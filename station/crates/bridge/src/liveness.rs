//! Running vs Gone, from process data (the log alone cannot know it).
//!
//! **Sources** (Linux; elsewhere every session stays `Unknown`):
//! 1. Claude Code's session registry `<claude>/sessions/<pid>.json` (`pid`, `sessionId`, `name`,
//!    `cwd`, `procStart`, `status`). An entry counts only while `/proc/<pid>` exists AND its start
//!    time (field 22 of `/proc/<pid>/stat`) equals `procStart`, so a stale file whose pid was
//!    reused is ignored. Only `*.json` is read; the `*.key` files beside them are never opened.
//! 2. Fallback for a `claude` process with no live registry entry: `--name <Name>` from its
//!    command line plus its cwd (`/proc/<pid>/cwd`, the launch dir) → project. The newest
//!    session of thread (project, Name) counts as running.
//!
//! **Rule.** A session is `Running` when source 1 names its id or source 2 picks it; every other
//! session is `Gone`. A registry entry whose `status` is `waiting` makes its session `NeedsYou`
//! instead of `Running`: Claude Code sets it while a question or a dialog is open on screen
//! (`waitingFor`: "input needed", "dialog open"). Its log shows nothing then (the question is
//! written only once answered), so the log alone reads as an unfinished turn.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::fsro;
use observatory_core::{Liveness, ProjectSpec, Session, project_for_slug, slugify};

/// One running Claude Code process, as far as we can tell.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LiveProc {
    pub pid: u32,
    /// From the registry; `None` for a fallback (process-list) entry.
    pub session_id: Option<String>,
    pub name: Option<String>,
    pub cwd: Option<String>,
    /// Registry `status` (`idle`, `busy`, `shell`, `waiting` seen so far).
    pub status: Option<String>,
    /// Registry `tmux` (`<session>:@<window>.%<pane>`) when Claude Code runs in tmux. A hint and
    /// a cross-check only: sends resolve the pane from the process tree ([`crate::tmux`]).
    pub tmux: Option<String>,
    /// Registry `waitingFor` (what the open question or dialog is) while `status` is `waiting`.
    pub waiting_for: Option<String>,
}

impl LiveProc {
    /// A question or dialog is open in this session's terminal: keys typed there answer it.
    pub fn is_waiting(&self) -> bool {
        self.status.as_deref() == Some("waiting")
    }

    /// Why a send must not type into this process now, or `None` when it may.
    pub fn send_refusal(&self) -> Option<String> {
        // ORCA340-674 RED stub: the old rule, only `waiting` refuses (the fix replaces it).
        if !self.is_waiting() {
            return None;
        }
        let what = self
            .waiting_for
            .as_deref()
            .unwrap_or("a question or a dialog");
        Some(format!(
            "This agent is waiting for you in its terminal ({what}). Typing now would answer it, \
             so answer it there first."
        ))
    }
}

#[cfg(target_os = "linux")]
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RegEntry {
    pid: u32,
    session_id: Option<String>,
    name: Option<String>,
    cwd: Option<String>,
    proc_start: Option<String>,
    status: Option<String>,
    tmux: Option<String>,
    waiting_for: Option<String>,
}

/// Registry files to read: `*.json` directly in `dir`. Never a `*.key` (or anything else).
pub fn registry_files(dir: &Path) -> Vec<PathBuf> {
    fsro::list_dir(dir)
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect()
}

/// `--name X` / `--name=X` from a `claude` argv (NUL-separated `/proc/<pid>/cmdline`).
/// `None` when argv[0] is not a `claude` binary.
pub fn claude_name(cmdline: &[u8]) -> Option<Option<String>> {
    let args: Vec<String> = cmdline
        .split(|&b| b == 0)
        .filter(|a| !a.is_empty())
        .map(|a| String::from_utf8_lossy(a).into_owned())
        .collect();
    let argv0 = args.first()?;
    if Path::new(argv0).file_name()? != "claude" {
        return None;
    }
    let mut it = args.iter().skip(1);
    while let Some(a) = it.next() {
        if a == "--name" {
            return Some(it.next().cloned());
        }
        if let Some(v) = a.strip_prefix("--name=") {
            return Some(Some(v.to_owned()));
        }
    }
    Some(None)
}

/// Field 22 (`starttime`) of `/proc/<pid>/stat`. The command name (field 2) may contain spaces
/// and parentheses, so fields are counted after the LAST `)`.
pub fn stat_start_time(stat: &str) -> Option<u64> {
    let rest = &stat[stat.rfind(')')? + 1..];
    // After `)`: field 3 is the first token, so field 22 is token index 19.
    rest.split_whitespace().nth(19)?.parse().ok()
}

/// Field 4 (`ppid`) of `/proc/<pid>/stat`, counted after the last `)` like [`stat_start_time`].
pub fn stat_ppid(stat: &str) -> Option<u32> {
    let rest = &stat[stat.rfind(')')? + 1..];
    rest.split_whitespace().nth(1)?.parse().ok()
}

/// The parent of `pid`, read from `/proc` now (`None` when it is gone or unreadable).
#[cfg(target_os = "linux")]
pub fn parent_of(pid: u32) -> Option<u32> {
    let b = fsro::read_bytes(&Path::new("/proc").join(pid.to_string()).join("stat"))?;
    stat_ppid(&String::from_utf8_lossy(&b))
}

#[cfg(not(target_os = "linux"))]
pub fn parent_of(_pid: u32) -> Option<u32> {
    None
}

/// Live Claude Code processes (registry first, then the process-list fallback).
#[cfg(target_os = "linux")]
pub fn scan(claude_dir: &Path) -> Option<Vec<LiveProc>> {
    let proc_dir = Path::new("/proc");
    let start_of = |pid: u32| {
        fsro::read_bytes(&proc_dir.join(pid.to_string()).join("stat"))
            .and_then(|b| stat_start_time(&String::from_utf8_lossy(&b)))
    };
    let mut out = Vec::new();
    let mut covered = HashSet::new();
    for f in registry_files(&claude_dir.join("sessions")) {
        let Some(e) = fsro::read_text(&f)
            .ok()
            .and_then(|t| serde_json::from_str::<RegEntry>(&t).ok())
        else {
            continue;
        };
        let Some(start) = start_of(e.pid) else {
            continue; // not running
        };
        if e.proc_start.as_deref().and_then(|s| s.parse().ok()) != Some(start) {
            continue; // pid reused by another process
        }
        covered.insert(e.pid);
        out.push(LiveProc {
            pid: e.pid,
            session_id: e.session_id,
            name: e.name,
            cwd: e.cwd,
            status: e.status,
            tmux: e.tmux,
            waiting_for: e.waiting_for,
        });
    }
    for p in fsro::list_dir(proc_dir) {
        let Some(pid) = p.file_name().and_then(|n| n.to_str()?.parse::<u32>().ok()) else {
            continue;
        };
        if covered.contains(&pid) {
            continue;
        }
        let Some(Some(name)) = fsro::read_bytes(&p.join("cmdline")).and_then(|c| claude_name(&c))
        else {
            continue;
        };
        out.push(LiveProc {
            pid,
            session_id: None,
            name: Some(name),
            cwd: fsro::read_link(&p.join("cwd")).map(|c| c.to_string_lossy().into_owned()),
            status: None,
            tmux: None,
            waiting_for: None,
        });
    }
    Some(out)
}

/// Process data is Linux-only; elsewhere liveness stays `Unknown`.
#[cfg(not(target_os = "linux"))]
pub fn scan(_claude_dir: &Path) -> Option<Vec<LiveProc>> {
    None
}

/// Liveness of each session, by session id (see the module rule). `sessions` are
/// (project, session) pairs.
pub fn assign<'a>(
    sessions: impl IntoIterator<Item = (&'a str, &'a Session)>,
    procs: &[LiveProc],
    specs: &[ProjectSpec],
) -> HashMap<String, Liveness> {
    let sessions: Vec<(&str, &Session)> = sessions.into_iter().collect();
    let mut running: HashSet<&str> = procs
        .iter()
        .filter_map(|p| p.session_id.as_deref())
        .collect();
    let waiting: HashSet<&str> = procs
        .iter()
        .filter(|p| p.is_waiting())
        .filter_map(|p| p.session_id.as_deref())
        .collect();
    for p in procs.iter().filter(|p| p.session_id.is_none()) {
        let (Some(name), Some(cwd)) = (&p.name, &p.cwd) else {
            continue;
        };
        let Some(project) = project_for_slug(&slugify(cwd), specs) else {
            continue;
        };
        let newest = sessions
            .iter()
            .filter(|(pr, s)| {
                *pr == project.name && s.meta.agent_name.as_deref() == Some(name.as_str())
            })
            .max_by(|a, b| {
                (a.1.meta.first_activity_ms, &a.1.meta.session_id)
                    .cmp(&(b.1.meta.first_activity_ms, &b.1.meta.session_id))
            });
        if let Some((_, s)) = newest {
            running.insert(&s.meta.session_id);
        }
    }
    sessions
        .iter()
        .map(|(_, s)| {
            let id = s.meta.session_id.clone();
            let l = if waiting.contains(id.as_str()) {
                Liveness::NeedsYou
            } else if running.contains(id.as_str()) {
                Liveness::Running
            } else {
                Liveness::Gone
            };
            (id, l)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stat_field_22_survives_odd_command_names() {
        let mut fields = vec!["S".to_string()];
        fields.extend((4..=21).map(|i| i.to_string()));
        fields.push("777".into()); // field 22
        fields.push("23".into());
        let stat = format!("42 (we ird) name)) {}", fields.join(" "));
        assert_eq!(stat_start_time(&stat), Some(777));
        assert_eq!(stat_ppid(&stat), Some(4), "field 4 is the parent pid");
        assert_eq!(stat_ppid("1 (x) S 99 1 1"), Some(99));
        assert_eq!(stat_ppid("garbage"), None);
    }

    #[test]
    fn claude_name_parsing() {
        assert_eq!(
            claude_name(b"claude\0--name\0Ada\0--model\0opus\0"),
            Some(Some("Ada".into()))
        );
        assert_eq!(
            claude_name(b"/usr/bin/claude\0--name=Lead\0"),
            Some(Some("Lead".into()))
        );
        assert_eq!(claude_name(b"claude\0"), Some(None));
        assert_eq!(claude_name(b"bash\0--name\0X\0"), None);
        assert_eq!(claude_name(b"claude-helper\0--name\0X\0"), None);
    }
}
