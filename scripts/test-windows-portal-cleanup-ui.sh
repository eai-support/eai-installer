#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "$ROOT/artifacts/release-e2e/.windows-portal-ui-test.XXXXXX")"
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'Windows portal cleanup UI test failed: %s\n' "$*" >&2
  exit 1
}

fake_login="$fake_bin/login"
cat >"$fake_login" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 0 ]] || exit 2
printf 'login\n' >>"$EAI_FAKE_LOGIN_LOG"
EOF
chmod +x "$fake_login"

fake_input="$fake_bin/input"
cat >"$fake_input" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload=""
if [[ "${*: -2}" == "type --stdin" ]]; then payload="$(cat)"; fi
printf '%s|%s\n' "$*" "$payload" >>"$EAI_FAKE_INPUT_LOG"
if [[ "$payload" == *'windows-interactive-exact-delete.ps1'* ]]; then
  printf '%s\n' "$payload" >>"$EAI_FAKE_INTERACTIVE_LAUNCH_LOG"
fi
EOF
chmod +x "$fake_input"

fake_prlctl="$fake_bin/prlctl"
cat >"$fake_prlctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    printf 'running\n'
    ;;
  exec)
    payload="$(cat)"
    if [[ "$payload" == *"eai.windows-interactive-delete-worker.v1"* ]]; then
      operation="$(printf '%s\n' "$payload" | sed -n 's/^\$operation = "\([^"]*\)"/\1/p' | head -1)"
      run="$(printf '%s\n' "$payload" | sed -n 's/^\$runId = "\([^"]*\)"/\1/p' | head -1)"
      ui_hash="$(printf '%s\n' "$payload" | sed -n 's/^\$expectedUiSha256 = "\([a-f0-9]*\)"/\1/p' | head -1)"
      runner_hash="$(printf '%s\n' "$payload" | sed -n 's/^\$expectedRunnerSha256 = "\([a-f0-9]*\)"/\1/p' | head -1)"
      printf '%s\n' "$operation" >>"$EAI_FAKE_WORKER_LOG"
      node - "$operation" "$run" "$ui_hash" "$runner_hash" <<'NODE'
const [operation, runId, uiHelperSha256, runnerSha256] = process.argv.slice(2);
console.log(JSON.stringify({
  schemaVersion: "eai.windows-interactive-delete-worker.v1",
  operation,
  runId,
  uiHelperSha256,
  runnerSha256,
  exactCurrentUser: true,
  realRunDirectory: true,
  verified: true,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
}));
NODE
      exit 0
    fi
    if [[ "$payload" == *"EAI_INTERACTIVE_DELETE_RESULT_PENDING"* ]]; then
      run="$(printf '%s\n' "$payload" | sed -n 's/^\$runId = "\([^"]*\)"/\1/p' | head -1)"
      invocation_id="$(printf '%s\n' "$payload" | sed -n 's/^\$invocationId = "\([a-f0-9]*\)"/\1/p' | head -1)"
      app="test-windows-$run"
      node - "$app" "$invocation_id" "$EAI_FAKE_UI_HASH" "$EAI_FAKE_RUNNER_HASH" "${EAI_FAKE_INTERACTIVE_OUTCOME:-closed}" <<'NODE'
const [appName, invocationId, uiHelperSha256, runnerSha256, outcome] = process.argv.slice(2);
const displayName = "Exact Windows Test App";
const dialogClosed = outcome === "closed";
console.log(JSON.stringify({
  schemaVersion: "eai.windows-interactive-exact-delete.v1",
  invocationId,
  uiHelperSha256,
  runnerSha256,
  appName,
  displayName,
  exactDialogVerified: true,
  exactTypedValueVerified: true,
  exactDialogRevalidatedImmediatelyBeforeInvoke: true,
  exactButtonFocused: true,
  scopedInvokePatternInvoked: true,
  exactExpectedUser: true,
  interactiveSessionId: 1,
  interactiveSessionProven: true,
  explorerSessionMatched: true,
  explorerOwnerSidMatched: true,
  edgeUiBoundToInteractiveSession: true,
  edgeOwnerSidMatched: true,
  browserWindowHandle: 101,
  browserProcessId: 202,
  browserProcessSessionId: 1,
  topLevelWindowRuntimeIdSha256: "b".repeat(64),
  dialogFinalRuntimeIdSha256: "c".repeat(64),
  sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke: true,
  exactBrowserWindowForegroundAtInvoke: true,
  mutationState: "invoked-unverified",
  invokedAt: new Date().toISOString(),
  confirmationDialogClosed: dialogClosed,
  dialogAbsentConsecutiveChecks: dialogClosed ? 12 : 0,
  dialogClosureStableMilliseconds: dialogClosed ? 3000 : 0,
  absenceVerificationRequired: true,
  retryMutationAutomatically: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}));
NODE
      exit 0
    fi
    action="$(printf '%s' "$payload" | sed -n "s/.*Invoke-WindowsUiAction -Action '\([^']*\)'.*/\1/p" | tail -1)"
    if [[ -n "$action" ]]; then
      printf '%s\n' "$action" >>"$EAI_FAKE_UI_LOG"
      if [[ "$action" == "${EAI_FAKE_TRANSIENT_ACTION:-}" ]]; then
        transient_count=0
        if [[ -f "${EAI_FAKE_TRANSIENT_COUNT_FILE:-}" ]]; then
          transient_count="$(cat "$EAI_FAKE_TRANSIENT_COUNT_FILE")"
        fi
        transient_count=$((transient_count + 1))
        printf '%s\n' "$transient_count" >"$EAI_FAKE_TRANSIENT_COUNT_FILE"
        if [[ "$transient_count" == 1 ]]; then
          printf '%s\n' 'PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.' >&2
          exit 255
        fi
      fi
      if [[ "$action" == probe-manage-app-search ]]; then
        if [[ "${EAI_FAKE_MANAGE_SEARCH_ABSENT:-0}" == 1 ]]; then
          printf 'EAI_MANAGE_APP_SEARCH_ABSENT\n'
        else
          printf 'EAI_MANAGE_APP_SEARCH_PRESENT\n'
        fi
      fi
      printf 'WINDOWS_UI_ACTION_OK\n'
      exit 0
    fi
    decoded="$(printf '%s' "$payload" | node -e '
      let source = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { source += chunk; });
      process.stdin.on("end", () => {
        const match = source.match(/-CleanupInputBase64 @\("([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "", "([A-Za-z0-9+/=]*)"\)/);
        if (!match) process.exit(2);
        process.stdout.write(match.slice(1).map((value) => Buffer.from(value, "base64").toString("utf8")).join("\n"));
      });
    ')"
    app="$(printf '%s\n' "$decoded" | sed -n '2p')"
    run="$(printf '%s\n' "$decoded" | sed -n '4p')"
    if [[ "${EAI_FAKE_TARGET_QUERY_FAILURE:-0}" == 1 ]]; then
      printf 'simulated read-only target query failure\n' >&2
      exit 42
    fi
    node - "$run" "$app" "${EAI_FAKE_CHILD_COUNT:-0}" "${EAI_FAKE_RESOURCE_HASH:-}" "${EAI_FAKE_RESOURCE_CREATED_AT:-}" "${EAI_FAKE_DISPLAY_NAME:-}" "${EAI_FAKE_CHILD_QUERY_INCOMPLETE:-0}" <<'NODE'
const [runId, appName, childRaw, resourceHashOverride, resourceCreatedAtOverride, displayNameOverride, incompleteRaw] = process.argv.slice(2);
const child = Number(childRaw);
const complete = incompleteRaw !== "1";
console.log(JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup.v1",
  action: "portal-target-only",
  runId,
  platform: "windows",
  appName,
  displayName: displayNameOverride || "Exact Windows Test App",
  resourceCreatedAt: resourceCreatedAtOverride || new Date(Number(runId.slice(0, 13)) + 1000).toISOString(),
  resourceIdSha256: resourceHashOverride || "a".repeat(64),
  preDeleteValidation: {
    enrollmentExactMatches: 1,
    createdDuringThisRun: true,
    sourceVerified: true,
    authoritativeChildQueriesComplete: complete,
    childQueries: {
      queriesComplete: complete,
      serviceActivations: { objectType: "vertical-service-activation", filterField: "data.verticalKey", comparison: "case-sensitive-exact", filterValueAppKeyBound: true, querySucceeded: complete, completeBoundedPage: complete, totalDocs: child, exactVerticalKeyMatches: child },
      productConfigs: { objectType: "vertical-product-config", filterField: "data.verticalKey", comparison: "case-sensitive-exact", filterValueAppKeyBound: true, querySucceeded: true, completeBoundedPage: true, totalDocs: 0, exactVerticalKeyMatches: 0 },
    },
    servicesBeforeDeletion: child,
    verticalProductConfigsBeforeDeletion: 0,
    workflowExactMatchesBeforeDeletion: 0,
    setupExactMatchesBeforeDeletion: 0,
  },
  mutationAttempted: false,
  deleted: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}));
NODE
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake_prlctl"

make_run() {
  local run_id="$1"
  local run_dir="$test_root/$run_id"
  local app="test-windows-$run_id"
  mkdir -p "$run_dir/windows"
  node - "$run_dir" "$run_id" "$app" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [runDir, runId, appName] = process.argv.slice(2);
fs.writeFileSync(path.join(runDir, "release-e2e.json"), JSON.stringify({
  runId,
  status: "failed",
  machines: [{ vm: "windows", status: "failed", appName, appCreated: true, cleanupVerified: false }],
}, null, 2));
fs.writeFileSync(path.join(runDir, "windows", "app-state.json"), JSON.stringify({
  appName,
  appCreated: true,
  cleanupRequired: true,
  cleanupRequested: true,
}, null, 2));
fs.writeFileSync(path.join(runDir, "windows", "vm-result.json"), JSON.stringify({
  status: "failed",
  vm: "windows",
  appName,
  appCreated: true,
  cleanupRequested: true,
  checks: { app: "passed" },
}, null, 2));
NODE
  printf '%s\n' "$run_dir"
}

run_helper() {
  EAI_WINDOWS_PORTAL_PRLCTL_BIN="$fake_prlctl" \
  EAI_WINDOWS_PORTAL_LOGIN_COMMAND="$fake_login" \
  EAI_WINDOWS_PORTAL_INPUT_COMMAND="$fake_input" \
  EAI_FAKE_LOGIN_LOG="$test_root/login.log" \
  EAI_FAKE_INPUT_LOG="$test_root/input.log" \
  EAI_FAKE_INTERACTIVE_LAUNCH_LOG="$test_root/interactive-launch.log" \
  EAI_FAKE_WORKER_LOG="$test_root/worker.log" \
  EAI_FAKE_UI_LOG="$test_root/ui.log" \
  EAI_FAKE_UI_HASH="$(shasum -a 256 "$ROOT/scripts/windows-ui-action.ps1" | awk '{print $1}')" \
  EAI_FAKE_RUNNER_HASH="$(shasum -a 256 "$ROOT/scripts/windows-interactive-exact-delete.ps1" | awk '{print $1}')" \
  EAI_HARNESS_USER_EMAIL="test-user@example.invalid" \
  EAI_HARNESS_TENANT_ID="${EAI_TEST_TENANT_ID:-00000000-0000-4000-8000-000000000000}" \
  EAI_HARNESS_TENANT_NAME="Protected Test Tenant" \
    "$ROOT/scripts/run-windows-portal-cleanup-ui.sh" "$@"
}

make_attempt2_eligible_run() {
  local run_id="$1"
  local run_dir=""
  run_dir="$(make_run "$run_id")"
  run_helper --run-dir "$run_dir" --prepare-delete >/dev/null
  node - "$run_dir" "$run_id" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [runDir, runId] = process.argv.slice(2);
const windows = path.join(runDir, "windows");
const appName = `test-windows-${runId}`;
const invocationPath = path.join(windows, "windows-portal-delete-invocation.json");
const verificationPath = path.join(windows, "windows-cleanup-verification-only.json");
const tenantIdSha256 = require("node:crypto").createHash("sha256").update("00000000-0000-4000-8000-000000000000").digest("hex");
const preparedPath = path.join(windows, "windows-portal-delete-prepared.json");
const prepared = JSON.parse(fs.readFileSync(preparedPath, "utf8"));
const now = Date.now();
prepared.preparedAt = new Date(now - 180_000).toISOString();
prepared.expiresAt = new Date(now + 1_620_000).toISOString();
fs.writeFileSync(preparedPath, `${JSON.stringify(prepared, null, 2)}\n`);
const invokedAt = new Date(now - 120_000).toISOString();
fs.writeFileSync(invocationPath, `${JSON.stringify({
  schemaVersion: "eai.windows-portal-delete-invocation.v1",
  runId,
  platform: "windows",
  appName,
  tenantIdSha256,
  action: "invoke-delete-permanently",
  mutationState: "invoked-unverified",
  transportExitCode: 0,
  sanitizedOutputSha256: "b".repeat(64),
  retryMutationAutomatically: false,
  deletionVerified: false,
  absenceVerificationRequired: true,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: invokedAt,
}, null, 2)}\n`);
const verifiedAt = new Date(now - 30_000).toISOString();
fs.writeFileSync(verificationPath, `${JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup.v1",
  action: "verify-only",
  runId,
  platform: "windows",
  appName,
  absence: {
    resourceApiExactMatchesAfter: 1,
    cliExactMatchesAfter: 1,
    resourceApiQuerySucceeded: true,
    cliAppListSucceeded: true,
    verified: false,
    verifiedAt,
  },
  deleted: false,
  portalVerificationRequired: true,
  cleanupVerified: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: verifiedAt,
}, null, 2)}\n`);
fs.utimesSync(invocationPath, new Date(now - 120_000), new Date(now - 120_000));
fs.utimesSync(verificationPath, new Date(now - 30_000), new Date(now - 30_000));
NODE
  printf '%s\n' "$run_dir"
}

make_attempt2_legacy_eligible_run() {
  local run_id="$1"
  local run_dir=""
  run_dir="$(make_attempt2_eligible_run "$run_id")"
  node - "$run_dir" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const runDir = process.argv[2];
const windows = path.join(runDir, "windows");
const targetPath = path.join(windows, "windows-portal-cleanup-target.json");
const preparedPath = path.join(windows, "windows-portal-delete-prepared.json");
const invocationPath = path.join(windows, "windows-portal-delete-invocation.json");
const target = JSON.parse(fs.readFileSync(targetPath, "utf8"));
target.preDeleteValidation = {
  enrollmentExactMatches: 1,
  createdDuringThisRun: true,
  sourceVerified: true,
  embeddedChildFieldsEmpty: true,
  servicesBeforeDeletion: 0,
  workflowExactMatchesBeforeDeletion: 0,
  setupExactMatchesBeforeDeletion: 0,
};
delete target.tenantIdSha256;
fs.writeFileSync(targetPath, `${JSON.stringify(target, null, 2)}\n`);
const prepared = JSON.parse(fs.readFileSync(preparedPath, "utf8"));
prepared.targetReceiptSha256 = crypto.createHash("sha256").update(fs.readFileSync(targetPath)).digest("hex");
delete prepared.tenantIdSha256;
delete prepared.interactiveWorker;
fs.writeFileSync(preparedPath, `${JSON.stringify(prepared, null, 2)}\n`);
const invocationStat = fs.statSync(invocationPath);
const invocation = JSON.parse(fs.readFileSync(invocationPath, "utf8"));
delete invocation.tenantIdSha256;
fs.writeFileSync(invocationPath, `${JSON.stringify(invocation, null, 2)}\n`);
fs.utimesSync(invocationPath, invocationStat.atime, invocationStat.mtime);
NODE
  printf '%s\n' "$run_dir"
}

run_dir="$(make_run 1788317000101-abc101)"
run_helper --run-dir "$run_dir" --prepare-delete >"$test_root/prepare.stdout"
jq -e '.schemaVersion == "eai.windows-portal-cleanup-target.v1" and .appName == "test-windows-1788317000101-abc101" and .preDeleteValidation.servicesBeforeDeletion == 0 and .mutationAttempted == false' \
  "$run_dir/windows/windows-portal-cleanup-target.json" >/dev/null \
  || fail "The exact read-only target receipt is invalid."
jq -e '.schemaVersion == "eai.windows-portal-delete-prepared.v1" and .exactOrigin == "admin-portal.myenterprise.ai" and .exactPath == "/platform/apps" and .typedConfirmationVerified == true and .interactiveWorker.stagedAndVerified == true and (.interactiveWorker.uiHelperSha256 | test("^[a-f0-9]{64}$")) and (.interactiveWorker.runnerSha256 | test("^[a-f0-9]{64}$")) and .deletePermanentlyInvoked == false' \
  "$run_dir/windows/windows-portal-delete-prepared.json" >/dev/null \
  || fail "The prepared delete receipt is invalid."
expected_actions=$'wait-platform-apps\ninvoke-create-app-split-arrow\ninvoke-manage-app\nprobe-manage-app-search\nfocus-manage-app-search\ninvoke-exact-app-delete\nfocus-delete-confirmation\nassert-delete-ready'
[[ "$(cat "$test_root/ui.log")" == "$expected_actions" ]] \
  || fail "The prepare phase did not use the exact structural UI action sequence."
if grep -Fqx 'invoke-delete-permanently' "$test_root/ui.log"; then
  fail "The prepare phase invoked the permanent deletion action."
fi
grep -Fq 'type --stdin|https://admin-portal.myenterprise.ai/platform/apps' "$test_root/input.log" \
  || fail "The prepare phase did not type the fixed approved apps URL."
grep -Fq 'type --stdin|test-windows-1788317000101-abc101' "$test_root/input.log" \
  || fail "The prepare phase did not type the exact receipt-bound app key."

run_helper --run-dir "$run_dir" --invoke-delete-permanently >"$test_root/invoke.stdout"
if grep -Fqx 'invoke-delete-permanently' "$test_root/ui.log"; then
  fail "The final permanent delete action used the Parallels service-desktop UI helper."
fi
[[ "$(grep -Fc 'windows-interactive-exact-delete.ps1' "$test_root/interactive-launch.log")" == 1 ]] \
  || fail "The interactive guest-desktop deletion worker was not launched exactly once."
[[ "$(grep -Fc 'combo command+r|' "$test_root/input.log")" == 1 ]] \
  || fail "The Windows Run dialog was not opened exactly once for the final action."
[[ "$(grep -Fxc 'stage' "$test_root/worker.log")" == 1 \
  && "$(grep -Fxc 'verify' "$test_root/worker.log")" == 1 ]] \
  || fail "The interactive guest-desktop deletion worker was not staged and reverified exactly once."
jq -e '.schemaVersion == "eai.windows-portal-delete-invocation.v1" and .mutationState == "invoked-unverified" and .interactiveDesktopLaunchAttempted == true and .interactiveResultObserved == true and .interactiveResultValidated == true and .exactExpectedUser == true and .interactiveSessionId == 1 and .interactiveSessionProven == true and .explorerSessionMatched == true and .edgeUiBoundToInteractiveSession == true and .confirmationDialogClosed == true and .dialogAbsentConsecutiveChecks >= 12 and .dialogClosureStableMilliseconds >= 3000 and .retryMutationAutomatically == false and .deletionVerified == false' \
  "$run_dir/windows/windows-portal-delete-invocation.json" >/dev/null \
  || fail "The permanent-delete invocation receipt is invalid."
set +e
run_helper --run-dir "$run_dir" --invoke-delete-permanently >/dev/null 2>&1
repeat_status=$?
set -e
[[ "$repeat_status" != 0 && "$(grep -Fc 'windows-interactive-exact-delete.ps1' "$test_root/interactive-launch.log")" == 1 ]] \
  || fail "A recorded permanent-delete invocation was replayed."
[[ "$(grep -Fc 'combo command+r|' "$test_root/input.log")" == 1 ]] \
  || fail "A recorded permanent-delete invocation reopened the Windows Run dialog."

mismatch_dir="$(make_run 1788317000102-abc102)"
node - "$mismatch_dir/windows/app-state.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.appName = "test-windows-1788317000102-wrong0";
fs.writeFileSync(file, JSON.stringify(value, null, 2));
NODE
login_count_before="$(wc -l <"$test_root/login.log" | tr -d ' ')"
set +e
run_helper --run-dir "$mismatch_dir" --prepare-delete >/dev/null 2>&1
mismatch_status=$?
set -e
[[ "$mismatch_status" != 0 && "$(wc -l <"$test_root/login.log" | tr -d ' ')" == "$login_count_before" ]] \
  || fail "Mismatched failed-run receipts were not rejected before guest access."

child_dir="$(make_run 1788317000103-abc103)"
set +e
EAI_FAKE_CHILD_COUNT=1 run_helper --run-dir "$child_dir" --prepare-delete >/dev/null 2>&1
child_status=$?
set -e
[[ "$child_status" != 0 && ! -e "$child_dir/windows/windows-portal-cleanup-target.json" ]] \
  || fail "A nonzero exact child count emitted a portal cleanup target receipt."

uncertain_dir="$(make_run 1788317000104-abc104)"
run_helper --run-dir "$uncertain_dir" --prepare-delete >/dev/null
set +e
EAI_FAKE_INTERACTIVE_OUTCOME=dialog-open run_helper --run-dir "$uncertain_dir" --invoke-delete-permanently >/dev/null 2>&1
uncertain_status=$?
set -e
[[ "$uncertain_status" != 0 ]] || fail "An invocation with the exact delete dialog still open was reported as successful."
[[ "$(grep -Fc 'windows-interactive-exact-delete.ps1' "$test_root/interactive-launch.log")" == 2 ]] \
  || fail "The uncertain interactive deletion launch was retried."
[[ "$(grep -Fc 'combo command+r|' "$test_root/input.log")" == 2 ]] \
  || fail "The still-open-dialog case did not use exactly one new interactive launch."
jq -e '.mutationState == "uncertain" and .interactiveResultObserved == true and .interactiveResultValidated == false and .confirmationDialogClosed == false and .dialogAbsentConsecutiveChecks == 0 and .retryMutationAutomatically == false and .deletionVerified == false' \
  "$uncertain_dir/windows/windows-portal-delete-invocation.json" >/dev/null \
  || fail "The still-open-dialog invocation receipt is invalid."
set +e
run_helper --run-dir "$uncertain_dir" --invoke-delete-permanently >/dev/null 2>&1
dialog_open_repeat_status=$?
set -e
[[ "$dialog_open_repeat_status" != 0 \
  && "$(grep -Fc 'windows-interactive-exact-delete.ps1' "$test_root/interactive-launch.log")" == 2 ]] \
  || fail "A still-open-dialog invocation was replayed."
[[ "$(grep -Fc 'combo command+r|' "$test_root/input.log")" == 2 ]] \
  || fail "A still-open-dialog invocation reopened the Windows Run dialog."

readonly_retry_dir="$(make_run 1788317000105-abc105)"
readonly_retry_count="$test_root/readonly-retry.count"
readonly_ui_start="$(wc -l <"$test_root/ui.log" | tr -d ' ')"
readonly_input_start="$(wc -l <"$test_root/input.log" | tr -d ' ')"
EAI_FAKE_TRANSIENT_ACTION=wait-platform-apps \
EAI_FAKE_TRANSIENT_COUNT_FILE="$readonly_retry_count" \
  run_helper --run-dir "$readonly_retry_dir" --prepare-delete >/dev/null
readonly_ui_log="$test_root/readonly-ui.log"
readonly_input_log="$test_root/readonly-input.log"
tail -n "+$((readonly_ui_start + 1))" "$test_root/ui.log" >"$readonly_ui_log"
tail -n "+$((readonly_input_start + 1))" "$test_root/input.log" >"$readonly_input_log"
[[ "$(grep -Fc 'wait-platform-apps' "$readonly_ui_log")" == 2 ]] \
  || fail "The exact read-only portal state probe did not retry once."
for one_shot_action in invoke-create-app-split-arrow invoke-manage-app probe-manage-app-search focus-manage-app-search invoke-exact-app-delete focus-delete-confirmation assert-delete-ready; do
  [[ "$(grep -Fxc "$one_shot_action" "$readonly_ui_log")" == 1 ]] \
    || fail "A non-transient portal action was not invoked exactly once after a read retry."
done
[[ "$(grep -Fc "type --stdin|https://admin-portal.myenterprise.ai/platform/apps" "$readonly_input_log")" == 1 ]] \
  || fail "The fixed portal URL was typed more than once during a read retry."
[[ "$(grep -Fc "type --stdin|test-windows-1788317000105-abc105" "$readonly_input_log")" == 1 ]] \
  || fail "The exact app key was typed more than once during a read retry."

one_shot_dir="$(make_run 1788317000106-abc106)"
one_shot_count="$test_root/one-shot.count"
one_shot_ui_start="$(wc -l <"$test_root/ui.log" | tr -d ' ')"
set +e
EAI_FAKE_TRANSIENT_ACTION=invoke-create-app-split-arrow \
EAI_FAKE_TRANSIENT_COUNT_FILE="$one_shot_count" \
  run_helper --run-dir "$one_shot_dir" --prepare-delete >/dev/null 2>&1
one_shot_status=$?
set -e
one_shot_ui_log="$test_root/one-shot-ui.log"
tail -n "+$((one_shot_ui_start + 1))" "$test_root/ui.log" >"$one_shot_ui_log"
[[ "$one_shot_status" != 0 ]] || fail "An ambiguous portal transition was replayed to success."
[[ "$(grep -Fxc 'invoke-create-app-split-arrow' "$one_shot_ui_log")" == 1 ]] \
  || fail "An ambiguous portal transition was not kept one-shot."
[[ ! -e "$one_shot_dir/windows/windows-portal-delete-prepared.json" ]] \
  || fail "An ambiguous one-shot portal transition emitted a prepared-delete receipt."

no_search_dir="$(make_run 1788317000107-abc107)"
no_search_ui_start="$(wc -l <"$test_root/ui.log" | tr -d ' ')"
no_search_input_start="$(wc -l <"$test_root/input.log" | tr -d ' ')"
EAI_FAKE_MANAGE_SEARCH_ABSENT=1 \
  run_helper --run-dir "$no_search_dir" --prepare-delete >/dev/null
no_search_ui_log="$test_root/no-search-ui.log"
no_search_input_log="$test_root/no-search-input.log"
tail -n "+$((no_search_ui_start + 1))" "$test_root/ui.log" >"$no_search_ui_log"
tail -n "+$((no_search_input_start + 1))" "$test_root/input.log" >"$no_search_input_log"
[[ "$(grep -Fxc 'probe-manage-app-search' "$no_search_ui_log")" == 1 ]] \
  || fail "The search-free Manage app layout was not independently proven."
if grep -Fqx 'focus-manage-app-search' "$no_search_ui_log"; then
  fail "The search-free Manage app layout attempted to focus a missing field."
fi
if grep -Fq 'type --stdin|Exact Windows Test App' "$no_search_input_log"; then
  fail "The search-free Manage app layout typed into an unproven field."
fi
grep -Fqx 'invoke-exact-app-delete' "$no_search_ui_log" \
  || fail "The search-free Manage app layout did not continue to exact-row binding."
jq -e '.typedConfirmationVerified == true and .deletePermanentlyInvoked == false' \
  "$no_search_dir/windows/windows-portal-delete-prepared.json" >/dev/null \
  || fail "The search-free Manage app layout did not produce a safe prepared receipt."

attempt2_dir="$(make_attempt2_eligible_run 1788317000108-abc108)"
attempt2_launch_before="$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')"
attempt2_login_before="$(wc -l <"$test_root/login.log" | tr -d ' ')"
run_helper --run-dir "$attempt2_dir" --prepare-delete-attempt-2 >"$test_root/attempt2-prepare.stdout"
attempt2_nonce="$(tail -n 1 "$test_root/attempt2-prepare.stdout")"
[[ "$attempt2_nonce" =~ ^[a-f0-9]{64}$ ]] || fail "Attempt 2 did not emit one exact confirmation nonce."
[[ "$(wc -l <"$test_root/login.log" | tr -d ' ')" == "$((attempt2_login_before + 1))" ]] \
  || fail "Attempt 2 did not perform exactly one fresh protected login."
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-1-still-present.v1" and .attempt == 1 and .checks.resourceApiExactMatchesAfter == 1 and .checks.cliExactMatchesAfter == 1 and .minimumSettleMilliseconds == 60000 and .actualSettleMilliseconds >= 60000 and .verifiedAbsent == false and .attempt1TargetChildEvidence.classification == "authoritative-independent-resource-queries" and .attempt1TargetChildEvidence.authoritativeAtAttempt1 == true and .attempt1TargetChildEvidence.acceptedForIdentityAndProvenanceOnly == false and .attempt1TargetChildEvidence.legacyChildCountsTrustedForAttempt2 == false and .attempt1TargetChildEvidence.freshAttempt2AuthoritativeGateRequired == true' \
  "$attempt2_dir/windows/windows-portal-delete-attempt-1-still-present.json" >/dev/null \
  || fail "Attempt 2 did not preserve an exact immutable 1/1 still-present gate."
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-2-target.v1" and .attempt == 2 and .identityMatchesOriginal == true and (.tenantIdSha256 | test("^[a-f0-9]{64}$")) and .attempt1TargetChildEvidence.classification == "authoritative-independent-resource-queries" and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .preDeleteValidation.enrollmentExactMatches == 1 and .preDeleteValidation.authoritativeChildQueriesComplete == true and .preDeleteValidation.childQueries.serviceActivations.objectType == "vertical-service-activation" and .preDeleteValidation.childQueries.productConfigs.objectType == "vertical-product-config" and .preDeleteValidation.servicesBeforeDeletion == 0 and .preDeleteValidation.workflowExactMatchesBeforeDeletion == 0 and .preDeleteValidation.setupExactMatchesBeforeDeletion == 0 and .freshGuestAuthProven == true and .mutationAttempted == false' \
  "$attempt2_dir/windows/windows-portal-delete-attempt-2-target.json" >/dev/null \
  || fail "Attempt 2 did not write its exact freshly authenticated target receipt."
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-2-prepared.v1" and .attempt == 2 and .attempt1TargetChildEvidence.classification == "authoritative-independent-resource-queries" and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .explicitActionTimeConfirmationRequired == true and (.confirmationNonceSha256 | test("^[a-f0-9]{64}$")) and .preInvokeTargetRevalidationRequired == true and .deletePermanentlyInvoked == false' \
  "$attempt2_dir/windows/windows-portal-delete-attempt-2-prepared.json" >/dev/null \
  || fail "Attempt 2 did not write a ten-minute nonce-bound prepared receipt."
node - "$attempt2_dir/windows/windows-portal-delete-attempt-2-prepared.json" <<'NODE' \
  || fail "The attempt-2 prepared receipt does not have an exact ten-minute lifetime."
const fs = require("node:fs");
const receipt = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (Date.parse(receipt.expiresAt) - Date.parse(receipt.preparedAt) !== 600_000) process.exit(1);
NODE
if rg -F "$attempt2_nonce" "$attempt2_dir/windows" >/dev/null; then
  fail "The raw attempt-2 confirmation nonce was stored in evidence."
fi

set +e
run_helper --run-dir "$attempt2_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$(printf 'f%.0s' {1..64})" >/dev/null 2>&1
wrong_nonce_status=$?
set -e
[[ "$wrong_nonce_status" != 0 && ! -e "$attempt2_dir/windows/windows-portal-delete-attempt-2-invocation.json" \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$attempt2_launch_before" ]] \
  || fail "A wrong attempt-2 nonce reached or armed the destructive desktop action."

run_helper --run-dir "$attempt2_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$attempt2_nonce" >"$test_root/attempt2-invoke.stdout"
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-2-preinvoke.v1" and .attempt == 2 and .identityMatchesOriginal == true and .attempt1TargetChildEvidence.classification == "authoritative-independent-resource-queries" and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .explicitActionTimeConfirmationAccepted == true and .exactDialogReadyRevalidated == true and .interactiveWorkerReverified == true and .mutationAttempted == false' \
  "$attempt2_dir/windows/windows-portal-delete-attempt-2-preinvoke.json" >/dev/null \
  || fail "Attempt 2 did not preserve its immediate live target and dialog revalidation."
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-2-invocation.v1" and .attempt == 2 and .attempt1TargetChildEvidence.classification == "authoritative-independent-resource-queries" and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .mutationState == "invoked-dialog-closed-unverified" and .armedBeforeDestructiveInput == true and .explicitActionTimeConfirmationAccepted == true and .interactiveDesktopLaunchAttempted == true and .exactExpectedUser == true and .interactiveSessionId == 1 and .interactiveSessionProven == true and .explorerSessionMatched == true and .explorerOwnerSidMatched == true and .edgeUiBoundToInteractiveSession == true and .edgeOwnerSidMatched == true and .browserWindowHandle > 0 and .browserProcessId > 0 and .browserProcessSessionId == .interactiveSessionId and (.topLevelWindowRuntimeIdSha256 | test("^[a-f0-9]{64}$")) and (.dialogFinalRuntimeIdSha256 | test("^[a-f0-9]{64}$")) and .sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke == true and .exactBrowserWindowForegroundAtInvoke == true and .scopedInvokePatternInvoked == true and .confirmationDialogClosed == true and .dialogAbsentConsecutiveChecks >= 12 and .dialogClosureStableMilliseconds >= 3000 and .retryMutationAutomatically == false and .deletionVerified == false' \
  "$attempt2_dir/windows/windows-portal-delete-attempt-2-invocation.json" >/dev/null \
  || fail "Attempt 2 did not finish with a receipt-bound sustained interactive closure."
attempt2_launched_id="$(tail -n 1 "$test_root/interactive-launch.log" \
  | sed -n 's/.*-InvocationId "\([a-f0-9]\{32\}\)".*/\1/p')"
attempt2_launched_id_hash="$(printf '%s' "$attempt2_launched_id" | shasum -a 256 | awk '{print $1}')"
jq -e --arg invocation_hash "$attempt2_launched_id_hash" \
  '.interactiveInvocationIdSha256 == $invocation_hash' \
  "$attempt2_dir/windows/windows-portal-delete-attempt-2-invocation.json" >/dev/null \
  || fail "The exclusive attempt-2 arm was not bound to the actual interactive worker invocation ID."
[[ "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$((attempt2_launch_before + 1))" ]] \
  || fail "Attempt 2 did not launch the interactive destructive worker exactly once."
set +e
run_helper --run-dir "$attempt2_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$attempt2_nonce" >/dev/null 2>&1
attempt2_repeat_status=$?
run_helper --run-dir "$attempt2_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
attempt2_reprepare_status=$?
run_helper --run-dir "$attempt2_dir" --prepare-delete-attempt-3 >/dev/null 2>&1
attempt3_status=$?
set -e
[[ "$attempt2_repeat_status" != 0 && "$attempt2_reprepare_status" != 0 && "$attempt3_status" != 0 \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$((attempt2_launch_before + 1))" ]] \
  || fail "Attempt 2 was replayed or an attempt-3 path was accepted."

legacy_attempt2_dir="$(make_attempt2_legacy_eligible_run 1788317000117-abc117)"
legacy_original_hash_before="$(shasum -a 256 "$legacy_attempt2_dir/windows/windows-portal-cleanup-target.json" | awk '{print $1}')"
run_helper --run-dir "$legacy_attempt2_dir" --prepare-delete-attempt-2 >"$test_root/legacy-attempt2-prepare.stdout"
legacy_attempt2_nonce="$(tail -n 1 "$test_root/legacy-attempt2-prepare.stdout")"
[[ "$legacy_attempt2_nonce" =~ ^[a-f0-9]{64}$ ]] \
  || fail "A valid legacy attempt-1 target did not reach nonce-bound attempt-2 preparation after a fresh authoritative child gate."
[[ "$(shasum -a 256 "$legacy_attempt2_dir/windows/windows-portal-cleanup-target.json" | awk '{print $1}')" == "$legacy_original_hash_before" ]] \
  || fail "Attempt-2 preparation rewrote the immutable legacy attempt-1 target receipt."
jq -e '.attempt1TargetChildEvidence.classification == "legacy-embedded-fields-nonauthoritative" and .attempt1TargetChildEvidence.authoritativeAtAttempt1 == false and .attempt1TargetChildEvidence.acceptedForIdentityAndProvenanceOnly == true and .attempt1TargetChildEvidence.legacyChildCountsTrustedForAttempt2 == false and .attempt1TargetChildEvidence.freshAttempt2AuthoritativeGateRequired == true' \
  "$legacy_attempt2_dir/windows/windows-portal-delete-attempt-1-still-present.json" >/dev/null \
  || fail "The legacy attempt-1 receipt was not explicitly classified as non-authoritative history."
jq -e '.attempt1TargetChildEvidence.classification == "legacy-embedded-fields-nonauthoritative" and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .preDeleteValidation.authoritativeChildQueriesComplete == true and .preDeleteValidation.childQueries.queriesComplete == true and .preDeleteValidation.childQueries.serviceActivations.exactVerticalKeyMatches == 0 and .preDeleteValidation.childQueries.productConfigs.exactVerticalKeyMatches == 0' \
  "$legacy_attempt2_dir/windows/windows-portal-delete-attempt-2-target.json" >/dev/null \
  || fail "The legacy migration path did not bind a fresh authoritative attempt-2 child gate."
jq -e '.attempt1TargetChildEvidence.classification == "legacy-embedded-fields-nonauthoritative" and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .deletePermanentlyInvoked == false' \
  "$legacy_attempt2_dir/windows/windows-portal-delete-attempt-2-prepared.json" >/dev/null \
  || fail "The prepared legacy migration receipt lost its fresh child-gate binding."
run_helper --run-dir "$legacy_attempt2_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$legacy_attempt2_nonce" >/dev/null
jq -e '.attempt1TargetChildEvidence.classification == "legacy-embedded-fields-nonauthoritative" and .attempt1TargetChildEvidence.legacyChildCountsTrustedForAttempt2 == false and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .preDeleteValidation.authoritativeChildQueriesComplete == true and .preDeleteValidation.childQueries.queriesComplete == true' \
  "$legacy_attempt2_dir/windows/windows-portal-delete-attempt-2-preinvoke.json" >/dev/null \
  || fail "The legacy classification and fresh gate were not bound into immediate pre-invocation evidence."
jq -e '.attempt1TargetChildEvidence.classification == "legacy-embedded-fields-nonauthoritative" and .attempt1TargetChildEvidence.legacyChildCountsTrustedForAttempt2 == false and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries" and .mutationState == "invoked-dialog-closed-unverified"' \
  "$legacy_attempt2_dir/windows/windows-portal-delete-attempt-2-invocation.json" >/dev/null \
  || fail "The legacy classification and fresh gate were not bound into the final attempt-2 invocation chain."

legacy_failure_dir="$(make_attempt2_legacy_eligible_run 1788317000118-abc118)"
legacy_failure_ui_before="$(wc -l <"$test_root/ui.log" | tr -d ' ')"
legacy_failure_input_before="$(wc -l <"$test_root/input.log" | tr -d ' ')"
legacy_failure_worker_before="$(wc -l <"$test_root/worker.log" | tr -d ' ')"
legacy_failure_launch_before="$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')"
set +e
EAI_FAKE_TARGET_QUERY_FAILURE=1 run_helper --run-dir "$legacy_failure_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
legacy_failure_status=$?
set -e
[[ "$legacy_failure_status" != 0 \
  && ! -e "$legacy_failure_dir/windows/windows-portal-delete-attempt-2-target.json" \
  && ! -e "$legacy_failure_dir/windows/windows-portal-delete-attempt-2-prepared.json" \
  && "$(wc -l <"$test_root/ui.log" | tr -d ' ')" == "$legacy_failure_ui_before" \
  && "$(wc -l <"$test_root/input.log" | tr -d ' ')" == "$legacy_failure_input_before" \
  && "$(wc -l <"$test_root/worker.log" | tr -d ' ')" == "$legacy_failure_worker_before" \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$legacy_failure_launch_before" ]] \
  || fail "A failed fresh authoritative query on the legacy path reached UI preparation or mutation."

legacy_incomplete_dir="$(make_attempt2_legacy_eligible_run 1788317000119-abc119)"
legacy_incomplete_ui_before="$(wc -l <"$test_root/ui.log" | tr -d ' ')"
legacy_incomplete_input_before="$(wc -l <"$test_root/input.log" | tr -d ' ')"
legacy_incomplete_worker_before="$(wc -l <"$test_root/worker.log" | tr -d ' ')"
legacy_incomplete_launch_before="$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')"
set +e
EAI_FAKE_CHILD_QUERY_INCOMPLETE=1 run_helper --run-dir "$legacy_incomplete_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
legacy_incomplete_status=$?
set -e
[[ "$legacy_incomplete_status" != 0 \
  && ! -e "$legacy_incomplete_dir/windows/windows-portal-delete-attempt-2-target.json" \
  && ! -e "$legacy_incomplete_dir/windows/windows-portal-delete-attempt-2-prepared.json" \
  && "$(wc -l <"$test_root/ui.log" | tr -d ' ')" == "$legacy_incomplete_ui_before" \
  && "$(wc -l <"$test_root/input.log" | tr -d ' ')" == "$legacy_incomplete_input_before" \
  && "$(wc -l <"$test_root/worker.log" | tr -d ' ')" == "$legacy_incomplete_worker_before" \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$legacy_incomplete_launch_before" ]] \
  || fail "Incomplete fresh child queries on the legacy path reached UI preparation or mutation."

legacy_nonzero_dir="$(make_attempt2_legacy_eligible_run 1788317000120-abc120)"
legacy_nonzero_ui_before="$(wc -l <"$test_root/ui.log" | tr -d ' ')"
legacy_nonzero_input_before="$(wc -l <"$test_root/input.log" | tr -d ' ')"
legacy_nonzero_worker_before="$(wc -l <"$test_root/worker.log" | tr -d ' ')"
legacy_nonzero_launch_before="$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')"
set +e
EAI_FAKE_CHILD_COUNT=1 run_helper --run-dir "$legacy_nonzero_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
legacy_nonzero_status=$?
set -e
[[ "$legacy_nonzero_status" != 0 \
  && ! -e "$legacy_nonzero_dir/windows/windows-portal-delete-attempt-2-target.json" \
  && ! -e "$legacy_nonzero_dir/windows/windows-portal-delete-attempt-2-prepared.json" \
  && "$(wc -l <"$test_root/ui.log" | tr -d ' ')" == "$legacy_nonzero_ui_before" \
  && "$(wc -l <"$test_root/input.log" | tr -d ' ')" == "$legacy_nonzero_input_before" \
  && "$(wc -l <"$test_root/worker.log" | tr -d ' ')" == "$legacy_nonzero_worker_before" \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$legacy_nonzero_launch_before" ]] \
  || fail "Nonzero fresh child state on the legacy path reached UI preparation or mutation."

attempt2_mixed_dir="$(make_attempt2_eligible_run 1788317000109-abc109)"
node - "$attempt2_mixed_dir/windows/windows-cleanup-verification-only.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.absence.resourceApiExactMatchesAfter = 0;
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
mixed_login_before="$(wc -l <"$test_root/login.log" | tr -d ' ')"
set +e
run_helper --run-dir "$attempt2_mixed_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
mixed_status=$?
set -e
[[ "$mixed_status" != 0 && "$(wc -l <"$test_root/login.log" | tr -d ' ')" == "$mixed_login_before" \
  && ! -e "$attempt2_mixed_dir/windows/windows-portal-delete-attempt-2-target.json" ]] \
  || fail "Mixed API/CLI presence counts did not fail before fresh login and target preparation."

attempt2_early_dir="$(make_attempt2_eligible_run 1788317000110-abc110)"
node - "$attempt2_early_dir/windows/windows-portal-delete-invocation.json" "$attempt2_early_dir/windows/windows-cleanup-verification-only.json" <<'NODE'
const fs = require("node:fs");
const [invocationPath, verificationPath] = process.argv.slice(2);
const invocation = JSON.parse(fs.readFileSync(invocationPath, "utf8"));
const verification = JSON.parse(fs.readFileSync(verificationPath, "utf8"));
const tooEarly = new Date(Date.parse(invocation.recordedAt) + 59_999).toISOString();
verification.absence.verifiedAt = tooEarly;
verification.recordedAt = tooEarly;
fs.writeFileSync(verificationPath, `${JSON.stringify(verification, null, 2)}\n`);
const invocationMtime = fs.statSync(invocationPath).mtimeMs;
fs.utimesSync(verificationPath, new Date(invocationMtime + 59_999), new Date(invocationMtime + 59_999));
NODE
set +e
run_helper --run-dir "$attempt2_early_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
early_status=$?
set -e
[[ "$early_status" != 0 && ! -e "$attempt2_early_dir/windows/windows-portal-delete-attempt-1-still-present.json" ]] \
  || fail "An attempt-1 verification less than 60 seconds after invocation was accepted."

attempt2_identity_dir="$(make_attempt2_eligible_run 1788317000111-abc111)"
set +e
EAI_FAKE_RESOURCE_HASH="$(printf 'b%.0s' {1..64})" \
  run_helper --run-dir "$attempt2_identity_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
identity_status=$?
set -e
[[ "$identity_status" != 0 && ! -e "$attempt2_identity_dir/windows/windows-portal-delete-attempt-2-target.json" ]] \
  || fail "A changed resource ID hash produced an attempt-2 target receipt."

attempt2_child_dir="$(make_attempt2_eligible_run 1788317000112-abc112)"
set +e
EAI_FAKE_CHILD_COUNT=1 run_helper --run-dir "$attempt2_child_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
attempt2_child_status=$?
set -e
[[ "$attempt2_child_status" != 0 && ! -e "$attempt2_child_dir/windows/windows-portal-delete-attempt-2-target.json" ]] \
  || fail "Nonzero child state produced an attempt-2 target receipt."

attempt2_uncertain_dir="$(make_attempt2_eligible_run 1788317000113-abc113)"
run_helper --run-dir "$attempt2_uncertain_dir" --prepare-delete-attempt-2 >"$test_root/attempt2-uncertain-prepare.stdout"
attempt2_uncertain_nonce="$(tail -n 1 "$test_root/attempt2-uncertain-prepare.stdout")"
uncertain_launch_before="$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')"
set +e
EAI_FAKE_INTERACTIVE_OUTCOME=dialog-open run_helper --run-dir "$attempt2_uncertain_dir" \
  --invoke-delete-attempt-2 --confirmation-nonce "$attempt2_uncertain_nonce" >/dev/null 2>&1
attempt2_uncertain_status=$?
set -e
[[ "$attempt2_uncertain_status" != 0 ]] || fail "Attempt 2 reported an open confirmation dialog as success."
jq -e '.mutationState == "uncertain" and .armedBeforeDestructiveInput == true and .retryMutationAutomatically == false and .deletionVerified == false' \
  "$attempt2_uncertain_dir/windows/windows-portal-delete-attempt-2-invocation.json" >/dev/null \
  || fail "An uncertain attempt 2 did not preserve its pre-action arm."
set +e
run_helper --run-dir "$attempt2_uncertain_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$attempt2_uncertain_nonce" >/dev/null 2>&1
attempt2_uncertain_repeat_status=$?
set -e
[[ "$attempt2_uncertain_repeat_status" != 0 \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$((uncertain_launch_before + 1))" ]] \
  || fail "An uncertain attempt 2 was replayed."

attempt2_lock_dir="$(make_attempt2_eligible_run 1788317000114-abc114)"
mkdir "$attempt2_lock_dir/windows/.windows-portal-delete-attempt-2.lock"
lock_login_before="$(wc -l <"$test_root/login.log" | tr -d ' ')"
set +e
run_helper --run-dir "$attempt2_lock_dir" --prepare-delete-attempt-2 >/dev/null 2>&1
lock_status=$?
set -e
[[ "$lock_status" != 0 && -d "$attempt2_lock_dir/windows/.windows-portal-delete-attempt-2.lock" \
  && "$(wc -l <"$test_root/login.log" | tr -d ' ')" == "$lock_login_before" ]] \
  || fail "A pre-existing attempt-2 lock was bypassed or removed automatically."
rmdir "$attempt2_lock_dir/windows/.windows-portal-delete-attempt-2.lock"

attempt2_tenant_dir="$(make_attempt2_eligible_run 1788317000115-abc115)"
run_helper --run-dir "$attempt2_tenant_dir" --prepare-delete-attempt-2 >"$test_root/attempt2-tenant-prepare.stdout"
attempt2_tenant_nonce="$(tail -n 1 "$test_root/attempt2-tenant-prepare.stdout")"
tenant_launch_before="$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')"
set +e
EAI_TEST_TENANT_ID="11111111-1111-4111-8111-111111111111" run_helper \
  --run-dir "$attempt2_tenant_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$attempt2_tenant_nonce" >/dev/null 2>&1
tenant_status=$?
set -e
[[ "$tenant_status" != 0 && ! -e "$attempt2_tenant_dir/windows/windows-portal-delete-attempt-2-preinvoke.json" \
  && ! -e "$attempt2_tenant_dir/windows/windows-portal-delete-attempt-2-invocation.json" \
  && "$(wc -l <"$test_root/interactive-launch.log" | tr -d ' ')" == "$tenant_launch_before" ]] \
  || fail "A different runtime tenant crossed the attempt-2 receipt boundary."

attempt2_expired_dir="$(make_attempt2_eligible_run 1788317000116-abc116)"
run_helper --run-dir "$attempt2_expired_dir" --prepare-delete-attempt-2 >"$test_root/attempt2-expired-prepare.stdout"
attempt2_expired_nonce="$(tail -n 1 "$test_root/attempt2-expired-prepare.stdout")"
node - "$attempt2_expired_dir/windows/windows-portal-delete-attempt-2-prepared.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.preparedAt = new Date(Date.now() - 610_000).toISOString();
value.expiresAt = new Date(Date.now() - 10_000).toISOString();
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
set +e
run_helper --run-dir "$attempt2_expired_dir" --invoke-delete-attempt-2 \
  --confirmation-nonce "$attempt2_expired_nonce" >/dev/null 2>&1
expired_status=$?
set -e
[[ "$expired_status" != 0 && ! -e "$attempt2_expired_dir/windows/windows-portal-delete-attempt-2-invocation.json" ]] \
  || fail "An expired attempt-2 preparation reached the exclusive arm."

printf 'Windows portal cleanup UI checks ok\n'
