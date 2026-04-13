#!/bin/bash
# CREDEBL PoC RESET SCRIPT
# Elimina todo rastro de una instalación previa de CREDEBL/cdpi-poc en este VPS
# Uso: bash scripts/reset-credebl-poc.sh

set -e


# Always resolve project root (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
echo "[RESET] Parando y eliminando contenedores CREDEBL..."
docker compose --env-file credebl/.env -f credebl/docker-compose.yml down --volumes --remove-orphans || true

# 2. Eliminar imágenes de CREDEBL (opcional, solo si quieres limpiar espacio)
# echo "[RESET] Eliminando imágenes CREDEBL..."
# docker images | grep credebl | awk '{print $3}' | xargs -r docker rmi || true

# 3. Eliminar volúmenes de datos persistentes
VOLUMENES=$(docker volume ls -q | grep credebl || true)
if [ -n "$VOLUMENES" ]; then
  echo "[RESET] Eliminando volúmenes CREDEBL..."
  echo "$VOLUMENES" | xargs docker volume rm || true
fi


# 4. Eliminar archivos de configuración y datos locales
echo "[RESET] Eliminando archivos de configuración y datos locales..."
if [ -f "$PROJECT_ROOT/credebl/.env" ]; then
  rm -f "$PROJECT_ROOT/credebl/.env" && echo "[RESET] credebl/.env deleted."
else
  echo "[RESET] credebl/.env not found or already deleted."
fi
rm -rf credebl/certs/*
rm -rf credebl/config/aws/*
rm -rf credebl/config/postgres-init.sql credebl/config/keycloak-realm.json credebl/config/credebl-master-table.json
rm -rf inji/.env inji/certs/* inji/config/postgres-init.sql

# 5. Limpiar logs y archivos temporales
rm -f /tmp/credebl-e2e.log

# 6. Mensaje final
echo "[DONE] El servidor está limpio y listo para una nueva instalación CREDEBL."
