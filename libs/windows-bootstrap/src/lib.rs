//! Owned startup-only SYSTEM bootstrap. It cannot launch a caller-supplied image
//! or arbitrary command. Native privileges live only on a temporary thread token.

use std::{error::Error, fmt};

/// Original executable-name metadata, and the only parent environment value
/// permitted in the SYSTEM child. This is not a credential transport.
pub const PORTABLE_APP_NAME_ENV_KEY: &str = "RUSTDESK_APPNAME";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapStage {
    InvalidRequest,
    UnsupportedPlatform,
    InspectCaller,
    PrivilegeScope,
    FindSystemToken,
    CreateEnvironment,
    LaunchProcess,
    VerifyChild,
    RestoreContext,
    ResumeChild,
}

impl BootstrapStage {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::UnsupportedPlatform => "unsupported_platform",
            Self::InspectCaller => "inspect_caller",
            Self::PrivilegeScope => "privilege_scope",
            Self::FindSystemToken => "find_system_token",
            Self::CreateEnvironment => "create_environment",
            Self::LaunchProcess => "launch_process",
            Self::VerifyChild => "verify_child",
            Self::RestoreContext => "restore_context",
            Self::ResumeChild => "resume_child",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BootstrapError {
    pub stage: BootstrapStage,
    pub win32_code: Option<u32>,
}

impl fmt::Display for BootstrapError {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            output,
            "system_bootstrap_failed stage={}",
            self.stage.code()
        )?;
        if let Some(code) = self.win32_code {
            write!(output, " win32_error={code}")?;
        }
        Ok(())
    }
}

impl Error for BootstrapError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LaunchOutcome {
    pub process_id: u32,
    pub session_id: u32,
}

#[cfg(windows)]
mod native;

/// Launch this same executable in portable-service mode, not an arbitrary
/// program. Success means a verified process was resumed, not service readiness.
#[cfg(windows)]
pub fn launch_portable_service(
    no_install: bool,
    shared_memory_name: Option<&str>,
    runtime_app_name: Option<&std::ffi::OsStr>,
) -> Result<LaunchOutcome, BootstrapError> {
    native::launch(no_install, shared_memory_name, runtime_app_name)
}

#[cfg(not(windows))]
pub fn launch_portable_service(
    _no_install: bool,
    _shared_memory_name: Option<&str>,
    _runtime_app_name: Option<&std::ffi::OsStr>,
) -> Result<LaunchOutcome, BootstrapError> {
    Err(BootstrapError {
        stage: BootstrapStage::UnsupportedPlatform,
        win32_code: None,
    })
}

#[cfg(any(windows, test))]
struct LaunchRequest {
    image: Vec<u16>,
    command: Vec<u16>,
    app_name: Option<Vec<u16>>,
}

#[cfg(any(windows, test))]
impl LaunchRequest {
    fn new(
        image: &[u16],
        no_install: bool,
        shared_memory_name: Option<&str>,
        app_name: Option<Vec<u16>>,
    ) -> Result<Self, BootstrapError> {
        let invalid = || BootstrapError {
            stage: BootstrapStage::InvalidRequest,
            win32_code: None,
        };
        if image.is_empty() || image.iter().any(|unit| [0, b'"' as u16].contains(unit)) {
            return Err(invalid());
        }
        if shared_memory_name.is_some_and(|name| {
            name.is_empty()
                || name.len() > 64
                || !name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        }) || app_name.as_ref().is_some_and(|name| {
            name.is_empty() || name.len() > 1024 || name.iter().any(|unit| *unit < 32)
        }) {
            return Err(invalid());
        }
        let mut command = vec![b'"' as u16];
        command.extend_from_slice(image);
        command.push(b'"' as u16);
        if no_install {
            command.extend(" --noinstall".encode_utf16());
        }
        command.extend(" --run-as-system".encode_utf16());
        if let Some(name) = shared_memory_name {
            command.extend(" --portable-service-shmem-name=".encode_utf16());
            command.extend(name.encode_utf16());
        }
        command.push(0);
        // CreateProcessWithTokenW documents a 1024-character command line.
        if command.len() > 1024 {
            return Err(invalid());
        }
        let mut image = image.to_vec();
        image.push(0);
        Ok(Self {
            image,
            command,
            app_name,
        })
    }
}

#[cfg(any(windows, test))]
trait BootstrapBackend {
    type Scope;
    type Token;
    type Child;

    fn prepare(&mut self) -> Result<Self::Scope, BootstrapError>;
    fn system_token(&mut self, scope: &Self::Scope) -> Result<Self::Token, BootstrapError>;
    fn start_suspended(
        &mut self,
        scope: &Self::Scope,
        token: &Self::Token,
        request: &LaunchRequest,
    ) -> Result<Self::Child, BootstrapError>;
    fn verify(&mut self, scope: &Self::Scope, child: &Self::Child) -> Result<(), BootstrapError>;
    fn restore(&mut self, scope: &mut Self::Scope) -> Result<(), BootstrapError>;
    fn resume(&mut self, child: &mut Self::Child) -> Result<(), BootstrapError>;
    fn outcome(&self, child: &Self::Child) -> LaunchOutcome;
}

#[cfg(any(windows, test))]
fn execute_bootstrap<B: BootstrapBackend>(
    backend: &mut B,
    request: &LaunchRequest,
) -> Result<LaunchOutcome, BootstrapError> {
    let mut scope = backend.prepare()?;
    let token = backend.system_token(&scope)?;
    let mut child = backend.start_suspended(&scope, &token, request)?;
    backend.verify(&scope, &child)?;
    // Resume is forbidden while the calling thread retains temporary privileges.
    // Uncommitted child and scope guards clean up in reverse order on any error.
    backend.restore(&mut scope)?;
    backend.resume(&mut child)?;
    Ok(backend.outcome(&child))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, rc::Rc};

    #[derive(Default)]
    struct Trace {
        events: Vec<&'static str>,
        privileged: bool,
        live_children: usize,
    }

    struct Scope(Rc<RefCell<Trace>>);

    impl Drop for Scope {
        fn drop(&mut self) {
            let mut trace = self.0.borrow_mut();
            if trace.privileged {
                trace.events.push("restore_on_drop");
                trace.privileged = false;
            }
        }
    }

    struct Child {
        trace: Rc<RefCell<Trace>>,
        resumed: bool,
    }

    impl Drop for Child {
        fn drop(&mut self) {
            let mut trace = self.trace.borrow_mut();
            if !self.resumed {
                trace.events.push("terminate_suspended");
            }
            trace.events.push("close_child_handles");
            trace.live_children -= 1;
        }
    }

    struct Fake {
        trace: Rc<RefCell<Trace>>,
        fail: Option<BootstrapStage>,
    }

    impl Fake {
        fn step(&self, stage: BootstrapStage) -> Result<(), BootstrapError> {
            self.trace.borrow_mut().events.push(stage.code());
            if self.fail == Some(stage) {
                return Err(BootstrapError {
                    stage,
                    win32_code: Some(5),
                });
            }
            Ok(())
        }
    }

    impl BootstrapBackend for Fake {
        type Scope = Scope;
        type Token = ();
        type Child = Child;

        fn prepare(&mut self) -> Result<Scope, BootstrapError> {
            self.step(BootstrapStage::InspectCaller)?;
            self.step(BootstrapStage::PrivilegeScope)?;
            self.trace.borrow_mut().privileged = true;
            Ok(Scope(Rc::clone(&self.trace)))
        }

        fn system_token(&mut self, _scope: &Scope) -> Result<(), BootstrapError> {
            self.step(BootstrapStage::FindSystemToken)
        }

        fn start_suspended(
            &mut self,
            _scope: &Scope,
            _token: &(),
            _request: &LaunchRequest,
        ) -> Result<Child, BootstrapError> {
            self.step(BootstrapStage::CreateEnvironment)?;
            self.step(BootstrapStage::LaunchProcess)?;
            self.trace.borrow_mut().live_children += 1;
            Ok(Child {
                trace: Rc::clone(&self.trace),
                resumed: false,
            })
        }

        fn verify(&mut self, _scope: &Scope, _child: &Child) -> Result<(), BootstrapError> {
            self.step(BootstrapStage::VerifyChild)
        }

        fn restore(&mut self, _scope: &mut Scope) -> Result<(), BootstrapError> {
            self.step(BootstrapStage::RestoreContext)?;
            self.trace.borrow_mut().privileged = false;
            Ok(())
        }

        fn resume(&mut self, child: &mut Child) -> Result<(), BootstrapError> {
            assert!(!self.trace.borrow().privileged);
            self.step(BootstrapStage::ResumeChild)?;
            child.resumed = true;
            Ok(())
        }

        fn outcome(&self, _child: &Child) -> LaunchOutcome {
            LaunchOutcome {
                process_id: 42,
                session_id: 1,
            }
        }
    }

    fn request() -> LaunchRequest {
        LaunchRequest::new(
            &r"C:\Program Files\Camellia\remote.exe"
                .encode_utf16()
                .collect::<Vec<_>>(),
            false,
            None,
            None,
        )
        .unwrap()
    }

    #[test]
    fn command_contains_only_the_fixed_image_and_validated_bootstrap_arguments() {
        let image: Vec<_> = r"C:\目录 space\remote.exe".encode_utf16().collect();
        let request = LaunchRequest::new(
            &image,
            true,
            Some("session-42_a"),
            Some("branded.exe".encode_utf16().collect()),
        )
        .unwrap();
        assert_eq!(
            String::from_utf16(&request.command[..request.command.len() - 1]).unwrap(),
            "\"C:\\目录 space\\remote.exe\" --noinstall --run-as-system --portable-service-shmem-name=session-42_a"
        );
        assert_eq!(&request.image[..request.image.len() - 1], image);
        assert_eq!(
            request.app_name.unwrap(),
            "branded.exe".encode_utf16().collect::<Vec<_>>()
        );
    }

    #[test]
    fn malformed_or_unbounded_input_is_rejected_before_any_backend_action() {
        for name in [
            "",
            "bad name",
            "bad\"arg",
            "bad&arg",
            "../name",
            &"a".repeat(65),
        ] {
            assert_eq!(
                LaunchRequest::new(&[b'a' as u16], false, Some(name), None)
                    .err()
                    .unwrap()
                    .stage,
                BootstrapStage::InvalidRequest
            );
        }
        for image in [vec![], vec![0], vec![b'"' as u16], vec![b'a' as u16; 1024]] {
            assert!(LaunchRequest::new(&image, false, None, None).is_err());
        }
        for name in [vec![], vec![0], vec![10], vec![b'a' as u16; 1025]] {
            assert!(LaunchRequest::new(&[b'a' as u16], false, None, Some(name)).is_err());
        }
    }

    #[test]
    fn every_failure_restores_context_and_terminates_only_uncommitted_children() {
        for stage in [
            BootstrapStage::InspectCaller,
            BootstrapStage::PrivilegeScope,
            BootstrapStage::FindSystemToken,
            BootstrapStage::CreateEnvironment,
            BootstrapStage::LaunchProcess,
            BootstrapStage::VerifyChild,
            BootstrapStage::RestoreContext,
            BootstrapStage::ResumeChild,
        ] {
            let trace = Rc::new(RefCell::new(Trace::default()));
            let mut backend = Fake {
                trace: Rc::clone(&trace),
                fail: Some(stage),
            };
            assert_eq!(
                execute_bootstrap(&mut backend, &request())
                    .unwrap_err()
                    .stage,
                stage
            );
            let trace = trace.borrow();
            assert!(!trace.privileged);
            assert_eq!(trace.live_children, 0);
            assert!(
                !trace.events.contains(&"resume_child") || stage == BootstrapStage::ResumeChild
            );
            let created = matches!(
                stage,
                BootstrapStage::VerifyChild
                    | BootstrapStage::RestoreContext
                    | BootstrapStage::ResumeChild
            );
            assert_eq!(trace.events.contains(&"terminate_suspended"), created);
            assert_eq!(trace.events.contains(&"close_child_handles"), created);
        }
    }

    #[test]
    fn repeated_calls_verify_then_restore_before_resuming_without_retained_state() {
        let trace = Rc::new(RefCell::new(Trace::default()));
        let mut backend = Fake {
            trace: Rc::clone(&trace),
            fail: None,
        };
        for _ in 0..3 {
            assert_eq!(
                execute_bootstrap(&mut backend, &request())
                    .unwrap()
                    .process_id,
                42
            );
        }
        let trace = trace.borrow();
        assert!(!trace.privileged);
        assert_eq!(trace.live_children, 0);
        assert!(!trace.events.contains(&"terminate_suspended"));
        assert_eq!(
            trace.events,
            [
                "inspect_caller",
                "privilege_scope",
                "find_system_token",
                "create_environment",
                "launch_process",
                "verify_child",
                "restore_context",
                "resume_child",
                "close_child_handles"
            ]
            .repeat(3)
        );
    }
}
