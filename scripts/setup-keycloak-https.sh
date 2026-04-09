#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Keycloak HTTPS Setup Script
# -----------------------------------------------------------------------------
# Installs Nginx + Certbot, provisions a Let's Encrypt certificate for a domain,
# configures reverse proxying to the local Keycloak container, and updates the
# CREDEBL .env public URL.
#
# Requirements:
#   - Ubuntu 22.04 / 24.04
#   - Domain already pointing to this VPS public IP
#   - Keycloak reachable locally on http://127.0.0.1:8080
#
# Usage:
#   chmod +x scripts/setup-keycloak-https.sh
#   sudo ./scripts/setup-keycloak-https.sh \
#     --domain auth.example.org \
#     --email admin@example.org
#
# Optional:
#   sudo ./scripts/setup-keycloak-https.sh \
#     --domain auth.example.org \
#     --email admin@example.org \
#     --keycloak-port 8080 \
#     --credebl-dir /opt/cdpi-poc/credebl
# =============================================================================

set -euo pipefail

DOMAIN=""
EMAIL=""
KEYCLOAK_PORT="8080"
CREDEBL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../credebl" && pwd)"
SKIP_CERTBOT=0

usage() {
  cat <<'EOF'
CDPI PoC — Keycloak HTTPS Setup

Required:
  --domain <fqdn>           Public domain for Keycloak (e.g. auth.example.org)
  --email <email>           Email used for Let's Encrypt renewal notices

Optional:
  --keycloak-port <port>    Local Keycloak port behind Nginx (default: 8080)
  --credebl-dir <path>      Path to the credebl folder (default: ../credebl)
  --skip-certbot            Only configure Nginx, skip certificate issuance
  -h, --help                Show this help

Example:
  sudo ./scripts/setup-keycloak-https.sh \
    --domain auth.example.org \
    --email ops@example.org
EOF
}

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"
        shift 2
        ;;
      --email)
        EMAIL="${2:-}"
        shift 2
        ;;
      --keycloak-port)
        KEYCLOAK_PORT="${2:-}"
        shift 2
        ;;
      --credebl-dir)
        CREDEBL_DIR="${2:-}"
        shift 2
        ;;
      --skip-certbot)
        SKIP_CERTBOT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$DOMAIN" ]] || die "Missing --domain"
  if [[ "$SKIP_CERTBOT" -eq 0 ]]; then
    [[ -n "$EMAIL" ]] || die "Missing --email"
  fi
}

check_dns() {
  local server_ip=""
  local resolved_ip=""

  server_ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  resolved_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}')

  if [[ -z "$resolved_ip" ]]; then
    if [[ "$SKIP_CERTBOT" -eq 1 ]]; then
      warn "Domain '$DOMAIN' does not resolve yet. Continuing because --skip-certbot was used."
      return
    fi
    die "Domain '$DOMAIN' does not resolve yet. Dependencies were installed, but DNS must point to this VPS before certificate issuance can succeed."
  fi

  log "Domain resolves to: $resolved_ip"
  if [[ -n "$server_ip" ]]; then
    log "Server public IP:    $server_ip"
    if [[ "$resolved_ip" != "$server_ip" ]]; then
      warn "DNS does not appear to point to this server yet. Certbot may fail until DNS propagates."
    fi
  fi
}

install_packages() {
  log "Installing Nginx, Certbot, and dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    nginx \
    certbot \
    python3-certbot-nginx \
    curl \
    ca-certificates \
    openssl \
    dnsutils \
    ufw

  require_command nginx
  require_command certbot

  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^nginx.service'; then
    systemctl daemon-reload || true
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx || systemctl start nginx || die "Unable to start nginx via systemctl."
  elif command -v service >/dev/null 2>&1; then
    service nginx restart || service nginx start || die "Unable to start nginx via service."
  else
    nginx || die "nginx is installed but could not be started automatically."
  fi
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Opening ports 80 and 443 in ufw (if enabled)..."
    ufw allow 80/tcp comment 'HTTP for ACME challenge' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'HTTPS reverse proxy for Keycloak' >/dev/null 2>&1 || true
  else
    warn "ufw not found; skipping firewall configuration."
  fi
}

write_nginx_config() {
  local site_name="keycloak-${DOMAIN//./-}"
  local conf_path="/etc/nginx/sites-available/${site_name}.conf"

  log "Writing Nginx site config: $conf_path"
  cat > "$conf_path" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:${KEYCLOAK_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_buffering off;
    }
}
EOF

  ln -sfn "$conf_path" "/etc/nginx/sites-enabled/${site_name}.conf"
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^nginx.service'; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx || systemctl restart nginx
  elif command -v service >/dev/null 2>&1; then
    service nginx reload || service nginx restart
  else
    nginx -s reload
  fi
}

issue_certificate() {
  if [[ "$SKIP_CERTBOT" -eq 1 ]]; then
    warn "Skipping Certbot by request. Site will remain HTTP-only until you issue a certificate."
    return
  fi

  log "Requesting Let's Encrypt certificate for $DOMAIN"
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m "$EMAIL" \
    -d "$DOMAIN"
}

update_credebl_env() {
  local env_file="$CREDEBL_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    warn "No .env file found at $env_file; skipping KEYCLOAK_PUBLIC_URL update."
    return
  fi

  log "Updating KEYCLOAK_PUBLIC_URL in $env_file"
  if grep -q '^KEYCLOAK_PUBLIC_URL=' "$env_file"; then
    sed -i "s|^KEYCLOAK_PUBLIC_URL=.*|KEYCLOAK_PUBLIC_URL=https://$DOMAIN|" "$env_file"
  else
    printf '\nKEYCLOAK_PUBLIC_URL=https://%s\n' "$DOMAIN" >> "$env_file"
  fi
}

restart_keycloak() {
  if [[ ! -f "$CREDEBL_DIR/docker-compose.yml" ]]; then
    warn "No docker-compose.yml found in $CREDEBL_DIR; skipping restart."
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed; skipping Keycloak restart."
    return
  fi

  log "Restarting Keycloak to pick up proxy-related settings..."
  (
    cd "$CREDEBL_DIR"
    docker compose up -d keycloak
    docker compose restart keycloak
  )
}

print_summary() {
  echo ""
  echo "============================================================"
  echo " Keycloak HTTPS setup complete"
  echo "============================================================"
  if [[ "$SKIP_CERTBOT" -eq 0 ]]; then
    echo " URL: https://$DOMAIN"
  else
    echo " URL: http://$DOMAIN"
  fi
  echo ""
  echo " Next steps:"
  echo "   1. Open https://$DOMAIN/admin/"
  echo "   2. Verify Keycloak login loads without the HTTPS-required error"
  echo "   3. If needed, restart the full CREDEBL stack:"
  echo "      cd $CREDEBL_DIR && docker compose up -d"
  echo ""
}

main() {
  require_root
  require_command curl
  require_command getent
  parse_args "$@"

  echo "============================================================"
  echo " CDPI PoC — Keycloak HTTPS Setup"
  echo " $(date)"
  echo "============================================================"

  install_packages
  configure_firewall
  check_dns
  write_nginx_config
  issue_certificate
  update_credebl_env
  restart_keycloak
  print_summary
}

main "$@"
