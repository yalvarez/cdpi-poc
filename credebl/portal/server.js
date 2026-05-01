'use strict';

const express    = require('express');
const nodemailer = require('nodemailer');
const QRCode     = require('qrcode');
const crypto     = require('crypto');
const https      = require('https');
const http       = require('http');
const path       = require('path');
const fs         = require('fs');

// =============================================================================
// Config
// =============================================================================

// Load credebl/.env (two levels up from credebl/portal/)
const envFile = path.resolve(__dirname, '../../credebl/.env');
if (fs.existsSync(envFile)) {
  const lines = fs.readFileSync(envFile, 'utf8').split('\n');
  for (const line of lines) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)/);
    if (m && process.env[m[1]] === undefined) {
      process.env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
    }
  }
}

const {
  VPS_HOST                      = 'localhost',
  API_GATEWAY_PROTOCOL          = 'http',
  CRYPTO_PRIVATE_KEY,
  PLATFORM_ADMIN_EMAIL,
  PLATFORM_ADMIN_INITIAL_PASSWORD,
  // Set these after running provision-org.sh + load-schemas.sh
  CREDEBL_ORG_ID,
  CREDEBL_ISSUER_ID,
  CREDEBL_TEMPLATE_ID,
  // Portal-specific
  PORTAL_PORT                   = '3002',
  PORTAL_FROM_EMAIL             = 'credenciales@cdpi.dev',
  PORTAL_FROM_NAME              = 'CDPI PoC',
  PORTAL_CREDENTIAL_NAME        = 'Credencial de Empleo',
  PORTAL_OFFER_VALID_HOURS      = '48',
  MAILPIT_SMTP_HOST             = VPS_HOST,
  MAILPIT_SMTP_PORT             = '1025',
} = process.env;

const BASE_URL = `${API_GATEWAY_PROTOCOL}://${VPS_HOST}`;
const PORT     = parseInt(PORTAL_PORT, 10);

// =============================================================================
// CryptoJS-compatible AES encryption (EVP_BytesToKey, MD5, CBC)
// Required by CREDEBL's /auth/signin endpoint
// =============================================================================
function encryptPassword(plaintext) {
  const pass = Buffer.from(CRYPTO_PRIVATE_KEY, 'utf8');
  const salt = crypto.randomBytes(8);
  let d = Buffer.alloc(0);
  let dI = Buffer.alloc(0);
  while (d.length < 48) {
    dI = crypto.createHash('md5').update(Buffer.concat([dI, pass, salt])).digest();
    d = Buffer.concat([d, dI]);
  }
  const cipher = crypto.createCipheriv('aes-256-cbc', d.subarray(0, 32), d.subarray(32, 48));
  const raw = JSON.stringify(plaintext);
  const enc = Buffer.concat([cipher.update(raw, 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from('Salted__'), salt, enc]).toString('base64');
}

// =============================================================================
// CREDEBL API helpers
// =============================================================================
function apiRequest(method, urlPath, body, token) {
  return new Promise((resolve, reject) => {
    const url      = new URL(urlPath, BASE_URL);
    const isHttps  = url.protocol === 'https:';
    const lib      = isHttps ? https : http;
    const payload  = body ? JSON.stringify(body) : null;
    const headers  = {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
    };
    const req = lib.request(
      { hostname: url.hostname, port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search, method, headers,
        rejectUnauthorized: false },
      (res) => {
        let data = '';
        res.on('data', c => (data += c));
        res.on('end', () => {
          try { resolve(JSON.parse(data)); }
          catch { resolve({ raw: data, statusCode: res.statusCode }); }
        });
      }
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function getToken() {
  const enc = encryptPassword(PLATFORM_ADMIN_INITIAL_PASSWORD);
  const res = await apiRequest('POST', '/v1/auth/signin', {
    email: PLATFORM_ADMIN_EMAIL, password: enc,
  });
  const token = res?.data?.access_token;
  if (!token) throw new Error(`CREDEBL sign-in failed: ${JSON.stringify(res)}`);
  return token;
}

async function createCredentialOffer(token, attributes) {
  const body = {
    credentialData:       [{ attributes }],
    credentialType:       'sdjwt',
    isReuseConnection:    false,
    comment:              `Emitida via portal CDPI PoC`,
    credentialFormat:     'dc+sd-jwt',
    emailId:              '',        // portal sends its own email
    credentialTemplateId: CREDEBL_TEMPLATE_ID,
    issuanceDate:         null,
    expirationDate:       null,
    protocolType:         'openid',
    flowType:             'preAuthorizedCodeFlow',
  };
  const res = await apiRequest(
    'POST',
    `/v1/orgs/${CREDEBL_ORG_ID}/oid4vc/${CREDEBL_ISSUER_ID}/credential-offer`,
    body, token
  );
  const offerUrl = res?.data?.offerRequest || res?.data?.credentialOffer;
  const pin      = res?.data?.userPin      || res?.data?.pin;
  if (!offerUrl) throw new Error(`Credential offer failed: ${JSON.stringify(res)}`);
  return { offerUrl, pin };
}

// =============================================================================
// Email
// =============================================================================
function buildEmailHtml({ recipientName, credentialName, pin, offerUrl, validHours, qrCid }) {
  const expiry = new Date(Date.now() + parseInt(validHours, 10) * 3_600_000)
    .toLocaleString('es-CO', { dateStyle: 'long', timeStyle: 'short' });

  return `<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${credentialName} — CDPI PoC</title>
</head>
<body style="margin:0;padding:0;background:#f0f4f8;font-family:Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f0f4f8;padding:32px 0;">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08);">

        <!-- Header -->
        <tr>
          <td style="background:#1A5EA0;padding:32px 40px;text-align:center;">
            <p style="margin:0;font-size:13px;color:#a8c8f0;letter-spacing:2px;text-transform:uppercase;">Infraestructura Digital Pública</p>
            <h1 style="margin:8px 0 0;font-size:24px;color:#fff;font-weight:700;">Su credencial está lista</h1>
          </td>
        </tr>

        <!-- Greeting -->
        <tr>
          <td style="padding:32px 40px 0;">
            <p style="margin:0;font-size:16px;color:#1a202c;">Estimado/a <strong>${escapeHtml(recipientName)}</strong>,</p>
            <p style="margin:16px 0 0;font-size:15px;color:#4a5568;line-height:1.6;">
              Su <strong>${escapeHtml(credentialName)}</strong> ha sido emitida y está disponible para descargar en su billetera digital.
            </p>
          </td>
        </tr>

        <!-- PIN Box -->
        <tr>
          <td style="padding:24px 40px 0;">
            <table width="100%" cellpadding="0" cellspacing="0">
              <tr>
                <td style="background:#f7fafc;border:2px solid #1A5EA0;border-radius:8px;padding:20px 24px;">
                  <p style="margin:0 0 8px;font-size:12px;color:#718096;text-transform:uppercase;letter-spacing:1px;">PIN de verificación</p>
                  <p style="margin:0;font-size:40px;font-weight:700;letter-spacing:10px;color:#1A5EA0;font-family:monospace;">${escapeHtml(pin || '------')}</p>
                  <p style="margin:10px 0 0;font-size:13px;color:#e53e3e;">
                    ⏰ Válido hasta: <strong>${expiry}</strong>
                  </p>
                </td>
              </tr>
            </table>
          </td>
        </tr>

        <!-- QR Code -->
        <tr>
          <td style="padding:24px 40px 0;text-align:center;">
            <p style="margin:0 0 12px;font-size:14px;color:#4a5568;">Escanee este código QR con su billetera digital (Inji)</p>
            <img src="cid:${qrCid}" alt="Código QR de la credencial" width="220" height="220"
                 style="border:1px solid #e2e8f0;border-radius:8px;padding:8px;">
          </td>
        </tr>

        <!-- Instructions -->
        <tr>
          <td style="padding:24px 40px 0;">
            <p style="margin:0 0 12px;font-size:14px;font-weight:600;color:#1a202c;">¿Cómo descargo mi credencial?</p>
            <table width="100%" cellpadding="0" cellspacing="0">
              ${[
                ['1', 'Descargue la billetera <strong>Inji</strong> en su dispositivo móvil.'],
                ['2', 'Abra la aplicación y seleccione "Agregar credencial".'],
                ['3', 'Escanee el código QR de este correo con la cámara.'],
                ['4', 'Ingrese el PIN cuando la aplicación lo solicite.'],
                ['5', 'Su credencial quedará guardada de forma segura en su dispositivo.'],
              ].map(([n, t]) => `
              <tr>
                <td valign="top" style="width:28px;padding:6px 0;">
                  <span style="display:inline-block;width:24px;height:24px;border-radius:50%;background:#1A5EA0;color:#fff;font-size:12px;font-weight:700;text-align:center;line-height:24px;">${n}</span>
                </td>
                <td style="padding:6px 0 6px 8px;font-size:14px;color:#4a5568;line-height:1.5;">${t}</td>
              </tr>`).join('')}
            </table>
          </td>
        </tr>

        <!-- Warning -->
        <tr>
          <td style="padding:24px 40px 0;">
            <table width="100%" cellpadding="0" cellspacing="0">
              <tr>
                <td style="background:#fff5f5;border-left:4px solid #e53e3e;border-radius:4px;padding:14px 16px;">
                  <p style="margin:0;font-size:13px;color:#742a2a;">
                    <strong>Importante:</strong> Este enlace expira el <strong>${expiry}</strong>.
                    Si no descarga su credencial en ese plazo, deberá solicitar una nueva emisión.
                  </p>
                </td>
              </tr>
            </table>
          </td>
        </tr>

        <!-- Footer -->
        <tr>
          <td style="padding:32px 40px;text-align:center;border-top:1px solid #e2e8f0;margin-top:24px;">
            <p style="margin:0;font-size:12px;color:#a0aec0;">
              Este correo fue generado automáticamente por el sistema de credenciales verificables de CDPI.<br>
              Si no solicitó esta credencial, puede ignorar este mensaje.
            </p>
          </td>
        </tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

async function sendEmail({ to, toName, credentialName, pin, offerUrl, validHours }) {
  const qrBuffer = await QRCode.toBuffer(offerUrl, {
    errorCorrectionLevel: 'M', width: 440, margin: 2,
    color: { dark: '#1A5EA0', light: '#ffffff' },
  });

  const qrCid = 'qrcode@cdpi.dev';
  const html  = buildEmailHtml({ recipientName: toName, credentialName, pin, offerUrl, validHours, qrCid });

  const transporter = nodemailer.createTransport({
    host: MAILPIT_SMTP_HOST,
    port: parseInt(MAILPIT_SMTP_PORT, 10),
    secure: false,
    ignoreTLS: true,
  });

  await transporter.sendMail({
    from:    `"${PORTAL_FROM_NAME}" <${PORTAL_FROM_EMAIL}>`,
    to:      `"${toName}" <${to}>`,
    subject: `Su ${credentialName} está lista para descargar`,
    html,
    attachments: [{
      filename:    'credencial-qr.png',
      content:     qrBuffer,
      encoding:    'base64',
      cid:         qrCid,
    }],
  });
}

// =============================================================================
// Express app
// =============================================================================
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.post('/api/issue', async (req, res) => {
  const {
    email, given_name, family_name,
    document_number, employer_name, position_title,
    employment_status, employment_start_date,
  } = req.body;

  if (!email || !given_name || !family_name) {
    return res.status(400).json({ error: 'email, given_name y family_name son requeridos.' });
  }

  // Validate that portal is configured
  if (!CREDEBL_ORG_ID || !CREDEBL_ISSUER_ID || !CREDEBL_TEMPLATE_ID) {
    return res.status(503).json({
      error: 'Portal no configurado. Defina CREDEBL_ORG_ID, CREDEBL_ISSUER_ID y CREDEBL_TEMPLATE_ID en credebl/.env',
    });
  }

  try {
    const token = await getToken();

    const attributes = [
      { name: 'given_name',            value: given_name },
      { name: 'family_name',           value: family_name },
      { name: 'document_number',       value: document_number       || '' },
      { name: 'employer_name',         value: employer_name         || '' },
      { name: 'position_title',        value: position_title        || '' },
      { name: 'employment_status',     value: employment_status     || 'active' },
      { name: 'employment_start_date', value: employment_start_date || '' },
    ].filter(a => a.value !== '');

    const { offerUrl, pin } = await createCredentialOffer(token, attributes);

    await sendEmail({
      to:             email,
      toName:         `${given_name} ${family_name}`,
      credentialName: PORTAL_CREDENTIAL_NAME,
      pin,
      offerUrl,
      validHours:     PORTAL_OFFER_VALID_HOURS,
    });

    res.json({ ok: true, message: 'Credencial emitida y correo enviado.' });
  } catch (err) {
    console.error('[/api/issue]', err.message);
    res.status(500).json({ error: err.message });
  }
});

// Startup checks
function checkConfig() {
  const missing = [];
  if (!CRYPTO_PRIVATE_KEY)           missing.push('CRYPTO_PRIVATE_KEY');
  if (!PLATFORM_ADMIN_EMAIL)         missing.push('PLATFORM_ADMIN_EMAIL');
  if (!PLATFORM_ADMIN_INITIAL_PASSWORD) missing.push('PLATFORM_ADMIN_INITIAL_PASSWORD');
  if (missing.length) {
    console.warn(`[portal] WARNING: missing .env vars: ${missing.join(', ')}`);
    console.warn('[portal] These are required for CREDEBL authentication.');
  }
  if (!CREDEBL_ORG_ID || !CREDEBL_ISSUER_ID || !CREDEBL_TEMPLATE_ID) {
    console.warn('[portal] WARNING: CREDEBL_ORG_ID / CREDEBL_ISSUER_ID / CREDEBL_TEMPLATE_ID not set.');
    console.warn('[portal] Run provision-org.sh + load-schemas.sh first, then add the IDs to credebl/.env');
  }
}

app.listen(PORT, () => {
  checkConfig();
  const mailpitUrl = `http://${MAILPIT_SMTP_HOST === 'localhost' ? 'localhost' : VPS_HOST}:8025`;
  console.log(`\nCDPI Credential Portal`);
  console.log(`  Portal:  http://${VPS_HOST}:${PORT}`);
  console.log(`  Mailpit: ${mailpitUrl}`);
  console.log(`  Target:  ${BASE_URL}`);
  console.log('');
});
