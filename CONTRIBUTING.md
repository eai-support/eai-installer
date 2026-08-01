# Contributing

Keep this repository provider-neutral and public-safe.

- Do not add tenant IDs, private hostnames, secrets, tokens, or internal API
  routes.
- Prefer official package managers and signed vendor downloads.
- Add a manifest validation test for every new prerequisite or workflow step.
- Keep platform-specific behavior inside a named adapter.
- Do not make the installer bypass `eai login`, tenant membership, or platform
  authorization.
- Run `npm test` before opening a pull request.
