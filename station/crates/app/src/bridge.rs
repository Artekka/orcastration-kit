//! The live source: start the WSL bridge, read its JSON-line frames on a background thread, and
//! hand the window a fresh view-model only when a frame changed something.
//!
//! - Windows: `wsl.exe --exec sh -c 'exec "$HOME/.local/share/observatory/bin/observatory-bridge"'`
//!   (`$HOME` is resolved inside WSL), spawned with `CREATE_NO_WINDOW` so no console flashes up.
//! - Elsewhere (dev, tests): the bridge binary is run directly.
//! - `--bridge <path>` overrides the binary path on both.
//!
//! Repaint rule: the reader thread calls its `repaint` hook only when [`LiveState::apply`] says a
//! frame changed what is shown, or when the connection state changes (connected, failed). Bad
//! lines, unknown frames, and frames that change nothing never wake the window.
//!
//! Spawning happens on the reader thread, so a slow `wsl.exe` start never blocks the window.
//!
//! Typing: the bridge's stdin carries [`Request`] lines. [`LiveSource::send`] writes ONE
//! request for the current connection and returns its id; the answer arrives as a
//! `send_result` frame ([`LiveSource::reply`]). The only caller is the prompt box, on the
//! human's Send. A retry drops the old connection's input with its child, so a request can
//! never reach a bridge other than the one it was written for.

use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

use observatory_core::Frame;
use observatory_core::wire::{Request, SendResult};

use crate::live::{LiveState, Offsets, Seats};
use crate::model::ViewModel;

/// Where `scripts/deploy.sh` installs the bridge inside WSL, relative to `$HOME`.
pub const BRIDGE_REL: &str = ".local/share/observatory/bin/observatory-bridge";
/// Last stderr lines kept for the failure banner.
const STDERR_KEEP: usize = 6;
/// Stderr bytes kept while reading (the tail; enough for `STDERR_KEEP` lines).
const STDERR_BYTES: usize = 16 * 1024;

/// Stderr bytes → its last few lines. `wsl.exe`'s own messages are UTF-16LE (with or without
/// a BOM); the bridge's are UTF-8. NULs and CRs never reach the banner.
pub fn decode_stderr(b: &[u8]) -> String {
    let utf16 = b.starts_with(&[0xFF, 0xFE])
        || (b.len() >= 4 && b.iter().skip(1).step_by(2).take(8).all(|&x| x == 0));
    let text = if utf16 {
        let units: Vec<u16> = b
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&c| u16::from_le_bytes(c))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(b).into_owned()
    };
    let lines: Vec<&str> = text
        .split(['\n', '\r'])
        .map(|l| l.trim_matches(|c: char| c == '\u{FEFF}' || c == '\0' || c.is_whitespace()))
        .filter(|l| !l.is_empty())
        .collect();
    lines[lines.len().saturating_sub(STDERR_KEEP)..].join("\n")
}

/// How to start the bridge.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Launch {
    /// Through `wsl.exe`; `path` is the bridge's path inside WSL (`None` = the installed one).
    Wsl { path: Option<String> },
    /// Run this program directly with these args.
    Direct { program: String, args: Vec<String> },
}

impl Launch {
    /// The default for this platform, with an optional explicit bridge path.
    pub fn for_platform(path: Option<String>) -> Self {
        if cfg!(windows) {
            Launch::Wsl { path }
        } else {
            let program = path.unwrap_or_else(|| match std::env::var("HOME") {
                Ok(h) => format!("{h}/{BRIDGE_REL}"),
                Err(_) => format!("~/{BRIDGE_REL}"),
            });
            Launch::Direct {
                program,
                args: vec![],
            }
        }
    }

    /// What the banner calls the bridge.
    pub fn describe(&self) -> String {
        match self {
            Launch::Wsl { path: None } => format!("~/{BRIDGE_REL} (in WSL)"),
            Launch::Wsl { path: Some(p) } => format!("{p} (in WSL)"),
            Launch::Direct { program, .. } => program.clone(),
        }
    }

    pub fn command(&self) -> Command {
        match self {
            Launch::Wsl { path } => {
                let target = match path {
                    None => format!("\"$HOME/{BRIDGE_REL}\""),
                    Some(p) => sh_quote(p),
                };
                let mut c = Command::new("wsl.exe");
                c.args(["--exec", "sh", "-c", &format!("exec {target}")]);
                no_window(&mut c);
                c
            }
            Launch::Direct { program, args } => {
                let mut c = Command::new(program);
                c.args(args);
                no_window(&mut c);
                c
            }
        }
    }
}

fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(windows)]
fn no_window(c: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    c.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn no_window(_: &mut Command) {}

/// What the banner shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Conn {
    /// Started, no `hello` yet.
    Connecting,
    /// `hello` received; frames flowing.
    Live,
    /// No live data, and why (one line or a few).
    Failed(String),
}

#[derive(Debug)]
pub struct Shared {
    pub state: LiveState,
    pub conn: Conn,
    /// Bumped on every visible change; the window rebuilds its model when it moves.
    pub generation: u64,
    /// Bumped by each (re)start and by drop; a reader whose epoch is stale changes nothing
    /// and kills its child.
    pub epoch: u64,
    /// Raw bytes of stdout lines that were not frames (the tail, bounded). `wsl.exe` prints its
    /// own errors here, in UTF-16; the failure banner shows them.
    pub noise: Vec<u8>,
    /// The current connection's request pipe (the bridge's stdin); `None` until it is up, and
    /// again from the moment a retry or drop starts.
    pub input: Option<Input>,
    /// Last request id handed out (ids are unique for the life of the source).
    pub last_id: u64,
}

/// Where request lines go: the bridge's stdin, or a test's buffer.
pub struct Input(pub Box<dyn Write + Send>);

impl std::fmt::Debug for Input {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Input")
    }
}

/// A request that went out: its id and the connection it went to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sent {
    pub id: u64,
    pub epoch: u64,
}

/// What the prompt box learns about a request it sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reply {
    /// No answer yet.
    Waiting,
    Answered(SendResult),
    /// The connection it went to is gone (retry, failure): it may or may not have been typed.
    Lost,
}

/// Append to a bounded byte tail, keeping UTF-16 pairs aligned when it trims.
fn push_tail(t: &mut Vec<u8>, bytes: &[u8]) {
    t.extend_from_slice(bytes);
    if t.len() > STDERR_BYTES {
        let cut = (t.len() - STDERR_BYTES) & !1;
        t.drain(..cut);
    }
}

/// What the banner quotes: the last lines of non-frame stdout and of stderr, decoded.
pub fn output_tail(stdout_noise: &[u8], stderr: &[u8]) -> String {
    let both = [decode_stderr(stdout_noise), decode_stderr(stderr)]
        .into_iter()
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    let lines: Vec<&str> = both.lines().collect();
    lines[lines.len().saturating_sub(STDERR_KEEP)..].join("\n")
}

pub type Repaint = Arc<dyn Fn() + Send + Sync>;

/// Read frames from `out` until it ends, applying each to `shared` and calling `repaint` only
/// on a visible change. Stops early once `shared.epoch` moves past `epoch` (a retry). Returns
/// the number of lines read. Never panics on input.
pub fn pump(out: impl Read, shared: &Mutex<Shared>, repaint: &Repaint, epoch: u64) -> u64 {
    let mut r = BufReader::new(out);
    let mut buf = Vec::new();
    let mut n = 0;
    loop {
        buf.clear();
        match r.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => return n,
            Ok(_) => {}
        }
        n += 1;
        // Not UTF-8, not JSON, not a frame we know: skipped as a frame, kept as noise.
        let frame = match std::str::from_utf8(&buf).map(str::trim) {
            Ok("") => continue,
            Ok(line) => Frame::from_line(line).ok(),
            Err(_) => None,
        };
        let changed = {
            let mut g = shared.lock().unwrap_or_else(|e| e.into_inner());
            if g.epoch != epoch {
                return n;
            }
            let Some(frame) = frame else {
                push_tail(&mut g.noise, &buf);
                continue;
            };
            let before = (g.state.greeted, g.state.refused);
            let mut changed = g.state.apply(frame);
            if (g.state.greeted, g.state.refused) != before {
                g.conn = match g.state.refused {
                    Some(p) => Conn::Failed(format!(
                        "The bridge speaks protocol {p}; this app speaks {}. Update both together.",
                        observatory_core::wire::PROTOCOL
                    )),
                    None => Conn::Live,
                };
                changed = true;
            }
            if changed {
                g.generation += 1;
            }
            changed
        };
        if changed {
            repaint();
        }
    }
}

/// A running (or failed) bridge connection.
pub struct LiveSource {
    pub launch: Launch,
    pub shared: Arc<Mutex<Shared>>,
    repaint: Repaint,
    /// The current connection's child. Replaced (not reused) by each start, see `spawn`.
    child: Arc<Mutex<Option<Child>>>,
    seen: u64,
    /// Test hook: a pause between the two steps of [`LiveSource::retry`], to widen any race
    /// between them. Zero in the app.
    #[doc(hidden)]
    pub retry_gap: std::time::Duration,
}

impl LiveSource {
    /// Start the bridge on a background thread and return at once.
    pub fn start(launch: Launch, repaint: Repaint) -> Self {
        let mut s = Self::idle(launch, repaint);
        s.spawn();
        s
    }

    /// A source that starts nothing until [`LiveSource::retry`]; tests feed `shared` directly.
    pub fn idle(launch: Launch, repaint: Repaint) -> Self {
        LiveSource {
            launch,
            shared: Arc::new(Mutex::new(Shared {
                state: LiveState::default(),
                conn: Conn::Connecting,
                generation: 0,
                epoch: 0,
                noise: Vec::new(),
                input: None,
                last_id: 0,
            })),
            repaint,
            child: Arc::new(Mutex::new(None)),
            seen: u64::MAX,
            retry_gap: std::time::Duration::ZERO,
        }
    }

    /// Drop the old connection (if any) and start a fresh one.
    pub fn retry(&mut self) {
        // Stop FIRST: once the epoch has moved, the old reader changes nothing, so the reset
        // below cannot be refilled with the old run's frames or output.
        self.stop();
        thread::sleep(self.retry_gap);
        {
            let mut g = self.shared.lock().unwrap_or_else(|e| e.into_inner());
            g.state = LiveState::default();
            g.conn = Conn::Connecting;
            g.generation += 1;
            g.noise.clear();
        }
        self.spawn();
    }

    /// End the current connection: mark it stale and take its child in ONE critical section
    /// (the shared lock), then kill the child. A reader checks the epoch and stores its child
    /// under the same lock (see `run`), so either the child is already in the slot here, or the
    /// reader sees the stale epoch and kills the child itself. No order to get wrong, no window.
    fn stop(&self) {
        let child = {
            let mut g = self.shared.lock().unwrap_or_else(|e| e.into_inner());
            g.epoch += 1;
            g.input = None;
            self.child.lock().unwrap_or_else(|e| e.into_inner()).take()
        };
        if let Some(mut c) = child {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    fn spawn(&mut self) {
        let launch = self.launch.clone();
        let shared = self.shared.clone();
        let repaint = self.repaint.clone();
        // A fresh slot per connection: an old reader (still draining a pipe a grandchild holds
        // open) can only ever reach its own child, never the one a Retry started.
        self.child = Arc::new(Mutex::new(None));
        let child_slot = self.child.clone();
        let epoch = shared.lock().unwrap_or_else(|e| e.into_inner()).epoch;
        let result = thread::Builder::new()
            .name("bridge-reader".into())
            .spawn(move || run(launch, &shared, &repaint, &child_slot, epoch));
        if let Err(e) = result {
            fail(
                &self.shared,
                &self.repaint,
                epoch,
                format!("Could not start the bridge reader: {e}"),
            );
        }
    }

    /// Write ONE send request to the current connection. Refused (nothing written) unless the
    /// bridge is live and its input is open.
    pub fn send(&self, session_id: &str, text: &str) -> Result<Sent, String> {
        let mut g = self.shared.lock().unwrap_or_else(|e| e.into_inner());
        if g.conn != Conn::Live {
            return Err("Not connected to the bridge.".into());
        }
        let id = g.last_id + 1;
        let epoch = g.epoch;
        let Some(Input(w)) = g.input.as_mut() else {
            return Err("The bridge can't take messages right now.".into());
        };
        let line = Request::Send {
            id,
            session_id: session_id.to_owned(),
            text: text.to_owned(),
        }
        .to_line();
        let ok = w
            .write_all(line.as_bytes())
            .and_then(|_| w.write_all(b"\n"))
            .and_then(|_| w.flush());
        g.last_id = id;
        match ok {
            Ok(()) => Ok(Sent { id, epoch }),
            Err(e) => {
                g.input = None;
                Err(format!("The message could not reach the bridge: {e}"))
            }
        }
    }

    /// The answer to `sent`, taken (a second call says `Waiting` or `Lost`).
    pub fn reply(&self, sent: Sent) -> Reply {
        let mut g = self.shared.lock().unwrap_or_else(|e| e.into_inner());
        if g.epoch != sent.epoch {
            return Reply::Lost;
        }
        match g.state.replies.remove(&sent.id) {
            Some(r) => Reply::Answered(r),
            None if matches!(g.conn, Conn::Failed(_)) => Reply::Lost,
            None => Reply::Waiting,
        }
    }

    /// Test hook: request lines go to `w` (an idle source has no bridge stdin).
    #[doc(hidden)]
    pub fn attach_input(&self, w: impl Write + Send + 'static) {
        self.shared.lock().unwrap_or_else(|e| e.into_inner()).input = Some(Input(Box::new(w)));
    }

    pub fn conn(&self) -> Conn {
        self.shared
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .conn
            .clone()
    }

    /// A new model when the data moved since the last call.
    pub fn take_model(&mut self, seats: &Seats, now: i64, offsets: Offsets) -> Option<ViewModel> {
        let g = self.shared.lock().unwrap_or_else(|e| e.into_inner());
        if g.generation == self.seen {
            return None;
        }
        self.seen = g.generation;
        Some(g.state.view_model(seats, now, offsets))
    }
}

impl Drop for LiveSource {
    fn drop(&mut self) {
        self.stop();
    }
}

fn fail(shared: &Mutex<Shared>, repaint: &Repaint, epoch: u64, why: String) {
    {
        let mut g = shared.lock().unwrap_or_else(|e| e.into_inner());
        if g.epoch != epoch {
            return; // a retry owns the banner now
        }
        g.conn = Conn::Failed(why);
        g.input = None;
        g.generation += 1;
    }
    repaint();
}

/// The reader thread: spawn, pump stdout, then explain why it ended.
fn run(
    launch: Launch,
    shared: &Mutex<Shared>,
    repaint: &Repaint,
    child_slot: &Mutex<Option<Child>>,
    epoch: u64,
) {
    let mut cmd = launch.command();
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return fail(shared, repaint, epoch, spawn_error(&launch, &e)),
    };
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdin = child.stdin.take();
    {
        // Check and store under the shared lock: `stop` bumps the epoch under the same lock
        // before it looks in the slot, so either it finds this child or this reader sees the
        // bump and kills the child here. No window where both miss it.
        let mut g = shared.lock().unwrap_or_else(|e| e.into_inner());
        if g.epoch != epoch {
            drop(g);
            let _ = child.kill();
            let _ = child.wait();
            return;
        }
        g.input = stdin.map(|s| Input(Box::new(s)));
        *child_slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(child);
    }

    // Raw bytes, not lines: wsl.exe writes its own errors in UTF-16.
    let tail = Arc::new(Mutex::new(Vec::<u8>::new()));
    let err_thread = stderr.map(|mut e| {
        let tail = tail.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n @ 1..) = e.read(&mut buf) {
                push_tail(
                    &mut tail.lock().unwrap_or_else(|e| e.into_inner()),
                    &buf[..n],
                );
            }
        })
    });
    if let Some(out) = stdout {
        pump(out, shared, repaint, epoch);
    }
    if let Some(t) = err_thread {
        let _ = t.join();
    }
    // Taken by a retry (which killed it) → None, and `fail` ignores a stale epoch anyway.
    let Some(status) = child_slot
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
        .and_then(|mut c| c.wait().ok())
    else {
        return;
    };
    let noise = shared
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .noise
        .clone();
    let tail = output_tail(&noise, &tail.lock().unwrap_or_else(|e| e.into_inner()));
    fail(
        shared,
        repaint,
        epoch,
        exit_reason(&launch, status.code(), &tail),
    );
}

pub fn spawn_error(launch: &Launch, e: &std::io::Error) -> String {
    match (launch, e.kind()) {
        (Launch::Wsl { .. }, std::io::ErrorKind::NotFound) => {
            "WSL is not available: wsl.exe was not found. Install WSL, then Retry.".into()
        }
        (_, std::io::ErrorKind::NotFound) => format!(
            "The bridge is not installed at {}. Run scripts/deploy.sh, then Retry.",
            launch.describe()
        ),
        _ => format!("Could not start the bridge ({}): {e}", launch.describe()),
    }
}

pub fn exit_reason(launch: &Launch, code: Option<i32>, stderr_tail: &str) -> String {
    let no_distro = matches!(launch, Launch::Wsl { .. }) && {
        let t = stderr_tail.to_lowercase();
        t.contains("no installed distributions") || t.contains("no distribution")
    };
    if no_distro {
        return "WSL has no Linux distribution installed, so the bridge can't start. Install \
                one (wsl --install), deploy the bridge, then Retry."
            .into();
    }
    let head = match code {
        // `sh -c 'exec <missing>'` exits 127 (not found) or 126 (not executable).
        Some(127) | Some(126) if matches!(launch, Launch::Wsl { .. }) => format!(
            "The bridge is not installed at {}. Run scripts/deploy.sh, then Retry.",
            launch.describe()
        ),
        Some(c) => format!("The bridge stopped (exit code {c})."),
        None => "The bridge stopped (killed by a signal).".into(),
    };
    let tail = stderr_tail.trim();
    if tail.is_empty() {
        head
    } else {
        format!("{head}\n{tail}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared(epoch: u64) -> Mutex<Shared> {
        Mutex::new(Shared {
            state: LiveState::default(),
            conn: Conn::Connecting,
            generation: 0,
            epoch,
            noise: Vec::new(),
            input: None,
            last_id: 0,
        })
    }

    #[test]
    fn a_stale_failure_does_not_overwrite_a_retry() {
        let sh = shared(2);
        let rp: Repaint = Arc::new(|| {});
        fail(&sh, &rp, 1, "old connection died".into());
        assert_eq!(sh.lock().unwrap().conn, Conn::Connecting);
        fail(&sh, &rp, 2, "this one died".into());
        assert_eq!(
            sh.lock().unwrap().conn,
            Conn::Failed("this one died".into())
        );
    }

    #[test]
    fn wsl_utf16_stderr_is_decoded_and_no_distro_is_said_plainly() {
        let msg = "Windows Subsystem for Linux has no installed distributions.\r\nUse 'wsl.exe --list --online' to list them.\r\n";
        let utf16: Vec<u8> = msg.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut bom = vec![0xFF, 0xFE];
        bom.extend(&utf16);
        for bytes in [&utf16, &bom] {
            let text = decode_stderr(bytes);
            assert_eq!(
                text,
                "Windows Subsystem for Linux has no installed distributions.\nUse 'wsl.exe --list --online' to list them."
            );
            let why = exit_reason(&Launch::Wsl { path: None }, Some(-1), &text);
            assert!(
                why.starts_with("WSL has no Linux distribution installed"),
                "{why}"
            );
            assert!(!why.contains("exit code"), "{why}");
        }
        // The same text from a direct (non-WSL) bridge is just its stderr.
        let direct = Launch::Direct {
            program: "/b".into(),
            args: vec![],
        };
        assert!(exit_reason(&direct, Some(1), "no distribution").contains("exit code 1"));
        // UTF-8 stays UTF-8, and only the last lines are kept.
        let many: String = (1..=9).map(|i| format!("line {i}\n")).collect();
        assert_eq!(
            decode_stderr(many.as_bytes()),
            "line 4\nline 5\nline 6\nline 7\nline 8\nline 9"
        );
        assert_eq!(decode_stderr("café ✓\n".as_bytes()), "café ✓");
    }

    #[test]
    fn exit_reasons_name_the_cause() {
        let wsl = Launch::Wsl { path: None };
        let direct = Launch::Direct {
            program: "/b".into(),
            args: vec![],
        };
        assert!(exit_reason(&wsl, Some(127), "").contains("not installed"));
        assert!(exit_reason(&wsl, Some(126), "").contains("not installed"));
        assert_eq!(
            exit_reason(&direct, Some(127), ""),
            "The bridge stopped (exit code 127)."
        );
        assert_eq!(
            exit_reason(&direct, None, " oops \n"),
            "The bridge stopped (killed by a signal).\noops"
        );
        let nf = std::io::Error::from(std::io::ErrorKind::NotFound);
        assert!(spawn_error(&wsl, &nf).contains("WSL is not available"));
        assert!(spawn_error(&direct, &nf).contains("not installed at /b"));
    }
}
