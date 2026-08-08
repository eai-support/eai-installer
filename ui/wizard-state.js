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

  function needsHomebrew(report, toolMap) {
    if (report.platform !== "macos" || report.package_manager === "brew") return false;
    return !toolMap.get("git")?.version || !toolMap.get("node")?.version || !toolMap.get("npm")?.version;
  }

  function prerequisitesReady(report, demo = false) {
    if (demo) return true;
    if (!report) return false;
    return ["git", "node", "npm", "eai"].every((command) => report.tools.some((tool) => tool.command === command && tool.version));
  }

  root.EAIWizard = { clampStep, createState, isKebabCase, needsHomebrew, prerequisitesReady, stepCount };
})(typeof window === "undefined" ? globalThis : window);
