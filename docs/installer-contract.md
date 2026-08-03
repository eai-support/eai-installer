# Installer Contract

`installer-manifest.json` is the public, machine-readable contract. It names
only public packages, public repositories, public vendor tools, and user-facing
commands.

## Required guarantees

- Installation is repeatable and safe to rerun.
- Missing prerequisites are detected before the next step is attempted.
- Fixed platform adapters are used; arbitrary user-supplied commands are not
  executed by the desktop app.
- Homebrew installation is an automatic macOS prerequisite only when Homebrew
  is missing, using the official HTTPS installer; macOS may still show its
  normal administrator prompt.
- Linux package installation uses the host's signed package manager through a
  graphical `pkexec` permission prompt when available; the installer never
  captures a password in its own UI.
- The installer never receives an EAI password or secret.
- `eai login` remains browser-based and interactive.
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
