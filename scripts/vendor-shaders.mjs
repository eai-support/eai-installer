/* Copy @paper-design/shaders into ui/vendor/ and bundle ui/shader.js
   into one file. The prototype loads modules over http with no CSP; Tauri
   locks script-src to hashed 'self' scripts and blocks data: images unless
   img-src says so — a type="module" graph plus a data: noise texture fails
   in the signed webview even when it works in the statemachine rail. */

import { cp, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "node_modules/@paper-design/shaders/dist");
const target = join(root, "ui/vendor/paper-shaders");

await mkdir(join(root, "ui/vendor"), { recursive: true });
await rm(target, { force: true, recursive: true });
await cp(source, target, { recursive: true });

await esbuild.build({
  entryPoints: [join(root, "ui/shader.js")],
  outfile: join(root, "ui/shader.bundle.js"),
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["es2020"],
  logLevel: "silent",
});
