#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — Interactive CREDEBL initializer
# -----------------------------------------------------------------------------
# Prompts for the required deployment values, writes `credebl/.env`, updates the
# seed host values, and then runs the Docker deployment commands.
#
# Usage:
#   chmod +x scripts/init-credebl.sh
#   bash scripts/init-credebl.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDEBL_DIR="$REPO_DIR/credebl"
ENV_TEMPLATE="$CREDEBL_DIR/.env.example"
ENV_FILE="$CREDEBL_DIR/.env"
MASTER_TABLE="$CREDEBL_DIR/config/credebl-master-table.json"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' was not found." >&2
    exit 1
  fi
}

require_cmd docker
require_cmd python3
require_cmd openssl
require_cmd curl

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker is not running or this user cannot access it." >&2
  exit 1
fi

if [ ! -f "$ENV_TEMPLATE" ]; then
  echo "Error: template not found at $ENV_TEMPLATE" >&2
  exit 1
fi

if [ ! -f "$MASTER_TABLE" ]; then
  echo "Error: seed config not found at $MASTER_TABLE" >&2
  exit 1
fi

trim() {
  printf '%s' "$1" | sed 's/^ *//;s/ *$//'
}

sanitize_host() {
  local value
  value="$(trim "$1")"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s' "$value"
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local secret="${3:-false}"
  local value

  while true; do
    if [ "$secret" = "true" ]; then
      if [ -n "$default" ]; then
        printf "%s [press Enter to use current/default value]: " "$prompt" >&2
      else
        printf "%s: " "$prompt" >&2
      fi
      read -r -s value
      printf "\n" >&2
    else
      if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
      else
        printf "%s: " "$prompt" >&2
      fi
      read -r value
    fi

    if [ -z "$value" ]; then
      value="$default"
    fi

    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi

    echo "A value is required." >&2
  done
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply
  local suffix="[y/N]"

  if [ "$default" = "Y" ]; then
    suffix="[Y/n]"
  fi

  while true; do
    printf "%s %s: " "$prompt" "$suffix" >&2
    read -r reply
    reply="$(trim "$reply")"

    if [ -z "$reply" ]; then
      reply="$default"
    fi

    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac

    echo "Please answer yes or no." >&2
  done
}

ensure_alnum() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "Error: $name must use only letters and numbers for this PoC." >&2
    exit 1
  fi
}

DEFAULT_HOST="$(curl -4 -fsS ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
DEFAULT_HOST="$(sanitize_host "$DEFAULT_HOST")"
DEFAULT_PROTOCOL="http"
DEFAULT_POSTGRES_PASSWORD="$(openssl rand -hex 16)"
DEFAULT_KEYCLOAK_ADMIN_PASSWORD="$(openssl rand -hex 16)"
DEFAULT_PLATFORM_ADMIN_INITIAL_PASSWORD="changeme"
DEFAULT_MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
DEFAULT_AWS_ACCESS_KEY_ID="credebls3"
DEFAULT_AWS_SECRET_ACCESS_KEY="$(openssl rand -hex 16)"
DEFAULT_KEYCLOAK_CLIENT_SECRET="$(openssl rand -hex 32)"
DEFAULT_PLATFORM_SEED="$(openssl rand -hex 16)"
DEFAULT_PLATFORM_WALLET_NAME="platformadminwallet"
DEFAULT_PLATFORM_WALLET_PASSWORD="$(openssl rand -hex 16)"
DEFAULT_AGENT_API_KEY="$(openssl rand -hex 32)"
DEFAULT_JWT_SECRET="$(openssl rand -hex 32)"
DEFAULT_NEXTAUTH_SECRET="$(openssl rand -hex 32)"
DEFAULT_JWT_TOKEN_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
DEFAULT_PLATFORM_ADMIN_EMAIL="admin@cdpi-poc.local"
DEFAULT_SUPPORT_EMAIL="support@cdpi-poc.local"
DEFAULT_CRYPTO_PRIVATE_KEY="cdpi-poc-crypto-key-change-me"

cat <<'EOF'
============================================================
 CDPI PoC — CREDEBL interactive initializer
============================================================
This will:
  1. Prompt for the required deployment values
  2. Create/overwrite credebl/.env
  3. Update the seed host values for this VPS
  4. Pull/build/start the Docker stack
============================================================
EOF

echo
PUBLIC_HOST="$(ask 'Public host or DNS name (without http://)' "$DEFAULT_HOST")"
PUBLIC_HOST="$(sanitize_host "$PUBLIC_HOST")"
PROTOCOL="$(ask 'Protocol for public URLs (http or https)' "$DEFAULT_PROTOCOL")"
PROTOCOL="${PROTOCOL,,}"
if [ "$PROTOCOL" != "http" ] && [ "$PROTOCOL" != "https" ]; then
  echo "Error: protocol must be http or https." >&2
  exit 1
fi

POSTGRES_PASSWORD="$(ask 'Postgres password' "$DEFAULT_POSTGRES_PASSWORD" true)"
KEYCLOAK_ADMIN_PASSWORD="$(ask 'Keycloak admin password' "$DEFAULT_KEYCLOAK_ADMIN_PASSWORD" true)"
PLATFORM_ADMIN_INITIAL_PASSWORD="$(ask 'Initial Studio admin password' "$DEFAULT_PLATFORM_ADMIN_INITIAL_PASSWORD" true)"
MINIO_ROOT_PASSWORD="$(ask 'MinIO root password' "$DEFAULT_MINIO_ROOT_PASSWORD" true)"
AWS_ACCESS_KEY_ID="$(ask 'MinIO access key ID' "$DEFAULT_AWS_ACCESS_KEY_ID")"
AWS_SECRET_ACCESS_KEY="$(ask 'MinIO secret access key' "$DEFAULT_AWS_SECRET_ACCESS_KEY" true)"
KEYCLOAK_CLIENT_SECRET="$(ask 'Keycloak client secret' "$DEFAULT_KEYCLOAK_CLIENT_SECRET" true)"
PLATFORM_SEED="$(ask 'Platform seed' "$DEFAULT_PLATFORM_SEED" true)"
PLATFORM_WALLET_NAME="$(ask 'Platform shared-wallet name' "$DEFAULT_PLATFORM_WALLET_NAME")"
PLATFORM_WALLET_PASSWORD="$(ask 'Platform shared-wallet password' "$DEFAULT_PLATFORM_WALLET_PASSWORD" true)"
AGENT_API_KEY="$(ask 'Agent admin API key' "$DEFAULT_AGENT_API_KEY" true)"
JWT_SECRET="$(ask 'JWT secret' "$DEFAULT_JWT_SECRET" true)"
NEXTAUTH_SECRET="$(ask 'NextAuth secret' "$DEFAULT_NEXTAUTH_SECRET" true)"
JWT_TOKEN_SECRET="$(ask 'JWT_TOKEN_SECRET (base64)' "$DEFAULT_JWT_TOKEN_SECRET" true)"
PLATFORM_ADMIN_EMAIL="$(ask 'Platform admin email' "$DEFAULT_PLATFORM_ADMIN_EMAIL")"
PUBLIC_PLATFORM_SUPPORT_EMAIL="$(ask 'Support email shown in the UI' "$DEFAULT_SUPPORT_EMAIL")"
CRYPTO_PRIVATE_KEY="$(ask 'CRYPTO_PRIVATE_KEY' "$DEFAULT_CRYPTO_PRIVATE_KEY" true)"

ensure_alnum 'POSTGRES_PASSWORD' "$POSTGRES_PASSWORD"
ensure_alnum 'KEYCLOAK_ADMIN_PASSWORD' "$KEYCLOAK_ADMIN_PASSWORD"
ensure_alnum 'PLATFORM_ADMIN_INITIAL_PASSWORD' "$PLATFORM_ADMIN_INITIAL_PASSWORD"
ensure_alnum 'MINIO_ROOT_PASSWORD' "$MINIO_ROOT_PASSWORD"
ensure_alnum 'AWS_ACCESS_KEY_ID' "$AWS_ACCESS_KEY_ID"
ensure_alnum 'AWS_SECRET_ACCESS_KEY' "$AWS_SECRET_ACCESS_KEY"
ensure_alnum 'KEYCLOAK_CLIENT_SECRET' "$KEYCLOAK_CLIENT_SECRET"
ensure_alnum 'PLATFORM_SEED' "$PLATFORM_SEED"
ensure_alnum 'PLATFORM_WALLET_NAME' "$PLATFORM_WALLET_NAME"
ensure_alnum 'PLATFORM_WALLET_PASSWORD' "$PLATFORM_WALLET_PASSWORD"
ensure_alnum 'AGENT_API_KEY' "$AGENT_API_KEY"
ensure_alnum 'JWT_SECRET' "$JWT_SECRET"
ensure_alnum 'NEXTAUTH_SECRET' "$NEXTAUTH_SECRET"

KEYCLOAK_MANAGEMENT_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET"
PLATFORM_ADMIN_KEYCLOAK_SECRET="$KEYCLOAK_CLIENT_SECRET"
REDIS_PASSWORD=""
KEYCLOAK_PUBLIC_URL="${PROTOCOL}://${PUBLIC_HOST}:8080"
API_ENDPOINT="${PUBLIC_HOST}:5000"
VPS_IP="$PUBLIC_HOST"
PLATFORM_WEB_URL="${PROTOCOL}://${PUBLIC_HOST}:5000"
FRONT_END_URL="$PLATFORM_WEB_URL"
STUDIO_URL="${PROTOCOL}://${PUBLIC_HOST}:3000"
ENABLE_CORS_IP_LIST="${STUDIO_URL},http://localhost:3000,http://127.0.0.1:3000,https://localhost:3000,https://127.0.0.1:3000"
APP_PROTOCOL="$PROTOCOL"
AGENT_PROTOCOL="http"
WALLET_STORAGE_HOST="postgres"
WALLET_STORAGE_PORT="5432"
WALLET_STORAGE_USER="credebl"
WALLET_STORAGE_PASSWORD="$POSTGRES_PASSWORD"

if [ -f "$ENV_FILE" ]; then
  if ask_yes_no "Existing $ENV_FILE found. Overwrite it?" "N"; then
    :
  else
    echo "Aborted. Existing .env was left untouched."
    exit 0
  fi
fi

export ENV_TEMPLATE ENV_FILE MASTER_TABLE \
  POSTGRES_PASSWORD REDIS_PASSWORD KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_PUBLIC_URL \
  KEYCLOAK_CLIENT_SECRET KEYCLOAK_MANAGEMENT_CLIENT_SECRET PLATFORM_ADMIN_KEYCLOAK_SECRET \
  PLATFORM_ADMIN_INITIAL_PASSWORD PLATFORM_SEED PLATFORM_WALLET_NAME PLATFORM_WALLET_PASSWORD \
  AGENT_API_KEY JWT_SECRET NEXTAUTH_SECRET API_ENDPOINT VPS_IP \
  PLATFORM_WEB_URL FRONT_END_URL STUDIO_URL ENABLE_CORS_IP_LIST APP_PROTOCOL AGENT_PROTOCOL \
  MINIO_ROOT_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY JWT_TOKEN_SECRET \
  PLATFORM_ADMIN_EMAIL PUBLIC_PLATFORM_SUPPORT_EMAIL CRYPTO_PRIVATE_KEY PUBLIC_HOST PROTOCOL \
  WALLET_STORAGE_HOST WALLET_STORAGE_PORT WALLET_STORAGE_USER WALLET_STORAGE_PASSWORD

python3 <<'PY'
import json
import os
import re
from pathlib import Path

env_template = Path(os.environ['ENV_TEMPLATE'])
env_file = Path(os.environ['ENV_FILE'])
master_table = Path(os.environ['MASTER_TABLE'])

text = env_template.read_text(encoding='utf-8')
replacements = {
    'POSTGRES_PASSWORD': os.environ['POSTGRES_PASSWORD'],
    'DATABASE_URL': f"postgresql://credebl:{os.environ['POSTGRES_PASSWORD']}@postgres:5432/credebl",
    'POOL_DATABASE_URL': f"postgresql://credebl:{os.environ['POSTGRES_PASSWORD']}@postgres:5432/credebl",
    'REDIS_PASSWORD': os.environ['REDIS_PASSWORD'],
    'KEYCLOAK_ADMIN_PASSWORD': os.environ['KEYCLOAK_ADMIN_PASSWORD'],
    'KEYCLOAK_PUBLIC_URL': os.environ['KEYCLOAK_PUBLIC_URL'],
    'KEYCLOAK_CLIENT_SECRET': os.environ['KEYCLOAK_CLIENT_SECRET'],
    'KEYCLOAK_MANAGEMENT_CLIENT_SECRET': os.environ['KEYCLOAK_MANAGEMENT_CLIENT_SECRET'],
    'PLATFORM_ADMIN_KEYCLOAK_SECRET': os.environ['PLATFORM_ADMIN_KEYCLOAK_SECRET'],
    'PLATFORM_ADMIN_INITIAL_PASSWORD': os.environ['PLATFORM_ADMIN_INITIAL_PASSWORD'],
    'PLATFORM_SEED': os.environ['PLATFORM_SEED'],
    'PLATFORM_WALLET_NAME': os.environ['PLATFORM_WALLET_NAME'],
    'PLATFORM_WALLET_PASSWORD': os.environ['PLATFORM_WALLET_PASSWORD'],
    'AGENT_API_KEY': os.environ['AGENT_API_KEY'],
    'AGENT_PROTOCOL': os.environ['AGENT_PROTOCOL'],
    'WALLET_STORAGE_HOST': os.environ['WALLET_STORAGE_HOST'],
    'WALLET_STORAGE_PORT': os.environ['WALLET_STORAGE_PORT'],
    'WALLET_STORAGE_USER': os.environ['WALLET_STORAGE_USER'],
    'WALLET_STORAGE_PASSWORD': os.environ['WALLET_STORAGE_PASSWORD'],
    'JWT_SECRET': os.environ['JWT_SECRET'],
    'NEXTAUTH_SECRET': os.environ['NEXTAUTH_SECRET'],
    'API_ENDPOINT': os.environ['API_ENDPOINT'],
    'VPS_IP': os.environ['VPS_IP'],
    'PLATFORM_WEB_URL': os.environ['PLATFORM_WEB_URL'],
    'FRONT_END_URL': os.environ['FRONT_END_URL'],
    'STUDIO_URL': os.environ['STUDIO_URL'],
    'ENABLE_CORS_IP_LIST': os.environ['ENABLE_CORS_IP_LIST'],
    'APP_PROTOCOL': os.environ['APP_PROTOCOL'],
    'MINIO_ROOT_PASSWORD': os.environ['MINIO_ROOT_PASSWORD'],
    'AWS_ACCESS_KEY_ID': os.environ['AWS_ACCESS_KEY_ID'],
    'AWS_SECRET_ACCESS_KEY': os.environ['AWS_SECRET_ACCESS_KEY'],
    'JWT_TOKEN_SECRET': os.environ['JWT_TOKEN_SECRET'],
    'PLATFORM_ADMIN_EMAIL': os.environ['PLATFORM_ADMIN_EMAIL'],
    'PUBLIC_PLATFORM_SUPPORT_EMAIL': os.environ['PUBLIC_PLATFORM_SUPPORT_EMAIL'],
    'CRYPTO_PRIVATE_KEY': os.environ['CRYPTO_PRIVATE_KEY'],
}

for key, value in replacements.items():
    pattern = re.compile(rf'^{re.escape(key)}=.*$', re.MULTILINE)
    text = pattern.sub(lambda _m, k=key, v=value: f'{k}={v}', text)

env_file.write_text(text, encoding='utf-8')

config = json.loads(master_table.read_text(encoding='utf-8'))
platform_config = config.get('platformConfigData', {})
protocol = os.environ['PROTOCOL']
host = os.environ['PUBLIC_HOST']
platform_config['externalIp'] = f'{protocol}://{host}'
platform_config['inboundEndpoint'] = f'{protocol}://{host}'
platform_config['apiEndpoint'] = f'{protocol}://{host}:5000'
config['platformConfigData'] = platform_config
master_table.write_text(json.dumps(config, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
PY

echo
echo "Created $ENV_FILE and updated seed host values."
echo "  Studio URL:   $STUDIO_URL"
echo "  API URL:      $PLATFORM_WEB_URL"
echo "  Keycloak URL: $KEYCLOAK_PUBLIC_URL"
echo "  CORS origins: $ENABLE_CORS_IP_LIST"
echo

cd "$CREDEBL_DIR"

if ask_yes_no "Do a full clean reset first (down -v --remove-orphans)?" "Y"; then
  docker compose down -v --remove-orphans
fi

echo
echo "Pulling images..."
docker compose pull

echo
echo "Starting the stack..."
docker compose up -d --build

echo
echo "Running health check..."
bash ../scripts/health-check.sh

echo
echo "Deployment completed."
echo "Studio login:"
echo "  Email:    $PLATFORM_ADMIN_EMAIL"
echo "  Password: $PLATFORM_ADMIN_INITIAL_PASSWORD"
