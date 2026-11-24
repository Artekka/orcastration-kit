//! Observatory's window: a sidebar of agents grouped by project and the selected agent's chat.
//! Renders its own view-model (`model`), fed live from the WSL bridge (`bridge`, `live`) or from
//! the built-in demo (`--demo`).

pub mod bridge;
pub mod demo;
pub mod images;
pub mod live;
pub mod markdown;
pub mod model;
pub mod pages;
pub mod prompt;
pub mod style;
pub mod view;

use egui::{CentralPanel, Frame, Margin, Panel, ScrollArea, Ui};

use bridge::{Conn, LiveSource};
use live::{Offsets, Seats};
use model::{AgentRef, ViewModel, repaint_after};
use style::Palette;

/// Where "now" comes from: the system clock, or a fixed instant (tests, demo snapshots).
#[derive(Clone, Copy, Debug)]
pub enum Clock {
    System,
    Fixed(i64),
}

impl Clock {
    pub fn now(self) -> i64 {
        match self {
            Clock::Fixed(t) => t,
            Clock::System => std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs() as i64),
        }
    }
}

pub struct ObservatoryApp {
    pub vm: ViewModel,
    pub selected: Option<AgentRef>,
    /// The project whose Visuals fill the main pane instead of the selected agent's chat.
    pub visuals: Option<usize>,
    pub show_thinking: bool,
    pub clock: Clock,
    /// The live feed; `None` for the demo and fixed test models.
    pub live: Option<Live>,
    /// Last frame's chat viewport (the chat scroll area's clip rect); read by the resize tests.
    pub chat_viewport: Option<egui::Rect>,
    /// Chat thumbnails and the enlarged image (pixels only; the model holds references).
    pub images: images::ImageCache,
    /// The pages panel: open or closed, selected agent or whole project.
    pub pages: pages::PanelState,
    /// The prompt box under the chat: drafts and the send in flight.
    pub prompt: prompt::PromptState,
}

/// The live feed and how to map it.
pub struct Live {
    pub source: LiveSource,
    pub seats: Seats,
    pub offsets: Offsets,
}

impl ObservatoryApp {
    pub fn new(vm: ViewModel, clock: Clock) -> Self {
        let selected = vm.first();
        Self {
            vm,
            selected,
            visuals: None,
            show_thinking: false,
            clock,
            live: None,
            chat_viewport: None,
            images: images::ImageCache::default(),
            pages: pages::PanelState::default(),
            prompt: prompt::PromptState::default(),
        }
    }

    /// Live data from `source`, mapped with `seats` and local times from `offsets`.
    pub fn live(source: LiveSource, seats: Seats, offsets: Offsets, clock: Clock) -> Self {
        let mut app = Self::new(ViewModel::default(), clock);
        app.live = Some(Live {
            source,
            seats,
            offsets,
        });
        app
    }

    /// Pull a new model from the live feed if it moved; keep the selected agent by name.
    fn sync(&mut self, now: i64) {
        let Some(live) = &mut self.live else { return };
        let Some(vm) = live.source.take_model(&live.seats, now, live.offsets) else {
            return;
        };
        let keep = self
            .selected
            .and_then(|r| self.vm.get(r))
            .map(|(p, a)| (p.name.clone(), a.name.clone()));
        let keep_visuals = self
            .visuals
            .and_then(|i| self.vm.projects.get(i))
            .map(|p| p.name.clone());
        self.vm = vm;
        self.visuals = keep_visuals.and_then(|n| {
            self.vm
                .projects
                .iter()
                .position(|p| p.name == n && p.gallery.is_some())
        });
        self.selected = keep.and_then(|(pn, an)| {
            self.vm.projects.iter().enumerate().find_map(|(pi, p)| {
                (p.name == pn).then(|| {
                    p.agents
                        .iter()
                        .position(|a| a.name == an)
                        .map(|ai| AgentRef {
                            project: pi,
                            agent: ai,
                        })
                })?
            })
        });
    }

    /// The live connection's banner text and whether it offers Retry.
    pub fn banner(&self) -> Option<(String, bool)> {
        let live = self.live.as_ref()?;
        match live.source.conn() {
            Conn::Live => None,
            Conn::Connecting => Some((
                format!(
                    "Connecting to the bridge: {}…",
                    live.source.launch.describe()
                ),
                false,
            )),
            Conn::Failed(why) => Some((format!("No live data. {why}"), true)),
        }
    }

    /// The built-in demo, frozen at the demo's own "now".
    pub fn demo() -> Self {
        Self::new(demo::demo(), Clock::Fixed(demo::DEMO_NOW))
    }

    /// Fonts and text styles. Call once per context.
    pub fn install(ctx: &egui::Context) {
        style::install(ctx);
    }

    pub fn ui(&mut self, ui: &mut Ui) {
        let pal = Palette::for_theme(ui.ctx().theme());
        let now = self.clock.now();
        self.sync(now);
        self.images.begin_frame(ui.ctx());
        if let Some((text, retry)) = self.banner() {
            let mut clicked = false;
            Panel::top("bridge-banner")
                .frame(Frame::side_top_panel(ui.style()).inner_margin(Margin::symmetric(14, 0)))
                .show(ui, |ui| {
                    clicked = view::bridge_banner(ui, &text, retry, pal)
                });
            if clicked && let Some(live) = &mut self.live {
                live.source.retry();
            }
        }
        if self.selected.and_then(|r| self.vm.get(r)).is_none() {
            self.selected = self.vm.first();
        }
        if self
            .visuals
            .is_some_and(|i| self.vm.projects.get(i).is_none_or(|p| p.gallery.is_none()))
        {
            self.visuals = None;
        }

        Panel::left("sidebar")
            .resizable(false)
            .exact_size(250.0)
            .frame(Frame::side_top_panel(ui.style()).inner_margin(Margin::symmetric(10, 6)))
            .show(ui, |ui| {
                ScrollArea::vertical().show(ui, |ui| {
                    let sel = view::Selection {
                        agent: &mut self.selected,
                        visuals: &mut self.visuals,
                    };
                    view::sidebar(ui, &self.vm, sel, now, pal);
                });
            });

        if let Some(pi) = self.visuals {
            let project = &self.vm.projects[pi];
            let gallery = project
                .gallery
                .as_ref()
                .expect("visuals was validated above");
            CentralPanel::default()
                .frame(Frame::central_panel(ui.style()).inner_margin(Margin::symmetric(18, 0)))
                .show(ui, |ui| {
                    Panel::top("visuals-header")
                        .show(ui, |ui| view::visuals_header(ui, project, gallery, pal));
                    CentralPanel::default().frame(Frame::NONE).show(ui, |ui| {
                        ui.add_space(10.0);
                        view::visuals(ui, project, gallery, now, &mut self.images, pal);
                    });
                });
            view::image_viewer(ui.ctx(), &mut self.images, pal);
            ui.ctx()
                .request_repaint_after(repaint_after(&self.vm, None));
            return;
        }

        let Some(sel) = self.selected else {
            CentralPanel::default().show(ui, |ui| {
                let msg = match self.live.as_ref().map(|l| l.source.conn()) {
                    Some(Conn::Connecting) => "Waiting for the bridge…",
                    _ => "No agents running.",
                };
                ui.centered_and_justified(|ui| ui.label(msg));
            });
            return;
        };
        let (project, agent) = self.vm.get(sel).expect("selected was validated above");
        pages::panel(ui, project, agent, &mut self.pages, now, pal);

        CentralPanel::default()
            .frame(Frame::central_panel(ui.style()).inner_margin(Margin::symmetric(18, 0)))
            .show(ui, |ui| {
                Panel::top("header").show(ui, |ui| {
                    view::header(
                        ui,
                        project,
                        agent,
                        view::HeaderState {
                            show_thinking: &mut self.show_thinking,
                        },
                        pal,
                    );
                });
                Panel::bottom("footer").frame(Frame::NONE).show(ui, |ui| {
                    pages::chip(ui, agent, &mut self.pages, pal);
                    let live = self.live.as_ref().map(|l| &l.source);
                    prompt::prompt_box(ui, project, agent, &mut self.prompt, live, pal);
                });
                CentralPanel::default().frame(Frame::NONE).show(ui, |ui| {
                    let out = ScrollArea::vertical()
                        .id_salt(("chat", sel.project, sel.agent))
                        .stick_to_bottom(true)
                        .auto_shrink(false)
                        .show(ui, |ui| {
                            let opts = view::ChatOpts {
                                show_thinking: self.show_thinking,
                                now,
                                key: sel,
                            };
                            view::chat(ui, agent, &opts, &mut self.images, pal);
                        });
                    self.chat_viewport = Some(out.inner_rect);
                });
            });

        view::image_viewer(ui.ctx(), &mut self.images, pal);
        ui.ctx()
            .request_repaint_after(repaint_after(&self.vm, self.selected));
    }
}

impl eframe::App for ObservatoryApp {
    fn ui(&mut self, ui: &mut Ui, _frame: &mut eframe::Frame) {
        ObservatoryApp::ui(self, ui);
    }
}
