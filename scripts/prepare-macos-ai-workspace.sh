#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/guest-test-lib.sh"
source "$ROOT/scripts/parallels-macos-current-user.sh"

vm_name="${EAI_MACOS_VM_NAME:-macOS}"
guest_user="${EAI_VM_GUEST_USER:-testmac}"
vscode_version="1.136.1"
vscode_commit="a44adf7f53e00964ab890f9f8758a334f1fc15bc"
pinned_hash="bd15a1b26cd10ba84900f7bd30f21d51eef268828e1e15a8ac1f97f99620bbe5"
download_url="https://update.code.visualstudio.com/${vscode_version}/darwin-arm64/stable"
guest_archive="/tmp/eai-release-e2e-vscode.zip"
guest_headers="/tmp/eai-release-e2e-vscode.headers"
guest_stage="/tmp/eai-release-e2e-vscode-stage"
guest_app="$guest_stage/Visual Studio Code.app"
installed_app="/Applications/Visual Studio Code.app"
installed_cli="$installed_app/Contents/Resources/app/bin/code"
evidence_file="$(dirname "${EAI_VM_RESULT_FILE:?EAI_VM_RESULT_FILE is required}")/macos-ai-workspace.json"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$work_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  guest_test_fail "$*"
}

guest_user_shell() {
  macos_prl_current_user_shell_idempotent
}

guest_root_shell() {
  prlctl exec "$vm_name" /bin/sh
}

guest_value() {
  local script="$1"
  printf '%s\n' "$script" | guest_user_shell | tr -d '\r'
}

guest_verify_app() {
  local app_path="$1"
  printf '%s\n' \
    "set -e" \
    "/bin/test -d '$app_path'" \
    "/bin/test -x '$app_path/Contents/Resources/app/bin/code'" \
    "/usr/bin/codesign --verify --deep --strict '$app_path'" \
    "/usr/sbin/spctl --assess --type execute --verbose=2 '$app_path'" \
    "team=\$(/usr/bin/codesign -dv --verbose=4 '$app_path' 2>&1 | /usr/bin/awk -F= '\$1 == \"TeamIdentifier\" { print \$2; exit }')" \
    "[ \"\$team\" = UBF8T346G9 ]" \
    "bundle=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$app_path/Contents/Info.plist')" \
    "[ \"\$bundle\" = com.microsoft.VSCode ]" \
    "/bin/test -d '$app_path/Contents/Resources/app/extensions/copilot'" \
    "/usr/bin/file '$app_path/Contents/MacOS/Code' | /usr/bin/grep -Fq arm64" \
    | guest_user_shell
}

guest_test_require prlctl
[[ "$guest_user" == testmac ]] || fail "The macOS AI-workspace harness must run as testmac."

macos_prl_current_user_configure "$vm_name" "$guest_user" "$work_dir" \
  || fail "The macOS current-user identity and Aqua session could not be verified."
actual_user="$MACOS_PRL_CURRENT_USER_NAME"
[[ "$actual_user" == "$guest_user" ]] || fail "The macOS current-user channel is not $guest_user."

source="existing"
expected_hash=""
archive_hash=""

if ! printf "/bin/test -d '%s'\n" "$installed_app" | guest_user_shell >/dev/null 2>&1; then
  source="official-download"
  printf '%s\n' \
    "set -e" \
    "/bin/rm -rf '$guest_stage'" \
    "/bin/rm -f '$guest_archive' '$guest_headers'" \
    "/bin/mkdir -p '$guest_stage'" \
    "/usr/bin/curl --fail --show-error --location --retry 5 --retry-all-errors --connect-timeout 30 --dump-header '$guest_headers' --output '$guest_archive' '$download_url'" \
    | guest_user_shell

  expected_hash="$(guest_value "/usr/bin/awk 'tolower(\$1) == \"x-sha256:\" { gsub(/\\r/, \"\", \$2); print tolower(\$2); exit }' '$guest_headers'")"
  archive_hash="$(guest_value "/usr/bin/shasum -a 256 '$guest_archive' | /usr/bin/awk '{ print tolower(\$1) }'")"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || fail "The official VS Code response did not provide a SHA-256 header."
  [[ "$expected_hash" == "$pinned_hash" ]] || fail "Microsoft's response hash does not match the pinned VS Code release-test dependency."
  [[ "$archive_hash" == "$expected_hash" ]] || fail "The downloaded VS Code archive hash did not match Microsoft's response header."

  printf '%s\n' \
    "set -e" \
    "/bin/rm -rf '$guest_stage'" \
    "/bin/mkdir -p '$guest_stage'" \
    "/usr/bin/ditto -x -k '$guest_archive' '$guest_stage'" \
    | guest_user_shell
  guest_verify_app "$guest_app" || fail "The staged VS Code application failed signature, publisher, bundle, or ARM64 verification."

  # VS Code is a release-test harness dependency, not an EAI prerequisite.
  # Install it through Parallels' protected root channel; its GUI is launched
  # later only in testmac's verified Aqua session.
  printf '%s\n' \
    "set -e" \
    "/bin/rm -rf '$installed_app'" \
    "/usr/bin/ditto '$guest_app' '$installed_app'" \
    "/usr/sbin/chown -R root:wheel '$installed_app'" \
    | guest_root_shell
fi

guest_verify_app "$installed_app" || fail "The installed VS Code application failed verification."
installed_version="$(guest_value "/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$installed_app/Contents/Info.plist'")"
[[ "$installed_version" == "$vscode_version" ]] || fail "Expected VS Code $vscode_version, found ${installed_version:-unknown}."
cli_version="$(guest_value "'$installed_cli' --version 2>/dev/null | /usr/bin/head -n 1")"
[[ "$cli_version" == "$installed_version" ]] || fail "The VS Code CLI version does not match the installed application."

EAI_AI_WORKSPACE_SOURCE="$source" \
EAI_AI_WORKSPACE_VERSION="$installed_version" \
EAI_AI_WORKSPACE_COMMIT="$vscode_commit" \
EAI_AI_WORKSPACE_EXPECTED_HASH="$expected_hash" \
EAI_AI_WORKSPACE_ARCHIVE_HASH="$archive_hash" \
EAI_AI_WORKSPACE_DOWNLOAD_URL="$download_url" \
node --input-type=module - "$evidence_file" <<'NODE'
import fs from "node:fs";

const evidenceFile = process.argv[2];
const evidence = {
  status: "prepared",
  surfaceId: "vscode-copilot",
  product: "Visual Studio Code",
  source: process.env.EAI_AI_WORKSPACE_SOURCE,
  version: process.env.EAI_AI_WORKSPACE_VERSION,
  commit: process.env.EAI_AI_WORKSPACE_COMMIT,
  architecture: "arm64",
  applicationPath: "/Applications/Visual Studio Code.app",
  downloadUrl: process.env.EAI_AI_WORKSPACE_DOWNLOAD_URL,
  expectedSha256: process.env.EAI_AI_WORKSPACE_EXPECTED_HASH || null,
  archiveSha256: process.env.EAI_AI_WORKSPACE_ARCHIVE_HASH || null,
  signatureVerified: true,
  gatekeeperAccepted: true,
  bundledCopilotVerified: true,
  teamIdentifier: "UBF8T346G9",
  bundleIdentifier: "com.microsoft.VSCode",
  preparedAt: new Date().toISOString(),
};
fs.writeFileSync(evidenceFile, `${JSON.stringify(evidence, null, 2)}\n`);
NODE

printf 'AI_WORKSPACE_READY surface=vscode-copilot version=%s source=%s\n' "$installed_version" "$source"
