#!/bin/bash
# Makes mx's self-signed code-signing identity, "mx", once. Run it by hand, one time:
#
#   scripts/make-signing-identity.sh [out-dir]    # default ./mx-signing
#
# It writes, into a new directory (mode 0700):
#   mx-signing.p12           the private key and certificate (PKCS#12)
#   mx-signing.p12.password  the .p12's random password
#   mx-signing.cer           the certificate alone (public)
#
# Why: Claude Desktop runs the mx in mx.mcpb as its own app, so users give mx
# itself Accessibility and Screen Recording. macOS keys those grants to the
# binary's designated requirement. Signed ad hoc, that is the code hash, so
# every update is a new binary and the grants lapse. Signed with this
# certificate, it is the identifier plus this certificate's hash, the same for
# every release, so the grants carry over. Losing the .p12 means a new
# certificate, and every user grants mx once more. Keep the .p12 and its
# password in the password manager.
#
# This is not the certificate that signs the .mcpb bundle itself
# (packaging/mcpb/make-signing-cert.sh); that one signs the zip, this one the
# mx binary inside it.
#
# It is self-signed, not a Developer ID: Gatekeeper doesn't trust it, which
# doesn't matter for a binary Claude Desktop unpacks and starts. Nothing goes
# into any keychain; scripts/sign-macos.sh imports the .p12 into a temporary
# keychain for one build.
set -euo pipefail

name="mx"
out="${1:-mx-signing}"
[ -e "$out" ] && { echo "$out already exists; not replacing an identity (a new one resets every user's grant)" >&2; exit 1; }

# The system LibreSSL, not a Homebrew OpenSSL 3 on PATH: OpenSSL 3 writes a
# PKCS#12 MAC that macOS's `security import` rejects.
openssl=/usr/bin/openssl

mkdir -m 0700 "$out"
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $name
O = Facets
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 20 years. The requirement pins this certificate, so replacing it resets grants.
"$openssl" req -x509 -newkey rsa:3072 -nodes -sha256 -days 7300 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
"$openssl" rand -hex 24 > "$out/mx-signing.p12.password"
"$openssl" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$out/mx-signing.p12" -passout "file:$out/mx-signing.p12.password"
"$openssl" x509 -in "$tmp/cert.pem" -outform der -out "$out/mx-signing.cer"

echo "made \"$name\" in $out"
echo "certificate SHA-1 (the designated requirement pins this): $("$openssl" x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
echo
echo "Set the release secrets, then move $out into the password manager and delete it from disk:"
echo "  base64 -i $out/mx-signing.p12 | gh secret set MX_SIGNING_P12 -R Facets-cloud/mx"
echo "  gh secret set MX_SIGNING_P12_PASSWORD -R Facets-cloud/mx < $out/mx-signing.p12.password"
