//! The real binary over a temp tree: `--once`, live tailing via inotify, and (Linux) the
//! read-only proof on a running process.

mod common;

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant, SystemTime};

use common::*;
use observatory_core::wire::Frame;

const BIN: &str = env!("CARGO_BIN_EXE_observatory-bridge");

/// The hello line the child bridge prints: this protocol, and the distro it inherits.
fn hello() -> String {
    Frame::Hello {
        protocol: observatory_core::wire::PROTOCOL,
        distro: std::env::var("WSL_DISTRO_NAME")
            .ok()
            .filter(|d| !d.is_empty()),
        seats: Vec::new(),
        note: None,
    }
    .to_line()
}

fn write_cfg(c: &Path, coalesce_ms: u64) -> PathBuf {
    let p = c.parent().unwrap().join("bridge.json");
    let cfg = format!(
        r#"{{"projects":[{{"name":"my-app","root":"/home/user/my-app","worktree_roots":["/home/user/my-app-worktrees"]}}],"liveness_secs":1,"coalesce_ms":{coalesce_ms}}}"#
    );
    write(&p, &cfg);
    p
}

fn spawn(c: &Path, extra: &[&str]) -> (Child, Receiver<Frame>) {
    let cfg = write_cfg(c, 50);
    let mut child = Command::new(BIN)
        .arg("--claude-dir")
        .arg(c)
        .arg("--config")
        .arg(&cfg)
        .args(extra)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let out = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for l in BufReader::new(out).lines() {
            let Ok(l) = l else { break };
            if tx.send(Frame::from_line(&l).unwrap()).is_err() {
                break;
            }
        }
    });
    (child, rx)
}

fn next(rx: &Receiver<Frame>, within: Duration) -> Option<Frame> {
    rx.recv_timeout(within).ok()
}

/// Every file under `root`: path → (bytes, mtime).
fn snapshot(root: &Path) -> BTreeMap<PathBuf, (Vec<u8>, SystemTime)> {
    let mut m = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            let md = fs::metadata(&p).unwrap();
            if md.is_dir() {
                m.insert(p.clone(), (Vec::new(), md.modified().unwrap()));
                stack.push(p);
            } else {
                m.insert(p.clone(), (fs::read(&p).unwrap(), md.modified().unwrap()));
            }
        }
    }
    m
}

#[test]
fn once_prints_startup_frames_and_exits() {
    let c = standard_tree("once");
    let cfg = write_cfg(&c, 50);
    let before = snapshot(c.parent().unwrap());
    let out = Command::new(BIN)
        .arg("--once")
        .arg("--claude-dir")
        .arg(&c)
        .arg("--config")
        .arg(&cfg)
        .output()
        .unwrap();
    assert!(out.status.success());
    let ls = lines(&out.stdout);
    assert_eq!(ls[0], hello());
    let n = ls
        .iter()
        .filter(|l| matches!(Frame::from_line(l).unwrap(), Frame::Session { .. }))
        .count();
    assert_eq!((ls.len(), n), (3, 2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("startup 2 sessions, 3 frames"), "{err}");
    assert_eq!(
        before,
        snapshot(c.parent().unwrap()),
        "--once wrote something"
    );
}

#[test]
fn missing_config_means_home_only_and_a_note_not_a_crash() {
    let c = claude_tree("noconfig");
    let home = c.parent().unwrap().to_path_buf();
    let p = c.join("projects");
    // A session launched in the home folder itself, and one in some project nobody configured.
    let home_slug = observatory_core::slugify(&home.to_string_lossy());
    write(&p.join(&home_slug).join("zoo-home.jsonl"), ZOO);
    write(&p.join("-somewhere-my-app").join("zoo-x.jsonl"), ZOO);
    let missing = c.join("does-not-exist.json");
    let out = Command::new(BIN)
        .arg("--once")
        .arg("--claude-dir")
        .arg(&c)
        .arg("--config")
        .arg(&missing)
        .env("HOME", &home)
        .output()
        .unwrap();
    assert!(out.status.success());
    let got: Vec<Frame> = lines(&out.stdout)
        .iter()
        .map(|l| Frame::from_line(l).unwrap())
        .collect();
    let Some(Frame::Hello {
        protocol,
        seats,
        note,
        ..
    }) = got.first()
    else {
        panic!("{got:?}")
    };
    assert_eq!(*protocol, observatory_core::wire::PROTOCOL);
    assert!(seats.is_empty());
    let note = note
        .as_deref()
        .expect("the app is told where the config goes");
    assert!(
        note.contains(&missing.display().to_string()),
        "the note names the path: {note}"
    );
    // Only the home folder's session; no gallery, nothing from the unconfigured project.
    let rest: Vec<(&str, &str)> = got[1..]
        .iter()
        .map(|f| match f {
            Frame::Session { project, session } => {
                (project.as_str(), session.meta.session_id.as_str())
            }
            other => panic!("only the home session is expected: {other:?}"),
        })
        .collect();
    assert_eq!(
        rest,
        [(observatory_bridge::config::HOME_PROJECT, "zoo-home")]
    );
}

#[test]
fn live_tail_picks_up_lines_and_new_files_read_only() {
    let c = standard_tree("live-tail");
    let root = c.parent().unwrap().to_path_buf();
    let (mut child, rx) = spawn(&c, &[]);
    let t = Duration::from_secs(5);
    for _ in 0..3 {
        next(&rx, t).expect("startup frame");
    }

    // A new line in an existing file → a patch.
    let f = c.join("projects").join(OBS_SLUG).join("7a1e5c00.jsonl");
    let line = text_line("live-1", "hi");
    let (a, z) = line.split_at(30);
    append(&f, a);
    assert!(
        next(&rx, Duration::from_millis(600)).is_none(),
        "partial line sent"
    );
    append(&f, z);
    match next(&rx, t).expect("patch for the new line") {
        Frame::Patch {
            session_id, items, ..
        } => {
            assert_eq!(session_id, "7a1e5c00");
            assert_eq!(items.len(), 1);
        }
        other => panic!("{other:?}"),
    }

    // A new session file and a new project dir → full frames.
    write(&c.join("projects").join(OBS_SLUG).join("zoo-9.jsonl"), ZOO);
    let got = next(&rx, t).expect("frame for the new file");
    assert!(
        matches!(&got, Frame::Session { session, .. } if session.meta.session_id == "zoo-9"),
        "{got:?}"
    );
    let nd = c.join("projects").join("-home-user-my-app-worktrees-x");
    fs::create_dir(&nd).unwrap();
    std::thread::sleep(Duration::from_millis(200)); // let the new dir's watch go up
    write(&nd.join("zoo-10.jsonl"), ZOO);
    let mut seen = false;
    let deadline = Instant::now() + t;
    while let Some(fr) = next(&rx, deadline.saturating_duration_since(Instant::now())) {
        if matches!(&fr, Frame::Session { session, .. } if session.meta.session_id == "zoo-10") {
            seen = true;
            break;
        }
    }
    assert!(seen, "session in a new project dir was not picked up");

    // Read-only proof on the running process.
    #[cfg(target_os = "linux")]
    {
        let pid = child.id();
        let mut ro = 0;
        for e in fs::read_dir(format!("/proc/{pid}/fd")).unwrap() {
            let e = e.unwrap();
            let Ok(target) = fs::read_link(e.path()) else {
                continue;
            };
            if !target.starts_with(&root) {
                continue;
            }
            let fdinfo = fs::read_to_string(format!(
                "/proc/{pid}/fdinfo/{}",
                e.file_name().to_string_lossy()
            ))
            .unwrap();
            let flags = fdinfo
                .lines()
                .find_map(|l| l.strip_prefix("flags:"))
                .map(|v| u32::from_str_radix(v.trim(), 8).unwrap())
                .unwrap();
            assert_eq!(
                flags & 0o3,
                0,
                "{} is open with access mode {:o} (not O_RDONLY)",
                target.display(),
                flags & 0o3
            );
            ro += 1;
        }
        assert!(
            ro >= 3,
            "only {ro} fds under the tree: the check is vacuous"
        );
    }
    assert!(
        c.join("sessions").join("99999999.json").exists(),
        "non-vacuity: the snapshot must cover a registry the bridge reads"
    );
    let before = snapshot(&root);
    std::thread::sleep(Duration::from_millis(1500)); // spans a liveness re-check
    let after = snapshot(&root);
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(before, after, "the bridge changed the tree");
}
