#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/guest-test-lib.sh"
# shellcheck source=scripts/windows-hidden-current-user.sh
source "$ROOT/scripts/windows-hidden-current-user.sh"
# shellcheck source=scripts/windows-readonly-powershell.sh
source "$ROOT/scripts/windows-readonly-powershell.sh"

vm_name="${EAI_WINDOWS_VM_NAME:-Windows 11}"
guest_user="${EAI_WINDOWS_GUEST_USER:-eai-douglasross}"
guest_script="$ROOT/scripts/prepare-windows-ai-workspace.ps1"
guest_evidence='C:\Users\Public\eai-release-e2e-windows-ai-workspace.json'
evidence_file="$(dirname "${EAI_VM_RESULT_FILE:?EAI_VM_RESULT_FILE is required}")/windows-ai-workspace.json"

fail() {
  guest_test_fail "$*"
}

is_parallels_session_open_failure() {
  local normalized=""
  normalized="$(printf '%s' "$1" | /usr/bin/tr -d '\r')"
  case "$normalized" in
    'PrlVmGuest_RunProgram: Invalid argument'|\
    'PrlVmGuest_RunProgram: Unable to open new session in this virtual machine. Make sure your virtual machine has finished booting, runs the latest version of Parallels Tools, and is not isolated from the host OS.')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

extract_marker() {
  tr -d '\r' \
    | /usr/bin/grep -oE 'AI_WORKSPACE_(READY|ERROR):?[^<]*' \
    | /usr/bin/tail -n 1 \
    || true
}

run_guest_powershell() {
  local nonce=""
  local guest_stage_dir=""
  local guest_stage_script=""
  local payload=""
  local launcher=""
  local output=""
  local status=1

  nonce="$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
  guest_stage_dir="C:\\Users\\Public\\eai-ai-workspace-${nonce}"
  guest_stage_script="${guest_stage_dir}\\prepare.ps1"
  payload="$({
    printf '%s\n' "\$env:EAI_WINDOWS_AI_EXPECTED_USER = '$guest_user'"
    /bin/cat "$guest_script"
  } | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  launcher="$(printf '%s' \
    "\$ErrorActionPreference='Stop';" \
    "\$stage='$guest_stage_dir';" \
    "\$script='$guest_stage_script';" \
    "\$status=1;" \
    "try {" \
    "Remove-Item -LiteralPath \$stage -Recurse -Force -ErrorAction SilentlyContinue;" \
    "New-Item -ItemType Directory -Path \$stage -ErrorAction Stop | Out-Null;" \
    "\$acl=[Security.AccessControl.DirectorySecurity]::new();" \
    "\$acl.SetAccessRuleProtection(\$true,\$false);" \
    "foreach (\$sidText in @('S-1-5-18','S-1-5-32-544')) {" \
    "\$sid=[Security.Principal.SecurityIdentifier]::new(\$sidText);" \
    "\$rule=[Security.AccessControl.FileSystemAccessRule]::new(\$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow');" \
    "[void]\$acl.AddAccessRule(\$rule)" \
    "};" \
    "Set-Acl -LiteralPath \$stage -AclObject \$acl -ErrorAction Stop;" \
    "[IO.File]::WriteAllBytes(\$script,[Convert]::FromBase64String('$payload'));" \
    "& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \$script;" \
    "\$status=\$LASTEXITCODE" \
    "} catch {" \
    "[Console]::Error.WriteLine((\$_ | Out-String));" \
    "\$status=1" \
    "} finally {" \
    "Remove-Item -LiteralPath \$stage -Recurse -Force -ErrorAction SilentlyContinue" \
    "};" \
    "exit \$status")"

  for _ in $(seq 1 120); do
    if output="$(printf '%s\n' "$launcher" | prlctl exec "$vm_name" cmd.exe /D /S /C powershell.exe \
      -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -InputFormat Text -OutputFormat Text -Command - 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi

    if is_parallels_session_open_failure "$output"; then
      sleep 2
      continue
    fi
    printf '%s\n' "$output"
    return "$status"
  done

  printf '%s\n' "$output"
  return "$status"
}

guest_test_require prlctl
guest_test_require node
[[ -f "$guest_script" ]] || fail "The Windows AI-workspace PowerShell helper is missing."
[[ "$guest_user" =~ ^[A-Za-z0-9._-]+$ ]] || fail "The expected Windows guest username is invalid."
mkdir -p "$(dirname "$evidence_file")"

actual_user=""
for _ in $(seq 1 30); do
  if actual_user="$(printf '%s\n' '[Security.Principal.WindowsIdentity]::GetCurrent().Name' | windows_hidden_current_user_ps "$vm_name" 2>/dev/null | tr -d '\r\n')"; then
    [[ -n "$actual_user" ]] && break
  fi
  sleep 2
done
actual_user_component="${actual_user##*\\}"
actual_user_component_lower="$(printf '%s' "$actual_user_component" | /usr/bin/tr '[:upper:]' '[:lower:]')"
guest_user_lower="$(printf '%s' "$guest_user" | /usr/bin/tr '[:upper:]' '[:lower:]')"
actual_user_lower="$(printf '%s' "$actual_user" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$actual_user_component_lower" == "$guest_user_lower" ]] \
  || fail "The Windows current-user channel is not running as the expected guest user."
[[ "$actual_user_lower" != 'nt authority\system' ]] \
  || fail "The Windows AI-workspace helper must not run as SYSTEM."

if powershell_output="$(run_guest_powershell)"; then
  marker="$(printf '%s\n' "$powershell_output" | extract_marker)"
  [[ "$marker" == "AI_WORKSPACE_READY surface=vscode-copilot version=1.136.1 source="* ]] \
    || fail "The Windows AI-workspace helper returned success without its readiness marker."
else
  marker="$(printf '%s\n' "$powershell_output" | extract_marker)"
  if [[ "$marker" == AI_WORKSPACE_ERROR:* ]]; then
    fail "${marker#AI_WORKSPACE_ERROR: }"
  fi
  if is_parallels_session_open_failure "$powershell_output"; then
    fail "The Windows AI-workspace current-user transport remained unavailable after bounded retries."
  fi
  fail "The Windows AI-workspace PowerShell helper failed without a readable diagnostic."
fi

guest_json=""
evidence_output=""
evidence_status=1
for _ in $(seq 1 5); do
  set +e
  evidence_output="$(printf '%s\n' "Get-Content -Raw -LiteralPath '$guest_evidence'" | guest_ps_readonly)"
  evidence_status=$?
  set -e
  if [[ "$evidence_status" == 0 ]]; then
    guest_json="$(printf '%s' "$evidence_output" | tr -d '\r')"
    if [[ -n "$guest_json" ]]; then
      break
    fi
    sleep 1
    continue
  fi
  fail "The Windows AI-workspace evidence read transport failed after bounded retries."
done
[[ "$evidence_status" == 0 ]] \
  || fail "The Windows AI-workspace evidence file could not be read from the guest after bounded transport retries."
[[ -n "$guest_json" ]] || fail "The Windows AI-workspace evidence file was empty."

EAI_WINDOWS_AI_EVIDENCE_JSON="$guest_json" node --input-type=module - "$evidence_file" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const evidenceFile = process.argv[2];
const raw = String(process.env.EAI_WINDOWS_AI_EVIDENCE_JSON || "").replace(/^\uFEFF/, "");
const parsed = JSON.parse(raw);
const exact = {
  status: "prepared",
  surfaceId: "vscode-copilot",
  product: "Visual Studio Code",
  version: "1.136.1",
  commit: "a44adf7f53e00964ab890f9f8758a334f1fc15bc",
  architecture: "arm64",
  peMachine: "0xAA64",
  applicationPath: "%ProgramFiles%\\Microsoft VS Code\\Code.exe",
  cliPath: "%ProgramFiles%\\Microsoft VS Code\\bin\\code.cmd",
  downloadUrl: "https://update.code.visualstudio.com/1.136.1/win32-arm64/stable",
  responseSha256: "57454d84d55f07b532fcf42295c57a5445054006be668ad7b1c19c9de9f68e31",
  installerSha256: "57454d84d55f07b532fcf42295c57a5445054006be668ad7b1c19c9de9f68e31",
  publisher: "Microsoft Corporation",
  extensionId: "GitHub.copilot-chat",
};
for (const [key, value] of Object.entries(exact)) {
  if (parsed[key] !== value) throw new Error(`Windows AI-workspace evidence mismatch: ${key}`);
}
for (const key of ["installerSignatureVerified", "applicationSignatureVerified", "bundledCopilotVerified", "machineWideInstallVerified", "protectedAclVerified"]) {
  if (parsed[key] !== true) throw new Error(`Windows AI-workspace evidence did not verify ${key}`);
}
const treeIdentity = {
  applicationTreeFileCount: 2463,
  applicationTreeTotalBytes: 782690305,
  applicationTreeSha256: "11009193bf07e51892a0ae9f6030188c7f8914e79ef4344e2f6a3a344807753f",
  binTreeFileCount: 3,
  binTreeTotalBytes: 25558542,
  binTreeSha256: "73fbdad4bf097af9408bdcbe75f4c5cc1741b88b9eedf9d946b338124457408b",
};
for (const [key, value] of Object.entries(treeIdentity)) {
  if (parsed[key] !== value) throw new Error(`Windows AI-workspace tree evidence mismatch: ${key}`);
}
if (!["existing", "official-download"].includes(parsed.source)) throw new Error("Windows AI-workspace evidence has an invalid source");
if (!/^\d{4}-\d{2}-\d{2}T/.test(parsed.preparedAt || "")) throw new Error("Windows AI-workspace evidence has an invalid timestamp");

const sanitized = {
  status: parsed.status,
  surfaceId: parsed.surfaceId,
  product: parsed.product,
  source: parsed.source,
  version: parsed.version,
  commit: parsed.commit,
  architecture: parsed.architecture,
  peMachine: parsed.peMachine,
  applicationPath: parsed.applicationPath,
  cliPath: parsed.cliPath,
  downloadUrl: parsed.downloadUrl,
  responseSha256: parsed.responseSha256,
  installerSha256: parsed.installerSha256,
  installerSignatureVerified: parsed.installerSignatureVerified,
  applicationSignatureVerified: parsed.applicationSignatureVerified,
  publisher: parsed.publisher,
  bundledCopilotVerified: parsed.bundledCopilotVerified,
  extensionId: parsed.extensionId,
  machineWideInstallVerified: parsed.machineWideInstallVerified,
  protectedAclVerified: parsed.protectedAclVerified,
  applicationTreeFileCount: parsed.applicationTreeFileCount,
  applicationTreeTotalBytes: parsed.applicationTreeTotalBytes,
  applicationTreeSha256: parsed.applicationTreeSha256,
  binTreeFileCount: parsed.binTreeFileCount,
  binTreeTotalBytes: parsed.binTreeTotalBytes,
  binTreeSha256: parsed.binTreeSha256,
  preparedAt: parsed.preparedAt,
};
fs.mkdirSync(path.dirname(evidenceFile), { recursive: true });
fs.writeFileSync(evidenceFile, `${JSON.stringify(sanitized, null, 2)}\n`);
NODE

printf '%s\n' "$marker"
