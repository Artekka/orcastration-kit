//! Is a Claude Code menu (a permission dialog or a question) open on an agent's screen?
//! Read from the pane right before the paste and right before the Enter.

/// Whether `screen` (the visible text of a pane) shows an open menu.
pub fn menu_open(_screen: &str) -> bool {
    // ORCA340-674 RED stub: never sees a menu (the fix replaces it).
    false
}
