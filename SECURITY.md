# Security Policy

## Scope

EAI Setup is a public bootstrapper. It installs public developer tools and
starts the user's existing EAI authentication flow. It must not contain
passwords, API keys, client secrets, private endpoints, tenant-specific
configuration, or private source code.

## Reporting

Do not open a public issue for a suspected security problem. Use the private
security advisory flow for this repository or contact the Enterprise AI Group
security maintainers through the organisation's published security contact.

Please include the affected version, operating system, reproduction steps, and
whether the report concerns the installer binary, a bootstrap script, or a
dependency. Never attach executable archives or live credentials.

## Release requirements

- Desktop artifacts must be signed for their platform before publication.
- Tauri updater artifacts must use signature verification; the signing private
  key is held only by the release environment.
- CI runs secret scanning, dependency checks, and static bootstrap validation.
- Installer downloads and documentation links must use HTTPS.
- Device registration, if added later, must use an explicit platform activation
  contract and a random local identifier, never a hardware serial number.
