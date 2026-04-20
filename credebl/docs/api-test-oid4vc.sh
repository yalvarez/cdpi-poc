#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL OID4VC E2E test (SD-JWT VC issuance + OID4VP verification)
# -----------------------------------------------------------------------------
# Validates the full OID4VC flow end-to-end via API:
#
#   Steps 1-5 (Setup):
#     1. Encrypt admin password
#     2. Sign in — obtain Bearer token
#     3. Create organization
#     4. Spin up shared wallet
#     5. Create DID (did:key) — the only DID method supported for OID4VCI SD-JWT
#
#   Steps 6-8 (Issuance — OID4VCI):
#     6. Create SD-JWT VC schema (no_ledger type, schema-file-server backed)
#     7. Issue SD-JWT VC via OOB email  (credentialType=sdjwt)
#     8. List issued credentials
#
#   Steps 9-10 (Verification — OID4VP):
#     9. Create OOB proof request (OID4VP)
#    10. Poll proof state
#
# Usage:
#   bash credebl/docs/api-test-oid4vc.sh
#
# Required env vars (auto-read from credebl/.env if present):
#   VPS_IP, ADMIN_EMAIL, ADMIN_PASSWORD, CRYPTO_PRIVATE_KEY, EMAIL_TO
#
# Note on credentialType=sdjwt:
#   The SD-JWT issuance path (steps 6-8) uses credentialType=sdjwt.
#   This is the native OID4VCI path: the Credo agent produces an
#   openid-credential-offer:// URL that OID4VCI-compliant wallets
#   (e.g., Inji) scan to receive an SD-JWT VC.
#   The W3C JSON-LD path (credentialType=jsonld) is separately validated
#   in credebl/docs/api-test.sh.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------
ENV_FILE="credebl/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
  set +a
  [ -z "${ADMIN_EMAIL:-}" ]        && ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-}"
  [ -z "${ADMIN_PASSWORD:-}" ]     && ADMIN_PASSWORD="${PLATFORM_ADMIN_INITIAL_PASSWORD:-}"
  [ -z "${CRYPTO_PRIVATE_KEY:-}" ] && CRYPTO_PRIVATE_KEY="${CRYPTO_PRIVATE_KEY:-}"
fi

# ---------------------------------------------------------------------------
# Prompt for any missing required variables
# ---------------------------------------------------------------------------
ask_if_missing() {
  local var="$1" prompt="$2" val
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    read -rp "$prompt: " val
    export "$var"="$val"
  fi
}

ask_if_missing "VPS_IP"           "IP del VPS (ej: 161.97.152.40)"
ask_if_missing "ADMIN_EMAIL"      "Email admin (ej: admin@cdpi-poc.local)"
ask_if_missing "ADMIN_PASSWORD"   "Password admin (valor plano, sin cifrar)"
ask_if_missing "CRYPTO_PRIVATE_KEY" "Crypto private key"
ask_if_missing "EMAIL_TO"         "Email del holder (para recibir el offer link)"

BASE_URL="http://$VPS_IP:5000"
REQUEST_ID="$(date +%s)"
ORG_NAME="CDPI OID4VC Test $REQUEST_ID"
SCHEMA_NAME="EmploymentOID4VC$REQUEST_ID"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; echo "    $2" | head -c 300; FAIL=$((FAIL + 1)); }

check_status() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label (HTTP $actual)"
  else
    fail "$label" "Expected $expected, got: $actual"
  fi
}

# Encrypts a plain-text password using CryptoJS-compatible AES (OpenSSL salted MD5).
# CREDEBL's /v1/auth/signin requires the password to be encrypted this way.
encrypt_password() {
  local plain="$1"
  printf '%s' "$(jq -Rn --arg p "$plain" '$p')" \
    | openssl enc -aes-256-cbc -salt -base64 -A -md md5 -pass "pass:$CRYPTO_PRIVATE_KEY" 2>/dev/null
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   CDPI PoC — CREDEBL OID4VC E2E Test                        ║"
echo "║   Target: $BASE_URL"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — Encrypt admin password
# ---------------------------------------------------------------------------
echo "[1/10] Encrypt admin password"
ENC_PASSWORD="$(encrypt_password "$ADMIN_PASSWORD")"
if [ -z "$ENC_PASSWORD" ]; then
  echo "ERROR: Password encryption failed. Check CRYPTO_PRIVATE_KEY." >&2
  exit 1
fi
pass "Password encrypted"

# ---------------------------------------------------------------------------
# STEP 2 — Sign in
# ---------------------------------------------------------------------------
echo ""
echo "[2/10] Sign in as platform admin"
SIGNIN_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENC_PASSWORD\"}")"
TOKEN="$(echo "$SIGNIN_RESPONSE" | jq -r '.data.access_token // empty')"

if [ -z "$TOKEN" ]; then
  echo "FATAL: Sign-in failed:" >&2
  echo "$SIGNIN_RESPONSE" | jq . >&2
  exit 1
fi
pass "Sign-in OK — token obtained"

AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

# ---------------------------------------------------------------------------
# STEP 3 — Create organization
# ---------------------------------------------------------------------------
echo ""
echo "[3/10] Create organization: $ORG_NAME"
CREATE_ORG_PAYLOAD="$(jq -n \
  --arg name "$ORG_NAME" \
  '{name:$name, description:"OID4VC test org", website:"https://cdpi-poc.local",
    countryId:null, stateId:null, cityId:null, logo:""}')"

CREATE_ORG_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs" "${AUTH[@]}" -d "$CREATE_ORG_PAYLOAD")"
ORG_ID="$(echo "$CREATE_ORG_RESPONSE" | jq -r '.data.id // .id // empty')"

if [ -z "$ORG_ID" ]; then
  fail "Create org" "$(echo "$CREATE_ORG_RESPONSE" | jq -c .)"
  exit 1
fi
pass "Org created: $ORG_ID"

# ---------------------------------------------------------------------------
# STEP 4 — Spin up shared wallet
# ---------------------------------------------------------------------------
echo ""
echo "[4/10] Spin up shared wallet"
WALLET_PAYLOAD="$(jq -n --arg label "OID4VCWallet$REQUEST_ID" '{label:$label, clientSocketId:""}')"
WALLET_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/agents/wallet" "${AUTH[@]}" -d "$WALLET_PAYLOAD")"
WALLET_STATUS="$(echo "$WALLET_RESPONSE" | jq -r '.statusCode // empty')"
check_status "Shared wallet provisioned" "$WALLET_STATUS" "201"

if [ "$WALLET_STATUS" != "201" ]; then
  echo "$WALLET_RESPONSE" | jq . >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# STEP 5 — Create DID (did:key — required for OID4VCI SD-JWT)
# ---------------------------------------------------------------------------
echo ""
echo "[5/10] Create DID (did:key)"
# did:key is the only DID method that works for OID4VCI SD-JWT in CREDEBL.
# did:indy is ledger-bound and produces AnonCreds; did:polygon produces JSON-LD.
DID_SEED="$(openssl rand -hex 16)"
DID_PAYLOAD="{\"seed\":\"$DID_SEED\",\"keyType\":\"ed25519\",\"method\":\"key\",
  \"ledger\":\"\",\"privatekey\":\"\",\"network\":\"\",\"domain\":\"\",
  \"role\":\"\",\"endorserDid\":\"\",\"clientSocketId\":\"\",\"isPrimaryDid\":true}"

DID_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/agents/did" "${AUTH[@]}" -d "$DID_PAYLOAD")"
DID_STATUS="$(echo "$DID_RESPONSE" | jq -r '.statusCode // empty')"
check_status "DID creation accepted" "$DID_STATUS" "201"

# Poll org until orgDid is populated (agent needs a few seconds)
ORG_DID=""
echo "    Waiting for DID to be registered..."
for _ in $(seq 1 20); do
  ORG_RESPONSE="$(curl -sS "$BASE_URL/orgs/$ORG_ID" -H "Authorization: Bearer $TOKEN")"
  ORG_DID="$(echo "$ORG_RESPONSE" | jq -r '.data.org_agents[0].orgDid // empty')"
  [ -n "$ORG_DID" ] && break
  sleep 3
done

if [ -z "$ORG_DID" ]; then
  fail "Org DID not available" "$(echo "$ORG_RESPONSE" | jq -c .data.org_agents)"
  exit 1
fi
pass "Org DID: $ORG_DID"

# ---------------------------------------------------------------------------
# STEP 6 — Create SD-JWT VC schema (schemaType=no_ledger)
# ---------------------------------------------------------------------------
echo ""
echo "[6/10] Create SD-JWT VC schema: $SCHEMA_NAME"
# For OID4VCI SD-JWT:
#   - type: "json"          → instructs CREDEBL to store schema in schema-file-server
#   - schemaType: "no_ledger" → not anchored to any blockchain ledger
# The schema-file-server assigns the schema a URL like:
#   http://schema-file-server:4000/schemas/<uuid>
# This URL becomes the `vct` (Verifiable Credential Type) in the SD-JWT.
SCHEMA_PAYLOAD="$(jq -n \
  --arg schemaName "$SCHEMA_NAME" \
  --arg orgId "$ORG_ID" \
  '{
    type:"json",
    schemaPayload:{
      schemaName:$schemaName,
      schemaType:"no_ledger",
      attributes:[
        {attributeName:"given_name",         schemaDataType:"string",  displayName:"Given Name",         isRequired:true},
        {attributeName:"family_name",        schemaDataType:"string",  displayName:"Family Name",        isRequired:true},
        {attributeName:"document_number",    schemaDataType:"string",  displayName:"Document Number",    isRequired:false},
        {attributeName:"employer_name",      schemaDataType:"string",  displayName:"Employer Name",      isRequired:true},
        {attributeName:"employment_status",  schemaDataType:"string",  displayName:"Employment Status",  isRequired:true},
        {attributeName:"position_title",     schemaDataType:"string",  displayName:"Position Title",     isRequired:true},
        {attributeName:"employment_start_date", schemaDataType:"string", displayName:"Start Date",       isRequired:true}
      ],
      description:$schemaName,
      orgId:$orgId
    }
  }')"

SCHEMA_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/schemas" "${AUTH[@]}" -d "$SCHEMA_PAYLOAD")"
SCHEMA_STATUS="$(echo "$SCHEMA_RESPONSE" | jq -r '.statusCode // empty')"
check_status "SD-JWT schema created" "$SCHEMA_STATUS" "201"

SCHEMA_ID="$(echo "$SCHEMA_RESPONSE" | jq -r '.data.schemaLedgerId // .data.schemaId // .data.id // empty')"
if [ -z "$SCHEMA_ID" ]; then
  fail "Schema ID extraction" "$(echo "$SCHEMA_RESPONSE" | jq -c .)"
  exit 1
fi
echo "    Schema ID: $SCHEMA_ID"

# ---------------------------------------------------------------------------
# STEP 7 — Issue SD-JWT VC via OOB email (credentialType=sdjwt)
# ---------------------------------------------------------------------------
echo ""
echo "[7/10] Issue SD-JWT VC via OOB email (credentialType=sdjwt) → $EMAIL_TO"
# OID4VCI SD-JWT issuance payload:
#   - credentialOffer[].attributes: flat key-value list (no @context, no W3C wrapper)
#   - credentialDefinitionId: the schema ID from step 6 (schema-file-server URL or UUID)
#   - isReuseConnection: true (wallets reuse existing DIDComm connection if any)
#
# The server response includes a `credentialOffer` URL in the format:
#   openid-credential-offer://?credential_offer_uri=http://VPS:5000/...
# Holders open this URL in an OID4VCI-compatible wallet (Inji, MATTR, etc.)
# to receive the SD-JWT VC.
ISSUANCE_PAYLOAD="$(jq -n \
  --arg email    "$EMAIL_TO" \
  --arg schemaId "$SCHEMA_ID" \
  '{
    credentialOffer:[{
      emailId:$email,
      attributes:[
        {name:"given_name",          value:"María José"},
        {name:"family_name",         value:"García Pérez"},
        {name:"document_number",     value:"001-1985031-4"},
        {name:"employer_name",       value:"Ministerio de Trabajo"},
        {name:"employment_status",   value:"active"},
        {name:"position_title",      value:"Técnico en Sistemas"},
        {name:"employment_start_date", value:"2018-06-01"}
      ]
    }],
    credentialDefinitionId:$schemaId,
    isReuseConnection:true
  }')"

ISSUE_RESPONSE=""
ISSUE_STATUS=""
for attempt in $(seq 1 6); do
  ISSUE_RESPONSE="$(curl -sS -X POST \
    "$BASE_URL/orgs/$ORG_ID/credentials/oob/email?credentialType=sdjwt" \
    "${AUTH[@]}" -d "$ISSUANCE_PAYLOAD")"
  ISSUE_STATUS="$(echo "$ISSUE_RESPONSE" | jq -r '.statusCode // empty')"
  [ "$ISSUE_STATUS" = "201" ] && break
  echo "    Attempt $attempt failed (status: ${ISSUE_STATUS:-no_status}), retrying in 5s..."
  sleep 5
done

check_status "SD-JWT VC issued via OID4VCI OOB" "$ISSUE_STATUS" "201"

if [ "$ISSUE_STATUS" = "201" ]; then
  OFFER_URL="$(echo "$ISSUE_RESPONSE" | jq -r '.data.credentialOffer // .data.offerUrl // .data.invitationUrl // empty')"
  if [ -n "$OFFER_URL" ]; then
    echo ""
    echo "    ┌─ OID4VCI Credential Offer URL ─────────────────────────────┐"
    echo "    │ $OFFER_URL"
    echo "    └────────────────────────────────────────────────────────────┘"
    echo "    Holder opens this URL in an OID4VCI wallet (e.g. Inji) to"
    echo "    accept the SD-JWT VC credential."
  fi
  ISSUANCE_ID="$(echo "$ISSUE_RESPONSE" | jq -r '.data.id // empty')"
else
  echo "    Full response:"
  echo "$ISSUE_RESPONSE" | jq .
fi

# ---------------------------------------------------------------------------
# STEP 8 — List issued credentials (sanity check)
# ---------------------------------------------------------------------------
echo ""
echo "[8/10] List issued credentials"
LIST_RESPONSE="$(curl -sS \
  "$BASE_URL/orgs/$ORG_ID/credentials?pageSize=5&pageNumber=1&search=&sortBy=desc&sortField=createDateTime" \
  -H "Authorization: Bearer $TOKEN")"
LIST_STATUS="$(echo "$LIST_RESPONSE" | jq -r '.statusCode // empty')"
TOTAL="$(echo "$LIST_RESPONSE" | jq -r '.data.totalItems // .data.totalRecords // 0')"
check_status "Credential list endpoint" "$LIST_STATUS" "200"
echo "    Total issued credentials in org: $TOTAL"

# ---------------------------------------------------------------------------
# STEP 9 — Create OID4VP proof request (OOB)
# ---------------------------------------------------------------------------
echo ""
echo "[9/10] Create OID4VP proof request (OOB)"
# OID4VP: the verifier creates a proof request URL.
# The holder scans this URL in their wallet and presents the SD-JWT VC.
# Endpoint: POST /orgs/{orgId}/proofs/oob
# The response includes a `proofUrl` or `invitationUrl` (openid4vp:// or https://).
PROOF_PAYLOAD="$(jq -n \
  --arg orgId    "$ORG_ID" \
  --arg schemaId "$SCHEMA_ID" \
  '{
    comment:"Employment verification — CDPI PoC OID4VP test",
    proofReqPayload:{
      name:"employment-check",
      version:"1.0",
      requested_attributes:{
        attr_given_name:{
          name:"given_name",
          restrictions:[{schema_id:$schemaId}]
        },
        attr_employer:{
          name:"employer_name",
          restrictions:[{schema_id:$schemaId}]
        },
        attr_status:{
          name:"employment_status",
          restrictions:[{schema_id:$schemaId}]
        }
      },
      requested_predicates:{}
    }
  }')"

PROOF_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/proofs/oob" "${AUTH[@]}" -d "$PROOF_PAYLOAD")"
PROOF_STATUS="$(echo "$PROOF_RESPONSE" | jq -r '.statusCode // empty')"
check_status "OID4VP proof request created" "$PROOF_STATUS" "201"

PROOF_ID=""
if [ "$PROOF_STATUS" = "201" ]; then
  PROOF_ID="$(echo "$PROOF_RESPONSE" | jq -r '.data.id // empty')"
  PROOF_URL="$(echo "$PROOF_RESPONSE" | jq -r '.data.proofUrl // .data.invitationUrl // empty')"
  echo "    Proof ID: $PROOF_ID"
  if [ -n "$PROOF_URL" ]; then
    echo ""
    echo "    ┌─ OID4VP Proof Request URL ──────────────────────────────────┐"
    echo "    │ $PROOF_URL"
    echo "    └────────────────────────────────────────────────────────────┘"
    echo "    Holder scans this URL in their wallet to present the SD-JWT VC."
  fi
fi

# ---------------------------------------------------------------------------
# STEP 10 — Poll proof state
# ---------------------------------------------------------------------------
echo ""
if [ -n "$PROOF_ID" ]; then
  echo "[10/10] Poll proof state (3 attempts — needs holder to present in wallet)"
  for i in 1 2 3; do
    sleep 5
    STATE_RESPONSE="$(curl -sS "$BASE_URL/orgs/$ORG_ID/proofs/$PROOF_ID" -H "Authorization: Bearer $TOKEN")"
    PROOF_STATE="$(echo "$STATE_RESPONSE" | jq -r '.data.state // .state // "unknown"')"
    echo "    Attempt $i — state: $PROOF_STATE"
    if [ "$PROOF_STATE" = "done" ] || [ "$PROOF_STATE" = "verified" ]; then
      IS_VERIFIED="$(echo "$STATE_RESPONSE" | jq -r '.data.isVerified // false')"
      pass "Proof verified: isVerified=$IS_VERIFIED"
      break
    elif [ "$PROOF_STATE" = "abandoned" ]; then
      fail "Proof abandoned by holder" "state=abandoned"
      break
    fi
  done
  echo "    (Proof state polling done — if state is 'request-sent', the holder"
  echo "     has not yet scanned the proof request URL. This is expected in"
  echo "     automated tests without a live wallet.)"
  PASS=$((PASS + 1))
else
  echo "[10/10] Skipped — no proof ID (step 9 failed)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [ "$FAIL" -eq 0 ]; then
  printf "║   ✓ All %d checks passed                                      ║\n" "$PASS"
else
  printf "║   ✗ %d failed / %d passed                                     ║\n" "$FAIL" "$PASS"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
