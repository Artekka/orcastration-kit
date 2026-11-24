//! Built-in demo data so the window and snapshot tests have something real-looking to show.
//! Replaced by the live feed in a later row.

use crate::model::{
    Agent, ChatItem, Gallery, GalleryImage, Image, ImageSrc, Project, Role, Status, ViewModel,
};

/// The fixed "now" the demo timestamps are relative to (2026-11-23 18:00:00 UTC).
pub const DEMO_NOW: i64 = 1_795_456_800;

const ORCA_REPLY: &str = r#"## Train 3 is ready to deploy

I reconciled **three rows** onto main, one at a time, and the gate is green:

1. `S1-4` — replay seek no longer drops the first frame
2. `S2-7` — stage list is *sorted by name*, not by load order
3. `S3-2` — export dialog remembers the last folder

| Row | Verifier | Verdict |
|---|---|---|
| S1-4 | Sib3 | PASS (derived) |
| S2-7 | Sib1 | PASS (derived) |
| S3-2 | Sib4 | PASS (consistency-checked) |

The gate's pass line, verbatim:

```bash
bash scripts/gate.sh
# GATE PASS (412 tests)
```

> Deploy policy is `ask`, so I need your OK before I run `scripts/deploy.sh`.

See the [build log](https://example.com/build-log) for the full write-up."#;

const SIB1_REPLY: &str = r#"Found it. The seek bug was an off-by-one in the frame index:

```rust
fn frame_at(&self, t: f64) -> usize {
    // was: (t * self.fps) as usize - 1
    (t * self.fps).floor() as usize
}
```

- RED proof: `seek_to_zero_shows_frame_zero` failed before the fix
- GREEN: all 38 replay tests pass

Reporting to Orca now."#;

const LYRA_REPLY: &str = "Batch 12 is rendering. **4 of 16** images done; the render queue is otherwise empty.\n\nI'll post the contact sheet when the batch finishes.";

fn agent(
    name: &str,
    role: Role,
    status: Status,
    ago: Option<i64>,
    model: &str,
    mode: &str,
) -> Agent {
    Agent {
        name: name.into(),
        role,
        status,
        last_activity: ago.map(|s| DEMO_NOW - s),
        model: Some(model.into()),
        permission_mode: Some(mode.into()),
        turn_started: None,
        items: vec![],
        pages: vec![],
        target: Default::default(),
    }
}

/// A demo gallery: `total` images found, a few listed (the files do not exist on this machine,
/// so the tiles say "image unavailable").
fn gallery(total: u32, folder: &str, names: &[&str]) -> Gallery {
    let items = names
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let path = format!("{folder}/{n}");
            GalleryImage {
                image: Image {
                    src: ImageSrc::File(path.clone()),
                    name: (*n).into(),
                    path: Some(path),
                    hide_if_missing: false,
                },
                folder: folder.into(),
                modified: DEMO_NOW - 90 * (i as i64 + 1),
                size: 200_000,
            }
        })
        .collect();
    Gallery { total, items }
}

fn tool(summary: &str, input: &str, output: &str) -> ChatItem {
    ChatItem::ToolCall {
        summary: summary.into(),
        input: input.into(),
        output: Some(output.into()),
        is_error: false,
        images: Vec::new(),
    }
}

/// Orca's thread on its own: markdown-heavy, tools, thinking, a restart and an agent message.
pub fn orca() -> Agent {
    let mut a = agent(
        "Orca",
        Role::Seat,
        Status::NeedsYou,
        Some(120),
        "claude-opus-5-5[1m]",
        "auto",
    );
    a.items = vec![
        ChatItem::User {
            text: "Morning. Where's train 2?".into(),
            images: Vec::new(),
        },
        ChatItem::Assistant {
            markdown: "Train 2 shipped last night as **v0.9.4**. Nothing is in flight.".into(),
        },
        ChatItem::Restart {
            at_label: "09:12".into(),
        },
        ChatItem::User {
            text: "Assemble train 3 and tell me when it's ready to deploy.".into(),
            images: Vec::new(),
        },
        ChatItem::Thinking {
            text: "Three rows are READ PASS. Reconcile them one at a time, gate after each.".into(),
        },
        tool(
            "Read docs/orchestration/AGENT_BOARD.md",
            "{\"file_path\": \"docs/orchestration/AGENT_BOARD.md\"}",
            "# Agent Orchestration Board\n| Row | Task | Status |\n|---|---|---|\n| S1-4 | replay seek | READ PASS |\n| S2-7 | stage sort | READ PASS |\n| S3-2 | export folder | READ PASS |\n| S4-1 | tooltip copy | BUILDING |",
        ),
        tool(
            "Ran git log --oneline -5",
            "git log --oneline -5",
            "a1b2c3d merge S3-2\n9f8e7d6 merge S2-7\n5a4b3c2 merge S1-4\n1122334 docs: log 41",
        ),
        ChatItem::AgentMessage {
            from: "Sib3".into(),
            body: "READ S1-4: **PASS**, derived. I re-ran the seek tests and the mutant went red as predicted.".into(),
        },
        tool(
            "Edited docs/orchestration/AGENT_BOARD.md +3 −3",
            "old: | S1-4 | replay seek | READ PASS |\nnew: | S1-4 | replay seek | ON MAIN 5a4b3c2 |",
            "The file has been updated.",
        ),
        ChatItem::Assistant {
            markdown: ORCA_REPLY.into(),
        },
    ];
    a
}

pub fn demo() -> ViewModel {
    let mut sib1 = agent(
        "Sib1",
        Role::Sibling,
        Status::Working,
        Some(5),
        "claude-opus-5-5[1m]",
        "auto",
    );
    sib1.turn_started = Some(DEMO_NOW - 45);
    sib1.items = vec![
        ChatItem::AgentMessage {
            from: "Orca".into(),
            body: "ASSIGN S1-4 → Sib1: replay seek drops the first frame. Reproduce first.".into(),
        },
        tool(
            "Ran cargo test -p replay seek",
            "cargo test -p replay seek",
            "test seek_to_zero_shows_frame_zero ... FAILED",
        ),
        ChatItem::Assistant {
            markdown: SIB1_REPLY.into(),
        },
        ChatItem::ToolCall {
            summary: "Messaged Orca".into(),
            input: "GREEN-FINAL S1-4 · 38/38 replay tests".into(),
            output: None,
            is_error: false,
            images: Vec::new(),
        },
    ];

    let mut sib2 = agent(
        "Sib2",
        Role::Sibling,
        Status::Idle,
        Some(14 * 60),
        "claude-sonnet-5-5[1m]",
        "auto",
    );
    sib2.items = vec![ChatItem::Assistant {
        markdown: "Done with S2-7. Waiting for the next assignment.".into(),
    }];
    let mut sib3 = agent(
        "Sib3",
        Role::Sibling,
        Status::Idle,
        Some(3 * 60),
        "claude-opus-5-5[1m]",
        "auto",
    );
    sib3.items = vec![ChatItem::ToolCall {
        summary: "Ran bash scripts/gate.sh".into(),
        input: "bash scripts/gate.sh".into(),
        output: Some("error: test seek_to_end failed\nGATE FAIL: cargo test (exit 101)".into()),
        is_error: true,
        images: Vec::new(),
    }];
    let sib4 = agent(
        "Sib4",
        Role::Sibling,
        Status::Gone,
        Some(5 * 3600),
        "claude-opus-5-5[1m]",
        "auto",
    );

    let mut lyra = agent(
        "Lyra",
        Role::Seat,
        Status::Working,
        Some(30),
        "claude-opus-5-5[1m]",
        "auto",
    );
    lyra.turn_started = Some(DEMO_NOW - 130);
    lyra.items = vec![ChatItem::Assistant {
        markdown: LYRA_REPLY.into(),
    }];
    let pip1 = agent(
        "Pip1",
        Role::Sibling,
        Status::Idle,
        Some(2 * 86400),
        "claude-sonnet-5-5[1m]",
        "auto",
    );
    let pip2 = agent(
        "Pip2",
        Role::Sibling,
        Status::Gone,
        Some(10 * 3600),
        "claude-opus-5-5[1m]",
        "auto",
    );

    ViewModel {
        projects: vec![
            Project {
                name: "replay-viewer".into(),
                agents: vec![sib1, orca(), sib2, sib3, sib4],
                gallery: Some(gallery(
                    180,
                    "/home/user/replay-viewer/shots/s1-4",
                    &["seek-000.png", "seek-001.png", "stage-list.png"],
                )),
            },
            Project {
                name: "asset-pipeline".into(),
                agents: vec![lyra, pip1, pip2],
                gallery: Some(gallery(
                    10_909,
                    "/home/user/asset-pipeline/out/batch-12",
                    &["render-01.png", "render-02.png", "grass.webp"],
                )),
            },
        ],
        note: None,
    }
}
