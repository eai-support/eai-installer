# Testing and Release Gates

## Local checks

`npm test` validates the manifest, checks that the fallback scripts contain the
required safety controls, and confirms the public source references are not
private platform endpoints. It does not perform a live tenant mutation.

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

The clean-machine test belongs in a controlled release environment. It should
use a test tenant and test user, not production credentials.

## Test installer downloads

The `Test installer bundles` workflow produces three unsigned, short-lived
GitHub Actions artifacts for the current branch or pull request:

- Windows x64 and ARM64 NSIS `.exe`
- macOS Apple Silicon and Intel `.dmg`
- Ubuntu x64 and ARM64 `.deb`

Each native runner builds its bundle and performs an installation/package smoke
test. The macOS job also copies the app to a disposable staging directory,
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
