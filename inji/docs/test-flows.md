# Test Flows — End-to-End
## CDPI PoC — INJI Stack (OID4VCI + eSignet)

**Purpose**: Validate the full INJI stack end-to-end  
**When to run**: Day 4 (mock data) and Day 5 (real integrations)  
**Prerequisites**: Stack healthy (`bash scripts/health-check-inji.sh`)

---

## Key difference from CREDEBL flows

INJI uses an OIDC authorization flow — the holder **authenticates first**, then receives the credential. There is no direct API issuance without user interaction. The flows below cover both:

- **API flow** — backend-to-backend for testing (pre-authorized code)
- **UI flow** — through Inji Web (for the Day 4 demo)

---

## Setup — environment variables

```bash
VPS_IP="YOUR_VPS_IP"
CERTIFY_BASE="http://$VPS_IP:8091"
ESIGNET_BASE="http://$VPS_IP:8088/v1/esignet"
MIMOTO_BASE="http://$VPS_IP:8099/residentmobileapp"
WALLET_BASE="http://$VPS_IP:3001"

# Mock test credentials (from employment-sample.csv)
TEST_UIN="5860356276"
TEST_OTP="111111"
```

---

## Flow 1 — Verify well-known endpoints are correct

```bash
echo "=== Certify issuer metadata ==="
curl -s "$CERTIFY_BASE/.well-known/openid-credential-issuer" | jq '{
  credential_issuer,
  authorization_servers,
  credential_endpoint,
  credential_configurations_supported: (.credential_configurations_supported | keys)
}'

echo ""
echo "=== eSignet OIDC discovery ==="
curl -s "$ESIGNET_BASE/.well-known/openid-configuration" | jq '{
  issuer,
  authorization_endpoint,
  token_endpoint,
  scopes_supported
}'
```

**Expected**: `credential_issuer` matches your VPS IP, scopes include `EmploymentCertification`.

---

## Flow 2 — UI flow (Inji Web — primary demo path)

This is the flow you will demonstrate on Day 4.

```
1. Open: http://VPS_IP:3001
2. Click "Get credentials" or select issuer "CDPI PoC Issuer"
3. Choose credential type: Employment Certification
4. Authentication screen appears (eSignet mock)
5. Enter UIN: 5860356276
6. Enter OTP: 111111  (mock OTP — always works)
7. Credential downloads to the browser wallet
8. View credential — verify all fields are correct
```

**What to check**:
- Credential type label shows "Employment Certification" (EN) or "Certificación de Empleo" (ES)
- Fields match the CSV row for UIN `5860356276`:
  - Name: María José García Pérez
  - Employer: Ministerio de Educación
  - Position: Técnico en Sistemas de Información
  - Status: active

---

## Flow 3 — API flow (pre-authorized code — for backend testing)

INJI Certify supports the OID4VCI pre-authorized code grant for automated testing.

```bash
# Step 1 — Get eSignet token via mock KBA authentication
TOKEN_RESPONSE=$(curl -s -X POST "$ESIGNET_BASE/oauth/v2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "client_id=inji-certify-client" \
  -d "code=MOCK_AUTH_CODE" \
  -d "redirect_uri=http://$VPS_IP:3001/home")

echo "Token response: $TOKEN_RESPONSE" | jq .

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')
echo "Access token: ${ACCESS_TOKEN:0:50}..."
```

> **Note**: The pre-authorized code flow requires eSignet to be configured with the mock authenticator. For the UI-based demo flow, use Flow 2 (Inji Web) instead.

---

## Flow 4 — Credential endpoint direct call

Once you have an access token from Flow 3:

```bash
# Request Employment Certification credential
CREDENTIAL_RESPONSE=$(curl -s -X POST \
  "$CERTIFY_BASE/v1/certify/issuance/credential" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "format": "vc+sd-jwt",
    "credential_definition": {
      "type": ["VerifiableCredential", "EmploymentCertification"]
    },
    "proof": {
      "proof_type": "jwt",
      "jwt": "HOLDER_KEY_PROOF_JWT"
    }
  }')

echo $CREDENTIAL_RESPONSE | jq .

# Extract the issued SD-JWT VC
CREDENTIAL=$(echo $CREDENTIAL_RESPONSE | jq -r '.credential')
echo ""
echo "Issued SD-JWT VC (first 100 chars):"
echo "${CREDENTIAL:0:100}..."
```

---

## Flow 5 — Verify a credential via Inji Verify

INJI's verification is done via the Inji Web interface or via the OID4VP API.

### Option A — Inji Web UI verification

```
1. Open: http://VPS_IP:3001
2. Click "Verify credential"
3. Upload or scan the credential QR code
4. Result shows: Verified / Not verified + disclosed attributes
```

### Option B — Direct verification API (OID4VP)

```bash
# Create a presentation request
PRESENTATION_REQUEST=$(curl -s -X POST \
  "$CERTIFY_BASE/v1/certify/vp/presentation-request" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "cdpi-poc-verifier",
    "redirect_uri": "http://'"$VPS_IP"':3001/verify",
    "response_type": "vp_token",
    "scope": "openid EmploymentCertification",
    "presentation_definition": {
      "id": "employment-check",
      "input_descriptors": [
        {
          "id": "employment",
          "name": "Employment Certification",
          "purpose": "Verify employment status",
          "constraints": {
            "limit_disclosure": "required",
            "fields": [
              { "path": ["$.given_name"] },
              { "path": ["$.family_name"] },
              { "path": ["$.employer_name"] },
              { "path": ["$.employment_status"] }
            ]
          }
        }
      ]
    }
  }')

PRESENTATION_URI=$(echo $PRESENTATION_REQUEST | jq -r '.request_uri // .presentation_uri')
echo "Share this with the holder's wallet:"
echo "$PRESENTATION_URI"
```

---

## Flow 6 — Credential revocation check

```bash
# Check credential status (if revocation is configured)
CREDENTIAL_ID="YOUR_CREDENTIAL_ID"

curl -s "$CERTIFY_BASE/v1/certify/credentials/status/$CREDENTIAL_ID" | jq .
```

---

## Day 5 — Validation checklist after real integrations

After connecting real DB and swapping eSignet for country OIDC:

- [ ] eSignet well-known reflects country OIDC issuer URL
- [ ] Certify well-known `authorization_servers` shows country OIDC URL
- [ ] Full UI flow works with real country OIDC (not mock UIN/OTP)
- [ ] Credential fields populated from real database — not mock CSV
- [ ] SD-JWT fields match the schema disclosure frame
- [ ] Selective disclosure works — holder can choose revealed fields
- [ ] Inji Web wallet displays credential correctly with right labels
- [ ] Mimoto BFF resolves issuer config correctly

---

## Switching from mock data to real database (Day 5)

```bash
# 1. Update CERTIFY_PROFILE in .env
nano inji/.env
# Change: CERTIFY_PROFILE=default
# To:     CERTIFY_PROFILE=postgres-local

# 2. Update DB connection in certify-employment.properties
nano inji/config/certify/certify-employment.properties
# Uncomment and fill the postgres-local datasource section

# 3. Restart Certify
cd inji
docker compose restart inji-certify certify-nginx
sleep 60

# 4. Check logs
docker compose logs --tail=50 inji-certify | grep -E "(Started|ERROR|datasource)"
```

---

## Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `credential_configurations_supported` is empty | Certify not loaded employment config | Check `certify-employment.properties` is mounted correctly |
| OTP `111111` not accepted | eSignet mock auth not active | Verify `SPRING_PROFILES_ACTIVE=default` in eSignet |
| Inji Web shows no issuers | Mimoto can't reach Certify | `docker compose exec mimoto curl http://inji-certify:8090/v1/certify/actuator/health` |
| Credential issued but fields empty | Subject ID (`sub`) doesn't match CSV/DB | Check mock UIN values or DB query field name |
| `invalid_proof` error | Holder key proof JWT is malformed | Use Inji Web which generates the proof automatically |
| ARM64 image error | No ARM build for inji-certify | `export DOCKER_DEFAULT_PLATFORM=linux/amd64` before all docker commands |
