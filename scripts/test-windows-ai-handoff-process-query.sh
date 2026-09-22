#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == --fake-guest-ps ]]; then
  [[ "${2:-}" == 1 ]] || exit 71
  payload="$(/bin/cat)"
  printf '%s\n' "$payload" >>"$EAI_FAKE_PAYLOAD_LOG"
  /usr/bin/grep -Fq "Get-Process Code" <<<"$payload" || exit 72
  /usr/bin/grep -Fq "ProgramFiles 'Microsoft VS Code\Code.exe'" <<<"$payload" || exit 73
  if /usr/bin/grep -Eq 'Stop-Process|Remove-Item|Set-Content|Start-Process|[.]Kill[(]' <<<"$payload"; then
    exit 74
  fi
  attempt="$(/bin/cat "$EAI_FAKE_ATTEMPT_FILE")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" >"$EAI_FAKE_ATTEMPT_FILE"

  case "$EAI_FAKE_MODE" in
    retcode-then-ready)
      if (( attempt < 3 )); then
        printf 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.\n' >&2
        exit 255
      fi
      printf 'EAI_AI_HANDOFF_PROCESS_READY:4242\n'
      ;;
    result-then-not-ready)
      if (( attempt < 2 )); then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
        exit 255
      fi
      printf 'EAI_AI_HANDOFF_PROCESS_NOT_READY\n'
      ;;
    all-transient)
      printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
      exit 255
      ;;
    extra-text)
      printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\nextra\n' >&2
      exit 255
      ;;
    partial-text)
      printf 'PrlJob_GetResult: Invalid argument.\n' >&2
      exit 255
      ;;
    wrong-status)
      printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
      exit 42
      ;;
    invalid-success)
      printf 'EAI_AI_HANDOFF_PROCESS_READY:4242 extra\n'
      ;;
    not-ready)
      printf 'EAI_AI_HANDOFF_PROCESS_NOT_READY\n'
      ;;
    *)
      exit 75
      ;;
  esac
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/windows-ai-handoff-process-query.sh"

test_dir="$(mktemp -d)"
attempt_file="$test_dir/attempt"
sleep_log="$test_dir/sleeps"
payload_log="$test_dir/payloads"
fake_mode=""

cleanup() {
  rm -rf -- "$test_dir"
}
trap cleanup EXIT

fail() {
  printf 'Windows AI handoff process query test failed: %s\n' "$*" >&2
  exit 1
}

reset_fake() {
  fake_mode="$1"
  printf '0\n' >"$attempt_file"
  : >"$sleep_log"
  : >"$payload_log"
}

sleep() {
  printf '%s\n' "$1" >>"$sleep_log"
}

guest_ps() {
  EAI_FAKE_MODE="$fake_mode" \
  EAI_FAKE_ATTEMPT_FILE="$attempt_file" \
  EAI_FAKE_PAYLOAD_LOG="$payload_log" \
    /bin/bash "$ROOT/scripts/test-windows-ai-handoff-process-query.sh" --fake-guest-ps "${1:-}"
}

reset_fake retcode-then-ready
set +e
output="$(windows_ai_handoff_process_query 2>"$test_dir/stderr")"
status=$?
set -e
[[ "$status" == 0 ]] || fail "the exact RetCode recovery failed with status $status: $(/bin/cat "$test_dir/stderr")"
[[ "$output" == EAI_AI_HANDOFF_PROCESS_READY:4242 ]] || fail "the exact RetCode recovery lost the process ID"
[[ "$(/bin/cat "$attempt_file")" == 3 ]] || fail "the exact RetCode failure did not stop at three attempts"
[[ "$(/bin/cat "$sleep_log")" == $'2\n2' ]] || fail "the exact RetCode retry delay was not two seconds"
[[ "$(/usr/bin/grep -Fc 'read-only Windows AI handoff process query transport unavailable' "$test_dir/stderr")" == 2 ]] \
  || fail "the RetCode retry diagnostics were not bounded"

reset_fake result-then-not-ready
set +e
output="$(windows_ai_handoff_process_query 2>"$test_dir/stderr")"
status=$?
set -e
[[ "$status" == 0 ]] || fail "the exact Result recovery failed with status $status: $(/bin/cat "$test_dir/stderr")"
[[ "$output" == EAI_AI_HANDOFF_PROCESS_NOT_READY ]] || fail "the exact Result recovery lost the not-ready state"
[[ "$(/bin/cat "$attempt_file")" == 2 ]] || fail "the exact Result failure did not recover on attempt two"
[[ "$(/bin/cat "$sleep_log")" == 2 ]] || fail "the exact Result retry delay was not two seconds"

reset_fake all-transient
set +e
windows_ai_handoff_process_query >"$test_dir/stdout" 2>"$test_dir/stderr"
status=$?
set -e
[[ "$status" == 255 ]] || fail "an exhausted exact transport failure changed status"
[[ "$(/bin/cat "$attempt_file")" == 3 ]] || fail "an exact transport failure exceeded three attempts"
[[ "$(/bin/cat "$sleep_log")" == $'2\n2' ]] || fail "an exhausted retry used an unexpected delay"

for non_exact_mode in extra-text partial-text; do
  reset_fake "$non_exact_mode"
  set +e
  windows_ai_handoff_process_query >"$test_dir/stdout" 2>"$test_dir/stderr"
  status=$?
  set -e
  [[ "$status" == 255 ]] || fail "$non_exact_mode changed status"
  [[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "$non_exact_mode was retried"
  [[ ! -s "$sleep_log" ]] || fail "$non_exact_mode slept before failing"
done

reset_fake wrong-status
set +e
windows_ai_handoff_process_query >"$test_dir/stdout" 2>"$test_dir/stderr"
status=$?
set -e
[[ "$status" == 42 ]] || fail "a non-255 failure changed status"
[[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "a non-255 failure was retried"
[[ ! -s "$sleep_log" ]] || fail "a non-255 failure slept before failing"

reset_fake invalid-success
set +e
windows_ai_handoff_process_query >"$test_dir/stdout" 2>"$test_dir/stderr"
status=$?
set -e
[[ "$status" == 65 ]] || fail "invalid successful output was not rejected"
[[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "invalid successful output was retried"
[[ ! -s "$sleep_log" ]] || fail "invalid successful output slept before failing"

reset_fake not-ready
set +e
output="$(windows_ai_handoff_process_query 2>"$test_dir/stderr")"
status=$?
set -e
[[ "$status" == 0 ]] || fail "the successful not-ready observation failed with status $status"
[[ "$output" == EAI_AI_HANDOFF_PROCESS_NOT_READY ]] || fail "a successful not-ready observation was rejected"
[[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "a successful not-ready observation was internally replayed"
[[ ! -s "$sleep_log" ]] || fail "a successful not-ready observation used a transport delay"

printf 'Windows AI handoff process query checks ok\n'
