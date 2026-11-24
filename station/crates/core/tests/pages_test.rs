//! Pages an agent published, from `fixtures/synthetic_pages.jsonl` (synthetic: invented
//! values in the shape of the Artifact tool's calls and results, see `fixtures/README.md`).
//! Expected values are written out by hand.

use observatory_core::wire::{Frame, PROTOCOL, apply_patch};
use observatory_core::{Page, Session};

const SYN: &str = include_str!("fixtures/synthetic_pages.jsonl");

fn ms(ts: &str) -> Option<i64> {
    observatory_core::time::parse_ms(ts)
}

fn page(url: &str, title: &str, ts: &str, versions: u32, deleted: bool) -> Page {
    Page {
        url: url.into(),
        title: title.into(),
        time_ms: ms(ts),
        versions,
        deleted,
    }
}

fn expected() -> Vec<Page> {
    vec![
        // Published twice from the same file: one entry, the result's "Version 2", the later time,
        // the file's base name without ".html" (seat ruling). One of its ASSETS was deleted
        // (`delete` with `path`): the page itself is not.
        page(
            "https://claude.ai/artifact/Pg7Vw2Lk9Qs4Xe1Rt8Yh3n",
            "status-board",
            "2030-03-14T17:50:22.000Z",
            2,
            false,
        ),
        // Titled, then the page deleted (struck through).
        page(
            "https://claude.ai/artifact/Bq2kTitledPage9",
            "Weekly report",
            "2030-03-14T07:00:02.000Z",
            1,
            true,
        ),
        page(
            "https://claude.ai/code/artifact/0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0",
            "notes.v2",
            "2030-03-14T08:00:01.000Z",
            1,
            false,
        ),
        // The result came before the call: titled from the CALL's file, at the call's time.
        page(
            "https://claude.ai/artifact/OrphanFirst55",
            "orphan",
            "2030-03-14T10:00:00.000Z",
            1,
            false,
        ),
        // Made from a type: the new page, never the type link the result also names.
        page(
            "https://claude.ai/artifact/NewFromType77",
            "Team dashboard",
            "2030-03-14T11:00:02.000Z",
            1,
            false,
        ),
    ]
}

#[test]
fn publish_republish_delete_and_the_calls_that_make_no_page() {
    let s = Session::from_lines("-home-user-my-app", "pages-1", SYN.lines());
    assert_eq!(s.pages, expected());
    // Nothing else leaked in: quickstart's type links, list/read/open/pin results, a refused
    // publish, an errored publish.
    let all: String = s.pages.iter().map(|p| p.url.as_str()).collect();
    for never in [
        "Ty5Dm3Kc8Ww1Np6Rb2Ha9z",
        "SlidesType1",
        "ListedOther",
        "ErroredPage3",
    ] {
        assert!(!all.contains(never), "{never} became a page");
    }
    // The calls are still ordinary chat items (pages are an addition, not a replacement).
    let calls = s
        .items
        .iter()
        .filter(
            |i| matches!(&i.kind, observatory_core::ItemKind::ToolCall(c) if c.name == "Artifact"),
        )
        .count();
    assert_eq!(calls, 15);
}

#[test]
fn pages_travel_in_frames_line_by_line() {
    // The bridge's way: one line at a time, a patch per line; the app's copy is built only from
    // the first full frame and the patches.
    let mut bridge = Session::new("-home-user-my-app", "pages-1");
    let mut app: Option<Session> = None;
    for l in SYN.lines() {
        bridge.push_line(l);
        match &mut app {
            None => {
                let f = Frame::Session {
                    project: "my-app".into(),
                    session: Box::new(bridge.clone()),
                };
                let Frame::Session { session, .. } = Frame::from_line(&f.to_line()).unwrap() else {
                    unreachable!()
                };
                app = Some(*session);
            }
            Some(held) => {
                let all = 0..bridge.items.len();
                let f = Frame::from_line(&Frame::patch(&bridge, all).to_line()).unwrap();
                assert!(apply_patch(held, &f));
            }
        }
    }
    assert_eq!(app.unwrap().pages, expected());
    assert_eq!(
        PROTOCOL, 6,
        "the frame shape changed (3: pages, 4: gallery, 5: typing, 6: hello seats/note): protocol bumped"
    );
}

#[test]
fn a_frame_carries_only_small_page_records() {
    let s = Session::from_lines("-home-user-my-app", "pages-1", SYN.lines());
    let line = Frame::patch(&s, []).to_line();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    let pages = v["pages"].as_array().unwrap();
    assert_eq!(pages.len(), 5);
    for p in pages {
        let mut keys: Vec<&str> = p.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["deleted", "time_ms", "title", "url", "versions"]);
    }
}

#[test]
fn an_older_frame_without_pages_still_reads() {
    // A patch from a protocol-2 bridge has no "pages": it reads as none (the hello's protocol
    // check is what refuses an old bridge).
    let s = Session::from_lines("-home-user-my-app", "pages-1", SYN.lines());
    let mut v: serde_json::Value = serde_json::from_str(&Frame::patch(&s, []).to_line()).unwrap();
    v.as_object_mut().unwrap().remove("pages");
    let Frame::Patch { pages, .. } = Frame::from_line(&v.to_string()).unwrap() else {
        panic!("not a patch")
    };
    assert!(pages.is_empty());
}
