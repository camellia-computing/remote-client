#![windows_subsystem = "windows"]

use std::{
    io,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use bin_reader::BinaryReader;

pub mod bin_reader;
#[cfg(windows)]
mod ui;

#[cfg(windows)]
const APP_METADATA: &[u8] = include_bytes!("../app_metadata.toml");
#[cfg(not(windows))]
const APP_METADATA: &[u8] = &[];
const APP_METADATA_CONFIG: &str = "meta.toml";
const PACKAGE_SHA256_PREFIX: &str = "package_sha256 = \"";
const APP_DIRECTORY: &str = "Camellia";
const PORTABLE_DIRECTORY: &str = "Portable";
const APPNAME_RUNTIME_ENV_KEY: &str = "RUSTDESK_APPNAME";
#[cfg(windows)]
const SET_FOREGROUND_WINDOW_ENV_KEY: &str = "SET_FOREGROUND_WINDOW";

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn parse_package_sha256(metadata: &[u8]) -> io::Result<&str> {
    let metadata = std::str::from_utf8(metadata)
        .map_err(|_| invalid_data("portable package metadata is not valid UTF-8"))?;
    let value = metadata
        .lines()
        .find_map(|line| {
            line.strip_prefix(PACKAGE_SHA256_PREFIX)
                .and_then(|value| value.strip_suffix('"'))
        })
        .ok_or_else(|| invalid_data("portable package metadata is missing its digest"))?;
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(invalid_data(
            "portable package metadata contains an invalid SHA-256 digest",
        ));
    }
    Ok(value)
}

fn is_package_current(dir: &Path, package_sha256: &str) -> io::Result<bool> {
    match std::fs::read(dir.join(APP_METADATA_CONFIG)) {
        Ok(metadata) => Ok(parse_package_sha256(&metadata)
            .map(|stored| stored == package_sha256)
            .unwrap_or(false)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn write_meta(dir: &Path, package_sha256: &str) -> io::Result<()> {
    std::fs::write(
        dir.join(APP_METADATA_CONFIG),
        format!("{PACKAGE_SHA256_PREFIX}{package_sha256}\"\n"),
    )
}

fn clear_directory(dir: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(dir) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(invalid_data(format!(
                "portable extraction root is unsafe: {}",
                dir.display()
            )))
        }
        Ok(_) => std::fs::remove_dir_all(dir),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn setup(
    reader: BinaryReader<'_>,
    dir: Option<PathBuf>,
    clear: bool,
    _args: &[String],
    _ui: &mut bool,
) -> io::Result<PathBuf> {
    let package_sha256 = parse_package_sha256(APP_METADATA)?;
    let dir = if let Some(dir) = dir {
        dir
    } else {
        dirs::data_local_dir()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "local app-data directory"))?
            .join(APP_DIRECTORY)
            .join(PORTABLE_DIRECTORY)
    };

    if clear || !is_package_current(&dir, package_sha256)? {
        #[cfg(windows)]
        if _args.is_empty() {
            *_ui = true;
            ui::setup();
        }
        clear_directory(&dir)?;
    }
    std::fs::create_dir_all(&dir)?;
    for file in &reader.files {
        file.write_to_file(&dir)?;
    }
    write_meta(&dir, package_sha256)?;
    #[cfg(windows)]
    if let Err(error) = win::copy_runtime_broker(&dir) {
        eprintln!("Could not prepare the optional privacy-mode broker: {error}");
    }
    #[cfg(target_os = "linux")]
    reader.configure_permission(&dir)?;

    let executable = dir.join(&reader.exe);
    let metadata = std::fs::symlink_metadata(&executable)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(invalid_data(format!(
            "portable executable is unsafe: {}",
            executable.display()
        )));
    }
    Ok(executable)
}

fn use_null_stdio() -> bool {
    false
}

fn execute(path: PathBuf, args: Vec<String>, _ui: bool) -> io::Result<()> {
    println!("executing {}", path.display());
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_name = exe.file_name().unwrap_or_default();
    let mut cmd = Command::new(path);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(winapi::um::winbase::CREATE_NO_WINDOW);
        if _ui {
            cmd.env(SET_FOREGROUND_WINDOW_ENV_KEY, "1");
        }
    }

    cmd.env(APPNAME_RUNTIME_ENV_KEY, exe_name);
    if use_null_stdio() {
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    } else {
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    }
    let child = cmd.spawn()?;

    #[cfg(windows)]
    if _ui {
        unsafe {
            winapi::um::winuser::AllowSetForegroundWindow(child.id());
        }
    }
    #[cfg(not(windows))]
    let _ = child;
    Ok(())
}

fn run() -> io::Result<()> {
    let mut args = Vec::new();
    let mut arg_exe = Default::default();
    for (index, arg) in std::env::args().enumerate() {
        if index == 0 {
            arg_exe = arg.clone();
        } else {
            args.push(arg);
        }
    }
    let click_setup = args.is_empty() && arg_exe.to_lowercase().ends_with("install.exe");
    #[cfg(windows)]
    let quick_support = args.is_empty() && win::is_quick_support_exe(&arg_exe);
    #[cfg(not(windows))]
    let quick_support = false;

    let mut ui = false;
    let package_sha256 = parse_package_sha256(APP_METADATA)?;
    let reader = BinaryReader::embedded(package_sha256)?;
    let exe = setup(
        reader,
        None,
        click_setup || args.contains(&"--silent-install".to_owned()),
        &args,
        &mut ui,
    )?;
    if click_setup {
        args = vec!["--install".to_owned()];
    } else if quick_support {
        args = vec!["--quick_support".to_owned()];
    }
    execute(exe, args, ui)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Portable launcher failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(windows)]
mod win {
    use std::{fs, os::windows::process::CommandExt, path::Path, process::Command};

    // Used for privacy mode(magnifier impl).
    pub const RUNTIME_BROKER_EXE: &str = "C:\\Windows\\System32\\RuntimeBroker.exe";
    pub const WIN_TOPMOST_INJECTED_PROCESS_EXE: &str = "RuntimeBroker_camellia_remote.exe";

    pub(super) fn copy_runtime_broker(dir: &Path) -> std::io::Result<()> {
        let src = RUNTIME_BROKER_EXE;
        let tgt = WIN_TOPMOST_INJECTED_PROCESS_EXE;
        let target_file = dir.join(tgt);
        match fs::symlink_metadata(&target_file) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "privacy-mode broker target is unsafe",
                ));
            }
            Ok(_) => {
                if let (Ok(src_file), Ok(tgt_file)) = (fs::read(src), fs::read(&target_file)) {
                    if src_file == tgt_file {
                        return Ok(());
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let _allow_err = Command::new("taskkill")
            .args(["/F", "/IM", WIN_TOPMOST_INJECTED_PROCESS_EXE])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .output();
        std::fs::copy(src, target_file)?;
        Ok(())
    }

    /// Check if the executable is a Quick Support version.
    /// Note: This function must be kept in sync with `src/core_main.rs`.
    #[inline]
    pub(super) fn is_quick_support_exe(exe: &str) -> bool {
        let exe = exe.to_lowercase();
        exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
    }
}
