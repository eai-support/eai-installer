#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/windows-readonly-powershell.sh"

test_dir="$(mktemp -d)"
attempt_file="$test_dir/attempt"
sleep_log="$test_dir/sleeps"
payload_log="$test_dir/payload.ps1"
vm_name='fixture-windows'
fake_mode=""
expected_channel=""

cleanup() {
  rm -rf -- "$test_dir"
}
trap cleanup EXIT

fail() {
  printf 'Windows read-only PowerShell transport test failed: %s\n' "$*" >&2
  exit 1
}

write_powershell_payload_wrapper() {
  local stdin_payload="$1"
  local script="$2"
  local payload_base64=""
  payload_base64="$(printf '%s' "$stdin_payload" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  printf '%s\n' \
    '& {' \
    "\$__eaiHarnessInputValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload_base64'))" \
    '[Console]::SetIn([IO.StringReader]::new($__eaiHarnessInputValue))' \
    '$__eaiHarnessInputValue = $null' \
    "$script" \
    '}' \
    ''
}

# Keep this unit fixture focused on retry semantics. The production helper's
# hidden WScript transport and payload isolation are asserted separately by
# test-release.mjs; here it delegates to the fake prlctl channel below.
windows_hidden_current_user_ps() {
  local fixture_vm_name="$1"
  local stdin_payload="${2:-}"
  local script=""
  script="$(/bin/cat)"
  write_powershell_payload_wrapper "$stdin_payload" "$script" \
    | prlctl exec "$fixture_vm_name" --current-user powershell.exe \
      -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden \
      -InputFormat Text -OutputFormat Text -Command -
}

sleep() {
  printf '%s\n' "$1" >>"$sleep_log"
}

prlctl() {
  local args=" $* "
  local actual_channel=system
  local attempt=0
  /bin/cat >"$payload_log"
  [[ "$args" == *' --current-user '* ]] && actual_channel=current-user
  [[ "$actual_channel" == "$expected_channel" ]] || return 91
  if [[ "$actual_channel" == current-user ]]; then
    [[ "$args" == *' --current-user powershell.exe '* ]] || return 92
    [[ "$args" == *' -WindowStyle Hidden '* ]] || return 95
  else
    [[ "$args" == *' cmd.exe /D /S /C powershell.exe '* ]] || return 92
  fi
  [[ "$args" == *' -InputFormat Text -OutputFormat Text -Command - '* ]] || return 93
  attempt="$(/bin/cat "$attempt_file")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" >"$attempt_file"
  case "$fake_mode" in
    retcode-then-success)
      if [[ "$attempt" == 1 ]]; then
        printf 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      ;;
    result-then-success)
      if [[ "$attempt" == 1 ]]; then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      ;;
    duplicate-result-then-success)
      if [[ "$attempt" == 1 ]]; then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n%.0s' 1 2 >&2
        return 255
      fi
      ;;
    session-result-success)
      if [[ "$attempt" == 1 ]]; then
        printf 'PrlVmGuest_RunProgram: Invalid argument\n' >&2
        return 1
      elif [[ "$attempt" == 2 ]]; then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      ;;
    all-transient)
      printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
      return 255
      ;;
    extra-text)
      printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\nextra\n' >&2
      return 255
      ;;
    mixed-known-then-success)
      if [[ "$attempt" == 1 ]]; then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\nPrlJob_GetRetCode: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      ;;
    partial-text)
      printf 'PrlJob_GetResult: Invalid argument.\n' >&2
      return 255
      ;;
    wrong-status)
      printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
      return 42
      ;;
    powershell-error)
      printf 'fixture PowerShell error\n' >&2
      return 1
      ;;
    success)
      ;;
    *)
      return 94
      ;;
  esac
  printf 'READ_OK\n'
}

reset_fake() {
  fake_mode="$1"
  expected_channel="$2"
  printf '0\n' >"$attempt_file"
  : >"$sleep_log"
  : >"$payload_log"
}

run_site_fixture() {
  local site="$1"
  local channel="$2"
  local mode="$3"
  local output=""
  reset_fake "$mode" "$channel"
  if [[ "$channel" == current-user ]]; then
    if [[ "$site" == second-executable-hash || "$site" == final-receipt-fetch ]]; then
      output="$(guest_ps_readonly 2>"$test_dir/stderr" <<POWERSHELL
# $site
Write-Output 'fixture'
POWERSHELL
)"
    else
      output="$(guest_ps_readonly_run "fixture-value" 4 2>"$test_dir/stderr" <<POWERSHELL
# $site
Write-Output ([Console]::In.ReadLine())
POWERSHELL
)"
    fi
  else
    output="$(guest_system_ps_readonly_run "fixture-value" 4 2>"$test_dir/stderr" <<POWERSHELL
# $site
Write-Output ([Console]::In.ReadLine())
POWERSHELL
)"
  fi
  [[ "$output" == READ_OK ]] || fail "$site did not recover its exact transient read"
  [[ "$(/bin/cat "$attempt_file")" == 2 ]] || fail "$site did not use exactly one retry"
  [[ "$(/bin/cat "$sleep_log")" == 2 ]] || fail "$site used an unexpected retry delay"
}

sites=(
  validate-guest-app-launch
  second-executable-hash
  receipt-polling
  final-receipt-fetch
  exact-project-proof
  post-appactivate-liveness
  guest-process-alive
)
channels=(system current-user current-user current-user current-user current-user system)
for index in "${!sites[@]}"; do
  if (( index % 2 == 0 )); then
    fixture_mode=retcode-then-success
  else
    fixture_mode=result-then-success
  fi
  run_site_fixture "${sites[$index]}" "${channels[$index]}" "$fixture_mode"
done

run_site_fixture receipt-polling current-user duplicate-result-then-success
run_site_fixture receipt-polling current-user mixed-known-then-success

reset_fake session-result-success current-user
output="$(guest_ps_readonly_run fixture 4 2>"$test_dir/stderr" <<'POWERSHELL'
Write-Output ([Console]::In.ReadLine())
POWERSHELL
)"
[[ "$output" == READ_OK ]] || fail 'session-open and exact ambiguous retries did not compose'
[[ "$(/bin/cat "$attempt_file")" == 3 ]] || fail 'composed retry did not stop after success'
[[ "$(/bin/cat "$sleep_log")" == $'2\n2' ]] || fail 'composed retry delays changed'

reset_fake all-transient system
set +e
guest_system_ps_readonly >"$test_dir/stdout" 2>"$test_dir/stderr" <<'POWERSHELL'
Write-Output 'fixture'
POWERSHELL
status=$?
set -e
[[ "$status" == 255 ]] || fail 'an exhausted exact result failure changed status'
[[ "$(/bin/cat "$attempt_file")" == 3 ]] || fail 'an exact result failure exceeded three attempts'
[[ "$(/bin/cat "$sleep_log")" == $'2\n2' ]] || fail 'an exhausted retry used an unexpected delay'

for non_exact_mode in extra-text partial-text wrong-status powershell-error; do
  reset_fake "$non_exact_mode" current-user
  set +e
  guest_ps_readonly >"$test_dir/stdout" 2>"$test_dir/stderr" <<'POWERSHELL'
Write-Output 'fixture'
POWERSHELL
  status=$?
  set -e
  expected_status=255
  [[ "$non_exact_mode" == wrong-status ]] && expected_status=42
  [[ "$non_exact_mode" == powershell-error ]] && expected_status=1
  [[ "$status" == "$expected_status" ]] || fail "$non_exact_mode changed status"
  [[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "$non_exact_mode was retried"
  [[ ! -s "$sleep_log" ]] || fail "$non_exact_mode slept before failing"
done

reset_fake success current-user
guest_ps_readonly_run fixture 4 >/dev/null <<'POWERSHELL'
Write-Output ([Console]::In.ReadLine())
POWERSHELL
if command -v pwsh >/dev/null 2>&1; then
  EAI_TEST_POWERSHELL_PAYLOAD="$payload_log" \
    pwsh -NoLogo -NoProfile -NonInteractive -Command \
      '$tokens = $null; $errors = $null; [void][Management.Automation.Language.Parser]::ParseFile($env:EAI_TEST_POWERSHELL_PAYLOAD, [ref]$tokens, [ref]$errors); if ($errors.Count -ne 0) { exit 1 }' \
    || fail 'the generated PowerShell payload did not parse'
fi

printf 'Windows read-only PowerShell transport checks ok\n'
