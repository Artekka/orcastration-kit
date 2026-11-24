//! Typing to an agent: the bridge's ONLY side effect besides writing stdout.
//!
//! **Resolution** ([`resolve`]), done afresh for every send, never cached:
//! 1. The session's live process: registry entries ([`crate::liveness::scan`], already checked
//!    against `/proc/<pid>` start times) whose `sessionId` is the one asked for. Exactly one,
//!    else refused.
//! 2. Its pane: every tmux pane whose shell pid is on that process's ancestor chain (the pid
//!    itself, its parent, … up to pid 1). Exactly one, else refused.
//! 3. That pane may hold no OTHER live Claude Code process (a second agent in the same pane).
//! 4. When the registry names a pane (`tmux` field) it must be the same pane.
//!
//! Never by agent name, window name or index: names repeat across stale sessions and projects.
//!
//! **Delivery**, step by step so the bridge can re-check between steps ([`Terminal`]):
//! `load-buffer` (text on stdin, a uniquely named buffer), `paste-buffer -p -r -d` into the pane
//! id (bracketed paste, line feeds kept as they are, the buffer deleted), then ONE
//! `send-keys Enter`. The bridge re-resolves the pane right before the paste and right before
//! the Enter (see `Bridge::on_request_line`). The text never passes through a shell or through
//! `send-keys`, so nothing in it is a key name or an expansion. Only the subcommands in
//! [`SUBCOMMANDS`] are ever run (`tests/read_only.rs` checks this file's literals).

use std::collections::BTreeSet;
use std::io::Write;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::liveness::LiveProc;

/// The program run, and the only one.
const TMUX_BIN: &str = "tmux";
/// Every tmux subcommand this module runs.
pub const SUBCOMMANDS: &[&str] = &[
    "list-panes",
    "load-buffer",
    "paste-buffer",
    "delete-buffer",
    "send-keys",
];
/// Ancestor walk limit (a loop in bad data can never spin).
const MAX_DEPTH: usize = 64;

/// One tmux pane: its id (`%3`) and the pid of the process it started.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pane {
    pub id: String,
    pub pid: u32,
}

/// The pane to type into, and why it is that one (for the bridge's stderr log).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub pane: String,
    pub pid: u32,
}

/// Panes whose process is `pid` or one of its ancestors.
fn panes_of(pid: u32, panes: &[Pane], parent: &dyn Fn(u32) -> Option<u32>) -> BTreeSet<String> {
    let mut chain = Vec::new();
    let mut p = Some(pid);
    while let Some(q) = p {
        if q <= 1 || chain.len() >= MAX_DEPTH || chain.contains(&q) {
            break;
        }
        chain.push(q);
        p = parent(q);
    }
    panes
        .iter()
        .filter(|pane| chain.contains(&pane.pid))
        .map(|pane| pane.id.clone())
        .collect()
}

/// The pane id in a registry `tmux` value (`replay-viewer:@3.%3` → `%3`).
fn registry_pane(v: &str) -> Option<&str> {
    let i = v.rfind('%')?;
    Some(&v[i..])
}

/// Find the one pane to type into for live session `session_id` (see the module rules).
/// `procs` and `panes` must be read at the moment of the send; `parent` reads `/proc` now.
pub fn resolve(
    session_id: &str,
    procs: &[LiveProc],
    panes: &[Pane],
    parent: &dyn Fn(u32) -> Option<u32>,
) -> Result<Target, String> {
    let mine: Vec<&LiveProc> = procs
        .iter()
        .filter(|p| p.session_id.as_deref() == Some(session_id))
        .collect();
    let me = match mine.as_slice() {
        [] => return Err("This agent has no live session right now.".into()),
        [one] => *one,
        _ => {
            return Err(format!(
                "{} live processes claim this session, so the right one is unclear.",
                mine.len()
            ));
        }
    };
    if me.is_waiting() {
        let what = me
            .waiting_for
            .as_deref()
            .unwrap_or("a question or a dialog");
        return Err(format!(
            "This agent is waiting for you in its terminal ({what}). Typing now would answer it, \
             so answer it there first."
        ));
    }
    let found = panes_of(me.pid, panes, parent);
    let pane = match found.len() {
        0 => return Err("This agent isn't running in a tmux pane.".into()),
        1 => found.into_iter().next().expect("one pane"),
        n => {
            return Err(format!(
                "This agent's process sits under {n} tmux panes, so the right one is unclear."
            ));
        }
    };
    if let Some(other) = procs
        .iter()
        .filter(|p| p.pid != me.pid)
        .find(|p| panes_of(p.pid, panes, parent).contains(&pane))
    {
        let who = other
            .name
            .as_deref()
            .unwrap_or("another Claude Code process");
        return Err(format!(
            "Pane {pane} also holds {who}, so the message could reach the wrong agent."
        ));
    }
    if let Some(reg) = me.tmux.as_deref()
        && registry_pane(reg) != Some(pane.as_str())
    {
        return Err(format!(
            "Claude Code says this agent is in {reg}, but its process is in pane {pane}."
        ));
    }
    Ok(Target { pane, pid: me.pid })
}

/// The terminal side of a send; replaceable in tests.
pub trait Terminal {
    /// Every pane of the tmux server, read now.
    fn panes(&mut self) -> Result<Vec<Pane>, String>;
    /// Put `text` in the named paste buffer (nothing is typed yet).
    fn load(&mut self, buffer: &str, text: &str) -> Result<(), String>;
    /// Remove the named buffer (after a refusal before the paste).
    fn discard(&mut self, buffer: &str);
    /// Paste the buffer into `pane` as one bracketed paste, deleting the buffer.
    fn paste(&mut self, pane: &str, buffer: &str) -> Result<(), String>;
    /// Press Enter once in `pane`.
    fn enter(&mut self, pane: &str) -> Result<(), String>;
    /// Pause between the paste and the Enter, so the app has taken the whole paste first.
    fn settle(&self) -> Duration {
        Duration::ZERO
    }
}

/// The real tmux. `socket` (`-L <name>`) is for tests only: they run their own server.
#[derive(Debug, Clone)]
pub struct Tmux {
    pub socket: Option<String>,
    /// Pause between the paste and the Enter, so the app has taken the whole paste first.
    pub enter_delay: Duration,
}

impl Default for Tmux {
    fn default() -> Self {
        Tmux {
            socket: None,
            enter_delay: Duration::from_millis(150),
        }
    }
}

impl Tmux {
    fn cmd(&self, sub: &str) -> Command {
        debug_assert!(SUBCOMMANDS.contains(&sub), "{sub}");
        let mut c = Command::new(TMUX_BIN);
        if let Some(s) = &self.socket {
            c.args(["-L", s]);
        }
        c.arg(sub)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        c
    }

    fn run(mut c: Command, input: Option<&[u8]>) -> Result<String, String> {
        if input.is_some() {
            c.stdin(Stdio::piped());
        }
        let mut child = c
            .spawn()
            .map_err(|e| format!("tmux could not start: {e}"))?;
        if let Some(bytes) = input {
            let mut stdin = child.stdin.take().expect("piped above");
            stdin
                .write_all(bytes)
                .map_err(|e| format!("tmux did not take the text: {e}"))?;
        }
        let out = child
            .wait_with_output()
            .map_err(|e| format!("tmux did not finish: {e}"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            let err = String::from_utf8_lossy(&out.stderr);
            Err(format!("tmux refused: {}", err.trim()))
        }
    }
}

/// `list-panes -a -F '#{pane_id} #{pane_pid}'` output → panes (bad lines skipped).
pub fn parse_panes(out: &str) -> Vec<Pane> {
    out.lines()
        .filter_map(|l| {
            let (id, pid) = l.trim().split_once(' ')?;
            if !id.starts_with('%') {
                return None;
            }
            Some(Pane {
                id: id.to_owned(),
                pid: pid.parse().ok()?,
            })
        })
        .collect()
}

impl Terminal for Tmux {
    fn panes(&mut self) -> Result<Vec<Pane>, String> {
        let mut c = self.cmd("list-panes");
        c.args(["-a", "-F", "#{pane_id} #{pane_pid}"]);
        match Self::run(c, None) {
            Ok(out) => Ok(parse_panes(&out)),
            // No tmux server at all: there are simply no panes.
            Err(e) if e.contains("no server running") || e.contains("error connecting") => {
                Ok(Vec::new())
            }
            Err(e) => Err(e),
        }
    }

    fn load(&mut self, buffer: &str, text: &str) -> Result<(), String> {
        let mut load = self.cmd("load-buffer");
        load.args(["-b", buffer, "-"]);
        Self::run(load, Some(text.as_bytes())).map(|_| ())
    }

    fn discard(&mut self, buffer: &str) {
        let mut del = self.cmd("delete-buffer");
        del.args(["-b", buffer]);
        let _ = Self::run(del, None);
    }

    fn paste(&mut self, pane: &str, buffer: &str) -> Result<(), String> {
        let mut paste = self.cmd("paste-buffer");
        paste.args(["-p", "-r", "-d", "-b", buffer, "-t", pane]);
        let r = Self::run(paste, None).map(|_| ());
        if r.is_err() {
            self.discard(buffer);
        }
        r
    }

    fn enter(&mut self, pane: &str) -> Result<(), String> {
        let mut enter = self.cmd("send-keys");
        enter.args(["-t", pane, "Enter"]);
        Self::run(enter, None).map(|_| ())
    }

    fn settle(&self) -> Duration {
        self.enter_delay
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_pane_ids() {
        assert_eq!(registry_pane("replay-viewer:@3.%3"), Some("%3"));
        assert_eq!(registry_pane("x:@10.%12"), Some("%12"));
        assert_eq!(registry_pane("nopane"), None);
    }

    #[test]
    fn pane_list_parsing() {
        let p = parse_panes("%0 100\n%12 2345\n\nbad line\n%x\n@1 5\n%3 notanumber\n");
        assert_eq!(
            p,
            vec![
                Pane {
                    id: "%0".into(),
                    pid: 100
                },
                Pane {
                    id: "%12".into(),
                    pid: 2345
                }
            ]
        );
    }
}
