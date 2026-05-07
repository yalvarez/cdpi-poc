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

  # ── SSL: certbot ───────────────────────────────────────────────────────────
  if $USE_SSL; then
    echo ""
    info "Configurando certificado SSL con Let's Encrypt..."

    # Verificar / instalar certbot
    if ! command -v certbot >/dev/null 2>&1; then
      info "certbot no encontrado — instalando..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq certbot
      elif command -v yum >/dev/null 2>&1; then
        yum install -y -q certbot
      else
        die "No se pudo instalar certbot automáticamente. Instálalo manualmente y vuelve a correr este script."
      fi
    fi

    # Verificar que el puerto 80 esté libre antes del challenge
    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
      warn "El puerto 80 está ocupado. Detén el servicio que lo usa antes de continuar."
      warn "Ej: systemctl stop apache2  o  systemctl stop nginx"
      ask_yn CONTINUE_ANYWAY "¿Continuar de todas formas (certbot puede fallar)?" "n"
      $CONTINUE_ANYWAY || die "Abortar. Libera el puerto 80 y vuelve a intentar."
    fi

    info "Solicitando certificado para ${DOMAIN}..."
    certbot certonly \
      --standalone \
      --non-interactive \
      --agree-tos \
      --register-unsafely-without-email \
      --domain "$DOMAIN" \
      --http-01-port 80 \
      || die "certbot falló. Verifica que ${DOMAIN} apunte a este servidor y el puerto 80 esté accesible."

    ok "Certificado obtenido: /etc/letsencrypt/live/${DOMAIN}/"

    # Generar nginx.conf con el dominio real
    sed "s/KEYCLOAK_DOMAIN/${DOMAIN}/g" config/nginx.conf > /tmp/kc_nginx.conf
    cp /tmp/kc_nginx.conf config/nginx.conf
    ok "nginx.conf configurado para ${DOMAIN}."

    # Renovación automática via cron (si no existe ya)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
      (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && docker exec keycloak-nginx nginx -s reload") | crontab -
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
info "Esperando que Keycloak esté listo (puede tomar hasta 90s)..."

MAX_RETRIES=36   # 36 × 5s = 3 min máximo
RETRY_DELAY=5
attempt=0

while [ $attempt -lt $MAX_RETRIES ]; do
  attempt=$((attempt + 1))
  if curl -sf "http://localhost:${KEYCLOAK_PORT}/health/ready" >/dev/null 2>&1; then
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
