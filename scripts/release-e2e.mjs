#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const canonicalV4Adapter = fs.realpathSync(path.join(root, "scripts", "run-v4-app-deprovision.sh"));
const canonicalVmAdapters = Object.fromEntries(["macos", "windows", "ubuntu"].map((vm) => [
  vm,
  fs.realpathSync(path.join(root, "scripts", `run-${vm}-guest-test.sh`)),
]));
const productionRepo = "eai-support/eai-installer";
const productionVms = ["macos", "windows", "ubuntu"];
const productionAssets = {
  macos: "eai-setup-macos-arm64.dmg",
  windows: "eai-setup-windows-arm64.exe",
  ubuntu: "eai-setup-ubuntu-arm64.deb",
};
const supportedVms = new Set(["macos", "windows", "ubuntu"]);
const defaultPublicApiOrigin = "https://api.au.myenterprise.ai/public";
const manifest = JSON.parse(fs.readFileSync(path.join(root, "installer-manifest.json"), "utf8"));
const minimumEaiVersion = manifest.prerequisites?.find((entry) => entry.id === "eai-cli")?.minimumVersion;
if (!/^\d+\.\d+\.\d+$/.test(minimumEaiVersion || "")) {
  throw new Error("installer-manifest.json does not declare a valid EAI CLI minimum version");
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help") {
      result.help = true;
      continue;
    }
    if (value === "--dry-run") {
      result.dryRun = true;
      continue;
    }
    if (value === "--preflight") {
      result.preflight = true;
      continue;
    }
    if (value === "--diagnostic") {
      result.diagnostic = true;
      continue;
    }
    if (value.startsWith("--")) {
      const key = value.slice(2);
      const next = argv[index + 1];
      if (!next || next.startsWith("--")) throw new Error(`Missing value for ${value}`);
      result[key] = next;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${value}`);
  }
  return result;
}

function usage() {
  return `Usage: node scripts/release-e2e.mjs --version <x.y.z> [options]\n\n` +
    `Options:\n` +
    `  --repo <owner/repo>       GitHub installer repository\n` +
    `  --tag <tag>               Published release tag (default: v<version>)\n` +
    `  --output <directory>      Evidence directory\n` +
    `  --driver command          Real VM adapter (default: EAI_VM_DRIVER or command)\n` +
    `  --deprovision api|mock    Real V4 cleanup, or diagnostic-only mock cleanup\n` +
    `  --vms <csv>               VM ids: macos,windows,ubuntu\n` +
    `  --preflight               Validate live credentials, VM drivers, and cleanup before release\n` +
    `  --diagnostic              Required with --deprovision mock; never valid for publish\n` +
    `  --dry-run                 Print the planned actions without changing a tenant\n`;
}

function commandExists(command) {
  return process.env.PATH.split(path.delimiter).some((directory) => fs.existsSync(path.join(directory, command)));
}

function redact(value) {
  let output = String(value ?? "");
  for (const key of ["EAI_HARNESS_PASSWORD", "EAI_HARNESS_CLIENT_SECRET", "EAI_SERVICE_CLIENT_SECRET", "EAI_DEPROVISION_TOKEN", "EAI_APP_DEPROVISION_TOKEN", "EAI_HARNESS_TENANT_ID", "EAI_HARNESS_TENANT_NAME", "EAI_HARNESS_USER_EMAIL", "EAI_HARNESS_PUBLIC_API_URL"]) {
    if (process.env[key]) output = output.split(process.env[key]).join("[REDACTED]");
  }
  return output;
}

const signalExitCodes = { SIGINT: 130, SIGTERM: 143 };
let activeChild = null;
let activeVmChild = null;
let activeSignalChild = null;
let interruption = null;

function exactChildIsRunning(record) {
  return record !== null
    && activeChild === record
    && record.settled !== true
    && record.exited !== true
    && record.child.exitCode === null
    && record.child.signalCode === null;
}

function signalExactChild(record, signal) {
  if (!exactChildIsRunning(record)) return false;
  try {
    return record.child.kill(signal);
  } catch (error) {
    if (interruption) interruption.forwardError = redact(error.message);
    return false;
  }
}

function forceInterruptedChild(reason) {
  if (!interruption?.target || interruption.forced === true) return;
  interruption.forceAttempted = true;
  interruption.forceReason = reason;
  interruption.forced = signalExactChild(interruption.target, "SIGKILL");
}

function handleSignal(signal) {
  if (!interruption) {
    const target = activeSignalChild;
    interruption = {
      signal,
      exitCode: signalExitCodes[signal],
      receivedAt: new Date().toISOString(),
      signalCount: 1,
      target,
      forwarded: false,
      forceAttempted: false,
      forced: false,
      forceReason: null,
    };
    interruption.forwarded = signalExactChild(target, signal);
    process.exitCode = interruption.exitCode;
    console.error(target
      ? `release-e2e received ${signal}; waiting for the active ${target.role} child before cleanup`
      : `release-e2e received ${signal}; protected cleanup will finish and no new VM will be started`);
    return;
  }

  interruption.signalCount += 1;
  process.exitCode = interruption.exitCode;
  console.error(`release-e2e received another signal; forcing only the original interruptible child if it is still running`);
  forceInterruptedChild("second-signal");
}

function throwIfInterrupted() {
  if (!interruption) return;
  const error = new Error(`Interrupted by ${interruption.signal}`);
  error.code = "EAI_RELEASE_INTERRUPTED";
  throw error;
}

function interruptionEvidence() {
  if (!interruption) return null;
  const target = interruption.target;
  return {
    signal: interruption.signal,
    exitCode: interruption.exitCode,
    receivedAt: interruption.receivedAt,
    signalCount: interruption.signalCount,
    targetRole: target?.role || null,
    targetProcessId: target?.child.pid || null,
    forwardedToActiveChild: interruption.forwarded,
    forceAttempted: interruption.forceAttempted,
    forced: interruption.forced,
    forceReason: interruption.forceReason,
    terminationObserved: target ? target.exited === true || target.settled === true : true,
    terminationSignal: target?.exitSignal || null,
    childExitCode: target?.exitCode ?? null,
    ...(interruption.forwardError ? { forwardError: interruption.forwardError } : {}),
  };
}

function run(command, args, options = {}) {
  if (!options.allowAfterInterruption) throwIfInterrupted();
  if (options.vmChild && activeVmChild !== null) throw new Error("Refusing to start a second VM adapter while one is active");
  if (activeChild !== null) throw new Error("Refusing to start a second child while another release operation is active");
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(command, args, {
        cwd: options.cwd || root,
        env: options.env || process.env,
        shell: Boolean(options.shell),
        // A terminal-generated signal targets the controller's foreground
        // process group. Isolate children so only the captured ChildProcess
        // handle receives forwarded signals and protected cleanup is not hit.
        detached: process.platform !== "win32",
      });
    } catch (error) {
      resolve({ code: 1, stdout: "", stderr: error.message });
      return;
    }
    let stdout = "";
    let stderr = "";
    const record = {
      child,
      role: options.role || "release-operation",
      settled: false,
      exited: false,
      exitCode: null,
      exitSignal: null,
    };
    activeChild = record;
    if (options.vmChild) activeVmChild = record;
    if (options.signalEligible) activeSignalChild = record;

    const settle = (result) => {
      if (record.settled) return;
      record.settled = true;
      if (activeChild === record) activeChild = null;
      if (activeVmChild === record) activeVmChild = null;
      if (activeSignalChild === record) activeSignalChild = null;
      resolve(result);
    };
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.stderr?.on("data", (chunk) => { stderr += chunk; });
    child.once("error", (error) => {
      record.exited = true;
      settle({ code: 1, stdout, stderr: `${stderr}${error.message}` });
    });
    child.once("exit", (code, signal) => {
      record.exited = true;
      record.exitCode = code;
      record.exitSignal = signal;
      if (interruption?.target === record) {
        child.stdout?.destroy();
        child.stderr?.destroy();
        settle({ code: code ?? 1, signal, stdout, stderr });
      }
    });
    child.once("close", (code, signal) => {
      record.exited = true;
      record.exitCode = code;
      record.exitSignal = signal;
      settle({ code: code ?? 1, signal, stdout, stderr });
    });
  });
}

function redactJsonValue(value) {
  if (typeof value === "string") return redact(value);
  if (Array.isArray(value)) return value.map(redactJsonValue);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [redact(key), redactJsonValue(item)]));
  }
  return value;
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(redactJsonValue(value), null, 2)}\n`);
}

function ensurePrivateDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`Evidence path is not a real directory: ${directory}`);
  fs.chmodSync(directory, 0o700);
}

function resolveExactExecutable(value, label) {
  if (typeof value !== "string" || !path.isAbsolute(value)) {
    throw new Error(`${label} must be one absolute executable path; put arguments and multi-step logic in the wrapper`);
  }
  let stat;
  let resolved;
  try {
    stat = fs.lstatSync(value);
    resolved = fs.realpathSync(value);
    fs.accessSync(value, fs.constants.X_OK);
  } catch {
    throw new Error(`${label} is not an executable file`);
  }
  if (!stat.isFile() || stat.isSymbolicLink() || resolved !== path.normalize(value)) {
    throw new Error(`${label} must be a canonical regular non-symlink executable file`);
  }
  return resolved;
}

function normalizePublicApiOrigin(value) {
  const normalized = String(value || defaultPublicApiOrigin).replace(/\/$/, "");
  if (!/^https:\/\/api\.(au|ca|eu)\.myenterprise\.ai\/public$/.test(normalized)) {
    throw new Error("EAI_HARNESS_PUBLIC_API_URL must be an approved regional HTTPS PublicAPI origin");
  }
  return normalized;
}

function sha256Text(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function semverAtLeast(actual, minimum) {
  if (!/^\d+\.\d+\.\d+$/.test(actual || "") || !/^\d+\.\d+\.\d+$/.test(minimum || "")) return false;
  const actualParts = actual.split(".").map(Number);
  const minimumParts = minimum.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (actualParts[index] > minimumParts[index]) return true;
    if (actualParts[index] < minimumParts[index]) return false;
  }
  return true;
}

function assetFor(vm) {
  const overrides = {
    macos: process.env.EAI_RELEASE_MACOS_ASSET,
    windows: process.env.EAI_RELEASE_WINDOWS_ASSET,
    ubuntu: process.env.EAI_RELEASE_UBUNTU_ASSET,
  };
  const asset = overrides[vm] || productionAssets[vm];
  if (typeof asset !== "string" || path.basename(asset) !== asset || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(asset)) {
    throw new Error(`Release asset override for ${vm} must be one safe filename`);
  }
  return asset;
}

function appNameFor(vm, runId) {
  return `test-${vm}-${runId}`.toLowerCase().replace(/[^a-z0-9-]/g, "-");
}

async function downloadAsset({ repo, tag, asset, destination }) {
  fs.mkdirSync(destination, { recursive: true });
  const target = path.join(destination, asset);
  if (!commandExists("gh")) throw new Error("gh is required to download the published release asset");
  const result = await run("gh", ["release", "download", tag, "--repo", repo, "--pattern", asset, "--dir", destination, "--clobber"], { role: "release-download", signalEligible: true });
  if (result.code !== 0 || !fs.existsSync(target)) {
    throw new Error(`GitHub release download failed for ${asset}: ${redact(result.stderr || result.stdout)}`);
  }
  return { path: target, source: "github-release" };
}

async function validateAsset(assetPath, vm) {
  const stat = fs.statSync(assetPath);
  if (stat.size === 0) throw new Error(`Downloaded asset is empty: ${path.basename(assetPath)}`);
  const extension = path.extname(assetPath).toLowerCase();
  if (vm === "macos" && extension === ".dmg" && commandExists("hdiutil")) {
    const result = await run("hdiutil", ["imageinfo", assetPath], { role: "asset-validation", signalEligible: true });
    if (result.code !== 0) throw new Error(`DMG validation failed: ${redact(result.stderr)}`);
  }
  if (vm === "ubuntu" && extension === ".deb" && commandExists("dpkg-deb")) {
    const result = await run("dpkg-deb", ["--info", assetPath], { role: "asset-validation", signalEligible: true });
    if (result.code !== 0) throw new Error(`Debian package validation failed: ${redact(result.stderr)}`);
  }
  return { bytes: stat.size, sha256: crypto.createHash("sha256").update(fs.readFileSync(assetPath)).digest("hex") };
}

async function runVm({ driver, command, vm, asset, output, release, appName, runId, tenantName, apiOrigin }) {
  const vmDir = path.join(output, vm);
  ensurePrivateDirectory(vmDir);
  const resultPath = path.join(vmDir, "vm-result.json");
  const env = {
    ...process.env,
    EAI_RELEASE_VERSION: release.version,
    EAI_RELEASE_TAG: release.tag,
    EAI_RELEASE_REPO: release.repo,
    EAI_VM_ID: vm,
    EAI_VM_ASSET: asset.path,
    EAI_VM_DOWNLOAD_URL: `https://github.com/${release.repo}/releases/download/${release.tag}/${path.basename(asset.path)}`,
    EAI_VM_PROJECT_NAME: appName,
    EAI_VM_RESULT_FILE: resultPath,
    EAI_VM_APP_STATE_FILE: path.join(vmDir, "app-state.json"),
    EAI_HARNESS_TENANT_NAME: tenantName,
    EAI_HARNESS_PUBLIC_API_URL: apiOrigin,
  };

  if (driver !== "command") throw new Error(`Unsupported VM driver: ${driver}`);

  const result = await run(command, [], { env, role: `vm:${vm}`, vmChild: true, signalEligible: true });
  fs.writeFileSync(path.join(vmDir, "vm-output.log"), `${redact(result.stdout)}\n${redact(result.stderr)}`);
  if (result.code !== 0) throw new Error(`${vm} VM test command failed with exit code ${result.code}`);
  if (!fs.existsSync(resultPath)) throw new Error(`${vm} VM test did not write ${resultPath}`);
  const payload = JSON.parse(fs.readFileSync(resultPath, "utf8"));
  if (payload.status !== "passed") throw new Error(`${vm} VM result was not passed`);
  const requiredChecks = ["download", "installer", "prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
  const checks = payload.checks && typeof payload.checks === "object" ? payload.checks : {};
  const missingChecks = requiredChecks.filter((check) => checks[check] !== "passed");
  if (missingChecks.length > 0) {
    throw new Error(`${vm} VM did not provide passing real checks: ${missingChecks.join(", ")}`);
  }
  if (payload.cleanupRequested !== true) {
    throw new Error(`${vm} VM did not confirm that cleanup was requested in the guest`);
  }
  if (!fs.existsSync(env.EAI_VM_APP_STATE_FILE)) {
    throw new Error(`${vm} VM did not write the app-state receipt required for cleanup`);
  }
  const appState = JSON.parse(fs.readFileSync(env.EAI_VM_APP_STATE_FILE, "utf8"));
  if (appState.appName !== appName || appState.appCreated !== true) {
    throw new Error(`${vm} VM app-state receipt does not prove creation of the expected app`);
  }
  return payload;
}

function hasDeletionEvidence(value) {
  return value !== null
    && typeof value === "object"
    && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype
    && Object.keys(value).length > 0;
}

function atomicallyWritePrivateJson(filePath, value) {
  const parent = path.dirname(filePath);
  const parentStat = fs.lstatSync(parent);
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) {
    throw new Error("Cleanup receipt parent is not a real directory");
  }
  const temporary = path.join(parent, `.cleanup-receipt.sanitized-${process.pid}-${crypto.randomBytes(8).toString("hex")}`);
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(redactJsonValue(value), null, 2)}\n`);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, filePath);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}

function readAndSanitizeCleanupReceipt(receiptPath) {
  let descriptor;
  let content;
  try {
    descriptor = fs.openSync(receiptPath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) throw new Error("V4 app deprovision command did not write a regular cleanup receipt");
    content = fs.readFileSync(descriptor, "utf8");
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }

  let receipt;
  try {
    receipt = JSON.parse(content);
  } catch {
    atomicallyWritePrivateJson(receiptPath, {
      schemaVersion: "eai.release-e2e.cleanup-receipt.v1",
      status: "invalid",
      cleanupVerified: false,
      note: "The cleanup adapter wrote invalid JSON; unsafe contents were discarded.",
    });
    throw new Error("V4 app deprovision command wrote an invalid cleanup receipt");
  }
  const sanitized = redactJsonValue(receipt);
  atomicallyWritePrivateJson(receiptPath, sanitized);
  return sanitized;
}

async function cleanup({ mode, diagnostic, command, appName, tenantName, runId, output, appCreated, apiOrigin }) {
  if (mode === "mock") {
    if (!diagnostic) throw new Error("Mock cleanup is diagnostic-only; pass --diagnostic explicitly");
    const receipt = {
      status: "not-verified",
      source: "diagnostic-mock",
      operationId: `diagnostic-${runId}`,
      appName,
      appCreated,
      confirmation: appName,
      deletedRecords: null,
      deletedResources: null,
      cleanupVerified: false,
      simulated: true,
      note: "No tenant records or resources were deleted. Run the real V4 cleanup gate before treating this release as safe to publish.",
    };
    writeJson(path.join(output, "cleanup-receipt.json"), receipt);
    return receipt;
  }
  if (mode !== "api") throw new Error(`Unsupported cleanup mode: ${mode}`);
  const receiptPath = path.join(output, "cleanup-receipt.json");
  const env = {
    ...process.env,
    EAI_DEPROVISION_TENANT_ID: process.env.EAI_HARNESS_TENANT_ID || "",
    EAI_DEPROVISION_TENANT_NAME: tenantName,
    EAI_DEPROVISION_APP_NAME: appName,
    EAI_DEPROVISION_CONFIRM: appName,
    EAI_DEPROVISION_APP_CREATED: appCreated ? "1" : "0",
    EAI_DEPROVISION_RUN_ID: runId,
    EAI_DEPROVISION_RECEIPT_FILE: receiptPath,
    EAI_DEPROVISION_API_ORIGIN: apiOrigin,
  };
  const result = await run(command, [], { env, role: "app-cleanup", allowAfterInterruption: true });
  let receipt = null;
  let receiptError = null;
  if (fs.existsSync(receiptPath)) {
    try {
      receipt = readAndSanitizeCleanupReceipt(receiptPath);
    } catch (error) {
      receiptError = error;
    }
  }
  if (result.code !== 0) throw new Error(`V4 app deprovision command failed with exit code ${result.code}`);
  if (receiptError) throw receiptError;
  if (!receipt) throw new Error("V4 app deprovision command did not write a cleanup receipt");
  if (receipt.schemaVersion !== "eai.release-e2e.cleanup-receipt.v1") throw new Error("V4 app deprovision receipt has the wrong schema version");
  if (receipt.status !== "verified") throw new Error("V4 app deprovision receipt is not verified");
  if (receipt.cleanupVerified !== true) throw new Error("V4 app deprovision receipt did not verify cleanup");
  if (receipt.source !== "public-api-v4") throw new Error("V4 app deprovision receipt does not identify the PublicAPI V4 source");
  if (typeof receipt.operationId !== "string" || receipt.operationId.length < 1) throw new Error("V4 app deprovision receipt is missing its operation id");
  if (!/^[a-f0-9]{64}$/.test(receipt.planHash || "")) throw new Error("V4 app deprovision receipt is missing its ownership-plan hash");
  if (receipt.ownershipManifestHash !== receipt.planHash) throw new Error("V4 app deprovision receipt is not bound to its ownership manifest");
  if (receipt.tenantMatch !== "verified" || receipt.tenantIdSha256 !== sha256Text(process.env.EAI_HARNESS_TENANT_ID || "")) {
    throw new Error("V4 app deprovision receipt is not bound to the exact protected tenant");
  }
  if (receipt.apiOriginSha256 !== sha256Text(apiOrigin)) throw new Error("V4 app deprovision receipt is not bound to the exact PublicAPI origin");
  if (!semverAtLeast(receipt.eaiVersion, minimumEaiVersion)) throw new Error("V4 app deprovision receipt used an unsupported EAI CLI version");
  if (!hasDeletionEvidence(receipt.deletedRecords) || !hasDeletionEvidence(receipt.deletedResources)) {
    throw new Error("V4 app deprovision receipt is missing non-empty deletion evidence");
  }
  if (receipt.deletedRecords.exactAppEnrollmentMatchesAfter !== 0
    || receipt.deletedRecords.exactFilteredTotalAfter !== 0
    || receipt.deletedResources.serverReceiptSchemaVersion !== "eai.app-deletion-receipt.v1"
    || !Number.isSafeInteger(receipt.deletedResources.resourceApiDeletedCount)
    || receipt.deletedResources.resourceApiDeletedCount < 1
    || receipt.deletedResources.resourceApiStep !== "verified"
    || !Array.isArray(receipt.deletedResources.retainedSharedObjectTypes)
    || receipt.deletedResources.retainedSharedObjectTypes.some((value) => typeof value !== "string" || value.length < 1)) {
    throw new Error("V4 app deprovision receipt has incomplete exact deletion evidence");
  }
  const requiredAbsenceTypes = [
    "tenant-vertical-enrollment",
    "vertical-service-activation",
    "vertical-product-config",
  ];
  if (!receipt.absenceCheck
    || Object.getPrototypeOf(receipt.absenceCheck) !== Object.prototype
    || receipt.absenceCheck.method !== "v4-filtered-manifest-owned-resource-queries"
    || JSON.stringify(receipt.absenceCheck.resourceTypes) !== JSON.stringify(requiredAbsenceTypes)
    || receipt.absenceCheck.filterField !== "verticalKey"
    || receipt.absenceCheck.allManifestOwnedResourceTypesAbsent !== true
    || !receipt.absenceCheck.exactMatchesByType
    || Object.getPrototypeOf(receipt.absenceCheck.exactMatchesByType) !== Object.prototype
    || JSON.stringify(Object.keys(receipt.absenceCheck.exactMatchesByType)) !== JSON.stringify(requiredAbsenceTypes)
    || requiredAbsenceTypes.some((resourceType) => receipt.absenceCheck.exactMatchesByType[resourceType] !== 0)) {
    throw new Error("V4 app deprovision receipt has incomplete independent absence evidence");
  }
  if (receipt.appName !== appName) throw new Error("V4 app deprovision receipt names a different app");
  if (receipt.appCreated !== appCreated) throw new Error("V4 app deprovision receipt does not match whether the guest created the app");
  if (receipt.confirmation !== appName && receipt.confirmedAppName !== appName) throw new Error("V4 app deprovision receipt does not prove typed app-name confirmation");
  return receipt;
}

function validateLiveConfiguration({ driver, deprovision, diagnostic, vms, repo }) {
  if (driver !== "command") throw new Error("The release gate only supports real command-driven VMs; mock drivers are removed.");
  if (deprovision !== "api" && deprovision !== "mock") throw new Error(`Unsupported cleanup mode: ${deprovision}`);
  if (deprovision === "mock" && !diagnostic) throw new Error("Mock cleanup is diagnostic-only; pass --diagnostic explicitly.");
  if (diagnostic && deprovision !== "mock") throw new Error("--diagnostic is only valid with --deprovision mock.");
  if (diagnostic && vms.length !== 1) {
    throw new Error("Diagnostic mock cleanup permits exactly one VM per invocation. Manually remove and verify that test app before starting the next VM.");
  }
  if (!process.env.EAI_HARNESS_TENANT_ID) throw new Error("EAI_HARNESS_TENANT_ID is required; the live gate refuses to guess a tenant.");
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(process.env.EAI_HARNESS_TENANT_ID)) throw new Error("EAI_HARNESS_TENANT_ID must be a tenant UUID.");
  if (!process.env.EAI_HARNESS_TENANT_NAME || process.env.EAI_HARNESS_TENANT_NAME.length > 256) {
    throw new Error("EAI_HARNESS_TENANT_NAME is required; the live gate refuses to guess a tenant name.");
  }
  if (!process.env.EAI_HARNESS_USER_EMAIL) throw new Error("EAI_HARNESS_USER_EMAIL is required; the live gate refuses to guess a test user.");
  if (/\s/.test(process.env.EAI_HARNESS_USER_EMAIL)) throw new Error("EAI_HARNESS_USER_EMAIL must not contain whitespace.");
  if (vms.length === 0 || vms.some((vm) => !supportedVms.has(vm)) || new Set(vms).size !== vms.length) {
    throw new Error("--vms must contain each requested value from macos,windows,ubuntu exactly once");
  }
  const protectedProduction = repo === productionRepo && !diagnostic;
  if (protectedProduction && vms.join(",") !== productionVms.join(",")) {
    throw new Error("Production validation requires macos,windows,ubuntu in that exact sequence");
  }
  if (protectedProduction) {
    for (const vm of productionVms) {
      if (assetFor(vm) !== productionAssets[vm]) {
        throw new Error(`Production validation requires the exact ARM64 ${vm} release asset`);
      }
    }
  }
  const apiOrigin = normalizePublicApiOrigin(process.env.EAI_HARNESS_PUBLIC_API_URL);
  const missing = vms.filter((vm) => !process.env[`EAI_VM_${vm.toUpperCase()}_COMMAND`]);
  if (missing.length > 0) throw new Error(`Real VM commands are missing for: ${missing.join(", ")}. Set EAI_VM_<VM>_COMMAND for every guest.`);
  const vmCommands = Object.fromEntries(vms.map((vm) => {
    const key = `EAI_VM_${vm.toUpperCase()}_COMMAND`;
    return [vm, resolveExactExecutable(process.env[key], key)];
  }));
  if (protectedProduction) {
    for (const vm of productionVms) {
      if (vmCommands[vm] !== canonicalVmAdapters[vm]) {
        throw new Error(`Production validation requires the repository ${vm} VM adapter`);
      }
    }
  }
  let deprovisionCommand = null;
  if (deprovision === "api") {
    const configured = process.env.EAI_APP_DEPROVISION_COMMAND || canonicalV4Adapter;
    deprovisionCommand = resolveExactExecutable(configured, "EAI_APP_DEPROVISION_COMMAND");
    if (repo !== "fixture/repo" && deprovisionCommand !== canonicalV4Adapter) {
      throw new Error("Production cleanup must use the repository's canonical V4 adapter");
    }
  }
  return { apiOrigin, vmCommands, deprovisionCommand };
}

function parseReadinessJson(stdout, description) {
  let value;
  try {
    value = JSON.parse(stdout);
  } catch {
    throw new Error(`${description} did not return its readiness JSON contract`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value) || value.status !== "ready" || value.mutationAttempted !== false) {
    throw new Error(`${description} did not prove mutation-free readiness`);
  }
  return value;
}

async function runLivePreflight({ repo, vmCommands, deprovisionCommand, deprovision, tenantName, apiOrigin }) {
  for (const [vm, command] of Object.entries(vmCommands)) {
    const result = await run(command, ["--preflight"], { role: `vm-preflight:${vm}`, signalEligible: true });
    if (result.code !== 0) throw new Error(`${vm} VM adapter read-only preflight failed: ${redact(result.stderr || result.stdout)}`);
    if (repo !== "fixture/repo") {
      const payload = parseReadinessJson(result.stdout, `${vm} VM adapter`);
      if (payload.schemaVersion !== "eai.vm-adapter-preflight.v1" || payload.platform !== vm || payload.architecture !== "arm64") {
        throw new Error(`${vm} VM adapter returned a mismatched readiness contract`);
      }
    }
  }
  if (deprovision === "api") {
    const env = {
      ...process.env,
      EAI_DEPROVISION_TENANT_ID: process.env.EAI_HARNESS_TENANT_ID || "",
      EAI_DEPROVISION_TENANT_NAME: tenantName,
      EAI_DEPROVISION_API_ORIGIN: apiOrigin,
    };
    const result = await run(deprovisionCommand, ["--preflight"], { env, role: "app-cleanup-preflight", signalEligible: true });
    if (result.code !== 0) throw new Error(`V4 cleanup adapter read-only preflight failed: ${redact(result.stderr || result.stdout)}`);
    if (repo !== "fixture/repo") {
      const payload = parseReadinessJson(result.stdout, "V4 cleanup adapter");
      if (payload.schemaVersion !== "eai.v4-deprovision-preflight.v1"
        || payload.mutationAttempted !== false
        || payload.tenantAuthorization !== "verified-read-only"
        || payload.apiOriginSha256 !== sha256Text(apiOrigin)
        || !semverAtLeast(payload.eaiVersion, minimumEaiVersion)) {
        throw new Error("V4 cleanup adapter returned an incomplete readiness contract");
      }
    }
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  if (!/^\d+\.\d+\.\d+$/.test(options.version || "")) throw new Error("--version must be MAJOR.MINOR.PATCH");
  const repo = options.repo || process.env.EAI_INSTALLER_REPO || "eai-support/eai-installer";
  const tag = options.tag || `v${options.version}`;
  const runId = `${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
  const output = path.resolve(options.output || path.join(root, "artifacts", "release-e2e", options.version, runId));
  const driver = options.driver || process.env.EAI_VM_DRIVER || "command";
  const deprovision = options.deprovision || process.env.EAI_DEPROVISION_MODE || "api";
  const diagnostic = options.diagnostic === true;
  const vms = String(options.vms || process.env.EAI_RELEASE_VMS || "macos,windows,ubuntu").split(",").map((value) => value.trim()).filter(Boolean);
  const tenantName = process.env.EAI_HARNESS_TENANT_NAME || "";
  const release = { version: options.version, tag, repo };
  ensurePrivateDirectory(output);
  const report = { release, runId, tenantName: "[REDACTED]", driver, deprovision, diagnostic, vms, status: "running", assets: [], machines: [] };
  writeJson(path.join(output, "release-e2e.json"), report);

  try {
    throwIfInterrupted();
    if (options.dryRun) {
      report.status = "dry_run";
      report.completedAt = new Date().toISOString();
      writeJson(path.join(output, "release-e2e.json"), report);
      console.log(JSON.stringify({ ...report, planned: vms.map((vm) => ({ vm, asset: assetFor(vm), appName: appNameFor(vm, runId) })) }, null, 2));
      return;
    }
    const liveConfiguration = validateLiveConfiguration({ driver, deprovision, diagnostic, vms, repo });
    throwIfInterrupted();
    if (options.preflight) {
      await runLivePreflight({
        repo,
        ...liveConfiguration,
        deprovision,
        tenantName,
      });
      throwIfInterrupted();
      report.status = "ready";
      report.completedAt = new Date().toISOString();
      writeJson(path.join(output, "release-e2e.json"), report);
      console.log(JSON.stringify({ status: "ready", release, driver, deprovision, diagnostic, vms, tenantName: "[REDACTED]" }, null, 2));
      return;
    }

    const downloadDir = path.join(output, "downloads");
    const assetPaths = new Map();
    for (const vm of vms) {
      throwIfInterrupted();
      const assetName = assetFor(vm);
      if (!assetName) throw new Error(`No release asset configured for VM ${vm}`);
      const downloaded = await downloadAsset({ repo, tag, asset: assetName, destination: downloadDir });
      throwIfInterrupted();
      const validation = await validateAsset(downloaded.path, vm);
      throwIfInterrupted();
      assetPaths.set(vm, downloaded.path);
      report.assets.push({ vm, asset: assetName, source: downloaded.source, ...validation });
    }
    writeJson(path.join(output, "release-e2e.json"), report);

    let failed = false;
    for (const vm of vms) {
      throwIfInterrupted();
      const appName = appNameFor(vm, runId);
      const machine = { vm, appName, status: "running" };
      report.machines.push(machine);
      writeJson(path.join(output, "release-e2e.json"), report);
      try {
        const asset = { ...report.assets.find((candidate) => candidate.vm === vm), path: assetPaths.get(vm) };
        machine.result = await runVm({
          driver,
          command: liveConfiguration.vmCommands[vm],
          vm,
          asset,
          output,
          release,
          appName,
          runId,
          tenantName,
          apiOrigin: liveConfiguration.apiOrigin,
        });
        throwIfInterrupted();
        machine.status = "passed";
      } catch (error) {
        machine.status = interruption ? "interrupted" : "failed";
        machine.error = interruption ? `Interrupted by ${interruption.signal}` : redact(error.message);
        failed = true;
      } finally {
        const appStatePath = path.join(output, vm, "app-state.json");
        let appState = null;
        let appStateError = null;
        try {
          if (!fs.existsSync(appStatePath)) throw new Error("the VM app-state checkpoint is missing");
          const stateStat = fs.lstatSync(appStatePath);
          if (!stateStat.isFile() || stateStat.isSymbolicLink()) {
            throw new Error("the VM app-state checkpoint is not a regular non-symlink file");
          }
          appState = JSON.parse(fs.readFileSync(appStatePath, "utf8"));
          if (!appState || typeof appState !== "object" || Array.isArray(appState)) {
            throw new Error("the VM app-state checkpoint is not a JSON object");
          }
          if (appState.appName !== appName || typeof appState.appCreated !== "boolean") {
            throw new Error("the VM app-state checkpoint is not bound to the exact run app");
          }
        } catch (error) {
          appStateError = redact(error.message);
          machine.appStateError = appStateError;
          machine.status = interruption ? "interrupted" : "failed";
          if (!machine.error) machine.error = interruption ? `Interrupted by ${interruption.signal}` : "The VM app-state checkpoint was unavailable or invalid.";
          failed = true;
        }
        const resultProvesCreation = machine.result?.appCreated === true || machine.result?.checks?.app === "passed";
        // If the adapter loses the VM or host transport before it can persist a
        // trustworthy state object, exact-name cleanup is mandatory. This is a
        // conservative cleanup target, not a claim that creation was observed.
        const cleanupTargetConservative = appStateError !== null && !resultProvesCreation;
        const appCreated = appState?.appCreated === true || resultProvesCreation || cleanupTargetConservative;
        machine.appCreated = appCreated;
        machine.cleanupTargetConservative = cleanupTargetConservative;
        machine.appStateCheckpoint = appStateError === null ? "verified" : "conservative-unknown";
        try {
          machine.cleanup = await cleanup({
            mode: deprovision,
            diagnostic,
            command: liveConfiguration.deprovisionCommand,
            appName,
            tenantName,
            runId,
            output: path.join(output, vm),
            appCreated,
            apiOrigin: liveConfiguration.apiOrigin,
          });
          machine.cleanupVerified = machine.cleanup.cleanupVerified === true;
          if (!machine.cleanupVerified && !diagnostic) failed = true;
        } catch (error) {
          machine.cleanupVerified = false;
          machine.cleanupError = redact(error.message);
          if (!diagnostic) failed = true;
        }
        if (interruption) {
          machine.status = "interrupted";
          if (!machine.error) machine.error = `Interrupted by ${interruption.signal}`;
          failed = true;
        }
        writeJson(path.join(output, "release-e2e.json"), report);
      }
      if (failed || interruption) break;
    }
    report.status = interruption ? "interrupted" : failed ? "failed" : diagnostic ? "passed_with_mock_cleanup" : "passed";
    if (interruption) report.interruption = interruptionEvidence();
    report.completedAt = new Date().toISOString();
    writeJson(path.join(output, "release-e2e.json"), report);
    console.log(JSON.stringify({ status: report.status, report: path.join(output, "release-e2e.json"), machines: report.machines.map(({ vm, status, cleanupVerified, error, cleanupError }) => ({ vm, status, cleanupVerified, error, cleanupError })) }, null, 2));
    if (interruption) process.exitCode = interruption.exitCode;
    else if (report.status === "failed") process.exitCode = 1;
  } catch (error) {
    report.status = interruption ? "interrupted" : "failed";
    report.error = interruption ? `Interrupted by ${interruption.signal}` : redact(error.message);
    if (interruption) report.interruption = interruptionEvidence();
    report.completedAt = new Date().toISOString();
    writeJson(path.join(output, "release-e2e.json"), report);
    throw error;
  }
}

process.on("SIGINT", () => handleSignal("SIGINT"));
process.on("SIGTERM", () => handleSignal("SIGTERM"));

main().catch((error) => {
  if (interruption) {
    console.error(`release-e2e interrupted by ${interruption.signal}`);
    process.exitCode = interruption.exitCode;
  } else {
    console.error(`release-e2e failed: ${redact(error.message)}`);
    process.exitCode = 1;
  }
});
