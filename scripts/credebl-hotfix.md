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

## Notas
- Si cambian los nombres de los contenedores, ajusta las variables en el script.
- Si hay cambios mayores en la estructura de los archivos, revisa y adapta el sed del script.
- Documenta cualquier error nuevo para futuros fixes.
