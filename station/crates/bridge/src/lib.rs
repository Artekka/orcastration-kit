//! observatory-bridge: runs inside WSL, follows Claude Code session logs for the configured
//! projects and writes `observatory_core::wire::Frame` JSON lines on stdout for the Windows app.
//!
//! Read-only by construction: all filesystem access goes through [`fsro`] (see its doc and
//! `tests/read_only.rs`). Parsing is all `observatory_core`; this crate only finds, tails and
//! sends. Startup and update rules: [`bridge`]. Config path and format: [`config`]. Liveness:
//! [`liveness`]. Project image galleries: [`gallery`].

pub mod bridge;
pub mod config;
pub mod discover;
pub mod fsro;
pub mod gallery;
pub mod liveness;
pub mod run;
pub mod screen;
pub mod tail;
pub mod tmux;
