use serde::{Deserialize, Serialize};
use std::cmp::Reverse;
#[cfg(unix)]
use std::ffi::CStr;
use std::env;
use std::fs;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
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

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompanyApp {
    key: String,
    display_name: String,
    status: String,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompanyTenant {
    id: String,
    display_name: String,
    slug: String,
    active: bool,
    apps: Vec<CompanyApp>,
}

#[derive(Serialize)]
struct BootstrapResult {
    ok: bool,
    step: String,
    message: String,
    command: Option<String>,
    output: Option<String>,
    project_path: Option<String>,
    requires_user_action: bool,
    project_directory: Option<String>,
    app_created: bool,
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

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapSummary {
    step: String,
    detail: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AiSurface {
    id: String,
    name: String,
    provider: String,
    kind: String,
    install_url: String,
    launch_support: String,
    installed: bool,
    recommended: bool,
    previously_used: bool,
    status: String,
    next_action: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AiSurfaceInventory {
    contract_version: String,
    platform: String,
    project_directory: String,
    preferred_surface: Option<String>,
    recommended_surface: Option<String>,
    surfaces: Vec<AiSurface>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AiLaunchResult {
    action: String,
    launched: bool,
    surface_id: String,
    surface_name: String,
    project_directory: String,
    prepared_prompt: bool,
    message: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct E2eConfiguration {
    enabled: bool,
    project_name: Option<String>,
    directory: Option<String>,
    company_tenant_id: Option<String>,
    app_key: Option<String>,
    receipt_file: Option<String>,
}

const EAI_SIGNUP_URL: &str = "https://www.enterpriseaigroup.com/signup/developer";

// This is the minimum CLI version known to be compatible with this installer
// release. The installer updates an older CLI during bootstrap, but local
// readiness must not depend on a live npm metadata request: an offline check
// must distinguish "not compatible yet" from "not installed" deterministically.
const MIN_EAI_CLI_VERSION: (u64, u64, u64) = (3, 15, 8);
const MIN_NODE_MAJOR_VERSION: u64 = 24;

fn usable_home_path(path: PathBuf) -> Option<PathBuf> {
    if path.is_absolute() && path.parent().is_some() && path != Path::new("/") {
        Some(path)
    } else {
        None
    }
}

#[cfg(unix)]
fn system_user_home_dir() -> Option<PathBuf> {
    let suggested_size = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    let mut buffer_size = if suggested_size > 0 { suggested_size as usize } else { 16_384 };
    loop {
        let mut account: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result = std::ptr::null_mut();
        let mut buffer = vec![0_u8; buffer_size];
        let status = unsafe {
            libc::getpwuid_r(
                libc::geteuid(),
                &mut account,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status == libc::ERANGE && buffer_size < 1_048_576 {
            buffer_size *= 2;
            continue;
        }
        if status != 0 || result.is_null() || account.pw_dir.is_null() {
            return None;
        }
        let home = unsafe { CStr::from_ptr(account.pw_dir) }.to_str().ok()?;
        return usable_home_path(PathBuf::from(home));
    }
}

fn user_home_dir() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        return env::var_os("USERPROFILE").and_then(|value| usable_home_path(PathBuf::from(value)));
    }
    #[cfg(unix)]
    {
        return system_user_home_dir().or_else(|| {
            env::var_os("HOME").and_then(|value| usable_home_path(PathBuf::from(value)))
        });
    }
    #[allow(unreachable_code)]
    None
}

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

fn emit_summary(app: &AppHandle, step: &str, detail: &str) {
    let _ = app.emit(
        "bootstrap-summary",
        BootstrapSummary {
            step: step.to_string(),
            detail: detail.to_string(),
        },
    );
}

fn nvm_version_key(path: &Path) -> (u64, u64, u64) {
    let version = path.file_name().and_then(|value| value.to_str()).unwrap_or_default();
    let mut parts = version.trim_start_matches('v').split('.').map(|part| part.parse::<u64>().unwrap_or(0));
    (parts.next().unwrap_or(0), parts.next().unwrap_or(0), parts.next().unwrap_or(0))
}

fn nvm_node_bin_dirs() -> Vec<PathBuf> {
    let Some(home) = user_home_dir() else { return Vec::new(); };
    let nvm_root = env::var_os("NVM_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".nvm"));
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
    if let Some(home) = user_home_dir() {
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

fn windows_package_bin_dirs() -> Vec<PathBuf> {
    if !cfg!(target_os = "windows") { return Vec::new(); }
    let mut directories = Vec::new();
    for variable in ["ProgramW6432", "ProgramFiles", "ProgramFiles(Arm)", "ProgramFiles(x86)", "LOCALAPPDATA", "APPDATA"] {
        if let Some(root) = env::var_os(variable) {
            let root = PathBuf::from(root);
            directories.push(root.join("nodejs"));
            directories.push(root.join("Git/cmd"));
            directories.push(root.join("Git/bin"));
            directories.push(root.join("npm"));
            directories.push(root.join("EAI Setup/npm-global"));
            directories.push(root.join("Programs/nodejs"));
            directories.push(root.join("Programs/Git/cmd"));
        }
    }
    directories
}

#[cfg(target_os = "windows")]
fn windows_resolved_path(program: &str) -> Option<PathBuf> {
    let filename = if matches!(program, "npm" | "eai") {
        format!("{program}.cmd")
    } else {
        format!("{program}.exe")
    };
    let mut directories = windows_package_bin_dirs();
    if let Some(existing) = env::var_os("PATH") {
        directories.extend(env::split_paths(&existing));
    }
    directories
        .into_iter()
        .map(|directory| directory.join(&filename))
        .find(|path| path.is_file())
}

fn user_npm_global_exec_dirs() -> Vec<PathBuf> {
    let Some(prefix) = user_npm_prefix() else { return Vec::new(); };
    if cfg!(target_os = "windows") {
        vec![prefix.clone(), prefix.join("bin")]
    } else {
        vec![prefix.join("bin")]
    }
}

fn executable(program: &str) -> String {
    if cfg!(unix) && matches!(program, "node" | "npm" | "eai") {
        let mut directories = if program == "eai" {
            // npm's user prefix is authoritative for the CLI. A previous
            // Node installation can leave an older eai symlink in node/bin.
            user_npm_global_exec_dirs()
        } else {
            Vec::new()
        };
        directories.extend(user_node_bin_dirs());
        for directory in directories {
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
    if cfg!(target_os = "windows") {
        #[cfg(target_os = "windows")]
        if let Some(path) = windows_resolved_path(program) {
            return path.to_string_lossy().to_string();
        }
        return if matches!(program, "npm" | "eai") {
            format!("{program}.cmd")
        } else {
            program.to_string()
        };
    }
    program.to_string()
}

fn run_program(program: &str, args: &[&str]) -> Result<(String, String), String> {
    run_program_in_directory(program, args, None)
}

fn is_transient_platform_error(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    let has_transient_status = message
        .split(|character: char| !character.is_ascii_digit())
        .any(|token| matches!(token, "502" | "503" | "504"));

    has_transient_status
        || [
            "bad gateway",
            "service unavailable",
            "gateway timeout",
            "request_error",
            "temporarily unavailable",
        ]
        .iter()
        .any(|value| message.contains(value))
}

fn with_transient_retries<T, F>(attempts: usize, delay: Duration, mut operation: F) -> Result<T, String>
where
    F: FnMut() -> Result<T, String>,
{
    let attempts = attempts.max(1);
    for attempt in 0..attempts {
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) if attempt + 1 < attempts && is_transient_platform_error(&error) => {
                if !delay.is_zero() {
                    thread::sleep(delay);
                }
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("the retry loop always returns on its final attempt")
}

fn run_eai_with_retries(args: &[&str]) -> Result<(String, String), String> {
    with_transient_retries(3, Duration::from_secs(1), || run_program("eai", args))
}

fn npm_cli_script() -> Option<PathBuf> {
    let mut node_paths = vec![PathBuf::from(executable("node"))];
    #[cfg(target_os = "windows")]
    if let Some(path) = windows_resolved_path("node") {
        node_paths.push(path);
    }

    #[cfg(target_os = "windows")]
    node_paths.push(PathBuf::from(executable("npm")));

    node_paths.into_iter().filter_map(|path| path.parent().map(Path::to_path_buf)).map(|directory| {
        directory.join("node_modules/npm/bin/npm-cli.js")
    }).find(|script| script.is_file())
}

fn run_npm_in_directory_with_env(
    args: &[&str],
    directory: Option<&Path>,
    environment: &[(&str, &str)],
) -> Result<(String, String), String> {
    // npm.cmd is a Windows shell shim. Calling npm's JavaScript entry point
    // through the resolved Node executable avoids CreateProcess and shell
    // quoting differences across Windows editions and user install paths.
    if let Some(script) = npm_cli_script() {
        let script = script.to_string_lossy().to_string();
        let mut node_args = Vec::with_capacity(args.len() + 1);
        node_args.push(script.as_str());
        node_args.extend(args.iter().copied());
        return run_program_in_directory_with_env("node", &node_args, directory, environment);
    }
    run_program_in_directory_with_env("npm", args, directory, environment)
}

fn run_npm_in_directory(
    args: &[&str],
    directory: Option<&Path>,
) -> Result<(String, String), String> {
    run_npm_in_directory_with_env(args, directory, &[])
}

fn run_npm_in_directory_with_progress(
    app: &AppHandle,
    step: &str,
    args: &[&str],
    directory: Option<&Path>,
    environment: &[(&str, &str)],
) -> Result<(String, String), String> {
    let progress = Some((app.clone(), step.to_string()));
    if let Some(script) = npm_cli_script() {
        let script = script.to_string_lossy().to_string();
        let mut node_args = Vec::with_capacity(args.len() + 1);
        node_args.push(script.as_str());
        node_args.extend(args.iter().copied());
        return run_program_in_directory_with_env_and_progress("node", &node_args, directory, environment, progress);
    }
    run_program_in_directory_with_env_and_progress("npm", args, directory, environment, progress)
}

fn npm_version() -> Option<String> {
    version("npm", &["--version"]).or_else(|| {
        #[cfg(target_os = "windows")]
        {
            return run_npm_in_directory(&["--version"], None)
                .ok()
                .map(|(stdout, stderr)| if stdout.is_empty() { stderr } else { stdout });
        }
        #[cfg(not(target_os = "windows"))]
        {
            None
        }
    })
}

#[cfg(target_os = "windows")]
fn windows_shell_arg(value: &str) -> String {
    if value.is_empty() || value.chars().any(|character| character.is_whitespace() || matches!(character, '&' | '|' | '<' | '>' | '^' | '(' | ')' | '"')) {
        format!("\"{}\"", value.replace('"', "\\\""))
    } else {
        value.to_string()
    }
}

fn clean_process_output(value: &str) -> String {
    let mut clean = String::with_capacity(value.len());
    let mut in_escape = false;
    for character in value.chars() {
        if in_escape {
            if ('@'..='~').contains(&character) {
                in_escape = false;
            }
            continue;
        }
        if character == '\u{1b}' {
            in_escape = true;
            continue;
        }
        if character == '\r' {
            continue;
        }
        if character.is_control() && character != '\n' && character != '\t' {
            continue;
        }
        clean.push(character);
    }
    clean.trim().to_string()
}

fn safe_build_summary(value: &str) -> Option<&'static str> {
    let line = value.to_ascii_lowercase();
    if line.contains("cloned from") {
        Some("Downloaded the supported EAI app template.")
    } else if line.contains("updated package.json") {
        Some("Updated the project settings.")
    } else if line.contains("generated .env.local") {
        Some("Created the local app configuration.")
    } else if line.contains("created object types scaffold") {
        Some("Prepared the app data model starter files.")
    } else if line.contains("generated agents.md") || line.contains("generated claude.md") {
        Some("Prepared the AI workspace guidance.")
    } else if line.contains("installed gofer assets") {
        Some("Installed the EAI delivery guidance.")
    } else if line.contains("initialized git repository") {
        Some("Prepared local version control.")
    } else if (line.contains("added ") && line.contains(" package")) || line.contains("up to date") {
        Some("Installed the required project packages.")
    } else if line.contains("authenticated as") {
        Some("Secure browser sign-in completed.")
    } else {
        None
    }
}

fn capture_process_stream<R>(reader: R, progress: Option<(AppHandle, String)>) -> thread::JoinHandle<String>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        let mut captured = Vec::new();
        let mut bytes = Vec::new();
        loop {
            bytes.clear();
            match reader.read_until(b'\n', &mut bytes) {
                Ok(0) => break,
                Ok(_) => {}
                Err(_) => break,
            }
            let line = String::from_utf8_lossy(&bytes);
            let clean = clean_process_output(&line);
            if clean.is_empty() {
                continue;
            }
            if let (Some((app, step)), Some(summary)) = (progress.as_ref(), safe_build_summary(&clean)) {
                emit_summary(app, step, summary);
            }
            captured.push(clean);
        }
        captured.join("\n")
    })
}

fn run_program_in_directory_with_env(
    program: &str,
    args: &[&str],
    directory: Option<&Path>,
    environment: &[(&str, &str)],
) -> Result<(String, String), String> {
    run_program_in_directory_with_env_and_progress(program, args, directory, environment, None)
}

fn run_program_in_directory_with_env_and_progress(
    program: &str,
    args: &[&str],
    directory: Option<&Path>,
    environment: &[(&str, &str)],
    progress: Option<(AppHandle, String)>,
) -> Result<(String, String), String> {
    // npm exposes `eai` as a shell wrapper. Running the package entry point
    // through Node avoids Windows batch quoting and stale-process PATH issues,
    // including user profiles whose paths contain spaces.
    if program == "eai" {
        if let Some(script) = eai_cli_script() {
            let script = script.to_string_lossy().to_string();
            let mut node_args = Vec::with_capacity(args.len() + 1);
            node_args.push(script.as_str());
            node_args.extend(args.iter().copied());
            return run_program_in_directory_with_env_and_progress(
                "node",
                &node_args,
                directory,
                environment,
                progress,
            );
        }
    }
    let program_path = executable(program);
    #[cfg(target_os = "windows")]
    let mut command = if program_path.ends_with(".cmd") || program_path.ends_with(".bat") {
        // npm and EAI installed from npm are Windows batch launchers. They
        // must be invoked through the command interpreter, otherwise
        // CreateProcess reports a launcher error even when the files exist.
        let mut command = Command::new(env::var_os("ComSpec").unwrap_or_else(|| "cmd.exe".into()));
        let mut command_line = format!("call {}", windows_shell_arg(&program_path));
        for arg in args {
            command_line.push(' ');
            command_line.push_str(&windows_shell_arg(arg));
        }
        command.args(["/D", "/S", "/C"]).arg(command_line);
        command
    } else {
        let mut command = Command::new(&program_path);
        command.args(args);
        command
    };
    #[cfg(not(target_os = "windows"))]
    let mut command = {
        let mut command = Command::new(&program_path);
        command.args(args);
        command
    };
    // GUI-launched commands must never wait on a terminal that the installer
    // does not expose. Interactive commands receive explicit non-interactive
    // flags at their call site below.
    command.stdin(Stdio::null());
    #[cfg(target_os = "windows")]
    {
        // The installer is a GUI application. Keep package managers and npm
        // launchers from opening a console window over the setup dialog.
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        command.creation_flags(CREATE_NO_WINDOW);
        let mut paths = windows_package_bin_dirs();
        if let Some(existing) = env::var_os("PATH") {
            paths.extend(env::split_paths(&existing));
        }
        if let Ok(path) = env::join_paths(paths) {
            command.env("PATH", path);
        }
    }
    if cfg!(unix) {
        let mut paths = user_node_bin_dirs();
        paths.extend(macos_package_bin_dirs());
        if let Some(existing) = env::var_os("PATH") {
            paths.extend(env::split_paths(&existing));
        }
        if let Ok(path) = env::join_paths(paths) {
            command.env("PATH", path);
        }
        if let Some(home) = user_home_dir() {
            command.env("HOME", &home);
            command.env("npm_config_cache", home.join(".eai-setup/npm-cache"));
        } else {
            command.env_remove("HOME");
            command.env_remove("npm_config_cache");
        }
    }
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    command.envs(environment.iter().copied());
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|error| format!("could not start {program}: {error}"))?;
    let stdout_reader = child.stdout.take().ok_or_else(|| format!("could not read {program} output"))?;
    let stderr_reader = child.stderr.take().ok_or_else(|| format!("could not read {program} errors"))?;
    let stdout_handle = capture_process_stream(stdout_reader, progress.clone());
    let stderr_handle = capture_process_stream(stderr_reader, progress);
    let status = child.wait().map_err(|error| format!("could not wait for {program}: {error}"))?;
    let stdout = stdout_handle.join().map_err(|_| format!("could not collect {program} output"))?;
    let stderr = stderr_handle.join().map_err(|_| format!("could not collect {program} errors"))?;
    if status.success() {
        Ok((stdout, stderr))
    } else {
        Err(match (stdout.is_empty(), stderr.is_empty()) {
            (false, false) => format!("{stderr}\n{stdout}"),
            (false, true) => stdout,
            (true, false) => stderr,
            (true, true) => format!("{program} exited unsuccessfully"),
        })
    }
}

fn run_program_in_directory(
    program: &str,
    args: &[&str],
    directory: Option<&Path>,
) -> Result<(String, String), String> {
    run_program_in_directory_with_env(program, args, directory, &[])
}

fn run_program_in_directory_with_progress(
    app: &AppHandle,
    step: &str,
    program: &str,
    args: &[&str],
    directory: Option<&Path>,
) -> Result<(String, String), String> {
    run_program_in_directory_with_env_and_progress(
        program,
        args,
        directory,
        &[],
        Some((app.clone(), step.to_string())),
    )
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
    if cfg!(target_os = "windows") {
        // The official Node.js installer places npm's standard per-user
        // location on PATH. Installing there makes `eai` available to the
        // desktop app and to newly opened command windows.
        env::var_os("APPDATA").map(|root| Path::new(&root).join("npm"))
    } else if cfg!(unix) {
        user_home_dir().map(|home| home.join(".eai-setup/npm-global"))
    } else {
        None
    }
}

fn eai_cli_script() -> Option<PathBuf> {
    let prefix = user_npm_prefix()?;
    [
        prefix.join("node_modules/@enterpriseai/cli/dist/index.js"),
        prefix.join("lib/node_modules/@enterpriseai/cli/dist/index.js"),
    ]
    .into_iter()
    .find(|script| script.is_file())
}

fn expose_user_npm_bin() -> Result<(), String> {
    let Some(prefix) = user_npm_prefix() else { return Ok(()); };
    fs::create_dir_all(prefix.join("bin")).map_err(|error| error.to_string())?;
    let marker = "EAI_SETUP_NPM_GLOBAL";
    let line = "\n# EAI_SETUP_NPM_GLOBAL\nexport PATH=\"$HOME/.eai-setup/node/bin:$HOME/.eai-setup/npm-global/bin:$PATH\"\n";
    let Some(home) = user_home_dir() else { return Ok(()); };
    for filename in [".profile", ".zprofile"] {
        let path = home.join(filename);
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

fn semantic_version(value: &str) -> Option<(u64, u64, u64)> {
    let value = value.trim().trim_start_matches('v');
    let mut parts = value.split('.');
    Some((
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
        parts.next()?.split(|character: char| !character.is_ascii_digit()).next()?.parse().ok()?,
    ))
}

fn node_version() -> Option<String> {
    let current = version("node", &["--version"])?;
    let current_version = semantic_version(&current)?;
    (current_version.0 >= MIN_NODE_MAJOR_VERSION).then_some(current)
}

fn eai_cli_version() -> Option<String> {
    let current = version("eai", &["--version"])?;
    let current_version = semantic_version(&current)?;
    (current_version >= MIN_EAI_CLI_VERSION).then_some(current)
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

fn parse_windows_runtime_version(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        (fields.len() >= 3 && fields[0] == "Version" && fields[1] == "REG_SZ")
            .then(|| fields[2].to_string())
    })
}

fn windows_runtime_registry_key() -> &'static str {
    if env::consts::ARCH == "aarch64" {
        r"HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\arm64"
    } else {
        r"HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
    }
}

fn windows_runtime_package_id() -> &'static str {
    if env::consts::ARCH == "aarch64" {
        "Microsoft.VCRedist.2015+.arm64"
    } else {
        "Microsoft.VCRedist.2015+.x64"
    }
}

fn windows_vc_runtime_version() -> Option<String> {
    if !cfg!(target_os = "windows") {
        return None;
    }
    let (stdout, _) = run_program(
        "reg",
        &["query", windows_runtime_registry_key(), "/v", "Version"],
    )
    .ok()?;
    parse_windows_runtime_version(&stdout)
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
        project_path: None,
        requires_user_action,
        project_directory: None,
        app_created: false,
    }
}

fn list_company_apps(tenant_id: &str) -> Result<Vec<CompanyApp>, String> {
    let (stdout, stderr) = run_eai_with_retries(&[
        "app",
        "list",
        "--tenant-id",
        tenant_id,
        "--format",
        "json",
    ])?;
    let payload: serde_json::Value = serde_json::from_str(&stdout).map_err(|error| {
        if stderr.is_empty() {
            format!("The EAI CLI returned invalid app data: {error}")
        } else {
            format!("The EAI CLI returned invalid app data: {error} ({stderr})")
        }
    })?;
    let entries = payload
        .get("apps")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "The EAI CLI did not return app data.".to_string())?;
    let mut apps = entries
        .iter()
        .filter_map(|entry| {
            let data = entry.get("data").unwrap_or(entry);
            Some(CompanyApp {
                key: data.get("verticalKey")?.as_str()?.to_string(),
                display_name: data
                    .get("displayName")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("Untitled app")
                    .to_string(),
                status: data
                    .get("status")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("unknown")
                    .to_string(),
            })
        })
        .collect::<Vec<_>>();
    apps.sort_by_key(|app| app.key.to_ascii_lowercase());
    Ok(apps)
}

fn list_company_tenants() -> Result<Vec<CompanyTenant>, String> {
    let (stdout, stderr) = run_eai_with_retries(&["tenant", "list", "--format", "json"])?;
    parse_company_tenants(&stdout, &stderr)
}

fn parse_company_tenants(stdout: &str, stderr: &str) -> Result<Vec<CompanyTenant>, String> {
    let payload: serde_json::Value = serde_json::from_str(&stdout).map_err(|error| {
        if stderr.is_empty() {
            format!("The EAI CLI returned invalid company workspace data: {error}")
        } else {
            format!("The EAI CLI returned invalid company workspace data: {error} ({stderr})")
        }
    })?;
    let entries = payload
        .get("tenants")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "The EAI CLI did not return company workspace data.".to_string())?;

    let mut tenants = entries
        .iter()
        .filter_map(|entry| {
            let direct_membership = entry
                .get("directMembership")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let is_active = entry
                .get("isActive")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(true);
            if !direct_membership || !is_active {
                return None;
            }
            Some(CompanyTenant {
                id: entry.get("id")?.as_str()?.to_string(),
                display_name: entry.get("displayName")?.as_str()?.to_string(),
                slug: entry.get("slug")?.as_str()?.to_string(),
                active: entry
                    .get("active")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                apps: Vec::new(),
            })
        })
        .collect::<Vec<_>>();
    tenants.sort_by_key(|tenant| (!tenant.active, tenant.display_name.to_ascii_lowercase()));
    if tenants.is_empty() {
        return Err("No active company workspaces are available for this account. Ask a company administrator to add you, then sign in again.".to_string());
    }
    Ok(tenants)
}

#[tauri::command]
fn get_company_tenants() -> Result<Vec<CompanyTenant>, String> {
    list_company_tenants()
}

#[tauri::command]
fn get_company_apps(tenant_id: String) -> Result<Vec<CompanyApp>, String> {
    if tenant_id.trim().is_empty() {
        return Err("Choose a company workspace before loading its apps.".to_string());
    }
    list_company_apps(&tenant_id)
}

#[tauri::command]
fn get_e2e_configuration() -> E2eConfiguration {
    E2eConfiguration {
        enabled: env::var("EAI_SETUP_E2E").ok().as_deref() == Some("1"),
        project_name: env::var("EAI_SETUP_E2E_PROJECT_NAME").ok(),
        directory: env::var("EAI_SETUP_E2E_DIRECTORY").ok(),
        company_tenant_id: env::var("EAI_SETUP_E2E_COMPANY_TENANT").ok(),
        app_key: env::var("EAI_SETUP_E2E_APP_KEY").ok(),
        receipt_file: env::var("EAI_SETUP_E2E_RECEIPT_FILE").ok(),
    }
}

#[tauri::command]
fn verify_e2e_auth() -> Result<(), String> {
    run_program("eai", &["whoami"])
        .map(|_| ())
        .map_err(|error| format!("The saved EAI sign-in could not be verified: {error}"))
}

#[tauri::command]
fn write_e2e_receipt(receipt_file: String, receipt: serde_json::Value) -> Result<(), String> {
    if env::var("EAI_SETUP_E2E").ok().as_deref() != Some("1") {
        return Err("E2E receipt writing is only available in the release test mode.".to_string());
    }
    let path = PathBuf::from(receipt_file);
    if path.as_os_str().is_empty() {
        return Err("The E2E receipt path is empty.".to_string());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let content = serde_json::to_string_pretty(&receipt).map_err(|error| error.to_string())?;
    fs::write(path, format!("{content}\n")).map_err(|error| error.to_string())
}

fn project_directory(parent: &Path, project_name: &str) -> PathBuf {
    let selected_name = parent.file_name().and_then(|value| value.to_str());
    if selected_name == Some(project_name) {
        parent.to_path_buf()
    } else {
        parent.join(project_name)
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
    let mut tools = vec![
        ToolState { command: "git".to_string(), version: git_version() },
        ToolState { command: "node".to_string(), version: node_version() },
        ToolState { command: "npm".to_string(), version: npm_version() },
        ToolState { command: "eai".to_string(), version: eai_cli_version() },
    ];
    if cfg!(target_os = "windows") {
        tools.push(ToolState {
            command: "windows-runtime".to_string(),
            version: windows_vc_runtime_version(),
        });
    }
    EnvironmentReport {
        platform: platform.to_string(),
        architecture: env::consts::ARCH.to_string(),
        tools,
        package_manager,
    }
}

fn package_install_step(app: &AppHandle, step: &str, package: &str, message: &str, admin_password: Option<&str>) -> BootstrapResult {
    emit_progress(app, step, &format!("Installing {package}"), "Preparing the signed package manager.", Some(5), Some(60));
    if cfg!(target_os = "windows") {
        if version("winget", &["--version"]).is_none() {
            return command_result(step, false, "WinGet is not available in this Windows session.", Some("Install or enable App Installer, then rerun EAI Setup."), None, true);
        }
        let mut output = Vec::new();
        let mut errors = Vec::new();
        if package == "git" {
            match run_program("winget", &["install", "--id", "Git.Git", "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]) {
                Ok((stdout, stderr)) => output.push(format!("{stdout}\n{stderr}")),
                Err(error) => errors.push(error),
            }
        } else {
            if node_version().is_none() || npm_version().is_none() {
                let winget_node_action = if version("node", &["--version"]).is_some() { "upgrade" } else { "install" };
                match run_program("winget", &[winget_node_action, "--id", "OpenJS.NodeJS.LTS", "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]) {
                    Ok((stdout, stderr)) => output.push(format!("{stdout}\n{stderr}")),
                    Err(error) => errors.push(error),
                }
            }
            if windows_vc_runtime_version().is_none() {
                emit_progress(app, step, "Installing Windows app support", "Installing Microsoft's signed runtime required by native Node.js packages.", Some(70), Some(30));
                match run_program("winget", &["install", "--id", windows_runtime_package_id(), "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]) {
                    Ok((stdout, stderr)) => output.push(format!("{stdout}\n{stderr}")),
                    Err(error) => errors.push(error),
                }
            }
        }
        emit_progress(app, step, &format!("Checking {package}"), "Confirming the installed commands are ready.", Some(90), Some(5));
        let ready = wait_for_package_ready(package, 5);
        let install_result = if ready {
            Ok((output.join("\n"), errors.join("\n")))
        } else if errors.is_empty() {
            Ok((output.join("\n"), String::new()))
        } else {
            Err(errors.join("\n"))
        };
        return windows_package_install_result(step, package, message, install_result, ready);
    }

    if cfg!(target_os = "macos") {
        if version("brew", &["--version"]).is_none() {
            if package == "git" {
                return command_line_tools_install_step(app, admin_password);
            }
            return node_pkg_install_step(app);
        }
        let brew_action = if package == "node" && version("node", &["--version"]).is_some() { "upgrade" } else { "install" };
        let brew_result = run_program("brew", &[brew_action, package]).or_else(|error| {
            if package == "node" && brew_action == "upgrade" {
                run_program("brew", &["install", package])
            } else {
                Err(error)
            }
        });
        return match brew_result {
            Ok((stdout, stderr)) => {
                emit_progress(app, step, &format!("{package} installed"), "Verifying the installation.", Some(90), Some(5));
                package_install_verified_result(step, package, message, "brew install/upgrade (fixed package name)", Some(format!("{stdout}\n{stderr}")))
            }
            Err(error) => command_result(step, false, &error, Some("brew install/upgrade (fixed package name)"), None, true),
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
                package_install_verified_result(step, package, message, "pkexec apt-get install", Some(format!("{stdout}\n{stderr}")))
            }
            Err(error) => command_result(step, false, &error, Some("pkexec apt-get install"), None, true),
        };
    }

    if version("dnf", &["--version"]).is_some() {
        let packages = if package == "git" { &["git"][..] } else { &["nodejs", "npm"][..] };
        return match run_program("pkexec", [&["dnf", "install", "-y"][..], packages].concat().as_slice()) {
            Ok((stdout, stderr)) => {
                emit_progress(app, step, &format!("{package} installed"), "Verifying the installation.", Some(90), Some(5));
                package_install_verified_result(step, package, message, "pkexec dnf install", Some(format!("{stdout}\n{stderr}")))
            }
            Err(error) => command_result(step, false, &error, Some("pkexec dnf install"), None, true),
        };
    }

    command_result(step, false, "No supported Linux package manager was found.", Some("Use your distribution's signed package manager, then retry."), None, true)
}

fn package_ready(package: &str) -> bool {
    if package == "git" {
        git_version().is_some()
    } else {
        node_version().is_some()
            && npm_version().is_some()
            && (!cfg!(target_os = "windows") || windows_vc_runtime_version().is_some())
    }
}

fn package_install_verified_result(
    step: &str,
    package: &str,
    success_message: &str,
    command: &'static str,
    output: Option<String>,
) -> BootstrapResult {
    if package_ready(package) {
        command_result(step, true, success_message, Some(command), output, false)
    } else if package == "node" {
        command_result(
            step,
            false,
            "The package step finished, but Node.js 24 and npm are not ready.",
            Some("Install Node.js 24 LTS, then choose Try again."),
            output,
            true,
        )
    } else {
        command_result(
            step,
            false,
            "The package step finished, but the required command is not ready.",
            Some("Repair the package installation, then choose Try again."),
            output,
            true,
        )
    }
}

fn wait_for_package_ready(package: &str, attempts: usize) -> bool {
    let attempts = attempts.max(1);
    for attempt in 0..attempts {
        if package_ready(package) {
            return true;
        }
        if attempt + 1 < attempts {
            thread::sleep(Duration::from_secs(1));
        }
    }
    false
}

fn windows_package_install_result(
    step: &str,
    package: &str,
    success_message: &str,
    install_result: Result<(String, String), String>,
    ready: bool,
) -> BootstrapResult {
    let command = Some("winget install (fixed package identifier)");
    match (install_result, ready) {
        (Ok((stdout, stderr)), true) => command_result(
            step,
            true,
            success_message,
            command,
            Some(format!("{stdout}\n{stderr}")),
            false,
        ),
        (Err(error), true) => command_result(
            step,
            true,
            if package == "git" { "Git is already installed and ready." } else { "Node.js and npm are already installed and ready." },
            command,
            Some(error),
            false,
        ),
        (Ok((stdout, stderr)), false) => command_result(
            step,
            false,
            "Windows finished the package step, but the required commands are not available yet.",
            Some("Restart EAI Setup to reload the Windows command paths, then choose Try again."),
            Some(format!("{stdout}\n{stderr}")),
            true,
        ),
        (Err(error), false) => command_result(
            step,
            false,
            &error,
            Some("Repair or reinstall the signed Windows package, then choose Try again."),
            None,
            true,
        ),
    }
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
        let Some((major, _, _)) = semantic_version(version) else { continue; };
        if major < MIN_NODE_MAJOR_VERSION { continue; }
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
    Err("no supported Node.js 24 LTS macOS package was found".to_string())
}

fn node_tar_install_step(app: &AppHandle, node_version: &str, filename: &str, url: &str) -> BootstrapResult {
    let archive = env::temp_dir().join(format!("eai-node-{}.tar.gz", Uuid::new_v4()));
    let checksum_file = env::temp_dir().join(format!("eai-node-{}-SHASUMS256.txt", Uuid::new_v4()));
    let archive_string = archive.to_string_lossy().to_string();
    let checksum_string = checksum_file.to_string_lossy().to_string();
    emit_progress(app, "node", "Downloading Node.js", "Downloading the official native Node.js 24 LTS archive.", Some(10), Some(90));
    if let Err(error) = run_program("curl", &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &archive_string, url]) {
        return command_result("node", false, &error, Some("Download the official Node.js 24 LTS archive over HTTPS"), None, true);
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
    let Some(home) = user_home_dir() else {
        return command_result("node", false, "The user home directory is unavailable.", Some("Retry EAI Setup from a normal user session"), None, true);
    };
    let install_root = home.join(".eai-setup/node");
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
    if !package_ready("node") {
        return command_result(
            "node",
            false,
            "Node.js files were downloaded, but the desktop app could not run Node.js 24 and npm from the installed path.",
            Some("Retry EAI Setup; if the problem continues, install the official Node.js 24 LTS release for this Mac"),
            None,
            true,
        );
    }
    emit_progress(app, "node", "Node.js and npm ready", "Continuing with the EAI CLI.", Some(100), Some(0));
    command_result("node", true, "Native Node.js 24 and npm were installed for this user.", Some("official Node.js 24 LTS archive with checksum verification"), None, false)
}

fn node_pkg_install_step(app: &AppHandle) -> BootstrapResult {
    let (node_version, filename) = match latest_node_artifact() {
        Ok(artifact) => artifact,
        Err(error) => return command_result("node", false, &error, Some("Download the official Node.js 24 LTS macOS installer"), None, true),
    };
    let url = format!("https://nodejs.org/dist/{node_version}/{filename}");
    if filename.ends_with(".tar.gz") {
        return node_tar_install_step(app, &node_version, &filename, &url);
    }
    let path = env::temp_dir().join(format!("eai-node-{}.pkg", Uuid::new_v4()));
    let path_string = path.to_string_lossy().to_string();
    emit_progress(app, "node", "Downloading Node.js", "Downloading the official signed Node.js 24 LTS installer.", Some(10), Some(90));
    if let Err(error) = run_program("curl", &["--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", &path_string, &url]) {
        return command_result("node", false, &error, Some("Download the official Node.js 24 LTS installer over HTTPS"), None, true);
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
        if package_ready("node") {
            let _ = fs::remove_file(&path);
            emit_progress(app, "node", "Node.js and npm ready", "Continuing with the EAI CLI.", Some(100), Some(0));
            return command_result("node", true, "Node.js 24 and npm installation completed.", Some("official signed Node.js 24 LTS package with native macOS authorization"), None, false);
        }
        if attempt % 5 == 0 {
            emit_progress(app, "node", "Finishing Node.js setup", "Checking that Node.js and npm are ready.", Some(85), Some(20));
        }
        thread::sleep(Duration::from_secs(1));
    }
    let _ = fs::remove_file(&path);
    command_result("node", false, "Node.js 24 and npm did not become available after the macOS installer finished.", Some("Retry EAI Setup or install the official Node.js 24 LTS package"), None, true)
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

fn run_bootstrap_sync(app: AppHandle, step: String, project_name: Option<String>, directory: Option<String>, admin_password: Option<String>, company_tenant_id: Option<String>, app_key: Option<String>) -> BootstrapResult {
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
                    Ok(()) => run_npm_in_directory_with_progress(&app, "eai-cli", &["install", "--global", "--prefix", &prefix_string, "@enterpriseai/cli"], None, &[]),
                    Err(error) => Err(error.to_string()),
                }
            } else {
                run_npm_in_directory_with_progress(&app, "eai-cli", &["install", "--global", "@enterpriseai/cli"], None, &[])
            };
            match install_result {
                Ok((stdout, stderr)) => {
                    if let Err(error) = expose_user_npm_bin() {
                        return command_result("eai-cli", false, &format!("The EAI CLI installed, but its user command path could not be configured: {error}"), Some("Open a new terminal after adding ~/.eai-setup/npm-global/bin to PATH"), None, true);
                    }
                    emit_progress(&app, "eai-cli", "EAI CLI ready", "Verifying the eai command.", Some(90), Some(5));
                    if version("eai", &["--version"]).is_none() {
                        return command_result("eai-cli", false, "npm finished, but the installed EAI CLI could not be started.", Some("Choose Try again. If the problem continues, repair Node.js and rerun setup."), Some(format!("{stdout}\n{stderr}")), true);
                    }
                    let command = if cfg!(target_os = "windows") {
                        "npm install --global --prefix %APPDATA%\\npm @enterpriseai/cli"
                    } else {
                        "npm install --global --prefix ~/.eai-setup/npm-global @enterpriseai/cli"
                    };
                    command_result("eai-cli", true, "The EAI CLI was installed or updated for this user.", Some(command), Some(format!("{stdout}\n{stderr}")), false)
                }
                Err(error) => command_result("eai-cli", false, &error, Some("Install the EAI CLI from npm using a user-writable prefix"), None, true),
            }
        }
        "login" => match run_program_in_directory_with_progress(&app, "login", "eai", &["login"], None) {
            Ok((stdout, stderr)) => command_result("login", true, "Browser sign-in completed.", Some("eai login"), Some(format!("{stdout}\n{stderr}")), false),
            Err(error) => command_result("login", false, &error, Some("eai login"), None, true),
        },
        "init" => {
            let name = project_name.unwrap_or_default();
            if !name.chars().all(|character| character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-') || name.is_empty() || name.starts_with('-') || name.ends_with('-') {
                return command_result("init", false, "Project name must be non-empty kebab-case.", None, None, true);
            }
            let parent = directory.map(std::path::PathBuf::from).unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")));
            let directory = project_directory(&parent, &name);
            if let Err(error) = fs::create_dir_all(&directory) {
                return command_result("init", false, &format!("The app folder could not be created: {error}"), Some("Choose a writable parent folder and retry."), None, true);
            }
            if !directory.is_dir() {
                return command_result("init", false, "The app folder could not be created.", Some("Choose a writable parent folder and retry."), None, true);
            }
            let Some(company_tenant_id) = company_tenant_id.filter(|value| !value.trim().is_empty()) else {
                return command_result("init", false, "Choose a company workspace before creating the app.", Some("Select a company workspace in EAI Setup, then retry."), None, true);
            };
            let mut init_args = vec![
                "init".to_string(),
                name.clone(),
                "--company-tenant".to_string(),
                company_tenant_id,
                "--current-dir".to_string(),
                "--skip-prompts".to_string(),
                "--no-splash".to_string(),
                "--no-install".to_string(),
            ];
            let existing_app = app_key.as_ref().is_some_and(|value| !value.trim().is_empty());
            if let Some(app_key) = app_key.filter(|value| !value.trim().is_empty()) {
                init_args.extend(["--app-key".to_string(), app_key]);
            }
            let init_args_ref = init_args.iter().map(String::as_str).collect::<Vec<_>>();
            match run_program_in_directory_with_progress(&app, "init", "eai", &init_args_ref, Some(&directory)) {
                Ok((stdout, stderr)) => {
                    emit_progress(
                        &app,
                        "init",
                        "Installing app dependencies",
                        "Installing the generated project's npm packages.",
                        Some(90),
                        Some(90),
                    );
                    let npm_result = run_npm_in_directory_with_progress(
                        &app,
                        "init",
                        &["install", "--no-audit", "--no-fund"],
                        Some(&directory),
                        &[("HUSKY", "0")],
                    );
                    let (npm_stdout, npm_stderr) = match npm_result {
                        Ok(output) => output,
                        Err(error) => {
                            let mut result = command_result(
                                "init",
                                false,
                                &format!("The app was created, but its dependencies could not be installed: {error}"),
                                Some("Open the project folder and run npm install, then retry the setup."),
                                Some(format!("{stdout}\n{stderr}\n{error}")),
                                true,
                            );
                            result.project_directory = Some(directory.to_string_lossy().to_string());
                            result.project_path = Some(directory.to_string_lossy().to_string());
                            result.app_created = !existing_app;
                            return result;
                        }
                    };
                    emit_progress(
                        &app,
                        "init",
                        "App dependencies ready",
                        "The generated project and its packages are ready.",
                        Some(100),
                        Some(0),
                    );
                    let message = if existing_app {
                        "The existing app was selected and the project was initialised."
                    } else {
                        "The app was initialised and its dependencies are ready."
                    };
                    let command = if existing_app {
                        "eai init <project-name> --app-key <app-key> --company-tenant <company-tenant-id> --current-dir --skip-prompts --no-splash --no-install"
                    } else {
                        "eai init <project-name> --company-tenant <company-tenant-id> --current-dir --skip-prompts --no-splash --no-install"
                    };
                    let mut result = command_result(
                        "init",
                        true,
                        message,
                        Some(command),
                        Some(format!("{stdout}\n{stderr}\n{npm_stdout}\n{npm_stderr}")),
                        false,
                    );
                    result.project_directory = Some(directory.to_string_lossy().to_string());
                    result.project_path = Some(directory.to_string_lossy().to_string());
                    result.app_created = !existing_app;
                    result
                }
                Err(error) => {
                    let command = if existing_app {
                        "eai init <project-name> --app-key <app-key> --company-tenant <company-tenant-id> --current-dir --skip-prompts --no-splash --no-install"
                    } else {
                        "eai init <project-name> --company-tenant <company-tenant-id> --current-dir --skip-prompts --no-splash --no-install"
                    };
                    command_result("init", false, &error, Some(command), Some(error.clone()), true)
                }
            }
        }
        _ => command_result(&step, false, "Unsupported bootstrap step.", None, None, false),
    }
}

#[tauri::command]
async fn run_bootstrap(app: AppHandle, step: String, project_name: Option<String>, directory: Option<String>, admin_password: Option<String>, company_tenant_id: Option<String>, app_key: Option<String>) -> BootstrapResult {
    let failure_step = step.clone();
    match tauri::async_runtime::spawn_blocking(move || run_bootstrap_sync(app, step, project_name, directory, admin_password, company_tenant_id, app_key)).await {
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
fn detect_ai_surfaces(directory: String) -> Result<AiSurfaceInventory, String> {
    let (stdout, stderr) = run_program("eai", &["start", &directory, "--check", "--format", "json"])?;
    let inventory: AiSurfaceInventory = serde_json::from_str(&stdout).map_err(|error| {
        let detail = if stderr.is_empty() { stdout } else { stderr };
        format!("EAI could not read the installed AI workspaces: {error}. {detail}")
    })?;
    if inventory.contract_version != "eai.ai-surfaces/v1" {
        return Err(format!("EAI returned an unsupported AI workspace contract: {}", inventory.contract_version));
    }
    Ok(inventory)
}

#[tauri::command]
fn start_ai_surface(directory: String, surface_id: String) -> Result<AiLaunchResult, String> {
    let (stdout, stderr) = run_program(
        "eai",
        &["start", &directory, "--surface", &surface_id, "--format", "json"],
    )?;
    serde_json::from_str(&stdout).map_err(|error| {
        let detail = if stderr.is_empty() { stdout } else { stderr };
        format!("EAI could not confirm the AI workspace handoff: {error}. {detail}")
    })
}

#[tauri::command]
fn install_ai_surface(surface_id: String) -> Result<String, String> {
    let (stdout, _) = run_program(
        "eai",
        &["start", "--surface", &surface_id, "--install", "--format", "json"],
    )?;
    Ok(stdout)
}

#[tauri::command]
fn open_project(path: String) -> Result<(), String> {
    let directory = PathBuf::from(path);
    if !directory.is_dir() {
        return Err("The project folder is no longer available.".to_string());
    }
    let directory = directory.to_string_lossy().to_string();
    let result = if cfg!(target_os = "macos") {
        run_program("open", &[&directory])
    } else if cfg!(target_os = "windows") {
        run_program("explorer.exe", &[&directory])
    } else {
        run_program("xdg-open", &[&directory])
    };
    result.map(|_| ())
}

#[tauri::command]
fn local_device_id() -> Result<String, String> {
    let home = user_home_dir().ok_or_else(|| "user home directory is unavailable".to_string())?;
    let directory = home.join(".eai-setup");
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
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![detect_environment, run_bootstrap, get_company_tenants, get_company_apps, get_e2e_configuration, verify_e2e_auth, write_e2e_receipt, open_signup, detect_ai_surfaces, start_ai_surface, install_ai_surface, open_project, local_device_id])
        .run(tauri::generate_context!())
        .expect("error while running EAI Setup");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io::Cursor;

    #[test]
    fn managed_files_never_use_root_or_relative_home_paths() {
        assert_eq!(usable_home_path(PathBuf::from("/")), None);
        assert_eq!(usable_home_path(PathBuf::from("relative/home")), None);
        #[cfg(unix)]
        assert_eq!(usable_home_path(PathBuf::from("/Users/example")), Some(PathBuf::from("/Users/example")));
    }

    #[test]
    fn build_summaries_allow_known_milestones_and_hide_sensitive_output() {
        assert_eq!(safe_build_summary("✓ Cloned from eai-support/eai-app-template@abc123"), Some("Downloaded the supported EAI app template."));
        assert_eq!(safe_build_summary("added 225 packages in 2s"), Some("Installed the required project packages."));
        assert_eq!(safe_build_summary("ENTRA_CLIENT_SECRET=do-not-display"), None);
        assert_eq!(safe_build_summary("Tenant ID: 5dd8db37-0993-f01c-0487-e8f0fae6c3d7"), None);
        assert_eq!(safe_build_summary("/Users/example/private/project"), None);
    }

    #[test]
    fn process_stream_drains_and_decodes_non_utf8_output() {
        let output = capture_process_stream(
            Cursor::new(b"first\ninvalid-\xff-line\nlast\n".to_vec()),
            None,
        )
        .join()
        .expect("process stream reader should finish");
        assert!(output.contains("first"));
        assert!(output.contains("invalid-�-line"));
        assert!(output.contains("last"));
    }

    #[test]
    fn winget_already_current_is_success_when_commands_are_ready() {
        let result = windows_package_install_result(
            "node",
            "node",
            "Node.js installation completed.",
            Err("Found an existing package already installed. No available upgrade found.".to_string()),
            true,
        );
        assert!(result.ok);
        assert_eq!(result.message, "Node.js and npm are already installed and ready.");
        assert!(!result.requires_user_action);
    }

    #[test]
    fn winget_failure_remains_failure_when_commands_are_missing() {
        let result = windows_package_install_result(
            "node",
            "node",
            "Node.js installation completed.",
            Err("No available upgrade found.".to_string()),
            false,
        );
        assert!(!result.ok);
        assert!(result.requires_user_action);
    }

    #[test]
    fn windows_runtime_registry_output_is_parsed() {
        let output = r#"
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\arm64
    Version    REG_SZ    v14.51.36247.00
"#;
        assert_eq!(
            parse_windows_runtime_version(output),
            Some("v14.51.36247.00".to_string()),
        );
        assert_eq!(parse_windows_runtime_version("ERROR: not found"), None);
    }

    #[test]
    fn transient_platform_failures_retry_but_access_failures_do_not() {
        let attempts = Cell::new(0);
        let result = with_transient_retries(3, Duration::ZERO, || {
            attempts.set(attempts.get() + 1);
            if attempts.get() < 3 {
                Err("503 Service Unavailable".to_string())
            } else {
                Ok("ready")
            }
        });
        assert_eq!(result, Ok("ready"));
        assert_eq!(attempts.get(), 3);

        let access_attempts = Cell::new(0);
        let denied: Result<&str, String> = with_transient_retries(3, Duration::ZERO, || {
            access_attempts.set(access_attempts.get() + 1);
            Err("403 Forbidden".to_string())
        });
        assert_eq!(denied, Err("403 Forbidden".to_string()));
        assert_eq!(access_attempts.get(), 1);

        let unrelated_attempts = Cell::new(0);
        let unrelated: Result<&str, String> = with_transient_retries(3, Duration::ZERO, || {
            unrelated_attempts.set(unrelated_attempts.get() + 1);
            Err("Reference 1502 could not be found".to_string())
        });
        assert_eq!(unrelated, Err("Reference 1502 could not be found".to_string()));
        assert_eq!(unrelated_attempts.get(), 1);
    }

    #[test]
    fn company_workspace_parsing_keeps_direct_active_children_without_loading_apps() {
        let payload = r#"{
          "tenants": [
            {"id":"child-1","displayName":"Child Workspace","slug":"child-workspace","directMembership":true,"isActive":true,"active":true},
            {"id":"inherited","displayName":"Inherited","slug":"inherited","directMembership":false,"isActive":true,"active":false},
            {"id":"disabled","displayName":"Disabled","slug":"disabled","directMembership":true,"isActive":false,"active":false}
          ]
        }"#;
        let tenants = parse_company_tenants(payload, "").expect("direct active workspace should parse");
        assert_eq!(tenants.len(), 1);
        assert_eq!(tenants[0].id, "child-1");
        assert!(tenants[0].apps.is_empty());
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_node_and_npm_readiness_uses_the_native_installation() {
        if version("node", &["--version"]).is_none() {
            return;
        }
        assert!(npm_version().is_some());
        assert!(package_ready("node"));
    }
}
