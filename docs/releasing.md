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
the repository, for example `0.1.2`. It publishes an unsigned prerelease with
the tag `eai-setup-test-v0.1.2` and six native assets for Windows, macOS, and
Ubuntu.

## Production release

After the release PR is merged, create and push the matching tag, for example:

```bash
git tag v0.1.2
git push origin v0.1.2
```

The release workflow validates that the tag and all source versions match,
then requires the configured signing and notarization credentials before
publishing the customer release.
