#!/bin/bash
# Reemplaza placeholders en archivos de configuración usando variables del .env
# Uso: bash scripts/render-configs.sh

set -e

# Cargar variables del .env
set -a
. credebl/.env
set +a

# Renderizar credebl-master-table.json
envsubst < credebl/config/credebl-master-table.json > credebl/config/credebl-master-table.rendered.json
mv credebl/config/credebl-master-table.rendered.json credebl/config/credebl-master-table.json

# (Opcional) Agrega aquí otros archivos a renderizar con envsubst
# envsubst < credebl/config/keycloak-realm.json > credebl/config/keycloak-realm.rendered.json
# mv credebl/config/keycloak-realm.rendered.json credebl/config/keycloak-realm.json

# Mensaje final
echo "[OK] Archivos de configuración renderizados con valores del .env."
