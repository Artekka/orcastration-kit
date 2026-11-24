//! One JSONL line → one typed [`Record`]. The only module that knows the log's field names.
//!
//! The format is undocumented, so every field is read defensively from a `serde_json::Value`:
//! a missing or oddly-typed field becomes `None`/empty, an unknown record `type` becomes
//! [`RecordKind::Other`], an unknown content block becomes [`Block::Unknown`], and a line that is
//! not a JSON object is [`Parsed::Malformed`]. Nothing here panics on input.
//!
//! Record types that matter for chat (measured 2026-11-23, see `tests/fixtures/README.md`):
//! `user`, `assistant`, `system`, and the identity records `agent-name`, `permission-mode`,
//! `mode`, `custom-title` (re-emitted every turn; the latest wins). Everything else
//! (`api-request*`, `attachment`, `data-flow-records`, `queue-operation`, …) is `Other`.
//! `api-request-blob` carries message blocks too, but it is a replay of the API request, not chat.

use serde_json::Value;

/// Outcome of parsing one line.
#[derive(Debug, Clone, PartialEq)]
pub enum Parsed {
    Record(Record),
    /// Empty or whitespace-only line.
    Blank,
    /// Not a JSON object. Carries a short reason.
    Malformed(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    /// The raw `type` field (`"<none>"` when absent).
    pub raw_type: String,
    pub session_id: Option<String>,
    pub uuid: Option<String>,
    pub timestamp: Option<String>,
    pub cwd: Option<String>,
    pub kind: RecordKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RecordKind {
    AgentName(String),
    PermissionMode(String),
    Mode(String),
    CustomTitle(String),
    User(UserRecord),
    Assistant(AssistantRecord),
    System(SystemRecord),
    /// Known-but-irrelevant or unknown record type.
    Other,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UserRecord {
    /// `message.content` as blocks (a plain string becomes one `Text` block).
    pub blocks: Vec<Block>,
    pub content_was_string: bool,
    pub is_meta: bool,
    pub is_compact_summary: bool,
    /// `origin.kind`: `human`, `peer`, `task-notification`, … (absent in older lines).
    pub origin_kind: Option<String>,
    /// `origin.name` / `origin.body`: set on peer (cross-session) messages.
    pub origin_name: Option<String>,
    pub origin_body: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AssistantRecord {
    pub message_id: Option<String>,
    pub model: Option<String>,
    pub blocks: Vec<Block>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SystemRecord {
    pub subtype: Option<String>,
    pub content: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Block {
    Text(String),
    Thinking(String),
    ToolUse {
        id: String,
        name: String,
        input: Value,
    },
    ToolResult {
        tool_use_id: String,
        /// Text of the result; non-text parts become `[image]`, `[<type>]`.
        content: String,
        is_error: bool,
        /// Readable image parts of the result (base64 source with data): (index in the result's
        /// content array, media type).
        images: Vec<(usize, Option<String>)>,
    },
    /// An image block (pasted screenshot). Only the media type is kept, never the bytes.
    Image {
        media_type: Option<String>,
        /// True when the block carries base64 data the app can read back from the log.
        embedded: bool,
    },
    Unknown(String),
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_owned)
}

fn flag(v: &Value, k: &str) -> bool {
    v.get(k).and_then(Value::as_bool).unwrap_or(false)
}

/// Parse one line (without its newline).
pub fn parse_line(line: &str) -> Parsed {
    if line.trim().is_empty() {
        return Parsed::Blank;
    }
    let v: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => return Parsed::Malformed(format!("json: {e}")),
    };
    if !v.is_object() {
        return Parsed::Malformed("not a JSON object".into());
    }
    let raw_type = s(&v, "type").unwrap_or_else(|| "<none>".into());
    let kind = match raw_type.as_str() {
        "agent-name" => s(&v, "agentName").map_or(RecordKind::Other, RecordKind::AgentName),
        "permission-mode" => {
            s(&v, "permissionMode").map_or(RecordKind::Other, RecordKind::PermissionMode)
        }
        "mode" => s(&v, "mode").map_or(RecordKind::Other, RecordKind::Mode),
        "custom-title" => s(&v, "customTitle").map_or(RecordKind::Other, RecordKind::CustomTitle),
        "user" => RecordKind::User(user(&v)),
        "assistant" => RecordKind::Assistant(assistant(&v)),
        "system" => RecordKind::System(SystemRecord {
            subtype: s(&v, "subtype"),
            content: s(&v, "content"),
            duration_ms: v.get("durationMs").and_then(Value::as_u64),
        }),
        _ => RecordKind::Other,
    };
    Parsed::Record(Record {
        raw_type,
        session_id: s(&v, "sessionId"),
        uuid: s(&v, "uuid"),
        timestamp: s(&v, "timestamp"),
        cwd: s(&v, "cwd"),
        kind,
    })
}

fn content_blocks(msg: Option<&Value>) -> (Vec<Block>, bool) {
    match msg.and_then(|m| m.get("content")) {
        Some(Value::String(t)) => (vec![Block::Text(t.clone())], true),
        Some(Value::Array(a)) => (a.iter().map(block).collect(), false),
        _ => (Vec::new(), false),
    }
}

fn user(v: &Value) -> UserRecord {
    let (blocks, content_was_string) = content_blocks(v.get("message"));
    let origin = v.get("origin");
    UserRecord {
        blocks,
        content_was_string,
        is_meta: flag(v, "isMeta"),
        is_compact_summary: flag(v, "isCompactSummary"),
        origin_kind: origin.and_then(|o| s(o, "kind")),
        origin_name: origin.and_then(|o| s(o, "name")),
        origin_body: origin.and_then(|o| s(o, "body")),
    }
}

fn assistant(v: &Value) -> AssistantRecord {
    let msg = v.get("message");
    let (blocks, _) = content_blocks(msg);
    AssistantRecord {
        message_id: msg.and_then(|m| s(m, "id")),
        model: msg.and_then(|m| s(m, "model")),
        blocks,
    }
}

fn block(b: &Value) -> Block {
    match b.get("type").and_then(Value::as_str) {
        Some("text") => Block::Text(s(b, "text").unwrap_or_default()),
        Some("thinking") => Block::Thinking(s(b, "thinking").unwrap_or_default()),
        Some("tool_use") => Block::ToolUse {
            id: s(b, "id").unwrap_or_default(),
            name: s(b, "name").unwrap_or_else(|| "tool".into()),
            input: b.get("input").cloned().unwrap_or(Value::Null),
        },
        Some("tool_result") => Block::ToolResult {
            tool_use_id: s(b, "tool_use_id").unwrap_or_default(),
            content: result_text(b.get("content")),
            is_error: flag(b, "is_error"),
            images: result_images(b.get("content")),
        },
        Some("image") => Block::Image {
            media_type: b.get("source").and_then(|src| s(src, "media_type")),
            embedded: is_base64_image(b),
        },
        Some(other) => Block::Unknown(other.to_owned()),
        None => Block::Unknown("<none>".into()),
    }
}

/// An image block whose `source` is `{"type":"base64","data":"…"}` (the only kind kept in logs).
fn is_base64_image(b: &Value) -> bool {
    b.get("source").is_some_and(|src| {
        s(src, "type").as_deref() == Some("base64") && src.get("data").is_some_and(Value::is_string)
    })
}

/// Positions and media types of the `image` parts of a tool result's content array.
fn result_images(c: Option<&Value>) -> Vec<(usize, Option<String>)> {
    match c {
        Some(Value::Array(parts)) => parts
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                p.get("type").and_then(Value::as_str) == Some("image") && is_base64_image(p)
            })
            .map(|(i, p)| (i, p.get("source").and_then(|src| s(src, "media_type"))))
            .collect(),
        _ => Vec::new(),
    }
}

fn result_text(c: Option<&Value>) -> String {
    match c {
        Some(Value::String(t)) => t.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .map(|p| match p.get("type").and_then(Value::as_str) {
                Some("text") => s(p, "text").unwrap_or_default(),
                Some(t) => format!("[{t}]"),
                None => "[?]".into(),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_and_blank_never_panic() {
        assert_eq!(parse_line("   "), Parsed::Blank);
        assert!(matches!(
            parse_line("{\"type\":\"user\",\"mess"),
            Parsed::Malformed(_)
        ));
        assert!(matches!(parse_line("[1,2]"), Parsed::Malformed(_)));
        assert!(matches!(parse_line("\"str\""), Parsed::Malformed(_)));
    }

    #[test]
    fn oddly_typed_fields_degrade_not_crash() {
        let Parsed::Record(r) =
            parse_line(r#"{"type":"user","message":{"content":42},"isMeta":"yes"}"#)
        else {
            panic!("expected record")
        };
        let RecordKind::User(u) = r.kind else {
            panic!()
        };
        assert!(u.blocks.is_empty());
        assert!(!u.is_meta);
        let Parsed::Record(r) = parse_line(r#"{"type":"agent-name","agentName":7}"#) else {
            panic!()
        };
        assert_eq!(r.kind, RecordKind::Other);
        let Parsed::Record(r) = parse_line(r#"{"no_type":true}"#) else {
            panic!()
        };
        assert_eq!(r.raw_type, "<none>");
    }

    #[test]
    fn unknown_block_type_is_kept_as_unknown() {
        let Parsed::Record(r) = parse_line(
            r#"{"type":"assistant","message":{"id":"m","content":[{"type":"hologram"},{"x":1}]}}"#,
        ) else {
            panic!()
        };
        let RecordKind::Assistant(a) = r.kind else {
            panic!()
        };
        assert_eq!(
            a.blocks,
            vec![
                Block::Unknown("hologram".into()),
                Block::Unknown("<none>".into())
            ]
        );
    }

    #[test]
    fn tool_result_list_content_is_flattened() {
        let Parsed::Record(r) = parse_line(
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,
               "content":[{"type":"text","text":"a"},{"type":"image"},{"type":"tool_reference"}]}]}}"#,
        ) else {
            panic!()
        };
        let RecordKind::User(u) = r.kind else {
            panic!()
        };
        assert_eq!(
            u.blocks,
            vec![Block::ToolResult {
                tool_use_id: "t1".into(),
                content: "a\n[image]\n[tool_reference]".into(),
                is_error: true,
                images: vec![],
            }]
        );
    }
}
