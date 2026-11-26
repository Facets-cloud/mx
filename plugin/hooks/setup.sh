#!/bin/sh
# mx plugin setup. Claude Code runs it in the background when a session
# starts, so the first mx call doesn't wait for a download. bin/mx runs it
# with `path` to learn where the binary goes, and with `cli` to install it
# when the hook hasn't yet.
#
# The binary is the plugin's own release (the version in plugin.json),
# installed by the install.sh beside this file, which checks the release's
# checksums. It goes in a folder per version, by default
# ~/Library/Application Support/mx/plugin/v<version>, so a plugin update
# brings the matching mx (mx doesn't update itself) and never touches an mx
# the user installed in ~/.local/bin. MX_INSTALL_DIR overrides the folder.
# The hook stays quiet: it must never get in the session's way.
mode=${1:-session}
here=$(cd "$(dirname "$0")" && pwd)
version=v$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$here/../.claude-plugin/plugin.json" | head -n 1)
dir=${MX_INSTALL_DIR:-$HOME/Library/Application Support/mx/plugin/$version}
bin=$dir/mx
[ "$mode" = path ] && { echo "$bin"; exit 0; }

if [ ! -x "$bin" ]; then
  # Install into a scratch folder, then rename into place, so a launcher
  # racing this hook never runs a half-written binary.
  mkdir -p "$dir" || exit 1
  tmp=$(mktemp -d "$dir/.install.XXXXXX") || exit 1
  if [ "$mode" = cli ]; then
    MX_VERSION=$version MX_INSTALL_DIR=$tmp sh "$here/install.sh" >&2
  else
    MX_VERSION=$version MX_INSTALL_DIR=$tmp sh "$here/install.sh" >/dev/null 2>&1
  fi
  ok=$?
  [ $ok -eq 0 ] && mv -f "$tmp/mx" "$bin"
  ok=$?
  rm -rf "$tmp"
  [ "$mode" = cli ] && exit $ok
fi
exit 0
