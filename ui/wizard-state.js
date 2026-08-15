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
    if (/spawn EINVAL|npm\.cmd/i.test(cleanMessage) && platform === "windows") {
      return {
        title: "Windows needs the latest EAI CLI",
        detail: "The project files were created, but Windows could not start npm to install its dependencies. Update EAI Setup, then choose Try again. Your project folder is safe to reuse.",
        next: "Close and reopen EAI Setup so it can update the EAI CLI, then retry.",
      };
    }
    return {
      title: "App setup failed",
      detail: cleanMessage,
      next: "Review Recent activity, correct the issue, then choose Try again.",
    };
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
    describeInitFailure,
    initButtonLabel,
    isKebabCase,
    prerequisitesReady,
    chooseAiSurface,
    stepCount,
  };
})(typeof window === "undefined" ? globalThis : window);
