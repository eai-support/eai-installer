const output = document.querySelector("#output");
const platform = document.querySelector("#platform");
const panels = [...document.querySelectorAll("[data-panel]")];
const completeMessage = document.querySelector("#complete-message");
const nextCommand = document.querySelector("#next-command");
const activity = document.querySelector("#activity");
const activityTitle = document.querySelector("#activity-title");
const activityDetail = document.querySelector("#activity-detail");
const activityBar = document.querySelector("#activity-bar");
const activityTrack = document.querySelector(".activity-track");
const retryInstall = document.querySelector("#retry-install");

const wizard = EAIWizard.createState();
let environmentReport = null;
let demoMode = false;

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

function showOutput(message, detail = "") {
  output.hidden = false;
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
}

function setToolState(report) {
  platform.textContent = `${report.platform} · ${report.architecture}`;
  wizard.prerequisitesReady = EAIWizard.prerequisitesReady(report, demoMode);
  if (retryInstall) retryInstall.hidden = true;
}

function showPreviewState() {
  demoMode = true;
  platform.textContent = "Desktop preview";
  wizard.prerequisitesReady = true;
  if (retryInstall) retryInstall.hidden = true;
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
    showOutput("Could not inspect this computer.", String(error));
    if (retryInstall) retryInstall.hidden = false;
    setActivity("Computer check needs attention", "Retry setup to try again.", 0, false);
    return false;
  }
}

async function runBootstrapStep(step) {
  const result = await invoke("run_bootstrap", { step, projectName: null, directory: null });
  if (result.output) console.info(result.output);
  if (!result.ok && !result.demo) {
    showOutput(result.message || "This setup step failed.", result.command ? `Next: ${result.command}` : "");
    return false;
  }
  return true;
}

async function installPrerequisites() {
  if (demoMode) {
    showOutput("Preview only: no changes were made to this computer.");
    setActivity("Preview only", "The signed desktop app will install only what is missing.", 100, false);
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
    wizard.prerequisitesReady = true;
    if (retryInstall) retryInstall.hidden = true;
    showOutput("All prerequisites are ready.");
    setActivity("Everything is ready", "Git, Node.js, npm, and the EAI CLI are already installed.", 100, false);
    return true;
  }
  setActivity("Preparing installation", `${steps.length} prerequisite${steps.length === 1 ? "" : "s"} need attention.`, 0);
  for (const [index, step] of steps.entries()) {
    const name = step === "eai-cli" ? "the EAI CLI" : step === "node" ? "Node.js and npm" : step;
    const start = Math.round((index / steps.length) * 100);
    setActivity(`Installing ${name}`, "This can take a few minutes.", start);
    if (!await runBootstrapStep(step)) {
      if (retryInstall) retryInstall.hidden = false;
      return false;
    }
    await detect();
    setActivity(`${name} installed`, "Continuing setup.", Math.round(((index + 1) / steps.length) * 100));
  }
  if (environmentReport) setToolState(environmentReport);
  if (wizard.prerequisitesReady) {
    showOutput("Prerequisites installed successfully.");
    setActivity("Installation complete", "All required tools are ready. Continue to sign in.", 100, false);
    return true;
  } else {
    if (retryInstall) retryInstall.hidden = false;
    showOutput("Some prerequisites still need attention. Try again.");
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
    showOutput(demoMode ? "Preview only: the signed app will open browser sign-in." : "Browser sign-in completed.");
    setActivity("Sign-in complete", "Continuing to app setup.", 100, false);
    setStep(4);
  } else {
    setActivity("Sign-in needs attention", "Complete browser sign-in, then try again.", 0, false);
  }
}

async function runInit() {
  const name = document.querySelector("#project-name").value.trim();
  const directory = document.querySelector("#project-directory").value.trim();
  if (!EAIWizard.isKebabCase(name)) {
    showOutput("Use a kebab-case project name, for example my-eai-app.");
    document.querySelector("#project-name").focus();
    return;
  }
  setActivity("Creating your EAI app", `Initialising ${name} and fetching the supported Gofer assets.`, null);
  const result = await invoke("run_bootstrap", { step: "init", projectName: name, directory: directory || null });
  if (!result.ok && !result.demo) {
    showOutput(result.message || "App initialisation failed.", result.command ? `Next: ${result.command.replace("<project-name>", name)}` : "");
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
  showOutput("Setup complete.");
}

async function runAction(action) {
  if (action === "start") return startSetup();
  if (action === "detect") return detect();
  if (action === "install-all") return installPrerequisites();
  if (action === "login") return runLogin();
  if (action === "init") return runInit();
  if (action === "finish") showOutput("You can close this window.");
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
