#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: test-macos-dev.sh /path/to/EAI\ Setup.app}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
entitlements="${script_dir}/../src-tauri/Entitlements.plist"
if [[ "$app" != *.app || ! -d "$app" ]]; then
  echo "Expected a macOS .app bundle: $app" >&2
  exit 2
fi
if [[ ! -f "$entitlements" ]]; then
  echo "Expected macOS entitlements: $entitlements" >&2
  exit 2
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/eai-setup-dev-test.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
copy="$staging/EAI Setup.app"

# CI builds are intentionally unsigned. Re-sign only this disposable copy so
# codesign can validate the bundle before the runtime smoke test.
ditto "$app" "$copy"
codesign --force --deep --options runtime --entitlements "$entitlements" --sign - "$copy"
codesign --verify --deep --strict --verbose=2 "$copy"
xattr -dr com.apple.quarantine "$copy" 2>/dev/null || true

"$copy/Contents/MacOS/eai-setup" >"$staging/app.log" 2>&1 &
pid=$!
for _ in $(seq 1 15); do
  if kill -0 "$pid" 2>/dev/null; then
    echo "macOS development app launched successfully"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done

echo "macOS development app exited before the runtime check completed" >&2
cat "$staging/app.log" >&2 || true
exit 1
