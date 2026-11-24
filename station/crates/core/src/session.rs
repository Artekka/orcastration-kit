//! One session log → ordered chat items, identity, and status.
//!
//! Feed lines in file order with [`Session::push_line`] (or records with [`Session::apply`]).
//! Claude Code writes one content block per line; blocks of one assistant message share a
//! `message.id` and are appended in the order they arrive, which is the order they were produced.
//!
//! What becomes an item:
//! - `user` real human text → [`ItemKind::UserText`]; slash commands → [`ItemKind::SlashCommand`].
//! - `user` that is really a message from another agent → [`ItemKind::AgentMessage`]. When the
//!   line has an `origin`, it decides (`peer` only; a human quoting a wrapper stays a human).
//!   Without one, the text must START with a `<cross-session-message>` / `<agent-message>`
//!   wrapper. A sender that is a bare hex task id is shown as `subagent` (id in `task_id`).
//! - `user` `<bash-stdout>` / `<bash-stderr>` / `<local-command-stdout|stderr>` output →
//!   [`NoticeKind::CommandOutput`] (the `<bash-input>` the human typed stays a user item).
//! - `user` task notifications and compaction summaries, `system` compaction / local-command
//!   records, and user interrupts → [`ItemKind::Notice`].
//! - other `isMeta` user lines (skill text, injected reminders) are hidden: no item.
//! - `assistant` text / thinking → [`ItemKind::AssistantText`] / [`ItemKind::Thinking`] (redacted
//!   thinking, signature only and no text, makes no item); a
//!   `tool_use` → [`ItemKind::ToolCall`], completed in place when its `tool_result` arrives (a
//!   result that arrives first is held until its call shows up).
//!
//! Status: a turn opens at any `user`/`assistant` record and closes at `system` `turn_duration`
//! (or a user interrupt). An open turn is [`Activity::Working`]. A session whose process died
//! mid-turn stays `Working` here; the bridge sets [`Liveness`] from process data.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::pages::{self, ArtifactCall, Page};
use crate::record::{AssistantRecord, Block, Parsed, Record, RecordKind, UserRecord, parse_line};
use crate::time::parse_ms;

/// Longest tool input / result text kept per item (characters). Longer text is cut and flagged.
pub const MAX_TOOL_TEXT: usize = 4000;
/// Longest command shown in a one-line tool summary (characters).
pub const MAX_SUMMARY: usize = 80;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Activity {
    Working,
    #[default]
    Idle,
}

/// Filled in by the bridge from process data; the log alone cannot know it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Liveness {
    #[default]
    Unknown,
    Running,
    NeedsYou,
    Gone,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Status {
    pub activity: Activity,
    /// When the open turn started (Unix ms); `None` while idle.
    pub working_since_ms: Option<i64>,
    pub liveness: Liveness,
    /// Latest `system` `away_summary` text: a one-line recap for an overview.
    pub away_summary: Option<String>,
    /// Set by the bridge: the live process runs in a tmux pane, so the app may offer the
    /// prompt box. A hint for the UI only: the bridge re-resolves the pane at every send.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub tmux: bool,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct SessionMeta {
    pub session_id: String,
    /// Log directory slug (`~/.claude/projects/<slug>`).
    pub slug: String,
    pub agent_name: Option<String>,
    pub custom_title: Option<String>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    pub mode: Option<String>,
    /// Last `cwd` seen; tool paths under it are shown relative.
    pub cwd: Option<String>,
    /// The session's log file (a WSL path), for reading embedded images back. Set by the bridge.
    #[serde(default)]
    pub log_path: Option<String>,
    pub first_activity_ms: Option<i64>,
    pub last_activity_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatItem {
    pub uuid: Option<String>,
    pub timestamp_ms: Option<i64>,
    #[serde(flatten)]
    pub kind: ItemKind,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ItemKind {
    UserText {
        text: String,
        /// Pasted images, by reference (bytes never travel; see [`ImageRef`]).
        #[serde(default)]
        images: Vec<ImageRef>,
    },
    SlashCommand {
        name: String,
        args: String,
    },
    /// A message from another agent (cross-session message or subagent hand-back).
    AgentMessage {
        /// Sender's name; `subagent` for a subagent hand-back (its id is in `task_id`).
        from: String,
        body: String,
        /// The subagent's task id when `from` is `subagent`.
        #[serde(default)]
        task_id: Option<String>,
    },
    /// System-ish line: one-line `summary`, expandable `body`.
    Notice {
        notice: NoticeKind,
        summary: String,
        body: String,
    },
    AssistantText {
        message_id: Option<String>,
        text: String,
    },
    Thinking {
        message_id: Option<String>,
        text: String,
    },
    ToolCall(ToolCall),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeKind {
    TaskNotification,
    Compacted,
    CompactSummary,
    LocalCommand,
    Interrupted,
    /// Output of a `!` shell command or a local slash command (`<bash-stdout>` etc.).
    CommandOutput,
    Info,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub message_id: Option<String>,
    /// One line: `Read src/x.rs`, `Ran git log …`, `Edited a.rs`, `Messaged Sib1`, or the tool name.
    pub summary: String,
    /// Pretty JSON of the input, cut at [`MAX_TOOL_TEXT`].
    pub input: String,
    pub input_truncated: bool,
    pub result: Option<ToolResult>,
    /// Images this call involves: the image parts of its result when it has any (exactly what
    /// the agent saw), else the image files its input names. One thumbnail per image.
    #[serde(default)]
    pub images: Vec<ImageRef>,
}

/// Where an image can be read from. Only the reference travels; the app reads the bytes itself.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum ImageRef {
    /// An image block inside the session's own log ([`SessionMeta::log_path`]).
    Embedded {
        /// Absolute byte offset of the line's first byte in the log file; `None` when the line
        /// was parsed without knowing it (then the image cannot be read back).
        line_offset: Option<u64>,
        /// The line's length in bytes, without its newline.
        line_len: u64,
        /// Index of the block in the line's `message.content` array.
        block: usize,
        /// Index of the image inside a `tool_result` block's `content` array.
        part: Option<usize>,
        media_type: Option<String>,
        /// The file the agent read it from (a `Read` call's `file_path`), when known.
        path: Option<String>,
    },
    /// An image file a tool call names, absolute (WSL path or a Windows `X:\…` path).
    File { path: String },
}

impl ImageRef {
    /// The file path to show for it, if any.
    pub fn path(&self) -> Option<&str> {
        match self {
            ImageRef::Embedded { path, .. } => path.as_deref(),
            ImageRef::File { path } => Some(path),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolResult {
    pub text: String,
    pub truncated: bool,
    pub is_error: bool,
}

/// Counters for lines that did not become chat (for diagnostics, never errors).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct LineStats {
    pub records: u64,
    pub malformed: u64,
    pub unknown_blocks: u64,
    pub duplicates: u64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Session {
    pub meta: SessionMeta,
    pub status: Status,
    pub items: Vec<ChatItem>,
    pub stats: LineStats,
    /// claude.ai pages this session published (see [`crate::pages`]).
    #[serde(default)]
    pub pages: Vec<Page>,
    /// `Artifact` calls still waiting for their result.
    #[serde(skip)]
    artifact_calls: HashMap<String, ArtifactCall>,
    /// tool_use id → index in `items`.
    #[serde(skip)]
    tool_index: HashMap<String, usize>,
    /// Results that arrived before their call (with their embedded images).
    #[serde(skip)]
    orphan_results: HashMap<String, (ToolResult, Vec<ImageRef>)>,
    /// The line being applied: (absolute byte offset, byte length), when known.
    #[serde(skip)]
    line_at: Option<(u64, u64)>,
    /// Home directory, for resolving `~/` in tool paths. Set by the bridge.
    #[serde(skip)]
    pub home: Option<String>,
    #[serde(skip)]
    seen_uuids: HashSet<String>,
}

fn cut(s: &str, max: usize) -> (String, bool) {
    match s.char_indices().nth(max) {
        Some((i, _)) => (format!("{}…", &s[..i]), true),
        None => (s.to_owned(), false),
    }
}

/// User-line wrappers for `!` shell and local-command output (never a human item).
const COMMAND_OUTPUT_TAGS: [&str; 4] = [
    "bash-stdout",
    "bash-stderr",
    "local-command-stdout",
    "local-command-stderr",
];

/// A subagent hand-back names its sender by a bare task id: lowercase hex with a digit, at
/// least 6 long (`a7c3e9f1b5d2486ce`). A name like `facade` or `Bead` is not one.
fn is_task_id(s: &str) -> bool {
    s.len() >= 6
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && s.bytes().any(|b| b.is_ascii_digit())
}

/// Inner text of the first `<tag …>…</tag>` in `s`, if present.
fn tag_inner<'a>(s: &'a str, tag: &str) -> Option<&'a str> {
    let open = s.find(&format!("<{tag}"))?;
    let after = &s[open + tag.len() + 1..];
    if !after.starts_with(['>', ' ', '\n']) {
        return None;
    }
    let body_start = after.find('>')? + 1;
    let body = &after[body_start..];
    let end = body.find(&format!("</{tag}>")).unwrap_or(body.len());
    Some(body[..end].trim())
}

/// Value of `attr="…"` inside the first `<tag …>` opener.
fn tag_attr(s: &str, tag: &str, attr: &str) -> Option<String> {
    let open = s.find(&format!("<{tag} "))?;
    let head = &s[open..open + s[open..].find('>')?];
    let key = format!(" {attr}=\"");
    let v = &head[head.find(&key)? + key.len()..];
    Some(v[..v.find('"')?].to_owned())
}

impl Session {
    pub fn new(slug: impl Into<String>, session_id: impl Into<String>) -> Self {
        let mut s = Self::default();
        s.meta.slug = slug.into();
        s.meta.session_id = session_id.into();
        s
    }

    /// Build a session from a whole file's text (lines in order).
    pub fn from_lines<'a>(
        slug: &str,
        session_id: &str,
        lines: impl IntoIterator<Item = &'a str>,
    ) -> Self {
        let mut s = Self::new(slug, session_id);
        for l in lines {
            s.push_line(l);
        }
        s
    }

    /// Parse and apply one complete line that starts at absolute byte `offset` of the log and is
    /// `len` bytes long (without its newline). Embedded images then point back at it.
    pub fn push_line_at(&mut self, line: &str, offset: u64, len: u64) {
        self.line_at = Some((offset, len));
        self.push_line(line);
        self.line_at = None;
    }

    fn embedded(&self, block: usize, part: Option<usize>, media_type: Option<String>) -> ImageRef {
        ImageRef::Embedded {
            line_offset: self.line_at.map(|(o, _)| o),
            line_len: self.line_at.map_or(0, |(_, l)| l),
            block,
            part,
            media_type,
            path: None,
        }
    }

    /// Parse and apply one complete line.
    pub fn push_line(&mut self, line: &str) {
        match parse_line(line) {
            Parsed::Record(r) => self.apply(r),
            Parsed::Blank => {}
            Parsed::Malformed(_) => self.stats.malformed += 1,
        }
    }

    pub fn apply(&mut self, r: Record) {
        self.stats.records += 1;
        if let Some(u) = &r.uuid
            && !self.seen_uuids.insert(u.clone())
        {
            self.stats.duplicates += 1;
            return;
        }
        let ts = r.timestamp.as_deref().and_then(parse_ms);
        let is_chat = matches!(
            r.kind,
            RecordKind::User(_) | RecordKind::Assistant(_) | RecordKind::System(_)
        );
        if is_chat {
            if let Some(t) = ts {
                let m = &mut self.meta;
                m.first_activity_ms = Some(m.first_activity_ms.map_or(t, |f| f.min(t)));
                m.last_activity_ms = Some(m.last_activity_ms.map_or(t, |l| l.max(t)));
            }
            if let Some(c) = &r.cwd {
                self.meta.cwd = Some(c.clone());
            }
        }
        let uuid = r.uuid.clone();
        match r.kind {
            RecordKind::AgentName(n) => self.meta.agent_name = Some(n),
            RecordKind::PermissionMode(p) => self.meta.permission_mode = Some(p),
            RecordKind::Mode(m) => self.meta.mode = Some(m),
            RecordKind::CustomTitle(t) => self.meta.custom_title = Some(t),
            RecordKind::User(u) => {
                self.open_turn(ts);
                self.user(u, uuid, ts);
            }
            RecordKind::Assistant(a) => {
                self.open_turn(ts);
                self.assistant(a, uuid, ts);
            }
            RecordKind::System(sys) => match sys.subtype.as_deref() {
                Some("turn_duration") => self.close_turn(),
                Some("away_summary") => self.status.away_summary = sys.content,
                Some("compact_boundary") => self.notice(
                    NoticeKind::Compacted,
                    sys.content
                        .unwrap_or_else(|| "Conversation compacted".into()),
                    String::new(),
                    uuid,
                    ts,
                ),
                Some("informational") => {
                    let body = sys.content.unwrap_or_default();
                    let (summary, _) = cut(body.lines().next().unwrap_or(""), MAX_SUMMARY);
                    self.notice(NoticeKind::Info, summary, body, uuid, ts)
                }
                Some("local_command") => {
                    let body = sys.content.unwrap_or_default();
                    let out = tag_inner(&body, "local-command-stdout")
                        .unwrap_or(&body)
                        .to_owned();
                    self.notice(
                        NoticeKind::LocalCommand,
                        "Local command".into(),
                        out,
                        uuid,
                        ts,
                    )
                }
                _ => {}
            },
            RecordKind::Other => {}
        }
    }

    fn open_turn(&mut self, ts: Option<i64>) {
        if self.status.activity == Activity::Idle {
            self.status.activity = Activity::Working;
            self.status.working_since_ms = ts;
        }
    }

    fn close_turn(&mut self) {
        self.status.activity = Activity::Idle;
        self.status.working_since_ms = None;
    }

    fn push(&mut self, kind: ItemKind, uuid: Option<String>, ts: Option<i64>) {
        self.items.push(ChatItem {
            uuid,
            timestamp_ms: ts,
            kind,
        });
    }

    fn notice(
        &mut self,
        notice: NoticeKind,
        summary: String,
        body: String,
        uuid: Option<String>,
        ts: Option<i64>,
    ) {
        self.push(
            ItemKind::Notice {
                notice,
                summary,
                body,
            },
            uuid,
            ts,
        );
    }

    fn user(&mut self, u: UserRecord, uuid: Option<String>, ts: Option<i64>) {
        let mut text = String::new();
        let mut images = Vec::new();
        for (bi, b) in u.blocks.iter().enumerate() {
            match b {
                Block::Text(t) => {
                    if !text.is_empty() {
                        text.push('\n');
                    }
                    text.push_str(t);
                }
                Block::Image {
                    media_type,
                    embedded,
                } => {
                    if *embedded && !u.content_was_string {
                        images.push(self.embedded(bi, None, media_type.clone()));
                    }
                }
                Block::ToolResult {
                    tool_use_id,
                    content,
                    is_error,
                    images: parts,
                } => {
                    let (text, truncated) = cut(content, MAX_TOOL_TEXT);
                    let res = ToolResult {
                        text,
                        truncated,
                        is_error: *is_error,
                    };
                    let shown = parts
                        .iter()
                        .map(|(pi, mt)| self.embedded(bi, Some(*pi), mt.clone()))
                        .collect();
                    self.attach_result(tool_use_id, res, shown);
                    if let Some(ac) = self.artifact_calls.remove(tool_use_id) {
                        pages::apply(&mut self.pages, &ac, content, *is_error, ts);
                    }
                }
                Block::Unknown(_) => self.stats.unknown_blocks += 1,
                Block::Thinking(_) | Block::ToolUse { .. } => {}
            }
        }
        if text.is_empty() && images.is_empty() {
            return; // pure tool-result line
        }
        // An explicit origin decides (a human quoting a wrapper stays a human). Without one, a
        // wrapper counts only when the text starts with it.
        let origin = u.origin_kind.as_deref();
        let peer_wrapper = ["cross-session-message", "agent-message"]
            .into_iter()
            .find(|t| tag_inner(&text, t).is_some());
        let starts_with_wrapper =
            peer_wrapper.is_some_and(|t| text.trim_start().starts_with(&format!("<{t}")));
        let is_peer = match origin {
            Some(o) => o == "peer",
            None => starts_with_wrapper,
        };
        if is_peer {
            let tag = peer_wrapper.unwrap_or("cross-session-message");
            let sender = u
                .origin_name
                .clone()
                .or_else(|| tag_attr(&text, tag, "from-name"))
                .or_else(|| tag_attr(&text, tag, "from"))
                .unwrap_or_else(|| "another agent".into());
            let (from, task_id) = if is_task_id(&sender) {
                ("subagent".to_owned(), Some(sender))
            } else {
                (sender, None)
            };
            let body = u
                .origin_body
                .clone()
                .or_else(|| tag_inner(&text, tag).map(str::to_owned))
                .unwrap_or(text);
            return self.push(
                ItemKind::AgentMessage {
                    from,
                    body,
                    task_id,
                },
                uuid,
                ts,
            );
        }
        if origin == Some("task-notification")
            || text.trim_start().starts_with("<task-notification>")
        {
            let summary = tag_inner(&text, "summary")
                .or_else(|| tag_inner(&text, "status"))
                .unwrap_or("Background task update");
            let (summary, _) = cut(summary, MAX_SUMMARY * 2);
            return self.notice(NoticeKind::TaskNotification, summary, text, uuid, ts);
        }
        if u.is_compact_summary {
            return self.notice(
                NoticeKind::CompactSummary,
                "Summary of the earlier conversation".into(),
                text,
                uuid,
                ts,
            );
        }
        if u.is_meta {
            return; // skill text, injected reminders, caveats
        }
        if text.starts_with("[Request interrupted by user") {
            self.close_turn();
            return self.notice(
                NoticeKind::Interrupted,
                "Interrupted".into(),
                text,
                uuid,
                ts,
            );
        }
        let t = text.trim_start();
        if COMMAND_OUTPUT_TAGS
            .iter()
            .any(|tag| t.starts_with(&format!("<{tag}>")))
        {
            let body = COMMAND_OUTPUT_TAGS
                .iter()
                .filter_map(|tag| tag_inner(t, tag))
                .filter(|b| !b.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            let first = body.lines().next().unwrap_or("").trim();
            let (summary, _) = cut(
                if first.is_empty() {
                    "Command output"
                } else {
                    first
                },
                MAX_SUMMARY,
            );
            return self.notice(NoticeKind::CommandOutput, summary, body, uuid, ts);
        }
        if t.starts_with("<command-message>") || t.starts_with("<command-name>") {
            let name = tag_inner(t, "command-name").unwrap_or("").to_owned();
            let args = tag_inner(t, "command-args").unwrap_or("").to_owned();
            return self.push(ItemKind::SlashCommand { name, args }, uuid, ts);
        }
        self.push(ItemKind::UserText { text, images }, uuid, ts);
    }

    fn attach_result(&mut self, id: &str, res: ToolResult, shown: Vec<ImageRef>) {
        match self.tool_index.get(id) {
            Some(&i) => {
                if let ItemKind::ToolCall(c) = &mut self.items[i].kind {
                    c.result = Some(res);
                    use_shown_images(c, shown);
                }
            }
            None => {
                self.orphan_results.insert(id.to_owned(), (res, shown));
            }
        }
    }

    fn assistant(&mut self, a: AssistantRecord, uuid: Option<String>, ts: Option<i64>) {
        if let Some(m) = a.model.filter(|m| !m.starts_with('<')) {
            self.meta.model = Some(m);
        }
        let mid = a.message_id;
        for b in a.blocks {
            match b {
                Block::Text(text) => self.push(
                    ItemKind::AssistantText {
                        message_id: mid.clone(),
                        text,
                    },
                    uuid.clone(),
                    ts,
                ),
                // Redacted thinking (signature only) carries no text: no item.
                Block::Thinking(text) if text.trim().is_empty() => {}
                Block::Thinking(text) => self.push(
                    ItemKind::Thinking {
                        message_id: mid.clone(),
                        text,
                    },
                    uuid.clone(),
                    ts,
                ),
                Block::ToolUse { id, name, input } => {
                    let raw_input = &input;
                    let summary = tool_summary(&name, &input, self.meta.cwd.as_deref());
                    let pretty = serde_json::to_string_pretty(&input).unwrap_or_default();
                    let (input, input_truncated) = cut(&pretty, MAX_TOOL_TEXT);
                    let named = image_files(
                        &name,
                        raw_input,
                        self.meta.cwd.as_deref(),
                        self.home.as_deref(),
                    );
                    let artifact = ArtifactCall::from_tool(&name, raw_input);
                    let orphan = self.orphan_results.remove(&id);
                    self.tool_index.insert(id.clone(), self.items.len());
                    let mut call = ToolCall {
                        id,
                        name,
                        message_id: mid.clone(),
                        summary,
                        input,
                        input_truncated,
                        result: None,
                        images: named,
                    };
                    if let Some((res, shown)) = orphan {
                        call.result = Some(res);
                        use_shown_images(&mut call, shown);
                    }
                    if let Some(ac) = artifact {
                        match &call.result {
                            // The result came first: apply it now (its text is the cut copy).
                            Some(r) => {
                                pages::apply(&mut self.pages, &ac, &r.text, r.is_error, ts);
                            }
                            None => {
                                self.artifact_calls.insert(call.id.clone(), ac);
                            }
                        }
                    }
                    self.push(ItemKind::ToolCall(call), uuid.clone(), ts);
                }
                Block::Unknown(_) => self.stats.unknown_blocks += 1,
                Block::ToolResult { .. } | Block::Image { .. } => {}
            }
        }
    }

    /// Label for the sidebar: agent name, else custom title, else `session <id prefix>`.
    pub fn display_name(&self) -> String {
        self.meta
            .agent_name
            .clone()
            .or_else(|| self.meta.custom_title.clone())
            .unwrap_or_else(|| {
                let id: String = self.meta.session_id.chars().take(8).collect();
                format!("session {id}")
            })
    }
}

/// A result's embedded images replace the files the call named: what the agent saw wins, even
/// if the file changed since. A single named file becomes their caption path.
fn use_shown_images(c: &mut ToolCall, shown: Vec<ImageRef>) {
    if shown.is_empty() {
        return;
    }
    let caption = match c.images.as_slice() {
        [ImageRef::File { path }] => Some(path.clone()),
        _ => None,
    };
    c.images = shown
        .into_iter()
        .map(|mut r| {
            if let ImageRef::Embedded { path, .. } = &mut r {
                *path = caption.clone();
            }
            r
        })
        .collect();
}

/// True for a name ending in `.png`, `.jpg`, `.jpeg` or `.webp` (any case).
pub fn is_image_path(p: &str) -> bool {
    let l = p.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".webp"]
        .iter()
        .any(|e| l.len() > e.len() && l.ends_with(e))
}

fn is_windows_abs(p: &str) -> bool {
    let b = p.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/')
}

/// `p` as an absolute path: Windows `X:\…` and `/…` as given, `~/…` under `home`, anything else
/// under `cwd`, with `.` and `..` folded. `None` when it cannot be made absolute.
pub fn resolve_path(p: &str, cwd: Option<&str>, home: Option<&str>) -> Option<String> {
    if is_windows_abs(p) {
        return Some(p.to_owned());
    }
    let joined = if p.starts_with('/') {
        p.to_owned()
    } else if let Some(rest) = p.strip_prefix("~/") {
        format!("{}/{rest}", home?.trim_end_matches('/'))
    } else if p.starts_with('~') {
        return None; // ~user/…
    } else {
        format!(
            "{}/{p}",
            cwd.filter(|c| c.starts_with('/'))?.trim_end_matches('/')
        )
    };
    let mut out: Vec<&str> = Vec::new();
    for seg in joined.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    Some(format!("/{}", out.join("/")))
}

fn new_word(cur: &mut Option<Word>, at: usize) -> &mut Word {
    cur.get_or_insert_with(|| Word {
        text: String::new(),
        quoted: Vec::new(),
        bare: false,
        fragment: false,
        literal_at: Vec::new(),
        redir: false,
        start: at,
        end: at,
    })
}

/// A shell word: its text after quote removal, the contents of its quoted parts, and whether
/// any of it was outside quotes.
struct Word {
    text: String,
    quoted: Vec<String>,
    bare: bool,
    /// In code: it touches a bracket (`[0-9]+.png`, `{n}.png`), so it is part of a pattern or
    /// an expression, not a name.
    fragment: bool,
    /// Per char of `text`: it was quoted or escaped, so a shell does not expand it (`"~/a.png"`).
    literal_at: Vec<bool>,
    /// The target of a redirection (`> out.png`, `2>/dev/null`).
    redir: bool,
    /// Char range of the word in the tokenized text, quotes included.
    start: usize,
    end: usize,
}

impl Word {
    fn push_bare(&mut self, c: char) {
        self.text.push(c);
        self.literal_at.push(false);
        self.bare = true;
    }
    fn push_literal(&mut self, q: String) {
        self.text.push_str(&q);
        self.literal_at.extend(q.chars().map(|_| true));
        self.quoted.push(q);
    }
}

enum Tok {
    Word(Word),
    /// `;`, newline, `&&`, `||`, `|`, `&`, `(`, `)`: the text of the operator.
    Op(&'static str),
}

/// Split a shell command into words and command separators, the way a POSIX shell would for
/// the cases that matter here: quotes (a quoted space stays in the word), backslash escapes,
/// comments, and here-documents (their bodies are data and are skipped). Redirections end a
/// word; their target is the next word. `script`: the text is quoted code (an inline Python or
/// shell script), where `, [ ] { } = :` outside quotes also end a word.
fn shell_tokens(cmd: &str, script: bool) -> Vec<Tok> {
    let s: Vec<char> = cmd.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    let mut cur: Option<Word> = None;
    // Here-doc delimiters waiting for the end of the current line: (delimiter, strip tabs).
    let mut heredocs: Vec<(String, bool)> = Vec::new();
    // After `<<`: the next word is a here-doc delimiter. After `<<<`: the next word is data.
    let mut next_is: Option<&'static str> = None;
    // After `>`, `<`, `&>`: the next word is a redirection target.
    let mut redir_next = false;
    fn end(
        cur: &mut Option<Word>,
        out: &mut Vec<Tok>,
        next_is: &mut Option<&'static str>,
        heredocs: &mut Vec<(String, bool)>,
        redir_next: &mut bool,
        at: usize,
    ) {
        if let Some(mut w) = cur.take() {
            w.end = at;
            match next_is.take() {
                Some(k) if k.starts_with("heredoc") => heredocs.push((w.text, k == "heredoc-")),
                Some(_) => {} // here-string data
                None => {
                    w.redir = std::mem::take(redir_next);
                    out.push(Tok::Word(w));
                }
            }
        }
    }
    macro_rules! end {
        () => {
            end(
                &mut cur,
                &mut out,
                &mut next_is,
                &mut heredocs,
                &mut redir_next,
                i,
            )
        };
    }
    while i < s.len() {
        let c = s[i];
        match c {
            '\\' => {
                if s.get(i + 1) == Some(&'\n') {
                    i += 2; // line continuation
                    continue;
                }
                if let Some(&n) = s.get(i + 1) {
                    // Escaped: literal, like a quoted char, but it does not end a code literal.
                    let w = new_word(&mut cur, i);
                    w.text.push(n);
                    w.literal_at.push(true);
                    w.bare = true;
                }
                i += 2;
            }
            '\'' => {
                let start = i + 1;
                let close = s[start..]
                    .iter()
                    .position(|&x| x == '\'')
                    .map(|p| start + p);
                let stop = close.unwrap_or(s.len());
                let q: String = s[start..stop].iter().collect();
                new_word(&mut cur, i).push_literal(q);
                i = stop + 1;
            }
            '"' => {
                let open = i;
                let mut q = String::new();
                i += 1;
                while i < s.len() && s[i] != '"' {
                    if s[i] == '\\' && matches!(s.get(i + 1), Some('"' | '\\' | '$' | '`' | '\n')) {
                        if s[i + 1] != '\n' {
                            q.push(s[i + 1]);
                        }
                        i += 2;
                        continue;
                    }
                    q.push(s[i]);
                    i += 1;
                }
                i += 1;
                new_word(&mut cur, open).push_literal(q);
            }
            '#' if cur.is_none() => {
                while i < s.len() && s[i] != '\n' {
                    i += 1;
                }
            }
            ' ' | '\t' => {
                end!();
                i += 1;
            }
            '\n' => {
                end!();
                redir_next = false;
                out.push(Tok::Op("\n"));
                i += 1;
                // Skip each pending here-doc body, up to its delimiter line.
                for (delim, strip) in std::mem::take(&mut heredocs) {
                    loop {
                        if i >= s.len() {
                            break;
                        }
                        let eol = s[i..]
                            .iter()
                            .position(|&x| x == '\n')
                            .map_or(s.len(), |p| i + p);
                        let line: String = s[i..eol].iter().collect();
                        i = eol + 1;
                        let line = if strip {
                            line.trim_start_matches('\t')
                        } else {
                            &line
                        };
                        if line == delim {
                            break;
                        }
                    }
                }
            }
            '&' if s.get(i + 1) == Some(&'>') => {
                // `&>file`: a redirection, not a background job.
                end!();
                redir_next = true;
                i += 2;
                while i < s.len() && s[i] == '>' {
                    i += 1;
                }
            }
            ';' | '&' | '|' | '(' | ')' => {
                end!();
                redir_next = false;
                let two = matches!(c, '&' | '|') && s.get(i + 1) == Some(&c);
                let op = match (c, two) {
                    ('&', true) => "&&",
                    ('|', true) => "||",
                    ('&', false) => "&",
                    ('|', false) => "|",
                    (';', _) => ";",
                    ('(', _) => "(",
                    _ => ")",
                };
                i += if two { 2 } else { 1 };
                out.push(Tok::Op(op));
            }
            '<' | '>' => {
                // `2>`, `1>>`: the digits name a file descriptor, not a word.
                if cur.as_ref().is_some_and(|w| {
                    w.quoted.is_empty() && w.text.chars().all(|d| d.is_ascii_digit())
                }) {
                    cur = None;
                }
                end!();
                if c == '<' && s.get(i + 1) == Some(&'<') {
                    if s.get(i + 2) == Some(&'<') {
                        next_is = Some("herestring");
                        i += 3;
                    } else if s.get(i + 2) == Some(&'-') {
                        next_is = Some("heredoc-");
                        i += 3;
                    } else {
                        next_is = Some("heredoc");
                        i += 2;
                    }
                } else {
                    // `>`, `>>`, `<`, `>&`, `&>`: the target is the next word.
                    redir_next = true;
                    i += 1;
                    while i < s.len() && matches!(s[i], '>' | '&' | '|') {
                        i += 1;
                    }
                }
            }
            ',' | '[' | ']' | '{' | '}' | '=' | ':' if script => {
                let bracket = matches!(c, '[' | ']' | '{' | '}');
                if bracket && let Some(w) = &mut cur {
                    w.fragment = true;
                }
                end!();
                i += 1;
                // A word starting right after a bracket is a fragment too.
                if bracket
                    && s.get(i)
                        .is_some_and(|n| !n.is_whitespace() && !"[]{},=:;&|()<>".contains(*n))
                {
                    new_word(&mut cur, i).fragment = true;
                }
            }
            _ => {
                new_word(&mut cur, i).push_bare(c);
                i += 1;
            }
        }
    }
    end!();
    out
}

/// A plain image path token: an image name, no pattern (`*`, `?`, `[`, `{`) and no expansion
/// (`$`, a backquote).
fn plain_image(t: &str) -> bool {
    !t.is_empty() && !t.contains(['*', '?', '[', '{', '}', '$', '`']) && is_image_path(t)
}

/// True when bash expands the `~` at char `at` of `w`: nothing from it up to the first
/// unquoted `/` was quoted (`~"/q.png"` and `"~"/q.png` stay `./~/q.png`), and, when it is not
/// at the start, the word is shaped like an assignment, `name=~…` or `name+=~…` with that part
/// unquoted (bash expands those even as arguments; `--out=~/a.png` and `x=y=~/a.png` stay
/// literal).
fn tilde_expands(w: &Word, at: usize) -> bool {
    let chars: Vec<char> = w.text.chars().collect();
    let lit = |k: usize| w.literal_at.get(k).copied().unwrap_or(true);
    let end = (at + 1..chars.len())
        .find(|&k| chars[k] == '/' && !lit(k))
        .unwrap_or(chars.len());
    if (at..end).any(lit) {
        return false;
    }
    if at == 0 {
        return true;
    }
    let prefix: String = chars[..at].iter().collect();
    let name = prefix
        .strip_suffix('=')
        .map(|n| n.strip_suffix('+').unwrap_or(n));
    let is_name = name.is_some_and(|n| {
        let mut c = n.chars();
        c.next()
            .is_some_and(|f| f == '_' || f.is_ascii_alphabetic())
            && c.all(|x| x == '_' || x.is_ascii_alphanumeric())
    });
    is_name && !(0..at).any(lit)
}

/// True when a quoted string reads as code rather than one file name: a line break, shell or
/// code punctuation, an option, or more than one image name. `"my shot.png"` is a file;
/// `'convert a.png b.png'` is a script. When unsure it stays one name, which at worst names a
/// file that does not exist (nothing shown), never another file.
fn looks_like_code(q: &str) -> bool {
    let pieces = || q.split_whitespace();
    q.contains(['\n', ';', '|', '&', '(', ')', '=', '\'', '"'])
        || pieces().any(|p| p.starts_with('-'))
        || pieces().filter(|p| is_image_path(p)).count() > 1
}

/// True when `text` may change directory itself (`cd`, `chdir`, `pushd`), so a relative path
/// inside it cannot be placed.
fn changes_dir(text: &str) -> bool {
    text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .any(|w| matches!(w, "cd" | "chdir" | "pushd" | "popd" | "cwd"))
}

/// Image files a shell command names, as absolute paths. Relative ones are placed against the
/// directory of the last `cd` before them in the same command (`cwd` before any). A `cd` that
/// cannot be followed for sure (a variable, `-`, `pushd`/`popd`, inside a subshell, a pipeline
/// or a background job, or after `||`) makes the relative paths after it unplaceable: they are
/// dropped, never guessed. Here-doc bodies and comments name nothing.
///
/// A quoted word that is not itself an image path (an inline script: `python -c "…"`) is read
/// as code: only whole words and whole string literals count (`open('a.png')` names `a.png`;
/// `D+'/a.png'` and `f'{n}.png'` name nothing), and if it changes directory itself its
/// relative paths are dropped.
pub fn bash_image_paths(cmd: &str, cwd: Option<&str>, home: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let dir = cwd.and_then(|c| resolve_path(c, None, home));
    scan_paths(cmd, dir, home, 0, Code::default(), &mut out);
    out
}

/// How deep quoted code inside quoted code is read.
const MAX_QUOTE_DEPTH: usize = 3;

/// Options that run the command in another directory (`npm --prefix dir`, `env --chdir=dir`).
const DIR_OPTS: &[&str] = &["--directory", "--chdir", "--cwd", "--prefix"];
/// Commands whose `-C dir` means "run in dir".
const DASH_C_DIR: &[&str] = &[
    "make", "gmake", "git", "tar", "bsdtar", "env", "ninja", "pnpm", "cargo", "just",
];
/// Commands whose file arguments are on another machine or in a container.
const REMOTE: &[&str] = &["ssh", "docker", "podman", "nerdctl", "kubectl"];
/// `find` options whose argument is a pattern, not a file.
const FIND_PATTERN: &[&str] = &[
    "-name",
    "-iname",
    "-path",
    "-ipath",
    "-wholename",
    "-iwholename",
    "-regex",
    "-iregex",
    "-lname",
    "-ilname",
];
/// Commands that run text or a script that may `cd`: the directory after them is unknown.
const RUNS_SCRIPT: &[&str] = &["eval", "source", "."];

/// What a simple command (the words up to the next operator) says about its file arguments.
#[derive(Default, Clone, Copy)]
struct Cmd {
    /// They are on another machine or in a container: name nothing.
    remote: bool,
    /// It runs in another directory: relative names cannot be placed.
    other_dir: bool,
    find: bool,
    runs_script: bool,
}

fn command_context(words: &[&Word]) -> Cmd {
    let bare = |w: &&&Word| w.quoted.is_empty();
    let name = words
        .iter()
        .filter(bare)
        .map(|w| w.text.as_str())
        .find(|t| !t.contains('=') && !matches!(*t, "sudo" | "command" | "exec" | "nohup" | "time"))
        .unwrap_or("");
    let name = name.rsplit('/').next().unwrap_or(name);
    let opt = |t: &str| {
        DIR_OPTS
            .iter()
            .any(|o| t == *o || t.strip_prefix(o).is_some_and(|r| r.starts_with('=')))
            || (DASH_C_DIR.contains(&name) && t.starts_with("-C"))
    };
    Cmd {
        remote: REMOTE.contains(&name),
        other_dir: words.iter().filter(bare).any(|w| opt(&w.text)),
        find: name == "find",
        runs_script: RUNS_SCRIPT.contains(&name),
    }
}

/// What a block of quoted code does that changes how its string literals read.
#[derive(Default, Clone, Copy)]
struct Code {
    /// It joins paths (`os.path.join`, `path.join`, `joinpath`): a relative literal in it may be
    /// one piece of a longer path, so none is placed.
    joins: bool,
    /// It expands `~` itself (`os.path.expanduser`).
    expands_tilde: bool,
}

fn code_context(q: &str, outer: Code) -> Code {
    let mut joins = outer.joins;
    let mut rest = q;
    while let Some(p) = rest.find("join") {
        rest = &rest[p + 4..];
        let r = rest.strip_prefix("path").unwrap_or(rest);
        if r.trim_start().starts_with('(') {
            joins = true;
        }
    }
    Code {
        joins,
        expands_tilde: outer.expands_tilde || q.contains("expanduser"),
    }
}

/// True when a string literal in code is part of an expression that builds a longer string:
/// next to `+ % / *` or another literal (`'/data/' 'f.png'`). (A method call glued to a literal,
/// `'a.png'.replace(…)`, is one mixed word and is dropped as an expression already.)
fn literal_in_expression(text: &[char], w: &Word) -> bool {
    let before = text[..w.start.min(text.len())]
        .iter()
        .rev()
        .find(|c| !c.is_whitespace());
    let after = text[w.end.min(text.len())..]
        .iter()
        .find(|c| !c.is_whitespace());
    let op = |c: Option<&char>| c.is_some_and(|c| "+%/*'\"".contains(*c));
    op(before) || op(after)
}

fn scan_paths(
    text: &str,
    mut dir: Option<String>,
    home: Option<&str>,
    level: usize,
    code_ctx: Code,
    out: &mut Vec<String>,
) {
    let toks = shell_tokens(text, level > 0);
    let chars: Vec<char> = text.chars().collect();
    let mut depth = 0usize;
    let mut prev_op: &str = "\n";
    let mut at_start = true;
    let mut cmd = Cmd::default();
    let mut prev_word: Option<&Word> = None;
    let push = |out: &mut Vec<String>, p: &str, dir: Option<&str>| {
        let abs = if p.starts_with('/') || p.starts_with('~') || is_windows_abs(p) {
            resolve_path(p, None, home)
        } else {
            dir.and_then(|d| resolve_path(p, Some(d), home))
        };
        if let Some(a) = abs
            && !out.contains(&a)
        {
            out.push(a);
        }
    };
    let mut i = 0;
    while i < toks.len() {
        if at_start && let Tok::Word(_) = &toks[i] {
            let words: Vec<&Word> = toks[i..]
                .iter()
                .map_while(|t| match t {
                    Tok::Word(a) => Some(a),
                    Tok::Op(_) => None,
                })
                .collect();
            cmd = command_context(&words);
            if cmd.runs_script {
                dir = None;
            }
            prev_word = None;
        }
        match &toks[i] {
            Tok::Op(op) => {
                match *op {
                    "(" => depth += 1,
                    ")" => depth = depth.saturating_sub(1),
                    _ => {}
                }
                prev_op = op;
                at_start = true;
                i += 1;
            }
            Tok::Word(w) if at_start && matches!(w.text.as_str(), "cd" | "pushd" | "popd") => {
                at_start = false;
                let args: Vec<&Word> = toks[i + 1..]
                    .iter()
                    .map_while(|t| match t {
                        Tok::Word(a) => Some(a),
                        Tok::Op(_) => None,
                    })
                    .collect();
                let next_op = match toks.get(i + 1 + args.len()) {
                    Some(Tok::Op(o)) => *o,
                    _ => "\n",
                };
                // `cd x || true`: the cd may fail and the script goes on in the old directory.
                let may_fail = next_op == "||"
                    && !matches!(
                        toks.get(i + 2 + args.len()),
                        Some(Tok::Word(n)) if matches!(n.text.as_str(), "exit" | "return")
                    );
                // Redirections (`2>/dev/null`) are not arguments.
                let target: Vec<&Word> = args
                    .iter()
                    .copied()
                    .filter(|a| !a.redir)
                    .filter(|a| !(a.text.starts_with('-') && a.text.len() > 1))
                    .collect();
                let sure = w.text == "cd"
                    && depth == 0
                    && !may_fail
                    && !matches!(prev_op, "|" | "||" | "&")
                    && !matches!(next_op, "|" | "&");
                dir = match (sure, target.as_slice()) {
                    (false, _) => None,
                    (true, []) => home.map(str::to_owned),
                    // `cd "~/sub"`: a quoted `~` names `./~/sub`; not followed (dropped).
                    (true, [w]) if w.text.starts_with('~') && !tilde_expands(w, 0) => None,
                    (true, [w])
                        if w.text != "-" && !w.text.contains(['$', '`', '*', '?', '[', '{']) =>
                    {
                        let t = w.text.as_str();
                        if t.starts_with('/') || t.starts_with('~') {
                            resolve_path(t, None, home)
                        } else {
                            dir.as_deref().and_then(|d| resolve_path(t, Some(d), home))
                        }
                    }
                    _ => None,
                };
                i += 1 + args.len();
            }
            // `then cd x`, `sudo cd x`, `` `cd x` ``: a directory change not followed here.
            Tok::Word(w)
                if w.quoted.is_empty()
                    && matches!(w.text.trim_matches('`'), "cd" | "pushd" | "popd") =>
            {
                at_start = false;
                dir = None;
                prev_word = Some(w);
                i += 1;
            }
            Tok::Word(w) => {
                at_start = false;
                let after = prev_word.map(|p| p.text.as_str());
                prev_word = Some(w);
                i += 1;
                // A redirection (`> out.png`) is opened by this shell, here, whatever the command.
                let here = w.redir;
                if (cmd.remote && !here)
                    || (cmd.find && after.is_some_and(|a| FIND_PATTERN.contains(&a)))
                {
                    continue;
                }
                // One quoted string and nothing else (`'a b.png'`, `"…script…"`).
                let one_literal = !w.bare && w.quoted.len() == 1;
                // `bash -c 'ls a.png'`, `node -e "…"`: the argument of -c / -e is always code.
                let script_arg = after.is_some_and(|a| {
                    a.len() <= 4
                        && a.strip_prefix('-').is_some_and(|f| {
                            f.chars().all(|c| c.is_ascii_lowercase())
                                && (f.ends_with('c') || f.ends_with('e'))
                        })
                });
                let code = one_literal && (script_arg || looks_like_code(&w.quoted[0]));
                // `--out=shot.png`, `x=a.png`: the value after the last `=` is the file. In
                // code, `=` already ends a word, and a word mixing quoted and bare parts
                // (`D+'/a.png'`) is an expression, not a path.
                let value = match level {
                    0 => w.text.rsplit_once('=').map_or(w.text.as_str(), |(_, v)| v),
                    _ if one_literal && !literal_in_expression(&chars, w) => w.text.as_str(),
                    _ if one_literal => "",
                    _ if w.quoted.is_empty() && !w.fragment && !w.text.contains('+') => {
                        w.text.as_str()
                    }
                    _ => "",
                };
                let relative =
                    !(value.starts_with('/') || value.starts_with('~') || is_windows_abs(value));
                // `"~/a.png"`, `~"/a.png"`, `--out=~/a.png`: bash leaves the `~` as it is (the
                // file would be `./~/a.png`), so it names nothing here.
                let skip = w.text.chars().count() - value.chars().count();
                let literal_tilde = value.starts_with('~')
                    && !tilde_expands(w, skip)
                    && !(level > 0 && code_ctx.expands_tilde);
                // `HEAD:a.png`, `host:a.png`, `http://…`: not a local file name.
                let not_local = value.contains(':') && !is_windows_abs(value);
                let unplaceable =
                    relative && ((cmd.other_dir && !here) || (level > 0 && code_ctx.joins));
                if !code
                    && plain_image(value)
                    && !w.text.contains(['$', '`'])
                    && !literal_tilde
                    && !not_local
                    && !unplaceable
                {
                    push(out, value, dir.as_deref());
                } else if code && level < MAX_QUOTE_DEPTH {
                    let q = &w.quoted[0];
                    let inner = if changes_dir(q) || cmd.other_dir {
                        None
                    } else {
                        dir.clone()
                    };
                    scan_paths(q, inner, home, level + 1, code_context(q, code_ctx), out);
                }
            }
        }
    }
}

/// Image files a tool call names: `file_path` of Read / Write / Edit, image paths in a Bash
/// `command`. Absolute, de-duplicated, in order.
fn image_files(name: &str, input: &Value, cwd: Option<&str>, home: Option<&str>) -> Vec<ImageRef> {
    let field = |k: &str| input.get(k).and_then(Value::as_str);
    let raw: Vec<&str> = match name {
        "Read" | "Write" | "Edit" => field("file_path")
            .filter(|p| is_image_path(p))
            .into_iter()
            .collect(),
        "Bash" => {
            return field("command")
                .map(|c| bash_image_paths(c, cwd, home))
                .unwrap_or_default()
                .into_iter()
                .map(|path| ImageRef::File { path })
                .collect();
        }
        _ => Vec::new(),
    };
    let mut out: Vec<ImageRef> = Vec::new();
    for p in raw {
        if let Some(path) = resolve_path(p, cwd, home) {
            let r = ImageRef::File { path };
            if !out.contains(&r) {
                out.push(r);
            }
        }
    }
    out
}

fn rel(path: &str, cwd: Option<&str>) -> String {
    cwd.and_then(|c| path.strip_prefix(c.trim_end_matches('/')))
        .and_then(|r| r.strip_prefix('/'))
        .filter(|r| !r.is_empty())
        .unwrap_or(path)
        .to_owned()
}

/// One-line summary of a tool call.
pub fn tool_summary(name: &str, input: &Value, cwd: Option<&str>) -> String {
    let field = |k: &str| input.get(k).and_then(Value::as_str);
    let one = |prefix: &str, v: Option<&str>| -> Option<String> {
        let first = v?.lines().next().unwrap_or("").trim();
        let (t, _) = cut(first, MAX_SUMMARY);
        Some(format!("{prefix} {t}"))
    };
    let path = |verb: &str, k: &str| field(k).map(|p| format!("{verb} {}", rel(p, cwd)));
    let out = match name {
        "Read" => path("Read", "file_path"),
        "Edit" | "MultiEdit" => path("Edited", "file_path"),
        "Write" => path("Wrote", "file_path"),
        "NotebookEdit" => path("Edited", "notebook_path"),
        "Bash" => one("Ran", field("command")),
        "SendMessage" => field("to").map(|t| format!("Messaged {t}")),
        "Grep" => one("Searched", field("pattern")),
        "Glob" => one("Listed", field("pattern")),
        "WebFetch" => one("Fetched", field("url")),
        "WebSearch" => one("Searched the web:", field("query")),
        "Agent" | "Task" => one("Agent:", field("description")),
        "Skill" => one("Skill", field("skill")),
        _ => None,
    };
    out.unwrap_or_else(|| name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn summaries() {
        let cwd = Some("/w/repo");
        assert_eq!(
            tool_summary("Read", &json!({"file_path":"/w/repo/src/a.rs"}), cwd),
            "Read src/a.rs"
        );
        assert_eq!(
            tool_summary("Read", &json!({"file_path":"/w/repository/a"}), cwd),
            "Read /w/repository/a"
        );
        assert_eq!(
            tool_summary("Edit", &json!({"file_path":"/x/b.rs"}), cwd),
            "Edited /x/b.rs"
        );
        assert_eq!(
            tool_summary("Bash", &json!({"command":"git log\n--oneline"}), cwd),
            "Ran git log"
        );
        assert_eq!(
            tool_summary("SendMessage", &json!({"to":"Sib1"}), cwd),
            "Messaged Sib1"
        );
        assert_eq!(tool_summary("mcp__x__y", &json!({}), cwd), "mcp__x__y");
        assert_eq!(tool_summary("Read", &json!({"file_path": 3}), cwd), "Read");
        let long = "x".repeat(200);
        let s = tool_summary("Bash", &json!({ "command": long }), cwd);
        assert_eq!(s.chars().count(), "Ran ".len() + MAX_SUMMARY + 1);
    }

    #[test]
    fn cut_is_char_safe() {
        assert_eq!(cut("ééé", 2), ("éé…".to_owned(), true));
        assert_eq!(cut("ab", 2), ("ab".to_owned(), false));
    }

    #[test]
    fn tag_helpers() {
        let t = "Another:\n<cross-session-message from=\"uds:/s\" from-name=\"Lead\" from-mode=\"p\">\nhi\n</cross-session-message>";
        assert_eq!(
            tag_attr(t, "cross-session-message", "from-name").as_deref(),
            Some("Lead")
        );
        assert_eq!(
            tag_attr(t, "cross-session-message", "from").as_deref(),
            Some("uds:/s")
        );
        assert_eq!(tag_inner(t, "cross-session-message"), Some("hi"));
        assert_eq!(tag_inner("<summaryx>a</summaryx>", "summary"), None);
    }

    #[test]
    fn result_before_its_call_is_held_then_attached() {
        // Not seen in today's logs; guards a tailer that reads two files' worth of lines out of order.
        let s = Session::from_lines(
            "-s",
            "id",
            [
                r#"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"early"}]}}"#,
                r#"{"type":"assistant","uuid":"u2","message":{"id":"m","content":[{"type":"tool_use","id":"t9","name":"Read","input":{"file_path":"/a"}}]}}"#,
                r#"{"type":"assistant","uuid":"u3","message":{"id":"m","content":[{"type":"tool_use","id":"t10","name":"Read","input":{}}]}}"#,
            ],
        );
        let calls: Vec<_> = s
            .items
            .iter()
            .filter_map(|i| match &i.kind {
                ItemKind::ToolCall(c) => Some(c),
                _ => None,
            })
            .collect();
        assert_eq!(calls.len(), 2);
        assert_eq!(
            calls[0].result.as_ref().map(|r| r.text.as_str()),
            Some("early")
        );
        assert_eq!(calls[1].result, None);
        assert!(s.orphan_results.is_empty());
    }

    #[test]
    fn long_tool_input_is_cut_and_flagged() {
        let big = "y".repeat(MAX_TOOL_TEXT * 2);
        let line = format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","id":"t","name":"Write","input":{{"content":"{big}"}}}}]}}}}"#
        );
        let s = Session::from_lines("-s", "id", [line.as_str()]);
        let ItemKind::ToolCall(c) = &s.items[0].kind else {
            panic!()
        };
        assert!(c.input_truncated);
        assert_eq!(c.input.chars().count(), MAX_TOOL_TEXT + 1);
    }
}
