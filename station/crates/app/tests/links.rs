//! Chat links: a click opens only an http or https page in the browser (captured here as
//! egui's `OpenUrl` output command). A file, a network path, a local path or any other scheme
//! is never handed to the browser, and the link says why on hover.

use egui::{OutputCommand, Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use observatory_app::model::{Agent, ChatItem, Project, Role, Status, ViewModel};
use observatory_app::view::row_label;
use observatory_app::{Clock, ObservatoryApp};

const NOW: i64 = 1_795_460_000;

const CHAT: &str = "[open-local-file](file:///etc/passwd)\n\n\
[open-network-share](file://///host.example/share/x)\n\n\
[open-script](javascript:alert(1))\n\n\
[open-web-page](https://example.com/build-log)";

fn model() -> ViewModel {
    ViewModel {
        projects: vec![Project {
            name: "my-app".into(),
            agents: vec![Agent {
                name: "Lead".into(),
                role: Role::Seat,
                status: Status::Idle,
                last_activity: Some(NOW - 120),
                model: None,
                permission_mode: None,
                turn_started: None,
                items: vec![ChatItem::Assistant {
                    markdown: CHAT.into(),
                }],
                pages: vec![],
                target: Default::default(),
            }],
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
    let a = &model().projects[0].agents[0];
    h.get_by_label(&row_label(a, NOW)).click();
    h.run();
    h
}

/// Click the link labeled `label` and return every URL the app asked the system to open.
fn click(h: &mut Harness<'_, ObservatoryApp>, label: &str) -> Vec<String> {
    h.get_by_label(label).click();
    h.step();
    h.output()
        .platform_output
        .commands
        .iter()
        .filter_map(|c| match c {
            OutputCommand::OpenUrl(o) => Some(o.url.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn a_file_link_is_never_opened() {
    let mut h = harness();
    assert_eq!(click(&mut h, "open-local-file"), Vec::<String>::new());
}

#[test]
fn a_network_path_link_is_never_opened() {
    let mut h = harness();
    assert_eq!(click(&mut h, "open-network-share"), Vec::<String>::new());
}

#[test]
fn a_script_link_is_never_opened() {
    let mut h = harness();
    assert_eq!(click(&mut h, "open-script"), Vec::<String>::new());
}

#[test]
fn a_web_link_opens_in_the_browser() {
    // Non-vacuity: the same click path does open an https link.
    let mut h = harness();
    assert_eq!(
        click(&mut h, "open-web-page"),
        ["https://example.com/build-log"]
    );
}
