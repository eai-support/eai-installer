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
if (manifest.sources.cliRepository !== "https://github.com/eai-support/eai.git" || manifest.sources.goferRepository !== "https://github.com/eai-support/eai-gofer.git") {
  throw new Error("manifest: CLI and Gofer repositories must use the current public repositories");
}
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

const rust = (await readFile(new URL("../src-tauri/src/main.rs", import.meta.url), "utf8")).replace(/\r\n/g, "\n");
for (const value of ["fn user_home_dir", "fn usable_home_path", "getpwuid_r", "user_home_dir().map", "managed_files_never_use_root_or_relative_home_paths"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter does not resolve a safe signed-in user home: ${value}`);
}
if ((rust.match(/env::var_os\("HOME"\)/g) ?? []).length !== 1 || rust.includes('Path::new(&home).join(".eai-setup')) {
  throw new Error("Tauri adapter must not create managed files from a raw HOME environment value");
}
for (const value of ['command.env("HOME", &home)', 'command.env("npm_config_cache", home.join(".eai-setup/npm-cache"))', 'command.env_remove("HOME")', 'command.env_remove("npm_config_cache")']) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter lets a GUI child process inherit an invalid home: ${value}`);
}
for (const value of ["MIN_EAI_CLI_VERSION", "@enterpriseai/cli", "eai_cli_version()", "user_npm_global_exec_dirs", "current_version >= MIN_EAI_CLI_VERSION", "fn eai_cli_script", "APPDATA", "run_program_in_directory_with_env(\"node\", &node_args, directory, environment)"] ) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter does not verify the canonical EAI CLI release: ${value}`);
}
if (rust.includes("latest_eai_cli_requirement") || rust.includes('version("npm", &["view", "@enterpriseai/cli"')) {
  throw new Error("Tauri adapter must not use live npm metadata to decide whether the installed EAI CLI is ready");
}
const eaiResolver = rust.slice(rust.indexOf("fn executable"), rust.indexOf("fn run_program"));
if (eaiResolver.indexOf("user_npm_global_exec_dirs") > eaiResolver.indexOf("user_node_bin_dirs")) {
  throw new Error("Tauri adapter must prefer the user npm-prefix EAI launcher over stale Node-directory launchers");
}
const windowsIcon = await readFile(new URL("../src-tauri/icons/icon.ico", import.meta.url));
if (windowsIcon.length < 32 || windowsIcon.readUInt16LE(2) !== 1) {
  throw new Error("Tauri Windows icon resource is missing or invalid");
}
const windowsBuild = await readFile(new URL("../src-tauri/build.rs", import.meta.url), "utf8");
const windowsManifest = await readFile(new URL("../src-tauri/windows-app-manifest.xml", import.meta.url), "utf8");
if (!windowsBuild.includes('app_manifest(include_str!("windows-app-manifest.xml"))')) {
  throw new Error("Tauri build does not embed the Windows application manifest");
}
if (!windowsManifest.includes('requestedExecutionLevel level="asInvoker" uiAccess="false"')) {
  throw new Error("Windows app must run as the signed-in user and request elevation only for individual package operations");
}
if (!windowsManifest.includes('name="Microsoft.Windows.Common-Controls"') || !windowsManifest.includes('version="6.0.0.0"')) {
  throw new Error("Windows app manifest must preserve native Common Controls v6 support");
}
for (const step of ["homebrew", "git", "node", "eai-cli", "login", "init", "start"]) {
  if (!rust.includes(`\"${step}\"`)) throw new Error(`Tauri adapter is missing ${step}`);
}
for (const value of ["detect_ai_surfaces", "start_ai_surface", "install_ai_surface", "AiSurfaceInventory", "eai", "start", "--check"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing AI workspace handoff: ${value}`);
}
for (const value of ["get_company_tenants", "get_company_apps", "list_company_apps", "app", "tenant", "list", "--format", "json", "directMembership", "app_key", "--app-key"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing company workspace discovery: ${value}`);
}
const tenantListSource = rust.slice(rust.indexOf("fn list_company_tenants"), rust.indexOf("fn parse_company_tenants"));
if (tenantListSource.includes("list_company_apps")) {
  throw new Error("Tauri adapter must not load every workspace's apps during workspace discovery");
}
for (const value of ["run_eai_with_retries", "with_transient_retries", "is_transient_platform_error"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing bounded platform retry support: ${value}`);
}
if (rust.includes("let is_root") || rust.includes("if !is_root")) {
  throw new Error("Tauri adapter must allow directly assigned child company workspaces");
}
for (const value of ["E2eConfiguration", "get_e2e_configuration", "verify_e2e_auth", "write_e2e_receipt", "EAI_SETUP_E2E", "EAI_SETUP_E2E_RECEIPT_FILE"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing bounded release E2E support: ${value}`);
}
if (!rust.includes("@enterpriseai/cli")) throw new Error("Tauri adapter uses the wrong CLI package");
if (!rust.includes('run_program_in_directory_with_progress(&app, "init", "eai", &init_args_ref')) throw new Error("Tauri adapter does not run eai init non-interactively with live progress in the selected directory");
if (!rust.includes('"--no-install".to_string()')) throw new Error("Tauri adapter must keep dependency installation outside the nested CLI init process");
if (!rust.includes("fn npm_cli_script") || !rust.includes("fn run_npm_in_directory") || !rust.includes("node_modules/npm/bin/npm-cli.js")) {
  throw new Error("Tauri adapter does not provide a direct Node/npm launcher for Windows");
}
if (!rust.includes('run_npm_in_directory_with_progress(\n                        &app,\n                        "init",\n                        &["install", "--no-audit", "--no-fund"]')) {
  throw new Error("Tauri adapter does not install generated app dependencies through its platform-aware npm path");
}
if (!rust.includes('&[("HUSKY", "0")]')) {
  throw new Error("Tauri adapter must skip Git-hook setup during unattended app dependency installation");
}
for (const value of ["app_created: bool", "result.app_created = !existing_app", "result.project_directory = Some", "result.project_path = Some"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter does not preserve partial app creation evidence: ${value}`);
}
if (!rust.includes("\"--company-tenant\"")) throw new Error("Tauri adapter does not pass the selected company workspace to eai init");
if (!rust.includes("command.stdin(Stdio::null())")) throw new Error("Tauri adapter does not close child stdin for GUI-launched commands");
if (!rust.includes('run_program_in_directory_with_progress(&app, "login", "eai", &["login"], None)')) throw new Error("Tauri adapter does not run eai login with live progress");
for (const value of ["bootstrap-summary", "safe_build_summary", "capture_process_stream", "Downloaded the supported EAI app template.", "Installed the required project packages."]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing safe live build summaries: ${value}`);
}
for (const value of ["read_until(b'\\n'", "String::from_utf8_lossy", "process_stream_drains_and_decodes_non_utf8_output"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter does not safely drain process output: ${value}`);
}
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

const appSource = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");
for (const value of ["let e2eAppCreated = false", "e2eAppCreated = Boolean(result?.app_created)", "appCreated: e2eAppCreated", 'e2eAppCreated ? "project" : "app"']) {
  if (!appSource.includes(value)) throw new Error(`Desktop release receipt does not preserve app creation evidence: ${value}`);
}
if (!rust.includes('inventory.contract_version != "eai.ai-surfaces/v1"')) {
  throw new Error("Tauri adapter does not enforce the versioned AI surface contract");
}
for (const value of ["Homebrew.pkg", "/usr/sbin/pkgutil", "--check-signature", "with administrator privileges", "--stdinpass", "No Terminal window will open"]) {
  if (!rust.includes(value)) throw new Error(`Tauri adapter is missing native macOS installation control: ${value}`);
}
for (const value of ["windows_package_bin_dirs", "windows_resolved_path", "env::split_paths", "ProgramW6432", "ProgramFiles(Arm)", "ProgramFiles(x86)", "CREATE_NO_WINDOW", "creation_flags", "APPDATA", "windows_shell_arg", "ComSpec", "ends_with(\".cmd\")", "command_line.push_str", "call {}", "windows_package_install_result", "windows_vc_runtime_version", "Microsoft.VCRedist.2015+", "npm_version", "run_npm_in_directory(&[\"--version\"], None)", "Node.js and npm are already installed and ready.", "installed EAI CLI could not be started."]) {
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
if (!rust.includes("fn clean_process_output") || !rust.includes("character == '\\u{1b}'")) {
  throw new Error("Tauri adapter does not remove terminal control sequences from GUI diagnostics");
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

/* ------------------------------------------------------------------
   The wizard's structure, after the state-machine redesign.

   Every assertion below was one before it, aimed at the same problem in
   the wizard-panel version of this app. The screens changed; the things
   worth guarding did not. Where the old markup is gone entirely, the
   check moved to whatever now carries the same responsibility, and
   where a control was deliberately removed the check that it is gone
   is here so it does not creep back in.
------------------------------------------------------------------- */

const wizard = await readFile(new URL("../ui/index.html", import.meta.url), "utf8");
const machineSource = await readFile(new URL("../ui/state-machine.js", import.meta.url), "utf8");

/* The app's branding is the window and its icon, not a mark inside the
   screen. The prototype's sign-in is the head and nothing else: the
   operating system already calls the window Enterprise AI Setup and the
   title says it again where somebody is reading, so a logo on top of
   both is a third statement of the same fact. */
if (!wizard.includes("Sign in to Enterprise AI")) {
  throw new Error("wizard: the sign-in screen no longer names the product");
}
if (wizard.includes('class="eai-brand"') || wizard.includes("eai-square-man-logo")) {
  throw new Error("wizard: a mark is back above the sign-in title — the prototype's screen is the head and nothing else");
}
const tauriWindow = JSON.parse(await readFile(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"))
  .app?.windows?.[0];
if (tauriWindow?.title !== "Enterprise AI Setup") {
  throw new Error("wizard: the window no longer carries the product name, which is now the only place it is branded");
}
const bundleLogo = await readFile(new URL("../src-tauri/icons/icon.png", import.meta.url));
if (bundleLogo.length < 1024) throw new Error("bundle: Enterprise AI logo icon is missing or unexpectedly small");
const bundleLogoSource = await readFile(new URL("../src-tauri/icons/icon.svg", import.meta.url), "utf8");
for (const color of ["#123d5b", "#83d8ef"]) {
  if (!bundleLogoSource.includes(color)) throw new Error(`bundle: Enterprise AI logo source is missing ${color}`);
}

// The seven screens of the tested state machine, and the overlay the
// last one lands in.
for (const screen of ["signin", "welcome", "setup", "running", "done", "handoff"]) {
  if (!wizard.includes(`data-screen="${screen}"`)) throw new Error(`wizard: missing screen ${screen}`);
}
if (!wizard.includes('id="builtOverlay"')) throw new Error("wizard: the built state has no overlay");
// The panel model it replaced must not come back alongside it.
if (wizard.includes("data-panel=") || wizard.includes("wizard-panel")) {
  throw new Error("wizard: the old numbered panel model is back beside the state machine");
}

// Sign-in holds the readiness result and both of its ways out.
for (const value of ['id="checkRows"', 'id="setupSignin"', 'id="setupCreate"', 'id="signinSub"']) {
  if (!wizard.includes(value)) throw new Error(`wizard: sign-in is missing ${value}`);
}
if (!wizard.includes("Create an EAI account")) throw new Error("wizard: account signup action is missing");

// The browser hand-off can fail, and the screen that reports it has the
// pair of controls that failure needs.
for (const value of ['id="welcomeMark"', 'id="welcomeTitle"', 'id="welcomeSub"', 'id="welcomeActs"', 'id="welcomeCopy"', 'id="welcomeRetry"', "Copy the sign-in link"]) {
  if (!wizard.includes(value)) throw new Error(`wizard: signed-in beat is missing ${value}`);
}

// The form, revealed downwards, with its questions and its rail.
for (const value of ['data-step="workspace"', 'data-step="name"', 'data-step="folder"', 'id="wsRows"', 'id="projName"', 'id="projFolder"', 'id="chooseFolder"', 'id="chooseFolderStart"', 'id="createApp"', 'id="setupBack"']) {
  if (!wizard.includes(value)) throw new Error(`wizard: the setup form is missing ${value}`);
}
/* Three questions, and the app picker is not one of them: EAI Setup
   creates from the EAI template every time, so "new app, or one you
   already have" had one real answer. See docs/known-issues.md. */
if (wizard.includes('data-step="app"') || wizard.includes('id="appRows"')) {
  throw new Error("wizard: the app picker is back — the installer only ever creates from the EAI template");
}
if ((wizard.match(/data-step="/g) || []).length !== 3) {
  throw new Error("wizard: the setup form is no longer the three questions of the tested design");
}
/* The location question has two shapes and both have to exist: one
   button before an answer, the path and a way to change it after. */
if (!wizard.includes('id="chooseFolderStart">Choose location') || !wizard.includes('id="chooseFolder">Change location')) {
  throw new Error("wizard: the location question has lost one of its two shapes, or the two disagree about the noun");
}
if (!wizard.includes("Kebab case only")) throw new Error("wizard: the app name question does not say what shape a name is");
if (!wizard.includes("Choose a workspace")) throw new Error("wizard: missing company workspace selection");
if (!wizard.includes('id="createApp" disabled')) {
  throw new Error("wizard: the primary is enabled before the form has been answered");
}
for (const value of ['autocapitalize="none"', 'autocorrect="off"', 'spellcheck="false"']) {
  if (!wizard.includes(value)) throw new Error(`wizard: project name permits unwanted typing assistance: ${value}`);
}
// A workspace that could not be listed has a way to try again, and it
// lives on the question it belongs to rather than in a floating bar.
if (!wizard.includes('id="wsNote"') || !wizard.includes('id="wsRetry"')) {
  throw new Error("wizard: a failed workspace check has no retry beside the question it blocks");
}
const wsQuestionStart = wizard.indexOf('data-step="workspace"');
const wsQuestionEnd = wizard.indexOf('data-step="name"');
if (wizard.indexOf('id="wsRetry"') < wsQuestionStart || wizard.indexOf('id="wsRetry"') > wsQuestionEnd) {
  throw new Error("wizard: workspace retry has drifted away from the workspace question");
}

// Creating, as rows rather than a command log, with an honest retry.
for (const value of ['id="runLines"', 'id="runTitle"', 'id="runSub"', 'id="runNote"', 'id="runRetry"', 'id="runBack"']) {
  if (!wizard.includes(value)) throw new Error(`wizard: the creating screen is missing ${value}`);
}

// Choosing a harness, and the hand-off it leads to.
for (const value of ['id="harnessRows"', 'id="harnessSub"', 'id="harnessNote"', 'id="harnessGo"', 'id="harnessRefresh"', 'id="harnessBack"', "Choose how to work with AI", "Check again"]) {
  if (!wizard.includes(value)) throw new Error(`wizard: AI tool selection is missing ${value}`);
}
for (const value of ['id="handoffTitle"', 'id="handoffSub"', 'id="harnessEaiBody"', 'id="harnessVideo"', 'id="handoffGo"', 'id="handoffBack"', "<code>/eai</code>"]) {
  if (!wizard.includes(value)) throw new Error(`wizard: the hand-off instruction is missing ${value}`);
}
if (!wizard.includes('id="builtFolder"') || !wizard.includes('id="handoffFolder"')) {
  throw new Error("wizard: the finished project cannot be opened from the screens that end the flow");
}
// Harvey balls were removed on purpose: a pie chart scoring somebody
// else's product, on the screen where they choose it, was answering a
// question nobody asked. Grouped rows say the same thing in words.
for (const removed of ["harvey-ball", "recommendation-dialog", "How the Harvey ball is scored", "Harvey ball"]) {
  if (wizard.includes(removed)) throw new Error(`wizard: the Harvey ball scoring is back: ${removed}`);
}
if (!machineSource.includes("Ready on ") || !machineSource.includes("Not installed")) {
  throw new Error("wizard: the AI tool list no longer separates what is installed from what is not");
}
/* The round trip is three steps rather than a paragraph, and the third
   one is the one that matters: come back. The reassurance that nothing
   is lost by leaving now lives in the box that is on screen while they
   are away, which is when somebody needs it. */
for (const step of ["Download and install", "Sign in there with", "Come back to this app"]) {
  if (!machineSource.includes(step)) throw new Error(`wizard: the round trip is missing its step: ${step}`);
}
if (!machineSource.includes("nothing is lost if you")) {
  throw new Error("wizard: nothing reassures somebody that leaving does not lose the app they just created");
}

// The macOS-only password moment, and the record of what actually ran.
for (const control of ['id="adminPanel"', 'id="adminPassword"', 'id="adminSubmit"', 'id="adminCancel"', "does not open Terminal"]) {
  if (!wizard.includes(control)) throw new Error(`wizard: macOS Git authorisation is missing: ${control}`);
}
for (const control of ['id="diagnostics"', 'id="diagLog"', 'id="diagStatus"', "Setup details"]) {
  if (!wizard.includes(control)) throw new Error(`wizard: the record of what the installer did is missing: ${control}`);
}
// Every button in a screen is a button, not a submit in disguise.
for (const match of wizard.matchAll(/<button\b(?![^>]*type="button")[^>]*>/g)) {
  throw new Error(`wizard: a control can accidentally submit a form: ${match[0]}`);
}
if (wizard.includes('id="next-command"') || wizard.includes("completion-command")) {
  throw new Error("wizard: internal init command must not be shown on the completion screen");
}
for (const obsolete of ["progress-area", "Step 3 of 6", "Install missing tools", "I am signed in", 'id="install-items"']) {
  if (wizard.includes(obsolete)) throw new Error(`wizard: unnecessary user step remains: ${obsolete}`);
}

const app = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");

// The release receipt still knows whether a platform app was created.
if (!app.includes('writeE2eReceipt("app", "Apps could not be loaded for the release-test workspace.")')) {
  throw new Error("wizard: release evidence misclassifies app discovery as a tenant failure");
}
if (!app.includes("helpers.resolveTenantSelection(tenants, facts.selectedTenantId)")) {
  throw new Error("wizard: rendering can clear a valid release-test tenant selection");
}
if (app.includes('steps.push("homebrew")')) throw new Error("wizard: Homebrew must not be a required setup step");
if (app.includes("console.info(result.output)")) throw new Error("wizard: raw installer command output must not be written to the browser console");

// Raw exception text belongs in the record, never in a designed
// sentence. `note()` is the record; anything that paints a screen is not.
for (const line of app.split("\n")) {
  if (!/String\(error\)/.test(line)) continue;
  if (/writeE2eReceipt|console\.error/.test(line)) continue;
  throw new Error(`wizard: an unfiltered exception reaches the interface: ${line.trim()}`);
}
for (const value of ["helpers.cleanText(error)", "helpers.cleanText(result.message)"]) {
  if (!app.includes(value)) throw new Error(`wizard: diagnostics are not stripped of terminal control sequences: ${value}`);
}

// The wiring the flow cannot work without.
for (const value of [
  "listenForBootstrapProgress", "eventApi.listen", "bootstrap-progress", "bootstrap-summary", "bootstrap-signin-url",
  "detect_environment", "check_connectivity", "run_bootstrap", "get_company_tenants", "get_company_apps",
  "open_signup", "detect_ai_surfaces", "start_ai_surface", "install_ai_surface", "open_project", "write_e2e_receipt",
  "dialog.open", "companyTenantId", "appKey", "projectPath",
  "helpers.describeWorkspaceFailure", "helpers.describeAppFailure", "helpers.describeInitFailure",
  "helpers.summarizeCommandOutput", "helpers.prerequisitesReady", "helpers.isKebabCase", "helpers.chooseAiSurface",
  "machine.faultsInForce", "machine.setupSteps", "machine.runRows", "machine.harnessGroups", "machine.classifyBootstrapFailure",
  "function reset()", "function paint()", "requestMacAdminPassword", "startHarnessPoll", "stopHarnessPoll",
]) {
  if (!app.includes(value)) throw new Error(`wizard: the state-machine driver is missing ${value}`);
}
// paint() must always rebuild from the reset, never patch what was left.
if (!/function paint\(\)[\s\S]{0,900}?\breset\(\);/.test(app)) {
  throw new Error("wizard: paint() no longer resets before it draws, so a state can be half-applied");
}
/* Readiness attempts every missing prerequisite and reports them
   together, rather than stopping at the first. The one exception is a
   tool that needed the failed one: the EAI CLI is installed with npm, so
   blaming it when Node is missing names the wrong thing. */
if (!/for \(const step of missingSteps\(\)\)[\s\S]{0,600}?failed\.push\(step\)/.test(app)) {
  throw new Error("wizard: the readiness sweep no longer collects the failures it finds");
}
if (!app.includes('raise("prereq", { steps: failed })')) {
  throw new Error("wizard: the prerequisite failure no longer names every tool that failed");
}
if (!/step === "eai-cli" && failed\.includes\("node"\)/.test(app)) {
  throw new Error("wizard: the EAI CLI is attempted after Node failed, which blames the wrong tool");
}

// The waiting box promises the screen updates by itself. It has to.
if (!app.includes("setInterval") || !app.includes("waitingForSurfaceId")) {
  throw new Error("wizard: the waiting state does not actually watch for the tool to land");
}
if (!/stopHarnessPoll\(\);/.test(app.slice(app.indexOf("function startHarnessPoll")))) {
  throw new Error("wizard: the waiting poll is never stopped");
}
// Setup begins on its own; the buttons are the accessible fallback.
if (!app.includes("start();")) throw new Error("wizard: the app never starts itself");

const wizardState = await readFile(new URL("../ui/wizard-state.js", import.meta.url), "utf8");
if (!wizardState.includes("prerequisitesReady") || !wizardState.includes("isKebabCase") || !wizardState.includes("describeInitFailure") || !wizardState.includes("Windows dependency setup needs attention") || !wizardState.includes("App dependencies need attention")) {
  throw new Error("wizard: state validation contract is missing");
}
if (!machineSource.includes("root.EAISetup") || !machineSource.includes("function createState()")) {
  throw new Error("wizard: the state machine module does not register");
}

const styles = await readFile(new URL("../ui/styles.css", import.meta.url), "utf8");
if (!styles.includes("summary::marker") || !styles.includes("summary::-webkit-details-marker")) {
  throw new Error("wizard: accordion markers are not hidden consistently across desktop webviews");
}
if (!styles.includes("prefers-reduced-motion")) {
  throw new Error("wizard: the reveal and the spinner do not respect a reduced-motion preference");
}

console.log("wizard structure checks ok");

const bundles = await readFile(new URL("../.github/workflows/test-bundles.yml", import.meta.url), "utf8");
for (const value of ["Windows", "macOS", "Ubuntu", "bundle: nsis", "bundle: dmg", "bundle: deb", "actions/upload-artifact@v6", "actions/download-artifact@v5", "tauri-apps/tauri-action@v1", "Smoke-test Windows installer", "Smoke-test macOS disk image", "Smoke-test Ubuntu package"]) {
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
for (const value of ["workflow_dispatch", "gh release create", "gh release upload", "actions/download-artifact@v5", "tauri-apps/tauri-action@v1", "eai-setup-macos-arm64.dmg", "eai-setup-macos-x64.dmg", "eai-setup-windows-x64.exe", "eai-setup-windows-arm64.exe", "eai-setup-ubuntu-amd64.deb", "eai-setup-ubuntu-arm64.deb", "x86_64-apple-darwin", "aarch64-pc-windows-msvc", "ubuntu-24.04-arm"]) {
  if (!testRelease.includes(value)) throw new Error(`test-release workflow is missing: ${value}`);
}
const release = await readFile(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
for (const value of ["Add stable direct-download assets", "tauri-apps/tauri-action@v1", "eai-setup-macos-arm64.dmg", "eai-setup-macos-x64.dmg", "eai-setup-windows-x64.exe", "eai-setup-windows-arm64.exe", "eai-setup-ubuntu-amd64.deb", "eai-setup-ubuntu-arm64.deb", "x86_64-apple-darwin", "aarch64-pc-windows-msvc", "ubuntu-24.04-arm", "codesign --verify --deep --strict", "spctl --assess --type execute", "xcrun stapler validate", "Get-AuthenticodeSignature"]) {
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
