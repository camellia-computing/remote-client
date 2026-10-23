use anyhow::{bail, Result as ResultType};
use dbus::{arg::OwnedFd, blocking::Connection};
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(2);
const REASON: &str = "Active Camellia remote session";

pub struct PowerInhibitor {
    session: Option<Connection>,
    cookie: Option<u32>,
    _system: Option<Connection>,
    _inhibitor: Option<OwnedFd>,
}

fn inhibition_scope(idle: bool, sleep: bool) -> Option<&'static str> {
    match (idle, sleep) {
        (false, false) => None,
        (true, false) => Some("idle"),
        (false, true) => Some("sleep"),
        (true, true) => Some("idle:sleep"),
    }
}

impl PowerInhibitor {
    pub fn new(display: bool, idle: bool, sleep: bool) -> ResultType<Self> {
        Self::with_connections(
            display,
            idle,
            sleep,
            Connection::new_system,
            Connection::new_session,
        )
    }

    fn with_connections(
        display: bool,
        idle: bool,
        sleep: bool,
        system: impl FnOnce() -> Result<Connection, dbus::Error>,
        session: impl FnOnce() -> Result<Connection, dbus::Error>,
    ) -> ResultType<Self> {
        let mut guard = Self {
            session: None,
            cookie: None,
            _system: None,
            _inhibitor: None,
        };
        if let Some(scope) = inhibition_scope(idle, sleep) {
            let system = system()?;
            let proxy =
                system.with_proxy("org.freedesktop.login1", "/org/freedesktop/login1", TIMEOUT);
            let (fd,): (OwnedFd,) = proxy.method_call(
                "org.freedesktop.login1.Manager",
                "Inhibit",
                (scope, "Camellia Remote", REASON, "block"),
            )?;
            guard._inhibitor = Some(fd);
            guard._system = Some(system);
        }
        if display {
            let session = session()?;
            let proxy = session.with_proxy(
                "org.freedesktop.ScreenSaver",
                "/org/freedesktop/ScreenSaver",
                TIMEOUT,
            );
            let (cookie,): (u32,) = proxy.method_call(
                "org.freedesktop.ScreenSaver",
                "Inhibit",
                ("com.camellia.remote", REASON),
            )?;
            guard.cookie = Some(cookie);
            guard.session = Some(session);
        }
        Ok(guard)
    }
}

impl Drop for PowerInhibitor {
    fn drop(&mut self) {
        if let (Some(session), Some(cookie)) = (&self.session, self.cookie.take()) {
            let proxy = session.with_proxy(
                "org.freedesktop.ScreenSaver",
                "/org/freedesktop/ScreenSaver",
                TIMEOUT,
            );
            let result: Result<(), _> =
                proxy.method_call("org.freedesktop.ScreenSaver", "UnInhibit", (cookie,));
            if let Err(error) = result {
                log::warn!("Unable to release display power protection: {error}");
            }
        }
    }
}

pub fn force_reboot() -> ResultType<()> {
    std::fs::write("/proc/sys/kernel/sysrq", b"128")?;
    std::fs::write("/proc/sysrq-trigger", b"b")?;
    Ok(())
}

fn reboot_accepted(result: Result<(), dbus::Error>) -> Result<bool, dbus::Error> {
    match result {
        Ok(()) => Ok(true),
        Err(error)
            if matches!(
                error.name(),
                Some(
                    "org.freedesktop.DBus.Error.ServiceUnknown"
                        | "org.freedesktop.DBus.Error.NameHasNoOwner"
                        | "org.freedesktop.DBus.Error.UnknownInterface"
                        | "org.freedesktop.DBus.Error.UnknownMethod"
                        | "org.freedesktop.DBus.Error.UnknownObject"
                )
            ) =>
        {
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

pub fn reboot() -> ResultType<()> {
    if let Ok(session) = Connection::new_session() {
        let gnome = session.with_proxy(
            "org.gnome.SessionManager",
            "/org/gnome/SessionManager",
            TIMEOUT,
        );
        let result: Result<(), _> = gnome.method_call("org.gnome.SessionManager", "Reboot", ());
        if reboot_accepted(result)? {
            return Ok(());
        }
        let kde = session.with_proxy("org.kde.ksmserver", "/KSMServer", TIMEOUT);
        let result: Result<(), _> =
            kde.method_call("org.kde.KSMServerInterface", "logout", (-1i32, 1i32, 2i32));
        if reboot_accepted(result)? {
            return Ok(());
        }
        let xfce = session.with_proxy(
            "org.xfce.SessionManager",
            "/org/xfce/SessionManager",
            TIMEOUT,
        );
        let result: Result<(), _> = xfce.method_call("org.xfce.SessionManager", "Restart", (true,));
        if reboot_accepted(result)? {
            return Ok(());
        }
    }
    if let Ok(system) = Connection::new_system() {
        let login = system.with_proxy("org.freedesktop.login1", "/org/freedesktop/login1", TIMEOUT);
        let result: Result<(), _> =
            login.method_call("org.freedesktop.login1.Manager", "Reboot", (true,));
        if reboot_accepted(result)? {
            return Ok(());
        }
    }
    let status = std::process::Command::new("shutdown")
        .args(["-r", "now"])
        .status()?;
    if !status.success() {
        bail!("System restart request was rejected");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use dbus::{channel::MatchingReceiver, message::MatchRule};
    use dbus_crossroads::Crossroads;
    use std::{
        io::{BufRead, BufReader, Read},
        os::unix::{io::IntoRawFd, net::UnixStream},
        process::{Child, Command, Stdio},
        sync::{
            atomic::{AtomicBool, AtomicUsize, Ordering},
            Arc, Mutex,
        },
        thread::JoinHandle,
    };

    struct ServiceState {
        fail_display: bool,
        releases: AtomicUsize,
        scopes: Mutex<Vec<String>>,
        peers: Mutex<Vec<UnixStream>>,
    }

    struct TestBus {
        daemon: Child,
        address: String,
        state: Arc<ServiceState>,
        stop: Arc<AtomicBool>,
        service: Option<JoinHandle<()>>,
    }

    impl TestBus {
        fn start(fail_display: bool) -> Self {
            let mut daemon = Command::new("dbus-daemon")
                .args(["--session", "--nofork", "--print-address=1"])
                .arg(format!(
                    "--address=unix:abstract=camellia-power-{}",
                    uuid::Uuid::new_v4()
                ))
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let mut address = String::new();
            BufReader::new(daemon.stdout.take().unwrap())
                .read_line(&mut address)
                .unwrap();
            let connection = Connection::new_address(address.trim()).unwrap();
            connection
                .request_name("org.freedesktop.login1", false, true, false)
                .unwrap();
            connection
                .request_name("org.freedesktop.ScreenSaver", false, true, false)
                .unwrap();
            let state = Arc::new(ServiceState {
                fail_display,
                releases: AtomicUsize::new(0),
                scopes: Mutex::new(Vec::new()),
                peers: Mutex::new(Vec::new()),
            });
            let mut crossroads = Crossroads::new();
            let login = crossroads.register("org.freedesktop.login1.Manager", |builder| {
                builder.method(
                    "Inhibit",
                    ("what", "who", "why", "mode"),
                    ("fd",),
                    |_,
                     state: &mut Arc<ServiceState>,
                     (what, who, why, mode): (String, String, String, String)| {
                        assert!(!who.is_empty());
                        assert_eq!(why, REASON);
                        assert_eq!(mode, "block");
                        state.scopes.lock().unwrap().push(what);
                        let (fd, peer) = UnixStream::pair().unwrap();
                        state.peers.lock().unwrap().push(peer);
                        Ok((unsafe { OwnedFd::new(fd.into_raw_fd()) },))
                    },
                );
            });
            let saver = crossroads.register("org.freedesktop.ScreenSaver", |builder| {
                builder.method(
                    "Inhibit",
                    ("application", "reason"),
                    ("cookie",),
                    |_, state: &mut Arc<ServiceState>, (application, reason): (String, String)| {
                        assert_eq!(application, "com.camellia.remote");
                        assert_eq!(reason, REASON);
                        if state.fail_display {
                            return Err(dbus::MethodErr::failed("injected display failure"));
                        }
                        Ok((7u32,))
                    },
                );
                builder.method(
                    "UnInhibit",
                    ("cookie",),
                    (),
                    |_, state: &mut Arc<ServiceState>, (cookie,): (u32,)| {
                        assert_eq!(cookie, 7);
                        state.releases.fetch_add(1, Ordering::SeqCst);
                        Ok(())
                    },
                );
            });
            crossroads.insert("/org/freedesktop/login1", &[login], Arc::clone(&state));
            crossroads.insert("/org/freedesktop/ScreenSaver", &[saver], Arc::clone(&state));
            connection.start_receive(
                MatchRule::new_method_call(),
                Box::new(move |message, connection| {
                    crossroads.handle_message(message, connection).unwrap();
                    true
                }),
            );
            let stop = Arc::new(AtomicBool::new(false));
            let service_stop = Arc::clone(&stop);
            let service = std::thread::spawn(move || {
                while !service_stop.load(Ordering::SeqCst) {
                    connection.process(Duration::from_millis(20)).unwrap();
                }
            });
            Self {
                daemon,
                address: address.trim().to_owned(),
                state,
                stop,
                service: Some(service),
            }
        }

        fn acquire(&self) -> ResultType<PowerInhibitor> {
            PowerInhibitor::with_connections(
                true,
                true,
                true,
                || Connection::new_address(&self.address),
                || Connection::new_address(&self.address),
            )
        }

        fn assert_fd_released(&self) {
            let mut peers = self.state.peers.lock().unwrap();
            assert_eq!(peers.len(), 1);
            peers[0]
                .set_read_timeout(Some(Duration::from_secs(1)))
                .unwrap();
            assert_eq!(peers[0].read(&mut [0u8; 1]).unwrap(), 0);
        }
    }

    impl Drop for TestBus {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(service) = self.service.take() {
                let _ = service.join();
            }
            let _ = self.daemon.kill();
            let _ = self.daemon.wait();
        }
    }

    #[test]
    fn private_bus_protection_is_released_on_drop() {
        let bus = TestBus::start(false);
        let guard = bus.acquire().unwrap();
        assert_eq!(*bus.state.scopes.lock().unwrap(), ["idle:sleep"]);
        assert_eq!(bus.state.releases.load(Ordering::SeqCst), 0);
        drop(guard);
        assert_eq!(bus.state.releases.load(Ordering::SeqCst), 1);
        bus.assert_fd_released();
    }

    #[test]
    fn partial_acquisition_failure_releases_system_protection() {
        let bus = TestBus::start(true);
        assert!(bus.acquire().is_err());
        assert_eq!(bus.state.releases.load(Ordering::SeqCst), 0);
        bus.assert_fd_released();
    }

    #[test]
    fn scope_matches_requested_protection() {
        assert_eq!(inhibition_scope(false, false), None);
        assert_eq!(inhibition_scope(true, false), Some("idle"));
        assert_eq!(inhibition_scope(false, true), Some("sleep"));
        assert_eq!(inhibition_scope(true, true), Some("idle:sleep"));
    }

    #[test]
    fn cancelled_restart_cannot_fall_through_to_another_backend() {
        let cancelled = dbus::Error::new_custom(
            "org.gtk.GDBus.UnmappedGError.Quark._g_2dio_2derror_2dquark.Code19",
            "cancelled",
        );
        assert!(reboot_accepted(Err(cancelled)).is_err());
        assert!(reboot_accepted(Err(dbus::Error::new_failed("unknown result"))).is_err());
        for name in [
            "org.freedesktop.DBus.Error.AccessDenied",
            "org.freedesktop.DBus.Error.NoReply",
            "org.freedesktop.login1.OperationInProgress",
        ] {
            assert!(reboot_accepted(Err(dbus::Error::new_custom(name, "rejected"))).is_err());
        }
        assert!(!reboot_accepted(Err(dbus::Error::new_custom(
            "org.freedesktop.DBus.Error.ServiceUnknown",
            "unavailable",
        )))
        .unwrap());
        assert!(reboot_accepted(Ok(())).unwrap());
    }

    #[test]
    fn no_requested_protection_requires_no_bus() {
        let guard = PowerInhibitor::new(false, false, false).unwrap();
        assert!(guard.session.is_none());
        assert!(guard._system.is_none());
        assert!(guard._inhibitor.is_none());
    }
}
