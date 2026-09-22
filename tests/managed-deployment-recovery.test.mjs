import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");
const start = source.indexOf("async function runAction(action) {");
const end = source.indexOf('\nfor (const button of document.querySelectorAll("[data-next]"))', start);
assert(start >= 0 && end > start, "The actual installer action handler must remain available to the test.");

for (const ready of [false, true]) {
  for (const automated of [false, true]) {
    test(`prerequisite retry preserves the next step: ready=${ready}, automated=${automated}`, async () => {
      const transitions = [];
      let installs = 0;
      let automatedContinuations = 0;
      const sandbox = {
        installPrerequisites: async () => { installs += 1; return ready; },
        setStep: (step) => transitions.push(step),
        e2eConfig: automated ? { enabled: true } : null,
        runE2eFlow: async () => { automatedContinuations += 1; },
      };
      vm.runInNewContext(source.slice(start, end), sandbox);
      assert.equal(await sandbox.runAction("install-all"), ready);
      assert.equal(installs, 1);
      assert.deepEqual(transitions, ready ? [3] : []);
      assert.equal(automatedContinuations, ready && automated ? 1 : 0);
    });
  }
}
