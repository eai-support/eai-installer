#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/windows-hidden-current-user.sh
source "$ROOT/scripts/windows-hidden-current-user.sh"
vm_name="${EAI_WINDOWS_VM_NAME:-Windows 11}"
guest_user="${EAI_WINDOWS_GUEST_USER:-eai-douglasross}"
prlctl_bin="${EAI_WINDOWS_CLEANUP_PRLCTL_BIN:-$(command -v prlctl 2>/dev/null || true)}"
hidden_ps_command="${EAI_WINDOWS_CLEANUP_HIDDEN_PS_COMMAND:-}"
login_command="${EAI_WINDOWS_CLEANUP_LOGIN_COMMAND:-$ROOT/scripts/login-windows-guest.sh}"
ps_helper="$ROOT/scripts/windows-diagnostic-cleanup.ps1"
ocr_source="$ROOT/scripts/macos-ocr-match.swift"
keychain_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
tenant_id_service="${EAI_TENANT_ID_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-id}"
tenant_name_service="${EAI_TENANT_NAME_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-name}"
keychain_account="${EAI_TENANT_KEYCHAIN_ACCOUNT:-release-e2e}"
mode="cleanup"
run_dir_input=""
work_dir="$(mktemp -d)"

# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() {
  rm -rf -- "$work_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'Windows diagnostic cleanup failed: %s\n' "$*" >&2
  exit 1
}

run_hidden_cleanup_ps() {
  if [[ -n "$hidden_ps_command" ]]; then
    [[ -x "$hidden_ps_command" && -f "$hidden_ps_command" && ! -L "$hidden_ps_command" ]] || return 126
    "$hidden_ps_command" "$vm_name"
  else
    windows_hidden_current_user_ps "$vm_name" ""
  fi
}

usage() {
  cat <<'EOF'
Usage:
  scripts/run-windows-diagnostic-cleanup.sh --run-dir <release-e2e-run>
  scripts/run-windows-diagnostic-cleanup.sh --run-dir <release-e2e-run> --verify-only
  scripts/run-windows-diagnostic-cleanup.sh --run-dir <release-e2e-run> --finalize-portal

The app key is read only from the run's validated Windows receipts. The cleanup
mode first attempts exact PublicAPI V4 deletion. The diagnostic enrollment
fallback requires manual-cleanup-child-gate.json produced by the companion gate
writer after exact portal and zero-child review. Portal navigation/deletion is
not automated; --finalize-portal validates the manually captured exact absence
screenshot after the two CLI/API absence checks pass.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --run-dir)
      [[ "$#" -ge 2 && -z "$run_dir_input" ]] || fail "--run-dir requires one value."
      run_dir_input="$2"
      shift 2
      ;;
    --verify-only)
      [[ "$mode" == cleanup ]] || fail "Choose only one cleanup mode."
      mode="verify"
      shift
      ;;
    --finalize-portal)
      [[ "$mode" == cleanup ]] || fail "Choose only one cleanup mode."
      mode="finalize-portal"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument."
      ;;
  esac
done

[[ -n "$run_dir_input" ]] || fail "--run-dir is required."
[[ "$guest_user" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The expected Windows guest user is invalid."
[[ -d "$run_dir_input" && ! -L "$run_dir_input" ]] || fail "The run directory must be a real directory, not a symlink."
artifact_root="$ROOT/artifacts/release-e2e"
[[ -d "$artifact_root" ]] || fail "The release E2E artifact root is missing."
artifact_root="$(cd "$artifact_root" && pwd -P)"
run_dir="$(cd "$run_dir_input" && pwd -P)"
case "$run_dir/" in
  "$artifact_root"/*) ;;
  *) fail "The run directory must be under artifacts/release-e2e." ;;
esac
run_id="$(basename "$run_dir")"
[[ "$run_id" =~ ^[0-9]{13}-[0-9a-f]{6}$ ]] || fail "The run directory name is not a release E2E run ID."
vm_dir="$run_dir/windows"
[[ -d "$vm_dir" && ! -L "$vm_dir" ]] || fail "The Windows evidence directory is missing or is a symlink."

for required_file in "$run_dir/release-e2e.json" "$vm_dir/app-state.json" "$vm_dir/vm-result.json"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] || fail "Required run evidence is missing or unsafe."
done

app_key="$({
  node --input-type=module - "$run_dir/release-e2e.json" "$vm_dir/app-state.json" "$vm_dir/vm-result.json" "$vm_dir/windows-remote-cleanup-arm.json" "$run_id" <<'NODE'
import fs from "node:fs";

const [reportPath, statePath, resultPath, armPath, runId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
const required = ["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
const expected = `test-windows-${runId}`;
const validCheck = (value) => ["passed", "failed", "not-run"].includes(value);
if (report.runId !== runId || !["passed_with_mock_cleanup", "passed", "failed"].includes(report.status)) throw new Error("controller-run-status");
const machines = Array.isArray(report.machines) ? report.machines.filter((machine) => machine?.vm === "windows") : [];
if (machines.length !== 1 || machines[0].appName !== expected || machines[0].appCreated !== true) throw new Error("controller-windows-target");
if (state.appName !== expected || state.appCreated !== true) throw new Error("app-state-not-exact-created-target");
if (result.vm !== "windows" || result.appName !== expected || result.appCreated !== true || result.cleanupRequested !== true) throw new Error("vm-result-target");
if (required.some((name) => !validCheck(result.checks?.[name]))) throw new Error("vm-result-invalid-checks");
const successfulRun = ["passed_with_mock_cleanup", "passed"].includes(report.status)
  && machines[0].status === "passed"
  && result.status === "passed"
  && required.every((name) => result.checks[name] === "passed");
let failedAfterCreationCheckpoint = false;
if (report.status === "failed" && machines[0].status === "failed" && machines[0].cleanupVerified !== true
    && result.status === "failed"
    && state.cleanupRequired === true && state.cleanupRequested === true
    && state.state === "remote-mutation-cleanup-armed" && state.conservative === true) {
  const armStat = fs.lstatSync(armPath);
  if (!armStat.isFile() || armStat.isSymbolicLink()) throw new Error("remote-cleanup-arm-unsafe");
  const arm = JSON.parse(fs.readFileSync(armPath, "utf8"));
  const progressiveReceiptProvesCreation = ["prerequisites", "authentication", "tenant", "app"]
    .every((name) => result.checks[name] === "passed");
  const exactLocalProjectProvesCreation = result.exactLocalProjectCheckpoint === true
    && state.exactLocalProjectCheckpoint === true;
  failedAfterCreationCheckpoint = (progressiveReceiptProvesCreation || exactLocalProjectProvesCreation)
    && arm.schemaVersion === "eai.windows-remote-cleanup-arm.v1"
    && arm.appName === expected
    && arm.cleanupRequired === true
    && arm.mutationNotYetProven === true
    && arm.sanitized === true
    && arm.diagnostic === true
    && arm.productionGate === false
    && typeof arm.armedAt === "string"
    && arm.armedAt === state.armedAt
    && Number.isFinite(Date.parse(arm.armedAt))
    && Number.isFinite(Date.parse(result.completedAt))
    && Date.parse(arm.armedAt) <= Date.parse(result.completedAt);
}
if (!successfulRun && !failedAfterCreationCheckpoint) throw new Error("run-did-not-prove-created-app");
if (!/^[a-z0-9][a-z0-9-]{0,127}$/.test(expected)) throw new Error("generated-app-key-invalid");
process.stdout.write(expected);
NODE
} 2>/dev/null)" || fail "The run evidence does not identify one exact Windows app eligible for diagnostic cleanup."
[[ "$app_key" == "test-windows-$run_id" ]] || fail "The validated Windows app key is not bound to this run."

load_protected_runtime() {
  test_email="${EAI_HARNESS_USER_EMAIL:-}"
  tenant_id="${EAI_HARNESS_TENANT_ID:-}"
  tenant_name="${EAI_HARNESS_TENANT_NAME:-}"
  if [[ -z "$test_email" ]]; then
    test_email="$(/usr/bin/security find-generic-password -s "$keychain_service" 2>/dev/null \
      | /usr/bin/awk -F '"' '$2 == "acct" { print $4; exit }')"
  fi
  if [[ -z "$tenant_id" ]]; then
    tenant_id="$(/usr/bin/security find-generic-password -s "$tenant_id_service" -a "$keychain_account" -w 2>/dev/null || true)"
  fi
  if [[ -z "$tenant_name" ]]; then
    tenant_name="$(/usr/bin/security find-generic-password -s "$tenant_name_service" -a "$keychain_account" -w 2>/dev/null || true)"
  fi
  [[ -n "$test_email" && "$test_email" != *[[:space:]]* ]] || fail "The protected test account is unavailable."
  [[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || fail "The protected harness tenant ID is unavailable."
  [[ -n "$tenant_name" ]] || fail "The protected harness tenant name is unavailable."
}

load_protected_runtime
tenant_id_sha256="$(printf '%s' "$tenant_id" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
[[ "$tenant_id_sha256" =~ ^[a-f0-9]{64}$ ]] \
  || fail "The protected harness tenant fingerprint could not be calculated."

compile_ocr() {
  ocr_binary="$work_dir/macos-ocr-match"
  [[ -f "$ocr_source" ]] || fail "The screenshot OCR source is missing."
  /usr/bin/swiftc -O "$ocr_source" -o "$ocr_binary" >/dev/null \
    || fail "The screenshot OCR helper could not be compiled."
}

ocr_has() {
  local image_path="$1"
  local pattern="$2"
  EAI_OCR_PATTERN="$pattern" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
    "$ocr_binary" "$image_path" >/dev/null 2>&1
}

assert_screenshot_sanitized() {
  local image_path="$1"
  local required_one="$2"
  local required_two="$3"
  [[ -f "$image_path" && ! -L "$image_path" ]] || fail "A required cleanup screenshot is missing or unsafe."
  ocr_has "$image_path" "$required_one" || fail "A cleanup screenshot does not show its exact target."
  ocr_has "$image_path" "$required_two" || fail "A cleanup screenshot does not show its required semantic state."
  local protected_pattern
  for protected_pattern in \
    "$test_email" "$tenant_id" "$tenant_name" \
    'localhost' '?code=' 'code=' 'access_token' 'refresh_token' \
    'client_info' 'session_state' 'Authentication complete' 'successfully authenticated'; do
    if ocr_has "$image_path" "$protected_pattern"; then
      fail "A cleanup screenshot contains protected or callback data."
    fi
  done
}

write_json_from_result() {
  local result_file="$1"
  EAI_RESULT_FILE="$result_file" EAI_VM_DIR="$vm_dir" EAI_AUTH_AT="$fresh_auth_at" \
  EAI_TENANT_HASH="$tenant_id_sha256" node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const result = JSON.parse(fs.readFileSync(process.env.EAI_RESULT_FILE, "utf8"));
const directory = process.env.EAI_VM_DIR;
const write = (name, payload) => fs.writeFileSync(path.join(directory, name), `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });

if (result.v4Attempt) {
  const attemptPath = path.join(directory, "manual-v4-delete-attempt.json");
  let previousAttempts = 0;
  try {
    const previous = JSON.parse(fs.readFileSync(attemptPath, "utf8"));
    if (previous.runId === result.runId && previous.appName === result.appName) previousAttempts = Number(previous.attempts) || 0;
  } catch {}
  write("manual-v4-delete-attempt.json", {
    runId: result.runId,
    platform: "windows",
    appName: result.appName,
    ...result.v4Attempt,
    attempts: previousAttempts + (Number(result.v4Attempt.attempts) || 1),
    sanitized: true,
    diagnostic: true,
    productionGate: false,
  });
}

if (result.action === "fallback-gate-required") {
  write("windows-cleanup-preflight.json", {
    schemaVersion: "eai.windows-diagnostic-cleanup-preflight.v1",
    runId: result.runId,
    platform: "windows",
    appName: result.appName,
    displayName: result.displayName,
    resourceCreatedAt: result.resourceCreatedAt,
    resourceIdSha256: result.resourceIdSha256,
    preDeleteValidation: result.preDeleteValidation,
    v4AttemptReceipt: "manual-v4-delete-attempt.json",
    fallbackEligibleAfterManualZeroChildGate: true,
    portalDeleteAutomationAvailable: false,
    sanitized: true,
    diagnostic: true,
    productionGate: false,
    recordedAt: result.recordedAt,
  });
}

if (["deleted-v4", "deleted-fallback"].includes(result.action)) {
  write("manual-cleanup-receipt.json", {
    schemaVersion: "eai.windows-diagnostic-cleanup-receipt.v1",
    runId: result.runId,
    platform: "windows",
    appName: result.appName,
    appCreated: true,
    cleanupMode: "manual-diagnostic",
    method: result.method,
    displayName: result.displayName,
    resourceType: "tenant-vertical-enrollment",
    resourceId: "[REDACTED]",
    resourceIdSha256: result.resourceIdSha256,
    resourceCreatedAt: result.resourceCreatedAt,
    tenantIdSha256: process.env.EAI_TENANT_HASH,
    preDeleteValidation: result.preDeleteValidation,
    v4AttemptReceipt: "manual-v4-delete-attempt.json",
    deletion: result.deletion,
    deleted: true,
    freshGuestAuthProven: true,
    freshGuestAuthAt: process.env.EAI_AUTH_AT,
    portalDeleteAttempted: false,
    portalPermanentDeleteClicked: false,
    portalDeleteAutomationAvailable: false,
    portalVerificationRequired: true,
    verificationReceipt: "manual-cleanup-verification.json",
    cleanupVerified: false,
    sanitized: true,
    diagnostic: true,
    productionGate: false,
    recordedAt: result.recordedAt,
  });
  write("manual-cleanup-verification.json", {
    schemaVersion: "eai.windows-diagnostic-cleanup-verification.v1",
    runId: result.runId,
    platform: "windows",
    appName: result.appName,
    tenantIdSha256: process.env.EAI_TENANT_HASH,
    checks: {
      resourceApiExactMatchesAfter: result.absence.resourceApiExactMatchesAfter,
      cliExactMatchesAfter: result.absence.cliExactMatchesAfter,
      portalExactMatchesAfter: null,
    },
    resourceAndCliVerifiedAt: result.absence.verifiedAt,
    portalVerifiedAt: null,
    portalSemanticResult: "manual-portal-verification-required",
    cleanupVerified: false,
    sanitized: true,
    diagnostic: true,
    productionGate: false,
  });
}

if (result.action === "verify-only") {
  const receipt = (() => { try { return JSON.parse(fs.readFileSync(path.join(directory, "manual-cleanup-receipt.json"), "utf8")); } catch { return null; } })();
  const verificationPath = path.join(directory, "manual-cleanup-verification.json");
  const verification = (() => { try { return JSON.parse(fs.readFileSync(verificationPath, "utf8")); } catch { return null; } })();
  if (receipt?.runId === result.runId && receipt?.appName === result.appName && receipt?.deleted === true && verification) {
    if (receipt.tenantIdSha256 !== process.env.EAI_TENANT_HASH || verification.tenantIdSha256 !== process.env.EAI_TENANT_HASH) throw new Error("cleanup-tenant-fingerprint-mismatch");
    verification.checks = {
      ...(verification.checks || {}),
      resourceApiExactMatchesAfter: result.absence.resourceApiExactMatchesAfter,
      cliExactMatchesAfter: result.absence.cliExactMatchesAfter,
    };
    verification.resourceAndCliVerifiedAt = result.absence.verifiedAt;
    verification.cleanupVerified = verification.checks.portalExactMatchesAfter === 0 && result.absence.verified === true;
    write("manual-cleanup-verification.json", verification);
    if (verification.cleanupVerified) {
      receipt.cleanupVerified = true;
      write("manual-cleanup-receipt.json", receipt);
    }
  } else {
    const attempt2InvocationPath = path.join(directory, "windows-portal-delete-attempt-2-invocation.json");
    if (fs.existsSync(attempt2InvocationPath)) {
      const requiredNames = [
        "windows-portal-cleanup-target.json",
        "windows-portal-delete-invocation.json",
        "windows-portal-delete-attempt-1-still-present.json",
        "windows-portal-delete-attempt-2-target.json",
        "windows-portal-delete-attempt-2-prepared.json",
        "windows-portal-delete-attempt-2-preinvoke.json",
        "windows-portal-delete-attempt-2-invocation.json",
      ];
      const requiredPaths = Object.fromEntries(requiredNames.map((name) => [name, path.join(directory, name)]));
      for (const [name, file] of Object.entries(requiredPaths)) {
        const stat = fs.lstatSync(file);
        if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`attempt2-evidence-${name}-unsafe`);
      }
      const bytes = (name) => fs.readFileSync(requiredPaths[name]);
      const read = (name) => JSON.parse(bytes(name).toString("utf8"));
      const hashBytes = (value) => crypto.createHash("sha256").update(value).digest("hex");
      const hash = (name) => hashBytes(bytes(name));
      const markings = (value) => value?.sanitized === true && value?.diagnostic === true && value?.productionGate === false;
      const validChildHistory = (history) => {
        const classificationValid = history?.classification === "authoritative-independent-resource-queries"
          ? history.authoritativeAtAttempt1 === true && history.acceptedForIdentityAndProvenanceOnly === false
          : history?.classification === "legacy-embedded-fields-nonauthoritative"
            && history.authoritativeAtAttempt1 === false && history.acceptedForIdentityAndProvenanceOnly === true;
        return classificationValid
          && history.legacyChildCountsTrustedForAttempt2 === false
          && history.freshAttempt2AuthoritativeGateRequired === true;
      };
      const sameChildHistory = (left, right) => validChildHistory(left)
        && validChildHistory(right)
        && JSON.stringify(left) === JSON.stringify(right);
      const validateFreshChildEvidence = (checks, code) => {
        if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true) throw new Error(`${code}-child-gate-invalid`);
        const expected = [[checks.childQueries.serviceActivations, "vertical-service-activation"], [checks.childQueries.productConfigs, "vertical-product-config"]];
        for (const [query, objectType] of expected) {
          if (query?.objectType !== objectType || query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || query.querySucceeded !== true || query.completeBoundedPage !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000 || query.exactVerticalKeyMatches !== 0) throw new Error(`${code}-child-query-evidence-invalid`);
        }
      };
      const childHistoryForOriginal = (checks) => {
        if (checks?.authoritativeChildQueriesComplete === true) {
          validateFreshChildEvidence(checks, "attempt1-original");
          return { classification: "authoritative-independent-resource-queries", authoritativeAtAttempt1: true, acceptedForIdentityAndProvenanceOnly: false, legacyChildCountsTrustedForAttempt2: false, freshAttempt2AuthoritativeGateRequired: true };
        }
        const legacyKeys = ["createdDuringThisRun", "embeddedChildFieldsEmpty", "enrollmentExactMatches", "servicesBeforeDeletion", "setupExactMatchesBeforeDeletion", "sourceVerified", "workflowExactMatchesBeforeDeletion"];
        if (!checks || JSON.stringify(Object.keys(checks).sort()) !== JSON.stringify(legacyKeys) || checks.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.embeddedChildFieldsEmpty !== true || checks.servicesBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0) throw new Error("attempt1-original-child-evidence-shape-invalid");
        return { classification: "legacy-embedded-fields-nonauthoritative", authoritativeAtAttempt1: false, acceptedForIdentityAndProvenanceOnly: true, legacyChildCountsTrustedForAttempt2: false, freshAttempt2AuthoritativeGateRequired: true };
      };
      const originalTarget = read("windows-portal-cleanup-target.json");
      const attempt1Invocation = read("windows-portal-delete-invocation.json");
      const presence = read("windows-portal-delete-attempt-1-still-present.json");
      const target = read("windows-portal-delete-attempt-2-target.json");
      const prepared = read("windows-portal-delete-attempt-2-prepared.json");
      const preinvoke = read("windows-portal-delete-attempt-2-preinvoke.json");
      const invocation = read("windows-portal-delete-attempt-2-invocation.json");
      if (attempt1Invocation.schemaVersion !== "eai.windows-portal-delete-invocation.v1" || attempt1Invocation.runId !== result.runId || attempt1Invocation.appName !== result.appName || attempt1Invocation.mutationState !== "invoked-unverified" || attempt1Invocation.transportExitCode !== 0 || attempt1Invocation.retryMutationAutomatically !== false || !markings(attempt1Invocation)) throw new Error("attempt2-attempt1-invocation-invalid");
      const expectedChildHistory = childHistoryForOriginal(originalTarget.preDeleteValidation);
      if (presence.schemaVersion !== "eai.windows-portal-delete-attempt-1-still-present.v1" || presence.attempt !== 1 || presence.runId !== result.runId || presence.appName !== result.appName || presence.attempt1TargetReceiptSha256 !== hash("windows-portal-cleanup-target.json") || presence.attempt1InvocationReceiptSha256 !== hash("windows-portal-delete-invocation.json") || presence.checks?.resourceApiExactMatchesAfter !== 1 || presence.checks?.cliExactMatchesAfter !== 1 || presence.verifiedAbsent !== false || !sameChildHistory(presence.attempt1TargetChildEvidence, expectedChildHistory) || !markings(presence)) throw new Error("attempt2-presence-invalid");
      if (target.schemaVersion !== "eai.windows-portal-delete-attempt-2-target.v1" || target.attempt !== 2 || target.runId !== result.runId || target.appName !== result.appName || target.originalTargetReceiptSha256 !== hash("windows-portal-cleanup-target.json") || target.attempt1StillPresentReceiptSha256 !== hash("windows-portal-delete-attempt-1-still-present.json") || target.identityMatchesOriginal !== true || target.resourceIdSha256 !== originalTarget.resourceIdSha256 || target.resourceCreatedAt !== originalTarget.resourceCreatedAt || target.displayName !== originalTarget.displayName || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || !sameChildHistory(target.attempt1TargetChildEvidence, presence.attempt1TargetChildEvidence) || target.freshAttempt2AuthoritativeChildGateEstablished !== true || target.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries" || !markings(target)) throw new Error("attempt2-target-invalid");
      validateFreshChildEvidence(target.preDeleteValidation, "attempt2-target");
      if (prepared.schemaVersion !== "eai.windows-portal-delete-attempt-2-prepared.v1" || prepared.attempt !== 2 || prepared.runId !== result.runId || prepared.appName !== result.appName || prepared.targetReceiptSha256 !== hash("windows-portal-delete-attempt-2-target.json") || prepared.attempt1StillPresentReceiptSha256 !== hash("windows-portal-delete-attempt-1-still-present.json") || prepared.resourceIdSha256 !== target.resourceIdSha256 || prepared.resourceCreatedAt !== target.resourceCreatedAt || prepared.tenantIdSha256 !== process.env.EAI_TENANT_HASH || !sameChildHistory(prepared.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || prepared.freshAttempt2AuthoritativeChildGateEstablished !== true || prepared.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || prepared.explicitActionTimeConfirmationRequired !== true || prepared.preInvokeTargetRevalidationRequired !== true || prepared.deletePermanentlyInvoked !== false || !/^[a-f0-9]{64}$/.test(prepared.confirmationNonceSha256 || "") || !markings(prepared)) throw new Error("attempt2-prepared-invalid");
      if (preinvoke.schemaVersion !== "eai.windows-portal-delete-attempt-2-preinvoke.v1" || preinvoke.attempt !== 2 || preinvoke.runId !== result.runId || preinvoke.appName !== result.appName || preinvoke.targetReceiptSha256 !== hash("windows-portal-delete-attempt-2-target.json") || preinvoke.preparedReceiptSha256 !== hash("windows-portal-delete-attempt-2-prepared.json") || preinvoke.resourceIdSha256 !== target.resourceIdSha256 || preinvoke.resourceCreatedAt !== target.resourceCreatedAt || preinvoke.tenantIdSha256 !== process.env.EAI_TENANT_HASH || preinvoke.identityMatchesOriginal !== true || !sameChildHistory(preinvoke.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || preinvoke.freshAttempt2AuthoritativeChildGateEstablished !== true || preinvoke.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || preinvoke.confirmationNonceSha256 !== prepared.confirmationNonceSha256 || preinvoke.explicitActionTimeConfirmationAccepted !== true || preinvoke.exactDialogReadyRevalidated !== true || preinvoke.interactiveWorkerReverified !== true || !markings(preinvoke)) throw new Error("attempt2-preinvoke-invalid");
      validateFreshChildEvidence(preinvoke.preDeleteValidation, "attempt2-preinvoke");
      if (invocation.schemaVersion !== "eai.windows-portal-delete-attempt-2-invocation.v1" || invocation.attempt !== 2 || invocation.runId !== result.runId || invocation.appName !== result.appName || invocation.action !== "invoke-delete-attempt-2" || invocation.tenantIdSha256 !== process.env.EAI_TENANT_HASH || invocation.attempt1InvocationReceiptSha256 !== hash("windows-portal-delete-invocation.json") || invocation.attempt1StillPresentReceiptSha256 !== hash("windows-portal-delete-attempt-1-still-present.json") || invocation.targetReceiptSha256 !== hash("windows-portal-delete-attempt-2-target.json") || invocation.preparedReceiptSha256 !== hash("windows-portal-delete-attempt-2-prepared.json") || invocation.preInvokeReceiptSha256 !== hash("windows-portal-delete-attempt-2-preinvoke.json") || !sameChildHistory(invocation.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || invocation.freshAttempt2AuthoritativeChildGateEstablished !== true || invocation.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || invocation.confirmationNonceSha256 !== prepared.confirmationNonceSha256 || invocation.explicitActionTimeConfirmationAccepted !== true || invocation.mutationState !== "invoked-dialog-closed-unverified" || invocation.armedBeforeDestructiveInput !== true || invocation.transportExitCode !== 0 || invocation.interactiveDesktopLaunchAttempted !== true || invocation.interactiveResultValidated !== true || invocation.exactDialogVerified !== true || invocation.exactTypedValueVerified !== true || invocation.exactDialogRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactButtonFocused !== true || invocation.scopedInvokePatternInvoked !== true || invocation.exactExpectedUser !== true || invocation.interactiveSessionProven !== true || !Number.isInteger(invocation.interactiveSessionId) || invocation.interactiveSessionId <= 0 || invocation.explorerSessionMatched !== true || invocation.edgeUiBoundToInteractiveSession !== true || invocation.confirmationDialogClosed !== true || invocation.dialogAbsentConsecutiveChecks < 12 || invocation.dialogClosureStableMilliseconds < 3000 || invocation.retryMutationAutomatically !== false || invocation.deletionVerified !== false || invocation.absenceVerificationRequired !== true || !markings(invocation)) throw new Error("attempt2-invocation-invalid");
      if (invocation.explorerOwnerSidMatched !== true || invocation.edgeOwnerSidMatched !== true || !Number.isInteger(invocation.browserWindowHandle) || invocation.browserWindowHandle <= 0 || !Number.isInteger(invocation.browserProcessId) || invocation.browserProcessId <= 0 || invocation.browserProcessSessionId !== invocation.interactiveSessionId || !/^[a-f0-9]{64}$/.test(invocation.topLevelWindowRuntimeIdSha256 || "") || !/^[a-f0-9]{64}$/.test(invocation.dialogFinalRuntimeIdSha256 || "") || invocation.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactBrowserWindowForegroundAtInvoke !== true) throw new Error("attempt2-interactive-window-proof-invalid");
      const invocationAt = Date.parse(invocation.completedAt || invocation.recordedAt);
      const verifiedAt = Date.parse(result.absence?.verifiedAt);
      if (!Number.isFinite(invocationAt) || !Number.isFinite(verifiedAt) || verifiedAt < invocationAt) throw new Error("attempt2-verification-time-invalid");
      const exactTwoChannelAbsence = result.absence?.resourceApiQuerySucceeded === true
        && result.absence?.cliAppListSucceeded === true
        && result.absence?.resourceApiExactMatchesAfter === 0
        && result.absence?.cliExactMatchesAfter === 0
        && result.absence?.verified === true;
      if (exactTwoChannelAbsence) {
        const attempt2Verification = {
          schemaVersion: "eai.windows-portal-delete-attempt-2-verification.v1",
          attempt: 2,
          runId: result.runId,
          platform: "windows",
          appName: result.appName,
          tenantIdSha256: process.env.EAI_TENANT_HASH,
          attempt2InvocationReceiptSha256: hash("windows-portal-delete-attempt-2-invocation.json"),
          attempt2TargetReceiptSha256: hash("windows-portal-delete-attempt-2-target.json"),
          attempt2PreInvokeReceiptSha256: hash("windows-portal-delete-attempt-2-preinvoke.json"),
          attempt1TargetChildEvidence: target.attempt1TargetChildEvidence,
          freshAttempt2AuthoritativeChildGateEstablished: true,
          freshAttempt2AuthoritativeChildGateSource: target.freshAttempt2AuthoritativeChildGateSource,
          checks: {
            resourceApiQuerySucceeded: true,
            resourceApiExactMatchesAfter: 0,
            cliAppListSucceeded: true,
            cliExactMatchesAfter: 0,
            portalExactMatchesAfter: null,
          },
          resourceAndCliVerifiedAt: result.absence.verifiedAt,
          verifiedAbsentOnResourceApiAndCli: true,
          portalVerificationRequired: true,
          cleanupVerified: false,
          sanitized: true,
          diagnostic: true,
          productionGate: false,
          recordedAt: result.recordedAt,
        };
        const attempt2VerificationPath = path.join(directory, "windows-portal-delete-attempt-2-verification.json");
        if (fs.existsSync(attempt2VerificationPath)) {
          const stat = fs.lstatSync(attempt2VerificationPath);
          if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("attempt2-verification-receipt-unsafe");
          const existing = JSON.parse(fs.readFileSync(attempt2VerificationPath, "utf8"));
          if (existing.schemaVersion !== attempt2Verification.schemaVersion || existing.attempt !== 2 || existing.runId !== result.runId || existing.appName !== result.appName || existing.tenantIdSha256 !== process.env.EAI_TENANT_HASH || existing.attempt2InvocationReceiptSha256 !== attempt2Verification.attempt2InvocationReceiptSha256 || existing.attempt2TargetReceiptSha256 !== attempt2Verification.attempt2TargetReceiptSha256 || existing.attempt2PreInvokeReceiptSha256 !== attempt2Verification.attempt2PreInvokeReceiptSha256 || !sameChildHistory(existing.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || existing.freshAttempt2AuthoritativeChildGateEstablished !== true || existing.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || existing.checks?.resourceApiExactMatchesAfter !== 0 || existing.checks?.cliExactMatchesAfter !== 0 || existing.verifiedAbsentOnResourceApiAndCli !== true || existing.portalVerificationRequired !== true || !markings(existing)) throw new Error("attempt2-verification-receipt-changed");
        } else {
          fs.writeFileSync(
            attempt2VerificationPath,
            `${JSON.stringify(attempt2Verification, null, 2)}\n`,
            { mode: 0o600, flag: "wx" },
          );
        }
        write("manual-cleanup-receipt.json", {
          schemaVersion: "eai.windows-diagnostic-cleanup-receipt.v1",
          runId: result.runId,
          platform: "windows",
          appName: result.appName,
          appCreated: true,
          cleanupMode: "manual-diagnostic",
          method: "admin-portal-interactive-delete-attempt-2",
          displayName: target.displayName,
          resourceType: "tenant-vertical-enrollment",
          resourceId: "[REDACTED]",
          resourceIdSha256: target.resourceIdSha256,
          resourceCreatedAt: target.resourceCreatedAt,
          tenantIdSha256: process.env.EAI_TENANT_HASH,
          attempt1TargetChildEvidence: target.attempt1TargetChildEvidence,
          freshAttempt2AuthoritativeChildGateEstablished: true,
          freshAttempt2AuthoritativeChildGateSource: target.freshAttempt2AuthoritativeChildGateSource,
          preDeleteValidation: target.preDeleteValidation,
          deletion: {
            method: "admin-portal-interactive-delete-attempt-2",
            attempt: 2,
            invocationReceipt: "windows-portal-delete-attempt-2-invocation.json",
            invocationReceiptSha256: hash("windows-portal-delete-attempt-2-invocation.json"),
            targetReceiptSha256: hash("windows-portal-delete-attempt-2-target.json"),
            preInvokeReceiptSha256: hash("windows-portal-delete-attempt-2-preinvoke.json"),
            exactInteractiveSession: true,
            sustainedDialogClosure: true,
          },
          deleted: true,
          freshGuestAuthProven: true,
          freshGuestAuthAt: process.env.EAI_AUTH_AT,
          portalDeleteAttempted: true,
          portalPermanentDeleteClicked: true,
          portalDeleteAutomationAvailable: true,
          portalVerificationRequired: true,
          verificationReceipt: "manual-cleanup-verification.json",
          cleanupVerified: false,
          sanitized: true,
          diagnostic: true,
          productionGate: false,
          recordedAt: result.recordedAt,
        });
        write("manual-cleanup-verification.json", {
          schemaVersion: "eai.windows-diagnostic-cleanup-verification.v1",
          runId: result.runId,
          platform: "windows",
          appName: result.appName,
          tenantIdSha256: process.env.EAI_TENANT_HASH,
          checks: {
            resourceApiExactMatchesAfter: 0,
            cliExactMatchesAfter: 0,
            portalExactMatchesAfter: null,
          },
          resourceAndCliVerifiedAt: result.absence.verifiedAt,
          portalVerifiedAt: null,
          portalSemanticResult: "manual-portal-verification-required",
          cleanupVerified: false,
          sanitized: true,
          diagnostic: true,
          productionGate: false,
        });
      } else {
        write("windows-portal-delete-attempt-2-verification-pending.json", {
          ...result,
          tenantIdSha256: process.env.EAI_TENANT_HASH,
        });
      }
    } else {
      const attempt1InvocationPath = path.join(directory, "windows-portal-delete-invocation.json");
      const exactTwoChannelAbsence = result.absence?.resourceApiQuerySucceeded === true
        && result.absence?.cliAppListSucceeded === true
        && result.absence?.resourceApiExactMatchesAfter === 0
        && result.absence?.cliExactMatchesAfter === 0
        && result.absence?.verified === true;
      if (fs.existsSync(attempt1InvocationPath) && exactTwoChannelAbsence) {
        const names = ["windows-portal-cleanup-target.json", "windows-portal-delete-prepared.json", "windows-portal-delete-invocation.json"];
        const raw = {};
        for (const name of names) {
          const file = path.join(directory, name);
          const stat = fs.lstatSync(file);
          if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`attempt1-evidence-${name}-unsafe`);
          raw[name] = fs.readFileSync(file);
        }
        const read = (name) => JSON.parse(raw[name].toString("utf8"));
        const hash = (name) => crypto.createHash("sha256").update(raw[name]).digest("hex");
        const markings = (value) => value?.sanitized === true && value?.diagnostic === true && value?.productionGate === false;
        const target = read(names[0]);
        const prepared = read(names[1]);
        const invocation = read(names[2]);
        if (target.schemaVersion !== "eai.windows-portal-cleanup-target.v1" || target.runId !== result.runId || target.appName !== result.appName || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || !markings(target)) throw new Error("attempt1-target-invalid");
        if (prepared.schemaVersion !== "eai.windows-portal-delete-prepared.v1" || prepared.runId !== result.runId || prepared.appName !== result.appName || prepared.tenantIdSha256 !== process.env.EAI_TENANT_HASH || prepared.targetReceiptSha256 !== hash(names[0]) || !markings(prepared)) throw new Error("attempt1-prepared-invalid");
        if (invocation.schemaVersion !== "eai.windows-portal-delete-invocation.v1" || invocation.runId !== result.runId || invocation.appName !== result.appName || invocation.tenantIdSha256 !== process.env.EAI_TENANT_HASH || invocation.targetReceiptSha256 !== hash(names[0]) || invocation.preparedReceiptSha256 !== hash(names[1]) || invocation.mutationState !== "invoked-unverified" || invocation.transportExitCode !== 0 || invocation.interactiveDesktopLaunchAttempted !== true || invocation.interactiveResultValidated !== true || invocation.exactDialogVerified !== true || invocation.exactTypedValueVerified !== true || invocation.exactDialogRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactButtonFocused !== true || invocation.scopedInvokePatternInvoked !== true || invocation.exactExpectedUser !== true || invocation.interactiveSessionProven !== true || !Number.isInteger(invocation.interactiveSessionId) || invocation.interactiveSessionId <= 0 || invocation.explorerSessionMatched !== true || invocation.explorerOwnerSidMatched !== true || invocation.edgeUiBoundToInteractiveSession !== true || invocation.edgeOwnerSidMatched !== true || !Number.isInteger(invocation.browserWindowHandle) || invocation.browserWindowHandle <= 0 || !Number.isInteger(invocation.browserProcessId) || invocation.browserProcessId <= 0 || invocation.browserProcessSessionId !== invocation.interactiveSessionId || !/^[a-f0-9]{64}$/.test(invocation.topLevelWindowRuntimeIdSha256 || "") || !/^[a-f0-9]{64}$/.test(invocation.dialogFinalRuntimeIdSha256 || "") || invocation.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactBrowserWindowForegroundAtInvoke !== true || invocation.confirmationDialogClosed !== true || invocation.dialogAbsentConsecutiveChecks < 12 || invocation.dialogClosureStableMilliseconds < 3000 || invocation.retryMutationAutomatically !== false || invocation.deletionVerified !== false || !markings(invocation)) throw new Error("attempt1-invocation-invalid");
        if (fs.statSync(process.env.EAI_RESULT_FILE).mtimeMs < fs.statSync(attempt1InvocationPath).mtimeMs) throw new Error("attempt1-verification-predates-invocation");
        const immutable = {
          schemaVersion: "eai.windows-portal-delete-attempt-1-verification.v1",
          attempt: 1,
          runId: result.runId,
          platform: "windows",
          appName: result.appName,
          tenantIdSha256: process.env.EAI_TENANT_HASH,
          attempt1InvocationReceiptSha256: hash(names[2]),
          checks: { resourceApiQuerySucceeded: true, resourceApiExactMatchesAfter: 0, cliAppListSucceeded: true, cliExactMatchesAfter: 0, portalExactMatchesAfter: null },
          resourceAndCliVerifiedAt: result.absence.verifiedAt,
          verifiedAbsentOnResourceApiAndCli: true,
          portalVerificationRequired: true,
          cleanupVerified: false,
          sanitized: true,
          diagnostic: true,
          productionGate: false,
          recordedAt: result.recordedAt,
        };
        const immutablePath = path.join(directory, "windows-portal-delete-attempt-1-verification.json");
        if (fs.existsSync(immutablePath)) {
          const existing = JSON.parse(fs.readFileSync(immutablePath, "utf8"));
          if (existing.attempt1InvocationReceiptSha256 !== immutable.attempt1InvocationReceiptSha256 || existing.tenantIdSha256 !== process.env.EAI_TENANT_HASH || existing.verifiedAbsentOnResourceApiAndCli !== true) throw new Error("attempt1-verification-receipt-changed");
        } else {
          fs.writeFileSync(immutablePath, `${JSON.stringify(immutable, null, 2)}\n`, { mode: 0o600, flag: "wx" });
        }
        write("manual-cleanup-receipt.json", {
          schemaVersion: "eai.windows-diagnostic-cleanup-receipt.v1", runId: result.runId, platform: "windows", appName: result.appName,
          tenantIdSha256: process.env.EAI_TENANT_HASH, appCreated: true, cleanupMode: "manual-diagnostic", method: "admin-portal-interactive-delete-attempt-1",
          displayName: target.displayName, resourceType: "tenant-vertical-enrollment", resourceId: "[REDACTED]", resourceIdSha256: target.resourceIdSha256, resourceCreatedAt: target.resourceCreatedAt,
          preDeleteValidation: target.preDeleteValidation, deletion: { method: "admin-portal-interactive-delete-attempt-1", attempt: 1, invocationReceipt: names[2], invocationReceiptSha256: hash(names[2]), exactInteractiveSession: true, sustainedDialogClosure: true },
          deleted: true, freshGuestAuthProven: true, freshGuestAuthAt: process.env.EAI_AUTH_AT, portalDeleteAttempted: true, portalPermanentDeleteClicked: true, portalDeleteAutomationAvailable: true,
          portalVerificationRequired: true, verificationReceipt: "manual-cleanup-verification.json", cleanupVerified: false, sanitized: true, diagnostic: true, productionGate: false, recordedAt: result.recordedAt,
        });
        write("manual-cleanup-verification.json", {
          schemaVersion: "eai.windows-diagnostic-cleanup-verification.v1", runId: result.runId, platform: "windows", appName: result.appName, tenantIdSha256: process.env.EAI_TENANT_HASH,
          checks: { resourceApiExactMatchesAfter: 0, cliExactMatchesAfter: 0, portalExactMatchesAfter: null }, resourceAndCliVerifiedAt: result.absence.verifiedAt,
          portalVerifiedAt: null, portalSemanticResult: "manual-portal-verification-required", cleanupVerified: false, sanitized: true, diagnostic: true, productionGate: false,
        });
      } else {
        write("windows-cleanup-verification-only.json", {
          ...result,
          tenantIdSha256: process.env.EAI_TENANT_HASH,
        });
      }
    }
  }
}

if (["v4-failed-not-eligible-for-fallback", "failed", "mutation-uncertain"].includes(result.action)) {
  write("windows-cleanup-failure.json", result);
}
NODE
}

finalize_portal() {
  local receipt="$vm_dir/manual-cleanup-receipt.json"
  local verification="$vm_dir/manual-cleanup-verification.json"
  local screenshot="$vm_dir/manual-cleanup-verified-absent.png"
  [[ -f "$receipt" && ! -L "$receipt" && -f "$verification" && ! -L "$verification" ]] \
    || fail "CLI/API cleanup evidence is incomplete; portal verification cannot be finalized."
  portal_values="$({
    EAI_TENANT_HASH="$tenant_id_sha256" node --input-type=module - \
      "$receipt" "$verification" "$vm_dir" "$run_id" "$app_key" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
const [receiptPath, verificationPath, directory, runId, appName] = process.argv.slice(2);
const safeBytes = (name) => {
  const file = path.join(directory, name);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${name}-unsafe`);
  return fs.readFileSync(file);
};
const hashBytes = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const validateChildEvidence = (checks) => {
  if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true) throw new Error("finalize-child-gate-invalid");
  const expected = [[checks.childQueries.serviceActivations, "vertical-service-activation"], [checks.childQueries.productConfigs, "vertical-product-config"]];
  for (const [query, objectType] of expected) if (query?.objectType !== objectType || query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || query.querySucceeded !== true || query.completeBoundedPage !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000 || query.exactVerticalKeyMatches !== 0) throw new Error("finalize-child-query-evidence-invalid");
};
const validChildHistory = (history) => {
  const classificationValid = history?.classification === "authoritative-independent-resource-queries"
    ? history.authoritativeAtAttempt1 === true && history.acceptedForIdentityAndProvenanceOnly === false
    : history?.classification === "legacy-embedded-fields-nonauthoritative"
      && history.authoritativeAtAttempt1 === false && history.acceptedForIdentityAndProvenanceOnly === true;
  return classificationValid
    && history.legacyChildCountsTrustedForAttempt2 === false
    && history.freshAttempt2AuthoritativeGateRequired === true;
};
const sameChildHistory = (left, right) => validChildHistory(left)
  && validChildHistory(right)
  && JSON.stringify(left) === JSON.stringify(right);
const childHistoryForOriginal = (checks) => {
  if (checks?.authoritativeChildQueriesComplete === true) {
    validateChildEvidence(checks);
    return { classification: "authoritative-independent-resource-queries", authoritativeAtAttempt1: true, acceptedForIdentityAndProvenanceOnly: false, legacyChildCountsTrustedForAttempt2: false, freshAttempt2AuthoritativeGateRequired: true };
  }
  const legacyKeys = ["createdDuringThisRun", "embeddedChildFieldsEmpty", "enrollmentExactMatches", "servicesBeforeDeletion", "setupExactMatchesBeforeDeletion", "sourceVerified", "workflowExactMatchesBeforeDeletion"];
  if (!checks || JSON.stringify(Object.keys(checks).sort()) !== JSON.stringify(legacyKeys) || checks.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.embeddedChildFieldsEmpty !== true || checks.servicesBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0) throw new Error("finalize-attempt1-child-evidence-shape-invalid");
  return { classification: "legacy-embedded-fields-nonauthoritative", authoritativeAtAttempt1: false, acceptedForIdentityAndProvenanceOnly: true, legacyChildCountsTrustedForAttempt2: false, freshAttempt2AuthoritativeGateRequired: true };
};
const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
const verification = JSON.parse(fs.readFileSync(verificationPath, "utf8"));
if (receipt.schemaVersion !== "eai.windows-diagnostic-cleanup-receipt.v1" || receipt.runId !== runId || receipt.appName !== appName || receipt.platform !== "windows" || receipt.deleted !== true || receipt.freshGuestAuthProven !== true || receipt.tenantIdSha256 !== process.env.EAI_TENANT_HASH) throw new Error("receipt-invalid");
if (verification.schemaVersion !== "eai.windows-diagnostic-cleanup-verification.v1" || verification.runId !== runId || verification.appName !== appName || verification.tenantIdSha256 !== process.env.EAI_TENANT_HASH || verification.checks?.resourceApiExactMatchesAfter !== 0 || verification.checks?.cliExactMatchesAfter !== 0) throw new Error("two-channel-verification-incomplete");
const chainParts = [fs.readFileSync(receiptPath), fs.readFileSync(verificationPath)];
if (receipt.method === "admin-portal-interactive-delete-attempt-2") {
  const names = [
    "windows-portal-cleanup-target.json",
    "windows-portal-delete-attempt-1-still-present.json",
    "windows-portal-delete-attempt-2-target.json",
    "windows-portal-delete-attempt-2-prepared.json",
    "windows-portal-delete-attempt-2-preinvoke.json",
    "windows-portal-delete-attempt-2-invocation.json",
    "windows-portal-delete-attempt-2-verification.json",
  ];
  const raw = Object.fromEntries(names.map((name) => [name, safeBytes(name)]));
  chainParts.push(...names.map((name) => raw[name]));
  const read = (name) => JSON.parse(raw[name].toString("utf8"));
  const hash = (name) => hashBytes(raw[name]);
  const originalTarget = read(names[0]);
  const presence = read(names[1]);
  const target = read(names[2]);
  const prepared = read(names[3]);
  const preinvoke = read(names[4]);
  const invocation = read(names[5]);
  const immutableVerification = read(names[6]);
  const expectedChildHistory = childHistoryForOriginal(originalTarget.preDeleteValidation);
  validateChildEvidence(target.preDeleteValidation);
  validateChildEvidence(preinvoke.preDeleteValidation);
  if ([target, prepared, preinvoke, invocation, immutableVerification].some((value) => value.tenantIdSha256 !== process.env.EAI_TENANT_HASH)) throw new Error("attempt2-finalize-tenant-mismatch");
  if (presence.attempt1TargetReceiptSha256 !== hash(names[0]) || target.originalTargetReceiptSha256 !== hash(names[0]) || target.attempt1StillPresentReceiptSha256 !== hash(names[1]) || prepared.attempt1StillPresentReceiptSha256 !== hash(names[1]) || prepared.targetReceiptSha256 !== hash(names[2]) || preinvoke.targetReceiptSha256 !== hash(names[2]) || preinvoke.preparedReceiptSha256 !== hash(names[3]) || invocation.attempt1StillPresentReceiptSha256 !== hash(names[1]) || invocation.targetReceiptSha256 !== hash(names[2]) || invocation.preparedReceiptSha256 !== hash(names[3]) || invocation.preInvokeReceiptSha256 !== hash(names[4])) throw new Error("attempt2-finalize-chain-invalid");
  if (target.resourceIdSha256 !== originalTarget.resourceIdSha256 || target.resourceCreatedAt !== originalTarget.resourceCreatedAt || target.displayName !== originalTarget.displayName || !sameChildHistory(presence.attempt1TargetChildEvidence, expectedChildHistory) || !sameChildHistory(target.attempt1TargetChildEvidence, presence.attempt1TargetChildEvidence) || !sameChildHistory(prepared.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || !sameChildHistory(preinvoke.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || !sameChildHistory(invocation.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || !sameChildHistory(immutableVerification.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence) || !sameChildHistory(receipt.attempt1TargetChildEvidence, target.attempt1TargetChildEvidence)) throw new Error("attempt2-finalize-child-history-invalid");
  for (const value of [target, prepared, preinvoke, invocation, immutableVerification, receipt]) if (value.freshAttempt2AuthoritativeChildGateEstablished !== true || value.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries") throw new Error("attempt2-finalize-fresh-child-gate-invalid");
  if (invocation.schemaVersion !== "eai.windows-portal-delete-attempt-2-invocation.v1" || invocation.attempt !== 2 || invocation.runId !== runId || invocation.appName !== appName || invocation.mutationState !== "invoked-dialog-closed-unverified" || invocation.armedBeforeDestructiveInput !== true || invocation.transportExitCode !== 0 || invocation.interactiveDesktopLaunchAttempted !== true || invocation.interactiveResultValidated !== true || invocation.exactDialogVerified !== true || invocation.exactTypedValueVerified !== true || invocation.exactDialogRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactButtonFocused !== true || invocation.scopedInvokePatternInvoked !== true || invocation.exactExpectedUser !== true || invocation.interactiveSessionProven !== true || !Number.isInteger(invocation.interactiveSessionId) || invocation.interactiveSessionId <= 0 || invocation.explorerSessionMatched !== true || invocation.explorerOwnerSidMatched !== true || invocation.edgeUiBoundToInteractiveSession !== true || invocation.edgeOwnerSidMatched !== true || !Number.isInteger(invocation.browserWindowHandle) || invocation.browserWindowHandle <= 0 || !Number.isInteger(invocation.browserProcessId) || invocation.browserProcessId <= 0 || invocation.browserProcessSessionId !== invocation.interactiveSessionId || !/^[a-f0-9]{64}$/.test(invocation.topLevelWindowRuntimeIdSha256 || "") || !/^[a-f0-9]{64}$/.test(invocation.dialogFinalRuntimeIdSha256 || "") || invocation.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactBrowserWindowForegroundAtInvoke !== true || invocation.confirmationDialogClosed !== true || invocation.dialogAbsentConsecutiveChecks < 12 || invocation.dialogClosureStableMilliseconds < 3000 || invocation.retryMutationAutomatically !== false) throw new Error("attempt2-finalize-invocation-invalid");
  if (immutableVerification.schemaVersion !== "eai.windows-portal-delete-attempt-2-verification.v1" || immutableVerification.attempt !== 2 || immutableVerification.runId !== runId || immutableVerification.appName !== appName || immutableVerification.attempt2InvocationReceiptSha256 !== hash(names[5]) || immutableVerification.attempt2TargetReceiptSha256 !== hash(names[2]) || immutableVerification.attempt2PreInvokeReceiptSha256 !== hash(names[4]) || immutableVerification.checks?.resourceApiExactMatchesAfter !== 0 || immutableVerification.checks?.cliExactMatchesAfter !== 0 || immutableVerification.verifiedAbsentOnResourceApiAndCli !== true || immutableVerification.portalVerificationRequired !== true) throw new Error("attempt2-finalize-verification-invalid");
  if (receipt.deletion?.invocationReceiptSha256 !== hash(names[5]) || receipt.deletion?.targetReceiptSha256 !== hash(names[2]) || receipt.deletion?.preInvokeReceiptSha256 !== hash(names[4])) throw new Error("attempt2-finalize-manual-receipt-invalid");
} else if (receipt.method === "admin-portal-interactive-delete-attempt-1") {
  const names = [
    "windows-portal-cleanup-target.json",
    "windows-portal-delete-prepared.json",
    "windows-portal-delete-invocation.json",
    "windows-portal-delete-attempt-1-verification.json",
  ];
  const raw = Object.fromEntries(names.map((name) => [name, safeBytes(name)]));
  chainParts.push(...names.map((name) => raw[name]));
  const read = (name) => JSON.parse(raw[name].toString("utf8"));
  const hash = (name) => hashBytes(raw[name]);
  const target = read(names[0]);
  const prepared = read(names[1]);
  const invocation = read(names[2]);
  const immutableVerification = read(names[3]);
  validateChildEvidence(target.preDeleteValidation);
  if ([target, prepared, invocation, immutableVerification].some((value) => value.tenantIdSha256 !== process.env.EAI_TENANT_HASH)) throw new Error("attempt1-finalize-tenant-mismatch");
  if (prepared.targetReceiptSha256 !== hash(names[0]) || invocation.targetReceiptSha256 !== hash(names[0]) || invocation.preparedReceiptSha256 !== hash(names[1])) throw new Error("attempt1-finalize-chain-invalid");
  if (invocation.mutationState !== "invoked-unverified" || invocation.transportExitCode !== 0 || invocation.interactiveDesktopLaunchAttempted !== true || invocation.interactiveResultValidated !== true || invocation.exactDialogVerified !== true || invocation.exactTypedValueVerified !== true || invocation.exactDialogRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactButtonFocused !== true || invocation.scopedInvokePatternInvoked !== true || invocation.exactExpectedUser !== true || invocation.interactiveSessionProven !== true || !Number.isInteger(invocation.interactiveSessionId) || invocation.interactiveSessionId <= 0 || invocation.explorerSessionMatched !== true || invocation.explorerOwnerSidMatched !== true || invocation.edgeUiBoundToInteractiveSession !== true || invocation.edgeOwnerSidMatched !== true || !Number.isInteger(invocation.browserWindowHandle) || invocation.browserWindowHandle <= 0 || !Number.isInteger(invocation.browserProcessId) || invocation.browserProcessId <= 0 || invocation.browserProcessSessionId !== invocation.interactiveSessionId || !/^[a-f0-9]{64}$/.test(invocation.topLevelWindowRuntimeIdSha256 || "") || !/^[a-f0-9]{64}$/.test(invocation.dialogFinalRuntimeIdSha256 || "") || invocation.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke !== true || invocation.exactBrowserWindowForegroundAtInvoke !== true || invocation.confirmationDialogClosed !== true || invocation.dialogAbsentConsecutiveChecks < 12 || invocation.dialogClosureStableMilliseconds < 3000 || invocation.retryMutationAutomatically !== false) throw new Error("attempt1-finalize-invocation-invalid");
  if (immutableVerification.schemaVersion !== "eai.windows-portal-delete-attempt-1-verification.v1" || immutableVerification.attempt !== 1 || immutableVerification.runId !== runId || immutableVerification.appName !== appName || immutableVerification.attempt1InvocationReceiptSha256 !== hash(names[2]) || immutableVerification.checks?.resourceApiExactMatchesAfter !== 0 || immutableVerification.checks?.cliExactMatchesAfter !== 0 || immutableVerification.verifiedAbsentOnResourceApiAndCli !== true || immutableVerification.portalVerificationRequired !== true) throw new Error("attempt1-finalize-verification-invalid");
  if (receipt.deletion?.invocationReceiptSha256 !== hash(names[2])) throw new Error("attempt1-finalize-manual-receipt-invalid");
} else if (String(receipt.method || "").startsWith("admin-portal")) {
  throw new Error("unsupported-portal-cleanup-method");
}
if (typeof receipt.displayName !== "string" || !receipt.displayName || /[\r\n]/.test(receipt.displayName)) throw new Error("display-name-invalid");
process.stdout.write(`${Buffer.from(receipt.displayName, "utf8").toString("base64")}\n${hashBytes(Buffer.concat(chainParts))}\n`);
NODE
  } 2>/dev/null)" || fail "Existing cleanup receipts do not prove exact two-channel absence."
  display_name="$(printf '%s\n' "$portal_values" | sed -n '1p' | /usr/bin/base64 --decode)"
  portal_chain_sha256="$(printf '%s\n' "$portal_values" | sed -n '2p')"
  [[ -n "$display_name" && "$portal_chain_sha256" =~ ^[a-f0-9]{64}$ ]] \
    || fail "The portal finalization chain could not be bound."
  compile_ocr
  assert_screenshot_sanitized "$screenshot" "$display_name" "No apps match"
  ocr_has "$screenshot" "All apps" || fail "The portal verification screenshot does not show All apps."
  screenshot_hash="$(/usr/bin/shasum -a 256 "$screenshot" | /usr/bin/awk '{print $1}')"
  EAI_RECEIPT="$receipt" EAI_VERIFICATION="$verification" EAI_VM_DIR="$vm_dir" \
  EAI_TENANT_HASH="$tenant_id_sha256" EAI_PORTAL_CHAIN_HASH="$portal_chain_sha256" \
  EAI_SCREENSHOT="$screenshot" EAI_SCREENSHOT_HASH="$screenshot_hash" \
    node "$ROOT/scripts/finalize-windows-portal-evidence.mjs"
  write_cleanup_index
  printf 'Windows diagnostic cleanup is verified absent across Resource API, CLI, and portal evidence.\n'
}

write_cleanup_index() {
  EAI_VM_DIR="$vm_dir" EAI_RUN_ID="$run_id" node --input-type=module <<'NODE'
import fs from "node:fs";
import path from "node:path";
const directory = process.env.EAI_VM_DIR;
const read = (name) => {
  try { return JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")); } catch { return null; }
};
const receipt = read("manual-cleanup-receipt.json");
const verification = read("manual-cleanup-verification.json");
const files = [
  "manual-v4-delete-attempt.json",
  "windows-cleanup-preflight.json",
  "manual-cleanup-child-gate.json",
  "windows-portal-cleanup-target.json",
  "windows-portal-delete-prepared.json",
  "windows-portal-delete-invocation.json",
  "windows-portal-delete-attempt-1-verification.json",
  "windows-portal-delete-attempt-1-still-present.json",
  "windows-portal-delete-attempt-2-target.json",
  "windows-portal-delete-attempt-2-prepared.json",
  "windows-portal-delete-attempt-2-preinvoke.json",
  "windows-portal-delete-attempt-2-invocation.json",
  "windows-portal-delete-attempt-2-verification.json",
  "windows-portal-delete-attempt-2-verification-pending.json",
  "manual-cleanup-target-row.png",
  "manual-delete-confirmation.png",
  "manual-cleanup-receipt.json",
  "manual-cleanup-verification.json",
  "manual-cleanup-verified-absent.png",
].filter((name) => fs.existsSync(path.join(directory, name)));
const index = {
  schemaVersion: "eai.windows-diagnostic-cleanup-index.v1",
  runId: process.env.EAI_RUN_ID,
  platform: "windows",
  files,
  resourceApiVerifiedAbsent: verification?.checks?.resourceApiExactMatchesAfter === 0,
  cliVerifiedAbsent: verification?.checks?.cliExactMatchesAfter === 0,
  portalVerifiedAbsent: verification?.checks?.portalExactMatchesAfter === 0,
  cleanupVerified: receipt?.cleanupVerified === true && verification?.cleanupVerified === true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
fs.writeFileSync(path.join(directory, "windows-cleanup-evidence-index.json"), `${JSON.stringify(index, null, 2)}\n`, { mode: 0o600 });
NODE
}

if [[ "$mode" == finalize-portal ]]; then
  finalize_portal
  exit 0
fi

[[ -n "$prlctl_bin" && -x "$prlctl_bin" ]] || fail "prlctl is unavailable."
[[ -x "$login_command" ]] || fail "The Windows protected-login command is unavailable."
[[ -f "$ps_helper" && ! -L "$ps_helper" ]] || fail "The Windows cleanup PowerShell helper is missing or unsafe."
status_output="$($prlctl_bin status "$vm_name" 2>/dev/null || true)"
[[ "$status_output" == *running* ]] || fail "The exact Windows VM must still be running; do not restore it before cleanup."

fresh_auth_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EAI_WINDOWS_VM_NAME="$vm_name" EAI_HARNESS_USER_EMAIL="$test_email" \
EAI_HARNESS_TENANT_ID="$tenant_id" EAI_HARNESS_TENANT_NAME="$tenant_name" \
  "$login_command" --portal-only >/dev/null \
  || fail "Fresh protected Windows portal authentication failed."
EAI_WINDOWS_VM_NAME="$vm_name" EAI_HARNESS_USER_EMAIL="$test_email" \
EAI_HARNESS_TENANT_ID="$tenant_id" EAI_HARNESS_TENANT_NAME="$tenant_name" \
  "$login_command" --cli-only >/dev/null \
  || fail "Fresh protected Windows CLI authentication failed."

guest_mode="Cleanup"
if [[ "$mode" == verify ]]; then
  guest_mode="VerifyOnly"
elif [[ -f "$vm_dir/manual-cleanup-receipt.json" ]]; then
  if jq -e --arg run "$run_id" --arg app "$app_key" \
    '.runId == $run and .appName == $app and .deleted == true' \
    "$vm_dir/manual-cleanup-receipt.json" >/dev/null 2>&1; then
    guest_mode="VerifyOnly"
  fi
fi

if [[ "$guest_mode" == Cleanup && -f "$vm_dir/windows-cleanup-transport-uncertain.json" ]]; then
  fail "A previous cleanup transport was uncertain. Run --verify-only before considering another mutation."
fi
if [[ "$guest_mode" == Cleanup && -f "$vm_dir/windows-portal-delete-invocation.json" ]]; then
  fail "A portal permanent-delete invocation is already recorded. Run --verify-only; never start a second cleanup mutation."
fi
if [[ "$guest_mode" == Cleanup && -f "$vm_dir/windows-portal-delete-prepared.json" ]]; then
  fail "A portal permanent-delete dialog is already prepared. Finish or discard that exact UI workflow before choosing another cleanup method."
fi

gate_base64=""
gate_file="$vm_dir/manual-cleanup-child-gate.json"
if [[ "$guest_mode" == Cleanup && -f "$gate_file" ]]; then
  [[ ! -L "$gate_file" ]] || fail "The fallback gate must not be a symlink."
  preflight_file="$vm_dir/windows-cleanup-preflight.json"
  [[ -f "$preflight_file" && ! -L "$preflight_file" ]] || fail "The fallback gate has no matching cleanup preflight."
  gate_values="$({
    node --input-type=module - "$gate_file" "$preflight_file" "$run_id" "$app_key" <<'NODE'
import fs from "node:fs";
const [gatePath, preflightPath, runId, appName] = process.argv.slice(2);
const gate = JSON.parse(fs.readFileSync(gatePath, "utf8"));
const preflight = JSON.parse(fs.readFileSync(preflightPath, "utf8"));
const expected = {
  runId,
  appName,
  platform: "windows",
  resourceIdSha256: preflight.resourceIdSha256,
  displayName: preflight.displayName,
};
if (gate.schemaVersion !== "eai.windows-diagnostic-cleanup-child-gate.v1") throw new Error("gate-schema");
for (const [key, value] of Object.entries(expected)) if (gate[key] !== value) throw new Error(`gate-${key}`);
if (gate.enrollmentExactMatches !== 1 || gate.createdDuringThisRun !== true || gate.exactDisplayNameVerified !== true || gate.typedConfirmation !== true) throw new Error("gate-exactness");
for (const field of ["servicesBeforeDeletion", "workflowExactMatchesBeforeDeletion", "setupExactMatchesBeforeDeletion"]) if (gate[field] !== 0) throw new Error(`gate-${field}`);
if (gate.zeroChildAssertionSource !== "manual-approved-admin-interface-and-exact-resource-queries" || gate.sanitized !== true || gate.diagnostic !== true) throw new Error("gate-marking");
for (const item of [gate.targetRowScreenshot, gate.confirmationScreenshot]) {
  if (!item || typeof item.path !== "string" || !/^[a-z0-9-]+[.]png$/.test(item.path) || !/^[0-9a-f]{64}$/.test(item.sha256 || "") || item.sanitized !== true) throw new Error("gate-screenshot");
}
process.stdout.write(JSON.stringify({
  displayName: gate.displayName,
  targetPath: gate.targetRowScreenshot.path,
  targetSha256: gate.targetRowScreenshot.sha256,
  confirmationPath: gate.confirmationScreenshot.path,
  confirmationSha256: gate.confirmationScreenshot.sha256,
}));
NODE
  } 2>/dev/null)" || fail "The manual fallback gate does not match the exact run target."
  display_name="$(printf '%s' "$gate_values" | jq -er '.displayName')"
  target_name="$(printf '%s' "$gate_values" | jq -er '.targetPath')"
  confirmation_name="$(printf '%s' "$gate_values" | jq -er '.confirmationPath')"
  target_path="$vm_dir/$target_name"
  confirmation_path="$vm_dir/$confirmation_name"
  [[ "$(/usr/bin/shasum -a 256 "$target_path" 2>/dev/null | /usr/bin/awk '{print $1}')" == "$(printf '%s' "$gate_values" | jq -er '.targetSha256')" ]] \
    || fail "The exact target-row screenshot hash does not match the fallback gate."
  [[ "$(/usr/bin/shasum -a 256 "$confirmation_path" 2>/dev/null | /usr/bin/awk '{print $1}')" == "$(printf '%s' "$gate_values" | jq -er '.confirmationSha256')" ]] \
    || fail "The exact typed-confirmation screenshot hash does not match the fallback gate."
  compile_ocr
  assert_screenshot_sanitized "$target_path" "$display_name" "No services"
  assert_screenshot_sanitized "$confirmation_path" "$app_key" "Delete permanently"
  gate_base64="$(/usr/bin/base64 <"$gate_file" | /usr/bin/tr -d '\n')"
fi

mode_base64="$(printf '%s' "$guest_mode" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
app_base64="$(printf '%s' "$app_key" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
tenant_base64="$(printf '%s' "$tenant_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
run_base64="$(printf '%s' "$run_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
gate_payload_base64="$(printf '%s' "$gate_base64" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
guest_user_base64="$(printf '%s' "$guest_user" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
raw_stdout="$work_dir/guest.stdout"
raw_stderr="$work_dir/guest.stderr"
set +e
{
  printf '& {\n'
  /bin/cat "$ps_helper"
  printf '\n} -CleanupInputBase64 @("%s", "%s", "%s", "%s", "%s", "%s")\n\n' \
    "$mode_base64" "$app_base64" "$tenant_base64" "$run_base64" "$gate_payload_base64" "$guest_user_base64"
} | run_hidden_cleanup_ps >"$raw_stdout" 2>"$raw_stderr"
transport_status=$?
set -e
tenant_id=""
gate_base64=""
tenant_base64=""
gate_payload_base64=""
guest_user_base64=""

guest_result="$work_dir/guest-result.json"
if ! node --input-type=module - "$raw_stdout" "$guest_result" "$run_id" "$app_key" <<'NODE'
import fs from "node:fs";
const [source, destination, runId, appName] = process.argv.slice(2);
const lines = fs.readFileSync(source, "utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).reverse();
let value = null;
for (const line of lines) {
  try {
    const candidate = JSON.parse(line);
    if (candidate?.schemaVersion === "eai.windows-diagnostic-cleanup.v1") { value = candidate; break; }
  } catch {}
}
if (!value || value.runId !== runId || value.appName !== appName || value.platform !== "windows" || value.sanitized !== true || value.diagnostic !== true || value.productionGate !== false) process.exit(1);
const forbiddenKeys = /tenant(?:id|name)?|email|password|token|secret|authorization|resourceId$/i;
const walk = (node) => {
  if (Array.isArray(node)) return node.forEach(walk);
  if (!node || typeof node !== "object") return;
  for (const [key, child] of Object.entries(node)) {
    if (forbiddenKeys.test(key)) throw new Error("protected-key-in-result");
    walk(child);
  }
};
walk(value);
fs.writeFileSync(destination, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
NODE
then
  if [[ "$guest_mode" == Cleanup ]]; then
    EAI_UNCERTAIN_FILE="$vm_dir/windows-cleanup-transport-uncertain.json" EAI_RUN_ID="$run_id" \
    EAI_APP_KEY="$app_key" EAI_TRANSPORT_STATUS="$transport_status" node --input-type=module <<'NODE'
import fs from "node:fs";
fs.writeFileSync(process.env.EAI_UNCERTAIN_FILE, `${JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup-transport.v1",
  runId: process.env.EAI_RUN_ID,
  platform: "windows",
  appName: process.env.EAI_APP_KEY,
  mutationState: "uncertain",
  transportExitCode: Number(process.env.EAI_TRANSPORT_STATUS),
  retryMutationAutomatically: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}, null, 2)}\n`, { mode: 0o600 });
NODE
  fi
  fail "The guest cleanup transport returned no valid sanitized result; mutation state is treated as uncertain."
fi

write_json_from_result "$guest_result"
write_cleanup_index
action="$(jq -er '.action' "$guest_result")"

if [[ "$action" == mutation-uncertain ]]; then
  EAI_UNCERTAIN_FILE="$vm_dir/windows-cleanup-transport-uncertain.json" EAI_RUN_ID="$run_id" \
  EAI_APP_KEY="$app_key" EAI_ERROR_CODE="$(jq -er '.errorCode // "guest-cleanup-failed"' "$guest_result")" \
    node --input-type=module <<'NODE'
import fs from "node:fs";
fs.writeFileSync(process.env.EAI_UNCERTAIN_FILE, `${JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup-transport.v1",
  runId: process.env.EAI_RUN_ID,
  platform: "windows",
  appName: process.env.EAI_APP_KEY,
  mutationState: "uncertain",
  errorCode: process.env.EAI_ERROR_CODE,
  retryMutationAutomatically: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}, null, 2)}\n`, { mode: 0o600 });
NODE
fi

case "$action" in
  fallback-gate-required)
    printf 'V4 cleanup reached the one allowed diagnostic failure. No deletion occurred.\n' >&2
    printf 'Capture the exact target row and typed confirmation, verify zero services/workflows/setup, then run scripts/write-windows-diagnostic-cleanup-gate.mjs before retrying.\n' >&2
    exit 3
    ;;
  deleted-v4|deleted-fallback)
    if ! jq -e '.absence.verified == true and .absence.resourceApiExactMatchesAfter == 0 and .absence.cliExactMatchesAfter == 0' "$guest_result" >/dev/null; then
      fail "Deletion occurred, but Resource API and CLI absence were not both verified. Run --verify-only; do not retry deletion."
    fi
    printf 'Windows app deletion and two-channel absence are verified. Portal delete UI remains unautomated.\n' >&2
    printf 'In the still-authenticated portal, search the exact display name, save a sanitized manual-cleanup-verified-absent.png, then run --finalize-portal.\n' >&2
    exit 3
    ;;
  verify-only)
    if jq -e '.absence.verified == true and .absence.resourceApiExactMatchesAfter == 0 and .absence.cliExactMatchesAfter == 0' "$guest_result" >/dev/null; then
      printf 'Resource API and CLI both report the exact Windows app absent; portal verification is still required.\n'
      exit 3
    fi
    fail "The exact Windows app is still discoverable or absence could not be verified."
    ;;
  v4-failed-not-eligible-for-fallback)
    fail "V4 deletion failed outside the one documented fallback condition; no fallback was attempted."
    ;;
  failed)
    error_code="$(jq -er '.errorCode // "guest-cleanup-failed"' "$guest_result")"
    fail "The guest cleanup failed closed ($error_code)."
    ;;
  mutation-uncertain)
    fail "The guest reported an uncertain mutation outcome. Run --verify-only; never retry deletion automatically."
    ;;
  *)
    fail "The guest cleanup returned an unsupported state."
    ;;
esac
