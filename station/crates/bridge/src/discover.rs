//! Which session files to read: `<claude>/projects/<slug>/<session-id>.jsonl`, top level of a slug
//! dir only (subagent logs in subdirectories are not sessions), for slugs a configured project
//! claims (`observatory_core::project_for_slug`).

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use observatory_core::{ProjectSpec, project_for_slug};

use crate::fsro;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub path: PathBuf,
    pub slug: String,
    pub project: String,
    pub session_id: String,
}

/// The project of a slug directory under `projects_dir`, if a spec claims it.
pub fn project_of_dir(dir: &Path, projects_dir: &Path, specs: &[ProjectSpec]) -> Option<String> {
    if dir.parent()? != projects_dir {
        return None;
    }
    let slug = dir.file_name()?.to_str()?;
    project_for_slug(slug, specs).map(|p| p.name.clone())
}

/// A path is a session file when it is `<projects_dir>/<claimed slug>/<id>.jsonl`.
pub fn session_file(path: &Path, projects_dir: &Path, specs: &[ProjectSpec]) -> Option<Found> {
    if path.extension()? != "jsonl" {
        return None;
    }
    let dir = path.parent()?;
    let project = project_of_dir(dir, projects_dir, specs)?;
    Some(Found {
        path: path.to_path_buf(),
        slug: dir.file_name()?.to_str()?.to_owned(),
        project,
        session_id: path.file_stem()?.to_str()?.to_owned(),
    })
}

/// Slug directories some project claims.
pub fn claimed_dirs(projects_dir: &Path, specs: &[ProjectSpec]) -> Vec<PathBuf> {
    fsro::list_dir(projects_dir)
        .into_iter()
        .filter(|d| fsro::is_dir(d) && project_of_dir(d, projects_dir, specs).is_some())
        .collect()
}

/// Session files in one slug dir, modified at or after `since` (None = all).
pub fn files_in(
    dir: &Path,
    projects_dir: &Path,
    specs: &[ProjectSpec],
    since: Option<SystemTime>,
) -> Vec<Found> {
    fsro::list_dir(dir)
        .into_iter()
        .filter(|p| !fsro::is_dir(p))
        .filter(|p| since.is_none_or(|t| fsro::modified(p).is_some_and(|m| m >= t)))
        .filter_map(|p| session_file(&p, projects_dir, specs))
        .collect()
}

/// Every session file of every claimed slug dir (see [`files_in`]).
pub fn discover(
    projects_dir: &Path,
    specs: &[ProjectSpec],
    since: Option<SystemTime>,
) -> Vec<Found> {
    claimed_dirs(projects_dir, specs)
        .iter()
        .flat_map(|d| files_in(d, projects_dir, specs, since))
        .collect()
}
