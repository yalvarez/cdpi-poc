#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Keycloak Standalone init
# -----------------------------------------------------------------------------
# Despliega Keycloak como servicio OIDC independiente.
# Flujo interactivo:
#   1. ¿Tienes un dominio?
#      └─ Sí → ¿Quieres SSL con Let's Encrypt? → certbot + nginx
#      └─ No  → HTTP puro con IP del servidor
#   2. Genera .env con credenciales aleatorias
#   3. Levanta postgres + keycloak (+ nginx si SSL)
#   4. Espera que Keycloak esté listo
#   5. Imprime credenciales de acceso
#
# Uso:
#   cd keycloak/
#   bash init-keycloak.sh
#
# Para crear el realm CREDEBL después:
#   bash setup-credebl-realm.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
NGINX_CONF="config/nginx.conf"
NGINX_TEMPLATE="config/nginx.conf"   # se sobreescribe in-place con sed

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[keycloak]${NC} $*"; }
ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()   { echo -e "${RED}  ✗ ERROR:${NC} $*" >&2; exit 1; }
ask()   { local var="$1" prompt="$2" def="${3:-}"; local val
          printf "  %s" "$prompt"
          [ -n "$def" ] && printf " [%s]" "$def"
          printf ": "
          read -r val; echo
          val="${val:-$def}"
          printf -v "$var" '%s' "$val"; }
ask_yn(){ local var="$1" prompt="$2" def="${3:-n}"; local val
          printf "  %s [s/n, default %s]: " "$prompt" "$def"
          read -r val; echo
          val="${val:-$def}"
          [[ "$val" =~ ^[sSyY] ]] && printf -v "$var" 'true' || printf -v "$var" 'false'; }

gen_secret() { openssl rand -hex 20 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 40; }

# ── Verificar herramientas ───────────────────────────────────────────────────
for cmd in docker curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Falta '$cmd'. Instálalo y vuelve a intentar."
done
docker compose version >/dev/null 2>&1 || die "Se requiere 'docker compose' v2 (plugin, no docker-compose)."

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   CDPI PoC — Keycloak Standalone                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Si ya existe .env, preguntar si se reutiliza ─────────────────────────────
RECONFIGURE=false
if [ -f "$ENV_FILE" ]; then
  echo -e "  Se encontró un ${BOLD}.env${NC} existente."
  ask_yn RECONFIGURE "¿Reconfigurar desde cero?" "n"
  if ! $RECONFIGURE; then
    info "Usando .env existente — solo se levantarán los servicios."
    set -a; source <(grep -E '^[A-Z_]+=' "$ENV_FILE"); set +a
    USE_SSL="${USE_SSL:-false}"
    jump_to_startup=true
  fi
fi
jump_to_startup="${jump_to_startup:-false}"

# ── Bloque de configuración interactiva ──────────────────────────────────────
if ! $jump_to_startup; then

  echo -e "  Responde las siguientes preguntas para configurar Keycloak."
  echo ""

  # ── Pregunta 1: ¿dominio? ──────────────────────────────────────────────────
  ask_yn HAS_DOMAIN "¿Tienes un dominio apuntando a este servidor?" "n"

  DOMAIN=""
  USE_SSL=false

  if $HAS_DOMAIN; then
    ask DOMAIN "  Dominio (ej: keycloak.mi-pais.gov)" ""
    [ -z "$DOMAIN" ] && die "El dominio no puede estar vacío."
    DOMAIN="${DOMAIN,,}"   # lowercase

    # ── Pregunta 2: ¿SSL con Let's Encrypt? ────────────────────────────────
    echo ""
    echo -e "  Let's Encrypt requiere:"
    echo -e "    - Puerto ${BOLD}80${NC} accesible desde internet (para el challenge ACME)"
    echo -e "    - El dominio ${BOLD}${DOMAIN}${NC} apuntando a este servidor"
    echo ""
    ask_yn USE_SSL "¿Generar certificado SSL gratuito con Let's Encrypt?" "s"
  fi

  # ── Pregunta 3: puerto Keycloak (solo HTTP mode) ───────────────────────────
  KC_PORT_DEFAULT=8080
  if ! $USE_SSL; then
    ask KC_PORT "Puerto HTTP de Keycloak" "$KC_PORT_DEFAULT"
    KC_PORT="${KC_PORT:-$KC_PORT_DEFAULT}"
  else
    KC_PORT=8080    # interno, nginx expone 443
  fi

  # ── Generar credenciales ────────────────────────────────────────────────────
  echo ""
  info "Generando credenciales..."

  KC_ADMIN_PASS="$(gen_secret)"
  KC_CLIENT_SECRET="$(gen_secret)"
  PG_PASS="$(gen_secret)"

  # URL pública
  if $USE_SSL; then
    KC_PUBLIC_URL="https://${DOMAIN}"
  elif $HAS_DOMAIN; then
    KC_PUBLIC_URL="http://${DOMAIN}:${KC_PORT}"
  else
    # Detectar IP pública del servidor
    SERVER_IP="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    KC_PUBLIC_URL="http://${SERVER_IP}:${KC_PORT}"
    echo ""
    warn "Sin dominio — usando IP detectada: ${SERVER_IP}"
    warn "Si la IP no es correcta, edita KC_PUBLIC_URL en .env y reinicia."
  fi

  # ── Escribir .env ──────────────────────────────────────────────────────────
  cat > "$ENV_FILE" <<EOF
# Generado por init-keycloak.sh — $(date -u +"%Y-%m-%d %H:%M UTC")

DOMAIN=${DOMAIN:-}
USE_SSL=${USE_SSL}
KC_PUBLIC_URL=${KC_PUBLIC_URL}

KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASS}
KEYCLOAK_CLIENT_SECRET=${KC_CLIENT_SECRET}

POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=${PG_PASS}

KEYCLOAK_PORT=${KC_PORT}
POSTGRES_PORT=5434
EOF
  ok ".env generado."

  # ── SSL: nginx del sistema + certbot --webroot ────────────────────────────
  if $USE_SSL; then
    echo ""
    info "Configurando nginx + Let's Encrypt para ${DOMAIN}..."
    [ "${EUID:-$(id -u)}" -ne 0 ] && die "SSL requiere permisos de root. Corre: sudo bash init-keycloak.sh"

    webroot="/var/www/certbot"

    # Instalar nginx + certbot si es necesario
    if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
      info "Instalando nginx y certbot..."
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx certbot python3-certbot-nginx curl openssl ufw
      elif command -v yum >/dev/null 2>&1; then
        yum install -y -q nginx certbot python3-certbot-nginx
      else
        die "No se pudo instalar nginx/certbot automáticamente. Instálalos y vuelve a intentar."
      fi
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx 2>/dev/null || service nginx start 2>/dev/null || true
    mkdir -p "$webroot"
    rm -f /etc/nginx/sites-enabled/default

    # Abrir firewall si está activo
    if command -v ufw >/dev/null 2>&1; then
      ufw allow 80/tcp  comment 'HTTP ACME'   >/dev/null 2>&1 || true
      ufw allow 443/tcp comment 'HTTPS nginx' >/dev/null 2>&1 || true
    fi

    kc_site="keycloak-${DOMAIN//./-}"
    kc_conf="/etc/nginx/sites-available/${kc_site}.conf"

    # Bloque HTTP temporal para el challenge ACME
    cat > "$kc_conf" << NGINX
server {
    listen 80; listen [::]:80;
    server_name ${DOMAIN};
    client_max_body_size 25m;
    location /.well-known/acme-challenge/ { root ${webroot}; default_type "text/plain"; }
    location / {
        proxy_pass http://127.0.0.1:${KC_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_buffering off;
    }
}
NGINX
    ln -sfn "$kc_conf" "/etc/nginx/sites-enabled/${kc_site}.conf"
    nginx -t && (systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true)

    # Solicitar certificado con método webroot (nginx ya está corriendo)
    info "Solicitando certificado para ${DOMAIN}..."
    certbot certonly --webroot -w "$webroot" --non-interactive --agree-tos \
      --register-unsafely-without-email --keep-until-expiring -d "$DOMAIN" \
      || die "certbot falló. Verifica que ${DOMAIN} apunte a este servidor y el puerto 80 esté accesible."
    ok "Certificado obtenido: /etc/letsencrypt/live/${DOMAIN}/"

    # Archivos de soporte SSL (los crea certbot --nginx; con --webroot los creamos manualmente)
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
      info "Generando parámetros DH (tarda ~5–15s)..."
      openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null
    fi

    # Actualizar bloque nginx a HTTPS completo
    cat > "$kc_conf" << NGINX
server {
    listen 80; listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root ${webroot}; default_type "text/plain"; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2; listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:${KC_PORT};
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
NGINX
    nginx -t && (systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true)
    ok "nginx configurado para ${DOMAIN}."

    # Renovación automática via cron (si no existe ya)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
      (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null") | crontab -
      ok "Cron de renovación automática configurado (3:00 AM diario)."
    fi
  fi

fi  # fin bloque configuración

# ── Cargar .env ────────────────────────────────────────────────────────────────
set -a
source <(grep -E '^[A-Z_]+=' "$ENV_FILE")
set +a

USE_SSL="${USE_SSL:-false}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8080}"
KC_PUBLIC_URL="${KC_PUBLIC_URL:-http://localhost:${KEYCLOAK_PORT}}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?ERROR: KEYCLOAK_ADMIN_PASSWORD no definido en .env}"
DOMAIN="${DOMAIN:-}"

# ── Levantar servicios ─────────────────────────────────────────────────────────
echo ""
info "Iniciando servicios..."

if [[ "$USE_SSL" == "true" ]]; then
  COMPOSE_FILES="-f docker-compose.yml -f docker-compose.ssl.yml"
else
  COMPOSE_FILES="-f docker-compose.yml"
fi

# shellcheck disable=SC2086
docker compose $COMPOSE_FILES pull --quiet 2>/dev/null || true
# shellcheck disable=SC2086
docker compose $COMPOSE_FILES up -d
ok "Servicios iniciados."

# ── Esperar Keycloak ───────────────────────────────────────────────────────────
echo ""
info "Esperando que Keycloak esté listo (puede tomar hasta 3 min)..."
# Puerto 9000 (management) no publicado externamente para evitar conflicto con MinIO.
# Usamos el estado de health de Docker (el healthcheck interno verifica el puerto 8080).

MAX_RETRIES=36   # 36 × 5s = 3 min máximo
RETRY_DELAY=5
attempt=0

while [ $attempt -lt $MAX_RETRIES ]; do
  attempt=$((attempt + 1))
  # shellcheck disable=SC2086
  kc_health=$(docker compose $COMPOSE_FILES ps --format '{{.Health}}' keycloak 2>/dev/null || true)
  if [ "$kc_health" = "healthy" ]; then
    ok "Keycloak listo (${attempt}×${RETRY_DELAY}s)."
    break
  fi
  if [ $attempt -eq $MAX_RETRIES ]; then
    echo ""
    warn "Keycloak no respondió después de $((MAX_RETRIES * RETRY_DELAY))s."
    echo -e "  Revisa los logs: ${BOLD}docker compose $COMPOSE_FILES logs -f keycloak${NC}"
    echo ""
    break
  fi
  printf "    intentando... (%d/%d)\r" "$attempt" "$MAX_RETRIES"
  sleep $RETRY_DELAY
done

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Keycloak listo                                              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$USE_SSL" == "true" ]]; then
  echo -e "  ${BOLD}Modo:${NC}         HTTPS (nginx + Let's Encrypt)"
  echo -e "  ${BOLD}URL pública:${NC}  https://${DOMAIN}"
else
  echo -e "  ${BOLD}Modo:${NC}         HTTP (sin SSL)"
  echo -e "  ${BOLD}URL pública:${NC}  ${KC_PUBLIC_URL}"
fi

echo ""
echo -e "  ${BOLD}Consola admin:${NC}"
echo -e "    ${KC_PUBLIC_URL}/admin"
echo -e "    Usuario:  ${KEYCLOAK_ADMIN}"
echo -e "    Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo -e "  ${BOLD}Próximo paso — crear realm CREDEBL:${NC}"
echo -e "    bash setup-credebl-realm.sh"
echo ""
echo -e "  ${BOLD}Logs:${NC}  docker compose ${COMPOSE_FILES} logs -f keycloak"
echo -e "  ${BOLD}Parar:${NC} docker compose ${COMPOSE_FILES} down"
echo ""
