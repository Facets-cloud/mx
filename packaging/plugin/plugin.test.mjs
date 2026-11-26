// The Claude Code plugin's way to the CLI: bin/mx and hooks/setup.sh. A stub
// install.sh and npx stand in for the network, so these check the wiring:
// which mx runs, when setup installs, the npx fallback. The rest checks what
// the plugin ships: no MCP server for Claude Code, the installer copy, the skill.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");
const plugin = join(repo, "plugin");
const version = "v" + JSON.parse(readFileSync(join(plugin, ".claude-plugin/plugin.json"))).version;

// A copy of the plugin whose install.sh logs how it was called and, unless
// told to fail, installs an mx that prints its arguments and exits with
// $MX_STUB_EXIT.
function rig({ installFails = false } = {}) {
  const t = mkdtempSync(join(tmpdir(), "mx-plugin-"));
  const out = join(t, "plugin");
  cpSync(plugin, out, { recursive: true });
  const log = join(t, "install.log");
  writeFileSync(
    join(out, "hooks/install.sh"),
    `echo "$MX_VERSION" >>"${log}"\n` +
      (installFails
        ? "exit 1\n"
        : `mkdir -p "$MX_INSTALL_DIR"\nprintf '#!/bin/sh\\necho "mx $*"\\nexit \${MX_STUB_EXIT:-0}\\n' >"$MX_INSTALL_DIR/mx"\nchmod +x "$MX_INSTALL_DIR/mx"\necho "Installed $MX_INSTALL_DIR/mx"\n`),
  );
  const fakes = join(t, "fakes");
  mkdirSync(fakes);
  writeFileSync(join(fakes, "npx"), '#!/bin/sh\necho "npx $*"\n', { mode: 0o755 });
  // HOME is the temp dir and MX_INSTALL_DIR is unset, so the default folder is tested.
  const env = { PATH: `${fakes}:/usr/bin:/bin`, HOME: t };
  const bin = join(t, "Library/Application Support/mx/plugin", version, "mx");
  return { t, out, log, env, bin };
}

const run = (cmd, args, env) => spawnSync(cmd, args, { encoding: "utf8", env });
const installs = (log) => (existsSync(log) ? readFileSync(log, "utf8") : "");

test("an mx the user installed comes first on PATH, so the launcher never runs", () => {
  const { t, out, log, env } = rig();
  const user = join(t, "user");
  mkdirSync(user);
  writeFileSync(join(user, "mx"), '#!/bin/sh\necho "user mx $*"\n', { mode: 0o755 });
  // Claude Code appends the plugin's bin/ after the user's PATH.
  const r = run("sh", ["-c", "mx --version"], { ...env, PATH: `${user}:${env.PATH}:${join(out, "bin")}` });
  assert.equal(r.stdout, "user mx --version\n");
  assert.equal(installs(log), "");
});

test("bin/mx installs the plugin's release on first use, then runs it with the same args and exit code", () => {
  const { out, log, env, bin } = rig();
  const r = run(join(out, "bin/mx"), ["snapshot", "--app", "Finder"], env);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "mx snapshot --app Finder\n", "install output stays off stdout");
  assert.match(r.stderr, /Installed /);
  assert.equal(installs(log), `${version}\n`);
  assert.ok(existsSync(bin), bin);
  const again = run(join(out, "bin/mx"), ["click", "--ref", "e1"], { ...env, MX_STUB_EXIT: "3" });
  assert.equal(again.status, 3);
  assert.equal(again.stdout, "mx click --ref e1\n");
  assert.equal(installs(log), `${version}\n`, "installs only once");
});

test("bin/mx honours MX_INSTALL_DIR", () => {
  const { t, out, env } = rig();
  const dir = join(t, "custom");
  assert.equal(run("sh", [join(out, "hooks/setup.sh"), "path"], { ...env, MX_INSTALL_DIR: dir }).stdout, `${dir}/mx\n`);
  run(join(out, "bin/mx"), ["--version"], { ...env, MX_INSTALL_DIR: dir });
  assert.ok(existsSync(join(dir, "mx")));
});

test("bin/mx falls back to npx when the install fails", () => {
  const { out, env } = rig({ installFails: true });
  const r = run(join(out, "bin/mx"), ["list_apps", "--json"], env);
  assert.equal(r.stdout, "npx -y @facets-cloud/mx list_apps --json\n");
});

test("the SessionStart hook runs setup in the background", () => {
  const hooks = JSON.parse(readFileSync(join(plugin, "hooks/hooks.json"))).hooks;
  assert.deepEqual(Object.keys(hooks), ["SessionStart"]);
  const h = hooks.SessionStart[0].hooks[0];
  assert.equal(h.async, true);
  assert.equal(h.command, 'sh "${CLAUDE_PLUGIN_ROOT}/hooks/setup.sh"');
});

test("setup installs once, quietly, and stays quiet when the install fails", () => {
  const { out, log, env, bin } = rig();
  for (let i = 0; i < 2; i++) {
    const r = run("sh", [join(out, "hooks/setup.sh")], env);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout + r.stderr, "");
  }
  assert.equal(installs(log), `${version}\n`, "idempotent");
  assert.ok(existsSync(bin));
  const bad = rig({ installFails: true });
  const r = run("sh", [join(bad.out, "hooks/setup.sh")], bad.env);
  assert.equal(r.status, 0);
  assert.equal(r.stdout + r.stderr, "");
  assert.equal(run("sh", [join(bad.out, "hooks/setup.sh"), "cli"], bad.env).status, 1);
});

test("the plugin's install.sh is site/install.sh", () => {
  assert.equal(
    readFileSync(join(plugin, "hooks/install.sh"), "utf8"),
    readFileSync(join(repo, "site/install.sh"), "utf8"),
    "copy site/install.sh to plugin/hooks/install.sh",
  );
});

test("Claude Code loads no MCP server from the plugin; Codex still does", () => {
  assert.ok(!existsSync(join(plugin, ".mcp.json")), "Claude Code always loads a plugin's root .mcp.json");
  assert.equal(JSON.parse(readFileSync(join(plugin, ".claude-plugin/plugin.json"))).mcpServers, undefined);
  const codex = JSON.parse(readFileSync(join(plugin, ".codex-plugin/plugin.json")));
  assert.match(codex.mcpServers, /^\.\/[^/]+\.json$/);
  assert.notEqual(codex.mcpServers, "./.mcp.json");
  const servers = JSON.parse(readFileSync(join(plugin, codex.mcpServers))).mcpServers;
  assert.deepEqual(servers.mx, { command: "npx", args: ["-y", "@facets-cloud/mx"] });
});

test("the skill teaches the CLI, with MCP only as the no-shell fallback", () => {
  const skill = readFileSync(join(plugin, "skills/mx/SKILL.md"), "utf8");
  assert.ok(skill.length <= 13200, `${skill.length} chars`);
  for (const s of ["mx --help", "mx snapshot --app", "--args -", "--confirm", "--out", "mx stop", "mx doctor"]) {
    assert.ok(skill.includes(s), s);
  }
  assert.doesNotMatch(skill, /mcp__/);
  assert.equal(skill.match(/\bMCP\b/g)?.length ?? 0, 1, "MCP is named once, in the no-shell line");
});
