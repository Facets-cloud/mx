#!/bin/sh
# Install the mx CLI from the latest GitHub release. No Node, no sudo.
#
#   curl -fsSL https://facets-cloud.github.io/mx/install.sh | sh
#
# It downloads the archive for this Mac's CPU, checks its SHA-256 against the
# release's checksums.txt, and installs the binary into $MX_INSTALL_DIR
# (default ~/.local/bin). Set MX_VERSION=v0.1.4 to pin a version. Then it runs
# mx doctor, which says which app to grant Accessibility to.
set -eu

repo="Facets-cloud/mx"
dir="${MX_INSTALL_DIR:-$HOME/.local/bin}"

fail() { echo "mx install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "needs $1"; }
need curl
need tar
need uname

# One of GitHub's download addresses doesn't answer from some networks, and
# curl waits over a minute on it before trying the next. A short connect
# timeout makes it move on in a second or two.
dl() { curl -fL --connect-timeout 4 --retry 2 "$@"; }

[ "$(uname -s)" = Darwin ] || fail "mx drives Mac apps through the macOS accessibility API, so it only runs on macOS (this is $(uname -s))"
case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x64 ;;
  *) fail "unsupported CPU $(uname -m)" ;;
esac

version="${MX_VERSION:-}"
if [ -z "$version" ]; then
  # releases/latest redirects to .../releases/tag/<version>.
  version=$(curl -fsSI --connect-timeout 4 "https://github.com/$repo/releases/latest" 2>/dev/null |
    sed -n 's|^[Ll]ocation: .*/releases/tag/\([^[:space:]]*\).*|\1|p' | head -n 1 || true)
fi
if [ -z "$version" ]; then
  version=$(dl -sS "https://api.github.com/repos/$repo/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
fi
[ -n "$version" ] || fail "couldn't find the latest release"

base="https://github.com/$repo/releases/download/$version"
name="mx_darwin_$arch.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading mx $version for darwin/$arch"
dl --progress-bar -o "$tmp/$name" "$base/$name" || fail "couldn't download $name for $version"
echo "Downloading checksums"
dl -sS -o "$tmp/checksums.txt" "$base/checksums.txt" || fail "couldn't download checksums.txt for $version"

want=$(grep " $name\$" "$tmp/checksums.txt" | cut -d' ' -f1)
[ -n "$want" ] || fail "no checksum listed for $name"
[ "$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)" = "$want" ] || fail "checksum mismatch for $name; not installing"
echo "Checksum verified"

tar -xzf "$tmp/$name" -C "$tmp"
[ -f "$tmp/bin/mx" ] || fail "$name has no bin/mx"
mkdir -p "$dir"
install -m 0755 "$tmp/bin/mx" "$dir/mx"
echo "Installed $dir/mx"

case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH, for example: export PATH=\"$dir:\$PATH\"" ;;
esac

# doctor exits 1 until Accessibility is granted; that's expected on a first install.
echo
"$dir/mx" doctor || true
