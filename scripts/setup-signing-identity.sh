#!/usr/bin/env bash
#
# One-time setup: create a self-signed code-signing identity in the
# login keychain so make-app.sh produces builds with a stable code
# signature.
#
# Why: TCC keys grants (Microphone, System Audio Recording, Screen
# Recording with the ScreenCaptureKit engine, Calendars, Full Disk Access)
# off the code signature hash. Ad-hoc signing (`codesign --sign -`) produces
# a new hash on every build, which macOS interprets as a new app and revokes
# the previous grants. A stable self-signed identity keeps the hash constant
# across rebuilds, so TCC grants persist.
#
# Side effects:
#   - Creates ~/Library/Keychains/login.keychain-db entry "Minnas Dev"
#     (10-year self-signed cert, code-signing extKeyUsage)
#   - You will be prompted for your login keychain password ONCE so
#     codesign can use the key without further prompts.
#
# Run as: bash scripts/setup-signing-identity.sh
# Idempotent: re-running is a no-op once the identity is in place.
#
set -euo pipefail

IDENTITY_NAME="Minnas Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "OK: '$IDENTITY_NAME' identity already exists in login keychain."
    echo "Re-running is a no-op. Use scripts/make-app.sh to build."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> generating 2048-bit RSA private key"
openssl genrsa -out "$WORK_DIR/key.pem" 2048 2>/dev/null

echo "==> writing self-signed cert with codeSigning extKeyUsage"
cat > "$WORK_DIR/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_req

[req_dn]
CN = $IDENTITY_NAME

[v3_req]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -new -x509 \
    -key "$WORK_DIR/key.pem" \
    -out "$WORK_DIR/cert.pem" \
    -days 3650 \
    -config "$WORK_DIR/cert.cnf" 2>/dev/null

# Bundle key + cert into a PKCS#12 file so `security import` can ingest
# both with one call. The intermediate password is throwaway; the key is
# protected by the keychain itself once imported.
TEMP_PW="$(openssl rand -hex 16)"
openssl pkcs12 -export \
    -inkey "$WORK_DIR/key.pem" \
    -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" \
    -name "$IDENTITY_NAME" \
    -passout "pass:$TEMP_PW" 2>/dev/null

echo "==> importing into login keychain"
# Keep the private key non-extractable and usable without a prompt only by
# codesign; otherwise any process running as the user could sign with this
# identity and inherit the app's TCC grants.
#
# An identity created by an earlier script version keeps its old ACL until the
# user deletes and recreates it. Recreation resets TCC grants, so that is a
# deliberate one-time step for the user.
security import "$WORK_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$TEMP_PW" \
    -x \
    -T /usr/bin/codesign >/dev/null

# Trust the cert for code signing. Without this step, find-identity and
# codesign don't see a self-signed cert as a usable codesigning identity
# even when both cert and key are present.
#
# Important: `add-trusted-cert -p codeSign` with no -r/-k flags targets
# the user trust domain and works without sudo. The variants with
# `-r trustAsRoot -k <user-keychain>` or `-r trustRoot` either error out
# (errSecParam) or require admin privileges respectively.
echo "==> registering cert as a trusted code-signing root"
security add-trusted-cert -p codeSign "$WORK_DIR/cert.pem"

echo ""
echo "Done. Verifying:"
security find-identity -p codesigning -v | grep "$IDENTITY_NAME" || {
    echo "FAIL: identity not visible to codesigning. Something went wrong." >&2
    exit 1
}

echo ""
echo "Now run: bash scripts/make-app.sh"
echo "make-app.sh will pick up the identity automatically."
