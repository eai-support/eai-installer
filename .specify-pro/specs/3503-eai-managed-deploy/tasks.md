# Tasks

- [x] Record 2026-09-25 approval and preserved user contract.
- [x] Merge current `main` without force-pushing.
- [x] Gate local-template overrides behind a test-only build capability (DTE-057).
- [x] Accept normal Git worktrees (DTE-058).
- [x] Align and test the shipped retry control (DTE-058, DTE-094).
- [x] Clarify capability-versus-version release gating (DTE-056, DTE-088).
- [x] Gate production publication on an isolated readback of the actual published CLI package and command help (DTE-056, DTE-088).
- [x] Reject lookalike options and bind both local and protected-workflow publication to the same exact package gate (DTE-056, DTE-088).
- [x] Update owned tests and traceability.
- [ ] Complete exact-head Rust and bundle validation in required CI after the latest review fixes.

## Local validation on 2026-09-25

- `npm test`: passed on the final local source, including 25 owned tests, 77 scenario states, release-gate contracts, Windows watchdog tests, and production safeguards.
- Focused managed-deployment tests: 18 passed, covering distinct missing/incompatible CLI diagnostics, exact complete version output and exit status, exact matching for all three required command options, and real Retry control recovery.
- Bootstrap, desktop, and cross-platform release evidence now reject wrapped or ambiguous CLI version output; the successful exact-version flow is unchanged.
- The test-only local template override requires Git to recognize the exact checkout and metadata directory, and all three VM adapters bind exact executable output to the installed CLI package version.
- Published-package gate fixtures: 7 passed, covering the released baseline, exact `eai` bin ownership, exact version output, and exact command option tokens. Live readback failed closed as intended because npm `@enterpriseai/cli@3.18.1` lacks `--source`; Installer publication stays blocked until the CLI producer releases the feature.
- `npm run test:journey`: passed, 2 Playwright journeys.
- Managed-deployment browser capture: passed at 900×680 and 720×540 with the shipped Retry control, keyboard recovery, no overflow, and no browser errors.
- `bash -n scripts/bootstrap.sh scripts/release-preflight.sh`, `node --check ui/app.js`, and `git diff --check`: passed.
- Required exact-head CI and refreshed browser provenance must rerun after the final Windows resolver review fix. Implementation commit `e0f4d350ac33d3798f15480727c42db9896bd0df` passed the preceding full required check set.
