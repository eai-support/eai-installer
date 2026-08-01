import { readFile } from "node:fs/promises";
import { URL } from "node:url";

const root = new URL("../", import.meta.url);
const manifest = JSON.parse(await readFile(new URL("installer-manifest.json", root), "utf8"));

const fail = (message) => {
  throw new Error(`manifest: ${message}`);
};

if (manifest.schemaVersion !== 1) fail("unsupported schemaVersion");
if (manifest.product?.publicDownload !== true) fail("publicDownload must be true");
if (manifest.sources?.cliPackage !== "@enterpriseai/cli") fail("unexpected CLI package");
if (manifest.sources?.cliCommand !== "eai") fail("unexpected CLI command");

for (const key of ["goferRepository", "appTemplateRepository"]) {
  const value = manifest.sources[key];
  if (!value || !value.startsWith("https://github.com/")) fail(`${key} must be a public HTTPS GitHub URL`);
}

const forbidden = /(\.internal\.|\.local\b|myenterprise|api\.(dev|test|prod)\b|token\s*[:=]|client[_-]?secret\s*[:=]|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)/i;
const text = JSON.stringify(manifest);
if (forbidden.test(text)) fail("private host or credential-shaped text found");

const commands = [
  "eai login",
  "eai whoami",
  "eai tenant list",
  "eai tenant select <tenant>",
  "eai init <project-name>",
];
for (const command of commands) {
  if (!manifest.runtime.userCommands.includes(command)) fail(`missing runtime command: ${command}`);
}

for (const value of Object.values(manifest.sources)) {
  if (typeof value === "string" && value.startsWith("http") && new URL(value).protocol !== "https:") {
    fail(`non-HTTPS source: ${value}`);
  }
}

for (const prerequisite of manifest.prerequisites) {
  if (!prerequisite.id || !prerequisite.command || !prerequisite.minimumVersion) {
    fail("each prerequisite needs id, command, and minimumVersion");
  }
}

if (manifest.security.noSecretsInRepository !== true) fail("noSecretsInRepository must be true");
if (manifest.security.signedDesktopArtifactsRequiredForRelease !== true) {
  fail("signed desktop artifacts must be a release requirement");
}

console.log(`manifest ok: ${manifest.product.name}`);
