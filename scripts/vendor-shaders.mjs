/* Copy @paper-design/shaders into ui/vendor/ so the Tauri bundle can
   load WebGL without a CDN — the app's CSP is 'self' only. */

import { cp, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "node_modules/@paper-design/shaders/dist");
const target = join(root, "ui/vendor/paper-shaders");

await mkdir(join(root, "ui/vendor"), { recursive: true });
await rm(target, { force: true, recursive: true });
await cp(source, target, { recursive: true });
