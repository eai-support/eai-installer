# EAI Setup User Scenario Matrix

This matrix is the release traceability contract for the desktop wizard. Each
scenario must have a deterministic local test, a controlled fixture, or a
guest-machine smoke test. A scenario is not considered covered because the
installer window opened; the expected state and recovery action must also be
visible.

| ID | Stage | User situation | Expected result |
| --- | --- | --- | --- |
| WELCOME-01 | Sign in | Open the installer | The app opens on Sign in, the readiness check runs by itself, and the window stays responsive. |
| WELCOME-02 | Sign in | Press Sign in with browser twice | Only one sign-in runs; the second press is ignored while the first is still waiting. |
| PRE-01 | Computer | Git, Node.js, npm, and EAI CLI are present | No package is installed; setup continues. |
| PRE-02 | Computer | Git is missing | Only Git is installed, then its version is rechecked. |
| PRE-03 | Computer | Node.js or npm is missing | Node.js and npm are installed together, then both are rechecked. |
| PRE-04 | Computer | EAI CLI is missing or below the supported release | The canonical CLI package is installed or updated, then `eai --version` is rechecked. |
| PRE-05 | Sign in | A prerequisite installer fails or permission is cancelled | The tick is replaced by a row naming each item that failed and its fix; the primary greys out and Retry appears. |
| PRE-06 | Sign in | Choose Retry after fixing the prerequisite | Only the missing item is retried, and the tick returns when it lands. |
| PRE-07 | Computer | WinGet reports that Node.js is already installed and no upgrade is available | Setup verifies the live `node` and `npm` commands and continues when they work; WinGet's no-change exit is not treated as an installation failure. |
| AUTH-01 | Sign in | Browser sign-in succeeds | The company workspaces are loaded and app setup opens. |
| AUTH-02 | Signed in | Browser sign-in is cancelled or times out | The Signed-in beat turns over: it says sign-in did not finish, and offers Try again plus the sign-in link. |
| AUTH-03 | Sign in | User has no account | The public signup page opens; no password is collected by the installer. |
| AUTH-04 | Sign in | User has no available company workspace | App creation is blocked with a clear administrator action. |
| AUTH-05 | Sign in | Workspace discovery returns a temporary 502, 503, or 504 response | Setup retries the request, preserves the completed sign-in, and offers a workspace-only retry if the service remains unavailable. |
| APP-01 | App | One company workspace is available | It is selected automatically and shown as the owner. |
| APP-02 | App | Several company workspaces are available | The user chooses the owner explicitly before continuing. |
| APP-03 | App | Any workspace | The form always creates a new app from the EAI template; there is no app-type question. |
| APP-04 | App | The workspace already has apps | They are not offered — the installer only creates from the template. Connecting to an existing app is CLI-only. See docs/known-issues.md KI-02. |
| APP-05 | App | Workspace discovery fails | No initialization call is made; a temporary failure offers a retry beside the question, a missing-membership failure does not. |
| APP-06 | App | User administers many company workspaces | The workspace question becomes a list; choosing one reveals the name question. No app list is fetched, so one unrelated workspace cannot block the screen. |
| LOCATION-01 | Location | Enter a valid parent folder | The project folder will be created beneath that parent. |
| LOCATION-02 | Location | Use Finder or File Explorer and cancel | The current folder value is unchanged and the user can continue. |
| LOCATION-03 | Location | Select a parent folder whose name differs from the project | A new child folder with the project name is created. |
| LOCATION-04 | Location | Select a folder already named as the project | The selected folder is used directly; no duplicate child folder is created. |
| LOCATION-05 | Location | Folder is empty, missing, or not writable | Initialization stops before the CLI call with a specific correction. |
| INIT-01 | Initialize | Choose Create app | The screen immediately changes to Creating with its four rows; the button immediately changes state and cannot be pressed again. |
| INIT-02 | Initialize | Double-click Create app | Exactly one initialization request runs. |
| INIT-03 | Initialize | Windows CLI creates the scaffold | The installer invokes `eai init --no-install`, then runs the platform-aware npm installer itself so app dependencies do not depend on a nested `npm.cmd` launch. |
| INIT-07 | Initialize | Windows npm launcher returns `spawn EINVAL` in a direct CLI run | The desktop installer invokes npm through the resolved Node runtime where possible, preserves the diagnostic, and reports a dependency-install recovery path; it does not blame the EAI CLI. |
| INIT-09 | Initialize | Windows Node/npm is installed in a user-managed or PATH-only location | The installer resolves the live Node and npm locations from the machine PATH, runs the npm entry point from that installation, and does not report that the EAI CLI needs an update when the CLI is already available. |
| RELEASE-01 | Release gate | Run the published installer in a protected guest | The desktop application performs the real prerequisite, saved-auth, workspace, initialization, and AI-workspace handoff flow and writes a bounded receipt; an existing CLI alone cannot satisfy the gate. |
| INIT-04 | Initialize | Template clone, manifest, or dependency install fails for another reason | The real failure remains visible, the project folder is described as safe to reuse when applicable, and retry is offered. |
| INIT-05 | Initialize | Initialization leaves a partial scaffold | Retry uses the supported CLI recovery path and does not silently claim success. |
| INIT-06 | Initialize | Initialization completes | The project path is shown and the completion screen offers Open project folder. |
| INIT-08 | Workspace | Signed-in user has a direct membership on a child company workspace | The workspace is selectable and app discovery is scoped to that workspace; root-only filtering is not applied. |
| COMPLETE-01 | Complete | Choose Open project folder | The native file manager opens the created project. |
| COMPLETE-02 | Built | Choose Done | The window closes, or says it can be closed, without deleting the project. |
| AI-01 | AI handoff | No supported AI workspace is installed | The app remains complete and the official download option is shown. |
| AI-02 | AI handoff | A supported AI workspace is installed | The user can start it with the project path. |
| AI-03 | AI handoff | Choose an AI workspace download | Only the official provider page opens; no provider account or secret is collected. |
| AI-04 | AI handoff | AI workspace start fails | The project remains safe and the user receives a command-free recovery explanation. |
| STATE-01 | Every screen | Walk the seven screens in order | Sign in, Signed in, Set up, Creating, Choose a harness, Hand-off and Built each appear once, in that order, with one visible at a time. |
| STATE-02 | Sign in | A prerequisite failed and the EAI API is unreachable | Both rows appear in one list, chronologically, under "Two things are in the way"; the tick is not shown beside either. |
| STATE-03 | Sign in | The network probe cannot run on this machine | Connectivity is treated as reachable and sign-in decides; the user is not sent to their VPN settings over a missing probe. |
| STATE-04 | Sign in | A prerequisite install fails because the network is down | The screen reports the connection, not the prerequisite; the fix offered is the one that will work. |
| STATE-17 | Sign in | Two prerequisites both fail | Both are attempted, both are reported as rows in the same list, and the heading counts rows. Neither row claims nothing else is waiting on it. |
| STATE-18 | Sign in | Node.js fails and the EAI CLI is also missing | The CLI is not attempted, because it is installed with npm; the failure names Node.js and does not blame the CLI. |
| STATE-05 | Set up | Answer each question in turn | The next question appears under the answer with no Continue between them; Back and Create app are present from the first question. |
| STATE-06 | Set up | Clear the app name after choosing a location | The location question closes again; Create app greys out. |
| STATE-07 | Set up | The chosen name already exists in the chosen folder | The error is shown in the name field, on the form, not on the Creating screen. |
| STATE-11 | Set up | The location has not been chosen yet | One button, at the left, reading Choose location. No path, no greyed text, and nothing that reads as an answer already in. |
| STATE-12 | Set up | The location has been chosen | The path is shown, with Change location on the right of it. Both controls say "location", matching the question. |
| STATE-13 | Set up | Any stage | The form is three questions — workspace, name, location. The app name is always editable. |
| STATE-14 | Set up | The name has not been typed yet | The field is empty with ghost text, and the location question is not shown. Nothing on the screen is pre-answered. |
| STATE-15 | Set up | Type an app name one character at a time | The location question appears on the first character and does not close again on a hyphen mid-word. Clearing the field closes it. |
| STATE-16 | Set up | Type a name that is not kebab case | Create app stays disabled, and leaving the field says why. Typing again clears the message. |
| STATE-08 | Set up | The account has no workspace | No workspace row is shown beside the failure, and every question below stays down. |
| STATE-09 | Creating | Initialization fails partway | The row that was running is marked failed, the rows after it stay pending, no fifth row appears, and Retry this step is offered. |
| STATE-10 | Built | The harness opened on the project | The success overlay lands over the hand-off and offers Open the project folder and Done. |
| HARNESS-01 | Choose a harness | A supported tool is already installed | It is listed first under "Ready on this <device>", it is preselected, there is no alert, and the button reads Next. |
| HARNESS-02 | Choose a harness | Nothing is installed | Only the "Not installed" group is drawn, the alert names the vendor site and account, and the button reads Get <tool>. |
| HARNESS-03 | Choose a harness | Choose Get and leave for the vendor site | The waiting box appears, the alert is withdrawn, the button is disabled and reads Waiting for <tool>. |
| HARNESS-04 | Choose a harness | The tool is installed while the waiting box is up | The screen updates by itself within a few seconds and the button becomes Next; the poll stops. |
| HARNESS-05 | Choose a harness | Detection itself fails | The screen says the check failed and the app is safe; it does not read as though the app failed. |
| PLATFORM-01 | Every screen | Run on Windows | No screen says Mac, Finder, xcode-select or Command Line Tools; the prerequisite failure names winget and the location question names File Explorer. |
| PLATFORM-02 | Every screen | Run on Linux | No screen names a Mac or a PC; the prerequisite failure names the distribution package manager. |
| PLATFORM-03 | Sign in | Run on Windows with the runtime missing | The readiness row counts five checks including Windows app support, and the failure names the tool that failed. |
| PLATFORM-04 | Sign in | Run on Windows or Linux | The macOS password panel is never shown; the platform's own prompt is used. |

## Evidence rules

- `npm run prototype` opens every screen and failure below in the real
  app, at the real window size, with a rail to reach them. It is a review
  tool and is not in the bundle. It cannot exercise anything that needs a
  real machine — the macOS password prompt, a real login, a real init —
  so it evidences wording and screen state, never behaviour.
- `scripts/test-state-machine.mjs` covers every screen, every fault and every
  platform wording without a browser, including the check that no Windows or
  Linux sentence names a Mac.
- `scripts/test-ui-contract.mjs` covers the coupling between the markup, the
  driver and the stylesheet: every id the app reaches for, every screen the
  machine declares, and every class it assigns at runtime.
- `scripts/test-wizard.mjs` covers deterministic state, validation, labels, and
  error guidance.
- `scripts/test-bootstrap.mjs` covers the desktop wiring contract, including
  the Windows launcher, output sanitization, folder flow, and retry controls.
- The native bundle workflow builds and installs Windows x64/ARM64, macOS
  Intel/Apple Silicon, and Ubuntu x64/ARM64 artifacts.
- Release evidence must include one guest-machine run for each OS family. A
  source test or a preview window is not a substitute for the guest run.
