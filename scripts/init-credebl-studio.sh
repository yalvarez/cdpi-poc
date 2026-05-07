#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL Studio initializer
# -----------------------------------------------------------------------------
# Builds and starts the Studio frontend independently from the core stack.
# The core stack (init-credebl.sh) must already be running.
#
# Usage:
#   bash scripts/init-credebl-studio.sh
#
# What it does:
#   1. Verifies the core stack is running (api-gateway + keycloak healthy)
#   2. Asks whether to rebuild the Studio image (skip if already built)
#   3. Builds the Studio Next.js image (~5-8 min on first run)
#   4. Starts Studio on port 3000
#   5. Uploads CREDEBL logo to MinIO (for email branding)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDEBL_DIR="$REPO_DIR/credebl"
STUDIO_DIR="$CREDEBL_DIR/studio"
ENV_FILE="$CREDEBL_DIR/.env"

# --- Utility functions -------------------------------------------------------

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply suffix="[y/N]"
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

die() { echo "Error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }

# --- Check core .env exists --------------------------------------------------

[ -f "$ENV_FILE" ] || die "Core .env not found at $ENV_FILE — run init-credebl.sh first."

# Load .env so we have VPS_HOST, STUDIO_URL, etc. available
set -a
# shellcheck disable=SC1090
source <(grep -E '^[A-Z_]+=' "$ENV_FILE")
set +a

# --- Banner ------------------------------------------------------------------

echo
printf '\033[1;36m'
cat <<'ASCII'
   ____  ____  ____  ___
  / ___||  _ \|  _ \|_ _|
 | |    | | | || |_) || |
 | |___ | |_| ||  __/ | |
  \____||____/ |_|   |___|
ASCII
printf '\033[0m'
echo "  Centre for Digital Public Infrastructure"
echo "  CREDEBL Studio initializer"
echo

# --- Verify core stack is running --------------------------------------------

echo "Checking that the core stack is running..."

api_health="$(docker inspect credebl-api-gateway --format '{{.State.Health.Status}}' 2>/dev/null || true)"
kc_health="$(docker inspect credebl-keycloak --format '{{.State.Health.Status}}' 2>/dev/null || true)"

if [ "$api_health" != "healthy" ]; then
  die "credebl-api-gateway is not healthy (status: ${api_health:-not found}). Run init-credebl.sh first."
fi
if [ "$kc_health" != "healthy" ]; then
  die "credebl-keycloak is not healthy (status: ${kc_health:-not found}). Run init-credebl.sh first."
fi
ok "Core stack is running."

# --- Studio image check ------------------------------------------------------

cd "$STUDIO_DIR"

STUDIO_IMAGE="cdpi-credebl-studio-studio"
SKIP_BUILD=false

if docker image inspect "$STUDIO_IMAGE" >/dev/null 2>&1; then
  echo
  if ask_yes_no "Studio image already exists. Skip rebuild? (answer N if VPS IP or secrets changed)" "Y"; then
    SKIP_BUILD=true
    echo "  Will reuse existing Studio image."
  else
    echo "  Will rebuild Studio image."
  fi
fi

if ask_yes_no "Remove existing Studio container before starting? (recommended on rebuild)" "N"; then
  docker compose rm -sf studio >/dev/null 2>&1 || true
fi

# --- Build and start Studio --------------------------------------------------

echo
if [ "$SKIP_BUILD" = "true" ]; then
  echo "Starting Studio (skipping build)..."
  docker compose up -d --no-build studio
else
  echo "Building Studio image (this may take 5-8 minutes)..."
  docker compose build studio
  echo
  echo "Starting Studio..."
  docker compose up -d --no-build studio
fi

ok "Studio container started."

# --- Brand logo URL (for email branding) ------------------------------------

echo
echo "Email branding logo..."
if grep -q '^BRAND_LOGO=http' "$ENV_FILE" 2>/dev/null; then
  echo "  BRAND_LOGO already configured — skipping."
else
  printf "  Logo URL for emails (leave blank to skip): "
  read -r LOGO_URL
  if [ -n "$LOGO_URL" ]; then
    printf '\n# Email branding — set by init-credebl-studio.sh\nBRAND_LOGO=%s\n' "$LOGO_URL" >> "$ENV_FILE"
    docker restart credebl-issuance >/dev/null 2>&1 || true
    ok "BRAND_LOGO set — issuance restarted."
  else
    echo "  Skipped. Set BRAND_LOGO in credebl/.env manually if needed."
  fi
fi

# --- Final summary -----------------------------------------------------------

STUDIO_URL_EFFECTIVE="${STUDIO_URL:-http://${VPS_HOST:-localhost}:3000}"

echo
echo "============================================================"
echo " Studio deployed"
echo "============================================================"
printf " %-20s %s\n" "Studio URL:" "$STUDIO_URL_EFFECTIVE"
printf " %-20s %s\n" "Email:"      "${PLATFORM_ADMIN_EMAIL:-admin@cdpi-poc.local}"
printf " %-20s %s\n" "Password:"   "${PLATFORM_ADMIN_INITIAL_PASSWORD:-changeme}"
echo
echo "  Logs: docker compose -f credebl/studio/docker-compose.yml logs -f studio"
echo "  Stop: docker compose -f credebl/studio/docker-compose.yml down"
echo
