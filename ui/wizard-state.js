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

  function initButtonLabel(appKey, busy = false) {
    if (busy) return appKey ? "Initialising project..." : "Creating app...";
    return appKey ? "Use app and initialise project" : "Create and initialise app";
  }

  function describeInitFailure(message, platform = "") {
    const cleanMessage = cleanText(message) || "The app could not be initialised.";
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
      next: "Review Recent activity, correct the issue, then choose Try again.",
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
      next: "Review Recent activity, then try the workspace check again.",
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
      next: "Review Recent activity, then choose Try again.",
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

  function createState() {
    return { step: 0, prerequisitesReady: false, projectName: "" };
  }

  function prerequisitesReady(report, demo = false) {
    if (demo) return true;
    if (!report) return false;
    return ["git", "node", "npm", "eai"].every((command) => report.tools.some((tool) => tool.command === command && tool.version));
  }

  function chooseAiSurface(inventory) {
    if (!inventory || !Array.isArray(inventory.surfaces)) return null;
    const readyIds = new Set(inventory.surfaces.filter((surface) => surface.installed).map((surface) => surface.id));
    if (inventory.preferredSurface && readyIds.has(inventory.preferredSurface)) return inventory.preferredSurface;
    if (inventory.recommendedSurface && readyIds.has(inventory.recommendedSurface)) return inventory.recommendedSurface;
    return inventory.surfaces.find((surface) => surface.installed)?.id || inventory.surfaces[0]?.id || null;
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
    chooseAiSurface,
    retryActionLabel,
    workspaceRetryCanContinue,
    stepCount,
  };
})(typeof window === "undefined" ? globalThis : window);
