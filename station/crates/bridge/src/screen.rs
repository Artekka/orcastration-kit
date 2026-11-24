//! Is a Claude Code menu (a permission dialog or a question) open on an agent's screen?
//! A send reads the pane right before the paste and right before the Enter, because Claude
//! Code writes `waiting` to its registry only after the dialog is drawn, and an Enter into a
//! permission menu picks its highlighted option ("Yes").
//!
//! **Rule** ([`menu_open`]): in the bottom [`BOTTOM_ROWS`] rows of the pane (trailing empty
//! rows dropped), a menu is open when a row starts, after spaces, with the cursor `❯` and a
//! numbered option (`❯ 2. Table`), and no input-box rule (a row of `─` only) comes after
//! that row. Claude Code draws its input box between two such rules, so text typed there,
//! even a quoted menu, is never a menu.
//!
//! This follows how Claude Code draws its screen today (the cursor glyph, numbered options,
//! the ruled input box). If that drawing changes, the check can miss a menu; the registry
//! status check still runs (README, Known limits).

/// Whether the idle input box is seen at the bottom of `screen`: the only screen a send may
/// type into.
pub fn input_box_ready(screen: &str) -> bool {
    // RED stub: the old deny rule (the fix replaces it).
    !menu_open(screen)
}

/// Rows at the bottom of the pane that are searched. Menus sit at the bottom of the screen.
pub const BOTTOM_ROWS: usize = 15;

/// The cursor Claude Code puts on the selected option of a menu.
const CURSOR: char = '❯';

/// Whether `screen` (the visible text of a pane) shows an open menu.
pub fn menu_open(screen: &str) -> bool {
    let rows: Vec<&str> = screen.lines().map(str::trim_end).collect();
    let last = rows.iter().rposition(|r| !r.is_empty());
    let end = last.map_or(0, |i| i + 1);
    let bottom = &rows[end.saturating_sub(BOTTOM_ROWS)..end];
    let Some(option) = bottom.iter().rposition(|r| is_cursor_option(r)) else {
        return false;
    };
    !bottom[option + 1..].iter().any(|r| is_rule(r))
}

/// `❯ 1. Yes`: the cursor, then a number and a dot.
fn is_cursor_option(row: &str) -> bool {
    let Some(rest) = row.trim_start().strip_prefix(CURSOR) else {
        return false;
    };
    let rest = rest.trim_start();
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    digits > 0 && rest[digits..].starts_with(". ")
}

/// A row of box-drawing `─` only (the input box's top and bottom edges).
fn is_rule(row: &str) -> bool {
    let r = row.trim();
    r.chars().count() >= 10 && r.chars().all(|c| c == '─')
}
