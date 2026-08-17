# Signing and Distribution Setup

This repository separates three concerns:

1. The application bundle must be signed by the platform publisher.
2. macOS releases must also be notarized and stapled.
3. The GitHub release must remain a draft until the published-asset VM gate
   has passed.

The production workflow uses the protected GitHub `release` environment. The
environment currently has no signing secrets, so production releases are
intentionally blocked until the account owners complete the setup below.
Do not put any certificate, password, private key, or token in git.

## Apple distribution

For a direct DMG download, use an Apple **Developer ID Application**
certificate. An Apple Distribution certificate is for App Store submission and
is not the correct identity for this direct-download channel.

Create or obtain the certificate in the Apple Developer account, export it as
a password-protected `.p12`, and configure these secrets in the GitHub
`release` environment:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64 contents of the Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used for the `.p12` export |
| `APPLE_SIGNING_IDENTITY` | Exact `Developer ID Application: ...` identity name |
| `APPLE_API_ISSUER` | App Store Connect API issuer ID |
| `APPLE_API_KEY` | App Store Connect API key ID, for example `ABC123DEFG` |
| `APPLE_API_PRIVATE_KEY` | Raw contents of the matching `AuthKey_*.p8` file |

The App Store Connect API key is the preferred notarization path. The
workflow also accepts the older Apple ID path using `APPLE_ID`,
`APPLE_PASSWORD` (an app-specific password), and `APPLE_TEAM_ID` instead of
the three API-key secrets.

On macOS, the certificate value can be uploaded without putting it in shell
history:

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | \
  gh secret set APPLE_CERTIFICATE --repo eai-support/eai-installer --env release
gh secret set APPLE_CERTIFICATE_PASSWORD --repo eai-support/eai-installer --env release
gh secret set APPLE_SIGNING_IDENTITY --repo eai-support/eai-installer --env release
gh secret set APPLE_API_ISSUER --repo eai-support/eai-installer --env release
gh secret set APPLE_API_KEY --repo eai-support/eai-installer --env release
gh secret set APPLE_API_PRIVATE_KEY --repo eai-support/eai-installer --env release < AuthKey_ABC123DEFG.p8
```

The production workflow verifies the app with `codesign` and `spctl`, then
validates the stapled ticket with `xcrun stapler validate`. A notarized DMG is
the requirement for removing the macOS malware warning for ordinary customer
downloads. A first-download confirmation can still be shown by macOS as a
normal internet-download consent step.

## Windows distribution

The immediate workflow path uses a password-protected PFX code-signing
certificate:

| Secret | Value |
| --- | --- |
| `WINDOWS_CERTIFICATE` | Base64 contents of the PFX certificate |
| `WINDOWS_CERTIFICATE_PASSWORD` | Password used for the PFX |

The certificate must identify the legal publishing entity and be valid for
code signing. The workflow now runs `Get-AuthenticodeSignature` against the
actual NSIS installer and fails if Windows does not report a valid signature.

For the long-term enterprise setup, Microsoft Artifact Signing (formerly
Trusted Signing) is preferred because it integrates with CI through Azure
identity rather than storing a long-lived PFX. That path requires an Azure
Artifact Signing account, verified publisher identity, and a GitHub Actions
OIDC trust configuration. It is a separate workflow change; do not upload a
placeholder PFX. Even with a valid signature, Microsoft states that SmartScreen
reputation builds over time for a new publisher, so no responsible release
process can promise zero SmartScreen prompts on the first downloads. Microsoft
Store distribution is the strongest route when zero SmartScreen download
warnings are a hard requirement.

## Linux distribution

The current channel distributes `.deb` files directly from GitHub Releases.
The workflow validates the package structure and publishes it only as part of
the gated release process. Direct `.deb` downloads do not use an apt
repository trust chain; customers should install from the official release
URL. If EAI later offers an apt repository, its repository metadata must be
GPG-signed separately.

The Tauri updater is currently disabled, so `TAURI_SIGNING_PRIVATE_KEY` is not
needed for this release channel. It must be added only when signed updater
artifacts are deliberately enabled.

## GitHub Actions and release protection

The workflows use the current Node 24-compatible action majors:

- `actions/checkout@v6`
- `actions/setup-node@v6`
- `actions/upload-artifact@v6`
- `actions/download-artifact@v5`
- `tauri-apps/tauri-action@v1`

The release job uses minimal `contents: write` permission and the protected
`release` environment. Configure required reviewers for that environment in
GitHub before adding production secrets. A reviewer should confirm the
release PR, the exact version, and the guest E2E evidence before approving
access to the signing secrets.

The release sequence is:

```text
merge release PR
  -> tag the exact merged commit
  -> build signed assets into a draft GitHub release
  -> download those exact assets and run the real Mac/Windows/Ubuntu gate
  -> publish the draft only after the gate and cleanup receipt pass
```

Unsigned test releases remain explicitly marked as prereleases and are never
promoted to the public `latest` channel.

## External setup still required

The repository can enforce the rules, but it cannot create or recover the
following account-owned material:

- Apple Developer account access and Developer ID Application certificate
- App Store Connect API key or Apple notarization credentials
- Windows PFX certificate, or an Azure Artifact Signing account and verified
  publisher identity
- GitHub environment reviewers for `release`

Once those are available, add only the secret names listed above and rerun the
release workflow. The workflow will report the exact missing item if setup is
incomplete; it will not publish an unsigned customer installer.

## Official references

- [Tauri macOS signing and notarization](https://v2.tauri.app/distribute/sign/macos/)
- [Tauri distribution overview](https://v2.tauri.app/distribute/)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Microsoft SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)
- [Microsoft Artifact Signing](https://learn.microsoft.com/en-us/azure/trusted-signing/)
- [GitHub Actions environments and deployment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [GitHub Actions secrets](https://docs.github.com/en/actions/concepts/security/secrets)
