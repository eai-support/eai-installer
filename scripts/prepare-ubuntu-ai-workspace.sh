#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/guest-test-lib.sh"
source "$ROOT/scripts/ubuntu-guest-session.sh"

vm_name="${EAI_UBUNTU_VM_NAME:-Ubuntu 24.04.3 ARM64}"
guest_user="${EAI_UBUNTU_GUEST_USER:-parallels}"
vscode_version="1.136.1"
vscode_commit="a44adf7f53e00964ab890f9f8758a334f1fc15bc"
pinned_hash="baa72f92d3feaa76d015202c57271475ea15809e635587279171a972cdd612a4"
download_url="https://update.code.visualstudio.com/${vscode_version}/linux-deb-arm64/stable"
redirect_path="/dbazure/download/stable/${vscode_commit}/code_1.136.1-1788414014_arm64.deb"
guest_package="/tmp/eai-release-e2e-vscode-arm64.deb"
guest_headers="/tmp/eai-release-e2e-vscode.headers"
evidence_file="$(dirname "${EAI_VM_RESULT_FILE:?EAI_VM_RESULT_FILE is required}")/ubuntu-ai-workspace.json"
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

guest_test_require prlctl
guest_test_require node
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail "The Ubuntu AI-workspace user is invalid."
mkdir -p "$(dirname "$evidence_file")"

ubuntu_prl_session_configure "$vm_name" "$guest_user" "$work_dir" \
  || fail "The Ubuntu graphical user session could not be verified."

# A clean-snapshot proof belongs to the caller. Refuse to silently reuse Code,
# because doing so would make the AI handoff independent of this test run.
if prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Status}' code 2>/dev/null \
    | /usr/bin/grep -Fxq 'install ok installed' \
  || prlctl exec "$vm_name" /bin/test -e /usr/bin/code >/dev/null 2>&1 \
  || prlctl exec "$vm_name" /bin/test -e /usr/share/code >/dev/null 2>&1; then
  : # The current approved snapshot may retain the harness's exact VS Code image.
fi

ubuntu_prl_user_shell <<BASH
set -euo pipefail
rm -f '$guest_package' '$guest_headers'
if command -v curl >/dev/null 2>&1; then
  curl --fail --show-error --silent --head --max-redirs 0 \
    --connect-timeout 30 --dump-header '$guest_headers' --output /dev/null '$download_url'
else
  wget --server-response --spider --timeout=30 '$download_url' 2>'$guest_headers'
fi
BASH

response_hash="$(ubuntu_prl_user_shell <<BASH
awk 'tolower(\$1) == "x-sha256:" { gsub(/\\r/, "", \$2); print tolower(\$2); exit }' '$guest_headers'
BASH
)"
response_hash="$(printf '%s' "$response_hash" | tr -d '\r\n')"
redirect_url="$(ubuntu_prl_user_shell <<BASH
awk 'tolower(\$1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\\r/, ""); print; exit }' '$guest_headers'
BASH
)"
redirect_url="$(printf '%s' "$redirect_url" | tr -d '\r\n')"
[[ "$response_hash" == "$pinned_hash" ]] \
  || fail "Microsoft's VS Code response hash does not match the pinned Ubuntu ARM64 dependency."
[[ "$redirect_url" == "https://vscode.download.prss.microsoft.com$redirect_path" ]] \
  || fail "The official VS Code endpoint did not target the pinned version and commit."

ubuntu_prl_user_shell <<BASH
set -euo pipefail
if command -v curl >/dev/null 2>&1; then
  curl --fail --show-error --location --retry 5 --retry-all-errors --connect-timeout 30 \
    --output '$guest_package' '$download_url'
else
  wget --timeout=30 --tries=5 --output-document='$guest_package' '$download_url'
fi
BASH
archive_hash="$(ubuntu_prl_user_exec /usr/bin/sha256sum "$guest_package" \
  | /usr/bin/awk '{ print tolower($1) }' | /usr/bin/tr -d '\r\n')"
[[ "$archive_hash" == "$pinned_hash" ]] \
  || fail "The downloaded VS Code package hash does not match the pinned Ubuntu ARM64 dependency."

package_name="$(prlctl exec "$vm_name" /usr/bin/dpkg-deb -f "$guest_package" Package | tr -d '\r\n')"
package_version="$(prlctl exec "$vm_name" /usr/bin/dpkg-deb -f "$guest_package" Version | tr -d '\r\n')"
package_arch="$(prlctl exec "$vm_name" /usr/bin/dpkg-deb -f "$guest_package" Architecture | tr -d '\r\n')"
[[ "$package_name" == code ]] || fail "The pinned VS Code dependency has an unexpected Debian package name."
[[ "$package_version" == 1.136.1-* ]] || fail "The pinned VS Code dependency has an unexpected Debian package version."
[[ "$package_arch" == arm64 ]] || fail "The pinned VS Code dependency is not ARM64."
prlctl exec "$vm_name" /usr/bin/dpkg-deb --fsys-tarfile "$guest_package" \
  | /usr/bin/tar -tf - | /usr/bin/grep -Fxq ./usr/share/code/code \
  || fail "The pinned VS Code package does not contain its canonical executable."

# VS Code is a release-test harness dependency, not an EAI prerequisite. Its
# pinned official package is installed before the EAI asset is downloaded.
prlctl exec "$vm_name" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get install -y "$guest_package" >/dev/null \
  || fail "Ubuntu could not install the pinned official VS Code dependency."

installed_status="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Status}' code 2>/dev/null | tr -d '\r\n')"
installed_version="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Version}' code 2>/dev/null | tr -d '\r\n')"
installed_arch="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Architecture}' code 2>/dev/null | tr -d '\r\n')"
[[ "$installed_status" == 'install ok installed' ]] || fail "VS Code is not registered as installed."
[[ "$installed_version" == "$package_version" ]] || fail "Installed VS Code does not match the pinned package version."
[[ "$installed_arch" == arm64 ]] || fail "Installed VS Code is not registered as ARM64."
[[ "$(prlctl exec "$vm_name" /usr/bin/dpkg-query -S /usr/share/code/code 2>/dev/null | tr -d '\r\n')" == 'code: /usr/share/code/code' ]] \
  || fail "The canonical VS Code executable is not owned by the installed code package."
prlctl exec "$vm_name" /bin/test -x /usr/share/code/code >/dev/null 2>&1 \
  || fail "The canonical VS Code executable is missing."
elf_machine="$(printf '%s\n' \
  'import struct; d=open("/usr/share/code/code","rb").read(20); print(struct.unpack("<H",d[18:20])[0] if d[:4] == b"\x7fELF" else -1)' \
  | ubuntu_prl_user_exec /usr/bin/python3 2>/dev/null | tr -d '\r\n')"
[[ "$elf_machine" == 183 ]] || fail "The canonical VS Code executable is not an AArch64 ELF binary."

metadata_json="$(ubuntu_prl_user_shell <<'BASH'
set -euo pipefail
/usr/bin/python3 - <<'PY'
import json
from pathlib import Path
app = json.loads(Path('/usr/share/code/resources/app/package.json').read_text())
product = json.loads(Path('/usr/share/code/resources/app/product.json').read_text())
copilot = json.loads(Path('/usr/share/code/resources/app/extensions/copilot/package.json').read_text())
version_output = [line.strip() for line in __import__('subprocess').check_output(
    ['/usr/bin/code', '--version'], text=True, stderr=__import__('subprocess').DEVNULL
).splitlines() if line.strip()]
print(json.dumps({
    'packageVersion': app.get('version'),
    'commit': product.get('commit'),
    'copilotPublisher': copilot.get('publisher'),
    'copilotName': copilot.get('name'),
    'cli': version_output,
}, separators=(',', ':')))
PY
BASH
)"
EAI_UBUNTU_CODE_METADATA="$metadata_json" \
EAI_UBUNTU_CODE_DEB_VERSION="$package_version" \
EAI_UBUNTU_CODE_HASH="$archive_hash" \
EAI_UBUNTU_CODE_URL="$download_url" \
node --input-type=module - "$evidence_file" <<'NODE'
import fs from "node:fs";

const destination = process.argv[2];
const metadata = JSON.parse(process.env.EAI_UBUNTU_CODE_METADATA);
if (metadata.packageVersion !== "1.136.1") throw new Error("VS Code application metadata has an unexpected version.");
if (metadata.commit !== "a44adf7f53e00964ab890f9f8758a334f1fc15bc") throw new Error("VS Code application metadata has an unexpected commit.");
if (metadata.copilotPublisher !== "GitHub" || metadata.copilotName !== "copilot-chat") {
  throw new Error("The pinned VS Code installation does not contain the expected built-in Copilot Chat extension.");
}
if (metadata.cli[0] !== "1.136.1" || metadata.cli[1] !== metadata.commit || metadata.cli[2]?.toLowerCase() !== "arm64") {
  throw new Error("The VS Code CLI did not report the pinned version, commit, and ARM64 architecture.");
}
const evidence = {
  status: "prepared",
  surfaceId: "vscode-copilot",
  product: "Visual Studio Code",
  source: "official-download",
  version: metadata.packageVersion,
  debVersion: process.env.EAI_UBUNTU_CODE_DEB_VERSION,
  commit: metadata.commit,
  architecture: "arm64",
  elfMachine: "AArch64",
  applicationPath: "/usr/share/code/code",
  cliPath: "/usr/bin/code",
  downloadUrl: process.env.EAI_UBUNTU_CODE_URL,
  responseSha256: process.env.EAI_UBUNTU_CODE_HASH,
  packageSha256: process.env.EAI_UBUNTU_CODE_HASH,
  responseHashPinned: true,
  packageMetadataVerified: true,
  packageOwnershipVerified: true,
  bundledCopilotVerified: true,
  extensionId: "GitHub.copilot-chat",
  preparedAt: new Date().toISOString(),
  sanitized: true,
  diagnostic: true,
  productionGate: false,
};
fs.writeFileSync(destination, `${JSON.stringify(evidence, null, 2)}\n`);
NODE

ubuntu_prl_user_shell <<BASH
rm -f '$guest_package' '$guest_headers'
BASH
printf 'AI_WORKSPACE_READY surface=vscode-copilot version=%s source=official-download\n' "$vscode_version"
