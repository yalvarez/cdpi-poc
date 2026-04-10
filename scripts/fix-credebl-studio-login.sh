#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDEBL_DIR="$(cd "$SCRIPT_DIR/../credebl" && pwd)"
cd "$CREDEBL_DIR"

if [[ ! -f .env ]]; then
  echo "Error: $CREDEBL_DIR/.env not found"
  exit 1
fi

set -a
source .env
set +a

: "${KEYCLOAK_ADMIN_USER:?Missing KEYCLOAK_ADMIN_USER in .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Missing KEYCLOAK_ADMIN_PASSWORD in .env}"
: "${KEYCLOAK_REALM:?Missing KEYCLOAK_REALM in .env}"
: "${PLATFORM_ADMIN_EMAIL:?Missing PLATFORM_ADMIN_EMAIL in .env}"
: "${POSTGRES_USER:?Missing POSTGRES_USER in .env}"
: "${POSTGRES_DB:?Missing POSTGRES_DB in .env}"

PLATFORM_ADMIN_PASSWORD="${1:-changeme}"

parse_user_json() {
  python3 - "$1" <<'PY'
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else '[]'
try:
    data = json.loads(raw)
except Exception:
    data = []

if isinstance(data, list) and data:
    item = data[0] or {}
    print(item.get('id', ''))
    print(item.get('username', ''))
else:
    print('')
    print('')
PY
}

echo "==> Authenticating to Keycloak admin API"
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

echo "==> Looking up platform user in realm '$KEYCLOAK_REALM'"
USER_JSON="$(docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get users -r "$KEYCLOAK_REALM" -q email="$PLATFORM_ADMIN_EMAIL")"
mapfile -t USER_FIELDS < <(parse_user_json "$USER_JSON")
KC_USER_ID="${USER_FIELDS[0]:-}"
KC_USERNAME="${USER_FIELDS[1]:-$PLATFORM_ADMIN_EMAIL}"

if [[ -z "$KC_USER_ID" ]]; then
  echo "==> No existing platform user found; creating '$PLATFORM_ADMIN_EMAIL'"
  docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create users -r "$KEYCLOAK_REALM" \
    -s username="$PLATFORM_ADMIN_EMAIL" \
    -s email="$PLATFORM_ADMIN_EMAIL" \
    -s enabled=true \
    -s emailVerified=true \
    -s firstName=Platform \
    -s lastName=Admin >/dev/null

  USER_JSON="$(docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get users -r "$KEYCLOAK_REALM" -q username="$PLATFORM_ADMIN_EMAIL")"
  mapfile -t USER_FIELDS < <(parse_user_json "$USER_JSON")
  KC_USER_ID="${USER_FIELDS[0]:-}"
  KC_USERNAME="${USER_FIELDS[1]:-$PLATFORM_ADMIN_EMAIL}"
fi

if [[ -z "$KC_USER_ID" ]]; then
  echo "Error: could not resolve the Keycloak platform user ID"
  exit 1
fi

echo "==> Resetting platform user password"
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh set-password \
  -r "$KEYCLOAK_REALM" \
  --userid "$KC_USER_ID" \
  --new-password "$PLATFORM_ADMIN_PASSWORD" >/dev/null

echo "==> Ensuring realm role 'platform-admin' is present"
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh add-roles \
  -r "$KEYCLOAK_REALM" \
  --uid "$KC_USER_ID" \
  --rolename platform-admin >/dev/null 2>&1 || true

echo "==> Linking the Keycloak user ID in Postgres"
docker compose exec -T postgres psql \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  -c "UPDATE \"user\" SET \"keycloakUserId\"='${KC_USER_ID}' WHERE email='${PLATFORM_ADMIN_EMAIL}';"

echo "==> Restarting services"
docker compose restart user api-gateway studio >/dev/null

echo
echo "Studio login repaired."
echo "Email:    $PLATFORM_ADMIN_EMAIL"
echo "Password: $PLATFORM_ADMIN_PASSWORD"
