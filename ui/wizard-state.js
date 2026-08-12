(function registerWizard(root) {
  const stepCount = 6;

  function clampStep(step) {
    return Math.max(0, Math.min(stepCount - 1, Number(step) || 0));
  }

  function isKebabCase(value) {
    return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value);
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

  root.EAIWizard = { clampStep, createState, isKebabCase, prerequisitesReady, chooseAiSurface, stepCount };
})(typeof window === "undefined" ? globalThis : window);
