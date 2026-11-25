//! End-to-end tests on the fixtures in `tests/fixtures/` (see its README for provenance).
//! Expected counts were derived independently from the fixture files with a Python one-off.

use observatory_core::lines::LineBuffer;
use observatory_core::session::{ToolCall, ToolResult};
use observatory_core::time::parse_ms;
use observatory_core::wire::{self, Frame, PROTOCOL};
use observatory_core::*;

const ADA: &str = include_str!("fixtures/synthetic_session.jsonl");
const ZOO: &str = include_str!("fixtures/synthetic_zoo.jsonl");
const OBS_SLUG: &str = "-home-user-my-app";

fn ada() -> Session {
    Session::from_lines(OBS_SLUG, "7a1e5c00", ADA.lines())
}

fn zoo() -> Session {
    Session::from_lines("-home-user-proj", "zoo-1", ZOO.lines())
}

fn tool_calls(s: &Session) -> Vec<&ToolCall> {
    s.items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::ToolCall(c) => Some(c),
            _ => None,
        })
        .collect()
}

fn kinds(s: &Session) -> Vec<&'static str> {
    s.items
        .iter()
        .map(|i| match &i.kind {
            ItemKind::UserText { .. } => "user",
            ItemKind::SlashCommand { .. } => "slash",
            ItemKind::AgentMessage { .. } => "agent_msg",
            ItemKind::Notice { .. } => "notice",
            ItemKind::AssistantText { .. } => "text",
            ItemKind::Thinking { .. } => "thinking",
            ItemKind::ToolCall(_) => "tool",
        })
        .collect()
}

#[test]
fn session_fixture_identity_and_meta() {
    let s = ada();
    assert_eq!(s.meta.agent_name.as_deref(), Some("Ada"));
    assert_eq!(s.meta.custom_title.as_deref(), Some("Ada"));
    assert_eq!(s.meta.permission_mode.as_deref(), Some("auto"));
    assert_eq!(s.meta.mode.as_deref(), Some("normal"));
    assert_eq!(s.meta.model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(s.meta.cwd.as_deref(), Some("/home/user/my-app"));
    assert_eq!(
        s.meta.last_activity_ms,
        parse_ms("2030-03-14T09:01:02.701Z")
    );
    assert_eq!(s.stats.malformed, 0);
    assert_eq!(s.stats.records, 161);
}

#[test]
fn session_fixture_items_in_order_and_hidden_meta() {
    let s = ada();
    let k = kinds(&s);
    assert_eq!(k.iter().filter(|&&x| x == "tool").count(), 12);
    assert_eq!(k.iter().filter(|&&x| x == "text").count(), 2);
    // Every thinking block here is redacted (signature only): 10 lines carry one, 6 remain after
    // duplicate-uuid lines are dropped, and none becomes an item.
    assert_eq!(k.iter().filter(|&&x| x == "thinking").count(), 0);
    assert_eq!(k.iter().filter(|&&x| x == "agent_msg").count(), 1);
    // The skill text (isMeta) and api-request-blob replays never become chat.
    assert_eq!(k.iter().filter(|&&x| x == "user").count(), 0);
    let ItemKind::SlashCommand { name, .. } = &s.items[0].kind else {
        panic!(
            "first item should be the /orient command, got {:?}",
            s.items[0].kind
        )
    };
    assert_eq!(name, "/orchestration-kit:orient");
    // Items keep file (time) order.
    let ts: Vec<i64> = s.items.iter().filter_map(|i| i.timestamp_ms).collect();
    assert!(ts.windows(2).all(|w| w[0] <= w[1]));
}

#[test]
fn session_fixture_tools_pair_even_out_of_order() {
    let s = ada();
    let calls = tool_calls(&s);
    assert_eq!(calls.iter().filter(|c| c.result.is_some()).count(), 11);
    let unpaired: Vec<_> = calls
        .iter()
        .filter(|c| c.result.is_none())
        .map(|c| c.id.as_str())
        .collect();
    assert_eq!(unpaired, vec!["toolu_01mwW1NcQJxWGzEVJ2dJ5RVt"]);
    // Two calls in one message whose results came back in reverse order.
    let by_id = |id: &str| *calls.iter().find(|c| c.id == id).unwrap();
    let a = by_id("toolu_01TYsSSpeD9MmLXw6IOn3037");
    let b = by_id("toolu_01LOUj7KuJENO969gtW9ypma");
    assert_eq!(a.message_id, b.message_id);
    assert!(
        a.result
            .as_ref()
            .unwrap()
            .text
            .starts_with("# Orientation for new sessions")
    );
    assert!(b.result.as_ref().unwrap().text.starts_with("# Kit notes"));
    assert!(a.summary.starts_with("Ran cat docs/or"), "{}", a.summary);
    assert_eq!(
        by_id("toolu_01CAj6UMXSFoMFdX2w8mNL2E").summary,
        "ListAgents"
    );
    assert_eq!(
        by_id("toolu_01ix7gtGAO1NDx291DDltJbP").summary,
        "Messaged Lead"
    );
}

#[test]
fn session_fixture_peer_message_is_not_a_human_bubble() {
    let s = ada();
    let (from, body) = s
        .items
        .iter()
        .find_map(|i| match &i.kind {
            ItemKind::AgentMessage { from, body, .. } => Some((from, body)),
            _ => None,
        })
        .unwrap();
    assert_eq!(from, "Lead");
    assert!(body.starts_with("WILLOW-7"), "{body}");
}

#[test]
fn session_fixture_ends_mid_turn_so_working() {
    let s = ada();
    assert_eq!(s.status.activity, Activity::Working);
    // The turn opened by the peer message after the 09:00:01 turn_duration.
    assert_eq!(
        s.status.working_since_ms,
        parse_ms("2030-03-14T09:01:02.072Z")
    );
    assert_eq!(s.status.liveness, Liveness::Unknown);
}

#[test]
fn zoo_every_kind_lands_where_it_should() {
    let s = zoo();
    assert_eq!(
        kinds(&s),
        vec![
            "user",
            "user",
            "tool",
            "notice",
            "agent_msg",
            "text",
            "notice",
            "notice",
            "notice",
            "notice",
            "slash",
            "notice"
        ]
    );
    let n = |i: usize| match &s.items[i].kind {
        ItemKind::Notice {
            notice, summary, ..
        } => (*notice, summary.as_str()),
        k => panic!("item {i} not a notice: {k:?}"),
    };
    assert_eq!(
        n(3),
        (
            NoticeKind::TaskNotification,
            "Agent \"Survey the logs\" completed"
        )
    );
    assert_eq!(n(6).0, NoticeKind::Compacted);
    assert_eq!(n(7).0, NoticeKind::CompactSummary);
    assert_eq!(n(8).0, NoticeKind::Info);
    assert_eq!(n(9).0, NoticeKind::LocalCommand);
    assert_eq!(n(11).0, NoticeKind::Interrupted);
    assert_eq!(
        s.items[1].kind,
        ItemKind::UserText {
            text: "see this".into(),
            // Parsed without offsets (from_lines): the ref keeps its block but cannot be read back.
            images: vec![ImageRef::Embedded {
                line_offset: None,
                line_len: 0,
                block: 1,
                part: None,
                media_type: Some("image/png".into()),
                path: None,
            }]
        }
    );
    let ItemKind::AgentMessage {
        from,
        body,
        task_id,
    } = &s.items[4].kind
    else {
        panic!()
    };
    // A bare hex sender is a subagent hand-back.
    assert_eq!(from, "subagent");
    assert_eq!(task_id.as_deref(), Some("a1b2c3"));
    assert_eq!(
        body,
        "[Subagent hand-back] The survey found 27 record types."
    );
    let ItemKind::SlashCommand { name, args } = &s.items[10].kind else {
        panic!()
    };
    assert_eq!((name.as_str(), args.as_str()), ("/clear", ""));
    assert_eq!(tool_calls(&s)[0].summary, "Agent: Survey the logs");
    assert_eq!(
        tool_calls(&s)[0].result,
        Some(ToolResult {
            text: "Async agent launched".into(),
            truncated: false,
            is_error: false
        })
    );
}

#[test]
fn zoo_status_stats_and_away_summary() {
    let s = zoo();
    assert_eq!(
        s.status.activity,
        Activity::Idle,
        "interrupt closes the turn"
    );
    assert_eq!(
        s.status.away_summary.as_deref(),
        Some("You asked for a sidebar review; the survey finished.")
    );
    assert_eq!(s.stats.malformed, 2, "truncated line + bare number");
    assert_eq!(s.stats.unknown_blocks, 1, "server_tool_use");
    assert_eq!(s.stats.duplicates, 1, "repeated uuid z-01");
    assert_eq!(s.meta.agent_name.as_deref(), Some("Zed"));
}

#[test]
fn idle_after_turn_duration() {
    let lines: Vec<&str> = ZOO.lines().take(8).collect(); // through the first turn_duration
    let s = Session::from_lines("-home-user-proj", "zoo-1", lines);
    assert_eq!(s.status.activity, Activity::Idle);
    assert_eq!(s.status.working_since_ms, None);
    let s = Session::from_lines("-home-user-proj", "zoo-1", ZOO.lines().take(7));
    assert_eq!(s.status.activity, Activity::Working);
    assert_eq!(
        s.status.working_since_ms,
        parse_ms("2026-11-23T10:00:00.000Z")
    );
}

#[test]
fn tailer_chunks_give_the_same_session_as_whole_file() {
    let whole = ada();
    for chunk in [1usize, 7, 64, 4096] {
        let mut buf = LineBuffer::new();
        let mut s = Session::new(OBS_SLUG, "7a1e5c00");
        for c in ADA.as_bytes().chunks(chunk) {
            for l in buf.push(c) {
                s.push_line(&l);
            }
        }
        assert_eq!(buf.pending_len(), 0);
        assert_eq!(s, whole, "chunk size {chunk}");
    }
    // A file cut mid-line: the partial tail is held, not parsed as garbage.
    let cut = ADA.len() - 40;
    let mut buf = LineBuffer::new();
    let mut s = Session::new(OBS_SLUG, "7a1e5c00");
    for l in buf.push(&ADA.as_bytes()[..cut]) {
        s.push_line(&l);
    }
    assert_eq!(s.stats.malformed, 0);
    assert!(buf.pending_len() > 0);
    for l in buf.push(&ADA.as_bytes()[cut..]) {
        s.push_line(&l);
    }
    assert_eq!(s, whole);
}

/// A second Ada session derived from the fixture: new id, every timestamp moved one hour later.
fn restarted(session_id: &str) -> String {
    ADA.lines()
        .map(|l| {
            l.replace("7a1e5c00-0b5e-4d1a-9f00-00000000ada1", session_id)
                .replace("\"2030-03-14T09:", "\"2030-03-14T10:")
                .replace("\"uuid\": \"", "\"uuid\": \"r-")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn projects() -> Vec<ProjectSpec> {
    vec![
        ProjectSpec {
            name: "my-app".into(),
            root: "/home/user/my-app".into(),
            worktree_roots: vec!["/home/user/my-app-worktrees".into()],
            gallery: vec![],
            exact: false,
        },
        ProjectSpec {
            name: "my".into(),
            root: "/home/user/my".into(),
            worktree_roots: vec![],
            gallery: vec![],
            exact: false,
        },
    ]
}

#[test]
fn restart_merges_into_one_thread_with_divider() {
    let second_text = restarted("second-session");
    // Fed newest first, and the second one from a worktree slug: still one thread, time order.
    let second = Session::from_lines(
        "-home-user-my-app-worktrees-v1-1",
        "second-session",
        second_text.lines(),
    );
    let threads = build_threads([second, ada()], &projects());
    assert_eq!(threads.len(), 1);
    let (key, t) = threads.iter().next().unwrap();
    assert_eq!(
        key,
        &ThreadKey {
            project: "my-app".into(),
            agent: "Ada".into()
        }
    );
    assert_eq!(t.sessions[0].meta.session_id, "7a1e5c00");
    let entries = t.entries();
    let per = ada().items.len();
    assert_eq!(entries.len(), per * 2 + 1);
    assert_eq!(
        entries[per],
        ThreadEntry::Restart {
            session_id: "second-session".into(),
            at_ms: t.sessions[1].meta.first_activity_ms
        }
    );
    assert!(t.sessions[1].meta.first_activity_ms > t.sessions[0].meta.last_activity_ms);
    assert_eq!(t.status().activity, Activity::Working);
}

#[test]
fn threads_split_by_agent_and_project_and_drop_unknown_projects() {
    let threads = build_threads(
        [
            ada(),
            Session::from_lines("-home-user-my-app", "zoo-1", ZOO.lines()),
            Session::from_lines("-home-user-my", "x", ADA.lines()),
            Session::from_lines("-home-user-elsewhere", "y", ADA.lines()),
            Session::from_lines(
                "-home-user-my-app",
                "nameless",
                ["{\"type\":\"mode\",\"mode\":\"normal\"}"],
            ),
        ],
        &projects(),
    );
    let keys: Vec<(&str, &str)> = threads
        .keys()
        .map(|k| (k.project.as_str(), k.agent.as_str()))
        .collect();
    assert_eq!(
        keys,
        vec![
            ("my", "Ada"),
            ("my-app", "Ada"),
            ("my-app", "Zed"),
            ("my-app", "session:nameless")
        ]
    );
}

#[test]
fn wire_round_trip() {
    let frames = vec![
        Frame::Hello {
            protocol: PROTOCOL,
            distro: Some("Ubuntu".into()),
            seats: vec!["Orca".into(), "Lead".into()],
            note: Some("No projects configured: write ~/.config/observatory/bridge.json".into()),
        },
        Frame::Session {
            project: "my-app".into(),
            session: Box::new(ada()),
        },
        Frame::Session {
            project: "proj".into(),
            session: Box::new(zoo()),
        },
        Frame::Gone {
            session_id: "zoo-1".into(),
        },
    ];
    for f in &frames {
        let line = f.to_line();
        assert!(!line.contains('\n'), "a frame must be one line");
        let back = Frame::from_line(&line).unwrap();
        // Internal pairing maps are not on the wire; compare the public model.
        match (f, &back) {
            (Frame::Session { session: a, .. }, Frame::Session { session: b, .. }) => {
                assert_eq!(
                    (&a.meta, &a.status, &a.items, &a.stats),
                    (&b.meta, &b.status, &b.items, &b.stats)
                );
            }
            _ => assert_eq!(f, &back),
        }
    }
    let hello = Frame::Hello {
        protocol: 2,
        distro: None,
        seats: Vec::new(),
        note: None,
    }
    .to_line();
    assert_eq!(hello, r#"{"frame":"hello","protocol":2}"#);
    // A protocol-1 hello (no distro) still parses, so the app can name the mismatch.
    assert_eq!(
        Frame::from_line(r#"{"frame":"hello","protocol":1}"#).unwrap(),
        Frame::Hello {
            protocol: 1,
            distro: None,
            seats: Vec::new(),
            note: None,
        }
    );
    let zoo_line = frames[2].to_line();
    assert!(
        zoo_line.contains(r#""kind":"agent_message","from":"subagent""#)
            && zoo_line.contains(r#""task_id":"a1b2c3""#),
        "{zoo_line}"
    );
    assert!(zoo_line.contains(r#""kind":"tool_call""#));
}

/// Replays a fixture one line at a time: after each line the app's copy, updated only by
/// `patch` frames that went through the wire, equals the bridge's session. Changed indexes are
/// found by brute force here (the bridge tracks them cheaply).
fn replay_by_patches(slug: &str, id: &str, text: &str) -> usize {
    let mut bridge = Session::new(slug, id);
    let mut app = Session::new(slug, id);
    let mut patches = 0;
    for line in text.lines() {
        let before = bridge.items.clone();
        bridge.push_line(line);
        let changed: Vec<usize> = (0..bridge.items.len())
            .filter(|&i| before.get(i) != Some(&bridge.items[i]))
            .collect();
        let wire = Frame::from_line(&Frame::patch(&bridge, changed.clone()).to_line()).unwrap();
        if let Frame::Patch { items, len, .. } = &wire {
            assert_eq!(*len, bridge.items.len());
            assert_eq!(items.len(), changed.len(), "only changed items are sent");
        } else {
            panic!("not a patch: {wire:?}");
        }
        assert!(wire::apply_patch(&mut app, &wire));
        patches += 1;
        assert_eq!(
            (&app.meta, &app.status, &app.items, &app.stats),
            (&bridge.meta, &bridge.status, &bridge.items, &bridge.stats),
            "diverged after line {patches}"
        );
    }
    patches
}

#[test]
fn patches_rebuild_the_session_line_by_line() {
    assert!(replay_by_patches(OBS_SLUG, "7a1e5c00", ADA) > 10);
    assert!(replay_by_patches("-home-user-proj", "zoo-1", ZOO) > 10);
    // The replay must reach in-place tool completions, not only appends.
    let s = zoo();
    assert!(tool_calls(&s).iter().any(|c| c.result.is_some()));
}

#[test]
fn patch_wire_form_and_guards() {
    let s = ada();
    let n = s.items.len();
    let f = Frame::patch(&s, [n - 1, n - 1, n + 5]);
    let line = f.to_line();
    assert!(
        line.starts_with(r#"{"frame":"patch","session_id":"7a1e5c00""#),
        "{line}"
    );
    let Frame::Patch { items, len, .. } = Frame::from_line(&line).unwrap() else {
        panic!()
    };
    assert_eq!(len, n);
    assert_eq!(
        items.iter().map(|i| i.index).collect::<Vec<_>>(),
        vec![n - 1]
    );
    // A patch for another session, or a non-patch frame, changes nothing.
    let mut other = zoo();
    let snapshot = other.items.clone();
    assert!(!wire::apply_patch(&mut other, &f));
    assert!(!wire::apply_patch(
        &mut other,
        &Frame::Hello {
            protocol: PROTOCOL,
            distro: Some("Ubuntu".into()),
            seats: Vec::new(),
            note: None,
        }
    ));
    assert_eq!(other.items, snapshot);
    // `len` cuts a longer held list.
    let mut longer = ada();
    longer.items.push(longer.items[0].clone());
    assert!(wire::apply_patch(&mut longer, &f));
    assert_eq!(longer.items, s.items);
}
