const output = document.querySelector("#output");
const platform = document.querySelector("#platform");

function show(message, detail = "") {
  output.textContent = detail ? `${message} ${detail}` : message;
}

async function invoke(command, args = {}) {
  const tauri = window.__TAURI__;
  if (!tauri?.core?.invoke) {
    return { ok: true, demo: true, message: "Browser preview: the desktop command is available in the signed EAI Setup app." };
  }
  return tauri.core.invoke(command, args);
}

function setToolState(report) {
  for (const tool of report.tools) {
    const state = document.querySelector(`#${tool.command}-state`);
    if (state) state.textContent = tool.version ? `Installed: ${tool.version}` : "Not installed";
  }
  platform.textContent = `${report.platform} · ${report.architecture}`;
}

async function detect() {
  try {
    const report = await invoke("detect_environment");
    if (report.demo) {
      platform.textContent = "Desktop preview";
      return;
    }
    setToolState(report);
  } catch (error) {
    show("Could not inspect this computer.", String(error));
  }
}

async function runStep(step) {
  if (step === "init") {
    const name = document.querySelector("#project-name").value.trim();
    const directory = document.querySelector("#project-directory").value.trim();
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) {
      show("Use a kebab-case project name, for example my-eai-app.");
      return;
    }
    const result = await invoke("run_bootstrap", { step, projectName: name, directory: directory || null });
    show(result.message, result.command ? `Next command: ${result.command.replace("<project-name>", name)}` : "");
    return;
  }
  const result = await invoke("run_bootstrap", { step, projectName: null, directory: null });
  show(result.message, result.command ? `Next: ${result.command}` : "");
  if (result.output) console.info(result.output);
  await detect();
}

for (const button of document.querySelectorAll("[data-action]")) {
  button.addEventListener("click", () => runStep(button.dataset.action));
}

detect();
