import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { verifyInstalledCliPackage } from "../scripts/verify-published-cli.mjs";

async function createCliFixture({ version = "3.17.0", help = "--source --github-link-session --target-tenant-id" } = {}) {
  const root = await mkdtemp(join(tmpdir(), "eai-installer-published-cli-"));
  const dist = join(root, "dist");
  await mkdir(dist);
  await writeFile(join(root, "package.json"), `${JSON.stringify({
    name: "@enterpriseai/cli",
    version,
    type: "module",
    bin: { eai: "dist/index.js" },
  }, null, 2)}\n`);
  await writeFile(join(dist, "index.js"), `
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "--version") console.log(${JSON.stringify(version)});
else if (args.join(" ") === "deploy app --help") console.log(${JSON.stringify(help)});
else process.exitCode = 2;
`);
  return root;
}

test("accepts an exact published package with the managed deployment capability", async () => {
  const fixture = await createCliFixture();
  try {
    const result = await verifyInstalledCliPackage(fixture, "3.17.0");
    assert.equal(result.version, "3.17.0");
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects a package that predates the released baseline", async () => {
  const fixture = await createCliFixture({ version: "3.16.99" });
  try {
    await assert.rejects(verifyInstalledCliPackage(fixture, "3.17.0"), /below the Installer minimum/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects a version-compatible package without the complete managed deployment command", async () => {
  const fixture = await createCliFixture({ help: "--source --target-tenant-id" });
  try {
    await assert.rejects(verifyInstalledCliPackage(fixture, "3.17.0"), /lacks --github-link-session/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});
