//! Live data: the bridge's wire frames → what the app holds → the app's [`ViewModel`].
//!
//! [`LiveState::apply`] takes one frame and says whether anything the window shows changed; the
//! reader thread ([`crate::bridge`]) repaints only then. [`LiveState::view_model`] groups the held
//! sessions into threads by core's rule (same project + agent name, oldest session first, a
//! restart divider before each later session) and maps every core kind to an app item.
//!
//! | core | app |
//! |---|---|
//! | `UserText { text, images }` | `User { text, images }` (refs → [`Image`]: WSL paths read through `\\wsl.localhost\<distro>`) |
//! | `SlashCommand { name, args }` | `User { text: "/name args" }` |
//! | `AgentMessage { from, body, task_id }` | `AgentMessage { from, body }` (`subagent <id>` when a task id) |
//! | `Notice { notice, summary, body }` (every `NoticeKind`) | `Notice { summary, body }` |
//! | `AssistantText { text }` | `Assistant { markdown: text }` |
//! | `Thinking { text }` | `Thinking { text }` |
//! | `ToolCall(c)` | `ToolCall { summary, input, output: result.text, is_error: result.is_error, images }` (+ "… (cut)" when truncated) |
//! | thread `Restart { at_ms }` | `Restart { at_label }` (local time: "HH:MM" today, "Mon DD HH:MM" else) |
//! | `Liveness::Gone` | `Status::Gone` (dimmed) |
//! | `Liveness::NeedsYou` | `Status::NeedsYou` |
//! | `Activity::Working` (not gone) | `Status::Working` + `turn_started` |
//! | `Activity::Idle` (not gone) | `Status::Idle` |
//! | `Frame::Gallery { project, total, items }` | `Project.gallery` (replaced whole; a project with a gallery is listed even with no agents) |
//! | newest non-gone session with `status.tmux` | `Agent.target = Tmux { session_id }` (else `NotInTmux` / `NoLiveSession`) |
//! | `Frame::SendResult { id, result }` | held in [`LiveState::replies`] for the prompt box (not in the model) |

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Datelike, FixedOffset, Local, Offset, TimeZone, Utc};
use observatory_core::wire::{self, GalleryItem, PROTOCOL, SendResult};
use observatory_core::{
    Activity, Frame, ItemKind, Liveness, Session, Thread, ThreadEntry, ThreadKey, session,
};

use crate::model::{
    Agent, ChatItem, Gallery, GalleryImage, Image, Project, Role, Status, Target, ViewModel,
};

/// How to turn a session's image references into paths this process can open.
#[derive(Clone, Copy, Debug, Default)]
pub struct PathCtx<'a> {
    /// The session's log (a WSL path), for embedded images.
    pub log_path: Option<&'a str>,
    /// The bridge's WSL distro, from its `hello`.
    pub distro: Option<&'a str>,
    /// This app runs on Windows (else: inside Linux, WSL paths used as they are).
    pub windows: bool,
}

impl PathCtx<'_> {
    fn images(&self, refs: &[session::ImageRef]) -> Vec<Image> {
        refs.iter()
            .map(|r| Image::from_ref(r, self.log_path, self.distro, self.windows))
            .collect()
    }
}

/// The seat name when neither the app (`--seats` / `OBSERVATORY_SEATS`) nor the bridge config
/// names any: the orchestration-kit's own default seat.
pub const DEFAULT_SEATS: &str = "Orca";

/// Which agent names are seats. [`Seats::default`] defers to the bridge: the `seats` its `hello`
/// carries (from its config), else [`DEFAULT_SEATS`]. [`Seats::parse`] is an override from the app
/// itself (flag or env) and wins over the bridge, even when empty.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Seats(Option<Vec<String>>);

impl Seats {
    /// Comma-separated names; blanks are ignored.
    pub fn parse(list: &str) -> Self {
        Seats(Some(
            list.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect(),
        ))
    }

    /// The names in force, given what the bridge said.
    fn resolve<'a>(&'a self, bridge: &'a [String]) -> Vec<&'a str> {
        match &self.0 {
            Some(own) => own.iter().map(String::as_str).collect(),
            None if !bridge.is_empty() => bridge.iter().map(String::as_str).collect(),
            None => vec![DEFAULT_SEATS],
        }
    }

    /// `agent`'s role, given the bridge's seat list.
    pub fn role(&self, agent: &str, bridge: &[String]) -> Role {
        if self.resolve(bridge).contains(&agent) {
            Role::Seat
        } else {
            Role::Sibling
        }
    }
}

/// Seconds east of UTC at a given unix instant (the local zone, or a fixed one in tests).
pub type Offsets = fn(i64) -> i32;

/// The machine's local zone.
pub fn local_offset(t: i64) -> i32 {
    match Local.timestamp_opt(t, 0) {
        chrono::LocalResult::Single(d) | chrono::LocalResult::Ambiguous(d, _) => {
            d.offset().fix().local_minus_utc()
        }
        chrono::LocalResult::None => 0,
    }
}

pub fn utc_offset(_: i64) -> i32 {
    0
}

/// Everything the app holds from one bridge run.
#[derive(Debug, Default)]
pub struct LiveState {
    /// session_id → (project, session).
    sessions: HashMap<String, (String, Session)>,
    /// project → (total, newest items), from its latest `Gallery` frame.
    galleries: BTreeMap<String, (u32, Vec<GalleryItem>)>,
    /// Set by a `hello` with a protocol this app does not speak; frames are then ignored.
    pub refused: Option<u32>,
    /// A `hello` has arrived.
    pub greeted: bool,
    /// The bridge's WSL distro, from its `hello`.
    pub distro: Option<String>,
    /// Seat names from the bridge's config, from its `hello`.
    pub seats: Vec<String>,
    /// The bridge's one-line config note (missing or bad config), from its `hello`.
    pub note: Option<String>,
    /// Answers to this run's sends, by request id (taken by the prompt box).
    pub replies: BTreeMap<u64, SendResult>,
}

impl LiveState {
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// Apply one frame. Returns true when something the window shows changed.
    pub fn apply(&mut self, frame: Frame) -> bool {
        if let Frame::Hello {
            protocol,
            distro,
            seats,
            note,
        } = frame
        {
            let had = !self.sessions.is_empty() || !self.galleries.is_empty() || !self.greeted;
            self.sessions.clear();
            self.galleries.clear();
            self.replies.clear();
            self.greeted = true;
            self.distro = distro;
            self.seats = seats;
            self.note = note;
            self.refused = (protocol != PROTOCOL).then_some(protocol);
            return had || self.refused.is_some();
        }
        if self.refused.is_some() {
            return false;
        }
        match frame {
            Frame::Hello { .. } => unreachable!("handled above"),
            Frame::Session { project, session } => {
                let id = session.meta.session_id.clone();
                let new = (project, *session);
                match self.sessions.get(&id) {
                    Some(old) if shown_eq(old, &new) => {
                        // Keep counters current even when nothing visible moved.
                        self.sessions.insert(id, new);
                        false
                    }
                    _ => {
                        self.sessions.insert(id, new);
                        true
                    }
                }
            }
            Frame::Patch {
                ref session_id,
                ref meta,
                ref status,
                len,
                ref items,
                ref pages,
                ..
            } => {
                let Some((_, held)) = self.sessions.get_mut(session_id) else {
                    return false;
                };
                let changed = held.meta != **meta
                    || held.status != *status
                    || held.items.len() != len
                    || held.pages != *pages
                    || items
                        .iter()
                        .any(|ii| held.items.get(ii.index) != Some(&ii.item));
                wire::apply_patch(held, &frame);
                changed
            }
            Frame::Gone { session_id } => match self.sessions.get_mut(&session_id) {
                Some((_, s)) if s.status.liveness != Liveness::Gone => {
                    s.status.liveness = Liveness::Gone;
                    true
                }
                _ => false,
            },
            Frame::Gallery {
                project,
                total,
                items,
            } => {
                let new = (total, items);
                if self.galleries.get(&project) == Some(&new) {
                    return false;
                }
                self.galleries.insert(project, new);
                true
            }
            Frame::SendResult { id, result } => {
                self.replies.insert(id, result);
                true
            }
        }
    }

    /// Parse and apply one line. A bad line or an unknown frame is skipped (false).
    pub fn apply_line(&mut self, line: &str) -> bool {
        let line = line.trim();
        if line.is_empty() {
            return false;
        }
        match Frame::from_line(line) {
            Ok(f) => self.apply(f),
            Err(_) => false,
        }
    }

    /// The window's model: projects by name, agents by name within a project.
    pub fn view_model(&self, seats: &Seats, now: i64, offsets: Offsets) -> ViewModel {
        // The app's own override, else the bridge config's list, else the kit default.
        let seats = &Seats(Some(
            seats
                .resolve(&self.seats)
                .into_iter()
                .map(str::to_owned)
                .collect(),
        ));
        let mut threads: BTreeMap<ThreadKey, Thread> = BTreeMap::new();
        for (project, s) in self.sessions.values() {
            let key = ThreadKey {
                project: project.clone(),
                agent: s
                    .meta
                    .agent_name
                    .clone()
                    .unwrap_or_else(|| format!("session:{}", s.meta.session_id)),
            };
            threads.entry(key).or_default().sessions.push(s.clone());
        }
        let mut projects: Vec<Project> = Vec::new();
        for (key, mut t) in threads {
            // Core's thread order: first activity, then session id.
            t.sessions.sort_by(|a, b| {
                (a.meta.first_activity_ms, &a.meta.session_id)
                    .cmp(&(b.meta.first_activity_ms, &b.meta.session_id))
            });
            let agent = map_thread(&key, &t, seats, now, offsets, self.distro.as_deref());
            match projects.last_mut() {
                Some(p) if p.name == key.project => p.agents.push(agent),
                _ => projects.push(Project {
                    name: key.project.clone(),
                    agents: vec![agent],
                    gallery: None,
                }),
            }
        }
        for (name, (total, items)) in &self.galleries {
            let gallery = Some(map_gallery(
                *total,
                items,
                self.distro.as_deref(),
                cfg!(windows),
            ));
            match projects.binary_search_by(|p| p.name.as_str().cmp(name)) {
                Ok(i) => projects[i].gallery = gallery,
                Err(i) => projects.insert(
                    i,
                    Project {
                        name: name.clone(),
                        agents: Vec::new(),
                        gallery,
                    },
                ),
            }
        }
        ViewModel {
            projects,
            note: self.note.clone(),
        }
    }
}

/// A gallery frame's items → the app's gallery. `windows`: as in [`PathCtx`].
pub fn map_gallery(
    total: u32,
    items: &[GalleryItem],
    distro: Option<&str>,
    windows: bool,
) -> Gallery {
    let items = items
        .iter()
        .map(|it| {
            let folder = match it.path.rfind('/') {
                Some(0) => "/".to_owned(),
                Some(i) => it.path[..i].to_owned(),
                None => String::new(),
            };
            GalleryImage {
                image: Image::from_ref(
                    &session::ImageRef::File {
                        path: it.path.clone(),
                    },
                    None,
                    distro,
                    windows,
                ),
                folder,
                modified: it.mtime_ms.div_euclid(1000),
                size: it.size,
            }
        })
        .collect();
    Gallery { total, items }
}

/// Two held sessions that render the same (line counters may differ).
fn shown_eq(a: &(String, Session), b: &(String, Session)) -> bool {
    a.0 == b.0 && a.1.meta == b.1.meta && a.1.status == b.1.status && a.1.items == b.1.items
}

fn display_name(key: &ThreadKey, latest: Option<&Session>) -> String {
    if !key.agent.starts_with("session:") {
        return key.agent.clone();
    }
    latest
        .and_then(|s| s.meta.custom_title.clone().or_else(|| first_words(s)))
        .unwrap_or_else(|| {
            let id = key.agent.trim_start_matches("session:");
            format!("session {}", id.chars().take(8).collect::<String>())
        })
}

/// An unnamed session's label from the start of its first human message: its first
/// non-empty line, whitespace collapsed, cut at a word boundary near 40 characters.
fn first_words(s: &Session) -> Option<String> {
    const MAX: usize = 40;
    let text = s.items.iter().find_map(|it| match &it.kind {
        ItemKind::UserText { text, .. } => text.lines().find(|l| !l.trim().is_empty()),
        _ => None,
    })?;
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() <= MAX {
        return Some(line);
    }
    let cut: String = line.chars().take(MAX).collect();
    let cut = match cut.rfind(' ') {
        Some(i) if i > MAX / 2 => &cut[..i],
        _ => cut.as_str(),
    };
    Some(format!("{cut}…"))
}

pub fn map_status(st: &session::Status) -> Status {
    match (st.liveness, st.activity) {
        (Liveness::Gone, _) => Status::Gone,
        (Liveness::NeedsYou, _) => Status::NeedsYou,
        (_, Activity::Working) => Status::Working,
        (_, Activity::Idle) => Status::Idle,
    }
}

fn map_thread(
    key: &ThreadKey,
    t: &Thread,
    seats: &Seats,
    now: i64,
    offsets: Offsets,
    distro: Option<&str>,
) -> Agent {
    let latest = t.latest();
    let st = t.status();
    let status = map_status(&st);
    let name = display_name(key, latest);
    // Entries are the sessions' items in order with a restart divider between sessions, so the
    // divider count says which session (and log) an item came from.
    let mut session = 0;
    let items = t
        .entries()
        .into_iter()
        .map(|e| match e {
            ThreadEntry::Restart { at_ms, .. } => {
                session += 1;
                ChatItem::Restart {
                    at_label: restart_label(at_ms, now, offsets),
                }
            }
            ThreadEntry::Item(i) => {
                let ctx = PathCtx {
                    log_path: t
                        .sessions
                        .get(session)
                        .and_then(|s| s.meta.log_path.as_deref()),
                    distro,
                    windows: cfg!(windows),
                };
                map_item(i.kind, &ctx)
            }
        })
        .collect();
    Agent {
        role: seats.role(&name, &[]),
        name,
        status,
        last_activity: t.last_activity_ms().map(|ms| ms.div_euclid(1000)),
        model: latest.and_then(|s| s.meta.model.clone()),
        permission_mode: latest.and_then(|s| s.meta.permission_mode.clone()),
        turn_started: match status {
            Status::Working => st.working_since_ms.map(|ms| ms.div_euclid(1000)),
            _ => None,
        },
        items,
        pages: crate::pages::from_sessions(&t.sessions),
        target: target_of(t),
    }
}

/// Where a thread's prompt box sends: its newest live session that runs in tmux.
pub fn target_of(t: &Thread) -> Target {
    let live: Vec<&Session> = t
        .sessions
        .iter()
        .filter(|s| s.status.liveness != Liveness::Gone)
        .collect();
    match live.iter().rev().find(|s| s.status.tmux) {
        Some(s) => Target::Tmux {
            session_id: s.meta.session_id.clone(),
        },
        None if live.is_empty() => Target::NoLiveSession,
        None => Target::NotInTmux,
    }
}

pub fn map_item(kind: ItemKind, ctx: &PathCtx) -> ChatItem {
    match kind {
        ItemKind::UserText { text, images } => ChatItem::User {
            text,
            images: ctx.images(&images),
        },
        ItemKind::SlashCommand { name, args } => {
            let name = if name.starts_with('/') {
                name
            } else {
                format!("/{name}")
            };
            let text = if args.trim().is_empty() {
                name
            } else {
                format!("{name} {}", args.trim())
            };
            ChatItem::User {
                text,
                images: Vec::new(),
            }
        }
        ItemKind::AgentMessage {
            from,
            body,
            task_id,
        } => ChatItem::AgentMessage {
            from: match task_id {
                Some(id) if from == "subagent" => format!("subagent {id}"),
                _ => from,
            },
            body,
        },
        ItemKind::Notice { summary, body, .. } => ChatItem::Notice { summary, body },
        ItemKind::AssistantText { text, .. } => ChatItem::Assistant { markdown: text },
        ItemKind::Thinking { text, .. } => ChatItem::Thinking { text },
        ItemKind::ToolCall(c) => {
            let input = if c.input_truncated {
                format!("{}\n… (cut)", c.input)
            } else {
                c.input
            };
            let (output, is_error) = match c.result {
                Some(r) => (
                    Some(if r.truncated {
                        format!("{}\n… (cut)", r.text)
                    } else {
                        r.text
                    }),
                    r.is_error,
                ),
                None => (None, false),
            };
            ChatItem::ToolCall {
                summary: c.summary,
                input,
                output,
                is_error,
                images: {
                    // A file named only in a shell command is hidden when missing; a Bash result
                    // never embeds images, but those would stay visible.
                    let bash = c.name == "Bash";
                    let mut images = ctx.images(&c.images);
                    for (im, r) in images.iter_mut().zip(&c.images) {
                        im.hide_if_missing = bash && matches!(r, session::ImageRef::File { .. });
                    }
                    images
                },
            }
        }
    }
}

/// "09:12" when `at_ms` is on the same local day as `now`, "Nov 22 09:12" otherwise, "earlier"
/// when unknown.
pub fn restart_label(at_ms: Option<i64>, now: i64, offsets: Offsets) -> String {
    let Some(ms) = at_ms else {
        return "earlier".into();
    };
    let at_s = ms.div_euclid(1000);
    let local = |t: i64| -> Option<DateTime<FixedOffset>> {
        let off = FixedOffset::east_opt(offsets(t))?;
        Some(DateTime::<Utc>::from_timestamp(t, 0)?.with_timezone(&off))
    };
    let (Some(at), Some(today)) = (local(at_s), local(now)) else {
        return "earlier".into();
    };
    if (at.year(), at.ordinal()) == (today.year(), today.ordinal()) {
        at.format("%H:%M").to_string()
    } else {
        at.format("%b %-d %H:%M").to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minus6(_: i64) -> i32 {
        -6 * 3600
    }

    #[test]
    fn restart_label_is_local_and_drops_the_date_today() {
        // 2030-03-14T15:12:00Z = 09:12 at UTC-6.
        let at = 1_899_731_520_000;
        let now = 1_899_741_600; // 18:00Z = 12:00 at UTC-6, same day
        assert_eq!(restart_label(Some(at), now, minus6), "09:12");
        assert_eq!(restart_label(Some(at), now, utc_offset), "15:12");
        assert_eq!(
            restart_label(Some(at), now + 86_400, minus6),
            "Mar 14 09:12",
            "a day later shows the date"
        );
        assert_eq!(restart_label(None, now, minus6), "earlier");
        // 03:00Z on Mar 15 is still Mar 14 at UTC-6: same local day as 12:00 on Mar 14.
        assert_eq!(restart_label(Some(1_899_774_000_000), now, minus6), "21:00");
    }

    #[test]
    fn seats_parse_and_default() {
        let bridge = vec!["Lead".to_string(), "Orca".to_string()];
        let s = Seats::parse(" Lead, ,Orca ");
        assert_eq!(s.role("Lead", &[]), Role::Seat);
        assert_eq!(s.role("Orca", &[]), Role::Seat);
        assert_eq!(s.role("Sib1", &[]), Role::Sibling);
        assert_eq!(
            Seats::parse("Orca").role("Lead", &bridge),
            Role::Sibling,
            "the app's own list wins over the bridge's"
        );
        assert_eq!(
            Seats::parse("").role("Orca", &bridge),
            Role::Sibling,
            "an empty override means no seats"
        );
        assert_eq!(
            Seats::default().role("Lead", &bridge),
            Role::Seat,
            "bridge list"
        );
        assert_eq!(
            Seats::default().role("Orca", &[]),
            Role::Seat,
            "kit default"
        );
        assert_eq!(Seats::default().role("Lead", &[]), Role::Sibling);
        assert_eq!(
            Seats::default().role("orca", &[]),
            Role::Sibling,
            "names are exact"
        );
    }
}
