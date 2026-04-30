#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL organization provisioner
# -----------------------------------------------------------------------------
# Creates a CREDEBL organization with shared wallet, DID, and OID4VCI issuer.
# Idempotent: safe to re-run; detects existing resources via DB state.
#
# Prerequisites:
#   - CREDEBL stack running (init-credebl.sh completed)
#   - credebl/.env present with platform-admin credentials
#   - jq, openssl, python3 available
#
# Usage:
#   bash scripts/provision-org.sh \
#     --name    "Ministry of Labor" \
#     --slug    "mintrabajo-employment" \
#     [--description "Official employment credential issuer"] \
#     [--website     "https://mintrabajo.gov.co"] \
#     [--did-method  key|web]            (default: key) \
#     [--issuer-name "Ministry of Labor Issuer"] \
#     [--env         path/to/.env]       (default: credebl/.env)
#
# Output:
#   Progress messages → stderr
#   Key=value pairs   → stdout  (suitable for: eval $(bash provision-org.sh ...))
#
#   ORG_ID=<uuid>
#   ORG_DID=<did:key:z6Mk... or did:web:...>
#   ISSUER_ID=<uuid>
#
# Example (capture output for next step):
#   eval $(bash scripts/provision-org.sh --name "Min. Trabajo" --slug "mintrabajo")
#   bash scripts/load-schemas.sh --org-id "$ORG_ID" --issuer-id "$ISSUER_ID"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDEBL_DIR="$REPO_DIR/credebl"

# --- Defaults ----------------------------------------------------------------
ORG_NAME=""
ORG_SLUG=""
ORG_DESCRIPTION=""
ORG_WEBSITE=""
DID_METHOD="key"
ISSUER_NAME=""
ENV_FILE="$CREDEBL_DIR/.env"

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         ORG_NAME="$2";        shift 2 ;;
    --slug)         ORG_SLUG="$2";        shift 2 ;;
    --description)  ORG_DESCRIPTION="$2"; shift 2 ;;
    --website)      ORG_WEBSITE="$2";     shift 2 ;;
    --did-method)   DID_METHOD="$2";      shift 2 ;;
    --issuer-name)  ISSUER_NAME="$2";     shift 2 ;;
    --env)          ENV_FILE="$2";        shift 2 ;;
    -h|--help)
      sed -n '2,/^# =====/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validate ----------------------------------------------------------------
[[ -z "$ORG_NAME" ]]  && { echo "Error: --name is required" >&2; exit 1; }
[[ -z "$ORG_SLUG" ]]  && { echo "Error: --slug is required" >&2; exit 1; }
[[ "$DID_METHOD" != "key" && "$DID_METHOD" != "web" ]] && {
  echo "Error: --did-method must be 'key' or 'web'" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "Error: .env not found at $ENV_FILE" >&2; exit 1; }

: "${ORG_DESCRIPTION:="$ORG_NAME - CDPI PoC credential issuer"}"
: "${ORG_WEBSITE:="https://cdpi.dev"}"
: "${ISSUER_NAME:="$ORG_NAME Issuer"}"

# --- Load env ----------------------------------------------------------------
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${VPS_HOST:?VPS_HOST not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"
: "${CRYPTO_PRIVATE_KEY:?CRYPTO_PRIVATE_KEY not set in .env}"
: "${PLATFORM_ADMIN_EMAIL:?PLATFORM_ADMIN_EMAIL not set in .env}"
: "${PLATFORM_ADMIN_INITIAL_PASSWORD:?PLATFORM_ADMIN_INITIAL_PASSWORD not set in .env}"

PROTOCOL="${API_GATEWAY_PROTOCOL:-http}"
BASE_URL="${PROTOCOL}://${VPS_HOST}"
if [[ "$PROTOCOL" = "https" ]]; then
  KC_URL="https://auth.${VPS_HOST}/realms/credebl-realm"
else
  KC_URL="http://${VPS_HOST}:8080/realms/credebl-realm"
fi

# docker compose must run from CREDEBL_DIR so container names resolve correctly
cd "$CREDEBL_DIR"

# --- Helpers -----------------------------------------------------------------
info() { echo "  $*" >&2; }
err()  { echo "  ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

pg_query() {
  docker compose exec -T postgres \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U credebl -d credebl -Atqc "$1" 2>/dev/null | tr -d '\r\n'
}

# --- Authenticate ------------------------------------------------------------
echo >&2
echo "Provisioning org: $ORG_NAME  (slug: $ORG_SLUG)" >&2
echo "Target: $BASE_URL" >&2

enc_password="$(printf '%s' "$(jq -Rn --arg p "$PLATFORM_ADMIN_INITIAL_PASSWORD" '$p')" \
  | openssl enc -aes-256-cbc -salt -base64 -A -md md5 \
  -pass "pass:$CRYPTO_PRIVATE_KEY" 2>/dev/null)"

token="$(curl -sf -X POST "$BASE_URL/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$PLATFORM_ADMIN_EMAIL\",\"password\":\"$enc_password\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["access_token"])' \
  2>/dev/null)" || die "Sign-in to CREDEBL API failed"

[[ -z "$token" ]] && die "Sign-in returned empty token — check credentials"
info "Authenticated as $PLATFORM_ADMIN_EMAIL"
auth_h=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")

# --- Create org --------------------------------------------------------------
ORG_ID="$(pg_query "SELECT id FROM organisation WHERE name = '$(echo "$ORG_NAME" | sed "s/'/''/g")' LIMIT 1;")"

if [[ -z "$ORG_ID" ]]; then
  org_payload="$(jq -n \
    --arg name "$ORG_NAME" \
    --arg desc "$ORG_DESCRIPTION" \
    --arg web  "$ORG_WEBSITE" \
    '{name:$name,description:$desc,website:$web,countryId:null,stateId:null,cityId:null,logo:""}')"
  org_resp="$(curl -sf -X POST "$BASE_URL/v1/orgs" "${auth_h[@]}" -d "$org_payload" 2>/dev/null)"
  ORG_ID="$(echo "$org_resp" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)" || true
  [[ -z "$ORG_ID" ]] && { err "Org creation failed"; echo "$org_resp" >&2; exit 1; }
  info "Org created: $ORG_ID"
else
  info "Org already exists: $ORG_ID"
fi

# Grant owner role to platform-admin for org-scoped endpoints
pg_query "
INSERT INTO user_org_roles (id, \"userId\", \"orgId\", \"orgRoleId\")
SELECT gen_random_uuid(), uor.\"userId\", '$ORG_ID', r.id
FROM user_org_roles uor
JOIN \"user\" u     ON u.id   = uor.\"userId\"
JOIN org_roles src ON src.id = uor.\"orgRoleId\" AND src.name = 'platform_admin'
CROSS JOIN (SELECT id FROM org_roles WHERE name = 'owner') r
WHERE u.email = '$PLATFORM_ADMIN_EMAIL'
  AND NOT EXISTS (
    SELECT 1 FROM user_org_roles x
    WHERE x.\"userId\"    = uor.\"userId\"
      AND x.\"orgId\"     = '$ORG_ID'
      AND x.\"orgRoleId\" = r.id
  );" >/dev/null 2>&1 || true

# --- Provision wallet --------------------------------------------------------
agent_status="$(pg_query "SELECT \"agentSpinUpStatus\" FROM org_agents WHERE \"orgId\" = '$ORG_ID' LIMIT 1;")"

if [[ "$agent_status" != "2" ]]; then
  info "Provisioning shared wallet..."
  wallet_label="$(echo "$ORG_SLUG" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')-wallet"
  curl -sf -X POST "$BASE_URL/v1/orgs/$ORG_ID/agents/wallet" "${auth_h[@]}" \
    -d "{\"label\":\"$wallet_label\",\"clientSocketId\":\"\"}" >/dev/null 2>&1 || true

  info "Waiting for wallet to be ready (up to 5 min)..."
  for i in $(seq 1 60); do
    agent_status="$(pg_query "SELECT \"agentSpinUpStatus\" FROM org_agents WHERE \"orgId\" = '$ORG_ID' LIMIT 1;")"
    [[ "$agent_status" = "2" ]] && break
    sleep 5
  done
  [[ "$agent_status" != "2" ]] && die "Wallet provisioning timed out (status=$agent_status)"
  info "Wallet ready"
else
  info "Wallet already provisioned"
fi

# --- Create DID --------------------------------------------------------------
ORG_DID="$(pg_query "SELECT \"orgDid\" FROM org_agents WHERE \"orgId\" = '$ORG_ID' AND \"orgDid\" IS NOT NULL LIMIT 1;")"

if [[ -z "$ORG_DID" ]]; then
  info "Creating did:${DID_METHOD}..."
  did_seed="$(openssl rand -hex 16)"

  if [[ "$DID_METHOD" = "web" ]]; then
    # did:web domain path: VPS_HOST:oid4vci:SLUG  (colons become path separators)
    did_domain="${VPS_HOST%%:*}:oid4vci:${ORG_SLUG}"
    curl -sf -X POST "$BASE_URL/v1/orgs/$ORG_ID/agents/did" "${auth_h[@]}" \
      -d "{\"seed\":\"$did_seed\",\"keyType\":\"ed25519\",\"method\":\"web\",\"domain\":\"$did_domain\",\"ledger\":\"\",\"privatekey\":\"\",\"network\":\"\",\"role\":\"\",\"endorserDid\":\"\",\"clientSocketId\":\"\",\"isPrimaryDid\":true}" \
      >/dev/null 2>&1 || true
  else
    curl -sf -X POST "$BASE_URL/v1/orgs/$ORG_ID/agents/did" "${auth_h[@]}" \
      -d "{\"seed\":\"$did_seed\",\"keyType\":\"ed25519\",\"method\":\"key\",\"ledger\":\"\",\"privatekey\":\"\",\"network\":\"\",\"domain\":\"\",\"role\":\"\",\"endorserDid\":\"\",\"clientSocketId\":\"\",\"isPrimaryDid\":true}" \
      >/dev/null 2>&1 || true
  fi

  info "Waiting for DID registration..."
  for i in $(seq 1 20); do
    ORG_DID="$(pg_query "SELECT \"orgDid\" FROM org_agents WHERE \"orgId\" = '$ORG_ID' AND \"orgDid\" IS NOT NULL LIMIT 1;")"
    [[ -n "$ORG_DID" ]] && break
    sleep 3
  done
  [[ -z "$ORG_DID" ]] && die "DID registration timed out"
  info "DID: $ORG_DID"
else
  info "DID already registered: $ORG_DID"
fi

# --- Create OID4VCI issuer ---------------------------------------------------
ISSUER_ID="$(pg_query "SELECT id FROM oidc_issuer WHERE \"publicIssuerId\" = '$ORG_SLUG' LIMIT 1;")"

if [[ -z "$ISSUER_ID" ]]; then
  [[ "$PROTOCOL" != "https" ]] && info "WARNING: OID4VCI requires HTTPS — the credential_issuer URL must be HTTPS for wallet compatibility."

  info "Creating OID4VCI issuer ($ORG_SLUG)..."
  issuer_payload="$(jq -n \
    --arg slug     "$ORG_SLUG" \
    --arg name     "$ISSUER_NAME" \
    --arg orgId    "$ORG_ID" \
    --arg orgDid   "$ORG_DID" \
    --arg kcUrl    "$KC_URL" \
    --arg host     "$BASE_URL" \
    '{
      issuerId:                    $slug,
      credentialIssuerHost:        $host,
      orgId:                       $orgId,
      orgDid:                      $orgDid,
      authorizationServerUrl:      $kcUrl,
      batchCredentialIssuanceSize: 1,
      display: [{name: $name, locale: "en"}]
    }')"

  issuer_resp="$(curl -sf -X POST "$BASE_URL/v1/orgs/$ORG_ID/oid4vc/issuers" "${auth_h[@]}" \
    -d "$issuer_payload" 2>/dev/null)"
  ISSUER_ID="$(echo "$issuer_resp" | python3 -c \
    'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)" || true
  [[ -z "$ISSUER_ID" ]] && { err "OID4VCI issuer creation failed"; echo "$issuer_resp" >&2; exit 1; }
  info "Issuer created: $ISSUER_ID"
else
  info "OID4VCI issuer already exists: $ISSUER_ID"
fi

# --- Summary -----------------------------------------------------------------
echo >&2
echo "============================================================" >&2
echo " Org provisioned" >&2
echo "============================================================" >&2
printf "  %-16s %s\n" "Org ID:"    "$ORG_ID"    >&2
printf "  %-16s %s\n" "DID:"       "$ORG_DID"   >&2
printf "  %-16s %s\n" "Issuer ID:" "$ISSUER_ID" >&2
printf "  %-16s %s\n" "Metadata:"  "$BASE_URL/oid4vci/$ORG_SLUG/.well-known/openid-credential-issuer" >&2
echo "------------------------------------------------------------" >&2
echo "  Next: load schemas" >&2
echo "    bash scripts/load-schemas.sh \\" >&2
echo "      --org-id    $ORG_ID \\" >&2
echo "      --issuer-id $ISSUER_ID" >&2
echo "============================================================" >&2

# Key=value to stdout — caller can eval or source
printf 'ORG_ID=%s\nORG_DID=%s\nISSUER_ID=%s\n' "$ORG_ID" "$ORG_DID" "$ISSUER_ID"
