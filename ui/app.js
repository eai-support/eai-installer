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
const activityPhase = document.querySelector("#activity-phase");
const activityEta = document.querySelector("#activity-eta");
const activityHeartbeat = document.querySelector("#activity-heartbeat");
const installItems = document.querySelector("#install-items");
const activityLog = document.querySelector("#activity-log");
const activityLogStatus = document.querySelector("#activity-log-status");
const retryInstall = document.querySelector("#retry-install");
const adminPasswordPanel = document.querySelector("#admin-password-panel");
const adminPasswordInput = document.querySelector("#admin-password");
const adminPasswordSubmit = document.querySelector("#admin-password-submit");
const adminPasswordCancel = document.querySelector("#admin-password-cancel");

const wizard = EAIWizard.createState();
let environmentReport = null;
let demoMode = false;
let setupStarted = false;
let activeBootstrapStep = null;
let activityTicker = null;
let activityStartedAt = 0;
let activityLastUpdateAt = 0;
let activityLastHeartbeatLogAt = 0;
let pendingAdminPassword = null;
const activityEvents = [];

const stepLabels = {
  git: "Git",
  node: "Node.js and npm",
  "eai-cli": "EAI CLI",
};

const prerequisiteSteps = ["git", "node", "eai-cli"];

const stepEstimates = {
  git: 45,
  node: 75,
  "eai-cli": 45,
};

function formatEta(seconds) {
  if (seconds === null || seconds === undefined) return "";
  if (seconds <= 0) return "Finishing";
  if (seconds < 60) return `Typical duration: under ${seconds} seconds`;
  return `Typical duration: about ${Math.ceil(seconds / 60)} minutes`;
}

function activityCategory(title, phase) {
  if (/error|fail|attention/i.test(title) || phase === "Error") return "Error";
  if (/wait|permission/i.test(title) || phase === "Waiting") return "Waiting";
  if (/download/i.test(title) || phase === "Downloading") return "Download";
  if (/install|prepar/i.test(title) || phase === "Installing") return "Install";
  if (/ready|complete/i.test(title) || phase === "Ready") return "Ready";
  return phase || "Update";
}

function renderActivityLog() {
  if (!activityLog) return;
  activityLog.replaceChildren();
  for (const event of [...activityEvents].reverse()) {
    const item = document.createElement("li");
    item.dataset.category = event.category.toLowerCase();
    const timestamp = document.createElement("time");
    timestamp.textContent = new Date(event.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" });
    const category = document.createElement("strong");
    category.textContent = event.category;
    const message = document.createElement("span");
    message.textContent = `${event.title}: ${event.detail}`;
    item.append(timestamp, category, message);
    activityLog.append(item);
  }
}

function recordActivityEvent(title, detail, phase) {
  const previous = activityEvents.at(-1);
  if (previous?.title === title && previous.detail === detail) return;
  activityEvents.push({ at: Date.now(), category: activityCategory(title, phase), title, detail });
  if (activityEvents.length > 8) activityEvents.shift();
  renderActivityLog();
}

function setActivity(title, detail, progress = null, active = true, eta = "", phase = "") {
  activityLastUpdateAt = Date.now();
  // Keep the activity log visible after a failure so the user can see the last
  // successful action and the exact step that needs attention.
  activity.hidden = !active && phase !== "Error";
  activityTitle.textContent = title;
  activityDetail.textContent = detail;
  activityPhase.textContent = phase || (progress === null ? "In progress" : `${progress}% complete`);
  activityEta.textContent = eta;
  activity.classList.toggle("complete", progress === 100);
  activity.classList.toggle("error", phase === "Error");
  if (activityLogStatus) activityLogStatus.textContent = phase === "Error" ? "Stopped with error" : active ? "Live updates" : progress === 100 ? "Complete" : "Stopped";
  recordActivityEvent(title, detail, phase);
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

const waitingDetails = {
  detect: "Checking the required tools.",
  git: "Checking Apple Software Update for the minimal Command Line Tools package. No Terminal window is needed.",
  node: "Downloading or validating the official Node.js package.",
  "eai-cli": "Downloading the EAI CLI package from npm.",
  login: "Waiting for browser sign-in.",
  init: "Waiting for app setup to finish.",
};

function refreshActivityHeartbeat() {
  if (!activityHeartbeat || !activityStartedAt) return;
  const now = Date.now();
  const elapsed = Math.max(0, Math.floor((now - activityStartedAt) / 1000));
  const sinceUpdate = Math.max(0, Math.floor((now - activityLastUpdateAt) / 1000));
  const updateAge = sinceUpdate === 0 ? "just now" : `${sinceUpdate}s ago`;
  const waitingForAdmin = adminPasswordPanel && !adminPasswordPanel.hidden;
  activityHeartbeat.textContent = waitingForAdmin
    ? `Elapsed ${elapsed}s · Screen updated every second · Waiting for your input`
    : `Elapsed ${elapsed}s · Screen updated every second · Last installer update ${updateAge}`;
  if (waitingForAdmin) {
    if (elapsed >= 5 && elapsed - activityLastHeartbeatLogAt >= 5) {
      activityLastHeartbeatLogAt = elapsed;
      recordActivityEvent("Action needed", "Enter your Mac login password to authorize the Git installation. It is used once and never saved.", "Waiting");
    }
    activityPhase.textContent = "Action needed";
    return;
  }
  if (elapsed >= 5 && elapsed - activityLastHeartbeatLogAt >= 5) {
    activityLastHeartbeatLogAt = elapsed;
    recordActivityEvent(
      "Still working",
      `${activityTitle.textContent}: ${activityDetail.textContent} (${elapsed}s elapsed; the installer is still being checked)`,
      "In progress",
    );
  }
  if (sinceUpdate >= 10 && !activity.classList.contains("complete") && activeBootstrapStep) {
    if (activeBootstrapStep === "git" && /installing git/i.test(activityTitle.textContent)) {
      activityDetail.textContent = "Apple Software Update is still installing Git. EAI Setup is checking for Git every second; the next status will appear here.";
    } else {
      activityDetail.textContent = waitingDetails[activeBootstrapStep] || "The installer is still working and will show the next result here.";
    }
    activityPhase.textContent = "Working - no action needed";
  }
}

function startActivityHeartbeat(step) {
  if (activityTicker) clearInterval(activityTicker);
  activeBootstrapStep = step;
  activityStartedAt = Date.now();
  activityLastUpdateAt = activityStartedAt;
  activityLastHeartbeatLogAt = 0;
  refreshActivityHeartbeat();
  activityTicker = setInterval(refreshActivityHeartbeat, 1000);
}

function stopActivityHeartbeat() {
  if (activityTicker) clearInterval(activityTicker);
  activityTicker = null;
  if (activityHeartbeat && activityStartedAt) {
    const elapsed = Math.max(0, Math.floor((Date.now() - activityStartedAt) / 1000));
    activityHeartbeat.textContent = `Finished after ${elapsed}s`;
  }
  activityStartedAt = 0;
}

function requestMacAdminPassword() {
  if (!adminPasswordPanel || !adminPasswordInput || !adminPasswordSubmit || !adminPasswordCancel) return Promise.resolve(null);
  adminPasswordPanel.hidden = false;
  adminPasswordInput.value = "";
  adminPasswordInput.focus();
  setActivity("Authorize Git installation", "Enter your Mac login password once. EAI Setup uses it only for Apple's minimal Git tools, never saves it, and does not open Terminal.", null, true, "", "Waiting");
  return new Promise((resolve) => {
    pendingAdminPassword = resolve;
    adminPasswordSubmit.onclick = () => {
      const password = adminPasswordInput.value;
      if (!password) return;
      adminPasswordPanel.hidden = true;
      adminPasswordInput.value = "";
      const finish = pendingAdminPassword;
      pendingAdminPassword = null;
      finish(password);
    };
    adminPasswordCancel.onclick = () => {
      adminPasswordPanel.hidden = true;
      adminPasswordInput.value = "";
      const finish = pendingAdminPassword;
      pendingAdminPassword = null;
      finish(null);
    };
  });
}

function renderInstallItems(steps) {
  installItems.replaceChildren();
  for (const step of steps) {
    const item = document.createElement("li");
    item.className = "install-item";
    item.dataset.step = step;
    item.dataset.state = "pending";
    const name = document.createElement("span");
    name.textContent = stepLabels[step] || step;
    const detail = document.createElement("span");
    detail.className = "install-item-detail";
    detail.textContent = "Waiting";
    item.append(name, detail);
    installItems.append(item);
  }
  installItems.hidden = steps.length === 0;
}

function setInstallItemState(step, state, detailText) {
  const item = installItems.querySelector(`[data-step="${step}"]`);
  if (!item) return;
  item.dataset.state = state;
  item.lastElementChild.textContent = detailText;
}

function setDetectionState(report) {
  const tools = new Map(report.tools.map((tool) => [tool.command, tool]));
  const gitReady = Boolean(tools.get("git")?.version);
  const nodeReady = Boolean(tools.get("node")?.version && tools.get("npm")?.version);
  const eaiReady = Boolean(tools.get("eai")?.version);
  setInstallItemState("git", gitReady ? "done" : "pending", gitReady ? tools.get("git").version : "Not installed");
  setInstallItemState("node", nodeReady ? "done" : "pending", nodeReady ? `Node ${tools.get("node").version} / npm ready` : "Not installed");
  setInstallItemState("eai-cli", eaiReady ? "done" : "pending", eaiReady ? tools.get("eai").version : "Not installed");
}

function phaseForTitle(title) {
  if (/waiting|permission/i.test(title)) return "Waiting for permission";
  if (/download/i.test(title)) return "Downloading";
  if (/check|verify/i.test(title)) return "Verifying";
  if (/install|prepar|finish/i.test(title)) return "Installing";
  if (/ready|complete/i.test(title)) return "Ready";
  return "In progress";
}

async function listenForBootstrapProgress() {
  const eventApi = window.__TAURI__?.event;
  if (!eventApi?.listen || window.__eaiBootstrapProgressListener) return;
  window.__eaiBootstrapProgressListener = await eventApi.listen("bootstrap-progress", ({ payload }) => {
    if (!activeBootstrapStep || payload.step !== activeBootstrapStep) return;
    setActivity(payload.title, payload.detail, payload.progress ?? null, true, formatEta(payload.estimatedSeconds), phaseForTitle(payload.title));
    setInstallItemState(payload.step, /ready|complete/i.test(payload.title) ? "done" : "active", phaseForTitle(payload.title));
  });
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
  renderInstallItems(prerequisiteSteps);
  for (const step of prerequisiteSteps) setInstallItemState(step, "active", "Checking");
  setActivity("Checking this computer", "Checking the required tools.", null, true, "", "Checking");
  startActivityHeartbeat("detect");
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
    setDetectionState(report);
    setActivity("Computer check complete", `${report.platform} is ready. Missing items are shown below.`, 100, false, "", "Complete");
    return true;
  } catch (error) {
    showOutput("Could not inspect this computer.", String(error));
    if (retryInstall) retryInstall.hidden = false;
    setActivity("Computer check failed", `The computer check could not finish: ${String(error)}`, 0, false, "", "Error");
    return false;
  } finally {
    stopActivityHeartbeat();
  }
}

async function runBootstrapStep(step) {
  activeBootstrapStep = step;
  await listenForBootstrapProgress();
  startActivityHeartbeat(step);
  let result;
  try {
    const adminPassword = step === "git" && environmentReport?.platform === "macos" ? await requestMacAdminPassword() : null;
    if (step === "git" && environmentReport?.platform === "macos" && !adminPassword) {
      showOutput("Mac approval was cancelled. No tools were changed.", "Next: enter the Mac password and allow installation to retry.");
      setActivity("Git setup cancelled", "No changes were made. Enter the Mac password to retry the Apple Command Line Tools installation.", 0, false, "", "Error");
      return false;
    }
    result = await invoke("run_bootstrap", { step, projectName: null, directory: null, adminPassword });
  } catch (error) {
    showOutput("This setup step could not start.", String(error));
    setActivity(`${stepLabels[step] || step} setup failed`, `The step could not finish: ${String(error)}`, 0, false, "", "Error");
    return false;
  } finally {
    stopActivityHeartbeat();
    activeBootstrapStep = null;
  }
  if (result.output) console.info(result.output);
  if (!result.ok && !result.demo) {
    const message = result.message || "This setup step failed.";
    showOutput(message, result.command ? `Next: ${result.command}` : "");
    setActivity(`${stepLabels[step] || step} setup failed`, message, 0, false, "", "Error");
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
  if (!toolMap.get("git")?.version) steps.push("git");
  if (!toolMap.get("node")?.version || !toolMap.get("npm")?.version) steps.push("node");
  if (!toolMap.get("eai")?.version) steps.push("eai-cli");
  if (!steps.length) {
    installItems.hidden = true;
    wizard.prerequisitesReady = true;
    if (retryInstall) retryInstall.hidden = true;
    showOutput("All prerequisites are ready.");
    setActivity("Everything is ready", "Git, Node.js, npm, and the EAI CLI are already installed.", 100, false);
    return true;
  }
  renderInstallItems(steps);
  setActivity("Preparing installation", `${steps.length} prerequisite${steps.length === 1 ? "" : "s"} need attention.`, 0, true, "Preparing");
  for (const [index, step] of steps.entries()) {
    const name = stepLabels[step] || step;
    const start = Math.round((index / steps.length) * 100);
    setInstallItemState(step, "active", "Starting");
    setActivity(`Installing ${name}`, "Downloading and installing only what is missing. The live status below will show each installer action.", start, true, formatEta(stepEstimates[step]));
    if (!await runBootstrapStep(step)) {
      setInstallItemState(step, "failed", "Needs attention");
      if (retryInstall) retryInstall.hidden = false;
      return false;
    }
    setInstallItemState(step, "done", "Ready");
    await detect();
    setActivity(`${name} installed`, "Continuing setup.", Math.round(((index + 1) / steps.length) * 100), true, formatEta(Math.max(0, steps.slice(index + 1).reduce((total, item) => total + stepEstimates[item], 0))));
  }
  if (environmentReport) setToolState(environmentReport);
  if (wizard.prerequisitesReady) {
    showOutput("Prerequisites installed successfully.");
    setActivity("Installation complete", "All required tools are ready. Continue to sign in.", 100, false, "Ready");
    return true;
  } else {
    if (retryInstall) retryInstall.hidden = false;
    showOutput("Some prerequisites still need attention. Try again.");
    setActivity("Installation needs attention", "Retry the installation step after reviewing the recent activity.", 0, false, "", "Error");
    return false;
  }
}

async function startSetup() {
  if (setupStarted) return;
  setupStarted = true;
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
    setActivity("Sign-in needs attention", "Complete browser sign-in, then try again. See recent activity for the last result.", 0, false, "", "Error");
  }
}

async function runSignup() {
  setActivity("Opening account signup", "Opening the Enterprise AI signup page in your default browser. Return here when your account is ready.", null, true, "", "Opening");
  try {
    const result = await invoke("open_signup");
    if (result?.demo) {
      showOutput("Preview only: the Enterprise AI signup page would open in your browser.");
      setActivity("Signup page ready", "In the signed installer, the public Enterprise AI signup page will open in your browser.", 100, false, "", "Ready");
      return;
    }
    showOutput("Signup page opened.", "Create your account there, then return here and choose Sign in with browser.");
    setActivity("Signup page opened", "Create your account in the browser, then return here and choose Sign in with browser.", 100, false, "", "Ready");
  } catch (error) {
    showOutput("The signup page could not be opened.", String(error));
    setActivity("Signup page could not open", "Open https://www.enterpriseaigroup.com/signup/developer in your browser, then return here and sign in.", 0, false, "", "Error");
  }
}

async function runInit() {
  const name = document.querySelector("#project-name").value.trim();
  const directory = document.querySelector("#project-directory").value.trim();
  if (!EAIWizard.isKebabCase(name)) {
    showOutput("Use lowercase words separated by hyphens, for example customer-portal.");
    document.querySelector("#project-name").focus();
    return;
  }
  if (!directory) {
    showOutput("Choose a parent folder for the app.", "Use Choose folder or enter a folder path.");
    document.querySelector("#project-directory").focus();
    return;
  }
  setActivity("Creating your EAI app", `Initialising ${name} and fetching the supported Gofer assets.`, null);
  startActivityHeartbeat("init");
  let result;
  try {
    result = await invoke("run_bootstrap", { step: "init", projectName: name, directory: directory || null });
  } catch (error) {
    showOutput("App initialisation could not start.", String(error));
    setActivity("App setup failed", `The app could not finish initialising: ${String(error)}`, 0, false, "", "Error");
    return;
  } finally {
    stopActivityHeartbeat();
    activeBootstrapStep = null;
  }
  if (!result.ok && !result.demo) {
    showOutput(result.message || "App initialisation failed.", result.command ? `Next: ${result.command.replace("<project-name>", name)}` : "");
    setActivity("App setup failed", result.message || "The app could not finish initialising. Review recent activity and retry.", 0, false, "", "Error");
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
  if (action === "signup") return runSignup();
  if (action === "choose-folder") {
    const dialog = window.__TAURI__?.dialog;
    if (!dialog?.open) {
      showOutput("Folder selection is available in the desktop installer.");
      return;
    }
    try {
      const selected = await dialog.open({ directory: true, multiple: false, title: "Choose the app folder" });
      if (typeof selected === "string" && selected) {
        document.querySelector("#project-directory").value = selected;
        setActivity("Folder selected", "Your app will be created in this folder.", 100, false, "", "Ready");
        showOutput("Folder selected.");
      }
    } catch (error) {
      showOutput("The folder could not be selected.", String(error));
      setActivity("Folder selection failed", "Choose a folder or enter its path, then try again.", 0, false, "", "Error");
    }
    return;
  }
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
// The installer should make the first decision itself. The button remains as
// an accessible fallback, but normal users only see the permission prompt when
// a missing system component genuinely needs it.
window.setTimeout(() => startSetup(), 250);
