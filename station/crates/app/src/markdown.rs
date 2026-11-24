//! A small CommonMark renderer for agent replies: headings, paragraphs, bold/italic/strike,
//! inline code, links (http and https open on click; any other link is drawn struck
//! through and says why on hover, see [`link_target`]), lists (nested, ordered), block quotes, rules, tables and
//! fenced code blocks with syntax highlighting. Our own (rather than egui_commonmark) so every
//! run of text gets the generous line height and the fixed text column.

use std::ops::Range;

use egui::text::{LayoutJob, TextFormat};
use egui::{Align, CursorIcon, FontFamily, FontId, Id, Label, Sense, Stroke, Ui};
use egui_extras::syntax_highlighting::{CodeTheme, highlight};
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

use crate::style::{BODY_SIZE, LINE_HEIGHT, MONO_SIZE, Palette, bold_family};

const INDENT: f32 = 20.0;

#[derive(Default)]
struct Block {
    job: LayoutJob,
    chars: usize,
    links: Vec<(Range<usize>, String)>,
}

impl Block {
    fn push(&mut self, text: &str, fmt: TextFormat, link: Option<&str>) {
        let n = text.chars().count();
        if let Some(url) = link {
            self.links
                .push((self.chars..self.chars + n, url.to_owned()));
        }
        self.job.append(text, 0.0, fmt);
        self.chars += n;
    }
    fn is_blank(&self) -> bool {
        self.job.text.trim().is_empty()
    }
}

struct Renderer<'u> {
    ui: &'u mut Ui,
    pal: Palette,
    width: f32,
    id: Id,
    n_blocks: usize,
    cur: Block,
    bold: u32,
    italic: u32,
    strike: u32,
    link: Option<String>,
    heading: Option<HeadingLevel>,
    quote: u32,
    lists: Vec<Option<u64>>,
    marker: Option<String>,
    code: Option<(String, String)>,
    table: Option<Vec<(bool, Vec<Block>)>>,
    in_head: bool,
}

/// Render `markdown` into `ui`, wrapping at `width`. `id_salt` must be unique per message.
pub fn render(
    ui: &mut Ui,
    markdown: &str,
    id_salt: impl std::hash::Hash + std::fmt::Debug,
    pal: Palette,
    width: f32,
) {
    let id = ui.scope_id().with(id_salt);
    let mut r = Renderer {
        ui,
        pal,
        width,
        id,
        n_blocks: 0,
        cur: Block::default(),
        bold: 0,
        italic: 0,
        strike: 0,
        link: None,
        heading: None,
        quote: 0,
        lists: vec![],
        marker: None,
        code: None,
        table: None,
        in_head: false,
    };
    let opts = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for ev in Parser::new_ext(markdown, opts) {
        r.event(ev);
    }
    r.flush();
}

fn heading_size(level: HeadingLevel) -> f32 {
    match level {
        HeadingLevel::H1 => 23.0,
        HeadingLevel::H2 => 19.5,
        HeadingLevel::H3 => 17.0,
        _ => BODY_SIZE,
    }
}

impl Renderer<'_> {
    fn size(&self) -> f32 {
        self.heading.map_or(BODY_SIZE, heading_size)
    }

    fn fmt(&self) -> TextFormat {
        let size = self.size();
        let family = if self.bold > 0 || self.heading.is_some() || self.in_head {
            bold_family()
        } else {
            FontFamily::Proportional
        };
        // A link that will not open is drawn weak and struck through, so it reads as dead
        // before anyone hovers it.
        let refused = self
            .link
            .as_deref()
            .is_some_and(|u| link_target(u).is_err());
        let color = if refused {
            self.pal.weak
        } else if self.link.is_some() {
            self.pal.link
        } else if self.quote > 0 {
            self.pal.weak
        } else {
            self.pal.text
        };
        TextFormat {
            font_id: FontId::new(size, family),
            color,
            italics: self.italic > 0,
            strikethrough: if self.strike > 0 || refused {
                Stroke::new(1.0, color)
            } else {
                Stroke::NONE
            },
            underline: if self.link.is_some() {
                Stroke::new(1.0, color)
            } else {
                Stroke::NONE
            },
            line_height: Some(size * LINE_HEIGHT),
            valign: Align::Center,
            ..Default::default()
        }
    }

    fn text(&mut self, t: &str) {
        if let Some((_, code)) = &mut self.code {
            code.push_str(t);
            return;
        }
        let fmt = self.fmt();
        let link = self.link.clone();
        self.cur.push(t, fmt, link.as_deref());
    }

    fn inline_code(&mut self, t: &str) {
        let mut fmt = self.fmt();
        fmt.font_id = FontId::monospace(MONO_SIZE.max(self.size() - 2.0));
        fmt.background = self.pal.code_bg;
        let link = self.link.clone();
        self.cur.push(t, fmt, link.as_deref());
    }

    fn indent(&self) -> f32 {
        self.lists.len().saturating_sub(1) as f32 * INDENT
            + if self.lists.is_empty() { 0.0 } else { INDENT }
            + self.quote as f32 * 14.0
    }

    fn next_id(&mut self) -> Id {
        self.n_blocks += 1;
        self.id.with(self.n_blocks)
    }

    /// Render the pending run of inline text as one wrapped paragraph.
    fn flush(&mut self) {
        let block = std::mem::take(&mut self.cur);
        if block.is_blank() {
            return;
        }
        let indent = self.indent();
        let marker = self.marker.take();
        let quote = self.quote > 0;
        let (pal, width) = (self.pal, self.width);
        let resp = self.ui.horizontal_top(|ui| {
            ui.spacing_mut().item_spacing.x = 0.0;
            if indent > 0.0 {
                let pad = if marker.is_some() {
                    indent - INDENT
                } else {
                    indent
                };
                ui.add_space(pad);
            }
            if let Some(m) = &marker {
                let mut job = LayoutJob::default();
                job.append(
                    m,
                    0.0,
                    TextFormat {
                        font_id: FontId::proportional(BODY_SIZE),
                        color: pal.weak,
                        line_height: Some(BODY_SIZE * LINE_HEIGHT),
                        ..Default::default()
                    },
                );
                ui.add_sized([INDENT, BODY_SIZE * LINE_HEIGHT], Label::new(job));
            }
            paragraph(ui, block, (width - indent).max(80.0));
        });
        if quote {
            let r = resp.response.rect;
            let x = r.left() + indent - 8.0;
            self.ui
                .painter()
                .vline(x, r.y_range(), Stroke::new(3.0, pal.card_stroke));
        }
    }

    fn code_block(&mut self, lang: &str, code: &str) {
        let indent = self.indent();
        let (pal, width) = (self.pal, self.width);
        self.ui.horizontal_top(|ui| {
            ui.add_space(indent);
            egui::Frame::new()
                .fill(pal.code_bg)
                .corner_radius(6.0)
                .inner_margin(10.0)
                .show(ui, |ui| {
                    let inner = (width - indent - 20.0).max(80.0);
                    ui.set_width(inner);
                    ui.vertical(|ui| {
                        if !lang.is_empty() {
                            ui.label(egui::RichText::new(lang).small().color(pal.weak));
                        }
                        let theme = CodeTheme::from_style(ui.style());
                        let mut job =
                            highlight(ui.ctx(), ui.style(), &theme, code.trim_end(), lang);
                        job.wrap.max_width = inner;
                        ui.add(Label::new(job));
                    });
                });
        });
    }

    fn render_table(&mut self, rows: Vec<(bool, Vec<Block>)>) {
        let id = self.next_id();
        let (pal, width) = (self.pal, self.width);
        // A cell wraps only past 60% of the column, so short tables stay on one line per row.
        let cell_w = (width * 0.6).max(60.0);
        // A table wider than the column scrolls sideways inside its frame instead of running
        // past the pane's right edge; a narrow one shrinks to fit and looks unchanged.
        egui::Frame::new()
            .stroke(Stroke::new(1.0, pal.card_stroke))
            .corner_radius(6.0)
            .inner_margin(8.0)
            .show(self.ui, |ui| {
                egui::ScrollArea::horizontal()
                    .id_salt(("table-scroll", id))
                    .max_width((width - 18.0).max(0.0))
                    .auto_shrink([true, true])
                    .show(ui, |ui| {
                        egui::Grid::new(id)
                            .striped(true)
                            .spacing([16.0, 4.0])
                            .show(ui, |ui| {
                                for (_head, cells) in rows {
                                    for cell in cells {
                                        paragraph(ui, cell, cell_w);
                                    }
                                    ui.end_row();
                                }
                            });
                    });
            });
    }

    fn event(&mut self, ev: Event<'_>) {
        match ev {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(t) => self.text(&t),
            Event::Code(t) => self.inline_code(&t),
            Event::Html(t) | Event::InlineHtml(t) => self.text(&t),
            Event::SoftBreak => self.text(" "),
            Event::HardBreak => self.text("\n"),
            Event::Rule => {
                self.flush();
                self.ui.separator();
            }
            Event::TaskListMarker(done) => self.text(if done { "☑ " } else { "☐ " }),
            _ => {}
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => {}
            Tag::Heading { level, .. } => {
                self.flush();
                self.ui.add_space(6.0);
                self.heading = Some(level);
            }
            Tag::BlockQuote(_) => {
                self.flush();
                self.quote += 1;
            }
            Tag::CodeBlock(kind) => {
                self.flush();
                let lang = match kind {
                    CodeBlockKind::Fenced(l) => {
                        l.split_whitespace().next().unwrap_or("").to_owned()
                    }
                    CodeBlockKind::Indented => String::new(),
                };
                self.code = Some((lang, String::new()));
            }
            Tag::List(start) => {
                self.flush();
                self.lists.push(start);
            }
            Tag::Item => {
                self.flush();
                let m = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        let m = format!("{n}.");
                        *n += 1;
                        m
                    }
                    _ => "•".to_owned(),
                };
                self.marker = Some(m);
            }
            Tag::Emphasis => self.italic += 1,
            Tag::Strong => self.bold += 1,
            Tag::Strikethrough => self.strike += 1,
            Tag::Link { dest_url, .. } => self.link = Some(dest_url.into_string()),
            Tag::Table(_) => {
                self.flush();
                self.table = Some(vec![]);
            }
            Tag::TableHead => {
                self.in_head = true;
                if let Some(t) = &mut self.table {
                    t.push((true, vec![]));
                }
            }
            Tag::TableRow => {
                if let Some(t) = &mut self.table {
                    t.push((false, vec![]));
                }
            }
            Tag::TableCell => self.cur = Block::default(),
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => self.flush(),
            TagEnd::Heading(_) => {
                self.flush();
                self.heading = None;
            }
            TagEnd::BlockQuote(_) => {
                self.flush();
                self.quote = self.quote.saturating_sub(1);
            }
            TagEnd::CodeBlock => {
                if let Some((lang, code)) = self.code.take() {
                    self.code_block(&lang, &code);
                }
            }
            TagEnd::List(_) => {
                self.flush();
                self.lists.pop();
            }
            TagEnd::Item => self.flush(),
            TagEnd::Emphasis => self.italic = self.italic.saturating_sub(1),
            TagEnd::Strong => self.bold = self.bold.saturating_sub(1),
            TagEnd::Strikethrough => self.strike = self.strike.saturating_sub(1),
            TagEnd::Link => self.link = None,
            TagEnd::TableHead => self.in_head = false,
            TagEnd::TableCell => {
                let cell = std::mem::take(&mut self.cur);
                if let Some(row) = self.table.as_mut().and_then(|t| t.last_mut()) {
                    row.1.push(cell);
                }
            }
            TagEnd::Table => {
                if let Some(rows) = self.table.take() {
                    self.render_table(rows);
                }
            }
            _ => {}
        }
    }
}

/// Why a chat link is not opened. Chat text is what agents write, and an agent can echo
/// injected web content, so a click opens only an ordinary web page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkRefusal {
    /// `file:` on this machine.
    FileUrl,
    /// A Windows network path (`\\host\share`, `//host`, `file://host/…`): opening one can send
    /// your Windows sign-in to that host.
    NetworkPath,
    /// A drive path (`C:\…`), a relative path or a bare name: the browser would open a local file.
    LocalPath,
    /// `http:`/`https:` with no host, or with spaces or control characters in it.
    Malformed,
    /// Any scheme but http and https (`javascript:`, `data:`, `smb:`, `ms-settings:`, `mailto:` …).
    OtherScheme,
}

impl LinkRefusal {
    /// The text shown on the link when it is not opened.
    pub fn reason(self) -> &'static str {
        match self {
            LinkRefusal::FileUrl => "Not opened: it is a file on this computer.",
            LinkRefusal::NetworkPath => "Not opened: it is a network path.",
            LinkRefusal::LocalPath => "Not opened: it is a local path, not a web address.",
            LinkRefusal::Malformed => "Not opened: the web address is malformed.",
            LinkRefusal::OtherScheme => "Not opened: only http and https links open.",
        }
    }
}

/// The address to open for a chat link, or why it is not opened. Only `http://` and
/// `https://` with a host open.
///
/// Why not leave it to the browser crate: webbrowser 1.2.7 opens any scheme, and a string that
/// does not parse as a URL becomes a local file path. Checking here also covers a build where
/// its `hardened` feature is off.
pub fn link_target(url: &str) -> Result<&str, LinkRefusal> {
    let u = url.trim();
    // Windows reads `\` and `/` alike in a path, so `\\host`, `//host` and `/\host` are all
    // network paths.
    if u.replace('\\', "/").starts_with("//") {
        return Err(LinkRefusal::NetworkPath);
    }
    let Some((scheme, rest)) = u.split_once(':') else {
        return Err(LinkRefusal::LocalPath);
    };
    // A one-letter "scheme" is a drive (`C:`); anything not shaped like a scheme is a path.
    let is_scheme = scheme.len() > 1
        && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    if !is_scheme {
        return Err(LinkRefusal::LocalPath);
    }
    match scheme.to_ascii_lowercase().as_str() {
        "http" | "https" => {
            let Some(after) = rest.strip_prefix("//") else {
                return Err(LinkRefusal::Malformed);
            };
            let authority = &after[..after.find(['/', '?', '#']).unwrap_or(after.len())];
            let host = authority.rsplit('@').next().unwrap_or("");
            let bad_char = |c: char| c.is_whitespace() || c.is_control();
            if host.is_empty()
                || host.starts_with(':')
                || authority.contains('\\')
                || u.chars().any(bad_char)
            {
                return Err(LinkRefusal::Malformed);
            }
            Ok(u)
        }
        "file" => Err(file_kind(rest)),
        _ => Err(LinkRefusal::OtherScheme),
    }
}

/// `file:` URLs: a host other than `localhost` (or extra slashes before one) is a network path.
fn file_kind(rest: &str) -> LinkRefusal {
    // A URL parser reads `\` as `/` in a file URL, so `file:\\host` is `file://host`.
    let rest = rest.replace('\\', "/");
    let Some(after) = rest.strip_prefix("//") else {
        return LinkRefusal::FileUrl;
    };
    if after.starts_with("//") {
        return LinkRefusal::NetworkPath;
    }
    let host = after.split('/').next().unwrap_or("");
    if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
        LinkRefusal::FileUrl
    } else {
        LinkRefusal::NetworkPath
    }
}

/// One wrapped run of text; links inside it open on click.
fn paragraph(ui: &mut Ui, mut block: Block, width: f32) {
    block.job.wrap.max_width = width;
    let galley = ui.painter().layout_job(block.job);
    let sense = if block.links.is_empty() {
        Sense::hover()
    } else {
        Sense::click()
    };
    let resp = ui.add(
        Label::new(galley.clone())
            .sense(sense)
            .selectable(block.links.is_empty()),
    );
    if block.links.is_empty() {
        return;
    }
    let Some(pos) = resp.hover_pos() else { return };
    let idx = galley.cursor_from_pos(pos - resp.rect.min).index.0;
    if let Some((_, url)) = block.links.iter().find(|(r, _)| r.contains(&idx)) {
        match link_target(url) {
            Ok(target) => {
                ui.ctx().set_cursor_icon(CursorIcon::PointingHand);
                if resp.clicked() {
                    ui.ctx().open_url(egui::OpenUrl::new_tab(target));
                }
            }
            // Never handed to the browser; the hover text says why.
            Err(why) => {
                ui.ctx().set_cursor_icon(CursorIcon::NotAllowed);
                let _ = resp.on_hover_text(why.reason());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_ranges_count_chars_not_bytes() {
        let mut b = Block::default();
        b.push("é·", TextFormat::default(), None);
        b.push("link", TextFormat::default(), Some("u"));
        assert_eq!(b.links, vec![(2..6, "u".to_owned())]);
    }

    #[test]
    fn web_links_open() {
        for u in [
            "https://example.com/build-log",
            "http://example.com",
            "HTTPS://Example.com/a?b=c#d",
            "  https://example.com/x  ",
            "https://user@example.com:8443/p",
        ] {
            assert_eq!(link_target(u), Ok(u.trim()), "{u}");
        }
    }

    #[test]
    fn file_urls_are_refused() {
        for u in ["file:///etc/passwd", "FILE:///C:/Windows/win.ini", "file:/etc/hosts"] {
            assert_eq!(link_target(u), Err(LinkRefusal::FileUrl), "{u}");
        }
        assert_eq!(
            link_target("file://localhost/etc/passwd"),
            Err(LinkRefusal::FileUrl)
        );
    }

    #[test]
    fn network_paths_are_refused() {
        for u in [
            r"\\host\share\x",
            "//host/share/x",
            "file://///host/share/x",
            "file:////host/share/x",
            "file://host/share/x",
            r" \\10.0.0.1\c$",
            r"/\host\share",
            r"file:\\host\share",
        ] {
            assert_eq!(link_target(u), Err(LinkRefusal::NetworkPath), "{u}");
        }
    }

    #[test]
    fn local_paths_are_refused() {
        for u in [
            r"C:\Windows\System32\calc.exe",
            "c:/Users/x/a.html",
            "/etc/passwd",
            "./notes.html",
            "../up.html",
            "report.html",
            "www.example.com",
            "#section",
            "",
        ] {
            assert_eq!(link_target(u), Err(LinkRefusal::LocalPath), "{u:?}");
        }
    }

    #[test]
    fn other_schemes_are_refused() {
        for u in [
            "javascript:alert(1)",
            "data:text/html,<b>x</b>",
            "smb://host/share",
            "ms-settings:privacy",
            "mailto:a@example.com",
            "ftp://example.com/x",
            "vscode://file/etc/passwd",
            "search-ms:query=x",
        ] {
            assert_eq!(link_target(u), Err(LinkRefusal::OtherScheme), "{u}");
        }
    }

    #[test]
    fn malformed_web_links_are_refused() {
        for u in [
            "https:///etc/passwd",
            "https:",
            r"https:\\host\x",
            "http:example.com",
            "https://exa mple.com/",
            "https://example.com/\u{7}",
            "https://?x",
        ] {
            assert_eq!(link_target(u), Err(LinkRefusal::Malformed), "{u:?}");
        }
    }

    #[test]
    fn every_refusal_has_a_reason() {
        for r in [
            LinkRefusal::FileUrl,
            LinkRefusal::NetworkPath,
            LinkRefusal::LocalPath,
            LinkRefusal::Malformed,
            LinkRefusal::OtherScheme,
        ] {
            assert!(r.reason().starts_with("Not opened: "), "{r:?}");
        }
    }
}
