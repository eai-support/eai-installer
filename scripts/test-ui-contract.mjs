/* ------------------------------------------------------------------
   The markup and the code, checked against each other.

   app.js reaches into ui/index.html by id, and ui/index.html is styled
   by a stylesheet ported from a different repo. Both of those are the
   kind of coupling that fails silently: an element renamed in the
   markup gives a blank screen at runtime, and a class that lost its
   rule gives an unstyled one. Neither shows up in a unit test of the
   state machine, and neither shows up until somebody opens the app.

   The prototype had the same problem and solved it by throwing with the
   missing id in the message. This is the build-time half of that: the
   same drift, caught before anybody installs anything.

   It parses with regular expressions on purpose. The repo has no
   dependencies and this file is not worth acquiring one for — these
   are three specific questions about a file we control, not a general
   HTML parser.
------------------------------------------------------------------- */

import { readFile } from "node:fs/promises";
import vm from "node:vm";

const html = await readFile(new URL("../ui/index.html", import.meta.url), "utf8");
const app = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");
const css = await readFile(new URL("../ui/styles.css", import.meta.url), "utf8");
const video = await readFile(new URL("../ui/video.js", import.meta.url), "utf8");

const machineSource = await readFile(new URL("../ui/state-machine.js", import.meta.url), "utf8");
const sandbox = { console, URLSearchParams };
sandbox.globalThis = sandbox;
vm.runInNewContext(machineSource, sandbox);
const machine = sandbox.EAISetup;

function fail(message) {
  throw new Error(message);
}

/* ============== 1. EVERY id app.js REACHES FOR EXISTS ============ */

const declaredIds = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));

/* Ids the app creates at runtime rather than shipping in the markup —
   the waiting box, which only exists while somebody is away installing
   something. Listed here so the check stays exact rather than lenient. */
const RUNTIME_IDS = new Set(["harnessWait"]);

const referenced = new Set([
  ...[...app.matchAll(/\bel\("([^"]+)"\)/g)].map((match) => match[1]),
  ...[...app.matchAll(/\bmaybe\("([^"]+)"\)/g)].map((match) => match[1]),
]);

for (const id of referenced) {
  if (!declaredIds.has(id) && !RUNTIME_IDS.has(id)) {
    fail(`app.js reaches for #${id}, which ui/index.html does not have`);
  }
}
if (referenced.size < 30) fail(`only ${referenced.size} element references found — the scan is not seeing app.js`);

/* The other direction, for the ids that are the app's own contract:
   an element that nothing drives is either dead markup or a wiring bug,
   and both are worth knowing about. Ids that exist only for CSS or for
   accessibility are exempt by name. */
const PRESENTATION_IDS = new Set(["setupApp", "welcomeBlock", "harnessEai", "setupSteps", "diagnostics"]);
for (const id of declaredIds) {
  if (PRESENTATION_IDS.has(id)) continue;
  if (!app.includes(`"${id}"`) && !video.includes(`"${id}"`)) {
    fail(`ui/index.html declares #${id}, which nothing in app.js drives`);
  }
}

/* ============ 2. EVERY SCREEN IN THE MACHINE HAS MARKUP ========= */

const screensInMarkup = new Set([...html.matchAll(/data-screen="([^"]+)"/g)].map((match) => match[1]));
for (const id of machine.SCREEN_ORDER) {
  if (id === "built") continue;   // an overlay, not a screen in the body
  if (!screensInMarkup.has(id)) fail(`the state machine has a screen "${id}" with no markup`);
}
for (const id of screensInMarkup) {
  if (!machine.SCREEN_ORDER.includes(id)) fail(`ui/index.html has a screen "${id}" the state machine does not know about`);
}
if (!declaredIds.has("builtOverlay")) fail("the built state has no overlay to land in");

/* The setup screen's questions, and the machine's idea of them. */
const stepsInMarkup = [...html.matchAll(/data-step="([^"]+)"/g)].map((match) => match[1]);
const stepsInMachine = machine.setupSteps(
  Object.assign(machine.createState(), { screen: "setup", stage: 4 }),
  { hasApps: true, appAnswered: true },
).map((step) => step.id);
if (stepsInMarkup.join(",") !== stepsInMachine.join(",")) {
  fail(`the form's questions differ between markup (${stepsInMarkup}) and machine (${stepsInMachine})`);
}

/* ============ 3. EVERY CLASS THE APP WRITES IS STYLED =========== */

/* Classes assigned from JavaScript never appear in the markup, so a
   stylesheet that lost one of their rules looks fine in a diff and
   broken in the window. These are the ones that carry the design. */
const DRIVEN_CLASSES = [
  "eai-row", "eai-rows", "pick", "failed", "active", "pending",
  "mk", "done", "busy", "fail", "bang", "sm",
  "lbl", "sub", "val",
  "i3-step", "answered", "i3-num", "i3-foot", "i3-nav",
  "i3-welcome", "i3-tick", "i3-welcome-acts", "i3-welcome-fine", "wide",
  "i4-group", "i4-pick", "i4-row", "i4-alert", "i4-pick-alert", "i4-wait",
  "i4-list", "i4-back", "i4-actions", "i4-eai", "i4-eai-note", "i4-eai-video",
  "mark", "tile", "nm", "state", "on", "ready", "missing",
  "eai-btn", "primary", "ring", "off", "big", "ghost-quiet",
  "eai-field", "eai-input", "eai-combo", "eai-inner", "eai-err", "eai-note",
  "eai-done", "eai-done-card", "tick",
  "eai-diag", "eai-diag-log", "eai-diag-status", "eai-diag-foot",
  "eai-vid", "eai-vid-stage", "eai-vid-win", "eai-vid-play", "eai-vid-caret",
  "eai-vid-ok", "eai-vid-caption", "eai-vid-track", "playing", "replay",
];
for (const name of DRIVEN_CLASSES) {
  if (!new RegExp(`\\.${name.replace(/[-]/g, "\\-")}\\b`).test(css)) {
    fail(`ui/styles.css has no rule for .${name}, which the app assigns at runtime`);
  }
}

/* The prototype's own hard-won fixes, which a re-port would quietly
   lose. Each of these was a visible bug before it was a rule. */
if (!/\.mk\.busy\s*\{[^}]*display:\s*block/s.test(css)) {
  fail("the spinner is a flex item again — its bars will push the running row's label out of the lane");
}
if (!/\.eai-row \.mk \{[^}]*min-width:\s*16px/s.test(css)) {
  fail("the row marker lost its fixed width, so a spinner can resize the column");
}
if (!css.includes("summary::marker") || !css.includes("summary::-webkit-details-marker")) {
  fail("the disclosure triangle is not hidden consistently across desktop webviews");
}
// Comments may name the function; declarations may not use it.
const declarations = css.replace(/\/\*[\s\S]*?\*\//g, "");
if (/oklch\(/.test(declarations)) {
  fail("a colour is written as oklch(), which older WebView2 and WebKitGTK builds drop entirely");
}
if (/fonts\.googleapis|fonts\.gstatic/.test(css) || /fonts\.googleapis|fonts\.gstatic/.test(html)) {
  fail("the app fetches a font over the network before it has proved it has one");
}

/* The window runs under `default-src 'self'`, which refuses inline style
   attributes. They work in a plain browser and silently do nothing in
   the signed build — a difference that only shows up in a screenshot
   somebody takes weeks later. Every colour has to come from the sheet. */
for (const source of [html, app, video]) {
  for (const match of source.matchAll(/style="[^"]+"/g)) {
    fail(`an inline style attribute will be refused by the app's content policy: ${match[0]}`);
  }
}
for (const name of ["vscode", "copilot", "claude", "codex", "grok"]) {
  if (!css.includes(`[data-tile="${name}"]`)) fail(`the ${name} tile has no colour in the stylesheet`);
}

/* ============= 4. THE COPY LIVES IN THE MACHINE ================= */

/* app.js is not allowed to say "this Mac". Anything that names the
   machine has to come from state-machine.js, where the Windows and
   Linux wordings live beside it and the tests can read all three. */
for (const line of app.split("\n")) {
  const code = line.split("//")[0];
  if (!/["'`]/.test(code)) continue;
  if (/\bthis Mac\b|\bthis PC\b|\bFinder\b|\bxcode-select\b|\bwinget\b/.test(code)) {
    fail(`app.js writes platform copy directly: ${line.trim()}`);
  }
}
for (const line of html.split("\n")) {
  if (/<!--/.test(line)) continue;
  if (/\bthis Mac\b|>\s*Finder\b/.test(line)) fail(`ui/index.html hard-codes Mac copy: ${line.trim()}`);
}

console.log(`ui contract checks ok (${referenced.size} element references, ${screensInMarkup.size} screens, ${DRIVEN_CLASSES.length} runtime classes)`);
