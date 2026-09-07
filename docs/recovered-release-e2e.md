# Recovered Release E2E Evidence

This record preserves the safe, non-secret configuration and successful test
outcomes recovered from the previous local `eai-installer` working copy on
2026-08-28. The original raw evidence remains local under the ignored
`artifacts/` tree and must not be committed because guest logs can contain
machine and account metadata.

## Controlled Parallels guests

| Adapter | VM | Guest user | Successful 0.3.16 run |
| --- | --- | --- | --- |
| macOS ARM64 | `macOS` | `testmac` | `1787139242049-aa3eec` |
| Windows ARM64 | `Windows 11` | `eai-douglasross` | `1787138102927-6cbea4` |
| Ubuntu ARM64 | `Ubuntu 24.04.3 ARM64` | `parallels` | `1787142014694-efb048` |

The harness tenant display name, tenant UUID, and test-user email are treated as
protected runtime identifiers and are intentionally omitted. This document does
not invent or substitute those required protected inputs.

## Proven checks

Each successful run used the published `eai-setup-test-v0.3.16` ARM64 asset and
reported all eight release checks as passed: download, installer,
prerequisites, authentication, tenant, app, project, and AI handoff. Each run
created a uniquely named test project, ran its package installation, test,
production build, and cross-platform lifecycle test, and recorded diagnostic
mock cleanup rather than verified V4 deletion.

Recovered runtime versions included EAI CLI `3.15.6`; the successful Ubuntu
run also recorded Node.js `24.19.0` and npm `11.17.0`. These are historical
observations, not current minimum-version overrides.

## Secret boundary

Keep `EAI_HARNESS_TENANT_ID` and `EAI_HARNESS_USER_EMAIL` in the protected
runner environment or OS keychain. Do not add them, authentication tokens,
generated `.env.local` files, or raw VM logs to this repository. The guest
adapters validate the recovered guest usernames but still fail closed until
the protected tenant and user inputs are supplied.
