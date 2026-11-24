//! Hard read-only guard.
//! 1. Source scan: only `src/fsro.rs` may name the filesystem, and it has no write-capable call.
//! 2. Registry: only `*.json` is selected; a `*.key` beside it never is.
//! 3. Live (Linux): every fd the running bridge holds under the tree is O_RDONLY, and the
//!    tree is byte-identical before and after it runs (see `live_test.rs` for the run itself).
//! 4. Processes: only `src/tmux.rs` may start one, the program is `tmux`, and its
//!    literals are allow-listed (the five subcommands of a send, their flags, the pane format).

mod common;

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use common::*;
use observatory_bridge::liveness;

/// Code with `//` comments removed (doc text may say "write"; code may not).
fn code_of(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|l| l.split("//").next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n")
}

/// `word` as a whole identifier (not inside `FileConfig` or `fsro`).
fn has_word(code: &str, word: &str) -> bool {
    let ident = |c: char| c.is_ascii_alphanumeric() || c == '_';
    code.match_indices(word).any(|(i, _)| {
        let before = code[..i].chars().next_back();
        let after = code[i + word.len()..].chars().next();
        !before.is_some_and(ident) && !after.is_some_and(ident)
    })
}

#[test]
fn has_word_matches_identifiers_only() {
    assert!(has_word("use std::fs::File;", "File"));
    assert!(has_word("std::fs::read(p)", "fs"));
    assert!(!has_word(
        "let f: FileConfig = x; fsro::read_text(p)",
        "File"
    ));
    assert!(!has_word("fsro::read_text(p)", "fs"));
}

const SRC: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/src");

#[test]
fn only_fsro_touches_the_filesystem() {
    let mut scanned = 0;
    for e in fs::read_dir(SRC).unwrap() {
        let p = e.unwrap().path();
        if p.extension().is_none_or(|x| x != "rs") || p.ends_with("fsro.rs") {
            continue;
        }
        scanned += 1;
        let code = code_of(&p);
        for bad in ["fs", "File", "OpenOptions"] {
            assert!(
                !has_word(&code, bad),
                "{} names `{bad}`: filesystem access belongs in fsro.rs",
                p.display()
            );
        }
    }
    assert!(
        scanned >= 6,
        "scanned only {scanned} files: the scan is vacuous"
    );
}

/// Rust-ish tokens of `code`: identifiers and single punctuation characters.
fn tokens(code: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for c in code.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            cur.push(c);
            continue;
        }
        if !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
        if !c.is_whitespace() {
            out.push(c.to_string());
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn is_ident(t: &str) -> bool {
    t.chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
}

/// (paths `a::b::c`, method calls `.m(`, bare calls `f(`) used in `code`.
fn calls(code: &str) -> (BTreeSet<String>, BTreeSet<String>, BTreeSet<String>) {
    let t = tokens(code);
    let (mut paths, mut methods, mut bare) = (BTreeSet::new(), BTreeSet::new(), BTreeSet::new());
    let mut i = 0;
    while i < t.len() {
        if !is_ident(&t[i]) {
            i += 1;
            continue;
        }
        let start = i;
        let mut path = t[i].clone();
        while i + 3 < t.len() && t[i + 1] == ":" && t[i + 2] == ":" && is_ident(&t[i + 3]) {
            path = format!("{path}::{}", t[i + 3]);
            i += 3;
        }
        let after_colons = start >= 2 && t[start - 1] == ":" && t[start - 2] == ":";
        let next_is_call = t.get(i + 1).is_some_and(|n| n == "(");
        if path.contains("::") {
            paths.insert(path);
        } else if start >= 1 && t[start - 1] == "." && next_is_call {
            methods.insert(path);
        } else if next_is_call && !after_colons {
            bare.insert(path);
        }
        i += 1;
    }
    (paths, methods, bare)
}

const FSRO_PATHS: &[&str] = &[
    "File::open",
    "SeekFrom::Start",
    "String::new",
    "Vec::new",
    "fs::metadata",
    "fs::read_dir",
    "fs::read_link",
    // Gallery: stat a file itself, never following a symlink.
    "fs::symlink_metadata",
    "io::Result",
    "std::fs",
    "std::io",
    "std::os::unix::fs::MetadataExt",
    "std::path",
    "std::time::SystemTime",
];
const FSRO_METHODS: &[&str] = &[
    "and_then",
    "collect",
    "dev",
    "file_type", // An entry's type, from the directory listing (no symlink followed)
    "filter_map",
    "ino",
    "is_dir",
    "is_file",
    "is_some_and",
    "len",
    "map",
    "metadata",
    "modified",
    "ok",
    "path",
    "push", // Collecting entries into a Vec
    "read",
    "read_to_end",
    "read_to_string",
    "seek",
    "sort",
    "unwrap_or_default",
];
const FSRO_BARE: &[&str] = &[
    "Ok",
    "RoFile",
    "Some",
    "cfg",
    "derive",
    "entries",    // List a directory with entry types
    "file_stamp", // mtime + size of a file itself
    "is_dir",
    "is_still",
    "list_dir",
    "match",
    "metadata",
    "modified",
    "not",
    "open",
    "read_at",
    "read_bytes",
    "read_link",
    "read_text",
    "size",
];
const FSRO_USES: &[&str] = &[
    "use std::fs::{self, File, Metadata};",
    "use std::io::{self, Read, Seek, SeekFrom};",
    "use std::path::{Path, PathBuf};",
    "use std::time::SystemTime;",
    "use std::os::unix::fs::MetadataExt;",
];

/// ALLOW-LIST: fsro.rs may use exactly these paths, methods, calls and imports. Anything new (a
/// write, a process, another fs function) fails here until a reviewer adds it on purpose.
#[test]
fn fsro_uses_only_allow_listed_calls() {
    let code = code_of(&Path::new(SRC).join("fsro.rs"));
    let (paths, methods, bare) = calls(&code);
    let check = |kind: &str, got: &BTreeSet<String>, allowed: &[&str]| {
        let extra: Vec<&String> = got
            .iter()
            .filter(|g| !allowed.contains(&g.as_str()))
            .collect();
        assert!(
            extra.is_empty(),
            "fsro.rs uses {kind} not on the allow-list: {extra:?}"
        );
        assert!(!got.is_empty(), "non-vacuity: no {kind} found");
    };
    check("paths", &paths, FSRO_PATHS);
    check("methods", &methods, FSRO_METHODS);
    check("bare calls", &bare, FSRO_BARE);
    for l in code
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("use "))
    {
        assert!(
            FSRO_USES.contains(&l),
            "fsro.rs import not on the allow-list: {l}"
        );
    }
    assert!(
        paths.contains("File::open"),
        "non-vacuity: fsro opens files"
    );
}

#[test]
fn allow_list_scanner_sees_writes() {
    let (p, m, b) =
        calls("fn f() { std::fs::write(p, x); fs::write(p, x); h.write_all(b); remove_file(p); }");
    assert!(
        p.contains("std::fs::write") && p.contains("fs::write"),
        "{p:?}"
    );
    assert!(m.contains("write_all"), "{m:?}");
    assert!(b.contains("remove_file"), "{b:?}");
}

/// No module may start processes or step outside safe Rust (fsro included). The one
/// exception: `tmux.rs` may name `Command`, under the checks of `tmux_runs_only_tmux_sends`.
#[test]
fn no_process_or_unsafe_anywhere() {
    for e in fs::read_dir(SRC).unwrap() {
        let p = e.unwrap().path();
        let code = code_of(&p);
        for bad in ["Command", "unsafe", "libc", "nix", "OpenOptions", "Stdio"] {
            if p.ends_with("tmux.rs") && (bad == "Command" || bad == "Stdio") {
                continue;
            }
            assert!(!has_word(&code, bad), "{} names `{bad}`", p.display());
        }
        if !p.ends_with("fsro.rs") {
            assert!(
                !has_word(&code, "os"),
                "{}: std::os belongs in fsro.rs",
                p.display()
            );
        }
    }
}

#[test]
fn registry_reads_json_only_never_key_files() {
    let c = claude_tree("registry-select");
    let s = c.join("sessions");
    for n in [
        "123.json",
        "123.5f97aa.key",
        "456.json.bak",
        "789.JSONX",
        "key.json.key",
    ] {
        write(&s.join(n), "{}");
    }
    let names: Vec<String> = liveness::registry_files(&s)
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["123.json"]);
}

/// The registry entry for a live pid counts only when its start time matches.
#[cfg(target_os = "linux")]
#[test]
fn registry_entry_needs_live_pid_and_matching_start_time() {
    let me = std::process::id();
    let stat = fs::read_to_string("/proc/self/stat").unwrap();
    let start = liveness::stat_start_time(&stat).unwrap();
    let c = claude_tree("registry-live");
    let s = c.join("sessions");
    let entry = |pid: u32, start: u64, sid: &str| {
        format!(
            r#"{{"pid":{pid},"sessionId":"{sid}","cwd":"/x","procStart":"{start}","status":"busy","name":"T","extra":1}}"#
        )
    };
    write(&s.join(format!("{me}.json")), &entry(me, start, "good"));
    // A key file holding a VALID live entry: if scan ever reads a .key, "from-key" shows up.
    write(
        &s.join(format!("{me}.abc.key")),
        &entry(me, start, "from-key"),
    );

    let found = liveness::scan(&c).unwrap();
    let mine: Vec<_> = found.iter().filter(|p| p.pid == me).collect();
    assert_eq!(mine.len(), 1, "{found:?}");
    assert_eq!(mine[0].session_id.as_deref(), Some("good"));
    assert_eq!(mine[0].status.as_deref(), Some("busy"));
    assert!(
        found
            .iter()
            .all(|p| p.session_id.as_deref() != Some("from-key")),
        "a .key file was read: {found:?}"
    );

    // Same pid, wrong start time (pid reused): not counted from the registry.
    let tree2 = claude_tree("registry-reused");
    write(
        &tree2.join("sessions").join(format!("{me}.json")),
        &entry(me, start + 1, "stale"),
    );
    let found = liveness::scan(&tree2).unwrap();
    assert!(
        found
            .iter()
            .all(|p| p.session_id.as_deref() != Some("stale")),
        "{found:?}"
    );
}

/// String literals in `code` (escapes kept as written).
fn literals(code: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut it = code.chars().peekable();
    let mut prev = ' ';
    while let Some(c) = it.next() {
        // A char literal like '"' is not a string start.
        if c == '"' && prev != '\'' {
            let mut lit = String::new();
            while let Some(d) = it.next() {
                if d == '\\' {
                    lit.push(d);
                    if let Some(e) = it.next() {
                        lit.push(e);
                    }
                    continue;
                }
                if d == '"' {
                    break;
                }
                lit.push(d);
            }
            out.push(lit);
            prev = '"';
            continue;
        }
        prev = c;
    }
    out
}

#[test]
fn literal_scanner_sees_strings() {
    assert_eq!(
        literals(r#"c.args(["-L", s]); let q = '"'; x("a b\"c")"#),
        ["-L", r#"a b\"c"#]
    );
}

/// Every whitespace-free literal tmux.rs (outside its unit tests) may contain: the program,
/// the six subcommands, their flags, the key `Enter`, stdin `-`, the buffer prefix. A new
/// subcommand (`kill-server`, `run-shell`…) or another program fails here. `capture-pane`
/// was added on purpose: it only reads the pane's visible text (`-p` prints it to stdout
/// instead of a buffer), so a send can refuse when a menu is open there.
const TMUX_LITERALS: &[&str] = &[
    "tmux",
    "list-panes",
    "load-buffer",
    "paste-buffer",
    "delete-buffer",
    "send-keys",
    "capture-pane",
    "-L",
    "-a",
    "-F",
    "-b",
    "-",
    "-p",
    "-r",
    "-d",
    "-t",
    "Enter",
    "observatory-{tag}",
    "{sub}",
    "%",
];

#[test]
fn tmux_runs_only_tmux_sends() {
    let full = code_of(&Path::new(SRC).join("tmux.rs"));
    let code = full.split("#[cfg(test)]").next().unwrap();
    assert!(
        code.contains(r#"const TMUX_BIN: &str = "tmux";"#),
        "the program is tmux"
    );
    let news: Vec<_> = code.match_indices("Command::new(").collect();
    assert_eq!(news.len(), 1, "one place starts a process");
    assert!(
        code[news[0].0..].starts_with("Command::new(TMUX_BIN)"),
        "and it starts TMUX_BIN"
    );
    let lits = literals(code);
    let bare: Vec<&String> = lits.iter().filter(|l| !l.contains(' ')).collect();
    for l in &bare {
        assert!(
            TMUX_LITERALS.contains(&l.as_str()),
            "tmux.rs literal not on the allow-list: {l:?}"
        );
    }
    // The only spaced literal that reaches tmux's argv is the pane format.
    assert!(lits.iter().any(|l| l == "#{pane_id} #{pane_pid}"));
    for sub in [
        "list-panes",
        "load-buffer",
        "paste-buffer",
        "send-keys",
        "capture-pane",
    ] {
        assert!(bare.iter().any(|l| *l == sub), "non-vacuity: {sub}");
    }
    // `send-keys` only ever presses Enter: its argv is [-t, pane, Enter].
    assert!(
        code.contains(r#"enter.args(["-t", pane, "Enter"]);"#),
        "send-keys carries only Enter"
    );
    // capture-pane only prints the visible pane (`-p`), never into a buffer or another pane.
    assert!(
        code.contains(r#"capture.args(["-p", "-t", pane]);"#),
        "capture-pane carries only -p and the pane"
    );
    // The text goes in on stdin only (load-buffer `-`), never as an argument.
    assert!(code.contains(r#"load.args(["-b", buffer, "-"]);"#));
}
