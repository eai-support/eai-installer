#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/guest-test-lib.sh
source "$ROOT/scripts/guest-test-lib.sh"
# shellcheck source=scripts/parallels-macos-current-user.sh
source "$ROOT/scripts/parallels-macos-current-user.sh"

vm_name="${EAI_MACOS_VM_NAME:-macOS}"
snapshot_id="${EAI_MACOS_SNAPSHOT_ID:-462d2ce7-701e-4257-a95d-545590e86784}"
expected_cli_version="${EAI_EXPECTED_CLI_VERSION:-3.15.10}"
if [[ "${1:-}" == "--preflight" ]]; then
  [[ "$#" -eq 1 ]] || guest_test_fail "The macOS adapter preflight accepts no additional arguments."
  exec "$ROOT/scripts/vm-adapter-preflight.sh" macos "$vm_name" "$snapshot_id"
fi
mac_admin_service="eai-installer-parallels-macos-admin"
mac_admin_account="testmac"
guest_user="${EAI_VM_GUEST_USER:-$mac_admin_account}"
guest_receipt="/tmp/eai-setup-e2e-receipt.json"
guest_parent="/Users/$guest_user/EAIReleaseTests"
guest_app="/tmp/eai-setup-e2e-app"
executable="$guest_app/Contents/MacOS/eai-setup"
normal_pid_file="/tmp/eai-setup-normal.pid"
e2e_pid_file="/tmp/eai-setup-e2e.pid"
guest_node="/Users/$guest_user/.eai-setup/node/bin/node"
guest_npm_cli="/Users/$guest_user/.eai-setup/node/lib/node_modules/npm/bin/npm-cli.js"
guest_cli="/Users/$guest_user/.eai-setup/npm-global/lib/node_modules/@enterpriseai/cli/dist/index.js"
input_helper="$ROOT/scripts/parallels-input.mjs"
ocr_binary="${TMPDIR:-/tmp}/eai-installer-macos-ocr-match"
work_dir="$(mktemp -d)"
host_receipt="$work_dir/desktop-receipt.json"
host_project_package="$work_dir/project-package.json"
failure_receipt="$work_dir/failure-receipt.json"
failure_package="$work_dir/failure-package.json"
normal_log="$work_dir/normal-app.log"
e2e_log="$work_dir/e2e-app.log"
normal_bridge_pid=""
e2e_bridge_pid=""
phase="preflight"
completed=0

stage() {
  phase="$1"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

input() {
  node "$input_helper" --vm "$vm_name" "$@"
}

screen_has() {
  local pattern="$1"
  local screenshot="$work_dir/screen.png"
  local match_status=2
  if prlctl capture "$vm_name" --file "$screenshot" >/dev/null 2>&1; then
    set +e
    EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
    match_status=$?
    set -e
  fi
  rm -f "$screenshot"
  [[ "$match_status" == 0 ]]
}

guest_process_alive() {
  local pid_file="$1"
  local pid=""
  pid="$(prlctl exec "$vm_name" /bin/cat "$pid_file" 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  prlctl exec "$vm_name" /bin/kill -0 "$pid" >/dev/null 2>&1
}

stop_guest_process() {
  local pid_file="$1"
  local pid=""
  pid="$(prlctl exec "$vm_name" /bin/cat "$pid_file" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    prlctl exec "$vm_name" /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      prlctl exec "$vm_name" /bin/kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 1
    done
    prlctl exec "$vm_name" /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  prlctl exec "$vm_name" /bin/rm -f "$pid_file" >/dev/null 2>&1 || true
}

preserve_sanitized_log() {
  local source_file="$1"
  local destination_file="$2"
  [[ -s "$source_file" ]] || return 0
  node --input-type=module - "$source_file" "$destination_file" <<'NODE'
import fs from "node:fs";

const [source, destination] = process.argv.slice(2);
let content = fs.readFileSync(source, "utf8");
for (const key of ["EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL"]) {
  const value = process.env[key];
  if (value) content = content.split(value).join("[REDACTED]");
}
fs.writeFileSync(destination, content);
NODE
}

write_failure_result() {
  local exact_project_directory=0
  local package_json_copied=0
  local package_json_regular_non_symlink=0
  local receipt_copied=0
  local guest_project=""
  local guest_package=""

  [[ -n "${EAI_VM_RESULT_FILE:-}" && -n "${EAI_VM_APP_STATE_FILE:-}" ]] || return 0
  /bin/rm -f -- "$failure_receipt" "$failure_package"

  # A failed desktop flow may have created its tenant app before its final
  # receipt reached the host. Inspect only the fixed receipt and exact generated
  # project paths. Never enumerate tenant resources or guest directories here.
  if prlctl status "$vm_name" 2>/dev/null | /usr/bin/grep -Fq running; then
    if prlctl exec "$vm_name" /bin/test -f "$guest_receipt" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/test ! -L "$guest_receipt" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/cat "$guest_receipt" >"$failure_receipt" 2>/dev/null; then
      receipt_copied=1
    else
      /bin/rm -f -- "$failure_receipt"
    fi

    if [[ "${EAI_VM_PROJECT_NAME:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      guest_project="$guest_parent/$EAI_VM_PROJECT_NAME"
      guest_package="$guest_project/package.json"
      if prlctl exec "$vm_name" /bin/test -d "$guest_parent" >/dev/null 2>&1 \
        && prlctl exec "$vm_name" /bin/test ! -L "$guest_parent" >/dev/null 2>&1 \
        && prlctl exec "$vm_name" /bin/test -d "$guest_project" >/dev/null 2>&1 \
        && prlctl exec "$vm_name" /bin/test ! -L "$guest_project" >/dev/null 2>&1; then
        exact_project_directory=1
        if prlctl exec "$vm_name" /bin/test -f "$guest_package" >/dev/null 2>&1 \
          && prlctl exec "$vm_name" /bin/test ! -L "$guest_package" >/dev/null 2>&1; then
          package_json_regular_non_symlink=1
          if prlctl exec "$vm_name" /bin/cat "$guest_package" >"$failure_package" 2>/dev/null; then
            package_json_copied=1
          else
            /bin/rm -f -- "$failure_package"
          fi
        fi
      fi
    fi
  fi

  EAI_FAILURE_PHASE="$phase" \
  EAI_FAILURE_RECEIPT_COPIED="$receipt_copied" \
  EAI_FAILURE_EXACT_PROJECT_DIRECTORY="$exact_project_directory" \
  EAI_FAILURE_PACKAGE_REGULAR_NON_SYMLINK="$package_json_regular_non_symlink" \
  EAI_FAILURE_PACKAGE_COPIED="$package_json_copied" \
  node --input-type=module - \
    "$EAI_VM_RESULT_FILE" "$EAI_VM_APP_STATE_FILE" "${EAI_VM_PROJECT_NAME:-unknown}" \
    "$failure_receipt" "$failure_package" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const [resultPath, appStatePath, appName, receiptPath, packagePath] = process.argv.slice(2);
fs.mkdirSync(path.dirname(resultPath), { recursive: true });
fs.mkdirSync(path.dirname(appStatePath), { recursive: true });
const readJson = (filePath) => {
  try {
    const content = fs.readFileSync(filePath, "utf8").trim();
    return content ? JSON.parse(content) : null;
  } catch {
    return null;
  }
};
const receipt = process.env.EAI_FAILURE_RECEIPT_COPIED === "1" ? readJson(receiptPath) : null;
const packageJson = process.env.EAI_FAILURE_PACKAGE_COPIED === "1" ? readJson(packagePath) : null;
const existingResult = readJson(resultPath);
const existingAppState = readJson(appStatePath);
const expectedPackageName = `@eai-tools/${appName}`;
const packageJsonNameMatches = packageJson?.name === expectedPackageName;
const locallyGeneratedProject = process.env.EAI_FAILURE_EXACT_PROJECT_DIRECTORY === "1"
  && process.env.EAI_FAILURE_PACKAGE_REGULAR_NON_SYMLINK === "1"
  && packageJsonNameMatches;
const resultAlreadyProvedCreation = existingResult?.appName === appName && existingResult?.appCreated === true;
const appStateAlreadyProvedCreation = existingAppState?.appName === appName && existingAppState?.appCreated === true;
const appCreated = resultAlreadyProvedCreation
  || appStateAlreadyProvedCreation
  || receipt?.appCreated === true
  || locallyGeneratedProject;
const checkpoint = {
  receiptCopied: process.env.EAI_FAILURE_RECEIPT_COPIED === "1",
  receiptAppCreated: receipt?.appCreated === true,
  exactProjectDirectory: process.env.EAI_FAILURE_EXACT_PROJECT_DIRECTORY === "1",
  packageJsonRegularNonSymlink: process.env.EAI_FAILURE_PACKAGE_REGULAR_NON_SYMLINK === "1",
  packageJsonCopied: process.env.EAI_FAILURE_PACKAGE_COPIED === "1",
  packageJsonNameMatches,
  locallyGeneratedProject,
  appCreated,
  checkedAt: new Date().toISOString(),
};
const allowedCheckStates = new Set(["passed", "failed", "not-run"]);
const requiredChecks = ["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
const checks = Object.fromEntries(requiredChecks.map((name) => {
  const value = receipt?.checks?.[name];
  return [name, allowedCheckStates.has(value) ? value : "not-run"];
}));
const fallbackResult = {
  status: "failed",
  vm: "macos",
  appName,
  appCreated,
  cleanupRequested: true,
  failedPhase: process.env.EAI_FAILURE_PHASE,
  checks,
  failureCheckpoint: checkpoint,
  completedAt: new Date().toISOString(),
  message: `The macOS adapter stopped during ${process.env.EAI_FAILURE_PHASE}.`,
};
const result = existingResult && typeof existingResult === "object"
  ? {
      ...existingResult,
      appCreated,
      cleanupRequested: true,
      failedPhase: existingResult.failedPhase || process.env.EAI_FAILURE_PHASE,
      failureCheckpoint: checkpoint,
    }
  : fallbackResult;
fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
const checkpointState = receipt
  ? "receipt"
  : locallyGeneratedProject ? "exact-local-project-checkpoint" : "not-proven";
const appState = existingAppState && typeof existingAppState === "object"
  ? {
      ...existingAppState,
      appName,
      appCreated,
      state: existingAppState.state && existingAppState.state !== "not-proven"
        ? existingAppState.state
        : checkpointState,
      failureCheckpoint: checkpoint,
    }
  : { appName, appCreated, state: checkpointState, failureCheckpoint: checkpoint };
fs.writeFileSync(appStatePath, `${JSON.stringify(appState, null, 2)}\n`);
fs.writeFileSync(path.join(path.dirname(resultPath), "macos-failure-checkpoint.json"), `${JSON.stringify(checkpoint, null, 2)}\n`);
NODE
}

cleanup() {
  local status=$?
  set +e
  if prlctl status "$vm_name" 2>/dev/null | grep -Fq running; then
    stop_guest_process "$normal_pid_file"
    stop_guest_process "$e2e_pid_file"
  fi
  for bridge_pid in "$normal_bridge_pid" "$e2e_bridge_pid"; do
    if [[ "$bridge_pid" =~ ^[1-9][0-9]*$ ]]; then
      kill "$bridge_pid" 2>/dev/null || true
      wait "$bridge_pid" 2>/dev/null || true
    fi
  done
  if [[ "$completed" != 1 && "$status" != 0 ]]; then
    write_failure_result
    preserve_sanitized_log "$normal_log" "$(dirname "$EAI_VM_RESULT_FILE")/macos-normal-app.log"
    preserve_sanitized_log "$e2e_log" "$(dirname "$EAI_VM_RESULT_FILE")/macos-e2e-app.log"
  fi
  rm -rf -- "$work_dir"
  return "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

semantic_version_at_least() {
  local value="$1"
  local minimum_major="$2"
  local minimum_minor="$3"
  local minimum_patch="$4"
  [[ "$value" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  local major="${BASH_REMATCH[1]}"
  local minor="${BASH_REMATCH[2]}"
  local patch="${BASH_REMATCH[3]}"
  (( major > minimum_major )) \
    || (( major == minimum_major && minor > minimum_minor )) \
    || (( major == minimum_major && minor == minimum_minor && patch >= minimum_patch ))
}

guest_git_version() {
  local developer_dir=""
  developer_dir="$(macos_prl_current_user_exec_idempotent /usr/bin/xcode-select -p 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$developer_dir" == /* && "$developer_dir" != *[[:space:]]* ]] || return 1
  macos_prl_current_user_exec_idempotent /bin/test -x "$developer_dir/usr/bin/git" >/dev/null 2>&1 || return 1
  macos_prl_current_user_exec_idempotent /usr/bin/git --version 2>/dev/null | tr -d '\r\n'
}

guest_node_version() {
  macos_prl_current_user_exec_idempotent /bin/test -x "$guest_node" >/dev/null 2>&1 || return 1
  macos_prl_current_user_exec_idempotent "$guest_node" --version 2>/dev/null | tr -d '\r\n'
}

guest_npm_version() {
  macos_prl_current_user_exec_idempotent /bin/test -f "$guest_npm_cli" >/dev/null 2>&1 || return 1
  macos_prl_current_user_exec_idempotent "$guest_node" "$guest_npm_cli" --version 2>/dev/null | tr -d '\r\n'
}

guest_eai_version() {
  macos_prl_current_user_exec_idempotent /bin/test -f "$guest_cli" >/dev/null 2>&1 || return 1
  macos_prl_current_user_exec_idempotent "$guest_node" "$guest_cli" --version 2>/dev/null | tr -d '\r\n'
}

prerequisite_versions_satisfy_contract() {
  local git_version="$1"
  local node_version="$2"
  local npm_version="$3"
  local eai_version="$4"
  [[ "$git_version" == git\ version* ]] \
    && semantic_version_at_least "$node_version" 24 0 0 \
    && semantic_version_at_least "$npm_version" 1 0 0 \
    && semantic_version_at_least "$eai_version" 3 15 10
}

guest_prerequisites_ready() {
  local git_version=""
  local node_version=""
  local npm_version=""
  local eai_version=""
  git_version="$(guest_git_version || true)"
  node_version="$(guest_node_version || true)"
  npm_version="$(guest_npm_version || true)"
  eai_version="$(guest_eai_version || true)"
  prerequisite_versions_satisfy_contract "$git_version" "$node_version" "$npm_version" "$eai_version"
}

guest_current_command_exists() {
  local command_name="$1"
  printf 'command -v %s >/dev/null 2>&1\n' "$command_name" \
    | macos_prl_current_user_shell_idempotent >/dev/null 2>&1
}

guest_path_exists() {
  local path="$1"
  printf "/bin/test -e '%s'\n" "$path" \
    | prlctl exec "$vm_name" /bin/sh >/dev/null 2>&1
}

guest_current_path_exists() {
  local path="$1"
  printf "/bin/test -e '%s'\n" "$path" \
    | macos_prl_current_user_shell_idempotent >/dev/null 2>&1
}

run_clean_snapshot_preflight() {
  local aqua_session=""
  local console_user=""
  local control_capture="$work_dir/parallels-control.png"
  local guest_arch=""
  local guest_os=""
  local keyboard_ui_mode=""
  local path=""
  local process_list=""
  local vm_info=""
  local vm_status=""

  [[ "$guest_user" == "testmac" ]] \
    || guest_test_fail "The macOS release guest must use the protected testmac account."
  vm_status="$(prlctl status "$vm_name" 2>/dev/null || true)"
  [[ "$vm_status" == *running* ]] || guest_test_fail "The macOS Parallels guest is not running."
  vm_info="$(prlctl list -i "$vm_name" 2>/dev/null || true)"
  grep -Fq "GuestTools: state=installed" <<<"$vm_info" \
    || guest_test_fail "Parallels Tools are not reported as installed in the macOS guest."
  grep -Fq "Capture mouse clicks: on" <<<"$vm_info" \
    || guest_test_fail "Parallels mouse-click capture is not enabled for the macOS guest."

  guest_os="$(prlctl exec "$vm_name" /usr/bin/uname -s 2>/dev/null | tr -d '\r\n' || true)"
  guest_arch="$(prlctl exec "$vm_name" /usr/bin/uname -m 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$guest_os" == "Darwin" ]] || guest_test_fail "The selected Parallels guest is not macOS."
  [[ "$guest_arch" == "arm64" ]] || guest_test_fail "The macOS release guest must be ARM64."
  [[ "$actual_user" == "testmac" ]] || guest_test_fail "The macOS current-user channel is not testmac."
  [[ "$uid" =~ ^[1-9][0-9]*$ ]] || guest_test_fail "The macOS current-user channel has an invalid user ID."

  console_user="$(prlctl exec "$vm_name" /usr/bin/stat -f %Su /dev/console 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$console_user" == "testmac" ]] || guest_test_fail "The macOS console user is not testmac."
  aqua_session="$(prlctl exec "$vm_name" /bin/launchctl print "gui/$uid" 2>/dev/null || true)"
  grep -Fq "session = Aqua" <<<"$aqua_session" \
    || guest_test_fail "The testmac Aqua launch session is unavailable."
  keyboard_ui_mode="$(macos_prl_current_user_exec_idempotent /usr/bin/defaults read NSGlobalDomain AppleKeyboardUIMode 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$keyboard_ui_mode" == "3" ]] \
    || guest_test_fail "AppleKeyboardUIMode must be 3 for keyboard-only macOS control."

  process_list="$(prlctl exec "$vm_name" /bin/ps -ax -o command= 2>/dev/null || true)"
  grep -Fq "/Library/Parallels Guest Tools/prltoolsd" <<<"$process_list" \
    || guest_test_fail "The Parallels Tools service is not running in the macOS guest."
  grep -Fq "/Library/Parallels Guest Tools/prlcopypaste" <<<"$process_list" \
    || guest_test_fail "The Parallels current-user integration service is not running."
  prlctl capture "$vm_name" --file "$control_capture" >/dev/null 2>&1 \
    || guest_test_fail "Parallels could not capture the macOS guest display."
  [[ -s "$control_capture" ]] || guest_test_fail "The Parallels guest display capture is empty."

  if macos_prl_current_user_exec_idempotent /usr/bin/xcode-select -p >/dev/null 2>&1 \
    || guest_path_exists /Library/Developer/CommandLineTools \
    || guest_path_exists /Developer \
    || prlctl exec "$vm_name" /bin/ls -1A /Applications 2>/dev/null | grep -Eq '^Xcode.*[.]app$' \
    || prlctl exec "$vm_name" /usr/sbin/pkgutil --pkgs 2>/dev/null | grep -Eiq '(^|[.])(CLTools|CommandLineTools)([._-]|$)'; then
    guest_test_fail "The approved macOS snapshot already contains Xcode or Command Line Tools."
  fi

  for path in /opt/homebrew /usr/local/Homebrew /usr/local/bin/brew /home/linuxbrew/.linuxbrew; do
    if guest_path_exists "$path"; then
      guest_test_fail "The approved macOS snapshot already contains Homebrew."
    fi
  done
  if guest_current_command_exists brew; then
    guest_test_fail "The approved macOS snapshot already exposes Homebrew."
  fi

  for path in \
    /usr/bin/node /usr/bin/npm \
    /usr/local/bin/node /usr/local/bin/npm \
    /opt/homebrew/bin/node /opt/homebrew/bin/npm \
    /Library/Frameworks/Node.framework \
    /usr/local/lib/node_modules/npm /opt/homebrew/lib/node_modules/npm \
    "$guest_home/.eai-setup/node" \
    "$guest_home/.nvm/versions/node" \
    "$guest_home/.volta/bin/node" \
    "$guest_home/.fnm/node-versions" \
    "$guest_home/.local/share/fnm/node-versions"; do
    if guest_path_exists "$path"; then
      guest_test_fail "The approved macOS snapshot already contains Node.js or npm."
    fi
  done
  if guest_current_command_exists node || guest_current_command_exists npm \
    || prlctl exec "$vm_name" /usr/sbin/pkgutil --pkgs 2>/dev/null | grep -Eiq '(^|[.])org[.]nodejs([._-]|$)'; then
    guest_test_fail "The approved macOS snapshot already exposes Node.js or npm."
  fi

  for path in \
    /usr/bin/eai /usr/local/bin/eai /opt/homebrew/bin/eai \
    /usr/local/lib/node_modules/@enterpriseai/cli \
    /opt/homebrew/lib/node_modules/@enterpriseai/cli \
    "$guest_home/.local/bin/eai" \
    "$guest_home/.npm-global/bin/eai" \
    "$guest_home/.npm-global/lib/node_modules/@enterpriseai/cli" \
    "$guest_home/.eai-setup/npm-global/lib/node_modules/@enterpriseai/cli"; do
    if guest_path_exists "$path"; then
      guest_test_fail "The approved macOS snapshot already contains the EAI CLI."
    fi
  done
  if guest_current_command_exists eai; then
    guest_test_fail "The approved macOS snapshot already exposes the EAI CLI."
  fi

  if prlctl exec "$vm_name" /bin/ls -1A /Applications 2>/dev/null | grep -Fxq "EAI Setup.app" \
    || macos_prl_current_user_exec_idempotent /bin/ls -1A "$guest_home/Applications" 2>/dev/null | grep -Fxq "EAI Setup.app"; then
    guest_test_fail "The approved macOS snapshot already contains the EAI Setup application."
  fi
  for path in \
    "$guest_home/.eai" \
    "$guest_home/.eai-setup" \
    "$guest_home/.config/eai" \
    "$guest_home/Library/Application Support/EAI Setup" \
    "$guest_home/EAIReleaseTests" \
    /tmp/eai-setup-under-test.dmg \
    /tmp/eai-setup-under-test \
    /tmp/eai-setup-e2e-app \
    /tmp/eai-setup-e2e-receipt.json \
    /tmp/eai-setup-normal.pid \
    /tmp/eai-setup-e2e.pid; do
    if guest_current_path_exists "$path"; then
      guest_test_fail "The approved macOS snapshot contains EAI Setup state or prior test artifacts."
    fi
  done
  if prlctl exec "$vm_name" /bin/ls -1A /tmp 2>/dev/null | grep -Eq '^eai-setup($|[-.])'; then
    guest_test_fail "The approved macOS snapshot contains EAI Setup temporary artifacts."
  fi
  if grep -Eiq 'EAI Setup[.]app|@enterpriseai/cli|(^|[/[:space:]])eai-setup([[:space:]]|$)|(^|[/[:space:]])eai([[:space:]]|$)' <<<"$process_list"; then
    guest_test_fail "The approved macOS snapshot already has an EAI Setup or EAI CLI process running."
  fi
}

launch_normal_app() {
  {
    printf 'printf "%%s\\n" "$$" > "%s"\n' "$normal_pid_file"
    printf 'exec /usr/bin/env HOME="%s" USER="%s" LOGNAME="%s" "%s"\n' "$guest_home" "$guest_user" "$guest_user" "$executable"
  } | prlctl exec "$vm_name" /bin/launchctl asuser "$uid" /usr/bin/sudo -H -u "$guest_user" /bin/sh >"$normal_log" 2>&1 &
  normal_bridge_pid=$!
}

launch_e2e_app() {
  {
    printf 'printf "%%s\\n" "$$" > "%s"\n' "$e2e_pid_file"
    printf 'exec /usr/bin/env HOME="%s" USER="%s" LOGNAME="%s" EAI_SETUP_E2E=1 EAI_SETUP_E2E_PROJECT_NAME="%s" EAI_SETUP_E2E_DIRECTORY="%s" EAI_SETUP_E2E_COMPANY_TENANT="%s" EAI_SETUP_E2E_RECEIPT_FILE="%s" "%s"\n' \
      "$guest_home" "$guest_user" "$guest_user" "$EAI_VM_PROJECT_NAME" "$guest_parent" "$EAI_HARNESS_TENANT_ID" "$guest_receipt" "$executable"
  } | prlctl exec "$vm_name" /bin/launchctl asuser "$uid" /usr/bin/sudo -H -u "$guest_user" /bin/sh >"$e2e_log" 2>&1 &
  e2e_bridge_pid=$!
}

guest_test_require prlctl
guest_test_require node
guest_test_require security
guest_test_require_environment
[[ "$expected_cli_version" == 3.15.10 ]] \
  || guest_test_fail "The macOS release harness is pinned to EAI CLI 3.15.10."
[[ -f "$input_helper" ]] || guest_test_fail "The Parallels input helper is missing."
[[ "$guest_user" == "$mac_admin_account" ]] \
  || guest_test_fail "The controlled macOS release guest must use the testmac account."

# Validate only protected service/account metadata before any snapshot-changing
# operation. Secrets are read only at the exact UI actions that require them.
EAI_MACOS_VM_NAME="$vm_name" "$ROOT/scripts/login-macos-guest.sh" --preflight \
  || guest_test_fail "The protected Enterprise AI login credential is unavailable."
/usr/bin/security find-generic-password -s "$mac_admin_service" -a "$mac_admin_account" >/dev/null 2>&1 \
  || guest_test_fail "The protected macOS guest administrator credential is unavailable."

stage snapshot-restore
guest_test_restore_snapshot "$vm_name" "$snapshot_id"

stage guest-session
actual_user=""
uid=""
guest_home=""
for _ in $(seq 1 120); do
  if macos_prl_current_user_configure "$vm_name" "$guest_user" "$work_dir" >/dev/null 2>&1; then
    actual_user="$MACOS_PRL_CURRENT_USER_NAME"
    uid="$MACOS_PRL_CURRENT_USER_UID"
    guest_home="$MACOS_PRL_CURRENT_USER_HOME"
    break
  fi
  sleep 2
done
[[ "$actual_user" == "$guest_user" ]] || guest_test_fail "Expected macOS user $guest_user, got ${actual_user:-none}."
[[ "$uid" =~ ^[1-9][0-9]*$ ]] || guest_test_fail "The expected macOS guest user ID could not be resolved."
[[ "$guest_home" == "/Users/$guest_user" ]] || guest_test_fail "The expected macOS guest home directory could not be resolved."

stage clean-snapshot-preflight
run_clean_snapshot_preflight
before_git=""
before_node=""
before_npm=""
before_eai=""
stage clean-snapshot-preflight-passed

stage ai-workspace-provision
EAI_MACOS_VM_NAME="$vm_name" EAI_VM_GUEST_USER="$guest_user" \
  "$ROOT/scripts/prepare-macos-ai-workspace.sh"
stage ai-workspace-provision-passed

stage portal-login
EAI_MACOS_VM_NAME="$vm_name" "$ROOT/scripts/login-macos-guest.sh" --portal-only \
  || guest_test_fail "Enterprise AI portal login failed."

stage exact-asset-download
EAI_VM_ALLOW_UNSIGNED_TEST=1 EAI_VM_GUEST_USER="$guest_user" EAI_MACOS_VM_NAME="$vm_name" \
  "$ROOT/scripts/prepare-macos-guest-dmg.sh"

stage exact-app-copy
printf '%s\n' \
  "rm -rf '$guest_app'" \
  "/usr/bin/ditto '/tmp/eai-setup-under-test/EAI Setup.app' '$guest_app'" \
  | macos_prl_current_user_shell_idempotent
macos_prl_current_user_exec_idempotent /bin/test -x "$executable" \
  || guest_test_fail "The mounted macOS application executable could not be found."
macos_prl_current_user_exec_idempotent /bin/mkdir -p "$guest_parent"
macos_prl_current_user_exec_idempotent /bin/rm -f "$guest_receipt" "$normal_pid_file" "$e2e_pid_file"
executable_hash="$(macos_prl_current_user_exec_idempotent /usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')"
[[ "$executable_hash" =~ ^[0-9a-f]{64}$ ]] || guest_test_fail "The released macOS executable hash could not be recorded."

stage prerequisite-baseline-proven

# First pass: the exact released app auto-starts its normal prerequisite flow.
# This launch intentionally contains no EAI_SETUP_E2E environment variables.
stage normal-app-launch
launch_normal_app
for _ in $(seq 1 30); do
  guest_process_alive "$normal_pid_file" && break
  sleep 1
done
guest_process_alive "$normal_pid_file" || guest_test_fail "The normal released app process did not start."

if [[ -z "$before_git" ]]; then
  stage mac-admin-authorization
  admin_prompt_seen=0
  liveness_failures=0
  for _ in $(seq 1 300); do
    if guest_process_alive "$normal_pid_file"; then
      liveness_failures=0
    else
      liveness_failures=$((liveness_failures + 1))
      [[ "$liveness_failures" -lt 5 ]] || guest_test_fail "The released app exited before requesting Git authorization."
    fi
    if screen_has "Mac login password" && screen_has "Authorize Git installation"; then
      admin_prompt_seen=1
      /usr/bin/security find-generic-password -s "$mac_admin_service" -a "$mac_admin_account" -w \
        | input type --stdin
      input key tab
      input key enter
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" mac-admin-credential-submitted
      break
    fi
    guest_git_version >/dev/null 2>&1 && break
    sleep 1
  done
  if [[ "$admin_prompt_seen" == 0 ]]; then
    guest_git_version >/dev/null 2>&1 \
      || guest_test_fail "The released app did not present the expected one-time Git authorization prompt."
  fi
fi

stage prerequisite-install
ready_reads=0
liveness_failures=0
for attempt in $(seq 1 600); do
  if guest_process_alive "$normal_pid_file"; then
    liveness_failures=0
  else
    liveness_failures=$((liveness_failures + 1))
    [[ "$liveness_failures" -lt 5 ]] || guest_test_fail "The released app exited before prerequisite installation completed."
  fi
  if guest_prerequisites_ready && screen_has "Sign in to EAI"; then
    # The long activity list can scroll its completion banner out of view. The
    # visible sign-in panel is only selected after installPrerequisites returns
    # true; pair it with the independent version checks above rather than
    # relying on off-screen OCR text.
    ready_reads=$((ready_reads + 1))
    [[ "$ready_reads" -ge 2 ]] && break
  else
    ready_reads=0
  fi
  if (( attempt % 30 == 0 )); then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" prerequisite-install-still-running
  fi
  sleep 2
done
[[ "$ready_reads" -ge 2 ]] || guest_test_fail "The released app did not reach stable prerequisite readiness within 20 minutes."

after_git="$(guest_git_version)"
after_node="$(guest_node_version)"
after_npm="$(guest_npm_version)"
after_eai="$(guest_eai_version)"
prerequisite_versions_satisfy_contract "$after_git" "$after_node" "$after_npm" "$after_eai" \
  || guest_test_fail "Installed prerequisite versions do not satisfy the release contract."
stage prerequisite-install-passed

stage normal-app-stop
stop_guest_process "$normal_pid_file"
guest_process_alive "$normal_pid_file" && guest_test_fail "The normal app instance did not stop before CLI login."
if [[ "$normal_bridge_pid" =~ ^[1-9][0-9]*$ ]]; then
  wait "$normal_bridge_pid" 2>/dev/null || true
fi
normal_bridge_pid=""

stage cli-login
EAI_MACOS_VM_NAME="$vm_name" "$ROOT/scripts/login-macos-guest.sh" --cli-only \
  || guest_test_fail "The EAI CLI browser login or tenant verification failed."
stage cli-login-passed

second_executable_hash="$(macos_prl_current_user_exec_idempotent /usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')"
[[ "$second_executable_hash" == "$executable_hash" ]] \
  || guest_test_fail "The executable changed between the prerequisite and E2E launches."

stage e2e-app-launch
macos_prl_current_user_exec_idempotent /bin/rm -f "$guest_receipt"
launch_e2e_app
for _ in $(seq 1 30); do
  guest_process_alive "$e2e_pid_file" && break
  sleep 1
done
guest_process_alive "$e2e_pid_file" || guest_test_fail "The E2E released app process did not start."

receipt_ready=0
liveness_failures=0
for attempt in $(seq 1 240); do
  if macos_prl_current_user_exec_idempotent /bin/test -s "$guest_receipt" >/dev/null 2>&1; then
    receipt_ready=1
    break
  fi
  if guest_process_alive "$e2e_pid_file"; then
    liveness_failures=0
  else
    liveness_failures=$((liveness_failures + 1))
    [[ "$liveness_failures" -lt 5 ]] || guest_test_fail "The E2E app exited before writing its receipt."
  fi
  if (( attempt % 12 == 0 )); then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" e2e-flow-still-running
  fi
  sleep 5
done
[[ "$receipt_ready" == 1 ]] || guest_test_fail "The macOS desktop E2E receipt was not produced within 20 minutes."

stage receipt-validation
macos_prl_current_user_exec_idempotent /bin/cat "$guest_receipt" >"$host_receipt" \
  || guest_test_fail "The macOS desktop E2E receipt could not be read."

stage exact-project-validation
exact_project="$guest_parent/$EAI_VM_PROJECT_NAME"
exact_package="$exact_project/package.json"
macos_prl_current_user_exec_idempotent /bin/test -d "$guest_parent" \
  || guest_test_fail "The generated-project parent directory is missing."
macos_prl_current_user_exec_idempotent /bin/test ! -L "$guest_parent" \
  || guest_test_fail "The generated-project parent directory is a symlink."
macos_prl_current_user_exec_idempotent /bin/test -d "$exact_project" \
  || guest_test_fail "The exact generated project directory is missing."
macos_prl_current_user_exec_idempotent /bin/test ! -L "$exact_project" \
  || guest_test_fail "The exact generated project directory is a symlink."
macos_prl_current_user_exec_idempotent /bin/test -f "$exact_package" \
  || guest_test_fail "The exact generated project has no package.json."
macos_prl_current_user_exec_idempotent /bin/test ! -L "$exact_package" \
  || guest_test_fail "The exact generated project's package.json is a symlink."
macos_prl_current_user_exec_idempotent /bin/cat "$exact_package" >"$host_project_package" \
  || guest_test_fail "The exact generated project's package.json could not be read."
guest_package_hash="$(macos_prl_current_user_exec_idempotent /usr/bin/shasum -a 256 "$exact_package" | /usr/bin/awk '{print $1}')"
host_package_hash="$(/usr/bin/shasum -a 256 "$host_project_package" | /usr/bin/awk '{print $1}')"
[[ "$guest_package_hash" =~ ^[0-9a-f]{64}$ && "$guest_package_hash" == "$host_package_hash" ]] \
  || guest_test_fail "The generated package.json changed while its project proof was collected."
EAI_EXPECTED_APP_NAME="$EAI_VM_PROJECT_NAME" \
EAI_EXPECTED_PROJECT_PATH="$exact_project" \
EAI_PROJECT_PACKAGE_HASH="$host_package_hash" \
EAI_PROJECT_PACKAGE="$host_project_package" \
EAI_PROJECT_RECEIPT="$host_receipt" \
EAI_PROJECT_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/macos-project-verification.json" \
node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";

const appName = process.env.EAI_EXPECTED_APP_NAME;
const projectPath = process.env.EAI_EXPECTED_PROJECT_PATH;
const expectedPackageName = `@eai-tools/${appName}`;
const packageBytes = fs.readFileSync(process.env.EAI_PROJECT_PACKAGE);
const packageJson = JSON.parse(packageBytes.toString("utf8"));
const receipt = JSON.parse(fs.readFileSync(process.env.EAI_PROJECT_RECEIPT, "utf8"));
const scripts = Object.keys(packageJson.scripts || {});
const dependencies = Object.keys(packageJson.dependencies || {});
const devDependencies = Object.keys(packageJson.devDependencies || {});
if (receipt.checks?.project !== "passed") {
  throw new Error("The desktop receipt did not pass its project check.");
}
if (receipt.projectPath && receipt.projectPath !== projectPath) {
  throw new Error("The desktop receipt points to a different generated project.");
}
if (packageJson.name !== expectedPackageName) {
  throw new Error("The generated package.json names a different project.");
}
if (scripts.length === 0 || dependencies.length === 0) {
  throw new Error("The generated project does not contain usable scripts and dependencies.");
}
const evidence = {
  status: "verified",
  platform: "macos",
  appName,
  projectPath,
  packageJsonRegularFile: true,
  packageJsonSymlink: false,
  packageName: packageJson.name,
  packageNameMatched: true,
  packageJsonSha256: crypto.createHash("sha256").update(packageBytes).digest("hex"),
  guestAndHostPackageHashesMatched:
    crypto.createHash("sha256").update(packageBytes).digest("hex") === process.env.EAI_PROJECT_PACKAGE_HASH,
  scriptCount: scripts.length,
  dependencyCount: dependencies.length,
  devDependencyCount: devDependencies.length,
  receiptProjectCheck: "passed",
  verifiedAt: new Date().toISOString(),
  sanitized: true,
  diagnostic: true,
  productionGate: false,
};
fs.writeFileSync(process.env.EAI_PROJECT_EVIDENCE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
export EAI_VM_PROJECT_VERIFIED=1

stage ai-handoff-process-validation
ai_workspace_running=0
ai_workspace_pid=""
for _ in $(seq 1 30); do
  ai_workspace_pid="$(printf '%s\n' "/usr/bin/pgrep -f '/Applications/Visual Studio Code.app/Contents/MacOS/Code' | /usr/bin/head -1" \
    | macos_prl_current_user_shell_idempotent 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "$ai_workspace_pid" =~ ^[1-9][0-9]*$ ]]; then
    ai_workspace_running=1
    break
  fi
  sleep 1
done
[[ "$ai_workspace_running" == 1 ]] \
  || guest_test_fail "The EAI handoff receipt passed, but the signed-in user's VS Code process was not running."

# Safari owns the completed CLI callback at this point and is no longer needed.
# Close it before evidence capture, then foreground the product-opened VS Code
# process without opening a project on the adapter's behalf.
if macos_prl_current_user_exec_idempotent /usr/bin/pgrep -x Safari >/dev/null 2>&1; then
  macos_prl_current_user_exec_idempotent /usr/bin/pkill -x Safari >/dev/null 2>&1 \
    || guest_test_fail "Safari could not be closed before handoff evidence capture."
fi
safari_stopped=0
for _ in $(seq 1 20); do
  if ! macos_prl_current_user_exec_idempotent /usr/bin/pgrep -x Safari >/dev/null 2>&1; then
    safari_stopped=1
    break
  fi
  sleep 1
done
[[ "$safari_stopped" == 1 ]] \
  || guest_test_fail "Safari still owned the callback window before handoff evidence capture."
macos_prl_signed_in_user_exec /usr/bin/open -a "Visual Studio Code" >/dev/null \
  || guest_test_fail "The product-opened VS Code workspace could not be foregrounded for handoff evidence."
sleep 3
macos_prl_current_user_exec_idempotent /bin/kill -0 "$ai_workspace_pid" >/dev/null 2>&1 \
  || guest_test_fail "The product-opened VS Code process changed before handoff evidence capture."
handoff_candidate="$work_dir/macos-ai-handoff.png"
handoff_destination="$(dirname "$EAI_VM_RESULT_FILE")/macos-ai-handoff.png"
prlctl capture "$vm_name" --file "$handoff_candidate" >/dev/null 2>&1 \
  || guest_test_fail "The macOS AI handoff screenshot could not be captured."
EAI_OCR_PATTERN="$EAI_VM_PROJECT_NAME" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
  "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1 \
  || guest_test_fail "The macOS handoff screenshot does not show the exact generated project."
EAI_OCR_PATTERN="Build with Agent" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
  "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1 \
  || guest_test_fail "The macOS handoff screenshot does not show the AI chat surface."
for protected_pattern in \
  "$EAI_HARNESS_USER_EMAIL" "$EAI_HARNESS_TENANT_ID" "$EAI_HARNESS_TENANT_NAME" \
  'localhost' '?code=' 'code=' 'code =' 'access_token' 'refresh_token' \
  'client_info' 'session_state' 'Authentication complete' 'successfully authenticated'; do
  if EAI_OCR_PATTERN="$protected_pattern" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
    "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1; then
    guest_test_fail "The macOS handoff screenshot contains protected or callback data."
  fi
done
/usr/bin/ditto "$handoff_candidate" "$handoff_destination" \
  || guest_test_fail "The sanitized macOS AI handoff screenshot could not be preserved."
handoff_hash="$(/usr/bin/shasum -a 256 "$handoff_destination" | /usr/bin/awk '{print $1}')"
EAI_HANDOFF_SCREENSHOT_HASH="$handoff_hash" \
EAI_HANDOFF_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/macos-ai-handoff-evidence.json" \
EAI_HANDOFF_PROJECT_PATH="$exact_project" \
EAI_HANDOFF_APP_NAME="$EAI_VM_PROJECT_NAME" \
EAI_HANDOFF_PROCESS_ID="$ai_workspace_pid" \
node --input-type=module <<'NODE'
import fs from "node:fs";

const evidence = {
  platform: "macos",
  appName: process.env.EAI_HANDOFF_APP_NAME,
  projectPath: process.env.EAI_HANDOFF_PROJECT_PATH,
  surfaceId: "vscode-copilot",
  handoffReceiptPassed: true,
  processVerified: true,
  processOwner: "testmac",
  processId: Number(process.env.EAI_HANDOFF_PROCESS_ID),
  processMatch: "/Applications/Visual Studio Code.app/Contents/MacOS/Code",
  screenshot: {
    path: "macos-ai-handoff.png",
    sha256: process.env.EAI_HANDOFF_SCREENSHOT_HASH,
    showsExactProject: true,
    showsChatSurface: true,
    showsProviderAuthenticated: false,
    automatedProtectedContentCheckPassed: true,
  },
  verifiedAt: new Date().toISOString(),
  sanitized: true,
  diagnostic: true,
  productionGate: false,
};
fs.writeFileSync(process.env.EAI_HANDOFF_EVIDENCE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
export EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1
export EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1

guest_hash="$(macos_prl_current_user_exec_idempotent /usr/bin/shasum -a 256 /tmp/eai-setup-under-test.dmg | /usr/bin/awk '{print $1}')"
versions="$(node --input-type=module - "$after_git" "$after_node" "$after_npm" "$after_eai" <<'NODE'
const [git, node, npm, eai] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ git, node, npm, eai }));
NODE
)"
before_versions="$(node --input-type=module - "$before_git" "$before_node" "$before_npm" "$before_eai" <<'NODE'
const [git, node, npm, eai] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ git: git || null, node: node || null, npm: npm || null, eai: eai || null }));
NODE
)"
export EAI_VM_INSTALLER_VERIFIED=1
export EAI_VM_PREREQUISITES_PROVEN=1
export EAI_VM_EXECUTABLE_SHA256="$executable_hash"
export EAI_VM_PREREQUISITES_BEFORE="$before_versions"
guest_test_finalize macos "$guest_parent/$EAI_VM_PROJECT_NAME" "$host_receipt" "$(guest_test_host_sha256)" "$guest_hash" "$versions"
completed=1
stage macos-e2e-passed
