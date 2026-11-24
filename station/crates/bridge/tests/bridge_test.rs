//! The bridge's startup and update rules, driven directly (injected process data, output to a
//! Vec) over temp trees with copied fixture lines.

mod common;

use std::cell::RefCell;
use std::fs;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use common::*;
use observatory_bridge::bridge::Bridge;
use observatory_bridge::liveness::LiveProc;
use observatory_core::wire::{self, Frame};
use observatory_core::{Liveness, Session};

type Procs = Rc<RefCell<Vec<LiveProc>>>;

fn bridge(claude: &std::path::Path, procs: &Procs) -> Bridge<Vec<u8>> {
    let p = procs.clone();
    Bridge::new(cfg(0), claude.to_path_buf(), Vec::new())
        .with_scan(move |_| Some(p.borrow().clone()))
}

fn frames(b: Bridge<Vec<u8>>) -> Vec<Frame> {
    lines(&b.into_output())
        .iter()
        .map(|l| Frame::from_line(l).unwrap())
        .collect()
}

fn public(s: &Session) -> impl PartialEq + std::fmt::Debug + '_ {
    (&s.meta, &s.status.activity, &s.items, &s.stats)
}

fn sessions(fs: &[Frame]) -> Vec<(&str, &Session)> {
    fs.iter()
        .filter_map(|f| match f {
            Frame::Session { project, session } => Some((project.as_str(), &**session)),
            _ => None,
        })
        .collect()
}

#[test]
fn startup_sends_hello_then_every_claimed_session_whole() {
    let c = standard_tree("startup");
    let old = c.join("projects").join(OBS_SLUG).join("old.jsonl");
    write(&old, ZOO);
    let month_ago = SystemTime::now() - Duration::from_secs(30 * 86_400);
    fs::File::options()
        .write(true)
        .open(&old)
        .unwrap()
        .set_modified(month_ago)
        .unwrap();

    let procs: Procs = Rc::default();
    let mut b = bridge(&c, &procs);
    b.hello().unwrap();
    b.startup().unwrap();
    let fs = frames(b);
    assert!(
        matches!(&fs[0], Frame::Hello { protocol, distro, seats, note } if *protocol == observatory_core::wire::PROTOCOL
            && seats.is_empty() && note.is_none()
            && *distro == std::env::var("WSL_DISTRO_NAME").ok().filter(|d| !d.is_empty())),
        "{:?}",
        fs[0]
    );
    let ss = sessions(&fs);
    let mut ids: Vec<_> = ss.iter().map(|(_, s)| s.meta.session_id.as_str()).collect();
    ids.sort();
    assert_eq!(
        ids,
        ["7a1e5c00", "zoo-1"],
        "cutoff, subdirs, unclaimed slugs, non-jsonl skipped"
    );
    assert_eq!(fs.len(), 3);
    for (project, s) in &ss {
        assert_eq!(*project, "my-app");
        // Each session names its own log (embedded images are read back from it).
        let dir = if s.meta.session_id == "zoo-1" {
            WT_SLUG
        } else {
            OBS_SLUG
        };
        let log = c
            .join("projects")
            .join(dir)
            .join(format!("{}.jsonl", s.meta.session_id));
        assert_eq!(s.meta.log_path.as_deref(), log.to_str());
        let text = if s.meta.session_id == "zoo-1" {
            ZOO
        } else {
            ADA
        };
        let direct = parsed_like(s, text);
        assert_eq!(public(s), public(&direct), "parsing is core's, unchanged");
        assert_eq!(s.status.liveness, Liveness::Gone, "no process → gone");
    }

    // cutoff 0 = everything, including the month-old file.
    let mut b = bridge(&c, &procs);
    b.cfg.cutoff_days = 0;
    b.startup().unwrap();
    assert_eq!(sessions(&frames(b)).len(), 3);
}

#[test]
fn one_line_sends_one_bounded_patch_and_partial_lines_wait() {
    let c = standard_tree("patch");
    let f = c.join("projects").join(OBS_SLUG).join("7a1e5c00.jsonl");
    let procs: Procs = Rc::default();
    let mut b = bridge(&c, &procs);
    b.startup().unwrap();
    let start = take_keep(&mut b);
    let i = start
        .iter()
        .position(|f| matches!(f, Frame::Session { session, .. } if session.meta.session_id == "7a1e5c00"))
        .unwrap();
    let Frame::Session { session: held, .. } = &start[i] else {
        unreachable!()
    };
    let mut app = (**held).clone();
    let full_bytes = start[i].to_line().len();

    // Half a line: nothing goes out.
    let line = tool_use_line("n1", "toolu_new");
    let (a, z) = line.split_at(40);
    append(&f, a);
    b.on_path(&f).unwrap();
    b.flush().unwrap();
    assert!(take_keep(&mut b).is_empty(), "a partial line must wait");

    // Its newline arrives: one patch with exactly the one new item.
    append(&f, z);
    b.on_path(&f).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    assert_eq!(out.len(), 1);
    let Frame::Patch { items, len, .. } = &out[0] else {
        panic!("{:?}", out[0])
    };
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].index, held.items.len());
    assert_eq!(*len, held.items.len() + 1);
    assert!(
        out[0].to_line().len() * 10 < full_bytes,
        "patch {} bytes vs full session {} bytes",
        out[0].to_line().len(),
        full_bytes
    );
    assert!(wire::apply_patch(&mut app, &out[0]));

    // Three lines in one window (text, then the result that completes the earlier call):
    // ONE patch, carrying the new text and the completed call, nothing else.
    append(&f, &text_line("n2", "hello"));
    b.on_path(&f).unwrap();
    append(&f, &tool_result_line("n3", "toolu_new"));
    b.on_path(&f).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    assert_eq!(out.len(), 1, "coalesced into one frame");
    let Frame::Patch { items, .. } = &out[0] else {
        panic!()
    };
    let idx: Vec<usize> = items.iter().map(|i| i.index).collect();
    assert_eq!(idx, vec![held.items.len(), held.items.len() + 1]);
    assert!(wire::apply_patch(&mut app, &out[0]));

    // The app's copy, built only from frames, equals a fresh parse of the whole file.
    let whole = fs::read_to_string(&f).unwrap();
    let direct = parsed_like(&app, &whole);
    assert_eq!(public(&app), public(&direct));
}

/// Take the frames written so far, keeping the bridge.
fn take_keep(b: &mut Bridge<Vec<u8>>) -> Vec<Frame> {
    b.drain_output()
        .iter()
        .map(|l| Frame::from_line(l).unwrap())
        .collect()
}

#[test]
fn new_files_new_dirs_and_rewrites_send_full_frames() {
    let c = standard_tree("newfiles");
    let p = c.join("projects");
    let procs: Procs = Rc::default();
    let mut b = bridge(&c, &procs);
    b.startup().unwrap();
    take_keep(&mut b);

    let nf = p.join(OBS_SLUG).join("zoo-2.jsonl");
    write(&nf, ZOO);
    b.on_path(&nf).unwrap();
    let nd = p.join("-home-user-my-app-worktrees-new");
    write(&nd.join("zoo-3.jsonl"), ZOO);
    b.on_path(&nd).unwrap();
    // Unclaimed paths do nothing.
    let other = p.join("-home-user-other").join("y.jsonl");
    write(&other, ZOO);
    b.on_path(&other).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    let mut ids: Vec<_> = sessions(&out)
        .iter()
        .map(|(_, s)| s.meta.session_id.clone())
        .collect();
    ids.sort();
    assert_eq!(ids, ["zoo-2", "zoo-3"]);
    assert_eq!(
        out.len(),
        2,
        "no gone frame for a session whose full frame carries it"
    );

    // A file rewritten shorter is re-read from the start and sent whole.
    let z = p.join(WT_SLUG).join("zoo-1.jsonl");
    write(&z, &ZOO[..ZOO.len() / 2]);
    let cut = ZOO[..ZOO.len() / 2].rfind('\n').unwrap() + 1;
    b.on_path(&z).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    let ss = sessions(&out);
    assert_eq!(ss.len(), 1);
    let direct = parsed_like(ss[0].1, &ZOO[..cut]);
    assert_eq!(public(ss[0].1), public(&direct));
}

#[test]
fn liveness_running_gone_and_back() {
    let c = standard_tree("live");
    // A second zoo session by the same agent (Zed), newer by session id on equal times.
    write(&c.join("projects").join(WT_SLUG).join("zoo-2.jsonl"), ZOO);
    let procs: Procs = Rc::new(RefCell::new(vec![
        LiveProc {
            pid: 1,
            session_id: Some("7a1e5c00".into()),
            ..Default::default()
        },
        // Fallback entry: no registry, matched by --name + cwd → the NEWEST Zed session only.
        LiveProc {
            pid: 2,
            name: Some("Zed".into()),
            cwd: Some("/home/user/my-app-worktrees/v1-3".into()),
            ..Default::default()
        },
    ]));
    let mut b = bridge(&c, &procs);
    b.startup().unwrap();
    let out = take_keep(&mut b);
    let live: Vec<(String, Liveness)> = sessions(&out)
        .iter()
        .map(|(_, s)| (s.meta.session_id.clone(), s.status.liveness))
        .collect();
    let get = |id: &str| live.iter().find(|(i, _)| i == id).unwrap().1;
    assert_eq!(get("7a1e5c00"), Liveness::Running);
    assert_eq!(get("zoo-2"), Liveness::Running);
    assert_eq!(
        get("zoo-1"),
        Liveness::Gone,
        "older session of a running agent"
    );

    // Process gone → one `gone` frame, nothing else.
    procs.borrow_mut().remove(0);
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    assert_eq!(
        take_keep(&mut b),
        vec![Frame::Gone {
            session_id: "7a1e5c00".into()
        }]
    );
    // Unchanged → silence.
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    assert!(take_keep(&mut b).is_empty());
    // Back → a header-only patch saying running.
    procs.borrow_mut().push(LiveProc {
        pid: 3,
        session_id: Some("7a1e5c00".into()),
        ..Default::default()
    });
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    assert_eq!(out.len(), 1);
    let Frame::Patch { items, status, .. } = &out[0] else {
        panic!("{:?}", out[0])
    };
    assert!(items.is_empty());
    assert_eq!(status.liveness, Liveness::Running);
}

#[test]
fn no_process_data_leaves_liveness_unknown() {
    let c = standard_tree("unknown");
    let mut b = Bridge::new(cfg(0), c, Vec::new()).with_scan(|_| None);
    b.startup().unwrap();
    for (_, s) in sessions(&take_keep(&mut b)) {
        assert_eq!(s.status.liveness, Liveness::Unknown);
    }
}

#[test]
fn a_file_replaced_by_rename_is_reopened_and_sent_whole() {
    let c = standard_tree("replaced");
    let z = c.join("projects").join(WT_SLUG).join("zoo-1.jsonl");
    let procs: Procs = Rc::default();
    let mut b = bridge(&c, &procs);
    b.startup().unwrap();
    take_keep(&mut b);
    // A LONGER file renamed over the old one: a size check alone would see nothing to read.
    let new_text = text_line("r1", "replaced") + ZOO;
    let tmp = z.with_extension("tmp");
    write(&tmp, &new_text);
    fs::rename(&tmp, &z).unwrap();
    b.on_path(&z).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    let ss = sessions(&out);
    assert_eq!(ss.len(), 1, "{out:?}");
    let direct = parsed_like(ss[0].1, &new_text);
    assert_eq!(public(ss[0].1), public(&direct));
}

/// With the default projects, a session launched in the home folder itself is sent under
/// the `~ (home)` project; an unconfigured `~/x` dir is still left out. Fixture: synthetic.
#[test]
fn default_projects_send_home_folder_sessions_as_their_own_project() {
    const HOME: &str = include_str!("../../core/tests/fixtures/synthetic_home.jsonl");
    let c = claude_tree("home");
    let p = c.join("projects");
    write(&p.join("-home-user").join("home-1.jsonl"), HOME);
    write(&p.join("-home-user-notes-app").join("x.jsonl"), ZOO);
    write(&p.join(OBS_SLUG).join("7a1e5c00.jsonl"), ADA);
    let cfg = observatory_bridge::config::Config::defaults("/home/user");
    let mut b = Bridge::new(cfg, c.clone(), Vec::new()).with_scan(|_| Some(Vec::<LiveProc>::new()));
    b.startup().unwrap();
    let fs = frames(b);
    let mut got: Vec<(&str, &str)> = sessions(&fs)
        .into_iter()
        .map(|(p, s)| (p, s.meta.session_id.as_str()))
        .collect();
    got.sort();
    // No config: only the home folder's own sessions; nothing else is claimed.
    assert_eq!(got, [(observatory_bridge::config::HOME_PROJECT, "home-1")]);
    let home = sessions(&fs)
        .into_iter()
        .find(|(_, s)| s.meta.session_id == "home-1")
        .unwrap()
        .1;
    assert_eq!(home.pages.len(), 1);
    assert_eq!(home.pages[0].versions, 2);
}

#[test]
fn tmux_hint_follows_the_registry_and_goes_out_as_a_header_patch() {
    let c = standard_tree("tmux-hint");
    let procs: Procs = Rc::new(RefCell::new(vec![LiveProc {
        pid: 1,
        session_id: Some("7a1e5c00".into()),
        ..Default::default()
    }]));
    let mut b = bridge(&c, &procs);
    b.startup().unwrap();
    let out = take_keep(&mut b);
    let s = sessions(&out);
    let held = s
        .iter()
        .find(|(_, s)| s.meta.session_id == "7a1e5c00")
        .unwrap();
    assert!(!held.1.status.tmux, "not in tmux yet");
    // Now the registry says it runs in tmux → one header-only patch with the hint.
    procs.borrow_mut()[0].tmux = Some("s:@1.%1".into());
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    let out = take_keep(&mut b);
    assert_eq!(out.len(), 1, "{out:?}");
    let Frame::Patch { items, status, .. } = &out[0] else {
        panic!("{:?}", out[0])
    };
    assert!(items.is_empty());
    assert!(status.tmux && status.liveness == Liveness::Running);
    // Unchanged → silence; gone → the hint is dropped with it.
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    assert!(take_keep(&mut b).is_empty());
    procs.borrow_mut().clear();
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    assert_eq!(
        take_keep(&mut b),
        vec![Frame::Gone {
            session_id: "7a1e5c00".into()
        }]
    );
}

#[test]
fn an_open_question_makes_the_session_needs_you_and_back() {
    // Claude Code sets registry status `waiting` while a question or dialog is open; the log
    // shows nothing then, so only the registry can tell.
    let c = standard_tree("needs-you");
    let procs: Procs = Rc::new(RefCell::new(vec![LiveProc {
        pid: 1,
        session_id: Some("7a1e5c00".into()),
        status: Some("busy".into()),
        ..Default::default()
    }]));
    let mut b = bridge(&c, &procs);
    b.startup().unwrap();
    let out = take_keep(&mut b);
    let s = sessions(&out);
    let held = s
        .iter()
        .find(|(_, s)| s.meta.session_id == "7a1e5c00")
        .unwrap();
    assert_eq!(held.1.status.liveness, Liveness::Running, "busy is running");
    let mut status_now = |st: &str| {
        procs.borrow_mut()[0].status = Some(st.into());
        procs.borrow_mut()[0].waiting_for = (st == "waiting").then(|| "input needed".into());
        b.refresh_liveness(true).unwrap();
        b.flush().unwrap();
        let out = take_keep(&mut b);
        assert_eq!(out.len(), 1, "{st}: {out:?}");
        let Frame::Patch { items, status, .. } = &out[0] else {
            panic!("{:?}", out[0])
        };
        assert!(items.is_empty());
        status.liveness
    };
    assert_eq!(status_now("waiting"), Liveness::NeedsYou);
    assert_eq!(status_now("idle"), Liveness::Running);
}

#[test]
fn hello_carries_the_configs_seats_and_note() {
    let c = standard_tree("hello-cfg");
    let procs: Procs = Rc::default();
    let mut cfg = cfg(0);
    cfg.seats = vec!["Lead".into(), "Orca".into()];
    cfg.note = Some("No projects configured: write /x/bridge.json".into());
    let mut b = Bridge::new(cfg, c.clone(), Vec::new()).with_scan({
        let p = procs.clone();
        move |_| Some(p.borrow().clone())
    });
    b.hello().unwrap();
    let fs = frames(b);
    let Frame::Hello { seats, note, .. } = &fs[0] else {
        panic!("{:?}", fs[0])
    };
    assert_eq!(seats, &["Lead", "Orca"]);
    assert_eq!(
        note.as_deref(),
        Some("No projects configured: write /x/bridge.json")
    );
}
