# INJI OIDC Swap Procedure — Day 5
## Replacing eSignet with the country's real Authorization Server

**Owner**: Backend engineer (country) + CDPI  
**When**: Day 5, after real database connection is confirmed  
**Time estimate**: 60–120 minutes  
**Risk**: Medium-High — eSignet and the country's OIDC may have different token claim structures

---

## Key difference vs. CREDEBL swap

In CREDEBL, swapping OIDC only affects the API authentication.  
In INJI, eSignet is deeply integrated into the Certify credential issuance flow — the access token from eSignet carries the subject identifier (`sub`) that maps to the data record. When you swap eSignet for the country's real OIDC, you must also confirm that the `sub` claim in the real OIDC token matches the identifier in the country's database.

---

## Before you start

- [ ] Country's OIDC issuer URL confirmed and reachable from the VPS
- [ ] Access token from the country's OIDC contains a `sub` claim
- [ ] `sub` claim value matches the identifier used in the country's database
- [ ] Country has registered a redirect URI: `http://VPS_IP:3001/home`
- [ ] Country has provided client ID and client secret
- [ ] Country backend engineer present

---

## Step 1 — Verify the country's OIDC is reachable

```bash
OIDC_ISSUER="https://oidc.country.gov/realms/production"

curl -s "$OIDC_ISSUER/.well-known/openid-configuration" | jq '{
  issuer,
  authorization_endpoint,
  token_endpoint,
  jwks_uri
}'
```

---

## Step 2 — Test token flow manually

```bash
# Get an authorization code (manual step — open in browser):
# https://oidc.country.gov/realms/production/protocol/openid-connect/auth
#   ?client_id=inji-certify-poc
#   &response_type=code
#   &scope=openid+EmploymentCertification
#   &redirect_uri=http://VPS_IP:3001/home

# Exchange code for token:
curl -s -X POST "https://oidc.country.gov/realms/production/protocol/openid-connect/token" \
  -d "grant_type=authorization_code" \
  -d "code=AUTH_CODE_FROM_BROWSER" \
  -d "client_id=inji-certify-poc" \
  -d "client_secret=CLIENT_SECRET" \
  -d "redirect_uri=http://VPS_IP:3001/home" \
  | jq '{access_token, id_token}' \
  | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
token = data.get('access_token', '')
if token:
    parts = token.split('.')
    if len(parts) >= 2:
        payload = parts[1] + '=='
        decoded = base64.urlsafe_b64decode(payload)
        print('Token claims:', json.dumps(json.loads(decoded), indent=2))
"
```

**Critical check**: the `sub` claim in the decoded token must match a record identifier in the country's database. If it doesn't, the data query will return no results.

---

## Step 3 — Back up current config

```bash
cd /opt/cdpi-poc/inji
cp .env .env.backup-$(date +%Y%m%d-%H%M%S)
cp config/certify/certify-employment.properties config/certify/certify-employment.properties.bak
```

---

## Step 4 — Update Certify to point to country OIDC

Edit `config/certify/application.properties`:

```bash
nano config/certify/application.properties
```

Change:
```properties
# FROM (eSignet mock):
mosip.certify.authn.issuer-uri=http://esignet:8088/v1/esignet
mosip.certify.authn.jwk-set-uri=http://esignet:8088/v1/esignet/oauth/.well-known/jwks.json
mosip.certify.authorization-servers={'http://esignet:8088/v1/esignet'}

# TO (country real OIDC):
mosip.certify.authn.issuer-uri=https://oidc.country.gov/realms/production
mosip.certify.authn.jwk-set-uri=https://oidc.country.gov/realms/production/protocol/openid-connect/certs
mosip.certify.authorization-servers={'https://oidc.country.gov/realms/production'}
```

---

## Step 5 — Update Mimoto to point to country OIDC

Edit `config/mimoto/mimoto-issuers-config.json`:

```json
{
  "issuers": [
    {
      "credential_issuer": "http://VPS_IP:8091/v1/certify",
      "authorization_server": "https://oidc.country.gov/realms/production",
      "client_id": "inji-certify-poc",
      "redirect_uri": "http://VPS_IP:3001/home"
    }
  ]
}
```

---

## Step 6 — Update .env

```bash
nano .env
```

Uncomment and fill:
```env
COUNTRY_OIDC_ISSUER_URL=https://oidc.country.gov/realms/production
COUNTRY_OIDC_CLIENT_ID=inji-certify-poc
COUNTRY_OIDC_CLIENT_SECRET=<provided-by-country>
```

---

## Step 7 — Restart affected services

```bash
docker compose restart inji-certify certify-nginx mimoto
```

Wait 60 seconds:
```bash
docker compose logs -f inji-certify | grep -E "(Started|ERROR|WARN)"
```

---

## Step 8 — Validate

```bash
# Check Certify well-known reflects new OIDC issuer
curl -s http://VPS_IP:8091/.well-known/openid-credential-issuer | jq '.authorization_servers'
# Should show the country's OIDC URL

# Check Certify health
curl -sf http://VPS_IP:8091/health | jq .status
```

Then test the full issuance flow via Inji Web at `http://VPS_IP:3001`.

---

## Rollback

```bash
cd /opt/cdpi-poc/inji
cp .env.backup-YYYYMMDD-HHMMSS .env
cp config/certify/application.properties.bak config/certify/application.properties
cp config/mimoto/mimoto-issuers-config.json.bak config/mimoto/mimoto-issuers-config.json
docker compose restart inji-certify certify-nginx mimoto
```

---

## Common issues

| Error | Cause | Fix |
|-------|-------|-----|
| `Invalid issuer` in Certify logs | OIDC issuer URL mismatch | Verify the exact issuer URL from `.well-known/openid-configuration` |
| `JWK set fetch failed` | Network issue or wrong JWKS URI | Check VPS can reach country OIDC from inside container: `docker compose exec inji-certify curl https://oidc.country.gov/...` |
| Credential issued but empty fields | `sub` claim doesn't match DB identifier | Align DB query to use the correct claim from the real token |
| `Invalid audience` | Certify's expected audience doesn't match token | Update `mosip.certify.authn.allowed-audiences` with the real audience value |
