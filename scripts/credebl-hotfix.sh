#!/bin/bash
# CREDEBL Hotfix Script
# Aplica los hotfixes necesarios a los contenedores utility y tenant agent tras cada build/redeploy.
# Uso: bash scripts/credebl-hotfix.sh

set -e

# --- CONFIGURACIÓN ---
UTILITY_CONTAINER=$(docker ps --format '{{.Names}}' | grep utility | head -n1)
AGENT_CONTAINER=$(docker ps --format '{{.Names}}' | grep agent | head -n1)

# --- HOTFIX UTILITY (S3/MinIO endpoint/path-style) ---
echo "[HOTFIX] Parcheando utility para MinIO S3..."
docker exec "$UTILITY_CONTAINER" bash -c '
  if grep -q "endpoint: process.env.AWS_ENDPOINT" /app/dist/apps/utility/main.js; then
    echo "[INFO] Utility ya parchado."
  else
    sed -i "/new AWS.S3({/a \\ \ \ \ \ endpoint: process.env.AWS_ENDPOINT,\n    s3ForcePathStyle: true," /app/dist/apps/utility/main.js
    echo "[OK] Utility parchado para MinIO."
  fi
'

echo "[HOTFIX] Reiniciando utility..."
docker restart "$UTILITY_CONTAINER"

# --- HOTFIX TENANT AGENT (CredentialEvents.js guard) ---
echo "[HOTFIX] Parcheando tenant agent CredentialEvents.js..."
docker exec "$AGENT_CONTAINER" bash -c '
  FILE=/app/build/events/CredentialEvents.js
  if grep -q "?.getFormatData" "$FILE"; then
    echo "[INFO] Tenant agent ya parchado."
  else
    sed -i "s/getFormatData(/?.getFormatData(/g" "$FILE"
    echo "[OK] Tenant agent parchado."
  fi
'

echo "[HOTFIX] Reiniciando tenant agent..."
docker restart "$AGENT_CONTAINER"

echo "[DONE] Hotfixes aplicados."
