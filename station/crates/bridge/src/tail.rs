//! One session file being followed: read new bytes from where we stopped, feed complete lines to
//! the session (a partial last line waits in [`LineBuffer`]), and say exactly which items changed.
//!
//! An item changes in two ways only (see `observatory_core::session`): it is appended, or it is a
//! tool call whose result arrives on a later line. Appends are the indexes past the old length.
//! For results, the line's own `tool_result` ids are looked up in a tool-id → index map kept here,
//! so the cost per line does not grow with the session.
//!
//! A file is re-read from the start (and sent whole) when its path now names a different file
//! (replaced by a rename: device + inode differ) or when it shrank. **Known limit:** a file that is
//! truncated in place AND refilled past the old offset between two reads looks like an append; the
//! session is then wrong until the bridge restarts. Claude Code only appends, so this is not expected.

use std::collections::{BTreeSet, HashMap};
use std::io;
use std::path::PathBuf;

use observatory_core::lines::{Line, LineBuffer};
use observatory_core::record::{Block, Parsed, RecordKind, parse_line};
use observatory_core::{ItemKind, Session};

use crate::discover::Found;
use crate::fsro::RoFile;

const CHUNK: usize = 1 << 20;

/// An empty session for `path`, knowing its log path (embedded images point back into it) and
/// `$HOME` (for `~/` in tool paths).
fn fresh_session(slug: String, id: String, path: &std::path::Path) -> Session {
    let mut s = Session::new(slug, id);
    s.meta.log_path = Some(path.to_string_lossy().into_owned());
    s.home = std::env::var("HOME").ok();
    s
}

/// What one [`Tail::read_new`] changed.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// The file shrank (rewritten): the session was rebuilt from the start; send it whole.
    pub reset: bool,
    /// At least one complete line was applied (meta/status may have changed).
    pub lines: usize,
    /// Indexes of items that are new or were completed in place.
    pub items: BTreeSet<usize>,
}

#[derive(Debug)]
pub struct Tail {
    pub path: PathBuf,
    pub project: String,
    pub session: Session,
    file: RoFile,
    offset: u64,
    buf: LineBuffer,
    tool_ix: HashMap<String, usize>,
    slug: String,
}

impl Tail {
    pub fn open(f: &Found) -> io::Result<Self> {
        Ok(Tail {
            path: f.path.clone(),
            project: f.project.clone(),
            session: fresh_session(f.slug.clone(), f.session_id.clone(), &f.path),
            file: RoFile::open(&f.path)?,
            offset: 0,
            buf: LineBuffer::new(),
            tool_ix: HashMap::new(),
            slug: f.slug.clone(),
        })
    }

    /// Bytes consumed so far (complete lines and the held partial line).
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Read everything appended since the last call.
    pub fn read_new(&mut self) -> io::Result<Changes> {
        let mut ch = Changes::default();
        if !self.file.is_still(&self.path) {
            if let Ok(f) = RoFile::open(&self.path) {
                self.file = f;
                self.restart();
                ch.reset = true;
            }
        } else if self.file.size()? < self.offset {
            self.restart();
            ch.reset = true;
        }
        let mut chunk = vec![0u8; CHUNK];
        loop {
            let n = self.file.read_at(self.offset, &mut chunk)?;
            if n == 0 {
                break;
            }
            self.offset += n as u64;
            for line in self.buf.push_lines(&chunk[..n]) {
                self.apply_line(&line, &mut ch.items);
                ch.lines += 1;
            }
        }
        Ok(ch)
    }

    /// Forget everything read so far; the next read starts at byte 0.
    fn restart(&mut self) {
        let id = self.session.meta.session_id.clone();
        self.session = fresh_session(self.slug.clone(), id, &self.path);
        self.offset = 0;
        self.buf = LineBuffer::new();
        self.tool_ix.clear();
    }

    fn apply_line(&mut self, l: &Line, changed: &mut BTreeSet<usize>) {
        let line = l.text.as_str();
        let before = self.session.items.len();
        // Only lines that can complete a call are parsed a second time.
        let result_ids: Vec<String> = if line.contains("\"tool_result\"") {
            match parse_line(line) {
                Parsed::Record(r) => match r.kind {
                    RecordKind::User(u) => u
                        .blocks
                        .into_iter()
                        .filter_map(|b| match b {
                            Block::ToolResult { tool_use_id, .. } => Some(tool_use_id),
                            _ => None,
                        })
                        .collect(),
                    _ => Vec::new(),
                },
                _ => Vec::new(),
            }
        } else {
            Vec::new()
        };
        self.session.push_line_at(line, l.offset, l.len);
        let after = self.session.items.len();
        for i in before..after {
            if let ItemKind::ToolCall(c) = &self.session.items[i].kind {
                self.tool_ix.insert(c.id.clone(), i); // same overwrite rule as core's tool_index
            }
            changed.insert(i);
        }
        for id in result_ids {
            if let Some(&i) = self.tool_ix.get(&id) {
                changed.insert(i);
            }
        }
    }
}
