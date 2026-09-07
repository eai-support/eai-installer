#!/usr/bin/env bash

# Shared Ubuntu-only Parallels session transport. This file is sourced by the
# Ubuntu release adapter and its helpers; it deliberately does not restore,
# start, or otherwise mutate a VM.

ubuntu_session_fail() {
  printf 'Ubuntu guest session failed: %s\n' "$*" >&2
  return 1
}

ubuntu_prl_root_shell() {
  [[ -n "${UBUNTU_PRL_VM_NAME:-}" ]] || return 2
  prlctl exec "$UBUNTU_PRL_VM_NAME" /bin/bash -s
}

ubuntu_prl_user_shell() {
  [[ -n "${UBUNTU_PRL_VM_NAME:-}" && -n "${UBUNTU_PRL_USER:-}" \
    && -n "${UBUNTU_PRL_UID:-}" && -n "${UBUNTU_PRL_HOME:-}" ]] || return 2
  prlctl exec "$UBUNTU_PRL_VM_NAME" /usr/sbin/runuser -u "$UBUNTU_PRL_USER" -- \
    /usr/bin/env -i \
      HOME="$UBUNTU_PRL_HOME" \
      USER="$UBUNTU_PRL_USER" \
      LOGNAME="$UBUNTU_PRL_USER" \
      SHELL=/bin/bash \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH="$UBUNTU_PRL_HOME/.eai-setup/node/bin:$UBUNTU_PRL_HOME/.eai-setup/npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
      XDG_CURRENT_DESKTOP=ubuntu:GNOME \
      XDG_SESSION_DESKTOP=ubuntu \
      DESKTOP_SESSION=ubuntu \
      GDMSESSION=ubuntu \
      XDG_SESSION_TYPE="$UBUNTU_PRL_SESSION_TYPE" \
      XDG_SESSION_ID="$UBUNTU_PRL_SESSION_ID" \
      XDG_RUNTIME_DIR="/run/user/$UBUNTU_PRL_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UBUNTU_PRL_UID/bus" \
      DISPLAY="$UBUNTU_PRL_DISPLAY" \
      WAYLAND_DISPLAY="$UBUNTU_PRL_WAYLAND_DISPLAY" \
      XAUTHORITY="$UBUNTU_PRL_XAUTHORITY" \
      /bin/bash -s
}

ubuntu_prl_user_exec() {
  [[ -n "${UBUNTU_PRL_VM_NAME:-}" && -n "${UBUNTU_PRL_USER:-}" \
    && -n "${UBUNTU_PRL_UID:-}" && -n "${UBUNTU_PRL_HOME:-}" ]] || return 2
  prlctl exec "$UBUNTU_PRL_VM_NAME" /usr/sbin/runuser -u "$UBUNTU_PRL_USER" -- \
    /usr/bin/env -i \
      HOME="$UBUNTU_PRL_HOME" \
      USER="$UBUNTU_PRL_USER" \
      LOGNAME="$UBUNTU_PRL_USER" \
      SHELL=/bin/bash \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PATH="$UBUNTU_PRL_HOME/.eai-setup/node/bin:$UBUNTU_PRL_HOME/.eai-setup/npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
      XDG_CURRENT_DESKTOP=ubuntu:GNOME \
      XDG_SESSION_DESKTOP=ubuntu \
      DESKTOP_SESSION=ubuntu \
      GDMSESSION=ubuntu \
      XDG_SESSION_TYPE="$UBUNTU_PRL_SESSION_TYPE" \
      XDG_SESSION_ID="$UBUNTU_PRL_SESSION_ID" \
      XDG_RUNTIME_DIR="/run/user/$UBUNTU_PRL_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UBUNTU_PRL_UID/bus" \
      DISPLAY="$UBUNTU_PRL_DISPLAY" \
      WAYLAND_DISPLAY="$UBUNTU_PRL_WAYLAND_DISPLAY" \
      XAUTHORITY="$UBUNTU_PRL_XAUTHORITY" \
      "$@"
}

# Stop and remove only the release harness's exact Snap-visible Firefox
# profile. Callers must first prove that this profile did not predate the run.
ubuntu_disposable_browser_cleanup() {
  local profile="$1"
  local pid_file="$2"
  local expected_profile="$UBUNTU_PRL_HOME/snap/firefox/common/eai-release-e2e-profile"
  local stop_status=0
  [[ "$profile" == "$expected_profile" \
    && "$pid_file" == "$expected_profile/eai-release-e2e-firefox.pid" ]] || return 2
  prlctl exec "$UBUNTU_PRL_VM_NAME" /bin/bash -c '
    uid=$1; profile=$2; pid_file=$3
    pids=""
    if [ -f "$pid_file" ] && [ ! -L "$pid_file" ]; then
      read -r recorded_pid < "$pid_file"
      case "$recorded_pid" in ""|*[!0-9]*) ;; *) pids="$recorded_pid";; esac
    fi
    # The Snap launcher can exit after spawning the real browser, so also
    # resolve every verified-user process carrying this exact profile path.
    for process in /proc/[0-9]*; do
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || continue
      command=$(tr "\0" " " < "$process/cmdline" 2>/dev/null)
      case "$command" in *"$profile"*) pids="$pids ${process##*/}";; esac
    done
    for pid in $pids; do
      case "$pid" in ""|*[!0-9]*) continue;; esac
      [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] || continue
      command=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)
      case "$command" in *"$profile"*) kill -TERM "$pid" 2>/dev/null || true;; esac
    done
    for _ in $(seq 1 20); do
      alive=0
      for pid in $pids; do
        [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] || continue
        command=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)
        case "$command" in *"$profile"*) alive=1;; esac
      done
      [ "$alive" = 0 ] && exit 0
      sleep 1
    done
    for pid in $pids; do
      [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] || continue
      command=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)
      case "$command" in *"$profile"*) kill -KILL "$pid" 2>/dev/null || true;; esac
    done
    for _ in $(seq 1 10); do
      alive=0
      for pid in $pids; do
        [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] || continue
        command=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)
        case "$command" in *"$profile"*) alive=1;; esac
      done
      [ "$alive" = 0 ] && exit 0
      sleep 1
    done
    exit 1
  ' _ "$UBUNTU_PRL_UID" "$profile" "$pid_file" >/dev/null 2>&1 || stop_status=$?
  [[ "$stop_status" == 0 ]] || return 1
  ubuntu_prl_user_exec /bin/rm -rf -- "$profile" >/dev/null 2>&1
}

ubuntu_prl_session_configure() {
  local vm_name="$1"
  local expected_user="$2"
  local work_dir="$3"
  local session_record=""
  local session_id=""
  local session_name=""
  local session_uid=""
  local session_type=""
  local session_class=""
  local session_state=""
  local session_remote=""
  local session_leader=""
  local guest_home=""
  local display=""
  local wayland_display=""
  local xauthority=""

  [[ "$expected_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] \
    || ubuntu_session_fail "the expected user is not a valid local Unix username" || return
  [[ -d "$work_dir" ]] || ubuntu_session_fail "the caller-owned temporary directory is unavailable" || return
  prlctl status "$vm_name" 2>/dev/null | /usr/bin/grep -Fq running \
    || ubuntu_session_fail "the configured VM is not running" || return

  # Select only the expected user's active, local, seat0 graphical login.
  # The expected username is validated above and is not protected data.
  session_record="$(prlctl exec "$vm_name" /bin/bash -c '
    expected=$1
    while read -r sid _; do
      [ -n "$sid" ] || continue
      name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null) || continue
      uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null) || continue
      state=$(loginctl show-session "$sid" -p State --value 2>/dev/null) || continue
      active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null) || continue
      remote=$(loginctl show-session "$sid" -p Remote --value 2>/dev/null) || continue
      type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null) || continue
      class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null) || continue
      seat=$(loginctl show-session "$sid" -p Seat --value 2>/dev/null) || continue
      leader=$(loginctl show-session "$sid" -p Leader --value 2>/dev/null) || continue
      if [ "$name" = "$expected" ] && [ "$state" = active ] && [ "$active" = yes ] \
        && [ "$remote" = no ] && { [ "$type" = x11 ] || [ "$type" = wayland ]; } \
        && [ "$class" = user ] && [ "$seat" = seat0 ] && [ -n "$leader" ]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$sid" "$name" "$uid" "$type" "$class" "$state" "$remote" "$leader"
        exit 0
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    exit 1
  ' _ "$expected_user" 2>/dev/null || true)"

  IFS=$'\t' read -r session_id session_name session_uid session_type \
    session_class session_state session_remote session_leader <<<"$session_record"
  [[ -n "$session_id" && "$session_name" == "$expected_user" ]] \
    || ubuntu_session_fail "no active local seat0 graphical session exists for $expected_user" || return
  [[ "$session_uid" =~ ^[1-9][0-9]*$ && "$session_leader" =~ ^[1-9][0-9]*$ ]] \
    || ubuntu_session_fail "the graphical session has invalid user or leader metadata" || return
  [[ "$session_type" == x11 || "$session_type" == wayland ]] \
    || ubuntu_session_fail "the selected session is not graphical" || return
  [[ "$session_class" == user && "$session_state" == active && "$session_remote" == no ]] \
    || ubuntu_session_fail "the selected graphical session is not a local active user session" || return

  guest_home="$(prlctl exec "$vm_name" /usr/bin/getent passwd "$expected_user" 2>/dev/null \
    | /usr/bin/awk -F: 'NR == 1 { print $6 }' | /usr/bin/tr -d '\r\n')"
  [[ "$guest_home" == "/home/$expected_user" ]] \
    || ubuntu_session_fail "the expected user's home directory is not /home/$expected_user" || return
  [[ "$(prlctl exec "$vm_name" /usr/bin/id -u "$expected_user" 2>/dev/null | /usr/bin/tr -d '\r\n')" == "$session_uid" ]] \
    || ubuntu_session_fail "the graphical session UID does not match the expected account" || return
  prlctl exec "$vm_name" /bin/test -d "/run/user/$session_uid" >/dev/null 2>&1 \
    || ubuntu_session_fail "the graphical user's runtime directory is missing" || return
  [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "/run/user/$session_uid" 2>/dev/null | /usr/bin/tr -d '\r\n')" == "$session_uid" ]] \
    || ubuntu_session_fail "the graphical user's runtime directory has the wrong owner" || return
  prlctl exec "$vm_name" /bin/test -S "/run/user/$session_uid/bus" >/dev/null 2>&1 \
    || ubuntu_session_fail "the graphical user's D-Bus socket is missing" || return

  # Read only allow-listed display variables. loginctl's Leader can be a PAM
  # helper without the desktop environment, so scan only processes owned by
  # the verified UID and explicitly bound to the selected XDG session. Never
  # copy or print a process's complete environment.
  display="$(prlctl exec "$vm_name" /bin/bash -c '
    sid=$1; uid=$2; leader=$3; key=$4
    for process in "/proc/$leader" /proc/[0-9]*; do
      [ -r "$process/environ" ] || continue
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || continue
      environment=$(tr "\0" "\n" < "$process/environ")
      if [ "${process##*/}" != "$leader" ]; then
        printf "%s\n" "$environment" | grep -Fxq "XDG_SESSION_ID=$sid" || continue
      fi
      value=$(printf "%s\n" "$environment" | sed -n "s/^$key=//p" | head -n 1)
      [ -n "$value" ] || continue
      printf "%s\n" "$value"
      exit 0
    done
    exit 1
  ' _ "$session_id" "$session_uid" "$session_leader" DISPLAY 2>/dev/null | /usr/bin/tr -d '\r\n' || true)"
  wayland_display="$(prlctl exec "$vm_name" /bin/bash -c '
    sid=$1; uid=$2; leader=$3; key=$4
    for process in "/proc/$leader" /proc/[0-9]*; do
      [ -r "$process/environ" ] || continue
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || continue
      environment=$(tr "\0" "\n" < "$process/environ")
      if [ "${process##*/}" != "$leader" ]; then
        printf "%s\n" "$environment" | grep -Fxq "XDG_SESSION_ID=$sid" || continue
      fi
      value=$(printf "%s\n" "$environment" | sed -n "s/^$key=//p" | head -n 1)
      [ -n "$value" ] || continue
      printf "%s\n" "$value"
      exit 0
    done
    exit 1
  ' _ "$session_id" "$session_uid" "$session_leader" WAYLAND_DISPLAY 2>/dev/null | /usr/bin/tr -d '\r\n' || true)"
  xauthority="$(prlctl exec "$vm_name" /bin/bash -c '
    sid=$1; uid=$2; leader=$3; key=$4
    for process in "/proc/$leader" /proc/[0-9]*; do
      [ -r "$process/environ" ] || continue
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || continue
      environment=$(tr "\0" "\n" < "$process/environ")
      if [ "${process##*/}" != "$leader" ]; then
        printf "%s\n" "$environment" | grep -Fxq "XDG_SESSION_ID=$sid" || continue
      fi
      value=$(printf "%s\n" "$environment" | sed -n "s/^$key=//p" | head -n 1)
      [ -n "$value" ] || continue
      printf "%s\n" "$value"
      exit 0
    done
    exit 1
  ' _ "$session_id" "$session_uid" "$session_leader" XAUTHORITY 2>/dev/null | /usr/bin/tr -d '\r\n' || true)"

  if [[ "$session_type" == x11 ]]; then
    [[ "$display" =~ ^:[0-9]+([.][0-9]+)?$ ]] \
      || ubuntu_session_fail "the X11 session leader did not expose a valid DISPLAY" || return
    [[ "$xauthority" == /* && "$xauthority" != *[[:space:]]* ]] \
      || ubuntu_session_fail "the X11 session leader did not expose a valid XAUTHORITY path" || return
    prlctl exec "$vm_name" /bin/test -f "$xauthority" >/dev/null 2>&1 \
      || ubuntu_session_fail "the X11 authority file does not exist" || return
    [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "$xauthority" 2>/dev/null | /usr/bin/tr -d '\r\n')" == "$session_uid" ]] \
      || ubuntu_session_fail "the X11 authority file is not owned by the graphical user" || return
    wayland_display=""
  else
    [[ "$wayland_display" =~ ^wayland-[0-9]+$ ]] \
      || ubuntu_session_fail "the Wayland session leader did not expose a valid socket name" || return
    prlctl exec "$vm_name" /bin/test -S "/run/user/$session_uid/$wayland_display" >/dev/null 2>&1 \
      || ubuntu_session_fail "the Wayland display socket does not exist" || return
    [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "/run/user/$session_uid/$wayland_display" 2>/dev/null | /usr/bin/tr -d '\r\n')" == "$session_uid" ]] \
      || ubuntu_session_fail "the Wayland display socket is not owned by the graphical user" || return
    [[ -z "$display" || "$display" =~ ^:[0-9]+([.][0-9]+)?$ ]] \
      || ubuntu_session_fail "the Wayland session exposed an invalid XWayland DISPLAY" || return
    [[ -z "$xauthority" || ( "$xauthority" == /* && "$xauthority" != *[[:space:]]* ) ]] \
      || ubuntu_session_fail "the Wayland session exposed an invalid XAUTHORITY path" || return
  fi

  UBUNTU_PRL_VM_NAME="$vm_name"
  UBUNTU_PRL_USER="$session_name"
  UBUNTU_PRL_UID="$session_uid"
  UBUNTU_PRL_HOME="$guest_home"
  UBUNTU_PRL_SESSION_ID="$session_id"
  UBUNTU_PRL_SESSION_TYPE="$session_type"
  UBUNTU_PRL_SESSION_LEADER="$session_leader"
  UBUNTU_PRL_DISPLAY="$display"
  UBUNTU_PRL_WAYLAND_DISPLAY="$wayland_display"
  UBUNTU_PRL_XAUTHORITY="$xauthority"
  export UBUNTU_PRL_VM_NAME UBUNTU_PRL_USER UBUNTU_PRL_UID UBUNTU_PRL_HOME
  export UBUNTU_PRL_SESSION_ID UBUNTU_PRL_SESSION_TYPE UBUNTU_PRL_SESSION_LEADER
  export UBUNTU_PRL_DISPLAY UBUNTU_PRL_WAYLAND_DISPLAY UBUNTU_PRL_XAUTHORITY
}
