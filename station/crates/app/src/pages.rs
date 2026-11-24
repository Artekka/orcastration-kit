//! Pages: the claude.ai pages agents published, listed in a right-hand panel beside the
//! chat. A "Pages N" chip under the chat opens and closes it. A click on an entry asks the system
//! to open the page in the normal browser (`ctx.open_url`; eframe's `links` feature hands it to
//! the OS); nothing is ever shown inside the app.

use egui::{
    Align, Button, Frame, Layout, Margin, Panel, RichText, ScrollArea, Sense, Stroke, Ui,
    WidgetInfo, vec2,
};
use observatory_core::Session;

use crate::model::{Agent, Project, format_age};
use crate::style::{Palette, bold_family};

/// One page in the view model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page {
    pub url: String,
    pub title: String,
    /// Unix seconds it was last published, if known.
    pub time: Option<i64>,
    pub versions: u32,
    pub deleted: bool,
}

/// An agent's pages from all its sessions (a thread), one per URL: the latest publish wins
/// (title, time, deleted), the highest version count is kept. Newest first.
pub fn from_sessions<'a>(sessions: impl IntoIterator<Item = &'a Session>) -> Vec<Page> {
    let mut out: Vec<Page> = Vec::new();
    for s in sessions {
        for p in &s.pages {
            let page = Page {
                url: p.url.clone(),
                title: p.title.clone(),
                time: p.time_ms.map(|ms| ms.div_euclid(1000)),
                versions: p.versions,
                deleted: p.deleted,
            };
            match out.iter_mut().find(|o| o.url == page.url) {
                Some(o) => {
                    let versions = o.versions.max(page.versions);
                    if page.time >= o.time {
                        *o = page;
                    }
                    o.versions = versions;
                }
                None => out.push(page),
            }
        }
    }
    newest_first(&mut out);
    out
}

fn newest_first(pages: &mut [Page]) {
    // `None` (time unknown) sorts last; ties keep their order.
    pages.sort_by_key(|p| std::cmp::Reverse(p.time));
}

/// Whether the panel is open and what it lists.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PanelState {
    pub open: bool,
    /// List every agent's pages in the project, not just the selected agent's.
    pub whole_project: bool,
}

/// Label of the chip under the chat; tests click it by this.
pub fn chip_label(n: usize) -> String {
    format!("Pages {n}")
}

/// Accessible name of a page entry; tests click it by this.
pub fn entry_label(p: &Page) -> String {
    format!("page {}", p.title)
}

/// The panel's text when the list is empty.
pub fn empty_text(agent: &str, whole_project: bool) -> String {
    if whole_project {
        "No pages published in this project yet".into()
    } else {
        format!("No pages published by {agent} yet")
    }
}

/// The "Pages N" chip for the selected agent, always shown so the panel can be found;
/// dimmed at 0. Click toggles the panel.
pub fn chip(ui: &mut Ui, agent: &Agent, state: &mut PanelState, pal: Palette) {
    let n = agent.pages.len();
    let row = vec2(ui.available_width(), 24.0);
    ui.allocate_ui_with_layout(row, Layout::right_to_left(Align::Center), |ui| {
        let color = match (state.open, n) {
            (true, _) => pal.text,
            (false, 0) => pal.weak.gamma_multiply(0.6),
            (false, _) => pal.weak,
        };
        let text = RichText::new(chip_label(n)).size(12.5).color(color);
        let b = Button::new(text)
            .fill(if state.open { pal.bubble } else { pal.code_bg })
            .stroke(Stroke::new(1.0, pal.card_stroke))
            .corner_radius(10.0);
        if ui.add(b).clicked() {
            state.open = !state.open;
        }
    });
    ui.add_space(4.0);
}

/// The right-hand panel. Call before the chat's `CentralPanel` so it takes its side first.
pub fn panel(
    ui: &mut Ui,
    project: &Project,
    agent: &Agent,
    state: &mut PanelState,
    now: i64,
    pal: Palette,
) {
    if !state.open {
        return;
    }
    Panel::right("pages")
        .resizable(true)
        .default_size(300.0)
        .size_range(200.0..=640.0)
        .frame(Frame::side_top_panel(ui.style()).inner_margin(Margin::symmetric(12, 8)))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(
                    RichText::new("Pages")
                        .size(15.0)
                        .family(bold_family())
                        .color(pal.text),
                );
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if ui.small_button("Close").clicked() {
                        state.open = false;
                    }
                    ui.checkbox(&mut state.whole_project, "Whole project");
                });
            });
            ui.add_space(6.0);
            let list: Vec<(Option<&str>, &Page)> = if state.whole_project {
                let mut all: Vec<(Option<&str>, &Page)> = project
                    .agents
                    .iter()
                    .flat_map(|a| a.pages.iter().map(move |p| (Some(a.name.as_str()), p)))
                    .collect();
                all.sort_by_key(|(_, p)| std::cmp::Reverse(p.time));
                all
            } else {
                agent.pages.iter().map(|p| (None, p)).collect()
            };
            if list.is_empty() {
                ui.label(
                    RichText::new(empty_text(&agent.name, state.whole_project)).color(pal.weak),
                );
                return;
            }
            ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
                for (who, p) in list {
                    entry(ui, who.unwrap_or(&agent.name), p, now, pal);
                    ui.add_space(6.0);
                }
            });
        });
}

fn entry(ui: &mut Ui, who: &str, p: &Page, now: i64, pal: Palette) {
    let mut title = RichText::new(&p.title)
        .size(13.5)
        .family(bold_family())
        .color(if p.deleted { pal.weak } else { pal.text });
    if p.deleted {
        title = title.strikethrough();
    }
    let mut meta = vec![who.to_owned()];
    if let Some(t) = p.time {
        meta.push(format_age(now, t));
    }
    if p.versions > 1 {
        meta.push(format!("v{}", p.versions));
    }
    if p.deleted {
        meta.push("deleted".into());
    }
    let resp = Frame::new()
        .fill(pal.code_bg)
        .stroke(Stroke::new(1.0, pal.card_stroke))
        .corner_radius(6.0)
        .inner_margin(Margin::symmetric(10, 7))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing = vec2(0.0, 2.0);
            ui.add(egui::Label::new(title).wrap().selectable(false));
            ui.add(
                egui::Label::new(RichText::new(meta.join(" · ")).size(11.5).color(pal.weak))
                    .selectable(false),
            );
        })
        .response
        .interact(Sense::click())
        .on_hover_text(&p.url)
        .on_hover_cursor(egui::CursorIcon::PointingHand);
    let label = entry_label(p);
    resp.widget_info(|| WidgetInfo::labeled(egui::Role::Button, true, label.clone()));
    if resp.clicked() {
        ui.ctx().open_url(egui::OpenUrl::new_tab(&p.url));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sess(id: &str, pages: Vec<(&str, &str, i64, u32, bool)>) -> Session {
        let mut s = Session::new("slug", id);
        s.pages = pages
            .into_iter()
            .map(|(u, t, ms, v, d)| observatory_core::Page {
                url: u.into(),
                title: t.into(),
                time_ms: Some(ms),
                versions: v,
                deleted: d,
            })
            .collect();
        s
    }

    #[test]
    fn a_thread_merges_its_sessions_pages_by_url_newest_first() {
        let old = sess(
            "a",
            vec![
                ("u/1", "first", 1_000_000, 3, false),
                ("u/2", "two", 2_000_000, 1, false),
                // The older session republished u/4 AFTER the newer one published it.
                ("u/4", "late in old", 9_000_000, 2, false),
            ],
        );
        let new = sess(
            "b",
            vec![
                ("u/1", "renamed", 5_000_000, 1, true),
                ("u/3", "three", 3_000_000, 1, false),
                ("u/4", "early in new", 4_000_000, 1, false),
            ],
        );
        let got = from_sessions([&old, &new]);
        let short: Vec<(&str, &str, Option<i64>, u32, bool)> = got
            .iter()
            .map(|p| {
                (
                    p.url.as_str(),
                    p.title.as_str(),
                    p.time,
                    p.versions,
                    p.deleted,
                )
            })
            .collect();
        assert_eq!(
            short,
            [
                // latest publish's title/time/deleted (by time, not by session order),
                // highest version count
                ("u/4", "late in old", Some(9_000), 2, false),
                ("u/1", "renamed", Some(5_000), 3, true),
                ("u/3", "three", Some(3_000), 1, false),
                ("u/2", "two", Some(2_000), 1, false),
            ]
        );
    }
}
