/* Prototype-tier scenario fixtures.

   Each entry maps a scenario-matrix id to the query string ui/index.html
   already understands, plus checks a cloud agent or Playwright job can
   run without the rail. */

/** @typedef {"present" | "absent" | "text" | "count"} CheckKind */

/**
 * @typedef {Object} ScenarioCheck
 * @property {CheckKind} kind
 * @property {string} selector
 * @property {string} [includes]
 * @property {number} [min]
 * @property {number} [max]
 */

/**
 * @typedef {Object} PrototypeFixture
 * @property {"prototype"} tier
 * @property {Record<string, string | number>} params
 * @property {ScenarioCheck[]} checks
 * @property {{ summary: string, viewport: [number, number], notes?: string }} agent
 */

/** @type {Record<string, PrototypeFixture>} */
export const PROTOTYPE_FIXTURES = {
  "STATE-01-signin": {
    tier: "prototype",
    params: { screen: "signin" },
    checks: [
      { kind: "present", selector: "#setupSignin" },
      { kind: "present", selector: ".setup-split-art" },
    ],
    agent: {
      summary: "Sign-in screen with two-column layout and shader panel",
      viewport: [1100, 720],
    },
  },
  "STATE-01-setup": {
    tier: "prototype",
    params: { screen: "setup", stage: "0" },
    checks: [
      { kind: "present", selector: '[data-step="workspace"]' },
      { kind: "absent", selector: '[data-step="folder"]:not([hidden])' },
    ],
    agent: {
      summary: "Set up form reveals workspace first with later questions hidden",
      viewport: [1100, 720],
    },
  },
  "STATE-11": {
    tier: "prototype",
    params: { screen: "setup", stage: "2" },
    checks: [
      { kind: "present", selector: "#chooseFolderStart" },
      { kind: "absent", selector: "#locCombo:not([hidden])" },
    ],
    agent: {
      summary: "Location not chosen yet — only Choose location button",
      viewport: [1100, 720],
    },
  },
  "STATE-12": {
    tier: "prototype",
    params: { screen: "setup", stage: "3" },
    checks: [
      { kind: "present", selector: "#locCombo" },
      { kind: "present", selector: "#chooseFolder" },
      { kind: "text", selector: "#chooseFolder", includes: "Change location" },
    ],
    agent: {
      summary: "Chosen location shows full-width path with Change location underneath",
      viewport: [1100, 720],
    },
  },
  "APP-06": {
    tier: "prototype",
    params: { screen: "setup", stage: "0", workspaces: "10" },
    checks: [
      { kind: "present", selector: "#wsPick" },
      { kind: "present", selector: ".eai-pick-menu" },
    ],
    agent: {
      summary: "Ten workspaces — rich dropdown instead of a static row",
      viewport: [1100, 720],
    },
  },
  "STATE-09": {
    tier: "prototype",
    params: { screen: "running", fault: "init", reached: "template" },
    checks: [
      { kind: "present", selector: "#runRows" },
      { kind: "text", selector: "#runRetry", includes: "Try again" },
    ],
    agent: {
      summary: "Creating screen failed row with retry — no fifth phantom row",
      viewport: [1100, 720],
    },
  },
  "HARNESS-01": {
    tier: "prototype",
    params: { screen: "done", installed: "claude-cli" },
    checks: [
      { kind: "text", selector: ".i4-group b", includes: "Ready on" },
      { kind: "text", selector: "#harnessGo", includes: "Next" },
    ],
    agent: {
      summary: "Installed harness preselected with Next and ready group heading",
      viewport: [1100, 720],
    },
  },
  "HARNESS-02": {
    tier: "prototype",
    params: { screen: "done", installed: "none" },
    checks: [
      { kind: "text", selector: ".i4-group b", includes: "Not installed" },
      { kind: "absent", selector: ".state" },
    ],
    agent: {
      summary: "Nothing installed — group heading only, no per-row state column",
      viewport: [1100, 720],
    },
  },
  "HARNESS-07": {
    tier: "prototype",
    params: { screen: "done", installed: "none", pick: "codex-cli" },
    checks: [
      { kind: "present", selector: ".i4-row.on" },
      { kind: "present", selector: ".i4-round-trip" },
      { kind: "text", selector: ".i4-round-trip", includes: "come back here" },
    ],
    agent: {
      summary: "Chosen harness option shows round-trip alert with tool name",
      viewport: [1100, 720],
    },
  },
  "HARNESS-03": {
    tier: "prototype",
    params: { screen: "done", installed: "none", waiting: "1" },
    checks: [
      { kind: "present", selector: "#harnessWait" },
      { kind: "text", selector: "#harnessGo", includes: "Waiting for" },
    ],
    agent: {
      summary: "Away installing — waiting box visible, button disabled",
      viewport: [1100, 720],
    },
  },
  "STATE-22-handoff": {
    tier: "prototype",
    params: { screen: "handoff" },
    checks: [
      { kind: "present", selector: "#harnessEai" },
      { kind: "present", selector: "#harnessVideo" },
      { kind: "absent", selector: ".eai-vid-ft" },
    ],
    agent: {
      summary: "Hand-off — instruction and video in one card, no Watch what happens next footer",
      viewport: [1100, 720],
    },
  },
  "STATE-10": {
    tier: "prototype",
    params: { screen: "built" },
    checks: [
      { kind: "present", selector: "#builtOverlay" },
      { kind: "present", selector: "#builtClose" },
      { kind: "present", selector: "#builtDone" },
    ],
    agent: {
      summary: "Built overlay with close control and Done",
      viewport: [1100, 720],
    },
  },
  "PLATFORM-01": {
    tier: "prototype",
    params: { screen: "signin", platform: "windows", fault: "prereq", step: "git" },
    checks: [
      { kind: "text", selector: "body", includes: "winget" },
      { kind: "absent", selector: "body", includes: "xcode-select" },
    ],
    agent: {
      summary: "Windows prerequisite copy names winget, not Mac tooling",
      viewport: [1100, 720],
    },
  },
  "PLATFORM-02": {
    tier: "prototype",
    params: { screen: "signin", platform: "linux", fault: "prereq", step: "git" },
    checks: [
      { kind: "text", selector: "body", includes: "package manager" },
    ],
    agent: {
      summary: "Linux prerequisite copy names the distribution package manager",
      viewport: [1100, 720],
    },
  },
};

/** Matrix ids covered only by unit or guest checks — listed for catalog completeness. */
export const STATIC_TIERS = {
  unit: [
    "WELCOME-01", "WELCOME-02", "PRE-01", "PRE-02", "PRE-03", "PRE-04", "PRE-05", "PRE-06", "PRE-07",
    "STATE-02", "STATE-03", "STATE-04", "STATE-17", "STATE-18", "STATE-19", "STATE-20", "STATE-21",
    "HARNESS-08", "HARNESS-09", "PLATFORM-03", "PLATFORM-04",
  ],
  guest: [
    "AUTH-01", "AUTH-02", "AUTH-03", "AUTH-04", "AUTH-05",
    "APP-01", "APP-02", "APP-03", "APP-04", "APP-05",
    "LOCATION-01", "LOCATION-02", "LOCATION-03", "LOCATION-04", "LOCATION-05",
    "INIT-01", "INIT-02", "INIT-03", "INIT-04", "INIT-05", "INIT-06", "INIT-07", "INIT-08", "INIT-09", "INIT-10",
    "COMPLETE-01", "COMPLETE-02", "AI-01", "AI-02", "AI-03", "AI-04", "RELEASE-01",
    "HARNESS-04", "HARNESS-05", "HARNESS-06",
  ],
};
