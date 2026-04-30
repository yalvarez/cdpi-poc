# CREDEBL API Integration Reference

This document covers all API endpoints needed to integrate external systems with CREDEBL for SD-JWT VC issuance and verification. All endpoints require authentication unless noted.

**Base URL**: `https://<VPS_HOST>` (HTTP: `http://<VPS_HOST>:5000`)  
**API version prefix**: `/v1/`  
**Content-Type**: `application/json`

---

## Authentication

CREDEBL uses a non-standard password encryption scheme. The password sent to the API must be AES-encrypted, not plaintext.

### Encrypt password (shell)

```bash
ENC_PASSWORD="$(printf '%s' \
  "$(jq -Rn --arg p "YOUR_PLAINTEXT_PASSWORD" '$p')" \
  | openssl enc -aes-256-cbc -salt -base64 -A -md md5 \
  -pass "pass:YOUR_CRYPTO_PRIVATE_KEY")"
```

> `CRYPTO_PRIVATE_KEY` is the value from `credebl/.env`. Studio encrypts automatically; raw passwords always fail the API.

### Encrypt password (Node.js)

```js
const CryptoJS = require("crypto-js");
const enc = CryptoJS.AES.encrypt(
  JSON.stringify("YOUR_PLAINTEXT_PASSWORD"),
  "YOUR_CRYPTO_PRIVATE_KEY"
).toString();
```

### Encrypt password (Python)

```python
from Crypto.Cipher import AES
import base64, hashlib, os, json

def encrypt_password(password, key):
    salt = os.urandom(8)
    d = b""
    d_i = b""
    while len(d) < 48:
        d_i = hashlib.md5(d_i + key.encode() + salt).digest()
        d += d_i
    aes_key, aes_iv = d[:32], d[32:48]
    raw = json.dumps(password).encode()
    pad = 16 - len(raw) % 16
    raw += bytes([pad] * pad)
    enc = AES.new(aes_key, AES.MODE_CBC, aes_iv).encrypt(raw)
    return base64.b64encode(b"Salted__" + salt + enc).decode()
```

### POST /v1/auth/signin

Obtain a Bearer token.

```http
POST /v1/auth/signin
Content-Type: application/json

{
  "email":    "admin@example.com",
  "password": "<AES-encrypted password>"
}
```

**Response**:
```json
{
  "statusCode": 201,
  "message":    "User login successfully",
  "data": {
    "access_token":  "<JWT>",
    "token_type":    "bearer",
    "expires_in":    3600
  }
}
```

Use `data.access_token` as `Authorization: Bearer <token>` on all subsequent requests. Tokens expire after 1 hour.

---

## Organizations

### POST /v1/orgs — Create organization

```http
POST /v1/orgs
Authorization: Bearer <token>
Content-Type: application/json

{
  "name":        "Ministry of Labor",
  "description": "Official employment credential issuer",
  "website":     "https://mintrabajo.gov.co",
  "countryId":   null,
  "stateId":     null,
  "cityId":      null,
  "logo":        ""
}
```

**Response** (`data.id` is the `orgId` used in all subsequent org-scoped calls):
```json
{
  "statusCode": 201,
  "data": {
    "id":   "<org-uuid>",
    "name": "Ministry of Labor"
  }
}
```

### GET /v1/orgs — List organizations

```http
GET /v1/orgs?pageNumber=1&pageSize=10
Authorization: Bearer <token>
```

---

## Agent / Wallet

Each organization needs a shared wallet before it can issue credentials.

### POST /v1/orgs/{orgId}/agents/wallet — Provision shared wallet

```http
POST /v1/orgs/{orgId}/agents/wallet
Authorization: Bearer <token>
Content-Type: application/json

{
  "label":          "mintrabajo-wallet",
  "clientSocketId": ""
}
```

**Response**: HTTP 201 — wallet provisioning starts asynchronously.

Check `agentSpinUpStatus` in the database or poll the org detail endpoint until status is `2` (ready). Provisioning typically takes 20–60 seconds.

### POST /v1/orgs/{orgId}/agents/did — Create DID

Only `did:key` is supported for OID4VCI SD-JWT credential issuance.

```http
POST /v1/orgs/{orgId}/agents/did
Authorization: Bearer <token>
Content-Type: application/json

{
  "seed":          "3f8a1b2c4d5e6f7a8b9c0d1e2f3a4b5c",
  "keyType":       "ed25519",
  "method":        "key",
  "ledger":        "",
  "privatekey":    "",
  "network":       "",
  "domain":        "",
  "role":          "",
  "endorserDid":   "",
  "clientSocketId": "",
  "isPrimaryDid":  true
}
```

**Response**: HTTP 201 — DID registration starts asynchronously. The DID (`did:key:z6Mk...`) is available in `org_agents.orgDid` once complete.

---

## Schemas

Schemas define the structure of a credential. CREDEBL stores them in its internal schema file server (`no_ledger` type).

### POST /v1/orgs/{orgId}/schemas — Create SD-JWT VC schema

```http
POST /v1/orgs/{orgId}/schemas
Authorization: Bearer <token>
Content-Type: application/json

{
  "type": "json",
  "schemaPayload": {
    "schemaName":  "EmploymentCertification",
    "schemaType":  "no_ledger",
    "description": "Verifiable credential certifying an employment relationship",
    "orgId":       "<org-uuid>",
    "attributes": [
      {
        "attributeName": "given_name",
        "schemaDataType": "string",
        "displayName":    "Given Name",
        "isRequired":     true
      },
      {
        "attributeName": "family_name",
        "schemaDataType": "string",
        "displayName":    "Family Name",
        "isRequired":     true
      },
      {
        "attributeName": "employment_status",
        "schemaDataType": "string",
        "displayName":    "Employment Status",
        "isRequired":     true
      }
    ]
  }
}
```

**Response**:
```json
{
  "statusCode": 201,
  "data": {
    "id":              "<schema-db-uuid>",
    "schemaLedgerId":  "http://schema-file-server:4000/schemas/<hash>",
    "schemaName":      "EmploymentCertification"
  }
}
```

> Use `data.schemaLedgerId` (not `data.id`) as the `vct` value in credential templates. If `schemaLedgerId` is null, fall back to `data.id`.

### GET /v1/orgs/{orgId}/schemas — List schemas

```http
GET /v1/orgs/{orgId}/schemas?pageNumber=1&pageSize=10
Authorization: Bearer <token>
```

---

## OID4VCI Issuance

OID4VCI (OpenID for Verifiable Credential Issuance) requires HTTPS. The `credential_issuer` URL in the metadata must be an `https://` URL for wallet compatibility.

### POST /v1/orgs/{orgId}/oid4vc/issuers — Create OID4VCI issuer

The `issuerId` (also called `publicIssuerId`) becomes the slug in the well-known metadata URL: `https://<VPS_HOST>/oid4vci/<issuerId>/.well-known/openid-credential-issuer`

```http
POST /v1/orgs/{orgId}/oid4vc/issuers
Authorization: Bearer <token>
Content-Type: application/json

{
  "issuerId":                    "mintrabajo-employment",
  "credentialIssuerHost":        "https://<VPS_HOST>",
  "orgId":                       "<org-uuid>",
  "orgDid":                      "did:key:z6Mk...",
  "authorizationServerUrl":      "https://auth.<VPS_HOST>/realms/credebl-realm",
  "batchCredentialIssuanceSize": 1,
  "display": [
    { "name": "Ministry of Labor Issuer", "locale": "en" }
  ]
}
```

**Response**:
```json
{
  "statusCode": 201,
  "data": {
    "id":       "<issuer-db-uuid>",
    "issuerId": "mintrabajo-employment"
  }
}
```

### POST /v1/orgs/{orgId}/oid4vc/{issuerId}/template — Create credential template

Links a schema to an issuer and defines the SD-JWT format and attributes. `issuerId` here is the **database UUID** from the issuer creation response (not the slug).

```http
POST /v1/orgs/{orgId}/oid4vc/{issuerDbId}/template
Authorization: Bearer <token>
Content-Type: application/json

{
  "name":         "Employment Certification",
  "format":       "dc+sd-jwt",
  "signerOption": "DID",
  "canBeRevoked": false,
  "template": {
    "vct": "http://schema-file-server:4000/schemas/<hash>",
    "attributes": [
      { "key": "given_name",        "value_type": "string" },
      { "key": "family_name",       "value_type": "string" },
      { "key": "employment_status", "value_type": "string" },
      { "key": "position_title",    "value_type": "string" }
    ]
  }
}
```

> `signerOption` must be `"DID"` for `dc+sd-jwt` with `did:key`. Other values (`X509_P256`, `X509_ED25519`) are for certificate-based signing.

**Response**:
```json
{
  "statusCode": 201,
  "data": {
    "id": "<template-uuid>"
  }
}
```

### POST /v1/orgs/{orgId}/oid4vc/{issuerDbId}/credential-offer — Issue credential

Creates a pre-authorized code flow offer. The holder receives an `openid-credential-offer://` URL and a PIN via email.

```http
POST /v1/orgs/{orgId}/oid4vc/{issuerDbId}/credential-offer
Authorization: Bearer <token>
Content-Type: application/json

{
  "credentialData": [
    {
      "attributes": [
        { "name": "given_name",        "value": "María José" },
        { "name": "family_name",       "value": "García Pérez" },
        { "name": "employment_status", "value": "active" },
        { "name": "position_title",    "value": "Software Engineer" },
        { "name": "employer_name",     "value": "Ministry of Labor" }
      ]
    }
  ],
  "credentialType":       "sdjwt",
  "isReuseConnection":    false,
  "comment":              "Employment credential for María José García",
  "credentialFormat":     "dc+sd-jwt",
  "emailId":              "holder@example.com",
  "credentialTemplateId": "<template-uuid>",
  "issuanceDate":         null,
  "expirationDate":       null,
  "protocolType":         "openid",
  "flowType":             "preAuthorizedCodeFlow"
}
```

**Response**:
```json
{
  "statusCode": 201,
  "data": {
    "offerRequest": "openid-credential-offer://?credential_offer_uri=https%3A%2F%2F...",
    "userPin":      "123456"
  }
}
```

The holder opens the `offerRequest` URL in an OID4VCI-compatible wallet (e.g. Inji, Wallet.id) and enters the PIN to claim the credential.

### GET /v1/orgs/{orgId}/oid4vc/issuers — List issuers

```http
GET /v1/orgs/{orgId}/oid4vc/issuers?pageNumber=1&pageSize=10
Authorization: Bearer <token>
```

### GET /v1/orgs/{orgId}/oid4vc/{issuerDbId}/templates — List templates

```http
GET /v1/orgs/{orgId}/oid4vc/{issuerDbId}/templates
Authorization: Bearer <token>
```

---

## OID4VCI Well-Known Metadata

These endpoints are **public** (no authentication required). Wallets use them to discover issuer capabilities.

### GET /oid4vci/{issuerSlug}/.well-known/openid-credential-issuer

Returns the issuer metadata document.

```http
GET /oid4vci/mintrabajo-employment/.well-known/openid-credential-issuer
```

**Response** (OID4VCI Draft 13 format):
```json
{
  "credential_issuer": "https://<VPS_HOST>",
  "credential_endpoint": "https://<VPS_HOST>/oid4vci/mintrabajo-employment/credential",
  "credentials_supported": [...]
}
```

---

## OID4VP Verification

OID4VP (OpenID for Verifiable Presentations) allows a verifier to request credential presentation from a holder's wallet.

### POST /v1/orgs/{orgId}/proofs/oob — Create OOB proof request

Creates an out-of-band (OOB) proof request using `presentationExchange`. Returns a DIDComm invitation URL that the holder scans to present their credential.

```http
POST /v1/orgs/{orgId}/proofs/oob?requestType=presentationExchange
Authorization: Bearer <token>
Content-Type: application/json

{
  "proofRequestLabel": "Employment Verification",
  "comment":           "Verify employment status for service access",
  "type":              "presentationExchange",
  "requestedAttributes":  {},
  "requestedPredicates":  {},
  "connectionId":         null,
  "presentationDefinition": {
    "id": "employment-check",
    "input_descriptors": [
      {
        "id":      "employment-descriptor",
        "name":    "Employment Credential",
        "purpose": "Verify current employment status",
        "format":  { "vc+sd-jwt": { "alg": ["EdDSA"] } },
        "constraints": {
          "fields": [
            {
              "path":   ["$.vct"],
              "filter": {
                "type":  "string",
                "const": "http://schema-file-server:4000/schemas/<hash>"
              }
            },
            {
              "path": ["$.employment_status"]
            }
          ]
        }
      }
    ]
  }
}
```

**Response**:
```json
{
  "statusCode": 201,
  "data": {
    "presentationId":  "<proof-uuid>",
    "invitationUrl":   "https://<VPS_HOST>?d_m=eyJ...",
    "invitationsDid":  "did:peer:...",
    "message":         "Out of band proof request details"
  }
}
```

Display `invitationUrl` as a QR code or deep link for the holder to scan.

### GET /v1/orgs/{orgId}/proofs — List proof requests

```http
GET /v1/orgs/{orgId}/proofs?pageNumber=1&pageSize=10
Authorization: Bearer <token>
```

### GET /v1/orgs/{orgId}/proofs/{presentationId} — Get proof status

Poll this endpoint to check whether the holder has responded.

```http
GET /v1/orgs/{orgId}/proofs/{presentationId}
Authorization: Bearer <token>
```

**Response**:
```json
{
  "statusCode": 200,
  "data": {
    "state":            "done",
    "isVerified":       true,
    "presentationId":   "<proof-uuid>",
    "createDateTime":   "2026-04-30T12:00:00.000Z"
  }
}
```

`state` values: `request-sent` → `presentation-received` → `done` (verified) or `abandoned`.

---

## Credential List

### GET /v1/orgs/{orgId}/credentials — List issued credentials

```http
GET /v1/orgs/{orgId}/credentials?pageNumber=1&pageSize=10
Authorization: Bearer <token>
```

---

## Integration Patterns

### Pattern 1 — Issuance from a backend system

Trigger credential issuance from your application when a business event occurs (new employee registered, degree conferred, license approved):

```
1. Your system calls POST /v1/auth/signin  →  get token
2. Your system calls POST /v1/orgs/{orgId}/oid4vc/{issuerId}/credential-offer
   with the holder's email and credential data
3. CREDEBL emails the openid-credential-offer:// URL + PIN to the holder
4. Holder opens wallet → scans/taps offer → enters PIN → credential stored
```

The `orgId`, `issuerId`, and `templateId` are fixed per deployment — store them in your application config, not derived per-request.

### Pattern 2 — Verification gate

Protect a resource or service by requiring credential presentation:

```
1. User initiates action in your app
2. Your app calls POST /v1/orgs/{orgId}/proofs/oob  →  get invitationUrl
3. Your app shows invitationUrl as QR code
4. User scans with wallet → presents credential
5. Your app polls GET /v1/orgs/{orgId}/proofs/{presentationId}
   until state=done and isVerified=true
6. Your app grants access
```

### Pattern 3 — Bulk issuance

Issue credentials to a list of recipients (e.g., entire employee registry):

```bash
while IFS=, read -r given_name family_name email position; do
  curl -X POST "$BASE_URL/v1/orgs/$ORG_ID/oid4vc/$ISSUER_ID/credential-offer" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg gn "$given_name" --arg fn "$family_name" \
      --arg em "$email"      --arg pos "$position" \
      --arg tid "$TEMPLATE_ID" \
      '{
        credentialData: [{attributes: [
          {name:"given_name",     value:$gn},
          {name:"family_name",    value:$fn},
          {name:"position_title", value:$pos}
        ]}],
        credentialType: "sdjwt", credentialFormat: "dc+sd-jwt",
        emailId: $em, credentialTemplateId: $tid,
        protocolType: "openid", flowType: "preAuthorizedCodeFlow",
        isReuseConnection: false, issuanceDate: null, expirationDate: null
      }')"
done < employees.csv
```

---

## Error Reference

| HTTP | Message | Cause |
|------|---------|-------|
| 400 | Invalid Credentials | Password is plaintext — must be AES-encrypted |
| 400 | @context must be an array... | Schema URL has no TLD — requires `require_tld: false` patch |
| 401 | Unauthorized | Bearer token missing or expired |
| 404 | API key is not found | Org agent not provisioned or Credo restarted |
| 500 | Something went wrong | Agent not ready, schema URL double-prefixed, or Credo crash |
| 500 | Rpc Exception - connect ECONNREFUSED | Credo container not running or CredentialEvents crash |

---

## SDK

Pre-built verification SDKs with no external dependencies:

- **Node.js**: [`credebl/sdk/sdk.js`](../sdk/sdk.js)
- **Python**: [`credebl/sdk/sdk.py`](../sdk/sdk.py)

Both SDKs handle the verification polling loop and return a structured result with `isVerified`, `state`, and the presented credential claims.
