#!/bin/bash
# Signs a macOS binary for mx.mcpb:
#   sign-macos.sh <file>
# With MX_SIGNING_P12 (path to the .p12 from make-signing-identity.sh) and
# MX_SIGNING_P12_PASSWORD set, it signs with the "mx" identity and the fixed
# identifier cloud.facets.mx. The designated requirement is then the same for
# every release, so a user's Accessibility and Screen Recording grants to mx
# survive updates. Without them it signs ad hoc and says so: the grants then
# lapse on update. Run it on the universal binary, after lipo, so codesign
# signs both slices.
set -euo pipefail
file="${1:?usage: sign-macos.sh <file>}"
identity="mx"

if [ -z "${MX_SIGNING_P12:-}" ]; then
  echo "sign-macos.sh: MX_SIGNING_P12 not set, signing $file ad hoc (Accessibility and Screen Recording grants won't survive updates)" >&2
  codesign -s - -f -i cloud.facets.mx "$file" 2>/dev/null
  exit 0
fi
: "${MX_SIGNING_P12_PASSWORD:?set MX_SIGNING_P12_PASSWORD}"

tmp="$(mktemp -d)"
kc="$tmp/signing.keychain-db"
# The user keychain search list as it was, restored on exit.
searchlist=()
while IFS= read -r k; do
  k="${k#"${k%%[![:space:]]*}"}"; k="${k#\"}"; k="${k%\"}"
  [ -n "$k" ] && searchlist+=("$k")
done < <(security list-keychains -d user)
cleanup() {
  if [ "${CI:-}" = true ]; then
    security list-keychains -d user -s ${searchlist[@]+"${searchlist[@]}"} 2>/dev/null || true
  fi
  security delete-keychain "$kc" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

kcpass="$(uuidgen)"
security create-keychain -p "$kcpass" "$kc"
# codesign on macOS 15 and 26 (GitHub's runners) finds no identity in a
# keychain that isn't on the search list, even with --keychain. macOS 27
# doesn't need it, so a local build leaves the user's list alone.
if [ "${CI:-}" = true ]; then
  security list-keychains -d user -s "$kc" ${searchlist[@]+"${searchlist[@]}"}
fi
security set-keychain-settings "$kc" # no auto-lock mid-build
security unlock-keychain -p "$kcpass" "$kc"
security import "$MX_SIGNING_P12" -k "$kc" -P "$MX_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
# Not -v: a self-signed identity is never "valid" (not trusted); codesign signs with it anyway.
ids="$(security find-identity -p codesigning "$kc")"
grep -q "\"$identity\"" <<<"$ids" || { echo "no \"$identity\" identity in $MX_SIGNING_P12" >&2; exit 1; }

codesign -f -s "$identity" -i cloud.facets.mx --timestamp=none --keychain "$kc" "$file"
# Captured first: with pipefail, grep -q quitting early would fail codesign.
for arch in $(lipo -archs "$file"); do
  info="$(codesign -dvv --arch "$arch" "$file" 2>&1)"
  grep -qx "Authority=$identity" <<<"$info" || { echo "$file ($arch) isn't signed by $identity" >&2; exit 1; }
done
echo "signed $file: $(codesign -d -r- "$file" 2>&1 | sed -n 's/^designated => //p')" >&2
