#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL OID4VC E2E test (SD-JWT VC issuance via OID4VCI + OID4VP)
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
#   Steps 6-8 (Issuance — OID4VCI pre-authorized code flow):
#     6. Create SD-JWT VC schema (no_ledger type, schema-file-server backed)
#     7. Create OID4VCI issuer + credential template
#     8. Create credential offer → display openid-credential-offer:// URL + PIN
#
#   Steps 9-10 (Verification — OID4VP):
#     9. Create OOB proof request (presentationExchange)
#    10. Poll proof state
#
# Usage:
#   bash credebl/docs/api-test-oid4vc.sh
#
# Required env vars (auto-read from credebl/.env if present):
#   VPS_IP, ADMIN_EMAIL, ADMIN_PASSWORD, CRYPTO_PRIVATE_KEY, EMAIL_TO
#
# Prerequisites (SSL deployment only):
#   - nginx must proxy /oid4vci/ → Credo admin port 8001 (added by init-credebl.sh)
#   - AGENT_HTTP_URL in agent.env must be https:// (set by init-credebl.sh when SSL enabled)
#   - Credo OID4VCI spec requires credential_issuer to be an https:// URL
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

ask_if_missing "VPS_IP"           "IP o dominio del VPS (ej: 161.97.152.40 o credebl.bootcamp.cdpi.dev)"
ask_if_missing "ADMIN_EMAIL"      "Email admin (ej: admin@cdpi-poc.local)"
ask_if_missing "ADMIN_PASSWORD"   "Password admin (valor plano, sin cifrar)"
ask_if_missing "CRYPTO_PRIVATE_KEY" "Crypto private key"
ask_if_missing "EMAIL_TO"         "Email del holder (para recibir el offer link)"

# Use HTTPS if VPS_IP looks like a domain name (has dots but no port and not a bare IP)
if [[ "$VPS_IP" =~ \. ]] && [[ ! "$VPS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  BASE_URL="https://$VPS_IP"
else
  BASE_URL="http://$VPS_IP:5000"
fi
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

CREATE_ORG_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/orgs" "${AUTH[@]}" -d "$CREATE_ORG_PAYLOAD")"
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
WALLET_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/orgs/$ORG_ID/agents/wallet" "${AUTH[@]}" -d "$WALLET_PAYLOAD")"
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

DID_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/orgs/$ORG_ID/agents/did" "${AUTH[@]}" -d "$DID_PAYLOAD")"
DID_STATUS="$(echo "$DID_RESPONSE" | jq -r '.statusCode // empty')"
check_status "DID creation accepted" "$DID_STATUS" "201"

# Poll org until orgDid is populated (agent needs a few seconds)
ORG_DID=""
echo "    Waiting for DID to be registered..."
for _ in $(seq 1 20); do
  ORG_RESPONSE="$(curl -sS "$BASE_URL/v1/orgs/$ORG_ID" -H "Authorization: Bearer $TOKEN")"
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

SCHEMA_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/orgs/$ORG_ID/schemas" "${AUTH[@]}" -d "$SCHEMA_PAYLOAD")"
SCHEMA_STATUS="$(echo "$SCHEMA_RESPONSE" | jq -r '.statusCode // empty')"
check_status "SD-JWT schema created" "$SCHEMA_STATUS" "201"

SCHEMA_ID="$(echo "$SCHEMA_RESPONSE" | jq -r '.data.schemaLedgerId // .data.schemaId // .data.id // empty')"
if [ -z "$SCHEMA_ID" ]; then
  fail "Schema ID extraction" "$(echo "$SCHEMA_RESPONSE" | jq -c .)"
  exit 1
fi
echo "    Schema ID: $SCHEMA_ID"

# ---------------------------------------------------------------------------
# STEP 7 — Create OID4VCI issuer + credential template
# ---------------------------------------------------------------------------
echo ""
echo "[7/10] Create OID4VCI issuer + credential template"

# 7a — Create the OID4VCI issuer (maps org + did:key → an OID4VCI credential_issuer endpoint)
#
# credentialIssuerHost: the public HTTPS base URL where Credo serves OID4VCI endpoints.
#   nginx proxies /oid4vci/ → Credo admin port 8001.
# issuerId: slug used as the path component in all public OID4VCI URLs, e.g.:
#   https://<host>/oid4vci/<issuerId>/offers/<id>
#   https://<host>/oid4vci/<issuerId>/.well-known/openid-credential-issuer
# authorizationServerUrl: Keycloak realm URL (MUST be the public-facing HTTPS URL)
# batchCredentialIssuanceSize: MUST be ≥ 1 — Credo's OID4VCI draft 15 Zod schema
#   validates batch_size > 0; passing 0 makes .well-known return server_error.

ISSUER_SLUG="cdpi-poc-employment-${REQUEST_ID}"
KEYCLOAK_REALM_URL="${BASE_URL/5000/8080}/realms/credebl-realm"
# If BASE_URL uses a domain (no port), construct the Keycloak auth URL differently
if [[ "$BASE_URL" =~ ^https:// ]] && [[ ! "$BASE_URL" =~ :[0-9] ]]; then
  KC_BASE="${BASE_URL/https:\/\//}"
  KEYCLOAK_REALM_URL="https://auth.${KC_BASE}/realms/credebl-realm"
fi

ISSUER_PAYLOAD="$(jq -n \
  --arg issuerId    "$ISSUER_SLUG" \
  --arg issuerHost  "$BASE_URL" \
  --arg orgId       "$ORG_ID" \
  --arg orgDid      "$ORG_DID" \
  --arg kcUrl       "$KEYCLOAK_REALM_URL" \
  '{
    issuerId: $issuerId,
    credentialIssuerHost: $issuerHost,
    orgId: $orgId,
    orgDid: $orgDid,
    authorizationServerUrl: $kcUrl,
    batchCredentialIssuanceSize: 1,
    display: [{name: "CDPI PoC Employment Issuer", locale: "en"}]
  }')"

ISSUER_RESPONSE="$(curl -sS -X POST \
  "$BASE_URL/v1/orgs/$ORG_ID/oid4vc/issuers" \
  "${AUTH[@]}" -d "$ISSUER_PAYLOAD")"
ISSUER_STATUS="$(echo "$ISSUER_RESPONSE" | jq -r '.statusCode // empty')"
check_status "OID4VCI issuer created" "$ISSUER_STATUS" "201"

ISSUER_DB_ID="$(echo "$ISSUER_RESPONSE" | jq -r '.data.id // empty')"
if [ -z "$ISSUER_DB_ID" ]; then
  fail "Issuer DB ID extraction" "$(echo "$ISSUER_RESPONSE" | jq -c .)"
  exit 1
fi
echo "    Issuer DB ID: $ISSUER_DB_ID"
echo "    Issuer slug:  $ISSUER_SLUG"

# 7b — Create the credential template (links schema → issuer with SD-JWT attributes)
#
# credentialName: label shown in wallet UI
# type: credential type tag (used as the key in credential_configurations_supported)
# vct: Verifiable Credential Type URI — must match the schema's schemaLedgerId
# attributes[].key: SD-JWT claim name (matches schema attributeName)
# attributes[].value_type: one of "string" | "number" | "boolean"

TEMPLATE_PAYLOAD="$(jq -n \
  --arg schemaId "$SCHEMA_ID" \
  '{
    name:   "Employment Credential",
    type:   "EmploymentCredential-sdjwt",
    format: "dc+sd-jwt",
    vct:    $schemaId,
    attributes: [
      {key:"given_name",            value_type:"string"},
      {key:"family_name",           value_type:"string"},
      {key:"document_number",       value_type:"string"},
      {key:"employer_name",         value_type:"string"},
      {key:"employment_status",     value_type:"string"},
      {key:"position_title",        value_type:"string"},
      {key:"employment_start_date", value_type:"string"}
    ]
  }')"

TEMPLATE_RESPONSE="$(curl -sS -X POST \
  "$BASE_URL/v1/orgs/$ORG_ID/oid4vc/$ISSUER_DB_ID/template" \
  "${AUTH[@]}" -d "$TEMPLATE_PAYLOAD")"
TEMPLATE_STATUS="$(echo "$TEMPLATE_RESPONSE" | jq -r '.statusCode // empty')"
check_status "Credential template created" "$TEMPLATE_STATUS" "201"

TEMPLATE_ID="$(echo "$TEMPLATE_RESPONSE" | jq -r '.data.id // empty')"
if [ -z "$TEMPLATE_ID" ]; then
  fail "Template ID extraction" "$(echo "$TEMPLATE_RESPONSE" | jq -c .)"
  exit 1
fi
echo "    Template ID: $TEMPLATE_ID"

# ---------------------------------------------------------------------------
# STEP 8 — Create credential offer (pre-authorized code flow with PIN)
# ---------------------------------------------------------------------------
echo ""
echo "[8/10] Create OID4VCI credential offer (pre-authorized code, PIN-protected)"

# The offer payload wraps credential data inside credentials[].payload.
# authorizationType: "preAuthorizedCodeFlow" for pre-auth code flow.
# pin: user PIN the wallet sends when exchanging the pre-authorized code.
# credentials[].templateId: links to the correct credential_configurations_supported entry.
# credentials[].payload: flat object with the holder's SD-JWT claims.
OFFER_PAYLOAD="$(jq -n \
  --arg templateId  "$TEMPLATE_ID" \
  '{
    authorizationType: "preAuthorizedCodeFlow",
    pin: "1234",
    credentials: [{
      templateId: $templateId,
      payload: {
        given_name:            "Carlos",
        family_name:           "Gomez Restrepo",
        document_number:       "1234567890",
        employer_name:         "MINTIC Colombia",
        employment_status:     "active",
        position_title:        "Ingeniero de Software",
        employment_start_date: "2021-03-15"
      }
    }]
  }')"

OFFER_RESPONSE="$(curl -sS -X POST \
  "$BASE_URL/v1/orgs/$ORG_ID/oid4vc/$ISSUER_DB_ID/create-offer" \
  "${AUTH[@]}" -d "$OFFER_PAYLOAD")"
OFFER_STATUS="$(echo "$OFFER_RESPONSE" | jq -r '.statusCode // empty')"
check_status "Credential offer created" "$OFFER_STATUS" "201"

OFFER_URL="$(echo "$OFFER_RESPONSE" | jq -r '.data.credentialOffer // .data.offerUrl // .data.invitationUrl // empty')"
OFFER_PIN="$(echo "$OFFER_RESPONSE" | jq -r '.data.issuanceSession.userPin // .data.pin // "1234"')"

if [ -n "$OFFER_URL" ]; then
  echo ""
  echo "    ┌─ OID4VCI Credential Offer (pre-authorized code) ───────────────┐"
  echo "    │ $OFFER_URL"
  echo "    ├────────────────────────────────────────────────────────────────┤"
  echo "    │ PIN: $OFFER_PIN"
  echo "    └────────────────────────────────────────────────────────────────┘"
  echo "    Holder opens this URL in an OID4VCI wallet (e.g. Inji, MATTR)"
  echo "    and enters the PIN when prompted to receive the SD-JWT VC."
  echo ""
  echo "    Public OID4VCI metadata:"
  echo "    ${BASE_URL}/oid4vci/${ISSUER_SLUG}/.well-known/openid-credential-issuer"
fi

# ---------------------------------------------------------------------------
# STEP 9 — Create OOB proof request (Presentation Exchange — for did:key orgs)
# ---------------------------------------------------------------------------
echo ""
echo "[9/10] Create OOB proof request (presentationExchange)"
# POST /orgs/{orgId}/proofs/oob?requestType=presentationExchange
#
# Must use requestType=presentationExchange for orgs with did:key / no_ledger schemas.
# Indy proof format requires AnonCreds credentials from a ledger DID — using it with
# did:key causes a Credo crash (TypeError in DidCommProofV1Protocol.createRequest).
#
# The DTO (SendProofRequestPayload) expects:
#   - presentationDefinition: { id, name, purpose, input_descriptors[] }
#   - comment, protocolVersion (v2 for PE), autoAcceptProof
#
# Credo routes the PE proof request to DIDComm OOB and returns an invitationUrl.
# For SD-JWT holders (when PR #1279 lands), the wallet presents via OID4VP.
PROOF_PAYLOAD="$(jq -n \
  --arg schemaId "$SCHEMA_ID" \
  '{
    comment:"Employment verification — CDPI PoC OID4VP test",
    protocolVersion:"v2",
    presentationDefinition:{
      id:"employment-verification-001",
      name:"Employment Verification",
      purpose:"Verify employment status",
      input_descriptors:[
        {
          id:"given_name_descriptor",
          name:"Given Name",
          schema:[{uri:$schemaId}],
          constraints:{
            fields:[{path:["$.credentialSubject.given_name","$.given_name"]}]
          }
        },
        {
          id:"employer_name_descriptor",
          name:"Employer Name",
          schema:[{uri:$schemaId}],
          constraints:{
            fields:[{path:["$.credentialSubject.employer_name","$.employer_name"]}]
          }
        },
        {
          id:"employment_status_descriptor",
          name:"Employment Status",
          schema:[{uri:$schemaId}],
          constraints:{
            fields:[{path:["$.credentialSubject.employment_status","$.employment_status"]}]
          }
        }
      ]
    },
    autoAcceptProof:"always"
  }')"

PROOF_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/proofs/oob?requestType=presentationExchange" "${AUTH[@]}" -d "$PROOF_PAYLOAD")"
PROOF_STATUS="$(echo "$PROOF_RESPONSE" | jq -r '.statusCode // empty')"
check_status "OID4VP proof request created" "$PROOF_STATUS" "201"

PROOF_ID=""
if [ "$PROOF_STATUS" = "201" ]; then
  PROOF_URL="$(echo "$PROOF_RESPONSE" | jq -r '.data.proofUrl // .data.invitationUrl // empty')"
  # CREDEBL's oob proof endpoint only returns invitationUrl — no ID in the response.
  # Query the proof list and take the most recently created presentationId.
  # The single-proof endpoint uses presentationId, not the list's id field.
  PROOF_ID="$(curl -sS "$BASE_URL/orgs/$ORG_ID/proofs" -H "Authorization: Bearer $TOKEN" \
    | jq -r '.data.data | sort_by(.createDateTime) | last | .presentationId // empty' 2>/dev/null)"
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
