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
  echo "   MinIO console:  http://$VPS_IP:9001"
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
