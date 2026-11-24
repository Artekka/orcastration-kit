//! Memory probe (Linux only; evidence, not a test). Feeds a saved `observatory-bridge --once`
//! output into the app's live state, then loads every chat thumbnail the way the window does
//! (read-only, downscaled, LRU-capped), opens the largest image enlarged and closes it, printing
//! the process RSS after each step.
//!
//!     cargo run --release -p observatory-app --example rss_probe -- <frames.jsonl>

use observatory_app::images::{ImageCache, Slot};
use observatory_app::live::{LiveState, Seats, utc_offset};
use observatory_app::model::{ChatItem, Image};

fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1)?.parse().ok())
        })
        .unwrap_or(0)
}

fn report(step: &str) {
    println!("{step:<44} RSS {:>8} KB", rss_kb());
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: rss_probe <frames.jsonl>");
    report("start");
    let text = std::fs::read_to_string(&path).expect("read frames");
    let mut state = LiveState::default();
    for l in text.lines() {
        state.apply_line(l);
    }
    drop(text);
    let vm = state.view_model(&Seats::default(), 0, utc_offset);
    let images: Vec<Image> = vm
        .projects
        .iter()
        .flat_map(|p| &p.agents)
        .flat_map(|a| &a.items)
        .flat_map(|i| match i {
            ChatItem::User { images, .. } | ChatItem::ToolCall { images, .. } => images.clone(),
            _ => Vec::new(),
        })
        .collect();
    report(&format!("live model held ({} image refs)", images.len()));

    let ctx = egui::Context::default();
    let mut cache = ImageCache::inline();
    let (mut ok, mut failed) = (0, 0);
    let mut loaded: Vec<Image> = Vec::new();
    for batch in images.chunks(25) {
        // One frame per batch, like scrolling: textures are uploaded and deltas consumed.
        let _ = ctx.run_ui(egui::RawInput::default(), |ui| {
            cache.begin_frame(ui.ctx());
            for img in batch {
                match cache.thumb(ui.ctx(), &img.src) {
                    Slot::Ready(_) => {
                        ok += 1;
                        if !loaded.iter().any(|l| l.src == img.src) {
                            loaded.push(img.clone());
                        }
                    }
                    Slot::Failed(_) => failed += 1,
                    Slot::Pending => {}
                }
            }
        });
    }
    let (held, _) = cache.resident();
    report(&format!(
        "every thumbnail loaded ({ok} ok, {failed} unavailable, {held} held)"
    ));

    // The biggest image by full size, among the loaded ones (each try replaces the last).
    let mut biggest: Option<(usize, Image)> = None;
    for img in loaded.iter().take(300) {
        let _ = ctx.run_ui(egui::RawInput::default(), |ui| {
            if let Slot::Ready(t) = cache.full(ui.ctx(), &img.src) {
                let px = t.size()[0] * t.size()[1];
                if biggest.as_ref().is_none_or(|(n, _)| px > *n) {
                    biggest = Some((px, img.clone()));
                }
            }
        });
    }
    cache.close();
    let _ = ctx.run_ui(egui::RawInput::default(), |ui| cache.begin_frame(ui.ctx()));
    report("after trying 300 full-size decodes, closed");
    if let Some((_, img)) = biggest {
        let _ = ctx.run_ui(egui::RawInput::default(), |ui| {
            cache.open = Some(img.clone());
            if let Slot::Ready(t) = cache.full(ui.ctx(), &img.src) {
                println!("  enlarged {} at {:?}", img.name, t.size());
            }
        });
        report("largest image enlarged");
        cache.close();
        for _ in 0..2 {
            let _ = ctx.run_ui(egui::RawInput::default(), |ui| cache.begin_frame(ui.ctx()));
        }
        report("enlarged view closed");
    }
}
