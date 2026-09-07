#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
tenant_id_service="${EAI_TENANT_ID_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-id}"
tenant_name_service="${EAI_TENANT_NAME_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-name}"
keychain_account="${EAI_TENANT_KEYCHAIN_ACCOUNT:-release-e2e}"

fail() {
  printf 'Release E2E Keychain launcher failed: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == Darwin ]] || fail "The local Keychain launcher must run on the Parallels Mac host."
command -v security >/dev/null 2>&1 || fail "The macOS Keychain command is unavailable."
command -v caffeinate >/dev/null 2>&1 || fail "The macOS power-assertion command is unavailable."
[[ -x /usr/sbin/ioreg ]] || fail "The macOS console-state command is unavailable."
[[ "$#" -ge 1 ]] || fail "Pass the normal diagnostic-e2e arguments, beginning with the release version."

# A power assertion prevents a new lock but cannot expose a desktop that is
# already locked. Refuse before any snapshot is restored: the Windows consent
# monitor must capture the actual Parallels console, never the lock screen.
console_state="$(/usr/sbin/ioreg -n Root -d1)"
if [[ "$console_state" == *'"IOConsoleLocked" = Yes'* ]]; then
  fail "Unlock the macOS desktop before starting release E2E; no VM was touched."
fi
unset console_state

# The account is stored as Keychain metadata; the password is never read here.
# It is streamed into the macOS VM only by login-macos-guest.sh.
test_email="$(/usr/bin/security find-generic-password -s "$account_service" 2>&1 \
  | /usr/bin/awk -F '"' '$2 == "acct" { print $4; exit }')"
tenant_id="$(/usr/bin/security find-generic-password -s "$tenant_id_service" -a "$keychain_account" -w 2>/dev/null || true)"
tenant_name="$(/usr/bin/security find-generic-password -s "$tenant_name_service" -a "$keychain_account" -w 2>/dev/null || true)"

[[ -n "$test_email" && "$test_email" != *[[:space:]]* ]] || fail "The release-test account is missing from the host Keychain."
[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || fail "The harness tenant ID is missing from the host Keychain."
[[ -n "$tenant_name" ]] || fail "The harness tenant name is missing from the host Keychain."

export EAI_HARNESS_USER_EMAIL="$test_email"
export EAI_HARNESS_TENANT_ID="$tenant_id"
export EAI_HARNESS_TENANT_NAME="$tenant_name"
export EAI_VM_DRIVER=command
export EAI_VM_MACOS_COMMAND="$ROOT/scripts/run-macos-guest-test.sh"
export EAI_VM_WINDOWS_COMMAND="$ROOT/scripts/run-windows-guest-test.sh"
export EAI_VM_UBUNTU_COMMAND="$ROOT/scripts/run-ubuntu-guest-test.sh"

# Keep the host display, user session, and system awake for exact Parallels
# window capture and consent monitoring. This cannot unlock an already locked
# Mac; the preflight above enforces an unlocked starting desktop.
exec caffeinate -dimsu "$ROOT/release.sh" diagnostic-e2e "$@"
