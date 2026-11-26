# mx plugin for Claude Code

This plugin puts the `mx` CLI on Claude Code's PATH and adds the `mx` skill,
which teaches the agent the commands, how to work in few calls, which mode
to pick and when to ask before it sends or deletes anything. It starts no
MCP server.

```sh
claude plugin marketplace add Facets-cloud/mx
claude plugin install mx@mx
```

Restart Claude Code. When a session starts, the plugin downloads the mx
release that matches its version into
`~/Library/Application Support/mx/plugin/v<version>/`, checking the
release's checksums. An `mx` you installed yourself (say in `~/.local/bin`)
comes first on PATH and is used instead. Then turn on Accessibility (and
Screen Recording, for screenshots) for the app Claude Code runs in, in
System Settings > Privacy & Security. `mx doctor` says what is missing.

Claude Code asks before each `mx` command. A rule like `Bash(mx snapshot:*)`
in your permissions allows one command; `Bash(mx:*)` allows all of them,
sends and deletes included, so prefer the narrow ones.

Codex loads the same folder through `.codex-plugin/plugin.json`, which still
runs the MCP server with `npx -y @facets-cloud/mx`. See
[docs/PLUGIN-CLI.md](../docs/PLUGIN-CLI.md) for why, and the
[main README](https://github.com/Facets-cloud/mx#readme) for the rest.
