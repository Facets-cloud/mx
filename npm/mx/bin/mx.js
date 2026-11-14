#!/usr/bin/env node
// Runs the mx binary from the platform package npm installed alongside this
// one (@facets-cloud/mx-darwin-<cpu>), passing arguments, stdio and the exit code
// through. With no arguments mx is an MCP server on this same stdio.
"use strict";
const { spawn } = require("node:child_process");

const pkg = `@facets-cloud/mx-${process.platform}-${process.arch}`;
let bin;
try {
  bin = require.resolve(`${pkg}/bin/mx`);
} catch (err) {
  if (err.code !== "MODULE_NOT_FOUND") throw err;
  console.error(`mx: no build for ${process.platform}-${process.arch} (looked for ${pkg}). mx supports macOS on arm64 and x64.`);
  process.exit(1);
}

const child = spawn(bin, process.argv.slice(2), { stdio: "inherit" });
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => child.kill(sig));
}
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
