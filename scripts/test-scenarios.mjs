import { readFile } from "node:fs/promises";

const matrix = await readFile(new URL("../docs/scenario-matrix.md", import.meta.url), "utf8");
const requiredIds = [
  "WELCOME-01", "WELCOME-02", "PRE-01", "PRE-02", "PRE-03", "PRE-04", "PRE-05", "PRE-06", "PRE-07",
  "AUTH-01", "AUTH-02", "AUTH-03", "AUTH-04", "AUTH-05", "APP-01", "APP-02", "APP-03", "APP-04", "APP-05", "APP-06",
  "LOCATION-01", "LOCATION-02", "LOCATION-03", "LOCATION-04", "LOCATION-05", "INIT-01", "INIT-02",
  "INIT-03", "INIT-04", "INIT-05", "INIT-06", "INIT-07", "INIT-08", "INIT-09", "COMPLETE-01", "COMPLETE-02", "AI-01", "AI-02", "AI-03", "AI-04", "RELEASE-01",
];

for (const id of requiredIds) {
  if (!matrix.includes(`| ${id} |`)) throw new Error(`scenario matrix is missing ${id}`);
}
if (!matrix.includes("spawn EINVAL") || !matrix.includes("PATH-only") || !matrix.includes("installer invokes `eai init --no-install`") || !matrix.includes("button immediately changes") || !matrix.includes("Double-click")) {
  throw new Error("scenario matrix is missing the Windows initialization interaction cases");
}

console.log(`scenario matrix checks ok (${requiredIds.length} scenarios)`);
