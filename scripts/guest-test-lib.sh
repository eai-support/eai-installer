#!/usr/bin/env bash

set -euo pipefail

guest_test_fail() {
  printf 'Guest release test failed: %s\n' "$*" >&2
  exit 1
}

guest_test_require() {
  command -v "$1" >/dev/null 2>&1 || guest_test_fail "Required command not found: $1"
}

guest_test_require_environment() {
  local key
  for key in EAI_VM_DOWNLOAD_URL EAI_VM_ASSET EAI_VM_PROJECT_NAME EAI_VM_RESULT_FILE EAI_VM_APP_STATE_FILE EAI_HARNESS_TENANT_ID EAI_HARNESS_TENANT_NAME EAI_HARNESS_USER_EMAIL EAI_HARNESS_PUBLIC_API_URL; do
    [[ -n "${!key:-}" ]] || guest_test_fail "$key is required."
  done
  [[ "$EAI_VM_DOWNLOAD_URL" =~ ^https://github\.com/eai-support/eai-installer/releases/download/[^[:space:]]+$ ]] \
    || guest_test_fail "EAI_VM_DOWNLOAD_URL must be an eai-support/eai-installer GitHub release asset URL."
  [[ -f "$EAI_VM_ASSET" ]] || guest_test_fail "EAI_VM_ASSET does not exist."
  [[ "$EAI_VM_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || guest_test_fail "EAI_VM_PROJECT_NAME must be kebab-case."
  [[ "$EAI_HARNESS_TENANT_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || guest_test_fail "EAI_HARNESS_TENANT_ID must be a tenant UUID."
  [[ "$EAI_HARNESS_PUBLIC_API_URL" =~ ^https://api\.(au|ca|eu)\.myenterprise\.ai/public$ ]] \
    || guest_test_fail "EAI_HARNESS_PUBLIC_API_URL must be an approved regional PublicAPI origin."
  mkdir -p "$(dirname "$EAI_VM_RESULT_FILE")" "$(dirname "$EAI_VM_APP_STATE_FILE")"
}

guest_test_restore_snapshot() {
  local vm_name="$1"
  local snapshot_id="$2"
  local status=""
  local switch_output=""
  # Bash's `${VAR:-{uuid}}` syntax can leave a trailing brace when callers
  # provide an ID with braces. Normalize both `{uuid}` and `uuid` inputs
  # before passing the value to prlctl.
  snapshot_id="$(printf '%s' "$snapshot_id" | tr -d '{}')"
  snapshot_id="{$snapshot_id}"
  prlctl snapshot-list "$vm_name" | grep -Fq "$snapshot_id" || guest_test_fail "Snapshot $snapshot_id was not found for $vm_name."
  printf 'Restoring approved snapshot for %s...\n' "$vm_name"

  # Do not resume a powered-on snapshot's saved memory image. Saved state can
  # become incompatible after a Parallels or guest OS update; --skip-resume
  # restores the snapshot disk and then boots it normally below.
  status="$(prlctl status "$vm_name" 2>/dev/null || true)"
  if [[ "$status" == *suspended* ]]; then
    prlctl stop "$vm_name" --drop-state >/dev/null
  elif [[ "$status" == *running* || "$status" == *paused* ]]; then
    prlctl stop "$vm_name" --kill >/dev/null
  fi
  for _ in $(seq 1 60); do
    status="$(prlctl status "$vm_name" 2>/dev/null || true)"
    [[ "$status" == *stopped* ]] && break
    sleep 1
  done
  [[ "$status" == *stopped* ]] || guest_test_fail "$vm_name did not stop before snapshot restore."

  switch_output="$(prlctl snapshot-switch "$vm_name" --id "$snapshot_id" --skip-resume 2>&1)" \
    || guest_test_fail "Parallels could not restore $snapshot_id without resuming saved memory: $switch_output"
  printf 'Restored the snapshot disk without resuming saved memory.\n'
  status="$(prlctl status "$vm_name" 2>/dev/null || true)"
  [[ "$status" == *running* ]] || prlctl start "$vm_name"
  for _ in $(seq 1 90); do
    status="$(prlctl status "$vm_name" 2>/dev/null || true)"
    [[ "$status" == *running* ]] && return 0
    sleep 2
  done
  guest_test_fail "$vm_name did not reach the running state after snapshot restore."
}

guest_test_host_sha256() {
  /usr/bin/shasum -a 256 "$EAI_VM_ASSET" | /usr/bin/awk '{print $1}'
}

guest_test_finalize() {
  local vm_id="$1"
  local project_path="$2"
  local desktop_receipt="$3"
  local host_hash="$4"
  local guest_hash="$5"
  local versions_json="$6"
  node --input-type=module - "$vm_id" "$project_path" "$desktop_receipt" "$host_hash" "$guest_hash" "$versions_json" "$EAI_VM_PROJECT_NAME" "$EAI_VM_RESULT_FILE" "$EAI_VM_APP_STATE_FILE" <<'NODE'
import fs from "node:fs";

const [vm, projectPath, receiptPath, hostHash, guestHash, versionsJson, appName, resultPath, appStatePath] = process.argv.slice(2);
const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
const versions = JSON.parse(versionsJson);
const installerVerified = process.env.EAI_VM_INSTALLER_VERIFIED;
const prerequisitesProven = process.env.EAI_VM_PREREQUISITES_PROVEN;
const aiHandoffProcessVerified = process.env.EAI_VM_AI_HANDOFF_PROCESS_VERIFIED;
const aiHandoffScreenshotVerified = process.env.EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED;
const projectVerified = process.env.EAI_VM_PROJECT_VERIFIED;
const defenderExactFileAdded = process.env.EAI_VM_DEFENDER_EXACT_FILE_ADDED;
const defenderExactFileRemoved = process.env.EAI_VM_DEFENDER_EXACT_FILE_REMOVED;
const executableSha256 = process.env.EAI_VM_EXECUTABLE_SHA256 || null;
const evidenceDirectory = resultPath.slice(0, resultPath.lastIndexOf("/"));
const readEvidence = (name) => {
  const evidencePath = `${evidenceDirectory}/${name}`;
  return fs.existsSync(evidencePath) ? JSON.parse(fs.readFileSync(evidencePath, "utf8")) : null;
};
const defenderAddEvidence = vm === "windows" ? readEvidence("windows-defender-exclusion-add.json") : null;
const defenderRemoveEvidence = vm === "windows" ? readEvidence("windows-defender-exclusion-remove.json") : null;
const installerBridgeEvidence = vm === "windows" ? readEvidence("windows-installer-bridge.json") : null;
const uacConsentPolicyEvidence = vm === "windows" ? readEvidence("windows-uac-consent-policy.json") : null;
const uacConsentUiMonitorEvidence = vm === "windows" ? readEvidence("windows-uac-consent-ui-monitor.json") : null;
const defenderProofPassed = vm !== "windows" || (
  defenderExactFileAdded === "1"
  && defenderExactFileRemoved === "1"
  && defenderAddEvidence?.status === "ready"
  && defenderAddEvidence?.assetSha256 === hostHash
  && defenderAddEvidence?.scope === "exact-file"
  && defenderAddEvidence?.diagnosticOnly === true
  && defenderAddEvidence?.productionGate === false
  && defenderAddEvidence?.elevationMethod === "parallels-protected-LocalSystem"
  && defenderAddEvidence?.uacUsed === false
  && defenderAddEvidence?.systemIdentityVerified === true
  && defenderAddEvidence?.administratorRoleVerified === true
  && defenderAddEvidence?.receiptSystemOwned === true
  && /^[0-9a-f]{64}$/.test(defenderAddEvidence?.guardianWorkerSha256 || "")
  && defenderAddEvidence?.guardianWorkerNonceBound === true
  && Number.isInteger(defenderAddEvidence?.guardianProcessId)
  && defenderAddEvidence.guardianProcessId > 0
  && defenderAddEvidence?.workerScriptHashVerified === true
  && defenderAddEvidence?.workerProcessPathVerified === true
  && defenderAddEvidence?.workerSessionVerified === true
  && defenderAddEvidence?.effectiveExclusionPresentBefore === false
  && defenderAddEvidence?.precheckProbeVerified === true
  && defenderAddEvidence?.exactExclusionPresent === true
  && defenderAddEvidence?.soleExclusionDelta === true
  && defenderAddEvidence?.completionSignalVerified === true
  && defenderAddEvidence?.targetHashVerified === true
  && defenderAddEvidence?.mpCmdRunVerified === true
  && defenderAddEvidence?.protectionEnabled === true
  && defenderAddEvidence?.protectionSettingsUnchanged === true
  && defenderRemoveEvidence?.status === "removed-verified"
  && defenderRemoveEvidence?.assetSha256 === hostHash
  && defenderRemoveEvidence?.scope === "exact-file"
  && defenderRemoveEvidence?.diagnosticOnly === true
  && defenderRemoveEvidence?.productionGate === false
  && defenderRemoveEvidence?.elevationMethod === "parallels-protected-LocalSystem"
  && defenderRemoveEvidence?.uacUsed === false
  && defenderRemoveEvidence?.systemIdentityVerified === true
  && defenderRemoveEvidence?.administratorRoleVerified === true
  && defenderRemoveEvidence?.receiptSystemOwned === true
  && defenderRemoveEvidence?.guardianWorkerSha256 === defenderAddEvidence?.guardianWorkerSha256
  && defenderRemoveEvidence?.guardianWorkerNonceBound === true
  && defenderRemoveEvidence?.guardianProcessId === defenderAddEvidence?.guardianProcessId
  && defenderRemoveEvidence?.guardianProcessStartedAt === defenderAddEvidence?.guardianProcessStartedAt
  && defenderRemoveEvidence?.workerScriptHashVerified === true
  && defenderRemoveEvidence?.workerProcessPathVerified === true
  && defenderRemoveEvidence?.workerSessionVerified === true
  && defenderRemoveEvidence?.removedByGuardian === true
  && defenderRemoveEvidence?.exactExclusionAbsent === true
  && defenderRemoveEvidence?.baselineExclusionSetRestored === true
  && defenderRemoveEvidence?.mpCmdRunVerifiedNotExcluded === true
  && defenderRemoveEvidence?.protectionSettingsUnchanged === true
  && defenderRemoveEvidence?.cleanupVerified === true
  && defenderRemoveEvidence?.guardianTimedOut === false
  && Date.parse(defenderAddEvidence?.guardianProcessStartedAt) <= Date.parse(defenderAddEvidence?.recordedAt)
  && Date.parse(defenderAddEvidence?.recordedAt) <= Date.parse(defenderRemoveEvidence?.recordedAt)
);
const installerBridgeProofPassed = vm !== "windows" || (
  installerBridgeEvidence?.status === "completed"
  && installerBridgeEvidence?.assetSha256 === hostHash
  && installerBridgeEvidence?.identityVerified === true
  && installerBridgeEvidence?.interactiveSessionVerified === true
  && /^[0-9a-f]{64}$/.test(installerBridgeEvidence?.workerScriptSha256 || "")
  && installerBridgeEvidence?.workerNonceBound === true
  && Number.isInteger(installerBridgeEvidence?.workerProcessId)
  && installerBridgeEvidence.workerProcessId > 0
  && Number.isInteger(installerBridgeEvidence?.workerProcessSessionId)
  && installerBridgeEvidence.workerProcessSessionId > 0
  && installerBridgeEvidence?.workerScriptHashVerified === true
  && installerBridgeEvidence?.workerProcessPathVerified === true
  && installerBridgeEvidence?.workerSessionVerified === true
  && installerBridgeEvidence?.targetAbsentWhenArmed === true
  && installerBridgeEvidence?.launchSignalSystemOwned === true
  && installerBridgeEvidence?.launchSignalHashBound === true
  && installerBridgeEvidence?.defenderReadyReceiptVerified === true
  && installerBridgeEvidence?.defenderCleanupNotRequestedAtLaunch === true
  && installerBridgeEvidence?.targetRegularFileVerified === true
  && installerBridgeEvidence?.targetHashVerified === true
  && installerBridgeEvidence?.targetLaunchLockVerified === true
  && installerBridgeEvidence?.launchStartInfoPathVerified === true
  && (installerBridgeEvidence?.liveProcessPathVerified === true
    || installerBridgeEvidence?.liveProcessExitedBeforePathInspection === true)
  && installerBridgeEvidence?.processPathVerified === true
  && installerBridgeEvidence?.installerStarted === true
  && installerBridgeEvidence?.installerExited === true
  && installerBridgeEvidence?.installerExitCode === 0
  && Number.isInteger(installerBridgeEvidence?.installerProcessId)
  && installerBridgeEvidence.installerProcessId > 0
  && (installerBridgeEvidence?.liveProcessExitedBeforePathInspection === true || (
    Number.isInteger(installerBridgeEvidence?.installerProcessSessionId)
    && installerBridgeEvidence.installerProcessSessionId > 0
    && !Number.isNaN(Date.parse(installerBridgeEvidence?.installerProcessStartedAt))
  ))
  && installerBridgeEvidence?.cancelRequested === false
  && installerBridgeEvidence?.timedOut === false
  && installerBridgeEvidence?.errorType === null
  && Date.parse(installerBridgeEvidence?.workerProcessStartedAt) <= Date.parse(installerBridgeEvidence?.armedAt)
  && Date.parse(defenderAddEvidence?.recordedAt) <= Date.parse(installerBridgeEvidence?.installerStartedAt)
  && Date.parse(installerBridgeEvidence?.completedAt) <= Date.parse(defenderRemoveEvidence?.recordedAt)
);
const uacConsentPolicyProofPassed = vm !== "windows" || (
  uacConsentPolicyEvidence?.schemaVersion === "eai-windows-uac-consent-policy/v1"
  && /^[0-9a-f]{32}$/.test(uacConsentPolicyEvidence?.nonce || "")
  && /^[0-9a-f]{64}$/.test(uacConsentPolicyEvidence?.runBindingSha256 || "")
  && uacConsentPolicyEvidence?.runBindingSha256 === process.env.EAI_VM_UAC_POLICY_RUN_BINDING
  && uacConsentPolicyEvidence?.registryPath === "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System"
  && uacConsentPolicyEvidence?.valueName === "ConsentPromptBehaviorAdmin"
  && uacConsentPolicyEvidence?.before?.consentPromptBehaviorAdmin?.kind === "DWord"
  && uacConsentPolicyEvidence?.before?.consentPromptBehaviorAdmin?.value === 5
  && uacConsentPolicyEvidence?.before?.promptOnSecureDesktop?.kind === "DWord"
  && uacConsentPolicyEvidence?.before?.promptOnSecureDesktop?.value === 0
  && uacConsentPolicyEvidence?.before?.enableLUA?.kind === "DWord"
  && uacConsentPolicyEvidence?.before?.enableLUA?.value === 1
  && uacConsentPolicyEvidence?.after?.consentPromptBehaviorAdmin?.kind === "DWord"
  && uacConsentPolicyEvidence?.after?.consentPromptBehaviorAdmin?.value === 0
  && uacConsentPolicyEvidence?.after?.promptOnSecureDesktop?.kind === "DWord"
  && uacConsentPolicyEvidence?.after?.promptOnSecureDesktop?.value === 0
  && uacConsentPolicyEvidence?.after?.enableLUA?.kind === "DWord"
  && uacConsentPolicyEvidence?.after?.enableLUA?.value === 1
  && uacConsentPolicyEvidence?.mutationPerformed === true
  && uacConsentPolicyEvidence?.localSystem === true
  && uacConsentPolicyEvidence?.administrator === true
  && uacConsentPolicyEvidence?.scope === "machine-wide temporary admin-consent window bounded by the Windows adapter"
  && uacConsentPolicyEvidence?.diagnosticOnly === true
  && uacConsentPolicyEvidence?.productionGate === false
  && uacConsentPolicyEvidence?.uacConsentUiCovered === false
  && uacConsentPolicyEvidence?.policyTemporarilyRelaxed === true
  && uacConsentPolicyEvidence?.approvalInputSent === false
  && uacConsentPolicyEvidence?.uacApprovalCount === 0
  && uacConsentPolicyEvidence?.restoration?.schemaVersion === "eai-windows-uac-consent-policy-restore/v1"
  && uacConsentPolicyEvidence?.restoration?.nonce === uacConsentPolicyEvidence?.nonce
  && uacConsentPolicyEvidence?.restoration?.runBindingSha256 === uacConsentPolicyEvidence?.runBindingSha256
  && uacConsentPolicyEvidence?.restoration?.before?.consentPromptBehaviorAdmin?.kind === "DWord"
  && uacConsentPolicyEvidence?.restoration?.before?.consentPromptBehaviorAdmin?.value === 0
  && uacConsentPolicyEvidence?.restoration?.before?.promptOnSecureDesktop?.kind === "DWord"
  && uacConsentPolicyEvidence?.restoration?.before?.promptOnSecureDesktop?.value === 0
  && uacConsentPolicyEvidence?.restoration?.before?.enableLUA?.kind === "DWord"
  && uacConsentPolicyEvidence?.restoration?.before?.enableLUA?.value === 1
  && uacConsentPolicyEvidence?.restoration?.after?.consentPromptBehaviorAdmin?.kind === "DWord"
  && uacConsentPolicyEvidence?.restoration?.after?.consentPromptBehaviorAdmin?.value === 5
  && uacConsentPolicyEvidence?.restoration?.after?.promptOnSecureDesktop?.kind === "DWord"
  && uacConsentPolicyEvidence?.restoration?.after?.promptOnSecureDesktop?.value === 0
  && uacConsentPolicyEvidence?.restoration?.after?.enableLUA?.kind === "DWord"
  && uacConsentPolicyEvidence?.restoration?.after?.enableLUA?.value === 1
  && uacConsentPolicyEvidence?.restoration?.mutationPerformed === true
  && uacConsentPolicyEvidence?.restoration?.localSystem === true
  && uacConsentPolicyEvidence?.restoration?.administrator === true
  && uacConsentPolicyEvidence?.currentlyRelaxed === false
  && uacConsentPolicyEvidence?.restorationRequired === false
  && uacConsentPolicyEvidence?.restorationVerified === true
  && Number.isFinite(Date.parse(uacConsentPolicyEvidence?.changedAt))
  && Number.isFinite(Date.parse(uacConsentPolicyEvidence?.restoration?.restoredAt))
  && Date.parse(uacConsentPolicyEvidence?.changedAt) <= Date.parse(uacConsentPolicyEvidence?.restoration?.restoredAt)
);
const uacConsentUiMonitorProofPassed = vm !== "windows" || (
  uacConsentUiMonitorEvidence?.schemaVersion === "eai-windows-uac-consent-ui-monitor/v1"
  && uacConsentUiMonitorEvidence?.runBindingSha256 === uacConsentPolicyEvidence?.runBindingSha256
  && Number.isFinite(Date.parse(uacConsentUiMonitorEvidence?.startedAt))
  && Number.isFinite(Date.parse(uacConsentUiMonitorEvidence?.stoppedAt))
  && Date.parse(uacConsentPolicyEvidence?.changedAt) <= Date.parse(uacConsentUiMonitorEvidence?.startedAt)
  && Date.parse(uacConsentUiMonitorEvidence?.startedAt) <= Date.parse(uacConsentUiMonitorEvidence?.stoppedAt)
  && Date.parse(uacConsentUiMonitorEvidence?.stoppedAt) <= Date.parse(uacConsentPolicyEvidence?.restoration?.restoredAt)
  && uacConsentUiMonitorEvidence?.unexpectedConsentUiDetected === false
  && uacConsentUiMonitorEvidence?.approvalInputSent === false
  && uacConsentUiMonitorEvidence?.uacApprovalCount === 0
  && uacConsentUiMonitorEvidence?.monitorExitedCleanly === true
);
const installerProofPassed = installerVerified === "1"
  && /^[0-9a-f]{64}$/.test(executableSha256 || "")
  && defenderProofPassed
  && installerBridgeProofPassed;
const checks = {
  download: hostHash === guestHash ? "passed" : "failed",
  installer: installerProofPassed ? "passed" : "failed",
  prerequisites: receipt.checks?.prerequisites === "passed"
    && prerequisitesProven === "1"
    && uacConsentPolicyProofPassed
    && uacConsentUiMonitorProofPassed ? "passed" : "failed",
  authentication: receipt.checks?.authentication,
  tenant: receipt.checks?.tenant,
  app: receipt.checks?.app,
  project: receipt.checks?.project === "passed"
    && projectVerified === "1" ? "passed" : "failed",
  aiHandoff: receipt.checks?.aiHandoff === "passed"
    && aiHandoffProcessVerified === "1"
    && aiHandoffScreenshotVerified === "1" ? "passed" : "failed",
};
const passed = receipt.status === "passed" && Object.values(checks).every((value) => value === "passed");
const result = {
  status: passed ? "passed" : "failed",
  vm,
  appName,
  projectPath,
  appCreated: receipt.appCreated === true,
  cleanupRequested: true,
  checks,
  hashes: { host: hostHash, guest: guestHash },
  versions,
  adapterEvidence: {
    installerVerified: installerVerified === "1",
    prerequisiteInstallProven: prerequisitesProven === "1",
    executableSha256,
    prerequisitesBefore: process.env.EAI_VM_PREREQUISITES_BEFORE
      ? JSON.parse(process.env.EAI_VM_PREREQUISITES_BEFORE)
      : null,
    aiHandoffProcessVerified: aiHandoffProcessVerified === "1",
    aiHandoffScreenshotVerified: aiHandoffScreenshotVerified === "1",
    projectVerified: projectVerified === "1",
    defenderExactFileAllowance: vm === "windows" ? {
      diagnosticOnly: true,
      productionGate: false,
      scope: "exact-file",
      added: defenderExactFileAdded === "1",
      removed: defenderExactFileRemoved === "1",
      proofPassed: defenderProofPassed,
      addEvidence: defenderAddEvidence,
      removeEvidence: defenderRemoveEvidence,
    } : null,
    installerBridge: vm === "windows" ? {
      proofPassed: installerBridgeProofPassed,
      evidence: installerBridgeEvidence,
    } : null,
    uacConsentPolicy: vm === "windows" ? {
      proofPassed: uacConsentPolicyProofPassed,
      evidence: uacConsentPolicyEvidence,
    } : null,
    uacConsentUiMonitor: vm === "windows" ? {
      proofPassed: uacConsentUiMonitorProofPassed,
      evidence: uacConsentUiMonitorEvidence,
    } : null,
    aiWorkspace: (() => {
      const evidencePath = `${evidenceDirectory}/${vm}-ai-workspace.json`;
      return fs.existsSync(evidencePath) ? JSON.parse(fs.readFileSync(evidencePath, "utf8")) : null;
    })(),
  },
  completedAt: new Date().toISOString(),
  message: receipt.message || "",
};
fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
fs.writeFileSync(appStatePath, `${JSON.stringify({
  appName,
  appCreated: result.appCreated,
  cleanupRequired: result.appCreated,
  cleanupRequested: result.cleanupRequested === true,
}, null, 2)}\n`);
if (!passed) process.exitCode = 1;
NODE
}
