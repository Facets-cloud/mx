#!/bin/bash
# Build the npm packages for one version: npm-build.sh v0.1.0
# Fills npm/mx-darwin-{arm64,x64}/bin/mx, sets every package.json version and
# the plugin version. Publish the platform packages before npm/mx.
set -euo pipefail
tag="${1:?usage: npm-build.sh vX.Y.Z}"
version="${tag#v}"
cd "$(dirname "$0")/.."

# Swift has no -X ldflags: write the version into Version.swift for this
# build, then put the file back.
vfile=Sources/mx/Version.swift
cp "$vfile" "$vfile.orig"
trap 'mv -f "$vfile.orig" "$vfile"' EXIT
sed -i '' "s/^let mxVersion = .*/let mxVersion = \"$version\"/" "$vfile"

for pair in arm64:arm64 x64:x86_64; do
  npmarch="${pair%%:*}"; swiftarch="${pair##*:}"
  dir="npm/mx-darwin-$npmarch"
  swift build -c release --arch "$swiftarch"
  mkdir -p "$dir/bin"
  cp "$(swift build -c release --arch "$swiftarch" --show-bin-path)/mx" "$dir/bin/mx"
  strip -x "$dir/bin/mx"
  cp LICENSE THIRD_PARTY_NOTICES "$dir/"
done
cp LICENSE THIRD_PARTY_NOTICES README.md npm/mx/
# Link the platform packages where node looks for them, so a checkout can run
# `node npm/mx/bin/mx.js` the way an install would.
mkdir -p npm/node_modules/@facets-cloud
for npmarch in arm64 x64; do
  ln -sfn "../../mx-darwin-$npmarch" "npm/node_modules/@facets-cloud/mx-darwin-$npmarch"
done

for f in npm/*/package.json plugin/.claude-plugin/plugin.json; do
  node -e '
    const fs = require("fs"), [f, v] = process.argv.slice(1);
    const p = JSON.parse(fs.readFileSync(f));
    p.version = v;
    for (const d of Object.keys(p.optionalDependencies || {})) p.optionalDependencies[d] = v;
    fs.writeFileSync(f, JSON.stringify(p, null, 2) + "\n");
  ' "$f" "$version"
done
echo "built npm packages for $version"
