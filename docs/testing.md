# Testing and Release Gates

## Local checks

`npm test` validates the manifest, checks that the fallback scripts contain the
required safety controls, and confirms the public source references are not
private platform endpoints. It does not perform a live tenant mutation.

The full desktop interaction traceability list is in
[`docs/scenario-matrix.md`](./scenario-matrix.md). It covers the user choices
at every wizard stage, including existing versus new apps, folder picker
cancel/selection, prerequisite failures, duplicate clicks, and Windows npm
launcher failures. Deterministic behavior is checked locally; native bundle
and guest-machine behavior is checked by the platform workflows below.

The bootstrap contract tests also verify that Homebrew is optional on macOS,
that missing Git uses Apple's Command Line Tools rather than full Xcode, and
that a missing Software Update listing triggers Apple's native catalog refresh
before the setup reports a recoverable error.
that missing Node.js uses the official signed Node.js LTS package over HTTPS.
The desktop path must not open Terminal: it uses native macOS administrator
dialogs and reports progress back to the EAI Setup window. The clean-machine
matrix must include macOS Apple Silicon and Intel hosts without Homebrew so the
minimal Git, Node.js/npm, and CLI handoff are exercised together.

## CI checks

- JSON and JavaScript syntax validation
- Static secret and private-host hygiene checks
- Rust `cargo check` for the Tauri application
- GitHub's repository-level default CodeQL analysis for Rust and JavaScript
- Dependency review on pull requests

## Release checks

A release is incomplete until all of the following are true:

1. The native architecture bundles build on Windows, macOS, and Linux.
2. Windows and macOS artifacts are signed and, where applicable, notarized.
3. Tauri updater artifacts are enabled only after signed update keys and their
   public verification key are added to the application configuration.
4. A clean machine test installs Git, Node/npm, and the CLI, then runs the
   browser login and project handoff without storing a credential.
5. A smoke project confirms `eai init` fetched the supported Gofer/template
   assets and that the generated repository is usable.
6. The exact published assets pass the three-machine release gate and every
   test app has a verified cleanup receipt.

The clean-machine test belongs in a controlled release environment. It should
use a test tenant and test user, not production credentials. The release guest
launches the published desktop application in a protected E2E mode. That mode
uses a pre-authenticated test snapshot, runs the same prerequisite and project
bootstrap commands as the visible wizard, and writes a bounded receipt. It is
not allowed to pass merely because an older `eai` command already exists on the
guest.

The Windows NSIS bundle uses the current-user install mode. This keeps the EAI
Setup application in the user's profile and avoids an administrator prompt for
the installer itself. EAI Setup may still ask for permission when the user
chooses to install system-managed Git or Node.js prerequisites; that request is
separate and is shown by the setup window as an explicit action.

On Windows, EAI Setup does not rely on the CLI to launch a nested `npm.cmd`
process. It calls `eai init --no-install` to create the scaffold, then invokes
npm through the resolved Node runtime when the npm entry point is available,
with a shell-shim fallback. This keeps the setup flow independent of the
user's PowerShell execution policy or PATH and preserves the real npm
diagnostic if dependency installation fails. A direct `eai init` remains a
separate CLI workflow.

The production release controller is run by release.sh publish. It cannot
declare a release healthy from simulated installer files, simulated tenant
records, or a synthetic cleanup receipt. The live gate fails closed before
downloading assets or creating an app unless the protected VM commands,
test-tenant ID, and approved V4 app-deprovision adapter are configured.

release.sh diagnostic-e2e <version> is available for installer debugging. It
uses the real published assets and real guest workflow, but deliberately does
not delete the test app. It reports passed_with_mock_cleanup and must not be
used to approve or publish a release. A guest timeout or a pre-existing CLI is
not a pass; the receipt must show the desktop bootstrap path completed.

release.sh publish-diagnostic <version> can publish a tagged release while
using that same diagnostic gate. It is an explicit exception for the period
before V4 app deletion is available; it leaves test apps behind and must not
be described as clean-release evidence.

`npm test` checks this contract. The live release gate must be run from a
protected release environment with real GitHub release assets, real clean
machines, real EAI authentication, and real tenant cleanup. It is intentionally
not a GitHub-hosted unit test because it needs interactive operating-system
installers, browser sign-in, and a tenant-admin cleanup action.

## Test installer downloads

The `Test installer bundles` workflow produces three unsigned, short-lived
GitHub Actions artifacts for the current branch or pull request:

- Windows x64 and ARM64 NSIS `.exe`
- macOS Apple Silicon and Intel `.dmg`
- Ubuntu x64 and ARM64 `.deb`

Each native runner builds its bundle and performs an installation/package smoke
test. Ubuntu validates that the selected `.deb` contains the executable before
installing it, so a control-only package cannot be published. The macOS job also copies the app to a disposable staging directory,
re-signs that copy ad hoc, removes its quarantine attribute, and launches the
embedded executable. This proves that the unsigned development bundle runs;
it is deliberately not a Gatekeeper trust test. A final Ubuntu job downloads
all three artifacts again, checks that each file is non-empty, and records
SHA-256 hashes. These are test artifacts, not production releases; users will
see the operating system's unsigned-download warning until release signing is
configured.

The public macOS release gate is different: it must verify the actual
Developer ID signature, notarization, and stapled ticket on the release app or
DMG. An ad-hoc re-sign is never suitable for a customer download.

To run the development check manually on a Mac after mounting a test DMG:

```bash
scripts/test-macos-dev.sh "/Volumes/EAI Setup/EAI Setup.app"
```

The script makes a disposable copy, so it does not alter the mounted image or
the original app. It does not weaken Gatekeeper for normal applications.

Development builds declare Tauri's `signingIdentity` as `-`, which creates a
valid ad-hoc bundle signature. The release workflow overrides that identity
with the organisation's Developer ID credentials and requires Apple
notarization credentials before it can publish a macOS asset. It then runs
`codesign`, `spctl`, and `xcrun stapler validate` against the exact release
bundle.

GitHub Actions artifacts are intentionally ZIP-wrapped by GitHub. They are
useful for CI evidence, but are not the end-user download experience. To create
direct native test downloads, run the manual `Publish test installer release`
workflow with a unique version such as `0.1.0-pr9`. It publishes a prerelease
with these stable asset names:

- `eai-setup-macos-arm64.dmg`
- `eai-setup-macos-x64.dmg`
- `eai-setup-windows-x64.exe`
- `eai-setup-windows-arm64.exe`
- `eai-setup-ubuntu-amd64.deb`
- `eai-setup-ubuntu-arm64.deb`

Production releases use the same stable asset names, so public documentation
can use GitHub's `/releases/latest/download/<asset-name>` links without
exposing a temporary Actions artifact URL.
