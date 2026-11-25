//! The screen check a send runs on the agent's pane right before the paste and the Enter.
//! It is an ALLOW rule: a send may type only when Claude Code's idle input box is seen at the
//! bottom of the pane; every other screen refuses. No tmux here.
//!
//! The allowed screens copy the shape of real `tmux capture-pane -p` captures of Claude Code
//! 2.1.322 panes (idle, busy, a queued message, a shell running beside the prompt; with and
//! without the session name in the top rule); the text in them is replaced. The question
//! menu and the permission dialog are DERIVED, not captured: drawn from a reading of the
//! Claude Code bundle, since opening a real dialog needs a sandbox.

use observatory_bridge::screen::input_box_ready;

/// A rule row `n` characters wide.
fn rule(n: usize) -> String {
    "─".repeat(n)
}

/// A top rule carrying a session name, as Claude Code draws it for a named session.
fn named_rule(name: &str, width: usize) -> String {
    let tail = format!(" {name} ─");
    format!("{}{tail}", rule(width - tail.chars().count()))
}

/// Captured shape: a named session, idle, two status rows under the box.
fn idle_named() -> String {
    format!(
        "✻ Worked for 8m 15s · done 10:31 AM\n\n{}\n❯\u{a0}\n{}\n  u@host:~/work\n  \
         Model 5 · 52.3% (104.7k/200k)\n",
        named_rule("Ada", 80),
        rule(80)
    )
}

/// Captured shape: no session name, idle, blank rows, then the mode row.
fn idle_plain() -> String {
    format!(
        "  Done.\n\n{r}\n❯\u{a0}\n{r}\n  u@host:~/work\n  Model 5 · 28.0% (280.0k/1000k)\n\n\n\n\n\
         \n\n  ⏵⏵ auto mode on (shift+tab to cycle)\n{}",
        "\n".repeat(10),
        r = rule(100)
    )
}

/// Captured shape: busy (spinner and tip above the box).
fn busy() -> String {
    format!(
        "✽ Working… (4s · ↓ 267 tokens · thinking)\n  ⎿ \u{a0}Tip: a tip line\n\n{}\n❯\u{a0}\n{}\n  \
         u@host:~/work\n  Model 5 · 10.0% (20.0k/200k)\n",
        named_rule("Bo", 80),
        rule(80)
    )
}

/// Captured shape: a queued message in the box, a shell running beside the prompt.
fn queued_with_shell() -> String {
    format!(
        "{r}\n❯\u{a0}commit and push\n{r}\n  u@host:~/work\n  Model 5 · 42.0% (84.0k/200k)\n\n\n\
         \n\n\n\n  ⏵⏵ auto mode on · 1 shell\n",
        r = rule(110)
    )
}

#[test]
fn the_idle_input_box_allows_a_send() {
    assert!(input_box_ready(&idle_named()), "named top rule");
    assert!(input_box_ready(&idle_plain()), "plain top rule, blank rows");
    assert!(input_box_ready(&busy()), "busy");
    assert!(
        input_box_ready(&queued_with_shell()),
        "queued text, a shell"
    );
}

#[test]
fn a_long_session_name_in_the_top_rule_still_allows() {
    let s = format!(
        "{}\n❯\u{a0}\n{}\n  u@host:~/work\n",
        named_rule("A-very-long-session-name-for-a-narrow-pane", 60),
        rule(60)
    );
    assert!(input_box_ready(&s));
}

#[test]
fn text_in_the_input_box_is_still_the_input_box() {
    // Typed text that quotes a menu, on continuation rows.
    let s = format!(
        "{r}\n❯\u{a0}The dialog said:\n  ❯ 1. Yes\n    2. No\n{r}\n  ? for shortcuts\n",
        r = rule(80)
    );
    assert!(input_box_ready(&s));
}

#[test]
fn an_empty_or_blank_capture_refuses() {
    assert!(!input_box_ready(""));
    assert!(!input_box_ready("\n\n\n"));
}

#[test]
fn a_shell_prompt_refuses() {
    let s = "u@host:~$ ls\nnotes.txt\nu@host:~$\n";
    assert!(!input_box_ready(s));
}

#[test]
fn the_question_menu_derived_not_captured_refuses() {
    // A divider sits between the numbered options and "Chat about this".
    let s = format!(
        "{r}\n Which layout?\n\n ❯ 1. Cards\n   2. Table\n   3. Type something.\n{r}\n   \
         4. Chat about this\n\n Enter to select · Esc to cancel\n",
        r = rule(80)
    );
    assert!(!input_box_ready(&s));
}

#[test]
fn the_permission_dialog_derived_not_captured_refuses() {
    let s = format!(
        "{}\n Bash command\n\n   rm -rf build\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, \
         and don't ask again\n   3. No, and tell Claude what to do differently (esc)\n",
        rule(80)
    );
    assert!(!input_box_ready(&s));
}

#[test]
fn a_bordered_dialog_refuses() {
    let s = [
        "╭────────────────────╮",
        "│ Continue?          │",
        "│ ❯ 1. Yes           │",
        "│   2. No            │",
        "╰────────────────────╯",
    ]
    .join("\n");
    assert!(!input_box_ready(&s));
}

#[test]
fn an_unnumbered_dialog_refuses() {
    let s = "  Something happened.\n\n  Press Enter to continue…\n";
    assert!(!input_box_ready(s));
}

#[test]
fn an_input_box_above_other_rows_refuses() {
    // The box is not at the bottom: a menu was drawn under it.
    let s = format!(
        "{}\n ❯ 1. Yes\n   2. No\n\n Enter to select · Esc to cancel\n",
        idle_named()
    );
    assert!(!input_box_ready(&s));
}

#[test]
fn a_menu_row_under_the_box_refuses() {
    let s = format!("{r}\n❯\u{a0}\n{r}\n  ❯ 1. Yes\n", r = rule(80));
    assert!(!input_box_ready(&s));
}

#[test]
fn a_wrapped_rule_or_a_rule_inside_the_box_refuses() {
    // A rule split over two rows (a pane narrower than the rule): not a shape seen in a
    // capture, so refused.
    let s = format!(
        "{r}\n❯\u{a0}\n{r}\n{}\n  u@host:~/work\n",
        rule(20),
        r = rule(80)
    );
    assert!(!input_box_ready(&s));
    // A row of rule characters typed as an option of a dialog under a divider.
    let s = format!(
        "{r}\n Pick one\n ❯ 1. {}\n{r}\n  hint\n",
        rule(30),
        r = rule(80)
    );
    assert!(!input_box_ready(&s));
}

#[test]
fn a_footer_that_is_too_tall_refuses() {
    let tall: String = (1..=9).map(|i| format!("  row {i}\n")).collect();
    let s = format!("{r}\n❯\u{a0}\n{r}\n{tall}", r = rule(80));
    assert!(!input_box_ready(&s));
}
