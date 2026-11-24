#![allow(dead_code)]
//! Test helpers: temp `.claude` trees under cargo's target tmp dir (never the live logs).

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use observatory_bridge::config::Config;
use observatory_core::lines::LineBuffer;
use observatory_core::{ProjectSpec, Session};

pub const ADA: &str = include_str!("../../../core/tests/fixtures/synthetic_session.jsonl");
pub const ZOO: &str = include_str!("../../../core/tests/fixtures/synthetic_zoo.jsonl");
pub const OBS_SLUG: &str = "-home-user-my-app";
pub const WT_SLUG: &str = "-home-user-my-app-worktrees-v1-3";

static N: AtomicU32 = AtomicU32::new(0);

/// A fresh, empty `<tmp>/<name>-<pid>-<n>/.claude/projects`.
pub fn claude_tree(name: &str) -> PathBuf {
    let base = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "{name}-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = fs::remove_dir_all(&base);
    let claude = base.join(".claude");
    fs::create_dir_all(claude.join("projects")).unwrap();
    claude
}

pub fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

pub fn append(path: &Path, text: &str) {
    let mut f = fs::OpenOptions::new().append(true).open(path).unwrap();
    f.write_all(text.as_bytes()).unwrap();
}

pub fn cfg(coalesce_ms: u64) -> Config {
    Config {
        projects: vec![ProjectSpec {
            name: "my-app".into(),
            root: "/home/user/my-app".into(),
            worktree_roots: vec!["/home/user/my-app-worktrees".into()],
            gallery: vec![],
            exact: false,
        }],
        cutoff_days: 7,
        liveness_secs: 1,
        coalesce_ms,
        seats: Vec::new(),
        note: None,
    }
}

/// The two fixtures in claimed dirs, plus files the bridge must ignore.
pub fn standard_tree(name: &str) -> PathBuf {
    let c = claude_tree(name);
    let p = c.join("projects");
    write(&p.join(OBS_SLUG).join("7a1e5c00.jsonl"), ADA);
    write(&p.join(WT_SLUG).join("zoo-1.jsonl"), ZOO);
    // Ignored: unclaimed slug, subagent log in a subdir, a non-jsonl file.
    write(&p.join("-home-user-other").join("x.jsonl"), ZOO);
    write(
        &p.join(OBS_SLUG).join("7a1e5c00/subagents/agent-1.jsonl"),
        ZOO,
    );
    write(&p.join(OBS_SLUG).join("notes.txt"), "x");
    // A session registry, so the snapshot tests cover the files liveness reads. The pid
    // is far above any pid_max, so it is never live. Synthetic.
    let reg = r#"{"pid":99999999,"sessionId":"7a1e5c00","cwd":"/home/user/my-app","procStart":"1","status":"idle","name":"Ada"}"#;
    write(&c.join("sessions").join("99999999.json"), reg);
    write(&c.join("sessions").join("99999999.abc.key"), reg);
    c
}

pub fn lines(out: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(out)
        .lines()
        .map(str::to_owned)
        .collect()
}

/// Synthetic lines (labelled: not from a real log).
pub fn tool_use_line(uuid: &str, id: &str) -> String {
    format!(
        r#"{{"type":"assistant","uuid":"{uuid}","timestamp":"2026-11-23T20:00:00.000Z","message":{{"id":"m-{uuid}","content":[{{"type":"tool_use","id":"{id}","name":"Bash","input":{{"command":"ls"}}}}]}}}}"#
    ) + "\n"
}

pub fn tool_result_line(uuid: &str, id: &str) -> String {
    format!(
        r#"{{"type":"user","uuid":"{uuid}","timestamp":"2026-11-23T20:00:01.000Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"{id}","content":"a\nb"}}]}}}}"#
    ) + "\n"
}

pub fn text_line(uuid: &str, text: &str) -> String {
    format!(
        r#"{{"type":"assistant","uuid":"{uuid}","timestamp":"2026-11-23T20:00:02.000Z","message":{{"id":"m-{uuid}","content":[{{"type":"text","text":"{text}"}}]}}}}"#
    ) + "\n"
}

/// `text` parsed the way the bridge parses a log: complete lines only, each with its absolute
/// offset, into a session that knows `like`'s log path and `$HOME`.
#[allow(dead_code)]
pub fn parsed_like(like: &Session, text: &str) -> Session {
    let mut d = Session::new(like.meta.slug.clone(), like.meta.session_id.clone());
    d.meta.log_path = like.meta.log_path.clone();
    d.home = std::env::var("HOME").ok();
    let mut b = LineBuffer::new();
    for l in b.push_lines(text.as_bytes()) {
        d.push_line_at(&l.text, l.offset, l.len);
    }
    d
}
