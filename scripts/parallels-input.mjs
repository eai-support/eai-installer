#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const KEY = Object.freeze({
  escape: 9,
  "1": 10, "2": 11, "3": 12, "4": 13, "5": 14,
  "6": 15, "7": 16, "8": 17, "9": 18, "0": 19,
  minus: 20, equal: 21, backspace: 22, tab: 23,
  q: 24, w: 25, e: 26, r: 27, t: 28, y: 29, u: 30,
  i: 31, o: 32, p: 33, "left-bracket": 34, "right-bracket": 35,
  enter: 36, control: 37,
  a: 38, s: 39, d: 40, f: 41, g: 42, h: 43, j: 44,
  k: 45, l: 46, semicolon: 47, quote: 48, backtick: 49,
  shift: 50, backslash: 51,
  z: 52, x: 53, c: 54, v: 55, b: 56, n: 57, m: 58,
  comma: 59, dot: 60, slash: 61, "right-shift": 62,
  alt: 64, space: 65,
  home: 97, up: 98, "page-up": 99, left: 100, right: 102,
  end: 103, down: 104, "page-down": 105, insert: 106, delete: 107,
  "right-control": 109, "right-alt": 113,
  command: 115, "right-command": 116,
  "mouse-left": 178, "mouse-middle": 179, "mouse-right": 180,
  "mouse-up-left": 181, "mouse-up": 182, "mouse-up-right": 183,
  "mouse-leftward": 184, "mouse-rightward": 185,
  "mouse-down-left": 186, "mouse-down": 187, "mouse-down-right": 188,
  "wheel-up": 189, "wheel-down": 190, "wheel-left": 191, "wheel-right": 192,
});

const CHARACTER_KEYS = Object.freeze({
  "1": 10, "2": 11, "3": 12, "4": 13, "5": 14,
  "6": 15, "7": 16, "8": 17, "9": 18, "0": 19,
  "-": 20, "=": 21,
  q: 24, w: 25, e: 26, r: 27, t: 28, y: 29, u: 30,
  i: 31, o: 32, p: 33, "[": 34, "]": 35,
  a: 38, s: 39, d: 40, f: 41, g: 42, h: 43, j: 44,
  k: 45, l: 46, ";": 47, "'": 48, "`": 49, "\\": 51,
  z: 52, x: 53, c: 54, v: 55, b: 56, n: 57, m: 58,
  ",": 59, ".": 60, "/": 61, " ": 65,
});

const SHIFTED_KEYS = Object.freeze({
  "!": 10, "@": 11, "#": 12, "$": 13, "%": 14,
  "^": 15, "&": 16, "*": 17, "(": 18, ")": 19,
  _: 20, "+": 21, "{": 34, "}": 35,
  ":": 47, '"': 48, "~": 49, "|": 51,
  "<": 59, ">": 60, "?": 61,
});

function fail(message) {
  console.error(`Parallels input failed: ${message}`);
  process.exit(1);
}

function usage() {
  return [
    "Usage:",
    "  node scripts/parallels-input.mjs --vm <name> key <name> [--repeat <n>]",
    "  node scripts/parallels-input.mjs --vm <name> combo <key+key>",
    "  node scripts/parallels-input.mjs --vm <name> type --stdin",
    "",
    "Secrets must be piped through stdin. Do not place them in command arguments.",
  ].join("\n");
}

function parseArgs(argv) {
  let vm = "";
  let delay = 80;
  let repeat = 1;
  const positionals = [];
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--vm") vm = argv[++index] || "";
    else if (value === "--delay") delay = Number(argv[++index]);
    else if (value === "--repeat") repeat = Number(argv[++index]);
    else if (value === "--help" || value === "-h") {
      console.log(usage());
      process.exit(0);
    } else positionals.push(value);
  }
  if (!vm) fail("--vm is required.");
  if (!Number.isInteger(delay) || delay < 0 || delay > 5000) fail("--delay must be an integer from 0 to 5000.");
  if (!Number.isInteger(repeat) || repeat < 1 || repeat > 1000) fail("--repeat must be an integer from 1 to 1000.");
  return { vm, delay, repeat, positionals };
}

function tap(events, key, delay) {
  if (key === KEY.enter) {
    events.push({ key, event: "press", delay }, { key, event: "release", delay });
  } else {
    events.push({ key, delay });
  }
}

function chord(events, names, delay) {
  if (names.length < 2) fail("A combo must contain at least two keys.");
  const codes = names.map((name) => KEY[name]);
  if (codes.some((code) => code === undefined)) fail("Unknown key in combo.");
  for (const code of codes.slice(0, -1)) events.push({ key: code, event: "press", delay });
  tap(events, codes.at(-1), delay);
  for (const code of codes.slice(0, -1).reverse()) events.push({ key: code, event: "release", delay });
}

function typeText(events, text, delay) {
  for (const character of text) {
    if (character === "\n") {
      tap(events, KEY.enter, delay);
      continue;
    }
    const lower = character.toLowerCase();
    if (CHARACTER_KEYS[character] !== undefined) {
      tap(events, CHARACTER_KEYS[character], delay);
    } else if (character >= "A" && character <= "Z") {
      chord(events, ["shift", lower], delay);
    } else if (SHIFTED_KEYS[character] !== undefined) {
      events.push({ key: KEY.shift, event: "press", delay });
      tap(events, SHIFTED_KEYS[character], delay);
      events.push({ key: KEY.shift, event: "release", delay });
    } else {
      fail("Input contains a character outside the supported US keyboard map.");
    }
  }
}

const { vm, delay, repeat, positionals } = parseArgs(process.argv.slice(2));
const [command, operand, ...extra] = positionals;
if (!command || extra.length > 0) fail(usage());

const status = spawnSync("prlctl", ["status", vm], { encoding: "utf8" });
if (status.status !== 0 || !status.stdout.includes("running")) fail(`VM '${vm}' is not running.`);

const events = [];
if (command === "key") {
  if (KEY[operand] === undefined) fail("Unknown key name.");
  for (let index = 0; index < repeat; index += 1) tap(events, KEY[operand], delay);
} else if (command === "combo") {
  if (!operand) fail("combo requires names separated by '+'.");
  for (let index = 0; index < repeat; index += 1) chord(events, operand.split("+"), delay);
} else if (command === "type") {
  if (operand !== "--stdin") fail("type accepts only --stdin so sensitive text never enters argv.");
  let input = readFileSync(0, "utf8");
  input = input.replace(/\r?\n$/, "");
  if (!input) fail("stdin was empty.");
  typeText(events, input, delay);
} else {
  fail(usage());
}

if (events.length === 0) fail("No input events were generated.");
const result = spawnSync("prlctl", ["send-key-event", vm, "--json"], {
  input: JSON.stringify(events),
  encoding: "utf8",
  stdio: ["pipe", "ignore", "pipe"],
});
if (result.status !== 0) fail("prlctl rejected the input event batch.");
