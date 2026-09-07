#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/guest-test-lib.sh
source "$ROOT/scripts/guest-test-lib.sh"

vm_name="${EAI_UBUNTU_VM_NAME:-Ubuntu 24.04.3 ARM64}"
snapshot_id="${EAI_UBUNTU_SNAPSHOT_ID:-00f4cb1b-09ea-4f06-b41b-3d1d2085e8c7}"
if [[ "${1:-}" == "--preflight" ]]; then
  [[ "$#" -eq 1 ]] || guest_test_fail "The Ubuntu adapter preflight accepts no additional arguments."
  exec "$ROOT/scripts/vm-adapter-preflight.sh" ubuntu "$vm_name" "$snapshot_id"
fi

# Keep the public adapter path stable while the Ubuntu-only core carries the
# fail-closed clean-state, login, installer, prerequisite, and handoff proofs.
hardened_core="$ROOT/scripts/ubuntu-guest-test-core.sh"
[[ -f "$hardened_core" ]] || guest_test_fail "The hardened Ubuntu adapter core is missing."
exec /bin/bash "$hardened_core" "$@"
