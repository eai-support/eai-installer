import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const bootstrapPath = join(repositoryRoot, "scripts", "bootstrap.sh");

async function writeExecutable(path, source) {
  await writeFile(path, `#!/bin/sh\nset -eu\n${source}\n`);
  await chmod(path, 0o755);
}

async function createBootstrapHarness({ version, deployReady }) {
  const root = await mkdtemp(join(tmpdir(), "eai-installer-managed-deploy-"));
  const bin = join(root, "bin");
  await mkdir(bin);

  await writeExecutable(
    join(bin, "git"),
    'if [ "${1:-}" = "--version" ]; then echo "git version 2.45.0"; exit 0; fi\nexit 0',
  );
  await writeExecutable(
    join(bin, "node"),
    'if [ "${1:-}" = "-p" ]; then echo "24"; exit 0; fi\nif [ "${1:-}" = "--version" ]; then echo "v24.8.0"; exit 0; fi\nexit 1',
  );
  await writeExecutable(
    join(bin, "npm"),
    'if [ "${1:-}" = "--version" ]; then echo "10.9.0"; exit 0; fi\nprintf "%s\\n" "$*" >> "$EAI_TEST_NPM_LOG"\nexit 0',
  );
  await writeExecutable(
    join(bin, "eai"),
    `if [ "\${1:-}" = "--version" ]; then echo "${version}"; exit 0; fi
if [ "\${1:-}" = "deploy" ] && [ "\${2:-}" = "app" ] && [ "\${3:-}" = "--help" ]; then exit ${deployReady ? 0 : 7}; fi
exit 1`,
  );

  const npmLog = join(root, "npm.log");
  const run = spawnSync("/bin/bash", [bootstrapPath], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      EAI_SETUP_AUTO_INSTALL: "0",
      EAI_TEST_NPM_LOG: npmLog,
      PATH: `${bin}:/usr/bin:/bin`,
    },
  });
  return { root, npmLog, run };
}

test("accepts the minimum CLI only when managed deployment is executable", async () => {
  const harness = await createBootstrapHarness({ version: "3.18.0", deployReady: true });
  try {
    assert.equal(harness.run.status, 0, harness.run.stderr);
    assert.match(harness.run.stdout, /EAI CLI: 3\.18\.0/);
    assert.match(harness.run.stdout, /Use 'eai deploy app --help' when you are ready to choose hosting/);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("rejects a pre-managed-deploy CLI without silently replacing it", async () => {
  const harness = await createBootstrapHarness({ version: "3.17.9", deployReady: true });
  try {
    assert.equal(harness.run.status, 1);
    assert.match(harness.run.stderr, /Missing eai\. Re-run with EAI_SETUP_AUTO_INSTALL=1/);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("rejects a compatible version when the deploy command is unavailable", async () => {
  const harness = await createBootstrapHarness({ version: "3.18.0", deployReady: false });
  try {
    assert.equal(harness.run.status, 1);
    assert.match(harness.run.stderr, /Missing eai\. Re-run with EAI_SETUP_AUTO_INSTALL=1/);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("maps the executable bootstrap proof to both deployed contracts", async () => {
  const coverage = JSON.parse(
    await readFile(join(repositoryRoot, ".eai", "test-coverage.json"), "utf8"),
  );
  const feature = coverage.repositories["eai-installer"].features.find(
    ({ id }) => id === "managed-deployment-cli-bootstrap",
  );
  const contractPaths = feature.required_deployed_contracts.map(({ path }) => path);

  assert.ok(feature.owned_paths.includes("tests/managed-deployment-bootstrap.test.mjs"));
  assert.ok(feature.required_repo_tests.includes("tests/managed-deployment-bootstrap.test.mjs"));
  assert.ok(feature.required_cross_service_surfaces.includes("eai-managed-deploy"));
  assert.deepEqual(
    contractPaths.filter((path) => path.includes("eai-managed-deploy")),
    [
      "tests/cross-service/contracts/eai-cli/eai-managed-deploy.spec.ts",
      "tests/cross-service/contracts/eai-cli/eai-managed-deploy-mutation.spec.ts",
    ],
  );
});
