#!/bin/bash
# Creates a self-signed code-signing identity, "NowBar Local Signing", in the login keychain.
#
# Ad hoc signed builds are identified by a hash of the exact binary, so macOS forgets the
# "control Spotify" permission on every rebuild. Signing with this identity gives every build the
# same identity instead. The certificate isn't trusted system-wide and only works on the Mac that
# made it. Delete it in Keychain Access if it's no longer needed.
set -euo pipefail
NAME="NowBar Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "$NAME already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS's own LibreSSL: its PKCS#12 output is in the legacy format `security import` expects.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -passout "pass:$PASS" -out "$TMP/identity.p12"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created $NAME"
