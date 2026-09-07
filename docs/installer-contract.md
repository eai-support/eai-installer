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
- If Node.js 24 is missing on macOS, EAI Setup first discovers valid user-managed
  installations such as NVM, including when the app was opened from Finder. If
  no usable runtime is found, it downloads the official Node.js 24 LTS archive
  over HTTPS, verifies its checksum, and installs it for the current user
  without a second administrator prompt. A signed package is the fallback when
  the official archive is unavailable.
- On Windows, prerequisite detection runs the real `git`, `node`, `npm`, and
  `eai` version commands. It searches the normal system and user npm locations,
  upgrades Node.js through WinGet when the installed runtime is older than
  Node.js 24, installs the CLI into a user-writable prefix when needed,
  verifies the command after npm finishes, and hides package-manager consoles
  behind the setup window.
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
  json --contract-version v2`. Detection reads installed command and
  application metadata only. Explicit negotiation lets the EAI CLI keep its
  v1 default for compatibility with EAI Setup 0.3.19 during the rollout.
- The first use asks the user which ready AI workspace to use. Later uses may
  preselect the last workspace that opened successfully, while still allowing
  the user to switch.
- The GitHub Copilot app, GitHub Copilot CLI, and GitHub Copilot in VS Code are
  separate choices. The app requires the user to sign in and connect the local
  project; the CLI is the terminal/headless installation option but still
  requires first-use GitHub sign-in; VS Code requires the Copilot extension.
- Google Antigravity 2.0 desktop and Antigravity CLI (`agy`) are separate choices
  and separate installation checks. Google Gemini desktop/CLI is not used as a
  substitute. Antigravity 2.0 desktop requires manual project-folder selection;
  `agy` opens as a bare interactive session in the generated project folder,
  where the user enters the prepared EAI request after startup.
- Claude Desktop/Claude Code and ChatGPT desktop/Codex CLI remain separate
  choices. Their current official desktop and CLI installation pages are used,
  and Linux desktop package launchers are detected where the vendors publish
  them.
- Grok Build (`grok`) is the xAI local-project CLI. Grok Bot is the current xAI
  desktop client for macOS, Windows, and Linux, but it is launch-only because
  xAI documents it as a thin client for cloud Bot chat, review, and approvals
  rather than a local-project Grok Build desktop wrapper. EAI detects native
  app and package-manager installations; a portable Linux AppImage must be
  registered with the app launcher or exposed through a stable executable path.
- These records use `eai.ai-surfaces/v2`. Setup rejects older or unknown
  catalog contracts instead of guessing how a new launch mode behaves. The
  v2 capability list is preserved through the native adapter so launch plans
  can require a command such as `copilot app` or `codex app` before using it.
- CLI detection validates the provider's own `--version` identity instead of
  accepting an unrelated executable with the same short name. Optional launch
  features are then checked from command help; a valid older CLI remains
  available but falls back to the provider's supported manual flow.
- GitHub Copilot in VS Code is the default recommendation when no supported
  workspace is installed. Antigravity, Claude, Codex, Grok Build, and Grok Bot
  remain explicit choices.
- The recommendation score is shown as a four-quarter Harvey ball. It scores
  automatic project opening, automatic delivery of the EAI first request,
  repository-owned EAI/Gofer instruction support, and an integrated visual
  project/chat workspace. It does not score model intelligence, price,
  security, or provider quality. Installation status remains a separate label.
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

### Official AI workspace sources

The catalog uses rolling vendor-owned pages instead of pinning transient asset
URLs. Desktop and CLI products are always separate detection records.

| Surface | Catalog ID | Official Get page | Handoff |
| --- | --- | --- | --- |
| Google Antigravity 2.0 | `antigravity-desktop` | <https://antigravity.google/download> | Open app; add the project folder manually |
| Antigravity CLI | `antigravity-cli` | <https://antigravity.google/docs/cli/install/> | Open bare `agy` interactively in the project; enter the prepared request after startup |
| GitHub Copilot app | `copilot-desktop` | <https://docs.github.com/en/copilot/get-started/quickstart-copilot-app> | `copilot app` in the project when Copilot CLI is ready; otherwise open the app |
| GitHub Copilot CLI | `copilot-cli` | <https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli> | `copilot -C <project> -i <request>` |
| Claude Desktop | `claude-desktop` | <https://claude.com/download> | Official `claude://code/new` project deep link when registered |
| Claude Code | `claude-cli` | <https://code.claude.com/docs/en/setup> | `claude <request>` when help advertises an initial prompt; otherwise `claude` in the project |
| ChatGPT desktop (Codex) | `codex-desktop` | <https://learn.chatgpt.com/docs/app> | `codex app <project>` when Codex CLI is also ready; otherwise open the app |
| Codex CLI | `codex-cli` | <https://learn.chatgpt.com/docs/codex/cli> | `codex <request>` in the project |
| Grok Bot | `grok-bot` | <https://docs.x.ai/grok-bot/get-started> | Open the macOS, Windows, or Linux app only; no local-project contract |
| Grok Build | `grok-cli` | <https://x.ai/build> | `grok --cwd <project> <request>` when current help advertises the positional interactive prompt; otherwise open Grok Build in the project |

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
