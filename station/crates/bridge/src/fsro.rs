//! The ONLY place the bridge touches the filesystem. Everything here reads; nothing creates,
//! writes, renames, removes or changes permissions. `tests/read_only.rs` scans the crate's source
//! to keep it that way (no other module may name `std::fs` or `File`) and checks, on Linux, that
//! the file descriptors a running bridge holds on log files are opened read-only.

use std::fs::{self, File, Metadata};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// A file opened for reading only.
#[derive(Debug)]
pub struct RoFile(File);

impl RoFile {
    /// `File::open` is read-only (`O_RDONLY`) by definition.
    pub fn open(path: &Path) -> io::Result<Self> {
        File::open(path).map(RoFile)
    }

    /// False when `path` no longer names the file held open (replaced by a rename, or deleted).
    /// Unix compares device + inode; elsewhere it cannot tell and says true.
    pub fn is_still(&self, path: &Path) -> bool {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            match (self.0.metadata(), fs::metadata(path)) {
                (Ok(held), Ok(now)) => held.dev() == now.dev() && held.ino() == now.ino(),
                _ => false,
            }
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            true
        }
    }

    pub fn size(&self) -> io::Result<u64> {
        Ok(self.0.metadata()?.len())
    }

    /// Read up to `buf.len()` bytes at `offset`.
    pub fn read_at(&mut self, offset: u64, buf: &mut [u8]) -> io::Result<usize> {
        self.0.seek(SeekFrom::Start(offset))?;
        self.0.read(buf)
    }
}

/// Whole small file (configs, the session registry) as text.
pub fn read_text(path: &Path) -> io::Result<String> {
    let mut s = String::new();
    File::open(path)?.read_to_string(&mut s)?;
    Ok(s)
}

/// Directory entries (names only, sorted); a missing or unreadable dir is empty.
pub fn list_dir(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    v.sort();
    v
}

pub fn metadata(path: &Path) -> Option<Metadata> {
    fs::metadata(path).ok()
}

pub fn is_dir(path: &Path) -> bool {
    metadata(path).is_some_and(|m| m.is_dir())
}

pub fn modified(path: &Path) -> Option<SystemTime> {
    metadata(path).and_then(|m| m.modified().ok())
}

/// Target of a symlink such as `/proc/<pid>/cwd`.
pub fn read_link(path: &Path) -> Option<PathBuf> {
    fs::read_link(path).ok()
}

/// Raw bytes of a small file such as `/proc/<pid>/cmdline`.
pub fn read_bytes(path: &Path) -> Option<Vec<u8>> {
    let mut v = Vec::new();
    File::open(path).ok()?.read_to_end(&mut v).ok()?;
    Some(v)
}

/// One directory entry. A symlink is neither a directory nor a file here: it is never followed.
#[derive(Debug)]
pub struct Entry {
    pub path: PathBuf,
    pub is_dir: bool,
    pub is_file: bool,
}

/// Directory entries with their types (unsorted, no symlinks followed); `Err` when the
/// directory cannot be read.
pub fn entries(dir: &Path) -> io::Result<Vec<Entry>> {
    let mut v = Vec::new();
    for e in fs::read_dir(dir)? {
        let Ok(e) = e else { continue };
        let Ok(t) = e.file_type() else { continue };
        v.push(Entry {
            path: e.path(),
            is_dir: t.is_dir(),
            is_file: t.is_file(),
        });
    }
    Ok(v)
}

/// Modified time and size of `path` itself (a symlink is not followed).
pub fn file_stamp(path: &Path) -> Option<(SystemTime, u64)> {
    let m = fs::symlink_metadata(path).ok()?;
    Some((m.modified().ok()?, m.len()))
}
