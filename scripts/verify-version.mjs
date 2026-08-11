import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const packageJson = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
const cargo = await readFile(new URL("src-tauri/Cargo.toml", root), "utf8");
const tauri = JSON.parse(await readFile(new URL("src-tauri/tauri.conf.json", root), "utf8"));
const semver = /^\d+\.\d+\.\d+$/;
const cargoVersion = cargo.match(/^version\s*=\s*"([^"]+)"/m)?.[1];
const versions = {
  "package.json": packageJson.version,
  "src-tauri/Cargo.toml": cargoVersion,
  "src-tauri/tauri.conf.json": tauri.version,
};

if (!Object.values(versions).every((version) => semver.test(version || ""))) {
  throw new Error(`Release version must be major.minor.patch: ${JSON.stringify(versions)}`);
}

const unique = new Set(Object.values(versions));
if (unique.size !== 1) {
  throw new Error(`Version mismatch: ${JSON.stringify(versions)}`);
}

console.log(`semantic version ${packageJson.version} is consistent`);
