#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/ubuntu-guest-session.sh"

vm_name="${EAI_UBUNTU_VM_NAME:-Ubuntu 24.04.3 ARM64}"
guest_user="${EAI_UBUNTU_GUEST_USER:-parallels}"
login_url="${EAI_HARNESS_LOGIN_URL:-https://www.enterpriseaigroup.com/sign-in}"
tenant_name="${EAI_HARNESS_TENANT_NAME:-}"
tenant_id="${EAI_HARNESS_TENANT_ID:-}"
test_email="${EAI_HARNESS_USER_EMAIL:-}"
keychain_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
input_helper="$ROOT/scripts/parallels-input.mjs"
ui_helper="$ROOT/scripts/ubuntu-ui-action.py"
ocr_source="$ROOT/scripts/macos-ocr-match.swift"
ocr_binary="${TMPDIR:-/tmp}/eai-installer-macos-ocr-match"
browser_profile=""
browser_pid_file=""
browser_log=""
browser_launcher=""
firefox_snap_root=""
work_dir="$(mktemp -d)"
mode="both"
session_configured=0
disposable_profile_owned=0
preserve_browser="${EAI_UBUNTU_PRESERVE_BROWSER:-0}"

cleanup() {
  local status=$?
  set +e
  if [[ "$session_configured" == 1 && "$disposable_profile_owned" == 1 \
    && "$preserve_browser" != 1 ]]; then
    stop_profile_bound_firefox >/dev/null 2>&1 || true
    ubuntu_disposable_browser_cleanup "$browser_profile" "$browser_pid_file"
  fi
  rm -rf -- "$work_dir"
  return "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'Ubuntu guest login failed: %s\n' "$*" >&2
  exit 1
}

[[ -n "$tenant_name" ]] || fail "EAI_HARNESS_TENANT_NAME is required."
[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] \
  || fail "EAI_HARNESS_TENANT_ID must be a tenant UUID."
[[ -n "$test_email" && "$test_email" != *[[:space:]]* ]] \
  || fail "EAI_HARNESS_USER_EMAIL is required."
[[ "$login_url" == "https://www.enterpriseaigroup.com/sign-in" ]] \
  || fail "EAI_HARNESS_LOGIN_URL must be the supported Enterprise AI Group sign-in page."
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "The Ubuntu guest username is invalid."
[[ "$preserve_browser" == 0 || "$preserve_browser" == 1 ]] \
  || fail "EAI_UBUNTU_PRESERVE_BROWSER must be 0 or 1."
command -v prlctl >/dev/null 2>&1 || fail "prlctl is not installed."
command -v node >/dev/null 2>&1 || fail "Node.js is not installed on the host."
command -v security >/dev/null 2>&1 || fail "The macOS Keychain command is unavailable."
command -v swiftc >/dev/null 2>&1 || fail "The Swift compiler required for private local OCR is unavailable."
[[ -f "$input_helper" ]] || fail "The Parallels input helper is missing."
[[ -f "$ui_helper" ]] || fail "The Ubuntu AT-SPI helper is missing."
[[ -f "$ocr_source" ]] || fail "The screenshot OCR helper is missing."

if [[ ! -x "$ocr_binary" || "$ocr_source" -nt "$ocr_binary" ]]; then
  swiftc -O "$ocr_source" -o "$ocr_binary" >/dev/null \
    || fail "The screenshot OCR helper could not be compiled."
fi

# Validate service and account metadata only. The secret is read at the exact
# password-field action below and streamed directly to virtual-key input.
/usr/bin/security find-generic-password -s "$keychain_service" -a "$test_email" >/dev/null 2>&1 \
  || fail "The EAI release-test Keychain item is missing."

case "${1:-}" in
  "")
    [[ "$#" == 0 ]] || fail "Unknown argument."
    ;;
  --preflight)
    [[ "$#" == 1 ]] || fail "--preflight does not accept additional arguments."
    exit 0
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

ubuntu_prl_session_configure "$vm_name" "$guest_user" "$work_dir" \
  || fail "The expected Ubuntu graphical session could not be verified."
session_configured=1
browser_profile="$UBUNTU_PRL_HOME/snap/firefox/common/eai-release-e2e-profile"
browser_pid_file="$browser_profile/eai-release-e2e-firefox.pid"
browser_log="$browser_profile/firefox.log"
browser_launcher="$browser_profile/eai-release-e2e-browser"

input() {
  node "$input_helper" --vm "$vm_name" "$@"
}

run_ui_action() {
  ubuntu_prl_user_exec /usr/bin/python3 - "$@" <"$ui_helper"
}

screen_has() {
  local pattern="$1"
  local screenshot="$work_dir/screen.png"
  local status=2
  if prlctl capture "$vm_name" --file "$screenshot" >/dev/null 2>&1; then
    set +e
    EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
    status=$?
    set -e
  fi
  rm -f -- "$screenshot"
  [[ "$status" == 0 ]]
}

firefox_snap_root_proof() {
  prlctl exec "$vm_name" /bin/bash -c '
    set -eu
    wrapper=/usr/bin/firefox
    [ -x "$wrapper" ]
    [ "$(stat -Lc %u "$wrapper")" = 0 ]
    wrapper_mode=$(stat -Lc %a "$wrapper")
    [ $((8#$wrapper_mode & 022)) -eq 0 ]
    wrapper_real=$(readlink -f "$wrapper")
    case "$wrapper_real" in
      /usr/bin/snap) ;;
      /usr/bin/firefox)
        grep -Eq "(/snap/bin/firefox|snap[[:space:]]+run[[:space:]]+firefox)" "$wrapper"
        ;;
      *) exit 1 ;;
    esac
    [ "$(stat -Lc %u "$wrapper_real")" = 0 ]
    wrapper_real_mode=$(stat -Lc %a "$wrapper_real")
    [ $((8#$wrapper_real_mode & 022)) -eq 0 ]
    [ -L /snap/firefox/current ]
    revision=$(readlink /snap/firefox/current)
    case "$revision" in ""|*[!0-9]*) exit 1 ;; esac
    snap_root=/snap/firefox/$revision
    [ "$(readlink -f /snap/firefox/current)" = "$snap_root" ]
    [ -d "$snap_root" ] && [ ! -L "$snap_root" ]
    [ "$(stat -Lc %u "$snap_root")" = 0 ]
    root_mode=$(stat -Lc %a "$snap_root")
    [ $((8#$root_mode & 022)) -eq 0 ]
    mount_record=$(findmnt -n -o FSTYPE,OPTIONS --target "$snap_root")
    set -- $mount_record
    [ "${1:-}" = squashfs ]
    case ",${2:-}," in *,ro,*) ;; *) exit 1 ;; esac
    main_binary=$snap_root/usr/lib/firefox/firefox
    main_real=$(readlink -f "$main_binary")
    case "$main_real" in "$snap_root"/*) ;; *) exit 1 ;; esac
    [ -f "$main_real" ] && [ -x "$main_real" ]
    [ "$(stat -Lc %u "$main_real")" = 0 ]
    main_mode=$(stat -Lc %a "$main_real")
    [ $((8#$main_mode & 022)) -eq 0 ]
    printf "%s\n" "$snap_root"
  ' 2>/dev/null | tr -d '\r\n'
}

profile_bound_firefox_action() {
  local action="$1"
  [[ "$action" == probe || "$action" == stop ]] || return 2
  [[ "$firefox_snap_root" =~ ^/snap/firefox/[0-9]+$ ]] || return 1
  prlctl exec "$vm_name" /bin/bash -c '
    action=$1; uid=$2; profile=$3; session=$4; session_type=$5; display=$6; wayland_display=$7; snap_root=$8
    case "$action" in probe|stop) ;; *) exit 2 ;; esac
    [ "$(readlink -f /snap/firefox/current 2>/dev/null)" = "$snap_root" ] || exit 1
    is_bound() {
      process=$1
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || return 1
      [ -r "$process/cmdline" ] && [ -r "$process/environ" ] || return 1
      executable=$(readlink -f "$process/exe" 2>/dev/null) || return 1
      case "$executable" in
        "$snap_root/usr/lib/firefox/firefox"|"$snap_root/usr/lib/firefox/firefox-bin") ;;
        *) return 1 ;;
      esac
      [ "$(stat -Lc %u "$executable" 2>/dev/null)" = 0 ] || return 1
      executable_mode=$(stat -Lc %a "$executable" 2>/dev/null) || return 1
      [ $((8#$executable_mode & 022)) -eq 0 ] || return 1
      process_name=$(cat "$process/comm" 2>/dev/null) || return 1
      case "$process_name" in firefox|firefox-bin) ;; *) return 1 ;; esac
      profile_match=0
      tr "\0" "\n" < "$process/environ" \
        | grep -Fxq "EAI_RELEASE_E2E_FIREFOX_PROFILE=$profile" && profile_match=1
      previous=""
      while IFS= read -r -d "" argument; do
        if { [ "$previous" = --profile ] || [ "$previous" = -profile ]; } \
          && [ "$argument" = "$profile" ]; then
          profile_match=1
        fi
        case "$argument" in
          --profile="$profile"|-profile="$profile") profile_match=1 ;;
        esac
        previous=$argument
      done < "$process/cmdline"
      [ "$profile_match" = 1 ] || return 1
      tr "\0" "\n" < "$process/environ" | grep -Fxq "XDG_SESSION_ID=$session" || return 1
      tr "\0" "\n" < "$process/environ" | grep -Fxq "XDG_RUNTIME_DIR=/run/user/$uid" || return 1
      tr "\0" "\n" < "$process/environ" | grep -Fxq "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" || return 1
      if [ "$session_type" = wayland ]; then
        tr "\0" "\n" < "$process/environ" | grep -Fxq "WAYLAND_DISPLAY=$wayland_display" || return 1
      else
        tr "\0" "\n" < "$process/environ" | grep -Fxq "DISPLAY=$display" || return 1
      fi
    }
    bound_pids() {
      for process in /proc/[0-9]*; do
        is_bound "$process" || continue
        printf "%s\n" "${process##*/}"
      done
    }
    if [ "$action" = probe ]; then
      [ -n "$(bound_pids)" ]
      exit
    fi
    stable_absence=0
    poll=0
    while [ "$poll" -lt 80 ] && [ "$stable_absence" -lt 4 ]; do
      pids=$(bound_pids)
      if [ -z "$pids" ]; then
        stable_absence=$((stable_absence + 1))
      else
        stable_absence=0
        signal=TERM
        [ "$poll" -lt 40 ] || signal=KILL
        for pid in $pids; do kill -"$signal" "$pid" 2>/dev/null || true; done
      fi
      poll=$((poll + 1))
      sleep 0.25
    done
    [ "$stable_absence" -ge 4 ]
  ' _ "$action" "$UBUNTU_PRL_UID" "$browser_profile" "$UBUNTU_PRL_SESSION_ID" \
    "$UBUNTU_PRL_SESSION_TYPE" "$UBUNTU_PRL_DISPLAY" "$UBUNTU_PRL_WAYLAND_DISPLAY" \
    "$firefox_snap_root" >/dev/null 2>&1
}

profile_bound_firefox() {
  profile_bound_firefox_action probe
}

stop_profile_bound_firefox() {
  profile_bound_firefox_action stop
}

firefox_snap_root="$(firefox_snap_root_proof)" \
  || fail "Firefox is not bound to a root-owned, read-only installed Snap revision."

portal_is_ready() {
  screen_has "Getting started" && screen_has "Company platform"
}

wait_for_portal() {
  local attempts="${1:-120}"
  for _ in $(seq 1 "$attempts"); do
    portal_is_ready && return 0
    sleep 1
  done
  return 1
}

if [[ "$mode" != cli ]]; then
  ubuntu_prl_user_exec /usr/bin/test -x /usr/bin/firefox >/dev/null 2>&1 \
    || fail "The approved Ubuntu snapshot does not provide Firefox."
  if ubuntu_prl_user_exec /usr/bin/pgrep -u "$UBUNTU_PRL_UID" -x firefox >/dev/null 2>&1 \
    || ubuntu_prl_user_exec /usr/bin/pgrep -u "$UBUNTU_PRL_UID" -f '/firefox' >/dev/null 2>&1; then
    fail "Firefox was already running before the fresh Ubuntu portal login."
  fi
  browser_profile_parent="${browser_profile%/*}"
  ubuntu_prl_user_exec /bin/mkdir -p -- "$browser_profile_parent" >/dev/null 2>&1 \
    || fail "Firefox's Snap-visible release-test profile parent could not be created."
  ubuntu_prl_user_exec /bin/test -d "$browser_profile_parent" >/dev/null 2>&1 \
    && ubuntu_prl_user_exec /bin/test ! -L "$browser_profile_parent" >/dev/null 2>&1 \
    && [[ "$(ubuntu_prl_user_exec /usr/bin/stat -c %u "$browser_profile_parent" 2>/dev/null | tr -d '\r\n')" == "$UBUNTU_PRL_UID" ]] \
    || fail "Firefox's Snap-visible release-test profile parent is not a user-owned directory."
  ubuntu_prl_user_exec /usr/bin/test ! -e "$browser_profile" >/dev/null 2>&1 \
    || fail "The disposable Ubuntu Firefox profile already exists before login."
  disposable_profile_owned=1

  ubuntu_prl_user_shell <<BASH
set -euo pipefail
umask 077
mkdir '$browser_profile'
cat >'$browser_profile/user.js' <<'PREFS'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.startup.firstrunSkipsHomepage", true);
user_pref("signon.rememberSignons", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
PREFS
export EAI_RELEASE_E2E_FIREFOX_PROFILE='$browser_profile'
/usr/bin/setsid /usr/bin/firefox --profile '$browser_profile' --new-window '$login_url' \
  >'$browser_log' 2>&1 </dev/null &
printf '%s\n' "\$!" >'$browser_pid_file'
BASH

  run_ui_action assert-origin 'www.enterpriseaigroup.com,enterpriseaigroup.com' 60 >/dev/null \
    || fail "Firefox did not remain on the supported public HTTPS origin."
  if portal_is_ready; then
    fail "The restored Ubuntu snapshot reached the portal without a fresh protected login."
  fi
  run_ui_action wait "Sign in to your account" 60 >/dev/null \
    || fail "The Enterprise AI Group sign-in page did not become ready."
  run_ui_action invoke "Continue with Email" 60 >/dev/null \
    || fail "The public Continue with Email action could not be invoked."
  printf 'PUBLIC_SIGN_IN_HANDOFF_READY\n'

  run_ui_action assert-origin admin-portal.myenterprise.ai 60 >/dev/null \
    || fail "Firefox did not reach the supported Enterprise AI portal HTTPS origin."
  if portal_is_ready; then
    fail "The restored Ubuntu snapshot reached the authenticated portal before credentials were entered."
  fi
  run_ui_action invoke "Sign in with Microsoft" 60 >/dev/null \
    || fail "The portal Sign in with Microsoft action could not be invoked."
  printf 'PORTAL_MICROSOFT_HANDOFF_READY\n'

  run_ui_action assert-origin 'enterpriseaiplatform.ciamlogin.com,login.microsoftonline.com' 90 >/dev/null \
    || fail "Firefox did not reach the supported Microsoft HTTPS sign-in origin."
  if screen_has "Enter password"; then
    fail "Microsoft skipped the required fresh email stage."
  fi
  run_ui_action focus "Email address" 60 >/dev/null \
    || fail "Microsoft's email field could not be focused."
  printf '%s' "$test_email" | input type --stdin
  run_ui_action invoke "Next" 30 >/dev/null \
    || fail "Microsoft's Next action could not be invoked."
  printf 'MICROSOFT_EMAIL_STAGE_SUBMITTED\n'

  run_ui_action assert-origin 'enterpriseaiplatform.ciamlogin.com,login.microsoftonline.com' 60 >/dev/null \
    || fail "Firefox left the supported Microsoft HTTPS origin before password entry."
  run_ui_action focus "Password" 60 >/dev/null \
    || fail "Microsoft's password field could not be focused."
  /usr/bin/security find-generic-password -s "$keychain_service" -a "$test_email" -w \
    | input type --stdin
  run_ui_action invoke "Sign in" 30 >/dev/null \
    || fail "Microsoft's Sign in action could not be invoked."
  printf 'MICROSOFT_PASSWORD_STAGE_SUBMITTED\n'

  # Password saving is disabled in the disposable profile, but dismiss a
  # browser-owned prompt if a distro policy still presents one.
  if screen_has "Save password" || screen_has "Save Password"; then
    input key escape
  fi
  if run_ui_action wait "Stay signed in" 45 >/dev/null 2>&1; then
    run_ui_action invoke "Yes" 20 >/dev/null \
      || fail "Microsoft's stay-signed-in confirmation could not be invoked."
  fi
  wait_for_portal 120 || fail "The authenticated Enterprise AI portal did not become ready."
  run_ui_action assert-origin admin-portal.myenterprise.ai 30 >/dev/null \
    || fail "The authenticated portal was not on the supported HTTPS origin."
  printf 'FRESH_PROTECTED_LOGIN_PROVEN\n'
  printf 'AUTHENTICATED_PORTAL_READY\n'
  [[ "$mode" == portal ]] && exit 0
fi

exact_cli="$UBUNTU_PRL_HOME/.eai-setup/npm-global/bin/eai"
ubuntu_prl_user_exec /usr/bin/test -x "$exact_cli" >/dev/null 2>&1 \
  || fail "The exact EAI CLI installed by EAI Setup is unavailable."

# The CLI callback must reuse the same disposable Firefox profile and verified
# graphical login as the portal flow. A private fixed launcher gives libraries
# that honour BROWSER an exact target; the before/after process proof also
# catches launchers that fall back to xdg-open and Firefox remote activation.
ubuntu_prl_user_exec /bin/test -d "$browser_profile" >/dev/null 2>&1 \
  && ubuntu_prl_user_exec /bin/test ! -L "$browser_profile" >/dev/null 2>&1 \
  && [[ "$(ubuntu_prl_user_exec /usr/bin/stat -c %u "$browser_profile" 2>/dev/null | tr -d '\r\n')" == "$UBUNTU_PRL_UID" ]] \
  || fail "The disposable Ubuntu Firefox profile is unavailable for CLI login."
profile_bound_firefox \
  || fail "The CLI login has no Firefox process bound to the disposable profile and graphical session."
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  "profile='$browser_profile'" \
  '[ "$#" -eq 1 ]' \
  'url=$1' \
  'case "$url" in http://127.0.0.1:*|http://localhost:*|https://*) ;; *) exit 2;; esac' \
  'export EAI_RELEASE_E2E_FIREFOX_PROFILE="$profile"' \
  'exec /usr/bin/firefox --profile "$profile" --new-tab "$url"' \
  | ubuntu_prl_user_exec /usr/bin/install -m 0700 /dev/stdin "$browser_launcher" \
  || fail "The disposable Firefox CLI launcher could not be created."
ubuntu_prl_user_exec /bin/test -f "$browser_launcher" >/dev/null 2>&1 \
  && ubuntu_prl_user_exec /bin/test ! -L "$browser_launcher" >/dev/null 2>&1 \
  && [[ "$(ubuntu_prl_user_exec /usr/bin/stat -c %u "$browser_launcher" 2>/dev/null | tr -d '\r\n')" == "$UBUNTU_PRL_UID" ]] \
  || fail "The disposable Firefox CLI launcher is not a user-owned regular file."

# The portal and CLI sessions are separate. Refresh the CLI token every run;
# suppress and then delete all command output because it can contain callback
# URLs or account metadata.
cli_output="$work_dir/cli-login.txt"
ubuntu_prl_user_shell >"$cli_output" 2>&1 <<BASH &
set -euo pipefail
export BROWSER='$browser_launcher'
exec '$exact_cli' login
BASH
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
rm -f -- "$cli_output"
[[ "$cli_finished" == 1 && "$cli_status" == 0 ]] \
  || fail "The EAI CLI browser callback did not complete."
profile_bound_firefox \
  || fail "The CLI callback escaped the disposable Firefox profile or graphical session."
printf 'CLI_DISPOSABLE_BROWSER_BOUND\n'

identity_file="$work_dir/whoami.txt"
tenant_file="$work_dir/tenants.json"
ubuntu_prl_user_shell >"$identity_file" 2>/dev/null <<BASH \
  || fail "The active EAI CLI identity could not be read."
set -euo pipefail
exec '$exact_cli' whoami
BASH
expected_email_lower="$(printf '%s' "$test_email" | tr '[:upper:]' '[:lower:]')"
identity_lower="$(tr '[:upper:]' '[:lower:]' <"$identity_file")"
rm -f -- "$identity_file"
[[ "$identity_lower" == *"$expected_email_lower"* \
  && "$identity_lower" =~ status[[:space:]:]+active ]] \
  || fail "The active EAI CLI identity does not match the protected test account."
identity_lower=""

ubuntu_prl_user_shell >"$tenant_file" 2>/dev/null <<BASH \
  || fail "The EAI CLI tenant list could not be read."
set -euo pipefail
exec '$exact_cli' tenant list --format json
BASH
EAI_EXPECTED_TENANT_ID="$tenant_id" EAI_EXPECTED_TENANT_NAME="$tenant_name" \
node --input-type=module - "$tenant_file" <<'NODE' \
  || fail "The configured harness tenant is not an active direct membership."
import fs from "node:fs";
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const tenants = Array.isArray(payload) ? payload : payload.tenants;
const match = tenants?.some((tenant) =>
  tenant.id === process.env.EAI_EXPECTED_TENANT_ID
  && tenant.displayName === process.env.EAI_EXPECTED_TENANT_NAME
  && tenant.directMembership === true
  && tenant.isActive !== false
);
if (!match) process.exitCode = 1;
NODE
rm -f -- "$tenant_file"
printf 'AUTHENTICATED_PORTAL_AND_CLI_READY\n'
