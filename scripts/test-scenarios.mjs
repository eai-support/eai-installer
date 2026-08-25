import { readFile } from "node:fs/promises";

const matrix = await readFile(new URL("../docs/scenario-matrix.md", import.meta.url), "utf8");
const requiredIds = [
  "WELCOME-01", "WELCOME-02", "PRE-01", "PRE-02", "PRE-03", "PRE-04", "PRE-05", "PRE-06", "PRE-07",
  "AUTH-01", "AUTH-02", "AUTH-03", "AUTH-04", "AUTH-05", "APP-01", "APP-02", "APP-03", "APP-04", "APP-05", "APP-06",
  "LOCATION-01", "LOCATION-02", "LOCATION-03", "LOCATION-04", "LOCATION-05", "INIT-01", "INIT-02",
  "STATE-01", "STATE-02", "STATE-03", "STATE-04", "STATE-05", "STATE-06", "STATE-07", "STATE-08", "STATE-09", "STATE-10",
  "STATE-11", "STATE-12", "STATE-13", "STATE-14", "STATE-15", "STATE-16", "STATE-17", "STATE-18", "STATE-19", "STATE-20",
  "HARNESS-01", "HARNESS-02", "HARNESS-03", "HARNESS-04", "HARNESS-05",
  "PLATFORM-01", "PLATFORM-02", "PLATFORM-03", "PLATFORM-04",
  "INIT-03", "INIT-04", "INIT-05", "INIT-06", "INIT-07", "INIT-08", "INIT-09", "COMPLETE-01", "COMPLETE-02", "AI-01", "AI-02", "AI-03", "AI-04", "RELEASE-01",
];

for (const id of requiredIds) {
  if (!matrix.includes(`| ${id} |`)) throw new Error(`scenario matrix is missing ${id}`);
}
if (!matrix.includes("spawn EINVAL") || !matrix.includes("PATH-only") || !matrix.includes("installer invokes `eai init --no-install`") || !matrix.includes("button immediately changes") || !matrix.includes("Double-click")) {
  throw new Error("scenario matrix is missing the Windows initialization interaction cases");
}
// The redesign's two hardest scenarios to remember: a machine that already
// has the tool, and one that has to go and get it.
if (!matrix.includes("Ready on this <device>") || !matrix.includes("Waiting for <tool>")) {
  throw new Error("scenario matrix does not cover both harness-installed states");
}
if (!matrix.includes("xcode-select") || !matrix.includes("winget")) {
  throw new Error("scenario matrix does not cover the per-platform prerequisite wording");
}

/* Scope, and where it is written down. The app picker was removed on
   purpose; the matrix has to say so, or the next person reads its
   absence as a regression. */
if (!matrix.includes("known-issues.md")) {
  throw new Error("scenario matrix does not point at the log of what was deliberately left out");
}
const known = await readFile(new URL("../docs/known-issues.md", import.meta.url), "utf8");
for (const id of ["KI-01", "KI-02", "KI-03", "KI-04"]) {
  if (!known.includes(`## ${id}`)) throw new Error(`known issues log is missing ${id}`);
}
if (!known.includes("app name") || !known.includes("read-only")) {
  throw new Error("known issues log no longer records why the app name could not be changed");
}

console.log(`scenario matrix checks ok (${requiredIds.length} scenarios)`);
