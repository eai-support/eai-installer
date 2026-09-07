#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_root="$ROOT/artifacts/release-e2e"
vm_name="${EAI_WINDOWS_VM_NAME:-Windows 11}"
guest_user="${EAI_WINDOWS_GUEST_USER:-eai-douglasross}"
prlctl_bin="${EAI_WINDOWS_PORTAL_PRLCTL_BIN:-$(command -v prlctl 2>/dev/null || true)}"
login_command="${EAI_WINDOWS_PORTAL_LOGIN_COMMAND:-$ROOT/scripts/login-windows-guest.sh}"
input_command="${EAI_WINDOWS_PORTAL_INPUT_COMMAND:-}"
input_helper="$ROOT/scripts/parallels-input.mjs"
ui_helper="$ROOT/scripts/windows-ui-action.ps1"
interactive_delete_helper="$ROOT/scripts/windows-interactive-exact-delete.ps1"
target_helper="$ROOT/scripts/windows-diagnostic-cleanup.ps1"
keychain_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
tenant_id_service="${EAI_TENANT_ID_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-id}"
tenant_name_service="${EAI_TENANT_NAME_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-name}"
keychain_account="${EAI_TENANT_KEYCHAIN_ACCOUNT:-release-e2e}"
approved_apps_url="https://admin-portal.myenterprise.ai/platform/apps"
mode=""
confirmation_nonce=""
run_dir_input=""
work_dir="$(mktemp -d)"
attempt2_lock_dir=""
attempt2_lock_owned=0

# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() {
  if [[ "${attempt2_lock_owned:-0}" == 1 && -n "${attempt2_lock_dir:-}" ]]; then
    /bin/rmdir -- "$attempt2_lock_dir" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$work_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'Windows portal cleanup UI failed: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/run-windows-portal-cleanup-ui.sh --run-dir <release-e2e-run> --prepare-delete
  scripts/run-windows-portal-cleanup-ui.sh --run-dir <release-e2e-run> --invoke-delete-permanently
  scripts/run-windows-portal-cleanup-ui.sh --run-dir <release-e2e-run> --prepare-delete-attempt-2
  scripts/run-windows-portal-cleanup-ui.sh --run-dir <release-e2e-run> --invoke-delete-attempt-2 --confirmation-nonce <64-hex>

The prepare phase reads the exact app key only from matching run receipts,
performs a fresh protected portal/CLI login, records a read-only exact target
receipt, navigates the Admin Portal, and types the exact confirmation key. It
does not invoke Delete permanently. The final action is deliberately separate
so the caller can obtain confirmation immediately before the mutation.

The attempt-2 modes are a hard-coded, one-time recovery path. They are eligible
only after one successful-but-unverified attempt-1 invocation and a later
successful two-channel 1/1 still-present result. There is no generic attempt
number and no attempt-3 path.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --run-dir)
      [[ "$#" -ge 2 && -z "$run_dir_input" ]] || fail "--run-dir requires one value."
      run_dir_input="$2"
      shift 2
      ;;
    --prepare-delete)
      [[ -z "$mode" ]] || fail "Choose only one portal cleanup mode."
      mode="prepare"
      shift
      ;;
    --invoke-delete-permanently)
      [[ -z "$mode" ]] || fail "Choose only one portal cleanup mode."
      mode="invoke"
      shift
      ;;
    --prepare-delete-attempt-2)
      [[ -z "$mode" ]] || fail "Choose only one portal cleanup mode."
      mode="prepare-attempt-2"
      shift
      ;;
    --invoke-delete-attempt-2)
      [[ -z "$mode" ]] || fail "Choose only one portal cleanup mode."
      mode="invoke-attempt-2"
      shift
      ;;
    --confirmation-nonce)
      [[ "$#" -ge 2 && -z "$confirmation_nonce" ]] || fail "--confirmation-nonce requires one value."
      confirmation_nonce="$2"
      shift 2
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
[[ -n "$mode" ]] || fail "Choose one documented portal cleanup mode."
if [[ "$mode" == invoke-attempt-2 ]]; then
  [[ "$confirmation_nonce" =~ ^[a-f0-9]{64}$ ]] \
    || fail "Attempt 2 requires one exact 64-hex --confirmation-nonce from its current preparation."
else
  [[ -z "$confirmation_nonce" ]] || fail "--confirmation-nonce is accepted only by --invoke-delete-attempt-2."
fi
[[ "$guest_user" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The expected Windows guest user is invalid."
[[ -d "$run_dir_input" && ! -L "$run_dir_input" ]] || fail "The run directory must be a real directory, not a symlink."
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
[[ -d "$vm_dir" && ! -L "$vm_dir" ]] || fail "The Windows evidence directory is missing or unsafe."

report_file="$run_dir/release-e2e.json"
state_file="$vm_dir/app-state.json"
result_file="$vm_dir/vm-result.json"
for required_file in "$report_file" "$state_file" "$result_file"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] || fail "Required Windows run evidence is missing or unsafe."
done

# A failed controller run remains eligible only when every independent receipt
# identifies the same run-derived app and says cleanup is still required. The
# failed status never relaxes app identity, provenance, or later child checks.
app_key="$({
  node --input-type=module - "$report_file" "$state_file" "$result_file" "$run_id" <<'NODE'
import fs from "node:fs";
const [reportPath, statePath, resultPath, runId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
const expected = `test-windows-${runId}`;
if (report.runId !== runId || !["passed", "passed_with_mock_cleanup", "failed"].includes(report.status)) throw new Error("report-status");
const machines = Array.isArray(report.machines) ? report.machines.filter((machine) => machine?.vm === "windows") : [];
if (machines.length !== 1) throw new Error("machine-count");
const machine = machines[0];
if (!["passed", "failed"].includes(machine.status) || machine.appName !== expected || machine.appCreated !== true || machine.cleanupVerified === true) throw new Error("machine-target");
if (report.status === "failed" && machine.status !== "failed") throw new Error("failed-status-mismatch");
if (state.appName !== expected || state.appCreated !== true || state.cleanupRequired !== true || state.cleanupRequested !== true) throw new Error("state-target");
if (!["passed", "failed"].includes(result.status) || result.vm !== "windows" || result.appName !== expected || result.appCreated !== true || result.cleanupRequested !== true || result.checks?.app !== "passed") throw new Error("result-target");
if (!/^test-windows-[0-9]{13}-[0-9a-f]{6}$/.test(expected) || expected.length > 128) throw new Error("app-key");
process.stdout.write(expected);
NODE
} 2>/dev/null)" || fail "The run receipts do not identify one exact Windows app that still requires cleanup."
[[ "$app_key" == "test-windows-$run_id" ]] || fail "The validated app key is not bound to this run."

target_receipt="$vm_dir/windows-portal-cleanup-target.json"
prepared_receipt="$vm_dir/windows-portal-delete-prepared.json"
invocation_receipt="$vm_dir/windows-portal-delete-invocation.json"
attempt1_present_receipt="$vm_dir/windows-portal-delete-attempt-1-still-present.json"
attempt2_target_receipt="$vm_dir/windows-portal-delete-attempt-2-target.json"
attempt2_prepared_receipt="$vm_dir/windows-portal-delete-attempt-2-prepared.json"
attempt2_preinvoke_receipt="$vm_dir/windows-portal-delete-attempt-2-preinvoke.json"
attempt2_invocation_receipt="$vm_dir/windows-portal-delete-attempt-2-invocation.json"
verification_only_receipt="$vm_dir/windows-cleanup-verification-only.json"
if [[ "$mode" == prepare && -e "$invocation_receipt" ]]; then
  fail "A permanent-delete invocation is already recorded; verify exact absence instead of preparing another invocation."
fi
if [[ "$mode" == prepare-attempt-2 && -e "$attempt2_invocation_receipt" ]]; then
  fail "Attempt 2 is already armed or invoked; verify exact absence and never prepare another deletion."
fi
if [[ "$mode" == prepare-attempt-2 || "$mode" == invoke-attempt-2 ]]; then
  attempt2_lock_dir="$vm_dir/.windows-portal-delete-attempt-2.lock"
  if ! /bin/mkdir -- "$attempt2_lock_dir" 2>/dev/null; then
    fail "The exclusive attempt-2 lock already exists. Do not remove it automatically; inspect the run and resolve a stale lock manually."
  fi
  attempt2_lock_owned=1
  # Re-check after acquiring the lock. Another process may have armed the
  # one-shot attempt between the initial mode check and lock acquisition.
  [[ ! -e "$attempt2_invocation_receipt" ]] \
    || fail "Attempt 2 is already armed or invoked; verify exact absence and never replay it."
fi

[[ -n "$prlctl_bin" && -x "$prlctl_bin" ]] || fail "prlctl is unavailable."
[[ -f "$ui_helper" && ! -L "$ui_helper" ]] || fail "The Windows UI Automation helper is missing or unsafe."
[[ -f "$interactive_delete_helper" && ! -L "$interactive_delete_helper" ]] \
  || fail "The Windows interactive deletion helper is missing or unsafe."
[[ -f "$target_helper" && ! -L "$target_helper" ]] || fail "The Windows read-only target helper is missing or unsafe."
ui_helper_sha256="$(/usr/bin/shasum -a 256 "$ui_helper" | /usr/bin/awk '{print $1}')"
interactive_delete_helper_sha256="$(/usr/bin/shasum -a 256 "$interactive_delete_helper" | /usr/bin/awk '{print $1}')"
[[ "$ui_helper_sha256" =~ ^[a-f0-9]{64}$ && "$interactive_delete_helper_sha256" =~ ^[a-f0-9]{64}$ ]] \
  || fail "The Windows interactive worker hashes could not be calculated."
if [[ -n "$input_command" ]]; then
  [[ -x "$input_command" ]] || fail "The configured Parallels input command is unavailable."
else
  command -v node >/dev/null 2>&1 || fail "Node.js is unavailable."
  [[ -f "$input_helper" && ! -L "$input_helper" ]] || fail "The Parallels input helper is missing or unsafe."
fi

status_output="$($prlctl_bin status "$vm_name" 2>/dev/null || true)"
[[ "$status_output" == *running* ]] || fail "The exact Windows VM must already be running."
unset status_output

input() {
  if [[ -n "$input_command" ]]; then
    "$input_command" --vm "$vm_name" "$@"
  else
    node "$input_helper" --vm "$vm_name" "$@"
  fi
}

is_exact_transport_failure() {
  local normalized=""
  normalized="$(printf '%s' "$1" | /usr/bin/tr -d '\r')"
  case "$normalized" in
    'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.'|\
    'PrlJob_GetResult: Invalid argument. An invalid argument was passed.'|\
    'PrlVmGuest_RunProgram: Invalid argument'|\
    'PrlVmGuest_RunProgram: Unable to open new session in this virtual machine. Make sure your virtual machine has finished booting, runs the latest version of Parallels Tools, and is not isolated from the host OS.')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_target_query_once() {
  local mode_base64="$1"
  local app_base64="$2"
  local tenant_base64="$3"
  local run_base64="$4"
  local user_base64="$5"
  local stdout_file="$6"
  local stderr_file="$7"
  {
    printf '& {\n'
    /bin/cat "$target_helper"
    printf '\n} -CleanupInputBase64 @("%s", "%s", "%s", "%s", "", "%s")\n\n' \
      "$mode_base64" "$app_base64" "$tenant_base64" "$run_base64" "$user_base64"
  } | "$prlctl_bin" exec "$vm_name" --current-user powershell.exe \
        -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass \
        -InputFormat Text -OutputFormat Text -Command - \
        >"$stdout_file" 2>"$stderr_file"
}

run_interactive_worker_query_once() {
  local operation="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local ui_payload=""
  local runner_payload=""
  [[ "$operation" == stage || "$operation" == verify ]] || return 2
  if [[ "$operation" == stage ]]; then
    ui_payload="$(/usr/bin/base64 <"$ui_helper" | /usr/bin/tr -d '\n')"
    runner_payload="$(/usr/bin/base64 <"$interactive_delete_helper" | /usr/bin/tr -d '\n')"
  fi
  {
    printf "\$ErrorActionPreference = \"Stop\"\n"
    printf "\$operation = \"%s\"\n" "$operation"
    printf "\$runId = \"%s\"\n" "$run_id"
    printf "\$expectedUser = \"%s\"\n" "$guest_user"
    printf "\$expectedUiSha256 = \"%s\"\n" "$ui_helper_sha256"
    printf "\$expectedRunnerSha256 = \"%s\"\n" "$interactive_delete_helper_sha256"
    printf "\$uiPayload = \"%s\"\n" "$ui_payload"
    printf "\$runnerPayload = \"%s\"\n" "$runner_payload"
    /bin/cat <<'POWERSHELL'
function Assert-Condition([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw $Code }
}
function Assert-RealDirectory([string]$Path, [string]$Code) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    Assert-Condition ($item.PSIsContainer) "$Code-not-directory"
    Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "$Code-reparse-point"
    Assert-Condition ([string]::Equals(
        $item.FullName,
        [IO.Path]::GetFullPath($Path),
        [StringComparison]::OrdinalIgnoreCase
    )) "$Code-resolved-elsewhere"
}
function Assert-ExactWorkerFile([string]$Path, [string]$ExpectedSha256, [string]$Code) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    Assert-Condition (-not $item.PSIsContainer) "$Code-not-file"
    Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "$Code-reparse-point"
    $actualSha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition ($actualSha256 -ceq $ExpectedSha256) "$Code-hash-mismatch"
}
function Install-ExactWorkerFile(
    [string]$Path,
    [string]$Payload,
    [string]$ExpectedSha256,
    [string]$Code
) {
    $bytes = [Convert]::FromBase64String($Payload)
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllBytes($temporary, $bytes)
    try {
        Assert-ExactWorkerFile -Path $temporary -ExpectedSha256 $ExpectedSha256 -Code "$Code-temporary"
        if (Test-Path -LiteralPath $Path) {
            $existing = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            Assert-Condition (-not $existing.PSIsContainer) "$Code-existing-not-file"
            Assert-Condition (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "$Code-existing-reparse-point"
            Remove-Item -LiteralPath $existing.FullName -Force
        }
        [IO.File]::Move($temporary, $Path)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Assert-ExactWorkerFile -Path $Path -ExpectedSha256 $ExpectedSha256 -Code $Code
}

Assert-Condition ($operation -in @('stage', 'verify')) 'worker-operation-invalid'
Assert-Condition ($runId -match '^[0-9]{13}-[0-9a-f]{6}$') 'worker-run-id-invalid'
Assert-Condition ($expectedUser -match '^[A-Za-z0-9._-]{1,64}$') 'worker-user-invalid'
Assert-Condition ($expectedUiSha256 -match '^[a-f0-9]{64}$') 'worker-ui-hash-invalid'
Assert-Condition ($expectedRunnerSha256 -match '^[a-f0-9]{64}$') 'worker-runner-hash-invalid'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
Assert-Condition ($null -ne $identity -and -not $identity.IsSystem) 'worker-current-user-system'
$actualUser = ([string]$identity.Name -split '\\')[-1]
Assert-Condition ([string]::Equals($actualUser, $expectedUser, [StringComparison]::OrdinalIgnoreCase)) 'worker-current-user-mismatch'
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
Assert-RealDirectory -Path $localAppData -Code 'worker-local-app-data'
$workerRoot = Join-Path $localAppData 'EAIReleaseE2E'
$portalRoot = Join-Path $workerRoot 'PortalDelete'
$workerDirectory = Join-Path $portalRoot $runId
if ($operation -ceq 'stage') {
    Assert-Condition (-not [string]::IsNullOrEmpty($uiPayload)) 'worker-ui-payload-missing'
    Assert-Condition (-not [string]::IsNullOrEmpty($runnerPayload)) 'worker-runner-payload-missing'
    foreach ($directory in @($workerRoot, $portalRoot, $workerDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            [void][IO.Directory]::CreateDirectory($directory)
        }
        Assert-RealDirectory -Path $directory -Code 'worker-directory'
    }
    Install-ExactWorkerFile -Path (Join-Path $workerDirectory 'windows-ui-action.ps1') `
        -Payload $uiPayload -ExpectedSha256 $expectedUiSha256 -Code 'worker-ui-helper'
    Install-ExactWorkerFile -Path (Join-Path $workerDirectory 'windows-interactive-exact-delete.ps1') `
        -Payload $runnerPayload -ExpectedSha256 $expectedRunnerSha256 -Code 'worker-runner'
} else {
    Assert-RealDirectory -Path $workerRoot -Code 'worker-root'
    Assert-RealDirectory -Path $portalRoot -Code 'worker-portal-root'
    Assert-RealDirectory -Path $workerDirectory -Code 'worker-run-directory'
    Assert-ExactWorkerFile -Path (Join-Path $workerDirectory 'windows-ui-action.ps1') `
        -ExpectedSha256 $expectedUiSha256 -Code 'worker-ui-helper'
    Assert-ExactWorkerFile -Path (Join-Path $workerDirectory 'windows-interactive-exact-delete.ps1') `
        -ExpectedSha256 $expectedRunnerSha256 -Code 'worker-runner'
}
[ordered]@{
    schemaVersion = 'eai.windows-interactive-delete-worker.v1'
    operation = $operation
    runId = $runId
    uiHelperSha256 = $expectedUiSha256
    runnerSha256 = $expectedRunnerSha256
    exactCurrentUser = $true
    realRunDirectory = $true
    verified = $true
    sanitized = $true
    diagnostic = $true
    productionGate = $false
} | ConvertTo-Json -Compress
POWERSHELL
    printf '\n'
  } | "$prlctl_bin" exec "$vm_name" --current-user powershell.exe \
        -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass \
        -InputFormat Text -OutputFormat Text -Command - \
        >"$stdout_file" 2>"$stderr_file"
}

validate_interactive_worker_output() {
  local raw_file="$1"
  local expected_operation="$2"
  EAI_WORKER_RAW="$raw_file" EAI_WORKER_OPERATION="$expected_operation" \
  EAI_RUN_ID="$run_id" EAI_UI_HASH="$ui_helper_sha256" \
  EAI_RUNNER_HASH="$interactive_delete_helper_sha256" node --input-type=module <<'NODE'
import fs from "node:fs";
const lines = fs.readFileSync(process.env.EAI_WORKER_RAW, "utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).reverse();
let result = null;
for (const line of lines) {
  try {
    const value = JSON.parse(line);
    if (value?.schemaVersion === "eai.windows-interactive-delete-worker.v1") { result = value; break; }
  } catch {}
}
if (!result || result.operation !== process.env.EAI_WORKER_OPERATION || result.runId !== process.env.EAI_RUN_ID) process.exit(1);
if (result.uiHelperSha256 !== process.env.EAI_UI_HASH || result.runnerSha256 !== process.env.EAI_RUNNER_HASH) process.exit(1);
if (result.exactCurrentUser !== true || result.realRunDirectory !== true || result.verified !== true) process.exit(1);
if (result.sanitized !== true || result.diagnostic !== true || result.productionGate !== false) process.exit(1);
NODE
}

run_interactive_worker_operation() {
  local operation="$1"
  local stdout_file="$work_dir/worker-$operation.stdout"
  local stderr_file="$work_dir/worker-$operation.stderr"
  local worker_status=1
  local worker_output=""
  local attempt
  for attempt in $(seq 1 3); do
    : >"$stdout_file"
    : >"$stderr_file"
    set +e
    run_interactive_worker_query_once "$operation" "$stdout_file" "$stderr_file"
    worker_status=$?
    set -e
    worker_output="$(/bin/cat "$stdout_file" "$stderr_file")"
    if [[ "$worker_status" == 0 ]] && validate_interactive_worker_output "$stdout_file" "$operation"; then
      return 0
    fi
    if [[ "$operation" == verify && "$worker_status" == 255 ]] \
      && is_exact_transport_failure "$worker_output" \
      && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    return 1
  done
  return 1
}

read_interactive_delete_result_once() {
  local invocation_id="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  {
    printf "\$ErrorActionPreference = \"Stop\"\n"
    printf "\$runId = \"%s\"\n" "$run_id"
    printf "\$invocationId = \"%s\"\n" "$invocation_id"
    /bin/cat <<'POWERSHELL'
if ($runId -notmatch '^[0-9]{13}-[0-9a-f]{6}$' -or
    $invocationId -notmatch '^[a-f0-9]{32}$') {
    throw 'interactive-result-target-invalid'
}
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$workerDirectory = Join-Path (Join-Path (Join-Path $localAppData 'EAIReleaseE2E') 'PortalDelete') $runId
$resultPath = Join-Path $workerDirectory "windows-interactive-exact-delete-result-$invocationId.json"
if (-not (Test-Path -LiteralPath $resultPath)) {
    [Console]::Out.WriteLine('EAI_INTERACTIVE_DELETE_RESULT_PENDING')
    exit 3
}
$item = Get-Item -LiteralPath $resultPath -Force -ErrorAction Stop
if ($item.PSIsContainer -or
    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    -not [string]::Equals($item.FullName, [IO.Path]::GetFullPath($resultPath), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'interactive-result-file-unsafe'
}
[Console]::Out.WriteLine((Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop).Trim())
POWERSHELL
    printf '\n'
  } | "$prlctl_bin" exec "$vm_name" --current-user powershell.exe \
        -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass \
        -InputFormat Text -OutputFormat Text -Command - \
        >"$stdout_file" 2>"$stderr_file"
}

run_interactive_delete_once() {
  local stdout_file="$work_dir/interactive-result.stdout"
  local stderr_file="$work_dir/interactive-result.stderr"
  local launch_command=""
  local result_status=1
  local result_output=""
  local deadline=0
  local expected_guest_user_base64=""
  interactive_output=""
  interactive_transport_status=1
  interactive_launch_attempted=0
  if [[ -z "${interactive_invocation_id:-}" ]]; then
    interactive_invocation_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '-')"
  fi
  [[ "$interactive_invocation_id" =~ ^[a-f0-9]{32}$ ]] || return 2
  expected_guest_user_base64="$(printf '%s' "$guest_user" | /usr/bin/base64 | /usr/bin/tr -d '\n')"

  launch_command="powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%LOCALAPPDATA%\\EAIReleaseE2E\\PortalDelete\\$run_id\\windows-interactive-exact-delete.ps1\" -AppKeyBase64 \"$app_base64\" -DisplayNameBase64 \"$display_base64\" -ExpectedGuestUserBase64 \"$expected_guest_user_base64\" -UiHelperSha256 \"$ui_helper_sha256\" -RunnerSha256 \"$interactive_delete_helper_sha256\" -InvocationId \"$interactive_invocation_id\""

  # Windows+R is injected directly into the VM's logged-in desktop. The
  # destructive worker itself validates the exact dialog, focuses the exact
  # button, invokes its scoped UI Automation InvokePattern once, and observes
  # sustained dialog closure. None of
  # these input operations may be replayed after an ambiguous result.
  interactive_launch_attempted=1
  input combo command+r || return 2
  sleep 1
  printf '%s' "$launch_command" | input type --stdin || return 2
  input key enter || return 2

  deadline=$((SECONDS + 40))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    : >"$stdout_file"
    : >"$stderr_file"
    set +e
    read_interactive_delete_result_once "$interactive_invocation_id" "$stdout_file" "$stderr_file"
    result_status=$?
    set -e
    result_output="$(/bin/cat "$stdout_file" "$stderr_file")"
    if [[ "$result_status" == 0 ]]; then
      interactive_output="$(/bin/cat "$stdout_file")"
      interactive_transport_status=0
      return 0
    fi
    if [[ "$result_status" == 3 ]] \
      && printf '%s\n' "$result_output" | /usr/bin/tr -d '\r' \
        | /usr/bin/grep -Fqx 'EAI_INTERACTIVE_DELETE_RESULT_PENDING'; then
      sleep 0.5
      continue
    fi
    if [[ "$result_status" == 255 ]] && is_exact_transport_failure "$result_output"; then
      sleep 0.5
      continue
    fi
    interactive_transport_status="$result_status"
    return 1
  done
  interactive_transport_status=124
  return 1
}

validate_interactive_delete_result() {
  local raw_file="$1"
  local normalized_file="$2"
  EAI_INTERACTIVE_RAW="$raw_file" EAI_INTERACTIVE_NORMALIZED="$normalized_file" \
  EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" EAI_DISPLAY_NAME="$display_name" \
  EAI_INVOCATION_ID="$interactive_invocation_id" EAI_UI_HASH="$ui_helper_sha256" \
  EAI_RUNNER_HASH="$interactive_delete_helper_sha256" node --input-type=module <<'NODE'
import fs from "node:fs";
const lines = fs.readFileSync(process.env.EAI_INTERACTIVE_RAW, "utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).reverse();
let result = null;
for (const line of lines) {
  try {
    const value = JSON.parse(line);
    if (value?.schemaVersion === "eai.windows-interactive-exact-delete.v1") { result = value; break; }
  } catch {}
}
if (!result || result.invocationId !== process.env.EAI_INVOCATION_ID) process.exit(1);
if (result.uiHelperSha256 !== process.env.EAI_UI_HASH || result.runnerSha256 !== process.env.EAI_RUNNER_HASH) process.exit(1);
if (!['invoked-unverified', 'uncertain', 'not-applied'].includes(result.mutationState)) process.exit(1);
if (result.sanitized !== true || result.diagnostic !== true || result.productionGate !== false || result.retryMutationAutomatically !== false || result.absenceVerificationRequired !== true) process.exit(1);
if (result.mutationState !== 'not-applied' || result.appName || result.displayName) {
  if (result.appName !== process.env.EAI_APP_KEY || result.displayName !== process.env.EAI_DISPLAY_NAME) process.exit(1);
}
if (result.mutationState === 'invoked-unverified') {
  if (result.exactExpectedUser !== true || result.interactiveSessionProven !== true || !Number.isInteger(result.interactiveSessionId) || result.interactiveSessionId <= 0 || result.explorerSessionMatched !== true || result.explorerOwnerSidMatched !== true || result.edgeUiBoundToInteractiveSession !== true || result.edgeOwnerSidMatched !== true) process.exit(1);
  if (!Number.isInteger(result.browserWindowHandle) || result.browserWindowHandle <= 0 || !Number.isInteger(result.browserProcessId) || result.browserProcessId <= 0 || result.browserProcessSessionId !== result.interactiveSessionId || !/^[a-f0-9]{64}$/.test(result.topLevelWindowRuntimeIdSha256 || "") || !/^[a-f0-9]{64}$/.test(result.dialogFinalRuntimeIdSha256 || "") || result.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke !== true || result.exactBrowserWindowForegroundAtInvoke !== true) process.exit(1);
  if (result.exactDialogVerified !== true || result.exactTypedValueVerified !== true || result.exactDialogRevalidatedImmediatelyBeforeInvoke !== true || result.exactButtonFocused !== true || result.scopedInvokePatternInvoked !== true || result.confirmationDialogClosed !== true || !Number.isInteger(result.dialogAbsentConsecutiveChecks) || result.dialogAbsentConsecutiveChecks < 12 || result.dialogClosureStableMilliseconds < 3000) process.exit(1);
} else if (result.confirmationDialogClosed !== false) {
  process.exit(1);
}
fs.writeFileSync(process.env.EAI_INTERACTIVE_NORMALIZED, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
NODE
}

run_ui_action_once() {
  local action="$1"
  local timeout_seconds="$2"
  local target_flag="${3:-0}"
  local stdout_file="$work_dir/ui.stdout"
  local stderr_file="$work_dir/ui.stderr"
  local invocation=""
  : >"$stdout_file"
  : >"$stderr_file"
  if [[ "$target_flag" == 1 ]]; then
    invocation="Invoke-WindowsUiAction -Action '$action' -TimeoutSeconds $timeout_seconds -AppKeyBase64 '$app_base64' -DisplayNameBase64 '$display_base64'"
  else
    invocation="Invoke-WindowsUiAction -Action '$action' -TimeoutSeconds $timeout_seconds"
  fi
  if {
    /bin/cat "$ui_helper"
    printf '\n%s\n' "$invocation"
  } | "$prlctl_bin" exec "$vm_name" --current-user powershell.exe \
        -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass \
        -InputFormat Text -OutputFormat Text -Command - \
        >"$stdout_file" 2>"$stderr_file"; then
    ui_status=0
  else
    ui_status=$?
  fi
  ui_output="$(/bin/cat "$stdout_file" "$stderr_file")"
  if [[ "$ui_status" == 0 ]] \
    && printf '%s\n' "$ui_output" | /usr/bin/tr -d '\r' | /usr/bin/grep -Fqx 'WINDOWS_UI_ACTION_OK'; then
    return 0
  fi
  if [[ "$ui_status" == 0 ]]; then return 1; fi
  return "$ui_status"
}

run_readonly_ui_action() {
  local action="$1"
  local timeout_seconds="$2"
  local target_flag="${3:-0}"
  local attempt
  case "$action" in
    wait-platform-apps|probe-manage-app-search|assert-delete-ready)
      ;;
    *)
      fail "Only a read-only portal state probe may use the retry transport."
      ;;
  esac
  for attempt in $(seq 1 3); do
    if run_ui_action_once "$action" "$timeout_seconds" "$target_flag"; then
      printf '%s\n' "$ui_output"
      return 0
    fi
    if [[ "$ui_status" == 255 ]] \
      && is_exact_transport_failure "$ui_output" \
      && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    return 1
  done
  return 1
}

manage_app_search_state() {
  local output=""
  local present_count=0
  local absent_count=0
  output="$(run_readonly_ui_action probe-manage-app-search 30)" || return 2
  present_count="$(printf '%s\n' "$output" | /usr/bin/tr -d '\r' \
    | /usr/bin/grep -Fxc 'EAI_MANAGE_APP_SEARCH_PRESENT' || true)"
  absent_count="$(printf '%s\n' "$output" | /usr/bin/tr -d '\r' \
    | /usr/bin/grep -Fxc 'EAI_MANAGE_APP_SEARCH_ABSENT' || true)"
  if [[ "$present_count" == 1 && "$absent_count" == 0 ]]; then return 0; fi
  if [[ "$present_count" == 0 && "$absent_count" == 1 ]]; then return 1; fi
  return 2
}

if [[ "$mode" == prepare-attempt-2 ]]; then
  for required_attempt1_file in \
    "$target_receipt" \
    "$prepared_receipt" \
    "$invocation_receipt" \
    "$verification_only_receipt"; do
    [[ -f "$required_attempt1_file" && ! -L "$required_attempt1_file" ]] \
      || fail "Attempt 2 requires complete, safe attempt-1 target, preparation, invocation, and verification evidence."
  done
  for optional_attempt2_file in "$attempt1_present_receipt" "$attempt2_target_receipt" "$attempt2_prepared_receipt"; do
    [[ ! -e "$optional_attempt2_file" || ( -f "$optional_attempt2_file" && ! -L "$optional_attempt2_file" ) ]] \
      || fail "An attempt-2 evidence path is unsafe."
  done

  EAI_ATTEMPT1_TARGET="$target_receipt" EAI_ATTEMPT1_PREPARED="$prepared_receipt" \
  EAI_ATTEMPT1_INVOCATION="$invocation_receipt" EAI_VERIFY_ONLY="$verification_only_receipt" \
  EAI_ATTEMPT1_PRESENT="$attempt1_present_receipt" EAI_REPORT="$report_file" \
  EAI_STATE="$state_file" EAI_RESULT="$result_file" EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const readBytes = (file) => fs.readFileSync(file);
const read = (file) => JSON.parse(readBytes(file).toString("utf8"));
const hashBytes = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const hash = (file) => hashBytes(readBytes(file));
const targetBytes = readBytes(process.env.EAI_ATTEMPT1_TARGET);
const preparedBytes = readBytes(process.env.EAI_ATTEMPT1_PREPARED);
const invocationBytes = readBytes(process.env.EAI_ATTEMPT1_INVOCATION);
const verificationBytes = readBytes(process.env.EAI_VERIFY_ONLY);
const invocationStat = fs.statSync(process.env.EAI_ATTEMPT1_INVOCATION);
const verificationStat = fs.statSync(process.env.EAI_VERIFY_ONLY);
const target = JSON.parse(targetBytes.toString("utf8"));
const prepared = JSON.parse(preparedBytes.toString("utf8"));
const invocation = JSON.parse(invocationBytes.toString("utf8"));
const verification = JSON.parse(verificationBytes.toString("utf8"));
const runId = process.env.EAI_RUN_ID;
const appName = process.env.EAI_APP_KEY;
const markings = (value) => value?.sanitized === true && value?.diagnostic === true && value?.productionGate === false;
if (target.schemaVersion !== "eai.windows-portal-cleanup-target.v1" || target.runId !== runId || target.platform !== "windows" || target.appName !== appName || target.freshGuestAuthProven !== true || target.mutationAttempted !== false || !markings(target)) throw new Error("attempt1-target-invalid");
if (!/^[a-f0-9]{64}$/.test(target.resourceIdSha256 || "") || typeof target.resourceCreatedAt !== "string" || !Number.isFinite(Date.parse(target.resourceCreatedAt)) || typeof target.displayName !== "string") throw new Error("attempt1-target-identity-invalid");
const checks = target.preDeleteValidation;
if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true) throw new Error("attempt1-target-provenance-invalid");
const modernChildEvidence = checks.authoritativeChildQueriesComplete === true
  && checks.servicesBeforeDeletion === 0
  && checks.verticalProductConfigsBeforeDeletion === 0
  && checks.workflowExactMatchesBeforeDeletion === 0
  && checks.setupExactMatchesBeforeDeletion === 0
  && checks.childQueries?.queriesComplete === true
  && checks.childQueries?.serviceActivations?.objectType === "vertical-service-activation"
  && checks.childQueries?.serviceActivations?.querySucceeded === true
  && checks.childQueries?.serviceActivations?.completeBoundedPage === true
  && checks.childQueries?.serviceActivations?.exactVerticalKeyMatches === 0
  && checks.childQueries?.productConfigs?.objectType === "vertical-product-config"
  && checks.childQueries?.productConfigs?.querySucceeded === true
  && checks.childQueries?.productConfigs?.completeBoundedPage === true
  && checks.childQueries?.productConfigs?.exactVerticalKeyMatches === 0;
if (modernChildEvidence) {
  for (const query of [checks.childQueries.serviceActivations, checks.childQueries.productConfigs]) {
    if (query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000) throw new Error("attempt1-target-child-query-evidence-invalid");
  }
}
const legacyKeys = [
  "createdDuringThisRun",
  "embeddedChildFieldsEmpty",
  "enrollmentExactMatches",
  "servicesBeforeDeletion",
  "setupExactMatchesBeforeDeletion",
  "sourceVerified",
  "workflowExactMatchesBeforeDeletion",
];
const exactLegacyChildSummary = checks && JSON.stringify(Object.keys(checks).sort()) === JSON.stringify(legacyKeys)
  && checks.embeddedChildFieldsEmpty === true
  && checks.servicesBeforeDeletion === 0
  && checks.workflowExactMatchesBeforeDeletion === 0
  && checks.setupExactMatchesBeforeDeletion === 0;
if (!modernChildEvidence && !exactLegacyChildSummary) throw new Error("attempt1-target-child-evidence-shape-invalid");
const attempt1TargetChildEvidence = {
  classification: modernChildEvidence
    ? "authoritative-independent-resource-queries"
    : "legacy-embedded-fields-nonauthoritative",
  authoritativeAtAttempt1: modernChildEvidence,
  acceptedForIdentityAndProvenanceOnly: !modernChildEvidence,
  legacyChildCountsTrustedForAttempt2: false,
  freshAttempt2AuthoritativeGateRequired: true,
};
if (target.sourceEvidenceSha256?.controller !== hash(process.env.EAI_REPORT) || target.sourceEvidenceSha256?.appState !== hash(process.env.EAI_STATE) || target.sourceEvidenceSha256?.vmResult !== hash(process.env.EAI_RESULT)) throw new Error("attempt1-source-evidence-changed");
if (prepared.schemaVersion !== "eai.windows-portal-delete-prepared.v1" || prepared.runId !== runId || prepared.platform !== "windows" || prepared.appName !== appName || prepared.displayName !== target.displayName || prepared.targetReceiptSha256 !== hashBytes(targetBytes) || prepared.exactOrigin !== "admin-portal.myenterprise.ai" || prepared.exactPath !== "/platform/apps" || prepared.exactRowBound !== true || prepared.typedConfirmationVerified !== true || prepared.deletePermanentlyInvoked !== false || !markings(prepared)) throw new Error("attempt1-prepared-invalid");
if (invocation.schemaVersion !== "eai.windows-portal-delete-invocation.v1" || invocation.runId !== runId || invocation.platform !== "windows" || invocation.appName !== appName || invocation.action !== "invoke-delete-permanently" || invocation.mutationState !== "invoked-unverified" || invocation.transportExitCode !== 0 || invocation.retryMutationAutomatically !== false || invocation.deletionVerified !== false || invocation.absenceVerificationRequired !== true || !markings(invocation)) throw new Error("attempt1-invocation-not-eligible");
const preparedAt = Date.parse(prepared.preparedAt);
const expiresAt = Date.parse(prepared.expiresAt);
const invokedAt = Date.parse(invocation.recordedAt);
if (![preparedAt, expiresAt, invokedAt].every(Number.isFinite) || invokedAt < preparedAt || invokedAt > expiresAt) throw new Error("attempt1-invocation-time-invalid");
const absence = verification.absence;
if (verification.schemaVersion !== "eai.windows-diagnostic-cleanup.v1" || verification.action !== "verify-only" || verification.runId !== runId || verification.platform !== "windows" || verification.appName !== appName || verification.deleted !== false || verification.cleanupVerified !== false || !markings(verification)) throw new Error("attempt1-verification-invalid");
if (absence?.resourceApiQuerySucceeded !== true || absence.cliAppListSucceeded !== true || absence.resourceApiExactMatchesAfter !== 1 || absence.cliExactMatchesAfter !== 1 || absence.verified !== false) throw new Error("attempt1-not-exactly-one-on-both-channels");
const verifiedAt = Date.parse(absence.verifiedAt);
const verificationRecordedAt = Date.parse(verification.recordedAt);
if (![verifiedAt, verificationRecordedAt].every(Number.isFinite) || invokedAt > Date.now() + 300000 || verifiedAt > Date.now() + 300000 || verificationRecordedAt > Date.now() + 300000) throw new Error("attempt1-verification-semantic-time-invalid");
const hostSettleMilliseconds = verificationStat.mtimeMs - invocationStat.mtimeMs;
if (!Number.isFinite(hostSettleMilliseconds) || verificationStat.mtimeMs < invocationStat.mtimeMs || hostSettleMilliseconds < 60_000 || invocationStat.mtimeMs > Date.now() + 300000 || verificationStat.mtimeMs > Date.now() + 300000) throw new Error("attempt1-verification-host-settle-invalid");
const receipt = {
  schemaVersion: "eai.windows-portal-delete-attempt-1-still-present.v1",
  attempt: 1,
  runId,
  platform: "windows",
  appName,
  displayName: target.displayName,
  resourceIdSha256: target.resourceIdSha256,
  resourceCreatedAt: target.resourceCreatedAt,
  attempt1TargetReceiptSha256: hashBytes(targetBytes),
  attempt1PreparedReceiptSha256: hashBytes(preparedBytes),
  attempt1InvocationReceiptSha256: hashBytes(invocationBytes),
  sourceVerifyOnlyReceiptSha256: hashBytes(verificationBytes),
  attempt1TargetChildEvidence,
  checks: {
    resourceApiQuerySucceeded: true,
    resourceApiExactMatchesAfter: 1,
    cliAppListSucceeded: true,
    cliExactMatchesAfter: 1,
  },
  attempt1InvokedAt: invocation.recordedAt,
  verifiedAt: absence.verifiedAt,
  attempt1InvocationHostModifiedAt: new Date(invocationStat.mtimeMs).toISOString(),
  verificationHostModifiedAt: new Date(verificationStat.mtimeMs).toISOString(),
  minimumSettleMilliseconds: 60000,
  actualSettleMilliseconds: hostSettleMilliseconds,
  verifiedAbsent: false,
  mutationAttempted: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
if (fs.existsSync(process.env.EAI_ATTEMPT1_PRESENT)) {
  const existing = read(process.env.EAI_ATTEMPT1_PRESENT);
  for (const field of ["schemaVersion", "runId", "platform", "appName", "resourceIdSha256", "resourceCreatedAt", "attempt1TargetReceiptSha256", "attempt1PreparedReceiptSha256", "attempt1InvocationReceiptSha256", "sourceVerifyOnlyReceiptSha256"]) {
    if (existing[field] !== receipt[field]) throw new Error(`attempt1-presence-${field}-changed`);
  }
  if (JSON.stringify(existing.attempt1TargetChildEvidence) !== JSON.stringify(receipt.attempt1TargetChildEvidence)) throw new Error("attempt1-presence-child-evidence-classification-changed");
  if (existing.checks?.resourceApiExactMatchesAfter !== 1 || existing.checks?.cliExactMatchesAfter !== 1 || existing.verifiedAbsent !== false || !markings(existing)) throw new Error("attempt1-presence-invalid");
} else {
  fs.writeFileSync(process.env.EAI_ATTEMPT1_PRESENT, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600, flag: "wx" });
}
NODE

  [[ -x "$login_command" ]] || fail "The protected Windows login command is unavailable."
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
  [[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || fail "The protected tenant ID is unavailable."
  [[ -n "$tenant_name" ]] || fail "The protected tenant name is unavailable."
  tenant_id_sha256="$(printf '%s' "$tenant_id" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$tenant_id_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "The protected tenant fingerprint could not be calculated."
  EAI_WINDOWS_VM_NAME="$vm_name" EAI_HARNESS_USER_EMAIL="$test_email" \
  EAI_HARNESS_TENANT_ID="$tenant_id" EAI_HARNESS_TENANT_NAME="$tenant_name" \
    "$login_command" >/dev/null \
    || fail "Fresh protected Windows portal and CLI authentication failed before attempt 2."
  fresh_auth_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  test_email=""
  tenant_name=""

  mode_base64="$(printf '%s' 'PortalTargetOnly' | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  app_base64="$(printf '%s' "$app_key" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  tenant_base64="$(printf '%s' "$tenant_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  run_base64="$(printf '%s' "$run_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  user_base64="$(printf '%s' "$guest_user" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  target_stdout="$work_dir/attempt2-target.stdout"
  target_stderr="$work_dir/attempt2-target.stderr"
  target_status=1
  for attempt in $(seq 1 3); do
    : >"$target_stdout"
    : >"$target_stderr"
    set +e
    run_target_query_once "$mode_base64" "$app_base64" "$tenant_base64" "$run_base64" "$user_base64" \
      "$target_stdout" "$target_stderr"
    target_status=$?
    set -e
    target_output="$(/bin/cat "$target_stdout" "$target_stderr")"
    if [[ "$target_status" == 0 ]]; then break; fi
    if [[ "$target_status" == 255 ]] && is_exact_transport_failure "$target_output" && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    break
  done
  tenant_id=""
  tenant_base64=""
  user_base64=""
  mode_base64=""
  run_base64=""
  [[ "$target_status" == 0 ]] || fail "The fresh attempt-2 exact enrollment query failed."

  EAI_TARGET_RAW="$target_stdout" EAI_ORIGINAL_TARGET="$target_receipt" \
  EAI_ATTEMPT1_PRESENT="$attempt1_present_receipt" EAI_ATTEMPT2_TARGET="$attempt2_target_receipt" \
  EAI_REPORT="$report_file" EAI_STATE="$state_file" EAI_RESULT="$result_file" \
  EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" EAI_AUTH_AT="$fresh_auth_at" \
  EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const rawLines = fs.readFileSync(process.env.EAI_TARGET_RAW, "utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).reverse();
let result = null;
for (const line of rawLines) {
  try { const value = JSON.parse(line); if (value?.schemaVersion === "eai.windows-diagnostic-cleanup.v1") { result = value; break; } } catch {}
}
const originalBytes = fs.readFileSync(process.env.EAI_ORIGINAL_TARGET);
const original = JSON.parse(originalBytes.toString("utf8"));
const presenceBytes = fs.readFileSync(process.env.EAI_ATTEMPT1_PRESENT);
const presence = JSON.parse(presenceBytes.toString("utf8"));
const hashBytes = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const hash = (file) => hashBytes(fs.readFileSync(file));
const childHistory = presence.attempt1TargetChildEvidence;
const childHistoryClassificationValid = childHistory?.classification === "authoritative-independent-resource-queries"
  ? childHistory.authoritativeAtAttempt1 === true && childHistory.acceptedForIdentityAndProvenanceOnly === false
  : childHistory?.classification === "legacy-embedded-fields-nonauthoritative"
    && childHistory.authoritativeAtAttempt1 === false && childHistory.acceptedForIdentityAndProvenanceOnly === true;
if (!childHistoryClassificationValid || childHistory.legacyChildCountsTrustedForAttempt2 !== false || childHistory.freshAttempt2AuthoritativeGateRequired !== true || presence.attempt1TargetReceiptSha256 !== hashBytes(originalBytes)) throw new Error("attempt1-child-evidence-history-invalid");
if (!result || result.action !== "portal-target-only" || result.runId !== process.env.EAI_RUN_ID || result.platform !== "windows" || result.appName !== process.env.EAI_APP_KEY || result.mutationAttempted !== false || result.deleted !== false || result.sanitized !== true || result.diagnostic !== true || result.productionGate !== false) throw new Error("attempt2-target-result-invalid");
if (original.resourceIdSha256 !== result.resourceIdSha256 || original.resourceCreatedAt !== result.resourceCreatedAt || original.displayName !== result.displayName) throw new Error("attempt2-resource-identity-changed");
if (presence.resourceIdSha256 !== result.resourceIdSha256 || presence.resourceCreatedAt !== result.resourceCreatedAt || presence.displayName !== result.displayName) throw new Error("attempt2-presence-identity-changed");
const checks = result.preDeleteValidation;
if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true || checks.childQueries?.serviceActivations?.objectType !== "vertical-service-activation" || checks.childQueries?.serviceActivations?.querySucceeded !== true || checks.childQueries?.serviceActivations?.completeBoundedPage !== true || checks.childQueries?.serviceActivations?.exactVerticalKeyMatches !== 0 || checks.childQueries?.productConfigs?.objectType !== "vertical-product-config" || checks.childQueries?.productConfigs?.querySucceeded !== true || checks.childQueries?.productConfigs?.completeBoundedPage !== true || checks.childQueries?.productConfigs?.exactVerticalKeyMatches !== 0) throw new Error("attempt2-target-child-gate-invalid");
for (const query of [checks.childQueries.serviceActivations, checks.childQueries.productConfigs]) if (query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000) throw new Error("attempt2-target-child-query-evidence-invalid");
if (original.sourceEvidenceSha256?.controller !== hash(process.env.EAI_REPORT) || original.sourceEvidenceSha256?.appState !== hash(process.env.EAI_STATE) || original.sourceEvidenceSha256?.vmResult !== hash(process.env.EAI_RESULT)) throw new Error("attempt2-source-evidence-changed");
const receipt = {
  schemaVersion: "eai.windows-portal-delete-attempt-2-target.v1",
  attempt: 2,
  runId: result.runId,
  platform: "windows",
  appName: result.appName,
  displayName: result.displayName,
  resourceIdSha256: result.resourceIdSha256,
  resourceCreatedAt: result.resourceCreatedAt,
  tenantIdSha256: process.env.EAI_TENANT_HASH,
  identityMatchesOriginal: true,
  attempt1TargetChildEvidence: childHistory,
  freshAttempt2AuthoritativeChildGateEstablished: true,
  freshAttempt2AuthoritativeChildGateSource: "bounded-exact-resource-queries",
  preDeleteValidation: checks,
  sourceEvidenceSha256: original.sourceEvidenceSha256,
  originalTargetReceiptSha256: hashBytes(originalBytes),
  attempt1StillPresentReceiptSha256: hashBytes(presenceBytes),
  freshGuestAuthProven: true,
  freshGuestAuthAt: process.env.EAI_AUTH_AT,
  mutationAttempted: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
const temporary = `${process.env.EAI_ATTEMPT2_TARGET}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_ATTEMPT2_TARGET);
NODE

  display_name="$(node --input-type=module - "$attempt2_target_receipt" "$run_id" "$app_key" <<'NODE'
import fs from "node:fs";
const [file, runId, appName] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
if (value.schemaVersion !== "eai.windows-portal-delete-attempt-2-target.v1" || value.attempt !== 2 || value.runId !== runId || value.appName !== appName || value.identityMatchesOriginal !== true || value.freshAttempt2AuthoritativeChildGateEstablished !== true || value.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries") process.exit(1);
process.stdout.write(value.displayName);
NODE
  )" || fail "The sanitized attempt-2 portal target receipt could not be revalidated."
  display_base64="$(printf '%s' "$display_name" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  run_interactive_worker_operation stage \
    || fail "The exact interactive guest-desktop deletion worker could not be staged for attempt 2."

  input combo control+l || fail "The Edge address bar could not be selected."
  printf '%s' "$approved_apps_url" | input type --stdin || fail "The approved Admin Portal apps URL could not be typed."
  input key enter || fail "The approved Admin Portal apps URL could not be opened."
  run_readonly_ui_action wait-platform-apps 90 >/dev/null || fail "The exact authenticated Admin Portal apps page did not become ready."
  run_ui_action_once invoke-create-app-split-arrow 30 || fail "The unique Create app split-button arrow could not be invoked safely."
  run_ui_action_once invoke-manage-app 30 || fail "The exact Manage app action could not be invoked safely."
  manage_search_status=2
  if manage_app_search_state; then manage_search_status=0; else manage_search_status=$?; fi
  case "$manage_search_status" in
    0)
      run_ui_action_once focus-manage-app-search 30 || fail "The exact Manage app search field could not be focused."
      input combo control+a || fail "The exact Manage app search field could not be selected."
      printf '%s' "$display_name" | input type --stdin || fail "The validated exact display name could not be typed."
      ;;
    1) ;;
    *) fail "The exact Manage app search layout could not be proven." ;;
  esac
  run_ui_action_once invoke-exact-app-delete 60 1 || fail "The one exact app row and its delete control could not be proven."
  run_ui_action_once focus-delete-confirmation 30 1 || fail "The exact app confirmation field could not be focused."
  input combo control+a || fail "The exact app confirmation field could not be selected."
  printf '%s' "$app_key" | input type --stdin || fail "The validated exact app key could not be typed."
  run_readonly_ui_action assert-delete-ready 30 1 >/dev/null || fail "The attempt-2 permanent-delete dialog is not exactly bound and ready."

  issued_confirmation_nonce="$(node --input-type=module -e 'import crypto from "node:crypto"; process.stdout.write(crypto.randomBytes(32).toString("hex"));')"
  [[ "$issued_confirmation_nonce" =~ ^[a-f0-9]{64}$ ]] || fail "The attempt-2 confirmation nonce could not be generated."
  issued_confirmation_nonce_sha256="$(printf '%s' "$issued_confirmation_nonce" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  EAI_ATTEMPT2_TARGET="$attempt2_target_receipt" EAI_ATTEMPT1_PRESENT="$attempt1_present_receipt" \
  EAI_ATTEMPT2_PREPARED="$attempt2_prepared_receipt" EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" \
  EAI_UI_HASH="$ui_helper_sha256" EAI_RUNNER_HASH="$interactive_delete_helper_sha256" \
  EAI_NONCE_HASH="$issued_confirmation_nonce_sha256" EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const targetBytes = fs.readFileSync(process.env.EAI_ATTEMPT2_TARGET);
const target = JSON.parse(targetBytes.toString("utf8"));
const presenceBytes = fs.readFileSync(process.env.EAI_ATTEMPT1_PRESENT);
const childHistory = target.attempt1TargetChildEvidence;
const childHistoryClassificationValid = childHistory?.classification === "authoritative-independent-resource-queries"
  ? childHistory.authoritativeAtAttempt1 === true && childHistory.acceptedForIdentityAndProvenanceOnly === false
  : childHistory?.classification === "legacy-embedded-fields-nonauthoritative"
    && childHistory.authoritativeAtAttempt1 === false && childHistory.acceptedForIdentityAndProvenanceOnly === true;
if (target.schemaVersion !== "eai.windows-portal-delete-attempt-2-target.v1" || target.attempt !== 2 || target.runId !== process.env.EAI_RUN_ID || target.appName !== process.env.EAI_APP_KEY || target.identityMatchesOriginal !== true || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || !childHistoryClassificationValid || childHistory.legacyChildCountsTrustedForAttempt2 !== false || childHistory.freshAttempt2AuthoritativeGateRequired !== true || target.freshAttempt2AuthoritativeChildGateEstablished !== true || target.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries") throw new Error("attempt2-target-invalid");
const preparedAt = new Date();
const receipt = {
  schemaVersion: "eai.windows-portal-delete-attempt-2-prepared.v1",
  attempt: 2,
  runId: target.runId,
  platform: "windows",
  appName: target.appName,
  displayName: target.displayName,
  resourceIdSha256: target.resourceIdSha256,
  resourceCreatedAt: target.resourceCreatedAt,
  tenantIdSha256: target.tenantIdSha256,
  attempt1TargetChildEvidence: childHistory,
  freshAttempt2AuthoritativeChildGateEstablished: true,
  freshAttempt2AuthoritativeChildGateSource: target.freshAttempt2AuthoritativeChildGateSource,
  targetReceiptSha256: crypto.createHash("sha256").update(targetBytes).digest("hex"),
  attempt1StillPresentReceiptSha256: crypto.createHash("sha256").update(presenceBytes).digest("hex"),
  exactOrigin: "admin-portal.myenterprise.ai",
  exactPath: "/platform/apps",
  exactRowBound: true,
  typedConfirmationVerified: true,
  interactiveWorker: {
    uiHelperSha256: process.env.EAI_UI_HASH,
    runnerSha256: process.env.EAI_RUNNER_HASH,
    exactCurrentUser: true,
    realRunDirectory: true,
    stagedAndVerified: true,
  },
  explicitActionTimeConfirmationRequired: true,
  confirmationNonceSha256: process.env.EAI_NONCE_HASH,
  preInvokeTargetRevalidationRequired: true,
  deletePermanentlyInvoked: false,
  expiresAt: new Date(preparedAt.getTime() + 10 * 60 * 1000).toISOString(),
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  preparedAt: preparedAt.toISOString(),
};
const temporary = `${process.env.EAI_ATTEMPT2_PREPARED}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_ATTEMPT2_PREPARED);
NODE
  printf 'Attempt 2 is prepared for the exact Windows app; no deletion was invoked.\n'
  printf 'Obtain renewed action-time confirmation for %s, then invoke with this one-time nonce:\n' "$app_key"
  printf '%s\n' "$issued_confirmation_nonce"
  issued_confirmation_nonce=""
  exit 0
fi

if [[ "$mode" == prepare ]]; then
  [[ -x "$login_command" ]] || fail "The protected Windows login command is unavailable."
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
  [[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || fail "The protected tenant ID is unavailable."
  [[ -n "$tenant_name" ]] || fail "The protected tenant name is unavailable."
  tenant_id_sha256="$(printf '%s' "$tenant_id" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$tenant_id_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "The protected tenant fingerprint could not be calculated."

  fresh_auth_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  EAI_WINDOWS_VM_NAME="$vm_name" EAI_HARNESS_USER_EMAIL="$test_email" \
  EAI_HARNESS_TENANT_ID="$tenant_id" EAI_HARNESS_TENANT_NAME="$tenant_name" \
    "$login_command" >/dev/null \
    || fail "Fresh protected Windows portal and CLI authentication failed."
  test_email=""
  tenant_name=""

  mode_base64="$(printf '%s' 'PortalTargetOnly' | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  app_base64="$(printf '%s' "$app_key" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  tenant_base64="$(printf '%s' "$tenant_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  run_base64="$(printf '%s' "$run_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  user_base64="$(printf '%s' "$guest_user" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  target_stdout="$work_dir/target.stdout"
  target_stderr="$work_dir/target.stderr"
  target_status=1
  for attempt in $(seq 1 3); do
    set +e
    run_target_query_once "$mode_base64" "$app_base64" "$tenant_base64" "$run_base64" "$user_base64" \
      "$target_stdout" "$target_stderr"
    target_status=$?
    set -e
    target_output="$(/bin/cat "$target_stdout" "$target_stderr")"
    if [[ "$target_status" == 0 ]]; then break; fi
    if [[ "$target_status" == 255 ]] && is_exact_transport_failure "$target_output" && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    break
  done
  tenant_id=""
  tenant_base64=""
  user_base64=""
  mode_base64=""
  run_base64=""
  [[ "$target_status" == 0 ]] || fail "The private read-only exact enrollment query failed."

  EAI_TARGET_RAW="$target_stdout" EAI_TARGET_RECEIPT="$target_receipt" \
  EAI_REPORT="$report_file" EAI_STATE="$state_file" EAI_RESULT="$result_file" \
  EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" EAI_AUTH_AT="$fresh_auth_at" \
  EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const rawLines = fs.readFileSync(process.env.EAI_TARGET_RAW, "utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).reverse();
let result = null;
for (const line of rawLines) {
  try {
    const value = JSON.parse(line);
    if (value?.schemaVersion === "eai.windows-diagnostic-cleanup.v1") { result = value; break; }
  } catch {}
}
if (!result || result.action !== "portal-target-only" || result.runId !== process.env.EAI_RUN_ID || result.platform !== "windows" || result.appName !== process.env.EAI_APP_KEY) throw new Error("target-result-invalid");
if (result.mutationAttempted !== false || result.deleted !== false || result.sanitized !== true || result.diagnostic !== true || result.productionGate !== false) throw new Error("target-safety-invalid");
const checks = result.preDeleteValidation;
if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true || checks.childQueries?.serviceActivations?.objectType !== "vertical-service-activation" || checks.childQueries?.serviceActivations?.querySucceeded !== true || checks.childQueries?.serviceActivations?.completeBoundedPage !== true || checks.childQueries?.serviceActivations?.exactVerticalKeyMatches !== 0 || checks.childQueries?.productConfigs?.objectType !== "vertical-product-config" || checks.childQueries?.productConfigs?.querySucceeded !== true || checks.childQueries?.productConfigs?.completeBoundedPage !== true || checks.childQueries?.productConfigs?.exactVerticalKeyMatches !== 0) throw new Error("target-child-gate-invalid");
for (const query of [checks.childQueries.serviceActivations, checks.childQueries.productConfigs]) if (query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000) throw new Error("target-child-query-evidence-invalid");
if (typeof result.displayName !== "string" || !/^[A-Za-z0-9][A-Za-z0-9 .,_-]{0,199}$/.test(result.displayName)) throw new Error("target-display-name-invalid");
if (!/^[a-f0-9]{64}$/.test(result.resourceIdSha256 || "")) throw new Error("target-resource-hash-invalid");
const runStartedAt = Number(process.env.EAI_RUN_ID.slice(0, 13));
const resourceCreatedAt = Date.parse(result.resourceCreatedAt);
if (!Number.isFinite(resourceCreatedAt) || resourceCreatedAt < runStartedAt || resourceCreatedAt > Date.now() + 300000) throw new Error("target-created-at-invalid");
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const receipt = {
  schemaVersion: "eai.windows-portal-cleanup-target.v1",
  runId: result.runId,
  platform: "windows",
  appName: result.appName,
  displayName: result.displayName,
  resourceCreatedAt: result.resourceCreatedAt,
  resourceIdSha256: result.resourceIdSha256,
  tenantIdSha256: process.env.EAI_TENANT_HASH,
  preDeleteValidation: checks,
  sourceEvidenceSha256: {
    controller: hash(process.env.EAI_REPORT),
    appState: hash(process.env.EAI_STATE),
    vmResult: hash(process.env.EAI_RESULT),
  },
  freshGuestAuthProven: true,
  freshGuestAuthAt: process.env.EAI_AUTH_AT,
  mutationAttempted: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
const temporary = `${process.env.EAI_TARGET_RECEIPT}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_TARGET_RECEIPT);
NODE

  display_name="$(node --input-type=module - "$target_receipt" "$run_id" "$app_key" <<'NODE'
import fs from "node:fs";
const [file, runId, appName] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
if (value.schemaVersion !== "eai.windows-portal-cleanup-target.v1" || value.runId !== runId || value.appName !== appName) process.exit(1);
process.stdout.write(value.displayName);
NODE
  )" || fail "The sanitized portal target receipt could not be revalidated."
  display_base64="$(printf '%s' "$display_name" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  run_interactive_worker_operation stage \
    || fail "The exact interactive guest-desktop deletion worker could not be staged and verified."

  input combo control+l || fail "The Edge address bar could not be selected."
  printf '%s' "$approved_apps_url" | input type --stdin || fail "The approved Admin Portal apps URL could not be typed."
  input key enter || fail "The approved Admin Portal apps URL could not be opened."
  run_readonly_ui_action wait-platform-apps 90 >/dev/null \
    || fail "The exact authenticated Admin Portal apps page did not become ready."
  run_ui_action_once invoke-create-app-split-arrow 30 || fail "The unique Create app split-button arrow could not be invoked safely."
  run_ui_action_once invoke-manage-app 30 || fail "The exact Manage app action could not be invoked safely."
  manage_search_status=2
  if manage_app_search_state; then
    manage_search_status=0
  else
    manage_search_status=$?
  fi
  case "$manage_search_status" in
    0)
      run_ui_action_once focus-manage-app-search 30 || fail "The exact Manage app search field could not be focused."
      input combo control+a || fail "The exact Manage app search field could not be selected."
      printf '%s' "$display_name" | input type --stdin || fail "The validated exact display name could not be typed."
      ;;
    1)
      # The current portal presents the bounded Manage app modal without a
      # search box. Exact row/display-name binding below remains mandatory.
      ;;
    *)
      fail "The exact Manage app search layout could not be proven."
      ;;
  esac
  run_ui_action_once invoke-exact-app-delete 60 1 || fail "The one exact app row and its delete control could not be proven."
  run_ui_action_once focus-delete-confirmation 30 1 || fail "The exact app confirmation field could not be focused."
  input combo control+a || fail "The exact app confirmation field could not be selected."
  printf '%s' "$app_key" | input type --stdin || fail "The validated exact app key could not be typed."
  run_readonly_ui_action assert-delete-ready 30 1 >/dev/null \
    || fail "The permanent-delete dialog is not exactly bound and ready."

  EAI_TARGET_RECEIPT="$target_receipt" EAI_PREPARED_RECEIPT="$prepared_receipt" \
  EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" EAI_UI_HASH="$ui_helper_sha256" \
  EAI_RUNNER_HASH="$interactive_delete_helper_sha256" EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const targetBytes = fs.readFileSync(process.env.EAI_TARGET_RECEIPT);
const target = JSON.parse(targetBytes.toString("utf8"));
if (target.runId !== process.env.EAI_RUN_ID || target.appName !== process.env.EAI_APP_KEY || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH) throw new Error("target-mismatch");
const preparedAt = new Date();
const receipt = {
  schemaVersion: "eai.windows-portal-delete-prepared.v1",
  runId: target.runId,
  platform: "windows",
  appName: target.appName,
  displayName: target.displayName,
  tenantIdSha256: target.tenantIdSha256,
  targetReceiptSha256: crypto.createHash("sha256").update(targetBytes).digest("hex"),
  exactOrigin: "admin-portal.myenterprise.ai",
  exactPath: "/platform/apps",
  exactRowBound: true,
  typedConfirmationVerified: true,
  interactiveWorker: {
    uiHelperSha256: process.env.EAI_UI_HASH,
    runnerSha256: process.env.EAI_RUNNER_HASH,
    exactCurrentUser: true,
    realRunDirectory: true,
    stagedAndVerified: true,
  },
  deletePermanentlyInvoked: false,
  expiresAt: new Date(preparedAt.getTime() + 30 * 60 * 1000).toISOString(),
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  preparedAt: preparedAt.toISOString(),
};
const temporary = `${process.env.EAI_PREPARED_RECEIPT}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_PREPARED_RECEIPT);
NODE
  printf 'The exact Windows app is prepared in the permanent-delete dialog; no deletion was invoked.\n'
  printf 'After explicit confirmation, run this helper again with --invoke-delete-permanently.\n'
  exit 0
fi

if [[ "$mode" == invoke-attempt-2 ]]; then
  for required_attempt2_file in \
    "$target_receipt" \
    "$prepared_receipt" \
    "$invocation_receipt" \
    "$verification_only_receipt" \
    "$attempt1_present_receipt" \
    "$attempt2_target_receipt" \
    "$attempt2_prepared_receipt"; do
    [[ -f "$required_attempt2_file" && ! -L "$required_attempt2_file" ]] \
      || fail "Attempt 2 requires its complete safe receipt chain."
  done
  [[ ! -e "$attempt2_invocation_receipt" ]] \
    || fail "Attempt 2 is already armed or invoked; verify exact absence and never replay it."
  [[ ! -e "$attempt2_preinvoke_receipt" ]] \
    || fail "Attempt 2 already reached pre-invocation validation. Do not replay it; inspect the evidence and prepare a renewed attempt only after manual resolution."

  tenant_id="${EAI_HARNESS_TENANT_ID:-}"
  if [[ -z "$tenant_id" ]]; then
    tenant_id="$(/usr/bin/security find-generic-password -s "$tenant_id_service" -a "$keychain_account" -w 2>/dev/null || true)"
  fi
  [[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] \
    || fail "The protected tenant ID is unavailable for the immediate attempt-2 revalidation."
  tenant_id_sha256="$(printf '%s' "$tenant_id" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$tenant_id_sha256" =~ ^[a-f0-9]{64}$ ]] \
    || fail "The protected tenant fingerprint could not be calculated."

  prepared_values="$({
    EAI_UI_HASH="$ui_helper_sha256" EAI_RUNNER_HASH="$interactive_delete_helper_sha256" \
    EAI_CONFIRMATION_NONCE="$confirmation_nonce" EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module - \
      "$target_receipt" "$prepared_receipt" "$invocation_receipt" "$verification_only_receipt" \
      "$attempt1_present_receipt" "$attempt2_target_receipt" "$attempt2_prepared_receipt" \
      "$report_file" "$state_file" "$result_file" "$run_id" "$app_key" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const [originalTargetPath, originalPreparedPath, originalInvocationPath, verificationPath, presencePath, targetPath, preparedPath, reportPath, statePath, resultPath, runId, appName] = process.argv.slice(2);
const bytes = (file) => fs.readFileSync(file);
const read = (file) => JSON.parse(bytes(file).toString("utf8"));
const hashBytes = (value) => crypto.createHash("sha256").update(value).digest("hex");
const hash = (file) => hashBytes(bytes(file));
const markings = (value) => value?.sanitized === true && value?.diagnostic === true && value?.productionGate === false;
const originalTarget = read(originalTargetPath);
const originalPreparedBytes = bytes(originalPreparedPath);
const originalInvocationBytes = bytes(originalInvocationPath);
const originalInvocation = JSON.parse(originalInvocationBytes.toString("utf8"));
const verificationBytes = bytes(verificationPath);
const presenceBytes = bytes(presencePath);
const presence = JSON.parse(presenceBytes.toString("utf8"));
const targetBytes = bytes(targetPath);
const target = JSON.parse(targetBytes.toString("utf8"));
const prepared = read(preparedPath);
const validChildHistory = (history) => {
  const classificationValid = history?.classification === "authoritative-independent-resource-queries"
    ? history.authoritativeAtAttempt1 === true && history.acceptedForIdentityAndProvenanceOnly === false
    : history?.classification === "legacy-embedded-fields-nonauthoritative"
      && history.authoritativeAtAttempt1 === false && history.acceptedForIdentityAndProvenanceOnly === true;
  return classificationValid && history.legacyChildCountsTrustedForAttempt2 === false && history.freshAttempt2AuthoritativeGateRequired === true;
};
if (originalInvocation.schemaVersion !== "eai.windows-portal-delete-invocation.v1" || originalInvocation.runId !== runId || originalInvocation.appName !== appName || originalInvocation.mutationState !== "invoked-unverified" || originalInvocation.transportExitCode !== 0 || originalInvocation.retryMutationAutomatically !== false || originalInvocation.deletionVerified !== false || !markings(originalInvocation)) throw new Error("attempt1-invocation-not-eligible");
if (presence.schemaVersion !== "eai.windows-portal-delete-attempt-1-still-present.v1" || presence.attempt !== 1 || presence.runId !== runId || presence.appName !== appName || presence.attempt1TargetReceiptSha256 !== hash(originalTargetPath) || presence.attempt1PreparedReceiptSha256 !== hashBytes(originalPreparedBytes) || presence.attempt1InvocationReceiptSha256 !== hashBytes(originalInvocationBytes) || presence.sourceVerifyOnlyReceiptSha256 !== hashBytes(verificationBytes) || presence.checks?.resourceApiExactMatchesAfter !== 1 || presence.checks?.cliExactMatchesAfter !== 1 || presence.verifiedAbsent !== false || !validChildHistory(presence.attempt1TargetChildEvidence) || !markings(presence)) throw new Error("attempt1-presence-invalid");
if (target.schemaVersion !== "eai.windows-portal-delete-attempt-2-target.v1" || target.attempt !== 2 || target.runId !== runId || target.platform !== "windows" || target.appName !== appName || target.identityMatchesOriginal !== true || target.originalTargetReceiptSha256 !== hash(originalTargetPath) || target.attempt1StillPresentReceiptSha256 !== hashBytes(presenceBytes) || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || target.freshGuestAuthProven !== true || target.mutationAttempted !== false || !validChildHistory(target.attempt1TargetChildEvidence) || JSON.stringify(target.attempt1TargetChildEvidence) !== JSON.stringify(presence.attempt1TargetChildEvidence) || target.freshAttempt2AuthoritativeChildGateEstablished !== true || target.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries" || !markings(target)) throw new Error("attempt2-target-invalid");
if (target.resourceIdSha256 !== originalTarget.resourceIdSha256 || target.resourceCreatedAt !== originalTarget.resourceCreatedAt || target.displayName !== originalTarget.displayName) throw new Error("attempt2-target-identity-mismatch");
const checks = target.preDeleteValidation;
if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true || checks.childQueries?.serviceActivations?.objectType !== "vertical-service-activation" || checks.childQueries?.serviceActivations?.querySucceeded !== true || checks.childQueries?.serviceActivations?.completeBoundedPage !== true || checks.childQueries?.serviceActivations?.exactVerticalKeyMatches !== 0 || checks.childQueries?.productConfigs?.objectType !== "vertical-product-config" || checks.childQueries?.productConfigs?.querySucceeded !== true || checks.childQueries?.productConfigs?.completeBoundedPage !== true || checks.childQueries?.productConfigs?.exactVerticalKeyMatches !== 0) throw new Error("attempt2-target-child-gate-invalid");
for (const query of [checks.childQueries.serviceActivations, checks.childQueries.productConfigs]) if (query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000) throw new Error("attempt2-target-child-query-evidence-invalid");
if (target.sourceEvidenceSha256?.controller !== hash(reportPath) || target.sourceEvidenceSha256?.appState !== hash(statePath) || target.sourceEvidenceSha256?.vmResult !== hash(resultPath)) throw new Error("attempt2-source-evidence-changed");
if (prepared.schemaVersion !== "eai.windows-portal-delete-attempt-2-prepared.v1" || prepared.attempt !== 2 || prepared.runId !== runId || prepared.platform !== "windows" || prepared.appName !== appName || prepared.displayName !== target.displayName || prepared.resourceIdSha256 !== target.resourceIdSha256 || prepared.resourceCreatedAt !== target.resourceCreatedAt || prepared.tenantIdSha256 !== process.env.EAI_TENANT_HASH || prepared.targetReceiptSha256 !== hashBytes(targetBytes) || prepared.attempt1StillPresentReceiptSha256 !== hashBytes(presenceBytes) || !validChildHistory(prepared.attempt1TargetChildEvidence) || JSON.stringify(prepared.attempt1TargetChildEvidence) !== JSON.stringify(target.attempt1TargetChildEvidence) || prepared.freshAttempt2AuthoritativeChildGateEstablished !== true || prepared.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || prepared.exactOrigin !== "admin-portal.myenterprise.ai" || prepared.exactPath !== "/platform/apps" || prepared.exactRowBound !== true || prepared.typedConfirmationVerified !== true || prepared.explicitActionTimeConfirmationRequired !== true || prepared.preInvokeTargetRevalidationRequired !== true || prepared.deletePermanentlyInvoked !== false || !markings(prepared)) throw new Error("attempt2-prepared-invalid");
if (prepared.interactiveWorker?.uiHelperSha256 !== process.env.EAI_UI_HASH || prepared.interactiveWorker?.runnerSha256 !== process.env.EAI_RUNNER_HASH || prepared.interactiveWorker?.exactCurrentUser !== true || prepared.interactiveWorker?.realRunDirectory !== true || prepared.interactiveWorker?.stagedAndVerified !== true) throw new Error("attempt2-worker-invalid");
const preparedAt = Date.parse(prepared.preparedAt);
const expiresAt = Date.parse(prepared.expiresAt);
const authAt = Date.parse(target.freshGuestAuthAt);
if (![preparedAt, expiresAt, authAt].every(Number.isFinite) || expiresAt - preparedAt !== 10 * 60 * 1000 || authAt > preparedAt || Date.now() > expiresAt || preparedAt > Date.now() + 300000) throw new Error("attempt2-prepared-expired");
const nonce = process.env.EAI_CONFIRMATION_NONCE;
if (!/^[a-f0-9]{64}$/.test(nonce || "") || hashBytes(Buffer.from(nonce, "utf8")) !== prepared.confirmationNonceSha256) throw new Error("attempt2-confirmation-nonce-invalid");
if (typeof target.displayName !== "string" || !/^[A-Za-z0-9][A-Za-z0-9 .,_-]{0,199}$/.test(target.displayName)) throw new Error("attempt2-display-name-invalid");
process.stdout.write(`${Buffer.from(appName, "utf8").toString("base64")}\n${Buffer.from(target.displayName, "utf8").toString("base64")}\n${target.displayName}\n${prepared.confirmationNonceSha256}\n`);
NODE
  } 2>/dev/null)" || fail "Attempt 2 is not eligible, its receipt chain changed, or its renewed confirmation nonce expired."
  app_base64="$(printf '%s\n' "$prepared_values" | sed -n '1p')"
  display_base64="$(printf '%s\n' "$prepared_values" | sed -n '2p')"
  display_name="$(printf '%s\n' "$prepared_values" | sed -n '3p')"
  confirmation_nonce_sha256="$(printf '%s\n' "$prepared_values" | sed -n '4p')"
  [[ -n "$app_base64" && -n "$display_base64" && -n "$display_name" \
    && "$confirmation_nonce_sha256" =~ ^[a-f0-9]{64}$ ]] \
    || fail "The attempt-2 target encoding or confirmation binding is missing."
  confirmation_nonce=""

  mode_base64="$(printf '%s' 'PortalTargetOnly' | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  tenant_base64="$(printf '%s' "$tenant_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  run_base64="$(printf '%s' "$run_id" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  user_base64="$(printf '%s' "$guest_user" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  target_stdout="$work_dir/attempt2-preinvoke-target.stdout"
  target_stderr="$work_dir/attempt2-preinvoke-target.stderr"
  target_status=1
  for attempt in $(seq 1 3); do
    : >"$target_stdout"
    : >"$target_stderr"
    set +e
    run_target_query_once "$mode_base64" "$app_base64" "$tenant_base64" "$run_base64" "$user_base64" \
      "$target_stdout" "$target_stderr"
    target_status=$?
    set -e
    target_output="$(/bin/cat "$target_stdout" "$target_stderr")"
    if [[ "$target_status" == 0 ]]; then break; fi
    if [[ "$target_status" == 255 ]] && is_exact_transport_failure "$target_output" && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    break
  done
  tenant_id=""
  tenant_base64=""
  user_base64=""
  mode_base64=""
  run_base64=""
  [[ "$target_status" == 0 ]] || fail "The immediate live attempt-2 target revalidation failed before arming."
  run_readonly_ui_action assert-delete-ready 30 1 >/dev/null \
    || fail "The exact attempt-2 dialog changed before arming; prepare again and obtain renewed confirmation."
  run_interactive_worker_operation verify \
    || fail "The prepared interactive attempt-2 worker is missing or changed."

  EAI_TARGET_RAW="$target_stdout" EAI_ORIGINAL_TARGET="$target_receipt" \
  EAI_ATTEMPT2_TARGET="$attempt2_target_receipt" EAI_ATTEMPT2_PREPARED="$attempt2_prepared_receipt" \
  EAI_ATTEMPT2_PREINVOKE="$attempt2_preinvoke_receipt" EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" \
  EAI_NONCE_HASH="$confirmation_nonce_sha256" EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const rawLines = fs.readFileSync(process.env.EAI_TARGET_RAW, "utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean).reverse();
let result = null;
for (const line of rawLines) {
  try { const value = JSON.parse(line); if (value?.schemaVersion === "eai.windows-diagnostic-cleanup.v1") { result = value; break; } } catch {}
}
const original = JSON.parse(fs.readFileSync(process.env.EAI_ORIGINAL_TARGET, "utf8"));
const targetBytes = fs.readFileSync(process.env.EAI_ATTEMPT2_TARGET);
const target = JSON.parse(targetBytes.toString("utf8"));
const preparedBytes = fs.readFileSync(process.env.EAI_ATTEMPT2_PREPARED);
const prepared = JSON.parse(preparedBytes.toString("utf8"));
const hashBytes = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const validChildHistory = (history) => {
  const classificationValid = history?.classification === "authoritative-independent-resource-queries"
    ? history.authoritativeAtAttempt1 === true && history.acceptedForIdentityAndProvenanceOnly === false
    : history?.classification === "legacy-embedded-fields-nonauthoritative"
      && history.authoritativeAtAttempt1 === false && history.acceptedForIdentityAndProvenanceOnly === true;
  return classificationValid && history.legacyChildCountsTrustedForAttempt2 === false && history.freshAttempt2AuthoritativeGateRequired === true;
};
if (!result || result.action !== "portal-target-only" || result.runId !== process.env.EAI_RUN_ID || result.platform !== "windows" || result.appName !== process.env.EAI_APP_KEY || result.mutationAttempted !== false || result.deleted !== false || result.sanitized !== true || result.diagnostic !== true || result.productionGate !== false) throw new Error("attempt2-preinvoke-result-invalid");
if (result.resourceIdSha256 !== original.resourceIdSha256 || result.resourceCreatedAt !== original.resourceCreatedAt || result.displayName !== original.displayName || result.resourceIdSha256 !== target.resourceIdSha256 || result.resourceCreatedAt !== target.resourceCreatedAt || result.displayName !== target.displayName || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || prepared.tenantIdSha256 !== process.env.EAI_TENANT_HASH) throw new Error("attempt2-preinvoke-identity-changed");
if (!validChildHistory(target.attempt1TargetChildEvidence) || JSON.stringify(prepared.attempt1TargetChildEvidence) !== JSON.stringify(target.attempt1TargetChildEvidence) || target.freshAttempt2AuthoritativeChildGateEstablished !== true || prepared.freshAttempt2AuthoritativeChildGateEstablished !== true || target.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries" || prepared.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource) throw new Error("attempt2-preinvoke-child-history-invalid");
const checks = result.preDeleteValidation;
if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true || checks.childQueries?.serviceActivations?.objectType !== "vertical-service-activation" || checks.childQueries?.serviceActivations?.querySucceeded !== true || checks.childQueries?.serviceActivations?.completeBoundedPage !== true || checks.childQueries?.serviceActivations?.exactVerticalKeyMatches !== 0 || checks.childQueries?.productConfigs?.objectType !== "vertical-product-config" || checks.childQueries?.productConfigs?.querySucceeded !== true || checks.childQueries?.productConfigs?.completeBoundedPage !== true || checks.childQueries?.productConfigs?.exactVerticalKeyMatches !== 0) throw new Error("attempt2-preinvoke-child-gate-invalid");
for (const query of [checks.childQueries.serviceActivations, checks.childQueries.productConfigs]) if (query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000) throw new Error("attempt2-preinvoke-child-query-evidence-invalid");
if (prepared.confirmationNonceSha256 !== process.env.EAI_NONCE_HASH || prepared.targetReceiptSha256 !== hashBytes(targetBytes)) throw new Error("attempt2-preinvoke-preparation-changed");
const receipt = {
  schemaVersion: "eai.windows-portal-delete-attempt-2-preinvoke.v1",
  attempt: 2,
  runId: result.runId,
  platform: "windows",
  appName: result.appName,
  displayName: result.displayName,
  resourceIdSha256: result.resourceIdSha256,
  resourceCreatedAt: result.resourceCreatedAt,
  tenantIdSha256: process.env.EAI_TENANT_HASH,
  identityMatchesOriginal: true,
  attempt1TargetChildEvidence: target.attempt1TargetChildEvidence,
  freshAttempt2AuthoritativeChildGateEstablished: true,
  freshAttempt2AuthoritativeChildGateSource: target.freshAttempt2AuthoritativeChildGateSource,
  preDeleteValidation: checks,
  targetReceiptSha256: hashBytes(targetBytes),
  preparedReceiptSha256: hashBytes(preparedBytes),
  confirmationNonceSha256: process.env.EAI_NONCE_HASH,
  explicitActionTimeConfirmationAccepted: true,
  exactDialogReadyRevalidated: true,
  interactiveWorkerReverified: true,
  mutationAttempted: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
const temporary = `${process.env.EAI_ATTEMPT2_PREINVOKE}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_ATTEMPT2_PREINVOKE);
NODE

  interactive_invocation_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '-')"
  [[ "$interactive_invocation_id" =~ ^[a-f0-9]{32}$ ]] || fail "The attempt-2 invocation ID could not be generated."
  EAI_ATTEMPT2_INVOCATION="$attempt2_invocation_receipt" EAI_ATTEMPT1_INVOCATION="$invocation_receipt" \
  EAI_ATTEMPT1_PRESENT="$attempt1_present_receipt" EAI_ATTEMPT2_TARGET="$attempt2_target_receipt" \
  EAI_ATTEMPT2_PREPARED="$attempt2_prepared_receipt" EAI_ATTEMPT2_PREINVOKE="$attempt2_preinvoke_receipt" \
  EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" EAI_INVOCATION_ID="$interactive_invocation_id" \
  EAI_NONCE_HASH="$confirmation_nonce_sha256" EAI_TENANT_HASH="$tenant_id_sha256" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const target = JSON.parse(fs.readFileSync(process.env.EAI_ATTEMPT2_TARGET, "utf8"));
const prepared = JSON.parse(fs.readFileSync(process.env.EAI_ATTEMPT2_PREPARED, "utf8"));
const preinvoke = JSON.parse(fs.readFileSync(process.env.EAI_ATTEMPT2_PREINVOKE, "utf8"));
if (target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || prepared.tenantIdSha256 !== process.env.EAI_TENANT_HASH || preinvoke.tenantIdSha256 !== process.env.EAI_TENANT_HASH) throw new Error("attempt2-tenant-invalid");
if (preinvoke.schemaVersion !== "eai.windows-portal-delete-attempt-2-preinvoke.v1" || preinvoke.attempt !== 2 || preinvoke.runId !== process.env.EAI_RUN_ID || preinvoke.appName !== process.env.EAI_APP_KEY || preinvoke.identityMatchesOriginal !== true || JSON.stringify(preinvoke.attempt1TargetChildEvidence) !== JSON.stringify(target.attempt1TargetChildEvidence) || JSON.stringify(prepared.attempt1TargetChildEvidence) !== JSON.stringify(target.attempt1TargetChildEvidence) || target.freshAttempt2AuthoritativeChildGateEstablished !== true || prepared.freshAttempt2AuthoritativeChildGateEstablished !== true || preinvoke.freshAttempt2AuthoritativeChildGateEstablished !== true || target.freshAttempt2AuthoritativeChildGateSource !== "bounded-exact-resource-queries" || prepared.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || preinvoke.freshAttempt2AuthoritativeChildGateSource !== target.freshAttempt2AuthoritativeChildGateSource || preinvoke.explicitActionTimeConfirmationAccepted !== true || preinvoke.exactDialogReadyRevalidated !== true || preinvoke.interactiveWorkerReverified !== true || preinvoke.confirmationNonceSha256 !== process.env.EAI_NONCE_HASH || preinvoke.mutationAttempted !== false) throw new Error("attempt2-preinvoke-invalid");
const preparedAt = Date.parse(prepared.preparedAt);
const expiresAt = Date.parse(prepared.expiresAt);
const preinvokeAt = Date.parse(preinvoke.recordedAt);
const now = Date.now();
if (![preparedAt, expiresAt, preinvokeAt].every(Number.isFinite) || expiresAt - preparedAt !== 10 * 60 * 1000 || preinvokeAt < preparedAt || now > expiresAt || preparedAt > now + 300000) throw new Error("attempt2-expired-immediately-before-arm");
const armedAt = new Date().toISOString();
const receipt = {
  schemaVersion: "eai.windows-portal-delete-attempt-2-invocation.v1",
  attempt: 2,
  runId: process.env.EAI_RUN_ID,
  platform: "windows",
  appName: process.env.EAI_APP_KEY,
  tenantIdSha256: process.env.EAI_TENANT_HASH,
  attempt1TargetChildEvidence: target.attempt1TargetChildEvidence,
  freshAttempt2AuthoritativeChildGateEstablished: true,
  freshAttempt2AuthoritativeChildGateSource: target.freshAttempt2AuthoritativeChildGateSource,
  action: "invoke-delete-attempt-2",
  attempt1InvocationReceiptSha256: hash(process.env.EAI_ATTEMPT1_INVOCATION),
  attempt1StillPresentReceiptSha256: hash(process.env.EAI_ATTEMPT1_PRESENT),
  targetReceiptSha256: hash(process.env.EAI_ATTEMPT2_TARGET),
  preparedReceiptSha256: hash(process.env.EAI_ATTEMPT2_PREPARED),
  preInvokeReceiptSha256: hash(process.env.EAI_ATTEMPT2_PREINVOKE),
  confirmationNonceSha256: process.env.EAI_NONCE_HASH,
  explicitActionTimeConfirmationAccepted: true,
  confirmationAcceptedAt: preinvoke.recordedAt,
  mutationState: "armed-uncertain",
  armedBeforeDestructiveInput: true,
  interactiveDesktopLaunchAttempted: false,
  interactiveInvocationIdSha256: crypto.createHash("sha256").update(process.env.EAI_INVOCATION_ID).digest("hex"),
  transportExitCode: null,
  interactiveResultObserved: false,
  interactiveResultValidated: false,
  confirmationDialogClosed: false,
  dialogAbsentConsecutiveChecks: 0,
  dialogClosureStableMilliseconds: 0,
  retryMutationAutomatically: false,
  deletionVerified: false,
  absenceVerificationRequired: true,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  armedAt,
  recordedAt: armedAt,
};
fs.writeFileSync(process.env.EAI_ATTEMPT2_INVOCATION, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600, flag: "wx" });
NODE

  interactive_raw="$work_dir/attempt2-interactive-result.raw"
  interactive_normalized="$work_dir/attempt2-interactive-result.json"
  interactive_output=""
  interactive_transport_status=1
  interactive_launch_attempted=0
  set +e
  run_interactive_delete_once
  interactive_run_status=$?
  set -e
  printf '%s' "$interactive_output" >"$interactive_raw"
  interactive_result_valid=0
  interactive_result_observed=0
  if [[ "$interactive_run_status" == 0 && -n "$interactive_output" ]]; then interactive_result_observed=1; fi
  if [[ "$interactive_run_status" == 0 ]] \
    && validate_interactive_delete_result "$interactive_raw" "$interactive_normalized"; then
    interactive_result_valid=1
  fi
  final_status=1
  if [[ "$interactive_result_valid" == 1 ]] \
    && jq -e '.mutationState == "invoked-unverified" and .exactExpectedUser == true and .interactiveSessionProven == true and .interactiveSessionId > 0 and .explorerSessionMatched == true and .explorerOwnerSidMatched == true and .edgeUiBoundToInteractiveSession == true and .edgeOwnerSidMatched == true and .browserWindowHandle > 0 and .browserProcessId > 0 and .browserProcessSessionId == .interactiveSessionId and .sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke == true and .exactBrowserWindowForegroundAtInvoke == true and .scopedInvokePatternInvoked == true and .confirmationDialogClosed == true and .dialogAbsentConsecutiveChecks >= 12 and .dialogClosureStableMilliseconds >= 3000' \
      "$interactive_normalized" >/dev/null; then
    final_status=0
  fi
  if [[ -n "$interactive_output" ]]; then
    output_hash="$(printf '%s' "$interactive_output" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  else
    output_hash="$(printf 'interactive-result-unavailable:%s' "$interactive_transport_status" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  fi
  EAI_ATTEMPT2_INVOCATION="$attempt2_invocation_receipt" EAI_FINAL_STATUS="$final_status" \
  EAI_OUTPUT_HASH="$output_hash" EAI_INTERACTIVE_RESULT="$interactive_normalized" \
  EAI_INTERACTIVE_RESULT_VALID="$interactive_result_valid" EAI_INTERACTIVE_RESULT_OBSERVED="$interactive_result_observed" \
  EAI_INTERACTIVE_TRANSPORT_STATUS="$interactive_transport_status" \
  EAI_INTERACTIVE_LAUNCH_ATTEMPTED="$interactive_launch_attempted" node --input-type=module <<'NODE'
import fs from "node:fs";
const receipt = JSON.parse(fs.readFileSync(process.env.EAI_ATTEMPT2_INVOCATION, "utf8"));
if (receipt.schemaVersion !== "eai.windows-portal-delete-attempt-2-invocation.v1" || receipt.attempt !== 2 || receipt.mutationState !== "armed-uncertain" || receipt.armedBeforeDestructiveInput !== true || receipt.retryMutationAutomatically !== false) throw new Error("attempt2-arm-invalid");
const interactiveResult = process.env.EAI_INTERACTIVE_RESULT_VALID === "1"
  ? JSON.parse(fs.readFileSync(process.env.EAI_INTERACTIVE_RESULT, "utf8"))
  : null;
const status = Number(process.env.EAI_FINAL_STATUS);
receipt.mutationState = status === 0 ? "invoked-dialog-closed-unverified" : "uncertain";
receipt.transportExitCode = Number(process.env.EAI_INTERACTIVE_TRANSPORT_STATUS);
receipt.sanitizedOutputSha256 = process.env.EAI_OUTPUT_HASH;
receipt.interactiveDesktopLaunchAttempted = process.env.EAI_INTERACTIVE_LAUNCH_ATTEMPTED === "1";
receipt.interactiveResultObserved = process.env.EAI_INTERACTIVE_RESULT_OBSERVED === "1";
receipt.interactiveResultValidated = interactiveResult !== null;
receipt.exactDialogVerified = interactiveResult?.exactDialogVerified === true;
receipt.exactTypedValueVerified = interactiveResult?.exactTypedValueVerified === true;
receipt.exactDialogRevalidatedImmediatelyBeforeInvoke = interactiveResult?.exactDialogRevalidatedImmediatelyBeforeInvoke === true;
receipt.exactButtonFocused = interactiveResult?.exactButtonFocused === true;
receipt.scopedInvokePatternInvoked = interactiveResult?.scopedInvokePatternInvoked === true;
receipt.exactExpectedUser = interactiveResult?.exactExpectedUser === true;
receipt.interactiveSessionId = Number.isInteger(interactiveResult?.interactiveSessionId) ? interactiveResult.interactiveSessionId : null;
receipt.interactiveSessionProven = interactiveResult?.interactiveSessionProven === true;
receipt.explorerSessionMatched = interactiveResult?.explorerSessionMatched === true;
receipt.explorerOwnerSidMatched = interactiveResult?.explorerOwnerSidMatched === true;
receipt.edgeUiBoundToInteractiveSession = interactiveResult?.edgeUiBoundToInteractiveSession === true;
receipt.edgeOwnerSidMatched = interactiveResult?.edgeOwnerSidMatched === true;
receipt.browserWindowHandle = Number.isInteger(interactiveResult?.browserWindowHandle) ? interactiveResult.browserWindowHandle : null;
receipt.browserProcessId = Number.isInteger(interactiveResult?.browserProcessId) ? interactiveResult.browserProcessId : null;
receipt.browserProcessSessionId = Number.isInteger(interactiveResult?.browserProcessSessionId) ? interactiveResult.browserProcessSessionId : null;
receipt.topLevelWindowRuntimeIdSha256 = interactiveResult?.topLevelWindowRuntimeIdSha256 || null;
receipt.dialogFinalRuntimeIdSha256 = interactiveResult?.dialogFinalRuntimeIdSha256 || null;
receipt.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke = interactiveResult?.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke === true;
receipt.exactBrowserWindowForegroundAtInvoke = interactiveResult?.exactBrowserWindowForegroundAtInvoke === true;
receipt.confirmationDialogClosed = interactiveResult?.confirmationDialogClosed === true;
receipt.dialogAbsentConsecutiveChecks = Number.isInteger(interactiveResult?.dialogAbsentConsecutiveChecks) ? interactiveResult.dialogAbsentConsecutiveChecks : 0;
receipt.dialogClosureStableMilliseconds = Number.isInteger(interactiveResult?.dialogClosureStableMilliseconds) ? interactiveResult.dialogClosureStableMilliseconds : 0;
receipt.completedAt = new Date().toISOString();
receipt.recordedAt = receipt.completedAt;
const temporary = `${process.env.EAI_ATTEMPT2_INVOCATION}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_ATTEMPT2_INVOCATION);
NODE
  if [[ "$final_status" != 0 ]]; then
    fail "Attempt 2 was armed but did not produce a validated sustained exact dialog closure. Never replay it; verify exact absence only."
  fi
  printf 'Attempt 2 invoked Delete permanently exactly once from the interactive guest desktop with sustained dialog closure. Verify API, CLI, and portal absence; no attempt 3 exists.\n'
  exit 0
fi

[[ -f "$target_receipt" && ! -L "$target_receipt" ]] || fail "The sanitized portal target receipt is missing or unsafe."
[[ -f "$prepared_receipt" && ! -L "$prepared_receipt" ]] || fail "The prepared permanent-delete receipt is missing or unsafe."
[[ ! -e "$invocation_receipt" ]] || fail "A permanent-delete invocation has already been recorded; verify absence instead of retrying."
tenant_id="${EAI_HARNESS_TENANT_ID:-}"
if [[ -z "$tenant_id" ]]; then
  tenant_id="$(/usr/bin/security find-generic-password -s "$tenant_id_service" -a "$keychain_account" -w 2>/dev/null || true)"
fi
[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] \
  || fail "The protected tenant ID is unavailable for invocation binding."
tenant_id_sha256="$(printf '%s' "$tenant_id" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
tenant_id=""
[[ "$tenant_id_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "The protected tenant fingerprint could not be calculated."

prepared_values="$({
  EAI_UI_HASH="$ui_helper_sha256" EAI_RUNNER_HASH="$interactive_delete_helper_sha256" \
  EAI_TENANT_HASH="$tenant_id_sha256" \
  node --input-type=module - "$target_receipt" "$prepared_receipt" "$report_file" "$state_file" "$result_file" "$run_id" "$app_key" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const [targetPath, preparedPath, reportPath, statePath, resultPath, runId, appName] = process.argv.slice(2);
const targetBytes = fs.readFileSync(targetPath);
const target = JSON.parse(targetBytes.toString("utf8"));
const prepared = JSON.parse(fs.readFileSync(preparedPath, "utf8"));
if (target.schemaVersion !== "eai.windows-portal-cleanup-target.v1" || target.runId !== runId || target.platform !== "windows" || target.appName !== appName || target.tenantIdSha256 !== process.env.EAI_TENANT_HASH || target.freshGuestAuthProven !== true || target.mutationAttempted !== false || target.sanitized !== true || target.diagnostic !== true || target.productionGate !== false || !/^[a-f0-9]{64}$/.test(target.resourceIdSha256 || "")) throw new Error("target-invalid");
const checks = target.preDeleteValidation;
if (checks?.enrollmentExactMatches !== 1 || checks.createdDuringThisRun !== true || checks.sourceVerified !== true || checks.authoritativeChildQueriesComplete !== true || checks.servicesBeforeDeletion !== 0 || checks.verticalProductConfigsBeforeDeletion !== 0 || checks.workflowExactMatchesBeforeDeletion !== 0 || checks.setupExactMatchesBeforeDeletion !== 0 || checks.childQueries?.queriesComplete !== true || checks.childQueries?.serviceActivations?.objectType !== "vertical-service-activation" || checks.childQueries?.serviceActivations?.querySucceeded !== true || checks.childQueries?.serviceActivations?.completeBoundedPage !== true || checks.childQueries?.serviceActivations?.exactVerticalKeyMatches !== 0 || checks.childQueries?.productConfigs?.objectType !== "vertical-product-config" || checks.childQueries?.productConfigs?.querySucceeded !== true || checks.childQueries?.productConfigs?.completeBoundedPage !== true || checks.childQueries?.productConfigs?.exactVerticalKeyMatches !== 0) throw new Error("target-child-gate-invalid");
for (const query of [checks.childQueries.serviceActivations, checks.childQueries.productConfigs]) if (query.filterField !== "data.verticalKey" || query.comparison !== "case-sensitive-exact" || query.filterValueAppKeyBound !== true || !Number.isInteger(query.totalDocs) || query.totalDocs < 0 || query.totalDocs >= 1000) throw new Error("target-child-query-evidence-invalid");
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
if (target.sourceEvidenceSha256?.controller !== hash(reportPath) || target.sourceEvidenceSha256?.appState !== hash(statePath) || target.sourceEvidenceSha256?.vmResult !== hash(resultPath)) throw new Error("source-evidence-changed");
if (prepared.schemaVersion !== "eai.windows-portal-delete-prepared.v1" || prepared.runId !== runId || prepared.platform !== "windows" || prepared.appName !== appName || prepared.displayName !== target.displayName || prepared.tenantIdSha256 !== process.env.EAI_TENANT_HASH || prepared.exactOrigin !== "admin-portal.myenterprise.ai" || prepared.exactPath !== "/platform/apps" || prepared.exactRowBound !== true || prepared.typedConfirmationVerified !== true || prepared.deletePermanentlyInvoked !== false) throw new Error("prepared-invalid");
if (prepared.interactiveWorker?.uiHelperSha256 !== process.env.EAI_UI_HASH || prepared.interactiveWorker?.runnerSha256 !== process.env.EAI_RUNNER_HASH || prepared.interactiveWorker?.exactCurrentUser !== true || prepared.interactiveWorker?.realRunDirectory !== true || prepared.interactiveWorker?.stagedAndVerified !== true) throw new Error("prepared-worker-invalid");
const targetHash = crypto.createHash("sha256").update(targetBytes).digest("hex");
if (prepared.targetReceiptSha256 !== targetHash) throw new Error("target-hash-mismatch");
const preparedAt = Date.parse(prepared.preparedAt);
const expiresAt = Date.parse(prepared.expiresAt);
if (!Number.isFinite(preparedAt) || !Number.isFinite(expiresAt) || preparedAt > Date.now() + 300000 || Date.now() > expiresAt || expiresAt - preparedAt !== 30 * 60 * 1000) throw new Error("prepared-expired");
if (typeof target.displayName !== "string" || !/^[A-Za-z0-9][A-Za-z0-9 .,_-]{0,199}$/.test(target.displayName)) throw new Error("display-name-invalid");
process.stdout.write(`${Buffer.from(appName, "utf8").toString("base64")}\n${Buffer.from(target.displayName, "utf8").toString("base64")}\n${prepared.interactiveWorker.uiHelperSha256}\n${prepared.interactiveWorker.runnerSha256}\n${target.displayName}\n`);
NODE
} 2>/dev/null)" || fail "The exact prepared portal target is invalid, changed, or expired; rerun --prepare-delete."
app_base64="$(printf '%s\n' "$prepared_values" | sed -n '1p')"
display_base64="$(printf '%s\n' "$prepared_values" | sed -n '2p')"
prepared_ui_hash="$(printf '%s\n' "$prepared_values" | sed -n '3p')"
prepared_runner_hash="$(printf '%s\n' "$prepared_values" | sed -n '4p')"
display_name="$(printf '%s\n' "$prepared_values" | sed -n '5p')"
[[ -n "$app_base64" && -n "$display_base64" \
  && -n "$display_name" \
  && "$prepared_ui_hash" == "$ui_helper_sha256" \
  && "$prepared_runner_hash" == "$interactive_delete_helper_sha256" ]] \
  || fail "The prepared target encoding or interactive worker binding is missing."

# Revalidate the prepared guest worker through the read-only service channel.
# The final action itself must not run through that service desktop.
run_interactive_worker_operation verify \
  || fail "The prepared interactive guest-desktop deletion worker is missing or changed."

# This launch is intentionally one-shot. Any missing, malformed, or ambiguous
# interactive result is recorded as uncertain and must never be retried.
interactive_raw="$work_dir/interactive-result.raw"
interactive_normalized="$work_dir/interactive-result.json"
interactive_output=""
interactive_transport_status=1
interactive_launch_attempted=0
interactive_invocation_id=""
set +e
run_interactive_delete_once
interactive_run_status=$?
set -e
printf '%s' "$interactive_output" >"$interactive_raw"
interactive_result_valid=0
interactive_result_observed=0
if [[ "$interactive_run_status" == 0 && -n "$interactive_output" ]]; then
  interactive_result_observed=1
fi
if [[ "$interactive_run_status" == 0 ]] \
  && validate_interactive_delete_result "$interactive_raw" "$interactive_normalized"; then
  interactive_result_valid=1
fi
final_status=1
if [[ "$interactive_result_valid" == 1 ]] \
  && jq -e '.mutationState == "invoked-unverified" and .exactExpectedUser == true and .interactiveSessionProven == true and .interactiveSessionId > 0 and .explorerSessionMatched == true and .explorerOwnerSidMatched == true and .edgeUiBoundToInteractiveSession == true and .edgeOwnerSidMatched == true and .browserWindowHandle > 0 and .browserProcessId > 0 and .browserProcessSessionId == .interactiveSessionId and .sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke == true and .exactBrowserWindowForegroundAtInvoke == true and .scopedInvokePatternInvoked == true and .confirmationDialogClosed == true and .dialogAbsentConsecutiveChecks >= 12 and .dialogClosureStableMilliseconds >= 3000' \
    "$interactive_normalized" >/dev/null; then
  final_status=0
fi
if [[ -n "$interactive_output" ]]; then
  output_hash="$(printf '%s' "$interactive_output" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
else
  output_hash="$(printf 'interactive-result-unavailable:%s' "$interactive_transport_status" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
fi
EAI_INVOCATION_RECEIPT="$invocation_receipt" EAI_TARGET_RECEIPT="$target_receipt" \
EAI_PREPARED_RECEIPT="$prepared_receipt" EAI_RUN_ID="$run_id" EAI_APP_KEY="$app_key" \
EAI_FINAL_STATUS="$final_status" EAI_OUTPUT_HASH="$output_hash" \
EAI_INTERACTIVE_RESULT="$interactive_normalized" EAI_INTERACTIVE_RESULT_VALID="$interactive_result_valid" \
EAI_INTERACTIVE_RESULT_OBSERVED="$interactive_result_observed" \
EAI_INTERACTIVE_TRANSPORT_STATUS="$interactive_transport_status" \
EAI_INTERACTIVE_LAUNCH_ATTEMPTED="$interactive_launch_attempted" \
EAI_INTERACTIVE_INVOCATION_ID="$interactive_invocation_id" EAI_TENANT_HASH="$tenant_id_sha256" \
  node --input-type=module <<'NODE'
import fs from "node:fs";
import crypto from "node:crypto";
const status = Number(process.env.EAI_FINAL_STATUS);
const interactiveResult = process.env.EAI_INTERACTIVE_RESULT_VALID === "1"
  ? JSON.parse(fs.readFileSync(process.env.EAI_INTERACTIVE_RESULT, "utf8"))
  : null;
const receipt = {
  schemaVersion: "eai.windows-portal-delete-invocation.v1",
  runId: process.env.EAI_RUN_ID,
  platform: "windows",
  appName: process.env.EAI_APP_KEY,
  tenantIdSha256: process.env.EAI_TENANT_HASH,
  action: "invoke-delete-permanently",
  targetReceiptSha256: crypto.createHash("sha256").update(fs.readFileSync(process.env.EAI_TARGET_RECEIPT)).digest("hex"),
  preparedReceiptSha256: crypto.createHash("sha256").update(fs.readFileSync(process.env.EAI_PREPARED_RECEIPT)).digest("hex"),
  mutationState: status === 0 ? "invoked-unverified" : interactiveResult?.mutationState === "not-applied" ? "not-applied" : "uncertain",
  transportExitCode: Number(process.env.EAI_INTERACTIVE_TRANSPORT_STATUS),
  sanitizedOutputSha256: process.env.EAI_OUTPUT_HASH,
  interactiveDesktopLaunchAttempted: process.env.EAI_INTERACTIVE_LAUNCH_ATTEMPTED === "1",
  interactiveResultObserved: process.env.EAI_INTERACTIVE_RESULT_OBSERVED === "1",
  interactiveResultValidated: interactiveResult !== null,
  interactiveInvocationIdSha256: process.env.EAI_INTERACTIVE_INVOCATION_ID
    ? crypto.createHash("sha256").update(process.env.EAI_INTERACTIVE_INVOCATION_ID).digest("hex")
    : null,
  exactDialogVerified: interactiveResult?.exactDialogVerified === true,
  exactTypedValueVerified: interactiveResult?.exactTypedValueVerified === true,
  exactDialogRevalidatedImmediatelyBeforeInvoke: interactiveResult?.exactDialogRevalidatedImmediatelyBeforeInvoke === true,
  exactButtonFocused: interactiveResult?.exactButtonFocused === true,
  scopedInvokePatternInvoked: interactiveResult?.scopedInvokePatternInvoked === true,
  exactExpectedUser: interactiveResult?.exactExpectedUser === true,
  interactiveSessionId: Number.isInteger(interactiveResult?.interactiveSessionId)
    ? interactiveResult.interactiveSessionId
    : null,
  interactiveSessionProven: interactiveResult?.interactiveSessionProven === true,
  explorerSessionMatched: interactiveResult?.explorerSessionMatched === true,
  explorerOwnerSidMatched: interactiveResult?.explorerOwnerSidMatched === true,
  edgeUiBoundToInteractiveSession: interactiveResult?.edgeUiBoundToInteractiveSession === true,
  edgeOwnerSidMatched: interactiveResult?.edgeOwnerSidMatched === true,
  browserWindowHandle: Number.isInteger(interactiveResult?.browserWindowHandle) ? interactiveResult.browserWindowHandle : null,
  browserProcessId: Number.isInteger(interactiveResult?.browserProcessId) ? interactiveResult.browserProcessId : null,
  browserProcessSessionId: Number.isInteger(interactiveResult?.browserProcessSessionId) ? interactiveResult.browserProcessSessionId : null,
  topLevelWindowRuntimeIdSha256: interactiveResult?.topLevelWindowRuntimeIdSha256 || null,
  dialogFinalRuntimeIdSha256: interactiveResult?.dialogFinalRuntimeIdSha256 || null,
  sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke: interactiveResult?.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke === true,
  exactBrowserWindowForegroundAtInvoke: interactiveResult?.exactBrowserWindowForegroundAtInvoke === true,
  confirmationDialogClosed: interactiveResult?.confirmationDialogClosed === true,
  dialogAbsentConsecutiveChecks: Number.isInteger(interactiveResult?.dialogAbsentConsecutiveChecks)
    ? interactiveResult.dialogAbsentConsecutiveChecks
    : 0,
  dialogClosureStableMilliseconds: Number.isInteger(interactiveResult?.dialogClosureStableMilliseconds)
    ? interactiveResult.dialogClosureStableMilliseconds
    : 0,
  retryMutationAutomatically: false,
  deletionVerified: false,
  absenceVerificationRequired: true,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
const temporary = `${process.env.EAI_INVOCATION_RECEIPT}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, process.env.EAI_INVOCATION_RECEIPT);
NODE
if [[ "$final_status" != 0 ]]; then
  fail "The one-shot interactive permanent-delete result was not a sustained exact dialog closure. Do not retry; verify exact absence first."
fi
printf 'Delete permanently was invoked once from the interactive guest desktop and exact dialog closure was sustained. Exact portal/API/CLI absence is still required.\n'
