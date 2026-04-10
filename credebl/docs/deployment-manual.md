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
- Ports open: 22, 80, 443, 5000, 8080, 9001, 8025, 4000

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
REDIS_PASSWORD=<strong-password>
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
JWT_SECRET=<run: openssl rand -hex 32>
JWT_TOKEN_SECRET=<run: openssl rand -base64 32>
PLATFORM_ADMIN_EMAIL=admin@cdpi-poc.local
CRYPTO_PRIVATE_KEY=cdpi-poc-crypto-key-change-me
NATS_AUTH_TYPE=none
ELK_LOG=false
APP_PROTOCOL=http
```

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
docker compose up --force-recreate minio-setup
```

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
| **Studio (web UI)** | `http://VPS_IP:3000` | Initial login: `admin@cdpi-poc.local` / `changeme` |
| CREDEBL API | `http://VPS_IP:5000` | JWT from `POST /v1/auth/signin` (password must be encrypted like Studio does) |
| Keycloak Console | `http://VPS_IP:8080` | `master` realm → `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` |
| MinIO Console | `http://VPS_IP:9001` | MINIO_ROOT_USER / PASSWORD |
| Mailpit (email) | `http://VPS_IP:8025` | No auth |
| Schema Server | `http://VPS_IP:4000` | No auth |

> **Studio first-login note**: Studio authenticates with the seeded platform user `admin@cdpi-poc.local` / `changeme` — **not** with the Keycloak master admin password. The bundled `keycloak-realm.json` already registers `http://YOUR_VPS_IP:3000/*` as a valid redirect URI. If you access Studio from a different address (e.g. a domain), add the redirect URI in Keycloak Console → `credebl-realm` → Clients → `credebl-client` → Valid redirect URIs.
>
> **Existing VPS note**: if Studio still returns `401` with `Something went wrong!`, the usual cause is that the platform admin DB record is not linked to the Keycloak user yet (`keycloakUserId` is null). Run `bash ../scripts/fix-credebl-studio-login.sh` from the `credebl/` folder and then retry the Studio login.

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

If memory is critical, stop the `geolocation` and `webhook` services (not included in PoC stack by default).

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
