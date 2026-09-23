#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const checkpointSchema = "eai.release-e2e.checkpoint-ledger.v1";
export const windowsPhases = ["fresh", "native-installer-verified", "welcome-start-verified", "welcome-ready-verified", "signin-verified", "cli-login-verified", "e2e-complete"];

function fail(message) { throw new Error(message); }
function validHash(value) { return typeof value === "string" && /^[a-f0-9]{64}$/.test(value); }
function assertSafe(value, field = "value") {
  if (typeof value === "string") {
    if (/(password|secret|token|tenant|email|credential)/i.test(field)) fail(`Checkpoint ${field} must not contain a secret or identity.`);
    return;
  }
  if (Array.isArray(value)) return value.forEach((item) => assertSafe(item, field));
  if (value && typeof value === "object") for (const [key, item] of Object.entries(value)) assertSafe(item, key);
}
function assertLedger(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("Checkpoint ledger is not a JSON object.");
  if (value.schemaVersion !== checkpointSchema || value.vm !== "windows" || !windowsPhases.includes(value.phase)) fail("Checkpoint ledger schema, VM, or phase is invalid.");
  if (!/^\d+\.\d+\.\d+$/.test(value.release?.version || "") || typeof value.release?.tag !== "string" || !validHash(value.release?.assetSha256)) fail("Checkpoint ledger release binding is invalid.");
  if (expected && (value.release.version !== expected.version || value.release.tag !== expected.tag || value.release.assetSha256 !== expected.assetSha256)) fail("Checkpoint ledger is bound to a different published release asset.");
  if (!Array.isArray(value.events)) fail("Checkpoint ledger events are invalid.");
  assertSafe(value);
  return value;
}
function atomicWrite(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, file);
}
export function readCheckpoint(file, expected) {
  if (!fs.existsSync(file)) return null;
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) fail("Checkpoint ledger is not a regular file.");
  return assertLedger(JSON.parse(fs.readFileSync(file, "utf8")), expected);
}
export function initializeCheckpoint(file, release) {
  const existing = readCheckpoint(file, release);
  if (existing) return existing;
  const verifiedAt = new Date().toISOString();
  const ledger = { schemaVersion: checkpointSchema, vm: "windows", release, phase: "fresh", updatedAt: verifiedAt, events: [{ phase: "fresh", verifiedAt, evidence: { source: "new-ledger" } }] };
  atomicWrite(file, ledger);
  return ledger;
}
export function advanceCheckpoint(file, release, phase, evidence = {}) {
  if (!windowsPhases.includes(phase) || phase === "fresh") fail("Checkpoint phase is not advanceable.");
  assertSafe(evidence, "evidence");
  const ledger = initializeCheckpoint(file, release);
  const oldIndex = windowsPhases.indexOf(ledger.phase);
  const nextIndex = windowsPhases.indexOf(phase);
  if (nextIndex <= oldIndex) return ledger;
  if (nextIndex > oldIndex + 1) fail("Checkpoint transition is out of order.");
  const verifiedAt = new Date().toISOString();
  ledger.phase = phase;
  ledger.updatedAt = verifiedAt;
  ledger.events.push({ phase, verifiedAt, evidence });
  atomicWrite(file, ledger);
  return ledger;
}
function option(name) { const index = process.argv.indexOf(`--${name}`); return index === -1 ? undefined : process.argv[index + 1]; }
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const command = process.argv[2];
  const file = option("ledger");
  const release = { version: option("version"), tag: option("tag"), assetSha256: option("asset-sha256") };
  if (!file || !release.version || !release.tag || !release.assetSha256) fail("ledger, version, tag, and asset-sha256 are required.");
  if (command === "init") console.log(JSON.stringify(initializeCheckpoint(file, release)));
  else if (command === "read") console.log(JSON.stringify(readCheckpoint(file, release) || initializeCheckpoint(file, release)));
  else if (command === "advance") console.log(JSON.stringify(advanceCheckpoint(file, release, option("phase"), option("evidence") ? JSON.parse(option("evidence")) : {})));
  else fail("Expected init, read, or advance.");
}
