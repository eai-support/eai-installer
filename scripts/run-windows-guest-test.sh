#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/guest-test-lib.sh
source "$ROOT/scripts/guest-test-lib.sh"
# shellcheck source=scripts/windows-ai-handoff-process-query.sh
source "$ROOT/scripts/windows-ai-handoff-process-query.sh"
# shellcheck source=scripts/windows-readonly-powershell.sh
source "$ROOT/scripts/windows-readonly-powershell.sh"
# shellcheck source=scripts/windows-hidden-current-user.sh
source "$ROOT/scripts/windows-hidden-current-user.sh"

vm_name="${EAI_WINDOWS_VM_NAME:-Windows 11}"
snapshot_id="${EAI_WINDOWS_SNAPSHOT_ID:-48921a89-eb72-430e-b4bf-a7b70d8bfaab}"
if [[ "${1:-}" == "--preflight" ]]; then
  [[ "$#" -eq 1 ]] || guest_test_fail "The Windows adapter preflight accepts no additional arguments."
  exec "$ROOT/scripts/vm-adapter-preflight.sh" windows "$vm_name" "$snapshot_id"
fi
guest_user="${EAI_WINDOWS_GUEST_USER:-eai-douglasross}"
expected_cli_version="${EAI_EXPECTED_CLI_VERSION:-3.15.10}"
guest_normal_pid='C:\Users\Public\eai-setup-normal.pid'
guest_e2e_pid='C:\Users\Public\eai-setup-e2e.pid'
guest_normal_launch_receipt='C:\Users\Public\eai-setup-normal-launch.json'
guest_e2e_launch_receipt='C:\Users\Public\eai-setup-e2e-launch.json'
guest_normal_launch_arm='C:\Users\Public\eai-setup-normal-launch-arm.json'
guest_e2e_launch_arm='C:\Users\Public\eai-setup-e2e-launch-arm.json'
guest_normal_launch_cancel='C:\Users\Public\eai-setup-normal-launch-cancel.signal'
guest_e2e_launch_cancel='C:\Users\Public\eai-setup-e2e-launch-cancel.signal'
guest_app_bootstrap='C:\Users\Public\eai-setup-app-bootstrap.ps1'
guest_normal_log='C:\Users\Public\eai-setup-normal.log'
guest_normal_error_log='C:\Users\Public\eai-setup-normal-error.log'
guest_e2e_log='C:\Users\Public\eai-setup-e2e.log'
guest_e2e_error_log='C:\Users\Public\eai-setup-e2e-error.log'
guest_parent='C:\Users\Public\EAIReleaseTests'
guest_executable_file='C:\Users\Public\eai-setup-e2e-executable.txt'
ocr_source="$ROOT/scripts/macos-ocr-match.swift"
ocr_binary="${TMPDIR:-/tmp}/eai-installer-macos-ocr-match"
window_id_source="$ROOT/scripts/macos-parallels-window-id.swift"
window_id_binary="${TMPDIR:-/tmp}/eai-installer-macos-parallels-window-id"
work_dir="$(mktemp -d)"
host_receipt="$work_dir/desktop-receipt.json"
phase="preflight"
completed=0
normal_launch_nonce=""
e2e_launch_nonce=""
normal_bootstrap_hash=""
e2e_bootstrap_hash=""
normal_launch_transport_confirmed=0
e2e_launch_transport_confirmed=0
detached_launch_quarantine_required=0
defender_exclusion_pending=0
defender_exclusion_added=0
defender_exclusion_removed=0
defender_cleanup_wait_exhausted=0
installer_bridge_pending=0
installer_worker_hash=""
installer_worker_nonce=""
defender_worker_hash=""
defender_worker_nonce=""
uac_watcher_pid=""
uac_watcher_started_at=""
uac_consent_restore_required=0
uac_policy_nonce=""
uac_policy_run_binding=""

stage() {
  phase="$1"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase"
}

capture_vm_window() {
  local screenshot="$1"
  local window_id=""
  local verified_window_id=""
  window_id="$("$window_id_binary" "$vm_name" 2>/dev/null || true)"
  [[ "$window_id" =~ ^[1-9][0-9]*$ ]] || return 1
  /usr/sbin/screencapture -x -o -l "$window_id" "$screenshot" >/dev/null 2>&1 || return 1
  verified_window_id="$("$window_id_binary" "$vm_name" 2>/dev/null || true)"
  [[ "$verified_window_id" == "$window_id" ]]
}

exit_vm_coherence_if_needed() {
  local _=""

  # The exact bundle-ID-bound console window is conclusive evidence that this
  # VM is already windowed. Never press the state-changing menu item in that
  # case.
  "$window_id_binary" "$vm_name" >/dev/null 2>&1 && return 0

  # A restored Windows snapshot can retain Coherence. Process display names,
  # executable paths, and PIDs are not stable identities for WinAppHelper.
  # Resolve the one helper whose second menu-bar item names this exact VM and
  # whose View menu exposes exactly one Exit Coherence action. Only integer
  # PIDs survive the enumeration so AppleScript repeat references cannot alias
  # the last process visited.
  if ! osascript - "$vm_name" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  set vmName to item 1 of argv
  set candidatePids to {}
  set candidateActionCount to 0

  tell application "System Events"
    repeat with candidateProcess in application processes
      try
        set candidateMenuBars to menu bars of candidateProcess
        if (count of candidateMenuBars) is greater than 0 then
          set candidateMenuBar to item 1 of candidateMenuBars
          set candidateMenuItems to menu bar items of candidateMenuBar
          if (count of candidateMenuItems) is greater than or equal to 2 then
            set candidateVmName to name of item 2 of candidateMenuItems as text
            if candidateVmName is vmName then
              set exitActionCount to 0
              repeat with candidateViewItem in candidateMenuItems
                try
                  if (name of candidateViewItem as text) is "View" then
                    repeat with candidateViewMenu in menus of candidateViewItem
                      repeat with candidateAction in menu items of candidateViewMenu
                        try
                          if (name of candidateAction as text) is "Exit Coherence" then
                            set exitActionCount to exitActionCount + 1
                          end if
                        end try
                      end repeat
                    end repeat
                  end if
                end try
              end repeat
              if exitActionCount is greater than 0 then
                set end of candidatePids to (unix id of candidateProcess) as integer
                set candidateActionCount to candidateActionCount + exitActionCount
              end if
            end if
          end if
        end if
      end try
    end repeat

    if (count of candidatePids) is not 1 then error "Expected exactly one VM-bound Coherence helper."
    if candidateActionCount is not 1 then error "Expected exactly one Exit Coherence action."

    set targetPid to item 1 of candidatePids as integer
    set targetProcesses to every application process whose unix id is my targetPid
    if (count of targetProcesses) is not 1 then error "The VM-bound Coherence helper changed."
    set targetProcess to item 1 of targetProcesses
    set actionCoordinates to {}

    tell targetProcess
      set targetMenuItems to menu bar items of menu bar 1
      if (count of targetMenuItems) is less than 2 then error "The VM-bound menu bar changed."
      if (name of item 2 of targetMenuItems as text) is not vmName then error "The VM-bound menu name changed."
      repeat with viewIndex from 1 to count of targetMenuItems
        set targetViewItem to item viewIndex of targetMenuItems
        try
          if (name of targetViewItem as text) is "View" then
            set targetViewMenus to menus of targetViewItem
            repeat with menuIndex from 1 to count of targetViewMenus
              set targetViewMenu to item menuIndex of targetViewMenus
              set targetActions to menu items of targetViewMenu
              repeat with actionIndex from 1 to count of targetActions
                try
                  if (name of item actionIndex of targetActions as text) is "Exit Coherence" then
                    set end of actionCoordinates to {viewIndex, menuIndex, actionIndex}
                  end if
                end try
              end repeat
            end repeat
          end if
        end try
      end repeat
    end tell

    if (count of actionCoordinates) is not 1 then error "The Exit Coherence action changed."
    set actionCoordinate to item 1 of actionCoordinates
    set viewIndex to item 1 of actionCoordinate
    set menuIndex to item 2 of actionCoordinate
    set actionIndex to item 3 of actionCoordinate
    tell targetProcess
      set frontmost to true
      set targetAction to menu item actionIndex of menu menuIndex of menu bar item viewIndex of menu bar 1
      if (name of targetAction as text) is not "Exit Coherence" then error "The Exit Coherence action changed before invocation."
      click targetAction
    end tell
  end tell
end run
APPLESCRIPT
  then
    # A concurrent transition, including a click that completed while AX
    # reported failure, is accepted only if the exact VM window now exists.
    "$window_id_binary" "$vm_name" >/dev/null 2>&1 && return 0
    return 1
  fi

  # The state-changing action above is never replayed. Wait only for the exact
  # bundle-ID-bound Parallels window created by that one transition.
  for _ in $(seq 1 30); do
    "$window_id_binary" "$vm_name" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

show_vm_console() {
  local _=""
  for _ in $(seq 1 30); do
    if osascript - "$vm_name" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  set vmName to item 1 of argv
  tell application id "com.parallels.desktop.console" to activate
  tell application "System Events"
    set parallelsProcesses to every application process whose bundle identifier is "com.parallels.desktop.console"
    if (count of parallelsProcesses) is not 1 then error "Expected one Parallels Desktop console process."
    tell item 1 of parallelsProcesses
      set frontmost to true
      click menu item vmName of menu "Window" of menu bar 1
    end tell
  end tell
end run
APPLESCRIPT
    then
      "$window_id_binary" "$vm_name" >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  return 1
}

focus_receipt_bound_eai_setup_window() {
  local output=""
  local expected_hash="${executable_hash:-}"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  output="$(guest_ps_run "$guest_normal_pid"$'\n'"$guest_normal_launch_receipt"$'\n'"$guest_executable_file"$'\n'"$expected_hash"$'\n' 2 <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

function ConvertTo-ComparableAppPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw 'A detached application path is empty.'
  }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

$pidFile = [Console]::In.ReadLine()
$receiptFile = [Console]::In.ReadLine()
$executableFile = [Console]::In.ReadLine()
$expectedHash = [Console]::In.ReadLine()
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsSystem -or $expectedHash -cnotmatch '^[0-9a-f]{64}$') {
  throw 'The EAI Setup focus trust inputs are invalid.'
}
foreach ($path in @($pidFile, $receiptFile, $executableFile)) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'An EAI Setup focus artifact is not a canonical regular file.'
  }
}
$pidText = (Get-Content -Raw -LiteralPath $pidFile).Trim()
$receipt = Get-Content -Raw -LiteralPath $receiptFile | ConvertFrom-Json
$executable = (Get-Content -Raw -LiteralPath $executableFile).Trim()
if ($pidText -cnotmatch '^[1-9][0-9]*$' -or
    $receipt.schemaVersion -cne 'eai-windows-detached-app-launch/v5' -or
    $receipt.status -cne 'launched' -or $receipt.mode -cne 'normal' -or
    [int]$receipt.processId -ne [int]$pidText -or
    $receipt.processOwnerSid -cne $identity.User.Value -or
    $receipt.executableSha256 -cne $expectedHash -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash.ToLowerInvariant() -cne $expectedHash) {
  throw 'The EAI Setup focus artifacts are not bound to the normal launch.'
}
$process = Get-Process -Id ([int]$pidText) -ErrorAction Stop
[void]$process.Handle
$startedAt = $process.StartTime.ToUniversalTime().ToString('o')
$cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
$ownerSid = Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop
$expectedCommandLine = '"' + $executable + '"'
$expectedComparablePath = ConvertTo-ComparableAppPath $executable
try { $actualComparablePath = ConvertTo-ComparableAppPath $process.Path }
catch { throw 'The EAI Setup process path is unavailable for focus.' }
if ($process.HasExited -or $process.SessionId -ne [int]$receipt.processSessionId -or
    -not [string]::Equals($actualComparablePath, $expectedComparablePath, [StringComparison]::OrdinalIgnoreCase) -or
    $startedAt -cne [string]$receipt.processStartedAt -or
    $ownerSid.ReturnValue -ne 0 -or $ownerSid.Sid -cne $identity.User.Value -or
    [string]$cim.CommandLine -cne $expectedCommandLine -or
    $process.MainWindowHandle -eq [IntPtr]::Zero) {
  throw 'The EAI Setup window is not bound to the exact live process receipt.'
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EaiReleaseWindowFocus {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
$terminalRoot = (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.WindowsTerminal_')
foreach ($terminal in @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)) {
  try {
    if ($terminal.SessionId -ne $process.SessionId -or $terminal.MainWindowHandle -eq [IntPtr]::Zero) { continue }
    $terminalPath = $terminal.Path
    $terminalCim = Get-CimInstance Win32_Process -Filter "ProcessId = $($terminal.Id)" -ErrorAction Stop
    $terminalOwnerSid = Invoke-CimMethod -InputObject $terminalCim -MethodName GetOwnerSid -ErrorAction Stop
    if ($terminalOwnerSid.ReturnValue -eq 0 -and $terminalOwnerSid.Sid -ceq $identity.User.Value -and
        $terminalPath.StartsWith($terminalRoot, [StringComparison]::OrdinalIgnoreCase) -and
        $terminalPath.EndsWith('\WindowsTerminal.exe', [StringComparison]::OrdinalIgnoreCase)) {
      [void][EaiReleaseWindowFocus]::ShowWindowAsync($terminal.MainWindowHandle, 6)
    }
  } finally {
    $terminal.Dispose()
  }
}
$window = $process.MainWindowHandle
[void][EaiReleaseWindowFocus]::ShowWindowAsync($window, 9)
[void][EaiReleaseWindowFocus]::SetForegroundWindow($window)
for ($poll = 0; $poll -lt 20 -and [EaiReleaseWindowFocus]::GetForegroundWindow() -ne $window; $poll++) {
  Start-Sleep -Milliseconds 100
}
if ([EaiReleaseWindowFocus]::GetForegroundWindow() -ne $window) {
  throw 'The exact EAI Setup window could not be proven in the foreground.'
}
$process.Dispose()
[Console]::Out.WriteLine('EAI_SETUP_RECEIPT_BOUND_WINDOW_FOCUSED')
POWERSHELL
  )" || return 1
  printf '%s\n' "$output" | /usr/bin/tr -d '\r' \
    | /usr/bin/grep -Fqx 'EAI_SETUP_RECEIPT_BOUND_WINDOW_FOCUSED'
}

screen_has() {
  local pattern="$1"
  local screenshot="$work_dir/screen.png"
  local status=2
  focus_receipt_bound_eai_setup_window || return 1
  if prlctl capture "$vm_name" --file "$screenshot" >/dev/null 2>&1; then
    set +e
    EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
    status=$?
    set -e
  fi
  if [[ "$status" != 0 ]]; then
    if capture_vm_window "$screenshot"; then
      set +e
      EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
      status=$?
      set -e
    fi
  fi
  rm -f "$screenshot"
  [[ "$status" == 0 ]]
}

unexpected_prerequisite_uac_visible() {
  local screenshot="$work_dir/prerequisite-uac.png"
  local pattern=""
  local status=0
  local matches=0
  capture_vm_window "$screenshot" || return 2
  for pattern in 'User Account Control' 'Do you want to allow' 'changes to your device?'; do
    set +e
    EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      matches=$((matches + 1))
    elif [[ "$status" != 1 ]]; then
      rm -f "$screenshot"
      return 2
    fi
  done
  rm -f "$screenshot"
  [[ "$matches" == 0 ]] && return 1
  # Treat even a partial generic UAC signature as unexpected. OCR must
  # successfully prove all three public phrases absent before the monitor
  # reports a clean frame.
  return 0
}

start_prerequisite_uac_watcher() {
  local stop_file="$work_dir/prerequisite-uac-watcher.stop"
  local failure_file="$work_dir/prerequisite-uac-watcher.failed"
  local log_file="$work_dir/prerequisite-uac-watcher.log"
  rm -f "$stop_file" "$failure_file" "$log_file"
  (
    while [[ ! -e "$stop_file" ]]; do
      if unexpected_prerequisite_uac_visible; then
        printf '%s unexpected-uac-consent-ui\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$failure_file"
        exit 2
      else
        monitor_status=$?
      fi
      if [[ "$monitor_status" != 1 ]]; then
        printf '%s consent-ui-monitor-infrastructure-failed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$failure_file"
        exit 2
      fi
      sleep 1
    done
  ) >"$log_file" 2>&1 &
  uac_watcher_pid=$!
  uac_watcher_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

prerequisite_uac_watcher_alive() {
  [[ -n "$uac_watcher_pid" ]] \
    && [[ ! -e "$work_dir/prerequisite-uac-watcher.failed" ]] \
    && kill -0 "$uac_watcher_pid" >/dev/null 2>&1
}

stop_prerequisite_uac_watcher() {
  local watcher_status=0
  local evidence_dir=""
  [[ -n "$uac_watcher_pid" ]] || return 0
  : >"$work_dir/prerequisite-uac-watcher.stop"
  for _ in $(seq 1 20); do
    kill -0 "$uac_watcher_pid" >/dev/null 2>&1 || break
    sleep 0.25
  done
  if kill -0 "$uac_watcher_pid" >/dev/null 2>&1; then
    kill "$uac_watcher_pid" >/dev/null 2>&1 || true
  fi
  wait "$uac_watcher_pid" >/dev/null 2>&1 || watcher_status=$?
  uac_watcher_pid=""
  if [[ -n "${EAI_VM_RESULT_FILE:-}" && -f "$work_dir/prerequisite-uac-watcher.log" ]]; then
    evidence_dir="$(dirname "$EAI_VM_RESULT_FILE")"
    sanitize_log_file "$work_dir/prerequisite-uac-watcher.log" \
      "$evidence_dir/windows-prerequisite-uac-watcher.log" || true
  fi
  if [[ "$watcher_status" == 0 && -n "$evidence_dir" ]]; then
    EAI_UAC_MONITOR_RECEIPT="$evidence_dir/windows-uac-consent-ui-monitor.json" \
    EAI_UAC_MONITOR_STARTED_AT="$uac_watcher_started_at" \
    EAI_UAC_MONITOR_RUN_BINDING="$uac_policy_run_binding" \
      node --input-type=module <<'NODE' || watcher_status=1
import { writeFileSync } from "node:fs";
if (!Number.isFinite(Date.parse(process.env.EAI_UAC_MONITOR_STARTED_AT || "")) ||
    !/^[0-9a-f]{64}$/.test(process.env.EAI_UAC_MONITOR_RUN_BINDING || "")) {
  throw new Error("The consent-UI monitor receipt is not bound to this run.");
}
writeFileSync(process.env.EAI_UAC_MONITOR_RECEIPT, `${JSON.stringify({
  schemaVersion: "eai-windows-uac-consent-ui-monitor/v1",
  runBindingSha256: process.env.EAI_UAC_MONITOR_RUN_BINDING,
  startedAt: process.env.EAI_UAC_MONITOR_STARTED_AT,
  stoppedAt: new Date().toISOString(),
  unexpectedConsentUiDetected: false,
  approvalInputSent: false,
  uacApprovalCount: 0,
  monitorExitedCleanly: true,
}, null, 2)}\n`, { mode: 0o600 });
NODE
  fi
  uac_watcher_started_at=""
  [[ "$watcher_status" == 0 ]]
}

write_powershell_payload_wrapper() {
  local stdin_payload="$1"
  local script="$2"
  local payload_base64=""
  payload_base64="$(printf '%s' "$stdin_payload" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  # shellcheck disable=SC2016 # These are literal PowerShell expressions.
  printf '%s\n' \
    '& {' \
    "\$__eaiHarnessInputValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload_base64'))" \
    '[Console]::SetIn([IO.StringReader]::new($__eaiHarnessInputValue))' \
    '$__eaiHarnessInputValue = $null' \
    "$script" \
    '}' \
    ''
}

is_parallels_session_open_failure() {
  local normalized=""
  normalized="$(printf '%s' "$1" | /usr/bin/tr -d '\r')"
  case "$normalized" in
    'PrlVmGuest_RunProgram: Invalid argument'|\
    'PrlVmGuest_RunProgram: Unable to open new session in this virtual machine. Make sure your virtual machine has finished booting, runs the latest version of Parallels Tools, and is not isolated from the host OS.')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_parallels_ambiguous_launch_result_failure() {
  local status="$1"
  local normalized=""
  [[ "$status" == 255 ]] || return 1
  normalized="$(printf '%s' "$2" | /usr/bin/tr -d '\r')"
  case "$normalized" in
    'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.'|\
    'PrlJob_GetResult: Invalid argument. An invalid argument was passed.')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

guest_ps_run() {
  local stdin_payload="$1"
  local max_attempts="${2:-30}"
  local script=""
  local output=""
  local status=1
  local attempt
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || return 2
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  for attempt in $(seq 1 "$max_attempts"); do
    set +e
    output="$(printf '%s\n' "$script" | windows_hidden_current_user_ps "$vm_name" "$stdin_payload" 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if is_parallels_session_open_failure "$output"; then
      if [[ "$attempt" -ge "$max_attempts" ]]; then
        break
      fi
      if [[ "$attempt" == 1 || $((attempt % 5)) == 0 ]]; then
        printf '%s current-user PowerShell session unavailable; retry %s/%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$attempt" "$max_attempts" >&2
      fi
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

guest_ps() {
  local max_attempts="${1:-30}"
  local script=""
  local output=""
  local status=1
  local attempt
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || return 2
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  for attempt in $(seq 1 "$max_attempts"); do
    set +e
    # Keep large no-payload scripts off the Parallels argv. Windows
    # PowerShell's `-Command -` parser needs one coherent script block and the
    # trailing blank line to execute a final multi-line statement over stdin.
    output="$(printf '%s\n' "$script" | windows_hidden_current_user_ps "$vm_name" "" 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if is_parallels_session_open_failure "$output"; then
      if [[ "$attempt" -ge "$max_attempts" ]]; then
        break
      fi
      if [[ "$attempt" == 1 || $((attempt % 5)) == 0 ]]; then
        printf '%s streamed current-user PowerShell session unavailable; retry %s/%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$attempt" "$max_attempts" >&2
      fi
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

# Parallels can reject a direct powershell.exe guest session while the same
# protected LocalSystem channel remains available through cmd.exe. /D disables
# cmd AutoRun hooks; PowerShell still performs the operation and retains every
# in-script LocalSystem/administrator identity assertion.
guest_system_ps_run() {
  local stdin_payload="$1"
  local max_attempts="${2:-5}"
  local script=""
  local output=""
  local status=1
  local attempt
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || return 2
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  for attempt in $(seq 1 "$max_attempts"); do
    set +e
    output="$(write_powershell_payload_wrapper "$stdin_payload" "$script" \
      | prlctl exec "$vm_name" cmd.exe /D /S /C powershell.exe \
      -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -InputFormat Text -OutputFormat Text -Command - 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if is_parallels_session_open_failure "$output"; then
      [[ "$attempt" -lt "$max_attempts" ]] || break
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

guest_system_ps() {
  local script=""
  local output=""
  local status=1
  local attempt
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  for attempt in $(seq 1 5); do
    set +e
    output="$(printf '& {\n%s\n}\n\n' "$script" | prlctl exec "$vm_name" cmd.exe /D /S /C powershell.exe \
      -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -InputFormat Text -OutputFormat Text -Command - 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if is_parallels_session_open_failure "$output"; then
      [[ "$attempt" -lt 5 ]] || break
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

guest_system_ps_once() {
  local script=""
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  printf '& {\n%s\n}\n\n' "$script" | prlctl exec "$vm_name" cmd.exe /D /S /C powershell.exe \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -InputFormat Text -OutputFormat Text -Command -
}

write_uac_policy_arm_receipt() {
  local arm_json="$1"
  local receipt_file=""
  receipt_file="$(dirname "$EAI_VM_RESULT_FILE")/windows-uac-consent-policy.json"
  EAI_UAC_POLICY_RECEIPT="$receipt_file" \
  EAI_UAC_POLICY_ARM_JSON="$arm_json" \
    node --input-type=module <<'NODE'
import { writeFileSync } from "node:fs";
const receipt = JSON.parse(process.env.EAI_UAC_POLICY_ARM_JSON);
if (receipt.schemaVersion !== "eai-windows-uac-consent-policy/v1" ||
    !/^[0-9a-f]{32}$/.test(receipt.nonce || "") ||
    !/^[0-9a-f]{64}$/.test(receipt.runBindingSha256 || "") ||
    receipt.registryPath !== "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" ||
    receipt.valueName !== "ConsentPromptBehaviorAdmin" ||
    receipt.before?.consentPromptBehaviorAdmin?.kind !== "DWord" ||
    receipt.before?.consentPromptBehaviorAdmin?.value !== 5 ||
    receipt.before?.promptOnSecureDesktop?.kind !== "DWord" ||
    receipt.before?.promptOnSecureDesktop?.value !== 0 ||
    receipt.before?.enableLUA?.kind !== "DWord" || receipt.before?.enableLUA?.value !== 1 ||
    receipt.after?.consentPromptBehaviorAdmin?.kind !== "DWord" ||
    receipt.after?.consentPromptBehaviorAdmin?.value !== 0 ||
    receipt.after?.promptOnSecureDesktop?.kind !== "DWord" ||
    receipt.after?.promptOnSecureDesktop?.value !== 0 ||
    receipt.after?.enableLUA?.kind !== "DWord" || receipt.after?.enableLUA?.value !== 1 ||
    receipt.mutationPerformed !== true ||
    receipt.localSystem !== true || receipt.administrator !== true ||
    !Number.isFinite(Date.parse(receipt.changedAt))) {
  throw new Error("The LocalSystem UAC consent-policy application receipt is invalid.");
}
writeFileSync(process.env.EAI_UAC_POLICY_RECEIPT, `${JSON.stringify({
  ...receipt,
  scope: "machine-wide temporary admin-consent window bounded by the Windows adapter",
  diagnosticOnly: true,
  productionGate: false,
  uacConsentUiCovered: false,
  policyTemporarilyRelaxed: true,
  approvalInputSent: false,
  uacApprovalCount: 0,
  restorationRequired: true,
  restorationVerified: false,
}, null, 2)}\n`, { mode: 0o600 });
NODE
}

compute_uac_policy_run_binding() {
  [[ "${host_hash:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'vm=%s\nsnapshot=%s\nrelease=%s\nproject=%s\nasset=%s\n' \
    "$vm_name" "$snapshot_id" "$EAI_RELEASE_VERSION" "$EAI_VM_PROJECT_NAME" "$host_hash" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

arm_temporary_admin_consent_suppression() {
  local arm_json=""
  # From this point onward cleanup must restore the approved value even if the
  # mutation succeeds but a later verification or evidence write fails.
  uac_policy_nonce="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$uac_policy_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  uac_policy_run_binding="$(compute_uac_policy_run_binding)" || return 1
  [[ "$uac_policy_run_binding" =~ ^[0-9a-f]{64}$ ]] || return 1
  uac_consent_restore_required=1
  arm_json="$(guest_system_ps_run "$uac_policy_nonce"$'\n'"$uac_policy_run_binding"$'\n' 5 <<'POWERSHELL' | tr -d '\r' | tail -n 1
$ErrorActionPreference = 'Stop'
$nonce = [Console]::In.ReadLine()
$runBinding = [Console]::In.ReadLine()
if ($nonce -cnotmatch '^[0-9a-f]{32}$') { throw 'The UAC consent-policy nonce is invalid.' }
if ($runBinding -cnotmatch '^[0-9a-f]{64}$') { throw 'The UAC consent-policy run binding is invalid.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -or
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'The UAC consent-policy change is not running as an administrative LocalSystem process.'
}
$path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$item = Get-Item -LiteralPath $path -ErrorAction Stop
$beforeConsentKind = $item.GetValueKind('ConsentPromptBehaviorAdmin')
$beforeConsentValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'ConsentPromptBehaviorAdmin' -ErrorAction Stop)
$beforeDesktopKind = $item.GetValueKind('PromptOnSecureDesktop')
$beforeDesktopValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'PromptOnSecureDesktop' -ErrorAction Stop)
$beforeEnableKind = $item.GetValueKind('EnableLUA')
$beforeEnableValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'EnableLUA' -ErrorAction Stop)
if ($beforeConsentKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $beforeConsentValue -ne 5 -or
    $beforeDesktopKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $beforeDesktopValue -ne 0 -or
    $beforeEnableKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $beforeEnableValue -ne 1) {
  throw 'The approved UAC policy baseline changed before the bounded consent-policy mutation.'
}
Set-ItemProperty -LiteralPath $path -Name 'ConsentPromptBehaviorAdmin' -Value ([int]0) -Type DWord -ErrorAction Stop
$afterConsentKind = $item.GetValueKind('ConsentPromptBehaviorAdmin')
$afterConsentValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'ConsentPromptBehaviorAdmin' -ErrorAction Stop)
$afterDesktopKind = $item.GetValueKind('PromptOnSecureDesktop')
$afterDesktopValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'PromptOnSecureDesktop' -ErrorAction Stop)
$afterEnableKind = $item.GetValueKind('EnableLUA')
$afterEnableValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'EnableLUA' -ErrorAction Stop)
if ($afterConsentKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $afterConsentValue -ne 0) {
  throw 'The temporary no-prompt administrator consent behavior could not be verified.'
}
if ($afterDesktopKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $afterDesktopValue -ne 0 -or
    $afterEnableKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $afterEnableValue -ne 1) {
  throw 'A preserved UAC policy changed during the bounded consent-policy mutation.'
}
[ordered]@{
  schemaVersion = 'eai-windows-uac-consent-policy/v1'
  nonce = $nonce
  runBindingSha256 = $runBinding
  registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  valueName = 'ConsentPromptBehaviorAdmin'
  before = [ordered]@{
    consentPromptBehaviorAdmin = [ordered]@{ kind = [string]$beforeConsentKind; value = $beforeConsentValue }
    promptOnSecureDesktop = [ordered]@{ kind = [string]$beforeDesktopKind; value = $beforeDesktopValue }
    enableLUA = [ordered]@{ kind = [string]$beforeEnableKind; value = $beforeEnableValue }
  }
  after = [ordered]@{
    consentPromptBehaviorAdmin = [ordered]@{ kind = [string]$afterConsentKind; value = $afterConsentValue }
    promptOnSecureDesktop = [ordered]@{ kind = [string]$afterDesktopKind; value = $afterDesktopValue }
    enableLUA = [ordered]@{ kind = [string]$afterEnableKind; value = $afterEnableValue }
  }
  mutationPerformed = $true
  localSystem = $true
  administrator = $true
  changedAt = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Compress
POWERSHELL
)" || return 1
  write_uac_policy_arm_receipt "$arm_json" || return 1
}

restore_admin_consent_prompt() {
  local receipt_file=""
  local restore_json=""
  [[ "$uac_consent_restore_required" == 1 ]] || return 0
  [[ "$uac_policy_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "$uac_policy_run_binding" =~ ^[0-9a-f]{64}$ ]] || return 1
  restore_json="$(guest_system_ps_run "$uac_policy_nonce"$'\n'"$uac_policy_run_binding"$'\n' 5 <<'POWERSHELL' | tr -d '\r' | tail -n 1
$ErrorActionPreference = 'Stop'
$nonce = [Console]::In.ReadLine()
$runBinding = [Console]::In.ReadLine()
if ($nonce -cnotmatch '^[0-9a-f]{32}$') { throw 'The UAC consent-policy restoration nonce is invalid.' }
if ($runBinding -cnotmatch '^[0-9a-f]{64}$') { throw 'The UAC consent-policy restoration run binding is invalid.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -or
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'The UAC consent-policy restoration is not running as an administrative LocalSystem process.'
}
$path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$item = Get-Item -LiteralPath $path -ErrorAction Stop
$beforeConsentKind = $item.GetValueKind('ConsentPromptBehaviorAdmin')
$beforeConsentValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'ConsentPromptBehaviorAdmin' -ErrorAction Stop)
$beforeDesktopKind = $item.GetValueKind('PromptOnSecureDesktop')
$beforeDesktopValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'PromptOnSecureDesktop' -ErrorAction Stop)
$beforeEnableKind = $item.GetValueKind('EnableLUA')
$beforeEnableValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'EnableLUA' -ErrorAction Stop)
if ($beforeConsentKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $beforeConsentValue -notin @(0, 5)) {
  throw 'The UAC consent-policy restoration found an unexpected current value.'
}
if ($beforeConsentValue -eq 0) {
  Set-ItemProperty -LiteralPath $path -Name 'ConsentPromptBehaviorAdmin' -Value ([int]5) -Type DWord -ErrorAction Stop
}
$afterConsentKind = $item.GetValueKind('ConsentPromptBehaviorAdmin')
$afterConsentValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'ConsentPromptBehaviorAdmin' -ErrorAction Stop)
$afterDesktopKind = $item.GetValueKind('PromptOnSecureDesktop')
$afterDesktopValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'PromptOnSecureDesktop' -ErrorAction Stop)
$afterEnableKind = $item.GetValueKind('EnableLUA')
$afterEnableValue = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'EnableLUA' -ErrorAction Stop)
if ($afterConsentKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $afterConsentValue -ne 5 -or
    $afterDesktopKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $afterDesktopValue -ne 0 -or
    $afterEnableKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $afterEnableValue -ne 1) {
  throw 'The approved UAC consent-policy baseline could not be restored and verified.'
}
[ordered]@{
  schemaVersion = 'eai-windows-uac-consent-policy-restore/v1'
  nonce = $nonce
  runBindingSha256 = $runBinding
  before = [ordered]@{
    consentPromptBehaviorAdmin = [ordered]@{ kind = [string]$beforeConsentKind; value = $beforeConsentValue }
    promptOnSecureDesktop = [ordered]@{ kind = [string]$beforeDesktopKind; value = $beforeDesktopValue }
    enableLUA = [ordered]@{ kind = [string]$beforeEnableKind; value = $beforeEnableValue }
  }
  after = [ordered]@{
    consentPromptBehaviorAdmin = [ordered]@{ kind = [string]$afterConsentKind; value = $afterConsentValue }
    promptOnSecureDesktop = [ordered]@{ kind = [string]$afterDesktopKind; value = $afterDesktopValue }
    enableLUA = [ordered]@{ kind = [string]$afterEnableKind; value = $afterEnableValue }
  }
  mutationPerformed = ($beforeConsentValue -eq 0)
  localSystem = $true
  administrator = $true
  restoredAt = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Compress
POWERSHELL
)" || return 1
  receipt_file="$(dirname "$EAI_VM_RESULT_FILE")/windows-uac-consent-policy.json"
  EAI_UAC_POLICY_RECEIPT="$receipt_file" \
  EAI_UAC_POLICY_RESTORE_JSON="$restore_json" \
    node --input-type=module <<'NODE' || return 1
import { readFileSync, writeFileSync } from "node:fs";
const path = process.env.EAI_UAC_POLICY_RECEIPT;
const receipt = JSON.parse(readFileSync(path, "utf8"));
const restoration = JSON.parse(process.env.EAI_UAC_POLICY_RESTORE_JSON);
if (receipt.schemaVersion !== "eai-windows-uac-consent-policy/v1" ||
    receipt.valueName !== "ConsentPromptBehaviorAdmin" ||
    receipt.before?.consentPromptBehaviorAdmin?.kind !== "DWord" ||
    receipt.before?.consentPromptBehaviorAdmin?.value !== 5 ||
    receipt.after?.consentPromptBehaviorAdmin?.kind !== "DWord" ||
    receipt.after?.consentPromptBehaviorAdmin?.value !== 0 ||
    receipt.mutationPerformed !== true ||
    receipt.restorationRequired !== true ||
    restoration.schemaVersion !== "eai-windows-uac-consent-policy-restore/v1" ||
    restoration.nonce !== receipt.nonce ||
    restoration.runBindingSha256 !== receipt.runBindingSha256 ||
    restoration.before?.consentPromptBehaviorAdmin?.kind !== "DWord" ||
    restoration.before?.consentPromptBehaviorAdmin?.value !== 0 ||
    restoration.after?.consentPromptBehaviorAdmin?.kind !== "DWord" ||
    restoration.after?.consentPromptBehaviorAdmin?.value !== 5 ||
    restoration.after?.promptOnSecureDesktop?.kind !== "DWord" ||
    restoration.after?.promptOnSecureDesktop?.value !== 0 ||
    restoration.after?.enableLUA?.kind !== "DWord" ||
    restoration.after?.enableLUA?.value !== 1 ||
    restoration.mutationPerformed !== true ||
    restoration.localSystem !== true || restoration.administrator !== true ||
    !Number.isFinite(Date.parse(restoration.restoredAt)) ||
    Date.parse(receipt.changedAt) > Date.parse(restoration.restoredAt)) {
  throw new Error("The UAC consent-policy receipt cannot be safely finalized.");
}
writeFileSync(path, `${JSON.stringify({
  ...receipt,
  restoration,
  currentlyRelaxed: false,
  restorationRequired: false,
  restorationVerified: true,
}, null, 2)}\n`, { mode: 0o600 });
NODE
  uac_consent_restore_required=0
}

start_installer_bridge() {
  local expected_hash="$1"
  local expected_user="$2"
  local worker_script=""
  local worker_hash=""
  local worker_nonce=""
  local worker_base64=""
  local bootstrap_script=""
  local bootstrap_pid=""
  local bridge_stdout="$work_dir/installer-bridge.stdout"
  local bridge_stderr="$work_dir/installer-bridge.stderr"
  local bootstrap_status_file="$work_dir/installer-bridge-bootstrap.status"
  local bootstrap_status=1
  local attempt
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_user" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  worker_nonce="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  worker_script="$(/bin/cat <<'POWERSHELL'
param(
  [Parameter(Mandatory = $true)][string]$ExpectedWorkerSha256,
  [Parameter(Mandatory = $true)][int]$ExpectedSessionId
)
$ErrorActionPreference = 'Stop'
$expectedSha256 = '__EXPECTED_SHA256__'
$expectedUser = '__EXPECTED_USER__'
$expectedWorkerNonce = '__EXPECTED_WORKER_NONCE__'
$expectedWorkerSha256 = $ExpectedWorkerSha256.ToLowerInvariant()
$expectedSessionId = $ExpectedSessionId
$workerScriptPath = 'C:\Users\Public\eai-setup-installer-worker.ps1'
$workerScriptTemporary = 'C:\Users\Public\eai-setup-installer-worker.ps1.tmp'
$targetPath = 'C:\Users\Public\eai-setup-under-test.exe'
$armedReceipt = 'C:\Users\Public\eai-setup-installer-bridge-armed.json'
$armedReceiptTemporary = 'C:\Users\Public\eai-setup-installer-bridge-armed.json.tmp'
$launchSignal = 'C:\Users\Public\eai-setup-installer-launch.signal'
$launchSignalTemporary = 'C:\Users\Public\eai-setup-installer-launch.signal.tmp'
$cancelSignal = 'C:\Users\Public\eai-setup-installer-cancel.signal'
$cancelSignalTemporary = 'C:\Users\Public\eai-setup-installer-cancel.signal.tmp'
$completionReceipt = 'C:\Users\Public\eai-setup-installer-complete.json'
$completionReceiptTemporary = 'C:\Users\Public\eai-setup-installer-complete.json.tmp'
$defenderAddReceipt = 'C:\Users\Public\eai-setup-defender-add.json'
$defenderDoneSignal = 'C:\Users\Public\eai-setup-defender-done.signal'
$launchWaitSeconds = 300
$installerTimeoutSeconds = 300
$systemSid = 'S-1-5-18'
$bridgeStatus = 'failed'
$armedAt = $null
$installerStartedAt = $null
$completedAt = $null
$identityVerified = $false
$interactiveSessionVerified = $false
$workerScriptHashVerified = $false
$workerProcessPathVerified = $false
$workerSessionVerified = $false
$workerProcessId = $PID
$workerProcessStartedAt = $null
$workerProcessSessionId = $null
$targetAbsentWhenArmed = $false
$launchSignalSystemOwned = $false
$launchSignalHashBound = $false
$defenderReadyReceiptVerified = $false
$defenderCleanupNotRequestedAtLaunch = $false
$targetRegularFileVerified = $false
$targetHashVerified = $false
$targetLaunchLockVerified = $false
$launchStartInfoPathVerified = $false
$liveProcessPathVerified = $null
$liveProcessExitedBeforePathInspection = $false
$processPathVerified = $false
$installerStarted = $false
$installerExited = $false
$installerExitCode = $null
$installerProcessId = $null
$installerProcessStartedAt = $null
$installerProcessSessionId = $null
$cancelRequested = $false
$timedOut = $false
$exactProcessStopVerified = $false
$errorType = $null
$installerProcess = $null
$workerSourceLock = $null
$targetLaunchLock = $null

function Write-AtomicJson([string]$path, [string]$temporary, [System.Collections.IDictionary]$value) {
  if ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $temporary)) {
    throw "A fixed installer bridge receipt path is already occupied: $path"
  }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($value | ConvertTo-Json -Depth 6))
  $stream = $null
  try {
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  Move-Item -LiteralPath $temporary -Destination $path -ErrorAction Stop
}

function Assert-SystemSignal([string]$path, [string]$expectedValue) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'An installer bridge signal is not the exact canonical regular file.'
  }
  $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
  $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if ($ownerSid -cne $systemSid) {
    throw 'An installer bridge signal is not owned by LocalSystem.'
  }
  if ((Get-Content -Raw -LiteralPath $path).Trim() -cne $expectedValue) {
    throw 'An installer bridge signal is not bound to the expected release hash.'
  }
  return $true
}

function ConvertTo-ComparableWindowsPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw 'A Windows executable path is empty.'
  }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Stop-OwnedInstaller([Diagnostics.Process]$process) {
  if ($process.WaitForExit(0)) { return $true }
  $running = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
  if ($null -eq $running) {
    if ($process.WaitForExit(0)) { return $true }
    throw 'The owned installer process could not be resolved before cancellation.'
  }
  try {
    $runningPath = ConvertTo-ComparableWindowsPath $running.Path
    $runningSessionId = $running.SessionId
    $runningStartedAt = $running.StartTime.ToUniversalTime()
    $owner = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop) -MethodName GetOwnerSid -ErrorAction Stop
  } catch {
    # A fast installer can terminate between the zero-time wait and a process
    # property read. Its retained Process handle is authoritative for that
    # transition; never inspect or terminate a reused numeric PID.
    if ($process.WaitForExit(0)) { return $true }
    throw 'The owned installer process identity could not be verified before cancellation.'
  }
  if (-not [string]::Equals($runningPath, (ConvertTo-ComparableWindowsPath $targetPath), [StringComparison]::OrdinalIgnoreCase) -or
      $runningSessionId -ne $installerProcessSessionId -or
      $runningStartedAt -ne [DateTime]::Parse($installerProcessStartedAt).ToUniversalTime() -or
      $owner.Sid -cne $workerUserSid) {
    throw 'The installer PID tuple no longer identifies the exact owned release process; refusing to terminate it.'
  }
  Stop-Process -Id $process.Id -Force -ErrorAction Stop
  for ($stopPoll = 0; $stopPoll -lt 120; $stopPoll++) {
    if ($process.WaitForExit(250)) { return $true }
  }
  throw 'The exact owned installer process did not stop after cancellation.'
}

try {
  $fixedPaths = @(
    $targetPath,
    $workerScriptTemporary,
    $armedReceipt,
    $armedReceiptTemporary,
    $launchSignal,
    $launchSignalTemporary,
    $cancelSignal,
    $cancelSignalTemporary,
    $completionReceipt,
    $completionReceiptTemporary
  )
  if ($fixedPaths | Where-Object { Test-Path -LiteralPath $_ }) {
    throw 'The installer bridge requires an empty fixed-path baseline.'
  }
  if ($expectedWorkerSha256 -cnotmatch '^[0-9a-f]{64}$' -or $expectedWorkerNonce -cnotmatch '^[0-9a-f]{32}$') {
    throw 'The detached installer worker trust inputs are invalid.'
  }
  $workerItem = Get-Item -LiteralPath $workerScriptPath -ErrorAction Stop
  if ($workerItem.PSIsContainer -or (($workerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($workerItem.FullName, $workerScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The detached installer worker is not the exact canonical regular script.'
  }
  $workerSourceLock = [IO.File]::Open($workerScriptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $workerHashAlgorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $workerScriptHash = ([BitConverter]::ToString($workerHashAlgorithm.ComputeHash($workerSourceLock))).Replace('-', '').ToLowerInvariant()
    $workerSourceLock.Position = 0
  } finally {
    $workerHashAlgorithm.Dispose()
  }
  $workerScriptHashVerified = $workerScriptHash -ceq $expectedWorkerSha256
  if (-not $workerScriptHashVerified) {
    throw 'The detached installer worker script hash does not match its bootstrap payload.'
  }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $workerUserSid = $identity.User.Value
  $currentProcess = Get-Process -Id $PID -ErrorAction Stop
  $expectedPowerShellPath = Join-Path $PSHOME 'powershell.exe'
  try { $workerProcessPath = $currentProcess.Path } catch { throw 'The detached installer worker process path is unavailable.' }
  $workerProcessPathVerified = [string]::Equals($workerProcessPath, $expectedPowerShellPath, [StringComparison]::OrdinalIgnoreCase)
  $workerSessionVerified = $currentProcess.SessionId -eq $expectedSessionId
  $workerProcessStartedAt = $currentProcess.StartTime.ToUniversalTime().ToString('o')
  $workerProcessSessionId = $currentProcess.SessionId
  $sessionExplorer = Get-Process explorer -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq $expectedSessionId } | Select-Object -First 1
  $identityVerified = -not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -and
    $identity.Name.EndsWith("\$expectedUser", [StringComparison]::OrdinalIgnoreCase)
  $interactiveSessionVerified = [Environment]::UserInteractive -and $workerSessionVerified -and $null -ne $sessionExplorer
  $targetAbsentWhenArmed = -not (Test-Path -LiteralPath $targetPath)
  if (-not $identityVerified -or -not $interactiveSessionVerified -or -not $workerScriptHashVerified -or
      -not $workerProcessPathVerified -or -not $workerSessionVerified -or -not $targetAbsentWhenArmed) {
    throw 'The installer bridge is not running in the expected clean interactive user session.'
  }
  $armedAt = [DateTime]::UtcNow.ToString('o')
  Write-AtomicJson $armedReceipt $armedReceiptTemporary ([ordered]@{
    schemaVersion = 'eai-windows-installer-bridge/v1'
    status = 'armed'
    assetName = 'eai-setup-under-test.exe'
    assetSha256 = $expectedSha256
    identityVerified = $identityVerified
    interactiveSessionVerified = $interactiveSessionVerified
    workerScriptSha256 = $expectedWorkerSha256
    workerNonce = $expectedWorkerNonce
    workerScriptHashVerified = $workerScriptHashVerified
    workerProcessPathVerified = $workerProcessPathVerified
    workerSessionVerified = $workerSessionVerified
    workerProcessId = $workerProcessId
    workerProcessStartedAt = $workerProcessStartedAt
    workerProcessSessionId = $workerProcessSessionId
    targetAbsentWhenArmed = $targetAbsentWhenArmed
    launchWaitSeconds = $launchWaitSeconds
    installerTimeoutSeconds = $installerTimeoutSeconds
    recordedAt = $armedAt
  })

  $launchObserved = $false
  for ($launchPoll = 0; $launchPoll -lt ($launchWaitSeconds * 4); $launchPoll++) {
    if (Test-Path -LiteralPath $cancelSignal -PathType Leaf) {
      [void](Assert-SystemSignal $cancelSignal "cancel:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}")
      $cancelRequested = $true
      $bridgeStatus = 'cancelled-before-launch'
      break
    }
    if (Test-Path -LiteralPath $launchSignal -PathType Leaf) {
      [void](Assert-SystemSignal $launchSignal "launch:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}")
      $launchSignalSystemOwned = $true
      $launchSignalHashBound = $true
      $launchObserved = $true
      break
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $launchObserved -and -not $cancelRequested) {
    $timedOut = $true
    $bridgeStatus = 'launch-timeout'
  }

  if ($launchObserved) {
    if (Test-Path -LiteralPath $cancelSignal -PathType Leaf) {
      [void](Assert-SystemSignal $cancelSignal "cancel:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}")
      $cancelRequested = $true
      $bridgeStatus = 'cancelled-before-launch'
    } else {
      $defenderReceiptItem = Get-Item -LiteralPath $defenderAddReceipt -ErrorAction Stop
      if ($defenderReceiptItem.PSIsContainer -or
          (($defenderReceiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
          -not [string]::Equals($defenderReceiptItem.FullName, $defenderAddReceipt, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Defender ready receipt is not a regular file at installer launch.'
      }
      $defenderReceiptAcl = Get-Acl -LiteralPath $defenderAddReceipt -ErrorAction Stop
      if ($defenderReceiptAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid) {
        throw 'The Defender ready receipt is not owned by LocalSystem at installer launch.'
      }
      $defenderReceipt = Get-Content -Raw -LiteralPath $defenderAddReceipt | ConvertFrom-Json
      $defenderReadyReceiptVerified = $defenderReceipt.status -eq 'ready' -and
        $defenderReceipt.assetSha256 -ceq $expectedSha256 -and
        $defenderReceipt.scope -eq 'exact-file' -and
        $defenderReceipt.receiptSystemOwned -eq $true -and
        $defenderReceipt.precheckProbeVerified -eq $true -and
        $defenderReceipt.targetHashVerified -eq $true -and
        $defenderReceipt.mpCmdRunVerified -eq $true
      $defenderCleanupNotRequestedAtLaunch = -not (Test-Path -LiteralPath $defenderDoneSignal)
      if (-not $defenderReadyReceiptVerified -or -not $defenderCleanupNotRequestedAtLaunch) {
        throw 'The exact-file Defender allowance is not proven active at installer launch.'
      }

      $target = Get-Item -LiteralPath $targetPath -ErrorAction Stop
      $targetRegularFileVerified = -not $target.PSIsContainer -and
        (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
        [string]::Equals($target.FullName, $targetPath, [StringComparison]::OrdinalIgnoreCase)
      if (-not $targetRegularFileVerified) {
        throw 'The exact release installer is not a canonical regular file immediately before launch.'
      }
      $targetLaunchLock = [IO.File]::Open(
        $targetPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
      )
      $targetLaunchHasher = [Security.Cryptography.SHA256]::Create()
      try {
        $launchSha256 = ([BitConverter]::ToString($targetLaunchHasher.ComputeHash($targetLaunchLock))).Replace('-', '').ToLowerInvariant()
        $targetLaunchLock.Position = 0
      } finally {
        $targetLaunchHasher.Dispose()
      }
      $targetHashVerified = $launchSha256 -ceq $expectedSha256
      $targetLaunchLockVerified = $targetHashVerified -and $targetLaunchLock.Length -eq $target.Length
      if (-not $targetHashVerified) {
        throw 'The exact release installer hash changed immediately before launch.'
      }
      if (-not $targetLaunchLockVerified) {
        throw 'The exact release installer could not be locked against mutation across launch.'
      }

      $installerStartedAt = [DateTime]::UtcNow.ToString('o')
      $installerProcess = Start-Process -FilePath $targetPath -ArgumentList '/S' -PassThru
      $installerStarted = $true
      $installerProcessId = $installerProcess.Id
      $launchStartInfoPath = ConvertTo-ComparableWindowsPath $installerProcess.StartInfo.FileName
      $comparableTargetPath = ConvertTo-ComparableWindowsPath $targetPath
      $launchStartInfoPathVerified = [string]::Equals(
        $launchStartInfoPath,
        $comparableTargetPath,
        [StringComparison]::OrdinalIgnoreCase
      )
      if (-not $launchStartInfoPathVerified) {
        throw 'The launched installer start target does not match the locked release asset.'
      }

      # NSIS can exit between any two Process property reads. Preserve the
      # exact StartInfo binding separately, and require either a complete live
      # path/tuple observation or terminal state from the retained Process
      # handle. An access failure while the handle is still live remains fatal.
      if ($installerProcess.WaitForExit(0)) {
        $liveProcessExitedBeforePathInspection = $true
      } else {
        $liveProcessPath = $null
        try {
          $liveProcessPath = ConvertTo-ComparableWindowsPath $installerProcess.Path
          $installerProcessStartedAt = $installerProcess.StartTime.ToUniversalTime().ToString('o')
          $installerProcessSessionId = $installerProcess.SessionId
        } catch {
          if ($installerProcess.WaitForExit(0)) {
            $liveProcessExitedBeforePathInspection = $true
          } else {
            throw
          }
        }
        if ($null -ne $liveProcessPath) {
          $liveProcessPathVerified = [string]::Equals(
            $liveProcessPath,
            $comparableTargetPath,
            [StringComparison]::OrdinalIgnoreCase
          )
          if (-not $liveProcessPathVerified) {
            throw 'The live installer process does not match the locked release asset.'
          }
        }
      }
      $processPathVerified = $launchStartInfoPathVerified -and
        ($liveProcessPathVerified -eq $true -or $liveProcessExitedBeforePathInspection)
      if (-not $processPathVerified) {
        throw 'The installer process path could not be bound to the locked release asset.'
      }
      $targetLaunchLock.Dispose()
      $targetLaunchLock = $null

      for ($installerPoll = 0; $installerPoll -lt ($installerTimeoutSeconds * 4); $installerPoll++) {
        if ($installerProcess.WaitForExit(250)) { break }
        if (Test-Path -LiteralPath $cancelSignal -PathType Leaf) {
          [void](Assert-SystemSignal $cancelSignal "cancel:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}")
          $cancelRequested = $true
          $bridgeStatus = 'cancelled-during-install'
          $exactProcessStopVerified = Stop-OwnedInstaller $installerProcess
          break
        }
      }
      if (-not $installerProcess.WaitForExit(0) -and -not $cancelRequested) {
        $timedOut = $true
        $bridgeStatus = 'installer-timeout'
        $exactProcessStopVerified = Stop-OwnedInstaller $installerProcess
      }
      $installerExited = $installerProcess.WaitForExit(0)
      if (-not $installerExited) { throw 'The exact installer process remained active after its bounded wait.' }
      $installerExitCode = [int]$installerProcess.ExitCode
      if (-not $cancelRequested -and -not $timedOut) {
        $bridgeStatus = if ($installerExitCode -eq 0) { 'completed' } else { 'installer-failed' }
      }
    }
  }
} catch {
  $errorType = $_.Exception.GetType().FullName
  if ($bridgeStatus -eq 'failed') { $bridgeStatus = 'bridge-failed' }
} finally {
  if ($null -ne $installerProcess) {
    try {
      if (-not $installerProcess.WaitForExit(0)) {
        $exactProcessStopVerified = Stop-OwnedInstaller $installerProcess
      }
      $installerExited = $installerProcess.WaitForExit(0)
      if ($installerExited -and $null -eq $installerExitCode) {
        $installerExitCode = [int]$installerProcess.ExitCode
      }
    } catch {
      $errorType = $_.Exception.GetType().FullName
      $bridgeStatus = 'bridge-failed'
    }
  }
  $completedAt = [DateTime]::UtcNow.ToString('o')
  if (-not (Test-Path -LiteralPath $completionReceipt)) {
    Write-AtomicJson $completionReceipt $completionReceiptTemporary ([ordered]@{
      schemaVersion = 'eai-windows-installer-bridge/v1'
      status = $bridgeStatus
      assetName = 'eai-setup-under-test.exe'
      assetSha256 = $expectedSha256
      identityVerified = $identityVerified
      interactiveSessionVerified = $interactiveSessionVerified
      workerScriptSha256 = $expectedWorkerSha256
      workerNonce = $expectedWorkerNonce
      workerScriptHashVerified = $workerScriptHashVerified
      workerProcessPathVerified = $workerProcessPathVerified
      workerSessionVerified = $workerSessionVerified
      workerProcessId = $workerProcessId
      workerProcessStartedAt = $workerProcessStartedAt
      workerProcessSessionId = $workerProcessSessionId
      targetAbsentWhenArmed = $targetAbsentWhenArmed
      launchSignalSystemOwned = $launchSignalSystemOwned
      launchSignalHashBound = $launchSignalHashBound
      defenderReadyReceiptVerified = $defenderReadyReceiptVerified
      defenderCleanupNotRequestedAtLaunch = $defenderCleanupNotRequestedAtLaunch
      targetRegularFileVerified = $targetRegularFileVerified
      targetHashVerified = $targetHashVerified
      targetLaunchLockVerified = $targetLaunchLockVerified
      launchStartInfoPathVerified = $launchStartInfoPathVerified
      liveProcessPathVerified = $liveProcessPathVerified
      liveProcessExitedBeforePathInspection = $liveProcessExitedBeforePathInspection
      processPathVerified = $processPathVerified
      installerStarted = $installerStarted
      installerExited = $installerExited
      installerExitCode = $installerExitCode
      installerProcessId = $installerProcessId
      installerProcessStartedAt = $installerProcessStartedAt
      installerProcessSessionId = $installerProcessSessionId
      cancelRequested = $cancelRequested
      timedOut = $timedOut
      exactProcessStopVerified = $exactProcessStopVerified
      launchWaitSeconds = $launchWaitSeconds
      installerTimeoutSeconds = $installerTimeoutSeconds
      armedAt = $armedAt
      installerStartedAt = $installerStartedAt
      completedAt = $completedAt
      errorType = $errorType
    })
  }
  if ($null -ne $targetLaunchLock) { $targetLaunchLock.Dispose() }
  if ($null -ne $workerSourceLock) { $workerSourceLock.Dispose() }
}

if ($bridgeStatus -eq 'completed') { exit 0 }
exit 1
POWERSHELL
)"
  worker_script="${worker_script/__EXPECTED_SHA256__/$expected_hash}"
  worker_script="${worker_script/__EXPECTED_USER__/$expected_user}"
  worker_script="${worker_script/__EXPECTED_WORKER_NONCE__/$worker_nonce}"
  worker_hash="$(printf '%s' "$worker_script" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$worker_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  worker_base64="$(printf '%s' "$worker_script" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  [[ -n "$worker_base64" ]] || return 1
  bootstrap_script="$(/bin/cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$expectedSha256 = '__EXPECTED_SHA256__'
$expectedWorkerSha256 = '__EXPECTED_WORKER_SHA256__'
$expectedWorkerNonce = '__EXPECTED_WORKER_NONCE__'
$expectedUser = '__EXPECTED_USER__'
$workerScriptPath = 'C:\Users\Public\eai-setup-installer-worker.ps1'
$workerScriptTemporary = 'C:\Users\Public\eai-setup-installer-worker.ps1.tmp'
$armedReceipt = 'C:\Users\Public\eai-setup-installer-bridge-armed.json'
$temporaryOwned = $false
$stream = $null
$workerLoadLock = $null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentProcess = Get-Process -Id $PID -ErrorAction Stop
$sessionId = $currentProcess.SessionId
$identityVerified = -not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -and
  $identity.Name.EndsWith("\$expectedUser", [StringComparison]::OrdinalIgnoreCase)
$sessionExplorer = Get-Process explorer -ErrorAction SilentlyContinue |
  Where-Object { $_.SessionId -eq $sessionId } | Select-Object -First 1
if (-not $identityVerified -or -not [Environment]::UserInteractive -or $null -eq $sessionExplorer) {
  throw 'The detached installer bootstrap is not in the expected interactive user session.'
}
if ($expectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or $expectedWorkerSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $expectedWorkerNonce -cnotmatch '^[0-9a-f]{32}$') {
  throw 'The detached installer bootstrap hashes are invalid.'
}
$fixedPaths = @(
  'C:\Users\Public\eai-setup-under-test.exe',
  $workerScriptPath,
  $workerScriptTemporary,
  $armedReceipt,
  'C:\Users\Public\eai-setup-installer-bridge-armed.json.tmp',
  'C:\Users\Public\eai-setup-installer-launch.signal',
  'C:\Users\Public\eai-setup-installer-launch.signal.tmp',
  'C:\Users\Public\eai-setup-installer-cancel.signal',
  'C:\Users\Public\eai-setup-installer-cancel.signal.tmp',
  'C:\Users\Public\eai-setup-installer-complete.json',
  'C:\Users\Public\eai-setup-installer-complete.json.tmp'
)
if ($fixedPaths | Where-Object { Test-Path -LiteralPath $_ }) {
  throw 'The detached installer bootstrap requires an empty fixed-path baseline.'
}

$payloadBase64 = '__WORKER_PAYLOAD_BASE64__'
if ([string]::IsNullOrWhiteSpace($payloadBase64)) { throw 'The detached installer worker payload is missing.' }
try { $payload = [Convert]::FromBase64String($payloadBase64) } catch { throw 'The detached installer worker payload is not valid base64.' }
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
  $payloadSha256 = ([BitConverter]::ToString($sha256.ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
} finally {
  $sha256.Dispose()
}
if ($payloadSha256 -cne $expectedWorkerSha256) {
  throw 'The detached installer worker payload hash changed before staging.'
}

try {
  $stream = [IO.File]::Open($workerScriptTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $temporaryOwned = $true
  $stream.Write($payload, 0, $payload.Length)
  $stream.Flush($true)
  $stream.Dispose()
  $stream = $null
  $item = Get-Item -LiteralPath $workerScriptTemporary -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $workerScriptTemporary, [StringComparison]::OrdinalIgnoreCase) -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $workerScriptTemporary).Hash.ToLowerInvariant() -cne $expectedWorkerSha256) {
    throw 'The staged detached installer worker is not the exact verified regular file.'
  }
  Move-Item -LiteralPath $workerScriptTemporary -Destination $workerScriptPath -ErrorAction Stop
  $temporaryOwned = $false
} finally {
  if ($null -ne $stream) { $stream.Dispose() }
  if ($temporaryOwned -and (Test-Path -LiteralPath $workerScriptTemporary -PathType Leaf)) {
    $temporaryItem = Get-Item -LiteralPath $workerScriptTemporary -ErrorAction SilentlyContinue
    if ($null -ne $temporaryItem -and -not $temporaryItem.PSIsContainer -and
        (($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $workerScriptTemporary).Hash.ToLowerInvariant() -ceq $expectedWorkerSha256) {
      Remove-Item -Force -LiteralPath $workerScriptTemporary -ErrorAction SilentlyContinue
    }
  }
}

$workerItem = Get-Item -LiteralPath $workerScriptPath -ErrorAction Stop
if ($workerItem.PSIsContainer -or (($workerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($workerItem.FullName, $workerScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The detached installer worker could not be verified before launch.'
}
$powerShellPath = Join-Path $PSHOME 'powershell.exe'
$workerLoadLock = [IO.File]::Open($workerScriptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$lockedWorkerHasher = [Security.Cryptography.SHA256]::Create()
try {
  $lockedWorkerSha256 = ([BitConverter]::ToString($lockedWorkerHasher.ComputeHash($workerLoadLock))).Replace('-', '').ToLowerInvariant()
  $workerLoadLock.Position = 0
} finally {
  $lockedWorkerHasher.Dispose()
}
if ($lockedWorkerSha256 -cne $expectedWorkerSha256) {
  throw 'The locked detached installer worker hash changed before launch.'
}
$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerScriptPath -ExpectedWorkerSha256 $expectedWorkerSha256 -ExpectedSessionId $sessionId"
$launchedWorker = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
$launchedWorkerStartedAt = $launchedWorker.StartTime.ToUniversalTime().ToString('o')

$armed = $null
for ($poll = 0; $poll -lt 120; $poll++) {
  if (Test-Path -LiteralPath $armedReceipt -PathType Leaf) {
    try { $armed = Get-Content -Raw -LiteralPath $armedReceipt | ConvertFrom-Json } catch { $armed = $null }
    if ($null -ne $armed -and $armed.status -eq 'armed') { break }
  }
  Start-Sleep -Milliseconds 250
}
if ($null -eq $armed) { throw 'The detached installer worker did not arm during the bounded bootstrap.' }
$armedItem = Get-Item -LiteralPath $armedReceipt -ErrorAction Stop
if ($armedItem.PSIsContainer -or (($armedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($armedItem.FullName, $armedReceipt, [StringComparison]::OrdinalIgnoreCase) -or
    $armed.schemaVersion -ne 'eai-windows-installer-bridge/v1' -or $armed.status -ne 'armed' -or
    $armed.assetSha256 -cne $expectedSha256 -or
    $armed.workerScriptSha256 -cne $expectedWorkerSha256 -or $armed.workerNonce -cne $expectedWorkerNonce -or
    $armed.workerScriptHashVerified -ne $true -or
    $armed.workerProcessPathVerified -ne $true -or $armed.workerSessionVerified -ne $true -or
    $armed.identityVerified -ne $true -or $armed.interactiveSessionVerified -ne $true -or
    $armed.targetAbsentWhenArmed -ne $true -or $armed.workerProcessId -ne $launchedWorker.Id -or
    $armed.workerProcessStartedAt -cne $launchedWorkerStartedAt -or $armed.workerProcessSessionId -ne $sessionId) {
  throw 'The detached installer worker armed receipt is invalid.'
}
$launchedWorker.Refresh()
try { $workerProcessPath = $launchedWorker.Path } catch { throw 'The detached installer worker process path could not be verified.' }
if ($launchedWorker.HasExited -or $launchedWorker.SessionId -ne $sessionId -or
    -not [string]::Equals($workerProcessPath, $powerShellPath, [StringComparison]::OrdinalIgnoreCase) -or
    $launchedWorker.StartTime.ToUniversalTime() -ne [DateTime]::Parse($armed.workerProcessStartedAt).ToUniversalTime()) {
  throw 'The detached installer worker process identity does not match its receipt.'
}
$workerLoadLock.Dispose()
$workerLoadLock = $null
Write-Output "DETACHED_INSTALLER_WORKER_ARMED:$expectedWorkerSha256"
POWERSHELL
)"
  bootstrap_script="${bootstrap_script/__EXPECTED_SHA256__/$expected_hash}"
  bootstrap_script="${bootstrap_script/__EXPECTED_WORKER_SHA256__/$worker_hash}"
  bootstrap_script="${bootstrap_script/__EXPECTED_WORKER_NONCE__/$worker_nonce}"
  bootstrap_script="${bootstrap_script/__EXPECTED_USER__/$expected_user}"
  bootstrap_script="${bootstrap_script/__WORKER_PAYLOAD_BASE64__/$worker_base64}"
  printf '' >"$bridge_stdout"
  printf '' >"$bridge_stderr"
  /bin/unlink "$bootstrap_status_file" >/dev/null 2>&1 || true
  installer_bridge_pending=1
  installer_worker_hash="$worker_hash"
  installer_worker_nonce="$worker_nonce"
  (
    local attached_status=1
    set +e
    printf '%s\n' "$bootstrap_script" | windows_hidden_current_user_ps "$vm_name" "" \
      >"$bridge_stdout" 2>"$bridge_stderr"
    attached_status=$?
    set -e
    printf '%s\n' "$attached_status" >"$bootstrap_status_file"
    exit "$attached_status"
  ) &
  bootstrap_pid=$!
  for attempt in $(seq 1 90); do
    [[ -f "$bootstrap_status_file" ]] && break
    sleep 1
  done
  if [[ ! -f "$bootstrap_status_file" ]]; then
    cleanup_host_bridge "$bootstrap_pid"
    return 1
  fi
  bootstrap_status="$(tr -d '\r\n' <"$bootstrap_status_file")"
  if wait "$bootstrap_pid" >/dev/null 2>&1; then :; fi
  [[ "$bootstrap_status" == 0 ]] || return 1
  /usr/bin/tr -d '\r' <"$bridge_stdout" \
    | /usr/bin/grep -Fqx "DETACHED_INSTALLER_WORKER_ARMED:$worker_hash" \
    || return 1
}

write_installer_bridge_signal() {
  local action="$1"
  local expected_hash="$2"
  local expected_worker_hash="${installer_worker_hash:-}"
  local expected_worker_nonce="${installer_worker_nonce:-}"
  local signal_script=""
  [[ "$action" == launch || "$action" == cancel ]] || return 2
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_worker_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  signal_script="$(/bin/cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$action = '__SIGNAL_ACTION__'
$expectedSha256 = '__EXPECTED_SHA256__'
$expectedWorkerSha256 = '__EXPECTED_WORKER_SHA256__'
$expectedWorkerNonce = '__EXPECTED_WORKER_NONCE__'
$systemSid = 'S-1-5-18'
$targetPath = 'C:\Users\Public\eai-setup-under-test.exe'
$workerScriptPath = 'C:\Users\Public\eai-setup-installer-worker.ps1'
$armedReceipt = 'C:\Users\Public\eai-setup-installer-bridge-armed.json'
$defenderAddReceipt = 'C:\Users\Public\eai-setup-defender-add.json'
$launchSignal = 'C:\Users\Public\eai-setup-installer-launch.signal'
$launchSignalTemporary = 'C:\Users\Public\eai-setup-installer-launch.signal.tmp'
$cancelSignal = 'C:\Users\Public\eai-setup-installer-cancel.signal'
$cancelSignalTemporary = 'C:\Users\Public\eai-setup-installer-cancel.signal.tmp'
$temporaryOwned = $false

function Assert-SystemOwnedMarker([string]$path, [string]$expectedValue) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installer bridge marker is not the exact canonical regular file.'
  }
  $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid) {
    throw 'The installer bridge marker is not owned by LocalSystem.'
  }
  if ((Get-Content -Raw -LiteralPath $path).Trim() -cne $expectedValue) {
    throw 'The installer bridge marker is not bound to the expected release hash.'
  }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -or
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Installer bridge signals require the protected LocalSystem channel.'
}
if ($expectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'The installer bridge release hash is invalid.' }

if ($action -eq 'launch') {
  $finalPath = $launchSignal
  $temporaryPath = $launchSignalTemporary
  $expectedValue = "launch:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}"
  if ((Test-Path -LiteralPath $finalPath) -or (Test-Path -LiteralPath $temporaryPath) -or
      (Test-Path -LiteralPath $cancelSignal) -or (Test-Path -LiteralPath $cancelSignalTemporary)) {
    throw 'The one-shot installer launch marker paths are not empty.'
  }
  $armedItem = Get-Item -LiteralPath $armedReceipt -ErrorAction Stop
  if ($armedItem.PSIsContainer -or (($armedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($armedItem.FullName, $armedReceipt, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installer bridge armed receipt is not a canonical regular file.'
  }
  $armed = Get-Content -Raw -LiteralPath $armedReceipt | ConvertFrom-Json
  if ($armed.schemaVersion -ne 'eai-windows-installer-bridge/v1' -or $armed.status -ne 'armed' -or
      $armed.assetSha256 -cne $expectedSha256 -or $armed.identityVerified -ne $true -or
      $armed.interactiveSessionVerified -ne $true -or $armed.targetAbsentWhenArmed -ne $true -or
      $armed.workerScriptSha256 -cne $expectedWorkerSha256 -or $armed.workerNonce -cne $expectedWorkerNonce -or
      $armed.workerScriptHashVerified -ne $true -or
      $armed.workerProcessPathVerified -ne $true -or $armed.workerSessionVerified -ne $true -or
      $armed.workerProcessId -notmatch '^[1-9][0-9]*$') {
    throw 'The current-user installer bridge is not proven armed for this release asset.'
  }
  $workerScript = Get-Item -LiteralPath $workerScriptPath -ErrorAction Stop
  if ($workerScript.PSIsContainer -or (($workerScript.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($workerScript.FullName, $workerScriptPath, [StringComparison]::OrdinalIgnoreCase) -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $workerScriptPath).Hash.ToLowerInvariant() -cne $expectedWorkerSha256) {
    throw 'The detached installer worker script is not the exact bootstrap payload before launch signalling.'
  }
  $workerProcess = Get-Process -Id ([int]$armed.workerProcessId) -ErrorAction Stop
  try { $workerProcessPath = $workerProcess.Path } catch { throw 'The detached installer worker process path is unavailable before launch signalling.' }
  $expectedPowerShellPath = Join-Path $PSHOME 'powershell.exe'
  if (-not [string]::Equals($workerProcessPath, $expectedPowerShellPath, [StringComparison]::OrdinalIgnoreCase) -or
      $workerProcess.StartTime.ToUniversalTime() -ne [DateTime]::Parse($armed.workerProcessStartedAt).ToUniversalTime()) {
    throw 'The detached installer worker process identity changed before launch signalling.'
  }
  $defenderItem = Get-Item -LiteralPath $defenderAddReceipt -ErrorAction Stop
  if ($defenderItem.PSIsContainer -or (($defenderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($defenderItem.FullName, $defenderAddReceipt, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The Defender ready receipt is not a canonical regular file before launch signalling.'
  }
  $defenderAcl = Get-Acl -LiteralPath $defenderAddReceipt -ErrorAction Stop
  if ($defenderAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid) {
    throw 'The Defender ready receipt is not owned by LocalSystem before launch signalling.'
  }
  $defender = Get-Content -Raw -LiteralPath $defenderAddReceipt | ConvertFrom-Json
  if ($defender.status -ne 'ready' -or $defender.assetSha256 -cne $expectedSha256 -or
      $defender.scope -ne 'exact-file' -or $defender.receiptSystemOwned -ne $true -or
      $defender.precheckProbeVerified -ne $true -or
      $defender.targetHashVerified -ne $true -or $defender.mpCmdRunVerified -ne $true) {
    throw 'The exact-file Defender allowance is not ready for installer launch.'
  }
  $target = Get-Item -LiteralPath $targetPath -ErrorAction Stop
  if ($target.PSIsContainer -or (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($target.FullName, $targetPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The exact installer target is not a canonical regular file before launch signalling.'
  }
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant() -cne $expectedSha256) {
    throw 'The exact installer target hash changed before launch signalling.'
  }
} else {
  $finalPath = $cancelSignal
  $temporaryPath = $cancelSignalTemporary
  $expectedValue = "cancel:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}"
  if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
    Assert-SystemOwnedMarker $finalPath $expectedValue
    exit 0
  }
  if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
    Assert-SystemOwnedMarker $temporaryPath $expectedValue
    if (-not (Test-Path -LiteralPath $finalPath)) {
      Move-Item -LiteralPath $temporaryPath -Destination $finalPath -ErrorAction Stop
      Assert-SystemOwnedMarker $finalPath $expectedValue
      exit 0
    }
    throw 'Both installer cancel marker paths are occupied.'
  }
}

try {
  $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $temporaryOwned = $true
  try {
    $bytes = [Text.Encoding]::ASCII.GetBytes($expectedValue)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  $acl = Get-Acl -LiteralPath $temporaryPath -ErrorAction Stop
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($systemSid))
  Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
  Assert-SystemOwnedMarker $temporaryPath $expectedValue
  Move-Item -LiteralPath $temporaryPath -Destination $finalPath -ErrorAction Stop
  $temporaryOwned = $false
  Assert-SystemOwnedMarker $finalPath $expectedValue
} finally {
  if ($temporaryOwned -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
    try {
      Assert-SystemOwnedMarker $temporaryPath $expectedValue
      Remove-Item -Force -LiteralPath $temporaryPath -ErrorAction Stop
    } catch {}
  }
}
POWERSHELL
)"
  signal_script="${signal_script/__SIGNAL_ACTION__/$action}"
  signal_script="${signal_script/__EXPECTED_SHA256__/$expected_hash}"
  signal_script="${signal_script/__EXPECTED_WORKER_SHA256__/$expected_worker_hash}"
  signal_script="${signal_script/__EXPECTED_WORKER_NONCE__/$expected_worker_nonce}"
  printf '%s' "$signal_script" | guest_system_ps_once
}

signal_installer_bridge_launch() {
  write_installer_bridge_signal launch "$1"
}

cancel_installer_bridge() {
  local expected_hash="${1:-}"
  local attempt
  [[ "$installer_bridge_pending" == 1 ]] || return 0
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  for attempt in $(seq 1 5); do
    write_installer_bridge_signal cancel "$expected_hash" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# When the installer worker armed but the Defender guardian never started, use
# a fixed LocalSystem cmd.exe read to observe its cancellation receipt. This
# avoids opening hundreds of contending PowerShell sessions while the detached
# current-user worker is shutting down. The receipt is still fully validated on
# the host, and wait_installer_bridge_exit performs the protected PowerShell
# process-tuple proof after the worker has released the transport.
wait_installer_bridge_terminal_cmd() {
  local expected_hash="$1"
  local expected_worker_hash="${installer_worker_hash:-}"
  local expected_worker_nonce="${installer_worker_nonce:-}"
  local raw_receipt="$work_dir/installer-bridge-cmd-terminal.json"
  local output=""
  local status=1
  local attempt
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$expected_worker_hash" =~ ^[0-9a-f]{64}$ \
    && "$expected_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  for attempt in $(seq 1 30); do
    set +e
    output="$(prlctl exec "$vm_name" cmd.exe /D /Q /C type \
      'C:\Users\Public\eai-setup-installer-complete.json' 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 && -n "$output" ]]; then
      printf '%s\n' "$output" >"$raw_receipt"
      if EAI_INSTALLER_TERMINAL_RAW="$raw_receipt" \
        EAI_INSTALLER_TERMINAL_HASH="$expected_hash" \
        EAI_INSTALLER_TERMINAL_WORKER_HASH="$expected_worker_hash" \
        EAI_INSTALLER_TERMINAL_WORKER_NONCE="$expected_worker_nonce" \
        node --input-type=module <<'NODE'
import fs from "node:fs";
const value = JSON.parse(fs.readFileSync(process.env.EAI_INSTALLER_TERMINAL_RAW, "utf8"));
const terminal = new Set(["completed", "installer-failed", "cancelled-before-launch", "cancelled-during-install", "launch-timeout", "installer-timeout", "bridge-failed"]);
if (value.schemaVersion !== "eai-windows-installer-bridge/v1"
    || value.assetSha256 !== process.env.EAI_INSTALLER_TERMINAL_HASH
    || value.workerScriptSha256 !== process.env.EAI_INSTALLER_TERMINAL_WORKER_HASH
    || value.workerNonce !== process.env.EAI_INSTALLER_TERMINAL_WORKER_NONCE
    || value.workerScriptHashVerified !== true
    || value.workerProcessPathVerified !== true
    || value.workerSessionVerified !== true
    || !Number.isInteger(value.workerProcessId) || value.workerProcessId <= 0
    || !Number.isInteger(value.workerProcessSessionId) || value.workerProcessSessionId <= 0
    || (value.installerStarted === true && value.installerExited !== true)
    || !terminal.has(value.status)) process.exit(1);
NODE
      then
        return 0
      fi
      # The worker publishes this fixed path atomically without replacement.
      # A complete but invalid terminal receipt cannot become valid on a later
      # poll, so fail immediately instead of issuing 29 redundant guest reads.
      return 1
    elif ! is_parallels_session_open_failure "$output" \
      && [[ "$output" != *"cannot find the file"* \
      && "$output" != *"The system cannot find the file"* ]]; then
      return "$status"
    fi
    sleep 1
  done
  return 1
}

wait_installer_bridge_terminal() {
  local expected_hash="$1"
  local expected_worker_hash="${installer_worker_hash:-}"
  local expected_worker_nonce="${installer_worker_nonce:-}"
  local output=""
  local status=1
  local attempt
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_worker_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  for attempt in $(seq 1 360); do
    set +e
    output="$(guest_system_ps_run "$expected_hash"$'\n'"$expected_worker_hash"$'\n'"$expected_worker_nonce"$'\n' 2 2>&1 <<'POWERSHELL'
$expectedSha256 = [Console]::In.ReadLine()
$expectedWorkerSha256 = [Console]::In.ReadLine()
$expectedWorkerNonce = [Console]::In.ReadLine()
$path = 'C:\Users\Public\eai-setup-installer-complete.json'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 1 }
$item = Get-Item -LiteralPath $path -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
  Write-Output 'EAI_INSTALLER_BRIDGE_IMMUTABLE_TERMINAL_INVALID'
  exit 3
}
try { $value = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch {
  Write-Output 'EAI_INSTALLER_BRIDGE_IMMUTABLE_TERMINAL_INVALID'
  exit 3
}
$terminal = @('completed', 'installer-failed', 'cancelled-before-launch', 'cancelled-during-install', 'launch-timeout', 'installer-timeout', 'bridge-failed')
$installerSafe = $value.installerStarted -ne $true -or $value.installerExited -eq $true
if ($value.schemaVersion -eq 'eai-windows-installer-bridge/v1' -and
    $value.assetSha256 -ceq $expectedSha256 -and $value.workerScriptSha256 -ceq $expectedWorkerSha256 -and
    $value.workerNonce -ceq $expectedWorkerNonce -and
    $value.workerScriptHashVerified -eq $true -and $value.workerProcessPathVerified -eq $true -and
    $value.workerSessionVerified -eq $true -and $value.workerProcessSessionId -match '^[1-9][0-9]*$' -and
    $installerSafe -and $terminal -contains $value.status) { exit 0 }
Write-Output 'EAI_INSTALLER_BRIDGE_IMMUTABLE_TERMINAL_INVALID'
exit 3
POWERSHELL
    )"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      return 0
    fi
    if [[ "$output" == *"EAI_INSTALLER_BRIDGE_IMMUTABLE_TERMINAL_INVALID"* ]]; then
      # Completion receipts are atomic and immutable. Retrying a bound but
      # unsafe terminal state only delays cleanup and cannot repair evidence.
      return 1
    fi
    sleep 1
  done
  return 1
}

wait_installer_bridge_exit() {
  local expected_mode="${1:-success}"
  local expected_hash="${host_hash:-}"
  local expected_worker_hash="${installer_worker_hash:-}"
  local expected_worker_nonce="${installer_worker_nonce:-}"
  local exited=0
  local probe_script=""
  local attempt
  [[ "$expected_mode" == success || "$expected_mode" == any ]] || return 2
  [[ "$installer_bridge_pending" == 1 ]] || return 0
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$expected_worker_hash" =~ ^[0-9a-f]{64}$ \
    && "$expected_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  probe_script="$(/bin/cat <<'POWERSHELL'
$expectedMode = '__EXPECTED_MODE__'
$expectedSha256 = '__EXPECTED_SHA256__'
$expectedWorkerSha256 = '__EXPECTED_WORKER_SHA256__'
$expectedWorkerNonce = '__EXPECTED_WORKER_NONCE__'
$armedPath = 'C:\Users\Public\eai-setup-installer-bridge-armed.json'
$completionPath = 'C:\Users\Public\eai-setup-installer-complete.json'
$workerPath = 'C:\Users\Public\eai-setup-installer-worker.ps1'
foreach ($path in @($armedPath, $completionPath, $workerPath)) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { exit 1 }
}
$armed = Get-Content -Raw -LiteralPath $armedPath | ConvertFrom-Json
$completion = Get-Content -Raw -LiteralPath $completionPath | ConvertFrom-Json
$terminal = @('completed', 'installer-failed', 'cancelled-before-launch', 'cancelled-during-install', 'launch-timeout', 'installer-timeout', 'bridge-failed')
if ($armed.schemaVersion -ne 'eai-windows-installer-bridge/v1' -or $completion.schemaVersion -ne 'eai-windows-installer-bridge/v1' -or
    $armed.assetSha256 -cne $expectedSha256 -or $completion.assetSha256 -cne $expectedSha256 -or
    $armed.workerScriptSha256 -cne $expectedWorkerSha256 -or $completion.workerScriptSha256 -cne $expectedWorkerSha256 -or
    $armed.workerNonce -cne $expectedWorkerNonce -or $completion.workerNonce -cne $expectedWorkerNonce -or
    $armed.workerProcessId -notmatch '^[1-9][0-9]*$' -or $completion.workerProcessId -ne $armed.workerProcessId -or
    $armed.workerProcessSessionId -notmatch '^[1-9][0-9]*$' -or
    $completion.workerProcessSessionId -ne $armed.workerProcessSessionId -or
    $completion.workerProcessStartedAt -cne $armed.workerProcessStartedAt -or
    $completion.workerScriptHashVerified -ne $true -or $completion.workerProcessPathVerified -ne $true -or
    $completion.workerSessionVerified -ne $true -or $terminal -notcontains $completion.status -or
    ($completion.installerStarted -eq $true -and $completion.installerExited -ne $true) -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $workerPath).Hash.ToLowerInvariant() -cne $expectedWorkerSha256 -or
    ($expectedMode -eq 'success' -and $completion.status -ne 'completed')) { exit 1 }
$process = Get-Process -Id ([int]$armed.workerProcessId) -ErrorAction SilentlyContinue
if ($null -eq $process) { exit 0 }
try { $processPath = $process.Path } catch { exit 1 }
$expectedPowerShellPath = Join-Path $PSHOME 'powershell.exe'
$sameWorker = [string]::Equals($processPath, $expectedPowerShellPath, [StringComparison]::OrdinalIgnoreCase) -and
  $process.SessionId -eq [int]$armed.workerProcessSessionId -and
  $process.StartTime.ToUniversalTime() -eq [DateTime]::Parse($armed.workerProcessStartedAt).ToUniversalTime()
if ($sameWorker) { exit 1 }
# The PID was reused only after the recorded worker exited; never terminate it.
exit 0
POWERSHELL
  )"
  probe_script="${probe_script/__EXPECTED_MODE__/$expected_mode}"
  probe_script="${probe_script/__EXPECTED_SHA256__/$expected_hash}"
  probe_script="${probe_script/__EXPECTED_WORKER_SHA256__/$expected_worker_hash}"
  probe_script="${probe_script/__EXPECTED_WORKER_NONCE__/$expected_worker_nonce}"
  for attempt in $(seq 1 30); do
    if printf '%s' "$probe_script" | guest_system_ps >/dev/null 2>&1; then
      exited=1
      break
    fi
    sleep 1
  done
  [[ "$exited" == 1 ]] || return 1
  installer_bridge_pending=0
}

preserve_installer_bridge_evidence() {
  local expected_status="$1"
  local raw_receipt="$work_dir/installer-bridge-raw.json"
  local destination
  destination="$(dirname "$EAI_VM_RESULT_FILE")/windows-installer-bridge.json"
  [[ "$expected_status" == completed || "$expected_status" == any ]] || return 2
  guest_system_ps >"$raw_receipt" 2>/dev/null <<'POWERSHELL' || return 1
$path = 'C:\Users\Public\eai-setup-installer-complete.json'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 1 }
$item = Get-Item -LiteralPath $path -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { exit 1 }
Get-Content -Raw -LiteralPath $path
POWERSHELL
  EAI_INSTALLER_BRIDGE_EXPECTED_STATUS="$expected_status" \
    EAI_INSTALLER_BRIDGE_EXPECTED_HASH="${host_hash:-}" \
    EAI_INSTALLER_BRIDGE_EXPECTED_WORKER_HASH="${installer_worker_hash:-}" \
    EAI_INSTALLER_BRIDGE_EXPECTED_WORKER_NONCE="${installer_worker_nonce:-}" \
    EAI_INSTALLER_BRIDGE_RAW="$raw_receipt" EAI_INSTALLER_BRIDGE_DESTINATION="$destination" \
    node --input-type=module <<'NODE'
import fs from "node:fs";

const receipt = JSON.parse(fs.readFileSync(process.env.EAI_INSTALLER_BRIDGE_RAW, "utf8"));
const expectedStatus = process.env.EAI_INSTALLER_BRIDGE_EXPECTED_STATUS;
const expectedHash = process.env.EAI_INSTALLER_BRIDGE_EXPECTED_HASH;
const expectedWorkerHash = process.env.EAI_INSTALLER_BRIDGE_EXPECTED_WORKER_HASH;
const expectedWorkerNonce = process.env.EAI_INSTALLER_BRIDGE_EXPECTED_WORKER_NONCE;
const statuses = ["completed", "installer-failed", "cancelled-before-launch", "cancelled-during-install", "launch-timeout", "installer-timeout", "bridge-failed"];
if (receipt.schemaVersion !== "eai-windows-installer-bridge/v1" || !statuses.includes(receipt.status)) throw new Error("Invalid installer bridge evidence schema or status.");
if (receipt.assetName !== "eai-setup-under-test.exe" || receipt.assetSha256 !== expectedHash || !/^[0-9a-f]{64}$/.test(expectedHash || "")) throw new Error("Installer bridge evidence identifies a different release asset.");
if (receipt.workerScriptSha256 !== expectedWorkerHash || !/^[0-9a-f]{64}$/.test(expectedWorkerHash || "")) throw new Error("Installer bridge evidence identifies a different detached worker payload.");
if (receipt.workerNonce !== expectedWorkerNonce || !/^[0-9a-f]{32}$/.test(expectedWorkerNonce || "")) throw new Error("Installer bridge evidence is stale or belongs to another run.");
const validDate = (value) => typeof value === "string" && !Number.isNaN(Date.parse(value));
if (!validDate(receipt.completedAt)) throw new Error("Installer bridge evidence has no valid completion timestamp.");
if (!Number.isInteger(receipt.workerProcessId) || receipt.workerProcessId <= 0
    || !Number.isInteger(receipt.workerProcessSessionId) || receipt.workerProcessSessionId <= 0
    || !validDate(receipt.workerProcessStartedAt)) {
  throw new Error("Installer bridge evidence has no valid detached worker process tuple.");
}
const safe = {
  schemaVersion: receipt.schemaVersion,
  status: receipt.status,
  assetName: receipt.assetName,
  assetSha256: receipt.assetSha256,
  identityVerified: receipt.identityVerified === true,
  interactiveSessionVerified: receipt.interactiveSessionVerified === true,
  workerScriptSha256: receipt.workerScriptSha256,
  workerNonceBound: receipt.workerNonce === expectedWorkerNonce,
  workerProcessId: receipt.workerProcessId,
  workerProcessSessionId: receipt.workerProcessSessionId,
  workerScriptHashVerified: receipt.workerScriptHashVerified === true,
  workerProcessPathVerified: receipt.workerProcessPathVerified === true,
  workerSessionVerified: receipt.workerSessionVerified === true,
  workerProcessStartedAt: receipt.workerProcessStartedAt,
  targetAbsentWhenArmed: receipt.targetAbsentWhenArmed === true,
  launchSignalSystemOwned: receipt.launchSignalSystemOwned === true,
  launchSignalHashBound: receipt.launchSignalHashBound === true,
  defenderReadyReceiptVerified: receipt.defenderReadyReceiptVerified === true,
  defenderCleanupNotRequestedAtLaunch: receipt.defenderCleanupNotRequestedAtLaunch === true,
  targetRegularFileVerified: receipt.targetRegularFileVerified === true,
  targetHashVerified: receipt.targetHashVerified === true,
  targetLaunchLockVerified: receipt.targetLaunchLockVerified === true,
  launchStartInfoPathVerified: receipt.launchStartInfoPathVerified === true,
  liveProcessPathVerified: typeof receipt.liveProcessPathVerified === "boolean" ? receipt.liveProcessPathVerified : null,
  liveProcessExitedBeforePathInspection: receipt.liveProcessExitedBeforePathInspection === true,
  processPathVerified: receipt.processPathVerified === true,
  installerStarted: receipt.installerStarted === true,
  installerExited: receipt.installerExited === true,
  installerExitCode: Number.isInteger(receipt.installerExitCode) ? receipt.installerExitCode : null,
  installerProcessId: Number.isInteger(receipt.installerProcessId) ? receipt.installerProcessId : null,
  installerProcessStartedAt: validDate(receipt.installerProcessStartedAt) ? receipt.installerProcessStartedAt : null,
  installerProcessSessionId: Number.isInteger(receipt.installerProcessSessionId) ? receipt.installerProcessSessionId : null,
  cancelRequested: receipt.cancelRequested === true,
  timedOut: receipt.timedOut === true,
  exactProcessStopVerified: receipt.exactProcessStopVerified === true,
  launchWaitSeconds: Number.isInteger(receipt.launchWaitSeconds) ? receipt.launchWaitSeconds : null,
  installerTimeoutSeconds: Number.isInteger(receipt.installerTimeoutSeconds) ? receipt.installerTimeoutSeconds : null,
  armedAt: validDate(receipt.armedAt) ? receipt.armedAt : null,
  installerStartedAt: validDate(receipt.installerStartedAt) ? receipt.installerStartedAt : null,
  completedAt: receipt.completedAt,
  errorType: typeof receipt.errorType === "string" ? receipt.errorType : null,
};
fs.writeFileSync(process.env.EAI_INSTALLER_BRIDGE_DESTINATION, `${JSON.stringify(safe, null, 2)}\n`);
if (expectedStatus === "completed" && (receipt.status !== "completed"
    || receipt.identityVerified !== true
    || receipt.interactiveSessionVerified !== true
    || receipt.workerScriptHashVerified !== true
    || receipt.workerNonce !== expectedWorkerNonce
    || receipt.workerProcessPathVerified !== true
    || receipt.workerSessionVerified !== true
    || !validDate(receipt.workerProcessStartedAt)
    || receipt.targetAbsentWhenArmed !== true
    || receipt.launchSignalSystemOwned !== true
    || receipt.launchSignalHashBound !== true
    || receipt.defenderReadyReceiptVerified !== true
    || receipt.defenderCleanupNotRequestedAtLaunch !== true
    || receipt.targetRegularFileVerified !== true
    || receipt.targetHashVerified !== true
    || receipt.targetLaunchLockVerified !== true
    || receipt.launchStartInfoPathVerified !== true
    || (receipt.liveProcessPathVerified !== true && receipt.liveProcessExitedBeforePathInspection !== true)
    || receipt.processPathVerified !== true
    || receipt.installerStarted !== true
    || receipt.installerExited !== true
    || receipt.installerExitCode !== 0
    || !Number.isInteger(receipt.installerProcessId)
    || receipt.installerProcessId <= 0
    || (receipt.liveProcessPathVerified === true && receipt.liveProcessExitedBeforePathInspection !== true
      && (!validDate(receipt.installerProcessStartedAt)
        || !Number.isInteger(receipt.installerProcessSessionId)
        || receipt.installerProcessSessionId <= 0))
    || receipt.cancelRequested !== false
    || receipt.timedOut !== false
    || receipt.launchWaitSeconds !== 300
    || receipt.installerTimeoutSeconds !== 300
    || !validDate(receipt.armedAt)
    || !validDate(receipt.installerStartedAt)
    || Date.parse(receipt.armedAt) > Date.parse(receipt.installerStartedAt)
    || Date.parse(receipt.installerStartedAt) > Date.parse(receipt.completedAt))) {
  throw new Error("The installer bridge receipt is not a complete protected current-user execution proof.");
}
if (expectedStatus !== "any" && receipt.status !== expectedStatus) throw new Error(`Unexpected installer bridge status: ${receipt.status}`);
NODE
}

cleanup_installer_bridge_artifacts() {
  local expected_worker_hash="${installer_worker_hash:-}"
  [[ "$expected_worker_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  # A detached worker can briefly leave Parallels unable to open another
  # LocalSystem session even after its exact process-exit proof succeeds. The
  # transport helper retries only the two known session-open failures; keep the
  # hash-bound removal command one-shot for every other PowerShell error.
  guest_system_ps_run "$expected_worker_hash"$'\n' 30 >/dev/null 2>&1 <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$expectedWorkerSha256 = [Console]::In.ReadLine()
$workerPath = 'C:\Users\Public\eai-setup-installer-worker.ps1'
$workerTemporary = 'C:\Users\Public\eai-setup-installer-worker.ps1.tmp'
$paths = @(
  $workerPath,
  $workerTemporary,
  'C:\Users\Public\eai-setup-installer-bridge-armed.json',
  'C:\Users\Public\eai-setup-installer-bridge-armed.json.tmp',
  'C:\Users\Public\eai-setup-installer-launch.signal',
  'C:\Users\Public\eai-setup-installer-launch.signal.tmp',
  'C:\Users\Public\eai-setup-installer-cancel.signal',
  'C:\Users\Public\eai-setup-installer-cancel.signal.tmp',
  'C:\Users\Public\eai-setup-installer-complete.json',
  'C:\Users\Public\eai-setup-installer-complete.json.tmp'
)
foreach ($path in $paths) {
  if (Test-Path -LiteralPath $path) {
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
        -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove an invalid installer bridge artifact: $path"
    }
    if (($path -eq $workerPath -or $path -eq $workerTemporary) -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne $expectedWorkerSha256) {
      throw 'Refusing to remove a detached installer worker with an unexpected hash.'
    }
    Remove-Item -Force -LiteralPath $path -ErrorAction Stop
  }
}
if ($paths | Where-Object { Test-Path -LiteralPath $_ }) {
  throw 'One or more installer bridge artifacts could not be removed.'
}
POWERSHELL
}

start_defender_guardian() {
  local expected_hash="$1"
  local expected_installer_worker_hash="$2"
  local expected_installer_worker_nonce="$3"
  local worker_script=""
  local worker_hash=""
  local worker_nonce=""
  local worker_base64=""
  local bootstrap_script=""
  local bootstrap_pid=""
  local bootstrap_status_file="$work_dir/defender-guardian-bootstrap.status"
  local bootstrap_stdout="$work_dir/defender-guardian-bridge.stdout"
  local bootstrap_stderr="$work_dir/defender-guardian-bridge.stderr"
  local bootstrap_status=1
  local attempt
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_installer_worker_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$expected_installer_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  worker_nonce="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  worker_script="$(/bin/cat <<'POWERSHELL'
param(
  [Parameter(Mandatory = $true)][string]$ExpectedWorkerSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedWorkerNonce
)
$ErrorActionPreference = 'Stop'
$expectedWorkerSha256 = $ExpectedWorkerSha256.ToLowerInvariant()
$expectedWorkerNonce = $ExpectedWorkerNonce.ToLowerInvariant()
$workerScriptPath = 'C:\Users\Public\eai-setup-defender-guardian.ps1'
$workerScriptTemporary = 'C:\Users\Public\eai-setup-defender-guardian.ps1.tmp'
$guardianArmedReceipt = 'C:\Users\Public\eai-setup-defender-guardian-armed.json'
$guardianArmedReceiptTemporary = 'C:\Users\Public\eai-setup-defender-guardian-armed.json.tmp'
$targetPath = 'C:\Users\Public\eai-setup-under-test.exe'
$addReceipt = 'C:\Users\Public\eai-setup-defender-add.json'
$removeReceipt = 'C:\Users\Public\eai-setup-defender-remove.json'
$doneSignal = 'C:\Users\Public\eai-setup-defender-done.signal'
$targetReadySignal = 'C:\Users\Public\eai-setup-defender-target-ready.signal'
$targetReadySignalTemporary = 'C:\Users\Public\eai-setup-defender-target-ready.signal.tmp'
$expectedSha256 = '__EXPECTED_SHA256__'
$timeoutSeconds = 900
$targetWaitSeconds = 180
$addedByGuardian = $false
$addAttempted = $false
$baselineCaptured = $false
$baselineExactPresent = $false
$baselineExclusions = @()
$protectionBefore = $null
$mpPrecheckCompleted = $false
$mpVerifiedNotExcludedBefore = $false
$precheckProbeVerified = $false
$guardianError = $null
$timedOut = $false
$targetHashVerified = $false
$completionSignalVerified = $false
$workerSourceLock = $null
$workerScriptHashVerified = $false
$workerProcessPathVerified = $false
$workerSessionVerified = $false
$guardianProcess = Get-Process -Id $PID -ErrorAction Stop
$guardianProcessStartedAt = $guardianProcess.StartTime.ToUniversalTime().ToString('o')
$guardianProcessId = $PID

function Write-Receipt([string]$path, [System.Collections.IDictionary]$receipt) {
  $temporary = "$path.tmp"
  $receipt['receiptSystemOwned'] = $true
  $receipt['guardianWorkerSha256'] = $expectedWorkerSha256
  $receipt['guardianWorkerNonce'] = $expectedWorkerNonce
  $receipt['guardianProcessId'] = $guardianProcessId
  $receipt['guardianProcessStartedAt'] = $guardianProcessStartedAt
  $receipt['workerScriptHashVerified'] = $workerScriptHashVerified
  $receipt['workerProcessPathVerified'] = $workerProcessPathVerified
  $receipt['workerSessionVerified'] = $workerSessionVerified
  if (Test-Path -LiteralPath $temporary) { throw "A Defender receipt temporary path is occupied: $temporary" }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 6))
  $stream = $null
  try {
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  $acl = Get-Acl -LiteralPath $temporary -ErrorAction Stop
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
  Set-Acl -LiteralPath $temporary -AclObject $acl -ErrorAction Stop
  Move-Item -Force -LiteralPath $temporary -Destination $path
}

function Write-GuardianArmedReceipt {
  if ((Test-Path -LiteralPath $guardianArmedReceipt) -or (Test-Path -LiteralPath $guardianArmedReceiptTemporary)) {
    throw 'The fixed Defender guardian armed receipt path is occupied.'
  }
  $value = [ordered]@{
    schemaVersion = 'eai-defender-guardian-worker/v1'
    status = 'armed'
    assetSha256 = $expectedSha256
    guardianWorkerSha256 = $expectedWorkerSha256
    guardianWorkerNonce = $expectedWorkerNonce
    guardianProcessId = $guardianProcessId
    guardianProcessStartedAt = $guardianProcessStartedAt
    workerScriptHashVerified = $workerScriptHashVerified
    workerProcessPathVerified = $workerProcessPathVerified
    workerSessionVerified = $workerSessionVerified
    systemIdentityVerified = $isSystem
    administratorRoleVerified = $isAdministrator
    recordedAt = [DateTime]::UtcNow.ToString('o')
  }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($value | ConvertTo-Json -Depth 6))
  $stream = $null
  try {
    $stream = [IO.File]::Open($guardianArmedReceiptTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  $acl = Get-Acl -LiteralPath $guardianArmedReceiptTemporary -ErrorAction Stop
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
  Set-Acl -LiteralPath $guardianArmedReceiptTemporary -AclObject $acl -ErrorAction Stop
  Move-Item -LiteralPath $guardianArmedReceiptTemporary -Destination $guardianArmedReceipt -ErrorAction Stop
}

function Get-NormalizedExclusions {
  $paths = @((Get-MpPreference).ExclusionPath)
  return @($paths | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
}

function Test-StringSetEqual([string[]]$left, [string[]]$right) {
  $normalizedLeft = @($left | Sort-Object -Unique) -join "`n"
  $normalizedRight = @($right | Sort-Object -Unique) -join "`n"
  return [string]::Equals($normalizedLeft, $normalizedRight, [StringComparison]::Ordinal)
}

function Get-ProtectionState {
  $status = Get-MpComputerStatus
  $preference = Get-MpPreference
  return [ordered]@{
    antivirusEnabled = [bool]$status.AntivirusEnabled
    antispywareEnabled = [bool]$status.AntispywareEnabled
    realTimeProtectionEnabled = [bool]$status.RealTimeProtectionEnabled
    behaviorMonitorEnabled = [bool]$status.BehaviorMonitorEnabled
    ioavProtectionEnabled = [bool]$status.IoavProtectionEnabled
    puaProtection = [int]$preference.PUAProtection
  }
}

function Get-MpCmdRunPath {
  $candidates = @((Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'))
  $platformRoot = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
  if (Test-Path -LiteralPath $platformRoot -PathType Container) {
    $platformCandidates = @(Get-ChildItem -LiteralPath $platformRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' })
    $candidates = @($platformCandidates + $candidates)
  }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  throw 'Microsoft Defender MpCmdRun.exe was not found.'
}

function Test-MpCmdExclusion([string]$mpCmdRun, [string]$path, [int]$expectedExitCode) {
  $createdProbe = $false
  $stream = $null
  try {
    if (-not (Test-Path -LiteralPath $path)) {
      $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      $createdProbe = $true
      $stream.Dispose()
      $stream = $null
    }
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
        -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase) -or
        ($createdProbe -and $item.Length -ne 0)) {
      throw 'The exact-file Defender exclusion probe is not a regular zero-byte file.'
    }
    for ($poll = 0; $poll -lt 15; $poll++) {
      & $mpCmdRun -CheckExclusion -Path $path *> $null
      if ($LASTEXITCODE -eq $expectedExitCode) { return $true }
      Start-Sleep -Seconds 1
    }
    return $false
  } finally {
    $streamDisposeError = $null
    if ($null -ne $stream) {
      try {
        $stream.Dispose()
      } catch {
        $streamDisposeError = $_.Exception.GetType().FullName
      }
      $stream = $null
    }
    if ($createdProbe) {
      $probe = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
      if ($null -ne $probe) {
        if ($probe.PSIsContainer -or (($probe.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $probe.Length -ne 0) {
          throw 'The exact-file Defender exclusion probe changed unexpectedly; refusing to remove it.'
        }
        Remove-Item -Force -LiteralPath $path -ErrorAction Stop
      }
      if (Test-Path -LiteralPath $path) {
        throw 'The exact-file Defender exclusion probe could not be removed.'
      }
    }
    if ($null -ne $streamDisposeError) {
      throw "The exact-file Defender exclusion probe stream could not be closed: $streamDisposeError"
    }
  }
}

try {
  $fixedPaths = @(
    $workerScriptTemporary,
    $guardianArmedReceipt,
    $guardianArmedReceiptTemporary,
    $addReceipt,
    "$addReceipt.tmp",
    $removeReceipt,
    "$removeReceipt.tmp",
    $doneSignal,
    $targetReadySignal,
    $targetReadySignalTemporary
  )
  if ($fixedPaths | Where-Object { Test-Path -LiteralPath $_ }) {
    throw 'The detached Defender guardian requires an empty fixed-path baseline.'
  }
  if ($expectedWorkerSha256 -cnotmatch '^[0-9a-f]{64}$' -or $expectedWorkerNonce -cnotmatch '^[0-9a-f]{32}$') {
    throw 'The detached Defender guardian trust inputs are invalid.'
  }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  $isSystem = $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid)
  $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isSystem -or -not $isAdministrator) {
    throw 'The protected Defender guardian is not running as LocalSystem with administrator rights.'
  }
  $workerItem = Get-Item -LiteralPath $workerScriptPath -ErrorAction Stop
  if ($workerItem.PSIsContainer -or (($workerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($workerItem.FullName, $workerScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The detached Defender guardian is not the exact canonical regular script.'
  }
  $workerSourceLock = [IO.File]::Open($workerScriptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $workerHashAlgorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $workerScriptHash = ([BitConverter]::ToString($workerHashAlgorithm.ComputeHash($workerSourceLock))).Replace('-', '').ToLowerInvariant()
    $workerSourceLock.Position = 0
  } finally {
    $workerHashAlgorithm.Dispose()
  }
  $workerScriptHashVerified = $workerScriptHash -ceq $expectedWorkerSha256
  try { $guardianProcessPath = $guardianProcess.Path } catch { throw 'The detached Defender guardian process path is unavailable.' }
  $workerProcessPathVerified = [string]::Equals($guardianProcessPath, (Join-Path $PSHOME 'powershell.exe'), [StringComparison]::OrdinalIgnoreCase)
  $workerSessionVerified = $guardianProcess.SessionId -eq 0
  if (-not $workerScriptHashVerified -or -not $workerProcessPathVerified -or -not $workerSessionVerified) {
    throw 'The detached Defender guardian worker identity could not be verified.'
  }
  Write-GuardianArmedReceipt
  Import-Module Defender -ErrorAction Stop
  if (Test-Path -LiteralPath $targetPath) {
    throw 'The Defender diagnostic target path must be absent before the exact-file allowance is armed.'
  }

  $baselineExclusions = @(Get-NormalizedExclusions)
  $baselineCaptured = $true
  $normalizedTarget = $targetPath.ToLowerInvariant()
  $baselineExactPresent = $baselineExclusions -contains $normalizedTarget
  $protectionBefore = Get-ProtectionState
  if (-not $protectionBefore.antivirusEnabled -or -not $protectionBefore.antispywareEnabled -or
      -not $protectionBefore.realTimeProtectionEnabled -or -not $protectionBefore.behaviorMonitorEnabled -or
      -not $protectionBefore.ioavProtectionEnabled -or $protectionBefore.puaProtection -eq 0) {
    throw 'Microsoft Defender and PUA protection must be enabled for this diagnostic.'
  }
  $mpCmdRun = Get-MpCmdRunPath
  $mpVerifiedNotExcludedBefore = Test-MpCmdExclusion $mpCmdRun $targetPath 1
  $mpPrecheckCompleted = $true
  $precheckProbeVerified = $mpVerifiedNotExcludedBefore -and -not (Test-Path -LiteralPath $targetPath)

  if ($baselineExactPresent -or -not $precheckProbeVerified) {
    Write-Receipt $addReceipt ([ordered]@{
      schemaVersion = 'eai-defender-exact-file/v1'
      action = 'add'
      status = 'refused-existing'
      assetName = 'eai-setup-under-test.exe'
      assetSha256 = $expectedSha256
      scope = 'exact-file'
      diagnosticOnly = $true
      productionGate = $false
      elevationMethod = 'parallels-protected-LocalSystem'
      uacUsed = $false
      systemIdentityVerified = $isSystem
      administratorRoleVerified = $isAdministrator
      ownedByGuardian = $false
      preexistingExactExclusion = $baselineExactPresent
      effectiveExclusionPresentBefore = -not $mpVerifiedNotExcludedBefore
      precheckProbeVerified = $precheckProbeVerified
      exactExclusionPresent = $baselineExactPresent
      soleExclusionDelta = $false
      mpCmdRunVerified = $false
      protectionEnabled = $true
      protectionSettingsUnchanged = $true
      recordedAt = [DateTime]::UtcNow.ToString('o')
    })
    throw 'A pre-existing exact, parent, or wildcard Defender exclusion already covered the file; refusing to alter it.'
  }

  Write-Receipt $addReceipt ([ordered]@{
    schemaVersion = 'eai-defender-exact-file/v1'
    action = 'add'
    status = 'pending'
    assetName = 'eai-setup-under-test.exe'
    assetSha256 = $expectedSha256
    scope = 'exact-file'
    diagnosticOnly = $true
    productionGate = $false
    elevationMethod = 'parallels-protected-LocalSystem'
    uacUsed = $false
    systemIdentityVerified = $isSystem
    administratorRoleVerified = $isAdministrator
    ownedByGuardian = $true
    preexistingExactExclusion = $false
    effectiveExclusionPresentBefore = $false
    precheckProbeVerified = $precheckProbeVerified
    exactExclusionPresent = $false
    soleExclusionDelta = $false
    mpCmdRunVerified = $false
    protectionEnabled = $true
    protectionSettingsUnchanged = $true
    recordedAt = [DateTime]::UtcNow.ToString('o')
  })

  $addAttempted = $true
  Add-MpPreference -ExclusionPath $targetPath -Force -ErrorAction Stop
  $addedByGuardian = $true
  $afterAdd = @(Get-NormalizedExclusions)
  $expectedAfterAdd = @(($baselineExclusions + $normalizedTarget) | Sort-Object -Unique)
  $soleDelta = Test-StringSetEqual $expectedAfterAdd $afterAdd
  $exactPresent = $afterAdd -contains $normalizedTarget
  $protectionAfterAdd = Get-ProtectionState
  $protectionUnchanged = (ConvertTo-Json -Compress $protectionBefore) -ceq (ConvertTo-Json -Compress $protectionAfterAdd)
  if (-not $soleDelta -or -not $exactPresent -or -not $protectionUnchanged) {
    throw 'The exact-file Defender exclusion could not be verified without unrelated changes.'
  }

  Write-Receipt $addReceipt ([ordered]@{
    schemaVersion = 'eai-defender-exact-file/v1'
    action = 'add'
    status = 'awaiting-target'
    assetName = 'eai-setup-under-test.exe'
    assetSha256 = $expectedSha256
    scope = 'exact-file'
    diagnosticOnly = $true
    productionGate = $false
    elevationMethod = 'parallels-protected-LocalSystem'
    uacUsed = $false
    systemIdentityVerified = $isSystem
    administratorRoleVerified = $isAdministrator
    ownedByGuardian = $true
    preexistingExactExclusion = $false
    effectiveExclusionPresentBefore = $false
    precheckProbeVerified = $precheckProbeVerified
    exactExclusionPresent = $true
    soleExclusionDelta = $true
    targetHashVerified = $false
    completionSignalVerified = $false
    mpCmdRunVerified = $false
    protectionEnabled = $true
    protectionSettingsUnchanged = $true
    guardianTimeoutSeconds = $timeoutSeconds
    recordedAt = [DateTime]::UtcNow.ToString('o')
  })

  $targetAppeared = $false
  for ($targetPoll = 0; $targetPoll -lt ($targetWaitSeconds * 4); $targetPoll++) {
    if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and
        (Test-Path -LiteralPath $targetReadySignal -PathType Leaf)) {
      $targetAppeared = $true
      break
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $targetAppeared) {
    throw 'The exact Defender diagnostic target and completion signal did not appear before their bounded wait expired.'
  }
  $expectedSignalValue = 'download-complete'
  $expectedSignalBytes = [Text.Encoding]::ASCII.GetBytes($expectedSignalValue)
  $signalStream = $null
  try {
    $signalStream = [IO.File]::Open($targetReadySignal, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $signal = Get-Item -LiteralPath $targetReadySignal -ErrorAction Stop
    $signalAcl = Get-Acl -LiteralPath $targetReadySignal -ErrorAction Stop
    if ($signal.PSIsContainer -or (($signal.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
        -not [string]::Equals($signal.FullName, $targetReadySignal, [StringComparison]::OrdinalIgnoreCase) -or
        $signalAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18' -or
        $signal.Length -ne $expectedSignalBytes.Length -or $signalStream.Length -ne $expectedSignalBytes.Length) {
      throw 'The Defender diagnostic target completion signal metadata is invalid.'
    }
    $actualSignalBytes = [byte[]]::new($expectedSignalBytes.Length)
    $actualSignalOffset = 0
    while ($actualSignalOffset -lt $actualSignalBytes.Length) {
      $actualSignalRead = $signalStream.Read(
        $actualSignalBytes,
        $actualSignalOffset,
        $actualSignalBytes.Length - $actualSignalOffset
      )
      if ($actualSignalRead -eq 0) { break }
      $actualSignalOffset += $actualSignalRead
    }
    if ($actualSignalOffset -ne $actualSignalBytes.Length -or
        [Text.Encoding]::ASCII.GetString($actualSignalBytes) -cne $expectedSignalValue) {
      throw 'The Defender diagnostic target completion signal contents are invalid.'
    }
  }
  finally {
    if ($null -ne $signalStream) { $signalStream.Dispose() }
  }
  $completionSignalVerified = $true
  $target = Get-Item -LiteralPath $targetPath -ErrorAction Stop
  if ($target.PSIsContainer -or (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'The Defender diagnostic target is not a regular file.'
  }
  if (-not [string]::Equals($target.FullName, $targetPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The Defender diagnostic target resolved to a different path.'
  }
  $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
  if ($actualSha256 -cne $expectedSha256) {
    throw 'The Defender diagnostic target hash does not match the published asset.'
  }
  $targetHashVerified = $true
  $mpVerified = Test-MpCmdExclusion $mpCmdRun $targetPath 0
  if (-not $mpVerified) {
    throw 'MpCmdRun did not verify the exact-file allowance after the target hash matched.'
  }

  Write-Receipt $addReceipt ([ordered]@{
    schemaVersion = 'eai-defender-exact-file/v1'
    action = 'add'
    status = 'ready'
    assetName = 'eai-setup-under-test.exe'
    assetSha256 = $expectedSha256
    scope = 'exact-file'
    diagnosticOnly = $true
    productionGate = $false
    elevationMethod = 'parallels-protected-LocalSystem'
    uacUsed = $false
    systemIdentityVerified = $isSystem
    administratorRoleVerified = $isAdministrator
    ownedByGuardian = $true
    preexistingExactExclusion = $false
    effectiveExclusionPresentBefore = $false
    precheckProbeVerified = $precheckProbeVerified
    exactExclusionPresent = $true
    soleExclusionDelta = $true
    targetHashVerified = $targetHashVerified
    completionSignalVerified = $completionSignalVerified
    mpCmdRunVerified = $mpVerified
    protectionEnabled = $true
    protectionSettingsUnchanged = $true
    guardianTimeoutSeconds = $timeoutSeconds
    recordedAt = [DateTime]::UtcNow.ToString('o')
  })

  $done = $false
  for ($attempt = 0; $attempt -lt $timeoutSeconds; $attempt++) {
    if (Test-Path -LiteralPath $doneSignal -PathType Leaf) {
      $doneItem = Get-Item -LiteralPath $doneSignal -ErrorAction Stop
      $doneAcl = Get-Acl -LiteralPath $doneSignal -ErrorAction Stop
      $expectedDone = "cleanup:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}"
      if ($doneItem.PSIsContainer -or (($doneItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
          $doneAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18' -or
          (Get-Content -Raw -LiteralPath $doneSignal).Trim() -cne $expectedDone) {
        throw 'The Defender guardian cleanup signal is not System-owned and bound to this run.'
      }
      $done = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $done) {
    $timedOut = $true
    throw 'The Defender diagnostic guardian reached its hard cleanup timeout.'
  }
} catch {
  $guardianError = $_.Exception.GetType().FullName
} finally {
  $cleanupError = $null
  $removedByGuardian = $false
  $baselineRestored = $false
  $exactAbsent = $false
  $mpVerifiedNotExcluded = $false
  $protectionUnchanged = $false
  try {
    Remove-Item -Force -LiteralPath $targetReadySignal, $targetReadySignalTemporary -ErrorAction SilentlyContinue
    $beforeCleanup = if ($baselineCaptured) { @(Get-NormalizedExclusions) } else { @() }
    $exactPresentBeforeCleanup = $baselineCaptured -and ($beforeCleanup -contains $targetPath.ToLowerInvariant())
    $effectivePresentBeforeCleanup = $false
    if ($baselineCaptured -and -not $baselineExactPresent -and $addAttempted) {
      $mpCmdRun = Get-MpCmdRunPath
      $effectivePresentBeforeCleanup = Test-MpCmdExclusion $mpCmdRun $targetPath 0
    }
    if (-not $baselineExactPresent -and $addAttempted -and
        ($addedByGuardian -or $exactPresentBeforeCleanup -or $effectivePresentBeforeCleanup)) {
      Remove-MpPreference -ExclusionPath $targetPath -Force -ErrorAction Stop
      $removedByGuardian = $true
    }
    if ($baselineCaptured) {
      $afterCleanup = @(Get-NormalizedExclusions)
      $baselineRestored = Test-StringSetEqual $baselineExclusions $afterCleanup
      $exactAbsent = -not ($afterCleanup -contains $targetPath.ToLowerInvariant())
      if (-not $baselineExactPresent) {
        $mpCmdRun = Get-MpCmdRunPath
        $mpVerifiedNotExcluded = Test-MpCmdExclusion $mpCmdRun $targetPath 1
      }
      $protectionAfterCleanup = Get-ProtectionState
      $protectionUnchanged = (ConvertTo-Json -Compress $protectionBefore) -ceq (ConvertTo-Json -Compress $protectionAfterCleanup)
    }
  } catch {
    $cleanupError = $_.Exception.GetType().FullName
  }
  $cleanupVerified = $baselineCaptured -and $baselineRestored -and $protectionUnchanged -and
    ($baselineExactPresent -or ($exactAbsent -and $mpVerifiedNotExcluded))
  $removeStatus = if ($cleanupVerified -and $baselineExactPresent) { 'preexisting-preserved' }
    elseif ($cleanupVerified) { 'removed-verified' }
    else { 'cleanup-failed' }
  Write-Receipt $removeReceipt ([ordered]@{
    schemaVersion = 'eai-defender-exact-file/v1'
    action = 'remove'
    status = $removeStatus
    assetName = 'eai-setup-under-test.exe'
    assetSha256 = $expectedSha256
    scope = 'exact-file'
    diagnosticOnly = $true
    productionGate = $false
    elevationMethod = 'parallels-protected-LocalSystem'
    uacUsed = $false
    systemIdentityVerified = $isSystem
    administratorRoleVerified = $isAdministrator
    ownedByGuardian = $addedByGuardian
    removedByGuardian = $removedByGuardian
    preexistingExactExclusion = $baselineExactPresent
    effectiveExclusionPresentBefore = if ($mpPrecheckCompleted) { -not $mpVerifiedNotExcludedBefore } else { $null }
    exactExclusionAbsent = $exactAbsent
    baselineExclusionSetRestored = $baselineRestored
    mpCmdRunVerifiedNotExcluded = $mpVerifiedNotExcluded
    protectionSettingsUnchanged = $protectionUnchanged
    cleanupVerified = $cleanupVerified
    guardianTimedOut = $timedOut
    guardianErrorType = $guardianError
    cleanupErrorType = $cleanupError
    recordedAt = [DateTime]::UtcNow.ToString('o')
  })
  if ($null -ne $workerSourceLock) { $workerSourceLock.Dispose() }
}

if ($guardianError -or -not $cleanupVerified) { exit 1 }
exit 0
POWERSHELL
)"
  worker_script="${worker_script/__EXPECTED_SHA256__/$expected_hash}"
  worker_hash="$(printf '%s' "$worker_script" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$worker_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  worker_base64="$(printf '%s' "$worker_script" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  [[ -n "$worker_base64" ]] || return 1
  bootstrap_script="$(/bin/cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$expectedSha256 = '__EXPECTED_SHA256__'
$expectedWorkerSha256 = '__EXPECTED_WORKER_SHA256__'
$expectedWorkerNonce = '__EXPECTED_WORKER_NONCE__'
$expectedInstallerWorkerSha256 = '__EXPECTED_INSTALLER_WORKER_SHA256__'
$expectedInstallerWorkerNonce = '__EXPECTED_INSTALLER_WORKER_NONCE__'
$payloadBase64 = '__WORKER_PAYLOAD_BASE64__'
$workerScriptPath = 'C:\Users\Public\eai-setup-defender-guardian.ps1'
$workerScriptTemporary = 'C:\Users\Public\eai-setup-defender-guardian.ps1.tmp'
$armedReceipt = 'C:\Users\Public\eai-setup-defender-guardian-armed.json'
$armedReceiptTemporary = 'C:\Users\Public\eai-setup-defender-guardian-armed.json.tmp'
$addReceipt = 'C:\Users\Public\eai-setup-defender-add.json'
$targetPath = 'C:\Users\Public\eai-setup-under-test.exe'
$systemSid = 'S-1-5-18'
$sourceLock = $null
$temporaryOwned = $false
$stream = $null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -or
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'The detached Defender bootstrap requires the protected LocalSystem channel.'
}
if ($expectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or $expectedWorkerSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $expectedWorkerNonce -cnotmatch '^[0-9a-f]{32}$' -or
    $expectedInstallerWorkerSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $expectedInstallerWorkerNonce -cnotmatch '^[0-9a-f]{32}$') {
  throw 'The detached Defender bootstrap trust inputs are invalid.'
}
$installerWorkerPath = 'C:\Users\Public\eai-setup-installer-worker.ps1'
$installerArmedPath = 'C:\Users\Public\eai-setup-installer-bridge-armed.json'
$installerCompletionPath = 'C:\Users\Public\eai-setup-installer-complete.json'
foreach ($path in @($installerWorkerPath, $installerArmedPath)) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The detached installer worker trust artifact is not a canonical regular file.'
  }
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $installerWorkerPath).Hash.ToLowerInvariant() -cne $expectedInstallerWorkerSha256) {
  throw 'The detached installer worker script changed before Defender bootstrap.'
}
if (Test-Path -LiteralPath $installerCompletionPath) {
  throw 'The detached installer worker terminated before Defender bootstrap.'
}
$installerArmed = Get-Content -Raw -LiteralPath $installerArmedPath | ConvertFrom-Json
if ($installerArmed.schemaVersion -ne 'eai-windows-installer-bridge/v1' -or
    $installerArmed.status -ne 'armed' -or $installerArmed.assetSha256 -cne $expectedSha256 -or
    $installerArmed.workerScriptSha256 -cne $expectedInstallerWorkerSha256 -or
    $installerArmed.workerNonce -cne $expectedInstallerWorkerNonce -or
    $installerArmed.workerScriptHashVerified -ne $true -or
    $installerArmed.workerProcessPathVerified -ne $true -or $installerArmed.workerSessionVerified -ne $true -or
    $installerArmed.identityVerified -ne $true -or $installerArmed.interactiveSessionVerified -ne $true -or
    $installerArmed.targetAbsentWhenArmed -ne $true -or
    $installerArmed.workerProcessId -notmatch '^[1-9][0-9]*$' -or
    $installerArmed.workerProcessSessionId -notmatch '^[1-9][0-9]*$') {
  throw 'The detached installer worker is not armed for this Defender bootstrap.'
}
$installerProcess = Get-Process -Id ([int]$installerArmed.workerProcessId) -ErrorAction Stop
try { $installerProcessPath = $installerProcess.Path } catch { throw 'The detached installer worker process path is unavailable.' }
if ($installerProcess.SessionId -ne [int]$installerArmed.workerProcessSessionId -or
    -not [string]::Equals($installerProcessPath, (Join-Path $PSHOME 'powershell.exe'), [StringComparison]::OrdinalIgnoreCase) -or
    $installerProcess.StartTime.ToUniversalTime() -ne [DateTime]::Parse($installerArmed.workerProcessStartedAt).ToUniversalTime()) {
  throw 'The detached installer worker process tuple changed before Defender bootstrap.'
}
$fixedPaths = @(
  $workerScriptPath,
  $workerScriptTemporary,
  $armedReceipt,
  $armedReceiptTemporary,
  'C:\Users\Public\eai-setup-defender-add.json',
  'C:\Users\Public\eai-setup-defender-add.json.tmp',
  'C:\Users\Public\eai-setup-defender-remove.json',
  'C:\Users\Public\eai-setup-defender-remove.json.tmp',
  'C:\Users\Public\eai-setup-defender-done.signal',
  'C:\Users\Public\eai-setup-defender-done.signal.tmp',
  'C:\Users\Public\eai-setup-defender-target-ready.signal',
  'C:\Users\Public\eai-setup-defender-target-ready.signal.tmp'
)
if ($fixedPaths | Where-Object { Test-Path -LiteralPath $_ }) {
  throw 'The detached Defender bootstrap requires an empty fixed-path baseline.'
}
if (Test-Path -LiteralPath 'C:\Users\Public\eai-setup-under-test.exe') {
  throw 'The detached Defender bootstrap requires an absent installer target.'
}
try { $payload = [Convert]::FromBase64String($payloadBase64) } catch { throw 'The detached Defender worker payload is not valid base64.' }
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
  $payloadSha256 = ([BitConverter]::ToString($sha256.ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
} finally {
  $sha256.Dispose()
}
if ($payloadSha256 -cne $expectedWorkerSha256) { throw 'The detached Defender worker payload hash changed before staging.' }
try {
  $stream = [IO.File]::Open($workerScriptTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $temporaryOwned = $true
  $stream.Write($payload, 0, $payload.Length)
  $stream.Flush($true)
  $stream.Dispose()
  $stream = $null
  $item = Get-Item -LiteralPath $workerScriptTemporary -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $workerScriptTemporary).Hash.ToLowerInvariant() -cne $expectedWorkerSha256) {
    throw 'The staged detached Defender worker is invalid.'
  }
  Move-Item -LiteralPath $workerScriptTemporary -Destination $workerScriptPath -ErrorAction Stop
  $temporaryOwned = $false
} finally {
  if ($null -ne $stream) { $stream.Dispose() }
  if ($temporaryOwned -and (Test-Path -LiteralPath $workerScriptTemporary -PathType Leaf) -and
      (Get-FileHash -Algorithm SHA256 -LiteralPath $workerScriptTemporary).Hash.ToLowerInvariant() -ceq $expectedWorkerSha256) {
    Remove-Item -Force -LiteralPath $workerScriptTemporary -ErrorAction SilentlyContinue
  }
}
$workerItem = Get-Item -LiteralPath $workerScriptPath -ErrorAction Stop
if ($workerItem.PSIsContainer -or (($workerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($workerItem.FullName, $workerScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The detached Defender worker could not be verified before launch.'
}
$sourceLock = [IO.File]::Open($workerScriptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$lockedWorkerHasher = [Security.Cryptography.SHA256]::Create()
try {
  $lockedWorkerSha256 = ([BitConverter]::ToString($lockedWorkerHasher.ComputeHash($sourceLock))).Replace('-', '').ToLowerInvariant()
  $sourceLock.Position = 0
} finally {
  $lockedWorkerHasher.Dispose()
}
if ($lockedWorkerSha256 -cne $expectedWorkerSha256) {
  throw 'The locked detached Defender worker hash changed before launch.'
}
$powerShellPath = Join-Path $PSHOME 'powershell.exe'
$workerCommandLine = '"' + $powerShellPath + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
  $workerScriptPath + '" -ExpectedWorkerSha256 ' + $expectedWorkerSha256 + ' -ExpectedWorkerNonce ' + $expectedWorkerNonce
$startupEnvironment = [Collections.Generic.List[string]]::new()
foreach ($entry in [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).GetEnumerator()) {
  $name = [string]$entry.Key
  $value = [string]$entry.Value
  if (-not $name -or $name.IndexOf([char]'=') -ge 0 -or
      $name.IndexOf([char]0) -ge 0 -or $value.IndexOf([char]0) -ge 0) {
    throw 'The Defender bootstrap environment contains an invalid name or value.'
  }
  if ($name.StartsWith('EAI_', [StringComparison]::OrdinalIgnoreCase)) { continue }
  $startupEnvironment.Add(('{0}={1}' -f $name, $value))
}
$startupEnvironmentValues = [string[]]$startupEnvironment.ToArray()
$wmiStartupClass = [wmiclass]'\\.\root\cimv2:Win32_ProcessStartup'
$wmiStartup = $wmiStartupClass.CreateInstance()
$wmiStartup.CreateFlags = [uint32]1536
$wmiStartup.EnvironmentVariables = $startupEnvironmentValues
$wmiProcessClass = [wmiclass]'\\.\root\cimv2:Win32_Process'
$wmiResult = $wmiProcessClass.Create($workerCommandLine, (Split-Path -Parent $powerShellPath), $wmiStartup)
if ([int]$wmiResult.ReturnValue -ne 0 -or [int]$wmiResult.ProcessId -le 0) {
  throw 'Local WMI could not launch the detached Defender guardian.'
}
$workerProcess = Get-Process -Id ([int]$wmiResult.ProcessId) -ErrorAction Stop
[void]$workerProcess.Handle
$workerCim = Get-CimInstance Win32_Process -Filter "ProcessId = $($workerProcess.Id)" -ErrorAction Stop
$workerOwnerSid = Invoke-CimMethod -InputObject $workerCim -MethodName GetOwnerSid -ErrorAction Stop
if ($workerProcess.SessionId -ne 0 -or
    -not [string]::Equals($workerProcess.Path, $powerShellPath, [StringComparison]::OrdinalIgnoreCase) -or
    $workerOwnerSid.ReturnValue -ne 0 -or $workerOwnerSid.Sid -cne $systemSid -or
    [string]$workerCim.CommandLine -cne $workerCommandLine) {
  throw 'The local-WMI Defender guardian does not match its exact SYSTEM/session/path/command-line binding.'
}
$workerProcessStartedAt = $workerProcess.StartTime.ToUniversalTime().ToString('o')
$armed = $null
for ($poll = 0; $poll -lt 120; $poll++) {
  if (Test-Path -LiteralPath $armedReceipt -PathType Leaf) {
    try { $armed = Get-Content -Raw -LiteralPath $armedReceipt | ConvertFrom-Json } catch { $armed = $null }
    if ($null -ne $armed -and $armed.status -eq 'armed') { break }
  }
  Start-Sleep -Milliseconds 250
}
if ($null -eq $armed -or $armed.schemaVersion -ne 'eai-defender-guardian-worker/v1' -or
    $armed.assetSha256 -cne $expectedSha256 -or $armed.guardianWorkerSha256 -cne $expectedWorkerSha256 -or
    $armed.guardianWorkerNonce -cne $expectedWorkerNonce -or $armed.guardianProcessId -ne $workerProcess.Id -or
    $armed.guardianProcessStartedAt -cne $workerProcessStartedAt -or $armed.workerScriptHashVerified -ne $true -or
    $armed.workerProcessPathVerified -ne $true -or $armed.workerSessionVerified -ne $true -or
    $armed.systemIdentityVerified -ne $true -or $armed.administratorRoleVerified -ne $true) {
  throw 'The detached Defender guardian armed receipt is invalid or stale.'
}
$armedItem = Get-Item -LiteralPath $armedReceipt -ErrorAction Stop
$armedAcl = Get-Acl -LiteralPath $armedReceipt -ErrorAction Stop
if ($armedItem.PSIsContainer -or (($armedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    $armedAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18') {
  throw 'The detached Defender guardian armed receipt is not a System-owned regular file.'
}
$workerProcess.Refresh()
try { $workerProcessPath = $workerProcess.Path } catch { throw 'The detached Defender guardian process path is unavailable.' }
if ($workerProcess.HasExited -or $workerProcess.SessionId -ne 0 -or
    -not [string]::Equals($workerProcessPath, $powerShellPath, [StringComparison]::OrdinalIgnoreCase) -or
    $workerProcess.StartTime.ToUniversalTime() -ne [DateTime]::Parse($armed.guardianProcessStartedAt).ToUniversalTime()) {
  throw 'The detached Defender guardian process tuple does not match its receipt.'
}

# Keep this already-open protected bootstrap attached until the guardian has
# actually added and independently recorded the exact allowance. Opening a new
# LocalSystem guest session while the detached guardian is active is unreliable
# under Parallels, so the bootstrap itself provides the fail-closed arm proof.
$awaitingTarget = $null
for ($poll = 0; $poll -lt 240; $poll++) {
  $workerProcess.Refresh()
  if ($workerProcess.HasExited) {
    throw 'The detached Defender guardian exited before the exact allowance was ready.'
  }
  if (Test-Path -LiteralPath $addReceipt -PathType Leaf) {
    try { $candidate = Get-Content -Raw -LiteralPath $addReceipt | ConvertFrom-Json } catch { $candidate = $null }
    if ($null -ne $candidate -and $candidate.status -eq 'awaiting-target') {
      $awaitingTarget = $candidate
      break
    }
  }
  Start-Sleep -Milliseconds 250
}
if ($null -eq $awaitingTarget) {
  throw 'The detached Defender guardian did not record the awaiting-target allowance during the bounded bootstrap.'
}
$addItem = Get-Item -LiteralPath $addReceipt -ErrorAction Stop
$addAcl = Get-Acl -LiteralPath $addReceipt -ErrorAction Stop
if ($addItem.PSIsContainer -or (($addItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($addItem.FullName, $addReceipt, [StringComparison]::OrdinalIgnoreCase) -or
    $addAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid) {
  throw 'The detached Defender awaiting-target receipt is not a canonical System-owned regular file.'
}
if ($awaitingTarget.schemaVersion -ne 'eai-defender-exact-file/v1' -or
    $awaitingTarget.action -ne 'add' -or $awaitingTarget.status -ne 'awaiting-target' -or
    $awaitingTarget.assetName -ne 'eai-setup-under-test.exe' -or
    $awaitingTarget.assetSha256 -cne $expectedSha256 -or $awaitingTarget.scope -ne 'exact-file' -or
    $awaitingTarget.diagnosticOnly -ne $true -or $awaitingTarget.productionGate -ne $false -or
    $awaitingTarget.elevationMethod -ne 'parallels-protected-LocalSystem' -or $awaitingTarget.uacUsed -ne $false -or
    $awaitingTarget.systemIdentityVerified -ne $true -or $awaitingTarget.administratorRoleVerified -ne $true -or
    $awaitingTarget.receiptSystemOwned -ne $true -or $awaitingTarget.ownedByGuardian -ne $true -or
    $awaitingTarget.preexistingExactExclusion -ne $false -or
    $awaitingTarget.effectiveExclusionPresentBefore -ne $false -or
    $awaitingTarget.precheckProbeVerified -ne $true -or $awaitingTarget.exactExclusionPresent -ne $true -or
    $awaitingTarget.soleExclusionDelta -ne $true -or $awaitingTarget.targetHashVerified -ne $false -or
    $awaitingTarget.completionSignalVerified -ne $false -or $awaitingTarget.mpCmdRunVerified -ne $false -or
    $awaitingTarget.protectionEnabled -ne $true -or $awaitingTarget.protectionSettingsUnchanged -ne $true -or
    $awaitingTarget.guardianTimeoutSeconds -ne 900 -or
    $awaitingTarget.guardianWorkerSha256 -cne $expectedWorkerSha256 -or
    $awaitingTarget.guardianWorkerNonce -cne $expectedWorkerNonce -or
    $awaitingTarget.guardianProcessId -ne $workerProcess.Id -or
    $awaitingTarget.guardianProcessStartedAt -cne $workerProcessStartedAt -or
    $awaitingTarget.workerScriptHashVerified -ne $true -or
    $awaitingTarget.workerProcessPathVerified -ne $true -or $awaitingTarget.workerSessionVerified -ne $true) {
  throw 'The detached Defender awaiting-target receipt is invalid or belongs to another guardian.'
}
if (Test-Path -LiteralPath $targetPath) {
  throw 'The Defender installer target appeared before the protected download stage.'
}
Import-Module Defender -ErrorAction Stop
$defenderPreference = Get-MpPreference
$normalizedTarget = $targetPath.ToLowerInvariant()
$effectiveExclusions = @($defenderPreference.ExclusionPath |
  Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
  ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
$defenderStatus = Get-MpComputerStatus
if ($effectiveExclusions -notcontains $normalizedTarget -or
    -not [bool]$defenderStatus.AntivirusEnabled -or -not [bool]$defenderStatus.AntispywareEnabled -or
    -not [bool]$defenderStatus.RealTimeProtectionEnabled -or -not [bool]$defenderStatus.BehaviorMonitorEnabled -or
    -not [bool]$defenderStatus.IoavProtectionEnabled -or [int]$defenderPreference.PUAProtection -eq 0) {
  throw 'The exact Defender allowance or required protection state is not active at bootstrap acknowledgement.'
}
$workerProcess.Refresh()
try { $workerProcessPath = $workerProcess.Path } catch { throw 'The detached Defender guardian process path is unavailable at acknowledgement.' }
if ($workerProcess.HasExited -or $workerProcess.SessionId -ne 0 -or
    -not [string]::Equals($workerProcessPath, $powerShellPath, [StringComparison]::OrdinalIgnoreCase) -or
    $workerProcess.StartTime.ToUniversalTime() -ne [DateTime]::Parse($awaitingTarget.guardianProcessStartedAt).ToUniversalTime()) {
  throw 'The detached Defender guardian process tuple changed before bootstrap acknowledgement.'
}
$sourceLock.Dispose()
$sourceLock = $null
Write-Output "DETACHED_DEFENDER_GUARDIAN_ARMED:${expectedWorkerSha256}:${expectedWorkerNonce}"
POWERSHELL
)"
  bootstrap_script="${bootstrap_script/__EXPECTED_SHA256__/$expected_hash}"
  bootstrap_script="${bootstrap_script/__EXPECTED_WORKER_SHA256__/$worker_hash}"
  bootstrap_script="${bootstrap_script/__EXPECTED_WORKER_NONCE__/$worker_nonce}"
  bootstrap_script="${bootstrap_script/__EXPECTED_INSTALLER_WORKER_SHA256__/$expected_installer_worker_hash}"
  bootstrap_script="${bootstrap_script/__EXPECTED_INSTALLER_WORKER_NONCE__/$expected_installer_worker_nonce}"
  bootstrap_script="${bootstrap_script/__WORKER_PAYLOAD_BASE64__/$worker_base64}"
  printf '' >"$bootstrap_stdout"
  printf '' >"$bootstrap_stderr"
  /bin/unlink "$bootstrap_status_file" >/dev/null 2>&1 || true
  defender_exclusion_pending=1
  defender_worker_hash="$worker_hash"
  defender_worker_nonce="$worker_nonce"
  (
    local attached_status=1
    set +e
    printf '& {\n%s\n}\n\n' "$bootstrap_script" | prlctl exec "$vm_name" cmd.exe /D /S /C powershell.exe \
      -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -InputFormat Text -OutputFormat Text -Command - \
      >"$bootstrap_stdout" 2>"$bootstrap_stderr"
    attached_status=$?
    set -e
    printf '%s\n' "$attached_status" >"$bootstrap_status_file"
    exit "$attached_status"
  ) &
  bootstrap_pid=$!
  for attempt in $(seq 1 90); do
    [[ -f "$bootstrap_status_file" ]] && break
    sleep 1
  done
  if [[ ! -f "$bootstrap_status_file" ]]; then
    cleanup_host_bridge "$bootstrap_pid"
    return 1
  fi
  bootstrap_status="$(tr -d '\r\n' <"$bootstrap_status_file")"
  if wait "$bootstrap_pid" >/dev/null 2>&1; then :; fi
  [[ "$bootstrap_status" == 0 ]] || return 1
  /usr/bin/tr -d '\r' <"$bootstrap_stdout" \
    | /usr/bin/grep -Fqx "DETACHED_DEFENDER_GUARDIAN_ARMED:$worker_hash:$worker_nonce" \
    || return 1
}

wait_defender_guardian_ready() {
  local expected_hash="${host_hash:-}"
  local expected_worker_hash="${defender_worker_hash:-}"
  local expected_worker_nonce="${defender_worker_nonce:-}"
  local guardian_ready=0
  local attempt
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$expected_worker_hash" =~ ^[0-9a-f]{64}$ \
    && "$expected_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  for attempt in $(seq 1 240); do
    if guest_system_ps_run "$expected_hash"$'\n'"$expected_worker_hash"$'\n'"$expected_worker_nonce"$'\n' 2 >/dev/null 2>&1 <<'POWERSHELL'; then
$expectedSha256 = [Console]::In.ReadLine()
$expectedWorkerSha256 = [Console]::In.ReadLine()
$expectedWorkerNonce = [Console]::In.ReadLine()
$receipt = 'C:\Users\Public\eai-setup-defender-add.json'
if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { exit 1 }
$item = Get-Item -LiteralPath $receipt -ErrorAction Stop
$acl = Get-Acl -LiteralPath $receipt -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18') { exit 1 }
try { $value = Get-Content -Raw -LiteralPath $receipt | ConvertFrom-Json } catch { exit 1 }
if ($value.status -eq 'ready' -and $value.scope -eq 'exact-file' -and
    $value.assetSha256 -ceq $expectedSha256 -and $value.guardianWorkerSha256 -ceq $expectedWorkerSha256 -and
    $value.guardianWorkerNonce -ceq $expectedWorkerNonce -and $value.guardianProcessId -match '^[1-9][0-9]*$' -and
    $value.workerScriptHashVerified -eq $true -and $value.workerProcessPathVerified -eq $true -and
    $value.workerSessionVerified -eq $true -and
    $value.ownedByGuardian -eq $true -and $value.precheckProbeVerified -eq $true -and
    $value.completionSignalVerified -eq $true -and
    $value.targetHashVerified -eq $true -and
    $value.mpCmdRunVerified -eq $true) {
  $process = Get-Process -Id ([int]$value.guardianProcessId) -ErrorAction SilentlyContinue
  if ($null -eq $process) { exit 1 }
  try { $processPath = $process.Path } catch { exit 1 }
  if ($process.SessionId -eq 0 -and
      [string]::Equals($processPath, (Join-Path $PSHOME 'powershell.exe'), [StringComparison]::OrdinalIgnoreCase) -and
      $process.StartTime.ToUniversalTime() -eq [DateTime]::Parse($value.guardianProcessStartedAt).ToUniversalTime()) { exit 0 }
}
exit 1
POWERSHELL
      guardian_ready=1
      break
    fi
    sleep 1
  done
  [[ "$guardian_ready" == 1 ]]
}

preserve_defender_evidence() {
  local action="$1"
  local expected_status="$2"
  local raw_receipt="$work_dir/defender-${action}-raw.json"
  local destination=""
  destination="$(dirname "$EAI_VM_RESULT_FILE")/windows-defender-exclusion-${action}.json"
  case "$action" in
    add)
      guest_system_ps >"$raw_receipt" 2>/dev/null <<'POWERSHELL' || return 1
$path = 'C:\Users\Public\eai-setup-defender-add.json'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 1 }
$item = Get-Item -LiteralPath $path -ErrorAction Stop
$acl = Get-Acl -LiteralPath $path -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18') { exit 1 }
Get-Content -Raw -LiteralPath $path
POWERSHELL
      ;;
    remove)
      guest_system_ps >"$raw_receipt" 2>/dev/null <<'POWERSHELL' || return 1
$path = 'C:\Users\Public\eai-setup-defender-remove.json'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 1 }
$item = Get-Item -LiteralPath $path -ErrorAction Stop
$acl = Get-Acl -LiteralPath $path -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18') { exit 1 }
Get-Content -Raw -LiteralPath $path
POWERSHELL
      ;;
    *) return 2 ;;
  esac
  EAI_DEFENDER_ACTION="$action" EAI_DEFENDER_EXPECTED_STATUS="$expected_status" \
    EAI_DEFENDER_EXPECTED_HASH="${host_hash:-}" \
    EAI_DEFENDER_EXPECTED_WORKER_HASH="${defender_worker_hash:-}" \
    EAI_DEFENDER_EXPECTED_WORKER_NONCE="${defender_worker_nonce:-}" \
    EAI_DEFENDER_RAW="$raw_receipt" EAI_DEFENDER_DESTINATION="$destination" node --input-type=module <<'NODE'
import fs from "node:fs";

const receipt = JSON.parse(fs.readFileSync(process.env.EAI_DEFENDER_RAW, "utf8"));
const action = process.env.EAI_DEFENDER_ACTION;
const expectedStatus = process.env.EAI_DEFENDER_EXPECTED_STATUS;
const expectedHash = process.env.EAI_DEFENDER_EXPECTED_HASH;
const expectedWorkerHash = process.env.EAI_DEFENDER_EXPECTED_WORKER_HASH;
const expectedWorkerNonce = process.env.EAI_DEFENDER_EXPECTED_WORKER_NONCE;
const validDate = (value) => typeof value === "string" && !Number.isNaN(Date.parse(value));
if (receipt.schemaVersion !== "eai-defender-exact-file/v1" || receipt.action !== action) throw new Error("Invalid Defender evidence schema.");
if (receipt.assetName !== "eai-setup-under-test.exe" || !/^[0-9a-f]{64}$/.test(receipt.assetSha256 || "")) throw new Error("Invalid Defender asset evidence.");
if (receipt.scope !== "exact-file" || receipt.diagnosticOnly !== true || receipt.productionGate !== false) throw new Error("Unsafe Defender evidence scope.");
if (expectedHash && receipt.assetSha256 !== expectedHash) throw new Error("Defender evidence identifies a different release asset hash.");
if (receipt.guardianWorkerSha256 !== expectedWorkerHash || !/^[0-9a-f]{64}$/.test(expectedWorkerHash || "")) throw new Error("Defender evidence identifies a different detached guardian payload.");
if (receipt.guardianWorkerNonce !== expectedWorkerNonce || !/^[0-9a-f]{32}$/.test(expectedWorkerNonce || "")) throw new Error("Defender evidence is stale or belongs to another run.");
if (!validDate(receipt.recordedAt)) throw new Error("Defender evidence has no valid timestamp.");
if (!Number.isInteger(receipt.guardianProcessId) || receipt.guardianProcessId <= 0 || !validDate(receipt.guardianProcessStartedAt)) {
  throw new Error("Defender evidence has no valid detached guardian process tuple.");
}
const allowedStatuses = action === "add"
  ? ["pending", "awaiting-target", "ready", "refused-existing"]
  : ["removed-verified", "preexisting-preserved", "cleanup-failed"];
if (!allowedStatuses.includes(receipt.status)) throw new Error(`Invalid Defender ${action} status.`);
const safe = {
  schemaVersion: receipt.schemaVersion,
  action,
  status: receipt.status,
  assetName: receipt.assetName,
  assetSha256: receipt.assetSha256,
  scope: receipt.scope,
  diagnosticOnly: true,
  productionGate: false,
  elevationMethod: receipt.elevationMethod,
  uacUsed: receipt.uacUsed === true,
  systemIdentityVerified: receipt.systemIdentityVerified === true,
  administratorRoleVerified: receipt.administratorRoleVerified === true,
  receiptSystemOwned: receipt.receiptSystemOwned === true,
  guardianWorkerSha256: receipt.guardianWorkerSha256,
  guardianWorkerNonceBound: receipt.guardianWorkerNonce === expectedWorkerNonce,
  guardianProcessId: receipt.guardianProcessId,
  workerScriptHashVerified: receipt.workerScriptHashVerified === true,
  workerProcessPathVerified: receipt.workerProcessPathVerified === true,
  workerSessionVerified: receipt.workerSessionVerified === true,
  guardianProcessStartedAt: receipt.guardianProcessStartedAt,
  ownedByGuardian: receipt.ownedByGuardian === true,
  removedByGuardian: receipt.removedByGuardian === true,
  preexistingExactExclusion: receipt.preexistingExactExclusion === true,
  precheckProbeVerified: receipt.precheckProbeVerified === true,
  effectiveExclusionPresentBefore: typeof receipt.effectiveExclusionPresentBefore === "boolean"
    ? receipt.effectiveExclusionPresentBefore
    : null,
  exactExclusionPresent: receipt.exactExclusionPresent === true,
  exactExclusionAbsent: receipt.exactExclusionAbsent === true,
  soleExclusionDelta: receipt.soleExclusionDelta === true,
  targetHashVerified: receipt.targetHashVerified === true,
  completionSignalVerified: receipt.completionSignalVerified === true,
  baselineExclusionSetRestored: receipt.baselineExclusionSetRestored === true,
  mpCmdRunVerified: receipt.mpCmdRunVerified === true,
  mpCmdRunVerifiedNotExcluded: receipt.mpCmdRunVerifiedNotExcluded === true,
  protectionEnabled: receipt.protectionEnabled === true,
  protectionSettingsUnchanged: receipt.protectionSettingsUnchanged === true,
  cleanupVerified: receipt.cleanupVerified === true,
  guardianTimedOut: receipt.guardianTimedOut === true,
  guardianTimeoutSeconds: Number.isInteger(receipt.guardianTimeoutSeconds)
    ? receipt.guardianTimeoutSeconds
    : null,
  recordedAt: receipt.recordedAt,
};
fs.writeFileSync(process.env.EAI_DEFENDER_DESTINATION, `${JSON.stringify(safe, null, 2)}\n`);
if (receipt.elevationMethod !== "parallels-protected-LocalSystem"
    || receipt.uacUsed !== false
    || receipt.systemIdentityVerified !== true
    || receipt.administratorRoleVerified !== true) {
  throw new Error("Defender evidence does not prove the protected LocalSystem channel.");
}
  if (receipt.status === "ready" && (receipt.ownedByGuardian !== true
    || receipt.guardianWorkerNonce !== expectedWorkerNonce
    || receipt.workerScriptHashVerified !== true
    || receipt.workerProcessPathVerified !== true
    || receipt.workerSessionVerified !== true
    || receipt.receiptSystemOwned !== true
    || receipt.preexistingExactExclusion !== false
    || receipt.effectiveExclusionPresentBefore !== false
    || receipt.precheckProbeVerified !== true
    || receipt.exactExclusionPresent !== true
    || receipt.soleExclusionDelta !== true
    || receipt.completionSignalVerified !== true
    || receipt.targetHashVerified !== true
    || receipt.mpCmdRunVerified !== true
    || receipt.protectionEnabled !== true
    || receipt.protectionSettingsUnchanged !== true
    || receipt.guardianTimeoutSeconds !== 900)) {
  throw new Error("The Defender add receipt is not a complete exact-file proof.");
}
if (receipt.status === "removed-verified" && (receipt.ownedByGuardian !== true
    || receipt.guardianWorkerNonce !== expectedWorkerNonce
    || receipt.workerScriptHashVerified !== true
    || receipt.workerProcessPathVerified !== true
    || receipt.workerSessionVerified !== true
    || receipt.receiptSystemOwned !== true
    || receipt.removedByGuardian !== true
    || receipt.preexistingExactExclusion !== false
    || receipt.exactExclusionAbsent !== true
    || receipt.baselineExclusionSetRestored !== true
    || receipt.mpCmdRunVerifiedNotExcluded !== true
    || receipt.protectionSettingsUnchanged !== true
    || receipt.cleanupVerified !== true
    || receipt.guardianTimedOut !== false)) {
  throw new Error("The Defender removal receipt is not a complete cleanup proof.");
}
if (expectedStatus !== "any" && receipt.status !== expectedStatus) throw new Error(`Unexpected Defender ${action} status: ${receipt.status}`);
NODE
}

write_unarmed_defender_guardian_quarantine() {
  local destination=""
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 1
  destination="$(dirname "$EAI_VM_RESULT_FILE")/windows-defender-guardian-unarmed-quarantine.json"
  EAI_DEFENDER_UNARMED_DESTINATION="$destination" \
  EAI_DEFENDER_UNARMED_VM="$vm_name" \
  EAI_DEFENDER_UNARMED_SNAPSHOT="$snapshot_id" \
  EAI_DEFENDER_UNARMED_PHASE="$phase" \
  EAI_DEFENDER_UNARMED_ASSET_HASH="${host_hash:-}" \
  EAI_DEFENDER_UNARMED_WORKER_HASH="${defender_worker_hash:-}" \
    node --input-type=module <<'NODE'
import { writeFileSync } from "node:fs";
const diagnostic = {
  schemaVersion: "eai-windows-defender-unarmed-quarantine/v1",
  recordedAt: new Date().toISOString(),
  vm: process.env.EAI_DEFENDER_UNARMED_VM,
  approvedSnapshot: process.env.EAI_DEFENDER_UNARMED_SNAPSHOT,
  failedPhase: process.env.EAI_DEFENDER_UNARMED_PHASE,
  assetSha256: /^[0-9a-f]{64}$/.test(process.env.EAI_DEFENDER_UNARMED_ASSET_HASH || "")
    ? process.env.EAI_DEFENDER_UNARMED_ASSET_HASH
    : null,
  guardianWorkerSha256: /^[0-9a-f]{64}$/.test(process.env.EAI_DEFENDER_UNARMED_WORKER_HASH || "")
    ? process.env.EAI_DEFENDER_UNARMED_WORKER_HASH
    : null,
  cleanupSignalPublished: true,
  guardianArmReceiptObserved: false,
  exclusionCleanupVerified: false,
  quarantineRequired: true,
  restoreApprovedSnapshotBeforeReuse: true,
  diagnosticOnly: true,
  productionGate: false,
};
writeFileSync(process.env.EAI_DEFENDER_UNARMED_DESTINATION, `${JSON.stringify(diagnostic, null, 2)}\n`, { mode: 0o600 });
NODE
}

stop_defender_guardian() {
  local expected_hash="${host_hash:-}"
  local expected_worker_hash="${defender_worker_hash:-}"
  local expected_worker_nonce="${defender_worker_nonce:-}"
  local evidence_status=1
  local signal_sent=0
  local worker_exited=0
  local attempt
  [[ "$defender_exclusion_pending" == 1 ]] || return 0
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$expected_worker_hash" =~ ^[0-9a-f]{64}$ \
    && "$expected_worker_nonce" =~ ^[0-9a-f]{32}$ ]] || return 2
  for attempt in $(seq 1 5); do
    if guest_system_ps_run "$expected_hash"$'\n'"$expected_worker_hash"$'\n'"$expected_worker_nonce"$'\n' 1 >/dev/null 2>&1 <<'POWERSHELL'; then
$expectedSha256 = [Console]::In.ReadLine()
$expectedWorkerSha256 = [Console]::In.ReadLine()
$expectedWorkerNonce = [Console]::In.ReadLine()
$systemSid = 'S-1-5-18'
$finalPath = 'C:\Users\Public\eai-setup-defender-done.signal'
$temporaryPath = 'C:\Users\Public\eai-setup-defender-done.signal.tmp'
$expectedValue = "cleanup:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}"
function Assert-Marker([string]$path) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase) -or
      $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid -or
      (Get-Content -Raw -LiteralPath $path).Trim() -cne $expectedValue) { throw 'Invalid Defender cleanup marker.' }
}
if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
  Assert-Marker $finalPath
  if (Test-Path -LiteralPath $temporaryPath) { throw 'Both Defender cleanup marker paths are occupied.' }
  exit 0
}
if (Test-Path -LiteralPath $temporaryPath) {
  Assert-Marker $temporaryPath
  Move-Item -LiteralPath $temporaryPath -Destination $finalPath -ErrorAction Stop
  Assert-Marker $finalPath
  exit 0
}
$stream = $null
try {
  $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $bytes = [Text.Encoding]::ASCII.GetBytes($expectedValue)
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush($true)
} finally {
  if ($null -ne $stream) { $stream.Dispose() }
}
$acl = Get-Acl -LiteralPath $temporaryPath -ErrorAction Stop
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new($systemSid))
Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
Assert-Marker $temporaryPath
Move-Item -LiteralPath $temporaryPath -Destination $finalPath -ErrorAction Stop
Assert-Marker $finalPath
POWERSHELL
      signal_sent=1
      break
    fi
    sleep 2
  done
  if [[ "$signal_sent" != 1 ]]; then
    printf '%s Defender cleanup signal unavailable; waiting for the guardian hard timeout.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  fi
  # If the stateful bootstrap returned ambiguously before any guardian arm or
  # Defender receipt existed, the nonce-bound cleanup marker prevents a late
  # worker from entering its mutation path. Finite absence is still not a
  # terminal cleanup proof, so fail fast into snapshot quarantine instead of
  # polling sixteen minutes for a removal receipt that cannot be authoritative.
  if [[ "$signal_sent" == 1 ]] && guest_system_ps_run \
    "$expected_hash"$'\n'"$expected_worker_hash"$'\n'"$expected_worker_nonce"$'\n' 2 \
    >/dev/null 2>&1 <<'POWERSHELL'; then
$expectedSha256 = [Console]::In.ReadLine()
$expectedWorkerSha256 = [Console]::In.ReadLine()
$expectedWorkerNonce = [Console]::In.ReadLine()
$systemSid = 'S-1-5-18'
$doneSignal = 'C:\Users\Public\eai-setup-defender-done.signal'
$expectedDone = "cleanup:${expectedSha256}:${expectedWorkerSha256}:${expectedWorkerNonce}"
$ambiguousEvidence = @(
  'C:\Users\Public\eai-setup-defender-guardian-armed.json',
  'C:\Users\Public\eai-setup-defender-guardian-armed.json.tmp',
  'C:\Users\Public\eai-setup-defender-add.json',
  'C:\Users\Public\eai-setup-defender-add.json.tmp',
  'C:\Users\Public\eai-setup-defender-remove.json',
  'C:\Users\Public\eai-setup-defender-remove.json.tmp',
  'C:\Users\Public\eai-setup-under-test.exe'
)
if ($ambiguousEvidence | Where-Object { Test-Path -LiteralPath $_ }) { exit 1 }
$item = Get-Item -LiteralPath $doneSignal -ErrorAction Stop
$acl = Get-Acl -LiteralPath $doneSignal -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($item.FullName, $doneSignal, [StringComparison]::OrdinalIgnoreCase) -or
    $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid -or
    (Get-Content -Raw -LiteralPath $doneSignal).Trim() -cne $expectedDone) { exit 1 }
exit 0
POWERSHELL
    defender_cleanup_wait_exhausted=1
    write_unarmed_defender_guardian_quarantine >/dev/null 2>&1 || true
    return 1
  fi
  for attempt in $(seq 1 960); do
    if guest_system_ps_run "$expected_hash"$'\n'"$expected_worker_hash"$'\n'"$expected_worker_nonce"$'\n' 2 \
      >"$work_dir/defender-remove-poll.out" 2>&1 <<'POWERSHELL'; then
$expectedSha256 = [Console]::In.ReadLine()
$expectedWorkerSha256 = [Console]::In.ReadLine()
$expectedWorkerNonce = [Console]::In.ReadLine()
$path = 'C:\Users\Public\eai-setup-defender-remove.json'
$item = Get-Item -LiteralPath $path -ErrorAction Stop
$acl = Get-Acl -LiteralPath $path -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18') { exit 1 }
$value = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
if ($value.schemaVersion -ne 'eai-defender-exact-file/v1' -or $value.action -ne 'remove' -or
    $value.assetSha256 -cne $expectedSha256 -or $value.guardianWorkerSha256 -cne $expectedWorkerSha256 -or
    $value.guardianWorkerNonce -cne $expectedWorkerNonce -or $value.guardianProcessId -notmatch '^[1-9][0-9]*$') { exit 1 }
if ($value.status -ne 'removed-verified' -or $value.systemIdentityVerified -ne $true -or
    $value.administratorRoleVerified -ne $true -or $value.receiptSystemOwned -ne $true -or
    $value.ownedByGuardian -ne $true -or $value.removedByGuardian -ne $true -or
    $value.preexistingExactExclusion -ne $false -or $value.exactExclusionAbsent -ne $true -or
    $value.baselineExclusionSetRestored -ne $true -or $value.mpCmdRunVerifiedNotExcluded -ne $true -or
    $value.protectionSettingsUnchanged -ne $true -or $value.cleanupVerified -ne $true -or
    $value.guardianTimedOut -ne $false -or $value.workerScriptHashVerified -ne $true -or
    $value.workerProcessPathVerified -ne $true -or $value.workerSessionVerified -ne $true) {
  Write-Output 'GUARDIAN_UNSAFE_TERMINAL'
  exit 3
}
$process = Get-Process -Id ([int]$value.guardianProcessId) -ErrorAction SilentlyContinue
if ($null -eq $process) { exit 0 }
try { $processPath = $process.Path } catch { exit 1 }
$sameWorker = [string]::Equals($processPath, (Join-Path $PSHOME 'powershell.exe'), [StringComparison]::OrdinalIgnoreCase) -and
  $process.SessionId -eq 0 -and
  $process.StartTime.ToUniversalTime() -eq [DateTime]::Parse($value.guardianProcessStartedAt).ToUniversalTime()
if ($sameWorker) { exit 1 }
# PID reuse proves the recorded guardian exited; never terminate the replacement.
exit 0
POWERSHELL
      worker_exited=1
      break
    fi
    if /usr/bin/grep -Fq 'GUARDIAN_UNSAFE_TERMINAL' "$work_dir/defender-remove-poll.out" 2>/dev/null; then
      preserve_defender_evidence remove any >/dev/null 2>&1 || true
      return 1
    fi
    sleep 1
  done
  if [[ "$worker_exited" != 1 ]]; then
    defender_cleanup_wait_exhausted=1
    preserve_defender_evidence remove any >/dev/null 2>&1 || true
    return 1
  fi
  if preserve_defender_evidence remove removed-verified; then
    evidence_status=0
  else
    evidence_status=$?
  fi
  if [[ "$evidence_status" == 0 ]]; then
    defender_exclusion_pending=0
    defender_cleanup_wait_exhausted=0
    defender_exclusion_removed=1
    return 0
  fi
  return 1
}

write_detached_transport_return_proof() {
  local mode="$1"
  local nonce="$2"
  local started_ms="$3"
  local returned_ms="$4"
  local transport_status="$5"
  local evidence_dir=""
  local destination=""
  [[ "$mode" == normal || "$mode" == e2e ]] || return 2
  [[ "$nonce" =~ ^[0-9a-f]{32}$ && "$started_ms" =~ ^[0-9]+$ && "$returned_ms" =~ ^[0-9]+$ \
      && "$transport_status" =~ ^[0-9]+$ ]] || return 2
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 0
  evidence_dir="$(dirname "$EAI_VM_RESULT_FILE")"
  mkdir -p "$evidence_dir"
  destination="$evidence_dir/windows-${mode}-transport-return.json"
  EAI_WINDOWS_TRANSPORT_PROOF_DESTINATION="$destination" \
  EAI_WINDOWS_TRANSPORT_PROOF_MODE="$mode" \
  EAI_WINDOWS_TRANSPORT_PROOF_NONCE="$nonce" \
  EAI_WINDOWS_TRANSPORT_PROOF_STARTED_MS="$started_ms" \
  EAI_WINDOWS_TRANSPORT_PROOF_RETURNED_MS="$returned_ms" \
  EAI_WINDOWS_TRANSPORT_PROOF_STATUS="$transport_status" \
    node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";

const destination = process.env.EAI_WINDOWS_TRANSPORT_PROOF_DESTINATION;
const mode = process.env.EAI_WINDOWS_TRANSPORT_PROOF_MODE;
const nonce = process.env.EAI_WINDOWS_TRANSPORT_PROOF_NONCE;
const startedMs = Number(process.env.EAI_WINDOWS_TRANSPORT_PROOF_STARTED_MS);
const returnedMs = Number(process.env.EAI_WINDOWS_TRANSPORT_PROOF_RETURNED_MS);
const transportExitStatus = Number(process.env.EAI_WINDOWS_TRANSPORT_PROOF_STATUS);
if (!destination || !["normal", "e2e"].includes(mode) || !/^[0-9a-f]{32}$/.test(nonce)
    || !Number.isSafeInteger(startedMs) || !Number.isSafeInteger(returnedMs)
    || returnedMs < startedMs || !Number.isSafeInteger(transportExitStatus)) {
  throw new Error("Invalid Windows transport-return proof inputs.");
}
const proof = {
  schemaVersion: "eai-windows-detached-transport-return/v1",
  status: "passed",
  mode,
  launchNonceSha256: crypto.createHash("sha256").update(nonce).digest("hex"),
  transport: "prlctl-exec-current-user",
  launchBroker: "local-win32-process-create",
  transportExitStatus,
  transportStartedAt: new Date(startedMs).toISOString(),
  transportReturnedAt: new Date(returnedMs).toISOString(),
  transportElapsedMs: returnedMs - startedMs,
  transportReturned: true,
  childAliveValidatedAfterReturn: true,
  providerBrokeredJobEscapeProven: true,
  protectedValuesRecorded: false,
  sanitized: true,
};
const temporary = `${destination}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(proof, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, destination);
NODE
}

# This Parallels build serializes guest-exec transports while an application
# remains in the current-user command's monitored lineage. Stage one fixed
# no-secret bootstrap as LocalSystem, send protected E2E values only over raw
# process stdin, and have local WMI broker the GUI process outside that lineage.
launch_guest_app_detached() {
  local mode="$1"
  local protected_payload="$2"
  local expected_executable_hash="$3"
  local attempt="${4:-1}"
  local max_attempts=3
  local launch_nonce=""
  local bootstrap_script=""
  local bootstrap_base64=""
  local bootstrap_hash=""
  local bootstrap_output=""
  local bootstrap_status=1
  local cleanup_status=0
  local recursive_status=1
  local pid_file=""
  local receipt_file=""
  local arm_file=""
  local transport_started_ms=""
  local transport_returned_ms=""
  [[ "$mode" == normal || "$mode" == e2e ]] || return 2
  [[ "$expected_executable_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$attempt" =~ ^[1-9][0-9]*$ && "$attempt" -le "$max_attempts" ]] || return 2
  launch_nonce="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$launch_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
  bootstrap_script="$(/bin/cat <<'POWERSHELL'
param(
  [Parameter(Mandatory = $true)][ValidateSet('normal', 'e2e')][string]$Mode,
  [Parameter(Mandatory = $true)][string]$LaunchNonce,
  [Parameter(Mandatory = $true)][string]$ExpectedExecutableSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedBootstrapSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedUser
)
$ErrorActionPreference = 'Stop'
$bootstrapPath = 'C:\Users\Public\eai-setup-app-bootstrap.ps1'
$executableFile = 'C:\Users\Public\eai-setup-e2e-executable.txt'
$pidPath = if ($Mode -eq 'normal') { 'C:\Users\Public\eai-setup-normal.pid' } else { 'C:\Users\Public\eai-setup-e2e.pid' }
$pidTemporary = "$pidPath.tmp"
$receiptPath = if ($Mode -eq 'normal') { 'C:\Users\Public\eai-setup-normal-launch.json' } else { 'C:\Users\Public\eai-setup-e2e-launch.json' }
$receiptTemporary = "$receiptPath.tmp"
$armPath = if ($Mode -eq 'normal') { 'C:\Users\Public\eai-setup-normal-launch-arm.json' } else { 'C:\Users\Public\eai-setup-e2e-launch-arm.json' }
$armTemporary = "$armPath.tmp"
$cancelPath = if ($Mode -eq 'normal') { 'C:\Users\Public\eai-setup-normal-launch-cancel.signal' } else { 'C:\Users\Public\eai-setup-e2e-launch-cancel.signal' }
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$tenantId = $null
$projectName = $null
$startupEnvironment = $null
$startupEnvironmentValues = $null
$wmiStartupClass = $null
$wmiStartup = $null
$wmiProcessClass = $null
$wmiResult = $null
$wmiCreatedProcess = $null
$process = $null
$executableLock = $null
$launchCommitted = $false
$wmiCallAttempted = $false
$createdProcessId = 0
$wmiReturnedAtUtc = $null
$processIdentityObservedAtUtc = $null

# The local Win32_Process provider creates the application outside the
# Parallels caller lineage. Native job inspection remains necessary evidence:
# the provider may put the child in its own job, which is safe only when the
# host transport has returned while the exact child remains alive.
if ($null -eq ('EaiReleaseE2E.NativeProcess' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace EaiReleaseE2E {
  public static class NativeProcess {
    [DllImport("kernel32.dll", ExactSpelling = true)]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", EntryPoint = "IsProcessInJob", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsProcessInJob(
      IntPtr processHandle,
      IntPtr jobHandle,
      [MarshalAs(UnmanagedType.Bool)] out bool result);
  }
}
'@ -ErrorAction Stop
}

function Set-RestrictedUserReceiptAcl([string]$path, [Security.Principal.SecurityIdentifier]$userSid) {
  $acl = [Security.AccessControl.FileSecurity]::new()
  $acl.SetOwner($userSid)
  $acl.SetAccessRuleProtection($true, $false)
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($userSid, 'FullControl', 'Allow'))
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, 'FullControl', 'Allow'))
  Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop
}

function Write-AtomicRestrictedText([string]$path, [string]$temporary, [string]$value, [Security.Principal.SecurityIdentifier]$userSid) {
  if ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $temporary)) {
    throw "A detached app-launch path is already occupied: $path"
  }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($value)
  $stream = $null
  try {
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  Set-RestrictedUserReceiptAcl $temporary $userSid
  [IO.File]::Move($temporary, $path)
}

function Get-ExactProcesses([string]$path, [int]$sessionId) {
  $expectedComparablePath = ConvertTo-ComparableAppPath $path
  @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    if ($_.SessionId -ne $sessionId) { return $false }
    try {
      return [string]::Equals(
        (ConvertTo-ComparableAppPath $_.Path),
        $expectedComparablePath,
        [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
  })
}

function Get-WmiProcessEvidence([int]$processId) {
  $wmi = $null
  try {
    $wmi = [wmi]('\\.\root\cimv2:Win32_Process.Handle=''{0}''' -f $processId)
    if ($null -eq $wmi -or [int]$wmi.ProcessId -ne $processId) {
      throw 'The local WMI process tuple is unavailable.'
    }
    $owner = $wmi.GetOwner()
    $ownerSid = $wmi.GetOwnerSid()
    if ($owner.ReturnValue -ne 0 -or $ownerSid.ReturnValue -ne 0) {
      throw 'The local WMI process owner is unavailable.'
    }
    return [pscustomobject]@{
      CommandLine = [string]$wmi.CommandLine
      ParentProcessId = [int]$wmi.ParentProcessId
      SessionId = [int]$wmi.SessionId
      OwnerUser = [string]$owner.User
      OwnerSid = [string]$ownerSid.Sid
    }
  } finally {
    if ($null -ne $wmi) { $wmi.Dispose() }
  }
}

function ConvertTo-ComparableAppPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw 'A detached application path is empty.'
  }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Stop-ExactCreatedProcess(
  [Diagnostics.Process]$target,
  [string]$context,
  [string]$expectedPath,
  [int]$expectedSessionId,
  [string]$expectedOwnerSid,
  [DateTime]$armedAt,
  [DateTime]$wmiReturnedAt,
  [DateTime]$identityObservedAt,
  [string]$expectedCommandLine) {
  if ($null -eq $target) { return }
  $targetId = $target.Id
  try {
    $targetPath = ConvertTo-ComparableAppPath $target.Path
    $targetStartedAtUtc = $target.StartTime.ToUniversalTime()
    $targetStartedAt = $targetStartedAtUtc.ToString('o')
    $targetSessionId = $target.SessionId
  } catch {
    if ($target.WaitForExit(0)) { return }
    throw "$context cannot be rebound to its exact path/start tuple before termination."
  }
  $proveTerminated = {
    if (-not $target.WaitForExit(30000)) { throw "$context did not terminate within 30 seconds." }
    $replacement = Get-Process -Id $targetId -ErrorAction SilentlyContinue
    if ($null -ne $replacement) {
      try { $replacementStartedAt = $replacement.StartTime.ToUniversalTime().ToString('o') }
      catch { $replacementStartedAt = $null }
      $replacement.Dispose()
      if ($null -eq $targetStartedAt -or $replacementStartedAt -ceq $targetStartedAt) {
        throw "$context could not be proven terminated."
      }
    }
  }
  if ($target.WaitForExit(0)) {
    & $proveTerminated
    return
  }
  try {
    $evidence = Get-WmiProcessEvidence $targetId
  } catch {
    try { $racedToExitBeforeBinding = $target.WaitForExit(0) } catch { $racedToExitBeforeBinding = $false }
    if (-not $racedToExitBeforeBinding) { throw }
    & $proveTerminated
    return
  }
  if (-not [string]::Equals($targetPath, (ConvertTo-ComparableAppPath $expectedPath), [StringComparison]::OrdinalIgnoreCase) -or
      $targetSessionId -ne $expectedSessionId -or $wmiReturnedAt -lt $armedAt -or
      $identityObservedAt -lt $wmiReturnedAt -or $targetStartedAtUtc -lt $armedAt -or
      $targetStartedAtUtc -gt $identityObservedAt -or
      $evidence.OwnerSid -cne $expectedOwnerSid -or $evidence.SessionId -ne $expectedSessionId -or
      (-not [string]::IsNullOrEmpty($expectedCommandLine) -and $evidence.CommandLine -cne $expectedCommandLine)) {
    throw "$context does not match the exact path/session/owner/post-arm/command-line binding."
  }
  if (-not $target.WaitForExit(0)) {
    try { $target.Kill() }
    catch {
      try { $racedToExit = $target.WaitForExit(0) } catch { $racedToExit = $false }
      if (-not $racedToExit) { throw }
    }
  }
  & $proveTerminated
}

function New-WmiStartupEnvironment([string]$mode, [string]$tenant, [string]$project) {
  $environment = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
  $currentEnvironment = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
  foreach ($entry in $currentEnvironment.GetEnumerator()) {
    $name = [string]$entry.Key
    $value = [string]$entry.Value
    if (-not $name -or $name.IndexOf([char]'=') -ge 0 -or
        $name.IndexOf([char]0) -ge 0 -or
        $value.IndexOf([char]0) -ge 0) {
      throw 'The current-user bootstrap environment contains an invalid name or value.'
    }
    if ($name.StartsWith('EAI_SETUP_E2E', [StringComparison]::OrdinalIgnoreCase)) { continue }
    $environment[$name] = $value
  }
  if ($mode -eq 'e2e') {
    $environment['EAI_SETUP_E2E'] = '1'
    $environment['EAI_SETUP_E2E_PROJECT_NAME'] = $project
    $environment['EAI_SETUP_E2E_DIRECTORY'] = 'C:\Users\Public\EAIReleaseTests'
    $environment['EAI_SETUP_E2E_COMPANY_TENANT'] = $tenant
    $environment['EAI_SETUP_E2E_RECEIPT_FILE'] = 'C:\Users\Public\eai-setup-e2e-receipt.json'
  }
  $values = [Collections.Generic.List[string]]::new()
  $e2eCount = 0
  foreach ($entry in $environment.GetEnumerator()) {
    if ([string]$entry.Key -cmatch '^EAI_SETUP_E2E(?:$|_)') { $e2eCount += 1 }
    $values.Add(('{0}={1}' -f [string]$entry.Key, [string]$entry.Value))
  }
  $expectedE2eCount = if ($mode -eq 'e2e') { 5 } else { 0 }
  if ($values.Count -eq 0 -or $e2eCount -ne $expectedE2eCount) {
    throw 'The private WMI startup environment has an invalid E2E-variable contract.'
  }
  return [pscustomobject]@{ Values = [string[]]$values.ToArray(); E2eVariableCount = $e2eCount }
}

function Clear-WmiStartupEnvironment([object]$startupEnvironmentValue, [string[]]$values) {
  if ($null -ne $values) {
    for ($index = 0; $index -lt $values.Length; $index++) { $values[$index] = $null }
  }
  if ($null -ne $startupEnvironmentValue) {
    $startupEnvironmentValue.Values = $null
    $startupEnvironmentValue.E2eVariableCount = 0
  }
}

function Assert-LaunchNotCancelled() {
  if (-not (Test-Path -LiteralPath $cancelPath)) { return }
  $expectedCancel = 'cancel:{0}:{1}:{2}:{3}' -f $Mode, $LaunchNonce, $ExpectedBootstrapSha256, $ExpectedExecutableSha256
  $expectedCancelUserSid = ([Security.Principal.NTAccount]::new("$env:COMPUTERNAME\$ExpectedUser")).Translate([Security.Principal.SecurityIdentifier])
  $item = Get-Item -LiteralPath $cancelPath -ErrorAction Stop
  $acl = Get-Acl -LiteralPath $cancelPath -ErrorAction Stop
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $systemRules = @($rules | Where-Object {
    $_.IdentityReference.Value -ceq $systemSid.Value -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
  })
  $userRules = @($rules | Where-Object {
    $_.IdentityReference.Value -ceq $expectedCancelUserSid.Value -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read) -eq [Security.AccessControl.FileSystemRights]::Read -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0 -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) -eq 0
  })
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $cancelPath, [StringComparison]::OrdinalIgnoreCase) -or
      $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid.Value -or
      -not $acl.AreAccessRulesProtected -or $rules.Count -ne 2 -or $systemRules.Count -ne 1 -or $userRules.Count -ne 1 -or
      (Get-Content -Raw -LiteralPath $cancelPath).Trim() -cne $expectedCancel) {
    throw 'A detached launch cancellation path exists but is not the exact LocalSystem-owned run binding.'
  }
  throw 'The detached application launch was cancelled at its local-WMI boundary.'
}

try {
  if ($LaunchNonce -cnotmatch '^[0-9a-f]{32}$' -or $ExpectedExecutableSha256 -cnotmatch '^[0-9a-f]{64}$' -or
      $ExpectedBootstrapSha256 -cnotmatch '^[0-9a-f]{64}$' -or $ExpectedUser -cnotmatch '^[A-Za-z0-9._-]+$') {
    throw 'The detached app bootstrap trust inputs are invalid.'
  }
  Assert-LaunchNotCancelled
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $bootstrapProcess = Get-Process -Id $PID -ErrorAction Stop
  $sessionId = $bootstrapProcess.SessionId
  $explorer = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Select-Object -First 1
  if ($identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) -or
      -not $identity.Name.EndsWith("\$ExpectedUser", [StringComparison]::OrdinalIgnoreCase) -or
      -not [Environment]::UserInteractive -or $sessionId -le 0 -or $null -eq $explorer) {
    throw 'The detached app bootstrap is not in the expected interactive user session.'
  }
  $bootstrapItem = Get-Item -LiteralPath $bootstrapPath -ErrorAction Stop
  $bootstrapAcl = Get-Acl -LiteralPath $bootstrapPath -ErrorAction Stop
  $bootstrapRules = @($bootstrapAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $bootstrapSystemRules = @($bootstrapRules | Where-Object {
    $_.IdentityReference.Value -ceq $systemSid.Value -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
  })
  $bootstrapUserRules = @($bootstrapRules | Where-Object {
    $_.IdentityReference.Value -ceq $identity.User.Value -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0 -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) -eq 0
  })
  if ($bootstrapItem.PSIsContainer -or (($bootstrapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($bootstrapItem.FullName, $bootstrapPath, [StringComparison]::OrdinalIgnoreCase) -or
      $bootstrapAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid.Value -or
      -not $bootstrapAcl.AreAccessRulesProtected -or $bootstrapRules.Count -ne 2 -or
      $bootstrapSystemRules.Count -ne 1 -or $bootstrapUserRules.Count -ne 1) {
    throw 'The detached app bootstrap is not the protected LocalSystem-owned script.'
  }
  $bootstrapLock = [IO.File]::Open($bootstrapPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $bootstrapHasher = [Security.Cryptography.SHA256]::Create()
  try {
    $actualBootstrapSha256 = ([BitConverter]::ToString($bootstrapHasher.ComputeHash($bootstrapLock))).Replace('-', '').ToLowerInvariant()
  } finally {
    $bootstrapHasher.Dispose()
    $bootstrapLock.Dispose()
  }
  if ($actualBootstrapSha256 -cne $ExpectedBootstrapSha256) { throw 'The detached app bootstrap hash is invalid.' }

  if ($Mode -eq 'e2e') {
    $tenantId = [Console]::In.ReadLine()
    $projectName = [Console]::In.ReadLine()
    if ($tenantId -cnotmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        $projectName -cnotmatch '^[a-z0-9](?:[a-z0-9-]{1,62}[a-z0-9])?$' -or $null -ne [Console]::In.ReadLine()) {
      throw 'The raw protected E2E stdin failed its exact two-line schema.'
    }
    $tenantId = $tenantId.ToLowerInvariant()
  }

  foreach ($path in @($pidPath, $pidTemporary, $receiptPath, $receiptTemporary, $armPath, $armTemporary)) {
    if (Test-Path -LiteralPath $path) { throw "A detached app-launch path is already occupied: $path" }
  }
  $executable = (Get-Content -Raw -LiteralPath $executableFile).Trim()
  $executableItem = Get-Item -LiteralPath $executable -ErrorAction Stop
  if ($executableItem.PSIsContainer -or (($executableItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($executableItem.FullName, $executable, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The detached app executable is not the canonical regular installed file.'
  }
  $executableLock = [IO.File]::Open($executable, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $executableHasher = [Security.Cryptography.SHA256]::Create()
  try {
    $actualExecutableSha256 = ([BitConverter]::ToString($executableHasher.ComputeHash($executableLock))).Replace('-', '').ToLowerInvariant()
    $executableLock.Position = 0
  } finally {
    $executableHasher.Dispose()
  }
  if ($actualExecutableSha256 -cne $ExpectedExecutableSha256) { throw 'The installed executable changed before detached launch.' }
  $preexistingExactProcesses = @(Get-ExactProcesses $executable $sessionId)
  try {
    if ($preexistingExactProcesses.Count -ne 0) { throw 'An exact EAI Setup process already exists before detached launch.' }
  } finally {
    foreach ($preexistingProcess in $preexistingExactProcesses) { $preexistingProcess.Dispose() }
  }
  $bootstrapInJob = $false
  if (-not [EaiReleaseE2E.NativeProcess]::IsProcessInJob(
      [EaiReleaseE2E.NativeProcess]::GetCurrentProcess(), [IntPtr]::Zero, [ref]$bootstrapInJob)) {
    $bootstrapJobError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw [ComponentModel.Win32Exception]::new($bootstrapJobError, 'The bootstrap job membership could not be queried.')
  }
  if (-not $bootstrapInJob) { throw 'The Parallels bootstrap is unexpectedly outside a job object.' }
  $bootstrapStartedAt = $bootstrapProcess.StartTime.ToUniversalTime().ToString('o')
  $armedAt = [DateTime]::UtcNow.ToString('o')
  $arm = [ordered]@{
    schemaVersion = 'eai-windows-detached-app-launch-arm/v2'
    status = 'armed'
    mode = $Mode
    launchNonce = $LaunchNonce
    executableSha256 = $actualExecutableSha256
    bootstrapSha256 = $actualBootstrapSha256
    bootstrapProcessId = $PID
    bootstrapProcessStartedAt = $bootstrapStartedAt
    processSessionId = $sessionId
    processOwnerSid = $identity.User.Value
    bootstrapInJob = $bootstrapInJob
    launchBroker = 'local-win32-process-create'
    wmiDispatchPending = $true
    armedAt = $armedAt
  }
  Write-AtomicRestrictedText $armPath $armTemporary ($arm | ConvertTo-Json -Compress) $identity.User

  $workingDirectory = Split-Path -Parent $executable
  if ([string]::IsNullOrWhiteSpace($workingDirectory) -or $executable.IndexOf([char]'"') -ge 0 -or
      $executable.IndexOf([char]0) -ge 0 -or $executable.IndexOf([char]13) -ge 0 -or
      $executable.IndexOf([char]10) -ge 0) {
    throw 'The canonical WMI executable command line cannot be represented exactly.'
  }
  $commandLine = '"' + $executable + '"'
  $startupEnvironment = New-WmiStartupEnvironment $Mode $tenantId $projectName
  $startupEnvironmentValues = [string[]]$startupEnvironment.Values
  $e2eEnvironmentVariableCount = [int]$startupEnvironment.E2eVariableCount
  $creationFlags = [uint32]1536
  $childInJob = $false
  $processEvidence = $null
  $processStartedAt = $null
  $wmiReturnValue = [uint32]::MaxValue
  $launchFailure = $null
  try {
    $wmiStartupClass = [wmiclass]'\\.\root\cimv2:Win32_ProcessStartup'
    $wmiStartup = $wmiStartupClass.CreateInstance()
    $wmiStartup.CreateFlags = $creationFlags
    $wmiStartup.WinstationDesktop = 'winsta0\default'
    $wmiStartup.EnvironmentVariables = $startupEnvironmentValues
    $wmiProcessClass = [wmiclass]'\\.\root\cimv2:Win32_Process'
    Assert-LaunchNotCancelled
    $wmiCallAttempted = $true
    $wmiResult = $wmiProcessClass.Create($commandLine, $workingDirectory, $wmiStartup)
    $wmiReturnedAtUtc = [DateTime]::UtcNow
    if ($null -ne $wmiResult) {
      $wmiReturnValue = [uint32]$wmiResult.ReturnValue
      $createdProcessId = [int]$wmiResult.ProcessId
    }
    # This check is deliberately the first operation after capturing the WMI
    # result tuple. A cancellation must terminate and wait the exact returned
    # PID before this bootstrap is allowed to throw.
    Assert-LaunchNotCancelled
    if ($null -eq $wmiResult -or $wmiReturnValue -ne 0 -or $createdProcessId -le 0) {
      throw "Local Win32_Process.Create failed with return value $wmiReturnValue and no valid process tuple."
    }
    $tenantId = $null
    $projectName = $null
    $process = Get-Process -Id $createdProcessId -ErrorAction Stop
    [void]$process.Handle
    Start-Sleep -Milliseconds 250
    if ($process.WaitForExit(0)) { throw 'The local-WMI application exited before validation.' }
    try {
      $processPath = ConvertTo-ComparableAppPath $process.Path
      $processStartedAtUtc = $process.StartTime.ToUniversalTime()
      $processSessionId = $process.SessionId
      # WMI may return before Process.StartTime becomes observable. This bound
      # is captured only after the complete handle-backed tuple was read.
      $processIdentityObservedAtUtc = [DateTime]::UtcNow
    } catch {
      if ($process.WaitForExit(0)) { throw 'The local-WMI application exited during identity validation.' }
      throw 'The local-WMI application identity is unavailable.'
    }
    $armedAtUtc = [DateTime]::Parse($armedAt).ToUniversalTime()
    if (-not [string]::Equals($processPath, (ConvertTo-ComparableAppPath $executable), [StringComparison]::OrdinalIgnoreCase) -or
        $processSessionId -ne $sessionId -or $wmiReturnedAtUtc -lt $armedAtUtc -or
        $processIdentityObservedAtUtc -lt $wmiReturnedAtUtc -or
        $processStartedAtUtc -lt $armedAtUtc -or
        $processStartedAtUtc -gt $processIdentityObservedAtUtc) {
      throw 'The local-WMI application path/session/post-arm tuple is invalid.'
    }
    $processEvidence = Get-WmiProcessEvidence $createdProcessId
    if ($processEvidence.OwnerSid -cne $identity.User.Value -or
        -not [string]::Equals($processEvidence.OwnerUser, $ExpectedUser, [StringComparison]::OrdinalIgnoreCase) -or
        $processEvidence.SessionId -ne $sessionId -or $processEvidence.CommandLine -cne $commandLine) {
      throw 'The local-WMI application owner/session/command-line tuple is invalid.'
    }
    if (-not [EaiReleaseE2E.NativeProcess]::IsProcessInJob(
        $process.Handle, [IntPtr]::Zero, [ref]$childInJob)) {
      $childJobError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
      throw [ComponentModel.Win32Exception]::new($childJobError, 'The local-WMI child job state could not be observed.')
    }
    $processStartedAt = $processStartedAtUtc.ToString('o')
    $executableLock.Dispose()
    $executableLock = $null
    Write-AtomicRestrictedText $pidPath $pidTemporary ([string]$process.Id) $identity.User
    $receipt = [ordered]@{
      schemaVersion = 'eai-windows-detached-app-launch/v5'
      status = 'launched'
      mode = $Mode
      launchNonce = $LaunchNonce
      launchMechanism = 'local-win32-process-create'
      localWmiCall = $true
      wmiClass = 'Win32_Process'
      wmiMethod = 'Create'
      wmiReturnValue = [int]$wmiReturnValue
      providerBrokeredJobEscape = $true
      bootstrapSha256 = $actualBootstrapSha256
      bootstrapProcessId = $PID
      bootstrapProcessStartedAt = $bootstrapStartedAt
      bootstrapProcessSessionId = $sessionId
      protectedRuntimeInput = if ($Mode -eq 'e2e') { 'raw-process-stdin' } else { 'none' }
      protectedValuesInArguments = $false
      protectedLaunchInputFileCreated = $false
      protectedValuesInGlobalEnvironment = $false
      processOnlyStartupEnvironment = $true
      inheritedE2EEnvironmentVariablesStripped = $true
      e2eEnvironmentVariableCount = $e2eEnvironmentVariableCount
      childEnvironmentScoped = ($Mode -eq 'e2e')
      explicitChildEnvironmentBlock = $true
      unicodeChildEnvironmentBlock = $true
      bootstrapInJob = $bootstrapInJob
      childJobStateObserved = $true
      childInJob = $childInJob
      childJobAbsenceRequired = $false
      canonicalExecutableOnlyCommandLine = $true
      quotedExecutableCommandLine = $true
      startupInfoUsesStdHandles = $false
      desktop = 'winsta0\default'
      creationFlags = [int]$creationFlags
      emptyApplicationArguments = $true
      executableSha256 = $actualExecutableSha256
      processId = $process.Id
      processStartedAt = $processStartedAt
      processSessionId = $process.SessionId
      processOwnerSid = $identity.User.Value
      providerProcessId = $processEvidence.ParentProcessId
      armedAt = $armedAt
      wmiReturnedAt = $wmiReturnedAtUtc.ToString('o')
      processIdentityObservedAt = $processIdentityObservedAtUtc.ToString('o')
      recordedAt = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicRestrictedText $receiptPath $receiptTemporary ($receipt | ConvertTo-Json -Compress) $identity.User
    $launchCommitted = $true
    [Console]::Out.WriteLine('DETACHED_APP_LAUNCH_READY')
  } catch {
    $launchFailure = $_
    if (-not $launchCommitted -and $wmiCallAttempted) {
      $cleanupFailure = $null
      try {
        if ($null -eq $wmiReturnedAtUtc) { $wmiReturnedAtUtc = [DateTime]::UtcNow }
        if ($null -eq $processIdentityObservedAtUtc -or $processIdentityObservedAtUtc -lt $wmiReturnedAtUtc) {
          $processIdentityObservedAtUtc = [DateTime]::UtcNow
        }
        if ($createdProcessId -gt 0) {
          if ($null -eq $process) { $process = Get-Process -Id $createdProcessId -ErrorAction SilentlyContinue }
          if ($null -ne $process) {
            Stop-ExactCreatedProcess $process 'The returned local-WMI child' $executable $sessionId $identity.User.Value ([DateTime]::Parse($armedAt).ToUniversalTime()) $wmiReturnedAtUtc $processIdentityObservedAtUtc $commandLine
          }
        }
      } catch {
        $cleanupFailure = $_
      }
      if ($null -ne $cleanupFailure) {
        throw "Local WMI launch failed and exact child cleanup was not proven. Launch: $($launchFailure.Exception.Message) Cleanup: $($cleanupFailure.Exception.Message)"
      }
    }
    throw $launchFailure
  }
} finally {
  if ($null -ne $executableLock) { $executableLock.Dispose() }
  if ($null -ne $process) { $process.Dispose() }
  if ($null -ne $wmiResult) { $wmiResult.Dispose() }
  if ($null -ne $wmiStartup) { $wmiStartup.Dispose() }
  if ($null -ne $wmiStartupClass) { $wmiStartupClass.Dispose() }
  if ($null -ne $wmiProcessClass) { $wmiProcessClass.Dispose() }
  Clear-WmiStartupEnvironment $startupEnvironment $startupEnvironmentValues
  $startupEnvironment = $null
  $startupEnvironmentValues = $null
  $tenantId = $null
  $projectName = $null
}
POWERSHELL
)"
  bootstrap_hash="$(printf '%s' "$bootstrap_script" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  bootstrap_base64="$(printf '%s' "$bootstrap_script" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  [[ "$bootstrap_hash" =~ ^[0-9a-f]{64}$ && -n "$bootstrap_base64" ]] || return 1
  if [[ "$mode" == normal ]]; then
    normal_launch_nonce="$launch_nonce"
    normal_bootstrap_hash="$bootstrap_hash"
    normal_launch_transport_confirmed=0
    pid_file="$guest_normal_pid"
    receipt_file="$guest_normal_launch_receipt"
    arm_file="$guest_normal_launch_arm"
    protected_payload=""
  else
    e2e_launch_nonce="$launch_nonce"
    e2e_bootstrap_hash="$bootstrap_hash"
    e2e_launch_transport_confirmed=0
    pid_file="$guest_e2e_pid"
    receipt_file="$guest_e2e_launch_receipt"
    arm_file="$guest_e2e_launch_arm"
  fi
  guest_system_ps_run "$bootstrap_hash"$'\n'"$bootstrap_base64"$'\n'"$guest_user"$'\n' 2 >/dev/null <<'POWERSHELL' || return 1
$ErrorActionPreference = 'Stop'
$expectedHash = [Console]::In.ReadLine()
$sourceBase64 = [Console]::In.ReadLine()
$expectedUser = [Console]::In.ReadLine()
$path = 'C:\Users\Public\eai-setup-app-bootstrap.ps1'
$temporary = 'C:\Users\Public\eai-setup-app-bootstrap.ps1.tmp'
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
if ($expectedHash -cnotmatch '^[0-9a-f]{64}$' -or $sourceBase64 -cnotmatch '^[A-Za-z0-9+/]+={0,2}$' -or
    $expectedUser -cnotmatch '^[A-Za-z0-9._-]+$') { throw 'The bootstrap staging inputs are invalid.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid)) {
  throw 'The app bootstrap is not being staged by LocalSystem.'
}
if ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $temporary)) { throw 'A fixed app bootstrap path is already occupied.' }
$userSid = ([Security.Principal.NTAccount]::new("$env:COMPUTERNAME\$expectedUser")).Translate([Security.Principal.SecurityIdentifier])
$bytes = [Convert]::FromBase64String($sourceBase64)
$hasher = [Security.Cryptography.SHA256]::Create()
try { $actualHash = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
finally { $hasher.Dispose() }
if ($actualHash -cne $expectedHash) { throw 'The app bootstrap staging hash is invalid.' }
$stream = $null
try {
  $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush($true)
} finally {
  if ($null -ne $stream) { $stream.Dispose() }
}
$acl = [Security.AccessControl.FileSecurity]::new()
$acl.SetOwner($systemSid)
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, 'FullControl', 'Allow'))
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($userSid, 'ReadAndExecute', 'Allow'))
Set-Acl -LiteralPath $temporary -AclObject $acl -ErrorAction Stop
[IO.File]::Move($temporary, $path)
$item = Get-Item -LiteralPath $path -ErrorAction Stop
$finalAcl = Get-Acl -LiteralPath $path -ErrorAction Stop
if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase) -or
    $finalAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid.Value -or
    -not $finalAcl.AreAccessRulesProtected -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne $expectedHash) {
  throw 'The staged app bootstrap failed its protected-file verification.'
}
POWERSHELL
  transport_started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
  set +e
  bootstrap_output="$(printf '%s\n' \
    "& 'C:\Users\Public\eai-setup-app-bootstrap.ps1' -Mode '$mode' -LaunchNonce '$launch_nonce' -ExpectedExecutableSha256 '$expected_executable_hash' -ExpectedBootstrapSha256 '$bootstrap_hash' -ExpectedUser '$guest_user'" \
    | windows_hidden_current_user_ps "$vm_name" "$protected_payload" 2>&1)"
  bootstrap_status=$?
  set -e
  transport_returned_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
  if [[ "$bootstrap_status" == 0 && "$bootstrap_output" == *DETACHED_APP_LAUNCH_READY* ]]; then
    if validate_guest_app_launch "$pid_file" "$receipt_file" "$arm_file" \
        "$launch_nonce" "$mode" "$expected_executable_hash" "$bootstrap_hash" \
        && write_detached_transport_return_proof "$mode" "$launch_nonce" \
          "$transport_started_ms" "$transport_returned_ms" "$bootstrap_status"; then
      if [[ "$mode" == normal ]]; then
        normal_launch_transport_confirmed=1
      else
        e2e_launch_transport_confirmed=1
      fi
      protected_payload=""
      return 0
    fi
    bootstrap_output+=$'\nLocalSystem post-return validation or sanitized host proof failed.'
    bootstrap_status=1
  fi

  # A missing or failed Parallels result is never replay authority. A complete
  # LocalSystem-validated receipt is sufficient independent proof that this
  # exact nonce finished and the child survived; otherwise cancel first.
  if validate_guest_app_launch "$pid_file" "$receipt_file" "$arm_file" \
      "$launch_nonce" "$mode" "$expected_executable_hash" "$bootstrap_hash" \
      && write_detached_transport_return_proof "$mode" "$launch_nonce" \
        "$transport_started_ms" "$transport_returned_ms" "$bootstrap_status"; then
    if [[ "$mode" == normal ]]; then
      normal_launch_transport_confirmed=1
    else
      e2e_launch_transport_confirmed=1
    fi
    protected_payload=""
    return 0
  fi

  printf '%s\n' "$bootstrap_output" >&2
  if [[ "$bootstrap_status" == 255 ]] && is_parallels_session_open_failure "$bootstrap_output"; then
    # Only the exact session-open error may become retryable, and only after
    # cleanup returns its special proof that no bootstrap, arm, PID, receipt,
    # or exact executable process ever belonged to the old nonce.
    preserve_detached_launch_evidence "$mode" >/dev/null 2>&1 || true
    cleanup_status=0
    cleanup_detached_guest_app "$mode" 1 || cleanup_status=$?
    if [[ "$cleanup_status" == 4 && "$attempt" -lt "$max_attempts" ]]; then
      printf '%s detached %s bootstrap was proven unstarted; retry %s/%s with a new nonce\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$((attempt + 1))" "$max_attempts" >&2
      if launch_guest_app_detached "$mode" "$protected_payload" "$expected_executable_hash" "$((attempt + 1))"; then
        protected_payload=""
        return 0
      else
        recursive_status=$?
        protected_payload=""
        return "$recursive_status"
      fi
    fi
    protected_payload=""
    [[ "$cleanup_status" == 4 ]] && return "$bootstrap_status"
    return 1
  fi

  if is_parallels_ambiguous_launch_result_failure "$bootstrap_status" "$bootstrap_output"; then
    printf '%s ambiguous Parallels launch result had no independently valid complete receipt; replay is forbidden\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  fi
  preserve_detached_launch_evidence "$mode" >/dev/null 2>&1 || true
  cleanup_detached_guest_app "$mode" 0 >/dev/null 2>&1 || true
  protected_payload=""
  return 1
}

validate_guest_app_launch() {
  local pid_file="$1"
  local receipt_file="$2"
  local arm_file="$3"
  local expected_nonce="$4"
  local expected_mode="$5"
  local expected_hash="$6"
  local expected_bootstrap_hash="$7"
  guest_system_ps_readonly_run "$pid_file"$'\n'"$receipt_file"$'\n'"$arm_file"$'\n'"$expected_nonce"$'\n'"$expected_mode"$'\n'"$expected_hash"$'\n'"$expected_bootstrap_hash"$'\n'"$guest_executable_file"$'\n'"$guest_user"$'\n' 2 >/dev/null <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

function ConvertTo-ComparableAppPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw 'A detached application path is empty.'
  }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

$pidFile = [Console]::In.ReadLine()
$receiptFile = [Console]::In.ReadLine()
$armFile = [Console]::In.ReadLine()
$expectedNonce = [Console]::In.ReadLine()
$expectedMode = [Console]::In.ReadLine()
$expectedHash = [Console]::In.ReadLine()
$expectedBootstrapHash = [Console]::In.ReadLine()
$executableFile = [Console]::In.ReadLine()
$expectedUser = [Console]::In.ReadLine()
if ($expectedNonce -cnotmatch '^[0-9a-f]{32}$' -or $expectedMode -notin @('normal', 'e2e') -or
    $expectedHash -cnotmatch '^[0-9a-f]{64}$' -or $expectedBootstrapHash -cnotmatch '^[0-9a-f]{64}$') {
  throw 'The detached launch validation inputs are invalid.'
}
$receiptItem = Get-Item -LiteralPath $receiptFile -ErrorAction Stop
$pidItem = Get-Item -LiteralPath $pidFile -ErrorAction Stop
$armItem = Get-Item -LiteralPath $armFile -ErrorAction Stop
$receipt = Get-Content -Raw -LiteralPath $receiptFile | ConvertFrom-Json
$expectedOwnerSid = [string]$receipt.processOwnerSid
foreach ($pair in @(@($receiptItem, $receiptFile), @($pidItem, $pidFile), @($armItem, $armFile))) {
  $item = $pair[0]
  $path = $pair[1]
  $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $allowedSids = @($expectedOwnerSid, 'S-1-5-18')
  $actualSids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase) -or
      $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $expectedOwnerSid -or
      -not $acl.AreAccessRulesProtected -or $rules.Count -ne 2 -or $actualSids.Count -ne 2 -or
      $actualSids -cnotcontains $expectedOwnerSid -or $actualSids -cnotcontains 'S-1-5-18' -or
      ($rules | Where-Object { $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $allowedSids -cnotcontains $_.IdentityReference.Value })) {
    throw 'A detached launch artifact lacks its canonical path, owner, or restricted ACL.'
  }
}
$arm = Get-Content -Raw -LiteralPath $armFile | ConvertFrom-Json
$processId = (Get-Content -Raw -LiteralPath $pidFile).Trim()
if ($receipt.schemaVersion -cne 'eai-windows-detached-app-launch/v5' -or $receipt.status -cne 'launched' -or
    $receipt.mode -cne $expectedMode -or $receipt.launchNonce -cne $expectedNonce -or
    $receipt.launchMechanism -cne 'local-win32-process-create' -or
    $receipt.localWmiCall -ne $true -or $receipt.wmiClass -cne 'Win32_Process' -or
    $receipt.wmiMethod -cne 'Create' -or [int]$receipt.wmiReturnValue -ne 0 -or
    $receipt.providerBrokeredJobEscape -ne $true -or $receipt.bootstrapSha256 -cne $expectedBootstrapHash -or
    $receipt.protectedValuesInArguments -ne $false -or $receipt.protectedLaunchInputFileCreated -ne $false -or
    $receipt.protectedValuesInGlobalEnvironment -ne $false -or
    $receipt.processOnlyStartupEnvironment -ne $true -or
    $receipt.inheritedE2EEnvironmentVariablesStripped -ne $true -or
    $receipt.bootstrapInJob -ne $true -or $receipt.childJobStateObserved -ne $true -or
    $receipt.childInJob -isnot [bool] -or $receipt.childJobAbsenceRequired -ne $false -or
    $receipt.canonicalExecutableOnlyCommandLine -ne $true -or
    $receipt.quotedExecutableCommandLine -ne $true -or $receipt.startupInfoUsesStdHandles -ne $false -or
    $receipt.desktop -cne 'winsta0\default' -or [int64]$receipt.creationFlags -ne 1536 -or
    $receipt.emptyApplicationArguments -ne $true -or $receipt.executableSha256 -cne $expectedHash -or
    $processId -cnotmatch '^[1-9][0-9]*$' -or [int]$processId -ne [int]$receipt.processId -or
    $receipt.processSessionId -le 0 -or $receipt.providerProcessId -le 0 -or
    $expectedOwnerSid -cnotmatch '^S-1-5-21-' -or
    $arm.schemaVersion -cne 'eai-windows-detached-app-launch-arm/v2' -or $arm.status -cne 'armed' -or
    $arm.mode -cne $expectedMode -or $arm.launchNonce -cne $expectedNonce -or
    $arm.executableSha256 -cne $expectedHash -or $arm.bootstrapSha256 -cne $expectedBootstrapHash -or
    $arm.bootstrapInJob -ne $true -or $arm.launchBroker -cne 'local-win32-process-create' -or
    $arm.wmiDispatchPending -ne $true -or
    [int]$arm.bootstrapProcessId -ne [int]$receipt.bootstrapProcessId -or
    [string]$arm.bootstrapProcessStartedAt -cne [string]$receipt.bootstrapProcessStartedAt -or
    [string]$arm.processOwnerSid -cne $expectedOwnerSid -or
    [int]$arm.processSessionId -ne [int]$receipt.processSessionId -or
    [int]$arm.processSessionId -ne [int]$receipt.bootstrapProcessSessionId -or
    [string]$receipt.armedAt -cne [string]$arm.armedAt -or
    [DateTime]::Parse([string]$receipt.bootstrapProcessStartedAt).ToUniversalTime() -gt [DateTime]::Parse([string]$arm.armedAt).ToUniversalTime() -or
    [DateTime]::Parse([string]$receipt.processStartedAt).ToUniversalTime() -lt [DateTime]::Parse([string]$arm.armedAt).ToUniversalTime() -or
    [DateTime]::Parse([string]$receipt.wmiReturnedAt).ToUniversalTime() -lt [DateTime]::Parse([string]$arm.armedAt).ToUniversalTime() -or
    [DateTime]::Parse([string]$receipt.processIdentityObservedAt).ToUniversalTime() -lt [DateTime]::Parse([string]$receipt.wmiReturnedAt).ToUniversalTime() -or
    [DateTime]::Parse([string]$receipt.processStartedAt).ToUniversalTime() -gt [DateTime]::Parse([string]$receipt.processIdentityObservedAt).ToUniversalTime() -or
    [DateTime]::Parse([string]$receipt.recordedAt).ToUniversalTime() -lt [DateTime]::Parse([string]$receipt.processIdentityObservedAt).ToUniversalTime()) {
  throw 'The detached application arm/receipt does not match the expected launch.'
}
if ($expectedMode -eq 'normal') {
  if ($receipt.protectedRuntimeInput -cne 'none' -or $receipt.childEnvironmentScoped -ne $false -or
      $receipt.explicitChildEnvironmentBlock -ne $true -or $receipt.unicodeChildEnvironmentBlock -ne $true -or
      [int]$receipt.e2eEnvironmentVariableCount -ne 0) {
    throw 'The normal launch receipt has an unexpected protected-input contract.'
  }
} elseif ($receipt.protectedRuntimeInput -cne 'raw-process-stdin' -or $receipt.childEnvironmentScoped -ne $true -or
    $receipt.explicitChildEnvironmentBlock -ne $true -or $receipt.unicodeChildEnvironmentBlock -ne $true -or
    [int]$receipt.e2eEnvironmentVariableCount -ne 5) {
  throw 'The E2E launch receipt does not prove raw-stdin/child-environment isolation.'
}
$bootstrap = Get-Process -Id ([int]$receipt.bootstrapProcessId) -ErrorAction SilentlyContinue
if ($null -ne $bootstrap) {
  try {
    # Retain the currently observed process object before reading its creation
    # time, so a second PID reuse cannot redirect this identity check.
    [void]$bootstrap.Handle
    $bootstrap.Refresh()
    $bootstrapStartedAtUtc = $bootstrap.StartTime.ToUniversalTime()
    $expectedBootstrapStartedAtUtc = [DateTime]::Parse([string]$receipt.bootstrapProcessStartedAt).ToUniversalTime()
    $receiptRecordedAtUtc = [DateTime]::Parse([string]$receipt.recordedAt).ToUniversalTime()
    if ($bootstrapStartedAtUtc -eq $expectedBootstrapStartedAtUtc) {
      throw 'The one-shot bootstrap remained alive during the independent LocalSystem validation.'
    }
    if ($bootstrapStartedAtUtc -le $receiptRecordedAtUtc) {
      throw 'The reused bootstrap PID does not have a strictly later process creation time.'
    }
    # Windows can reuse a PID only after the old process is terminal. A
    # retained, strictly later process is therefore positive terminal proof
    # for the receipt-bound bootstrap and is deliberately left untouched.
  } finally {
    $bootstrap.Dispose()
  }
}
$expectedExecutable = (Get-Content -Raw -LiteralPath $executableFile).Trim()
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $expectedExecutable).Hash.ToLowerInvariant() -cne $expectedHash) {
  throw 'The canonical installed executable changed after detached launch.'
}
$process = Get-Process -Id ([int]$processId) -ErrorAction Stop
try { $actualExecutable = ConvertTo-ComparableAppPath $process.Path }
catch { throw 'The detached process path is unavailable.' }
$expectedComparableExecutable = ConvertTo-ComparableAppPath $expectedExecutable
if (-not [string]::Equals($actualExecutable, $expectedComparableExecutable, [StringComparison]::OrdinalIgnoreCase) -or
    $process.SessionId -ne [int]$receipt.processSessionId -or
    $process.StartTime.ToUniversalTime().ToString('o') -cne [string]$receipt.processStartedAt -or
    $process.StartTime.ToUniversalTime() -lt [DateTime]::Parse([string]$arm.armedAt).ToUniversalTime()) {
  throw 'The detached process tuple no longer matches its launch receipt.'
}
$cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
$owner = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwner -ErrorAction Stop
$ownerSid = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwnerSid -ErrorAction Stop
if ($owner.ReturnValue -ne 0 -or -not [string]::Equals($owner.User, $expectedUser, [StringComparison]::OrdinalIgnoreCase) -or
    $ownerSid.ReturnValue -ne 0 -or $ownerSid.Sid -cne $expectedOwnerSid) {
  throw 'The detached process owner no longer matches its launch receipt.'
}
$expectedCommandLine = '"' + $expectedExecutable + '"'
if ([string]$cimProcess.CommandLine -cne $expectedCommandLine) {
  throw 'The detached process no longer has the exact quoted executable-only command line.'
}
if ($null -eq ('EaiReleaseE2E.ValidationNativeProcess' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace EaiReleaseE2E {
  public static class ValidationNativeProcess {
    [DllImport("kernel32.dll", EntryPoint = "IsProcessInJob", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsProcessInJob(
      IntPtr processHandle,
      IntPtr jobHandle,
      [MarshalAs(UnmanagedType.Bool)] out bool result);
  }
}
'@ -ErrorAction Stop
}
$liveChildInJob = $false
if (-not [EaiReleaseE2E.ValidationNativeProcess]::IsProcessInJob(
    $process.Handle, [IntPtr]::Zero, [ref]$liveChildInJob)) {
  throw 'The detached child job state cannot be observed after host transport return.'
}
if ($liveChildInJob -ne [bool]$receipt.childInJob) {
  throw 'The detached child job state changed after the local-WMI receipt was written.'
}
POWERSHELL
}

cleanup_detached_guest_app() {
  local mode="$1"
  local retry_candidate="${2:-0}"
  local pid_file=""
  local receipt_file=""
  local arm_file=""
  local cancel_file=""
  local expected_nonce=""
  local expected_hash="${executable_hash:-}"
  local expected_bootstrap_hash=""
  local transport_confirmed=0
  local cleanup_status=0
  case "$mode" in
    normal)
      pid_file="$guest_normal_pid"
      receipt_file="$guest_normal_launch_receipt"
      arm_file="$guest_normal_launch_arm"
      cancel_file="$guest_normal_launch_cancel"
      expected_nonce="$normal_launch_nonce"
      expected_bootstrap_hash="$normal_bootstrap_hash"
      transport_confirmed="$normal_launch_transport_confirmed"
      ;;
    e2e)
      pid_file="$guest_e2e_pid"
      receipt_file="$guest_e2e_launch_receipt"
      arm_file="$guest_e2e_launch_arm"
      cancel_file="$guest_e2e_launch_cancel"
      expected_nonce="$e2e_launch_nonce"
      expected_bootstrap_hash="$e2e_bootstrap_hash"
      transport_confirmed="$e2e_launch_transport_confirmed"
      ;;
    *) return 2 ;;
  esac
  [[ "$retry_candidate" =~ ^[01]$ ]] || return 2
  [[ "$expected_nonce" =~ ^[0-9a-f]{32}$ && "$expected_hash" =~ ^[0-9a-f]{64}$ \
      && "$expected_bootstrap_hash" =~ ^[0-9a-f]{64}$ && "$transport_confirmed" =~ ^[01]$ ]] || return 0
  cleanup_status=0
  guest_system_ps_run "$pid_file"$'\n'"$receipt_file"$'\n'"$arm_file"$'\n'"$cancel_file"$'\n'"$guest_app_bootstrap"$'\n'"$guest_executable_file"$'\n'"$expected_nonce"$'\n'"$mode"$'\n'"$expected_hash"$'\n'"$expected_bootstrap_hash"$'\n'"$guest_user"$'\n'"$transport_confirmed"$'\n'"$retry_candidate"$'\n' 2 >/dev/null <<'POWERSHELL' || cleanup_status=$?
$ErrorActionPreference = 'Stop'
$pidFile = [Console]::In.ReadLine()
$receiptFile = [Console]::In.ReadLine()
$armFile = [Console]::In.ReadLine()
$cancelFile = [Console]::In.ReadLine()
$bootstrapFile = [Console]::In.ReadLine()
$executableFile = [Console]::In.ReadLine()
$expectedNonce = [Console]::In.ReadLine()
$expectedMode = [Console]::In.ReadLine()
$expectedHash = [Console]::In.ReadLine()
$expectedBootstrapHash = [Console]::In.ReadLine()
$expectedUser = [Console]::In.ReadLine()
$transportConfirmed = [Console]::In.ReadLine() -eq '1'
$retryCandidate = [Console]::In.ReadLine() -eq '1'
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$expectedPowerShell = Join-Path $PSHOME 'powershell.exe'

if ($expectedNonce -cnotmatch '^[0-9a-f]{32}$' -or $expectedMode -notin @('normal', 'e2e') -or
    $expectedHash -cnotmatch '^[0-9a-f]{64}$' -or $expectedBootstrapHash -cnotmatch '^[0-9a-f]{64}$' -or
    $expectedUser -cnotmatch '^[A-Za-z0-9._-]+$') { throw 'Detached cleanup trust inputs are invalid.' }
$expectedUserSid = ([Security.Principal.NTAccount]::new("$env:COMPUTERNAME\$expectedUser")).Translate([Security.Principal.SecurityIdentifier])
$expectedCancel = "cancel:$expectedMode`:$expectedNonce`:$expectedBootstrapHash`:$expectedHash"
$cancelTemporary = "$cancelFile.tmp"

function Assert-CanonicalRegularFile([string]$path) {
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase)) {
    throw "A detached cleanup path is not a canonical regular file: $path"
  }
  return $item
}

function Assert-CancelSignal() {
  [void](Assert-CanonicalRegularFile $cancelFile)
  $acl = Get-Acl -LiteralPath $cancelFile -ErrorAction Stop
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $systemRules = @($rules | Where-Object {
    $_.IdentityReference.Value -ceq $systemSid.Value -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
  })
  $userRules = @($rules | Where-Object {
    $_.IdentityReference.Value -ceq $expectedUserSid.Value -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read) -eq [Security.AccessControl.FileSystemRights]::Read -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0 -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) -eq 0
  })
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid.Value -or
      -not $acl.AreAccessRulesProtected -or $rules.Count -ne 2 -or $systemRules.Count -ne 1 -or $userRules.Count -ne 1 -or
      (Get-Content -Raw -LiteralPath $cancelFile).Trim() -cne $expectedCancel) {
    throw 'The detached cancellation signal is not the exact LocalSystem-owned run binding.'
  }
}

function Write-CancelSignal() {
  if (Test-Path -LiteralPath $cancelFile) {
    Assert-CancelSignal
    return
  }
  if (Test-Path -LiteralPath $cancelTemporary) { throw 'A detached cancellation temporary path is already occupied.' }
  $bytes = [Text.Encoding]::ASCII.GetBytes($expectedCancel)
  $stream = $null
  try {
    $stream = [IO.File]::Open($cancelTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  $acl = [Security.AccessControl.FileSecurity]::new()
  $acl.SetOwner($systemSid)
  $acl.SetAccessRuleProtection($true, $false)
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, 'FullControl', 'Allow'))
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($expectedUserSid, 'Read', 'Allow'))
  Set-Acl -LiteralPath $cancelTemporary -AclObject $acl -ErrorAction Stop
  [IO.File]::Move($cancelTemporary, $cancelFile)
  Assert-CancelSignal
}

function Test-ExpectedOwner([Microsoft.Management.Infrastructure.CimInstance]$cim) {
  $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction Stop
  $ownerSid = Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop
  return $owner.ReturnValue -eq 0 -and
    [string]::Equals($owner.User, $expectedUser, [StringComparison]::OrdinalIgnoreCase) -and
    $ownerSid.ReturnValue -eq 0 -and $ownerSid.Sid -ceq $expectedUserSid.Value
}

function ConvertTo-ComparableAppPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw 'A detached application path is empty.'
  }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Get-CommandBoundBootstraps() {
  $tokens = @(
    $bootstrapFile,
    "-Mode $expectedMode",
    "-LaunchNonce $expectedNonce",
    "-ExpectedExecutableSha256 $expectedHash",
    "-ExpectedBootstrapSha256 $expectedBootstrapHash",
    "-ExpectedUser $expectedUser"
  )
  $matches = @()
  foreach ($cim in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop)) {
    if ($cim.SessionId -le 0 -or [string]::IsNullOrWhiteSpace([string]$cim.CommandLine)) { continue }
    if ($tokens | Where-Object { ([string]$cim.CommandLine).IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }) { continue }
    $process = Get-Process -Id ([int]$cim.ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    try { $path = ConvertTo-ComparableAppPath $process.Path } catch { continue }
    if (-not [string]::Equals($path, (ConvertTo-ComparableAppPath $expectedPowerShell), [StringComparison]::OrdinalIgnoreCase) -or
        $process.SessionId -ne [int]$cim.SessionId -or -not (Test-ExpectedOwner $cim)) { continue }
    $matches += $process
  }
  return @($matches)
}

function Assert-UserLaunchArtifact([string]$path) {
  [void](Assert-CanonicalRegularFile $path)
  $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $sids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $expectedUserSid.Value -or
      -not $acl.AreAccessRulesProtected -or $rules.Count -ne 2 -or $sids.Count -ne 2 -or
      $sids -cnotcontains $expectedUserSid.Value -or $sids -cnotcontains $systemSid.Value -or
      ($rules | Where-Object {
        $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl
      })) {
    throw "A detached launch artifact lacks its exact protected owner/ACL: $path"
  }
}

function Convert-RequiredUtc([object]$value, [string]$name) {
  try { return [DateTime]::Parse([string]$value).ToUniversalTime() }
  catch { throw "A detached launch artifact has an invalid $name timestamp." }
}

function Read-BoundLaunchState() {
  $armValue = $null
  $receiptValue = $null
  $pidValue = $null
  $evidencePresent = $false
  if (Test-Path -LiteralPath $armFile -PathType Leaf) {
    $evidencePresent = $true
    Assert-UserLaunchArtifact $armFile
    $armValue = Get-Content -Raw -LiteralPath $armFile | ConvertFrom-Json
    if ($armValue.schemaVersion -cne 'eai-windows-detached-app-launch-arm/v2' -or $armValue.status -cne 'armed' -or
        $armValue.mode -cne $expectedMode -or $armValue.launchNonce -cne $expectedNonce -or
        $armValue.executableSha256 -cne $expectedHash -or $armValue.bootstrapSha256 -cne $expectedBootstrapHash -or
        $armValue.bootstrapInJob -ne $true -or $armValue.launchBroker -cne 'local-win32-process-create' -or
        $armValue.wmiDispatchPending -ne $true -or
        $armValue.processSessionId -le 0 -or $armValue.processOwnerSid -cne $expectedUserSid.Value -or
        $armValue.bootstrapProcessId -le 0) {
      throw 'Cleanup refuses an unbound detached-launch arm.'
    }
    [void](Convert-RequiredUtc $armValue.bootstrapProcessStartedAt 'bootstrap-process-start')
    [void](Convert-RequiredUtc $armValue.armedAt 'arm')
  }
  if (Test-Path -LiteralPath $receiptFile -PathType Leaf) {
    $evidencePresent = $true
    Assert-UserLaunchArtifact $receiptFile
    $receiptValue = Get-Content -Raw -LiteralPath $receiptFile | ConvertFrom-Json
    if ($receiptValue.schemaVersion -cne 'eai-windows-detached-app-launch/v5' -or $receiptValue.status -cne 'launched' -or
        $receiptValue.mode -cne $expectedMode -or $receiptValue.launchNonce -cne $expectedNonce -or
        $receiptValue.executableSha256 -cne $expectedHash -or $receiptValue.bootstrapSha256 -cne $expectedBootstrapHash -or
        $receiptValue.launchMechanism -cne 'local-win32-process-create' -or
        $receiptValue.localWmiCall -ne $true -or $receiptValue.wmiClass -cne 'Win32_Process' -or
        $receiptValue.wmiMethod -cne 'Create' -or [int]$receiptValue.wmiReturnValue -ne 0 -or
        $receiptValue.providerBrokeredJobEscape -ne $true -or
        $receiptValue.protectedValuesInArguments -ne $false -or
        $receiptValue.protectedLaunchInputFileCreated -ne $false -or
        $receiptValue.protectedValuesInGlobalEnvironment -ne $false -or
        $receiptValue.processOnlyStartupEnvironment -ne $true -or
        $receiptValue.inheritedE2EEnvironmentVariablesStripped -ne $true -or
        $receiptValue.bootstrapInJob -ne $true -or $receiptValue.childJobStateObserved -ne $true -or
        $receiptValue.childInJob -isnot [bool] -or $receiptValue.childJobAbsenceRequired -ne $false -or
        $receiptValue.canonicalExecutableOnlyCommandLine -ne $true -or
        $receiptValue.quotedExecutableCommandLine -ne $true -or
        $receiptValue.startupInfoUsesStdHandles -ne $false -or $receiptValue.desktop -cne 'winsta0\default' -or
        [int64]$receiptValue.creationFlags -ne 1536 -or
        $receiptValue.processSessionId -le 0 -or $receiptValue.bootstrapProcessSessionId -le 0 -or
        $receiptValue.processOwnerSid -cne $expectedUserSid.Value -or $receiptValue.processId -le 0 -or
        $receiptValue.providerProcessId -le 0) {
      throw 'Cleanup refuses an unbound detached-launch receipt.'
    }
    if (($expectedMode -ceq 'normal' -and
          ($receiptValue.protectedRuntimeInput -cne 'none' -or
           $receiptValue.childEnvironmentScoped -ne $false -or
           $receiptValue.explicitChildEnvironmentBlock -ne $true -or
           $receiptValue.unicodeChildEnvironmentBlock -ne $true -or
           [int]$receiptValue.e2eEnvironmentVariableCount -ne 0)) -or
        ($expectedMode -ceq 'e2e' -and
          ($receiptValue.protectedRuntimeInput -cne 'raw-process-stdin' -or
           $receiptValue.childEnvironmentScoped -ne $true -or
           $receiptValue.explicitChildEnvironmentBlock -ne $true -or
           $receiptValue.unicodeChildEnvironmentBlock -ne $true -or
           [int]$receiptValue.e2eEnvironmentVariableCount -ne 5))) {
      throw 'Cleanup refuses a detached-launch receipt with an invalid WMI environment contract.'
    }
    [void](Convert-RequiredUtc $receiptValue.bootstrapProcessStartedAt 'receipt-bootstrap-process-start')
    [void](Convert-RequiredUtc $receiptValue.processStartedAt 'application-process-start')
    [void](Convert-RequiredUtc $receiptValue.armedAt 'receipt-arm')
    [void](Convert-RequiredUtc $receiptValue.wmiReturnedAt 'receipt-WMI-return')
    [void](Convert-RequiredUtc $receiptValue.processIdentityObservedAt 'receipt-process-identity-observation')
    [void](Convert-RequiredUtc $receiptValue.recordedAt 'receipt-record')
    if ([DateTime]::Parse([string]$receiptValue.processStartedAt).ToUniversalTime() -lt
          [DateTime]::Parse([string]$receiptValue.armedAt).ToUniversalTime() -or
        [DateTime]::Parse([string]$receiptValue.wmiReturnedAt).ToUniversalTime() -lt
          [DateTime]::Parse([string]$receiptValue.armedAt).ToUniversalTime() -or
        [DateTime]::Parse([string]$receiptValue.processIdentityObservedAt).ToUniversalTime() -lt
          [DateTime]::Parse([string]$receiptValue.wmiReturnedAt).ToUniversalTime() -or
        [DateTime]::Parse([string]$receiptValue.processStartedAt).ToUniversalTime() -gt
          [DateTime]::Parse([string]$receiptValue.processIdentityObservedAt).ToUniversalTime() -or
        [DateTime]::Parse([string]$receiptValue.recordedAt).ToUniversalTime() -lt
          [DateTime]::Parse([string]$receiptValue.processIdentityObservedAt).ToUniversalTime()) {
      throw 'Cleanup refuses a detached-launch receipt with an impossible WMI timeline.'
    }
  }
  if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
    $evidencePresent = $true
    Assert-UserLaunchArtifact $pidFile
    $pidText = (Get-Content -Raw -LiteralPath $pidFile).Trim()
    if ($pidText -cnotmatch '^[1-9][0-9]*$') { throw 'Cleanup refuses a malformed detached PID artifact.' }
    $pidValue = [int]$pidText
  }
  foreach ($temporary in @("$pidFile.tmp", "$receiptFile.tmp", "$armFile.tmp")) {
    if (Test-Path -LiteralPath $temporary) { $evidencePresent = $true }
  }
  if ($null -ne $pidValue -and $null -eq $armValue -and $null -eq $receiptValue) {
    throw 'Cleanup found an unbound detached PID path.'
  }
  if ($null -ne $receiptValue) {
    if (($null -ne $pidValue -and $pidValue -ne [int]$receiptValue.processId) -or
        ($null -ne $armValue -and (
          [int]$armValue.bootstrapProcessId -ne [int]$receiptValue.bootstrapProcessId -or
          [string]$armValue.bootstrapProcessStartedAt -cne [string]$receiptValue.bootstrapProcessStartedAt -or
          [int]$armValue.processSessionId -ne [int]$receiptValue.processSessionId -or
          [int]$armValue.processSessionId -ne [int]$receiptValue.bootstrapProcessSessionId -or
          [string]$armValue.processOwnerSid -cne [string]$receiptValue.processOwnerSid -or
          [string]$armValue.armedAt -cne [string]$receiptValue.armedAt -or
          [DateTime]::Parse([string]$receiptValue.recordedAt).ToUniversalTime() -lt [DateTime]::Parse([string]$armValue.armedAt).ToUniversalTime()))) {
      throw 'Cleanup found contradictory detached arm/PID/receipt tuples.'
    }
  }
  return [pscustomobject]@{
    Arm = $armValue
    Receipt = $receiptValue
    Pid = $pidValue
    EvidencePresent = $evidencePresent
  }
}

# Cancellation is the first mutation. No launch artifact is trusted or removed
# before a delayed bootstrap has an exact LocalSystem-owned stop signal.
Write-CancelSignal
$arm = $null
$receipt = $null
$launchEvidenceObserved = $false
$bootstrapObserved = $false

$stableBootstrapAbsence = 0
for ($poll = 0; $poll -lt 100 -and $stableBootstrapAbsence -lt 20; $poll++) {
  # Refresh on every read: a bootstrap may have passed its final cancel check
  # immediately before LocalSystem published the signal, then written its arm.
  $state = Read-BoundLaunchState
  if ($state.EvidencePresent) { $launchEvidenceObserved = $true }
  $arm = $state.Arm
  $receipt = $state.Receipt
  $bootstraps = @(Get-CommandBoundBootstraps)
  if ($null -ne $arm) {
    $armedProcess = Get-Process -Id ([int]$arm.bootstrapProcessId) -ErrorAction SilentlyContinue
    if ($null -ne $armedProcess) {
      try { $armedPath = ConvertTo-ComparableAppPath $armedProcess.Path } catch { $armedPath = $null }
      try { $armedStartedAt = $armedProcess.StartTime.ToUniversalTime().ToString('o') } catch { $armedStartedAt = $null }
      if ([string]::Equals($armedPath, (ConvertTo-ComparableAppPath $expectedPowerShell), [StringComparison]::OrdinalIgnoreCase) -and
          $armedProcess.SessionId -eq [int]$arm.processSessionId -and $armedStartedAt -ceq [string]$arm.bootstrapProcessStartedAt -and
          -not ($bootstraps | Where-Object { $_.Id -eq $armedProcess.Id })) {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($armedProcess.Id)" -ErrorAction Stop
        if (-not (Test-ExpectedOwner $cim)) { throw 'The armed bootstrap PID has an unexpected owner.' }
        $bootstraps += $armedProcess
      }
    }
  }
  $bootstraps = @($bootstraps | Sort-Object Id -Unique)
  if ($bootstraps.Count -gt 1) { throw 'Cleanup found multiple run-bound bootstrap processes.' }
  if ($bootstraps.Count -eq 1) {
    $bootstrapObserved = $true
    # Never kill a bootstrap while its synchronous local-WMI dispatch may be
    # in flight. The SYSTEM cancellation signal is its post-return guard. A
    # still-live bootstrap makes this VM quarantined until snapshot restore.
    foreach ($bootstrap in $bootstraps) { $bootstrap.Dispose() }
    Assert-CancelSignal
    exit 3
  } else {
    $stableBootstrapAbsence += 1
  }
  Start-Sleep -Milliseconds 250
}
if ($stableBootstrapAbsence -lt 20) { throw 'Stable absence of the run-bound bootstrap could not be proven.' }

# Refresh arm, receipt, and PID only after the exact bootstrap is terminal.
# This closes the bootstrap-side final-cancel/local-WMI-return race and makes
# the child scan consume the last state the bootstrap could have published.
$state = Read-BoundLaunchState
if ($state.EvidencePresent) { $launchEvidenceObserved = $true }
$arm = $state.Arm
$receipt = $state.Receipt

$executable = (Get-Content -Raw -LiteralPath $executableFile).Trim()
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash.ToLowerInvariant() -cne $expectedHash) {
  throw 'Cleanup refuses an executable that changed after launch.'
}

# An arm without the completed, exact PID/start/owner/command-line receipt is
# provider-ambiguous. Win32_Process.Create is synchronous for the caller, but
# the provider can still complete after that caller is interrupted. Never
# terminate a path/session/post-arm match in this state: it is not an exact
# process identity. Retain the cancellation boundary and require the approved
# snapshot restore to terminate every possible late provider dispatch.
if ($null -ne $arm -and $null -eq $receipt) {
  Assert-CancelSignal
  exit 3
}

function Get-PostArmApps() {
  if ($null -eq $receipt) { return @() }
  $expectedCommandLine = '"' + $executable + '"'
  $process = Get-Process -Id ([int]$receipt.processId) -ErrorAction SilentlyContinue
  if ($null -eq $process) { return @() }
  try {
    # Open and retain the process handle before validating the receipt tuple,
    # so termination below cannot be redirected by PID reuse.
    [void]$process.Handle
    $processStartedAt = $process.StartTime.ToUniversalTime().ToString('o')
    $processPath = ConvertTo-ComparableAppPath $process.Path
    if ($process.Id -ne [int]$receipt.processId -or
        $process.SessionId -ne [int]$receipt.processSessionId -or
        -not [string]::Equals($processPath, (ConvertTo-ComparableAppPath $executable), [StringComparison]::OrdinalIgnoreCase) -or
        $processStartedAt -cne [string]$receipt.processStartedAt) {
      throw 'The receipt-bound application no longer matches its exact PID/start/path/session tuple.'
    }
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
    if ($null -eq $cim -or -not (Test-ExpectedOwner $cim) -or
        [string]$cim.CommandLine -cne $expectedCommandLine) {
      throw 'The receipt-bound application no longer matches its exact owner/command-line tuple.'
    }
    return @($process)
  } catch {
    $process.Dispose()
    throw
  }
}

function Get-AllExactExecutableApps() {
  $matches = @()
  foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
    try {
      if ([string]::Equals(
          (ConvertTo-ComparableAppPath $process.Path),
          (ConvertTo-ComparableAppPath $executable),
          [StringComparison]::OrdinalIgnoreCase)) {
        $matches += $process
      }
    } catch {}
  }
  return @($matches)
}

$stableAppAbsence = 0
for ($poll = 0; $poll -lt 100 -and $stableAppAbsence -lt 20; $poll++) {
  if ($null -eq $arm -and $null -eq $receipt) {
    $apps = @(Get-AllExactExecutableApps)
    if ($apps.Count -ne 0) {
      throw 'An unstarted launch cannot be proven while any exact executable process exists.'
    }
  } else {
    $apps = @(Get-PostArmApps)
  }
  if ($apps.Count -gt 1) { throw 'Cleanup found multiple exact post-arm app processes and refuses an ambiguous stop.' }
  if ($apps.Count -eq 1) {
    $stoppedId = $apps[0].Id
    $stoppedStartedAt = $apps[0].StartTime.ToUniversalTime().ToString('o')
    try {
      if (-not $apps[0].HasExited) { $apps[0].Kill() }
      if (-not $apps[0].WaitForExit(30000)) { throw 'The exact detached app did not stop.' }
    } finally {
      $apps[0].Dispose()
    }
    $replacement = Get-Process -Id $stoppedId -ErrorAction SilentlyContinue
    if ($null -ne $replacement) {
      try { $replacementStartedAt = $replacement.StartTime.ToUniversalTime().ToString('o') }
      catch { $replacementStartedAt = $null }
      $replacement.Dispose()
      if ($replacementStartedAt -ceq $stoppedStartedAt) { throw 'The exact detached app did not stop.' }
    }
    $stableAppAbsence = 0
  } else {
    $stableAppAbsence += 1
  }
  Start-Sleep -Milliseconds 250
}
if ($stableAppAbsence -lt 20) { throw 'Stable absence of the exact detached app could not be proven.' }

if ($retryCandidate -and -not $launchEvidenceObserved -and -not $bootstrapObserved) {
  foreach ($path in @($pidFile, "$pidFile.tmp", $receiptFile, "$receiptFile.tmp", $armFile, "$armFile.tmp", $bootstrapFile, "$bootstrapFile.tmp")) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    [void](Assert-CanonicalRegularFile $path)
    Remove-Item -Force -LiteralPath $path -ErrorAction Stop
  }
  Assert-CancelSignal
  Remove-Item -Force -LiteralPath $cancelFile -ErrorAction Stop
  if (Test-Path -LiteralPath $cancelFile) { throw 'The proven-unstarted launch cancellation signal could not be removed.' }
  # Exit 4 is an internal, positive proof: the exact session-open error was
  # followed by cancellation, five seconds of bootstrap absence, no launch
  # artifacts, and stable absence of every exact executable process.
  exit 4
}

if ($transportConfirmed -and $null -ne $receipt) {
  foreach ($path in @($pidFile, "$pidFile.tmp", $receiptFile, "$receiptFile.tmp", $armFile, "$armFile.tmp", $bootstrapFile, "$bootstrapFile.tmp")) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    [void](Assert-CanonicalRegularFile $path)
    if ([string]::Equals($path, $bootstrapFile, [StringComparison]::OrdinalIgnoreCase)) {
      $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
      if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid.Value -or
          (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -cne $expectedBootstrapHash) {
        throw 'Cleanup refuses a bootstrap outside this run hash/owner binding.'
      }
    }
    Remove-Item -Force -LiteralPath $path -ErrorAction Stop
  }
  Assert-CancelSignal
  Remove-Item -Force -LiteralPath $cancelFile -ErrorAction Stop
  if (Test-Path -LiteralPath $cancelFile) { throw 'The terminal launch cancellation signal could not be removed.' }
  exit 0
}

# Any incomplete or ambiguous local-WMI launch is diagnostic-only. A finite
# absence observation is not a cleanup proof: keep the LocalSystem-owned
# cancellation signal and bound artifacts, quarantine the VM, and require an
# approved snapshot restore before the VM can be reused.
Assert-CancelSignal
exit 3
POWERSHELL
  if [[ "$cleanup_status" == 0 || "$cleanup_status" == 4 ]]; then
    # A completed mode must become a no-op for the EXIT trap. Otherwise a
    # later E2E process can be mistaken for an app belonging to stale normal
    # launch globals after the normal arm/receipt were already removed.
    if [[ "$mode" == normal ]]; then
      normal_launch_nonce=""
      normal_bootstrap_hash=""
      normal_launch_transport_confirmed=0
    else
      e2e_launch_nonce=""
      e2e_bootstrap_hash=""
      e2e_launch_transport_confirmed=0
    fi
  fi
  if [[ "$cleanup_status" == 4 ]]; then
    return 4
  fi
  if [[ "$cleanup_status" == 3 ]]; then
    detached_launch_quarantine_required=1
    return 1
  fi
  if [[ "$cleanup_status" != 0 ]]; then
    detached_launch_quarantine_required=1
  fi
  return "$cleanup_status"
}

arm_windows_remote_cleanup() {
  [[ -n "${EAI_VM_APP_STATE_FILE:-}" && -n "${EAI_VM_RESULT_FILE:-}" \
      && "${EAI_VM_PROJECT_NAME:-}" =~ ^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$ ]] || return 1
  EAI_WINDOWS_APP_STATE="$EAI_VM_APP_STATE_FILE" \
  EAI_WINDOWS_CLEANUP_ARM="$(dirname "$EAI_VM_RESULT_FILE")/windows-remote-cleanup-arm.json" \
  EAI_WINDOWS_APP_NAME="$EAI_VM_PROJECT_NAME" node --input-type=module <<'NODE'
import fs from "node:fs";

const appStatePath = process.env.EAI_WINDOWS_APP_STATE;
const armPath = process.env.EAI_WINDOWS_CLEANUP_ARM;
const appName = process.env.EAI_WINDOWS_APP_NAME;
let existing = null;
try { existing = JSON.parse(fs.readFileSync(appStatePath, "utf8")); } catch {}
if (existing && existing.appName !== appName) {
  throw new Error("The existing Windows app-state file names another cleanup target.");
}
const armedAt = new Date().toISOString();
const state = {
  ...(existing && typeof existing === "object" ? existing : {}),
  appName,
  appCreated: true,
  cleanupRequired: true,
  cleanupRequested: true,
  state: "remote-mutation-cleanup-armed",
  conservative: true,
  armedAt,
};
const arm = {
  schemaVersion: "eai.windows-remote-cleanup-arm.v1",
  appName,
  cleanupRequired: true,
  mutationNotYetProven: true,
  armedAt,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
};
fs.writeFileSync(appStatePath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
fs.writeFileSync(armPath, `${JSON.stringify(arm, null, 2)}\n`, { mode: 0o600 });
NODE
}

cleanup_host_bridge() {
  local bridge_pid="$1"
  local child_pid
  local child_pids=""
  local attempt
  [[ "$bridge_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  for attempt in $(seq 1 10); do
    kill -0 "$bridge_pid" >/dev/null 2>&1 || break
    sleep 1
  done
  if kill -0 "$bridge_pid" >/dev/null 2>&1; then
    child_pids="$(/usr/bin/pgrep -P "$bridge_pid" 2>/dev/null || true)"
    for child_pid in $child_pids; do
      [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] && kill "$child_pid" >/dev/null 2>&1 || true
    done
    kill "$bridge_pid" >/dev/null 2>&1 || true
  fi
  wait "$bridge_pid" >/dev/null 2>&1 || true
}

guest_process_alive() {
  local pid_file="$1"
  local output=""
  local normalized=""
  local transport_status=0
  if output="$(guest_system_ps_readonly_run "$pid_file"$'\n'"$guest_executable_file"$'\n'"$guest_user"$'\n' 2 2>/dev/null <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$pidFile = [Console]::In.ReadLine()
$executableFile = [Console]::In.ReadLine()
$expectedUser = [Console]::In.ReadLine()
function Write-NotAlive {
  Write-Output 'EAI_GUEST_PROCESS_NOT_ALIVE'
  exit 0
}
function ConvertTo-ComparableAppPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { throw 'A detached application path is empty.' }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}
if (-not (Test-Path $pidFile)) { Write-NotAlive }
$expectedExecutable = if (Test-Path $executableFile) { (Get-Content -Raw $executableFile).Trim() } else { $null }
if (-not $expectedExecutable) { Write-NotAlive }
$processId = (Get-Content -Raw $pidFile).Trim()
if ($processId -notmatch '^[1-9][0-9]*$') { Write-NotAlive }
$process = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
if (-not $process) { Write-NotAlive }
try { $actualExecutable = ConvertTo-ComparableAppPath $process.Path } catch { Write-NotAlive }
if (-not [string]::Equals($actualExecutable, (ConvertTo-ComparableAppPath $expectedExecutable), [StringComparison]::OrdinalIgnoreCase)) { Write-NotAlive }
$cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
if (-not $cimProcess -or $process.SessionId -le 0) { Write-NotAlive }
$owner = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwner -ErrorAction SilentlyContinue
if (-not $owner -or $owner.ReturnValue -ne 0 -or -not [string]::Equals($owner.User, $expectedUser, [StringComparison]::OrdinalIgnoreCase)) { Write-NotAlive }
Write-Output 'EAI_GUEST_PROCESS_ALIVE'
POWERSHELL
  )"; then
    transport_status=0
  else
    transport_status=$?
  fi
  [[ "$transport_status" == 0 ]] || return 2
  normalized="$(printf '%s' "$output" | /usr/bin/tr -d '\r')"
  case "$normalized" in
    EAI_GUEST_PROCESS_ALIVE) return 0 ;;
    EAI_GUEST_PROCESS_NOT_ALIVE) return 1 ;;
    *) return 2 ;;
  esac
}

stop_guest_process() {
  local pid_file="$1"
  guest_system_ps_run "$pid_file"$'\n'"$guest_executable_file"$'\n'"$guest_user"$'\n' 5 >/dev/null 2>&1 <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$pidFile = [Console]::In.ReadLine()
$executableFile = [Console]::In.ReadLine()
$expectedUser = [Console]::In.ReadLine()
function ConvertTo-ComparableAppPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { throw 'A detached application path is empty.' }
  $fullPath = [IO.Path]::GetFullPath($path)
  if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = '\\' + $fullPath.Substring(8)
  } elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.Substring(4)
  }
  return $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}
if (-not (Test-Path $pidFile)) { throw "The expected EAI Setup PID file is missing: $pidFile" }
if (-not (Test-Path $executableFile)) { throw 'The canonical EAI Setup executable receipt is missing.' }
$expectedExecutable = (Get-Content -Raw $executableFile).Trim()
if (-not $expectedExecutable) { throw 'The canonical EAI Setup executable receipt is empty.' }
$processId = (Get-Content -Raw $pidFile).Trim()
if ($processId -notmatch '^[1-9][0-9]*$') { throw "The EAI Setup PID file is invalid: $pidFile" }
$process = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
if ($process) {
  try { $actualExecutable = ConvertTo-ComparableAppPath $process.Path } catch { throw "Cannot verify executable path for PID $processId." }
  if (-not [string]::Equals($actualExecutable, (ConvertTo-ComparableAppPath $expectedExecutable), [StringComparison]::OrdinalIgnoreCase)) {
    throw "PID $processId does not identify the canonical EAI Setup executable."
  }
  if ($process.SessionId -le 0) { throw "EAI Setup PID $processId is not in an interactive session." }
  $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
  $owner = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwner -ErrorAction Stop
  if ($owner.ReturnValue -ne 0 -or -not [string]::Equals($owner.User, $expectedUser, [StringComparison]::OrdinalIgnoreCase)) {
    throw "EAI Setup PID $processId is not owned by the expected release-test user."
  }
  Stop-Process -Id ([int]$processId) -Force
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    if (-not (Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
  }
}
if (Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue) {
  throw "EAI Setup PID $processId did not exit."
}
Remove-Item -Force $pidFile
if (Test-Path $pidFile) { throw "The exited EAI Setup PID receipt could not be removed: $pidFile" }
POWERSHELL
}

sanitize_log_file() {
  local source_path="$1"
  local destination="$2"
  [[ -f "$source_path" ]] || return 1
  mkdir -p "$(dirname "$destination")"
  EAI_LOG_SOURCE="$source_path" EAI_LOG_DESTINATION="$destination" node --input-type=module <<'NODE'
import fs from "node:fs";

let content = fs.readFileSync(process.env.EAI_LOG_SOURCE, "utf8");
const protectedValues = [];
for (const key of ["EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL"]) {
  const value = process.env[key];
  if (value) {
    protectedValues.push(value);
    content = content.split(value).join("[REDACTED]");
  }
}
content = content.replace(/[A-Za-z0-9+/]{16,}={0,2}/g, (candidate) => {
  try {
    const decoded = Buffer.from(candidate, "base64").toString("utf8");
    if (protectedValues.some((value) => decoded.includes(value))) return "[REDACTED_BASE64]";
  } catch {}
  return candidate;
});
content = content
  .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[REDACTED_EMAIL]")
  .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "[REDACTED_UUID]")
  .replace(/\bBearer\s+[^\s"'<>]+/gi, "Bearer [REDACTED]")
  .replace(/([?&](?:code|token|access_token|refresh_token|id_token|client_secret)=)[^&\s"'<>]+/gi, "$1[REDACTED]")
  .replace(/((?:(?:access|refresh|id)[_-]?token|authorization|client[_-]?secret|password)\s*[:=]\s*["']?)[^\s"',;}]+/gi, "$1[REDACTED]");
fs.writeFileSync(process.env.EAI_LOG_DESTINATION, content);
NODE
}

preserve_guest_log() {
  local guest_path="$1"
  local destination="$2"
  local log_label
  local raw_log
  log_label="$(printf '%s' "$guest_path" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  raw_log="$work_dir/raw-${log_label}.log"
  if guest_ps_run "$guest_path"$'\n' >"$raw_log" 2>/dev/null <<'POWERSHELL'; then
$path = [Console]::In.ReadLine()
if (-not (Test-Path $path)) { exit 1 }
Get-Content -Raw $path
POWERSHELL
    sanitize_log_file "$raw_log" "$destination"
  fi
}

preserve_guest_json_artifact() {
  local guest_path="$1"
  local destination="$2"
  local raw_json=""
  raw_json="$work_dir/guest-json-$(printf '%s' "$guest_path" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  if guest_system_ps_run "$guest_path"$'\n' 2 >"$raw_json" 2>/dev/null <<'POWERSHELL'; then
$path = [Console]::In.ReadLine()
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 1 }
Get-Content -Raw -LiteralPath $path
POWERSHELL
    sanitize_log_file "$raw_json" "$destination"
  fi
}

preserve_detached_launch_evidence() {
  local mode="$1"
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 0
  local evidence_dir=""
  evidence_dir="$(dirname "$EAI_VM_RESULT_FILE")"
  case "$mode" in
    normal)
      preserve_guest_json_artifact "$guest_normal_launch_receipt" "$evidence_dir/windows-normal-app-launch.json"
      preserve_guest_json_artifact "$guest_normal_launch_arm" "$evidence_dir/windows-normal-app-launch-arm.json"
      ;;
    e2e)
      preserve_guest_json_artifact "$guest_e2e_launch_receipt" "$evidence_dir/windows-e2e-app-launch.json"
      preserve_guest_json_artifact "$guest_e2e_launch_arm" "$evidence_dir/windows-e2e-app-launch-arm.json"
      ;;
    *) return 2 ;;
  esac
}

preserve_guest_logs() {
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 0
  local evidence_dir
  evidence_dir="$(dirname "$EAI_VM_RESULT_FILE")"
  preserve_guest_log "$guest_normal_log" "$evidence_dir/windows-normal-app.log"
  preserve_guest_log "$guest_normal_error_log" "$evidence_dir/windows-normal-app-error.log"
  preserve_guest_log "$guest_e2e_log" "$evidence_dir/windows-e2e-app.log"
  preserve_guest_log "$guest_e2e_error_log" "$evidence_dir/windows-e2e-app-error.log"
}

preserve_defender_bridge_logs() {
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 0
  local evidence_dir
  evidence_dir="$(dirname "$EAI_VM_RESULT_FILE")"
  sanitize_log_file "$work_dir/defender-guardian-bridge.stdout" \
    "$evidence_dir/windows-defender-guardian-bridge.stdout.log" || true
  sanitize_log_file "$work_dir/defender-guardian-bridge.stderr" \
    "$evidence_dir/windows-defender-guardian-bridge.stderr.log" || true
  sanitize_log_file "$work_dir/installer-bridge.stdout" \
    "$evidence_dir/windows-installer-bridge.stdout.log" || true
  sanitize_log_file "$work_dir/installer-bridge.stderr" \
    "$evidence_dir/windows-installer-bridge.stderr.log" || true
}

write_failure_result() {
  [[ -n "${EAI_VM_RESULT_FILE:-}" && -n "${EAI_VM_APP_STATE_FILE:-}" ]] || return 0
  local failure_receipt="$work_dir/failure-receipt.json"
  local failure_checkpoint="$work_dir/failure-checkpoint.json"
  if prlctl status "$vm_name" 2>/dev/null | grep -Fq running; then
    guest_ps >"$failure_receipt" 2>/dev/null <<'POWERSHELL' || true
if (Test-Path 'C:\Users\Public\eai-setup-e2e-receipt.json') {
  Get-Content -Raw 'C:\Users\Public\eai-setup-e2e-receipt.json'
}
POWERSHELL
    # This is deliberately local-only and exact-name scoped. It does not list
    # or mutate tenant resources. A matching generated package is sufficient
    # to flag that the remote app may require cleanup when no receipt exists.
    guest_ps_run "${EAI_VM_PROJECT_NAME:-unknown}"$'\n' >"$failure_checkpoint" 2>/dev/null <<'POWERSHELL' || true
$appName = [Console]::In.ReadLine()
$projectPath = Join-Path 'C:\Users\Public\EAIReleaseTests' $appName
$packagePath = Join-Path $projectPath 'package.json'
$packageNameMatches = $false
if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
  try {
    $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
    $packageNameMatches = $package.name -ceq "@eai-tools/$appName"
  } catch {}
}
[ordered]@{
  exactProjectDirectory = Test-Path -LiteralPath $projectPath -PathType Container
  packageJsonNameMatches = $packageNameMatches
} | ConvertTo-Json -Compress
POWERSHELL
  fi
  EAI_FAILURE_PHASE="$phase" EAI_FAILURE_RECEIPT="$failure_receipt" EAI_FAILURE_CHECKPOINT="$failure_checkpoint" node --input-type=module - \
    "$EAI_VM_RESULT_FILE" "$EAI_VM_APP_STATE_FILE" "${EAI_VM_PROJECT_NAME:-unknown}" <<'NODE'
import fs from "node:fs";

const [resultPath, appStatePath, appName] = process.argv.slice(2);
const readJson = (path) => {
  try {
    const text = fs.readFileSync(path, "utf8").trim();
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
};
let receipt = null;
receipt = readJson(process.env.EAI_FAILURE_RECEIPT);
const checkpoint = readJson(process.env.EAI_FAILURE_CHECKPOINT);
const existingResult = readJson(resultPath);
const existingAppState = readJson(appStatePath);
const required = ["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
const checks = Object.fromEntries(required.map((name) => [name, receipt?.checks?.[name] || "not-run"]));
const locallyGeneratedProject = checkpoint?.exactProjectDirectory === true && checkpoint?.packageJsonNameMatches === true;
const appCreated = existingResult?.appCreated === true
  || existingAppState?.appCreated === true
  || receipt?.appCreated === true
  || locallyGeneratedProject;
const fallbackResult = {
  status: "failed",
  vm: "windows",
  appName,
  appCreated,
  exactLocalProjectCheckpoint: locallyGeneratedProject,
  cleanupRequested: true,
  failedPhase: process.env.EAI_FAILURE_PHASE,
  checks,
  completedAt: new Date().toISOString(),
  message: `The Windows adapter stopped during ${process.env.EAI_FAILURE_PHASE}.`,
};
// guest_test_finalize may already have produced a much richer diagnostic
// result. Preserve it and only strengthen the cleanup checkpoint.
const result = existingResult && typeof existingResult === "object"
  ? {
      ...existingResult,
      appCreated,
      exactLocalProjectCheckpoint: locallyGeneratedProject,
      cleanupRequested: true,
      failedPhase: existingResult.failedPhase || process.env.EAI_FAILURE_PHASE,
    }
  : fallbackResult;
fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
const appState = existingAppState && typeof existingAppState === "object"
  ? { ...existingAppState, appName, appCreated, exactLocalProjectCheckpoint: locallyGeneratedProject }
  : {
      appName,
      appCreated,
      exactLocalProjectCheckpoint: locallyGeneratedProject,
      state: receipt ? "receipt" : locallyGeneratedProject ? "exact-local-project-checkpoint" : "not-proven",
    };
fs.writeFileSync(appStatePath, `${JSON.stringify(appState, null, 2)}\n`);
NODE
}

write_uac_policy_quarantine_diagnostic() {
  local diagnostic_file=""
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 1
  diagnostic_file="$(dirname "$EAI_VM_RESULT_FILE")/windows-uac-consent-policy-quarantine.json"
  EAI_UAC_QUARANTINE_FILE="$diagnostic_file" \
  EAI_UAC_QUARANTINE_VM="$vm_name" \
  EAI_UAC_QUARANTINE_SNAPSHOT="$snapshot_id" \
  EAI_UAC_QUARANTINE_PHASE="$phase" \
  EAI_UAC_QUARANTINE_NONCE="$uac_policy_nonce" \
  EAI_UAC_QUARANTINE_RUN_BINDING="$uac_policy_run_binding" \
    node --input-type=module <<'NODE'
import { writeFileSync } from "node:fs";
const diagnostic = {
  schemaVersion: "eai-windows-uac-consent-policy-quarantine/v1",
  recordedAt: new Date().toISOString(),
  vm: process.env.EAI_UAC_QUARANTINE_VM,
  approvedSnapshot: process.env.EAI_UAC_QUARANTINE_SNAPSHOT,
  failedPhase: process.env.EAI_UAC_QUARANTINE_PHASE,
  nonce: /^[0-9a-f]{32}$/.test(process.env.EAI_UAC_QUARANTINE_NONCE || "")
    ? process.env.EAI_UAC_QUARANTINE_NONCE
    : null,
  runBindingSha256: /^[0-9a-f]{64}$/.test(process.env.EAI_UAC_QUARANTINE_RUN_BINDING || "")
    ? process.env.EAI_UAC_QUARANTINE_RUN_BINDING
    : null,
  restorationVerified: false,
  quarantineRequired: true,
  restoreApprovedSnapshotBeforeReuse: true,
  diagnosticOnly: true,
  productionGate: false,
};
writeFileSync(process.env.EAI_UAC_QUARANTINE_FILE, `${JSON.stringify(diagnostic, null, 2)}\n`, { mode: 0o600 });
NODE
}

write_detached_launch_quarantine_diagnostic() {
  local diagnostic_file=""
  local normal_bound=false
  local e2e_bound=false
  [[ -n "${EAI_VM_RESULT_FILE:-}" ]] || return 1
  diagnostic_file="$(dirname "$EAI_VM_RESULT_FILE")/windows-detached-launch-quarantine.json"
  [[ "$normal_launch_nonce" =~ ^[0-9a-f]{32}$ ]] && normal_bound=true
  [[ "$e2e_launch_nonce" =~ ^[0-9a-f]{32}$ ]] && e2e_bound=true
  EAI_DETACHED_QUARANTINE_FILE="$diagnostic_file" \
  EAI_DETACHED_QUARANTINE_VM="$vm_name" \
  EAI_DETACHED_QUARANTINE_SNAPSHOT="$snapshot_id" \
  EAI_DETACHED_QUARANTINE_PHASE="$phase" \
  EAI_DETACHED_NORMAL_BOUND="$normal_bound" \
  EAI_DETACHED_E2E_BOUND="$e2e_bound" \
    node --input-type=module <<'NODE'
import { writeFileSync } from "node:fs";
const diagnostic = {
  schemaVersion: "eai-windows-detached-launch-quarantine/v1",
  recordedAt: new Date().toISOString(),
  vm: process.env.EAI_DETACHED_QUARANTINE_VM,
  approvedSnapshot: process.env.EAI_DETACHED_QUARANTINE_SNAPSHOT,
  failedPhase: process.env.EAI_DETACHED_QUARANTINE_PHASE,
  normalLaunchBound: process.env.EAI_DETACHED_NORMAL_BOUND === "true",
  e2eLaunchBound: process.env.EAI_DETACHED_E2E_BOUND === "true",
  exactBootstrapAndChildTerminalProof: false,
  cancellationSignalMayRemain: true,
  quarantineRequired: true,
  restoreApprovedSnapshotBeforeReuse: true,
  sanitized: true,
  diagnosticOnly: true,
  productionGate: false,
};
writeFileSync(process.env.EAI_DETACHED_QUARANTINE_FILE, `${JSON.stringify(diagnostic, null, 2)}\n`, { mode: 0o600 });
NODE
}

cleanup() {
  local status=$?
  local defender_cleanup_failed=0
  local installer_bridge_cleanup_failed=0
  local uac_policy_cleanup_failed=0
  local detached_app_cleanup_failed=0
  local vm_running=0
  set +e

  if prlctl status "$vm_name" 2>/dev/null | grep -Fq running; then
    vm_running=1
    # Preserve whatever final arm/receipt bytes exist before cancellation or
    # removal. Validation failure is diagnostic evidence, not permission to
    # erase the only copy of the interrupted state.
    preserve_detached_launch_evidence normal >/dev/null 2>&1 || true
    preserve_detached_launch_evidence e2e >/dev/null 2>&1 || true
    cleanup_detached_guest_app normal 0 >/dev/null 2>&1 || detached_app_cleanup_failed=1
    cleanup_detached_guest_app e2e 0 >/dev/null 2>&1 || detached_app_cleanup_failed=1
    set +e
  elif [[ "$normal_launch_nonce" =~ ^[0-9a-f]{32}$ || "$e2e_launch_nonce" =~ ^[0-9a-f]{32}$ ]]; then
    detached_app_cleanup_failed=1
    detached_launch_quarantine_required=1
  fi

  # Keep the consent-UI watcher and temporary no-prompt policy active until
  # the exact bootstrap/application terminal proof above has completed.
  stop_prerequisite_uac_watcher >/dev/null 2>&1 || true
  if [[ "$uac_consent_restore_required" == 1 ]]; then
    restore_admin_consent_prompt >/dev/null 2>&1 || uac_policy_cleanup_failed=1
    set +e
  fi
  if [[ "$installer_bridge_pending" == 1 ]]; then
    cancel_installer_bridge "${host_hash:-}" >/dev/null 2>&1 || installer_bridge_cleanup_failed=1
    if [[ "$defender_exclusion_pending" == 1 ]]; then
      wait_installer_bridge_terminal "${host_hash:-}" >/dev/null 2>&1 || installer_bridge_cleanup_failed=1
    else
      wait_installer_bridge_terminal_cmd "${host_hash:-}" >/dev/null 2>&1 || installer_bridge_cleanup_failed=1
    fi
    wait_installer_bridge_exit any >/dev/null 2>&1 || installer_bridge_cleanup_failed=1
    preserve_installer_bridge_evidence any >/dev/null 2>&1 || true
    set +e
  fi
  if [[ "$defender_exclusion_pending" == 1 ]]; then
    preserve_defender_evidence add any >/dev/null 2>&1 || true
    if [[ "$defender_cleanup_wait_exhausted" == 1 ]]; then
      defender_cleanup_failed=1
    else
      stop_defender_guardian >/dev/null 2>&1 || defender_cleanup_failed=1
    fi
    # The transport helpers restore errexit after their own probes. Keep the
    # EXIT handler best-effort until every evidence and process cleanup step
    # has run.
    set +e
  fi
  preserve_defender_bridge_logs
  set +e
  # A failure before start_installer_bridge has no protected bridge artifacts
  # to remove.  In that case both identifiers are deliberately empty; do not
  # turn the original phase into a synthetic cleanup failure by calling the
  # hash-bound remover without an initialized bridge identity.
  if [[ "$installer_bridge_pending" != 1 && "$defender_exclusion_pending" != 1 \
      && "${installer_worker_hash:-}" =~ ^[0-9a-f]{64}$ \
      && "${installer_worker_nonce:-}" =~ ^[0-9a-f]{32}$ ]]; then
    cleanup_installer_bridge_artifacts >/dev/null 2>&1 || installer_bridge_cleanup_failed=1
    set +e
  fi
  if [[ "$defender_cleanup_failed" == 1 || ("$defender_exclusion_added" == 1 && "$defender_exclusion_removed" != 1) ]]; then
    status=1
    phase="defender-exact-file-cleanup"
  fi
  if [[ "$installer_bridge_cleanup_failed" == 1 || "$installer_bridge_pending" == 1 ]]; then
    status=1
    phase="installer-bridge-cleanup"
  fi
  if [[ "$uac_policy_cleanup_failed" == 1 || "$uac_consent_restore_required" == 1 ]]; then
    status=1
    phase="uac-admin-consent-restoration"
    write_uac_policy_quarantine_diagnostic >/dev/null 2>&1 || true
  fi
  if [[ "$detached_app_cleanup_failed" == 1 ]]; then
    detached_launch_quarantine_required=1
    status=1
    phase="detached-app-cleanup"
    write_detached_launch_quarantine_diagnostic >/dev/null 2>&1 || true
  fi
  if [[ "$completed" != 1 && "$status" != 0 && "$installer_bridge_pending" != 1 && "$defender_exclusion_pending" != 1 ]]; then
    write_failure_result
  fi
  set +e
  if [[ "$vm_running" == 1 ]] || prlctl status "$vm_name" 2>/dev/null | grep -Fq running; then
    preserve_guest_logs
  fi
  set +e
  if [[ "$defender_exclusion_pending" == 1 || "$installer_bridge_pending" == 1 \
      || "$uac_consent_restore_required" == 1 || "$detached_launch_quarantine_required" == 1 ]]; then
    printf 'Retaining unresolved protected-change diagnostics at %s\n' "$work_dir" >&2
  else
    rm -rf -- "$work_dir"
  fi
  trap - EXIT
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

guest_versions_json() {
  guest_ps <<'POWERSHELL' | tr -d '\r' | tail -n 1
function Test-ProgramPath([string]$path) {
  if (-not $path -or $path -match '(?i)\\Microsoft\\WindowsApps\\') { return $false }
  try {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    return -not $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
      $item.Extension -in @('.exe', '.cmd')
  } catch {
    return $false
  }
}
function Resolve-Program([string]$name, [string[]]$relativePaths) {
  $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA) |
    Where-Object { $_ } | Select-Object -Unique
  foreach ($root in $roots) {
    foreach ($relative in $relativePaths) {
      $candidate = Join-Path $root $relative
      if (Test-ProgramPath $candidate) { return (Get-Item -LiteralPath $candidate -Force).FullName }
    }
  }
  $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command -and (Test-ProgramPath $command.Source)) {
    return (Get-Item -LiteralPath $command.Source -Force).FullName
  }
  return $null
}
function Read-Version([string]$path) {
  if (-not (Test-ProgramPath $path)) { return $null }
  $path = (Get-Item -LiteralPath $path -Force).FullName
  if ($path -match '[\r\n"&|<>^]') { return $null }
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  if ([IO.Path]::GetExtension($path) -ieq '.cmd') {
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/D /S /C ""' + $path + '" --version"'
  } else {
    $startInfo.FileName = $path
    $startInfo.Arguments = '--version'
  }
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { return $null }
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(5000)) {
      & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F *> $null
      $process.WaitForExit(5000) | Out-Null
      return $null
    }
    $streamsCompleted = [Threading.Tasks.Task]::WaitAll(@($standardOutput, $standardError), 1000)
    if (-not $streamsCompleted) {
      $process.StandardOutput.Dispose()
      $process.StandardError.Dispose()
      return $null
    }
    if ($process.ExitCode -ne 0) { return $null }
    return (($standardOutput.Result + "`n" + $standardError.Result) | Out-String).Trim()
  } catch {
    return $null
  } finally {
    $process.Dispose()
  }
}
$git = Resolve-Program git.exe @('Git\cmd\git.exe', 'Programs\Git\cmd\git.exe')
$node = Resolve-Program node.exe @('nodejs\node.exe', 'Programs\nodejs\node.exe')
$npm = Resolve-Program npm.cmd @('nodejs\npm.cmd', 'Programs\nodejs\npm.cmd', 'npm\npm.cmd')
$eai = Resolve-Program eai.cmd @('npm\eai.cmd', 'EAI Setup\npm-global\eai.cmd')
[ordered]@{
  git = Read-Version $git
  node = Read-Version $node
  npm = Read-Version $npm
  eai = Read-Version $eai
} | ConvertTo-Json -Compress
POWERSHELL
}

versions_satisfy_contract() {
  local versions="$1"
  EAI_WINDOWS_VERSIONS="$versions" EAI_EXPECTED_CLI_VERSION="$expected_cli_version" node --input-type=module <<'NODE'
const versions = JSON.parse(process.env.EAI_WINDOWS_VERSIONS);
const nodeMajor = Number.parseInt(String(versions.node || "").replace(/^v/, "").split(".")[0], 10);
const expectedCli = process.env.EAI_EXPECTED_CLI_VERSION;
const cliVersion = String(versions.eai || "").match(/[0-9]+\.[0-9]+\.[0-9]+/)?.[0];
if (!versions.git || !Number.isInteger(nodeMajor) || nodeMajor < 24 || !versions.npm || cliVersion !== expectedCli) {
  process.exitCode = 1;
}
NODE
}

guest_test_require prlctl
guest_test_require node
guest_test_require security
guest_test_require swiftc
guest_test_require iconv
guest_test_require base64
guest_test_require screencapture
guest_test_require osascript
guest_test_require_environment
[[ "${EAI_RELEASE_VERSION:-}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || guest_test_fail "EAI_RELEASE_VERSION must be a semantic version."
[[ -f "$ocr_source" ]] || guest_test_fail "The screenshot OCR helper is missing."
[[ -f "$window_id_source" ]] || guest_test_fail "The Parallels window lookup helper is missing."
[[ "$guest_user" =~ ^[A-Za-z0-9._-]+$ ]] || guest_test_fail "The Windows guest user is invalid."

if [[ ! -x "$ocr_binary" || "$ocr_source" -nt "$ocr_binary" ]]; then
  swiftc -O "$ocr_source" -o "$ocr_binary" >/dev/null \
    || guest_test_fail "The screenshot OCR helper could not be compiled."
fi
if [[ ! -x "$window_id_binary" || "$window_id_source" -nt "$window_id_binary" ]]; then
  swiftc -O "$window_id_source" -o "$window_id_binary" >/dev/null \
    || guest_test_fail "The Parallels window lookup helper could not be compiled."
fi
EAI_WINDOWS_VM_NAME="$vm_name" "$ROOT/scripts/login-windows-guest.sh" --preflight \
  || guest_test_fail "The protected Enterprise AI login credential is unavailable."

stage snapshot-restore
guest_test_restore_snapshot "$vm_name" "$snapshot_id"

stage guest-session
actual_user=""
powershell_identity=""
session_stable_reads=0
guest_user_lower="$(printf '%s' "$guest_user" | /usr/bin/tr '[:upper:]' '[:lower:]')"
for _ in $(seq 1 120); do
  actual_user="$(printf '%s\n' '[Security.Principal.WindowsIdentity]::GetCurrent().Name' | windows_hidden_current_user_ps "$vm_name" 2>/dev/null | tr -d '\r\n' | tr '[:upper:]' '[:lower:]' || true)"
  if [[ "$actual_user" == *"\\$guest_user_lower" ]]; then
    powershell_identity="$(guest_ps 1 2>/dev/null <<'POWERSHELL' || true
[Security.Principal.WindowsIdentity]::GetCurrent().Name.ToLowerInvariant()
POWERSHELL
)"
    powershell_identity="$(printf '%s' "$powershell_identity" | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')"
    if [[ "$powershell_identity" == *"\\$guest_user_lower" ]]; then
      session_stable_reads=$((session_stable_reads + 1))
      [[ "$session_stable_reads" -ge 3 ]] && break
    else
      session_stable_reads=0
    fi
  else
    session_stable_reads=0
  fi
  sleep 2
done
[[ "$actual_user" == *"\\$guest_user_lower" && "$powershell_identity" == *"\\$guest_user_lower" && "$session_stable_reads" -ge 3 ]] \
  || guest_test_fail "Windows current-user cmd and PowerShell channels did not stabilize as $guest_user."
stage guest-session-stable

if ! show_vm_console; then
  exit_vm_coherence_if_needed \
    || guest_test_fail "The exact Windows VM could not be proven windowed after a one-shot Coherence exit."
  show_vm_console \
    || guest_test_fail "The exact Windows Parallels console window could not be opened after leaving Coherence."
fi
capture_vm_window "$work_dir/windows-console-preflight.png" \
  || guest_test_fail "The exact Windows Parallels console window is not visible for prerequisite consent-UI monitoring."
rm -f "$work_dir/windows-console-preflight.png"
stage host-console-visible

stage clean-snapshot-preflight
baseline_json="$(guest_ps <<'POWERSHELL' | tr -d '\r' | tail -n 1
$os = Get-CimInstance Win32_OperatingSystem
$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$identity = $windowsIdentity.Name
$localAdministrator = $false
try {
  $localAdministrator = [bool](
    Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop |
      Where-Object { $_.SID.Value -eq $windowsIdentity.User.Value }
  )
} catch {
  # A filtered UAC token marks the Administrators SID deny-only, so token
  # membership is not a valid test of account membership. Keep a read-only
  # ADSI fallback for Windows images where LocalAccounts is unavailable.
  $administrators = [ADSI]("WinNT://$env:COMPUTERNAME/Administrators,group")
  $administratorMemberSids = @(
    $administrators.psbase.Invoke('Members') | ForEach-Object {
      $rawSid = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
      [Security.Principal.SecurityIdentifier]::new($rawSid, 0).Value
    }
  )
  $localAdministrator = $administratorMemberSids -contains $windowsIdentity.User.Value
}
function Test-RealProgramPath([string]$path) {
  if (-not $path -or $path -match '(?i)\\Microsoft\\WindowsApps\\') { return $false }
  try {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    return -not $item.PSIsContainer -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and
      $item.Extension -in @('.exe', '.cmd')
  } catch {
    return $false
  }
}
function Resolve-RealCommand([string]$name) {
  $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  return $command -and (Test-RealProgramPath $command.Source)
}
$gitPaths = @(
  (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
  (Join-Path $env:ProgramFiles 'Git\bin\git.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
)
$nodePaths = @(
  (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
)
$npmPaths = @(
  (Join-Path $env:ProgramFiles 'nodejs\npm.cmd'),
  (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\npm.cmd'),
  (Join-Path $env:APPDATA 'npm\npm.cmd')
)
$eaiPaths = @(
  (Join-Path $env:APPDATA 'npm\eai.cmd'),
  (Join-Path $env:LOCALAPPDATA 'EAI Setup\npm-global\eai.cmd'),
  (Join-Path $env:LOCALAPPDATA 'Programs\EAI Setup\npm-global\eai.cmd')
)
$vscode = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
$setupPaths = @(
  (Join-Path $env:LOCALAPPDATA 'EAI Setup\eai-setup.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\EAI Setup\eai-setup.exe'),
  (Join-Path $env:LOCALAPPDATA 'EAI Setup\EAI Setup.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\EAI Setup\EAI Setup.exe')
)
$setupArtifactPaths = @(
  (Join-Path $env:LOCALAPPDATA 'EAI Setup'),
  (Join-Path $env:LOCALAPPDATA 'Programs\EAI Setup')
)
$uninstallPaths = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$uninstallEntries = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue)
$userStatePaths = @(
  (Join-Path $env:USERPROFILE '.eai'),
  (Join-Path $env:USERPROFILE '.eai-setup'),
  (Join-Path $env:LOCALAPPDATA 'EAISetup'),
  (Join-Path $env:APPDATA 'EAISetup')
)
$publicArtifacts = @(
  'C:\Users\Public\EAISetup',
  'C:\Users\Public\EAIReleaseTests',
  'C:\Users\Public\eai-setup-under-test.exe',
  'C:\Users\Public\eai-setup-e2e-executable.txt',
  'C:\Users\Public\eai-setup-e2e-install.json',
  'C:\Users\Public\eai-setup-e2e-receipt.json',
  'C:\Users\Public\eai-setup-normal.pid',
  'C:\Users\Public\eai-setup-normal.pid.tmp',
  'C:\Users\Public\eai-setup-e2e.pid',
  'C:\Users\Public\eai-setup-e2e.pid.tmp',
  'C:\Users\Public\eai-setup-normal-launch.json',
  'C:\Users\Public\eai-setup-normal-launch.json.tmp',
  'C:\Users\Public\eai-setup-e2e-launch.json',
  'C:\Users\Public\eai-setup-e2e-launch.json.tmp',
  'C:\Users\Public\eai-setup-normal-launch-arm.json',
  'C:\Users\Public\eai-setup-normal-launch-arm.json.tmp',
  'C:\Users\Public\eai-setup-e2e-launch-arm.json',
  'C:\Users\Public\eai-setup-e2e-launch-arm.json.tmp',
  'C:\Users\Public\eai-setup-normal-launch-cancel.signal',
  'C:\Users\Public\eai-setup-normal-launch-cancel.signal.tmp',
  'C:\Users\Public\eai-setup-e2e-launch-cancel.signal',
  'C:\Users\Public\eai-setup-e2e-launch-cancel.signal.tmp',
  'C:\Users\Public\eai-setup-app-bootstrap.ps1',
  'C:\Users\Public\eai-setup-app-bootstrap.ps1.tmp',
  'C:\Users\Public\eai-setup-normal.log',
  'C:\Users\Public\eai-setup-normal-error.log',
  'C:\Users\Public\eai-setup-e2e.log',
  'C:\Users\Public\eai-setup-e2e-error.log',
  'C:\Users\Public\eai-setup-defender-add.json',
  'C:\Users\Public\eai-setup-defender-add.json.tmp',
  'C:\Users\Public\eai-setup-defender-remove.json',
  'C:\Users\Public\eai-setup-defender-remove.json.tmp',
  'C:\Users\Public\eai-setup-defender-guardian.ps1',
  'C:\Users\Public\eai-setup-defender-guardian.ps1.tmp',
  'C:\Users\Public\eai-setup-defender-guardian-armed.json',
  'C:\Users\Public\eai-setup-defender-guardian-armed.json.tmp',
  'C:\Users\Public\eai-setup-defender-done.signal',
  'C:\Users\Public\eai-setup-defender-done.signal.tmp',
  'C:\Users\Public\eai-setup-defender-target-ready.signal',
  'C:\Users\Public\eai-setup-defender-target-ready.signal.tmp',
  'C:\Users\Public\eai-setup-installer-worker.ps1',
  'C:\Users\Public\eai-setup-installer-worker.ps1.tmp',
  'C:\Users\Public\eai-setup-installer-bridge-armed.json',
  'C:\Users\Public\eai-setup-installer-bridge-armed.json.tmp',
  'C:\Users\Public\eai-setup-installer-launch.signal',
  'C:\Users\Public\eai-setup-installer-launch.signal.tmp',
  'C:\Users\Public\eai-setup-installer-cancel.signal',
  'C:\Users\Public\eai-setup-installer-cancel.signal.tmp',
  'C:\Users\Public\eai-setup-installer-complete.json',
  'C:\Users\Public\eai-setup-installer-complete.json.tmp'
)
$uacPolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacPolicyItem = Get-Item -LiteralPath $uacPolicyPath -ErrorAction Stop
[ordered]@{
  os = $os.Caption
  version = $os.Version
  osArchitecture = $os.OSArchitecture
  processArchitecture = $env:PROCESSOR_ARCHITECTURE
  identity = $identity
  localAdministrator = $localAdministrator
  interactive = [Environment]::UserInteractive
  parallelsTools = [bool](Get-Process prl_tools_service -ErrorAction SilentlyContinue)
  winget = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
  promptOnSecureDesktopKind = [string]$uacPolicyItem.GetValueKind('PromptOnSecureDesktop')
  promptOnSecureDesktop = [int](Get-ItemPropertyValue -LiteralPath $uacPolicyPath -Name 'PromptOnSecureDesktop' -ErrorAction Stop)
  consentPromptBehaviorAdminKind = [string]$uacPolicyItem.GetValueKind('ConsentPromptBehaviorAdmin')
  consentPromptBehaviorAdmin = [int](Get-ItemPropertyValue -LiteralPath $uacPolicyPath -Name 'ConsentPromptBehaviorAdmin' -ErrorAction Stop)
  enableLUAKind = [string]$uacPolicyItem.GetValueKind('EnableLUA')
  enableLUA = [int](Get-ItemPropertyValue -LiteralPath $uacPolicyPath -Name 'EnableLUA' -ErrorAction Stop)
  edgeProcesses = [bool](Get-Process msedge -ErrorAction SilentlyContinue)
  git = [bool]((Resolve-RealCommand git.exe) -or ($gitPaths | Where-Object { Test-RealProgramPath $_ }) -or ($uninstallEntries | Where-Object { $_.DisplayName -match '^Git(?: version)?(?:\s|$)' }))
  node = [bool]((Resolve-RealCommand node.exe) -or ($nodePaths | Where-Object { Test-RealProgramPath $_ }) -or ($uninstallEntries | Where-Object { $_.DisplayName -match '^Node[.]js(?:\s|$)' }))
  npm = [bool]((Resolve-RealCommand npm.cmd) -or ($npmPaths | Where-Object { Test-RealProgramPath $_ }))
  eai = [bool]((Resolve-RealCommand eai.cmd) -or ($eaiPaths | Where-Object { Test-RealProgramPath $_ }))
  vscode = Test-Path $vscode
  eaiSetup = [bool](($setupPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) -or ($setupArtifactPaths | Where-Object { Test-Path -LiteralPath $_ }) -or ($uninstallEntries | Where-Object { $_.DisplayName -eq 'EAI Setup' }))
  userEaiState = [bool]($userStatePaths | Where-Object { Test-Path -LiteralPath $_ })
  publicTestArtifacts = [bool]($publicArtifacts | Where-Object { Test-Path -LiteralPath $_ })
} | ConvertTo-Json -Compress
POWERSHELL
)"
EAI_WINDOWS_BASELINE="$baseline_json" EAI_WINDOWS_EXPECTED_USER="$guest_user" node --input-type=module <<'NODE'
const value = JSON.parse(process.env.EAI_WINDOWS_BASELINE);
const expectedUser = process.env.EAI_WINDOWS_EXPECTED_USER.toLowerCase();
if (!String(value.os).includes("Windows 11")) throw new Error(`Expected Windows 11, found ${value.os}`);
if (!String(value.osArchitecture).toUpperCase().includes("ARM") || value.processArchitecture !== "ARM64") throw new Error("The Windows guest is not ARM64.");
if (!String(value.identity).toLowerCase().endsWith(`\\${expectedUser}`) || value.interactive !== true) throw new Error("The Windows guest session identity is invalid.");
if (value.localAdministrator !== true) throw new Error("The approved Windows release-test user is not a local administrator.");
if (value.parallelsTools !== true || value.winget !== true) throw new Error("Parallels Tools or WinGet is unavailable.");
if (value.promptOnSecureDesktopKind !== "DWord" || value.promptOnSecureDesktop !== 0 ||
    value.consentPromptBehaviorAdminKind !== "DWord" || value.consentPromptBehaviorAdmin !== 5 ||
    value.enableLUAKind !== "DWord" || value.enableLUA !== 1) {
  throw new Error("The approved Windows snapshot does not have the required UAC consent-policy baseline.");
}
for (const key of ["edgeProcesses", "git", "node", "npm", "eai", "vscode", "eaiSetup", "userEaiState", "publicTestArtifacts"]) {
  if (value[key] !== false) throw new Error(`The approved Windows snapshot is not clean: ${key} is already present.`);
}
NODE
before_versions='{"git":null,"node":null,"npm":null,"eai":null}'
stage clean-snapshot-preflight-passed

stage ai-workspace-provision
EAI_WINDOWS_VM_NAME="$vm_name" EAI_WINDOWS_GUEST_USER="$guest_user" \
  "$ROOT/scripts/prepare-windows-ai-workspace.sh"
stage ai-workspace-provision-passed

stage portal-login
EAI_WINDOWS_VM_NAME="$vm_name" "$ROOT/scripts/login-windows-guest.sh" --portal-only \
  || guest_test_fail "Enterprise AI portal login failed in the Windows guest."
stage portal-login-passed

host_hash="$(guest_test_host_sha256)"
stage installer-bridge-arm
start_installer_bridge "$host_hash" "$guest_user" \
  || guest_test_fail "The protected current-user installer bridge could not arm before the Defender guardian."
stage installer-bridge-armed

stage defender-exact-file-allowance-arm
start_defender_guardian "$host_hash" "$installer_worker_hash" "$installer_worker_nonce" \
  || guest_test_fail "The protected Windows Defender exact-file guardian could not arm the empty target path."
stage defender-exact-file-allowance-armed

stage exact-asset-download
guest_system_ps_run "$EAI_VM_DOWNLOAD_URL"$'\n' 5 <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid)) {
  throw 'The exact release download is not running through the protected LocalSystem channel.'
}
$url = [Console]::In.ReadLine()
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile 'C:\Users\Public\eai-setup-under-test.exe'
POWERSHELL
guest_hash="$(guest_system_ps_run "" 5 <<'POWERSHELL' | tr -d '\r' | tail -n 1
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid)) { exit 1 }
(Get-FileHash -Algorithm SHA256 'C:\Users\Public\eai-setup-under-test.exe').Hash.ToLowerInvariant()
POWERSHELL
)"
[[ "$guest_hash" == "$host_hash" ]] || guest_test_fail "The Windows guest installer hash does not match the host release asset."
guest_system_ps_run "" 5 <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid)) {
  throw 'The target-ready marker is not running through the protected LocalSystem channel.'
}
$readyTemporary = 'C:\Users\Public\eai-setup-defender-target-ready.signal.tmp'
$readySignal = 'C:\Users\Public\eai-setup-defender-target-ready.signal'
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')

function Assert-SystemReadyMarker([string]$path) {
  $expectedValue = 'download-complete'
  $item = Get-Item -LiteralPath $path -ErrorAction Stop
  $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
  $actualBytes = [IO.File]::ReadAllBytes($path)
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      -not [string]::Equals($item.FullName, $path, [StringComparison]::OrdinalIgnoreCase) -or
      $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $systemSid.Value -or
      $item.Length -ne 17 -or $actualBytes.Length -ne 17 -or
      [Text.Encoding]::ASCII.GetString($actualBytes) -cne $expectedValue) {
    throw "The Defender target-ready marker is invalid: $path"
  }
}

if ((Test-Path -LiteralPath $readyTemporary) -or (Test-Path -LiteralPath $readySignal)) {
  throw 'A Defender target-ready marker path is already occupied.'
}
$readyBytes = [Text.Encoding]::ASCII.GetBytes('download-complete')
$readyStream = $null
try {
  $readyStream = [IO.File]::Open($readyTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $readyStream.Write($readyBytes, 0, $readyBytes.Length)
  $readyStream.Flush($true)
}
finally {
  if ($null -ne $readyStream) { $readyStream.Dispose() }
}
$readyAcl = Get-Acl -LiteralPath $readyTemporary -ErrorAction Stop
$readyAcl.SetOwner($systemSid)
Set-Acl -LiteralPath $readyTemporary -AclObject $readyAcl -ErrorAction Stop
Assert-SystemReadyMarker $readyTemporary
[IO.File]::Move($readyTemporary, $readySignal)
Assert-SystemReadyMarker $readySignal
POWERSHELL
stage exact-asset-download-passed

stage defender-exact-file-allowance-verify
wait_defender_guardian_ready \
  || guest_test_fail "The protected Windows Defender guardian did not verify the exact downloaded asset."
preserve_defender_evidence add ready \
  || guest_test_fail "The Windows Defender exact-file allowance could not be proven."
defender_exclusion_added=1
stage defender-exact-file-allowance-active

stage native-installer
installer_execution_ok=0
installer_terminal_seen=0
installer_bridge_exit_ok=0
defender_cleanup_ok=0
installer_exit_mode=any
installer_evidence_status=any
if signal_installer_bridge_launch "$host_hash"; then
  if wait_installer_bridge_terminal "$host_hash"; then
    installer_terminal_seen=1
    if preserve_installer_bridge_evidence completed; then
      installer_execution_ok=1
      installer_exit_mode=success
      installer_evidence_status=completed
    else
      preserve_installer_bridge_evidence any >/dev/null 2>&1 || true
    fi
  fi
fi
if [[ "$installer_terminal_seen" != 1 ]]; then
  cancel_installer_bridge "$host_hash" >/dev/null 2>&1 || true
  wait_installer_bridge_terminal "$host_hash" >/dev/null 2>&1 || true
  preserve_installer_bridge_evidence any >/dev/null 2>&1 || true
fi

stage defender-exact-file-cleanup
if stop_defender_guardian; then
  defender_cleanup_ok=1
fi
if wait_installer_bridge_exit "$installer_exit_mode"; then
  installer_bridge_exit_ok=1
fi
preserve_installer_bridge_evidence "$installer_evidence_status" >/dev/null 2>&1 || true
preserve_defender_bridge_logs
if [[ "$installer_bridge_exit_ok" == 1 && "$defender_cleanup_ok" == 1 ]]; then
  cleanup_installer_bridge_artifacts \
    || guest_test_fail "The fixed Windows installer bridge artifacts could not be removed."
fi
[[ "$installer_execution_ok" == 1 && "$installer_bridge_exit_ok" == 1 ]] \
  || guest_test_fail "The protected current-user installer bridge did not complete the exact installer successfully."
[[ "$defender_cleanup_ok" == 1 ]] \
  || guest_test_fail "The Windows Defender exact-file allowance was not removed and independently verified."
stage defender-exact-file-cleanup-passed

guest_ps_run "$EAI_RELEASE_VERSION"$'\n' <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$expectedVersion = [Console]::In.ReadLine()
if ($expectedVersion -cnotmatch '^[0-9]+[.][0-9]+[.][0-9]+$') { throw 'The expected EAI Setup version is invalid.' }
$receipt = 'C:\Users\Public\eai-setup-e2e-receipt.json'
$exeFile = 'C:\Users\Public\eai-setup-e2e-executable.txt'
$installReceipt = 'C:\Users\Public\eai-setup-e2e-install.json'
$parent = 'C:\Users\Public\EAIReleaseTests'
Remove-Item -Force $receipt, $exeFile, $installReceipt, 'C:\Users\Public\eai-setup-normal.pid', 'C:\Users\Public\eai-setup-e2e.pid' -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$executable = Join-Path $env:LOCALAPPDATA 'EAI Setup\eai-setup.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
  throw "The canonical EAI Setup executable was not installed at $executable"
}
$uninstallPaths = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$uninstallEntries = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'EAI Setup' })
if ($uninstallEntries.Count -ne 1) {
  throw "Expected exactly one EAI Setup uninstall record, found $($uninstallEntries.Count)."
}
$uninstallEntry = $uninstallEntries[0]
if ([string]$uninstallEntry.DisplayVersion -cne $expectedVersion) {
  throw 'The EAI Setup uninstall record does not match the exact release version.'
}
if ([string]::IsNullOrWhiteSpace([string]$uninstallEntry.UninstallString)) {
  throw 'The EAI Setup uninstall record has no uninstall command.'
}
$canonicalDirectory = Split-Path -Parent $executable
$recordedDirectory = ([string]$uninstallEntry.InstallLocation).Trim().Trim('"')
if (-not [string]::Equals($recordedDirectory, $canonicalDirectory, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The EAI Setup uninstall record does not identify the canonical install directory.'
}
$recordedUninstaller = ([string]$uninstallEntry.UninstallString).Trim().Trim('"')
$canonicalUninstaller = Join-Path $canonicalDirectory 'uninstall.exe'
if (-not [string]::Equals($recordedUninstaller, $canonicalUninstaller, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The EAI Setup uninstall record does not identify the canonical uninstaller.'
}
Set-Content -NoNewline -Path $exeFile -Value $executable
[ordered]@{
  canonicalExecutable = $executable
  displayName = [string]$uninstallEntry.DisplayName
  displayVersion = [string]$uninstallEntry.DisplayVersion
  uninstallMetadataPresent = $true
} | ConvertTo-Json | Set-Content -Encoding UTF8 -Path $installReceipt
POWERSHELL
executable_hash="$(guest_ps <<'POWERSHELL' | tr -d '\r' | tail -n 1
$executable = (Get-Content -Raw 'C:\Users\Public\eai-setup-e2e-executable.txt').Trim()
(Get-FileHash -Algorithm SHA256 $executable).Hash.ToLowerInvariant()
POWERSHELL
)"
[[ "$executable_hash" =~ ^[0-9a-f]{64}$ ]] || guest_test_fail "The released Windows executable hash could not be recorded."
stage native-installer-passed

stage uac-admin-consent-suppression-arm
arm_temporary_admin_consent_suppression \
  || guest_test_fail "The temporary no-prompt administrator consent policy could not be safely armed."
stage uac-admin-consent-suppression-armed

stage normal-app-launch
start_prerequisite_uac_watcher
prerequisite_uac_watcher_alive \
  || guest_test_fail "The exact-window Windows unexpected-consent-UI watcher did not start."
launch_guest_app_detached normal "" "$executable_hash" \
  || guest_test_fail "Explorer did not complete the bounded detached normal-app launch."
validate_guest_app_launch "$guest_normal_pid" "$guest_normal_launch_receipt" "$guest_normal_launch_arm" \
  "$normal_launch_nonce" normal "$executable_hash" "$normal_bootstrap_hash" \
  || guest_test_fail "The detached normal-app launch receipt or process tuple is invalid."
preserve_detached_launch_evidence normal \
  || guest_test_fail "The detached normal-app launch evidence could not be preserved."
normal_started=0
normal_start_deadline=$((SECONDS + 330))
while (( SECONDS < normal_start_deadline )); do
  if guest_process_alive "$guest_normal_pid"; then
    normal_started=1
    break
  else
    process_state=$?
    [[ "$process_state" == 1 ]] \
      || guest_test_fail "The read-only normal-app liveness check could not determine process state."
  fi
  prerequisite_uac_watcher_alive || break
  sleep 1
done
[[ "$normal_started" == 1 ]] || guest_test_fail "The normal released Windows app process did not start."

stage prerequisite-install
versions=""
ready_reads=0
liveness_failures=0
prerequisite_deadline=$((SECONDS + 1200))
prerequisite_progress_at=$SECONDS
while (( SECONDS < prerequisite_deadline )); do
  prerequisite_uac_watcher_alive \
    || guest_test_fail "Unexpected Windows consent UI appeared while the no-prompt policy was active."
  if guest_process_alive "$guest_normal_pid"; then
    liveness_failures=0
  else
    process_state=$?
    [[ "$process_state" == 1 ]] \
      || guest_test_fail "The read-only normal-app liveness check could not determine process state."
    liveness_failures=$((liveness_failures + 1))
    [[ "$liveness_failures" -lt 5 ]] || guest_test_fail "The released Windows app exited before prerequisite installation completed."
  fi
  versions="$(guest_versions_json || true)"
  if [[ -n "$versions" ]] \
    && versions_satisfy_contract "$versions" \
    && screen_has "Sign in" \
    && screen_has "Prerequisites installed successfully"; then
    ready_reads=$((ready_reads + 1))
    [[ "$ready_reads" -ge 2 ]] && break
  else
    ready_reads=0
  fi
  if (( SECONDS - prerequisite_progress_at >= 60 )); then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" prerequisite-install-still-running
    prerequisite_progress_at=$SECONDS
  fi
  sleep 5
done
[[ "$ready_reads" -ge 2 ]] || guest_test_fail "The Windows installer did not reach stable prerequisite readiness within 20 minutes."
stop_prerequisite_uac_watcher \
  || guest_test_fail "The Windows unexpected-consent-UI watcher did not close cleanly."
stage prerequisite-install-passed

stage uac-admin-consent-restoration
restore_admin_consent_prompt \
  || guest_test_fail "The Windows administrator consent policy could not be restored and verified."
stage uac-admin-consent-restoration-passed

stage normal-app-stop
stop_guest_process "$guest_normal_pid" \
  || guest_test_fail "The adapter could not stop and verify the exact normal EAI Setup process."
if guest_process_alive "$guest_normal_pid"; then
  guest_test_fail "The normal Windows app did not stop before CLI login."
else
  process_state=$?
  [[ "$process_state" == 1 ]] \
    || guest_test_fail "The read-only normal-app stop verification could not determine process state."
fi
cleanup_detached_guest_app normal \
  || guest_test_fail "The detached normal-app launch artifacts could not be safely removed."

stage cli-login
EAI_WINDOWS_VM_NAME="$vm_name" "$ROOT/scripts/login-windows-guest.sh" --cli-only \
  || guest_test_fail "The EAI CLI browser login or tenant verification failed in the Windows guest."
stage cli-login-passed

second_executable_hash="$(guest_ps_readonly <<'POWERSHELL' | tr -d '\r' | tail -n 1
$executable = (Get-Content -Raw 'C:\Users\Public\eai-setup-e2e-executable.txt').Trim()
(Get-FileHash -Algorithm SHA256 $executable).Hash.ToLowerInvariant()
POWERSHELL
)"
[[ "$second_executable_hash" == "$executable_hash" ]] \
  || guest_test_fail "The released Windows executable changed between the prerequisite and E2E launches."

stage remote-cleanup-arm
arm_windows_remote_cleanup \
  || guest_test_fail "The conservative exact-name Windows remote-cleanup checkpoint could not be armed."
stage remote-cleanup-armed

stage e2e-app-launch
guest_ps <<'POWERSHELL'
Remove-Item -Force 'C:\Users\Public\eai-setup-e2e-receipt.json' -ErrorAction SilentlyContinue
POWERSHELL
e2e_stdin="${EAI_HARNESS_TENANT_ID}"$'\n'"${EAI_VM_PROJECT_NAME}"
launch_guest_app_detached e2e "$e2e_stdin" "$executable_hash" \
  || guest_test_fail "The protected bounded E2E bootstrap did not complete its detached launch."
unset e2e_stdin
validate_guest_app_launch "$guest_e2e_pid" "$guest_e2e_launch_receipt" "$guest_e2e_launch_arm" \
  "$e2e_launch_nonce" e2e "$executable_hash" "$e2e_bootstrap_hash" \
  || guest_test_fail "The detached E2E bootstrap receipt or process tuple is invalid."
preserve_detached_launch_evidence e2e \
  || guest_test_fail "The detached E2E launch evidence could not be preserved."
e2e_started=0
e2e_start_deadline=$((SECONDS + 330))
while (( SECONDS < e2e_start_deadline )); do
  if guest_process_alive "$guest_e2e_pid"; then
    e2e_started=1
    break
  else
    process_state=$?
    [[ "$process_state" == 1 ]] \
      || guest_test_fail "The read-only E2E-app liveness check could not determine process state."
  fi
  sleep 1
done
[[ "$e2e_started" == 1 ]] || guest_test_fail "The Windows E2E app process did not start."

receipt_ready=0
liveness_failures=0
for attempt in $(seq 1 240); do
  receipt_probe=""
  receipt_probe_status=0
  if receipt_probe="$(guest_ps_readonly_run "$EAI_VM_PROJECT_NAME"$'\n' 2 2>/dev/null <<'POWERSHELL'
$expectedAppName = [Console]::In.ReadLine()
$receiptPath = 'C:\Users\Public\eai-setup-e2e-receipt.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
try { $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json } catch { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
if ($receipt.status -notin @('passed', 'failed')) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
if ($receipt.message -isnot [string]) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
if ($receipt.appCreated -isnot [bool]) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
if (-not $receipt.checks) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
$requiredChecks = @('prerequisites', 'authentication', 'tenant', 'app', 'project', 'aiHandoff')
foreach ($check in $requiredChecks) {
  if ($receipt.checks.PSObject.Properties.Name -notcontains $check) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
  if ($receipt.checks.$check -notin @('passed', 'failed', 'not-run')) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
}
# The released receipt schema does not duplicate the project name. Bind the
# parsed passed receipt to the exact requested app through its generated
# package, then repeat that proof independently on the host below.
if ($receipt.status -eq 'passed') {
  if ($receipt.appCreated -ne $true) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
  foreach ($check in $requiredChecks) {
    if ($receipt.checks.$check -ne 'passed') { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
  }
  $projectPath = Join-Path 'C:\Users\Public\EAIReleaseTests' $expectedAppName
  $packagePath = Join-Path $projectPath 'package.json'
  if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
  try { $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json } catch { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
  if ($package.name -cne "@eai-tools/$expectedAppName") { Write-Output 'EAI_E2E_RECEIPT_NOT_READY'; return }
}
Write-Output 'EAI_E2E_RECEIPT_READY'
POWERSHELL
  )"; then
    receipt_probe_status=0
  else
    receipt_probe_status=$?
  fi
  [[ "$receipt_probe_status" == 0 ]] \
    || guest_test_fail "The read-only Windows E2E receipt probe transport failed."
  receipt_probe="$(printf '%s' "$receipt_probe" | /usr/bin/tr -d '\r')"
  case "$receipt_probe" in
    EAI_E2E_RECEIPT_READY)
      receipt_ready=1
      break
      ;;
    EAI_E2E_RECEIPT_NOT_READY)
      ;;
    *)
      guest_test_fail "The read-only Windows E2E receipt probe returned an invalid state."
      ;;
  esac
  if guest_process_alive "$guest_e2e_pid"; then
    liveness_failures=0
  else
    process_state=$?
    [[ "$process_state" == 1 ]] \
      || guest_test_fail "The read-only E2E-app liveness check could not determine process state."
    liveness_failures=$((liveness_failures + 1))
    [[ "$liveness_failures" -lt 5 ]] || guest_test_fail "The Windows E2E app exited before writing its receipt."
  fi
  if (( attempt % 12 == 0 )); then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" e2e-flow-still-running
  fi
  sleep 5
done
[[ "$receipt_ready" == 1 ]] || guest_test_fail "The Windows desktop E2E receipt was not produced within 20 minutes."

stage receipt-validation
guest_ps_readonly >"$host_receipt" <<'POWERSHELL'
Get-Content -Raw 'C:\Users\Public\eai-setup-e2e-receipt.json'
POWERSHELL
EAI_RECEIPT_PATH="$host_receipt" EAI_EXPECTED_APP_NAME="$EAI_VM_PROJECT_NAME" node --input-type=module <<'NODE'
import fs from "node:fs";

const receipt = JSON.parse(fs.readFileSync(process.env.EAI_RECEIPT_PATH, "utf8"));
const requiredChecks = ["prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
if (!receipt || typeof receipt !== "object" || !["passed", "failed"].includes(receipt.status)) {
  throw new Error("The Windows desktop receipt has an invalid status schema.");
}
if (typeof receipt.message !== "string" || typeof receipt.appCreated !== "boolean" || !receipt.checks || typeof receipt.checks !== "object") {
  throw new Error("The Windows desktop receipt is missing required typed fields.");
}
for (const check of requiredChecks) {
  if (!["passed", "failed", "not-run"].includes(receipt.checks[check])) {
    throw new Error(`The Windows desktop receipt has an invalid ${check} check.`);
  }
}
if (receipt.status !== "passed" || receipt.appCreated !== true || requiredChecks.some((check) => receipt.checks[check] !== "passed")) {
  throw new Error(`The Windows desktop E2E flow reported failure for ${process.env.EAI_EXPECTED_APP_NAME}.`);
}
NODE
stage receipt-validation-passed

stage exact-project-validation
project_verification="$work_dir/windows-project-verification.json"
guest_ps_readonly_run "$EAI_VM_PROJECT_NAME"$'\n' <<'POWERSHELL' | tr -d '\r' | tail -n 1 >"$project_verification"
$ErrorActionPreference = 'Stop'
$expectedAppName = [Console]::In.ReadLine()
$expectedPath = [IO.Path]::GetFullPath((Join-Path 'C:\Users\Public\EAIReleaseTests' $expectedAppName))
$project = Get-Item -LiteralPath $expectedPath -ErrorAction Stop
if (-not $project.PSIsContainer) { throw 'The exact E2E project path is not a directory.' }
if (($project.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The exact E2E project path is a reparse point.' }
if (-not [string]::Equals($project.FullName, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The E2E project resolved to an unexpected path.'
}
$packagePath = Join-Path $project.FullName 'package.json'
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw 'The exact E2E project has no package.json.' }
$package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
if ($package.name -cne "@eai-tools/$expectedAppName") { throw 'The generated package.json names a different project.' }
$scriptCount = @($package.scripts.PSObject.Properties).Count
$dependencyCount = @($package.dependencies.PSObject.Properties).Count
$devDependencyCount = @($package.devDependencies.PSObject.Properties).Count
if ($scriptCount -eq 0 -or $dependencyCount -eq 0) { throw 'The generated project has no usable scripts or dependencies.' }
[ordered]@{
  status = 'verified'
  appName = $expectedAppName
  projectPath = $project.FullName
  packageName = [string]$package.name
  packageJsonSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagePath).Hash.ToLowerInvariant()
  scriptCount = $scriptCount
  dependencyCount = $dependencyCount
  devDependencyCount = $devDependencyCount
} | ConvertTo-Json -Compress
POWERSHELL
EAI_PROJECT_VERIFICATION="$project_verification" EAI_EXPECTED_APP_NAME="$EAI_VM_PROJECT_NAME" node --input-type=module <<'NODE'
import fs from "node:fs";

const proof = JSON.parse(fs.readFileSync(process.env.EAI_PROJECT_VERIFICATION, "utf8"));
const expectedPackageName = `@eai-tools/${process.env.EAI_EXPECTED_APP_NAME}`;
if (proof.status !== "verified" || proof.appName !== process.env.EAI_EXPECTED_APP_NAME || proof.packageName !== expectedPackageName) {
  throw new Error("The exact Windows project/package proof does not match the requested app.");
}
if (!/^[0-9a-f]{64}$/.test(proof.packageJsonSha256 || "")) {
  throw new Error("The Windows package.json hash is invalid.");
}
if (!Number.isInteger(proof.scriptCount) || proof.scriptCount < 1
  || !Number.isInteger(proof.dependencyCount) || proof.dependencyCount < 1
  || !Number.isInteger(proof.devDependencyCount) || proof.devDependencyCount < 0) {
  throw new Error("The Windows generated project does not contain usable scripts and dependencies.");
}
NODE
/bin/cp "$project_verification" "$(dirname "$EAI_VM_RESULT_FILE")/windows-project-verification.json"
export EAI_VM_PROJECT_VERIFIED=1
stage exact-project-validation-passed

stage ai-handoff-process-validation
code_process_id=""
code_process_probe=""
code_process_probe_status=0
for _ in $(seq 1 60); do
  if code_process_probe="$(windows_ai_handoff_process_query)"; then
    code_process_probe_status=0
  else
    code_process_probe_status=$?
  fi
  [[ "$code_process_probe_status" == 0 ]] \
    || guest_test_fail "The fixed read-only Windows AI handoff process query failed."
  case "$code_process_probe" in
    EAI_AI_HANDOFF_PROCESS_NOT_READY)
      sleep 2
      ;;
    EAI_AI_HANDOFF_PROCESS_READY:*)
      code_process_id="${code_process_probe#EAI_AI_HANDOFF_PROCESS_READY:}"
      break
      ;;
    *)
      guest_test_fail "The fixed read-only Windows AI handoff process query returned an invalid state."
      ;;
  esac
done
[[ "$code_process_id" =~ ^[1-9][0-9]*$ ]] \
  || guest_test_fail "The expected VS Code process did not appear in the Windows interactive session."

# The completed CLI callback may still be visible in Edge. Close that browser,
# prove it exited, then foreground the product-opened VS Code window by its
# already verified process ID before collecting private screenshot evidence.
guest_ps <<'POWERSHELL'
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
POWERSHELL
edge_stopped=0
for _ in $(seq 1 30); do
  if guest_ps >/dev/null 2>&1 <<'POWERSHELL'; then
if (Get-Process msedge -ErrorAction SilentlyContinue) { exit 1 }
POWERSHELL
    edge_stopped=1
    break
  fi
  sleep 1
done
[[ "$edge_stopped" == 1 ]] \
  || guest_test_fail "Edge still owned the callback window before Windows handoff evidence capture."
handoff_candidate="$work_dir/windows-ai-handoff.png"
handoff_screenshot="$(dirname "$EAI_VM_RESULT_FILE")/windows-ai-handoff.png"
handoff_capture_ready=0
handoff_capture_seen=0
handoff_project_seen=0
handoff_chat_seen=0
# shellcheck disable=SC2034 # The named counter documents this bounded evidence attempt.
for handoff_capture_attempt in $(seq 1 10); do
  # Focus is the only replayed action in this loop. It is idempotent and does
  # not repeat the product handoff, login, app creation, or any remote mutation.
  # Re-query the exact single VS Code window before every attempt so a recycled
  # PID or replacement process can never inherit the original proof.
  code_process_probe=""
  code_process_probe_status=0
  if code_process_probe="$(windows_ai_handoff_process_query)"; then
    code_process_probe_status=0
  else
    code_process_probe_status=$?
  fi
  [[ "$code_process_probe_status" == 0 ]] \
    || guest_test_fail "The fixed read-only Windows AI handoff process query failed during evidence capture."
  [[ "$code_process_probe" == "EAI_AI_HANDOFF_PROCESS_READY:$code_process_id" ]] \
    || guest_test_fail "The product-opened VS Code process changed during Windows handoff evidence capture."

  if ! guest_ps_run "$code_process_id"$'\n' >/dev/null 2>&1 <<'POWERSHELL'; then
$ErrorActionPreference = 'Stop'
$processId = [int][Console]::In.ReadLine()
$expected = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))
$session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
$process = Get-Process -Id $processId -ErrorAction Stop
if ($process.SessionId -ne $session -or
    -not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase) -or
    $process.MainWindowHandle -eq [IntPtr]::Zero) {
  throw 'The verified VS Code process has no exact foregroundable window.'
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EaiReleaseAiWindowFocus {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
$window = $process.MainWindowHandle
$shell = New-Object -ComObject WScript.Shell
[void]$shell.AppActivate($processId)
[void][EaiReleaseAiWindowFocus]::ShowWindowAsync($window, 9)
[void][EaiReleaseAiWindowFocus]::SetForegroundWindow($window)
for ($poll = 0; $poll -lt 30 -and [EaiReleaseAiWindowFocus]::GetForegroundWindow() -ne $window; $poll++) {
  Start-Sleep -Milliseconds 100
}
if ([EaiReleaseAiWindowFocus]::GetForegroundWindow() -ne $window) {
  throw 'The exact VS Code window could not be proven in the foreground.'
}
POWERSHELL
    sleep 2
    continue
  fi
  sleep 2
  guest_ps_readonly_run "$code_process_id"$'\n' >/dev/null <<'POWERSHELL' \
    || guest_test_fail "The product-opened VS Code process changed before Windows handoff evidence capture."
$processId = [int][Console]::In.ReadLine()
$expected = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))
$session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
$process = Get-Process -Id $processId -ErrorAction Stop
if ($process.SessionId -ne $session -or
    -not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase) -or
    $process.MainWindowHandle -eq [IntPtr]::Zero) { exit 1 }
POWERSHELL
  rm -f "$handoff_candidate"
  if ! prlctl capture "$vm_name" --file "$handoff_candidate" >/dev/null 2>&1; then
    sleep 2
    continue
  fi
  handoff_capture_seen=1

  # Reject a protected frame immediately, before deciding whether its public
  # project/chat text is complete enough to retain as evidence.
  for protected_pattern in \
    "$EAI_HARNESS_USER_EMAIL" "$EAI_HARNESS_TENANT_ID" "$EAI_HARNESS_TENANT_NAME" \
    'localhost' '?code=' 'code=' 'code =' 'access_token' 'refresh_token' \
    'client_info' 'session_state' 'Authentication complete' 'successfully authenticated'; do
    if EAI_OCR_PATTERN="$protected_pattern" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
      "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1; then
      guest_test_fail "The Windows handoff screenshot contains protected or callback data."
    fi
  done

  handoff_project_seen=0
  handoff_chat_seen=0
  if EAI_OCR_PATTERN="$EAI_VM_PROJECT_NAME" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
    "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1; then
    handoff_project_seen=1
  fi
  if EAI_OCR_PATTERN="Build with Agent" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
    "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1; then
    handoff_chat_seen=1
  fi
  if [[ "$handoff_project_seen" == 1 && "$handoff_chat_seen" == 1 ]]; then
    handoff_capture_ready=1
    break
  fi
  sleep 2
done
[[ "$handoff_capture_seen" == 1 ]] \
  || guest_test_fail "The Windows AI handoff screenshot could not be captured after bounded retries."
[[ "$handoff_capture_ready" == 1 ]] \
  || guest_test_fail "The Windows handoff screenshot did not converge on the exact generated project and AI chat surface."
/usr/bin/ditto "$handoff_candidate" "$handoff_screenshot" \
  || guest_test_fail "The sanitized Windows AI handoff screenshot could not be preserved."
handoff_hash="$(/usr/bin/shasum -a 256 "$handoff_screenshot" | /usr/bin/awk '{print $1}')"
EAI_HANDOFF_SCREENSHOT_HASH="$handoff_hash" EAI_HANDOFF_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/windows-ai-handoff-evidence.json" \
EAI_HANDOFF_PROCESS_ID="$code_process_id" \
  node --input-type=module - "$EAI_VM_PROJECT_NAME" <<'NODE'
import fs from "node:fs";

const appName = process.argv[2];
const evidence = {
  platform: "windows",
  appName,
  projectPath: `C:\\Users\\Public\\EAIReleaseTests\\${appName}`,
  surfaceId: "vscode-copilot",
  handoffReceiptPassed: true,
  processVerified: true,
  processOwner: "expected-interactive-user",
  processId: Number(process.env.EAI_HANDOFF_PROCESS_ID),
  processMatch: "%ProgramFiles%\\Microsoft VS Code\\Code.exe",
  verifiedAt: new Date().toISOString(),
  screenshot: {
    path: "windows-ai-handoff.png",
    sha256: process.env.EAI_HANDOFF_SCREENSHOT_HASH,
    visualReview: "automated-protected-content-check-passed",
    showsExactProject: true,
    showsChatSurface: true,
    showsProviderAuthenticated: false,
    automatedProtectedContentCheckPassed: true,
  },
  sanitized: true,
  diagnostic: true,
  productionGate: false,
};
fs.writeFileSync(process.env.EAI_HANDOFF_EVIDENCE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
export EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1
export EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1

stage e2e-app-stop
stop_guest_process "$guest_e2e_pid" \
  || guest_test_fail "The adapter could not stop and verify the exact E2E EAI Setup process."
if guest_process_alive "$guest_e2e_pid"; then
  guest_test_fail "The E2E Windows app did not stop after evidence capture."
else
  process_state=$?
  [[ "$process_state" == 1 ]] \
    || guest_test_fail "The read-only E2E-app stop verification could not determine process state."
fi
cleanup_detached_guest_app e2e \
  || guest_test_fail "The detached E2E launch artifacts could not be safely removed."
stage e2e-app-stop-passed

export EAI_VM_INSTALLER_VERIFIED=1
export EAI_VM_PREREQUISITES_PROVEN=1
export EAI_VM_EXECUTABLE_SHA256="$executable_hash"
export EAI_VM_PREREQUISITES_BEFORE="$before_versions"
export EAI_VM_DEFENDER_EXACT_FILE_ADDED="$defender_exclusion_added"
export EAI_VM_DEFENDER_EXACT_FILE_REMOVED="$defender_exclusion_removed"
export EAI_VM_UAC_POLICY_RUN_BINDING="$uac_policy_run_binding"
guest_test_finalize windows "$guest_parent\\$EAI_VM_PROJECT_NAME" "$host_receipt" \
  "$host_hash" "$guest_hash" "$versions"
completed=1
stage windows-e2e-passed
