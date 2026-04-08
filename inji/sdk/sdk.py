"""
CDPI PoC — INJI Verification SDK (Python 3.8+)
------------------------------------------------
Wrapper for verifying SD-JWT VC credentials via INJI's OID4VP flow.

Usage:
    from sdk import InjiVerifier

    verifier = InjiVerifier(
        certify_url="http://VPS_IP:8091",
        client_id="cdpi-poc-verifier",
        redirect_uri="http://VPS_IP:3001/verify"
    )
    request_uri, request_id = verifier.create_presentation_request([...])
    result = verifier.await_presentation(request_id)
"""

import json
import time
import random
import string
import urllib.request
import urllib.error
from typing import List, Optional, Dict, Any, Callable, Tuple, Union


class InjiError(Exception):
    def __init__(self, status_code: int, body: Any):
        message = (body.get("message") or body.get("error") or f"HTTP {status_code}") \
            if isinstance(body, dict) else str(body)
        super().__init__(message)
        self.status_code = status_code
        self.body = body


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
        raise InjiError(e.code, body)


def _nonce(n: int = 16) -> str:
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=n))


class InjiVerifier:
    """
    SDK for verifying SD-JWT VC credentials through INJI's OID4VP flow.

    Args:
        certify_url:   Certify base URL via Nginx (e.g. http://VPS_IP:8091)
        client_id:     Verifier client ID registered in Mimoto
        redirect_uri:  Redirect URI after presentation
        poll_interval: Seconds between polling attempts (default: 3)
        poll_timeout:  Total seconds to wait (default: 120)
    """

    def __init__(
        self,
        certify_url: str,
        client_id: str,
        redirect_uri: str,
        poll_interval: float = 3.0,
        poll_timeout: float = 120.0,
    ):
        if not certify_url:
            raise ValueError("certify_url is required")
        if not client_id:
            raise ValueError("client_id is required")
        if not redirect_uri:
            raise ValueError("redirect_uri is required")

        self.certify_url   = certify_url.rstrip("/")
        self.client_id     = client_id
        self.redirect_uri  = redirect_uri
        self.poll_interval = poll_interval
        self.poll_timeout  = poll_timeout

    # ── Discovery ────────────────────────────────────────────────────────────────

    def get_issuer_metadata(self) -> dict:
        """Fetch issuer metadata from Certify well-known endpoint."""
        return _http("GET", f"{self.certify_url}/.well-known/openid-credential-issuer")

    def get_supported_credential_types(self) -> list:
        """List credential types supported by this issuer."""
        meta = self.get_issuer_metadata()
        return list(meta.get("credential_configurations_supported", {}).keys())

    # ── Presentation request ─────────────────────────────────────────────────────

    def create_presentation_request(
        self,
        requested_fields: List[Union[str, Dict[str, Any]]],
        credential_type: str = "EmploymentCertification",
        purpose: str = "CDPI PoC Credential Verification",
        limit_disclosure: bool = True,
    ) -> Tuple[str, str]:
        """
        Create an OID4VP presentation request.

        Args:
            requested_fields: List of field paths or dicts with 'path' key
                              e.g. ["$.given_name"] or [{"path": "$.given_name"}]
            credential_type:  Credential type to request
            purpose:          Human-readable purpose
            limit_disclosure: Enforce selective disclosure (default: True)

        Returns:
            Tuple of (request_uri, request_id)

        Example:
            uri, req_id = verifier.create_presentation_request(
                ["$.given_name", "$.family_name", "$.employer_name"],
                credential_type="EmploymentCertification"
            )
        """
        fields = [
            {"path": [f if isinstance(f, str) else f["path"]]}
            for f in requested_fields
        ]

        payload = {
            "client_id": self.client_id,
            "redirect_uri": self.redirect_uri,
            "response_type": "vp_token",
            "scope": f"openid {credential_type}",
            "nonce": _nonce(),
            "presentation_definition": {
                "id": f"{credential_type.lower()}-check-{int(time.time())}",
                "input_descriptors": [
                    {
                        "id": credential_type.lower(),
                        "name": credential_type,
                        "purpose": purpose,
                        "constraints": {
                            "limit_disclosure": "required" if limit_disclosure else "preferred",
                            "fields": fields,
                        },
                    }
                ],
            },
        }

        data = _http("POST", f"{self.certify_url}/v1/certify/vp/presentation-request", payload)
        request_uri = data.get("request_uri") or data.get("presentation_uri")
        request_id  = data.get("id") or data.get("request_id") or data.get("nonce")
        return request_uri, request_id

    # ── Await presentation ───────────────────────────────────────────────────────

    def get_presentation_state(self, request_id: str) -> dict:
        """Check the current state of a presentation request."""
        data = _http("GET", f"{self.certify_url}/v1/certify/vp/presentation/{request_id}")
        return {
            "state": data.get("state") or data.get("status"),
            "verified": data.get("verified"),
            "claims": data.get("verified_claims") or data.get("claims"),
            "raw": data,
        }

    def await_presentation(
        self,
        request_id: str,
        on_state_change: Optional[Callable[[str], None]] = None,
        on_tick: Optional[Callable[[int, str], None]] = None,
    ) -> dict:
        """
        Poll for presentation result until complete or timeout.

        Args:
            request_id:      Presentation request ID
            on_state_change: Callback(state) when state changes
            on_tick:         Callback(attempt, state) on each poll

        Returns:
            Dict with verified, claims, reason, request_id
        """
        start      = time.time()
        last_state = None
        attempt    = 0
        terminal   = {"verified", "done", "completed", "rejected", "failed", "abandoned"}

        while time.time() - start < self.poll_timeout:
            attempt += 1
            result = self.get_presentation_state(request_id)

            if result["state"] != last_state:
                last_state = result["state"]
                if on_state_change:
                    on_state_change(result["state"])

            if on_tick:
                on_tick(attempt, result["state"])

            if result["state"] in {"verified", "done", "completed"}:
                return {
                    "verified": result["verified"] is not False,
                    "claims": result["claims"],
                    "reason": None,
                    "request_id": request_id,
                }

            if result["state"] in {"rejected", "failed", "abandoned"}:
                return {
                    "verified": False,
                    "claims": None,
                    "reason": result["state"],
                    "request_id": request_id,
                }

            time.sleep(self.poll_interval)

        return {"verified": False, "claims": None, "reason": "timeout", "request_id": request_id}

    def verify(
        self,
        requested_fields: List[Union[str, Dict[str, Any]]],
        credential_type: str = "EmploymentCertification",
        purpose: str = "CDPI PoC Credential Verification",
        on_request_uri: Optional[Callable[[str, str], None]] = None,
        on_state_change: Optional[Callable[[str], None]] = None,
    ) -> dict:
        """
        One-shot: create request and wait for presentation.

        Args:
            requested_fields: List of field paths
            credential_type:  Credential type to verify
            purpose:          Human-readable purpose
            on_request_uri:   Callback(request_uri, request_id) — show QR to holder
            on_state_change:  Callback(state)

        Returns:
            Dict with verified, claims, reason, request_id
        """
        request_uri, request_id = self.create_presentation_request(
            requested_fields,
            credential_type=credential_type,
            purpose=purpose,
        )

        if on_request_uri:
            on_request_uri(request_uri, request_id)

        return self.await_presentation(request_id, on_state_change=on_state_change)


# ─── CLI quick test ───────────────────────────────────────────────────────────
if __name__ == "__main__":
    import os
    import sys

    certify_url  = os.environ.get("INJI_CERTIFY_URL",  "http://localhost:8091")
    client_id    = os.environ.get("INJI_CLIENT_ID",    "cdpi-poc-verifier")
    redirect_uri = os.environ.get("INJI_REDIRECT_URI", "http://localhost:3001/verify")

    verifier = InjiVerifier(
        certify_url=certify_url,
        client_id=client_id,
        redirect_uri=redirect_uri,
    )

    print("Supported credential types:")
    try:
        types = verifier.get_supported_credential_types()
        print(types)
    except Exception as e:
        print(f"  Could not fetch (stack may not be running): {e}")

    print("\nCreating presentation request...")
    result = verifier.verify(
        requested_fields=[
            "$.given_name",
            "$.family_name",
            "$.employer_name",
            "$.employment_status",
        ],
        credential_type="EmploymentCertification",
        purpose="Employment verification — CDPI PoC",
        on_request_uri=lambda uri, rid: print(f"\nShare with holder wallet:\n{uri}\n\nWaiting..."),
        on_state_change=lambda s: print(f"  State: {s}"),
    )

    print("\nResult:")
    print(json.dumps(result, indent=2, default=str))
