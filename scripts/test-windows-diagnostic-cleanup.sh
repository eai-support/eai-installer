#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ps_helper="$ROOT/scripts/windows-diagnostic-cleanup.ps1"
artifact_root="$ROOT/artifacts/release-e2e"
test_root="$(mktemp -d "$artifact_root/.windows-cleanup-test.XXXXXX")"
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'Windows diagnostic cleanup test failed: %s\n' "$*" >&2
  exit 1
}

[[ -f "$ps_helper" && ! -L "$ps_helper" ]] \
  || fail "The PowerShell cleanup helper is missing or unsafe."
EAI_WINDOWS_CLEANUP_PS_HELPER="$ps_helper" node --input-type=module <<'NODE'
import fs from "node:fs";

const source = fs.readFileSync(process.env.EAI_WINDOWS_CLEANUP_PS_HELPER, "utf8");
const required = [
  "C:\\Users\\Public\\EAIReleaseTests",
  "Resolve-ExactEaiCleanupProject -AppKey $appKey",
  "Get-RealDirectoryWithoutReparsePoints",
  "[IO.FileAttributes]::ReparsePoint",
  "@eai-tools/$AppKey",
  ".eai-manifest.json",
  "src\\eai.config\\object-types.ts",
  "Push-Location -LiteralPath $binding.ProjectPath",
  "Assert-CompleteBoundedResourcePage",
  "'--limit', '1000'",
];
for (const marker of required) {
  if (!source.includes(marker)) throw new Error(`missing cleanup project-binding marker: ${marker}`);
}
if (source.includes("'--where'")) {
  throw new Error("PowerShell 5.1-fragile JSON --where arguments must not be used by cleanup.");
}
if (/EAI_[A-Z0-9_]*PROJECT(?:_ROOT|_PATH)|env:[A-Za-z0-9_]*PROJECT/i.test(source)) {
  throw new Error("The guest cleanup project root must not be supplied by environment or input.");
}
const initialBinding = source.indexOf("$projectBinding = Resolve-ExactEaiCleanupProject -AppKey $appKey");
const firstLiveQuery = source.indexOf("if ($mode -ceq 'PortalTargetOnly')");
if (initialBinding < 0 || firstLiveQuery < 0 || initialBinding >= firstLiveQuery) {
  throw new Error("The exact generated project is not bound before cleanup query/mutation branches.");
}
const invokeStart = source.indexOf("function Invoke-Eai");
const invokeEnd = source.indexOf("function Get-ExactEnrollment", invokeStart);
const invokeBody = source.slice(invokeStart, invokeEnd);
if (invokeBody.indexOf("Resolve-ExactEaiCleanupProject") > invokeBody.indexOf("& $script:EaiPath")) {
  throw new Error("The EAI command can run before its exact project is revalidated.");
}
if (!/\$previousErrorActionPreference = \$ErrorActionPreference[\s\S]*\$ErrorActionPreference = 'Continue'[\s\S]*& \$script:EaiPath @Arguments 2>&1[\s\S]*\$ErrorActionPreference = \$previousErrorActionPreference/.test(invokeBody)) {
  throw new Error("Native CLI stderr is not safely captured around the exact invocation.");
}
NODE

if command -v pwsh >/dev/null 2>&1; then
  [[ "$(pwsh -NoLogo -NoProfile -NonInteractive -File "$ps_helper" -SelfTest)" == \
    "WINDOWS_DIAGNOSTIC_CLEANUP_SELF_TEST_OK" ]] \
    || fail "The PowerShell cleanup self-test failed."
fi

grep -Fq -- 'windows_hidden_current_user_ps "$vm_name" ""' \
  "$ROOT/scripts/run-windows-diagnostic-cleanup.sh" \
  || fail "Diagnostic cleanup must use the hidden current-user PowerShell transport."
grep -Fq -- 'source "$ROOT/scripts/windows-hidden-current-user.sh"' "$ROOT/scripts/run-windows-diagnostic-cleanup.sh" \
  || fail "Diagnostic cleanup must keep its current-user PowerShell window hidden."

fake_login="$fake_bin/login"
cat >"$fake_login" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --portal-only|--cli-only) printf '%s\n' "$1" >>"$EAI_FAKE_LOGIN_LOG" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake_login"

fake_prlctl="$fake_bin/prlctl"
cat >"$fake_prlctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    printf 'running\n'
    exit 0
    ;;
  exec)
    payload="$(cat)"
    decoded="$(printf '%s' "$payload" | node -e '
      let source = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { source += chunk; });
      process.stdin.on("end", () => {
        const match = source.match(/-CleanupInputBase64 @\("([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)", "([A-Za-z0-9+/=]*)"\)/);
        if (!match) process.exit(2);
        process.stdout.write(match.slice(1).map((value) => Buffer.from(value, "base64").toString("utf8")).join("\n"));
      });
    ')"
    mode="$(printf '%s\n' "$decoded" | sed -n '1p')"
    app="$(printf '%s\n' "$decoded" | sed -n '2p')"
    run="$(printf '%s\n' "$decoded" | sed -n '4p')"
    case "$EAI_FAKE_CLEANUP_RESULT" in
      fallback)
        node - "$run" "$app" <<'NODE'
const [runId, appName] = process.argv.slice(2);
console.log(JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup.v1",
  action: "fallback-gate-required",
  runId,
  platform: "windows",
  appName,
  displayName: "Exact Windows Test App",
  resourceCreatedAt: new Date(Number(runId.slice(0, 13)) + 1000).toISOString(),
  resourceIdSha256: "a".repeat(64),
  preDeleteValidation: {
    enrollmentExactMatches: 1,
    createdDuringThisRun: true,
    sourceVerified: true,
    embeddedChildFieldsEmpty: true,
    servicesBeforeDeletion: null,
    workflowExactMatchesBeforeDeletion: null,
    setupExactMatchesBeforeDeletion: null,
  },
  v4Attempt: {
    attempts: 1,
    exitCode: 1,
    outputLineCount: 1,
    sanitizedOutputSha256: "b".repeat(64),
    classification: {
      deletionRequest: true,
      missingOwnershipManifest: true,
      deletionPlanNotFound: false,
      authenticationFailure: false,
      knownDiagnosticFallbackCondition: true,
    },
    sanitized: true,
    diagnostic: true,
    attemptedAt: new Date().toISOString(),
  },
  deleted: false,
  portalDeleteAutomationAvailable: false,
  portalVerificationRequired: true,
  cleanupVerified: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}));
NODE
        exit 3
        ;;
      deleted)
        node - "$run" "$app" <<'NODE'
const [runId, appName] = process.argv.slice(2);
console.log(JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup.v1",
  action: "deleted-v4",
  runId,
  platform: "windows",
  appName,
  displayName: "Exact Windows Test App",
  resourceCreatedAt: new Date(Number(runId.slice(0, 13)) + 1000).toISOString(),
  resourceIdSha256: "a".repeat(64),
  method: "public-api-v4-cli",
  preDeleteValidation: {
    enrollmentExactMatches: 1,
    createdDuringThisRun: true,
    sourceVerified: true,
    embeddedChildFieldsEmpty: true,
    servicesBeforeDeletion: null,
    workflowExactMatchesBeforeDeletion: null,
    setupExactMatchesBeforeDeletion: null,
  },
  v4Attempt: {
    attempts: 1,
    exitCode: 0,
    outputLineCount: 1,
    sanitizedOutputSha256: "b".repeat(64),
    classification: {
      deletionRequest: true,
      missingOwnershipManifest: false,
      deletionPlanNotFound: false,
      authenticationFailure: false,
      knownDiagnosticFallbackCondition: false,
    },
    sanitized: true,
    diagnostic: true,
    attemptedAt: new Date().toISOString(),
  },
  deletion: { method: "public-api-v4-cli", exitCode: 0, verified: true, operationIdSha256: "c".repeat(64) },
  absence: {
    resourceApiExactMatchesAfter: 0,
    cliExactMatchesAfter: 0,
    resourceApiQuerySucceeded: true,
    cliAppListSucceeded: true,
    verified: true,
    verifiedAt: new Date().toISOString(),
  },
  deleted: true,
  portalDeleteAutomationAvailable: false,
  portalVerificationRequired: true,
  cleanupVerified: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}));
NODE
        exit 0
        ;;
      verify)
        [[ "$mode" == VerifyOnly ]] || exit 9
        node - "$run" "$app" <<'NODE'
const [runId, appName] = process.argv.slice(2);
console.log(JSON.stringify({
  schemaVersion: "eai.windows-diagnostic-cleanup.v1",
  action: "verify-only",
  runId,
  platform: "windows",
  appName,
  absence: {
    resourceApiExactMatchesAfter: 0,
    cliExactMatchesAfter: 0,
    resourceApiQuerySucceeded: true,
    cliAppListSucceeded: true,
    verified: true,
    verifiedAt: new Date().toISOString(),
  },
  deleted: false,
  portalVerificationRequired: true,
  cleanupVerified: false,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
}));
NODE
        exit 0
        ;;
      empty)
        exit 1
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake_prlctl"

fake_hidden_ps="$fake_bin/hidden-ps"
cat >"$fake_hidden_ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$EAI_WINDOWS_CLEANUP_PRLCTL_BIN" exec "$1" --current-user powershell.exe
EOF
chmod +x "$fake_hidden_ps"

make_run() {
  local run_id="$1"
  local run_dir="$test_root/$run_id"
  local app="test-windows-$run_id"
  mkdir -p "$run_dir/windows"
  node - "$run_dir" "$run_id" "$app" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [runDir, runId, appName] = process.argv.slice(2);
const checks = Object.fromEntries(["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"].map((name) => [name, "passed"]));
fs.writeFileSync(path.join(runDir, "release-e2e.json"), JSON.stringify({
  runId,
  status: "passed_with_mock_cleanup",
  machines: [{ vm: "windows", status: "passed", appName, appCreated: true }],
}, null, 2));
fs.writeFileSync(path.join(runDir, "windows", "app-state.json"), JSON.stringify({ appName, appCreated: true }, null, 2));
fs.writeFileSync(path.join(runDir, "windows", "vm-result.json"), JSON.stringify({
  status: "passed",
  vm: "windows",
  appName,
  appCreated: true,
  cleanupRequested: true,
  checks,
}, null, 2));
NODE
  printf '%s\n' "$run_dir"
}

make_completed_portal_attempt2_run() {
  local run_id="$1"
  local run_dir=""
  run_dir="$(make_run "$run_id")"
  node - "$run_dir" "$run_id" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const [runDir, runId] = process.argv.slice(2);
const directory = path.join(runDir, "windows");
const appName = `test-windows-${runId}`;
const displayName = "Exact Windows Test App";
const resourceIdSha256 = "a".repeat(64);
const tenantIdSha256 = crypto.createHash("sha256").update("00000000-0000-4000-8000-000000000000").digest("hex");
const resourceCreatedAt = new Date(Number(runId.slice(0, 13)) + 1000).toISOString();
const markings = { sanitized: true, diagnostic: true, productionGate: false };
const checks = {
  enrollmentExactMatches: 1,
  createdDuringThisRun: true,
  sourceVerified: true,
  authoritativeChildQueriesComplete: true,
  childQueries: {
    queriesComplete: true,
    serviceActivations: { objectType: "vertical-service-activation", filterField: "data.verticalKey", comparison: "case-sensitive-exact", filterValueAppKeyBound: true, querySucceeded: true, completeBoundedPage: true, totalDocs: 0, exactVerticalKeyMatches: 0 },
    productConfigs: { objectType: "vertical-product-config", filterField: "data.verticalKey", comparison: "case-sensitive-exact", filterValueAppKeyBound: true, querySucceeded: true, completeBoundedPage: true, totalDocs: 0, exactVerticalKeyMatches: 0 },
  },
  servicesBeforeDeletion: 0,
  verticalProductConfigsBeforeDeletion: 0,
  workflowExactMatchesBeforeDeletion: 0,
  setupExactMatchesBeforeDeletion: 0,
};
const childHistory = {
  classification: "authoritative-independent-resource-queries",
  authoritativeAtAttempt1: true,
  acceptedForIdentityAndProvenanceOnly: false,
  legacyChildCountsTrustedForAttempt2: false,
  freshAttempt2AuthoritativeGateRequired: true,
};
const freshChildGate = {
  attempt1TargetChildEvidence: childHistory,
  freshAttempt2AuthoritativeChildGateEstablished: true,
  freshAttempt2AuthoritativeChildGateSource: "bounded-exact-resource-queries",
};
const write = (name, value) => fs.writeFileSync(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`);
const hash = (name) => crypto.createHash("sha256").update(fs.readFileSync(path.join(directory, name))).digest("hex");
const originalTarget = {
  schemaVersion: "eai.windows-portal-cleanup-target.v1", runId, platform: "windows", appName,
  displayName, resourceIdSha256, resourceCreatedAt, tenantIdSha256, preDeleteValidation: checks,
  freshGuestAuthProven: true, mutationAttempted: false, ...markings,
};
write("windows-portal-cleanup-target.json", originalTarget);
write("windows-portal-delete-prepared.json", {
  schemaVersion: "eai.windows-portal-delete-prepared.v1", runId, platform: "windows", appName,
  displayName, tenantIdSha256, targetReceiptSha256: hash("windows-portal-cleanup-target.json"),
  exactOrigin: "admin-portal.myenterprise.ai", exactPath: "/platform/apps",
  exactRowBound: true, typedConfirmationVerified: true, deletePermanentlyInvoked: false,
  ...markings,
});
write("windows-portal-delete-invocation.json", {
  schemaVersion: "eai.windows-portal-delete-invocation.v1", runId, platform: "windows", appName,
  tenantIdSha256, action: "invoke-delete-permanently", mutationState: "invoked-unverified", transportExitCode: 0,
  retryMutationAutomatically: false, deletionVerified: false, absenceVerificationRequired: true,
  recordedAt: new Date(Date.now() - 180_000).toISOString(), ...markings,
});
const firstVerification = {
  schemaVersion: "eai.windows-diagnostic-cleanup.v1", action: "verify-only", runId, platform: "windows", appName,
  absence: {
    resourceApiExactMatchesAfter: 1, cliExactMatchesAfter: 1,
    resourceApiQuerySucceeded: true, cliAppListSucceeded: true, verified: false,
    verifiedAt: new Date(Date.now() - 90_000).toISOString(),
  },
  deleted: false, cleanupVerified: false, recordedAt: new Date(Date.now() - 90_000).toISOString(), ...markings,
};
write("windows-cleanup-verification-only.json", firstVerification);
write("windows-portal-delete-attempt-1-still-present.json", {
  schemaVersion: "eai.windows-portal-delete-attempt-1-still-present.v1", attempt: 1,
  runId, platform: "windows", appName, displayName, resourceIdSha256, resourceCreatedAt,
  attempt1TargetReceiptSha256: hash("windows-portal-cleanup-target.json"),
  attempt1InvocationReceiptSha256: hash("windows-portal-delete-invocation.json"),
  sourceVerifyOnlyReceiptSha256: hash("windows-cleanup-verification-only.json"),
  attempt1TargetChildEvidence: childHistory,
  checks: { resourceApiExactMatchesAfter: 1, cliExactMatchesAfter: 1 },
  verifiedAbsent: false, ...markings,
});
write("windows-portal-delete-attempt-2-target.json", {
  schemaVersion: "eai.windows-portal-delete-attempt-2-target.v1", attempt: 2,
  runId, platform: "windows", appName, displayName, resourceIdSha256, resourceCreatedAt, tenantIdSha256,
  originalTargetReceiptSha256: hash("windows-portal-cleanup-target.json"),
  attempt1StillPresentReceiptSha256: hash("windows-portal-delete-attempt-1-still-present.json"),
  identityMatchesOriginal: true, preDeleteValidation: checks, ...freshChildGate, ...markings,
});
write("windows-portal-delete-attempt-2-prepared.json", {
  schemaVersion: "eai.windows-portal-delete-attempt-2-prepared.v1", attempt: 2,
  runId, platform: "windows", appName, displayName, resourceIdSha256, resourceCreatedAt, tenantIdSha256,
  targetReceiptSha256: hash("windows-portal-delete-attempt-2-target.json"),
  attempt1StillPresentReceiptSha256: hash("windows-portal-delete-attempt-1-still-present.json"),
  explicitActionTimeConfirmationRequired: true,
  confirmationNonceSha256: "c".repeat(64),
  preInvokeTargetRevalidationRequired: true,
  deletePermanentlyInvoked: false,
  ...freshChildGate, ...markings,
});
write("windows-portal-delete-attempt-2-preinvoke.json", {
  schemaVersion: "eai.windows-portal-delete-attempt-2-preinvoke.v1", attempt: 2,
  runId, platform: "windows", appName, displayName, resourceIdSha256, resourceCreatedAt, tenantIdSha256,
  targetReceiptSha256: hash("windows-portal-delete-attempt-2-target.json"),
  preparedReceiptSha256: hash("windows-portal-delete-attempt-2-prepared.json"),
  identityMatchesOriginal: true, exactDialogReadyRevalidated: true,
  confirmationNonceSha256: "c".repeat(64), explicitActionTimeConfirmationAccepted: true,
  interactiveWorkerReverified: true, preDeleteValidation: checks, ...freshChildGate, ...markings,
});
write("windows-portal-delete-attempt-2-invocation.json", {
  schemaVersion: "eai.windows-portal-delete-attempt-2-invocation.v1", attempt: 2,
  runId, platform: "windows", appName, tenantIdSha256, action: "invoke-delete-attempt-2",
  attempt1InvocationReceiptSha256: hash("windows-portal-delete-invocation.json"),
  attempt1StillPresentReceiptSha256: hash("windows-portal-delete-attempt-1-still-present.json"),
  targetReceiptSha256: hash("windows-portal-delete-attempt-2-target.json"),
  preparedReceiptSha256: hash("windows-portal-delete-attempt-2-prepared.json"),
  preInvokeReceiptSha256: hash("windows-portal-delete-attempt-2-preinvoke.json"),
  confirmationNonceSha256: "c".repeat(64), explicitActionTimeConfirmationAccepted: true,
  mutationState: "invoked-dialog-closed-unverified", armedBeforeDestructiveInput: true,
  transportExitCode: 0, interactiveDesktopLaunchAttempted: true, interactiveResultValidated: true,
  exactDialogVerified: true, exactTypedValueVerified: true,
  exactDialogRevalidatedImmediatelyBeforeInvoke: true, exactButtonFocused: true,
  scopedInvokePatternInvoked: true,
  exactExpectedUser: true, interactiveSessionProven: true, interactiveSessionId: 1,
  explorerSessionMatched: true, explorerOwnerSidMatched: true,
  edgeUiBoundToInteractiveSession: true, edgeOwnerSidMatched: true,
  browserWindowHandle: 101, browserProcessId: 202, browserProcessSessionId: 1,
  topLevelWindowRuntimeIdSha256: "d".repeat(64), dialogFinalRuntimeIdSha256: "e".repeat(64),
  sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke: true,
  exactBrowserWindowForegroundAtInvoke: true,
  confirmationDialogClosed: true, dialogAbsentConsecutiveChecks: 12,
  dialogClosureStableMilliseconds: 3000, retryMutationAutomatically: false,
  deletionVerified: false, absenceVerificationRequired: true,
  completedAt: new Date(Date.now() - 60_000).toISOString(), ...freshChildGate, ...markings,
});
NODE
  printf '%s\n' "$run_dir"
}

rehash_attempt2_chain() {
  local run_dir="$1"
  node - "$run_dir" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const directory = path.join(process.argv[2], "windows");
const file = (name) => path.join(directory, name);
const read = (name) => JSON.parse(fs.readFileSync(file(name), "utf8"));
const write = (name, value) => fs.writeFileSync(file(name), `${JSON.stringify(value, null, 2)}\n`);
const hash = (name) => crypto.createHash("sha256").update(fs.readFileSync(file(name))).digest("hex");
const target = read("windows-portal-delete-attempt-2-target.json");
target.originalTargetReceiptSha256 = hash("windows-portal-cleanup-target.json");
target.attempt1StillPresentReceiptSha256 = hash("windows-portal-delete-attempt-1-still-present.json");
write("windows-portal-delete-attempt-2-target.json", target);
const prepared = read("windows-portal-delete-attempt-2-prepared.json");
prepared.targetReceiptSha256 = hash("windows-portal-delete-attempt-2-target.json");
prepared.attempt1StillPresentReceiptSha256 = hash("windows-portal-delete-attempt-1-still-present.json");
write("windows-portal-delete-attempt-2-prepared.json", prepared);
const preinvoke = read("windows-portal-delete-attempt-2-preinvoke.json");
preinvoke.targetReceiptSha256 = hash("windows-portal-delete-attempt-2-target.json");
preinvoke.preparedReceiptSha256 = hash("windows-portal-delete-attempt-2-prepared.json");
write("windows-portal-delete-attempt-2-preinvoke.json", preinvoke);
const invocation = read("windows-portal-delete-attempt-2-invocation.json");
invocation.attempt1InvocationReceiptSha256 = hash("windows-portal-delete-invocation.json");
invocation.attempt1StillPresentReceiptSha256 = hash("windows-portal-delete-attempt-1-still-present.json");
invocation.targetReceiptSha256 = hash("windows-portal-delete-attempt-2-target.json");
invocation.preparedReceiptSha256 = hash("windows-portal-delete-attempt-2-prepared.json");
invocation.preInvokeReceiptSha256 = hash("windows-portal-delete-attempt-2-preinvoke.json");
write("windows-portal-delete-attempt-2-invocation.json", invocation);
NODE
}

tamper_attempt2_semantics() {
  local run_dir="$1"
  local tamper="$2"
  node - "$run_dir" "$tamper" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [runDir, tamper] = process.argv.slice(2);
const directory = path.join(runDir, "windows");
const read = (name) => JSON.parse(fs.readFileSync(path.join(directory, name), "utf8"));
const write = (name, value) => fs.writeFileSync(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`);
const chainNames = [
  "windows-portal-delete-attempt-1-still-present.json",
  "windows-portal-delete-attempt-2-target.json",
  "windows-portal-delete-attempt-2-prepared.json",
  "windows-portal-delete-attempt-2-preinvoke.json",
  "windows-portal-delete-attempt-2-invocation.json",
];
if (tamper === "missing-classification") {
  const value = read(chainNames[0]);
  delete value.attempt1TargetChildEvidence;
  write(chainNames[0], value);
} else if (tamper === "tampered-classification") {
  for (const name of chainNames) {
    const value = read(name);
    value.attempt1TargetChildEvidence = {
      classification: "legacy-embedded-fields-nonauthoritative",
      authoritativeAtAttempt1: false,
      acceptedForIdentityAndProvenanceOnly: true,
      legacyChildCountsTrustedForAttempt2: false,
      freshAttempt2AuthoritativeGateRequired: true,
    };
    write(name, value);
  }
} else if (tamper === "missing-fresh-gate") {
  for (const name of chainNames.slice(1)) {
    const value = read(name);
    delete value.freshAttempt2AuthoritativeChildGateEstablished;
    write(name, value);
  }
} else if (tamper === "tampered-fresh-source") {
  for (const name of chainNames.slice(1)) {
    const value = read(name);
    value.freshAttempt2AuthoritativeChildGateSource = "legacy-embedded-fields";
    write(name, value);
  }
} else if (tamper === "preinvoke-child-proof") {
  const value = read("windows-portal-delete-attempt-2-preinvoke.json");
  value.preDeleteValidation.childQueries.queriesComplete = false;
  write("windows-portal-delete-attempt-2-preinvoke.json", value);
} else {
  throw new Error("unknown-tamper");
}
NODE
  rehash_attempt2_chain "$run_dir"
}

make_completed_portal_attempt1_run() {
  local run_id="$1"
  local run_dir=""
  run_dir="$(make_completed_portal_attempt2_run "$run_id")"
  node - "$run_dir" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const directory = path.join(process.argv[2], "windows");
for (const name of [
  "windows-portal-delete-attempt-1-still-present.json",
  "windows-portal-delete-attempt-2-target.json",
  "windows-portal-delete-attempt-2-prepared.json",
  "windows-portal-delete-attempt-2-preinvoke.json",
  "windows-portal-delete-attempt-2-invocation.json",
]) fs.unlinkSync(path.join(directory, name));
const hash = (name) => crypto.createHash("sha256").update(fs.readFileSync(path.join(directory, name))).digest("hex");
const file = path.join(directory, "windows-portal-delete-invocation.json");
const value = JSON.parse(fs.readFileSync(file, "utf8"));
Object.assign(value, {
  targetReceiptSha256: hash("windows-portal-cleanup-target.json"),
  preparedReceiptSha256: hash("windows-portal-delete-prepared.json"),
  interactiveDesktopLaunchAttempted: true, interactiveResultValidated: true,
  exactDialogVerified: true, exactTypedValueVerified: true,
  exactDialogRevalidatedImmediatelyBeforeInvoke: true, exactButtonFocused: true,
  scopedInvokePatternInvoked: true, exactExpectedUser: true,
  interactiveSessionId: 1, interactiveSessionProven: true,
  explorerSessionMatched: true, explorerOwnerSidMatched: true,
  edgeUiBoundToInteractiveSession: true, edgeOwnerSidMatched: true,
  browserWindowHandle: 101, browserProcessId: 202, browserProcessSessionId: 1,
  topLevelWindowRuntimeIdSha256: "d".repeat(64), dialogFinalRuntimeIdSha256: "e".repeat(64),
  sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke: true,
  exactBrowserWindowForegroundAtInvoke: true,
  confirmationDialogClosed: true, dialogAbsentConsecutiveChecks: 12,
  dialogClosureStableMilliseconds: 3000,
});
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
  printf '%s\n' "$run_dir"
}

make_creation_checkpoint_failure_run() {
  local run_id="$1"
  local app_check="${2:-passed}"
  local exact_local_project_checkpoint="${3:-false}"
  local run_dir="$test_root/$run_id"
  local app="test-windows-$run_id"
  mkdir -p "$run_dir/windows"
  node - "$run_dir" "$run_id" "$app" "$app_check" "$exact_local_project_checkpoint" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [runDir, runId, appName, appCheck, exactLocalProjectCheckpointText] = process.argv.slice(2);
const exactLocalProjectCheckpoint = exactLocalProjectCheckpointText === "true";
const armedAt = "2026-09-03T01:00:00.000Z";
const checks = Object.fromEntries(["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"].map((name) => [name, "not-run"]));
for (const name of ["prerequisites", "authentication", "tenant"]) checks[name] = "passed";
checks.app = appCheck;
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
  state: "remote-mutation-cleanup-armed",
  conservative: true,
  exactLocalProjectCheckpoint,
  armedAt,
}, null, 2));
fs.writeFileSync(path.join(runDir, "windows", "windows-remote-cleanup-arm.json"), JSON.stringify({
  schemaVersion: "eai.windows-remote-cleanup-arm.v1",
  appName,
  cleanupRequired: true,
  mutationNotYetProven: true,
  armedAt,
  sanitized: true,
  diagnostic: true,
  productionGate: false,
}, null, 2));
fs.writeFileSync(path.join(runDir, "windows", "vm-result.json"), JSON.stringify({
  status: "failed",
  vm: "windows",
  appName,
  appCreated: true,
  exactLocalProjectCheckpoint,
  cleanupRequested: true,
  checks,
  completedAt: "2026-09-03T01:00:01.000Z",
}, null, 2));
NODE
  printf '%s\n' "$run_dir"
}

run_adapter() {
  local result_mode="$1"
  shift
  EAI_WINDOWS_CLEANUP_PRLCTL_BIN="$fake_prlctl" \
  EAI_WINDOWS_CLEANUP_HIDDEN_PS_COMMAND="$fake_hidden_ps" \
  EAI_WINDOWS_CLEANUP_LOGIN_COMMAND="$fake_login" \
  EAI_FAKE_CLEANUP_RESULT="$result_mode" \
  EAI_FAKE_LOGIN_LOG="$test_root/login.log" \
  EAI_HARNESS_USER_EMAIL="test-user@example.invalid" \
  EAI_HARNESS_TENANT_ID="00000000-0000-4000-8000-000000000000" \
  EAI_HARNESS_TENANT_NAME="Protected Test Tenant" \
    "$ROOT/scripts/run-windows-diagnostic-cleanup.sh" "$@"
}

checkpoint_failure_run="$(make_creation_checkpoint_failure_run 1999999999000-abc000)"
set +e
run_adapter fallback --run-dir "$checkpoint_failure_run" >"$test_root/checkpoint.stdout" 2>"$test_root/checkpoint.stderr"
checkpoint_status=$?
set -e
[[ "$checkpoint_status" == 3 ]] \
  || fail "A failed run with an exact durable app-creation checkpoint was not admitted to diagnostic cleanup."
jq -e '.appName == "test-windows-1999999999000-abc000" and .preDeleteValidation.enrollmentExactMatches == 1' \
  "$checkpoint_failure_run/windows/windows-cleanup-preflight.json" >/dev/null \
  || fail "The failed-run creation checkpoint did not produce an exact cleanup preflight."

published_rc_crash_run="$(make_creation_checkpoint_failure_run 1999999999000-abc008 not-run true)"
set +e
run_adapter fallback --run-dir "$published_rc_crash_run" >"$test_root/published-rc.stdout" 2>"$test_root/published-rc.stderr"
published_rc_status=$?
set -e
[[ "$published_rc_status" == 3 ]] \
  || fail "An old-RC post-init crash with an exact local-project checkpoint was not admitted to diagnostic cleanup."
jq -e '.appName == "test-windows-1999999999000-abc008" and .preDeleteValidation.createdDuringThisRun == true' \
  "$published_rc_crash_run/windows/windows-cleanup-preflight.json" >/dev/null \
  || fail "The old-RC exact-project checkpoint did not reach provenance-verified resource preflight."
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
  | /usr/bin/base64 --decode >"$published_rc_crash_run/windows/manual-cleanup-target-row.png"
cp "$published_rc_crash_run/windows/manual-cleanup-target-row.png" \
  "$published_rc_crash_run/windows/manual-delete-confirmation.png"
node "$ROOT/scripts/write-windows-diagnostic-cleanup-gate.mjs" --run-dir "$published_rc_crash_run" \
  --confirm-zero-services-workflows-setup >/dev/null
jq -e '.appName == "test-windows-1999999999000-abc008" and .servicesBeforeDeletion == 0' \
  "$published_rc_crash_run/windows/manual-cleanup-child-gate.json" >/dev/null \
  || fail "The old-RC failed-run evidence did not pass the guarded manual zero-child gate."

unproven_failure_run="$(make_creation_checkpoint_failure_run 1999999999000-abc009 not-run)"
set +e
run_adapter fallback --run-dir "$unproven_failure_run" >"$test_root/unproven.stdout" 2>"$test_root/unproven.stderr"
unproven_status=$?
set -e
[[ "$unproven_status" == 1 ]] \
  || fail "A failed run without a passed app-creation checkpoint was admitted to diagnostic cleanup."
[[ ! -e "$unproven_failure_run/windows/windows-cleanup-preflight.json" ]] \
  || fail "An unproven failed run wrote a cleanup preflight."

fallback_run="$(make_run 1999999999001-abc001)"
set +e
run_adapter fallback --run-dir "$fallback_run" >"$test_root/fallback.stdout" 2>"$test_root/fallback.stderr"
fallback_status=$?
set -e
[[ "$fallback_status" == 3 ]] || fail "The known V4 failure did not stop for the manual fallback gate."
jq -e '.fallbackEligibleAfterManualZeroChildGate == true and .preDeleteValidation.servicesBeforeDeletion == null' \
  "$fallback_run/windows/windows-cleanup-preflight.json" >/dev/null \
  || fail "The fallback preflight is not fail-closed."
[[ ! -e "$fallback_run/windows/manual-cleanup-receipt.json" ]] \
  || fail "The gate-required path wrote a deletion receipt."
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
  | /usr/bin/base64 --decode >"$fallback_run/windows/manual-cleanup-target-row.png"
cp "$fallback_run/windows/manual-cleanup-target-row.png" "$fallback_run/windows/manual-delete-confirmation.png"
node "$ROOT/scripts/write-windows-diagnostic-cleanup-gate.mjs" --run-dir "$fallback_run" \
  --confirm-zero-services-workflows-setup >/dev/null
jq -e '.schemaVersion == "eai.windows-diagnostic-cleanup-child-gate.v1" and .servicesBeforeDeletion == 0 and .workflowExactMatchesBeforeDeletion == 0 and .setupExactMatchesBeforeDeletion == 0' \
  "$fallback_run/windows/manual-cleanup-child-gate.json" >/dev/null \
  || fail "The explicit manual zero-child gate is invalid."

deleted_run="$(make_run 1999999999002-abc002)"
set +e
run_adapter deleted --run-dir "$deleted_run" >"$test_root/deleted.stdout" 2>"$test_root/deleted.stderr"
deleted_status=$?
set -e
[[ "$deleted_status" == 3 ]] || fail "Two-channel deletion did not stop for portal verification."
jq -e '.deleted == true and .cleanupVerified == false and .portalVerificationRequired == true and .resourceId == "[REDACTED]"' \
  "$deleted_run/windows/manual-cleanup-receipt.json" >/dev/null \
  || fail "The sanitized deletion receipt is invalid."
jq -e '.checks.resourceApiExactMatchesAfter == 0 and .checks.cliExactMatchesAfter == 0 and .checks.portalExactMatchesAfter == null and .cleanupVerified == false' \
  "$deleted_run/windows/manual-cleanup-verification.json" >/dev/null \
  || fail "The two-channel verification receipt is invalid."

set +e
run_adapter verify --run-dir "$deleted_run" --verify-only >"$test_root/verify.stdout" 2>"$test_root/verify.stderr"
verify_status=$?
set -e
[[ "$verify_status" == 3 ]] || fail "Read-only verification did not preserve the portal gate."
jq -e '.cleanupVerified == false and .checks.portalExactMatchesAfter == null' \
  "$deleted_run/windows/manual-cleanup-verification.json" >/dev/null \
  || fail "Read-only verification incorrectly completed cleanup."

portal_attempt2_run="$(make_completed_portal_attempt2_run 1999999999004-abc004)"
attempt1_verify_hash_before="$(shasum -a 256 "$portal_attempt2_run/windows/windows-cleanup-verification-only.json" | awk '{print $1}')"
set +e
run_adapter verify --run-dir "$portal_attempt2_run" --verify-only \
  >"$test_root/portal-attempt2-verify.stdout" 2>"$test_root/portal-attempt2-verify.stderr"
portal_attempt2_status=$?
set -e
[[ "$portal_attempt2_status" == 3 ]] \
  || fail "Verified portal attempt 2 did not stop at the final portal-absence gate."
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-2-verification.v1" and .attempt == 2 and .checks.resourceApiExactMatchesAfter == 0 and .checks.cliExactMatchesAfter == 0 and .checks.portalExactMatchesAfter == null and .verifiedAbsentOnResourceApiAndCli == true and .portalVerificationRequired == true and .cleanupVerified == false and (.attempt2InvocationReceiptSha256 | test("^[a-f0-9]{64}$")) and (.attempt2TargetReceiptSha256 | test("^[a-f0-9]{64}$")) and (.attempt2PreInvokeReceiptSha256 | test("^[a-f0-9]{64}$")) and .attempt1TargetChildEvidence.legacyChildCountsTrustedForAttempt2 == false and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries"' \
  "$portal_attempt2_run/windows/windows-portal-delete-attempt-2-verification.json" >/dev/null \
  || fail "Portal attempt 2 did not write its immutable two-channel absence receipt."
jq -e '.schemaVersion == "eai.windows-diagnostic-cleanup-receipt.v1" and .method == "admin-portal-interactive-delete-attempt-2" and .deleted == true and .resourceId == "[REDACTED]" and .portalDeleteAttempted == true and .portalPermanentDeleteClicked == true and .portalVerificationRequired == true and .cleanupVerified == false and .deletion.attempt == 2 and .deletion.exactInteractiveSession == true and .deletion.sustainedDialogClosure == true and (.deletion.targetReceiptSha256 | test("^[a-f0-9]{64}$")) and (.deletion.preInvokeReceiptSha256 | test("^[a-f0-9]{64}$")) and .attempt1TargetChildEvidence.legacyChildCountsTrustedForAttempt2 == false and .freshAttempt2AuthoritativeChildGateEstablished == true and .freshAttempt2AuthoritativeChildGateSource == "bounded-exact-resource-queries"' \
  "$portal_attempt2_run/windows/manual-cleanup-receipt.json" >/dev/null \
  || fail "Portal attempt 2 did not produce a sanitized portal-method cleanup receipt."
jq -e '.checks.resourceApiExactMatchesAfter == 0 and .checks.cliExactMatchesAfter == 0 and .checks.portalExactMatchesAfter == null and .portalSemanticResult == "manual-portal-verification-required" and .cleanupVerified == false' \
  "$portal_attempt2_run/windows/manual-cleanup-verification.json" >/dev/null \
  || fail "Portal attempt 2 did not enter the existing final portal-verification flow."
jq -e '.files | index("windows-portal-delete-attempt-2-verification.json") != null' \
  "$portal_attempt2_run/windows/windows-cleanup-evidence-index.json" >/dev/null \
  || fail "The cleanup evidence index omitted the immutable attempt-2 verification receipt."
[[ "$(shasum -a 256 "$portal_attempt2_run/windows/windows-cleanup-verification-only.json" | awk '{print $1}')" == "$attempt1_verify_hash_before" ]] \
  || fail "Successful attempt-2 verification overwrote the attempt-1 1/1 verification evidence."

portal_attempt2_screenshot="$portal_attempt2_run/windows/manual-cleanup-verified-absent.png"
cp "$fallback_run/windows/manual-cleanup-target-row.png" "$portal_attempt2_screenshot"
attempt2_tenant_hash="$(printf '%s' '00000000-0000-4000-8000-000000000000' | shasum -a 256 | awk '{print $1}')"
attempt2_screenshot_hash="$(shasum -a 256 "$portal_attempt2_screenshot" | awk '{print $1}')"
attempt2_chain_hash() {
  node - "$portal_attempt2_run/windows" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const directory = process.argv[2];
const names = [
  "manual-cleanup-receipt.json",
  "manual-cleanup-verification.json",
  "windows-portal-cleanup-target.json",
  "windows-portal-delete-attempt-1-still-present.json",
  "windows-portal-delete-attempt-2-target.json",
  "windows-portal-delete-attempt-2-prepared.json",
  "windows-portal-delete-attempt-2-preinvoke.json",
  "windows-portal-delete-attempt-2-invocation.json",
  "windows-portal-delete-attempt-2-verification.json",
];
process.stdout.write(crypto.createHash("sha256").update(Buffer.concat(names.map((name) => fs.readFileSync(path.join(directory, name))))).digest("hex"));
NODE
}
portal_attempt2_chain_hash="$(attempt2_chain_hash)"
EAI_RECEIPT="$portal_attempt2_run/windows/manual-cleanup-receipt.json" \
EAI_VERIFICATION="$portal_attempt2_run/windows/manual-cleanup-verification.json" \
EAI_VM_DIR="$portal_attempt2_run/windows" EAI_TENANT_HASH="$attempt2_tenant_hash" \
EAI_PORTAL_CHAIN_HASH="$portal_attempt2_chain_hash" EAI_SCREENSHOT="$portal_attempt2_screenshot" \
EAI_SCREENSHOT_HASH="$attempt2_screenshot_hash" node "$ROOT/scripts/finalize-windows-portal-evidence.mjs"
jq -e '.cleanupVerified == true and .portalVerified == true' \
  "$portal_attempt2_run/windows/manual-cleanup-receipt.json" >/dev/null \
  || fail "The seven-file attempt-2 chain did not finalize its cleanup receipt."
jq -e '.cleanupVerified == true and .checks.portalExactMatchesAfter == 0 and .portalSemanticResult == "verified-absent"' \
  "$portal_attempt2_run/windows/manual-cleanup-verification.json" >/dev/null \
  || fail "The seven-file attempt-2 chain did not finalize its verification receipt."
attempt2_final_receipt_hash="$(shasum -a 256 "$portal_attempt2_run/windows/manual-cleanup-receipt.json" | awk '{print $1}')"
attempt2_final_verification_hash="$(shasum -a 256 "$portal_attempt2_run/windows/manual-cleanup-verification.json" | awk '{print $1}')"
portal_attempt2_chain_hash="$(attempt2_chain_hash)"
EAI_RECEIPT="$portal_attempt2_run/windows/manual-cleanup-receipt.json" \
EAI_VERIFICATION="$portal_attempt2_run/windows/manual-cleanup-verification.json" \
EAI_VM_DIR="$portal_attempt2_run/windows" EAI_TENANT_HASH="$attempt2_tenant_hash" \
EAI_PORTAL_CHAIN_HASH="$portal_attempt2_chain_hash" EAI_SCREENSHOT="$portal_attempt2_screenshot" \
EAI_SCREENSHOT_HASH="$attempt2_screenshot_hash" node "$ROOT/scripts/finalize-windows-portal-evidence.mjs"
[[ "$(shasum -a 256 "$portal_attempt2_run/windows/manual-cleanup-receipt.json" | awk '{print $1}')" == "$attempt2_final_receipt_hash" \
  && "$(shasum -a 256 "$portal_attempt2_run/windows/manual-cleanup-verification.json" | awk '{print $1}')" == "$attempt2_final_verification_hash" ]] \
  || fail "Attempt-2 portal finalization was not idempotent for the same screenshot and seven-file chain."

semantic_case=0
for semantic_tamper in \
  missing-classification tampered-classification missing-fresh-gate \
  tampered-fresh-source preinvoke-child-proof; do
  semantic_case=$((semantic_case + 1))
  semantic_run_id="$(printf '19999999992%02d-abc2%02d' "$semantic_case" "$semantic_case")"
  semantic_run="$(make_completed_portal_attempt2_run "$semantic_run_id")"
  tamper_attempt2_semantics "$semantic_run" "$semantic_tamper"
  set +e
  run_adapter verify --run-dir "$semantic_run" --verify-only >/dev/null 2>&1
  semantic_status=$?
  set -e
  [[ "$semantic_status" == 1 \
    && ! -e "$semantic_run/windows/manual-cleanup-receipt.json" \
    && ! -e "$semantic_run/windows/windows-portal-delete-attempt-2-verification.json" ]] \
    || fail "Hash-consistent attempt-2 semantic tamper $semantic_tamper reached cleanup evidence."
done

finalizer_tamper_run="$(make_completed_portal_attempt2_run 1999999999206-abc206)"
set +e
run_adapter verify --run-dir "$finalizer_tamper_run" --verify-only >/dev/null 2>&1
finalizer_bridge_status=$?
set -e
[[ "$finalizer_bridge_status" == 3 ]] \
  || fail "The finalizer semantic-negative fixture did not reach the portal-pending state."
node - "$finalizer_tamper_run/windows/manual-cleanup-receipt.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
delete value.attempt1TargetChildEvidence;
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
set +e
run_adapter verify --run-dir "$finalizer_tamper_run" --finalize-portal >/dev/null 2>&1
finalizer_tamper_status=$?
set -e
[[ "$finalizer_tamper_status" == 1 ]] \
  || fail "Portal finalization accepted a cleanup receipt missing its child-history binding."

portal_attempt1_run="$(make_completed_portal_attempt1_run 1999999999006-abc006)"
set +e
run_adapter verify --run-dir "$portal_attempt1_run" --verify-only \
  >"$test_root/portal-attempt1-verify.stdout" 2>"$test_root/portal-attempt1-verify.stderr"
portal_attempt1_status=$?
set -e
[[ "$portal_attempt1_status" == 3 ]] \
  || fail "Verified hardened portal attempt 1 did not enter the final portal-absence gate."
jq -e '.schemaVersion == "eai.windows-portal-delete-attempt-1-verification.v1" and .attempt == 1 and .verifiedAbsentOnResourceApiAndCli == true and (.tenantIdSha256 | test("^[a-f0-9]{64}$")) and (.attempt1InvocationReceiptSha256 | test("^[a-f0-9]{64}$"))' \
  "$portal_attempt1_run/windows/windows-portal-delete-attempt-1-verification.json" >/dev/null \
  || fail "Hardened portal attempt 1 did not write its immutable two-channel absence receipt."
jq -e '.method == "admin-portal-interactive-delete-attempt-1" and .deletion.attempt == 1 and .portalVerificationRequired == true and .cleanupVerified == false' \
  "$portal_attempt1_run/windows/manual-cleanup-receipt.json" >/dev/null \
  || fail "Hardened portal attempt 1 did not bridge into portal finalization."

portal_attempt1_screenshot="$portal_attempt1_run/windows/manual-cleanup-verified-absent.png"
cp "$fallback_run/windows/manual-cleanup-target-row.png" "$portal_attempt1_screenshot"
tenant_hash="$(printf '%s' '00000000-0000-4000-8000-000000000000' | shasum -a 256 | awk '{print $1}')"
screenshot_hash="$(shasum -a 256 "$portal_attempt1_screenshot" | awk '{print $1}')"
attempt1_chain_hash() {
  node - "$portal_attempt1_run/windows" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const directory = process.argv[2];
const names = ["manual-cleanup-receipt.json", "manual-cleanup-verification.json", "windows-portal-cleanup-target.json", "windows-portal-delete-prepared.json", "windows-portal-delete-invocation.json", "windows-portal-delete-attempt-1-verification.json"];
process.stdout.write(crypto.createHash("sha256").update(Buffer.concat(names.map((name) => fs.readFileSync(path.join(directory, name))))).digest("hex"));
NODE
}
portal_chain_hash="$(attempt1_chain_hash)"
EAI_RECEIPT="$portal_attempt1_run/windows/manual-cleanup-receipt.json" \
EAI_VERIFICATION="$portal_attempt1_run/windows/manual-cleanup-verification.json" \
EAI_VM_DIR="$portal_attempt1_run/windows" EAI_TENANT_HASH="$tenant_hash" \
EAI_PORTAL_CHAIN_HASH="$portal_chain_hash" EAI_SCREENSHOT="$portal_attempt1_screenshot" \
EAI_SCREENSHOT_HASH="$screenshot_hash" node "$ROOT/scripts/finalize-windows-portal-evidence.mjs"
final_receipt_hash="$(shasum -a 256 "$portal_attempt1_run/windows/manual-cleanup-receipt.json" | awk '{print $1}')"
final_verification_hash="$(shasum -a 256 "$portal_attempt1_run/windows/manual-cleanup-verification.json" | awk '{print $1}')"
portal_chain_hash="$(attempt1_chain_hash)"
EAI_RECEIPT="$portal_attempt1_run/windows/manual-cleanup-receipt.json" \
EAI_VERIFICATION="$portal_attempt1_run/windows/manual-cleanup-verification.json" \
EAI_VM_DIR="$portal_attempt1_run/windows" EAI_TENANT_HASH="$tenant_hash" \
EAI_PORTAL_CHAIN_HASH="$portal_chain_hash" EAI_SCREENSHOT="$portal_attempt1_screenshot" \
EAI_SCREENSHOT_HASH="$screenshot_hash" node "$ROOT/scripts/finalize-windows-portal-evidence.mjs"
[[ "$(shasum -a 256 "$portal_attempt1_run/windows/manual-cleanup-receipt.json" | awk '{print $1}')" == "$final_receipt_hash" \
  && "$(shasum -a 256 "$portal_attempt1_run/windows/manual-cleanup-verification.json" | awk '{print $1}')" == "$final_verification_hash" ]] \
  || fail "Portal finalization retry was not idempotent for the same screenshot and chain."

portal_attempt2_tampered_run="$(make_completed_portal_attempt2_run 1999999999005-abc005)"
node - "$portal_attempt2_tampered_run/windows/windows-portal-delete-attempt-2-invocation.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.targetReceiptSha256 = "f".repeat(64);
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
set +e
run_adapter verify --run-dir "$portal_attempt2_tampered_run" --verify-only \
  >"$test_root/portal-attempt2-tampered.stdout" 2>"$test_root/portal-attempt2-tampered.stderr"
portal_attempt2_tampered_status=$?
set -e
[[ "$portal_attempt2_tampered_status" == 1 \
  && ! -e "$portal_attempt2_tampered_run/windows/manual-cleanup-receipt.json" \
  && ! -e "$portal_attempt2_tampered_run/windows/windows-portal-delete-attempt-2-verification.json" ]] \
  || fail "A tampered attempt-2 hash chain produced deletion or verification receipts."

proof_case=0
for proof_field in \
  explorerOwnerSidMatched edgeOwnerSidMatched browserWindowHandle browserProcessId \
  browserProcessSessionId topLevelWindowRuntimeIdSha256 dialogFinalRuntimeIdSha256 \
  sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke exactBrowserWindowForegroundAtInvoke \
  scopedInvokePatternInvoked exactDialogRevalidatedImmediatelyBeforeInvoke; do
  proof_case=$((proof_case + 1))
  proof_run_id="$(printf '19999999991%02d-abc%03d' "$proof_case" "$proof_case")"
  proof_run="$(make_completed_portal_attempt2_run "$proof_run_id")"
  node - "$proof_run/windows/windows-portal-delete-attempt-2-invocation.json" "$proof_field" <<'NODE'
const fs = require("node:fs");
const [file, field] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
delete value[field];
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
  set +e
  run_adapter verify --run-dir "$proof_run" --verify-only >/dev/null 2>&1
  proof_status=$?
  set -e
  [[ "$proof_status" == 1 && ! -e "$proof_run/windows/manual-cleanup-receipt.json" ]] \
    || fail "Missing interactive proof $proof_field was accepted by the attempt-2 bridge."
done

uncertain_run="$(make_run 1999999999003-abc003)"
set +e
run_adapter empty --run-dir "$uncertain_run" >"$test_root/empty.stdout" 2>"$test_root/empty.stderr"
empty_status=$?
set -e
[[ "$empty_status" == 1 ]] || fail "Missing guest output did not fail."
jq -e '.mutationState == "uncertain" and .retryMutationAutomatically == false' \
  "$uncertain_run/windows/windows-cleanup-transport-uncertain.json" >/dev/null \
  || fail "Uncertain transport did not block automatic mutation retry."

if rg -F -e '00000000-0000-4000-8000-000000000000' -e 'test-user@example.invalid' -e 'Protected Test Tenant' \
  "$fallback_run/windows" "$deleted_run/windows" "$uncertain_run/windows" >/dev/null; then
  fail "Protected runtime values entered cleanup evidence."
fi

[[ "$(grep -c -- '--portal-only' "$test_root/login.log")" -ge 4 ]] \
  || fail "Fresh portal authentication was not requested for each live check."
[[ "$(grep -c -- '--cli-only' "$test_root/login.log")" -ge 4 ]] \
  || fail "Fresh CLI authentication was not requested for each live check."

printf 'Windows diagnostic cleanup host regression passed.\n'
