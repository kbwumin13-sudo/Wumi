#!/bin/zsh
# Creates the local self-signed code-signing identity "DirDesk Local Signing" in the login keychain.
# A fixed identity keeps the app's designated requirement stable, so privacy grants (Full Disk Access, Desktop and
# Documents folders) survive rebuilds; ad-hoc signatures change on every build and macOS asks again.
# Usage: scripts/make-signing-cert.sh            (does nothing when the identity already exists)
set -euo pipefail

NAME="${SIGN_IDENTITY:-DirDesk Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
  echo "identity \"$NAME\" already exists"
  exit 0
fi

WORK="$(mktemp -d /tmp/dirdesk-cert.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -config "$WORK/cert.cnf" 2>/dev/null
PASS="$("$OPENSSL" rand -hex 16)"
# 3DES/SHA-1 PKCS#12 so that `security import` can read it (OpenSSL 3 defaults to AES, which it rejects).
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/id.p12" \
  -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "created \"$NAME\" ($("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2))"
