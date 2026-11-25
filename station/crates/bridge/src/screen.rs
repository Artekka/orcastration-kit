//! May a send type into this pane now? A send reads the pane right before the paste and
//! right before the Enter, because Claude Code writes `waiting` to its registry only after a
//! dialog is drawn, and an Enter into a menu picks its highlighted option.
//!
//! **ALLOW rule** ([`input_box_ready`]): a send may type only when Claude Code's idle input
//! box is seen at the bottom of the pane. Every other screen refuses: an empty capture, a
//! question or permission menu, any dialog, a shell, a shape not seen before. From the
//! bottom, trailing empty rows dropped:
//! 1. a footer of at most [`MAX_FOOTER_ROWS`] rows ([`MAX_FOOTER_TEXT_ROWS`] with text, at
//!    least one): status and hint rows, each starting with exactly two spaces, no `❯`;
//! 2. the bottom rule: a row of `─` only;
//! 3. the box: the prompt row, starting with `❯` in the first column, then any rows that
//!    are not rules (text typed into the box);
//! 4. the top rule: a row of `─` only, or `─` rows around a session name (`──── Ada ─`).
//!
//! The shape follows real `tmux capture-pane -p` captures of Claude Code 2.1.322 (README,
//! Known limits): if Claude Code draws its input box differently, sends refuse.

/// Rows (blank ones included) allowed under the input box.
pub const MAX_FOOTER_ROWS: usize = 12;
/// Rows with text allowed under the input box.
pub const MAX_FOOTER_TEXT_ROWS: usize = 6;

/// Claude Code's prompt, in the first column of the input box.
const PROMPT: char = '❯';

/// Whether the idle input box is seen at the bottom of `screen`: the only screen a send may
/// type into.
pub fn input_box_ready(screen: &str) -> bool {
    let mut rows: Vec<&str> = screen.lines().map(str::trim_end).collect();
    while rows.last().is_some_and(|r| r.is_empty()) {
        rows.pop();
    }
    // 1. The footer, up to the bottom rule.
    let Some(bottom) = rows.iter().rposition(|r| is_rule(r)) else {
        return false;
    };
    let footer = &rows[bottom + 1..];
    let text_rows = footer.iter().filter(|r| !r.is_empty()).count();
    if footer.len() > MAX_FOOTER_ROWS
        || text_rows == 0
        || text_rows > MAX_FOOTER_TEXT_ROWS
        || !footer.iter().all(|r| r.is_empty() || is_hint(r))
    {
        return false;
    }
    // 2 to 4. The nearest top rule above, with the prompt row right under it and no rule
    // row between it and the bottom rule.
    let Some(top) = rows[..bottom].iter().rposition(|r| is_top_rule(r)) else {
        return false;
    };
    let inside = &rows[top + 1..bottom];
    inside.first().is_some_and(|r| r.starts_with(PROMPT))
        && !inside.iter().any(|r| is_rule(r) || is_top_rule(r))
}

/// A hint or status row: exactly two spaces, then text, and never the prompt or a cursor.
fn is_hint(row: &str) -> bool {
    row.strip_prefix("  ")
        .is_some_and(|t| !t.starts_with(' ') && !t.is_empty())
        && !row.contains(PROMPT)
}

/// A row of box-drawing `─` only, at least ten wide.
fn is_rule(row: &str) -> bool {
    row.chars().count() >= 10 && row.chars().all(|c| c == '─')
}

/// A rule, or a rule with a session name in it: `─` rows, ` name `, then `─` to the end.
fn is_top_rule(row: &str) -> bool {
    if is_rule(row) {
        return true;
    }
    let head = row.len() - row.trim_start_matches('─').len();
    let tail = row.len() - row.trim_end_matches('─').len();
    let name = &row[head..row.len() - tail];
    // `─` is three bytes, so three rule characters are nine bytes.
    head >= 9
        && tail >= 3
        && row.chars().count() >= 10
        && name.len() > 2
        && name.starts_with(' ')
        && name.ends_with(' ')
        && !name.trim().is_empty()
        && !name.contains('─')
}
