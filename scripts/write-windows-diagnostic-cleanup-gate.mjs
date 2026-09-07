#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function fail(message) {
  process.stderr.write(`Windows diagnostic cleanup gate failed: ${message}\n`);
  process.exit(1);
}

process.on("uncaughtException", () => {
  fail("Required cleanup evidence is missing, unreadable, or malformed.");
});

const args = process.argv.slice(2);
let runDirInput = "";
let confirmed = false;
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--run-dir" && index + 1 < args.length && !runDirInput) {
    runDirInput = args[index + 1];
    index += 1;
  } else if (args[index] === "--confirm-zero-services-workflows-setup") {
    confirmed = true;
  } else if (args[index] === "--help" || args[index] === "-h") {
    process.stdout.write(
      "Usage: scripts/write-windows-diagnostic-cleanup-gate.mjs --run-dir <release-e2e-run> --confirm-zero-services-workflows-setup\n",
    );
    process.exit(0);
  } else {
    fail("Unknown or incomplete argument.");
  }
}

if (!runDirInput) fail("--run-dir is required.");
if (!confirmed) {
  fail("The explicit zero-services/workflows/setup confirmation is required; no fallback gate was written.");
}

const artifactRoot = fs.realpathSync(path.join(root, "artifacts", "release-e2e"));
const inputStat = fs.lstatSync(runDirInput);
if (!inputStat.isDirectory() || inputStat.isSymbolicLink()) fail("The run directory must be a real directory, not a symlink.");
const runDir = fs.realpathSync(runDirInput);
if (!runDir.startsWith(`${artifactRoot}${path.sep}`)) fail("The run directory must be under artifacts/release-e2e.");
const runId = path.basename(runDir);
if (!/^[0-9]{13}-[0-9a-f]{6}$/.test(runId)) fail("The run directory name is not a release E2E run ID.");
const windowsDir = path.join(runDir, "windows");
const windowsStat = fs.lstatSync(windowsDir);
if (!windowsStat.isDirectory() || windowsStat.isSymbolicLink()) fail("The Windows evidence directory is unsafe.");

const readSafeJson = (name) => {
  const target = path.join(windowsDir, name);
  const stat = fs.lstatSync(target);
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${name} is missing or unsafe.`);
  try {
    return JSON.parse(fs.readFileSync(target, "utf8"));
  } catch {
    fail(`${name} is unreadable or malformed.`);
  }
};
const fileEvidence = (name, minimumMtime) => {
  const target = path.join(windowsDir, name);
  const stat = fs.lstatSync(target);
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${name} is missing or unsafe.`);
  if (stat.mtimeMs < minimumMtime) fail(`${name} predates the exact cleanup preflight.`);
  const bytes = fs.readFileSync(target);
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a"
    || bytes.subarray(12, 16).toString("ascii") !== "IHDR"
    || bytes.readUInt32BE(16) < 1 || bytes.readUInt32BE(20) < 1) {
    fail(`${name} is not a structurally valid non-empty PNG.`);
  }
  return {
    path: name,
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
    dimensions: `${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}`,
    sanitized: true,
  };
};

const preflight = readSafeJson("windows-cleanup-preflight.json");
const state = readSafeJson("app-state.json");
const result = readSafeJson("vm-result.json");
const appName = `test-windows-${runId}`;
if (preflight.schemaVersion !== "eai.windows-diagnostic-cleanup-preflight.v1"
  || preflight.runId !== runId
  || preflight.platform !== "windows"
  || preflight.appName !== appName
  || preflight.fallbackEligibleAfterManualZeroChildGate !== true
  || preflight.preDeleteValidation?.enrollmentExactMatches !== 1
  || preflight.preDeleteValidation?.createdDuringThisRun !== true
  || preflight.preDeleteValidation?.sourceVerified !== true
  || preflight.preDeleteValidation?.embeddedChildFieldsEmpty !== true
  || !/^[0-9a-f]{64}$/.test(preflight.resourceIdSha256 || "")
  || typeof preflight.displayName !== "string"
  || !preflight.displayName
  || /[\r\n]/.test(preflight.displayName)) {
  fail("The cleanup preflight is not an exact, provenance-verified fallback candidate.");
}
const successfulResult = result.status === "passed";
let failedAfterCreationCheckpoint = false;
if (result.status === "failed"
  && result.vm === "windows"
  && result.appName === appName
  && result.appCreated === true
  && result.cleanupRequested === true
  && state.cleanupRequired === true
  && state.cleanupRequested === true
  && state.state === "remote-mutation-cleanup-armed"
  && state.conservative === true) {
  const arm = readSafeJson("windows-remote-cleanup-arm.json");
  const progressiveReceiptProvesCreation = ["prerequisites", "authentication", "tenant", "app"]
    .every((name) => result.checks?.[name] === "passed");
  const exactLocalProjectProvesCreation = result.exactLocalProjectCheckpoint === true
    && state.exactLocalProjectCheckpoint === true;
  failedAfterCreationCheckpoint = (progressiveReceiptProvesCreation || exactLocalProjectProvesCreation)
    && arm.schemaVersion === "eai.windows-remote-cleanup-arm.v1"
    && arm.appName === appName
    && arm.cleanupRequired === true
    && arm.mutationNotYetProven === true
    && arm.sanitized === true
    && arm.diagnostic === true
    && arm.productionGate === false
    && arm.armedAt === state.armedAt
    && Number.isFinite(Date.parse(arm.armedAt))
    && Number.isFinite(Date.parse(result.completedAt))
    && Date.parse(arm.armedAt) <= Date.parse(result.completedAt);
}
if (state.appName !== appName || state.appCreated !== true
  || result.vm !== "windows" || result.appName !== appName || result.appCreated !== true
  || (!successfulResult && !failedAfterCreationCheckpoint)) {
  fail("The run receipts do not agree on one created Windows app.");
}

const minimumMtime = Date.parse(preflight.recordedAt);
if (!Number.isFinite(minimumMtime)) fail("The cleanup preflight timestamp is invalid.");
const targetRow = fileEvidence("manual-cleanup-target-row.png", minimumMtime);
const confirmation = fileEvidence("manual-delete-confirmation.png", minimumMtime);
const gatePath = path.join(windowsDir, "manual-cleanup-child-gate.json");
if (fs.existsSync(gatePath)) fail("A fallback gate already exists; refusing to overwrite evidence.");

const gate = {
  schemaVersion: "eai.windows-diagnostic-cleanup-child-gate.v1",
  runId,
  platform: "windows",
  appName,
  displayName: preflight.displayName,
  resourceIdSha256: preflight.resourceIdSha256,
  enrollmentExactMatches: 1,
  createdDuringThisRun: true,
  exactDisplayNameVerified: true,
  typedConfirmation: true,
  servicesBeforeDeletion: 0,
  workflowExactMatchesBeforeDeletion: 0,
  setupExactMatchesBeforeDeletion: 0,
  zeroChildAssertionSource: "manual-approved-admin-interface-and-exact-resource-queries",
  targetRowScreenshot: {
    ...targetRow,
    showsExactDisplayName: true,
    showsNoServices: true,
  },
  confirmationScreenshot: {
    ...confirmation,
    showsExactTypedConfirmation: true,
  },
  sanitized: true,
  diagnostic: true,
  productionGate: false,
  recordedAt: new Date().toISOString(),
};
fs.writeFileSync(gatePath, `${JSON.stringify(gate, null, 2)}\n`, { mode: 0o600, flag: "wx" });
process.stdout.write(`Wrote ${path.relative(root, gatePath)}. Re-run the Windows diagnostic cleanup adapter to evaluate the guarded fallback.\n`);
