use camellia_remote_protocol::{
    anyhow::{anyhow, Context},
    bail,
    config::Config,
    log, ResultType,
};
use serde_derive::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const OUTBOX_PROTOCOL: u8 = 1;
const OUTBOX_DIRECTORY: &str = "audit-evidence-outbox-v1";
const MAX_PENDING_EVENTS: usize = 256;
const MAX_RECORD_BYTES: u64 = 64 * 1024;
const MAX_URL_BYTES: usize = 2048;
const MAX_DIRECTORY_ENTRIES: usize = MAX_PENDING_EVENTS * 4;

static OUTBOX_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum EvidenceKind {
    Alarm,
    File,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PendingEvidence {
    pub protocol: u8,
    pub event_id: String,
    pub url: String,
    pub body: Value,
    pub kind: EvidenceKind,
    pub created_at_unix_ms: u64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StoredEvidence {
    payload: PendingEvidence,
    checksum: String,
}

fn outbox_directory() -> PathBuf {
    Config::path(OUTBOX_DIRECTORY)
}

fn canonical_uuid4(value: &str) -> bool {
    Uuid::parse_str(value)
        .ok()
        .filter(|parsed| parsed.get_version_num() == 4 && parsed.to_string() == value)
        .is_some()
}

fn checksum(payload: &PendingEvidence) -> ResultType<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(payload)?)
    ))
}

fn validate(payload: &PendingEvidence) -> ResultType<()> {
    if payload.protocol != OUTBOX_PROTOCOL || !canonical_uuid4(&payload.event_id) {
        bail!("invalid audit outbox identity");
    }
    if payload.url.len() > MAX_URL_BYTES {
        bail!("audit outbox URL is too long");
    }
    let parsed_url = url::Url::parse(&payload.url).context("invalid audit outbox URL")?;
    if !matches!(parsed_url.scheme(), "http" | "https")
        || parsed_url.host_str().is_none()
        || !parsed_url.username().is_empty()
        || parsed_url.password().is_some()
        || parsed_url.query().is_some()
        || parsed_url.fragment().is_some()
    {
        bail!("invalid audit outbox URL authority");
    }
    let (expected_version, expected_path) = match payload.kind {
        EvidenceKind::Alarm => (3, "/api/audit/alarm"),
        EvidenceKind::File => (4, "/api/audit/file"),
    };
    if parsed_url.path() != expected_path
        || payload.body.get("version").and_then(Value::as_u64) != Some(expected_version)
    {
        bail!("audit outbox kind does not match its endpoint or protocol");
    }
    if payload.body.get("event_id").and_then(Value::as_str) != Some(payload.event_id.as_str())
        || payload.body.get("receipt_version").and_then(Value::as_u64) != Some(1)
        || payload
            .body
            .get("reporter_sequence")
            .and_then(Value::as_u64)
            .filter(|sequence| *sequence > 0)
            .is_none()
        || !payload
            .body
            .get("audit_session_id")
            .and_then(Value::as_str)
            .is_some_and(canonical_uuid4)
    {
        bail!("invalid audit outbox payload binding");
    }
    Ok(())
}

fn ensure_directory(directory: &Path) -> ResultType<()> {
    std::fs::create_dir_all(directory)?;
    let metadata = std::fs::symlink_metadata(directory)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!("audit outbox path is not a real directory");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn record_path(directory: &Path, event_id: &str) -> PathBuf {
    directory.join(format!("{event_id}.json"))
}

fn open_read(path: &Path) -> ResultType<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(
            camellia_remote_protocol::libc::O_CLOEXEC | camellia_remote_protocol::libc::O_NOFOLLOW,
        );
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        bail!("audit outbox entry is not a regular file");
    }
    Ok(file)
}

fn load_path(path: &Path) -> ResultType<PendingEvidence> {
    let mut file = open_read(path)?;
    let mut data = Vec::new();
    Read::by_ref(&mut file)
        .take(MAX_RECORD_BYTES + 1)
        .read_to_end(&mut data)?;
    if data.len() as u64 > MAX_RECORD_BYTES {
        bail!("audit outbox entry is too large");
    }
    let stored: StoredEvidence = serde_json::from_slice(&data)?;
    validate(&stored.payload)?;
    if checksum(&stored.payload)? != stored.checksum {
        bail!("audit outbox checksum mismatch");
    }
    let expected_name = format!("{}.json", stored.payload.event_id);
    if path.file_name().and_then(|name| name.to_str()) != Some(expected_name.as_str()) {
        bail!("audit outbox filename does not match its event ID");
    }
    Ok(stored.payload)
}

fn sync_directory(path: &Path) -> ResultType<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn outbox_paths(directory: &Path) -> ResultType<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for (index, entry) in std::fs::read_dir(directory)?.enumerate() {
        if index >= MAX_DIRECTORY_ENTRIES {
            bail!("audit outbox directory contains too many entries");
        }
        paths.push(entry?.path());
    }
    Ok(paths)
}

fn remove_crash_temporary_files(directory: &Path, paths: &[PathBuf]) -> ResultType<()> {
    let mut removed = false;
    for path in paths {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name.starts_with('.') && name.ends_with(".tmp") {
            match std::fs::remove_file(path) {
                Ok(()) => removed = true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    log::warn!("Failed to remove a crashed audit outbox temporary file: {error}")
                }
            }
        }
    }
    if removed {
        sync_directory(directory)?;
    }
    Ok(())
}

fn persist_in(directory: &Path, payload: PendingEvidence) -> ResultType<PendingEvidence> {
    validate(&payload)?;
    ensure_directory(directory)?;
    let final_path = record_path(directory, &payload.event_id);
    match load_path(&final_path) {
        Ok(existing) => {
            if checksum(&existing)? != checksum(&payload)? {
                bail!("audit event ID is already bound to different persisted content");
            }
            return Ok(existing);
        }
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound) => {}
        Err(error) => return Err(error),
    }
    let pending_count = outbox_paths(directory)?
        .into_iter()
        .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
        .count();
    if pending_count >= MAX_PENDING_EVENTS {
        bail!("audit outbox capacity is exhausted");
    }

    let stored = StoredEvidence {
        checksum: checksum(&payload)?,
        payload: payload.clone(),
    };
    let data = serde_json::to_vec(&stored)?;
    if data.len() as u64 > MAX_RECORD_BYTES {
        bail!("audit outbox entry is too large");
    }
    let temporary = directory.join(format!(".{}.{}.tmp", payload.event_id, Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(
            camellia_remote_protocol::libc::O_CLOEXEC | camellia_remote_protocol::libc::O_NOFOLLOW,
        );
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(&data)?;
    file.sync_all()?;
    drop(file);
    match std::fs::hard_link(&temporary, &final_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let existing = load_path(&final_path)?;
            if checksum(&existing)? != stored.checksum {
                let _ = std::fs::remove_file(&temporary);
                bail!("audit event ID raced with different persisted content");
            }
        }
        Err(error) => {
            let _ = std::fs::remove_file(&temporary);
            return Err(error.into());
        }
    }
    std::fs::remove_file(&temporary)?;
    sync_directory(directory)?;
    Ok(payload)
}

pub(super) fn persist(
    event_id: String,
    url: String,
    body: Value,
    kind: EvidenceKind,
) -> ResultType<PendingEvidence> {
    let _guard = OUTBOX_LOCK
        .lock()
        .map_err(|_| anyhow!("audit outbox lock is poisoned"))?;
    let created_at_unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| anyhow!("system clock is before the Unix epoch"))?
        .as_millis()
        .try_into()
        .map_err(|_| anyhow!("audit outbox timestamp is out of range"))?;
    persist_in(
        &outbox_directory(),
        PendingEvidence {
            protocol: OUTBOX_PROTOCOL,
            event_id,
            url,
            body,
            kind,
            created_at_unix_ms,
        },
    )
}

fn pending_in(directory: &Path) -> ResultType<Vec<PendingEvidence>> {
    ensure_directory(directory)?;
    let paths = outbox_paths(directory)?;
    remove_crash_temporary_files(directory, &paths)?;
    let mut entries = Vec::new();
    let mut removed_invalid = false;
    for path in paths {
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        match load_path(&path) {
            Ok(payload) => entries.push(payload),
            Err(error) => {
                log::error!("Discarding an invalid durable audit outbox entry: {error}");
                match std::fs::remove_file(&path) {
                    Ok(()) => removed_invalid = true,
                    Err(remove_error) if remove_error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(remove_error) => log::error!(
                        "Failed to remove an invalid durable audit outbox entry: {remove_error}"
                    ),
                }
            }
        }
    }
    if removed_invalid {
        sync_directory(directory)?;
    }
    entries.sort_by_key(|entry| (entry.created_at_unix_ms, entry.event_id.clone()));
    Ok(entries)
}

pub(super) fn pending() -> ResultType<Vec<PendingEvidence>> {
    let _guard = OUTBOX_LOCK
        .lock()
        .map_err(|_| anyhow!("audit outbox lock is poisoned"))?;
    pending_in(&outbox_directory())
}

fn acknowledge_in(directory: &Path, event_id: &str) -> ResultType<()> {
    if !canonical_uuid4(event_id) {
        bail!("invalid audit acknowledgement identity");
    }
    match std::fs::remove_file(record_path(directory, event_id)) {
        Ok(()) => sync_directory(directory),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

pub(super) fn acknowledge(event_id: &str) -> ResultType<()> {
    let _guard = OUTBOX_LOCK
        .lock()
        .map_err(|_| anyhow!("audit outbox lock is poisoned"))?;
    acknowledge_in(&outbox_directory(), event_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_payload(event_id: &str) -> PendingEvidence {
        PendingEvidence {
            protocol: OUTBOX_PROTOCOL,
            event_id: event_id.to_owned(),
            url: "https://management.invalid/api/audit/alarm".to_owned(),
            body: serde_json::json!({
                "version": 3,
                "event_id": event_id,
                "audit_session_id": Uuid::new_v4().to_string(),
                "receipt_version": 1,
                "reporter_sequence": 1,
            }),
            kind: EvidenceKind::Alarm,
            created_at_unix_ms: 1,
        }
    }

    #[test]
    fn durable_event_id_replays_identical_content_and_rejects_conflicts() {
        let directory =
            std::env::temp_dir().join(format!("camellia-audit-outbox-test-{}", Uuid::new_v4()));
        let event_id = Uuid::new_v4().to_string();
        let payload = test_payload(&event_id);

        let first = persist_in(&directory, payload.clone()).unwrap();
        let replayed = persist_in(&directory, payload.clone()).unwrap();
        assert_eq!(checksum(&first).unwrap(), checksum(&replayed).unwrap());
        assert_eq!(
            load_path(&record_path(&directory, &event_id))
                .unwrap()
                .event_id,
            event_id
        );

        let mut conflicting = payload;
        conflicting.body["reporter_sequence"] = serde_json::json!(2);
        assert!(persist_in(&directory, conflicting).is_err());
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn checksum_and_filename_tampering_fail_closed() {
        let directory =
            std::env::temp_dir().join(format!("camellia-audit-outbox-test-{}", Uuid::new_v4()));
        let event_id = Uuid::new_v4().to_string();
        persist_in(&directory, test_payload(&event_id)).unwrap();
        let path = record_path(&directory, &event_id);
        let mut bytes = std::fs::read(&path).unwrap();
        let index = bytes.len() / 2;
        bytes[index] ^= 1;
        std::fs::write(&path, bytes).unwrap();
        assert!(load_path(&path).is_err());
        assert!(pending_in(&directory).unwrap().is_empty());
        assert!(!path.exists());
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn endpoint_protocol_and_kind_are_bound_without_query_secrets() {
        let event_id = Uuid::new_v4().to_string();
        let mut payload = test_payload(&event_id);
        assert!(validate(&payload).is_ok());

        payload.url.push_str("?access_token=secret");
        assert!(validate(&payload).is_err());
        payload.url = "https://management.invalid/api/audit/file".to_owned();
        assert!(validate(&payload).is_err());
        payload.kind = EvidenceKind::File;
        assert!(validate(&payload).is_err());
        payload.body["version"] = serde_json::json!(4);
        assert!(validate(&payload).is_ok());
    }

    #[test]
    fn crash_reload_preserves_identity_and_acknowledges_exactly_one_event() {
        let directory =
            std::env::temp_dir().join(format!("camellia-audit-outbox-test-{}", Uuid::new_v4()));
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let first = persist_in(&directory, test_payload(&first_id)).unwrap();
        let mut second = test_payload(&second_id);
        second.body["reporter_sequence"] = serde_json::json!(2);
        persist_in(&directory, second).unwrap();
        std::fs::write(directory.join(format!(".{first_id}.crash.tmp")), b"partial").unwrap();

        let reloaded = pending_in(&directory).unwrap();
        assert_eq!(reloaded.len(), 2);
        let reloaded_first = reloaded
            .iter()
            .find(|entry| entry.event_id == first_id)
            .unwrap();
        assert_eq!(checksum(reloaded_first).unwrap(), checksum(&first).unwrap());
        assert!(!directory.join(format!(".{first_id}.crash.tmp")).exists());

        acknowledge_in(&directory, &first_id).unwrap();
        let remaining = pending_in(&directory).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].event_id, second_id);
        acknowledge_in(&directory, &first_id).unwrap();
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn outbox_capacity_is_hard_bounded_and_recovers_after_ack() {
        let directory =
            std::env::temp_dir().join(format!("camellia-audit-outbox-test-{}", Uuid::new_v4()));
        let mut first_id = String::new();
        for sequence in 1..=MAX_PENDING_EVENTS {
            let event_id = Uuid::new_v4().to_string();
            if first_id.is_empty() {
                first_id = event_id.clone();
            }
            let mut payload = test_payload(&event_id);
            payload.body["reporter_sequence"] = serde_json::json!(sequence);
            persist_in(&directory, payload).unwrap();
        }
        let overflow_id = Uuid::new_v4().to_string();
        let mut overflow = test_payload(&overflow_id);
        overflow.body["reporter_sequence"] = serde_json::json!(MAX_PENDING_EVENTS + 1);
        assert!(persist_in(&directory, overflow.clone()).is_err());

        acknowledge_in(&directory, &first_id).unwrap();
        persist_in(&directory, overflow).unwrap();
        assert_eq!(pending_in(&directory).unwrap().len(), MAX_PENDING_EVENTS);
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn symlink_entries_and_symlink_outbox_directories_fail_closed() {
        use std::os::unix::fs::symlink;

        let directory =
            std::env::temp_dir().join(format!("camellia-audit-outbox-test-{}", Uuid::new_v4()));
        let event_id = Uuid::new_v4().to_string();
        ensure_directory(&directory).unwrap();
        let sentinel = directory.with_extension("sentinel");
        std::fs::write(&sentinel, b"must remain unchanged").unwrap();
        let linked_record = record_path(&directory, &event_id);
        symlink(&sentinel, &linked_record).unwrap();

        assert!(pending_in(&directory).unwrap().is_empty());
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"must remain unchanged");
        assert!(!linked_record.exists());

        let linked_directory = directory.with_extension("directory-link");
        symlink(&directory, &linked_directory).unwrap();
        assert!(ensure_directory(&linked_directory).is_err());

        std::fs::remove_file(&linked_directory).unwrap();
        std::fs::remove_file(&sentinel).unwrap();
        std::fs::remove_dir_all(&directory).unwrap();
    }
}
