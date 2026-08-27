# Merge plan: PRs 71 → 74 → 72

Handoff doc for executing the stacked merge to `main`. Repo: `eai-support/eai-installer`.

## PR stack

| PR | Branch | Base | Contents |
|----|--------|------|----------|
| **71** | `GChainey/connect-three-repos-ui` | `main` | State machine rebuild, prototype rail, two-column layout (~22 commits) |
| **74** | `GChainey/pr71-two-column-shader` | **71** | UI polish: harness in-row CTAs, shader/Tauri, built screen, nav buttons |
| **72** | `GChainey/scenario-cloud-agents` | **71** | Scenario catalog: docs, fixtures, CI workflow |

74 and 72 are **siblings** (both fork from 71). Low file overlap: 74 → `ui/`; 72 → `docs/`, `scripts/`.

```
main ← 71 ← 74
main ← 71 ← 72   (after 74 is on main)
```

**Recommended:** Path A — three merges to `main` in order **71 → 74 → 72**.

---

## Human vs agent

| Step | Agent | Human |
|------|-------|-------|
| Fetch, checkout, rebase, `npm test`, fix fixture conflicts | ✅ | |
| Retarget PR base after 71 lands (`gh pr edit --base main`) | ✅ | |
| Mark PR ready (`gh pr ready 71`) | ✅ | Blocked if repo policy restricts |
| **Merge PRs** (`gh pr merge`) | ⚠️ if permitted | **Usually yes** — approve + merge |
| Resolve ambiguous conflicts (product intent) | Partial | **Yes** if unclear |
| Delete remote branches | ✅ | **Ask first** |
| Tauri / visual smoke | Build only | **Yes** for shader, harness UX |
| Choose Path A vs B | Recommend A | **Yes** if single squash preferred |

**Default:** Agent prepares branches, retargets, rebases, runs tests, fixes stale fixtures. Human merges when green.

---

## Execution (Path A)

### 1. Merge PR 71 → `main`

**Agent:**
```bash
git fetch origin
git checkout GChainey/connect-three-repos-ui && git pull
npm ci && npm test
gh pr ready 71    # still draft as of 2026-08-27
gh pr view 71 --json mergeable,statusCheckRollup
```

**Human:** Approve + merge PR 71.

**Agent after:**
```bash
git checkout main && git pull origin main
```

### 2. Merge PR 74 → `main`

**Agent (automatic retarget + rebase):**
```bash
gh pr edit 74 --base main
git checkout GChainey/pr71-two-column-shader && git pull
git rebase origin/main
npm test
git push --force-with-lease origin GChainey/pr71-two-column-shader
```

Confirm PR diff shows **only UI polish**, not full 71 history again.

**Human:** Visual smoke (prototype + Tauri shader), approve + merge PR 74.

**Agent after:** `git pull origin main`

### 3. Merge PR 72 → `main`

**Agent:**
```bash
gh pr edit 72 --base main
git checkout GChainey/scenario-cloud-agents && git pull
git rebase origin/main
# Fix scripts/scenario-fixtures.mjs if harness selectors/copy are stale (post-74)
npm test && npm run scenario-catalog
git push --force-with-lease origin GChainey/scenario-cloud-agents
```

**Human:** Confirm CI “Scenario catalog” workflow + artifact; approve + merge PR 72.

**Agent after:** `git pull origin main && npm test`

---

## Path B (only if human explicitly asks)

1. Merge 74 into `GChainey/connect-three-repos-ui`
2. Rebase/merge 72 onto updated 71; fix fixtures
3. Merge PR 71 → `main` once
4. Close 74 and 72 as superseded

---

## Risks

### Low (mechanical)

- **Git conflicts between 74 and 72** — minimal overlap; easy rebase
- **Retargeting** — agent handles; standard stacked-PR step
- **CI on merge** — PR 71 green on 2026-08-27 (CI, installer matrix, CodeQL, tauri-check)

### Medium (likely needs a fix pass)

1. **Stale scenario fixtures (PR 72)** — highest concrete risk. Written against pre-74 harness UI. May reference `#builtOverlay`, “Next step”, overlay-style harness. Update `scripts/scenario-fixtures.mjs` and `docs/scenario-matrix.md` after 74 lands.
2. **`package.json` / test script overlap** — keep both 74’s UI contract tests and 72’s scenario-catalog in test chain after rebase.
3. **PR 71 is draft** — must undraft before merge.
4. **Large blast radius on 71** — replaces core wizard flow; regressions more likely in real install paths than in CI.

### Higher (harder to catch automatically)

5. **Tauri vs prototype divergence** — shader bundle + CSP; visual issues may only show in local Tauri release build.
6. **Real installer / OS behavior** — harness open-install, browser sign-in, location, handoff depend on OS and external tools; state machine tests mock much of this.
7. **Wrong merge order** — if 72 lands before 74 (or before fixture update), scenario catalog describes old UI. Fixable follow-up, but confusing immediately.
8. **Green CI ≠ ship ready** — FOUC, button sizing, in-row CTAs are mostly visual; contract tests won’t catch subtle UX bugs.

### Low probability, painful

- External docs/demos referencing old selectors
- Mid-merge branch drift requiring re-rebase
- Platform-specific UX issues (polish likely exercised on macOS)

---

## Pre/post checks

```bash
npm ci && npm test
npm run scenario-catalog   # after 72 rebased
cd src-tauri && cargo test   # optional
```

**Manual smoke (after 74):**
- Prototype: `npm run prototype` → harness, sign-in, `?screen=built`, `?screen=done&installed=none&pick=codex-cli`
- Tauri: `cd src-tauri && cargo build && open target/debug/eai-setup` — shader animates, no load flash

**Conflict resolution:** If both touch `package.json` or `scripts/test-*.mjs`, keep **both** test suites. For `ui/*`, prefer **74**.

---

## Success criteria

- [ ] `main` has state machine + UI polish + scenario catalog
- [ ] `npm test` green on `main`
- [ ] PRs 71, 74, 72 merged (human)
- [ ] Scenario fixtures match post-74 harness UI
- [ ] No force-push to `main`

## Rollback

Separate merge commits per PR (if using merge commits) — revert one PR without undoing the whole stack.
