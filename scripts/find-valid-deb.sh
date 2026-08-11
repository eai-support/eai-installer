#!/usr/bin/env bash

set -euo pipefail

root="${1:-src-tauri/target}"

while IFS= read -r -d '' candidate; do
  if dpkg-deb --contents "$candidate" | awk '$NF ~ /(^|\/)usr\/bin\/eai-setup$/ { found = 1 } END { exit found ? 0 : 1 }'; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done < <(find "$root" -type f -path '*/bundle/deb/*.deb' -print0)

printf 'No Debian package containing /usr/bin/eai-setup was found under %s\n' "$root" >&2
exit 1
