# CREDEBL Deployment Manual
## CDPI PoC — Country Team Guide

**Stack**: CREDEBL + MinIO + Mailpit + Keycloak  
**Purpose**: Self-contained Proof of Concept deployment  
**Audience**: Country DevOps engineer + CDPI

---

## Prerequisites

Your VPS must have:
- Ubuntu 22.04 or 24.04 LTS
- 4 CPU cores, 8GB RAM, 150GB disk
- Docker Engine (installed by setup-vps.sh)
- Ports open: 22, 80, 443, 3000, 5000, 8080, 9001, 8025, 4000

If the VPS is fresh, run the setup script first:

```bash
sudo bash scripts/setup-vps.sh
```

---

## First-time deployment

### 1. Clone the repository

```bash
cd /opt/cdpi-poc
git clone <CDPI_REPO_URL> .
```

### 2. Configure environment

**Recommended (interactive):**
```bash
bash ../scripts/init-credebl.sh
```

This prompts for the required values, writes `credebl/.env`, updates the seed host config, and runs the Docker startup commands automatically.

**Manual alternative:**
```bash
cd credebl
cp .env.example .env
```

Open `.env` and fill in every value marked `# REQUIRED`:

```bash
nano .env
```

Minimum required values:
```env
POSTGRES_PASSWORD=<strong-password>
REDIS_PASSWORD=                      # leave blank in the self-contained PoC
KEYCLOAK_ADMIN_PASSWORD=<strong-password>
KEYCLOAK_CLIENT_SECRET=<run: openssl rand -hex 32>
KEYCLOAK_MANAGEMENT_CLIENT_SECRET=<copy KEYCLOAK_CLIENT_SECRET>
PLATFORM_ADMIN_KEYCLOAK_SECRET=<copy KEYCLOAK_CLIENT_SECRET>
# keep KEYCLOAK_MANAGEMENT_CLIENT_ID=adminClient
# keep PLATFORM_ADMIN_KEYCLOAK_ID=adminClient
MINIO_ROOT_PASSWORD=<strong-password>
AWS_ACCESS_KEY_ID=<alphanumeric only — e.g. credebls3>
AWS_SECRET_ACCESS_KEY=<alphanumeric only — e.g. run: openssl rand -hex 16>
PLATFORM_SEED=<run: openssl rand -hex 16>
PLATFORM_WALLET_NAME=platformadminwallet
PLATFORM_WALLET_PASSWORD=<run: openssl rand -hex 16>
AGENT_API_KEY=<run: openssl rand -hex 32>
AGENT_PROTOCOL=http
WALLET_STORAGE_HOST=postgres
WALLET_STORAGE_PORT=5432
WALLET_STORAGE_USER=credebl
WALLET_STORAGE_PASSWORD=<copy POSTGRES_PASSWORD>
JWT_SECRET=<run: openssl rand -hex 32>
JWT_TOKEN_SECRET=<run: openssl rand -base64 32>
PLATFORM_ADMIN_EMAIL=admin@cdpi-poc.local
PLATFORM_ADMIN_INITIAL_PASSWORD=changeme  # OPTIONAL — initial Studio login password
CRYPTO_PRIVATE_KEY=cdpi-poc-crypto-key-change-me
NATS_AUTH_TYPE=none
ELK_LOG=false
APP_PROTOCOL=http
ENABLE_CORS_IP_LIST=http://YOUR_VPS_IP:3000,http://localhost:3000,http://127.0.0.1:3000
```

Use the exact Studio origin **without a trailing slash**:
```env
STUDIO_URL=http://YOUR_VPS_IP:3000
```

> **Redis note**: in this PoC, keep `REDIS_PASSWORD` empty. The bundled `issuance` worker uses Bull with `host` + `port` only and does not send a Redis password, so enabling `requirepass` causes the repeated `NOAUTH Authentication required` errors seen in `docker compose logs issuance`.

> **Password character restriction**: Do NOT use `@`, `-`, or any character outside `[A-Za-z0-9]` in passwords or access keys. The `schema-file-server` (Deno) and `minio-setup` containers decode several env vars as base64 internally, and special characters cause an `InvalidCharacterError` crash. Use `openssl rand -hex 16` (hex output, always safe) for passwords and `openssl rand -base64 32` for `JWT_TOKEN_SECRET` (which is explicitly base64-decoded).

Also replace `YOUR_VPS_IP` with your actual VPS IP address in both `.env` and the seed data file:
```bash
VPS_IP=$(curl -s ifconfig.me)
sed -i "s/YOUR_VPS_IP/$VPS_IP/g" .env config/credebl-master-table.json
echo "Updated .env and credebl-master-table.json with VPS IP: $VPS_IP"
```

Keep both database variables present in `.env` using the plain password (no URL-encoding needed if the password is alphanumeric-only):
```env
DATABASE_URL=postgresql://credebl:YOUR_POSTGRES_PASSWORD@postgres:5432/credebl
POOL_DATABASE_URL=postgresql://credebl:YOUR_POSTGRES_PASSWORD@postgres:5432/credebl
API_GATEWAY_PROTOCOL=http
API_GATEWAY_HOST=0.0.0.0
API_ENDPOINT=YOUR_VPS_IP:5000
```

> Docker does not expand `${POSTGRES_PASSWORD}` inside `env_file` values, so the full URL must be written out literally. Keep `API_GATEWAY_HOST=0.0.0.0`; the compiled app calls `app.listen(PORT, API_GATEWAY_HOST)` and will crash with `getaddrinfo EAI_AGAIN undefined` if that variable is missing.

> **CORS note**: `ENABLE_CORS_IP_LIST` must include the exact Studio origin (for example `http://YOUR_VPS_IP:3000`). If it is missing, Studio can accept the login form but fail to redirect to `/dashboard`, and dropdowns such as **Country / State / City** remain empty because the browser blocks requests to the API gateway on port `5000`.

### 3. Pull all images

```bash
docker compose pull
```

This downloads ~10GB of images. Do this before the mission day to save time.

### 4. Start infrastructure first

```bash
docker compose up -d postgres redis nats minio mailpit
```

Wait for all health checks to pass:

```bash
watch docker compose ps
```

All infrastructure containers should show `healthy` before continuing.

### 5. Set up MinIO access keys

The `minio-setup` service runs automatically as part of `docker compose up -d` and creates the bucket and access key defined in `.env` (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). No manual step required.

To verify it ran successfully:
```bash
docker compose logs minio-setup
```
Expected last line: `MinIO setup complete`

If you need to re-run it (e.g. after changing credentials):
```bash
docker compose up -d --force-recreate minio-setup
```

> If organization creation fails with `The AWS Access Key Id you provided does not exist in our records`, MinIO is up but the S3 user was not bootstrapped with the current `.env` values. Re-run `minio-setup`, then recreate the affected services:
>
> ```bash
> docker compose up -d --force-recreate minio-setup api-gateway organization utility
> ```

### 6. Start Keycloak

```bash
docker compose up -d keycloak
```

The imported `credebl-realm` already includes the confidential `adminClient` used by the bootstrap flow, with the `realm-management` `realm-admin` role assigned to its service account. On a **fresh** server, no extra `kcadm.sh` commands are needed.

Keycloak takes 60-90 seconds to start. Watch the logs:

```bash
docker compose logs -f keycloak
```

Wait until you see: `Keycloak X.X.X on JVM ... started`

### 7. Optional — enable HTTPS for Keycloak

If you have a real domain pointing to the VPS (for example `auth.example.org`), you can automate Nginx + Let's Encrypt setup with:

```bash
sudo bash scripts/setup-keycloak-https.sh \
  --domain auth.example.org \
  --email admin@example.org
```

This script will:
- install `nginx`, `certbot`, and the Nginx Certbot plugin
- open ports `80` and `443`
- create an Nginx reverse proxy to the local Keycloak container
- request a Let's Encrypt certificate
- update `credebl/.env` so `KEYCLOAK_PUBLIC_URL` uses `https://...`

> Note: Let's Encrypt requires a real domain name. It does not issue certificates for a raw public IP.

### 8. Start all CREDEBL services

```bash
docker compose up -d
```

This now includes the locally built `studio` frontend at `http://YOUR_VPS_IP:3000`.

### 9. Watch startup progress

```bash
docker compose ps
docker compose logs -f api-gateway
```

The full stack takes 3-5 minutes to be fully ready.  
The `seed` container will run Prisma migrations, seed the database, and then exit — that is normal.

> If you change `config/keycloak-realm.json` later, remember that Keycloak only imports the realm on first creation. Reusing an existing PostgreSQL/Keycloak state will keep the old realm config until you reset the stack data.

### 10. Verify deployment

```bash
bash scripts/health-check.sh
```

Expected output:
```
✓ postgres        healthy
✓ redis           healthy
✓ nats            healthy
✓ keycloak        healthy
✓ minio           healthy
✓ mailpit         running
✓ api-gateway     healthy  http://VPS_IP:5000
✓ studio          running  http://VPS_IP:3000
✓ schema-file-server  running  http://VPS_IP:4000
All services healthy — PoC stack is ready
```

---

## Daily operations

### Start the stack

```bash
cd /opt/cdpi-poc/credebl
docker compose up -d
```

### Stop the stack

```bash
docker compose down
```

### Stop and remove all data (full reset)

```bash
docker compose down -v
```

⚠️ This deletes all volumes including the database. Use only for a clean restart.

### View logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f api-gateway
docker compose logs -f issuance
docker compose logs -f verification

# Last 100 lines of a service
docker compose logs --tail=100 organization
```

### Check resource usage

```bash
docker stats --no-stream
```

### Restart a single service

```bash
docker compose restart api-gateway
docker compose restart issuance
```

---

## Verifying issuance and verification flows

See `docs/test-flows.md` for step-by-step curl commands to test:
1. User registration
2. Organization creation
3. Schema creation
4. Credential definition
5. Credential issuance
6. Credential verification

---

## Access points summary

| Service | URL | Credentials |
|---------|-----|-------------|
| **Studio (web UI)** | `http://VPS_IP:3000` | Initial login: `admin@cdpi-poc.local` / value of `PLATFORM_ADMIN_INITIAL_PASSWORD` (default: `changeme`) |
| CREDEBL API | `http://VPS_IP:5000` | JWT from `POST /v1/auth/signin` (password must be encrypted like Studio does) |
| Keycloak Console | `http://VPS_IP:8080` | `master` realm → `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` |
| MinIO Console | `http://VPS_IP:9001` | MINIO_ROOT_USER / PASSWORD |
| Mailpit (email) | `http://VPS_IP:8025` | No auth |
| Schema Server | `http://VPS_IP:4000` | No auth |

> **Studio first-login note**: Studio authenticates with the seeded platform user `admin@cdpi-poc.local` and the value of `PLATFORM_ADMIN_INITIAL_PASSWORD` (default: `changeme`) — **not** with the Keycloak master admin password. The bundled `keycloak-realm.json` already registers `http://YOUR_VPS_IP:3000/*` as a valid redirect URI. If you access Studio from a different address (e.g. a domain), add the redirect URI in Keycloak Console → `credebl-realm` → Clients → `credebl-client` → Valid redirect URIs.
>
> **Fresh-install note**: `docker compose up -d` now runs the one-shot `platform-admin-bootstrap` service after `seed` to ensure the Keycloak user exists, its password is set, and the Postgres record gets the correct `keycloakUserId`. If you ever need to re-sync that account manually on an existing VPS, run `docker compose run --rm platform-admin-bootstrap`.

---

## Troubleshooting

### Container exits immediately

```bash
docker compose logs <service-name>
```
Look for the error on the last lines.

### Services stuck in `starting` state

Usually a startup ordering issue. Wait 2 minutes, then:

```bash
docker compose restart
```

### Postgres connection errors

```bash
# Check if postgres is healthy
docker compose ps postgres

# Check postgres logs
docker compose logs postgres

# Verify credentials
docker compose exec postgres psql -U credebl -c "\l"
```

### Out of memory

```bash
# Check what is using memory
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"

# Check swap usage
free -h
```

If memory is critical, stop the `webhook` service first. The self-contained PoC does not include the `geolocation` microservice by default; if the Country / State / City dropdowns are empty in Studio, you can still continue because those fields are optional in the PoC flow.

### Shared wallet creation still fails on `POST /orgs/:orgId/agents/wallet`

If `cloud-wallet`, `agent-provisioning`, and `agent-service` are all already `Up`, the remaining failure is usually **platform-admin shared-agent provisioning**, not the `cloud-wallet` container itself.

The shared-wallet path depends on these `.env` values being present and consistent:
- `PLATFORM_WALLET_NAME`
- `PLATFORM_WALLET_PASSWORD`
- `AGENT_API_KEY`
- `WALLET_STORAGE_HOST`
- `WALLET_STORAGE_PORT`
- `WALLET_STORAGE_USER`
- `WALLET_STORAGE_PASSWORD` (same value as `POSTGRES_PASSWORD` in this PoC)

Fix:
```bash
cd credebl
grep -E '^(PLATFORM_WALLET_NAME|PLATFORM_WALLET_PASSWORD|AGENT_API_KEY|WALLET_STORAGE_HOST|WALLET_STORAGE_PORT|WALLET_STORAGE_USER|WALLET_STORAGE_PASSWORD|SOCKET_HOST)=' .env

docker compose up -d --force-recreate agent-provisioning agent-service cloud-wallet

docker compose logs --tail=200 agent-service
docker compose logs --tail=200 agent-provisioning

docker compose exec -T postgres env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "
    SELECT o.name, oa.\"agentSpinUpStatus\", oa.\"agentEndPoint\"
    FROM organisation o
    JOIN org_agents oa ON oa.\"orgId\" = o.id
    WHERE o.name = 'Platform-admin';"

# If the row is stuck in status 1 (wallet created but DID not finished),
# remove the stale partial record and let agent-service recreate it cleanly.
docker compose exec -T postgres env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    DELETE FROM org_agents oa
    USING organisation o
    WHERE oa.\"orgId\" = o.id
      AND o.name = 'Platform-admin'
      AND (oa.\"agentSpinUpStatus\" <> 2 OR COALESCE(oa.\"agentEndPoint\", '') = '');"

docker compose restart agent-provisioning agent-service
```

Look for errors mentioning:
- `Platform admin agent is not spun up`
- `Error while creating the wallet`
- missing wallet storage or API key values

Expected result: the `Platform-admin` row shows `agentSpinUpStatus = 2` with a non-empty `agentEndPoint`, and retrying **Create Shared Wallet** in Studio stops returning the `create-tenant` 500.

### `minio-setup` exited with failure

If the health check shows `minio-setup ← FAILED`, rerun the one-shot MinIO bootstrap container:

```bash
cd credebl
docker compose rm -sf minio-setup

docker compose up --no-deps minio-setup

docker inspect --format='{{.State.Status}} {{.State.ExitCode}}' credebl-minio-setup
```

Expected result: `exited 0`

### schema-file-server keeps restarting (`InvalidCharacterError: Failed to decode base64`)

The Deno-based schema-file-server base64-decodes `JWT_TOKEN_SECRET` at startup. Two causes:

**1. `JWT_TOKEN_SECRET` not set** — falls back to default `"your_secret_key_here"` which contains `_` (invalid in standard base64). Fix: add it to `.env`:
```bash
echo "JWT_TOKEN_SECRET=$(openssl rand -base64 32)" >> .env
docker compose up -d --force-recreate schema-file-server
```

**2. `JWT_TOKEN_SECRET` set but contains invalid chars** — only `[A-Za-z0-9+/=]` are valid. Regenerate with `openssl rand -base64 32`.

### Port already in use

```bash
# Find what is using a port (e.g. 5000)
sudo lsof -i :5000
sudo netstat -tlnp | grep 5000
```

---

## Re-deploying after code changes

```bash
cd /opt/cdpi-poc/credebl

# Pull latest images
docker compose pull

# Restart updated services
docker compose up -d --force-recreate
```
