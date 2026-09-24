import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = (await readFile(new URL("../ui/app.js", import.meta.url), "utf8"))
  .replace(/\r\n/g, "\n");
const readinessStart = source.indexOf("async function runReadiness() {");
const readinessEnd = source.indexOf("\n}\n\n/**\n * One prerequisite.", readinessStart) + 2;
assert(
  readinessStart >= 0 && readinessEnd > readinessStart,
  "The actual installer readiness flow must remain available to the test.",
);
const readiness = `${source.slice(readinessStart, readinessEnd)}\nrunReadiness()`;

test("managed CLI recovery completes readiness and offers the sign-in step", async () => {
  const trace = [];
  let detectCalls = 0;
  let missingCalls = 0;
  const sandbox = {
    readinessInProgress: false,
    facts: {
      demo: false,
      prereqBusy: "eai-cli",
      prereqDetail: "",
      prereqPlan: [],
      prereqCompleted: 0,
      failureContext: {},
      environment: { tools: [] },
    },
    state: { screen: "signin" },
    machine: { clear: () => {} },
    listenForBootstrapProgress: async () => {},
    detect: async () => { detectCalls += 1; return true; },
    checkConnectivity: async () => ({ ok: true }),
    missingSteps: () => { missingCalls += 1; return ["eai-cli"]; },
    runBootstrapStep: async (step) => { trace.push(step); return true; },
    helpers: { prerequisitesReady: () => true },
    raise: (id) => { throw new Error(`unexpected installer failure: ${id}`); },
    note: (message) => trace.push(message),
    paint: () => trace.push("ready"),
  };
  assert.equal(await vm.runInNewContext(readiness, sandbox), true);
  assert.deepEqual(trace, ["ready", "eai-cli", "Everything EAI needs is ready.", "ready"]);
  assert.equal(detectCalls, 2);
  assert.equal(missingCalls, 1);

  let startHandler;
  const setupStartStart = source.indexOf('el("setupStart").addEventListener("click", async () => {');
  const setupCreateStart = source.indexOf('\nel("setupCreate")', setupStartStart);
  assert(
    setupStartStart >= 0 && setupCreateStart > setupStartStart,
    "The actual sign-in continuation action must remain available to the test.",
  );
  const continuation = source.slice(setupStartStart, setupCreateStart);
  const transitionSandbox = {
    facts: { preparationStarted: true, prereqBusy: null },
    el: () => ({ addEventListener: (_event, handler) => { startHandler = handler; } }),
    goTo: (screen) => trace.push(screen),
  };
  vm.runInNewContext(continuation, transitionSandbox);
  await startHandler();
  assert.equal(trace.at(-1), "signin");
});

test("readiness batches three prerequisite installs into one final environment readback", async () => {
  const steps = [];
  let detectCalls = 0;
  let missingCalls = 0;
  const sandbox = {
    readinessInProgress: false,
    facts: { demo: false, prereqBusy: null, prereqDetail: "", prereqPlan: [], prereqCompleted: 0, failureContext: {}, environment: { tools: [] } },
    state: { screen: "signin" },
    machine: { clear: () => {} },
    listenForBootstrapProgress: async () => {},
    detect: async () => { detectCalls += 1; return true; },
    checkConnectivity: async () => ({ ok: true }),
    missingSteps: () => { missingCalls += 1; return ["git", "node", "eai-cli"]; },
    runBootstrapStep: async (step) => { steps.push(step); return true; },
    helpers: { prerequisitesReady: () => true },
    raise: (id) => { throw new Error(`unexpected installer failure: ${id}`); },
    note: () => {},
    paint: () => {},
  };
  assert.equal(await vm.runInNewContext(readiness, sandbox), true);
  assert.deepEqual(steps, ["git", "node", "eai-cli"]);
  assert.equal(detectCalls, 2);
  assert.equal(missingCalls, 1);
  assert.equal(sandbox.facts.prereqCompleted, 3);
  assert.equal(sandbox.facts.prereqBusy, null);
});

test("readiness does not claim success when the final environment readback fails", async () => {
  let detectCalls = 0;
  const failures = [];
  const sandbox = {
    readinessInProgress: false,
    facts: { demo: false, prereqBusy: null, prereqDetail: "", prereqPlan: [], prereqCompleted: 0, failureContext: {}, environment: { tools: [] } },
    state: { screen: "signin" },
    machine: { clear: () => {} },
    listenForBootstrapProgress: async () => {},
    detect: async () => ++detectCalls === 1,
    checkConnectivity: async () => ({ ok: true }),
    missingSteps: () => ["eai-cli"],
    runBootstrapStep: async () => true,
    helpers: { prerequisitesReady: () => true },
    raise: (id, context) => failures.push({ id, context }),
    note: () => {},
    paint: () => {},
  };
  assert.equal(await vm.runInNewContext(readiness, sandbox), false);
  assert.equal(detectCalls, 2);
  assert.deepEqual(failures.map(({ id }) => id), ["prereq"]);
  assert.equal(failures[0].context.steps[0], "detect");
});
