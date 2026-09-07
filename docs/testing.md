# Testing and Release Gates

## Local checks

`npm test` validates the manifest, checks that the fallback scripts contain the
required safety controls, and confirms the public source references are not
private platform endpoints. It does not perform a live tenant mutation.

The full desktop interaction traceability list is in
[`docs/scenario-matrix.md`](./scenario-matrix.md). It covers the user choices
at every wizard stage, including existing versus new apps, folder picker
cancel/selection, prerequisite failures, duplicate clicks, and Windows npm
launcher failures. Deterministic behavior is checked locally; native bundle
and guest-machine behavior is checked by the platform workflows below.

The exact test execution trace, including what each gate proves and what it
does not prove, is in [`docs/test-execution-trace.md`](./test-execution-trace.md).

The bootstrap contract tests also verify that Homebrew is optional on macOS,
that missing Git uses Apple's Command Line Tools rather than full Xcode, and
that a missing Software Update listing triggers Apple's native catalog refresh
before the setup reports a recoverable error. They also verify that Node.js 24
is the required runtime and that missing Node.js uses the official signed
Node.js 24 LTS package over HTTPS.
The desktop path must not open Terminal: it uses native macOS administrator
dialogs and reports progress back to the EAI Setup window. The clean-machine
matrix must include macOS Apple Silicon and Intel hosts without Homebrew so the
minimal Git, Node.js/npm, and CLI handoff are exercised together.

## CI checks

- JSON and JavaScript syntax validation
- Static secret and private-host hygiene checks
- Rust `cargo check` for the Tauri application
- GitHub's repository-level default CodeQL analysis for Rust and JavaScript
- Dependency review on pull requests

## Release checks

A release is incomplete until all of the following are true:

1. The native architecture bundles build on Windows, macOS, and Linux.
2. Windows and macOS artifacts are signed and, where applicable, notarized.
3. Tauri updater artifacts are enabled only after signed update keys and their
   public verification key are added to the application configuration.
4. A clean machine test installs Git, Node.js 24/npm, and the CLI, then runs the
   browser login and project handoff without storing a credential.
5. A smoke project confirms `eai init` fetched the supported Gofer/template
   assets and that the generated repository is usable.
6. The exact published assets pass the three-machine release gate and every
   test app has a verified cleanup receipt.

The clean-machine test belongs in a controlled release environment. It should
use a test tenant and test user, not production credentials. The release guest
launches the published desktop application in a protected E2E mode. That mode
uses a control-ready clean snapshot and performs and verifies authentication on
each run. It runs the same prerequisite and project bootstrap commands as the
visible wizard and writes a bounded receipt. Every platform snapshot must omit
Git, Node.js/npm, the EAI CLI, EAI Setup, the AI-workspace harness dependency,
reusable EAI CLI authentication, and installer state. No run may accept cached
browser authentication as its proof. The Windows adapter enforces that boundary
by deleting the restored test user's disposable default Edge profile before it
performs the mandatory email-and-password flow. It also proves that the exact
public HTTPS sign-in URL is reachable from the restored guest before launching
Edge, and bounds any network-error refresh to that proven origin. The macOS snapshot must also
omit Xcode, Apple Command Line Tools, and Homebrew. Its login helper fails if it
observes an authenticated portal before entering credentials or a Microsoft
password page before entering the configured email. A run is not allowed to
pass merely because an older `eai` command already exists on the guest.

The exact Test Mac control and privacy baseline is documented in
[`release-e2e.md`](./release-e2e.md#test-mac-clean-snapshot-baseline).
The macOS adapter provisions its pinned, verified VS Code handoff target only
after proving that baseline is clean, and records both the launched process and
guest screenshot. The AI-handoff check validates launch of the generated
project; it does not validate a separate AI-provider subscription or response.

The exact Windows 11 ARM64 restore, login, installer, and handoff contract is
documented in [Test Windows clean-snapshot and login
baseline](./release-e2e.md#test-windows-clean-snapshot-and-login-baseline). The
adapter restores the approved snapshot disk without resuming saved memory,
proves the prerequisite and EAI state is absent, and signs in from the public
website using exact-name Edge UI Automation. It stops Edge, deletes only
`%LOCALAPPDATA%\Microsoft\Edge\User Data` inside the restored disposable test
VM, and launches the replacement Edge process through persistent local
`Win32_Process.Create`. The helper verifies the returned process's exact
path, command line, interactive session, and owner before accepting the launch;
the following origin-bound UI check proves the public sign-in page. PowerShell
source is streamed through `-Command -`, wrapped as
one `& { ... }` block, and followed by the trailing blank line Windows
PowerShell needs to execute the final multiline statement. Do not move these
scripts back to `-EncodedCommand`: the current Parallels Tools transport was
measured accepting a 3,464-character encoded argument and rejecting 3,728
characters, so the former 6,000-character harness guard was not safe. For
general payload-bearing calls, the host UTF-8/base64 frames only the data inside the
stdin wrapper, installs it as `[Console]::In`, and executes only the trusted
here-document. Protected values are streamed from the host Keychain/runtime
environment, never through command arguments, guest files, executable decoded
text, or the clipboard. General retry classification requires an exact
`PrlVmGuest_RunProgram` session-open line. Fixed browser UI transitions, the
read-only post-login tenant-list verification, and the fixed read-only Windows
AI-handoff process observation are exceptions to an exact
`PrlJob_GetResult`/`GetRetCode` failure. Post-launch replay-safe reads use the
same narrow exception for launch validation, the second installed-executable
hash, receipt polling/fetch, exact-project proof, post-`AppActivate` liveness,
and tri-state application-process observation. Both current-user and LocalSystem
read transports retry at most three times, two seconds apart, only for exit 255
plus one complete approved line. Static tests prove those wrappers are not used
for launch, stop, product handoff, cleanup, or policy mutations. The fixed AI
process observation can only inspect the expected VS Code path/session/window
tuple. Successful not-ready observations may be polled; malformed output, extra
or partial error text, other statuses, and mutation-bearing calls fail without
an ambiguous-result retry. Browser actions may retry five times because each
action first accepts its exact, origin-bound destination state. Installed-app
launch has one narrower exception:
an exact exit-255 `PrlVmGuest_RunProgram` session-open failure may be retried at
most twice, each time with a new nonce, only after LocalSystem has published the
old nonce's cancellation signal and proven that no bound bootstrap, arm, PID,
receipt, temporary artifact, or exact executable process existed. Exact
`PrlJob_GetResult`/`GetRetCode` errors are ambiguous and never authorize a
mutation replay.
LocalSystem first stages a fixed, no-secret, SHA-256-bound bootstrap with an
inheritance-disabled ACL: LocalSystem owns and may modify it, while only the
expected interactive user may read and execute it. The one current-user
`powershell -File` request contains only non-secret mode/hash/nonce arguments;
E2E tenant and project values are exactly two raw stdin lines. An uncertain
transport return is accepted only when independent LocalSystem validation finds
the complete nonce-bound arm/PID/receipt, proves the bootstrap terminal, and
proves the exact child still alive. Otherwise cleanup cancels that nonce before
inspection; similar-looking PowerShell output and all other ambiguous results
fail closed without starting a duplicate process. The fixed process-query retry
has a host-only behavioral regression test and never contacts a VM:

```bash
bash scripts/test-windows-ai-handoff-process-query.sh
bash scripts/test-windows-readonly-powershell.sh
```

Before typing either value, the helper binds the element to Edge in the active
session and verifies the expected origin: `www.enterpriseaigroup.com`, then
`admin-portal.myenterprise.ai`, then
`enterpriseaiplatform.ciamlogin.com`. The password field must have Automation
ID `i0118`, name `Enter the password for {0}`, and `IsPassword=true`. Both the
email and password stages are required. Portal readiness means the exact
`/platform/getting-started` path plus visible **Getting started** and **All
apps** controls; cached authentication is never a pass. The adapter then
downloads and hashes the exact published ARM64 installer inside the guest,
launches the installed application once without E2E mode to prove its
prerequisite path, and launches the unchanged executable in bounded E2E mode.
The AI-handoff check additionally requires the pinned, signed ARM64 VS Code
process in the same interactive user session and stores sanitised workspace,
process, and screenshot evidence.

The Windows NSIS bundle uses the current-user install mode. This keeps the EAI
Setup application in the user's profile and avoids an administrator prompt for
the installer itself. EAI Setup may still ask for permission when the user
chooses to install system-managed Git or Node.js prerequisites; that request is
separate and is shown by the setup window as an explicit action.

The protected installer bridge treats the short-lived NSIS launcher as a
process-handle race: it records the normalized `StartInfo` path independently,
then requires either a matching live path or a zero-time `WaitForExit` proof
that the same returned process exited before live inspection. Static release
tests reject the former `HasExited`-then-`Path` sequence, require both receipt
fields and their aggregate gate, and require both atomically published terminal
receipt readers to return immediately on an immutable invalid receipt. These
tests inspect host scripts only and do not access a VM.

The Windows VM console must remain visible (it need not be full-screen) during
that prerequisite stage. If a restore retained Coherence, the host helper first
accepts an already-visible exact bundle-bound VM window; otherwise it resolves
the unique WinAppHelper through menu-bar item 2's exact VM name plus a **View**
submenu containing one **Exit Coherence** action. It stores only integer PIDs
during Accessibility enumeration, revalidates the exact process and unique menu
action, invokes it once, and waits for the exact Parallels window helper. It
never retries that state change and never identifies the helper by process
display name, path, or a hardcoded PID. Ambiguous or missing candidates fail
closed. Normal console selection retains the bundle-identifier lookup for the
`prl_client_app` process.

The approved snapshot must have the release-test user
in the local Administrators group and exact DWORD values `EnableLUA=1`,
`PromptOnSecureDesktop=0`, and `ConsentPromptBehaviorAdmin=5`. After the native
installer passes, the protected LocalSystem channel revalidates that baseline
and temporarily changes only `ConsentPromptBehaviorAdmin` from `5` to `0`.
UAC stays enabled and `PromptOnSecureDesktop` remains `0`. This is a bounded,
disposable-VM diagnostic accommodation for the already-authorized Git and
Node.js installs, not a production gate or consent-UI test.

While prerequisites install, a host-only negative watcher captures only the
exact bundle-bound Parallels window. Any visible UAC consent dialog or any
capture/OCR infrastructure failure fails closed; the watcher never sends
approval input and does not retain a rejected frame. Its receipt records zero
approvals. The harness restores and reads back
`ConsentPromptBehaviorAdmin=5` immediately after prerequisites and before
authentication/E2E, with LocalSystem nonce- and run-bound before/after evidence.
The exit trap repeats restoration on failure. If restoration cannot be proven,
the VM is quarantined and the approved snapshot must be restored before reuse.
WindowsApps aliases are not treated as installed
Git/Node/npm/EAI binaries, every version process is time-bounded, and the whole
readiness wait has a 20-minute wall-clock limit.
Each visible-readiness capture first revalidates the exact normal-launch v5
receipt and live PID/start/path/session/owner/command-line tuple. It minimizes
only the same user's packaged Microsoft Windows Terminal window, foregrounds
the receipt-bound EAI Setup window, and verifies the foreground handle before
OCR. Readiness requires both visible **Sign in** and **Prerequisites installed
successfully** text from that window after the version contract passes. The
phrases are matched independently because Apple Vision did not reliably retain
the trailing brand text in **Sign in to EAI** on the Windows guest. This prevents
the current-user version probe from hiding the product; it does not close or
terminate either process.
If the host process is forcibly killed and cannot run its exit trap, the VM is
also quarantined and restored to the approved snapshot before reuse.
Consent-UI inspection is an independent host-only watcher, is required to
remain alive, and is stopped before the consent policy is restored.
The normal and E2E application launches never keep a Parallels command attached
to the GUI lifetime. The fixed bootstrap holds a no-write/no-delete read lock
while hashing the exact installed executable, writes a nonce-bound launch arm,
and asks local legacy WMI `Win32_Process.Create` to start the exact quoted path
with no application arguments. `Win32_ProcessStartup` supplies a full
process-only Unicode environment and `winsta0\default`; inherited
`EAI_SETUP_E2E*` values are stripped in both modes and exactly five are added
only for E2E. The bootstrap writes a v5 PID/start/session/owner receipt and
clears its protected input state before returning.
The v5 timeline separately records WMI return and the later instant at which
the complete process tuple was observed. It requires arm time to precede both
WMI return and process start, and requires both to precede tuple observation;
it deliberately does not require process start to precede WMI return because
that ordering is not guaranteed by the provider. The same observation bound is
used when rebinding the exact WMI-returned PID for immediate failure cleanup.
Only after that current-user command returns does LocalSystem prove the exact
bootstrap PID/start tuple is gone while the exact application tuple remains
alive, including the canonical command line and the live child job state. The
prelaunch scan, independent validator, receipt-bound focus, liveness/stop
probes, and terminal cleanup share one path-equivalence contract: full paths
may differ only by Windows' extended local (`\\?\C:\...`) or UNC
(`\\?\UNC\...`) prefix spelling. Static fixtures cover both forms, while the
quoted executable-only command line remains an exact raw comparison. A
reused numeric PID passes only after LocalSystem retains its process handle and
proves its creation time is strictly later than the receipt timestamp; the
replacement is never terminated. Same-start, unreadable, and non-later
identities fail closed. That
post-return validation, not job absence, proves the provider-brokered process
outlived Parallels' monitored command lineage. A sanitized host receipt records
the transport duration and successful live-child validation. Only a complete
receipt can authorize cleanup, and it binds cleanup to the exact retained
PID/start/path/session/owner/command-line tuple immediately before termination
and wait. An arm without that receipt never authorizes a path-, session-, or
timestamp-based process stop.
The bootstrap checks a fixed LocalSystem-owned cancellation signal both on entry
and immediately before and after the local WMI call. A cancellation or any
post-create validation failure rebinds the exact WMI-returned PID to its
path/session/owner/command-line and arm-to-identity-observation time window,
then terminates and waits it before throwing. A WMI error without a trustworthy returned PID is
never scanned heuristically and is never replayed. Exit cleanup preserves any
existing arm and receipt bytes first, publishes that signal before reading
launch state,
never kills a still-live nonce/hash/user/session-bound bootstrap whose WMI call
may be in flight, and refreshes arm/PID/receipt only after natural bootstrap
absence. A launch without a complete v5 receipt never reports terminal cleanup:
finite process absence is diagnostic only, the cancellation signal and bound
guest artifacts remain, and the VM is quarantined for immediate approved-snapshot
restoration before any retry or reuse. During the prerequisite window this entire app/bootstrap
cleanup runs while the negative consent-UI watcher and temporary no-prompt
policy are still active; the watcher is stopped and
`ConsentPromptBehaviorAdmin=5` restored only after terminal app proof.
The current-user bootstrap must be inside the Parallels job before launch. The
WMI provider can legitimately put its child in another job, so
`IsProcessInJob(..., NULL)` is recorded and revalidated as either boolean; a
false-only assertion would reject the live-proven provider path.

The LocalSystem Defender guardian uses the same provider-brokered pattern:
local `Win32_Process.Create`, a process-only environment with `EAI_*` stripped,
and an exact SYSTEM/session-0/path/command-line check before accepting its arm.
If the stateful bootstrap returns ambiguously before any guardian or Defender
receipt exists, cleanup publishes the nonce-bound stop marker and records
snapshot quarantine immediately. It never treats finite absence as verified
Defender cleanup or fabricates a removal receipt.

On Windows, EAI Setup does not rely on the CLI to launch a nested `npm.cmd`
process. It calls `eai init --no-install` to create the scaffold, then invokes
npm through the resolved Node runtime when the npm entry point is available,
with a shell-shim fallback. This keeps the setup flow independent of the
user's PowerShell execution policy or PATH and preserves the real npm
diagnostic if dependency installation fails. A direct `eai init` remains a
separate CLI workflow.

The production release controller is run by release.sh publish. It cannot
declare a release healthy from simulated installer files, simulated tenant
records, or a synthetic cleanup receipt. The live gate fails closed before
downloading assets or creating an app unless each VM command is one exact
canonical executable, the protected test-tenant runtime values are present,
the PublicAPI origin is an approved regional endpoint, and the repository's
canonical V4 app-deprovision adapter proves read-only readiness with the
manifest-pinned minimum EAI CLI. Production publish also waits for the exact
protected signing-readiness workflow run before it creates a tag. Static
safeguards require that workflow to validate Apple certificate lifetime,
identity, chain/revocation, timestamped signing and notarization authentication,
and the exact Azure account/profile/identity-validation/signer-role control
plane without tag, release, tenant, Azure-resource, or notarization-submission
mutation. The Apple check does create and remove private temporary runner files
and contacts certificate timestamp/revocation and notarization-history services.
They also preserve the explicit limitation that only the post-tag
Windows matrix can prove Azure's Artifact Signing data plane by signing and
verifying the exact staged installer.

`npm test` also exercises controller interruption entirely with fake host
commands. The fixtures prove `SIGINT`/`SIGTERM` forwarding, exit codes 130/143,
release-download interruption, direct no-shell adapter execution,
adapter PID/trap binding, single-VM and single-cleanup execution, terminal report
persistence, output redaction, second-signal force of the original child, and
that a second signal received after VM termination does not kill the active
cleanup child. Cleanup fixtures also reject wrong schema, tenant/API
fingerprints, CLI version, ownership plan, deletion counts, and absence proof.
Static coverage requires POSIX process-group isolation with the detached child
still retained and awaited, and rejects any automatic `SIGKILL` timer. These
tests do not start, stop, restore, or otherwise alter a VM.

release.sh diagnostic-e2e <version> is available for installer debugging. It
uses the real published assets and real guest workflow, but deliberately does
not delete the test app. It reports passed_with_mock_cleanup and must not be
used to approve or publish a release. A guest timeout or a pre-existing CLI is
not a pass; the receipt must show the desktop bootstrap path completed.

release.sh publish-diagnostic <version> is deliberately disabled: diagnostic
cleanup cannot authorize a production `v*` tag. `publish-test` requires one
explicit `EAI_RELEASE_VMS=macos|windows|ubuntu` value so manual cleanup can be
confirmed before the next diagnostic VM. Neither path can become clean-release
evidence.

The diagnostic controller itself does not delete tenant data. Cleanup between
guests must follow [Manual diagnostic app
cleanup](./release-e2e.md#manual-diagnostic-app-cleanup), including exact portal
confirmation, the narrowly gated zero-service fallback for the known V4
`deletion-plan` failure, and three independent absence checks. This evidence
remains diagnostic and does not satisfy the production gate's V4 cleanup
receipt. Safari Automation used during diagnosis is temporary guest state, not
part of the Test Mac snapshot baseline; its separate `prltoolsd` control prompt
is not the System Events Automation approval required by the normal adapter.

The Windows portal cleanup UI has a host-only fake-transport regression test:

```bash
bash scripts/test-windows-portal-cleanup-ui.sh
```

It proves that a failed controller run is accepted only with three matching
run-derived app receipts, nonzero child state cannot emit a target receipt, the
fixed `/platform/apps` navigation and structural UI actions execute in order,
the prepare phase never invokes the permanent action, an exact transient can be
retried for a read-only portal-state observation without retyping values, an
ambiguous menu/dialog transition is not replayed, a final action is invoked at
most once through a hash-bound worker launched on the interactive guest desktop,
and an invocation that returns while the exact confirmation dialog remains open
is rejected and recorded as uncertain without replay. It requires the exact
expected guest username, matching Explorer/Edge owner SIDs, one positive
Explorer-backed interactive session, one shared foreground Edge HWND/PID with
stable runtime IDs, scoped InvokePattern rather than SendKeys, and
twelve consecutive 250 ms absent-dialog observations before accepting the
interactive result. The same host-only test covers the single hard-coded
attempt-2 recovery gate: a successful first invocation, two post-60-second 1/1
presence channels measured on the host receipt clock, fresh
identity/source/tenant matching, complete bounded service-activation and
product-config zero-child queries, a ten-minute hashed confirmation nonce, a
per-run lock with manual stale-lock resolution, immediate pre-arm
target/dialog/expiry revalidation, an
exclusive arm written before desktop input, and permanent rejection of replay
or attempt 3. It also covers the exact 0.3.19 legacy target-receipt migration:
the old embedded child summary is recorded as non-authoritative identity and
provenance history, the immutable receipt remains unchanged, and only a new
complete bounded exact zero-child query can reach UI preparation. Failed,
incomplete, and nonzero fresh queries are asserted to produce no portal input,
worker staging, or mutation, while the modern authoritative receipt path remains
valid. The Windows diagnostic cleanup regression additionally proves
that a valid hardened attempt-1 or attempt-2 invocation plus later `0/0` API/CLI verification creates
the immutable attempt-2 verification and standard portal-pending cleanup
receipts without overwriting attempt-1 evidence, while a changed hash chain,
tenant fingerprint, or interactive window/session/owner proof fails closed.
The test uses fake login, input, and `prlctl` commands and does not access or
alter a VM. Static release checks additionally bind the protected Windows
login's three-attempt retry to HTTPS reachability and portal-readiness reads and
keep Edge/profile actions plus credential and CLI submissions outside it.

The shared guest finalizer is also contract-checked to retain
`cleanupRequired` and `cleanupRequested` in `app-state.json` after a created-app
result, so a successful diagnostic run is eligible for this exact cleanup path.
The desktop bootstrap additionally writes an exact-name progressive creation
checkpoint before processing returned init output, and Rust tests exercise its
synchronized atomic replacement. The Windows cleanup regression covers both a
failed current build with that passed app checkpoint and the published 0.3.19
candidate's host-inferred exact local-project checkpoint. Both paths also
require the matching run-bound remote-cleanup arm; a failed run with only the
conservative arm is rejected before a guest query or mutation.

The companion Windows diagnostic-cleanup regression also runs without a VM:

```bash
bash scripts/test-windows-diagnostic-cleanup.sh
```

It statically and through the PowerShell self-test enforces that every CLI
query or mutation runs from the fixed, receipt-derived
`C:\Users\Public\EAIReleaseTests\<exact-app-key>` project. The project root,
all ancestors, nested marker directories, and marker files must be real
filesystem objects without reparse points; the exact scoped package name,
build/typecheck scripts, EAI dependency, default-template manifest, and Object
Types source marker must agree. The test also rejects an input/environment
project-root override and JSON `--where` arguments. Enrollment reads instead
use a complete page below the 1000-record cap and exact case-sensitive
in-memory selection, avoiding Windows PowerShell 5.1 argument dequoting.

The macOS Parallels current-user transport also has a host-only regression
test. Its fake `prlctl` verifies both exact transient signatures, the
three-attempt limit, original failure statuses, stdout/stderr separation,
replayable stdin for explicitly idempotent shell blocks, identity/Aqua gating,
and the least-privilege `launchctl asuser` command shape without accessing a VM:

```bash
bash scripts/test-parallels-macos-current-user.sh
```

Static release-contract checks also require the macOS abnormal-exit cleanup to
use only its fixed receipt and exact non-symlink project/package paths, parse an
exact scoped package name privately on the host, preserve richer receipts, and emit a
boolean failure checkpoint without enumerating tenant resources.

The Ubuntu static contract additionally proves that the expected CLI is pinned
to `3.15.10`, Node.js 24+ is verified after the released product runs without a
harness repair, and an executable npm is resolved to a root-owned target owned
by the fully installed `nodejs` package without requiring a separate `npm`
Debian package. A host-only provider fixture covers the NodeSource-style layout
where `npm --version` succeeds while `dpkg-query -W npm` does not.

Both checkpoint and final Resource API queries execute from the exact generated
project, use the scalar `{"verticalKey":"<exact-app-key>"}` filter expected by
CLI 3.15.10, and parse its `{resources,totalDocs}` envelope. Static checks reject
the earlier nested `equals` filter and require both query sites to remain scalar.
The adapter enforces the write-ahead
order `cleanup arm -> durable app state -> mutating E2E launch`, retains the arm
when a remote query is unavailable or ambiguous, and requires the final remote
record hash to match the creation checkpoint. VS Code evidence requires the
exact user-owned executable and project cwd while independently inspecting its
NUL-delimited argv. CLI login is bound to the disposable Firefox profile and
verified graphical session through a private `BROWSER` launcher.

Controller checks reject empty or non-object V4 deletion fields. They also keep
cleanup invocation separate from app-state parsing, so a missing, malformed,
symlinked, or wrong-app state file causes exact-name conservative cleanup and a
failed run instead of bypassing cleanup.

The success path performs the same independent project proof and retains only a
handoff screenshot that passes full-frame OCR for the exact project and chat
surface while rejecting protected runtime values and browser callback data.
Windows retries only the safe focus/capture observation: every attempt must
re-query the same exact `Code.exe`, prove its foreground window handle, and
revalidate its PID/path/session tuple. It never repeats the product handoff,
login, app creation, or cleanup mutation.

`npm test` checks this contract. The live release gate must be run from a
protected release environment with real GitHub release assets, real clean
machines, real EAI authentication, and real tenant cleanup. It is intentionally
not a GitHub-hosted unit test because it needs interactive operating-system
installers, browser sign-in, and a tenant-admin cleanup action. In particular,
the static contract checks enforce the Windows stage order, exact public login
path, disposable Edge-profile reset, persistent Explorer launch, PowerShell
standard-input terminator, origin and password-field binding, authenticated
portal controls, Keychain and UI Automation boundaries, guest-versus-host asset
hash, the diagnostic-only exact-file Defender allowance and verified removal,
ordinary pre-E2E launch, and ARM64 VS Code handoff evidence. The Defender
allowance applies only to the hashed unsigned candidate inside the controlled
guest; it neither disables protection nor constitutes production release
approval.

## Test installer downloads

The `Test installer bundles` workflow produces three unsigned, short-lived
GitHub Actions artifacts for the current branch or pull request:

- Windows x64 and ARM64 NSIS `.exe`
- macOS Apple Silicon and Intel `.dmg`
- Ubuntu x64 and ARM64 `.deb`

Each native runner builds its bundle and performs an installation/package smoke
test. Ubuntu validates that the selected `.deb` contains the executable before
installing it, so a control-only package cannot be published. The macOS job also copies the app to a disposable staging directory,
re-signs that copy ad hoc, removes its quarantine attribute, and launches the
embedded executable. This proves that the unsigned development bundle runs;
it is deliberately not a Gatekeeper trust test. A final Ubuntu job downloads
all three artifacts again, checks that each file is non-empty, and records
SHA-256 hashes. These are test artifacts, not production releases; users will
see the operating system's unsigned-download warning until release signing is
configured.

The public macOS release gate is different: it must verify the actual
Developer ID signature, notarization, and stapled ticket on the release app or
DMG. An ad-hoc re-sign is never suitable for a customer download.

To run the development check manually on a Mac after mounting a test DMG:

```bash
scripts/test-macos-dev.sh "/Volumes/EAI Setup/EAI Setup.app"
```

The script makes a disposable copy, so it does not alter the mounted image or
the original app. It does not weaken Gatekeeper for normal applications.

Development builds declare Tauri's `signingIdentity` as `-`, which creates a
valid ad-hoc bundle signature. The release workflow overrides that identity
with the organisation's Developer ID credentials and requires Apple
notarization credentials before it can publish a macOS asset. It then runs
`codesign`, `spctl`, and `xcrun stapler validate` against the exact release
bundle.

GitHub Actions artifacts are intentionally ZIP-wrapped by GitHub. They are
useful for CI evidence, but are not the end-user download experience. To create
direct native test downloads, run the manual `Publish test installer release`
workflow with a unique version such as `0.1.0-pr9`. It publishes a prerelease
with these stable asset names:

- `eai-setup-macos-arm64.dmg`
- `eai-setup-macos-x64.dmg`
- `eai-setup-windows-x64.exe`
- `eai-setup-windows-arm64.exe`
- `eai-setup-ubuntu-amd64.deb`
- `eai-setup-ubuntu-arm64.deb`

Production releases use the same stable asset names, so public documentation
can use GitHub's `/releases/latest/download/<asset-name>` links without
exposing a temporary Actions artifact URL.
