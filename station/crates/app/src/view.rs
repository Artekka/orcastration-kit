//! The window's pieces: sidebar, header, chat thread (the prompt box is in `prompt`).

use std::sync::Arc;

use egui::text::{LayoutJob, TextFormat, TextWrapping};
use egui::{
    Align, Align2, CollapsingHeader, FontFamily, FontId, FontSelection, Frame, Galley, Label,
    Layout, Margin, RichText, Sense, Stroke, TextStyle, Theme, Ui, WidgetInfo, WidgetText, pos2,
    vec2,
};

use crate::images::{ImageCache, Slot, THUMB_MAX_H};
use crate::markdown;
use crate::model::{
    Agent, AgentRef, ChatItem, Gallery, GalleryImage, Image, Project, Role, Status, ViewModel,
    format_age, format_working, sidebar_order, truncate,
};
use crate::style::{BODY_SIZE, COLUMN_CHARS, LINE_HEIGHT, Palette, bold_family, status_color};

const TOOL_MAX_LINES: usize = 14;
const TOOL_MAX_CHARS: usize = 2000;
/// Thumbnails shown before "+N more".
pub const THUMBS_SHOWN: usize = 6;
/// A thumbnail's spot before it has loaded (and while off screen).
const THUMB_PLACEHOLDER: egui::Vec2 = egui::vec2(120.0, 90.0);

/// Accessible name of a sidebar row; tests click rows by it.
pub fn row_label(a: &Agent, now: i64) -> String {
    let age = a.last_activity.map(|t| format_age(now, t));
    match age {
        Some(age) => format!(
            "{}, {}, {}, {age}",
            a.name,
            a.role.label(),
            a.status.label()
        ),
        None => format!("{}, {}, {}", a.name, a.role.label(), a.status.label()),
    }
}

fn body_job(text: &str, color: egui::Color32, italics: bool, width: f32) -> LayoutJob {
    let mut job = LayoutJob::default();
    job.append(
        text,
        0.0,
        TextFormat {
            font_id: FontId::proportional(BODY_SIZE),
            color,
            italics,
            line_height: Some(BODY_SIZE * LINE_HEIGHT),
            ..Default::default()
        },
    );
    job.wrap.max_width = width;
    job
}

fn dot(ui: &Ui, center: egui::Pos2, status: Status, theme: Theme) {
    let c = status_color(status, theme);
    if status == Status::Gone {
        ui.painter().circle_stroke(center, 4.0, Stroke::new(1.5, c));
    } else {
        ui.painter().circle_filled(center, 4.5, c);
    }
}

// ---------------------------------------------------------------- sidebar

/// What the main pane shows: an agent's chat, or a project's Visuals (`visuals` wins).
pub struct Selection<'a> {
    pub agent: &'a mut Option<AgentRef>,
    /// Index of the project whose Visuals are shown.
    pub visuals: &'a mut Option<usize>,
}

pub fn sidebar(ui: &mut Ui, vm: &ViewModel, sel: Selection<'_>, now: i64, pal: Palette) {
    let Selection {
        agent: selected,
        visuals,
    } = sel;
    let theme = ui.ctx().theme();
    ui.add_space(10.0);
    ui.label(
        RichText::new("Observatory")
            .size(17.0)
            .family(bold_family()),
    );
    ui.add_space(6.0);
    if let Some(note) = &vm.note {
        // The bridge has no usable config: say where it goes (wraps within the sidebar).
        ui.add(egui::Label::new(RichText::new(note).color(pal.weak).size(12.0)).wrap());
        ui.add_space(6.0);
    }
    if vm.projects.iter().all(|p| p.agents.is_empty()) {
        ui.label(RichText::new("No agents yet.").color(pal.weak));
    }
    for (pi, p) in vm.projects.iter().enumerate() {
        ui.add_space(10.0);
        ui.label(
            RichText::new(p.name.to_uppercase())
                .size(11.5)
                .family(bold_family())
                .color(pal.weak),
        );
        ui.add_space(2.0);
        if let Some(g) = &p.gallery
            && visuals_row(ui, p, g, *visuals == Some(pi), pal).clicked()
        {
            *visuals = Some(pi);
        }
        for ai in sidebar_order(p) {
            let r = AgentRef {
                project: pi,
                agent: ai,
            };
            let a = &p.agents[ai];
            let indent = if a.role == Role::Seat { 0.0 } else { 14.0 };
            let is_selected = visuals.is_none() && *selected == Some(r);
            if agent_row(ui, a, is_selected, indent, now, pal, theme).clicked() {
                *selected = Some(r);
                *visuals = None;
            }
        }
    }
}

/// "10,909": thousands separated, as the sidebar and the Visuals header show counts.
pub fn count_label(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// Accessible name of a project's "Visuals (N)" sidebar row; tests click rows by it.
pub fn visuals_row_label(p: &Project, g: &Gallery) -> String {
    format!("Visuals ({}), {}", count_label(g.total as u64), p.name)
}

fn visuals_row(
    ui: &mut Ui,
    p: &Project,
    g: &Gallery,
    is_selected: bool,
    pal: Palette,
) -> egui::Response {
    let (rect, resp) = ui.allocate_exact_size(vec2(ui.available_width(), 30.0), Sense::click());
    let label = visuals_row_label(p, g);
    resp.widget_info(|| WidgetInfo::selected(egui::Role::Button, true, is_selected, label.clone()));
    let painter = ui.painter();
    if is_selected {
        painter.rect_filled(rect, 6.0, pal.sidebar_selected);
    } else if resp.hovered() {
        painter.rect_filled(rect, 6.0, pal.sidebar_hover);
    }
    let x = rect.left() + 8.0;
    let cy = rect.center().y;
    // A small "picture" glyph where agent rows have their status dot.
    let icon = egui::Rect::from_center_size(pos2(x + 4.0, cy), vec2(10.0, 8.0));
    painter.rect_stroke(
        icon,
        1.5,
        Stroke::new(1.3, pal.weak),
        egui::StrokeKind::Inside,
    );
    painter.text(
        pos2(x + 16.0, cy),
        Align2::LEFT_CENTER,
        format!("Visuals ({})", count_label(g.total as u64)),
        FontId::new(14.0, bold_family()),
        pal.text,
    );
    resp
}

fn agent_row(
    ui: &mut Ui,
    a: &Agent,
    is_selected: bool,
    indent: f32,
    now: i64,
    pal: Palette,
    theme: Theme,
) -> egui::Response {
    let (rect, resp) = ui.allocate_exact_size(vec2(ui.available_width(), 40.0), Sense::click());
    let label = row_label(a, now);
    resp.widget_info(|| WidgetInfo::selected(egui::Role::Button, true, is_selected, label.clone()));
    let p = ui.painter();
    if is_selected {
        p.rect_filled(rect, 6.0, pal.sidebar_selected);
    } else if resp.hovered() {
        p.rect_filled(rect, 6.0, pal.sidebar_hover);
    }
    let gone = a.status == Status::Gone;
    let dim = |c: egui::Color32| if gone { c.gamma_multiply(0.55) } else { c };
    let x = rect.left() + 8.0 + indent;
    let cy = rect.center().y;
    dot(ui, pos2(x + 4.0, cy - 7.0), a.status, theme);
    p.text(
        pos2(x + 16.0, cy - 7.0),
        Align2::LEFT_CENTER,
        &a.name,
        FontId::new(14.5, bold_family()),
        dim(pal.text),
    );
    p.text(
        pos2(x + 16.0, cy + 9.0),
        Align2::LEFT_CENTER,
        format!("{} · {}", a.role.label(), a.status.label()),
        FontId::proportional(12.0),
        dim(pal.weak),
    );
    if let Some(t) = a.last_activity {
        p.text(
            pos2(rect.right() - 10.0, cy - 7.0),
            Align2::RIGHT_CENTER,
            format_age(now, t),
            FontId::proportional(12.0),
            dim(pal.weak),
        );
    }
    resp
}

// ---------------------------------------------------------------- header

pub struct HeaderState<'a> {
    pub show_thinking: &'a mut bool,
}

pub fn header(ui: &mut Ui, p: &Project, a: &Agent, st: HeaderState<'_>, pal: Palette) {
    let theme = ui.ctx().theme();
    ui.add_space(8.0);
    ui.horizontal(|ui| {
        ui.label(RichText::new(&a.name).size(20.0).family(bold_family()));
        let (r, _) = ui.allocate_exact_size(vec2(12.0, 20.0), Sense::hover());
        dot(ui, r.center(), a.status, theme);
        ui.label(RichText::new(a.status.label()).color(pal.weak));
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            let (next, text) = match theme {
                Theme::Dark => (Theme::Light, "Light theme"),
                Theme::Light => (Theme::Dark, "Dark theme"),
            };
            if ui.button(text).clicked() {
                ui.ctx().set_theme(next);
            }
            ui.checkbox(st.show_thinking, "Show thinking");
        });
    });
    let mut meta = vec![p.name.clone(), a.role.label().to_owned()];
    meta.extend(a.model.clone());
    meta.extend(a.permission_mode.as_ref().map(|m| format!("mode: {m}")));
    ui.label(RichText::new(meta.join("  ·  ")).size(13.0).color(pal.weak));
    ui.add_space(6.0);
}

// ---------------------------------------------------------------- chat

/// Width of the `COLUMN_CHARS` (~100-character) text column for the body font.
pub fn column_width(ui: &Ui) -> f32 {
    const SAMPLE: &str = "the quick brown fox jumps over the lazy dog, Then Writes 42 Tests.";
    let w = ui
        .painter()
        .layout_no_wrap(
            SAMPLE.into(),
            FontId::new(BODY_SIZE, FontFamily::Proportional),
            egui::Color32::WHITE,
        )
        .size()
        .x;
    w / SAMPLE.chars().count() as f32 * COLUMN_CHARS
}

pub struct ChatOpts {
    pub show_thinking: bool,
    pub now: i64,
    pub key: AgentRef,
}

/// Space kept on each side of the chat column when the pane is narrower than the column.
pub const CHAT_SIDE_MARGIN: f32 = 24.0;

/// The chat column's width and left pad for a pane `available` points wide: the
/// `COLUMN_CHARS` column, capped so it fits the pane minus a side margin, centred.
/// Never wider than `available`, so nothing is clipped at any window size.
pub fn chat_column(column: f32, available: f32) -> (f32, f32) {
    let available = available.max(0.0);
    let col = column
        .min(available - 2.0 * CHAT_SIDE_MARGIN)
        .max(available.min(200.0));
    (col, ((available - col) / 2.0).max(0.0))
}

pub fn chat(ui: &mut Ui, a: &Agent, opts: &ChatOpts, imgs: &mut ImageCache, pal: Palette) {
    let (col, pad) = chat_column(column_width(ui), ui.available_width());
    ui.horizontal_top(|ui| {
        ui.add_space(pad);
        ui.vertical(|ui| {
            ui.set_width(col);
            ui.spacing_mut().item_spacing.y = 10.0;
            ui.add_space(12.0);
            if a.items.is_empty() {
                ui.label(RichText::new("No messages yet.").color(pal.weak));
            }
            for (i, item) in a.items.iter().enumerate() {
                chat_item(ui, a, item, i, opts, col, imgs, pal);
            }
            if let Some(started) = a.turn_started {
                ui.label(
                    RichText::new(format_working(opts.now, started))
                        .italics()
                        .color(pal.weak),
                );
            }
            ui.add_space(16.0);
        });
    });
}

#[allow(clippy::too_many_arguments)]
fn chat_item(
    ui: &mut Ui,
    a: &Agent,
    item: &ChatItem,
    i: usize,
    opts: &ChatOpts,
    col: f32,
    imgs: &mut ImageCache,
    pal: Palette,
) {
    let salt = (opts.key.project, opts.key.agent, i);
    match item {
        ChatItem::User { text, images } => {
            if text.trim().is_empty() {
                thumb_row(ui, images, true, salt, imgs, pal);
                return;
            }
            ui.with_layout(Layout::right_to_left(Align::TOP), |ui| {
                Frame::new()
                    .fill(pal.bubble)
                    .corner_radius(14.0)
                    .inner_margin(Margin::symmetric(14, 9))
                    .show(ui, |ui| {
                        // A pre-laid-out galley: inside right_to_left (a non-wrapping layout) a
                        // Label given a LayoutJob switches to TextWrapMode::Extend and drops the
                        // wrap width, so a long message grew leftward past the column.
                        let job = body_job(text, pal.text, false, col * 0.78);
                        let galley = ui.painter().layout_job(job);
                        ui.add(Label::new(galley));
                    });
            });
            thumb_row(ui, images, true, salt, imgs, pal);
        }
        ChatItem::AgentMessage { from, body } => {
            Frame::new()
                .fill(pal.card)
                .stroke(Stroke::new(1.0, pal.card_stroke))
                .corner_radius(8.0)
                .inner_margin(Margin::symmetric(12, 10))
                .show(ui, |ui| {
                    ui.set_width(col - 26.0);
                    ui.label(
                        RichText::new(format!("Message from {from}"))
                            .size(12.5)
                            .family(bold_family())
                            .color(pal.weak),
                    );
                    markdown::render(ui, body, ("agent-msg", salt), pal, col - 26.0);
                });
        }
        ChatItem::Assistant { markdown: md } => {
            markdown::render(ui, md, ("md", salt), pal, col);
        }
        ChatItem::Thinking { text } => {
            if opts.show_thinking {
                Frame::new()
                    .inner_margin(Margin {
                        left: 12,
                        ..Default::default()
                    })
                    .stroke(Stroke::NONE)
                    .show(ui, |ui| {
                        ui.label(RichText::new("Thinking").size(12.5).color(pal.weak));
                        ui.add(Label::new(body_job(text, pal.weak, true, col - 12.0)));
                    });
            }
        }
        ChatItem::ToolCall {
            summary,
            input,
            output,
            is_error,
            images,
        } => {
            tool_call(ui, summary, input, output.as_deref(), *is_error, salt, pal);
            thumb_row(ui, images, false, salt, imgs, pal);
        }
        ChatItem::Restart { at_label } => restart_divider(ui, &a.name, at_label, pal),
        ChatItem::Notice { summary, body } => notice(ui, summary, body, salt, pal),
    }
}

/// Accessible name of a thumbnail; tests click it by this.
pub fn thumb_label(img: &Image) -> String {
    format!("image {}", img.name)
}

/// The images under a chat item: a wrapping row of thumbnails, the first [`THUMBS_SHOWN`] and a
/// "+N more" button that shows the rest. `right`: aligned under a right-hand bubble.
fn thumb_row(
    ui: &mut Ui,
    images: &[Image],
    right: bool,
    salt: (usize, usize, usize),
    imgs: &mut ImageCache,
    pal: Palette,
) {
    if images.is_empty() {
        return;
    }
    // Hide-if-missing images (files named only in a shell command) are resolved as soon as the
    // row is on screen, so a missing one drops out before "first 6 / +N more" is counted.
    let row = ui.max_rect();
    let probe = egui::Rect::from_min_size(
        egui::pos2(row.left(), ui.cursor().top()),
        vec2(row.width(), THUMB_PLACEHOLDER.y),
    );
    if ui.is_rect_visible(probe) {
        for img in images.iter().filter(|i| i.hide_if_missing) {
            imgs.thumb(ui.ctx(), &img.src);
        }
    }
    let images: Vec<&Image> = images
        .iter()
        .filter(|i| !(i.hide_if_missing && matches!(imgs.peek(&i.src), Some(Slot::Failed(_)))))
        .collect();
    if images.is_empty() {
        return;
    }
    let id = ui.scope_id().with(("thumbs-more", salt));
    let expanded = ui.data(|d| d.get_temp::<bool>(id)).unwrap_or(false);
    let shown = if expanded {
        images.len()
    } else {
        images.len().min(THUMBS_SHOWN)
    };
    let layout = if right {
        Layout::right_to_left(Align::TOP)
    } else {
        Layout::left_to_right(Align::TOP)
    };
    ui.with_layout(layout.with_main_wrap(true), |ui| {
        ui.spacing_mut().item_spacing = vec2(8.0, 8.0);
        let rest = images.len() - shown;
        let more = |ui: &mut Ui| {
            if rest > 0 && ui.button(format!("+{rest} more")).clicked() {
                ui.data_mut(|d| d.insert_temp(id, true));
            }
        };
        // A right-to-left row places its first widget rightmost: add them in reverse so the
        // images still read left to right, with "+N more" last.
        if right {
            more(ui);
            for img in images[..shown].iter().rev() {
                thumb(ui, img, imgs, pal);
            }
        } else {
            for img in &images[..shown] {
                thumb(ui, img, imgs, pal);
            }
            more(ui);
        }
    });
}

fn thumb(ui: &mut Ui, img: &Image, imgs: &mut ImageCache, pal: Palette) {
    // Off screen: hold the spot without loading anything. Only the vertical position matters
    // (the chat scrolls vertically), so probe the row's full width at the cursor's height; this
    // holds for left-to-right and right-to-left rows alike.
    let row = ui.max_rect();
    let probe = egui::Rect::from_min_size(
        egui::pos2(row.left(), ui.cursor().top()),
        vec2(row.width(), THUMB_PLACEHOLDER.y),
    );
    let slot = if ui.is_rect_visible(probe) {
        Some(imgs.thumb(ui.ctx(), &img.src))
    } else {
        None
    };
    let label = thumb_label(img);
    match slot {
        Some(Slot::Ready(tex)) => {
            let mut size = tex.size_vec2();
            if size.y > THUMB_MAX_H as f32 {
                size *= THUMB_MAX_H as f32 / size.y;
            }
            let resp = ui
                .add(egui::Image::new((tex.id(), size)).sense(Sense::click()))
                .on_hover_text(img.path.as_deref().unwrap_or(&img.name));
            resp.widget_info(|| WidgetInfo::labeled(egui::Role::Button, true, label.clone()));
            if resp.clicked() {
                imgs.open = Some(img.clone());
            }
        }
        // Hidden when missing (see `thumb_row`); never a placeholder, even for one frame.
        Some(Slot::Failed(_)) if img.hide_if_missing => {}
        Some(Slot::Failed(why)) => {
            let shown = img.path.as_deref().unwrap_or(&img.name);
            Frame::new()
                .fill(pal.code_bg)
                .stroke(Stroke::new(1.0, pal.card_stroke))
                .corner_radius(6.0)
                .inner_margin(8.0)
                .show(ui, |ui| {
                    ui.set_max_width(260.0);
                    ui.vertical(|ui| {
                        ui.label(
                            RichText::new("image unavailable")
                                .size(12.5)
                                .color(pal.weak),
                        );
                        ui.add(
                            Label::new(RichText::new(shown).size(11.5).monospace().color(pal.weak))
                                .wrap(),
                        );
                    });
                })
                .response
                .on_hover_text(why)
                .widget_info(|| {
                    WidgetInfo::labeled(
                        egui::Role::Label,
                        true,
                        format!("image unavailable {shown}"),
                    )
                });
        }
        // Not resolved yet and may turn out missing: draw nothing rather than a placeholder that
        // would vanish (the row only ever grows when it loads, never jumps back).
        Some(Slot::Pending) | None if img.hide_if_missing => {}
        Some(Slot::Pending) | None => {
            let (rect, resp) = ui.allocate_exact_size(THUMB_PLACEHOLDER, Sense::hover());
            ui.painter().rect_filled(rect, 6.0, pal.code_bg);
            resp.widget_info(|| {
                WidgetInfo::labeled(egui::Role::Label, true, format!("{label} loading"))
            });
        }
    }
}

/// The enlarged image, over the window: fits the window, keeps its aspect ratio, shows its name
/// and (for a file) its full path. Esc or a click outside closes it and frees its pixels.
pub fn image_viewer(ctx: &egui::Context, imgs: &mut ImageCache, pal: Palette) {
    let Some(img) = imgs.open.clone() else {
        return;
    };
    let screen = ctx.content_rect();
    let slot = imgs.full(ctx, &img.src);
    let resp = egui::Modal::new(egui::Id::unique("image-viewer")).show(ctx, |ui| {
        ui.label(
            RichText::new(&img.name)
                .size(14.0)
                .family(bold_family())
                .color(pal.text),
        );
        if let Some(p) = &img.path {
            ui.add(Label::new(RichText::new(p).size(12.0).monospace().color(pal.weak)).wrap());
        }
        ui.add_space(6.0);
        let max =
            vec2(screen.width() * 0.9 - 32.0, screen.height() * 0.9 - 80.0).max(vec2(32.0, 32.0));
        match slot {
            Slot::Ready(tex) => {
                let s = tex.size_vec2();
                let k = (max.x / s.x).min(max.y / s.y);
                ui.add(egui::Image::new((tex.id(), s * k)));
            }
            Slot::Pending => {
                ui.add_sized(vec2(240.0, 160.0), egui::Spinner::new());
            }
            Slot::Failed(why) => {
                ui.label(RichText::new(format!("image unavailable: {why}")).color(pal.weak));
            }
        }
    });
    if resp.should_close() {
        imgs.close();
    }
}

fn notice(ui: &mut Ui, summary: &str, body: &str, salt: (usize, usize, usize), pal: Palette) {
    let title = RichText::new(summary).size(13.0).italics().color(pal.weak);
    if body.trim().is_empty() || body.trim() == summary.trim() {
        ui.label(title);
        return;
    }
    CollapsingHeader::new(header_title(ui, title))
        .id_salt(("notice", salt))
        .default_open(false)
        .show(ui, |ui| mono_box(ui, "Details", body, pal.text, pal));
}

/// A collapsing row's title, cut to one line ending in "…" so it fits the column: egui lays
/// header text out unwrapped, so a long title ran past the pane's right edge. The
/// full text stays the row's accessible name and is shown when the row is expanded.
fn header_title(ui: &Ui, title: RichText) -> Arc<Galley> {
    let width = ui.available_width() - ui.spacing().indent - ui.spacing().button_padding.x;
    let mut job = Arc::unwrap_or_clone(WidgetText::from(title).into_layout_job(
        ui.style(),
        FontSelection::Style(TextStyle::Button),
        Align::Center,
    ));
    job.wrap = TextWrapping::truncate_at_width(width.max(0.0));
    ui.painter().layout_job(job)
}

/// A strip at the top of the window saying why there is no live data, with a Retry button
/// when `retry` (a failure). Returns true when Retry was clicked.
pub fn bridge_banner(ui: &mut Ui, text: &str, retry: bool, pal: Palette) -> bool {
    let mut clicked = false;
    ui.add_space(6.0);
    ui.horizontal(|ui| {
        let color = if retry { pal.error } else { pal.weak };
        if retry && ui.button("Retry").clicked() {
            clicked = true;
        }
        ui.add(Label::new(RichText::new(text).color(color)).wrap());
    });
    ui.add_space(6.0);
    clicked
}

fn tool_call(
    ui: &mut Ui,
    summary: &str,
    input: &str,
    output: Option<&str>,
    is_error: bool,
    salt: (usize, usize, usize),
    pal: Palette,
) {
    let title = if is_error {
        RichText::new(format!("{summary} — failed")).color(pal.error)
    } else {
        RichText::new(summary).color(pal.weak)
    };
    CollapsingHeader::new(header_title(ui, title.size(14.0)))
        .id_salt(("tool", salt))
        .default_open(false)
        .show(ui, |ui| {
            mono_box(ui, "Input", input, pal.text, pal);
            if let Some(out) = output {
                mono_box(
                    ui,
                    "Output",
                    out,
                    if is_error { pal.error } else { pal.text },
                    pal,
                );
            }
        });
}

fn mono_box(ui: &mut Ui, title: &str, text: &str, color: egui::Color32, pal: Palette) {
    ui.label(RichText::new(title).size(12.0).color(pal.weak));
    Frame::new()
        .fill(pal.code_bg)
        .corner_radius(6.0)
        .inner_margin(8.0)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(
                RichText::new(truncate(text, TOOL_MAX_LINES, TOOL_MAX_CHARS))
                    .monospace()
                    .color(color),
            );
        });
}

fn restart_divider(ui: &mut Ui, name: &str, at: &str, pal: Palette) {
    let text = format!("{name} restarted · {at}");
    let (rect, resp) = ui.allocate_exact_size(vec2(ui.available_width(), 26.0), Sense::hover());
    resp.widget_info(|| WidgetInfo::labeled(egui::Role::Label, true, text.clone()));
    let p = ui.painter();
    let galley = p.layout_no_wrap(text, FontId::proportional(12.5), pal.weak);
    let tw = galley.size().x + 20.0;
    let c = rect.center();
    let stroke = Stroke::new(1.0, pal.card_stroke);
    p.hline(rect.left()..=c.x - tw / 2.0, c.y, stroke);
    p.hline(c.x + tw / 2.0..=rect.right(), c.y, stroke);
    p.galley(c - galley.size() / 2.0, galley, pal.weak);
}

// ---------------------------------------------------------------- visuals

/// Tiles listed at first, and how many more each "Show older" adds (up to what the bridge sent).
pub const VISUALS_PAGE: usize = 400;
/// One tile: the thumbnail box plus a two-line caption.
pub const TILE: egui::Vec2 = egui::vec2(168.0, 152.0);
const TILE_IMAGE: egui::Vec2 = egui::vec2(168.0, 112.0);
const TILE_GAP: f32 = 10.0;

/// Accessible name of a gallery tile; tests find tiles by it.
pub fn tile_label(g: &GalleryImage) -> String {
    format!("visual {}", g.image.name)
}

/// "5m ago" / "just now", for tile captions.
pub fn age_caption(now: i64, then: i64) -> String {
    match format_age(now, then).as_str() {
        "now" => "just now".into(),
        a => format!("{a} ago"),
    }
}

/// How many tiles are listed for this project right now (the "Show older" state).
fn listed_id(project: &str) -> egui::Id {
    egui::Id::unique(("visuals-listed", project))
}

/// Tiles per row for a pane `width` points wide (at least one).
pub fn tile_columns(width: f32) -> usize {
    (((width + TILE_GAP) / (TILE.x + TILE_GAP)).floor() as usize).max(1)
}

pub fn visuals_header(ui: &mut Ui, p: &Project, g: &Gallery, pal: Palette) {
    ui.add_space(8.0);
    ui.label(RichText::new("Visuals").size(20.0).family(bold_family()));
    let count = match g.total {
        1 => "1 image".to_owned(),
        n => format!("{} images", count_label(n as u64)),
    };
    ui.label(
        RichText::new(format!("{}  ·  {count}  ·  newest first", p.name))
            .size(13.0)
            .color(pal.weak),
    );
    ui.add_space(8.0);
}

/// The project's images as a newest-first grid. Only the rows on screen are laid out, so only
/// their thumbnails load; [`VISUALS_PAGE`] tiles are listed, "Show older" adds more.
pub fn visuals(
    ui: &mut Ui,
    p: &Project,
    g: &Gallery,
    now: i64,
    imgs: &mut ImageCache,
    pal: Palette,
) {
    if g.items.is_empty() {
        ui.add_space(20.0);
        ui.label(RichText::new("No images in this project's folders yet.").color(pal.weak));
        return;
    }
    let id = listed_id(&p.name);
    let listed = ui
        .data(|d| d.get_temp::<usize>(id))
        .unwrap_or(VISUALS_PAGE)
        .min(g.items.len());
    let older_here = g.items.len() - listed;
    let not_listed = g.not_listed();
    let cols = tile_columns(ui.available_width());
    let rows = listed.div_ceil(cols);
    let footer = usize::from(older_here > 0 || not_listed > 0);
    let mut more = false;
    ui.spacing_mut().item_spacing.y = TILE_GAP;
    egui::ScrollArea::vertical()
        .id_salt(("visuals", &p.name))
        .auto_shrink(false)
        .show_rows(ui, TILE.y, rows + footer, |ui, range| {
            for row in range {
                if row == rows {
                    ui.horizontal(|ui| {
                        if older_here > 0
                            && ui
                                .button(format!(
                                    "Show older ({} more)",
                                    count_label(older_here as u64)
                                ))
                                .clicked()
                        {
                            more = true;
                        }
                        if older_here == 0 && not_listed > 0 {
                            ui.label(
                                RichText::new(format!(
                                    "{} older images not listed (newest {} only)",
                                    count_label(not_listed),
                                    count_label(g.items.len() as u64)
                                ))
                                .color(pal.weak),
                            );
                        }
                    });
                    continue;
                }
                ui.horizontal(|ui| {
                    ui.spacing_mut().item_spacing.x = TILE_GAP;
                    let start = row * cols;
                    for item in &g.items[start..(start + cols).min(listed)] {
                        tile(ui, item, now, imgs, pal);
                    }
                });
            }
        });
    if more {
        ui.data_mut(|d| d.insert_temp(id, (listed + VISUALS_PAGE).min(g.items.len())));
    }
}

fn tile(ui: &mut Ui, g: &GalleryImage, now: i64, imgs: &mut ImageCache, pal: Palette) {
    let (rect, resp) = ui.allocate_exact_size(TILE, Sense::click());
    // Only rows on screen are laid out (`show_rows`), so drawing a tile is what loads it.
    let slot = imgs.thumb(ui.ctx(), &g.image.src);
    let label = match &slot {
        Slot::Ready(_) => tile_label(g),
        Slot::Pending => format!("{} loading", tile_label(g)),
        Slot::Failed(_) => format!("{} unavailable", tile_label(g)),
    };
    resp.widget_info(|| WidgetInfo::labeled(egui::Role::Button, true, label.clone()));
    let painter = ui.painter_at(rect);
    let image_rect = egui::Rect::from_min_size(rect.min, TILE_IMAGE);
    painter.rect_filled(image_rect, 6.0, pal.code_bg);
    match &slot {
        Slot::Ready(tex) => {
            let s = tex.size_vec2();
            let k = (TILE_IMAGE.x / s.x).min(TILE_IMAGE.y / s.y);
            let r = egui::Rect::from_center_size(image_rect.center(), s * k);
            painter.image(
                tex.id(),
                r,
                egui::Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)),
                egui::Color32::WHITE,
            );
        }
        Slot::Pending => {}
        Slot::Failed(_) => {
            painter.text(
                image_rect.center(),
                Align2::CENTER_CENTER,
                "image unavailable",
                FontId::proportional(12.0),
                pal.weak,
            );
        }
    }
    if resp.hovered() {
        painter.rect_stroke(
            image_rect,
            6.0,
            Stroke::new(1.5, pal.weak),
            egui::StrokeKind::Inside,
        );
    }
    let caption = |text: &str, y: f32, color: egui::Color32| {
        let mut job = LayoutJob::single_section(
            text.to_owned(),
            TextFormat::simple(FontId::proportional(12.0), color),
        );
        job.wrap = TextWrapping::truncate_at_width(TILE.x);
        let galley = ui.painter().layout_job(job);
        painter.galley(pos2(rect.left(), y), galley, color);
    };
    caption(&g.image.name, image_rect.bottom() + 5.0, pal.text);
    caption(
        &age_caption(now, g.modified),
        image_rect.bottom() + 22.0,
        pal.weak,
    );
    let why = match &slot {
        Slot::Failed(why) => format!("\nimage unavailable: {why}"),
        _ => String::new(),
    };
    let resp = resp.on_hover_text(format!(
        "{}\n{}\n{}{why}",
        g.image.name,
        g.folder,
        age_caption(now, g.modified)
    ));
    if resp.clicked() {
        imgs.open = Some(g.image.clone());
    }
}
