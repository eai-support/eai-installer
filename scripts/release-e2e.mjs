#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

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
  for (const key of ["EAI_HARNESS_PASSWORD", "EAI_HARNESS_CLIENT_SECRET", "EAI_SERVICE_CLIENT_SECRET", "EAI_DEPROVISION_TOKEN", "EAI_APP_DEPROVISION_TOKEN", "EAI_HARNESS_TENANT_ID", "EAI_HARNESS_USER_EMAIL"]) {
    if (process.env[key]) output = output.split(process.env[key]).join("[REDACTED]");
  }
  return output;
}

function run(command, args, options = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      cwd: options.cwd || root,
      env: options.env || process.env,
      shell: Boolean(options.shell),
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.stderr?.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => resolve({ code: 1, stdout, stderr: `${stderr}${error.message}` }));
    child.on("close", (code, signal) => resolve({ code: code ?? 1, signal, stdout, stderr }));
  });
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function assetFor(vm) {
  const overrides = {
    macos: process.env.EAI_RELEASE_MACOS_ASSET,
    windows: process.env.EAI_RELEASE_WINDOWS_ASSET,
    ubuntu: process.env.EAI_RELEASE_UBUNTU_ASSET,
  };
  return overrides[vm] || {
    macos: "eai-setup-macos-arm64.dmg",
    windows: "eai-setup-windows-arm64.exe",
    ubuntu: "eai-setup-ubuntu-arm64.deb",
  }[vm];
}

function appNameFor(vm, runId) {
  return `test-${vm}-${runId}`.toLowerCase().replace(/[^a-z0-9-]/g, "-");
}

async function downloadAsset({ repo, tag, asset, destination }) {
  fs.mkdirSync(destination, { recursive: true });
  const target = path.join(destination, asset);
  if (!commandExists("gh")) throw new Error("gh is required to download the published release asset");
  const result = await run("gh", ["release", "download", tag, "--repo", repo, "--pattern", asset, "--dir", destination, "--clobber"]);
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
    const result = await run("hdiutil", ["imageinfo", assetPath]);
    if (result.code !== 0) throw new Error(`DMG validation failed: ${redact(result.stderr)}`);
  }
  if (vm === "ubuntu" && extension === ".deb" && commandExists("dpkg-deb")) {
    const result = await run("dpkg-deb", ["--info", assetPath]);
    if (result.code !== 0) throw new Error(`Debian package validation failed: ${redact(result.stderr)}`);
  }
  return { bytes: stat.size, sha256: crypto.createHash("sha256").update(fs.readFileSync(assetPath)).digest("hex") };
}

async function runVm({ driver, vm, asset, output, release, appName, runId, tenantName }) {
  const vmDir = path.join(output, vm);
  fs.mkdirSync(vmDir, { recursive: true });
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
  };

  if (driver !== "command") throw new Error(`Unsupported VM driver: ${driver}`);

  const key = `EAI_VM_${vm.toUpperCase()}_COMMAND`;
  const command = process.env[key];
  if (!command) throw new Error(`No real VM test command configured. Set ${key}`);
  const result = await run(command, [], { shell: true, env });
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

async function cleanup({ mode, diagnostic, appName, tenantName, runId, output, appCreated }) {
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
  const command = process.env.EAI_APP_DEPROVISION_COMMAND;
  if (!command) throw new Error("Live cleanup is unavailable: set EAI_APP_DEPROVISION_COMMAND to the approved V4 app deprovision adapter. No test app may be created without it.");
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
  };
  const result = await run(command, [], { shell: true, env });
  if (result.code !== 0) throw new Error(`V4 app deprovision command failed with exit code ${result.code}`);
  if (!fs.existsSync(receiptPath)) throw new Error("V4 app deprovision command did not write a cleanup receipt");
  const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
  if (receipt.status !== "verified") throw new Error("V4 app deprovision receipt is not verified");
  if (receipt.cleanupVerified !== true) throw new Error("V4 app deprovision receipt did not verify cleanup");
  if (receipt.source !== "public-api-v4") throw new Error("V4 app deprovision receipt does not identify the PublicAPI V4 source");
  if (typeof receipt.operationId !== "string" || receipt.operationId.length < 1) throw new Error("V4 app deprovision receipt is missing its operation id");
  if (!receipt.deletedRecords || !receipt.deletedResources) throw new Error("V4 app deprovision receipt is missing deletion evidence");
  if (receipt.appName !== appName) throw new Error("V4 app deprovision receipt names a different app");
  if (receipt.appCreated !== appCreated) throw new Error("V4 app deprovision receipt does not match whether the guest created the app");
  if (receipt.confirmation !== appName && receipt.confirmedAppName !== appName) throw new Error("V4 app deprovision receipt does not prove typed app-name confirmation");
  return receipt;
}

function validateLiveConfiguration({ driver, deprovision, diagnostic, vms }) {
  if (driver !== "command") throw new Error("The release gate only supports real command-driven VMs; mock drivers are removed.");
  if (deprovision !== "api" && deprovision !== "mock") throw new Error(`Unsupported cleanup mode: ${deprovision}`);
  if (deprovision === "mock" && !diagnostic) throw new Error("Mock cleanup is diagnostic-only; pass --diagnostic explicitly.");
  if (diagnostic && deprovision !== "mock") throw new Error("--diagnostic is only valid with --deprovision mock.");
  if (!process.env.EAI_HARNESS_TENANT_ID) throw new Error("EAI_HARNESS_TENANT_ID is required; the live gate refuses to guess a tenant.");
  if (!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(process.env.EAI_HARNESS_TENANT_ID)) throw new Error("EAI_HARNESS_TENANT_ID must be a tenant UUID.");
  if (!process.env.EAI_HARNESS_USER_EMAIL) throw new Error("EAI_HARNESS_USER_EMAIL is required; the live gate refuses to guess a test user.");
  if (deprovision === "api" && !process.env.EAI_APP_DEPROVISION_COMMAND) throw new Error("EAI_APP_DEPROVISION_COMMAND is required before any live app is created.");
  const missing = vms.filter((vm) => !process.env[`EAI_VM_${vm.toUpperCase()}_COMMAND`]);
  if (missing.length > 0) throw new Error(`Real VM commands are missing for: ${missing.join(", ")}. Set EAI_VM_<VM>_COMMAND for every guest.`);
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
  const tenantName = process.env.EAI_HARNESS_TENANT_NAME || "EAI release test tenant";
  const release = { version: options.version, tag, repo };
  fs.mkdirSync(output, { recursive: true });
  const report = { release, runId, tenantName, driver, deprovision, diagnostic, vms, status: "running", assets: [], machines: [] };
  writeJson(path.join(output, "release-e2e.json"), report);

  if (options.dryRun) {
    console.log(JSON.stringify({ ...report, planned: vms.map((vm) => ({ vm, asset: assetFor(vm), appName: appNameFor(vm, runId) })) }, null, 2));
    return;
  }
  validateLiveConfiguration({ driver, deprovision, diagnostic, vms });
  if (options.preflight) {
    console.log(JSON.stringify({ status: "ready", release, driver, deprovision, diagnostic, vms, tenantName }, null, 2));
    return;
  }

  const downloadDir = path.join(output, "downloads");
  const assetPaths = new Map();
  for (const vm of vms) {
    const assetName = assetFor(vm);
    if (!assetName) throw new Error(`No release asset configured for VM ${vm}`);
    const downloaded = await downloadAsset({ repo, tag, asset: assetName, destination: downloadDir });
    const validation = await validateAsset(downloaded.path, vm);
    assetPaths.set(vm, downloaded.path);
    report.assets.push({ vm, asset: assetName, source: downloaded.source, ...validation });
  }
  writeJson(path.join(output, "release-e2e.json"), report);

  let failed = false;
  for (const vm of vms) {
    const appName = appNameFor(vm, runId);
    const machine = { vm, appName, status: "running" };
    try {
      const asset = { ...report.assets.find((candidate) => candidate.vm === vm), path: assetPaths.get(vm) };
      machine.result = await runVm({ driver, vm, asset, output, release, appName, runId, tenantName });
      machine.status = "passed";
    } catch (error) {
      machine.status = "failed";
      machine.error = redact(error.message);
      failed = true;
    } finally {
      try {
        const appStatePath = path.join(output, vm, "app-state.json");
        const appState = fs.existsSync(appStatePath) ? JSON.parse(fs.readFileSync(appStatePath, "utf8")) : {};
        const appCreated = appState.appCreated === true || machine.result?.appCreated === true || machine.result?.checks?.app === "passed";
        machine.appCreated = appCreated;
        machine.cleanup = await cleanup({ mode: deprovision, diagnostic, appName, tenantName, runId, output: path.join(output, vm), appCreated });
        machine.cleanupVerified = machine.cleanup.cleanupVerified === true;
        if (!machine.cleanupVerified && !diagnostic) failed = true;
      } catch (error) {
        machine.cleanupVerified = false;
        machine.cleanupError = redact(error.message);
        if (!diagnostic) failed = true;
      }
      report.machines.push(machine);
      writeJson(path.join(output, "release-e2e.json"), report);
    }
  }
  report.status = failed ? "failed" : diagnostic ? "passed_with_mock_cleanup" : "passed";
  report.completedAt = new Date().toISOString();
  writeJson(path.join(output, "release-e2e.json"), report);
  console.log(JSON.stringify({ status: report.status, report: path.join(output, "release-e2e.json"), machines: report.machines.map(({ vm, status, cleanupVerified, error, cleanupError }) => ({ vm, status, cleanupVerified, error, cleanupError })) }, null, 2));
  if (report.status !== "passed") process.exitCode = 1;
}

main().catch((error) => {
  console.error(`release-e2e failed: ${redact(error.message)}`);
  process.exitCode = 1;
});
