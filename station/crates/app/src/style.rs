//! Fonts, text sizes and the colour palette for both themes.

use std::sync::Arc;

use egui::{Color32, FontData, FontDefinitions, FontFamily, FontId, TextStyle, Theme};

pub const BODY_SIZE: f32 = 15.0;
pub const MONO_SIZE: f32 = 13.0;
/// Line height as a multiple of the font size ("generous").
pub const LINE_HEIGHT: f32 = 1.55;
/// Widest text column, in average characters; narrower panes get a column that fills them.
pub const COLUMN_CHARS: f32 = 100.0;

/// The semibold family, used for headings, bold text and names.
pub fn bold_family() -> FontFamily {
    FontFamily::Name("bold".into())
}

/// Bundled open-licensed fonts (licences next to them in assets/fonts) first; egui's defaults
/// stay as fallbacks so emoji and symbols in logs still render.
pub fn fonts() -> FontDefinitions {
    let mut defs = FontDefinitions::default();
    let add = |defs: &mut FontDefinitions, name: &str, bytes: &'static [u8]| {
        defs.font_data
            .insert(name.into(), Arc::new(FontData::from_static(bytes)));
    };
    add(
        &mut defs,
        "Inter",
        include_bytes!("../assets/fonts/Inter-Regular.ttf"),
    );
    add(
        &mut defs,
        "Inter-SemiBold",
        include_bytes!("../assets/fonts/Inter-SemiBold.ttf"),
    );
    add(
        &mut defs,
        "JetBrainsMono",
        include_bytes!("../assets/fonts/JetBrainsMono-Regular.ttf"),
    );
    let fallbacks = defs.families[&FontFamily::Proportional].clone();
    defs.families
        .get_mut(&FontFamily::Proportional)
        .expect("egui always defines Proportional")
        .insert(0, "Inter".into());
    defs.families
        .get_mut(&FontFamily::Monospace)
        .expect("egui always defines Monospace")
        .insert(0, "JetBrainsMono".into());
    let mut bold = vec!["Inter-SemiBold".to_string()];
    bold.extend(fallbacks);
    defs.families.insert(bold_family(), bold);
    defs
}

/// Install fonts and text sizes on a context (both themes).
pub fn install(ctx: &egui::Context) {
    ctx.set_fonts(fonts());
    ctx.all_styles_mut(|s| {
        s.text_styles = [
            (TextStyle::Small, FontId::proportional(12.0)),
            (TextStyle::Body, FontId::proportional(BODY_SIZE)),
            (TextStyle::Button, FontId::proportional(14.0)),
            (TextStyle::Heading, FontId::new(20.0, bold_family())),
            (TextStyle::Monospace, FontId::monospace(MONO_SIZE)),
        ]
        .into();
        s.spacing.item_spacing.y = 6.0;
    });
}

/// Colours the chat needs beyond egui's own visuals.
#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub text: Color32,
    pub weak: Color32,
    pub bubble: Color32,
    pub card: Color32,
    pub card_stroke: Color32,
    pub code_bg: Color32,
    pub link: Color32,
    pub error: Color32,
    pub sidebar_selected: Color32,
    pub sidebar_hover: Color32,
}

impl Palette {
    pub fn for_theme(theme: Theme) -> Self {
        match theme {
            Theme::Dark => Self {
                text: Color32::from_rgb(0xdc, 0xdf, 0xe4),
                weak: Color32::from_rgb(0x8b, 0x91, 0x9a),
                bubble: Color32::from_rgb(0x2b, 0x3a, 0x55),
                card: Color32::from_rgb(0x24, 0x27, 0x2e),
                card_stroke: Color32::from_rgb(0x3d, 0x43, 0x4d),
                code_bg: Color32::from_rgb(0x1a, 0x1c, 0x21),
                link: Color32::from_rgb(0x6c, 0xb6, 0xff),
                error: Color32::from_rgb(0xf0, 0x71, 0x78),
                sidebar_selected: Color32::from_rgb(0x2f, 0x34, 0x3d),
                sidebar_hover: Color32::from_rgb(0x28, 0x2c, 0x33),
            },
            Theme::Light => Self {
                text: Color32::from_rgb(0x1f, 0x23, 0x28),
                weak: Color32::from_rgb(0x65, 0x6d, 0x76),
                bubble: Color32::from_rgb(0xdd, 0xe8, 0xfa),
                card: Color32::from_rgb(0xf3, 0xf4, 0xf6),
                card_stroke: Color32::from_rgb(0xd0, 0xd7, 0xde),
                code_bg: Color32::from_rgb(0xf0, 0xf2, 0xf5),
                link: Color32::from_rgb(0x09, 0x69, 0xda),
                error: Color32::from_rgb(0xcf, 0x22, 0x2e),
                sidebar_selected: Color32::from_rgb(0xe3, 0xe7, 0xec),
                sidebar_hover: Color32::from_rgb(0xee, 0xf0, 0xf3),
            },
        }
    }
}

/// Status-dot colour. `Gone` is a muted grey: dimmed, never error-red.
pub fn status_color(status: crate::model::Status, theme: Theme) -> Color32 {
    use crate::model::Status::*;
    match (status, theme) {
        (Working, _) => Color32::from_rgb(0x3f, 0xb9, 0x50),
        (Idle, Theme::Dark) => Color32::from_rgb(0x6e, 0x8f, 0xb8),
        (Idle, Theme::Light) => Color32::from_rgb(0x54, 0x77, 0xa6),
        (NeedsYou, _) => Color32::from_rgb(0xe3, 0xa0, 0x08),
        (Gone, Theme::Dark) => Color32::from_rgb(0x55, 0x5a, 0x62),
        (Gone, Theme::Light) => Color32::from_rgb(0xb0, 0xb6, 0xbd),
    }
}
