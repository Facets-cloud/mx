// Builds mx.mcpb, the Claude Desktop extension, from a universal mx binary:
//
//   node packaging/mcpb/build.mjs <version> <universal-binary> <out-dir>
//
// <universal-binary> is the arm64 + x86_64 mx that release.yml makes with
// `lipo -create`, so the bundle needs no launcher to pick a CPU. <out-dir>
// gets mx-<version>.mcpb and an identical mx.mcpb, so
// releases/latest/download/mx.mcpb is a stable link.
//
// A .mcpb is a zip with manifest.json at its root (spec:
// github.com/modelcontextprotocol/mcpb, MANIFEST.md). It runs `mx` with no
// arguments, which is the MCP server on stdio, so users need neither Node nor
// a terminal. mx has no self-update: users update by installing the next
// .mcpb.
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** The manifest.json for `version` (no leading v). */
export function manifest(version) {
  const plugin = JSON.parse(readFileSync(join(root, "plugin", ".claude-plugin", "plugin.json"), "utf8"));
  return {
    manifest_version: "0.3",
    name: "mx",
    display_name: "mx",
    version,
    description: plugin.description,
    long_description:
      "mx lets Claude run its steps inside the Mac apps you already have open and signed in to, through the macOS accessibility API. It works in the background by default, sends nothing over the network and has no telemetry.\n\n" +
      "**Before you start:** mx needs macOS 14 or later. Claude Desktop runs mx as its own app, so in System Settings > Privacy & Security give **Accessibility** to mx itself, not Claude (every tool except `list_apps`, `start` and `done` needs it), and **Screen Recording** too if you want screenshots. The file is `~/Library/Application Support/Claude/Claude Extensions/local.mcpb.facets-cloud.mx/server/mx`; mx's doctor tool names it and gives the steps. Then quit Claude with Cmd+Q and reopen it.",
    author: { name: "Facets Cloud", url: "https://github.com/Facets-cloud" },
    homepage: "https://facets-cloud.github.io/mx/",
    documentation: "https://github.com/Facets-cloud/mx#readme",
    support: "https://github.com/Facets-cloud/mx/issues",
    repository: { type: "git", url: "https://github.com/Facets-cloud/mx" },
    license: "MIT",
    icon: "icon.png",
    keywords: ["mac", "macos", "accessibility", "automation", "apps"],
    server: {
      type: "binary",
      entry_point: "server/mx",
      // MX_MCPB=1 tells mx it runs inside the bundle, where a missing permission
      // goes to mx itself, so its errors name its own path (grantSteps in Tools.swift).
      mcp_config: { command: "${__dirname}/server/mx", args: [], env: { MX_MCPB: "1" } },
    },
    compatibility: { platforms: ["darwin"] },
  };
}

/** Writes both bundles for `version` into `outDir` and returns their paths. */
export function build(version, binary, outDir) {
  const v = version.replace(/^v/, "");
  const stage = mkdtempSync(join(tmpdir(), "mx-mcpb-"));
  try {
    mkdirSync(join(stage, "server"));
    copyFileSync(binary, join(stage, "server", "mx"));
    chmodSync(join(stage, "server", "mx"), 0o755);
    for (const f of ["LICENSE", "THIRD_PARTY_NOTICES"]) copyFileSync(join(root, f), join(stage, f));
    copyFileSync(join(root, "packaging", "mcpb", "icon.png"), join(stage, "icon.png"));
    writeFileSync(join(stage, "manifest.json"), JSON.stringify(manifest(v), null, 2) + "\n");

    mkdirSync(outDir, { recursive: true });
    // Absolute, because zip runs in the staging folder.
    const versioned = resolve(outDir, `mx-${v}.mcpb`);
    const stable = resolve(outDir, "mx.mcpb");
    rmSync(versioned, { force: true });
    // zip keeps each file's Unix mode, so mx stays executable once Claude
    // Desktop unpacks it. -D leaves out directory entries, which mcpb's
    // unpacker writes as files and fails on. -X leaves out other extra fields.
    execFileSync("zip", ["-qrDX", versioned, "."], { cwd: stage });
    copyFileSync(versioned, stable);
    return [versioned, stable];
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [version, binary, outDir] = process.argv.slice(2);
  if (!version || !binary || !outDir) {
    process.stderr.write("usage: node packaging/mcpb/build.mjs <version> <universal-binary> <out-dir>\n");
    process.exit(2);
  }
  for (const f of build(version, binary, outDir)) process.stdout.write(f + "\n");
}
