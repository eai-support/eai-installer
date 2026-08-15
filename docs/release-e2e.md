# Release End-to-End Gate

The release gate validates the installer from the public GitHub release page,
not from a local build directory. It is deliberately separate from normal
package CI checks.

## Release commands

Version preparation creates a release PR and never pushes directly to `main`:

```bash
./release.sh patch "Fix clean-machine bootstrap"
./release.sh minor "Add the release VM gate"
./release.sh major "Change the installer contract"
```

After the release PR is merged:

```bash
./release.sh publish 0.2.0
```

`publish` runs the live preflight before creating a tag. It then tags the
merged commit, waits for the signed GitHub release workflow, downloads the
exact release assets, and runs the VM gate. A failed code gate requires a new
patch version. A transient VM failure may rerun the same immutable tag after
the environment is repaired.

When app deletion is intentionally unavailable, use the separate
`publish-diagnostic` command:

```bash
./release.sh publish-diagnostic 0.3.0
```

This publishes the release after the real guest checks are configured, but
uses diagnostic-only cleanup and leaves the created test apps in the harness
tenant. Its E2E evidence is `passed_with_mock_cleanup`, not a clean-release
approval. The normal `publish` command remains real-cleanup-only.

The production release gate has no mock mode. It cannot claim success from
simulated installer files, simulated tenant records, or a synthetic cleanup
receipt.

For installer diagnosis only, run the explicitly labelled diagnostic command:

    ./release.sh diagnostic-e2e 0.3.0

This still downloads the published GitHub assets and runs the real macOS,
Windows, and Ubuntu guest checks. It can create a real test app, but it records
cleanup as not-verified and does not delete anything. A successful result is
reported as passed_with_mock_cleanup; it is evidence that the installer and
guest workflow ran, not evidence that a release is safe to publish. The
publish command always uses the real V4 cleanup adapter and rejects this
diagnostic mode.

## Live VM adapter contract

The controller runs one test for each of `macos`, `windows`, and `ubuntu`. The
only supported adapter is `command`; it fails clearly until a controlled
Parallels or CI runner is configured. Each adapter receives these environment
variables:

- `EAI_RELEASE_VERSION`, `EAI_RELEASE_TAG`, and `EAI_RELEASE_REPO`
- `EAI_VM_ID` and `EAI_VM_ASSET`
- `EAI_VM_DOWNLOAD_URL`, which points to the GitHub release asset
- `EAI_VM_PROJECT_NAME`, a unique kebab-case test app name
- `EAI_VM_RESULT_FILE`, where the adapter must write JSON
- `EAI_VM_APP_STATE_FILE`, where the adapter must write app creation state
- `EAI_HARNESS_TENANT_NAME`
- `EAI_HARNESS_USER_EMAIL`

### What the VM commands mean

The VM commands are release-team adapters, not commands that customers run.
They are protected scripts maintained by the release owner for the three clean
guest machines. The controller starts one command per guest and passes the
published asset, download URL, unique test app name, and receipt paths through
environment variables.

A macOS adapter may reset or start the Parallels macOS guest, download the DMG
inside that guest, run the installer, complete the browser sign-in, create the
test app, and write the JSON receipts back through the shared test folder. The
Windows adapter does the same with PowerShell and the Windows installer. The
Ubuntu adapter does the same with a shell script and the Debian package.

The important boundary is that the work happens inside the guest. A host-side
script that only checks whether a file exists is not a valid VM adapter. In a
CI environment, the same contract can be implemented by an ephemeral Windows,
macOS, or Ubuntu runner instead of Parallels.

The release team owns the machine names, Parallels or runner connection,
browser automation, and protected credentials. These values belong in the
release environment or OS keychain, never in this repository or a public
release asset.

The controller requires an OS-specific command for every guest. Do not use a
shared host command: download, installation, authentication, tenant, and app
steps must happen inside the named clean guest.

Configure the commands in a protected shell or release runner:

```bash
export EAI_VM_DRIVER=command
export EAI_HARNESS_TENANT_ID="<production-test-tenant-uuid>"
export EAI_HARNESS_TENANT_NAME="EAI Test Harness"
export EAI_HARNESS_USER_EMAIL="<protected-test-user-email>"
export EAI_VM_MACOS_COMMAND="$PWD/scripts/run-macos-guest-test.sh"
export EAI_VM_WINDOWS_COMMAND="$PWD/scripts/run-windows-guest-test.ps1"
export EAI_VM_UBUNTU_COMMAND="$PWD/scripts/run-ubuntu-guest-test.sh"
export EAI_APP_DEPROVISION_COMMAND="$PWD/scripts/run-v4-app-deprovision.sh"
./release.sh publish 0.2.0
```

The guest adapter is responsible for starting or resetting its clean VM,
opening the release URL, downloading the asset inside the guest, running the
GUI installer, completing browser sign-in, selecting the harness tenant,
creating the test app, and verifying the generated project. It must report
every required check and write the app-state receipt immediately after app
creation. The app-state receipt is required so cleanup still works if the
guest crashes after creating the app but before writing its final result:

```json
{
  "appName": "test-macos-run-id",
  "appCreated": true
}
```

The final result must confirm that cleanup was requested even if a preceding
step failed:

```json
{
  "status": "passed",
  "vm": "macos",
  "appName": "test-macos-run-id",
  "projectPath": "/guest/path/to/project",
  "appCreated": true,
  "cleanupRequested": true,
  "checks": {
    "download": "passed",
    "installer": "passed",
    "prerequisites": "passed",
    "authentication": "passed",
    "tenant": "passed",
    "app": "passed",
    "project": "passed"
  }
}
```

Every check is required. A green `/health` or a successful installer process
is not enough. The controller stores command output in the evidence directory
and redacts configured credentials, the harness tenant ID, and the test-user
email before writing it. Guest adapters must not print tenant IDs, account
data, or credentials.

## Real app cleanup

The cleanup command must use the approved V4 app-deprovision API. It receives:

- `EAI_DEPROVISION_TENANT_ID`
- `EAI_DEPROVISION_TENANT_NAME`
- `EAI_DEPROVISION_APP_NAME`
- `EAI_DEPROVISION_CONFIRM`
- `EAI_DEPROVISION_APP_CREATED` (`1` or `0`)
- `EAI_DEPROVISION_RUN_ID`
- `EAI_DEPROVISION_RECEIPT_FILE`

The command must perform the tenant-admin-confirmed V4 cascade and write a
JSON receipt with the exact app name, matching `appCreated` boolean, typed
confirmation proof, and `"cleanupVerified": true`:

```json
{
  "status": "verified",
  "source": "public-api-v4",
  "operationId": "opaque-server-operation-id",
  "appName": "test-macos-run-id",
  "appCreated": true,
  "confirmation": "test-macos-run-id",
  "deletedRecords": { "app": 1, "children": 7 },
  "deletedResources": { "objectTypes": 5, "storage": true, "entra": true },
  "cleanupVerified": true
}
```

The controller marks the production release gate failed if cleanup is missing,
unverified, names another app, or does not match whether the guest created an
app. The diagnostic path is intentionally the only exception, and its report
cannot be used as production release evidence.

At the time of writing, production EAI does not expose the required whole-app
V4 deprovision route. The live gate therefore cannot honestly pass until that
platform capability and its approved adapter exist. The runner refuses to
create test apps without it.

Credentials must be injected by a protected runner or OS keychain. They must
never be committed, printed, or included in GitHub release assets.

## Evidence

Each run writes `release-e2e.json`, per-VM output, asset hashes, and cleanup
receipts under `artifacts/release-e2e/<version>/<run-id>/`. The public release
page contains installers only; tenant identifiers and credentials stay out of
the release notes and public artifacts.
