// Builds the bundle from a fake binary, then checks the manifest and the files
// and their modes inside the zip.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "./build.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// A shell script stands in for mx: it echoes its arguments.
function fakeBinary() {
  const f = join(mkdtempSync(join(tmpdir(), "mx-mcpb-in-")), "mx");
  writeFileSync(f, '#!/bin/sh\necho "mx $*"\n', { mode: 0o644 });
  return f;
}

function built(version = "v1.2.3") {
  const out = mkdtempSync(join(tmpdir(), "mx-mcpb-out-"));
  return { out, files: build(version, fakeBinary(), out) };
}

test("writes a versioned bundle and an identical mx.mcpb", () => {
  const { out, files } = built();
  assert.deepEqual(files, [join(out, "mx-1.2.3.mcpb"), join(out, "mx.mcpb")]);
  assert.ok(readFileSync(files[0]).equals(readFileSync(files[1])));
});

test("takes a relative out-dir, as release.yml passes dist", () => {
  const cwd = process.cwd();
  const work = mkdtempSync(join(tmpdir(), "mx-mcpb-rel-"));
  const input = fakeBinary();
  try {
    process.chdir(work);
    build("1.2.3", input, "dist");
    for (const f of ["mx-1.2.3.mcpb", "mx.mcpb"]) assert.ok(existsSync(join(work, "dist", f)), f);
  } finally {
    process.chdir(cwd);
  }
});

test("the manifest runs mx with no arguments from the bundled binary, on macOS only", () => {
  const { files } = built();
  const m = JSON.parse(execFileSync("unzip", ["-p", files[0], "manifest.json"]));
  const plugin = JSON.parse(readFileSync(join(root, "plugin", ".claude-plugin", "plugin.json")));
  assert.equal(m.manifest_version, "0.3");
  assert.equal(m.name, "mx");
  assert.equal(m.display_name, "mx");
  assert.equal(m.version, "1.2.3");
  assert.equal(m.description, plugin.description);
  assert.match(m.long_description, /Accessibility/);
  assert.match(m.long_description, /Screen Recording/);
  assert.equal(m.license, "MIT");
  assert.equal(m.server.type, "binary");
  assert.equal(m.server.entry_point, "server/mx");
  assert.deepEqual(m.server.mcp_config, { command: "${__dirname}/server/mx", args: [], env: { MX_MCPB: "1" } });
  assert.match(m.long_description, /mx itself, not Claude/);
  assert.deepEqual(m.compatibility, { platforms: ["darwin"] });
  assert.equal(m.icon, "icon.png");
});

test("carries mx and the legal files, mx kept executable, no directory entries", () => {
  const { files } = built();
  // zipinfo lines: "-rwxr-xr-x  3.0 unx  31 tx defN 26-Nov-26 10:00 server/mx"
  const modes = Object.fromEntries(
    execFileSync("zipinfo", [files[0]], { encoding: "utf8" })
      .split("\n")
      .filter((l) => /^[-d]/.test(l))
      .map((l) => [l.trim().split(/\s+/).at(-1), l.slice(0, 10)]),
  );
  assert.equal(modes["server/mx"], "-rwxr-xr-x");
  // No directory entries: mcpb's unpacker writes every entry as a file.
  assert.deepEqual(Object.keys(modes).sort(), ["LICENSE", "THIRD_PARTY_NOTICES", "icon.png", "manifest.json", "server/mx"]);
});

test("the unzipped command runs the bundled binary", () => {
  const { files } = built();
  const dir = mkdtempSync(join(tmpdir(), "mx-mcpb-x-"));
  execFileSync("unzip", ["-q", files[0], "-d", dir]);
  const r = spawnSync(join(dir, "server", "mx"), [], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "mx \n");
});
