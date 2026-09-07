#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files=(
  "$ROOT/scripts/run-ubuntu-guest-test.sh"
  "$ROOT/scripts/ubuntu-guest-test-core.sh"
  "$ROOT/scripts/ubuntu-guest-session.sh"
  "$ROOT/scripts/prepare-ubuntu-ai-workspace.sh"
  "$ROOT/scripts/login-ubuntu-guest.sh"
)

/bin/bash -n "${files[@]}"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "${files[@]}"
fi
python3 - "$ROOT/scripts/ubuntu-ui-action.py" <<'PY'
from pathlib import Path
import sys

compile(Path(sys.argv[1]).read_text(), sys.argv[1], "exec")
PY

fixture_dir="$(mktemp -d)"
cleanup_fixtures() { rm -rf -- "$fixture_dir"; }
trap cleanup_fixtures EXIT
validator_file="$fixture_dir/core-contract-functions.sh"
/usr/bin/awk '/^validate_npm_provider_values\(\)/,/^}/' \
  "$ROOT/scripts/ubuntu-guest-test-core.sh" >"$validator_file"
/usr/bin/awk '/^gdm_autologin_parser_source\(\)/,/^}/' \
  "$ROOT/scripts/ubuntu-guest-test-core.sh" >>"$validator_file"
# shellcheck source=/dev/null
source "$validator_file"

mkdir -p "$fixture_dir/bin"
cat >"$fixture_dir/bin/npm" <<'FIXTURE'
#!/bin/sh
[ "$1" = --version ] || exit 2
printf '%s\n' 10.9.2
FIXTURE
cat >"$fixture_dir/bin/dpkg-query" <<'FIXTURE'
#!/bin/sh
if [ "$1" = -S ] && [ "$2" = /usr/lib/node_modules/npm/bin/npm-cli.js ]; then
  printf '%s\n' 'nodejs: /usr/lib/node_modules/npm/bin/npm-cli.js'
  exit 0
fi
if [ "$1" = -W ] && [ "$2" = npm ]; then
  exit 1
fi
exit 2
FIXTURE
chmod 0700 "$fixture_dir/bin/npm" "$fixture_dir/bin/dpkg-query"
fixture_npm_version="$("$fixture_dir/bin/npm" --version)"
if "$fixture_dir/bin/dpkg-query" -W npm >/dev/null 2>&1; then
  printf 'The npm-provider fixture unexpectedly exposed a separate npm package.\n' >&2
  exit 1
fi
fixture_npm_target=/usr/lib/node_modules/npm/bin/npm-cli.js
fixture_npm_ownership="$("$fixture_dir/bin/dpkg-query" -S "$fixture_npm_target")"
[[ "$(validate_npm_provider_values "$fixture_npm_version" /usr/bin/npm \
  "$fixture_npm_target" "$fixture_npm_ownership")" == nodejs ]]
reject_npm_provider_fixture() {
  if validate_npm_provider_values "$@" >/dev/null 2>&1; then
    printf 'The npm-provider fixture accepted invalid provider evidence.\n' >&2
    exit 1
  fi
}
reject_npm_provider_fixture invalid /usr/bin/npm "$fixture_npm_target" "$fixture_npm_ownership"
reject_npm_provider_fixture "$fixture_npm_version" /usr/local/bin/npm "$fixture_npm_target" "$fixture_npm_ownership"
reject_npm_provider_fixture "$fixture_npm_version" /usr/bin/npm /tmp/npm-cli.js \
  'nodejs: /tmp/another-npm-cli.js'
reject_npm_provider_fixture "$fixture_npm_version" /usr/bin/npm "$fixture_npm_target" \
  "npm: $fixture_npm_target"
reject_npm_provider_fixture "$fixture_npm_version" /usr/bin/npm "$fixture_npm_target" \
  $'nodejs: /usr/lib/node_modules/npm/bin/npm-cli.js\nother: /usr/lib/node_modules/npm/bin/npm-cli.js'

cat >"$fixture_dir/gdm-valid.conf" <<'FIXTURE'
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = parallels
FIXTURE
[[ "$(gdm_autologin_parser_source | python3 - "$fixture_dir/gdm-valid.conf")" == parallels ]]
cat >"$fixture_dir/gdm-duplicate-option.conf" <<'FIXTURE'
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = parallels
AutomaticLogin = another-user
FIXTURE
if gdm_autologin_parser_source | python3 - "$fixture_dir/gdm-duplicate-option.conf" >/dev/null 2>&1; then
  printf 'The GDM parser accepted an ambiguous duplicate AutomaticLogin option.\n' >&2
  exit 1
fi
cat >"$fixture_dir/gdm-duplicate-section.conf" <<'FIXTURE'
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = parallels
[Daemon]
AutomaticLoginEnable = true
AutomaticLogin = parallels
FIXTURE
if gdm_autologin_parser_source | python3 - "$fixture_dir/gdm-duplicate-section.conf" >/dev/null 2>&1; then
  printf 'The GDM parser accepted ambiguous case-variant daemon sections.\n' >&2
  exit 1
fi

node --input-type=module - "$ROOT" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const root = process.argv[2];
const read = (name) => fs.readFileSync(path.join(root, "scripts", name), "utf8");
const wrapper = read("run-ubuntu-guest-test.sh");
const core = read("ubuntu-guest-test-core.sh");
const session = read("ubuntu-guest-session.sh");
const login = read("login-ubuntu-guest.sh");
const workspace = read("prepare-ubuntu-ai-workspace.sh");
const ui = read("ubuntu-ui-action.py");

if (!wrapper.includes('exec /bin/bash "$hardened_core" "$@"')) throw new Error("Ubuntu wrapper does not delegate to the hardened core.");
const stages = [
  "snapshot-restore", "clean-snapshot-preflight", "prerequisite-contract-validation",
  "ai-workspace-provision", "portal-login",
  "exact-asset-download", "package-metadata-validation", "native-installer", "normal-app-launch",
  "prerequisite-install", "cli-login", "e2e-app-launch", "receipt-validation",
  "remote-app-validation", "exact-project-validation", "ai-handoff-process-validation",
  "browser-auth-state-cleanup", "final-integrity-validation",
];
let cursor = -1;
for (const stage of stages) {
  const next = core.indexOf(`stage ${stage}`);
  if (next <= cursor) throw new Error(`Ubuntu stage is missing or out of order: ${stage}`);
  cursor = next;
}
for (const marker of [
  "verified-clean", "host_hash", "guest_hash", "dpkg-deb -f", "install ok installed",
  "elf_machine", "EAI_VM_INSTALLER_VERIFIED=1", "EAI_VM_PREREQUISITES_PROVEN=1",
  "EAI_VM_PROJECT_VERIFIED=1", "EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1",
  "EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1", "checkpoint_state",
  "Released-product prerequisite defect", "noHarnessPrerequisiteRepair: true",
  "eai-release-ubuntu-vm", "prerequisite-baseline-proven-passed",
  "A pre-launch harness or package mutation installed",
  "tenantWideEnumerationPerformed: false", "noEmitTypecheckPassed",
  "eai-setup-test-v", "eai-setup-ubuntu-arm64.deb",
  "ubuntu-prerequisite-contract.json", "minimumNodeMajor: 24",
  "The Ubuntu diagnostic harness is pinned to EAI CLI 3.15.10",
  "eai.ubuntu-remote-app-checkpoint.v1", "remote-mutation-cleanup-armed",
  "remoteAppCheckpointUncertain", "resourceIdSha256", "createdDuringThisRun",
  "processCwdVerified: true", "processArgumentsInspected: true", 'bindingSource: "exact-process-cwd"',
]) {
  if (!core.includes(marker)) throw new Error(`Ubuntu proof marker is missing: ${marker}`);
}
if (!core.includes("/dev/stdin \"$protected_input\"")) throw new Error("Protected E2E values are not streamed into a user-only file.");
for (const marker of [
  "eai-setup-test-v", "eai-setup-ubuntu-arm64.deb",
  "resources list tenant-vertical-enrollment", "--where", "--limit 2",
  "tenantWideEnumerationPerformed: false", "authorization", "noEmitTypecheckPassed",
]) {
  if (!core.includes(marker)) throw new Error(`Ubuntu exact-proof marker is missing: ${marker}`);
}
if (core.includes("'app', 'list'") || core.includes(" app list ")) {
  throw new Error("Ubuntu remote-app proof must not enumerate the tenant-wide app list.");
}
const e2eLaunch = core.slice(core.indexOf("stage e2e-app-launch"), core.indexOf("receipt_ready=0"));
const enableCheckpoint = e2eLaunch.indexOf("remote_checkpoint_enabled=1");
const armCleanup = e2eLaunch.indexOf("arm_exact_remote_cleanup");
const persistArm = e2eLaunch.indexOf("checkpoint_state");
const launchProduct = e2eLaunch.indexOf('launch_bridge "$e2e_pid_file"');
if (!(enableCheckpoint >= 0 && enableCheckpoint < armCleanup && armCleanup < persistArm && persistArm < launchProduct)) {
  throw new Error("Ubuntu must durably arm exact-name cleanup before the mutating product launch.");
}
for (const marker of [
  "appCreatedConservative: true", "cleanupRequired: true", "remoteMutationCleanupArmed: true",
  "prior.appName !== appName", "exactOldState", "conservativeOrphanPromotion",
]) {
  if (!core.includes(marker)) throw new Error(`Ubuntu orphan checkpoint marker is missing: ${marker}`);
}
const checkpointState = core.slice(core.indexOf("checkpoint_state() {"), core.indexOf("write_failure() {"));
if (checkpointState.indexOf('[[ "$remote_status" != 2 ]]') < checkpointState.lastIndexOf("fs.writeFileSync")) {
  throw new Error("Ubuntu remote-checkpoint ambiguity can escape before durable conservative state is written.");
}
if (!checkpointState.includes("const checkpointUncertain = !exactRemote")) {
  throw new Error("An exact Ubuntu remote checkpoint must clear earlier query uncertainty.");
}
const remoteProbe = core.slice(core.indexOf("probe_remote_app_checkpoint() {"), core.indexOf("arm_exact_remote_cleanup() {"));
const finalRemoteProof = core.slice(core.indexOf("stage remote-app-validation"), core.indexOf("stage remote-app-validation-passed"));
if (!remoteProbe.includes('[ "\\$query_status" -eq 0 ] || exit 5')
    || !remoteProbe.includes("raise SystemExit(3)")) {
  throw new Error("Ubuntu remote checkpoint must distinguish query failure from a verified exact no-match.");
}
for (const [label, source] of [["checkpoint", remoteProbe], ["final", finalRemoteProof]]) {
  const projectCwd = source.indexOf("cd -- '$exact_project'");
  const resourceQuery = source.indexOf("resources list tenant-vertical-enrollment");
  if (!(projectCwd >= 0 && projectCwd < resourceQuery)) {
    throw new Error(`Ubuntu ${label} resources validation is not run inside the exact generated project.`);
  }
  if (!source.includes('json.dumps({"verticalKey":sys.argv[1]})') || source.includes('"equals"')) {
    throw new Error(`Ubuntu ${label} resources validation does not use the canonical scalar verticalKey filter.`);
  }
}
if ((core.match(/json[.]dumps[(][{]"verticalKey":sys[.]argv\[1\][}][)]/g) ?? []).length !== 2
    || core.includes('{"verticalKey":{"equals"')) {
  throw new Error("Both Ubuntu Resource API queries must use only the canonical scalar verticalKey filter.");
}
const scalarFilterFixture = {verticalKey: "test-ubuntu-1788228158725-fee15e"};
if (typeof scalarFilterFixture.verticalKey !== "string"
    || Object.hasOwn(scalarFilterFixture.verticalKey, "equals")) {
  throw new Error("The Ubuntu Resource API filter fixture is not scalar.");
}
const resourceEnvelopeFixture = {
  resources: [{id: "resource-1", data: {verticalKey: scalarFilterFixture.verticalKey, source: "eai-cli"}}],
  totalDocs: 1,
};
if (!Array.isArray(resourceEnvelopeFixture.resources)
    || !Number.isInteger(resourceEnvelopeFixture.totalDocs)
    || resourceEnvelopeFixture.totalDocs !== resourceEnvelopeFixture.resources.length) {
  throw new Error("The Ubuntu Resource API fixture does not use the canonical {resources,totalDocs} envelope.");
}
for (const marker of [
  "durableCreationCheckpointMatched: true", "embeddedChildFieldsEmpty: true",
  "hashlib.sha256(record_id.encode()).hexdigest()", "expected_resource_hash", 'payload.get("totalDocs")',
]) {
  if (!finalRemoteProof.includes(marker)) throw new Error(`Ubuntu final remote proof marker is missing: ${marker}`);
}
const handoffProof = core.slice(core.indexOf("stage ai-handoff-process-validation"), core.indexOf("stage browser-auth-state-cleanup"));
for (const marker of [
  'readlink -f "$process/cwd"', 'read -r -d "" argument', "arguments_inspected=1",
  "processCwdVerified: true", "processArgumentsInspected: true", "exactProjectArgumentPresent",
]) {
  if (!handoffProof.includes(marker)) throw new Error(`Ubuntu handoff process proof marker is missing: ${marker}`);
}
if (!login.includes("find-generic-password") || !login.includes("| input type --stdin")) {
  throw new Error("Ubuntu protected browser login does not stream Keychain input into virtual keys.");
}
for (const marker of ["assert-origin", "AT-SPI", "fresh protected login", "tenant list --format json"]) {
  if (!login.toLowerCase().includes(marker.toLowerCase())) throw new Error(`Ubuntu login proof marker is missing: ${marker}`);
}
for (const marker of [
  "profile_bound_firefox", "eai-release-e2e-browser", "export BROWSER=", "CLI_DISPOSABLE_BROWSER_BOUND",
  'XDG_SESSION_ID=$session', 'firefox_snap_root_proof', 'revision=$(readlink /snap/firefox/current)',
  '"$snap_root/usr/lib/firefox/firefox-bin"', 'case "$process_name" in firefox|firefox-bin',
  'FSTYPE,OPTIONS', 'squashfs', '*,ro,*', 'stop_profile_bound_firefox',
  'EAI_RELEASE_E2E_FIREFOX_PROFILE=$profile',
]) {
  if (!login.includes(marker)) throw new Error(`Ubuntu CLI disposable-browser binding is missing: ${marker}`);
}
for (const marker of [
  "validate_npm_provider_values", 'owner_package" == nodejs', "npmSeparateDebPackageRequired: false",
  "EAI_NPM_PROVIDER_PACKAGE", "npmProvider", "resolvedTarget", "installed_node_package_status",
  "The Ubuntu nodejs package that provides npm is not fully installed.",
  'ownerPackageStatus: "install ok installed"',
]) {
  if (!core.includes(marker)) throw new Error(`Ubuntu npm provider proof marker is missing: ${marker}`);
}
if (/dpkg-query[^\n]*-W[^\n]*npm/.test(core)
    || /for package_name in[^\n]*\bnpm\b/.test(core)) {
  throw new Error("Ubuntu incorrectly requires a separately installed dpkg npm package.");
}
for (const marker of [
  "gdm_autologin_parser_source", "configparser.ConfigParser", "strict=True",
  'name.strip().casefold() == "daemon"', "len(daemon_sections) != 1",
  "target_keys.intersection(parser.defaults())",
]) {
  if (!core.includes(marker)) throw new Error(`Ubuntu effective GDM autologin parser marker is missing: ${marker}`);
}
for (const marker of ["local active", "seat0", "XDG_SESSION_ID", "WAYLAND_DISPLAY", "XAUTHORITY"]) {
  if (!session.toLowerCase().includes(marker.toLowerCase())) throw new Error(`Ubuntu session marker is missing: ${marker}`);
}
if ((session.match(/XDG_SESSION_ID="\$UBUNTU_PRL_SESSION_ID"/g) ?? []).length !== 2) {
  throw new Error("Both Ubuntu user transports must export the verified graphical XDG_SESSION_ID.");
}
for (const marker of ["snap/firefox/common/eai-release-e2e-profile", "/proc/[0-9]*", "kill -KILL"]) {
  if (!session.includes(marker)) throw new Error(`Ubuntu disposable-browser cleanup marker is missing: ${marker}`);
}
for (const marker of ["1.136.1", "baa72f92d3feaa76d015202c57271475ea15809e635587279171a972cdd612a4", "AArch64", "copilot-chat"]) {
  if (!workspace.includes(marker)) throw new Error(`Pinned Ubuntu AI workspace marker is missing: ${marker}`);
}
for (const marker of [
  'command == "assert-origin"', 'get_document_attribute_value("DocURL")',
  "Atspi.StateType.ACTIVE", "Atspi.StateType.SHOWING", "parsed.port in (None, 443)",
  "parsed.username is None", "parsed.password is None",
]) {
  if (!ui.includes(marker)) throw new Error(`Ubuntu active-origin proof marker is missing: ${marker}`);
}
NODE

printf 'Ubuntu release adapter static tests passed.\n'
