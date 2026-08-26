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
  -> Git + Node.js 24/npm
  -> @enterpriseai/cli (command: eai)
  -> browser sign-in
  -> eai init
       -> supported Gofer assets
       -> eai-app-template
       -> user-selected project folder
  -> eai start --check
  -> user confirms the selected AI provider may open the project
  -> eai start --surface <supported-surface>
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

## AI workspace handoff

The installer delegates detection and launch to the versioned
`eai.ai-surfaces/v1` CLI contract. Detection reads command and application
metadata only. It does not inspect provider accounts or project contents.

The user chooses the workspace on first use; the last successfully opened
workspace becomes the next default. Starting it is an explicit confirmation
that the selected provider may read the project and use the user's provider
account. EAI Setup remains open until the handoff reports success or a useful
failure.

EAI Setup never obtains provider credentials or writes provider tokens into the
project. When a provider is missing, an explicit user action may open a fixed
official provider installation page. The provider remains responsible for its
installer, licensing, authentication, and account terms.
