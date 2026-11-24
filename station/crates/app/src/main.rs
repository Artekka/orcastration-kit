// No console window behind the app on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! `observatory [--demo] [--bridge <path>] [--seats <A,B,…>]`
//!
//! Default: live data from the WSL bridge. `--demo`: the built-in demo (no bridge).
//! `--bridge`: the bridge's path (inside WSL on Windows), used as given: write it absolute,
//! since `~` is NOT expanded (`--bridge ~/x` looks for a file literally named `~/x`). `--seats` (or env
//! `OBSERVATORY_SEATS`): which agent names are seats. Without either, the bridge config's `seats`
//! are used, else the kit's default seat name (`Orca`).

use std::sync::Arc;

use observatory_app::bridge::{Launch, LiveSource};
use observatory_app::live::{Seats, local_offset};
use observatory_app::{Clock, ObservatoryApp};

struct Args {
    demo: bool,
    bridge: Option<String>,
    seats: Seats,
}

fn parse_args() -> Args {
    let mut a = Args {
        demo: false,
        bridge: None,
        seats: std::env::var("OBSERVATORY_SEATS")
            .map(|v| Seats::parse(&v))
            .unwrap_or_default(),
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--demo" => a.demo = true,
            "--bridge" => a.bridge = it.next(),
            "--seats" => {
                if let Some(v) = it.next() {
                    a.seats = Seats::parse(&v);
                }
            }
            _ => {} // unknown flags are ignored: a GUI app has nowhere to print usage
        }
    }
    a
}

fn main() -> eframe::Result {
    let args = parse_args();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Observatory")
            .with_inner_size([1180.0, 800.0])
            .with_min_inner_size([720.0, 480.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Observatory",
        options,
        Box::new(move |cc| {
            ObservatoryApp::install(&cc.egui_ctx);
            if args.demo {
                return Ok(Box::new(ObservatoryApp::demo()));
            }
            let ctx = cc.egui_ctx.clone();
            let source = LiveSource::start(
                Launch::for_platform(args.bridge),
                Arc::new(move || ctx.request_repaint()),
            );
            Ok(Box::new(ObservatoryApp::live(
                source,
                args.seats,
                local_offset,
                Clock::System,
            )))
        }),
    )
}
