use super::{FileDescription, FileType};
use crate::CliprdrError;
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions, OpenOptionsExt},
};
use std::{
    collections::HashSet,
    ffi::OsString,
    io::{BufWriter, Write},
    path::{Component, Path, PathBuf},
};
use unicode_normalization::UnicodeNormalization;

const STAGING_PREFIX: &str = ".camellia-clipboard-";
const STAGING_SUFFIX: &str = ".rddownload";
const RANDOM_NAME_ATTEMPTS: usize = 16;
const FINAL_NAME_ATTEMPTS: usize = 10_000;

fn invalid_path(path: &Path, reason: &str) -> CliprdrError {
    CliprdrError::InvalidRequest {
        description: format!("invalid clipboard paste path {}: {reason}", path.display()),
    }
}

fn file_error(path: &Path, err: std::io::Error) -> CliprdrError {
    CliprdrError::FileError {
        path: path.to_string_lossy().into_owned(),
        err,
    }
}

pub(super) fn normalize_relative_path(path: &Path) -> Result<PathBuf, CliprdrError> {
    let value = path
        .to_str()
        .ok_or_else(|| invalid_path(path, "path is not valid UTF-8"))?;
    if value.is_empty() {
        return Err(invalid_path(path, "path is empty"));
    }
    if value.contains('\0') {
        return Err(invalid_path(path, "path contains NUL"));
    }

    let mut original_components = Vec::new();
    let mut normalized_components = Vec::new();
    for component in path.components() {
        let Component::Normal(component) = component else {
            return Err(invalid_path(
                path,
                "only normal relative components are allowed",
            ));
        };
        let component = component
            .to_str()
            .ok_or_else(|| invalid_path(path, "component is not valid UTF-8"))?;
        if component.is_empty() {
            return Err(invalid_path(path, "component is empty"));
        }
        original_components.push(component.to_owned());
        normalized_components.push(component.nfc().collect::<String>());
    }
    if original_components.is_empty() {
        return Err(invalid_path(path, "path has no file name"));
    }

    let structurally_canonical = original_components.join("/");
    if structurally_canonical != value {
        return Err(invalid_path(
            path,
            "path must use one canonical separator form",
        ));
    }
    Ok(normalized_components.iter().collect())
}

pub(super) fn normalize_file_descriptions(
    files: &mut [FileDescription],
) -> Result<(), CliprdrError> {
    let mut paths = HashSet::with_capacity(files.len());
    for file in files {
        if file.kind == FileType::Symlink {
            return Err(invalid_path(
                &file.name,
                "symbolic-link descriptors are not supported",
            ));
        }
        let normalized = normalize_relative_path(&file.name)?;
        if !paths.insert(normalized.clone()) {
            return Err(invalid_path(
                &file.name,
                "path collides after Unicode normalization",
            ));
        }
        file.name = normalized;
    }
    Ok(())
}

fn open_ambient_directory_nofollow(path: &Path) -> Result<Dir, CliprdrError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|err| file_error(path, err))?
            .join(path)
    };
    let mut root = PathBuf::new();
    let mut components = Vec::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(prefix) => root.push(prefix.as_os_str()),
            Component::RootDir => root.push(std::path::MAIN_SEPARATOR.to_string()),
            Component::CurDir => {}
            Component::ParentDir => {
                if components.pop().is_none() {
                    return Err(invalid_path(path, "target escapes its filesystem root"));
                }
            }
            Component::Normal(component) => components.push(component.to_os_string()),
        }
    }
    if root.as_os_str().is_empty() {
        return Err(invalid_path(path, "target has no filesystem root"));
    }

    let mut directory =
        Dir::open_ambient_dir(&root, ambient_authority()).map_err(|err| file_error(&root, err))?;
    let mut display = root;
    for component in components {
        display.push(&component);
        directory = directory
            .open_dir_nofollow(&component)
            .map_err(|err| file_error(&display, err))?;
    }
    Ok(directory)
}

#[derive(Debug)]
pub(super) struct PasteStorage {
    root: Dir,
    display_root: PathBuf,
}

impl PasteStorage {
    pub(super) fn open(target: &Path) -> Result<Self, CliprdrError> {
        Ok(Self {
            root: open_ambient_directory_nofollow(target)?,
            display_root: target.to_path_buf(),
        })
    }

    pub(super) fn display_path(&self, relative: &Path) -> PathBuf {
        self.display_root.join(relative)
    }

    fn open_parent(&self, relative: &Path, create: bool) -> Result<(Dir, OsString), CliprdrError> {
        let relative = normalize_relative_path(relative)?;
        let components = relative
            .components()
            .filter_map(|component| match component {
                Component::Normal(component) => Some(component.to_os_string()),
                _ => None,
            })
            .collect::<Vec<_>>();
        let (final_name, parents) = components
            .split_last()
            .ok_or_else(|| invalid_path(&relative, "path has no final component"))?;
        let mut directory = self
            .root
            .try_clone()
            .map_err(|err| file_error(&self.display_root, err))?;
        let mut display = self.display_root.clone();
        for component in parents {
            display.push(component);
            directory = match directory.open_dir_nofollow(component) {
                Ok(next) => next,
                Err(err) if create && err.kind() == std::io::ErrorKind::NotFound => {
                    match directory.create_dir(component) {
                        Ok(()) => {}
                        Err(create_err)
                            if create_err.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(create_err) => return Err(file_error(&display, create_err)),
                    }
                    directory
                        .open_dir_nofollow(component)
                        .map_err(|open_err| file_error(&display, open_err))?
                }
                Err(err) => return Err(file_error(&display, err)),
            };
        }
        Ok((directory, final_name.clone()))
    }

    pub(super) fn ensure_directory(&self, relative: &Path) -> Result<(), CliprdrError> {
        let relative = normalize_relative_path(relative)?;
        let mut directory = self
            .root
            .try_clone()
            .map_err(|err| file_error(&self.display_root, err))?;
        let mut display = self.display_root.clone();
        for component in relative.components() {
            let Component::Normal(component) = component else {
                return Err(invalid_path(&relative, "invalid directory component"));
            };
            display.push(component);
            directory = match directory.open_dir_nofollow(component) {
                Ok(next) => next,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                    match directory.create_dir(component) {
                        Ok(()) => {}
                        Err(create_err)
                            if create_err.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(create_err) => return Err(file_error(&display, create_err)),
                    }
                    directory
                        .open_dir_nofollow(component)
                        .map_err(|open_err| file_error(&display, open_err))?
                }
                Err(err) => return Err(file_error(&display, err)),
            };
        }
        Ok(())
    }

    pub(super) fn begin_file(
        &self,
        relative: &Path,
        buffer_capacity: usize,
    ) -> Result<PendingPasteFile, CliprdrError> {
        let relative = normalize_relative_path(relative)?;
        let (parent, final_name) = self.open_parent(&relative, true)?;
        let mut options = OpenOptions::new();
        options
            .write(true)
            .create_new(true)
            .follow(FollowSymlinks::No)
            .mode(0o600);

        for _ in 0..RANDOM_NAME_ATTEMPTS {
            let temp_name = format!(
                "{STAGING_PREFIX}{:032x}{STAGING_SUFFIX}",
                rand::random::<u128>()
            );
            let file = match parent.open_with(&temp_name, &options) {
                Ok(file) => file.into_std(),
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(err) => return Err(file_error(&self.display_path(&relative), err)),
            };
            return Ok(PendingPasteFile {
                parent,
                writer: Some(BufWriter::with_capacity(buffer_capacity, file)),
                temp_name: Some(OsString::from(temp_name)),
                final_name,
                display_parent: self
                    .display_path(relative.parent().unwrap_or_else(|| Path::new(""))),
            });
        }
        Err(CliprdrError::CommonError {
            description: format!(
                "failed to allocate a unique clipboard staging file for {}",
                self.display_path(&relative).display()
            ),
        })
    }
}

#[derive(Debug)]
pub(super) struct PendingPasteFile {
    parent: Dir,
    writer: Option<BufWriter<std::fs::File>>,
    temp_name: Option<OsString>,
    final_name: OsString,
    display_parent: PathBuf,
}

impl PendingPasteFile {
    pub(super) fn writer_mut(&mut self) -> Result<&mut BufWriter<std::fs::File>, CliprdrError> {
        self.writer
            .as_mut()
            .ok_or_else(|| CliprdrError::CommonError {
                description: "clipboard staging file is already closed".to_owned(),
            })
    }

    pub(super) fn file(&self) -> Result<&std::fs::File, CliprdrError> {
        self.writer
            .as_ref()
            .map(BufWriter::get_ref)
            .ok_or_else(|| CliprdrError::CommonError {
                description: "clipboard staging file is already closed".to_owned(),
            })
    }

    fn candidate_name(&self, attempt: usize) -> OsString {
        if attempt == 0 {
            return self.final_name.clone();
        }
        let path = Path::new(&self.final_name);
        if let Some(extension) = path.extension() {
            let mut value = OsString::new();
            value.push(path.file_stem().unwrap_or_default());
            value.push(format!("-{attempt}."));
            value.push(extension);
            value
        } else {
            let mut value = self.final_name.clone();
            value.push(format!(" ({attempt})"));
            value
        }
    }

    pub(super) fn commit(mut self) -> Result<PathBuf, CliprdrError> {
        let Some(mut writer) = self.writer.take() else {
            return Err(CliprdrError::CommonError {
                description: "clipboard staging file is already closed".to_owned(),
            });
        };
        writer
            .flush()
            .map_err(|err| file_error(&self.display_parent, err))?;
        writer
            .get_ref()
            .sync_all()
            .map_err(|err| file_error(&self.display_parent, err))?;
        drop(writer);

        let temp_name = self
            .temp_name
            .as_ref()
            .ok_or_else(|| CliprdrError::CommonError {
                description: "clipboard staging name is missing".to_owned(),
            })?;
        for attempt in 0..FINAL_NAME_ATTEMPTS {
            let candidate = self.candidate_name(attempt);
            match rustix::fs::renameat_with(
                &self.parent,
                temp_name,
                &self.parent,
                &candidate,
                rustix::fs::RenameFlags::NOREPLACE,
            ) {
                Ok(()) => {
                    self.temp_name = None;
                    let mut options = OpenOptions::new();
                    options.read(true).follow(FollowSymlinks::No);
                    self.parent
                        .open_with(".", &options)
                        .and_then(|directory| directory.sync_all())
                        .map_err(|err| file_error(&self.display_parent, err))?;
                    return Ok(self.display_parent.join(candidate));
                }
                Err(err) if err == rustix::io::Errno::EXIST => continue,
                Err(err) => return Err(file_error(&self.display_parent, err.into())),
            }
        }
        Err(CliprdrError::CommonError {
            description: format!(
                "failed to allocate a final clipboard file name under {}",
                self.display_parent.display()
            ),
        })
    }
}

impl Drop for PendingPasteFile {
    fn drop(&mut self) {
        if let Some(temp_name) = self.temp_name.as_ref() {
            let _ = self.parent.remove_file_or_symlink(temp_name);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{symlink, PermissionsExt},
        time::{SystemTime, UNIX_EPOCH},
    };

    struct TestDir(PathBuf);

    impl TestDir {
        fn new(tag: &str) -> Result<Self, Box<dyn std::error::Error>> {
            let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
            let path = std::env::temp_dir().join(format!(
                "camellia-paste-{tag}-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path)?;
            Ok(Self(path))
        }

        fn join(&self, path: &str) -> PathBuf {
            self.0.join(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn description(name: &str, kind: FileType) -> FileDescription {
        FileDescription {
            conn_id: 1,
            name: PathBuf::from(name),
            kind,
            atime: SystemTime::UNIX_EPOCH,
            last_modified: SystemTime::UNIX_EPOCH,
            last_metadata_changed: SystemTime::UNIX_EPOCH,
            creation_time: SystemTime::UNIX_EPOCH,
            size: 0,
            perm: 0o644,
        }
    }

    #[test]
    fn rejects_absolute_parent_and_noncanonical_paths() {
        for path in [
            "/outside.txt",
            "../outside.txt",
            "dir/../outside.txt",
            "./file.txt",
            "dir//file.txt",
            "dir/file.txt/",
            "bad\0name",
        ] {
            assert!(normalize_relative_path(Path::new(path)).is_err(), "{path}");
        }
        assert_eq!(
            normalize_relative_path(Path::new("dir/file.txt")).unwrap(),
            PathBuf::from("dir/file.txt")
        );
    }

    #[test]
    fn rejects_unicode_normalization_collisions() {
        let mut files = vec![
            description("\u{e9}.txt", FileType::File),
            description("e\u{301}.txt", FileType::File),
        ];
        assert!(normalize_file_descriptions(&mut files).is_err());
    }

    #[test]
    fn parent_symlink_cannot_escape_the_target() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("parent-symlink")?;
        let target = temp.join("target");
        let outside = temp.join("outside");
        fs::create_dir(&target)?;
        fs::create_dir(&outside)?;
        symlink(&outside, target.join("link"))?;
        let storage = PasteStorage::open(&target)?;

        assert!(storage
            .begin_file(Path::new("link/secret.txt"), 64)
            .is_err());
        assert!(!outside.join("secret.txt").exists());
        Ok(())
    }

    #[test]
    fn target_root_symlink_is_rejected() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("target-root-symlink")?;
        let target = temp.join("target");
        let actual_target = temp.join("actual-target");
        fs::create_dir(&actual_target)?;
        symlink(&actual_target, &target)?;

        assert!(PasteStorage::open(&target).is_err());
        Ok(())
    }

    #[test]
    fn predictable_symlink_is_not_opened_or_truncated() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("predictable-symlink")?;
        let target = temp.join("target");
        fs::create_dir(&target)?;
        let sentinel = temp.join("sentinel");
        fs::write(&sentinel, b"must remain")?;
        symlink(&sentinel, target.join("report.txt.rddownload"))?;
        let storage = PasteStorage::open(&target)?;

        let mut pending = storage.begin_file(Path::new("report.txt"), 64)?;
        pending.writer_mut()?.write_all(b"safe")?;
        let committed = pending.commit()?;

        assert_eq!(fs::read(&sentinel)?, b"must remain");
        assert_eq!(committed, target.join("report.txt"));
        assert_eq!(fs::read(committed)?, b"safe");
        assert!(target
            .join("report.txt.rddownload")
            .symlink_metadata()?
            .file_type()
            .is_symlink());
        Ok(())
    }

    #[test]
    fn staging_is_private_and_removed_when_abandoned() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("staging-cleanup")?;
        let target = temp.join("target");
        fs::create_dir(&target)?;
        let storage = PasteStorage::open(&target)?;
        let pending = storage.begin_file(Path::new("report.txt"), 64)?;
        assert_eq!(
            pending.file()?.metadata()?.permissions().mode() & 0o777,
            0o600
        );
        let staging = fs::read_dir(&target)?
            .next()
            .ok_or("staging file is missing")??
            .path();
        assert_eq!(staging.metadata()?.permissions().mode() & 0o777, 0o600);
        drop(pending);
        assert!(fs::read_dir(&target)?.next().is_none());
        Ok(())
    }

    #[test]
    fn final_name_race_does_not_overwrite_existing_file() -> Result<(), Box<dyn std::error::Error>>
    {
        let temp = TestDir::new("final-race")?;
        let target = temp.join("target");
        fs::create_dir(&target)?;
        let storage = PasteStorage::open(&target)?;
        let mut pending = storage.begin_file(Path::new("report.txt"), 64)?;
        pending.writer_mut()?.write_all(b"new")?;
        fs::write(target.join("report.txt"), b"old")?;

        let committed = pending.commit()?;
        assert_eq!(fs::read(target.join("report.txt"))?, b"old");
        assert_eq!(committed, target.join("report-1.txt"));
        assert_eq!(fs::read(committed)?, b"new");
        Ok(())
    }

    #[test]
    fn final_symlink_is_not_overwritten() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("final-symlink")?;
        let target = temp.join("target");
        fs::create_dir(&target)?;
        let sentinel = temp.join("sentinel");
        fs::write(&sentinel, b"must remain")?;
        symlink(&sentinel, target.join("report.txt"))?;
        let storage = PasteStorage::open(&target)?;
        let mut pending = storage.begin_file(Path::new("report.txt"), 64)?;
        pending.writer_mut()?.write_all(b"new")?;

        let committed = pending.commit()?;
        assert_eq!(fs::read(&sentinel)?, b"must remain");
        assert!(target
            .join("report.txt")
            .symlink_metadata()?
            .file_type()
            .is_symlink());
        assert_eq!(committed, target.join("report-1.txt"));
        assert_eq!(fs::read(committed)?, b"new");
        Ok(())
    }

    #[test]
    fn directory_creation_does_not_follow_symlinks() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("directory-symlink")?;
        let target = temp.join("target");
        let outside = temp.join("outside");
        fs::create_dir(&target)?;
        fs::create_dir(&outside)?;
        symlink(&outside, target.join("nested"))?;
        let storage = PasteStorage::open(&target)?;

        assert!(storage.ensure_directory(Path::new("nested/child")).is_err());
        assert!(!outside.join("child").exists());
        storage.ensure_directory(Path::new("regular/child"))?;
        assert!(target.join("regular/child").is_dir());
        Ok(())
    }
}
