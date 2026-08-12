#!/usr/bin/env bash

set -euo pipefail

root="${1:-src-tauri/target}"

while IFS= read -r -d '' candidate; do
  if hdiutil imageinfo "$candidate" >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done < <(find "$root" -type f -path '*/bundle/dmg/*.dmg' -print0)

printf 'No valid macOS disk image was found under %s\n' "$root" >&2
exit 1
