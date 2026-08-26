/* Validate scenario fixtures and catalog generation. */

import { readFile } from "node:fs/promises";
import { access } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { PROTOTYPE_FIXTURES, STATIC_TIERS } from "./scenario-fixtures.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const matrix = await readFile(join(root, "docs/scenario-matrix.md"), "utf8");
const matrixIds = new Set([...matrix.matchAll(/\|\s*([A-Z]+-\d+)\s*\|/g)].map((match) => match[1]));

const ALIASES = {
  "STATE-01-signin": "STATE-01",
  "STATE-01-setup": "STATE-01",
  "STATE-22-handoff": "STATE-22",
};

for (const [fixtureId, fixture] of Object.entries(PROTOTYPE_FIXTURES)) {
  if (fixture.tier !== "prototype") throw new Error(`${fixtureId} must be prototype tier`);
  if (!fixture.params?.screen) throw new Error(`${fixtureId} has no screen param`);
  if (!Array.isArray(fixture.checks) || !fixture.checks.length) {
    throw new Error(`${fixtureId} has no checks for agents to run`);
  }
  for (const check of fixture.checks) {
    if (!check.selector) throw new Error(`${fixtureId} check missing selector`);
    if (!["present", "absent", "text", "count"].includes(check.kind)) {
      throw new Error(`${fixtureId} check has unknown kind ${check.kind}`);
    }
    if (check.kind === "text" && !check.includes) {
      throw new Error(`${fixtureId} text check missing includes`);
    }
  }
  const matrixId = ALIASES[fixtureId] || fixtureId;
  if (!matrixIds.has(matrixId)) {
    throw new Error(`${fixtureId} maps to unknown matrix id ${matrixId}`);
  }
}

for (const id of [...STATIC_TIERS.unit, ...STATIC_TIERS.guest]) {
  if (!matrixIds.has(id)) throw new Error(`static tier lists unknown matrix id ${id}`);
}

const overlap = STATIC_TIERS.unit.filter((id) => STATIC_TIERS.guest.includes(id));
if (overlap.length) throw new Error(`scenario listed in both unit and guest: ${overlap.join(", ")}`);

await import("./generate-scenario-catalog.mjs");
await access(join(root, "artifacts/scenario-catalog.json"));

console.log(`scenario catalog checks ok (${Object.keys(PROTOTYPE_FIXTURES).length} prototype fixtures)`);
