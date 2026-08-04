use super::FileDescription;
use crate::CliprdrError;
use std::io::Write;

pub(super) fn checked_total_size(files: &[FileDescription]) -> Result<u64, CliprdrError> {
    files.iter().try_fold(0_u64, |total, file| {
        total
            .checked_add(file.size)
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: "clipboard paste total size overflow".to_owned(),
            })
    })
}

pub(super) fn checked_add_within(
    current: u64,
    increment: u64,
    limit: u64,
    description: &'static str,
) -> Result<u64, CliprdrError> {
    let next = current
        .checked_add(increment)
        .ok_or_else(|| CliprdrError::InvalidRequest {
            description: format!("{description} overflow"),
        })?;
    if next > limit {
        return Err(CliprdrError::InvalidRequest {
            description: format!("{description} exceeds its declared budget"),
        });
    }
    Ok(next)
}

pub(super) fn progress_fraction(current: u64, total: u64, completed: bool) -> f64 {
    if total == 0 {
        if completed {
            1.0
        } else {
            0.0
        }
    } else {
        current as f64 / total as f64
    }
}

pub(super) fn write_all_response(
    writer: &mut impl Write,
    data: &[u8],
    path: &str,
) -> Result<(), CliprdrError> {
    writer
        .write_all(data)
        .map_err(|err| CliprdrError::FileError {
            path: path.to_owned(),
            err,
        })
}

#[derive(Debug, Default)]
pub(super) struct PasteResponseRetries {
    consecutive_failures: usize,
}

impl PasteResponseRetries {
    pub(super) fn record_failure(&mut self, retry_limit: usize) -> bool {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        self.consecutive_failures > retry_limit
    }

    pub(super) fn record_success(&mut self) {
        self.consecutive_failures = 0;
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct OutstandingPasteRequest {
    pub(super) stream_id: u32,
    pub(super) conn_id: i32,
    list_index: i32,
    offset: u64,
    max_bytes: u32,
    remaining_bytes: u64,
}

impl OutstandingPasteRequest {
    pub(super) fn new(
        stream_id: u32,
        conn_id: i32,
        list_index: i32,
        offset: u64,
        max_bytes: u32,
        remaining_bytes: u64,
    ) -> Self {
        Self {
            stream_id,
            conn_id,
            list_index,
            offset,
            max_bytes,
            remaining_bytes,
        }
    }

    pub(super) fn matches_response(&self, stream_id: u32, conn_id: i32) -> bool {
        self.stream_id == stream_id && self.conn_id == conn_id
    }

    pub(super) fn validate_response(
        self,
        current_list_index: i32,
        current_offset: u64,
        response_bytes: usize,
    ) -> Result<u64, CliprdrError> {
        if self.list_index != current_list_index || self.offset != current_offset {
            return Err(CliprdrError::InvalidRequest {
                description: "clipboard paste response does not match the outstanding file state"
                    .to_owned(),
            });
        }
        let response_bytes =
            u64::try_from(response_bytes).map_err(|_| CliprdrError::InvalidRequest {
                description: "clipboard paste response length is not representable".to_owned(),
            })?;
        if response_bytes == 0
            || response_bytes > u64::from(self.max_bytes)
            || response_bytes > self.remaining_bytes
        {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "clipboard paste response length {response_bytes} exceeds the outstanding budget {} and remaining size {}",
                    self.max_bytes, self.remaining_bytes
                ),
            });
        }
        Ok(response_bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::unix::FileType;
    use std::{
        io::{self, Write},
        path::PathBuf,
        time::SystemTime,
    };

    fn description(size: u64) -> FileDescription {
        FileDescription {
            conn_id: 7,
            name: PathBuf::from("file"),
            kind: FileType::File,
            atime: SystemTime::UNIX_EPOCH,
            last_modified: SystemTime::UNIX_EPOCH,
            last_metadata_changed: SystemTime::UNIX_EPOCH,
            creation_time: SystemTime::UNIX_EPOCH,
            size,
            perm: 0o644,
        }
    }

    #[test]
    fn total_size_rejects_overflow() {
        assert!(checked_total_size(&[description(u64::MAX), description(1)]).is_err());
        assert_eq!(
            checked_total_size(&[description(4), description(9)]).unwrap(),
            13
        );
    }

    #[test]
    fn response_requires_matching_request_identity_and_state() {
        let request = || OutstandingPasteRequest::new(11, 7, 3, 4096, 1024, 1024);
        assert!(request().matches_response(11, 7));
        assert!(!request().matches_response(10, 7));
        assert!(!request().matches_response(11, 8));
        assert!(request().validate_response(2, 4096, 512).is_err());
        assert!(request().validate_response(3, 4095, 512).is_err());
        assert_eq!(request().validate_response(3, 4096, 512).unwrap(), 512);

        let mut outstanding = Some(request());
        assert!(outstanding.take().is_some());
        assert!(outstanding.take().is_none());
    }

    #[test]
    fn checked_progress_rejects_overflow_and_declared_budget_excess() {
        assert_eq!(checked_add_within(4, 5, 9, "test progress").unwrap(), 9);
        assert!(checked_add_within(u64::MAX, 1, u64::MAX, "test progress").is_err());
        assert!(checked_add_within(4, 6, 9, "test progress").is_err());
    }

    #[test]
    fn zero_total_progress_is_finite_and_only_success_is_complete() {
        for value in [
            progress_fraction(0, 0, false),
            progress_fraction(0, 0, true),
            progress_fraction(1, 2, false),
        ] {
            assert!(value.is_finite());
        }
        assert_eq!(progress_fraction(0, 0, false), 0.0);
        assert_eq!(progress_fraction(0, 0, true), 1.0);
        assert_eq!(progress_fraction(1, 2, false), 0.5);
    }

    #[test]
    fn response_retry_budget_is_consecutive_and_task_local() {
        let mut retries = PasteResponseRetries::default();
        assert!(!retries.record_failure(3));
        assert!(!retries.record_failure(3));
        retries.record_success();
        assert!(!retries.record_failure(3));
        assert!(!retries.record_failure(3));
        assert!(!retries.record_failure(3));
        assert!(retries.record_failure(3));

        let mut next_task = PasteResponseRetries::default();
        assert!(!next_task.record_failure(3));
    }

    struct PartialWriter {
        bytes: Vec<u8>,
        max_chunk: usize,
    }

    impl Write for PartialWriter {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            let count = data.len().min(self.max_chunk);
            self.bytes.extend_from_slice(&data[..count]);
            Ok(count)
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn response_writer_completes_partial_writes_and_rejects_zero_progress() {
        let mut partial = PartialWriter {
            bytes: Vec::new(),
            max_chunk: 2,
        };
        write_all_response(&mut partial, b"abcdef", "partial").unwrap();
        assert_eq!(partial.bytes, b"abcdef");

        let mut zero = PartialWriter {
            bytes: Vec::new(),
            max_chunk: 0,
        };
        let error = write_all_response(&mut zero, b"blocked", "zero").unwrap_err();
        let CliprdrError::FileError { err, .. } = error else {
            panic!("expected file error");
        };
        assert_eq!(err.kind(), io::ErrorKind::WriteZero);
    }

    #[test]
    fn response_rejects_empty_and_excess_data_but_accepts_short_blocks() {
        let request = || OutstandingPasteRequest::new(11, 7, 3, 4096, 1024, 700);
        assert!(request().validate_response(3, 4096, 0).is_err());
        assert!(request().validate_response(3, 4096, 701).is_err());
        assert!(request().validate_response(3, 4096, 1025).is_err());
        assert_eq!(request().validate_response(3, 4096, 699).unwrap(), 699);
        assert_eq!(request().validate_response(3, 4096, 700).unwrap(), 700);
    }
}
