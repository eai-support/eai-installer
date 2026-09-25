# Decisions

## 2026-09-25 owner approval

Implement the reviewed Installer fixes while preserving supported setup and both source-mode commands. Do not merge, release, deploy, activate, bill, or run destructive live tests.

## CLI release floor

Capability detection is authoritative during pre-release development. Keep the existing baseline explicit, but do not call it the final feature-bearing floor and do not predict or reuse a version. Publication remains blocked until a real released CLI both meets the floor and exposes the required command flags.

## Local-template testing

Local trusted-template execution is a build/test facility, not a production environment switch. Production binaries must not enable it from an ordinary environment variable.
