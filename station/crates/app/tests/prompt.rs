//! The prompt box: when it is on, what Enter / Shift+Enter / the button do, what a reply does,
//! and that nothing is ever sent except by the human. Requests go to an in-memory pipe
//! (`LiveSource::attach_input`); no bridge, no tmux, no agent.

use std::io::{Cursor, Write};
use std::sync::{Arc, Mutex};

use egui::accesskit::Role as AkRole;
use egui::{Key, Modifiers, Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use observatory_app::bridge::{Conn, Launch, LiveSource, Repaint, pump};
use observatory_app::live::{LiveState, Seats, target_of, utc_offset};
use observatory_app::model::{Agent, Role, Status, Target};
use observatory_app::prompt::{
    self, BUSY_NOTE, DEMO_NOTE, LOST_NOTE, UNCERTAIN_NOTE, availability,
};
use observatory_app::{Clock, ObservatoryApp};
use observatory_core::session::SessionMeta;
use observatory_core::wire::{PROTOCOL, Request, SendResult};
use observatory_core::{Activity, Frame, Liveness, Session, Thread};

/// 2026-11-23 18:00:00 UTC.
const NOW: i64 = 1_795_456_800;
const PROJECT: &str = "my-app";

fn session(id: &str, agent: &str, min_ago: i64, tmux: bool) -> Session {
    let mut s = Session::new("-home-u-proj", id);
    s.meta = SessionMeta {
        session_id: id.into(),
        slug: "-home-u-proj".into(),
        agent_name: Some(agent.into()),
        model: Some("claude-opus-5-5".into()),
        permission_mode: Some("auto".into()),
        first_activity_ms: Some((NOW - min_ago * 60) * 1000),
        last_activity_ms: Some((NOW - min_ago * 60) * 1000),
        ..Default::default()
    };
    s.status.liveness = Liveness::Running;
    s.status.tmux = tmux;
    s
}

fn full(s: &Session) -> String {
    Frame::Session {
        project: PROJECT.into(),
        session: Box::new(s.clone()),
    }
    .to_line()
}

fn hello() -> String {
    Frame::Hello {
        protocol: PROTOCOL,
        distro: None,
        note: None,
        seats: Vec::new(),
    }
    .to_line()
}

fn reply(id: u64, result: SendResult) -> String {
    Frame::SendResult { id, result }.to_line()
}

/// What the app wrote on the "bridge's stdin".
#[derive(Clone, Default)]
struct Sink(Arc<Mutex<Vec<u8>>>);

impl Write for Sink {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Sink {
    fn requests(&self) -> Vec<Request> {
        String::from_utf8(self.0.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(|l| Request::from_line(l).unwrap())
            .collect()
    }
}

fn noop() -> Repaint {
    Arc::new(|| {})
}

fn feed(src: &LiveSource, lines: &[String]) {
    // Read the epoch first: a guard inside the call's arguments would live through `pump`.
    let epoch = src.shared.lock().unwrap().epoch;
    pump(
        Cursor::new(lines.join("\n") + "\n"),
        &src.shared,
        &noop(),
        epoch,
    );
}

/// Ada (tmux, idle), Bob (running, not in tmux), Cy (tmux, mid-turn): a live source with them.
fn scenario() -> Vec<String> {
    let ada = session("sid-ada", "Ada", 1, true);
    let bob = session("sid-bob", "Bob", 2, false);
    let mut cy = session("sid-cy", "Cy", 3, true);
    cy.status.activity = Activity::Working;
    cy.status.working_since_ms = Some((NOW - 30) * 1000);
    vec![hello(), full(&ada), full(&bob), full(&cy)]
}

fn live_harness() -> (Harness<'static, ObservatoryApp>, Sink) {
    let src = LiveSource::idle(Launch::for_platform(None), noop());
    feed(&src, &scenario());
    let sink = Sink::default();
    src.attach_input(sink.clone());
    let app = ObservatoryApp::live(src, Seats::parse(""), utc_offset, Clock::Fixed(NOW));
    (harness(app), sink)
}

fn harness(app: ObservatoryApp) -> Harness<'static, ObservatoryApp> {
    let mut h = Harness::builder()
        .with_size(vec2(900.0, 560.0))
        .with_theme(Theme::Dark)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    h
}

fn select(h: &mut Harness<'static, ObservatoryApp>, name: &str) {
    h.get_by_label_contains(&format!("{name}, sibling")).click();
    h.run();
}

fn type_into_box(h: &mut Harness<'static, ObservatoryApp>, text: &str) {
    h.get_by_role(AkRole::MultilineTextInput).focus();
    h.run();
    h.get_by_role(AkRole::MultilineTextInput).type_text(text);
    h.run();
}

fn draft(h: &Harness<'static, ObservatoryApp>, agent: &str) -> String {
    h.state().prompt.draft(PROJECT, agent).to_owned()
}

fn src<'a>(h: &'a Harness<'static, ObservatoryApp>) -> &'a LiveSource {
    &h.state().live.as_ref().unwrap().source
}

// ------------------------------------------------------------------ when the box is on

fn agent(name: &str, status: Status, target: Target) -> Agent {
    Agent {
        name: name.into(),
        role: Role::Sibling,
        status,
        last_activity: None,
        model: None,
        permission_mode: None,
        turn_started: None,
        items: vec![],
        pages: vec![],
        target,
    }
}

#[test]
fn availability_says_why_or_where() {
    let tmux = Target::Tmux {
        session_id: "s1".into(),
    };
    let a = agent("Ada", Status::Idle, tmux.clone());
    assert_eq!(availability(Some(&Conn::Live), &a), Ok("s1".into()));
    assert_eq!(
        availability(
            Some(&Conn::Live),
            &agent("Ada", Status::Working, tmux.clone())
        ),
        Ok("s1".into()),
        "a busy agent can be typed to (the message queues)"
    );
    let why = availability(
        Some(&Conn::Live),
        &agent("Ada", Status::NeedsYou, tmux.clone()),
    )
    .unwrap_err();
    assert!(
        why.contains("Ada is waiting for you in its terminal"),
        "an open question would swallow the paste and the Enter: {why}"
    );
    assert_eq!(availability(None, &a), Err(DEMO_NOTE.into()));
    for c in [Conn::Connecting, Conn::Failed("x".into())] {
        assert_eq!(
            availability(Some(&c), &a),
            Err("Not connected to the bridge.".into())
        );
    }
    assert_eq!(
        availability(Some(&Conn::Live), &agent("Ada", Status::Gone, tmux)),
        Err("Ada has no live session.".into())
    );
    assert_eq!(
        availability(
            Some(&Conn::Live),
            &agent("Ada", Status::Idle, Target::NoLiveSession)
        ),
        Err("Ada has no live session.".into())
    );
    assert!(
        availability(
            Some(&Conn::Live),
            &agent("Ada", Status::Idle, Target::NotInTmux)
        )
        .unwrap_err()
        .contains("isn't running in tmux")
    );
}

#[test]
fn target_is_the_newest_live_tmux_session_of_the_thread() {
    let mut old = session("old", "Ada", 9, true);
    let mut new = session("new", "Ada", 1, true);
    let t = |s: Vec<Session>| Thread { sessions: s };
    assert_eq!(
        target_of(&t(vec![old.clone(), new.clone()])),
        Target::Tmux {
            session_id: "new".into()
        }
    );
    new.status.liveness = Liveness::Gone;
    assert_eq!(
        target_of(&t(vec![old.clone(), new.clone()])),
        Target::Tmux {
            session_id: "old".into()
        },
        "a gone session is never the target"
    );
    old.status.tmux = false;
    assert_eq!(
        target_of(&t(vec![old.clone(), new.clone()])),
        Target::NotInTmux
    );
    old.status.liveness = Liveness::Gone;
    assert_eq!(target_of(&t(vec![old, new])), Target::NoLiveSession);
}

#[test]
fn the_model_carries_the_target_from_the_frames() {
    let mut st = LiveState::default();
    for l in scenario() {
        st.apply_line(&l);
    }
    let vm = st.view_model(&Seats::parse(""), NOW, utc_offset);
    let targets: Vec<(&str, &Target)> = vm.projects[0]
        .agents
        .iter()
        .map(|a| (a.name.as_str(), &a.target))
        .collect();
    assert_eq!(
        targets,
        [
            (
                "Ada",
                &Target::Tmux {
                    session_id: "sid-ada".into()
                }
            ),
            ("Bob", &Target::NotInTmux),
            (
                "Cy",
                &Target::Tmux {
                    session_id: "sid-cy".into()
                }
            ),
        ]
    );
}

// ------------------------------------------------------------------ sending

#[test]
fn enter_sends_once_to_the_live_session_with_the_exact_text() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    h.get_by_label("Send to Ada");
    type_into_box(&mut h, "hello Ada");
    assert!(sink.requests().is_empty(), "typing sends nothing");
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(
        sink.requests(),
        vec![Request::Send {
            id: 1,
            session_id: "sid-ada".into(),
            text: "hello Ada".into()
        }]
    );
    assert_eq!(h.state().prompt.sends, 1);
    assert_eq!(
        draft(&h, "Ada"),
        "hello Ada",
        "kept until the bridge says sent"
    );
    h.get_by_label(prompt::SENDING_NOTE);
}

#[test]
fn shift_enter_is_a_new_line_and_sends_nothing() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "line one");
    h.key_press_modifiers(Modifiers::SHIFT, Key::Enter);
    h.run();
    h.get_by_role(AkRole::MultilineTextInput)
        .type_text("line two");
    h.run();
    assert!(sink.requests().is_empty());
    assert_eq!(draft(&h, "Ada"), "line one\nline two");
    h.key_press(Key::Enter);
    h.run();
    let r = sink.requests();
    assert_eq!(r.len(), 1);
    let Request::Send { text, .. } = &r[0];
    assert_eq!(
        text, "line one\nline two",
        "multi-line arrives as one message"
    );
}

#[test]
fn one_enter_is_at_most_one_send() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "once");
    // Two Enter presses in ONE frame (a double event), then the button in the same frame.
    h.key_press(Key::Enter);
    h.key_press(Key::Enter);
    h.step();
    h.run();
    assert_eq!(
        sink.requests().len(),
        1,
        "double Enter in a frame = one send"
    );
    // While it waits for the answer: Enter and the button do nothing.
    h.key_press(Key::Enter);
    h.run();
    h.get_by_label("Send to Ada").click();
    h.run();
    assert_eq!(sink.requests().len(), 1, "nothing more while waiting");
    assert_eq!(h.state().prompt.sends, 1);
}

#[test]
fn the_button_sends_too() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "by click");
    h.get_by_label("Send to Ada").click();
    h.run();
    assert_eq!(sink.requests().len(), 1);
}

#[test]
fn sent_clears_the_box() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "go");
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(sink.requests().len(), 1);
    feed(src(&h), &[reply(1, SendResult::Sent)]);
    h.run();
    assert_eq!(draft(&h, "Ada"), "");
    assert!(!h.state().prompt.is_pending());
    // An empty box never sends.
    h.get_by_role(AkRole::MultilineTextInput).focus();
    h.run();
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(sink.requests().len(), 1);
}

#[test]
fn snapshot_refused_keeps_the_text_and_shows_why() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "keep me");
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(sink.requests().len(), 1);
    let why = "This agent isn't running in a tmux pane.";
    feed(
        src(&h),
        &[reply(1, SendResult::Refused { reason: why.into() })],
    );
    h.run();
    assert_eq!(draft(&h, "Ada"), "keep me");
    assert_eq!(h.state().prompt.note(PROJECT, "Ada"), Some(why));
    h.get_by_label(why);
    // Sending again is the human's choice, and works.
    h.get_by_label("Send to Ada").click();
    h.run();
    assert_eq!(sink.requests().len(), 2);
    feed(
        src(&h),
        &[reply(2, SendResult::Refused { reason: why.into() })],
    );
    h.run();
    h.snapshot("prompt_refused_dark");
}

#[test]
fn a_restarted_connection_loses_the_answer_and_keeps_the_text() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "in flight");
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(sink.requests().len(), 1);
    // A retry: new epoch, the old answer can never land.
    src(&h).shared.lock().unwrap().epoch += 1;
    h.run();
    assert_eq!(draft(&h, "Ada"), "in flight");
    assert_eq!(h.state().prompt.note(PROJECT, "Ada"), Some(LOST_NOTE));
    assert_eq!(sink.requests().len(), 1, "never re-sent by itself");
}

#[test]
fn bad_text_is_refused_in_the_app_and_never_written() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "   ");
    h.key_press(Key::Enter);
    h.run();
    assert!(sink.requests().is_empty());
    assert_eq!(
        h.state().prompt.note(PROJECT, "Ada"),
        Some("The message is empty.")
    );
}

// ------------------------------------------------------------------ never on its own

#[test]
fn nothing_sends_on_startup_replay_reconnect_focus_or_restart() {
    let (mut h, sink) = live_harness();
    // Startup + settling.
    for _ in 0..5 {
        h.step();
    }
    // A draft exists, the box has focus, then focus moves away and back, agents switch.
    select(&mut h, "Ada");
    type_into_box(&mut h, "draft only");
    select(&mut h, "Cy");
    select(&mut h, "Ada");
    h.get_by_role(AkRole::MultilineTextInput).focus();
    h.run();
    // Replay: the same frames again; reconnect: a fresh hello and everything again.
    feed(src(&h), &scenario());
    h.run();
    feed(src(&h), &scenario()[..1]);
    feed(src(&h), &scenario());
    h.run();
    // An Enter while the box is NOT focused (Ada's draft is there, focus is on the sidebar):
    // nothing.
    h.get_by_label_contains("Ada, sibling").click();
    h.run();
    assert_eq!(
        draft(&h, "Ada"),
        "draft only",
        "non-vacuity: a sendable draft is shown"
    );
    h.key_press(Key::Enter);
    h.run();
    assert!(sink.requests().is_empty(), "{:?}", sink.requests());
    assert_eq!(h.state().prompt.sends, 0);
    // App restart: a fresh app over the same source holds no draft and sends nothing.
    let app = h.into_state();
    let source = app.live.unwrap().source;
    let fresh = ObservatoryApp::live(source, Seats::parse(""), utc_offset, Clock::Fixed(NOW));
    let mut h2 = harness(fresh);
    for _ in 0..5 {
        h2.step();
    }
    assert!(sink.requests().is_empty());
    assert_eq!(draft(&h2, "Ada"), "");
}

// ------------------------------------------------------------------ states

#[test]
fn snapshot_enabled() {
    let (mut h, _) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "Please rerun the gate");
    h.snapshot("prompt_enabled_dark");
}

#[test]
fn snapshot_disabled_with_reason() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Bob");
    h.get_by_label("Bob isn't running in tmux, so it can't be typed to from here.");
    h.get_by_label("Send to Bob").click();
    h.run();
    h.key_press(Key::Enter);
    h.run();
    assert!(sink.requests().is_empty(), "a disabled box sends nothing");
    h.snapshot("prompt_disabled_dark");
}

#[test]
fn a_busy_agent_says_the_message_will_queue() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Cy");
    h.get_by_label(BUSY_NOTE);
    type_into_box(&mut h, "after this turn");
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(
        sink.requests().len(),
        1,
        "busy still sends: it queues there"
    );
}

#[test]
fn a_gone_agent_or_lost_bridge_turns_the_box_off() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    feed(
        src(&h),
        &[Frame::Gone {
            session_id: "sid-ada".into(),
        }
        .to_line()],
    );
    h.run();
    h.get_by_label("Ada has no live session.");
    src(&h).shared.lock().unwrap().conn = Conn::Failed("gone".into());
    src(&h).shared.lock().unwrap().generation += 1;
    h.run();
    h.get_by_label("Not connected to the bridge.");
    h.get_by_label("Send to Ada").click();
    h.run();
    assert!(sink.requests().is_empty());
}

#[test]
fn source_send_refuses_without_a_live_connection() {
    let src = LiveSource::idle(Launch::for_platform(None), noop());
    let sink = Sink::default();
    src.attach_input(sink.clone());
    assert!(src.send("s", "x").is_err(), "connecting: refused");
    feed(&src, &scenario()[..1]);
    assert!(src.send("s", "x").is_ok());
    assert_eq!(sink.requests().len(), 1);
}

// ------------------------------------------------------------------ more cases

#[test]
fn snapshot_uncertain_keeps_the_text_and_says_check_first() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    type_into_box(&mut h, "maybe typed");
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(sink.requests().len(), 1);
    let reason = "The agent changed while sending: This agent has no live session right now.";
    feed(
        src(&h),
        &[reply(
            1,
            SendResult::Uncertain {
                reason: reason.into(),
            },
        )],
    );
    h.run();
    assert_eq!(
        draft(&h, "Ada"),
        "maybe typed",
        "kept: it may not have arrived"
    );
    let note = h.state().prompt.note(PROJECT, "Ada").unwrap().to_owned();
    assert!(
        note.starts_with(UNCERTAIN_NOTE) && note.contains(reason),
        "{note}"
    );
    assert!(!h.state().prompt.is_pending());
    h.get_by_label_contains("Uncertain: the text may be in the agent's box");
    // The long note wraps: the button stays inside the window.
    let b = h.get_by_label("Send to Ada").rect();
    assert!(
        b.max.x <= 900.0 && b.max.y <= 560.0,
        "button pushed off: {b:?}"
    );
    assert_eq!(sink.requests().len(), 1, "never re-sent by itself");
    // The whole note is on screen in the frame the answer arrived (no extra frames).
    let n = h
        .get_by_label_contains("Uncertain: the text may be in the agent's box")
        .rect();
    assert!(n.max.y <= 552.0, "note clipped at the bottom: {n:?}");
    h.snapshot("prompt_uncertain_dark");
}

#[test]
fn control_characters_are_refused_in_the_app_and_never_written() {
    let (mut h, sink) = live_harness();
    select(&mut h, "Ada");
    for (i, text) in [
        "ends paste \u{1b}[201~ then keys",
        "early\rsubmit",
        "bell\u{7}",
    ]
    .into_iter()
    .enumerate()
    {
        h.state_mut().prompt.set_draft(PROJECT, "Ada", text);
        h.get_by_role(AkRole::MultilineTextInput).focus();
        h.run();
        h.key_press(Key::Enter);
        h.run();
        let note = h.state().prompt.note(PROJECT, "Ada").map(str::to_owned);
        assert!(
            note.as_deref()
                .is_some_and(|n| n.contains("control character")),
            "case {i}: {note:?}"
        );
        assert_eq!(draft(&h, "Ada"), text, "case {i}: text kept");
    }
    assert!(sink.requests().is_empty(), "{:?}", sink.requests());
    assert_eq!(h.state().prompt.sends, 0);
    // Non-vacuity: a clean text in the same box does go out.
    h.state_mut()
        .prompt
        .set_draft(PROJECT, "Ada", "clean\twith tab");
    h.get_by_role(AkRole::MultilineTextInput).focus();
    h.run();
    h.key_press(Key::Enter);
    h.run();
    assert_eq!(sink.requests().len(), 1);
}
