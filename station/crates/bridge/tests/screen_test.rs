//! The menu check a send runs on the agent's pane right before the paste and the Enter.
//! Synthetic screens in the shape of Claude Code's terminal; no tmux.

use observatory_bridge::screen::menu_open;

/// A permission dialog: a numbered menu under the `❯` cursor, no input box under it.
const MENU: &str = "\
  Done reading the build log.

────────────────────────────────────────────────────────────
 Bash command

   rm -rf build

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands in /work
   3. No, and tell Claude what to do differently (esc)
";

/// The idle prompt: the input box between two rules, a hint line under it.
const IDLE: &str = "\
  Done reading the build log.

────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────
  ? for shortcuts
";

#[test]
fn a_permission_menu_is_open() {
    assert!(menu_open(MENU));
}

#[test]
fn a_question_menu_with_the_cursor_on_a_later_option_is_open() {
    let question = "\
 Which layout?

   1. Cards
 ❯ 2. Table
   3. Both

 Enter to select · ↑/↓ to navigate · Esc to cancel
";
    assert!(menu_open(question));
}

#[test]
fn blank_rows_under_the_menu_are_ignored() {
    // capture-pane prints the whole pane, so a short screen ends in empty rows.
    assert!(menu_open(&format!("{MENU}{}", "\n".repeat(40))));
}

#[test]
fn the_idle_prompt_is_not_a_menu() {
    assert!(!menu_open(IDLE));
    assert!(!menu_open(""));
}

#[test]
fn menu_text_typed_into_the_input_box_is_not_a_menu() {
    let typed = "\
────────────────────────────────────────────────────────────
❯ 1. Yes
  ❯ 2. No
────────────────────────────────────────────────────────────
  ? for shortcuts
";
    assert!(!menu_open(typed));
}

#[test]
fn a_menu_above_the_bottom_rows_is_not_counted() {
    // An old menu quoted in the transcript, then output that pushed it up the screen.
    let lines: String = (1..=20).map(|i| format!("  line {i}\n")).collect();
    assert!(!menu_open(&format!("{MENU}{lines}")));
}

#[test]
fn a_numbered_list_without_the_cursor_is_not_a_menu() {
    assert!(!menu_open("  1. Yes\n  2. No\n"));
}
