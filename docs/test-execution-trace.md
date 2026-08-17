# Installer Test Execution Trace

This is the evidence map for Enterprise AI Setup. A check is only described as
end to end when it runs the published installer inside a clean guest, signs in,
selects a company workspace, creates or selects an app, creates the local
project, opens an AI workspace, and verifies cleanup.

## 1. Source and behaviour checks

Run with `npm test` on every pull request and release build.

| Order | Test | What it proves | Boundary |
| --- | --- | --- | --- |
| 1 | `verify-version.mjs` | Package, Rust, and Tauri versions agree and use major.minor.patch. | Does not build an installer. |
| 2 | `verify-manifest.mjs` | Public installer metadata is complete and contains no private platform addresses. | Does not contact external services. |
| 3 | `test-bootstrap.mjs` | Required commands, fixed package identifiers, safe launch rules, platform paths, folder handling, and release controls are wired into the desktop source. | Structural contract; it does not execute WinGet, Apple installers, or EAI APIs. |
| 4 | `test-wizard.mjs` | Project-name validation, prerequisite readiness, AI workspace choice, error cleanup, Windows dependency guidance, and workspace failure classification behave deterministically. | Runs the browser-neutral state model, not the native window. |
| 5 | `test-scenarios.mjs` | Every scenario ID in the user journey has a documented expected outcome. | Traceability check; scenario presence alone is not runtime proof. |
| 6 | `test-release.mjs` | Release commands fail closed without real VM adapters, real test identity details, and verified V4 cleanup. | Does not run the VMs during normal pull-request CI. |
| 7 | Rust unit tests | WinGet “already current” is accepted only when Node/npm actually run; transient platform failures retry; access denials do not retry; direct active child workspaces parse without eager app calls. | Native command execution is simulated through pure decision inputs. |

## 2. Native build and package checks

The `Test installer bundles` workflow runs for every pull request.

| Platform | Architectures | Checks performed |
| --- | --- | --- |
| Windows 10/11 family | x64, ARM64 | Build NSIS installer, run silent current-user installation, and confirm an installed executable exists. |
| macOS | Apple Silicon, Intel | Build DMG, validate the image, mount it, find the app executable, copy and ad-hoc sign a disposable development app, then launch it. |
| Ubuntu | x64, ARM64 | Build DEB, confirm it contains `/usr/bin/eai-setup`, install it, verify package state and executable, then uninstall it. |
| Download verification | All six files | Download the workflow artifacts again, require all architectures, validate package structure, and record SHA-256 hashes. |

These checks prove that installers are buildable, downloadable, installable,
and launchable. They do not prove the visible wizard can install missing tools,
sign in, or create an app.

## 3. Published clean-machine journey

The release controller downloads the exact GitHub release assets and requires
one protected clean guest for macOS, Windows, and Ubuntu. Each guest must record
the following checks as passed:

| Order | Receipt check | Required evidence |
| --- | --- | --- |
| 1 | Download | The release asset was downloaded inside the named guest and its hash was recorded. |
| 2 | Installer | The native installer installed and opened Enterprise AI Setup. |
| 3 | Prerequisites | Git, Node.js, npm, and the compatible EAI CLI were detected or installed by the desktop bootstrap path. |
| 4 | Authentication | Browser sign-in completed using the protected test user. |
| 5 | Tenant | The approved test company workspace was visible and selected. |
| 6 | App | A unique test app was created or the intended existing app was selected. |
| 7 | Project | The generated folder, manifest, dependencies, Gofer assets, and app template were verified. |
| 8 | AI handoff | `eai start` detected the available AI workspaces and opened the selected workspace with the generated project. |
| 9 | Cleanup | The V4 cleanup adapter deleted every test-created platform and local artifact and returned a verified receipt. |

## 4. Release decision

- Pull-request green means source behaviour, compilation, six native packages,
  installation, and launch checks passed.
- Release green means the exact published files also passed all nine clean-guest
  stages on macOS, Windows, and Ubuntu, including verified cleanup.
- A diagnostic run without real cleanup is useful engineering evidence but is
  not a releasable end-to-end pass.

The Windows no-upgrade and macOS workspace failures reported in August 2026
escaped because the package jobs stopped after installation and launch. The
new behavioural tests cover both decisions, while the release trace now makes
the remaining clean-guest obligation explicit.
