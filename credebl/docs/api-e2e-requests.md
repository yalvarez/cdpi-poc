# CREDEBL API E2E Requests (No Studio UI)

This document provides a request-only flow to test core CREDEBL operations end-to-end.
It is aligned with the current Studio API wrappers and payload builders in this repository.

## What This Covers

Two paths are documented here:

**Path A — W3C JSON-LD (DIDComm OOB)** — validated Apr 18, 2026  
1. Encrypt password locally (OpenSSL-compatible AES)
2. Sign in and obtain Bearer token
3. Create organization
4. Spin up shared wallet
5. Create DID (`did:key`)
6. Create W3C schema
7. Issue credential by email (`credentialType=jsonld`)

**Path B — SD-JWT VC (OID4VCI + OID4VP)** — see section below  
Steps 1-5 are identical. Steps 6-7 differ:
6. Create SD-JWT VC schema (`schemaType: no_ledger`)
7. Issue credential by email (`credentialType=sdjwt`) — produces `openid-credential-offer://` URL
8. Create OID4VP proof request (`POST /orgs/{id}/proofs/oob`)

> Full automated scripts:
> - `bash credebl/docs/api-test.sh` — Path A (W3C JSON-LD)
> - `bash credebl/docs/api-test-oid4vc.sh` — Path B (SD-JWT OID4VCI)

## Prerequisites

- CREDEBL stack is up and healthy
- `jq` installed
- Platform admin credentials available (`admin@cdpi-poc.local` + password)
- `SCHEMA_FILE_SERVER_URL` set with trailing `/schemas/`

## Variables

```bash
VPS_IP="YOUR_VPS_IP"
BASE_URL="http://$VPS_IP:5000"
ADMIN_EMAIL="admin@cdpi-poc.local"
ADMIN_PASSWORD="changeme"
CRYPTO_PRIVATE_KEY="cdpi-poc-crypto-key-change-me"
EMAIL_TO="holder@example.com"
```

## 1) Encrypt Password Locally (no Studio dependency)

```bash
# CREDEBL expects encrypted password in /v1/auth/signin
# This matches Studio's CryptoJS AES format (OpenSSL salted, MD5 key derivation).
ENC_PASSWORD=$(printf '%s' "$(jq -Rn --arg p "$ADMIN_PASSWORD" '$p')" \
  | openssl enc -aes-256-cbc -salt -base64 -A -md md5 -pass "pass:$CRYPTO_PRIVATE_KEY")
```

## 2) Sign In

```bash
SIGNIN=$(curl -s -X POST "$BASE_URL/v1/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENC_PASSWORD\"}")

TOKEN=$(echo "$SIGNIN" | jq -r '.data.access_token')
echo "$TOKEN" | cut -c1-40
```

## 3) Create Organization

```bash
ORG_PAYLOAD='{
  "name": "CDPI API Flow Org",
  "description": "Created from API requests",
  "website": "https://cdpi-poc.local",
  "countryId": null,
  "stateId": null,
  "cityId": null,
  "logo": ""
}'

ORG_RESPONSE=$(curl -s -X POST "$BASE_URL/orgs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$ORG_PAYLOAD")

ORG_ID=$(echo "$ORG_RESPONSE" | jq -r '.data.id // .id')
echo "$ORG_ID"
```

## 4) Spin Up Shared Wallet

```bash
curl -s -X POST "$BASE_URL/orgs/$ORG_ID/agents/wallet" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"label":"ApiFlowWallet","clientSocketId":""}' | jq .
```

## 5) Create DID (`did:key`)

```bash
curl -s -X POST "$BASE_URL/orgs/$ORG_ID/agents/did" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "seed":"",
    "keyType":"ed25519",
    "method":"key",
    "ledger":"",
    "privatekey":"",
    "network":"",
    "domain":"",
    "role":"",
    "endorserDid":"",
    "clientSocketId":"",
    "isPrimaryDid":true
  }' | jq .
```

Get org DID:

```bash
ORG_DID=$(curl -s "$BASE_URL/orgs/$ORG_ID" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.data.org_agents[0].orgDid')
echo "$ORG_DID"
```

## 6) Create W3C Schema

Use `schemaType=no_ledger` for `did:key`/`did:web`, or `polygon` for `did:polygon`.

```bash
SCHEMA_NAME="EmploymentApiFlow"

SCHEMA_PAYLOAD=$(jq -n --arg orgId "$ORG_ID" --arg schemaName "$SCHEMA_NAME" '{
  type:"json",
  schemaPayload:{
    schemaName:$schemaName,
    schemaType:"no_ledger",
    attributes:[
      {attributeName:"firstName", schemaDataType:"string", displayName:"First Name", isRequired:true},
      {attributeName:"lastName", schemaDataType:"string", displayName:"Last Name", isRequired:true},
      {attributeName:"employeeId", schemaDataType:"string", displayName:"Employee ID", isRequired:true}
    ],
    description:$schemaName,
    orgId:$orgId
  }
}')

SCHEMA_RESPONSE=$(curl -s -X POST "$BASE_URL/orgs/$ORG_ID/schemas" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$SCHEMA_PAYLOAD")

echo "$SCHEMA_RESPONSE" | jq .
SCHEMA_ID_RAW=$(echo "$SCHEMA_RESPONSE" | jq -r '.data.schemaLedgerId // .data.schemaId // .data.id')
```

## 7) Issue Email Credential (`jsonld`)

Normalize schema context URL (required by legacy JSON-LD issuance flow):

```bash
SCHEMA_BASE="${SCHEMA_FILE_SERVER_URL:-http://schema-file-server:4000/schemas/}"
SCHEMA_BASE="${SCHEMA_BASE%/}"
[[ "$SCHEMA_BASE" =~ /schemas$ ]] || SCHEMA_BASE="$SCHEMA_BASE/schemas"
SCHEMA_CONTEXT_URL="$SCHEMA_BASE/$SCHEMA_ID_RAW"

ISSUE_PAYLOAD=$(jq -n \
  --arg email "$EMAIL_TO" \
  --arg ctx1 "https://www.w3.org/2018/credentials/v1" \
  --arg ctx2 "$SCHEMA_CONTEXT_URL" \
  --arg schemaName "$SCHEMA_NAME" \
  --arg orgDid "$ORG_DID" '{
    credentialOffer:[{
      emailId:$email,
      credential:{
        "@context":[ $ctx1, $ctx2 ],
        type:["VerifiableCredential", $schemaName],
        issuer:{ id:$orgDid },
        issuanceDate:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        credentialSubject:{
          firstName:"Maria",
          lastName:"Garcia",
          employeeId:"EMP-001"
        }
      },
      options:{
        proofType:"Ed25519Signature2018",
        proofPurpose:"assertionMethod"
      }
    }],
    protocolVersion:"v2",
    isReuseConnection:true,
    credentialType:"jsonld"
  }')

curl -s -X POST "$BASE_URL/orgs/$ORG_ID/credentials/oob/email?credentialType=jsonld" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$ISSUE_PAYLOAD" | jq .
```

---

## Path B — SD-JWT VC (OID4VCI)

Steps 1-5 are identical to Path A. Only the schema creation and issuance differ.

### 6B) Create SD-JWT VC Schema

Use `schemaType: "no_ledger"` — same API, same endpoint, no blockchain required.

```bash
SDJWT_SCHEMA_NAME="EmploymentOID4VC"

SDJWT_SCHEMA_PAYLOAD=$(jq -n --arg orgId "$ORG_ID" --arg schemaName "$SDJWT_SCHEMA_NAME" '{
  type:"json",
  schemaPayload:{
    schemaName:$schemaName,
    schemaType:"no_ledger",
    attributes:[
      {attributeName:"given_name",          schemaDataType:"string", displayName:"Given Name",     isRequired:true},
      {attributeName:"family_name",         schemaDataType:"string", displayName:"Family Name",    isRequired:true},
      {attributeName:"document_number",     schemaDataType:"string", displayName:"Document Number",isRequired:false},
      {attributeName:"employer_name",       schemaDataType:"string", displayName:"Employer Name",  isRequired:true},
      {attributeName:"employment_status",   schemaDataType:"string", displayName:"Status",         isRequired:true},
      {attributeName:"position_title",      schemaDataType:"string", displayName:"Position",       isRequired:true},
      {attributeName:"employment_start_date",schemaDataType:"string",displayName:"Start Date",     isRequired:true}
    ],
    description:$schemaName,
    orgId:$orgId
  }
}')

SDJWT_SCHEMA_RESPONSE=$(curl -s -X POST "$BASE_URL/orgs/$ORG_ID/schemas" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$SDJWT_SCHEMA_PAYLOAD")

echo "$SDJWT_SCHEMA_RESPONSE" | jq .
SDJWT_SCHEMA_ID=$(echo "$SDJWT_SCHEMA_RESPONSE" | jq -r '.data.schemaLedgerId // .data.schemaId // .data.id')
echo "SD-JWT Schema ID: $SDJWT_SCHEMA_ID"
```

### 7B) Issue SD-JWT VC via OID4VCI OOB Email

Key differences from Path A:
- `?credentialType=sdjwt` instead of `jsonld`
- `attributes` flat array instead of W3C `@context`/`credential` wrapper
- `credentialDefinitionId` set to the schema ID (no ledger credential definition needed)
- Response contains `openid-credential-offer://` URL (not a MinIO URL)

```bash
SDJWT_ISSUE_PAYLOAD=$(jq -n \
  --arg email   "$EMAIL_TO" \
  --arg schemaId "$SDJWT_SCHEMA_ID" \
  '{
    credentialOffer:[{
      emailId:$email,
      attributes:[
        {name:"given_name",          value:"María José"},
        {name:"family_name",         value:"García Pérez"},
        {name:"document_number",     value:"001-1985031-4"},
        {name:"employer_name",       value:"Ministerio de Trabajo"},
        {name:"employment_status",   value:"active"},
        {name:"position_title",      value:"Técnico en Sistemas"},
        {name:"employment_start_date",value:"2018-06-01"}
      ]
    }],
    credentialDefinitionId:$schemaId,
    isReuseConnection:true
  }')

curl -s -X POST "$BASE_URL/orgs/$ORG_ID/credentials/oob/email?credentialType=sdjwt" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$SDJWT_ISSUE_PAYLOAD" | jq .
```

**Expected response** (201):
```json
{
  "statusCode": 201,
  "message": "Credential offer sent successfully",
  "data": {
    "id": "<issuance-uuid>",
    "credentialOffer": "openid-credential-offer://?credential_offer_uri=http://VPS:5000/..."
  }
}
```

### 8B) Create OID4VP Proof Request

```bash
PROOF_PAYLOAD=$(jq -n \
  --arg schemaId "$SDJWT_SCHEMA_ID" \
  '{
    comment:"Employment verification",
    proofReqPayload:{
      name:"employment-check",
      version:"1.0",
      requested_attributes:{
        attr_given_name:{name:"given_name",        restrictions:[{schema_id:$schemaId}]},
        attr_employer:  {name:"employer_name",     restrictions:[{schema_id:$schemaId}]},
        attr_status:    {name:"employment_status", restrictions:[{schema_id:$schemaId}]}
      },
      requested_predicates:{}
    }
  }')

PROOF_RESPONSE=$(curl -s -X POST "$BASE_URL/orgs/$ORG_ID/proofs/oob" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PROOF_PAYLOAD")

echo "$PROOF_RESPONSE" | jq .
PROOF_ID=$(echo "$PROOF_RESPONSE" | jq -r '.data.id')
PROOF_URL=$(echo "$PROOF_RESPONSE" | jq -r '.data.proofUrl // .data.invitationUrl')
echo "Proof URL (OID4VP): $PROOF_URL"
```

---

## One-command execution

A ready-to-run script is included at:

- `scripts/credebl-api-e2e.sh`

Run:

```bash
ADMIN_PASSWORD='changeme' bash scripts/credebl-api-e2e.sh YOUR_VPS_IP holder@example.com
```

For the OID4VC path:

```bash
ADMIN_PASSWORD='changeme' EMAIL_TO='holder@example.com' \
  bash credebl/docs/api-test-oid4vc.sh
```

## Postman Collection

You can run the same flow in Postman Collection Runner.

Files:

- `credebl/docs/postman/credebl-api-e2e.postman_collection.json`
- `credebl/docs/postman/credebl-api-e2e.postman_environment.json`

Steps:

1. Import both files into Postman.
2. Select environment `CREDEBL API E2E - CDPI`.
3. Set `base_url`, `admin_password`, and `crypto_private_key`.
4. Run requests in order from `01` to `08`.

The collection auto-captures and reuses:

- `enc_password`
- `access_token`
- `org_id`
- `org_did`
- `schema_id_raw`
- `schema_context_url`
