import { expect, test } from "@playwright/test";

const tools = ["git", "node", "npm", "windows-runtime", "eai"].map((command) => ({
  command,
  version: command === "node" ? "24.1.0" : "1.0.0",
}));

test.beforeEach(async ({ page }) => {
  await page.addInitScript(({ readyTools }) => {
    window.__testReceipts = [];
    window.__testAiSurfaceStarts = 0;
    window.__TAURI__ = {
      core: {
        invoke: async (command, args = {}) => {
          switch (command) {
            case "get_e2e_configuration": return window.__testE2eConfig || { enabled: false };
            case "detect_environment": return { platform: "windows", architecture: "arm64", tools: readyTools };
            case "check_connectivity": return { ok: true };
            case "verify_e2e_auth": return { ok: true };
            case "get_company_tenants": return [{ id: "test", displayName: "Test workspace" }];
            case "get_company_apps": return [];
            case "run_bootstrap":
              return args.step === "init"
                ? { ok: true, app_created: true, project_directory: "C:\\EAI\\playwright-e2e", project_path: "C:\\EAI\\playwright-e2e" }
                : { ok: true, message: "Ready" };
            case "detect_ai_surfaces": return window.__testAiInventories?.shift() || {
              preferredSurface: "vscode-copilot",
              surfaces: [{ id: "vscode-copilot", provider: "GitHub", installed: true, launchSupport: "project-and-prompt" }],
            };
            case "start_ai_surface": window.__testAiSurfaceStarts += 1; return { ok: true, launched: true };
            case "write_e2e_receipt": window.__testReceipts.push(args.receipt); return { ok: true };
            default: return { ok: true };
          }
        },
      },
      event: { listen: async () => () => {} },
      dialog: { open: async () => "C:\\EAI" },
    };
  }, { readyTools: tools });
});

test("Windows Welcome waits for Get started", async ({ page }) => {
  await page.goto("/ui/index.html");
  await expect(page.locator("#setupStart")).toBeVisible();
  await expect(page.locator('[data-screen="signin"]')).toBeHidden();
  await page.locator("#setupStart").click();
  await expect(page.locator("#setupStart")).toHaveText("Let’s go");
  await page.locator("#setupStart").click();
  await expect(page.getByRole("heading", { name: "Sign in to Enterprise AI" })).toBeVisible();
});

test("Windows release E2E refreshes the AI inventory after project creation", async ({ page }) => {
  await page.addInitScript(() => {
    window.__testE2eConfig = {
      enabled: true,
      companyTenantId: "test",
      projectName: "playwright-e2e-retry",
      directory: "C:\\EAI",
      receiptFile: "C:\\EAI\\receipt.json",
    };
    window.__testAiInventories = [
      { preferredSurface: null, surfaces: [{ id: "vscode-copilot", provider: "GitHub", installed: false, launchSupport: "project-and-prompt" }] },
      { preferredSurface: "vscode-copilot", surfaces: [{ id: "vscode-copilot", provider: "GitHub", installed: true, launchSupport: "project-and-prompt" }] },
    ];
  });
  await page.goto("/ui/index.html");
  await expect.poll(() => page.evaluate(() => window.__testAiSurfaceStarts), { timeout: 8_000 }).toBe(1);
  await expect.poll(() => page.evaluate(() => window.__testReceipts.at(-1)?.status), { timeout: 8_000 }).toBe("passed");
});
