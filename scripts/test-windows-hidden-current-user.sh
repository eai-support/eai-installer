#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/windows-hidden-current-user.sh
source "$ROOT/scripts/windows-hidden-current-user.sh"

test_dir="$(mktemp -d)"
cleanup() {
  [[ -z "${fake_pid:-}" ]] || kill -KILL "$fake_pid" 2>/dev/null || true
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$test_dir/bin"
cp /bin/sleep "$test_dir/bin/prlctl"
start_seconds=$SECONDS
set +e
PATH="$test_dir/bin:$PATH" windows_hidden_bounded_prlctl 1 30
status=$?
set -e
elapsed=$((SECONDS - start_seconds))

[[ "$status" -ne 0 ]] || {
  printf 'Expected the bounded command to time out.\n' >&2
  exit 1
}
[[ "$elapsed" -lt 5 ]] || {
  printf 'Bounded command took %s seconds.\n' "$elapsed" >&2
  exit 1
}

printf 'Windows hidden-current-user watchdog tests passed.\n'
