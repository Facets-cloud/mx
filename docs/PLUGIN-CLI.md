# The Claude Code plugin runs the CLI, not the MCP server

## Why

The mx MCP server costs every Claude Code session context and memory before
anyone mentions a Mac app:

- Its `tools/list` is 27.8k characters, about 7k tokens, loaded whenever the
  agent loads MCP schemas up front.
- Run through `npx -y @facets-cloud/mx`, it takes about 86 MB per session,
  72 MB of it Node.

The CLI costs nothing until the agent runs it. The skill (13.2k characters)
loads only when used.

## Claude Code (terminal and the Desktop app's Code tab)

The plugin has no `.mcp.json`, since Claude Code always loads a plugin's
root `.mcp.json`. It has:

- `bin/mx`. Claude Code puts a plugin's `bin/` on the Bash tool's PATH after
  the user's own entries, so an mx the user installed runs first. The
  launcher runs the plugin's own mx, installing it first if it is missing.
  If the install fails, it runs `npx -y @facets-cloud/mx`.
- `hooks/setup.sh`, run by an `async` SessionStart hook, so the first `mx`
  call doesn't wait for the download. It does nothing when the binary is
  there and prints nothing either way.
- `hooks/install.sh`, a copy of `site/install.sh` (plugins install from git,
  so no symlink). A test fails when the two differ. `setup.sh` pins
  `MX_VERSION` to the plugin's version from `plugin.json`, which the release
  script sets, so the CLI and the skill come from the same release and no
  GitHub lookup is needed.

The binary lives in `~/Library/Application Support/mx/plugin/v<version>/mx`
(`MX_INSTALL_DIR` overrides it). mx doesn't update itself, so a folder per
version means a plugin update brings the matching binary, and the plugin
never overwrites an mx the user installed in `~/.local/bin`. It isn't in
`${CLAUDE_PLUGIN_DATA}` because Claude Code doesn't set that variable for
the Bash tool, only for hooks, so the launcher couldn't find it.
Accessibility goes to the terminal app, not the binary, so the path doesn't
affect permissions. Old version folders stay behind (a few MB each).

setup.sh installs into a scratch folder and renames the binary into place,
so a launcher that runs while the hook is still downloading never runs a
half-written file.

The skill runs `mx <tool> --flags`. Without a shell, it says to use the MCP
tools of the same names.

Trade-offs:

- A plugin can't add permission rules. The user approves `mx` commands in
  Claude Code's prompt. `Bash(mx:*)` covers every command, clicks on Send
  included, where MCP approvals went tool by tool. Suggest prefix rules such
  as `Bash(mx snapshot:*)` and `Bash(mx list_apps:*)` instead. mx's own
  gates (exit 3 until `--confirm`) still apply.
- CI runners stay GitHub-hosted, since the repo is public.

## Other ways in

- **Claude Desktop, Chat tab:** `mx.mcpb`, the Desktop Extension. It runs
  the MCP server from the native binary, no Node.
- **Cowork:** not supported. Cowork refuses a plugin with a top-level `bin/`.
- **Codex** loads the same plugin folder. `.codex-plugin/plugin.json` points
  `mcpServers` at `codex-mcp.json`, which still runs
  `npx -y @facets-cloud/mx`. Claude Code doesn't read that file.
- **Cursor and other agents** keep the MCP server for now. Later each gets
  a SessionStart hook that installs the CLI, and then drops its MCP entry.
