#!/bin/bash
# Makes the self-signed certificate that signs mx.mcpb, once. Run it by hand, one time.
#
#   packaging/mcpb/make-signing-cert.sh [out-dir]    # default ./mx-mcpb-signing
#
# It writes, into a new directory (mode 0700):
#   cert.pem   the certificate (public)
#   key.pem    its private key (unencrypted PEM, which `mcpb sign` reads)
# and prints the certificate's SHA-256 fingerprint, in the form `mcpb verify` prints it, for
# the install page.
#
# Why one stable certificate: users and the install page check a signed bundle by this
# fingerprint, so every release must carry the same one. A new certificate means a new
# fingerprint to publish. Keep both files in the password manager.
#
# The certificate is self-signed, so no OS trust store knows it: Claude Desktop and
# `mcpb verify` don't treat it as a trusted publisher. A trusted one needs a code-signing
# certificate from a CA.
#
# After running it:
#   gh secret set MCPB_SIGNING_CERT -R Facets-cloud/mx < mx-mcpb-signing/cert.pem
#   gh secret set MCPB_SIGNING_KEY -R Facets-cloud/mx < mx-mcpb-signing/key.pem
# then move the directory into the password manager and delete it from disk.
set -euo pipefail

name="mx (Facets Cloud)"
out="${1:-mx-mcpb-signing}"
[ -e "$out" ] && { echo "$out already exists; not replacing the certificate (a new one changes the fingerprint)" >&2; exit 1; }

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
O = Facets Cloud
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# RSA, because mcpb signs with node-forge, which reads RSA keys only. 20 years, so the
# fingerprint outlives many releases.
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 7300 -config "$tmp/cert.cnf" \
  -keyout "$out/key.pem" -out "$out/cert.pem" 2>/dev/null

echo "made \"$name\" in $out"
echo "certificate SHA-256 (as mcpb verify prints it): $(openssl x509 -in "$out/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')"
