//! The app's own view-model. A later row fills it from `observatory-core`; this crate only
//! renders it. Times are unix seconds; "now" is passed in so rendering is deterministic.

use std::time::Duration;

pub use crate::images::{Image, ImageSrc};

/// What the status dot shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Mid-turn.
    Working,
    /// Turn finished, waiting for input.
    Idle,
    /// Blocked on the human (permission prompt, question).
    NeedsYou,
    /// Not running. Rendered dimmed, never as an error.
    Gone,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Working => "working",
            Status::Idle => "idle",
            Status::NeedsYou => "needs you",
            Status::Gone => "gone",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Seat,
    Sibling,
}

impl Role {
    pub fn label(self) -> &'static str {
        match self {
            Role::Seat => "seat",
            Role::Sibling => "sibling",
        }
    }
}

/// One entry in an agent's chat thread.
#[derive(Clone, Debug, PartialEq)]
pub enum ChatItem {
    /// Typed by the human. Right-aligned bubble; pasted images as thumbnails under it.
    User { text: String, images: Vec<Image> },
    /// Sent by another agent (arrives in the log as user-role text). Left-aligned labelled card.
    AgentMessage { from: String, body: String },
    /// The agent's reply, Markdown.
    Assistant { markdown: String },
    /// Hidden unless the "Show thinking" toggle is on.
    Thinking { text: String },
    /// One tool call, folded to `summary` (e.g. "Read docs/BRIEF.md").
    ToolCall {
        summary: String,
        input: String,
        output: Option<String>,
        is_error: bool,
        /// Thumbnails under the card: what the result showed, else the image files it names.
        images: Vec<Image>,
    },
    /// A new session with the same agent name started. `at_label` is preformatted local time.
    Restart { at_label: String },
    /// A system-ish line (task notification, compaction, command output, interrupt): a dim
    /// one-line `summary`, click to expand `body` when there is one.
    Notice { summary: String, body: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Agent {
    pub name: String,
    pub role: Role,
    pub status: Status,
    /// Unix seconds of the last log record.
    pub last_activity: Option<i64>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    /// Unix seconds the current turn started; `Some` while mid-turn.
    pub turn_started: Option<i64>,
    pub items: Vec<ChatItem>,
    /// claude.ai pages this agent published, newest first.
    pub pages: Vec<crate::pages::Page>,
    /// Where the prompt box would send. A hint: the bridge re-checks at send time.
    pub target: Target,
}

/// Whether the human can type to an agent from here.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Target {
    /// No running session (or the demo).
    #[default]
    NoLiveSession,
    /// Running, but not in tmux.
    NotInTmux,
    /// Running in tmux: send to this live session.
    Tmux { session_id: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Project {
    pub name: String,
    pub agents: Vec<Agent>,
    /// The project's "Visuals": `None` when it has no image folders configured.
    pub gallery: Option<Gallery>,
}

/// A project's image folders as the bridge last listed them: the newest images, newest first.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Gallery {
    /// Images found in all its folders; can be more than `items.len()` (the bridge sends only
    /// the newest [`observatory_core::wire::GALLERY_MAX`]).
    pub total: u32,
    pub items: Vec<GalleryImage>,
}

/// One gallery image, by reference (never bytes).
#[derive(Clone, Debug, PartialEq)]
pub struct GalleryImage {
    /// `path` is the file's WSL path, shown in the enlarged view.
    pub image: Image,
    /// The folder it is in (WSL path), for the hover caption.
    pub folder: String,
    /// Modified time, unix seconds.
    pub modified: i64,
    pub size: u64,
}

impl Gallery {
    /// Images in the folders that were not sent (beyond the newest `items.len()`).
    pub fn not_listed(&self) -> u64 {
        (self.total as u64).saturating_sub(self.items.len() as u64)
    }
}

/// Index of an agent: (project, agent) positions in `ViewModel::projects`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AgentRef {
    pub project: usize,
    pub agent: usize,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ViewModel {
    pub projects: Vec<Project>,
    /// One line from the bridge when its config is missing or bad (where the config goes).
    pub note: Option<String>,
}

impl ViewModel {
    pub fn get(&self, r: AgentRef) -> Option<(&Project, &Agent)> {
        let p = self.projects.get(r.project)?;
        Some((p, p.agents.get(r.agent)?))
    }

    /// The first agent in sidebar order, if any.
    pub fn first(&self) -> Option<AgentRef> {
        self.projects.iter().enumerate().find_map(|(pi, p)| {
            sidebar_order(p).first().map(|&ai| AgentRef {
                project: pi,
                agent: ai,
            })
        })
    }
}

/// Agent indices in sidebar order: seats first, then siblings, each group in given order.
pub fn sidebar_order(p: &Project) -> Vec<usize> {
    let mut idx: Vec<usize> = (0..p.agents.len()).collect();
    idx.sort_by_key(|&i| match p.agents[i].role {
        Role::Seat => 0,
        Role::Sibling => 1,
    });
    idx
}

/// Compact age for the sidebar: "now", "5m", "3h", "2d".
pub fn format_age(now: i64, then: i64) -> String {
    let s = (now - then).max(0);
    match s {
        0..60 => "now".into(),
        60..3600 => format!("{}m", s / 60),
        3600..86400 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86400),
    }
}

/// "working… m:ss" under the last message of a mid-turn agent.
pub fn format_working(now: i64, started: i64) -> String {
    let s = (now - started).max(0);
    format!("working… {}:{:02}", s / 60, s % 60)
}

/// Keep at most `max_lines` lines and `max_chars` characters; say how much was cut.
pub fn truncate(text: &str, max_lines: usize, max_chars: usize) -> String {
    let total_lines = text.lines().count();
    let mut out = String::new();
    let mut chars = 0;
    let mut cut = false;
    for (i, line) in text.lines().enumerate() {
        if i == max_lines {
            cut = true;
            break;
        }
        let n = line.chars().count();
        if chars + n > max_chars {
            out.extend(line.chars().take(max_chars - chars));
            cut = true;
            break;
        }
        if i > 0 {
            out.push('\n');
        }
        out.push_str(line);
        chars += n;
    }
    if cut {
        let shown = out.lines().count();
        let more = total_lines.saturating_sub(shown);
        if more > 0 {
            out.push_str(&format!("\n… {more} more lines"));
        } else {
            out.push_str(" …");
        }
    }
    out
}

/// The repaint policy, the whole of it: the UI never asks for an immediate repaint. It asks for
/// a 1 s tick only while the shown agent is mid-turn (the m:ss counter), else a 60 s tick so
/// sidebar ages stay true. Input and new data repaint on their own.
pub fn repaint_after(vm: &ViewModel, selected: Option<AgentRef>) -> Duration {
    let working = selected
        .and_then(|r| vm.get(r))
        .is_some_and(|(_, a)| a.turn_started.is_some());
    if working {
        Duration::from_secs(1)
    } else {
        Duration::from_secs(60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(name: &str, role: Role) -> Agent {
        Agent {
            name: name.into(),
            role,
            status: Status::Idle,
            last_activity: None,
            model: None,
            permission_mode: None,
            turn_started: None,
            items: vec![],
            pages: vec![],
            target: Target::default(),
        }
    }

    #[test]
    fn seat_sorts_first_whatever_its_position() {
        let p = Project {
            name: "p".into(),
            agents: vec![
                agent("S1", Role::Sibling),
                agent("Seat", Role::Seat),
                agent("S2", Role::Sibling),
            ],
            gallery: None,
        };
        assert_eq!(sidebar_order(&p), vec![1, 0, 2]);
    }

    #[test]
    fn ages() {
        assert_eq!(format_age(100, 100), "now");
        assert_eq!(format_age(159, 100), "now");
        assert_eq!(format_age(160, 100), "1m");
        assert_eq!(format_age(100 + 3599, 100), "59m");
        assert_eq!(format_age(100 + 3600, 100), "1h");
        assert_eq!(format_age(100 + 86400 * 2, 100), "2d");
        assert_eq!(format_age(50, 100), "now", "clock skew never goes negative");
    }

    #[test]
    fn working_counter() {
        assert_eq!(format_working(145, 100), "working… 0:45");
        assert_eq!(format_working(100 + 125, 100), "working… 2:05");
    }

    #[test]
    fn truncate_by_lines_and_chars() {
        assert_eq!(truncate("a\nb", 5, 100), "a\nb");
        assert_eq!(truncate("a\nb\nc\nd", 2, 100), "a\nb\n… 2 more lines");
        assert_eq!(truncate("abcdef", 5, 3), "abc …");
        assert_eq!(truncate("", 5, 3), "");
    }

    #[test]
    fn repaint_is_never_immediate_and_ticks_fast_only_mid_turn() {
        let mut a = agent("A", Role::Seat);
        let vm_idle = ViewModel {
            projects: vec![Project {
                name: "p".into(),
                agents: vec![a.clone()],
                gallery: None,
            }],
            note: None,
        };
        let r = vm_idle.first();
        assert_eq!(repaint_after(&vm_idle, r), Duration::from_secs(60));
        assert_eq!(repaint_after(&vm_idle, None), Duration::from_secs(60));
        a.turn_started = Some(1);
        let vm_busy = ViewModel {
            projects: vec![Project {
                name: "p".into(),
                agents: vec![a],
                gallery: None,
            }],
            note: None,
        };
        assert_eq!(repaint_after(&vm_busy, r), Duration::from_secs(1));
    }
}
