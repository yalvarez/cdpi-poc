#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL schema loader
# -----------------------------------------------------------------------------
# Reads SD-JWT VC schema JSON files from a directory and for each one:
#   1. Creates the schema in CREDEBL (no_ledger, stored in schema-file-server)
#   2. Creates an OID4VCI credential template linked to the issuer
#   3. Generates a ready-to-run test script at credebl/docs/test-<slug>.sh
#
# The schema JSON files must follow the CDPI PoC schema format with sections:
#   schema              — JSON Schema (properties + required)
#   vct_type_metadata   — display metadata (claims with EN labels)
#   credebl_api_payload — name, vct, attributes[]
#   sample_credential_data — test data for generated test scripts
#
# Prerequisites:
#   - CREDEBL stack running (init-credebl.sh completed)
#   - Org provisioned (provision-org.sh completed)
#   - credebl/.env present
#   - jq, openssl, python3 available
#
# Usage:
#   bash scripts/load-schemas.sh \
#     --org-id    <uuid> \
#     --issuer-id <uuid> \
#     [--schemas-dir credebl/schemas/] \
#     [--env         credebl/.env]
#
# Example:
#   bash scripts/load-schemas.sh \
#     --org-id    "3fa85f64-5717-4562-b3fc-2c963f66afa6" \
#     --issuer-id "7e3c9b12-4a2d-4f8e-b9c1-d5e6f7a8b9c0"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDEBL_DIR="$REPO_DIR/credebl"

# --- Defaults ----------------------------------------------------------------
ORG_ID=""
ISSUER_ID=""
SCHEMAS_DIR="$CREDEBL_DIR/schemas"
ENV_FILE="$CREDEBL_DIR/.env"

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id)      ORG_ID="$2";      shift 2 ;;
    --issuer-id)   ISSUER_ID="$2";   shift 2 ;;
    --schemas-dir) SCHEMAS_DIR="$2"; shift 2 ;;
    --env)         ENV_FILE="$2";    shift 2 ;;
    -h|--help)
      sed -n '2,/^# =====/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validate ----------------------------------------------------------------
[[ -z "$ORG_ID" ]]    && { echo "Error: --org-id is required" >&2; exit 1; }
[[ -z "$ISSUER_ID" ]] && { echo "Error: --issuer-id is required" >&2; exit 1; }
[[ -d "$SCHEMAS_DIR" ]] || { echo "Error: schemas directory not found: $SCHEMAS_DIR" >&2; exit 1; }
[[ -f "$ENV_FILE" ]]  || { echo "Error: .env not found at $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${VPS_HOST:?VPS_HOST not set in .env}"
: "${CRYPTO_PRIVATE_KEY:?CRYPTO_PRIVATE_KEY not set in .env}"
: "${PLATFORM_ADMIN_EMAIL:?PLATFORM_ADMIN_EMAIL not set in .env}"
: "${PLATFORM_ADMIN_INITIAL_PASSWORD:?PLATFORM_ADMIN_INITIAL_PASSWORD not set in .env}"

PROTOCOL="${API_GATEWAY_PROTOCOL:-http}"
BASE_URL="${PROTOCOL}://${VPS_HOST}"
DOCS_DIR="$CREDEBL_DIR/docs"

cd "$CREDEBL_DIR"

# --- Helpers -----------------------------------------------------------------
info()    { echo "  $*" >&2; }
success() { echo "  [OK] $*" >&2; }
err()     { echo "  ERROR: $*" >&2; }
die()     { err "$*"; exit 1; }

# --- Authenticate ------------------------------------------------------------
echo >&2
echo "Loading schemas into org $ORG_ID" >&2
echo "Issuer: $ISSUER_ID" >&2

enc_password="$(printf '%s' "$(jq -Rn --arg p "$PLATFORM_ADMIN_INITIAL_PASSWORD" '$p')" \
  | openssl enc -aes-256-cbc -salt -base64 -A -md md5 \
  -pass "pass:$CRYPTO_PRIVATE_KEY" 2>/dev/null)"

token="$(curl -sf -X POST "$BASE_URL/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$PLATFORM_ADMIN_EMAIL\",\"password\":\"$enc_password\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["access_token"])' \
  2>/dev/null)" || die "Sign-in failed"

[[ -z "$token" ]] && die "Sign-in returned empty token"
info "Authenticated as $PLATFORM_ADMIN_EMAIL"
auth_h=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")

# =============================================================================
# Python helper — extracts CREDEBL API payloads from a schema JSON file
# =============================================================================
PYEXTRACT='
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

schema   = data.get("schema", {})
payload  = data.get("credebl_api_payload", {})
meta     = data.get("vct_type_metadata", {})
sample   = data.get("sample_credential_data", {})

# Map from claim path to EN display label
display_map = {}
for claim in meta.get("claims", []):
    path = claim.get("path", [])
    if path:
        key = path[0]
        labels = claim.get("display", [])
        label = next((d["label"] for d in labels if d.get("lang") == "en"), None)
        if label:
            display_map[key] = label

required_fields = set(schema.get("required", []))
props = schema.get("properties", {})

# JWT standard claims — not credential attributes
JWT_CLAIMS = {"vct", "iss", "iat", "exp", "nbf", "sub", "jti", "cnf", "status"}

schema_attributes = []
template_attributes = []
for attr in payload.get("attributes", []):
    if attr in JWT_CLAIMS:
        continue
    prop = props.get(attr, {})
    dtype = prop.get("type", "string")
    if dtype not in ("string", "number", "integer", "boolean"):
        dtype = "string"
    display = display_map.get(attr) or attr.replace("_", " ").title()
    schema_attributes.append({
        "attributeName": attr,
        "schemaDataType": dtype,
        "displayName":   display,
        "isRequired":    attr in required_fields
    })
    template_attributes.append({"key": attr, "value_type": dtype})

# Filter sample data to only include credential attributes
sample_attrs = {k: v for k, v in sample.items()
                if not k.startswith("_") and k not in JWT_CLAIMS}

result = {
    "schema_name":          payload.get("name", "UnknownSchema"),
    "vct":                  payload.get("vct", ""),
    "description":          schema.get("description", ""),
    "schema_attributes":    schema_attributes,
    "template_attributes":  template_attributes,
    "sample_data":          sample_attrs
}
print(json.dumps(result))
'

# =============================================================================
# Process each schema JSON file
# =============================================================================
schema_files=("$SCHEMAS_DIR"/*.json)
[[ "${#schema_files[@]}" -eq 0 || ! -f "${schema_files[0]}" ]] && \
  die "No .json files found in $SCHEMAS_DIR"

loaded=0
failed=0

for schema_file in "${schema_files[@]}"; do
  [[ -f "$schema_file" ]] || continue
  schema_slug="$(basename "$schema_file" .json)"

  echo >&2
  echo "--- $schema_slug ---" >&2

  # Extract metadata
  meta_json="$(python3 -c "$PYEXTRACT" "$schema_file" 2>/dev/null)" || {
    err "$schema_slug: failed to parse schema JSON"
    (( failed++ )) || true
    continue
  }

  schema_name="$(echo "$meta_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["schema_name"])')"
  vct="$(echo          "$meta_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["vct"])')"
  description="$(echo  "$meta_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["description"])')"
  attrs_json="$(echo   "$meta_json" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["schema_attributes"]))')"
  tmpl_json="$(echo    "$meta_json" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["template_attributes"]))')"
  sample_json="$(echo  "$meta_json" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["sample_data"]))')"

  # -------------------------------------------------------------------------
  # 1. Create schema
  # -------------------------------------------------------------------------
  info "Creating schema: $schema_name"
  schema_payload="$(jq -n \
    --arg orgId   "$ORG_ID" \
    --arg name    "$schema_name" \
    --arg desc    "$description" \
    --argjson attrs "$attrs_json" \
    '{
      type: "json",
      schemaPayload: {
        schemaName:  $name,
        schemaType:  "no_ledger",
        attributes:  $attrs,
        description: $desc,
        orgId:       $orgId
      }
    }')"

  schema_resp="$(curl -sf -X POST "$BASE_URL/v1/orgs/$ORG_ID/schemas" "${auth_h[@]}" \
    -d "$schema_payload" 2>/dev/null)"
  schema_id="$(echo "$schema_resp" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["data"]; print(d.get("schemaLedgerId") or d.get("id",""))' \
    2>/dev/null)" || true

  if [[ -z "$schema_id" ]]; then
    err "$schema_slug: schema creation failed"
    echo "$schema_resp" >&2
    (( failed++ )) || true
    continue
  fi
  info "Schema ID: $schema_id"

  # -------------------------------------------------------------------------
  # 2. Create OID4VCI credential template
  # -------------------------------------------------------------------------
  info "Creating credential template..."
  template_payload="$(jq -n \
    --arg schemaId "$schema_id" \
    --arg name     "$schema_name" \
    --arg vct      "$vct" \
    --argjson tmpl "$tmpl_json" \
    '{
      name:         $name,
      format:       "dc+sd-jwt",
      signerOption: "DID",
      canBeRevoked: false,
      template: {
        vct:        $schemaId,
        attributes: $tmpl
      }
    }')"

  template_resp="$(curl -sf -X POST "$BASE_URL/v1/orgs/$ORG_ID/oid4vc/$ISSUER_ID/template" "${auth_h[@]}" \
    -d "$template_payload" 2>/dev/null)"
  template_id="$(echo "$template_resp" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)" || true

  if [[ -z "$template_id" ]]; then
    err "$schema_slug: credential template creation failed"
    echo "$template_resp" >&2
    (( failed++ )) || true
    continue
  fi
  info "Template ID: $template_id"

  # -------------------------------------------------------------------------
  # 3. Generate test script
  # -------------------------------------------------------------------------
  test_script="$DOCS_DIR/test-${schema_slug}.sh"
  info "Generating test script: $test_script"

  # Build credential attributes array for the offer payload
  offer_attrs="$(echo "$sample_json" | python3 -c '
import sys, json
sample = json.load(sys.stdin)
attrs = [{"name": k, "value": str(v)} for k, v in sample.items()]
print(json.dumps(attrs))
')"

  # Build presentationExchange input_descriptors from template attributes
  proof_fields="$(echo "$tmpl_json" | python3 -c '
import sys, json
attrs = json.load(sys.stdin)
fields = [{"path": ["$." + a["key"]]} for a in attrs[:3]]
print(json.dumps(fields))
')"

  cat > "$test_script" <<TESTSCRIPT
#!/usr/bin/env bash
# =============================================================================
# Auto-generated test script for: $schema_name
# Generated by: scripts/load-schemas.sh from $schema_slug.json
#
# Tests the full OID4VCI issuance + OID4VP verification flow.
#
# Usage:
#   bash credebl/docs/test-${schema_slug}.sh
#
# Override defaults via environment:
#   BASE_URL=https://your-vps.example.com \\
#   ORG_ID=<uuid> \\
#   ISSUER_ID=<uuid> \\
#   TEMPLATE_ID=<uuid> \\
#     bash credebl/docs/test-${schema_slug}.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="\$(cd "\$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="\$REPO_DIR/credebl/.env"
[[ -f "\$ENV_FILE" ]] || { echo "credebl/.env not found" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; source "\$ENV_FILE"; set +a

PROTOCOL="\${API_GATEWAY_PROTOCOL:-http}"
BASE_URL="\${BASE_URL:-\${PROTOCOL}://\${VPS_HOST}}"
ORG_ID="\${ORG_ID:-$ORG_ID}"
ISSUER_ID="\${ISSUER_ID:-$ISSUER_ID}"
TEMPLATE_ID="\${TEMPLATE_ID:-$template_id}"
EMAIL="\${TEST_EMAIL:-\${PLATFORM_ADMIN_EMAIL}}"

pass_count=0; fail_count=0
check() {
  local label="\$1" cond="\$2"
  if [[ "\$cond" = "0" ]]; then
    echo "[OK] \$label"; (( pass_count++ )) || true
  else
    echo "[FAIL] \$label"; (( fail_count++ )) || true
  fi
}

echo
echo "=== Test: $schema_name ==="
echo "  Base URL:    \$BASE_URL"
echo "  Org ID:      \$ORG_ID"
echo "  Issuer ID:   \$ISSUER_ID"
echo "  Template ID: \$TEMPLATE_ID"

# ---------------------------------------------------------------------------
# Step 1 — Authenticate
# ---------------------------------------------------------------------------
ENC_PASSWORD="\$(printf '%s' "\$(jq -Rn --arg p "\$PLATFORM_ADMIN_INITIAL_PASSWORD" '\$p')" \\
  | openssl enc -aes-256-cbc -salt -base64 -A -md md5 \\
  -pass "pass:\$CRYPTO_PRIVATE_KEY" 2>/dev/null)"

TOKEN="\$(curl -sS -X POST "\$BASE_URL/v1/auth/signin" \\
  -H "Content-Type: application/json" \\
  -d "{\\"email\\":\\"\$PLATFORM_ADMIN_EMAIL\\",\\"password\\":\\"\$ENC_PASSWORD\\"}" \\
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["access_token"])' 2>/dev/null)"
check "Sign-in" "\$([ -n "\$TOKEN" ] && echo 0 || echo 1)"
[[ -z "\$TOKEN" ]] && { echo "Authentication failed — aborting." >&2; exit 1; }

AUTH=(-H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json")

# ---------------------------------------------------------------------------
# Step 2 — Create OID4VCI credential offer
# ---------------------------------------------------------------------------
echo
echo "Creating credential offer..."
OFFER_PAYLOAD="\$(jq -n \\
  --arg templateId "\$TEMPLATE_ID" \\
  --arg email      "\$EMAIL" \\
  --argjson attrs  '$(echo "$offer_attrs" | jq -c .)' \\
  '{
    credentialData: [{attributes: \$attrs}],
    credentialType:       "sdjwt",
    isReuseConnection:    false,
    comment:              "Test issuance - $schema_name",
    credentialFormat:     "dc+sd-jwt",
    emailId:              \$email,
    credentialTemplateId: \$templateId,
    issuanceDate:         null,
    expirationDate:       null,
    protocolType:         "openid",
    flowType:             "preAuthorizedCodeFlow"
  }')"

OFFER_RESP="\$(curl -sS -X POST "\$BASE_URL/v1/orgs/\$ORG_ID/oid4vc/\$ISSUER_ID/credential-offer" \\
  "\${AUTH[@]}" -d "\$OFFER_PAYLOAD" 2>/dev/null)"

OFFER_URL="\$(echo "\$OFFER_RESP" | python3 -c \\
  'import sys,json; d=json.load(sys.stdin)["data"]; print(d.get("offerRequest","") or d.get("credentialOffer",""))' 2>/dev/null)" || OFFER_URL=""
PIN="\$(echo "\$OFFER_RESP" | python3 -c \\
  'import sys,json; d=json.load(sys.stdin)["data"]; print(d.get("userPin","") or d.get("pin",""))' 2>/dev/null)" || PIN=""

HTTP_OK="\$(echo "\$OFFER_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("statusCode",200))' 2>/dev/null)" || HTTP_OK="0"
check "Credential offer created" "\$([ "\$HTTP_OK" != "400" ] && [ "\$HTTP_OK" != "500" ] && [ -n "\$OFFER_URL" ] && echo 0 || echo 1)"

if [[ -n "\$OFFER_URL" ]]; then
  echo
  echo "  Credential offer:"
  echo "  \$OFFER_URL"
  [[ -n "\$PIN" ]] && echo "  PIN: \$PIN"
fi

# ---------------------------------------------------------------------------
# Step 3 — Create OID4VP proof request
# ---------------------------------------------------------------------------
echo
echo "Creating OID4VP proof request..."
PROOF_PAYLOAD="\$(jq -n '{
  proofRequestLabel: "Test verification - $schema_name",
  comment:           "Automated test",
  type:              "presentationExchange",
  requestedAttributes:  {},
  requestedPredicates:  {},
  connectionId:         null,
  presentationDefinition: {
    id: "test-$schema_slug",
    input_descriptors: [{
      id:      "$schema_slug-check",
      name:    "$schema_name Check",
      purpose: "Verify $schema_name",
      format:  {"vc+sd-jwt": {"alg": ["EdDSA"]}},
      constraints: {
        fields: $(echo "$proof_fields" | jq -c .)
      }
    }]
  }
}')"

PROOF_RESP="\$(curl -sS -X POST "\$BASE_URL/v1/orgs/\$ORG_ID/proofs/oob?requestType=presentationExchange" \\
  "\${AUTH[@]}" -d "\$PROOF_PAYLOAD" 2>/dev/null)"

PROOF_URL="\$(echo "\$PROOF_RESP" | python3 -c \\
  'import sys,json; d=json.load(sys.stdin); print(d.get("data",{}).get("invitationUrl",""))' 2>/dev/null)" || PROOF_URL=""

PROOF_HTTP="\$(echo "\$PROOF_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("statusCode",200))' 2>/dev/null)" || PROOF_HTTP="0"
check "OID4VP proof request created" "\$([ "\$PROOF_HTTP" != "400" ] && [ "\$PROOF_HTTP" != "500" ] && [ -n "\$PROOF_URL" ] && echo 0 || echo 1)"

if [[ -n "\$PROOF_URL" ]]; then
  echo
  echo "  OID4VP request (share with wallet to verify):"
  echo "  \$PROOF_URL"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== Results: \$pass_count passed, \$fail_count failed ==="
[[ "\$fail_count" -gt 0 ]] && exit 1 || exit 0
TESTSCRIPT

  chmod +x "$test_script"
  success "$schema_slug: schema + template + test script created"
  (( loaded++ )) || true
done

# --- Final summary -----------------------------------------------------------
echo >&2
echo "============================================================" >&2
echo " Schema loading complete" >&2
echo "============================================================" >&2
echo "  Loaded:  $loaded" >&2
echo "  Failed:  $failed" >&2
echo >&2
echo "  Test scripts generated in: $DOCS_DIR" >&2
for f in "$DOCS_DIR"/test-*.sh; do
  [[ -f "$f" ]] && echo "    bash $f" >&2
done
echo "============================================================" >&2

[[ "$failed" -gt 0 ]] && exit 1 || exit 0
