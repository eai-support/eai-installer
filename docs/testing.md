# Testing and Release Gates

## Local checks

`npm test` validates the manifest, checks that the fallback scripts contain the
required safety controls, and confirms the public source references are not
private platform endpoints. It does not perform a live tenant mutation.

The bootstrap contract tests also verify that macOS Homebrew installation is an
explicit step, uses the official HTTPS source, and cannot be triggered by an
arbitrary command or URL. The clean-machine matrix must include a macOS host
without Homebrew so the consent, administrator prompt, PATH refresh, Git,
Node.js/npm, and CLI handoff are exercised together.

## CI checks

- JSON and JavaScript syntax validation
- Static secret and private-host hygiene checks
- Rust `cargo check` for the Tauri application
- GitHub's repository-level default CodeQL analysis for Rust and JavaScript
- Dependency review on pull requests

## Release checks

A release is incomplete until all of the following are true:

1. The three platform bundles build on Windows, macOS, and Linux.
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

- Windows NSIS `.exe`
- macOS `.dmg`
- Ubuntu 22.04 `.deb`

Each native runner builds its bundle and performs an installation/package smoke
test. A final Ubuntu job downloads all three artifacts again, checks that each
file is non-empty, and records SHA-256 hashes. These are test artifacts, not
production releases; users will see the operating system's unsigned-download
warning until release signing is configured.
