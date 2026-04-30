# CLAUDE.md — Project Context & Memory
## CDPI PoC Technical Repository

**Last updated**: April 21, 2026  
**Purpose**: This file gives Claude complete context to continue working on this project without needing to re-explain everything. Read this first before any session.

---

## Who is Ysaias and what is CDPI

Ysaias works at **CDPI (Centre for Digital Public Infrastructure)**, advising governments on Digital Public Infrastructure and Verifiable Credentials implementation. His work spans Latin America and is conducted in English and Spanish.

CDPI's advisory model involves in-country missions where they help governments adopt DPI building blocks — specifically VC (Verifiable Credentials) infrastructure. This repository is the technical foundation for those missions.

---

## The mission model (6-day in-country)

CDPI deploys a team for a **single 6-day in-country mission** per government engagement. Everything — process mapping, PoC build, real integrations, and handover — must happen within that window.

| Day | What happens |
|-----|-------------|
| 1 | Use case selection + as-is process mapping |
| 2 | To-be journey design + credential schema draft + technical handoff |
| 3 | DPG selection + stack decisions + environment setup + schema lock |
| 4 | Build — issuance and verification flows end-to-end |
| 5 | Real integrations (DB + OIDC) + source code handover + UAT sign-off |
| 6 | Presentation to government authorities + national scale-up roadmap |

**The critical constraint**: CDPI must arrive with everything pre-built. Days 3-5 are adaptation and integration — not construction from scratch. That's why this repository exists.

---

## First mission: Colombia (May 4-9, 2026)

- **May 4**: Day 1 — Use case + process mapping  
- **May 5**: Day 2 — Journey + schema + technical handoff  
- **May 6**: Day 3 — Stack decisions + setup  
- **May 7**: Day 4 — Build  
- **May 8**: Day 5 — Real integrations + handover  
- **May 9**: Day 6 — Presentation to Colombian government authorities  
- **Use case**: TBD — pending confirmation from Colombian counterpart  
- **DPG**: Selected on Day 3 jointly with Colombia  

---

## Repository structure and what's in it

```
cdpi-poc/
├── CLAUDE.md                      ← YOU ARE HERE
├── README.md                      ← Human-readable overview
├── .gitignore
├── scripts/
│   ├── setup-vps.sh               ← Ubuntu 22/24 VPS setup (Docker, firewall, swap)
│   ├── init-credebl.sh            ← CREDEBL single entry point: fresh deploy, patch recovery,
│   │                                 SendGrid/Mailpit choice, SSL/nginx/certbot/Keycloak-HTTPS
│   │                                 (5 interactive questions, 6-7 if SSL enabled)
│   ├── init-inji.sh               ← INJI single entry point: 1 interactive question,
│   │                                 secrets auto-generated, keystore gen, ordered startup,
│   │                                 DB schema user passwords, health check
│   ├── reset-credebl-poc.sh       ← Full CREDEBL teardown (containers + volumes + Credo)
│   ├── health-check.sh            ← CREDEBL stack verification (37 checks)
│   ├── health-check-inji.sh       ← INJI stack verification (15 checks)
│   ├── bootstrap-platform-admin.sh ← CREDEBL platform-admin sync (auto-run by init-credebl.sh)
│   └── generate-inji-certs.sh     ← PKCS12 keystore for INJI (called by init-inji.sh)
│
├── credebl/                       ← DPG Option A
│   ├── docker-compose.yml         ← 13 CREDEBL services + MinIO + Mailpit + Keycloak
│   ├── .env.example
│   ├── config/
│   │   ├── postgres-init.sql      ← Creates keycloak schema in shared DB
│   │   ├── keycloak-realm.json    ← Pre-configured OIDC realm with roles + clients
│   │   └── agent.env              ← Credo agent config (BCovrin testnet)
│   ├── schemas/                   ← SD-JWT VC templates (see schema section below)
│   │   ├── README.md
│   │   ├── employment.json
│   │   ├── education.json
│   │   ├── professional-license.json
│   │   └── civil-identity.json
│   ├── sdk/
│   │   ├── README.md
│   │   ├── sdk.js                 ← Node.js verification SDK (no external deps)
│   │   └── sdk.py                 ← Python 3.8+ SDK (stdlib only)
│   └── docs/
│       ├── deployment-manual.md
│       ├── oidc-swap-procedure.md ← Day 5: swap Keycloak for country OIDC
│       ├── test-flows.md          ← Complete curl sequences for all flows
│       ├── api-test.sh            ← Full E2E CREDEBL test (8 steps: signin → issuance → list)
│       ├── api-test-oid4vc.sh     ← OID4VCI + OID4VP end-to-end test (9 steps)
│       ├── api-e2e-requests.md    ← Annotated curl reference for all API endpoints
│       └── postman/               ← Postman collection + environment for CREDEBL API
│
└── inji/                          ← DPG Option B
    ├── docker-compose.yml         ← Certify + eSignet + Mimoto + Inji Web + Nginx
    ├── .env.example
    ├── config/
    │   ├── postgres-init.sql      ← Creates schemas for Certify, eSignet, Mimoto
    │   ├── certify/
    │   │   ├── application.properties       ← Core Certify Spring Boot config
    │   │   ├── certify-employment.properties ← Employment credential config
    │   │   ├── softhsm-application.conf     ← SoftHSM key manager (containerized)
    │   │   └── data/employment-sample.csv   ← Mock data for default profile
    │   ├── esignet/
    │   │   └── application.properties       ← eSignet OIDC provider config
    │   ├── mimoto/
    │   │   ├── application.properties
    │   │   ├── mimoto-issuers-config.json   ← Issuer list for Inji Web
    │   │   └── mimoto-trusted-verifiers.json
    │   └── nginx/
    │       └── certify.conf                 ← .well-known routing (required by OID4VCI)
    ├── certs/
    │   └── .gitkeep               ← Keystore goes here (generated, not committed)
    ├── sdk/
    │   ├── README.md
    │   ├── sdk.js                 ← Node.js OID4VP verification SDK
    │   └── sdk.py                 ← Python OID4VP verification SDK
    └── docs/
        ├── deployment-manual.md
        ├── oidc-swap-procedure.md ← Day 5: swap eSignet for country OIDC
        └── test-flows.md          ← INJI-specific test sequences
```

---

## DPG technical comparison

| | CREDEBL | INJI |
|--|---------|------|
| **Images** | `ghcr.io/credebl/*` | `mosipid/inji-certify-with-plugins`, `mosipid/esignet-with-plugins`, `mosipid/mock-identity-system`, `mosipid/mimoto`, `mosipid/inji-web` |
| **Architecture** | ~13 microservices + infra | 10 services (Spring Boot + Nginx + infra) |
| **Auth server** | Keycloak 25.0.6 | eSignet 1.5.1 (MOSIP) |
| **Storage** | MinIO (replaces AWS S3) | Not needed |
| **Email** | Mailpit (replaces SendGrid) | Mailpit |
| **Credential format** | SD-JWT VC, AnonCreds | SD-JWT VC (vc+sd-jwt), W3C VCDM 1.1 + 2.0 |
| **Issuance protocol** | OID4VCI | OID4VCI draft 13 |
| **Verification protocol** | Custom CREDEBL API | OID4VP |
| **Wallet** | External (Inji, any OID4VCI) | Inji Web (port 3001) included |
| **Key management** | CREDEBL internal | SoftHSM (PKCS11, containerized) |
| **Plugin system** | No | Yes — DataProvider or VCIssuance plugins |
| **CERTIFY_PROFILE=default** | N/A | Uses mock CSV data (no DB needed) |
| **CERTIFY_PROFILE=postgres-local** | N/A | Uses real PostgreSQL data source |
| **ARM64 support** | Yes | **No — AMD64 only** → always `DOCKER_DEFAULT_PLATFORM=linux/amd64` |
| **RAM (8GB VPS)** | ~4.5GB | ~3.5GB |

---

## SD-JWT VC schemas — what's built

Each schema file has 5 sections:
1. `schema` — JSON Schema (field definitions + validation)
2. `vct_type_metadata` — wallet display metadata (labels, colors, EN+ES)
3. `disclosure_frame` — which fields are `_sd` (selective) vs always revealed
4. `sample_credential_data` — test data with realistic Latin American context
5. `credebl_api_payload` — ready to paste into CREDEBL's schema creation API

| File | Issuer | Always revealed | Selectively disclosable |
|------|--------|-----------------|------------------------|
| `employment.json` | Ministry of Labor | name, employer, position, status, start date | salary, doc number, contract type, dept |
| `education.json` | University / Min. Education | name, institution, degree, field, grad date | grade, doc number, program code, honors |
| `professional-license.json` | Licensing board / Colegio | name, profession, license #, status, dates | sanctions, doc number, qualification basis |
| `civil-identity.json` | Civil registry / JCE / RENIEC | name, doc number, doc type, nationality, status | birthdate, address, gender, tax ID, phone, email |

**Key design decision on civil-identity**: Added `age_over_18`, `age_over_21`, `age_over_65` as boolean SD fields. These allow privacy-preserving age verification without revealing exact birthdate.

---

## Infrastructure design decisions

### Why MinIO instead of AWS S3 (CREDEBL)
CREDEBL requires S3 for file storage (org logos, connection URLs, bulk issuance). MinIO is S3-compatible, runs in Docker, and requires zero external credentials. The `minio-setup` service creates the required bucket structure automatically on first run.

### Why Mailpit instead of SendGrid
CREDEBL uses SendGrid for transactional emails. Mailpit provides an SMTP server on port 1025 that captures all emails without sending them. Viewable at port 8025. No API key needed.

### Why eSignet stays in INJI (not replaced with Keycloak)
eSignet is deeply integrated into INJI Certify's token validation and subject identifier flow. The `sub` claim from eSignet's token maps directly to data lookups. Replacing it requires changes to Certify's auth configuration. On Day 5 we swap the issuer URL — not the entire service.

### Why SoftHSM for INJI key management
INJI Certify requires PKCS11 key management. SoftHSM provides a software-based PKCS11 HSM that runs inside the container. Generated by `generate-inji-certs.sh` before first deploy.

### Why WALLET_STORAGE_HOST=172.17.0.1 (not the VPS IP or 'postgres')
CREDEBL's `agent-provisioning` spawns the Credo controller container via the Docker socket using a generated child docker-compose file. That child container lands on Docker's **default bridge network** (`bridge`), not on `credebl-net`. As a result:
- `postgres` — not resolvable (Docker DNS only works inside named networks)
- VPS public IP — many VPS providers block self-connections at the NIC/loopback level
- `172.17.0.1` — the `docker0` bridge gateway; always reachable from any default-bridge container; routes to the host where port 5432 is published on `0.0.0.0`

This is hardcoded in `init-credebl.sh` and the `docker-compose.yml` fallback default. Do not change to the VPS hostname/IP.
 
### Ten required CREDEBL container patches (automated in init-credebl.sh)

These patches fix bugs in the published CREDEBL Docker images. `init-credebl.sh` applies them automatically via `apply_container_patches()` after every `docker compose up`. All are idempotent.

**Patch 1 — Utility service S3 → MinIO endpoint**
AWS SDK v2 ignores `AWS_ENDPOINT` from environment. CREDEBL's utility service creates three S3 clients without an `endpoint` option, so all S3 calls go to real AWS and fail with "Access Key Id does not exist". Fix: add `endpoint: process.env.AWS_ENDPOINT` and `s3ForcePathStyle: true` to all three constructors in `/app/dist/apps/utility/main.js`.
_Symptom if missing_: Wallet provisioning returns `{"statusCode":500,"message":"Something went wrong!"}`.

**Patch 2 — API gateway @context validator allows Docker-internal hostnames**
`IsCredentialJsonLdContext` calls `isURL(v)` with `require_tld: true` (default). Docker service names like `schema-file-server` have no TLD, so validation rejects them. Fix: `isURL(v, { require_tld: false })` in `/app/dist/apps/api-gateway/main.js`.
_Symptom if missing_: W3C schema creation or credential issuance returns `400 "@context must be an array of strings or objects, where the first item is the verifiable credential context URL"`.

**Patch 3 — Credo CredentialEvents.js crash in multi-tenancy root agent**
In multi-tenancy mode the root agent's `agent.modules.credentials` is undefined. The bare `getFormatData()` call throws `TypeError: Cannot read properties of undefined`, crashing the event handler. Every subsequent issuance attempt then gets ECONNREFUSED. Fix: wrap in `try { if (agent.modules && agent.modules.credentials) {...} } catch(e) {}` in `/app/build/events/CredentialEvents.js` inside the spawned Credo container.
_Symptom if missing_: Credential issuance returns `500 "Rpc Exception - connect ECONNREFUSED VPS_IP:8012"`.

**Patch 4 — Issuance service schema URL deduplication (getW3CSchemaAttributes)**
Studio's URL builder prepends `http://` to the `schemaLedgerId` even when it already starts with `http://`, producing `http://http://schema-file-server:4000/schemas/...`. CREDEBL's `getW3CSchemaAttributes` uses this URL to fetch the schema JSON — the double-prefixed URL 404s. Fix: insert a `while (schemaUrl.indexOf("://http") > 0)` stripping loop at the start of `getW3CSchemaAttributes` in `/app/dist/apps/issuance/main.js`. Uses string operations only — no regex literals (regex literals in string-concatenated bundles lose backslashes and produce `SyntaxError`).
_Symptom if missing_: Credential issuance returns `500 "Something went wrong!"` with agent-service log showing a 404 on the schema URL.

**Patch 6 — Agent-service shared wallet creation uses root JWT for create-tenant**
`_createTenantWallet` in agent-service sends Platform-admin's tenant JWT (RestTenantAgent) as `Authorization` when calling Credo's `/multi-tenancy/create-tenant`. Credo requires a root JWT (RestRootAgentWithTenants) for this — the tenant JWT is silently rejected (empty response), so `walletResponseDetails.id` is undefined, the code throws NotFoundException, and `org_agents` stays at `agentSpinUpStatus=1` with empty `tenantId`/`apiKey`. Every new org's shared wallet creation fails. Fix: call `POST {endpoint}/agent/token` with `AGENT_API_KEY` first to get a root JWT, then call `create-tenant` with `Authorization: Bearer {root_jwt}`. Patch string guard: `PATCH: create-tenant needs root JWT`.
_Symptom if missing_: Studio "Create Shared Wallet" appears to succeed (no error shown) but `org_agents.agentSpinUpStatus` stays at 1 with empty `tenantId`. All subsequent operations (Create DID, issue credential) return 404 `"API key is not found"`.

**Patch 7 — Credo ProofEvents.js crash in multi-tenancy root agent**
Two bugs in `ProofEvents.js` crash Credo when an OOB proof request is created. Bug A: `contextCorrelationId` starts with "tenant-" (it is a context correlation ID, not a bare tenant UUID) — `getTenantAgent({tenantId:"tenant-abc..."})` throws `"Tenant id already starts with 'tenant-'. You are probably passing a context correlation id"`. Bug B: `tenantAgent.proofs` is undefined in the multi-tenancy root agent context — `tenantAgent.proofs.getFormatData()` throws `TypeError: Cannot read properties of undefined`. Fix: strip "tenant-" prefix before `getTenantAgent`, then wrap `getFormatData` in a try-catch guard (same pattern as Patch 3). Applied to `/app/build/events/ProofEvents.js` inside the spawned Credo container. Guard string: `proofData try-catch guard`.
_Symptom if missing_: `POST /orgs/{id}/proofs/oob` → 500 "Something went wrong!" — Credo crashes and restarts on every proof request.

**Patch 8 — Agent-service normalizeUrlWithProtocol uses API_GATEWAY_PROTOCOL for Credo admin ports**
`agent-service.CommonService.normalizeUrlWithProtocol(baseUrl)` is called before every internal Credo API call (e.g. `getBaseAgentToken`, `getTenantWalletToken`). It prepends `process.env.API_GATEWAY_PROTOCOL` to any bare `host:port` value stored in `org_agents.agentEndPoint`. When SSL is enabled (`API_GATEWAY_PROTOCOL=https`), every Credo call uses `https://VPS:8002` — but Credo admin ports (8000-8099) only listen on plain HTTP, causing `EPROTO` or `ECONNREFUSED` on every provisioning attempt. Fix: replace `process.env.API_GATEWAY_PROTOCOL` with `process.env.AGENT_PROTOCOL || "http"`. `AGENT_PROTOCOL=http` is always set in `.env`; this is an internal Credo-facing call where HTTPS is never correct. Guard string: `PATCH8: normalizeUrlWithProtocol uses AGENT_PROTOCOL`.
_Symptom if missing_: When SSL is enabled, platform-admin shared agent provisioning fails in a crash-loop with `EPROTO` or `ECONNREFUSED` on `https://VPS:800X/agent/token`. `org_agents` stays empty. Health check reports `✗ platform-admin shared agent`.

**Patch 5 — Issuance service @context triple-prefix (outOfBandCredentialOffer)**
When Studio builds the OOB JSON-LD credential offer, it prepends `http://` to the schema URL again — now the `@context` array sent to Credo contains `"http://http://http://schema-file-server:4000/schemas/..."`. Credo rejects this with 400. Fix: insert a normalization loop after `this.logger.debug('Validated/Updated Issuance dates credential offer')` in `outOfBandCredentialOffer` that strips duplicate `://http` prefixes from every URL in `offer.credential['@context']`. Guard string: `ctx.map(function(url)`.
_Symptom if missing_: Credential issuance returns `500 "Something went wrong!"` or `500 "Cannot read properties of undefined (reading 'status')"` — Credo returns 400 which becomes an unhandled error in the issuance service.

**Patch 9 — Issuance service OOB credential not saved to DB (upsert + orgId fix)**
In Credo multi-tenancy, credential state-change events fire on each TENANT agent's EventEmitter, not the root agent's. `CredentialEvents.js` only listens to the root agent — it never receives the `offer-sent` event for tenant-issued credentials, never POSTs the webhook, and `saveIssuedCredentialDetails` is never called. The `credentials` table stays empty despite successful email delivery. Fix (PATCH9): change `updateSchemaIdByThreadId` from `prisma.credentials.update` (throws P2025 "Record to update not found") to `prisma.credentials.upsert`, accepting `orgId` as an optional third parameter. Fix (PATCH9B): `createdBy` and `lastChangedBy` are non-nullable `@db.Uuid` fields with no default — passing `undefined` (when `orgId` is absent) throws `PrismaClientValidationError` → uncaughtException → service crash → "no subscribers" loop. Fixed by using a fallback UUID `'00000000-0000-0000-0000-000000000000'`. Also: the OOB email call site (occurrence 2 — `credentialCreateOfferDetails.response.credentialRequestThId`) was not passing `orgId` as the third argument; now patched to pass it. Guard strings: `PATCH9: oob credential upsert` (fn signature), `PATCH9B: fallback UUID` (final state indicator).
_Symptom if missing_: Credential issuance succeeds (email arrives) but the credential list in Studio returns 500 "no subscribers" (from repeated issuance service crashes) and the `credentials` table stays empty.

**Patch 10 — Issuance service QR code attachment is corrupted binary**
The QR code is generated as a base64 data URL (`data:image/png;base64,...`) and split to extract the raw base64 string before attaching. Without `encoding: 'base64'` in the nodemailer attachment definition, nodemailer treats the string as UTF-8 text and MIME-encodes the literal base64 characters — recipients receive a text file containing "iVBORw0KGgo..." rather than a binary PNG image. Fix: add `encoding: 'base64'` so nodemailer decodes the base64 string back to binary before transfer. Also corrects `disposition: 'attachment'` to `contentDisposition: 'attachment'` (nodemailer's canonical field name). Guard string: `PATCH10: qr encoding`.
_Symptom if missing_: QR code email attachment appears to arrive (file is attached) but cannot be opened as an image — the file contains the raw base64 text, not PNG binary data.

### Platform-admin tenant wallet and DID creation (Patch — automated in init-credebl.sh)

**Root cause**: CREDEBL's Credo controller runs in multi-tenancy mode. The platform-admin org has `orgAgentType = DEDICATED` — its `agentEndPoint` points to the shared Credo container. For DEDICATED agents, `agent-service` decrypts `org_agents.apiKey` and uses it directly as the `Authorization` header for every Credo API call. In multi-tenant Credo, a `RestRootAgentWithTenants` JWT cannot perform DID operations — Credo rejects it with `"Basewallet can only manage tenants"`. Only a `RestTenantAgent` JWT (scoped to a specific tenant ID) can write DIDs and issue credentials.

On a fresh CREDEBL deployment, `org_agents.tenantId` is NULL and `org_agents.apiKey` is empty for the Platform-admin org, because `agent-service` provisions the root Credo container but never creates a tenant inside it for Platform-admin itself. Studio's "Create DID" button hits `POST /orgs/{id}/agents/did` → 500 `"Unauthorized"`.

**Fix (automated)**: `ensure_platform_admin_tenant()` in `init-credebl.sh` runs after `ensure_platform_admin_shared_agent` and does the following:
1. Gets a root JWT: `POST {agentEndPoint}/agent/token` with `Authorization: {AGENT_API_KEY}` → response field is `"token"` (NOT `"access_token"`)
2. Creates a tenant: `POST {agentEndPoint}/multi-tenancy/create-tenant` with `{"config":{"label":"Platform-admin"}}` — no `jwt` field (it's excess and rejected). Response `"id"` field is the `tenantId`.
3. Gets a fresh tenant JWT: `POST {agentEndPoint}/multi-tenancy/get-token/{tenantId}` → response field is also `"token"`
4. Encrypts the tenant JWT: `CryptoJS.AES.encrypt(JSON.stringify(token), CRYPTO_PRIVATE_KEY)` — the inner `JSON.stringify` is required because CREDEBL's `decryptPassword` calls `JSON.parse` on the decrypted bytes
5. Stores `tenantId` and encrypted JWT in `org_agents` and restarts `agent-service`

**Credo JWT lifetime caveat**: The tenant JWT is signed with a random `secretKey` generated when the Credo container starts and stored in Askar wallet. It has no `exp` claim. If the Credo container is ever restarted, the `secretKey` regenerates and the stored JWT becomes invalid. Recovery: re-run `ensure_platform_admin_tenant` manually (or re-run `init-credebl.sh`). The function is idempotent — it skips tenant creation if `tenantId` already exists in DB, but always refreshes the JWT.

**Why `patch_credo_credential_events` only restarts Credo when actually patched**: The patch script prints `"patched"` or `"already patched"`. The bash function reads this result and only calls `docker restart` when the value is `"patched"`. Restarting Credo when already patched would regenerate the secretKey for no reason, immediately invalidating the JWT just stored by `ensure_platform_admin_tenant`. On re-runs of `init-credebl.sh`, the patch is a no-op so the restart is skipped.

**Credo startup timing**: `patch_credo_credential_events` restarts Credo with no built-in wait. `ensure_platform_admin_tenant` runs immediately after and needs to call `/agent/token`. Credo takes ~15s to start, so `ensure_platform_admin_tenant` retries the `/agent/token` call up to 8 times with 5s delays (40s total) before giving up.

**Symptoms when this is broken**:
- `POST /orgs/{id}/agents/did` → 500 `"Unauthorized"` (agent-service log: `"Basewallet can only manage tenants"`)
- `POST /orgs/{id}/agents/did` → 500 `"Invalid Credentials"` (agent-service log: `"Agent api key details: Invalid Credentials"`) — means `apiKey` is empty or corrupt
- `POST /orgs/{id}/agents/did` → 404 `"API key is not found"` — means `org_agents.tenantId` is NULL or the tenant JWT is stale (Credo was restarted). Same fix: create/refresh tenant JWT.
- `POST /auth/signin` → 400 `"Invalid Credentials"` — unrelated but common trap: CREDEBL's API expects the password **CryptoJS AES-encrypted** (`CryptoJS.AES.encrypt(JSON.stringify(password), CRYPTO_PRIVATE_KEY)`). Studio encrypts automatically; raw passwords always fail the `/auth/signin` endpoint.

**Recovery for any org (not just Platform-admin)** whose wallet provisioning failed (`agentSpinUpStatus=1`, empty `tenantId`/`apiKey`): on fresh deployments this was caused by a bug in agent-service (Patch 6, now automated). On existing orgs that were created before the patch, or if Credo was restarting during wallet creation, manual fix:
1. `POST {agentEndPoint}/agent/token` → get root JWT
2. `POST {agentEndPoint}/multi-tenancy/create-tenant` with `{"config":{"label":"<org name>"}}` → get tenantId
3. `POST {agentEndPoint}/multi-tenancy/get-token/{tenantId}` → get tenant JWT
4. Encrypt JWT with CryptoJS: `CryptoJS.AES.encrypt(JSON.stringify(jwt), CRYPTO_PRIVATE_KEY)`
5. `UPDATE org_agents SET tenantId=..., apiKey=..., agentEndPoint=..., agentSpinUpStatus=2, orgAgentTypeId='bf4cde73-5dfa-4d36-a65f-1352b7385da4', walletName=... WHERE id=...`
   - SHARED agent type UUID: `bf4cde73-5dfa-4d36-a65f-1352b7385da4`
   - agentEndPoint = Platform-admin's Credo endpoint (e.g. `http://VPS:8002`)

### Why Studio is built locally (not pulled)
Studio is a Next.js app with `NEXT_PUBLIC_*` build args that bake the VPS IP, OIDC config, and secrets into the image at build time. There is no pre-built image on any registry. `init-credebl.sh` checks for an existing `credebl-studio` image and skips the ~5-8 minute Next.js build on re-deployments. Answer N to the skip prompt only if the VPS IP or secrets changed.

### Port allocation (no conflicts when running both stacks)
```
CREDEBL: 3000 (Studio), 5000 (API), 5432 (Postgres), 6379 (Redis), 8080 (Keycloak),
         9000/9011 (MinIO data/console), 4000 (Schema), 1025/8025 (Mailpit),
         8000-8099 (Credo admin ports), 9100+ (Credo inbound ports)
INJI:    3001 (Inji Web), 5433 (Postgres), 6380 (Redis), 8088 (eSignet),
         8090 (Certify internal), 8091 (Certify Nginx), 8099 (Mimoto), 1026/8026 (Mailpit)
```

### INJI services (10 total)

| Service | Image | Port | Role |
|---------|-------|------|------|
| postgres | postgres:14-alpine | 5433 | Shared DB — 4 schemas (mockidentitysystem, esignet, certify, mimoto) |
| redis | redis:7-alpine | 6380 | Cache for all Spring Boot services |
| mock-identity-system | mosipid/mock-identity-system:0.10.1 | 8082 | UIN/OTP identity provider — required by esignet-mock-plugin |
| esignet | mosipid/esignet-with-plugins:1.5.1 | 8088 | OIDC Authorization Server |
| inji-certify | mosipid/inji-certify-with-plugins:0.13.1 | 8090 | Credential issuance (OID4VCI) |
| certify-nginx | nginx:stable-alpine | 8091 | Reverse proxy — handles `.well-known` routing for OID4VCI |
| mimoto-config-server | nginx:stable-alpine | — | Serves `mimoto-issuers-config.json` and `mimoto-trusted-verifiers.json` via HTTP |
| mimoto | mosipid/mimoto:0.19.2 | 8099 | BFF for Inji Web — proxies to Certify |
| inji-web | mosipid/inji-web:0.14.1 | 3001 | Web-based holder wallet |
| mailpit | axllent/mailpit | 1026/8026 | SMTP capture (optional email flows) |

Startup order: postgres+redis → mock-identity-system → esignet → inji-certify → certify-nginx+mimoto-config-server → mimoto → inji-web+mailpit

**Why mock-identity-system is required**: eSignet uses the `esignet-mock-plugin.jar` for UIN/OTP authentication. The mock plugin calls mock-identity-system's API to validate UINs. Without it, eSignet startup fails.

**Why mimoto-config-server exists**: Mimoto's `IssuersServiceImpl` fetches `mimoto-issuers-config.json` via RestTemplate (HTTP only, no classpath). This Nginx serves the config files from `inji/config/mimoto/` so the config URL can be a local `http://mimoto-config-server/` instead of a remote GitHub URL.

**Why certify-nginx exists**: OID4VCI requires `.well-known/openid-credential-issuer` at the issuer's root URL. Certify's Spring Boot actuator is at `/actuator/health` (root context), but the app itself is at `/v1/certify`. The Nginx proxy handles this routing transparently.

### INJI startup fixes (validated April 23, 2026 — all required for a working stack)

These fixes were discovered during VPS validation and are all codified in the committed config files. They must be re-applied if postgres data is wiped and the stack is re-deployed from scratch.

**Fix 1 — Mimoto keystore must be on a writable volume**
`mosip.kernel.keymanager.hsm.config-path` in `application-default.properties` must point to a writable path, NOT to `/certs/oidckeystore.p12` (which is mounted `:ro`). The keymanager creates its own PKCS12 file on first start. Correct path: `/home/mosip/encryption/mimoto-keystore.p12` backed by Docker named volume `mimoto_keystore`.
_Symptom if wrong_: `KeystoreProcessingException: /certs/oidckeystore.p12 (Read-only file system)` — mimoto crash-loops on startup.

**Fix 2 — `key_alias.uni_ident` must be varchar(512) in all schemas**
MOSIP's key manager stores a UUID-derived unique identifier in `key_alias.uni_ident`. Hibernate's entity maps it as 32 chars; the actual values can exceed 128. The column must be created with `varchar(512)` BEFORE the service starts, or Hibernate `ddl-auto=update` creates it at 32 and the first key alias insert fails. All three schemas (`mockidentitysystem`, `esignet`, `mimoto`) have DDL in `postgres-init.sql` with `varchar(512)`.
_Symptom if wrong_: `DataIntegrityViolationException: value too long for type character varying(32)` — service crashes on first key generation.

**Fix 3 — mimoto health check: use wget, accept 401**
The mimoto container (Alpine) has no `curl`. Health check uses `wget -qSO /dev/null ... 2>&1 | grep -qE 'HTTP.*[24][0-9][0-9]'`. The actuator health endpoint returns 401 (Spring Security activates when `spring.security.oauth2.client.registration.*` properties are present) — 401 is normal and means the service is running.

**Fix 4 — inji-web nginx upstream is hardcoded as `mimoto-service`**
The inji-web Docker image's nginx config has `upstream mimoto-service {...}` hardcoded. Docker DNS won't resolve this to the `inji-mimoto` container unless a network alias is set. Fix: add `aliases: [mimoto-service]` under `networks: inji-net:` in the mimoto service definition.
_Symptom if wrong_: `502 Bad Gateway` from inji-web; nginx log shows `upstream not found: mimoto-service`.

**Fix 5 — inji-web port mapping is 3001:3004**
The inji-web container's internal nginx listens on port 3004, not 3001. Port mapping must be `3001:3004`. Health check must use `127.0.0.1:3004` (Alpine `localhost` resolves to IPv6 `::1` which nginx doesn't listen on).

**Fix 6 — eSignet OIDC discovery URL is `/oidc/.well-known/openid-configuration`**
Despite `server.servlet.path=/v1/esignet`, eSignet's `DispatcherServlet` is mapped at `/`. The `OpenIdConnectController` uses `@RequestMapping("/oidc")`, so the full path is `http://esignet:8088/oidc/.well-known/openid-configuration` — NOT `/v1/esignet/oidc/.well-known/...`.

**Fix 7 — Certify actuator is at root context, not under servlet path**
Spring Boot actuator does not move with the servlet path. Certify's actuator is at `http://inji-certify:8090/actuator/health`, not at `http://inji-certify:8090/v1/certify/actuator/health`. The nginx `/health` location must proxy to the root context path.

**Fix 8 — `key_policy_def` seed rows required in all three schemas**
`mockidentitysystem`, `esignet`, and `mimoto` all call `KeyManagerConfig.run()` or `AppConfig.run()` on startup, which queries `key_policy_def` for `ROOT` and service-specific entries. If those rows don't exist, the service crashes. All seed `INSERT ... ON CONFLICT DO NOTHING` statements are in `postgres-init.sql`.

---

## OIDC swap — Day 5 critical notes

### CREDEBL (simpler)
- Edit `.env`: replace `KEYCLOAK_PUBLIC_URL` + client credentials
- Restart: `docker compose restart api-gateway user organization`
- No schema or credential changes needed
- Docs: `credebl/docs/oidc-swap-procedure.md`

### INJI (more complex)
- Edit `config/certify/application.properties`: change issuer URI + JWKS URI
- Edit `config/mimoto/mimoto-issuers-config.json`: update authorization_server
- Critical: the `sub` claim in the country's token must match the DB identifier
- Restart: `docker compose restart inji-certify certify-nginx mimoto`
- Docs: `inji/docs/oidc-swap-procedure.md`

---

## Verification SDK comparison

| | CREDEBL SDK | INJI SDK |
|--|-------------|----------|
| **Protocol** | CREDEBL proprietary REST API | OID4VP |
| **Flow** | Server calls API → polls result | Server creates request → holder presents → server polls |
| **Auth needed** | Yes (JWT token from CREDEBL login) | No (verifier is public-facing) |
| **QR/deep link** | Optional (for mobile wallet) | Required (holder must scan to present) |
| **Node.js** | `credebl/sdk/sdk.js` | `inji/sdk/sdk.js` |
| **Python** | `credebl/sdk/sdk.py` | `inji/sdk/sdk.py` |

---

## Known gaps — what still needs to be done

### Before Colombia (May 4)
- [x] **`credebl-master-table.json`**: Built manually and included at `credebl/config/credebl-master-table.json`. Contains BCovrin Testnet + Indicio Testnet ledger configs and the minimum org_agents_type and client_config seed data. The `seed` service mounts it at `/app/libs/prisma-service/prisma/data/credebl-master-table.json`. Note: if CREDEBL's actual master table has additional fields or tables not reflected here, the seed service may log warnings but should not fail — Prisma's `upsert` pattern skips unknown fields.
- [x] **Validate CREDEBL stack on real VPS**: Full end-to-end validated on April 17, 2026. All 35 health checks pass on first run of `init-credebl.sh`. Stack uses ~3.6GB RAM. Agent provisioning works reliably with `WALLET_STORAGE_HOST=172.17.0.1`.
- [x] **Full E2E API flow validated**: April 18, 2026. `api-test.sh` passes all 8 steps: org creation → wallet provisioning (201) → DID did:key (201) → W3C JSON-LD schema (201) → OOB email credential issuance (201) → credential list (200). Five container patches are now automated in `init-credebl.sh` via `apply_container_patches()` and `patch_credo_credential_events()` — see critical notes below.
- [x] **Platform-admin tenant wallet setup automated**: April 19, 2026. `ensure_platform_admin_tenant()` added to `init-credebl.sh`. Creates a Credo multi-tenancy tenant for Platform-admin, stores the encrypted `RestTenantAgent` JWT in `org_agents.apiKey`, and sets `tenantId`. Fixes Studio "Create DID" → 500 "Unauthorized" on fresh deployments. See "Platform-admin tenant wallet and DID creation" in Infrastructure design decisions.
- [x] **Studio OOB JSON-LD credential issuance validated**: April 19, 2026. Required six patches total: (1) utility S3→MinIO, (2) api-gateway TLD validator, (3) Credo CredentialEvents crash guard, (4) issuance schema URL dedup, (5) issuance @context triple-prefix normalization, (6) agent-service shared wallet create-tenant root JWT. All automated in `init-credebl.sh`. Full flow validated: new org → shared wallet → DID → schema → OOB email issuance.
- [x] **OID4VCI + OID4VP full flow validated**: April 30, 2026. `api-test-oid4vc.sh` passes all 10/10 steps: org → wallet → did:key → no_ledger schema → OID4VCI issuer → credential template (dc+sd-jwt, signerOption DID) → credential offer (preAuthorizedCodeFlow, PIN) → OOB proof request (presentationExchange, 201). `ensure_oid4vc_employment_issuer()` in `init-credebl.sh` provisions all of this on fresh deploy. Key fixes: `CreateCredentialTemplateDto` requires `template: {vct, attributes[]}` (not flat), `signerOption: "DID"` is required, all proof endpoints need `/v1/` prefix. SD-JWT issuance via `credentialType=sdjwt` (PR #1279) was NOT needed — the OID4VCI flow uses the `oid4vc-issuance` service, not the legacy issuance service.
- [x] **Validate INJI stack on real VPS**: April 23, 2026. All 15 health checks pass (10 services + 5 endpoints). See "INJI services" and "INJI startup fixes" sections for full details. Mock OID4VCI flow available at port 3001 with UIN `5860356276` / OTP `111111`.
- [ ] **Colombia use case**: Once confirmed, adapt the relevant schema template and update `certify-employment.properties` with the correct credential type and `vct` URL.
- [ ] **INJI credential configs for education, professional-license, civil-identity**: `certify-employment.properties` exists but the other 3 schema configs for INJI are not yet created. Use `certify-employment.properties` as template.

### Post-Colombia
- [ ] National scale-up roadmap template (for Day 6 presentation)
- [ ] Dynamic Technical Scope template (post-mission reference)
- [ ] BC1 + BC2 pre-mission checklists
- [ ] INJI schema configs for education, professional-license, civil-identity

---

## VPS specs and constraints

- **OS**: Ubuntu 22.04 or 24.04 LTS
- **CPU**: 4 cores
- **RAM**: 8GB
- **Disk**: 150GB
- **Architecture**: AMD64 (x86_64) — INJI images have no ARM64 build
- **Swap**: 4GB configured by `setup-vps.sh` to handle memory pressure
- **Docker log rotation**: 10MB max, 3 files — configured in `setup-vps.sh`

Running both stacks simultaneously uses ~8GB RAM total. Recommended: run one at a time during the mission (select DPG on Day 3 and deploy only that one).

---

## Operational model document

A full Word document (`CDPI_Bootcamp_Model_v02.docx`) covers the complete 6-day mission framework including:
- Mission overview + day-by-day structure
- Counterpart profiles (who the country must bring)
- Pre-mission checklist (blockers vs. prerequisites)
- Day-by-day agenda with sessions, outputs, and go/no-go gates
- Fallback options for failed gates

This document was produced separately and is not in this repository. Ask Ysaias for the latest version.

---

## How to work on this project

### To add a new credential schema
1. Copy `credebl/schemas/employment.json` as template
2. Update all 5 sections: `schema`, `vct_type_metadata`, `disclosure_frame`, `sample_credential_data`, `credebl_api_payload`
3. Create the corresponding INJI config: copy `inji/config/certify/certify-employment.properties`, update credential type and vct URL
4. Add sample data rows to `inji/config/certify/data/employment-sample.csv`

### To add a new DPG
Create a new top-level folder (`walt-id/`, `quarkid/`, etc.) mirroring the structure of `credebl/` or `inji/`. Minimum contents: `docker-compose.yml`, `.env.example`, `docs/deployment-manual.md`, `docs/oidc-swap-procedure.md`.

### To update for a specific country
1. In `credebl/.env.example`: update field name notes to match country terminology (RNC → NIT for Colombia, etc.)
2. In schemas: adapt `document_number` label and `vct` URL to country domain
3. In `inji/config/mimoto/mimoto-issuers-config.json`: update `credential_issuer` URL
4. In test flows: update sample UINs/document numbers with country-specific values

### To extend the SDK
Both SDKs (CREDEBL and INJI) have no external dependencies by design — Node.js uses `http`/`https`, Python uses `urllib`. This keeps them deployable in environments without internet access. Keep this constraint.

---

## Glossary (for context in this project)

| Term | Meaning |
|------|---------|
| **BC3/BC4/BC5** | Internal CDPI names for bootcamp phases — in practice all happen in the single 6-day mission |
| **Country Champion** | The senior government representative who has decision authority during the mission |
| **DPG** | Digital Public Good — open-source DPI building blocks (CREDEBL, INJI, walt.id, QuarkID) |
| **Dynamic Technical Scope** | Document produced on Day 5 listing what was built, mocked, and what remains for post-mission |
| **OID4VCI** | OpenID for Verifiable Credential Issuance — the protocol wallets use to receive credentials |
| **OID4VP** | OpenID for Verifiable Presentations — the protocol verifiers use to request credentials |
| **SD-JWT VC** | Selective Disclosure JWT Verifiable Credential — the primary credential format in this project |
| **vct** | Verifiable Credential Type — the URI identifier for an SD-JWT VC schema |
| **eSignet** | MOSIP's OIDC-compliant authorization server — INJI's native auth layer |
| **Mimoto** | INJI's Backend-for-Frontend — sits between Inji Web and Certify |
| **SoftHSM** | Software-based PKCS11 HSM — handles key management for INJI Certify |
| **OIDC swap** | Day 5 operation: replacing the mock auth server (Keycloak/eSignet) with the country's real OIDC |
| **Disclosure frame** | Configuration specifying which credential fields are selectively disclosable |
| **BCovrin** | Public Hyperledger Indy test network used by CREDEBL for the PoC ledger |
