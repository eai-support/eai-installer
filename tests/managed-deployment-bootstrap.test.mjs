import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const isWindows = process.platform === "win32";
const bootstrapPath = join(repositoryRoot, "scripts", isWindows ? "bootstrap.ps1" : "bootstrap.sh");
const missingCliPattern = isWindows
  ? /Missing EAI CLI[\s\S]*-AutoInstall/
  : /Missing eai\. Re-run with EAI_SETUP_AUTO_INSTALL=1/;

async function writeExecutable(path, source) {
  await writeFile(path, `#!/bin/sh\nset -eu\n${source}\n`);
  await chmod(path, 0o755);
}

async function createBootstrapHarness({ version, deployReady, sourceReady = deployReady, autoInstall = false }) {
  const root = await mkdtemp(join(tmpdir(), "eai-installer-managed-deploy-"));
  const bin = join(root, "bin");
  await mkdir(bin);

  if (isWindows) {
    const fixtures = {
      git: 'if "%~1"=="--version" echo git version 2.45.0\nexit /b 0',
      node: 'if "%~1"=="-p" (echo 24 & exit /b 0)\nif "%~1"=="--version" (echo v24.8.0 & exit /b 0)\nexit /b 1',
      npm: 'if "%~1"=="--version" (echo 10.9.0 & exit /b 0)\necho %*>> "%EAI_TEST_NPM_LOG%"\nexit /b 0',
      eai: `echo %*>> "%EAI_TEST_EAI_LOG%"
if "%~1"=="--version" (echo ${version} & exit /b 0)
if "%~1"=="deploy" if "%~2"=="app" if "%~3"=="--help" (echo ${sourceReady ? "--source ^<choice^> --github-link-session ^<id^>" : "--repo ^<owner/name^>"} & exit /b ${deployReady ? 0 : 7})
exit /b 1`,
    };
    for (const [name, source] of Object.entries(fixtures)) {
      await writeFile(join(bin, `${name}.cmd`), `@echo off\n${source}\n`.replaceAll("\n", "\r\n"));
    }
  } else {
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
      `printf "%s\\n" "$*" >> "$EAI_TEST_EAI_LOG"
if [ "\${1:-}" = "--version" ]; then echo "${version}"; exit 0; fi
if [ "\${1:-}" = "deploy" ] && [ "\${2:-}" = "app" ] && [ "\${3:-}" = "--help" ]; then echo "${sourceReady ? "--source <choice> --github-link-session <id>" : "--repo <owner/name>"}"; exit ${deployReady ? 0 : 7}; fi
exit 1`,
    );
  }

  const npmLog = join(root, "npm.log");
  const eaiLog = join(root, "eai.log");
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(([key]) => key.toUpperCase() !== "PATH"),
  );
  const inheritedPath = Object.entries(process.env).find(([key]) => key.toUpperCase() === "PATH")?.[1];
  const shell = isWindows ? "pwsh.exe" : "/bin/bash";
  const args = isWindows
    ? ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", bootstrapPath]
    : [bootstrapPath];
  const run = spawnSync(shell, args, {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {
      ...environment,
      EAI_SETUP_AUTO_INSTALL: autoInstall ? "1" : "0",
      EAI_TEST_EAI_LOG: eaiLog,
      EAI_TEST_NPM_LOG: npmLog,
      PATH: isWindows ? `${bin}${delimiter}${inheritedPath ?? ""}` : `${bin}:/usr/bin:/bin`,
    },
  });
  if (run.error) {
    await rm(root, { recursive: true, force: true });
    throw run.error;
  }
  return { root, eaiLog, npmLog, run };
}

test("accepts the minimum CLI only when managed deployment is executable", async () => {
  const harness = await createBootstrapHarness({ version: "3.18.0", deployReady: true });
  try {
    assert.equal(harness.run.status, 0, harness.run.stderr);
    assert.match(harness.run.stdout, /^(?:EAI CLI: )?3\.18\.0\s*$/m);
    assert.match(harness.run.stdout, /Use 'eai deploy app --help' when you are ready to choose hosting/);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
    assert.deepEqual((await readFile(harness.eaiLog, "utf8")).trim().split(/\r?\n/), [
      "--version",
      "deploy app --help",
    ]);
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("does not reinstall an already capable CLI when automatic installation is allowed", async () => {
  const harness = await createBootstrapHarness({ version: "3.18.0", deployReady: true, autoInstall: true });
  try {
    assert.equal(harness.run.status, 0, harness.run.stderr);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("rejects a pre-managed-deploy CLI without silently replacing it", async () => {
  const harness = await createBootstrapHarness({ version: "3.17.9", deployReady: true });
  try {
    assert.equal(harness.run.status, 1, harness.run.stderr);
    assert.match(harness.run.stderr, missingCliPattern);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("rejects a compatible version when the deploy command is unavailable", async () => {
  const harness = await createBootstrapHarness({ version: "3.18.0", deployReady: false });
  try {
    assert.equal(harness.run.status, 1, harness.run.stderr);
    assert.match(harness.run.stderr, missingCliPattern);
    await assert.rejects(readFile(harness.npmLog, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(harness.root, { recursive: true, force: true });
  }
});

test("rejects customer-only CLI help that lacks source choice and GitHub-link handoff", async () => {
  const harness = await createBootstrapHarness({ version: "3.18.0", deployReady: true, sourceReady: false });
  try {
    assert.equal(harness.run.status, 1, harness.run.stderr);
    assert.match(harness.run.stderr, missingCliPattern);
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
