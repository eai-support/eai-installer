import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("../ui/wizard-state.js", import.meta.url), "utf8");
const sandbox = { console };
sandbox.globalThis = sandbox;
vm.runInNewContext(source, sandbox);
const wizard = sandbox.EAIWizard;
if (!wizard) throw new Error("wizard state module did not register");

const state = wizard.createState();
if (state.step !== 0 || state.prerequisitesReady) throw new Error("wizard initial state is wrong");
if (wizard.clampStep(-2) !== 0 || wizard.clampStep(99) !== 5) throw new Error("wizard step bounds are wrong");
if (!wizard.isKebabCase("my-eai-app") || wizard.isKebabCase("My App") || wizard.isKebabCase("-bad")) {
  throw new Error("wizard project-name validation is wrong");
}
if (wizard.cleanText("\u001b[31mFailed\u001b[39m\r\nspawn EINVAL") !== "Failed\nspawn EINVAL") {
  throw new Error("wizard output cleaning is wrong");
}
const buildSummaries = wizard.summarizeCommandOutput(`
✓ Cloned from eai-support/eai-app-template@abc123
✓ Generated .env.local
added 225 packages in 2s
ENTRA_CLIENT_SECRET=do-not-display
Tenant ID: 5dd8db37-0993-f01c-0487-e8f0fae6c3d7
`);
if (!buildSummaries.includes("Downloaded the supported EAI app template.") || !buildSummaries.includes("Created the local app configuration.") || !buildSummaries.includes("Installed the required project packages.")) {
  throw new Error("wizard safe build summaries omit supported milestones");
}
if (buildSummaries.some((summary) => /secret|5dd8db37|abc123/i.test(summary))) {
  throw new Error("wizard safe build summaries expose private command output");
}
if (wizard.journeyStageForActivity("git", "Apple Software Update is installing Git") !== "git") {
  throw new Error("wizard mistakes Apple Software Update for the app-creation stage");
}
if (wizard.journeyStageForActivity(null, "Creating your EAI app") !== "app") {
  throw new Error("wizard does not recognise the explicit app-creation stage");
}
if (wizard.initButtonLabel(null, false) !== "Create and initialise app" || wizard.initButtonLabel("existing-app", false) !== "Use app and initialise project") {
  throw new Error("wizard app action labels are wrong");
}
if (wizard.initButtonLabel(null, true) !== "Creating app..." || wizard.initButtonLabel("existing-app", true) !== "Initialising project...") {
  throw new Error("wizard busy action labels are wrong");
}
const windowsFailure = wizard.describeInitFailure("\u001b[31mFailed to install app dependencies\u001b[39m: spawn EINVAL", "windows");
if (windowsFailure.title !== "Windows dependency setup needs attention" || !windowsFailure.detail.includes("project files were created") || !windowsFailure.detail.includes("spawn EINVAL") || !windowsFailure.next.includes("Try again")) {
  throw new Error("wizard Windows npm failure guidance is missing");
}
const dependencyFailure = wizard.describeInitFailure("The app was created, but its dependencies could not be installed: npm failed", "windows");
if (dependencyFailure.title !== "App dependencies need attention" || !dependencyFailure.detail.includes("project files were created") || !dependencyFailure.next.includes("Try again")) {
  throw new Error("wizard app dependency failure guidance is missing");
}
const genericFailure = wizard.describeInitFailure("folder is not writable", "macos");
if (genericFailure.title !== "App setup failed" || !genericFailure.detail.includes("folder is not writable")) {
  throw new Error("wizard generic failure guidance is wrong");
}
const dumpedInitFailure = wizard.describeInitFailure(
  "✕ Something unique went wrong\n\nTry next:\n1. eai whoami [read-only]\n\nGetting started: https://www.enterpriseaigroup.com/docs/getting-started",
  "macos",
);
if (
  dumpedInitFailure.detail.includes("eai whoami")
  || dumpedInitFailure.detail.includes("Try next")
  || dumpedInitFailure.detail.includes("Getting started")
  || dumpedInitFailure.next.includes("Build summary")
) {
  throw new Error("wizard init failure still dumps CLI recovery onto the screen");
}
const transientInitFailure = wizard.describeInitFailure(
  "✕ App creation failed: A platform dependency is temporarily unavailable\n\nTry next:\n1. eai whoami [read-only]\n\nGetting started: https://www.enterpriseaigroup.com/docs/getting-started",
  "macos",
);
if (
  transientInitFailure.title !== "EAI is temporarily unavailable"
  || !transientInitFailure.detail.includes("service it depends on")
  || transientInitFailure.detail.includes("eai whoami")
  || !transientInitFailure.next.includes("Retry this step")
  || transientInitFailure.failedAt !== "template"
) {
  throw new Error("wizard transient init failure guidance is wrong");
}
const missingExistingApp = wizard.describeInitFailure(
  "No app named eai-app-testing was found in the selected company workspace.",
  "windows",
);
if (missingExistingApp.title !== "Existing app could not be found" || !missingExistingApp.detail.includes("No new platform app was created") || !missingExistingApp.next.includes("Create a new app")) {
  throw new Error("wizard existing-app lookup guidance is missing");
}
const disabledExistingApp = wizard.describeInitFailure("The selected app status is disabled.", "windows");
if (disabledExistingApp.title !== "Selected app is disabled" || !disabledExistingApp.next.includes("active app")) {
  throw new Error("wizard disabled-app guidance is missing");
}
const temporaryWorkspaceFailure = wizard.describeWorkspaceFailure("503 Service Unavailable");
if (temporaryWorkspaceFailure.title !== "EAI is temporarily unavailable" || !temporaryWorkspaceFailure.detail.includes("sign-in is complete") || !temporaryWorkspaceFailure.next.includes("Try workspace check again") || temporaryWorkspaceFailure.retryable !== true) {
  throw new Error("wizard temporary workspace failure guidance is wrong");
}
const missingWorkspaceFailure = wizard.describeWorkspaceFailure("No active company workspaces are available for this account.");
if (missingWorkspaceFailure.title !== "No company workspace is available" || !missingWorkspaceFailure.next.includes("company administrator")) {
  throw new Error("wizard missing workspace guidance is wrong");
}
const accessWorkspaceFailure = wizard.describeWorkspaceFailure("403 Forbidden");
if (accessWorkspaceFailure.title === "EAI is temporarily unavailable") {
  throw new Error("wizard must not classify an access denial as a temporary platform outage");
}
const temporaryAppFailure = wizard.describeAppFailure("502 Bad Gateway");
if (temporaryAppFailure.title !== "EAI is temporarily unavailable" || !temporaryAppFailure.detail.includes("company workspace is ready") || !temporaryAppFailure.next.includes("Try again")) {
  throw new Error("wizard temporary app failure guidance is wrong");
}
const deniedAppFailure = wizard.describeAppFailure("403 Forbidden");
if (deniedAppFailure.title !== "Apps need attention" || deniedAppFailure.detail.includes("company workspaces after")) {
  throw new Error("wizard app failure guidance is misleading");
}
if (wizard.retryActionLabel("workspace") !== "Try workspace check again" || wizard.retryActionLabel("app") !== "Try again") {
  throw new Error("wizard retry labels do not match the failed action");
}
if (wizard.workspaceRetryCanContinue(false, 2, null) || !wizard.workspaceRetryCanContinue(false, 1, "only") || !wizard.workspaceRetryCanContinue(true, 2, "selected")) {
  throw new Error("wizard workspace retry skips a required multi-workspace choice");
}
const companyTenants = [{ id: "first" }, { id: "requested" }];
if (wizard.resolveTenantSelection(companyTenants, "requested") !== "requested") {
  throw new Error("wizard clears a valid release-test tenant when multiple workspaces are available");
}
if (wizard.resolveTenantSelection(companyTenants, "missing") !== null) {
  throw new Error("wizard keeps a tenant selection that is no longer available");
}
if (wizard.resolveTenantSelection([{ id: "only" }], null) !== "only") {
  throw new Error("wizard does not automatically select the only company workspace");
}

const report = {
  platform: "macos",
  package_manager: null,
  tools: [
    { command: "git", version: "git version 2.40" },
    { command: "node", version: "v20.0.0" },
    { command: "npm", version: "10.0.0" },
    { command: "eai", version: "3.8.0" },
  ],
};
if (!wizard.prerequisitesReady(report)) throw new Error("complete prerequisite report should be ready");
if (wizard.prerequisitesReady({ platform: "linux", package_manager: "apt-get", tools: [{ command: "git", version: "2" }] })) {
  throw new Error("incomplete prerequisite report should not be ready");
}
const windowsReport = {
  ...report,
  platform: "windows",
  tools: [...report.tools, { command: "windows-runtime", version: "v14.51.36247.00" }],
};
if (!wizard.prerequisitesReady(windowsReport)) throw new Error("complete Windows prerequisite report should be ready");
if (wizard.prerequisitesReady({ ...windowsReport, tools: report.tools })) {
  throw new Error("Windows prerequisites should require the native app runtime");
}
const surfaceInventory = {
  preferredSurface: "claude-desktop",
  recommendedSurface: "vscode-copilot",
  surfaces: [
    { id: "vscode-copilot", installed: true },
    { id: "claude-desktop", installed: true },
  ],
};
if (wizard.chooseAiSurface(surfaceInventory) !== "claude-desktop") throw new Error("wizard does not remember a ready AI surface");
surfaceInventory.surfaces[1].installed = false;
if (wizard.chooseAiSurface(surfaceInventory) !== "vscode-copilot") throw new Error("wizard does not fall back from a stale AI surface preference");

const expectedRecommendationScores = {
  "vscode-copilot": 4,
  "copilot-cli": 3,
  "copilot-desktop": 2,
  "claude-desktop": 2,
  "claude-cli": 3,
  "codex-desktop": 3,
  "codex-cli": 3,
  "grok-cli": 1,
};
for (const [surfaceId, score] of Object.entries(expectedRecommendationScores)) {
  const recommendation = wizard.aiSurfaceRecommendation(surfaceId);
  if (recommendation.score !== score || recommendation.maximum !== 4 || !recommendation.label) {
    throw new Error(`wizard AI surface recommendation is wrong for ${surfaceId}`);
  }
}
if (wizard.aiSurfaceRecommendation("unknown").score !== 0) throw new Error("wizard unknown AI surface must not receive a recommendation score");

console.log("wizard state tests ok");
