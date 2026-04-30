#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Generador de credencial SD-JWT OID4VCI
# -----------------------------------------------------------------------------
# Genera un openid-credential-offer:// con PIN para entregar al holder.
# Llama directamente a Credo (puerto 8001) — no requiere token CREDEBL.
#
# Uso:
#   bash credebl/docs/issue-credential.sh
#   bash credebl/docs/issue-credential.sh \
#     --given-name "Ana" --family-name "López" \
#     --employer "Ministerio TIC" --position "Directora" \
#     --doc "CC-987654321"
#
# Opciones:
#   --given-name    Nombre(s) del titular        (default: Carlos)
#   --family-name   Apellido(s) del titular       (default: Gomez Restrepo)
#   --employer      Nombre del empleador          (default: MINTIC Colombia)
#   --position      Cargo                         (default: Ingeniero de Software)
#   --status        Estado laboral                (default: active)
#   --start-date    Fecha inicio YYYY-MM-DD       (default: 2021-03-15)
#   --doc           Número de documento           (default: 1234567890)
#   --qr            Mostrar QR en terminal (requiere qrencode)
#
# Vars de entorno opcionales (se leen del .env automáticamente en el VPS):
#   CREDO_URL       URL interna del agente  (default: http://localhost:8001)
#   TENANT_ID       Tenant ID del org en Credo
#   ISSUER_SLUG     Slug del issuer         (default: cdpi-poc-employment)
#   VPS_ENV         Ruta al .env de CREDEBL (default: /root/apps/cdpi-poc/credebl/.env)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
GIVEN_NAME="Carlos"
FAMILY_NAME="Gomez Restrepo"
EMPLOYER="MINTIC Colombia"
POSITION="Ingeniero de Software"
STATUS="active"
START_DATE="2021-03-15"
DOC_NUMBER="1234567890"
SHOW_QR=false

CREDO_URL="${CREDO_URL:-http://localhost:8001}"
TENANT_ID="${TENANT_ID:-}"
ISSUER_SLUG="${ISSUER_SLUG:-cdpi-poc-employment}"
VPS_ENV="${VPS_ENV:-/root/apps/cdpi-poc/credebl/.env}"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --given-name)  GIVEN_NAME="$2";  shift 2 ;;
    --family-name) FAMILY_NAME="$2"; shift 2 ;;
    --employer)    EMPLOYER="$2";    shift 2 ;;
    --position)    POSITION="$2";    shift 2 ;;
    --status)      STATUS="$2";      shift 2 ;;
    --start-date)  START_DATE="$2";  shift 2 ;;
    --doc)         DOC_NUMBER="$2";  shift 2 ;;
    --qr)          SHOW_QR=true;     shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [ ! -f "$VPS_ENV" ]; then
  echo "ERROR: No se encontró $VPS_ENV" >&2
  echo "       Ejecuta desde el VPS o define VPS_ENV=/ruta/a/.env" >&2
  exit 1
fi

AGENT_API_KEY="$(grep '^AGENT_API_KEY=' "$VPS_ENV" | cut -d= -f2)"
POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' "$VPS_ENV" | cut -d= -f2)"

if [ -z "$AGENT_API_KEY" ]; then
  echo "ERROR: AGENT_API_KEY vacío en $VPS_ENV" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Get root + tenant JWT
# ---------------------------------------------------------------------------
ROOT_JWT="$(curl -sf -X POST "$CREDO_URL/agent/token" \
  -H "Authorization: $AGENT_API_KEY" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')" || {
  echo "ERROR: No se pudo conectar a Credo en $CREDO_URL" >&2
  exit 1
}

if [ -z "$TENANT_ID" ]; then
  TENANT_ID="$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -U credebl -d credebl -tAc \
    "SELECT oa.\"tenantId\" FROM org_agents oa
     JOIN oidc_issuer oi ON oi.\"orgAgentId\" = oa.id
     WHERE oi.\"publicIssuerId\" = '$ISSUER_SLUG'
     LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$TENANT_ID" ] && { echo "ERROR: No se encontró tenantId para issuer '$ISSUER_SLUG'. Usa TENANT_ID=... o --help." >&2; exit 1; }
fi

TENANT_JWT="$(curl -sf -X POST "$CREDO_URL/multi-tenancy/get-token/$TENANT_ID" \
  -H "Authorization: Bearer $ROOT_JWT" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')" || {
  echo "ERROR: No se pudo obtener token del tenant $TENANT_ID" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Resolve issuer metadata (VCT, credentialSupportedId, signerDid, KC URL)
# ---------------------------------------------------------------------------
ISSUER_META="$(curl -sf "$CREDO_URL/openid4vc/issuer/$ISSUER_SLUG" \
  -H "Authorization: Bearer $TENANT_JWT")"

read -r CRED_SUPPORTED_ID VCT SIGNER_DID KC_URL < <(python3 - "$ISSUER_SLUG" <<'PYEOF'
import sys, json

raw = sys.stdin.read()
# issuer meta was already printed to stdout before this heredoc runs;
# we receive it via stdin when called from process substitution below
data = json.loads(raw)
cfgs = data.get("credentialConfigurationsSupported", {})
cred_id = next(iter(cfgs), "EmploymentCredential-sdjwt")
cfg = cfgs.get(cred_id, {})
vct = cfg.get("vct", "")
signer_did = ""
# extract KC URL from scope or fall back to empty
kc_url = ""
print(cred_id, vct, signer_did, kc_url)
PYEOF
) 2>/dev/null || true

# Use python3 more robustly via temp file approach
CRED_SUPPORTED_ID="$(echo "$ISSUER_META" | python3 -c '
import sys, json
d = json.load(sys.stdin)
cfgs = d.get("credentialConfigurationsSupported", {})
print(next(iter(cfgs), "EmploymentCredential-sdjwt"))
')"

VCT="$(echo "$ISSUER_META" | python3 -c '
import sys, json
d = json.load(sys.stdin)
cfgs = d.get("credentialConfigurationsSupported", {})
cfg = next(iter(cfgs.values()), {})
print(cfg.get("vct", ""))
')"

SIGNER_DID="$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -U credebl -d credebl -tAc \
  "SELECT oa.\"orgDid\" FROM org_agents oa
   JOIN oidc_issuer oi ON oi.\"orgAgentId\" = oa.id
   WHERE oi.\"publicIssuerId\" = '$ISSUER_SLUG'
   LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"

# Derive Keycloak URL from the credential issuer host
ISSUER_HOST="$(echo "$ISSUER_META" | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
# issuer_id looks like "cdpi-poc-employment", hosted at credentialIssuerHost
# we rely on the env var for KC URL
print("")
' 2>/dev/null)"

# Fall back: construct from schema-file-server URL in .env
SCHEMA_URL="$(grep '^SCHEMA_FILE_SERVER_URL=' "$VPS_ENV" | cut -d= -f2)"
BASE_HOST="$(echo "$SCHEMA_URL" | sed 's|https\?://||' | cut -d/ -f1)"
if echo "$BASE_HOST" | grep -qE '^credebl\.'; then
  AUTH_HOST="$(echo "$BASE_HOST" | sed 's/^credebl\./auth./')"
  KC_URL="https://${AUTH_HOST}/realms/credebl-realm"
elif echo "$BASE_HOST" | grep -qE '^[0-9]+\.[0-9]+'; then
  KC_URL="http://${BASE_HOST%:*}:8080/realms/credebl-realm"
else
  KC_URL="http://keycloak:8080/realms/credebl-realm"
fi

if [ -z "$VCT" ] || [ -z "$SIGNER_DID" ]; then
  echo "ERROR: No se pudo resolver VCT o DID del issuer '$ISSUER_SLUG'" >&2
  echo "       VCT='$VCT'  DID='$SIGNER_DID'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build JSON payload with jq (safe quoting)
# ---------------------------------------------------------------------------
PAYLOAD="$(jq -n \
  --arg issuerId    "$ISSUER_SLUG" \
  --arg credId      "$CRED_SUPPORTED_ID" \
  --arg signerDid   "$SIGNER_DID" \
  --arg vct         "$VCT" \
  --arg givenName   "$GIVEN_NAME" \
  --arg familyName  "$FAMILY_NAME" \
  --arg docNum      "$DOC_NUMBER" \
  --arg employer    "$EMPLOYER" \
  --arg empStatus   "$STATUS" \
  --arg position    "$POSITION" \
  --arg startDate   "$START_DATE" \
  --arg kcUrl       "$KC_URL" \
  '{
    publicIssuerId: $issuerId,
    credentials: [{
      credentialSupportedId: $credId,
      format: "dc+sd-jwt",
      signerOptions: {method: "did", did: $signerDid},
      payload: {
        vct: $vct,
        given_name: $givenName,
        family_name: $familyName,
        document_number: $docNum,
        employer_name: $employer,
        employment_status: $empStatus,
        position_title: $position,
        employment_start_date: $startDate
      }
    }],
    preAuthorizedCodeFlowConfig: {
      authorizationServerUrl: $kcUrl,
      txCode: {input_mode: "numeric", length: 4, description: "Ingrese su PIN"}
    }
  }')"

# ---------------------------------------------------------------------------
# Create offer
# ---------------------------------------------------------------------------
echo "Generando credencial para: $GIVEN_NAME $FAMILY_NAME ($EMPLOYER)..."

OFFER_RESP="$(curl -sf -X POST "$CREDO_URL/openid4vc/issuance-sessions/create-credential-offer" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TENANT_JWT" \
  -d "$PAYLOAD")" || {
  echo "ERROR: Fallo al crear el offer. Respuesta:" >&2
  echo "$OFFER_RESP" >&2
  exit 1
}

OFFER_URL="$(echo "$OFFER_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["credentialOffer"])')"
PIN="$(echo "$OFFER_RESP"       | python3 -c 'import sys,json; print(json.load(sys.stdin)["issuanceSession"]["userPin"])')"
EXPIRES="$(echo "$OFFER_RESP"   | python3 -c 'import sys,json; print(json.load(sys.stdin)["issuanceSession"]["expiresAt"])')"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Credencial SD-JWT generada (OID4VCI pre-authorized code flow)    ║"
echo "╠═══════════════════════════════════════════════════════════════════╣"
printf "║  Titular:   %-53s ║\n" "$GIVEN_NAME $FAMILY_NAME"
printf "║  Empleador: %-53s ║\n" "$EMPLOYER"
printf "║  Cargo:     %-53s ║\n" "$POSITION"
printf "║  Vence:     %-53s ║\n" "$EXPIRES"
echo "╠═══════════════════════════════════════════════════════════════════╣"
echo "║  Abre este URL en tu wallet OID4VCI (e.g. Inji):                  ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "$OFFER_URL"
echo ""
echo "PIN: $PIN"
echo ""

if [ "$SHOW_QR" = "true" ]; then
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$OFFER_URL"
  else
    echo "(instala qrencode para QR en terminal: apt-get install -y qrencode)"
  fi
fi
