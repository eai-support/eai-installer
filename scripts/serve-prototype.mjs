/* ------------------------------------------------------------------
   A static server for the state machine, with live reload.

   The page loads the real app out of `../ui` rather than keeping a
   second copy of it, and a browser will not fetch a sibling folder over
   `file://` — so opening prototype/index.html by double-clicking gives
   a blank frame and no useful error. This is the smallest thing that
   makes that work.

   Node's own http module and fs.watch, no dependency. The repo has none
   and this is not the file to acquire one for.

   It serves the repository root, because the page reaches up out of its
   own folder for three things: the app (`../ui`), the state machine
   (`../ui/state-machine.js`) and the window size
   (`../src-tauri/tauri.conf.json`). Every one of those is a deliberate
   reach — it is how the page cannot drift from what ships.

   Two things it does beyond serving bytes:

   · **No caching, ever.** The whole claim of the page is that it shows
     the live app; a browser holding yesterday's stylesheet makes it a
     copy, just one nobody chose, and the bug that follows looks like a
     CSS bug rather than a stale file.

   · **Reloads open tabs when ui/ or prototype/ changes.** The snippet
     that does it is added to HTML *responses*, never to the files —
     nothing in the repository knows this server exists, and the bytes
     Tauri bundles are untouched. scripts/test-ui-contract.mjs fails if
     any of it ever lands on disk.
------------------------------------------------------------------- */

import { createServer } from "node:http";
import { watch } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const port = Number(process.env.PORT) || 4321;

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

/**
 * The path on disk for a request, or null if it escapes the repository.
 *
 * `..` in a URL is the obvious way out of a static root, and this server
 * is pointed at a folder containing the whole repository. It only ever
 * listens on localhost, but a path check is one line and the alternative
 * is trusting that it always will.
 */
function resolve(url) {
  const path = decodeURIComponent(new URL(url, "http://localhost").pathname);
  const target = normalize(join(root, path));
  if (!target.startsWith(root.endsWith(sep) ? root : root + sep)) return null;
  return target;
}

/* ====================== live reload =============================

   One long-lived response per open tab, and a line written down it when
   a file changes. No websocket and no library: this is four lines of
   protocol, and the browser has shipped the client for it for a decade. */

const listeners = new Set();

const RELOAD_SNIPPET = `
<script>
/* Added by scripts/serve-prototype.mjs, to the response and not to the
   file. Nothing on disk knows this server exists, and Tauri bundles ui/
   exactly as it is written. */
(function () {
  // Only the top document reloads. The app in the frame has its src set
  // again on the way back up, so reloading both is one reload wasted.
  if (window.top !== window) return;
  var stream = new EventSource('/__reload');
  stream.onmessage = function () { location.reload(); };
})();
</script>`;

let pending = null;
function fileChanged() {
  // Editors write a file two or three times. One reload is enough.
  clearTimeout(pending);
  pending = setTimeout(() => {
    for (const listener of listeners) listener.write("data: changed\n\n");
  }, 80);
}

function watchForChanges() {
  for (const folder of ["ui", "prototype", "src-tauri"]) {
    try {
      /* src-tauri is watched for tauri.conf.json alone, which is where
         the window size comes from. Recursive there would drag in
         target/ — tens of thousands of files that rebuild constantly. */
      const recursive = folder !== "src-tauri";
      watch(join(root, folder), { recursive }, (_event, name) => {
        if (!recursive && name !== "tauri.conf.json") return;
        if (name && /(^|[/\\])(\.|node_modules$|target$)/.test(name)) return;
        fileChanged();
      });
    } catch (error) {
      console.warn(`  (not watching ${folder}/ — ${error.message})`);
    }
  }
}

/* ========================= serving =============================== */

const server = createServer(async (request, response) => {
  const path = new URL(request.url, "http://localhost").pathname;

  if (path === "/__reload") {
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      connection: "keep-alive",
    });
    response.write("retry: 500\n\n");
    listeners.add(response);
    request.on("close", () => listeners.delete(response));
    return;
  }

  /* `/` redirects rather than serving the file, because the page's
     stylesheet and script are named relative to it. Serving
     prototype/index.html at `/` resolves `rail.css` against the root and
     gives an unstyled page with two 404s and no obvious cause. */
  if (path === "/") {
    response.writeHead(302, { location: "/prototype/" }).end();
    return;
  }

  const target = resolve(request.url);
  if (!target) {
    response.writeHead(403).end("Outside the repository.");
    return;
  }
  try {
    const info = await stat(target);
    const file = info.isDirectory() ? join(target, "index.html") : target;
    const type = TYPES[extname(file)] || "application/octet-stream";
    const body = await readFile(file);
    const headers = { "content-type": type, "cache-control": "no-store" };

    // HTML gets the reload client. Everything else is sent as written.
    if (type.startsWith("text/html")) {
      const html = body.toString("utf8").replace("</body>", `${RELOAD_SNIPPET}\n</body>`);
      response.writeHead(200, headers).end(html);
      return;
    }
    response.writeHead(200, headers).end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" }).end(`Not found: ${request.url}`);
  }
});

/* A port already in use means it is already running, which is the thing
   this is meant to stop being a surprise. Say so plainly rather than
   printing a stack and leaving somebody to read it. */
server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.log(`\n  Already running  →  http://localhost:${port}/\n`);
    console.log("  It reloads on its own when ui/ or prototype/ changes.\n");
    process.exit(0);
  }
  throw error;
});

server.listen(port, "127.0.0.1", () => {
  watchForChanges();
  console.log(`\n  EAI Setup — statemachine\n\n  →  http://localhost:${port}/\n`);
  console.log("  Every screen and every failure, in the real app, with a rail to reach them.");
  console.log("  Reloads itself when ui/ or prototype/ changes — leave the tab open.");
  console.log("  A review tool: it is outside ui/, so it is not in the bundle.\n");
});
