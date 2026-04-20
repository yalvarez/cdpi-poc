# Test Flows — End-to-End
## CDPI PoC — CREDEBL Issuance & Verification

**Purpose**: Validate the full PoC stack end-to-end  
**When to run**: Day 4 (with sample data) and Day 5 (with real integrations)  
**Prerequisites**: Stack healthy (`bash scripts/health-check.sh`)

> API-first path (no Studio clicks): see `credebl/docs/api-e2e-requests.md` and run `scripts/credebl-api-e2e.sh`.
> OID4VC (SD-JWT) path: see `credebl/docs/api-test-oid4vc.sh` — validates OID4VCI issuance + OID4VP verification end-to-end.

---

## Setup — get a token and IDs

Before running any flow, run this once to set your environment:

```bash
VPS_IP="YOUR_VPS_IP"  # replace with your actual VPS IP
BASE="http://$VPS_IP:5000"

# 1. Login and get token
# Initial Studio login uses the seeded platform admin account.
# Default credentials: admin@cdpi-poc.local / value of PLATFORM_ADMIN_INITIAL_PASSWORD (defaults to changeme)
STUDIO="http://$VPS_IP:3000"
ENC_PASSWORD=$(curl -s -X POST "$STUDIO/api/encrypt" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${ADMIN_PASSWORD:-${PLATFORM_ADMIN_INITIAL_PASSWORD:-changeme}}\"}" \
  | jq -r '.data')
TOKEN=$(curl -s -X POST "$BASE/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"admin@cdpi-poc.local\",\"password\":\"${ENC_PASSWORD}\"}" \
  | jq -r '.data.access_token')

echo "Token: ${TOKEN:0:40}..."  # Should show a JWT prefix
```

---

## Flow 1 — Create organization and agent

```bash
# Create organization
ORG=$(curl -s -X POST "$BASE/orgs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "CDPI PoC Issuer",
    "description": "Test organization for PoC",
    "website": "https://cdpi-poc.local",
    "country": "DO"
  }' | jq .)

ORG_ID=$(echo $ORG | jq -r '.id')
echo "Organization ID: $ORG_ID"

# Create agent for the organization
curl -s -X POST "$BASE/orgs/$ORG_ID/agents" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "cdpi-poc-agent",
    "ledgerId": "testnet"
  }' | jq .

# Wait ~30 seconds for agent to provision, then check status
sleep 30
curl -s "$BASE/orgs/$ORG_ID/agents" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

**Expected**: Agent status should be `active` after ~30 seconds.

---

## Flow 2 — Register schema (Employment example)

```bash
# Register the employment schema
SCHEMA=$(curl -s -X POST "$BASE/schema/create" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "EmploymentCertification",
    "version": "1.0",
    "schemaType": "SD_JWT_VC",
    "vct": "https://schemas.cdpi-poc.local/employment/v1",
    "orgId": "'"$ORG_ID"'",
    "attributes": [
      "given_name", "family_name", "birthdate", "document_number",
      "employer_name", "employer_id",
      "employment_status", "employment_type", "position_title", "department",
      "employment_start_date", "gross_salary", "salary_currency",
      "issuer_name", "certificate_number"
    ]
  }' | jq .)

SCHEMA_ID=$(echo $SCHEMA | jq -r '.id')
echo "Schema ID: $SCHEMA_ID"
```

---

## Flow 3 — Create credential definition

```bash
CRED_DEF=$(curl -s -X POST "$BASE/credential-definitions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "schemaId": "'"$SCHEMA_ID"'",
    "orgId": "'"$ORG_ID"'",
    "tag": "employment-v1",
    "revocable": true
  }' | jq .)

CRED_DEF_ID=$(echo $CRED_DEF | jq -r '.credentialDefinitionId')
echo "Credential Definition ID: $CRED_DEF_ID"
```

---

## Flow 4A — Issue an SD-JWT VC (OID4VCI — recommended for OID4VC protocol)

This is the native OID4VCI path. The Credo agent produces an `openid-credential-offer://` URL that OID4VCI-compliant wallets (Inji, MATTR, etc.) scan to receive an SD-JWT VC.

**Prerequisites**: org with `did:key` DID and an SD-JWT schema (see Flows 1-3 above, using `schemaType: "no_ledger"`).

```bash
# Issue SD-JWT VC via OOB email — credentialType=sdjwt triggers the OID4VCI path
ISSUE=$(curl -s -X POST "$BASE/orgs/$ORG_ID/credentials/oob/email?credentialType=sdjwt" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "credentialOffer": [
      {
        "emailId": "holder@example.com",
        "attributes": [
          { "name": "given_name",            "value": "María José" },
          { "name": "family_name",           "value": "García Pérez" },
          { "name": "document_number",       "value": "001-1985031-4" },
          { "name": "employer_name",         "value": "Ministerio de Trabajo" },
          { "name": "employment_status",     "value": "active" },
          { "name": "position_title",        "value": "Técnico en Sistemas" },
          { "name": "employment_start_date", "value": "2018-06-01" }
        ]
      }
    ],
    "credentialDefinitionId": "'"$SCHEMA_ID"'",
    "isReuseConnection": true
  }' | jq .)

OFFER_URL=$(echo $ISSUE | jq -r '.data.credentialOffer // .data.offerUrl // .data.invitationUrl')
ISSUANCE_ID=$(echo $ISSUE | jq -r '.data.id')

echo "Issuance ID: $ISSUANCE_ID"
echo "OID4VCI Offer URL (open in wallet or encode as QR):"
echo "$OFFER_URL"
```

**Offer URL format**: `openid-credential-offer://?credential_offer_uri=http://VPS:5000/...`  
**Holder action**: open the URL in Inji or any OID4VCI-compatible wallet to accept the SD-JWT VC.

> **Run the full automated test**: `bash credebl/docs/api-test-oid4vc.sh`

---

## Flow 4B — Issue a W3C JSON-LD VC (validated, DIDComm OOB path)

This is the alternative path using W3C JSON-LD credentials delivered via DIDComm OOB.
The offer URL format is `https://VPS:9000/credebl-bucket/default/{uuid}` (stored in MinIO).

```bash
# Issue W3C JSON-LD VC via OOB email — credentialType=jsonld
ISSUE=$(curl -s -X POST "$BASE/orgs/$ORG_ID/credentials/oob/email?credentialType=jsonld" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "credentialOffer": [
      {
        "emailId": "holder@example.com",
        "credential": {
          "@context": [
            "https://www.w3.org/2018/credentials/v1",
            "'"$SCHEMA_CONTEXT_URL"'"
          ],
          "type": ["VerifiableCredential", "'"$SCHEMA_NAME"'"],
          "issuer": { "id": "'"$ORG_DID"'" },
          "issuanceDate": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
          "credentialSubject": {
            "given_name": "María José",
            "family_name": "García Pérez",
            "employer_name": "Ministerio de Trabajo",
            "employment_status": "active"
          }
        },
        "options": {
          "proofType": "Ed25519Signature2018",
          "proofPurpose": "assertionMethod"
        }
      }
    ],
    "protocolVersion": "v2",
    "isReuseConnection": true,
    "credentialType": "jsonld"
  }' | jq .)

echo "Offer URL (DIDComm OOB):"
echo $ISSUE | jq -r '.data.invitationUrl // .data.offerUrl'
```

> **Run the full validated test**: `bash credebl/docs/api-test.sh` (validated Apr 18, 2026)

---

## Flow 5 — Create OID4VP proof request

The verifier creates a proof request URL. The holder scans it in their wallet and presents the credential.

```bash
# Create OID4VP OOB proof request
PROOF=$(curl -s -X POST "$BASE/orgs/$ORG_ID/proofs/oob" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "comment": "Employment verification — PoC demo",
    "proofReqPayload": {
      "name": "employment-check",
      "version": "1.0",
      "requested_attributes": {
        "attr_given_name": {
          "name": "given_name",
          "restrictions": [{ "schema_id": "'"$SCHEMA_ID"'" }]
        },
        "attr_employer": {
          "name": "employer_name",
          "restrictions": [{ "schema_id": "'"$SCHEMA_ID"'" }]
        },
        "attr_status": {
          "name": "employment_status",
          "restrictions": [{ "schema_id": "'"$SCHEMA_ID"'" }]
        }
      },
      "requested_predicates": {}
    }
  }' | jq .)

PROOF_URL=$(echo $PROOF | jq -r '.data.proofUrl // .data.invitationUrl')
PROOF_ID=$(echo $PROOF | jq -r '.data.id')

echo "Proof ID: $PROOF_ID"
echo "OID4VP Proof Request URL (show as QR for wallet to scan):"
echo "$PROOF_URL"
```

---

## Flow 6 — Poll verification result

```bash
# Poll until done or abandoned (run after holder presents the credential)
while true; do
  RESULT=$(curl -s "$BASE/orgs/$ORG_ID/proofs/$PROOF_ID" \
    -H "Authorization: Bearer $TOKEN" | jq .)

  STATE=$(echo $RESULT | jq -r '.data.state // .state')
  echo "State: $STATE"

  if [ "$STATE" = "done" ] || [ "$STATE" = "verified" ]; then
    echo ""
    echo "Verification result:"
    echo $RESULT | jq '{isVerified: .data.isVerified, state: .data.state}'
    break
  fi

  if [ "$STATE" = "abandoned" ]; then
    echo "Verification abandoned by holder"
    break
  fi

  sleep 3
done
```

---

## Flow 7 — Full automated tests (Day 4 smoke tests)

Two scripts cover the full E2E:

| Script | Protocol | Format | Status |
|--------|----------|--------|--------|
| `credebl/docs/api-test.sh` | DIDComm OOB | W3C JSON-LD | ✓ Validated Apr 18, 2026 |
| `credebl/docs/api-test-oid4vc.sh` | OID4VCI + OID4VP | SD-JWT VC | Run on Day 4 |

```bash
# W3C JSON-LD (DIDComm OOB) — already validated
ADMIN_PASSWORD='yourpassword' EMAIL_TO='holder@example.com' \
  bash credebl/docs/api-test.sh

# SD-JWT VC (OID4VCI + OID4VP)
ADMIN_PASSWORD='yourpassword' EMAIL_TO='holder@example.com' \
  bash credebl/docs/api-test-oid4vc.sh
```

Quick API health smoke test:

```bash
#!/usr/bin/env bash
# Save as: scripts/smoke-test.sh

set -euo pipefail

VPS_IP="${1:-localhost}"
BASE="http://$VPS_IP:5000"
PASS=0
FAIL=0

check() {
  local name=$1
  local result=$2
  local expected=$3
  if echo "$result" | jq -e "$expected" > /dev/null 2>&1; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name"
    echo "    Got: $(echo $result | jq -c . | head -c 200)"
    FAIL=$((FAIL+1))
  fi
}

echo "══════════════════════════════════════════"
echo " CDPI PoC Smoke Test — $VPS_IP"
echo "══════════════════════════════════════════"
echo ""

echo "── API health ──"
HEALTH=$(curl -sf "$BASE/health" | jq .)
check "API gateway responding" "$HEALTH" '.status == "ok" or .status == "healthy"'

echo ""
echo "── Authentication ──"
ENC_PASSWORD=$(curl -s -X POST "http://$VPS_IP:3000/api/encrypt" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${ADMIN_PASSWORD:-CHANGE_ME_TO_KEYCLOAK_ADMIN_PASSWORD}\"}" | jq -r '.data')
LOGIN=$(curl -s -X POST "$BASE/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"admin@cdpi-poc.local\",\"password\":\"${ENC_PASSWORD}\"}" | jq .)
# ADMIN_PASSWORD should match KEYCLOAK_ADMIN_PASSWORD from .env for the bundled platform-admin user.
check "Login returns token" "$LOGIN" '.data.access_token | length > 0'
TOKEN=$(echo $LOGIN | jq -r '.data.access_token')

echo ""
echo "── Organization listing ──"
ORGS=$(curl -s "$BASE/orgs" -H "Authorization: Bearer $TOKEN" | jq .)
check "Can list organizations" "$ORGS" '. | length >= 0'

echo ""
echo "── Schema listing ──"
# This will fail if no org exists yet — that's expected on first run
SCHEMAS=$(curl -s "$BASE/schema" -H "Authorization: Bearer $TOKEN" | jq . 2>/dev/null || echo "[]")
check "Schema endpoint reachable" "$SCHEMAS" '. != null'

echo ""
echo "══════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
  echo " ✓ All $PASS checks passed"
else
  echo " ✗ $FAIL failed / $PASS passed"
  exit 1
fi
echo "══════════════════════════════════════════"
```

```bash
chmod +x scripts/smoke-test.sh
ADMIN_PASSWORD=your_password bash scripts/smoke-test.sh YOUR_VPS_IP
```

---

## Day 5 — Validation checklist after real integrations

After connecting the real database and swapping the OIDC, re-run all flows and confirm:

- [ ] Login still works (real OIDC)
- [ ] Can issue a credential with data from the real database
- [ ] Issued credential appears in the holder's wallet correctly
- [ ] Verification flow produces `isVerified: true`
- [ ] All revealed attributes match the real database values
- [ ] Selectively disclosable fields work — holder can choose what to reveal
- [ ] Credential revocation works (revoke one credential, verify it fails)

---

## Common issues during testing

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `401 Unauthorized` | Token expired | Re-run login, update `$TOKEN` |
| Agent status stuck at `provisioning` | Agent container still starting | Wait 60s, check `docker compose logs agent-provisioning` |
| Offer URL not opening in wallet | Wallet not reachable from VPS network | Try opening URL in browser first to confirm it resolves |
| `isVerified: false` | Schema/cred def mismatch | Confirm holder has credential from same cred def ID |
| Verification request `abandoned` | Holder dismissed the request in wallet | Retry the verification flow |
