//! Sandboxed storage backing the protocol's filesystem operations.
//!
//! Every path in this module arrives from the network, so path resolution
//! is a security boundary, not a convenience: nothing may escape the
//! configured root.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use crate::protocol::DirEntry;
use sha2::{Digest, Sha256};
use tokio::fs::{self, File, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

/// Suffix for in-flight transfers. A file only takes its real name once
/// its full-content hash has been verified, so a crash mid-transfer can
/// never leave a truncated file masquerading as a complete one.
const PARTIAL_SUFFIX: &str = ".silo-part";

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("rejected path {0:?}: {1}")]
    RejectedPath(String, &'static str),
    #[error("no open file handle for {0:?}")]
    NoSuchHandle(String),
    #[error("integrity check failed for {0:?}")]
    IntegrityFailure(String),
}

pub struct Storage {
    root: PathBuf,
    writers: HashMap<String, File>,
    readers: HashMap<String, File>,
}

impl Storage {
    pub fn new(root: PathBuf) -> Self {
        Self { root, writers: HashMap::new(), readers: HashMap::new() }
    }

    /// Maps a client-supplied relative path into the sandbox.
    ///
    /// Rejects absolute paths, parent traversal, and anything that is not a
    /// plain name component. This is deliberately allow-list shaped: only
    /// `Component::Normal` survives, so tricks like `..`, `/etc/passwd`,
    /// or Windows prefixes cannot produce a path outside `root`.
    fn resolve(&self, relative: &str) -> Result<PathBuf, StorageError> {
        if relative.is_empty() {
            return Err(StorageError::RejectedPath(relative.into(), "empty"));
        }
        if relative.contains('\0') {
            return Err(StorageError::RejectedPath(relative.into(), "contains NUL"));
        }

        let candidate = Path::new(relative);
        let mut resolved = self.root.clone();
        for component in candidate.components() {
            match component {
                Component::Normal(part) => resolved.push(part),
                Component::CurDir => {}
                Component::ParentDir => {
                    return Err(StorageError::RejectedPath(relative.into(), "parent traversal"))
                }
                Component::RootDir | Component::Prefix(_) => {
                    return Err(StorageError::RejectedPath(relative.into(), "absolute path"))
                }
            }
        }
        Ok(resolved)
    }

    fn partial_path(&self, relative: &str) -> Result<PathBuf, StorageError> {
        let mut path = self.resolve(relative)?;
        let mut name = path
            .file_name()
            .ok_or(StorageError::RejectedPath(relative.into(), "no file name"))?
            .to_os_string();
        name.push(PARTIAL_SUFFIX);
        path.set_file_name(name);
        Ok(path)
    }

    pub async fn create_dir_all(&self, relative: &str) -> Result<(), StorageError> {
        let path = self.resolve(relative)?;
        fs::create_dir_all(path).await?;
        Ok(())
    }

    pub async fn exists(&self, relative: &str) -> Result<bool, StorageError> {
        let path = self.resolve(relative)?;
        Ok(fs::metadata(path).await.is_ok())
    }

    pub async fn is_dir(&self, relative: &str) -> Result<bool, StorageError> {
        let path = self.resolve(relative)?;
        match fs::metadata(path).await {
            Ok(meta) => Ok(meta.is_dir()),
            Err(_) => Ok(false),
        }
    }

    /// Entries directly inside `relative`. A missing directory lists as
    /// empty rather than erroring — the device asks about directories that
    /// legitimately do not exist yet on a first backup.
    ///
    /// Partial (`.silo-part`) files are skipped: they hold bytes whose hash
    /// has not been verified, so as far as the device is concerned they are
    /// not part of the backup.
    pub async fn list_dir(&self, relative: &str) -> Result<Vec<DirEntry>, StorageError> {
        let path = self.resolve(relative)?;
        let mut reader = match fs::read_dir(&path).await {
            Ok(reader) => reader,
            Err(_) => return Ok(Vec::new()),
        };
        let mut out = Vec::new();
        while let Some(entry) = reader.next_entry().await? {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(PARTIAL_SUFFIX) {
                continue;
            }
            let Ok(meta) = entry.metadata().await else { continue };
            let modified = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64);
            out.push(DirEntry {
                name,
                is_dir: meta.is_dir(),
                size: meta.len(),
                modified,
            });
        }
        Ok(out)
    }

    /// See `Request::Stat` for the meaning of the returned pair.
    pub async fn stat(&self, relative: &str) -> Result<(bool, u64), StorageError> {
        let final_path = self.resolve(relative)?;
        if let Ok(meta) = fs::metadata(&final_path).await {
            if meta.is_file() {
                return Ok((true, meta.len()));
            }
        }
        let partial = self.partial_path(relative)?;
        if let Ok(meta) = fs::metadata(&partial).await {
            if meta.is_file() {
                return Ok((false, meta.len()));
            }
        }
        Ok((false, 0))
    }

    pub async fn create_file_write(&mut self, relative: &str, truncate: bool) -> Result<(), StorageError> {
        let partial = self.partial_path(relative)?;
        if let Some(parent) = partial.parent() {
            fs::create_dir_all(parent).await?;
        }

        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .append(!truncate)
            .truncate(truncate)
            .open(&partial)
            .await?;

        self.writers.insert(relative.to_string(), file);
        Ok(())
    }

    pub async fn write_chunk(&mut self, relative: &str, data: &[u8]) -> Result<(), StorageError> {
        let file = self
            .writers
            .get_mut(relative)
            .ok_or_else(|| StorageError::NoSuchHandle(relative.to_string()))?;
        file.write_all(data).await?;
        // tokio::fs::File hands writes off to a blocking-pool task; without
        // this, `write_all` can return before the bytes are actually
        // visible to another handle (e.g. the `fs::metadata` call `Stat`
        // uses after a reconnect) — measured directly, not assumed: a
        // fresh Storage's Stat reported size 0 right after a peer's
        // WriteChunk returned Ok. That would silently break resume after
        // exactly the crash-then-reconnect scenario resume exists for.
        file.flush().await?;
        Ok(())
    }

    /// Flushes, verifies the stored bytes against `expected`, then
    /// atomically publishes the file under its real name.
    ///
    /// The hash is computed by re-reading what actually landed on disk
    /// rather than by hashing bytes as they streamed in. That costs one
    /// local read pass but validates the real artifact — and stays correct
    /// when a transfer was resumed across connections, where an in-memory
    /// running hash would only cover the latest segment.
    pub async fn close_file(&mut self, relative: &str, expected: &[u8; 32]) -> Result<(), StorageError> {
        let mut file = self
            .writers
            .remove(relative)
            .ok_or_else(|| StorageError::NoSuchHandle(relative.to_string()))?;
        file.flush().await?;
        file.sync_all().await?;
        drop(file);

        let partial = self.partial_path(relative)?;
        let actual = hash_file(&partial).await?;
        if &actual != expected {
            let _ = fs::remove_file(&partial).await;
            return Err(StorageError::IntegrityFailure(relative.to_string()));
        }

        let final_path = self.resolve(relative)?;
        if let Some(parent) = final_path.parent() {
            fs::create_dir_all(parent).await?;
        }
        fs::rename(&partial, &final_path).await?;
        Ok(())
    }

    pub async fn open_file_read(&mut self, relative: &str) -> Result<(), StorageError> {
        let path = self.resolve(relative)?;
        let file = File::open(path).await?;
        self.readers.insert(relative.to_string(), file);
        Ok(())
    }

    /// Returns `None` at end of file.
    pub async fn read_chunk(&mut self, relative: &str, max: usize) -> Result<Option<Vec<u8>>, StorageError> {
        let file = self
            .readers
            .get_mut(relative)
            .ok_or_else(|| StorageError::NoSuchHandle(relative.to_string()))?;

        let mut buffer = vec![0u8; max];
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            return Ok(None);
        }
        buffer.truncate(read);
        Ok(Some(buffer))
    }

    pub fn close_read(&mut self, relative: &str) {
        self.readers.remove(relative);
    }

    pub async fn remove(&mut self, relative: &str) -> Result<(), StorageError> {
        self.writers.remove(relative);
        self.readers.remove(relative);

        let path = self.resolve(relative)?;
        match fs::metadata(&path).await {
            Ok(meta) if meta.is_dir() => fs::remove_dir_all(&path).await?,
            Ok(_) => fs::remove_file(&path).await?,
            // Removing something absent is not an error: the delegate uses
            // remove() to clear state it cannot know the existence of.
            Err(_) => {}
        }
        Ok(())
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<(), StorageError> {
        let from_path = self.resolve(from)?;
        let to_path = self.resolve(to)?;
        if let Some(parent) = to_path.parent() {
            fs::create_dir_all(parent).await?;
        }
        fs::rename(from_path, to_path).await?;
        Ok(())
    }

    pub async fn copy(&self, src: &str, dst: &str) -> Result<(), StorageError> {
        let src_path = self.resolve(src)?;
        let dst_path = self.resolve(dst)?;
        if let Some(parent) = dst_path.parent() {
            fs::create_dir_all(parent).await?;
        }
        fs::copy(src_path, dst_path).await?;
        Ok(())
    }
}

async fn hash_file(path: &Path) -> Result<[u8; 32], StorageError> {
    let mut file = File::open(path).await?;
    file.seek(std::io::SeekFrom::Start(0)).await?;

    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn storage() -> Storage {
        Storage::new(PathBuf::from("/srv/silo"))
    }

    #[test]
    fn rejects_parent_traversal() {
        assert!(storage().resolve("../etc/passwd").is_err());
        assert!(storage().resolve("backups/../../etc/passwd").is_err());
    }

    #[test]
    fn rejects_absolute_paths() {
        assert!(storage().resolve("/etc/passwd").is_err());
    }

    #[test]
    fn rejects_empty_and_nul() {
        assert!(storage().resolve("").is_err());
        assert!(storage().resolve("a\0b").is_err());
    }

    #[test]
    fn accepts_normal_nested_paths() {
        let resolved = storage().resolve("2026-07-26/ab/abcdef").unwrap();
        assert_eq!(resolved, PathBuf::from("/srv/silo/2026-07-26/ab/abcdef"));
    }

    #[test]
    fn current_dir_components_are_harmless() {
        let resolved = storage().resolve("./a/./b").unwrap();
        assert_eq!(resolved, PathBuf::from("/srv/silo/a/b"));
    }

    #[test]
    fn partial_path_sits_next_to_target() {
        let partial = storage().partial_path("snap/file.db").unwrap();
        assert_eq!(partial, PathBuf::from("/srv/silo/snap/file.db.silo-part"));
    }
}
