/**
 * CDPI PoC — Verification SDK (Node.js / TypeScript-compatible)
 * ----------------------------------------------------------------
 * Complete implementation for requesting and verifying SD-JWT VC
 * credentials through CREDEBL's OID4VP-based verification flow.
 *
 * Usage:
 *   const { CredeblVerifier } = require('./sdk');
 *   const verifier = new CredeblVerifier({ apiUrl, orgId, apiToken });
 *   const { proofUrl, proofId } = await verifier.requestPresentation([...]);
 *   const result = await verifier.awaitResult(proofId);
 */

'use strict';

const https = require('https');
const http = require('http');
const url = require('url');

// ─────────────────────────────────────────────────────────────────────────────
// HTTP helper (no external dependencies)
// ─────────────────────────────────────────────────────────────────────────────
function httpRequest(method, urlStr, body, headers) {
  return new Promise((resolve, reject) => {
    const parsed = url.parse(urlStr);
    const lib = parsed.protocol === 'https:' ? https : http;
    const data = body ? JSON.stringify(body) : null;

    const options = {
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.path,
      method,
      headers: {
        'Content-Type': 'application/json',
        ...headers,
        ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}),
      },
    };

    const req = lib.request(options, (res) => {
      let raw = '';
      res.on('data', (chunk) => { raw += chunk; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(raw);
          if (res.statusCode >= 400) {
            reject(new CredeblError(res.statusCode, parsed));
          } else {
            resolve(parsed);
          }
        } catch {
          reject(new Error(`Non-JSON response (${res.statusCode}): ${raw.slice(0, 200)}`));
        }
      });
    });

    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom error class
// ─────────────────────────────────────────────────────────────────────────────
class CredeblError extends Error {
  constructor(statusCode, body) {
    super(body?.message || body?.error || `HTTP ${statusCode}`);
    this.statusCode = statusCode;
    this.body = body;
    this.name = 'CredeblError';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main SDK class
// ─────────────────────────────────────────────────────────────────────────────
class CredeblVerifier {
  /**
   * @param {object} config
   * @param {string} config.apiUrl       - CREDEBL API base URL (e.g. http://VPS_IP:5000)
   * @param {string} config.orgId        - Organization ID in CREDEBL
   * @param {string} config.apiToken     - JWT token from /auth/login
   * @param {number} [config.pollInterval=3000] - ms between result polling attempts
   * @param {number} [config.pollTimeout=120000] - ms total timeout for awaiting result
   */
  constructor({ apiUrl, orgId, apiToken, pollInterval = 3000, pollTimeout = 120000 }) {
    if (!apiUrl) throw new Error('config.apiUrl is required');
    if (!orgId) throw new Error('config.orgId is required');
    if (!apiToken) throw new Error('config.apiToken is required');

    this.apiUrl = apiUrl.replace(/\/$/, '');
    this.orgId = orgId;
    this.apiToken = apiToken;
    this.pollInterval = pollInterval;
    this.pollTimeout = pollTimeout;
  }

  get _headers() {
    return { Authorization: `Bearer ${this.apiToken}` };
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  /**
   * Get a fresh JWT token. Call this to re-authenticate after token expiry.
   *
   * @param {string} apiUrl
   * @param {string} email
   * @param {string} password
   * @returns {Promise<string>} JWT access token
   */
  static async login(apiUrl, email, password) {
    const data = await httpRequest(
      'POST',
      `${apiUrl.replace(/\/$/, '')}/auth/login`,
      { email, password }
    );
    return data.access_token;
  }

  // ── Organization ───────────────────────────────────────────────────────────

  /**
   * Get organization details including agent status.
   * Useful to confirm the agent is ready before starting a verification.
   *
   * @returns {Promise<object>}
   */
  async getOrganization() {
    return httpRequest('GET', `${this.apiUrl}/orgs/${this.orgId}`, null, this._headers);
  }

  // ── Schema & Credential Definition ────────────────────────────────────────

  /**
   * List all schemas registered by this organization.
   *
   * @returns {Promise<object[]>}
   */
  async listSchemas() {
    return httpRequest('GET', `${this.apiUrl}/schema/org/${this.orgId}`, null, this._headers);
  }

  /**
   * List all credential definitions for this organization.
   *
   * @returns {Promise<object[]>}
   */
  async listCredentialDefinitions() {
    return httpRequest('GET', `${this.apiUrl}/credential-definitions/org/${this.orgId}`, null, this._headers);
  }

  // ── Verification ───────────────────────────────────────────────────────────

  /**
   * Create a verification proof request.
   *
   * @param {object[]} requestedAttributes - Array of attribute requests
   * @param {string}   requestedAttributes[].attributeName - Field name from the schema
   * @param {string}   requestedAttributes[].schemaId      - CREDEBL schema ID
   * @param {string}   requestedAttributes[].credDefId     - Credential definition ID
   * @param {object}   [options]
   * @param {string}   [options.comment]        - Human-readable comment for the request
   * @param {string}   [options.connectionId]   - If verifying over an existing connection
   *
   * @returns {Promise<{ proofUrl: string, proofId: string, state: string }>}
   *
   * @example
   * const { proofUrl, proofId } = await verifier.requestPresentation([
   *   { attributeName: 'given_name',    schemaId: 'abc123', credDefId: 'def456' },
   *   { attributeName: 'employer_name', schemaId: 'abc123', credDefId: 'def456' },
   * ]);
   */
  async requestPresentation(requestedAttributes, options = {}) {
    const payload = {
      orgId: this.orgId,
      requestedAttributes: requestedAttributes.map((attr) => ({
        attributeName: attr.attributeName,
        schemaId: attr.schemaId,
        credDefId: attr.credDefId,
        isRevoked: false,
      })),
      comment: options.comment || 'CDPI PoC Verification Request',
    };

    if (options.connectionId) {
      payload.connectionId = options.connectionId;
    }

    const data = await httpRequest(
      'POST',
      `${this.apiUrl}/verification/send-verification-request`,
      payload,
      this._headers
    );

    return {
      proofUrl: data.proofUrl || data.invitationUrl,
      proofId: data.id || data.proofId,
      state: data.state,
      raw: data,
    };
  }

  /**
   * Get the current state and result of a proof request.
   *
   * @param {string} proofId
   * @returns {Promise<{ state: string, isVerified: boolean|null, attributes: object|null }>}
   */
  async getProofResult(proofId) {
    const data = await httpRequest(
      'GET',
      `${this.apiUrl}/verification/proofs/${proofId}`,
      null,
      this._headers
    );

    return {
      state: data.state,
      isVerified: data.isVerified ?? null,
      attributes: data.requestedAttributes || null,
      raw: data,
    };
  }

  /**
   * Poll for verification result until done, abandoned, or timeout.
   *
   * @param {string} proofId
   * @param {object} [callbacks]
   * @param {function} [callbacks.onStateChange] - Called when state changes: (state) => void
   * @param {function} [callbacks.onTick]        - Called on each poll: (attempt, state) => void
   *
   * @returns {Promise<{ verified: boolean, attributes: object|null, reason: string|null }>}
   */
  async awaitResult(proofId, callbacks = {}) {
    const startTime = Date.now();
    let lastState = null;
    let attempt = 0;

    while (Date.now() - startTime < this.pollTimeout) {
      attempt++;
      const result = await this.getProofResult(proofId);

      if (result.state !== lastState) {
        lastState = result.state;
        if (callbacks.onStateChange) callbacks.onStateChange(result.state);
      }

      if (callbacks.onTick) callbacks.onTick(attempt, result.state);

      if (result.state === 'done') {
        return {
          verified: result.isVerified === true,
          attributes: result.attributes,
          reason: result.isVerified ? null : 'credential_invalid',
          proofId,
        };
      }

      if (result.state === 'abandoned') {
        return { verified: false, attributes: null, reason: 'abandoned', proofId };
      }

      await new Promise((r) => setTimeout(r, this.pollInterval));
    }

    return { verified: false, attributes: null, reason: 'timeout', proofId };
  }

  /**
   * One-shot: request presentation and wait for result.
   * Convenience method combining requestPresentation + awaitResult.
   *
   * @param {object[]} requestedAttributes
   * @param {object}   [options]
   * @param {function} [options.onProofUrl] - Called immediately with the QR/deep link URL
   * @param {function} [options.onStateChange]
   *
   * @returns {Promise<{ verified: boolean, attributes: object|null, reason: string|null }>}
   */
  async verify(requestedAttributes, options = {}) {
    const { proofUrl, proofId } = await this.requestPresentation(requestedAttributes, options);

    if (options.onProofUrl) options.onProofUrl(proofUrl, proofId);

    return this.awaitResult(proofId, {
      onStateChange: options.onStateChange,
      onTick: options.onTick,
    });
  }

  // ── Proof list ─────────────────────────────────────────────────────────────

  /**
   * List recent proof requests for this organization.
   *
   * @param {number} [limit=20]
   * @returns {Promise<object[]>}
   */
  async listProofs(limit = 20) {
    return httpRequest(
      'GET',
      `${this.apiUrl}/verification/proofs?orgId=${this.orgId}&limit=${limit}`,
      null,
      this._headers
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exports
// ─────────────────────────────────────────────────────────────────────────────
module.exports = { CredeblVerifier, CredeblError };

// ─────────────────────────────────────────────────────────────────────────────
// CLI quick test (run: node sdk.js)
// ─────────────────────────────────────────────────────────────────────────────
if (require.main === module) {
  const API_URL   = process.env.CREDEBL_API_URL   || 'http://localhost:5000';
  const ORG_ID    = process.env.CREDEBL_ORG_ID    || '';
  const API_TOKEN = process.env.CREDEBL_API_TOKEN || '';
  const SCHEMA_ID  = process.env.CREDEBL_SCHEMA_ID  || '';
  const CRED_DEF_ID = process.env.CREDEBL_CRED_DEF_ID || '';

  if (!ORG_ID || !API_TOKEN || !SCHEMA_ID || !CRED_DEF_ID) {
    console.error('Set env vars: CREDEBL_API_URL, CREDEBL_ORG_ID, CREDEBL_API_TOKEN, CREDEBL_SCHEMA_ID, CREDEBL_CRED_DEF_ID');
    process.exit(1);
  }

  const verifier = new CredeblVerifier({ apiUrl: API_URL, orgId: ORG_ID, apiToken: API_TOKEN });

  (async () => {
    console.log('Requesting verification...');
    const result = await verifier.verify(
      [
        { attributeName: 'given_name',    schemaId: SCHEMA_ID, credDefId: CRED_DEF_ID },
        { attributeName: 'family_name',   schemaId: SCHEMA_ID, credDefId: CRED_DEF_ID },
        { attributeName: 'employer_name', schemaId: SCHEMA_ID, credDefId: CRED_DEF_ID },
      ],
      {
        onProofUrl: (url) => {
          console.log('\nScan this QR / open in wallet:');
          console.log(url);
          console.log('\nWaiting for presentation...');
        },
        onStateChange: (state) => console.log(`  State: ${state}`),
      }
    );

    console.log('\nResult:', JSON.stringify(result, null, 2));
  })().catch(console.error);
}
