//! Galleries: which files count, order, the bound, globs, and change detection. Image files
//! are empty files with image names (the bridge never opens them), in cargo's target tmp dir.

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, SystemTime};

use common::*;
use observatory_bridge::bridge::Bridge;
use observatory_bridge::gallery::{self, Scanner, expand, scan};
use observatory_core::ProjectSpec;
use observatory_core::wire::{Frame, GALLERY_MAX, GalleryItem};

fn root(name: &str) -> PathBuf {
    let d = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join("v1-8")
        .join(name);
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// An empty file at `p` whose modified time is `t` seconds after an arbitrary epoch.
fn file(p: &Path, t: u64) {
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    let f = fs::File::create(p).unwrap();
    f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + t))
        .unwrap();
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn names(items: &[GalleryItem]) -> Vec<String> {
    items
        .iter()
        .map(|i| i.path.rsplit('/').next().unwrap().to_owned())
        .collect()
}

fn spec(name: &str, gallery: &[String]) -> ProjectSpec {
    ProjectSpec {
        name: name.into(),
        root: "/nonexistent/root".into(),
        worktree_roots: vec![],
        gallery: gallery.to_vec(),
        exact: false,
    }
}

#[test]
fn images_only_recursive_newest_first_hidden_and_links_skipped() {
    let r = root("which");
    file(&r.join("a.png"), 10);
    file(&r.join("deep/er/b.JPG"), 30);
    file(&r.join("c.webp"), 20);
    file(&r.join("d.jpeg"), 20); // same time as c: ties by path
    file(&r.join("notes.txt"), 99);
    file(&r.join("tex.dds"), 99);
    file(&r.join(".cache/hidden.png"), 99);
    let elsewhere = root("which-elsewhere");
    file(&elsewhere.join("linked.png"), 99);
    std::os::unix::fs::symlink(&elsewhere, r.join("link-dir")).unwrap();
    std::os::unix::fs::symlink(elsewhere.join("linked.png"), r.join("link.png")).unwrap();
    let mut missing = Vec::new();
    let (total, items) = scan(&[s(&r)], &mut missing);
    assert_eq!(names(&items), ["b.JPG", "c.webp", "d.jpeg", "a.png"]);
    assert_eq!(total, 4);
    assert!(missing.is_empty());
    assert_eq!(items[0].path, s(&r.join("deep/er/b.JPG")), "absolute path");
    assert_eq!(items[0].mtime_ms, (1_700_000_000 + 30) * 1000);
    assert_eq!(items[0].size, 0);
}

#[test]
fn bound_keeps_the_newest_and_counts_all() {
    let r = root("bound");
    let n = GALLERY_MAX + 5;
    for i in 0..n {
        file(&r.join(format!("{i:05}.png")), i as u64);
    }
    let (total, items) = scan(&[s(&r)], &mut Vec::new());
    assert_eq!(total as usize, n);
    assert_eq!(items.len(), GALLERY_MAX);
    assert_eq!(
        names(&items[..1]),
        [format!("{:05}.png", n - 1)],
        "newest first"
    );
    assert_eq!(
        names(&items[GALLERY_MAX - 1..]),
        ["00005.png"],
        "the 5 oldest are the ones left out"
    );
}

#[test]
fn globs_match_directory_names_and_pick_up_new_ones() {
    let r = root("glob");
    file(&r.join("run1/shots/a.png"), 1);
    file(&r.join("run1/other/x.png"), 9);
    file(&r.join("loose.png"), 9);
    let pat = format!("{}/*/shots", s(&r));
    assert_eq!(expand(&pat), [r.join("run1/shots")]);
    assert_eq!(
        expand(&format!("{}/run?/shots", s(&r))),
        [r.join("run1/shots")]
    );
    let mut sc = Scanner::new(&[spec("p", std::slice::from_ref(&pat))]);
    assert_eq!(sc.pass().len(), 1);
    file(&r.join("run2/shots/b.png"), 2);
    let f = sc.pass();
    let [Frame::Gallery { items, total, .. }] = f.as_slice() else {
        panic!("{f:?}")
    };
    assert_eq!(
        (names(items), *total),
        (vec!["b.png".into(), "a.png".into()], 2)
    );
}

#[test]
fn add_change_delete_each_send_one_frame_and_quiet_sends_none() {
    let r = root("live");
    file(&r.join("a.png"), 1);
    let mut sc = Scanner::new(&[spec("p", &[s(&r)]), spec("no-gallery", &[])]);
    let first = sc.pass();
    assert_eq!(first.len(), 1, "only projects with a gallery: {first:?}");
    assert!(sc.pass().is_empty(), "nothing changed: no frame");
    let only = |f: Vec<Frame>| match f.as_slice() {
        [
            Frame::Gallery {
                project,
                items,
                total,
            },
        ] => {
            assert_eq!(project, "p");
            assert_eq!(*total as usize, items.len());
            names(items)
        }
        other => panic!("{other:?}"),
    };
    file(&r.join("b.png"), 2);
    assert_eq!(only(sc.pass()), ["b.png", "a.png"], "added");
    file(&r.join("a.png"), 3);
    assert_eq!(
        only(sc.pass()),
        ["a.png", "b.png"],
        "changed: moves to the front"
    );
    fs::write(r.join("b.png"), b"bigger now").unwrap();
    file_time(&r.join("b.png"), 2);
    assert_eq!(
        only(sc.pass()),
        ["a.png", "b.png"],
        "size change alone is a change"
    );
    fs::remove_file(r.join("a.png")).unwrap();
    assert_eq!(only(sc.pass()), ["b.png"], "deleted");
}

fn file_time(p: &Path, t: u64) {
    fs::File::options()
        .append(true)
        .open(p)
        .unwrap()
        .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + t))
        .unwrap();
}

#[test]
fn missing_folders_are_skipped_and_reported_overlaps_counted_once() {
    let r = root("overlap");
    file(&r.join("sub/a.png"), 1);
    let gone = s(&r.join("not-there"));
    let mut missing = Vec::new();
    let (total, items) = scan(&[s(&r), s(&r.join("sub")), gone.clone()], &mut missing);
    assert_eq!(
        (total, names(&items)),
        (1, vec!["a.png".to_owned()]),
        "inside two folders, once"
    );
    assert_eq!(missing, std::slice::from_ref(&gone));
    // A gallery whose only folder is missing still sends an (empty) frame, once.
    let mut sc = Scanner::new(&[spec("p", &[gone])]);
    match sc.pass().as_slice() {
        [
            Frame::Gallery {
                total: 0, items, ..
            },
        ] if items.is_empty() => {}
        other => panic!("{other:?}"),
    }
    assert!(sc.pass().is_empty());
    assert!(
        expand("relative/dir").is_empty(),
        "a relative folder is never guessed"
    );
}

#[test]
fn the_thread_sends_changes_as_they_happen() {
    let r = root("thread");
    file(&r.join("a.png"), 1);
    let (tx, rx) = mpsc::channel();
    gallery::spawn(
        Scanner::new(&[spec("p", &[s(&r)])]),
        Duration::from_millis(20),
        tx,
        |f| f,
    );
    let next = || rx.recv_timeout(Duration::from_secs(10)).expect("a frame");
    assert!(matches!(next(), Frame::Gallery { total: 1, .. }));
    file(&r.join("b.png"), 2);
    assert!(matches!(next(), Frame::Gallery { total: 2, .. }));
}

#[test]
fn once_sends_galleries_after_the_sessions() {
    let claude = standard_tree("gallery-once");
    let r = root("once");
    file(&r.join("a.png"), 1);
    let mut c = cfg(0);
    c.projects[0].gallery = vec![s(&r)];
    let mut b = Bridge::new(c, claude, Vec::new()).with_scan(|_| None);
    observatory_bridge::run::run(&mut b, true).unwrap();
    let out = lines(&b.into_output());
    let kinds: Vec<String> = out
        .iter()
        .map(|l| {
            serde_json::from_str::<serde_json::Value>(l).unwrap()["frame"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect();
    assert_eq!(kinds.first().map(String::as_str), Some("hello"));
    assert_eq!(
        kinds.last().map(String::as_str),
        Some("gallery"),
        "{kinds:?}"
    );
    assert!(kinds.iter().any(|k| k == "session"), "{kinds:?}");
    let g = Frame::from_line(out.last().unwrap()).unwrap();
    assert!(
        matches!(&g, Frame::Gallery { project, total: 1, items } if project == "my-app" && items[0].path.ends_with("/a.png")),
        "{g:?}"
    );
    assert!(!out.last().unwrap().contains("base64"), "paths only");
}

/// A `*` or `?` does not match a hidden (`.name`) directory, as in a shell glob and as
/// the walk already skips them; a pattern segment that itself starts with `.` still does.
#[test]
fn globs_skip_hidden_directories() {
    let r = root("glob-hidden");
    file(&r.join("run1/shots/a.png"), 1);
    file(&r.join(".cache/shots/h.png"), 2);
    file(&r.join(".x/shots/q.png"), 3);
    assert_eq!(
        expand(&format!("{}/*/shots", s(&r))),
        [r.join("run1/shots")]
    );
    assert_eq!(
        expand(&format!("{}/??/shots", s(&r))),
        Vec::<PathBuf>::new()
    );
    assert_eq!(
        expand(&format!("{}/.c*/shots", s(&r))),
        [r.join(".cache/shots")],
        "an explicit leading dot matches"
    );
    let (total, items) = scan(&[format!("{}/*/shots", s(&r))], &mut Vec::new());
    assert_eq!((total, names(&items)), (1, vec!["a.png".to_owned()]));
}

/// A missing folder is reported on stderr once, not on every scan; another missing
/// folder gets its own line; a folder that exists is never reported.
#[test]
fn a_missing_folder_is_logged_once() {
    let r = root("logged-once");
    file(&r.join("here/a.png"), 1);
    let gone1 = s(&r.join("gone1"));
    let gone2 = s(&r.join("gone2"));
    let mut sc = Scanner::new(&[
        spec("p", &[s(&r.join("here")), gone1.clone()]),
        spec("q", std::slice::from_ref(&gone2)),
    ]);
    let mut lines: Vec<String> = Vec::new();
    for _ in 0..3 {
        sc.pass_logged(&mut |l| lines.push(l.to_owned()));
    }
    let line = |m: &str| format!("observatory-bridge: gallery folder not found, skipped: {m}");
    assert_eq!(
        lines,
        [line(&gone1), line(&gone2)],
        "three scans, one line each"
    );
}
