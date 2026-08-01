## Summary

<!-- What changed and why? -->

## Validation

- [ ] `npm test`
- [ ] `bash -n scripts/bootstrap.sh scripts/release-preflight.sh`
- [ ] PowerShell parsing checked when the script changed
- [ ] Rust/Tauri CI check is green when native code changed

## Public-repo safety

- [ ] No credentials, tenant-specific values, private hostnames, or internal API routes
- [ ] No executable archives or binary test fixtures added to the PR
- [ ] New downloads use official HTTPS sources and are documented
- [ ] Authentication remains browser-based and no user secret is collected
