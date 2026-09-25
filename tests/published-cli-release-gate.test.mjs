import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { verifyInstalledCliPackage } from "../scripts/verify-published-cli.mjs";

async function createCliFixture({ version = "3.17.0", versionOutput = version, help = "--source --github-link-session --target-tenant-id", bin = { eai: "dist/index.js" } } = {}) {
  const root = await mkdtemp(join(tmpdir(), "eai-installer-published-cli-"));
  const dist = join(root, "dist");
  await mkdir(dist);
  await writeFile(join(root, "package.json"), `${JSON.stringify({
    name: "@enterpriseai/cli",
    version,
    type: "module",
    bin,
  }, null, 2)}\n`);
  await writeFile(join(dist, "index.js"), `
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "--version") console.log(${JSON.stringify(versionOutput)});
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

test("rejects npm bin shorthand without the required eai command name", async () => {
  const fixture = await createCliFixture({ bin: "dist/index.js" });
  try {
    await assert.rejects(verifyInstalledCliPackage(fixture, "3.17.0"), /does not declare a relative eai executable/);
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

test("rejects a package whose managed deployment command cannot bind the target tenant", async () => {
  const fixture = await createCliFixture({ help: "--source --github-link-session" });
  try {
    await assert.rejects(verifyInstalledCliPackage(fixture, "3.17.0"), /lacks --target-tenant-id/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects lookalike option names", async () => {
  const fixture = await createCliFixture({
    help: "--source-path --github-link-session-token --target-tenant-id-alias",
  });
  try {
    await assert.rejects(verifyInstalledCliPackage(fixture, "3.17.0"), /lacks --source/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("rejects extra or mismatched version text", async () => {
  const fixture = await createCliFixture({ versionOutput: "wrapper 3.17.0; actual runtime 3.16.0" });
  try {
    await assert.rejects(verifyInstalledCliPackage(fixture, "3.17.0"), /executable version does not match/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});
