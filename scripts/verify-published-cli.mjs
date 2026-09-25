#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageName = "@enterpriseai/cli";
const publicRegistry = "https://registry.npmjs.org/";

function parseVersion(value) {
  const match = String(value).trim().match(/^v?(\d+)\.(\d+)\.(\d+)$/);
  if (!match) throw new Error(`Invalid semantic version: ${value}`);
  return match.slice(1).map(Number);
}

function isAtLeast(value, minimum) {
  const current = parseVersion(value);
  const required = parseVersion(minimum);
  return current[0] > required[0]
    || (current[0] === required[0] && current[1] > required[1])
    || (current[0] === required[0] && current[1] === required[1] && current[2] >= required[2]);
}

function helpHasOption(help, option) {
  return String(help).split(/\s+/u).some((token) => token === option || token.startsWith(`${option}=`));
}

function isolatedCliEnvironment(home) {
  const environment = {};
  for (const key of ["PATH", "SystemRoot", "ComSpec", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL"]) {
    if (process.env[key]) environment[key] = process.env[key];
  }
  environment.HOME = home;
  environment.USERPROFILE = home;
  environment.NO_COLOR = "1";
  environment.CI = "1";
  return environment;
}

function isolatedNpmEnvironment(home, cache, userConfig) {
  const environment = {};
  for (const key of [
    "PATH", "SystemRoot", "ComSpec", "APPDATA", "LOCALAPPDATA", "TMPDIR", "TEMP", "TMP",
    "LANG", "LC_ALL", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
    "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR",
  ]) {
    if (process.env[key]) environment[key] = process.env[key];
  }
  return {
    ...environment,
    HOME: home,
    USERPROFILE: home,
    NO_COLOR: "1",
    CI: "1",
    npm_config_cache: cache,
    npm_config_userconfig: userConfig,
  };
}

function runCli(entrypoint, args, home) {
  return execFileSync(process.execPath, [entrypoint, ...args], {
    encoding: "utf8",
    env: isolatedCliEnvironment(home),
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export async function verifyInstalledCliPackage(packageRoot, minimumVersion, home = packageRoot) {
  const packagePath = join(packageRoot, "package.json");
  const manifest = JSON.parse(await readFile(packagePath, "utf8"));
  if (manifest.name !== packageName) throw new Error(`Expected ${packageName}, received ${manifest.name ?? "an unnamed package"}.`);
  if (!isAtLeast(manifest.version, minimumVersion)) {
    throw new Error(`Published ${packageName} ${manifest.version} is below the Installer minimum ${minimumVersion}.`);
  }

  const bin = manifest.bin && typeof manifest.bin === "object" && !Array.isArray(manifest.bin)
    ? manifest.bin.eai
    : undefined;
  if (typeof bin !== "string" || !bin || isAbsolute(bin)) {
    throw new Error(`Published ${packageName} does not declare a relative eai executable.`);
  }
  const canonicalRoot = await realpath(packageRoot);
  const entrypoint = await realpath(resolve(packageRoot, bin));
  const entrypointRelative = relative(canonicalRoot, entrypoint);
  if (!entrypointRelative || entrypointRelative === ".." || entrypointRelative.startsWith(`..${sep}`) || isAbsolute(entrypointRelative)) {
    throw new Error(`Published ${packageName} points its eai executable outside the package.`);
  }
  if (!(await stat(entrypoint)).isFile()) throw new Error(`Published ${packageName} eai executable is not a regular file.`);

  const versionOutput = runCli(entrypoint, ["--version"], home).trim();
  const executableVersion = versionOutput.startsWith("v") ? versionOutput.slice(1) : versionOutput;
  if (!/^\d+\.\d+\.\d+$/.test(executableVersion) || executableVersion !== manifest.version) {
    throw new Error(`Published ${packageName} executable version does not match package ${manifest.version}.`);
  }
  const help = runCli(entrypoint, ["deploy", "app", "--help"], home);
  for (const flag of ["--source", "--github-link-session", "--target-tenant-id"]) {
    if (!helpHasOption(help, flag)) throw new Error(`Published ${packageName} ${manifest.version} lacks ${flag} in eai deploy app --help.`);
  }
  return { version: manifest.version, entrypoint };
}

export async function verifyPublishedCli() {
  const installerManifest = JSON.parse(await readFile(join(root, "installer-manifest.json"), "utf8"));
  const minimumVersion = installerManifest.prerequisites?.find((item) => item.id === "eai-cli")?.minimumVersion;
  if (typeof minimumVersion !== "string") throw new Error("installer-manifest.json does not declare the EAI CLI minimum.");

  const workspace = await mkdtemp(join(tmpdir(), "eai-installer-cli-gate-"));
  try {
    const home = join(workspace, "home");
    const npmCache = join(workspace, "npm-cache");
    await mkdir(home, { recursive: true });
    await mkdir(npmCache, { recursive: true });
    const npmConfig = join(workspace, "npmrc");
    await writeFile(npmConfig, `registry=${publicRegistry}\nalways-auth=false\n`, { mode: 0o600 });

    const npmEnvironment = isolatedNpmEnvironment(home, npmCache, npmConfig);
    execFileSync("npm", [
      "install",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--package-lock=false",
      "--save=false",
      `--registry=${publicRegistry}`,
      "--prefix",
      workspace,
      `${packageName}@latest`,
    ], {
      cwd: workspace,
      encoding: "utf8",
      env: npmEnvironment,
      timeout: 120_000,
      maxBuffer: 8 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const packageRoot = join(workspace, "node_modules", "@enterpriseai", "cli");
    const result = await verifyInstalledCliPackage(packageRoot, minimumVersion, home);
    process.stdout.write(`published CLI release gate passed: ${packageName} ${result.version}\n`);
    return result;
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  verifyPublishedCli().catch((error) => {
    process.stderr.write(`published CLI release gate failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
