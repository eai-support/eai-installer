# Cloud agent scenario testing

This document describes how automated scenario runs fit beside the
existing checks, and how a cloud agent (or a human with the same
catalog) exercises the installer UI without walking the full native
bootstrap every time.

## Three tiers

| Tier | What runs | What it proves | What it cannot prove |
| --- | --- | --- | --- |
| **Unit** | `npm test` | Copy, state machine, UI contract, scenario IDs in the matrix | Pixels, WebView CSP, real CLI |
| **Prototype** | `npm run prototype` + catalog URLs | Every reviewable screen, wording, layout, and failure state at 1100×720 | macOS password prompt, real login, real `eai init`, harness poll |
| **Guest** | Release E2E VMs | Full bootstrap on clean macOS, Windows, Ubuntu | Fast feedback on a PR |

Cloud agents sit in **prototype** tier. They open a URL from the
scenario catalog, assert the checks listed there, and write a receipt.
That is the same surface you have been using manually in Conductor.

## The scenario catalog

`npm run scenario-catalog` writes
`artifacts/scenario-catalog.json`. Each entry contains:

- **id** — matches `docs/scenario-matrix.md` (for example `HARNESS-02`)
- **tier** — `prototype`, `unit`, or `guest`
- **url** — direct address of `ui/index.html` with the query string the
  app already understands (no rail required)
- **checks** — machine-readable assertions (`present`, `absent`, `text`)
- **agent** — plain-language goal, viewport, and optional notes for the
  cloud agent prompt

Only scenarios with a `prototype` tier and a fixture in
`scripts/scenario-fixtures.mjs` appear with a URL. The rest are listed
so agents and release tooling know they belong to unit or guest tier.

## Running locally

```bash
npm run prototype          # leave running — http://localhost:4321/
npm run scenario-catalog   # writes artifacts/scenario-catalog.json
npm test                   # includes test-scenario-catalog.mjs
```

Open any catalog URL in a browser at **1100×720**, or point a cloud
agent at the same address with the `agent` block as its brief.

Example:

```text
http://localhost:4321/ui/index.html?screen=done&installed=none
```

## Cloud agent workflow (Conductor / CI)

1. **Start the prototype server** in the workspace (`npm run prototype`).
2. **Generate the catalog** (`npm run scenario-catalog`) so URLs and
   checks match the current branch.
3. **For each scenario** in the catalog where `tier` is `prototype`:
   - Open `url` at the viewport in `agent.viewport`
   - Verify every item in `checks`
   - Record pass/fail and optional screenshot path
4. **Write a receipt** — `artifacts/scenario-receipt.json` with one row
   per scenario id.

The GitHub Actions workflow **Scenario catalog** (on pull requests) runs
steps 2 and uploads `scenario-catalog.json` as an artifact. Wire your
cloud agent runner to download that artifact and execute step 3 against
a workspace where the prototype is already running.

## Adding a scenario

1. Add or update the row in `docs/scenario-matrix.md`.
2. If it is prototype-reviewable, add a fixture to
   `scripts/scenario-fixtures.mjs` with `params`, `checks`, and `agent`.
3. Run `npm test` — `test-scenario-catalog.mjs` fails if a prototype
   fixture references an unknown id or a matrix id has no tier entry.
4. Regenerate the catalog and run the agent against the new URL once.

## Out of scope for prototype agents

These matrix scenarios stay on **guest** or **unit** tier only:

- Real prerequisite installs (`PRE-*` except wording checked in unit tests)
- Browser sign-in and tenant loading (`AUTH-*`, `APP-*` runtime)
- `eai init` timing and CLI output (`INIT-*` except screen state)
- Harness install poll detecting a real newly installed app (`HARNESS-04`)
- Release gate (`RELEASE-01`)

The prototype README lists the same boundary; the catalog makes it
explicit per scenario id so agents do not false-pass by stubbing.
