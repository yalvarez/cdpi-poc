#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — INJI OID4VCI E2E test (eSignet authorization + Certify credential)
# -----------------------------------------------------------------------------
# Validates the full INJI OID4VCI flow end-to-end via API:
#
#   Phase 1: Infrastructure (6 checks)
#     1. All 10 service containers healthy/running
#     2. eSignet OIDC discovery (.well-known/openid-configuration)
#     3. Certify OID4VCI issuer metadata (.well-known/openid-credential-issuer)
#     4. Mock identity system health
#     5. Mimoto health
#     6. Inji Web reachability
#
#   Phase 2: eSignet authorization flow (4 steps)
#     7. oauth-details   → get transactionId (client lookup via client_detail table)
#     8. send-otp        → send OTP to test UIN via mock-identity-system
#     9. authenticate    → verify OTP + get updated transactionId
#    10. auth-code       → consent claims, get authorization_code
#
#   Phase 3: Token + Credential (2 steps)
#    11. Token exchange  → POST /oauth/v2/token (private_key_jwt client auth)
#    12. Credential      → POST /v1/certify/issuance/credential (VC + sd-jwt)
#
# Usage:
#   bash inji/docs/api-test-inji.sh
#
# Required vars (auto-read from inji/.env if present):
#   VPS_IP                    — public IP or hostname of the VPS
#   CERTIFY_KEYSTORE_PASSWORD — PKCS12 keystore password (from .credentials-report)
#
# The script needs access to inji/certs/oidckeystore.p12 for token signing.
# Run from the repo root on the VPS or from any machine that has the keystore.
#
# Prerequisites:
#   - INJI stack running (init-inji.sh completed)
#   - inji-certify-client registered in eSignet (done by init-inji.sh)
#   - Python 3 + openssl in PATH
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Load inji/.env if present
# ---------------------------------------------------------------------------
ENV_FILE="inji/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Z_]+=' "$ENV_FILE")
  set +a
  # Map PUBLIC_URL → VPS_IP
  if [ -z "${VPS_IP:-}" ] && [ -n "${PUBLIC_URL:-}" ]; then
    VPS_IP="${PUBLIC_URL#http://}"
    VPS_IP="${VPS_IP#https://}"
  fi
fi

# ---------------------------------------------------------------------------
# Prompt for missing required variables
# ---------------------------------------------------------------------------
ask_if_missing() {
  local var="$1" prompt="$2" val
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    read -rp "$prompt: " val
    export "$var"="$val"
  fi
}

ask_if_missing "VPS_IP"                    "VPS public IP or hostname (e.g. 161.97.152.40)"
ask_if_missing "CERTIFY_KEYSTORE_PASSWORD" "Certify keystore password (from inji/.credentials-report)"

ESIGNET_BASE="http://${VPS_IP}:8088"
CERTIFY_BASE="http://${VPS_IP}:8091"
MIMOTO_BASE="http://${VPS_IP}:8099"
MOCK_ID_BASE="http://${VPS_IP}:8082"
INJI_WEB_BASE="http://${VPS_IP}:3001"

KEYSTORE="inji/certs/oidckeystore.p12"
KS_PASS="${CERTIFY_KEYSTORE_PASSWORD}"

TEST_UIN="5860356276"
TEST_OTP="111111"
CLIENT_ID="inji-certify-client"
REDIRECT_URI="http://${VPS_IP}:3001/home"

PASS=0; FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pass()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail()  { echo "  ✗ $1"; echo "    ${2:-}" | head -c 300; echo; FAIL=$((FAIL + 1)); }

check_http() {
  local label="$1" url="$2" expected="${3:-200}"
  local code
  code=$(curl -so /dev/null -w "%{http_code}" "$url" 2>/dev/null) || code="ERR"
  if [ "$code" = "$expected" ]; then
    pass "$label (HTTP $code)"
  else
    fail "$label" "Expected HTTP $expected, got: $code"
  fi
}

req_time() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }

# Fetch a CSRF token cookie from eSignet
get_xsrf() {
  local jar="$1"
  curl -sc "$jar" "${ESIGNET_BASE}/oidc/.well-known/openid-configuration" >/dev/null 2>&1
  grep -o 'XSRF-TOKEN[[:space:]]*[^[:space:]]*' "$jar" 2>/dev/null | awk '{print $NF}' || echo ""
}

esignet_post() {
  local endpoint="$1" body="$2"
  local jar="/tmp/inji_test_cookies_$$"
  local xsrf
  xsrf=$(get_xsrf "$jar")
  # Use -s (silent) without -f so non-2xx responses are captured rather than
  # causing curl to exit with code 22, which would kill the script via set -e.
  curl -s -X POST "${ESIGNET_BASE}${endpoint}" \
    -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: ${xsrf}" \
    -b "XSRF-TOKEN=${xsrf}" \
    -d "$body" 2>/dev/null || true
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   CDPI PoC — INJI OID4VCI E2E Test                          ║"
printf "║   eSignet: %-50s║\n" "$ESIGNET_BASE"
printf "║   Certify: %-50s║\n" "$CERTIFY_BASE"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ===========================================================================
# PHASE 1 — Infrastructure
# ===========================================================================

echo "── Phase 1: Infrastructure ──────────────────────────────────────"
echo ""

# 1 — Container health
echo "[1/12] Container health"
CONTAINERS=(postgres redis mock-identity-system esignet inji-certify certify-nginx
            mimoto-config-server mimoto inji-web mailpit)
ALL_HEALTHY=true
for svc in "${CONTAINERS[@]}"; do
  STATUS=$(docker compose -f inji/docker-compose.yml ps "$svc" 2>/dev/null | tail -1)
  if echo "$STATUS" | grep -qE "(healthy)|(Up)|(running)"; then
    echo "    ✓ $svc"
  else
    echo "    ✗ $svc — $(echo "$STATUS" | awk '{print $NF}')"
    ALL_HEALTHY=false
  fi
done
if $ALL_HEALTHY; then pass "All INJI containers healthy/running"
else fail "Some containers not healthy — check logs above"; fi

echo ""

# 2 — eSignet OIDC discovery
echo "[2/12] eSignet OIDC discovery"
OIDC_META=$(curl -sf "${ESIGNET_BASE}/oidc/.well-known/openid-configuration" 2>/dev/null) || OIDC_META=""
if [ -n "$OIDC_META" ]; then
  ISSUER=$(echo "$OIDC_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer','?'))" 2>/dev/null)
  TOKEN_ENDPOINT=$(echo "$OIDC_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token_endpoint','?'))" 2>/dev/null)
  pass "eSignet OIDC discovery OK"
  echo "    issuer:         $ISSUER"
  echo "    token_endpoint: $TOKEN_ENDPOINT"
else
  fail "eSignet OIDC discovery" "No response from ${ESIGNET_BASE}/oidc/.well-known/openid-configuration"
  TOKEN_ENDPOINT="http://${VPS_IP}/v1/esignet/oauth/v2/token"
fi

echo ""

# 3 — Certify OID4VCI metadata
echo "[3/12] Certify OID4VCI issuer metadata"
VCI_META=$(curl -sf "${CERTIFY_BASE}/v1/certify/.well-known/openid-credential-issuer" 2>/dev/null) || VCI_META=""
if [ -n "$VCI_META" ]; then
  CREDENTIAL_ENDPOINT=$(echo "$VCI_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('credential_endpoint','?'))" 2>/dev/null)
  CRED_ISSUER=$(echo "$VCI_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('credential_issuer','?'))" 2>/dev/null)
  pass "Certify OID4VCI metadata OK"
  echo "    credential_issuer:   $CRED_ISSUER"
  echo "    credential_endpoint: $CREDENTIAL_ENDPOINT"
  # Rewrite hostname to VPS_IP:8091 for direct access
  CREDENTIAL_ENDPOINT="http://${VPS_IP}:8091/v1/certify/issuance/credential"
else
  fail "Certify OID4VCI metadata" "No response from ${CERTIFY_BASE}/v1/certify/.well-known/openid-credential-issuer"
  CREDENTIAL_ENDPOINT="http://${VPS_IP}:8091/v1/certify/issuance/credential"
fi

echo ""

# 4-6 — Service reachability
echo "[4/12] Mock identity system health"
check_http "Mock identity system" "${MOCK_ID_BASE}/v1/mock-identity-system/actuator/health"

echo ""
echo "[5/12] Mimoto health"
MIMOTO_CODE=$(curl -so /dev/null -w "%{http_code}" "${MIMOTO_BASE}/v1/mimoto/actuator/health" 2>/dev/null) || MIMOTO_CODE="ERR"
if [ "$MIMOTO_CODE" = "200" ] || [ "$MIMOTO_CODE" = "401" ]; then
  pass "Mimoto health endpoint reachable (HTTP $MIMOTO_CODE)"
else
  fail "Mimoto health" "Expected 200/401, got: $MIMOTO_CODE"
fi

echo ""
echo "[6/12] Inji Web reachability"
check_http "Inji Web" "${INJI_WEB_BASE}"

echo ""

# ===========================================================================
# PHASE 2 — eSignet authorization flow
# ===========================================================================

echo "── Phase 2: eSignet authorization flow ──────────────────────────"
echo ""

# 7 — oauth-details
echo "[7/12] oauth-details (client lookup → transactionId)"
OAUTH_BODY=$(python3 -c "
import json, sys
print(json.dumps({
  'requestTime': '$(req_time)',
  'request': {
    'clientId': '${CLIENT_ID}',
    'redirectUri': '${REDIRECT_URI}',
    'responseType': 'code',
    'scope': 'openid profile EmploymentCertification',
    'acrValues': 'mosip:idp:acr:generated-code',
    'display': 'page',
    'prompt': 'login',
    'nonce': 'test-nonce-$(date +%s)',
    'state': 'test-state-$(date +%s)',
    'claimsLocales': 'en',
    'claims': {
      'userinfo': {'name': {'essential': True}, 'email': {'essential': False}},
      'id_token': {}
    }
  }
}))")

OAUTH_RESP=$(esignet_post "/authorization/oauth-details" "$OAUTH_BODY")
TRANSACTION_ID=$(echo "$OAUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('transactionId',''))" 2>/dev/null) || TRANSACTION_ID=""

if [ -n "$TRANSACTION_ID" ]; then
  pass "oauth-details → transactionId obtained"
  echo "    transactionId: $TRANSACTION_ID"
else
  fail "oauth-details" "$(echo "$OAUTH_RESP" | head -c 300)"
  echo ""
  echo "    Remaining steps require a valid transactionId — skipping Phase 2+3."
  SKIP_PHASE2=true
fi

SKIP_PHASE2="${SKIP_PHASE2:-false}"

echo ""

# 8 — send-otp
if ! $SKIP_PHASE2; then
echo "[8/12] send-otp (UIN: $TEST_UIN)"
OTP_BODY=$(python3 -c "
import json
print(json.dumps({
  'requestTime': '$(req_time)',
  'request': {
    'transactionId': '${TRANSACTION_ID}',
    'individualId': '${TEST_UIN}',
    'otpChannels': ['email']
  }
}))")

OTP_RESP=$(esignet_post "/authorization/send-otp" "$OTP_BODY")
OTP_STATUS=$(echo "$OTP_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('status',''))" 2>/dev/null) || OTP_STATUS=""

if [ "$OTP_STATUS" = "SUCCESS" ] || echo "$OTP_RESP" | grep -q '"status":"SUCCESS"'; then
  pass "send-otp → OTP sent to UIN $TEST_UIN"
else
  fail "send-otp" "$(echo "$OTP_RESP" | head -c 300)"
fi

echo ""

# 9 — authenticate
echo "[9/12] authenticate (OTP: $TEST_OTP)"
AUTH_BODY=$(python3 -c "
import json
print(json.dumps({
  'requestTime': '$(req_time)',
  'request': {
    'transactionId': '${TRANSACTION_ID}',
    'individualId': '${TEST_UIN}',
    'challengeList': [
      {'authFactorType': 'OTP', 'challenge': '${TEST_OTP}', 'format': 'alpha-numeric'}
    ]
  }
}))")

AUTH_RESP=$(esignet_post "/authorization/authenticate" "$AUTH_BODY")
NEW_TX_ID=$(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('transactionId',''))" 2>/dev/null) || NEW_TX_ID=""

if [ -n "$NEW_TX_ID" ]; then
  pass "authenticate → transactionId refreshed"
  echo "    new transactionId: $NEW_TX_ID"
  TRANSACTION_ID="$NEW_TX_ID"
else
  fail "authenticate" "$(echo "$AUTH_RESP" | head -c 300)"
  SKIP_PHASE2=true
fi

echo ""

# 10 — auth-code
if ! $SKIP_PHASE2; then
echo "[10/12] auth-code (consent → authorization_code)"
AUTHCODE_BODY=$(python3 -c "
import json
print(json.dumps({
  'requestTime': '$(req_time)',
  'request': {
    'transactionId': '${TRANSACTION_ID}',
    'acceptedClaims': ['name', 'email'],
    'permittedAuthorizeScopes': ['openid', 'profile', 'EmploymentCertification']
  }
}))")

AUTHCODE_RESP=$(esignet_post "/authorization/auth-code" "$AUTHCODE_BODY")
AUTH_CODE=$(echo "$AUTHCODE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('code',''))" 2>/dev/null) || AUTH_CODE=""

if [ -n "$AUTH_CODE" ]; then
  pass "auth-code → authorization_code obtained"
  echo "    code: ${AUTH_CODE:0:40}..."
else
  fail "auth-code" "$(echo "$AUTHCODE_RESP" | head -c 300)"
  SKIP_PHASE2=true
fi

echo ""
fi  # skip after authenticate
fi  # skip phase 2

# ===========================================================================
# PHASE 3 — Token + Credential
# ===========================================================================

echo "── Phase 3: Token + Credential ──────────────────────────────────"
echo ""

SKIP_PHASE3="${SKIP_PHASE2:-false}"

# 11 — Token exchange
echo "[11/12] Token exchange (private_key_jwt)"

if $SKIP_PHASE3; then
  fail "Token exchange" "Skipped — Phase 2 did not complete"
elif [ -z "${AUTH_CODE:-}" ]; then
  fail "Token exchange" "No authorization_code from step 10"
else

if [ ! -f "$KEYSTORE" ]; then
  fail "Token exchange" "Keystore not found: $KEYSTORE — run from repo root on the VPS"
  SKIP_PHASE3=true
else

# Build private_key_jwt using Python + openssl
JWT_ASSERTION=$(python3 - "$KEYSTORE" "$KS_PASS" "$TOKEN_ENDPOINT" <<'PYEOF'
import subprocess, base64, json, sys, time, uuid, tempfile, os

ks, pw, token_ep = sys.argv[1], sys.argv[2], sys.argv[3]

# Extract private key PEM from PKCS12
key_pem = subprocess.run(
    ['openssl','pkcs12','-in',ks,'-nocerts','-nodes','-passin','pass:'+pw],
    capture_output=True).stdout

# JWT header + payload
header_dict = {"alg": "RS256", "typ": "JWT"}
now = int(time.time())
payload_dict = {
    "iss": "inji-certify-client",
    "sub": "inji-certify-client",
    "aud": token_ep,
    "iat": now,
    "exp": now + 300,
    "jti": str(uuid.uuid4())
}

def b64url(data):
    if isinstance(data, str): data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header_b64  = b64url(json.dumps(header_dict, separators=(',',':')))
payload_b64 = b64url(json.dumps(payload_dict, separators=(',',':')))
signing_input = (header_b64 + '.' + payload_b64).encode()

# Write key to temp file and sign
with tempfile.NamedTemporaryFile(delete=False, suffix='.pem', mode='wb') as f:
    f.write(key_pem)
    key_file = f.name

try:
    sig_bytes = subprocess.run(
        ['openssl','dgst','-sha256','-sign', key_file],
        input=signing_input, capture_output=True).stdout
    sig_b64 = b64url(sig_bytes)
finally:
    os.unlink(key_file)

print(header_b64 + '.' + payload_b64 + '.' + sig_b64)
PYEOF
) 2>/dev/null || JWT_ASSERTION=""

if [ -z "$JWT_ASSERTION" ]; then
  fail "Token exchange" "Failed to build private_key_jwt — check keystore path and password"
  SKIP_PHASE3=true
else

JAR="/tmp/inji_token_jar_$$"
XSRF=$(get_xsrf "$JAR")

TOKEN_RESP=$(curl -s -X POST "${ESIGNET_BASE}/oauth/v2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-XSRF-TOKEN: ${XSRF}" \
  -b "XSRF-TOKEN=${XSRF}" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${AUTH_CODE}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${JWT_ASSERTION}" 2>/dev/null) || TOKEN_RESP=""

ACCESS_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || ACCESS_TOKEN=""

if [ -n "$ACCESS_TOKEN" ]; then
  TOKEN_TYPE=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token_type','Bearer'))" 2>/dev/null)
  pass "Token exchange → access_token obtained (type: $TOKEN_TYPE)"
  echo "    access_token: ${ACCESS_TOKEN:0:40}..."
else
  fail "Token exchange" "$(echo "$TOKEN_RESP" | head -c 300)"
  SKIP_PHASE3=true
fi

fi  # JWT assertion OK
fi  # keystore exists
fi  # skip phase 3 / no auth code

echo ""

# 12 — Credential request
echo "[12/12] Credential request (vc+sd-jwt)"

if $SKIP_PHASE3; then
  fail "Credential request" "Skipped — prior steps did not complete"
elif [ -z "${ACCESS_TOKEN:-}" ]; then
  fail "Credential request" "No access_token from step 11"
else

CRED_RESP=$(curl -s -X POST "$CREDENTIAL_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d '{"format":"vc+sd-jwt","credential_definition":{"type":["VerifiableCredential","EmploymentCertification"]}}' 2>/dev/null) || CRED_RESP=""

CREDENTIAL=$(echo "$CRED_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('credential',''))" 2>/dev/null) || CREDENTIAL=""

if [ -n "$CREDENTIAL" ]; then
  CRED_FORMAT=$(echo "$CRED_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('format','?'))" 2>/dev/null)
  pass "Credential issued (format: $CRED_FORMAT)"
  echo "    credential: ${CREDENTIAL:0:80}..."
  echo ""
  echo "    ┌─ Verifiable Credential (SD-JWT) ──────────────────────────┐"
  echo "    │ Format: $CRED_FORMAT"
  # Count disclosures (parts separated by ~)
  DISC_COUNT=$(echo "$CREDENTIAL" | tr '~' '\n' | wc -l)
  echo "    │ Disclosures: $((DISC_COUNT - 1)) selective disclosure(s)"
  echo "    └────────────────────────────────────────────────────────────┘"
else
  fail "Credential request" "$(echo "$CRED_RESP" | head -c 300)"
fi

fi  # skip phase 3

echo ""

# ===========================================================================
# Summary
# ===========================================================================

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
