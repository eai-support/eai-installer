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
const macDevSmoke = await readFile(new URL("../scripts/test-macos-dev.sh", import.meta.url), "utf8");
for (const value of ["codesign --force --deep --sign -", "codesign --verify --deep --strict", "xattr -dr com.apple.quarantine", "Contents/MacOS/eai-setup"]) {
  if (!macDevSmoke.includes(value)) throw new Error(`macOS development smoke test is missing: ${value}`);
}

const shell = await readFile(new URL("../scripts/bootstrap.sh", import.meta.url), "utf8");
for (const value of ["--install-homebrew", "EAI_SETUP_INSTALL_HOMEBREW", "raw.githubusercontent.com/Homebrew/install/HEAD/install.sh", "--proto '=https'", "--tlsv1.2"]) {
  if (!shell.includes(value)) throw new Error(`bootstrap.sh: Homebrew install control is missing: ${value}`);
}
if (!shell.includes('INSTALL_HOMEBREW="${EAI_SETUP_INSTALL_HOMEBREW:-0}"')) {
  throw new Error("bootstrap.sh: Homebrew installation is not opt-in");
}

const manifest = JSON.parse(await readFile(new URL("../installer-manifest.json", import.meta.url), "utf8"));
if (manifest.runtime?.accountSignupUrl !== "https://www.enterpriseaigroup.com/signup/developer") {
  throw new Error("manifest: public developer signup URL is missing or incorrect");
}
const homebrew = manifest.prerequisites.find((item) => item.id === "homebrew");
if (!homebrew || homebrew.platform !== "macos" || !homebrew.installers?.macos?.includes("github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg")) {
  throw new Error("manifest: macOS Homebrew prerequisite is not explicit");
}
if (homebrew.required !== false) throw new Error("manifest: Homebrew must remain optional for the minimal EAI setup");
const git = manifest.prerequisites.find((item) => item.id === "git");
if (!git?.installers?.macos?.includes("Command Line Tools") || git.installers.macos.includes("full Xcode is required")) {
  throw new Error("manifest: macOS Git path must use Command Line Tools without requiring full Xcode");
}
const node = manifest.prerequisites.find((item) => item.id === "node");
const nodeMacInstaller = node?.installers?.macos ?? "";
const nodeMacUrls = nodeMacInstaller.match(/https:\/\/[^\s]+/g) ?? [];
const hasOfficialNodeUrl = nodeMacUrls.some((value) => {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "nodejs.org";
  } catch {
    return false;
  }
});
if (!hasOfficialNodeUrl || !nodeMacInstaller.includes("checksum verification") || !nodeMacInstaller.includes("user-local")) {
  throw new Error("manifest: macOS Node.js path must use the official checksum-verified user-local archive");
}

const dmgBackgroundSource = await readFile(new URL("../src-tauri/icons/dmg-background.svg", import.meta.url), "utf8");
if (!dmgBackgroundSource.includes(">Install Enterprise AI harness</text>") || !dmgBackgroundSource.includes(">Drag Enterprise AI Setup to Applications to install</text>")) {
  throw new Error("DMG background does not use the Enterprise AI harness heading");
}

const rust = await readFile(new URL("../src-tauri/src/main.rs", import.meta.url), "utf8");
const windowsIcon = await readFile(new URL("../src-tauri/icons/icon.ico", import.meta.url));
if (windowsIcon.length < 32 || windowsIcon.readUInt16LE(2) !== 1) {
  throw new Error("Tauri Windows icon resource is missing or invalid");
}
for (const step of ["homebrew", "git", "node", "eai-cli", "login", "init", "start"]) {
  if (!rust.includes(`\"${step}\"`)) throw new Error(`Tauri adapter is missing ${step}`);
}
for (const value of ["detect_ai_surfaces", "start_ai_surface", "install_ai_surface", "AiSurfaceInventory", "eai", "start", "--check"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing AI workspace handoff: ${value}`);
}
for (const value of ["get_company_tenants", "tenant", "list", "--format", "json", "directMembership", "parentId"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing company workspace discovery: ${value}`);
}
if (!rust.includes("@enterpriseai/cli")) throw new Error("Tauri adapter uses the wrong CLI package");
if (!rust.includes("run_program_in_directory(\"eai\", &init_args")) throw new Error("Tauri adapter does not run eai init non-interactively in the selected directory");
if (!rust.includes("\"--company-tenant\"")) throw new Error("Tauri adapter does not pass the selected company workspace to eai init");
if (!rust.includes("command.stdin(Stdio::null())")) throw new Error("Tauri adapter does not close child stdin for GUI-launched commands");
if (!rust.includes("run_program(\"eai\", &[\"login\"]")) throw new Error("Tauri adapter does not run eai login");
if (!rust.includes("fn open_signup") || !rust.includes("EAI_SIGNUP_URL") || !rust.includes("www.enterpriseaigroup.com/signup/developer")) {
  throw new Error("Tauri adapter does not provide the fixed public account signup handoff");
}
if (!rust.includes("pkexec")) throw new Error("Tauri adapter does not provide automatic Linux package installation");
if (!rust.includes("tauri_plugin_dialog::init()")) throw new Error("Tauri adapter does not provide the native folder picker");
if (!rust.includes("fn project_directory") || !rust.includes("fs::create_dir_all(&directory)")) {
  throw new Error("Tauri adapter does not create the project folder before initialization");
}
if (!rust.includes("project_directory: Option<String>") || !rust.includes("result.project_directory = Some")) {
  throw new Error("Tauri adapter does not return the exact created project directory to the AI workspace handoff");
}
if (!rust.includes('inventory.contract_version != "eai.ai-surfaces/v1"')) {
  throw new Error("Tauri adapter does not enforce the versioned AI surface contract");
}
for (const value of ["Homebrew.pkg", "/usr/sbin/pkgutil", "--check-signature", "with administrator privileges", "--stdinpass", "No Terminal window will open"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing native macOS installation control: ${value}`);
}
for (const value of ["windows_package_bin_dirs", "ProgramFiles(x86)", "CREATE_NO_WINDOW", "creation_flags", "LOCALAPPDATA", "Windows package installation finished, but the expected command is not available yet.", "npm finished, but the eai command is not available yet."]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing Windows prerequisite safety support: ${value}`);
}
for (const value of ["xcode-select", "full Xcode is not required", "softwareupdate", "latest_command_line_tools_label", "refresh_macos_command_line_tools_catalog", "Refreshing Apple Software Update", "with administrator privileges", "secure administrator dialog", "native administrator install", "latest_node_artifact", "nodejs.org/dist/index.json", "osx-arm64-pkg", "osx-x64-pkg", "osx-arm64-tar", "osx-x64-tar", "SHASUMS256.txt", "shasum", "uname", "--prefix", "expose_user_npm_bin", "NVM_DIR", "versions/node", "NVM_BIN", "nvm_node_bin_dirs", "macos_package_bin_dirs"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing minimal macOS setup support: ${value}`);
}
if (!rust.includes("fn macos_git_ready()") || !rust.includes("/usr/bin/xcode-select") || !rust.includes("usr/bin/git")) {
  throw new Error("Tauri adapter does not guard the macOS Git shim before detection");
}
const detectStart = rust.indexOf("fn detect_environment");
const detectEnd = rust.indexOf("fn package_install_step");
const detectSource = rust.slice(detectStart, detectEnd);
if (detectSource.includes('version("git"')) {
  throw new Error("Tauri adapter invokes the macOS Git shim directly during detection");
}
const cltStart = rust.indexOf("fn command_line_tools_install_step");
const cltEnd = rust.indexOf("fn latest_node_artifact");
const cltSource = rust.slice(cltStart, cltEnd);
if (cltSource.includes('version("git"')) {
  throw new Error("Tauri adapter invokes the macOS Git shim directly during Command Line Tools setup");
}
if (!rust.includes("/usr/bin/osascript") || rust.includes('tell application "Terminal"')) {
  throw new Error("Tauri adapter still opens Terminal for Homebrew installation");
}
if (!rust.includes("Prefer the user-local archive") || !rust.includes("password was supplied once and is not saved")) {
  throw new Error("Tauri adapter does not explain the no-second-prompt macOS path");
}
if (!rust.includes('command.env("PATH", path)') || !rust.includes(".eai-setup/node/bin") || !rust.includes("versions/node")) {
  throw new Error("Tauri adapter does not expose user-managed Node.js paths to npm child processes");
}
if (!rust.includes("Node.js files were downloaded, but the desktop app could not run node and npm")) {
  throw new Error("Tauri adapter reports Node.js ready before verifying the installed executables");
}
if (!rust.includes("async fn run_bootstrap") || !rust.includes("spawn_blocking")) {
  throw new Error("Tauri adapter blocks the UI while running a bootstrap task");
}
if (rust.includes("Command::new(user") || rust.includes("shell = user")) {
  throw new Error("Tauri adapter appears to execute user-supplied commands");
}

console.log("bootstrap safety checks ok");

const wizard = await readFile(new URL("../ui/index.html", import.meta.url), "utf8");
const brandLogo = await readFile(new URL("../ui/assets/eai-square-man-logo.png", import.meta.url));
if (brandLogo.length < 1024) throw new Error("wizard: Enterprise AI logo asset is missing or unexpectedly small");
for (const brandElement of ["Enterprise AI Setup", "assets/eai-square-man-logo.png", "class=\"brand-logo\"", "class=\"panel-logo\""]) {
  if (!wizard.includes(brandElement)) throw new Error(`wizard: branding is missing ${brandElement}`);
}
const bundleLogo = await readFile(new URL("../src-tauri/icons/icon.png", import.meta.url));
if (bundleLogo.length < 1024) throw new Error("bundle: Enterprise AI logo icon is missing or unexpectedly small");
const bundleLogoSource = await readFile(new URL("../src-tauri/icons/icon.svg", import.meta.url), "utf8");
for (const color of ["#123d5b", "#83d8ef"]) {
  if (!bundleLogoSource.includes(color)) throw new Error(`bundle: Enterprise AI logo source is missing ${color}`);
}
for (const panel of ["0", "3", "4", "5"]) {
  if (!wizard.includes(`data-panel="${panel}"`)) throw new Error(`wizard: missing panel ${panel}`);
}
for (const control of ["data-action=\"start\"", "data-action=\"login\"", "data-action=\"signup\"", "data-action=\"choose-folder\"", "data-action=\"init\"", "data-action=\"start-ai\"", "data-action=\"finish\""]) {
  if (!wizard.includes(control)) throw new Error(`wizard: missing control ${control}`);
}
for (const value of ["id=\"ai-surface-status\"", "id=\"ai-surface-options\"", "id=\"ai-surface-consent\"", "Start building with EAI", "may use your provider account"]) {
  if (!wizard.includes(value)) throw new Error(`wizard: AI workspace handoff is missing ${value}`);
}
for (const value of ["id=\"company-tenant-field\"", "id=\"company-tenant\"", "Company workspace", "Choose where this app will be created"]) {
  if (!wizard.includes(value)) throw new Error(`wizard: missing company workspace selection: ${value}`);
}
for (const value of ["id=\"choose-folder\"", "Use lowercase words separated by hyphens", "Parent folder", "A new folder with your project name will be created here"]) {
  if (!wizard.includes(value)) throw new Error(`wizard: missing project location guidance: ${value}`);
}
if (!wizard.includes("Create an EAI account")) throw new Error("wizard: account signup action is missing");
for (const obsolete of ["progress-area", "Step 3 of 6", "Step ${index + 1} of ${steps.length}", "Install missing tools", "I am signed in"]) {
  if (wizard.includes(obsolete)) throw new Error(`wizard: unnecessary user step remains: ${obsolete}`);
}
if (!wizard.includes('id="retry-install"')) throw new Error("wizard: failed installation has no retry control");
for (const control of ["id=\"activity\"", "id=\"activity-title\"", "id=\"activity-detail\"", "id=\"activity-eta\"", "id=\"activity-heartbeat\"", "id=\"activity-log\"", "id=\"install-items\"", "id=\"admin-password\"", "id=\"admin-password-submit\""]) {
  if (!wizard.includes(control)) throw new Error(`wizard: missing activity status: ${control}`);
}
if (!wizard.includes("Recent activity")) throw new Error("wizard: recent activity heading is missing");
const app = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");
if (app.includes('steps.push("homebrew")')) throw new Error("wizard: Homebrew must not be a required setup step");
if (!app.includes("setActivity") || !app.includes("Installation complete") || !app.includes("listenForBootstrapProgress") || !app.includes("eventApi.listen") || !app.includes("renderInstallItems") || !app.includes("setDetectionState") || !app.includes("phaseForTitle") || !app.includes("async function startSetup") || !app.includes("window.setTimeout(() => startSetup(), 250)") || !app.includes("setStep(4)") || !app.includes("async function runSignup") || !app.includes("open_signup") || !app.includes("dialog.open") || !app.includes("choose-folder") || !app.includes("get_company_tenants") || !app.includes("companyTenantId")) {
  throw new Error("wizard: live activity status updates are missing");
}
for (const value of ["loadAiSurfaces", "renderAiSurfaces", "startAiSurface", "detect_ai_surfaces", "start_ai_surface", "install_ai_surface"]) {
  if (!app.includes(value)) throw new Error(`wizard: AI workspace behavior is missing ${value}`);
}
for (const value of ["setInterval(refreshActivityHeartbeat, 1000)", "Elapsed ${elapsed}s", "Screen updated every second", "Last installer update", "Waiting for your input", "Action needed", "Still working", "activityLastHeartbeatLogAt", "waitingDetails", "activityEvents", "Stopped with error", "Checking the required tools"]) {
  if (!app.includes(value)) throw new Error(`wizard: per-second progress feedback is missing: ${value}`);
}
if (app.includes('git: "macOS may show an installer window. If it appears, click Install; otherwise no action is needed."')) {
  throw new Error("wizard: macOS Git fallback still tells users to wait for an unspecified installer window");
}
if (!app.includes("Working - no action needed") || !app.includes("Apple Software Update is still installing Git")) {
  throw new Error("wizard: long-running macOS installs do not explain the live status clearly");
}
if (!app.includes('activity.hidden = !active && phase !== "Error"') || !app.includes("requestMacAdminPassword") || !app.includes("adminPassword")) {
  throw new Error("wizard: failed activity log is hidden instead of remaining available for diagnosis");
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
const debSelector = await readFile(new URL("./find-valid-deb.sh", import.meta.url), "utf8");
if (!debSelector.includes("dpkg-deb --contents") || !debSelector.includes("usr\\/bin\\/eai-setup")) {
  throw new Error("Linux package selector does not verify the installed executable payload");
}
const dmgSelector = await readFile(new URL("./find-valid-dmg.sh", import.meta.url), "utf8");
if (!dmgSelector.includes("hdiutil imageinfo") || !dmgSelector.includes("*/bundle/dmg/*.dmg")) {
  throw new Error("macOS package selector does not verify a real DMG image");
}
for (const workflow of [bundles, await readFile(new URL("../.github/workflows/test-release.yml", import.meta.url), "utf8"), await readFile(new URL("../.github/workflows/release.yml", import.meta.url), "utf8")]) {
  if (!workflow.includes("scripts/find-valid-deb.sh")) {
    throw new Error("Linux packaging workflow does not use the validated Debian package selector");
  }
  if (!workflow.includes("scripts/find-valid-dmg.sh")) {
    throw new Error("macOS packaging workflow does not use the validated DMG selector");
  }
}
console.log("test-bundle workflow checks ok");

const tauriConfig = JSON.parse(await readFile(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"));
const dmg = tauriConfig.bundle?.macOS?.dmg;
if (!dmg?.background || dmg.windowSize?.width !== 660 || dmg.windowSize?.height !== 400) {
  throw new Error("Tauri DMG does not declare the guided installation window");
}
if (tauriConfig.bundle?.macOS?.signingIdentity !== "-") {
  throw new Error("Tauri development builds must use an explicit ad-hoc macOS signing identity");
}
const dmgBackground = await readFile(new URL(`../src-tauri/${dmg.background.replace(/^icons\//, "icons/")}`, import.meta.url));
if (dmgBackground.length < 64 || dmgBackground.readUInt32BE(0) !== 0x89504e47) {
  throw new Error("Tauri DMG background image is missing or invalid");
}
const testRelease = await readFile(new URL("../.github/workflows/test-release.yml", import.meta.url), "utf8");
for (const value of ["workflow_dispatch", "gh release create", "gh release upload", "eai-setup-macos-arm64.dmg", "eai-setup-macos-x64.dmg", "eai-setup-windows-x64.exe", "eai-setup-windows-arm64.exe", "eai-setup-ubuntu-amd64.deb", "eai-setup-ubuntu-arm64.deb", "x86_64-apple-darwin", "aarch64-pc-windows-msvc", "ubuntu-24.04-arm"]) {
  if (!testRelease.includes(value)) throw new Error(`test-release workflow is missing: ${value}`);
}
const release = await readFile(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
for (const value of ["Add stable direct-download assets", "eai-setup-macos-arm64.dmg", "eai-setup-macos-x64.dmg", "eai-setup-windows-x64.exe", "eai-setup-windows-arm64.exe", "eai-setup-ubuntu-amd64.deb", "eai-setup-ubuntu-arm64.deb", "x86_64-apple-darwin", "aarch64-pc-windows-msvc", "ubuntu-24.04-arm", "codesign --verify --deep --strict", "spctl --assess --type execute", "xcrun stapler validate"]) {
  if (!release.includes(value)) throw new Error(`release workflow is missing: ${value}`);
}
const testBundles = await readFile(new URL("../.github/workflows/test-bundles.yml", import.meta.url), "utf8");
for (const value of ["Windows ARM64", "macOS Intel", "aarch64-pc-windows-msvc", "x86_64-apple-darwin", "${#windows[@]}", "${#macos[@]}"]) {
  if (!testBundles.includes(value)) throw new Error(`test-bundles workflow is missing multi-architecture coverage: ${value}`);
}
for (const value of ["verify-published-macos", "gh release download", "hdiutil imageinfo", "hdiutil attach"]) {
  if (!(await readFile(new URL("../.github/workflows/test-release.yml", import.meta.url), "utf8")).includes(value)) {
    throw new Error(`test-release workflow is missing published DMG verification: ${value}`);
  }
}
console.log("release and DMG checks ok");
