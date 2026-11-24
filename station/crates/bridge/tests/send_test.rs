//! Typing: target resolution (`tmux::resolve`) and the bridge's request handling, with a
//! fake terminal that records what would be typed. No tmux, no real agent.

mod common;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use common::*;
use observatory_bridge::bridge::Bridge;
use observatory_bridge::liveness::LiveProc;
use observatory_bridge::tmux::{self, Pane, Terminal};
use observatory_core::wire::{Frame, Request, SendResult};

/// A process tree: pid → parent.
fn tree(edges: &[(u32, u32)]) -> impl Fn(u32) -> Option<u32> + 'static {
    let m: HashMap<u32, u32> = edges.iter().copied().collect();
    move |p| m.get(&p).copied()
}

fn proc_(pid: u32, sid: &str, name: &str, tmux: Option<&str>) -> LiveProc {
    LiveProc {
        pid,
        session_id: Some(sid.into()),
        name: Some(name.into()),
        // A live, idle agent unless a test says otherwise: only a known status may be typed into.
        status: Some("idle".into()),
        tmux: tmux.map(str::to_owned),
        ..Default::default()
    }
}

fn pane(id: &str, pid: u32) -> Pane {
    Pane { id: id.into(), pid }
}

// Two panes: %1 (shell 100 → claude 101 "A"), %2 (shell 200 → claude 201 "B").
fn two_agents() -> (Vec<LiveProc>, Vec<Pane>, impl Fn(u32) -> Option<u32>) {
    (
        vec![
            proc_(101, "sid-a", "A", Some("s:@1.%1")),
            proc_(201, "sid-b", "B", Some("s:@2.%2")),
        ],
        vec![pane("%1", 100), pane("%2", 200)],
        tree(&[(101, 100), (100, 50), (201, 200), (200, 50), (50, 1)]),
    )
}

#[test]
fn one_match_resolves_by_process_tree() {
    let (procs, panes, parent) = two_agents();
    let t = tmux::resolve("sid-b", &procs, &panes, &parent).unwrap();
    assert_eq!((t.pane.as_str(), t.pid), ("%2", 201));
    let t = tmux::resolve("sid-a", &procs, &panes, &parent).unwrap();
    assert_eq!(t.pane, "%1");
}

#[test]
fn an_agent_waiting_on_a_question_is_refused() {
    let (mut procs, panes, parent) = two_agents();
    procs[1].status = Some("busy".into());
    assert!(
        tmux::resolve("sid-b", &procs, &panes, &parent).is_ok(),
        "busy is fine (queued)"
    );
    procs[1].status = Some("waiting".into());
    procs[1].waiting_for = Some("input needed".into());
    let why = tmux::resolve("sid-b", &procs, &panes, &parent).unwrap_err();
    assert!(
        why.contains("waiting for you") && why.contains("input needed"),
        "{why}"
    );
    procs[1].waiting_for = None; // waiting with no detail still refuses
    assert!(tmux::resolve("sid-b", &procs, &panes, &parent).is_err());
    // The other agent is unaffected.
    assert!(tmux::resolve("sid-a", &procs, &panes, &parent).is_ok());
}

#[test]
fn only_a_known_idle_busy_or_shell_status_may_be_typed_into() {
    let (mut procs, panes, parent) = two_agents();
    // `shell`: a shell command runs beside the open prompt (see liveness::SENDABLE).
    for ok in ["idle", "busy", "shell"] {
        procs[1].status = Some(ok.into());
        assert!(
            tmux::resolve("sid-b", &procs, &panes, &parent).is_ok(),
            "{ok}"
        );
    }
    procs[1].status = None;
    let why = tmux::resolve("sid-b", &procs, &panes, &parent).unwrap_err();
    assert!(why.contains("no status"), "{why}");
    for odd in ["frobnicate", "", "IDLE", "idle "] {
        procs[1].status = Some(odd.into());
        let why = tmux::resolve("sid-b", &procs, &panes, &parent).unwrap_err();
        assert!(why.contains("unknown status"), "{odd:?}: {why}");
    }
    // The other agent is unaffected.
    assert!(tmux::resolve("sid-a", &procs, &panes, &parent).is_ok());
}

#[test]
fn deeper_descendant_still_resolves() {
    // claude under a wrapper shell under the pane shell.
    let procs = vec![proc_(303, "sid", "A", None)];
    let panes = vec![pane("%7", 300)];
    let parent = tree(&[(303, 302), (302, 300), (300, 1)]);
    assert_eq!(
        tmux::resolve("sid", &procs, &panes, &parent).unwrap().pane,
        "%7"
    );
}

#[test]
fn zero_panes_is_refused() {
    let procs = vec![proc_(101, "sid-a", "A", None)];
    let panes = vec![pane("%1", 900)]; // another process tree
    let parent = tree(&[(101, 100), (100, 1)]);
    let e = tmux::resolve("sid-a", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("isn't running in a tmux pane"), "{e}");
}

#[test]
fn two_panes_is_refused() {
    // Nested tmux: both pane shells sit on the chain.
    let procs = vec![proc_(101, "sid-a", "A", None)];
    let panes = vec![pane("%1", 100), pane("%9", 90)];
    let parent = tree(&[(101, 100), (100, 95), (95, 90), (90, 1)]);
    let e = tmux::resolve("sid-a", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("2 tmux panes"), "{e}");
}

#[test]
fn no_live_session_is_refused_and_stale_pids_never_count() {
    let (procs, panes, parent) = two_agents();
    // A stale registry entry is dropped by `liveness::scan` (start-time check, read_only.rs);
    // what reaches resolve is only the live list, so a session absent from it is refused.
    let e = tmux::resolve("sid-gone", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("no live session"), "{e}");
    let e = tmux::resolve("sid-a", &[], &panes, &parent).unwrap_err();
    assert!(e.contains("no live session"), "{e}");
}

#[test]
fn two_live_processes_for_one_session_is_refused() {
    let (mut procs, panes, parent) = two_agents();
    procs.push(proc_(201, "sid-a", "A", None));
    let e = tmux::resolve("sid-a", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("2 live processes"), "{e}");
}

#[test]
fn never_by_name_a_same_named_agent_elsewhere_is_not_the_target() {
    // Two processes named "Sib1" (another project's, and ours): only the session id decides.
    let procs = vec![
        proc_(101, "theirs", "Sib1", Some("s:@1.%1")),
        proc_(201, "ours", "Sib1", Some("s:@2.%2")),
    ];
    let panes = vec![pane("%1", 100), pane("%2", 200)];
    let parent = tree(&[(101, 100), (201, 200)]);
    assert_eq!(
        tmux::resolve("ours", &procs, &panes, &parent).unwrap().pane,
        "%2"
    );
    // A name-only process (no registry) never resolves to a send target.
    let fallback = vec![LiveProc {
        pid: 201,
        name: Some("Sib1".into()),
        ..Default::default()
    }];
    assert!(tmux::resolve("Sib1", &fallback, &panes, &parent).is_err());
}

#[test]
fn pane_of_another_agent_is_refused() {
    // B runs under A's pane: typing into %1 could reach either.
    let procs = vec![
        proc_(101, "sid-a", "A", None),
        proc_(102, "sid-b", "B", None),
    ];
    let panes = vec![pane("%1", 100)];
    let parent = tree(&[(101, 100), (102, 101), (100, 1)]);
    let e = tmux::resolve("sid-a", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("also holds B"), "{e}");
    let e = tmux::resolve("sid-b", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("also holds A"), "{e}");
}

#[test]
fn registry_pane_disagreeing_with_the_tree_is_refused() {
    let (mut procs, panes, parent) = two_agents();
    procs[0].tmux = Some("s:@2.%2".into()); // claims B's pane
    let e = tmux::resolve("sid-a", &procs, &panes, &parent).unwrap_err();
    assert!(e.contains("but its process is in pane %1"), "{e}");
}

// ------------------------------------------------------------------ the bridge's requests

#[derive(Default)]
struct Log {
    /// Pane lists handed out (so a test can change them between sends).
    panes: Vec<Pane>,
    lists: usize,
    /// Buffers loaded: name → text.
    loaded: HashMap<String, String>,
    /// (pane, text, buffer) per paste.
    typed: Vec<(String, String, String)>,
    /// Panes that got an Enter.
    enters: Vec<String>,
    /// Every step, in order (`load`, `discard`, `paste`, `enter`).
    steps: Vec<&'static str>,
    /// This step fails (after being recorded).
    fail_at: Option<&'static str>,
    /// What the pane shows, and an error the screen read returns instead (if set). Reads are
    /// counted, not recorded in `steps`, so the step lists of the other tests stay as they were.
    screen: String,
    screen_error: Option<String>,
    screen_reads: usize,
}

/// Runs once, right AFTER the named step (to change the world between steps).
type Hook = Rc<RefCell<Option<(&'static str, Box<dyn FnMut()>)>>>;

#[derive(Clone, Default)]
struct Fake(Rc<RefCell<Log>>, Hook);

impl Fake {
    fn step(&mut self, name: &'static str) -> Result<(), String> {
        let fail = {
            let mut l = self.0.borrow_mut();
            l.steps.push(name);
            l.fail_at == Some(name)
        };
        let due = self.1.borrow().as_ref().is_some_and(|(n, _)| *n == name);
        if due {
            let (_, mut f) = self.1.borrow_mut().take().unwrap();
            f();
        }
        if fail {
            Err(format!("tmux refused: {name} failed"))
        } else {
            Ok(())
        }
    }
    fn after(&self, name: &'static str, f: impl FnMut() + 'static) {
        *self.1.borrow_mut() = Some((name, Box::new(f)));
    }
}

impl Terminal for Fake {
    fn panes(&mut self) -> Result<Vec<Pane>, String> {
        let mut l = self.0.borrow_mut();
        l.lists += 1;
        Ok(l.panes.clone())
    }
    fn load(&mut self, buffer: &str, text: &str) -> Result<(), String> {
        self.0
            .borrow_mut()
            .loaded
            .insert(buffer.into(), text.into());
        self.step("load")
    }
    fn discard(&mut self, buffer: &str) {
        self.0.borrow_mut().loaded.remove(buffer);
        let _ = self.step("discard");
    }
    fn paste(&mut self, pane: &str, buffer: &str) -> Result<(), String> {
        {
            let mut l = self.0.borrow_mut();
            let text = l.loaded.remove(buffer).expect("paste of a loaded buffer");
            l.typed.push((pane.into(), text, buffer.into()));
        }
        self.step("paste")
    }
    fn enter(&mut self, pane: &str) -> Result<(), String> {
        self.0.borrow_mut().enters.push(pane.into());
        self.step("enter")
    }
    fn screen(&mut self, _pane: &str) -> Result<String, String> {
        let mut l = self.0.borrow_mut();
        l.screen_reads += 1;
        match &l.screen_error {
            Some(e) => Err(e.clone()),
            None => Ok(l.screen.clone()),
        }
    }
}

type Procs = Rc<RefCell<Vec<LiveProc>>>;
type Edges = Rc<RefCell<HashMap<u32, u32>>>;

fn setup() -> (Bridge<Vec<u8>>, Fake, Procs, Edges) {
    let c = claude_tree("send");
    let (procs, panes, _) = two_agents();
    let procs: Procs = Rc::new(RefCell::new(procs));
    let edges: Edges = Rc::new(RefCell::new(
        [(101, 100), (100, 50), (201, 200), (200, 50), (50, 1)]
            .into_iter()
            .collect(),
    ));
    let fake = Fake::default();
    fake.0.borrow_mut().panes = panes;
    // The agent's pane shows Claude Code's idle input box unless a test says otherwise.
    fake.0.borrow_mut().screen = idle_box();
    let p = procs.clone();
    let e = edges.clone();
    let b = Bridge::new(cfg(0), c, Vec::new())
        .with_scan(move |_| Some(p.borrow().clone()))
        .with_terminal(fake.clone(), move |pid| e.borrow().get(&pid).copied());
    (b, fake, procs, edges)
}

fn send_line(id: u64, sid: &str, text: &str) -> String {
    Request::Send {
        id,
        session_id: sid.into(),
        text: text.into(),
    }
    .to_line()
}

fn replies(b: &mut Bridge<Vec<u8>>) -> Vec<Frame> {
    b.drain_output()
        .iter()
        .map(|l| Frame::from_line(l).unwrap())
        .collect()
}

#[test]
fn a_send_types_once_and_answers_sent_with_its_id() {
    let (mut b, fake, _, _) = setup();
    let text = "multi\nline \"quoted\" $(x) `y`; /slash ✓";
    b.on_request_line(&send_line(7, "sid-b", text)).unwrap();
    assert_eq!(
        replies(&mut b),
        vec![Frame::SendResult {
            id: 7,
            result: SendResult::Sent
        }]
    );
    let l = fake.0.borrow();
    assert_eq!(l.typed.len(), 1, "exactly one delivery");
    assert_eq!(l.typed[0].0, "%2");
    assert_eq!(l.typed[0].1, text, "text untouched");
    assert!(l.typed[0].2.ends_with("-7"), "buffer named per request");
    assert_eq!(l.enters, ["%2"], "exactly one Enter, same pane");
    assert_eq!(l.steps, ["load", "paste", "enter"]);
}

#[test]
fn a_refused_send_types_nothing_and_says_why() {
    let (mut b, fake, procs, _) = setup();
    procs.borrow_mut().clear(); // the agent stopped
    b.on_request_line(&send_line(3, "sid-a", "hi")).unwrap();
    let out = replies(&mut b);
    let [
        Frame::SendResult {
            id: 3,
            result: SendResult::Refused { reason },
        },
    ] = out.as_slice()
    else {
        panic!("{out:?}")
    };
    assert!(reason.contains("no live session"), "{reason}");
    assert!(fake.0.borrow().typed.is_empty());
}

#[test]
fn bad_text_is_refused_before_tmux_is_asked() {
    let (mut b, fake, _, _) = setup();
    for (id, text) in [
        (1, ""),
        (2, "  \n "),
        (3, "end paste \u{1b}[201~ then keys"),
        (4, "early\rsubmit"),
    ] {
        b.on_request_line(&send_line(id, "sid-a", text)).unwrap();
    }
    let out = replies(&mut b);
    assert_eq!(out.len(), 4);
    assert!(out.iter().all(|f| matches!(
        f,
        Frame::SendResult {
            result: SendResult::Refused { .. },
            ..
        }
    )));
    let l = fake.0.borrow();
    assert!(l.typed.is_empty());
    assert_eq!(l.lists, 0, "rejected before any tmux call");
}

#[test]
fn the_pane_is_resolved_at_every_send_never_cached() {
    let (mut b, fake, procs, edges) = setup();
    b.on_request_line(&send_line(1, "sid-a", "one")).unwrap();
    // A restarts: new pid 401 in a new pane %4 (shell 400); %1 now holds only a shell.
    {
        let mut p = procs.borrow_mut();
        p[0].pid = 401;
        p[0].tmux = Some("s:@4.%4".into());
        edges.borrow_mut().extend([(401, 400), (400, 50)]);
        fake.0.borrow_mut().panes.push(pane("%4", 400));
    }
    b.on_request_line(&send_line(2, "sid-a", "two")).unwrap();
    let l = fake.0.borrow();
    let panes: Vec<&str> = l.typed.iter().map(|t| t.0.as_str()).collect();
    assert_eq!(panes, ["%1", "%4"]);
    assert_eq!(
        l.lists, 6,
        "pane list read 3 times per send (resolve, pre-paste, pre-Enter)"
    );
    assert_eq!(replies(&mut b).len(), 2);
}

#[test]
fn malformed_and_unknown_requests_are_ignored() {
    let (mut b, fake, _, _) = setup();
    for line in [
        "",
        "not json",
        "{}",
        r#"{"cmd":"kill","id":1}"#,
        r#"{"cmd":"send","id":1,"session_id":"sid-a"}"#,
        r#"{"cmd":"send","id":1,"session_id":"sid-a","text":"x","pane":"%2"}"#,
        r#"{"cmd":"exec","id":1,"session_id":"sid-a","text":"rm -rf /"}"#,
        r#"{"frame":"hello","protocol":5}"#,
    ] {
        b.on_request_line(line).unwrap();
    }
    assert!(replies(&mut b).is_empty(), "no answer, no action");
    let l = fake.0.borrow();
    assert!(l.typed.is_empty());
    assert_eq!(l.lists, 0);
}

#[test]
fn nothing_is_typed_without_a_request() {
    // Startup, liveness checks and flushes never type.
    let (mut b, fake, _, _) = setup();
    b.startup().unwrap();
    b.refresh_liveness(true).unwrap();
    b.flush().unwrap();
    let l = fake.0.borrow();
    assert!(l.typed.is_empty());
    assert_eq!(l.lists, 0);
}

#[test]
fn request_wire_form() {
    let r = Request::Send {
        id: 9,
        session_id: "s".into(),
        text: "a\nb".into(),
    };
    assert_eq!(
        r.to_line(),
        r#"{"cmd":"send","id":9,"session_id":"s","text":"a\nb"}"#
    );
    assert_eq!(Request::from_line(&r.to_line()).unwrap(), r);
    let f = Frame::SendResult {
        id: 9,
        result: SendResult::Refused {
            reason: "no".into(),
        },
    };
    assert_eq!(
        f.to_line(),
        r#"{"frame":"send_result","id":9,"result":{"status":"refused","reason":"no"}}"#
    );
    assert_eq!(Frame::from_line(&f.to_line()).unwrap(), f);
}

// ------------------------------------------------------------------ between steps

fn result_of(b: &mut Bridge<Vec<u8>>) -> SendResult {
    let out = replies(b);
    let [Frame::SendResult { result, .. }] = out.as_slice() else {
        panic!("{out:?}")
    };
    result.clone()
}

/// A recycle in place: same pane %1, the old claude (101) replaced by a new one (102,
/// another session). `old_alive` keeps sid-a registered (a different pid then).
fn recycle_a(procs: &Procs, edges: &Edges, same_session: bool) {
    let mut p = procs.borrow_mut();
    p[0].pid = 102;
    if !same_session {
        p[0].session_id = Some("sid-new".into());
    }
    edges.borrow_mut().insert(102, 100);
}

#[test]
fn a_change_before_the_paste_is_refused_and_nothing_is_typed() {
    for same_session in [false, true] {
        let (mut b, fake, procs, edges) = setup();
        let (p, e) = (procs.clone(), edges.clone());
        fake.after("load", move || recycle_a(&p, &e, same_session));
        b.on_request_line(&send_line(1, "sid-a", "for the old one"))
            .unwrap();
        let r = result_of(&mut b);
        assert!(
            matches!(&r, SendResult::Refused { reason } if reason.contains("changed while sending")),
            "{r:?}"
        );
        let l = fake.0.borrow();
        assert!(l.typed.is_empty() && l.enters.is_empty(), "{:?}", l.steps);
        assert_eq!(l.steps, ["load", "discard"], "the buffer is dropped");
        assert!(l.loaded.is_empty());
    }
}

#[test]
fn a_change_between_paste_and_enter_is_uncertain_with_no_enter() {
    for same_session in [false, true] {
        let (mut b, fake, procs, edges) = setup();
        let (p, e) = (procs.clone(), edges.clone());
        fake.after("paste", move || recycle_a(&p, &e, same_session));
        b.on_request_line(&send_line(1, "sid-a", "pasted then swapped"))
            .unwrap();
        let r = result_of(&mut b);
        assert!(
            matches!(&r, SendResult::Uncertain { reason } if reason.contains("changed while sending")),
            "{r:?}"
        );
        let l = fake.0.borrow();
        assert_eq!(l.typed.len(), 1);
        assert!(
            l.enters.is_empty(),
            "no Enter after a change: {:?}",
            l.steps
        );
    }
}

#[test]
fn a_pane_move_between_paste_and_enter_is_uncertain() {
    // Same pid, but its process now sits under another pane.
    let (mut b, fake, _, edges) = setup();
    let e = edges.clone();
    fake.after("paste", move || {
        e.borrow_mut().insert(101, 200);
    });
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Uncertain { .. }));
    assert!(fake.0.borrow().enters.is_empty());
}

#[test]
fn failures_before_the_paste_are_refused_after_it_uncertain() {
    for (at, uncertain) in [("load", false), ("paste", true), ("enter", true)] {
        let (mut b, fake, _, _) = setup();
        fake.0.borrow_mut().fail_at = Some(at);
        b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
        let r = result_of(&mut b);
        match (&r, uncertain) {
            (SendResult::Uncertain { reason }, true) | (SendResult::Refused { reason }, false) => {
                assert!(reason.contains(&format!("{at} failed")), "{reason}")
            }
            _ => panic!("{at}: {r:?}"),
        }
        let l = fake.0.borrow();
        if at == "paste" {
            assert!(l.enters.is_empty(), "no Enter after a failed paste");
        }
    }
}

/// Claude Code opens a question in sid-a's terminal.
fn question_opens(procs: &Procs) {
    let mut p = procs.borrow_mut();
    p[0].status = Some("waiting".into());
    p[0].waiting_for = Some("input needed".into());
}

#[test]
fn a_send_to_an_agent_waiting_on_a_question_types_nothing() {
    let (mut b, fake, procs, _) = setup();
    question_opens(&procs);
    b.on_request_line(&send_line(1, "sid-a", "1")).unwrap();
    let r = result_of(&mut b);
    assert!(
        matches!(&r, SendResult::Refused { reason } if reason.contains("waiting for you")),
        "{r:?}"
    );
    assert!(fake.0.borrow().steps.is_empty(), "nothing loaded or typed");
}

#[test]
fn a_question_opening_mid_send_stops_before_the_paste_or_the_enter() {
    let (mut b, fake, procs, _) = setup();
    let p = procs.clone();
    fake.after("load", move || question_opens(&p));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Refused { .. }));
    assert_eq!(fake.0.borrow().steps, ["load", "discard"]);

    let (mut b, fake, procs, _) = setup();
    let p = procs.clone();
    fake.after("paste", move || question_opens(&p));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Uncertain { .. }));
    let l = fake.0.borrow();
    assert!(
        l.enters.is_empty(),
        "no Enter into an open question: {:?}",
        l.steps
    );
}

/// After a step, sid-a's registry status becomes `s`.
fn status_becomes(procs: &Procs, s: Option<&'static str>) -> impl FnMut() + 'static {
    let p = procs.clone();
    move || p.borrow_mut()[0].status = s.map(str::to_owned)
}

#[test]
fn a_send_to_an_agent_with_no_or_an_unknown_status_types_nothing() {
    for status in [None, Some("frobnicate")] {
        let (mut b, fake, procs, _) = setup();
        procs.borrow_mut()[0].status = status.map(str::to_owned);
        b.on_request_line(&send_line(1, "sid-a", "1")).unwrap();
        let r = result_of(&mut b);
        assert!(matches!(&r, SendResult::Refused { .. }), "{r:?}");
        assert!(fake.0.borrow().steps.is_empty(), "nothing loaded or typed");
    }
}

#[test]
fn a_status_lost_mid_send_stops_before_the_paste_or_the_enter() {
    let (mut b, fake, procs, _) = setup();
    fake.after("load", status_becomes(&procs, None));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Refused { .. }));
    assert_eq!(fake.0.borrow().steps, ["load", "discard"]);

    let (mut b, fake, procs, _) = setup();
    fake.after("paste", status_becomes(&procs, Some("frobnicate")));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Uncertain { .. }));
    assert!(fake.0.borrow().enters.is_empty(), "no Enter");
}

/// A Claude Code permission dialog: no input box under its menu.
const MENU: &str = "\
  Done reading the build log.

────────────────────────────────────────────────────────────
 Bash command

   rm -rf build

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands in /work
   3. No, and tell Claude what to do differently (esc)
";

/// What a pane shows (`Ok`), or the error its screen read returns (`Err`).
type Shown = Result<&'static str, &'static str>;

/// After a step, sid-a's pane shows `s`.
fn screen_becomes(fake: &Fake, s: Shown) -> impl FnMut() + 'static {
    let f = fake.clone();
    move || {
        let mut l = f.0.borrow_mut();
        match s {
            Ok(t) => l.screen = t.into(),
            Err(e) => l.screen_error = Some(e.into()),
        }
    }
}

#[test]
fn a_send_reads_the_screen_before_the_paste_and_before_the_enter() {
    let (mut b, fake, _, _) = setup();
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Sent));
    assert_eq!(fake.0.borrow().screen_reads, 2);
}

#[test]
fn a_menu_on_screen_before_the_paste_types_nothing() {
    let (mut b, fake, _, _) = setup();
    fake.0.borrow_mut().screen = MENU.into();
    b.on_request_line(&send_line(1, "sid-a", "1")).unwrap();
    let r = result_of(&mut b);
    assert!(
        matches!(&r, SendResult::Refused { reason } if reason.contains("input box")),
        "{r:?}"
    );
    let l = fake.0.borrow();
    assert!(l.typed.is_empty(), "nothing typed");
    assert!(l.enters.is_empty(), "no Enter");
    assert_eq!(l.steps, ["load", "discard"]);
}

#[test]
fn a_menu_that_opens_after_the_paste_gets_no_enter() {
    let (mut b, fake, _, _) = setup();
    fake.after("paste", screen_becomes(&fake, Ok(MENU)));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Uncertain { .. }));
    let l = fake.0.borrow();
    assert!(
        l.enters.is_empty(),
        "no Enter into an open menu: {:?}",
        l.steps
    );
}

#[test]
fn menu_text_inside_the_typed_message_is_not_a_menu() {
    // The message itself quotes a menu; it sits in the input box, between its two rules.
    let typed = "\
  Done reading the build log.

────────────────────────────────────────────────────────────
❯ The dialog said:
  ❯ 1. Yes
    2. No
────────────────────────────────────────────────────────────
  ? for shortcuts
";
    let (mut b, fake, _, _) = setup();
    fake.after("paste", screen_becomes(&fake, Ok(typed)));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Sent));
    assert_eq!(fake.0.borrow().enters, ["%1"]);
}

#[test]
fn a_screen_that_cannot_be_read_refuses_fail_closed() {
    let (mut b, fake, _, _) = setup();
    fake.0.borrow_mut().screen_error = Some("tmux did not answer within 2000 ms".into());
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    let r = result_of(&mut b);
    assert!(
        matches!(&r, SendResult::Refused { reason } if reason.contains("did not answer")),
        "{r:?}"
    );
    assert!(fake.0.borrow().typed.is_empty());

    let (mut b, fake, _, _) = setup();
    fake.after("paste", screen_becomes(&fake, Err("no pane")));
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    assert!(matches!(result_of(&mut b), SendResult::Uncertain { .. }));
    assert!(fake.0.borrow().enters.is_empty(), "no Enter");
}

/// Claude Code's idle input box: a rule, the prompt row, a rule, a hint row.
fn idle_box() -> String {
    format!("{r}\n❯\u{a0}\n{r}\n  ? for shortcuts\n", r = "─".repeat(80))
}

#[test]
fn a_screen_without_the_input_box_types_nothing() {
    let (mut b, fake, _, _) = setup();
    fake.0.borrow_mut().screen = "u@host:~$\n".into();
    b.on_request_line(&send_line(1, "sid-a", "x")).unwrap();
    let r = result_of(&mut b);
    assert!(
        matches!(&r, SendResult::Refused { reason } if reason.contains("input box")),
        "{r:?}"
    );
    assert!(fake.0.borrow().typed.is_empty(), "nothing typed");
}
