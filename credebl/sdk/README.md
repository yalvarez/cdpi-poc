# CDPI PoC — Verification SDK
## Integration Guide for Country Technical Teams

**Version**: 1.0  
**DPG**: CREDEBL  
**Credential format**: SD-JWT VC  
**Protocol**: OID4VP (OpenID for Verifiable Presentations)

---

## What this SDK does

This SDK gives your backend and frontend the tools to request and verify SD-JWT VC credentials issued through CREDEBL — without needing to understand the full OID4VP protocol internals.

There are two integration patterns:

| Pattern | When to use |
|---------|-------------|
| **Server-side verification** | Your backend verifies credentials directly via CREDEBL API |
| **Client-side presentation** | Your web frontend generates a QR code or deep link that triggers the holder's wallet |

---

## Prerequisites

- CREDEBL stack running and accessible (`http://VPS_IP:5000`)
- An organization registered in CREDEBL with an active agent
- A credential definition (cred def) created for your schema
- A valid API token (obtained via `/auth/login`)

---

## Quick start — 5 minutes to first verification

### 1. Install the helper library

```bash
# Node.js / TypeScript
npm install axios

# Python
pip install requests
```

### 2. Configure your connection

```javascript
// config.js
module.exports = {
  CREDEBL_API: process.env.CREDEBL_API_URL || 'http://VPS_IP:5000',
  ORG_ID: process.env.CREDEBL_ORG_ID,       // Your organization ID in CREDEBL
  API_TOKEN: process.env.CREDEBL_API_TOKEN,  // JWT token from /auth/login
};
```

### 3. Request a credential presentation

```javascript
const { CREDEBL_API, ORG_ID, API_TOKEN } = require('./config');
const axios = require('axios');

async function requestVerification(requestedAttributes) {
  const response = await axios.post(
    `${CREDEBL_API}/verification/send-verification-request`,
    {
      orgId: ORG_ID,
      requestedAttributes,
      comment: 'CDPI PoC Verification'
    },
    { headers: { Authorization: `Bearer ${API_TOKEN}` } }
  );
  return response.data; // Contains proofUrl and proofId
}

// Example: request employment status and name only
const result = await requestVerification([
  { attributeName: 'given_name',        schemaId: 'SCHEMA_ID', credDefId: 'CRED_DEF_ID' },
  { attributeName: 'family_name',       schemaId: 'SCHEMA_ID', credDefId: 'CRED_DEF_ID' },
  { attributeName: 'employer_name',     schemaId: 'SCHEMA_ID', credDefId: 'CRED_DEF_ID' },
  { attributeName: 'employment_status', schemaId: 'SCHEMA_ID', credDefId: 'CRED_DEF_ID' },
]);

console.log(result.proofUrl);  // Share this URL / QR with the holder's wallet
console.log(result.proofId);   // Use this to poll for the result
```

### 4. Poll for the verification result

```javascript
async function pollVerificationResult(proofId, maxAttempts = 20, intervalMs = 3000) {
  for (let i = 0; i < maxAttempts; i++) {
    const response = await axios.get(
      `${CREDEBL_API}/verification/proofs/${proofId}`,
      { headers: { Authorization: `Bearer ${API_TOKEN}` } }
    );

    const { state, isVerified, requestedAttributes } = response.data;

    if (state === 'done') {
      return { verified: isVerified, attributes: requestedAttributes };
    }

    if (state === 'abandoned') {
      return { verified: false, attributes: null, reason: 'abandoned' };
    }

    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }

  return { verified: false, attributes: null, reason: 'timeout' };
}

const result = await pollVerificationResult(proofId);
if (result.verified) {
  console.log('Verified attributes:', result.attributes);
} else {
  console.log('Verification failed:', result.reason);
}
```

---

## Full SDK reference

See `sdk.js` (Node.js) and `sdk.py` (Python) for the complete implementation.

---

## QR code generation for web frontend

The `proofUrl` returned by CREDEBL can be encoded as a QR code so the holder scans it with their wallet app (Inji, etc.).

```html
<!-- Include QRCode.js from CDN -->
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>

<div id="qrcode"></div>
<p id="status">Waiting for presentation...</p>

<script>
async function startVerification() {
  // 1. Call your backend to get the proofUrl
  const response = await fetch('/api/verify/start', { method: 'POST' });
  const { proofUrl, proofId } = await response.json();

  // 2. Render QR code
  new QRCode(document.getElementById('qrcode'), {
    text: proofUrl,
    width: 256,
    height: 256
  });

  // 3. Poll for result
  pollResult(proofId);
}

async function pollResult(proofId) {
  const interval = setInterval(async () => {
    const response = await fetch(`/api/verify/result/${proofId}`);
    const result = await response.json();

    if (result.state === 'done') {
      clearInterval(interval);
      document.getElementById('status').textContent =
        result.verified ? '✓ Verification successful' : '✗ Verification failed';
    }
  }, 3000);
}

startVerification();
</script>
```

---

## Verification states reference

| State | Meaning | Action |
|-------|---------|--------|
| `request-sent` | Proof request created, waiting for wallet | Show QR / deep link |
| `presentation-received` | Wallet sent the presentation | CREDEBL is verifying |
| `done` | Verification complete | Check `isVerified` |
| `abandoned` | Holder rejected or timed out | Show error to user |

---

## Error handling

| HTTP status | Meaning | Fix |
|-------------|---------|-----|
| `401` | Invalid or expired token | Re-authenticate via `/auth/login` |
| `404` | Organization or proof not found | Check `orgId` and `proofId` |
| `400` | Invalid request payload | Check attribute names match schema |
| `503` | CREDEBL agent not reachable | Check agent-service container logs |

---

## OIDC swap note (Day 5)

After swapping Keycloak for the real country OIDC on Day 5, no SDK code changes are needed. The OIDC swap only affects authentication to the CREDEBL API — the verification flow itself remains identical.

---

## Automation and best practices

- Use `scripts/init-credebl.sh` for fully automated environment setup (4 prompts, all secrets auto-generated)
- Always save the final credentials/secrets report securely
- For full E2E test flows, see `credebl/docs/test-flows.md` and `credebl/docs/api-e2e-requests.md`
