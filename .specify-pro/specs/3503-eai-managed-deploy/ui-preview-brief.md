---
feature: 3503-eai-managed-deploy
created: 2026-09-23
workflowProfile: enterpriseai
status: validated
---

# Managed deployment compatibility recovery

The preview covers a developer whose installed CLI cannot expose `eai deploy app`. It shows the exact native compatibility failure, the CLI minimum version and recovery instruction, and a keyboard retry that reaches sign-in after a compatible CLI becomes available.

The server serves the real `ui/index.html`, `ui/styles.css`, `ui/wizard-state.js`, and `ui/app.js`. Only the Tauri bridge is replaced. The failure message and command come directly from the `command_result` in `src-tauri/src/main.rs`; the fixture performs no package installation, sign-in, cloud mutation, or secret exchange.

Run `npm run preview:managed-deploy` and open <http://127.0.0.1:43183/>. To reproduce the browser assertions and images with an installed Playwright module:

```sh
node scripts/preview-managed-deploy.mjs --capture --port 43183 --playwright-module /absolute/path/to/playwright/index.mjs
```

Stop any existing preview server on that port before capture. Playwright Chromium must be installed. The module argument can be omitted when `playwright` is locally resolvable; no production dependency was added.

| Requirement | Evidence |
| --- | --- |
| Native default 900×680 and minimum 720×540 viewport | Four full-page browser screenshots in `preview/` |
| Exact compatibility and recovery text | Source-extracted Rust message asserted in real `#output` |
| Failure state and keyboard focus | CLI stage reports Needs attention; Try again receives visible focus |
| Successful retry | Two fixture bootstrap calls; retry disappears, CLI stage becomes Ready, sign-in panel appears |
| Layout and accessibility | No horizontal overflow, live-region output, keyboard Enter recovery, no browser errors |
| Branding | Existing installer assets and CSS; no new design or app-template dependency |

All scope checks passed. Native packaged installation and real login remain covered by their separate installer tests; this packet proves frontend rendering and recovery behavior.

- [x] Local browser render captured.
- [x] Screenshots inspected at both supported sizes.
- [x] Recovery mismatch fixed and verified.
- [x] No remaining visual issue in the reviewed scope.
