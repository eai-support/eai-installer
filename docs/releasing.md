# Releasing EAI Setup

EAI Setup uses semantic versioning:

- `MAJOR.MINOR.PATCH` is the only release version format.
- Major versions contain breaking installer or workflow changes.
- Minor versions contain backwards-compatible features.
- Patch versions contain backwards-compatible fixes.

Before opening a release PR, update the same version in:

- `package.json`
- `src-tauri/Cargo.toml`
- `src-tauri/tauri.conf.json`

Run `npm test`. The version check fails if a source is not a valid
`MAJOR.MINOR.PATCH` value or if the three values differ.

## Test release

Use the `Publish test installer release` workflow with the exact version in
the repository, for example `0.1.4`. It publishes an unsigned prerelease with
the tag `eai-setup-test-v0.1.4` and six native assets for Windows, macOS, and
Ubuntu.

## Production release

After the release PR is merged, run the release controller with the matching
version:

```bash
./release.sh publish 0.1.4
```

It creates and pushes the matching tag. The release workflow validates that
the tag and all source versions match, then requires the configured signing and
notarization credentials before publishing the customer release.

## End-to-end release gate

Use the repository release controller after the release PR has merged:

```bash
./release.sh publish 0.2.0
```

It waits for the GitHub release, downloads the exact assets from that release,
and runs the macOS, Windows, and Ubuntu VM adapters. A release is not complete
when package CI passes alone. The VM adapters must complete browser sign-in,
tenant selection, app creation, generated-project verification, and cleanup.
Before creating the tag, `publish` runs a live preflight. It requires a
protected test tenant, one real VM command per operating system, and the
approved V4 app-deprovision adapter. If any is missing, no tag is created and
no test app is created.

There is no local mock or bypass mode for the production gate. To rerun a
published release after repairing a VM or platform dependency, use
./release.sh e2e <version> with the same protected live configuration. A code
fix requires a new patch, because the release gate must test the exact
published asset.

For installer-only diagnosis while V4 app deletion is unavailable, use
./release.sh diagnostic-e2e <version>. This runs the real published-asset VM
workflow but does not delete the created test app, so it is never a release
approval or a substitute for the live cleanup gate.

If a tagged release is still required before V4 app deletion is available,
use ./release.sh publish-diagnostic <version>. This is an explicit exception:
it publishes only after the real guest workflow passes, but its cleanup
evidence is unverified and the created test apps remain in the harness tenant.
