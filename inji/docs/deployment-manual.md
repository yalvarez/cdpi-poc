# INJI Stack Deployment Manual
## CDPI PoC — Country Team Guide

**Stack**: Inji Certify + eSignet + Mimoto + Inji Web  
**Credential format**: SD-JWT VC (OID4VCI draft 13) + W3C VCDM  
**Wallet**: Inji Web (browser-based) + Inji Mobile (app)

---

## Architecture overview

```
[Holder — Inji Web :3001]
         ↓ OID4VCI
[Mimoto BFF :8099]
         ↓
[eSignet OIDC :8088] ←→ [Inji Certify :8090] ←→ [PostgreSQL :5433]
                              ↓
                    [Certify Nginx :8091]  ← well-known routing
```

**Key difference from CREDEBL**: INJI's credential issuance is tied to an OIDC authentication flow. The holder authenticates via eSignet (or country OIDC on Day 5), and the token's `sub` claim is used to look up their data.

---

## Prerequisites

- Ubuntu 22.04/24.04 VPS, 4 CPU, 8GB RAM
- Docker Engine installed (`sudo bash scripts/setup-vps.sh`)
- `openssl` available (for keystore generation)

---

## First-time deployment

### 1. Generate keystore

```bash
cd /opt/cdpi-poc
export CERTIFY_KEYSTORE_PASSWORD=$(openssl rand -hex 16)
echo "Save this password: $CERTIFY_KEYSTORE_PASSWORD"
bash scripts/generate-inji-certs.sh
```

### 2. Configure environment

```bash
cd inji
cp .env.example .env
nano .env   # fill REQUIRED values
```

Update `YOUR_VPS_IP` throughout:
```bash
VPS_IP=$(curl -s ifconfig.me)
sed -i "s/YOUR_VPS_IP/$VPS_IP/g" .env
sed -i "s/YOUR_VPS_IP/$VPS_IP/g" config/mimoto/mimoto-issuers-config.json
sed -i "s/YOUR_VPS_IP/$VPS_IP/g" config/mimoto/mimoto-trusted-verifiers.json
echo "Updated config with VPS IP: $VPS_IP"
```

### 3. Pull images (do before mission to save time)

```bash
# NOTE: inji-certify is AMD64 only
export DOCKER_DEFAULT_PLATFORM=linux/amd64
docker compose pull
```

### 4. Start in order

```bash
# Infrastructure first
docker compose up -d postgres redis
sleep 20

# Auth server
docker compose up -d esignet
echo "Waiting for eSignet (90s)..."
sleep 90

# Certify + nginx
docker compose up -d inji-certify certify-nginx
echo "Waiting for Certify (120s)..."
sleep 120

# BFF + wallet
docker compose up -d mimoto inji-web mailpit
```

### 5. Verify

```bash
bash ../scripts/health-check-inji.sh
```

---

## Access points

| Service | URL | Notes |
|---------|-----|-------|
| Inji Web (wallet) | `http://VPS_IP:3001` | Holder interface |
| Certify API | `http://VPS_IP:8091/v1/certify` | OID4VCI issuer |
| Certify well-known | `http://VPS_IP:8091/.well-known/openid-credential-issuer` | Issuer metadata |
| eSignet OIDC | `http://VPS_IP:8088/v1/esignet` | Authorization Server |
| eSignet well-known | `http://VPS_IP:8088/v1/esignet/.well-known/openid-configuration` | OIDC discovery |
| Mimoto BFF | `http://VPS_IP:8099/residentmobileapp` | Wallet backend |
| Mailpit (email) | `http://VPS_IP:8026` | Email capture |

---

## Testing credential issuance

### Option A — Inji Web (browser wallet)

1. Open `http://VPS_IP:3001`
2. Select issuer "CDPI PoC Issuer"
3. Choose credential type (e.g. Employment Certification)
4. Authenticate with mock credentials:
   - UIN: `5860356276` or `2154189532`
   - OTP: `111111` (mock OTP)
5. Accept the credential — it downloads to the browser wallet

### Option B — API (for backend testing)

```bash
# 1. Get eSignet authorization URL
curl -s "http://VPS_IP:8088/v1/esignet/.well-known/openid-configuration" | jq .authorization_endpoint

# 2. Follow OID4VCI pre-authorized code flow
# See docs/test-flows.md for complete curl sequence
```

---

## Switching credential profiles

The `CERTIFY_PROFILE` in `.env` controls which credential plugin is active:

```bash
# Default: mock CSV (no DB needed)
CERTIFY_PROFILE=default

# PostgreSQL DataProvider (real DB)
CERTIFY_PROFILE=postgres-local
```

After changing the profile, restart Certify:
```bash
docker compose restart inji-certify certify-nginx
```

---

## Troubleshooting

### Certify fails to start
```bash
docker compose logs inji-certify | tail -50
# Common: database not ready → wait longer and retry
# Common: keystore not found → run generate-inji-certs.sh
```

### eSignet fails to start
```bash
docker compose logs esignet | tail -50
# Common: postgres schema not created → check postgres-init.sql ran
```

### Mimoto can't reach Certify
```bash
docker compose exec mimoto curl http://inji-certify:8090/v1/certify/actuator/health
# Should return {"status":"UP"}
```

### Credential issuance returns empty fields
The mock CSV data uses specific UINs. Only these work with the mock:
- `5860356276`, `2154189532`, `1234567890`, `0987654321`, `1122334455`

### ARM64 / Apple Silicon
```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64
docker compose up -d
```
