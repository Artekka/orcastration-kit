//! Wire form between the WSL bridge and the Windows app: one JSON object per line (JSON Lines) on
//! the bridge's stdout. Every frame is a [`Frame`], tagged by `"frame"`:
//!
//! ```json
//! {"frame":"hello","protocol":6,"distro":"Ubuntu","seats":["Orca"]}
//! {"frame":"session","project":"my-app","session":{"meta":{…},"status":{…},"items":[…],"stats":{…}}}
//! {"frame":"patch","session_id":"…","meta":{…},"status":{…},"stats":{…},"len":42,"items":[{"index":41,"item":{…}}]}
//! {"frame":"gone","session_id":"…"}
//! ```
//!
//! - `hello` comes first; the app refuses a `protocol` it does not know.
//! - `session` is a FULL snapshot of one session (meta, status, items). The bridge sends one when a
//!   session appears and again whenever it changes; the app replaces what it held for that
//!   `session_id` and regroups threads with [`crate::thread`] rules (same project + agent name).
//!   Items are already trimmed (see [`crate::session::MAX_TOOL_TEXT`]), so snapshots stay small.
//! - `patch` is an update to a session the app already holds from a `session` frame: new `meta`,
//!   `status` and `stats`, the session's item count `len`, and only the items that changed, by
//!   index. Apply it with [`apply_patch`]: set `items[index] = item` for each entry (an index at or
//!   past the end appends), then cut the list to `len`. So one new log line costs a few items, not
//!   the whole session. A `patch` for a session the app does not hold is ignored (a full `session`
//!   frame for it comes first).
//! - `gone` means the session's process is no longer running (the app dims it; never an error).
//! - `send_result` answers one [`Request::Send`] by its `id`: `sent` or `refused` with a reason.
//!
//! **The other direction:** the app writes [`Request`] lines (JSON Lines) on the bridge's
//! stdin. There is exactly one request, `send`: type `text` into the tmux pane of the live
//! session `session_id`, as the human's own message. Nothing else is ever accepted:
//!
//! ```json
//! {"cmd":"send","id":7,"session_id":"…","text":"hello\nsecond line"}
//! ```
//!
//! Item kinds are tagged by `"kind"` (`user_text`, `slash_command`, `agent_message`, `notice`,
//! `assistant_text`, `thinking`, `tool_call`); see [`crate::session::ItemKind`].

use serde::{Deserialize, Serialize};

use crate::pages::Page;
use crate::session::{ChatItem, LineStats, Session, SessionMeta, Status};

/// 2: images by reference (`ImageRef`), `log_path`, `Hello.distro`.
/// 3: published pages (`Session.pages`, `Patch.pages`). 4: `Gallery`.
/// 5: typing to an agent: [`Request`] on stdin, `SendResult` (sent/refused/uncertain),
/// `Status.tmux`. 6: `Hello.seats` and `Hello.note` (the bridge config).
pub const PROTOCOL: u32 = 6;

/// Longest text one [`Request::Send`] may carry, in bytes.
pub const SEND_MAX_BYTES: usize = 32 * 1024;

/// At most this many gallery images go over the wire per project: the newest.
pub const GALLERY_MAX: usize = 2_000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "frame", rename_all = "snake_case")]
pub enum Frame {
    Hello {
        protocol: u32,
        /// The bridge's WSL distro (`$WSL_DISTRO_NAME`): the app reads WSL paths through
        /// `\\wsl.localhost\<distro>\…`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        distro: Option<String>,
        /// Agent names shown as seats, from the bridge config (the app's own flag/env win).
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        seats: Vec<String>,
        /// One line for the window when the config is missing or bad: where it goes, what failed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    Session {
        project: String,
        session: Box<Session>,
    },
    Patch {
        session_id: String,
        /// Boxed only to keep `Frame` small; on the wire it is the plain object.
        meta: Box<SessionMeta>,
        status: Status,
        stats: LineStats,
        /// The session's item count after this patch.
        len: usize,
        /// Changed or new items, by index, ascending.
        items: Vec<IndexedItem>,
        /// The session's whole page list (small records).
        #[serde(default)]
        pages: Vec<Page>,
    },
    Gone {
        session_id: String,
    },
    /// A project's gallery: the newest [`GALLERY_MAX`] images of its folders, newest first.
    /// Sent whole at startup and again whenever the list changes. Paths only, never bytes.
    Gallery {
        project: String,
        /// Images found in all its folders (may exceed `items.len()`).
        total: u32,
        items: Vec<GalleryItem>,
    },
    /// The answer to the [`Request::Send`] with this `id`.
    SendResult {
        id: u64,
        result: SendResult,
    },
}

/// What happened to one send.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum SendResult {
    /// Pasted into the agent's pane and submitted with one Enter.
    Sent,
    /// Nothing was typed anywhere; `reason` is one plain sentence for the human.
    Refused { reason: String },
    /// Something failed or changed AFTER the paste started: the text may be sitting in the
    /// agent's input box (not submitted). The human checks before sending again.
    Uncertain { reason: String },
}

/// One line the app writes on the bridge's stdin. `send` is the only request there is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    /// The human pressed Send: type `text` into the pane of live session `session_id`.
    Send {
        id: u64,
        session_id: String,
        text: String,
    },
}

impl Request {
    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("request serialization cannot fail")
    }

    pub fn from_line(line: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(line)
    }
}

/// Why `text` may not be typed into a terminal, or `None` when it may. Shared by the app (to
/// say so before sending) and the bridge (which checks again). Refused: empty or blank, longer
/// than [`SEND_MAX_BYTES`], or any control character other than newline and tab. An ESC could
/// end the bracketed paste early and turn the rest into keystrokes; a CR could submit early.
pub fn send_text_problem(text: &str) -> Option<String> {
    if text.trim().is_empty() {
        return Some("The message is empty.".into());
    }
    if text.len() > SEND_MAX_BYTES {
        return Some(format!(
            "The message is too long ({} KB; at most {} KB).",
            text.len().div_ceil(1024),
            SEND_MAX_BYTES / 1024
        ));
    }
    if let Some(c) = text
        .chars()
        .find(|&c| c.is_control() && c != '\n' && c != '\t')
    {
        return Some(format!(
            "The message holds a control character (U+{:04X}) that can't be typed safely.",
            c as u32
        ));
    }
    None
}

/// One image file of a gallery.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GalleryItem {
    /// Absolute path as the bridge sees it (a WSL path).
    pub path: String,
    /// Modified time, Unix milliseconds.
    pub mtime_ms: i64,
    pub size: u64,
}

/// One item of a [`Frame::Patch`] and its position in the session's item list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexedItem {
    pub index: usize,
    pub item: ChatItem,
}

impl Frame {
    /// One line of JSON (no newline).
    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("frame serialization cannot fail")
    }

    pub fn from_line(line: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(line)
    }

    /// A [`Frame::Patch`] carrying `session`'s header and the items at `changed` (indexes past
    /// the end are skipped; duplicates are sent once).
    pub fn patch(session: &Session, changed: impl IntoIterator<Item = usize>) -> Frame {
        let mut idx: Vec<usize> = changed
            .into_iter()
            .filter(|&i| i < session.items.len())
            .collect();
        idx.sort_unstable();
        idx.dedup();
        Frame::Patch {
            session_id: session.meta.session_id.clone(),
            meta: Box::new(session.meta.clone()),
            status: session.status.clone(),
            stats: session.stats,
            len: session.items.len(),
            items: idx
                .into_iter()
                .map(|index| IndexedItem {
                    index,
                    item: session.items[index].clone(),
                })
                .collect(),
            pages: session.pages.clone(),
        }
    }
}

/// Apply a [`Frame::Patch`]'s fields to the session the app holds (see the module doc). Returns
/// false, changing nothing, when `frame` is not a patch for `held`.
pub fn apply_patch(held: &mut Session, frame: &Frame) -> bool {
    let Frame::Patch {
        session_id,
        meta,
        status,
        stats,
        len,
        items,
        pages,
    } = frame
    else {
        return false;
    };
    if *session_id != held.meta.session_id {
        return false;
    }
    held.meta = (**meta).clone();
    held.status = status.clone();
    held.stats = *stats;
    for IndexedItem { index, item } in items {
        if *index < held.items.len() {
            held.items[*index] = item.clone();
        } else {
            held.items.push(item.clone());
        }
    }
    held.items.truncate(*len);
    held.pages = pages.clone();
    true
}
