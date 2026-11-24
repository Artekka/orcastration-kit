//! Headless UI tests: behaviour checks through the accessibility tree, plus reference snapshots
//! (crates/app/tests/snapshots/*.png; regenerate with UPDATE_SNAPSHOTS=1).

use egui::{Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use observatory_app::model::{AgentRef, ChatItem, ViewModel};
use observatory_app::style::Palette;
use observatory_app::{Clock, ObservatoryApp, demo, markdown, view};

const WINDOW: [f32; 2] = [1180.0, 1500.0];

fn harness(app: ObservatoryApp, theme: Theme) -> Harness<'static, ObservatoryApp> {
    let mut h = Harness::builder()
        .with_size(vec2(WINDOW[0], WINDOW[1]))
        .with_theme(theme)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    h
}

fn select(h: &mut Harness<'_, ObservatoryApp>, row_label: &str) {
    h.get_by_label(row_label).click();
    h.run();
}

// ------------------------------------------------------------------ behaviour

#[test]
fn opens_on_the_first_projects_seat_even_when_listed_after_a_sibling() {
    let h = harness(ObservatoryApp::demo(), Theme::Dark);
    // demo lists Sib1 before Orca in replay-viewer; the seat must still come first.
    assert_eq!(
        h.state().selected,
        Some(AgentRef {
            project: 0,
            agent: 1
        })
    );
    h.get_by_label("Orca, seat, needs you, 2m");
}

#[test]
fn sidebar_groups_by_project_and_shows_every_status() {
    let h = harness(ObservatoryApp::demo(), Theme::Dark);
    h.get_by_label("REPLAY-VIEWER");
    h.get_by_label("ASSET-PIPELINE");
    for row in [
        "Orca, seat, needs you, 2m",
        "Sib1, sibling, working, now",
        "Sib2, sibling, idle, 14m",
        "Sib4, sibling, gone, 5h",
        "Lyra, seat, working, now",
        "Pip1, sibling, idle, 2d",
        "Pip2, sibling, gone, 10h",
    ] {
        h.get_by_label(row);
    }
}

#[test]
fn clicking_a_row_selects_it_and_shows_the_working_counter() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Dark);
    assert!(h.query_by_label_contains("working…").is_none());
    select(&mut h, "Sib1, sibling, working, now");
    assert_eq!(
        h.state().selected,
        Some(AgentRef {
            project: 0,
            agent: 0
        })
    );
    h.get_by_label("working… 0:45");
    h.get_by_label("Message from Orca");
}

#[test]
fn thinking_is_hidden_until_toggled() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Dark);
    let thought = "Three rows are READ PASS";
    assert!(h.query_by_label_contains(thought).is_none());
    h.get_by_label("Show thinking").click();
    h.run();
    h.get_by_label_contains(thought);
}

#[test]
fn tool_calls_fold_to_one_line_and_expand_on_click() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Dark);
    let out_line = "| S4-1 | tooltip copy | BUILDING |";
    assert!(h.query_by_label_contains(out_line).is_none());
    h.get_by_label("Read docs/orchestration/AGENT_BOARD.md")
        .click();
    h.run();
    h.get_by_label_contains(out_line);
}

#[test]
fn restart_divider_header_and_prompt_box_off_in_demo() {
    let h = harness(ObservatoryApp::demo(), Theme::Dark);
    h.get_by_label("Orca restarted · 09:12");
    h.get_by_label("replay-viewer  ·  seat  ·  claude-opus-5-5[1m]  ·  mode: auto");
    h.get_by_label(observatory_app::prompt::DEMO_NOTE);
}

#[test]
fn failed_tool_call_is_marked() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Dark);
    select(&mut h, "Sib3, sibling, idle, 3m");
    h.get_by_label("Ran bash scripts/gate.sh — failed");
}

#[test]
fn empty_model_renders_without_panicking() {
    let h = harness(
        ObservatoryApp::new(ViewModel::default(), Clock::Fixed(0)),
        Theme::Dark,
    );
    h.get_by_label("No agents running.");
}

/// No continuous repaint: after one frame the UI settles (the harness stops stepping as soon
/// as no IMMEDIATE repaint is pending), idle and mid-turn alike.
#[test]
fn ui_settles_without_immediate_repaints() {
    for row in [None, Some("Sib1, sibling, working, now")] {
        let mut h = Harness::builder()
            .with_size(vec2(WINDOW[0], WINDOW[1]))
            .with_context_setup(ObservatoryApp::install)
            .with_max_steps(8)
            .build_ui_state(
                |ui, app: &mut ObservatoryApp| app.ui(ui),
                ObservatoryApp::demo(),
            );
        h.try_run().expect("first run settles");
        if let Some(r) = row {
            select(&mut h, r);
        }
        let steps = h.try_run().expect("settles after selection");
        assert!(steps <= 2, "{row:?}: needed {steps} steps to settle");
    }
}

// ------------------------------------------------------------------ snapshots

#[test]
fn snapshot_window_dark() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Dark);
    h.snapshot("window_dark");
}

#[test]
fn snapshot_window_light() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Light);
    h.snapshot("window_light");
}

#[test]
fn snapshot_tool_expanded_and_thinking() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Dark);
    h.get_by_label("Read docs/orchestration/AGENT_BOARD.md")
        .click();
    h.get_by_label("Show thinking").click();
    h.run();
    h.snapshot("tool_expanded_dark");
}

#[test]
fn snapshot_agent_messages_and_working() {
    let mut h = harness(ObservatoryApp::demo(), Theme::Light);
    select(&mut h, "Sib1, sibling, working, now");
    h.snapshot("sib1_working_light");
}

fn markdown_snapshot(theme: Theme, name: &str) {
    let md = match &demo::orca().items.last() {
        Some(observatory_app::model::ChatItem::Assistant { markdown }) => markdown.clone(),
        other => panic!("demo's last Orca item should be the markdown reply: {other:?}"),
    };
    let mut h = Harness::builder()
        .with_theme(theme)
        .with_context_setup(ObservatoryApp::install)
        .with_size(vec2(620.0, 900.0))
        .build_ui(move |ui| {
            egui::CentralPanel::default().show(ui, |ui| {
                let pal = Palette::for_theme(ui.ctx().theme());
                let w = view::column_width(ui).min(ui.available_width());
                markdown::render(ui, &md, "md", pal, w);
            });
        });
    h.run();
    h.snapshot(name);
}

#[test]
fn snapshot_markdown_heavy_message_dark() {
    markdown_snapshot(Theme::Dark, "markdown_dark");
}

#[test]
fn snapshot_markdown_heavy_message_light() {
    markdown_snapshot(Theme::Light, "markdown_light");
}

// ------------------------------------------------------------------ resizing

const WIDE: [f32; 2] = [1600.0, 900.0];
/// The window's minimum width (main.rs `with_min_inner_size`).
const NARROW: [f32; 2] = [720.0, 900.0];

fn sized(app: ObservatoryApp, size: [f32; 2]) -> Harness<'static, ObservatoryApp> {
    let mut h = Harness::builder()
        .with_size(vec2(size[0], size[1]))
        .with_theme(Theme::Dark)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    h
}

fn resize(h: &mut Harness<'_, ObservatoryApp>, size: [f32; 2]) {
    h.set_size(vec2(size[0], size[1]));
    h.run();
}

/// Marks the wide table's cells; only they may extend past the pane, inside the table's
/// own horizontal scroll area.
const TABLE_MARK: &str = "tablecell";

/// The demo with Orca's thread extended by rows that fit only if they wrap, truncate or
/// scroll: an 80-char tool summary (core's cap), a 160-char notice title (core's cap), and
/// a three-column table wider than any column.
fn long_rows_demo() -> ObservatoryApp {
    let mut app = ObservatoryApp::demo();
    let orca = app.selected.expect("demo selects Orca");
    let items = &mut app.vm.projects[orca.project].agents[orca.agent].items;
    let summary: String = format!(
        "Ran {}",
        "cd ~/my-app-worktrees/read && cargo test -p app --test ui -- --nocapture --exact"
    )
    .chars()
    .take(80)
    .collect();
    items.push(ChatItem::ToolCall {
        summary,
        input: "i".into(),
        output: Some("o".into()),
        is_error: false,
        images: Vec::new(),
    });
    let notice: String = "Background command \"Run the parser tests on the new branch and write \
        the whole output to a log file in the temp folder\" completed (exit code 0) and then \
        some more words so it reaches the cap"
        .chars()
        .take(160)
        .collect();
    items.push(ChatItem::Notice {
        summary: notice,
        body: "details".into(),
    });
    let cell = format!("{TABLE_MARK} ").repeat(30);
    items.push(ChatItem::Assistant {
        markdown: format!(
            "| {TABLE_MARK} a | {TABLE_MARK} b | {TABLE_MARK} c |\n|---|---|---|\n| {cell} | {cell} | {cell} |"
        ),
    });
    app
}

/// Every widget outside the sidebar lies inside the chat pane's clip rect, horizontally; the
/// wide table's cells may run past its right edge only inside the table's own scroll area.
/// Returns how many were checked (a filter that matches nothing must not pass).
fn assert_pane_fits(h: &Harness<'_, ObservatoryApp>, tag: &str) -> usize {
    use egui_kittest::kittest::NodeT;
    let app = h.state();
    let clip = app.chat_viewport.expect("chat pane was drawn");
    let now = app.clock.now();
    // The sidebar, named: its title, project headings and agent rows.
    let mut sidebar = vec!["Observatory".to_owned()];
    for p in &app.vm.projects {
        sidebar.push(p.name.to_uppercase());
        sidebar.extend(p.agents.iter().map(|a| view::row_label(a, now)));
        sidebar.extend(p.gallery.iter().map(|g| view::visuals_row_label(p, g)));
    }
    let (mut checked, mut table_cells, mut table_overflows) = (0, 0, false);
    let mut side_bars = Vec::new();
    for n in h.query_all_by(|n| n.bounding_box().is_some()) {
        let node = n.accesskit_node();
        let text = node.label().or_else(|| node.value()).unwrap_or_default();
        if sidebar.contains(&text) {
            continue;
        }
        checked += 1;
        let r = n.rect();
        assert!(
            r.left() >= clip.left() - 0.5,
            "{tag}: {text:?} at {r:?} starts left of the chat pane {clip:?}"
        );
        if text.contains(TABLE_MARK) {
            table_cells += 1;
            table_overflows |= r.right() > clip.right() + 0.5;
            continue;
        }
        if node.role() == egui::accesskit::Role::ScrollBar && r.width() > r.height() {
            side_bars.push(r);
        }
        assert!(
            r.right() <= clip.right() + 0.5,
            "{tag}: {text:?} at {r:?} ends right of the chat pane {clip:?}"
        );
    }
    assert!(checked > 30, "{tag}: only {checked} widgets checked");
    assert!(
        table_cells > 3,
        "{tag}: only {table_cells} table cells seen"
    );
    // Cells past the pane's edge are only allowed inside the table's own sideways scroll area,
    // whose bar (checked above to lie inside the pane) must then be showing.
    assert!(
        !table_overflows || !side_bars.is_empty(),
        "{tag}: table cells run past the pane with no sideways scroll bar"
    );
    checked
}

#[test]
fn chat_column_always_fits_the_pane() {
    for avail in (0..=2400).step_by(7).map(|w| w as f32) {
        for column in [500.0, 723.0, 1200.0] {
            let (col, pad) = view::chat_column(column, avail);
            assert!(col <= avail + 1e-3, "{column}@{avail}: col {col}");
            assert!(
                col <= column.max(avail.min(200.0)),
                "{column}@{avail}: col {col} over cap"
            );
            assert!(
                pad >= 0.0 && (col + 2.0 * pad - avail).abs() < 1e-3,
                "{column}@{avail}"
            );
            if avail >= column + 2.0 * view::CHAT_SIDE_MARGIN {
                assert_eq!(
                    col, column,
                    "{column}@{avail}: wide panes get the full column"
                );
            }
        }
    }
}

/// The human's report: after narrowing the window the chat column's left part was clipped
/// off the pane. Wide -> narrow -> wide must keep every chat widget inside the pane, re-wrap,
/// and restore the wide layout exactly. Long one-line rows and a wide table must not clip
/// on the right either.
#[test]
fn resize_wide_narrow_wide_keeps_the_chat_inside_the_pane() {
    let tool = "Read docs/orchestration/AGENT_BOARD.md";
    let mut h = sized(long_rows_demo(), WIDE);
    assert_pane_fits(&h, "wide");
    let wide_rect = h.get_by_label(tool).rect();

    resize(&mut h, NARROW);
    assert_pane_fits(&h, "narrow");
    let narrow_rect = h.get_by_label(tool).rect();
    let clip = h.state().chat_viewport.unwrap();
    assert!(
        narrow_rect.left() >= clip.left() + view::CHAT_SIDE_MARGIN - 0.5,
        "narrow: column starts at {narrow_rect:?}, pane {clip:?}"
    );

    resize(&mut h, WIDE);
    assert_pane_fits(&h, "wide again");
    assert_eq!(
        h.get_by_label(tool).rect().left(),
        wide_rect.left(),
        "layout restored"
    );
}

#[test]
fn snapshot_resized_narrow_then_wide() {
    let mut h = sized(long_rows_demo(), WIDE);
    resize(&mut h, NARROW);
    h.snapshot("resize_narrow_dark");
    resize(&mut h, WIDE);
    h.snapshot("resize_wide_dark");
}
