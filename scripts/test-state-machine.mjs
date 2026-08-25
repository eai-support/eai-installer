/* ------------------------------------------------------------------
   The state machine, exercised without a browser.

   ui/state-machine.js is deliberately pure — no DOM, no Tauri, no
   timers — so every screen, every fault and every platform wording can
   be walked here rather than clicked through by hand. The prototype's
   review model was "every state on one page"; this is the same idea
   with the page replaced by assertions.

   Three things this file is for, in order of how much trouble they save:

   1. **No Mac sentences on Windows.** The prototype says "this Mac"
      eleven times. Every one of them is now a function of the platform,
      and the check below is the one that fails if a new one is written
      by hand.

   2. **Every fault reachable, and only on its own screen.** A fault
      raised on a screen that does not own it would be a fault nobody
      can see and nobody can clear.

   3. **The reveal goes both ways.** Deleting the app name has to close
      the questions under it. A counter would pass a test that only ever
      counts upwards; this one takes answers away again.
------------------------------------------------------------------- */

import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("../ui/state-machine.js", import.meta.url), "utf8");
const sandbox = { console, URLSearchParams };
sandbox.globalThis = sandbox;
vm.runInNewContext(source, sandbox);
const machine = sandbox.EAISetup;
if (!machine) throw new Error("state machine module did not register");

const PLATFORMS = ["macos", "windows", "linux"];

function fail(message) {
  throw new Error(message);
}

/* ============ 1. THE SCREENS ARE THE FLOW, IN ORDER ============== */

const expectedScreens = ["signin", "welcome", "setup", "running", "done", "handoff", "built"];
if (machine.SCREEN_ORDER.join(",") !== expectedScreens.join(",")) {
  fail(`state machine screens are not the tested flow: ${machine.SCREEN_ORDER.join(",")}`);
}
for (const id of expectedScreens) {
  const screen = machine.screenById(id);
  if (!screen) fail(`state machine has no screen ${id}`);
  if (!screen.name || !screen.note) fail(`screen ${id} does not say what it is for`);
}

/* Every fault belongs to exactly one screen, and that screen lists it. */
for (const [id, fault] of Object.entries(machine.FAULTS)) {
  if (fault.id !== id) fail(`fault ${id} disagrees with its own id`);
  const screen = machine.screenById(fault.screen);
  if (!screen) fail(`fault ${id} names a screen that does not exist`);
  if (!screen.faultIds.includes(id)) fail(`screen ${fault.screen} does not list its own fault ${id}`);
  if (typeof fault.note !== "function" || typeof fault.out !== "function") {
    fail(`fault ${id} has no note or no way out — a picture of an error nobody can leave`);
  }
}
for (const screen of machine.SCREENS) {
  for (const id of screen.faultIds) {
    if (machine.FAULTS[id]?.screen !== screen.id) fail(`screen ${screen.id} claims a fault it does not own: ${id}`);
  }
}

/* A fault cannot be raised on a screen that does not own it. */
{
  const state = machine.createState();
  machine.goTo(state, "signin");
  machine.raise(state, "init");
  if (state.faults.length) fail("a running-screen fault was raised on the sign-in screen");
  machine.raise(state, "prereq");
  machine.raise(state, "network");
  if (state.faults.length !== 2) fail("sign-in cannot hold both of its failures at once");
  machine.clear(state, "prereq");
  if (state.faults.join() !== "network") fail("clearing one sign-in fault clears the other");
}

/* Screens that say they hold one at a time actually hold one. */
for (const screen of machine.SCREENS.filter((item) => item.exclusive && item.faultIds.length > 1)) {
  const state = machine.createState();
  machine.goTo(state, screen.id);
  for (const id of screen.faultIds) machine.raise(state, id);
  if (state.faults.length !== 1) fail(`${screen.id} says it is exclusive but held ${state.faults.length} faults`);
}

/* Moving screens drops the faults of the screen being left. */
{
  const state = machine.createState();
  machine.raise(state, "prereq");
  machine.goTo(state, "welcome");
  if (state.faults.length) fail("a fault survived the move to another screen");
}

/* Faults come back in the screen's order, not the order they arrived. */
{
  const state = machine.createState();
  machine.raise(state, "network");
  machine.raise(state, "prereq");
  const order = machine.faultsInForce(state).map((fault) => fault.id).join(",");
  if (order !== "prereq,network") fail(`sign-in faults are not in chronological order: ${order}`);
}

/* ============ 2. NOTHING CALLS A WINDOWS PC A MAC ================ */

const MAC_WORDS = /\b(mac|macos|finder|xcode-select|command line tools|apple)\b/i;

/**
 * Every sentence the machine can produce, for one platform.
 *
 * If a screen learns to say something new, it has to be added here —
 * which is the point. The alternative is a Windows build that says
 * "Approve the prompt macOS showed" and nobody noticing until a tester
 * does.
 */
function everySentence(platform) {
  const lines = [];
  const state = machine.createState();
  state.platform = platform;

  const ready = machine.readyRow(platform);
  lines.push(ready.title, ready.body);

  for (const step of ["detect", "git", "node", "eai-cli"]) {
    const row = machine.workingRow(platform, step);
    lines.push(row.title, row.body);
  }

  for (const screen of machine.SCREENS) {
    machine.goTo(state, screen.id);
    lines.push(screen.name, screen.note);
    if (screen.combo) lines.push(screen.comboHead, screen.combo);
    if (screen.why) lines.push(screen.why);
    for (const id of screen.faultIds) {
      state.faults = [id];
      const fault = machine.FAULTS[id];
      const context = {
        step: "git",
        host: "api.example.com",
        account: "someone@example.com",
        projectName: "contract-renewals",
        harnessName: "Claude Code",
        projectPath: "/somewhere",
        title: "t",
        detail: "d",
        next: "n",
      };
      lines.push(fault.name, fault.note(platform, context), fault.out(platform, context));
      if (fault.head) lines.push(fault.head(platform, context));
      if (fault.body) lines.push(fault.body(platform, context));
      if (fault.message) lines.push(fault.message(platform, context));
      if (fault.problem) lines.push(...fault.problem(platform, context));
      if (fault.noteTitle) lines.push(fault.noteTitle(platform, {}), fault.noteBody(platform, {}));
      const written = machine.caption(state, context);
      lines.push(written.name, written.note);
    }
    state.faults = [];
    lines.push(machine.caption(state).note);
  }

  const surfaces = [
    { id: "claude-cli", name: "Claude Code", provider: "Anthropic", installUrl: "https://claude.com/product/claude-code", installed: true },
    { id: "copilot-cli", name: "GitHub Copilot CLI", provider: "GitHub", installUrl: "https://github.com/features/copilot", installed: false },
  ];
  lines.push(machine.harnessSubtitle(surfaces, platform));
  lines.push(machine.harnessSubtitle([], platform));
  lines.push(machine.harnessSubtitle(surfaces.map((s) => ({ ...s, installed: true })), platform));
  for (const group of machine.harnessGroups(surfaces, platform)) lines.push(group.label, group.note);
  const waiting = machine.harnessWaiting(surfaces[1], platform);
  lines.push(waiting.title, waiting.body);
  const alert = machine.harnessAlert(surfaces[1]);
  lines.push(alert.title, ...alert.parts.map((part) => (typeof part === "string" ? part : part.b)));
  lines.push(machine.harnessButtonLabel(surfaces[0]), machine.harnessButtonLabel(surfaces[1]), machine.harnessButtonLabel(surfaces[1], { waiting: true }));

  const handoff = machine.handoffCopy(surfaces[0], { projectName: "contract-renewals" });
  lines.push(handoff.title, handoff.sub, handoff.instruction, handoff.body, handoff.button);
  const built = machine.builtCopy({ projectName: "contract-renewals", workspaceName: "Northwind", harnessName: "Claude Code" });
  lines.push(built.title, built.body);

  const dev = machine.device(platform);
  lines.push(dev.device, dev.deviceCapitalised, dev.shortDevice, dev.fileManager, dev.chooserNote, dev.restartNote);
  lines.push(...machine.checkedTools(platform));
  lines.push(machine.setupSub(state, { account: "someone@example.com" }));
  for (const row of machine.runRows(state, {})) lines.push(row.label);

  return lines.filter(Boolean);
}

for (const platform of ["windows", "linux"]) {
  for (const line of everySentence(platform)) {
    if (MAC_WORDS.test(line)) fail(`the ${platform} build would say a Mac sentence: "${line}"`);
  }
}

/* And macOS still says the Mac things, so the platform copy is doing
   work rather than being neutral everywhere. */
{
  const macLines = everySentence("macos").join("\n");
  if (!/this Mac/.test(macLines)) fail("the macOS build no longer names the Mac");
  if (!/xcode-select/.test(macLines)) fail("the macOS prerequisite failure lost its actual fix");
  if (!/Finder/.test(macLines)) fail("the macOS location question no longer names Finder");
  const windowsLines = everySentence("windows").join("\n");
  if (!/this PC/.test(windowsLines)) fail("the Windows build does not name the PC");
  if (!/winget/.test(windowsLines)) fail("the Windows prerequisite failure does not name winget");
  if (!/File Explorer/.test(windowsLines)) fail("the Windows location question does not name File Explorer");
  const linuxLines = everySentence("linux").join("\n");
  if (!/this computer/.test(linuxLines)) fail("the Linux build has no neutral name for the machine");
  if (!/package manager/.test(linuxLines)) fail("the Linux prerequisite failure does not name the package manager");
}

/* An unknown platform must not fall back to Mac wording. */
{
  const unknown = machine.device("solaris");
  if (MAC_WORDS.test(`${unknown.device} ${unknown.fileManager} ${unknown.chooserNote}`)) {
    fail("an unrecognised platform falls back to Mac wording");
  }
}

/* Windows checks one more thing than the others, and says so. */
if (!machine.checkedTools("windows").includes("Windows app support")) {
  fail("the Windows readiness row does not mention the extra runtime it checks");
}
if (machine.checkedTools("macos").includes("Windows app support")) {
  fail("the macOS readiness row claims to have checked a Windows runtime");
}
if (!machine.readyRow("windows").body.includes(String(machine.checkedTools("windows").length))) {
  fail("the readiness row's count does not match the list it names");
}

/* ================= 3. SIGN-IN, ONE OR BOTH ====================== */

{
  const state = machine.createState();
  state.platform = "macos";
  if (machine.signinButtonLabel(state) !== "Sign in with browser") fail("the working sign-in button is not Sign in");
  machine.raise(state, "prereq");
  if (machine.signinButtonLabel(state) !== "Retry") fail("a broken sign-in screen does not offer Retry");

  const one = machine.signinHead(state, { prereq: { step: "git" } });
  if (one !== "One thing EAI needs could not be installed.") fail(`single-fault sign-in head is wrong: ${one}`);

  machine.raise(state, "network");
  const both = machine.signinHead(state, {});
  if (both !== machine.screenById("signin").comboHead) fail("two failures do not get the combination sentence");

  const rows = machine.signinProblems(state, { prereq: { step: "git" }, network: { host: "api.example.com" } });
  if (rows.length !== 2) fail("two failures do not produce two rows");
  if (!rows[1][0].includes("api.example.com")) fail("the network row does not name the host it could not reach");
  if (rows.some(([title, body]) => !title || !body)) fail("a failure row is missing its title or its explanation");
}

/* The prerequisite row names the thing that actually failed. */
for (const [step, expected] of [["git", "Git"], ["node", "Node.js and npm"], ["eai-cli", "the EAI CLI"], ["windows-runtime", "Windows app support"]]) {
  if (machine.toolName(step) !== expected) fail(`the plain name for ${step} is wrong: ${machine.toolName(step)}`);
}
{
  const [, body] = machine.FAULTS.prereq.problem("windows", { step: "eai-cli" });
  if (!body.includes("the EAI CLI")) fail("the Windows prerequisite failure does not name the tool that failed");
}

/* A check that did not finish is not an install that failed. Offering the
   install advice there sends somebody to approve a prompt nobody showed. */
for (const platform of PLATFORMS) {
  const [title, body] = machine.FAULTS.prereq.problem(platform, { step: "detect" });
  if (/install/i.test(title)) fail(`the ${platform} detection failure is worded as an install failure: ${title}`);
  if (/approve|winget|package manager/i.test(body)) {
    fail(`the ${platform} detection failure offers install advice for something that was never installed: ${body}`);
  }
  if (!/Retry/.test(body)) fail(`the ${platform} detection failure does not say how to leave it`);
  if (/could not be installed/i.test(machine.FAULTS.prereq.head(platform, { step: "detect" }))) {
    fail(`the ${platform} detection failure's title claims an install was attempted`);
  }
}

/* ================ 4. CLASSIFYING WHAT WENT WRONG ================ */

for (const message of [
  "getaddrinfo ENOTFOUND registry.npmjs.org",
  "curl: (6) Could not resolve host: nodejs.org",
  "connect ECONNREFUSED 10.0.0.1:443",
  "unable to get local issuer certificate",
  "Client network socket disconnected before secure TLS connection was established",
]) {
  if (!machine.looksLikeNetworkFailure(message)) fail(`a network failure was not recognised: ${message}`);
  if (machine.classifyBootstrapFailure("git", message) !== "network") {
    fail(`a network failure during a prerequisite install was blamed on the prerequisite: ${message}`);
  }
}
for (const message of [
  "The installer requires approval",
  "winget exited unsuccessfully",
  "xcode-select: note: install requested",
]) {
  if (machine.looksLikeNetworkFailure(message)) fail(`a local failure was mistaken for a network one: ${message}`);
  if (machine.classifyBootstrapFailure("git", message) !== "prereq") {
    fail(`a local prerequisite failure was blamed on the network: ${message}`);
  }
}
if (machine.classifyBootstrapFailure("login", "sign-in did not complete") !== "network") {
  fail("a sign-in failure at the readiness stage is not treated as a connection problem");
}
for (const message of ["mkdir: file already exists", "EEXIST", "the directory is not empty"]) {
  if (!machine.looksLikeTakenName(message)) fail(`a taken name was not recognised: ${message}`);
}
if (machine.looksLikeTakenName("the template could not be downloaded")) {
  fail("a template failure was mistaken for a taken name and sent back to the form");
}

/* ================= 5. THE REVEAL, BOTH WAYS ===================== */

{
  const answers = { workspace: false, name: false, folder: false };
  if (machine.stageForAnswers(answers) !== 1) fail("an unanswered form does not start at the first question");
  answers.workspace = true;
  if (machine.stageForAnswers(answers) !== 2) fail("answering the workspace does not reveal the name");
  answers.name = true;
  if (machine.stageForAnswers(answers) !== 3) fail("naming the app does not reveal the location");
  answers.folder = true;
  if (machine.stageForAnswers(answers) !== 4) fail("choosing a location does not complete the form");
  // And back down again: deleting the name has to close the question under it.
  answers.name = false;
  answers.folder = false;
  if (machine.stageForAnswers(answers) !== 2) fail("deleting the app name leaves the location question open");
}

{
  const state = machine.createState();
  machine.goTo(state, "setup", { stage: 1 });
  const steps = machine.setupSteps(state);
  if (steps.length !== 3) fail(`the form is not three questions: ${steps.length}`);
  if (steps.map((step) => step.id).join(",") !== "workspace,name,folder") {
    fail(`the form's questions are not the tested three: ${steps.map((step) => step.id)}`);
  }
  if (steps.map((step) => step.number).join("") !== "123") fail("the three questions are not numbered 1-2-3");
  if (steps[1].shown || steps[2].shown) fail("the first stage reveals questions that have not been reached");

  /* The app picker is gone on purpose: EAI Setup creates from the EAI
     template every time, so "new app, or one you already have" had one
     real answer. A fourth question reappearing means the scope crept
     back. See docs/known-issues.md. */
  if (machine.setupSteps(state, { hasApps: true }).length !== 3) {
    fail("the form still grows a fourth question when it is told about existing apps");
  }

  machine.goTo(state, "setup", { stage: 4 });
  if (!machine.setupComplete(state)) fail("a fully answered form is not complete");
  machine.raise(state, "name");
  if (machine.setupComplete(state)) fail("a form with a failure on it reports itself complete");
}

/* Stage and answers are the same fact read two ways, so they have to
   round-trip. Anything that draws this screen from a stage rather than
   from real answers — the preview, a review page — reads it through
   `answersForStage`, and a fixture that fills a field the stage says is
   empty is what makes a screen look finished with its next question
   still hidden. */
{
  const state = machine.createState();
  machine.goTo(state, "setup");
  /* Two to four, not one to four. Stage one and stage two hold the same
     answers — the workspace, which is answered on arrival — and differ
     only by the name question having appeared. The real app never rests
     in stage one, so the round trip starts where it can. */
  for (let stage = 2; stage <= 4; stage += 1) {
    state.stage = stage;
    const answers = machine.answersForStage(state);
    if (machine.stageForAnswers(answers) !== stage) {
      fail(`stage ${stage} does not survive a round trip through its own answers`);
    }
  }

  state.stage = 1;
  if (machine.answersForStage(state).name) fail("the workspace-only stage claims there is already a name");
  if (machine.answersForStage(state).folder) fail("the workspace-only stage claims there is already a location");
  state.stage = 2;
  const naming = machine.answersForStage(state);
  if (naming.name) fail("the stage where the name question has just appeared claims it is already answered");
  if (naming.folder) fail("the stage where the name question has just appeared claims a location too");
  state.stage = 3;
  if (!machine.answersForStage(state).name) fail("the stage after the name was given claims there is no name");
  if (machine.answersForStage(state).folder) fail("the stage where the chooser is still offered claims a location");
  state.stage = 4;
  const done = machine.answersForStage(state);
  if (!done.workspace || !done.name || !done.folder) fail("the finished form is missing an answer");
}

/* The location question has two shapes, and which one is drawn follows
   the state rather than whether a folder happens to be set. That
   divergence is what made "Location — choose" draw its answered shape:
   a greyed path and Change location, on the stage whose whole point is
   that nothing has been picked. */
{
  const state = machine.createState();
  machine.goTo(state, "setup", { stage: 1 });
  for (const stage of [1, 2, 3]) {
    state.stage = stage;
    if (machine.locationShape(state) !== "choose") {
      fail(`stage ${stage} draws the location question as answered before anybody has chosen`);
    }
  }
  state.stage = 4;
  if (machine.locationShape(state) !== "chosen") fail("the answered location question does not show the answer");
}

/* ==================== 6. CREATING, AS ROWS ====================== */

{
  const state = machine.createState();
  machine.goTo(state, "running");
  const rows = machine.runRows(state, { reached: "template" });
  if (rows.length !== 4) fail("the creating screen is not the four rows of the flow board");
  if (rows.map((row) => row.mark).join(",") !== "done,done,active,pending") {
    fail(`rows before the running one are not finished: ${rows.map((row) => row.mark).join(",")}`);
  }
  const failed = machine.runRows(state, { reached: "dependencies", failedAt: "dependencies" });
  if (failed.map((row) => row.mark).join(",") !== "done,done,done,fail") {
    fail("a failure does not land on the row that was running");
  }
  if (failed.filter((row) => row.mark === "fail").length !== 1) fail("a failure adds a row instead of marking one");
  const finished = machine.runRowsComplete();
  if (finished.some((row) => row.mark !== "done")) fail("a finished run leaves a row unticked");
}

/* Both streams the Creating screen listens to. The progress events are
   titles; the build summaries are whole sentences, and every one of them
   has to land on a row — a screen that sits on "Workspace connected" for
   the whole template download is a screen that looks stuck. */
for (const [line, expected] of [
  ["Installing app dependencies", "dependencies"],
  ["App dependencies ready", "dependencies"],
  ["Cloned from eai-app-template", "template"],
  ["Installed gofer assets", "template"],
  ["Generated .env.local", "template"],
  // The safe build summaries, verbatim from ui/wizard-state.js.
  ["Downloaded the supported EAI app template.", "template"],
  ["Updated the project settings.", "template"],
  ["Created the local app configuration.", "template"],
  ["Prepared the app data model starter files.", "template"],
  ["Prepared the AI workspace guidance.", "template"],
  ["Installed the EAI delivery guidance.", "template"],
  ["Prepared local version control.", "template"],
  ["Installed the required project packages.", "dependencies"],
]) {
  const row = machine.runRowForProgress(line, "");
  if (row !== expected) fail(`"${line}" was filed under ${row} rather than ${expected}`);
}

/* And every summary the installer can emit lands somewhere, so a new one
   cannot be added upstream and quietly stall the screen. */
{
  const wizardSource = await readFile(new URL("../ui/wizard-state.js", import.meta.url), "utf8");
  const summaries = [...wizardSource.matchAll(/add\("([^"]+)"\)/g)].map((match) => match[1]);
  if (summaries.length < 8) fail(`only ${summaries.length} build summaries found — the scan is not seeing wizard-state.js`);
  for (const summary of summaries) {
    if (/sign-in/i.test(summary)) continue;   // sign-in is not part of creating
    if (!machine.runRowForProgress(summary, "")) fail(`the build summary "${summary}" does not advance any Creating row`);
  }
}

/* ============= 7. THE HARNESS, HERE AND NOT HERE ================ */

const installedMac = [
  { id: "claude-cli", name: "Claude Code", provider: "Anthropic", installUrl: "https://claude.com/product/claude-code", installed: true },
  { id: "copilot-cli", name: "GitHub Copilot CLI", provider: "GitHub", installUrl: "https://github.com/features/copilot", installed: false },
];
const emptyMac = installedMac.map((surface) => ({ ...surface, installed: false }));

{
  const groups = machine.harnessGroups(installedMac, "macos");
  if (groups.length !== 2) fail("a machine with one tool installed does not get both groups");
  if (groups[0].id !== "ready") fail("the tools that are already here are not first");
  if (groups[0].items[0].id !== "claude-cli") fail("the installed tool is not in the ready group");
  if (!groups[0].label.includes("this Mac")) fail("the ready group does not say where ready means");

  const empty = machine.harnessGroups(emptyMac, "macos");
  if (empty.length !== 1 || empty[0].id !== "missing") {
    fail("a machine with nothing installed still draws an empty ready group");
  }
  if (!empty[0].note) fail("the not-installed group does not say where those come from");

  if (machine.harnessGroups([], "macos").length !== 0) fail("an empty inventory still draws headings");
}

{
  const subInstalled = machine.harnessSubtitle(installedMac, "macos");
  if (!subInstalled.includes("Claude Code is already on this Mac")) fail(`installed subtitle is wrong: ${subInstalled}`);
  const subEmpty = machine.harnessSubtitle(emptyMac, "macos");
  if (!subEmpty.includes("None of these are on this Mac yet")) fail(`empty subtitle is wrong: ${subEmpty}`);
  const subWindows = machine.harnessSubtitle(emptyMac, "windows");
  if (!subWindows.includes("this PC")) fail("the Windows subtitle does not name the PC");
}

{
  if (machine.harnessButtonLabel(installedMac[0]) !== "Next") fail("an installed tool does not move the flow on");
  if (machine.harnessButtonLabel(installedMac[1]) !== "Get GitHub Copilot CLI") fail("a missing tool does not offer to get it");
  if (machine.harnessButtonLabel(installedMac[1], { waiting: true }) !== "Waiting for GitHub Copilot CLI…") {
    fail("the waiting button does not say what it is waiting for");
  }
  if (machine.harnessButtonLabel(null) !== "Choose an AI tool") fail("no selection does not ask for one");

  if (machine.harnessAlert(installedMac[0])) fail("an installed tool is given a go-and-get-it alert");
  const alert = machine.harnessAlert(installedMac[1]);
  if (!alert.title.includes("github.com")) fail(`the alert does not name the site: ${alert.title}`);
  const body = alert.parts.map((part) => (typeof part === "string" ? part : part.b)).join("");
  if (!body.includes("GitHub")) fail("the alert does not say whose account they will need");
  if (!body.includes("already created")) fail("the alert does not reassure that the app already exists");

  const origin = machine.harnessOrigin({ installUrl: "https://code.visualstudio.com/download", provider: "GitHub" });
  if (origin.site !== "code.visualstudio.com") fail(`the origin host is wrong: ${origin.site}`);

  /* The CLI's install URLs point at documentation. "GitHub Copilot CLI
     comes from docs.github.com" is a sentence about a manual. */
  for (const [url, expected] of [
    ["https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli", "github.com"],
    ["https://learn.chatgpt.com/docs/codex/cli", "chatgpt.com"],
    ["https://www.example.com/get", "example.com"],
    ["https://claude.ai/download", "claude.ai"],
    ["https://x.ai/cli", "x.ai"],
  ]) {
    const site = machine.harnessOrigin({ installUrl: url, provider: "Someone" }).site;
    if (site !== expected) fail(`${url} was described as coming from ${site}, not ${expected}`);
  }
  if (machine.harnessOrigin(null).site !== "") fail("a missing surface still claims an origin");
}

/* ================= 8. STATES HAVE ADDRESSES ==================== */

{
  const state = machine.readAddress("?screen=signin&fault=prereq,network&platform=windows");
  if (state.screen !== "signin" || state.faults.length !== 2 || state.platform !== "windows") {
    fail("a two-fault Windows address does not round-trip");
  }
  const written = machine.writeAddress(state);
  if (!written.includes("fault=prereq%2Cnetwork") && !written.includes("fault=prereq,network")) {
    fail(`the address does not write both faults back: ${written}`);
  }
  if (!written.includes("platform=windows")) fail("the address forgets which platform it was describing");

  // A screen that cannot hold two takes the first one asked for.
  const single = machine.readAddress("?screen=setup&fault=workspace,name");
  if (single.faults.length !== 1) fail("an exclusive screen accepted two faults from a URL");

  // A fault that belongs to another screen is not honoured.
  const wrong = machine.readAddress("?screen=welcome&fault=prereq");
  if (wrong.faults.length) fail("a URL can raise a fault on a screen that does not own it");

  // An unknown screen leaves the state where it was.
  const unknown = machine.readAddress("?screen=nowhere");
  if (unknown.screen !== "signin") fail("an unknown screen name moves the app somewhere undefined");
}

/* =================== 9. STAGES ARE CLAMPED ===================== */

{
  const state = machine.createState();
  machine.goTo(state, "setup");
  state.stage = 99;
  if (machine.stageOf(state) !== 4) fail("an over-large stage is not clamped to the screen's last one");
  state.stage = -3;
  if (machine.stageOf(state) !== 1) fail("a negative stage is not clamped to the first one");
  machine.goTo(state, "welcome");
  if (machine.stageOf(state) !== 0) fail("a screen with no stages reports one anyway");
}

/* ================ 10. THE CAPTION, FOR REVIEW ================== */

{
  const state = machine.createState();
  machine.goTo(state, "signin");
  if (machine.caption(state).name !== "Sign in") fail("a working screen's caption is not its name");
  machine.raise(state, "prereq");
  const one = machine.caption(state, { prereq: { step: "git" } });
  if (!one.name.includes("—")) fail("a broken screen's caption does not name the failure");
  if (!one.note.includes("Way out:")) fail("a broken screen's caption does not say how to leave it");
  machine.raise(state, "network");
  const two = machine.caption(state);
  if (!two.name.includes("+")) fail("two failures are not both named in the caption");
  if (two.note !== machine.screenById("signin").combo) fail("two failures do not get the screen's own combination note");
}

console.log(`state machine tests ok (${machine.SCREEN_ORDER.length} screens, ${Object.keys(machine.FAULTS).length} faults, ${PLATFORMS.length} platforms)`);
