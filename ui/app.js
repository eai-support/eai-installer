const output = document.querySelector("#output");
const platform = document.querySelector("#platform");
const panels = [...document.querySelectorAll("[data-panel]")];
const completeMessage = document.querySelector("#complete-message");
const completeLocation = document.querySelector("#complete-location");
const openProjectButton = document.querySelector("#open-project");
const activity = document.querySelector("#activity");
const activityTitle = document.querySelector("#activity-title");
const activityDetail = document.querySelector("#activity-detail");
const activityBar = document.querySelector("#activity-bar");
const activityTrack = document.querySelector(".activity-track");
const activityPhase = document.querySelector("#activity-phase");
const activityEta = document.querySelector("#activity-eta");
const activityHeartbeat = document.querySelector("#activity-heartbeat");
const activityStep = document.querySelector("#activity-step");
const setupStages = document.querySelector("#setup-stages");
const activityLog = document.querySelector("#activity-log");
const activityLogStatus = document.querySelector("#activity-log-status");
const retryInstall = document.querySelector("#retry-install");
const retryWorkspaces = document.querySelector("#retry-workspaces");
const adminPasswordPanel = document.querySelector("#admin-password-panel");
const adminPasswordInput = document.querySelector("#admin-password");
const adminPasswordSubmit = document.querySelector("#admin-password-submit");
const adminPasswordCancel = document.querySelector("#admin-password-cancel");
const companyTenantField = document.querySelector("#company-tenant-field");
const companyTenantSelect = document.querySelector("#company-tenant");
const appSelectionField = document.querySelector("#app-selection-field");
const appSelection = document.querySelector("#app-selection");
const projectNameInput = document.querySelector("#project-name");
const initAppButton = document.querySelector("#init-app");
const aiSurfaceStatus = document.querySelector("#ai-surface-status");
const aiSurfaceField = document.querySelector("#ai-surface-field");
const aiSurfaceOptions = document.querySelector("#ai-surface-options");
const aiSurfaceNext = document.querySelector("#ai-surface-next");
const aiSurfaceConsent = document.querySelector("#ai-surface-consent");
const refreshAiButton = document.querySelector("#refresh-ai");
const startAiButton = document.querySelector("#start-ai");
const recommendationHelp = document.querySelector("#recommendation-help");
const recommendationDialog = document.querySelector("#recommendation-dialog");
const recommendationClose = document.querySelector("#recommendation-close");

const wizard = EAIWizard.createState();
let environmentReport = null;
let demoMode = false;
let setupStarted = false;
let activeBootstrapStep = null;
let activityTicker = null;
let activityStartedAt = 0;
let activityLastUpdateAt = 0;
let pendingAdminPassword = null;
let companyTenants = [];
let selectedCompanyTenantId = null;
let selectedCompanyAppKey = null;
let failedAppTenantId = null;
let createdProjectDirectory = null;
let aiSurfaceInventory = null;
let selectedAiSurfaceId = null;
let projectPath = null;
let initInProgress = false;
let e2eConfig = null;
let e2eAppCreated = false;
const activityEvents = [];
const activitySummaryKeys = new Set();

const stepLabels = {
  git: "Git",
  node: "Node.js and npm",
  "eai-cli": "EAI CLI",
};

const prerequisiteSteps = ["git", "node", "eai-cli"];

const journeyStages = [
  { id: "computer", label: "Check computer", waiting: "Waiting to check this computer." },
  { id: "git", label: "Prepare Git", waiting: "Waiting for the computer check." },
  { id: "node", label: "Prepare Node.js and npm", waiting: "Waiting for Git." },
  { id: "eai-cli", label: "Prepare EAI CLI", waiting: "Waiting for Node.js and npm." },
  { id: "signin", label: "Sign in", waiting: "Waiting for the required tools." },
  { id: "app", label: "Create app", waiting: "Waiting for sign-in." },
  { id: "ai", label: "Open AI workspace", waiting: "Waiting for the app." },
];

const journeyState = new Map(journeyStages.map((stage) => [stage.id, { state: "pending", detail: stage.waiting }]));
let currentJourneyStageId = "computer";

const stepEstimates = {
  git: 45,
  node: 75,
  "eai-cli": 45,
};

const aiSurfaceGuidance = {
  "copilot-desktop": {
    label: "GitHub Copilot app",
    ready: "GitHub Copilot will open. Sign in to GitHub if asked, choose Add local repositories, and select the project folder shown above.",
    notInstalled: "Download GitHub Copilot from GitHub. After installing it, return here and select Check again.",
  },
  "copilot-cli": {
    label: "GitHub Copilot CLI",
    ready: "A terminal will open in this project. The first use asks you to run /login and confirm that you trust this folder.",
    notInstalled: "GitHub supports a terminal install for Copilot CLI. EAI will open the official instructions; after installing, return here and select Check again.",
  },
  "vscode-copilot": {
    label: "GitHub Copilot in VS Code",
    ready: "VS Code will open this project. Sign in to GitHub in VS Code if asked, then open Copilot Chat.",
    notInstalled: "Install VS Code and the GitHub Copilot extension from the official page. Return here and select Check again.",
  },
};

function journeyStatusLabel(state) {
  return { pending: "Waiting", active: "In progress", done: "Ready", error: "Needs attention" }[state] || "Waiting";
}

function renderJourneyStages() {
  if (!setupStages) return;
  const openStages = new Set(
    [...setupStages.querySelectorAll("details[open]")].map((details) => details.dataset.stage),
  );
  setupStages.replaceChildren();
  for (const [index, stage] of journeyStages.entries()) {
    const value = journeyState.get(stage.id);
    const details = document.createElement("details");
    details.className = "setup-stage";
    details.dataset.stage = stage.id;
    details.dataset.state = value.state;
    details.open = openStages.has(stage.id)
      || (stage.id === currentJourneyStageId && ["active", "error"].includes(value.state));
    const summary = document.createElement("summary");
    const number = document.createElement("span");
    number.className = "setup-stage-number";
    number.textContent = String(index + 1);
    const name = document.createElement("span");
    name.className = "setup-stage-name";
    name.textContent = stage.label;
    const status = document.createElement("span");
    status.className = "setup-stage-status";
    status.textContent = journeyStatusLabel(value.state);
    const detail = document.createElement("p");
    detail.className = "setup-stage-detail";
    detail.textContent = value.detail;
    summary.append(number, name, status);
    details.append(summary, detail);
    setupStages.append(details);
  }
  const currentIndex = Math.max(0, journeyStages.findIndex((stage) => stage.id === currentJourneyStageId));
  if (activityStep) activityStep.textContent = `Step ${currentIndex + 1} of ${journeyStages.length}`;
}

function setJourneyStage(stageId, state, detail) {
  if (!journeyState.has(stageId)) return;
  if (["active", "error"].includes(state)) {
    const targetIndex = journeyStages.findIndex((stage) => stage.id === stageId);
    for (const [otherId, otherValue] of journeyState.entries()) {
      if (otherId === stageId || otherValue.state !== "active") continue;
      const otherIndex = journeyStages.findIndex((stage) => stage.id === otherId);
      journeyState.set(otherId, {
        ...otherValue,
        state: otherIndex < targetIndex ? "done" : "pending",
      });
    }
  }
  const current = journeyState.get(stageId);
  journeyState.set(stageId, { state: state || current.state, detail: detail || current.detail });
  if (["active", "error"].includes(state)) currentJourneyStageId = stageId;
  renderJourneyStages();
}

function journeyStageForActivity(title) {
  return EAIWizard.journeyStageForActivity(activeBootstrapStep, title);
}

function syncJourneyActivity(title, detail, active, phase) {
  const stageId = journeyStageForActivity(title);
  if (!stageId) return;
  if (phase === "Error") setJourneyStage(stageId, "error", detail);
  else if (active) setJourneyStage(stageId, "active", detail);
  else setJourneyStage(stageId, null, detail);
}

function recordSafeSummary(step, detail) {
  const summaryKey = `${step}:${detail}`;
  if (activitySummaryKeys.has(summaryKey)) return;
  activitySummaryKeys.add(summaryKey);
  const stageId = step === "init" ? "app" : step === "login" ? "signin" : step;
  const label = journeyStages.find((stage) => stage.id === stageId)?.label || stepLabels[step] || "Setup";
  recordActivityEvent(label, detail, "Update");
  if (journeyState.has(stageId)) setJourneyStage(stageId, null, detail);
}

function recordCommandSummaries(step, commandOutput) {
  for (const detail of EAIWizard.summarizeCommandOutput(commandOutput)) {
    recordSafeSummary(step, detail);
  }
}

function aiSurfaceCopy(surface) {
  return aiSurfaceGuidance[surface?.id] || {
    label: surface?.name || "AI workspace",
    ready: `${surface?.name || "The AI workspace"} will open with this project. Follow its sign-in or project selection prompts.`,
    notInstalled: `Open the official ${surface?.provider || "provider"} page, install ${surface?.name || "the workspace"}, then return here and select Check again.`,
  };
}

function updateAiSurfaceControls(surface) {
  if (!surface) {
    if (aiSurfaceNext) aiSurfaceNext.hidden = true;
    if (startAiButton) startAiButton.textContent = "Choose an AI workspace";
    return;
  }
  const copy = aiSurfaceCopy(surface);
  if (startAiButton) startAiButton.textContent = surface.installed ? `Open ${copy.label}` : `Get ${copy.label}`;
  if (aiSurfaceNext) {
    aiSurfaceNext.hidden = false;
    aiSurfaceNext.textContent = surface.installed ? copy.ready : copy.notInstalled;
  }
}

function createHarveyBall(surface) {
  const recommendation = EAIWizard.aiSurfaceRecommendation(surface.id);
  const wrapper = document.createElement("span");
  wrapper.className = "harvey-ball-label";
  wrapper.setAttribute("aria-label", `Recommendation: ${recommendation.score} of ${recommendation.maximum}, ${recommendation.label}`);
  wrapper.title = `${recommendation.label}: ${recommendation.score} of ${recommendation.maximum}`;
  const ball = document.createElement("span");
  ball.className = "harvey-ball";
  ball.style.setProperty("--recommendation-score", recommendation.score);
  ball.setAttribute("aria-hidden", "true");
  wrapper.append(ball);
  return { element: wrapper, recommendation };
}

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
  syncJourneyActivity(title, detail, active, phase);
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
    activityPhase.textContent = "Action needed";
    return;
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

function setDetectionState(report) {
  const tools = new Map(report.tools.map((tool) => [tool.command, tool]));
  const gitReady = Boolean(tools.get("git")?.version);
  const nodeReady = Boolean(tools.get("node")?.version && tools.get("npm")?.version);
  const eaiReady = Boolean(tools.get("eai")?.version);
  setJourneyStage("git", gitReady ? "done" : "pending", gitReady ? "Git is already ready." : "Git needs to be installed.");
  setJourneyStage("node", nodeReady ? "done" : "pending", nodeReady ? "Node.js and npm are already ready." : "Node.js and npm need to be installed.");
  setJourneyStage("eai-cli", eaiReady ? "done" : "pending", eaiReady ? "The EAI CLI is already ready." : "The EAI CLI needs to be installed.");
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
  });
  if (!window.__eaiBootstrapSummaryListener) {
    window.__eaiBootstrapSummaryListener = await eventApi.listen("bootstrap-summary", ({ payload }) => {
      if (!payload?.detail) return;
      recordSafeSummary(payload.step, payload.detail);
    });
  }
}

function showOutput(message, detail = "") {
  output.hidden = false;
  const cleanMessage = EAIWizard.cleanText(message);
  const cleanDetail = EAIWizard.cleanText(detail);
  output.textContent = cleanDetail ? `${cleanMessage} ${cleanDetail}` : cleanMessage;
}

function setInitButtonBusy(busy) {
  if (!initAppButton) return;
  initAppButton.disabled = busy;
  initAppButton.setAttribute("aria-busy", String(busy));
  initAppButton.textContent = EAIWizard.initButtonLabel(selectedCompanyAppKey, busy);
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
  const initialComputerCheck = !environmentReport;
  if (initialComputerCheck) setJourneyStage("computer", "active", "Checking this computer and the required tools.");
  setActivity("Checking this computer", "Checking the required tools.", null, true, "", "Checking");
  startActivityHeartbeat("detect");
  try {
    const report = await invoke("detect_environment");
    if (report.demo) {
      showPreviewState();
      if (initialComputerCheck) setJourneyStage("computer", "done", "Computer check complete. Preview mode made no changes.");
      setActivity("Computer check complete", "Preview mode is ready. No changes were made.", 100, false);
      return true;
    }
    demoMode = false;
    environmentReport = report;
    setToolState(report);
    setDetectionState(report);
    if (initialComputerCheck) setJourneyStage("computer", "done", `${report.platform} check complete.`);
    setActivity("Computer check complete", `${report.platform} is ready. Missing items are shown below.`, 100, false, "", "Complete");
    return true;
  } catch (error) {
    showOutput("Could not inspect this computer.", String(error));
    if (retryInstall) retryInstall.hidden = false;
    if (initialComputerCheck) setJourneyStage("computer", "error", "The computer check could not finish.");
    setActivity("Computer check failed", `The computer check could not finish: ${String(error)}`, 0, false, "", "Error");
    return false;
  } finally {
    stopActivityHeartbeat();
    if (activeBootstrapStep === "detect") activeBootstrapStep = null;
  }
}

async function runBootstrapStep(step) {
  const journeyStep = step === "login" ? "signin" : step;
  if (journeyState.has(journeyStep)) setJourneyStage(journeyStep, "active", `${stepLabels[step] || "Secure sign-in"} is in progress.`);
  activeBootstrapStep = step;
  await listenForBootstrapProgress();
  startActivityHeartbeat(step);
  let result;
  try {
    const adminPassword = step === "git" && environmentReport?.platform === "macos" ? await requestMacAdminPassword() : null;
    if (step === "git" && environmentReport?.platform === "macos" && !adminPassword) {
      showOutput("Mac approval was cancelled. No tools were changed.", "Next: enter the Mac password and allow installation to retry.");
      setActivity("Git setup cancelled", "No changes were made. Enter the Mac password to retry the Apple Command Line Tools installation.", 0, false, "", "Error");
      setJourneyStage("git", "error", "Git installation approval was cancelled.");
      return false;
    }
    result = await invoke("run_bootstrap", { step, projectName: null, directory: null, adminPassword, companyTenantId: null });
  } catch (error) {
    showOutput("This setup step could not start.", String(error));
    setActivity(`${stepLabels[step] || step} setup failed`, `The step could not finish: ${String(error)}`, 0, false, "", "Error");
    if (journeyState.has(journeyStep)) setJourneyStage(journeyStep, "error", "This step could not finish.");
    return false;
  } finally {
    stopActivityHeartbeat();
    activeBootstrapStep = null;
  }
  if (result.output) {
    recordCommandSummaries(step, result.output);
  }
  if (!result.ok && !result.demo) {
    const message = result.message || "This setup step failed.";
    showOutput(message, result.command ? `Next: ${result.command}` : "");
    setActivity(`${stepLabels[step] || step} setup failed`, message, 0, false, "", "Error");
    if (journeyState.has(journeyStep)) setJourneyStage(journeyStep, "error", message);
    return false;
  }
  if (journeyState.has(journeyStep)) setJourneyStage(journeyStep, "done", result.message || `${stepLabels[step] || "This step"} is ready.`);
  return true;
}

async function installPrerequisites() {
  if (demoMode) {
    showOutput("Preview only: no changes were made to this computer.");
    for (const step of prerequisiteSteps) setJourneyStage(step, "done", `${stepLabels[step]} will be prepared by the signed installer.`);
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
    wizard.prerequisitesReady = true;
    if (retryInstall) retryInstall.hidden = true;
    showOutput("All prerequisites are ready.");
    setActivity("Everything is ready", "Git, Node.js, npm, and the EAI CLI are already installed.", 100, false);
    for (const step of prerequisiteSteps) setJourneyStage(step, "done", `${stepLabels[step]} is ready.`);
    return true;
  }
  setActivity("Preparing installation", `${steps.length} prerequisite${steps.length === 1 ? "" : "s"} need attention.`, 0, true, "Preparing");
  for (const [index, step] of steps.entries()) {
    const name = stepLabels[step] || step;
    const start = Math.round((index / steps.length) * 100);
    setJourneyStage(step, "active", `Installing ${name}.`);
    setActivity(`Installing ${name}`, "Downloading and installing only what is missing. The live status below will show each installer action.", start, true, formatEta(stepEstimates[step]));
    if (!await runBootstrapStep(step)) {
      if (retryInstall) retryInstall.hidden = false;
      return false;
    }
    setJourneyStage(step, "done", `${name} is ready.`);
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
    setActivity("Installation needs attention", "Review Build summary, then retry the installation step.", 0, false, "", "Error");
    return false;
  }
}

async function startSetup() {
  if (setupStarted) return;
  setupStarted = true;
  try {
    const config = await invoke("get_e2e_configuration");
    e2eConfig = config?.enabled ? config : null;
  } catch {
    e2eConfig = null;
  }
  setStep(1);
  if (!await detect()) {
    await writeE2eReceipt("prerequisites", "The computer check could not finish.");
    return;
  }
  setStep(2);
  if (await installPrerequisites()) {
    setStep(3);
    if (e2eConfig) await runE2eFlow();
  } else {
    await writeE2eReceipt("prerequisites", "The required tools could not be installed.");
  }
}

async function writeE2eReceipt(failedCheck, message) {
  if (!e2eConfig?.receiptFile) return;
  const checkOrder = ["prerequisites", "authentication", "tenant", "app", "project", "aiHandoff"];
  const failedIndex = failedCheck ? checkOrder.indexOf(failedCheck) : -1;
  const checks = Object.fromEntries(checkOrder.map((check, index) => [
    check,
    failedIndex < 0 ? "passed" : index < failedIndex ? "passed" : index === failedIndex ? "failed" : "not-run",
  ]));
  try {
    await invoke("write_e2e_receipt", {
      receiptFile: e2eConfig.receiptFile,
      receipt: {
        status: failedCheck ? "failed" : "passed",
        message,
        checks,
        appCreated: e2eAppCreated,
      },
    });
  } catch (error) {
    console.error("Could not write the E2E receipt", error);
  }
}

async function runE2eFlow() {
  setActivity("Checking saved sign-in", "The release test is using the pre-authenticated guest account.", null, true, "", "Checking");
  try {
    await invoke("verify_e2e_auth");
  } catch (error) {
    showOutput("Saved sign-in needs attention.", String(error));
    setActivity("Saved sign-in failed", "The release test guest is not authenticated. Refresh its approved test snapshot, then retry.", 0, false, "", "Error");
    await writeE2eReceipt("authentication", String(error));
    return;
  }
  if (!await loadCompanyTenants()) {
    await writeE2eReceipt("tenant", "Company workspaces could not be loaded.");
    return;
  }
  const requestedTenant = e2eConfig.companyTenantId;
  if (!requestedTenant || !companyTenants.some((tenant) => tenant.id === requestedTenant)) {
    const message = "The configured release-test tenant is not available to the signed-in account.";
    showOutput("Release-test tenant needs attention.", message);
    setActivity("Release-test tenant unavailable", message, 0, false, "", "Error");
    await writeE2eReceipt("tenant", message);
    return;
  }
  selectedCompanyTenantId = requestedTenant;
  renderCompanyTenants();
  if (!await loadCompanyApps(requestedTenant)) {
    await writeE2eReceipt("app", "Apps could not be loaded for the release-test workspace.");
    return;
  }
  selectedCompanyAppKey = e2eConfig.appKey || null;
  if (appSelection && selectedCompanyAppKey) appSelection.value = selectedCompanyAppKey;
  if (projectNameInput) projectNameInput.value = e2eConfig.projectName || "eai-release-test";
  const directoryInput = document.querySelector("#project-directory");
  if (directoryInput) directoryInput.value = e2eConfig.directory || "";
  setStep(4);
  const completed = await runInit();
  if (!completed) {
    await writeE2eReceipt(e2eAppCreated ? "project" : "app", "The EAI app could not be initialised by the desktop bootstrap path.");
    return;
  }
  const surface = aiSurfaceInventory?.surfaces?.find((item) => item.id === selectedAiSurfaceId && item.installed)
    || aiSurfaceInventory?.surfaces?.find((item) => item.installed);
  if (!surface) {
    await writeE2eReceipt("aiHandoff", "No installed AI workspace was available for the release-test handoff.");
    return;
  }
  try {
    await invoke("start_ai_surface", { directory: createdProjectDirectory, surfaceId: surface.id });
  } catch (error) {
    await writeE2eReceipt("aiHandoff", `The AI workspace could not be opened: ${String(error)}`);
    return;
  }
  await writeE2eReceipt(null, "The published installer completed its desktop bootstrap path.");
}

async function runLogin() {
  setJourneyStage("signin", "active", "Opening secure browser sign-in.");
  setActivity("Opening secure sign-in", "Your browser will handle EAI authentication. The installer does not see your password.", null);
  const result = await runBootstrapStep("login");
  if (result) {
    showOutput(demoMode ? "Preview only: the signed app will open browser sign-in." : "Browser sign-in completed.");
    if (demoMode || await loadCompanyTenants()) {
      setJourneyStage("signin", "done", "Secure browser sign-in is complete.");
      setActivity("Sign-in complete", "Your company workspaces are ready. Continue to app setup.", 100, false, "Ready");
      setStep(4);
    }
  } else {
    setJourneyStage("signin", "error", "Browser sign-in did not complete.");
    setActivity("Sign-in needs attention", "Complete browser sign-in, then try again. Build summary shows the last result.", 0, false, "", "Error");
  }
}

function renderCompanyTenants() {
  if (!companyTenantField || !companyTenantSelect) return;
  selectedCompanyTenantId = EAIWizard.resolveTenantSelection(companyTenants, selectedCompanyTenantId);
  companyTenantSelect.replaceChildren();
  if (companyTenants.length === 1) {
    companyTenantField.hidden = true;
    if (appSelectionField) appSelectionField.hidden = true;
    return;
  }

  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.textContent = "Choose a company workspace";
  placeholder.disabled = true;
  placeholder.selected = !selectedCompanyTenantId;
  companyTenantSelect.append(placeholder);
  for (const tenant of companyTenants) {
    const option = document.createElement("option");
    option.value = tenant.id;
    option.textContent = tenant.displayName;
    option.selected = tenant.id === selectedCompanyTenantId;
    companyTenantSelect.append(option);
  }
  companyTenantField.hidden = false;
  if (appSelectionField) appSelectionField.hidden = true;
}

function selectedCompanyTenant() {
  return companyTenants.find((tenant) => tenant.id === selectedCompanyTenantId) || null;
}

function renderCompanyApps() {
  if (!appSelectionField || !appSelection) return;
  const tenant = selectedCompanyTenant();
  const apps = Array.isArray(tenant?.apps) ? tenant.apps : [];
  appSelection.replaceChildren();
  selectedCompanyAppKey = null;

  if (apps.length === 0) {
    appSelectionField.hidden = true;
    if (projectNameInput) {
      projectNameInput.readOnly = false;
      projectNameInput.value = "";
    }
    setInitButtonBusy(false);
    return;
  }

  const createOption = document.createElement("option");
  createOption.value = "";
  createOption.textContent = "Create a new app";
  appSelection.append(createOption);
  for (const app of apps) {
    const option = document.createElement("option");
    option.value = app.key;
    option.textContent = `${app.displayName} (${app.key}) · ${app.status}`;
    appSelection.append(option);
  }
  appSelection.value = "";
  appSelectionField.hidden = false;
  if (projectNameInput) projectNameInput.readOnly = false;
  setInitButtonBusy(false);
}

async function loadCompanyApps(tenantId) {
  if (!tenantId) return true;
  const tenant = companyTenants.find((item) => item.id === tenantId);
  if (!tenant) return false;
  if (tenant.appsLoaded) {
    if (retryWorkspaces) {
      retryWorkspaces.hidden = true;
      retryWorkspaces.textContent = EAIWizard.retryActionLabel("app");
    }
    renderCompanyApps();
    return true;
  }
  setActivity("Checking apps", `Loading apps for ${tenant.displayName}.`, null, true, "", "Checking");
  setJourneyStage("app", "active", "Checking the apps available in the selected company workspace.");
  try {
    tenant.apps = await invoke("get_company_apps", { tenantId });
    tenant.appsLoaded = true;
    failedAppTenantId = null;
    if (retryWorkspaces) {
      retryWorkspaces.hidden = true;
      retryWorkspaces.textContent = EAIWizard.retryActionLabel("app");
    }
    renderCompanyApps();
    recordActivityEvent("Apps ready", `Apps for ${tenant.displayName} are ready.`, "Ready");
    return true;
  } catch (error) {
    failedAppTenantId = tenantId;
    const failure = EAIWizard.describeAppFailure(error);
    showOutput(failure.title, `${failure.detail} ${failure.next} Diagnostic: ${failure.diagnostic}`);
    setActivity(failure.title, `${failure.detail} ${failure.next}`, 0, false, "", "Error");
    if (retryWorkspaces) {
      retryWorkspaces.textContent = EAIWizard.retryActionLabel("app");
      retryWorkspaces.hidden = !failure.retryable;
    }
    return false;
  }
}

function selectCompanyApp() {
  selectedCompanyAppKey = appSelection?.value || null;
  if (selectedCompanyAppKey) {
    if (projectNameInput) {
      projectNameInput.value = selectedCompanyAppKey;
      projectNameInput.readOnly = true;
    }
    setInitButtonBusy(false);
    const app = selectedCompanyTenant()?.apps?.find((item) => item.key === selectedCompanyAppKey);
    setActivity(
      "Existing app selected",
      `The local project will use ${app?.displayName || selectedCompanyAppKey}. No new platform app will be created.`,
      100,
      false,
      "Ready",
      "Ready",
    );
    return;
  }
  if (projectNameInput) {
    projectNameInput.value = "";
    projectNameInput.readOnly = false;
  }
  setInitButtonBusy(false);
  setActivity("Create a new app", "Enter a project name and choose its parent folder.", 100, false, "Ready", "Ready");
}

async function loadCompanyTenants() {
  if (demoMode) return true;
  failedAppTenantId = null;
  if (retryWorkspaces) retryWorkspaces.hidden = true;
  setActivity("Checking company workspaces", "Finding where your new app can be created.", null, true, "", "Checking");
  setJourneyStage("app", "active", "Finding where the new app can be created.");
  try {
    companyTenants = await invoke("get_company_tenants");
    if (!Array.isArray(companyTenants) || companyTenants.length === 0) {
      throw new Error("No company workspaces are available for this account.");
    }
    renderCompanyTenants();
    if (companyTenants.length === 1) {
      if (!await loadCompanyApps(selectedCompanyTenantId)) return false;
      recordActivityEvent("Workspace ready", `Using ${companyTenants[0].displayName} for this app.`, "Ready");
      return true;
    }
    recordActivityEvent("Workspace choice", "Choose the company workspace that should own this app.", "Waiting");
    setActivity("Choose a company workspace", "Select the company workspace that should own this app, then continue.", 100, false, "", "Waiting");
    return true;
  } catch (error) {
    const failure = EAIWizard.describeWorkspaceFailure(error);
    showOutput(failure.title, `${failure.detail} ${failure.next} Diagnostic: ${failure.diagnostic}`);
    setActivity(failure.title, `${failure.detail} ${failure.next}`, 0, false, "", "Error");
    if (retryWorkspaces) {
      retryWorkspaces.textContent = EAIWizard.retryActionLabel("workspace");
      retryWorkspaces.hidden = !failure.retryable;
    }
    return false;
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
  if (initInProgress) return;
  const name = projectNameInput.value.trim();
  const directory = document.querySelector("#project-directory").value.trim();
  if (!EAIWizard.isKebabCase(name)) {
    showOutput("Use lowercase words separated by hyphens, for example customer-portal.");
    document.querySelector("#project-name").focus();
    return false;
  }
  if (!directory) {
    showOutput("Choose a parent folder for the app.", "Use Choose folder or enter a folder path.");
    document.querySelector("#project-directory").focus();
    return false;
  }
  if (!demoMode && !selectedCompanyTenantId) {
    showOutput("Choose the company workspace for this app.");
    setActivity("Choose a company workspace", "Select the company workspace that should own this app, then continue.", 100, false, "", "Waiting");
    companyTenantSelect?.focus();
    return false;
  }
  initInProgress = true;
  setInitButtonBusy(true);
  setJourneyStage("app", "active", `Creating ${name} and preparing its project files.`);
  setActivity("Creating your EAI app", `Initialising ${name} and fetching the supported Gofer assets.`, null);
  await listenForBootstrapProgress();
  startActivityHeartbeat("init");
  let result;
  try {
    result = await invoke("run_bootstrap", { step: "init", projectName: name, directory: directory || null, companyTenantId: selectedCompanyTenantId, appKey: selectedCompanyAppKey });
  } catch (error) {
    const failure = EAIWizard.describeInitFailure(error, environmentReport?.platform);
    showOutput(failure.title, `${failure.detail} Next: ${failure.next}`);
    setActivity(failure.title, failure.detail, 0, false, "", "Error");
    setJourneyStage("app", "error", failure.detail);
    return false;
  } finally {
    stopActivityHeartbeat();
    activeBootstrapStep = null;
    initInProgress = false;
    setInitButtonBusy(false);
  }
  if (result?.output) {
    recordCommandSummaries("init", result.output);
  }
  e2eAppCreated = Boolean(result?.app_created);
  if (result?.project_directory) {
    createdProjectDirectory = result.project_directory;
    projectPath = result.project_path || result.project_directory;
  }
  if (!result.ok && !result.demo) {
    const failure = EAIWizard.describeInitFailure(result.message, environmentReport?.platform);
    showOutput(failure.title, `Next: ${failure.next}`);
    setActivity(failure.title, failure.detail, 0, false, "", "Error");
    setJourneyStage("app", "error", failure.detail);
    return false;
  }
  completeMessage.textContent = result.demo
    ? "Preview complete. The signed desktop app will run eai init in the selected folder."
    : selectedCompanyAppKey
      ? `The ${name} project is connected to your existing EAI app. Open its folder to start building.`
      : `The ${name} app was created successfully. Open its folder to start building.`;
  projectPath = result.project_path || null;
  wizard.projectName = name;
  createdProjectDirectory = result.project_directory || (directory.endsWith(`/${name}`) || directory.endsWith(`\\${name}`) ? directory : `${directory}/${name}`);
  if (!projectPath) projectPath = createdProjectDirectory;
  if (completeLocation) {
    completeLocation.textContent = projectPath ? `Project folder: ${projectPath}` : "Your project folder is ready.";
    completeLocation.hidden = !projectPath;
  }
  if (openProjectButton) openProjectButton.hidden = !projectPath || demoMode;
  setJourneyStage("app", "done", "The EAI app and its project files are ready.");
  setJourneyStage("ai", "active", "Checking which AI workspaces can open this project.");
  setStep(5);
  setActivity("Setup complete", "Your EAI app and developer tools are ready.", 100, false);
  showOutput("Setup complete.");
  await loadAiSurfaces();
  return true;
}

function renderAiSurfaces() {
  if (!aiSurfaceInventory || !aiSurfaceOptions) return;
  aiSurfaceOptions.replaceChildren();
  selectedAiSurfaceId = EAIWizard.chooseAiSurface(aiSurfaceInventory);
  for (const surface of aiSurfaceInventory.surfaces) {
    const row = document.createElement("label");
    row.className = "surface-option";
    const input = document.createElement("input");
    input.type = "radio";
    input.name = "ai-surface";
    input.value = surface.id;
    input.checked = surface.id === selectedAiSurfaceId;
    input.addEventListener("change", () => {
      selectedAiSurfaceId = surface.id;
      updateAiSurfaceControls(surface);
    });
    const copy = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = aiSurfaceCopy(surface).label;
    const detail = document.createElement("small");
    detail.textContent = surface.installed
      ? `${surface.provider} · Ready${surface.launchSupport === "manual-project" ? "; connect the project when it opens" : "; opens this project"}`
      : `${surface.provider} · Not installed`;
    copy.append(name, detail);
    const badge = document.createElement("span");
    badge.className = "surface-badge";
    const { element: harveyBall, recommendation } = createHarveyBall(surface);
    const badgeText = document.createElement("span");
    badgeText.textContent = recommendation.score === recommendation.maximum
      ? "Recommended"
      : surface.installed ? "Ready" : "Official download";
    badge.append(harveyBall, badgeText);
    row.append(input, copy, badge);
    aiSurfaceOptions.append(row);
  }
  const selected = aiSurfaceInventory.surfaces.find((surface) => surface.id === selectedAiSurfaceId);
  aiSurfaceField.hidden = false;
  aiSurfaceConsent.hidden = false;
  if (refreshAiButton) refreshAiButton.hidden = false;
  startAiButton.hidden = false;
  updateAiSurfaceControls(selected);
  const readyCount = aiSurfaceInventory.surfaces.filter((surface) => surface.installed).length;
  aiSurfaceStatus.innerHTML = readyCount
    ? `<strong>${readyCount} AI workspace${readyCount === 1 ? " is" : "s are"} ready</strong><p>Choose one below. EAI will open the project and explain the next step.</p>`
    : "<strong>Choose an AI workspace</strong><p>GitHub Copilot, Claude, Codex, and Grok can work with your EAI project. Install one only if you need it.</p>";
}

recommendationHelp?.addEventListener("click", () => recommendationDialog?.showModal());
recommendationClose?.addEventListener("click", () => recommendationDialog?.close());
recommendationDialog?.addEventListener("click", (event) => {
  if (event.target === recommendationDialog) recommendationDialog.close();
});

async function loadAiSurfaces() {
  if (!createdProjectDirectory) return false;
  try {
    aiSurfaceInventory = await invoke("detect_ai_surfaces", { directory: createdProjectDirectory });
    if (aiSurfaceInventory.demo) {
      aiSurfaceInventory = {
        preferredSurface: null,
        recommendedSurface: "vscode-copilot",
        surfaces: [
          { id: "vscode-copilot", name: "GitHub Copilot in VS Code", provider: "GitHub", launchSupport: "project-and-prompt", installed: false, recommended: true },
          { id: "copilot-cli", name: "GitHub Copilot CLI", provider: "GitHub", launchSupport: "project-and-prompt", installed: false, recommended: false },
          { id: "copilot-desktop", name: "GitHub Copilot app", provider: "GitHub", launchSupport: "manual-project", installed: false, recommended: false },
          { id: "claude-desktop", name: "Claude Desktop", provider: "Anthropic", launchSupport: "manual-project", installed: false, recommended: false },
          { id: "claude-cli", name: "Claude Code", provider: "Anthropic", launchSupport: "project-and-prompt", installed: false, recommended: false },
          { id: "codex-desktop", name: "Codex Desktop", provider: "OpenAI", launchSupport: "project-only", installed: false, recommended: false },
          { id: "codex-cli", name: "Codex CLI", provider: "OpenAI", launchSupport: "project-and-prompt", installed: false, recommended: false },
          { id: "grok-cli", name: "Grok Build", provider: "xAI", launchSupport: "project-and-prompt", installed: false, recommended: false },
        ],
      };
    }
    renderAiSurfaces();
    const readyCount = aiSurfaceInventory.surfaces.filter((surface) => surface.installed).length;
    setJourneyStage("ai", "active", readyCount ? `${readyCount} AI workspace${readyCount === 1 ? " is" : "s are"} ready to open.` : "Choose an AI workspace to install.");
    return true;
  } catch (error) {
    aiSurfaceStatus.innerHTML = "<strong>AI workspace check needs attention</strong><p>You can close setup and run <code>eai start</code> from the project folder.</p>";
    showOutput("Your app is ready, but AI workspace detection did not finish.", String(error));
    setJourneyStage("ai", "error", "AI workspace detection did not finish. The app remains ready.");
    return false;
  }
}

async function refreshAiSurfaces() {
  if (!createdProjectDirectory || !refreshAiButton) return;
  refreshAiButton.disabled = true;
  setActivity("Checking AI workspaces", "Checking installed apps and commands. EAI does not read provider accounts or project files.", null, true, "", "Checking");
  try {
    const refreshed = await loadAiSurfaces();
    if (refreshed) {
      showOutput("AI workspace check complete.", "Choose Open or Get for the workspace you want to use.");
      setActivity("AI workspace check complete", "The list above reflects the apps and commands currently available on this computer.", 100, false, "", "Ready");
    }
  } finally {
    refreshAiButton.disabled = false;
  }
}

async function startAiSurface() {
  const surface = aiSurfaceInventory?.surfaces.find((item) => item.id === selectedAiSurfaceId);
  if (!surface || !createdProjectDirectory) {
    showOutput("Choose an AI workspace first.");
    return;
  }
  startAiButton.disabled = true;
  const copy = aiSurfaceCopy(surface);
  setActivity(surface.installed ? `Opening ${copy.label}` : `Opening ${copy.label} download`, surface.installed ? copy.ready : copy.notInstalled, null, true, "", "Opening");
  try {
    if (!surface.installed) {
      await invoke("install_ai_surface", { surfaceId: surface.id });
      setActivity("Official download opened", copy.notInstalled, 100, false, "", "Ready");
      showOutput(`The official ${surface.provider} page opened.`, "Install the selected workspace, return here, and choose Check again. EAI does not sign in to an AI provider for you.");
      setJourneyStage("ai", "active", `The official ${surface.provider} download is open. Install it, then check again.`);
      return;
    }
    const result = await invoke("start_ai_surface", { directory: createdProjectDirectory, surfaceId: surface.id });
    setActivity(`${copy.label} opened`, copy.ready, 100, false, "", "Ready");
    completeMessage.textContent = `${copy.label} is open. Complete its sign-in or project connection step to start building.`;
    startAiButton.textContent = `Open ${copy.label} again`;
    showOutput(`${copy.label} opened.`, copy.ready);
    setJourneyStage("ai", "done", `${copy.label} opened with this project.`);
  } catch (error) {
    setJourneyStage("ai", "error", "The selected AI workspace could not be opened.");
    setActivity("AI workspace could not start", String(error), 0, false, "", "Error");
    showOutput("Your app is safe and complete.", `Run eai start from ${createdProjectDirectory} or try another workspace.`);
  } finally {
    startAiButton.disabled = false;
  }
}

async function runAction(action) {
  if (action === "start") return startSetup();
  if (action === "detect") return detect();
  if (action === "install-all") return installPrerequisites();
  if (action === "login") return runLogin();
  if (action === "retry-workspaces") {
    const retryingApps = Boolean(failedAppTenantId);
    const ready = retryingApps
      ? await loadCompanyApps(failedAppTenantId)
      : await loadCompanyTenants();
    if (ready) {
      if (retryWorkspaces) {
        retryWorkspaces.hidden = true;
        retryWorkspaces.textContent = EAIWizard.retryActionLabel("app");
      }
      if (!EAIWizard.workspaceRetryCanContinue(retryingApps, companyTenants.length, selectedCompanyTenantId)) {
        showOutput("Company workspaces are ready.", "Choose the company workspace that should own this app.");
        setStep(4);
        return;
      }
      setActivity("EAI is ready", "Continue setting up your app.", 100, false, "", "Ready");
      showOutput("EAI is ready.", "Continue setting up your app.");
      setStep(4);
    }
    return;
  }
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
  if (action === "select-company-tenant") {
    selectedCompanyTenantId = companyTenantSelect?.value || null;
    if (selectedCompanyTenantId) {
      const tenant = companyTenants.find((item) => item.id === selectedCompanyTenantId);
      if (!await loadCompanyApps(selectedCompanyTenantId)) return;
      setActivity("Company workspace selected", `${tenant?.displayName || "Company workspace"} will own this app.`, 100, false, "", "Ready");
    }
    return;
  }
  if (action === "select-company-app") {
    selectCompanyApp();
    return;
  }
  if (action === "init") return runInit();
  if (action === "start-ai") return startAiSurface();
  if (action === "refresh-ai") return refreshAiSurfaces();
  if (action === "open-project") {
    if (!projectPath) return;
    try {
      await invoke("open_project", { path: projectPath });
      setActivity("Project folder opened", "Your EAI app is ready in the file manager.", 100, false, "", "Ready");
      showOutput("Project folder opened.");
    } catch (error) {
      showOutput("The project folder could not be opened.", String(error));
      setActivity("Project folder could not open", "Use the folder location shown above to open it manually.", 100, false, "", "Error");
    }
    return;
  }
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
companyTenantSelect?.addEventListener("change", () => runAction("select-company-tenant"));
appSelection?.addEventListener("change", () => runAction("select-company-app"));

renderJourneyStages();
setStep(0);
// The installer should make the first decision itself. The button remains as
// an accessible fallback, but normal users only see the permission prompt when
// a missing system component genuinely needs it.
window.setTimeout(() => startSetup(), 250);
