//! Project galleries ("Visuals"): the image files in each project's configured folders,
//! newest first, found by polling (every [`SCAN_EVERY`] on a thread of its own).
//!
//! Why polling: a folder on a Windows drive under WSL (`/mnt/<drive>`) gets no inotify events for
//! files Windows programs write, and a big gallery can hold thousands of directories (one watch
//! each). A warm walk of such a tree takes well under a second, so a scan every few seconds is
//! cheap and needs no watches at all.
//!
//! Rules: PNG / JPEG / WebP by name (any case); folders recursive up to [`MAX_DEPTH`]; hidden
//! (`.name`) directories and symlinks skipped; a `*` or `?` in a folder's path segment matches
//! any directory name there, re-expanded every scan so new runs appear. A folder that is missing
//! is skipped and reported on stderr once. Only listing and stat (via [`crate::fsro`]).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::time::{Duration, UNIX_EPOCH};

use observatory_core::ProjectSpec;
use observatory_core::session::is_image_path;
use observatory_core::wire::{Frame, GALLERY_MAX, GalleryItem};

use crate::fsro;

/// How often the folders are scanned: a new image shows within this (plus the scan itself).
pub const SCAN_EVERY: Duration = Duration::from_secs(4);
/// Deeper folders are not entered (a link loop cannot form: symlinks are not followed).
pub const MAX_DEPTH: usize = 32;

/// `*` / `?` wildcard match of one path segment.
fn wild(pat: &[u8], name: &[u8]) -> bool {
    match (pat.first(), name.first()) {
        (None, None) => true,
        (Some(b'*'), _) => wild(&pat[1..], name) || (!name.is_empty() && wild(pat, &name[1..])),
        (Some(b'?'), Some(_)) => wild(&pat[1..], &name[1..]),
        (Some(p), Some(n)) if p == n => wild(&pat[1..], &name[1..]),
        _ => false,
    }
}

/// The existing directories a folder pattern names (one for a plain path).
pub fn expand(pattern: &str) -> Vec<PathBuf> {
    if !pattern.starts_with('/') {
        return Vec::new(); // relative: nothing to anchor it to
    }
    let mut dirs = vec![PathBuf::from("/")];
    for seg in pattern.split('/').filter(|s| !s.is_empty()) {
        let mut next = Vec::new();
        for d in &dirs {
            if seg.contains(['*', '?']) {
                for e in fsro::entries(d).unwrap_or_default() {
                    let name = e.path.file_name().map(|n| n.to_string_lossy().into_owned());
                    // Like a shell glob: a hidden `.name` matches only a pattern that starts
                    // with `.` itself (the walk below skips hidden folders too).
                    let shown = |n: &str| !n.starts_with('.') || seg.starts_with('.');
                    if e.is_dir
                        && name.is_some_and(|n| shown(&n) && wild(seg.as_bytes(), n.as_bytes()))
                    {
                        next.push(e.path);
                    }
                }
            } else {
                next.push(d.join(seg));
            }
        }
        dirs = next;
    }
    dirs.retain(|d| fsro::is_dir(d));
    dirs.sort();
    dirs
}

/// Every image under `root` (recursive), appended to `out`; paths already in `seen` are skipped.
fn walk(root: &Path, seen: &mut HashSet<PathBuf>, out: &mut Vec<GalleryItem>) {
    let mut stack = vec![(root.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        let Ok(entries) = fsro::entries(&dir) else {
            continue;
        };
        for e in entries {
            let name = e.path.file_name().unwrap_or_default().to_string_lossy();
            if e.is_dir {
                if depth < MAX_DEPTH && !name.starts_with('.') {
                    stack.push((e.path, depth + 1));
                }
            } else if e.is_file
                && is_image_path(&name)
                && let Some((m, size)) = fsro::file_stamp(&e.path)
                && seen.insert(e.path.clone())
            {
                let mtime_ms = match m.duration_since(UNIX_EPOCH) {
                    Ok(d) => d.as_millis() as i64,
                    Err(e) => -(e.duration().as_millis() as i64),
                };
                out.push(GalleryItem {
                    path: e.path.to_string_lossy().into_owned(),
                    mtime_ms,
                    size,
                });
            }
        }
    }
}

/// All images of a project's folders, newest first (ties by path), and how many there are;
/// only the newest [`GALLERY_MAX`] are kept. Folders that match nothing are added to `missing`.
pub fn scan(patterns: &[String], missing: &mut Vec<String>) -> (u32, Vec<GalleryItem>) {
    let mut seen = HashSet::new();
    let mut items = Vec::new();
    for p in patterns {
        let roots = expand(p);
        if roots.is_empty() {
            missing.push(p.clone());
        }
        for r in roots {
            walk(&r, &mut seen, &mut items);
        }
    }
    items.sort_by(|a, b| {
        b.mtime_ms
            .cmp(&a.mtime_ms)
            .then_with(|| a.path.cmp(&b.path))
    });
    let total = items.len().min(u32::MAX as usize) as u32;
    items.truncate(GALLERY_MAX);
    (total, items)
}

/// Scans every project that has a gallery and reports the ones whose list changed.
pub struct Scanner {
    projects: Vec<(String, Vec<String>)>,
    last: HashMap<String, (u32, Vec<GalleryItem>)>,
    reported_missing: HashSet<String>,
}

impl Scanner {
    pub fn new(specs: &[ProjectSpec]) -> Self {
        Scanner {
            projects: specs
                .iter()
                .filter(|p| !p.gallery.is_empty())
                .map(|p| (p.name.clone(), p.gallery.clone()))
                .collect(),
            last: HashMap::new(),
            reported_missing: HashSet::new(),
        }
    }

    /// True when no project has a gallery (no thread needed).
    pub fn is_empty(&self) -> bool {
        self.projects.is_empty()
    }

    /// One scan of every gallery: a `Gallery` frame for each project seen for the first time or
    /// whose list changed (an image added, changed or removed, or the total moved).
    pub fn pass(&mut self) -> Vec<Frame> {
        self.pass_logged(&mut |line| eprintln!("{line}"))
    }

    /// [`Scanner::pass`], with its stderr lines handed to `log` (tests read them).
    pub fn pass_logged(&mut self, log: &mut dyn FnMut(&str)) -> Vec<Frame> {
        let mut frames = Vec::new();
        for (name, patterns) in &self.projects {
            let mut missing = Vec::new();
            let (total, items) = scan(patterns, &mut missing);
            for m in missing {
                if self.reported_missing.insert(m.clone()) {
                    log(&format!(
                        "observatory-bridge: gallery folder not found, skipped: {m}"
                    ));
                }
            }
            let now = (total, items);
            if self.last.get(name) != Some(&now) {
                frames.push(Frame::Gallery {
                    project: name.clone(),
                    total: now.0,
                    items: now.1.clone(),
                });
                self.last.insert(name.clone(), now);
            }
        }
        frames
    }
}

/// Run `scanner` every [`SCAN_EVERY`] on its own thread, sending each changed gallery through
/// `tx` (wrapped by `wrap`); stops when the receiver is gone.
pub fn spawn<T: Send + 'static>(
    mut scanner: Scanner,
    every: Duration,
    tx: Sender<T>,
    wrap: fn(Frame) -> T,
) {
    let spawned = std::thread::Builder::new()
        .name("observatory-gallery".into())
        .spawn(move || {
            loop {
                for f in scanner.pass() {
                    if tx.send(wrap(f)).is_err() {
                        return;
                    }
                }
                std::thread::sleep(every);
            }
        });
    if let Err(e) = spawned {
        eprintln!("observatory-bridge: cannot start the gallery scanner: {e}");
    }
}
