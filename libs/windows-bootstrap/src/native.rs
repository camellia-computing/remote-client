//! Clean-room Win32 adapter. No code from the retired impersonation dependency.
//! API contracts: see the primary Microsoft references in this crate's README.

use super::{
    execute_bootstrap, BootstrapBackend, BootstrapError, BootstrapStage, LaunchOutcome,
    LaunchRequest,
};
use std::{
    cmp::Ordering,
    ffi::{OsStr, OsString},
    fs::{File, OpenOptions},
    marker::PhantomData,
    mem::{size_of, zeroed},
    os::windows::{
        ffi::{OsStrExt, OsStringExt},
        fs::OpenOptionsExt,
        io::AsRawHandle,
    },
    ptr::{null, null_mut},
    rc::Rc,
    time::{Duration, Instant},
};
use winapi::{
    shared::{
        minwindef::{DWORD, FALSE, TRUE},
        ntdef::NULL,
        winerror::*,
    },
    um::{
        errhandlingapi::{GetLastError, SetLastError},
        fileapi::FILE_ID_INFO,
        handleapi::{CloseHandle, INVALID_HANDLE_VALUE},
        minwinbase::{FileIdInfo, STILL_ACTIVE},
        processthreadsapi::{
            GetCurrentProcess, GetCurrentProcessId, GetCurrentThread, GetExitCodeProcess,
            OpenProcess, OpenProcessToken, OpenThreadToken, ProcessIdToSessionId, ResumeThread,
            SetThreadToken, TerminateProcess, PROCESS_INFORMATION, STARTUPINFOW,
        },
        securitybaseapi::{
            AdjustTokenPrivileges, DuplicateTokenEx, GetTokenInformation, IsWellKnownSid,
            RevertToSelf,
        },
        stringapiset::CompareStringOrdinal,
        sysinfoapi::GetSystemDirectoryW,
        tlhelp32::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
        userenv::{CreateEnvironmentBlock, DestroyEnvironmentBlock},
        winbase::{
            CreateProcessWithTokenW, GetFileInformationByHandleEx, LookupPrivilegeValueW,
            QueryFullProcessImageNameW, CREATE_NO_WINDOW, CREATE_SUSPENDED,
            CREATE_UNICODE_ENVIRONMENT,
        },
        winnt::{
            SecurityImpersonation, TokenElevation, TokenImpersonation, TokenPrimary,
            TokenSessionId, TokenUser, WinLocalSystemSid, FILE_SHARE_READ, HANDLE,
            LUID_AND_ATTRIBUTES, PROCESS_QUERY_LIMITED_INFORMATION, SE_DEBUG_NAME,
            SE_IMPERSONATE_NAME, SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES,
            TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_IMPERSONATE, TOKEN_INFORMATION_CLASS,
            TOKEN_PRIVILEGES, TOKEN_QUERY, TOKEN_USER,
        },
    },
};

// The existing portable wrapper passes only its original executable-name
// metadata. No caller PATH, bearer token or arbitrary environment is inherited.
const APP_NAME_KEY: &str = super::PORTABLE_APP_NAME_ENV_KEY;
const MAX_ENVIRONMENT_UNITS: usize = 32768;

fn error(stage: BootstrapStage) -> BootstrapError {
    BootstrapError {
        stage,
        win32_code: Some(unsafe { GetLastError() }),
    }
}

fn rejected(stage: BootstrapStage, code: DWORD) -> BootstrapError {
    BootstrapError {
        stage,
        win32_code: Some(code),
    }
}

struct Handle(HANDLE);

impl Handle {
    fn valid(&self) -> bool {
        !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        if self.valid() && unsafe { CloseHandle(self.0) } == FALSE {
            log::error!(
                "event=system_bootstrap_cleanup_failed stage=close_handle win32_error={}",
                unsafe { GetLastError() }
            );
        }
    }
}

struct ThreadScope {
    _token: Handle,
    session: DWORD,
    active: bool,
    // Restoring another OS thread's context would be a security bug.
    _same_thread: PhantomData<Rc<()>>,
}

impl ThreadScope {
    fn restore(&mut self) -> Result<(), BootstrapError> {
        if self.active {
            if unsafe { RevertToSelf() } == FALSE {
                return Err(error(BootstrapStage::RestoreContext));
            }
            self.active = false;
        }
        Ok(())
    }
}

impl Drop for ThreadScope {
    fn drop(&mut self) {
        if let Err(failure) = self.restore() {
            log::error!("event=system_bootstrap_context_restore_failed {}", failure);
            // A caller must never continue with temporary privileges attached.
            // Exit without generating a crash dump of privileged application
            // memory or invoking an interactive crash-reporting dialog.
            std::process::exit(1);
        }
    }
}

struct Child {
    process: Handle,
    thread: Handle,
    pid: DWORD,
    session: DWORD,
    resumed: bool,
}

impl Drop for Child {
    fn drop(&mut self) {
        if !self.resumed
            && self.process.valid()
            && unsafe { TerminateProcess(self.process.0, 1) } == FALSE
        {
            let failure = unsafe { GetLastError() };
            let mut code = STILL_ACTIVE;
            if unsafe { GetExitCodeProcess(self.process.0, &mut code) } == FALSE
                || code == STILL_ACTIVE
            {
                log::error!("event=system_bootstrap_cleanup_failed stage=terminate_child child_pid={} win32_error={}", self.pid, failure);
            }
        }
    }
}

struct Environment(*mut winapi::ctypes::c_void);

impl Drop for Environment {
    fn drop(&mut self) {
        if unsafe { DestroyEnvironmentBlock(self.0) } == FALSE {
            log::error!(
                "event=system_bootstrap_cleanup_failed stage=destroy_environment win32_error={}",
                unsafe { GetLastError() }
            );
        }
    }
}

fn process_token(
    process: HANDLE,
    access: DWORD,
    stage: BootstrapStage,
) -> Result<Handle, BootstrapError> {
    let mut token = null_mut();
    if unsafe { OpenProcessToken(process, access, &mut token) } == FALSE {
        return Err(error(stage));
    }
    Ok(Handle(token))
}

fn token_u32(
    token: &Handle,
    class: TOKEN_INFORMATION_CLASS,
    stage: BootstrapStage,
) -> Result<DWORD, BootstrapError> {
    let mut value: DWORD = 0;
    let mut bytes = 0;
    if unsafe {
        GetTokenInformation(
            token.0,
            class,
            &mut value as *mut _ as _,
            size_of::<DWORD>() as _,
            &mut bytes,
        )
    } == FALSE
    {
        return Err(error(stage));
    }
    if bytes != size_of::<DWORD>() as DWORD {
        return Err(rejected(stage, ERROR_INVALID_DATA));
    }
    Ok(value)
}

fn is_system_token(
    token: &Handle,
    session: DWORD,
    stage: BootstrapStage,
) -> Result<bool, BootstrapError> {
    let mut bytes = 0;
    let probe = unsafe { GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut bytes) };
    if probe != FALSE
        || unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER
        || !(size_of::<TOKEN_USER>()..=4096).contains(&(bytes as usize))
    {
        return Err(rejected(stage, ERROR_INVALID_DATA));
    }
    // TOKEN_USER and its SID must have pointer alignment, unlike Vec<u8>.
    let mut buffer = vec![0usize; (bytes as usize).div_ceil(size_of::<usize>())];
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr() as _,
            bytes,
            &mut bytes,
        )
    } == FALSE
    {
        return Err(error(stage));
    }
    let user = unsafe { &*(buffer.as_ptr() as *const TOKEN_USER) };
    Ok(
        unsafe { IsWellKnownSid(user.User.Sid, WinLocalSystemSid) } != FALSE
            && token_u32(token, TokenSessionId, stage)? == session,
    )
}

fn enable_privilege(token: &Handle, name: &str) -> Result<(), BootstrapError> {
    let name: Vec<_> = name.encode_utf16().chain(Some(0)).collect();
    let mut luid = unsafe { zeroed() };
    if unsafe { LookupPrivilegeValueW(null(), name.as_ptr(), &mut luid) } == FALSE {
        return Err(error(BootstrapStage::PrivilegeScope));
    }
    let mut privileges = TOKEN_PRIVILEGES {
        PrivilegeCount: 1,
        Privileges: [LUID_AND_ATTRIBUTES {
            Luid: luid,
            Attributes: SE_PRIVILEGE_ENABLED,
        }],
    };
    unsafe { SetLastError(ERROR_SUCCESS) };
    let adjusted = unsafe {
        AdjustTokenPrivileges(token.0, FALSE, &mut privileges, 0, null_mut(), null_mut())
    };
    let code = unsafe { GetLastError() };
    if adjusted == FALSE || code != ERROR_SUCCESS {
        return Err(rejected(BootstrapStage::PrivilegeScope, code));
    }
    Ok(())
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct FileIdentity(u64, [u8; 16]);

fn file_identity(file: &File, stage: BootstrapStage) -> Result<FileIdentity, BootstrapError> {
    let mut info: FILE_ID_INFO = unsafe { zeroed() };
    if unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            &mut info as *mut _ as _,
            size_of::<FILE_ID_INFO>() as _,
        )
    } == FALSE
    {
        return Err(error(stage));
    }
    Ok(FileIdentity(
        info.VolumeSerialNumber,
        info.FileId.Identifier,
    ))
}

fn environment(token: &Handle, app_name: Option<&[u16]>) -> Result<Vec<u16>, BootstrapError> {
    let stage = BootstrapStage::CreateEnvironment;
    let mut raw = null_mut();
    if unsafe { CreateEnvironmentBlock(&mut raw, token.0, FALSE) } == FALSE {
        return Err(error(stage));
    }
    if raw.is_null() {
        return Err(rejected(stage, ERROR_INVALID_DATA));
    }
    let _guard = Environment(raw);
    let mut entries = Vec::<Vec<u16>>::new();
    let mut entry = Vec::new();
    let mut ended = false;
    for offset in 0..MAX_ENVIRONMENT_UNITS {
        // CreateEnvironmentBlock owns a double-NUL-terminated UTF-16 block.
        let unit = unsafe { *(raw as *const u16).add(offset) };
        if unit != 0 {
            entry.push(unit);
        } else if entry.is_empty() {
            ended = true;
            break;
        } else {
            entries.push(std::mem::take(&mut entry));
        }
    }
    if !ended {
        return Err(rejected(stage, ERROR_BAD_LENGTH));
    }
    let key: Vec<_> = APP_NAME_KEY.encode_utf16().collect();
    let mut insertion = None;
    let mut result = Vec::<Vec<u16>>::new();
    for entry in entries {
        // Preserve drive-current-directory entries such as '=C:=C:\'.
        let skip = usize::from(entry.first() == Some(&(b'=' as u16)));
        let Some(separator) = entry
            .iter()
            .enumerate()
            .skip(skip)
            .find_map(|(index, unit)| (*unit == b'=' as u16).then_some(index))
        else {
            return Err(rejected(stage, ERROR_INVALID_DATA));
        };
        let compared = unsafe {
            CompareStringOrdinal(
                entry.as_ptr(),
                separator as _,
                key.as_ptr(),
                key.len() as _,
                TRUE,
            )
        };
        let compared = match compared {
            1 => Ordering::Less,
            2 => Ordering::Equal,
            3 => Ordering::Greater,
            _ => return Err(error(stage)),
        };
        if compared == Ordering::Equal {
            continue;
        }
        if compared == Ordering::Greater && insertion.is_none() {
            insertion = Some(result.len());
        }
        result.push(entry);
    }
    if let Some(value) = app_name {
        let mut item = key;
        item.push(b'=' as u16);
        item.extend_from_slice(value);
        result.insert(insertion.unwrap_or(result.len()), item);
    }
    let size = result.iter().map(|item| item.len() + 1).sum::<usize>() + 1;
    if size > MAX_ENVIRONMENT_UNITS {
        return Err(rejected(stage, ERROR_BAD_LENGTH));
    }
    let mut block = Vec::with_capacity(size.max(2));
    for item in result {
        block.extend(item);
        block.push(0);
    }
    block.push(0);
    if block.len() == 1 {
        block.push(0);
    }
    Ok(block)
}

struct NativeBackend {
    _image: File,
    identity: FileIdentity,
    directory: Vec<u16>,
}

impl BootstrapBackend for NativeBackend {
    type Scope = ThreadScope;
    type Token = Handle;
    type Child = Child;

    fn prepare(&mut self) -> Result<ThreadScope, BootstrapError> {
        let mut existing = NULL;
        if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &mut existing) } != FALSE
        {
            let _existing = Handle(existing);
            // Startup cannot discard or elevate an existing impersonated caller.
            return Err(rejected(BootstrapStage::InspectCaller, ERROR_ACCESS_DENIED));
        }
        if unsafe { GetLastError() } != ERROR_NO_TOKEN {
            return Err(error(BootstrapStage::InspectCaller));
        }
        let process = process_token(
            unsafe { GetCurrentProcess() },
            TOKEN_QUERY | TOKEN_DUPLICATE,
            BootstrapStage::InspectCaller,
        )?;
        if token_u32(&process, TokenElevation, BootstrapStage::InspectCaller)? == 0 {
            return Err(rejected(
                BootstrapStage::InspectCaller,
                ERROR_ELEVATION_REQUIRED,
            ));
        }
        let mut session = 0;
        if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) } == FALSE {
            return Err(error(BootstrapStage::InspectCaller));
        }
        if session == 0 {
            return Err(rejected(
                BootstrapStage::InspectCaller,
                ERROR_CTX_WINSTATION_NOT_FOUND,
            ));
        }
        let mut duplicate = NULL;
        if unsafe {
            DuplicateTokenEx(
                process.0,
                TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES | TOKEN_IMPERSONATE,
                null_mut(),
                SecurityImpersonation,
                TokenImpersonation,
                &mut duplicate,
            )
        } == FALSE
        {
            return Err(error(BootstrapStage::PrivilegeScope));
        }
        let token = Handle(duplicate);
        enable_privilege(&token, SE_DEBUG_NAME)?;
        enable_privilege(&token, SE_IMPERSONATE_NAME)?;
        if unsafe { SetThreadToken(null_mut(), token.0) } == FALSE {
            return Err(error(BootstrapStage::PrivilegeScope));
        }
        Ok(ThreadScope {
            _token: token,
            session,
            active: true,
            _same_thread: PhantomData,
        })
    }

    fn system_token(&mut self, scope: &ThreadScope) -> Result<Handle, BootstrapError> {
        let stage = BootstrapStage::FindSystemToken;
        let snapshot = Handle(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) });
        if !snapshot.valid() {
            return Err(error(stage));
        }
        let mut entry: PROCESSENTRY32W = unsafe { zeroed() };
        entry.dwSize = size_of::<PROCESSENTRY32W>() as _;
        let mut available = unsafe { Process32FirstW(snapshot.0, &mut entry) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while available != FALSE {
            if Instant::now() >= deadline {
                return Err(rejected(stage, ERROR_TIMEOUT));
            }
            let size = entry
                .szExeFile
                .iter()
                .position(|unit| *unit == 0)
                .unwrap_or(entry.szExeFile.len());
            if String::from_utf16_lossy(&entry.szExeFile[..size])
                .eq_ignore_ascii_case("winlogon.exe")
            {
                let process = Handle(unsafe {
                    OpenProcess(
                        PROCESS_QUERY_LIMITED_INFORMATION,
                        FALSE,
                        entry.th32ProcessID,
                    )
                });
                if process.valid() {
                    if let Ok(token) =
                        process_token(process.0, TOKEN_QUERY | TOKEN_DUPLICATE, stage)
                    {
                        // Never trust a process name or a later re-open of its PID.
                        if is_system_token(&token, scope.session, stage)? {
                            let mut primary = NULL;
                            if unsafe {
                                DuplicateTokenEx(
                                    token.0,
                                    TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY,
                                    null_mut(),
                                    SecurityImpersonation,
                                    TokenPrimary,
                                    &mut primary,
                                )
                            } == FALSE
                            {
                                return Err(error(stage));
                            }
                            let primary = Handle(primary);
                            if !is_system_token(&primary, scope.session, stage)? {
                                return Err(rejected(stage, ERROR_ACCESS_DENIED));
                            }
                            return Ok(primary);
                        }
                    }
                }
            }
            available = unsafe { Process32NextW(snapshot.0, &mut entry) };
        }
        let code = unsafe { GetLastError() };
        Err(rejected(
            stage,
            if code == ERROR_NO_MORE_FILES {
                ERROR_NOT_FOUND
            } else {
                code
            },
        ))
    }

    fn start_suspended(
        &mut self,
        scope: &ThreadScope,
        token: &Handle,
        request: &LaunchRequest,
    ) -> Result<Child, BootstrapError> {
        let block = environment(token, request.app_name.as_deref())?;
        let mut startup: STARTUPINFOW = unsafe { zeroed() };
        startup.cb = size_of::<STARTUPINFOW>() as _;
        let mut process: PROCESS_INFORMATION = unsafe { zeroed() };
        let mut command = request.command.clone();
        if unsafe {
            CreateProcessWithTokenW(
                token.0,
                0,
                request.image.as_ptr(),
                command.as_mut_ptr(),
                CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                block.as_ptr() as _,
                self.directory.as_ptr(),
                &mut startup,
                &mut process,
            )
        } == FALSE
        {
            return Err(error(BootstrapStage::LaunchProcess));
        }
        Ok(Child {
            process: Handle(process.hProcess),
            thread: Handle(process.hThread),
            pid: process.dwProcessId,
            session: scope.session,
            resumed: false,
        })
    }

    fn verify(&mut self, scope: &ThreadScope, child: &Child) -> Result<(), BootstrapError> {
        let stage = BootstrapStage::VerifyChild;
        if !child.process.valid() || !child.thread.valid() || child.pid == 0 {
            return Err(rejected(stage, ERROR_INVALID_HANDLE));
        }
        let token = process_token(child.process.0, TOKEN_QUERY, stage)?;
        if !is_system_token(&token, scope.session, stage)? {
            return Err(rejected(stage, ERROR_ACCESS_DENIED));
        }
        let mut path = vec![0u16; 32768];
        let mut count = path.len() as DWORD;
        if unsafe { QueryFullProcessImageNameW(child.process.0, 0, path.as_mut_ptr(), &mut count) }
            == FALSE
        {
            return Err(error(stage));
        }
        if count == 0 || count as usize >= path.len() {
            return Err(rejected(stage, ERROR_INVALID_DATA));
        }
        let path = OsString::from_wide(&path[..count as usize]);
        let file = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(path)
            .map_err(|failure| {
                rejected(
                    stage,
                    failure.raw_os_error().unwrap_or(ERROR_INVALID_DATA as _) as _,
                )
            })?;
        if file_identity(&file, stage)? != self.identity {
            return Err(rejected(stage, ERROR_ACCESS_DENIED));
        }
        Ok(())
    }

    fn restore(&mut self, scope: &mut ThreadScope) -> Result<(), BootstrapError> {
        scope.restore()
    }

    fn resume(&mut self, child: &mut Child) -> Result<(), BootstrapError> {
        match unsafe { ResumeThread(child.thread.0) } {
            1 => {}
            u32::MAX => return Err(error(BootstrapStage::ResumeChild)),
            _ => return Err(rejected(BootstrapStage::ResumeChild, ERROR_INVALID_STATE)),
        }
        child.resumed = true;
        Ok(())
    }

    fn outcome(&self, child: &Child) -> LaunchOutcome {
        LaunchOutcome {
            process_id: child.pid,
            session_id: child.session,
        }
    }
}

pub(super) fn launch(
    no_install: bool,
    shared_memory_name: Option<&str>,
    app_name: Option<&OsStr>,
) -> Result<LaunchOutcome, BootstrapError> {
    let stage = BootstrapStage::InvalidRequest;
    let path = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .map_err(|failure| {
            rejected(
                stage,
                failure.raw_os_error().unwrap_or(ERROR_INVALID_DATA as _) as _,
            )
        })?;
    let request = LaunchRequest::new(
        &path.as_os_str().encode_wide().collect::<Vec<_>>(),
        no_install,
        shared_memory_name,
        app_name.map(|value| value.encode_wide().collect()),
    )?;
    // Deny writes/deletes while the same fixed image is being bootstrapped.
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .open(path)
        .map_err(|failure| {
            rejected(
                stage,
                failure.raw_os_error().unwrap_or(ERROR_INVALID_DATA as _) as _,
            )
        })?;
    let identity = file_identity(&file, stage)?;
    let mut directory = vec![0u16; 32768];
    let size =
        unsafe { GetSystemDirectoryW(directory.as_mut_ptr(), directory.len() as _) } as usize;
    if size == 0 || size >= directory.len() {
        return Err(error(stage));
    }
    directory.truncate(size + 1);
    let mut backend = NativeBackend {
        _image: file,
        identity,
        directory,
    };
    execute_bootstrap(&mut backend, &request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use winapi::um::{
        securitybaseapi::ImpersonateSelf,
        winnt::{TokenPrivileges, TokenStatistics, TOKEN_STATISTICS},
    };

    fn current_image() -> File {
        OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(std::env::current_exe().unwrap())
            .unwrap()
    }

    fn backend_for_context_test() -> NativeBackend {
        let image = current_image();
        NativeBackend {
            identity: file_identity(&image, BootstrapStage::InspectCaller).unwrap(),
            _image: image,
            directory: vec![0], // These tests must never create a child.
        }
    }

    fn thread_token() -> Result<Handle, DWORD> {
        let mut token = NULL;
        if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &mut token) } == FALSE {
            return Err(unsafe { GetLastError() });
        }
        Ok(Handle(token))
    }

    fn token_id(token: &Handle) -> (DWORD, i32) {
        let mut statistics: TOKEN_STATISTICS = unsafe { zeroed() };
        let mut bytes = 0;
        assert_ne!(
            unsafe {
                GetTokenInformation(
                    token.0,
                    TokenStatistics,
                    &mut statistics as *mut _ as _,
                    size_of::<TOKEN_STATISTICS>() as _,
                    &mut bytes,
                )
            },
            FALSE
        );
        assert_eq!(bytes as usize, size_of::<TOKEN_STATISTICS>());
        (statistics.TokenId.LowPart, statistics.TokenId.HighPart)
    }

    fn privilege_states(token: &Handle) -> Vec<(DWORD, i32, DWORD)> {
        let mut bytes = 0;
        assert_eq!(
            unsafe { GetTokenInformation(token.0, TokenPrivileges, null_mut(), 0, &mut bytes) },
            FALSE
        );
        assert!((size_of::<TOKEN_PRIVILEGES>()..=65536).contains(&(bytes as usize)));
        let mut buffer = vec![0usize; (bytes as usize).div_ceil(size_of::<usize>())];
        assert_ne!(
            unsafe {
                GetTokenInformation(
                    token.0,
                    TokenPrivileges,
                    buffer.as_mut_ptr() as _,
                    bytes,
                    &mut bytes,
                )
            },
            FALSE
        );
        let privileges = unsafe { &*(buffer.as_ptr() as *const TOKEN_PRIVILEGES) };
        let count = privileges.PrivilegeCount as usize;
        assert!(
            std::mem::offset_of!(TOKEN_PRIVILEGES, Privileges)
                + count * size_of::<LUID_AND_ATTRIBUTES>()
                <= bytes as usize
        );
        let mut states =
            unsafe { std::slice::from_raw_parts(privileges.Privileges.as_ptr(), count) }
                .iter()
                .map(|entry| {
                    (
                        entry.Luid.LowPart,
                        entry.Luid.HighPart,
                        entry.Attributes & SE_PRIVILEGE_ENABLED,
                    )
                })
                .collect::<Vec<_>>();
        states.sort_unstable();
        states
    }

    struct TestImpersonation;

    impl Drop for TestImpersonation {
        fn drop(&mut self) {
            assert_ne!(unsafe { RevertToSelf() }, FALSE);
        }
    }

    #[test]
    fn an_existing_thread_identity_is_rejected_without_replacing_it() {
        std::thread::spawn(|| {
            assert_eq!(thread_token().err(), Some(ERROR_NO_TOKEN));
            assert_ne!(unsafe { ImpersonateSelf(SecurityImpersonation) }, FALSE);
            let guard = TestImpersonation;
            let original = token_id(&thread_token().unwrap());
            let failure = backend_for_context_test().prepare().err().unwrap();
            assert_eq!(failure.stage, BootstrapStage::InspectCaller);
            assert_eq!(failure.win32_code, Some(ERROR_ACCESS_DENIED));
            assert_eq!(token_id(&thread_token().unwrap()), original);
            drop(guard);
            assert_eq!(thread_token().err(), Some(ERROR_NO_TOKEN));
        })
        .join()
        .unwrap();
    }

    #[test]
    fn repeated_scopes_leave_no_thread_identity_and_never_create_a_child() {
        std::thread::spawn(|| {
            let mut backend = backend_for_context_test();
            let parent = process_token(
                unsafe { GetCurrentProcess() },
                TOKEN_QUERY,
                BootstrapStage::InspectCaller,
            )
            .unwrap();
            let initial_privileges = privilege_states(&parent);
            for _ in 0..3 {
                assert_eq!(thread_token().err(), Some(ERROR_NO_TOKEN));
                match backend.prepare() {
                    Ok(mut scope) => {
                        assert!(thread_token().is_ok());
                        scope.restore().unwrap();
                        scope.restore().unwrap();
                        println!("bootstrap scope verified: elevated interactive branch");
                    }
                    Err(failure) => {
                        // Headless/non-elevated runners cannot certify the
                        // interactive privileged branch. Report it explicitly.
                        assert!(matches!(
                            failure.stage,
                            BootstrapStage::InspectCaller | BootstrapStage::PrivilegeScope
                        ));
                        println!("bootstrap scope denied: {failure}");
                    }
                }
                assert_eq!(thread_token().err(), Some(ERROR_NO_TOKEN));
                assert_eq!(privilege_states(&parent), initial_privileges);
            }
        })
        .join()
        .unwrap();
    }

    #[test]
    fn fresh_environment_preserves_only_the_explicit_portable_name_override() {
        let token = process_token(
            unsafe { GetCurrentProcess() },
            TOKEN_QUERY | TOKEN_DUPLICATE,
            BootstrapStage::CreateEnvironment,
        )
        .unwrap();
        let prefix = format!("{APP_NAME_KEY}=");
        let names = |block: &[u16]| {
            block
                .split(|unit| *unit == 0)
                .filter(|entry| !entry.is_empty())
                .map(String::from_utf16_lossy)
                .filter(|entry| entry.to_ascii_uppercase().starts_with(&prefix))
                .collect::<Vec<_>>()
        };
        let without = environment(&token, None).unwrap();
        assert!(without.ends_with(&[0, 0]));
        assert!(names(&without).is_empty());
        let value: Vec<_> = "approved-名字.exe".encode_utf16().collect();
        let with = environment(&token, Some(&value)).unwrap();
        assert!(with.ends_with(&[0, 0]));
        assert_eq!(names(&with), [format!("{prefix}approved-名字.exe")]);
    }

    #[test]
    fn held_image_identity_matches_a_second_handle_without_reading_contents() {
        let first = current_image();
        let second = current_image();
        assert!(
            file_identity(&first, BootstrapStage::VerifyChild).unwrap()
                == file_identity(&second, BootstrapStage::VerifyChild).unwrap()
        );
    }
}
