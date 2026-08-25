#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI_DIR="${EAI_CLI_SOURCE:-${INSTALLER_DIR}/../eai}"

if [[ ! -f "${CLI_DIR}/package.json" ]]; then
  echo "The sibling eai checkout was not found at: ${CLI_DIR}"
  echo "Place eai and eai-installer beside each other, then run npm run dev again."
  exit 1
fi

for command_name in node npm cargo; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Local setup needs ${command_name}, but it is not installed yet."
    echo "On macOS, run: brew install rust"
    exit 1
  fi
done

USER_DIR="$(node -p 'require("node:os").homedir()')"
SETUP_PREFIX="${USER_DIR}/.eai-setup/npm-global"

echo "Preparing the local EAI CLI..."
npm --prefix "${CLI_DIR}" install --no-audit --no-fund
npm --prefix "${CLI_DIR}" run build
npm install --global --prefix "${SETUP_PREFIX}" "${CLI_DIR}"

echo "Opening the local EAI Setup app..."
EAI_SETUP_ALLOW_LOCAL_CLI=1 cargo run --manifest-path "${INSTALLER_DIR}/src-tauri/Cargo.toml"
