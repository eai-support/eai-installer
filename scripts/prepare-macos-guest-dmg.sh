#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/parallels-macos-current-user.sh"

vm_name="${EAI_MACOS_VM_NAME:-macOS}"
guest_user="${EAI_VM_GUEST_USER:-}"
download_url="${EAI_VM_DOWNLOAD_URL:-}"
host_asset="${EAI_VM_ASSET:-}"
guest_dmg="/tmp/eai-setup-under-test.dmg"
guest_mount="/tmp/eai-setup-under-test"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$work_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'macOS VM preparation failed: %s\n' "$*" >&2
  exit 1
}

guest_idempotent() {
  macos_prl_current_user_exec_idempotent "$@"
}

guest_asuser() {
  macos_prl_signed_in_user_exec "$@"
}

command -v prlctl >/dev/null 2>&1 || fail "Parallels prlctl is not installed."
[[ -n "$guest_user" ]] || fail "EAI_VM_GUEST_USER is required."
[[ -n "$download_url" ]] || fail "EAI_VM_DOWNLOAD_URL is required."
[[ "$download_url" =~ ^https?://[^[:space:]]+$ ]] || fail "EAI_VM_DOWNLOAD_URL must be a complete HTTP or HTTPS URL."
[[ -f "$host_asset" ]] || fail "EAI_VM_ASSET must point to the validated host-side DMG."
[[ "$host_asset" == *.dmg ]] || fail "EAI_VM_ASSET must be a DMG."

vm_status="$(prlctl status "$vm_name" 2>/dev/null || true)"
[[ "$vm_status" == *"running"* ]] || fail "The Parallels VM '$vm_name' is not running."
macos_prl_current_user_configure "$vm_name" "$guest_user" "$work_dir" \
  || fail "The requested signed-in macOS user and Aqua session could not be verified."
actual_user="$MACOS_PRL_CURRENT_USER_NAME"
actual_uid="$MACOS_PRL_CURRENT_USER_UID"
actual_home="$MACOS_PRL_CURRENT_USER_HOME"
guest_os="$(guest_idempotent /usr/bin/uname -s | tr -d '\r\n')"
[[ "$guest_os" == "Darwin" ]] || fail "The selected Parallels guest is not macOS."
[[ "$actual_user" == "$guest_user" ]] || fail "The macOS guest command is not running as the requested signed-in user."
[[ "$actual_uid" =~ ^[1-9][0-9]*$ ]] || fail "The macOS clean-machine test must not run as root."
[[ "$actual_home" == /Users/* ]] || fail "The signed-in macOS user's home directory could not be resolved."
guest_idempotent /bin/test -d "$actual_home" || fail "The signed-in macOS user's home directory does not exist."
guest_arch="$(guest_idempotent /usr/bin/uname -m | tr -d '\r\n')"
[[ "$guest_arch" == "arm64" || "$guest_arch" == "x86_64" ]] || fail "Unsupported macOS guest architecture: $guest_arch"

printf 'Downloading the validated installer inside %s...\n' "$vm_name"
guest_asuser /usr/bin/curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --output "$guest_dmg" "$download_url"

stable_size=""
stable_reads=0
for _ in {1..30}; do
  current_size="$(guest_idempotent /usr/bin/stat -f %z "$guest_dmg" 2>/dev/null || true)"
  if [[ "$current_size" =~ ^[1-9][0-9]*$ && "$current_size" == "$stable_size" ]]; then
    stable_reads=$((stable_reads + 1))
  else
    stable_size="$current_size"
    stable_reads=0
  fi
  (( stable_reads >= 2 )) && break
  sleep 1
done
[[ "$stable_reads" -ge 2 ]] || fail "The DMG did not reach a stable, non-zero size."

expected_hash="$(/usr/bin/shasum -a 256 "$host_asset" | /usr/bin/awk '{print $1}')"
guest_hash="$(guest_idempotent /usr/bin/shasum -a 256 "$guest_dmg" | /usr/bin/awk '{print $1}')"
[[ "$guest_hash" == "$expected_hash" ]] || fail "The guest DMG checksum does not match the CI artifact."

guest_idempotent /usr/bin/hdiutil imageinfo "$guest_dmg" >/dev/null || fail "macOS rejected the DMG structure."

# Unsigned pull-request artifacts are only suitable for controlled VM testing.
# Customer releases must remain signed and notarized and must not use this flag.
if [[ "${EAI_VM_ALLOW_UNSIGNED_TEST:-0}" == "1" ]]; then
  guest_asuser /usr/bin/xattr -d com.apple.quarantine "$guest_dmg" >/dev/null 2>&1 || true
fi

guest_asuser /usr/bin/hdiutil detach "$guest_mount" -quiet >/dev/null 2>&1 || true
guest_asuser /bin/rm -rf "$guest_mount"
guest_asuser /bin/mkdir -p "$guest_mount"
guest_asuser /usr/bin/hdiutil attach "$guest_dmg" -nobrowse -readonly -mountpoint "$guest_mount" >/dev/null

mounted_apps="$(guest_idempotent /usr/bin/find "$guest_mount" -type d | /usr/bin/awk '/[.]app$/')"
app_count="$(printf '%s\n' "$mounted_apps" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
[[ "$app_count" == "1" ]] || fail "The mounted DMG must contain exactly one application."
[[ "$(/usr/bin/dirname "$mounted_apps")" == "$guest_mount" ]] || fail "The application must be at the top level of the mounted DMG."

# The control channel launches outside the Aqua session. Enter the already
# verified signed-in user's GUI session explicitly so Finder can display the DMG.
guest_asuser /usr/bin/open "file://$guest_mount"
printf 'READY_FOR_UI vm=%s user=%s arch=%s bytes=%s sha256=%s mount=%s\n' "$vm_name" "$actual_user" "$guest_arch" "$stable_size" "$guest_hash" "$guest_mount"
