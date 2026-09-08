#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const readSource = (sourcePath) => fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
const runner = path.join(root, "scripts", "release-e2e.mjs");
const macosGuestPreparer = path.join(root, "scripts", "prepare-macos-guest-dmg.sh");
const macosAiWorkspacePreparer = path.join(root, "scripts", "prepare-macos-ai-workspace.sh");
const macosGuestLogin = path.join(root, "scripts", "login-macos-guest.sh");
const macosOcr = path.join(root, "scripts", "macos-ocr-match.swift");
const macosParallelsWindowId = path.join(root, "scripts", "macos-parallels-window-id.swift");
const macosParallelsUacPoint = path.join(root, "scripts", "macos-parallels-uac-point.swift");
const macosCurrentUserLibrary = path.join(root, "scripts", "parallels-macos-current-user.sh");
const macosCurrentUserTest = path.join(root, "scripts", "test-parallels-macos-current-user.sh");
const windowsAiWorkspacePreparer = path.join(root, "scripts", "prepare-windows-ai-workspace.sh");
const windowsAiWorkspacePowerShell = path.join(root, "scripts", "prepare-windows-ai-workspace.ps1");
const windowsAiHandoffProcessQuery = path.join(root, "scripts", "windows-ai-handoff-process-query.sh");
const windowsAiHandoffProcessQueryTest = path.join(root, "scripts", "test-windows-ai-handoff-process-query.sh");
const windowsHiddenCurrentUser = path.join(root, "scripts", "windows-hidden-current-user.sh");
const windowsReadonlyPowerShell = path.join(root, "scripts", "windows-readonly-powershell.sh");
const windowsReadonlyPowerShellTest = path.join(root, "scripts", "test-windows-readonly-powershell.sh");
const windowsGuestLogin = path.join(root, "scripts", "login-windows-guest.sh");
const windowsUiAction = path.join(root, "scripts", "windows-ui-action.ps1");
const windowsInteractiveExactDelete = path.join(root, "scripts", "windows-interactive-exact-delete.ps1");
const windowsPortalCleanupUi = path.join(root, "scripts", "run-windows-portal-cleanup-ui.sh");
const windowsPortalCleanupUiTest = path.join(root, "scripts", "test-windows-portal-cleanup-ui.sh");
const windowsDiagnosticCleanup = path.join(root, "scripts", "run-windows-diagnostic-cleanup.sh");
const windowsPortalEvidenceFinalizer = path.join(root, "scripts", "finalize-windows-portal-evidence.mjs");
const windowsDiagnosticCleanupPowerShell = path.join(root, "scripts", "windows-diagnostic-cleanup.ps1");
const windowsDiagnosticCleanupTest = path.join(root, "scripts", "test-windows-diagnostic-cleanup.sh");
const windowsDiagnosticCleanupGate = path.join(root, "scripts", "write-windows-diagnostic-cleanup-gate.mjs");
const keychainE2eLauncher = path.join(root, "scripts", "run-release-e2e-from-keychain.sh");
const ubuntuGuestCore = path.join(root, "scripts", "ubuntu-guest-test-core.sh");
const ubuntuGuestSession = path.join(root, "scripts", "ubuntu-guest-session.sh");
const ubuntuGuestLogin = path.join(root, "scripts", "login-ubuntu-guest.sh");
const ubuntuAiWorkspacePreparer = path.join(root, "scripts", "prepare-ubuntu-ai-workspace.sh");
const ubuntuUiAction = path.join(root, "scripts", "ubuntu-ui-action.py");
const ubuntuGuestTest = path.join(root, "scripts", "test-ubuntu-guest-test.sh");
const guestTestLibrary = path.join(root, "scripts", "guest-test-lib.sh");
const vmAdapterPreflight = path.join(root, "scripts", "vm-adapter-preflight.sh");
const guestAdapters = ["macos", "windows", "ubuntu"].map((vm) => path.join(root, "scripts", `run-${vm}-guest-test.sh`));
const macosGuestAdapterSource = readSource(guestAdapters[0]);
const windowsGuestAdapterSource = readSource(guestAdapters[1]);
const releaseShell = readSource(path.join(root, "release.sh"));
const runnerSource = readSource(runner);
const macosGuestPreparerSource = readSource(macosGuestPreparer);
const macosAiWorkspacePreparerSource = readSource(macosAiWorkspacePreparer);
const macosGuestLoginSource = readSource(macosGuestLogin);
const macosOcrSource = readSource(macosOcr);
const macosParallelsWindowIdSource = readSource(macosParallelsWindowId);
const macosParallelsUacPointSource = readSource(macosParallelsUacPoint);
const macosCurrentUserLibrarySource = readSource(macosCurrentUserLibrary);
const windowsAiWorkspacePreparerSource = readSource(windowsAiWorkspacePreparer);
const windowsAiWorkspacePowerShellSource = readSource(windowsAiWorkspacePowerShell);
const windowsAiHandoffProcessQuerySource = readSource(windowsAiHandoffProcessQuery);
const windowsHiddenCurrentUserSource = readSource(windowsHiddenCurrentUser);
const windowsReadonlyPowerShellSource = readSource(windowsReadonlyPowerShell);
const windowsGuestLoginSource = readSource(windowsGuestLogin);
const windowsUiActionSource = readSource(windowsUiAction);
const windowsInteractiveExactDeleteSource = readSource(windowsInteractiveExactDelete);
const windowsPortalCleanupUiSource = readSource(windowsPortalCleanupUi);
const windowsDiagnosticCleanupSource = readSource(windowsDiagnosticCleanup);
const windowsPortalEvidenceFinalizerSource = readSource(windowsPortalEvidenceFinalizer);
const windowsDiagnosticCleanupPowerShellSource = readSource(windowsDiagnosticCleanupPowerShell);
const keychainE2eLauncherSource = readSource(keychainE2eLauncher);
assert.match(keychainE2eLauncherSource, /\/usr\/sbin\/ioreg -n Root -d1/);
assert.match(keychainE2eLauncherSource, /"IOConsoleLocked" = Yes/);
assert.match(keychainE2eLauncherSource, /no VM was touched/);
assert.doesNotMatch(keychainE2eLauncherSource, /ioreg[^\n]*\|[^\n]*grep -Fq/);
assert.ok(
  keychainE2eLauncherSource.indexOf('"IOConsoleLocked" = Yes')
    < keychainE2eLauncherSource.indexOf('exec caffeinate -dimsu'),
);
const ubuntuGuestAdapterSource = readSource(guestAdapters[2]);
const ubuntuGuestCoreSource = readSource(ubuntuGuestCore);
const ubuntuGuestSessionSource = readSource(ubuntuGuestSession);
const ubuntuGuestLoginSource = readSource(ubuntuGuestLogin);
const ubuntuAiWorkspacePreparerSource = readSource(ubuntuAiWorkspacePreparer);
const ubuntuUiActionSource = readSource(ubuntuUiAction);
const guestTestLibrarySource = readSource(guestTestLibrary);
const vmAdapterPreflightSource = readSource(vmAdapterPreflight);
const releaseWorkflow = readSource(path.join(root, ".github", "workflows", "release.yml"));
const releaseReadinessWorkflow = readSource(path.join(root, ".github", "workflows", "release-readiness.yml"));
const tauriConfig = JSON.parse(fs.readFileSync(path.join(root, "src-tauri", "tauri.conf.json"), "utf8"));
const output = fs.mkdtempSync(path.join(os.tmpdir(), "eai-installer-release-contract-"));

const finalizerFixture = path.join(output, "guest-finalizer-cleanup-contract");
fs.mkdirSync(finalizerFixture, { recursive: true });
const finalizerReceipt = path.join(finalizerFixture, "desktop-receipt.json");
const finalizerResult = path.join(finalizerFixture, "vm-result.json");
const finalizerState = path.join(finalizerFixture, "app-state.json");
fs.writeFileSync(finalizerReceipt, JSON.stringify({
  status: "passed",
  appCreated: true,
  checks: Object.fromEntries([
    "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff",
  ].map((name) => [name, "passed"])),
  message: "fixture",
}));
const finalizerHash = "a".repeat(64);
const finalizerRun = spawnSync("bash", ["-c", `
  source "$1"
  guest_test_finalize macos "/fixture/project" "$2" "$3" "$3" "$4"
`, "guest-finalizer-fixture", guestTestLibrary, finalizerReceipt, finalizerHash, JSON.stringify({
  git: "fixture", node: "v24.0.0", npm: "11.0.0", eai: "3.15.10",
})], {
  cwd: root,
  encoding: "utf8",
  env: {
    ...process.env,
    EAI_VM_PROJECT_NAME: "test-macos-1788430000000-abc123",
    EAI_VM_RESULT_FILE: finalizerResult,
    EAI_VM_APP_STATE_FILE: finalizerState,
    EAI_VM_INSTALLER_VERIFIED: "1",
    EAI_VM_PREREQUISITES_PROVEN: "1",
    EAI_VM_AI_HANDOFF_PROCESS_VERIFIED: "1",
    EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED: "1",
    EAI_VM_PROJECT_VERIFIED: "1",
    EAI_VM_EXECUTABLE_SHA256: finalizerHash,
  },
});
assert.equal(finalizerRun.status, 0, finalizerRun.stderr);
assert.deepEqual(JSON.parse(fs.readFileSync(finalizerState, "utf8")), {
  appName: "test-macos-1788430000000-abc123",
  appCreated: true,
  cleanupRequired: true,
  cleanupRequested: true,
});

assert.match(releaseShell, /patch\|minor\|major/);
assert.match(keychainE2eLauncherSource, /command -v caffeinate/);
assert.match(keychainE2eLauncherSource, /exec caffeinate -dimsu "\$ROOT\/release[.]sh" diagnostic-e2e/);
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
assert.match(diagnosticPublishSection, /publish-diagnostic is disabled because diagnostic cleanup cannot authorize a production v\* tag/);
assert.doesNotMatch(diagnosticPublishSection, /git tag|git push|gh release|wait_for_release_workflow/);
const testPublishSection = releaseShell.slice(releaseShell.indexOf("publish_test_release"), releaseShell.indexOf("publish_diagnostic_release"));
assert.match(testPublishSection, /gh workflow run test-release\.yml/);
assert.match(testPublishSection, /eai-setup-test-v\$version/);
assert.match(testPublishSection, /--deprovision mock --diagnostic/);
assert.match(testPublishSection, /publish-test requires one explicit EAI_RELEASE_VMS value/);
assert.match(testPublishSection, /--vms "\$diagnostic_vm"/);
assert.match(runnerSource, /diagnostic-only/);
assert.match(runnerSource, /source: "diagnostic-mock"/);
assert.match(runnerSource, /passed_with_mock_cleanup/);
assert.match(runnerSource, /report\.status === "failed"/);
assert.doesNotMatch(runnerSource, /report\.status !== "passed"/);
assert.match(runnerSource, /cleanupVerified: false/);
assert.match(runnerSource, /EAI_HARNESS_TENANT_ID/);
assert.match(runnerSource, /EAI_APP_DEPROVISION_COMMAND/);
assert.match(runnerSource, /EAI_VM_\$\{vm\.toUpperCase\(\)\}_COMMAND/);
assert.match(runnerSource, /EAI_VM_APP_STATE_FILE/);
assert.match(runnerSource, /EAI_HARNESS_USER_EMAIL/);
assert.match(runnerSource, /"EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL"/);
assert.match(runnerSource, /cleanupVerified !== true/);
assert.match(runnerSource, /receipt\.source !== "public-api-v4"/);
assert.match(runnerSource, /receipt\.operationId/);
assert.match(runnerSource, /receipt\.deletedRecords/);
assert.match(runnerSource, /function hasDeletionEvidence\(value\)/);
assert.match(runnerSource, /!Array\.isArray\(value\)/);
assert.match(runnerSource, /Object\.keys\(value\)\.length > 0/);
assert.doesNotMatch(runnerSource, /!receipt\.deletedRecords \|\| !receipt\.deletedResources/);
assert.match(runnerSource, /cleanupTargetConservative/);
assert.match(runnerSource, /appStateCheckpoint = appStateError === null \? "verified" : "conservative-unknown"/);
assert.match(runnerSource, /const appCreated = appState\?\.appCreated === true \|\| resultProvesCreation \|\| cleanupTargetConservative/);
assert.match(runnerSource, /const signalExitCodes = \{ SIGINT: 130, SIGTERM: 143 \}/);
assert.match(runnerSource, /activeChild === record/);
assert.match(runnerSource, /const target = activeSignalChild/);
assert.match(runnerSource, /function resolveExactExecutable\(value, label\)/);
assert.match(runnerSource, /must be one absolute executable path/);
assert.match(runnerSource, /must be a canonical regular non-symlink executable file/);
assert.match(runnerSource, /Refusing to start a second VM adapter while one is active/);
assert.match(runnerSource, /detached: process[.]platform !== "win32"/);
assert.match(runnerSource, /child[.]once\("close",[\s\S]*settle\(\{ code: code \?\? 1, signal, stdout, stderr \}\)/);
assert.match(runnerSource, /const result = await run\(command, \[\], \{ env, role: `vm:\$\{vm\}`/);
assert.match(runnerSource, /role: `vm:\$\{vm\}`, vmChild: true, signalEligible: true/);
assert.match(runnerSource, /role: "release-download", signalEligible: true/);
assert.match(runnerSource, /role: "asset-validation", signalEligible: true/);
assert.match(runnerSource, /record[.]child[.]kill\(signal\)/);
assert.match(runnerSource, /forceInterruptedChild\("second-signal"\)/);
assert.match(runnerSource, /role: "app-cleanup", allowAfterInterruption: true/);
assert.doesNotMatch(runnerSource, /role: "app-cleanup"[^\n]*signalEligible/);
assert.match(runnerSource, /await run\(command, \["--preflight"\]/);
assert.match(runnerSource, /await run\(deprovisionCommand, \["--preflight"\]/);
assert.match(runnerSource, /mutationAttempted !== false/);
assert.match(runnerSource, /canonicalV4Adapter/);
assert.match(runnerSource, /Production cleanup must use the repository's canonical V4 adapter/);
assert.match(runnerSource, /Production validation requires macos,windows,ubuntu in that exact sequence/);
assert.match(runnerSource, /Production validation requires the repository \$\{vm\} VM adapter/);
assert.match(runnerSource, /Production validation requires the exact ARM64 \$\{vm\} release asset/);
assert.doesNotMatch(runnerSource, /shell: true/);
assert.match(runnerSource, /report[.]status = interruption \? "interrupted"/);
assert.doesNotMatch(runnerSource, /process[.]kill\(/);
assert.doesNotMatch(runnerSource, /setTimeout\([^\n]*SIGKILL|grace-timeout/);
assert.ok(runnerSource.indexOf("report.machines.push(machine)") < runnerSource.indexOf("await runVm("));
const deletionEvidenceHelperSource = runnerSource.slice(
  runnerSource.indexOf("function hasDeletionEvidence(value)"),
  runnerSource.indexOf("\n\nasync function cleanup", runnerSource.indexOf("function hasDeletionEvidence(value)")),
);
const hasDeletionEvidence = Function(`${deletionEvidenceHelperSource}\nreturn hasDeletionEvidence;`)();
for (const invalidEvidence of [{}, [], ["deleted"], true, 1, "deleted", null]) {
  assert.equal(hasDeletionEvidence(invalidEvidence), false);
}
assert.equal(hasDeletionEvidence({ app: 1 }), true);
assert.match(runnerSource, /EAI_DEPROVISION_APP_CREATED/);
assert.match(runnerSource, /receipt\.appCreated !== appCreated/);
assert.match(runnerSource, /receipt\.schemaVersion !== "eai\.release-e2e\.cleanup-receipt\.v1"/);
assert.match(runnerSource, /receipt\.tenantIdSha256 !== sha256Text/);
assert.match(runnerSource, /receipt\.apiOriginSha256 !== sha256Text/);
assert.match(runnerSource, /receipt\.planHash/);
assert.match(runnerSource, /vertical-service-activation/);
assert.match(runnerSource, /vertical-product-config/);
assert.match(runnerSource, /allManifestOwnedResourceTypesAbsent !== true/);
assert.match(runnerSource, /fs\.constants\.O_NOFOLLOW/);
assert.match(runnerSource, /fs\.renameSync\(temporary, filePath\)/);
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
assert.doesNotMatch(macosGuestPreparerSource, /--password/);
assert.doesNotMatch(macosGuestPreparerSource, /EAI_VM_GUEST_PASSWORD/);
assert.match(macosGuestPreparerSource, /source "\$ROOT\/scripts\/parallels-macos-current-user[.]sh"/);
assert.match(macosGuestPreparerSource, /macos_prl_current_user_configure "\$vm_name" "\$guest_user" "\$work_dir"/);
assert.doesNotMatch(macosGuestPreparerSource, /prlctl exec[^\n]*--current-user/);
assert.match(macosGuestPreparerSource, /-name '[*][.]app'.*macos_prl_current_user_shell_idempotent/s);
assert.match(macosGuestPreparerSource, /application must be at the top level/);
assert.doesNotMatch(macosGuestPreparerSource, /guest_idempotent \/usr\/bin\/open/);
assert.match(macosGuestPreparerSource, /The signed-in macOS user's home directory could not be resolved/);
assert.match(macosGuestPreparerSource, /guest_idempotent \/bin\/test -d "\$actual_home"/);
assert.match(macosGuestPreparerSource, /guest_asuser \/usr\/bin\/curl/);
assert.match(macosGuestPreparerSource, /guest_asuser \/usr\/bin\/hdiutil attach/);
assert.match(macosGuestPreparerSource, /guest_asuser \/usr\/bin\/open/);
assert.match(macosGuestPreparerSource, /trap cleanup EXIT/);
assert.match(macosGuestPreparerSource, /READY_FOR_UI.*mount=%s/);
assert.match(macosGuestAdapterSource, /login-macos-guest\.sh/);
assert.match(macosGuestAdapterSource, /prepare-macos-ai-workspace\.sh/);
assert.doesNotMatch(macosGuestAdapterSource, /tell application "System Events"/);
assert.doesNotMatch(macosGuestAdapterSource, /click Allow/);
const cleanSnapshotPreflight = macosGuestAdapterSource.indexOf("stage clean-snapshot-preflight");
assert.notEqual(cleanSnapshotPreflight, -1);
assert.ok(cleanSnapshotPreflight < macosGuestAdapterSource.indexOf("stage portal-login"));
assert.ok(cleanSnapshotPreflight < macosGuestAdapterSource.indexOf("stage exact-asset-download"));
const aiWorkspaceProvision = macosGuestAdapterSource.indexOf("stage ai-workspace-provision");
assert.ok(cleanSnapshotPreflight < aiWorkspaceProvision);
assert.ok(aiWorkspaceProvision < macosGuestAdapterSource.indexOf("stage portal-login"));
for (const cleanSnapshotCheck of [
  /GuestTools: state=installed/,
  /Capture mouse clicks: on/,
  /The macOS release guest must be ARM64/,
  /stat -f %Su \/dev\/console/,
  /session = Aqua/,
  /AppleKeyboardUIMode must be 3/,
  /prltoolsd/,
  /prlcopypaste/,
  /prlctl capture/,
  /xcode-select -p/,
  /Library\/Developer\/CommandLineTools/,
  /opt\/homebrew/,
  /guest_current_command_exists node/,
  /guest_current_command_exists npm/,
  /guest_current_command_exists eai/,
  /EAI Setup[.]app/,
  /EAI Setup state or prior test artifacts/,
  /EAI Setup or EAI CLI process running/,
]) {
  assert.match(macosGuestAdapterSource, cleanSnapshotCheck);
}
assert.doesNotMatch(macosGuestAdapterSource, /already has every prerequisite/);
const macosFailureRecoveryStart = macosGuestAdapterSource.indexOf("write_failure_result() {");
const macosFailureRecoveryEnd = macosGuestAdapterSource.indexOf("cleanup() {");
assert.ok(macosFailureRecoveryStart >= 0 && macosFailureRecoveryEnd > macosFailureRecoveryStart);
const macosFailureRecoverySource = macosGuestAdapterSource.slice(macosFailureRecoveryStart, macosFailureRecoveryEnd);
for (const failureRecoveryCheck of [
  /prlctl status "\$vm_name"[^\n]*grep -Fq running/,
  /\/bin\/test -f "\$guest_receipt"/,
  /\/bin\/test ! -L "\$guest_receipt"/,
  /\/bin\/cat "\$guest_receipt" >"\$failure_receipt" 2>\/dev\/null/,
  /guest_project="\$guest_parent\/\$EAI_VM_PROJECT_NAME"/,
  /guest_package="\$guest_project\/package[.]json"/,
  /\/bin\/test -d "\$guest_project"/,
  /\/bin\/test ! -L "\$guest_project"/,
  /\/bin\/test -f "\$guest_package"/,
  /\/bin\/test ! -L "\$guest_package"/,
  /\/bin\/cat "\$guest_package" >"\$failure_package" 2>\/dev\/null/,
  /expectedPackageName = `@eai-tools\/\$\{appName\}`/,
  /packageJson[?][.]name === expectedPackageName/,
  /existingResult[?][.]appName === appName && existingResult[?][.]appCreated === true/,
  /existingAppState[?][.]appName === appName && existingAppState[?][.]appCreated === true/,
  /receipt[?][.]appCreated === true/,
  /\|\| locallyGeneratedProject/,
  /[.][.][.]existingResult/,
  /[.][.][.]existingAppState/,
  /macos-failure-checkpoint[.]json/,
]) {
  assert.match(macosFailureRecoverySource, failureRecoveryCheck);
}
assert.doesNotMatch(macosFailureRecoverySource, /\/bin\/ls|\/usr\/bin\/find|tenant list|resources (?:list|delete)/);
assert.match(macosGuestAdapterSource, /failure_receipt="\$work_dir\/failure-receipt[.]json"/);
assert.match(macosGuestAdapterSource, /failure_package="\$work_dir\/failure-package[.]json"/);
for (const source of [macosGuestAdapterSource, macosGuestPreparerSource, macosAiWorkspacePreparerSource, macosGuestLoginSource]) {
  assert.match(source, /source "\$ROOT\/scripts\/parallels-macos-current-user[.]sh"/);
  assert.doesNotMatch(source, /prlctl exec[^\n]*--current-user/);
  assert.doesNotMatch(source, /Invalid argument/);
}
assert.match(macosCurrentUserLibrarySource, /macos_prl_current_user_is_exact_transient\(\)/);
assert.match(macosCurrentUserLibrarySource, /"\$status" -eq 255/);
assert.match(macosCurrentUserLibrarySource, /grep -Fqx/);
assert.match(macosCurrentUserLibrarySource, /PrlJob_GetRetCode: Invalid argument[.] An invalid argument was passed[.]/);
assert.match(macosCurrentUserLibrarySource, /PrlJob_GetResult: Invalid argument[.] An invalid argument was passed[.]/);
assert.match(macosCurrentUserLibrarySource, /local max_attempts=3/);
assert.match(macosCurrentUserLibrarySource, /sleep 2/);
assert.match(macosCurrentUserLibrarySource, /stdout_file="\$attempt_dir\/stdout"/);
assert.match(macosCurrentUserLibrarySource, /stderr_file="\$attempt_dir\/stderr"/);
assert.match(macosCurrentUserLibrarySource, /cat "\$stdout_file"/);
assert.match(macosCurrentUserLibrarySource, /cat "\$stderr_file" >&2/);
assert.match(macosCurrentUserLibrarySource, /mktemp -d "\$MACOS_PRL_CURRENT_USER_WORK_DIR\/prl-current-user[.]XXXXXX"/);
assert.match(macosCurrentUserLibrarySource, /actual_user=.*_macos_prl_current_user_run_retryable \/dev\/null \/usr\/bin\/id -un/);
assert.match(macosCurrentUserLibrarySource, /MACOS_PRL_CURRENT_USER_READY=1/);
assert.ok(
  macosCurrentUserLibrarySource.indexOf("actual_user=\"$(_macos_prl_current_user_run_retryable")
    < macosCurrentUserLibrarySource.lastIndexOf("MACOS_PRL_CURRENT_USER_READY=1"),
);
assert.match(macosCurrentUserLibrarySource, /launchctl asuser "\$MACOS_PRL_CURRENT_USER_UID"/);
assert.match(macosCurrentUserLibrarySource, /sudo -H -u "\$MACOS_PRL_CURRENT_USER_NAME"/);
assert.match(macosCurrentUserLibrarySource, /HOME="\$MACOS_PRL_CURRENT_USER_HOME"/);
assert.match(macosCurrentUserLibrarySource, /\[\[ "\$aqua_session" == \*"session = Aqua"\* \]\]/);
assert.doesNotMatch(macosCurrentUserLibrarySource, /printf[^\n]*\$aqua_session[^\n]*\|[^\n]*grep/);
assert.doesNotMatch(macosCurrentUserLibrarySource, /\*Invalid argument\*/);
const macosExactAppCopyStart = macosGuestAdapterSource.indexOf("stage exact-app-copy");
const macosPrerequisiteBaseline = macosGuestAdapterSource.indexOf("stage prerequisite-baseline-proven");
assert.ok(macosExactAppCopyStart >= 0 && macosPrerequisiteBaseline > macosExactAppCopyStart);
const macosExactAppCopySource = macosGuestAdapterSource.slice(macosExactAppCopyStart, macosPrerequisiteBaseline);
assert.match(macosExactAppCopySource, /macos_prl_current_user_shell_idempotent/);
assert.match(macosExactAppCopySource, /rm -rf '\$guest_app'/);
assert.match(macosExactAppCopySource, /ditto '\/tmp\/eai-setup-under-test\/EAI Setup[.]app' '\$guest_app'/);
assert.ok(
  macosExactAppCopySource.indexOf("macos_prl_current_user_shell_idempotent")
    < macosExactAppCopySource.indexOf('/bin/test -x "$executable"'),
);
const beforeSnapshotRestore = macosGuestAdapterSource.slice(0, macosGuestAdapterSource.indexOf("stage snapshot-restore"));
assert.match(beforeSnapshotRestore, /find-generic-password -s "\$mac_admin_service" -a "\$mac_admin_account" >\/dev\/null 2>&1/);
assert.doesNotMatch(beforeSnapshotRestore, /find-generic-password[^\n]* -[wg]/);
const loginMetadataPreflight = macosGuestLoginSource.slice(0, macosGuestLoginSource.indexOf("case \"\${1:-}\""));
assert.match(loginMetadataPreflight, /find-generic-password -s "\$keychain_service" -a "\$test_email" >\/dev\/null 2>&1/);
assert.doesNotMatch(loginMetadataPreflight, /find-generic-password[^\n]* -[wg]/);
assert.match(macosGuestLoginSource, /https:\/\/www[.]enterpriseaigroup[.]com\/sign-in/);
assert.match(macosGuestLoginSource, /PUBLIC_SIGN_IN_PAGE_READY/);
assert.match(macosGuestLoginSource, /input combo alt\+tab --repeat 10/);
assert.doesNotMatch(macosGuestLoginSource, /open .*admin-portal[.]myenterprise[.]ai/);
assert.doesNotMatch(macosGuestLoginSource, /input combo control\+tab/);
const macosBrowserLoginStart = macosGuestLoginSource.indexOf('if [[ "$mode" != cli ]]');
const macosBrowserLoginEnd = macosGuestLoginSource.indexOf("# The portal session and CLI token are separate.");
assert.ok(macosBrowserLoginStart >= 0 && macosBrowserLoginEnd > macosBrowserLoginStart);
const macosBrowserLoginSource = macosGuestLoginSource.slice(macosBrowserLoginStart, macosBrowserLoginEnd);
const mandatoryFreshMacosLoginSteps = [
  'macos_prl_signed_in_user_exec /usr/bin/open "$login_url"',
  "The restored Test Mac already has an authenticated portal session",
  "PUBLIC_SIGN_IN_PAGE_READY",
  "input combo alt+tab --repeat 10",
  "The restored Test Mac reached the authenticated portal before credentials were entered",
  "PORTAL_LOGIN_PAGE_READY",
  'if screen_has "Email address"',
  'if screen_has "Enter password"',
  "remembered account state is not valid release evidence",
  "MICROSOFT_EMAIL_STAGE_READY",
  `printf '%s' "$test_email" | input type --stdin`,
  `wait_for_screen "Enter password" 60`,
  "MICROSOFT_PASSWORD_STAGE_READY",
  `find-generic-password -s "$keychain_service" -a "$test_email" -w`,
  'post_password_stage=""',
  'screen_has "Save Password?"',
  'screen_has "Stay signed in?"',
  "wait_for_portal 120",
  "AUTHENTICATED_PORTAL_READY",
];
let previousFreshMacosLoginStep = -1;
for (const step of mandatoryFreshMacosLoginSteps) {
  const stepIndex = macosBrowserLoginSource.indexOf(step, previousFreshMacosLoginStep + 1);
  assert.notEqual(stepIndex, -1, `missing mandatory fresh macOS login step: ${step}`);
  assert.ok(stepIndex > previousFreshMacosLoginStep, `out-of-order fresh macOS login step: ${step}`);
  previousFreshMacosLoginStep = stepIndex;
}
assert.doesNotMatch(macosBrowserLoginSource, /portal_authenticated|login_stage=password/);
assert.equal((macosBrowserLoginSource.match(/input type --stdin/g) ?? []).length, 2);
const macosCliLoginStart = macosGuestLoginSource.indexOf("cli_output=\"$work_dir/cli-login.txt\"");
const macosCliVerificationStart = macosGuestLoginSource.indexOf("cli_authenticated=0");
assert.ok(macosCliLoginStart >= 0 && macosCliVerificationStart > macosCliLoginStart);
const macosCliLoginSource = macosGuestLoginSource.slice(macosCliLoginStart, macosCliVerificationStart);
assert.match(macosCliLoginSource, /macos_prl_signed_in_user_exec "\$guest_node" "\$guest_cli" login/);
assert.doesNotMatch(macosCliLoginSource, /macos_prl_current_user_exec_idempotent[^\n]* login/);
assert.doesNotMatch(macosCliLoginSource, /while \(\( cli_attempt/);
assert.equal(
  (macosCliLoginSource.match(/macos_prl_signed_in_user_exec "\$guest_node" "\$guest_cli" login/g) ?? []).length,
  1,
);
assert.doesNotMatch(macosCliLoginSource, /(?:cat|printf)[^\n]*\$cli_output/);
assert.match(macosAiWorkspacePreparerSource, /1[.]136[.]1/);
assert.match(macosAiWorkspacePreparerSource, /bd15a1b26cd10ba84900f7bd30f21d51eef268828e1e15a8ac1f97f99620bbe5/);
assert.match(macosAiWorkspacePreparerSource, /update[.]code[.]visualstudio[.]com/);
assert.match(macosAiWorkspacePreparerSource, /darwin-arm64/);
assert.match(macosAiWorkspacePreparerSource, /x-sha256:/);
assert.match(macosAiWorkspacePreparerSource, /codesign --verify --deep --strict/);
assert.match(macosAiWorkspacePreparerSource, /spctl --assess/);
assert.match(macosAiWorkspacePreparerSource, /TeamIdentifier/);
assert.match(macosAiWorkspacePreparerSource, /UBF8T346G9/);
assert.match(macosAiWorkspacePreparerSource, /extensions\/copilot/);
assert.doesNotMatch(macosAiWorkspacePreparerSource, /find-generic-password|--password/);
assert.match(macosAiWorkspacePreparerSource, /macos_prl_current_user_configure/);
assert.match(macosAiWorkspacePreparerSource, /guest_user_shell\(\)[\s\S]*macos_prl_current_user_shell_idempotent/);
assert.match(macosAiWorkspacePreparerSource, /guest_root_shell\(\)[\s\S]*prlctl exec "\$vm_name" \/bin\/sh/);
assert.doesNotMatch(macosAiWorkspacePreparerSource, /for _ in \$\(seq 1 5\)/);
const macosAiVerificationStart = macosAiWorkspacePreparerSource.indexOf("guest_verify_app() {");
const macosAiVerificationEnd = macosAiWorkspacePreparerSource.indexOf("guest_test_require prlctl");
assert.ok(macosAiVerificationStart >= 0 && macosAiVerificationEnd > macosAiVerificationStart);
const macosAiVerificationSource = macosAiWorkspacePreparerSource.slice(macosAiVerificationStart, macosAiVerificationEnd);
const mandatoryFailFastMacosVerificationSteps = [
  '"set -e"',
  "/usr/bin/codesign --verify --deep --strict",
  "/usr/sbin/spctl --assess --type execute --verbose=2",
  "TeamIdentifier",
  '[ \\"\\$team\\" = UBF8T346G9 ]',
  "CFBundleIdentifier",
  '[ \\"\\$bundle\\" = com.microsoft.VSCode ]',
  "/Contents/Resources/app/extensions/copilot",
  "/usr/bin/file",
  "/usr/bin/grep -Fq arm64",
];
let previousMacosVerificationStep = -1;
for (const step of mandatoryFailFastMacosVerificationSteps) {
  const stepIndex = macosAiVerificationSource.indexOf(step, previousMacosVerificationStep + 1);
  assert.notEqual(stepIndex, -1, `missing fail-fast macOS AI verification step: ${step}`);
  assert.ok(stepIndex > previousMacosVerificationStep, `out-of-order macOS AI verification step: ${step}`);
  previousMacosVerificationStep = stepIndex;
}
const macosAiRootInstallStart = macosAiWorkspacePreparerSource.indexOf("# Install it through Parallels' protected root channel");
const macosAiRootInstallEnd = macosAiWorkspacePreparerSource.indexOf('guest_verify_app "$installed_app"');
assert.ok(macosAiRootInstallStart >= 0 && macosAiRootInstallEnd > macosAiRootInstallStart);
const macosAiRootInstallSource = macosAiWorkspacePreparerSource.slice(macosAiRootInstallStart, macosAiRootInstallEnd);
const mandatoryFailFastMacosRootInstallSteps = [
  '"set -e"',
  "/bin/rm -rf '$installed_app'",
  "/usr/bin/ditto '$guest_app' '$installed_app'",
  "/usr/sbin/chown -R root:wheel '$installed_app'",
  "| guest_root_shell",
];
let previousMacosRootInstallStep = -1;
for (const step of mandatoryFailFastMacosRootInstallSteps) {
  const stepIndex = macosAiRootInstallSource.indexOf(step, previousMacosRootInstallStep + 1);
  assert.notEqual(stepIndex, -1, "missing fail-fast macOS root install step: " + step);
  assert.ok(stepIndex > previousMacosRootInstallStep, "out-of-order macOS root install step: " + step);
  previousMacosRootInstallStep = stepIndex;
}
assert.match(macosGuestAdapterSource, /EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1/);
assert.match(macosGuestAdapterSource, /EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1/);
assert.match(macosGuestAdapterSource, /EAI_VM_PROJECT_VERIFIED=1/);
assert.match(macosGuestAdapterSource, /Visual Studio Code[.]app\/Contents\/MacOS\/Code/);
assert.match(macosGuestAdapterSource, /macos-ai-handoff[.]png/);
assert.match(macosGuestAdapterSource, /macos-project-verification[.]json/);
assert.match(macosGuestAdapterSource, /macos-ai-handoff-evidence[.]json/);
assert.match(macosGuestAdapterSource, /EAI_OCR_INCLUDE_BROWSER_CHROME=1/);
assert.match(macosGuestAdapterSource, /The macOS handoff screenshot contains protected or callback data/);
assert.match(macosGuestAdapterSource, /guestAndHostPackageHashesMatched/);
assert.match(macosGuestAdapterSource, /Safari still owned the callback window/);
assert.match(macosOcrSource, /EAI_OCR_INCLUDE_BROWSER_CHROME/);
assert.match(guestTestLibrarySource, /&& projectVerified === "1" \? "passed" : "failed"/);
assert.match(guestTestLibrarySource, /&& aiHandoffScreenshotVerified === "1" \? "passed" : "failed"/);
assert.doesNotMatch(guestTestLibrarySource, /vm === "ubuntu" \|\| projectVerified/);
assert.doesNotMatch(guestTestLibrarySource, /vm === "ubuntu" \|\| aiHandoffScreenshotVerified/);

assert.match(runnerSource, /windows: "eai-setup-windows-arm64[.]exe"/);
assert.match(windowsGuestAdapterSource, /vm_name="\$\{EAI_WINDOWS_VM_NAME:-Windows 11\}"/);
assert.match(windowsGuestAdapterSource, /snapshot_id="\$\{EAI_WINDOWS_SNAPSHOT_ID:-48921a89-eb72-430e-b4bf-a7b70d8bfaab\}"/);
assert.match(windowsGuestAdapterSource, /guest_user="\$\{EAI_WINDOWS_GUEST_USER:-eai-douglasross\}"/);
assert.match(windowsGuestAdapterSource, /login-windows-guest[.]sh/);
assert.match(windowsGuestAdapterSource, /prepare-windows-ai-workspace[.]sh/);
assert.match(windowsGuestAdapterSource, /windows-ai-handoff-process-query[.]sh/);
assert.match(guestTestLibrarySource, /prlctl snapshot-list "\$vm_name"/);
assert.match(guestTestLibrarySource, /prlctl stop "\$vm_name" --drop-state/);
assert.match(guestTestLibrarySource, /prlctl stop "\$vm_name" --kill/);
assert.match(guestTestLibrarySource, /prlctl snapshot-switch "\$vm_name" --id "\$snapshot_id" --skip-resume/);
assert.match(guestTestLibrarySource, /hashes: \{ host: hostHash, guest: guestHash \}/);
assert.match(guestTestLibrarySource, /executableSha256/);
assert.match(guestTestLibrarySource, /prerequisitesBefore/);
assert.match(guestTestLibrarySource, /\$\{vm\}-ai-workspace[.]json/);

const windowsSnapshotRestore = windowsGuestAdapterSource.indexOf("stage snapshot-restore");
const windowsCleanSnapshotPreflight = windowsGuestAdapterSource.indexOf("stage clean-snapshot-preflight");
const windowsAiWorkspaceProvision = windowsGuestAdapterSource.indexOf("stage ai-workspace-provision");
const windowsPortalLogin = windowsGuestAdapterSource.indexOf("stage portal-login");
const windowsInstallerBridgeArm = windowsGuestAdapterSource.indexOf("stage installer-bridge-arm");
const windowsInstallerBridgeArmed = windowsGuestAdapterSource.indexOf("stage installer-bridge-armed");
const windowsDefenderAllowanceArm = windowsGuestAdapterSource.indexOf("stage defender-exact-file-allowance-arm");
const windowsDefenderAllowanceArmed = windowsGuestAdapterSource.indexOf("stage defender-exact-file-allowance-armed");
const windowsExactAssetDownload = windowsGuestAdapterSource.indexOf("stage exact-asset-download");
const windowsExactAssetDownloadPassed = windowsGuestAdapterSource.indexOf("stage exact-asset-download-passed");
const windowsDefenderAllowanceVerify = windowsGuestAdapterSource.indexOf("stage defender-exact-file-allowance-verify");
const windowsDefenderAllowanceActive = windowsGuestAdapterSource.indexOf("stage defender-exact-file-allowance-active");
const windowsNativeInstaller = windowsGuestAdapterSource.indexOf("stage native-installer");
const windowsDefenderCleanup = windowsGuestAdapterSource.indexOf("stage defender-exact-file-cleanup");
const windowsDefenderCleanupPassed = windowsGuestAdapterSource.indexOf("stage defender-exact-file-cleanup-passed");
const windowsUacPolicyArm = windowsGuestAdapterSource.indexOf("stage uac-admin-consent-suppression-arm");
const windowsNormalLaunch = windowsGuestAdapterSource.indexOf("stage normal-app-launch");
const windowsPrerequisiteInstall = windowsGuestAdapterSource.indexOf("stage prerequisite-install");
const windowsUacPolicyRestore = windowsGuestAdapterSource.indexOf("stage uac-admin-consent-restoration");
const windowsCliLogin = windowsGuestAdapterSource.indexOf("stage cli-login");
const windowsE2eLaunch = windowsGuestAdapterSource.indexOf("stage e2e-app-launch");
for (const stageIndex of [
  windowsSnapshotRestore,
  windowsCleanSnapshotPreflight,
  windowsAiWorkspaceProvision,
  windowsPortalLogin,
  windowsInstallerBridgeArm,
  windowsInstallerBridgeArmed,
  windowsDefenderAllowanceArm,
  windowsDefenderAllowanceArmed,
  windowsExactAssetDownload,
  windowsExactAssetDownloadPassed,
  windowsDefenderAllowanceVerify,
  windowsDefenderAllowanceActive,
  windowsNativeInstaller,
  windowsDefenderCleanup,
  windowsDefenderCleanupPassed,
  windowsUacPolicyArm,
  windowsNormalLaunch,
  windowsPrerequisiteInstall,
  windowsUacPolicyRestore,
  windowsCliLogin,
  windowsE2eLaunch,
]) {
  assert.notEqual(stageIndex, -1);
}
assert.ok(windowsDefenderCleanupPassed < windowsUacPolicyArm);
assert.ok(windowsUacPolicyArm < windowsNormalLaunch);
assert.ok(windowsPrerequisiteInstall < windowsUacPolicyRestore);
assert.ok(windowsUacPolicyRestore < windowsCliLogin);
assert.ok(windowsSnapshotRestore < windowsCleanSnapshotPreflight);
assert.ok(windowsCleanSnapshotPreflight < windowsAiWorkspaceProvision);
assert.ok(windowsAiWorkspaceProvision < windowsPortalLogin);
assert.ok(windowsPortalLogin < windowsInstallerBridgeArm);
assert.ok(windowsInstallerBridgeArm < windowsInstallerBridgeArmed);
assert.ok(windowsInstallerBridgeArmed < windowsDefenderAllowanceArm);
assert.ok(windowsDefenderAllowanceArm < windowsDefenderAllowanceArmed);
assert.ok(windowsDefenderAllowanceArmed < windowsExactAssetDownload);
assert.ok(windowsExactAssetDownload < windowsExactAssetDownloadPassed);
assert.ok(windowsExactAssetDownloadPassed < windowsDefenderAllowanceVerify);
assert.ok(windowsDefenderAllowanceVerify < windowsDefenderAllowanceActive);
assert.ok(windowsDefenderAllowanceActive < windowsNativeInstaller);
assert.ok(windowsNativeInstaller < windowsDefenderCleanup);
assert.ok(windowsDefenderCleanup < windowsDefenderCleanupPassed);
assert.ok(windowsDefenderCleanupPassed < windowsNormalLaunch);
assert.ok(windowsNormalLaunch < windowsPrerequisiteInstall);
assert.ok(windowsPrerequisiteInstall < windowsCliLogin);
assert.ok(windowsCliLogin < windowsE2eLaunch);

const windowsBeforeSnapshotRestore = windowsGuestAdapterSource.slice(0, windowsSnapshotRestore);
assert.match(windowsBeforeSnapshotRestore, /login-windows-guest[.]sh" --preflight/);
assert.doesNotMatch(windowsBeforeSnapshotRestore, /find-generic-password[^\n]* -w/);
assert.match(windowsGuestAdapterSource, /local max_attempts="\$\{2:-30\}"/);
assert.match(windowsGuestAdapterSource, /Unable to open new session in this virtual machine/);
const windowsPayloadWrapperStart = windowsGuestAdapterSource.indexOf("write_powershell_payload_wrapper() {");
const windowsPayloadPowerShellStart = windowsGuestAdapterSource.indexOf("guest_ps_run() {");
const windowsStreamedPowerShellStart = windowsGuestAdapterSource.indexOf("guest_ps() {");
const windowsSystemPayloadPowerShellStart = windowsGuestAdapterSource.indexOf("guest_system_ps_run() {");
const windowsSystemPowerShellStart = windowsGuestAdapterSource.indexOf("guest_system_ps() {");
const windowsInstallerBridgeStart = windowsGuestAdapterSource.indexOf("start_installer_bridge() {");
const windowsGuardianStart = windowsGuestAdapterSource.indexOf("start_defender_guardian() {");
const windowsDetachedLaunchStart = windowsGuestAdapterSource.indexOf("launch_guest_app_detached() {");
assert.ok(windowsPayloadWrapperStart >= 0 && windowsPayloadPowerShellStart > windowsPayloadWrapperStart);
assert.ok(windowsStreamedPowerShellStart > windowsPayloadPowerShellStart);
assert.ok(windowsSystemPayloadPowerShellStart > windowsStreamedPowerShellStart);
assert.ok(windowsSystemPowerShellStart > windowsSystemPayloadPowerShellStart);
assert.ok(windowsInstallerBridgeStart > windowsSystemPowerShellStart);
assert.ok(windowsGuardianStart > windowsInstallerBridgeStart);
assert.ok(windowsDetachedLaunchStart > windowsGuardianStart);
const windowsPayloadWrapperSource = windowsGuestAdapterSource.slice(windowsPayloadWrapperStart, windowsPayloadPowerShellStart);
const windowsPayloadPowerShellSource = windowsGuestAdapterSource.slice(windowsPayloadPowerShellStart, windowsStreamedPowerShellStart);
const windowsStreamedPowerShellSource = windowsGuestAdapterSource.slice(windowsStreamedPowerShellStart, windowsSystemPayloadPowerShellStart);
const windowsSystemPayloadPowerShellSource = windowsGuestAdapterSource.slice(windowsSystemPayloadPowerShellStart, windowsSystemPowerShellStart);
const windowsSystemPowerShellSource = windowsGuestAdapterSource.slice(windowsSystemPowerShellStart, windowsInstallerBridgeStart);
const windowsInstallerBridgeSource = windowsGuestAdapterSource.slice(windowsInstallerBridgeStart, windowsGuardianStart);
const windowsGuardianSource = windowsGuestAdapterSource.slice(windowsGuardianStart, windowsDetachedLaunchStart);
assert.match(windowsPayloadWrapperSource, /payload_base64="\$\(printf '%s' "\$stdin_payload" \| \/usr\/bin\/base64 \| \/usr\/bin\/tr -d '\\n'\)"/);
assert.match(windowsPayloadWrapperSource, /FromBase64String\('\$payload_base64'\)/);
assert.match(windowsPayloadWrapperSource, /\[Console\]::SetIn\(\[IO[.]StringReader\]::new\(\$__eaiHarnessInputValue\)\)/);
assert.doesNotMatch(windowsPayloadWrapperSource, /prlctl|--current-user|EncodedCommand|Set-Content|Out-File/);
assert.doesNotMatch(windowsPayloadWrapperSource, /Invoke-Expression|ScriptBlock|AddScript|iex\b/i);
assert.match(windowsPayloadPowerShellSource, /printf '%s\\n' "\$script" \| windows_hidden_current_user_ps "\$vm_name" "\$stdin_payload"/);
assert.doesNotMatch(windowsPayloadPowerShellSource, /EncodedCommand|local encoded=|printf '%s' "\$stdin_payload" \| prlctl/);
assert.match(windowsStreamedPowerShellSource, /printf '%s\\n' "\$script" \| windows_hidden_current_user_ps "\$vm_name" ""/);
assert.doesNotMatch(windowsStreamedPowerShellSource, /EncodedCommand/);
assert.match(windowsHiddenCurrentUserSource, /payload="\$\(printf '%s' "\$stdin_payload" \| \/usr\/bin\/base64 \| \/usr\/bin\/tr -d '\\n'\)"/);
assert.match(windowsHiddenCurrentUserSource, /\[Console\]::SetIn\(\[IO[.]StringReader\]::new\(\$__eaiInput\)\)/);
assert.match(windowsHiddenCurrentUserSource, /windows_hidden_bounded_prlctl 600 exec "\$vm_name" --current-user wscript[.]exe "\$vbs_path"/);
assert.match(windowsHiddenCurrentUserSource, /"\$prlctl_bin" "\$@" <&0 &/);
assert.match(windowsHiddenCurrentUserSource, /\) <\/dev\/null >\/dev\/null 2>&1 &/);
assert.match(windowsHiddenCurrentUserSource, /s[.]Run\(.*powershell[.]exe.*-File/);
assert.match(windowsHiddenCurrentUserSource, /SetAccessRuleProtection\(\\\$true, \\\$false\)/);
assert.match(windowsHiddenCurrentUserSource, /SecurityIdentifier\]::new\('S-1-5-18'\)/);
assert.match(windowsHiddenCurrentUserSource, /SecurityIdentifier\]::new\('S-1-5-32-544'\)/);
assert.match(windowsHiddenCurrentUserSource, /,\\\$interactiveSid\)/);
assert.match(windowsHiddenCurrentUserSource, /'ContainerInherit,ObjectInherit'/);
assert.match(windowsHiddenCurrentUserSource, /Remove-Item -LiteralPath '\$base' -Recurse/);
assert.doesNotMatch(windowsHiddenCurrentUserSource, /base="C:\\\\Users\\\\Public\\\\eai-hidden-\$\{nonce\}"[\s\S]*ps_path="\$\{base\}[.]ps1"/);
assert.doesNotMatch(windowsHiddenCurrentUserSource, /EncodedCommand|Invoke-Expression|ScriptBlock|AddScript|iex\b/i);
assert.match(
  windowsSystemPayloadPowerShellSource,
  /write_powershell_payload_wrapper "\$stdin_payload" "\$script"[\s\S]*prlctl exec "\$vm_name" cmd[.]exe \/D \/S \/C powershell[.]exe/,
);
assert.match(windowsSystemPayloadPowerShellSource, /-InputFormat Text -OutputFormat Text -Command -/);
assert.doesNotMatch(windowsSystemPayloadPowerShellSource, /EncodedCommand|local encoded=|printf '%s' "\$stdin_payload" \| prlctl/);
assert.doesNotMatch(windowsSystemPayloadPowerShellSource, /--current-user/);
assert.equal(
  (windowsSystemPowerShellSource.match(/prlctl exec "\$vm_name" cmd[.]exe \/D \/S \/C powershell[.]exe/g) ?? []).length,
  2,
);
assert.match(windowsSystemPowerShellSource, /printf '& \{\\n%s\\n\}\\n\\n'/);
assert.doesNotMatch(windowsSystemPowerShellSource, /--current-user/);
assert.doesNotMatch(windowsSystemPowerShellSource, /EncodedCommand/);
assert.doesNotMatch(windowsGuestAdapterSource, /prlctl exec "\$vm_name" powershell[.]exe/);
assert.equal(
  (windowsGuestAdapterSource.match(/prlctl exec "\$vm_name" cmd[.]exe \/D \/S \/C powershell[.]exe/g) ?? []).length,
  4,
);
assert.doesNotMatch(windowsGuestAdapterSource, /start_system_powershell_bridge|defender_action_bridge_pid|defender-guardian-bridge[.]status|installer-bridge[.]status/);
assert.doesNotMatch(windowsGuestAdapterSource, /--current-user cmd[.]exe/);
assert.doesNotMatch(windowsGuestAdapterSource, /guest_ps_run ""/);
assert.match(windowsGuestAdapterSource, /guest_ps 1 2>\/dev\/null/);
assert.match(windowsGuestAdapterSource, /baseline_json="\$\(guest_ps <<'POWERSHELL'/);
assert.match(windowsGuestAdapterSource, /source "\$ROOT\/scripts\/windows-readonly-powershell[.]sh"/);
assert.match(windowsReadonlyPowerShellSource, /windows_readonly_is_ambiguous_result_failure\(\) \{/);
assert.match(windowsReadonlyPowerShellSource, /"\$status" == 255/);
assert.match(windowsReadonlyPowerShellSource, /PrlJob_GetRetCode: Invalid argument[.] An invalid argument was passed[.]/);
assert.match(windowsReadonlyPowerShellSource, /PrlJob_GetResult: Invalid argument[.] An invalid argument was passed[.]/);
assert.match(windowsReadonlyPowerShellSource, /windows_readonly_is_session_open_failure\(\) \{/);
assert.match(windowsReadonlyPowerShellSource, /PrlVmGuest_RunProgram: Unable to open new session/);
assert.match(windowsReadonlyPowerShellSource, /if \[\[ "\$ambiguous_attempt" -ge 3 \]\]/);
assert.match(windowsReadonlyPowerShellSource, /sleep 2/);
assert.match(windowsReadonlyPowerShellSource, /guest_ps_readonly_run\(\) \{/);
assert.match(windowsReadonlyPowerShellSource, /guest_ps_readonly\(\) \{/);
assert.match(windowsReadonlyPowerShellSource, /guest_system_ps_readonly_run\(\) \{/);
assert.match(windowsReadonlyPowerShellSource, /guest_system_ps_readonly\(\) \{/);
assert.match(windowsReadonlyPowerShellSource, /windows_hidden_current_user_ps "\$vm_name" "\$stdin_payload"/);
assert.match(windowsReadonlyPowerShellSource, /prlctl exec "\$vm_name" cmd[.]exe \/D \/S \/C powershell[.]exe/);
assert.doesNotMatch(
  windowsReadonlyPowerShellSource,
  /Stop-Process|Remove-Item|Set-Content|Start-Process|Add-MpPreference|Remove-MpPreference|Set-ItemProperty|[.]Kill\(/,
);
assert.match(windowsAiHandoffProcessQuerySource, /local max_attempts=3/);
assert.match(windowsAiHandoffProcessQuerySource, /guest_ps 1 2>&1 <<'POWERSHELL'/);
assert.match(windowsAiHandoffProcessQuerySource, /Get-Process Code -ErrorAction SilentlyContinue/);
assert.match(windowsAiHandoffProcessQuerySource, /EAI_AI_HANDOFF_PROCESS_NOT_READY/);
assert.match(windowsAiHandoffProcessQuerySource, /EAI_AI_HANDOFF_PROCESS_READY:\{0\}/);
assert.match(windowsAiHandoffProcessQuerySource, /"\$status" == 255/);
assert.match(windowsAiHandoffProcessQuerySource, /PrlJob_GetRetCode: Invalid argument[.] An invalid argument was passed[.]/);
assert.match(windowsAiHandoffProcessQuerySource, /PrlJob_GetResult: Invalid argument[.] An invalid argument was passed[.]/);
assert.match(windowsAiHandoffProcessQuerySource, /sleep 2/);
assert.doesNotMatch(windowsAiHandoffProcessQuerySource, /Stop-Process|Remove-Item|Set-Content|Start-Process|[.]Kill[(]/);
const windowsAiHandoffValidationStart = windowsGuestAdapterSource.indexOf("stage ai-handoff-process-validation");
const windowsAiHandoffValidationEnd = windowsGuestAdapterSource.indexOf("# The completed CLI callback", windowsAiHandoffValidationStart);
const windowsAiHandoffValidationSource = windowsGuestAdapterSource.slice(
  windowsAiHandoffValidationStart,
  windowsAiHandoffValidationEnd,
);
assert.match(windowsAiHandoffValidationSource, /windows_ai_handoff_process_query/);
assert.match(windowsAiHandoffValidationSource, /code_process_probe_status/);
assert.doesNotMatch(windowsAiHandoffValidationSource, /\|\| true/);
assert.doesNotMatch(windowsGuestAdapterSource, /Refusing an oversized .*EncodedCommand|\$\{#encoded\}" -lt 6000/);
assert.doesNotMatch(windowsGuestAdapterSource, /EncodedCommand|encode_powershell/);
assert.match(windowsGuestAdapterSource, /is_parallels_session_open_failure\(\) \{/);
assert.match(windowsGuestAdapterSource, /'PrlVmGuest_RunProgram: Invalid argument'/);
assert.match(windowsGuestAdapterSource, /'PrlVmGuest_RunProgram: Unable to open new session in this virtual machine[.]/);
assert.doesNotMatch(windowsGuestAdapterSource, /\[\[ "\$output" == \*"Invalid argument"\*/);
const windowsDetachedLaunchEnd = windowsGuestAdapterSource.indexOf("validate_guest_app_launch() {", windowsDetachedLaunchStart);
const windowsDetachedLaunchSource = windowsGuestAdapterSource.slice(windowsDetachedLaunchStart, windowsDetachedLaunchEnd);
assert.match(windowsDetachedLaunchSource, /guest_system_ps_run "\$bootstrap_hash"\$'\\n'"\$bootstrap_base64"/);
assert.match(windowsDetachedLaunchSource, /app bootstrap is not being staged by LocalSystem/);
assert.match(windowsDetachedLaunchSource, /SetAccessRuleProtection\(\$true, \$false\)/);
assert.match(windowsDetachedLaunchSource, /'ReadAndExecute', 'Allow'/);
assert.match(windowsDetachedLaunchSource, /\$bootstrapRules[.]Count -ne 2/);
assert.match(windowsDetachedLaunchSource, /FileSystemRights\]::Write\) -eq 0/);
assert.match(windowsDetachedLaunchSource, /FileSystemRights\]::Delete\) -eq 0/);
assert.match(windowsDetachedLaunchSource, /windows_hidden_current_user_ps "\$vm_name" "\$protected_payload"/);
assert.match(windowsDetachedLaunchSource, /& 'C:\\Users\\Public\\eai-setup-app-bootstrap[.]ps1' -Mode '\$mode'/);
assert.match(windowsDetachedLaunchSource, /\$tenantId = \[Console\]::In[.]ReadLine\(\)[\s\S]*\$projectName = \[Console\]::In[.]ReadLine\(\)/);
assert.match(windowsDetachedLaunchSource, /\$null -ne \[Console\]::In[.]ReadLine\(\)/);
assert.match(windowsDetachedLaunchSource, /Add-Type -TypeDefinition @'/);
assert.match(windowsDetachedLaunchSource, /public static extern IntPtr GetCurrentProcess\(\)/);
assert.match(windowsDetachedLaunchSource, /EntryPoint = "IsProcessInJob"[\s\S]*SetLastError = true/);
assert.match(windowsDetachedLaunchSource, /\[wmiclass\]'\\\\[.]\\root\\cimv2:Win32_ProcessStartup'/);
assert.match(windowsDetachedLaunchSource, /\$wmiStartup = \$wmiStartupClass[.]CreateInstance\(\)/);
assert.match(windowsDetachedLaunchSource, /\$wmiStartup[.]CreateFlags = \$creationFlags/);
assert.match(windowsDetachedLaunchSource, /\$wmiStartup[.]WinstationDesktop = 'winsta0\\default'/);
assert.match(windowsDetachedLaunchSource, /\$wmiStartup[.]EnvironmentVariables = \$startupEnvironmentValues/);
assert.match(windowsDetachedLaunchSource, /\[wmiclass\]'\\\\[.]\\root\\cimv2:Win32_Process'/);
assert.match(windowsDetachedLaunchSource, /\$wmiResult = \$wmiProcessClass[.]Create\(\$commandLine, \$workingDirectory, \$wmiStartup\)/);
assert.match(windowsDetachedLaunchSource, /\$creationFlags = \[uint32\]1536/);
assert.match(windowsDetachedLaunchSource, /\$commandLine = '"' \+ \$executable \+ '"'/);
assert.match(
  windowsDetachedLaunchSource,
  /function Get-ExactProcesses[\s\S]*?ConvertTo-ComparableAppPath \$_[.]Path/,
);
const bootstrapJobProof = windowsDetachedLaunchSource.indexOf(
  "[EaiReleaseE2E.NativeProcess]::GetCurrentProcess(), [IntPtr]::Zero, [ref]$bootstrapInJob",
);
const launchArmWrite = windowsDetachedLaunchSource.indexOf("Write-AtomicRestrictedText $armPath");
const wmiCreateCall = windowsDetachedLaunchSource.indexOf("$wmiResult = $wmiProcessClass.Create(");
const preWmiCancelCheck = windowsDetachedLaunchSource.lastIndexOf("Assert-LaunchNotCancelled", wmiCreateCall);
const wmiReturnCapture = windowsDetachedLaunchSource.indexOf("$wmiReturnedAtUtc = [DateTime]::UtcNow", wmiCreateCall);
const postWmiCancelCheck = windowsDetachedLaunchSource.indexOf("Assert-LaunchNotCancelled", wmiReturnCapture);
const processIdentityObservation = windowsDetachedLaunchSource.indexOf(
  "$processIdentityObservedAtUtc = [DateTime]::UtcNow",
  postWmiCancelCheck,
);
const childJobProof = windowsDetachedLaunchSource.indexOf("$process.Handle, [IntPtr]::Zero, [ref]$childInJob");
assert.ok(bootstrapJobProof >= 0 && bootstrapJobProof < launchArmWrite);
assert.ok(
  launchArmWrite < preWmiCancelCheck && preWmiCancelCheck < wmiCreateCall
    && wmiCreateCall < wmiReturnCapture && wmiReturnCapture < postWmiCancelCheck
    && postWmiCancelCheck < processIdentityObservation
    && processIdentityObservation < childJobProof,
);
const exactStopStart = windowsDetachedLaunchSource.indexOf("function Stop-ExactCreatedProcess(");
const exactStopEnd = windowsDetachedLaunchSource.indexOf("function New-WmiStartupEnvironment(", exactStopStart);
const exactStopSource = windowsDetachedLaunchSource.slice(exactStopStart, exactStopEnd);
const stopBinding = exactStopSource.indexOf("$evidence = Get-WmiProcessEvidence $targetId");
const stopKill = exactStopSource.indexOf("$target.Kill()");
const stopProofAfterKill = exactStopSource.indexOf("& $proveTerminated", stopKill);
assert.ok(stopBinding >= 0 && stopBinding < stopKill && stopKill < stopProofAfterKill);
assert.match(exactStopSource, /\$proveTerminated = \{[\s\S]*\$target[.]WaitForExit\(30000\)/);
assert.match(exactStopSource, /if \(\$target[.]WaitForExit\(0\)\) \{[\s\S]*& \$proveTerminated[\s\S]*return/);
assert.match(exactStopSource, /catch \{[\s\S]*\$racedToExitBeforeBinding = \$target[.]WaitForExit\(0\)[\s\S]*& \$proveTerminated/);
assert.match(exactStopSource, /\$wmiReturnedAt -lt \$armedAt[\s\S]*\$identityObservedAt -lt \$wmiReturnedAt/);
assert.match(exactStopSource, /\$targetStartedAtUtc -lt \$armedAt[\s\S]*\$targetStartedAtUtc -gt \$identityObservedAt/);
assert.match(exactStopSource, /\$evidence[.]OwnerSid -cne \$expectedOwnerSid/);
assert.match(exactStopSource, /\$evidence[.]CommandLine -cne \$expectedCommandLine/);
assert.match(exactStopSource, /\$racedToExit = \$target[.]WaitForExit\(0\)/);
assert.doesNotMatch(windowsDetachedLaunchSource, /Stop-AmbiguousPostArmProcess|ambiguous local-WMI child|multiple exact post-arm application processes/i);
const windowsLaunchFailureCleanupStart = windowsDetachedLaunchSource.indexOf(
  "if (-not $launchCommitted -and $wmiCallAttempted)",
);
const windowsLaunchFailureCleanupSource = windowsDetachedLaunchSource.slice(
  windowsLaunchFailureCleanupStart,
  windowsDetachedLaunchSource.indexOf("throw $launchFailure", windowsLaunchFailureCleanupStart),
);
assert.match(windowsLaunchFailureCleanupSource, /if \(\$createdProcessId -gt 0\) \{[\s\S]*Stop-ExactCreatedProcess \$process/);
assert.doesNotMatch(windowsLaunchFailureCleanupSource, /Get-ExactProcesses|foreach \(\$candidate|Stop-Ambiguous/i);
assert.match(windowsDetachedLaunchSource, /\$wmiReturnValue -ne 0 -or \$createdProcessId -le 0/);
assert.match(windowsDetachedLaunchSource, /\$wmiReturnedAtUtc -lt \$armedAtUtc[\s\S]*\$processIdentityObservedAtUtc -lt \$wmiReturnedAtUtc/);
assert.match(windowsDetachedLaunchSource, /\$processStartedAtUtc -lt \$armedAtUtc[\s\S]*\$processStartedAtUtc -gt \$processIdentityObservedAtUtc/);
assert.doesNotMatch(windowsDetachedLaunchSource, /\$processStartedAtUtc -gt \$wmiReturnedAtUtc/);
assert.match(windowsDetachedLaunchSource, /\$processEvidence[.]CommandLine -cne \$commandLine/);
assert.match(windowsDetachedLaunchSource, /\$expectedE2eCount = if \(\$mode -eq 'e2e'\) \{ 5 \} else \{ 0 \}/);
assert.match(windowsDetachedLaunchSource, /\$name[.]StartsWith\('EAI_SETUP_E2E', \[StringComparison\]::OrdinalIgnoreCase\)/);
for (const variable of [
  "EAI_SETUP_E2E", "EAI_SETUP_E2E_PROJECT_NAME", "EAI_SETUP_E2E_DIRECTORY",
  "EAI_SETUP_E2E_COMPANY_TENANT", "EAI_SETUP_E2E_RECEIPT_FILE",
]) {
  assert.match(windowsDetachedLaunchSource, new RegExp(`\\$environment\\['${variable}'\\] =`));
}
assert.match(windowsDetachedLaunchSource, /eai-windows-detached-app-launch-arm\/v2/);
assert.match(windowsDetachedLaunchSource, /eai-windows-detached-app-launch\/v5/);
assert.match(windowsDetachedLaunchSource, /processIdentityObservedAt = \$processIdentityObservedAtUtc[.]ToString\('o'\)/);
assert.match(windowsDetachedLaunchSource, /launchMechanism = 'local-win32-process-create'/);
assert.match(windowsDetachedLaunchSource, /providerBrokeredJobEscape = \$true/);
assert.match(windowsDetachedLaunchSource, /bootstrapInJob = \$bootstrapInJob/);
assert.match(windowsDetachedLaunchSource, /childInJob = \$childInJob/);
assert.match(windowsDetachedLaunchSource, /childJobStateObserved = \$true/);
assert.match(windowsDetachedLaunchSource, /childJobAbsenceRequired = \$false/);
assert.match(windowsDetachedLaunchSource, /protectedValuesInGlobalEnvironment = \$false/);
assert.match(windowsDetachedLaunchSource, /processOnlyStartupEnvironment = \$true/);
assert.match(windowsDetachedLaunchSource, /explicitChildEnvironmentBlock = \$true/);
assert.match(windowsDetachedLaunchSource, /unicodeChildEnvironmentBlock = \$true/);
assert.match(windowsDetachedLaunchSource, /protectedRuntimeInput = if \(\$Mode -eq 'e2e'\) \{ 'raw-process-stdin' \}/);
assert.equal((windowsDetachedLaunchSource.match(/Assert-LaunchNotCancelled/g) ?? []).length, 4);
assert.match(windowsDetachedLaunchSource, /cancel:\{0\}:\{1\}:\{2\}:\{3\}/);
assert.match(windowsDetachedLaunchSource, /local max_attempts=3/);
assert.match(windowsDetachedLaunchSource, /validate_guest_app_launch "\$pid_file" "\$receipt_file" "\$arm_file"/);
assert.match(windowsDetachedLaunchSource, /"\$bootstrap_status" == 255[\s\S]*is_parallels_session_open_failure/);
assert.match(windowsDetachedLaunchSource, /cleanup_detached_guest_app "\$mode" 1[\s\S]*"\$cleanup_status" == 4/);
assert.match(windowsDetachedLaunchSource, /launch_guest_app_detached "\$mode" "\$protected_payload" "\$expected_executable_hash" "\$\(\(attempt \+ 1\)\)"/);
assert.match(windowsDetachedLaunchSource, /ambiguous Parallels launch result had no independently valid complete receipt; replay is forbidden/);
assert.match(windowsDetachedLaunchSource, /preserve_detached_launch_evidence "\$mode"[\s\S]*cleanup_detached_guest_app/);
assert.doesNotMatch(windowsDetachedLaunchSource, /Start-Process|ProcessStartInfo|Diagnostics[.]Process\]::Start|NamedPipe|GetNamedPipeClientProcessId/);
assert.doesNotMatch(windowsDetachedLaunchSource, /CreateProcessW|CreateProcessAsUser|CREATE_BREAKAWAY_FROM_JOB|STARTF_USESTDHANDLES|CREATE_NO_WINDOW/);
assert.doesNotMatch(windowsDetachedLaunchSource, /New-CimInstance|Invoke-CimMethod/);
assert.doesNotMatch(windowsDetachedLaunchSource, /SetEnvironmentVariable|Env:\\EAI_SETUP_E2E/);
assert.doesNotMatch(windowsDetachedLaunchSource, /[.]Contains\([^\n]*StringComparison/);
assert.doesNotMatch(windowsDetachedLaunchSource, /\b(?:record|nint|using var)\b|\?\./);
assert.doesNotMatch(windowsDetachedLaunchSource, /guest_ps_run[\s\S]*\$protected_payload|ArgumentList[^\n]*(?:tenant|project)/i);
assert.equal((windowsDetachedLaunchSource.match(/windows_hidden_current_user_ps "\$vm_name" "\$protected_payload"/g) ?? []).length, 1);
assert.doesNotMatch(windowsGuestAdapterSource, /start_guest_app_bridge|wait_host_bridge|host_bridge_alive/);
const windowsDetachedValidationStart = windowsGuestAdapterSource.indexOf("validate_guest_app_launch() {", windowsDetachedLaunchEnd);
const windowsDetachedCleanupStart = windowsGuestAdapterSource.indexOf("cleanup_detached_guest_app() {", windowsDetachedValidationStart);
const windowsDetachedRemoteArmStart = windowsGuestAdapterSource.indexOf("arm_windows_remote_cleanup() {", windowsDetachedCleanupStart);
const windowsDetachedValidationSource = windowsGuestAdapterSource.slice(windowsDetachedValidationStart, windowsDetachedCleanupStart);
const windowsDetachedCleanupSource = windowsGuestAdapterSource.slice(windowsDetachedCleanupStart, windowsDetachedRemoteArmStart);
const windowsFocusStart = windowsGuestAdapterSource.indexOf("focus_receipt_bound_eai_setup_window() {");
const windowsScreenHasStart = windowsGuestAdapterSource.indexOf("screen_has() {", windowsFocusStart);
const windowsFocusSource = windowsGuestAdapterSource.slice(windowsFocusStart, windowsScreenHasStart);
const windowsScreenHasSource = windowsGuestAdapterSource.slice(
  windowsScreenHasStart,
  windowsGuestAdapterSource.indexOf("unexpected_prerequisite_uac_visible() {", windowsScreenHasStart),
);
const windowsGuestProcessAliveStart = windowsGuestAdapterSource.indexOf("guest_process_alive() {");
const windowsStopGuestProcessStart = windowsGuestAdapterSource.indexOf(
  "stop_guest_process() {",
  windowsGuestProcessAliveStart,
);
const windowsSanitizeLogStart = windowsGuestAdapterSource.indexOf(
  "sanitize_log_file() {",
  windowsStopGuestProcessStart,
);
const windowsGuestProcessAliveSource = windowsGuestAdapterSource.slice(
  windowsGuestProcessAliveStart,
  windowsStopGuestProcessStart,
);
const windowsStopGuestProcessSource = windowsGuestAdapterSource.slice(
  windowsStopGuestProcessStart,
  windowsSanitizeLogStart,
);
assert.ok(windowsFocusStart >= 0 && windowsScreenHasStart > windowsFocusStart);
assert.ok(
  windowsGuestProcessAliveStart >= 0
    && windowsStopGuestProcessStart > windowsGuestProcessAliveStart
    && windowsSanitizeLogStart > windowsStopGuestProcessStart,
);
assert.match(windowsDetachedValidationSource, /guest_system_ps_readonly_run/);
assert.doesNotMatch(windowsDetachedValidationSource, /\bguest_system_ps_run\b/);
assert.match(windowsGuestProcessAliveSource, /guest_system_ps_readonly_run/);
assert.match(windowsGuestProcessAliveSource, /EAI_GUEST_PROCESS_ALIVE/);
assert.match(windowsGuestProcessAliveSource, /EAI_GUEST_PROCESS_NOT_ALIVE/);
assert.match(windowsGuestProcessAliveSource, /"\$transport_status" == 0 \]\] \|\| return 2/);
assert.match(windowsGuestProcessAliveSource, /EAI_GUEST_PROCESS_ALIVE\) return 0/);
assert.match(windowsGuestProcessAliveSource, /EAI_GUEST_PROCESS_NOT_ALIVE\) return 1/);
assert.doesNotMatch(windowsStopGuestProcessSource, /readonly/);

const windowsSecondExecutableHashStart = windowsGuestAdapterSource.indexOf("second_executable_hash=");
const windowsRemoteCleanupStageStart = windowsGuestAdapterSource.indexOf("stage remote-cleanup-arm", windowsSecondExecutableHashStart);
const windowsSecondExecutableHashSource = windowsGuestAdapterSource.slice(
  windowsSecondExecutableHashStart,
  windowsRemoteCleanupStageStart,
);
assert.match(windowsSecondExecutableHashSource, /guest_ps_readonly <<'POWERSHELL'/);
assert.doesNotMatch(windowsSecondExecutableHashSource, /\bguest_ps <<'POWERSHELL'/);

const windowsE2eReceiptPollStart = windowsGuestAdapterSource.indexOf("receipt_ready=0", windowsE2eLaunch);
const windowsReceiptValidationStageStart = windowsGuestAdapterSource.indexOf("stage receipt-validation", windowsE2eReceiptPollStart);
const windowsE2eReceiptPollSource = windowsGuestAdapterSource.slice(
  windowsE2eReceiptPollStart,
  windowsReceiptValidationStageStart,
);
assert.match(windowsE2eReceiptPollSource, /guest_ps_readonly_run "\$EAI_VM_PROJECT_NAME"\$'\\n'/);
assert.doesNotMatch(windowsE2eReceiptPollSource, /\bguest_ps_run\b/);

const windowsReceiptValidationPassed = windowsGuestAdapterSource.indexOf(
  "stage receipt-validation-passed",
  windowsReceiptValidationStageStart,
);
const windowsFinalReceiptFetchSource = windowsGuestAdapterSource.slice(
  windowsReceiptValidationStageStart,
  windowsReceiptValidationPassed,
);
assert.match(windowsFinalReceiptFetchSource, /guest_ps_readonly >"\$host_receipt"/);
assert.doesNotMatch(windowsFinalReceiptFetchSource, /\bguest_ps >"\$host_receipt"/);

const windowsExactProjectStageStart = windowsGuestAdapterSource.indexOf(
  "stage exact-project-validation",
  windowsReceiptValidationPassed,
);
const windowsExactProjectStagePassed = windowsGuestAdapterSource.indexOf(
  "stage exact-project-validation-passed",
  windowsExactProjectStageStart,
);
const windowsExactProjectSource = windowsGuestAdapterSource.slice(
  windowsExactProjectStageStart,
  windowsExactProjectStagePassed,
);
assert.match(windowsExactProjectSource, /guest_ps_readonly_run "\$EAI_VM_PROJECT_NAME"\$'\\n'/);
assert.doesNotMatch(windowsExactProjectSource, /\bguest_ps_run\b/);

const windowsAppActivateStart = windowsGuestAdapterSource.indexOf(
  "handoff_capture_ready=0",
  windowsExactProjectStagePassed,
);
const windowsHandoffCaptureStart = windowsGuestAdapterSource.indexOf(
  '/usr/bin/ditto "$handoff_candidate" "$handoff_screenshot"',
  windowsAppActivateStart,
);
const windowsPostAppActivateSource = windowsGuestAdapterSource.slice(
  windowsAppActivateStart,
  windowsHandoffCaptureStart,
);
assert.match(windowsPostAppActivateSource, /for handoff_capture_attempt in \$\(seq 1 10\)/);
assert.match(windowsPostAppActivateSource, /windows_ai_handoff_process_query/);
assert.match(windowsPostAppActivateSource, /\$shell[.]AppActivate\(\$processId\)/);
assert.match(windowsPostAppActivateSource, /EaiReleaseAiWindowFocus/);
assert.match(windowsPostAppActivateSource, /GetForegroundWindow\(\) -ne \$window/);
assert.match(windowsPostAppActivateSource, /guest_ps_readonly_run "\$code_process_id"/);
assert.match(windowsPostAppActivateSource, /rm -f "\$handoff_candidate"[\s\S]*prlctl capture/);
assert.match(windowsPostAppActivateSource, /handoff_capture_seen=1/);
assert.match(windowsPostAppActivateSource, /handoff_project_seen=1/);
assert.match(windowsPostAppActivateSource, /handoff_chat_seen=1/);
assert.match(windowsPostAppActivateSource, /handoff_capture_ready=1/);
assert.match(windowsPostAppActivateSource, /The Windows handoff screenshot contains protected or callback data/);
assert.equal((windowsPostAppActivateSource.match(/guest_ps_run "\$code_process_id"/g) ?? []).length, 1);
assert.equal((windowsPostAppActivateSource.match(/guest_ps_readonly_run "\$code_process_id"/g) ?? []).length, 1);
assert.ok(
  windowsPostAppActivateSource.indexOf("The Windows handoff screenshot contains protected or callback data")
    < windowsPostAppActivateSource.indexOf('EAI_OCR_PATTERN="$EAI_VM_PROJECT_NAME"'),
);

const windowsE2eReceiptResetStart = windowsGuestAdapterSource.indexOf("stage e2e-app-launch", windowsRemoteCleanupStageStart);
const windowsE2eDetachedLaunch = windowsGuestAdapterSource.indexOf("launch_guest_app_detached e2e", windowsE2eReceiptResetStart);
const windowsE2eReceiptResetSource = windowsGuestAdapterSource.slice(windowsE2eReceiptResetStart, windowsE2eDetachedLaunch);
assert.match(windowsE2eReceiptResetSource, /guest_ps <<'POWERSHELL'[\s\S]*Remove-Item/);
assert.doesNotMatch(windowsE2eReceiptResetSource, /readonly/);

for (const mutationSource of [windowsDetachedLaunchSource, windowsDetachedCleanupSource, windowsStopGuestProcessSource]) {
  assert.doesNotMatch(mutationSource, /guest_(?:system_)?ps_readonly/);
}

const normalizeWindowsExtendedPrefixFixture = (value) => {
  const extendedUncPrefix = "\\\\?\\UNC\\";
  const extendedPrefix = "\\\\?\\";
  if (value.slice(0, extendedUncPrefix.length).toLowerCase() === extendedUncPrefix.toLowerCase()) {
    return `\\\\${value.slice(extendedUncPrefix.length)}`;
  }
  if (value.slice(0, extendedPrefix.length).toLowerCase() === extendedPrefix.toLowerCase()) {
    return value.slice(extendedPrefix.length);
  }
  return value;
};
assert.equal(
  normalizeWindowsExtendedPrefixFixture("\\\\?\\C:\\Program Files\\EAI Setup\\EAI Setup.exe"),
  "C:\\Program Files\\EAI Setup\\EAI Setup.exe",
);
assert.equal(
  normalizeWindowsExtendedPrefixFixture("\\\\?\\UnC\\server\\share\\EAI Setup.exe"),
  "\\\\server\\share\\EAI Setup.exe",
);
assert.equal(
  normalizeWindowsExtendedPrefixFixture("C:\\Program Files\\EAI Setup\\EAI Setup.exe"),
  "C:\\Program Files\\EAI Setup\\EAI Setup.exe",
);
for (const [name, source] of [
  ["focus", windowsFocusSource],
  ["launch", windowsDetachedLaunchSource],
  ["validation", windowsDetachedValidationSource],
  ["terminal cleanup", windowsDetachedCleanupSource],
  ["liveness", windowsGuestProcessAliveSource],
  ["stop", windowsStopGuestProcessSource],
]) {
  assert.match(source, /function ConvertTo-ComparableAppPath/, `${name} must normalize process paths`);
  assert.match(source, /StartsWith\('\\\\[?]\\UNC\\'/, `${name} must normalize extended UNC paths`);
  assert.match(source, /\$fullPath = '\\\\' \+ \$fullPath[.]Substring\(8\)/, `${name} must retain UNC roots`);
  assert.match(source, /\$fullPath = \$fullPath[.]Substring\(4\)/, `${name} must normalize extended local paths`);
}
const windowsDetachedPathProofSources = [
  windowsFocusSource,
  windowsDetachedLaunchSource,
  windowsDetachedValidationSource,
  windowsDetachedCleanupSource,
  windowsGuestProcessAliveSource,
  windowsStopGuestProcessSource,
].join("\n");
assert.doesNotMatch(
  windowsDetachedPathProofSources,
  /\[string\]::Equals\(\$(?:process|armedProcess)[.]Path,|\[string\]::Equals\(\$_[.]Path,|\[string\]::Equals\(\$actualExecutable, \$expectedExecutable|\[string\]::Equals\(\$(?:armedPath|path), \$expectedPowerShell/,
);
assert.match(windowsFocusSource, /eai-windows-detached-app-launch\/v5/);
assert.match(windowsFocusSource, /\$receipt[.]mode -cne 'normal'/);
assert.match(windowsFocusSource, /\[int\]\$receipt[.]processId -ne \[int\]\$pidText/);
assert.match(windowsFocusSource, /\$receipt[.]processOwnerSid -cne \$identity[.]User[.]Value/);
assert.match(windowsFocusSource, /Get-FileHash -Algorithm SHA256 -LiteralPath \$executable/);
assert.match(windowsFocusSource, /\[void\]\$process[.]Handle/);
assert.match(windowsFocusSource, /\$process[.]SessionId -ne \[int\]\$receipt[.]processSessionId/);
assert.match(windowsFocusSource, /ConvertTo-ComparableAppPath \$process[.]Path/);
assert.match(windowsFocusSource, /\$actualComparablePath, \$expectedComparablePath/);
assert.match(windowsFocusSource, /\$startedAt -cne \[string\]\$receipt[.]processStartedAt/);
assert.match(windowsFocusSource, /\$ownerSid[.]Sid -cne \$identity[.]User[.]Value/);
assert.match(windowsFocusSource, /\[string\]\$cim[.]CommandLine -cne \$expectedCommandLine/);
assert.match(windowsFocusSource, /Get-Process WindowsTerminal/);
assert.match(windowsFocusSource, /\$terminal[.]SessionId -ne \$process[.]SessionId/);
assert.match(windowsFocusSource, /\$terminalOwnerSid[.]Sid -ceq \$identity[.]User[.]Value/);
assert.match(windowsFocusSource, /Microsoft[.]WindowsTerminal_/);
assert.match(windowsFocusSource, /ShowWindowAsync\(\$terminal[.]MainWindowHandle, 6\)/);
assert.match(windowsFocusSource, /SetForegroundWindow\(\$window\)/);
assert.match(windowsFocusSource, /GetForegroundWindow\(\) -ne \$window/);
assert.match(windowsFocusSource, /grep -Fqx 'EAI_SETUP_RECEIPT_BOUND_WINDOW_FOCUSED'/);
assert.doesNotMatch(windowsFocusSource, /Stop-Process|[.]Kill\(|CloseMainWindow|Remove-Item/);
assert.ok(
  windowsScreenHasSource.indexOf("focus_receipt_bound_eai_setup_window")
    < windowsScreenHasSource.indexOf('prlctl capture "$vm_name"'),
);
assert.match(windowsDetachedValidationSource, /eai-windows-detached-app-launch\/v5/);
assert.match(windowsDetachedValidationSource, /launchMechanism -cne 'local-win32-process-create'/);
assert.match(windowsDetachedValidationSource, /localWmiCall -ne \$true/);
assert.match(windowsDetachedValidationSource, /providerBrokeredJobEscape -ne \$true/);
assert.match(windowsDetachedValidationSource, /bootstrapInJob -ne \$true/);
assert.match(windowsDetachedValidationSource, /childInJob -isnot \[bool\]/);
assert.match(windowsDetachedValidationSource, /childJobAbsenceRequired -ne \$false/);
assert.match(windowsDetachedValidationSource, /creationFlags -ne 1536/);
assert.match(windowsDetachedValidationSource, /e2eEnvironmentVariableCount -ne 0/);
assert.match(windowsDetachedValidationSource, /e2eEnvironmentVariableCount -ne 5/);
assert.match(windowsDetachedValidationSource, /\$liveChildInJob -ne \[bool\]\$receipt[.]childInJob/);
assert.match(windowsDetachedValidationSource, /ConvertTo-ComparableAppPath \$process[.]Path/);
assert.match(windowsDetachedValidationSource, /\$actualExecutable, \$expectedComparableExecutable/);
assert.match(windowsDetachedValidationSource, /\$arm[.]processOwnerSid -cne \$expectedOwnerSid/);
assert.match(windowsDetachedValidationSource, /\$arm[.]processSessionId -ne \[int\]\$receipt[.]processSessionId/);
assert.match(windowsDetachedValidationSource, /\$arm[.]processSessionId -ne \[int\]\$receipt[.]bootstrapProcessSessionId/);
assert.match(windowsDetachedValidationSource, /\$receipt[.]armedAt -cne \[string\]\$arm[.]armedAt/);
assert.match(windowsDetachedValidationSource, /\$receipt[.]bootstrapProcessStartedAt\)[.]ToUniversalTime\(\) -gt \[DateTime\]::Parse\(\[string\]\$arm[.]armedAt/);
assert.match(windowsDetachedValidationSource, /\$receipt[.]wmiReturnedAt/);
assert.match(windowsDetachedValidationSource, /\$receipt[.]processIdentityObservedAt/);
assert.doesNotMatch(
  windowsDetachedValidationSource,
  /\$receipt[.]processStartedAt\)[.]ToUniversalTime\(\) -gt \[DateTime\]::Parse\(\[string\]\$receipt[.]wmiReturnedAt/,
);
assert.match(windowsDetachedValidationSource, /Get-Process -Id \(\[int\]\$receipt[.]bootstrapProcessId\)/);
assert.match(windowsDetachedValidationSource, /\[void\]\$bootstrap[.]Handle/);
assert.match(windowsDetachedValidationSource, /\$bootstrap[.]Refresh\(\)/);
assert.match(windowsDetachedValidationSource, /\$bootstrapStartedAtUtc = \$bootstrap[.]StartTime[.]ToUniversalTime\(\)/);
assert.match(windowsDetachedValidationSource, /\$expectedBootstrapStartedAtUtc = \[DateTime\]::Parse\(\[string\]\$receipt[.]bootstrapProcessStartedAt\)/);
assert.match(windowsDetachedValidationSource, /\$receiptRecordedAtUtc = \[DateTime\]::Parse\(\[string\]\$receipt[.]recordedAt\)/);
assert.match(windowsDetachedValidationSource, /one-shot bootstrap remained alive/);
assert.match(windowsDetachedValidationSource, /\$bootstrapStartedAtUtc -le \$receiptRecordedAtUtc/);
assert.match(windowsDetachedValidationSource, /strictly later process creation time/);
assert.match(windowsDetachedValidationSource, /\$bootstrap[.]Dispose\(\)/);
assert.doesNotMatch(windowsDetachedValidationSource, /PID was reused before independent validation; refusing ambiguous proof/);
const windowsBootstrapHandleRetained = windowsDetachedValidationSource.indexOf("[void]$bootstrap.Handle");
const windowsBootstrapRefreshed = windowsDetachedValidationSource.indexOf("$bootstrap.Refresh()");
const windowsBootstrapStartRead = windowsDetachedValidationSource.indexOf(
  "$bootstrapStartedAtUtc = $bootstrap.StartTime.ToUniversalTime()",
);
const windowsBootstrapLaterProof = windowsDetachedValidationSource.indexOf(
  "$bootstrapStartedAtUtc -le $receiptRecordedAtUtc",
);
assert.ok(windowsBootstrapHandleRetained >= 0 && windowsBootstrapHandleRetained < windowsBootstrapRefreshed);
assert.ok(
  windowsDetachedValidationSource.indexOf("Get-Process -Id ([int]$receipt.bootstrapProcessId)")
    < windowsBootstrapHandleRetained,
);
assert.ok(windowsBootstrapRefreshed < windowsBootstrapStartRead);
assert.ok(windowsBootstrapStartRead < windowsBootstrapLaterProof);
const windowsBootstrapIdentityEnd = windowsDetachedValidationSource.indexOf(
  "$expectedExecutable =",
  windowsBootstrapLaterProof,
);
const windowsBootstrapIdentitySource = windowsDetachedValidationSource.slice(
  windowsDetachedValidationSource.indexOf("$bootstrap = Get-Process"),
  windowsBootstrapIdentityEnd,
);
assert.doesNotMatch(windowsBootstrapIdentitySource, /[.]Kill\(|Stop-Process|WaitForExit/);
assert.match(windowsDetachedCleanupSource, /Get-Process -Id \(\[int\]\$receipt[.]processId\)/);
assert.match(windowsDetachedCleanupSource, /\[void\]\$process[.]Handle/);
assert.match(windowsDetachedCleanupSource, /\$processStartedAt -cne \[string\]\$receipt[.]processStartedAt/);
assert.match(windowsDetachedCleanupSource, /\[string\]\$cim[.]CommandLine -cne \$expectedCommandLine/);
assert.match(windowsDetachedCleanupSource, /\$apps\[0\][.]Kill\(\)[\s\S]*\$apps\[0\][.]WaitForExit\(30000\)/);
assert.match(windowsDetachedCleanupSource, /eai-windows-detached-app-launch\/v5/);
assert.match(windowsDetachedCleanupSource, /receipt-process-identity-observation/);
assert.match(windowsDetachedCleanupSource, /\$receiptValue[.]processIdentityObservedAt/);
assert.match(windowsDetachedCleanupSource, /launchMechanism -cne 'local-win32-process-create'/);
assert.match(windowsDetachedCleanupSource, /invalid WMI environment contract/);
assert.match(windowsDetachedCleanupSource, /bootstrapInJob -ne \$true/);
assert.match(windowsDetachedCleanupSource, /childInJob -isnot \[bool\]/);
assert.match(windowsDetachedCleanupSource, /childJobAbsenceRequired -ne \$false/);
assert.match(windowsDetachedCleanupSource, /creationFlags -ne 1536/);
assert.match(windowsDetachedCleanupSource, /Cleanup refuses a bootstrap outside this run hash\/owner binding/);
const windowsAmbiguousArmQuarantineStart = windowsDetachedCleanupSource.indexOf(
  "if ($null -ne $arm -and $null -eq $receipt)",
);
const windowsReceiptBoundAppLookupStart = windowsDetachedCleanupSource.indexOf("function Get-PostArmApps()");
assert.ok(windowsAmbiguousArmQuarantineStart >= 0);
assert.ok(windowsReceiptBoundAppLookupStart > windowsAmbiguousArmQuarantineStart);
assert.match(windowsDetachedCleanupSource, /if \(\$null -ne \$arm -and \$null -eq \$receipt\) \{[\s\S]*?Assert-CancelSignal[\s\S]*?exit 3[\s\S]*?\}/);
assert.match(windowsDetachedCleanupSource, /function Get-PostArmApps\(\) \{[\s\S]*?if \(\$null -eq \$receipt\) \{ return @\(\) \}/);
assert.match(windowsDetachedCleanupSource, /Get-Process -Id \(\[int\]\$receipt[.]processId\)/);
assert.match(windowsDetachedCleanupSource, /\[void\]\$process[.]Handle[\s\S]*?\$processStartedAt -cne \[string\]\$receipt[.]processStartedAt/);
assert.match(windowsDetachedCleanupSource, /Test-ExpectedOwner \$cim[\s\S]*?\[string\]\$cim[.]CommandLine -cne \$expectedCommandLine/);
const windowsReceiptBoundAppLookupSource = windowsDetachedCleanupSource.slice(
  windowsReceiptBoundAppLookupStart,
  windowsDetachedCleanupSource.indexOf("function Get-AllExactExecutableApps()", windowsReceiptBoundAppLookupStart),
);
const windowsAmbiguousArmQuarantineSource = windowsDetachedCleanupSource.slice(
  windowsAmbiguousArmQuarantineStart,
  windowsReceiptBoundAppLookupStart,
);
assert.match(windowsAmbiguousArmQuarantineSource, /Assert-CancelSignal[\s\S]*exit 3/);
assert.doesNotMatch(windowsAmbiguousArmQuarantineSource, /Get-Process|[.]Kill\(|Remove-Item/);
assert.equal((windowsReceiptBoundAppLookupSource.match(/Get-Process/g) ?? []).length, 1);
assert.doesNotMatch(windowsReceiptBoundAppLookupSource, /foreach \(\$process in @\(Get-Process/);
const windowsReceiptHandleOpen = windowsReceiptBoundAppLookupSource.indexOf("[void]$process.Handle");
const windowsReceiptTupleValidation = windowsReceiptBoundAppLookupSource.indexOf("$process.Id -ne [int]$receipt.processId");
const windowsReceiptOwnerValidation = windowsReceiptBoundAppLookupSource.indexOf("Test-ExpectedOwner $cim");
assert.ok(
  windowsReceiptHandleOpen >= 0
    && windowsReceiptHandleOpen < windowsReceiptTupleValidation
    && windowsReceiptTupleValidation < windowsReceiptOwnerValidation,
);
assert.match(windowsReceiptBoundAppLookupSource, /\$process[.]SessionId -ne \[int\]\$receipt[.]processSessionId/);
assert.match(windowsReceiptBoundAppLookupSource, /ConvertTo-ComparableAppPath \$process[.]Path/);
assert.match(windowsReceiptBoundAppLookupSource, /\$processPath, \(ConvertTo-ComparableAppPath \$executable\)/);
assert.match(windowsReceiptBoundAppLookupSource, /\$processStartedAt -cne \[string\]\$receipt[.]processStartedAt/);
const windowsCleanupOwnerProofStart = windowsDetachedCleanupSource.indexOf("function Test-ExpectedOwner(");
const windowsCleanupOwnerProofSource = windowsDetachedCleanupSource.slice(
  windowsCleanupOwnerProofStart,
  windowsDetachedCleanupSource.indexOf("function Get-CommandBoundBootstraps()", windowsCleanupOwnerProofStart),
);
assert.match(windowsCleanupOwnerProofSource, /\$owner[.]User, \$expectedUser/);
assert.match(windowsCleanupOwnerProofSource, /\$ownerSid[.]Sid -ceq \$expectedUserSid[.]Value/);
assert.match(windowsDetachedCleanupSource, /cancel:\$expectedMode/);
assert.match(windowsDetachedCleanupSource, /Write-CancelSignal[\s\S]*\$stableBootstrapAbsence/);
assert.doesNotMatch(windowsDetachedCleanupSource, /Stop-Process -Id \$bootstraps/);
assert.match(windowsDetachedCleanupSource, /Never kill a bootstrap while its synchronous local-WMI dispatch may be/);
assert.match(windowsDetachedCleanupSource, /Refresh arm, receipt, and PID only after the exact bootstrap is terminal/);
assert.equal((windowsDetachedCleanupSource.match(/\$state = Read-BoundLaunchState/g) ?? []).length, 2);
assert.match(windowsDetachedCleanupSource, /\$bootstrapObserved = \$true/);
assert.match(windowsDetachedCleanupSource, /An unstarted launch cannot be proven while any exact executable process exists/);
assert.match(windowsDetachedCleanupSource, /\$retryCandidate -and -not \$launchEvidenceObserved -and -not \$bootstrapObserved/);
assert.match(windowsDetachedCleanupSource, /exit 4/);
const windowsCleanupCancelWrite = windowsDetachedCleanupSource.match(/^Write-CancelSignal\r?$/m)?.index ?? -1;
const windowsCleanupFirstStateRead = windowsDetachedCleanupSource.indexOf("$state = Read-BoundLaunchState", windowsCleanupCancelWrite);
assert.ok(windowsCleanupCancelWrite >= 0 && windowsCleanupCancelWrite < windowsCleanupFirstStateRead);
for (const kill of windowsDetachedCleanupSource.matchAll(/[.]Kill\(\)/g)) {
  assert.ok(windowsCleanupCancelWrite < kill.index);
}
const windowsNoEvidenceBranchStart = windowsDetachedCleanupSource.indexOf(
  "if ($null -eq $arm -and $null -eq $receipt)",
  windowsReceiptBoundAppLookupStart,
);
const windowsSharedAppStopStart = windowsDetachedCleanupSource.indexOf("if ($apps.Count -gt 1)", windowsNoEvidenceBranchStart);
const windowsNoEvidenceBranchSource = windowsDetachedCleanupSource.slice(
  windowsNoEvidenceBranchStart,
  windowsSharedAppStopStart,
);
assert.match(windowsNoEvidenceBranchSource, /Get-AllExactExecutableApps[\s\S]*if \(\$apps.Count -ne 0\) \{[\s\S]*throw/);
assert.ok(
  windowsNoEvidenceBranchSource.indexOf("throw 'An unstarted launch cannot be proven")
    < windowsDetachedCleanupSource.indexOf("$apps[0].Kill()", windowsSharedAppStopStart),
);
assert.match(windowsDetachedCleanupSource, /\$transportConfirmed -and \$null -ne \$receipt/);
assert.match(windowsDetachedCleanupSource, /finite[\s\S]*absence observation is not a cleanup proof/);
assert.match(windowsDetachedCleanupSource, /keep the LocalSystem-owned[\s\S]*bound artifacts[\s\S]*exit 3/);
const windowsFinalQuarantineStart = windowsDetachedCleanupSource.indexOf(
  "# Any incomplete or ambiguous local-WMI launch is diagnostic-only.",
);
const windowsFinalQuarantineSource = windowsDetachedCleanupSource.slice(
  windowsFinalQuarantineStart,
  windowsDetachedCleanupSource.indexOf("\nPOWERSHELL", windowsFinalQuarantineStart),
);
assert.match(windowsFinalQuarantineSource, /Assert-CancelSignal\s+exit 3/);
assert.doesNotMatch(windowsFinalQuarantineSource, /Remove-Item|[.]Kill\(/);
assert.match(windowsDetachedCleanupSource, /normal_launch_nonce=""[\s\S]*e2e_launch_nonce=""/);
assert.match(windowsDetachedCleanupSource, /ConvertTo-ComparableAppPath \$armedProcess[.]Path/);
assert.match(windowsDetachedCleanupSource, /ConvertTo-ComparableAppPath \$expectedPowerShell/);
assert.match(windowsDetachedCleanupSource, /ConvertTo-ComparableAppPath \$process[.]Path/);
assert.match(
  windowsDetachedCleanupSource,
  /function Get-AllExactExecutableApps[\s\S]*?ConvertTo-ComparableAppPath \$process[.]Path/,
);
assert.match(windowsGuestProcessAliveSource, /ConvertTo-ComparableAppPath \$process[.]Path/);
assert.match(windowsGuestProcessAliveSource, /ConvertTo-ComparableAppPath \$expectedExecutable/);
assert.match(windowsStopGuestProcessSource, /ConvertTo-ComparableAppPath \$process[.]Path/);
assert.match(windowsStopGuestProcessSource, /ConvertTo-ComparableAppPath \$expectedExecutable/);
assert.match(windowsGuestAdapterSource, /guest_system_ps_run "\$pid_file"\$'\\n'"\$guest_executable_file"/);
assert.match(windowsGuestAdapterSource, /Get-CimInstance Win32_Process -Filter "ProcessId = \$processId"/);
assert.match(windowsGuestAdapterSource, /Invoke-CimMethod -InputObject \$cimProcess -MethodName GetOwner/);
assert.match(windowsGuestAdapterSource, /windows-normal-app-launch[.]json/);
assert.match(windowsGuestAdapterSource, /windows-e2e-app-launch[.]json/);
assert.match(windowsGuestAdapterSource, /windows-\$\{mode\}-transport-return[.]json/);
assert.match(windowsGuestAdapterSource, /eai-windows-detached-transport-return\/v1/);
assert.match(windowsGuestAdapterSource, /childAliveValidatedAfterReturn: true/);
assert.match(windowsGuestAdapterSource, /providerBrokeredJobEscapeProven: true/);
assert.match(windowsDetachedLaunchSource, /validate_guest_app_launch[\s\S]*write_detached_transport_return_proof/);
assert.match(windowsGuestAdapterSource, /REDACTED_BASE64/);
assert.match(windowsGuestAdapterSource, /decoded[.]includes\(value\)/);
assert.match(windowsGuestAdapterSource, /session_stable_reads=\$\(\(session_stable_reads \+ 1\)\)/);
assert.match(windowsGuestAdapterSource, /"\$session_stable_reads" -ge 3/);
assert.match(windowsGuestAdapterSource, /stage guest-session-stable/);
for (const cleanSnapshotCheck of [
  /Expected Windows 11/,
  /The Windows guest is not ARM64/,
  /Windows guest session identity is invalid/,
  /prl_tools_service/,
  /WinGet is unavailable/,
  /\["edgeProcesses", "git", "node", "npm", "eai", "vscode", "eaiSetup", "userEaiState", "publicTestArtifacts"\]/,
  /approved Windows snapshot is not clean/,
]) {
  assert.match(windowsGuestAdapterSource, cleanSnapshotCheck);
}
const windowsCleanSnapshotSection = windowsGuestAdapterSource.slice(
  windowsCleanSnapshotPreflight,
  windowsAiWorkspaceProvision,
);
for (const detachedWorkerBaselinePath of [
  "eai-setup-installer-worker.ps1",
  "eai-setup-installer-worker.ps1.tmp",
  "eai-setup-defender-guardian.ps1",
  "eai-setup-defender-guardian.ps1.tmp",
  "eai-setup-defender-guardian-armed.json",
  "eai-setup-defender-guardian-armed.json.tmp",
  "eai-setup-defender-done.signal.tmp",
]) {
  assert.match(
    windowsCleanSnapshotSection,
    new RegExp(`C:\\\\Users\\\\Public\\\\${detachedWorkerBaselinePath.replaceAll(".", "[.]")}`),
  );
}
for (const detachedAppBaselinePath of [
  "eai-setup-app-bootstrap.ps1",
  "eai-setup-app-bootstrap.ps1.tmp",
  "eai-setup-normal-launch.json",
  "eai-setup-normal-launch-arm.json",
  "eai-setup-e2e-launch.json",
  "eai-setup-e2e-launch-arm.json",
  "eai-setup-normal-launch-cancel.signal",
  "eai-setup-normal-launch-cancel.signal.tmp",
  "eai-setup-e2e-launch-cancel.signal",
  "eai-setup-e2e-launch-cancel.signal.tmp",
  "eai-setup-normal.pid.tmp",
  "eai-setup-e2e.pid.tmp",
]) {
  assert.match(
    windowsCleanSnapshotSection,
    new RegExp(`C:\\\\Users\\\\Public\\\\${detachedAppBaselinePath.replaceAll(".", "[.]")}`),
  );
}

const windowsLoginMetadataPreflight = windowsGuestLoginSource.slice(
  0,
  windowsGuestLoginSource.indexOf('[[ "$mode" == preflight ]] && exit 0'),
);
assert.match(windowsLoginMetadataPreflight, /security find-generic-password -s "\$keychain_service" 2>\/dev\/null/);
assert.match(windowsLoginMetadataPreflight, /stored_account.*== "\$test_email"/s);
assert.doesNotMatch(windowsLoginMetadataPreflight, /find-generic-password[^\n]* -w/);
assert.equal(
  (windowsGuestLoginSource.match(/find-generic-password -s "\$keychain_service" -w/g) ?? []).length,
  1,
);
assert.match(windowsGuestLoginSource, /https:\/\/www[.]enterpriseaigroup[.]com\/sign-in/);
assert.doesNotMatch(windowsGuestLoginSource, /open .*admin-portal[.]myenterprise[.]ai/);
assert.match(windowsGuestLoginSource, /--force-renderer-accessibility/);
assert.match(windowsGuestLoginSource, /windows-ui-action[.]ps1/);
assert.match(windowsGuestLoginSource, /source "\$ROOT\/scripts\/windows-hidden-current-user[.]sh"/);
assert.match(windowsGuestLoginSource, /printf '%s\\n' "\$script" \| windows_hidden_current_user_ps "\$vm_name" ""/);
assert.match(windowsGuestLoginSource, /for _ in \$\(seq 1 120\); do/);
assert.match(windowsGuestLoginSource, /is_parallels_session_open_failure "\$output"/);
assert.match(windowsGuestLoginSource, /is_parallels_exact_job_result_failure\(\) \{/);
assert.match(windowsGuestLoginSource, /run_idempotent_ui_action\(\) \{/);
assert.match(windowsGuestLoginSource, /if ! run_idempotent_ui_action edge-first-run 120[\s\S]*run_ui_action_once invoke-public-email 30/);
assert.match(windowsGuestLoginSource, /'PrlVmGuest_RunProgram: Invalid argument'/);
assert.match(windowsGuestLoginSource, /'PrlJob_GetResult: Invalid argument[.] An invalid argument was passed[.]'/);
assert.doesNotMatch(windowsGuestLoginSource, /\[\[ "\$output" == \*"Invalid argument"\*/);
assert.doesNotMatch(windowsGuestLoginSource, /--current-user cmd[.]exe/);
assert.match(windowsHiddenCurrentUserSource, /-InputFormat Text -OutputFormat Text -Command -/);
assert.match(windowsHiddenCurrentUserSource, /stage_base="\$\{base\}[.]tmp"/);
assert.match(windowsHiddenCurrentUserSource, /Move-Item -LiteralPath '\$stage_base' -Destination '\$base' -ErrorAction Stop/);
assert.match(windowsHiddenCurrentUserSource, /EAI_HIDDEN_WORKER_STAGED/);
assert.match(windowsHiddenCurrentUserSource, /if ! windows_hidden_bounded_prlctl 600 exec "\$vm_name" --current-user wscript[.]exe/);
assert.doesNotMatch(
  windowsHiddenCurrentUserSource,
  /windows_hidden_bounded_prlctl 600 exec "\$vm_name" --current-user wscript[.]exe[^\n]*\|\| true/,
);
assert.match(windowsDiagnosticCleanupPowerShellSource, /guest-cleanup-failed-line-\$line-stack-\$stackLine/);
assert.match(windowsDiagnosticCleanupSource, /source "\$ROOT\/scripts\/windows-hidden-current-user[.]sh"/);
assert.match(windowsDiagnosticCleanupSource, /\} \| run_hidden_cleanup_ps >"\$raw_stdout" 2>"\$raw_stderr"/);
assert.match(windowsDiagnosticCleanupSource, /windows_hidden_current_user_ps "\$vm_name" ""/);
assert.doesNotMatch(windowsDiagnosticCleanupSource, /\} \| "\$prlctl_bin" exec "\$vm_name" --current-user powershell[.]exe/);
assert.doesNotMatch(windowsGuestLoginSource, /Shell[.]Application|ShellExecute/);
assert.match(windowsGuestLoginSource, /\[wmiclass\]'\\\\[.]\\root\\cimv2:Win32_ProcessStartup'/);
assert.match(windowsGuestLoginSource, /\$startup[.]WinstationDesktop = 'winsta0\\default'/);
assert.match(windowsGuestLoginSource, /\$startup[.]CreateFlags = \[uint32\]1536/);
assert.match(windowsGuestLoginSource, /\$processClass[.]Create\(\$commandLine, \(Split-Path -Parent \$edge\), \$startup\)/);
assert.match(windowsGuestLoginSource, /\$name[.]StartsWith\('EAI_', \[StringComparison\]::OrdinalIgnoreCase\)/);
assert.match(windowsGuestLoginSource, /\[void\]\$process[.]Handle/);
assert.match(windowsGuestLoginSource, /\$process[.]SessionId -ne \$sessionId/);
assert.match(windowsGuestLoginSource, /\$ownerSid[.]Sid -cne \$identity[.]User[.]Value/);
assert.match(windowsGuestLoginSource, /\[string\]\$cim[.]CommandLine -cne \$commandLine/);
assert.match(windowsGuestLoginSource, /EDGE_LOCAL_WMI_LAUNCH_READY/);
assert.match(windowsGuestLoginSource, /grep -Fqx 'EDGE_LOCAL_WMI_LAUNCH_READY'/);
assert.match(windowsGuestLoginSource, /GetFolderPath\(\[Environment\+SpecialFolder\]::LocalApplicationData\)/);
assert.match(windowsGuestLoginSource, /Microsoft\\Edge\\User Data/);
assert.match(windowsGuestLoginSource, /expectedRoot = Join-Path \$env:LOCALAPPDATA/);
assert.match(windowsGuestLoginSource, /Get-Process msedge -ErrorAction SilentlyContinue \| Stop-Process -Force/);
assert.match(windowsGuestLoginSource, /Remove-Item -LiteralPath \$profileRoot -Recurse -Force/);
assert.match(windowsGuestLoginSource, /DISPOSABLE_EDGE_PROFILE_READY/);
assert.match(windowsGuestLoginSource, /wait_enterprise_portal_https/);
assert.match(windowsGuestLoginSource, /Get-Command "curl[.]exe"/);
assert.match(windowsGuestLoginSource, /EAI_HTTP_STATUS=%\{http_code\}/);
assert.match(windowsGuestLoginSource, /EAI_EFFECTIVE_URL=%\{url_effective\}/);
assert.match(windowsGuestLoginSource, /ENTERPRISE_PORTAL_HTTPS_READY/);
const windowsLoginReadOnlyPowerShellStart = windowsGuestLoginSource.indexOf("run_guest_powershell_readonly() {");
const windowsLoginUiActionOnceStart = windowsGuestLoginSource.indexOf("run_ui_action_once() {");
const windowsLoginIdempotentUiStart = windowsGuestLoginSource.indexOf("run_idempotent_ui_action() {");
const windowsLoginReadOnlyUiStart = windowsGuestLoginSource.indexOf("run_readonly_ui_action() {");
const windowsLoginLaunchEdgeStart = windowsGuestLoginSource.indexOf("launch_edge() {");
assert.ok(
  windowsLoginReadOnlyPowerShellStart >= 0
    && windowsLoginUiActionOnceStart > windowsLoginReadOnlyPowerShellStart
    && windowsLoginIdempotentUiStart > windowsLoginUiActionOnceStart
    && windowsLoginReadOnlyUiStart > windowsLoginIdempotentUiStart
    && windowsLoginLaunchEdgeStart > windowsLoginReadOnlyUiStart,
);
const windowsLoginReadOnlyPowerShellSource = windowsGuestLoginSource.slice(
  windowsLoginReadOnlyPowerShellStart,
  windowsLoginUiActionOnceStart,
);
const windowsLoginUiActionOnceSource = windowsGuestLoginSource.slice(
  windowsLoginUiActionOnceStart,
  windowsLoginIdempotentUiStart,
);
const windowsLoginIdempotentUiSource = windowsGuestLoginSource.slice(
  windowsLoginIdempotentUiStart,
  windowsLoginReadOnlyUiStart,
);
const windowsLoginReadOnlyUiSource = windowsGuestLoginSource.slice(
  windowsLoginReadOnlyUiStart,
  windowsLoginLaunchEdgeStart,
);
assert.match(windowsLoginReadOnlyPowerShellSource, /for attempt in \$\(seq 1 3\); do/);
assert.match(windowsLoginReadOnlyPowerShellSource, /"\$status" == 255/);
assert.match(windowsLoginReadOnlyPowerShellSource, /is_parallels_exact_job_result_failure "\$output"/);
assert.match(windowsLoginReadOnlyPowerShellSource, /sleep 2/);
assert.doesNotMatch(windowsLoginReadOnlyPowerShellSource, /input|Invoke-WindowsUiAction|Remove-Item|Start-Process/);
assert.doesNotMatch(windowsLoginUiActionOnceSource, /for attempt|is_parallels_exact_job_result_failure/);
assert.match(windowsLoginIdempotentUiSource, /edge-first-run\|focus-email\|focus-password/);
assert.match(windowsLoginIdempotentUiSource, /for attempt in \$\(seq 1 3\); do/);
assert.match(windowsLoginIdempotentUiSource, /is_parallels_exact_job_result_failure "\$output"/);
assert.doesNotMatch(windowsLoginIdempotentUiSource, /invoke-next|invoke-sign-in|input type/);
assert.match(windowsGuestLoginSource, /run_idempotent_ui_action focus-email 60/);
assert.match(windowsGuestLoginSource, /run_idempotent_ui_action focus-password 60/);
assert.match(windowsLoginReadOnlyUiSource, /"\$action" == probe-portal-ready \|\| "\$action" == wait-portal-ready/);
assert.match(windowsLoginReadOnlyUiSource, /for attempt in \$\(seq 1 3\); do/);
assert.match(windowsLoginReadOnlyUiSource, /"\$status" == 255/);
assert.doesNotMatch(windowsLoginReadOnlyUiSource, /input type|invoke-public-email|invoke-next|invoke-sign-in/);
assert.match(windowsGuestLoginSource, /wait_enterprise_portal_https\(\) \{[\s\S]*run_guest_powershell_readonly <<'POWERSHELL'/);
assert.match(windowsGuestLoginSource, /portal_ready_state\(\) \{[\s\S]*run_readonly_ui_action probe-portal-ready 5/);
assert.match(windowsGuestLoginSource, /wait_portal_ready\(\) \{[\s\S]*run_readonly_ui_action wait-portal-ready/);
assert.match(windowsGuestLoginSource, /EAI_PORTAL_READY/);
assert.match(windowsGuestLoginSource, /EAI_PORTAL_NOT_READY/);
assert.match(windowsGuestLoginSource, /unauthenticated portal state could not be proven/);
assert.equal((windowsGuestLoginSource.match(/reset_edge_profile >\/dev\/null/g) ?? []).length, 1);
assert.match(windowsGuestLoginSource, /printf '%s' "\$test_email" \| input type --stdin/);
assert.match(windowsGuestLoginSource, /find-generic-password -s "\$keychain_service" -w[\s\\]*\| input type --stdin/);
const windowsBrowserLoginFlow = windowsGuestLoginSource.slice(
  windowsGuestLoginSource.indexOf('if [[ "$mode" != cli ]]'),
  windowsGuestLoginSource.indexOf("cli_exists()"),
);
const mandatoryFreshLoginSteps = [
  "reset_edge_profile",
  "wait_enterprise_portal_https",
  "launch_edge",
  "if portal_ready_state",
  "run_ui_action_once invoke-public-email",
  "run_ui_action_once invoke-portal-microsoft",
  "run_idempotent_ui_action focus-email",
  "input type --stdin",
  "run_ui_action_once invoke-next",
  "run_idempotent_ui_action focus-password",
  "find-generic-password -s \"$keychain_service\" -w",
  "run_ui_action_once invoke-sign-in",
  "wait_portal_ready 120",
  "FRESH_PROTECTED_LOGIN_PROVEN",
];
let previousFreshLoginStep = -1;
for (const step of mandatoryFreshLoginSteps) {
  const stepIndex = windowsBrowserLoginFlow.indexOf(step, previousFreshLoginStep + 1);
  assert.notEqual(stepIndex, -1, `missing mandatory fresh Windows login step: ${step}`);
  assert.ok(stepIndex > previousFreshLoginStep, `out-of-order fresh Windows login step: ${step}`);
  previousFreshLoginStep = stepIndex;
}
assert.match(windowsBrowserLoginFlow, /replacement snapshot already has an authenticated portal session/);
assert.match(windowsGuestLoginSource, /Join-Path \$env:APPDATA "npm\\eai[.]cmd"\) login/);
assert.match(windowsGuestLoginSource, /Join-Path \$env:APPDATA "npm\\eai[.]cmd"\) whoami/);
assert.match(windowsGuestLoginSource, /tenant list --format json/);
assert.match(
  windowsGuestLoginSource,
  /if cli_identity_is_active && cli_tenant_matches; then[\s\S]*AUTHENTICATED_PORTAL_AND_CLI_READY[\s\S]*exit 0/,
);
assert.ok(
  windowsGuestLoginSource.indexOf("if cli_identity_is_active && cli_tenant_matches; then")
    < windowsGuestLoginSource.indexOf("# The CLI opens its localhost callback"),
  "verified CLI-session reuse must precede a fresh browser callback",
);
const windowsCliTenantStart = windowsGuestLoginSource.indexOf("cli_tenant_matches() {");
const windowsCliTenantEnd = windowsGuestLoginSource.indexOf(
  '\n}\n\ncli_exists ||',
  windowsCliTenantStart,
);
assert.ok(windowsCliTenantStart >= 0 && windowsCliTenantEnd > windowsCliTenantStart);
const windowsCliTenantSource = windowsGuestLoginSource.slice(windowsCliTenantStart, windowsCliTenantEnd);
assert.match(windowsCliTenantSource, /for attempt in \$\(seq 1 3\); do/);
assert.match(windowsCliTenantSource, /tenant list --format json'[\s\S]*windows_hidden_current_user_ps "\$vm_name"/);
assert.match(windowsCliTenantSource, /\[\[ "\$output_status" == 255 \]\]/);
assert.match(windowsCliTenantSource, /is_parallels_exact_job_result_failure "\$tenant_json"/);
assert.match(windowsCliTenantSource, /if \[\[ "\$output_status" != 0 \]\]; then/);
assert.match(windowsCliTenantSource, /sleep 2[\s\S]*continue/);
assert.match(windowsCliTenantSource, /Array[.]isArray\(tenants\) [?] tenants[.]filter/);
assert.match(windowsCliTenantSource, /matches[.]length !== 1/);
assert.match(windowsCliTenantSource, /tenant_json=""/);
assert.doesNotMatch(windowsCliTenantSource, /is_parallels_ui_action_transport_failure/);
assert.doesNotMatch(windowsCliTenantSource, /is_parallels_session_open_failure/);
assert.doesNotMatch(windowsCliTenantSource, /\*"Invalid argument"\*/);
assert.doesNotMatch(windowsCliTenantSource, /printf '%s\\n' "\$tenant_json"/);
assert.doesNotMatch(windowsGuestLoginSource, /Set-Clipboard|Get-Clipboard|clip[.]exe|pbcopy/);
assert.match(windowsUiActionSource, /Get-Process -Name "msedge"/);
assert.match(windowsUiActionSource, /ControlType "Hyperlink"/);
assert.match(windowsUiActionSource, /Continue with Email, Google, or Microsoft/);
assert.match(windowsUiActionSource, /Sign in with Microsoft/);
assert.match(windowsUiActionSource, /function Test-ExactEdgeState/);
assert.match(windowsUiActionSource, /function Test-PostSignInState/);
assert.match(windowsUiActionSource, /More than one visible approved destination element matched; refusing an ambiguous state/);
assert.match(windowsUiActionSource, /Confirm and continue/);
assert.match(windowsUiActionSource, /Find-ExactEdgeElements -Names @\("Refresh"\) -ControlType "Button"/);
assert.match(windowsUiActionSource, /More than one visible Edge refresh action matched; refusing an ambiguous action/);
assert.match(windowsUiActionSource, /More than one visible approved UI element matched; refusing an ambiguous action/);
for (const expectedOrigin of [
  /ExpectedHost "www[.]enterpriseaigroup[.]com"/,
  /ExpectedHost "admin-portal[.]myenterprise[.]ai"/,
  /ExpectedHost "enterpriseaiplatform[.]ciamlogin[.]com"/,
]) {
  assert.match(windowsUiActionSource, expectedOrigin);
}
assert.match(windowsUiActionSource, /ExpectedPath "\/sign-in"/);
assert.match(windowsUiActionSource, /ExpectedPath "\/login"/);
assert.match(windowsUiActionSource, /AutomationIdProperty,\s*"i0118"/);
assert.match(windowsUiActionSource, /NameProperty,\s*"Enter the password for \{0\}"/);
assert.match(windowsUiActionSource, /IsPasswordProperty,\s*\$true/);
assert.match(windowsUiActionSource, /\$normalizedPath -ine "\/platform\/getting-started"/);
assert.match(windowsUiActionSource, /Test-ExactEdgeElement -Names @\("Getting started"\) -ControlType "Any"/);
assert.match(windowsUiActionSource, /Test-ExactEdgeElement -Names @\("All apps"\) -ControlType "Any"/);
assert.match(windowsUiActionSource, /"probe-portal-ready"/);
assert.match(windowsUiActionSource, /EAI_PORTAL_READY/);
assert.match(windowsUiActionSource, /EAI_PORTAL_NOT_READY/);
assert.match(windowsUiActionSource, /ValuePattern[\s\S]*Current[.]Value/);
assert.doesNotMatch(windowsUiActionSource, /SetValue|SendKeys|Set-Clipboard|Get-Clipboard|clip[.]exe/);
for (const cleanupAction of [
  "wait-platform-apps",
  "invoke-create-app-split-arrow",
  "invoke-manage-app",
  "probe-manage-app-search",
  "focus-manage-app-search",
  "invoke-exact-app-delete",
  "focus-delete-confirmation",
  "assert-delete-ready",
]) {
  assert.match(windowsUiActionSource, new RegExp(`"${cleanupAction}"`));
}
assert.doesNotMatch(windowsUiActionSource, /"invoke-delete-permanently"/);
assert.match(windowsUiActionSource, /function Assert-PortalAppsLocation/);
assert.match(windowsUiActionSource, /Host -ine "admin-portal[.]myenterprise[.]ai"/);
assert.match(windowsUiActionSource, /AbsolutePath[.]TrimEnd\("\/"\) -ine "\/platform\/apps"/);
assert.match(windowsUiActionSource, /IsDefaultPort/);
assert.match(windowsUiActionSource, /IsNullOrEmpty\(\$uri[.]Query\)/);
assert.match(windowsUiActionSource, /TreeWalker\]::ControlViewWalker/);
assert.match(windowsUiActionSource, /Test-RectanglesAreAdjacentSplitButtons/);
assert.match(windowsUiActionSource, /function Expand-UiElement/);
assert.match(windowsUiActionSource, /ExpandCollapsePattern\]::Pattern/);
assert.match(windowsUiActionSource, /\$expandPattern[.]Expand\(\)/);
assert.match(windowsUiActionSource, /Expand-UiElement -Element \$arrow/);
assert.match(windowsUiActionSource, /function Get-ManageAppDialogWindow/);
assert.match(windowsUiActionSource, /ControlType\]::Window/);
assert.match(windowsUiActionSource, /EAI_MANAGE_APP_SEARCH_PRESENT/);
assert.match(windowsUiActionSource, /EAI_MANAGE_APP_SEARCH_ABSENT/);
assert.match(windowsUiActionSource, /Delete \{0\}" -f \$Target[.]DisplayName/);
assert.match(windowsUiActionSource, /ValuePattern\]\$pattern\)[.]Current[.]Value/);
assert.match(windowsPortalCleanupUiSource, /state[.]cleanupRequired !== true/);
assert.match(windowsPortalCleanupUiSource, /result[.]exactLocalProjectCheckpoint === true/);
assert.match(windowsPortalCleanupUiSource, /windows-remote-cleanup-arm[.]v1/);
assert.match(windowsPortalCleanupUiSource, /PortalTargetOnly/);
assert.match(windowsPortalCleanupUiSource, /servicesBeforeDeletion !== 0/);
assert.match(windowsPortalCleanupUiSource, /workflowExactMatchesBeforeDeletion !== 0/);
assert.match(windowsPortalCleanupUiSource, /setupExactMatchesBeforeDeletion !== 0/);
assert.match(windowsPortalCleanupUiSource, /run_readonly_ui_action wait-platform-apps/);
assert.match(windowsPortalCleanupUiSource, /run_readonly_ui_action probe-manage-app-search/);
assert.match(windowsPortalCleanupUiSource, /run_readonly_ui_action assert-delete-ready/);
assert.match(windowsPortalCleanupUiSource, /run_ui_action_once invoke-exact-app-delete/);
assert.match(windowsPortalCleanupUiSource, /run_ui_action_once invoke-create-app-split-arrow/);
assert.match(windowsPortalCleanupUiSource, /run_ui_action_once invoke-manage-app/);
assert.match(windowsPortalCleanupUiSource, /run_ui_action_once focus-manage-app-search/);
assert.match(windowsPortalCleanupUiSource, /run_ui_action_once focus-delete-confirmation/);
assert.doesNotMatch(windowsPortalCleanupUiSource, /run_ui_action_once invoke-delete-permanently/);
assert.match(windowsPortalCleanupUiSource, /input combo command\+r/);
assert.match(windowsPortalCleanupUiSource, /windows-interactive-exact-delete[.]ps1/);
assert.match(windowsPortalCleanupUiSource, /run_interactive_worker_operation verify/);
assert.match(windowsPortalCleanupUiSource, /confirmationDialogClosed == true/);
assert.match(windowsPortalCleanupUiSource, /dialogAbsentConsecutiveChecks >= 12/);
assert.match(windowsPortalCleanupUiSource, /dialogClosureStableMilliseconds >= 3000/);
assert.match(windowsInteractiveExactDeleteSource, /Focus-UiElement -Element \$state[.]Final/);
assert.match(windowsInteractiveExactDeleteSource, /Invoke-UiElement -Element \$state[.]Final/);
assert.doesNotMatch(windowsInteractiveExactDeleteSource, /SendKeys|System[.]Windows[.]Forms/);
assert.match(windowsInteractiveExactDeleteSource, /sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke/);
assert.match(windowsInteractiveExactDeleteSource, /EaiExactDeleteForegroundWindow\]::GetForegroundWindow/);
assert.match(windowsInteractiveExactDeleteSource, /explorerOwnerSidMatched/);
assert.match(windowsInteractiveExactDeleteSource, /edgeOwnerSidMatched/);
assert.match(windowsUiActionSource, /function Get-TopLevelWindow/);
assert.match(windowsUiActionSource, /NativeWindowHandle/);
assert.match(windowsUiActionSource, /Get-VisibleDescendantElements -Root \$context[.]Window -Name "Delete permanently"/);
assert.match(windowsInteractiveExactDeleteSource, /\$consecutiveAbsentChecks -ge 12/);
assert.match(windowsInteractiveExactDeleteSource, /dialogClosureStableMilliseconds = 3000/);
assert.match(windowsInteractiveExactDeleteSource, /ExpectedGuestUserBase64/);
assert.match(windowsInteractiveExactDeleteSource, /The deletion worker is not running as the exact expected guest user/);
assert.match(windowsInteractiveExactDeleteSource, /\$interactiveSessionId = \[Diagnostics[.]Process\]::GetCurrentProcess\(\)[.]SessionId/);
assert.match(windowsInteractiveExactDeleteSource, /Get-Process -Name 'explorer'/);
assert.match(windowsInteractiveExactDeleteSource, /edgeUiBoundToInteractiveSession/);
assert.match(windowsInteractiveExactDeleteSource, /mutationState = if \(\$mutationMayHaveOccurred\) \{ 'uncertain' \} else \{ 'not-applied' \}/);
for (const attempt2Contract of [
  /--prepare-delete-attempt-2/,
  /--invoke-delete-attempt-2/,
  /--confirmation-nonce/,
  /eai[.]windows-portal-delete-attempt-1-still-present[.]v1/,
  /eai[.]windows-portal-delete-attempt-2-target[.]v1/,
  /eai[.]windows-portal-delete-attempt-2-prepared[.]v1/,
  /eai[.]windows-portal-delete-attempt-2-preinvoke[.]v1/,
  /eai[.]windows-portal-delete-attempt-2-invocation[.]v1/,
  /verificationStat[.]mtimeMs - invocationStat[.]mtimeMs/,
  /hostSettleMilliseconds < 60_000/,
  /resourceApiExactMatchesAfter !== 1/,
  /cliExactMatchesAfter !== 1/,
  /original[.]resourceIdSha256 !== result[.]resourceIdSha256/,
  /original[.]resourceCreatedAt !== result[.]resourceCreatedAt/,
  /original[.]displayName !== result[.]displayName/,
  /freshGuestAuthProven: true/,
  /explicitActionTimeConfirmationRequired: true/,
  /confirmationNonceSha256/,
  /preInvokeTargetRevalidationRequired: true/,
  /armedBeforeDestructiveInput: true/,
  /mutationState: "armed-uncertain"/,
  /flag: "wx"/,
  /invoked-dialog-closed-unverified/,
  /tenantIdSha256/,
  /[.]windows-portal-delete-attempt-2[.]lock/,
  /attempt2-expired-immediately-before-arm/,
]) {
  assert.match(windowsPortalCleanupUiSource, attempt2Contract);
}
assert.doesNotMatch(windowsPortalCleanupUiSource, /--attempt(?:[ =]|\s+<)/);
assert.match(windowsPortalCleanupUiSource, /if \[\[ -z "\$\{interactive_invocation_id:-\}" \]\]; then[\s\S]*uuidgen/);
const attempt2ArmPosition = windowsPortalCleanupUiSource.indexOf('schemaVersion: "eai.windows-portal-delete-attempt-2-invocation.v1"');
const attempt2LaunchPosition = windowsPortalCleanupUiSource.indexOf("run_interactive_delete_once", attempt2ArmPosition);
assert.ok(attempt2ArmPosition >= 0 && attempt2LaunchPosition > attempt2ArmPosition);
for (const portalCompletionContract of [
  /eai[.]windows-portal-delete-attempt-1-verification[.]v1/,
  /eai[.]windows-portal-delete-attempt-2-verification[.]v1/,
  /admin-portal-interactive-delete-attempt-1/,
  /admin-portal-interactive-delete-attempt-2/,
  /attempt2InvocationReceiptSha256/,
  /verifiedAbsentOnResourceApiAndCli: true/,
  /portalExactMatchesAfter: null/,
  /portalPermanentDeleteClicked: true/,
  /windows-portal-delete-attempt-2-verification[.]json/,
]) {
  assert.match(windowsDiagnosticCleanupSource, portalCompletionContract);
}
assert.match(windowsDiagnosticCleanupPowerShellSource, /vertical-service-activation/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /vertical-product-config/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /filterField = 'data[.]verticalKey'/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /completeBoundedPage = \$true/);
assert.doesNotMatch(windowsDiagnosticCleanupPowerShellSource, /Get-EmbeddedChildCounts|embeddedChildFieldsEmpty/);
assert.match(windowsDiagnosticCleanupSource, /finalize-windows-portal-evidence[.]mjs/);
assert.match(windowsPortalEvidenceFinalizerSource, /const alreadyFinalized/);
assert.match(windowsPortalEvidenceFinalizerSource, /receipt[.]deletionRecordedAt = receipt[.]deletionRecordedAt \|\| receipt[.]recordedAt/);
assert.match(windowsPortalEvidenceFinalizerSource, /fs[.]renameSync\(temporary, file\)/);
assert.ok(
  windowsPortalEvidenceFinalizerSource.indexOf("atomicWrite(process.env.EAI_VERIFICATION")
    < windowsPortalEvidenceFinalizerSource.indexOf("atomicWrite(process.env.EAI_RECEIPT"),
);
assert.doesNotMatch(windowsPortalCleanupUiSource, /run_readonly_ui_action (?:invoke|focus)-/);
assert.match(windowsPortalCleanupUiSource, /Only a read-only portal state probe may use the retry transport/);
assert.match(windowsPortalCleanupUiSource, /retryMutationAutomatically: false/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /action = 'portal-target-only'/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /C:\\Users\\Public\\EAIReleaseTests/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /function Resolve-ExactEaiCleanupProject/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /function Get-RealDirectoryWithoutReparsePoints/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /\[IO[.]FileAttributes\]::ReparsePoint/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /@eai-tools\/\$AppKey/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /[.]eai-manifest[.]json/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /src\\eai[.]config\\object-types[.]ts/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /Push-Location -LiteralPath \$binding[.]ProjectPath/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /Assert-CompleteBoundedResourcePage/);
assert.match(windowsDiagnosticCleanupPowerShellSource, /'--limit', '1000'/);
assert.doesNotMatch(windowsDiagnosticCleanupPowerShellSource, /'--where'/);
assert.ok(
  windowsDiagnosticCleanupPowerShellSource.indexOf("$projectBinding = Resolve-ExactEaiCleanupProject -AppKey $appKey")
    < windowsDiagnosticCleanupPowerShellSource.indexOf("if ($mode -ceq 'PortalTargetOnly')"),
);

assert.match(windowsGuestAdapterSource, /Invoke-WebRequest .*\$url .*eai-setup-under-test[.]exe/);
assert.match(windowsGuestAdapterSource, /Get-FileHash -Algorithm SHA256 'C:\\Users\\Public\\eai-setup-under-test[.]exe'/);
assert.match(windowsGuestAdapterSource, /host_hash="\$\(guest_test_host_sha256\)"/);
assert.match(windowsGuestAdapterSource, /"\$guest_hash" == "\$host_hash"/);
const windowsExactAssetDownloadSection = windowsGuestAdapterSource.slice(
  windowsExactAssetDownload,
  windowsExactAssetDownloadPassed,
);
const windowsDownloadInvoke = windowsExactAssetDownloadSection.indexOf("Invoke-WebRequest");
const windowsDownloadCompleteSignal = windowsExactAssetDownloadSection.indexOf("[IO.File]::Open($readyTemporary");
const windowsDownloadCompletePublish = windowsExactAssetDownloadSection.indexOf("[IO.File]::Move($readyTemporary, $readySignal)");
assert.ok(windowsDownloadInvoke >= 0 && windowsDownloadInvoke < windowsDownloadCompleteSignal);
assert.ok(windowsDownloadCompleteSignal < windowsDownloadCompletePublish);
assert.match(windowsExactAssetDownloadSection, /guest_system_ps_run "\$EAI_VM_DOWNLOAD_URL"\$'\\n' 5/);
assert.match(windowsExactAssetDownloadSection, /guest_hash="\$\(guest_system_ps_run "" 5/);
assert.doesNotMatch(windowsExactAssetDownloadSection, /\bguest_ps(?:_run)?\b|--current-user/);
assert.match(windowsExactAssetDownloadSection, /WellKnownSidType]::LocalSystemSid/);
assert.match(
  windowsExactAssetDownloadSection,
  /\$readyTemporary = 'C:\\Users\\Public\\eai-setup-defender-target-ready[.]signal[.]tmp'/,
);
assert.match(
  windowsExactAssetDownloadSection,
  /\$readySignal = 'C:\\Users\\Public\\eai-setup-defender-target-ready[.]signal'/,
);
assert.match(
  windowsExactAssetDownloadSection,
  /\[IO[.]File\]::Open\(\$readyTemporary, \[IO[.]FileMode\]::CreateNew, \[IO[.]FileAccess\]::Write, \[IO[.]FileShare\]::None\)/,
);
assert.match(
  windowsExactAssetDownloadSection,
  /\$readyAcl[.]SetOwner\(\$systemSid\)/,
);
assert.match(windowsExactAssetDownloadSection, /\$readyStream[.]Flush\(\$true\)/);
assert.match(windowsExactAssetDownloadSection, /Assert-SystemReadyMarker \$readyTemporary/);
assert.match(windowsExactAssetDownloadSection, /\[IO[.]File\]::Move\(\$readyTemporary, \$readySignal\)/);
assert.match(windowsExactAssetDownloadSection, /Assert-SystemReadyMarker \$readySignal/);
assert.match(windowsExactAssetDownloadSection, /\$item[.]PSIsContainer/);
assert.match(windowsExactAssetDownloadSection, /\$item[.]Attributes -band \[IO[.]FileAttributes\]::ReparsePoint/);
assert.match(windowsExactAssetDownloadSection, /\$item[.]FullName, \$path, \[StringComparison\]::OrdinalIgnoreCase/);
assert.match(windowsExactAssetDownloadSection, /\$acl[.]GetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]\)[.]Value -cne \$systemSid[.]Value/);
assert.match(windowsExactAssetDownloadSection, /\$item[.]Length -ne 17/);
assert.match(windowsExactAssetDownloadSection, /\$actualBytes[.]Length -ne 17/);
assert.match(windowsExactAssetDownloadSection, /\[Text[.]Encoding\]::ASCII[.]GetString\(\$actualBytes\) -cne \$expectedValue/);
assert.doesNotMatch(windowsExactAssetDownloadSection, /Move-Item\s+-Force|Set-Content/);
assert.match(windowsInstallerBridgeSource, /Start-Process -FilePath \$targetPath -ArgumentList '\/S' -PassThru/);
assert.doesNotMatch(windowsInstallerBridgeSource, /Start-Process[^\n]*-Wait/);
assert.match(windowsGuestAdapterSource, /Get-FileHash -Algorithm SHA256 \$executable/);
assert.match(windowsGuestAdapterSource, /"\$second_executable_hash" == "\$executable_hash"/);
assert.match(windowsGuardianSource, /WellKnownSidType]::LocalSystemSid/);
assert.match(windowsGuardianSource, /WindowsBuiltInRole]::Administrator/);
assert.match(windowsGuardianSource, /elevationMethod = 'parallels-protected-LocalSystem'/);
assert.match(windowsGuardianSource, /uacUsed = \$false/);
assert.match(windowsGuardianSource, /\$receipt\['receiptSystemOwned'\] = \$true/);
assert.match(windowsGuardianSource, /SetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]::new\('S-1-5-18'\)\)/);
assert.match(windowsGuardianSource, /\$targetPath = 'C:\\Users\\Public\\eai-setup-under-test[.]exe'/);
assert.match(windowsGuardianSource, /\$targetReadySignal = 'C:\\Users\\Public\\eai-setup-defender-target-ready[.]signal'/);
assert.match(windowsGuardianSource, /\$targetReadySignalTemporary = 'C:\\Users\\Public\\eai-setup-defender-target-ready[.]signal[.]tmp'/);
assert.match(windowsGuardianSource, /Add-MpPreference -ExclusionPath \$targetPath -Force -ErrorAction Stop/);
assert.match(windowsGuardianSource, /Remove-MpPreference -ExclusionPath \$targetPath -Force -ErrorAction Stop/);
assert.match(windowsGuardianSource, /-not \$baselineExactPresent -and \$addAttempted -and/);
const windowsGuardianPrecheckRefusal = windowsGuardianSource.indexOf("if ($baselineExactPresent -or -not $precheckProbeVerified)");
const windowsGuardianAddPreference = windowsGuardianSource.indexOf("Add-MpPreference -ExclusionPath $targetPath");
assert.ok(windowsGuardianPrecheckRefusal >= 0 && windowsGuardianPrecheckRefusal < windowsGuardianAddPreference);
const windowsMpProbeStart = windowsGuardianSource.indexOf("function Test-MpCmdExclusion");
const windowsMpProbeEnd = windowsGuardianSource.indexOf("\n}\n\ntry {", windowsMpProbeStart);
assert.ok(windowsMpProbeStart >= 0 && windowsMpProbeEnd > windowsMpProbeStart);
const windowsMpProbeSource = windowsGuardianSource.slice(windowsMpProbeStart, windowsMpProbeEnd);
assert.match(windowsMpProbeSource, /if \(-not \(Test-Path -LiteralPath \$path\)\)/);
assert.match(
  windowsMpProbeSource,
  /\[IO[.]File\]::Open\(\$path, \[IO[.]FileMode\]::CreateNew, \[IO[.]FileAccess\]::Write, \[IO[.]FileShare\]::None\)/,
);
const windowsMpProbeOwned = windowsMpProbeSource.indexOf("$createdProbe = $true");
const windowsMpProbeFirstDispose = windowsMpProbeSource.indexOf("$stream.Dispose()");
assert.ok(windowsMpProbeOwned >= 0 && windowsMpProbeOwned < windowsMpProbeFirstDispose);
assert.match(windowsMpProbeSource, /\$item[.]PSIsContainer/);
assert.match(windowsMpProbeSource, /\$item[.]Attributes -band \[IO[.]FileAttributes\]::ReparsePoint/);
assert.match(windowsMpProbeSource, /\$item[.]FullName, \$path, \[StringComparison\]::OrdinalIgnoreCase/);
assert.match(windowsMpProbeSource, /\$createdProbe -and \$item[.]Length -ne 0/);
assert.match(windowsMpProbeSource, /finally \{/);
assert.match(windowsMpProbeSource, /if \(\$createdProbe\)[\s\S]*\$probe[.]Length -ne 0/);
assert.match(windowsMpProbeSource, /Remove-Item -Force -LiteralPath \$path -ErrorAction Stop/);
assert.match(windowsMpProbeSource, /if \(Test-Path -LiteralPath \$path\)[\s\S]*probe could not be removed/);
assert.match(windowsGuardianSource, /\$mpVerifiedNotExcludedBefore = Test-MpCmdExclusion \$mpCmdRun \$targetPath 1/);
assert.match(
  windowsGuardianSource,
  /\$precheckProbeVerified = \$mpVerifiedNotExcludedBefore -and -not \(Test-Path -LiteralPath \$targetPath\)/,
);
assert.match(windowsGuardianSource, /\$awaitingTarget[.]precheckProbeVerified -ne \$true/);
assert.match(windowsGuardianSource, /\$awaitingTarget[.]soleExclusionDelta -ne \$true/);
assert.match(windowsGuardianSource, /\$awaitingTarget[.]ownedByGuardian -ne \$true/);
const windowsGuardianTargetAbsent = windowsGuardianSource.indexOf("if (Test-Path -LiteralPath $targetPath)");
const windowsGuardianAddExclusion = windowsGuardianSource.indexOf("Add-MpPreference -ExclusionPath $targetPath");
const windowsGuardianAwaitingTarget = windowsGuardianSource.indexOf("status = 'awaiting-target'");
const windowsGuardianCompletionSignal = windowsGuardianSource.indexOf("$completionSignalVerified = $true");
const windowsGuardianTargetHash = windowsGuardianSource.indexOf("$actualSha256 = (Get-FileHash");
const windowsGuardianTargetHashVerified = windowsGuardianSource.indexOf("$targetHashVerified = $true");
const windowsGuardianEffectiveExclusion = windowsGuardianSource.indexOf("$mpVerified = Test-MpCmdExclusion $mpCmdRun $targetPath 0");
const windowsGuardianReady = windowsGuardianSource.indexOf("status = 'ready'", windowsGuardianEffectiveExclusion);
assert.ok(windowsGuardianTargetAbsent >= 0 && windowsGuardianTargetAbsent < windowsGuardianAddExclusion);
assert.ok(windowsGuardianAddExclusion < windowsGuardianAwaitingTarget);
assert.ok(windowsGuardianAwaitingTarget < windowsGuardianCompletionSignal);
assert.ok(windowsGuardianCompletionSignal < windowsGuardianTargetHash);
assert.ok(windowsGuardianTargetHash < windowsGuardianTargetHashVerified);
assert.ok(windowsGuardianTargetHashVerified < windowsGuardianEffectiveExclusion);
assert.ok(windowsGuardianEffectiveExclusion < windowsGuardianReady);
assert.match(windowsGuardianSource, /Test-Path -LiteralPath \$targetPath -PathType Leaf[\s\S]*Test-Path -LiteralPath \$targetReadySignal -PathType Leaf/);
assert.match(windowsGuardianSource, /\[IO[.]File\]::Open\(\$targetReadySignal, \[IO[.]FileMode\]::Open, \[IO[.]FileAccess\]::Read, \[IO[.]FileShare\]::Read\)/);
assert.match(windowsGuardianSource, /\$signal[.]Length -ne \$expectedSignalBytes[.]Length/);
assert.match(windowsGuardianSource, /\$signalStream[.]Length -ne \$expectedSignalBytes[.]Length/);
assert.match(windowsGuardianSource, /\[Text[.]Encoding\]::ASCII[.]GetString\(\$actualSignalBytes\) -cne \$expectedSignalValue/);
assert.doesNotMatch(windowsGuardianSource, /Get-Content -Raw -LiteralPath \$targetReadySignal[)]?[.]Trim\(\)/);
assert.match(windowsGuardianSource, /if \(\$actualSha256 -cne \$expectedSha256\)/);
assert.match(windowsGuardianSource, /Remove-Item -Force -LiteralPath \$targetReadySignal, \$targetReadySignalTemporary -ErrorAction SilentlyContinue/);
assert.match(windowsGuardianSource, /for \(\$poll = 0; \$poll -lt 15; \$poll\+\+\)/);
assert.match(windowsGuardianSource, /Test-MpCmdExclusion \$mpCmdRun \$targetPath 1/);
assert.match(windowsGuardianSource, /Test-MpCmdExclusion \$mpCmdRun \$targetPath 0/);
assert.match(windowsGuardianSource, /\$timeoutSeconds = 900/);
assert.match(windowsGuardianSource, /for attempt in \$\(seq 1 960\)/);
assert.match(windowsGuardianSource, /eai-windows-defender-unarmed-quarantine\/v1/);
const windowsUnarmedGuardianQuarantine = windowsGuardianSource.indexOf(
  'if [[ "$signal_sent" == 1 ]] && guest_system_ps_run',
);
const windowsArmedGuardianRemovalPoll = windowsGuardianSource.indexOf(
  "for attempt in $(seq 1 960)",
  windowsUnarmedGuardianQuarantine,
);
assert.ok(
  windowsUnarmedGuardianQuarantine >= 0
    && windowsUnarmedGuardianQuarantine < windowsArmedGuardianRemovalPoll,
);
const windowsUnarmedGuardianQuarantineSource = windowsGuardianSource.slice(
  windowsUnarmedGuardianQuarantine,
  windowsArmedGuardianRemovalPoll,
);
assert.match(windowsUnarmedGuardianQuarantineSource, /eai-setup-defender-done[.]signal/);
assert.match(windowsUnarmedGuardianQuarantineSource, /eai-setup-defender-guardian-armed[.]json/);
assert.match(windowsUnarmedGuardianQuarantineSource, /eai-setup-defender-add[.]json/);
assert.match(windowsUnarmedGuardianQuarantineSource, /eai-setup-defender-remove[.]json/);
assert.match(windowsUnarmedGuardianQuarantineSource, /defender_cleanup_wait_exhausted=1/);
assert.match(windowsUnarmedGuardianQuarantineSource, /write_unarmed_defender_guardian_quarantine/);
assert.match(windowsUnarmedGuardianQuarantineSource, /return 1/);
assert.doesNotMatch(windowsUnarmedGuardianQuarantineSource, /defender_exclusion_pending=0|removed-verified|[.]Kill\(|Stop-Process/);
assert.match(windowsGuardianSource, /baselineExclusionSetRestored = \$baselineRestored/);
assert.match(windowsGuardianSource, /protectionSettingsUnchanged = \$protectionUnchanged/);
assert.match(windowsGuardianSource, /"cleanup:\$\{expectedSha256\}:\$\{expectedWorkerSha256\}:\$\{expectedWorkerNonce\}"/);
assert.match(windowsGuardianSource, /\[IO[.]File\]::Open\(\$temporaryPath, \[IO[.]FileMode\]::CreateNew/);
assert.match(windowsGuardianSource, /\$acl[.]SetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]::new\(\$systemSid\)\)/);
assert.doesNotMatch(windowsGuardianSource, /EAI_HARNESS|EAI_SETUP_E2E_COMPANY_TENANT|find-generic-password/);
assert.doesNotMatch(windowsGuardianSource, /Set-MpPreference|ExclusionProcess|ExclusionExtension|DisableRealtimeMonitoring|Unblock-File|AllowThreat/);
for (const guardianArtifact of [
  "eai-setup-defender-add.json",
  "eai-setup-defender-add.json.tmp",
  "eai-setup-defender-remove.json",
  "eai-setup-defender-remove.json.tmp",
  "eai-setup-defender-guardian.ps1",
  "eai-setup-defender-guardian.ps1.tmp",
  "eai-setup-defender-guardian-armed.json",
  "eai-setup-defender-guardian-armed.json.tmp",
  "eai-setup-defender-done.signal",
  "eai-setup-defender-done.signal.tmp",
  "eai-setup-defender-target-ready.signal",
  "eai-setup-defender-target-ready.signal.tmp",
]) {
  assert.match(windowsGuestAdapterSource, new RegExp(`C:\\\\Users\\\\Public\\\\${guardianArtifact.replaceAll(".", "[.]")}`));
}
for (const installerBridgeArtifact of [
  "eai-setup-installer-worker.ps1",
  "eai-setup-installer-worker.ps1.tmp",
  "eai-setup-installer-bridge-armed.json",
  "eai-setup-installer-bridge-armed.json.tmp",
  "eai-setup-installer-launch.signal",
  "eai-setup-installer-launch.signal.tmp",
  "eai-setup-installer-cancel.signal",
  "eai-setup-installer-cancel.signal.tmp",
  "eai-setup-installer-complete.json",
  "eai-setup-installer-complete.json.tmp",
]) {
  assert.match(windowsGuestAdapterSource, new RegExp(`C:\\\\Users\\\\Public\\\\${installerBridgeArtifact.replaceAll(".", "[.]")}`));
}
assert.match(windowsInstallerBridgeSource, /windows_hidden_current_user_ps "\$vm_name" ""/);
assert.equal(
  (windowsInstallerBridgeSource.match(/windows_hidden_current_user_ps "\$vm_name" ""/g) ?? []).length,
  1,
);
assert.match(windowsInstallerBridgeSource, /eai-setup-installer-worker[.]ps1/);
assert.match(windowsInstallerBridgeSource, /DETACHED_INSTALLER_WORKER_ARMED:/);
assert.match(windowsInstallerBridgeSource, /tr -d '\\r' <"\$bridge_stdout"/);
assert.match(windowsInstallerBridgeSource, /Start-Process -FilePath \$powerShellPath -ArgumentList \$arguments -WindowStyle Hidden -PassThru/);
assert.match(windowsInstallerBridgeSource, /workerScriptSha256 = \$expectedWorkerSha256/);
assert.match(windowsInstallerBridgeSource, /workerNonce = \$expectedWorkerNonce/);
assert.match(windowsInstallerBridgeSource, /workerProcessId = \$workerProcessId/);
assert.match(windowsInstallerBridgeSource, /workerProcessStartedAt = \$workerProcessStartedAt/);
assert.match(windowsInstallerBridgeSource, /workerProcessSessionId = \$workerProcessSessionId/);
assert.match(windowsInstallerBridgeSource, /workerSessionVerified = \$workerSessionVerified/);
const windowsInstallerWorkerLock = windowsInstallerBridgeSource.indexOf(
  "$workerLoadLock = [IO.File]::Open($workerScriptPath",
);
const windowsInstallerLockedHash = windowsInstallerBridgeSource.indexOf(
  "$lockedWorkerHasher.ComputeHash($workerLoadLock)",
);
const windowsInstallerDetachedLaunch = windowsInstallerBridgeSource.indexOf(
  "Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru",
);
assert.ok(windowsInstallerWorkerLock >= 0 && windowsInstallerWorkerLock < windowsInstallerLockedHash);
assert.ok(windowsInstallerLockedHash < windowsInstallerDetachedLaunch);
const windowsInstallerBootstrapReaped = windowsInstallerBridgeSource.indexOf('wait "$bootstrap_pid"');
const windowsInstallerArmFunctionEnd = windowsInstallerBridgeSource.indexOf("\n}\n\nwrite_installer_bridge_signal() {");
assert.ok(windowsInstallerBootstrapReaped >= 0 && windowsInstallerBootstrapReaped < windowsInstallerArmFunctionEnd);
assert.doesNotMatch(
  windowsInstallerBridgeSource.slice(windowsInstallerBootstrapReaped, windowsInstallerArmFunctionEnd),
  /guest_system_ps|prlctl exec/,
);
assert.match(windowsInstallerBridgeSource, /schemaVersion = 'eai-windows-installer-bridge\/v1'/);
assert.match(windowsInstallerBridgeSource, /\$launchWaitSeconds = 300/);
assert.match(windowsInstallerBridgeSource, /\$installerTimeoutSeconds = 300/);
assert.match(windowsInstallerBridgeSource, /\$systemSid = 'S-1-5-18'/);
assert.match(windowsInstallerBridgeSource, /GetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]\)[.]Value/);
assert.match(windowsInstallerBridgeSource, /SetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]::new\(\$systemSid\)\)/);
assert.match(windowsInstallerBridgeSource, /\[IO[.]File\]::Open\(\$temporaryPath, \[IO[.]FileMode\]::CreateNew/);
assert.match(windowsInstallerBridgeSource, /"launch:\$\{expectedSha256\}:\$\{expectedWorkerSha256\}:\$\{expectedWorkerNonce\}"/);
assert.match(windowsInstallerBridgeSource, /"cancel:\$\{expectedSha256\}:\$\{expectedWorkerSha256\}:\$\{expectedWorkerNonce\}"/);
assert.match(windowsInstallerBridgeSource, /Move-Item -LiteralPath \$temporaryPath -Destination \$finalPath -ErrorAction Stop/);
assert.doesNotMatch(windowsInstallerBridgeSource, /Move-Item -Force -LiteralPath \$temporaryPath -Destination \$finalPath/);
assert.match(windowsInstallerBridgeSource, /\$defenderReceipt[.]receiptSystemOwned -eq \$true/);
assert.match(windowsInstallerBridgeSource, /\$defenderAcl[.]GetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]\)[.]Value -cne \$systemSid/);
assert.match(windowsInstallerBridgeSource, /\$defenderReceiptAcl[.]GetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]\)[.]Value -cne \$systemSid/);
assert.match(windowsInstallerBridgeSource, /\$targetHashVerified = \$launchSha256 -ceq \$expectedSha256/);
assert.match(windowsInstallerBridgeSource, /\$targetLaunchLock = \[IO[.]File\]::Open\(/);
assert.match(windowsInstallerBridgeSource, /\[IO[.]FileShare\]::Read/);
assert.match(windowsInstallerBridgeSource, /\$targetLaunchLockVerified = \$targetHashVerified/);
assert.match(windowsInstallerBridgeSource, /\$installerProcess[.]StartInfo[.]FileName/);
assert.match(windowsInstallerBridgeSource, /function ConvertTo-ComparableWindowsPath/);
assert.match(windowsInstallerBridgeSource, /StartsWith\('\\\\[?]\\UNC\\'/);
assert.match(windowsInstallerBridgeSource, /launchStartInfoPathVerified = \$launchStartInfoPathVerified/);
assert.match(windowsInstallerBridgeSource, /liveProcessPathVerified = \$liveProcessPathVerified/);
assert.match(windowsInstallerBridgeSource, /liveProcessExitedBeforePathInspection = \$liveProcessExitedBeforePathInspection/);
assert.match(windowsInstallerBridgeSource, /installerProcessId = \$installerProcessId/);
assert.match(windowsInstallerBridgeSource, /\$installerProcessId = \$installerProcess[.]Id/);
assert.match(windowsInstallerBridgeSource, /\$installerProcess[.]WaitForExit\(0\)/);
assert.match(
  windowsInstallerBridgeSource,
  /\$processPathVerified = \$launchStartInfoPathVerified -and\s+\(\$liveProcessPathVerified -eq \$true -or \$liveProcessExitedBeforePathInspection\)/,
);
assert.doesNotMatch(windowsInstallerBridgeSource, /\$installerProcess[.]HasExited/);
assert.match(windowsInstallerBridgeSource, /targetLaunchLockVerified = \$targetLaunchLockVerified/);
const windowsTargetLaunchLock = windowsInstallerBridgeSource.indexOf("$targetLaunchLock = [IO.File]::Open(");
const windowsTargetLockedHash = windowsInstallerBridgeSource.indexOf("$targetLaunchHasher.ComputeHash($targetLaunchLock)");
const windowsInstallerFastStart = windowsInstallerBridgeSource.indexOf("Start-Process -FilePath $targetPath -ArgumentList '/S' -PassThru");
const windowsTargetLockRelease = windowsInstallerBridgeSource.indexOf("$targetLaunchLock.Dispose()", windowsInstallerFastStart);
assert.ok(windowsTargetLaunchLock >= 0 && windowsTargetLaunchLock < windowsTargetLockedHash);
assert.ok(windowsTargetLockedHash < windowsInstallerFastStart);
assert.ok(windowsInstallerFastStart < windowsTargetLockRelease);
assert.match(windowsInstallerBridgeSource, /Stop-OwnedInstaller \$installerProcess/);
assert.match(windowsInstallerBridgeSource, /Stop-Process -Id \$process[.]Id -Force -ErrorAction Stop/);
assert.match(windowsInstallerBridgeSource, /\$cancelRequested = \$true[\s\S]*\$bridgeStatus = 'cancelled-before-launch'/);
assert.match(windowsInstallerBridgeSource, /windows-installer-bridge[.]json/);
assert.match(windowsGuestAdapterSource, /windows-installer-bridge[.]stdout[.]log/);
assert.match(windowsGuestAdapterSource, /windows-installer-bridge[.]stderr[.]log/);
assert.doesNotMatch(windowsInstallerBridgeSource, /EAI_HARNESS|EAI_SETUP_E2E_COMPANY_TENANT|find-generic-password/);
assert.match(windowsGuardianSource, /eai-setup-defender-guardian[.]ps1/);
assert.match(windowsGuardianSource, /DETACHED_DEFENDER_GUARDIAN_ARMED:/);
assert.match(windowsGuardianSource, /tr -d '\\r' <"\$bootstrap_stdout"/);
assert.doesNotMatch(windowsGuardianSource, /Start-Process -FilePath \$powerShellPath/);
assert.match(windowsGuardianSource, /\[wmiclass\]'\\\\[.]\\root\\cimv2:Win32_ProcessStartup'/);
assert.match(windowsGuardianSource, /\$wmiStartup[.]CreateFlags = \[uint32\]1536/);
assert.match(windowsGuardianSource, /\$wmiStartup[.]EnvironmentVariables = \$startupEnvironmentValues/);
assert.match(windowsGuardianSource, /\$name[.]StartsWith\('EAI_', \[StringComparison\]::OrdinalIgnoreCase\)/);
assert.match(windowsGuardianSource, /\[wmiclass\]'\\\\[.]\\root\\cimv2:Win32_Process'/);
assert.match(windowsGuardianSource, /\$wmiResult = \$wmiProcessClass[.]Create\(\$workerCommandLine, \(Split-Path -Parent \$powerShellPath\), \$wmiStartup\)/);
assert.match(windowsGuardianSource, /\[void\]\$workerProcess[.]Handle/);
assert.match(windowsGuardianSource, /\$workerProcess[.]SessionId -ne 0/);
assert.match(windowsGuardianSource, /\$workerOwnerSid[.]Sid -cne \$systemSid/);
assert.match(windowsGuardianSource, /\[string\]\$workerCim[.]CommandLine -cne \$workerCommandLine/);
assert.equal(
  (windowsGuardianSource.match(/prlctl exec "\$vm_name" cmd[.]exe \/D \/S \/C powershell[.]exe/g) ?? []).length,
  1,
);
assert.match(windowsGuardianSource, /guardianWorkerSha256 = \$expectedWorkerSha256/);
assert.match(windowsGuardianSource, /guardianWorkerNonce = \$expectedWorkerNonce/);
assert.match(windowsGuardianSource, /guardianProcessId = \$guardianProcessId/);
assert.match(windowsGuardianSource, /guardianProcessStartedAt = \$guardianProcessStartedAt/);
assert.match(windowsGuardianSource, /\$installerArmed[.]workerScriptSha256 -cne \$expectedInstallerWorkerSha256/);
assert.match(windowsGuardianSource, /\$installerArmed[.]workerNonce -cne \$expectedInstallerWorkerNonce/);
assert.match(windowsGuardianSource, /\$installerProcess[.]SessionId -ne \[int\]\$installerArmed[.]workerProcessSessionId/);
const windowsGuardianWorkerLock = windowsGuardianSource.indexOf(
  "$sourceLock = [IO.File]::Open($workerScriptPath",
);
const windowsGuardianLockedHash = windowsGuardianSource.indexOf("$lockedWorkerHasher.ComputeHash($sourceLock)");
const windowsGuardianDetachedLaunch = windowsGuardianSource.indexOf(
  "$wmiResult = $wmiProcessClass.Create($workerCommandLine",
);
assert.ok(windowsGuardianWorkerLock >= 0 && windowsGuardianWorkerLock < windowsGuardianLockedHash);
assert.ok(windowsGuardianLockedHash < windowsGuardianDetachedLaunch);
const windowsGuardianBootstrapReaped = windowsGuardianSource.indexOf('wait "$bootstrap_pid"');
const windowsGuardianFirstSystemPoll = windowsGuardianSource.indexOf("guest_system_ps_run", windowsGuardianBootstrapReaped);
assert.ok(windowsGuardianBootstrapReaped >= 0 && windowsGuardianBootstrapReaped < windowsGuardianFirstSystemPoll);
const windowsGuardianArmFunctionEnd = windowsGuardianSource.indexOf("\n}\n\nwait_defender_guardian_ready() {");
assert.ok(windowsGuardianArmFunctionEnd > windowsGuardianBootstrapReaped);
const windowsGuardianArmFunctionSource = windowsGuardianSource.slice(0, windowsGuardianArmFunctionEnd);
const windowsGuardianAwaitingTargetProof = windowsGuardianArmFunctionSource.indexOf("$awaitingTarget = $null");
const windowsGuardianBootstrapAcknowledgement = windowsGuardianArmFunctionSource.indexOf(
  'Write-Output "DETACHED_DEFENDER_GUARDIAN_ARMED:',
);
assert.ok(windowsGuardianDetachedLaunch < windowsGuardianAwaitingTargetProof);
assert.ok(windowsGuardianAwaitingTargetProof < windowsGuardianBootstrapAcknowledgement);
assert.match(windowsGuardianArmFunctionSource, /for \(\$poll = 0; \$poll -lt 240; \$poll\+\+\)/);
assert.match(windowsGuardianArmFunctionSource, /\$addAcl[.]GetOwner\(\[Security[.]Principal[.]SecurityIdentifier\]\)[.]Value -cne \$systemSid/);
assert.match(windowsGuardianArmFunctionSource, /\$awaitingTarget[.]receiptSystemOwned -ne \$true/);
assert.match(windowsGuardianArmFunctionSource, /\$awaitingTarget[.]guardianWorkerSha256 -cne \$expectedWorkerSha256/);
assert.match(windowsGuardianArmFunctionSource, /\$awaitingTarget[.]guardianWorkerNonce -cne \$expectedWorkerNonce/);
assert.match(windowsGuardianArmFunctionSource, /\$awaitingTarget[.]guardianProcessId -ne \$workerProcess[.]Id/);
assert.match(windowsGuardianArmFunctionSource, /\$effectiveExclusions -notcontains \$normalizedTarget/);
assert.match(windowsGuardianArmFunctionSource, /Get-MpComputerStatus/);
assert.match(windowsGuardianArmFunctionSource, /\$workerProcess[.]HasExited -or \$workerProcess[.]SessionId -ne 0/);
assert.doesNotMatch(
  windowsGuardianArmFunctionSource.slice(windowsGuardianBootstrapReaped),
  /guest_system_ps(?:_run)?/,
);
assert.doesNotMatch(windowsGuardianArmFunctionSource, /for attempt in \$\(seq 1 180\)/);
assert.match(windowsGuardianSource, /guardianProcessId: receipt[.]guardianProcessId/);
assert.match(windowsGuardianSource, /GUARDIAN_UNSAFE_TERMINAL/);
const windowsDefenderEvidenceBeforeClear = windowsGuardianSource.lastIndexOf(
  "preserve_defender_evidence remove removed-verified",
);
const windowsDefenderPendingClear = windowsGuardianSource.lastIndexOf("defender_exclusion_pending=0");
assert.ok(windowsDefenderEvidenceBeforeClear >= 0 && windowsDefenderEvidenceBeforeClear < windowsDefenderPendingClear);

const windowsInstallerBridgeArmSection = windowsGuestAdapterSource.slice(windowsInstallerBridgeArm, windowsDefenderAllowanceArm);
assert.match(windowsInstallerBridgeArmSection, /start_installer_bridge "\$host_hash" "\$guest_user"/);
const windowsGuardianActiveMainSection = windowsGuestAdapterSource.slice(windowsDefenderAllowanceArm, windowsDefenderCleanupPassed);
assert.doesNotMatch(windowsGuardianActiveMainSection, /\bguest_ps(?:_run)?\b|--current-user|start_guest_app_bridge/);
assert.match(windowsGuardianActiveMainSection, /start_defender_guardian "\$host_hash" "\$installer_worker_hash" "\$installer_worker_nonce"/);
assert.match(windowsGuardianActiveMainSection, /guest_system_ps_run "\$EAI_VM_DOWNLOAD_URL"\$'\\n' 5/);
const windowsInstallerLaunchSignal = windowsGuardianActiveMainSection.indexOf('signal_installer_bridge_launch "$host_hash"');
const windowsInstallerTerminalWait = windowsGuardianActiveMainSection.indexOf('wait_installer_bridge_terminal "$host_hash"');
const windowsGuardianStopAfterInstaller = windowsGuardianActiveMainSection.indexOf("stop_defender_guardian");
const windowsInstallerBridgeExit = windowsGuardianActiveMainSection.indexOf('wait_installer_bridge_exit "$installer_exit_mode"');
assert.ok(windowsInstallerLaunchSignal >= 0 && windowsInstallerLaunchSignal < windowsInstallerTerminalWait);
assert.ok(windowsInstallerTerminalWait < windowsGuardianStopAfterInstaller);
assert.ok(windowsGuardianStopAfterInstaller < windowsInstallerBridgeExit);
const windowsNativeInstallerSection = windowsGuestAdapterSource.slice(windowsNativeInstaller, windowsNormalLaunch);
const windowsImmediateLaunchHash = windowsInstallerBridgeSource.indexOf("$targetLaunchHasher.ComputeHash($targetLaunchLock)");
const windowsInstallerStartProcess = windowsInstallerBridgeSource.indexOf("Start-Process -FilePath $targetPath");
assert.ok(windowsImmediateLaunchHash >= 0 && windowsImmediateLaunchHash < windowsInstallerStartProcess);
assert.match(windowsNativeInstallerSection, /Join-Path \$env:LOCALAPPDATA 'EAI Setup\\eai-setup[.]exe'/);
assert.doesNotMatch(windowsNativeInstallerSection, /Programs\\EAI Setup\\eai-setup[.]exe/);
assert.match(windowsGuestAdapterSource, /EAI_VM_DEFENDER_EXACT_FILE_ADDED="\$defender_exclusion_added"/);
assert.match(windowsGuestAdapterSource, /EAI_VM_DEFENDER_EXACT_FILE_REMOVED="\$defender_exclusion_removed"/);
assert.match(windowsGuestAdapterSource, /preserve_defender_bridge_logs/);
const windowsCleanupSection = windowsGuestAdapterSource.slice(
  windowsGuestAdapterSource.indexOf("cleanup() {"),
  windowsGuestAdapterSource.indexOf("trap cleanup EXIT"),
);
assert.ok(windowsCleanupSection.indexOf("cancel_installer_bridge") < windowsCleanupSection.indexOf("stop_defender_guardian"));
const windowsExitPreserveNormal = windowsCleanupSection.indexOf("preserve_detached_launch_evidence normal");
const windowsExitPreserveE2e = windowsCleanupSection.indexOf("preserve_detached_launch_evidence e2e");
const windowsExitCleanupNormal = windowsCleanupSection.indexOf("cleanup_detached_guest_app normal");
const windowsExitCleanupE2e = windowsCleanupSection.indexOf("cleanup_detached_guest_app e2e");
const windowsExitWatcherStop = windowsCleanupSection.indexOf("stop_prerequisite_uac_watcher");
const windowsExitUacRestore = windowsCleanupSection.indexOf("restore_admin_consent_prompt");
const windowsExitInstallerCancel = windowsCleanupSection.indexOf("cancel_installer_bridge");
assert.ok(windowsExitPreserveNormal >= 0 && windowsExitPreserveNormal < windowsExitCleanupNormal);
assert.ok(windowsExitPreserveE2e >= 0 && windowsExitPreserveE2e < windowsExitCleanupE2e);
assert.ok(windowsExitCleanupNormal < windowsExitCleanupE2e);
assert.ok(windowsExitCleanupE2e < windowsExitWatcherStop);
assert.ok(windowsExitWatcherStop < windowsExitUacRestore);
assert.ok(windowsExitUacRestore < windowsExitInstallerCancel);
assert.match(windowsCleanupSection, /wait_installer_bridge_terminal/);
assert.match(windowsCleanupSection, /wait_installer_bridge_terminal_cmd/);
assert.match(windowsCleanupSection, /wait_installer_bridge_exit any/);
assert.equal((windowsCleanupSection.match(/wait_installer_bridge_exit any/g) ?? []).length, 1);
assert.match(
  windowsCleanupSection,
  /if \[\[ "\$installer_bridge_pending" != 1 && "\$defender_exclusion_pending" != 1 \\\n\s+&& "\$\{installer_worker_hash:-\}" =~ \^\[0-9a-f\]\{64\}\$ \\\n\s+&& "\$\{installer_worker_nonce:-\}" =~ \^\[0-9a-f\]\{32\}\$ \]\]; then\s+cleanup_installer_bridge_artifacts/,
);
assert.match(windowsCleanupSection, /Retaining unresolved protected-change diagnostics/);
assert.match(windowsCleanupSection, /write_detached_launch_quarantine_diagnostic/);
assert.match(windowsCleanupSection, /detached_launch_quarantine_required/);
const windowsInstallerArtifactCleanupStart = windowsInstallerBridgeSource.indexOf("cleanup_installer_bridge_artifacts() {");
const windowsInstallerArtifactCleanupEnd = windowsInstallerBridgeSource.indexOf(
  "start_defender_guardian() {",
  windowsInstallerArtifactCleanupStart,
);
const windowsInstallerArtifactCleanupSource = windowsInstallerBridgeSource.slice(
  windowsInstallerArtifactCleanupStart,
  windowsInstallerArtifactCleanupEnd,
);
assert.match(windowsInstallerArtifactCleanupSource, /guest_system_ps_run "\$expected_worker_hash"\$'\\n' 30/);
const windowsInstallerExitWaitStart = windowsInstallerBridgeSource.indexOf("wait_installer_bridge_exit() {");
const windowsInstallerExitWaitEnd = windowsInstallerBridgeSource.indexOf("preserve_installer_bridge_evidence() {", windowsInstallerExitWaitStart);
const windowsInstallerExitWaitSource = windowsInstallerBridgeSource.slice(windowsInstallerExitWaitStart, windowsInstallerExitWaitEnd);
assert.match(windowsInstallerExitWaitSource, /printf '%s' "\$probe_script" \| guest_system_ps/);
assert.match(windowsInstallerExitWaitSource, /for attempt in \$\(seq 1 30\)/);
assert.doesNotMatch(windowsInstallerExitWaitSource, /guest_system_ps_run|-EncodedCommand/);
assert.match(windowsInstallerBridgeSource, /prlctl exec "\$vm_name" cmd[.]exe \/D \/Q \/C type/);
const windowsInstallerCmdReceiptStart = windowsInstallerBridgeSource.indexOf("wait_installer_bridge_terminal_cmd() {");
const windowsInstallerCmdReceiptEnd = windowsInstallerBridgeSource.indexOf(
  "wait_installer_bridge_terminal() {",
  windowsInstallerCmdReceiptStart,
);
const windowsInstallerCmdReceiptSource = windowsInstallerBridgeSource.slice(
  windowsInstallerCmdReceiptStart,
  windowsInstallerCmdReceiptEnd,
);
assert.match(windowsInstallerCmdReceiptSource, /prlctl exec "\$vm_name" cmd[.]exe \/D \/Q \/C type/);
assert.doesNotMatch(windowsInstallerCmdReceiptSource, /--current-user|powershell[.]exe/);
assert.match(
  windowsInstallerCmdReceiptSource,
  /A complete but invalid terminal receipt cannot become valid on a later/,
);
assert.match(windowsInstallerCmdReceiptSource, /then\s+return 0\s+fi\s+# The worker publishes[\s\S]*return 1/);
const windowsInstallerTerminalFunctionStart = windowsInstallerBridgeSource.indexOf("wait_installer_bridge_terminal() {");
const windowsInstallerTerminalFunctionEnd = windowsInstallerBridgeSource.indexOf(
  "wait_installer_bridge_exit() {",
  windowsInstallerTerminalFunctionStart,
);
const windowsInstallerTerminalFunctionSource = windowsInstallerBridgeSource.slice(
  windowsInstallerTerminalFunctionStart,
  windowsInstallerTerminalFunctionEnd,
);
assert.match(windowsInstallerTerminalFunctionSource, /EAI_INSTALLER_BRIDGE_IMMUTABLE_TERMINAL_INVALID/);
assert.match(
  windowsInstallerTerminalFunctionSource,
  /if \[\[ "\$output" == [*]"EAI_INSTALLER_BRIDGE_IMMUTABLE_TERMINAL_INVALID"[*] \]\]; then[\s\S]*return 1/,
);
assert.match(guestTestLibrarySource, /defenderProofPassed/);
assert.match(guestTestLibrarySource, /defenderExactFileAllowance/);
assert.match(guestTestLibrarySource, /installerBridgeProofPassed/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]launchSignalSystemOwned === true/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]launchSignalHashBound === true/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]defenderReadyReceiptVerified === true/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]targetLaunchLockVerified === true/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]launchStartInfoPathVerified === true/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]liveProcessPathVerified === true/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]liveProcessExitedBeforePathInspection === true/);
assert.match(guestTestLibrarySource, /Number[.]isInteger\(installerBridgeEvidence[?][.]installerProcessId\)/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]installerProcessSessionId/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]installerProcessStartedAt/);
assert.match(guestTestLibrarySource, /Date[.]parse\(defenderAddEvidence[?][.]recordedAt\) <= Date[.]parse\(installerBridgeEvidence[?][.]installerStartedAt\)/);
assert.match(guestTestLibrarySource, /Date[.]parse\(installerBridgeEvidence[?][.]completedAt\) <= Date[.]parse\(defenderRemoveEvidence[?][.]recordedAt\)/);
assert.match(guestTestLibrarySource, /diagnosticOnly: true/);
assert.match(guestTestLibrarySource, /productionGate: false/);
assert.match(windowsGuardianSource, /receipt[.]completionSignalVerified !== true/);
assert.match(windowsGuardianSource, /receipt[.]targetHashVerified !== true/);
assert.match(windowsGuardianSource, /receipt[.]mpCmdRunVerified !== true/);
assert.match(windowsGuardianSource, /receipt[.]precheckProbeVerified !== true/);
assert.match(windowsGuardianSource, /receipt[.]receiptSystemOwned !== true/);
assert.match(guestTestLibrarySource, /defenderAddEvidence[?][.]precheckProbeVerified === true/);
assert.match(guestTestLibrarySource, /defenderAddEvidence[?][.]receiptSystemOwned === true/);
assert.match(guestTestLibrarySource, /defenderRemoveEvidence[?][.]receiptSystemOwned === true/);
assert.match(guestTestLibrarySource, /defenderRemoveEvidence[?][.]guardianProcessId === defenderAddEvidence[?][.]guardianProcessId/);
assert.match(guestTestLibrarySource, /defenderRemoveEvidence[?][.]guardianProcessStartedAt === defenderAddEvidence[?][.]guardianProcessStartedAt/);
assert.match(guestTestLibrarySource, /installerBridgeEvidence[?][.]workerProcessId/);
assert.match(guestTestLibrarySource, /defenderAddEvidence[?][.]completionSignalVerified === true/);
assert.match(guestTestLibrarySource, /defenderAddEvidence[?][.]targetHashVerified === true/);
const windowsNormalLaunchSection = windowsGuestAdapterSource.slice(windowsNormalLaunch, windowsE2eLaunch);
assert.match(windowsNormalLaunchSection, /launch_guest_app_detached normal "" "\$executable_hash"/);
assert.match(windowsNormalLaunchSection, /validate_guest_app_launch "\$guest_normal_pid"/);
assert.match(windowsNormalLaunchSection, /cleanup_detached_guest_app normal/);
assert.doesNotMatch(windowsNormalLaunchSection, /EAI_SETUP_E2E(?:_|\s*=)/);
assert.match(windowsNormalLaunchSection, /versions_satisfy_contract "\$versions"/);
assert.match(windowsNormalLaunchSection, /screen_has "Sign in"/);
assert.match(windowsNormalLaunchSection, /screen_has "Prerequisites installed successfully"/);
assert.doesNotMatch(windowsNormalLaunchSection, /screen_has "Sign in to EAI"/);
const windowsVersionsReadyGate = windowsNormalLaunchSection.indexOf('versions_satisfy_contract "$versions"');
const windowsSignInReadyGate = windowsNormalLaunchSection.indexOf('screen_has "Sign in"');
const windowsPrerequisiteSuccessReadyGate = windowsNormalLaunchSection.indexOf(
  'screen_has "Prerequisites installed successfully"',
);
assert.ok(windowsVersionsReadyGate >= 0 && windowsVersionsReadyGate < windowsSignInReadyGate);
assert.ok(
  windowsSignInReadyGate < windowsPrerequisiteSuccessReadyGate,
  "Windows readiness must require both receipt-bound visible phrases after the version contract",
);
assert.match(macosParallelsWindowIdSource, /[.]optionOnScreenOnly/);
assert.match(macosParallelsWindowIdSource, /kCGWindowOwnerName[\s\S]*Parallels Desktop/);
assert.match(macosParallelsWindowIdSource, /kCGWindowName[\s\S]*expectedTitle/);
assert.match(macosParallelsWindowIdSource, /kCGWindowLayer[\s\S]*layer[.]intValue == 0/);
assert.match(macosParallelsWindowIdSource, /kCGWindowAlpha[\s\S]*alpha[.]doubleValue > 0/);
assert.match(macosParallelsWindowIdSource, /com[.]parallels[.]desktop[.]console/);
assert.match(macosParallelsWindowIdSource, /matches[.]count == 1/);
assert.match(macosParallelsUacPointSource, /[.]optionOnScreenOnly/);
assert.match(macosParallelsUacPointSource, /com[.]parallels[.]desktop[.]console/);
assert.match(macosParallelsUacPointSource, /scaleX >= 1[\s\S]*abs\(scaleX - scaleY\) < 0[.]02/);
assert.match(macosParallelsUacPointSource, /candidate[.]confidence >= 0[.]7/);
assert.match(macosParallelsUacPointSource, /candidate[.]string[.]compare\("Yes"/);
assert.match(macosParallelsUacPointSource, /yesCandidates[.]count == 1/);
assert.match(macosParallelsUacPointSource, /centerX >= 0[.]30[\s\S]*centerX <= 0[.]52/);
assert.match(macosParallelsUacPointSource, /centerY >= 0[.]20[\s\S]*centerY <= 0[.]40/);
assert.match(macosParallelsUacPointSource, /"%u %[.]2f %[.]2f"/);
assert.match(windowsGuestAdapterSource, /\/usr\/sbin\/screencapture -x -o -l "\$window_id"/);
assert.match(windowsGuestAdapterSource, /verified_window_id="\$\("\$window_id_binary" "\$vm_name"/);
const windowsCoherenceExitStart = windowsGuestAdapterSource.indexOf("exit_vm_coherence_if_needed() {");
const windowsShowConsoleStart = windowsGuestAdapterSource.indexOf("show_vm_console() {");
assert.ok(windowsCoherenceExitStart >= 0 && windowsCoherenceExitStart < windowsShowConsoleStart);
const windowsCoherenceExitSource = windowsGuestAdapterSource.slice(
  windowsCoherenceExitStart,
  windowsShowConsoleStart,
);
assert.ok(
  windowsCoherenceExitSource.indexOf('"$window_id_binary" "$vm_name" >/dev/null 2>&1 && return 0')
    < windowsCoherenceExitSource.indexOf('osascript - "$vm_name"'),
);
assert.equal((windowsCoherenceExitSource.match(/osascript - "\$vm_name"/g) ?? []).length, 1);
assert.match(windowsCoherenceExitSource, /repeat with candidateProcess in application processes/);
assert.match(windowsCoherenceExitSource, /name of item 2 of candidateMenuItems as text/);
assert.match(windowsCoherenceExitSource, /candidateVmName is vmName/);
assert.match(windowsCoherenceExitSource, /name of candidateViewItem as text\) is "View"/);
assert.match(windowsCoherenceExitSource, /name of candidateAction as text\) is "Exit Coherence"/);
assert.match(windowsCoherenceExitSource, /set end of candidatePids to \(unix id of candidateProcess\) as integer/);
assert.match(windowsCoherenceExitSource, /count of candidatePids\) is not 1/);
assert.match(windowsCoherenceExitSource, /candidateActionCount is not 1/);
assert.match(windowsCoherenceExitSource, /application process whose unix id is my targetPid/);
assert.match(windowsCoherenceExitSource, /count of actionCoordinates\) is not 1/);
assert.equal((windowsCoherenceExitSource.match(/click targetAction/g) ?? []).length, 1);
assert.match(
  windowsCoherenceExitSource,
  /for _ in \$\(seq 1 30\); do[\s\S]*"\$window_id_binary" "\$vm_name" >\/dev\/null 2>&1 && return 0[\s\S]*sleep 1/,
);
assert.doesNotMatch(
  windowsCoherenceExitSource,
  /application processes? whose name|application process "WinAppHelper"|tell process "WinAppHelper"/,
);
assert.doesNotMatch(windowsCoherenceExitSource, /Contents\/MacOS\/prl_client_app|unix id is [0-9]+/);
assert.match(windowsGuestAdapterSource, /show_vm_console\(\) \{/);
assert.match(windowsGuestAdapterSource, /application process whose bundle identifier is "com\.parallels\.desktop\.console"/);
assert.match(windowsGuestAdapterSource, /tell application id "com[.]parallels[.]desktop[.]console" to activate/);
assert.match(windowsGuestAdapterSource, /click menu item vmName of menu "Window" of menu bar 1/);
assert.match(windowsGuestAdapterSource, /osascript - "\$vm_name"/);
assert.doesNotMatch(windowsGuestAdapterSource, /input combo alt\+y|approve_verified_uac_with_virtual_keyboard/);
assert.equal((windowsGuestAdapterSource.match(/verified_window_id="\$\("\$window_id_binary" "\$vm_name"/g) ?? []).length, 1);
assert.doesNotMatch(windowsGuestAdapterSource, /tell application "System Events" to click at \{clickX, clickY\}/);
assert.match(windowsGuestAdapterSource, /stage host-console-visible/);
const windowsConsoleTransitionStart = windowsGuestAdapterSource.lastIndexOf("stage guest-session-stable");
const windowsConsoleTransitionEnd = windowsGuestAdapterSource.indexOf("stage host-console-visible", windowsConsoleTransitionStart);
const windowsConsoleTransitionSource = windowsGuestAdapterSource.slice(
  windowsConsoleTransitionStart,
  windowsConsoleTransitionEnd,
);
assert.ok(
  windowsConsoleTransitionSource.indexOf("show_vm_console")
    < windowsConsoleTransitionSource.indexOf("exit_vm_coherence_if_needed"),
);
assert.equal((windowsConsoleTransitionSource.match(/show_vm_console/g) ?? []).length, 2);
assert.match(windowsConsoleTransitionSource, /one-shot Coherence exit/);
const windowsUacStart = windowsGuestAdapterSource.indexOf("unexpected_prerequisite_uac_visible() {");
const windowsUacEnd = windowsGuestAdapterSource.indexOf("\n}\n\nstart_prerequisite_uac_watcher()", windowsUacStart);
assert.ok(windowsUacStart >= 0 && windowsUacEnd > windowsUacStart);
const windowsUacSource = windowsGuestAdapterSource.slice(windowsUacStart, windowsUacEnd);
assert.equal((windowsUacSource.match(/capture_vm_window "\$screenshot"/g) ?? []).length, 1);
for (const exactUacText of [
  "User Account Control",
  "Do you want to allow",
  "changes to your device?",
]) {
  assert.match(windowsUacSource, new RegExp(exactUacText.replaceAll(".", "[.]")));
}
assert.match(windowsUacSource, /rm -f "\$screenshot"/);
assert.match(windowsUacSource, /capture_vm_window "\$screenshot" \|\| return 2/);
assert.match(windowsUacSource, /elif \[\[ "\$status" != 1 \]\]/);
assert.doesNotMatch(windowsUacSource, /Git for Windows|Johannes Schindelin|Node[.]js|OpenJS Foundation|cp |writeFileSync|input |screen_has/);
const windowsUacPolicyArmStart = windowsGuestAdapterSource.indexOf("arm_temporary_admin_consent_suppression() {");
const windowsUacPolicyRestoreStart = windowsGuestAdapterSource.indexOf("restore_admin_consent_prompt() {");
assert.ok(windowsUacPolicyArmStart >= 0 && windowsUacPolicyRestoreStart > windowsUacPolicyArmStart);
const windowsUacPolicySource = windowsGuestAdapterSource.slice(windowsUacPolicyArmStart, windowsUacPolicyRestoreStart);
assert.match(windowsUacPolicySource, /WellKnownSidType]::LocalSystemSid/);
assert.match(windowsUacPolicySource, /WindowsBuiltInRole]::Administrator/);
assert.match(windowsUacPolicySource, /GetValueKind\('ConsentPromptBehaviorAdmin'\)/);
assert.match(windowsUacPolicySource, /GetValueKind\('PromptOnSecureDesktop'\)/);
assert.match(windowsUacPolicySource, /GetValueKind\('EnableLUA'\)/);
assert.match(windowsUacPolicySource, /beforeConsentValue -ne 5/);
assert.match(windowsUacPolicySource, /beforeDesktopValue -ne 0/);
assert.match(windowsUacPolicySource, /beforeEnableValue -ne 1/);
assert.match(windowsUacPolicySource, /Set-ItemProperty -LiteralPath \$path -Name 'ConsentPromptBehaviorAdmin' -Value \(\[int\]0\) -Type DWord -ErrorAction Stop/);
assert.doesNotMatch(windowsUacPolicySource, /Set-ItemProperty[^\n]+(?:PromptOnSecureDesktop|EnableLUA)/);
assert.match(windowsUacPolicySource, /runBindingSha256 = \$runBinding/);
assert.match(windowsUacPolicySource, /mutationPerformed = \$true/);
assert.match(windowsGuestAdapterSource, /schemaVersion = 'eai-windows-uac-consent-policy\/v1'/);
assert.match(windowsGuestAdapterSource, /diagnosticOnly: true/);
assert.match(windowsGuestAdapterSource, /productionGate: false/);
assert.match(windowsGuestAdapterSource, /uacConsentUiCovered: false/);
assert.match(windowsGuestAdapterSource, /policyTemporarilyRelaxed: true/);
assert.match(windowsGuestAdapterSource, /approvalInputSent: false/);
const windowsUacPolicyRestoreEnd = windowsGuestAdapterSource.indexOf("\n}\n\nstart_installer_bridge()", windowsUacPolicyRestoreStart);
assert.ok(windowsUacPolicyRestoreEnd > windowsUacPolicyRestoreStart);
const windowsUacPolicyRestoreSource = windowsGuestAdapterSource.slice(windowsUacPolicyRestoreStart, windowsUacPolicyRestoreEnd);
assert.match(windowsUacPolicyRestoreSource, /Set-ItemProperty -LiteralPath \$path -Name 'ConsentPromptBehaviorAdmin' -Value \(\[int\]5\) -Type DWord -ErrorAction Stop/);
assert.doesNotMatch(windowsUacPolicyRestoreSource, /Set-ItemProperty[^\n]+(?:PromptOnSecureDesktop|EnableLUA)/);
assert.match(windowsUacPolicyRestoreSource, /afterDesktopValue -ne 0/);
assert.match(windowsUacPolicyRestoreSource, /afterEnableValue -ne 1/);
assert.match(windowsUacPolicyRestoreSource, /restorationVerified: true/);
const windowsUacWatcherStart = windowsGuestAdapterSource.indexOf("start_prerequisite_uac_watcher() {");
const windowsUacWatcherEnd = windowsGuestAdapterSource.indexOf("\n}\n\nwrite_powershell_payload_wrapper()", windowsUacWatcherStart);
assert.ok(windowsUacWatcherStart >= 0 && windowsUacWatcherEnd > windowsUacWatcherStart);
const windowsUacWatcherSource = windowsGuestAdapterSource.slice(windowsUacWatcherStart, windowsUacWatcherEnd);
assert.match(windowsUacWatcherSource, /unexpected_prerequisite_uac_visible/);
assert.match(windowsUacWatcherSource, /prerequisite-uac-watcher[.]failed/);
assert.match(windowsUacWatcherSource, /consent-ui-monitor-infrastructure-failed/);
assert.match(windowsUacWatcherSource, /kill -0 "\$uac_watcher_pid"/);
assert.match(windowsUacWatcherSource, /sanitize_log_file[\s\S]*windows-prerequisite-uac-watcher[.]log/);
assert.match(windowsUacWatcherSource, /eai-windows-uac-consent-ui-monitor\/v1/);
assert.match(windowsUacWatcherSource, /approvalInputSent: false/);
assert.match(windowsUacWatcherSource, /uacApprovalCount: 0/);
assert.doesNotMatch(windowsUacWatcherSource, /guest_ps|prlctl exec|--current-user/);
assert.equal((windowsGuestAdapterSource.match(/unexpected_prerequisite_uac_visible/g) ?? []).length, 2);
const windowsVersionsStart = windowsGuestAdapterSource.indexOf("guest_versions_json() {");
const windowsVersionsEnd = windowsGuestAdapterSource.indexOf("\n}\n\nversions_satisfy_contract()", windowsVersionsStart);
assert.ok(windowsVersionsStart >= 0 && windowsVersionsEnd > windowsVersionsStart);
const windowsVersionsSource = windowsGuestAdapterSource.slice(windowsVersionsStart, windowsVersionsEnd);
assert.match(windowsVersionsSource, /Microsoft\\\\WindowsApps/);
assert.match(windowsVersionsSource, /FileAttributes]::ReparsePoint/);
assert.match(windowsVersionsSource, /WaitForExit\(5000\)/);
assert.match(windowsVersionsSource, /taskkill[.]exe/);
assert.match(windowsVersionsSource, /streamsCompleted/);
assert.match(windowsVersionsSource, /StandardOutput[.]Dispose\(\)/);
const windowsBaselineStart = windowsGuestAdapterSource.indexOf("stage clean-snapshot-preflight");
const windowsBaselineEnd = windowsGuestAdapterSource.indexOf("before_versions=", windowsBaselineStart);
const windowsBaselineSource = windowsGuestAdapterSource.slice(windowsBaselineStart, windowsBaselineEnd);
assert.match(windowsBaselineSource, /Resolve-RealCommand git[.]exe/);
assert.match(windowsBaselineSource, /Resolve-RealCommand node[.]exe/);
assert.match(windowsBaselineSource, /Resolve-RealCommand npm[.]cmd/);
assert.match(windowsBaselineSource, /Resolve-RealCommand eai[.]cmd/);
assert.match(windowsBaselineSource, /Microsoft\\\\WindowsApps/);
assert.match(windowsBaselineSource, /winget = \[bool\]\(Get-Command winget[.]exe/);
assert.match(windowsBaselineSource, /Get-LocalGroupMember -SID 'S-1-5-32-544'/);
  assert.match(windowsBaselineSource, /WinNT:\/\/\$env:COMPUTERNAME\/Administrators,group/);
assert.doesNotMatch(windowsBaselineSource, /windowsIdentity[.]Groups[\s\S]*S-1-5-32-544/);
assert.match(windowsBaselineSource, /localAdministrator = \$localAdministrator/);
assert.match(windowsBaselineSource, /consentPromptBehaviorAdminKind/);
assert.match(windowsBaselineSource, /consentPromptBehaviorAdmin !== 5/);
assert.match(windowsBaselineSource, /promptOnSecureDesktop !== 0/);
assert.match(windowsBaselineSource, /enableLUA !== 1/);
assert.match(windowsNormalLaunchSection, /prerequisite_deadline=\$\(\(SECONDS \+ 1200\)\)/);
assert.match(windowsNormalLaunchSection, /while \(\( SECONDS < prerequisite_deadline \)\)/);
assert.doesNotMatch(windowsNormalLaunchSection, /for attempt in \$\(seq 1 240\)/);
const windowsUacWatcherLaunch = windowsNormalLaunchSection.indexOf("start_prerequisite_uac_watcher");
const windowsFirstNormalLivenessProbe = windowsNormalLaunchSection.indexOf('guest_process_alive "$guest_normal_pid"');
const windowsPrerequisiteLoop = windowsNormalLaunchSection.indexOf("stage prerequisite-install");
const windowsUacWatcherStop = windowsNormalLaunchSection.indexOf("stop_prerequisite_uac_watcher");
assert.ok(windowsUacWatcherLaunch >= 0 && windowsUacWatcherLaunch < windowsPrerequisiteLoop);
assert.ok(windowsUacWatcherLaunch < windowsFirstNormalLivenessProbe);
assert.ok(windowsUacWatcherStop > windowsPrerequisiteLoop);
assert.match(windowsCleanupSection, /stop_prerequisite_uac_watcher/);
assert.match(windowsCleanupSection, /restore_admin_consent_prompt/);
assert.match(windowsCleanupSection, /uac_consent_restore_required/);
assert.match(windowsCleanupSection, /write_uac_policy_quarantine_diagnostic/);
assert.match(windowsCleanupSection, /Retaining unresolved protected-change diagnostics/);
assert.match(windowsCleanupSection, /defender_exclusion_pending[\s\S]*installer_bridge_pending[\s\S]*uac_consent_restore_required/);
assert.match(windowsCleanupSection, /cleanup_detached_guest_app normal/);
assert.match(windowsCleanupSection, /cleanup_detached_guest_app e2e/);
assert.match(windowsCleanupSection, /detached_app_cleanup_failed/);
assert.match(windowsCleanupSection, /preserve_detached_launch_evidence normal[\s\S]*cleanup_detached_guest_app normal/);
assert.match(windowsCleanupSection, /preserve_detached_launch_evidence e2e[\s\S]*cleanup_detached_guest_app e2e/);
assert.match(windowsCleanupSection, /write_detached_launch_quarantine_diagnostic/);
assert.match(windowsCleanupSection, /uac_consent_restore_required[\s\S]*detached_launch_quarantine_required/);
assert.match(guestTestLibrarySource, /readEvidence\("windows-uac-consent-policy[.]json"\)/);
assert.match(guestTestLibrarySource, /readEvidence\("windows-uac-consent-ui-monitor[.]json"\)/);
assert.match(guestTestLibrarySource, /uacConsentPolicyProofPassed/);
assert.match(guestTestLibrarySource, /uacConsentUiMonitorProofPassed/);
assert.match(guestTestLibrarySource, /restorationVerified === true/);
assert.match(guestTestLibrarySource, /prerequisitesProven === "1"[\s\S]*uacConsentPolicyProofPassed[\s\S]*uacConsentUiMonitorProofPassed/);
assert.match(windowsGuestAdapterSource, /guest_ps_run "\$EAI_RELEASE_VERSION"\$'\\n' <<'POWERSHELL'/);
assert.match(windowsGuestAdapterSource, /Join-Path \$env:LOCALAPPDATA 'EAI Setup\\eai-setup[.]exe'/);
assert.match(windowsGuestAdapterSource, /\[string\]\$uninstallEntry[.]DisplayVersion -cne \$expectedVersion/);
assert.match(windowsGuestAdapterSource, /EAI_RELEASE_VERSION must be a semantic version/);
const windowsE2eLaunchSection = windowsGuestAdapterSource.slice(windowsE2eLaunch);
assert.match(windowsE2eLaunchSection, /launch_guest_app_detached e2e "\$e2e_stdin" "\$executable_hash"/);
assert.match(windowsGuestAdapterSource, /e2e_stdin="\$\{EAI_HARNESS_TENANT_ID\}"\$'\\n'"\$\{EAI_VM_PROJECT_NAME\}"/);
assert.doesNotMatch(windowsGuestAdapterSource, /e2e_stdin=[^\n]*\$'\\n'\s*$/m);
assert.match(windowsGuestAdapterSource, /stage remote-cleanup-arm[\s\S]*arm_windows_remote_cleanup[\s\S]*stage remote-cleanup-armed[\s\S]*stage e2e-app-launch/);
assert.match(windowsGuestAdapterSource, /eai[.]windows-remote-cleanup-arm[.]v1/);
assert.match(windowsGuestAdapterSource, /state: "remote-mutation-cleanup-armed"/);
assert.doesNotMatch(windowsE2eLaunchSection, /ArgumentList[^\n]*tenant/i);

assert.match(windowsAiWorkspacePowerShellSource, /1[.]136[.]1/);
assert.match(windowsAiWorkspacePowerShellSource, /a44adf7f53e00964ab890f9f8758a334f1fc15bc/);
assert.match(windowsAiWorkspacePowerShellSource, /57454d84d55f07b532fcf42295c57a5445054006be668ad7b1c19c9de9f68e31/);
assert.match(windowsAiWorkspacePowerShellSource, /update[.]code[.]visualstudio[.]com\/1[.]136[.]1\/win32-arm64\/stable/);
assert.match(windowsAiWorkspacePowerShellSource, /VSCodeSetup-arm64/);
assert.match(windowsAiWorkspacePowerShellSource, /Program Files path/);
assert.match(windowsAiWorkspacePowerShellSource, /function Assert-ProtectedInstallation/);
assert.match(windowsAiWorkspacePowerShellSource, /11009193bf07e51892a0ae9f6030188c7f8914e79ef4344e2f6a3a344807753f/);
assert.match(windowsAiWorkspacePowerShellSource, /function Invoke-CurlWithRetry/);
assert.match(windowsAiWorkspacePowerShellSource, /Get-Command 'curl[.]exe'/);
assert.match(windowsAiWorkspacePowerShellSource, /'--proto', '=https'/);
assert.match(windowsAiWorkspacePowerShellSource, /\$metadata[.]RedirectUrl/);
assert.doesNotMatch(windowsAiWorkspacePowerShellSource, /HttpWebRequest|Invoke-WebRequest/);
assert.match(windowsAiWorkspacePowerShellSource, /Get-AuthenticodeSignature/);
assert.match(windowsAiWorkspacePowerShellSource, /Microsoft Corporation/);
assert.match(windowsAiWorkspacePowerShellSource, /0xAA64/);
assert.match(windowsAiWorkspacePowerShellSource, /extensions\\copilot/);
assert.match(windowsAiWorkspacePowerShellSource, /GitHub[.]copilot-chat/);
assert.match(windowsAiWorkspacePreparerSource, /Windows AI-workspace evidence mismatch/);
assert.match(windowsAiWorkspacePreparerSource, /windows-ai-workspace[.]json/);
assert.match(windowsAiWorkspacePreparerSource, /source "\$ROOT\/scripts\/windows-readonly-powershell[.]sh"/);
assert.match(windowsAiWorkspacePreparerSource, /prlctl exec "\$vm_name" cmd[.]exe \/D \/S \/C powershell[.]exe/);
assert.match(windowsAiWorkspacePreparerSource, /eai-ai-workspace-\$\{nonce\}/);
assert.match(windowsAiWorkspacePreparerSource, /FromBase64String\('\$payload'\)/);
assert.match(windowsAiWorkspacePreparerSource, /SetAccessRuleProtection\(\\\$true,\\\$false\)/);
assert.match(windowsAiWorkspacePreparerSource, /-ExecutionPolicy Bypass -File \\\$script/);
assert.match(windowsAiWorkspacePreparerSource, /if \[\[ -n "\$guest_json" \]\]; then/);
assert.match(windowsAiWorkspacePreparerSource, /Get-Content -Raw[\s\S]*\| guest_ps_readonly/);
assert.equal((windowsAiWorkspacePreparerSource.match(/for _ in \$\(seq 1 120\); do/g) ?? []).length, 1);
assert.match(windowsAiWorkspacePreparerSource, /for _ in \$\(seq 1 5\); do/);
assert.match(windowsAiWorkspacePreparerSource, /evidence_output="\$\(printf '%s\\n'[\s\S]*guest_ps_readonly\)/);
assert.match(windowsAiWorkspacePreparerSource, /Get-Content -Raw -LiteralPath/);
assert.doesNotMatch(windowsAiWorkspacePreparerSource, /type "\$guest_evidence" 2>\/dev\/null/);
assert.doesNotMatch(windowsAiWorkspacePreparerSource, /\[\[ "\$output" == \*"Invalid argument"\*/);
assert.doesNotMatch(windowsAiWorkspacePreparerSource, /--current-user cmd[.]exe/);
assert.doesNotMatch(windowsAiWorkspacePreparerSource, /find-generic-password|--password|Set-Clipboard|Get-Clipboard/);
assert.match(windowsAiHandoffProcessQuerySource, /Get-Process Code/);
assert.match(windowsAiHandoffProcessQuerySource, /[.]SessionId -eq \$session/);
assert.match(
  windowsAiHandoffProcessQuerySource,
  /\[string\]::Equals\(\$_[.]Path, \$expected, \[StringComparison\]::OrdinalIgnoreCase\)/,
);
assert.match(windowsGuestAdapterSource, /windows-ai-handoff[.]png/);
assert.match(windowsGuestAdapterSource, /windows-ai-handoff-evidence[.]json/);
assert.match(windowsGuestAdapterSource, /EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1/);
assert.match(windowsGuestAdapterSource, /EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1/);
assert.match(windowsGuestAdapterSource, /@eai-tools\/\$expectedAppName/);
assert.match(windowsGuestAdapterSource, /The generated project has no usable scripts or dependencies/);
assert.match(windowsGuestAdapterSource, /handoff_candidate="\$work_dir\/windows-ai-handoff[.]png"/);
assert.match(windowsGuestAdapterSource, /Edge still owned the callback window/);
assert.match(windowsGuestAdapterSource, /The Windows handoff screenshot contains protected or callback data/);
const windowsReceiptProbeStart = windowsGuestAdapterSource.indexOf("receipt_ready=0");
const windowsReceiptValidationStart = windowsGuestAdapterSource.indexOf("stage receipt-validation");
assert.ok(windowsReceiptProbeStart >= 0 && windowsReceiptValidationStart > windowsReceiptProbeStart);
const windowsReceiptProbeSource = windowsGuestAdapterSource.slice(
  windowsReceiptProbeStart,
  windowsReceiptValidationStart,
);
assert.match(windowsReceiptProbeSource, /EAI_E2E_RECEIPT_NOT_READY'; return/);
assert.doesNotMatch(windowsReceiptProbeSource, /Write-NotReady|exit 0/);
assert.match(guestTestLibrarySource, /&& aiHandoffScreenshotVerified === "1" \? "passed" : "failed"/);
assert.match(windowsGuestAdapterSource, /for \(const key of \["EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL"\]\)/);
assert.doesNotMatch(windowsGuestAdapterSource, /Set-Clipboard|Get-Clipboard|clip[.]exe|pbcopy/);
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
const productionWindowsBuildJob = releaseWorkflow.slice(
  releaseWorkflow.indexOf("  build-windows:"),
  releaseWorkflow.indexOf("  release-windows:"),
);
const productionWindowsJob = releaseWorkflow.slice(
  releaseWorkflow.indexOf("  release-windows:"),
  releaseWorkflow.indexOf("  release-apple:"),
);
const productionAppleJob = releaseWorkflow.slice(
  releaseWorkflow.indexOf("  release-apple:"),
  releaseWorkflow.indexOf("  release-linux:"),
);
const productionLinuxJob = releaseWorkflow.slice(
  releaseWorkflow.indexOf("  release-linux:"),
  releaseWorkflow.indexOf("  publish-draft:"),
);
assert.match(releaseWorkflow, /^permissions:\n  contents: read$/m);
assert.match(productionWindowsJob, /permissions:\n      contents: read\n      id-token: write/);
assert.doesNotMatch(productionWindowsBuildJob, /id-token: write|environment: release|Azure\/login|artifact-signing-action/);
assert.doesNotMatch(productionAppleJob, /id-token: write|Azure\/login|artifact-signing-action/);
assert.doesNotMatch(productionLinuxJob, /id-token: write|environment: release|APPLE_CERTIFICATE|Azure\/login|artifact-signing-action/);
assert.equal((releaseWorkflow.match(/contents: write/g) ?? []).length, 1);
assert.match(releaseWorkflow, /publish-draft:[\s\S]*needs: \[release-windows, release-apple, release-linux\][\s\S]*permissions:\n      contents: write/);
assert.match(releaseWorkflow, /name: Sign Windows installer with Azure Artifact Signing[\s\S]*uses: Azure\/login@[a-f0-9]{40} # v3/);
assert.match(releaseWorkflow, /name: Apply Windows Authenticode signature[\s\S]*uses: Azure\/artifact-signing-action@[a-f0-9]{40} # v2/);
assert.match(releaseWorkflow, /endpoint: https:\/\/neu\.codesigning\.azure\.net\//);
assert.match(releaseWorkflow, /signing-account-name: eai-installer-signing/);
assert.match(releaseWorkflow, /certificate-profile-name: eai-installer-windows/);
assert.match(releaseWorkflow, /timestamp-rfc3161: http:\/\/timestamp\.acs\.microsoft\.com/);
assert.doesNotMatch(releaseWorkflow, /WINDOWS_CERTIFICATE(?:_PASSWORD)?/);
assert.match(releaseWorkflow, /Missing release secret APPLE_CERTIFICATE/);
assert.match(releaseWorkflow, /name: Verify exact version, PE architecture, Authenticode signer, and RFC3161 timestamp/);
assert.match(releaseWorkflow, /Get-Item -LiteralPath "staged-release\/\$\{\{ matrix\.asset \}\}"/);
assert.match(productionWindowsJob, /SignerCertificate[.]Subject -cne \$env:AZURE_SIGNING_SUBJECT/);
assert.match(productionWindowsJob, /TimeStamperCertificate/);
assert.match(productionWindowsJob, /1[.]3[.]6[.]1[.]5[.]5[.]7[.]3[.]8/);
assert.match(productionWindowsJob, /ProductVersion/);
assert.match(productionWindowsJob, /ToUInt16\(\$bytes, \$peOffset \+ 4\)/);
assert.match(productionAppleJob, /hdiutil attach "\$dmg" -readonly -nobrowse/);
assert.match(productionAppleJob, /CFBundleShortVersionString/);
assert.match(productionAppleJob, /lipo -archs/);
assert.match(productionLinuxJob, /dpkg-deb --field "\$package" Version/);
assert.match(productionLinuxJob, /dpkg-deb --field "\$package" Architecture/);
assert.match(releaseWorkflow, /uses: actions\/upload-artifact@[a-f0-9]{40} # v6/);
assert.match(releaseWorkflow, /uses: actions\/download-artifact@[a-f0-9]{40} # v5/);
assert.match(releaseWorkflow, /name: Publish verified six-asset draft/);
assert.match(releaseWorkflow, /test "\$\{#actual\[@\]\}" -eq 6/);
assert.match(releaseWorkflow, /gh release create "\$tag"[\s\S]*--draft/);
assert.match(releaseWorkflow, /gh release upload "\$tag" release-assets\/\* --clobber/);
assert.match(releaseWorkflow, /sha256sum --check/);
assert.match(releaseWorkflow, /git fetch --force --no-tags origin "refs\/tags\/\$tag:refs\/tags\/\$tag"/);
assert.ok(
  releaseWorkflow.indexOf("git rev-parse --verify")
    < releaseWorkflow.indexOf('gh release create "$tag"'),
);
for (const job of [productionWindowsBuildJob, productionAppleJob, productionLinuxJob]) {
  assert.match(job, /uses: tauri-apps\/tauri-action@[a-f0-9]{40} # v1/);
}
assert.equal((releaseWorkflow.match(/uses: tauri-apps\/tauri-action@[a-f0-9]{40}/g) ?? []).length, 3);
assert.doesNotMatch(productionAppleJob, /mapfile/);
assert.doesNotMatch(releaseWorkflow, /releaseDraft:/);
assert.match(releaseWorkflow, /echo "APPLE_API_KEY_PATH=\$RUNNER_TEMP\/AuthKey_\$\{APPLE_API_KEY\}[.]p8" >> "\$GITHUB_ENV"/);
assert.doesNotMatch(releaseWorkflow, /APPLE_API_KEY_PATH: \$\{\{ runner[.]temp \}\}\/AuthKey_/);
assert.match(releaseWorkflow, /validate-readiness-provenance:/);
assert.match(releaseWorkflow, /--workflow release-readiness[.]yml/);
assert.match(releaseWorkflow, /--commit "\$workflow_commit"/);
assert.match(releaseWorkflow, /String\(run[.]headSha\)[.]toLowerCase\(\) === commit[.]toLowerCase\(\)/);
assert.match(releaseWorkflow, /no recent successful protected readiness run is bound to this version and commit/);
assert.match(releaseReadinessWorkflow, /on:\n  workflow_dispatch:/);
assert.match(releaseReadinessWorkflow, /^permissions:\n  contents: read$/m);
assert.match(releaseReadinessWorkflow, /apple-readiness:[\s\S]*runs-on: macos-latest[\s\S]*environment: release/);
assert.match(releaseReadinessWorkflow, /azure-readiness:[\s\S]*id-token: write/);
assert.match(releaseReadinessWorkflow, /readiness:[\s\S]*needs: \[apple-readiness, azure-readiness\]/);
assert.match(releaseReadinessWorkflow, /openssl pkcs12/);
assert.match(releaseReadinessWorkflow, /openssl x509[^\n]*-checkend 604800/);
assert.match(releaseReadinessWorkflow, /security verify-cert[\s\S]*-p codeSign -R ocsp -R require/);
assert.match(releaseReadinessWorkflow, /codesign --force --options runtime --timestamp/);
assert.match(releaseReadinessWorkflow, /grep -Eq '\^Timestamp='/);
assert.match(releaseReadinessWorkflow, /xcrun notarytool history/);
assert.match(releaseReadinessWorkflow, /uses: Azure\/login@[a-f0-9]{40} # v3/);
assert.match(releaseReadinessWorkflow, /Microsoft[.]CodeSigning\/codeSigningAccounts/);
assert.match(releaseReadinessWorkflow, /Artifact Signing Certificate Profile Signer/);
assert.match(releaseReadinessWorkflow, /AZURE_SIGNING_RESOURCE_GROUP/);
assert.match(releaseReadinessWorkflow, /AZURE_SIGNING_SUBJECT/);
assert.match(releaseReadinessWorkflow, /properties[.]accountUri !== "https:\/\/neu[.]codesigning[.]azure[.]net\/"/);
assert.match(releaseReadinessWorkflow, /2837e146-70d7-4cfd-ad55-7efa6464f958/);
assert.match(releaseReadinessWorkflow, /profile has no valid identity-validation ID/);
assert.doesNotMatch(releaseReadinessWorkflow, /az provider show|az resource list|--include-groups/);
assert.match(releaseReadinessWorkflow, /post-tag Windows matrix signature is the authoritative Azure data-plane proof/);
assert.doesNotMatch(
  releaseReadinessWorkflow,
  /contents: write|gh release|git tag|git push|notarytool submit|Azure\/artifact-signing-action|az provider register|az role assignment create|az resource create/i,
);
for (const source of [releaseWorkflow, releaseReadinessWorkflow]) {
  assert.doesNotMatch(
    source,
    /uses: (?:actions\/(?:checkout|setup-node|upload-artifact|download-artifact)|tauri-apps\/tauri-action|Azure\/(?:login|artifact-signing-action))@(?:v\d+|stable)/i,
  );
}
assert.match(publishSection, /canonical_deprovision="\$ROOT\/scripts\/run-v4-app-deprovision\.sh"/);
assert.match(publishSection, /--driver command --vms macos,windows,ubuntu --deprovision api --preflight/);
assert.match(publishSection, /--driver command --vms macos,windows,ubuntu --deprovision api/);
assert.match(publishSection, /gh workflow run release-readiness\.yml/);
assert.match(publishSection, /readiness_commit="\$\(git rev-parse HEAD\)"/);
assert.match(publishSection, /wait_for_release_readiness_workflow "\$version" "\$readiness_nonce" "\$readiness_started_at" "\$readiness_commit"/);
assert.ok(releaseShell.includes('.headSha == \\"$expected_sha\\"'));
assert.ok(publishSection.indexOf("wait_for_release_readiness_workflow") < publishSection.indexOf('git tag -a "$tag"'));
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
  "EAI_HARNESS_TENANT_NAME",
  "EAI_HARNESS_USER_EMAIL",
  "EAI_HARNESS_PUBLIC_API_URL",
  "EAI_APP_DEPROVISION_COMMAND",
  "EAI_VM_MACOS_COMMAND",
  "EAI_VM_WINDOWS_COMMAND",
  "EAI_VM_UBUNTU_COMMAND",
  "EAI_VM_TEST_COMMAND",
  "EAI_RELEASE_VMS",
  "EAI_RELEASE_MACOS_ASSET",
  "EAI_RELEASE_WINDOWS_ASSET",
  "EAI_RELEASE_UBUNTU_ASSET",
]) delete cleanEnvironment[key];
const blocked = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "blocked"), "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: cleanEnvironment,
});
assert.equal(blocked.status, 1);
assert.match(blocked.stderr, /EAI_HARNESS_TENANT_ID is required/);
assert.doesNotMatch(blocked.stderr, /mock/i);

const missingDiagnosticEvidence = spawnSync(process.execPath, [
  windowsDiagnosticCleanupGate,
  "--run-dir", path.join(output, "missing-diagnostic-run"),
  "--confirm-zero-services-workflows-setup",
], { cwd: root, encoding: "utf8" });
assert.equal(missingDiagnosticEvidence.status, 1);
assert.match(missingDiagnosticEvidence.stderr, /^Windows diagnostic cleanup gate failed: Required cleanup evidence is missing, unreadable, or malformed[.]\n$/);
assert.doesNotMatch(missingDiagnosticEvidence.stderr, /at file:|ENOENT|node:internal/);

const mockVmAdapter = process.platform === "win32"
  ? path.join(process.env.ProgramFiles || "C:\\Program Files", "Git", "usr", "bin", "true.exe")
  : "/usr/bin/true";
const diagnosticEnvironment = {
  ...cleanEnvironment,
  EAI_HARNESS_TENANT_ID: "00000000-0000-4000-8000-000000000000",
  EAI_HARNESS_TENANT_NAME: "Fixture tenant",
  EAI_HARNESS_USER_EMAIL: "release-test@example.invalid",
  EAI_VM_MACOS_COMMAND: fs.realpathSync(mockVmAdapter),
  EAI_VM_WINDOWS_COMMAND: fs.realpathSync(mockVmAdapter),
  EAI_VM_UBUNTU_COMMAND: fs.realpathSync(mockVmAdapter),
  EAI_RELEASE_VMS: "macos",
};
const mockWithoutFlag = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "mock-without-flag"), "--deprovision", "mock", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(mockWithoutFlag.status, 1);
assert.match(mockWithoutFlag.stderr, /diagnostic-only/);

const diagnosticPreflight = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--repo", "fixture/repo", "--output", path.join(output, "diagnostic"), "--deprovision", "mock", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(diagnosticPreflight.status, 0);
assert.match(diagnosticPreflight.stdout, /"deprovision": "mock"/);
assert.match(diagnosticPreflight.stdout, /"diagnostic": true/);

const productionSubset = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "production-subset"), "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(productionSubset.status, 1);
assert.match(productionSubset.stderr, /requires macos,windows,ubuntu in that exact sequence/);

const productionSpoofedAdapters = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "production-spoofed-adapters"), "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: {
    ...diagnosticEnvironment,
    EAI_RELEASE_VMS: "macos,windows,ubuntu",
    EAI_APP_DEPROVISION_COMMAND: path.join(root, "scripts", "run-v4-app-deprovision.sh"),
  },
});
assert.equal(productionSpoofedAdapters.status, 1);
assert.match(productionSpoofedAdapters.stderr, /requires the repository macos VM adapter/);

const productionSpoofedAsset = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "production-spoofed-asset"), "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: {
    ...diagnosticEnvironment,
    EAI_RELEASE_VMS: "macos,windows,ubuntu",
    EAI_VM_MACOS_COMMAND: guestAdapters[0],
    EAI_VM_WINDOWS_COMMAND: guestAdapters[1],
    EAI_VM_UBUNTU_COMMAND: guestAdapters[2],
    EAI_APP_DEPROVISION_COMMAND: path.join(root, "scripts", "run-v4-app-deprovision.sh"),
    EAI_RELEASE_MACOS_ASSET: "substitute.dmg",
  },
});
assert.equal(productionSpoofedAsset.status, 1);
assert.match(productionSpoofedAsset.stderr, /requires the exact ARM64 macos release asset/);

const selectedVmEnvironment = {
  ...cleanEnvironment,
  EAI_HARNESS_TENANT_ID: "00000000-0000-4000-8000-000000000000",
  EAI_HARNESS_TENANT_NAME: "Fixture tenant",
  EAI_HARNESS_USER_EMAIL: "release-test@example.invalid",
  EAI_RELEASE_VMS: "windows",
  EAI_VM_WINDOWS_COMMAND: fs.realpathSync(mockVmAdapter),
};
const selectedVmPreflight = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--repo", "fixture/repo", "--output", path.join(output, "selected-vm"), "--deprovision", "mock", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: selectedVmEnvironment,
});
assert.equal(selectedVmPreflight.status, 0, selectedVmPreflight.stderr);
assert.match(selectedVmPreflight.stdout, /"vms": \[\s*"windows"\s*\]/);
assert.doesNotMatch(selectedVmPreflight.stdout, /"macos"|"ubuntu"/);

const nonExecutablePreflight = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "non-executable"), "--deprovision", "mock", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: {...diagnosticEnvironment, EAI_VM_MACOS_COMMAND: path.join(output, "does-not-exist")},
});
assert.equal(nonExecutablePreflight.status, 1);
assert.match(nonExecutablePreflight.stderr, /EAI_VM_MACOS_COMMAND is not an executable file/);

const diagnosticWithApi = spawnSync(process.execPath, [runner, "--version", "0.2.0", "--output", path.join(output, "diagnostic-with-api"), "--deprovision", "api", "--diagnostic", "--preflight"], {
  cwd: root,
  encoding: "utf8",
  env: diagnosticEnvironment,
});
assert.equal(diagnosticWithApi.status, 1);
assert.match(diagnosticWithApi.stderr, /only valid with --deprovision mock/);

// These controller fixtures exercise POSIX shebang executables and signal delivery.
// The release controller runs on macOS; Windows runners still cover its static contracts.
if (process.platform !== "win32") {
const cleanupFixtureRoot = path.join(output, "cleanup-fixtures");
const cleanupFixtureBin = path.join(cleanupFixtureRoot, "bin");
fs.mkdirSync(cleanupFixtureBin, { recursive: true });
const fakeGh = path.join(cleanupFixtureBin, "gh");
const fakeVm = path.join(cleanupFixtureRoot, "vm.mjs");
const fakeCleanup = path.join(cleanupFixtureRoot, "cleanup.mjs");
fs.writeFileSync(fakeGh, `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
if (args.includes("--version")) { console.log("gh version test"); process.exit(0); }
const directory = args[args.indexOf("--dir") + 1];
const pattern = args[args.indexOf("--pattern") + 1];
if (!directory || !pattern) process.exit(2);
fs.mkdirSync(directory, {recursive: true});
fs.writeFileSync(path.join(directory, pattern), "exact published fixture asset");
if (process.env.EAI_TEST_GH_READY_FILE) {
  const handleSignal = (signal) => {
    fs.writeFileSync(process.env.EAI_TEST_GH_SIGNAL_FILE, JSON.stringify({signal, pid: process.pid}));
    setTimeout(() => process.exit(0), 25);
  };
  process.on("SIGINT", () => handleSignal("SIGINT"));
  process.on("SIGTERM", () => handleSignal("SIGTERM"));
  fs.writeFileSync(process.env.EAI_TEST_GH_READY_FILE, JSON.stringify({pid: process.pid}));
  setInterval(() => {}, 1000);
}
`);
fs.chmodSync(fakeGh, 0o700);
fs.writeFileSync(fakeVm, `#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
const mode = process.env.EAI_TEST_VM_MODE;
fs.mkdirSync(path.dirname(process.env.EAI_VM_APP_STATE_FILE), {recursive: true});
if (mode === "malformed") fs.writeFileSync(process.env.EAI_VM_APP_STATE_FILE, "{");
if (mode === "missing" || mode === "malformed") process.exit(1);
if (mode === "signal-exit" || mode === "signal-ignore") {
  if (process.env.EAI_TEST_VM_START_COUNT_FILE) {
    const prior = fs.existsSync(process.env.EAI_TEST_VM_START_COUNT_FILE) ? Number(fs.readFileSync(process.env.EAI_TEST_VM_START_COUNT_FILE, "utf8")) : 0;
    fs.writeFileSync(process.env.EAI_TEST_VM_START_COUNT_FILE, String(prior + 1));
  }
  fs.writeFileSync(process.env.EAI_VM_APP_STATE_FILE, JSON.stringify({appName: process.env.EAI_VM_PROJECT_NAME, appCreated: true}));
  const handleSignal = (signal) => {
    fs.writeFileSync(process.env.EAI_TEST_VM_SIGNAL_FILE, JSON.stringify({signal, pid: process.pid}));
    process.stderr.write(\`received \${signal} for \${process.env.EAI_HARNESS_TENANT_NAME}\\n\`);
    if (mode === "signal-exit") setTimeout(() => process.exit(0), 25);
  };
  process.on("SIGINT", () => handleSignal("SIGINT"));
  process.on("SIGTERM", () => handleSignal("SIGTERM"));
  fs.writeFileSync(process.env.EAI_TEST_VM_READY_FILE, JSON.stringify({pid: process.pid}));
  setInterval(() => {}, 1000);
} else {
const checks = Object.fromEntries(["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"].map((name) => [name, "passed"]));
fs.writeFileSync(process.env.EAI_VM_APP_STATE_FILE, JSON.stringify({appName: process.env.EAI_VM_PROJECT_NAME, appCreated: true}));
fs.writeFileSync(process.env.EAI_VM_RESULT_FILE, JSON.stringify({status: "passed", vm: "windows", appName: process.env.EAI_VM_PROJECT_NAME, projectPath: "C:\\\\fixture", appCreated: true, cleanupRequested: true, checks}));
}
`);
fs.chmodSync(fakeVm, 0o700);
fs.writeFileSync(fakeCleanup, `#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
const invalidField = process.env.EAI_TEST_INVALID_DELETION_FIELD || "";
const invalidValue = process.env.EAI_TEST_INVALID_DELETION_JSON ? JSON.parse(process.env.EAI_TEST_INVALID_DELETION_JSON) : null;
if (process.env.EAI_TEST_CLEANUP_COUNT_FILE) {
  const prior = fs.existsSync(process.env.EAI_TEST_CLEANUP_COUNT_FILE) ? Number(fs.readFileSync(process.env.EAI_TEST_CLEANUP_COUNT_FILE, "utf8")) : 0;
  fs.writeFileSync(process.env.EAI_TEST_CLEANUP_COUNT_FILE, String(prior + 1));
}
if (process.env.EAI_TEST_CLEANUP_READY_FILE) fs.writeFileSync(process.env.EAI_TEST_CLEANUP_READY_FILE, "ready");
if (process.env.EAI_TEST_CLEANUP_DELAY_MS) await new Promise((resolve) => setTimeout(resolve, Number(process.env.EAI_TEST_CLEANUP_DELAY_MS)));
const digest = (value) => crypto.createHash("sha256").update(value).digest("hex");
const receipt = {
  schemaVersion: "eai.release-e2e.cleanup-receipt.v1",
  status: "verified",
  source: "public-api-v4",
  operationId: "fixture-operation",
  appName: process.env.EAI_DEPROVISION_APP_NAME,
  appCreated: process.env.EAI_DEPROVISION_APP_CREATED === "1",
  confirmation: process.env.EAI_DEPROVISION_CONFIRM,
  tenantMatch: "verified",
  tenantIdSha256: digest(process.env.EAI_DEPROVISION_TENANT_ID),
  apiOriginSha256: digest(process.env.EAI_DEPROVISION_API_ORIGIN),
  eaiVersion: "3.15.10",
  planHash: "a".repeat(64),
  ownershipManifestHash: "a".repeat(64),
  deletedRecords: {exactAppEnrollmentMatchesAfter: 0, exactFilteredTotalAfter: 0},
  deletedResources: {serverReceiptSchemaVersion: "eai.app-deletion-receipt.v1", resourceApiDeletedCount: 3, resourceApiStep: "verified", retainedSharedObjectTypes: []},
  absenceCheck: {
    method: "v4-filtered-manifest-owned-resource-queries",
    resourceTypes: ["tenant-vertical-enrollment", "vertical-service-activation", "vertical-product-config"],
    filterField: "verticalKey",
    exactMatchesByType: {"tenant-vertical-enrollment": 0, "vertical-service-activation": 0, "vertical-product-config": 0},
    allManifestOwnedResourceTypesAbsent: true,
  },
  cleanupVerified: true,
  adapterMessage: \`cleanup for \${process.env.EAI_HARNESS_TENANT_NAME}\`,
};
if (invalidField) receipt[invalidField] = invalidValue;
fs.writeFileSync(process.env.EAI_DEPROVISION_RECEIPT_FILE, JSON.stringify(receipt));
if (process.env.EAI_TEST_CLEANUP_INVOCATION_FILE) fs.writeFileSync(process.env.EAI_TEST_CLEANUP_INVOCATION_FILE, JSON.stringify({appName: process.env.EAI_DEPROVISION_APP_NAME, appCreated: process.env.EAI_DEPROVISION_APP_CREATED}));
`);
fs.chmodSync(fakeCleanup, 0o700);
const fakeVmExecutable = fs.realpathSync(fakeVm);
const fakeCleanupExecutable = fs.realpathSync(fakeCleanup);
const apiFixtureEnvironment = {
  ...cleanEnvironment,
  PATH: `${cleanupFixtureBin}:${cleanEnvironment.PATH}`,
  EAI_HARNESS_TENANT_ID: "00000000-0000-4000-8000-000000000000",
  EAI_HARNESS_TENANT_NAME: "Fixture tenant",
  EAI_HARNESS_USER_EMAIL: "release-test@example.invalid",
  EAI_HARNESS_PUBLIC_API_URL: "https://api.au.myenterprise.ai/public",
  EAI_RELEASE_VMS: "windows",
  EAI_VM_WINDOWS_COMMAND: fakeVmExecutable,
  EAI_APP_DEPROVISION_COMMAND: fakeCleanupExecutable,
};
const runApiFixture = (name, extraEnvironment = {}) => {
  const fixtureOutput = path.join(cleanupFixtureRoot, name);
  const result = spawnSync(process.execPath, [
    runner, "--version", "0.2.0", "--repo", "fixture/repo", "--tag", "fixture-tag",
    "--vms", "windows", "--output", fixtureOutput, "--deprovision", "api",
  ], {
    cwd: root,
    encoding: "utf8",
    env: {...apiFixtureEnvironment, ...extraEnvironment},
  });
  const report = JSON.parse(fs.readFileSync(path.join(fixtureOutput, "release-e2e.json"), "utf8"));
  return {result, report};
};
for (const mode of ["missing", "malformed"]) {
  const invocationFile = path.join(cleanupFixtureRoot, `${mode}-cleanup-invocation.json`);
  const fixture = runApiFixture(`app-state-${mode}`, {
    EAI_TEST_VM_MODE: mode,
    EAI_TEST_CLEANUP_INVOCATION_FILE: invocationFile,
  });
  assert.equal(fixture.result.status, 1, fixture.result.stderr);
  assert.equal(fixture.report.machines[0].cleanupVerified, true);
  assert.equal(fixture.report.machines[0].cleanupTargetConservative, true);
  assert.equal(fixture.report.machines[0].appStateCheckpoint, "conservative-unknown");
  assert.equal(JSON.parse(fs.readFileSync(invocationFile, "utf8")).appCreated, "1");
}
for (const field of ["deletedRecords", "deletedResources"]) {
  for (const [index, invalid] of [{}, [], true, 1, "deleted"].entries()) {
    const fixture = runApiFixture(`invalid-${field}-${index}`, {
      EAI_TEST_VM_MODE: "passed",
      EAI_TEST_INVALID_DELETION_FIELD: field,
      EAI_TEST_INVALID_DELETION_JSON: JSON.stringify(invalid),
    });
    assert.equal(fixture.result.status, 1, fixture.result.stderr);
    assert.equal(fixture.report.machines[0].cleanupVerified, false);
    assert.match(fixture.report.machines[0].cleanupError, /non-empty deletion evidence/);
  }
}
for (const [name, field, invalid, expectedError] of [
  ["wrong-schema", "schemaVersion", "wrong", /wrong schema version/],
  ["wrong-tenant-fingerprint", "tenantIdSha256", "0".repeat(64), /exact protected tenant/],
  ["wrong-api-fingerprint", "apiOriginSha256", "0".repeat(64), /exact PublicAPI origin/],
  ["old-cli-receipt", "eaiVersion", "3.15.9", /unsupported EAI CLI version/],
  ["wrong-plan", "planHash", "not-a-plan", /ownership-plan hash/],
  ["wrong-manifest", "ownershipManifestHash", "b".repeat(64), /ownership manifest/],
  ["missing-absence", "absenceCheck", {}, /independent absence evidence/],
  ["nonzero-absence", "absenceCheck", {method: "v4-filtered-manifest-owned-resource-queries", resourceTypes: ["tenant-vertical-enrollment", "vertical-service-activation", "vertical-product-config"], filterField: "verticalKey", exactMatchesByType: {"tenant-vertical-enrollment": 0, "vertical-service-activation": 1, "vertical-product-config": 0}, allManifestOwnedResourceTypesAbsent: true}, /independent absence evidence/],
  ["incomplete-delete-counts", "deletedRecords", {exactAppEnrollmentMatchesAfter: 1, exactFilteredTotalAfter: 1}, /incomplete exact deletion evidence/],
]) {
  const fixture = runApiFixture(name, {
    EAI_TEST_VM_MODE: "passed",
    EAI_TEST_INVALID_DELETION_FIELD: field,
    EAI_TEST_INVALID_DELETION_JSON: JSON.stringify(invalid),
  });
  assert.equal(fixture.result.status, 1, fixture.result.stderr);
  assert.equal(fixture.report.machines[0].cleanupVerified, false);
  assert.match(fixture.report.machines[0].cleanupError, expectedError);
}
const validCleanupFixture = runApiFixture("valid-cleanup", {EAI_TEST_VM_MODE: "passed"});
assert.equal(validCleanupFixture.result.status, 0, validCleanupFixture.result.stderr);
assert.equal(validCleanupFixture.report.status, "passed");
assert.equal(validCleanupFixture.report.machines[0].cleanupVerified, true);
assert.equal(validCleanupFixture.report.machines[0].cleanup.schemaVersion, "eai.release-e2e.cleanup-receipt.v1");
assert.equal(
  validCleanupFixture.report.machines[0].cleanup.tenantIdSha256,
  crypto.createHash("sha256").update(apiFixtureEnvironment.EAI_HARNESS_TENANT_ID).digest("hex"),
);
assert.equal(
  validCleanupFixture.report.machines[0].cleanup.apiOriginSha256,
  crypto.createHash("sha256").update(apiFixtureEnvironment.EAI_HARNESS_PUBLIC_API_URL).digest("hex"),
);

assert.match(
  guestTestLibrarySource,
  /cleanupRequired: result[.]appCreated,[\s\S]*cleanupRequested: result[.]cleanupRequested === true/,
  "guest finalization must preserve the cleanup contract required by the exact Windows portal helper",
);

const waitForFixtureFile = async (file, child, description) => {
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(file)) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`release controller exited before ${description}`);
    }
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${description}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};

const waitForFixtureClose = (promise, description) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`timed out waiting for ${description}`)), 10_000);
  promise.then(
    (value) => {
      clearTimeout(timer);
      resolve(value);
    },
    (error) => {
      clearTimeout(timer);
      reject(error);
    },
  );
});

const downloadSignalOutput = path.join(cleanupFixtureRoot, "signal-release-download");
const downloadReadyFile = path.join(cleanupFixtureRoot, "signal-release-download-ready");
const downloadSignalFile = path.join(cleanupFixtureRoot, "signal-release-download-signal");
const downloadController = spawn(process.execPath, [
  runner, "--version", "0.2.0", "--repo", "fixture/repo", "--tag", "fixture-tag",
  "--vms", "windows", "--output", downloadSignalOutput, "--deprovision", "api",
], {
  cwd: root,
  env: {
    ...apiFixtureEnvironment,
    EAI_TEST_GH_READY_FILE: downloadReadyFile,
    EAI_TEST_GH_SIGNAL_FILE: downloadSignalFile,
  },
  stdio: ["ignore", "ignore", "pipe"],
});
let downloadControllerStderr = "";
downloadController.stderr.on("data", (chunk) => { downloadControllerStderr += chunk; });
const downloadControllerClose = new Promise((resolve, reject) => {
  downloadController.once("error", reject);
  downloadController.once("close", (code, closeSignal) => resolve({code, signal: closeSignal}));
});
await waitForFixtureFile(downloadReadyFile, downloadController, "release-download readiness");
assert.equal(downloadController.kill("SIGINT"), true);
await waitForFixtureFile(downloadSignalFile, downloadController, "release-download forwarded signal");
const downloadReady = JSON.parse(fs.readFileSync(downloadReadyFile, "utf8"));
assert.deepEqual(JSON.parse(fs.readFileSync(downloadSignalFile, "utf8")), {signal: "SIGINT", pid: downloadReady.pid});
const downloadClose = await waitForFixtureClose(downloadControllerClose, "release-download controller exit");
const downloadSignalReport = JSON.parse(fs.readFileSync(path.join(downloadSignalOutput, "release-e2e.json"), "utf8"));
assert.equal(downloadClose.code, 130, downloadControllerStderr);
assert.equal(downloadClose.signal, null);
assert.equal(downloadSignalReport.status, "interrupted");
assert.equal(downloadSignalReport.interruption.targetRole, "release-download");
assert.equal(downloadSignalReport.interruption.targetProcessId, downloadReady.pid);
assert.equal(downloadSignalReport.interruption.forwardedToActiveChild, true);
assert.equal(downloadSignalReport.interruption.terminationObserved, true);
assert.equal(downloadSignalReport.machines.length, 0);
assert.ok(downloadSignalReport.completedAt);
assert.doesNotMatch(downloadControllerStderr, /UnhandledPromiseRejection|unhandled rejection/i);

const runSignalFixture = async ({ name, signal, vmMode, secondDuringCleanup, vms = "windows", extraEnvironment = {} }) => {
  const fixtureOutput = path.join(cleanupFixtureRoot, name);
  const vmReadyFile = path.join(cleanupFixtureRoot, `${name}-vm-ready`);
  const vmSignalFile = path.join(cleanupFixtureRoot, `${name}-vm-signal`);
  const vmStartCountFile = path.join(cleanupFixtureRoot, `${name}-vm-start-count`);
  const cleanupReadyFile = path.join(cleanupFixtureRoot, `${name}-cleanup-ready`);
  const cleanupCountFile = path.join(cleanupFixtureRoot, `${name}-cleanup-count`);
  const protectedTenantName = `Protected ${name} tenant`;
  const env = {
    ...apiFixtureEnvironment,
    EAI_HARNESS_TENANT_NAME: protectedTenantName,
    EAI_RELEASE_VMS: vms,
    EAI_RELEASE_UBUNTU_ASSET: "fixture-ubuntu.bin",
    EAI_VM_WINDOWS_COMMAND: fakeVmExecutable,
    EAI_VM_UBUNTU_COMMAND: fakeVmExecutable,
    EAI_TEST_VM_MODE: vmMode,
    EAI_TEST_VM_READY_FILE: vmReadyFile,
    EAI_TEST_VM_SIGNAL_FILE: vmSignalFile,
    EAI_TEST_VM_START_COUNT_FILE: vmStartCountFile,
    EAI_TEST_CLEANUP_READY_FILE: cleanupReadyFile,
    EAI_TEST_CLEANUP_COUNT_FILE: cleanupCountFile,
    ...(secondDuringCleanup ? {EAI_TEST_CLEANUP_DELAY_MS: "250"} : {}),
    ...extraEnvironment,
  };
  const child = spawn(process.execPath, [
    runner, "--version", "0.2.0", "--repo", "fixture/repo", "--tag", "fixture-tag",
    "--vms", vms, "--output", fixtureOutput, "--deprovision", "api",
  ], {
    cwd: root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const closePromise = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, closeSignal) => resolve({ code, signal: closeSignal }));
  });
  try {
    await waitForFixtureFile(vmReadyFile, child, `${name} VM readiness`);
    assert.equal(child.kill(signal), true);
    await waitForFixtureFile(vmSignalFile, child, `${name} forwarded signal`);
    const vmReady = JSON.parse(fs.readFileSync(vmReadyFile, "utf8"));
    const vmSignal = JSON.parse(fs.readFileSync(vmSignalFile, "utf8"));
    assert.deepEqual(vmSignal, {signal, pid: vmReady.pid});
    if (secondDuringCleanup) {
      await waitForFixtureFile(cleanupReadyFile, child, `${name} cleanup start`);
    }
    assert.equal(child.kill(signal), true);
    const close = await waitForFixtureClose(closePromise, `${name} controller exit`);
    const report = JSON.parse(fs.readFileSync(path.join(fixtureOutput, "release-e2e.json"), "utf8"));
    return { close, report, stdout, stderr, fixtureOutput, protectedTenantName, vmStartCountFile, cleanupCountFile, vmPid: vmReady.pid };
  } catch (error) {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      child.kill("SIGTERM");
    }
    throw error;
  }
};

const gracefulInterrupt = await runSignalFixture({
  name: "signal-graceful-cleanup",
  signal: "SIGINT",
  vmMode: "signal-exit",
  secondDuringCleanup: true,
  vms: "windows,ubuntu",
});
assert.equal(gracefulInterrupt.close.code, 130, gracefulInterrupt.stderr);
assert.equal(gracefulInterrupt.close.signal, null);
assert.equal(gracefulInterrupt.report.status, "interrupted");
assert.equal(gracefulInterrupt.report.interruption.signal, "SIGINT");
assert.equal(gracefulInterrupt.report.interruption.exitCode, 130);
assert.equal(gracefulInterrupt.report.interruption.signalCount, 2);
assert.equal(gracefulInterrupt.report.interruption.targetRole, "vm:windows");
assert.equal(gracefulInterrupt.report.interruption.targetProcessId, gracefulInterrupt.vmPid);
assert.equal(gracefulInterrupt.report.interruption.forwardedToActiveChild, true);
assert.equal(gracefulInterrupt.report.interruption.forceAttempted, true);
assert.equal(gracefulInterrupt.report.interruption.forced, false);
assert.equal(gracefulInterrupt.report.interruption.terminationObserved, true);
assert.equal(gracefulInterrupt.report.machines.length, 1);
assert.equal(gracefulInterrupt.report.machines[0].status, "interrupted");
assert.equal(gracefulInterrupt.report.machines[0].appStateCheckpoint, "verified");
assert.equal(gracefulInterrupt.report.machines[0].appCreated, true);
assert.equal(gracefulInterrupt.report.machines[0].cleanupVerified, true);
assert.ok(gracefulInterrupt.report.completedAt);
assert.equal(fs.readFileSync(gracefulInterrupt.vmStartCountFile, "utf8"), "1");
assert.equal(fs.readFileSync(gracefulInterrupt.cleanupCountFile, "utf8"), "1");
const gracefulVmLog = fs.readFileSync(path.join(gracefulInterrupt.fixtureOutput, "windows", "vm-output.log"), "utf8");
assert.doesNotMatch(gracefulVmLog, new RegExp(gracefulInterrupt.protectedTenantName));
assert.match(gracefulVmLog, /\[REDACTED\]/);
assert.doesNotMatch(JSON.stringify(gracefulInterrupt.report), new RegExp(gracefulInterrupt.protectedTenantName));
assert.match(JSON.stringify(gracefulInterrupt.report), /\[REDACTED\]/);
const gracefulCleanupReceipt = fs.readFileSync(path.join(gracefulInterrupt.fixtureOutput, "windows", "cleanup-receipt.json"), "utf8");
assert.doesNotMatch(gracefulCleanupReceipt, new RegExp(gracefulInterrupt.protectedTenantName));
assert.match(gracefulCleanupReceipt, /\[REDACTED\]/);
assert.doesNotMatch(gracefulInterrupt.stderr, /UnhandledPromiseRejection|unhandled rejection/i);

const forcedInterrupt = await runSignalFixture({
  name: "signal-forced-child",
  signal: "SIGTERM",
  vmMode: "signal-ignore",
  secondDuringCleanup: false,
  extraEnvironment: {
    EAI_TEST_INVALID_DELETION_FIELD: "deletedRecords",
    EAI_TEST_INVALID_DELETION_JSON: "{}",
  },
});
assert.equal(forcedInterrupt.close.code, 143, forcedInterrupt.stderr);
assert.equal(forcedInterrupt.close.signal, null);
assert.equal(forcedInterrupt.report.status, "interrupted");
assert.equal(forcedInterrupt.report.interruption.signal, "SIGTERM");
assert.equal(forcedInterrupt.report.interruption.exitCode, 143);
assert.equal(forcedInterrupt.report.interruption.signalCount, 2);
assert.equal(forcedInterrupt.report.interruption.targetProcessId, forcedInterrupt.vmPid);
assert.equal(forcedInterrupt.report.interruption.forwardedToActiveChild, true);
assert.equal(forcedInterrupt.report.interruption.forceAttempted, true);
assert.equal(forcedInterrupt.report.interruption.forced, true);
assert.equal(forcedInterrupt.report.interruption.forceReason, "second-signal");
assert.equal(forcedInterrupt.report.interruption.terminationObserved, true);
assert.equal(forcedInterrupt.report.interruption.terminationSignal, "SIGKILL");
assert.equal(forcedInterrupt.report.machines[0].appStateCheckpoint, "verified");
assert.equal(forcedInterrupt.report.machines[0].appCreated, true);
assert.equal(forcedInterrupt.report.machines[0].cleanupVerified, false);
assert.match(forcedInterrupt.report.machines[0].cleanupError, /non-empty deletion evidence/);
assert.equal(fs.readFileSync(forcedInterrupt.vmStartCountFile, "utf8"), "1");
assert.equal(fs.readFileSync(forcedInterrupt.cleanupCountFile, "utf8"), "1");
assert.doesNotMatch(forcedInterrupt.stderr, /UnhandledPromiseRejection|unhandled rejection/i);
}

const shellSyntax = execFileSync("bash", ["-n", path.join(root, "release.sh")], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(shellSyntax, "");
assert.equal(execFileSync("bash", ["-n", macosGuestPreparer], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", macosAiWorkspacePreparer], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", macosGuestLogin], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", macosCurrentUserLibrary], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", [macosCurrentUserTest], { cwd: root, encoding: "utf8" }), "macOS Parallels transport checks ok\n");
assert.equal(execFileSync("bash", ["-n", windowsAiWorkspacePreparer], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", windowsAiHandoffProcessQuery], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", windowsAiHandoffProcessQueryTest], { cwd: root, encoding: "utf8" }), "");
assert.equal(
  execFileSync("bash", [windowsAiHandoffProcessQueryTest], { cwd: root, encoding: "utf8" }),
  "Windows AI handoff process query checks ok\n",
);
assert.equal(execFileSync("bash", ["-n", windowsReadonlyPowerShell], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", windowsReadonlyPowerShellTest], { cwd: root, encoding: "utf8" }), "");
assert.equal(
  execFileSync("bash", [windowsReadonlyPowerShellTest], { cwd: root, encoding: "utf8" }),
  "Windows read-only PowerShell transport checks ok\n",
);
assert.equal(execFileSync("bash", ["-n", windowsGuestLogin], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", windowsPortalCleanupUi], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", windowsPortalCleanupUiTest], { cwd: root, encoding: "utf8" }), "");
if (process.platform !== "win32") {
assert.equal(
  execFileSync("bash", [windowsPortalCleanupUiTest], { cwd: root, encoding: "utf8" }),
  "Windows portal cleanup UI checks ok\n",
);
}
assert.equal(execFileSync("bash", ["-n", windowsDiagnosticCleanupTest], { cwd: root, encoding: "utf8" }), "");
if (process.platform !== "win32") {
assert.equal(
  execFileSync("bash", [windowsDiagnosticCleanupTest], { cwd: root, encoding: "utf8" }),
  "Windows diagnostic cleanup host regression passed.\n",
);
}
for (const ubuntuShell of [ubuntuGuestCore, ubuntuGuestSession, ubuntuGuestLogin, ubuntuAiWorkspacePreparer, ubuntuGuestTest]) {
  assert.equal(execFileSync("bash", ["-n", ubuntuShell], { cwd: root, encoding: "utf8" }), "");
}
assert.equal(
  execFileSync("bash", [ubuntuGuestTest], { cwd: root, encoding: "utf8" }),
  "Ubuntu release adapter static tests passed.\n",
);
assert.equal(execFileSync("bash", ["-n", guestTestLibrary], { cwd: root, encoding: "utf8" }), "");
assert.equal(execFileSync("bash", ["-n", vmAdapterPreflight], { cwd: root, encoding: "utf8" }), "");
assert.match(vmAdapterPreflightSource, /\$prlctl_bin list "\$vm_name" --info/);
assert.match(vmAdapterPreflightSource, /\$prlctl_bin snapshot-list "\$vm_name"/);
assert.match(vmAdapterPreflightSource, /"schemaVersion":"eai\.vm-adapter-preflight\.v1"/);
assert.match(vmAdapterPreflightSource, /"mutationAttempted":false/);
assert.doesNotMatch(vmAdapterPreflightSource, /\$prlctl_bin (?:start|stop|snapshot-switch|exec)/);
for (const [index, adapter] of guestAdapters.entries()) {
  const source = fs.readFileSync(adapter, "utf8");
  const implementation = index === 2 ? ubuntuGuestCoreSource : source;
  const mutableBoundary = index === 2
    ? source.indexOf('exec /bin/bash "$hardened_core"')
    : source.indexOf('work_dir="$(mktemp -d)');
  assert.ok(source.indexOf('"--preflight"') < mutableBoundary, "VM preflight must run before mutable adapter setup");
  assert.match(source, /exec "\$ROOT\/scripts\/vm-adapter-preflight\.sh" (?:macos|windows|ubuntu) "\$vm_name" "\$snapshot_id"/);
  assert.match(implementation, /guest_test_restore_snapshot/);
  assert.match(implementation, /guest_test_finalize/);
  assert.doesNotMatch(`${source}\n${implementation}`, /PASSWORD|CLIENT_SECRET|DEPROVISION_TOKEN/);
  assert.equal(execFileSync("bash", ["-n", adapter], { cwd: root, encoding: "utf8" }), "");
}
assert.match(fs.readFileSync(guestAdapters[0], "utf8"), /prepare-macos-guest-dmg\.sh/);
assert.match(macosGuestAdapterSource, /vm_name="\$\{EAI_MACOS_VM_NAME:-macOS\}"/);
assert.match(macosGuestAdapterSource, /snapshot_id="\$\{EAI_MACOS_SNAPSHOT_ID:-462d2ce7-701e-4257-a95d-545590e86784\}"/);
assert.match(macosGuestAdapterSource, /mac_admin_service="eai-installer-parallels-macos-admin"/);
assert.match(macosGuestAdapterSource, /mac_admin_account="testmac"/);
assert.match(macosGuestAdapterSource, /The controlled macOS release guest must use the testmac account/);
assert.match(
  macosGuestAdapterSource,
  /find-generic-password -s "\$mac_admin_service" -a "\$mac_admin_account" >\/dev\/null 2>&1/,
);
assert.equal(
  (macosGuestAdapterSource.match(/find-generic-password -s "\$mac_admin_service" -a "\$mac_admin_account" -w/g) ?? []).length,
  1,
);
assert.doesNotMatch(macosGuestAdapterSource, /EAI_MACOS_ADMIN_KEYCHAIN_SERVICE/);
assert.doesNotMatch(macosGuestAdapterSource, /find-generic-password[^\n]*-a "\$guest_user"/);
assert.doesNotMatch(macosGuestAdapterSource, /--password|EAI_VM_GUEST_PASSWORD/);
assert.match(windowsGuestAdapterSource, /eai-douglasross/);
assert.match(ubuntuGuestAdapterSource, /exec \/bin\/bash "\$hardened_core" "\$@"/);
assert.doesNotMatch(ubuntuGuestAdapterSource, /EAI_SETUP_E2E_COMPANY_TENANT/);
assert.match(ubuntuGuestCoreSource, /Ubuntu 24[.]04[.]3 ARM64/);
assert.match(ubuntuGuestCoreSource, /2119c623-791d-411a-b599-087dfc5eb9fb/);
for (const effectiveAutologinCheck of [
  /gdm_autologin_parser_source\(\)/,
  /configparser[.]ConfigParser\(/,
  /strict=True/,
  /parser[.]optionxform = str[.]lower/,
  /name[.]strip\(\)[.]casefold\(\) == "daemon"/,
  /len\(daemon_sections\) != 1/,
  /target_keys = \{"automaticloginenable", "automaticlogin"\}/,
  /target_keys[.]intersection\(parser[.]defaults\(\)\)/,
  /daemon = parser[.]_sections\[daemon_sections\[0\]\]/,
  /target_keys[.]issubset\(daemon\)/,
  /enabled != "true"/,
  /configured_autologin[\s\S]*== "\$guest_user"/,
]) {
  assert.match(ubuntuGuestCoreSource, effectiveAutologinCheck);
}
assert.match(ubuntuGuestCoreSource, /verified-clean/);
assert.match(ubuntuGuestCoreSource, /host_hash/);
assert.match(ubuntuGuestCoreSource, /guest_hash/);
assert.match(ubuntuGuestCoreSource, /dpkg-deb -f/);
assert.match(ubuntuGuestCoreSource, /install ok installed/);
assert.match(ubuntuGuestCoreSource, /EAI_VM_INSTALLER_VERIFIED=1/);
assert.match(ubuntuGuestCoreSource, /EAI_VM_PREREQUISITES_PROVEN=1/);
assert.match(ubuntuGuestCoreSource, /EAI_VM_PROJECT_VERIFIED=1/);
assert.match(ubuntuGuestCoreSource, /EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1/);
assert.match(ubuntuGuestCoreSource, /EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1/);
assert.match(ubuntuGuestCoreSource, /Released-product prerequisite defect/);
assert.match(ubuntuGuestCoreSource, /noHarnessPrerequisiteRepair: true/);
assert.match(ubuntuGuestCoreSource, /prerequisite-contract-validation/);
assert.match(ubuntuGuestCoreSource, /minimumNodeMajor: 24/);
assert.match(ubuntuGuestCoreSource, /pinned to EAI CLI 3[.]15[.]10/);
for (const npmProviderCheck of [
  /validate_npm_provider_values\(\)/,
  /installed_node_package_status=/,
  /== 'install ok installed'/,
  /npmSeparateDebPackageRequired: false/,
  /ownerPackageStatus: "install ok installed"/,
]) {
  assert.match(ubuntuGuestCoreSource, npmProviderCheck);
}
assert.doesNotMatch(ubuntuGuestCoreSource, /installed_npm_package_version/);
assert.doesNotMatch(ubuntuGuestCoreSource, /dpkg-query[^\n]*-W[^\n]*npm/);
assert.equal(
  (ubuntuGuestCoreSource.match(/json[.]dumps[(][{]"verticalKey":sys[.]argv\[1\][}][)]/g) ?? []).length,
  2,
);
assert.doesNotMatch(ubuntuGuestCoreSource, /[{]"verticalKey":[{]"equals"/);
assert.match(ubuntuGuestCoreSource, /arm_exact_remote_cleanup/);
assert.match(ubuntuGuestCoreSource, /remote-mutation-cleanup-armed/);
assert.match(ubuntuGuestCoreSource, /ubuntu-remote-app-checkpoint[.]json/);
assert.match(ubuntuGuestCoreSource, /remoteAppCheckpointUncertain/);
assert.match(ubuntuGuestCoreSource, /durableCreationCheckpointMatched: true/);
assert.match(ubuntuGuestCoreSource, /readlink -f "\$process\/cwd"/);
assert.match(ubuntuGuestCoreSource, /processArgumentsInspected: true/);
assert.match(ubuntuGuestCoreSource, /\/dev\/stdin "\$protected_input"/);
assert.match(ubuntuGuestSessionSource, /loginctl list-sessions/);
assert.match(ubuntuGuestSessionSource, /loginctl show-session/);
assert.match(ubuntuGuestSessionSource, /seat0/);
assert.match(ubuntuGuestSessionSource, /XDG_SESSION_ID/);
assert.match(ubuntuGuestSessionSource, /XDG_SESSION_TYPE/);
assert.match(ubuntuGuestSessionSource, /WAYLAND_DISPLAY/);
assert.match(ubuntuGuestSessionSource, /XAUTHORITY/);
assert.match(ubuntuGuestLoginSource, /find-generic-password/);
assert.match(ubuntuGuestLoginSource, /input type --stdin/);
assert.match(ubuntuGuestLoginSource, /assert-origin/);
assert.match(ubuntuGuestLoginSource, /tenant list --format json/);
assert.match(ubuntuGuestLoginSource, /profile_bound_firefox/);
assert.match(ubuntuGuestLoginSource, /export BROWSER=/);
assert.match(ubuntuGuestLoginSource, /CLI_DISPOSABLE_BROWSER_BOUND/);
for (const firefoxProvenanceCheck of [
  /firefox_snap_root_proof\(\)/,
  /revision=\$\(readlink \/snap\/firefox\/current\)/,
  /snap_root=\/snap\/firefox\/\$revision/,
  /readlink -f \/snap\/firefox\/current/,
  /findmnt -n -o FSTYPE,OPTIONS/,
  /squashfs/,
  /main_binary=\$snap_root\/usr\/lib\/firefox\/firefox/,
  /"\$snap_root\/usr\/lib\/firefox\/firefox"\|"\$snap_root\/usr\/lib\/firefox\/firefox-bin"/,
  /EAI_RELEASE_E2E_FIREFOX_PROFILE=\$profile/,
]) {
  assert.match(ubuntuGuestLoginSource, firefoxProvenanceCheck);
}
assert.doesNotMatch(ubuntuGuestLoginSource, /--password|EAI_VM_GUEST_PASSWORD/);
assert.match(ubuntuAiWorkspacePreparerSource, /1[.]136[.]1/);
assert.match(ubuntuAiWorkspacePreparerSource, /baa72f92d3feaa76d015202c57271475ea15809e635587279171a972cdd612a4/);
assert.match(ubuntuAiWorkspacePreparerSource, /copilot-chat/);
assert.match(ubuntuUiActionSource, /command == "assert-origin"/);

console.log("live release gate contract checks ok");
