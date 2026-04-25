#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — INJI Stack Initialiser
# -----------------------------------------------------------------------------
# Single entry point for a complete INJI deployment.
# Asks only 1 essential question; all secrets are generated automatically.
#
# Usage:
#   bash scripts/init-inji.sh
#
# Re-runs are safe. Existing deployment → offered fast restart path.
# =============================================================================

set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INJI_DIR="$REPO_DIR/inji"
ENV_FILE="$INJI_DIR/.env"
CREDS_REPORT="$INJI_DIR/.credentials-report"

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✗ $*${NC}"; }
info() { echo -e "${CYAN}  → $*${NC}"; }

# --- Utility functions -------------------------------------------------------

sanitize_host() {
  local v
  v="$(printf '%s' "$1" | sed 's/^ *//;s/ *$//')"
  v="${v#http://}"
  v="${v#https://}"
  v="${v%%/*}"
  printf '%s' "$v"
}

ask() {
  local prompt="$1" default="${2:-}" value
  while true; do
    [ -n "$default" ] \
      && printf "%s [%s]: " "$prompt" "$default" >&2 \
      || printf "%s: "      "$prompt"             >&2
    read -r value
    [ -z "$value" ] && value="$default"
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    echo "A value is required." >&2
  done
}

ask_yes_no() {
  local prompt="$1" default="${2:-N}" reply suffix="[y/N]"
  [ "$default" = "Y" ] && suffix="[Y/n]"
  while true; do
    printf "%s %s: " "$prompt" "$suffix" >&2
    read -r reply
    reply="$(printf '%s' "$reply" | sed 's/^ *//;s/ *$//')"
    [ -z "$reply" ] && reply="$default"
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
    esac
    echo "Please answer yes or no." >&2
  done
}

print_banner() {
  echo
  printf '\033[1;36m'
  cat <<'ASCII'
  ___  _  _  ___  ___
 |_ _|| \| ||_ _||_ _|
  | | | .` | | |  | |
 |___||_|\_||___||___|
ASCII
  printf '\033[0m'
  echo "  Centre for Digital Public Infrastructure"
  echo "  INJI PoC Initialiser"
  echo
}

# Wait for a service to report (healthy) in docker compose ps
wait_healthy() {
  local svc="$1" max_wait="${2:-180}" elapsed=0
  info "Waiting for ${svc} (up to ${max_wait}s)..."
  while [ "$elapsed" -lt "$max_wait" ]; do
    local STATUS
    STATUS=$(cd "$INJI_DIR" && docker compose ps "$svc" 2>/dev/null | tail -1)
    if echo "$STATUS" | grep -q "(healthy)"; then
      echo ""
      ok "${svc} is healthy"
      return 0
    fi
    if echo "$STATUS" | grep -qE "Exit [^0]|exited \([^0]"; then
      echo ""
      err "${svc} exited with error — check logs:"
      (cd "$INJI_DIR" && docker compose logs --tail=40 "$svc" 2>/dev/null) || true
      return 1
    fi
    sleep 5; elapsed=$((elapsed+5))
    printf "."
  done
  echo ""
  err "${svc} did not become healthy within ${max_wait}s"
  (cd "$INJI_DIR" && docker compose logs --tail=20 "$svc" 2>/dev/null) || true
  return 1
}

# Wait for a service to be in running/Up state (no healthcheck defined)
wait_running() {
  local svc="$1" max_wait="${2:-60}" elapsed=0
  info "Waiting for ${svc} to start..."
  while [ "$elapsed" -lt "$max_wait" ]; do
    local STATUS
    STATUS=$(cd "$INJI_DIR" && docker compose ps "$svc" 2>/dev/null | tail -1)
    if echo "$STATUS" | grep -qiE "running|up [0-9]"; then
      echo ""
      ok "${svc} is running"
      return 0
    fi
    if echo "$STATUS" | grep -qE "Exit [^0]|exited \([^0]"; then
      echo ""
      err "${svc} exited with error"
      return 1
    fi
    sleep 3; elapsed=$((elapsed+3))
    printf "."
  done
  echo ""
  err "${svc} did not start within ${max_wait}s"
  return 1
}

# =============================================================================
# BANNER + PREREQUISITES
# =============================================================================

print_banner

for cmd in docker openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "Error: '$cmd' not found. Run scripts/setup-vps.sh first." >&2; exit 1; }
done

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker is not running or this user cannot access it." >&2; exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Error: Docker Compose v2 required. Run: apt install docker-compose-plugin" >&2; exit 1
fi

ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
ok "Docker Compose $(docker compose version --short 2>/dev/null || echo 'v2')"
ok "openssl available"

# =============================================================================
# AMD64 CHECK
# =============================================================================
echo ""
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  ok "Architecture: AMD64 (INJI images are AMD64 only — compatible)"
else
  warn "Architecture: $ARCH — INJI images have no ARM64 build."
  warn "Setting DOCKER_DEFAULT_PLATFORM=linux/amd64 for emulation."
  export DOCKER_DEFAULT_PLATFORM=linux/amd64
fi

# =============================================================================
# RE-RUN DETECTION
# If a .env already exists, offer a fast restart path instead of full re-init.
# =============================================================================

if [ -f "$ENV_FILE" ]; then
  echo ""
  echo "  Existing deployment found."
  echo
  if ask_yes_no "Restart existing stack and re-run health check? (No = full re-initialization)" "Y"; then
    echo ""
    _ev() { grep "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
    PUB_URL="$(_ev PUBLIC_URL)"

    cd "$INJI_DIR"
    info "Stopping existing services..."
    docker compose down --remove-orphans
    info "Starting INJI stack..."
    docker compose up -d

    echo ""
    echo "── Waiting for services ─────────────────────────────────────"
    # Startup order: postgres+redis → mock-identity-system → esignet
    #                → inji-certify → certify-nginx+mimoto-config-server
    #                → mimoto → inji-web+mailpit
    wait_healthy postgres              60
    wait_healthy redis                 60
    wait_healthy mock-identity-system 180
    wait_healthy esignet              150
    wait_healthy inji-certify         180
    wait_running certify-nginx         60
    wait_running mimoto-config-server  30
    wait_healthy mimoto               120
    wait_healthy inji-web              60

    echo ""
    bash "$SCRIPT_DIR/health-check-inji.sh"
    echo ""
    ok "INJI stack restarted.  Inji Web: ${PUB_URL}:3001"
    exit 0
  fi
fi

# =============================================================================
# INTERACTIVE PROMPT — 1 question only; everything else is auto-generated
# =============================================================================

echo ""
echo "  1 question. All secrets are auto-generated and"
echo "  printed in full at the end — save that report securely."
echo ""

DETECTED_IP="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null \
  || hostname -I 2>/dev/null | awk '{print $1}' \
  || true)"
DETECTED_IP="$(sanitize_host "${DETECTED_IP:-}")"

VPS_HOST="$(ask "VPS public IP or hostname (without http://)" "$DETECTED_IP")"
VPS_HOST="$(sanitize_host "$VPS_HOST")"
PUBLIC_URL="http://${VPS_HOST}"

# =============================================================================
# GENERATE ALL SECRETS
# =============================================================================

POSTGRES_PASSWORD="$(openssl rand -hex 16)"
REDIS_PASSWORD="$(openssl rand -hex 16)"
CERTIFY_KEYSTORE_PASSWORD="$(openssl rand -hex 16)"

# Schema-user passwords — set via ALTER USER after postgres is healthy.
# The services themselves connect as the main 'inji' superuser (POSTGRES_PASSWORD).
# These passwords are for direct DB access by schema owners only.
CERTIFY_DB_PASS="$(openssl rand -hex 16)"
ESIGNET_DB_PASS="$(openssl rand -hex 16)"
MIMOTO_DB_PASS="$(openssl rand -hex 16)"
MOCKID_DB_PASS="$(openssl rand -hex 16)"

# =============================================================================
# WRITE .env
# =============================================================================

if [ -f "$ENV_FILE" ]; then
  if ! ask_yes_no "Existing $ENV_FILE found. Overwrite it?" "N"; then
    echo "Aborted. Existing .env left untouched."
    exit 0
  fi
fi

cat > "$ENV_FILE" <<EOF
# Generated by scripts/init-inji.sh — $(date)
# DO NOT COMMIT THIS FILE TO GIT

# ── Network ──────────────────────────────────────────────────────────────────
# Used by Certify for .well-known issuer metadata, OID4VCI redirect URIs,
# and by Mimoto for wallet callbacks. Must be the public-facing base URL.
PUBLIC_URL=${PUBLIC_URL}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
POSTGRES_USER=inji
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=mosip_db

# ── Redis ─────────────────────────────────────────────────────────────────────
REDIS_PASSWORD=${REDIS_PASSWORD}

# ── Inji Certify ──────────────────────────────────────────────────────────────
# CERTIFY_PROFILE=default         → mock CSV data (no real DB needed — PoC testing)
# CERTIFY_PROFILE=postgres-local  → real PostgreSQL data source (Day 5 integration)
CERTIFY_PROFILE=default
CERTIFY_KEYSTORE_PASSWORD=${CERTIFY_KEYSTORE_PASSWORD}

# ── Day 5 — OIDC swap ─────────────────────────────────────────────────────────
# On Day 5 replace eSignet with the country's real Authorization Server.
# Update these and restart: docker compose restart inji-certify certify-nginx mimoto
# See docs/oidc-swap-procedure.md for the full procedure.
#
# COUNTRY_OIDC_ISSUER_URL=https://oidc.country.gov/realms/production
# COUNTRY_OIDC_CLIENT_ID=inji-certify-poc
# COUNTRY_OIDC_CLIENT_SECRET=<provided-by-country>
EOF

ok ".env written to $ENV_FILE"

# =============================================================================
# CREDENTIALS REPORT
# =============================================================================

echo ""
printf '\033[1;33m'
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           INJI CREDENTIALS REPORT — SAVE THIS NOW           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
printf '\033[0m'
printf "  %-36s  %s\n" "PUBLIC_URL"               "$PUBLIC_URL"
echo ""
printf "  %-36s  %s\n" "POSTGRES_PASSWORD"         "$POSTGRES_PASSWORD"
printf "  %-36s  %s\n" "REDIS_PASSWORD"            "$REDIS_PASSWORD"
printf "  %-36s  %s\n" "CERTIFY_KEYSTORE_PASSWORD" "$CERTIFY_KEYSTORE_PASSWORD"
echo ""
printf "  DB schema user passwords (set after startup):\n"
printf "  %-36s  %s\n" "certify_user"  "$CERTIFY_DB_PASS"
printf "  %-36s  %s\n" "esignet_user"  "$ESIGNET_DB_PASS"
printf "  %-36s  %s\n" "mimoto_user"   "$MIMOTO_DB_PASS"
printf "  %-36s  %s\n" "mockid_user"   "$MOCKID_DB_PASS"
echo ""
printf '\033[1;33m'
printf "  Saved to: %s\n" "$CREDS_REPORT"
printf '\033[0m'

cat > "$CREDS_REPORT" <<EOF
# INJI Credentials Report — $(date)
# Generated by scripts/init-inji.sh — DO NOT COMMIT
PUBLIC_URL=${PUBLIC_URL}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
CERTIFY_KEYSTORE_PASSWORD=${CERTIFY_KEYSTORE_PASSWORD}
CERTIFY_DB_PASS=${CERTIFY_DB_PASS}
ESIGNET_DB_PASS=${ESIGNET_DB_PASS}
MIMOTO_DB_PASS=${MIMOTO_DB_PASS}
MOCKID_DB_PASS=${MOCKID_DB_PASS}
EOF

echo ""

# =============================================================================
# KEYSTORE GENERATION
# =============================================================================

echo "── Keystore (OIDC signing key) ──────────────────────────────"
KEYSTORE="$INJI_DIR/certs/oidckeystore.p12"
if [ -f "$KEYSTORE" ]; then
  ok "Keystore already exists: $KEYSTORE"
else
  info "Generating OIDC keystore (PKCS12)..."
  CERTIFY_KEYSTORE_PASSWORD="${CERTIFY_KEYSTORE_PASSWORD}" \
    bash "$SCRIPT_DIR/generate-inji-certs.sh"
  ok "Keystore generated: $KEYSTORE"
fi

# =============================================================================
# IMAGE PULL
# =============================================================================

echo ""
echo "── Docker images ────────────────────────────────────────────"
if ask_yes_no "Pull latest INJI images? (recommended on first deploy, ~10 min)" "Y"; then
  info "Pulling INJI images (AMD64 only)..."
  cd "$INJI_DIR"
  docker compose pull
  ok "Images pulled"
else
  ok "Skipping image pull (using cached images)"
fi

# =============================================================================
# OPTIONAL FULL RESET
# =============================================================================

echo ""
echo "── Stack startup ────────────────────────────────────────────"
cd "$INJI_DIR"

RUNNING=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l || echo 0)
if [ "$RUNNING" -gt 0 ]; then
  if ask_yes_no "Existing services detected. Full reset? (docker compose down -v — DELETES DB data)" "N"; then
    info "Removing containers and volumes..."
    docker compose down -v --remove-orphans
    ok "Stack wiped"
  else
    info "Stopping services without wiping volumes..."
    docker compose down --remove-orphans
    ok "Stack stopped"
  fi
fi

# =============================================================================
# START STACK
# =============================================================================

info "Starting INJI stack..."
cd "$INJI_DIR"
docker compose up -d
ok "docker compose up -d completed"

# =============================================================================
# WAIT FOR SERVICES
# Startup order (each depends_on the previous being healthy):
#   1. postgres + redis         (infra, fast)
#   2. mock-identity-system     (Spring Boot + DB init, ~90s)
#   3. esignet                  (Spring Boot, depends on mock-identity-system)
#   4. inji-certify             (Spring Boot + PKCS12 key init, ~120s)
#   5. certify-nginx            (Nginx proxy, starts immediately)
#   6. mimoto-config-server     (Nginx config server, starts immediately)
#   7. mimoto                   (Spring Boot, depends on certify)
#   8. inji-web + mailpit       (static Nginx + SMTP capture)
# =============================================================================

echo ""
echo "── Waiting for services to be healthy ───────────────────────"
echo "  Total startup time is typically 5-8 minutes."
echo ""

wait_healthy postgres              60
wait_healthy redis                 60
wait_healthy mock-identity-system 180
wait_healthy esignet              150
wait_healthy inji-certify         180
wait_running certify-nginx         60
wait_running mimoto-config-server  30
wait_healthy mimoto               120
wait_healthy inji-web              60

echo ""

# =============================================================================
# SET REAL DB SCHEMA USER PASSWORDS
# Replaces the CHANGE_ME_* placeholder passwords from postgres-init.sql with
# the generated secrets. Services connect as the main 'inji' superuser, so
# this doesn't affect service operation — it secures direct DB access.
# =============================================================================

echo "── Securing DB schema users ─────────────────────────────────"
info "Updating schema user passwords..."

cd "$INJI_DIR"
docker compose exec -T postgres psql -U inji -d mosip_db \
  -c "ALTER USER certify_user WITH PASSWORD '${CERTIFY_DB_PASS}';" \
  -c "ALTER USER esignet_user WITH PASSWORD '${ESIGNET_DB_PASS}';" \
  -c "ALTER USER mimoto_user  WITH PASSWORD '${MIMOTO_DB_PASS}';"  \
  -c "ALTER USER mockid_user  WITH PASSWORD '${MOCKID_DB_PASS}';"  \
  >/dev/null 2>&1 && ok "Schema user passwords updated" \
  || warn "Could not update schema user passwords (non-critical — services use main inji user)"

# =============================================================================
# HEALTH CHECK
# =============================================================================

echo ""
echo "── Health check ─────────────────────────────────────────────"
bash "$SCRIPT_DIR/health-check-inji.sh"

# =============================================================================
# FINAL REPORT
# =============================================================================

echo ""
printf '\033[1;32m'
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   INJI STACK IS READY                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
printf '\033[0m'
echo ""
echo "  Access points:"
printf "   %-30s  %s\n" "Inji Web wallet"   "${PUBLIC_URL}:3001"
printf "   %-30s  %s\n" "Certify API"       "${PUBLIC_URL}:8091/v1/certify"
printf "   %-30s  %s\n" "eSignet OIDC"      "${PUBLIC_URL}:8088/v1/esignet"
printf "   %-30s  %s\n" "Mock ID System"    "${PUBLIC_URL}:8082"
printf "   %-30s  %s\n" "Email capture"     "${PUBLIC_URL}:8026"
echo ""
echo "  Test credentials (mock profile):"
echo "   UINs:  5860356276 / 2154189532 / 1234567890 / 0987654321 / 1122334455"
echo "   OTP:   111111 (valid for any UIN above)"
echo ""
echo "  Supported credential types:"
echo "   EmploymentCertification  — Certificación de Empleo"
echo "   EducationalCredential    — Credencial Educativa"
echo "   ProfessionalLicense      — Licencia Profesional"
echo "   CivilIdentity            — Identidad Civil"
echo ""
echo "  Day 5 OIDC swap:  inji/docs/oidc-swap-procedure.md"
echo "  Credentials file: $CREDS_REPORT"
echo ""
