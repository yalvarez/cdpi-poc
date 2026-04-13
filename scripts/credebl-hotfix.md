# Hotfixes CREDEBL PoC — Utility y Tenant Agent

## ¿Por qué son necesarios estos hotfixes?

Al no tener acceso al código fuente de los microservicios DPG (utility y tenant agent), algunos bugs/crashes solo pueden corregirse parchando los archivos ya compilados dentro de los contenedores Docker. Estos hotfixes aseguran que:
- El servicio utility use correctamente MinIO como S3 (endpoint/path-style).
- El tenant agent no crashee al emitir credenciales por un acceso no protegido en CredentialEvents.js.

## ¿Cuándo ejecutar el script?
- Siempre que reconstruyas o actualices los contenedores de CREDEBL (utility o agent).
- Tras un `docker compose up --build` o pull de nuevas imágenes.
- Antes de correr el E2E o exponer el PoC a usuarios.

## ¿Cómo ejecutar el script?

1. Da permisos de ejecución:
   ```bash
   chmod +x scripts/credebl-hotfix.sh
   ```
2. Ejecútalo desde la raíz del repo:
   ```bash
   bash scripts/credebl-hotfix.sh
   ```

## ¿Qué hace cada hotfix?

### 1. Utility S3/MinIO
- Parchea `/app/dist/apps/utility/main.js` dentro del contenedor utility para que el cliente S3 use el endpoint y path-style de MinIO.
- Reinicia el contenedor utility.

### 2. Tenant Agent CredentialEvents.js
- Parchea `/app/build/events/CredentialEvents.js` dentro del contenedor agent para evitar crash por acceso no protegido a `getFormatData`.
- Reinicia el contenedor agent.

## ¿Cómo verificar que funcionó?
- El script imprime `[OK]` tras cada parche.
- El E2E debe avanzar sin errores de S3 ni crash del agent.
- Puedes revisar logs con:
  ```bash
  docker logs <nombre_contenedor>
  ```

## Hotfix 3 — Stale Credo controller container (`error in wallet provision : {}`)

### Síntoma
`agent-service` arranca, encuentra el org de Platform-admin en la DB, intenta provisionar
el wallet vía NATS a `agent-provisioning`, y falla con error vacío `{}`. Los servicios
`agent-service` y `agent-provisioning` entran en crash-loop sin mensaje de error útil.

### Causa raíz
Los containers Credo controller (`ghcr.io/credebl/credo-controller:latest`) son lanzados
por `agent-provisioning` vía `docker run` **fuera del scope de docker compose**. Cuando
se hace `docker compose down -v`, estos containers no se detienen. Si un container Credo
viejo sigue corriendo y tiene ocupados los puertos 8001/9001, el nuevo intento de spin-up
falla al hacer `docker run` con el puerto ya en uso — la excepción es swallowed y solo se
ve `error in wallet provision : {}`.

### Fix manual (en VPS existente)
```bash
cd /home/apps/cdpi-poc/credebl

# 1. Identificar y matar containers Credo viejos
docker ps -a --filter "ancestor=ghcr.io/credebl/credo-controller:latest" --format "{{.Names}}"
docker rm -f <nombre_del_container_viejo>

# 2. Limpiar registro parcial en la DB
POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2)
docker compose exec -T postgres env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -U credebl -d credebl -c "
    DELETE FROM org_agents oa USING organisation o
    WHERE oa.\"orgId\" = o.id AND o.name = 'Platform-admin';"

# 3. Reiniciar servicios del agente
docker compose restart agent-provisioning agent-service

# 4. Esperar ~60s y verificar que el nuevo Credo container arrancó
docker ps | grep credo
```

### Fix permanente
El script `init-credebl.sh` ahora limpia estos containers automáticamente antes de
arrancar el stack y en cada ciclo de reintento del shared agent.

## Notas
- Si cambian los nombres de los contenedores, ajusta las variables en el script.
- Si hay cambios mayores en la estructura de los archivos, revisa y adapta el sed del script.
- Documenta cualquier error nuevo para futuros fixes.
