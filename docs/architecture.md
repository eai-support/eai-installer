# Architecture

## Boundary

EAI Setup is a client-side bootstrapper, not a replacement for the EAI
platform. Its job is to make a clean computer ready for the public EAI
workflow. The existing CLI remains the source of truth for login, tenant
selection, template provenance, Gofer assets, app initialization, and platform
operations.

```text
Signed EAI Setup
  -> platform adapter (WinGet / native macOS packages / distro package manager)
  -> Git + Node/npm
  -> @enterpriseai/cli (command: eai)
  -> browser sign-in
  -> eai init
       -> supported Gofer assets
       -> eai-app-template
       -> user-selected project folder
```

## Why this is not a full computer image

An OS image is large, platform-specific, hard to update, and usually carries
more identity and configuration than a public developer tool should. A signed
installer gives the Dropbox-like guided experience while keeping the machine's
normal package manager and the EAI CLI's release model.

## Company and computer registration

Anyone may download the public installer. Download permission is not EAI data
permission. The first-run flow uses the normal EAI browser login, then the
platform decides what the signed-in user can do in each tenant. If a future
device-registration service is introduced, it must be an explicit server-side
contract with revocation and audit; this repository does not pretend that a
local device ID is an authorization decision.

## AI host handoff

The installer can detect an editor or show the documented next command. It must
not install a user's AI provider, obtain AI credentials, or put provider tokens
in the project. After `eai init`, the generated repository contains the
Gofer/editor assets needed by the supported EAI workflow.
