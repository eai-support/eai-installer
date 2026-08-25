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

import { readdir, readFile } from "node:fs/promises";
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

/* Every field a person types into has a name a screen reader can read.
   A <label> that wraps an input but contains no text is a label in the
   markup and nothing at all out loud. */
for (const match of html.matchAll(/<input\b[^>]*>/g)) {
  const tag = match[0];
  if (/type="(hidden|button|submit)"/.test(tag)) continue;
  const id = /\bid="([^"]+)"/.exec(tag)?.[1];
  const labelled = /aria-label="/.test(tag)
    || (id && new RegExp(`<label[^>]*for="${id}"[^>]*>\\s*[^<\\s]`).test(html))
    || /placeholder="/.test(tag);
  if (!labelled) fail(`the field ${id ? `#${id}` : tag} has no name a screen reader can read`);
}

/* The app has a width, and only one place may decide it.

   The design states it where it shows the app on its own — the
   prototype's statemachine page frames it at `min(100%, 900px)`. The
   window opens at that width and the content is capped at it, so a
   maximised window gives more room around the form rather than a wider
   form. Two files carry the number; they have to agree. */
const windowConfig = JSON.parse(await readFile(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"))
  .app?.windows?.[0];
const declaredCap = /--app-width:\s*(\d+)px/.exec(css)?.[1];
if (!declaredCap) fail("ui/styles.css does not declare --app-width, so the content has no width to be capped at");
if (Number(declaredCap) !== windowConfig?.width) {
  fail(`the content is capped at ${declaredCap}px but the window opens at ${windowConfig?.width}px — one of them is wrong`);
}
if (!/\.eai-body \{[^}]*max-width:\s*var\(--app-width\)/s.test(css)) {
  fail("the content column is not capped, so a maximised window stretches the form across the monitor");
}
if (!/\.eai-body \{[^}]*margin-inline:\s*auto/s.test(css)) {
  fail("the content column is capped but not centred, so a wide window leaves it against one edge");
}

/* ========= 4. THE PLAYGROUND, AND WHERE IT MAY NOT LIVE ========= */

/* The review playground drives the real app in a frame. Two things make
   that safe, and both are checked here because both are one careless
   move away from being untrue. */

const rail = await readFile(new URL("../prototype/rail.js", import.meta.url), "utf8");

// One: it is outside ui/, which is the only folder Tauri bundles.
const tauriConfig = JSON.parse(await readFile(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"));
if (tauriConfig.build?.frontendDist !== "../ui") {
  fail(`the bundle no longer ships ui/ alone (${tauriConfig.build?.frontendDist}) — check the playground cannot reach a signed build`);
}
for (const name of await readdir(new URL("../ui/", import.meta.url))) {
  if (/prototype|statemachine|playground|rail\./i.test(name)) {
    fail(`ui/${name} would be bundled into the signed app — the playground belongs outside ui/`);
  }
}

/* The rail is the prototype's, not one invented here. These are the
   class names and the shapes assets/states.css defines; a rewrite that
   drifts back to bordered option boxes or a coloured field is a rail
   that reviews the app in somebody else's design language. */
const railCss = await readFile(new URL("../prototype/rail.css", import.meta.url), "utf8");
for (const name of ["st-rail", "st-title", "st-stage", "st-cap", "st-frame",
  "rl-group", "rl-label", "rl-note", "rl-select", "rl-opt", "rl-tick", "rl-pill", "rl-chip"]) {
  if (!railCss.includes(`.${name}`)) fail(`the playground rail has lost the prototype's .${name}`);
}
if (!/\.rl-opt \{[^}]*border:\s*none/s.test(railCss)) {
  fail("the rail's options have grown a box again — in the prototype the chosen one is simply the one you can read");
}
if (!railCss.includes(".rl-tick .box.radio::after")) {
  fail("the rail's radios tick instead of filling — a tick in a radio is a checkbox wearing the wrong shape");
}
if (!/grid-template-columns:\s*296px/.test(railCss)) fail("the rail is no longer the prototype's width");

/* Anything shipped hidden and given a display by a class needs to say
   so, because an author rule beats the browser's own [hidden]. The
   failure panel spent a while as an empty bordered box under the app,
   scrolling the page for no reason. */
for (const match of railCss.matchAll(/\.([a-z-]+)\s*\{[^}]*display:\s*(flex|grid|block)[^}]*\}/g)) {
  const name = match[1];
  if (!new RegExp(`\\.${name}\\[hidden\\]`).test(railCss)) continue;
  if (!new RegExp(`\\.${name}\\[hidden\\]\\s*\\{[^}]*display:\\s*none`).test(railCss)) {
    fail(`.${name}[hidden] does not actually hide`);
  }
}
if (!/\.st-dead\[hidden\]\s*\{[^}]*display:\s*none/.test(railCss)) {
  fail("the failure panel is shipped hidden but its class gives it a display — it will sit under the app as an empty box");
}

/* Grey is the surface colour and nothing else. A control that fills
   itself grey is a control competing with the app beside it, and the
   whole point of the page is that it does not. */
/* The select is the exception and is meant to be filled: it is the one
   control that hides its options, and the fill is what says so. */
for (const rule of ["rl-pill", "rl-chip", "rl-opt", "rl-tick"]) {
  const block = new RegExp(`\\.${rule}[^{]*\\{([^}]*)\\}`, "g");
  for (const match of railCss.matchAll(block)) {
    const grey = /background:\s*(#f4f4f5|#fafafa|#f5f5f5)/.exec(match[1]);
    if (grey) fail(`.${rule} fills itself ${grey[1]} — grey is the page's surface, not a control's`);
  }
}

/* One label, two or three words, and nothing under it explaining what
   the group is for. A sentence per group is three or four lines of grey
   text down a 296px rail saying what the labels already say, and it
   breaks the rhythm: the groups that have one sit further apart than
   the groups that do not. */
const railJs = await readFile(new URL("../prototype/rail.js", import.meta.url), "utf8");
for (const match of railJs.matchAll(/\bgroup\(([^)]*)\)/g)) {
  const args = match[1];
  if (args.includes(",") && !args.startsWith("broken ?")) {
    fail(`a rail group carries a description: group(${args})`);
  }
  for (const label of args.matchAll(/"([^"]+)"/g)) {
    const words = label[1].trim().split(/\s+/).length;
    if (words > 3) fail(`the rail label "${label[1]}" is ${words} words — a group label is three at most`);
  }
}
if (/function group\(label,\s*note\)/.test(railJs)) {
  fail("group() takes a description again — the label is the whole of it");
}

/* Two: the rail can express every state the app can be put into. A
   parameter the app reads and the rail never writes is a state nobody
   can review; a parameter the rail writes and the app ignores is a
   control that does nothing. */
/* Two readers, because the address is read in two places: the machine
   takes the four that are the state itself, and app.js takes the
   fixtures. Missing the first set would let the rail lose the screen
   selector and still pass. */
const devAddress = app.slice(app.indexOf("function applyDevAddress"), app.indexOf("async function start()"));
const readAddress = machineSource.slice(machineSource.indexOf("function readAddress"), machineSource.indexOf("function writeAddress"));
const readByApp = new Set([
  ...[...devAddress.matchAll(/query\.(?:get|has)\("([^"]+)"\)/g)].map((match) => match[1]),
  ...[...readAddress.matchAll(/query\.get\("([^"]+)"\)/g)].map((match) => match[1]),
]);
const writtenByRail = new Set([
  ...[...rail.matchAll(/query\.set\("([^"]+)"/g)].map((match) => match[1]),
  ...[...rail.matchAll(/URLSearchParams\(\{\s*([a-z]+):/g)].map((match) => match[1]),
]);
// `harness` is the old spelling of `installed`, kept so links written
// before the rail existed still open.
const RETIRED = new Set(["harness"]);
for (const name of readByApp) {
  if (RETIRED.has(name)) continue;
  if (!writtenByRail.has(name)) fail(`the app reads ?${name}, which the playground rail cannot set — that state is unreviewable`);
}
for (const name of writtenByRail) {
  if (!readByApp.has(name)) fail(`the playground rail sets ?${name}, which the app ignores — that control does nothing`);
}

/* ============= 5. THE COPY LIVES IN THE MACHINE ================= */

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

console.log(`ui contract checks ok (${referenced.size} element references, ${screensInMarkup.size} screens, ${DRIVEN_CLASSES.length} runtime classes, ${readByApp.size} reviewable states)`);
