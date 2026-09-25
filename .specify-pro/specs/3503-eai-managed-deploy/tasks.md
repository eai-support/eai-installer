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
- [x] Complete exact-head Rust and bundle validation in required CI.

## Local validation on 2026-09-25

- `npm test`: passed on the final local source, including 21 owned tests, 77 scenario states, release-gate contracts, Windows watchdog tests, and production safeguards.
- Focused managed-deployment tests: 15 passed, covering distinct missing/incompatible CLI diagnostics, exact matching for all three required command options, and real Retry control recovery.
- Published-package gate fixtures: 6 passed, covering the released baseline, exact version output, and exact command option tokens. Live readback failed closed as intended because npm `@enterpriseai/cli@3.18.1` lacks `--source`; Installer publication stays blocked until the CLI producer releases the feature.
- `npm run test:journey`: passed, 2 Playwright journeys.
- Managed-deployment browser capture: passed at 900×680 and 720×540 with the shipped Retry control, keyboard recovery, no overflow, and no browser errors.
- `bash -n scripts/bootstrap.sh scripts/release-preflight.sh`, `node --check ui/app.js`, and `git diff --check`: passed.
- Exact-head CI for `23aa16ea1b00c503b353e0736c716cf7492b3ca5`: passed, including Rust CodeQL, `tauri-check`, public hygiene, dependency review, and macOS, Ubuntu, and Windows bundle jobs for both supported architectures.
