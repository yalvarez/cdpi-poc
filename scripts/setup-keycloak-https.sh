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
VPS_DOMAIN=""
VPS_PORT="5000"
CREDEBL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../credebl" && pwd)"
SKIP_CERTBOT=0
CERTBOT_WEBROOT="/var/www/certbot"

usage() {
  cat <<'EOF'
CDPI PoC — Keycloak HTTPS Setup

Required:
  --domain <fqdn>           Public domain for Keycloak (e.g. auth.example.org)
  --email <email>           Email used for Let's Encrypt renewal notices

Optional:
  --vps-domain <fqdn>       General VPS domain for API/Studio (e.g. api.example.org)
  --vps-port <port>         Local backend port for the VPS domain (default: 5000)
  --keycloak-port <port>    Local Keycloak port behind Nginx (default: 8080)
  --credebl-dir <path>      Path to the credebl folder (default: ../credebl)
  --skip-certbot            Only configure Nginx, skip certificate issuance
  -h, --help                Show this help

Example:
  sudo ./scripts/setup-keycloak-https.sh \
    --domain auth.example.org \
    --vps-domain api.example.org \
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
      --vps-domain)
        VPS_DOMAIN="${2:-}"
        shift 2
        ;;
      --vps-port)
        VPS_PORT="${2:-}"
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

check_dns_for() {
  local domain="$1"
  local server_ip="${2:-}"
  local resolved_ip

  resolved_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')

  if [[ -z "$resolved_ip" ]]; then
    if [[ "$SKIP_CERTBOT" -eq 1 ]]; then
      warn "Domain '$domain' does not resolve yet. Continuing because --skip-certbot was used."
      return
    fi
    die "Domain '$domain' does not resolve yet. DNS must point to this VPS before certificate issuance can succeed."
  fi

  log "  $domain -> $resolved_ip"
  if [[ -n "$server_ip" && "$resolved_ip" != "$server_ip" ]]; then
    warn "DNS for '$domain' does not point to this server ($server_ip) yet. Certbot may fail until DNS propagates."
  fi
}

check_dns() {
  local server_ip
  server_ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -n "$server_ip" ]] && log "Server public IP: $server_ip"

  log "Checking DNS resolution..."
  check_dns_for "$DOMAIN" "$server_ip"
  [[ -n "$VPS_DOMAIN" && "$VPS_DOMAIN" != "$DOMAIN" ]] && check_dns_for "$VPS_DOMAIN" "$server_ip"
}

install_packages() {
  log "Installing Nginx, Certbot, and dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    nginx \
    certbot \
    python3 \
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

site_name() {
  echo "keycloak-${DOMAIN//./-}"
}

conf_path() {
  echo "/etc/nginx/sites-available/$(site_name).conf"
}

cert_paths_exist() {
  [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]
}

# Returns 0 if the domain already has a valid certificate with at least 24 h remaining.
cert_is_valid() {
  local domain="$1"
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key="/etc/letsencrypt/live/${domain}/privkey.pem"
  [[ -f "$cert" && -f "$key" ]] && \
    openssl x509 -checkend 86400 -noout -in "$cert" 2>/dev/null
}

vps_site_name() {
  echo "vps-${VPS_DOMAIN//./-}"
}

vps_conf_path() {
  echo "/etc/nginx/sites-available/$(vps_site_name).conf"
}

reload_nginx() {
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

disable_conflicting_sites() {
  local desired_kc_conf desired_vps_conf
  desired_kc_conf="$(conf_path)"
  desired_vps_conf="$(vps_conf_path)"

  log "Disabling default/conflicting Nginx sites..."
  rm -f /etc/nginx/sites-enabled/default

  while IFS= read -r enabled_site; do
    [[ -n "$enabled_site" ]] || continue
    [[ "$enabled_site" == "$desired_kc_conf" ]] && continue
    [[ -n "$VPS_DOMAIN" && "$enabled_site" == "$desired_vps_conf" ]] && continue

    local pattern="$DOMAIN"
    [[ -n "$VPS_DOMAIN" ]] && pattern="${DOMAIN}|${VPS_DOMAIN}"

    if grep -Eq "server_name[[:space:]].*($pattern)" "$enabled_site" 2>/dev/null; then
      warn "Disabling conflicting Nginx site: $enabled_site"
      rm -f "$enabled_site"
    fi
  done < <(find /etc/nginx/sites-enabled -maxdepth 1 \( -type l -o -type f \) 2>/dev/null)
}

write_nginx_http_config() {
  local conf_path_value
  conf_path_value="$(conf_path)"

  mkdir -p "$CERTBOT_WEBROOT"

  log "Writing HTTP Nginx site config: $conf_path_value"
  cat > "$conf_path_value" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 25m;

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        default_type "text/plain";
    }

    location / {
        proxy_pass http://127.0.0.1:${KEYCLOAK_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 80;
        proxy_buffering off;
    }
}
EOF

  ln -sfn "$conf_path_value" "/etc/nginx/sites-enabled/$(site_name).conf"
  reload_nginx
}

write_nginx_https_config() {
  local conf_path_value
  conf_path_value="$(conf_path)"

  if ! cert_paths_exist; then
    warn "TLS certificate files for ${DOMAIN} are not present yet; leaving the HTTP proxy config in place."
    return
  fi

  log "Writing HTTPS Nginx site config: $conf_path_value"
  cat > "$conf_path_value" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

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

  ln -sfn "$conf_path_value" "/etc/nginx/sites-enabled/$(site_name).conf"
  reload_nginx
}

write_nginx_vps_http_config() {
  [[ -z "$VPS_DOMAIN" ]] && return
  local vps_conf
  vps_conf="$(vps_conf_path)"
  mkdir -p "$CERTBOT_WEBROOT"
  log "Writing HTTP Nginx site config for VPS domain: $vps_conf"
  cat > "$vps_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${VPS_DOMAIN};

    client_max_body_size 25m;

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        default_type "text/plain";
    }

    # next-auth internal routes → Studio (port 3000)
    location ^~ /api/auth/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_buffering off;
    }

    # API gateway Swagger UI — exact match only (not /api/encrypt or other Studio routes)
    location ~ ^/(api|api-json)$ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto http;
        proxy_buffering off;
    }

    # API gateway — rutas con prefijo /v1/ (todas las llamadas del cliente Studio)
    location ~ ^/v1/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_buffering off;
    }

    # NextAuth llama /auth/signin server-side sin /v1/ — rewrite lo añade
    location ~ ^/auth/ {
        rewrite ^/(.*)\$ /v1/\$1 break;
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_buffering off;
    }

    # Socket.IO — WebSocket para eventos en tiempo real del API gateway
    location /socket.io/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_read_timeout 86400;
        proxy_buffering off;
    }

    # Studio — catch-all (Next.js pages: /credentials, /connections, /schemas, etc.)
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF
  ln -sfn "$vps_conf" "/etc/nginx/sites-enabled/$(vps_site_name).conf"
  reload_nginx
}

write_nginx_vps_https_config() {
  [[ -z "$VPS_DOMAIN" ]] && return
  local vps_conf
  vps_conf="$(vps_conf_path)"
  if [[ ! -f "/etc/letsencrypt/live/${VPS_DOMAIN}/fullchain.pem" ]]; then
    warn "TLS certificate for ${VPS_DOMAIN} not present; leaving HTTP proxy config in place."
    return
  fi
  log "Writing HTTPS Nginx site config for VPS domain: $vps_conf"
  cat > "$vps_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${VPS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        default_type "text/plain";
    }

    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${VPS_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${VPS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${VPS_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    client_max_body_size 25m;

    # next-auth internal routes → Studio (port 3000)
    # Must be ^~ so it wins over the /api regex below
    location ^~ /api/auth/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    # API gateway Swagger UI — exact match only (/api/encrypt and other
    # Studio-internal /api/* routes must fall through to the catch-all below)
    location ~ ^/(api|api-json)\$ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    # API gateway — rutas con prefijo /v1/ (Studio siempre incluye /v1/ en sus llamadas)
    location ~ ^/v1/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    # API gateway — NextAuth llama GET /auth/sessionDetails SIN prefijo /v1/
    # El rewrite agrega /v1/ antes de pasar al API gateway (puerto 5000)
    # NOTA: /api/auth/* ya está capturado por el bloque ^~ de arriba; este bloque
    # solo aplica a /auth/... (sin /api/ adelante)
    location ~ ^/auth/ {
        rewrite ^/(.*)\$ /v1/\$1 break;
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    # Socket.IO — WebSocket para eventos en tiempo real del API gateway
    location /socket.io/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400;
        proxy_buffering off;
    }

    # Studio catch-all (Next.js — maneja /credentials, /connections, /orgs y todas las rutas UI)
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF
  ln -sfn "$vps_conf" "/etc/nginx/sites-enabled/$(vps_site_name).conf"
  reload_nginx
}

issue_certificate() {
  if [[ "$SKIP_CERTBOT" -eq 1 ]]; then
    warn "Skipping Certbot by request. Sites will remain HTTP-only until you issue a certificate."
    return
  fi

  mkdir -p "$CERTBOT_WEBROOT"

  # Build the list of domains that need a certificate
  local all_domains=("$DOMAIN")
  [[ -n "$VPS_DOMAIN" && "$VPS_DOMAIN" != "$DOMAIN" ]] && all_domains+=("$VPS_DOMAIN")

  for domain in "${all_domains[@]}"; do
    if cert_is_valid "$domain"; then
      log "Certificate for $domain is already valid (>24 h remaining) — skipping issuance."
      continue
    fi
    log "Requesting Let's Encrypt certificate for $domain using the webroot method"
    certbot certonly \
      --webroot \
      -w "$CERTBOT_WEBROOT" \
      --non-interactive \
      --agree-tos \
      --keep-until-expiring \
      -m "$EMAIL" \
      -d "$domain"
  done
}

verify_proxy_setup() {
  local local_status=""
  local public_url=""
  local public_headers=""
  local public_status=""
  local redirect_location=""

  local_status=$(curl -k -o /dev/null -s -w '%{http_code}' "http://127.0.0.1:${KEYCLOAK_PORT}/admin/" || true)

  if cert_paths_exist && [[ "$SKIP_CERTBOT" -eq 0 ]]; then
    public_url="https://${DOMAIN}/admin/"
  else
    public_url="http://${DOMAIN}/admin/"
  fi

  public_headers=$(curl -k -I -s "$public_url" || true)
  public_status=$(printf '%s\n' "$public_headers" | awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code}')
  redirect_location=$(printf '%s\n' "$public_headers" | awk 'BEGIN{IGNORECASE=1} /^Location:/ {print $2}' | tr -d '\r')

  log "Verification: local Keycloak /admin -> HTTP ${local_status}; public ${public_url} -> HTTP ${public_status}"

  if [[ -n "$redirect_location" ]]; then
    log "Public redirect location: ${redirect_location}"
    if [[ "$redirect_location" == http://* ]]; then
      warn "Keycloak is still advertising an HTTP redirect. Recreate the container so the updated KC_HOSTNAME/KEYCLOAK_PUBLIC_URL values take effect."
    fi
  fi

  case "$public_status" in
    200|301|302|303)
      ;;
    *)
      warn "Unexpected public response status ${public_status}. Check 'nginx -T' and 'docker compose logs keycloak' if the admin console still does not load."
      ;;
  esac
}

set_env_var() {
  # set_env_var <file> <KEY> <value>
  # Replaces KEY=... in file, or appends if missing.
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

update_credebl_env() {
  local env_file="$CREDEBL_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    warn "No .env file found at $env_file; skipping env update."
    return
  fi

  # KEYCLOAK_PUBLIC_URL — public URL Keycloak uses in issuer claims (HTTPS)
  log "Updating KEYCLOAK_PUBLIC_URL in $env_file"
  set_env_var "$env_file" "KEYCLOAK_PUBLIC_URL" "https://$DOMAIN"

  # KEYCLOAK_DOMAIN — must match the iss claim in Keycloak JWTs so CREDEBL
  # services pass JWT validation. After SSL, Keycloak emits
  # iss: https://<domain>/realms/... — this value must end with a trailing slash.
  log "Updating KEYCLOAK_DOMAIN to match the HTTPS issuer in $env_file"
  set_env_var "$env_file" "KEYCLOAK_DOMAIN" "https://$DOMAIN/"

  # When a VPS_DOMAIN is given the Studio and API gateway are both served from
  # that domain via Nginx path routing. Update all public-facing URLs so Studio
  # build args and email links are correct.
  if [[ -n "$VPS_DOMAIN" ]]; then
    log "Updating Studio / API gateway public URLs for HTTPS VPS domain in $env_file"

    # API_GATEWAY_PROTOCOL=https makes Studio bake NEXT_PUBLIC_BASE_URL as
    # https://... at build time. Without this, Node.js fetch follows the 301
    # redirect from Nginx and converts POST → GET, breaking login.
    set_env_var "$env_file" "API_GATEWAY_PROTOCOL" "https"
    set_env_var "$env_file" "APP_PROTOCOL"         "https"

    # API_ENDPOINT is host only (no protocol, no port) — Studio prepends the
    # protocol from API_GATEWAY_PROTOCOL to form NEXT_PUBLIC_BASE_URL.
    # With Nginx on 443 there is no port in the URL.
    set_env_var "$env_file" "API_ENDPOINT"  "$VPS_DOMAIN"

    # Studio is now on the same domain as the API (no separate port)
    set_env_var "$env_file" "STUDIO_URL"        "https://$VPS_DOMAIN"
    set_env_var "$env_file" "PLATFORM_WEB_URL"  "https://$VPS_DOMAIN"
    set_env_var "$env_file" "FRONT_END_URL"     "https://$VPS_DOMAIN"
    set_env_var "$env_file" "SOCKET_HOST"       "https://$VPS_DOMAIN"

    # Allow the browser to call the API from the Studio origin
    set_env_var "$env_file" "ENABLE_CORS_IP_LIST" "https://$VPS_DOMAIN,http://localhost:3000,http://127.0.0.1:3000"
  fi
}

rebuild_studio() {
  # Studio bakes NEXT_PUBLIC_BASE_URL (and other NEXT_PUBLIC_* vars) at build time.
  # After changing API_GATEWAY_PROTOCOL or API_ENDPOINT, the image must be rebuilt
  # or the Studio will still call the old HTTP URL and login will break.
  [[ -z "$VPS_DOMAIN" ]] && return
  if [[ ! -f "$CREDEBL_DIR/docker-compose.yml" ]]; then
    warn "No docker-compose.yml found; skipping Studio rebuild."
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker not available; skipping Studio rebuild. Run 'docker compose build studio && docker compose up -d studio' manually."
    return
  fi
  log "Rebuilding Studio with updated HTTPS env vars (this takes 5-8 minutes)..."
  (
    cd "$CREDEBL_DIR"
    docker compose build studio
    docker compose up -d studio
  )
  log "Studio rebuilt and restarted."
}

restart_credebl_services() {
  if [[ ! -f "$CREDEBL_DIR/docker-compose.yml" ]]; then
    warn "No docker-compose.yml found; skipping CREDEBL service restart."
    return
  fi
  log "Restarting CREDEBL microservices so updated KEYCLOAK_DOMAIN takes effect..."
  (
    cd "$CREDEBL_DIR"
    docker compose restart api-gateway user organization issuance verification ledger connection cloud-wallet
  )
}

normalize_utf8_file() {
  local target_file="$1"

  if [[ ! -f "$target_file" ]]; then
    return
  fi

  require_command python3

  python3 - "$target_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
last_error = None
for encoding in ("utf-8", "cp1252", "latin-1"):
    try:
        text = data.decode(encoding)
        path.write_text(text, encoding="utf-8", newline="")
        print(f"[INFO] Normalized {path} using {encoding} -> utf-8")
        break
    except UnicodeDecodeError as exc:
        last_error = exc
else:
    raise SystemExit(f"[ERROR] Could not normalize {path} to UTF-8: {last_error}")
PY
}

validate_compose_file() {
  local compose_file="$CREDEBL_DIR/docker-compose.yml"

  if [[ ! -f "$compose_file" ]]; then
    return
  fi

  normalize_utf8_file "$compose_file"

  if command -v docker >/dev/null 2>&1; then
    (
      cd "$CREDEBL_DIR"
      docker compose config >/dev/null
    ) || die "docker compose could not parse $compose_file even after UTF-8 normalization."
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

  log "Recreating Keycloak so the updated hostname/proxy settings take effect..."
  (
    cd "$CREDEBL_DIR"
    docker compose up -d --force-recreate keycloak
  )
}

wait_for_keycloak() {
  local attempt

  log "Waiting for Keycloak to become reachable on http://127.0.0.1:${KEYCLOAK_PORT} ..."
  for attempt in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${KEYCLOAK_PORT}/health/ready" >/dev/null 2>&1 || \
       curl -fsS "http://127.0.0.1:${KEYCLOAK_PORT}" >/dev/null 2>&1; then
      log "Keycloak is responding locally."
      return
    fi
    sleep 2
  done

  warn "Keycloak did not report ready within the expected time window; continuing with verification anyway."
}

print_summary() {
  local kc_url vps_url
  if cert_paths_exist && [[ "$SKIP_CERTBOT" -eq 0 ]]; then
    kc_url="https://$DOMAIN"
  else
    kc_url="http://$DOMAIN"
  fi

  echo ""
  echo "============================================================"
  echo " HTTPS setup complete"
  echo "============================================================"
  echo " Keycloak:    $kc_url"
  if [[ -n "$VPS_DOMAIN" ]]; then
    if cert_is_valid "$VPS_DOMAIN" || [[ -f "/etc/letsencrypt/live/${VPS_DOMAIN}/fullchain.pem" ]]; then
      vps_url="https://$VPS_DOMAIN"
    else
      vps_url="http://$VPS_DOMAIN (no certificate yet)"
    fi
    echo " Studio:      $vps_url"
    echo " API gateway: $vps_url/v1/"
    echo " API Swagger: $vps_url/api"
  fi
  echo ""
  echo " Next steps:"
  echo "   1. Open $kc_url/admin/ — verify Keycloak loads without HTTPS-required error"
  if [[ -n "$VPS_DOMAIN" ]]; then
    echo "   2. Open $vps_url — log in to Studio"
    echo "   3. If login fails, ensure Studio was rebuilt (check 'docker compose ps studio')"
  fi
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
  disable_conflicting_sites
  write_nginx_http_config
  write_nginx_vps_http_config
  issue_certificate
  write_nginx_https_config
  write_nginx_vps_https_config
  update_credebl_env
  validate_compose_file
  restart_keycloak
  wait_for_keycloak
  verify_proxy_setup
  restart_credebl_services
  rebuild_studio
  print_summary
}

main "$@"
