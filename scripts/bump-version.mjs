#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bump = process.argv[2];
if (!["major", "minor", "patch"].includes(bump)) {
  console.error("Usage: node scripts/bump-version.mjs <major|minor|patch>");
  process.exit(2);
}

const packagePath = path.join(root, "package.json");
const packageJson = JSON.parse(fs.readFileSync(packagePath, "utf8"));
const current = packageJson.version;
const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(current);
if (!match) throw new Error(`Invalid current version: ${current}`);

let [major, minor, patchVersion] = match.slice(1).map(Number);
if (bump === "major") {
  major += 1;
  minor = 0;
  patchVersion = 0;
} else if (bump === "minor") {
  minor += 1;
  patchVersion = 0;
} else {
  patchVersion += 1;
}
const next = `${major}.${minor}.${patchVersion}`;

packageJson.version = next;
fs.writeFileSync(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);

const cargoPath = path.join(root, "src-tauri", "Cargo.toml");
const cargo = fs.readFileSync(cargoPath, "utf8");
const nextCargo = cargo.replace(/^(version\s*=\s*")([^\"]+)(")/m, `$1${next}$3`);
if (cargo === nextCargo) throw new Error("Could not update src-tauri/Cargo.toml version");
fs.writeFileSync(cargoPath, nextCargo);

const tauriPath = path.join(root, "src-tauri", "tauri.conf.json");
const tauri = JSON.parse(fs.readFileSync(tauriPath, "utf8"));
tauri.version = next;
fs.writeFileSync(tauriPath, `${JSON.stringify(tauri, null, 2)}\n`);

console.log(next);
