# EAI Setup

EAI Setup is the single, signed desktop entry point for the EAI developer
workflow. It prepares a new Windows, macOS, or supported Linux computer, then
hands control to the normal EAI CLI flow.

## What one download does

1. Detects the operating system, CPU architecture, and installed tools.
2. Installs only the minimal missing developer tools. On macOS, Git uses
   Apple's Command Line Tools (not full Xcode), and Node.js uses an existing
   NVM/Homebrew installation when available or the official checksum-verified
   Node.js LTS archive in a user-local directory. Homebrew is optional rather than an EAI
   prerequisite, so an old Homebrew installation cannot block setup.
3. Uses native permission prompts where required. Windows, macOS, and Linux
   keep the progress status in the EAI Setup window rather than exposing a
   terminal.
4. Installs or updates the canonical `@enterpriseai/cli` npm package, whose
   command is `eai` and whose source repository is public at
   `eai-support/eai-cli`.
5. Opens the normal browser sign-in flow with `eai login`. New users can choose
   **Create an EAI account** to open the public developer signup page, then
   return to the installer and sign in.
6. Lets the user choose an existing folder or a new project folder. Tenant
   selection remains part of the normal EAI CLI prompts, where the platform can
   show only tenants the signed-in user may access.
7. Runs `eai init --no-install`, which fetches the supported Gofer assets and
   EAI app template through the existing CLI contract, then installs the
   generated app dependencies from the setup process itself. This avoids a
   second Windows shell launcher inside the CLI.
8. Detects supported AI workspaces without reading provider accounts or project
   files. It remembers the last successfully opened workspace and recommends
   GitHub Copilot in VS Code when the user needs to choose one.
9. After one clear provider-access confirmation, opens the project in GitHub
   Copilot, Claude, Codex, or Grok with an EAI first request prepared where the
   provider supports it. If a workspace is missing, the installer can open only
   that provider's fixed official installation page.

## Download the installer

The public release channel serves native installers directly from GitHub
Releases. The links download the file itself, not a GitHub Actions artifact
ZIP:

- [macOS Apple Silicon DMG](https://github.com/eai-support/eai-installer/releases/latest/download/eai-setup-macos-arm64.dmg)
- [macOS Intel DMG](https://github.com/eai-support/eai-installer/releases/latest/download/eai-setup-macos-x64.dmg)
- [Windows x64 installer](https://github.com/eai-support/eai-installer/releases/latest/download/eai-setup-windows-x64.exe)
- [Windows ARM64 installer](https://github.com/eai-support/eai-installer/releases/latest/download/eai-setup-windows-arm64.exe)
- [Ubuntu/Debian x64 package](https://github.com/eai-support/eai-installer/releases/latest/download/eai-setup-ubuntu-amd64.deb)
- [Ubuntu/Debian ARM64 package](https://github.com/eai-support/eai-installer/releases/latest/download/eai-setup-ubuntu-arm64.deb)

Choose the Ubuntu/Debian package that matches the computer's architecture. The
ARM64 package is intended for ARM64 Linux machines such as Apple Silicon VMs;
the x64 package is for Intel/AMD Linux machines.

On macOS, open the downloaded DMG and drag **EAI Setup** to **Applications**.
The first launch may show the normal macOS security confirmation. Production
release assets are signed and notarized when the release signing environment is
configured.

The installer does not copy private platform code, embed a tenant secret, or
silently install a commercial AI product or accept provider credentials. A
public download is intentional;
EAI access remains controlled by browser authentication, tenant membership,
application policy, and the platform's own authorization checks.

GitHub's default CodeQL setup scans this public repository; a second advanced
CodeQL workflow is intentionally not included because GitHub does not accept
both scanning modes at once.

## Support target

- Windows 10 and 11, x64 and arm64 where the prerequisite installers support it
- macOS 15 and newer on Apple Silicon and Intel; both native DMG architectures
- Ubuntu/Debian Linux initially, with other distributions added by explicit
  adapters rather than unsafe shell guessing

The first implementation contains the provider-neutral contract, Tauri source,
Windows/macOS/Linux bootstrap adapters, validation, and CI. Signed installers
are produced only by the release workflow after the organisation configures
Apple, Windows, and Tauri signing credentials in GitHub Actions. No signing
private key belongs in this repository. The updater is deliberately disabled
until its public key is configured in the release environment.

## Development

```bash
npm test
node scripts/verify-manifest.mjs
```

## Versioning and releases

EAI Setup uses semantic versions in `MAJOR.MINOR.PATCH` form:

- **Major**: breaking installer or user workflow changes.
- **Minor**: backwards-compatible features.
- **Patch**: backwards-compatible fixes.

The version must match in `package.json`, `src-tauri/Cargo.toml`, and
`src-tauri/tauri.conf.json`. Production releases use the matching Git tag
`vMAJOR.MINOR.PATCH`; test releases use `eai-setup-test-vMAJOR.MINOR.PATCH`.
Release checks reject other formats or mismatched version sources.

For the shell fallback:

```bash
EAI_SETUP_AUTO_INSTALL=1 ./scripts/bootstrap.sh --install-homebrew
./scripts/bootstrap.sh --project my-app --directory "$HOME/Code/my-app"
```

On Windows, run PowerShell as the signed installer or use:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\bootstrap.ps1 -ProjectName my-app -Directory "$HOME\Code\my-app"
```

The GUI never accepts arbitrary shell commands. It invokes only the fixed
commands represented by `BootstrapStep` in `src-tauri/src/main.rs`.

Test installers are built by the `Test installer bundles` GitHub Actions
workflow. It publishes temporary Windows `.exe`, macOS `.dmg`, and Ubuntu
`.deb` artifacts and smoke-tests each native package before checking the
downloaded files together. These artifacts are unsigned test files, not the
public release channel. Maintainers can use the manual `Publish test installer
release` workflow when a direct, native test download is needed.

## Design documents

- [Architecture and product boundary](docs/architecture.md)
- [Installer contract](docs/installer-contract.md)
- [Testing and release gates](docs/testing.md)
- [Releasing and semantic versioning](docs/releasing.md)
- [Release end-to-end gate](docs/release-e2e.md)
- [Security policy](SECURITY.md)
