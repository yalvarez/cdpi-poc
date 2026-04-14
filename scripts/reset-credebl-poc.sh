#!/bin/bash
# CREDEBL PoC RESET SCRIPT
# Elimina todo rastro de una instalación previa de CREDEBL/cdpi-poc en este VPS.
# Los archivos de configuración del repositorio (postgres-init.sql, keycloak-realm.json,
# credebl-master-table.json) NO se borran — son archivos git tracked y se restauran
# a su estado correcto con `git checkout`.
#
# Uso: bash scripts/reset-credebl-poc.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# 1. Parar y eliminar contenedores + volúmenes de Docker
echo "[RESET] Parando y eliminando contenedores CREDEBL..."
docker compose --env-file credebl/.env -f credebl/docker-compose.yml down --volumes --remove-orphans 2>/dev/null || true

# 2. Eliminar contenedores Credo (spawneados fuera del compose scope)
STALE_CREDO=$(docker ps -a \
  --filter "ancestor=ghcr.io/credebl/credo-controller:latest" \
  --format "{{.Names}}" 2>/dev/null || true)
if [ -n "$STALE_CREDO" ]; then
  echo "[RESET] Eliminando contenedores Credo stale..."
  echo "$STALE_CREDO" | xargs docker rm -f
fi

# 3. Eliminar volúmenes residuales con nombre cdpi-credebl_*
VOLUMENES=$(docker volume ls -q | grep -E '^cdpi-credebl_' || true)
if [ -n "$VOLUMENES" ]; then
  echo "[RESET] Eliminando volúmenes CREDEBL..."
  echo "$VOLUMENES" | xargs docker volume rm || true
fi

# 4. Eliminar .env (generado por init-credebl.sh — no es tracked en git)
if [ -f "$PROJECT_ROOT/credebl/.env" ]; then
  rm -f "$PROJECT_ROOT/credebl/.env"
  echo "[RESET] credebl/.env eliminado."
fi

# 5. Eliminar agent runtime (generado, no tracked)
rm -rf "$PROJECT_ROOT/credebl/.agent-runtime"
echo "[RESET] Agent runtime eliminado."

# 6. Restaurar archivos de config del repo a su estado git original
#    (init-credebl.sh los modifica al correr; esta restauración los deja limpios
#     para el próximo init)
echo "[RESET] Restaurando archivos de config del repositorio..."
git -C "$PROJECT_ROOT" checkout -- \
  credebl/config/credebl-master-table.json \
  2>/dev/null && echo "[RESET] credebl-master-table.json restaurado." || true

# 7. Limpiar logs temporales
rm -f /tmp/credebl-e2e.log

echo
echo "[DONE] Servidor limpio. Siguiente paso:"
echo "  bash scripts/init-credebl.sh"
