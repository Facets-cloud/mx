#!/bin/sh
# End-to-end check of the plugin in a real, logged-in Claude Code, run with
# --plugin-dir (nothing is installed into your Claude config) and an empty
# --strict-mcp-config, so no mx MCP server can load. Every mx call is
# read-only: --version, list_apps and a Finder snapshot.
#
#   sh packaging/plugin/claude-e2e.sh
#
# 1. No mx on PATH: the launcher installs the plugin's release into a temp
#    MX_INSTALL_DIR and runs it. MX_E2E_VERSION (default v0.1.4) stands in
#    for the plugin's version, since a checkout's plugin.json may name a
#    release that isn't out yet.
# 2. This checkout's mx first on PATH (the user-installed case): the agent
#    follows the skill and runs `mx snapshot --app Finder` through the CLI.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
version=${MX_E2E_VERSION:-v0.1.4}
t=$(mktemp -d "${TMPDIR:-/tmp}/mx-claude-e2e.XXXXXX")
t=$(cd "$t" && pwd -P)
trap 'rm -rf "$t"' EXIT

# A plugin copy with the pinned version, and an empty MCP config.
cp -R "$repo/plugin" "$t/plugin"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"${version#v}\"/" "$t/plugin/.claude-plugin/plugin.json"
echo '{"mcpServers":{}}' >"$t/mcp.json"

# PATH without ~/.local/bin or any other mx. claude itself may live there.
claude=$(command -v claude)
path=
for d in $(echo "$PATH" | tr ':' ' '); do
  [ "$d" = "$HOME/.local/bin" ] && continue
  [ -x "$d/mx" ] && continue
  path=${path:+$path:}$d
done
export MX_INSTALL_DIR="$t/install" MX_SESSION="mx-claude-e2e-$$"

ask() { # output file, extra PATH entry, prompt
  (cd "$t" && PATH="${2:+$2:}$path" "$claude" -p "$3" \
    --plugin-dir "$t/plugin" --strict-mcp-config --mcp-config "$t/mcp.json" \
    --allowedTools "Bash(mx --version)" "Bash(mx list_apps)" "Bash(mx list_apps:*)" \
      "Bash(mx snapshot:*)" "Bash(command -v mx)" "Skill" "Read" \
    --output-format stream-json --verbose >"$1" 2>&1) || true
}

fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. The launcher installs the pinned release and runs it.
ask "$t/install.jsonl" "" \
  "Run exactly these shell commands, one Bash call each, and report each output: 'command -v mx', 'mx --version', 'mx list_apps'. Don't run anything else."
if [ -x "$MX_INSTALL_DIR/mx" ] && "$MX_INSTALL_DIR/mx" --version </dev/null | grep -q "${version#v}"; then
  ok "launcher installed mx $version into MX_INSTALL_DIR"
else
  bad "no mx $version in $MX_INSTALL_DIR"
fi
grep -q "$t/plugin/bin/mx" "$t/install.jsonl" && ok "the agent's mx was the plugin's bin/mx" || bad "bin/mx wasn't the mx on PATH"
grep -q '"mcp_servers":\[\]' "$t/install.jsonl" && ok "no MCP server loaded" || bad "an MCP server loaded"
grep -q "mx ${version#v}" "$t/install.jsonl" && ok "mx --version printed ${version#v}" || bad "mx --version output missing"
# v0.1.4 predates the CLI, so list_apps reaching it shows as its usage text (exit 2).
grep -q 'run the MCP server on stdio\|"is_error":false' "$t/install.jsonl" && ok "mx list_apps reached the installed mx" || bad "mx list_apps didn't run"

# 2. A user's mx (this checkout's build) wins, and the skill drives the CLI.
(cd "$repo" && swift build -c release >/dev/null)
own="$t/own"
mkdir -p "$own"
cp "$(cd "$repo" && swift build -c release --show-bin-path)/mx" "$own/mx"
ask "$t/cli.jsonl" "$own" \
  "Use the mx skill to list the controls in Finder's front window. Only read: run 'command -v mx' first, then 'mx snapshot --app Finder'. Don't click, type or change anything, and don't run start or done. Report the first 5 lines of the snapshot."
grep -q "$own/mx" "$t/cli.jsonl" && ok "the user's mx came first on PATH" || bad "the user's mx wasn't first"
grep -q 'mx snapshot --app Finder' "$t/cli.jsonl" && ok "the agent ran mx snapshot --app Finder" || bad "no mx snapshot call"
grep -Eq '\be[0-9]+ [a-z]+' "$t/cli.jsonl" && ok "the snapshot printed refs" || bad "no refs in the snapshot output"
"$own/mx" stop >/dev/null 2>&1 || true
"$MX_INSTALL_DIR/mx" stop </dev/null >/dev/null 2>&1 || true

[ "$fail" = 0 ] || { echo "transcripts kept in $t"; trap - EXIT; }
exit $fail
