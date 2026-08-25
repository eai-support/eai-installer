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
- After sign-in, the installer discovers active top-level company workspaces
  through `eai tenant list --format json`. It selects the only workspace
  automatically, or asks the user to choose one when several are available,
  then passes that explicit workspace to `eai init --company-tenant`.
- A project is created only in a user-selected directory, or in an explicit
  new folder derived from a validated kebab-case project name.
- When app creation finishes, the installer shows the exact project folder and
  opens it in Finder, File Explorer, or the Linux file manager. It does not
  ask the user to copy or run an internal bootstrap command.
- Gofer and the app template are fetched by `eai init`, so the CLI's supported
  provenance and compatibility checks remain in charge.
- Supported AI workspaces are detected through `eai start --check --format
  json`. Detection reads installed command and application metadata only.
- The first use asks the user which ready AI workspace to use. Later uses may
  preselect the last workspace that opened successfully, while still allowing
  the user to switch.
- The GitHub Copilot app, GitHub Copilot CLI, and GitHub Copilot in VS Code are
  separate choices. The app requires the user to sign in and connect the local
  project; the CLI is the terminal/headless installation option but still
  requires first-use GitHub sign-in; VS Code requires the Copilot extension.
- GitHub Copilot in VS Code is the default recommendation when no supported
  workspace is installed. Claude, Codex, and Grok remain explicit choices.
- AI workspaces are shown in two named groups: the ones already on this
  computer, and the ones the user has to fetch from their makers. The group a
  workspace is in is the only thing that changes between a machine that has it
  and one that does not, which keeps the two cases comparable.
- The four-quarter Harvey ball has been removed. It scored somebody else's
  product on the screen where the user chooses it, and the score it gave was
  routinely read as a quality rating even though it measured only handoff
  completeness. Installation status and the vendor origin are stated in words
  instead.
- EAI Setup opens a fixed official provider installation page only after the
  user requests it. It does not accept provider credentials, agree to provider
  terms, or silently install commercial software.
- After a provider install, the user can select **Check again**. Starting a
  workspace clearly states the next provider-specific action, including when
  sign-in or local-folder connection is required. The installer stays open
  until the handoff succeeds or fails.
- The prepared first request starts with the business outcome, teaches EAI as
  it becomes relevant, keeps internal stage names hidden, and pauses once for
  approval of the business specification.

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
- `ai-workspace-detection`: the CLI could not produce the supported versioned
  workspace inventory; the completed app remains safe and usable.
- `ai-workspace-handoff`: the chosen provider could not open the project; keep
  setup open and offer another detected workspace or `eai start` recovery.
