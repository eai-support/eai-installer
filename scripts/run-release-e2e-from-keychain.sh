#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
source "$ROOT/scripts/load-release-e2e-keychain.sh" || fail "Protected release-test values could not be loaded from the host Keychain."
export EAI_VM_DRIVER=command
export EAI_VM_MACOS_COMMAND="$ROOT/scripts/run-macos-guest-test.sh"
export EAI_VM_WINDOWS_COMMAND="$ROOT/scripts/run-windows-guest-test.sh"
export EAI_VM_UBUNTU_COMMAND="$ROOT/scripts/run-ubuntu-guest-test.sh"

# Keep the host display, user session, and system awake for exact Parallels
# window capture and consent monitoring. This cannot unlock an already locked
# Mac; the preflight above enforces an unlocked starting desktop.
exec caffeinate -dimsu "$ROOT/release.sh" diagnostic-e2e "$@"
