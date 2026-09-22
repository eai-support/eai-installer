import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const uiRoot = resolve(root, "ui");
const feature = ".specify-pro/specs/3503-eai-managed-deploy";
const previewDirectory = resolve(root, feature, "preview");
const rust = await readFile(resolve(root, "src-tauri/src/main.rs"), "utf8");
const failure = rust.match(/command_result\("eai-cli", false, ("npm finished,[^"]*"), Some\(("Choose Try again\.[^"]*")\)/);
assert(failure, "The preview must use the actual managed-deployment compatibility failure from Rust.");
const message = JSON.parse(failure[1]);
const recovery = JSON.parse(failure[2]);
const bridge = `
(() => {
  let attempts = 0;
  let installed = false;
  window.__eaiPreviewCalls = [];
  window.__TAURI__ = {
    event: { async listen() { return () => {}; } },
    core: { async invoke(command, args = {}) {
      window.__eaiPreviewCalls.push({ command, args });
      if (command === "get_e2e_configuration") return { enabled: false };
      if (command === "detect_environment") return {
        platform: "macos", architecture: "arm64", package_manager: null,
        tools: [
          { command: "git", version: "git version 2.50.0" },
          { command: "node", version: "v24.8.0" },
          { command: "npm", version: "11.6.0" },
          { command: "eai", version: installed ? "3.18.0" : null },
        ],
      };
      if (command === "run_bootstrap" && args.step === "eai-cli") {
        attempts += 1;
        installed = attempts > 1;
        return {
          ok: installed, step: "eai-cli",
          message: installed ? "The EAI CLI was installed or updated for this user." : ${JSON.stringify(message)},
          command: installed ? null : ${JSON.stringify(recovery)},
          output: null, project_path: null, project_directory: null,
          requires_user_action: !installed, app_created: false,
        };
      }
      throw new Error("Unsupported preview bridge command: " + command);
    } },
  };
})();
`;
const contentTypes = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png" };
const server = createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname);
    if (pathname === "/preview-native-bridge.js") {
      response.writeHead(200, { "Content-Type": "text/javascript", "Cache-Control": "no-store" });
      response.end(bridge);
      return;
    }
    const path = resolve(uiRoot, `.${pathname === "/" ? "/index.html" : pathname}`);
    if (!path.startsWith(`${uiRoot}${sep}`)) { response.writeHead(403); response.end(); return; }
    let contents = await readFile(path);
    if (path === resolve(uiRoot, "index.html")) {
      contents = Buffer.from(contents.toString().replace("</head>", '<script src="/preview-native-bridge.js"></script></head>'));
    }
    response.writeHead(200, { "Content-Type": contentTypes[extname(path)] || "application/octet-stream", "Cache-Control": "no-store" });
    response.end(contents);
  } catch {
    response.writeHead(404); response.end();
  }
});
const args = process.argv.slice(2);
const portIndex = args.indexOf("--port");
const port = portIndex >= 0 ? Number(args[portIndex + 1]) : 43183;
await new Promise((done) => server.listen(port, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}/`;
console.log(`Real installer frontend with controlled native bridge: ${url}`);

if (args.includes("--capture")) {
  let browser;
  try {
    const moduleIndex = args.indexOf("--playwright-module");
    const moduleName = moduleIndex >= 0 ? pathToFileURL(resolve(args[moduleIndex + 1])).href : "playwright";
    const { chromium } = await import(moduleName);
    browser = await chromium.launch({ headless: true });
    await mkdir(previewDirectory, { recursive: true });
    const screenshots = [];
    const assertions = [];
    for (const viewport of [{ width: 900, height: 680 }, { width: 720, height: 540 }]) {
      const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await page.goto(url);
      await page.locator("#retry-install").waitFor({ state: "visible" });
      assert.equal(await page.locator("#output").textContent(), `${message} Next: ${recovery}`);
      assert.equal(await page.locator("#activity-title").textContent(), "EAI CLI setup failed");
      assert.equal(await page.locator('[data-stage="eai-cli"]').getAttribute("data-state"), "error");
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
      await page.locator("#retry-install").focus();
      assert(await page.locator("#retry-install").evaluate((button) => button === document.activeElement));
      const failureName = `managed-deploy-incompatible-${viewport.width}x${viewport.height}.png`;
      await page.screenshot({ path: resolve(previewDirectory, failureName), fullPage: true });
      screenshots.push(`${feature}/preview/${failureName}`);
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => document.querySelector("#activity-title")?.textContent === "Installation complete");
      assert.equal(await page.locator("#retry-install").isVisible(), false);
      assert.equal(await page.locator('[data-stage="eai-cli"]').getAttribute("data-state"), "done");
      assert.equal(await page.locator("#signin-title").isVisible(), true);
      const calls = await page.evaluate(() => window.__eaiPreviewCalls);
      assert.equal(calls.filter((call) => call.command === "run_bootstrap").length, 2);
      assert.equal(calls.some((call) => ["login", "init"].includes(call.args.step)), false);
      assert.deepEqual(errors, []);
      const recoveryName = `managed-deploy-recovered-${viewport.width}x${viewport.height}.png`;
      await page.screenshot({ path: resolve(previewDirectory, recoveryName), fullPage: true });
      screenshots.push(`${feature}/preview/${recoveryName}`);
      assertions.push({ viewport, exactRustFailureText: true, recoveryCommandVisible: true, noHorizontalOverflow: true,
        keyboardRetryWorks: true, retryClearsFailure: true, signInReached: true, nativeBootstrapCalls: 2, browserErrors: errors });
      await page.close();
    }
    const sourceHashes = {};
    for (const file of ["ui/index.html", "ui/styles.css", "ui/app.js", "ui/wizard-state.js", "src-tauri/src/main.rs", "scripts/preview-managed-deploy.mjs"]) {
      sourceHashes[file] = createHash("sha256").update(await readFile(resolve(root, file))).digest("hex");
    }
    const evidence = { capturedAt: new Date().toISOString(), previewUrl: url, browser: `Chromium ${browser.version()}`,
      sourceHead: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
      sourceHashes, fixture: "Actual installer UI, controlled Tauri bridge; failure text extracted from Rust. No native install or cloud calls.",
      assertions, screenshots };
    await writeFile(resolve(previewDirectory, "browser-evidence.json"), `${JSON.stringify(evidence, null, 2)}\n`);
    console.log(JSON.stringify(evidence, null, 2));
  } finally {
    if (browser) await browser.close();
    server.close();
  }
}
