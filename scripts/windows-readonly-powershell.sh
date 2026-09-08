#!/usr/bin/env bash

# Bounded Parallels transports for replay-safe Windows PowerShell reads. This
# file is sourced by run-windows-guest-test.sh after its ordinary transport
# helpers are defined. Callers must pass only read-only PowerShell.
# shellcheck disable=SC2154 # vm_name is a required caller-owned global.

windows_readonly_is_session_open_failure() {
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

windows_readonly_is_ambiguous_result_failure() {
  local status="$1"
  local normalized=""
  local line=""
  local count=0
  [[ "$status" == 255 ]] || return 1
  normalized="$(printf '%s' "$2" | /usr/bin/tr -d '\r')"
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

windows_readonly_powershell_transport() {
  local channel="$1"
  local stdin_payload="$2"
  local max_session_attempts="$3"
  local script=""
  local output=""
  local status=1
  local session_attempt=1
  local ambiguous_attempt=1
  local channel_label=""

  [[ "$channel" == current-user || "$channel" == system ]] || return 2
  [[ "$max_session_attempts" =~ ^[1-9][0-9]*$ ]] || return 2
  script="$(/bin/cat)"
  [[ -n "$script" ]] || return 2
  if [[ "$channel" == current-user ]]; then
    channel_label=current-user
  else
    channel_label=LocalSystem
  fi

  while true; do
    if [[ "$channel" == current-user ]]; then
      if output="$(printf '%s\n' "$script" | windows_hidden_current_user_ps "$vm_name" "$stdin_payload" 2>&1)"; then
        status=0
      else
        status=$?
      fi
    else
      if output="$(write_powershell_payload_wrapper "$stdin_payload" "$script" \
        | prlctl exec "$vm_name" cmd.exe /D /S /C powershell.exe \
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -InputFormat Text -OutputFormat Text -Command - 2>&1)"; then
        status=0
      else
        status=$?
      fi
    fi

    if [[ "$status" == 0 ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if windows_readonly_is_session_open_failure "$output"; then
      if [[ "$session_attempt" -ge "$max_session_attempts" ]]; then
        break
      fi
      if [[ "$session_attempt" == 1 || $((session_attempt % 5)) == 0 ]]; then
        printf '%s read-only %s PowerShell session unavailable; retry %s/%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$channel_label" \
          "$session_attempt" "$max_session_attempts" >&2
      fi
      session_attempt=$((session_attempt + 1))
      sleep 2
      continue
    fi
    if windows_readonly_is_ambiguous_result_failure "$status" "$output"; then
      if [[ "$ambiguous_attempt" -ge 3 ]]; then
        break
      fi
      printf '%s read-only %s PowerShell result unavailable; retry %s/3\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$channel_label" \
        "$ambiguous_attempt" >&2
      ambiguous_attempt=$((ambiguous_attempt + 1))
      sleep 2
      continue
    fi
    break
  done

  printf '%s\n' "$output" >&2
  return "$status"
}

guest_ps_readonly_run() {
  local stdin_payload="$1"
  local max_session_attempts="${2:-30}"
  windows_readonly_powershell_transport current-user "$stdin_payload" "$max_session_attempts"
}

guest_ps_readonly() {
  windows_readonly_powershell_transport current-user "" 30
}

guest_system_ps_readonly_run() {
  local stdin_payload="$1"
  local max_session_attempts="${2:-5}"
  windows_readonly_powershell_transport system "$stdin_payload" "$max_session_attempts"
}

guest_system_ps_readonly() {
  windows_readonly_powershell_transport system "" 5
}
