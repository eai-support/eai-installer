(function registerWizard(root) {
  const stepCount = 6;

  function clampStep(step) {
    return Math.max(0, Math.min(stepCount - 1, Number(step) || 0));
  }

  function isKebabCase(value) {
    return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value);
  }

  function cleanText(value) {
    return String(value ?? "")
      .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
      .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
      .replace(/\r/g, "")
      .trim();
  }

  function summarizeCommandOutput(value) {
    const text = cleanText(value);
    if (!text) return [];
    const summaries = [];
    const add = (message) => {
      if (!summaries.includes(message)) summaries.push(message);
    };
    for (const line of text.split("\n")) {
      if (/cloned from/i.test(line)) add("Downloaded the supported EAI app template.");
      else if (/updated package\.json/i.test(line)) add("Updated the project settings.");
      else if (/generated \.env\.local/i.test(line)) add("Created the local app configuration.");
      else if (/created object types scaffold/i.test(line)) add("Prepared the app data model starter files.");
      else if (/generated (agents|claude)\.md/i.test(line)) add("Prepared the AI workspace guidance.");
      else if (/installed gofer assets/i.test(line)) add("Installed the EAI delivery guidance.");
      else if (/initialized git repository/i.test(line)) add("Prepared local version control.");
      else if (/\badded \d+ packages?\b|\bup to date\b/i.test(line)) add("Installed the required project packages.");
      else if (/authenticated as/i.test(line)) add("Secure browser sign-in completed.");
    }
    return summaries;
  }

  function journeyStageForActivity(activeStep, title) {
    const context = `${activeStep || ""} ${title || ""}`;
    if (/ai workspace|copilot|claude|codex|grok/i.test(context)) return "ai";
    if (/sign[ -]?in|login|signup|account/i.test(context)) return "signin";
    if (/company workspace|\bapp\b|project|folder|tenant/i.test(context)) return "app";
    if (/eai[ -]?cli/i.test(context)) return "eai-cli";
    if (/node|npm/i.test(context)) return "node";
    if (/git|command line tools/i.test(context)) return "git";
    if (/computer|detect|required tools/i.test(context)) return "computer";
    return null;
  }

  function initButtonLabel(appKey, busy = false) {
    if (busy) return appKey ? "Initialising project..." : "Creating app...";
    return appKey ? "Use app and initialise project" : "Create and initialise app";
  }

  function describeInitFailure(message, platform = "") {
    const cleanMessage = cleanText(message) || "The app could not be initialised.";
    if (/no app named .* was found in the selected company workspace/i.test(cleanMessage)) {
      return {
        title: "Existing app could not be found",
        detail: "The selected app is no longer available in this company workspace. No new platform app was created.",
        next: "Choose Create a new app, or refresh the workspace list and select the existing app again.",
      };
    }
    if (/more than one enrollment was returned for app/i.test(cleanMessage)) {
      return {
        title: "Existing app record needs attention",
        detail: "EAI found more than one platform record for the selected app, so it stopped to avoid connecting this project to the wrong app. No new platform app was created.",
        next: "Ask a company administrator to resolve the duplicate app record, then retry.",
      };
    }
    if (/does not identify a runtime tenant/i.test(cleanMessage)) {
      return {
        title: "Existing app is not ready",
        detail: "The selected app does not have a runtime workspace recorded, so EAI stopped before creating a project. No new platform app was created.",
        next: "Choose Create a new app, or ask a company administrator to repair the selected app record before retrying.",
      };
    }
    if (/app.*disabled|status[^\n]*disabled/i.test(cleanMessage)) {
      return {
        title: "Selected app is disabled",
        detail: "The selected EAI app is disabled. EAI did not create a new app or change the existing app.",
        next: "Choose a different active app, or ask a company administrator to enable this app before retrying.",
      };
    }
    if (/the app was created, but its dependencies could not be installed/i.test(cleanMessage)) {
      return {
        title: "App dependencies need attention",
        detail: "The project files were created, but the packages needed to run the app could not be installed. Your project folder is safe to reuse.",
        next: "Choose Try again. If it still fails, open the project folder and run npm install after checking your network connection.",
      };
    }
    if (/spawn EINVAL|npm\.cmd/i.test(cleanMessage) && platform === "windows") {
      return {
        title: "Windows dependency setup needs attention",
        detail: `The project files were created, but Windows returned a process error while installing the app packages. Your project folder is safe to reuse. Diagnostic: ${cleanMessage}`,
        next: "Choose Try again. If it still fails, check the network connection and the project folder, then retry.",
      };
    }
    return {
      title: "App setup failed",
      detail: cleanMessage,
      next: "Review Build summary, correct the issue, then choose Try again.",
    };
  }

  function describeWorkspaceFailure(message) {
    const diagnostic = cleanText(message) || "Company workspaces could not be loaded.";
    if (/\b(502|503|504)\b|bad gateway|service unavailable|gateway timeout|request_error|temporarily unavailable/i.test(diagnostic)) {
      return {
        title: "EAI is temporarily unavailable",
        detail: "Your sign-in is complete. EAI could not load your company workspaces after several attempts.",
        next: "Wait a moment, then choose Try workspace check again. You do not need to sign in again.",
        diagnostic,
        retryable: true,
      };
    }
    if (/no active company workspaces|no company workspaces are available/i.test(diagnostic)) {
      return {
        title: "No company workspace is available",
        detail: "Your account is signed in, but it cannot create an app until a company workspace is assigned.",
        next: "Ask your company administrator to add you to a workspace, then try the workspace check again.",
        diagnostic,
        retryable: true,
      };
    }
    if (/\b(401|token expired|not authenticated|sign-in)\b/i.test(diagnostic)) {
      return {
        title: "Sign-in needs refreshing",
        detail: "EAI could not confirm the current browser sign-in.",
        next: "Choose Sign in with browser, then continue setup.",
        diagnostic,
        retryable: false,
      };
    }
    return {
      title: "Company workspaces need attention",
      detail: "EAI could not confirm where this app should be created.",
      next: "Review Build summary, then try the workspace check again.",
      diagnostic,
      retryable: true,
    };
  }

  function describeAppFailure(message) {
    const diagnostic = cleanText(message) || "Apps could not be loaded.";
    if (/\b(502|503|504)\b|bad gateway|service unavailable|gateway timeout|request_error|temporarily unavailable/i.test(diagnostic)) {
      return {
        title: "EAI is temporarily unavailable",
        detail: "Your sign-in is complete and your company workspace is ready. EAI could not load the apps after several attempts.",
        next: "Wait a moment, then choose Try again.",
        diagnostic,
        retryable: true,
      };
    }
    if (/\b(401|token expired|not authenticated|sign-in)\b/i.test(diagnostic)) {
      return {
        title: "Sign-in needs refreshing",
        detail: "EAI could not confirm the current browser sign-in while loading apps.",
        next: "Return to sign-in and refresh your session.",
        diagnostic,
        retryable: false,
      };
    }
    return {
      title: "Apps need attention",
      detail: "EAI could not load the apps for this company workspace.",
      next: "Review Build summary, then choose Try again.",
      diagnostic,
      retryable: true,
    };
  }

  function retryActionLabel(scope) {
    return scope === "workspace" ? "Try workspace check again" : "Try again";
  }

  function workspaceRetryCanContinue(retryingApps, tenantCount, selectedTenantId) {
    return Boolean(retryingApps || Number(tenantCount) === 1 || selectedTenantId);
  }

  function resolveTenantSelection(tenants, selectedTenantId) {
    if (!Array.isArray(tenants) || tenants.length === 0) return null;
    if (selectedTenantId && tenants.some((tenant) => tenant.id === selectedTenantId)) {
      return selectedTenantId;
    }
    return tenants.length === 1 ? tenants[0].id : null;
  }

  function createState() {
    return { step: 0, prerequisitesReady: false, projectName: "" };
  }

  function prerequisitesReady(report, demo = false) {
    if (demo) return true;
    if (!report) return false;
    const required = ["git", "node", "npm", "eai"];
    if (report.platform === "windows") required.push("windows-runtime");
    return required.every((command) => report.tools.some((tool) => tool.command === command && tool.version));
  }

  const hiddenAiSurfaceIds = new Set(["grok-cli"]);

  function visibleAiSurfaces(inventory) {
    if (!inventory || !Array.isArray(inventory.surfaces)) return [];
    return inventory.surfaces.filter((surface) => !hiddenAiSurfaceIds.has(surface.id));
  }

  function chooseAiSurface(inventory) {
    if (!inventory) return null;
    const surfaces = visibleAiSurfaces(inventory);
    const readyIds = new Set(surfaces.filter((surface) => surface.installed).map((surface) => surface.id));
    if (inventory.preferredSurface && readyIds.has(inventory.preferredSurface)) return inventory.preferredSurface;
    if (inventory.recommendedSurface && readyIds.has(inventory.recommendedSurface)) return inventory.recommendedSurface;
    return surfaces.find((surface) => surface.installed)?.id || surfaces[0]?.id || null;
  }

  const aiSurfaceRecommendationScores = Object.freeze({
    "vscode-copilot": 4,
    "copilot-cli": 3,
    "copilot-desktop": 2,
    "claude-desktop": 2,
    "claude-cli": 3,
    "codex-desktop": 3,
    "codex-cli": 3,
    "grok-cli": 1,
  });

  function aiSurfaceRecommendation(surfaceId) {
    const score = aiSurfaceRecommendationScores[surfaceId] ?? 0;
    const labels = ["Not scored", "Basic handoff", "Supported", "Strong fit", "Best fit"];
    return { score, maximum: 4, label: labels[score] };
  }

  root.EAIWizard = {
    clampStep,
    cleanText,
    createState,
    describeAppFailure,
    describeInitFailure,
    describeWorkspaceFailure,
    initButtonLabel,
    isKebabCase,
    prerequisitesReady,
    visibleAiSurfaces,
    chooseAiSurface,
    aiSurfaceRecommendation,
    retryActionLabel,
    resolveTenantSelection,
    summarizeCommandOutput,
    journeyStageForActivity,
    workspaceRetryCanContinue,
    stepCount,
  };
})(typeof window === "undefined" ? globalThis : window);
