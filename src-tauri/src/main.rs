use serde::Serialize;
use std::cmp::Reverse;
use std::env;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use uuid::Uuid;

#[derive(Serialize)]
struct ToolState {
    command: String,
    version: Option<String>,
}

#[derive(Serialize)]
struct EnvironmentReport {
    platform: String,
    architecture: String,
    tools: Vec<ToolState>,
    package_manager: Option<String>,
}

#[derive(Serialize)]
struct BootstrapResult {
    ok: bool,
    step: String,
    message: String,
    command: Option<String>,
    output: Option<String>,
    requires_user_action: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapProgress {
    step: String,
    title: String,
    detail: String,
    progress: Option<u8>,
    estimated_seconds: Option<u64>,
}

const EAI_SIGNUP_URL: &str = "https://www.enterpriseaigroup.com/signup/developer";

fn emit_progress(
    app: &AppHandle,
    step: &str,
    title: &str,
    detail: &str,
    progress: Option<u8>,
    estimated_seconds: Option<u64>,
) {
    let _ = app.emit(
        "bootstrap-progress",
        BootstrapProgress {
            step: step.to_string(),
            title: title.to_string(),
            detail: detail.to_string(),
            progress,
            estimated_seconds,
        },
    );
}

fn nvm_version_key(path: &Path) -> (u64, u64, u64) {
    let version = path.file_name().and_then(|value| value.to_str()).unwrap_or_default();
    let mut parts = version.trim_start_matches('v').split('.').map(|part| part.parse::<u64>().unwrap_or(0));
    (parts.next().unwrap_or(0), parts.next().unwrap_or(0), parts.next().unwrap_or(0))
}

fn nvm_node_bin_dirs() -> Vec<PathBuf> {
    let Some(home) = env::var_os("HOME") else { return Vec::new(); };
    let nvm_root = env::var_os("NVM_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(&home).join(".nvm"));
    let versions_root = nvm_root.join("versions/node");
    let mut versions = fs::read_dir(versions_root)
        .ok()
        .into_iter()
        .flat_map(|entries| entries.filter_map(Result::ok))
        .map(|entry| entry.path())
        .filter(|path| path.is_dir() && path.join("bin/node").is_file())
        .collect::<Vec<_>>();
    versions.sort_by_key(|path| Reverse(nvm_version_key(path)));

    let mut bins = Vec::new();
    if let Some(nvm_bin) = env::var_os("NVM_BIN") {
        let path = PathBuf::from(nvm_bin);
        if path.join("node").is_file() { bins.push(path); }
    }
    bins.extend(versions.into_iter().map(|path| path.join("bin")));
    bins
}

fn user_node_bin_dirs() -> Vec<PathBuf> {
    let mut bins = Vec::new();
    if let Some(home) = env::var_os("HOME") {
        let home = PathBuf::from(home);
        bins.push(home.join(".eai-setup/node/bin"));
        bins.push(home.join(".eai-setup/npm-global/bin"));
    }
    bins.extend(nvm_node_bin_dirs());
    bins
}

fn macos_package_bin_dirs() -> Vec<PathBuf> {
    if !cfg!(target_os = "macos") { return Vec::new(); }
    ["/opt/homebrew/bin", "/usr/local/bin"].into_iter().map(PathBuf::from).collect()
}

fn executable(program: &str) -> String {
    if cfg!(unix) && matches!(program, "node" | "npm" | "eai") {
        for directory in user_node_bin_dirs() {
            let path = directory.join(program);
            if path.is_file() {
                return path.to_string_lossy().to_string();
            }
        }
    }
    if cfg!(target_os = "macos") && matches!(program, "brew" | "git" | "node" | "npm" | "eai") {
        for directory in macos_package_bin_dirs() {
            let path = directory.join(program);
            if path.is_file() {
                return path.to_string_lossy().to_string();
            }
        }
    }
    if cfg!(target_os = "windows") && matches!(program, "npm" | "eai") {
        format!("{program}.cmd")
    } else {
        program.to_string()
    }
}

fn run_program(program: &str, args: &[&str]) -> Result<(String, String), String> {
    run_program_in_directory(program, args, None)
}

fn run_program_in_directory(program: &str, args: &[&str], directory: Option<&Path>) -> Result<(String, String), String> {
    let mut command = Command::new(executable(program));
    command.args(args);
    if cfg!(unix) {
        let mut paths = user_node_bin_dirs();
        paths.extend(macos_package_bin_dirs());
        if let Some(existing) = env::var_os("PATH") {
            paths.extend(env::split_paths(&existing));
        }
        if let Ok(path) = env::join_paths(paths) {
            command.env("PATH", path);
        }
    }
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    let output = command
        .output()
        .map_err(|error| format!("could not start {program}: {error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if output.status.success() {
        Ok((stdout, stderr))
    } else {
        Err(if stderr.is_empty() { stdout } else { stderr })
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn applescript_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
    )
}

fn user_npm_prefix() -> Option<PathBuf> {
    if cfg!(unix) {
        env::var_os("HOME").map(|home| Path::new(&home).join(".eai-setup/npm-global"))
    } else {
        None
    }
}

fn expose_user_npm_bin() -> Result<(), String> {
    let Some(prefix) = user_npm_prefix() else { return Ok(()); };
    fs::create_dir_all(prefix.join("bin")).map_err(|error| error.to_string())?;
    let marker = "EAI_SETUP_NPM_GLOBAL";
    let line = "\n# EAI_SETUP_NPM_GLOBAL\nexport PATH=\"$HOME/.eai-setup/node/bin:$HOME/.eai-setup/npm-global/bin:$PATH\"\n";
    let Some(home) = env::var_os("HOME") else { return Ok(()); };
    for filename in [".profile", ".zprofile"] {
        let path = Path::new(&home).join(filename);
        let existing = fs::read_to_string(&path).unwrap_or_default();
        if !existing.contains(marker) {
            let mut file = OpenOptions::new().create(true).append(true).open(&path).map_err(|error| error.to_string())?;
            file.write_all(line.as_bytes()).map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

fn version(program: &str, args: &[&str]) -> Option<String> {
    run_program(program, args).ok().map(|(stdout, stderr)| {
        if stdout.is_empty() { stderr } else { stdout }
    })
}

fn macos_git_ready() -> bool {
    if !cfg!(target_os = "macos") {
        return false;
    }
    let Ok((stdout, _)) = run_program("/usr/bin/xcode-select", &["-p"]) else {
        return false;
    };
    let developer_dir = stdout.trim();
    !developer_dir.is_empty() && Path::new(developer_dir).join("usr/bin/git").is_file()
}

fn git_version() -> Option<String> {
    if cfg!(target_os = "macos") && !macos_git_ready() {
        return None;
    }
    version("git", &["--version"])
}

fn latest_command_line_tools_label() -> Result<String, String> {
    let mut last_detail = String::new();
    for attempt in 0..15 {
        match run_program("/usr/sbin/softwareupdate", &["--list"]) {
            Ok((stdout, stderr)) => {
                // softwareupdate can write the useful package listing to stderr while
                // a background scan reports that another operation is in progress.
                let labels: Vec<String> = stdout
                    .lines()
                    .chain(stderr.lines())
                    .filter_map(|line| line.trim().strip_prefix("* Label: "))
                    .filter(|label| label.starts_with("Command Line Tools for Xcode"))
                    .map(str::to_string)
                    .collect();
                if let Some(label) = labels.last() {
                    return Ok(label.clone());
                }
                last_detail = stderr.trim().to_string();
            }
            Err(error) => last_detail = error,
        }
        if attempt < 14 {
            thread::sleep(Duration::from_secs(2));
        }
    }
    Err(format!(
        "Apple Software Update did not advertise Command Line Tools after 30 seconds. {}",
        last_detail
    ))
}

fn refresh_macos_command_line_tools_catalog() {
    // Apple refreshes the Software Update catalog after this native request. The
    // installer keeps control in the EAI window and only surfaces Apple's dialog
    // when macOS requires the user to approve the package download.
    let _ = Command::new("/usr/bin/xcode-select")
        .arg("--install")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn spawn_macos_command_line_tools_install(label: &str, admin_password: Option<&str>) -> Result<Child, String> {
    if let Some(password) = admin_password.filter(|value| !value.is_empty()) {
        let user = run_program("id", &["-un"])
            .map(|(stdout, _)| stdout.trim().to_string())
            .map_err(|error| format!("macOS could not determine the signed-in user: {error}"))?;
        let mut command = Command::new("/usr/sbin/softwareupdate");
        command
            .args(["--install", label, "--user", &user, "--stdinpass"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = command
            .spawn()
            .map_err(|error| format!("macOS could not start the Command Line Tools installer: {error}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(format!("{password}\n").as_bytes())
                .map_err(|error| format!("macOS could not provide the one-time administrator approval: {error}"))?;
        }
        return Ok(child);
    }
    let command = format!("/usr/sbin/softwareupdate --install {}", shell_quote(label));
    let apple_script = format!("do shell script {} with administrator privileges", applescript_quote(&command));
    Command::new("/usr/bin/osascript")
        .args(["-e", &apple_script])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("macOS could not start the native administrator install: {error}"))
}

fn command_result(step: &str, ok: bool, message: &str, command: Option<&str>, output: Option<String>, requires_user_action: bool) -> BootstrapResult {
    BootstrapResult {
        ok,
        step: step.to_string(),
        message: message.to_string(),
        command: command.map(ToString::to_string),
        output,
        requires_user_action,
    }
}

#[tauri::command]
fn detect_environment() -> EnvironmentReport {
    let platform = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unsupported"
    };
    let package_manager = if cfg!(target_os = "windows") && version("winget", &["--version"]).is_some() {
        Some("winget".to_string())
    } else if cfg!(target_os = "macos") && version("brew", &["--version"]).is_some() {
        Some("brew".to_string())
    } else if cfg!(target_os = "linux") && version("apt-get", &["--version"]).is_some() {
        Some("apt-get".to_string())
    } else if cfg!(target_os = "linux") && version("dnf", &["--version"]).is_some() {
        Some("dnf".to_string())
    } else {
        None
    };
    EnvironmentReport {
        platform: platform.to_string(),
        architecture: env::consts::ARCH.to_string(),
        tools: vec![
            ToolState { command: "git".to_string(), version: git_version() },
            ToolState { command: "node".to_string(), version: version("node", &["--version"]) },
            ToolState { command: "npm".to_string(), version: version("npm", &["--version"]) },
            ToolState { command: "eai".to_string(), version: version("eai", &["--version"]) },
        ],
        package_manager,
    }
}

fn package_install_step(app: &AppHandle, step: &str, package: &str, message: &str, admin_password: Option<&str>) -> BootstrapResult {
    emit_progress(app, step, &format!("Installing {package}"), "Preparing the signed package manager.", Some(5), Some(60));
    if cfg!(target_os = "windows") {
        if version("winget", &["--version"]).is_none() {
            return command_result(step, false, "WinGet is not available in this Windows session.", Some("Install or enable App Installer, then rerun EAI Setup."), None, true);
        }
        let package_id = if package == "git" { "Git.Git" } else { "OpenJS.NodeJS.LTS" };
        return match run_program("winget", &["install", "--id", package_id, "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements"]) {
            Ok((stdout, stderr)) => {
                emit_progress(app, step, &format!("{package} installed"), "Verifying the installation.", Some(90), Some(5));
                command_result(step, true, message, Some("winget install (fixed package identifier)"), Some(format!("{stdout}\n{stderr}")), false)
            }
            Err(error) => command_result(step, false, &error, Some("winget install (fixed package identifier)"), None, true),
        };
    }

    if cfg!(target_os = "macos") {
        if version("brew", &["--version"]).is_none() {
            if package == "git" {
                return command_line_tools_install_step(app, admin_password);
            }
            return node_pkg_install_step(app);
        }
        return match run_program("brew", &["install", package]) {
            Ok((stdout, stderr)) => {
                emit_progress(app, step, &format!("{package} installed"), "Verifying the installation.", Some(90), Some(5));
                command_result(step, true, message, Some("brew install (fixed package name)"), Some(format!("{stdout}\n{stderr}")), false)
            }
            Err(error) => command_result(step, false, &error, Some("brew install (fixed package name)"), None, true),
        };
    }

    if version("pkexec", &["--version"]).is_none() {
        return command_result(
            step,
            false,
            "This Linux computer does not provide a graphical permission helper for automatic installation.",
            Some("Ask an administrator to enable graphical package installation, then retry EAI Setup."),
            None,
            true,
        );
    }

    if version("apt-get", &["--version"]).is_some() {
        let packages = if package == "git" { &["git"][..] } else { &["nodejs", "npm"][..] };
        if let Err(error) = run_program("pkexec", &["apt-get", "update"]) {
            return command_result(step, false, &error, Some("pkexec apt-get update"), None, true);
        }
        return match run_program("pkexec", [&["apt-get", "install", "-y"][..], packages].concat().as_slice()) {
            Ok((stdout, stderr)) => {
                emit_progress(app, step, &format!("{package} installed"), "Verifying the installation.", Some(90), Some(5));
                command_result(step, true, message, Some("pkexec apt-get install"), Some(format!("{stdout}\n{stderr}")), false)
            }
            Err(error) => command_result(step, false, &error, Some("pkexec apt-get install"), None, true),
        };
    }

    if version("dnf", &["--version"]).is_some() {
        let packages = if package == "git" { &["git"][..] } else { &["nodejs", "npm"][..] };
        return match run_program("pkexec", [&["dnf", "install", "-y"][..], packages].concat().as_slice()) {
            Ok((stdout, stderr)) => {
                emit_progress(app, step, &format!("{package} installed"), "Verifying the installation.", Some(90), Some(5));
                command_result(step, true, message, Some("pkexec dnf install"), Some(format!("{stdout}\n{stderr}")), false)
            }
            Err(error) => command_result(step, false, &error, Some("pkexec dnf install"), None, true),
        };
    }

    command_result(step, false, "No supported Linux package manager was found.", Some("Use your distribution's signed package manager, then retry."), None, true)
}

fn command_line_tools_install_step(app: &AppHandle, admin_password: Option<&str>) -> BootstrapResult {
    emit_progress(app, "git", "Preparing Git", "Apple Command Line Tools are the minimal Git dependency; full Xcode is not required.", Some(10), Some(90));
    if git_version().is_some() {
        return command_result("git", true, "Git is ready.", Some("Apple Command Line Tools"), None, false);
    }
    if !Path::new("/usr/bin/xcode-select").exists() {
        return command_result("git", false, "Apple Command Line Tools are unavailable on this Mac.", Some("Install Command Line Tools from Apple, then retry EAI Setup."), None, true);
    }
    emit_progress(app, "git", "Finding Git tools", "Checking Apple Software Update for the minimal Command Line Tools package.", Some(15), None);
    let label = match latest_command_line_tools_label() {
        Ok(label) => label,
        Err(first_error) => {
            emit_progress(
                app,
                "git",
                "Refreshing Apple Software Update",
                "Apple has not listed the minimal Git tools yet. Asking macOS to refresh its signed catalog; if macOS shows an Install dialog, choose Install and EAI Setup will continue checking.",
                Some(18),
                Some(90),
            );
            refresh_macos_command_line_tools_catalog();
            match latest_command_line_tools_label() {
                Ok(label) => label,
                Err(second_error) => {
                    let detail = format!("{first_error} After the native refresh: {second_error}");
                    return command_result(
                        "git",
                        false,
                        &detail,
                        Some("Finish any Apple Command Line Tools prompt, or open System Settings > General > Software Update, then click Try again."),
                        None,
                        true,
                    );
                }
            }
        }
    };
    let approval_detail = if admin_password.filter(|value| !value.is_empty()).is_some() {
        "Using the Mac password you entered once to approve Apple Software Update; no Terminal window will open."
    } else {
        "macOS will show a secure administrator dialog. Enter your Mac password there; no Terminal window will open."
    };
    emit_progress(app, "git", "Waiting for permission", approval_detail, Some(25), None);
    let mut installer = match spawn_macos_command_line_tools_install(&label, admin_password) {
        Ok(child) => child,
        Err(error) => return command_result("git", false, &error, Some("Retry EAI Setup and enter your Mac login password again."), None, true),
    };
    emit_progress(app, "git", "Installing Git", "Installing the minimal Apple Command Line Tools package.", Some(30), None);
    let mut installer_finished = false;
    for attempt in 0..600 {
        if git_version().is_some() {
            emit_progress(app, "git", "Git ready", "Continuing with Node.js and npm.", Some(100), Some(0));
            return command_result("git", true, "Git installation completed.", Some("Apple Command Line Tools"), None, false);
        }
        if !installer_finished {
            match installer.try_wait() {
                Ok(Some(status)) => {
                    installer_finished = true;
                    if !status.success() {
                        return command_result("git", false, "Apple Software Update could not complete the minimal Git tools installation. Check Recent activity for the last status, then retry with your Mac login password.", Some("Retry EAI Setup and enter your Mac login password again."), None, true);
                    }
                }
                Ok(None) => {}
                Err(error) => return command_result("git", false, &format!("macOS installation status could not be read: {error}"), Some("Retry EAI Setup."), None, true),
            }
        } else if attempt >= 30 {
            return command_result("git", false, "macOS reported that Command Line Tools finished, but Git is still unavailable.", Some("Restart EAI Setup and retry the Apple Command Line Tools installation."), None, true);
        }
        if attempt % 5 == 0 {
            let elapsed = attempt;
            let detail = if admin_password.filter(|value| !value.is_empty()).is_some() {
                format!("Apple Software Update is still installing Git after {elapsed}s. The password was supplied once and is not saved.")
            } else if elapsed == 0 {
                "macOS will show a secure administrator dialog. Enter your Mac password there; no Terminal window will open."
                    .to_string()
            } else {
                format!("macOS is still installing Git after {elapsed}s. Check the native administrator dialog if it is visible.")
            };
            emit_progress(app, "git", "Installing Git", &detail, Some(30), None);
        }
        thread::sleep(Duration::from_secs(1));
    }
    command_result("git", false, "Command Line Tools did not become available after the macOS installer finished.", Some("Install Command Line Tools from Apple, then retry EAI Setup."), None, true)
}

fn latest_node_artifact() -> Result<(String, String), String> {
    let (body, _) = run_program("curl", &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "https://nodejs.org/dist/index.json"])?;
    let releases: serde_json::Value = serde_json::from_str(&body).map_err(|error| format!("could not read the Node.js release index: {error}"))?;
    let Some(releases) = releases.as_array() else { return Err("Node.js release index was not an array".to_string()); };
    let architecture = run_program("uname", &["-m"])
        .ok()
        .map(|(stdout, _)| stdout.trim().to_string())
        .unwrap_or_default();
    let package_file = if architecture == "arm64" || architecture == "aarch64" {
        "osx-arm64-pkg"
    } else {
        "osx-x64-pkg"
    };
    let tar_file = if architecture == "arm64" || architecture == "aarch64" {
        "osx-arm64-tar"
    } else {
        "osx-x64-tar"
    };
    for release in releases {
        let Some(version) = release.get("version").and_then(|value| value.as_str()) else { continue; };
        let is_lts = release.get("lts").and_then(|value| value.as_str()).is_some();
        let files = release.get("files").and_then(|value| value.as_array());
        let has_macos_pkg = files.map(|items| items.iter().any(|file| file.as_str() == Some(package_file))).unwrap_or(false);
        let has_macos_tar = files.map(|items| items.iter().any(|file| file.as_str() == Some(tar_file))).unwrap_or(false);
        if is_lts && (has_macos_pkg || has_macos_tar) {
            // Prefer the user-local archive. It includes npm, is checksum
            // verified below, and avoids a second administrator prompt.
            let filename = if has_macos_tar {
                format!("node-{version}-darwin-{}.tar.gz", if architecture == "arm64" || architecture == "aarch64" { "arm64" } else { "x64" })
            } else {
                format!("node-{version}.pkg")
            };
            return Ok((version.to_string(), filename));
        }
    }
    Err("no supported Node.js LTS macOS package was found".to_string())
}

fn node_tar_install_step(app: &AppHandle, node_version: &str, filename: &str, url: &str) -> BootstrapResult {
    let archive = env::temp_dir().join(format!("eai-node-{}.tar.gz", Uuid::new_v4()));
    let checksum_file = env::temp_dir().join(format!("eai-node-{}-SHASUMS256.txt", Uuid::new_v4()));
    let archive_string = archive.to_string_lossy().to_string();
    let checksum_string = checksum_file.to_string_lossy().to_string();
    emit_progress(app, "node", "Downloading Node.js", "Downloading the official native Node.js LTS archive.", Some(10), Some(90));
    if let Err(error) = run_program("curl", &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &archive_string, url]) {
        return command_result("node", false, &error, Some("Download the official Node.js LTS archive over HTTPS"), None, true);
    }
    let checksum_url = format!("https://nodejs.org/dist/{node_version}/SHASUMS256.txt");
    emit_progress(app, "node", "Checking Node.js installer", "Verifying the archive checksum before installation.", Some(35), Some(75));
    if let Err(error) = run_program("curl", &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &checksum_string, &checksum_url]) {
        let _ = fs::remove_file(&archive);
        return command_result("node", false, &error, Some("Download the official Node.js checksum manifest"), None, true);
    }
    let checksums = match fs::read_to_string(&checksum_file) {
        Ok(value) => value,
        Err(error) => {
            let _ = fs::remove_file(&archive);
            let _ = fs::remove_file(&checksum_file);
            return command_result("node", false, &format!("The Node.js checksum manifest could not be read: {error}"), Some("Verify the official Node.js checksum manifest"), None, true);
        }
    };
    let expected = checksums.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        let digest = fields.next()?;
        let listed_file = fields.next()?.trim_start_matches('*');
        (listed_file == filename).then_some(digest)
    });
    let Some(expected) = expected else {
        let _ = fs::remove_file(&archive);
        let _ = fs::remove_file(&checksum_file);
        return command_result("node", false, "The Node.js checksum manifest did not contain the downloaded archive.", Some("Verify the official Node.js checksum manifest"), None, true);
    };
    let actual = match run_program("shasum", &["-a", "256", &archive_string]) {
        Ok((stdout, _)) => stdout.split_whitespace().next().unwrap_or_default().to_string(),
        Err(error) => {
            let _ = fs::remove_file(&archive);
            let _ = fs::remove_file(&checksum_file);
            return command_result("node", false, &format!("The Node.js archive checksum could not be calculated: {error}"), Some("Verify the official Node.js checksum"), None, true);
        }
    };
    if actual != expected {
        let _ = fs::remove_file(&archive);
        let _ = fs::remove_file(&checksum_file);
        return command_result("node", false, "The Node.js archive checksum did not match the official manifest.", Some("Download the official Node.js archive again"), None, true);
    }
    let extract_dir = env::temp_dir().join(format!("eai-node-extract-{}", Uuid::new_v4()));
    let extract_string = extract_dir.to_string_lossy().to_string();
    if let Err(error) = fs::create_dir_all(&extract_dir) {
        return command_result("node", false, &format!("The Node.js archive could not be prepared: {error}"), None, None, true);
    }
    if let Err(error) = run_program("tar", &["-xzf", &archive_string, "-C", &extract_string]) {
        let _ = fs::remove_file(&archive);
        let _ = fs::remove_file(&checksum_file);
        let _ = fs::remove_dir_all(&extract_dir);
        return command_result("node", false, &format!("The Node.js archive could not be unpacked: {error}"), Some("Unpack the official Node.js archive"), None, true);
    }
    let folder = filename.trim_end_matches(".tar.gz");
    let extracted = extract_dir.join(folder);
    let Some(home) = env::var_os("HOME") else {
        return command_result("node", false, "The user home directory is unavailable.", Some("Retry EAI Setup from a normal user session"), None, true);
    };
    let install_root = Path::new(&home).join(".eai-setup/node");
    if let Some(parent) = install_root.parent() {
        if let Err(error) = fs::create_dir_all(parent) {
            return command_result("node", false, &format!("The user Node.js directory could not be created: {error}"), None, None, true);
        }
    }
    if install_root.exists() {
        let _ = fs::remove_dir_all(&install_root);
    }
    if let Err(error) = fs::rename(&extracted, &install_root) {
        let _ = fs::remove_file(&archive);
        let _ = fs::remove_file(&checksum_file);
        let _ = fs::remove_dir_all(&extract_dir);
        return command_result("node", false, &format!("The native Node.js installation could not be placed in the user setup directory: {error}"), Some("Install the official Node.js archive for this Mac"), None, true);
    }
    let _ = fs::remove_file(&archive);
    let _ = fs::remove_file(&checksum_file);
    let _ = fs::remove_dir_all(&extract_dir);
    if let Err(error) = expose_user_npm_bin() {
        return command_result("node", false, &format!("Node.js installed, but its user command path could not be configured: {error}"), Some("Open a new terminal after adding ~/.eai-setup/node/bin to PATH"), None, true);
    }
    if version("node", &["--version"]).is_none() || version("npm", &["--version"]).is_none() {
        return command_result(
            "node",
            false,
            "Node.js files were downloaded, but the desktop app could not run node and npm from the installed path.",
            Some("Retry EAI Setup; if the problem continues, install the official Node.js LTS release for this Mac"),
            None,
            true,
        );
    }
    emit_progress(app, "node", "Node.js and npm ready", "Continuing with the EAI CLI.", Some(100), Some(0));
    command_result("node", true, "Native Node.js and npm were installed for this user.", Some("official Node.js LTS ARM64 archive with checksum verification"), None, false)
}

fn node_pkg_install_step(app: &AppHandle) -> BootstrapResult {
    let (node_version, filename) = match latest_node_artifact() {
        Ok(artifact) => artifact,
        Err(error) => return command_result("node", false, &error, Some("Download the official Node.js LTS macOS installer"), None, true),
    };
    let url = format!("https://nodejs.org/dist/{node_version}/{filename}");
    if filename.ends_with(".tar.gz") {
        return node_tar_install_step(app, &node_version, &filename, &url);
    }
    let path = env::temp_dir().join(format!("eai-node-{}.pkg", Uuid::new_v4()));
    let path_string = path.to_string_lossy().to_string();
    emit_progress(app, "node", "Downloading Node.js", "Downloading the official signed Node.js LTS installer.", Some(10), Some(90));
    if let Err(error) = run_program("curl", &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &path_string, &url]) {
        return command_result("node", false, &error, Some("Download the official Node.js LTS installer over HTTPS"), None, true);
    }
    emit_progress(app, "node", "Checking Node.js installer", "Verifying the package signature before installation.", Some(35), Some(75));
    if let Err(error) = run_program("/usr/sbin/pkgutil", &["--check-signature", &path_string]) {
        let _ = fs::remove_file(&path);
        return command_result("node", false, &format!("The Node.js package signature could not be verified: {error}"), Some("Verify the official Node.js package signature"), None, true);
    }
    emit_progress(app, "node", "Waiting for permission", "macOS will ask once to install Node.js. No Terminal window will open.", Some(50), Some(60));
    let command = format!("/usr/sbin/installer -pkg {} -target /", shell_quote(&path_string));
    let apple_script = format!("do shell script {} with administrator privileges", applescript_quote(&command));
    if let Err(error) = run_program("/usr/bin/osascript", &["-e", &apple_script]) {
        let _ = fs::remove_file(&path);
        return command_result("node", false, &format!("macOS could not complete the Node.js installation: {error}"), Some("Approve the native macOS administrator dialog and retry"), None, true);
    }
    emit_progress(app, "node", "Finishing Node.js setup", "Checking that Node.js and npm are ready.", Some(85), Some(20));
    for attempt in 0..120 {
        if version("node", &["--version"]).is_some() && version("npm", &["--version"]).is_some() {
            let _ = fs::remove_file(&path);
            emit_progress(app, "node", "Node.js and npm ready", "Continuing with the EAI CLI.", Some(100), Some(0));
            return command_result("node", true, "Node.js and npm installation completed.", Some("official signed Node.js LTS package with native macOS authorization"), None, false);
        }
        if attempt % 5 == 0 {
            emit_progress(app, "node", "Finishing Node.js setup", "Checking that Node.js and npm are ready.", Some(85), Some(20));
        }
        thread::sleep(Duration::from_secs(1));
    }
    let _ = fs::remove_file(&path);
    command_result("node", false, "Node.js and npm did not become available after the macOS installer finished.", Some("Retry EAI Setup or install the official Node.js LTS package"), None, true)
}

// Homebrew is installed from the project's official signed package. The
// desktop flow invokes this fixed step only when brew is missing, and macOS
// owns the administrator authorization dialog rather than exposing a shell.
fn homebrew_install_step(app: &AppHandle) -> BootstrapResult {
    if !cfg!(target_os = "macos") {
        return command_result("homebrew", false, "Homebrew is only a macOS prerequisite.", None, None, false);
    }
    if version("brew", &["--version"]).is_some() {
        return command_result("homebrew", true, "Homebrew is already installed.", Some("brew --version"), None, false);
    }
    let curl = if version("curl", &["--version"]).is_some() { "curl" } else {
        return command_result("homebrew", false, "curl is required to fetch the official Homebrew installer.", Some("Install curl, then rerun EAI Setup."), None, true);
    };
    let path = env::temp_dir().join(format!("eai-homebrew-{}.pkg", Uuid::new_v4()));
    let path_string = path.to_string_lossy().to_string();
    let url = "https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg";
    emit_progress(app, "homebrew", "Downloading Homebrew", "Downloading the official signed installer.", Some(10), Some(90));
    if let Err(error) = run_program(curl, &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &path_string, url]) {
        return command_result("homebrew", false, &error, Some("Download the official Homebrew installer over HTTPS"), None, true);
    }
    emit_progress(app, "homebrew", "Checking Homebrew installer", "Verifying the package signature before installation.", Some(35), Some(75));
    if let Err(error) = run_program("/usr/sbin/pkgutil", &["--check-signature", &path_string]) {
        let _ = fs::remove_file(&path);
        return command_result("homebrew", false, &format!("The Homebrew package signature could not be verified: {error}"), Some("Verify the official Homebrew package signature"), None, true);
    }
    emit_progress(app, "homebrew", "Waiting for permission", "macOS will ask once for administrator approval. No Terminal window will open.", Some(50), Some(60));
    let command = format!("/usr/sbin/installer -pkg {} -target /", shell_quote(&path_string));
    let apple_script = format!("do shell script {} with administrator privileges", applescript_quote(&command));
    if let Err(error) = run_program("/usr/bin/osascript", &["-e", &apple_script]) {
        let _ = fs::remove_file(&path);
        let message = if error.to_lowercase().contains("user canceled") {
            "Administrator approval was cancelled. Homebrew was not installed.".to_string()
        } else {
            format!("macOS could not complete the Homebrew installation: {error}")
        };
        return command_result("homebrew", false, &message, Some("Approve the native macOS administrator dialog and retry"), None, true);
    }

    emit_progress(app, "homebrew", "Finishing Homebrew setup", "Checking that Homebrew is ready for Git and Node.js.", Some(85), Some(30));
    for attempt in 0..300 {
        if version("brew", &["--version"]).is_some() {
            let _ = fs::remove_file(&path);
            emit_progress(app, "homebrew", "Homebrew ready", "Continuing with the missing developer tools.", Some(100), Some(0));
            return command_result("homebrew", true, "Homebrew installation completed.", Some("official signed Homebrew package with native macOS authorization"), None, false);
        }
        if attempt % 5 == 0 {
            emit_progress(app, "homebrew", "Finishing Homebrew setup", "Homebrew is completing its first-run setup.", Some(85), Some(30));
        }
        thread::sleep(Duration::from_secs(1));
    }

    let _ = fs::remove_file(&path);
    command_result("homebrew", false, "Homebrew did not become available after macOS completed the installer.", Some("Retry EAI Setup or install Homebrew from the official signed package"), None, true)
}

fn run_bootstrap_sync(app: AppHandle, step: String, project_name: Option<String>, directory: Option<String>, admin_password: Option<String>) -> BootstrapResult {
    match step.as_str() {
        "homebrew" => homebrew_install_step(&app),
        "git" => package_install_step(&app, "git", "git", "Git installation completed.", admin_password.as_deref()),
        "node" => package_install_step(&app, "node", "node", "Node.js installation completed.", None),
        "eai-cli" => {
            emit_progress(&app, "eai-cli", "Installing the EAI CLI", "Downloading the canonical CLI package from npm.", Some(10), Some(45));
            let prefix = user_npm_prefix();
            let install_result = if let Some(prefix) = prefix.as_ref() {
                let prefix_string = prefix.to_string_lossy().to_string();
                match fs::create_dir_all(prefix) {
                    Ok(()) => run_program("npm", &["install", "--global", "--prefix", &prefix_string, "@enterpriseai/cli"]),
                    Err(error) => Err(error.to_string()),
                }
            } else {
                run_program("npm", &["install", "--global", "@enterpriseai/cli"])
            };
            match install_result {
                Ok((stdout, stderr)) => {
                    if let Err(error) = expose_user_npm_bin() {
                        return command_result("eai-cli", false, &format!("The EAI CLI installed, but its user command path could not be configured: {error}"), Some("Open a new terminal after adding ~/.eai-setup/npm-global/bin to PATH"), None, true);
                    }
                    emit_progress(&app, "eai-cli", "EAI CLI ready", "Verifying the eai command.", Some(90), Some(5));
                    command_result("eai-cli", true, "The EAI CLI was installed or updated for this user.", Some("npm install --global --prefix ~/.eai-setup/npm-global @enterpriseai/cli"), Some(format!("{stdout}\n{stderr}")), false)
                }
                Err(error) => command_result("eai-cli", false, &error, Some("Install the EAI CLI from npm using a user-writable prefix"), None, true),
            }
        }
        "login" => match run_program("eai", &["login"]) {
            Ok((stdout, stderr)) => command_result("login", true, "Browser sign-in completed.", Some("eai login"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result("login", false, &error, Some("eai login"), None, true),
        },
        "init" => {
            let name = project_name.unwrap_or_default();
            if !name.chars().all(|character| character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-') || name.is_empty() || name.starts_with('-') || name.ends_with('-') {
                return command_result("init", false, "Project name must be non-empty kebab-case.", None, None, true);
            }
            let directory = directory.map(std::path::PathBuf::from).unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")));
            if !directory.is_dir() {
                return command_result("init", false, "The selected project directory does not exist.", None, None, true);
            }
            match run_program_in_directory("eai", &["init", &name, "--current-dir"], Some(&directory)) {
                Ok((stdout, stderr)) => command_result("init", true, "The app was initialised and the Gofer assets are ready.", Some("eai init <project-name> --current-dir"), Some(format!("{stdout}\n{stderr}")), false),
                Err(error) => command_result("init", false, &error, Some("eai init <project-name> --current-dir"), None, true),
            }
        }
        _ => command_result(&step, false, "Unsupported bootstrap step.", None, None, false),
    }
}

#[tauri::command]
async fn run_bootstrap(app: AppHandle, step: String, project_name: Option<String>, directory: Option<String>, admin_password: Option<String>) -> BootstrapResult {
    let failure_step = step.clone();
    match tauri::async_runtime::spawn_blocking(move || run_bootstrap_sync(app, step, project_name, directory, admin_password)).await {
        Ok(result) => result,
        Err(error) => command_result(
            &failure_step,
            false,
            &format!("The setup task stopped unexpectedly: {error}"),
            Some("Retry the setup step"),
            None,
            true,
        ),
    }
}

#[tauri::command]
fn open_signup() -> Result<String, String> {
    let result = if cfg!(target_os = "macos") {
        run_program("open", &[EAI_SIGNUP_URL])
    } else if cfg!(target_os = "windows") {
        run_program("rundll32.exe", &["url.dll,FileProtocolHandler", EAI_SIGNUP_URL])
    } else {
        run_program("xdg-open", &[EAI_SIGNUP_URL])
    };
    result.map(|_| EAI_SIGNUP_URL.to_string())
}

#[tauri::command]
fn local_device_id() -> Result<String, String> {
    let home = if cfg!(target_os = "windows") {
        env::var("USERPROFILE").map_err(|_| "user profile directory is unavailable".to_string())?
    } else {
        env::var("HOME").map_err(|_| "home directory is unavailable".to_string())?
    };
    let directory = Path::new(&home).join(".eai-setup");
    fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let path = directory.join("device-id");
    if let Ok(value) = fs::read_to_string(&path) {
        let value = value.trim().to_string();
        if !value.is_empty() { return Ok(value); }
    }
    let value = Uuid::new_v4().to_string();
    fs::write(path, &value).map_err(|error| error.to_string())?;
    Ok(value)
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![detect_environment, run_bootstrap, open_signup, local_device_id])
        .run(tauri::generate_context!())
        .expect("error while running EAI Setup");
}
