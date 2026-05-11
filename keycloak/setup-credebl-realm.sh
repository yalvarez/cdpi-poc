#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Keycloak: configuración del realm CREDEBL
# -----------------------------------------------------------------------------
# Crea el realm 'credebl-realm' con los clientes y roles necesarios para la
# plataforma CREDEBL. Seguro para re-ejecutar: omite lo que ya existe.
#
# Uso:
#   bash setup-credebl-realm.sh [KEYCLOAK_URL] [ADMIN_PASSWORD] [CLIENT_SECRET]
#
# Defaults (se leen de keycloak/.env si existe):
#   KEYCLOAK_URL     → KC_PUBLIC_URL del .env, o http://localhost:8080
#   ADMIN_PASSWORD   → KEYCLOAK_ADMIN_PASSWORD del .env
#   CLIENT_SECRET    → KEYCLOAK_CLIENT_SECRET del .env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Colores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
skip() { echo -e "${YELLOW}  –${NC} $* (ya existe)"; }
die()  { echo -e "${RED}  ✗ ERROR:${NC} $*" >&2; exit 1; }

# ── Leer configuración ────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  set -a; source <(grep -E '^[A-Z_]+=' "$ENV_FILE"); set +a
fi

KC_URL="${1:-${KC_PUBLIC_URL:-http://localhost:${KEYCLOAK_PORT:-8080}}}"
KC_URL="${KC_URL%/}"
ADMIN_PASS="${2:-${KEYCLOAK_ADMIN_PASSWORD:-}}"
CLIENT_SECRET="${3:-${KEYCLOAK_CLIENT_SECRET:-}}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"

# Si no hay admin password, pedirlo
if [ -z "$ADMIN_PASS" ]; then
  printf "  Keycloak admin password: "
  read -r -s ADMIN_PASS; echo
fi
[ -z "$ADMIN_PASS" ] && die "Se requiere la contraseña de admin."

# Si no hay client secret, generarlo
if [ -z "$CLIENT_SECRET" ]; then
  CLIENT_SECRET="$(openssl rand -hex 20 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 40)"
  warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
  warn "No se encontró KEYCLOAK_CLIENT_SECRET — se usará uno generado: ${CLIENT_SECRET}"
  warn "Guárdalo en tu .env como KEYCLOAK_CLIENT_SECRET=${CLIENT_SECRET}"
fi

REALM="credebl-realm"

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' no está instalado."; }
require_cmd curl; require_cmd python3

kc_get()  { curl -sf --max-time 15 "${KC_URL}${2}" -H "Authorization: Bearer ${1}"; }
kc_post() { curl -sf --max-time 15 -X POST  "${KC_URL}${2}" \
              -H "Authorization: Bearer ${1}" -H "Content-Type: application/json" -d "${3}"; }
kc_put()  { curl -sf --max-time 15 -X PUT   "${KC_URL}${2}" \
              -H "Authorization: Bearer ${1}" -H "Content-Type: application/json" -d "${3}"; }

json_get() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('${1}',''))" 2>/dev/null
}
json_find() {
  python3 -c "
import json,sys
key,val,ret='${1}','${2}','${3}'
items=json.load(sys.stdin)
found=[x.get(ret,'') for x in (items if isinstance(items,list) else []) if x.get(key)==val]
print(found[0] if found else '')
" 2>/dev/null
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   CDPI PoC — Configuración realm CREDEBL                      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "  Keycloak: ${KC_URL}"
echo ""

# ── Token de admin ────────────────────────────────────────────────────────────
echo "=== Conectando a Keycloak ==="
TOKEN=$(curl -sf --max-time 15 -X POST \
  "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=${ADMIN_USER}&password=${ADMIN_PASS}&grant_type=password" \
  | json_get "access_token") || true
[ -z "$TOKEN" ] && die "No se pudo autenticar. Verifica la URL y la contraseña de admin."
ok "Token de admin obtenido."

# ── Realm ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Realm: ${REALM} ==="

REALM_EXISTS=$(kc_get "$TOKEN" "/admin/realms" \
  | python3 -c "import json,sys; print('yes' if any(r.get('realm')=='${REALM}' for r in json.load(sys.stdin)) else '')" \
  2>/dev/null) || REALM_EXISTS=""

if [ -n "$REALM_EXISTS" ]; then
  skip "Realm '${REALM}'"
else
  kc_post "$TOKEN" "/admin/realms" '{
    "realm": "'"${REALM}"'",
    "displayName": "CDPI PoC Realm",
    "enabled": true,
    "sslRequired": "none",
    "registrationAllowed": false,
    "loginWithEmailAllowed": true,
    "duplicateEmailsAllowed": false,
    "resetPasswordAllowed": true,
    "editUsernameAllowed": false,
    "accessTokenLifespan": 86400
  }' >/dev/null
  ok "Realm '${REALM}' creado."
fi

# ── Función helper para clientes ──────────────────────────────────────────────
create_client_if_missing() {
  local client_id="$1" payload="$2" label="$3"
  local existing_uuid
  existing_uuid=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients?clientId=${client_id}" \
    | json_find "clientId" "$client_id" "id") || existing_uuid=""

  if [ -n "$existing_uuid" ]; then
    skip "Cliente '${client_id}' (id: ${existing_uuid})" >&2
    echo "$existing_uuid"
    return
  fi

  kc_post "$TOKEN" "/admin/realms/${REALM}/clients" "$payload" >/dev/null
  local new_uuid
  new_uuid=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients?clientId=${client_id}" \
    | json_find "clientId" "$client_id" "id")
  ok "${label} '${client_id}' creado (id: ${new_uuid})." >&2
  echo "$new_uuid"
}

# ── Clientes ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Clientes OIDC ==="

# 1. credebl-client — confidencial, para la API de CREDEBL
CREDEBL_CLIENT_UUID=$(create_client_if_missing "credebl-client" '{
  "clientId": "credebl-client",
  "name": "CREDEBL Platform Client",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "'"${CLIENT_SECRET}"'",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": true,
  "publicClient": false,
  "protocol": "openid-connect",
  "redirectUris": [
    "'"${KC_URL%:*}//*"'/*",
    "http://localhost:5000/*",
    "http://localhost:3000/*",
    "*"
  ],
  "webOrigins": ["*"],
  "defaultClientScopes": ["openid","web-origins","profile","roles","email"],
  "protocolMappers": [{
    "name": "email",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-property-mapper",
    "consentRequired": false,
    "config": {
      "userinfo.token.claim": "true",
      "user.attribute": "email",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "email",
      "jsonType.label": "String"
    }
  }]
}' "Cliente confidencial")

# 2. adminClient — para operaciones de administración (service account)
ADMIN_CLIENT_UUID=$(create_client_if_missing "adminClient" '{
  "clientId": "adminClient",
  "name": "CREDEBL Platform Admin Client",
  "enabled": true,
  "clientAuthenticatorType": "client-secret",
  "secret": "'"${CLIENT_SECRET}"'",
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": true,
  "publicClient": false,
  "protocol": "openid-connect",
  "defaultClientScopes": ["openid","profile","email","roles"],
  "protocolMappers": [
    {
      "name": "realm-management-roles",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-client-role-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "multivalued": "true",
        "id.token.claim": "false",
        "access.token.claim": "true",
        "claim.name": "resource_access.realm-management.roles",
        "jsonType.label": "String",
        "client_id": "realm-management"
      }
    },
    {
      "name": "email",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "consentRequired": false,
      "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "email",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "email",
        "jsonType.label": "String"
      }
    }
  ]
}' "Cliente admin")

# 3. credebl-wallet-client — público, para wallets móviles/web
create_client_if_missing "credebl-wallet-client" '{
  "clientId": "credebl-wallet-client",
  "name": "CREDEBL Wallet Client (public)",
  "enabled": true,
  "publicClient": true,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "protocol": "openid-connect",
  "redirectUris": ["inji://callback","openid://callback","http://localhost/*","*"],
  "webOrigins": ["*"]
}' "Cliente público (wallet)" >/dev/null

# ── Roles del realm ───────────────────────────────────────────────────────────
echo ""
echo "=== Roles del realm ==="

for ROLE_NAME in platform-admin org-admin issuer verifier holder; do
  ROLE_EXISTS=$(kc_get "$TOKEN" "/admin/realms/${REALM}/roles" \
    | json_find "name" "$ROLE_NAME" "name") || ROLE_EXISTS=""
  if [ -n "$ROLE_EXISTS" ]; then
    skip "Rol '${ROLE_NAME}'"
  else
    kc_post "$TOKEN" "/admin/realms/${REALM}/roles" \
      '{"name":"'"${ROLE_NAME}"'","description":"CDPI role: '"${ROLE_NAME}"'"}' >/dev/null
    ok "Rol '${ROLE_NAME}' creado."
  fi
done

# ── Service account del adminClient → realm-admin ─────────────────────────────
echo ""
echo "=== Service account: adminClient → realm-admin ==="

# Buscar el service account user del adminClient
SA_USER_ID=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients/${ADMIN_CLIENT_UUID}/service-account-user" \
  | json_get "id") || SA_USER_ID=""

if [ -n "$SA_USER_ID" ]; then
  # Obtener el ID del cliente realm-management y del rol realm-admin
  RM_CLIENT_ID=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients?clientId=realm-management" \
    | json_find "clientId" "realm-management" "id") || RM_CLIENT_ID=""

  if [ -n "$RM_CLIENT_ID" ]; then
    REALM_ADMIN_ROLE=$(kc_get "$TOKEN" "/admin/realms/${REALM}/clients/${RM_CLIENT_ID}/roles/realm-admin" \
      2>/dev/null) || REALM_ADMIN_ROLE=""

    if [ -n "$REALM_ADMIN_ROLE" ]; then
      kc_post "$TOKEN" \
        "/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/clients/${RM_CLIENT_ID}" \
        "[${REALM_ADMIN_ROLE}]" >/dev/null 2>/dev/null || true
      ok "Service account 'adminClient' → rol 'realm-admin' asignado."
    fi
  fi
else
  echo -e "${YELLOW}  ⚠${NC} No se encontró service account para adminClient — puede requerir asignación manual."
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Realm CREDEBL configurado                                   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Realm:${NC}           ${REALM}"
echo -e "  ${BOLD}OIDC Discovery:${NC}  ${KC_URL}/realms/${REALM}/.well-known/openid-configuration"
echo ""
echo -e "  ${BOLD}credebl-client:${NC}  confidencial — para API gateway de CREDEBL"
echo -e "  ${BOLD}adminClient:${NC}     service account con realm-admin"
echo -e "  ${BOLD}Client secret:${NC}   ${CLIENT_SECRET}"
echo ""
echo -e "  ${BOLD}Variables para CREDEBL .env:${NC}"
echo -e "    KEYCLOAK_PUBLIC_URL=${KC_URL}"
echo -e "    KEYCLOAK_REALM=${REALM}"
echo -e "    KEYCLOAK_CLIENT_ID=credebl-client"
echo -e "    KEYCLOAK_CLIENT_SECRET=${CLIENT_SECRET}"
echo -e "    KEYCLOAK_ADMIN_CLIENT_ID=adminClient"
echo ""
