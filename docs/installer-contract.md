# Installer Contract

`installer-manifest.json` is the public, machine-readable contract. It names
only public packages, public repositories, public vendor tools, and user-facing
commands.

## Required guarantees

- Installation is repeatable and safe to rerun.
- Missing prerequisites are detected before the next step is attempted.
- Fixed platform adapters are used; arbitrary user-supplied commands are not
  executed by the desktop app.
- Homebrew is optional on macOS and is never required for the EAI workflow.
  When it is already installed, the adapter may use it for package installs;
  missing Homebrew does not block setup.
- If Git is missing on macOS, EAI Setup uses Apple's Command Line Tools native
  installer. Full Xcode is not required. If Apple's Software Update catalog has
  not advertised the package yet, EAI Setup asks macOS to refresh that catalog,
  continues checking, and explains any native Install dialog that needs approval.
- If Node.js is missing on macOS, EAI Setup first discovers valid user-managed
  installations such as NVM, including when the app was opened from Finder. If
  no usable runtime is found, it downloads the official Node.js LTS archive
  over HTTPS, verifies its checksum, and installs it for the current user
  without a second administrator prompt. A signed package is the fallback when
  the official archive is unavailable.
- On Windows, prerequisite detection runs the real `git`, `node`, `npm`, and
  `eai` version commands. It searches the normal system and user npm locations,
  installs the CLI into a user-writable prefix when needed, verifies the command
  after npm finishes, and hides package-manager consoles behind the setup window.
- Installation progress is reported in the EAI Setup window, including the
  current item, phase, and an honest approximate remaining time. Estimates are
  guidance, not a guarantee about network speed or provider availability.
- Linux package installation uses the host's signed package manager through a
  graphical `pkexec` permission prompt when available; the installer never
  captures a password in its own UI.
- The installer never receives an EAI password or secret.
- `eai login` remains browser-based and interactive. The sign-in panel also
  opens the public developer signup page for customers who do not have an EAI
  account yet; the installer never collects or stores signup credentials.
- A project is created only in a user-selected directory, or in an explicit
  new folder derived from a validated kebab-case project name.
- Gofer and the app template are fetched by `eai init`, so the CLI's supported
  provenance and compatibility checks remain in charge.

## Failure categories

- `unsupported-platform`: the operating system or architecture is outside the
  advertised matrix.
- `missing-package-manager`: the supported package manager is absent; show
  official installation guidance.
- `prerequisite-install`: the package manager could not install Git or Node.
- `cli-install`: npm could not install or verify `@enterpriseai/cli`.
- `authentication-required`: the user must complete `eai login` in a browser.
- `project-location`: the selected directory is unavailable or not writable.
- `initialization`: `eai init` returned a failure; preserve its diagnostic and
  do not claim that the app is ready.
