#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/parallels-macos-current-user.sh"

vm_name="${EAI_MACOS_VM_NAME:-macOS}"
login_url="${EAI_HARNESS_LOGIN_URL:-https://www.enterpriseaigroup.com/sign-in}"
tenant_name="${EAI_HARNESS_TENANT_NAME:-}"
tenant_id="${EAI_HARNESS_TENANT_ID:-}"
test_email="${EAI_HARNESS_USER_EMAIL:-}"
keychain_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
input_helper="$ROOT/scripts/parallels-input.mjs"
ocr_source="$ROOT/scripts/macos-ocr-match.swift"
ocr_binary="${TMPDIR:-/tmp}/eai-installer-macos-ocr-match"
work_dir="$(mktemp -d)"
mode="both"

cleanup() {
  rm -rf -- "$work_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'macOS guest login failed: %s\n' "$*" >&2
  exit 1
}

[[ -n "$tenant_name" ]] || fail "EAI_HARNESS_TENANT_NAME is required."
[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || fail "EAI_HARNESS_TENANT_ID must be a tenant UUID."
[[ -n "$test_email" && "$test_email" != *[[:space:]]* ]] || fail "EAI_HARNESS_USER_EMAIL is required."
[[ "$login_url" == "https://www.enterpriseaigroup.com/sign-in" ]] \
  || fail "EAI_HARNESS_LOGIN_URL must be the supported Enterprise AI Group sign-in page."
command -v prlctl >/dev/null 2>&1 || fail "prlctl is not installed."
command -v node >/dev/null 2>&1 || fail "Node.js is not installed on the host."
command -v security >/dev/null 2>&1 || fail "The macOS Keychain command is unavailable."
command -v swiftc >/dev/null 2>&1 || fail "The Swift compiler required for private local OCR is unavailable."
[[ -f "$input_helper" ]] || fail "The Parallels input helper is missing."
[[ -f "$ocr_source" ]] || fail "The screenshot OCR helper is missing."

if [[ ! -x "$ocr_binary" || "$ocr_source" -nt "$ocr_binary" ]]; then
  swiftc -O "$ocr_source" -o "$ocr_binary" >/dev/null \
    || fail "The screenshot OCR helper could not be compiled."
fi

# Check only the protected item's service/account metadata before any
# snapshot-changing caller proceeds. Deliberately omit both `-w` and `-g` so
# the secret is not read or printed during preflight.
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

macos_prl_current_user_configure "$vm_name" testmac "$work_dir" \
  || fail "The signed-in Test Mac user and Aqua session could not be verified."

input() {
  node "$input_helper" --vm "$vm_name" "$@"
}

screen_has() {
  local pattern="$1"
  local screenshot
  local match_status=2
  screenshot="$work_dir/screen.png"
  if prlctl capture "$vm_name" --file "$screenshot" >/dev/null 2>&1; then
    set +e
    EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
    match_status=$?
    set -e
  fi
  rm -f "$screenshot"
  [[ "$match_status" == 0 ]]
}

wait_for_screen() {
  local expected="$1"
  local attempts="${2:-60}"
  for _ in $(seq 1 "$attempts"); do
    screen_has "$expected" && return 0
    sleep 1
  done
  return 1
}

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
  macos_prl_signed_in_user_exec /usr/bin/open "$login_url" >/dev/null 2>&1 \
    || fail "Safari could not open the Enterprise AI Group sign-in page."

  public_sign_in_ready=0
  portal_sign_in_ready=0
  login_page_observations=0
  for _ in $(seq 1 30); do
    if portal_is_ready; then
      fail "The restored Test Mac already has an authenticated portal session; cached browser authentication is not valid release evidence."
    fi
    if screen_has "Sign in to your account" && screen_has "Continue with Email"; then
      public_sign_in_ready=1
      login_page_observations=$((login_page_observations + 1))
      [[ "$login_page_observations" -ge 3 ]] && break
    fi
    sleep 1
  done

  [[ "$public_sign_in_ready" == 1 ]] \
    || fail "The Enterprise AI Group sign-in page did not become ready."
  printf 'PUBLIC_SIGN_IN_PAGE_READY\n'

  # On the approved 29-8-2026 Test Mac snapshot, ten Option-Tab key presses
  # move from a newly opened Safari page to the single protected handoff link.
  # The visible enterpriseaigroup.com entry point must be exercised; do not
  # bypass it by opening the admin-portal URL directly.
  input combo alt+tab --repeat 10
  input key enter

  for _ in $(seq 1 60); do
    if portal_is_ready; then
      fail "The restored Test Mac reached the authenticated portal before credentials were entered; cached browser authentication is not valid release evidence."
    fi
    if screen_has "Sign in with Microsoft"; then
      portal_sign_in_ready=1
      break
    fi
    sleep 1
  done

  [[ "$portal_sign_in_ready" == 1 ]] \
    || fail "The Enterprise AI admin-portal handoff did not become ready."
  printf 'PORTAL_LOGIN_PAGE_READY\n'

  # Safari requires Option-Tab to include page buttons in keyboard focus. This
  # focuses the single Microsoft federation button without coordinate clicking.
  input combo alt+tab
  input key enter

  microsoft_email_ready=0
  for _ in $(seq 1 60); do
    if screen_has "Email address"; then
      microsoft_email_ready=1
      break
    fi
    if screen_has "Enter password"; then
      fail "Microsoft skipped the required email stage; remembered account state is not valid release evidence."
    fi
    sleep 1
  done
  [[ "$microsoft_email_ready" == 1 ]] \
    || fail "The supported Microsoft email page did not become ready."
  printf 'MICROSOFT_EMAIL_STAGE_READY\n'

  # The username is a protected runtime input. It is passed only over stdin as
  # virtual key codes and is never printed by the input helper.
  printf '%s' "$test_email" | input type --stdin
  input key enter
  wait_for_screen "Enter password" 60 || fail "The password page did not become ready."
  printf 'MICROSOFT_PASSWORD_STAGE_READY\n'

  # Stream the Keychain value directly into the virtual keyboard encoder. Never
  # use prlctl --password, shell tracing, clipboard sharing, or a typed argv value.
  /usr/bin/security find-generic-password -s "$keychain_service" -a "$test_email" -w \
    | input type --stdin
  input key enter

  # Safari may offer to save the password over Microsoft's stay-signed-in page.
  # Detect both states from the captured guest framebuffer, dismiss only the
  # local Safari prompt, then activate Microsoft's affirmative default action.
  post_password_stage=""
  for _ in $(seq 1 40); do
    if portal_is_ready; then
      post_password_stage=portal
      break
    fi
    if screen_has "Save Password?"; then
      post_password_stage=save-password
      break
    fi
    if screen_has "Stay signed in?"; then
      post_password_stage=stay-signed-in
      break
    fi
    sleep 1
  done
  [[ -n "$post_password_stage" ]] || fail "Microsoft sign-in did not advance after password submission."
  if [[ "$post_password_stage" == save-password ]]; then
    input key escape
    wait_for_screen "Stay signed in?" 40 || fail "Microsoft's stay-signed-in page did not become ready."
    post_password_stage=stay-signed-in
  fi
  if [[ "$post_password_stage" == stay-signed-in ]]; then
    input key enter
  fi

  wait_for_portal 120 || fail "The authenticated Enterprise AI tenant did not become ready."
  printf 'AUTHENTICATED_PORTAL_READY\n'
  [[ "$mode" == portal ]] && exit 0
fi

# The portal session and CLI token are separate. Once the supported portal has
# established Microsoft SSO, `eai login` can complete its localhost callback
# without receiving or storing the account password itself.
guest_user="$MACOS_PRL_CURRENT_USER_NAME"
[[ -n "$guest_user" && "$guest_user" != root ]] || fail "The signed-in guest user could not be resolved."
guest_home="$MACOS_PRL_CURRENT_USER_HOME"
[[ "$guest_home" == /Users/* ]] || fail "The signed-in guest home directory could not be resolved."
guest_node="$guest_home/.eai-setup/node/bin/node"
guest_cli="$guest_home/.eai-setup/npm-global/lib/node_modules/@enterpriseai/cli/dist/index.js"
macos_prl_current_user_exec_idempotent /bin/test -x "$guest_node" >/dev/null 2>&1 \
  || fail "The EAI-managed Node runtime required for CLI login is not installed."
macos_prl_current_user_exec_idempotent /bin/test -f "$guest_cli" >/dev/null 2>&1 \
  || fail "The EAI CLI required for login is not installed."

cli_identity_is_active() {
  local identity_file="$work_dir/whoami.txt"
  local match_status=1
  if macos_prl_current_user_exec_idempotent "$guest_node" "$guest_cli" whoami >"$identity_file" 2>/dev/null; then
    if grep -Fq "$test_email" "$identity_file" \
      && grep -Eiq 'Status[[:space:]:]+Active' "$identity_file"; then
      match_status=0
    fi
  fi
  rm -f "$identity_file"
  [[ "$match_status" == 0 ]]
}

cli_tenant_matches() {
  local tenant_file="$work_dir/tenants.json"
  local match_status=1
  if macos_prl_current_user_exec_idempotent "$guest_node" "$guest_cli" tenant list --format json >"$tenant_file" 2>/dev/null; then
    if EAI_EXPECTED_TENANT_ID="$tenant_id" EAI_EXPECTED_TENANT_NAME="$tenant_name" \
      node --input-type=module - "$tenant_file" <<'NODE'
import fs from "node:fs";

const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const match = payload.tenants?.some((tenant) =>
  tenant.id === process.env.EAI_EXPECTED_TENANT_ID
  && tenant.displayName === process.env.EAI_EXPECTED_TENANT_NAME
  && tenant.directMembership === true
  && tenant.isActive !== false
);
if (!match) process.exitCode = 1;
NODE
    then
      match_status=0
    fi
  fi
  rm -f "$tenant_file"
  [[ "$match_status" == 0 ]]
}

# Always refresh the CLI token in a clean-snapshot run. `eai whoami` can exit
# successfully while reporting an expired token, so its process status alone
# is not authentication evidence. This persistent browser-callback action is
# deliberately launched once through the verified Aqua/user session rather than
# through the retryable current-user transport.
cli_output="$work_dir/cli-login.txt"
cli_status=1
cli_finished=0
macos_prl_signed_in_user_exec "$guest_node" "$guest_cli" login >"$cli_output" 2>&1 &
cli_pid=$!
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
rm -f "$cli_output"
[[ "$cli_finished" == 1 && "$cli_status" == 0 ]] || fail "The EAI CLI browser callback did not complete."

cli_authenticated=0
for _ in $(seq 1 20); do
  if cli_identity_is_active; then
    cli_authenticated=1
    break
  fi
  sleep 0.5
done
[[ "$cli_authenticated" == 1 ]] || fail "The EAI CLI session could not be verified after portal login."
cli_tenant_matches || fail "The configured harness tenant is not available to the active EAI CLI account."
printf 'AUTHENTICATED_PORTAL_AND_CLI_READY\n'
