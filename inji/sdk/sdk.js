/**
 * CDPI PoC — INJI Verification SDK (Node.js)
 * -----------------------------------------------
 * Wrapper for verifying SD-JWT VC credentials through INJI's OID4VP flow.
 *
 * INJI verification differs from CREDEBL:
 *   - Uses OID4VP (OpenID for Verifiable Presentations) protocol
 *   - Holder presents credentials via Inji Wallet (web or mobile)
 *   - Verifier creates a presentation request → holder responds → verifier checks
 *
 * Usage:
 *   const { InjiVerifier } = require('./sdk');
 *   const verifier = new InjiVerifier({ certifyUrl, clientId, redirectUri });
 *   const { requestUri, requestId } = await verifier.createPresentationRequest([...]);
 *   const result = await verifier.awaitPresentation(requestId);
 */

'use strict';

const https = require('https');
const http  = require('http');
const url   = require('url');

// ─── HTTP helper ─────────────────────────────────────────────────────────────
function httpRequest(method, urlStr, body, headers) {
  return new Promise((resolve, reject) => {
    const parsed = url.parse(urlStr);
    const lib    = parsed.protocol === 'https:' ? https : http;
    const data   = body ? JSON.stringify(body) : null;
    const opts   = {
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
    const req = lib.request(opts, (res) => {
      let raw = '';
      res.on('data', (c) => { raw += c; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(raw);
          if (res.statusCode >= 400) reject(new InjiError(res.statusCode, parsed));
          else resolve(parsed);
        } catch {
          reject(new Error(`Non-JSON (${res.statusCode}): ${raw.slice(0, 200)}`));
        }
      });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

class InjiError extends Error {
  constructor(statusCode, body) {
    super(body?.message || body?.error || `HTTP ${statusCode}`);
    this.statusCode = statusCode;
    this.body = body;
    this.name = 'InjiError';
  }
}

// ─── Main SDK class ───────────────────────────────────────────────────────────
class InjiVerifier {
  /**
   * @param {object} config
   * @param {string} config.certifyUrl     - Certify base URL (e.g. http://VPS_IP:8091)
   * @param {string} config.clientId       - Verifier client ID (registered in Mimoto)
   * @param {string} config.redirectUri    - Redirect URI after presentation
   * @param {number} [config.pollInterval=3000]
   * @param {number} [config.pollTimeout=120000]
   */
  constructor({ certifyUrl, clientId, redirectUri, pollInterval = 3000, pollTimeout = 120000 }) {
    if (!certifyUrl) throw new Error('config.certifyUrl is required');
    if (!clientId)   throw new Error('config.clientId is required');
    if (!redirectUri) throw new Error('config.redirectUri is required');

    this.certifyUrl    = certifyUrl.replace(/\/$/, '');
    this.clientId      = clientId;
    this.redirectUri   = redirectUri;
    this.pollInterval  = pollInterval;
    this.pollTimeout   = pollTimeout;
  }

  // ── Discovery ────────────────────────────────────────────────────────────────

  /**
   * Fetch issuer metadata from Certify well-known endpoint.
   * Useful to confirm which credential types are supported.
   *
   * @returns {Promise<object>}
   */
  async getIssuerMetadata() {
    return httpRequest('GET', `${this.certifyUrl}/.well-known/openid-credential-issuer`);
  }

  /**
   * List supported credential types from issuer metadata.
   *
   * @returns {Promise<string[]>} Array of credential type names
   */
  async getSupportedCredentialTypes() {
    const meta = await this.getIssuerMetadata();
    return Object.keys(meta.credential_configurations_supported || {});
  }

  // ── Presentation request ─────────────────────────────────────────────────────

  /**
   * Create an OID4VP presentation request.
   *
   * @param {object[]} requestedFields - Fields to request from the holder
   * @param {string}   requestedFields[].path   - JSON path (e.g. "$.given_name")
   * @param {boolean}  [requestedFields[].required=true]
   * @param {object}   [options]
   * @param {string}   [options.credentialType]  - e.g. "EmploymentCertification"
   * @param {string}   [options.purpose]         - Human-readable purpose string
   * @param {boolean}  [options.limitDisclosure=true] - Enforce selective disclosure
   *
   * @returns {Promise<{ requestUri: string, requestId: string, qrData: string }>}
   *
   * @example
   * const { requestUri, requestId } = await verifier.createPresentationRequest([
   *   { path: '$.given_name' },
   *   { path: '$.family_name' },
   *   { path: '$.employer_name' },
   *   { path: '$.employment_status' },
   * ], { credentialType: 'EmploymentCertification', purpose: 'Employment verification' });
   */
  async createPresentationRequest(requestedFields, options = {}) {
    const {
      credentialType = 'EmploymentCertification',
      purpose = 'CDPI PoC Credential Verification',
      limitDisclosure = true,
    } = options;

    const payload = {
      client_id: this.clientId,
      redirect_uri: this.redirectUri,
      response_type: 'vp_token',
      scope: `openid ${credentialType}`,
      nonce: Math.random().toString(36).slice(2),
      presentation_definition: {
        id: `${credentialType.toLowerCase()}-check-${Date.now()}`,
        input_descriptors: [
          {
            id: credentialType.toLowerCase(),
            name: credentialType,
            purpose,
            constraints: {
              limit_disclosure: limitDisclosure ? 'required' : 'preferred',
              fields: requestedFields.map((f) => ({
                path: [typeof f === 'string' ? f : f.path],
                ...(f.required === false ? {} : {}),
              })),
            },
          },
        ],
      },
    };

    const data = await httpRequest(
      'POST',
      `${this.certifyUrl}/v1/certify/vp/presentation-request`,
      payload
    );

    const requestUri = data.request_uri || data.presentation_uri;
    const requestId  = data.id || data.request_id || data.nonce;

    return {
      requestUri,
      requestId,
      qrData: requestUri,  // encode this as QR to show to holder
      raw: data,
    };
  }

  // ── Await presentation ───────────────────────────────────────────────────────

  /**
   * Check the current state of a presentation request.
   *
   * @param {string} requestId
   * @returns {Promise<{ state: string, verified: boolean|null, claims: object|null }>}
   */
  async getPresentationState(requestId) {
    const data = await httpRequest(
      'GET',
      `${this.certifyUrl}/v1/certify/vp/presentation/${requestId}`
    );

    return {
      state: data.state || data.status,
      verified: data.verified ?? null,
      claims: data.verified_claims || data.claims || null,
      raw: data,
    };
  }

  /**
   * Poll for presentation result until complete or timeout.
   *
   * @param {string}   requestId
   * @param {object}   [callbacks]
   * @param {function} [callbacks.onStateChange]
   * @param {function} [callbacks.onTick]
   *
   * @returns {Promise<{ verified: boolean, claims: object|null, reason: string|null }>}
   */
  async awaitPresentation(requestId, callbacks = {}) {
    const start     = Date.now();
    let   lastState = null;
    let   attempt   = 0;

    while (Date.now() - start < this.pollTimeout) {
      attempt++;
      const result = await this.getPresentationState(requestId);

      if (result.state !== lastState) {
        lastState = result.state;
        if (callbacks.onStateChange) callbacks.onStateChange(result.state);
      }
      if (callbacks.onTick) callbacks.onTick(attempt, result.state);

      if (['verified', 'done', 'completed'].includes(result.state)) {
        return {
          verified: result.verified !== false,
          claims: result.claims,
          reason: null,
          requestId,
        };
      }

      if (['rejected', 'failed', 'abandoned'].includes(result.state)) {
        return { verified: false, claims: null, reason: result.state, requestId };
      }

      await new Promise((r) => setTimeout(r, this.pollInterval));
    }

    return { verified: false, claims: null, reason: 'timeout', requestId };
  }

  /**
   * One-shot: create request and wait for presentation.
   *
   * @param {object[]} requestedFields
   * @param {object}   [options]
   * @param {function} [options.onRequestUri] - Callback(requestUri) — use to show QR
   * @param {function} [options.onStateChange]
   *
   * @returns {Promise<{ verified: boolean, claims: object|null, reason: string|null }>}
   */
  async verify(requestedFields, options = {}) {
    const { requestUri, requestId } = await this.createPresentationRequest(
      requestedFields,
      options
    );

    if (options.onRequestUri) options.onRequestUri(requestUri, requestId);

    return this.awaitPresentation(requestId, {
      onStateChange: options.onStateChange,
      onTick: options.onTick,
    });
  }
}

// ─── Exports ──────────────────────────────────────────────────────────────────
module.exports = { InjiVerifier, InjiError };

// ─── CLI quick test ───────────────────────────────────────────────────────────
if (require.main === module) {
  const CERTIFY_URL  = process.env.INJI_CERTIFY_URL  || 'http://localhost:8091';
  const CLIENT_ID    = process.env.INJI_CLIENT_ID    || 'cdpi-poc-verifier';
  const REDIRECT_URI = process.env.INJI_REDIRECT_URI || 'http://localhost:3001/verify';

  const verifier = new InjiVerifier({ certifyUrl: CERTIFY_URL, clientId: CLIENT_ID, redirectUri: REDIRECT_URI });

  (async () => {
    console.log('Fetching supported credential types...');
    const types = await verifier.getSupportedCredentialTypes();
    console.log('Supported types:', types);

    console.log('\nCreating presentation request for EmploymentCertification...');
    const result = await verifier.verify(
      [
        { path: '$.given_name' },
        { path: '$.family_name' },
        { path: '$.employer_name' },
        { path: '$.employment_status' },
      ],
      {
        credentialType: 'EmploymentCertification',
        purpose: 'Employment verification — CDPI PoC',
        onRequestUri: (uri) => {
          console.log('\nShare this URI with the holder wallet:');
          console.log(uri);
          console.log('\nWaiting for presentation...');
        },
        onStateChange: (s) => console.log(`  State: ${s}`),
      }
    );

    console.log('\nResult:', JSON.stringify(result, null, 2));
  })().catch(console.error);
}
