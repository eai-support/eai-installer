#!/usr/bin/env bash

# Hardened Ubuntu ARM64 release adapter. Invoked by run-ubuntu-guest-test.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/guest-test-lib.sh"
source "$ROOT/scripts/ubuntu-guest-session.sh"

vm_name="${EAI_UBUNTU_VM_NAME:-Ubuntu 24.04.3 ARM64}"
snapshot_id="${EAI_UBUNTU_SNAPSHOT_ID:-00f4cb1b-09ea-4f06-b41b-3d1d2085e8c7}"
guest_user="${EAI_UBUNTU_GUEST_USER:-parallels}"
autologin_user="${EAI_UBUNTU_AUTOLOGIN_USER:-$guest_user}"
expected_cli_version="${EAI_EXPECTED_CLI_VERSION:-3.15.10}"
admin_service="${EAI_UBUNTU_ADMIN_KEYCHAIN_SERVICE:-eai-release-ubuntu-vm}"
guest_deb="/tmp/eai-setup-under-test.deb"
guest_receipt="/tmp/eai-setup-e2e-receipt.json"
guest_executable="/usr/bin/eai-setup"
normal_pid_file="/tmp/eai-setup-normal.pid"
e2e_pid_file="/tmp/eai-setup-e2e.pid"
browser_profile="/home/$guest_user/snap/firefox/common/eai-release-e2e-profile"
browser_pid_file="$browser_profile/eai-release-e2e-firefox.pid"
firefox_snap_root=""
input_helper="$ROOT/scripts/parallels-input.mjs"
ocr_source="$ROOT/scripts/macos-ocr-match.swift"
ocr_binary="${TMPDIR:-/tmp}/eai-installer-macos-ocr-match"
work_dir="$(mktemp -d)"
host_receipt="$work_dir/desktop-receipt.json"
host_package="$work_dir/project-package.json"
normal_log="$work_dir/normal-app.log"
e2e_log="$work_dir/e2e-app.log"
native_install_log="$work_dir/native-install.log"
project_typecheck_log="$work_dir/project-typecheck.log"
phase="host-preflight"
completed=0
normal_bridge_pid=""
e2e_bridge_pid=""
launched_bridge_pid=""
guest_parent=""
protected_input=""
remote_proof_input=""
remote_proof_output=""
remote_checkpoint_input=""
remote_checkpoint_raw=""
remote_checkpoint_guest=""
remote_checkpoint_host=""
guest_native_log=""
clean_snapshot_verified=0
remote_checkpoint_enabled=0
remote_checkpoint_proven=0
exact_project=""
exact_package=""

stage() {
  phase="$1"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase"
}

input() {
  node "$input_helper" --vm "$vm_name" "$@"
}

screen_has() {
  local pattern="$1"
  local screenshot="$work_dir/screen.png"
  local status=2
  if prlctl capture "$vm_name" --file "$screenshot" >/dev/null 2>&1; then
    set +e
    EAI_OCR_PATTERN="$pattern" "$ocr_binary" "$screenshot" >/dev/null 2>&1
    status=$?
    set -e
  fi
  rm -f -- "$screenshot"
  [[ "$status" == 0 ]]
}

semver_at_least() {
  local value="$1"
  local wanted_major="$2"
  local wanted_minor="$3"
  local wanted_patch="$4"
  [[ "$value" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  local major="${BASH_REMATCH[1]}"
  local minor="${BASH_REMATCH[2]}"
  local patch="${BASH_REMATCH[3]}"
  (( major > wanted_major )) \
    || (( major == wanted_major && minor > wanted_minor )) \
    || (( major == wanted_major && minor == wanted_minor && patch >= wanted_patch ))
}

validate_npm_provider_values() {
  local version="$1"
  local command_path="$2"
  local resolved_target="$3"
  local ownership="$4"
  local owner_package=""
  local owned_path=""
  [[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || return 1
  [[ "$command_path" == /usr/bin/npm ]] || return 1
  [[ "$resolved_target" == /* && "$resolved_target" != *$'\n'* ]] || return 1
  [[ "$ownership" != *$'\n'* && "$ownership" == *': '* ]] || return 1
  owner_package="${ownership%%: *}"
  owned_path="${ownership#*: }"
  [[ "$owner_package" == nodejs && "$owned_path" == "$resolved_target" ]] || return 1
  printf '%s\n' "$owner_package"
}

gdm_autologin_parser_source() {
  /bin/cat <<'PY'
import configparser
import sys

path = sys.argv[1]
parser = configparser.ConfigParser(
    interpolation=None,
    strict=True,
    inline_comment_prefixes=("#", ";"),
)
parser.optionxform = str.lower
try:
    with open(path, encoding="utf-8") as stream:
        parser.read_file(stream)
except (OSError, configparser.Error):
    raise SystemExit(2)
daemon_sections = [name for name in parser.sections() if name.strip().casefold() == "daemon"]
if len(daemon_sections) != 1:
    raise SystemExit(2)
target_keys = {"automaticloginenable", "automaticlogin"}
if target_keys.intersection(parser.defaults()):
    raise SystemExit(2)
daemon = parser._sections[daemon_sections[0]]
if not target_keys.issubset(daemon):
    raise SystemExit(2)
enabled = daemon["automaticloginenable"].strip().casefold()
user = daemon["automaticlogin"].strip()
if enabled != "true" or not user or any(character.isspace() for character in user):
    raise SystemExit(2)
print(user)
PY
}

firefox_snap_root_proof() {
  prlctl exec "$vm_name" /bin/bash -c '
    set -eu
    wrapper=/usr/bin/firefox
    [ -x "$wrapper" ] && [ "$(stat -Lc %u "$wrapper")" = 0 ]
    wrapper_mode=$(stat -Lc %a "$wrapper")
    [ $((8#$wrapper_mode & 022)) -eq 0 ]
    wrapper_real=$(readlink -f "$wrapper")
    case "$wrapper_real" in
      /usr/bin/snap) ;;
      /usr/bin/firefox) grep -Eq "(/snap/bin/firefox|snap[[:space:]]+run[[:space:]]+firefox)" "$wrapper" ;;
      *) exit 1 ;;
    esac
    [ "$(stat -Lc %u "$wrapper_real")" = 0 ]
    wrapper_real_mode=$(stat -Lc %a "$wrapper_real")
    [ $((8#$wrapper_real_mode & 022)) -eq 0 ]
    [ -L /snap/firefox/current ]
    revision=$(readlink /snap/firefox/current)
    case "$revision" in ""|*[!0-9]*) exit 1 ;; esac
    snap_root=/snap/firefox/$revision
    [ "$(readlink -f /snap/firefox/current)" = "$snap_root" ]
    [ -d "$snap_root" ] && [ ! -L "$snap_root" ] && [ "$(stat -Lc %u "$snap_root")" = 0 ]
    root_mode=$(stat -Lc %a "$snap_root")
    [ $((8#$root_mode & 022)) -eq 0 ]
    mount_record=$(findmnt -n -o FSTYPE,OPTIONS --target "$snap_root")
    set -- $mount_record
    [ "${1:-}" = squashfs ]
    case ",${2:-}," in *,ro,*) ;; *) exit 1 ;; esac
    main_binary=$snap_root/usr/lib/firefox/firefox
    main_real=$(readlink -f "$main_binary")
    case "$main_real" in "$snap_root"/*) ;; *) exit 1 ;; esac
    [ -f "$main_real" ] && [ -x "$main_real" ]
    [ "$(stat -Lc %u "$main_real")" = 0 ]
    main_mode=$(stat -Lc %a "$main_real")
    [ $((8#$main_mode & 022)) -eq 0 ]
    printf "%s\n" "$snap_root"
  ' 2>/dev/null | tr -d '\r\n'
}

stop_profile_bound_firefox() {
  [[ "$firefox_snap_root" =~ ^/snap/firefox/[0-9]+$ ]] || return 1
  prlctl exec "$vm_name" /bin/bash -c '
    uid=$1; profile=$2; session=$3; session_type=$4; display=$5; wayland_display=$6; snap_root=$7
    [ "$(readlink -f /snap/firefox/current 2>/dev/null)" = "$snap_root" ] || exit 1
    is_bound() {
      process=$1
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || return 1
      [ -r "$process/cmdline" ] && [ -r "$process/environ" ] || return 1
      executable=$(readlink -f "$process/exe" 2>/dev/null) || return 1
      case "$executable" in
        "$snap_root/usr/lib/firefox/firefox"|"$snap_root/usr/lib/firefox/firefox-bin") ;;
        *) return 1 ;;
      esac
      [ "$(stat -Lc %u "$executable" 2>/dev/null)" = 0 ] || return 1
      executable_mode=$(stat -Lc %a "$executable" 2>/dev/null) || return 1
      [ $((8#$executable_mode & 022)) -eq 0 ] || return 1
      process_name=$(cat "$process/comm" 2>/dev/null) || return 1
      case "$process_name" in firefox|firefox-bin) ;; *) return 1 ;; esac
      profile_match=0
      tr "\0" "\n" < "$process/environ" \
        | grep -Fxq "EAI_RELEASE_E2E_FIREFOX_PROFILE=$profile" && profile_match=1
      previous=""
      while IFS= read -r -d "" argument; do
        if { [ "$previous" = --profile ] || [ "$previous" = -profile ]; } \
          && [ "$argument" = "$profile" ]; then
          profile_match=1
        fi
        case "$argument" in --profile="$profile"|-profile="$profile") profile_match=1 ;; esac
        previous=$argument
      done < "$process/cmdline"
      [ "$profile_match" = 1 ] || return 1
      tr "\0" "\n" < "$process/environ" | grep -Fxq "XDG_SESSION_ID=$session" || return 1
      tr "\0" "\n" < "$process/environ" | grep -Fxq "XDG_RUNTIME_DIR=/run/user/$uid" || return 1
      tr "\0" "\n" < "$process/environ" | grep -Fxq "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" || return 1
      if [ "$session_type" = wayland ]; then
        tr "\0" "\n" < "$process/environ" | grep -Fxq "WAYLAND_DISPLAY=$wayland_display" || return 1
      else
        tr "\0" "\n" < "$process/environ" | grep -Fxq "DISPLAY=$display" || return 1
      fi
    }
    bound_pids() {
      for process in /proc/[0-9]*; do
        is_bound "$process" || continue
        printf "%s\n" "${process##*/}"
      done
    }
    stable_absence=0
    poll=0
    while [ "$poll" -lt 80 ] && [ "$stable_absence" -lt 4 ]; do
      pids=$(bound_pids)
      if [ -z "$pids" ]; then
        stable_absence=$((stable_absence + 1))
      else
        stable_absence=0
        signal=TERM
        [ "$poll" -lt 40 ] || signal=KILL
        for pid in $pids; do kill -"$signal" "$pid" 2>/dev/null || true; done
      fi
      poll=$((poll + 1))
      sleep 0.25
    done
    [ "$stable_absence" -ge 4 ]
  ' _ "$UBUNTU_PRL_UID" "$browser_profile" "$UBUNTU_PRL_SESSION_ID" \
    "$UBUNTU_PRL_SESSION_TYPE" "$UBUNTU_PRL_DISPLAY" "$UBUNTU_PRL_WAYLAND_DISPLAY" \
    "$firefox_snap_root" >/dev/null 2>&1
}

guest_value() {
  printf '%s\n' "$1" | ubuntu_prl_user_shell | tr -d '\r\n'
}

git_version() { ubuntu_prl_user_exec /usr/bin/git --version 2>/dev/null | tr -d '\r\n'; }
node_version() { ubuntu_prl_user_exec /usr/bin/node --version 2>/dev/null | tr -d '\r\n'; }
npm_version() { ubuntu_prl_user_exec /usr/bin/npm --version 2>/dev/null | tr -d '\r\n'; }
eai_version() {
  ubuntu_prl_user_exec "$UBUNTU_PRL_HOME/.eai-setup/npm-global/bin/eai" --version 2>/dev/null \
    | tr -d '\r\n'
}

versions_json() {
  local git_value=""
  local node_value=""
  local npm_value=""
  local eai_value=""
  git_value="$(git_version || true)"
  node_value="$(node_version || true)"
  npm_value="$(npm_version || true)"
  eai_value="$(eai_version || true)"
  node --input-type=module - "$git_value" "$node_value" "$npm_value" "$eai_value" <<'NODE'
const [git, nodeVersion, npm, eai] = process.argv.slice(2);
process.stdout.write(JSON.stringify({git: git || null, node: nodeVersion || null, npm: npm || null, eai: eai || null}));
NODE
}

versions_ready() {
  local value="$1"
  local parsed=""
  local git_value=""
  local node_value=""
  local npm_value=""
  local eai_value=""
  parsed="$(EAI_UBUNTU_VERSION_JSON="$value" node --input-type=module <<'NODE'
const v = JSON.parse(process.env.EAI_UBUNTU_VERSION_JSON);
process.stdout.write([v.git || "", v.node || "", v.npm || "", v.eai || ""].join("\t"));
NODE
)" || return 1
  IFS=$'\t' read -r git_value node_value npm_value eai_value <<<"$parsed"
  [[ "$git_value" == git\ version* ]] \
    && semver_at_least "$node_value" 24 0 0 \
    && semver_at_least "$npm_value" 0 0 0 \
    && [[ "$eai_value" == "$expected_cli_version" ]]
}

process_alive() {
  local pid_file="$1"
  prlctl exec "$vm_name" /bin/bash -c '
    uid=$1; file=$2; exe=$3
    [ -f "$file" ] && [ ! -L "$file" ] || exit 1
    read -r pid < "$file"
    case "$pid" in ""|*[!0-9]*) exit 1;; esac
    [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] || exit 1
    [ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" = "$exe" ] || exit 1
    kill -0 "$pid"
  ' _ "$UBUNTU_PRL_UID" "$pid_file" "$guest_executable" >/dev/null 2>&1
}

stop_process() {
  local pid_file="$1"
  prlctl exec "$vm_name" /bin/bash -c '
    uid=$1; file=$2; exe=$3
    [ -f "$file" ] && [ ! -L "$file" ] || { rm -f "$file"; exit 0; }
    read -r pid < "$file"
    case "$pid" in ""|*[!0-9]*) rm -f "$file"; exit 0;; esac
    if [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] \
      && [ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
  ' _ "$UBUNTU_PRL_UID" "$pid_file" "$guest_executable" >/dev/null 2>&1 || true
}

launch_bridge() {
  local pid_file="$1"
  local log_file="$2"
  local body=""
  body="$(cat)"
  {
    printf 'set -euo pipefail\n'
    printf 'printf "%%s\\n" "$$" >%q\n' "$pid_file"
    printf '%s\n' "$body"
  } | ubuntu_prl_user_shell >"$log_file" 2>&1 &
  launched_bridge_pid=$!
}

sanitize_log() {
  local source="$1"
  local destination="$2"
  [[ -s "$source" ]] || return 0
  EAI_LOG_SOURCE="$source" EAI_LOG_DESTINATION="$destination" node --input-type=module <<'NODE'
import fs from "node:fs";
let value = fs.readFileSync(process.env.EAI_LOG_SOURCE, "utf8");
for (const key of ["EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL"]) {
  const protectedValue = process.env[key];
  if (protectedValue) value = value.split(protectedValue).join("[REDACTED]");
}
value = value
  .replace(/(\bauthorization\s*[:=]\s*)(?:bearer\s+)?[^\r\n]+/gi, "$1[REDACTED]")
  .replace(/([?&](?:code|token|access_token|refresh_token|id_token|client_secret)=)[^&\s"'<>]+/gi, "$1[REDACTED]")
  .replace(/((?:(?:access|refresh|id)[_-]?token|authorization|client[_-]?secret|password)\s*[:=]\s*["']?)[^\s"',;}]+/gi, "$1[REDACTED]");
fs.writeFileSync(process.env.EAI_LOG_DESTINATION, value);
NODE
}

probe_remote_app_checkpoint() {
  [[ "$remote_checkpoint_enabled" == 1 ]] || return 0
  [[ "$remote_checkpoint_proven" != 1 ]] || return 0
  [[ -n "$exact_project" && -n "$remote_checkpoint_input" \
    && -n "$remote_checkpoint_raw" && -n "$remote_checkpoint_guest" \
    && -n "$remote_checkpoint_host" && -n "${exact_cli:-}" \
    && -n "${guest_group:-}" ]] || return 0
  prlctl status "$vm_name" 2>/dev/null | grep -Fq running || return 2
  prlctl exec "$vm_name" /bin/test -d "$exact_project" >/dev/null 2>&1 || return 0
  prlctl exec "$vm_name" /bin/test ! -L "$exact_project" >/dev/null 2>&1 || return 2
  [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "$exact_project" 2>/dev/null | tr -d '\r\n')" == "$UBUNTU_PRL_UID" ]] \
    || return 2

  rm -f -- "$remote_checkpoint_host"
  prlctl exec "$vm_name" /bin/rm -f \
    "$remote_checkpoint_input" "$remote_checkpoint_raw" "$remote_checkpoint_guest" \
    >/dev/null 2>&1 || return 2
  printf '%s\n%s\n' "$EAI_HARNESS_TENANT_ID" "$EAI_VM_PROJECT_NAME" \
    | prlctl exec "$vm_name" /usr/bin/install -m 0600 -o "$guest_user" -g "$guest_group" \
        /dev/stdin "$remote_checkpoint_input" \
    || return 2

  local probe_status=0
  set +e
  ubuntu_prl_user_shell >/dev/null <<BASH
set -euo pipefail
cleanup_remote_checkpoint() { rm -f '$remote_checkpoint_input' '$remote_checkpoint_raw'; }
trap cleanup_remote_checkpoint EXIT
trap 'cleanup_remote_checkpoint; exit 129' HUP
trap 'cleanup_remote_checkpoint; exit 130' INT
trap 'cleanup_remote_checkpoint; exit 143' TERM
exec 3<'$remote_checkpoint_input'
IFS= read -r tenant_id <&3
IFS= read -r app_key <&3
exec 3<&-
rm -f '$remote_checkpoint_input'
cd -- '$exact_project'
where_json="\$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"verticalKey":sys.argv[1]}))' "\$app_key")"
set +e
'$exact_cli' resources list tenant-vertical-enrollment \
  --tenant-id "\$tenant_id" --where "\$where_json" --limit 2 --format json \
  >'$remote_checkpoint_raw' 2>/dev/null
query_status=\$?
set -e
tenant_id=
where_json=
[ "\$query_status" -eq 0 ] || exit 5
/usr/bin/python3 - '$remote_checkpoint_raw' '$remote_checkpoint_guest' "\$app_key" '$exact_project' <<'PY'
import datetime
import hashlib
import json
import os
import re
import sys

source, destination, app_key, expected_cwd = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
if (not isinstance(payload, dict) or not isinstance(payload.get("resources"), list)
        or not isinstance(payload.get("totalDocs"), int)
        or isinstance(payload.get("totalDocs"), bool)):
    raise SystemExit(4)
documents = payload["resources"]
matches = []
for document in documents:
    if not isinstance(document, dict):
        continue
    data = document.get("data") if isinstance(document.get("data"), dict) else document
    if data.get("verticalKey") == app_key:
        matches.append((document, data))
if not matches:
    if documents or payload["totalDocs"] != 0:
        raise SystemExit(4)
    raise SystemExit(3)
if len(matches) != 1 or len(documents) != 1 or payload["totalDocs"] != 1:
    raise SystemExit(4)
record, data = matches[0]
if data.get("source") != "eai-cli":
    raise SystemExit(4)
record_id = next((record.get(key) for key in ("id", "_id")
                  if isinstance(record.get(key), str) and record.get(key)), None)
if not record_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}", record_id):
    raise SystemExit(4)
display_name = next((data.get(key) for key in ("displayName", "name")
                     if isinstance(data.get(key), str) and data.get(key).strip()), None)
if not display_name or len(display_name) > 200 or "\n" in display_name or "\r" in display_name:
    raise SystemExit(4)
created_raw = next((record.get(key) for key in ("createdAt", "created_at") if record.get(key)), None)
if created_raw is None:
    created_raw = next((data.get(key) for key in ("createdAt", "created_at") if data.get(key)), None)
if not isinstance(created_raw, str):
    raise SystemExit(4)
try:
    created_at = datetime.datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
except ValueError:
    raise SystemExit(4)
if created_at.tzinfo is None:
    created_at = created_at.replace(tzinfo=datetime.timezone.utc)
match = re.fullmatch(r"test-ubuntu-([0-9]{13})-[0-9a-f]{6}", app_key)
if not match:
    raise SystemExit(4)
run_started = datetime.datetime.fromtimestamp(int(match.group(1)) / 1000, datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
if created_at < run_started or created_at > now + datetime.timedelta(minutes=5):
    raise SystemExit(4)
def empty_child(value):
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, (list, dict)):
        return len(value) == 0
    return False
for key in ("services", "service", "workflows", "workflow", "setups", "setup"):
    if key in data and not empty_child(data[key]):
        raise SystemExit(4)
if os.path.realpath(os.getcwd()) != expected_cwd:
    raise SystemExit(4)
proof = {
    "schemaVersion": "eai.ubuntu-remote-app-checkpoint.v1",
    "status": "verified-created",
    "platform": "ubuntu",
    "appKeySha256": hashlib.sha256(app_key.encode()).hexdigest(),
    "resourceIdSha256": hashlib.sha256(record_id.encode()).hexdigest(),
    "displayNameSha256": hashlib.sha256(display_name.encode()).hexdigest(),
    "resourceCreatedAt": created_at.astimezone(datetime.timezone.utc).isoformat(),
    "createdDuringThisRun": True,
    "exactMatchCount": 1,
    "serverMatchCountVerified": True,
    "sourceVerified": True,
    "embeddedChildFieldsEmpty": True,
    "projectCwdBound": True,
    "sanitized": True,
    "diagnostic": True,
    "productionGate": False,
    "verifiedAt": now.isoformat(),
}
with open(destination, "x", encoding="utf-8") as output:
    json.dump(proof, output, indent=2)
    output.write("\n")
PY
BASH
  probe_status=$?
  set -e
  prlctl exec "$vm_name" /bin/rm -f "$remote_checkpoint_input" "$remote_checkpoint_raw" \
    >/dev/null 2>&1 || true
  if [[ "$probe_status" == 3 ]]; then
    prlctl exec "$vm_name" /bin/rm -f "$remote_checkpoint_guest" >/dev/null 2>&1 || true
    return 0
  fi
  [[ "$probe_status" == 0 ]] || return 2
  prlctl exec "$vm_name" /bin/test -f "$remote_checkpoint_guest" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/test ! -L "$remote_checkpoint_guest" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/cat "$remote_checkpoint_guest" >"$remote_checkpoint_host" 2>/dev/null \
    || return 2
  prlctl exec "$vm_name" /bin/rm -f "$remote_checkpoint_guest" >/dev/null 2>&1 || return 2

  EAI_REMOTE_CHECKPOINT_SOURCE="$remote_checkpoint_host" \
  EAI_REMOTE_CHECKPOINT_DESTINATION="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-remote-app-checkpoint.json" \
  EAI_REMOTE_CHECKPOINT_APP="$EAI_VM_PROJECT_NAME" \
  node --input-type=module <<'NODE' || return 2
import crypto from "node:crypto";
import fs from "node:fs";
const source = JSON.parse(fs.readFileSync(process.env.EAI_REMOTE_CHECKPOINT_SOURCE, "utf8"));
const expectedHash = crypto.createHash("sha256").update(process.env.EAI_REMOTE_CHECKPOINT_APP).digest("hex");
if (source.schemaVersion !== "eai.ubuntu-remote-app-checkpoint.v1"
    || source.status !== "verified-created" || source.platform !== "ubuntu"
    || source.appKeySha256 !== expectedHash || !/^[0-9a-f]{64}$/.test(source.resourceIdSha256 || "")
    || !/^[0-9a-f]{64}$/.test(source.displayNameSha256 || "")
    || source.createdDuringThisRun !== true || source.exactMatchCount !== 1
    || source.serverMatchCountVerified !== true || source.sourceVerified !== true
    || source.embeddedChildFieldsEmpty !== true || source.projectCwdBound !== true
    || source.sanitized !== true || source.diagnostic !== true || source.productionGate !== false
    || !Number.isFinite(Date.parse(source.resourceCreatedAt))
    || !Number.isFinite(Date.parse(source.verifiedAt))) {
  throw new Error("The Ubuntu remote-app checkpoint is invalid.");
}
fs.writeFileSync(process.env.EAI_REMOTE_CHECKPOINT_DESTINATION, `${JSON.stringify({
  ...source,
  appName: process.env.EAI_REMOTE_CHECKPOINT_APP,
  firstObservedAt: new Date().toISOString(),
}, null, 2)}\n`, {mode: 0o600, flag: "wx"});
NODE
  remote_checkpoint_proven=1
}

arm_exact_remote_cleanup() {
  [[ "$remote_checkpoint_enabled" == 1 ]] || return 2
  EAI_REMOTE_CLEANUP_STATE="$EAI_VM_APP_STATE_FILE" \
  EAI_REMOTE_CLEANUP_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-orphan-cleanup-evidence.json" \
  EAI_REMOTE_CLEANUP_APP="$EAI_VM_PROJECT_NAME" EAI_REMOTE_CLEANUP_PHASE="$phase" \
  node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
const appName = process.env.EAI_REMOTE_CLEANUP_APP;
if (!/^test-ubuntu-[0-9]{13}-[0-9a-f]{6}$/.test(appName || "")) {
  throw new Error("The Ubuntu cleanup arm is not bound to an exact run app name.");
}
const read = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const prior = read(process.env.EAI_REMOTE_CLEANUP_STATE);
if (prior && prior.appName !== appName) throw new Error("The Ubuntu app-state file names another cleanup target.");
const armedAt = new Date().toISOString();
const state = {
  ...(prior || {}),
  appName,
  // This is deliberately conservative: the next product action can create
  // the exact remote app before any product receipt or local package exists.
  // Exact-name cleanup is therefore mandatory from this point onward.
  appCreated: true,
  appCreatedConservative: true,
  creationProven: prior?.creationProven === true,
  cleanupRequired: true,
  state: "remote-mutation-cleanup-armed",
  phase: process.env.EAI_REMOTE_CLEANUP_PHASE,
  remoteMutationCleanupArmed: true,
  remoteMutationCleanupArmedAt: armedAt,
  checkedAt: armedAt,
};
fs.mkdirSync(path.dirname(process.env.EAI_REMOTE_CLEANUP_STATE), {recursive: true});
fs.writeFileSync(process.env.EAI_REMOTE_CLEANUP_STATE, `${JSON.stringify(state, null, 2)}\n`, {mode: 0o600});
fs.writeFileSync(process.env.EAI_REMOTE_CLEANUP_EVIDENCE, `${JSON.stringify({
  schemaVersion: "eai.ubuntu-orphan-cleanup-evidence.v1",
  platform: "ubuntu",
  appName,
  appKeySha256: crypto.createHash("sha256").update(appName).digest("hex"),
  appCreated: true,
  creationProven: false,
  cleanupRequired: true,
  checkpointState: "remote-mutation-cleanup-armed",
  remoteMutationCleanupArmed: true,
  remoteMutationCleanupArmedAt: armedAt,
  exactProjectDirectoryObserved: false,
  exactPackageNameMatched: false,
  exactRemoteAppMatched: false,
  resourceIdSha256: null,
  resourceCreatedAt: null,
  conservativeOrphanPromotion: true,
  tenantWideEnumerationPerformed: false,
  checkedAt: armedAt,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
}, null, 2)}\n`, {mode: 0o600});
NODE
}

checkpoint_state() {
  [[ -n "${EAI_VM_APP_STATE_FILE:-}" && -n "${EAI_VM_PROJECT_NAME:-}" ]] || return 0
  local receipt_copy="$work_dir/checkpoint-receipt.json"
  local package_copy="$work_dir/checkpoint-package.json"
  local remote_copy=""
  local receipt_ok=0
  local package_ok=0
  local directory_ok=0
  local remote_ok=0
  local remote_status=0
  local checkpoint_package="${exact_package:-${guest_parent:-/nonexistent}/$EAI_VM_PROJECT_NAME/package.json}"
  remote_copy="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-remote-app-checkpoint.json"
  rm -f -- "$receipt_copy" "$package_copy"
  if [[ "$remote_checkpoint_enabled" == 1 ]]; then
    probe_remote_app_checkpoint || remote_status=$?
  fi
  if prlctl status "$vm_name" 2>/dev/null | grep -Fq running; then
    if prlctl exec "$vm_name" /bin/test -f "$guest_receipt" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/test ! -L "$guest_receipt" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/cat "$guest_receipt" >"$receipt_copy" 2>/dev/null; then receipt_ok=1; fi
    if [[ -n "$guest_parent" ]] \
      && prlctl exec "$vm_name" /bin/test -f "$checkpoint_package" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/test ! -L "$checkpoint_package" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/cat "$checkpoint_package" >"$package_copy" 2>/dev/null; then package_ok=1; fi
    if [[ "$remote_checkpoint_enabled" == 1 && -n "$exact_project" ]] \
      && prlctl exec "$vm_name" /bin/test -d "$exact_project" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/test ! -L "$exact_project" >/dev/null 2>&1 \
      && [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "$exact_project" 2>/dev/null | tr -d '\r\n')" == "$UBUNTU_PRL_UID" ]]; then
      directory_ok=1
    fi
  fi
  if [[ -f "$remote_copy" && ! -L "$remote_copy" ]]; then remote_ok=1; fi
  EAI_CP_RECEIPT="$receipt_ok" EAI_CP_PACKAGE="$package_ok" \
  EAI_CP_DIRECTORY="$directory_ok" EAI_CP_REMOTE="$remote_ok" EAI_CP_PHASE="$phase" \
  EAI_CP_REMOTE_UNCERTAIN="$([[ "$remote_status" == 2 ]] && printf 1 || printf 0)" \
  EAI_CP_ORPHAN_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-orphan-cleanup-evidence.json" \
  node --input-type=module - "$EAI_VM_APP_STATE_FILE" "$EAI_VM_PROJECT_NAME" \
    "$receipt_copy" "$package_copy" "$remote_copy" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
const [destination, appName, receiptPath, packagePath, remotePath] = process.argv.slice(2);
const read = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const old = read(destination);
const receipt = process.env.EAI_CP_RECEIPT === "1" ? read(receiptPath) : null;
const pkg = process.env.EAI_CP_PACKAGE === "1" ? read(packagePath) : null;
const remote = process.env.EAI_CP_REMOTE === "1" ? read(remotePath) : null;
const exactProject = pkg?.name === `@eai-tools/${appName}`;
const exactDirectory = process.env.EAI_CP_DIRECTORY === "1";
const remoteCheckpointUncertain = process.env.EAI_CP_REMOTE_UNCERTAIN === "1";
const expectedAppHash = crypto.createHash("sha256").update(appName).digest("hex");
const exactRemote = remote?.schemaVersion === "eai.ubuntu-remote-app-checkpoint.v1"
  && remote?.status === "verified-created" && remote?.appName === appName
  && remote?.appKeySha256 === expectedAppHash && remote?.exactMatchCount === 1
  && remote?.createdDuringThisRun === true && remote?.serverMatchCountVerified === true
  && remote?.sourceVerified === true && remote?.embeddedChildFieldsEmpty === true
  && remote?.projectCwdBound === true && remote?.sanitized === true
  && remote?.diagnostic === true && remote?.productionGate === false
  && /^[0-9a-f]{64}$/.test(remote?.resourceIdSha256 || "")
  && /^[0-9a-f]{64}$/.test(remote?.displayNameSha256 || "")
  && Number.isFinite(Date.parse(remote?.resourceCreatedAt))
  && Number.isFinite(Date.parse(remote?.verifiedAt));
if (process.env.EAI_CP_REMOTE === "1" && !exactRemote) {
  throw new Error("The persisted Ubuntu remote-app checkpoint is invalid.");
}
// The released app creates this exact clean-run directory before invoking the
// mutating CLI. Treat its appearance as a conservative cleanup requirement
// even if the process dies before a receipt, package, or API proof is durable.
const possibleRemoteOrphan = exactDirectory && !exactRemote && !exactProject && receipt?.appCreated !== true;
const exactOldState = old?.appName === appName ? old : null;
if (old && !exactOldState) throw new Error("The existing Ubuntu app-state file names another cleanup target.");
const checkpointUncertain = !exactRemote
  && (remoteCheckpointUncertain || exactOldState?.remoteAppCheckpointUncertain === true);
const appCreated = exactOldState?.appCreated === true || receipt?.appCreated === true
  || exactRemote || exactProject || possibleRemoteOrphan;
const state = receipt?.appCreated === true ? "receipt"
  : exactRemote ? "exact-remote-app-checkpoint"
  : exactProject ? "exact-local-project-checkpoint"
  : possibleRemoteOrphan ? "possible-remote-app-orphan"
  : checkpointUncertain && exactOldState?.remoteMutationCleanupArmed === true
    ? "remote-checkpoint-uncertain"
  : exactOldState?.state || "not-proven";
const result = { appName, appCreated, state, phase: process.env.EAI_CP_PHASE,
  receiptCopied: receipt !== null, receiptAppCreated: receipt?.appCreated === true,
  exactPackageNameMatched: exactProject, exactProjectDirectoryObserved: exactDirectory,
  remoteAppCheckpointMatched: exactRemote, cleanupRequired: appCreated,
  remoteAppCheckpointUncertain: checkpointUncertain,
  appCreatedConservative: exactRemote || receipt?.appCreated === true
    ? false : exactOldState?.appCreatedConservative === true || possibleRemoteOrphan || exactProject,
  creationProven: exactRemote || receipt?.appCreated === true,
  exactLocalProjectCreationProxy: exactProject,
  remoteMutationCleanupArmed: exactOldState?.remoteMutationCleanupArmed === true,
  remoteMutationCleanupArmedAt: exactOldState?.remoteMutationCleanupArmedAt || null,
  orphanRiskConservativelyPromoted: possibleRemoteOrphan || exactOldState?.orphanRiskConservativelyPromoted === true
    || exactOldState?.appCreatedConservative === true || exactProject,
  remoteResourceIdSha256: exactRemote ? remote.resourceIdSha256 : exactOldState?.remoteResourceIdSha256 || null,
  remoteResourceCreatedAt: exactRemote ? remote.resourceCreatedAt : exactOldState?.remoteResourceCreatedAt || null,
  checkedAt: new Date().toISOString() };
fs.mkdirSync(path.dirname(destination), {recursive: true});
fs.writeFileSync(destination, `${JSON.stringify(result, null, 2)}\n`, {mode: 0o600});
fs.writeFileSync(process.env.EAI_CP_ORPHAN_EVIDENCE, `${JSON.stringify({
  schemaVersion: "eai.ubuntu-orphan-cleanup-evidence.v1",
  platform: "ubuntu",
  appName,
  appKeySha256: expectedAppHash,
  appCreated,
  creationProven: result.creationProven,
  cleanupRequired: appCreated,
  checkpointState: state,
  exactProjectDirectoryObserved: exactDirectory,
  exactPackageNameMatched: exactProject,
  exactLocalProjectCreationProxy: result.exactLocalProjectCreationProxy,
  exactRemoteAppMatched: exactRemote,
  remoteAppCheckpointUncertain: checkpointUncertain,
  resourceIdSha256: result.remoteResourceIdSha256,
  resourceCreatedAt: result.remoteResourceCreatedAt,
  conservativeOrphanPromotion: result.orphanRiskConservativelyPromoted,
  remoteMutationCleanupArmed: result.remoteMutationCleanupArmed,
  remoteMutationCleanupArmedAt: result.remoteMutationCleanupArmedAt,
  tenantWideEnumerationPerformed: false,
  checkedAt: result.checkedAt,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
}, null, 2)}\n`, {mode: 0o600});
NODE
  [[ "$remote_status" != 2 ]]
}

write_failure() {
  [[ -n "${EAI_VM_RESULT_FILE:-}" && -n "${EAI_VM_APP_STATE_FILE:-}" ]] || return 0
  checkpoint_state || true
  EAI_FAILURE_PHASE="$phase" node --input-type=module - \
    "$EAI_VM_RESULT_FILE" "$EAI_VM_APP_STATE_FILE" "${EAI_VM_PROJECT_NAME:-unknown}" \
    "$work_dir/checkpoint-receipt.json" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [resultPath, statePath, appName, receiptPath] = process.argv.slice(2);
const read = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const old = read(resultPath);
const state = read(statePath) || {appName, appCreated: false, state: "not-proven"};
const receipt = read(receiptPath);
const names = ["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
const allowed = new Set(["passed", "failed", "not-run"]);
const checks = Object.fromEntries(names.map((name) => {
  const value = old?.checks?.[name] || receipt?.checks?.[name];
  return [name, allowed.has(value) ? value : "not-run"];
}));
const redact = (input) => {
  let value = String(input || "");
  for (const key of ["EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL"]) {
    const protectedValue = process.env[key];
    if (protectedValue) value = value.split(protectedValue).join("[REDACTED]");
  }
  return value
    .replace(/(\bauthorization\s*[:=]\s*)(?:bearer\s+)?[^\r\n]+/gi, "$1[REDACTED]")
    .replace(/([?&](?:code|token|access_token|refresh_token|id_token|client_secret)=)[^&\s"'<>]+/gi, "$1[REDACTED]")
    .replace(/((?:(?:access|refresh|id)[_-]?token|client[_-]?secret|password)\s*[:=]\s*["']?)[^\s"',;}]+/gi, "$1[REDACTED]");
};
const result = {...(old || {}), status: "failed", vm: "ubuntu", appName,
  appCreated: state.appCreated === true, cleanupRequested: true,
  failedPhase: old?.failedPhase || process.env.EAI_FAILURE_PHASE, checks,
  failureCheckpoint: state, completedAt: new Date().toISOString(),
  message: redact(old?.message || receipt?.message || `Ubuntu validation stopped during ${process.env.EAI_FAILURE_PHASE}.`)};
fs.mkdirSync(path.dirname(resultPath), {recursive: true});
fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
NODE
}

cleanup() {
  local status=$?
  set +e
  if [[ -n "${UBUNTU_PRL_UID:-}" ]] \
    && prlctl status "$vm_name" 2>/dev/null | grep -Fq running; then
    stop_process "$normal_pid_file"
    stop_process "$e2e_pid_file"
    [[ -n "$protected_input" ]] && prlctl exec "$vm_name" /bin/rm -f "$protected_input" >/dev/null 2>&1
    [[ -n "$remote_proof_input" ]] && prlctl exec "$vm_name" /bin/rm -f "$remote_proof_input" >/dev/null 2>&1
    [[ -n "$remote_proof_output" ]] && prlctl exec "$vm_name" /bin/rm -f "$remote_proof_output" >/dev/null 2>&1
    [[ -n "$remote_checkpoint_input" ]] && prlctl exec "$vm_name" /bin/rm -f "$remote_checkpoint_input" >/dev/null 2>&1
    [[ -n "$remote_checkpoint_raw" ]] && prlctl exec "$vm_name" /bin/rm -f "$remote_checkpoint_raw" >/dev/null 2>&1
    [[ -n "$remote_checkpoint_guest" ]] && prlctl exec "$vm_name" /bin/rm -f "$remote_checkpoint_guest" >/dev/null 2>&1
    if [[ "$clean_snapshot_verified" == 1 ]]; then
      # The clean-state gate proved that no Firefox process/profile predated
      # this run. Stop only the profile-bound browser we launched, then remove
      # its Snap-visible disposable profile (including cookies and its log).
      stop_profile_bound_firefox || true
      ubuntu_disposable_browser_cleanup "$browser_profile" "$browser_pid_file" || true
    fi
    if [[ "$guest_native_log" =~ ^/var/tmp/eai-setup-native-install[.][A-Za-z0-9]+$ ]]; then
      prlctl exec "$vm_name" /bin/cat "$guest_native_log" >"$native_install_log" 2>/dev/null || true
      prlctl exec "$vm_name" /bin/rm -f "$guest_native_log" >/dev/null 2>&1 || true
    fi
  fi
  for pid in "$normal_bridge_pid" "$e2e_bridge_pid"; do
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi
  done
  if [[ "$completed" != 1 && "$status" != 0 ]]; then write_failure; fi
  if [[ -n "${EAI_VM_RESULT_FILE:-}" ]]; then
    sanitize_log "$normal_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-normal-app.log"
    sanitize_log "$e2e_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-e2e-app.log"
    sanitize_log "$native_install_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-native-install.log"
    sanitize_log "$project_typecheck_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-project-typecheck.log"
  fi
  rm -rf -- "$work_dir"
  return "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

guest_test_require prlctl
guest_test_require node
guest_test_require security
guest_test_require_environment
[[ "${EAI_RELEASE_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || guest_test_fail "EAI_RELEASE_VERSION is required."
expected_release_tag="eai-setup-test-v$EAI_RELEASE_VERSION"
expected_asset_name="eai-setup-ubuntu-arm64.deb"
expected_download_url="https://github.com/eai-support/eai-installer/releases/download/$expected_release_tag/$expected_asset_name"
[[ "${EAI_RELEASE_REPO:-}" == eai-support/eai-installer \
  && "${EAI_RELEASE_TAG:-}" == "$expected_release_tag" ]] \
  || guest_test_fail "The Ubuntu adapter requires the exact EAI Setup diagnostic prerelease tag."
[[ "$(basename "$EAI_VM_ASSET")" == "$expected_asset_name" \
  && "$EAI_VM_DOWNLOAD_URL" == "$expected_download_url" ]] \
  || guest_test_fail "The Ubuntu adapter requires the exact published ARM64 prerelease asset URL and filename."
[[ "$expected_cli_version" == 3.15.10 ]] \
  || guest_test_fail "The Ubuntu diagnostic harness is pinned to EAI CLI 3.15.10."
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$autologin_user" == "$guest_user" ]] \
  || guest_test_fail "The Ubuntu test and automatic-login users must be the same valid local account."
[[ -f "$input_helper" && -f "$ocr_source" ]] \
  || guest_test_fail "The Ubuntu input or OCR helper is missing."

# Read no secrets before snapshot restore. Both lookups inspect only protected
# item metadata; values are streamed only at their exact GUI actions later.
EAI_UBUNTU_VM_NAME="$vm_name" EAI_UBUNTU_GUEST_USER="$guest_user" \
  "$ROOT/scripts/login-ubuntu-guest.sh" --preflight \
  || guest_test_fail "The protected Enterprise AI login credential is unavailable."
/usr/bin/security find-generic-password -s "$admin_service" -a "$guest_user" >/dev/null 2>&1 \
  || guest_test_fail "The protected Ubuntu administrator credential is unavailable."
if [[ ! -x "$ocr_binary" || "$ocr_source" -nt "$ocr_binary" ]]; then
  swiftc -O "$ocr_source" -o "$ocr_binary" >/dev/null \
    || guest_test_fail "The private local OCR helper could not be compiled."
fi

stage snapshot-restore
guest_test_restore_snapshot "$vm_name" "$snapshot_id"

stage guest-session
session_ready=0
for _ in $(seq 1 120); do
  if ubuntu_prl_session_configure "$vm_name" "$guest_user" "$work_dir" >/dev/null 2>&1; then
    session_ready=1
    break
  fi
  sleep 2
done
[[ "$session_ready" == 1 ]] \
  || guest_test_fail "The approved Ubuntu snapshot did not reach its expected graphical session."
guest_parent="$UBUNTU_PRL_HOME/EAIReleaseTests"
exact_project="$guest_parent/$EAI_VM_PROJECT_NAME"
exact_package="$exact_project/package.json"
protected_input="/run/user/$UBUNTU_PRL_UID/eai-setup-e2e-input"
remote_proof_input="/run/user/$UBUNTU_PRL_UID/eai-setup-app-proof-input"
remote_proof_output="/run/user/$UBUNTU_PRL_UID/eai-setup-app-proof.json"
remote_checkpoint_input="/run/user/$UBUNTU_PRL_UID/eai-setup-app-checkpoint-input"
remote_checkpoint_raw="/run/user/$UBUNTU_PRL_UID/eai-setup-app-checkpoint-raw.json"
remote_checkpoint_guest="/run/user/$UBUNTU_PRL_UID/eai-setup-app-checkpoint.json"
remote_checkpoint_host="$work_dir/remote-app-checkpoint.json"
checkpoint_state

stage clean-snapshot-preflight
vm_info="$(prlctl list -i "$vm_name" 2>/dev/null || true)"
grep -Fq 'GuestTools: state=installed' <<<"$vm_info" \
  || guest_test_fail "Parallels Tools are not reported as installed in the Ubuntu guest."
guest_os="$(prlctl exec "$vm_name" /bin/bash -c '. /etc/os-release; printf "%s %s" "$ID" "$VERSION_ID"' 2>/dev/null | tr -d '\r\n')"
[[ "$guest_os" == 'ubuntu 24.04' ]] || guest_test_fail "The selected guest is not Ubuntu 24.04."
guest_arch="$(prlctl exec "$vm_name" /usr/bin/uname -m 2>/dev/null | tr -d '\r\n')"
dpkg_arch="$(prlctl exec "$vm_name" /usr/bin/dpkg --print-architecture 2>/dev/null | tr -d '\r\n')"
[[ "$guest_arch" == aarch64 && "$dpkg_arch" == arm64 ]] \
  || guest_test_fail "The Ubuntu release guest is not ARM64."
configured_autologin="$(gdm_autologin_parser_source \
  | prlctl exec "$vm_name" /usr/bin/python3 - /etc/gdm3/custom.conf 2>/dev/null \
  | tr -d '\r\n')" \
  || guest_test_fail "Ubuntu GDM automatic login has no unique effective [daemon] configuration."
[[ "$configured_autologin" == "$guest_user" ]] \
  || guest_test_fail "Ubuntu GDM automatic login is not configured for the expected test user."
prlctl capture "$vm_name" --file "$work_dir/ubuntu-control.png" >/dev/null 2>&1 \
  || guest_test_fail "Parallels could not capture the Ubuntu guest display."
[[ -s "$work_dir/ubuntu-control.png" ]] || guest_test_fail "The Ubuntu display capture is empty."
ubuntu_prl_user_exec /usr/bin/python3 -c \
  'import gi; gi.require_version("Atspi", "2.0"); from gi.repository import Atspi' >/dev/null 2>&1 \
  || guest_test_fail "The Ubuntu desktop does not expose its built-in AT-SPI accessibility channel."
firefox_snap_root="$(firefox_snap_root_proof)" \
  || guest_test_fail "Firefox is not bound to a root-owned, read-only installed Snap revision."

for package_name in eai-setup code git nodejs; do
  if prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null \
      | grep -Fxq 'install ok installed'; then
    guest_test_fail "The approved Ubuntu snapshot already contains $package_name."
  fi
done
for command_name in git node npm eai code eai-setup; do
  if printf 'command -v %q >/dev/null 2>&1\n' "$command_name" | ubuntu_prl_user_shell >/dev/null 2>&1; then
    guest_test_fail "The approved Ubuntu snapshot already exposes $command_name."
  fi
done
for path_value in \
  "$UBUNTU_PRL_HOME/.eai" "$UBUNTU_PRL_HOME/.eai-setup" \
  "$UBUNTU_PRL_HOME/.config/eai" "$UBUNTU_PRL_HOME/.config/EAI Setup" \
  "$UBUNTU_PRL_HOME/.mozilla/firefox" "$UBUNTU_PRL_HOME/snap/firefox/common/.mozilla/firefox" \
  "$guest_parent" \
  /usr/bin/eai-setup /usr/bin/code /usr/share/code \
  "$guest_deb" "$guest_receipt" "$normal_pid_file" "$e2e_pid_file" \
  "$browser_profile" "$browser_pid_file" \
  "$protected_input" "$remote_proof_input" "$remote_proof_output" \
  "$remote_checkpoint_input" "$remote_checkpoint_raw" "$remote_checkpoint_guest"; do
  if prlctl exec "$vm_name" /bin/test -e "$path_value" >/dev/null 2>&1; then
    guest_test_fail "The approved Ubuntu snapshot contains release-test state or a prior tool installation."
  fi
done
process_names="$(prlctl exec "$vm_name" /bin/ps -eo comm= 2>/dev/null || true)"
grep -Fxq prltoolsd <<<"$process_names" \
  || guest_test_fail "Parallels Tools are not running in the Ubuntu guest."
if grep -Eq '^(eai-setup|firefox|firefox-bin|code)$' <<<"$process_names"; then
  guest_test_fail "The approved Ubuntu snapshot already has a release-test application process."
fi
EAI_UBUNTU_BASELINE_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-clean-snapshot.json" \
EAI_UBUNTU_SNAPSHOT_PROOF="$(printf '%s' "$snapshot_id" | tr -d '{}')" \
EAI_UBUNTU_USER_PROOF="$guest_user" EAI_UBUNTU_SESSION_PROOF="$UBUNTU_PRL_SESSION_TYPE" \
node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {
  status: "verified-clean", platform: "ubuntu", os: "Ubuntu 24.04",
  architecture: "arm64", snapshotId: process.env.EAI_UBUNTU_SNAPSHOT_PROOF,
  expectedUser: process.env.EAI_UBUNTU_USER_PROOF, autoLoginVerified: true,
  graphicalSession: process.env.EAI_UBUNTU_SESSION_PROOF,
  localActiveSeat0SessionVerified: true, parallelsToolsVerified: true,
  atSpiVerified: true,
  absentBeforeTest: ["git", "node", "npm", "eai", "eai-setup", "vscode", "eai-auth-state", "test-artifacts"],
  verifiedAt: new Date().toISOString(), sanitized: true, diagnostic: true, productionGate: false,
};
fs.writeFileSync(process.env.EAI_UBUNTU_BASELINE_FILE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
before_versions='{"git":null,"node":null,"npm":null,"eai":null}'
stage clean-snapshot-preflight-passed
clean_snapshot_verified=1

stage prerequisite-contract-validation
# Record the released-product contract without predicting apt-get update from
# stale snapshot indexes or repairing the guest. The post-product proof below
# validates the actual installed Node.js/npm/CLI versions and package owners.
EAI_UBUNTU_CONTRACT_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-prerequisite-contract.json" \
EAI_UBUNTU_EXPECTED_CLI="$expected_cli_version" node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {
  status: "pinned", platform: "ubuntu", minimumNodeMajor: 24,
  npmRequired: true, npmMinimumVersionImposedByHarness: false,
  expectedCliVersion: process.env.EAI_UBUNTU_EXPECTED_CLI,
  expectedCliVersionPinned: process.env.EAI_UBUNTU_EXPECTED_CLI === "3.15.10",
  aptCandidatePredictedByHarness: false, aptIndexesRefreshedByHarness: false,
  repositoryAddedByHarness: false,
  noHarnessPrerequisiteRepair: true, verifiedAt: new Date().toISOString(),
  sanitized: true, diagnostic: true, productionGate: false,
};
fs.writeFileSync(process.env.EAI_UBUNTU_CONTRACT_FILE, `${JSON.stringify(evidence, null, 2)}\n`, {mode: 0o600});
NODE
stage prerequisite-contract-validation-passed

stage ai-workspace-provision
EAI_UBUNTU_VM_NAME="$vm_name" EAI_UBUNTU_GUEST_USER="$guest_user" \
  "$ROOT/scripts/prepare-ubuntu-ai-workspace.sh"
stage ai-workspace-provision-passed

stage portal-login
EAI_UBUNTU_VM_NAME="$vm_name" EAI_UBUNTU_GUEST_USER="$guest_user" \
  EAI_UBUNTU_PRESERVE_BROWSER=1 \
  "$ROOT/scripts/login-ubuntu-guest.sh" --portal-only \
  || guest_test_fail "A fresh protected Enterprise AI portal login failed in Ubuntu."
stage portal-login-passed

host_hash="$(guest_test_host_sha256)"
[[ "$host_hash" =~ ^[0-9a-f]{64}$ ]] || guest_test_fail "The host release asset hash is invalid."
stage exact-asset-download
ubuntu_prl_user_shell <<BASH
set -euo pipefail
umask 077
rm -f '$guest_deb'
curl --fail --show-error --location --retry 5 --retry-all-errors --connect-timeout 30 \
  --output '$guest_deb' '$EAI_VM_DOWNLOAD_URL'
test -f '$guest_deb'
test ! -L '$guest_deb'
BASH
guest_hash="$(ubuntu_prl_user_exec /usr/bin/sha256sum "$guest_deb" \
  | awk '{print tolower($1)}' | tr -d '\r\n')"
[[ "$guest_hash" == "$host_hash" ]] \
  || guest_test_fail "The guest package hash does not match the host release asset before installation."
stage exact-asset-download-passed

stage package-metadata-validation
deb_name="$(prlctl exec "$vm_name" /usr/bin/dpkg-deb -f "$guest_deb" Package | tr -d '\r\n')"
deb_version="$(prlctl exec "$vm_name" /usr/bin/dpkg-deb -f "$guest_deb" Version | tr -d '\r\n')"
deb_arch="$(prlctl exec "$vm_name" /usr/bin/dpkg-deb -f "$guest_deb" Architecture | tr -d '\r\n')"
[[ "$deb_name" == eai-setup && "$deb_version" == "$EAI_RELEASE_VERSION" && "$deb_arch" == arm64 ]] \
  || guest_test_fail "The release asset Debian name, version, or architecture is incorrect."
prlctl exec "$vm_name" /bin/bash -c '
  set -o pipefail
  dpkg-deb --fsys-tarfile "$1" | tar -tvf - ./usr/bin/eai-setup \
    | awk "NR == 1 && /^-rwx/ { found=1 } END { exit(found ? 0 : 1) }"
' _ "$guest_deb" >/dev/null 2>&1 \
  || guest_test_fail "The release package does not contain an executable canonical payload."
stage package-metadata-validation-passed

stage native-installer
guest_native_log="$(prlctl exec "$vm_name" /usr/bin/mktemp \
  /var/tmp/eai-setup-native-install.XXXXXXXX 2>/dev/null | tr -d '\r\n')"
[[ "$guest_native_log" =~ ^/var/tmp/eai-setup-native-install[.][A-Za-z0-9]+$ ]] \
  || guest_test_fail "Ubuntu could not allocate a protected native-installer log."
prlctl exec "$vm_name" /bin/test -f "$guest_native_log" >/dev/null 2>&1 \
  && prlctl exec "$vm_name" /bin/test ! -L "$guest_native_log" >/dev/null 2>&1 \
  && [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "$guest_native_log" 2>/dev/null | tr -d '\r\n')" == 0 ]] \
  || guest_test_fail "The protected native-installer log is not a root-owned regular file."
prlctl exec "$vm_name" /bin/bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "$1" > "$2" 2>&1
' _ "$guest_deb" "$guest_native_log" || guest_test_fail "Ubuntu apt could not install the exact release package."
installed_status="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Status}' eai-setup 2>/dev/null | tr -d '\r\n')"
installed_version="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Version}' eai-setup 2>/dev/null | tr -d '\r\n')"
installed_arch="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Architecture}' eai-setup 2>/dev/null | tr -d '\r\n')"
[[ "$installed_status" == 'install ok installed' && "$installed_version" == "$EAI_RELEASE_VERSION" \
  && "$installed_arch" == arm64 ]] \
  || guest_test_fail "The installed package database proof is incorrect."
[[ "$(prlctl exec "$vm_name" /usr/bin/dpkg-query -S "$guest_executable" 2>/dev/null | tr -d '\r\n')" == "eai-setup: $guest_executable" ]] \
  || guest_test_fail "The canonical executable is not owned by eai-setup."
if ! {
  prlctl exec "$vm_name" /bin/test -f "$guest_executable" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/test ! -L "$guest_executable" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/test -x "$guest_executable" >/dev/null 2>&1
}; then
  guest_test_fail "The canonical EAI Setup path is not a regular executable."
fi
elf_machine="$(prlctl exec "$vm_name" /usr/bin/python3 -c \
  'import struct,sys; d=open(sys.argv[1],"rb").read(20); print(struct.unpack("<H",d[18:20])[0] if d[:4] == b"\x7fELF" else -1)' \
  "$guest_executable" 2>/dev/null | tr -d '\r\n')"
[[ "$elf_machine" == 183 ]] || guest_test_fail "The installed executable is not AArch64 ELF."
executable_hash="$(prlctl exec "$vm_name" /usr/bin/sha256sum "$guest_executable" \
  | awk '{print tolower($1)}' | tr -d '\r\n')"
[[ "$executable_hash" =~ ^[0-9a-f]{64}$ ]] \
  || guest_test_fail "The installed executable hash could not be recorded."
EAI_UBUNTU_INSTALL_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-native-install.json" \
EAI_UBUNTU_ASSET_HASH="$host_hash" EAI_UBUNTU_EXE_HASH="$executable_hash" \
EAI_UBUNTU_INSTALL_VERSION="$installed_version" node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {status: "verified", platform: "ubuntu",
  nativeInstaller: "apt-get local Debian package", package: "eai-setup",
  version: process.env.EAI_UBUNTU_INSTALL_VERSION, architecture: "arm64",
  packageDatabaseStatus: "install ok installed", canonicalExecutable: "/usr/bin/eai-setup",
  packageOwnershipVerified: true, regularExecutableVerified: true, elfMachine: "AArch64",
  assetSha256: process.env.EAI_UBUNTU_ASSET_HASH, executableSha256: process.env.EAI_UBUNTU_EXE_HASH,
  installedAt: new Date().toISOString(), sanitized: true, diagnostic: true, productionGate: false};
fs.writeFileSync(process.env.EAI_UBUNTU_INSTALL_FILE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
stage native-installer-passed

prlctl exec "$vm_name" /bin/mkdir -p "$guest_parent"
prlctl exec "$vm_name" /bin/chown "$guest_user:$guest_user" "$guest_parent"
prlctl exec "$vm_name" /bin/rm -f "$guest_receipt" "$normal_pid_file" "$e2e_pid_file"

stage prerequisite-baseline-proven
# The pinned AI-workspace package and the native EAI Setup package are allowed
# harness/install mutations, but neither may pre-seed the prerequisites that
# the released GUI must install below. Re-prove absence at the last possible
# point before launching that GUI so the transition is attributable to it.
for package_name in git nodejs; do
  if prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null \
      | grep -Fxq 'install ok installed'; then
    guest_test_fail "A pre-launch harness or package mutation installed $package_name before the released GUI ran."
  fi
done
for command_name in git node npm eai; do
  if printf 'command -v %q >/dev/null 2>&1\n' "$command_name" | ubuntu_prl_user_shell >/dev/null 2>&1; then
    guest_test_fail "A pre-launch harness or package mutation exposed $command_name before the released GUI ran."
  fi
done
for path_value in \
  "$UBUNTU_PRL_HOME/.eai" "$UBUNTU_PRL_HOME/.eai-setup" \
  "$UBUNTU_PRL_HOME/.config/eai" "$UBUNTU_PRL_HOME/.config/EAI Setup"; do
  if prlctl exec "$vm_name" /bin/test -e "$path_value" >/dev/null 2>&1; then
    guest_test_fail "A pre-launch harness or package mutation created EAI prerequisite or authentication state."
  fi
done
stage prerequisite-baseline-proven-passed

stage normal-app-launch
launch_bridge "$normal_pid_file" "$normal_log" <<BASH
exec '$guest_executable'
BASH
normal_bridge_pid="$launched_bridge_pid"
for _ in $(seq 1 30); do
  process_alive "$normal_pid_file" && break
  sleep 1
done
process_alive "$normal_pid_file" \
  || guest_test_fail "The exact released Ubuntu application did not start in the graphical session."
kill -0 "$normal_bridge_pid" 2>/dev/null \
  || guest_test_fail "The normal Ubuntu application started without its host bridge."

stage prerequisite-install
ready_reads=0
node_defect_reads=0
polkit_approvals=0
liveness_failures=0
versions=""
for attempt in $(seq 1 300); do
  if process_alive "$normal_pid_file"; then
    liveness_failures=0
  else
    liveness_failures=$((liveness_failures + 1))
    [[ "$liveness_failures" -lt 5 ]] \
      || guest_test_fail "The released Ubuntu application exited during prerequisite installation."
  fi
  kill -0 "$normal_bridge_pid" 2>/dev/null \
    || guest_test_fail "The normal Ubuntu application bridge exited unexpectedly."

  if screen_has 'Authentication Required' \
    && { screen_has 'Authentication is required' || screen_has 'Password'; }; then
    [[ "$polkit_approvals" -lt 6 ]] \
      || guest_test_fail "The Ubuntu product path requested too many administrator approvals."
    /usr/bin/security find-generic-password -s "$admin_service" -a "$guest_user" -w \
      | input type --stdin
    input key enter
    polkit_approvals=$((polkit_approvals + 1))
    printf '%s ubuntu-polkit-credential-submitted\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  versions="$(versions_json || true)"
  if [[ -n "$versions" ]] && versions_ready "$versions" && screen_has 'Sign in to EAI'; then
    ready_reads=$((ready_reads + 1))
    [[ "$ready_reads" -ge 2 ]] && break
  else
    ready_reads=0
  fi

  observed_node="$(EAI_UBUNTU_VERSION_JSON="$versions" node --input-type=module <<'NODE'
try { process.stdout.write(JSON.parse(process.env.EAI_UBUNTU_VERSION_JSON).node || ""); } catch {}
NODE
)"
  if [[ -n "$observed_node" ]] && ! semver_at_least "$observed_node" 24 0 0 \
    && screen_has 'Node.js 24' && { screen_has 'needs attention' || screen_has 'not ready'; }; then
    node_defect_reads=$((node_defect_reads + 1))
  else
    node_defect_reads=0
  fi
  if [[ "$node_defect_reads" -ge 3 ]]; then
    guest_test_fail "Released-product prerequisite defect: EAI Setup installed ${observed_node}, below Node.js 24. The harness did not repair or replace it."
  fi
  if (( attempt % 15 == 0 )); then
    printf '%s prerequisite-install-still-running\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  sleep 4
done
[[ "$ready_reads" -ge 2 ]] \
  || guest_test_fail "The released Ubuntu app did not reach stable Git/Node.js 24/npm/EAI CLI readiness within 20 minutes."

after_git="$(git_version)"
after_node="$(node_version)"
after_npm="$(npm_version)"
after_eai="$(eai_version)"
versions_ready "$(versions_json)" \
  || guest_test_fail "Installed prerequisite versions do not satisfy the Ubuntu release contract."
[[ "$(guest_value 'command -v git')" == /usr/bin/git ]] \
  || guest_test_fail "Git was not installed at the expected system path."
[[ "$(guest_value 'command -v node')" == /usr/bin/node ]] \
  || guest_test_fail "Node.js was not installed at the expected system path."
npm_command_path="$(guest_value 'command -v npm')"
[[ "$npm_command_path" == /usr/bin/npm ]] \
  || guest_test_fail "npm was not installed at the expected system path."
exact_cli="$UBUNTU_PRL_HOME/.eai-setup/npm-global/bin/eai"
[[ "$(guest_value 'command -v eai')" == "$exact_cli" ]] \
  || guest_test_fail "The EAI CLI was not installed at EAI Setup's user prefix."
prlctl exec "$vm_name" /usr/bin/dpkg-query -S /usr/bin/git >/dev/null 2>&1 \
  || guest_test_fail "Git is not owned by an installed Ubuntu package."
node_target="$(prlctl exec "$vm_name" /usr/bin/readlink -f /usr/bin/node | tr -d '\r\n')"
npm_target="$(prlctl exec "$vm_name" /usr/bin/readlink -f /usr/bin/npm 2>/dev/null | tr -d '\r\n')" \
  || guest_test_fail "The exact /usr/bin/npm target could not be resolved."
prlctl exec "$vm_name" /bin/bash -c '
  target=$1
  [ -f "$target" ] && [ ! -L "$target" ] && [ "$(stat -Lc %u "$target")" = 0 ]
  mode=$(stat -Lc %a "$target")
  [ $((8#$mode & 022)) -eq 0 ]
' _ "$npm_target" >/dev/null 2>&1 \
  || guest_test_fail "The resolved npm target is not a root-owned, non-writable regular file."
prlctl exec "$vm_name" /usr/bin/dpkg-query -S "$node_target" >/dev/null 2>&1 \
  || guest_test_fail "Node.js is not owned by an installed Ubuntu package."
npm_ownership="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -S "$npm_target" 2>/dev/null | tr -d '\r')" \
  || guest_test_fail "The resolved npm target is not owned by an installed Ubuntu package."
npm_provider_package="$(validate_npm_provider_values \
  "$after_npm" "$npm_command_path" "$npm_target" "$npm_ownership")" \
  || guest_test_fail "npm is not the exact /usr/bin/npm command provided by the installed nodejs package."
[[ "$npm_provider_package" == nodejs ]] \
  || guest_test_fail "The resolved npm target is not provided by nodejs."
cli_package="$UBUNTU_PRL_HOME/.eai-setup/npm-global/lib/node_modules/@enterpriseai/cli/package.json"
cli_package_version="$(ubuntu_prl_user_exec /usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$cli_package" 2>/dev/null | tr -d '\r\n')"
[[ "$cli_package_version" == "$expected_cli_version" ]] \
  || guest_test_fail "The EAI CLI package metadata does not match its executable version."
installed_node_package_status="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Status}' nodejs 2>/dev/null | tr -d '\r\n')"
[[ "$installed_node_package_status" == 'install ok installed' ]] \
  || guest_test_fail "The Ubuntu nodejs package that provides npm is not fully installed."
installed_node_package_version="$(prlctl exec "$vm_name" /usr/bin/dpkg-query -W -f='${Version}' nodejs 2>/dev/null | tr -d '\r\n')"
semver_at_least "$installed_node_package_version" 24 0 0 \
  || guest_test_fail "The installed Ubuntu nodejs package is below the pinned Node.js 24 minimum."

EAI_UBUNTU_PREREQ_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-prerequisite-transition.json" \
EAI_AFTER_GIT="$after_git" EAI_AFTER_NODE="$after_node" EAI_AFTER_NPM="$after_npm" \
EAI_AFTER_EAI="$after_eai" EAI_NODE_PACKAGE_VERSION="$installed_node_package_version" \
EAI_NPM_COMMAND_PATH="$npm_command_path" EAI_NPM_RESOLVED_TARGET="$npm_target" \
EAI_NPM_PROVIDER_PACKAGE="$npm_provider_package" EAI_EXPECTED_CLI="$expected_cli_version" \
EAI_POLKIT_APPROVALS="$polkit_approvals" node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {status: "verified", platform: "ubuntu", normalReleasedAppLaunched: true,
  prerequisitesAbsentBeforeLaunch: true, noHarnessPrerequisiteRepair: true,
  transitionObserved: true, versions: {git: process.env.EAI_AFTER_GIT, node: process.env.EAI_AFTER_NODE,
    npm: process.env.EAI_AFTER_NPM, eai: process.env.EAI_AFTER_EAI,
    nodePackage: process.env.EAI_NODE_PACKAGE_VERSION},
  node24OrLater: true, npmAvailable: true, npmVersionParsed: true,
  npmProvider: {commandPath: process.env.EAI_NPM_COMMAND_PATH,
    resolvedTarget: process.env.EAI_NPM_RESOLVED_TARGET,
    ownerPackage: process.env.EAI_NPM_PROVIDER_PACKAGE,
    ownerPackageVersion: process.env.EAI_NODE_PACKAGE_VERSION,
    ownerPackageStatus: "install ok installed"},
  npmSeparateDebPackageRequired: false,
  expectedCliVersion: process.env.EAI_EXPECTED_CLI,
  expectedCliVersionPinned: process.env.EAI_EXPECTED_CLI === "3.15.10", packageOwnershipVerified: true,
  eaiUserPrefixVerified: true, graphicalPolkitApprovalCount: Number(process.env.EAI_POLKIT_APPROVALS),
  verifiedAt: new Date().toISOString(), sanitized: true, diagnostic: true, productionGate: false};
fs.writeFileSync(process.env.EAI_UBUNTU_PREREQ_FILE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
stage prerequisite-install-passed

stage normal-app-stop
stop_process "$normal_pid_file"
process_alive "$normal_pid_file" \
  && guest_test_fail "The normal Ubuntu application did not stop before CLI login."
if [[ "$normal_bridge_pid" =~ ^[1-9][0-9]*$ ]]; then wait "$normal_bridge_pid" 2>/dev/null || true; fi
normal_bridge_pid=""

stage cli-login
EAI_UBUNTU_VM_NAME="$vm_name" EAI_UBUNTU_GUEST_USER="$guest_user" \
  "$ROOT/scripts/login-ubuntu-guest.sh" --cli-only \
  || guest_test_fail "The fresh EAI CLI browser login or tenant verification failed in Ubuntu."
EAI_UBUNTU_AUTH_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-authentication.json" \
node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {status: "verified", platform: "ubuntu", publicEntryPointUsed: true,
  publicEntryPoint: "https://www.enterpriseaigroup.com/sign-in",
  disposableFirefoxProfile: true, cachedPortalSessionRejected: true,
  cliBrowserLauncherEnvironmentBound: true, cliCallbackDisposableProfileBound: true,
  cliCallbackGraphicalEnvironmentBound: true, cliCallbackFirefoxExecutableVerified: true,
  httpsOriginsVerifiedWithAtSpi: true, protectedCredentialStreamedAsVirtualKeys: true,
  credentialPresentInArgv: false, clipboardUsed: false, freshCliLoginCompleted: true,
  activeIdentityMatchedProtectedAccount: true, activeDirectTenantMembershipMatched: true,
  verifiedAt: new Date().toISOString(), sanitized: true, diagnostic: true, productionGate: false};
fs.writeFileSync(process.env.EAI_UBUNTU_AUTH_FILE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
stage cli-login-passed

second_executable_hash="$(prlctl exec "$vm_name" /usr/bin/sha256sum "$guest_executable" \
  | awk '{print tolower($1)}' | tr -d '\r\n')"
[[ "$second_executable_hash" == "$executable_hash" ]] \
  || guest_test_fail "The installed executable changed between prerequisite and E2E launches."

stage e2e-app-launch
prlctl exec "$vm_name" /bin/rm -f "$guest_receipt" "$e2e_pid_file" "$protected_input"
guest_group="$(prlctl exec "$vm_name" /usr/bin/id -gn "$guest_user" 2>/dev/null | tr -d '\r\n')"
[[ "$guest_group" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] \
  || guest_test_fail "The Ubuntu test user's primary group is invalid."
# Tenant ID and project name are streamed, never placed in a Parallels argv or
# persisted in evidence. The user-only file is deleted before exec.
printf '%s\n%s\n' "$EAI_HARNESS_TENANT_ID" "$EAI_VM_PROJECT_NAME" \
  | prlctl exec "$vm_name" /usr/bin/install -m 0600 -o "$guest_user" -g "$guest_group" \
      /dev/stdin "$protected_input"
remote_checkpoint_enabled=1
arm_exact_remote_cleanup \
  || guest_test_fail "The exact-name Ubuntu orphan-cleanup checkpoint could not be armed."
checkpoint_state \
  || guest_test_fail "The armed Ubuntu orphan-cleanup checkpoint could not be persisted."
launch_bridge "$e2e_pid_file" "$e2e_log" <<BASH
exec 3<'$protected_input'
IFS= read -r EAI_SETUP_E2E_COMPANY_TENANT <&3
IFS= read -r EAI_SETUP_E2E_PROJECT_NAME <&3
exec 3<&-
rm -f '$protected_input'
export EAI_SETUP_E2E=1 EAI_SETUP_E2E_COMPANY_TENANT EAI_SETUP_E2E_PROJECT_NAME
export EAI_SETUP_E2E_DIRECTORY='$guest_parent'
export EAI_SETUP_E2E_RECEIPT_FILE='$guest_receipt'
exec '$guest_executable'
BASH
e2e_bridge_pid="$launched_bridge_pid"
for _ in $(seq 1 30); do
  process_alive "$e2e_pid_file" && break
  sleep 1
done
process_alive "$e2e_pid_file" \
  || guest_test_fail "The exact released Ubuntu E2E application did not start."
kill -0 "$e2e_bridge_pid" 2>/dev/null \
  || guest_test_fail "The Ubuntu E2E application started without its host bridge."
prlctl exec "$vm_name" /bin/test ! -e "$protected_input" >/dev/null 2>&1 \
  || guest_test_fail "The protected Ubuntu E2E input file was not removed before product execution."

receipt_ready=0
liveness_failures=0
for attempt in $(seq 1 240); do
  # This is the cleanup-critical checkpoint: a receipt or the exact generated
  # package is recorded as soon as it appears, before later visual checks.
  checkpoint_state
  if prlctl exec "$vm_name" /bin/test -s "$guest_receipt" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/test ! -L "$guest_receipt" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/cat "$guest_receipt" >"$host_receipt" 2>/dev/null \
    && node --input-type=module - "$host_receipt" <<'NODE'
import fs from "node:fs";
const receipt = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const required = ["prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
if (!["passed", "failed"].includes(receipt.status) || typeof receipt.appCreated !== "boolean") process.exit(1);
for (const name of required) if (!["passed", "failed", "not-run"].includes(receipt.checks?.[name])) process.exit(1);
NODE
  then
    receipt_ready=1
    checkpoint_state
    break
  fi
  if process_alive "$e2e_pid_file"; then
    liveness_failures=0
  else
    liveness_failures=$((liveness_failures + 1))
    [[ "$liveness_failures" -lt 5 ]] \
      || guest_test_fail "The Ubuntu E2E application exited before writing a valid receipt."
  fi
  kill -0 "$e2e_bridge_pid" 2>/dev/null \
    || guest_test_fail "The Ubuntu E2E application bridge exited unexpectedly."
  if (( attempt % 12 == 0 )); then
    printf '%s e2e-flow-still-running\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  sleep 5
done
[[ "$receipt_ready" == 1 ]] \
  || guest_test_fail "The Ubuntu desktop E2E receipt was not produced within 20 minutes."

stage receipt-validation
node --input-type=module - "$host_receipt" <<'NODE'
import fs from "node:fs";
const receipt = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const required = ["prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
if (receipt.status !== "passed" || receipt.appCreated !== true) throw new Error("The Ubuntu desktop receipt did not pass.");
for (const name of required) if (receipt.checks?.[name] !== "passed") throw new Error(`Ubuntu receipt check did not pass: ${name}`);
NODE

stage remote-app-validation
# Bind the product's app and tenant self-report to one exact platform record.
# Query only the exact app key in the configured tenant; never preserve or
# enumerate the tenant's other apps. Protected values are streamed to a
# user-only input file, parsed entirely in the guest, then removed.
prlctl exec "$vm_name" /bin/test -d "$exact_project" >/dev/null 2>&1 \
  && prlctl exec "$vm_name" /bin/test ! -L "$exact_project" >/dev/null 2>&1 \
  && [[ "$(prlctl exec "$vm_name" /usr/bin/stat -c %u "$exact_project" 2>/dev/null | tr -d '\r\n')" == "$UBUNTU_PRL_UID" ]] \
  || guest_test_fail "The remote-app query cwd is not the exact user-owned generated project."
remote_checkpoint_file="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-remote-app-checkpoint.json"
[[ "$remote_checkpoint_proven" == 1 && -f "$remote_checkpoint_file" && ! -L "$remote_checkpoint_file" ]] \
  || guest_test_fail "The created Ubuntu app was not durably checkpointed before final validation."
remote_resource_id_hash="$(EAI_REMOTE_CHECKPOINT_FILE="$remote_checkpoint_file" \
  EAI_REMOTE_CHECKPOINT_APP="$EAI_VM_PROJECT_NAME" node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const proof = JSON.parse(fs.readFileSync(process.env.EAI_REMOTE_CHECKPOINT_FILE, "utf8"));
const appHash = crypto.createHash("sha256").update(process.env.EAI_REMOTE_CHECKPOINT_APP).digest("hex");
if (proof.schemaVersion !== "eai.ubuntu-remote-app-checkpoint.v1"
    || proof.status !== "verified-created" || proof.appName !== process.env.EAI_REMOTE_CHECKPOINT_APP
    || proof.appKeySha256 !== appHash || !/^[0-9a-f]{64}$/.test(proof.resourceIdSha256 || "")
    || !/^[0-9a-f]{64}$/.test(proof.displayNameSha256 || "")
    || proof.createdDuringThisRun !== true || proof.exactMatchCount !== 1
    || proof.serverMatchCountVerified !== true || proof.projectCwdBound !== true
    || proof.sourceVerified !== true || proof.embeddedChildFieldsEmpty !== true
    || proof.sanitized !== true || proof.diagnostic !== true || proof.productionGate !== false
    || !Number.isFinite(Date.parse(proof.resourceCreatedAt))
    || !Number.isFinite(Date.parse(proof.verifiedAt))) {
  throw new Error("The durable Ubuntu remote-app checkpoint is invalid.");
}
process.stdout.write(proof.resourceIdSha256);
NODE
)" || guest_test_fail "The durable Ubuntu remote-app checkpoint could not be validated."
[[ "$remote_resource_id_hash" =~ ^[0-9a-f]{64}$ ]] \
  || guest_test_fail "The durable Ubuntu remote-app checkpoint lacks a resource binding."
prlctl exec "$vm_name" /bin/rm -f "$remote_proof_input" "$remote_proof_output"
printf '%s\n%s\n%s\n' "$EAI_HARNESS_TENANT_ID" "$EAI_VM_PROJECT_NAME" "$remote_resource_id_hash" \
  | prlctl exec "$vm_name" /usr/bin/install -m 0600 -o "$guest_user" -g "$guest_group" \
      /dev/stdin "$remote_proof_input"
ubuntu_prl_user_shell >/dev/null <<BASH \
  || guest_test_fail "The exact created app could not be verified in the configured Ubuntu tenant."
set -euo pipefail
cleanup_remote_proof() { rm -f '$remote_proof_input' '$remote_proof_output'; }
trap cleanup_remote_proof EXIT
trap 'cleanup_remote_proof; exit 129' HUP
trap 'cleanup_remote_proof; exit 130' INT
trap 'cleanup_remote_proof; exit 143' TERM
exec 3<'$remote_proof_input'
IFS= read -r tenant_id <&3
IFS= read -r app_key <&3
IFS= read -r expected_resource_hash <&3
exec 3<&-
rm -f '$remote_proof_input'
cd -- '$exact_project'
where_json="\$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"verticalKey":sys.argv[1]}))' "\$app_key")"
'$exact_cli' resources list tenant-vertical-enrollment \
  --tenant-id "\$tenant_id" --where "\$where_json" --limit 2 --format json \
  >'$remote_proof_output' 2>/dev/null
/usr/bin/python3 - '$remote_proof_output' "\$app_key" "\$expected_resource_hash" '$exact_project' <<'PY'
import hashlib
import json
import os
import re
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if (not isinstance(payload, dict) or not isinstance(payload.get("resources"), list)
        or not isinstance(payload.get("totalDocs"), int)
        or isinstance(payload.get("totalDocs"), bool)):
    raise SystemExit(1)
documents = payload["resources"]
matches = []
for document in documents:
    if not isinstance(document, dict):
        continue
    data = document.get("data") if isinstance(document.get("data"), dict) else document
    if data.get("verticalKey") == sys.argv[2]:
        matches.append((document, data))
if (len(matches) != 1 or len(documents) != 1 or payload["totalDocs"] != 1
        or matches[0][1].get("source") != "eai-cli"):
    raise SystemExit(1)
record, data = matches[0]
record_id = next((record.get(key) for key in ("id", "_id")
                  if isinstance(record.get(key), str) and record.get(key)), None)
if not record_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}", record_id):
    raise SystemExit(1)
if hashlib.sha256(record_id.encode()).hexdigest() != sys.argv[3]:
    raise SystemExit(1)
def empty_child(value):
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, (list, dict)):
        return len(value) == 0
    return False
for key in ("services", "service", "workflows", "workflow", "setups", "setup"):
    if key in data and not empty_child(data[key]):
        raise SystemExit(1)
if os.path.realpath(os.getcwd()) != sys.argv[4]:
    raise SystemExit(1)
PY
BASH
remote_app_key_hash="$(printf '%s' "$EAI_VM_PROJECT_NAME" | /usr/bin/shasum -a 256 | awk '{print tolower($1)}')"
EAI_UBUNTU_REMOTE_APP_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-remote-app-verification.json" \
EAI_UBUNTU_REMOTE_APP_HASH="$remote_app_key_hash" \
EAI_UBUNTU_REMOTE_RESOURCE_HASH="$remote_resource_id_hash" node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {status: "verified", platform: "ubuntu",
  query: "exact tenant-vertical-enrollment filter", tenantQueryBound: true,
  tenantWideEnumerationPerformed: false, exactAppKeyMatchCount: 1,
  appKeySha256: process.env.EAI_UBUNTU_REMOTE_APP_HASH,
  resourceIdSha256: process.env.EAI_UBUNTU_REMOTE_RESOURCE_HASH,
  durableCreationCheckpointMatched: true, projectCwdBound: true,
  embeddedChildFieldsEmpty: true, appKeyMatched: true,
  sourceMatched: "eai-cli", receiptAppCheck: "passed",
  verifiedAt: new Date().toISOString(), sanitized: true, diagnostic: true, productionGate: false};
fs.writeFileSync(process.env.EAI_UBUNTU_REMOTE_APP_FILE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
stage remote-app-validation-passed

stage exact-project-validation
exact_project="$guest_parent/$EAI_VM_PROJECT_NAME"
exact_package="$exact_project/package.json"
for directory in "$guest_parent" "$exact_project"; do
  if ! {
    prlctl exec "$vm_name" /bin/test -d "$directory" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/test ! -L "$directory" >/dev/null 2>&1
  }; then
    guest_test_fail "The exact generated Ubuntu project path is missing or is a symlink."
  fi
done
for regular_file in \
  "$exact_project/tsconfig.json" \
  "$exact_project/node_modules/typescript/bin/tsc"; do
  if ! {
    prlctl exec "$vm_name" /bin/test -f "$regular_file" >/dev/null 2>&1 \
      && prlctl exec "$vm_name" /bin/test ! -L "$regular_file" >/dev/null 2>&1
  }; then
    guest_test_fail "The exact generated Ubuntu project lacks a regular TypeScript verification file."
  fi
done
if ! {
  prlctl exec "$vm_name" /bin/test -d "$exact_project/src" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/test ! -L "$exact_project/src" >/dev/null 2>&1
}; then
  guest_test_fail "The exact generated Ubuntu project lacks its regular source directory."
fi
if ! {
  prlctl exec "$vm_name" /bin/test -f "$exact_package" >/dev/null 2>&1 \
    && prlctl exec "$vm_name" /bin/test ! -L "$exact_package" >/dev/null 2>&1
}; then
  guest_test_fail "The exact generated Ubuntu package.json is missing or is a symlink."
fi
prlctl exec "$vm_name" /bin/cat "$exact_package" >"$host_package" \
  || guest_test_fail "The exact generated Ubuntu package.json could not be read."
guest_project_hash="$(prlctl exec "$vm_name" /usr/bin/sha256sum "$exact_package" \
  | awk '{print tolower($1)}' | tr -d '\r\n')"
host_project_hash="$(/usr/bin/shasum -a 256 "$host_package" | awk '{print tolower($1)}')"
[[ "$guest_project_hash" == "$host_project_hash" && "$guest_project_hash" =~ ^[0-9a-f]{64}$ ]] \
  || guest_test_fail "The generated Ubuntu package.json changed while proof was collected."
EAI_PROJECT_NAME="$EAI_VM_PROJECT_NAME" EAI_PROJECT_PATH="$exact_project" \
EAI_PROJECT_JSON="$host_package" EAI_PROJECT_HASH="$host_project_hash" \
EAI_PROJECT_RECEIPT="$host_receipt" \
EAI_PROJECT_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-project-verification.json" \
node --input-type=module <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
const bytes = fs.readFileSync(process.env.EAI_PROJECT_JSON);
const pkg = JSON.parse(bytes.toString("utf8"));
const receipt = JSON.parse(fs.readFileSync(process.env.EAI_PROJECT_RECEIPT, "utf8"));
const scripts = Object.keys(pkg.scripts || {});
const dependencies = Object.keys(pkg.dependencies || {});
const devDependencies = Object.keys(pkg.devDependencies || {});
const hash = crypto.createHash("sha256").update(bytes).digest("hex");
if (receipt.checks?.project !== "passed") throw new Error("The receipt did not pass project generation.");
if (receipt.projectPath && receipt.projectPath !== process.env.EAI_PROJECT_PATH) throw new Error("The receipt names another project path.");
if (pkg.name !== `@eai-tools/${process.env.EAI_PROJECT_NAME}`) throw new Error("The generated package names another app.");
if (!scripts.includes("build") || !scripts.includes("typecheck") || !dependencies.length) {
  throw new Error("The generated project lacks its expected build/typecheck scripts or dependencies.");
}
if (hash !== process.env.EAI_PROJECT_HASH) throw new Error("The host and guest package hashes differ.");
const evidence = {status: "structure-verified", platform: "ubuntu", appName: process.env.EAI_PROJECT_NAME,
  projectPath: process.env.EAI_PROJECT_PATH, packageJsonRegularFile: true, packageJsonSymlink: false,
  packageName: pkg.name, packageNameMatched: true, packageJsonSha256: hash,
  guestAndHostPackageHashesMatched: true, scriptCount: scripts.length,
  dependencyCount: dependencies.length, devDependencyCount: devDependencies.length,
  receiptProjectCheck: "passed", structuralVerifiedAt: new Date().toISOString(),
  sanitized: true, diagnostic: true, productionGate: false};
fs.writeFileSync(process.env.EAI_PROJECT_EVIDENCE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
if ! ubuntu_prl_user_shell >"$project_typecheck_log" 2>&1 <<BASH
set -euo pipefail
cd '$exact_project'
exec /usr/bin/node '$exact_project/node_modules/typescript/bin/tsc' \
  --noEmit --pretty false --project '$exact_project/tsconfig.json'
BASH
then
  sanitize_log "$project_typecheck_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-project-typecheck.log"
  guest_test_fail "The exact generated Ubuntu project failed a no-emit TypeScript compile."
fi
sanitize_log "$project_typecheck_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-project-typecheck.log"
EAI_PROJECT_EVIDENCE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-project-verification.json" \
node --input-type=module <<'NODE'
import fs from "node:fs";
const path = process.env.EAI_PROJECT_EVIDENCE;
const evidence = JSON.parse(fs.readFileSync(path, "utf8"));
evidence.status = "verified";
evidence.sourceDirectoryVerified = true;
evidence.tsconfigRegularFileVerified = true;
evidence.localTypeScriptCompilerVerified = true;
evidence.noEmitTypecheckPassed = true;
evidence.verifiedAt = new Date().toISOString();
fs.writeFileSync(path, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
export EAI_VM_PROJECT_VERIFIED=1

stage ai-handoff-process-validation
ai_pid=""
ai_exact_project_argument=""
for _ in $(seq 1 40); do
  ai_binding="$(prlctl exec "$vm_name" /bin/bash -c '
    uid=$1; project=$2
    for process in /proc/[0-9]*; do
      pid=${process##*/}
      [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || continue
      [ "$(readlink -f "$process/exe" 2>/dev/null)" = /usr/share/code/code ] || continue
      [ "$(readlink -f "$process/cwd" 2>/dev/null)" = "$project" ] || continue
      arguments_inspected=0
      exact_project_argument=0
      while IFS= read -r -d "" argument; do
        arguments_inspected=1
        [ "$argument" = "$project" ] && exact_project_argument=1
      done < "$process/cmdline"
      [ "$arguments_inspected" = 1 ] || continue
      printf "%s\t%s\n" "$pid" "$exact_project_argument"
      exit 0
    done
    exit 1
  ' _ "$UBUNTU_PRL_UID" "$exact_project" 2>/dev/null | tr -d '\r' || true)"
  IFS=$'\t' read -r ai_pid ai_exact_project_argument <<<"$ai_binding"
  [[ "$ai_pid" =~ ^[1-9][0-9]*$ \
    && ( "$ai_exact_project_argument" == 0 || "$ai_exact_project_argument" == 1 ) ]] && break
  sleep 1
done
[[ "$ai_pid" =~ ^[1-9][0-9]*$ \
  && ( "$ai_exact_project_argument" == 0 || "$ai_exact_project_argument" == 1 ) ]] \
  || guest_test_fail "The handoff receipt passed, but no user-owned VS Code process had the exact project cwd and inspectable arguments."

# Remove the completed authentication browser from the framebuffer. Do not
# open the project again: the process and visual evidence must come from the
# product's own AI handoff.
stop_profile_bound_firefox \
  || guest_test_fail "The exact profile-bound Firefox/Firefox-bin processes could not be closed before handoff evidence."
prlctl exec "$vm_name" /bin/bash -c '
  uid=$1; pid=$2; project=$3
  [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ]
  [ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" = /usr/share/code/code ]
  [ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" = "$project" ]
  [ -r "/proc/$pid/cmdline" ]
  kill -0 "$pid"
' _ "$UBUNTU_PRL_UID" "$ai_pid" "$exact_project" >/dev/null 2>&1 \
  || guest_test_fail "The product-opened VS Code process lost its owner, executable, cwd, or argument proof before evidence capture."

sleep 3
handoff_candidate="$work_dir/ubuntu-ai-handoff.png"
handoff_destination="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-ai-handoff.png"
prlctl capture "$vm_name" --file "$handoff_candidate" >/dev/null 2>&1 \
  || guest_test_fail "The Ubuntu AI handoff screenshot could not be captured."
EAI_OCR_PATTERN="$EAI_VM_PROJECT_NAME" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
  "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1 \
  || guest_test_fail "The Ubuntu handoff screenshot does not show the exact generated project."
EAI_OCR_PATTERN='Build with Agent' EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
  "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1 \
  || guest_test_fail "The Ubuntu handoff screenshot does not show the AI chat surface."
for protected_pattern in \
  "$EAI_HARNESS_USER_EMAIL" "$EAI_HARNESS_TENANT_ID" "$EAI_HARNESS_TENANT_NAME" \
  localhost '?code=' 'code=' 'code =' access_token refresh_token client_info session_state \
  'Authentication complete' 'successfully authenticated'; do
  if EAI_OCR_PATTERN="$protected_pattern" EAI_OCR_INCLUDE_BROWSER_CHROME=1 \
    "$ocr_binary" "$handoff_candidate" >/dev/null 2>&1; then
    guest_test_fail "The Ubuntu handoff screenshot contains protected or callback data."
  fi
done
/bin/cp "$handoff_candidate" "$handoff_destination"
handoff_hash="$(/usr/bin/shasum -a 256 "$handoff_destination" | awk '{print tolower($1)}')"
EAI_HANDOFF_FILE="$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-ai-handoff-evidence.json" \
EAI_HANDOFF_HASH="$handoff_hash" EAI_HANDOFF_APP="$EAI_VM_PROJECT_NAME" \
EAI_HANDOFF_PROJECT="$exact_project" EAI_HANDOFF_PID="$ai_pid" EAI_HANDOFF_USER="$guest_user" \
EAI_HANDOFF_EXACT_PROJECT_ARGUMENT="$ai_exact_project_argument" \
node --input-type=module <<'NODE'
import fs from "node:fs";
const evidence = {platform: "ubuntu", appName: process.env.EAI_HANDOFF_APP,
  projectPath: process.env.EAI_HANDOFF_PROJECT, surfaceId: "vscode-copilot",
  handoffReceiptPassed: true, processVerified: true, processOwner: process.env.EAI_HANDOFF_USER,
  processId: Number(process.env.EAI_HANDOFF_PID),
  processMatch: "/usr/share/code/code with exact project cwd and inspected argv",
  processExecutableVerified: true, processCwdVerified: true, processArgumentsInspected: true,
  exactProjectArgumentPresent: process.env.EAI_HANDOFF_EXACT_PROJECT_ARGUMENT === "1",
  bindingSource: "exact-process-cwd",
  screenshot: {path: "ubuntu-ai-handoff.png", sha256: process.env.EAI_HANDOFF_HASH,
    showsExactProject: true, showsChatSurface: true, showsProviderAuthenticated: false,
    automatedProtectedContentCheckPassed: true},
  verifiedAt: new Date().toISOString(), sanitized: true, diagnostic: true, productionGate: false};
fs.writeFileSync(process.env.EAI_HANDOFF_FILE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
export EAI_VM_AI_HANDOFF_PROCESS_VERIFIED=1
export EAI_VM_AI_HANDOFF_SCREENSHOT_VERIFIED=1

stage browser-auth-state-cleanup
ubuntu_disposable_browser_cleanup "$browser_profile" "$browser_pid_file" \
  || guest_test_fail "The disposable Ubuntu browser profile could not be removed."
ubuntu_prl_user_exec /bin/test ! -e "$browser_profile" >/dev/null 2>&1 \
  || guest_test_fail "The disposable Ubuntu browser profile persisted after authentication."
stage browser-auth-state-cleanup-passed

stage final-integrity-validation
final_guest_hash="$(ubuntu_prl_user_exec /usr/bin/sha256sum "$guest_deb" \
  | awk '{print tolower($1)}' | tr -d '\r\n')"
[[ "$final_guest_hash" == "$host_hash" ]] \
  || guest_test_fail "The exact Ubuntu release asset changed after native installation."
final_executable_hash="$(prlctl exec "$vm_name" /usr/bin/sha256sum "$guest_executable" \
  | awk '{print tolower($1)}' | tr -d '\r\n')"
[[ "$final_executable_hash" == "$executable_hash" ]] \
  || guest_test_fail "The installed Ubuntu executable changed during the E2E flow."
prlctl exec "$vm_name" /bin/cat "$guest_native_log" >"$native_install_log" 2>/dev/null \
  || guest_test_fail "The protected Ubuntu native-install log could not be collected."
sanitize_log "$native_install_log" "$(dirname "$EAI_VM_RESULT_FILE")/ubuntu-native-install.log"

versions="$(node --input-type=module - "$after_git" "$after_node" "$after_npm" "$after_eai" <<'NODE'
const [git, nodeVersion, npm, eai] = process.argv.slice(2);
process.stdout.write(JSON.stringify({git, node: nodeVersion, npm, eai}));
NODE
)"
export EAI_VM_INSTALLER_VERIFIED=1
export EAI_VM_PREREQUISITES_PROVEN=1
export EAI_VM_EXECUTABLE_SHA256="$executable_hash"
export EAI_VM_PREREQUISITES_BEFORE="$before_versions"
guest_test_finalize ubuntu "$exact_project" "$host_receipt" "$host_hash" "$final_guest_hash" "$versions"
completed=1
stage ubuntu-e2e-passed
