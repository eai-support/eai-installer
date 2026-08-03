# EAI Setup

EAI Setup is the single, signed desktop entry point for the EAI developer
workflow. It prepares a new Windows, macOS, or supported Linux computer, then
hands control to the normal EAI CLI flow.

## What one download does

1. Detects the operating system, CPU architecture, and installed tools.
2. On macOS, offers to install Homebrew from the official HTTPS installer when
   it is missing. The user must choose this step and approve any administrator
   prompt.
3. Installs missing Git and Node.js using the platform's package manager or a
   clear, user-approved fallback.
4. Installs or updates the canonical `@enterpriseai/cli` npm package, whose
   command is `eai` and whose source repository is public at
   `eai-support/eai-cli`.
5. Opens the normal browser sign-in flow with `eai login`.
6. Lets the user confirm their tenant and choose an existing folder or a new
   project folder.
7. Runs `eai init`, which fetches the supported Gofer assets and EAI app
   template through the existing CLI contract.
8. Verifies the project and shows the next action for the user's selected AI
   or editor host.

The installer does not copy private platform code, embed a tenant secret, or
silently install a commercial AI product. A public download is intentional;
EAI access remains controlled by browser authentication, tenant membership,
application policy, and the platform's own authorization checks.

GitHub's default CodeQL setup scans this public repository; a second advanced
CodeQL workflow is intentionally not included because GitHub does not accept
both scanning modes at once.

## Support target

- Windows 10 and 11, x64 and arm64 where the prerequisite installers support it
- Recent supported macOS releases on Apple Silicon and Intel
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
public release channel.

## Design documents

- [Architecture and product boundary](docs/architecture.md)
- [Installer contract](docs/installer-contract.md)
- [Testing and release gates](docs/testing.md)
- [Security policy](SECURITY.md)
