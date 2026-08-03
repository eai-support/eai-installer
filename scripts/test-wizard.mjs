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

const report = {
  platform: "macos",
  package_manager: "brew",
  tools: [
    { command: "git", version: "git version 2.40" },
    { command: "node", version: "v20.0.0" },
    { command: "npm", version: "10.0.0" },
    { command: "eai", version: "3.8.0" },
  ],
};
if (!wizard.prerequisitesReady(report)) throw new Error("complete prerequisite report should be ready");
if (wizard.needsHomebrew(report, new Map(report.tools.map((tool) => [tool.command, tool])))) {
  throw new Error("Homebrew should not be needed when brew is available");
}
if (wizard.prerequisitesReady({ platform: "linux", package_manager: "apt-get", tools: [{ command: "git", version: "2" }] })) {
  throw new Error("incomplete prerequisite report should not be ready");
}

console.log("wizard state tests ok");
