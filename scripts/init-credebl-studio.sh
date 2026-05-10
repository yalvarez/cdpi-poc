#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL Studio initializer
# -----------------------------------------------------------------------------
# Builds and starts the Studio frontend independently from the core stack.
# The core stack (init-credebl.sh) must already be running, and the standalone
# Keycloak stack (keycloak/) must be reachable.
#
# Usage:
#   bash scripts/init-credebl-studio.sh
#
# What it does:
#   1. Asks what URL Studio will be served on (default: STUDIO_URL from .env)
#   2. Verifies the core stack is running (api-gateway healthy)
#   3. Checks external Keycloak is reachable
#   4. Asks whether to rebuild the Studio image (forced if URL changed)
#   5. Builds the Studio Next.js image (~5-8 min on first run)
#   6. Starts Studio on port 3000
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDEBL_DIR="$REPO_DIR/credebl"
STUDIO_DIR="$CREDEBL_DIR/studio"
ENV_FILE="$CREDEBL_DIR/.env"

# --- Utility functions -------------------------------------------------------

ask() {
  local prompt="$1" default="${2:-}" secret="${3:-false}"
  local reply
  while true; do
    if [ "$secret" = "true" ]; then
      printf "  %s: " "$prompt" >&2
      read -rs reply; echo >&2
    else
      printf "  %s${default:+ [${default}]}: " "$prompt" >&2
      read -r reply
    fi
    reply="${reply:-$default}"
    [ -n "$reply" ] && break
    echo "  (required)" >&2
  done
  printf '%s' "$reply"
}

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

set_env_var() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

die() { echo "Error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }

# --- Check core .env exists --------------------------------------------------

[ -f "$ENV_FILE" ] || die "Core .env not found at $ENV_FILE — run init-credebl.sh first."

# Load .env so we have VPS_HOST, STUDIO_URL, KEYCLOAK_DOMAIN, etc. available
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

# --- Studio URL question ------------------------------------------------------
# STUDIO_URL is baked into the Next.js bundle at build time (NEXTAUTH_URL,
# NEXT_PUBLIC_ECOSYSTEM_FRONT_END_URL). If the URL changed from what was set
# during init-credebl.sh, the image must be rebuilt.

STUDIO_URL_CURRENT="${STUDIO_URL:-http://${VPS_HOST:-localhost}:3000}"

echo "Studio URL"
echo "  Current value from .env: $STUDIO_URL_CURRENT"
STUDIO_URL_NEW="$(ask "Studio URL (where Studio will be accessible — press Enter to keep current)" "$STUDIO_URL_CURRENT")"
STUDIO_URL_NEW="${STUDIO_URL_NEW%/}"

URL_CHANGED=false
if [ "$STUDIO_URL_NEW" != "$STUDIO_URL_CURRENT" ]; then
  URL_CHANGED=true
  set_env_var "$ENV_FILE" "STUDIO_URL"       "$STUDIO_URL_NEW"
  set_env_var "$ENV_FILE" "PLATFORM_WEB_URL" "$STUDIO_URL_NEW"
  set_env_var "$ENV_FILE" "FRONT_END_URL"    "$STUDIO_URL_NEW"
  ok "Studio URL updated in .env → $STUDIO_URL_NEW"
fi
STUDIO_URL="$STUDIO_URL_NEW"

# Re-source .env so updated STUDIO_URL is picked up by docker compose
set -a
# shellcheck disable=SC1090
source <(grep -E '^[A-Z_]+=' "$ENV_FILE")
set +a

# --- Verify core stack is running --------------------------------------------

echo
echo "Checking that the core stack is running..."

api_health="$(docker inspect credebl-api-gateway --format '{{.State.Health.Status}}' 2>/dev/null || true)"

if [ "$api_health" != "healthy" ]; then
  die "credebl-api-gateway is not healthy (status: ${api_health:-not found}). Run init-credebl.sh first."
fi
ok "Core API gateway is running."

# --- Check external Keycloak reachability ------------------------------------

# KEYCLOAK_DOMAIN in .env has a trailing slash; strip it for the health URL.
KC_BASE="${KEYCLOAK_DOMAIN%/}"
KC_BASE="${KC_BASE:-${KEYCLOAK_PUBLIC_URL:-}}"

if [ -n "$KC_BASE" ]; then
  echo "Checking Keycloak at ${KC_BASE} ..."
  # Use /realms/master (app port 8080) — Keycloak 24+ moves /health/ready to port 9000.
  KC_HEALTH_URL="${KC_BASE}/realms/master"
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$KC_HEALTH_URL" 2>/dev/null || true)"
  if [ "$HTTP_CODE" = "200" ]; then
    ok "Keycloak is reachable."
  else
    echo "  WARNING: Keycloak returned HTTP ${HTTP_CODE:-ERR} at ${KC_HEALTH_URL}."
    echo "  Studio will fail to authenticate until Keycloak is running."
    if ! ask_yes_no "  Continue anyway?" "N"; then
      exit 1
    fi
  fi
else
  echo "  KEYCLOAK_DOMAIN not set in .env — skipping Keycloak check."
fi

# --- Studio image check ------------------------------------------------------

cd "$STUDIO_DIR"

STUDIO_IMAGE="cdpi-credebl-studio-studio"
SKIP_BUILD=false

if docker image inspect "$STUDIO_IMAGE" >/dev/null 2>&1; then
  echo
  if [ "$URL_CHANGED" = "true" ]; then
    echo "  Studio URL changed — image must be rebuilt."
    SKIP_BUILD=false
  elif ask_yes_no "Studio image already exists. Skip rebuild? (answer N if VPS IP or secrets changed)" "Y"; then
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

# --- Final summary -----------------------------------------------------------

echo
echo "============================================================"
echo " Studio deployed"
echo "============================================================"
printf " %-20s %s\n" "Studio URL:" "$STUDIO_URL"
printf " %-20s %s\n" "Email:"      "${PLATFORM_ADMIN_EMAIL:-admin@cdpi-poc.local}"
printf " %-20s %s\n" "Password:"   "${PLATFORM_ADMIN_INITIAL_PASSWORD:-changeme}"
echo
echo "  Logs: docker compose -f credebl/studio/docker-compose.yml logs -f studio"
echo "  Stop: docker compose -f credebl/studio/docker-compose.yml down"
echo
