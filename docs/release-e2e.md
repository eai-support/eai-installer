# Release End-to-End Gate

The release gate validates the installer from the public GitHub release page,
not from a local build directory. It is deliberately separate from normal
package CI checks.

## Release commands

Version preparation creates a release PR and never pushes directly to `main`:

```bash
./release.sh patch "Fix clean-machine bootstrap"
./release.sh minor "Add the release VM gate"
./release.sh major "Change the installer contract"
```

After the release PR is merged:

```bash
./release.sh publish 0.2.0
```

`publish` runs the live preflight before creating a tag. That preflight executes
each exact adapter with `--preflight`: the VM adapters make only read-only
Parallels inventory/snapshot queries, while the canonical V4 adapter checks its
CLI contract and makes one bounded read-only tenant-resource query. It never
restores or boots a guest and never creates or deletes tenant data. The command
then dispatches the protected `release-readiness.yml` workflow with a unique
correlation value and refuses to tag unless that exact run validates the Apple
Developer ID identity, certificate lifetime/chain, timestamping and notarization
authentication, plus the exact Azure signing account/profile state and signer
RBAC. This non-publishing check deliberately does not issue an Azure signing
request: the Windows release matrix is the authoritative data-plane proof. It
then tags the merged commit, waits for the
signed GitHub release workflow, downloads the exact release assets, and runs
the VM gate. A failed code gate requires a new patch version. A transient VM
failure may rerun the same immutable tag after the environment is repaired.

When app deletion is intentionally unavailable, use the unsigned test-release
path for one explicitly selected VM at a time:

```bash
EAI_RELEASE_VMS=macos ./release.sh publish-test 0.3.19
```

Manually clean up and verify that VM's app before selecting the next VM. The
diagnostic evidence is `passed_with_mock_cleanup`, not a clean-release approval.
`publish-diagnostic` is disabled because unverified cleanup cannot authorize a
production `v*` tag. The normal `publish` command remains real-cleanup-only.

The production release gate has no mock mode. It cannot claim success from
simulated installer files, simulated tenant records, or a synthetic cleanup
receipt.

For installer diagnosis only, run the explicitly labelled diagnostic command:

    EAI_RELEASE_VMS=macos ./release.sh diagnostic-e2e 0.3.0

This still downloads the published GitHub assets and runs the real macOS,
Windows, and Ubuntu guest checks. It can create a real test app, but it records
cleanup as not-verified and does not delete anything. A successful result is
reported as passed_with_mock_cleanup; it is evidence that the installer and
guest workflow ran, not evidence that a release is safe to publish. The
publish command always uses the real V4 cleanup adapter and rejects this
diagnostic mode.

## Controlled downloadable test release

When production signing is not yet configured, use the release controller's
test path:

```bash
./release.sh publish-test 0.3.5
```

This command runs the local release checks, dispatches the repository's
`test-release.yml` workflow, waits until GitHub has published the six native
test assets, then downloads those exact assets from the GitHub prerelease
`eai-setup-test-v<version>` and runs the real macOS, Windows, and Ubuntu guest
adapters. The guest results are written to the normal release evidence folder.

The test release is intentionally unsigned and marked as a prerelease. It is
appropriate for controlled release validation only; it is not a customer
installer and does not replace the signed `publish` path.

## Live VM adapter contract

The controller runs one test for each of `macos`, `windows`, and `ubuntu`. The
only supported adapter is `command`; it fails clearly until a controlled
Parallels or CI runner is configured. Each adapter receives these environment
variables:

- `EAI_RELEASE_VERSION`, `EAI_RELEASE_TAG`, and `EAI_RELEASE_REPO`
- `EAI_VM_ID` and `EAI_VM_ASSET`
- `EAI_VM_DOWNLOAD_URL`, which points to the GitHub release asset
- `EAI_VM_PROJECT_NAME`, a unique kebab-case test app name
- `EAI_VM_RESULT_FILE`, where the adapter must write JSON
- `EAI_VM_APP_STATE_FILE`, where the adapter must write app creation state
- `EAI_HARNESS_TENANT_ID`
- `EAI_HARNESS_TENANT_NAME`
- `EAI_HARNESS_USER_EMAIL`

### What the VM commands mean

The VM commands are release-team adapters, not commands that customers run.
They are protected scripts maintained by the release owner for the three clean
guest machines. The controller starts one command per guest and passes the
published asset, download URL, unique test app name, and receipt paths through
environment variables.

A macOS adapter may reset or start the Parallels macOS guest, download the DMG
inside that guest, run the installer, complete the browser sign-in, create the
test app, and write the JSON receipts back through the shared test folder. The
Windows adapter does the same with PowerShell and the Windows installer. The
Ubuntu adapter does the same with a shell script and the Debian package.

For controlled macOS VM testing, `scripts/prepare-macos-guest-dmg.sh` owns the
download and mount boundary. It rejects malformed URLs, verifies the selected
guest is macOS, refuses to run the test as `root`, confirms the requested
signed-in guest account, resolves that account's real macOS home directory,
waits for a stable download size, compares the guest
SHA-256 with the CI artifact, validates the DMG structure, and opens the
verified mount through the signed-in user's macOS launch session. It uses
`launchctl asuser`, drops privileges, and explicitly restores `HOME`, `USER`,
and `LOGNAME` before opening Finder; a plain
root-owned GUI launch is explicitly forbidden. It deliberately avoids the guest Downloads folder
because Parallels background tools do not necessarily have macOS privacy access
to that folder. The controlled Test Mac account is fixed to `testmac`; the
adapter fails closed if a different guest username is supplied. It uses
Parallels' current signed-in user channel and never places a guest password in
command arguments, repository files, or test evidence.
Unsigned pull-request artifacts require the explicit
`EAI_VM_ALLOW_UNSIGNED_TEST=1` test flag; signed customer releases must not use
that flag.

### Test Mac clean-snapshot baseline

The controlled Apple Silicon guest is named `macOS`, its release-test user is
`testmac`, and its approved snapshot is `29-8-2026`
(`{d67a4cdf-bd15-46aa-963b-19a6ab49ebce}`). The approved snapshot contains the Parallels control plane, not the
developer prerequisites or EAI state that the released installer is meant to
create. Its required baseline is:

- macOS automatically logs in as `testmac` and reaches that user's Aqua session.
  After every cold restart, `prlctl exec macOS --current-user /usr/bin/id -un`
  must return `testmac`, and `launchctl` must expose the matching `gui/<uid>`
  session. A root or login-window control channel is not acceptable.
- Parallels Tools is installed in the guest, matches the host Parallels Desktop
  build, and its services are healthy. Host-side framebuffer capture and
  keyboard injection must still work after a restart.
- `AppleKeyboardUIMode` is `3` for `testmac`, so keyboard navigation can reach
  all controls without coordinate clicking.
- In the guest's Privacy & Security settings, `prltoolsd` has Accessibility
  access, and its Automation permission for System Events is enabled. Full Disk
  Access for `prltoolsd` is also enabled as an explicit release-owner-approved
  setting for this controlled test VM. These approvals are established before
  taking the snapshot; the release adapter must not bypass or silently change
  macOS privacy controls.
- The host keeps the macOS administrator credential in Keychain service
  `eai-installer-parallels-macos-admin`, account `testmac`. Only the service and
  account labels are documented. This is the guest administrator credential,
  not the EAI sign-in credential. The secret itself must never appear in this
  repository, command arguments, clipboard contents, logs, or evidence.

The separate portal helper uses Keychain service
`eai-installer-release-test-account`, with the protected test email as its
account label. It must not be substituted for the Test Mac administrator item.

The normal control path uses `prlctl capture` and `prlctl send-key-event` against
the guest framebuffer. The Parallels window therefore does not need to be
maximized, brought to the front, or exposed by minimizing other host windows.
This avoids fragile host-coordinate clicking while still keeping application
launches inside the verified Aqua session.

All macOS helpers source `scripts/parallels-macos-current-user.sh`. The shared
transport first proves that Parallels' `--current-user` channel is exactly
`testmac`, then independently proves the matching console user, non-root UID,
home directory, and Aqua `gui/<uid>` launch session. Updated Parallels Tools can
occasionally return exit status `255` with either of these exact complete lines:

```text
PrlJob_GetRetCode: Invalid argument. An invalid argument was passed.
PrlJob_GetResult: Invalid argument. An invalid argument was passed.
```

Only that status-and-exact-line combination is retried, at most three attempts
with two seconds between attempts. Other statuses, partial matches, and broader
`Invalid argument` text fail immediately with their original status and output.
Standard output and standard error are buffered separately beneath a private
caller-owned temporary directory; every caller removes that directory from its
exit and signal traps. Output from a discarded transient attempt is not copied
to the run log.

The retry transport is limited to read-only probes and shell blocks that begin
by removing/recreating their exact staging target, making the complete block
safe to repeat. Stateful actions without such a restart-clean boundary, and
persistent actions, use the already verified
`launchctl asuser <uid> sudo -H -u testmac` path with explicit `HOME`, `USER`,
and `LOGNAME`, and are launched once. This includes opening the portal or DMG,
downloading and mounting the release asset, and the CLI browser callback. The
normal application and E2E application retain their existing one-shot
launchctl-asuser bridges. App creation and the desktop E2E flow are never
blindly retried after an uncertain transport result.

On an abnormal macOS adapter exit, cleanup reads only the fixed guest receipt
and checks only the run's exact generated project path. A package checkpoint is
accepted only when `package.json` is a regular non-symlink file whose parsed
`name` exactly matches the generated package contract
`@eai-tools/<unique-test-app-name>`. The copied receipt and package
JSON stay in the private host work directory and are removed by the exit trap;
their contents are never printed or retained as evidence. Existing result and
app-state receipts are preserved, while `appCreated` is conservatively promoted
when any existing receipt, the guest receipt, or the exact local-project
checkpoint proves creation. The sanitised boolean proof is stored as
`macos-failure-checkpoint.json`. This recovery never lists or mutates tenant
resources.

The protected root copy that installs the already verified VS Code harness is
also issued once and is never placed on a text-matching retry loop.

The `prltoolsd` Automation approval for System Events is part of the snapshot
baseline; Safari Automation is not. If diagnostic Apple Events target Safari,
macOS may separately ask whether `prltoolsd` may control Safari. That approval,
Safari's developer menu, and its **Allow JavaScript from Apple Events** setting
are temporary dirty-guest instrumentation
for diagnosing portal requests. It is not required by the normal framebuffer
and keyboard path, must not be added to the approved snapshot, and must be
discarded by restoring the snapshot before a clean run.

Verify the baseline again after a cold guest restart and before taking or using
the snapshot: confirm the VM and ARM64 OS identity, `testmac` auto-login,
`--current-user`, the Aqua session, matching Parallels Tools, framebuffer
capture, keyboard navigation, and all three approved `prltoolsd` privacy
settings. A Parallels Tools or macOS update requires this restart verification
again before replacing the approved snapshot.

The post-restart control checks are read-only apart from sending a harmless
Escape key to prove keyboard injection:

```bash
prlctl status macOS
prlctl exec macOS /usr/bin/uname -m
prlctl exec macOS --current-user /usr/bin/id -un
prlctl exec macOS --current-user /usr/bin/defaults read -g AppleKeyboardUIMode
prlctl capture macOS --file /tmp/eai-test-mac-baseline.png
node scripts/parallels-input.mjs --vm macOS key escape
```

The expected values are `running`, `arm64`, `testmac`, and `3`, followed by a
non-empty guest screenshot and a successful key event. Also verify the active
Aqua `gui/<uid>` session, the matching Parallels Tools build, and the three
`prltoolsd` approvals in System Settings. The restart must reach `testmac`
without operator login.

The clean snapshot must not contain full Xcode, Apple Command Line Tools, a
functional Git installation, Homebrew, Node.js, npm, the EAI CLI, EAI Setup, an
EAI browser or CLI authentication session, or state from an earlier installer
run. In particular, `xcode-select -p` must not resolve a developer directory,
and the snapshot must not retain `~/.eai-setup`, `~/EAIReleaseTests`,
`/tmp/eai-setup-*`, a mounted test DMG, a copied EAI Setup application, or an EAI
Setup process. Do not invoke macOS's `/usr/bin/git` shim merely to test absence,
because doing so can open Apple's Command Line Tools installer.

The snapshot also intentionally contains no AI workspace. After the clean-state
checks pass, `scripts/prepare-macos-ai-workspace.sh` downloads the pinned official
Apple-silicon VS Code 1.136.1 archive inside the guest from Microsoft's stable
update endpoint. The helper requires the published SHA-256
`bd15a1b26cd10ba84900f7bd30f21d51eef268828e1e15a8ac1f97f99620bbe5`,
verifies the archive against Microsoft's response header, and verifies the
application's ARM64 executable, `com.microsoft.VSCode` bundle identifier,
Microsoft `UBF8T346G9` signing team, Gatekeeper assessment, and bundled Copilot
extension. It then installs only that harness dependency in `/Applications`.
This occurs before portal login and before EAI Setup is downloaded; it does not
provide Git, shell-visible Node.js/npm, the EAI CLI, or any EAI state.

The released EAI app must discover the resulting `vscode-copilot` surface and
perform its project handoff. In addition to the desktop receipt, the adapter
independently verifies the exact non-symlink project and scoped package name,
requires the signed-in user's VS Code process to be running, and stores
`macos-ai-workspace.json`, `macos-project-verification.json`,
`macos-ai-handoff-evidence.json`, plus `macos-ai-handoff.png` in the run
evidence. Safari is closed after the completed CLI callback, VS Code is
foregrounded, and the screenshot remains private until full-frame OCR confirms
the exact project and chat surface and rejects runtime account, tenant, token,
and callback strings. A rejected capture is never copied into the evidence
directory. This
proves the product's current launch contract. It does not claim that a GitHub
account signed in or that Copilot returned an answer; provider authentication is
outside this diagnostic installer gate.

### Test Windows clean-snapshot and login baseline

The controlled Windows guest is named `Windows 11`, its release-test user is
`eai-douglasross`, and its approved snapshot is `7-9-2026-clean`
(`{48921a89-eb72-430e-b4bf-a7b70d8bfaab}`). The adapter first validates its
runtime inputs and the host Keychain item's account metadata. It then restores
that exact snapshot disk with `--skip-resume` and performs a normal boot; it
never resumes the snapshot's saved memory image. This avoids carrying a stale
interactive session across Parallels or Windows updates.

Parallels can nevertheless restore the guest shell in Coherence rather than
exposing the normal VM console window. After the guest session stabilises, the
adapter first treats the exact visible VM window as conclusive already-windowed
success. Otherwise one macOS Accessibility request enumerates application
processes and identifies the VM-specific WinAppHelper only when menu-bar item 2
exactly names the configured VM and a **View** submenu contains **Exit
Coherence**. It retains integer Unix PIDs rather than AppleScript repeat
references, then re-resolves and revalidates the process. Exactly one candidate
and exactly one exit action are required. The action is invoked once and is
never retried; the adapter only waits for
`macos-parallels-window-id.swift` to prove the exact layer-zero, visible
`com.parallels.desktop.console` window. A process display name, executable path,
or hardcoded PID is never accepted as VM identity, and any ambiguity fails the
run. Once windowed, `show_vm_console` resolves the Parallels console process by
bundle identifier rather than the `prl_client_app` display name before selecting
the exact VM from its **Window** menu.

After every restore, Windows must automatically reach the approved user's
interactive desktop. The current-user Parallels channel must identify that user,
and the guest must report Windows 11 on ARM64, an interactive user session,
healthy Parallels Tools, and WinGet. The clean-state preflight then proves that
Git, Node.js, npm, the EAI CLI, VS Code, and both the installed application and
uninstaller registration for EAI Setup are absent. Finding any of them fails the
run. The snapshot must not be treated as a source of EAI browser or CLI
authentication and must not contain artifacts from an earlier release test.
App Execution Alias entries under `Microsoft\\WindowsApps` do not count as an
installed prerequisite. The clean-state check and later version probe accept
only regular, non-reparse `.exe` or `.cmd` files outside that alias directory;
WinGet itself remains the intentional exception because its supported command
is an App Execution Alias.
Microsoft Edge itself is part of the OS. After the clean-state check, the login
helper stops Edge and deletes the exact current user's disposable default
profile root at `%LOCALAPPDATA%\Microsoft\Edge\User Data`, then proves the path
is still absent before launching Edge. This reset happens inside the restored
test VM only. It ensures cached cookies, saved Microsoft or portal sessions,
password-save state, and first-run state cannot supply authentication to the
test. Any first-run screens recreated by Edge are handled by the fixed UI
allowlist. Before Edge starts, the helper waits for an HTTP 200 response from
the exact HTTPS sign-in URL inside the guest. If that fixed URL still shows
Edge's transient network-error page, UI Automation may invoke one unambiguous
**Refresh** action only after re-proving the exact origin and path.

The Windows portal login must be created afresh on every restored snapshot by
`scripts/login-windows-guest.sh`. It opens only the public
`https://www.enterpriseaigroup.com/sign-in` entry point in Edge with renderer
accessibility enabled. The current-user PowerShell control request uses local
legacy WMI `Win32_Process.Create` with `winsta0\default`, a process-only
environment, and the exact fixed command line. This provider-brokered browser
persists after the Parallels guest-exec request exits; the helper verifies its
returned PID, path, owner, session, and command line before UI Automation proves
the approved HTTPS origin. Multiline
PowerShell is sent to `powershell.exe -Command -` over standard input, but every
current-user invocation is opened through the proven
`--current-user cmd.exe /D /S /C powershell.exe` shim. On the controlled guest,
Parallels can reject a direct current-user `powershell.exe` session while the
same `cmd.exe` route reaches the exact interactive user, `UserInteractive=true`,
and session 1. LocalSystem PowerShell remains direct. The script is wrapped as
one `& { ... }` block and followed by the required trailing blank line. The
wrapper keeps error handling and `exit` behavior scoped to one complete script;
without the blank line, Windows PowerShell can leave its final multiline
statement unexecuted.

Parallels can also complete a request yet return an exact ambiguous
`PrlJob_GetResult` or `PrlJob_GetRetCode` line. The login helper retries that
condition only for the fixed HTTPS reachability read, the portal-readiness state
observation, and the read-only post-login `eai tenant list --format json`
verification. Each is limited to three attempts with two seconds between
attempts and requires exit status 255 plus one exact complete error line. Edge
launch, disposable-profile removal, every UI transition, protected
email/password entry, and the CLI login submission are one-shot. An ambiguous
result from one of those actions fails closed instead of replaying it. The fixed
read-only AI-handoff process observation has the same narrow retry. After an
installed-app launch has independently completed, a separate host-only
read-transport also covers only the replay-safe current-user and LocalSystem
gates: launch-receipt/process validation, the second executable hash, desktop
receipt polling and final fetch, exact-project proof, post-`AppActivate`
liveness, and exact application-process state. Each retries at most three
times, two seconds apart, and only for exit status 255 plus one exact complete
error line; the ordinary exact session-open retry remains available as well.
Static tests keep launch, stop, product handoff, cleanup, policy changes, and
every other material mutation on the non-replaying transports. Only the
idempotent focus action may repeat inside the bounded screenshot loop. The process helper contains the
fixed VS Code path/session/window query itself, accepts only its exact
ready-with-PID or not-ready sentinel, and cannot execute a caller-supplied script.
Successful not-ready observations may be polled while the window is opening;
malformed successful output, extra or partial transport text, and every other
failure status fail immediately. The tenant probe clears every response in shell
memory and never prints tenant data. Successful tenant transport with malformed
JSON, zero or duplicate exact memberships, or a membership mismatch is never
retried. Every browser transition still accepts only its exact origin-bound
destination control (for example, the Microsoft button after the public handoff
or the password field after **Next**), but that validation does not make an
ambiguous post-dispatch result replayable. Only the non-mutating readiness
observation uses the bounded ambiguous-result retry. No protected text entry is
part of any retry wrapper.

`scripts/windows-ui-action.ps1` scopes UI Automation to visible Edge elements
in the same Windows session and a fixed allowlist of exact names. It reads the
unique visible address bar only to verify the active HTTPS origin and path; it
has no action that sets arbitrary text or a browser value. The public hyperlink
must be **Continue with Email, Google, or Microsoft** at
`www.enterpriseaigroup.com/sign-in`. The next action must be **Sign in with
Microsoft** at `admin-portal.myenterprise.ai/login`. The Microsoft email, Next,
password, and Sign in stages must remain on
`enterpriseaiplatform.ciamlogin.com`. The password field is accepted only when
all three exact UI Automation properties match: Automation ID `i0118`, name
`Enter the password for {0}`, and `IsPassword=true`. More than one visible
approved match is an error.

Process and element-name scoping alone is not sufficient before protected text
is typed. The helper must also verify the expected origin at every transition
and before focusing either protected field. If it cannot prove that binding, it
must fail before entering the email or password. Email and password entry are
both mandatory on every run; there is no cached-authentication success branch.
If the portal is already authenticated after the disposable profile reset, the
run fails instead of accepting that session.

The EAI test account remains in the host Keychain service
`eai-installer-release-test-account`; only the service label is documented. The
helper checks that the Keychain account metadata matches the protected runtime
email before restoring the VM. When a field has been focused through the fixed
UI Automation action, it streams the runtime email and then the Keychain secret
directly to Parallels virtual-key input over standard input. Neither value is
placed in a command argument, clipboard, repository file, or evidence log. The
helper finally requires the exact authenticated page
`https://admin-portal.myenterprise.ai/platform/getting-started` with both
**Getting started** and **All apps** visible. After the released app installs
the CLI, it runs the exact `%APPDATA%\npm\eai.cmd` login flow with callback
output suppressed, then verifies the active identity and the configured
tenant's direct membership. A conforming adapter never accepts a saved guest
session as the authentication proof.

The clean snapshot intentionally has no AI workspace. Once the preflight has
proved that absence, `scripts/prepare-windows-ai-workspace.sh` installs the
pinned official ARM64 VS Code 1.136.1 SystemSetup bundle into
`%ProgramFiles%\Microsoft VS Code`. The privileged Parallels channel performs
the machine-wide install only after the current-user channel proves the expected
interactive account is signed in. It verifies Microsoft's response
SHA-256 and the pinned installer SHA-256
`57454d84d55f07b532fcf42295c57a5445054006be668ad7b1c19c9de9f68e31`,
valid Authenticode signatures from Microsoft Corporation, protected Program
Files ACLs, the exact application and CLI tree hashes, the ARM64 PE machine
type, the exact VS Code version and commit, and the bundled GitHub Copilot Chat
extension. This harness-only dependency is provisioned before EAI Setup is
downloaded and does not supply Git, shell-visible Node.js/npm, the EAI CLI, or
EAI state. Both the pinned metadata probe and exact redirect download use the
guest's native `curl.exe` with HTTPS-only policy and bounded retries; this
avoids Windows PowerShell's process-local DNS cache selecting a stale Azure
Front Door address after a snapshot restore.

The Windows installer sequence has three deliberately separate execution
phases:

1. The adapter computes the SHA-256 of the controller's published release asset,
   uses one bounded current-user bootstrap to stage and start a detached installer
   worker in the already verified interactive session, and proves that the exact
   guest target and every fixed worker path are absent. The bootstrap hashes the
   exact worker bytes while holding a no-write/no-delete read lock across launch,
   waits for a nonce-, hash-, PID-, process-start-, path-, and session-bound armed
   receipt, then exits and is reaped. A second bounded LocalSystem bootstrap uses
   the same locked-hash contract and local legacy WMI `Win32_Process.Create` to
   start a detached Defender guardian outside Parallels' monitored command job.
   It supplies a process-only environment with `EAI_*` values removed and
   verifies the returned process's exact SYSTEM owner, session 0, path, and
   command line. The bootstrap waits for its System-owned armed receipt, then
   exits and is reaped. LocalSystem downloads the exact
   `eai-setup-windows-arm64.exe` release URL once, verifies its SHA-256 against
   the controller, and writes the fixed, System-owned download-complete marker
   only after `Invoke-WebRequest` has returned. After the guardian independently proves the
   exact-file Defender allowance effective for that hash, LocalSystem writes a
   one-shot, System-owned, hash-bound launch signal. The detached current-user
   worker revalidates the guardian receipt owner, canonical
   non-reparse target, and SHA-256 while holding a read-only, no-write/no-delete
   file lock across creation of that exact NSIS installer process with `/S`.
   The returned process start target must equal the locked canonical path; when
   the short-lived bootstrap is still alive, its live image path must also
   match. This keeps a sub-second successful bootstrap from losing its launch
   proof merely because it exits before PowerShell can read the live process
   tuple. The worker waits for the exact process to exit before reporting
   completion. The adapter then locates the installed `eai-setup.exe` and
   records its SHA-256.
2. It launches the installed executable normally, without any E2E environment,
   and keeps the process alive while the visible application installs Git,
   Node.js 24 or newer, npm, and the configured current EAI CLI. Readiness also
   requires both visible **Sign in** and **Prerequisites installed successfully**
   text in the exact receipt-bound application window; pre-existing tools cannot
   make this check pass. The two independently recognised phrases are used because
   Apple Vision did not reliably retain the trailing brand text in **Sign in to
   EAI** on the Windows guest. Because a Parallels current-user version probe can foreground
   Windows Terminal, the OCR helper first revalidates the normal app's v5
   PID/start/path/session/owner/command-line receipt, minimizes only the signed-in
   user's Microsoft Windows Terminal window, foregrounds that exact EAI Setup
   window, and verifies the foreground handle. It never closes either process.
3. Only after the normal app has been stopped and CLI authentication verified
   does the adapter confirm the installed executable hash is unchanged and
   launch that same executable with the bounded E2E environment. LocalSystem
   stages one fixed, no-secret bootstrap script with an exact hash and protected
   ACL. Its one current-user `powershell -File` invocation carries only
   non-secret mode/hash/nonce arguments; the tenant ID and unique app name are
   the exact two raw stdin lines and are placed only in the launched child's
   environment. The application itself receives an empty argument list.

The fixed application bootstrap and its cleanup share a per-mode cancellation
file bound to mode, launch nonce, bootstrap SHA-256, and executable SHA-256.
LocalSystem owns that protected file; the expected interactive user can only
read it. The bootstrap validates it on entry and again immediately before
the local WMI call. Cleanup publishes cancellation before trusting any arm or
receipt. It never kills a still-live, command-line/path/user/session-bound
bootstrap because a synchronous WMI provider dispatch may still be in flight;
that condition immediately quarantines the VM with the cancellation binding
intact. Once bootstrap absence is proven, cleanup reloads arm, PID, and receipt
from disk. A complete receipt may terminate only its exact retained
PID/start/path/session/owner/command-line process tuple. Fixed artifacts are
removed only after that exact terminal proof.

The current-user `-File` transport has no general replay loop. An exit-255 exact
session-open error may be retried at most twice with a fresh nonce, but only
after the old nonce has been cancelled and LocalSystem returns the special
positive proof that no bootstrap was observed, no arm/PID/receipt or temporary
artifact existed, and no exact installed executable process existed. Exact
`PrlJob_GetResult` or `PrlJob_GetRetCode` errors remain ambiguous. They are
accepted only when independent LocalSystem validation proves a complete bound
receipt, a terminal bootstrap, and a surviving exact child; otherwise the
nonce is cancelled, never replayed, and the VM is quarantined for approved
snapshot restoration. Protected E2E stdin is therefore never sent twice on an
uncertain result.

The normal prerequisite launch requires one visible, on-screen Parallels
console window whose exact title is `Windows 11`. A command-line snapshot boot
can be headless, so the adapter activates the exact Parallels bundle and selects
that runtime VM name from Parallels' **Window** menu before the clean-state
check. The VM name is passed as AppleScript data, not interpolated into source.
The host then binds that window to the `Parallels Desktop` process and bundle ID
`com.parallels.desktop.console`, requires layer zero, nonzero visible bounds and
alpha, captures that window alone, and revalidates its window ID. The adapter
never falls back to a full-host-screen capture.

The approved snapshot keeps UAC enabled (`EnableLUA=1`) and keeps elevation
prompts on the interactive desktop (`PromptOnSecureDesktop=0`). Its normal
administrator behavior is `ConsentPromptBehaviorAdmin=5`. The clean-state
preflight proves all three values are DWORDs with those exact values and proves
that the release-test user is a local administrator. Immediately before the
normal prerequisite launch, the protected LocalSystem channel revalidates the
same baseline, temporarily changes only `ConsentPromptBehaviorAdmin` from `5`
to `0`, and reads back all three values. UAC remains enabled, and
`PromptOnSecureDesktop` is never changed. Microsoft documents these UAC policy
values and their behavior:
[User Account Control settings and configuration](https://learn.microsoft.com/windows/security/application-security/application-control/user-account-control/settings-and-configuration).
This controlled diagnostic setting lets the already-authorized Git and Node.js
prerequisite installers elevate without a consent dialog. A negative host-only
watcher treats any visible UAC consent dialog as a failure and never sends
approval input. The adapter restores `ConsentPromptBehaviorAdmin=5` immediately
after prerequisites are ready, before authentication or E2E work, and also from
its exit trap on every failure path. The run-bound receipt contains the nonce,
SHA-256 run binding, LocalSystem before/after readbacks, whether each mutation
occurred, and the final restoration proof. It also records
`approvalInputSent=false`, `uacApprovalCount=0`, `diagnosticOnly=true`,
`productionGate=false`, `uacConsentUiCovered=false`, and
`policyTemporarilyRelaxed=true`.

The consent policy is machine-wide during that bounded prerequisite window. A forced
host-process kill or host loss can bypass every process exit trap; if that
occurs, quarantine the disposable Windows VM and restore snapshot `7-9-2026-clean`
before any reuse. Every automated test already drops guest state and restores
that approved snapshot before beginning, which is the crash-recovery boundary.
If restoration or its receipt cannot be verified, the adapter writes a
sanitised quarantine diagnostic and retains the protected-change work directory.
The exit trap also preserves any existing normal/E2E arm and launch JSON before
it publishes cancellation or removes guest artifacts, even when independent
validation failed. While the temporary administrator policy is active, exact
bootstrap cancellation and child terminal proof run first under the still-live
negative consent-UI watcher. Only then does the trap stop that watcher and
restore `ConsentPromptBehaviorAdmin=5`; installer/Defender cleanup follows.
If exact bootstrap/child terminal proof is unavailable, the cancellation signal
and host diagnostics are retained, a sanitised detached-launch quarantine
receipt is written, and snapshot restoration is mandatory.

Each Git, Node.js, npm, and EAI CLI version process has a five-second bound; a
timed-out process tree and inherited output handles are closed instead of
blocking the harness. The complete readiness phase uses a 1,200-second
wall-clock deadline rather than an iteration count. No UAC approval action is
allowed in that window. The exact Parallels window remains visible so the
negative watcher can detect the generic UAC consent-dialog text. Any consent
dialog, missing console window, or failed monitor terminates the run; the
rejected frame is removed rather than retained as evidence.

The consent-UI inspection runs in a separate host-only watcher while the normal
app is preparing prerequisites. It uses no guest command or protected runtime
value and never sends input. The parent requires it to remain alive, stops and
reaps it before restoring the normal consent policy, preserves its sanitised
public-status log and zero-approval receipt, and also reaps it from the exit
trap on failure.

The installed application is never coupled to the lifetime of the attached
Parallels current-user command. Before dispatch, the fixed, protected Windows
PowerShell 5.1 bootstrap proves there is no exact pre-existing process, holds a
no-write/no-delete lock across executable hashing and launch, proves that the
bootstrap itself is in Parallels' job, and writes a nonce/hash-bound arm. It
then calls the local legacy-WMI `Win32_Process.Create` method with the exact
quoted canonical executable path and no application arguments. A
`Win32_ProcessStartup` instance supplies `winsta0\default`, Unicode plus new
process-group flags (`1536`), and a full process-only environment copied from
the bootstrap after every inherited `EAI_SETUP_E2E*` value is removed. Normal
mode adds none; E2E mode adds exactly the five required EAI Setup variables.
Protected values therefore remain out of arguments, guest files, and user or
machine environment state.

The provider may place the application in its own job, so child
`IsProcessInJob(..., NULL)` is recorded as an observed boolean rather than
required to be false. The release proof is instead the independent LocalSystem
validation performed after `prlctl exec --current-user` has returned: the exact
PID/path/hash/owner/session/start/command-line tuple must still be alive, and
its live job state must match the v5 receipt. The prelaunch collision scan,
post-return validation, receipt-bound window focus, liveness and stop probes,
and terminal cleanup all use the same Windows path-equivalence rule. It removes
only equivalent extended local (`\\?\C:\...`) or extended UNC
(`\\?\UNC\...`) prefixes after full-path resolution; the receipt-bound quoted
command line remains byte-for-byte exact. The bootstrap checks the exact
LocalSystem cancellation binding immediately before WMI and immediately after
WMI returns. Cancellation or any failed post-create validation terminates and
waits the exact returned PID only after rebinding its path, session, owner,
command line, and arm-to-identity-observation time window. WMI return is
recorded and ordered after the arm and before that observation, but it is not a
process-start upper bound: Windows can make the returned process ID available
before its `Process.StartTime` is observable. The v5 receipt therefore records
`processIdentityObservedAt` after reading the complete handle-backed tuple and
requires both process start and WMI return to precede that observation. An error or missing WMI PID
never authorizes a heuristic process scan, is never replay authority, and can
never produce a terminal-cleanup receipt.
See Microsoft's [Win32_Process.Create](https://learn.microsoft.com/windows/win32/cimwin32prov/create-method-in-class-win32-process),
[Win32_ProcessStartup](https://learn.microsoft.com/windows/win32/cimwin32prov/win32-processstartup),
and [Job Objects](https://learn.microsoft.com/windows/win32/procthread/job-objects)
contracts.
There is exactly one actual launch for each nonce: an ambiguous result is never retried. The only
transport retry is a fresh nonce after an exact session-open failure and the
positive LocalSystem proof that the prior nonce never reached a bootstrap,
artifact, or executable process; it is bounded to three transport attempts.
After the current-user
command has returned, LocalSystem proves the recorded bootstrap PID/start tuple
has exited while the exact application remains alive. If the numeric PID is
already occupied, it retains a handle to that process and accepts it only when
its creation time is strictly later than the receipt timestamp; Windows cannot
reuse the identifier until the old process terminates. The replacement is never
terminated. An unreadable identity, the original creation time, or any non-later
timestamp fails closed. This follows Microsoft's [process handles and identifiers
contract](https://learn.microsoft.com/windows/win32/procthread/process-handles-and-identifiers).
The adapter also validates canonical
receipt/PID/arm paths plus their owner and restricted ACL, and preserves
`windows-normal-app-launch.json`, `windows-normal-app-launch-arm.json`,
`windows-e2e-app-launch.json`, and `windows-e2e-app-launch-arm.json`. It also
writes a sanitized `windows-<mode>-transport-return.json` receipt proving that
the host transport returned before the live-child validation passed.

If launch stops between the arm and full receipt, the arm is evidence of an
ambiguous provider dispatch, not a process identity. Cleanup never terminates a
path/session/post-arm match in that state. Finite process absence is not proof
that a failed WMI provider dispatch cannot complete later, so cleanup retains
the LocalSystem cancellation signal and bound guest artifacts, returns
quarantine unconditionally, and requires immediate restoration of the approved
snapshot before any retry or reuse. Only a complete v5 receipt can enter the
exact terminal-cleanup path. Before the E2E child can mutate the tenant, the host also persists
a conservative exact-name remote-cleanup arm in `app-state.json`, so an
interrupted run cannot lose its cleanup target.

The 0.3.19 candidate is unsigned and Microsoft Defender may classify that exact
download as a potentially unwanted application. For this controlled diagnostic
only, the adapter bootstraps a detached, bounded guardian through Parallels'
protected non-current-user channel and proves that it is running as LocalSystem
with an administrator token. This avoids using interactive UAC for the
Defender-only operation and does not disable UAC. The protected channel receives only the fixed installer path, the public
release URL, and its already-public SHA-256. It never receives account, tenant,
app, or other protected runtime data. The guardian refuses to proceed if
Defender or PUA protection is disabled, if the still-empty target path is
already covered by an exact, parent, or wildcard exclusion, or if the later
downloaded file's path, regular-file status, or hash differs from the published
asset.

`MpCmdRun.exe -CheckExclusion` returns exit code 2 for an absent path on the
controlled Windows guest, rather than the exit code 1 produced by an existing,
non-excluded file. The guardian therefore creates an owned zero-byte probe at
the otherwise absent exact installer path with `FileMode.CreateNew`. Before the
exclusion is added, it proves that the probe is a canonical regular,
non-reparse, zero-length file, requires `MpCmdRun.exe` exit code 1, removes only
that owned unchanged probe in `finally`, and verifies that the target path is
absent again. Any probe collision, mutation, removal failure, or unexpected exit
code fails closed. `precheckProbeVerified: true` is required before the guardian
may arm the exclusion and is retained in the sanitised add evidence.

The guardian uses `Add-MpPreference -ExclusionPath` for the one fully qualified
installer path while that path is absent. It proves that this exact path is the
sole exclusion-set delta and records a LocalSystem-owned `awaiting-target`
receipt. A long-lived attached Parallels guest-exec can block every later guest
session, so neither long-lived worker remains attached to `prlctl`. Each bootstrap
is launched exactly once, remains attached only for its bounded bootstrap, and
is reaped before the next guest command. Before the Defender bootstrap emits its
acknowledgement, that already-open LocalSystem session waits for the guardian's
`awaiting-target` receipt and independently validates its canonical path, System
owner, hash and nonce binding, exact live PID/start-time/path/session tuple,
configured exact-file exclusion, and enabled Defender/PUA state. This removes a
redundant post-bootstrap LocalSystem polling loop that can contend with the live
guardian. Stale receipts cannot arm a run because they cannot satisfy those
checks. No new current-user command is opened from guardian arm through verified
guardian cleanup. After the arm acknowledgement, the one-shot download,
independent guest hash read, launch signalling, completion polling, and cleanup
signalling use short LocalSystem transports. Parallels may reject a direct
`powershell.exe` guest session while a `cmd.exe` session remains available, so
every protected streamed, one-shot, and bootstrap PowerShell command is started
through `cmd.exe /D /S /C powershell.exe`; `/D` disables command-processor AutoRun
hooks and the child inherits the same LocalSystem token. The current Parallels
Tools build rejects sufficiently long encoded command-line arguments, so all
payload-bearing current-user and LocalSystem scripts use `-Command -` instead.
The trusted here-document remains executable script, while the runtime payload
is UTF-8/base64 framed on stdin and installed as a data-only `StringReader` for
the existing `[Console]::In.ReadLine()` calls. It is never executed, placed in
argv, or written to a guest file. Fixed receipt reads that do not need PowerShell
use LocalSystem `cmd.exe type` directly. Calls may retry the exact
`PrlVmGuest_RunProgram` session-open error. The separately documented browser,
tenant, AI-process, and post-launch read-only wrappers may also retry only exit
255 plus an exact complete `PrlJob_GetResult` or `PrlJob_GetRetCode` line.
Substring matches, PowerShell errors, download failures, and mutations are never
replayed for that ambiguous result.

Only after the LocalSystem `Invoke-WebRequest` returns does that one-shot command
create and durably flush a fixed, non-secret temporary marker without overwriting
an existing path, explicitly set its owner to LocalSystem SID `S-1-5-18`, validate
its canonical path, regular-file type, owner, and exact contents, then atomically
move it without replacement to `eai-setup-defender-target-ready.signal` and
validate it again. This prevents the guardian from hashing a partially written
`-OutFile` target or observing a partial or incorrectly owned marker.
The guardian requires both the target and published completion signal to be
regular, non-reparse files, verifies the signal's fixed `download-complete`
value, verifies the canonical target path and published SHA-256, and only then
polls `MpCmdRun.exe -CheckExclusion` for Defender's eventually consistent
effective state. Guardian receipts are written through a temporary file, owned
by SID `S-1-5-18`, and atomically replaced. The ready receipt must be an actual
LocalSystem-owned regular file and include `receiptSystemOwned: true`,
`precheckProbeVerified: true`, `completionSignalVerified: true`,
`targetHashVerified: true`, and `mpCmdRunVerified: true`. Both the System launch
writer and detached current-user worker verify that owner and content before launch.

The launch and cancel controls are fixed one-shot files created with
`FileMode.CreateNew`, explicitly owned by SID `S-1-5-18`, bound to the published
SHA-256, and moved from a closed temporary file without overwriting an existing
marker. The detached current-user worker gives cancel priority, waits at most
300 seconds for launch, rehashes the exact target immediately before
`Start-Process`, and
waits at most 300 seconds for the exact installer process. On cancellation,
timeout, or an abnormal worker exit it will terminate only the PID it started,
and only after that PID's executable path still equals the verified installer;
it then verifies that the process is gone. No broad process-name termination is
allowed.

The installer process proof records the returned process ID and normalized path
from that process object's `StartInfo` separately from the optional live `Path`
and start/session tuple. Windows extended-path prefixes are normalized before
comparison, while the already-verified target remains held under its read lock.
Because the small NSIS bootstrap can exit between a state check and a following
property read, the worker uses the retained process handle's zero-time
`WaitForExit` result for that race. A pass requires the exact locked launch path
plus either a matching live path or a proven exit before live-path inspection;
an unreadable live process that has not exited still fails closed. The same
handle-based rule protects cancellation and finalization from stopping a reused
numeric PID.

The guardian confirms protection settings remain unchanged and has a 900-second
hard cleanup timeout. The host must first observe the worker's bounded completion
receipt, then signal that same protected guardian to run `Remove-MpPreference`
for the exact path. The cleanup marker is a closed `CreateNew` temporary file,
owned by LocalSystem, bound to the asset hash, guardian hash, and nonce, and then
published without overwriting; a matching System-owned temporary marker can be
promoted after an uncertain transport return. Only after both exact detached
worker process tuples have exited may the adapter open another current-user guest
command. The guardian
also removes the download-complete signal and its temporary marker on every
exit. The run continues only after the baseline exclusion set is restored, the
exact path is absent, `MpCmdRun.exe` reports it is no longer excluded, and
protection settings are unchanged. The add receipt timestamp must precede the
installer start, and installer completion must precede the removal receipt.

The clean-snapshot preflight rejects every fixed guardian and installer-worker
script, armed receipt, signal, completion receipt, and corresponding temporary
path. Exit and signal traps first request a hash-bound worker cancel, wait for its
terminal receipt and exact PID/start-time exit, then request guardian cleanup.
`defender_exclusion_pending` is cleared only after a `removed-verified` receipt
proves exact exclusion absence, baseline restoration, `MpCmdRun` not-excluded,
unchanged protection, and the exact guardian process exit. Unresolved workers
retain their private host work directory for diagnosis rather than starting
installed-app or other current-user activity.
If the installer worker arms but the Defender guardian never starts, cleanup
cancels that worker first and reads its fixed completion receipt through a
bounded LocalSystem `cmd.exe /C type` fallback. The host validates the exact
asset hash, worker hash, nonce, PID, session, and terminal installer state, then
uses one streamed PowerShell process-tuple check with a 30-poll bound. It does
not run the former 360-probe encoded-command loop or issue the exit wait twice.
Both terminal-receipt readers stop immediately when the atomically published,
no-replacement completion file is present but invalid. Retrying that immutable
receipt cannot repair it and previously delayed cleanup for the whole polling
bound.
If an ambiguous guardian bootstrap has no arm, add, or removal receipt, cleanup
publishes the nonce-bound guardian stop marker and returns quarantine
immediately; finite absence cannot prove a late provider dispatch impossible,
so it does not wait for or fabricate a removal receipt. The approved snapshot
must be restored before retry or reuse.
Sanitised evidence includes `windows-installer-bridge.json`,
`windows-defender-exclusion-add.json`,
`windows-defender-exclusion-remove.json`, and the two bounded bootstraps'
stdout/stderr logs. It records only hashes, non-secret process IDs, validated
start times, booleans, bounded timings, statuses, and error types; it contains no
credentials or tenant identifiers. Add and remove evidence must bind to the same
guardian worker hash, PID, and start time.

This mechanism never disables Defender, PUA protection, real-time protection,
or UAC and never adds a directory, wildcard, extension, or process exclusion.
The installer itself remains a current-user process. The allowance is explicitly
diagnostic-only and cannot satisfy a production release gate; a separately
blocked installed or temporary payload fails the test instead of broadening the
exclusion.

For AI handoff, the desktop receipt must pass and the adapter must independently
find the exact current-user `Code.exe` in the same interactive Windows session.
It stores `windows-ai-workspace.json`, `windows-ai-handoff-evidence.json`, and
`windows-ai-handoff.png` beside `vm-result.json` and `app-state.json`. The
workspace evidence records the pinned dependency's hashes, signatures,
architecture, and bundled Copilot surface. The handoff evidence records the
exact generated project, matching process, timestamp, and screenshot hash. As
on macOS, this proves the product's workspace-launch contract; it does not claim
that a GitHub account is signed in or that Copilot returned an answer.

Windows handoff capture is a bounded observation loop. Before each screenshot,
the adapter re-queries the one exact interactive `Code.exe` PID, safely restores
and foregrounds only that verified window, proves the actual foreground handle,
and revalidates the PID/path/session tuple. A transient Parallels capture or a
not-yet-painted frame may be retried; the product handoff and all remote
mutations are never replayed. Every captured frame is checked for protected
account, tenant, token, and callback text before its exact project/chat OCR can
qualify it for retention.

Application liveness is a tri-state read: the LocalSystem probe emits one exact
alive or not-alive sentinel after validating PID, canonical executable path,
interactive session, and owner. Transport failure or malformed successful output
is an indeterminate state and stops the run; it is never counted as evidence that
the process exited.

The generated Windows package must use the same scoped name contract as macOS:
`@eai-tools/<unique-test-app-name>`. Before preserving handoff evidence, the
adapter closes the completed Edge callback, foregrounds the already verified
VS Code window, captures privately, requires the exact project and chat surface
through full-frame OCR, and rejects protected runtime values and callback/token
text. A rejected framebuffer is never copied into the evidence directory.

Windows command output is sanitised before it is stored. CLI callback output is
discarded, and captured application logs redact the configured tenant ID,
tenant name, and test-user email. Before preserving any screenshot, review it
for account, tenant, callback, or other protected data; deterministically crop
or redact it and recompute its evidence hash if necessary. Do not retain an
unsanitised original in the evidence tree. A Windows diagnostic pass still
requires the manual cleanup and three independent absence checks described in
[Manual diagnostic app cleanup](#manual-diagnostic-app-cleanup); it is never a
production-release approval.

### Test Ubuntu clean-snapshot and evidence baseline

The controlled ARM64 Linux guest is named `Ubuntu 24.04.3 ARM64`, its release
test user is `parallels`, and its approved snapshot is `28-8-2026`
(`{00f4cb1b-09ea-4f06-b41b-3d1d2085e8c7}`). The adapter restores that exact
snapshot and selects only the expected user's active, local, non-root `seat0`
graphical session through `loginctl`. Every user command is then launched with
the verified session's `XDG_SESSION_ID`, X11 or Wayland display, runtime
directory, D-Bus address, and user identity. A root GUI workflow or an
unverified Parallels current-user session is not accepted.

Before the released application runs, the snapshot must have no Git, Node.js,
npm, EAI CLI, EAI Setup, VS Code, EAI authentication state, generated project,
or earlier release-test state. The pinned VS Code harness is provisioned only
after this absence proof. The harness records the released-product prerequisite
contract but does not predict the result of the product's later `apt-get
update`, refresh apt indexes itself, add a repository, install, upgrade, or
repair those prerequisites. After the product runs, package ownership is proved,
Node.js must be version 24 or newer, npm must be available with a parseable
version, and the Ubuntu diagnostic contract requires EAI CLI `3.15.10` exactly
from both the executable and its package metadata.

The approved Node.js 24 repository can supply npm from the installed `nodejs`
package rather than a separate Debian package named `npm`. The adapter therefore
executes the exact `/usr/bin/npm`, resolves its target, requires that target to be
a root-owned non-writable regular file owned by the fully installed `nodejs`
package, and records the npm version and provider package. It deliberately does
not use `dpkg-query -W npm`, which rejects this valid provider layout.

The published `eai-setup-ubuntu-arm64.deb` is still downloaded inside the guest
from the exact prerelease URL and compared byte-for-byte by SHA-256 with the
controller download. Package name, version, ARM64 metadata, dpkg ownership, and
the installed AArch64 executable are independently verified. The prerequisite
contract proof cannot substitute for or weaken any release-asset check.

Portal authentication starts with an absent, disposable Firefox profile. The
CLI callback is launched with `BROWSER` bound to a private wrapper inside that
same exact profile, and the adapter verifies both before and after login that a
user-owned process has an allow-listed Firefox executable and process name,
carries the profile, and has the verified graphical environment's
`XDG_SESSION_ID`, runtime directory, D-Bus address, and display values. This is
an environment binding and does not claim independent logind cgroup membership.
Callback output is discarded. The profile is stopped and removed before final
evidence is retained.

Immediately before the E2E application can mutate the tenant, the host writes a
durable, exact-app-name cleanup arm. It conservatively records
`appCreated: true`, `cleanupRequired: true`, and `creationProven: false`; this is
a cleanup obligation, not a claim that creation was already observed. The arm
is written before product launch, so a guest crash or lost Parallels transport
cannot leave an untracked exact-name orphan. While the product runs, the adapter
queries only the exact `tenant-vertical-enrollment` key from inside the exact
generated project. Both the checkpoint and final query encode the CLI 3.15.10
canonical scalar filter `{"verticalKey":"<exact-app-key>"}` and require its
`{resources,totalDocs}` JSON envelope; an operator-shaped `equals` object is not
accepted by the contract. A valid remote checkpoint binds one record ID hash,
source, creation time within this run, exact match count, and empty embedded
child fields. Query failure or ambiguous output retains the conservative cleanup
arm and is recorded as uncertain; only a valid remote checkpoint or a product
receipt upgrades `creationProven`.

Final app validation repeats the exact filtered query from the generated
project cwd and requires the same opaque record-ID hash. Project verification
requires the exact scoped package name, regular non-symlink sources and local
TypeScript compiler, and a no-emit compile. AI handoff independently binds a
user-owned `/usr/share/code/code` process to the exact project through
`/proc/<pid>/cwd`; its NUL-delimited argv must also be readable and is inspected
without being retained. The exact project argument is recorded as a boolean
because VS Code can consume the project argument and retain only the project
cwd. Sanitised evidence includes `ubuntu-prerequisite-contract.json`,
`ubuntu-remote-app-checkpoint.json`, `ubuntu-orphan-cleanup-evidence.json`,
`ubuntu-project-verification.json`, and `ubuntu-ai-handoff-evidence.json`.

The important boundary is that the work happens inside the guest. A host-side
script that only checks whether a file exists is not a valid VM adapter. In a
CI environment, the same contract can be implemented by an ephemeral Windows,
macOS, or Ubuntu runner instead of Parallels.

The release team owns the machine names, Parallels or runner connection,
browser automation, and protected credentials. These values belong in the
release environment or OS keychain, never in this repository or a public
release asset.

The controller requires an OS-specific command for every guest. Do not use a
shared host command: download, installation, authentication, tenant, and app
steps must happen inside the named clean guest.

Each `EAI_VM_<OS>_COMMAND` must be one absolute, canonical path to an executable
regular file. Symlinks, relative paths, inline arguments, pipelines, `&&`
chains, environment assignments, and other shell programs are rejected. Put
all multi-step logic in the executable wrapper. The controller invokes that
file directly (without a shell) so the tracked child is the adapter itself and
`SIGINT`/`SIGTERM` reaches its EXIT traps. Runtime environment variables are
inherited normally.

Configure the commands in a protected shell or release runner:

```bash
export EAI_VM_DRIVER=command
export EAI_HARNESS_TENANT_ID="<production-test-tenant-uuid>"
export EAI_HARNESS_TENANT_NAME="EAI Test Harness"
export EAI_HARNESS_USER_EMAIL="<protected-test-user-email>"
export EAI_HARNESS_PUBLIC_API_URL="https://api.au.myenterprise.ai/public"
export EAI_VM_MACOS_COMMAND="$PWD/scripts/run-macos-guest-test.sh"
export EAI_VM_WINDOWS_COMMAND="$PWD/scripts/run-windows-guest-test.sh"
export EAI_VM_UBUNTU_COMMAND="$PWD/scripts/run-ubuntu-guest-test.sh"
./release.sh publish 0.2.0
```

The PublicAPI origin defaults to the Australian endpoint and may be changed
only to the corresponding approved Canadian or European HTTPS endpoint. The
production path defaults to, and refuses any override of, the repository's
canonical `scripts/run-v4-app-deprovision.sh`; no tenant identifier or
credential is stored in the repository.

The repository includes Parallels command adapters for the controlled ARM64
guests used by the release team:

- `scripts/run-macos-guest-test.sh`
- `scripts/run-windows-guest-test.sh`
- `scripts/run-ubuntu-guest-test.sh`

Their default VM names and snapshot IDs match the protected release host. They
may be overridden with `EAI_<OS>_VM_NAME` and `EAI_<OS>_SNAPSHOT_ID`. Every
adapter validates all required runtime inputs before switching a snapshot, so a
missing tenant ID or release asset cannot reset a guest. The macOS adapter uses
the existing signed-in-user DMG preparation boundary. The Ubuntu adapter finds
the active graphical session with `loginctl`, verifies GDM automatic login is
configured for the expected non-root user, and launches the application inside
that user's X11 or Wayland session even when Parallels' current-user
authentication is not available. Configure the guest once, then capture that
state in the approved snapshot so every restore boots directly to the saved
test user.

Before launching the installer, the macOS adapter opens the public
`https://www.enterpriseaigroup.com/sign-in` page, activates its visible protected
handoff to the Enterprise AI admin portal, and verifies that the configured
tenant becomes visible. It must not open the admin portal directly. The clean
snapshot contains no saved EAI browser or CLI session. On a
fresh restore, the adapter enters the protected test email and streams the
password from the host Keychain directly to the virtual-keyboard helper over
standard input. It does not place the password in command arguments, clipboard
contents, repository files, logs, or evidence. After the released installer
supplies Node.js and the EAI CLI, the adapter refreshes the CLI login and
verifies both the active test identity and tenant.

The macOS helper fails closed if Safari reaches the authenticated portal before
the scripted credential flow or if Microsoft presents a password page before
the helper has entered the configured test email. Both observations indicate
reusable browser or remembered-account state in the restored snapshot. A valid
run must traverse the public handoff, enter the protected email, then enter the
Keychain password. Safari's save-password prompt and Microsoft's
stay-signed-in prompt remain supported only after those two mandatory stages.

For diagnostic validation with manual cleanup, invoke the controller once per
guest so cleanup can be confirmed before the next snapshot is touched:

Begin from an unlocked macOS desktop. The protected
`scripts/run-release-e2e-from-keychain.sh` launcher acquires a
`caffeinate -dimsu` assertion for the controller's lifetime so the Parallels window and UAC
evidence monitor remain visible. It checks `IOConsoleLocked` and refuses before
restoring any snapshot when the host is already locked; it cannot unlock the host itself.

```bash
export EAI_VM_DRIVER=command
export EAI_VM_MACOS_COMMAND="$PWD/scripts/run-macos-guest-test.sh"
export EAI_VM_WINDOWS_COMMAND="$PWD/scripts/run-windows-guest-test.sh"
export EAI_VM_UBUNTU_COMMAND="$PWD/scripts/run-ubuntu-guest-test.sh"

./release.sh diagnostic-e2e 0.3.19 --tag eai-setup-test-v0.3.19 --vms macos
# Delete and verify the uniquely named test app before continuing.
./release.sh diagnostic-e2e 0.3.19 --tag eai-setup-test-v0.3.19 --vms windows
# Delete and verify the uniquely named test app before continuing.
./release.sh diagnostic-e2e 0.3.19 --tag eai-setup-test-v0.3.19 --vms ubuntu
```

This sequence remains diagnostic evidence: manual deletion does not satisfy the
production gate's required V4 cleanup receipt.

### Manual diagnostic app cleanup

After each single-VM diagnostic run, clean up only the app key recorded in that
run's `app-state.json`. In the authenticated admin portal, open **All apps**, use
the app-actions menu beside **Create app**, choose **Manage app**, and locate the
single row whose app key and display name exactly match the receipt. Choose
**Delete <exact display name>**, type the exact app key in the confirmation
field, and choose **Delete permanently**. Capture the exact-app view and typed
confirmation. Never delete by row position, partial name, or a non-unique
display name.

Windows has a protected two-phase helper for this exact portal path. It accepts
no app-name argument. The app key must match the run ID independently in the
controller report, `windows/app-state.json`, and `windows/vm-result.json`. A
successful guest finalizer preserves `cleanupRequired: true` and
`cleanupRequested: true` in `app-state.json` whenever it records
`appCreated: true`; those fields are part of the protected helper contract, not
advisory metadata. A
failed controller run is accepted only when the report's one Windows machine,
app state, and VM result all identify that exact created app, both guest receipts
still request cleanup, and creation is independently checkpointed. Current
builds write an exact-app-name `eai.setup.e2e-app-created.v1` desktop checkpoint
as the first awaited action after `run_bootstrap` returns `app_created: true`.
It marks prerequisites, authentication, tenant, and app as passed while leaving
project and AI handoff not run. The same Tauri command writes both that
checkpoint and the later terminal receipt through a create-new temporary file
in the destination directory, flushes and synchronizes it, and atomically
replaces the receipt (`MoveFileExW` with replace/write-through on Windows).
Relative paths, symlink destinations, and non-regular destinations are rejected.
The checkpoint contains the run-derived app name but no tenant or credential
data.

The already-published 0.3.19 candidate predates that desktop checkpoint. If it
exits after app creation, the Windows adapter records its read-only exact local
project/package match in both host receipts. The cleanup helper accepts that
legacy signal only together with the run-bound prelaunch cleanup arm. Its guest
helper must then revalidate the fixed project path, all non-reparse ancestors
and generated-project markers before any CLI call, and must resolve exactly one
run-created, source-verified remote enrollment before the guarded resource
fallback is available. A conservative arm alone, or an app check that is not
passed without the paired exact-project checkpoint, remains ineligible.

Before any
guest CLI query or mutation, the helper derives (never accepts) the fixed path
`C:\Users\Public\EAIReleaseTests\<exact-app-key>`. It rejects a missing or
reparse-point directory anywhere in that path, reparse-point marker files, a
resolved parent mismatch, a package name other than exact
`@eai-tools/<exact-app-key>`, missing `build`/`typecheck` scripts or EAI
dependency, a non-default `.eai-manifest.json`, or a missing generated
`src\eai.config\object-types.ts`. Marker hashes are frozen and all checks are
repeated before every CLI call; the helper then changes to and verifies that
exact FileSystem working directory. No environment variable or caller argument
can redirect the project root.

Windows PowerShell 5.1 does not preserve the JSON quoting needed by the CLI's
`--where` argument. The helper therefore performs a private read-only bounded
enumeration of `tenant-vertical-enrollment` records inside the guest, requires
`totalDocs` to equal the returned count and remain below the 1000-record cap,
and applies a case-sensitive exact app-key filter in memory. It still requires
exactly one `eai-cli` enrollment created during the run with empty services,
workflows, and setup-record child state. Unrelated records are never copied to
the host or evidence. The sanitized target receipt stores only the selected
display name, opaque resource-ID hash, zero-child assertions, and source-receipt
hashes.

```bash
scripts/run-windows-portal-cleanup-ui.sh \
  --run-dir artifacts/release-e2e/0.3.19/<run-id> \
  --prepare-delete
```

The prepare action freshly authenticates the portal and CLI, opens only
`https://admin-portal.myenterprise.ai/platform/apps`, and rejects a query,
fragment, alternate port, origin, or path. Windows UI Automation must find one
exact **Create app** button, identify its adjacent split-button arrow from the
shared UI tree and bounding rectangles, require that arrow's UI Automation
`ExpandCollapsePattern`, expand it, and invoke exact **Manage app**. The helper
then proves whether that exact surface contains a structurally bound search
field. It searches the receipt display name when the field exists; when the
unique Manage app modal proves the current search-free layout, it types nothing
and proceeds directly to bind exact **Delete <display name>** to a single row
that also contains the exact app key. It focuses the bound confirmation edit;
`parallels-input.mjs` types the key as virtual keyboard input. The UI helper
only reads the resulting field value to prove an exact match. The prepare action
stops with **Delete permanently** visible and enabled and records
`windows-portal-delete-prepared.json`; it does not invoke deletion.
During that non-destructive phase it also stages run-bound copies of
`windows-ui-action.ps1` and `windows-interactive-exact-delete.ps1` beneath the
current user's local application-data directory. Both files and every staged
directory are rejected if they are reparse points. Their host and guest SHA-256
hashes are checked and bound into the prepared receipt.

During preparation, only the read-only exact enrollment query and the
`wait-platform-apps`, `probe-manage-app-search`, and `assert-delete-ready` state observations may retry an
exit-255 exact `PrlJob_GetResult` or `PrlJob_GetRetCode` transport result, at
most three times and two seconds apart. Address-bar navigation, URL/app-key
typing, menu and dialog transitions, search focus, and row-delete selection are
each issued once. An ambiguous result from any of those steps aborts preparation
without replay. The permanent-delete action below remains separately one-shot.

Immediately before the irreversible action, obtain explicit confirmation for
that exact displayed app, then run the separate one-shot action:

```bash
scripts/run-windows-portal-cleanup-ui.sh \
  --run-dir artifacts/release-e2e/0.3.19/<run-id> \
  --invoke-delete-permanently
```

The prepared receipt expires after 30 minutes. The final UI action is never sent
through `prlctl exec`: that channel can execute on the Parallels service desktop
even with `--current-user`, and a successful UI Automation
`InvokePattern.Invoke()` return does not prove that Edge processed the action.
Instead, the host re-verifies the staged hashes through a read-only call, injects
Windows+R directly into the logged-in guest desktop once, and launches the
run-bound interactive worker. The worker revalidates its own hash, the shared UI
helper hash, exact dialog, exact typed key, exact focused button, exact expected
guest username, non-System identity, positive interactive session ID, and an
Explorer shell in that same session. Explorer and Edge owner SIDs must match
that user. The address bar, dialog, field, and button must share one top-level
Edge HWND, PID, and session. Immediately before mutation the worker re-fetches
the same button/runtime ID and HWND, requires that HWND to be foreground, and
invokes only that button with UI Automation `InvokePattern`; global keyboard
input is forbidden. It reports success only after the exact
confirmation dialog is absent for twelve consecutive 250 ms observations
(three continuous seconds).
The Windows+R launch, command typing, and final button activation are
never retried. A missing result, a malformed result, or a result in which the
dialog remains visible writes `windows-portal-delete-invocation.json` with
mutation state `uncertain`; verify exact absence instead of invoking it again.
Even a successful invocation is recorded as `invoked-unverified` and does not
prove cleanup until Resource API, CLI, and refreshed portal absence checks all
pass.

#### One permitted no-effect recovery attempt

There is one hard-coded recovery path when that first invocation returned exit
status zero and was recorded as `invoked-unverified`, but a later fresh
verify-only operation still finds exactly one case-sensitive match through both
the bounded enrollment Resource API query and `eai app list`. The verification
must succeed on both channels at least 60 seconds after the first invocation,
measured with host receipt modification times; guest semantic timestamps are
validated separately.
An uncertain first invocation, a failed query, zero, mixed, or duplicate counts,
or an already verified deletion is not eligible.

Prepare the exceptional second attempt with:

```bash
scripts/run-windows-portal-cleanup-ui.sh \
  --run-dir artifacts/release-e2e/0.3.19/<run-id> \
  --prepare-delete-attempt-2
```

This preserves all first-attempt files and creates the immutable
`windows-portal-delete-attempt-1-still-present.json` gate. It authenticates the
portal and CLI afresh, re-queries the exact enrollment, and requires its opaque
resource-ID SHA-256, canonical creation timestamp, display name, source, run
provenance to match the original target while binding the fresh target to the
current protected tenant-ID SHA-256. Zero-child proof
comes from independent complete bounded `vertical-service-activation` and
`vertical-product-config` queries filtered by case-sensitive exact
`data.verticalKey`; missing enrollment fields never count as zero. A migration
exception permits the immutable target receipt produced by the earlier 0.3.19
helper to participate only as identity and provenance history. That exact legacy
shape contains `embeddedChildFieldsEmpty` and the three legacy zero-count fields,
but no `childQueries`; those fields are explicitly classified as
non-authoritative and are never used as the attempt-2 deletion-safety gate. The
original target and first invocation also predate the tenant fingerprint and are
not rewritten. Attempt 2 can advance to portal UI preparation only after its new,
tenant-bound query proves complete bounded, exact zero results from both current
child object types. The legacy/modern classification, the fact that legacy counts
were not trusted, and the successful fresh authoritative gate are carried through
the still-present, target, prepared, pre-invocation, and invocation hash chain.
Query failure, incomplete pagination/evidence, or a nonzero fresh result stops
before portal input or worker staging. It then prepares the exact portal row and
typed-confirmation dialog but
does not delete anything. The new target and preparation receipts are
`windows-portal-delete-attempt-2-target.json` and
`windows-portal-delete-attempt-2-prepared.json`. The preparation expires after
ten minutes and prints a random 64-hex confirmation nonce; only its SHA-256 is
stored in evidence. Prepare and invoke each hold a per-run exclusive directory
lock. A crash-left lock is never removed automatically: inspect the receipts and
resolve it manually so a suspected in-flight mutation cannot be replayed.

Obtain renewed action-time confirmation for the exact displayed app after that
preparation completes. Only then pass that nonce to the explicit second action:

```bash
scripts/run-windows-portal-cleanup-ui.sh \
  --run-dir artifacts/release-e2e/0.3.19/<run-id> \
  --invoke-delete-attempt-2 \
  --confirmation-nonce <64-hex-nonce-from-the-current-preparation>
```

Immediately before arming, the helper performs another live exact enrollment
and child-query set, repeats every identity, tenant fingerprint, and zero-child comparison, reasserts the exact
ready dialog, and re-verifies the staged interactive worker. The sanitized
proof is `windows-portal-delete-attempt-2-preinvoke.json`. It then creates
`windows-portal-delete-attempt-2-invocation.json` exclusively with state
`armed-uncertain` before injecting Windows+R or any other destructive input.
The ten-minute expiry is checked again under the lock immediately before this
arm. The receipt is updated to `invoked-dialog-closed-unverified` only when the one
interactive worker launch proves the expected user/session, owner SIDs, same
foreground Edge HWND/PID/runtime IDs, scoped InvokePattern call, and three
seconds of continuous dialog closure. A crash, malformed result, ambiguous
transport, or open/reappearing dialog remains `uncertain`.

The second action can never be replayed: the exclusive arm blocks another
preparation or invocation regardless of its outcome. There is no numeric
attempt option and no attempt-3 command. After attempt 2, run only read-only
absence verification. A `0/0` API/CLI result still requires refreshed portal
absence evidence; any other result stops for diagnosis. On `0/0`, the diagnostic
cleanup helper validates the complete attempt-2 hash chain and invocation state,
preserves the original 1/1 verification, writes immutable
`windows-portal-delete-attempt-2-verification.json`, and creates the standard
sanitized `manual-cleanup-receipt.json` plus
`manual-cleanup-verification.json` with portal verification pending. That allows
the normal `--finalize-portal` step after the exact-name **No apps match**
evidence is captured. A changed receipt hash or any weaker invocation state
cannot produce those completion receipts. A successful hardened attempt 1
followed directly by `0/0` uses the same bridge through immutable
`windows-portal-delete-attempt-1-verification.json`. Finalization re-hashes the
immutable invocation/verification chain and tenant fingerprint before accepting
portal absence evidence.

The portal accessibility contract still needs one live discovery pass after a
portal UI update. The current helper expects the Manage-app search edit to have
one of the fixed exact **Search**, **Search app(s)**, **Search by name or key**,
or **Search app(s) by name or key** variants, optionally with a literal ASCII or
Unicode ellipsis, structurally bounded beneath one non-invokable **Manage app**
or **Manage apps** heading. It also expects
the row control and dialog heading to expose **Delete <exact display name>**,
the dialog to expose either the exact app key or one of four fixed exact
**Type/Enter <app key> to confirm[: ]** variants, and the final button to expose
**Delete permanently**. Any label or UI-tree change fails
closed before the permanent action; update the allow-list only from a captured
authenticated UI Automation tree, never by adding partial-name matching or
coordinate clicks.

A known draft-app failure is a `404 Resource not found` from the V4
`deletion-plan` endpoint. The CLI can report the same condition as a missing
unambiguous ownership manifest. This is not proof that the app is absent or
deleted. Preserve a sanitised failure record and do not broaden the deletion
target.

For this diagnostic gate only, a `tenant-vertical-enrollment` Resource API
fallback is permitted after that exact V4 failure, and only when the run's exact
app key resolves to one enrollment record, the record was created by this run,
and it has zero services, workflows, and setup records. Abort if the match count
is not one, ownership is ambiguous, or any child count is non-zero. Delete only
that resolved type and opaque record ID; never enumerate and bulk-delete:

```bash
eai resources delete tenant-vertical-enrollment <opaque-record-id> --force --format json
```

This fallback is manual diagnostic cleanup, not the approved V4 cascade and
never production-release evidence. Verify absence independently in all three
places: the Resource API reports the exact opaque record deleted, a fresh
`eai app list --format json` has zero exact app-key matches, and a refreshed
authenticated **All apps** search has zero exact display-name matches. Store
sanitised `manual-cleanup-receipt.json`,
`manual-cleanup-verification.json`, `manual-delete-confirmation.png`, and
`manual-cleanup-verified-absent.png` files under the run's per-VM evidence
directory. Do not restore or start the next VM until all three checks pass.

The guest adapter is responsible for starting or resetting its clean VM,
opening the release URL, downloading the asset inside the guest, running the
native installer, completing and verifying browser sign-in, selecting the harness
tenant, creating the test app, and verifying the generated project. It must report
every required check and write the app-state receipt immediately after app
creation. The app-state receipt is required so cleanup still works if the
guest crashes after creating the app but before writing its final result:

```json
{
  "appName": "test-macos-run-id",
  "appCreated": true
}
```

The final result must confirm that cleanup was requested even if a preceding
step failed:

```json
{
  "status": "passed",
  "vm": "macos",
  "appName": "test-macos-run-id",
  "projectPath": "/guest/path/to/project",
  "appCreated": true,
  "cleanupRequested": true,
  "checks": {
    "download": "passed",
    "installer": "passed",
    "prerequisites": "passed",
    "authentication": "passed",
    "tenant": "passed",
    "app": "passed",
    "project": "passed",
    "aiHandoff": "passed"
  }
}
```

Every check is required. A green `/health` or a successful installer process
is not enough. The controller stores command output in the evidence directory
and redacts configured credentials, the harness tenant ID, and the test-user
email before writing it. Guest adapters must not print tenant IDs, account
data, or credentials.

## Real app cleanup

The cleanup command must use the approved V4 app-deprovision API. It receives:

- `EAI_DEPROVISION_TENANT_ID`
- `EAI_DEPROVISION_TENANT_NAME`
- `EAI_DEPROVISION_APP_NAME`
- `EAI_DEPROVISION_CONFIRM`
- `EAI_DEPROVISION_APP_CREATED` (`1` or `0`)
- `EAI_DEPROVISION_RUN_ID`
- `EAI_DEPROVISION_RECEIPT_FILE`
- `EAI_DEPROVISION_API_ORIGIN`

The repository's `scripts/run-v4-app-deprovision.sh` adapter invokes the
released EAI CLI command directly:

```text
eai app delete <app-key> --tenant-id <tenant-id> --confirm <app-key> \
  --non-interactive --format json
```

It accepts only the exact current `eai.app-deletion-receipt.v1` key and type
contract exercised by EAI CLI 3.15.10: the app and tenant must match the
protected inputs, status must be `deleted`, `verified` must be true, the
64-character plan and ownership-manifest hashes must match, the exact
`resourceAPI` cascade step must be verified with a positive integer deletion
count, and `retained.sharedObjectTypes` must be a unique string array. Unknown,
missing, or differently typed version-one fields fail closed. The raw
response is held only in a private temporary directory and is never copied to
release evidence.

After deletion, the adapter independently runs exact filtered, read-only V4
resource queries for all three current manifest-owned ResourceAPI types:
`tenant-vertical-enrollment`, `vertical-service-activation`, and
`vertical-product-config`, each with the generated `verticalKey`. Every query
must return an empty array, `totalDocs: 0`, no next cursor, and an unambiguous
first/only page. Only then does it atomically write the controller receipt. The
protected tenant ID is checked exactly but represented in retained evidence
only by a SHA-256 fingerprint:

```json
{
  "schemaVersion": "eai.release-e2e.cleanup-receipt.v1",
  "status": "verified",
  "source": "public-api-v4",
  "operationId": "opaque-server-operation-id",
  "appName": "test-macos-run-id",
  "appCreated": true,
  "confirmation": "test-macos-run-id",
  "tenantMatch": "verified",
  "tenantIdSha256": "64-character-sha256",
  "apiOriginSha256": "64-character-sha256",
  "eaiVersion": "3.15.10-or-newer",
  "planHash": "64-character-ownership-manifest-hash",
  "ownershipManifestHash": "same-64-character-ownership-manifest-hash",
  "deletedRecords": {
    "exactAppEnrollmentMatchesAfter": 0,
    "exactFilteredTotalAfter": 0
  },
  "deletedResources": {
    "serverReceiptSchemaVersion": "eai.app-deletion-receipt.v1",
    "resourceApiDeletedCount": 3,
    "resourceApiStep": "verified",
    "retainedSharedObjectTypes": []
  },
  "absenceCheck": {
    "method": "v4-filtered-manifest-owned-resource-queries",
    "resourceTypes": [
      "tenant-vertical-enrollment",
      "vertical-service-activation",
      "vertical-product-config"
    ],
    "filterField": "verticalKey",
    "exactMatchesByType": {
      "tenant-vertical-enrollment": 0,
      "vertical-service-activation": 0,
      "vertical-product-config": 0
    },
    "allManifestOwnedResourceTypesAbsent": true
  },
  "cleanupVerified": true
}
```

The controller marks the production release gate failed if cleanup is missing,
unverified, names another app, or does not match whether the guest created an
app. Both `deletedRecords` and `deletedResources` must be non-empty plain JSON
objects; empty objects, arrays, scalars, and strings are not deletion evidence.
A missing, malformed, non-regular, symlinked, or
wrong-app `app-state.json` never skips cleanup after a VM attempt. Instead, the
controller marks the run failed and conservatively invokes cleanup for the
run's exact generated app name. The diagnostic path is intentionally the only
exception to verified deletion, and its report cannot be used as production
release evidence.

The adapter resolves one canonical executable EAI CLI, requires at least the
`eai-cli` version pinned in `installer-manifest.json` (currently `3.15.10`), and
binds every command to the approved PublicAPI origin. The adapter deliberately
has no draft-enrollment deletion,
generic Resource API mutation, admin-portal, or diagnostic fallback. A missing
ownership plan (including a draft app for which `deletion-plan` returns 404), a
non-zero CLI exit, a mismatched or incomplete deletion receipt, any still-visible
manifest-owned record, pagination ambiguity, or a failed absence query produces
no success receipt and fails the production gate closed. The platform must therefore
issue an ownership manifest for every app created by the production E2E path;
the diagnostic cleanup tools cannot substitute for that platform contract.

Receipt publication is fail-closed: the adapter creates a private temporary
receipt and uses an atomic no-overwrite hard link. A path created between the
last safety check and publication causes failure and is never overwritten. The
controller opens the result with no-follow semantics, reads the same descriptor,
sanitizes it into a private atomic replacement, and validates the schema,
tenant/API fingerprints, ownership-plan hash, deletion counts, and independent
absence proof before accepting cleanup.

Credentials must be injected by a protected runner or OS keychain. They must
never be committed, printed, or included in GitHub release assets.

## Evidence

Each run writes `release-e2e.json`, per-VM output, host and guest asset hashes,
platform workspace and handoff evidence, and cleanup receipts under
`artifacts/release-e2e/<version>/<run-id>/`. The public release page contains
installers only; tenant identifiers and credentials stay out of the release
notes and public artifacts. Text evidence must be redacted before it is written.
Screenshots must be reviewed and sanitised before preservation, and an
unsanitised source capture must not remain in the evidence tree.

The controller runs one VM adapter at a time. On the first `SIGINT` or `SIGTERM`
it forwards that signal through the exact active release-download,
asset-validation, or VM-adapter child handle and waits for that child to
terminate. An interrupted VM then follows the normal app-state validation and
exact-name cleanup path. The controller-side deprovision child is deliberately
not signal-eligible and is allowed to finish. On POSIX hosts, managed children
are isolated from the controller's terminal process group, preventing a
terminal-generated signal from bypassing this forwarding policy or directly
striking cleanup. This isolation does not background the operation: the
controller retains the `ChildProcess` handle and awaits observed termination.
The first forwarded signal relies on each adapter's bounded signal/EXIT traps;
there is no automatic force timer. The controller does not target a remembered
PID. A second signal may send
`SIGKILL`, but only through the originally captured child handle if that same
record is still active; it never retargets a cleanup child. The terminal report
has `status: "interrupted"`, `completedAt`, per-machine cleanup evidence, and an
`interruption` object recording the signal, conventional exit code (`130` or
`143`), forwarding/force outcome, informational observed process ID, and
termination. The process ID is evidence only and is never used for signalling.
Missing or unverified production cleanup remains a non-passing result. Protected
tenant and account values are redacted from both the report and VM output.
If an adapter is blocked in an uninterruptible child, an operator may choose the
deliberate second-signal force path; that VM must then be quarantined and
restored to its approved snapshot before reuse.

Historical non-secret guest configuration and the last recovered successful
diagnostic runs are recorded in
[`recovered-release-e2e.md`](./recovered-release-e2e.md).
