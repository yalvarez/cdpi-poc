# INJI Verification SDK
## CDPI PoC — OID4VP Integration Guide

**Protocol**: OID4VP (OpenID for Verifiable Presentations)  
**Credential format**: SD-JWT VC  
**Languages**: Node.js (`sdk.js`), Python (`sdk.py`) — no external dependencies

---

## Key difference from CREDEBL SDK

CREDEBL verification is server-to-server (the verifier calls an API to check a credential).  
INJI verification is holder-initiated — the flow is:

```
Verifier creates request → shows QR to holder → holder presents from wallet → verifier checks result
```

This matches the real-world OID4VP flow and is what you will demo on Day 4.

---

## Quick start (Node.js)

```javascript
const { InjiVerifier } = require('./sdk');

const verifier = new InjiVerifier({
  certifyUrl:  'http://VPS_IP:8091',
  clientId:    'cdpi-poc-verifier',
  redirectUri: 'http://VPS_IP:3001/verify',
});

const result = await verifier.verify(
  ['$.given_name', '$.family_name', '$.employer_name', '$.employment_status'],
  {
    credentialType: 'EmploymentCertification',
    purpose: 'Employment verification',
    onRequestUri: (uri) => {
      // Encode uri as QR code and display to holder
      console.log('Show QR for:', uri);
    },
    onStateChange: (state) => console.log('State:', state),
  }
);

if (result.verified) {
  console.log('Verified claims:', result.claims);
}
```

## Quick start (Python)

```python
from sdk import InjiVerifier

verifier = InjiVerifier(
    certify_url="http://VPS_IP:8091",
    client_id="cdpi-poc-verifier",
    redirect_uri="http://VPS_IP:3001/verify",
)

result = verifier.verify(
    requested_fields=["$.given_name", "$.family_name", "$.employer_name"],
    credential_type="EmploymentCertification",
    on_request_uri=lambda uri, _: print(f"Show QR: {uri}"),
)

print("Verified:", result["verified"])
print("Claims:", result["claims"])
```

---

## QR code generation for web frontend

```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>

<div id="qr"></div>
<p id="status">Scan QR with Inji Wallet to present your credential</p>

<script>
async function startVerification() {
  const { requestUri, requestId } = await fetch('/api/inji/verify/start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ credentialType: 'EmploymentCertification' })
  }).then(r => r.json());

  new QRCode(document.getElementById('qr'), { text: requestUri, width: 256, height: 256 });

  // Poll backend for result
  const poll = setInterval(async () => {
    const result = await fetch(`/api/inji/verify/result/${requestId}`).then(r => r.json());
    if (result.state === 'verified' || result.state === 'done') {
      clearInterval(poll);
      document.getElementById('status').textContent = '✓ Credential verified';
    }
  }, 3000);
}

startVerification();
</script>
```

---

## CLI test

```bash
# Node.js
INJI_CERTIFY_URL=http://VPS_IP:8091 \
INJI_CLIENT_ID=cdpi-poc-verifier \
INJI_REDIRECT_URI=http://VPS_IP:3001/verify \
node sdk.js

# Python
INJI_CERTIFY_URL=http://VPS_IP:8091 \
INJI_CLIENT_ID=cdpi-poc-verifier \
INJI_REDIRECT_URI=http://VPS_IP:3001/verify \
python3 sdk.py
```

---

## Automation and best practices

- Deploy the full INJI stack with `bash scripts/init-inji.sh` — handles prerequisites, keystore generation, image pull, startup order, and health check
- Always save the final credentials/secrets report securely
- For full E2E test flows, see `inji/docs/test-flows.md`
