#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'VM adapter preflight failed: %s\n' "$*" >&2
  exit 1
}

platform="${1:-}"
vm_name="${2:-}"
snapshot_id="${3:-}"

case "$platform" in
  macos|windows|ubuntu) ;;
  *) fail "the platform must be macos, windows, or ubuntu." ;;
esac

[[ "$(uname -s)" == Darwin ]] \
  || fail "Parallels VM adapters must run on the macOS release host."
[[ -n "$vm_name" && ${#vm_name} -le 128 && "$vm_name" != *$'\n'* && "$vm_name" != *$'\r'* ]] \
  || fail "the configured VM name is invalid."
[[ "$snapshot_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || fail "the configured snapshot ID is not a UUID."

prlctl_bin='/Applications/Parallels Desktop.app/Contents/MacOS/prlctl'
[[ -x "$prlctl_bin" ]] || fail "the signed Parallels prlctl binary is unavailable."
/usr/bin/codesign --verify --deep --strict "$prlctl_bin" >/dev/null 2>&1 \
  || fail "the signed Parallels prlctl binary does not pass macOS signature verification."

# These are deliberately read-only Parallels queries. Preflight must never
# restore, start, stop, resume, suspend, or execute a command in a guest.
vm_info="$("$prlctl_bin" list "$vm_name" --info 2>/dev/null)" \
  || fail "the configured VM is not available."
grep -Fqx "Name: $vm_name" <<<"$vm_info" \
  || fail "Parallels returned information for a different VM."
guest_tools_state="$(sed -n 's/^GuestTools: state=\([^ ]*\) version=.*/\1/p' <<<"$vm_info" | head -n 1)"
case "$platform:$guest_tools_state" in
  macos:installed|windows:installed|ubuntu:installed|windows:outdated|ubuntu:outdated) ;;
  macos:*) fail "The macOS guest requires current Parallels Tools for UI control." ;;
  *) fail "Parallels Tools are unavailable in this guest." ;;
esac
grep -Fq "BIOS type: efi-arm64" <<<"$vm_info" \
  || fail "the configured VM is not ARM64."

case "$platform" in
  macos) grep -Fqx "OS: macosx" <<<"$vm_info" || fail "the configured VM is not macOS." ;;
  windows) grep -Eq '^OS: win-' <<<"$vm_info" || fail "the configured VM is not Windows." ;;
  ubuntu) grep -Fqx "OS: ubuntu" <<<"$vm_info" || fail "the configured VM is not Ubuntu." ;;
esac

snapshot_list="$("$prlctl_bin" snapshot-list "$vm_name" 2>/dev/null)" \
  || fail "the configured VM snapshot list is unavailable."
grep -Fq "{$snapshot_id}" <<<"$snapshot_list" \
  || fail "the configured reset snapshot is not available for this VM."

printf '{"schemaVersion":"eai.vm-adapter-preflight.v1","status":"ready","platform":"%s","architecture":"arm64","vm":"verified","snapshot":"verified","parallelsTools":"%s","mutationAttempted":false}\n' "$platform" "$guest_tools_state"
