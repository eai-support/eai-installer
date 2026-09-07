#!/usr/bin/env bash

# Shared Parallels transport for the controlled macOS release guest.
#
# Callers must create a private work directory, arrange for their EXIT/signal
# traps to remove it, and call macos_prl_current_user_configure before using the
# other functions. Only commands that are safe to run again belong on the
# *_idempotent transports. Persistent GUI processes and other actions with an
# uncertain completion boundary must use the verified launchctl-asuser path.

MACOS_PRL_CURRENT_USER_READY=0
MACOS_PRL_CURRENT_USER_VM=""
MACOS_PRL_CURRENT_USER_NAME=""
MACOS_PRL_CURRENT_USER_UID=""
MACOS_PRL_CURRENT_USER_HOME=""
MACOS_PRL_CURRENT_USER_WORK_DIR=""

macos_prl_current_user_is_exact_transient() {
  local status="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  [[ "$status" -eq 255 ]] || return 1
  /usr/bin/grep -Fqx \
    -e 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.' \
    -e 'PrlJob_GetResult: Invalid argument. An invalid argument was passed.' \
    "$stdout_file" "$stderr_file"
}

_macos_prl_current_user_run_retryable() {
  local stdin_file="$1"
  shift
  local attempt=1
  local attempt_dir=""
  local max_attempts=3
  local status=1
  local stdout_file=""
  local stderr_file=""

  [[ -n "$MACOS_PRL_CURRENT_USER_VM" ]] || {
    printf 'The macOS Parallels current-user transport is not configured.\n' >&2
    return 1
  }
  [[ -d "$MACOS_PRL_CURRENT_USER_WORK_DIR" && -w "$MACOS_PRL_CURRENT_USER_WORK_DIR" ]] || {
    printf 'The macOS Parallels current-user work directory is unavailable.\n' >&2
    return 1
  }
  [[ "$stdin_file" == /dev/null || -f "$stdin_file" ]] || {
    printf 'The macOS Parallels retry input is unavailable.\n' >&2
    return 1
  }

  while (( attempt <= max_attempts )); do
    attempt_dir="$(/usr/bin/mktemp -d "$MACOS_PRL_CURRENT_USER_WORK_DIR/prl-current-user.XXXXXX")" \
      || return 1
    stdout_file="$attempt_dir/stdout"
    stderr_file="$attempt_dir/stderr"

    if prlctl exec "$MACOS_PRL_CURRENT_USER_VM" --current-user "$@" \
      <"$stdin_file" >"$stdout_file" 2>"$stderr_file"; then
      status=0
    else
      status=$?
    fi

    if [[ "$status" -eq 0 ]]; then
      /bin/cat "$stdout_file"
      /bin/cat "$stderr_file" >&2
      /bin/rm -rf -- "$attempt_dir"
      return 0
    fi

    if ! macos_prl_current_user_is_exact_transient "$status" "$stdout_file" "$stderr_file"; then
      /bin/cat "$stdout_file"
      /bin/cat "$stderr_file" >&2
      /bin/rm -rf -- "$attempt_dir"
      return "$status"
    fi

    if (( attempt == max_attempts )); then
      /bin/cat "$stdout_file"
      /bin/cat "$stderr_file" >&2
      /bin/rm -rf -- "$attempt_dir"
      printf 'Parallels current-user transport failed after %s attempts.\n' "$max_attempts" >&2
      return "$status"
    fi

    # Do not replay output from a transport-failed attempt. In addition to
    # avoiding duplicate diagnostics, this prevents protected command output
    # from being copied to the host log during a retry.
    /bin/rm -rf -- "$attempt_dir"
    printf 'Parallels current-user transport was transiently unavailable; retry %s/%s.\n' \
      "$((attempt + 1))" "$max_attempts" >&2
    sleep 2
    attempt=$((attempt + 1))
  done

  return 255
}

macos_prl_current_user_configure() {
  local vm_name="$1"
  local expected_user="$2"
  local work_dir="$3"
  local actual_user=""
  local actual_uid=""
  local actual_home=""
  local aqua_session=""
  local console_user=""

  MACOS_PRL_CURRENT_USER_READY=0
  MACOS_PRL_CURRENT_USER_VM=""
  MACOS_PRL_CURRENT_USER_NAME=""
  MACOS_PRL_CURRENT_USER_UID=""
  MACOS_PRL_CURRENT_USER_HOME=""
  MACOS_PRL_CURRENT_USER_WORK_DIR=""

  [[ "$expected_user" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'The expected macOS guest user is invalid.\n' >&2
    return 1
  }
  [[ -d "$work_dir" && -w "$work_dir" ]] || {
    printf 'The macOS Parallels caller work directory is unavailable.\n' >&2
    return 1
  }

  MACOS_PRL_CURRENT_USER_VM="$vm_name"
  MACOS_PRL_CURRENT_USER_WORK_DIR="$work_dir"
  actual_user="$(_macos_prl_current_user_run_retryable /dev/null /usr/bin/id -un | tr -d '\r\n')" \
    || return 1
  if [[ "$actual_user" != "$expected_user" ]]; then
    printf 'The Parallels current-user channel is not the expected signed-in macOS user.\n' >&2
    return 1
  fi

  # Identity has now been proved. The remaining probes are read-only and may
  # use the same bounded exact-error transport while configuration is completed.
  actual_uid="$(_macos_prl_current_user_run_retryable /dev/null /usr/bin/id -u | tr -d '\r\n')" \
    || return 1
  [[ "$actual_uid" =~ ^[1-9][0-9]*$ ]] || {
    printf 'The signed-in macOS guest user has an invalid user ID.\n' >&2
    return 1
  }
  actual_home="$(_macos_prl_current_user_run_retryable /dev/null \
    /usr/bin/dscl . -read "/Users/$actual_user" NFSHomeDirectory \
    | /usr/bin/awk '{print $2}' | tr -d '\r\n')" || return 1
  [[ "$actual_home" == "/Users/$actual_user" ]] || {
    printf 'The signed-in macOS guest home directory is unexpected.\n' >&2
    return 1
  }

  console_user="$(prlctl exec "$vm_name" /usr/bin/stat -f %Su /dev/console 2>/dev/null | tr -d '\r\n')" \
    || return 1
  [[ "$console_user" == "$actual_user" ]] || {
    printf 'The Parallels current-user channel does not match the macOS console user.\n' >&2
    return 1
  }
  aqua_session="$(prlctl exec "$vm_name" /bin/launchctl print "gui/$actual_uid" 2>/dev/null)" \
    || return 1
  # launchctl can return roughly 100 KiB. With `pipefail`, piping that value to
  # `grep -q` is unsafe: grep exits on the early match, printf receives SIGPIPE,
  # and the successful probe is misclassified as a failed pipeline. Match the
  # captured value in-process so a large, valid Aqua domain stays valid.
  [[ "$aqua_session" == *"session = Aqua"* ]] || {
    printf 'The signed-in macOS Aqua launch session is unavailable.\n' >&2
    return 1
  }

  MACOS_PRL_CURRENT_USER_READY=1
  MACOS_PRL_CURRENT_USER_NAME="$actual_user"
  MACOS_PRL_CURRENT_USER_UID="$actual_uid"
  MACOS_PRL_CURRENT_USER_HOME="$actual_home"
  return 0
}

macos_prl_current_user_exec_idempotent() {
  [[ "$MACOS_PRL_CURRENT_USER_READY" == 1 ]] || {
    printf 'The signed-in macOS user has not been verified.\n' >&2
    return 1
  }
  _macos_prl_current_user_run_retryable /dev/null "$@"
}

macos_prl_current_user_shell_idempotent() {
  local script_dir=""
  local script_file=""
  local status=1

  [[ "$MACOS_PRL_CURRENT_USER_READY" == 1 ]] || {
    printf 'The signed-in macOS user has not been verified.\n' >&2
    return 1
  }
  script_dir="$(/usr/bin/mktemp -d "$MACOS_PRL_CURRENT_USER_WORK_DIR/prl-current-user-input.XXXXXX")" \
    || return 1
  script_file="$script_dir/stdin"
  /bin/cat >"$script_file"
  if _macos_prl_current_user_run_retryable "$script_file" /bin/sh; then
    status=0
  else
    status=$?
  fi
  /bin/rm -rf -- "$script_dir"
  return "$status"
}

macos_prl_signed_in_user_exec() {
  [[ "$MACOS_PRL_CURRENT_USER_READY" == 1 ]] || {
    printf 'The signed-in macOS user has not been verified.\n' >&2
    return 1
  }
  prlctl exec "$MACOS_PRL_CURRENT_USER_VM" \
    /bin/launchctl asuser "$MACOS_PRL_CURRENT_USER_UID" \
    /usr/bin/sudo -H -u "$MACOS_PRL_CURRENT_USER_NAME" \
    /usr/bin/env HOME="$MACOS_PRL_CURRENT_USER_HOME" \
      USER="$MACOS_PRL_CURRENT_USER_NAME" LOGNAME="$MACOS_PRL_CURRENT_USER_NAME" \
    "$@"
}

macos_prl_signed_in_user_shell() {
  macos_prl_signed_in_user_exec /bin/sh
}
