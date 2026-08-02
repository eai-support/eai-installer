use serde::Serialize;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;
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
    let output = Command::new(executable(program))
        .args(args)
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

    let command = if version("apt-get", &["--version"]).is_some() {
        if package == "git" { "sudo apt-get install -y git" } else { "sudo apt-get install -y nodejs npm" }
    } else if version("dnf", &["--version"]).is_some() {
        if package == "git" { "sudo dnf install -y git" } else { "sudo dnf install -y nodejs npm" }
    } else {
        "Install this prerequisite using your distribution's signed package manager."
    };
    command_result(step, false, "Linux package installation needs an elevated user action.", Some(command), None, true)
}

// Homebrew is the macOS package-manager prerequisite. The user invokes this
// explicit step, and the downloaded official script is never built from input.
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
    let result = run_program("bash", &[&path_string]);
    let _ = fs::remove_file(&path);
    match result {
        Ok((stdout, stderr)) => command_result("homebrew", true, "Homebrew installation completed. Restart the app if brew is not yet on PATH.", Some("official Homebrew installer"), Some(format!("{stdout}\n{stderr}")), false),
        Err(error) => command_result("homebrew", false, &error, Some("official Homebrew installer"), None, true),
    }
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
        "login" => command_result("login", true, "Complete browser sign-in, then return to EAI Setup.", Some("eai login"), None, true),
        "init" => {
            let name = project_name.unwrap_or_default();
            if !name.chars().all(|character| character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-') || name.is_empty() || name.starts_with('-') || name.ends_with('-') {
                return command_result("init", false, "Project name must be non-empty kebab-case.", None, None, true);
            }
            if let Some(path) = directory.as_deref() {
                if !Path::new(path).is_dir() {
                    return command_result("init", false, "The selected project directory does not exist.", None, None, true);
                }
            }
            command_result("init", true, "Run the command in the selected folder to fetch Gofer and the app template.", Some("eai init <project-name> --current-dir"), None, true)
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
