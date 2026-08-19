#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runner = path.join(root, "scripts", "release-e2e.mjs");
const macosGuestPreparer = path.join(root, "scripts", "prepare-macos-guest-dmg.sh");
const releaseShell = fs.readFileSync(path.join(root, "release.sh"), "utf8");
const runnerSource = fs.readFileSync(runner, "utf8");
const macosGuestPreparerSource = fs.readFileSync(macosGuestPreparer, "utf8");
const releaseWorkflow = fs.readFileSync(path.join(root, ".github", "workflows", "release.yml"), "utf8");
const tauriConfig = JSON.parse(fs.readFileSync(path.join(root, "src-tauri", "tauri.conf.json"), "utf8"));
const output = fs.mkdtempSync(path.join(os.tmpdir(), "eai-installer-release-contract-"));

assert.match(releaseShell, /patch\|minor\|major/);
assert.match(releaseShell, /release PR/);
assert.match(releaseShell, /git push origin "\$tag"/);
assert.doesNotMatch(releaseShell, /git push origin main/);
assert.match(releaseShell, /diagnostic-e2e/);
assert.match(releaseShell, /publish-diagnostic/);
assert.match(releaseShell, /publish-test/);
const publishSection = releaseShell.slice(releaseShell.indexOf("publish_release"), releaseShell.indexOf("publish_diagnostic_release"));
assert.match(publishSection, /--deprovision api/);
assert.match(publishSection, /gh release edit "\$tag"[\s\S]*--draft=false/);
assert.doesNotMatch(publishSection, /EAI_DEPROVISION_MODE/);
const diagnosticPublishSection = releaseShell.slice(releaseShell.indexOf("publish_diagnostic_release"), releaseShell.indexOf("run_e2e"));
assert.match(diagnosticPublishSection, /--deprovision mock --diagnostic/);
const testPublishSection = releaseShell.slice(releaseShell.indexOf("publish_test_release"), releaseShell.indexOf("publish_diagnostic_release"));
assert.match(testPublishSection, /gh workflow run test-release\.yml/);
assert.match(testPublishSection, /eai-setup-test-v\$version/);
assert.match(testPublishSection, /--deprovision mock --diagnostic/);
assert.match(runnerSource, /diagnostic-only/);
assert.match(runnerSource, /source: "diagnostic-mock"/);
assert.match(runnerSource, /passed_with_mock_cleanup/);
assert.match(runnerSource, /cleanupVerified: false/);
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
assert.match(runnerSource, /requiredChecks = \["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"\]/);
for (const requiredSafetyCheck of [
  /EAI_VM_DOWNLOAD_URL must be a complete HTTP or HTTPS URL/,
  /The selected Parallels guest is not macOS/,
  /The macOS guest command is not running as the requested signed-in user/,
  /The macOS clean-machine test must not run as root/,
  /The DMG did not reach a stable, non-zero size/,
  /The guest DMG checksum does not match the CI artifact/,
  /hdiutil imageinfo/,
  /EAI_VM_ALLOW_UNSIGNED_TEST/,
  /READY_FOR_UI/,
]) {
  assert.match(macosGuestPreparerSource, requiredSafetyCheck);
}
assert.doesNotMatch(macosGuestPreparerSource, /Users\/[^/]+\/Downloads/);
assert.doesNotMatch(macosGuestPreparerSource, /Gubamute/);
assert.doesNotMatch(macosGuestPreparerSource, /-maxdepth/);
assert.match(macosGuestPreparerSource, /for app in "\$1"\/\*\.app/);
assert.match(macosGuestPreparerSource, /\[ -d "\$app" \]/);
assert.doesNotMatch(macosGuestPreparerSource, /guest \/usr\/bin\/open/);
assert.match(macosGuestPreparerSource, /dscl \. -read "\/Users\/\$actual_user" NFSHomeDirectory/);
assert.match(macosGuestPreparerSource, /The signed-in macOS user's home directory could not be resolved/);
assert.match(macosGuestPreparerSource, /guest \/bin\/test -d "\$actual_home"/);
assert.match(macosGuestPreparerSource, /launchctl asuser "\$actual_uid"[\s\\]*\/usr\/bin\/sudo -H -u "\$actual_user"/);
assert.match(macosGuestPreparerSource, /HOME="\$actual_home" USER="\$actual_user" LOGNAME="\$actual_user"/);
assert.match(macosGuestPreparerSource, /READY_FOR_UI.*mount=%s/);
assert.match(releaseWorkflow, /name: Install Linux build dependencies/);
for (const dependency of [
  "build-essential",
  "libayatana-appindicator3-dev",
  "libgtk-3-dev",
  "libssl-dev",
  "libwebkit2gtk-4.1-dev",
  "libxdo-dev",
  "librsvg2-dev",
  "patchelf",
]) {
  assert.match(releaseWorkflow, new RegExp(`\\b${dependency.replaceAll(".", "\\.")}\\b`));
}
assert.match(releaseWorkflow, /name: Require release signing configuration[\s\S]*WINDOWS_CERTIFICATE_PASSWORD/);
assert.match(releaseWorkflow, /Missing release secret WINDOWS_CERTIFICATE/);
assert.match(releaseWorkflow, /Missing release secret APPLE_CERTIFICATE/);
assert.match(releaseWorkflow, /name: Verify Authenticode signature/);
assert.match(releaseWorkflow, /releaseDraft: true/);
assert.doesNotMatch(releaseWorkflow, /TAURI_SIGNING_PRIVATE_KEY/);
assert.equal(tauriConfig.bundle?.windows?.nsis?.installMode, "currentUser");

const dryRun = execFileSync(process.execPath, [runner, "--version", "0.2.0", "--dry-run"], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, EAI_RELEASE_VMS: "" },
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
  "EAI_RELEASE_VMS",
]) delete cleanEnvironment[key];
const blocked = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "blocked"), "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: cleanEnvironment,
});
assert.equal(blocked.status, 1);
assert.match(blocked.stderr, /EAI_HARNESS_TENANT_ID is required/);
assert.doesNotMatch(blocked.stderr, /mock/i);

const diagnosticEnvironment = {
  ...cleanEnvironment,
  EAI_HARNESS_TENANT_ID: "00000000-0000-4000-8000-000000000000",
  EAI_HARNESS_USER_EMAIL: "release-test@example.invalid",
  EAI_VM_MACOS_COMMAND: "true",
  EAI_VM_WINDOWS_COMMAND: "true",
  EAI_VM_UBUNTU_COMMAND: "true",
};
const mockWithoutFlag = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "mock-without-flag"), "--deprovision", "mock", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(mockWithoutFlag.status, 1);
assert.match(mockWithoutFlag.stderr, /diagnostic-only/);

const diagnosticPreflight = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "diagnostic"), "--deprovision", "mock", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(diagnosticPreflight.status, 0);
assert.match(diagnosticPreflight.stdout, /"deprovision": "mock"/);
assert.match(diagnosticPreflight.stdout, /"diagnostic": true/);

const selectedVmEnvironment = {
  ...cleanEnvironment,
  EAI_HARNESS_TENANT_ID: "00000000-0000-4000-8000-000000000000",
  EAI_HARNESS_USER_EMAIL: "release-test@example.invalid",
  EAI_RELEASE_VMS: "windows",
  EAI_VM_WINDOWS_COMMAND: "true",
};
const selectedVmPreflight = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "selected-vm"), "--deprovision", "mock", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: selectedVmEnvironment,
});
assert.equal(selectedVmPreflight.status, 0, selectedVmPreflight.stderr);
assert.match(selectedVmPreflight.stdout, /"vms": \[\s*"windows"\s*\]/);
assert.doesNotMatch(selectedVmPreflight.stdout, /"macos"|"ubuntu"/);

const diagnosticWithApi = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "diagnostic-with-api"), "--deprovision", "api", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(diagnosticWithApi.status, 1);
assert.match(diagnosticWithApi.stderr, /only valid with --deprovision mock/);

const shellSyntax = execFileSync("bash", ["-n", path.join(root, "release.sh")], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(shellSyntax, "");
assert.equal(execFileSync("bash", ["-n", macosGuestPreparer], { cwd: root, encoding: "utf8" }), "");

console.log("live release gate contract checks ok");
