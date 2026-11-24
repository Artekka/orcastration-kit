//! The pages panel — the "Pages N" chip, the panel (agent / whole project), and a click
//! that asks the system to open the page in the normal browser (captured here as egui's
//! `OpenUrl` output command; the app never shows the page itself).

use egui::{OutputCommand, Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::{NodeT, Queryable};
use observatory_app::model::{Agent, ChatItem, Project, Role, Status, ViewModel};
use observatory_app::pages::{Page, chip_label, empty_text, entry_label};
use observatory_app::view::row_label;
use observatory_app::{Clock, ObservatoryApp};

const NOW: i64 = 1_795_460_000;

fn page(url: &str, title: &str, ago: i64, versions: u32, deleted: bool) -> Page {
    Page {
        url: format!("https://claude.ai/artifact/{url}"),
        title: title.into(),
        time: Some(NOW - ago),
        versions,
        deleted,
    }
}

fn agent(name: &str, role: Role, pages: Vec<Page>) -> Agent {
    Agent {
        name: name.into(),
        role,
        status: Status::Idle,
        last_activity: Some(NOW - 120),
        model: None,
        permission_mode: None,
        turn_started: None,
        items: vec![
            ChatItem::User {
                text: "Publish the viewer for me".into(),
                images: vec![],
            },
            ChatItem::Assistant {
                markdown: "Published: the agent viewer is live.".into(),
            },
        ],
        pages,
        target: Default::default(),
    }
}

fn model() -> ViewModel {
    ViewModel {
        projects: vec![Project {
            name: "my-app".into(),
            agents: vec![
                agent(
                    "Lead",
                    Role::Seat,
                    vec![
                        page("Pg7Vw2Lk9Qs4Xe1Rt8Yh3n", "status-board", 300, 2, false),
                        page("Bq2kTitledPage9", "Weekly report", 7_200, 1, true),
                    ],
                ),
                agent(
                    "Ada",
                    Role::Sibling,
                    vec![page("NewFromType77", "Team dashboard", 60, 1, false)],
                ),
                agent("Bo", Role::Sibling, vec![]),
            ],
            gallery: None,
        }],
        note: None,
    }
}

fn harness() -> Harness<'static, ObservatoryApp> {
    let app = ObservatoryApp::new(model(), Clock::Fixed(NOW));
    let mut h = Harness::builder()
        .with_size(vec2(1180.0, 640.0))
        .with_theme(Theme::Dark)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    h
}

fn select(h: &mut Harness<'_, ObservatoryApp>, name: &str) {
    let vm = model();
    let a = vm.projects[0]
        .agents
        .iter()
        .find(|a| a.name == name)
        .unwrap();
    h.get_by_label(&row_label(a, NOW)).click();
    h.run();
}

fn titles(h: &Harness<'_, ObservatoryApp>) -> Vec<String> {
    // In list order (top to bottom).
    let mut v: Vec<(f32, String)> = h
        .query_all_by_label_contains("page ")
        .filter_map(|n| {
            let l = n.accesskit_node().label()?;
            let y = n.rect().top();
            l.strip_prefix("page ").map(|t| (y, t.to_owned()))
        })
        .collect();
    v.sort_by(|a, b| a.0.total_cmp(&b.0));
    v.into_iter().map(|(_, t)| t).collect()
}

#[test]
fn chip_counts_the_selected_agents_pages_and_shows_at_zero() {
    let mut h = harness();
    assert_eq!(h.state().selected.map(|r| r.agent), Some(0), "Lead first");
    h.get_by_label(&chip_label(2));
    assert!(titles(&h).is_empty(), "the panel is closed by default");
    select(&mut h, "Ada");
    h.get_by_label(&chip_label(1));
    select(&mut h, "Bo");
    // No pages still shows the chip, so the panel can always be found.
    h.get_by_label(&chip_label(0));
}

#[test]
fn chip_at_zero_opens_the_empty_panel_and_the_state_survives_switching() {
    let mut h = harness();
    select(&mut h, "Bo");
    assert!(
        h.query_by_label(&empty_text("Bo", false)).is_none(),
        "closed"
    );
    h.get_by_label(&chip_label(0)).click();
    h.run();
    h.get_by_label(&empty_text("Bo", false));
    assert!(titles(&h).is_empty());
    // "Whole project" still lists the other agents' pages.
    h.get_by_label("Whole project").click();
    h.run();
    assert_eq!(
        titles(&h),
        ["Team dashboard", "status-board", "Weekly report"]
    );
    h.get_by_label("Whole project").click();
    h.run();
    // Open stays open while switching agents, and closed stays closed.
    select(&mut h, "Lead");
    assert_eq!(titles(&h), ["status-board", "Weekly report"]);
    h.get_by_label(&chip_label(2)).click();
    h.run();
    select(&mut h, "Bo");
    assert!(h.query_by_label(&empty_text("Bo", false)).is_none());
}

#[test]
fn panel_lists_the_agents_pages_newest_first_then_the_whole_project() {
    let mut h = harness();
    h.get_by_label(&chip_label(2)).click();
    h.run();
    assert_eq!(titles(&h), ["status-board", "Weekly report"]);
    h.get_by_label("Whole project").click();
    h.run();
    assert_eq!(
        titles(&h),
        ["Team dashboard", "status-board", "Weekly report"],
        "every agent's pages, newest first"
    );
    // Closing: the chip again (or the Close button).
    h.get_by_label("Whole project").click();
    h.run();
    h.get_by_label(&chip_label(2)).click();
    h.run();
    assert!(titles(&h).is_empty());
}

#[test]
fn a_click_asks_the_system_to_open_the_page_in_the_browser() {
    let mut h = harness();
    h.get_by_label(&chip_label(2)).click();
    h.run();
    let p = &model().projects[0].agents[0].pages[0];
    h.get_by_label(&entry_label(p)).click();
    h.step();
    let opened: Vec<String> = h
        .output()
        .platform_output
        .commands
        .iter()
        .filter_map(|c| match c {
            OutputCommand::OpenUrl(o) => Some(o.url.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        opened,
        ["https://claude.ai/artifact/Pg7Vw2Lk9Qs4Xe1Rt8Yh3n"]
    );
    // A deleted page stays clickable.
    let gone = &model().projects[0].agents[0].pages[1];
    h.get_by_label(&entry_label(gone)).click();
    h.step();
    assert!(
        h.output()
            .platform_output
            .commands
            .iter()
            .any(|c| matches!(c, OutputCommand::OpenUrl(o) if o.url.ends_with("Bq2kTitledPage9")))
    );
}

#[test]
fn snapshot_agent_panel() {
    let mut h = harness();
    h.get_by_label(&chip_label(2)).click();
    h.run();
    h.snapshot("pages_agent_dark");
}

#[test]
fn snapshot_empty_agent_panel() {
    let mut h = harness();
    select(&mut h, "Bo");
    h.get_by_label(&chip_label(0)).click();
    h.run();
    h.snapshot("pages_empty_dark");
}

#[test]
fn snapshot_whole_project_panel() {
    let mut h = harness();
    h.get_by_label(&chip_label(2)).click();
    h.run();
    h.get_by_label("Whole project").click();
    h.run();
    h.snapshot("pages_project_dark");
}
