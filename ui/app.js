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
const activity = document.querySelector("#activity");
const activityTitle = document.querySelector("#activity-title");
const activityDetail = document.querySelector("#activity-detail");
const activityBar = document.querySelector("#activity-bar");
const activityTrack = document.querySelector(".activity-track");

const stepNames = ["Welcome", "Computer", "Prerequisites", "Sign in", "App", "Complete"];
const wizard = EAIWizard.createState();
let environmentReport = null;
let demoMode = false;

function show(message, detail = "") {
  output.textContent = detail ? `${message} ${detail}` : message;
}

function setActivity(title, detail, progress = null, active = true) {
  activity.hidden = !active;
  activityTitle.textContent = title;
  activityDetail.textContent = detail;
  activity.classList.toggle("complete", !active || progress === 100);
  if (progress === null) {
    activityTrack.removeAttribute("aria-valuenow");
    activityBar.classList.add("indeterminate");
  } else {
    const value = Math.max(0, Math.min(100, progress));
    activityTrack.setAttribute("aria-valuenow", String(value));
    activityBar.style.width = `${value}%`;
    activityBar.classList.remove("indeterminate");
  }
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
  setActivity("Checking this computer", "Looking for Git, Node.js, npm, and the EAI CLI.", null);
  try {
    const report = await invoke("detect_environment");
    if (report.demo) {
      showPreviewState();
      setActivity("Computer check complete", "Preview mode is ready. No changes were made.", 100, false);
      return true;
    }
    demoMode = false;
    environmentReport = report;
    setToolState(report);
    setActivity("Computer check complete", `${report.platform} is ready for the prerequisite check.`, 100, false);
    return true;
  } catch (error) {
    show("Could not inspect this computer.", String(error));
    environmentSummary.textContent = "The computer check failed. Retry before continuing.";
    setActivity("Computer check needs attention", "Retry the check before continuing.", 0, false);
    return false;
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
    setActivity("Preview only", "The signed desktop app performs installation after confirmation.", 100, false);
    return true;
  }
  if (!environmentReport) await detect();
  if (!environmentReport) return false;
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
    setActivity("Everything is ready", "Git, Node.js, npm, and the EAI CLI are already installed.", 100, false);
    return true;
  }
  setActivity("Preparing installation", `${steps.length} prerequisite${steps.length === 1 ? "" : "s"} need attention.`, 0);
  for (const [index, step] of steps.entries()) {
    const name = step === "eai-cli" ? "the EAI CLI" : step === "node" ? "Node.js and npm" : step;
    const start = Math.round((index / steps.length) * 100);
    prerequisiteNote.textContent = `Installing ${name}...`;
    setActivity(`Installing ${name}`, `Step ${index + 1} of ${steps.length}. This can take a few minutes.`, start);
    if (!await runBootstrapStep(step)) return false;
    await detect();
    setActivity(`${name} installed`, `Step ${index + 1} of ${steps.length} is complete.`, Math.round(((index + 1) / steps.length) * 100));
  }
  if (environmentReport) setToolState(environmentReport);
  if (wizard.prerequisitesReady) {
    prerequisiteNote.textContent = "All prerequisites are ready.";
    show("Prerequisites installed successfully.");
    setActivity("Installation complete", "All required tools are ready. Continue to sign in.", 100, false);
    return true;
  } else {
    show("Some prerequisites still need attention. Retry the installation step.");
    setActivity("Installation needs attention", "Retry the installation step after reviewing the tool statuses.", 0, false);
    return false;
  }
}

async function startSetup() {
  setStep(1);
  if (!await detect()) return;
  setStep(2);
  if (await installPrerequisites()) setStep(3);
}

async function runLogin() {
  setActivity("Opening secure sign-in", "Your browser will handle EAI authentication. The installer does not see your password.", null);
  const result = await runBootstrapStep("login");
  if (result) {
    show(demoMode ? "Preview only: the signed app will open browser sign-in." : "Browser sign-in completed.");
    setActivity("Sign-in complete", "Return here to start your EAI app.", 100, false);
  } else {
    setActivity("Sign-in needs attention", "Complete browser sign-in, then retry.", 0, false);
  }
}

async function runInit() {
  const name = document.querySelector("#project-name").value.trim();
  const directory = document.querySelector("#project-directory").value.trim();
  if (!EAIWizard.isKebabCase(name)) {
    show("Use a kebab-case project name, for example my-eai-app.");
    document.querySelector("#project-name").focus();
    return;
  }
  setActivity("Creating your EAI app", `Initialising ${name} and fetching the supported Gofer assets.`, null);
  const result = await invoke("run_bootstrap", { step: "init", projectName: name, directory: directory || null });
  if (!result.ok && !result.demo) {
    show(result.message || "App initialisation failed.", result.command ? `Next: ${result.command.replace("<project-name>", name)}` : "");
    setActivity("App setup needs attention", "Review the message below and retry the app step.", 0, false);
    return;
  }
  completeMessage.textContent = result.demo
    ? "Preview complete. The signed desktop app will run eai init in the selected folder."
    : `The ${name} app was initialised successfully.`;
  nextCommand.textContent = result.command ? result.command.replace("<project-name>", name) : "eai whoami";
  wizard.projectName = name;
  setStep(5);
  setActivity("Setup complete", "Your EAI app and developer tools are ready.", 100, false);
  show("Setup complete.");
}

async function runAction(action) {
  if (action === "start") return startSetup();
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
