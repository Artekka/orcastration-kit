//! Typing, against REAL tmux: a throwaway server on its own socket (`-L obs-test-…`,
//! never the default server where the agents run), one session `obs-test-…` running a fake
//! reader (python3 in raw mode with bracketed paste on; never a Claude agent). The bridge
//! resolves the reader's pane from a temp registry + the live process tree, then types into it.
//! The reader records every byte it receives; the test asserts they are exactly
//! `ESC[200~ <text> ESC[201~ CR`: the text byte-identical, one paste, one Enter.
//! Skipped (with a printed reason) when tmux or python3 is missing.

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use common::*;
use observatory_bridge::bridge::Bridge;
use observatory_bridge::liveness;
use observatory_bridge::tmux::{Pane, Terminal, Tmux};
use observatory_core::wire::{Frame, Request, SendResult};

const READER: &str = r#"
import os, sys, termios, tty, time, select
out, ready = sys.argv[1], sys.argv[2]
limit = float(sys.argv[3]) if len(sys.argv) > 3 else 20
fd = 0
tty.setraw(fd)
os.write(1, b"\x1b[?2004h")  # ask for bracketed paste, as Claude Code does
with open(ready, "w") as f:
    f.write(str(os.getpid()))
buf = b""
deadline = time.time() + limit
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        buf += os.read(fd, 65536)
    if buf.endswith(b"\x1b[201~\r"):
        # Keep listening a little: a second Enter or paste would show up here.
        end = time.time() + 0.7
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                buf += os.read(fd, 65536)
        break
with open(out + ".tmp", "wb") as f:
    f.write(buf)
os.rename(out + ".tmp", out)
"#;

fn have(bin: &str) -> bool {
    Command::new(bin)
        .arg(if bin == "tmux" { "-V" } else { "--version" })
        .output()
        .is_ok_and(|o| o.status.success())
}

/// Kills the throwaway server (and only it: its own socket) when the test ends.
/// Also removes its socket file (read while the server was up).
struct Server(String, Option<String>);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new("tmux")
            .args(["-L", &self.0, "kill-server"])
            .output();
        if let Some(p) = self.1.as_ref().filter(|p| p.contains("/obs-test-")) {
            let _ = fs::remove_file(p);
        }
    }
}

fn wait_for(p: &Path, secs: u64) -> bool {
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(secs) {
        if p.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn deliver_through_bridge(name: &str, text: &str) -> Vec<u8> {
    let claude = claude_tree(name);
    let dir: PathBuf = claude.parent().unwrap().to_path_buf();
    let script = dir.join("reader.py");
    let out = dir.join("received.bin");
    let ready = dir.join("ready");
    fs::write(&script, READER).unwrap();
    let sock = format!("obs-test-{}-{name}", std::process::id());
    let mut server = Server(sock.clone(), None);
    let st = Command::new("tmux")
        .args(["-L", &sock, "-f", "/dev/null", "new-session", "-d"])
        .args(["-s", &format!("obs-test-{name}"), "-x", "200", "-y", "50"])
        .arg(format!(
            "python3 {} {} {}",
            script.display(),
            out.display(),
            ready.display()
        ))
        .status()
        .unwrap();
    assert!(st.success(), "throwaway tmux session did not start");
    server.1 = Command::new("tmux")
        .args(["-L", &sock, "display-message", "-p", "#{socket_path}"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    assert!(wait_for(&ready, 10), "reader never got ready");
    std::thread::sleep(Duration::from_millis(200)); // let tmux see the 2004h mode switch
    let pid: u32 = fs::read_to_string(&ready).unwrap().trim().parse().unwrap();

    // The reader plays the agent: a registry entry for its pid, validated like any other.
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
    let start = liveness::stat_start_time(&stat).unwrap();
    write(
        &claude.join("sessions").join(format!("{pid}.json")),
        &format!(
            r#"{{"pid":{pid},"sessionId":"sid-reader","name":"Reader","cwd":"/x","procStart":"{start}","status":"idle"}}"#
        ),
    );
    let tmux = Tmux {
        socket: Some(sock.clone()),
        ..Tmux::default()
    };
    let mut b = Bridge::new(cfg(0), claude, Vec::new()).with_terminal(tmux, liveness::parent_of);
    let req = Request::Send {
        id: 1,
        session_id: "sid-reader".into(),
        text: text.into(),
    };
    b.on_request_line(&req.to_line()).unwrap();
    let replies: Vec<Frame> = b
        .drain_output()
        .iter()
        .map(|l| Frame::from_line(l).unwrap())
        .collect();
    assert_eq!(
        replies,
        vec![Frame::SendResult {
            id: 1,
            result: SendResult::Sent
        }]
    );
    assert!(wait_for(&out, 20), "reader saw no submit");
    let got = fs::read(&out).unwrap();
    // Evidence for the hand-off: the exact bytes, escaped.
    println!(
        "delivery[{name}]: socket {sock}, pane pid {pid}, received {} bytes: {}",
        got.len(),
        got.escape_ascii()
    );
    got
}

fn expect(text: &str) -> Vec<u8> {
    let mut v = b"\x1b[200~".to_vec();
    v.extend_from_slice(text.as_bytes());
    v.extend_from_slice(b"\x1b[201~\r");
    v
}

#[test]
fn real_tmux_delivers_text_byte_identical_and_submits_once() {
    if !have("tmux") || !have("python3") {
        println!("SKIPPED real_tmux delivery: tmux or python3 not installed");
        return;
    }
    let text = "/review the \"quoted\" 'single' $(whoami) `id` $HOME; echo done && rm -rf nothing\n\
                second line\twith tab\n\
                unicode: café ✓ 日本語 🚀\n\
                trailing \\ backslash and {braces} #{pane_id} %1";
    let got = deliver_through_bridge("full", text);
    assert_eq!(
        got.escape_ascii().to_string(),
        expect(text).escape_ascii().to_string()
    );
}

#[test]
fn real_tmux_single_line_with_leading_slash() {
    if !have("tmux") || !have("python3") {
        println!("SKIPPED real_tmux delivery: tmux or python3 not installed");
        return;
    }
    let text = "/help";
    let got = deliver_through_bridge("slash", text);
    assert_eq!(got, expect(text));
}

// ------------------------------------------------------------------ more delivery cases

/// Real tmux, plus a hook run once right AFTER one step: the injected timing of a recycle.
struct Hooked {
    inner: Tmux,
    at: &'static str,
    hook: Option<Box<dyn FnMut()>>,
}

impl Hooked {
    fn fire(&mut self, step: &str) {
        if step == self.at
            && let Some(mut f) = self.hook.take()
        {
            f();
        }
    }
}

impl Terminal for Hooked {
    fn panes(&mut self) -> Result<Vec<Pane>, String> {
        self.inner.panes()
    }
    fn load(&mut self, buffer: &str, text: &str) -> Result<(), String> {
        let r = self.inner.load(buffer, text);
        self.fire("load");
        r
    }
    fn discard(&mut self, buffer: &str) {
        self.inner.discard(buffer)
    }
    fn paste(&mut self, pane: &str, buffer: &str) -> Result<(), String> {
        let r = self.inner.paste(pane, buffer);
        self.fire("paste");
        r
    }
    fn enter(&mut self, pane: &str) -> Result<(), String> {
        self.inner.enter(pane)
    }
    fn settle(&self) -> std::time::Duration {
        self.inner.settle()
    }
}

fn register(claude: &Path, pid: u32, sid: &str) {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
    let start = liveness::stat_start_time(&stat).unwrap();
    write(
        &claude.join("sessions").join(format!("{pid}.json")),
        &format!(
            r#"{{"pid":{pid},"sessionId":"{sid}","name":"Reader","cwd":"/x","procStart":"{start}","status":"idle"}}"#
        ),
    );
}

/// One pane: bash runs reader 1 ("sid-OLD"), and when it dies, reader 2 ("sid-NEW") starts in
/// the SAME pane, like a recycle in place. The hook kills reader 1 after step `at`. Returns
/// the reply and the bytes reader 2 (the wrong target) received within its 3 s window.
fn recycle_during(name: &str, at: &'static str) -> (SendResult, Vec<u8>) {
    let claude = claude_tree(name);
    let dir: PathBuf = claude.parent().unwrap().to_path_buf();
    let script = dir.join("reader.py");
    fs::write(&script, READER).unwrap();
    let (o1, r1, o2, r2) = (
        dir.join("out1"),
        dir.join("ready1"),
        dir.join("out2"),
        dir.join("ready2"),
    );
    let sock = format!("obs-test-{}-{name}", std::process::id());
    let mut server = Server(sock.clone(), None);
    let st = Command::new("tmux")
        .args(["-L", &sock, "-f", "/dev/null", "new-session", "-d"])
        .args(["-s", &format!("obs-test-{name}"), "-x", "200", "-y", "50"])
        .arg(format!(
            "bash -c 'python3 {s} {o1} {r1} 20; python3 {s} {o2} {r2} 3'",
            s = script.display(),
            o1 = o1.display(),
            r1 = r1.display(),
            o2 = o2.display(),
            r2 = r2.display()
        ))
        .status()
        .unwrap();
    assert!(st.success(), "throwaway tmux session did not start");
    server.1 = Command::new("tmux")
        .args(["-L", &sock, "display-message", "-p", "#{socket_path}"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    assert!(wait_for(&r1, 10), "reader 1 never got ready");
    std::thread::sleep(Duration::from_millis(200));
    let old: u32 = fs::read_to_string(&r1).unwrap().trim().parse().unwrap();
    register(&claude, old, "sid-OLD");
    let (c2, r2h) = (claude.clone(), r2.clone());
    let hook = move || {
        let _ = Command::new("kill").arg(old.to_string()).status();
        assert!(wait_for(&r2h, 10), "replacement never started");
        let new: u32 = fs::read_to_string(&r2h).unwrap().trim().parse().unwrap();
        register(&c2, new, "sid-NEW");
        std::thread::sleep(Duration::from_millis(200));
    };
    let term = Hooked {
        inner: Tmux {
            socket: Some(sock.clone()),
            ..Tmux::default()
        },
        at,
        hook: Some(Box::new(hook)),
    };
    let mut b = Bridge::new(cfg(0), claude, Vec::new()).with_terminal(term, liveness::parent_of);
    let req = Request::Send {
        id: 1,
        session_id: "sid-OLD".into(),
        text: "meant for the OLD session".into(),
    };
    b.on_request_line(&req.to_line()).unwrap();
    let out: Vec<Frame> = b
        .drain_output()
        .iter()
        .map(|l| Frame::from_line(l).unwrap())
        .collect();
    let [Frame::SendResult { result, .. }] = out.as_slice() else {
        panic!("{out:?}")
    };
    assert!(wait_for(&o2, 10), "replacement never finished listening");
    let got = fs::read(&o2).unwrap();
    println!(
        "recycle[{name}] after {at}: reply {result:?}; replacement received {} bytes: {}",
        got.len(),
        got.escape_ascii()
    );
    (result.clone(), got)
}

#[test]
fn real_tmux_recycle_before_the_paste_is_refused_and_types_nothing() {
    if !have("tmux") || !have("python3") {
        println!("SKIPPED real_tmux recycle: tmux or python3 not installed");
        return;
    }
    let (r, got) = recycle_during("recycle-load", "load");
    assert!(matches!(r, SendResult::Refused { .. }), "{r:?}");
    assert!(
        got.is_empty(),
        "the new agent got bytes: {}",
        got.escape_ascii()
    );
}

#[test]
fn real_tmux_recycle_after_the_paste_is_uncertain_and_never_presses_enter() {
    if !have("tmux") || !have("python3") {
        println!("SKIPPED real_tmux recycle: tmux or python3 not installed");
        return;
    }
    let (r, got) = recycle_during("recycle-paste", "paste");
    assert!(matches!(r, SendResult::Uncertain { .. }), "{r:?}");
    assert!(
        !got.contains(&b'\r'),
        "an Enter reached the new agent: {}",
        got.escape_ascii()
    );
}
