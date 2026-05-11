#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — CREDEBL Studio initializer
# -----------------------------------------------------------------------------
# Builds and starts the Studio frontend independently from the core stack.
# The core stack (init-credebl.sh) must already be running, and the standalone
# Keycloak stack (keycloak/) must be reachable.
#
# Usage:
#   bash credebl/init-credebl-studio.sh
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

# --- SSL: system nginx + certbot for Studio domain ---------------------------
# Only runs when STUDIO_URL starts with https:// (user entered an https domain).

if [[ "$STUDIO_URL" == https://* ]]; then
  STUDIO_DOMAIN="${STUDIO_URL#https://}"
  STUDIO_DOMAIN="${STUDIO_DOMAIN%%/*}"    # strip any trailing path

  echo
  echo "HTTPS detected — configuring nginx + Let's Encrypt for Studio domain: ${STUDIO_DOMAIN}"

  STUDIO_SSL_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@cdpi-poc.local}"
  STUDIO_WEBROOT="/var/www/certbot"

  studio_ssl_tmp=$(mktemp /tmp/studio_ssl_XXXXXX.sh)
  chmod 700 "$studio_ssl_tmp"

  cat > "$studio_ssl_tmp" << 'SSLEOF'
#!/usr/bin/env bash
set -euo pipefail
studio_domain="$1"; email="$2"; webroot="$3"

log()  { echo "  [Studio SSL] $*"; }

reload_nginx() {
  nginx -t
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || nginx -s reload
}

cert_is_valid() {
  local cert="/etc/letsencrypt/live/${1}/fullchain.pem"
  [ -f "$cert" ] && openssl x509 -checkend 86400 -noout -in "$cert" 2>/dev/null
}

# Install packages if missing
if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
  log "Installing nginx + certbot..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nginx certbot python3-certbot-nginx curl openssl ufw
fi

systemctl enable nginx >/dev/null 2>&1 || true
systemctl start nginx 2>/dev/null || service nginx start 2>/dev/null || true
mkdir -p "$webroot"
rm -f /etc/nginx/sites-enabled/default

if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp  comment 'HTTP ACME'   >/dev/null 2>&1 || true
  ufw allow 443/tcp comment 'HTTPS nginx' >/dev/null 2>&1 || true
fi

studio_site="studio-${studio_domain//./-}"
studio_conf="/etc/nginx/sites-available/${studio_site}.conf"

# HTTP block for ACME challenge
cat > "$studio_conf" << 'NGINX'
server {
    listen 80; listen [::]:80;
    server_name __DOMAIN__;
    client_max_body_size 25m;
    location /.well-known/acme-challenge/ { root __WEBROOT__; default_type "text/plain"; }
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
NGINX
sed -i "s|__DOMAIN__|${studio_domain}|g; s|__WEBROOT__|${webroot}|g" "$studio_conf"
ln -sfn "$studio_conf" "/etc/nginx/sites-enabled/${studio_site}.conf"
reload_nginx

# Issue certificate
if cert_is_valid "$studio_domain"; then
  log "Certificate for ${studio_domain} is still valid — skipping."
else
  log "Requesting Let's Encrypt certificate for ${studio_domain}..."
  certbot certonly --webroot -w "$webroot" --non-interactive --agree-tos \
    --keep-until-expiring -m "$email" -d "$studio_domain"
fi

# Ensure certbot SSL support files
if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
  cat > /etc/letsencrypt/options-ssl-nginx.conf << 'SSLCONF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
SSLCONF
fi
if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
  log "Generating DH parameters (~5-15s)..."
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null
fi

# Upgrade to HTTPS
cat > "$studio_conf" << 'NGINX'
server {
    listen 80; listen [::]:80;
    server_name __DOMAIN__;
    location /.well-known/acme-challenge/ { root __WEBROOT__; default_type "text/plain"; }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl http2; listen [::]:443 ssl http2;
    server_name __DOMAIN__;
    ssl_certificate /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
NGINX
sed -i "s|__DOMAIN__|${studio_domain}|g; s|__WEBROOT__|${webroot}|g" "$studio_conf"
reload_nginx

# Auto-renewal cron
if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
  (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null") | crontab -
  log "Auto-renewal cron configured (daily 3 AM)."
fi

log "nginx + certbot setup complete for ${studio_domain}."
SSLEOF

  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "  SSL requires root — running nginx/certbot step with sudo..."
    sudo bash "$studio_ssl_tmp" "$STUDIO_DOMAIN" "$STUDIO_SSL_EMAIL" "$STUDIO_WEBROOT"
  else
    bash "$studio_ssl_tmp" "$STUDIO_DOMAIN" "$STUDIO_SSL_EMAIL" "$STUDIO_WEBROOT"
  fi
  rm -f "$studio_ssl_tmp"

  # Add HTTPS Studio origin to CREDEBL API gateway CORS list
  HTTPS_STUDIO_ORIGIN="https://${STUDIO_DOMAIN}"
  CURRENT_CORS=$(grep "^ENABLE_CORS_IP_LIST=" "$ENV_FILE" | cut -d= -f2-)
  if [ -n "$CURRENT_CORS" ] && ! echo "$CURRENT_CORS" | grep -qF "$HTTPS_STUDIO_ORIGIN"; then
    NEW_CORS="${CURRENT_CORS},${HTTPS_STUDIO_ORIGIN}"
    set_env_var "$ENV_FILE" "ENABLE_CORS_IP_LIST" "$NEW_CORS"
    ok "Added ${HTTPS_STUDIO_ORIGIN} to ENABLE_CORS_IP_LIST — restarting API gateway..."
    cd "$CREDEBL_DIR"
    docker compose restart api-gateway >/dev/null
    cd "$STUDIO_DIR"
  fi

  ok "Studio SSL configured: https://${STUDIO_DOMAIN}"
fi

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
