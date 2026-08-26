#!/bin/bash
# Creates the stable self-signed code-signing identity MailSpace is built with.
#
# Run once per Mac:  make signing-cert
#
# Why this exists: `codesign --sign -` (ad-hoc) gives the bundle no signing
# identity at all, so macOS identifies the app by its cdhash. Every rebuild
# changes the cdhash, so every rebuild looks like a brand-new app — which is
# why the notification permission prompt comes back after each `make build`.
# Signing with a certificate that stays the same across rebuilds gives the app
# one stable identity, and the permission answer sticks with it.
#
# The certificate is self-signed and lives only in this Mac's login keychain.
# It is not a Developer ID, it does not notarize anything, and it is not needed
# to run the app — `make build` falls back to ad-hoc signing when it is absent.
set -euo pipefail

NAME="${MAILSPACE_SIGN_IDENTITY:-MailSpace Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "signing-cert: \"$NAME\" already exists in the login keychain — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "signing-cert: generating a self-signed code-signing certificate \"$NAME\""

# `extendedKeyUsage=codeSigning` is what makes codesign accept the identity.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -subj "/CN=$NAME/O=MailSpace" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" -name "$NAME" >/dev/null 2>&1

# -T /usr/bin/codesign -A pre-authorises codesign to use the key, so builds do
# not stop on a keychain-access dialog.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -A >/dev/null

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "signing-cert: installed \"$NAME\" in $KEYCHAIN"
  echo "signing-cert: run 'make build' — it will pick the certificate up automatically."
else
  echo "signing-cert: FAILED — the certificate is not in the keychain." >&2
  exit 1
fi
