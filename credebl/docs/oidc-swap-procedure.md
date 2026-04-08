# OIDC Swap Procedure — Day 5
## Replacing the Keycloak mock with the country's real Authorization Server

**Owner**: Backend engineer (country) + CDPI  
**When**: Day 5 of the mission, after real database connection is confirmed  
**Time estimate**: 45–90 minutes  
**Risk**: Medium — if the swap fails, the PoC falls back to Keycloak mock

---

## Before you start

Confirm these are ready before touching anything:

- [ ] Country's OIDC issuer URL confirmed and reachable from the VPS
- [ ] Client ID provided by the country's authorization server team
- [ ] Client secret provided by the country's authorization server team
- [ ] Redirect URIs registered in the country's OIDC provider (add: `http://VPS_IP:5000/*`)
- [ ] Country backend engineer present and available

---

## Step 1 — Verify the country's OIDC endpoint is reachable

Run from the VPS:

```bash
# Replace with the actual country OIDC issuer URL
OIDC_ISSUER="https://oidc.country.gov/realms/production"

curl -s "${OIDC_ISSUER}/.well-known/openid-configuration" | jq .
```

You should see a JSON response with `issuer`, `authorization_endpoint`, `token_endpoint`.  
**If this fails — stop here.** Network access to the country's OIDC from the VPS is a prerequisite.

---

## Step 2 — Back up current .env

```bash
cd /opt/cdpi-poc/credebl
cp .env .env.backup-$(date +%Y%m%d-%H%M%S)
echo "Backup created"
```

---

## Step 3 — Update .env with real OIDC values

Edit the `.env` file and replace the Keycloak values with the country's real OIDC:

```bash
# Open with your preferred editor
nano .env
```

Change these values:

```env
# FROM (Keycloak mock):
KEYCLOAK_PUBLIC_URL=http://YOUR_VPS_IP:8080
KEYCLOAK_REALM=credebl-realm
KEYCLOAK_CLIENT_ID=credebl-client
KEYCLOAK_CLIENT_SECRET=<mock-secret>

# TO (country's real OIDC):
KEYCLOAK_PUBLIC_URL=https://oidc.country.gov/realms/production
KEYCLOAK_REALM=<country-realm-name>
KEYCLOAK_CLIENT_ID=<country-provided-client-id>
KEYCLOAK_CLIENT_SECRET=<country-provided-client-secret>
```

Also update the OIDC swap section at the bottom of `.env`:

```env
OIDC_ISSUER_URL=https://oidc.country.gov/realms/production
OIDC_CLIENT_ID=<country-provided-client-id>
OIDC_CLIENT_SECRET=<country-provided-client-secret>
```

---

## Step 4 — Restart only the affected services

You do NOT need to restart the full stack. Only the services that use OIDC need to restart:

```bash
cd /opt/cdpi-poc/credebl

docker compose restart api-gateway user organization
```

Wait 30 seconds, then check logs:

```bash
docker compose logs --tail=50 api-gateway
docker compose logs --tail=50 user
```

Look for errors containing `OIDC`, `unauthorized`, or `invalid_client`.

---

## Step 5 — Validate the swap

```bash
# Test token endpoint using the country's OIDC
curl -s -X POST \
  "${OIDC_ISSUER}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${KEYCLOAK_CLIENT_ID}" \
  -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" | jq .access_token
```

If you get a token (non-null string) — the swap is successful.

Then test the API gateway:

```bash
# Should return 200 with platform info
curl -s http://localhost:5000/health | jq .
```

---

## Step 6 — Run the issuance flow end-to-end

Follow the issuance test in `docs/test-flows.md` to confirm a credential can still be issued  
under the real OIDC authentication.

---

## Rollback procedure

If the swap fails and you need to restore the Keycloak mock immediately:

```bash
cd /opt/cdpi-poc/credebl

# Restore the backup
cp .env.backup-YYYYMMDD-HHMMSS .env

# Restart affected services
docker compose restart api-gateway user organization

echo "Rollback complete — back on Keycloak mock"
```

---

## Common issues

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `invalid_client` | Wrong client ID or secret | Verify credentials with country team |
| `Connection refused` | VPS cannot reach country OIDC | Check firewall / network from VPS |
| `Invalid redirect_uri` | Redirect not registered | Add `http://VPS_IP:5000/*` to allowed redirects in country OIDC |
| `SSL certificate error` | Country OIDC uses self-signed cert | Get the cert and add to trusted store, or use `KC_SSL_VERIFY=false` for PoC |
