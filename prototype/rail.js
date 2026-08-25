/* ------------------------------------------------------------------
   The control rail.

   This file owns the *selection* and nothing else. It never draws a
   screen: it builds the query string the installer already understands
   and points the frame at it, so the panel on the right is the real
   ui/index.html rendering itself. That is the whole design of the page —
   there is no second copy of any screen here, so nothing here can be
   out of date with the app.

   The screens, the faults, which faults can co-occur, and the sentence
   describing each state all come from ../ui/state-machine.js. The rail
   asks that module what the questions are rather than listing them, so
   a screen or a failure added to the app appears here on the next
   reload without anybody editing this file.

   The rail is four questions, and only the first is about screens:

     Screen        · which of the seven
     State         · working, or the specific thing that broke
     This computer · macOS, Windows or Linux — the question three
                     screens change their wording for
     ...and then whatever the current screen actually reads.

   A group the screen does not read is not offered. The old version of
   this idea kept every control visible and dimmed, which is two groups
   and two sentences of apology on five of the seven screens.
------------------------------------------------------------------- */

const machine = window.EAISetup;

const frame = document.getElementById("frame");
const app = document.getElementById("app");
const rail = document.getElementById("rail");
const dead = document.getElementById("dead");

/* ====================== 1. THE SELECTION ========================

   The machine's own state, plus the handful of facts the installer
   takes from the query string that are not part of the state machine —
   which tools are on the machine, how far the form has been answered,
   which prerequisite failed. They live here rather than in the machine
   because they are fixtures, not states: the machine's job is to say
   what a state means, and "Codex is installed" is not a state, it is a
   thing that is true. */

const state = machine.createState();

const fixtures = {
  installed: [],          // surface ids on this machine — [] is the empty one
  pick: null,             // which one is selected, null = the app decides
  waiting: false,         // away on somebody else's website
  step: "git",            // which prerequisite failed
  busy: null,             // the quiet fix-up, mid-run
  admin: false,           // macOS asking for the password
  workspaces: 1,
  reached: "template",    // how far the creating screen has got
  signin: null,           // waiting · waiting-long
  link: false,            // the CLI printed a sign-in URL
};

/* The fixtures' own vocabulary, kept next to the rail that offers it. */
const SURFACES = [
  { id: "vscode-copilot", name: "GitHub Copilot in VS Code" },
  { id: "copilot-cli", name: "GitHub Copilot CLI" },
  { id: "claude-cli", name: "Claude Code" },
  { id: "codex-cli", name: "Codex CLI" },
  { id: "grok-cli", name: "Grok Build" },
];

const PLATFORMS = [
  ["macOS", "macos"],
  ["Windows", "windows"],
  ["Linux", "linux"],
];

const PREREQ_STEPS = [
  ["Git", "git"],
  ["Node.js and npm", "node"],
  ["The EAI CLI", "eai-cli"],
  ["Windows app support", "windows-runtime"],
  ["The check never finished", "detect"],
];

/* ==================== 2. THE APP'S ADDRESS ======================

   One function, and it is the only coupling between this page and the
   app. Everything the rail can express has to come out here, and
   anything it cannot express is a state this page cannot reach. */

function address() {
  const query = new URLSearchParams({ screen: state.screen });

  if (state.faults.length) query.set("fault", machine.faultsInForce(state).map((fault) => fault.id).join(","));
  if (state.platform !== "macos") query.set("platform", state.platform);

  const screen = machine.screenById(state.screen);
  if (screen?.stages) query.set("stage", String(machine.stageOf(state)));

  if (uses("harness")) {
    query.set("installed", fixtures.installed.length ? fixtures.installed.join(",") : "none");
    if (fixtures.pick) query.set("pick", fixtures.pick);
    if (fixtures.waiting) query.set("waiting", "1");
  }
  if (state.screen === "signin") {
    if (machine.isBroken(state, "prereq")) query.set("step", fixtures.step);
    if (fixtures.busy) query.set("busy", fixtures.busy);
    if (fixtures.admin) query.set("admin", "1");
  }
  if (state.screen === "welcome") {
    if (fixtures.signin) query.set("signin", fixtures.signin);
    if (fixtures.link) query.set("link", "1");
  }
  if (state.screen === "running") query.set("reached", fixtures.reached);
  if (state.screen === "setup" && fixtures.workspaces === 2) query.set("workspaces", "2");
  return `../ui/index.html?${query}`;
}

function uses(control) {
  return (machine.screenById(state.screen)?.uses || []).includes(control);
}

/* ======================= 3. SHOWING IT ==========================

   The frame is set to the window's real size, read from tauri.conf.json
   rather than typed here. A prototype that reviews the app at a size the
   app is never opened at is reviewing a different app — and the size in
   that file has already been changed once during this work. */

async function sizeFrame() {
  try {
    const response = await fetch("../src-tauri/tauri.conf.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const config = await response.json();
    const window_ = config.app?.windows?.[0];
    if (window_?.width && window_?.height) {
      frame.style.width = `${window_.width}px`;
      frame.style.height = `${window_.height}px`;
      return;
    }
    throw new Error("tauri.conf.json declares no window size");
  } catch (error) {
    // A guess is better than a collapsed frame, but say it is a guess.
    frame.style.width = "900px";
    frame.style.height = "740px";
    showDead(error);
  }
}

/**
 * When it does not come up, say which of the two things went wrong.
 *
 * There are exactly two and they want opposite responses: either this
 * page is being opened straight off disk, in which case nothing will
 * ever load, or the server is fine and the app itself threw. A
 * diagnostic that cannot tell those apart sends somebody to check a
 * server that was never the problem.
 */
function showDead(error) {
  dead.hidden = false;
  dead.innerHTML = location.protocol === "file:"
    ? "<b>This page needs a static server.</b> It loads the real app out of <code>../ui</code> rather than "
      + "keeping a second copy, and a browser will not fetch a sibling folder over <code>file://</code>. "
      + "Run <code>npm run prototype</code> from the repo root."
    : `<b>The page loaded, but something under it failed.</b> The server is not the problem. `
      + `<code>${String(error.message || error)}</code>`;
}

function show() {
  const target = address();
  // Only when it actually changed: reassigning src reloads the frame,
  // and reloading it on every repaint restarts the hand-off's video and
  // throws away whatever was typed in the form.
  if (app.dataset.at !== target) {
    app.dataset.at = target;
    app.src = target;
  }
  renderRail();
  renderCaption();
  history.replaceState(null, "", `?${new URLSearchParams(address().split("?")[1])}`);
}

/* ===================== 4. BUILDING THE RAIL ===================== */

const TICK = '<svg viewBox="0 0 24 24" fill="none"><path d="M5 12.5l4.5 4.5L19 7.5" stroke="#fff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';

function group(label, note) {
  const node = document.createElement("div");
  node.className = "rl-group";
  const heading = document.createElement("div");
  heading.className = "rl-label";
  heading.textContent = label;
  node.append(heading);
  if (note) {
    const explanation = document.createElement("div");
    explanation.className = "rl-note";
    explanation.textContent = note;
    node.append(explanation);
  }
  return node;
}

function option(text, on, onPick) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `rl-opt${on ? " on" : ""}`;
  button.textContent = text;
  button.addEventListener("click", onPick);
  return button;
}

/**
 * A fault, with a box in front of it.
 *
 * Checkbox or radio, decided by the screen rather than by taste: a
 * checkbox promises the others are independent of it, so the faults on
 * a screen that can only hold one get radios instead of a checkbox that
 * silently unticks its neighbour. A control that lies about the model
 * underneath it is worse than no control.
 */
function tickbox(text, on, kind, onToggle) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `rl-tick${on ? " on" : ""}`;
  button.setAttribute("role", kind);
  button.setAttribute("aria-checked", String(on));
  button.innerHTML = `<span class="box ${kind}">${TICK}</span><span class="tx"></span>`;
  button.querySelector(".tx").textContent = text;
  button.addEventListener("click", onToggle);
  return button;
}

function renderRail() {
  const screen = machine.screenById(state.screen);
  rail.replaceChildren();

  /* --- which screen ---

     A dropdown rather than seven stacked names. The list was the longest
     thing in the rail and it was permanent: six of its seven lines were
     never the answer, and they pushed the controls that change what you
     are looking at below the fold. */
  const screens = group("Screen");
  const select = document.createElement("select");
  select.className = "rl-select";
  select.setAttribute("aria-label", "Screen");
  for (const item of machine.SCREENS) {
    const option_ = document.createElement("option");
    option_.value = item.id;
    option_.textContent = item.name;
    option_.selected = item.id === state.screen;
    select.append(option_);
  }
  select.addEventListener("change", () => goTo(select.value));
  screens.append(select);
  rail.append(screens);

  /* --- working, or which of the breaks ---

     The pill is the fast way back to the happy path — one click, rather
     than untangling whatever is ticked. Under it, the failures
     themselves, and they are not a menu of one: ticking two is how you
     find out whether a screen designed one error at a time can hold
     both. */
  const faults = group("State");
  const pill = document.createElement("div");
  pill.className = "rl-pill";
  for (const [text, wantBroken] of [["Working", false], ["Broken", true]]) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = `rl-chip${(state.faults.length > 0) === wantBroken ? " on" : ""}`;
    chip.disabled = wantBroken && !screen.faultIds.length;
    chip.textContent = text;
    chip.addEventListener("click", () => {
      state.faults = wantBroken ? [screen.faultIds[0]] : [];
      show();
    });
    pill.append(chip);
  }
  faults.append(pill);

  if (!screen.faultIds.length) {
    const none = document.createElement("div");
    none.className = "rl-note";
    none.textContent = "Nothing on this screen can fail — it has no network call and nothing to answer.";
    faults.append(none);
  } else if (state.faults.length) {
    const kind = screen.exclusive ? "radio" : "checkbox";
    for (const id of screen.faultIds) {
      const fault = machine.FAULTS[id];
      faults.append(tickbox(fault.name, machine.isBroken(state, id), kind, () => {
        if (screen.exclusive) state.faults = [id];
        else if (machine.isBroken(state, id)) machine.clear(state, id);
        else machine.raise(state, id);
        show();
      }));
    }
    if (screen.why) {
      const why = document.createElement("div");
      why.className = "rl-note";
      why.textContent = screen.why;
      faults.append(why);
    }
  }
  rail.append(faults);

  /* --- the machine ---

     Offered everywhere, because unlike the prototype's "This Mac" it
     changes the wording of every screen rather than the shape of the
     last three. It is the control this port exists to have. */
  const platform = group("This computer", "Changes what the screens call the machine, its file manager and its package manager.");
  for (const [text, value] of PLATFORMS) {
    platform.append(option(text, state.platform === value, () => {
      state.platform = value;
      // Windows is the only platform with a fourth prerequisite, so a
      // selection naming it cannot survive a move away from Windows.
      if (value !== "windows" && fixtures.step === "windows-runtime") fixtures.step = "git";
      show();
    }));
  }
  rail.append(platform);

  /* --- how far through the reveal ---

     Offered only on the working path: a failure decides the shape of
     this screen by itself, and a control claiming to also decide it
     would be a control with no effect. */
  if (screen.stages && !state.faults.length) {
    const stages = group(screen.stageLabel);
    screen.stages.forEach(([label], index) => {
      stages.append(option(label, machine.stageOf(state) === index + 1, () => {
        state.stage = index + 1;
        show();
      }));
    });
    rail.append(stages);
  }

  if (state.screen === "running") rail.append(runProgress());
  if (state.screen === "setup") rail.append(formShape());
  if (state.screen === "signin") rail.append(signinDetail());
  if (state.screen === "welcome") rail.append(welcomeDetail());
  if (uses("harness")) rail.append(harnessDetail());
}

/* --- how far eai init has got ---------------------------------------

   The row that is spinning, or on a failure the row that failed. It is
   the only thing that moves on this screen, so it is the only thing
   there is to review about it. */

function runProgress() {
  const broken = state.faults.length > 0;
  const node = group(broken ? "Where it failed" : "How far it has got");
  for (const row of machine.RUN_ROWS) {
    node.append(option(row.label, fixtures.reached === row.id, () => {
      fixtures.reached = row.id;
      show();
    }));
  }
  if (!broken) {
    node.append(option("Everything finished", fixtures.reached === "done", () => {
      fixtures.reached = "done";
      show();
    }));
  }
  return node;
}

/* --- the shapes of the form only company accounts ever see ---------- */

function formShape() {
  const node = group("This account", "Self-serve sign-up never sees the second of these.");
  node.append(option("One workspace", fixtures.workspaces === 1, () => {
    fixtures.workspaces = 1;
    show();
  }));
  node.append(option("Two workspaces", fixtures.workspaces === 2, () => {
    fixtures.workspaces = 2;
    show();
  }));
  return node;
}

/* --- what the sign-in screen is actually doing ---------------------- */

function signinDetail() {
  if (machine.isBroken(state, "prereq")) {
    const node = group("Which prerequisite", "The failure says a different true sentence for each of these.");
    for (const [text, value] of PREREQ_STEPS) {
      if (value === "windows-runtime" && state.platform !== "windows") continue;
      node.append(option(text, fixtures.step === value, () => {
        fixtures.step = value;
        show();
      }));
    }
    return node;
  }

  const node = group("Before anyone presses anything", "The quiet fix-up, which is most of what this screen is.");
  node.append(option("Finished — the tick", !fixtures.busy && !fixtures.admin, () => {
    fixtures.busy = null;
    fixtures.admin = false;
    show();
  }));
  node.append(option("Checking the computer", fixtures.busy === "detect" && !fixtures.admin, () => {
    fixtures.busy = "detect";
    fixtures.admin = false;
    show();
  }));
  node.append(option("Installing something", fixtures.busy === "git" && !fixtures.admin, () => {
    fixtures.busy = "git";
    fixtures.admin = false;
    show();
  }));
  if (state.platform === "macos") {
    node.append(option("Asking for the Mac password", fixtures.admin, () => {
      fixtures.admin = true;
      fixtures.busy = "git";
      show();
    }));
  }
  return node;
}

/* --- the wait on a window we do not control ------------------------- */

function welcomeDetail() {
  if (state.faults.length) {
    const node = group("The link", "The CLI only prints it when it is given a callback port, which the installer does not do.");
    node.append(option("No link — a sentence instead", !fixtures.link, () => { fixtures.link = false; show(); }));
    node.append(option("A link was printed", fixtures.link, () => { fixtures.link = true; show(); }));
    return node;
  }
  const node = group("The moment", "The happy path is a beat nobody acts on. The wait is not.");
  node.append(option("Signed in", !fixtures.signin, () => { fixtures.signin = null; show(); }));
  node.append(option("Waiting on the browser", fixtures.signin === "waiting", () => { fixtures.signin = "waiting"; show(); }));
  node.append(option("Waiting, long enough to worry", fixtures.signin === "waiting-long", () => { fixtures.signin = "waiting-long"; show(); }));
  if (fixtures.signin) {
    node.append(option(fixtures.link ? "…and a link was printed" : "…and no link was printed", fixtures.link, () => {
      fixtures.link = !fixtures.link;
      show();
    }));
  }
  return node;
}

/* --- what is on the machine, which is the question the last three
       screens exist to answer ------------------------------------- */

function harnessDetail() {
  const node = group("AI tools on this computer", "The one fact that changes the last three screens.");

  node.append(option("Nothing installed", fixtures.installed.length === 0, () => {
    fixtures.installed = [];
    fixtures.pick = null;
    fixtures.waiting = false;
    show();
  }));
  node.append(option("Claude Code only", fixtures.installed.join() === "claude-cli", () => {
    fixtures.installed = ["claude-cli"];
    fixtures.pick = null;
    fixtures.waiting = false;
    show();
  }));
  node.append(option("Claude Code and Codex CLI", fixtures.installed.join() === "claude-cli,codex-cli", () => {
    fixtures.installed = ["claude-cli", "codex-cli"];
    fixtures.pick = null;
    fixtures.waiting = false;
    show();
  }));
  node.append(option("All of them", fixtures.installed.length === SURFACES.length, () => {
    fixtures.installed = SURFACES.map((surface) => surface.id);
    fixtures.pick = null;
    fixtures.waiting = false;
    show();
  }));

  const chosen = group("Which one is picked");
  chosen.append(option("Whichever the app would pick", !fixtures.pick, () => { fixtures.pick = null; show(); }));
  for (const surface of SURFACES) {
    chosen.append(option(surface.name, fixtures.pick === surface.id, () => { fixtures.pick = surface.id; show(); }));
  }
  node.append(chosen);

  // Only reachable for something that is not here: waiting for a tool
  // that is already installed is not a state the app can be in.
  const pickedId = fixtures.pick || SURFACES.find((surface) => fixtures.installed.includes(surface.id))?.id || SURFACES[0].id;
  if (state.screen === "done" && !fixtures.installed.includes(pickedId) && !state.faults.length) {
    node.append(tickbox("Away installing it", fixtures.waiting, "checkbox", () => {
      fixtures.waiting = !fixtures.waiting;
      show();
    }));
  }
  return node;
}

/* ================= 5. WHAT THE STATE IS, IN WORDS ===============

   The name of the state and what it is for, above the app — and on a
   failure, the way out, which is the one thing a screenshot of an error
   cannot tell you and half of these do not have. */

function renderCaption() {
  const written = machine.caption(state, {
    step: fixtures.step,
    host: "api.au.myenterprise.ai",
    account: "you@example.com",
    projectName: "contract-renewals",
    harnessName: SURFACES.find((surface) => surface.id === fixtures.pick)?.name || "the AI tool",
    projectPath: "/Users/you/Projects/contract-renewals",
  });
  document.getElementById("capName").textContent = written.name;
  document.getElementById("capNote").textContent = written.note;
}

/* ========================= 6. GOING ============================= */

function goTo(screenId) {
  machine.goTo(state, screenId);
  // Waiting belongs to the screen that can be waited on.
  if (screenId !== "done") fixtures.waiting = false;
  show();
}

function stepBy(by) {
  const index = machine.SCREEN_ORDER.indexOf(state.screen) + by;
  if (index < 0 || index >= machine.SCREEN_ORDER.length) return;
  goTo(machine.SCREEN_ORDER[index]);
}

window.addEventListener("keydown", (event) => {
  if (event.target.matches("input, textarea, select")) return;
  if (event.key === "ArrowLeft") stepBy(-1);
  if (event.key === "ArrowRight") stepBy(1);
});

document.getElementById("copyLink").addEventListener("click", async (event) => {
  const url = new URL(address(), location.href).href;
  try {
    await navigator.clipboard.writeText(url);
    event.target.textContent = "Copied";
    setTimeout(() => { event.target.textContent = "Copy the app's link"; }, 1500);
  } catch {
    event.target.textContent = url;
  }
});

/* Reload of a state, from its own address. A state worth discussing is a
   state worth linking to. */
machine.readAddress(location.search, state);
const initial = new URLSearchParams(location.search);
if (initial.has("installed")) {
  fixtures.installed = initial.get("installed").split(",").filter((id) => id && id !== "none");
}
if (initial.has("pick")) fixtures.pick = initial.get("pick");
if (initial.get("waiting") === "1") fixtures.waiting = true;
if (initial.has("step")) fixtures.step = initial.get("step");
if (initial.has("busy")) fixtures.busy = initial.get("busy");
if (initial.get("admin") === "1") fixtures.admin = true;
if (initial.get("workspaces") === "2") fixtures.workspaces = 2;
if (initial.has("reached")) fixtures.reached = initial.get("reached");
if (initial.has("signin")) fixtures.signin = initial.get("signin");
if (initial.get("link") === "1") fixtures.link = true;

sizeFrame().then(show);
