//! Loading the bridge config from disk (the source scan keeps file writes out of `src/`).

use observatory_bridge::config;

#[test]
fn no_config_starts_with_home_only_and_a_note_saying_where() {
    let dir = std::env::temp_dir().join(format!("obs-cfg-missing-{}", std::process::id()));
    let path = dir.join("bridge.json");
    let (c, warning) = config::load(Some(&path), "/h");
    assert!(warning.is_none(), "a missing file is normal, not a warning");
    assert_eq!(c.projects, vec![config::home_project("/h")]);
    let note = c.note.expect("the app is told where the config goes");
    assert!(note.contains(&path.display().to_string()), "{note}");
    let (c, _) = config::load(None, "/h");
    assert!(c.note.is_some());
}

#[test]
fn a_bad_config_starts_with_defaults_a_warning_and_a_note() {
    let dir = std::env::temp_dir().join(format!("obs-cfg-bad-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("bridge.json");
    std::fs::write(&path, "{not json").unwrap();
    let (c, warning) = config::load(Some(&path), "/h");
    let _ = std::fs::remove_dir_all(&dir);
    let w = warning.expect("stderr warning");
    assert!(w.contains("bad config"), "{w}");
    assert_eq!(c.note.as_deref(), Some(w.as_str()));
    assert_eq!(c.projects, vec![config::home_project("/h")]);
}
