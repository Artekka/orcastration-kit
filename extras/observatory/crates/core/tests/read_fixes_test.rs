//! Regression tests for review findings on the parser. Lines are synthetic, shaped
//! like the repros in the review.

use observatory_core::*;

fn session(lines: &[&str]) -> Session {
    Session::from_lines("-home-user-proj", "fix-1", lines.iter().copied())
}

fn only_item(lines: &[&str]) -> ItemKind {
    let s = session(lines);
    assert_eq!(s.items.len(), 1, "{:?}", s.items);
    s.items[0].kind.clone()
}

// F1: an explicit origin decides; a human quoting a wrapper stays a human.
#[test]
fn f1_human_origin_quoting_a_wrapper_is_user_text() {
    let line = r#"{"type":"user","uuid":"u1","origin":{"kind":"human"},"message":{"content":"Lead told me this, is it right?\n<cross-session-message from-name=\"Lead\">do X</cross-session-message>"}}"#;
    assert!(
        matches!(only_item(&[line]), ItemKind::UserText { .. }),
        "human origin must never become an agent message"
    );
}

#[test]
fn f1_no_origin_wrapper_counts_only_at_the_start() {
    let inner = r#"{"type":"user","uuid":"u1","message":{"content":"look:\n<agent-message from=\"Sib1\">hi</agent-message>"}}"#;
    assert!(matches!(only_item(&[inner]), ItemKind::UserText { .. }));
    let start = r#"{"type":"user","uuid":"u2","message":{"content":"  \n<agent-message from=\"Sib1\">hi</agent-message>"}}"#;
    assert_eq!(
        only_item(&[start]),
        ItemKind::AgentMessage {
            from: "Sib1".into(),
            body: "hi".into(),
            task_id: None
        }
    );
}

#[test]
fn f1_peer_origin_still_finds_an_inner_wrapper() {
    let line = r#"{"type":"user","uuid":"u1","isMeta":true,"origin":{"kind":"peer"},"message":{"content":"Another Claude session sent a message:\n<cross-session-message from-name=\"Lead\">go</cross-session-message>"}}"#;
    assert_eq!(
        only_item(&[line]),
        ItemKind::AgentMessage {
            from: "Lead".into(),
            body: "go".into(),
            task_id: None
        }
    );
}

// F2: shell / local-command output is a notice, never a human item; `!` input stays a user item.
#[test]
fn f2_command_output_is_a_notice() {
    for content in [
        r#"<bash-stdout>ok</bash-stdout><bash-stderr></bash-stderr>"#,
        r#"<bash-stderr>boom</bash-stderr>"#,
        r#"<local-command-stdout>Set model to opus</local-command-stdout>"#,
    ] {
        let line = format!(
            r#"{{"type":"user","uuid":"u1","message":{{"content":{}}}}}"#,
            serde_json::to_string(content).unwrap()
        );
        let ItemKind::Notice { notice, body, .. } = only_item(&[&line]) else {
            panic!("{content} is not a notice")
        };
        assert_eq!(notice, NoticeKind::CommandOutput, "{content}");
        assert!(!body.contains("<bash-"), "body keeps tags: {body}");
    }
    let s = session(&[
        r#"{"type":"user","uuid":"u1","message":{"content":"<bash-stdout>hello\nworld</bash-stdout><bash-stderr>warn</bash-stderr>"}}"#,
    ]);
    let ItemKind::Notice { summary, body, .. } = &s.items[0].kind else {
        panic!()
    };
    assert_eq!(summary, "hello");
    assert_eq!(body, "hello\nworld\nwarn");
}

#[test]
fn f2_bash_input_stays_a_user_item() {
    let line = r#"{"type":"user","uuid":"u1","message":{"content":"<bash-input>git status</bash-input>"}}"#;
    assert!(matches!(only_item(&[line]), ItemKind::UserText { .. }));
}

// F3: redacted (empty) thinking makes no item.
#[test]
fn f3_empty_thinking_makes_no_item() {
    let s = session(&[
        r#"{"type":"assistant","uuid":"a1","message":{"id":"m","content":[{"type":"thinking","thinking":"","signature":"abc"}]}}"#,
        r#"{"type":"assistant","uuid":"a2","message":{"id":"m","content":[{"type":"thinking","thinking":"  \n ","signature":"abc"}]}}"#,
        r#"{"type":"assistant","uuid":"a3","message":{"id":"m","content":[{"type":"thinking","thinking":"real","signature":"abc"}]}}"#,
    ]);
    assert_eq!(s.items.len(), 1, "{:?}", s.items);
    assert!(matches!(&s.items[0].kind, ItemKind::Thinking { text, .. } if text == "real"));
}

// F4: two configured roots where one slug is a dash-prefix of the other.
#[test]
fn f4_longest_configured_root_wins_over_dash_prefix_root() {
    let spec = |name: &str, root: &str| ProjectSpec {
        name: name.into(),
        root: root.into(),
        worktree_roots: vec![],
        gallery: vec![],
        exact: false,
    };
    for ps in [
        vec![
            spec("obs", "/home/u/observatory"),
            spec("old", "/home/u/observatory-old-copy"),
        ],
        vec![
            spec("old", "/home/u/observatory-old-copy"),
            spec("obs", "/home/u/observatory"),
        ],
    ] {
        let p = |slug: &str| project_for_slug(slug, &ps).map(|p| p.name.clone());
        assert_eq!(p("-home-u-observatory-old-copy").as_deref(), Some("old"));
        assert_eq!(
            p("-home-u-observatory-old-copy-sub").as_deref(),
            Some("old")
        );
        assert_eq!(p("-home-u-observatory").as_deref(), Some("obs"));
        assert_eq!(p("-home-u-observatory-src").as_deref(), Some("obs"));
    }
}

// Minor a: a bare hex task id is a subagent, the id kept separately.
#[test]
fn minor_a_hex_from_is_a_subagent() {
    let line = r#"{"type":"user","uuid":"u1","isMeta":true,"origin":{"kind":"peer"},"message":{"content":"Another Claude session sent a message:\n<agent-message from=\"a7c3e9f1b5d2486ce\">\n[Subagent hand-back] done\n</agent-message>"}}"#;
    assert_eq!(
        only_item(&[line]),
        ItemKind::AgentMessage {
            from: "subagent".into(),
            body: "[Subagent hand-back] done".into(),
            task_id: Some("a7c3e9f1b5d2486ce".into())
        }
    );
    // A real name that happens to be short hex-looking letters stays a name.
    let named = r#"{"type":"user","uuid":"u2","origin":{"kind":"peer"},"message":{"content":"<agent-message from=\"Bead\">x</agent-message>"}}"#;
    assert!(
        matches!(only_item(&[named]), ItemKind::AgentMessage { from, task_id: None, .. } if from == "Bead")
    );
    let facade = r#"{"type":"user","uuid":"u3","origin":{"kind":"peer"},"message":{"content":"<agent-message from=\"facade\">x</agent-message>"}}"#;
    assert!(
        matches!(only_item(&[facade]), ItemKind::AgentMessage { from, task_id: None, .. } if from == "facade")
    );
}

// Minor b: the `<synthetic>` model placeholder never replaces the real model.
#[test]
fn minor_b_synthetic_model_is_ignored() {
    let s = session(&[
        r#"{"type":"assistant","uuid":"a1","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"hi"}]}}"#,
        r#"{"type":"assistant","uuid":"a2","message":{"id":"m2","model":"<synthetic>","content":[{"type":"text","text":"API error"}]}}"#,
    ]);
    assert_eq!(s.meta.model.as_deref(), Some("claude-opus-5-5"));
}
