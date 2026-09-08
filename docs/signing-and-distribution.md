# Signing and Distribution Setup

This repository separates three concerns:

1. The application bundle must be signed by the platform publisher.
2. macOS releases must also be notarized and stapled.
3. The GitHub release must remain a draft until the published-asset VM gate
   has passed.

The production workflow uses the GitHub `release` environment. Windows and
Linux signing are configured; macOS remains explicitly unsigned until the
Apple credentials and GitHub environment/tag protections described below are
configured.
Do not put any certificate, password, private key, or token in git.

## Platform signing matrix

Signing is evaluated per platform in the production workflow; one platform's
missing capability must never be used as a reason to remove signing from a
different platform. The current contract is:

| Artifact | Signing status | Verification |
| --- | --- | --- |
| Windows `.exe` | Required when published; Microsoft Artifact Signing | `Get-AuthenticodeSignature`, Code Signing EKU, and RFC3161 timestamp |
| macOS `.dmg` | Required when published; Apple Developer ID plus notarization | `codesign`, `spctl`, and stapled-ticket validation |
| Ubuntu `.deb` | Detached GPG signature, with the public release key shipped alongside the package | `gpg --verify` against the protected release key |

The Windows and macOS jobs are separate signing jobs and fail closed if their
protected credentials are incomplete. They do not fall back to publishing an
unsigned customer artifact. Linux package signing is a different mechanism
from Microsoft Authenticode. The direct GitHub Release channel publishes each
`.deb`, its detached `.asc` signature, and `eai-linux-signing-key.asc`. An apt
repository would instead require separately managed GPG-signed `InRelease`
metadata; that is not the current distribution channel.

The diagnostic `test-release.yml` workflow is intentionally unsigned on all
platforms. Its prereleases must not be described as signed or production
approved; use the production workflow for signed customer installers.

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

When the Apple credentials are configured, the production workflow verifies
the app with `codesign` and `spctl`, then validates the stapled ticket with
`xcrun stapler validate`. Until then, the protected release variable
`ALLOW_UNSIGNED_MACOS_RELEASE=true` permits an explicitly labelled unsigned
macOS asset; it must not be described as Gatekeeper-ready. A notarized DMG is
the requirement for removing the macOS malware warning for ordinary customer
downloads.

## Windows distribution

The production workflow uses Microsoft Artifact Signing (formerly Trusted
Signing) with GitHub Actions OIDC. Configure these variables in the protected
GitHub `release` environment:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Client ID of the federated release identity |
| `AZURE_TENANT_ID` | Microsoft Entra tenant containing that identity |
| `AZURE_SUBSCRIPTION_ID` | Subscription containing the signing account |
| `AZURE_SIGNING_RESOURCE_GROUP` | Exact resource group containing `eai-installer-signing` |
| `AZURE_SIGNING_SUBJECT` | Exact certificate subject expected on the staged installer |

The federated identity must be authorized for signing account
`eai-installer-signing` and certificate profile `eai-installer-windows` at the
configured northern-Europe endpoint. No PFX or long-lived Windows signing
secret belongs in GitHub. The protected readiness job also needs read-only
Azure control-plane access at the signing-account scope so it can inspect the
account, profile, identity-validation reference, and its own inherited role
assignment. Assign `Reader` at the signing-account scope in addition to a
**direct assignment to the workload identity** (not only to one of its groups)
of `Artifact Signing Certificate Profile Signer` at the profile or a parent
scope. The readiness check binds that role by its stable definition ID and
allows inherited scope, but deliberately does not resolve group membership.
Do not give the release identity Contributor, Owner, or role-assignment write
access.

Windows is intentionally built by a Tauri action invocation that has no
`GITHUB_TOKEN`, tag, release name, or release-body inputs. It therefore cannot
upload the unsigned NSIS output. The workflow then applies Artifact Signing,
requires `Get-AuthenticodeSignature` to report `Valid`, copies that verified
file to the stable platform asset name, and only then uploads that exact file to
private Actions artifact storage. Do not add release metadata to the Tauri build
step or move artifact upload above signature verification.

Even with a valid signature, Microsoft states that SmartScreen reputation
builds over time for a new publisher, so no responsible release process can
promise zero SmartScreen prompts on the first downloads. Microsoft Store
distribution is the strongest route when zero SmartScreen download warnings
are a hard requirement.

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

The platform matrices produce six isolated release outputs. Windows compilation
and tests run first in two unprotected, no-OIDC build legs; two separate
protected signing-only legs download those exact private artifacts and alone
receive `id-token: write`. Apple signing legs use the protected `release`
environment; Linux receives neither its credentials nor OIDC permission. Each
release leg signs where applicable, verifies version and architecture, renames,
and uploads one exact
stable-named file to Actions artifact storage. Only the dependent
`publish-draft` job receives `contents: write`; it downloads the matrix outputs,
requires the exact six-name/non-empty set, records local SHA-256 hashes, and
requires an already-existing immutable tag that resolves to the workflow commit
before it creates/uploads the draft once. It then compares the remote name set
and downloaded hashes with the staged set. A manual workflow dispatch cannot
create a missing release tag. Configure required reviewers for the protected
`release` environment before adding production secrets.

Before `release.sh publish` creates a tag, it dispatches
`release-readiness.yml` on `main` with a unique non-secret correlation value and
waits for that exact run. The readiness workflow has `contents: read` and
cannot tag or publish. Its macOS job imports the protected P12 into a temporary
keychain, requires at least seven days of certificate validity, matches the
exact Developer ID common name and team identifier, validates the code-signing
chain with required OCSP, performs a timestamped signature on an ephemeral
system-binary copy, and authenticates to notarization by reading history. Its
Ubuntu job validates the exact Azure subscription, configured resource group
and account ID, successful account state, North Europe data-plane URI,
supported account SKU, active/successfully provisioned PublicTrust profile,
UUID identity-validation reference, and the workload identity's direct or
inherited-scope `Artifact Signing Certificate Profile Signer` assignment.
Credential sets that are only partially configured fail closed.

This is the strongest pre-tag check available without creating a release or
requesting an Artifact Signing certificate. Azure's Artifact Signing GitHub
action and signing tools run on Windows, and a genuine data-plane probe would
consume a signing request and create signing audit history. The readiness job
therefore does **not** claim that Azure's signing data plane accepted a file;
the post-tag Windows matrix signing plus exact-file Authenticode verification is
the authoritative proof. Likewise, the Apple check proves the certificate,
private key, timestamp service, and notarization authentication separately;
the release matrix's notarization and stapling checks remain authoritative for
the built DMG.

The release sequence is:

```text
merge release PR
  -> run local mutation-free VM/V4 preflight
  -> run protected non-publishing signing readiness
  -> tag the exact merged commit
  -> build/sign/verify six isolated outputs (Windows build and signing separated)
  -> one publisher creates and verifies the six-asset draft
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
- GitHub environment reviewers for `release`
- An active GitHub tag ruleset that restricts creation, update, and deletion of
  production `v*` tags to the release operators

The workflow itself fails closed if a direct or manually dispatched tag has no
recent successful readiness run for the exact version and commit. Repository
settings cannot be added by a pull request, however. The 2026-09-06 settings
audit found no protection rules or deployment-branch policy on the `release`
environment and no repository tag ruleset. Those settings are an external
production-release blocker until an owner configures them. After configuration,
verify them through the GitHub repository settings or API before tagging; do not
treat the workflow provenance check as a substitute for tag-creation control.

As of 2026-09-06, the Azure release variables, exact signing resource/profile,
and direct workload-identity Reader/Signer assignments have been configured and
their expected values match. This is configuration evidence only: the protected
readiness workflow has not yet proved OIDC/control-plane access, and only the
Windows signing job can prove the Artifact Signing data plane against an actual
installer.

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
