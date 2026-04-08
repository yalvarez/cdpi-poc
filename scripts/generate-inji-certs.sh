#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — INJI Keystore Generation Script
# -----------------------------------------------------------------------------
# Generates the PKCS12 keystore required by Mimoto for secure credential
# download flows via Inji Web.
#
# Run ONCE before first deployment:
#   chmod +x scripts/generate-inji-certs.sh
#   bash scripts/generate-inji-certs.sh
#
# Output: inji/certs/oidckeystore.p12
# =============================================================================

set -euo pipefail

CERTS_DIR="$(dirname "$0")/../inji/certs"
KEYSTORE="$CERTS_DIR/oidckeystore.p12"
KEYSTORE_PASS="${CERTIFY_KEYSTORE_PASSWORD:-changeme_replace_this}"

mkdir -p "$CERTS_DIR"

if [ -f "$KEYSTORE" ]; then
  echo "Keystore already exists: $KEYSTORE"
  echo "Delete it and re-run to regenerate."
  exit 0
fi

echo "Generating INJI OIDC keystore..."

# Generate private key + self-signed cert
openssl req -newkey rsa:2048 -nodes \
  -keyout "$CERTS_DIR/oidc.key" \
  -x509 -days 3650 \
  -out "$CERTS_DIR/oidc.crt" \
  -subj "/C=XX/ST=PoC/L=CDPI/O=CDPI PoC/CN=inji-certify-poc" \
  2>/dev/null

# Bundle into PKCS12
openssl pkcs12 -export \
  -in "$CERTS_DIR/oidc.crt" \
  -inkey "$CERTS_DIR/oidc.key" \
  -out "$KEYSTORE" \
  -name "oidckeystore" \
  -passout "pass:$KEYSTORE_PASS"

# Clean up intermediate files
rm -f "$CERTS_DIR/oidc.key" "$CERTS_DIR/oidc.crt"

echo ""
echo "Keystore generated: $KEYSTORE"
echo "Password: $KEYSTORE_PASS"
echo ""
echo "Make sure CERTIFY_KEYSTORE_PASSWORD in inji/.env matches this password."
