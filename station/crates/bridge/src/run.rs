//! The live loop: inotify (via `notify`) wakes it for log changes; otherwise it sleeps until the
//! next coalesce deadline or liveness check. No polling of the log files. Galleries are scanned
//! on their own thread ([`crate::gallery`]) and arrive here as finished frames, so this loop
//! stays the only writer of stdout and a slow folder never delays the chat. Stdin lines (the
//! app's requests) are read on their own thread and handled here, one at a time.

use std::io::{self, BufRead, Read, Write};
use std::path::Path;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use notify::{EventKind, RecursiveMode, Watcher};

use crate::bridge::Bridge;
use crate::discover;
use crate::gallery::{self, Scanner};

/// What wakes the loop: a filesystem event for the logs, a changed gallery, or a request line.
enum Msg {
    Fs(notify::Result<notify::Event>),
    Gallery(observatory_core::wire::Frame),
    Request(String),
}

/// A stdin line longer than this is dropped unread (a send's text is far smaller).
const REQUEST_LINE_MAX: usize = 4 * observatory_core::wire::SEND_MAX_BYTES + 1024;

/// Read request lines from stdin until it closes; each complete line becomes one message.
fn spawn_stdin(tx: mpsc::Sender<Msg>) {
    let _ = std::thread::Builder::new()
        .name("requests".into())
        .spawn(move || {
            let mut r = io::stdin().lock();
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match r
                    .by_ref()
                    .take(REQUEST_LINE_MAX as u64 + 1)
                    .read_until(b'\n', &mut buf)
                {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {}
                }
                if buf.last() != Some(&b'\n') {
                    if buf.len() > REQUEST_LINE_MAX {
                        eprintln!("observatory-bridge: ignored an over-long request line");
                        // Skip the rest of that line.
                        let mut rest = Vec::new();
                        if r.read_until(b'\n', &mut rest).is_err() {
                            return;
                        }
                        continue;
                    }
                    return; // stdin closed mid-line: a partial request is never acted on
                }
                let line = String::from_utf8_lossy(&buf).into_owned();
                if tx.send(Msg::Request(line)).is_err() {
                    return;
                }
            }
        });
}

/// True when the error means the reader (the app) went away: exit quietly.
pub fn is_closed(e: &io::Error) -> bool {
    e.kind() == io::ErrorKind::BrokenPipe
}

/// Set up watches, send startup frames, then follow changes until stdout closes.
pub fn run<W: Write>(bridge: &mut Bridge<W>, once: bool) -> io::Result<()> {
    bridge.hello()?;
    let (tx, rx) = mpsc::channel();
    // Watches go up BEFORE the startup read, so nothing appended in between is missed (reads
    // continue from each file's offset, so a duplicate event is harmless).
    let mut watcher = if once {
        None
    } else {
        let fs_tx = tx.clone();
        let mut w = notify::recommended_watcher(move |r| {
            let _ = fs_tx.send(Msg::Fs(r));
        })
        .map_err(io::Error::other)?;
        let pd = bridge.projects_dir();
        if let Err(e) = w.watch(&pd, RecursiveMode::NonRecursive) {
            eprintln!(
                "observatory-bridge: cannot watch {}: {e} (new project dirs will not be seen)",
                pd.display()
            );
        }
        for d in discover::claimed_dirs(&pd, bridge.specs()) {
            if let Err(e) = w.watch(&d, RecursiveMode::NonRecursive) {
                eprintln!("observatory-bridge: cannot watch {}: {e}", d.display());
            }
        }
        Some(w)
    };
    let t0 = Instant::now();
    bridge.startup()?;
    eprintln!(
        "observatory-bridge: startup {} sessions, {} frames, {} bytes, {} ms",
        bridge.session_count(),
        bridge.volume.frames,
        bridge.volume.bytes,
        t0.elapsed().as_millis()
    );
    let mut scanner = Scanner::new(bridge.specs());
    let Some(w) = watcher.as_mut() else {
        // `--once`: one scan, inline.
        for f in scanner.pass() {
            bridge.send(&f)?;
        }
        return Ok(());
    };
    spawn_stdin(tx.clone());
    if !scanner.is_empty() {
        gallery::spawn(scanner, gallery::SCAN_EVERY, tx, Msg::Gallery);
    } else {
        drop(tx);
    }
    let live_every = Duration::from_secs(bridge.cfg.liveness_secs);
    let mut next_live = Instant::now() + live_every;
    let pd = bridge.projects_dir();
    loop {
        let now = Instant::now();
        let wake = bridge.flush_due().map_or(next_live, |d| d.min(next_live));
        match rx.recv_timeout(wake.saturating_duration_since(now)) {
            Ok(Msg::Gallery(f)) => bridge.send(&f)?,
            Ok(Msg::Request(line)) => bridge.on_request_line(&line)?,
            Ok(Msg::Fs(Ok(ev))) => {
                if matches!(ev.kind, EventKind::Access(_)) {
                    continue; // our own reads
                }
                for p in &ev.paths {
                    if matches!(ev.kind, EventKind::Create(_))
                        && discover::project_of_dir(p, &pd, bridge.specs()).is_some()
                    {
                        let _ = w.watch(Path::new(p), RecursiveMode::NonRecursive);
                    }
                    bridge.on_path(p)?;
                }
            }
            Ok(Msg::Fs(Err(e))) => eprintln!("observatory-bridge: watch error: {e}"),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
        }
        let now = Instant::now();
        if bridge.flush_due().is_some_and(|d| d <= now) {
            bridge.flush()?;
        }
        if next_live <= now {
            bridge.refresh_liveness(true)?;
            next_live = now + live_every;
        }
    }
}
