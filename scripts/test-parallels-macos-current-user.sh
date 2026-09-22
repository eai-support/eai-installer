#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/parallels-macos-current-user.sh"

test_dir="$(mktemp -d)"
attempt_file="$test_dir/attempt"
call_log="$test_dir/calls"
fake_mode=""

cleanup() {
  rm -rf -- "$test_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'macOS Parallels transport test failed: %s\n' "$*" >&2
  exit 1
}

reset_fake() {
  fake_mode="$1"
  printf '0\n' >"$attempt_file"
  : >"$call_log"
}

prlctl() {
  local attempt=""
  local payload=""
  attempt="$(/bin/cat "$attempt_file")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" >"$attempt_file"
  printf '%s\n' "$*" >>"$call_log"

  case "$fake_mode" in
    retcode-then-success)
      if (( attempt < 3 )); then
        printf 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      printf 'successful stdout\n'
      printf 'successful stderr\n' >&2
      ;;
    result-then-success)
      if (( attempt < 2 )); then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      printf 'result signature recovered\n'
      ;;
    non-exact)
      printf 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed. extra\n' >&2
      return 255
      ;;
    wrong-status)
      printf 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.\n' >&2
      return 42
      ;;
    stdin-replay)
      payload="$(/bin/cat)"
      if (( attempt < 2 )); then
        printf 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.\n' >&2
        return 255
      fi
      printf '%s\n' "$payload"
      ;;
    configure)
      if [[ "$3" == --current-user && "$4" == /usr/bin/id && "$5" == -un ]]; then
        if (( attempt < 2 )); then
          printf 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.\n' >&2
          return 255
        fi
        printf 'testmac\n'
      elif [[ "$3" == --current-user && "$4" == /usr/bin/id && "$5" == -u ]]; then
        printf '501\n'
      elif [[ "$3" == --current-user && "$4" == /usr/bin/dscl ]]; then
        printf 'NFSHomeDirectory: /Users/testmac\n'
      elif [[ "$3" == /usr/bin/stat ]]; then
        printf 'testmac\n'
      elif [[ "$3" == /bin/launchctl && "$4" == print ]]; then
        # Keep the match near the beginning and exceed a pipe buffer. This
        # catches the former `printf | grep -q` + pipefail false negative.
        printf 'session = Aqua\n'
        /usr/bin/awk 'BEGIN { for (i = 0; i < 5000; i += 1) print "large-launchctl-domain-padding-0123456789" }'
      else
        return 64
      fi
      ;;
    asuser)
      printf 'asuser-ok\n'
      ;;
    *)
      return 64
      ;;
  esac
}

MACOS_PRL_CURRENT_USER_READY=1
MACOS_PRL_CURRENT_USER_VM=fake-vm
MACOS_PRL_CURRENT_USER_NAME=testmac
MACOS_PRL_CURRENT_USER_UID=501
MACOS_PRL_CURRENT_USER_HOME=/Users/testmac
MACOS_PRL_CURRENT_USER_WORK_DIR="$test_dir"

reset_fake retcode-then-success
macos_prl_current_user_exec_idempotent /usr/bin/true \
  >"$test_dir/stdout" 2>"$test_dir/stderr"
[[ "$(/bin/cat "$attempt_file")" == 3 ]] || fail "the RetCode signature did not retry exactly three attempts"
/usr/bin/grep -Fqx 'successful stdout' "$test_dir/stdout" || fail "successful stdout was not preserved"
/usr/bin/grep -Fqx 'successful stderr' "$test_dir/stderr" || fail "successful stderr was not preserved"
[[ "$(/usr/bin/grep -Fc 'transport was transiently unavailable' "$test_dir/stderr")" == 2 ]] \
  || fail "the retry diagnostic count was incorrect"
if /usr/bin/grep -Fq 'PrlJob_GetRetCode:' "$test_dir/stderr"; then
  fail "a transient attempt's raw output was replayed"
fi

reset_fake result-then-success
macos_prl_current_user_exec_idempotent /usr/bin/true >"$test_dir/stdout" 2>"$test_dir/stderr"
[[ "$(/bin/cat "$attempt_file")" == 2 ]] || fail "the Result signature did not recover on the second attempt"
/usr/bin/grep -Fqx 'result signature recovered' "$test_dir/stdout" || fail "the Result signature recovery output was lost"

reset_fake non-exact
set +e
macos_prl_current_user_exec_idempotent /usr/bin/true >"$test_dir/stdout" 2>"$test_dir/stderr"
status=$?
set -e
[[ "$status" == 255 ]] || fail "a non-exact error changed status"
[[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "a non-exact error was retried"
/usr/bin/grep -Fqx 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed. extra' "$test_dir/stderr" \
  || fail "a non-exact error was not preserved"

reset_fake wrong-status
set +e
macos_prl_current_user_exec_idempotent /usr/bin/true >"$test_dir/stdout" 2>"$test_dir/stderr"
status=$?
set -e
[[ "$status" == 42 ]] || fail "a non-255 error changed status"
[[ "$(/bin/cat "$attempt_file")" == 1 ]] || fail "a non-255 error was retried"

reset_fake stdin-replay
printf 'repeat-safe script\n' | macos_prl_current_user_shell_idempotent \
  >"$test_dir/stdout" 2>"$test_dir/stderr"
[[ "$(/bin/cat "$attempt_file")" == 2 ]] || fail "the idempotent shell input was not retried once"
/usr/bin/grep -Fqx 'repeat-safe script' "$test_dir/stdout" || fail "the idempotent shell input was not replayed"

reset_fake configure
macos_prl_current_user_configure fake-vm testmac "$test_dir" \
  >"$test_dir/stdout" 2>"$test_dir/stderr"
[[ "$MACOS_PRL_CURRENT_USER_READY" == 1 ]] || fail "the verified transport was not marked ready"
[[ "$MACOS_PRL_CURRENT_USER_NAME" == testmac ]] || fail "the signed-in user was not retained"
[[ "$MACOS_PRL_CURRENT_USER_UID" == 501 ]] || fail "the signed-in UID was not retained"
[[ "$MACOS_PRL_CURRENT_USER_HOME" == /Users/testmac ]] || fail "the signed-in home was not retained"

reset_fake asuser
macos_prl_signed_in_user_exec /usr/bin/open https://example.invalid \
  >"$test_dir/stdout" 2>"$test_dir/stderr"
/usr/bin/grep -Fqx 'asuser-ok' "$test_dir/stdout" || fail "the launchctl-asuser command did not run"
/usr/bin/grep -Fq \
  'exec fake-vm /bin/launchctl asuser 501 /usr/bin/sudo -H -u testmac /usr/bin/env HOME=/Users/testmac USER=testmac LOGNAME=testmac /usr/bin/open https://example.invalid' \
  "$call_log" || fail "the launchctl-asuser command was not least-privilege scoped"

if /usr/bin/find "$test_dir" -maxdepth 1 -type d -name 'prl-current-user.*' -print -quit | /usr/bin/grep -q .; then
  fail "a retry attempt directory was not removed"
fi

printf 'macOS Parallels transport checks ok\n'
