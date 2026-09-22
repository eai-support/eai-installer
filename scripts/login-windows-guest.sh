#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/windows-hidden-current-user.sh
source "$ROOT/scripts/windows-hidden-current-user.sh"
vm_name="${EAI_WINDOWS_VM_NAME:-Windows 11}"
login_url="${EAI_HARNESS_LOGIN_URL:-https://www.enterpriseaigroup.com/sign-in}"
tenant_name="${EAI_HARNESS_TENANT_NAME:-}"
tenant_id="${EAI_HARNESS_TENANT_ID:-}"
test_email="${EAI_HARNESS_USER_EMAIL:-}"
keychain_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
input_helper="$ROOT/scripts/parallels-input.mjs"
ui_helper="$ROOT/scripts/windows-ui-action.ps1"
mode="both"

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'Windows guest login failed: %s\n' "$*" >&2
  exit 1
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

is_parallels_exact_job_result_failure() {
  local normalized=""
  local line=""
  local count=0
  normalized="$(printf '%s' "$1" | /usr/bin/tr -d '\r')"
  while IFS= read -r line; do
    case "$line" in
      'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.'|\
      'PrlJob_GetResult: Invalid argument. An invalid argument was passed.')
        ;;
      *)
        return 1
        ;;
    esac
    count=$((count + 1))
    [[ "$count" -le 3 ]] || return 1
  done <<<"$normalized"
  [[ "$count" -ge 1 ]]
}

[[ -n "$tenant_name" ]] || fail "EAI_HARNESS_TENANT_NAME is required."
[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] \
  || fail "EAI_HARNESS_TENANT_ID must be a tenant UUID."
[[ -n "$test_email" && "$test_email" != *[[:space:]]* ]] \
  || fail "EAI_HARNESS_USER_EMAIL is required."
[[ "$login_url" == "https://www.enterpriseaigroup.com/sign-in" ]] \
  || fail "EAI_HARNESS_LOGIN_URL must be the supported Enterprise AI Group sign-in page."
command -v prlctl >/dev/null 2>&1 || fail "prlctl is not installed."
command -v node >/dev/null 2>&1 || fail "Node.js is not installed on the host."
command -v security >/dev/null 2>&1 || fail "The macOS Keychain command is unavailable."
[[ -f "$input_helper" ]] || fail "The Parallels input helper is missing."
[[ -f "$ui_helper" ]] || fail "The protected Windows UI Automation helper is missing."
prlctl status "$vm_name" >/dev/null 2>&1 || fail "The configured Windows VM does not exist."

case "${1:-}" in
  "")
    [[ "$#" == 0 ]] || fail "Unknown argument."
    ;;
  --preflight)
    [[ "$#" == 1 ]] || fail "--preflight does not accept additional arguments."
    mode="preflight"
    ;;
  --portal-only)
    [[ "$#" == 1 ]] || fail "--portal-only does not accept additional arguments."
    mode="portal"
    ;;
  --cli-only)
    [[ "$#" == 1 ]] || fail "--cli-only does not accept additional arguments."
    mode="cli"
    ;;
  *)
    fail "Unknown argument. Use --preflight, --portal-only, or --cli-only."
    ;;
esac

# Read only the Keychain item's account metadata, without `-w` or `-g`, and
# compare it in shell memory. The protected email is never placed in argv.
stored_account="$(
  /usr/bin/security find-generic-password -s "$keychain_service" 2>/dev/null \
    | /usr/bin/awk -F '"' '$2 == "acct" { print $4; exit }'
)"
[[ "$stored_account" == "$test_email" ]] \
  || fail "The EAI release-test Keychain item is missing or belongs to a different account."
unset stored_account

[[ "$mode" == preflight ]] && exit 0

input() {
  node "$input_helper" --vm "$vm_name" "$@"
}

run_guest_powershell() {
  local script=""
  script="$(/bin/cat)"
  [[ -n "$script" ]] || fail "The Windows PowerShell command was empty."
  local output=""
  local status=1
  # Snapshot boot, Edge shutdown, and a just-finished UI Automation command can
  # each leave Parallels briefly unable to open the next current-user session.
  # Retry only those two transport errors; real PowerShell/UI failures remain
  # one-shot and retain their diagnostic output.
  for _ in $(seq 1 120); do
    set +e
    # Feed one coherent script block. Without the wrapper, Windows
    # PowerShell's `-Command -` interactive parser can execute only the first
    # complete statement before returning to its stdin prompt.
    output="$(printf '%s\n' "$script" | windows_hidden_current_user_ps "$vm_name" "" 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if is_parallels_session_open_failure "$output"; then
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

run_guest_powershell_readonly() {
  local script=""
  local output=""
  local status=1
  local attempt
  script="$(/bin/cat)"
  [[ -n "$script" ]] || fail "The read-only Windows PowerShell command was empty."
  for attempt in $(seq 1 3); do
    set +e
    output="$(printf '%s' "$script" | run_guest_powershell 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ "$status" == 255 ]] \
      && is_parallels_exact_job_result_failure "$output" \
      && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

run_ui_action_once() {
  local action="$1"
  local timeout_seconds="$2"
  local output=""
  local status=1
  case "$action" in
    edge-first-run|invoke-public-email|invoke-portal-microsoft|focus-email|invoke-next|focus-password|invoke-sign-in|invoke-edge-not-now|invoke-ms-yes|probe-portal-ready|wait-portal-ready)
      ;;
    *)
      fail "Unsupported Windows UI action."
      ;;
  esac
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] \
    || (( timeout_seconds < 1 || timeout_seconds > 300 )); then
    fail "Windows UI action timeout must be between 1 and 300 seconds."
  fi
  set +e
  output="$({
    /bin/cat "$ui_helper"
    printf "\nInvoke-WindowsUiAction -Action '%s' -TimeoutSeconds %d\n" "$action" "$timeout_seconds"
  } | run_guest_powershell 2>&1)"
  status=$?
  set -e
  if [[ "$status" == 0 ]]; then
    printf '%s\n' "$output"
    return 0
  fi
  printf '%s\n' "$output" >&2
  return "$status"
}

run_idempotent_ui_action() {
  local action="$1"
  local timeout_seconds="$2"
  local output=""
  local status=1
  local attempt
  case "$action" in
    edge-first-run|focus-email|focus-password)
      ;;
    *)
      fail "Unsupported idempotent Windows UI action."
      ;;
  esac
  for attempt in $(seq 1 3); do
    set +e
    output="$(run_ui_action_once "$action" "$timeout_seconds" 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ "$status" == 255 ]] \
      && is_parallels_exact_job_result_failure "$output" \
      && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

run_readonly_ui_action() {
  local action="$1"
  local timeout_seconds="$2"
  local output=""
  local status=1
  local attempt
  [[ "$action" == probe-portal-ready || "$action" == wait-portal-ready ]] \
    || fail "Only the portal-readiness action may use the read-only UI retry."
  for attempt in $(seq 1 3); do
    set +e
    output="$(run_ui_action_once "$action" "$timeout_seconds" 2>&1)"
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ "$status" == 255 ]] \
      && is_parallels_exact_job_result_failure "$output" \
      && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  done
  printf '%s\n' "$output" >&2
  return "$status"
}

launch_edge() {
  local output=""
  if ! output="$(run_guest_powershell 2>&1 <<'POWERSHELL'
$ErrorActionPreference = "Stop"
$edgeCandidates = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
$edge = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) {
    $edge = (Get-Command "msedge.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
if (-not $edge) {
    throw "Microsoft Edge was not found."
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($identity.IsSystem -or $sessionId -le 0) {
    throw "Edge must be launched by the signed-in interactive user."
}
$startupClass = $null
$startup = $null
$processClass = $null
$result = $null
$process = $null
$environmentValues = $null
try {
    # An Explorer-launched child remains in the monitored Parallels guest-exec
    # job and is terminated when the control request returns. Local legacy WMI
    # brokers the browser outside that lineage with the same user/session.
    $startupClass = [wmiclass]'\\.\root\cimv2:Win32_ProcessStartup'
    $startup = $startupClass.CreateInstance()
    $startup.WinstationDesktop = 'winsta0\default'
    $startup.CreateFlags = [uint32]1536
    $environment = [Collections.Generic.List[string]]::new()
    foreach ($entry in [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).GetEnumerator()) {
        $name = [string]$entry.Key
        $value = [string]$entry.Value
        if (-not $name -or $name.IndexOf([char]'=') -ge 0 -or
            $name.IndexOf([char]0) -ge 0 -or $value.IndexOf([char]0) -ge 0) {
            throw "The current-user browser environment contains an invalid name or value."
        }
        if ($name.StartsWith('EAI_', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $environment.Add(('{0}={1}' -f $name, $value))
    }
    $environmentValues = [string[]]$environment.ToArray()
    $startup.EnvironmentVariables = $environmentValues
    $processClass = [wmiclass]'\\.\root\cimv2:Win32_Process'
    $commandLine = '"' + $edge + '" --force-renderer-accessibility --no-first-run --disable-features=msEdgeFirstRunExperience --new-window https://www.enterpriseaigroup.com/sign-in'
    $result = $processClass.Create($commandLine, (Split-Path -Parent $edge), $startup)
    if ([int]$result.ReturnValue -ne 0 -or [int]$result.ProcessId -le 0) {
        throw "The local WMI Edge launch failed."
    }
    $process = Get-Process -Id ([int]$result.ProcessId) -ErrorAction Stop
    [void]$process.Handle
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
    $ownerSid = Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop
    if ($process.HasExited -or $process.SessionId -ne $sessionId -or
        -not [string]::Equals($process.Path, $edge, [StringComparison]::OrdinalIgnoreCase) -or
        $ownerSid.ReturnValue -ne 0 -or $ownerSid.Sid -cne $identity.User.Value -or
        [string]$cim.CommandLine -cne $commandLine) {
        throw "The local WMI Edge process did not match its exact user/session/path/command-line binding."
    }
    [Console]::Out.WriteLine("EDGE_LOCAL_WMI_LAUNCH_READY")
} finally {
    if ($null -ne $process) { $process.Dispose() }
    if ($null -ne $result) { $result.Dispose() }
    if ($null -ne $startup) { $startup.Dispose() }
    if ($null -ne $startupClass) { $startupClass.Dispose() }
    if ($null -ne $processClass) { $processClass.Dispose() }
    if ($null -ne $environmentValues) { [Array]::Clear($environmentValues, 0, $environmentValues.Length) }
}
POWERSHELL
  )"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output" | /usr/bin/tr -d '\r' \
    | /usr/bin/grep -Fqx 'EDGE_LOCAL_WMI_LAUNCH_READY'
}

reset_edge_profile() {
  run_guest_powershell <<'POWERSHELL'
$ErrorActionPreference = "Stop"
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$profileRoot = Join-Path $localAppData "Microsoft\Edge\User Data"
$expectedRoot = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
if ($profileRoot -cne $expectedRoot) { throw "The Edge profile path is not the approved current-user path." }
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
for ($attempt = 0; $attempt -lt 40 -and (Get-Process msedge -ErrorAction SilentlyContinue); $attempt += 1) {
    Start-Sleep -Milliseconds 250
}
if (Get-Process msedge -ErrorAction SilentlyContinue) { throw "Edge did not stop before its disposable profile reset." }
if (Test-Path -LiteralPath $profileRoot) { Remove-Item -LiteralPath $profileRoot -Recurse -Force }
if (Test-Path -LiteralPath $profileRoot) { throw "The disposable Edge profile could not be reset." }
[Console]::Out.WriteLine("DISPOSABLE_EDGE_PROFILE_READY")
POWERSHELL
}

wait_enterprise_portal_https() {
  run_guest_powershell_readonly <<'POWERSHELL'
$ErrorActionPreference = "Stop"
$approvedUri = [Uri]"https://www.enterpriseaigroup.com/sign-in"
$curl = Get-Command "curl.exe" -ErrorAction Stop | Select-Object -First 1
$deadline = [DateTime]::UtcNow.AddSeconds(180)
do {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $probe = @(& $curl.Source --proto '=https' --tlsv1.2 --head --silent --show-error --connect-timeout 15 --max-time 30 --write-out "EAI_HTTP_STATUS=%{http_code}`nEAI_EFFECTIVE_URL=%{url_effective}`n" $approvedUri.AbsoluteUri 2>&1)
        $curlStatus = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $probeText = $probe -join "`n"
    $statusMatch = [regex]::Match($probeText, '(?m)^EAI_HTTP_STATUS=(\d{3})$')
    $urlMatch = [regex]::Match($probeText, '(?m)^EAI_EFFECTIVE_URL=(https://\S+)$')
    $finalUri = $null
    if ($urlMatch.Success) {
        [void][Uri]::TryCreate($urlMatch.Groups[1].Value, [UriKind]::Absolute, [ref]$finalUri)
    }
    if ($curlStatus -eq 0 -and
        $statusMatch.Success -and $statusMatch.Groups[1].Value -ceq "200" -and
        $null -ne $finalUri -and
        $finalUri.Scheme -ceq "https" -and
        $finalUri.Host -ieq $approvedUri.Host -and
        $finalUri.AbsolutePath.TrimEnd("/") -ieq $approvedUri.AbsolutePath.TrimEnd("/")) {
        [Console]::Out.WriteLine("ENTERPRISE_PORTAL_HTTPS_READY")
        return
    }
    # Azure Front Door can briefly return an unreachable edge address just
    # after a restored VM regains networking. Retry only this fixed public URL.
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
throw "The approved Enterprise AI sign-in endpoint did not become reachable."
POWERSHELL
}

portal_ready_state() {
  local output=""
  local ready_count=0
  local not_ready_count=0
  output="$(run_readonly_ui_action probe-portal-ready 5)" || return 2
  ready_count="$(printf '%s\n' "$output" | /usr/bin/tr -d '\r' | /usr/bin/grep -Fxc 'EAI_PORTAL_READY' || true)"
  not_ready_count="$(printf '%s\n' "$output" | /usr/bin/tr -d '\r' | /usr/bin/grep -Fxc 'EAI_PORTAL_NOT_READY' || true)"
  if [[ "$ready_count" == 1 && "$not_ready_count" == 0 ]]; then return 0; fi
  if [[ "$ready_count" == 0 && "$not_ready_count" == 1 ]]; then return 1; fi
  return 2
}

wait_portal_ready() {
  local timeout_seconds="${1:-5}"
  run_readonly_ui_action wait-portal-ready "$timeout_seconds" >/dev/null 2>&1
}

if [[ "$mode" != cli ]]; then
  status="$(prlctl status "$vm_name" 2>/dev/null || true)"
  [[ "$status" == *running* ]] \
    || fail "The Windows VM must already be running before browser login."
  actual_user="$(
    printf '%s\n' '[Security.Principal.WindowsIdentity]::GetCurrent().Name' | windows_hidden_current_user_ps "$vm_name" 2>/dev/null \
      | /usr/bin/tr -d '\r\n'
  )"
  actual_user_lower="$(printf '%s' "$actual_user" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ -n "$actual_user" && "$actual_user_lower" != *"system"* ]] \
    || fail "The Windows signed-in-user control channel is unavailable."
  unset actual_user actual_user_lower status

  reset_edge_profile >/dev/null \
    || fail "The disposable Windows Edge profile could not be reset safely."
  wait_enterprise_portal_https >/dev/null \
    || fail "The Enterprise AI Group sign-in endpoint was not reachable from the Windows guest."
  launch_edge \
    || fail "Microsoft Edge could not open the Enterprise AI Group sign-in page."
  if ! run_idempotent_ui_action edge-first-run 120 >/dev/null 2>&1; then
    run_ui_action_once invoke-public-email 30 >/dev/null \
      || fail "Microsoft Edge first-run setup could not be handled safely."
  fi

  portal_state_status=2
  if portal_ready_state; then
    fail "The replacement snapshot already has an authenticated portal session; a fresh protected login cannot be proven."
  else
    portal_state_status=$?
  fi
  [[ "$portal_state_status" == 1 ]] \
    || fail "The unauthenticated portal state could not be proven before protected login."
  unset portal_state_status

  run_ui_action_once invoke-public-email 90 >/dev/null \
    || fail "The public Continue with Email action did not become available."
  printf 'PUBLIC_SIGN_IN_HANDOFF_READY\n'

  run_ui_action_once invoke-portal-microsoft 90 >/dev/null \
    || fail "The portal Sign in with Microsoft action did not become available."
  printf 'PORTAL_MICROSOFT_HANDOFF_READY\n'

  run_idempotent_ui_action focus-email 60 >/dev/null \
    || fail "Microsoft's Email address field did not become available."
  # The email is supplied only to a shell builtin and streamed over stdin as
  # virtual key events after UI Automation has focused the exact field.
  printf '%s' "$test_email" | input type --stdin
  run_ui_action_once invoke-next 30 >/dev/null \
    || fail "Microsoft's Next action did not become available."
  printf 'MICROSOFT_EMAIL_STAGE_SUBMITTED\n'

  run_idempotent_ui_action focus-password 60 >/dev/null \
    || fail "Microsoft's Password field did not become available."

  # The password is read only at the exact action that needs it. Service-only
  # lookup is safe because preflight proved its single account label matches
  # EAI_HARNESS_USER_EMAIL. The value flows directly into virtual-key stdin.
  /usr/bin/security find-generic-password -s "$keychain_service" -w \
    | input type --stdin
  run_ui_action_once invoke-sign-in 30 >/dev/null \
    || fail "Microsoft's Sign in action did not become available."
  printf 'MICROSOFT_PASSWORD_STAGE_SUBMITTED\n'

  run_ui_action_once invoke-edge-not-now 10 >/dev/null \
    || fail "The Edge password-save prompt could not be handled safely."
  run_ui_action_once invoke-ms-yes 45 >/dev/null \
    || fail "Microsoft's stay-signed-in prompt could not be handled safely."
  wait_portal_ready 120 \
    || fail "The authenticated Enterprise AI portal did not become ready."
  printf 'FRESH_PROTECTED_LOGIN_PROVEN\n'
  printf 'AUTHENTICATED_PORTAL_READY\n'
  [[ "$mode" == portal ]] && exit 0
fi

cli_exists() {
  printf '%s\n' 'if (Test-Path -LiteralPath (Join-Path $env:APPDATA "npm\eai.cmd") -PathType Leaf) { exit 0 } else { exit 1 }' \
    | windows_hidden_current_user_ps "$vm_name" \
    >/dev/null 2>&1
}

cli_identity_is_active() {
  local identity=""
  local identity_lower=""
  local expected_email_lower=""
  expected_email_lower="$(printf '%s' "$test_email" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  identity="$(
    printf '%s\n' '& (Join-Path $env:APPDATA "npm\eai.cmd") whoami' \
      | windows_hidden_current_user_ps "$vm_name" 2>/dev/null \
      | /usr/bin/tr -d '\r'
  )" || return 1
  identity_lower="$(printf '%s' "$identity" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  identity=""
  [[ "$identity_lower" == *"$expected_email_lower"* \
    && "$identity_lower" =~ status[[:space:]:]+active ]]
}

cli_tenant_matches() {
  local tenant_json=""
  local match_status=1
  local output_status=1
  local attempt
  for attempt in $(seq 1 3); do
    set +e
    tenant_json="$(
      printf '%s\n' '& (Join-Path $env:APPDATA "npm\eai.cmd") tenant list --format json' \
        | windows_hidden_current_user_ps "$vm_name" 2>&1 \
        | /usr/bin/tr -d '\r'
    )"
    output_status=$?
    set -e
    if [[ "$output_status" == 255 ]] \
      && is_parallels_exact_job_result_failure "$tenant_json"; then
      tenant_json=""
      if [[ "$attempt" -lt 3 ]]; then
        sleep 2
        continue
      fi
      return 1
    fi
    if [[ "$output_status" != 0 ]]; then
      tenant_json=""
      return 1
    fi
    if printf '%s' "$tenant_json" \
      | EAI_EXPECTED_TENANT_ID="$tenant_id" EAI_EXPECTED_TENANT_NAME="$tenant_name" \
        node --input-type=module -e '
          import fs from "node:fs";
          const payload = JSON.parse(fs.readFileSync(0, "utf8"));
          const tenants = Array.isArray(payload) ? payload : payload.tenants;
          const matches = Array.isArray(tenants) ? tenants.filter((tenant) =>
            tenant.id === process.env.EAI_EXPECTED_TENANT_ID
            && tenant.displayName === process.env.EAI_EXPECTED_TENANT_NAME
            && tenant.directMembership === true
            && tenant.isActive !== false
          ) : [];
          if (matches.length !== 1) process.exitCode = 1;
        ' 2>/dev/null
    then
      match_status=0
    fi
    tenant_json=""
    [[ "$match_status" == 0 ]]
    return
  done
  return 1
}

cli_exists || fail "The exact EAI CLI path %APPDATA%\\npm\\eai.cmd is not installed."

# Cleanup and other follow-up diagnostics may run immediately after a complete
# E2E login. Reuse that session only when both the exact identity and exact
# active direct tenant membership are independently proven. A restored clean
# snapshot has no installed CLI/session, so the primary E2E path still performs
# and proves the fresh browser callback below.
if cli_identity_is_active && cli_tenant_matches; then
  printf 'AUTHENTICATED_PORTAL_AND_CLI_READY\n'
  exit 0
fi

# The CLI opens its localhost callback in the signed-in user's existing Edge
# session. Suppress its complete output so callback URLs and account metadata
# can never enter host logs.
printf '%s\n' '& (Join-Path $env:APPDATA "npm\eai.cmd") login' \
  | windows_hidden_current_user_ps "$vm_name" >/dev/null 2>&1 &
cli_pid=$!
cli_finished=0
cli_status=1
for _ in $(seq 1 660); do
  if ! kill -0 "$cli_pid" 2>/dev/null; then
    if wait "$cli_pid"; then cli_status=0; else cli_status=$?; fi
    cli_finished=1
    break
  fi
  sleep 0.5
done
if [[ "$cli_finished" == 0 ]]; then
  kill "$cli_pid" 2>/dev/null || true
  wait "$cli_pid" 2>/dev/null || true
fi
if [[ "$cli_finished" != 1 || "$cli_status" != 0 ]]; then
  # The callback process can report a transport/close error after the local
  # callback has already persisted a valid session. Accept only when both the
  # exact identity and configured direct tenant are independently readable;
  # otherwise retain the hard failure.
  if cli_identity_is_active && cli_tenant_matches; then
    printf 'AUTHENTICATED_PORTAL_AND_CLI_READY\n'
    exit 0
  fi
  fail "The EAI CLI browser callback did not complete."
fi

cli_authenticated=0
for _ in $(seq 1 20); do
  if cli_identity_is_active; then
    cli_authenticated=1
    break
  fi
  sleep 0.5
done
[[ "$cli_authenticated" == 1 ]] \
  || fail "The active EAI CLI identity could not be verified."
cli_tenant_matches \
  || fail "The configured harness tenant is not an active direct membership."
printf 'AUTHENTICATED_PORTAL_AND_CLI_READY\n'
