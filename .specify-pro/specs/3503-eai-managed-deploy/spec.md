# Issue #3503: Installer managed-deployment capability gate

The coordinated 95-requirement deployment specification is recorded in
[Issue #3503](https://github.com/enterpriseaigroup/Issues2025/issues/3503#issuecomment-5826177803).

## Approval and scope

The owner approved this hardening scope on 2026-09-25. It covers reviewed Installer capability, test-isolation, worktree, and recovery fixes while preserving successful setup and both source journeys. It does not authorize merge, release, deployment, activation, billing, or destructive live tests.

## Preserved user contract

- Setup continues to install and validate the EAI CLI across supported operating systems.
- Both `eai-managed` and `customer-owned` onboarding commands remain visible.
- Version checks remain additive to executable capability checks.
- A user can retry a failed prerequisite from the shipped interface.

## Requirements

- **DTE-056:** require executable capability detection as well as a baseline version; defer the final feature-version floor until a feature-bearing CLI is actually released.
- **DTE-057:** compile or authenticate local-template overrides as test-only behavior; an ordinary production environment variable cannot enable arbitrary trusted scripts.
- **DTE-058:** accept a standard Git worktree whose `.git` is a file and drive recovery through a shipped UI control.
- **DTE-094:** keep recovery selectors aligned with the real UI and prove the exact controls in owned UI tests/evidence.
- **DTE-077:** leave live Installer-first dual-source qualification as an explicit post-release gate.
- **DTE-086 through DTE-088:** retain current-main behavior, rerun owned checks, and do not predict an unreleased CLI version.

## Acceptance

1. Production builds ignore or reject ordinary environment-only local-template overrides.
2. Debug/test builds can opt into a bounded local template through the explicit `e2e-local-template` compile feature; release builds reject that feature and runtime-only overrides.
3. Normal repositories and linked Git worktrees both pass template validation.
4. Recovery automation selects an element that exists in the shipped UI, and an owned test proves the retry interaction.
5. Bootstrap scripts reject a version-compatible CLI that lacks the managed deployment flags.
6. Release preflight refuses publication until the actual feature-bearing CLI release and capabilities are available.
7. macOS, Windows, and Ubuntu guest evidence accepts a CLI at or above the released baseline only when the installed executable exposes source choice, GitHub-link handoff, and explicit target-tenant binding; executable and package evidence stay bound to the actual installed version.
