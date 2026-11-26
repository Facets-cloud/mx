// Runs make-signing-cert.sh into a temporary folder and checks the certificate
// `mcpb sign` gets: who it names, what it may sign, how long it lasts, and the
// fingerprint line the install page publishes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const script = join(dirname(fileURLToPath(import.meta.url)), "make-signing-cert.sh");
const openssl = (...args) => execFileSync("openssl", args, { encoding: "utf8" });

test("makes one long-lived code-signing certificate and prints its fingerprint",
  { skip: process.platform === "win32" && "bash script" }, () => {
    const out = join(mkdtempSync(join(tmpdir(), "mx-mcpb-cert-")), "signing");
    const stdout = execFileSync(script, [out], { encoding: "utf8" });
    const cert = join(out, "cert.pem");

    assert.equal(statSync(out).mode & 0o777, 0o700);
    assert.equal(statSync(join(out, "key.pem")).mode & 0o777, 0o600);
    assert.match(openssl("x509", "-in", cert, "-noout", "-subject"), /CN ?= ?mx \(Facets Cloud\)/);
    assert.match(openssl("x509", "-in", cert, "-noout", "-ext", "extendedKeyUsage"), /Code Signing/);
    // Valid for at least 19 more years.
    assert.equal(spawnSync("openssl", ["x509", "-in", cert, "-noout", "-checkend", String(19 * 365 * 86400)]).status, 0);

    // The fingerprint as mcpb verify prints it: SHA-256 of the DER, lowercase hex.
    const der = execFileSync("openssl", ["x509", "-in", cert, "-outform", "der"]);
    const want = execFileSync("openssl", ["dgst", "-sha256", "-r"], { input: der, encoding: "utf8" }).split(" ")[0];
    assert.ok(stdout.includes(want), stdout);

    // A second run never replaces it.
    const again = spawnSync(script, [out], { encoding: "utf8" });
    assert.notEqual(again.status, 0);
    assert.match(again.stderr, /already exists/);
  });
