import { readFile } from "node:fs/promises";

const files = ["scripts/bootstrap.sh", "scripts/bootstrap.ps1"];
for (const file of files) {
  const text = await readFile(new URL(`../${file}`, import.meta.url), "utf8");
  if (!text.includes("@enterpriseai/cli")) throw new Error(`${file}: canonical CLI install is missing`);
  if (!text.includes("eai login")) throw new Error(`${file}: login handoff is missing`);
  if (!text.includes("eai init")) throw new Error(`${file}: init handoff is missing`);
  if (!text.includes("EAI_SETUP_AUTO_INSTALL") && !text.includes("AutoInstall")) {
    throw new Error(`${file}: explicit install opt-in is missing`);
  }
  if (/curl\s+[^\n|]*\|\s*(sh|bash)/i.test(text)) throw new Error(`${file}: unsafe curl pipe install found`);
}

const shell = await readFile(new URL("../scripts/bootstrap.sh", import.meta.url), "utf8");
for (const value of ["--install-homebrew", "EAI_SETUP_INSTALL_HOMEBREW", "raw.githubusercontent.com/Homebrew/install/HEAD/install.sh", "--proto '=https'", "--tlsv1.2"]) {
  if (!shell.includes(value)) throw new Error(`bootstrap.sh: Homebrew install control is missing: ${value}`);
}
if (!shell.includes('INSTALL_HOMEBREW="${EAI_SETUP_INSTALL_HOMEBREW:-0}"')) {
  throw new Error("bootstrap.sh: Homebrew installation is not opt-in");
}

const manifest = JSON.parse(await readFile(new URL("../installer-manifest.json", import.meta.url), "utf8"));
const homebrew = manifest.prerequisites.find((item) => item.id === "homebrew");
if (!homebrew || homebrew.platform !== "macos" || !homebrew.installers?.macos?.includes("raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")) {
  throw new Error("manifest: macOS Homebrew prerequisite is not explicit");
}

const rust = await readFile(new URL("../src-tauri/src/main.rs", import.meta.url), "utf8");
for (const step of ["homebrew", "git", "node", "eai-cli", "login", "init"]) {
  if (!rust.includes(`\"${step}\"`)) throw new Error(`Tauri adapter is missing ${step}`);
}
if (!rust.includes("@enterpriseai/cli")) throw new Error("Tauri adapter uses the wrong CLI package");
if (rust.includes("Command::new(user") || rust.includes("shell = user")) {
  throw new Error("Tauri adapter appears to execute user-supplied commands");
}

console.log("bootstrap safety checks ok");
