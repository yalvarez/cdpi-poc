"""
CDPI PoC — Verification SDK (Python 3.8+)
------------------------------------------
Complete implementation for requesting and verifying SD-JWT VC
credentials through CREDEBL's OID4VP-based verification flow.

Usage:
    from sdk import CredeblVerifier

    verifier = CredeblVerifier(api_url="http://VPS_IP:5000", org_id="...", api_token="...")
    proof_url, proof_id = verifier.request_presentation([...])
    result = verifier.await_result(proof_id)
"""

import json
import time
import urllib.request
import urllib.error
from typing import List, Optional, Dict, Any, Callable, Tuple


# ─────────────────────────────────────────────────────────────────────────────
# Custom exceptions
# ─────────────────────────────────────────────────────────────────────────────

class CredeblError(Exception):
    def __init__(self, status_code: int, body: Any):
        message = body.get("message") or body.get("error") or f"HTTP {status_code}" if isinstance(body, dict) else str(body)
        super().__init__(message)
        self.status_code = status_code
        self.body = body


# ─────────────────────────────────────────────────────────────────────────────
# HTTP helper (no external dependencies — stdlib only)
# ─────────────────────────────────────────────────────────────────────────────

def _http(method: str, url: str, body: Optional[dict] = None, headers: Optional[dict] = None) -> dict:
    data = json.dumps(body).encode() if body else None
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)

    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read())
        except Exception:
            body = {"error": str(e)}
        raise CredeblError(e.code, body)


# ─────────────────────────────────────────────────────────────────────────────
# Main SDK class
# ─────────────────────────────────────────────────────────────────────────────

class CredeblVerifier:
    """
    SDK for verifying SD-JWT VC credentials through CREDEBL.

    Args:
        api_url:       CREDEBL API base URL (e.g. http://VPS_IP:5000)
        org_id:        Organization ID in CREDEBL
        api_token:     JWT token from /auth/login
        poll_interval: Seconds between result polling attempts (default: 3)
        poll_timeout:  Total seconds to wait for a result (default: 120)
    """

    def __init__(
        self,
        api_url: str,
        org_id: str,
        api_token: str,
        poll_interval: float = 3.0,
        poll_timeout: float = 120.0,
    ):
        if not api_url:
            raise ValueError("api_url is required")
        if not org_id:
            raise ValueError("org_id is required")
        if not api_token:
            raise ValueError("api_token is required")

        self.api_url = api_url.rstrip("/")
        self.org_id = org_id
        self.api_token = api_token
        self.poll_interval = poll_interval
        self.poll_timeout = poll_timeout

    @property
    def _headers(self) -> dict:
        return {"Authorization": f"Bearer {self.api_token}"}

    # ── Authentication ─────────────────────────────────────────────────────────

    @staticmethod
    def login(api_url: str, email: str, password: str) -> str:
        """
        Authenticate and return a JWT access token.

        Args:
            api_url:  CREDEBL API base URL
            email:    User email
            password: User password

        Returns:
            JWT access token string
        """
        data = _http("POST", f"{api_url.rstrip('/')}/auth/login", {"email": email, "password": password})
        return data["access_token"]

    # ── Organization ───────────────────────────────────────────────────────────

    def get_organization(self) -> dict:
        """Get organization details including agent status."""
        return _http("GET", f"{self.api_url}/orgs/{self.org_id}", headers=self._headers)

    # ── Schema & Credential Definition ────────────────────────────────────────

    def list_schemas(self) -> list:
        """List all schemas registered by this organization."""
        return _http("GET", f"{self.api_url}/schema/org/{self.org_id}", headers=self._headers)

    def list_credential_definitions(self) -> list:
        """List all credential definitions for this organization."""
        return _http("GET", f"{self.api_url}/credential-definitions/org/{self.org_id}", headers=self._headers)

    # ── Verification ───────────────────────────────────────────────────────────

    def request_presentation(
        self,
        requested_attributes: List[Dict[str, str]],
        comment: str = "CDPI PoC Verification Request",
        connection_id: Optional[str] = None,
    ) -> Tuple[str, str]:
        """
        Create a verification proof request.

        Args:
            requested_attributes: List of dicts with keys:
                - attribute_name: Field name from the schema
                - schema_id:      CREDEBL schema ID
                - cred_def_id:    Credential definition ID
            comment:       Human-readable comment for the request
            connection_id: If verifying over an existing connection

        Returns:
            Tuple of (proof_url, proof_id)

        Example:
            proof_url, proof_id = verifier.request_presentation([
                {"attribute_name": "given_name",    "schema_id": "abc", "cred_def_id": "def"},
                {"attribute_name": "employer_name", "schema_id": "abc", "cred_def_id": "def"},
            ])
        """
        payload = {
            "orgId": self.org_id,
            "requestedAttributes": [
                {
                    "attributeName": attr["attribute_name"],
                    "schemaId": attr["schema_id"],
                    "credDefId": attr["cred_def_id"],
                    "isRevoked": False,
                }
                for attr in requested_attributes
            ],
            "comment": comment,
        }

        if connection_id:
            payload["connectionId"] = connection_id

        data = _http("POST", f"{self.api_url}/verification/send-verification-request", payload, self._headers)

        proof_url = data.get("proofUrl") or data.get("invitationUrl")
        proof_id = data.get("id") or data.get("proofId")
        return proof_url, proof_id

    def get_proof_result(self, proof_id: str) -> dict:
        """
        Get the current state and result of a proof request.

        Args:
            proof_id: Proof request ID

        Returns:
            Dict with keys: state, is_verified, attributes, raw
        """
        data = _http("GET", f"{self.api_url}/verification/proofs/{proof_id}", headers=self._headers)
        return {
            "state": data.get("state"),
            "is_verified": data.get("isVerified"),
            "attributes": data.get("requestedAttributes"),
            "raw": data,
        }

    def await_result(
        self,
        proof_id: str,
        on_state_change: Optional[Callable[[str], None]] = None,
        on_tick: Optional[Callable[[int, str], None]] = None,
    ) -> dict:
        """
        Poll for verification result until done, abandoned, or timeout.

        Args:
            proof_id:        Proof request ID
            on_state_change: Callback(state) called when state changes
            on_tick:         Callback(attempt, state) called on each poll

        Returns:
            Dict with keys:
                verified:    bool — True if credential was verified
                attributes:  dict | None — Verified attributes if successful
                reason:      str | None — Failure reason if not verified
                proof_id:    str
        """
        start_time = time.time()
        last_state = None
        attempt = 0

        while time.time() - start_time < self.poll_timeout:
            attempt += 1
            result = self.get_proof_result(proof_id)

            if result["state"] != last_state:
                last_state = result["state"]
                if on_state_change:
                    on_state_change(result["state"])

            if on_tick:
                on_tick(attempt, result["state"])

            if result["state"] == "done":
                return {
                    "verified": result["is_verified"] is True,
                    "attributes": result["attributes"],
                    "reason": None if result["is_verified"] else "credential_invalid",
                    "proof_id": proof_id,
                }

            if result["state"] == "abandoned":
                return {"verified": False, "attributes": None, "reason": "abandoned", "proof_id": proof_id}

            time.sleep(self.poll_interval)

        return {"verified": False, "attributes": None, "reason": "timeout", "proof_id": proof_id}

    def verify(
        self,
        requested_attributes: List[Dict[str, str]],
        comment: str = "CDPI PoC Verification",
        on_proof_url: Optional[Callable[[str, str], None]] = None,
        on_state_change: Optional[Callable[[str], None]] = None,
    ) -> dict:
        """
        One-shot: request presentation and wait for result.

        Args:
            requested_attributes: List of attribute dicts (see request_presentation)
            comment:              Human-readable request comment
            on_proof_url:         Callback(proof_url, proof_id) — use to display QR code
            on_state_change:      Callback(state) — use to update UI

        Returns:
            Dict with verified, attributes, reason, proof_id
        """
        proof_url, proof_id = self.request_presentation(requested_attributes, comment=comment)

        if on_proof_url:
            on_proof_url(proof_url, proof_id)

        return self.await_result(proof_id, on_state_change=on_state_change)

    def list_proofs(self, limit: int = 20) -> list:
        """List recent proof requests for this organization."""
        return _http(
            "GET",
            f"{self.api_url}/verification/proofs?orgId={self.org_id}&limit={limit}",
            headers=self._headers,
        )


# ─────────────────────────────────────────────────────────────────────────────
# CLI quick test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import os
    import sys

    api_url    = os.environ.get("CREDEBL_API_URL", "http://localhost:5000")
    org_id     = os.environ.get("CREDEBL_ORG_ID", "")
    api_token  = os.environ.get("CREDEBL_API_TOKEN", "")
    schema_id  = os.environ.get("CREDEBL_SCHEMA_ID", "")
    cred_def_id = os.environ.get("CREDEBL_CRED_DEF_ID", "")

    if not all([org_id, api_token, schema_id, cred_def_id]):
        print("Set env vars: CREDEBL_ORG_ID, CREDEBL_API_TOKEN, CREDEBL_SCHEMA_ID, CREDEBL_CRED_DEF_ID")
        sys.exit(1)

    verifier = CredeblVerifier(api_url=api_url, org_id=org_id, api_token=api_token)

    print("Requesting verification...")
    result = verifier.verify(
        requested_attributes=[
            {"attribute_name": "given_name",    "schema_id": schema_id, "cred_def_id": cred_def_id},
            {"attribute_name": "family_name",   "schema_id": schema_id, "cred_def_id": cred_def_id},
            {"attribute_name": "employer_name", "schema_id": schema_id, "cred_def_id": cred_def_id},
        ],
        on_proof_url=lambda url, pid: print(f"\nScan this QR / open in wallet:\n{url}\n\nWaiting..."),
        on_state_change=lambda s: print(f"  State: {s}"),
    )

    print("\nResult:")
    print(json.dumps(result, indent=2, default=str))
