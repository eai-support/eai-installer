#!/usr/bin/env bash

set -euo pipefail

vm_name="${EAI_MACOS_VM_NAME:-macOS}"
download_url="${EAI_VM_DOWNLOAD_URL:-}"
host_asset="${EAI_VM_ASSET:-}"
guest_dmg="/tmp/eai-setup-under-test.dmg"
guest_mount="/tmp/eai-setup-under-test"

fail() {
  printf 'macOS VM preparation failed: %s\n' "$*" >&2
  exit 1
}

guest() {
  prlctl exec "$vm_name" "$@"
}

command -v prlctl >/dev/null 2>&1 || fail "Parallels prlctl is not installed."
[[ -n "$download_url" ]] || fail "EAI_VM_DOWNLOAD_URL is required."
[[ "$download_url" =~ ^https?://[^[:space:]]+$ ]] || fail "EAI_VM_DOWNLOAD_URL must be a complete HTTP or HTTPS URL."
[[ -f "$host_asset" ]] || fail "EAI_VM_ASSET must point to the validated host-side DMG."
[[ "$host_asset" == *.dmg ]] || fail "EAI_VM_ASSET must be a DMG."

vm_status="$(prlctl status "$vm_name" 2>/dev/null || true)"
[[ "$vm_status" == *"running"* ]] || fail "The Parallels VM '$vm_name' is not running."
[[ "$(guest /usr/bin/uname -s)" == "Darwin" ]] || fail "The selected Parallels guest is not macOS."
guest_arch="$(guest /usr/bin/uname -m)"
[[ "$guest_arch" == "arm64" || "$guest_arch" == "x86_64" ]] || fail "Unsupported macOS guest architecture: $guest_arch"

printf 'Downloading the validated installer inside %s...\n' "$vm_name"
guest /usr/bin/curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --output "$guest_dmg" "$download_url"

stable_size=""
stable_reads=0
for _ in {1..30}; do
  current_size="$(guest /usr/bin/stat -f %z "$guest_dmg" 2>/dev/null || true)"
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
guest_hash="$(guest /usr/bin/shasum -a 256 "$guest_dmg" | /usr/bin/awk '{print $1}')"
[[ "$guest_hash" == "$expected_hash" ]] || fail "The guest DMG checksum does not match the CI artifact."

guest /usr/bin/hdiutil imageinfo "$guest_dmg" >/dev/null || fail "macOS rejected the DMG structure."

# Unsigned pull-request artifacts are only suitable for controlled VM testing.
# Customer releases must remain signed and notarized and must not use this flag.
if [[ "${EAI_VM_ALLOW_UNSIGNED_TEST:-0}" == "1" ]]; then
  guest /usr/bin/xattr -d com.apple.quarantine "$guest_dmg" >/dev/null 2>&1 || true
fi

guest /usr/bin/hdiutil detach "$guest_mount" -quiet >/dev/null 2>&1 || true
guest /bin/rm -rf "$guest_mount"
guest /bin/mkdir -p "$guest_mount"
guest /usr/bin/hdiutil attach "$guest_dmg" -nobrowse -readonly -mountpoint "$guest_mount" >/dev/null

app_count="$(guest /usr/bin/find "$guest_mount" -maxdepth 1 -name '*.app' -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$app_count" == "1" ]] || fail "The mounted DMG must contain exactly one application."

guest /usr/bin/open "file://$guest_mount"
printf 'READY_FOR_UI vm=%s arch=%s bytes=%s sha256=%s\n' "$vm_name" "$guest_arch" "$stable_size" "$guest_hash"
