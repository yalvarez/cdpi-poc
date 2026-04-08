#!/usr/bin/env bash
# CDPI PoC — INJI Stack Health Check
# Usage: bash scripts/health-check-inji.sh

set -euo pipefail

VPS_IP=$(curl -s ifconfig.me 2>/dev/null || echo "localhost")
PASS=0; FAIL=0

check() {
  local name=$1; local cmd=$2
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
check "redis"     "docker compose ps redis | grep -q '(healthy)'"

echo ""
echo "── INJI services ───────────────────────────────────────────"
check "esignet"        "docker compose ps esignet | grep -q '(healthy)'"
check "inji-certify"   "docker compose ps inji-certify | grep -q '(healthy)'"
check "certify-nginx"  "docker compose ps certify-nginx | grep -q 'running\|Up'"
check "mimoto"         "docker compose ps mimoto | grep -q '(healthy)'"
check "inji-web"       "docker compose ps inji-web | grep -q '(healthy)\|running\|Up'"
check "mailpit"        "docker compose ps mailpit | grep -q 'running\|Up'"

echo ""
echo "── Endpoints ───────────────────────────────────────────────"
check "eSignet OIDC discovery"    "curl -sf http://localhost:8088/v1/esignet/.well-known/openid-configuration"
check "Certify well-known"        "curl -sf http://localhost:8091/.well-known/openid-credential-issuer"
check "Certify health"            "curl -sf http://localhost:8091/health"
check "Mimoto health"             "curl -sf http://localhost:8099/residentmobileapp/actuator/health"
check "Inji Web"                  "curl -sf http://localhost:3001"

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
  echo "   Inji Web wallet:   http://$VPS_IP:3001"
  echo "   Certify API:       http://$VPS_IP:8091/v1/certify"
  echo "   eSignet OIDC:      http://$VPS_IP:8088/v1/esignet"
  echo "   Email capture:     http://$VPS_IP:8026"
  echo ""
  echo " Test credentials (mock):"
  echo "   UIN: 5860356276 or 2154189532   OTP: 111111"
else
  echo " ✗ $FAIL checks failed / $PASS passed"
  echo " Run: docker compose logs <service-name>"
  exit 1
fi
echo "============================================================"
echo ""
