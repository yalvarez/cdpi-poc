#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Keycloak realm setup for verifiably-demo
# -----------------------------------------------------------------------------
# Creates the 'verifiably-demo' realm, a confidential OIDC client, and three
# test users in the Keycloak instance running as part of the CREDEBL stack.
#
# Safe to re-run: skips creation if the realm/client/user already exists.
#
# Usage:
#   bash scripts/setup-keycloak-verifiably.sh [KEYCLOAK_URL] [ADMIN_PASSWORD]
#
# Defaults:
#   KEYCLOAK_URL      http://localhost:8080   (or set KC_URL env var)
#   ADMIN_PASSWORD    read from credebl/.env  (KEYCLOAK_ADMIN_PASSWORD)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_DIR/credebl/.env"

# ---------------------------------------------------------------------------
# Config — override via env vars or positional args
# ---------------------------------------------------------------------------
KC_URL="${1:-${KC_URL:-http://localhost:8080}}"
KC_URL="${KC_URL%/}"  # strip trailing slash

# Read admin password from .env if not provided
if [ -z "${KC_ADMIN_PASS:-}" ]; then
  if [ -f "$ENV_FILE" ]; then
    KC_ADMIN_PASS="$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")"
  fi
fi
KC_ADMIN_PASS="${2:-${KC_ADMIN_PASS:-}}"

if [ -z "$KC_ADMIN_PASS" ]; then
  printf "Keycloak admin password: " >&2
  read -r -s KC_ADMIN_PASS
  printf "\n" >&2
fi

REALM="verifiably-demo"
CLIENT_ID="verifiably-go"
ADMIN_USER="${KC_ADMIN_USER:-admin}"

REDIRECT_URIS=(
  "http://localhost:8080/auth/callback"
  "http://172.24.0.1:8080/auth/callback"
  "http://ec2-3-108-213-127.ap-south-1.compute.amazonaws.com:8080/auth/callback"
)

declare -A USERS
USERS[holder]="holder|holder@test.com|Jane|Doe"
USERS[issuer]="issuer|issuer@test.com|Keisha|Williams"
USERS[admin]="admin|admin@test.com|Maria|Gonzalez"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found." >&2; exit 1; }; }
require_cmd curl
require_cmd python3

kc_get() {
  # kc_get <token> <path> → prints response body
  curl -sf --max-time 15 \
    "${KC_URL}${2}" \
    -H "Authorization: Bearer ${1}"
}

kc_post() {
  # kc_post <token> <path> <json-body>
  curl -sf --max-time 15 -X POST \
    "${KC_URL}${2}" \
    -H "Authorization: Bearer ${1}" \
    -H "Content-Type: application/json" \
    -d "${3}"
}

kc_put() {
  curl -sf --max-time 15 -X PUT \
    "${KC_URL}${2}" \
    -H "Authorization: Bearer ${1}" \
    -H "Content-Type: application/json" \
    -d "${3}"
}

json_field() {
  # json_field <field> — reads from stdin
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('${1}',''))" 2>/dev/null
}

json_find() {
  # json_find <key> <value> <return-field> — searches array from stdin
  python3 -c "
import json,sys
key,val,ret = '${1}','${2}','${3}'
items=json.load(sys.stdin)
found=[x.get(ret,'') for x in items if x.get(key)==val]
print(found[0] if found else '')
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 1 — Admin token (master realm)
# ---------------------------------------------------------------------------
echo
echo "=== Connecting to Keycloak at $KC_URL ==="
echo -n "  Getting admin token... "

TOKEN=$(curl -sf --max-time 15 -X POST \
  "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=${ADMIN_USER}&password=${KC_ADMIN_PASS}&grant_type=password" \
  | json_field "access_token") || true

if [ -z "$TOKEN" ]; then
  echo "FAILED" >&2
  echo "  Could not authenticate. Check KC_URL and admin password." >&2
  exit 1
fi
echo "OK"

# ---------------------------------------------------------------------------
# Step 2 — Create realm (skip if exists)
# ---------------------------------------------------------------------------
echo
echo "=== Realm: $REALM ==="
echo -n "  Checking... "

REALM_EXISTS=$(kc_get "$TOKEN" "/admin/realms" \
  | python3 -c "import json,sys; print('yes' if any(r.get('realm')==\"${REALM}\" for r in json.load(sys.stdin)) else '')" 2>/dev/null) || true

if [ -n "$REALM_EXISTS" ]; then
  echo "already exists — skipping creation."
else
  echo -n "creating... "
  kc_post "$TOKEN" "/admin/realms" "{
    \"realm\": \"${REALM}\",
    \"displayName\": \"Verifiably Demo\",
    \"enabled\": true,
    \"registrationAllowed\": false,
    \"loginWithEmailAllowed\": true,
    \"duplicateEmailsAllowed\": false,
    \"resetPasswordAllowed\": true,
    \"editUsernameAllowed\": false,
    \"bruteForceProtected\": false
  }" >/dev/null
  echo "created."
fi

# ---------------------------------------------------------------------------
# Step 3 — Create confidential OIDC client (skip if exists)
# ---------------------------------------------------------------------------
echo
echo "=== Client: $CLIENT_ID ==="
echo -n "  Checking... "

EXISTING_CLIENT_ID=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  | json_find "clientId" "$CLIENT_ID" "id") || true

if [ -n "$EXISTING_CLIENT_ID" ]; then
  echo "already exists (id: ${EXISTING_CLIENT_ID}) — skipping creation."
  CLIENT_UUID="$EXISTING_CLIENT_ID"
else
  echo -n "creating... "

  # Build redirect URIs JSON array
  REDIRECT_JSON=$(python3 -c "
import json, sys
uris = $(printf '%s\n' "${REDIRECT_URIS[@]}" | python3 -c "import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin]))")
print(json.dumps(uris))
")

  kc_post "$TOKEN" "/admin/realms/${REALM}/clients" "{
    \"clientId\": \"${CLIENT_ID}\",
    \"name\": \"Verifiably Go Client\",
    \"enabled\": true,
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"standardFlowEnabled\": true,
    \"implicitFlowEnabled\": false,
    \"directAccessGrantsEnabled\": true,
    \"serviceAccountsEnabled\": false,
    \"authorizationServicesEnabled\": false,
    \"redirectUris\": ${REDIRECT_JSON},
    \"webOrigins\": [\"*\"],
    \"attributes\": {
      \"access.token.lifespan\": \"3600\"
    }
  }" >/dev/null

  CLIENT_UUID=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
    | json_find "clientId" "$CLIENT_ID" "id") || true

  echo "created (id: ${CLIENT_UUID})."
fi

# ---------------------------------------------------------------------------
# Step 4 — Print the client secret
# ---------------------------------------------------------------------------
echo -n "  Client secret: "
SECRET=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients/${CLIENT_UUID}/client-secret" \
  | json_field "value") || true
echo "${SECRET:-<could not retrieve — check Keycloak console>}"

# ---------------------------------------------------------------------------
# Step 5 — Create test users
# ---------------------------------------------------------------------------
echo
echo "=== Test Users ==="

for username in holder issuer admin; do
  IFS='|' read -r password email firstname lastname <<< "${USERS[$username]}"

  echo -n "  ${username}: "

  EXISTING_USER_ID=$(kc_get "$TOKEN" "/admin/realms/${REALM}/users?username=${username}&exact=true" \
    | json_find "username" "$username" "id") || true

  if [ -n "$EXISTING_USER_ID" ]; then
    echo "already exists — skipping."
    continue
  fi

  # Create user
  kc_post "$TOKEN" "/admin/realms/${REALM}/users" "{
    \"username\": \"${username}\",
    \"email\": \"${email}\",
    \"firstName\": \"${firstname}\",
    \"lastName\": \"${lastname}\",
    \"enabled\": true,
    \"emailVerified\": true,
    \"credentials\": [{
      \"type\": \"password\",
      \"value\": \"${password}\",
      \"temporary\": false
    }]
  }" >/dev/null

  USER_ID=$(kc_get "$TOKEN" "/admin/realms/${REALM}/users?username=${username}&exact=true" \
    | json_find "username" "$username" "id") || true

  if [ -n "$USER_ID" ]; then
    echo "created (id: ${USER_ID})."
  else
    echo "WARNING — could not verify creation." >&2
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== Done ==="
echo "  Realm:         ${REALM}"
echo "  Client ID:     ${CLIENT_ID}"
echo "  Client Secret: ${SECRET:-<see Keycloak console>}"
echo "  Keycloak URL:  ${KC_URL}"
echo
echo "  OIDC Discovery:"
echo "    ${KC_URL}/realms/${REALM}/.well-known/openid-configuration"
echo
echo "  Test users: holder / issuer / admin  (password = username)"
echo
echo "  To re-run: bash scripts/setup-keycloak-verifiably.sh"
