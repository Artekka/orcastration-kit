//! Observatory core: Claude Code session logs → a UI-free chat model. No UI, no file watching,
//! and no writes anywhere: callers hand it lines they read.
//!
//! Pipeline: bytes → [`lines::LineBuffer`] (complete lines only) → [`record::parse_line`] (one
//! typed record, never a panic) → [`session::Session`] (chat items, identity, status) →
//! [`thread::build_threads`] (one thread per project + agent, restart dividers) →
//! [`wire::Frame`] (JSON lines from the bridge to the app). Projects are configured, never
//! hard-coded: see [`project`].

pub mod lines;
pub mod pages;
pub mod project;
pub mod record;
pub mod session;
pub mod thread;
pub mod time;
pub mod wire;

pub use pages::Page;
pub use project::{ProjectSpec, project_for_slug, slugify};
pub use session::{Activity, ChatItem, ImageRef, ItemKind, Liveness, NoticeKind, Session, Status};
pub use thread::{Thread, ThreadEntry, ThreadKey, build_threads};
pub use wire::{Frame, Request, SendResult};
