use serde::Serialize;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;
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

fn executable(program: &str) -> String {
    if cfg!(target_os = "macos") && program == "brew" {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if Path::new(candidate).exists() {
                return candidate.to_string();
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

fn version(program: &str, args: &[&str]) -> Option<String> {
    run_program(program, args).ok().map(|(stdout, stderr)| {
        if stdout.is_empty() { stderr } else { stdout }
    })
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
            ToolState { command: "git".to_string(), version: version("git", &["--version"]) },
            ToolState { command: "node".to_string(), version: version("node", &["--version"]) },
            ToolState { command: "npm".to_string(), version: version("npm", &["--version"]) },
            ToolState { command: "eai".to_string(), version: version("eai", &["--version"]) },
        ],
        package_manager,
    }
}

fn package_install_step(step: &str, package: &str, message: &str) -> BootstrapResult {
    if cfg!(target_os = "windows") {
        if version("winget", &["--version"]).is_none() {
            return command_result(step, false, "WinGet is not available in this Windows session.", Some("Install or enable App Installer, then rerun EAI Setup."), None, true);
        }
        let package_id = if package == "git" { "Git.Git" } else { "OpenJS.NodeJS.LTS" };
        return match run_program("winget", &["install", "--id", package_id, "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements"]) {
            Ok((stdout, stderr)) => command_result(step, true, message, Some("winget install (fixed package identifier)"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result(step, false, &error, Some("winget install (fixed package identifier)"), None, true),
        };
    }

    if cfg!(target_os = "macos") {
        if version("brew", &["--version"]).is_none() {
            return command_result(step, false, "Homebrew is not installed.", Some("Install Homebrew from https://brew.sh, then rerun EAI Setup."), None, true);
        }
        return match run_program("brew", &["install", package]) {
            Ok((stdout, stderr)) => command_result(step, true, message, Some("brew install (fixed package name)"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result(step, false, &error, Some("brew install (fixed package name)"), None, true),
        };
    }

    if version("pkexec", &["--version"]).is_none() {
        let command = if version("apt-get", &["--version"]).is_some() {
            if package == "git" { "sudo apt-get install -y git" } else { "sudo apt-get install -y nodejs npm" }
        } else if version("dnf", &["--version"]).is_some() {
            if package == "git" { "sudo dnf install -y git" } else { "sudo dnf install -y nodejs npm" }
        } else {
            "Install this prerequisite using your distribution's signed package manager."
        };
        return command_result(step, false, "Linux needs a graphical permission helper to install packages automatically.", Some(command), None, true);
    }

    if version("apt-get", &["--version"]).is_some() {
        let packages = if package == "git" { &["git"][..] } else { &["nodejs", "npm"][..] };
        if let Err(error) = run_program("pkexec", &["apt-get", "update"]) {
            return command_result(step, false, &error, Some("pkexec apt-get update"), None, true);
        }
        return match run_program("pkexec", [&["apt-get", "install", "-y"][..], packages].concat().as_slice()) {
            Ok((stdout, stderr)) => command_result(step, true, message, Some("pkexec apt-get install"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result(step, false, &error, Some("pkexec apt-get install"), None, true),
        };
    }

    if version("dnf", &["--version"]).is_some() {
        let packages = if package == "git" { &["git"][..] } else { &["nodejs", "npm"][..] };
        return match run_program("pkexec", [&["dnf", "install", "-y"][..], packages].concat().as_slice()) {
            Ok((stdout, stderr)) => command_result(step, true, message, Some("pkexec dnf install"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result(step, false, &error, Some("pkexec dnf install"), None, true),
        };
    }

    command_result(step, false, "No supported Linux package manager was found.", Some("Use your distribution's signed package manager, then retry."), None, true)
}

// Homebrew is the macOS package-manager prerequisite. The desktop flow invokes
// this fixed step only when brew is missing, and the downloaded official script
// is never built from user input.
fn homebrew_install_step() -> BootstrapResult {
    if !cfg!(target_os = "macos") {
        return command_result("homebrew", false, "Homebrew is only a macOS prerequisite.", None, None, false);
    }
    if version("brew", &["--version"]).is_some() {
        return command_result("homebrew", true, "Homebrew is already installed.", Some("brew --version"), None, false);
    }
    let curl = if version("curl", &["--version"]).is_some() { "curl" } else {
        return command_result("homebrew", false, "curl is required to fetch the official Homebrew installer.", Some("Install curl, then rerun EAI Setup."), None, true);
    };
    let path = env::temp_dir().join(format!("eai-homebrew-{}.sh", Uuid::new_v4()));
    let path_string = path.to_string_lossy().to_string();
    let url = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh";
    if let Err(error) = run_program(curl, &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &path_string, url]) {
        return command_result("homebrew", false, &error, Some("Download the official Homebrew installer over HTTPS"), None, true);
    }
    // Finder-launched desktop apps do not have a TTY. Running the Homebrew
    // script through Command::output() therefore makes its sudo step fail in
    // non-interactive mode. Use the user's real Terminal session so the
    // standard macOS administrator prompt and Homebrew output remain visible.
    let command = format!(
        "echo 'EAI Setup: approve the standard macOS administrator prompt to install Homebrew.'; /bin/bash {}",
        shell_quote(&path_string)
    );
    let apple_script = format!(
        "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script {}",
        applescript_quote(&command)
    );
    if let Err(error) = run_program("/usr/bin/osascript", &["-e", &apple_script]) {
        let _ = fs::remove_file(&path);
        return command_result("homebrew", false, &error, Some("Open Terminal for the official Homebrew installer"), None, true);
    }

    for _ in 0..900 {
        if version("brew", &["--version"]).is_some() {
            let _ = fs::remove_file(&path);
            return command_result("homebrew", true, "Homebrew installation completed.", Some("official Homebrew installer in Terminal"), None, false);
        }
        thread::sleep(Duration::from_secs(1));
    }

    let _ = fs::remove_file(&path);
    command_result("homebrew", false, "Homebrew did not become available after the administrator setup window.", Some("Finish the official Homebrew installer in Terminal, then retry EAI Setup"), None, true)
}

#[tauri::command]
fn run_bootstrap(step: String, project_name: Option<String>, directory: Option<String>) -> BootstrapResult {
    match step.as_str() {
        "homebrew" => homebrew_install_step(),
        "git" => package_install_step("git", "git", "Git installation completed."),
        "node" => package_install_step("node", "node", "Node.js installation completed."),
        "eai-cli" => match run_program("npm", &["install", "--global", "@enterpriseai/cli"]) {
            Ok((stdout, stderr)) => command_result("eai-cli", true, "The EAI CLI was installed or updated.", Some("npm install --global @enterpriseai/cli"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result("eai-cli", false, &error, Some("npm install --global @enterpriseai/cli"), None, true),
        },
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
        .invoke_handler(tauri::generate_handler![detect_environment, run_bootstrap, local_device_id])
        .run(tauri::generate_context!())
        .expect("error while running EAI Setup");
}
