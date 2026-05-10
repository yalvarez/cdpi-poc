#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Full reset
# -----------------------------------------------------------------------------
# Wipes all stacks (CREDEBL core, Studio, Keycloak, INJI) back to a clean
# state. Removes: containers, volumes, .env files, runtime directories,
# generated keystores, and the built Studio image.
#
# Usage:
#   bash scripts/reset-poc.sh              # interactive — resets everything
#   bash scripts/reset-poc.sh --yes        # non-interactive, resets everything
#   bash scripts/reset-poc.sh --credebl    # only CREDEBL core + Studio
#   bash scripts/reset-poc.sh --inji       # only INJI
#   bash scripts/reset-poc.sh --keycloak   # only Keycloak standalone
#   bash scripts/reset-poc.sh --images     # also remove pulled Docker images
#
# Flags can be combined:
#   bash scripts/reset-poc.sh --credebl --inji --yes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[reset]${NC} $*"; }
ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*" >&2; }
step()  { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Parse flags ──────────────────────────────────────────────────────────────
RESET_CREDEBL=false
RESET_INJI=false
RESET_KEYCLOAK=false
REMOVE_IMAGES=false
AUTO_YES=false
SELECTIVE=false

for arg in "$@"; do
  case "$arg" in
    --credebl)  RESET_CREDEBL=true;  SELECTIVE=true ;;
    --inji)     RESET_INJI=true;     SELECTIVE=true ;;
    --keycloak) RESET_KEYCLOAK=true; SELECTIVE=true ;;
    --images)   REMOVE_IMAGES=true ;;
    --yes|-y)   AUTO_YES=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# If no stack specified, reset all
if ! $SELECTIVE; then
  RESET_CREDEBL=true
  RESET_INJI=true
  RESET_KEYCLOAK=true
fi

# ── Banner ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║   CDPI PoC — Full Reset                                       ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "  What will be destroyed:"
$RESET_CREDEBL  && echo "  • CREDEBL core (containers, volumes, .env, agent runtime)"
$RESET_CREDEBL  && echo "  • CREDEBL Studio (container, built image)"
$RESET_KEYCLOAK && echo "  • Keycloak standalone (container, volume, .env)"
$RESET_INJI     && echo "  • INJI (containers, volumes, .env, certs)"
$REMOVE_IMAGES  && echo "  • All pulled Docker images for these stacks"
echo

# ── Confirmation ─────────────────────────────────────────────────────────────
if ! $AUTO_YES; then
  printf "${BOLD}${RED}  This is irreversible. Continue? [y/N]: ${NC}"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

compose_down() {
  # Usage: compose_down <dir> [extra compose files...]
  local dir="$1"; shift
  local files="-f docker-compose.yml"
  for f in "$@"; do
    [ -f "$dir/$f" ] && files="$files -f $f"
  done
  (cd "$dir" && docker compose $files down --volumes --remove-orphans 2>/dev/null) || true
}

rm_volumes_matching() {
  local pattern="$1"
  local vols
  vols="$(docker volume ls -q 2>/dev/null | grep -E "$pattern" || true)"
  if [ -n "$vols" ]; then
    echo "$vols" | xargs docker volume rm 2>/dev/null || true
    ok "Volumes removed: $(echo "$vols" | tr '\n' ' ')"
  else
    echo "  No matching volumes found."
  fi
}

rm_images_matching() {
  local pattern="$1"
  local imgs
  imgs="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "$pattern" || true)"
  if [ -n "$imgs" ]; then
    echo "$imgs" | xargs docker rmi -f 2>/dev/null || true
    ok "Images removed: $(echo "$imgs" | tr '\n' ' ')"
  fi
}

# ── CREDEBL core ──────────────────────────────────────────────────────────────
if $RESET_CREDEBL; then
  step "CREDEBL core (cdpi-credebl)"

  info "Stopping containers..."
  compose_down "$REPO_DIR/credebl"
  ok "Containers stopped."

  info "Removing Credo controller containers (spawned outside compose)..."
  credo_containers="$(docker ps -a \
    --filter "ancestor=ghcr.io/credebl/credo-controller:latest" \
    --format '{{.ID}}' 2>/dev/null || true)"
  if [ -n "$credo_containers" ]; then
    echo "$credo_containers" | xargs docker rm -f 2>/dev/null || true
    ok "Credo containers removed."
  else
    echo "  No Credo containers found."
  fi

  info "Removing named volumes..."
  rm_volumes_matching '^cdpi-credebl_'

  info "Removing .env..."
  rm -f "$REPO_DIR/credebl/.env" && ok ".env removed." || true

  info "Removing agent runtime directory..."
  rm -rf "$REPO_DIR/credebl/.agent-runtime" && ok ".agent-runtime removed." || true

  if $REMOVE_IMAGES; then
    info "Removing CREDEBL pulled images..."
    rm_images_matching 'ghcr\.io/credebl/'
  fi

  step "CREDEBL Studio (cdpi-credebl-studio)"

  info "Stopping Studio container..."
  compose_down "$REPO_DIR/credebl/studio"
  ok "Studio container stopped."

  info "Removing built Studio image..."
  docker rmi -f cdpi-credebl-studio-studio 2>/dev/null \
    && ok "Studio image removed." \
    || echo "  Studio image not found — skipping."
fi

# ── Keycloak standalone ───────────────────────────────────────────────────────
if $RESET_KEYCLOAK; then
  step "Keycloak standalone (cdpi-keycloak)"

  info "Stopping containers (HTTP + SSL if active)..."
  compose_down "$REPO_DIR/keycloak" "docker-compose.ssl.yml"
  ok "Containers stopped."

  info "Removing named volumes..."
  rm_volumes_matching '^cdpi-keycloak_'

  info "Removing .env..."
  rm -f "$REPO_DIR/keycloak/.env" && ok ".env removed." || true

  if $REMOVE_IMAGES; then
    info "Removing Keycloak image..."
    docker rmi -f quay.io/keycloak/keycloak:25.0.6 2>/dev/null || true
  fi
fi

# ── INJI ─────────────────────────────────────────────────────────────────────
if $RESET_INJI; then
  step "INJI (cdpi-inji)"

  info "Stopping containers..."
  compose_down "$REPO_DIR/inji"
  ok "Containers stopped."

  info "Removing named volumes..."
  rm_volumes_matching '^cdpi-inji_'

  info "Removing .env..."
  rm -f "$REPO_DIR/inji/.env" && ok ".env removed." || true

  info "Removing generated keystores and certs..."
  rm -f "$REPO_DIR/inji/certs/"*.p12 \
        "$REPO_DIR/inji/certs/"*.key \
        "$REPO_DIR/inji/certs/"*.crt \
    && ok "inji/certs/ cleaned." || true

  if $REMOVE_IMAGES; then
    info "Removing INJI pulled images..."
    rm_images_matching 'mosipid/'
  fi
fi

# ── Global cleanup ────────────────────────────────────────────────────────────
step "Global cleanup"

info "Removing dangling volumes..."
docker volume prune -f >/dev/null 2>&1 && ok "Dangling volumes pruned." || true

info "Removing temp files..."
rm -f /tmp/credebl-* /tmp/inji-* 2>/dev/null || true
ok "Temp files cleaned."

if $REMOVE_IMAGES; then
  info "Removing dangling images..."
  docker image prune -f >/dev/null 2>&1 && ok "Dangling images pruned." || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   Reset complete — environment is clean                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "  Ready for a fresh deployment:"
$RESET_CREDEBL  && echo "    bash scripts/init-credebl.sh"
$RESET_CREDEBL  && echo "    bash scripts/init-credebl-studio.sh"
$RESET_KEYCLOAK && echo "    bash keycloak/init-keycloak.sh"
$RESET_INJI     && echo "    bash scripts/init-inji.sh"
echo
