//! `observatory-bridge [--once] [--config <path>] [--claude-dir <dir>] [--cutoff-days <n>]`
//!
//! Writes wire frames (JSON lines) on stdout, diagnostics on stderr. `--once` prints the startup
//! frames and exits. `--claude-dir` defaults to `~/.claude`. Config: see `config` module doc.

use std::io::{self, BufWriter};
use std::path::PathBuf;
use std::process::ExitCode;

use observatory_bridge::bridge::Bridge;
use observatory_bridge::{config, run};

const USAGE: &str =
    "usage: observatory-bridge [--once] [--config <path>] [--claude-dir <dir>] [--cutoff-days <n>]";

fn main() -> ExitCode {
    let mut once = false;
    let mut cfg_path: Option<PathBuf> = None;
    let mut claude_dir: Option<PathBuf> = None;
    let mut cutoff: Option<u64> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut val = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        let r: Result<(), String> = match a.as_str() {
            "--once" => {
                once = true;
                Ok(())
            }
            "--config" => val("--config").map(|v| cfg_path = Some(v.into())),
            "--claude-dir" => val("--claude-dir").map(|v| claude_dir = Some(v.into())),
            "--cutoff-days" => val("--cutoff-days").and_then(|v| {
                v.parse()
                    .map(|n| cutoff = Some(n))
                    .map_err(|_| format!("--cutoff-days: not a number: {v}"))
            }),
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            other => Err(format!("unknown argument {other}")),
        };
        if let Err(e) = r {
            eprintln!("observatory-bridge: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let cfg_path = cfg_path.or_else(|| config::default_path(|k| std::env::var(k).ok()));
    let (mut cfg, warning) = config::load(cfg_path.as_deref(), &home);
    if let Some(w) = warning {
        eprintln!("observatory-bridge: {w}");
    }
    if let Some(n) = cutoff {
        cfg.cutoff_days = n;
    }
    let claude_dir = claude_dir.unwrap_or_else(|| PathBuf::from(&home).join(".claude"));
    let out = BufWriter::with_capacity(1 << 16, io::stdout().lock());
    let mut bridge = Bridge::new(cfg, claude_dir, out);
    match run::run(&mut bridge, once) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) if run::is_closed(&e) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("observatory-bridge: {e}");
            ExitCode::FAILURE
        }
    }
}
