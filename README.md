# EAI Setup

EAI Setup is the single, signed desktop entry point for the EAI developer
workflow. It prepares a new Windows, macOS, or supported Linux computer, then
hands control to the normal EAI CLI flow.

## What one download does

1. Detects the operating system, CPU architecture, and installed tools.
2. Installs missing Git and Node.js using the platform's package manager or a
   clear, user-approved fallback.
3. Installs or updates the canonical `@enterpriseai/cli` npm package, whose
   command is `eai` and whose source repository is public at
   `eai-tools/eai-cli`.
4. Opens the normal browser sign-in flow with `eai login`.
5. Lets the user confirm their tenant and choose an existing folder or a new
   project folder.
6. Runs `eai init`, which fetches the supported Gofer assets and EAI app
   template through the existing CLI contract.
7. Verifies the project and shows the next action for the user's selected AI
   or editor host.

The installer does not copy private platform code, embed a tenant secret, or
silently install a commercial AI product. A public download is intentional;
EAI access remains controlled by browser authentication, tenant membership,
application policy, and the platform's own authorization checks.

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
EAI_SETUP_AUTO_INSTALL=1 ./scripts/bootstrap.sh
./scripts/bootstrap.sh --project my-app --directory "$HOME/Code/my-app"
```

On Windows, run PowerShell as the signed installer or use:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\bootstrap.ps1 -ProjectName my-app -Directory "$HOME\Code\my-app"
```

The GUI never accepts arbitrary shell commands. It invokes only the fixed
commands represented by `BootstrapStep` in `src-tauri/src/main.rs`.

## Design documents

- [Architecture and product boundary](docs/architecture.md)
- [Installer contract](docs/installer-contract.md)
- [Testing and release gates](docs/testing.md)
- [Security policy](SECURITY.md)
