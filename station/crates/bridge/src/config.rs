//! Bridge configuration: which projects to watch and a few knobs.
//!
//! **Path** (first that is set): `--config <path>`, `$OBSERVATORY_BRIDGE_CONFIG`,
//! `$XDG_CONFIG_HOME/observatory/bridge.json`, `~/.config/observatory/bridge.json`.
//!
//! **Format** (JSON; every field optional, a leading `~/` or a bare `~` in a path means `$HOME`). A worked
//! example is in the bridge README.
//!
//! ```json
//! {
//!   "projects": [
//!     {"name": "my-app", "root": "~/my-app",
//!      "worktree_roots": ["~/my-app-worktrees"],
//!      "gallery": ["~/my-app/screenshots/*"]}
//!   ],
//!   "seats": ["Orca"],
//!   "cutoff_days": 7,
//!   "liveness_secs": 5,
//!   "coalesce_ms": 250
//! }
//! ```
//!
//! - `projects`: see `observatory_core::project` for how a log dir is matched to one. Omitted =
//!   only the home folder, "~ (home)" ([`home_project`]).
//! - `gallery` (per project): image folders for its "Visuals" view, scanned recursively; a `*`
//!   or `?` in a path segment matches any directory name there. Omitted or `[]` = no gallery.
//! - `exact` (per project, default false): claim only the slug of `root` itself, no subdirectories
//!   or worktree roots (used for the home folder).
//! - `seats`: agent names shown as seats (the app's `--seats` / `OBSERVATORY_SEATS` override it;
//!   with neither, the app uses the kit's default seat name).
//! - `cutoff_days`: at startup only session files modified in the last N days are read (0 = all).
//!   An older file that is written to later is picked up then.
//! - `liveness_secs`: how often the process list is re-checked.
//! - `coalesce_ms`: updates to one session within this window go out as one frame.
//!
//! A missing file means the defaults plus a one-line note (sent to the app in `hello`) saying
//! where the file goes. An unreadable or malformed one is reported on stderr and in that note,
//! and the defaults are used: the bridge never fails to start over its config.

use std::path::{Path, PathBuf};

use observatory_core::ProjectSpec;
use serde::Deserialize;

use crate::fsro;

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub projects: Vec<ProjectSpec>,
    pub cutoff_days: u64,
    pub liveness_secs: u64,
    pub coalesce_ms: u64,
    /// Agent names shown as seats; empty = the app decides.
    pub seats: Vec<String>,
    /// One line for the app when the config file is missing or bad (where it goes, what failed).
    pub note: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileConfig {
    projects: Option<Vec<FileProject>>,
    cutoff_days: Option<u64>,
    liveness_secs: Option<u64>,
    coalesce_ms: Option<u64>,
    seats: Option<Vec<String>>,
}

/// A project as written in the file.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileProject {
    name: String,
    root: String,
    #[serde(default)]
    worktree_roots: Vec<String>,
    #[serde(default)]
    gallery: Vec<String>,
    #[serde(default)]
    exact: bool,
}

/// Name of the project for sessions launched in the home folder itself.
pub const HOME_PROJECT: &str = "~ (home)";

/// The one built-in project: sessions started in the home folder itself (only `~`'s own slug,
/// no gallery). Everything else comes from the config file.
pub fn home_project(home: &str) -> ProjectSpec {
    ProjectSpec {
        name: HOME_PROJECT.into(),
        root: home.into(),
        worktree_roots: Vec::new(),
        gallery: Vec::new(),
        exact: true,
    }
}

impl Config {
    pub fn defaults(home: &str) -> Self {
        Config {
            projects: vec![home_project(home)],
            cutoff_days: 7,
            liveness_secs: 5,
            coalesce_ms: 250,
            seats: Vec::new(),
            note: None,
        }
    }

    /// Parse config text. Errors are for the caller to report; see [`load`].
    pub fn parse(text: &str, home: &str) -> Result<Self, String> {
        let f: FileConfig = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let d = Self::defaults(home);
        let expand = |s: String| match s.strip_prefix("~/") {
            Some(rest) => format!("{home}/{rest}"),
            None if s == "~" => home.to_owned(),
            None => s,
        };
        let projects = f.projects.map(|ps| {
            ps.into_iter()
                .map(|p| ProjectSpec {
                    gallery: p.gallery.into_iter().map(expand).collect(),
                    name: p.name,
                    root: expand(p.root),
                    worktree_roots: p.worktree_roots.into_iter().map(expand).collect(),
                    exact: p.exact,
                })
                .collect()
        });
        Ok(Config {
            projects: projects.unwrap_or(d.projects),
            cutoff_days: f.cutoff_days.unwrap_or(d.cutoff_days),
            liveness_secs: f.liveness_secs.unwrap_or(d.liveness_secs).max(1),
            coalesce_ms: f.coalesce_ms.unwrap_or(d.coalesce_ms),
            seats: f
                .seats
                .unwrap_or_default()
                .into_iter()
                .map(|n| n.trim().to_owned())
                .filter(|n| !n.is_empty())
                .collect(),
            note: None,
        })
    }
}

/// Where the config is looked for when `--config` is not given.
pub fn default_path(env: impl Fn(&str) -> Option<String>) -> Option<PathBuf> {
    if let Some(p) = env("OBSERVATORY_BRIDGE_CONFIG").filter(|s| !s.is_empty()) {
        return Some(p.into());
    }
    if let Some(x) = env("XDG_CONFIG_HOME").filter(|s| !s.is_empty()) {
        return Some(Path::new(&x).join("observatory/bridge.json"));
    }
    env("HOME").map(|h| Path::new(&h).join(".config/observatory/bridge.json"))
}

/// Load the config at `path`, never failing: missing → defaults + a note saying where the file
/// goes; bad → defaults + a warning (stderr) and the same in the note.
/// Returns the config and an optional warning for stderr.
pub fn load(path: Option<&Path>, home: &str) -> (Config, Option<String>) {
    let with_note = |note: String| Config {
        note: Some(note),
        ..Config::defaults(home)
    };
    let Some(path) = path else {
        return (
            with_note("No projects configured, and no config path (HOME is not set).".into()),
            None,
        );
    };
    match fsro::read_text(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (
            with_note(format!(
                "No projects configured: write {} (see the bridge README).",
                path.display()
            )),
            None,
        ),
        Err(e) => {
            let w = format!("cannot read config {}: {e}; using defaults", path.display());
            (with_note(w.clone()), Some(w))
        }
        Ok(text) => match Config::parse(&text, home) {
            Ok(c) => (c, None),
            Err(e) => {
                let w = format!("bad config {}: {e}; using defaults", path.display());
                (with_note(w.clone()), Some(w))
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_config_keeps_other_defaults_and_expands_tilde() {
        let c = Config::parse(
            r#"{"projects":[{"name":"x","root":"~/x","worktree_roots":["~/x-wt","/abs"]}],"cutoff_days":0}"#,
            "/h",
        )
        .unwrap();
        assert_eq!(c.projects.len(), 1);
        assert_eq!(c.projects[0].root, "/h/x");
        assert_eq!(c.projects[0].worktree_roots, vec!["/h/x-wt", "/abs"]);
        let home = Config::parse(
            r#"{"projects":[{"name":"~ (home)","root":"~","exact":true}]}"#,
            "/h",
        )
        .unwrap();
        assert_eq!(
            home.projects,
            vec![home_project("/h")],
            "bare ~ is the home folder"
        );
        assert_eq!(c.cutoff_days, 0);
        assert_eq!(c.liveness_secs, 5);
        assert_eq!(c.coalesce_ms, 250);
    }

    #[test]
    fn defaults_are_only_the_home_folder() {
        let d = Config::defaults("/h");
        assert_eq!(d.projects, vec![home_project("/h")]);
        let home = &d.projects[0];
        assert_eq!(
            (home.name.as_str(), home.root.as_str(), home.exact),
            (HOME_PROJECT, "/h", true)
        );
        assert!(home.gallery.is_empty() && home.worktree_roots.is_empty());
        assert!(d.seats.is_empty() && d.note.is_none());
    }

    #[test]
    fn gallery_explicit_list_absent_and_off() {
        let g = |c: &Config, n: &str| {
            c.projects
                .iter()
                .find(|p| p.name == n)
                .unwrap()
                .gallery
                .clone()
        };
        let c = Config::parse(
            r#"{"projects":[
                {"name":"a","root":"~/a"},
                {"name":"b","root":"~/b","gallery":[]},
                {"name":"x","root":"/x","gallery":["~/pics","/abs/*/out"]}]}"#,
            "/h",
        )
        .unwrap();
        assert!(g(&c, "a").is_empty(), "key absent: no gallery");
        assert!(g(&c, "b").is_empty(), "[]: no gallery");
        assert_eq!(
            g(&c, "x"),
            ["/h/pics", "/abs/*/out"],
            "~/ expanded, globs kept"
        );
        assert!(
            Config::parse(
                r#"{"projects":[{"name":"x","root":"/x","galery":[]}]}"#,
                "/h"
            )
            .is_err(),
            "a typo in a project is an error too"
        );
    }

    #[test]
    fn seats_are_read_trimmed_and_blank_free() {
        let c = Config::parse(r#"{"seats":[" Lead ","","Orca"]}"#, "/h").unwrap();
        assert_eq!(c.seats, ["Lead", "Orca"]);
        assert!(Config::parse("{}", "/h").unwrap().seats.is_empty());
    }

    #[test]
    fn typo_is_an_error_not_a_silent_default() {
        assert!(Config::parse(r#"{"cutof_days":3}"#, "/h").is_err());
        assert!(Config::parse("not json", "/h").is_err());
    }

    #[test]
    fn path_precedence() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| {
                pairs
                    .iter()
                    .find(|(a, _)| *a == k)
                    .map(|(_, v)| v.to_string())
            }
        };
        assert_eq!(
            default_path(env(&[
                ("OBSERVATORY_BRIDGE_CONFIG", "/c.json"),
                ("HOME", "/h")
            ])),
            Some("/c.json".into())
        );
        assert_eq!(
            default_path(env(&[("XDG_CONFIG_HOME", "/x"), ("HOME", "/h")])),
            Some("/x/observatory/bridge.json".into())
        );
        assert_eq!(
            default_path(env(&[("HOME", "/h")])),
            Some("/h/.config/observatory/bridge.json".into())
        );
    }

    #[test]
    fn missing_file_is_defaults_without_warning() {
        let (c, w) = load(
            Some(Path::new("/nonexistent/observatory/bridge.json")),
            "/h",
        );
        assert_eq!(c.projects, Config::defaults("/h").projects);
        assert!(w.is_none());
        assert!(
            c.note
                .as_deref()
                .is_some_and(|n| n.contains("/nonexistent/observatory/bridge.json")),
            "{:?}",
            c.note
        );
    }
}
