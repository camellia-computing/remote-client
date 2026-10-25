//! Native management-write reservations. Only ID/time/opaque scope are stored.
//! Independent of Flutter/config/network so its filesystem contract can be
//! tested without compiling the desktop capture or codec dependency graph.

use std::{
    fs::{self, DirBuilder, File, OpenOptions, TryLockError},
    io::{Read, Write},
    path::Path,
    sync::{Mutex, TryLockError as MutexTryLockError},
};

const MAX_RECORD_BYTES: u64 = 256;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const LOCK_NAME: &str = ".journal.lock";
static PROCESS_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum JournalError {
    Busy,
    Unavailable,
    Corrupt,
    InvalidRecord,
    Pending,
    IdentityConflict,
}

impl JournalError {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Busy => "journal_busy",
            Self::Unavailable => "journal_unavailable",
            Self::Corrupt => "journal_corrupt",
            Self::InvalidRecord => "invalid_journal_record",
            Self::Pending => "journal_pending",
            Self::IdentityConflict => "journal_identity_conflict",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PendingOperation {
    pub(crate) operation_id: String,
    pub(crate) scope: String,
    pub(crate) created_at_ms: u64,
}

fn lowercase_hex(value: &[u8]) -> bool {
    value
        .iter()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

fn uuid4(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && [8, 13, 18, 23].iter().all(|index| bytes[*index] == b'-')
        && bytes[14] == b'4'
        && matches!(bytes[19], b'8' | b'9' | b'a' | b'b')
        && bytes.iter().enumerate().all(|(index, byte)| {
            [8, 13, 18, 23].contains(&index) || lowercase_hex(std::slice::from_ref(byte))
        })
}

impl PendingOperation {
    fn validate(&self) -> Result<(), JournalError> {
        if !uuid4(&self.operation_id)
            || self.scope.len() != 64
            || !lowercase_hex(self.scope.as_bytes())
            || self.created_at_ms > MAX_SAFE_INTEGER
        {
            return Err(JournalError::InvalidRecord);
        }
        Ok(())
    }

    fn filename(&self) -> String {
        format!("{}.pending", self.operation_id)
    }

    fn encode(&self) -> String {
        format!(
            "camellia-ab-operation-v1\n{}\n{}\n{}\n",
            self.operation_id, self.scope, self.created_at_ms
        )
    }

    fn decode(bytes: &[u8]) -> Result<Self, JournalError> {
        let text = std::str::from_utf8(bytes).map_err(|_| JournalError::Corrupt)?;
        let fields: Vec<_> = text.split('\n').collect();
        if fields.len() != 5 || fields[0] != "camellia-ab-operation-v1" || !fields[4].is_empty() {
            return Err(JournalError::Corrupt);
        }
        let created_at_ms: u64 = fields[3].parse().map_err(|_| JournalError::Corrupt)?;
        if created_at_ms.to_string() != fields[3] {
            return Err(JournalError::Corrupt);
        }
        let record = Self {
            operation_id: fields[1].to_owned(),
            scope: fields[2].to_owned(),
            created_at_ms,
        };
        record.validate().map_err(|_| JournalError::Corrupt)?;
        Ok(record)
    }
}

fn sync_directory(path: &Path) -> Result<(), JournalError> {
    #[cfg(unix)]
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|_| JournalError::Unavailable)?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn ensure_directory(path: &Path) -> Result<(), JournalError> {
    let mut builder = DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    match builder.create(path) {
        Ok(()) => sync_directory(path.parent().ok_or(JournalError::Unavailable)?)?,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(JournalError::Unavailable),
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| JournalError::Unavailable)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(JournalError::Corrupt);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o777 != 0o700 {
            return Err(JournalError::Corrupt);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            // FILE_ATTRIBUTE_REPARSE_POINT
            return Err(JournalError::Corrupt);
        }
    }
    Ok(())
}

fn verify_file(path: &Path, file: &File) -> Result<(), JournalError> {
    let named = fs::symlink_metadata(path).map_err(|_| JournalError::Unavailable)?;
    let opened = file.metadata().map_err(|_| JournalError::Unavailable)?;
    if !named.is_file() || named.file_type().is_symlink() || !opened.is_file() {
        return Err(JournalError::Corrupt);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if named.dev() != opened.dev()
            || named.ino() != opened.ino()
            || opened.nlink() != 1
            || opened.permissions().mode() & 0o777 != 0o600
        {
            return Err(JournalError::Corrupt);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if named.file_attributes() & 0x400 != 0 || opened.file_attributes() & 0x400 != 0 {
            return Err(JournalError::Corrupt);
        }
    }
    Ok(())
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn locked<T>(
    directory: &Path,
    operation: impl FnOnce(&Path) -> Result<T, JournalError>,
) -> Result<T, JournalError> {
    // Unlike Dart's POSIX advisory locks, this also serializes isolate engines
    // in one native process. OS locking covers independent client processes.
    let _process = PROCESS_LOCK.try_lock().map_err(|error| match error {
        MutexTryLockError::WouldBlock => JournalError::Busy,
        MutexTryLockError::Poisoned(_) => JournalError::Unavailable,
    })?;
    ensure_directory(directory)?;
    let lock_path = directory.join(LOCK_NAME);
    let lock = private_options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|_| JournalError::Unavailable)?;
    verify_file(&lock_path, &lock)?;
    lock.try_lock().map_err(|error| match error {
        TryLockError::WouldBlock => JournalError::Busy,
        TryLockError::Error(_) => JournalError::Unavailable,
    })?;
    verify_file(&lock_path, &lock)?;
    let result = operation(directory);
    lock.unlock().map_err(|_| JournalError::Unavailable)?;
    result
}

fn pending_locked(directory: &Path) -> Result<Option<PendingOperation>, JournalError> {
    let mut pending = None;
    for (index, entry) in fs::read_dir(directory)
        .map_err(|_| JournalError::Unavailable)?
        .enumerate()
    {
        if index >= 3 {
            return Err(JournalError::Corrupt);
        }
        let entry = entry.map_err(|_| JournalError::Unavailable)?;
        let name = entry.file_name();
        if name == LOCK_NAME {
            continue;
        }
        let Some(name) = name.to_str() else {
            return Err(JournalError::Corrupt);
        };
        let Some(id) = name.strip_suffix(".pending") else {
            return Err(JournalError::Corrupt);
        };
        if !uuid4(id) || pending.is_some() {
            return Err(JournalError::Corrupt);
        }
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|_| JournalError::Unavailable)?;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || metadata.len() > MAX_RECORD_BYTES
        {
            return Err(JournalError::Corrupt);
        }
        let file = File::open(&path).map_err(|_| JournalError::Unavailable)?;
        verify_file(&path, &file)?;
        let mut bytes = Vec::new();
        file.take(MAX_RECORD_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| JournalError::Unavailable)?;
        if bytes.len() as u64 > MAX_RECORD_BYTES {
            return Err(JournalError::Corrupt);
        }
        let record = PendingOperation::decode(&bytes)?;
        if record.operation_id != id {
            return Err(JournalError::Corrupt);
        }
        pending = Some(record);
    }
    Ok(pending)
}

pub(crate) fn pending(directory: &Path) -> Result<Option<PendingOperation>, JournalError> {
    locked(directory, pending_locked)
}

pub(crate) fn reserve(directory: &Path, record: &PendingOperation) -> Result<(), JournalError> {
    record.validate()?;
    locked(directory, |directory| {
        if pending_locked(directory)?.is_some() {
            return Err(JournalError::Pending);
        }
        let path = directory.join(record.filename());
        let mut file = private_options()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|_| JournalError::Unavailable)?;
        verify_file(&path, &file)?;
        // On short write, disk-full or fsync failure leave the file intact and
        // fail closed. Never hide evidence by deleting a failed reservation.
        file.write_all(record.encode().as_bytes())
            .map_err(|_| JournalError::Unavailable)?;
        file.sync_all().map_err(|_| JournalError::Unavailable)?;
        sync_directory(directory)
    })
}

pub(crate) fn acknowledge(directory: &Path, record: &PendingOperation) -> Result<(), JournalError> {
    record.validate()?;
    locked(directory, |directory| {
        let Some(current) = pending_locked(directory)? else {
            return Ok(());
        };
        if current != *record {
            return Err(JournalError::IdentityConflict);
        }
        fs::remove_file(directory.join(record.filename()))
            .map_err(|_| JournalError::Unavailable)?;
        sync_directory(directory)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::PathBuf,
        process::{Child, Command, Stdio},
        sync::atomic::{AtomicUsize, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    static NEXT: AtomicUsize = AtomicUsize::new(0);
    static TEST_SERIAL: Mutex<()> = Mutex::new(());
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "camellia-ab-journal-test-{}-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn journal(&self) -> PathBuf {
            self.0.join("journal")
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn record() -> PendingOperation {
        PendingOperation {
            operation_id: "ab440000-0000-4000-8000-000000000001".to_owned(),
            scope: "a".repeat(64),
            created_at_ms: 1_792_858_000_000,
        }
    }

    #[test]
    fn reserve_restart_ack_and_no_secret_fields() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let scratch = Scratch::new();
        let directory = scratch.journal();
        assert_eq!(pending(&directory), Ok(None));
        let expected = record();
        reserve(&directory, &expected).unwrap();
        assert_eq!(pending(&directory), Ok(Some(expected.clone())));
        assert_eq!(reserve(&directory, &expected), Err(JournalError::Pending));
        let bytes = fs::read(directory.join(expected.filename())).unwrap();
        assert_eq!(String::from_utf8(bytes).unwrap(), expected.encode());
        acknowledge(&directory, &expected).unwrap();
        acknowledge(&directory, &expected).unwrap();
        assert_eq!(pending(&directory), Ok(None));
    }

    #[test]
    fn id_scope_and_time_must_match_before_acknowledgement() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let scratch = Scratch::new();
        let directory = scratch.journal();
        let expected = record();
        reserve(&directory, &expected).unwrap();
        for wrong in [
            PendingOperation {
                scope: "b".repeat(64),
                ..expected.clone()
            },
            PendingOperation {
                created_at_ms: 0,
                ..expected.clone()
            },
            PendingOperation {
                operation_id: "ab440000-0000-4000-8000-000000000002".into(),
                ..expected.clone()
            },
        ] {
            assert_eq!(
                acknowledge(&directory, &wrong),
                Err(JournalError::IdentityConflict)
            );
            assert_eq!(pending(&directory), Ok(Some(expected.clone())));
        }
    }

    #[test]
    fn truncated_corrupt_or_extra_entries_never_get_evicted() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let scratch = Scratch::new();
        let directory = scratch.journal();
        let expected = record();
        reserve(&directory, &expected).unwrap();
        let path = directory.join(expected.filename());
        for bad in [
            String::new(),
            expected.encode().trim_end().to_owned(),
            "x".repeat(257),
        ] {
            fs::write(&path, bad).unwrap();
            assert_eq!(pending(&directory), Err(JournalError::Corrupt));
            assert_eq!(reserve(&directory, &expected), Err(JournalError::Corrupt));
            assert!(path.exists());
        }
        fs::write(&path, expected.encode()).unwrap();
        fs::write(directory.join("unexpected.tmp"), "preserve").unwrap();
        assert_eq!(pending(&directory), Err(JournalError::Corrupt));
        assert!(directory.join("unexpected.tmp").exists());
    }

    #[test]
    fn noncanonical_metadata_never_creates_a_record() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let scratch = Scratch::new();
        for bad in [
            PendingOperation {
                operation_id: "invalid".into(),
                ..record()
            },
            PendingOperation {
                scope: "A".repeat(64),
                ..record()
            },
            PendingOperation {
                created_at_ms: MAX_SAFE_INTEGER + 1,
                ..record()
            },
        ] {
            assert_eq!(
                reserve(&scratch.journal(), &bad),
                Err(JournalError::InvalidRecord)
            );
            assert!(!scratch.journal().exists());
        }
    }

    #[test]
    fn locked_os_handle_fails_fast_without_mutation() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let scratch = Scratch::new();
        let directory = scratch.journal();
        pending(&directory).unwrap();
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.join(LOCK_NAME))
            .unwrap();
        file.try_lock().unwrap();
        assert_eq!(reserve(&directory, &record()), Err(JournalError::Busy));
        file.unlock().unwrap();
        assert_eq!(pending(&directory), Ok(None));
    }

    #[cfg(unix)]
    #[test]
    fn symlink_and_hardlink_records_or_directories_fail_closed() {
        let _serial = TEST_SERIAL.lock().unwrap();
        use std::os::unix::fs::symlink;
        let scratch = Scratch::new();
        let real = scratch.0.join("real");
        fs::create_dir(&real).unwrap();
        symlink(&real, scratch.journal()).unwrap();
        assert_eq!(pending(&scratch.journal()), Err(JournalError::Corrupt));
        fs::remove_file(scratch.journal()).unwrap();
        reserve(&scratch.journal(), &record()).unwrap();
        let path = scratch.journal().join(record().filename());
        fs::hard_link(&path, scratch.0.join("alias")).unwrap();
        assert_eq!(pending(&scratch.journal()), Err(JournalError::Corrupt));
    }

    struct ChildGuard(Child);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            if self.0.try_wait().ok().flatten().is_none() {
                let _ = self.0.kill();
            }
            let _ = self.0.wait();
        }
    }

    #[test]
    #[ignore = "Subprocess helper; exercised by process_exit_releases_the_os_lock"]
    fn child_hold_lock() {
        let directory = PathBuf::from(std::env::var_os("CAMELLIA_AB_JOURNAL_TEST_CHILD").unwrap());
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.join(LOCK_NAME))
            .unwrap();
        file.try_lock().unwrap();
        fs::write(directory.with_extension("ready"), b"locked").unwrap();
        // The parent terminates this process; EOF also closes it if the parent
        // disappears. No detached worker or fixed-duration soak remains alive.
        let _ = std::io::stdin().read(&mut [0u8; 1]);
    }

    #[test]
    fn process_exit_releases_the_os_lock() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let scratch = Scratch::new();
        let directory = scratch.journal();
        assert_eq!(pending(&directory), Ok(None));
        let helper = std::thread::current()
            .name()
            .unwrap()
            .replace("process_exit_releases_the_os_lock", "child_hold_lock");
        let mut child = ChildGuard(
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", helper.as_str(), "--ignored"])
                .env("CAMELLIA_AB_JOURNAL_TEST_CHILD", &directory)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let started = std::time::Instant::now();
        while !directory.with_extension("ready").exists() {
            assert!(
                started.elapsed() < std::time::Duration::from_secs(10),
                "child lock deadline exceeded"
            );
            assert!(
                child.0.try_wait().unwrap().is_none(),
                "child exited before locking"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(reserve(&directory, &record()), Err(JournalError::Busy));
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        reserve(&directory, &record()).unwrap();
        assert_eq!(pending(&directory), Ok(Some(record())));
    }

    #[test]
    fn stable_error_codes_do_not_expose_filesystem_or_record_contents() {
        assert_eq!(JournalError::Busy.code(), "journal_busy");
        assert_eq!(JournalError::Corrupt.code(), "journal_corrupt");
        assert_eq!(JournalError::Unavailable.code(), "journal_unavailable");
        assert_eq!(JournalError::Pending.code(), "journal_pending");
        assert_eq!(JournalError::InvalidRecord.code(), "invalid_journal_record");
        assert_eq!(
            JournalError::IdentityConflict.code(),
            "journal_identity_conflict"
        );
    }
}
