# Test Flows — End-to-End
## CDPI PoC — CREDEBL Issuance & Verification

**Purpose**: Validate the full PoC stack end-to-end  
**When to run**: Day 4 (with sample data) and Day 5 (with real integrations)  
**Prerequisites**: Stack healthy (`bash scripts/health-check.sh`)

---

## Setup — get a token and IDs

Before running any flow, run this once to set your environment:

```bash
VPS_IP="YOUR_VPS_IP"  # replace with your actual VPS IP
BASE="http://$VPS_IP:5000"

# 1. Login and get token
# Initial Studio login uses the seeded platform admin account.
# Default credentials: admin@cdpi-poc.local / changeme
STUDIO="http://$VPS_IP:3000"
ENC_PASSWORD=$(curl -s -X POST "$STUDIO/api/encrypt" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${ADMIN_PASSWORD:-changeme}\"}" \
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

## Flow 4 — Issue a credential (OID4VCI)

```bash
# Issue credential — returns an offer URL the holder opens in their wallet
OFFER=$(curl -s -X POST "$BASE/issuance/oob/create-offer" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "orgId": "'"$ORG_ID"'",
    "credentialDefinitionId": "'"$CRED_DEF_ID"'",
    "comment": "PoC Employment Certificate",
    "attributes": [
      { "name": "given_name",           "value": "María José" },
      { "name": "family_name",          "value": "García Pérez" },
      { "name": "birthdate",            "value": "1985-03-14" },
      { "name": "document_number",      "value": "001-1985031-4" },
      { "name": "employer_name",        "value": "Ministerio de Educación" },
      { "name": "employer_id",          "value": "4-01-50001-8" },
      { "name": "employment_status",    "value": "active" },
      { "name": "employment_type",      "value": "permanent" },
      { "name": "position_title",       "value": "Técnico en Sistemas" },
      { "name": "department",           "value": "Dirección General de TI" },
      { "name": "employment_start_date","value": "2018-06-01" },
      { "name": "gross_salary",         "value": "45000" },
      { "name": "salary_currency",      "value": "DOP" },
      { "name": "issuer_name",          "value": "Ministerio de Trabajo" },
      { "name": "certificate_number",   "value": "CERT-2024-0001234" }
    ]
  }' | jq .)

OFFER_URL=$(echo $OFFER | jq -r '.offerUrl // .invitationUrl')
ISSUANCE_ID=$(echo $OFFER | jq -r '.id')

echo "Issuance ID: $ISSUANCE_ID"
echo ""
echo "Offer URL (open in wallet or encode as QR):"
echo "$OFFER_URL"
```

**Expected**: The holder opens this URL in their wallet app (Inji, etc.) to accept the credential.

---

## Flow 5 — Verify a credential (OID4VP)

```bash
# Create a verification request — returns a proof request URL
PROOF=$(curl -s -X POST "$BASE/verification/send-verification-request" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "orgId": "'"$ORG_ID"'",
    "comment": "Employment verification for PoC demo",
    "requestedAttributes": [
      {
        "attributeName": "given_name",
        "schemaId": "'"$SCHEMA_ID"'",
        "credDefId": "'"$CRED_DEF_ID"'",
        "isRevoked": false
      },
      {
        "attributeName": "family_name",
        "schemaId": "'"$SCHEMA_ID"'",
        "credDefId": "'"$CRED_DEF_ID"'",
        "isRevoked": false
      },
      {
        "attributeName": "employer_name",
        "schemaId": "'"$SCHEMA_ID"'",
        "credDefId": "'"$CRED_DEF_ID"'",
        "isRevoked": false
      },
      {
        "attributeName": "employment_status",
        "schemaId": "'"$SCHEMA_ID"'",
        "credDefId": "'"$CRED_DEF_ID"'",
        "isRevoked": false
      }
    ]
  }' | jq .)

PROOF_URL=$(echo $PROOF | jq -r '.proofUrl // .invitationUrl')
PROOF_ID=$(echo $PROOF | jq -r '.id')

echo "Proof ID: $PROOF_ID"
echo ""
echo "Proof URL (show as QR for wallet to scan):"
echo "$PROOF_URL"
```

---

## Flow 6 — Poll verification result

```bash
# Poll until done or abandoned (run after holder presents the credential)
while true; do
  RESULT=$(curl -s "$BASE/verification/proofs/$PROOF_ID" \
    -H "Authorization: Bearer $TOKEN" | jq .)

  STATE=$(echo $RESULT | jq -r '.state')
  echo "State: $STATE"

  if [ "$STATE" = "done" ]; then
    echo ""
    echo "Verification result:"
    echo $RESULT | jq '{isVerified: .isVerified, attributes: .requestedAttributes}'
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

## Flow 7 — Full automated test (Day 4 smoke test)

Run this script to validate issuance + verification work end-to-end using CREDEBL's test tooling:

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
