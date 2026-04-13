# CREDEBL API E2E Requests (No Studio UI)

This document provides a request-only flow to test core CREDEBL operations end-to-end.
It is aligned with the current Studio API wrappers and payload builders in this repository.

## What This Covers

1. Encrypt password via Studio API helper
2. Sign in and obtain Bearer token
3. Create organization
4. Spin up shared wallet
5. Create DID (`did:key`)
6. Create W3C schema
7. Issue credential by email (`credentialType=jsonld`)

## Prerequisites

- CREDEBL stack is up and healthy
- `jq` installed
- Platform admin credentials available (`admin@cdpi-poc.local` + password)
- `SCHEMA_FILE_SERVER_URL` set with trailing `/schemas/`

## Variables

```bash
VPS_IP="YOUR_VPS_IP"
BASE_URL="http://$VPS_IP:5000"
STUDIO_URL="http://$VPS_IP:3000"
ADMIN_EMAIL="admin@cdpi-poc.local"
ADMIN_PASSWORD="changeme"
EMAIL_TO="holder@example.com"
```

## 1) Encrypt Password (same mechanism Studio uses)

```bash
ENC_PASSWORD=$(curl -s -X POST "$STUDIO_URL/api/encrypt" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.data')
```

## 2) Sign In

```bash
SIGNIN=$(curl -s -X POST "$BASE_URL/auth/signin" \
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

## One-command execution

A ready-to-run script is included at:

- `scripts/credebl-api-e2e.sh`

Run:

```bash
ADMIN_PASSWORD='changeme' bash scripts/credebl-api-e2e.sh YOUR_VPS_IP holder@example.com
```

## Postman Collection

You can run the same flow in Postman Collection Runner.

Files:

- `credebl/docs/postman/credebl-api-e2e.postman_collection.json`
- `credebl/docs/postman/credebl-api-e2e.postman_environment.json`

Steps:

1. Import both files into Postman.
2. Select environment `CREDEBL API E2E - CDPI`.
3. Set `base_url`, `studio_url`, and `admin_password`.
4. Run requests in order from `01` to `09`.

The collection auto-captures and reuses:

- `enc_password`
- `access_token`
- `org_id`
- `org_did`
- `schema_id_raw`
- `schema_context_url`
