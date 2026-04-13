#!/bin/bash
# CREDEBL PoC Setup Script
# Un solo comando para dejar el PoC listo: levanta servicios, aplica hotfixes y valida salud.
# Uso: bash scripts/setup-credebl-poc.sh

set -e

# 1. Levantar servicios principales

echo "[SETUP] Levantando servicios CREDEBL..."
docker compose --env-file credebl/.env -f credebl/docker-compose.yml up -d

# 2. Esperar a que MinIO y dependencias estén listas
# (Opcional: puedes ajustar el tiempo si tu VPS es más rápido/lento)
echo "[SETUP] Esperando a que MinIO y dependencias estén listas..."
sleep 20

# 3. Aplicar hotfixes (utility y tenant agent)
echo "[SETUP] Aplicando hotfixes..."
bash scripts/credebl-hotfix.sh

# 4. Health-check de la plataforma
if [ -f scripts/health-check.sh ]; then
  echo "[SETUP] Ejecutando health-check..."
  bash scripts/health-check.sh || { echo '[ERROR] Health-check falló'; exit 1; }
else
  echo "[WARN] scripts/health-check.sh no encontrado, omitiendo chequeo de salud."
fi

echo "[DONE] CREDEBL PoC listo para usar."
