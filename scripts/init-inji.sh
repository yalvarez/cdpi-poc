#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — INJI Stack Initialisation Script
# -----------------------------------------------------------------------------
# Single entry point for deploying the INJI stack on a fresh Ubuntu VPS.
# Handles: prerequisites, AMD64 check, .env setup, keystore generation,
# image pull, docker compose up, health verification.
#
# Usage:
#   chmod +x scripts/init-inji.sh
#   bash scripts/init-inji.sh
#
# Re-runs are safe (idempotent). Services already running are restarted
# only when explicitly needed.
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✗ $*${NC}"; }
info() { echo -e "${CYAN}  → $*${NC}"; }

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INJI_DIR="$REPO_ROOT/inji"
ENV_FILE="$INJI_DIR/.env"

echo ""
echo "============================================================"
echo " CDPI PoC — INJI Stack Initialisation"
echo " $(date)"
echo "============================================================"
echo ""

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
echo "── Prerequisites ───────────────────────────────────────────"

if ! command -v docker &>/dev/null; then
  err "Docker is not installed. Run scripts/setup-vps.sh first."
  exit 1
fi
ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

if ! docker compose version &>/dev/null 2>&1; then
  err "Docker Compose v2 is required. Run: apt install docker-compose-plugin"
  exit 1
fi
ok "Docker Compose $(docker compose version --short 2>/dev/null || echo 'v2')"

if ! command -v openssl &>/dev/null; then
  err "openssl is required. Run: apt install openssl"
  exit 1
fi
ok "openssl available"

# ── Step 2: AMD64 architecture check ─────────────────────────────────────────
echo ""
echo "── Architecture ────────────────────────────────────────────"

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  ok "AMD64 — INJI images are AMD64 only, this is compatible"
else
  warn "Architecture: $ARCH"
  warn "INJI images (mosipid/*) have NO ARM64 build."
  warn "Setting DOCKER_DEFAULT_PLATFORM=linux/amd64 for emulation."
  export DOCKER_DEFAULT_PLATFORM=linux/amd64
fi

# ── Step 3: .env setup ────────────────────────────────────────────────────────
echo ""
echo "── Environment configuration ───────────────────────────────"

if [ ! -f "$ENV_FILE" ]; then
  info "No .env found — creating from .env.example"
  cp "$INJI_DIR/.env.example" "$ENV_FILE"
  warn ".env created. Fill in REQUIRED values, then re-run this script."
  warn "Edit: $ENV_FILE"
  echo ""
  cat "$ENV_FILE"
  exit 0
fi
ok ".env exists"

# Validate required variables
source "$ENV_FILE" 2>/dev/null || true

MISSING=0
for VAR in POSTGRES_PASSWORD REDIS_PASSWORD CERTIFY_KEYSTORE_PASSWORD PUBLIC_URL; do
  VAL=$(grep "^${VAR}=" "$ENV_FILE" | cut -d'=' -f2 | tr -d ' ')
  if [ -z "$VAL" ] || echo "$VAL" | grep -q "REQUIRED\|YOUR_"; then
    err "Required variable not set: $VAR"
    MISSING=$((MISSING+1))
  fi
done
if [ "$MISSING" -gt 0 ]; then
  err "$MISSING required variables are missing in $ENV_FILE"
  exit 1
fi
ok "All required .env variables are set"

# Re-source after validation
set -a; source "$ENV_FILE"; set +a

# ── Step 4: Keystore generation ────────────────────────────────────────────────
echo ""
echo "── Keystore (Mimoto OIDC) ──────────────────────────────────"

KEYSTORE="$INJI_DIR/certs/oidckeystore.p12"
if [ -f "$KEYSTORE" ]; then
  ok "Keystore already exists: $KEYSTORE"
else
  info "Generating OIDC keystore..."
  CERTIFY_KEYSTORE_PASSWORD="${CERTIFY_KEYSTORE_PASSWORD:-}" \
    bash "$SCRIPT_DIR/generate-inji-certs.sh"
  ok "Keystore generated"
fi

# ── Step 5: Pull images ────────────────────────────────────────────────────────
echo ""
echo "── Docker images ────────────────────────────────────────────"

read -r -p "  Pull latest INJI images? (y/N): " PULL_CHOICE
if [[ "${PULL_CHOICE,,}" == "y" ]]; then
  info "Pulling INJI images (AMD64 only — this may take a few minutes)..."
  cd "$INJI_DIR"
  docker compose pull
  ok "Images pulled"
else
  ok "Skipping image pull (using cached images)"
fi

# ── Step 6: Start services ────────────────────────────────────────────────────
echo ""
echo "── Starting INJI stack ─────────────────────────────────────"

cd "$INJI_DIR"

RUNNING=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l || echo 0)
if [ "$RUNNING" -gt 0 ]; then
  read -r -p "  INJI services are running. Restart stack? (y/N): " RESTART_CHOICE
  if [[ "${RESTART_CHOICE,,}" == "y" ]]; then
    info "Stopping existing services..."
    docker compose down --remove-orphans
    ok "Stack stopped"
  else
    info "Keeping existing services running"
  fi
fi

info "Starting INJI stack (eSignet starts first — wait ~90s)..."
docker compose up -d

ok "docker compose up -d completed"

# ── Step 7: Wait for healthy state ────────────────────────────────────────────
echo ""
echo "── Waiting for services to be healthy ───────────────────────"

wait_healthy() {
  local svc="$1"
  local max_wait="${2:-180}"
  local elapsed=0
  info "Waiting for $svc (up to ${max_wait}s)..."
  while [ "$elapsed" -lt "$max_wait" ]; do
    STATUS=$(docker compose ps "$svc" 2>/dev/null | tail -1)
    if echo "$STATUS" | grep -q "(healthy)"; then
      ok "$svc is healthy"
      return 0
    fi
    if echo "$STATUS" | grep -qE "(Exit|Error|exited)"; then
      err "$svc exited unexpectedly"
      docker compose logs --tail=30 "$svc" 2>/dev/null || true
      return 1
    fi
    sleep 5
    elapsed=$((elapsed+5))
    echo -n "."
  done
  echo ""
  err "$svc did not become healthy within ${max_wait}s"
  return 1
}

# Startup order: postgres + redis → esignet → inji-certify → mimoto → inji-web
wait_healthy postgres 60
wait_healthy redis 60
wait_healthy esignet 150     # eSignet needs ~90s to start Spring Boot + DB init
wait_healthy inji-certify 180 # Certify waits for esignet + SoftHSM init (~120s)
wait_healthy mimoto 120
wait_healthy inji-web 60

echo ""

# ── Step 8: Run health check ──────────────────────────────────────────────────
echo "── Running health check ─────────────────────────────────────"
bash "$SCRIPT_DIR/health-check-inji.sh"

echo ""
echo "============================================================"
echo " INJI stack is ready."
echo ""
echo " Public URL: ${PUBLIC_URL}"
echo ""
echo " Access points:"
echo "   Inji Web wallet:   ${PUBLIC_URL}:3001"
echo "   Certify API:       ${PUBLIC_URL}:8091/v1/certify"
echo "   eSignet OIDC:      ${PUBLIC_URL}:8088/v1/esignet"
echo "   Email capture:     ${PUBLIC_URL}:8026"
echo ""
echo " Test credentials (mock):"
echo "   UINs: 1234567890 / 0987654321 / 1122334455 / 5860356276 / 2154189532"
echo "   OTP:  111111 (all)"
echo ""
echo " Supported credential types:"
echo "   EmploymentCertification  — Certificación de Empleo"
echo "   EducationalCredential    — Credencial Educativa"
echo "   ProfessionalLicense      — Licencia Profesional"
echo "   CivilIdentity            — Identidad Civil"
echo ""
echo " Day 5 OIDC swap: see inji/docs/oidc-swap-procedure.md"
echo "============================================================"
echo ""
