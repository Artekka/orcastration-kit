//! Pages: the claude.ai pages ("artifacts") an agent published, read from its `Artifact`
//! tool calls. Only small records travel (URL, title, time, version count, deleted); never the
//! page's content, and the published file is never opened.
//!
//! | call (`action`) | result | effect |
//! |---|---|---|
//! | `publish` (or no `action`) | names `https://claude.ai/artifact/<id>` or `…/code/artifact/<uuid>` | a page; the same URL again updates it (latest time, title, version) |
//! | `publish` | error, or no page URL | nothing |
//! | `delete` with `url` and no `path` | not an error | that page is marked deleted (if known) |
//! | `delete` with `path` (one asset), `quickstart`, `list`, `read`, `open`, `pin`, … | any | nothing |
//!
//! Title: the call's `title`, else the published file's base name without its extension
//! (`status-board.html` → `status-board`, seat ruling), else the page we already know, else "page".
//! Versions: the result's "Version N" when it says so, else one more than before.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One published page.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page {
    /// `https://claude.ai/artifact/<id>` (or `/code/artifact/<uuid>`), as the result named it.
    pub url: String,
    pub title: String,
    /// When it was last published (Unix ms), if the log said.
    pub time_ms: Option<i64>,
    /// How many versions are known (at least 1).
    pub versions: u32,
    /// Deleted by a later `delete` call (still listed, struck through).
    #[serde(default)]
    pub deleted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Action {
    Publish,
    Delete,
}

/// The parts of an `Artifact` call that matter for pages, kept until its result arrives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtifactCall {
    action: Action,
    title: Option<String>,
    /// From `file_path`: base name, extension dropped.
    file_title: Option<String>,
    /// `url` input: the page republished or deleted.
    url: Option<String>,
    /// `type_url` input: a type's link, never the new page.
    type_url: Option<String>,
}

/// True for the Artifact tool, under its own name or an MCP server's (`mcp__<server>__Artifact`).
pub fn is_artifact_tool(name: &str) -> bool {
    name == "Artifact" || (name.starts_with("mcp__") && name.ends_with("__Artifact"))
}

fn base_title(path: &str) -> Option<String> {
    let name = path.rsplit(['/', '\\']).next()?;
    let stem = match name.rfind('.') {
        Some(i) if i > 0 => &name[..i],
        _ => name,
    };
    (!stem.trim().is_empty()).then(|| stem.to_owned())
}

impl ArtifactCall {
    /// The call's page-relevant parts, or `None` for a call that can never change a page.
    pub fn from_tool(name: &str, input: &Value) -> Option<Self> {
        if !is_artifact_tool(name) {
            return None;
        }
        let s = |k: &str| {
            input
                .get(k)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
        };
        let action = match s("action").as_deref() {
            None | Some("publish") => Action::Publish,
            // `delete` with `path` removes one uploaded asset, not the page.
            Some("delete") if s("path").is_none() && s("url").is_some() => Action::Delete,
            Some(_) => return None,
        };
        Some(ArtifactCall {
            action,
            title: s("title"),
            file_title: s("file_path").and_then(|p| base_title(&p)),
            url: s("url").map(|u| canonical(&u)),
            type_url: s("type_url").map(|u| canonical(&u)),
        })
    }
}

const PREFIXES: [&str; 2] = [
    "https://claude.ai/code/artifact/",
    "https://claude.ai/artifact/",
];

/// Every page URL in `text`, in order: the prefix and an id of letters, digits, `-` and `_`.
pub fn page_urls(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while let Some(at) = text[i..].find("https://claude.ai/") {
        let start = i + at;
        i = start + 1;
        let Some(prefix) = PREFIXES.iter().find(|p| text[start..].starts_with(**p)) else {
            continue;
        };
        let id_start = start + prefix.len();
        let id_len = text[id_start..]
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
            .unwrap_or(text.len() - id_start);
        if id_len == 0 {
            continue;
        }
        let url = text[start..id_start + id_len].to_owned();
        if !out.contains(&url) {
            out.push(url);
        }
        i = id_start + id_len;
    }
    out
}

/// `u` as the page URL it names (query, fragment and trailing slash dropped); `u` itself when it
/// names none.
fn canonical(u: &str) -> String {
    page_urls(u)
        .into_iter()
        .next()
        .unwrap_or_else(|| u.to_owned())
}

/// The `N` of the first "Version N" in `text`.
fn version_in(text: &str) -> Option<u32> {
    let at = text.find("Version ")? + "Version ".len();
    let digits: String = text[at..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().ok().filter(|&n| n > 0)
}

/// Apply a finished `Artifact` call to `pages`. Returns true when `pages` changed.
pub fn apply(
    pages: &mut Vec<Page>,
    call: &ArtifactCall,
    result: &str,
    is_error: bool,
    time_ms: Option<i64>,
) -> bool {
    if is_error {
        return false;
    }
    match call.action {
        Action::Delete => {
            let Some(url) = &call.url else { return false };
            match pages.iter_mut().find(|p| &p.url == url) {
                Some(p) if !p.deleted => {
                    p.deleted = true;
                    true
                }
                _ => false,
            }
        }
        Action::Publish => {
            let urls: Vec<String> = page_urls(result)
                .into_iter()
                .filter(|u| Some(u) != call.type_url.as_ref())
                .collect();
            let url = match &call.url {
                Some(u) if urls.contains(u) => u.clone(),
                _ => match urls.into_iter().next() {
                    Some(u) => u,
                    None => return false,
                },
            };
            let named = call.title.clone().or_else(|| call.file_title.clone());
            let version = version_in(result);
            match pages.iter_mut().find(|p| p.url == url) {
                Some(p) => {
                    if let Some(t) = named {
                        p.title = t;
                    }
                    p.time_ms = time_ms.or(p.time_ms);
                    p.versions = version.unwrap_or(p.versions + 1).max(1);
                    p.deleted = false;
                }
                None => pages.push(Page {
                    url,
                    title: named.unwrap_or_else(|| "page".into()),
                    time_ms,
                    versions: version.unwrap_or(1),
                    deleted: false,
                }),
            }
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn urls_are_found_whole_and_once() {
        let t = "Published /x/a.html at https://claude.ai/artifact/H6zD-Z_9 (Version 1). \
                 Also https://claude.ai/code/artifact/0b1c-22, https://claude.ai/chat/xyz, \
                 https://claude.ai/artifact/ and https://claude.ai/artifact/H6zD-Z_9.";
        assert_eq!(
            page_urls(t),
            [
                "https://claude.ai/artifact/H6zD-Z_9",
                "https://claude.ai/code/artifact/0b1c-22"
            ]
        );
        assert_eq!(
            canonical("https://claude.ai/artifact/abc/?x=1#f"),
            "https://claude.ai/artifact/abc"
        );
    }

    #[test]
    fn republish_prefers_its_own_url_and_counts_when_no_version_is_said() {
        let a = "https://claude.ai/artifact/AAA";
        let call = |v: Value| ArtifactCall::from_tool("Artifact", &v).unwrap();
        let mut pages = Vec::new();
        assert!(apply(
            &mut pages,
            &call(json!({"file_path": "/p/one.html"})),
            &format!("Published /p/one.html at {a}."),
            false,
            Some(1),
        ));
        // A republish naming its page: the result mentions another link first, the page is
        // still the one the call named; no "Version N" in the text, so the count goes up.
        assert!(apply(
            &mut pages,
            &call(json!({"url": a, "title": "One, renamed"})),
            &format!("See https://claude.ai/artifact/OTHER for help. Published at {a}."),
            false,
            Some(2),
        ));
        assert_eq!(
            pages,
            [Page {
                url: a.into(),
                title: "One, renamed".into(),
                time_ms: Some(2),
                versions: 2,
                deleted: false,
            }]
        );
        // Deleting a page nobody published here changes nothing.
        assert!(!apply(
            &mut pages,
            &call(json!({"action": "delete", "url": "https://claude.ai/artifact/ZZZ"})),
            "Deleted.",
            false,
            Some(3),
        ));
    }

    #[test]
    fn versions_and_titles() {
        assert_eq!(version_in("x (Version 12, version id 1-2)"), Some(12));
        assert_eq!(version_in("no version here"), None);
        assert_eq!(version_in("Version 0"), None);
        assert_eq!(
            base_title("/t/status-board.html").as_deref(),
            Some("status-board")
        );
        assert_eq!(base_title(r"D:\x\notes.v2.md").as_deref(), Some("notes.v2"));
        assert_eq!(base_title("/t/.hidden").as_deref(), Some(".hidden"));
        assert_eq!(base_title("/t/README").as_deref(), Some("README"));
    }

    #[test]
    fn which_calls_count() {
        let c = |name: &str, v: Value| ArtifactCall::from_tool(name, &v).map(|c| c.action);
        assert_eq!(
            c("Artifact", json!({"file_path": "/a.html"})),
            Some(Action::Publish)
        );
        assert_eq!(
            c("Artifact", json!({"action": "publish"})),
            Some(Action::Publish)
        );
        assert_eq!(
            c("mcp__claude-artifacts__Artifact", json!({})),
            Some(Action::Publish)
        );
        assert_eq!(
            c(
                "Artifact",
                json!({"action": "delete", "url": "https://claude.ai/artifact/a"})
            ),
            Some(Action::Delete)
        );
        for other in ["quickstart", "list", "read", "open", "pin", "unpin"] {
            assert_eq!(c("Artifact", json!({"action": other})), None, "{other}");
        }
        assert_eq!(
            c(
                "Artifact",
                json!({"action": "delete", "url": "https://claude.ai/artifact/a", "path": "0f"})
            ),
            None,
            "deleting one asset is not deleting the page"
        );
        assert_eq!(c("ArtifactComments", json!({})), None);
        assert_eq!(c("Read", json!({"file_path": "/a.html"})), None);
    }
}
