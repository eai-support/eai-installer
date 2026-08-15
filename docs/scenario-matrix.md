# EAI Setup User Scenario Matrix

This matrix is the release traceability contract for the desktop wizard. Each
scenario must have a deterministic local test, a controlled fixture, or a
guest-machine smoke test. A scenario is not considered covered because the
installer window opened; the expected state and recovery action must also be
visible.

| ID | Stage | User situation | Expected result |
| --- | --- | --- | --- |
| WELCOME-01 | Welcome | Open the installer | Device detection starts automatically and the window remains responsive. |
| WELCOME-02 | Welcome | Choose Start setup twice | Only one setup run starts; the second click is ignored. |
| PRE-01 | Computer | Git, Node.js, npm, and EAI CLI are present | No package is installed; setup continues. |
| PRE-02 | Computer | Git is missing | Only Git is installed, then its version is rechecked. |
| PRE-03 | Computer | Node.js or npm is missing | Node.js and npm are installed together, then both are rechecked. |
| PRE-04 | Computer | EAI CLI is missing or below the supported release | The canonical CLI package is installed or updated, then `eai --version` is rechecked. |
| PRE-05 | Computer | A prerequisite installer fails or permission is cancelled | The exact item is marked as needing attention, recent activity stays visible, and Try again is shown. |
| PRE-06 | Computer | Choose Try again after fixing the prerequisite | Only the missing item is retried. |
| AUTH-01 | Sign in | Browser sign-in succeeds | The company workspaces are loaded and app setup opens. |
| AUTH-02 | Sign in | Browser sign-in is cancelled or times out | The installer explains that sign-in did not finish and allows retry. |
| AUTH-03 | Sign in | User has no account | The public signup page opens; no password is collected by the installer. |
| AUTH-04 | Sign in | User has no available company workspace | App creation is blocked with a clear administrator action. |
| APP-01 | App | One company workspace is available | It is selected automatically and shown as the owner. |
| APP-02 | App | Several company workspaces are available | The user chooses the owner explicitly before continuing. |
| APP-03 | App | Selected workspace has no apps | The form offers creation of a new app. |
| APP-04 | App | Selected workspace has existing apps | The user can choose an existing app or Create a new app. |
| APP-05 | App | Workspace or app discovery fails | No initialization call is made; the user sees a retryable error. |
| LOCATION-01 | Location | Enter a valid parent folder | The project folder will be created beneath that parent. |
| LOCATION-02 | Location | Use Finder or File Explorer and cancel | The current folder value is unchanged and the user can continue. |
| LOCATION-03 | Location | Select a parent folder whose name differs from the project | A new child folder with the project name is created. |
| LOCATION-04 | Location | Select a folder already named as the project | The selected folder is used directly; no duplicate child folder is created. |
| LOCATION-05 | Location | Folder is empty, missing, or not writable | Initialization stops before the CLI call with a specific correction. |
| INIT-01 | Initialize | Click Create or Use app | The button immediately changes to Creating app... or Initialising project... and becomes disabled. |
| INIT-02 | Initialize | Double-click the initialize button | Exactly one initialization request runs. |
| INIT-03 | Initialize | Windows npm launcher returns `spawn EINVAL` | The UI strips terminal codes, identifies the outdated Windows CLI path, and tells the user to reopen/update/retry. |
| INIT-04 | Initialize | Template clone, manifest, or dependency install fails for another reason | The real failure remains visible, the project folder is described as safe to reuse when applicable, and retry is offered. |
| INIT-05 | Initialize | Initialization leaves a partial scaffold | Retry uses the supported CLI recovery path and does not silently claim success. |
| INIT-06 | Initialize | Initialization completes | The project path is shown and the completion screen offers Open project folder. |
| COMPLETE-01 | Complete | Choose Open project folder | The native file manager opens the created project. |
| COMPLETE-02 | Complete | Choose Close setup | The wizard closes without deleting the project. |
| AI-01 | AI handoff | No supported AI workspace is installed | The app remains complete and the official download option is shown. |
| AI-02 | AI handoff | A supported AI workspace is installed | The user can start it with the project path. |
| AI-03 | AI handoff | Choose an AI workspace download | Only the official provider page opens; no provider account or secret is collected. |
| AI-04 | AI handoff | AI workspace start fails | The project remains safe and the user receives a command-free recovery explanation. |

## Evidence rules

- `scripts/test-wizard.mjs` covers deterministic state, validation, labels, and
  error guidance.
- `scripts/test-bootstrap.mjs` covers the desktop wiring contract, including
  the Windows launcher, output sanitization, folder flow, and retry controls.
- The native bundle workflow builds and installs Windows x64/ARM64, macOS
  Intel/Apple Silicon, and Ubuntu x64/ARM64 artifacts.
- Release evidence must include one guest-machine run for each OS family. A
  source test or a preview window is not a substitute for the guest run.
