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
const windowsIcon = await readFile(new URL("../src-tauri/icons/icon.ico", import.meta.url));
if (windowsIcon.length < 32 || windowsIcon.readUInt16LE(2) !== 1) {
  throw new Error("Tauri Windows icon resource is missing or invalid");
}
for (const step of ["homebrew", "git", "node", "eai-cli", "login", "init"]) {
  if (!rust.includes(`\"${step}\"`)) throw new Error(`Tauri adapter is missing ${step}`);
}
if (!rust.includes("@enterpriseai/cli")) throw new Error("Tauri adapter uses the wrong CLI package");
if (!rust.includes("run_program_in_directory(\"eai\"")) throw new Error("Tauri adapter does not run eai init in the selected directory");
if (!rust.includes("run_program(\"eai\", &[\"login\"]")) throw new Error("Tauri adapter does not run eai login");
if (!rust.includes("pkexec")) throw new Error("Tauri adapter does not provide automatic Linux package installation");
if (rust.includes("Command::new(user") || rust.includes("shell = user")) {
  throw new Error("Tauri adapter appears to execute user-supplied commands");
}

console.log("bootstrap safety checks ok");

const wizard = await readFile(new URL("../ui/index.html", import.meta.url), "utf8");
for (const panel of ["0", "1", "2", "3", "4", "5"]) {
  if (!wizard.includes(`data-panel="${panel}"`)) throw new Error(`wizard: missing panel ${panel}`);
}
for (const control of ["data-action=\"start\"", "data-action=\"login\"", "data-action=\"init\"", "data-action=\"finish\""]) {
  if (!wizard.includes(control)) throw new Error(`wizard: missing control ${control}`);
}
if (wizard.includes("I am signed in")) throw new Error("wizard: sign-in still has an unnecessary confirmation step");
if (!wizard.includes('id="retry-install"')) throw new Error("wizard: failed installation has no retry control");
for (const control of ["id=\"activity\"", "id=\"activity-title\"", "id=\"activity-detail\""]) {
  if (!wizard.includes(control)) throw new Error(`wizard: missing activity status: ${control}`);
}
const app = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");
if (!app.includes("setActivity") || !app.includes("Installation complete") || !app.includes("async function startSetup") || !app.includes("setStep(4)")) {
  throw new Error("wizard: live activity status updates are missing");
}
const wizardState = await readFile(new URL("../ui/wizard-state.js", import.meta.url), "utf8");
if (!wizardState.includes("prerequisitesReady") || !wizardState.includes("isKebabCase")) {
  throw new Error("wizard: state validation contract is missing");
}

console.log("wizard structure checks ok");

const bundles = await readFile(new URL("../.github/workflows/test-bundles.yml", import.meta.url), "utf8");
for (const value of ["Windows", "macOS", "Ubuntu", "bundle: nsis", "bundle: dmg", "bundle: deb", "actions/upload-artifact@v4", "actions/download-artifact@v4", "Smoke-test Windows installer", "Smoke-test macOS disk image", "Smoke-test Ubuntu package"]) {
  if (!bundles.includes(value)) throw new Error(`test-bundles workflow is missing: ${value}`);
}
if (!bundles.includes("$null -ne $LASTEXITCODE")) {
  throw new Error("test-bundles workflow does not handle GUI installer exit codes safely");
}
if (!bundles.includes("expected install roots") || !bundles.includes("Where-Object { $_.Extension -ieq '.exe' }")) {
  throw new Error("test-bundles workflow does not inspect the installed Windows executable");
}
if (!bundles.includes("Start-Sleep -Seconds 1")) {
  throw new Error("test-bundles workflow does not wait for the Windows installer handoff");
}
console.log("test-bundle workflow checks ok");

const tauriConfig = JSON.parse(await readFile(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"));
const dmg = tauriConfig.bundle?.macOS?.dmg;
if (!dmg?.background || dmg.windowSize?.width !== 660 || dmg.windowSize?.height !== 400) {
  throw new Error("Tauri DMG does not declare the guided installation window");
}
const dmgBackground = await readFile(new URL(`../src-tauri/${dmg.background.replace(/^icons\//, "icons/")}`, import.meta.url));
if (dmgBackground.length < 64 || dmgBackground.readUInt32BE(0) !== 0x89504e47) {
  throw new Error("Tauri DMG background image is missing or invalid");
}
const testRelease = await readFile(new URL("../.github/workflows/test-release.yml", import.meta.url), "utf8");
for (const value of ["workflow_dispatch", "gh release create", "gh release upload", "eai-setup-macos-arm64.dmg", "eai-setup-windows-x64.exe", "eai-setup-ubuntu-amd64.deb"]) {
  if (!testRelease.includes(value)) throw new Error(`test-release workflow is missing: ${value}`);
}
const release = await readFile(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
for (const value of ["Add stable direct-download assets", "eai-setup-macos-arm64.dmg", "eai-setup-windows-x64.exe", "eai-setup-ubuntu-amd64.deb"]) {
  if (!release.includes(value)) throw new Error(`release workflow is missing: ${value}`);
}
console.log("release and DMG checks ok");
