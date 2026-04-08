# SD-JWT VC Schema Templates
## CDPI PoC — Country Adaptation Guide

---

## Overview

These 4 schema templates cover the most common government VC use cases in Latin America. Each schema file has the same structure:

```
schema_name.json
├── schema              → JSON Schema (field definitions + validation)
├── vct_type_metadata   → Wallet display metadata (labels, colors, languages)
├── disclosure_frame    → Which fields are selectively disclosable vs. always revealed
├── sample_credential_data → Test data for PoC build and testing
└── credebl_api_payload → Ready-to-use payload for CREDEBL's schema creation API
```

## Available templates

| File | Use case | Typical issuer | Key SD fields |
|------|----------|----------------|---------------|
| `employment.json` | Employment certification | Ministry of Labor / employer registry | salary, document number, contract type |
| `education.json` | Academic degree / diploma | Ministry of Education / university | grade, document number, program code |
| `professional-license.json` | Professional practice license | Licensing board / Colegio Profesional | sanctions, document number, internal codes |
| `civil-identity.json` | Identity attributes from civil registry | Civil registry / JCE / RENIEC | almost everything — most privacy-sensitive |

---

## How to use during the mission

### Day 1-2 — Country adapts the schema

The country's process owners review the template for their use case and adapt it:

1. Open the relevant `schema_name.json`
2. Review `schema.properties` — add or remove fields to match the country's data model
3. Review `disclosure_frame._sd` — confirm which fields should be selectively disclosable
4. Update `vct_type_metadata.display` with the correct institution name and language labels
5. Update `sample_credential_data` with realistic country-specific values

### Day 3 — Register the schema in CREDEBL

Use the `credebl_api_payload` block directly in the CREDEBL API:

```bash
# 1. Get an auth token
TOKEN=$(curl -s -X POST http://VPS_IP:5000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@cdpi-poc.local","password":"YOUR_PASSWORD"}' \
  | jq -r '.access_token')

# 2. Create the schema (example: employment)
curl -s -X POST http://VPS_IP:5000/schema/create \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "EmploymentCertification",
    "version": "1.0",
    "schemaType": "SD_JWT_VC",
    "vct": "https://schemas.cdpi-poc.local/employment/v1",
    "attributes": [
      "given_name", "family_name", "birthdate", "document_number",
      "employer_name", "employment_status", "position_title",
      "employment_start_date", "certificate_number"
    ]
  }' | jq .
```

Save the returned `schemaId` — you will need it for the credential definition.

---

## Selective disclosure — key concepts for the country team

### What it means

When a credential is issued with selective disclosure, the holder (the citizen's wallet) controls which fields they reveal to each verifier.

**Example — Employment credential presented to a bank for a loan:**
```
Revealed:  given_name, family_name, employer_name, employment_status, gross_salary
Hidden:    birthdate, document_number, department, employment_type
```

**Same credential presented to a new employer:**
```
Revealed:  given_name, family_name, employer_name, employment_status, position_title, employment_start_date
Hidden:    gross_salary, birthdate, department
```

The issuer signs all fields at once. The holder selectively reveals only what the verifier needs.

### Always-revealed vs. selectively disclosable

Each schema has two groups:

- **`_always_revealed`** — these fields are always visible in every presentation. Used for fields that don't have meaningful privacy sensitivity and are needed for basic verification.
- **`_sd` (selectively disclosable)** — the holder can choose to reveal or hide these per presentation.

### Adjusting for country context

Some fields may need to move between groups depending on the country's legal and cultural context:

- **Document number**: In some countries, revealing the national ID number is high risk (enables fraud). In others, it's already semi-public. Adjust accordingly.
- **Gender**: In many Latin American contexts, gender is sensitive. Consider making it SD even if it seems low-risk.
- **Salary**: Always SD — no exceptions.
- **Address**: Street-level address is always SD. Municipality/province may be always-revealed if needed for service routing.

---

## Adapting for a specific country use case

### Step 1 — Rename the vct URL

Replace `https://schemas.cdpi-poc.local/` with the country's actual schema registry URL:

```json
"vct": "https://schemas.ministerio.gob.XX/employment/v1"
```

For the PoC, keep `cdpi-poc.local` — it's a placeholder that works without DNS.

### Step 2 — Adjust field names to match country terminology

Countries use different terms for the same concept. Common adaptations:

| Template field | Colombia | Dominican Republic | Peru |
|----------------|----------|-------------------|------|
| `document_number` | Número de Cédula (CC) | Número de Cédula | DNI |
| `employer_id` | NIT | RNC | RUC |
| `tax_id` | NIT | RNC | RUC |

You can rename fields in the schema — just make sure the `credebl_api_payload.attributes` array reflects the renamed fields.

### Step 3 — Update sample data for testing

Replace the `sample_credential_data` values with realistic country-specific test data. This is what will be used during the Day 4 build to test the issuance flow.

---

## Schema versioning

Always include a version in the `vct` URL and the `name` field:

```
https://schemas.cdpi-poc.local/employment/v1   ← v1 for PoC
https://schemas.cdpi-poc.local/employment/v2   ← v2 after pilot changes
```

CREDEBL tracks schemas by version. Creating a new version does not invalidate previously issued credentials.
