#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runner = path.join(root, "scripts", "release-e2e.mjs");
const releaseShell = fs.readFileSync(path.join(root, "release.sh"), "utf8");
const runnerSource = fs.readFileSync(runner, "utf8");
const output = fs.mkdtempSync(path.join(os.tmpdir(), "eai-installer-release-contract-"));

assert.match(releaseShell, /patch\|minor\|major/);
assert.match(releaseShell, /release PR/);
assert.match(releaseShell, /git push origin "\$tag"/);
assert.doesNotMatch(releaseShell, /git push origin main/);
assert.doesNotMatch(releaseShell, /--mock|mock-assets|allow-mock-cleanup/);
assert.doesNotMatch(runnerSource, /mockPayloadState|mock-app-deprovision|mock installer asset/);
assert.doesNotMatch(runnerSource, /options\.mock|driver === "mock"|mode === "mock"/);
assert.equal(fs.existsSync(path.join(root, "scripts", "mock-app-deprovision.mjs")), false);
assert.match(runnerSource, /EAI_HARNESS_TENANT_ID/);
assert.match(runnerSource, /EAI_APP_DEPROVISION_COMMAND/);
assert.match(runnerSource, /EAI_VM_\$\{vm\.toUpperCase\(\)\}_COMMAND/);
assert.match(runnerSource, /EAI_VM_APP_STATE_FILE/);
assert.match(runnerSource, /EAI_HARNESS_USER_EMAIL/);
assert.match(runnerSource, /cleanupVerified !== true/);
assert.match(runnerSource, /receipt\.source !== "public-api-v4"/);
assert.match(runnerSource, /receipt\.operationId/);
assert.match(runnerSource, /receipt\.deletedRecords/);
assert.match(runnerSource, /EAI_DEPROVISION_APP_CREATED/);
assert.match(runnerSource, /receipt\.appCreated !== appCreated/);
assert.match(runnerSource, /requiredChecks = \["download", "installer", "prerequisites", "authentication", "tenant", "app", "project"\]/);

const dryRun = execFileSync(process.execPath, [runner, "--version", "0.2.0", "--dry-run"], {
  cwd: root,
  encoding: "utf8",
});
assert.match(dryRun, /eai-setup-macos-arm64\.dmg/);
assert.match(dryRun, /eai-setup-windows-arm64\.exe/);
assert.match(dryRun, /eai-setup-ubuntu-arm64\.deb/);

const cleanEnvironment = { ...process.env };
for (const key of [
  "EAI_HARNESS_TENANT_ID",
  "EAI_APP_DEPROVISION_COMMAND",
  "EAI_VM_MACOS_COMMAND",
  "EAI_VM_WINDOWS_COMMAND",
  "EAI_VM_UBUNTU_COMMAND",
  "EAI_VM_TEST_COMMAND",
]) delete cleanEnvironment[key];
const blocked = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "blocked"), "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: cleanEnvironment,
});
assert.equal(blocked.status, 1);
assert.match(blocked.stderr, /EAI_HARNESS_TENANT_ID is required/);
assert.doesNotMatch(blocked.stderr, /mock/i);

const shellSyntax = execFileSync("bash", ["-n", path.join(root, "release.sh")], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(shellSyntax, "");

console.log("live release gate contract checks ok");
