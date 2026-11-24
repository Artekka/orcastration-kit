//! State and the update rule.
//!
//! **Startup:** `hello`, then one full `session` frame per discovered session (oldest first
//! activity first), each with its liveness already set in `status`.
//!
//! **Update rule** (what goes out when the logs change):
//! - New complete lines in a known session → one `patch` with the session's header (meta, status,
//!   stats, item count) and ONLY the items those lines appended or completed in place. Never the
//!   rest of the session, never other sessions of its thread.
//! - Updates to one session are coalesced: the first change starts a `coalesce_ms` window, and
//!   everything that arrives in it goes out as one frame.
//! - A new session file (or a known one that shrank, i.e. was rewritten) → one full `session` frame.
//! - Liveness re-check every `liveness_secs`: a session that became `Gone` → a `gone` frame (its
//!   held status is updated too, so its next patch says `gone`); one that became `Running` → a
//!   header-only `patch`.
//! - A partial last line sends nothing until its newline arrives.
//! - A session's `status.tmux` hint (its live process runs in tmux, per the registry) is set at
//!   each liveness check; a change goes out as a header-only `patch`.
//!
//! **Requests**: each stdin line goes to [`Bridge::on_request_line`]. A `send` is resolved
//! and typed by [`crate::tmux`] and answered with one `send_result`; anything else is logged on
//! stderr and ignored. Nothing is ever typed except in answer to a `send` line.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use observatory_core::wire::{self, Frame, PROTOCOL, Request, SendResult};
use observatory_core::{Liveness, ProjectSpec};

use crate::config::Config;
use crate::discover::{self, Found};
use crate::liveness::{self, LiveProc};
use crate::screen;
use crate::tail::{Changes, Tail};
use crate::tmux::{self, Terminal, Tmux};

/// The refusal when the agent's idle input box is not on its screen.
const NO_INPUT_BOX: &str = "This agent's input box isn't on its screen (a question or a dialog \
                            may be open), so nothing more is typed. Check its terminal.";

/// Why a send did not complete: before anything was typed, or after the paste began.
enum Failed {
    Refused(String),
    Uncertain(String),
}

/// Counters for the startup report on stderr.
#[derive(Debug, Default, Clone, Copy)]
pub struct Volume {
    pub frames: u64,
    pub bytes: u64,
}

/// Process data source: `None` = not available on this platform.
pub type ScanFn = dyn FnMut(&Path) -> Option<Vec<LiveProc>>;

#[derive(Debug, Default)]
struct Pending {
    full: bool,
    items: BTreeSet<usize>,
}

pub struct Bridge<W: Write> {
    pub cfg: Config,
    pub claude_dir: PathBuf,
    tails: BTreeMap<PathBuf, Tail>,
    dirty: BTreeMap<PathBuf, Pending>,
    dirty_since: Option<Instant>,
    out: W,
    pub volume: Volume,
    /// Process data source; replaceable in tests.
    scan: Box<ScanFn>,
    /// Where sends go (real tmux; a fake in tests).
    term: Box<dyn Terminal>,
    /// A pid's parent, read now (from `/proc`; a fake in tests).
    parent: Box<dyn Fn(u32) -> Option<u32>>,
}

impl<W: Write> Bridge<W> {
    pub fn new(cfg: Config, claude_dir: PathBuf, out: W) -> Self {
        Bridge {
            cfg,
            claude_dir,
            tails: BTreeMap::new(),
            dirty: BTreeMap::new(),
            dirty_since: None,
            out,
            volume: Volume::default(),
            scan: Box::new(liveness::scan),
            term: Box::new(Tmux::default()),
            parent: Box::new(liveness::parent_of),
        }
    }

    /// Replace the terminal side and the parent lookup (tests).
    pub fn with_terminal(
        mut self,
        term: impl Terminal + 'static,
        parent: impl Fn(u32) -> Option<u32> + 'static,
    ) -> Self {
        self.term = Box::new(term);
        self.parent = Box::new(parent);
        self
    }

    /// One line from stdin. A `send` is answered with one `send_result` frame; a line that is
    /// not a request (bad JSON, an unknown command, extra fields) is logged and ignored.
    pub fn on_request_line(&mut self, line: &str) -> io::Result<()> {
        let line = line.trim();
        if line.is_empty() {
            return Ok(());
        }
        let Request::Send {
            id,
            session_id,
            text,
        } = match Request::from_line(line) {
            Ok(r) => r,
            Err(e) => {
                let head: String = line.chars().take(80).collect();
                eprintln!("observatory-bridge: ignored a request that is not a send ({e}): {head}");
                return Ok(());
            }
        };
        let result = match self.type_into(&session_id, &text, id) {
            Ok(t) => {
                eprintln!(
                    "observatory-bridge: send {id}: {} bytes typed into pane {} (pid {}, session {session_id})",
                    text.len(),
                    t.pane,
                    t.pid
                );
                SendResult::Sent
            }
            Err(Failed::Refused(reason)) => {
                eprintln!("observatory-bridge: send {id} refused: {reason}");
                SendResult::Refused { reason }
            }
            Err(Failed::Uncertain(reason)) => {
                eprintln!(
                    "observatory-bridge: send {id} UNCERTAIN (after the paste began): {reason}"
                );
                SendResult::Uncertain { reason }
            }
        };
        self.send(&Frame::SendResult { id, result })
    }

    /// The pane to type into for `session_id`, resolved from data read NOW.
    fn resolve_now(&mut self, session_id: &str) -> Result<tmux::Target, String> {
        let procs = (self.scan)(&self.claude_dir)
            .ok_or("This machine gives no process data, so the agent can't be found.")?;
        let panes = self.term.panes()?;
        tmux::resolve(session_id, &procs, &panes, &*self.parent)
    }

    /// Re-resolve now and demand the SAME pane and the SAME live process as `target`.
    fn still(&mut self, session_id: &str, target: &tmux::Target) -> Result<(), String> {
        match self.resolve_now(session_id) {
            Ok(t) if t == *target => Ok(()),
            Ok(t) => Err(format!(
                "The agent changed while sending (pane {} pid {} is now pane {} pid {}).",
                target.pane, target.pid, t.pane, t.pid
            )),
            Err(e) => Err(format!("The agent changed while sending: {e}")),
        }
    }

    /// Resolve the pane NOW and type `text` into it. Up to the paste, a failure is `Refused`
    /// (nothing typed); from the paste on, any failure or change is `Uncertain` (the text may sit
    /// unsent in the agent's box), and no Enter is pressed after a change.
    fn type_into(&mut self, session_id: &str, text: &str, id: u64) -> Result<tmux::Target, Failed> {
        use Failed::{Refused, Uncertain};
        if let Some(why) = wire::send_text_problem(text) {
            return Err(Refused(why));
        }
        let target = self.resolve_now(session_id).map_err(Refused)?;
        let buffer = format!("observatory-{}-{id}", std::process::id());
        self.term.load(&buffer, text).map_err(Refused)?;
        // Right before the paste: still the same pane and process, and no menu on screen?
        if let Err(e) = self.still(session_id, &target) {
            self.term.discard(&buffer);
            return Err(Refused(e));
        }
        if let Err(e) = self.no_menu(&target.pane) {
            self.term.discard(&buffer);
            return Err(Refused(e));
        }
        self.term.paste(&target.pane, &buffer).map_err(Uncertain)?;
        std::thread::sleep(self.term.settle());
        // Right before the Enter: the same checks again. Else no Enter.
        self.still(session_id, &target).map_err(Uncertain)?;
        self.no_menu(&target.pane).map_err(Uncertain)?;
        self.term.enter(&target.pane).map_err(Uncertain)?;
        Ok(target)
    }

    /// Read `pane` now: refuse unless Claude Code's idle input box is on screen, and when the
    /// screen can't be read (fail closed). Claude Code marks a dialog `waiting` only after
    /// drawing it, so the registry alone can miss one.
    fn no_menu(&mut self, pane: &str) -> Result<(), String> {
        let shown = match self.term.screen(pane) {
            Ok(s) => s,
            Err(e) => {
                return Err(format!(
                    "The agent's screen could not be read ({e}), so an open menu can't be \
                     ruled out."
                ));
            }
        };
        if !screen::input_box_ready(&shown) {
            return Err(NO_INPUT_BOX.into());
        }
        Ok(())
    }

    pub fn with_scan(mut self, f: impl FnMut(&Path) -> Option<Vec<LiveProc>> + 'static) -> Self {
        self.scan = Box::new(f);
        self
    }

    pub fn projects_dir(&self) -> PathBuf {
        self.claude_dir.join("projects")
    }

    pub fn specs(&self) -> &[ProjectSpec] {
        &self.cfg.projects
    }

    pub fn session_count(&self) -> usize {
        self.tails.len()
    }

    pub fn into_output(self) -> W {
        self.out
    }

    /// Write a frame built elsewhere (a gallery from the scanner thread).
    pub fn send(&mut self, f: &Frame) -> io::Result<()> {
        self.emit(f)?;
        self.out.flush()
    }

    fn emit(&mut self, f: &Frame) -> io::Result<()> {
        let line = f.to_line();
        self.out.write_all(line.as_bytes())?;
        self.out.write_all(b"\n")?;
        self.volume.frames += 1;
        self.volume.bytes += line.len() as u64 + 1;
        Ok(())
    }

    pub fn hello(&mut self) -> io::Result<()> {
        self.emit(&Frame::Hello {
            protocol: PROTOCOL,
            distro: std::env::var("WSL_DISTRO_NAME")
                .ok()
                .filter(|d| !d.is_empty()),
            seats: self.cfg.seats.clone(),
            note: self.cfg.note.clone(),
        })?;
        self.out.flush()
    }

    /// Read every session file modified since the cutoff and send them whole.
    pub fn startup(&mut self) -> io::Result<()> {
        let since = (self.cfg.cutoff_days > 0)
            .then(|| SystemTime::now() - Duration::from_secs(self.cfg.cutoff_days * 86_400));
        for f in discover::discover(&self.projects_dir(), &self.cfg.projects, since) {
            self.add(&f);
        }
        self.refresh_liveness(false)?;
        let mut order: Vec<&PathBuf> = self.tails.keys().collect();
        order.sort_by_key(|p| {
            let s = &self.tails[*p].session;
            (s.meta.first_activity_ms, s.meta.session_id.clone())
        });
        let order: Vec<PathBuf> = order.into_iter().cloned().collect();
        for p in order {
            self.send_full(&p)?;
        }
        self.dirty.clear();
        self.dirty_since = None;
        self.out.flush()
    }

    /// Start following a file (reads it to the end). Unreadable files are skipped.
    fn add(&mut self, f: &Found) -> bool {
        let Ok(mut t) = Tail::open(f) else {
            return false;
        };
        if t.read_new().is_err() {
            return false;
        }
        self.tails.insert(f.path.clone(), t);
        true
    }

    fn send_full(&mut self, path: &Path) -> io::Result<()> {
        let t = &self.tails[path];
        let f = Frame::Session {
            project: t.project.clone(),
            session: Box::new(t.session.clone()),
        };
        self.emit(&f)
    }

    fn mark(&mut self, path: &Path, ch: Changes, full: bool) {
        if !full && !ch.reset && ch.lines == 0 {
            return;
        }
        let p = self.dirty.entry(path.to_path_buf()).or_default();
        p.full |= full || ch.reset;
        p.items.extend(ch.items);
        self.dirty_since.get_or_insert_with(Instant::now);
    }

    /// A filesystem event for `path` (a session file, or a slug dir that just appeared).
    pub fn on_path(&mut self, path: &Path) -> io::Result<()> {
        if let Some(t) = self.tails.get_mut(path) {
            if let Ok(ch) = t.read_new() {
                self.mark(path, ch, false);
            }
            return Ok(());
        }
        let pd = self.projects_dir();
        let mut added = false;
        if let Some(f) = discover::session_file(path, &pd, &self.cfg.projects) {
            if crate::fsro::metadata(path).is_some_and(|m| m.is_file()) && self.add(&f) {
                self.mark(path, Changes::default(), true);
                added = true;
            }
        } else if discover::project_of_dir(path, &pd, &self.cfg.projects).is_some() {
            for f in discover::files_in(path, &pd, &self.cfg.projects, None) {
                if !self.tails.contains_key(&f.path) && self.add(&f) {
                    self.mark(&f.path, Changes::default(), true);
                    added = true;
                }
            }
        }
        if added {
            // The new session's liveness rides in its pending full frame; changes to the
            // others go out as usual.
            self.refresh_liveness(true)?;
        }
        Ok(())
    }

    /// Re-check process data. With `emit`, changes go out (see the module rule).
    pub fn refresh_liveness(&mut self, emit: bool) -> io::Result<()> {
        let Some(procs) = (self.scan)(&self.claude_dir) else {
            return Ok(()); // no process data on this platform: stays Unknown
        };
        let now = liveness::assign(
            self.tails
                .values()
                .map(|t| (t.project.as_str(), &t.session)),
            &procs,
            &self.cfg.projects,
        );
        let in_tmux: BTreeSet<&str> = procs
            .iter()
            .filter(|p| p.tmux.is_some())
            .filter_map(|p| p.session_id.as_deref())
            .collect();
        let mut gone = Vec::new();
        let mut revived = Vec::new();
        for (path, t) in self.tails.iter_mut() {
            let new = now
                .get(&t.session.meta.session_id)
                .copied()
                .unwrap_or(Liveness::Gone);
            let old = t.session.status.liveness;
            let tmux =
                new != Liveness::Gone && in_tmux.contains(t.session.meta.session_id.as_str());
            if tmux != t.session.status.tmux {
                t.session.status.tmux = tmux;
                if new == old {
                    revived.push(path.clone()); // header-only patch with the new hint
                    continue;
                }
            }
            if new == old {
                continue;
            }
            t.session.status.liveness = new;
            if new == Liveness::Gone {
                gone.push((path.clone(), t.session.meta.session_id.clone(), old));
            } else {
                revived.push(path.clone());
            }
        }
        if !emit {
            return Ok(());
        }
        for (path, id, old) in gone {
            // A session whose full frame is still pending needs no `gone` frame of its own:
            // the full frame carries the status.
            if old == Liveness::Unknown && self.dirty.get(&path).is_some_and(|p| p.full) {
                continue;
            }
            self.emit(&Frame::Gone { session_id: id })?;
        }
        for p in revived {
            self.dirty.entry(p).or_default();
            self.dirty_since.get_or_insert_with(Instant::now);
        }
        self.out.flush()
    }

    /// When the pending window closes (None = nothing pending).
    pub fn flush_due(&self) -> Option<Instant> {
        self.dirty_since
            .map(|t| t + Duration::from_millis(self.cfg.coalesce_ms))
    }

    /// Send everything pending: a full frame or one patch per dirty session.
    pub fn flush(&mut self) -> io::Result<()> {
        let dirty = std::mem::take(&mut self.dirty);
        self.dirty_since = None;
        for (path, p) in dirty {
            if !self.tails.contains_key(&path) {
                continue;
            }
            if p.full {
                self.send_full(&path)?;
            } else {
                let f = Frame::patch(&self.tails[&path].session, p.items);
                self.emit(&f)?;
            }
        }
        self.out.flush()
    }

    /// Bytes read so far per session file (diagnostics, tests).
    pub fn offsets(&self) -> HashMap<PathBuf, u64> {
        self.tails
            .iter()
            .map(|(p, t)| (p.clone(), t.offset()))
            .collect()
    }
}

impl Bridge<Vec<u8>> {
    /// Lines written so far, removing them from the buffer (tests).
    pub fn drain_output(&mut self) -> Vec<String> {
        let out = std::mem::take(&mut self.out);
        String::from_utf8_lossy(&out)
            .lines()
            .map(str::to_owned)
            .collect()
    }
}
