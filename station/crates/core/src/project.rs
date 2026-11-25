//! Which project a session log belongs to.
//!
//! Claude Code stores a session under `~/.claude/projects/<slug>/`, where `<slug>` is the
//! directory the session was LAUNCHED in with every character that is not an ASCII letter, digit
//! or `-` replaced by `-` (`/home/u/.x/my_app` → `-home-u--x-my-app`). It is the launch dir, not
//! the current cwd: a kit sibling launched in the main checkout logs there even while it works in
//! a worktree.
//!
//! **Rule.** Projects are a configurable list of [`ProjectSpec`] (nothing is hard-coded here).
//! A slug belongs to a project when it equals the slug of the project's `root` or of one of its
//! `worktree_roots`, or starts with that slug followed by `-` (a session launched in a
//! subdirectory or in one worktree under a worktree root). The `-` boundary keeps root
//! `/home/u/obs` from claiming `/home/u/observatory`. When several specs match, the LONGEST
//! matching slug wins, so a project nested under another's directory still gets its own sessions.
//! A slug no spec matches belongs to no project. A spec marked [`ProjectSpec::exact`] claims only
//! its own `root` slug, never a subdirectory (the home folder: `~` must not swallow every
//! unconfigured `~/x`).
//!
//! **Limit.** A slug cannot tell `/home/u/observatory/old-copy` (a subdirectory, which must match)
//! from `/home/u/observatory-old-copy` (a sibling) or `/home/u/observatory_old_copy`: all three
//! become `-home-u-observatory-old-copy`. So an UNCONFIGURED sibling directory whose name extends
//! a root after a `-` (or any other character that slugifies to `-`) is claimed by that root.
//! Configure the sibling as its own project and the longest-match rule gives it its sessions.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectSpec {
    /// Display name, e.g. `replay-viewer`.
    pub name: String,
    /// Absolute path of the main checkout.
    pub root: String,
    /// Absolute directories that hold this project's worktrees, if sessions are launched there.
    #[serde(default)]
    pub worktree_roots: Vec<String>,
    /// Image folders shown as this project's gallery ("Visuals"): absolute directories, scanned
    /// recursively; a `*` or `?` in a path segment matches any directory name there.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub gallery: Vec<String>,
    /// Claim only the exact slug of `root` (no subdirectories, no worktree roots).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub exact: bool,
}

/// The log-directory slug Claude Code uses for a launch directory.
pub fn slugify(path: &str) -> String {
    path.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect()
}

fn slug_matches(slug: &str, base: &str, exact: bool) -> bool {
    slug == base
        || !exact
            && slug
                .strip_prefix(base)
                .is_some_and(|rest| rest.starts_with('-'))
}

/// The project a log-directory slug belongs to (longest matching root wins), if any.
pub fn project_for_slug<'a>(slug: &str, projects: &'a [ProjectSpec]) -> Option<&'a ProjectSpec> {
    projects
        .iter()
        .filter_map(|p| {
            std::iter::once(&p.root)
                .chain(&p.worktree_roots)
                .map(|r| slugify(r))
                .filter(|base| slug_matches(slug, base, p.exact))
                .map(|base| base.len())
                .max()
                .map(|len| (len, p))
        })
        .max_by_key(|(len, _)| *len)
        .map(|(_, p)| p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(name: &str, root: &str, wt: &[&str]) -> ProjectSpec {
        ProjectSpec {
            name: name.into(),
            root: root.into(),
            worktree_roots: wt.iter().map(|s| s.to_string()).collect(),
            gallery: vec![],
            exact: false,
        }
    }

    #[test]
    fn slugify_matches_claude_code_dirs() {
        // The directory-name shape Claude Code uses under ~/.claude/projects (`/` `.` `_` and space become `-`).
        assert_eq!(slugify("/home/u/replay-viewer"), "-home-u-replay-viewer");
        assert_eq!(
            slugify("/home/u/asset-pipeline-worktrees/.scratch"),
            "-home-u-asset-pipeline-worktrees--scratch"
        );
        assert_eq!(slugify("/tmp/a_b c"), "-tmp-a-b-c");
    }

    #[test]
    fn root_subdir_and_worktree_match() {
        let ps = [spec("app", "/home/u/app", &["/home/u/app-worktrees"])];
        for slug in [
            "-home-u-app",
            "-home-u-app-frontend",
            "-home-u-app-worktrees-s1-x",
        ] {
            assert_eq!(
                project_for_slug(slug, &ps).map(|p| p.name.as_str()),
                Some("app"),
                "{slug}"
            );
        }
        assert_eq!(project_for_slug("-home-u", &ps), None);
        assert_eq!(project_for_slug("-home-u-other", &ps), None);
    }

    #[test]
    fn near_miss_prefix_is_not_claimed() {
        let ps = [spec("obs", "/home/u/obs", &[])];
        assert_eq!(project_for_slug("-home-u-observatory", &ps), None);
        assert_eq!(
            project_for_slug("-home-u-obs", &ps).map(|p| p.name.as_str()),
            Some("obs")
        );
    }

    #[test]
    fn exact_spec_claims_only_its_own_slug() {
        // The home folder: `~` itself, but no unconfigured `~/x` and no configured project's dir.
        let mut home = spec("~ (home)", "/home/u", &[]);
        home.exact = true;
        let ps = [spec("obs", "/home/u/obs", &[]), home];
        let of = |slug| project_for_slug(slug, &ps).map(|p| p.name.as_str());
        assert_eq!(of("-home-u"), Some("~ (home)"));
        assert_eq!(of("-home-u-notes-app"), None);
        assert_eq!(of("-home-u-obs-x"), Some("obs"));
        // Non-vacuity: the same spec without `exact` does claim the subdirectory.
        let mut loose = ps.clone();
        loose[1].exact = false;
        assert_eq!(
            project_for_slug("-home-u-notes-app", &loose).map(|p| p.name.as_str()),
            Some("~ (home)")
        );
    }

    #[test]
    fn longest_match_wins_for_nested_projects() {
        // `obs` would also claim `-home-u-obs-tools` by the subdirectory rule; the nested project wins.
        let ps = [
            spec("obs", "/home/u/obs", &[]),
            spec("tools", "/home/u/obs-tools", &[]),
        ];
        assert_eq!(
            project_for_slug("-home-u-obs-tools-x", &ps).map(|p| p.name.as_str()),
            Some("tools")
        );
        let rev = [ps[1].clone(), ps[0].clone()];
        assert_eq!(
            project_for_slug("-home-u-obs-tools", &rev).map(|p| p.name.as_str()),
            Some("tools")
        );
        assert_eq!(
            project_for_slug("-home-u-obs-x", &ps).map(|p| p.name.as_str()),
            Some("obs")
        );
    }
}
