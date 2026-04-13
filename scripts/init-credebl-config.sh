#!/bin/bash
# CREDEBL PoC Initial Config Script
# Interactivo: genera .env y config clave para un despliegue limpio y fácil
# Uso: bash scripts/init-credebl-config.sh

set -e

# --- FUNCIONES AUXILIARES ---
gen_pass() { head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
gen_hex() { head -c 32 /dev/urandom | xxd -p | head -c 64; }
gen_secret() { openssl rand -hex 32; }
gen_base64() { openssl rand -base64 32 | tr -d '\n'; }

# --- PREGUNTAS CLAVE AL USUARIO ---
echo "[CONFIG] Iniciando configuración interactiva CREDEBL PoC..."
read -p "Dominio público para deeplink (ej: https://cdpi-poc.duckdns.org:4000): " DEEPLINK_DOMAIN
echo "Dominio deeplink: $DEEPLINK_DOMAIN"
read -p "Email del administrador: " ADMIN_EMAIL

# --- GENERACIÓN AUTOMÁTICA DE CLAVES Y CONTRASEÑAS ---
POSTGRES_PASSWORD=$(gen_pass)
KEYCLOAK_ADMIN_PASSWORD=$(gen_pass)
KEYCLOAK_CLIENT_SECRET=$(gen_secret)
PLATFORM_ADMIN_INITIAL_PASSWORD=$(gen_pass)
PLATFORM_WALLET_PASSWORD=$(gen_pass)
AGENT_API_KEY=$(gen_pass)
WALLET_STORAGE_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$(gen_secret)
NEXTAUTH_SECRET=$(gen_secret)
PLATFORM_SEED=$(gen_secret)
ADMIN_PASSWORD=$(gen_pass)
MINIO_ROOT_PASSWORD=$(gen_pass)
AWS_ACCESS_KEY_ID=credebls3
AWS_SECRET_ACCESS_KEY=$(gen_pass)
CRYPTO_PRIVATE_KEY=$(gen_hex)

# --- CREAR .env ---
cat > credebl/.env <<EOF
# --- CREDEBL PoC .env generado automáticamente ---
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_PASSWORD=$ADMIN_PASSWORD
CRYPTO_PRIVATE_KEY=$CRYPTO_PRIVATE_KEY
SCHEMA_FILE_SERVER_URL=$DEEPLINK_DOMAIN/schemas/

POSTGRES_USER=credebl
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=credebl
DATABASE_URL=postgresql://credebl:$POSTGRES_PASSWORD@postgres:5432/credebl
POOL_DATABASE_URL=postgresql://credebl:$POSTGRES_PASSWORD@postgres:5432/credebl

KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD
KEYCLOAK_DOMAIN=http://keycloak:8080/
KEYCLOAK_ADMIN_URL=http://keycloak:8080
KEYCLOAK_MASTER_REALM=master
KEYCLOAK_REALM=credebl-realm
KEYCLOAK_CLIENT_ID=credebl-client
KEYCLOAK_CLIENT_SECRET=$KEYCLOAK_CLIENT_SECRET
KEYCLOAK_MANAGEMENT_CLIENT_ID=adminClient
KEYCLOAK_MANAGEMENT_CLIENT_SECRET=$KEYCLOAK_CLIENT_SECRET
PLATFORM_ADMIN_KEYCLOAK_ID=adminClient
PLATFORM_ADMIN_KEYCLOAK_SECRET=$KEYCLOAK_CLIENT_SECRET
PLATFORM_ADMIN_INITIAL_PASSWORD=$PLATFORM_ADMIN_INITIAL_PASSWORD
KEYCLOAK_PUBLIC_URL=$DEEPLINK_DOMAIN:8080

MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
MINIO_CONSOLE_PORT=9011
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
AWS_ENDPOINT=http://minio:9000
AWS_REGION=us-east-1
S3_BUCKET_NAME=credebl-bucket
S3_STOREOBJECT_BUCKET=credebl-bucket
AWS_BUCKET=credebl-bucket
AWS_S3_STOREOBJECT_ACCESS_KEY=$AWS_ACCESS_KEY_ID
AWS_S3_STOREOBJECT_SECRET_KEY=$AWS_SECRET_ACCESS_KEY
AWS_S3_STOREOBJECT_REGION=us-east-1
AWS_S3_STOREOBJECT_BUCKET=credebl-bucket

EMAIL_PROVIDER=smtp
SENDGRID_API_KEY=SG.mock-not-used
SMTP_HOST=mailpit
SMTP_PORT=1025
SMTP_SECURE=false
SMTP_USER=mailpit
SMTP_PASS=mailpit
EMAIL_FROM=noreply@cdpi-poc.local

API_GATEWAY_PROTOCOL=http
API_GATEWAY_HOST=0.0.0.0
API_GATEWAY_PORT=5000
PLATFORM_SEED=$PLATFORM_SEED
JWT_SECRET=$JWT_SECRET
JWT_EXPIRY=1d
NEXTAUTH_SECRET=$NEXTAUTH_SECRET
NEXTAUTH_COOKIE_DOMAIN=
API_ENDPOINT=$DEEPLINK_DOMAIN:5000
VPS_IP=$DEEPLINK_DOMAIN
PLATFORM_WEB_URL=$DEEPLINK_DOMAIN:5000
FRONT_END_URL=$DEEPLINK_DOMAIN:5000
STUDIO_URL=$DEEPLINK_DOMAIN:3000
SOCKET_HOST=$DEEPLINK_DOMAIN:5000
ENABLE_CORS_IP_LIST=$DEEPLINK_DOMAIN:3000,http://localhost:3000,http://127.0.0.1:3000
APP_PROTOCOL=http
PLATFORM_NAME=CREDEBL
PUBLIC_PLATFORM_SUPPORT_EMAIL=support@cdpi-poc.local
POWERED_BY=CDPI
POWERED_BY_URL=https://cdpi-poc.local
ORGANIZATION=credebl
CONTEXT=platform
APP=api
CONSOLE_LOG_FLAG=true
ELK_LOG=false
LOG_LEVEL=info
NEXT_PUBLIC_ACTIVE_THEME=credebl
OOB_BATCH_SIZE=50
PROOF_REQ_CONN_LIMIT=50
PLATFORM_ADMIN_EMAIL=$ADMIN_EMAIL
PLATFORM_WALLET_NAME=platformadminwallet
PLATFORM_WALLET_PASSWORD=$PLATFORM_WALLET_PASSWORD
AGENT_API_KEY=$AGENT_API_KEY
AGENT_PROTOCOL=http
WALLET_STORAGE_HOST=$DEEPLINK_DOMAIN
WALLET_STORAGE_PORT=5432
WALLET_STORAGE_USER=credebl
WALLET_STORAGE_PASSWORD=$WALLET_STORAGE_PASSWORD
EOF

# --- REPORTE FINAL ---
echo "\n[CONFIG] Configuración inicial completada. Resumen de credenciales y acceso:"
echo "------------------------------------------------------"
echo "Dominio deeplink: $DEEPLINK_DOMAIN"
echo "Email admin: $ADMIN_EMAIL"
echo "Password admin: $ADMIN_PASSWORD"
echo "Postgres password: $POSTGRES_PASSWORD"
echo "Keycloak admin password: $KEYCLOAK_ADMIN_PASSWORD"
echo "Keycloak client secret: $KEYCLOAK_CLIENT_SECRET"
echo "Studio admin password: $PLATFORM_ADMIN_INITIAL_PASSWORD"
echo "Wallet password: $PLATFORM_WALLET_PASSWORD"
echo "Agent API key: $AGENT_API_KEY"
echo "JWT secret: $JWT_SECRET"
echo "NextAuth secret: $NEXTAUTH_SECRET"
echo "MinIO root password: $MINIO_ROOT_PASSWORD"
echo "AWS S3 Access Key: $AWS_ACCESS_KEY_ID"
echo "AWS S3 Secret Key: $AWS_SECRET_ACCESS_KEY"
echo "Crypto Private Key: $CRYPTO_PRIVATE_KEY"
echo "Plataforma seed: $PLATFORM_SEED"
echo "Archivo generado: credebl/.env"
echo "------------------------------------------------------"
echo "\nGuarda este reporte en un lugar seguro."
echo "Crypto Private Key: $CRYPTO_PRIVATE_KEY"
echo "Archivo generado: credebl/.env"
echo "------------------------------------------------------"
echo "\nPuedes continuar con el script maestro de setup."
