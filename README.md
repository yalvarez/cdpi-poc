# CDPI PoC — Technical Artifacts Repository

This repository contains everything CDPI needs to deploy a working Proof of Concept for DPI/VC adoption with a government counterpart during a 6-day in-country mission.

## Repository structure

```
cdpi-poc/
├── credebl/                  ← CREDEBL stack (primary DPG)
│   ├── docker-compose.yml    ← Full self-contained stack
│   ├── .env.example          ← Environment variables template
│   ├── config/
│   │   ├── postgres-init.sql ← DB initialization
│   │   ├── keycloak-realm.json ← OIDC realm configuration
│   │   └── agent.env         ← Credo agent configuration
│   ├── schemas/              ← SD-JWT VC schema templates
│   │   ├── employment.json
│   │   ├── education.json
│   │   ├── professional-license.json
│   │   └── civil-identity.json
│   ├── sdk/                  ← Verification SDK
│   │   ├── README.md
│   │   └── examples/
│   └── docs/
│       ├── deployment-manual.md   ← Step-by-step deploy guide
│       ├── oidc-swap-procedure.md ← Day 5 real OIDC integration
│       └── test-flows.md          ← End-to-end test commands
├── scripts/
│   ├── setup-vps.sh          ← One-time VPS setup (Ubuntu)
│   └── health-check.sh       ← Post-deploy verification
└── README.md                 ← This file
```

## Quick start (CREDEBL)

```bash
# 1. Set up VPS (first time only)
sudo bash scripts/setup-vps.sh

# 2. Configure environment
cd credebl
cp .env.example .env
nano .env  # fill in all REQUIRED values

# 3. Pull images (do before mission to save time)
docker compose pull

# 4. Deploy
docker compose up -d

# 5. Verify
bash ../scripts/health-check.sh
```

## What is containerized (no external dependencies)

| External dependency | Replaced with | Port |
|--------------------|--------------|------|
| AWS S3 | MinIO (S3-compatible) | 9000, 9001 |
| SendGrid email | Mailpit (SMTP capture) | 1025, 8025 |
| Keycloak (OIDC) | Keycloak in Docker | 8080 |
| PostgreSQL | Postgres in Docker | 5432 |
| Redis | Redis in Docker | 6379 |
| NATS | NATS in Docker | 4222 |

## Mission day reference

| Day | What to do |
|-----|-----------|
| Before departure | `docker compose pull` on VPS, fill `.env`, run health check |
| Day 3 | `docker compose up -d`, run health check with country DevOps |
| Day 4 | Test issuance + verification flows (`docs/test-flows.md`) |
| Day 5 | Connect real DB, swap OIDC (`docs/oidc-swap-procedure.md`) |

## Credentials (fill in after deployment)

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| CREDEBL API | `:5000` | — | JWT token |
| Keycloak | `:8080` | from .env | from .env |
| MinIO | `:9001` | from .env | from .env |
| Mailpit | `:8025` | — | — |

## Status

- [x] CREDEBL Docker Compose (self-contained)
- [x] Environment variables template
- [x] OIDC swap procedure (Day 5)
- [x] Deployment manual
- [x] VPS setup script
- [x] Health check script
- [ ] Schema templates (SD-JWT VC) — in progress
- [ ] Verification SDK — in progress
- [ ] Test flows — in progress
- [ ] INJI stack — next
