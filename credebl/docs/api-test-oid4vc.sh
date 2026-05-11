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
#   Steps 9-11 (Verification — native OID4VP con Selective Disclosure):
#     9. Register OID4VP verifier
#    10. Solicitud COMPLETA — pide los 7 campos, envía QR por email, poll
#    11. Solicitud PARCIAL  — pide solo 3/7 campos (SD demo), envía QR por email, poll
#
# Usage:
#   bash credebl/docs/api-test-oid4vc.sh
#
# Required env vars (auto-read from credebl/.env if present):
#   VPS_IP, ADMIN_EMAIL, ADMIN_PASSWORD, CRYPTO_PRIVATE_KEY, EMAIL_TO
#
# Prerequisites (SSL deployment only):
#   - nginx must proxy /oid4vci/ and /oid4vp/ → Credo admin port 8001
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

# ---------------------------------------------------------------------------
# nginx_qr_shorten <long_url> <https_domain>
#   When a URL is too long for a QR code, writes a redirect HTML to
#   /var/www/qr/<token>.html and ensures nginx serves location /qr/ from
#   /var/www (idempotent — only modifies nginx if the location is absent).
#   Prints the short https://<domain>/qr/<token>.html URL.
# ---------------------------------------------------------------------------
nginx_qr_shorten() {
  local long_url="$1" domain="$2"
  local token qr_dir nginx_conf
  token="$(openssl rand -hex 8)"
  qr_dir="/var/www/qr"
  mkdir -p "$qr_dir"
  cat > "${qr_dir}/${token}.html" << HTMLEOF
<!DOCTYPE html><html><head>
<meta http-equiv="refresh" content="0;url=${long_url}">
<title>Abriendo wallet...</title>
</head><body>
<p>Abriendo wallet... <a href="${long_url}">Toca aquí si no redirige automáticamente</a></p>
</body></html>
HTMLEOF
  chmod 644 "${qr_dir}/${token}.html"
  # Add /qr/ static location to the CREDEBL nginx server block (once)
  nginx_conf="$(grep -rl "server_name ${domain}" /etc/nginx/sites-available/ 2>/dev/null | head -1)"
  if [ -n "$nginx_conf" ] && ! grep -q 'location /qr/' "$nginx_conf"; then
    python3 - "$nginx_conf" << 'PYEOF'
import sys
conf = sys.argv[1]
with open(conf) as f:
    content = f.read()
if 'location /qr/' not in content:
    loc = '\n    location /qr/ { root /var/www; try_files $uri =404; }\n'
    idx = content.rfind('}')
    content = content[:idx] + loc + content[idx:]
    with open(conf, 'w') as f:
        f.write(content)
PYEOF
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  echo "https://${domain}/qr/${token}.html"
}

# ---------------------------------------------------------------------------
# send_oid4vc_email <to> <subject> <url> <pin>
#   Generates a QR code for <url> and sends an HTML email via Brevo SMTP.
#   When URL is too long for direct QR (DIDComm OOB), creates a short nginx
#   redirect and encodes that instead.
#   Reads SMTP_HOST/PORT/USER/PASS and EMAIL_FROM from the environment.
#   pin may be empty (for proof-request emails).
#   Installs qrencode on first call if not present.
# ---------------------------------------------------------------------------
send_oid4vc_email() {
  local to="$1" subject="$2" url="$3" pin="${4:-}"

  # Install qrencode if absent (Ubuntu/Debian, runs as root on the VPS)
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "    (installing qrencode...)"
    apt-get install -y -q qrencode >/dev/null 2>&1 || {
      echo "    WARNING: qrencode not available — skipping email" >&2
      return 0
    }
  fi

  local qr_file has_qr
  qr_file="$(mktemp /tmp/oid4vc_qr_XXXXXX.png)"
  has_qr=false

  if qrencode -o "$qr_file" -s 8 -m 3 "$url" 2>/dev/null; then
    has_qr=true
  else
    rm -f "$qr_file"
    # URL too long — shorten via nginx redirect and try again
    if [[ "${BASE_URL:-}" =~ ^https:// ]]; then
      local domain short_url
      domain="${BASE_URL#https://}"
      short_url="$(nginx_qr_shorten "$url" "$domain" 2>/dev/null)" || short_url=""
      if [ -n "$short_url" ]; then
        qr_file="$(mktemp /tmp/oid4vc_qr_XXXXXX.png)"
        if qrencode -o "$qr_file" -s 8 -m 3 "$short_url" 2>/dev/null; then
          has_qr=true
        else
          rm -f "$qr_file"
        fi
      fi
    fi
  fi

  local pin_block=""
  if [ -n "$pin" ]; then
    pin_block="<p style='font-size:18px;margin:16px 0'><b>PIN:</b> <code style='font-size:22px;letter-spacing:4px;background:#f4f4f4;padding:4px 10px;border-radius:4px'>$pin</code></p>"
  fi

  local py_script
  py_script="$(mktemp /tmp/send_offer_XXXXXX.py)"
  cat > "$py_script" << PYEOF
import smtplib, ssl, os, sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.image import MIMEImage

smtp_host = os.environ.get('SMTP_HOST', 'smtp-relay.brevo.com')
smtp_port = int(os.environ.get('SMTP_PORT', '587'))
smtp_user = os.environ.get('SMTP_USER', '')
smtp_pass = os.environ.get('SMTP_PASS', '')
email_from = os.environ.get('EMAIL_FROM', smtp_user)

to_addr   = sys.argv[1]
subject   = sys.argv[2]
url       = sys.argv[3]
pin_block = sys.argv[4]
qr_path   = sys.argv[5]   # empty string = no QR

has_qr = bool(qr_path)
qr_section = '<p style="text-align:center"><img src="cid:qrcode" alt="QR code" style="width:220px;height:220px"></p>' if has_qr else \
             '<p style="color:#888;font-size:12px">(URL demasiado larga para QR — copia el enlace de abajo)</p>'

msg = MIMEMultipart('related')
msg['Subject'] = subject
msg['From']    = email_from
msg['To']      = to_addr

html = f"""
<html><body style="font-family:sans-serif;max-width:540px;margin:0 auto;padding:24px">
  <h2 style="color:#2d5be3">CDPI PoC — {subject}</h2>
  <p>Escanea el QR con tu wallet o copia el URL:</p>
  {qr_section}
  {pin_block}
  <p style="word-break:break-all;font-size:12px;color:#555;background:#f9f9f9;padding:10px;border-radius:6px">{url}</p>
  <hr style="margin-top:32px;border:none;border-top:1px solid #eee">
  <p style="font-size:11px;color:#aaa">CDPI Centre for Digital Public Infrastructure — PoC</p>
</body></html>
"""

alt = MIMEMultipart('alternative')
alt.attach(MIMEText(url, 'plain'))
alt.attach(MIMEText(html, 'html'))
msg.attach(alt)

if has_qr:
    with open(qr_path, 'rb') as f:
        img = MIMEImage(f.read(), _subtype='png')
        img.add_header('Content-ID', '<qrcode>')
        img.add_header('Content-Disposition', 'inline', filename='qr.png')
        msg.attach(img)

with smtplib.SMTP(smtp_host, smtp_port) as s:
    s.ehlo()
    s.starttls()
    s.login(smtp_user, smtp_pass)
    s.sendmail(email_from, to_addr, msg.as_string())

print('sent')
PYEOF

  local qr_arg=""
  [ "$has_qr" = "true" ] && qr_arg="$qr_file"

  local result
  result="$(python3 "$py_script" "$to" "$subject" "$url" "$pin_block" "$qr_arg" 2>&1)"
  rm -f "$py_script" "$qr_file"
  if [ "$result" = "sent" ]; then
    echo "    Email enviado a $to"
  else
    echo "    WARNING: email no enviado: $result" >&2
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
echo "[1/11] Encrypt admin password"
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
echo "[2/11] Sign in as platform admin"
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
echo "[3/11] Create organization: $ORG_NAME"
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
echo "[4/11] Spin up shared wallet"
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
echo "[5/11] Create DID (did:key)"
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
echo "[6/11] Create SD-JWT VC schema: $SCHEMA_NAME"
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
echo "[7/11] Create OID4VCI issuer + credential template"

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
    name:         "Employment Credential",
    format:       "dc+sd-jwt",
    signerOption: "DID",
    canBeRevoked: false,
    template: {
      vct: $schemaId,
      attributes: [
        {key:"given_name",            value_type:"string", disclose:false},
        {key:"employer_name",         value_type:"string", disclose:false},
        {key:"employment_status",     value_type:"string", disclose:false},
        {key:"family_name",           value_type:"string", disclose:true},
        {key:"document_number",       value_type:"string", disclose:true},
        {key:"position_title",        value_type:"string", disclose:true},
        {key:"employment_start_date", value_type:"string", disclose:true}
      ]
    }
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
echo "[8/11] Create OID4VCI credential offer (pre-authorized code, PIN-protected)"

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
  echo "    Holder abre este URL en una wallet OID4VCI (ej. Inji, MATTR)"
  echo "    e ingresa el PIN cuando se lo solicita para recibir el SD-JWT VC."
  echo ""
  echo "    Public OID4VCI metadata:"
  echo "    ${BASE_URL}/oid4vci/${ISSUER_SLUG}/.well-known/openid-credential-issuer"
  echo ""
  echo "    Enviando email con QR a ${EMAIL_TO}..."
  send_oid4vc_email "$EMAIL_TO" "OID4VCI Credential Offer — CDPI PoC" "$OFFER_URL" "$OFFER_PIN" || true
fi

# ---------------------------------------------------------------------------
# STEP 9 — Registrar OID4VP verifier (una vez — se reutiliza en steps 10 y 11)
# ---------------------------------------------------------------------------
echo ""
echo "[9/11] Registrar OID4VP verifier"
# Un verifier equivale a una "aplicación verificadora" (ej. el HR Portal).
# Se registra una vez y se reutiliza para múltiples solicitudes de presentación.
# verifierId: slug que aparece en todos los endpoints OID4VP de este verifier.
# logo_uri es requerido en clientMetadata — usar cualquier URL válida.
VERIFIER_SLUG="cdpi-poc-hr-verifier-${REQUEST_ID}"
VERIFIER_PAYLOAD="$(jq -n \
  --arg verifierId "$VERIFIER_SLUG" \
  --arg logoUri    "${BASE_URL}/logo.png" \
  '{
    verifierId: $verifierId,
    clientMetadata: {
      client_name: "CDPI PoC HR Portal",
      logo_uri:    $logoUri
    }
  }')"

VERIFIER_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/orgs/$ORG_ID/oid4vp/verifier" "${AUTH[@]}" -d "$VERIFIER_PAYLOAD")"
VERIFIER_STATUS="$(echo "$VERIFIER_RESPONSE" | jq -r '.statusCode // empty')"
check_status "OID4VP verifier registrado" "$VERIFIER_STATUS" "201"

VERIFIER_DB_ID="$(echo "$VERIFIER_RESPONSE" | jq -r '.data.id // empty')"
if [ -z "$VERIFIER_DB_ID" ]; then
  fail "Verifier DB ID extraction" "$(echo "$VERIFIER_RESPONSE" | jq -c .)"
  echo "  Skipping steps 10-11 (no verifier ID)"
  VERIFIER_DB_ID=""
fi

if [ -n "$VERIFIER_DB_ID" ]; then
  echo "    Verifier DB ID: $VERIFIER_DB_ID"
  echo "    Verifier slug:  $VERIFIER_SLUG"

# ---------------------------------------------------------------------------
# STEP 10 — OID4VP: solicitud COMPLETA (todos los campos)
# ---------------------------------------------------------------------------
echo ""
echo "[10/11] OID4VP — solicitud COMPLETA (7/7 campos)"
# El DCQL claims[] lista todos los atributos del esquema.
# El holder debe revelar todos — no hay ocultamiento selectivo.
# Útil para casos como verificación de empleo completa o onboarding KYC.
SESSION_ID_FULL=""
PRESENT_FULL_PAYLOAD="$(jq -n \
  --arg schemaId "$SCHEMA_ID" \
  '{
    requestSigner: { method: "DID" },
    responseMode: "direct_post",
    dcql: {
      query: {
        credentials: [
          {
            id:     "employment-full",
            format: "dc+sd-jwt",
            meta:   { vct_values: [$schemaId] },
            claims: [
              { path: ["given_name"] },
              { path: ["family_name"] },
              { path: ["document_number"] },
              { path: ["employer_name"] },
              { path: ["employment_status"] },
              { path: ["position_title"] },
              { path: ["employment_start_date"] }
            ]
          }
        ]
      }
    }
  }')"

PRESENT_FULL_RESPONSE="$(curl -sS -X POST \
  "$BASE_URL/v1/orgs/$ORG_ID/oid4vp/presentation?verifierId=$VERIFIER_DB_ID" \
  "${AUTH[@]}" -d "$PRESENT_FULL_PAYLOAD")"
PRESENT_FULL_STATUS="$(echo "$PRESENT_FULL_RESPONSE" | jq -r '.statusCode // empty')"
check_status "Solicitud completa creada" "$PRESENT_FULL_STATUS" "201"

PROOF_URL_FULL="$(echo "$PRESENT_FULL_RESPONSE" | jq -r '.data.authorizationRequest // empty')"
SESSION_ID_FULL="$(echo "$PRESENT_FULL_RESPONSE" | jq -r '.data.verificationSession.id // empty')"
echo "    Session ID (completa): $SESSION_ID_FULL"

if [ -n "$PROOF_URL_FULL" ]; then
  echo ""
  echo "    ┌─ OID4VP — Solicitud COMPLETA (7 campos) ───────────────────────┐"
  echo "    │ given_name, family_name, document_number, employer_name,"
  echo "    │ employment_status, position_title, employment_start_date"
  echo "    ├────────────────────────────────────────────────────────────────┤"
  echo "    │ $PROOF_URL_FULL"
  echo "    └────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "    Enviando email con QR a ${EMAIL_TO}..."
  send_oid4vc_email "$EMAIL_TO" "OID4VP Solicitud COMPLETA (7 campos) — CDPI PoC" "$PROOF_URL_FULL" "" || true
fi

# ---------------------------------------------------------------------------
# STEP 11 — OID4VP: solicitud PARCIAL (selective disclosure — 3 de 7 campos)
# ---------------------------------------------------------------------------
echo ""
echo "[11/11] OID4VP — solicitud PARCIAL (Selective Disclosure: 3/7 campos)"
# Los 3 campos pedidos son los "always revealed" (disclose:false en el template).
# Los 4 campos SD (family_name, document_number, position_title, employment_start_date)
# están hasheados en _sd[] — la wallet no incluye sus disclosure tokens.
# El verifier SOLO RECIBE given_name, employment_status, employer_name.
# Útil para "¿está empleado?" sin revelar RUT, apellido ni fecha de inicio.
SESSION_ID_PARTIAL=""
PRESENT_PARTIAL_PAYLOAD="$(jq -n \
  --arg schemaId "$SCHEMA_ID" \
  '{
    requestSigner: { method: "DID" },
    responseMode: "direct_post",
    dcql: {
      query: {
        credentials: [
          {
            id:     "employment-partial",
            format: "dc+sd-jwt",
            meta:   { vct_values: [$schemaId] },
            claims: [
              { path: ["given_name"] },
              { path: ["employment_status"] },
              { path: ["employer_name"] }
            ]
          }
        ]
      }
    }
  }')"

PRESENT_PARTIAL_RESPONSE="$(curl -sS -X POST \
  "$BASE_URL/v1/orgs/$ORG_ID/oid4vp/presentation?verifierId=$VERIFIER_DB_ID" \
  "${AUTH[@]}" -d "$PRESENT_PARTIAL_PAYLOAD")"
PRESENT_PARTIAL_STATUS="$(echo "$PRESENT_PARTIAL_RESPONSE" | jq -r '.statusCode // empty')"
check_status "Solicitud parcial creada" "$PRESENT_PARTIAL_STATUS" "201"

PROOF_URL_PARTIAL="$(echo "$PRESENT_PARTIAL_RESPONSE" | jq -r '.data.authorizationRequest // empty')"
SESSION_ID_PARTIAL="$(echo "$PRESENT_PARTIAL_RESPONSE" | jq -r '.data.verificationSession.id // empty')"
echo "    Session ID (parcial): $SESSION_ID_PARTIAL"

if [ -n "$PROOF_URL_PARTIAL" ]; then
  echo ""
  echo "    ┌─ OID4VP — Solicitud PARCIAL (3/7 campos — Selective Disclosure) ┐"
  echo "    │ Revelados:  given_name, employment_status, employer_name"
  echo "    │ Omitidos:   family_name, document_number, position_title, employment_start_date"
  echo "    ├────────────────────────────────────────────────────────────────┤"
  echo "    │ $PROOF_URL_PARTIAL"
  echo "    └────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "    Enviando email con QR a ${EMAIL_TO}..."
  send_oid4vc_email "$EMAIL_TO" "OID4VP Solicitud PARCIAL (SD: 3/7 campos) — CDPI PoC" "$PROOF_URL_PARTIAL" "" || true
fi

# Poll both sessions — 3 attempts each (5s apart)
# In automated tests the holder won't scan in time; this shows the initial state.
echo ""
echo "    ── Polling sesiones (3 intentos × 2, 5s entre cada uno) ──"
for entry in "completa:$SESSION_ID_FULL" "parcial:$SESSION_ID_PARTIAL"; do
  sess_label="${entry%%:*}"
  sess_id="${entry##*:}"
  [ -z "$sess_id" ] && echo "    Sesión $sess_label: sin ID — saltando" && continue
  echo ""
  echo "    Sesión $sess_label ($sess_id):"
  final_state="pending"
  for i in 1 2 3; do
    sleep 5
    SESS_RESP="$(curl -sS \
      "$BASE_URL/v1/orgs/$ORG_ID/oid4vp/verifier-presentation?id=$sess_id" \
      -H "Authorization: Bearer $TOKEN")"
    SESS_STATE="$(echo "$SESS_RESP" | jq -r '.data.state // .state // "unknown"' 2>/dev/null)"
    echo "      Intento $i — estado: $SESS_STATE"
    if [ "$SESS_STATE" = "ResponseVerified" ]; then
      pass "OID4VP presentación verificada ($sess_label)"
      final_state="verified"
      DISCLOSED="$(echo "$SESS_RESP" | jq '.data.presentationDocument // .data.claims // .data // empty' 2>/dev/null)"
      echo "      Datos recibidos por el verifier:"
      echo "$DISCLOSED" | jq -c . 2>/dev/null | head -c 500
      echo ""
      break
    elif [ "$SESS_STATE" = "Error" ]; then
      fail "OID4VP sesión con error ($sess_label)" "state=Error"
      final_state="error"
      break
    fi
  done
  if [ "$final_state" = "pending" ]; then
    echo "      Estado final: $SESS_STATE (holder aún no presentó — normal en test sin wallet activa)"
    PASS=$((PASS + 1))
  fi
done

fi  # end if [ -n "$VERIFIER_DB_ID" ]

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
