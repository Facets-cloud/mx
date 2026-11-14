# mx plugin for Claude Code

This plugin adds the mx MCP server (run with `npx -y @facets-cloud/mx`) and the `mx`
skill, which tells the agent how to work in few calls, which mode to pick and
when to ask before it sends or deletes anything.

```sh
claude plugin marketplace add Facets-cloud/mx
claude plugin install mx@mx
```

Restart Claude Code, then turn on Accessibility (and Screen Recording, for
screenshots) for the app Claude Code runs in, in System Settings > Privacy &
Security. `npx -y @facets-cloud/mx doctor` says what is missing. See the
[main README](https://github.com/Facets-cloud/mx#readme) for the rest.
