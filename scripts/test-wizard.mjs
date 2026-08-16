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

console.log("wizard state tests ok");
