//! Sessions → threads. One thread per (project, agent name): every session of that agent in that
//! project (main checkout and worktree slugs alike, see [`crate::project`]) in time order, with a
//! [`ThreadEntry::Restart`] divider before each session after the first.
//!
//! A session without an `agent-name` record is its own thread, keyed by its session id. Sessions
//! whose slug no [`ProjectSpec`] matches are left out.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::project::{ProjectSpec, project_for_slug};
use crate::session::{ChatItem, Session, Status};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ThreadKey {
    pub project: String,
    /// Agent name, or `session:<id>` for a session that never named itself.
    pub agent: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "entry", rename_all = "snake_case")]
pub enum ThreadEntry {
    /// Divider: "<agent> restarted · <time>".
    Restart {
        session_id: String,
        at_ms: Option<i64>,
    },
    Item(ChatItem),
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Thread {
    /// Oldest session first.
    pub sessions: Vec<Session>,
}

impl Thread {
    pub fn latest(&self) -> Option<&Session> {
        self.sessions.last()
    }

    /// Status of the newest session (an older one cannot be working once a newer one exists).
    pub fn status(&self) -> Status {
        self.latest().map(|s| s.status.clone()).unwrap_or_default()
    }

    pub fn last_activity_ms(&self) -> Option<i64> {
        self.sessions
            .iter()
            .filter_map(|s| s.meta.last_activity_ms)
            .max()
    }

    /// All items of all sessions in order, with a restart divider between sessions.
    pub fn entries(&self) -> Vec<ThreadEntry> {
        let mut out = Vec::new();
        for (i, s) in self.sessions.iter().enumerate() {
            if i > 0 {
                out.push(ThreadEntry::Restart {
                    session_id: s.meta.session_id.clone(),
                    at_ms: s.meta.first_activity_ms,
                });
            }
            out.extend(s.items.iter().cloned().map(ThreadEntry::Item));
        }
        out
    }
}

fn key_for(s: &Session, project: &str) -> ThreadKey {
    ThreadKey {
        project: project.to_owned(),
        agent: s
            .meta
            .agent_name
            .clone()
            .unwrap_or_else(|| format!("session:{}", s.meta.session_id)),
    }
}

/// Group sessions into threads. Sessions are ordered by first activity (a session with no
/// timestamps sorts first; ties break on session id, so the result is deterministic).
pub fn build_threads(
    sessions: impl IntoIterator<Item = Session>,
    projects: &[ProjectSpec],
) -> BTreeMap<ThreadKey, Thread> {
    let mut map: BTreeMap<ThreadKey, Thread> = BTreeMap::new();
    for s in sessions {
        let Some(p) = project_for_slug(&s.meta.slug, projects) else {
            continue;
        };
        map.entry(key_for(&s, &p.name))
            .or_default()
            .sessions
            .push(s);
    }
    for t in map.values_mut() {
        t.sessions.sort_by(|a, b| {
            (a.meta.first_activity_ms, &a.meta.session_id)
                .cmp(&(b.meta.first_activity_ms, &b.meta.session_id))
        });
    }
    map
}
