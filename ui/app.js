/* ------------------------------------------------------------------
   EAI Setup — the app that the state machine drives.

   ui/state-machine.js owns the state and every sentence about it. This
   file owns the DOM and the outside world: Tauri commands, the CLI's
   progress events, the folder chooser, the browser hand-off. It makes
   no decisions of its own about what a screen says.

   The pattern is the prototype's, and it is the whole reason the
   machine can be trusted: `paint()` resets the window to its base and
   then applies the current state from scratch. There is no "undo the
   failure" path, because nothing is ever half-applied — and the list of
   things an undo path has to remember is the list of bugs.

   Two rules for anyone editing this file:

   · **Ask the machine, don't write the sentence.** If a screen needs a
     new line of copy, it goes in state-machine.js where the tests can
     read it and where the Windows and Linux wordings live next to the
     Mac one.

   · **el() throws.** This file reaches into markup by id. When a screen
     gains or loses an element, "index.html has no #welcomeMark" is the
     answer; "Cannot read properties of null" is a morning of hunting.
------------------------------------------------------------------- */

const machine = window.EAISetup;
const helpers = window.EAIWizard;

/* ===================== 1. REACHING THE MARKUP ==================== */

function el(id) {
  const node = document.getElementById(id);
  if (!node) throw new Error(`ui/index.html has no #${id} — app.js and the markup have drifted apart`);
  return node;
}

/** For the boxes the app builds at runtime rather than ships in markup. */
function maybe(id) {
  return document.getElementById(id);
}

function screenNode(id) {
  const node = document.querySelector(`[data-screen="${id}"]`);
  if (!node) throw new Error(`ui/index.html has no [data-screen="${id}"]`);
  return node;
}

function stepNode(name) {
  return document.querySelector(`.i3-step[data-step="${name}"]`);
}

/* ======================== 2. THE STATE =========================== */

const state = machine.createState();

/** Everything the outside world has told us. Never rendered directly. */
const facts = {
  environment: null,        // detect_environment
  account: null,            // the address the CLI signed in as
  signinUrl: null,          // the link, for when the browser never came back
  connectivity: null,       // { ok, host }
  tenants: [],
  selectedTenantId: null,
  /* Only the release test ever sets this. EAI Setup creates from the
     EAI template every time, so there is no app question in the form —
     see docs/known-issues.md. The plumbing stays because the CLI takes
     --app-key and the guest-machine gate can be pointed at a fixed app. */
  selectedAppKey: null,
  projectName: "",
  projectFolder: "",
  projectPath: null,
  projectDirectory: null,
  surfaces: null,           // detect_ai_surfaces inventory
  selectedSurfaceId: null,
  waitingForSurfaceId: null,
  failureContext: {},       // per-fault detail, handed to the machine
  runReached: "workspace",
  runFailedAt: null,
  runValues: {},
  demo: false,
  prereqBusy: null,         // the step whose row is spinning
  prereqDetail: "",
  signinWaiting: false,
  signinEscapeShown: false,   // the way out, once waiting has become a problem
};

let e2eConfig = null;
let e2eAppCreated = false;
let initInProgress = false;
let readinessInProgress = false;
let welcomeEscapeTimer = null;
let harnessPollTimer = null;
let pendingAdminPassword = null;

function platform() {
  return facts.environment?.platform || state.platform;
}

/* ======================= 3. THE RECORD =========================== */

/**
 * What the installer actually did, for the call in fifty where the
 * designed sentence is not enough.
 *
 * Deliberately not the screen. The prototype has no panel like this,
 * and the reason it works is that nothing in it competes with the
 * primary: it is shut, it is the same height on every screen, and no
 * failure opens it.
 */
const diagnostics = [];

function note(message, kind = "update") {
  const previous = diagnostics.at(-1);
  if (previous?.message === message && previous.kind === kind) return;
  diagnostics.push({ at: Date.now(), message, kind });
  if (diagnostics.length > 60) diagnostics.shift();
  renderDiagnostics();
}

function renderDiagnostics() {
  const log = maybe("diagLog");
  if (!log) return;
  log.replaceChildren();
  for (const entry of [...diagnostics].reverse()) {
    const item = document.createElement("li");
    item.dataset.kind = entry.kind;
    const time = document.createElement("time");
    time.textContent = new Date(entry.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" });
    const text = document.createElement("span");
    text.textContent = entry.message;
    item.append(time, text);
    log.append(item);
  }
  const status = maybe("diagStatus");
  if (status) {
    const failed = diagnostics.filter((entry) => entry.kind === "error").length;
    status.textContent = failed
      ? `${failed} problem${failed === 1 ? "" : "s"} recorded`
      : diagnostics.length === 0
        ? "nothing yet"
        : `${diagnostics.length} step${diagnostics.length === 1 ? "" : "s"}`;
  }
  const foot = maybe("diagFoot");
  if (foot) {
    const report = facts.environment;
    foot.textContent = report
      ? `${report.platform} · ${report.architecture} · ${report.tools.map((tool) => `${tool.command} ${tool.version || "missing"}`).join(" · ")}`
      : "";
  }
}

/** Command output, summarised into things that are safe to show. */
function recordCommandSummaries(commandOutput) {
  for (const detail of helpers.summarizeCommandOutput(commandOutput)) note(detail);
}

/* ==================== 4. TALKING TO THE SHELL ==================== */

async function invoke(command, args = {}) {
  const tauri = window.__TAURI__;
  if (!tauri?.core?.invoke) {
    facts.demo = true;
    return { ok: true, demo: true, message: "Preview mode: install actions run in the signed EAI Setup app." };
  }
  return tauri.core.invoke(command, args);
}

async function listenForBootstrapProgress() {
  const eventApi = window.__TAURI__?.event;
  if (!eventApi?.listen) return;
  if (!window.__eaiBootstrapProgressListener) {
    window.__eaiBootstrapProgressListener = await eventApi.listen("bootstrap-progress", ({ payload }) => {
      onBootstrapProgress(payload);
    });
  }
  if (!window.__eaiBootstrapSummaryListener) {
    window.__eaiBootstrapSummaryListener = await eventApi.listen("bootstrap-summary", ({ payload }) => {
      if (!payload?.detail) return;
      note(payload.detail);
      if (payload.step !== "init") return;
      const row = machine.runRowForProgress(payload.detail, "");
      if (!row) return;
      facts.runReached = row;
      if (state.screen === "running") paint();
    });
  }
  if (!window.__eaiSigninUrlListener) {
    window.__eaiSigninUrlListener = await eventApi.listen("bootstrap-signin-url", ({ payload }) => {
      if (!payload?.url) return;
      facts.signinUrl = payload.url;
      note("The browser sign-in link is ready.");
      if (state.screen === "welcome") paint();
    });
  }
}

/**
 * The CLI's progress, turned into whichever screen is listening.
 *
 * Sign-in and Creating are the two screens with something running under
 * them, and they read the same stream differently: one wants a row that
 * says which tool is installing, the other wants to know how far down
 * its own four rows the CLI has got.
 */
function onBootstrapProgress(payload) {
  if (!payload) return;
  note(`${payload.title}: ${payload.detail}`);
  if (payload.step === "init") {
    const row = machine.runRowForProgress(payload.title, payload.detail);
    if (row) facts.runReached = row;
    if (state.screen === "running") paint();
    return;
  }
  if (["git", "node", "eai-cli", "homebrew", "detect"].includes(payload.step)) {
    facts.prereqBusy = payload.step;
    facts.prereqDetail = payload.detail;
    if (state.screen === "signin") paint();
  }
}

/* ======================= 5. THE RESET ============================

   Everything paint() is allowed to change, put back. This is the only
   reason the machine is trustworthy: a state is what the screen paints
   on top of this, never what the last state happened to leave behind. */

function reset() {
  for (const node of document.querySelectorAll("[data-screen]")) node.hidden = true;
  el("builtOverlay").hidden = true;
  el("builtOverlay").classList.remove("on");

  const dev = machine.device(platform());

  // Sign in
  el("signinSub").textContent = machine.signinHead(machine.createState());
  el("checkRows").replaceChildren();
  el("adminPanel").hidden = !pendingAdminPassword;
  el("setupCreate").textContent = "Create an EAI account";
  el("setupSignin").textContent = "Sign in with browser";
  el("setupSignin").classList.remove("off");
  el("setupSignin").disabled = false;

  // Signed in
  const mark = el("welcomeMark");
  mark.classList.remove("failed", "waiting");
  mark.innerHTML = '<svg viewBox="0 0 24 24" fill="none">'
    + '<path d="M5 12.5l4.5 4.5L19 7.5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  el("welcomeTitle").textContent = "Signed in";
  el("welcomeSub").textContent = facts.account || "";
  el("welcomeSub").classList.remove("wide");
  el("welcomeActs").hidden = true;
  el("welcomeRetry").hidden = false;
  el("welcomeRetry").textContent = "Try again";
  el("welcomeFine").hidden = false;
  el("welcomeFine").textContent = "If your browser never opened, paste the link into it yourself.";

  // Set up
  el("setupSub").textContent = machine.setupSub(state, { account: facts.account });
  el("wsRows").replaceChildren();
  el("wsNote").hidden = true;
  el("wsActs").hidden = true;
  el("folderHelp").textContent = dev.chooserNote;
  // Only when it differs: assigning `value` moves the caret to the end,
  // and the reveal repaints while somebody is still typing the name.
  if (el("projName").value.trim() !== facts.projectName) el("projName").value = facts.projectName;
  // The location question's two shapes are PAINT.setup's, because they
  // follow the stage. Reset only puts it back to the unanswered one.
  el("projFolder").value = "";
  el("locCombo").hidden = true;
  el("chooseFolderStart").hidden = false;
  for (const field of document.querySelectorAll(".eai-field")) {
    const error = field.querySelector(".eai-err");
    if (error) error.hidden = true;
    field.classList.remove("invalid", "shake");
  }
  for (const name of ["workspace", "app", "name", "folder"]) {
    const node = stepNode(name);
    if (node) {
      node.hidden = true;
      node.classList.remove("answered");
    }
  }
  el("projName").readOnly = false;
  el("createApp").disabled = true;

  // Creating
  el("runTitle").textContent = `Creating ${facts.projectName || "your EAI app"}`;
  el("runSub").textContent = "Downloading the app template into your folder.";
  el("runLines").replaceChildren();
  el("runNote").hidden = true;
  el("runActs").hidden = true;

  // Choose a harness
  el("harnessRows").replaceChildren();
  el("harnessSub").textContent = "";
  el("harnessNote").hidden = true;
  el("harnessRefresh").hidden = true;
  el("harnessGo").disabled = false;
  maybe("harnessWait")?.setAttribute("hidden", "");

  // Hand-off
  el("handoffTitle").textContent = "One last thing";
  el("handoffNote").hidden = true;
  el("handoffFolder").hidden = !facts.projectPath;
}

/* ==================== 6. THE SEVEN PAINTS ========================

   One function per screen. Each is handed the faults in force — a list,
   possibly empty — and is responsible for the whole screen either way.
   No function here reads what another one did. */

const SPINNER = "<s></s><s></s><s></s><s></s><s></s><s></s><s></s><s></s>";

function escapeHtml(value) {
  return String(value).replace(/[&<>"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[character]));
}

function addCheckRow(mark, title, body) {
  const row = document.createElement("div");
  row.className = `eai-row${mark === "fail" ? " failed" : mark === "busy" ? " active" : ""}`;
  const glyph = mark === "done" ? '<i class="mk done">&#10003;</i>'
    : mark === "busy" ? `<i class="mk busy">${SPINNER}</i>`
      : '<i class="mk fail bang">!</i>';
  row.innerHTML = glyph
    + `<span class="lbl">${escapeHtml(title)}`
    + (body ? `<span class="sub">${escapeHtml(body)}</span>` : "")
    + "</span>";
  el("checkRows").appendChild(row);
  return row;
}

const PAINT = {
  /**
   * Sign in, with none, one or both of its failures.
   *
   * The two are independent, so the screen is built out of them rather
   * than switched between them: each failure contributes one row, and
   * the title is the count. The tick does not survive a failure — it is
   * replaced by it, because the app cannot call itself ready and refuse
   * to continue in the same breath.
   */
  signin(faults) {
    el("signinSub").textContent = machine.signinHead(state, facts.failureContext);

    if (faults.length) {
      for (const [title, body] of machine.signinProblems(state, facts.failureContext)) {
        addCheckRow("fail", title, body);
      }
      // The design's own inversion: the primary greys out because
      // sign-in genuinely cannot proceed, and the way forward is Retry.
      el("setupCreate").textContent = "Retry";
      el("setupSignin").classList.add("off");
      el("setupSignin").disabled = true;
      return;
    }

    if (facts.prereqBusy) {
      const row = machine.workingRow(platform(), facts.prereqBusy, facts.prereqDetail);
      addCheckRow("busy", row.title, row.body);
      el("setupSignin").classList.add("off");
      el("setupSignin").disabled = true;
      el("adminPanel").hidden = !pendingAdminPassword;
      return;
    }

    const ready = machine.readyRow(platform());
    addCheckRow("done", ready.title, ready.body);
  },

  /* The tick and the address are the whole screen — until they aren't. */
  welcome(faults) {
    if (faults.length) {
      const mark = el("welcomeMark");
      mark.classList.add("failed");
      mark.innerHTML = '<svg viewBox="0 0 24 24" fill="none">'
        + '<path d="M12 6.5v7" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/>'
        + '<circle cx="12" cy="17.6" r="1.45" fill="currentColor"/></svg>';
      el("welcomeTitle").textContent = faults[0].head(platform(), facts.failureContext.callback || {});
      el("welcomeSub").textContent = faults[0].body(platform(), facts.failureContext.callback || {});
      el("welcomeSub").classList.add("wide");
      el("welcomeActs").hidden = false;
      el("welcomeCopy").hidden = !facts.signinUrl;
      // The fine print explains the button beside it. Without the link
      // there is no button, and the sentence is advice about something
      // the screen cannot give them.
      el("welcomeFine").hidden = !facts.signinUrl;
      return;
    }

    if (facts.signinWaiting) {
      const mark = el("welcomeMark");
      mark.classList.add("waiting");
      mark.innerHTML = `<i class="mk busy">${SPINNER}</i>`;
      el("welcomeTitle").textContent = "Waiting for your browser";
      el("welcomeSub").textContent = "Finish signing in there and this window carries on by itself. "
        + "Your password is only ever typed into the browser.";
      el("welcomeSub").classList.add("wide");

      /* The way out, but only once waiting has gone on long enough to be
         a problem. Before that, a button offering an escape from
         something that is working is a button asking whether it is.

         Try again is not offered here, and that is deliberate: the login
         command is still running and there is no way to stop it, so a
         second one would race the first against the same account.

         The link is offered when we have one. Today the CLI only prints
         it when it is given an explicit callback port, which the
         installer does not do — so most of the time this is a sentence
         rather than a button, and it says the true thing rather than
         offering to copy something that does not exist. */
      el("welcomeActs").hidden = !facts.signinEscapeShown;
      el("welcomeCopy").hidden = !facts.signinUrl;
      el("welcomeRetry").hidden = true;
      el("welcomeFine").hidden = !facts.signinEscapeShown;
      el("welcomeFine").textContent = facts.signinUrl
        ? "Still waiting. If your browser never opened, copy the link and paste it in yourself."
        : "Still waiting on your browser. Finish signing in there if the tab is still open — "
          + "otherwise close this window and open EAI Setup again to start over. Nothing has been saved, so that is safe.";
      return;
    }

    el("welcomeTitle").textContent = "Signed in";
    el("welcomeSub").textContent = facts.account || "Your account is connected.";
  },

  /**
   * Set up, revealed downwards.
   *
   * The reveal is a derivation, not a counter: the stage comes from
   * which answers are in, so taking one back closes the questions under
   * it. A counter that only goes up cannot do that, and a form whose
   * later questions survive the deletion of the answer they depend on
   * is a form that will create something nobody asked for.
   */
  setup(faults) {
    const fault = faults[0] || null;
    el("setupSub").textContent = machine.setupSub(state, { account: facts.account });

    if (fault?.id === "workspace") {
      /* "No workspace for this account" underneath a green tick naming a
         workspace is the screen contradicting itself in two lines, so
         the row goes rather than sitting above the thing that says there
         isn't one. */
      el("wsRows").replaceChildren();
      const node = stepNode("workspace");
      node.hidden = false;
      const context = facts.failureContext.workspace || {};
      el("wsNoteTitle").textContent = context.title || fault.name;
      el("wsNoteBody").textContent = fault.body(platform(), { account: facts.account, detail: context.detail });
      el("wsNote").hidden = false;
      /* A workspace nobody can add you to has no retry — an EAI admin
         has to add them and then they sign in again. A list that timed
         out has one. Offering the wrong one of those is worse than
         offering neither, so it follows what the failure actually was. */
      el("wsActs").hidden = !context.retryable;
      return;
    }

    for (const step of machine.setupSteps(state)) {
      const node = stepNode(step.id);
      if (!node) continue;
      node.hidden = !step.shown;
      node.classList.toggle("answered", step.answered);
      const numeral = node.querySelector(".i3-num");
      if (numeral) numeral.textContent = step.answered ? "✓" : step.number;
    }

    renderWorkspaceRows();

    /* The location question, in whichever of its two shapes the state
       says. Before an answer it is one button at the left, because
       somebody reads the heading and wants to go and choose; a greyed
       path sitting there instead reads as an answer that is already in. */
    const chosen = machine.locationShape(state) === "chosen";
    el("chooseFolderStart").hidden = chosen;
    el("locCombo").hidden = !chosen;
    if (chosen) el("projFolder").value = facts.projectFolder;

    if (fault?.id === "name") {
      setFieldError("name", fault.message(platform(), { projectName: facts.projectName }));
    }

    /* Every question answered, and the name actually usable. The reveal
       is happy with any name; the button that creates a folder is not. */
    el("createApp").disabled = !machine.setupComplete(state) || !helpers.isKebabCase(facts.projectName);
  },

  /* eai init, said in the words of the flow board. */
  running(faults) {
    const fault = faults[0] || null;
    const values = {
      workspace: selectedTenant()?.displayName || "",
      folder: facts.projectPath || facts.projectDirectory || "",
      template: facts.runValues.template || "",
      dependencies: facts.runValues.dependencies || "",
    };

    const rows = fault
      ? machine.runRows(state, { reached: facts.runReached, values, failedAt: facts.runFailedAt || facts.runReached })
      : machine.runRows(state, { reached: facts.runReached, values });

    for (const row of rows) addRunRow(row);

    if (fault) {
      const context = facts.failureContext.init || {};
      el("runTitle").textContent = fault.head(platform(), { projectName: facts.projectName });
      el("runSub").textContent = fault.body(platform(), context);
      el("runNoteTitle").textContent = fault.noteTitle(platform(), context);
      el("runNoteBody").textContent = fault.noteBody(platform(), context);
      el("runNote").hidden = false;
      el("runActs").hidden = false;
      return;
    }

    el("runTitle").textContent = `Creating ${facts.projectName}`;
    el("runSub").textContent = "This takes a couple of minutes. You can leave it running.";
  },

  /**
   * Choosing a harness.
   *
   * Two groups: what is already here, and what has to be fetched from
   * somebody else's website. Which group the chosen tool is in decides
   * the button's verb and whether there is an alert under the row, and
   * nothing else on the screen changes — which is what makes the
   * installed and not-installed machines comparable.
   */
  done(faults) {
    const fault = faults[0] || null;
    const surfaces = facts.surfaces?.surfaces || [];

    if (fault?.id === "detect") {
      el("harnessSub").textContent = fault.head(platform());
      el("harnessNoteTitle").textContent = fault.head(platform());
      el("harnessNoteBody").textContent = fault.body(platform());
      el("harnessNote").hidden = false;
      // The primary is the check. A second button beside it reading the
      // same words is the screen offering one action twice.
      el("harnessRefresh").hidden = true;
      el("harnessGo").textContent = "Check again";
      return;
    }

    el("harnessSub").textContent = machine.harnessSubtitle(surfaces, platform());
    renderHarnessRows(surfaces);
    el("harnessRefresh").hidden = false;

    const chosen = selectedSurface();

    if (fault?.id === "install") {
      el("harnessNoteTitle").textContent = fault.head(platform(), { harnessName: chosen?.name });
      el("harnessNoteBody").textContent = fault.body(platform());
      el("harnessNote").hidden = false;
      el("harnessGo").textContent = machine.harnessButtonLabel(chosen);
      return;
    }

    if (facts.waitingForSurfaceId && chosen?.id === facts.waitingForSurfaceId) {
      showWaiting(chosen);
      return;
    }

    el("harnessGo").textContent = machine.harnessButtonLabel(chosen);
    el("harnessGo").disabled = !chosen;
  },

  /* One instruction, on its own screen. */
  handoff(faults) {
    const surface = selectedSurface();
    const copy = machine.handoffCopy(surface, { projectName: facts.projectName });
    el("handoffTitle").textContent = copy.title;
    el("handoffSub").textContent = copy.sub;
    // /eai is a command, and the design sets it as one. Built from nodes
    // rather than innerHTML so a tool name from the CLI can never become
    // markup on the way to the screen.
    const body = el("harnessEaiBody");
    body.replaceChildren();
    for (const [index, piece] of copy.body.split("/eai").entries()) {
      if (index > 0) {
        const code = document.createElement("code");
        code.textContent = "/eai";
        body.append(code);
      }
      body.append(document.createTextNode(piece));
    }
    el("handoffGo").textContent = copy.button;
    el("handoffFolder").hidden = !facts.projectPath;

    const film = el("harnessVideo");
    if (window.mountVideo && film.dataset.mountedFor !== (surface?.id || "none")) {
      window.mountVideo(film, { app: surface?.name || "your AI tool", project: facts.projectName || "your app" });
      film.dataset.mountedFor = surface?.id || "none";
    }

    if (faults.length) {
      const fault = faults[0];
      el("handoffNoteTitle").textContent = fault.head(platform(), { harnessName: surface?.name });
      el("handoffNoteBody").textContent = fault.body(platform(), { projectPath: facts.projectPath });
      el("handoffNote").hidden = false;
    }
  },

  /* Built. It lands over the hand-off, so the hand-off is painted first. */
  built() {
    PAINT.handoff([]);
    screenNode("handoff").hidden = false;
    const copy = machine.builtCopy({
      projectName: facts.projectName,
      workspaceName: selectedTenant()?.displayName,
      harnessName: selectedSurface()?.name,
    });
    el("builtTitle").textContent = copy.title;
    const built = el("builtBody");
    built.replaceChildren();
    const name = facts.projectName || "Your app";
    for (const [index, piece] of copy.body.split(name).entries()) {
      if (index > 0) {
        const strong = document.createElement("b");
        strong.textContent = name;
        built.append(strong);
      }
      built.append(document.createTextNode(piece));
    }
    el("builtFolder").hidden = !facts.projectPath;
    const overlay = el("builtOverlay");
    overlay.hidden = false;
    requestAnimationFrame(() => overlay.classList.add("on"));
  },
};

/* ========================= 7. PAINT ============================== */

/**
 * The bar across the top, redrawn with everything else.
 *
 * Rebuilt rather than patched, like the rest of paint(): a bar whose
 * segments are updated in place is a bar that can be left showing the
 * last state's colours when a step is skipped.
 */
function renderSteps() {
  const list = el("steps");
  list.replaceChildren();
  for (const step of machine.stepper(state)) {
    const item = document.createElement("li");
    item.className = `eai-step ${step.status}`;
    if (step.current) item.setAttribute("aria-current", "step");
    const name = document.createElement("span");
    name.className = "sr-only";
    name.textContent = step.status === "failed" ? `${step.name} — needs attention` : step.name;
    item.append(name);
    list.append(item);
  }
}

function paint() {
  /* Which field somebody was in, so a repaint triggered by their own
     typing does not take the caret away from them. The reveal repaints
     mid-word by design — that is what makes the next question appear —
     so this is not an edge case, it is the common path. */
  const focused = document.activeElement?.id;
  const caret = document.activeElement?.selectionStart ?? null;

  reset();
  const screen = machine.screenById(state.screen);
  if (state.screen !== "built") screenNode(state.screen).hidden = false;
  renderSteps();
  PAINT[state.screen](machine.faultsInForce(state));
  document.querySelector(".eai-body").scrollTop = 0;

  if (focused) {
    const node = maybe(focused);
    if (node && typeof node.focus === "function" && !node.closest("[hidden]")) {
      node.focus();
      if (caret !== null && typeof node.setSelectionRange === "function") {
        try { node.setSelectionRange(caret, caret); } catch { /* not a text field */ }
      }
    }
  }

  if (screen && window.__eaiDevAddress) history.replaceState(null, "", machine.writeAddress(state));
}

function goTo(screenId, options) {
  const from = state.screen;
  machine.goTo(state, screenId, options);
  paint();
  if (from !== state.screen) focusScreenHeading();
}

/**
 * Put the cursor at the top of the screen somebody has just arrived on.
 *
 * Without this, moving from Set up to Creating leaves a screen reader
 * announcing the Create app button on a screen that no longer exists,
 * and leaves the keyboard focus on a detached node.
 */
function focusScreenHeading() {
  const node = state.screen === "built"
    ? maybe("builtTitle")
    : screenNode(state.screen).querySelector("h3");
  if (!node) return;
  node.setAttribute("tabindex", "-1");
  node.focus({ preventScroll: true });
}

function raise(faultId, context) {
  if (context) facts.failureContext[faultId] = context;
  machine.raise(state, faultId);
  note(`${machine.faultById(faultId)?.name || faultId}`, "error");
  paint();
}

/* ===================== 8. DRAWING THE PIECES ===================== */

function addRunRow({ label, value, mark }) {
  const row = document.createElement("div");
  row.className = `eai-row ${mark === "fail" ? "failed" : mark}`;
  const glyph = mark === "done" ? '<i class="mk done">&#10003;</i>'
    : mark === "active" ? `<i class="mk busy">${SPINNER}</i>`
      : mark === "fail" ? '<i class="mk fail">&#10005;</i>'
        : '<i class="mk pending"></i>';
  // A row that has not run has nothing to report. Showing the folder path
  // beside "Folder created" before the folder exists is the screen
  // claiming something it has not done.
  const reported = mark === "pending" ? "" : value || "";
  row.innerHTML = glyph
    + `<span class="lbl">${escapeHtml(label)}</span>`
    + `<span class="val">${escapeHtml(reported)}</span>`;
  el("runLines").appendChild(row);
}

function setFieldError(name, message) {
  const field = document.querySelector(`.eai-field[data-field="${name}"]`);
  if (!field) return;
  const error = field.querySelector(".eai-err");
  error.querySelector("span").textContent = message;
  error.hidden = false;
  field.classList.add("invalid");
}

function clearFieldError(name) {
  const field = document.querySelector(`.eai-field[data-field="${name}"]`);
  if (!field) return;
  field.querySelector(".eai-err").hidden = true;
  field.classList.remove("invalid", "shake");
}

function pickRow(label, meta, selected, onPick) {
  const row = document.createElement("button");
  row.type = "button";
  row.className = "eai-row pick";
  row.innerHTML = (selected ? '<i class="mk done">&#10003;</i>' : '<i class="mk pending"></i>')
    + `<span class="lbl">${escapeHtml(label)}`
    + (meta ? `<span class="sub">${escapeHtml(meta)}</span>` : "")
    + "</span>";
  row.addEventListener("click", onPick);
  return row;
}

function selectedTenant() {
  return facts.tenants.find((tenant) => tenant.id === facts.selectedTenantId) || null;
}

function renderWorkspaceRows() {
  const rows = el("wsRows");
  rows.replaceChildren();
  if (!facts.tenants.length) return;

  // One workspace is not a question. It is shown answered, which is what
  // the prototype does, because a list of one asks somebody to confirm
  // something they were never given a choice about.
  if (facts.tenants.length === 1) {
    const tenant = facts.tenants[0];
    const row = document.createElement("div");
    row.className = "eai-row";
    row.innerHTML = '<i class="mk done">&#10003;</i>'
      + `<span class="lbl">${escapeHtml(tenant.displayName)}</span>`;
    rows.appendChild(row);
    return;
  }

  for (const tenant of facts.tenants) {
    rows.appendChild(pickRow(
      tenant.displayName,
      tenant.slug || "",
      tenant.id === facts.selectedTenantId,
      () => chooseTenant(tenant.id),
    ));
  }
}

/* The tiles, so six tools are six things to look at rather than six lines
   of text. Keyed on the surface id's family, because the ids are the
   CLI's contract and the providers are not going to renumber.

   The brand colour is deliberately NOT here. It is a `data-tile`
   attribute that ui/styles.css matches on, because the app runs under a
   `default-src 'self'` policy, and a background written into innerHTML
   as a style attribute is exactly what that policy exists to refuse. A browser with no CSP shows the colour and a signed
   build shows a grey square, which is the worst kind of difference to
   discover in a screenshot. */
const TILES = {
  vscode: '<svg viewBox="0 0 64 64" fill="none"><path d="M46 9 30 26l-9-7-5 3.4 7.6 6.6L16 36l5 3.4 9-7 16 17 8-4V13z" fill="#ffffff"/></svg>',
  copilot: '<svg viewBox="0 0 64 64" fill="none"><path d="M32 20c8 0 12 3 12 3s4-1 6 1c1.6 1.6 1.4 6 1.4 6s2.6 1.4 2.6 5.6c0 6-4 9.4-8 11.2-4 1.8-9 2.2-14 2.2s-10-.4-14-2.2c-4-1.8-8-5.2-8-11.2 0-4.2 2.6-5.6 2.6-5.6s-.2-4.4 1.4-6c2-2 6-1 6-1s4-3 12-3z" fill="#ffffff"/><ellipse cx="24" cy="37" rx="5.4" ry="6.4" fill="#0d1117"/><ellipse cx="40" cy="37" rx="5.4" ry="6.4" fill="#0d1117"/></svg>',
  claude: '<svg viewBox="0 0 24 24" fill="none"><g stroke="#ffffff" stroke-width="2.6" stroke-linecap="round"><path d="M12 4v16"/><path d="M4 12h16"/><path d="M6.3 6.3l11.4 11.4"/><path d="M17.7 6.3L6.3 17.7"/></g></svg>',
  codex: '<svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="7.5" stroke="#ffffff" stroke-width="2.2"/></svg>',
  gemini: '<svg viewBox="0 0 24 24" fill="none"><path d="M12 2c.6 5.2 4.2 8.8 9.4 9.4-5.2.6-8.8 4.2-9.4 9.4-.6-5.2-4.2-8.8-9.4-9.4C7.8 10.8 11.4 7.2 12 2z" fill="#ffffff"/></svg>',
  grok: '<svg viewBox="0 0 24 24" fill="none"><g stroke="#ffffff" stroke-width="2.4" stroke-linecap="round"><path d="M6 6l12 12"/><path d="M18 6L6 18"/></g></svg>',
};

function tileFor(surface) {
  const family = Object.keys(TILES).find((key) => surface.id.includes(key));
  return { family: family || "other", svg: family ? TILES[family] : "" };
}

const TICK_SVG = '<svg viewBox="0 0 24 24" fill="none"><path d="M5 12.5l4.5 4.5L19 7.5" stroke="#ffffff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const ALERT_ICON = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">'
  + '<circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.9"/>'
  + '<path d="M12 11v5.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'
  + '<circle cx="12" cy="7.8" r="1.15" fill="currentColor"/></svg>';

function renderHarnessRows(surfaces) {
  const rows = el("harnessRows");
  rows.replaceChildren();

  for (const group of machine.harnessGroups(surfaces, platform())) {
    const head = document.createElement("div");
    head.className = "i4-group";
    head.innerHTML = `<b>${escapeHtml(group.label)}</b>${group.note ? `<span>${escapeHtml(group.note)}</span>` : ""}`;
    rows.appendChild(head);

    for (const surface of group.items) {
      const chosen = surface.id === facts.selectedSurfaceId;
      const pick = document.createElement("div");
      pick.className = `i4-pick${chosen ? " on" : ""}`;

      const tile = tileFor(surface);
      const row = document.createElement("button");
      row.type = "button";
      row.className = `eai-row i4-row${surface.installed ? " ready" : " missing"}${chosen ? " on" : ""}`;
      row.innerHTML = `<span class="mark">${TICK_SVG}</span>`
        + `<span class="tile" data-tile="${tile.family}">${tile.svg}</span>`
        + `<span class="nm">${escapeHtml(surface.name)}</span>`
        + `<span class="state">${surface.installed ? "installed" : "not installed"}</span>`;
      row.addEventListener("click", () => chooseSurface(surface.id));
      pick.appendChild(row);

      const alert = machine.harnessAlert(surface);
      if (chosen && alert) {
        const box = document.createElement("div");
        box.className = "i4-alert i4-pick-alert";
        box.innerHTML = `${ALERT_ICON}<div class="tx"><b></b><span></span></div>`;
        box.querySelector("b").textContent = alert.title;
        box.querySelector("span").replaceChildren(...alert.parts.map((part) => {
          if (typeof part === "string") return document.createTextNode(part);
          const node = document.createElement("b");
          node.textContent = part.b;
          return node;
        }));
        pick.appendChild(box);
      }
      rows.appendChild(pick);
    }
  }
}

function showWaiting(surface) {
  const copy = machine.harnessWaiting(surface, platform());
  // The alert said "we'll open their site". It has been opened. Leaving it
  // up beside a box that says we are waiting for the result is the screen
  // giving two different accounts of where somebody is.
  for (const alert of document.querySelectorAll(".i4-pick-alert")) alert.hidden = true;
  let box = maybe("harnessWait");
  if (!box) {
    box = document.createElement("div");
    box.className = "i4-wait";
    box.id = "harnessWait";
    box.innerHTML = `<i class="mk busy">${SPINNER}</i><div class="tx"><b></b><span></span></div>`;
    el("harnessRows").after(box);
  }
  box.querySelector(".tx b").textContent = copy.title;
  box.querySelector(".tx span").textContent = copy.body;
  box.hidden = false;
  el("harnessGo").disabled = true;
  el("harnessGo").textContent = machine.harnessButtonLabel(surface, { waiting: true });
}

function selectedSurface() {
  const surfaces = facts.surfaces?.surfaces || [];
  return surfaces.find((surface) => surface.id === facts.selectedSurfaceId) || null;
}

/* =================== 9. READINESS AND SIGN-IN ==================== */

async function detect() {
  facts.prereqBusy = "detect";
  facts.prereqDetail = "";
  if (state.screen === "signin") paint();
  try {
    const report = await invoke("detect_environment");
    if (report.demo) {
      facts.demo = true;
      facts.environment = { platform: state.platform, architecture: "preview", tools: [] };
      note("Preview mode: nothing on this computer is changed.");
      return true;
    }
    facts.demo = false;
    facts.environment = report;
    state.platform = report.platform;
    note(`Checked ${report.platform} ${report.architecture}.`);
    return true;
  } catch (error) {
    note(`The computer check could not finish: ${helpers.cleanText(error)}`, "error");
    return false;
  }
}

async function checkConnectivity() {
  try {
    const result = await invoke("check_connectivity");
    if (result?.demo) return { ok: true, host: "api.eai" };
    facts.connectivity = result;
    return result;
  } catch (error) {
    // A shell that cannot run the probe is not evidence that the network
    // is down, and claiming it is would send somebody to their VPN over
    // a missing curl. Unknown is reported as reachable and login finds
    // out for certain.
    note(`Connectivity could not be checked: ${helpers.cleanText(error)}`);
    return { ok: true, host: "", unknown: true };
  }
}

function missingSteps() {
  const report = facts.environment;
  if (!report || facts.demo) return [];
  const tools = new Map(report.tools.map((tool) => [tool.command, tool]));
  const steps = [];
  if (!tools.get("git")?.version) steps.push("git");
  if (!tools.get("node")?.version
    || !tools.get("npm")?.version
    || (report.platform === "windows" && !tools.get("windows-runtime")?.version)) steps.push("node");
  if (!tools.get("eai")?.version) steps.push("eai-cli");
  return steps;
}

/**
 * The quiet fix-up behind the sign-in screen.
 *
 * Everything here happens before anybody presses anything, which is why
 * the screen only ever shows the result: a tick, or the row for what
 * stood in the way.
 */
async function runReadiness() {
  if (readinessInProgress) return false;
  readinessInProgress = true;
  machine.clear(state);
  facts.failureContext = {};
  try {
    await listenForBootstrapProgress();

    if (!await detect()) {
      facts.prereqBusy = null;
      raise("prereq", { steps: ["detect"] });
      return false;
    }

    const reachable = await checkConnectivity();
    if (reachable && reachable.ok === false) {
      facts.prereqBusy = null;
      raise("network", { host: reachable.host || "the EAI API" });
      return false;
    }

    if (facts.demo) {
      facts.prereqBusy = null;
      paint();
      return true;
    }

    /* Every missing prerequisite is attempted, and every failure is
       reported together.

       This used to stop at the first one. On a machine locked down
       enough to refuse Git — which is the machine this failure exists
       for — Node and the CLI are usually refused too, so stopping at
       Git meant telling somebody one thing, waiting while they fixed it,
       and then telling them the next. Three round trips to learn what
       was knowable on the first.

       The one thing not attempted after a failure is a tool that needed
       the failed one: the EAI CLI is installed with npm, so reporting
       that it could not be installed when the real cause is that Node is
       missing names the wrong thing. */
    const failed = [];
    for (const step of missingSteps()) {
      if (step === "eai-cli" && failed.includes("node")) {
        note("Skipped the EAI CLI: it is installed with npm, and Node.js is not ready.");
        continue;
      }
      facts.prereqBusy = step;
      facts.prereqDetail = "";
      if (state.screen === "signin") paint();
      if (!await runBootstrapStep(step, { collect: true })) failed.push(step);
      await detect();
    }

    facts.prereqBusy = null;
    if (failed.length) {
      raise("prereq", { steps: failed });
      return false;
    }
    if (!helpers.prerequisitesReady(facts.environment, facts.demo)) {
      raise("prereq", { steps: missingSteps().length ? missingSteps() : ["git"] });
      return false;
    }
    note("Everything EAI needs is ready.");
    paint();
    return true;
  } finally {
    readinessInProgress = false;
  }
}

/**
 * One prerequisite.
 *
 * `collect` is for the readiness sweep, which attempts every missing
 * tool and raises one failure naming all of them at the end. Without it
 * each step would raise its own, and the screen would redraw itself
 * around a single failure three times before showing the real answer.
 */
async function runBootstrapStep(step, { collect = false } = {}) {
  const stop = (faultId, context) => {
    facts.prereqBusy = null;
    if (collect && faultId === "prereq") return false;
    raise(faultId, context);
    return false;
  };
  let result;
  try {
    const adminPassword = step === "git" && platform() === "macos" ? await requestMacAdminPassword() : null;
    if (step === "git" && platform() === "macos" && !adminPassword) {
      return stop("prereq", { steps: ["git"], detail: "Approval was cancelled, so nothing was changed." });
    }
    result = await invoke("run_bootstrap", {
      step,
      projectName: null,
      directory: null,
      adminPassword,
      companyTenantId: null,
    });
  } catch (error) {
    const message = helpers.cleanText(error);
    note(`${machine.toolName(step)} could not be installed: ${message}`, "error");
    return stop(machine.classifyBootstrapFailure(step, message), {
      steps: [step],
      host: facts.connectivity?.host || "the EAI API",
    });
  }
  if (result.output) recordCommandSummaries(result.output);
  if (!result.ok && !result.demo) {
    const message = helpers.cleanText(result.message);
    note(`${machine.toolName(step)} could not be installed: ${message}`, "error");
    return stop(machine.classifyBootstrapFailure(step, message), {
      steps: [step],
      host: facts.connectivity?.host || "the EAI API",
    });
  }
  note(`${machine.toolName(step)} is ready.`);
  return true;
}

function requestMacAdminPassword() {
  const panel = el("adminPanel");
  const input = el("adminPassword");
  panel.hidden = false;
  input.value = "";
  input.focus();
  // The row above the panel would otherwise spin under "Installing Git"
  // while nothing is installing and the app is waiting on a person.
  facts.prereqDetail = "Waiting for your approval before Apple's installer can run.";
  note("Waiting for the Mac login password to authorise Apple's Command Line Tools.");
  return new Promise((resolve) => {
    pendingAdminPassword = resolve;
    el("adminSubmit").onclick = () => {
      const password = input.value;
      if (!password) return;
      panel.hidden = true;
      input.value = "";
      const finish = pendingAdminPassword;
      pendingAdminPassword = null;
      finish(password);
    };
    el("adminCancel").onclick = () => {
      panel.hidden = true;
      input.value = "";
      const finish = pendingAdminPassword;
      pendingAdminPassword = null;
      finish(null);
    };
  });
}

/* --- sign-in ---------------------------------------------------------- */

async function runLogin() {
  // `eai login` can take minutes — the browser is somebody else's window.
  // A second press would start a second command against the same account.
  if (facts.signinWaiting) return;
  facts.signinWaiting = true;
  facts.signinUrl = null;
  facts.signinEscapeShown = false;
  goTo("welcome");
  await listenForBootstrapProgress();

  /* `eai login` blocks until the browser comes home, and if the tab is
     closed it never does. The designed failure — "the browser didn't
     come back" — can only be raised when the command returns, so this
     is the other half of it: after long enough to be a problem, the way
     out appears without waiting for a command that may not return. */
  clearTimeout(welcomeEscapeTimer);
  welcomeEscapeTimer = setTimeout(() => {
    facts.signinEscapeShown = true;
    if (state.screen === "welcome" && facts.signinWaiting) paint();
  }, 40000);

  let result;
  try {
    result = await invoke("run_bootstrap", { step: "login", projectName: null, directory: null, companyTenantId: null });
  } catch (error) {
    facts.signinWaiting = false;
    clearTimeout(welcomeEscapeTimer);
    note(`Sign-in did not complete: ${helpers.cleanText(error)}`, "error");
    raise("callback", {});
    return;
  }
  facts.signinWaiting = false;
  clearTimeout(welcomeEscapeTimer);

  if (result.output) {
    recordCommandSummaries(result.output);
    const address = /authenticated as[:\s]+([^\s]+@[^\s]+)/i.exec(helpers.cleanText(result.output));
    if (address) facts.account = address[1];
  }

  if (!result.ok && !result.demo) {
    note(`Sign-in did not complete: ${helpers.cleanText(result.message)}`, "error");
    raise("callback", {});
    return;
  }

  note("Browser sign-in completed.");
  paint();
  await loadWorkspaces();
}

/* ================ 10. WORKSPACES, APPS AND THE FORM ============== */

async function loadWorkspaces() {
  if (facts.demo) {
    facts.tenants = [{ id: "preview", displayName: "Preview workspace", slug: "preview", active: true, apps: [] }];
    facts.selectedTenantId = "preview";
    goTo("setup", { stage: machine.stageForAnswers({ workspace: true }) });
    return true;
  }
  try {
    const tenants = await invoke("get_company_tenants");
    if (!Array.isArray(tenants) || tenants.length === 0) {
      facts.tenants = [];
      goTo("setup");
      raise("workspace", { account: facts.account });
      return false;
    }
    facts.tenants = tenants;
    facts.selectedTenantId = helpers.resolveTenantSelection(tenants, facts.selectedTenantId);
    note(`${tenants.length} workspace${tenants.length === 1 ? "" : "s"} available.`);
    goTo("setup");
    syncStage();
    return true;
  } catch (error) {
    const failure = helpers.describeWorkspaceFailure(error);
    note(`${failure.title}: ${failure.diagnostic}`, "error");
    facts.tenants = [];
    goTo("setup");
    raise("workspace", {
      account: facts.account,
      title: failure.title,
      detail: failure.next,
      retryable: failure.retryable,
    });
    return false;
  }
}

/**
 * The workspace's existing apps, for the release gate only.
 *
 * Nothing in the form reads this: EAI Setup creates from the EAI
 * template every time. The guest-machine test can be pointed at a fixed
 * app with EAI_SETUP_E2E_APP_KEY, and this is what proves that app is
 * really there before the receipt claims it was used.
 */
async function loadApps(tenantId) {
  const tenant = facts.tenants.find((item) => item.id === tenantId);
  if (!tenant) return false;
  try {
    tenant.apps = await invoke("get_company_apps", { tenantId });
    note(`${tenant.apps?.length || 0} existing app${tenant.apps?.length === 1 ? "" : "s"} in ${tenant.displayName}.`);
    return true;
  } catch (error) {
    const failure = helpers.describeAppFailure(error);
    note(`${failure.title}: ${failure.diagnostic}`, "error");
    return false;
  }
}

function chooseTenant(tenantId) {
  facts.selectedTenantId = tenantId;
  machine.clear(state);
  syncStage();
  paint();
}

/**
 * The reveal, recomputed from the answers rather than counted upwards.
 *
 * The name counts as answered when there is one, not when it is a valid
 * kebab-case one. Those are different questions and tying the reveal to
 * validity makes the location question flap: typing "contract-renewals"
 * passes through "contract-", which is not valid, so the question below
 * would close on the hyphen and reopen on the next letter.
 *
 * Whether the name is any good is a separate matter, and it is what
 * decides the primary rather than the reveal — see the Create app line
 * in PAINT.setup.
 */
function syncStage() {
  const workspace = Boolean(facts.selectedTenantId);
  const name = workspace && facts.projectName.length > 0;
  state.stage = machine.stageForAnswers({
    workspace,
    name,
    folder: name && Boolean(facts.projectFolder),
  });
}

/* ===================== 11. CREATING THE APP ====================== */

async function runInit() {
  if (initInProgress) return false;

  if (!helpers.isKebabCase(facts.projectName)) {
    machine.clear(state);
    paint();
    setFieldError("name", "Use lowercase words separated by hyphens, for example customer-portal.");
    el("projName").focus();
    return false;
  }
  if (!facts.projectFolder) {
    setFieldError("folder", `Choose where the app is saved, using ${machine.device(platform()).fileManager}.`);
    return false;
  }
  if (!facts.demo && !facts.selectedTenantId) {
    raise("workspace", { account: facts.account });
    return false;
  }

  initInProgress = true;
  facts.runReached = "workspace";
  facts.runFailedAt = null;
  facts.runValues = {};
  goTo("running");
  await listenForBootstrapProgress();

  let result;
  try {
    result = await invoke("run_bootstrap", {
      step: "init",
      projectName: facts.projectName,
      directory: facts.projectFolder,
      companyTenantId: facts.selectedTenantId,
      appKey: facts.selectedAppKey,
    });
  } catch (error) {
    initInProgress = false;
    return failInit(helpers.cleanText(error));
  } finally {
    initInProgress = false;
  }

  if (result?.output) recordCommandSummaries(result.output);
  e2eAppCreated = Boolean(result?.app_created);
  if (result?.project_directory) {
    facts.projectDirectory = result.project_directory;
    facts.projectPath = result.project_path || result.project_directory;
  }

  if (!result.ok && !result.demo) return failInit(helpers.cleanText(result.message));

  if (!facts.projectDirectory) {
    facts.projectDirectory = `${facts.projectFolder}/${facts.projectName}`;
    facts.projectPath = facts.projectDirectory;
  }
  facts.runReached = "done";
  facts.runValues = {
    template: "ready",
    dependencies: "installed",
  };
  note("The app and its project files are ready.");
  // The screen moves first, so a detection failure raised below lands on
  // the screen that owns it rather than being cleared by the move.
  machine.goTo(state, "done");
  await loadSurfaces();
  paint();
  return true;
}

/**
 * An init failure, put on the screen that owns it.
 *
 * A name that is already taken belongs on the form, in the field, next
 * to the thing that has to change — not on the progress screen, where
 * the only available verb is Retry and retrying the same name does the
 * same thing.
 */
function failInit(message) {
  if (machine.looksLikeTakenName(message)) {
    goTo("setup", { stage: machine.stageForAnswers({ workspace: true, name: true, folder: true }) });
    raise("name", { projectName: facts.projectName });
    return false;
  }
  const failure = helpers.describeInitFailure(message, platform());
  facts.runFailedAt = failure.title === "App dependencies need attention" || /dependenc/i.test(failure.title)
    ? "dependencies"
    : facts.runReached;
  note(`${failure.title}: ${failure.detail}`, "error");
  raise("init", { title: failure.title, detail: failure.detail, next: failure.next });
  return false;
}

/* ==================== 12. HARNESS AND HAND-OFF =================== */

function previewInventory() {
  return {
    contractVersion: "eai.ai-surfaces/v1",
    preferredSurface: null,
    recommendedSurface: "vscode-copilot",
    surfaces: [
      { id: "vscode-copilot", name: "GitHub Copilot in VS Code", provider: "GitHub", installUrl: "https://code.visualstudio.com", launchSupport: "project-and-prompt", installed: false },
      { id: "copilot-cli", name: "GitHub Copilot CLI", provider: "GitHub", installUrl: "https://github.com/features/copilot", launchSupport: "project-and-prompt", installed: false },
      { id: "claude-cli", name: "Claude Code", provider: "Anthropic", installUrl: "https://claude.com/product/claude-code", launchSupport: "project-and-prompt", installed: false },
      { id: "codex-cli", name: "Codex CLI", provider: "OpenAI", installUrl: "https://openai.com/codex", launchSupport: "project-and-prompt", installed: false },
      { id: "grok-cli", name: "Grok Build", provider: "xAI", installUrl: "https://x.ai", launchSupport: "project-and-prompt", installed: false },
    ],
  };
}

async function loadSurfaces() {
  if (!facts.projectDirectory) {
    facts.surfaces = previewInventory();
    facts.selectedSurfaceId = helpers.chooseAiSurface(facts.surfaces);
    return true;
  }
  try {
    const inventory = await invoke("detect_ai_surfaces", { directory: facts.projectDirectory });
    facts.surfaces = inventory?.demo ? previewInventory() : inventory;
    facts.selectedSurfaceId = helpers.chooseAiSurface(facts.surfaces);
    const ready = facts.surfaces.surfaces.filter((surface) => surface.installed).length;
    note(`${ready} AI tool${ready === 1 ? " is" : "s are"} already installed.`);
    machine.clear(state, "detect");
    return true;
  } catch (error) {
    note(`The AI tool check did not finish: ${helpers.cleanText(error)}`, "error");
    facts.surfaces = { surfaces: [] };
    if (state.screen === "done") raise("detect", {});
    else { machine.goTo(state, "done"); machine.raise(state, "detect"); }
    return false;
  }
}

function chooseSurface(surfaceId) {
  facts.selectedSurfaceId = surfaceId;
  facts.waitingForSurfaceId = null;
  stopHarnessPoll();
  machine.clear(state);
  paint();
}

async function harnessNext() {
  const surface = selectedSurface();
  if (!surface) return;

  if (surface.installed) {
    goTo("handoff");
    return;
  }

  try {
    await invoke("install_ai_surface", { surfaceId: surface.id });
  } catch (error) {
    note(`The download page could not be opened: ${helpers.cleanText(error)}`, "error");
    raise("install", { harnessName: surface.name });
    return;
  }
  note(`Opened the official ${surface.provider} page for ${surface.name}.`);
  facts.waitingForSurfaceId = surface.id;
  paint();
  startHarnessPoll();
}

/**
 * While they are on somebody else's website.
 *
 * The waiting box promises this window updates by itself, so it has to.
 * Polling stops the moment the tool lands, the moment they pick a
 * different one, and the moment they leave the screen — a timer that
 * outlives its screen is a repaint of a screen nobody is looking at.
 */
function startHarnessPoll() {
  stopHarnessPoll();
  harnessPollTimer = setInterval(async () => {
    if (state.screen !== "done" || !facts.waitingForSurfaceId) { stopHarnessPoll(); return; }
    if (!facts.projectDirectory) return;
    try {
      const inventory = await invoke("detect_ai_surfaces", { directory: facts.projectDirectory });
      if (inventory?.demo) return;
      facts.surfaces = inventory;
      const landed = inventory.surfaces.find((surface) => surface.id === facts.waitingForSurfaceId && surface.installed);
      if (landed) {
        note(`${landed.name} is installed.`);
        facts.waitingForSurfaceId = null;
        stopHarnessPoll();
        paint();
      }
    } catch {
      // A failed poll is not news. The box already says what to do.
    }
  }, 5000);
}

function stopHarnessPoll() {
  if (harnessPollTimer) clearInterval(harnessPollTimer);
  harnessPollTimer = null;
}

async function openHarness() {
  const surface = selectedSurface();
  if (!surface || !facts.projectDirectory) return;
  el("handoffGo").disabled = true;
  try {
    await invoke("start_ai_surface", { directory: facts.projectDirectory, surfaceId: surface.id });
    note(`${surface.name} opened on the project.`);
    goTo("built");
  } catch (error) {
    note(`${surface.name} could not be opened: ${helpers.cleanText(error)}`, "error");
    raise("launch", { harnessName: surface.name, projectPath: facts.projectPath });
  } finally {
    el("handoffGo").disabled = false;
  }
}

async function openProjectFolder() {
  if (!facts.projectPath) return;
  try {
    await invoke("open_project", { path: facts.projectPath });
    note("Opened the project folder.");
  } catch (error) {
    note(`The project folder could not be opened: ${helpers.cleanText(error)}`, "error");
  }
}

async function runSignup() {
  try {
    const result = await invoke("open_signup");
    note(result?.demo
      ? "Preview only: the Enterprise AI signup page would open in your browser."
      : "The Enterprise AI signup page is open in your browser.");
  } catch (error) {
    note(`The signup page could not be opened: ${helpers.cleanText(error)}`, "error");
  }
}

/* ================== 13. THE RELEASE TEST PATH ====================

   Unchanged in intent from the version before the redesign: a published
   build, driven end to end by a guest account, writing a receipt that
   says which check failed. It walks the same screens a person does. */

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
      receipt: { status: failedCheck ? "failed" : "passed", message, checks, appCreated: e2eAppCreated },
    });
  } catch (error) {
    console.error("Could not write the E2E receipt", error);
  }
}

async function runE2eFlow() {
  try {
    await invoke("verify_e2e_auth");
  } catch (error) {
    await writeE2eReceipt("authentication", String(error));
    return;
  }
  if (!await loadWorkspaces()) {
    await writeE2eReceipt("tenant", "Company workspaces could not be loaded.");
    return;
  }
  const requestedTenant = e2eConfig.companyTenantId;
  if (!requestedTenant || !facts.tenants.some((tenant) => tenant.id === requestedTenant)) {
    await writeE2eReceipt("tenant", "The configured release-test tenant is not available to the signed-in account.");
    return;
  }
  facts.selectedTenantId = requestedTenant;
  if (!await loadApps(requestedTenant)) {
    await writeE2eReceipt("app", "Apps could not be loaded for the release-test workspace.");
    return;
  }
  facts.selectedAppKey = e2eConfig.appKey || null;
  facts.projectName = e2eConfig.projectName || "eai-release-test";
  facts.projectFolder = e2eConfig.directory || "";
  syncStage();
  paint();

  if (!await runInit()) {
    await writeE2eReceipt(e2eAppCreated ? "project" : "app", "The EAI app could not be initialised by the desktop bootstrap path.");
    return;
  }
  const surface = facts.surfaces?.surfaces?.find((item) => item.id === facts.selectedSurfaceId && item.installed)
    || facts.surfaces?.surfaces?.find((item) => item.installed);
  if (!surface) {
    await writeE2eReceipt("aiHandoff", "No installed AI workspace was available for the release-test handoff.");
    return;
  }
  try {
    await invoke("start_ai_surface", { directory: facts.projectDirectory, surfaceId: surface.id });
  } catch (error) {
    await writeE2eReceipt("aiHandoff", `The AI workspace could not be opened: ${String(error)}`);
    return;
  }
  await writeE2eReceipt(null, "The published installer completed its desktop bootstrap path.");
}

/* ======================== 14. THE WIRING ========================= */

el("setupSignin").addEventListener("click", () => runLogin());
el("setupCreate").addEventListener("click", () => {
  if (machine.faultsInForce(state).length) return runReadiness();
  return runSignup();
});

el("welcomeRetry").addEventListener("click", () => runLogin());
el("welcomeCopy").addEventListener("click", async () => {
  if (!facts.signinUrl) return;
  try {
    await navigator.clipboard.writeText(facts.signinUrl);
    el("welcomeCopy").textContent = "Link copied";
    setTimeout(() => { el("welcomeCopy").textContent = "Copy the sign-in link"; }, 2000);
  } catch {
    el("welcomeFine").textContent = facts.signinUrl;
  }
});

el("wsRetry").addEventListener("click", () => {
  machine.clear(state);
  paint();
  loadWorkspaces();
});

/**
 * Typing a name, one keystroke at a time.
 *
 * A full repaint per keystroke would rebuild the workspace rows under
 * the field and take the caret with them, so the screen is only
 * repainted when something about it actually changed: the reveal moved
 * on, or a taken-name error is no longer true.
 */
/* A disabled primary with nothing explaining it is a dead end. The name
   is checked when they leave the field rather than on every keystroke,
   because "contract-" is not wrong, it is half-typed. */
el("projName").addEventListener("blur", () => {
  if (!facts.projectName || helpers.isKebabCase(facts.projectName)) return;
  setFieldError("name", "Use lowercase words separated by hyphens, for example customer-portal.");
});

el("projName").addEventListener("input", (event) => {
  facts.projectName = event.target.value.trim();
  const before = state.stage;
  const hadNameFault = machine.isBroken(state, "name");
  machine.clear(state, "name");
  /* Typing clears the complaint, the way the taken-name error does:
     nothing was attempted, so there is nothing to retry. Cleared here
     rather than by a repaint, because most keystrokes change nothing
     else on the screen and do not earn one. */
  clearFieldError("name");
  syncStage();
  if (state.stage !== before || hadNameFault) paint();
  else el("createApp").disabled = !machine.setupComplete(state) || !helpers.isKebabCase(facts.projectName);
});

async function chooseFolder() {
  const dialog = window.__TAURI__?.dialog;
  if (!dialog?.open) {
    note("Folder selection is available in the signed desktop app.");
    return;
  }
  try {
    const selected = await dialog.open({ directory: true, multiple: false, title: "Choose a location" });
    if (typeof selected === "string" && selected) {
      facts.projectFolder = selected;
      note(`Location chosen: ${selected}`);
      syncStage();
      paint();
    }
  } catch (error) {
    note(`The folder could not be chosen: ${helpers.cleanText(error)}`, "error");
  }
}

el("chooseFolderStart").addEventListener("click", chooseFolder);
el("chooseFolder").addEventListener("click", chooseFolder);
el("setupBack").addEventListener("click", () => {
  facts.signinWaiting = false;
  goTo("signin");
});
el("createApp").addEventListener("click", () => runInit());

el("runBack").addEventListener("click", () => {
  syncStage();
  goTo("setup", { stage: machine.stageForAnswers({ workspace: true, name: true, folder: true }) });
});
el("runRetry").addEventListener("click", () => runInit());

el("harnessBack").addEventListener("click", () => {
  stopHarnessPoll();
  goTo("setup", { stage: machine.stageForAnswers({ workspace: true, name: true, folder: true }) });
});
el("harnessRefresh").addEventListener("click", async () => {
  el("harnessRefresh").disabled = true;
  try {
    await loadSurfaces();
    paint();
  } finally {
    el("harnessRefresh").disabled = false;
  }
});
el("harnessGo").addEventListener("click", () => {
  if (machine.isBroken(state, "detect")) {
    loadSurfaces().then(() => paint());
    return;
  }
  harnessNext();
});

el("handoffBack").addEventListener("click", () => goTo("done"));
el("handoffGo").addEventListener("click", () => openHarness());
el("handoffFolder").addEventListener("click", () => openProjectFolder());

el("builtFolder").addEventListener("click", () => openProjectFolder());
el("builtDone").addEventListener("click", async () => {
  try {
    await window.__TAURI__?.window?.getCurrentWindow()?.close();
  } catch {
    el("builtBody").textContent = "You can close this window.";
  }
});

/* ========================== 15. GO =============================== */

/**
 * Dev builds can open on any state.
 *
 * The prototype's whole review model is that a state worth discussing
 * is a state worth linking to, and losing that on the way into the app
 * would mean the next round of review happens against the prototype
 * rather than the thing that ships. It is off unless the query string
 * asks for it, and it never runs the real bootstrap.
 */
function applyDevAddress() {
  const query = new URLSearchParams(window.location.search);
  if (!query.has("screen")) return false;
  window.__eaiDevAddress = true;
  machine.readAddress(window.location.search, state);

  facts.environment = { platform: state.platform, architecture: "preview", tools: [] };
  facts.demo = true;
  facts.account = "you@example.com";
  /* The form's answers, and only the ones the stage says are in.

     This is the rule the fixture kept breaking: filling a field at a
     stage whose whole point is that it is empty. It made "Name appears"
     look finished with the location question still hidden underneath,
     and "Location — choose" draw its answered shape before anybody had
     chosen. `answersForStage` is the same mapping the form itself uses,
     so the preview cannot disagree with it.

     Every screen after Set up has been through the form, so they get
     the finished answers regardless. */
  const root = state.platform === "windows" ? "C:\\Users\\you\\Projects" : "/Users/you/Projects";
  const separator = state.platform === "windows" ? "\\" : "/";
  const answered = state.screen !== "setup"
    ? { workspace: true, name: true, folder: true }
    /* A workspace failure takes everything below question one off the
       screen, so nothing below it has been answered. Leaving a name in a
       hidden field means it appears out of nowhere the moment the
       failure clears. */
    : machine.isBroken(state, "workspace")
      ? { workspace: false, name: false, folder: false }
      : machine.answersForStage(state);

  facts.projectName = answered.name ? "contract-renewals" : "";
  facts.projectFolder = answered.folder ? root : "";
  // The later screens open the folder, so they always have a path.
  facts.projectPath = `${root}${separator}contract-renewals`;
  facts.projectDirectory = facts.projectPath;

  facts.tenants = [{ id: "preview", displayName: "Northwind Group", slug: "northwind", active: true, apps: [] }];
  facts.selectedTenantId = "preview";
  facts.runReached = query.get("reached") || "template";

  /* ?workspaces=2 reaches the one shape of the form a self-serve tester
     never sees: an account that administers more than one workspace. */
  if (query.get("workspaces") === "2") {
    facts.tenants.push({ id: "preview-2", displayName: "Northwind Retail", slug: "northwind-retail", active: true, apps: [] });
  }

  /* Which AI tools are on this machine, as a list of ids.

     The one control the harness screens exist to answer. `installed=none`
     is the empty machine and `installed=claude-cli,codex-cli` is a
     machine with two, because "is it here" is not a boolean across a list
     of six and a rail that pretends it is cannot reach the state where
     the ready group has more than one row in it. */
  facts.surfaces = previewInventory();
  const installed = query.has("installed")
    ? query.get("installed").split(",").filter((id) => id && id !== "none")
    : query.get("harness") === "installed" ? ["claude-cli"] : [];
  for (const surface of facts.surfaces.surfaces) surface.installed = installed.includes(surface.id);
  const wanted = query.get("pick");
  facts.selectedSurfaceId = facts.surfaces.surfaces.some((surface) => surface.id === wanted)
    ? wanted
    : helpers.chooseAiSurface(facts.surfaces);
  if (query.get("waiting") === "1") facts.waitingForSurfaceId = facts.selectedSurfaceId;

  /* What each failure is about. `step` matters because the prerequisite
     failure says a different true sentence for each tool and for a check
     that never finished at all. */
  /* The init note follows the row that failed, because a screen whose
     failed row says "Dependencies installed" and whose note underneath
     says "The app template would not download" is a screen contradicting
     itself — and a preview that can produce one is a preview that will
     be reviewed as a bug. In the real flow this comes from the CLI. */
  const initFailures = {
    workspace: { title: "The workspace would not connect", detail: "Nothing was created. The folder is untouched.", next: "Check the workspace is still active, then retry this step." },
    folder: { title: "The folder could not be created", detail: "Nothing was written. Choose a location you can write to.", next: "Pick another location, then retry this step." },
    template: { title: "The app template would not download", detail: "The folder was created and is empty. Nothing was left half-written.", next: "An EAI admin can grant access to the asset library, or you can retry once they have." },
    dependencies: { title: "The app's packages would not install", detail: "The project files were created, so the folder is safe to reuse.", next: "Retry this step. If it fails again, open the folder and run npm install." },
  };

  facts.failureContext = {
    prereq: { steps: (query.get("step") || "git").split(",").filter(Boolean) },
    network: { host: "api.au.myenterprise.ai" },
    init: initFailures[facts.runReached] || initFailures.template,
  };

  /* The two moments the sign-in screen has while nothing has failed and
     nobody has pressed anything: the quiet fix-up running, and macOS
     asking for a password. Both are states a reviewer has to see and
     neither is reachable by waiting, because in a preview build there is
     nothing to wait for. */
  const busy = query.get("busy");
  if (busy) {
    facts.prereqBusy = busy;
    facts.prereqDetail = "";
  }
  if (query.get("admin") === "1") {
    facts.prereqBusy = facts.prereqBusy || "git";
    facts.prereqDetail = "Waiting for your approval before Apple's installer can run.";
    pendingAdminPassword = () => {};
  }
  if (query.get("signin") === "waiting") facts.signinWaiting = true;
  if (query.get("signin") === "waiting-long") {
    facts.signinWaiting = true;
    facts.signinEscapeShown = true;
  }
  if (query.get("link") === "1") facts.signinUrl = "https://login.example.com/authorize?code=preview";

  paint();
  return true;
}

async function start() {
  renderDiagnostics();
  if (applyDevAddress()) return;

  paint();
  try {
    const config = await invoke("get_e2e_configuration");
    e2eConfig = config?.enabled ? config : null;
  } catch {
    e2eConfig = null;
  }

  const ready = await runReadiness();
  if (!ready) {
    await writeE2eReceipt("prerequisites", "The required tools could not be installed.");
    return;
  }
  if (e2eConfig) await runE2eFlow();
}

start();
