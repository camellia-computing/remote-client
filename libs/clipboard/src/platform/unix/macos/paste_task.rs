#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use crate::{
    platform::unix::{
        paste_state::{
            checked_add_within, checked_total_size, progress_fraction, write_all_response,
            OutstandingPasteRequest, PasteResponseRetries,
        },
        paste_storage::{normalize_file_descriptions, PasteStorage, PendingPasteFile},
        FileDescription, FileType, BLOCK_SIZE,
    },
    send_data, validate_file_contents_request, ClipboardFile, CliprdrError, ProgressPercent,
};
use camellia_remote_protocol::{log, tokio::time::Instant};
#[cfg(target_os = "macos")]
use std::os::macos::fs::FileTimesExt;
use std::{
    cmp::min,
    fs::{File, FileTimes},
    path::{Path, PathBuf},
    sync::{
        mpsc::{Receiver, RecvTimeoutError},
        Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime},
};
#[cfg(target_os = "macos")]
use xattr::FileExt as XattrFileExt;

const RECV_RETRY_TIMES: usize = 3;

const RECEIVE_WAIT_TIMEOUT: Duration = Duration::from_millis(5_000);

// https://stackoverflow.com/a/15112784/1926020
// "1984-01-24 08:00:00 +0000"
const TIMESTAMP_FOR_FILE_PROGRESS_COMPLETED: u64 = 443779200;
const ATTR_PROGRESS_FRACTION_COMPLETED: &str = "com.apple.progress.fractionCompleted";

fn with_created_time(times: FileTimes, creation_time: SystemTime) -> FileTimes {
    #[cfg(target_os = "macos")]
    {
        times.set_created(creation_time)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = creation_time;
        times
    }
}

fn set_progress_xattr(file: &File, value: &[u8]) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        file.set_xattr(ATTR_PROGRESS_FRACTION_COMPLETED, value)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (file, value);
        Ok(())
    }
}

fn remove_progress_xattr(file: &File) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        file.remove_xattr(ATTR_PROGRESS_FRACTION_COMPLETED)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = file;
        Ok(())
    }
}

pub struct FileContentsResponse {
    pub conn_id: i32,
    pub msg_flags: u32,
    pub stream_id: u32,
    pub requested_data: Vec<u8>,
}

#[derive(Debug)]
struct PasteTaskProgress {
    // Use list index to identify the file
    // `list_index` is also used as the stream id
    list_index: i32,
    offset: u64,
    total_size: u64,
    current_size: u64,
    last_sent_time: Instant,
    download_file_index: i32,
    download_file_size: u64,
    download_file_path: String,
    download_file_current_size: u64,
    request_stream_id: u32,
    outstanding_request: Option<OutstandingPasteRequest>,
    response_retries: PasteResponseRetries,
    pending_file: Option<PendingPasteFile>,
    error: Option<CliprdrError>,
    is_canceled: bool,
}

struct PasteTaskHandle {
    progress: PasteTaskProgress,
    storage: PasteStorage,
    files: Vec<FileDescription>,
}

pub struct PasteTask {
    exit: Arc<Mutex<bool>>,
    handle: Arc<Mutex<Option<PasteTaskHandle>>>,
    handle_worker: Option<thread::JoinHandle<()>>,
}

impl Drop for PasteTask {
    fn drop(&mut self) {
        *self.exit.lock().unwrap() = true;
        if let Some(handle_worker) = self.handle_worker.take() {
            handle_worker.join().ok();
        }
    }
}

impl PasteTask {
    const INVALID_FILE_INDEX: i32 = -1;

    pub fn new(rx_file_contents: Receiver<FileContentsResponse>) -> Self {
        let exit = Arc::new(Mutex::new(false));
        let handle = Arc::new(Mutex::new(None));
        let handle_worker =
            Self::init_worker_thread(exit.clone(), handle.clone(), rx_file_contents);
        Self {
            handle,
            exit,
            handle_worker: Some(handle_worker),
        }
    }

    pub fn start(
        &mut self,
        target_dir: PathBuf,
        mut files: Vec<FileDescription>,
    ) -> Result<(), CliprdrError> {
        let mut task_lock = self.handle.lock().unwrap();
        if task_lock
            .as_ref()
            .map(|x| !x.is_finished())
            .unwrap_or(false)
        {
            log::error!("Previous paste task is not finished, ignore new request.");
            return Ok(());
        }
        normalize_file_descriptions(&mut files)?;
        let storage = PasteStorage::open(&target_dir)?;
        let total_size = checked_total_size(&files)?;
        let mut task_handle = PasteTaskHandle {
            progress: PasteTaskProgress {
                list_index: -1,
                offset: 0,
                total_size,
                current_size: 0,
                last_sent_time: Instant::now(),
                download_file_index: Self::INVALID_FILE_INDEX,
                download_file_size: 0,
                download_file_path: "".to_owned(),
                download_file_current_size: 0,
                // Keep a new paste task away from the deterministic stream-id prefix of a
                // previous task while retaining at least half the u32 space before exhaustion.
                request_stream_id: rand::random::<u32>() & (u32::MAX >> 1),
                outstanding_request: None,
                response_retries: PasteResponseRetries::default(),
                pending_file: None,
                error: None,
                is_canceled: false,
            },
            storage,
            files,
        };
        task_handle.update_next(0)?;
        if task_handle.is_finished() {
            task_handle.on_finished();
        } else {
            if let Err(e) = task_handle.send_file_contents_request() {
                log::error!("Failed to send file contents request, error: {}", &e);
                task_handle.on_error(e);
            }
        }
        *task_lock = Some(task_handle);
        Ok(())
    }

    pub fn cancel(&self) {
        let mut task_handle = self.handle.lock().unwrap();
        if let Some(task_handle) = task_handle.as_mut() {
            task_handle.progress.is_canceled = true;
            task_handle.on_cancelled();
        }
    }

    fn init_worker_thread(
        exit: Arc<Mutex<bool>>,
        handle: Arc<Mutex<Option<PasteTaskHandle>>>,
        rx_file_contents: Receiver<FileContentsResponse>,
    ) -> thread::JoinHandle<()> {
        thread::spawn(move || {
            loop {
                if *exit.lock().unwrap() {
                    break;
                }

                match rx_file_contents.recv_timeout(Duration::from_millis(300)) {
                    Ok(file_contents) => {
                        let mut task_lock = handle.lock().unwrap();
                        let Some(task_handle) = task_lock.as_mut() else {
                            continue;
                        };
                        if task_handle.is_finished() {
                            continue;
                        }

                        let matches_request = task_handle
                            .progress
                            .outstanding_request
                            .as_ref()
                            .is_some_and(|request| {
                                request.matches_response(
                                    file_contents.stream_id,
                                    file_contents.conn_id,
                                )
                            });
                        if !matches_request {
                            // Ignore stale, duplicate, or cross-connection responses.
                            continue;
                        } else if file_contents.msg_flags != 0x01 {
                            task_handle.progress.outstanding_request = None;
                            if task_handle
                                .progress
                                .response_retries
                                .record_failure(RECV_RETRY_TIMES)
                            {
                                task_handle.on_error(CliprdrError::InvalidRequest {
                                    description: format!(
                                        "Failed to read file contents, stream id: {}, msg_flags: {}",
                                        file_contents.stream_id,
                                        file_contents.msg_flags
                                    ),
                                });
                            }
                        } else {
                            task_handle.progress.response_retries.record_success();
                            if let Err(e) = task_handle.handle_file_contents_response(file_contents)
                            {
                                log::error!("Failed to handle file contents response: {}", &e);
                                task_handle.on_error(e);
                            }
                        }

                        if !task_handle.is_finished() {
                            if let Err(e) = task_handle.send_file_contents_request() {
                                log::error!("Failed to send file contents request: {}", &e);
                                task_handle.on_error(e);
                            }
                        } else {
                            task_handle.on_finished();
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => {
                        let mut task_lock = handle.lock().unwrap();
                        if let Some(task_handle) = task_lock.as_mut() {
                            if task_handle.check_receive_timemout() {
                                task_handle.on_finished();
                            }
                        }
                    }
                    Err(RecvTimeoutError::Disconnected) => {
                        break;
                    }
                }
            }
        })
    }

    pub fn is_finished(&self) -> bool {
        self.handle
            .lock()
            .unwrap()
            .as_ref()
            .map(|handle| handle.is_finished())
            .unwrap_or(true)
    }

    pub fn progress_percent(&self) -> Option<ProgressPercent> {
        self.handle
            .lock()
            .unwrap()
            .as_ref()
            .map(|handle| handle.progress_percent())
    }
}

impl PasteTaskHandle {
    fn update_next(&mut self, size: u64) -> Result<(), CliprdrError> {
        if self.is_finished() {
            return Ok(());
        }
        self.progress.current_size = checked_add_within(
            self.progress.current_size,
            size,
            self.progress.total_size,
            "clipboard paste total progress",
        )?;

        let is_start = self.progress.list_index == -1;
        let next_offset = checked_add_within(
            self.progress.offset,
            size,
            self.progress.download_file_size,
            "clipboard paste file offset",
        )?;
        if is_start || next_offset >= self.progress.download_file_size {
            if !is_start {
                self.on_done()?;
            }
            for i in (self.progress.list_index + 1)..self.files.len() as i32 {
                let Some(file_desc) = self.files.get(i as usize) else {
                    return Err(CliprdrError::InvalidRequest {
                        description: format!("Invalid file index: {}", i),
                    });
                };
                match file_desc.kind {
                    FileType::File => {
                        if file_desc.size == 0 {
                            let pending = self.storage.begin_file(&file_desc.name, 0)?;
                            Self::commit_file(pending, file_desc)?;
                        } else {
                            self.progress.list_index = i;
                            self.progress.offset = 0;
                            self.open_new_writer()?;
                            break;
                        }
                    }
                    FileType::Directory => {
                        self.storage.ensure_directory(&file_desc.name)?;
                    }
                    FileType::Symlink => {
                        return Err(CliprdrError::InvalidRequest {
                            description: format!(
                                "symbolic-link clipboard descriptor is not supported: {}",
                                file_desc.name.display()
                            ),
                        });
                    }
                }
            }
        } else {
            self.progress.offset = next_offset;
            self.progress.download_file_current_size = checked_add_within(
                self.progress.download_file_current_size,
                size,
                self.progress.download_file_size,
                "clipboard paste file progress",
            )?;
            self.update_progress_completed(None);
        }
        if self.progress.pending_file.is_none() {
            self.progress.list_index = self.files.len() as i32;
            self.progress.offset = 0;
            self.progress.download_file_size = 0;
            self.progress.download_file_current_size = 0;
        }
        Ok(())
    }

    fn start_progress_completed(&self) {
        let Some(pending) = self.progress.pending_file.as_ref() else {
            return;
        };
        let Ok(file) = pending.file() else {
            log::warn!("Clipboard staging file disappeared before progress setup");
            return;
        };
        let creation_time =
            SystemTime::UNIX_EPOCH + Duration::from_secs(TIMESTAMP_FOR_FILE_PROGRESS_COMPLETED);
        if let Err(err) = file.set_times(with_created_time(FileTimes::new(), creation_time)) {
            log::debug!("Failed to set clipboard paste progress timestamp: {err}");
        }
        if let Err(err) = set_progress_xattr(file, "0.0".as_bytes()) {
            log::debug!("Failed to set clipboard paste progress xattr: {err}");
        }
    }

    fn update_progress_completed(&mut self, fraction_completed: Option<f64>) {
        let fraction_completed = fraction_completed.unwrap_or_else(|| {
            let current_size = self.progress.download_file_current_size as f64;
            let total_size = self.progress.download_file_size as f64;
            if total_size > 0.0 {
                current_size / total_size
            } else {
                1.0
            }
        });
        if let Some(pending) = self.progress.pending_file.as_ref() {
            let Ok(file) = pending.file() else {
                log::warn!("Clipboard staging file disappeared during progress update");
                return;
            };
            if let Err(err) = set_progress_xattr(file, fraction_completed.to_string().as_bytes()) {
                log::debug!("Failed to update clipboard paste progress xattr: {err}");
            }
        }
    }

    fn open_new_writer(&mut self) -> Result<(), CliprdrError> {
        let Some(file) = &self.files.get(self.progress.list_index as usize) else {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "Invalid file index: {}, file count: {}",
                    self.progress.list_index,
                    self.files.len()
                ),
            });
        };

        let pending = self
            .storage
            .begin_file(&file.name, BLOCK_SIZE as usize * 2)?;
        self.progress.download_file_index = self.progress.list_index;
        self.progress.download_file_size = file.size;
        self.progress.download_file_path = self
            .storage
            .display_path(&file.name)
            .to_string_lossy()
            .into_owned();
        self.progress.download_file_current_size = 0;
        self.progress.pending_file = Some(pending);
        self.start_progress_completed();
        Ok(())
    }

    fn progress_percent(&self) -> ProgressPercent {
        let completed = !self.progress.is_canceled
            && self.progress.error.is_none()
            && self.progress.list_index >= self.files.len() as i32;
        let percent = progress_fraction(
            self.progress.current_size,
            self.progress.total_size,
            completed,
        );
        ProgressPercent {
            percent,
            is_canceled: self.progress.is_canceled,
            is_failed: self.progress.error.is_some(),
        }
    }

    fn is_finished(&self) -> bool {
        self.progress.is_canceled
            || self.progress.error.is_some()
            || self.progress.list_index >= self.files.len() as i32
    }

    fn check_receive_timemout(&mut self) -> bool {
        if !self.is_finished() && self.progress.last_sent_time.elapsed() > RECEIVE_WAIT_TIMEOUT {
            self.progress.error = Some(CliprdrError::InvalidRequest {
                description: "Failed to read file contents".to_string(),
            });
            return true;
        }
        false
    }

    fn on_finished(&mut self) {
        if self.progress.is_canceled || self.progress.error.is_some() {
            self.on_cancelled();
            return;
        }
        if self.progress.current_size != self.progress.total_size {
            self.on_error(CliprdrError::InvalidRequest {
                description: "Failed to download all files".to_string(),
            });
            return;
        }
        if let Err(error) = self.on_done() {
            self.on_error(error);
        }
    }

    fn on_error(&mut self, error: CliprdrError) {
        self.progress.error = Some(error);
        self.on_cancelled();
    }

    fn on_cancelled(&mut self) {
        self.progress.outstanding_request = None;
        self.progress.response_retries.record_success();
        self.progress.pending_file = None;
    }

    fn on_done(&mut self) -> Result<(), CliprdrError> {
        self.update_progress_completed(Some(1.0));
        let Some(pending) = self.progress.pending_file.take() else {
            return Ok(());
        };
        if self.progress.download_file_index == PasteTask::INVALID_FILE_INDEX {
            return Err(CliprdrError::InvalidRequest {
                description: "clipboard paste file index is missing during commit".to_owned(),
            });
        }

        let file_desc = self
            .files
            .get(self.progress.download_file_index as usize)
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!(
                    "Invalid clipboard paste file index during commit: {}",
                    self.progress.download_file_index
                ),
            })?;
        Self::commit_file(pending, file_desc)?;
        self.progress.download_file_path = "".to_owned();
        self.progress.download_file_index = PasteTask::INVALID_FILE_INDEX;
        Ok(())
    }

    fn commit_file(
        pending: PendingPasteFile,
        file_desc: &FileDescription,
    ) -> Result<(), CliprdrError> {
        pending.commit()?.finish(|file, path| {
            if let Err(err) = remove_progress_xattr(file) {
                log::debug!("Failed to remove clipboard paste progress xattr: {err}");
            }
            Self::set_file_metadata(file, path, file_desc)
        })
    }

    #[inline]
    fn set_file_metadata(
        file: &File,
        path: &Path,
        file_desc: &FileDescription,
    ) -> Result<(), CliprdrError> {
        let times = with_created_time(
            FileTimes::new()
                .set_accessed(file_desc.atime)
                .set_modified(file_desc.last_modified),
            file_desc.creation_time,
        );
        file.set_times(times)
            .map_err(|err| CliprdrError::FileError {
                path: path.to_string_lossy().into_owned(),
                err,
            })
    }

    fn send_file_contents_request(&mut self) -> Result<(), CliprdrError> {
        if self.is_finished() {
            return Ok(());
        }

        let list_index =
            u32::try_from(self.progress.list_index).map_err(|_| CliprdrError::InvalidRequest {
                description: format!("Invalid file index: {}", self.progress.list_index),
            })?;
        let Some(file) = &self.files.get(list_index as usize) else {
            // unreachable
            return Err(CliprdrError::InvalidRequest {
                description: format!("Invalid file index: {}", list_index),
            });
        };
        let remaining = file.size.checked_sub(self.progress.offset).ok_or_else(|| {
            CliprdrError::InvalidRequest {
                description: "clipboard paste offset exceeds file size".to_owned(),
            }
        })?;
        let cb_requested = u32::try_from(min(BLOCK_SIZE as u64, remaining)).map_err(|_| {
            CliprdrError::InvalidRequest {
                description: "clipboard paste request length is not representable".to_owned(),
            }
        })?;
        let conn_id = file.conn_id;

        let (n_position_high, n_position_low) = (
            (self.progress.offset >> 32) as u32,
            self.progress.offset as u32,
        );
        validate_file_contents_request(2, n_position_low, n_position_high, cb_requested)?;
        let stream_id = self
            .progress
            .request_stream_id
            .checked_add(1)
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: "clipboard paste request stream id exhausted".to_owned(),
            })?;
        let request = ClipboardFile::FileContentsRequest {
            stream_id,
            list_index,
            dw_flags: 2,
            n_position_low,
            n_position_high,
            cb_requested,
            have_clip_data_id: false,
            clip_data_id: 0,
        };
        send_data(conn_id, request)?;
        self.progress.request_stream_id = stream_id;
        self.progress.outstanding_request = Some(OutstandingPasteRequest::new(
            stream_id,
            conn_id,
            self.progress.list_index,
            self.progress.offset,
            cb_requested,
            remaining,
        ));
        self.progress.last_sent_time = Instant::now();

        Ok(())
    }

    fn handle_file_contents_response(
        &mut self,
        file_contents: FileContentsResponse,
    ) -> Result<(), CliprdrError> {
        let outstanding = self.progress.outstanding_request.take().ok_or_else(|| {
            CliprdrError::InvalidRequest {
                description: "clipboard paste response has no outstanding request".to_owned(),
            }
        })?;
        let write_len = outstanding.validate_response(
            self.progress.list_index,
            self.progress.offset,
            file_contents.requested_data.len(),
        )?;
        if let Some(pending) = self.progress.pending_file.as_mut() {
            let file = pending.writer_mut()?;
            let data = file_contents.requested_data.as_slice();
            write_all_response(file, data, &self.progress.download_file_path)?;
            self.update_next(write_len)?;
        } else {
            return Err(CliprdrError::FileError {
                path: self.progress.download_file_path.clone(),
                err: std::io::Error::new(std::io::ErrorKind::NotFound, "file handle is not opened"),
            });
        }
        Ok(())
    }
}
