#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
npm test
if command -v cargo >/dev/null 2>&1; then
  cargo check --manifest-path src-tauri/Cargo.toml
else
  echo "cargo is not installed; CI must run the Tauri compile check before release." >&2
  exit 1
fi

echo "release preflight passed; native signing is verified by the release workflow"
