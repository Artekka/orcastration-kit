//! The prompt box under the chat: the human types to the selected agent.
//!
//! - Enter sends, Shift+Enter is a new line; the button says "Send to <Agent>".
//! - Disabled, with a one-line reason, when there is nothing safe to send to: the demo, no
//!   bridge connection, no live session, not in tmux ([`availability`]).
//! - A send goes out ONLY from the human's Enter or click, at most one per frame and none while
//!   an earlier one waits for its answer. Nothing sends on startup, reconnect, replay or focus.
//! - The draft clears only on "sent"; "refused" keeps it and shows the reason; "uncertain"
//!   (something changed after the paste began) keeps it and says to check the agent first. A busy agent
//!   shows "working — your message will be queued" before sending.
//!
//! Drafts live in memory only (per project + agent), so an app restart starts empty.

use std::collections::HashMap;

use egui::{
    Event, Frame, Key, KeyboardShortcut, Margin, Modifiers, RichText, Stroke, TextEdit, Ui,
};
use observatory_core::wire::{SendResult, send_text_problem};

use crate::bridge::{Conn, LiveSource, Reply, Sent};
use crate::model::{Agent, Project, Status, Target};
use crate::style::Palette;

/// Why the box is off with no bridge at all (the demo, fixed test models).
pub const DEMO_NOTE: &str = "Demo data: typing is off.";
/// Shown under the box while the agent is mid-turn.
pub const BUSY_NOTE: &str = "working — your message will be queued";
/// Shown while a send waits for the bridge's answer.
pub const SENDING_NOTE: &str = "Sending…";
/// Shown when the text may already sit, unsent, in the agent's input box.
pub const UNCERTAIN_NOTE: &str =
    "Uncertain: the text may be in the agent's box. Check it before sending again.";
/// Shown when the connection a send went to ended before it answered.
pub const LOST_NOTE: &str =
    "The bridge restarted before it answered; check the agent before sending again.";

/// (project, agent): whose draft.
type Key2 = (String, String);

/// What the box remembers between frames.
#[derive(Debug, Default)]
pub struct PromptState {
    drafts: HashMap<Key2, String>,
    /// The one send waiting for its answer.
    pending: Option<(Key2, Sent)>,
    /// Last outcome to show under a box (a refusal or a lost answer).
    notes: HashMap<Key2, String>,
    /// Sends written so far (tests pin "at most one").
    pub sends: u64,
    /// The note drawn last frame: a different one changes the footer's height.
    shown: Option<String>,
}

impl PromptState {
    pub fn draft(&self, project: &str, agent: &str) -> &str {
        self.drafts
            .get(&(project.to_owned(), agent.to_owned()))
            .map_or("", String::as_str)
    }

    pub fn set_draft(&mut self, project: &str, agent: &str, text: &str) {
        self.drafts
            .insert((project.to_owned(), agent.to_owned()), text.to_owned());
    }

    pub fn note(&self, project: &str, agent: &str) -> Option<&str> {
        self.notes
            .get(&(project.to_owned(), agent.to_owned()))
            .map(String::as_str)
    }

    pub fn is_pending(&self) -> bool {
        self.pending.is_some()
    }

    /// Take the pending send's answer, if it came.
    fn poll(&mut self, live: Option<&LiveSource>) {
        let Some((key, sent)) = self.pending.clone() else {
            return;
        };
        let reply = live.map_or(Reply::Lost, |l| l.reply(sent));
        match reply {
            Reply::Waiting => {}
            Reply::Answered(SendResult::Sent) => {
                self.pending = None;
                self.drafts.remove(&key);
                self.notes.remove(&key);
            }
            Reply::Answered(SendResult::Refused { reason }) => {
                self.pending = None;
                self.notes.insert(key, reason);
            }
            Reply::Answered(SendResult::Uncertain { reason }) => {
                self.pending = None;
                self.notes
                    .insert(key, format!("{UNCERTAIN_NOTE} ({reason})"));
            }
            Reply::Lost => {
                self.pending = None;
                self.notes.insert(key, LOST_NOTE.into());
            }
        }
    }
}

/// The live session to send to, or why the box is off.
pub fn availability(conn: Option<&Conn>, agent: &Agent) -> Result<String, String> {
    let Some(conn) = conn else {
        return Err(DEMO_NOTE.into());
    };
    if *conn != Conn::Live {
        return Err("Not connected to the bridge.".into());
    }
    match (&agent.target, agent.status) {
        (_, Status::Gone) | (Target::NoLiveSession, _) => {
            Err(format!("{} has no live session.", agent.name))
        }
        (_, Status::NeedsYou) => Err(format!(
            "{} is waiting for you in its terminal. Answer it there; typing here would answer it.",
            agent.name
        )),
        (Target::NotInTmux, _) => Err(format!(
            "{} isn't running in tmux, so it can't be typed to from here.",
            agent.name
        )),
        (Target::Tmux { session_id }, _) => Ok(session_id.clone()),
    }
}

pub fn send_label(agent: &Agent) -> String {
    format!("Send to {}", agent.name)
}

/// Remove plain Enter presses (no modifiers at all) from this frame's input; true if any.
/// Shift+Enter stays for the text box, which inserts the new line.
fn take_plain_enter(ui: &Ui) -> bool {
    ui.input_mut(|i| {
        let before = i.events.len();
        i.events.retain(|e| {
            !matches!(
                e,
                Event::Key {
                    key: Key::Enter,
                    pressed: true,
                    modifiers,
                    ..
                } if modifiers.is_none()
            )
        });
        i.events.len() != before
    })
}

/// The box, its button and its one-line note.
pub fn prompt_box(
    ui: &mut Ui,
    project: &Project,
    agent: &Agent,
    st: &mut PromptState,
    live: Option<&LiveSource>,
    pal: Palette,
) {
    st.poll(live);
    let key: Key2 = (project.name.clone(), agent.name.clone());
    let avail = availability(live.map(LiveSource::conn).as_ref(), agent);
    let pending_here = st.pending.as_ref().is_some_and(|(k, _)| *k == key);
    let can_send = avail.is_ok() && st.pending.is_none();
    let edit_id = egui::Id::unique(("prompt", &key));
    // Enter is taken BEFORE the text box runs, and only while it has focus.
    let enter = can_send && ui.memory(|m| m.has_focus(edit_id)) && take_plain_enter(ui);

    ui.add_space(8.0);
    let mut clicked = false;
    Frame::new()
        .fill(pal.card)
        .stroke(Stroke::new(1.0, pal.card_stroke))
        .corner_radius(8.0)
        .inner_margin(Margin::symmetric(12, 8))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            let draft = st.drafts.entry(key.clone()).or_default();
            ui.add_enabled_ui(avail.is_ok() && !pending_here, |ui| {
                ui.add(
                    TextEdit::multiline(draft)
                        .id(edit_id)
                        .desired_rows(2)
                        .desired_width(f32::INFINITY)
                        .hint_text(format!("Message {}…", agent.name))
                        .return_key(KeyboardShortcut::new(Modifiers::SHIFT, Key::Enter)),
                );
            });
            ui.horizontal(|ui| {
                let note = match &avail {
                    Err(why) => Some((why.clone(), pal.weak)),
                    Ok(_) if st.pending.is_some() => Some((SENDING_NOTE.into(), pal.weak)),
                    Ok(_) => match st.notes.get(&key) {
                        Some(n) => Some((n.clone(), pal.error)),
                        None => {
                            (agent.status == Status::Working).then(|| (BUSY_NOTE.into(), pal.weak))
                        }
                    },
                };
                let now_shown = note.as_ref().map(|(t, _)| t.clone());
                if now_shown != st.shown {
                    // The footer panel sizes itself from the previous frame; redo this frame's
                    // layout now, or a wrapped note stays clipped until the next repaint.
                    st.shown = now_shown;
                    ui.ctx().request_discard("prompt note changed");
                }
                if let Some((text, color)) = note {
                    // Wraps within the row, leaving the button its room: a plain label in a
                    // horizontal row never wraps and would push the button off the pane.
                    let w = (ui.available_width() - 160.0).max(120.0);
                    let col = egui::Layout::top_down(egui::Align::Min);
                    ui.allocate_ui_with_layout(egui::vec2(w, 0.0), col, |ui| {
                        ui.set_max_width(w);
                        ui.add(
                            egui::Label::new(RichText::new(text).size(13.0).color(color)).wrap(),
                        );
                    });
                }
                // A one-row strip: a bare right_to_left here would claim the panel's height.
                let w = ui.available_width();
                let layout = egui::Layout::right_to_left(egui::Align::Center);
                ui.allocate_ui_with_layout(egui::vec2(w, 24.0), layout, |ui| {
                    clicked = ui
                        .add_enabled(can_send, egui::Button::new(send_label(agent)))
                        .clicked();
                });
            });
        });
    ui.add_space(8.0);

    // One submit per frame at most, whatever arrived (a click and an Enter together count once).
    if !(enter || clicked) || !can_send {
        return;
    }
    let Ok(session_id) = avail else { return };
    let text = st.draft(&key.0, &key.1).to_owned();
    if let Some(why) = send_text_problem(&text) {
        st.notes.insert(key, why);
        return;
    }
    let Some(live) = live else { return };
    match live.send(&session_id, &text) {
        Ok(sent) => {
            st.sends += 1;
            st.notes.remove(&key);
            st.pending = Some((key, sent));
        }
        Err(why) => {
            st.notes.insert(key, why);
        }
    }
}
