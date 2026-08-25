/* ------------------------------------------------------------------
   EAI Setup — the state machine.

   Ported from the tested prototype (prototypes/assets/states.js). That
   page drives the real sign-up app markup; this module drives the real
   installer. Both answer the same three questions:

     Screen        · which of the seven
     State         · working, or the specific thing that broke
     This computer · what is already installed on it

   Everything here is pure. No DOM, no Tauri, no timers — so the whole
   machine can be exercised from Node, which is what scripts/test-state-
   machine.mjs does. ui/app.js owns the DOM and calls in here for every
   decision and every sentence.

   The prototype was written for a Mac. The installer ships on Windows
   and Linux too, and the same screens have to tell the same story
   there, so every sentence that named the Mac is now a function of the
   platform. `device()` is the single place that knows what to call the
   machine in front of somebody; nothing else may say "Mac".
------------------------------------------------------------------- */

(function registerSetupMachine(root) {
  /* ================= 1. WHAT THE MACHINE KNOWS ==================== */

  /**
   * What to call the computer, its file manager, and the places a
   * prerequisite comes from.
   *
   * The prototype says "this Mac" eleven times. Saying it on Windows
   * would be the single most obvious way for this port to look like a
   * port, so it is the one string with no default: an unknown platform
   * gets the neutral "this computer" rather than a Mac sentence.
   */
  const DEVICES = {
    macos: {
      id: "macos",
      device: "this Mac",
      deviceCapitalised: "This Mac",
      shortDevice: "Mac",
      fileManager: "Finder",
      chooserNote: "Where on this Mac the app is saved. We recommend a new folder — the chooser has a New Folder button.",
      restartNote: "Quit EAI Setup and open it again if a newly installed tool is not picked up.",
    },
    windows: {
      id: "windows",
      device: "this PC",
      deviceCapitalised: "This PC",
      shortDevice: "PC",
      fileManager: "File Explorer",
      chooserNote: "Where on this PC the app is saved. We recommend a new folder — the chooser has a New Folder button.",
      restartNote: "Close EAI Setup and open it again if a newly installed tool is not picked up — Windows only refreshes PATH for new programs.",
    },
    linux: {
      id: "linux",
      device: "this computer",
      deviceCapitalised: "This computer",
      shortDevice: "computer",
      fileManager: "your file manager",
      chooserNote: "Where on this computer the app is saved. We recommend a new folder — the chooser has a New Folder button.",
      restartNote: "Close EAI Setup and open it again if a newly installed tool is not picked up.",
    },
  };

  const NEUTRAL_DEVICE = {
    id: "unsupported",
    device: "this computer",
    deviceCapitalised: "This computer",
    shortDevice: "computer",
    fileManager: "your file manager",
    chooserNote: "Where on this computer the app is saved. We recommend a new folder.",
    restartNote: "Close EAI Setup and open it again if a newly installed tool is not picked up.",
  };

  function device(platform) {
    return DEVICES[String(platform || "").toLowerCase()] || NEUTRAL_DEVICE;
  }

  /** The tools the readiness row is allowed to claim it checked. */
  const CHECKED_TOOLS = {
    macos: ["Git", "Node.js", "npm", "EAI CLI"],
    linux: ["Git", "Node.js", "npm", "EAI CLI"],
    windows: ["Git", "Node.js", "npm", "Windows app support", "EAI CLI"],
  };

  function checkedTools(platform) {
    return CHECKED_TOOLS[String(platform || "").toLowerCase()] || CHECKED_TOOLS.macos;
  }

  /** Plain names for the things that can be missing, per bootstrap step. */
  const TOOL_NAMES = {
    git: "Git",
    node: "Node.js and npm",
    "eai-cli": "the EAI CLI",
    "windows-runtime": "Windows app support",
    homebrew: "Homebrew",
  };

  function toolName(step) {
    return TOOL_NAMES[step] || "a required tool";
  }

  /* ================== 2. THE STATE ITSELF ========================

     Six fields, and everything on screen is a function of them.
     Nothing else is remembered between paints, which is what makes a
     state here reachable from a URL as well as by clicking through.

     `faults` is a list, not one id. Things do not break politely one at
     a time: a machine that could not install Git is often the same
     machine behind the proxy that is also blocking the EAI API, and
     the screen that has to hold both is a different screen from either
     on its own. */

  function createState() {
    return {
      screen: "signin",
      faults: [],
      stage: 99,          // clamped on read against the screen's own list
      platform: "macos",
      harnessWaiting: false,
      selectedHarnessId: null,
    };
  }

  /* ================= 3. THE SEVEN SCREENS ========================

     In flow order, which is the only order they happen in. The disk
     image is not here: it is macOS's Finder window shown before the app
     exists, and on Windows and Linux the equivalent moment belongs to
     the platform installer, not to us.

     `note` is what the screen is for, in one line. `faults` is the
     honest list of ways it breaks, each carrying `out` — how somebody
     gets past it. Screens with an empty list are the ones with nothing
     to get wrong, and saying so is worth more than leaving them off. */

  const SCREENS = [
    {
      id: "signin",
      name: "Sign in",
      note: 'The app opens here. One status, with two faces: a tick saying the computer is ready, or a row for each thing in the way. Never both — "ready" is a claim that sign-in can proceed, so nothing that stops it may sit beside it.',
      /* Counted, because more than one prerequisite can fail on the same
         locked-down machine and each of them is a row. The old version
         was the literal string "Two things are in the way", which was
         right only while a fault could contribute exactly one row. */
      comboHead: (count) => `${["", "One thing is", "Two things are", "Three things are", "Four things are", "Five things are"][count] || `${count} things are`} in the way.`,
      combo: "A managed computer that would not let Git install is often the same one that cannot reach the EAI API. Two rows, one list, and one Retry that has to be honest about fixing two different things.",
      faultIds: ["prereq", "network"],
      exclusive: false,
    },
    {
      id: "welcome",
      name: "Signed in",
      note: "A beat, not a screen, on the happy path — nobody acts on it, it confirms what just happened and hands its title to the form behind it. It is also the only screen that reports on something the app does not control, so it is the one that has to say when the browser never came back.",
      faultIds: ["callback"],
      exclusive: true,
    },
    {
      id: "setup",
      name: "Set up",
      note: "The questions on one page, revealed downwards as each is answered, with no Continue between them. Back and Create app hold the bottom rail from the first question.",
      uses: ["stage"],
      stageLabel: "Answered so far",
      stages: [
        ["Workspace only", "workspace"],
        ["Name appears", "name"],
        ["Location — choose", "folder-choose"],
        ["Location — chosen", "folder-chosen"],
      ],
      exclusive: true,
      why: "One at a time: with no workspace, there's no name field to have a name taken in.",
      faultIds: ["workspace", "name"],
    },
    {
      id: "running",
      name: "Creating",
      note: "eai init, said in the words of the flow board — workspace, folder, template, dependencies — rather than tenants and CLIs.",
      faultIds: ["init"],
      exclusive: true,
    },
    {
      id: "done",
      name: "Choose a harness",
      note: "Everyone picks for themselves — there is no workspace standard in self-serve setup. What changes is whether the tool is already on the computer.",
      uses: ["harness"],
      faultIds: ["install", "detect"],
      exclusive: true,
    },
    {
      id: "handoff",
      name: "Hand-off",
      note: 'One instruction, on its own screen, because it has to survive a trip into a window we do not control. Everything that is not "type /eai" was taken off it.',
      uses: ["harness"],
      faultIds: ["launch"],
      exclusive: true,
    },
    {
      id: "built",
      name: "Built",
      note: "The harness opened on the project. The only screen that is not a step — it lands over everything.",
      faultIds: [],
      exclusive: true,
    },
  ];

  const SCREEN_ORDER = SCREENS.map((screen) => screen.id);

  /* =================== 3b. THE FOUR STAGES ========================

     Seven screens is the machine's count, not a person's. Two of the
     seven are not steps anybody takes: the signed-in beat is a moment
     inside signing in, and the hand-off is the last breath of choosing
     a tool. What is left is four things somebody does, and that is what
     the bar across the top counts.

     Borrowed from the sign-up dialog, which does the same thing with
     two: a filled bar for what you have reached, a pale one for what
     you have not. The addition here is a third state, because unlike a
     sign-up form this flow can stop — and a bar that only ever fills is
     a bar that says everything is fine while the screen underneath says
     it is not. */

  const STEPS = [
    { id: "signin", name: "Sign in", screens: ["signin", "welcome"] },
    { id: "setup", name: "Set up", screens: ["setup"] },
    { id: "create", name: "Create", screens: ["running"] },
    { id: "connect", name: "Connect your AI tool", screens: ["done", "handoff", "built"] },
  ];

  /**
   * The bar across the top, as a list of segments.
   *
   * `reached` covers the step somebody is on and everything before it —
   * the sign-up dialog draws no line between done and current and it
   * does not need one, because the screen below already says where you
   * are. `failed` is the step somebody is on when that screen has a
   * failure in force, and it is the only thing on the bar that is not
   * one of two greys.
   */
  function stepper(state) {
    const at = STEPS.findIndex((step) => step.screens.includes(state.screen));
    const broken = faultsInForce(state).length > 0;
    return STEPS.map((step, index) => ({
      id: step.id,
      name: step.name,
      current: index === at,
      status: index === at && broken ? "failed"
        : index <= at ? "reached"
          : "upcoming",
    }));
  }

  /* ================== 4. THE WAYS IT BREAKS ======================

     One entry per fault. `head`/`problem`/`note`/`out` are functions of
     the platform and of whatever the failure carried with it, because
     the same fault says a different true sentence on each platform:
     macOS blocks Git behind Command Line Tools, Windows behind winget
     policy, Linux behind a polkit prompt that a desktop session may
     never show. A single Mac sentence would be wrong twice. */

  const FAULTS = {
    prereq: {
      id: "prereq",
      screen: "signin",
      name: "A prerequisite would not install",
      head: (platform, context = {}) => (context.step === "detect"
        ? `We couldn't check ${device(platform).device}.`
        : "One thing EAI needs could not be installed."),
      problem(platform, context = {}) {
        const step = context.step || "git";
        const name = toolName(step);
        const detail = context.detail ? ` ${context.detail}` : "";
        /* "Nothing else is waiting on it" is true of one failure and a
           lie beside a second — the prototype names this as the problem
           with the combination, and now that one failure can be two rows
           it would be a lie twice on the same screen. The caller says
           whether this row is the only thing in the way. */
        const alone = context.alone !== false ? " Nothing else is waiting on it." : "";
        /* Nothing was being installed — the look itself did not finish.
           Offering the install advice here would send somebody to
           approve a prompt that was never shown. */
        if (step === "detect") {
          return [
            `We couldn't check what's on ${device(platform).device}`,
            `The check did not finish, so we can't say what is missing. Choose Retry.${detail}`,
          ];
        }
        if (platform === "windows") {
          return [
            `Windows would not install ${name}`,
            `winget could not install ${name} on this PC — it may be missing, blocked by policy, or still waiting on an approval prompt. `
              + `Approve it, or install ${name} yourself, then choose Retry.${alone}${detail}`,
          ];
        }
        if (platform === "linux") {
          return [
            `${name} could not be installed`,
            `The package manager needed a graphical authorisation prompt that this session did not get. `
              + `Install ${name} with your distribution's package manager, then choose Retry.${alone}${detail}`,
          ];
        }
        if (step === "git") {
          return [
            "Apple needs your approval to install Git",
            "macOS blocked the Command Line Tools install, so Git is missing. Approve it from the prompt macOS showed, "
              + `or run xcode-select --install in Terminal, then choose Retry.${alone}${detail}`,
          ];
        }
        return [
          `${name} could not be installed`,
          `macOS stopped the install before it finished. Approve any prompt it showed, then choose Retry. `
            + `${alone.trim()}${detail}`,
        ];
      },
      note: (platform) => (platform === "windows"
        ? "The installer could not put a required tool on this PC, so the quiet fix-up could not finish. The row takes the tick's place rather than sitting under it — the app cannot call itself ready and refuse to continue in the same breath."
        : platform === "linux"
          ? "The package manager could not put a required tool on this computer, so the quiet fix-up could not finish. The row takes the tick's place rather than sitting under it."
          : "macOS blocked the Command Line Tools install, so the quiet fix-up could not finish. The row takes the tick's place rather than sitting under it — the app cannot call itself ready and refuse to continue in the same breath."),
      out: (platform) => (platform === "windows"
        ? "Approve the Windows prompt, or install the tool yourself, then Retry."
        : platform === "linux"
          ? "Install the tool with your package manager, then Retry."
          : "Approve the prompt macOS showed, or run xcode-select --install, then Retry."),
    },

    network: {
      id: "network",
      screen: "signin",
      name: "Cannot reach EAI",
      head: (platform) => `Sign-in needs a connection to EAI, and ${device(platform).device} can't reach it.`,
      problem(platform, context = {}) {
        return [
          `Can't reach ${context.host || "the EAI API"}`,
          "Your network blocked the request, or EAI is unreachable from here. Check your connection or VPN, then Retry.",
        ];
      },
      note: (platform) => "Sign-in is the first thing that needs the network, so this is where a VPN or a blocked domain shows up. It replaces the tick for the same reason: "
        + `a ${device(platform).shortDevice} that cannot reach us is not ready to sign in, whatever is installed on it.`,
      out: () => "Fix the connection or the VPN, then Retry.",
    },

    callback: {
      id: "callback",
      screen: "welcome",
      name: "The browser didn't come back",
      head: () => "Sign-in didn't finish",
      body: () => "Your browser opened, but nothing came back. The tab was probably closed before it finished, "
        + "or the link expired. Nothing was saved either way, so trying again is safe.",
      note: () => "The app waits on a tab it cannot see — closed early, expired, or a callback eaten by a proxy. Try again is the primary because the usual cause is a closed tab; the link is for when pressing it again does the same nothing twice.",
      out: () => "Try again, or take the link to the browser yourself.",
    },

    workspace: {
      id: "workspace",
      screen: "setup",
      name: "No workspace for this account",
      head: (platform, context = {}) => (context.account
        ? `Signed in as ${context.account}. One thing is in the way.`
        : "Signed in. One thing is in the way."),
      body: (platform, context = {}) => `${context.account || "This account"} isn't a member of a company workspace yet. `
        + "An EAI admin can add you, then sign in again.",
      note: () => "The account exists but belongs to nobody. Everything below question one stays down, because there is nothing to answer it about.",
      out: () => "Nothing they can do here — an EAI admin adds them, then they sign in again.",
    },

    name: {
      id: "name",
      screen: "setup",
      name: "That name is taken",
      field: "name",
      message: (platform, context = {}) => `A folder called ${context.projectName || "that"} already exists there. `
        + "Pick another name, or choose a different location below.",
      note: () => "A folder of that name already exists where they pointed us. Caught in the field, before anything is written.",
      out: () => "Type a different name and it clears — no retry, because nothing was attempted.",
    },

    init: {
      id: "init",
      screen: "running",
      name: "The app could not be created",
      head: (platform, context = {}) => `Couldn't finish creating ${context.projectName || "your app"}`,
      body: (platform, context = {}) => context.detail
        || "The folder was created and is empty. Nothing was left half-written.",
      noteTitle: (platform, context = {}) => context.title || "The app template would not download",
      noteBody: (platform, context = {}) => context.next
        || "An EAI admin can grant access to the asset library, or you can retry once they have.",
      note: () => "The tenant is connected but the template or its packages did not land. The screen has to say what was left behind: a folder, and nothing half-written.",
      out: () => "Fix what the row names, then Retry this step.",
    },

    install: {
      id: "install",
      screen: "done",
      name: "Setup could not open the download",
      head: (platform, context = {}) => `Couldn't open the ${context.harnessName || "download"} page`,
      body: () => "Your app is finished either way — open its folder and install the tool yourself, or try again.",
      note: () => "The app is finished either way, which is the sentence that has to survive.",
      out: () => "Get it from its makers instead — the button already offers that.",
    },

    detect: {
      id: "detect",
      screen: "done",
      name: "The AI tool check did not finish",
      head: () => "We couldn't check which AI tools are here",
      body: (platform) => `Your app is created and safe. You can close setup and run eai start from the project folder, `
        + `or try the check again on ${device(platform).device}.`,
      note: () => "Detection is the only thing that failed. The app exists, so the screen must not read like the app failed.",
      out: () => "Check again, or close setup and run eai start from the project folder.",
    },

    launch: {
      id: "launch",
      screen: "handoff",
      name: "The tool would not open",
      head: (platform, context = {}) => `${context.harnessName || "The AI tool"} didn't open`,
      body: (platform, context = {}) => `Your app is created and safe at ${context.projectPath || "your chosen folder"}. `
        + "Open it yourself and run eai start, or go back and choose a different tool.",
      note: () => "The hand-off is the only thing that failed, and the app it was handing over still exists.",
      out: () => "Open the project folder and run eai start, or go back and choose another tool.",
    },
  };

  function screenById(id) {
    return SCREENS.find((screen) => screen.id === id) || null;
  }

  function faultById(id) {
    return FAULTS[id] || null;
  }

  /** The faults a screen owns, in the screen's own order. */
  function faultsForScreen(screenId) {
    const screen = screenById(screenId);
    if (!screen) return [];
    return screen.faultIds.map((id) => FAULTS[id]).filter(Boolean);
  }

  /**
   * The faults in force, in the screen's own order.
   *
   * Ordered by the table rather than by the order they arrived, so the
   * same set of failures always draws the same screen. On sign-in that
   * order is chronological — the install-time failure above the one
   * that only happens when you press the button.
   */
  function faultsInForce(state) {
    const screen = screenById(state.screen);
    if (!screen) return [];
    return screen.faultIds.filter((id) => state.faults.includes(id)).map((id) => FAULTS[id]);
  }

  /**
   * How far through a staged screen we are, clamped to what it has.
   *
   * Held as a plain number and clamped on read rather than corrected on
   * write, so moving between screens with different stage counts never
   * needs the two to agree about what "3" means.
   */
  function stageOf(state) {
    const screen = screenById(state.screen);
    if (!screen || !screen.stages) return 0;
    return Math.min(Math.max(1, Number(state.stage) || 1), screen.stages.length);
  }

  /* ================= 5. MOVING BETWEEN SCREENS ===================

     One entry point. Every move clears the faults of the screen being
     left, because a fault belongs to a screen and carrying it forward
     is how a machine starts lying. */

  function goTo(state, screenId, { stage } = {}) {
    const screen = screenById(screenId);
    if (!screen) return state;
    state.screen = screen.id;
    state.faults = [];
    state.stage = screen.stages ? (stage || screen.stages.length) : 99;
    return state;
  }

  function raise(state, faultId, { exclusive } = {}) {
    const fault = FAULTS[faultId];
    if (!fault) return state;
    const screen = screenById(state.screen);
    if (!screen || !screen.faultIds.includes(faultId)) return state;
    const single = exclusive === undefined ? screen.exclusive : exclusive;
    if (single) state.faults = [faultId];
    else if (!state.faults.includes(faultId)) state.faults = [...state.faults, faultId];
    return state;
  }

  function clear(state, faultId) {
    if (faultId === undefined) state.faults = [];
    else state.faults = state.faults.filter((id) => id !== faultId);
    return state;
  }

  function isBroken(state, faultId) {
    return state.faults.includes(faultId);
  }

  /* =============== 6. WHAT EACH SCREEN SAYS ======================

     The sentences, gathered here so the tests can read them without a
     browser and so no sentence about the machine is written twice. */

  /** The tick, when nothing is in the way. */
  function readyRow(platform) {
    const tools = checkedTools(platform);
    return {
      title: `${device(platform).deviceCapitalised} is ready`,
      body: `Checked ${tools.length} things — ${tools.join(", ")} — and installed what was missing.`,
    };
  }

  /** The row while the quiet fix-up is still running. */
  function workingRow(platform, step, detail) {
    const name = toolName(step);
    return {
      title: step === "detect"
        ? `Checking ${device(platform).device}`
        : `Installing ${name}`,
      body: detail || (step === "detect"
        ? `Looking for ${checkedTools(platform).join(", ")}.`
        : `Downloading and installing only what is missing. Nothing else on ${device(platform).device} is touched.`),
    };
  }

  function signinHead(state, context = {}) {
    const faults = faultsInForce(state);
    if (!faults.length) {
      return "Use the account you signed up with. Your browser opens for the password, and it stays there.";
    }
    /* Counted in rows rather than faults. "Two things are in the way"
       above three rows is the screen contradicting itself, and one fault
       can now be two rows. */
    const rows = signinProblems(state, context).length;
    if (rows > 1) return screenById("signin").comboHead(rows);
    return faults[0].head(state.platform, context[faults[0].id] || {});
  }

  function signinButtonLabel(state) {
    return faultsInForce(state).length ? "Retry" : "Sign in with browser";
  }

  /** The rows the sign-in screen shows instead of the tick. */
  /**
   * The rows the sign-in screen shows instead of the tick.
   *
   * A fault does not always mean a row. A machine locked down enough to
   * refuse Git usually refuses Node too, and telling somebody about one
   * of them, then the next after they have fixed it, is the drip-feed
   * this screen exists to avoid — so the prerequisite failure carries a
   * list and contributes a row for each thing on it.
   */
  function signinProblems(state, context = {}) {
    const faults = faultsInForce(state);
    const stepsOf = (fault) => {
      const own = context[fault.id] || {};
      return own.steps?.length ? own.steps : [own.step || "git"];
    };
    // Counted first, because each row's wording depends on whether it is
    // the only one.
    const rows = faults.reduce((total, fault) => total + (fault.id === "prereq" ? stepsOf(fault).length : 1), 0);

    return faults.flatMap((fault) => {
      const own = { ...(context[fault.id] || {}), alone: rows === 1 };
      if (fault.id !== "prereq") return [fault.problem(state.platform, own)];
      return stepsOf(fault).map((step) => fault.problem(state.platform, { ...own, step }));
    });
  }

  /* --- Set up ---------------------------------------------------------

     The reveal, as a set of booleans. `stage` is the prototype's four
     moments across three questions: nothing answered, the name
     revealed, the location revealed, the location answered. */

  /**
   * Which questions are on screen and which are answered.
   *
   * Three, always, exactly as the tested design has them. There was a
   * fourth for a while — "new app, or one you already have" — because
   * the platform can hold apps a project could be connected to. EAI
   * Setup only ever creates from the EAI template, so that question had
   * one real answer and asking it was asking somebody to confirm a
   * decision they were never given.
   *
   * It also took the app name hostage: connecting to an existing app
   * locked the name field, which is wrong even when the question
   * exists. See docs/known-issues.md.
   */
  function setupSteps(state) {
    const upto = stageOf(state);
    return [
      { id: "workspace", shown: upto >= 1, answered: upto >= 1 },
      { id: "name", shown: upto >= 2, answered: upto >= 3 },
      { id: "folder", shown: upto >= 3, answered: upto >= 4 },
    ].map((step, index) => ({ ...step, number: String(index + 1) }));
  }

  function setupComplete(state) {
    if (faultsInForce(state).length) return false;
    return setupSteps(state).every((step) => step.shown && step.answered);
  }

  /**
   * Which questions the stage says have been answered.
   *
   * Anything drawing this screen from a stage rather than from real
   * answers — the preview, a review page — has to be able to ask "at
   * this stage, is there a name yet?" and get the same answer the form
   * would give. Filling a field in at a stage whose whole point is that
   * it is empty is how a screen ends up looking finished with its next
   * question still hidden.
   *
   * The workspace is answered from the first stage, which is the
   * prototype's own model: there is one, and a question with one
   * possible answer is not a question. That makes stage one and stage
   * two the same set of answers seen a moment apart — the name question
   * appearing is the difference — so `stageForAnswers` maps that answer
   * set to two. The real app passes straight through stage one; it is
   * the frame before the reveal, not a state anybody rests in.
   */
  function answersForStage(state) {
    const at = stageOf(state);
    return { workspace: true, name: at >= 3, folder: at >= 4 };
  }

  /**
   * The two shapes of the location question.
   *
   * Before an answer it is one button, at the left, because somebody
   * reads the heading and wants to go and choose. A greyed path sitting
   * there instead reads as a value that is already filled in, and the
   * question looks answered when it is not.
   *
   * After an answer it is the path, with the way to change it on the
   * right. Derived from the stage rather than from whether a folder
   * happens to be set, so the screen is a function of the state and the
   * two can never disagree about which question is being asked.
   */
  function locationShape(state) {
    return answersForStage(state).folder ? "chosen" : "choose";
  }

  /**
   * The line under "Let's get set up".
   *
   * "Signed in as your account" is worse than not saying it: it is the
   * app admitting it does not know something it just did. When the CLI
   * did not report an address, the sentence simply starts later.
   */
  function setupSub(state, context = {}) {
    const who = context.account ? `Signed in as ${context.account}.` : "Signed in.";
    if (isBroken(state, "workspace")) return `${who} One thing is in the way.`;
    return `${who} Your workspace came with you — a few things, and your app exists.`;
  }

  /**
   * Which stage the answers put us at.
   *
   * The screen reveals downwards, so the stage is simply how many
   * answers are in. Held as a derivation rather than a variable because
   * an answer can be taken back — clearing the name field has to close
   * the location question again, and a stage that only counts upwards
   * cannot do that.
   */
  function stageForAnswers({ workspace, name, folder }) {
    if (folder) return 4;
    if (name) return 3;
    if (workspace) return 2;
    return 1;
  }

  /* --- Creating -------------------------------------------------------

     eai init said in the words of the flow board. The rows are fixed;
     what moves is which one is active, and the installer decides that
     from the progress events the CLI streams. */

  const RUN_ROWS = [
    { id: "workspace", label: "Workspace connected" },
    { id: "folder", label: "Folder created" },
    { id: "template", label: "App template downloaded" },
    { id: "dependencies", label: "Dependencies installed" },
  ];

  /**
   * Which of the four rows a line from the CLI belongs to.
   *
   * Two different streams end up here and they are worded differently:
   * the progress events, which are titles like "Installing app
   * dependencies", and the safe build summaries, which are whole
   * sentences like "Installed the required project packages." Both have
   * to land on a row, because a Creating screen that sits on the first
   * row for the whole template download is a screen that looks stuck.
   *
   * Order matters: dependencies is checked first because "Installed the
   * required project packages" also contains words the template row
   * would happily claim.
   */
  function runRowForProgress(title = "", detail = "") {
    const text = `${title} ${detail}`.toLowerCase();
    if (/dependenc|project packages|npm packages|added \d+ package|up to date|npm install/.test(text)) return "dependencies";
    if (/template|cloned from|scaffold|gofer|agents\.md|claude\.md|env\.local|package\.json|configuration|project settings|data model|workspace guidance|delivery guidance|version control/.test(text)) return "template";
    if (/folder|directory/.test(text)) return "folder";
    if (/workspace|tenant/.test(text)) return "workspace";
    return null;
  }

  /**
   * The four rows, with a mark each.
   *
   * `reached` is the last row the CLI has said anything about. Rows
   * before it are done, that one is active, the rest are pending — and
   * a failure turns the active one into the failure rather than adding
   * a fifth row, because the thing that failed is the thing that was
   * running.
   */
  function runRows(state, { reached = "workspace", values = {}, failedAt = null } = {}) {
    const order = RUN_ROWS.map((row) => row.id);
    const failed = failedAt && order.includes(failedAt) ? failedAt : null;
    const stop = failed || (order.includes(reached) ? reached : "workspace");
    const stopIndex = order.indexOf(stop);
    return RUN_ROWS.map((row, index) => {
      let mark = "pending";
      if (index < stopIndex) mark = "done";
      else if (index === stopIndex) mark = failed ? "fail" : "active";
      if (!failed && index === stopIndex && reached === "done") mark = "done";
      return { id: row.id, label: row.label, value: values[row.id] || "", mark };
    });
  }

  /** When everything is finished, all four rows are ticks. */
  function runRowsComplete(values = {}) {
    return RUN_ROWS.map((row) => ({ id: row.id, label: row.label, value: values[row.id] || "", mark: "done" }));
  }

  /* --- Choose a harness ----------------------------------------------

     Two groups, and which group a tool is in is the only thing on this
     screen that changes between a machine with the tool and one
     without. That is the scenario the round exists to test, so it is
     modelled explicitly rather than falling out of a sort. */

  function harnessSubtitle(surfaces, platform) {
    const ready = (surfaces || []).filter((surface) => surface.installed);
    const dev = device(platform);
    if (!ready.length) {
      return `None of these are on ${dev.device} yet. Pick the one you'd like and we'll send you to its makers.`;
    }
    if (ready.length === 1) {
      return `${ready[0].name} is already on ${dev.device}. Pick it, or use something else.`;
    }
    return `${ready.length} of these are already on ${dev.device}. Pick one, or use something else.`;
  }

  /**
   * The list, grouped.
   *
   * Ready first, always, and the group headings say why the two halves
   * are different: one is here, the other has to be fetched from
   * somebody else's website. An empty group is not drawn — a heading
   * over nothing is a heading that has to be apologised for.
   */
  function harnessGroups(surfaces, platform) {
    const list = [...(surfaces || [])];
    const ready = list.filter((surface) => surface.installed);
    const missing = list.filter((surface) => !surface.installed);
    return [
      { id: "ready", label: `Ready on ${device(platform).device}`, note: "", items: ready },
      { id: "missing", label: "Not installed", note: "you get these from their makers", items: missing },
    ].filter((group) => group.items.length);
  }

  /**
   * Where a tool comes from, said as its makers would say it.
   *
   * The CLI's install URLs point at documentation — docs.github.com,
   * learn.chatgpt.com — and "GitHub Copilot CLI comes from
   * docs.github.com" is a sentence about a manual rather than about a
   * product. The documentation subdomain is dropped for the sentence;
   * what is left is still the host we are about to open.
   */
  const DOC_SUBDOMAINS = /^(docs|learn|developer|help|support|www)\./;

  function harnessOrigin(surface) {
    if (!surface) return { site: "", account: "" };
    const url = String(surface.installUrl || surface.install_url || "");
    const host = url.replace(/^https?:\/\//, "").split("/")[0] || "";
    const site = host.replace(DOC_SUBDOMAINS, "");
    return { site, account: surface.provider || site };
  }

  /**
   * The alert inside the chosen option, when the chosen option is not
   * here yet.
   *
   * It says the whole trip up front — their site, their installer,
   * their account — rather than discovering it a step at a time, and it
   * ends by saying the app already exists, because the most common
   * reason people abandon here is thinking they are about to lose it.
   */
  function harnessAlert(surface) {
    if (!surface || surface.installed) return null;
    const origin = harnessOrigin(surface);
    return {
      title: origin.site ? `${surface.name} comes from ${origin.site}` : `${surface.name} comes from its makers`,
      parts: [
        "We'll open their site. Install it and make a ",
        { b: origin.account || surface.provider || "provider" },
        " account there, then come back here — your app is already created either way.",
      ],
    };
  }

  /**
   * The button's verb, which is the whole design of this screen.
   *
   * "Next" when the thing is there, "Get" when the user has to fetch
   * it, and the waiting form while they are away. Never the same word
   * for three different amounts of work.
   */
  function harnessButtonLabel(surface, { waiting = false } = {}) {
    if (!surface) return "Choose an AI tool";
    if (waiting) return `Waiting for ${surface.name}…`;
    return surface.installed ? "Next" : `Get ${surface.name}`;
  }

  /** The box that appears while they are on somebody else's website. */
  function harnessWaiting(surface, platform) {
    if (!surface) return null;
    const origin = harnessOrigin(surface);
    return {
      title: `Waiting for ${surface.name}`,
      body: `${origin.site || "Their site"} is open in your browser. Download ${surface.name}, install it and sign in — `
        + "this will update by itself when it lands. Your app is already created, so nothing is lost if you "
        + "close this window.",
    };
  }

  /* --- Hand-off -------------------------------------------------------

     One instruction, and every line that is not that instruction is a
     line competing with it. */

  function handoffCopy(surface, { projectName } = {}) {
    const name = surface?.name || "your AI tool";
    return {
      title: "One last thing",
      sub: `${name} is ready. Here's what to do the moment it opens.`,
      instruction: "When it opens, type /eai and press enter",
      body: `${name} opens on your app with an empty prompt — it doesn't know about EAI until you say so. `
        + "Typing /eai is what starts it.",
      button: `Open ${projectName ? `${projectName} in ` : "in "}${name}`,
    };
  }

  function builtCopy({ projectName, workspaceName, harnessName } = {}) {
    return {
      title: "That's it — you're building",
      body: `${projectName || "Your app"} is connected to ${workspaceName || "your workspace"} and EAI is running inside `
        + `${harnessName || "your AI tool"}. Tell it what you want to build.`,
    };
  }

  /* ============ 7. TURNING FAILURES INTO FAULTS ==================

     The installer's failures arrive as strings from the CLI and from
     the platform. This is the one place that decides which of the
     modelled faults a given string is, so the screens never have to
     read an error message. */

  const NETWORK_PATTERNS = /ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ERR_NETWORK|network is unreachable|could not resolve host|proxy|certificate|tls|ssl|offline|getaddrinfo/i;

  function looksLikeNetworkFailure(message) {
    return NETWORK_PATTERNS.test(String(message || ""));
  }

  /**
   * Which sign-in fault a bootstrap failure is.
   *
   * A prerequisite step that failed because the network is down is a
   * network fault, not a prerequisite one: telling somebody to approve
   * an Apple prompt when the real problem is a proxy sends them to the
   * wrong place, and they will do what the screen says.
   */
  function classifyBootstrapFailure(step, message) {
    if (looksLikeNetworkFailure(message)) return "network";
    if (step === "login") return "network";
    return "prereq";
  }

  /** Whether an init failure is a taken name, which is caught in the field. */
  function looksLikeTakenName(message) {
    return /already exists|EEXIST|not empty/i.test(String(message || ""));
  }

  /* ============ 8. STATES HAVE ADDRESSES (QA ONLY) ===============

     A state worth discussing is a state worth linking to. The installer
     is not a website, but its dev build opens with a query string, and
     "the one where nothing is installed and Git failed" being a link
     rather than four instructions is what made the prototype
     reviewable. Parsing is here; whether to honour it is app.js's
     decision, and it only does so in a dev build. */

  function readAddress(search, state = createState()) {
    const query = new URLSearchParams(String(search || "").replace(/^\?/, ""));
    const screen = screenById(query.get("screen"));
    if (screen) state.screen = screen.id;

    const asked = (query.get("fault") || "").split(",").filter(Boolean);
    const known = screenById(state.screen).faultIds.filter((id) => asked.includes(id));
    state.faults = screenById(state.screen).exclusive ? known.slice(0, 1) : known;

    const wantStage = Number(query.get("stage"));
    state.stage = wantStage >= 1 ? wantStage : 99;

    const platform = query.get("platform");
    if (DEVICES[platform]) state.platform = platform;

    return state;
  }

  function writeAddress(state) {
    const query = new URLSearchParams({ screen: state.screen });
    if (state.faults.length) query.set("fault", faultsInForce(state).map((fault) => fault.id).join(","));
    const screen = screenById(state.screen);
    if (screen?.stages && stageOf(state) !== screen.stages.length) query.set("stage", String(stageOf(state)));
    if (state.platform !== "macos") query.set("platform", state.platform);
    return `?${query}`;
  }

  /* ============ 9. THE CAPTION, FOR REVIEW BUILDS ================ */

  function caption(state, context = {}) {
    const screen = screenById(state.screen);
    const faults = faultsInForce(state);
    if (!faults.length) return { name: screen.name, note: screen.note };
    if (faults.length === 1) {
      return {
        name: `${screen.name} — ${faults[0].name}`,
        note: `${faults[0].note(state.platform, context)} Way out: ${faults[0].out(state.platform, context)}`,
      };
    }
    return {
      name: `${screen.name} — ${faults.map((fault) => fault.name).join(" + ")}`,
      note: screen.combo || `${faults.length} failures at once. ${faults.map((fault) => fault.note(state.platform, context)).join(" ")}`,
    };
  }

  root.EAISetup = {
    SCREENS,
    SCREEN_ORDER,
    STEPS,
    FAULTS,
    RUN_ROWS,
    DEVICES,
    caption,
    checkedTools,
    classifyBootstrapFailure,
    clear,
    createState,
    device,
    faultById,
    faultsForScreen,
    faultsInForce,
    goTo,
    handoffCopy,
    builtCopy,
    harnessAlert,
    harnessButtonLabel,
    harnessGroups,
    harnessOrigin,
    harnessSubtitle,
    harnessWaiting,
    isBroken,
    looksLikeNetworkFailure,
    looksLikeTakenName,
    raise,
    readAddress,
    readyRow,
    runRowForProgress,
    runRows,
    runRowsComplete,
    screenById,
    setupComplete,
    answersForStage,
    locationShape,
    setupSteps,
    setupSub,
    signinButtonLabel,
    signinHead,
    signinProblems,
    stageForAnswers,
    stageOf,
    stepper,
    toolName,
    workingRow,
    writeAddress,
  };
})(typeof window === "undefined" ? globalThis : window);
