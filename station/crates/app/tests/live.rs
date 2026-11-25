//! Live feed: synthetic wire frames → view-model, repaint rule, bridge failures, and a snapshot of
//! a live-mapped window. No test reads `~/.claude`: every session here is built in code.

use std::io::Cursor;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use egui::{Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use observatory_app::bridge::{Conn, Launch, LiveSource, Repaint, Shared, pump};
use observatory_app::live::{LiveState, Seats, utc_offset};
use observatory_app::model::{ChatItem, Image, ImageSrc, Role, Status};
use observatory_app::{Clock, ObservatoryApp};
use observatory_core::session::{ImageRef, SessionMeta, ToolCall, ToolResult};
use observatory_core::wire::PROTOCOL;
use observatory_core::{Activity, Frame, ItemKind, Liveness, NoticeKind, Session};

/// 2026-11-23 18:00:00 UTC.
const NOW: i64 = 1_795_456_800;
const MIN: i64 = 60_000;

fn item(ts_min_ago: i64, kind: ItemKind) -> observatory_core::ChatItem {
    observatory_core::ChatItem {
        uuid: None,
        timestamp_ms: Some(NOW * 1000 - ts_min_ago * MIN),
        kind,
    }
}

fn session(id: &str, agent: Option<&str>, first_min_ago: i64, last_min_ago: i64) -> Session {
    let mut s = Session::new("-home-u-proj", id);
    s.meta = SessionMeta {
        session_id: id.into(),
        slug: "-home-u-proj".into(),
        agent_name: agent.map(str::to_owned),
        model: Some("claude-opus-5-5".into()),
        permission_mode: Some("auto".into()),
        first_activity_ms: Some(NOW * 1000 - first_min_ago * MIN),
        last_activity_ms: Some(NOW * 1000 - last_min_ago * MIN),
        ..Default::default()
    };
    s.status.liveness = Liveness::Running;
    s
}

fn full(project: &str, s: &Session) -> String {
    Frame::Session {
        project: project.into(),
        session: Box::new(s.clone()),
    }
    .to_line()
}

fn hello() -> String {
    // A configured bridge: its seat list comes in hello (the app's own Seats::default defers to it).
    Frame::Hello {
        protocol: PROTOCOL,
        distro: Some("Ubuntu".into()),
        note: None,
        seats: vec!["Lead".into()],
    }
    .to_line()
}

/// Lead: an old session (gone) and a newer one mid-turn → one thread with a restart divider.
/// Ada: idle, every item kind. Bo: needs you. A nameless session in a second project.
fn scenario() -> (Vec<Session>, Vec<String>) {
    let mut lead_old = session("lead-old", Some("Lead"), 300, 200);
    lead_old.items.push(item(
        300,
        ItemKind::UserText {
            text: "take the seat".into(),
            images: vec![],
        },
    ));
    lead_old.status.liveness = Liveness::Gone;

    let mut lead = session("lead-new", Some("Lead"), 168, 1); // 15:12Z
    lead.items.push(item(
        168,
        ItemKind::SlashCommand {
            name: "/orcastration-kit:orchestrate".into(),
            args: String::new(),
        },
    ));
    lead.items.push(item(
        2,
        ItemKind::AssistantText {
            message_id: None,
            text: "## Plan\n\n- **Parser** goes to Bo".into(),
        },
    ));
    lead.status.activity = Activity::Working;
    lead.status.working_since_ms = Some(NOW * 1000 - 45_000);

    let mut ada = session("ada", Some("Ada"), 60, 14);
    ada.meta.log_path = Some("/home/user/.claude/projects/-obs/ada.jsonl".into());
    ada.items.extend([
        item(
            60,
            ItemKind::UserText {
                text: "see the screenshot".into(),
                images: vec![
                    ImageRef::Embedded {
                        line_offset: Some(4096),
                        line_len: 700,
                        block: 1,
                        part: None,
                        media_type: Some("image/png".into()),
                        path: None,
                    },
                    ImageRef::File {
                        path: "/home/user/shots/b.jpg".into(),
                    },
                ],
            },
        ),
        item(
            59,
            ItemKind::AgentMessage {
                from: "Lead".into(),
                body: "The parser row is yours".into(),
                task_id: None,
            },
        ),
        item(
            58,
            ItemKind::AgentMessage {
                from: "subagent".into(),
                body: "found 3 files".into(),
                task_id: Some("a7c3e9f1b5d2486ce".into()),
            },
        ),
        item(
            57,
            ItemKind::Thinking {
                message_id: None,
                text: "inotify or notify crate".into(),
            },
        ),
        item(
            56,
            ItemKind::ToolCall(ToolCall {
                id: "t1".into(),
                name: "Bash".into(),
                message_id: None,
                summary: "Ran cargo test".into(),
                input: "{\"command\":\"cargo test\"}".into(),
                input_truncated: false,
                result: Some(ToolResult {
                    text: "1 failed".into(),
                    truncated: true,
                    is_error: true,
                }),
                images: vec![],
            }),
        ),
        item(
            55,
            ItemKind::Notice {
                notice: NoticeKind::Compacted,
                summary: "Conversation compacted".into(),
                body: String::new(),
            },
        ),
        item(
            54,
            ItemKind::Notice {
                notice: NoticeKind::CommandOutput,
                summary: "ok".into(),
                body: "ok\nall good".into(),
            },
        ),
    ]);

    let mut bo = session("bo", Some("Bo"), 30, 3);
    bo.status.liveness = Liveness::NeedsYou;
    bo.status.activity = Activity::Working;
    bo.status.working_since_ms = Some(NOW * 1000 - 3 * MIN);

    let mut anon = session("5be0d1c4-1111", None, 20, 20);
    anon.status.liveness = Liveness::Unknown;

    let lines = vec![
        hello(),
        full("my-app", &lead_old),
        full("my-app", &lead),
        full("my-app", &ada),
        full("my-app", &bo),
        full("other-project", &anon),
    ];
    (vec![lead_old, lead, ada, bo, anon], lines)
}

fn counter() -> (Repaint, Arc<AtomicUsize>) {
    let n = Arc::new(AtomicUsize::new(0));
    let m = n.clone();
    (
        Arc::new(move || {
            m.fetch_add(1, Ordering::SeqCst);
        }),
        n,
    )
}

fn shared() -> Mutex<Shared> {
    Mutex::new(Shared {
        state: LiveState::default(),
        conn: Conn::Connecting,
        generation: 0,
        epoch: 0,
        noise: Vec::new(),
        input: None,
        last_id: 0,
    })
}

fn feed(lines: &[String]) -> (Mutex<Shared>, usize) {
    let sh = shared();
    let (rp, n) = counter();
    pump(Cursor::new(lines.join("\n") + "\n"), &sh, &rp, 0);
    let count = n.load(Ordering::SeqCst);
    (sh, count)
}

// ------------------------------------------------------------------ frame stream → model

#[test]
fn frame_stream_maps_to_the_expected_view_model() {
    let (_, lines) = scenario();
    let (sh, _) = feed(&lines);
    let g = sh.lock().unwrap();
    assert_eq!(g.conn, Conn::Live);
    let vm = g.state.view_model(&Seats::default(), NOW, utc_offset);

    let names: Vec<_> = vm.projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["my-app", "other-project"]);
    let obs = &vm.projects[0];
    let agents: Vec<_> = obs.agents.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(agents, ["Ada", "Bo", "Lead"], "one thread per agent name");

    let lead = &obs.agents[2];
    assert_eq!(lead.role, Role::Seat);
    assert_eq!(lead.status, Status::Working, "newest session decides");
    assert_eq!(lead.turn_started, Some(NOW - 45));
    assert_eq!(lead.last_activity, Some(NOW - 60));
    assert_eq!(lead.model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(lead.permission_mode.as_deref(), Some("auto"));
    assert_eq!(
        lead.items,
        vec![
            ChatItem::User {
                text: "take the seat".into(),
                images: vec![]
            },
            ChatItem::Restart {
                at_label: "15:12".into()
            },
            ChatItem::User {
                text: "/orcastration-kit:orchestrate".into(),
                images: vec![]
            },
            ChatItem::Assistant {
                markdown: "## Plan\n\n- **Parser** goes to Bo".into()
            },
        ]
    );

    let ada = &obs.agents[0];
    assert_eq!((ada.role, ada.status), (Role::Sibling, Status::Idle));
    assert_eq!(ada.turn_started, None);
    assert_eq!(
        ada.items,
        vec![
            ChatItem::User {
                text: "see the screenshot".into(),
                // On this (Linux) host WSL paths are opened as they are; the log comes from the
                // session's own meta.
                images: vec![
                    Image {
                        src: ImageSrc::Embedded {
                            log: "/home/user/.claude/projects/-obs/ada.jsonl".into(),
                            offset: 4096,
                            len: 700,
                            block: 1,
                            part: None,
                        },
                        name: "pasted image".into(),
                        path: None,
                        hide_if_missing: false,
                    },
                    Image {
                        src: ImageSrc::File("/home/user/shots/b.jpg".into()),
                        name: "b.jpg".into(),
                        path: Some("/home/user/shots/b.jpg".into()),
                        hide_if_missing: false,
                    },
                ]
            },
            ChatItem::AgentMessage {
                from: "Lead".into(),
                body: "The parser row is yours".into()
            },
            ChatItem::AgentMessage {
                from: "subagent a7c3e9f1b5d2486ce".into(),
                body: "found 3 files".into()
            },
            ChatItem::Thinking {
                text: "inotify or notify crate".into()
            },
            ChatItem::ToolCall {
                summary: "Ran cargo test".into(),
                input: "{\"command\":\"cargo test\"}".into(),
                output: Some("1 failed\n… (cut)".into()),
                is_error: true,
                images: vec![],
            },
            ChatItem::Notice {
                summary: "Conversation compacted".into(),
                body: String::new()
            },
            ChatItem::Notice {
                summary: "ok".into(),
                body: "ok\nall good".into()
            },
        ]
    );

    let bo = &obs.agents[1];
    assert_eq!(bo.status, Status::NeedsYou);
    assert_eq!(
        bo.turn_started, None,
        "the counter shows only while working"
    );

    let anon = &vm.projects[1].agents[0];
    assert_eq!(anon.name, "session 5be0d1c4");
    assert_eq!(anon.status, Status::Idle);
}

#[test]
fn gone_dims_and_patch_updates_in_place() {
    let (sessions, mut lines) = scenario();
    let mut ada = sessions[2].clone();
    // A patch: item 0 rewritten, one appended, then cut to len.
    ada.items[0].kind = ItemKind::UserText {
        text: "edited".into(),
        images: vec![],
    };
    ada.items.push(item(
        1,
        ItemKind::AssistantText {
            message_id: None,
            text: "done".into(),
        },
    ));
    let last = ada.items.len() - 1;
    lines.push(Frame::patch(&ada, [0, last]).to_line());
    lines.push(
        Frame::Gone {
            session_id: "lead-new".into(),
        }
        .to_line(),
    );
    let (sh, _) = feed(&lines);
    let g = sh.lock().unwrap();
    let vm = g.state.view_model(&Seats::default(), NOW, utc_offset);
    let obs = &vm.projects[0];
    assert_eq!(obs.agents[2].status, Status::Gone);
    assert_eq!(obs.agents[2].turn_started, None, "gone never counts up");
    let items = &obs.agents[0].items;
    assert_eq!(items.len(), 8);
    assert_eq!(
        items[0],
        ChatItem::User {
            text: "edited".into(),
            images: vec![]
        }
    );
    assert_eq!(
        items[7],
        ChatItem::Assistant {
            markdown: "done".into()
        }
    );

    // A shrinking patch truncates.
    let mut shorter = sessions[2].clone();
    shorter.items.truncate(2);
    drop(g);
    let mut g = sh.lock().unwrap();
    assert!(g.state.apply(Frame::patch(&shorter, [])));
    let vm = g.state.view_model(&Seats::default(), NOW, utc_offset);
    assert_eq!(vm.projects[0].agents[0].items.len(), 2);
}

#[test]
fn bad_lines_and_unknown_frames_are_skipped_never_a_crash() {
    let (_, good) = scenario();
    let mut lines = vec![good[0].clone()];
    lines.extend([
        "not json".to_owned(),
        "{\"frame\":\"weather\",\"sunny\":true}".to_owned(),
        "{\"frame\":\"session\"}".to_owned(),
        String::new(),
        "{\"frame\":\"patch\",\"session_id\":\"nobody\",\"meta\":{},\"status\":{},\"stats\":{},\"len\":0,\"items\":[]}".to_owned(),
    ]);
    lines.extend(good[1..].iter().cloned());
    let (sh, _) = feed(&lines);
    // A non-UTF-8 line right after `hello`: everything after it must still arrive.
    let mut bytes = (good[0].clone() + "\n").into_bytes();
    bytes.extend_from_slice(b"\xff\xfe not utf8\n");
    bytes.extend_from_slice((lines[1..].join("\n") + "\n").as_bytes());
    let sh2 = shared();
    let (rp, _) = counter();
    pump(Cursor::new(bytes), &sh2, &rp, 0);
    let a = sh.lock().unwrap();
    let b = sh2.lock().unwrap();
    assert_eq!(a.state.session_count(), 5);
    assert_eq!(b.state.session_count(), 5);
}

// ------------------------------------------------------------------ repaint rule

#[test]
fn repaints_only_when_a_frame_changes_something() {
    let (sessions, lines) = scenario();
    let (_, n) = feed(&lines);
    assert_eq!(n, lines.len(), "hello + 5 new sessions: one repaint each");

    let mut quiet = lines.clone();
    let ada = &sessions[2];
    let mut counted = ada.clone();
    counted.stats.records += 7; // counters move, nothing visible does
    quiet.extend([
        full("my-app", ada),              // identical snapshot
        full("my-app", &counted),         // only counters differ
        Frame::patch(ada, [0]).to_line(), // same item, same header
        Frame::Gone {
            session_id: "lead-old".into(), // already gone
        }
        .to_line(),
        Frame::Gone {
            session_id: "nobody".into(),
        }
        .to_line(),
        "garbage".into(),
        "{\"frame\":\"weather\"}".into(),
    ]);
    let (_, n2) = feed(&quiet);
    assert_eq!(n2, lines.len(), "no-op frames and bad lines never repaint");

    let mut busy = lines.clone();
    let mut moved = ada.clone();
    moved.status.activity = Activity::Working;
    busy.push(Frame::patch(&moved, []).to_line());
    let mut renamed = ada.clone();
    renamed.meta.model = Some("claude-sonnet-5-5".into());
    busy.push(full("my-app", &renamed)); // a held session's snapshot that moved
    busy.push(
        Frame::Gone {
            session_id: "ada".into(),
        }
        .to_line(),
    );
    let (_, n3) = feed(&busy);
    assert_eq!(
        n3,
        lines.len() + 3,
        "a status change, a moved snapshot and a gone each repaint"
    );
}

#[test]
fn unknown_protocol_is_refused_with_a_reason() {
    let (_, lines) = scenario();
    let mut l = vec![
        Frame::Hello {
            protocol: 99,
            distro: None,
            note: None,
            seats: Vec::new(),
        }
        .to_line(),
    ];
    l.extend(lines[1..].iter().cloned());
    let (sh, n) = feed(&l);
    let g = sh.lock().unwrap();
    assert_eq!(n, 1, "only the refusal repaints");
    assert_eq!(g.state.session_count(), 0);
    match &g.conn {
        Conn::Failed(why) => assert!(why.contains("protocol 99"), "{why}"),
        c => panic!("expected a failure, got {c:?}"),
    }
}

#[test]
fn a_second_hello_starts_over() {
    let (_, mut lines) = scenario();
    lines.push(hello());
    let (sh, _) = feed(&lines);
    assert_eq!(sh.lock().unwrap().state.session_count(), 0);
}

// ------------------------------------------------------------------ the real process path

fn wait_conn(src: &LiveSource, done: impl Fn(&Conn) -> bool) -> Conn {
    let t0 = Instant::now();
    loop {
        let c = src.conn();
        if done(&c) || t0.elapsed() > Duration::from_secs(10) {
            return c;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A fake bridge: a shell script run as `/bin/sh <script>`, never exec'd itself. Exec'ing a file
/// this process just wrote fails with ETXTBSY ("Text file busy") when another test thread forked
/// while the file was open for writing: the child holds the write fd until its own exec.
#[cfg(unix)]
fn fake_bridge(name: &str, body: &str) -> Launch {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("fake-bridges");
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join(name);
    std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
    Launch::Direct {
        program: "/bin/sh".into(),
        args: vec![p.to_string_lossy().into_owned()],
    }
}

#[cfg(unix)]
#[test]
fn a_bridge_that_exits_shows_why_and_keeps_what_it_sent() {
    let (_, lines) = scenario();
    let frames = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("frames.jsonl");
    std::fs::write(&frames, lines.join("\n") + "\n").unwrap();
    let script = fake_bridge(
        "exits3.sh",
        &format!(
            "cat '{}'\necho 'config: bad toml' >&2\nexit 3",
            frames.display()
        ),
    );
    let (rp, n) = counter();
    let src = LiveSource::start(script, rp);
    let c = wait_conn(&src, |c| matches!(c, Conn::Failed(_)));
    match c {
        Conn::Failed(why) => {
            assert!(why.contains("exit code 3"), "{why}");
            assert!(why.contains("config: bad toml"), "stderr tail shown: {why}");
        }
        c => panic!("expected the exit to show, got {c:?}"),
    }
    assert_eq!(src.shared.lock().unwrap().state.session_count(), 5);
    assert_eq!(
        n.load(Ordering::SeqCst),
        lines.len() + 1,
        "frames + the exit"
    );
}

#[test]
fn a_missing_bridge_says_so_and_does_not_block() {
    let (rp, _) = counter();
    let t0 = Instant::now();
    let src = LiveSource::start(
        Launch::Direct {
            program: "/nonexistent/observatory-bridge".into(),
            args: vec![],
        },
        rp,
    );
    assert!(
        t0.elapsed() < Duration::from_millis(500),
        "start returns at once"
    );
    match wait_conn(&src, |c| matches!(c, Conn::Failed(_))) {
        Conn::Failed(why) => {
            assert!(why.contains("not installed"), "{why}");
            assert!(why.contains("/nonexistent/observatory-bridge"), "{why}");
        }
        c => panic!("expected a failure, got {c:?}"),
    }
}

#[cfg(unix)]
#[test]
fn a_slow_bridge_shows_connecting_then_retry_reconnects() {
    let script = fake_bridge("slow.sh", "exec sleep 30");
    let (rp, _) = counter();
    let mut src = LiveSource::start(script, rp);
    assert_eq!(src.conn(), Conn::Connecting);
    let ok = fake_bridge("hello.sh", &format!("echo '{}'\nexec sleep 30", hello()));
    src.launch = ok;
    src.retry();
    assert_eq!(wait_conn(&src, |c| *c == Conn::Live), Conn::Live);
}

#[test]
fn the_wsl_command_resolves_home_inside_wsl() {
    let c = Launch::Wsl { path: None }.command();
    assert_eq!(c.get_program(), "wsl.exe");
    let args: Vec<_> = c
        .get_args()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        args,
        [
            "--exec",
            "sh",
            "-c",
            "exec \"$HOME/.local/share/observatory/bin/observatory-bridge\""
        ]
    );
    let c = Launch::Wsl {
        path: Some("/opt/it's/bridge".into()),
    }
    .command();
    let last = c.get_args().last().unwrap().to_string_lossy().into_owned();
    assert_eq!(last, r"exec '/opt/it'\''s/bridge'");
}

// ------------------------------------------------------------------ the window

const WINDOW: [f32; 2] = [1180.0, 900.0];

fn live_app() -> ObservatoryApp {
    live_app_with(&[])
}

/// The scenario, then a `gone` frame for each of `gone` (session ids).
fn live_app_with(gone: &[&str]) -> ObservatoryApp {
    let (_, mut lines) = scenario();
    lines.extend(gone.iter().map(|id| {
        Frame::Gone {
            session_id: (*id).into(),
        }
        .to_line()
    }));
    let (sh, _) = feed(&lines);
    let vm = sh
        .lock()
        .unwrap()
        .state
        .view_model(&Seats::default(), NOW, utc_offset);
    let mut app = ObservatoryApp::new(vm, Clock::Fixed(NOW));
    // Decode on the UI thread so a snapshot never races the image worker.
    app.images = observatory_app::images::ImageCache::inline();
    app
}

fn harness(app: ObservatoryApp, theme: Theme) -> Harness<'static, ObservatoryApp> {
    let mut h = Harness::builder()
        .with_size(vec2(WINDOW[0], WINDOW[1]))
        .with_theme(theme)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    h
}

#[test]
fn live_window_shows_seat_first_restart_and_gone_rows() {
    let mut h = harness(live_app(), Theme::Dark);
    h.get_by_label("Lead, seat, working, 1m");
    h.get_by_label("Ada, sibling, idle, 14m");
    h.get_by_label("Bo, sibling, needs you, 3m");
    h.get_by_label("session 5be0d1c4, sibling, idle, 20m");
    h.get_by_label("Lead restarted · 15:12");
    h.get_by_label("working… 0:45");
    h.get_by_label("Ada, sibling, idle, 14m").click();
    h.run();
    h.get_by_label("Ran cargo test — failed");
    h.get_by_label("Conversation compacted");
}

/// A stopped agent's row renders as gone (the label) and dimmed (the snapshot:
/// name, role line and age drawn at reduced strength, hollow dot).
#[test]
fn a_gone_agent_renders_as_a_dimmed_gone_row() {
    let mut h = harness(live_app_with(&["bo"]), Theme::Dark);
    h.get_by_label("Bo, sibling, gone, 3m");
    assert!(h.query_by_label("Bo, sibling, needs you, 3m").is_none());
    h.get_by_label("Bo, sibling, gone, 3m").click();
    h.run();
    h.get_by_label("gone");
    assert!(
        h.query_by_label_contains("working…").is_none(),
        "gone never counts up"
    );
    h.snapshot("live_gone_dark");
}

#[test]
fn snapshot_live_window_dark() {
    let mut h = harness(live_app(), Theme::Dark);
    h.get_by_label("Ada, sibling, idle, 14m").click();
    h.run();
    h.snapshot("live_ada_dark");
}

#[test]
fn failure_banner_offers_retry() {
    let (rp, _) = counter();
    let src = LiveSource::start(
        Launch::Direct {
            program: "/nonexistent/observatory-bridge".into(),
            args: vec![],
        },
        rp,
    );
    wait_conn(&src, |c| matches!(c, Conn::Failed(_)));
    let app = ObservatoryApp::live(src, Seats::default(), utc_offset, Clock::Fixed(NOW));
    let mut h = harness(app, Theme::Dark);
    h.get_by_label_contains("No live data. The bridge is not installed");
    h.get_by_label("Retry").click();
    h.run();
    // The retry fails again (still missing) but went through Connecting first.
    let c = wait_conn(&h.state().live.as_ref().unwrap().source, |c| {
        matches!(c, Conn::Failed(_))
    });
    assert!(matches!(c, Conn::Failed(_)));
}

/// The live window settles like the demo: a frame applied → one model rebuild, then no
/// immediate repaints.
#[test]
fn live_window_settles_without_immediate_repaints() {
    let mut h = Harness::builder()
        .with_size(vec2(WINDOW[0], WINDOW[1]))
        .with_context_setup(ObservatoryApp::install)
        .with_max_steps(8)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), live_app());
    h.try_run().expect("first run settles");
    let steps = h.try_run().expect("settles again");
    assert!(steps <= 2, "needed {steps} steps to settle");
}

#[test]
fn a_stale_reader_changes_nothing() {
    let (_, lines) = scenario();
    let sh = shared();
    sh.lock().unwrap().epoch = 1; // a retry happened after this reader started
    let (rp, n) = counter();
    pump(Cursor::new(lines.join("\n") + "\n"), &sh, &rp, 0);
    assert_eq!(n.load(Ordering::SeqCst), 0);
    assert_eq!(sh.lock().unwrap().state.session_count(), 0);
}

#[test]
fn selection_follows_the_agent_by_name_when_the_model_rebuilds() {
    let (_, lines) = scenario();
    let (rp, _) = counter();
    let src = LiveSource::idle(Launch::for_platform(None), rp);
    let sh = src.shared.clone();
    pump(Cursor::new(lines.join("\n") + "\n"), &sh, &counter().0, 0);
    let app = ObservatoryApp::live(src, Seats::default(), utc_offset, Clock::Fixed(NOW));
    let mut h = harness(app, Theme::Dark);
    h.get_by_label("Bo, sibling, needs you, 3m").click();
    h.run();
    // A new agent that sorts before Bo shifts every index after it.
    let abe = session("abe", Some("Abe"), 5, 5);
    pump(
        Cursor::new(full("my-app", &abe) + "\n"),
        &sh,
        &counter().0,
        0,
    );
    h.run();
    let st = h.state();
    let (_, a) = st.vm.get(st.selected.unwrap()).unwrap();
    assert_eq!(a.name, "Bo");
    assert_eq!(
        st.vm.projects[0].agents[0].name, "Abe",
        "the index really moved"
    );
}

/// After Retry, an old reader whose stdout closes late (a grandchild holds the
/// pipe) must not take the NEW connection's child: the new bridge's exit still shows.
#[cfg(unix)]
fn retry_case(tag: &str, first_tail: &str) -> Conn {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("race-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let script = fake_bridge(
        &format!("race-{tag}.sh"),
        &format!(
            "d='{d}'; n=$(cat \"$d/count\" 2>/dev/null || echo 0); n=$((n+1)); echo $n > \"$d/count\"\n\
             if [ $n = 1 ]; then echo '{{\"frame\":\"hello\",\"protocol\":99}}'; {first_tail}; fi\n\
             echo '{{\"frame\":\"hello\",\"protocol\":{PROTOCOL}}}'; sleep 5; exit 3",
            d = dir.display()
        ),
    );
    let (rp, _) = counter();
    let mut src = LiveSource::start(script, rp);
    let c = wait_conn(&src, |c| matches!(c, Conn::Failed(_)));
    assert!(
        matches!(&c, Conn::Failed(w) if w.contains("protocol 99")),
        "{c:?}"
    );
    src.retry(); // old child still running
    assert_eq!(wait_conn(&src, |c| *c == Conn::Live), Conn::Live);
    wait_conn(&src, |c| matches!(c, Conn::Failed(_)))
}

#[cfg(unix)]
#[test]
fn retry_with_a_lingering_old_stdout_still_reports_the_new_exit() {
    let c = retry_case("linger", "(sleep 3) & exec sleep 100");
    assert!(
        matches!(&c, Conn::Failed(w) if w.contains("exit code 3")),
        "got {c:?}"
    );
}

#[cfg(unix)]
#[test]
fn retry_without_linger_reports_the_new_exit() {
    let c = retry_case("plain", "exec sleep 100");
    assert!(
        matches!(&c, Conn::Failed(w) if w.contains("exit code 3")),
        "got {c:?}"
    );
}

/// Back-to-back retries, then drop, leave no bridge running.
#[cfg(unix)]
#[test]
fn double_retry_then_drop_kills_every_child() {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("double-retry");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let script = fake_bridge(
        "double-retry.sh",
        &format!("echo $$ >> '{}/pids'\nexec sleep 30", dir.display()),
    );
    let (rp, _) = counter();
    let mut src = LiveSource::start(script, rp);
    src.retry();
    src.retry();
    std::thread::sleep(Duration::from_millis(1500));
    drop(src);
    std::thread::sleep(Duration::from_millis(500));
    let pids = std::fs::read_to_string(dir.join("pids")).unwrap();
    let alive: Vec<&str> = pids
        .lines()
        .filter(|p| {
            std::process::Command::new("kill")
                .args(["-0", p])
                .status()
                .unwrap()
                .success()
        })
        .collect();
    for p in &alive {
        let _ = std::process::Command::new("kill").arg(p).status();
    }
    // A bridge whose connection was already stopped is killed as soon as it is spawned, often
    // before its script writes a pid, so 1 to 3 pids appear. None may be left alive.
    let started = pids.lines().count();
    assert!((1..=3).contains(&started), "bridges started: {pids}");
    assert!(
        alive.is_empty(),
        "orphaned bridges after drop: {alive:?} of {pids:?}"
    );
}

/// The exact stdout bytes the real `wsl.exe -d NoSuchDistro` wrote (UTF-16LE, CRLF; 0 bytes on
/// stderr; exit -1), recorded from a Windows-built probe.
const WSL_NODISTRO_STDOUT: &[u8] = include_bytes!("fixtures/wsl_nodistro_stdout.bin");

/// The recorded no-distro bytes through `pump` (as a WSL launch would read them) give the plain
/// "no Linux distribution" banner, not "exit code -1".
#[test]
fn recorded_wsl_nodistro_stdout_gives_the_plain_banner() {
    let sh = shared();
    let (rp, n) = counter();
    pump(Cursor::new(WSL_NODISTRO_STDOUT), &sh, &rp, 0);
    assert_eq!(
        n.load(Ordering::SeqCst),
        0,
        "noise is not a frame: no repaint"
    );
    let g = sh.lock().unwrap();
    let tail = observatory_app::bridge::output_tail(&g.noise, &[]);
    assert_eq!(
        tail,
        "There is no distribution with the supplied name.\n\
         Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND\n\
         If this error was unexpected, please consider searching for existing issues or filing a new issue at https://github.com/microsoft/WSL/issues."
    );
    let why = observatory_app::bridge::exit_reason(&Launch::Wsl { path: None }, Some(-1), &tail);
    assert!(
        why.starts_with("WSL has no Linux distribution installed"),
        "{why}"
    );
    assert!(!why.contains("exit code"), "{why}");
}

/// wsl.exe's own error comes on STDOUT, not stderr. A bridge that writes it and
/// exits must show the decoded text, not just an exit code.
#[cfg(unix)]
#[test]
fn non_frame_stdout_text_reaches_the_banner_decoded() {
    let bin = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/wsl_nodistro_stdout.bin");
    let script = fake_bridge("nodistro.sh", &format!("cat '{}'\nexit 255", bin.display()));
    let (rp, _) = counter();
    let src = LiveSource::start(script, rp);
    match wait_conn(&src, |c| matches!(c, Conn::Failed(_))) {
        Conn::Failed(why) => {
            assert!(why.contains("exit code 255"), "{why}");
            assert!(
                why.contains("There is no distribution with the supplied name."),
                "{why}"
            );
            assert!(why.contains("WSL_E_DISTRO_NOT_FOUND"), "{why}");
            assert!(!why.contains('\0'), "{why:?}");
        }
        c => panic!("expected a failure, got {c:?}"),
    }
    assert_eq!(
        WSL_NODISTRO_STDOUT.len(),
        482,
        "fixture is the recorded bytes"
    );
}

/// Closing the window right after start: the bridge that is still being spawned must not
/// outlive the app.
#[cfg(unix)]
#[test]
fn drop_right_after_start_leaves_no_bridge() {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("drop-early");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let script = fake_bridge(
        "drop-early.sh",
        &format!("echo $$ >> '{}/pids'\nexec sleep 30", dir.display()),
    );
    for _ in 0..5 {
        let (rp, _) = counter();
        drop(LiveSource::start(script.clone(), rp));
    }
    std::thread::sleep(Duration::from_millis(1500));
    let pids = std::fs::read_to_string(dir.join("pids")).unwrap_or_default();
    let alive: Vec<&str> = pids
        .lines()
        .filter(|p| {
            std::process::Command::new("kill")
                .args(["-0", p])
                .status()
                .unwrap()
                .success()
        })
        .collect();
    for p in &alive {
        let _ = std::process::Command::new("kill").arg(p).status();
    }
    assert!(
        alive.is_empty(),
        "bridges left after drop: {alive:?} of {pids:?}"
    );
}

/// The banner after a Retry quotes only the NEW run's output, never the old run's.
#[cfg(unix)]
#[test]
fn a_retry_banner_does_not_quote_the_previous_run() {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("retry-noise");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let script = fake_bridge(
        "retry-noise.sh",
        &format!(
            "d='{d}'; n=$(cat \"$d/count\" 2>/dev/null || echo 0); n=$((n+1)); echo $n > \"$d/count\"\n\
             if [ $n = 1 ]; then echo 'old run: config broken'; exit 2; fi\n\
             echo 'new run: disk full'; exit 3",
            d = dir.display()
        ),
    );
    let (rp, _) = counter();
    let mut src = LiveSource::start(script, rp);
    match wait_conn(&src, |c| matches!(c, Conn::Failed(_))) {
        Conn::Failed(w) => assert!(w.contains("old run: config broken"), "{w}"),
        c => panic!("{c:?}"),
    }
    src.retry();
    match wait_conn(
        &src,
        |c| matches!(c, Conn::Failed(w) if w.contains("exit code 3")),
    ) {
        Conn::Failed(w) => {
            assert!(w.contains("new run: disk full"), "{w}");
            assert!(!w.contains("old run"), "the old run's text leaked: {w}");
        }
        c => panic!("{c:?}"),
    }
}

/// Retry while the old (refused) bridge still floods stdout. Its reader must
/// be stale BEFORE the reset, or its output lands in the new run's banner. `retry_gap` widens the
/// gap between retry's steps (a review saw 20/20 leaks with 5 ms in the old order).
#[cfg(unix)]
#[test]
fn retry_during_an_old_flood_never_quotes_the_old_run() {
    for i in 0..5 {
        let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("flood-{i}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = fake_bridge(
            &format!("flood-{i}.sh"),
            &format!(
                "d='{d}'; n=$(cat \"$d/count\" 2>/dev/null || echo 0); n=$((n+1)); echo $n > \"$d/count\"\n\
                 if [ $n = 1 ]; then echo '{{\"frame\":\"hello\",\"protocol\":99}}'; exec yes OLDNOISE; fi\n\
                 echo '{{\"frame\":\"hello\",\"protocol\":{PROTOCOL}}}'; sleep 0.3; exit 3",
                d = dir.display()
            ),
        );
        let (rp, _) = counter();
        let mut src = LiveSource::start(script, rp);
        src.retry_gap = Duration::from_millis(5);
        wait_conn(&src, |c| matches!(c, Conn::Failed(_)));
        std::thread::sleep(Duration::from_millis(50)); // the flood is running
        src.retry();
        assert_eq!(wait_conn(&src, |c| *c == Conn::Live), Conn::Live, "run {i}");
        match wait_conn(&src, |c| matches!(c, Conn::Failed(_))) {
            Conn::Failed(w) => {
                assert!(w.contains("exit code 3"), "run {i}: {w}");
                assert!(!w.contains("OLDNOISE"), "run {i}: old output leaked: {w}");
            }
            c => panic!("run {i}: {c:?}"),
        }
    }
}

/// The app keeps the bridge's distro (WSL paths are read through it on Windows), and an
/// image in a later session of a thread points into THAT session's log, not the first one's.
#[test]
fn images_use_their_own_sessions_log_and_the_hello_distro() {
    let (mut sessions, _) = scenario();
    let pasted = |off| ImageRef::Embedded {
        line_offset: Some(off),
        line_len: 10,
        block: 0,
        part: None,
        media_type: None,
        path: None,
    };
    sessions[0].meta.log_path = Some("/logs/lead-old.jsonl".into());
    sessions[1].meta.log_path = Some("/logs/lead-new.jsonl".into());
    sessions[0].items[0].kind = ItemKind::UserText {
        text: "old".into(),
        images: vec![pasted(1)],
    };
    sessions[1].items[0].kind = ItemKind::UserText {
        text: "new".into(),
        images: vec![pasted(2)],
    };
    let lines = vec![
        hello(),
        full("my-app", &sessions[0]),
        full("my-app", &sessions[1]),
    ];
    let (sh, _) = feed(&lines);
    let g = sh.lock().unwrap();
    assert_eq!(g.state.distro.as_deref(), Some("Ubuntu"));
    let vm = g.state.view_model(&Seats::default(), NOW, utc_offset);
    let logs: Vec<(String, u64)> = vm.projects[0].agents[0]
        .items
        .iter()
        .filter_map(|i| match i {
            ChatItem::User { images, .. } => images.first().map(|im| match &im.src {
                ImageSrc::Embedded { log, offset, .. } => (log.clone(), *offset),
                other => panic!("{other:?}"),
            }),
            _ => None,
        })
        .collect();
    assert_eq!(
        logs,
        [
            ("/logs/lead-old.jsonl".to_owned(), 1),
            ("/logs/lead-new.jsonl".to_owned(), 2)
        ]
    );
}

/// Ruling: File refs of a Bash call are hide-if-missing; a Read's are not.
#[test]
fn bash_file_refs_are_hidden_when_missing_read_refs_are_not() {
    use observatory_app::live::{PathCtx, map_item};
    let call = |name: &str| {
        ItemKind::ToolCall(ToolCall {
            id: "t".into(),
            name: name.into(),
            message_id: None,
            summary: String::new(),
            input: String::new(),
            input_truncated: false,
            result: None,
            images: vec![ImageRef::File {
                path: "/x/a.png".into(),
            }],
        })
    };
    let hide = |name: &str| match map_item(call(name), &PathCtx::default()) {
        ChatItem::ToolCall { images, .. } => images[0].hide_if_missing,
        other => panic!("{other:?}"),
    };
    assert!(hide("Bash"));
    assert!(!hide("Read") && !hide("Write") && !hide("Edit"));
}

/// A live update that inserts a project before the one whose Visuals are shown keeps
/// that project's Visuals selected (by name), not the index it used to have.
#[test]
fn visuals_follow_the_project_by_name_across_live_updates() {
    let (_, lines) = scenario();
    let (rp, _) = counter();
    let src = LiveSource::idle(Launch::for_platform(None), rp);
    let sh = src.shared.clone();
    let g = |p: &str| {
        format!(
            r#"{{"frame":"gallery","project":"{p}","total":1,"items":[{{"path":"/nonexistent/{p}.png","mtime_ms":1,"size":1}}]}}"#
        )
    };
    pump(
        Cursor::new(lines.join("\n") + "\n" + &g("zeta") + "\n"),
        &sh,
        &counter().0,
        0,
    );
    let app = ObservatoryApp::live(src, Seats::default(), utc_offset, Clock::Fixed(NOW));
    let mut h = harness(app, Theme::Dark);
    h.get_by_label("Visuals (1), zeta").click();
    h.run();
    let before = h.state().visuals;
    pump(Cursor::new(g("aaa") + "\n"), &sh, &counter().0, 0);
    h.run();
    let st = h.state();
    let shown = st.visuals.expect("still showing Visuals");
    assert_eq!(st.vm.projects[shown].name, "zeta");
    assert_ne!(
        before, st.visuals,
        "the index really moved (aaa sorts first)"
    );
}

/// A home-folder session (synthetic fixture, no agent name or title) is its own group,
/// after the configured projects, labelled by its first human line, with its page; no gallery.
#[test]
fn home_folder_session_is_its_own_group_named_by_its_first_line() {
    const HOME: &str = include_str!("../../core/tests/fixtures/synthetic_home.jsonl");
    let mut home = Session::new("-home-user", "home-1");
    let mut b = observatory_core::lines::LineBuffer::new();
    for l in b.push_lines(HOME.as_bytes()) {
        home.push_line_at(&l.text, l.offset, l.len);
    }
    let named = session("ada-1", Some("Ada"), 10, 5);
    let lines = [hello(), full("~ (home)", &home), full("my-app", &named)];
    let (sh, _) = feed(&lines);
    let vm = sh
        .lock()
        .unwrap()
        .state
        .view_model(&Seats::default(), NOW, utc_offset);
    let names: Vec<_> = vm.projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["my-app", "~ (home)"], "home sorts last");
    let h = &vm.projects[1];
    assert!(h.gallery.is_none());
    let agents: Vec<_> = h.agents.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(agents, ["Open a terminal for each of the two…"]);
    let pages: Vec<_> = h.agents[0]
        .pages
        .iter()
        .map(|p| (p.title.as_str(), p.versions))
        .collect();
    assert_eq!(pages, [("status-board", 2)]);
}

#[test]
fn an_unconfigured_bridge_shows_where_the_config_goes_and_the_kit_seat() {
    // No config on the bridge side: no seat list, a note, and only a home-folder session.
    let note = "No projects configured: write /home/user/.config/observatory/bridge.json (see the bridge README).";
    let mut orca = session("orca-1", Some("Orca"), 60, 1);
    orca.status.liveness = Liveness::Running;
    let lines = vec![
        Frame::Hello {
            protocol: PROTOCOL,
            distro: None,
            seats: Vec::new(),
            note: Some(note.into()),
        }
        .to_line(),
        Frame::Session {
            project: "~ (home)".into(),
            session: Box::new(orca),
        }
        .to_line(),
    ];
    let (sh, _) = feed(&lines);
    let vm = sh
        .lock()
        .unwrap()
        .state
        .view_model(&Seats::default(), NOW, utc_offset);
    assert_eq!(vm.note.as_deref(), Some(note));
    assert_eq!(
        vm.projects[0].agents[0].role,
        Role::Seat,
        "no seat list anywhere: the kit's default seat name"
    );
    let h = harness(ObservatoryApp::new(vm, Clock::Fixed(NOW)), Theme::Dark);
    h.get_by_label(note);
}
