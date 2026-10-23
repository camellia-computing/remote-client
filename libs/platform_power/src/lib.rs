#[cfg(any(target_os = "macos", windows))]
use anyhow::Result as ResultType;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::{force_reboot, reboot, PowerInhibitor};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::PowerInhibitor;

#[cfg(target_os = "macos")]
pub fn reboot() -> ResultType<()> {
    let output = std::process::Command::new("/usr/bin/osascript")
        .args(["-e", "tell application \"System Events\" to restart"])
        .output()?;
    if !output.status.success() || !output.stderr.is_empty() {
        anyhow::bail!("System restart request was rejected");
    }
    Ok(())
}

#[cfg(windows)]
pub fn force_reboot() -> ResultType<()> {
    use std::os::windows::io::{FromRawHandle, OwnedHandle};
    use windows::Win32::{
        Foundation::{GetLastError, HANDLE},
        Security::{
            AdjustTokenPrivileges, LookupPrivilegeValueW, SE_PRIVILEGE_ENABLED, SE_SHUTDOWN_NAME,
            TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES, TOKEN_QUERY,
        },
        System::{
            Shutdown::{
                ExitWindowsEx, EWX_FORCE, EWX_FORCEIFHUNG, EWX_REBOOT, SHTDN_REASON_FLAG_PLANNED,
                SHTDN_REASON_MAJOR_OPERATINGSYSTEM, SHTDN_REASON_MINOR_UPGRADE,
            },
            Threading::{GetCurrentProcess, OpenProcessToken},
        },
    };
    struct PrivilegeGuard {
        token: HANDLE,
        previous: TOKEN_PRIVILEGES,
    }
    impl Drop for PrivilegeGuard {
        fn drop(&mut self) {
            if let Err(error) = unsafe {
                AdjustTokenPrivileges(self.token, false, Some(&self.previous), 0, None, None)
            } {
                log::warn!("Unable to restore system restart permission: {error}");
            }
        }
    }
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )?;
        let _token = OwnedHandle::from_raw_handle(token.0);
        let mut privileges = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            ..Default::default()
        };
        LookupPrivilegeValueW(None, SE_SHUTDOWN_NAME, &mut privileges.Privileges[0].Luid)?;
        privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        let mut previous = TOKEN_PRIVILEGES::default();
        let mut previous_size = 0;
        AdjustTokenPrivileges(
            token,
            false,
            Some(&privileges),
            std::mem::size_of::<TOKEN_PRIVILEGES>() as u32,
            Some(&mut previous),
            Some(&mut previous_size),
        )?;
        if GetLastError().0 != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let _privilege = PrivilegeGuard { token, previous };
        ExitWindowsEx(
            EWX_REBOOT | EWX_FORCE | EWX_FORCEIFHUNG,
            SHTDN_REASON_MAJOR_OPERATINGSYSTEM
                | SHTDN_REASON_MINOR_UPGRADE
                | SHTDN_REASON_FLAG_PLANNED,
        )?;
    }
    Ok(())
}
