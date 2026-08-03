const output = document.querySelector("#output");
const platform = document.querySelector("#platform");
const panels = [...document.querySelectorAll("[data-panel]")];
const progressItems = [...document.querySelectorAll("[data-progress]")];
const progressLabel = document.querySelector("#progress-label");
const progressName = document.querySelector("#progress-name");
const progressBar = document.querySelector("#progress-bar");
const progressTrack = document.querySelector(".progress-track");
const environmentSummary = document.querySelector("#environment-summary");
const prerequisiteNote = document.querySelector("#prerequisite-note");
const completeMessage = document.querySelector("#complete-message");
const nextCommand = document.querySelector("#next-command");

const stepNames = ["Welcome", "Computer", "Prerequisites", "Sign in", "App", "Complete"];
const wizard = EAIWizard.createState();
let environmentReport = null;
let demoMode = false;

function show(message, detail = "") {
  output.textContent = detail ? `${message} ${detail}` : message;
}

async function invoke(command, args = {}) {
  const tauri = window.__TAURI__;
  if (!tauri?.core?.invoke) {
    return { ok: true, demo: true, message: "Preview mode: install actions run in the signed EAI Setup app." };
  }
  return tauri.core.invoke(command, args);
}

function setStep(step) {
  wizard.step = EAIWizard.clampStep(step);
  for (const panel of panels) {
    const active = Number(panel.dataset.panel) === wizard.step;
    panel.hidden = !active;
    panel.classList.toggle("current", active);
  }
  for (const item of progressItems) {
    const itemStep = Number(item.dataset.progress);
    item.classList.toggle("current", itemStep === wizard.step);
    item.classList.toggle("complete", itemStep < wizard.step);
  }
  progressLabel.textContent = `Step ${wizard.step + 1} of ${stepNames.length}`;
  progressName.textContent = stepNames[wizard.step];
  progressBar.style.width = `${(wizard.step / (stepNames.length - 1)) * 100}%`;
  progressTrack.setAttribute("aria-valuenow", String(wizard.step + 1));
  if (wizard.step === 1) detect();
}

function updateEnvironmentSummary(report) {
  if (demoMode) {
    environmentSummary.textContent = "Browser preview only. Open the signed desktop app to inspect and change this computer.";
    return;
  }
  const installed = report.tools.filter((tool) => tool.version).length;
  environmentSummary.textContent = `${report.platform} · ${report.architecture} · ${installed} of ${report.tools.length} required tools detected`;
}

function setToolState(report) {
  const toolMap = new Map(report.tools.map((tool) => [tool.command, tool]));
  for (const tool of report.tools) {
    const displayId = tool.command === "eai" ? "eai-cli" : tool.command;
    const state = document.querySelector(`#${displayId}-state`);
    const badge = document.querySelector(`#${displayId}-badge`);
    if (state) state.textContent = tool.version ? `Installed: ${tool.version}` : "Not installed";
    if (badge) {
      badge.textContent = tool.version ? "Ready" : "Needs install";
      badge.classList.toggle("ready", Boolean(tool.version));
    }
  }
  const brew = document.querySelector("#homebrew-state");
  const brewBadge = document.querySelector("#homebrew-badge");
  const homebrewInstalled = report.package_manager === "brew";
  if (brew) brew.textContent = report.platform === "macos" ? (homebrewInstalled ? "Installed" : "Not installed") : "Not required on this platform";
  if (brewBadge) {
    const brewReady = report.platform !== "macos" || homebrewInstalled || !EAIWizard.needsHomebrew(report, toolMap);
    brewBadge.textContent = brewReady ? "Ready" : "Needs install";
    brewBadge.classList.toggle("ready", brewReady);
  }
  platform.textContent = `${report.platform} · ${report.architecture}`;
  updateEnvironmentSummary(report);
  wizard.prerequisitesReady = EAIWizard.prerequisitesReady(report, demoMode);
  document.querySelector('[data-next="3"]').disabled = !wizard.prerequisitesReady;
}

function showPreviewState() {
  demoMode = true;
  platform.textContent = "Desktop preview";
  updateEnvironmentSummary(null);
  for (const id of ["homebrew", "git", "node", "eai-cli"]) {
    const state = document.querySelector(`#${id}-state`);
    const badge = document.querySelector(`#${id}-badge`);
    if (state) state.textContent = "Preview only";
    if (badge) {
      badge.textContent = "Preview";
      badge.classList.add("ready");
    }
  }
  wizard.prerequisitesReady = true;
  document.querySelector('[data-next="3"]').disabled = false;
}

async function detect() {
  try {
    const report = await invoke("detect_environment");
    if (report.demo) {
      showPreviewState();
      return;
    }
    demoMode = false;
    environmentReport = report;
    setToolState(report);
  } catch (error) {
    show("Could not inspect this computer.", String(error));
    environmentSummary.textContent = "The computer check failed. Retry before continuing.";
  }
}

async function runBootstrapStep(step) {
  const result = await invoke("run_bootstrap", { step, projectName: null, directory: null });
  if (result.output) console.info(result.output);
  if (!result.ok && !result.demo) {
    show(result.message || "This setup step failed.", result.command ? `Next: ${result.command}` : "");
    return false;
  }
  return true;
}

async function installPrerequisites() {
  if (demoMode) {
    prerequisiteNote.textContent = "Preview mode: the signed desktop app will perform these installations after confirmation.";
    show("Preview only: no changes were made to this computer.");
    return;
  }
  if (!environmentReport) await detect();
  if (!environmentReport) return;
  const toolMap = new Map(environmentReport.tools.map((tool) => [tool.command, tool]));
  const steps = [];
  if (EAIWizard.needsHomebrew(environmentReport, toolMap)) steps.push("homebrew");
  if (!toolMap.get("git")?.version) steps.push("git");
  if (!toolMap.get("node")?.version || !toolMap.get("npm")?.version) steps.push("node");
  if (!toolMap.get("eai")?.version) steps.push("eai-cli");
  if (!steps.length) {
    prerequisiteNote.textContent = "Everything required is already installed.";
    wizard.prerequisitesReady = true;
    document.querySelector('[data-next="3"]').disabled = false;
    show("All prerequisites are ready.");
    return;
  }
  for (const step of steps) {
    prerequisiteNote.textContent = `Installing ${step === "eai-cli" ? "the EAI CLI" : step}...`;
    if (!await runBootstrapStep(step)) return;
    await detect();
  }
  if (environmentReport) setToolState(environmentReport);
  if (wizard.prerequisitesReady) {
    prerequisiteNote.textContent = "All prerequisites are ready.";
    show("Prerequisites installed successfully.");
  } else {
    show("Some prerequisites still need attention. Retry the installation step.");
  }
}

async function runLogin() {
  const result = await runBootstrapStep("login");
  if (result) show(demoMode ? "Preview only: the signed app will open browser sign-in." : "Browser sign-in completed.");
}

async function runInit() {
  const name = document.querySelector("#project-name").value.trim();
  const directory = document.querySelector("#project-directory").value.trim();
  if (!EAIWizard.isKebabCase(name)) {
    show("Use a kebab-case project name, for example my-eai-app.");
    document.querySelector("#project-name").focus();
    return;
  }
  const result = await invoke("run_bootstrap", { step: "init", projectName: name, directory: directory || null });
  if (!result.ok && !result.demo) {
    show(result.message || "App initialisation failed.", result.command ? `Next: ${result.command.replace("<project-name>", name)}` : "");
    return;
  }
  completeMessage.textContent = result.demo
    ? "Preview complete. The signed desktop app will run eai init in the selected folder."
    : `The ${name} app was initialised successfully.`;
  nextCommand.textContent = result.command ? result.command.replace("<project-name>", name) : "eai whoami";
  wizard.projectName = name;
  setStep(5);
  show("Setup complete.");
}

async function runAction(action) {
  if (action === "detect") return detect();
  if (action === "install-all") return installPrerequisites();
  if (action === "login") return runLogin();
  if (action === "init") return runInit();
  if (action === "finish") show("You can close this window.");
}

for (const button of document.querySelectorAll("[data-next]")) {
  button.addEventListener("click", () => setStep(Number(button.dataset.next)));
}
for (const button of document.querySelectorAll("[data-back]")) {
  button.addEventListener("click", () => setStep(Number(button.dataset.back)));
}
for (const button of document.querySelectorAll("[data-action]")) {
  button.addEventListener("click", () => runAction(button.dataset.action));
}

setStep(0);
detect();
