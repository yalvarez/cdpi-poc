#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Health Check Script
# Run after deployment to verify all services are up
# Usage: bash scripts/health-check.sh
# =============================================================================

set -euo pipefail

VPS_IP=$(curl -s ifconfig.me 2>/dev/null || echo "localhost")
PASS=0
FAIL=0

check() {
  local name=$1
  local cmd=$2
  if eval "$cmd" &>/dev/null; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name  ← FAILED"
    FAIL=$((FAIL + 1))
  fi
}

platform_admin_shared_agent_ready() {
  local row status endpoint token_url
  row="$(docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD:-}" \
    psql -U "${POSTGRES_USER:-credebl}" -d "${POSTGRES_DB:-credebl}" -Atqc "
      SELECT COALESCE(oa.\"agentSpinUpStatus\"::text,''), COALESCE(oa.\"agentEndPoint\", '')
      FROM organisation o
      LEFT JOIN org_agents oa ON oa.\"orgId\" = o.id
      WHERE o.name = 'Platform-admin'
      LIMIT 1;
    " 2>/dev/null | tr -d '\r')"

  status="${row%%|*}"
  endpoint="${row#*|}"

  # Reject placeholders such as empty strings or bare protocol values.
  if [ "$status" != "2" ] || [ -z "$endpoint" ] || [ "$endpoint" = "http://" ] || [ "$endpoint" = "https://" ]; then
    return 1
  fi

  if [[ ! "$endpoint" =~ ^https?:// ]]; then
    token_url="http://${endpoint}/agent/token"
  else
    token_url="${endpoint%/}/agent/token"
  fi

  curl -sf --max-time 8 -X POST -H "Authorization: ${AGENT_API_KEY:-}" "$token_url" >/dev/null
}
platform_config_host_format_ok() {
  docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD:-}" \
    psql -U "${POSTGRES_USER:-credebl}" -d "${POSTGRES_DB:-credebl}" -Atqc "
      SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM platform_config
        WHERE COALESCE(\"externalIp\", '') <> ''
          AND COALESCE(\"inboundEndpoint\", '') <> ''
          AND \"externalIp\" NOT LIKE 'http%'
          AND \"inboundEndpoint\" NOT LIKE 'http%'
      ) THEN 'ok' ELSE 'bad' END;
    " | grep -q '^ok$'
}

agent_runtime_envs_ok() {
  docker compose exec -T agent-service sh -ec '
    [ -n "${PLATFORM_WALLET_NAME:-}" ] &&
    [ -n "${PLATFORM_WALLET_PASSWORD:-}" ] &&
    [ -n "${AGENT_API_KEY:-}" ] &&
    [ -n "${WALLET_STORAGE_HOST:-}" ] &&
    [ -n "${WALLET_STORAGE_PORT:-}" ] &&
    [ -n "${WALLET_STORAGE_USER:-}" ] &&
    [ -n "${WALLET_STORAGE_PASSWORD:-}" ] &&
    [ -n "${SOCKET_HOST:-}" ] &&
    [ -n "${AGENT_PROTOCOL:-}" ] &&
    [ -n "${AFJ_VERSION:-}" ]
  '
}

agent_provisioning_runtime_ok() {
  docker compose exec -T agent-provisioning sh -ec '
    [ -n "${ROOT_PATH:-}" ] &&
    [ -n "${AFJ_AGENT_SPIN_UP:-}" ] &&
    [ -n "${AFJ_AGENT_ENDPOINT_PATH:-}" ] &&
    [ -n "${AFJ_VERSION:-}" ] &&
    command -v docker-compose >/dev/null 2>&1 &&
    [ -S /var/run/docker.sock ]
  '
}

agent_runtime_file_ok() {
  docker compose exec -T agent-provisioning sh -ec '
    [ -f /app/agent.env ] &&
    grep -q "^AGENT_HTTP_URL=http://" /app/agent.env &&
    grep -q "^AGENT_WS_URL=ws://" /app/agent.env &&
    grep -q "^CONNECT_TIMEOUT=[0-9][0-9]*$" /app/agent.env &&
    grep -q "^MAX_CONNECTIONS=[0-9][0-9]*$" /app/agent.env &&
    grep -q "^IDLE_TIMEOUT=[0-9][0-9]*$" /app/agent.env &&
    grep -q "^SESSION_ACQUIRE_TIMEOUT=[0-9][0-9]*$" /app/agent.env &&
    grep -q "^SESSION_LIMIT=[0-9][0-9]*$" /app/agent.env &&
    grep -q "^INMEMORY_LRU_CACHE_LIMIT=[0-9][0-9]*$" /app/agent.env &&
    grep -q "^TRUST_SERVICE_AUTH_TYPE=NoAuth$" /app/agent.env &&
    grep -q "^TRUST_LIST_URL=https://" /app/agent.env
  '
}

schema_file_server_auth_envs_ok() {
  [ -n "${SCHEMA_FILE_SERVER_URL:-}" ] &&
  [ -n "${SCHEMA_FILE_SERVER_TOKEN:-}" ] &&
  [ -n "${JWT_TOKEN_SECRET:-}" ] &&
  [ -n "${ISSUER:-}" ] &&
  printf '%s' "${SCHEMA_FILE_SERVER_URL}" | grep -Eq '/schemas/?$'
}

schema_file_server_storage_writable() {
  docker compose exec -T schema-file-server sh -ec '
    [ -d /app/schemas ] &&
    [ -w /app/schemas ]
  '
}
echo ""
echo "============================================================"
echo " CDPI PoC — Health Check"
echo " $(date)"
echo "============================================================"
echo ""

cd "$(dirname "$0")/../credebl" 2>/dev/null || cd credebl 2>/dev/null || true

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

KEYCLOAK_REALM_CHECK=${KEYCLOAK_REALM:-credebl-realm}
STUDIO_ORIGIN=${STUDIO_URL:-http://localhost:3000}
STUDIO_ORIGIN=${STUDIO_ORIGIN%/}

echo "── Infrastructure ──────────────────────────────────────────"
check "postgres"   "docker compose ps postgres | grep -q '(healthy)'"
check "redis"      "docker compose ps redis | grep -q '(healthy)'"
check "nats"       "docker compose ps nats | grep -q '(healthy)'"
check "keycloak"   "docker compose ps keycloak | grep -q '(healthy)'"
check "minio"      "docker compose ps minio | grep -q '(healthy)'"
check "minio-setup" "docker inspect --format='{{.State.Status}} {{.State.ExitCode}}' credebl-minio-setup 2>/dev/null | grep -Eqi '^exited 0$'"
check "mailpit"    "docker compose ps mailpit | grep -q 'running\|Up'"

echo ""
echo "── CREDEBL services ────────────────────────────────────────"
check "platform-admin-bootstrap" "docker inspect --format='{{.State.Status}} {{.State.ExitCode}}' credebl-platform-admin-bootstrap 2>/dev/null | grep -Eqi '^(running|exited 0)$'"
check "api-gateway"        "docker compose ps api-gateway | grep -q 'running\|Up'"
check "studio"             "docker compose ps studio | grep -q 'running\|Up'"
check "user"               "docker compose ps user | grep -q 'running\|Up'"
check "utility"            "docker compose ps utility | grep -q 'running\|Up'"
check "connection"         "docker compose ps connection | grep -q 'running\|Up'"
check "issuance"           "docker compose ps issuance | grep -q 'running\|Up'"
check "ledger"             "docker compose ps ledger | grep -q 'running\|Up'"
check "organization"       "docker compose ps organization | grep -q 'running\|Up'"
check "verification"       "docker compose ps verification | grep -q 'running\|Up'"
check "agent-provisioning" "docker compose ps agent-provisioning | grep -q 'running\|Up'"
check "agent-service"      "docker compose ps agent-service | grep -q 'running\|Up'"
check "cloud-wallet"       "docker compose ps cloud-wallet | grep -q 'running\|Up'"
check "schema-file-server" "docker compose ps schema-file-server | grep -q 'running\|Up'"
check "shared-wallet envs" "[ -n \"${PLATFORM_WALLET_PASSWORD:-}\" ] && [ -n \"${AGENT_API_KEY:-}\" ] && [ -n \"${WALLET_STORAGE_PASSWORD:-}\" ] && [ -n \"${SOCKET_HOST:-}\" ]"
check "platform-config host format" "platform_config_host_format_ok"
check "agent runtime envs" "agent_runtime_envs_ok"
check "agent-provisioning runtime" "agent_provisioning_runtime_ok"
check "child agent runtime file" "agent_runtime_file_ok"
check "schema-file-server auth envs" "schema_file_server_auth_envs_ok"
check "schema-file-server writable storage" "schema_file_server_storage_writable"
check "platform-admin shared agent" "platform_admin_shared_agent_ready"

echo ""
echo "── Endpoints ───────────────────────────────────────────────"
check "API Gateway HTTP" "curl -sf http://localhost:5000/api-json | grep -q 'openapi'"
check "Studio HTTP"      "curl -sf http://localhost:3000 | grep -qi '<html'"
check "API Gateway CORS" "curl -si -X OPTIONS http://localhost:5000/api-json -H \"Origin: ${STUDIO_ORIGIN}\" -H 'Access-Control-Request-Method: GET' | tr -d '\r' | grep -Fqi \"access-control-allow-origin: ${STUDIO_ORIGIN}\""
check "Keycloak HTTP"    "curl -sf http://localhost:8080/realms/${KEYCLOAK_REALM_CHECK}/.well-known/openid-configuration | grep -q 'issuer'"
check "MinIO HTTP"       "curl -sf http://localhost:9000/minio/health/live"
check "Mailpit HTTP"     "curl -sf http://localhost:8025"
check "Schema server"    "curl -sf http://localhost:4000"

echo ""
echo "── Resource usage ──────────────────────────────────────────"
echo "  RAM:  $(free -h | awk '/^Mem:/{printf "%s used / %s total", $3, $2}')"
echo "  Swap: $(free -h | awk '/^Swap:/{printf "%s used / %s total", $3, $2}')"
echo "  Disk: $(df -h / | awk 'NR==2{printf "%s used / %s total (%s free)", $3, $2, $4}')"

echo ""
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  echo " ✓ All $PASS checks passed — PoC stack is ready"
  echo ""
  echo " Access points:"
  echo "   Studio:         http://$VPS_IP:3000"
  echo "   CREDEBL API:    http://$VPS_IP:5000"
  echo "   Keycloak:       http://$VPS_IP:8080"
  echo "   MinIO console:  http://$VPS_IP:${MINIO_CONSOLE_PORT:-9011}"
  echo "   Email capture:  http://$VPS_IP:8025"
  echo "   Schema server:  http://$VPS_IP:4000"
else
  echo " ✗ $FAIL checks failed / $PASS passed"
  echo ""
  echo " Run: docker compose logs <service-name>"
  echo " See: docs/deployment-manual.md#troubleshooting"
  exit 1
fi
echo "============================================================"
echo ""
