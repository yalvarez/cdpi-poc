#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — INJI Stack Health Check
# Usage: bash scripts/health-check-inji.sh
# =============================================================================

set -euo pipefail

VPS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "localhost")
PASS=0; FAIL=0

check() {
  local name=$1 cmd=$2
  if eval "$cmd" &>/dev/null; then
    echo "  ✓ $name"; PASS=$((PASS+1))
  else
    echo "  ✗ $name  ← FAILED"; FAIL=$((FAIL+1))
  fi
}

echo ""
echo "============================================================"
echo " CDPI PoC — INJI Stack Health Check"
echo " $(date)"
echo "============================================================"
echo ""

cd "$(dirname "$0")/../inji" 2>/dev/null || cd inji 2>/dev/null || true

echo "── Infrastructure ──────────────────────────────────────────"
check "postgres"  "docker compose ps postgres | grep -q '(healthy)'"
check "redis"     "docker compose ps redis    | grep -q '(healthy)'"

echo ""
echo "── INJI services ───────────────────────────────────────────"
check "mock-identity-system"  "docker compose ps mock-identity-system | grep -q '(healthy)'"
check "esignet"               "docker compose ps esignet      | grep -q '(healthy)'"
check "inji-certify"          "docker compose ps inji-certify | grep -q '(healthy)'"
check "certify-nginx"         "docker compose ps certify-nginx        | grep -qiE 'running|up'"
check "mimoto-config-server"  "docker compose ps mimoto-config-server | grep -qiE 'running|up'"
check "mimoto"                "docker compose ps mimoto   | grep -q '(healthy)'"
check "inji-web"              "docker compose ps inji-web | grep -qiE '(healthy)|running|up'"
check "mailpit"               "docker compose ps mailpit  | grep -qiE 'running|up'"

echo ""
echo "── Endpoints ───────────────────────────────────────────────"
check "eSignet OIDC discovery"     "curl -sf http://localhost:8088/oidc/.well-known/openid-configuration"
check "Certify well-known"         "curl -sf http://localhost:8091/.well-known/openid-credential-issuer"
check "Certify health"             "curl -sf http://localhost:8091/health"
check "Mimoto health (401 ok)"     "curl -s -o /dev/null -w '%{http_code}' http://localhost:8099/residentmobileapp/actuator/health | grep -qE '^[24]'"
check "Inji Web"                   "curl -sf http://localhost:3001"

echo ""
echo "── Resource usage ──────────────────────────────────────────"
echo "  RAM:  $(free -h | awk '/^Mem:/{printf "%s used / %s total", $3, $2}')"
echo "  Swap: $(free -h | awk '/^Swap:/{printf "%s used / %s total", $3, $2}')"

echo ""
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  echo " ✓ All $PASS checks passed — INJI stack is ready"
  echo ""
  echo " Access points:"
  echo "   Inji Web wallet:       http://$VPS_IP:3001"
  echo "   Certify API:           http://$VPS_IP:8091/v1/certify"
  echo "   eSignet OIDC:          http://$VPS_IP:8088/v1/esignet"
  echo "   Mock Identity System:  http://$VPS_IP:8082"
  echo "   Email capture:         http://$VPS_IP:8026"
  echo ""
  echo " Test credentials (mock profile):"
  echo "   UINs: 5860356276 / 2154189532 / 1234567890 / 0987654321 / 1122334455"
  echo "   OTP:  111111 (valid for any UIN above)"
else
  echo " ✗ $FAIL checks failed / $PASS passed"
  echo ""
  echo " Troubleshooting:"
  echo "   docker compose logs <service-name>   — show service logs"
  echo "   docker compose ps                    — show container states"
  echo "   bash scripts/init-inji.sh            — re-run initialiser"
  exit 1
fi
echo "============================================================"
echo ""
