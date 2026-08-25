/* ------------------------------------------------------------------
   A static server for the state-machine playground.

   The playground loads the real app out of `../ui` rather than keeping
   a second copy of it, and a browser will not fetch a sibling folder
   over `file://` — so opening prototype/index.html by double-clicking
   it gives a blank frame and no useful error. This is the smallest
   thing that makes that work.

   Node's own http module, no dependency. The repo has none and this is
   not the file to acquire one for.

   It serves the repository root, because the playground reaches up out
   of its own folder for three things: the app (`../ui`), the state
   machine (`../ui/state-machine.js`) and the window size
   (`../src-tauri/tauri.conf.json`). Every one of those is a deliberate
   reach — it is how the page cannot drift from what ships.

   No caching headers, and that matters more here than anywhere else.
   The whole claim of the page is that it shows the live app; a browser
   holding yesterday's stylesheet makes it a copy, just one nobody
   chose, and the bug that follows looks like a CSS bug rather than a
   stale file.
------------------------------------------------------------------- */

import { createServer } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
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

const server = createServer(async (request, response) => {
  /* `/` redirects rather than serving the file, because the playground's
     stylesheet and script are named relative to it. Serving
     prototype/index.html at `/` resolves `rail.css` against the root and
     gives an unstyled page with two 404s and no obvious cause. */
  if (new URL(request.url, "http://localhost").pathname === "/") {
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
    await stat(file);
    response.writeHead(200, {
      "content-type": TYPES[extname(file)] || "application/octet-stream",
      "cache-control": "no-store",
    });
    createReadStream(file).pipe(response);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" }).end(`Not found: ${request.url}`);
  }
});

server.listen(port, "127.0.0.1", () => {
  /* One address, and it is the statemachine.

     The banner used to print two — the page and the app on its own —
     and the second one is the trap: open it and you get the installer
     with no rail, which looks like the tool is broken rather than like
     you opened the wrong thing. The app is still reachable, from a link
     inside the page, which is where a link to it belongs. */
  console.log(`\n  EAI Setup — statemachine\n\n  →  http://localhost:${port}/\n`);
  console.log("  Every screen and every failure, in the real app, with a rail to reach them.");
  console.log("  A review tool: it is outside ui/, so it is not in the bundle.\n");
});
