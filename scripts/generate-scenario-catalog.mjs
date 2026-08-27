/* Build artifacts/scenario-catalog.json for cloud agents and CI.

   Prototype scenarios get a full URL and checks; unit and guest scenarios
   are listed so the catalog covers the whole matrix without pretending
   they are browser-testable. */

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { PROTOTYPE_FIXTURES, STATIC_TIERS } from "./scenario-fixtures.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const matrix = await readFile(join(root, "docs/scenario-matrix.md"), "utf8");
const matrixIds = [...matrix.matchAll(/\|\s*([A-Z]+-\d+)\s*\|/g)].map((match) => match[1]);

const DEFAULT_BASE = process.env.SCENARIO_CATALOG_BASE || "http://localhost:4321/ui/index.html";

/** @type {Record<string, string>} */
const ALIASES = {
  "STATE-01-signin": "STATE-01",
  "STATE-01-setup": "STATE-01",
  "STATE-22-handoff": "STATE-22",
};

function buildUrl(params) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") query.set(key, String(value));
  }
  const qs = query.toString();
  return qs ? `${DEFAULT_BASE}?${qs}` : DEFAULT_BASE;
}

const scenarios = [];

for (const [fixtureId, fixture] of Object.entries(PROTOTYPE_FIXTURES)) {
  const matrixId = ALIASES[fixtureId] || fixtureId;
  scenarios.push({
    id: fixtureId,
    matrixId,
    tier: "prototype",
    url: buildUrl(fixture.params),
    params: fixture.params,
    checks: fixture.checks,
    agent: fixture.agent,
  });
}

for (const id of STATIC_TIERS.unit) {
  scenarios.push({ id, tier: "unit", runner: "npm test" });
}
for (const id of STATIC_TIERS.guest) {
  scenarios.push({ id, tier: "guest", runner: "release-e2e" });
}

const outDir = join(root, "artifacts");
await mkdir(outDir, { recursive: true });
const outPath = join(outDir, "scenario-catalog.json");

const catalog = {
  generatedAt: new Date().toISOString(),
  baseUrl: DEFAULT_BASE,
  viewport: [1100, 720],
  prototypeCount: Object.keys(PROTOTYPE_FIXTURES).length,
  matrixCount: matrixIds.length,
  scenarios: scenarios.sort((a, b) => a.id.localeCompare(b.id)),
};

await writeFile(outPath, `${JSON.stringify(catalog, null, 2)}\n`, "utf8");
console.log(`scenario catalog written (${catalog.prototypeCount} prototype, ${STATIC_TIERS.unit.length} unit, ${STATIC_TIERS.guest.length} guest) → ${outPath}`);
