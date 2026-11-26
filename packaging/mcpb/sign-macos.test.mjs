// scripts/sign-macos.sh without the signing secret: it signs every slice of a
// universal binary ad hoc with the fixed identifier, and warns. Also
// scripts/make-signing-identity.sh: what the "mx" certificate is, and that it
// never replaces one. The signed path needs a keychain, so the release build
// and the steps in docs/PLUGIN-CLI.md check it, not this test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, statSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scripts = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "scripts");
const mac = process.platform === "darwin" ? false : "macOS only";

test("without MX_SIGNING_P12, signs both slices ad hoc as cloud.facets.mx and warns", { skip: mac }, () => {
  // /usr/bin/true is universal, like the mx that release.yml makes with lipo.
  const f = join(mkdtempSync(join(tmpdir(), "mx-sign-")), "mx");
  copyFileSync("/usr/bin/true", f);
  const env = { ...process.env };
  delete env.MX_SIGNING_P12;
  const r = spawnSync(join(scripts, "sign-macos.sh"), [f], { encoding: "utf8", env });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /MX_SIGNING_P12 not set, signing .* ad hoc/);
  const archs = execFileSync("lipo", ["-archs", f], { encoding: "utf8" }).trim().split(/\s+/);
  assert.ok(archs.length >= 2, archs.join(" "));
  for (const arch of archs) {
    const info = spawnSync("codesign", ["-dvv", "--arch", arch, f], { encoding: "utf8" }).stderr;
    assert.match(info, /^Identifier=cloud\.facets\.mx$/m, arch);
    assert.match(info, /^Signature=adhoc$/m, arch);
  }
});

test("makes the \"mx\" code-signing identity once and prints the secrets to set", { skip: mac }, () => {
  const out = join(mkdtempSync(join(tmpdir(), "mx-identity-")), "mx-signing");
  const stdout = execFileSync(join(scripts, "make-signing-identity.sh"), [out], { encoding: "utf8" });
  assert.equal(statSync(out).mode & 0o777, 0o700);
  for (const f of ["mx-signing.p12", "mx-signing.p12.password", "mx-signing.cer"]) {
    assert.equal(statSync(join(out, f)).mode & 0o777, 0o600, f);
  }
  const x509 = (...a) => execFileSync("/usr/bin/openssl", ["x509", "-inform", "der", "-in", join(out, "mx-signing.cer"), "-noout", ...a], { encoding: "utf8" });
  assert.match(x509("-subject"), /CN ?= ?mx/);
  assert.match(x509("-subject"), /O ?= ?Facets/);
  assert.match(x509("-text"), /Code Signing/);
  assert.match(x509("-text"), /Public-Key: \(3072 bit\)/);
  assert.equal(spawnSync("/usr/bin/openssl", ["x509", "-inform", "der", "-in", join(out, "mx-signing.cer"), "-noout", "-checkend", String(19 * 365 * 86400)]).status, 0);
  // The .p12 opens with its password, under the name "mx".
  const p12 = execFileSync("/usr/bin/openssl", ["pkcs12", "-in", join(out, "mx-signing.p12"), "-nokeys", "-passin", `file:${join(out, "mx-signing.p12.password")}`], { encoding: "utf8" });
  assert.match(p12, /friendlyName: mx/);
  assert.match(stdout, /gh secret set MX_SIGNING_P12 -R Facets-cloud\/mx/);
  assert.match(stdout, /gh secret set MX_SIGNING_P12_PASSWORD -R Facets-cloud\/mx/);

  const again = spawnSync(join(scripts, "make-signing-identity.sh"), [out], { encoding: "utf8" });
  assert.notEqual(again.status, 0);
  assert.match(again.stderr, /already exists/);
});
