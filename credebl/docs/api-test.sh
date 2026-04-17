#!/usr/bin/env bash
set -euo pipefail

# Script E2E CREDEBL: lee .env, autocompleta variables y ejecuta el flujo robusto E2E

# Cargar variables desde credebl/.env si existe (solo clave=valor válidas)
ENV_FILE="credebl/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  source <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
  set +a

  # Mapear variables estándar de CREDEBL a las variables del script de test
  [ -z "${ADMIN_EMAIL:-}" ] && ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-}"
  [ -z "${ADMIN_PASSWORD:-}" ] && ADMIN_PASSWORD="${PLATFORM_ADMIN_INITIAL_PASSWORD:-}"
fi

# Función para pedir variable si no existe
ask_if_missing() {
  local var="$1"
  local prompt="$2"
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    read -rp "$prompt: " val
    export $var="$val"
  fi
}

# Variables requeridas
ask_if_missing "VPS_IP" "IP del VPS (ej: 10.0.0.1)"
ask_if_missing "ADMIN_EMAIL" "Email admin (ej: admin@cdpi-poc.local)"
ask_if_missing "ADMIN_PASSWORD" "Password admin"
ask_if_missing "CRYPTO_PRIVATE_KEY" "Crypto private key"
ask_if_missing "EMAIL_TO" "Email destino para emisión VC"

BASE_URL="http://$VPS_IP:5000"
SCHEMA_FILE_SERVER_URL="${SCHEMA_FILE_SERVER_URL:-http://schema-file-server:4000/schemas/}"

REQUEST_ID="$(date +%s)"
ORG_NAME="CDPI API E2E $REQUEST_ID"
SCHEMA_NAME="EmploymentApiE2E$REQUEST_ID"

normalize_schema_base() {
  local raw="$1"
  raw="${raw%/}"
  if [[ "$raw" =~ /schemas$ ]]; then
    echo "$raw/"
  else
    echo "$raw/schemas/"
  fi
}

normalize_schema_context_url() {
  local value="$1"
  local base
  base="$(normalize_schema_base "$SCHEMA_FILE_SERVER_URL")"

  if [[ "$value" =~ ^https?:// ]]; then
    echo "$value"
    return
  fi

  if [[ "$value" =~ ^/schemas/ ]]; then
    local origin
    origin="${base%/schemas/}"
    echo "$origin$value"
    return
  fi

  if [[ "$value" =~ ^[^[:space:]]+:[0-9]+/schemas/ ]]; then
    echo "http://$value"
    return
  fi

  echo "${base}${value}"
}

encrypt_admin_password() {
  local plain="$1"
  local quoted
  quoted="$(jq -Rn --arg p "$plain" '$p')"
  printf '%s' "$quoted" | openssl enc -aes-256-cbc -salt -base64 -A -md md5 -pass "pass:$CRYPTO_PRIVATE_KEY"
}

echo "[1/8] Encrypt admin password locally"
ENC_PASSWORD="$(encrypt_admin_password "$ADMIN_PASSWORD")"

if [ -z "$ENC_PASSWORD" ]; then
  echo "Failed to encrypt admin password locally" >&2
  exit 1
fi

echo "[2/8] Sign in"
SIGNIN_RESPONSE="$(curl -sS -X POST "$BASE_URL/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENC_PASSWORD\"}")"
TOKEN="$(echo "$SIGNIN_RESPONSE" | jq -r '.data.access_token // empty')"

if [ -z "$TOKEN" ]; then
  echo "Signin failed:" >&2
  echo "$SIGNIN_RESPONSE" | jq . >&2 || echo "$SIGNIN_RESPONSE" >&2
  exit 1
fi

auth_header=( -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" )

echo "[3/8] Create organization"
CREATE_ORG_PAYLOAD="$(jq -n \
  --arg name "$ORG_NAME" \
  --arg description "Organization created by API E2E script" \
  --arg website "https://cdpi-poc.local" \
  '{name:$name, description:$description, website:$website, countryId:null, stateId:null, cityId:null, logo:""}')"

CREATE_ORG_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs" "${auth_header[@]}" -d "$CREATE_ORG_PAYLOAD")"
ORG_ID="$(echo "$CREATE_ORG_RESPONSE" | jq -r '.data.id // .id // empty')"

if [ -z "$ORG_ID" ]; then
  echo "Organization creation failed:" >&2
  echo "$CREATE_ORG_RESPONSE" | jq . >&2 || echo "$CREATE_ORG_RESPONSE" >&2
  exit 1
fi

echo "Organization ID: $ORG_ID"

echo "[4/8] Spin up shared wallet"
WALLET_PAYLOAD="$(jq -n --arg label "ApiE2EWallet$REQUEST_ID" '{label:$label, clientSocketId:""}')"
WALLET_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/agents/wallet" "${auth_header[@]}" -d "$WALLET_PAYLOAD")"
echo "$WALLET_RESPONSE" | jq '{statusCode, message}'

WALLET_STATUS="$(echo "$WALLET_RESPONSE" | jq -r '.statusCode // empty')"
if [ "$WALLET_STATUS" != "201" ]; then
  echo "Wallet provisioning failed:" >&2
  echo "$WALLET_RESPONSE" | jq . >&2 || echo "$WALLET_RESPONSE" >&2
  exit 1
fi

echo "[5/8] Create DID (did:key)"
DID_SEED="$(openssl rand -hex 16)"
DID_PAYLOAD="{\"seed\":\"$DID_SEED\",\"keyType\":\"ed25519\",\"method\":\"key\",\"ledger\":\"\",\"privatekey\":\"\",\"network\":\"\",\"domain\":\"\",\"role\":\"\",\"endorserDid\":\"\",\"clientSocketId\":\"\",\"isPrimaryDid\":true}"
DID_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/agents/did" "${auth_header[@]}" -d "$DID_PAYLOAD")"
echo "$DID_RESPONSE" | jq '{statusCode, message, did: (.did // .data.did // "")}'

ORG_DID=""
for _ in $(seq 1 20); do
  ORG_RESPONSE="$(curl -sS "$BASE_URL/orgs/$ORG_ID" -H "Authorization: Bearer $TOKEN")"
  ORG_DID="$(echo "$ORG_RESPONSE" | jq -r '.data.org_agents[0].orgDid // empty')"
  if [ -n "$ORG_DID" ]; then
    break
  fi
  sleep 3
done

if [ -z "$ORG_DID" ]; then
  echo "Org DID not available yet:" >&2
  echo "$ORG_RESPONSE" | jq . >&2 || true
  exit 1
fi

echo "Org DID: $ORG_DID"

echo "[6/8] Create W3C schema"
SCHEMA_TYPE_VALUE="no_ledger"
if [[ "$ORG_DID" =~ ^did:polygon: ]]; then
  SCHEMA_TYPE_VALUE="polygon"
fi

SCHEMA_CREATE_PAYLOAD="$(jq -n \
  --arg type "json" \
  --arg schemaName "$SCHEMA_NAME" \
  --arg schemaType "$SCHEMA_TYPE_VALUE" \
  --arg description "$SCHEMA_NAME" \
  --arg orgId "$ORG_ID" \
  '{
    type:$type,
    schemaPayload:{
      schemaName:$schemaName,
      schemaType:$schemaType,
      attributes:[
        {attributeName:"firstName", schemaDataType:"string", displayName:"First Name", isRequired:true},
        {attributeName:"lastName", schemaDataType:"string", displayName:"Last Name", isRequired:true},
        {attributeName:"employeeId", schemaDataType:"string", displayName:"Employee ID", isRequired:true}
      ],
      description:$description,
      orgId:$orgId
    }
  }')"

SCHEMA_CREATE_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/schemas" "${auth_header[@]}" -d "$SCHEMA_CREATE_PAYLOAD")"
echo "$SCHEMA_CREATE_RESPONSE" | jq '{statusCode, message}'

SCHEMA_ID_RAW="$(echo "$SCHEMA_CREATE_RESPONSE" | jq -r '.data.schemaLedgerId // .data.schemaId // .data.id // empty')"

if [ -z "$SCHEMA_ID_RAW" ]; then
  # Fallback: pull first schema template used by issuance for W3C
  TEMPLATES_RESPONSE="$(curl -sS "$BASE_URL/orgs/$ORG_ID/credentials/bulk/template?schemaType=w3c" -H "Authorization: Bearer $TOKEN")"
  SCHEMA_ID_RAW="$(echo "$TEMPLATES_RESPONSE" | jq -r '.data[0].schemaIdentifier // empty')"
fi

if [ -z "$SCHEMA_ID_RAW" ]; then
  echo "Could not determine schema identifier from API responses." >&2
  echo "$SCHEMA_CREATE_RESPONSE" | jq . >&2 || true
  exit 1
fi

SCHEMA_CONTEXT_URL="$(normalize_schema_context_url "$SCHEMA_ID_RAW")"
echo "Schema context URL: $SCHEMA_CONTEXT_URL"

echo "[7/8] Issue credential via email OOB (jsonld)"
ISSUANCE_PAYLOAD="$(jq -n \
  --arg email "$EMAIL_TO" \
  --arg context1 "https://www.w3.org/2018/credentials/v1" \
  --arg context2 "$SCHEMA_CONTEXT_URL" \
  --arg schemaName "$SCHEMA_NAME" \
  --arg orgDid "$ORG_DID" \
  --arg firstName "Maria" \
  --arg lastName "Garcia" \
  --arg employeeId "EMP-$REQUEST_ID" \
  '{
    credentialOffer:[
      {
        emailId:$email,
        credential:{
          "@context":[ $context1, $context2 ],
          type:["VerifiableCredential", $schemaName],
          issuer:{ id:$orgDid },
          issuanceDate:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),
          credentialSubject:{
            firstName:$firstName,
            lastName:$lastName,
            employeeId:$employeeId
          }
        },
        options:{
          proofType:"Ed25519Signature2018",
          proofPurpose:"assertionMethod"
        }
      }
    ],
    protocolVersion:"v2",
    isReuseConnection:true,
    credentialType:"jsonld"
  }')"

ISSUE_RESPONSE=""
ISSUE_STATUS=""
for attempt in $(seq 1 6); do
  ISSUE_RESPONSE="$(curl -sS -X POST "$BASE_URL/orgs/$ORG_ID/credentials/oob/email?credentialType=jsonld" "${auth_header[@]}" -d "$ISSUANCE_PAYLOAD")"
  ISSUE_STATUS="$(echo "$ISSUE_RESPONSE" | jq -r '.statusCode // empty')"

  if [ "$ISSUE_STATUS" = "201" ]; then
    break
  fi

  sleep 5
done

echo "$ISSUE_RESPONSE" | jq .

echo "[8/8] Fetch issued credential list (sanity check endpoint)"
LIST_RESPONSE="$(curl -sS "$BASE_URL/orgs/$ORG_ID/credentials?pageSize=10&pageNumber=1&search=&sortBy=desc&sortField=createDateTime" -H "Authorization: Bearer $TOKEN")"
echo "$LIST_RESPONSE" | jq '{statusCode, message, total: (.data.totalItems // .data.totalRecords // 0)}'

echo "Done."
