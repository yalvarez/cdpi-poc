# CLAUDE.md — Project Context & Memory
## CDPI PoC Technical Repository

**Last updated**: April 2026  
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
│   ├── health-check.sh            ← CREDEBL stack verification
│   ├── health-check-inji.sh       ← INJI stack verification
│   └── generate-inji-certs.sh     ← PKCS12 keystore for INJI (run once)
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
│       └── test-flows.md          ← Complete curl sequences for all flows
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
| **Images** | `ghcr.io/credebl/*` | `mosipid/inji-certify-with-plugins`, `mosipid/esignet`, `mosipid/mimoto`, `mosipid/inji-web` |
| **Architecture** | ~13 microservices + infra | 5 services + infra |
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

### Port allocation (no conflicts when running both stacks)
```
CREDEBL: 5000 (API), 5432 (Postgres), 6379 (Redis), 8080 (Keycloak), 9000/9001 (MinIO), 4000 (Schema), 1025/8025 (Mailpit)
INJI:    3001 (Inji Web), 5433 (Postgres), 6380 (Redis), 8088 (eSignet), 8090 (Certify internal), 8091 (Certify Nginx), 8099 (Mimoto), 1026/8026 (Mailpit)
```

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
- [ ] **Validate CREDEBL stack on real VPS**: `docker compose up -d` and confirm all 13 services reach healthy state. Known risk: `agent-provisioning` and `agent-service` startup is flaky and depends on a `docker logs` grep.
- [ ] **Validate INJI stack on real VPS**: Startup order matters. eSignet must be fully healthy before Certify starts (90s wait). Test the mock OID4VCI flow end-to-end with UIN `5860356276` / OTP `111111`.
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
