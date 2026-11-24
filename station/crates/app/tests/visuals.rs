//! A project's "Visuals" — the sidebar entry, the newest-first grid, lazy thumbnails,
//! local paging ("Show older"), the enlarged view, and the bridge's `Gallery` frame mapping.
//! Image files are generated into cargo's target tmp dir; the names SHOWN are fixed strings,
//! so snapshots do not depend on the tree.

use std::path::PathBuf;

use egui::{Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use observatory_app::images::ImageCache;
use observatory_app::live::{LiveState, Seats, map_gallery, utc_offset};
use observatory_app::model::{
    Agent, Gallery, GalleryImage, Image, ImageSrc, Project, Role, Status, ViewModel,
};
use observatory_app::view::{self, VISUALS_PAGE};
use observatory_app::{Clock, ObservatoryApp};
use observatory_core::Frame;
use observatory_core::wire::{GALLERY_MAX, GalleryItem};

const NOW: i64 = 1_795_000_000;

fn dir() -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("v1-8-visuals");
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A w×h gradient saved as `name` (written aside, then renamed: tests run in parallel).
fn picture(name: &str, w: u32, h: u32, tint: [u8; 3]) -> String {
    let p = dir().join(name);
    let img = image::RgbImage::from_fn(w, h, |x, y| {
        image::Rgb([
            (tint[0] as u32 * x / w.max(1)) as u8,
            (tint[1] as u32 * y / h.max(1)) as u8,
            tint[2],
        ])
    });
    let tmp = dir().join(format!("tmp-{:?}-{name}", std::thread::current().id()));
    img.save(&tmp).unwrap();
    std::fs::rename(&tmp, &p).unwrap();
    p.to_string_lossy().into_owned()
}

/// A tile reading `real`, shown as `shown_folder/name`, modified `ago` seconds before NOW.
fn tile(real: &str, shown_folder: &str, name: &str, ago: i64) -> GalleryImage {
    let path = format!("{shown_folder}/{name}");
    GalleryImage {
        image: Image {
            src: ImageSrc::File(real.into()),
            name: name.into(),
            path: Some(path),
            hide_if_missing: false,
        },
        folder: shown_folder.into(),
        modified: NOW - ago,
        size: 1234,
    }
}

fn agent(name: &str) -> Agent {
    Agent {
        name: name.into(),
        role: Role::Seat,
        status: Status::Idle,
        last_activity: Some(NOW - 60),
        model: None,
        permission_mode: None,
        turn_started: None,
        items: vec![],
        pages: vec![],
        target: Default::default(),
    }
}

/// Two projects: "art" has a gallery, "plain" has none.
fn model(gallery: Gallery) -> ViewModel {
    ViewModel {
        projects: vec![
            Project {
                name: "art".into(),
                agents: vec![agent("Painter")],
                gallery: Some(gallery),
            },
            Project {
                name: "plain".into(),
                agents: vec![agent("Coder")],
                gallery: None,
            },
        ],
        note: None,
    }
}

/// `n` tiles that all point at files that do not exist (cheap: nothing to decode).
fn missing(n: usize) -> Gallery {
    Gallery {
        total: n as u32,
        items: (0..n)
            .map(|i| {
                tile(
                    &format!("/nonexistent/v1-8/{i}.png"),
                    "/home/user/shots",
                    &format!("{i}.png"),
                    i as i64,
                )
            })
            .collect(),
    }
}

fn harness_for(vm: ViewModel, size: [f32; 2]) -> Harness<'static, ObservatoryApp> {
    let mut app = ObservatoryApp::new(vm, Clock::Fixed(NOW));
    app.images = ImageCache::inline();
    let mut h = Harness::builder()
        .with_size(vec2(size[0], size[1]))
        .with_theme(Theme::Dark)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    h
}

fn open_visuals(h: &mut Harness<'_, ObservatoryApp>, label: &str) {
    h.get_by_label(label).click();
    h.run();
}

fn count(h: &Harness<'_, ObservatoryApp>, label: &str) -> usize {
    h.query_all_by_label_contains(label).count()
}

/// Twelve real images (different sizes and tints), newest first, plus one missing file.
fn art() -> Gallery {
    let mut items: Vec<GalleryImage> = (0..12)
        .map(|i| {
            let (w, h) = [(320, 200), (200, 300), (900, 300), (64, 64)][i % 4];
            let tint = [
                (40 * i as u32 % 255) as u8,
                180,
                (255 - 20 * i as u32) as u8,
            ];
            let real = picture(&format!("art{i}.png"), w, h, tint);
            tile(
                &real,
                "/home/user/replay-viewer-shots/s1-4/shots",
                &format!("frame-{i:03}.png"),
                [5, 90, 4000, 90_000][i % 4] + i as i64,
            )
        })
        .collect();
    items.insert(
        3,
        tile(
            "/nonexistent/v1-8/gone.png",
            "/home/user/replay-viewer-shots/s1-4/shots",
            "gone.png",
            300,
        ),
    );
    Gallery {
        total: items.len() as u32,
        items,
    }
}

// ------------------------------------------------------------------ sidebar

#[test]
fn visuals_row_only_for_projects_with_a_gallery() {
    let h = harness_for(model(missing(3)), [1180.0, 900.0]);
    assert_eq!(count(&h, "Visuals ("), 1, "one gallery, one row");
    h.get_by_label("Visuals (3), art");
    assert!(
        h.query_by_label_contains("), plain").is_none(),
        "no Visuals row for a project without a gallery"
    );
}

#[test]
fn visuals_row_counts_every_image_found_not_just_the_listed() {
    let mut g = missing(5);
    g.total = 10_909;
    let h = harness_for(model(g), [1180.0, 900.0]);
    h.get_by_label("Visuals (10,909), art");
}

#[test]
fn selecting_visuals_replaces_the_chat_and_an_agent_brings_it_back() {
    let mut h = harness_for(model(missing(3)), [1180.0, 900.0]);
    assert_eq!(h.state().visuals, None, "opens on the chat");
    open_visuals(&mut h, "Visuals (3), art");
    assert_eq!(h.state().visuals, Some(0));
    assert!(
        count(&h, "visual 0.png") > 0,
        "the grid is in the main pane"
    );
    assert!(
        h.query_by_label(observatory_app::prompt::DEMO_NOTE)
            .is_none(),
        "the prompt box is gone"
    );
    h.get_by_label("Coder, seat, idle, 1m").click();
    h.run();
    assert_eq!(h.state().visuals, None);
    assert_eq!(count(&h, "visual 0.png"), 0);
    h.get_by_label(observatory_app::prompt::DEMO_NOTE);
}

#[test]
fn a_project_with_a_gallery_and_no_agents_still_has_visuals() {
    let vm = ViewModel {
        projects: vec![Project {
            name: "factory".into(),
            agents: vec![],
            gallery: Some(missing(2)),
        }],
        note: None,
    };
    let mut h = harness_for(vm, [1180.0, 900.0]);
    open_visuals(&mut h, "Visuals (2), factory");
    assert!(count(&h, "visual 1.png") > 0);
}

// ------------------------------------------------------------------ grid

#[test]
fn tiles_are_newest_first_as_received() {
    let mut h = harness_for(model(art()), [1180.0, 1400.0]);
    open_visuals(&mut h, "Visuals (13), art");
    use egui_kittest::kittest::NodeT;
    let tops: Vec<(f32, f32, String)> = h
        .query_all_by_label_contains("visual frame-")
        .map(|n| {
            let r = n.rect();
            (
                r.top(),
                r.left(),
                n.accesskit_node().label().unwrap_or_default(),
            )
        })
        .collect();
    assert_eq!(tops.len(), 12, "every real tile is on screen: {tops:?}");
    let mut by_pos = tops.clone();
    by_pos.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let names: Vec<&str> = by_pos.iter().map(|t| t.2.as_str()).collect();
    let expected: Vec<String> = (0..12)
        .map(|i| format!("visual frame-{i:03}.png"))
        .collect();
    assert_eq!(
        names, expected,
        "reading order = the list order (newest first)"
    );
}

#[test]
fn a_missing_file_is_an_unavailable_tile() {
    let mut h = harness_for(model(art()), [1180.0, 1400.0]);
    open_visuals(&mut h, "Visuals (13), art");
    h.get_by_label("visual gone.png unavailable");
    h.get_by_label("visual frame-000.png");
}

#[test]
fn click_enlarges_with_the_full_path_and_escape_closes() {
    let mut h = harness_for(model(art()), [1180.0, 1400.0]);
    open_visuals(&mut h, "Visuals (13), art");
    h.get_by_label("visual frame-002.png").click();
    h.run();
    let open = h.state().images.open.clone().expect("enlarged");
    assert_eq!(
        open.path.as_deref(),
        Some("/home/user/replay-viewer-shots/s1-4/shots/frame-002.png")
    );
    h.get_by_label("/home/user/replay-viewer-shots/s1-4/shots/frame-002.png");
    assert!(
        h.state().images.resident().1,
        "the full image is held while open"
    );
    h.key_press(egui::Key::Escape);
    h.run();
    assert!(h.state().images.open.is_none());
    assert!(!h.state().images.resident().1, "closing frees it");
}

#[test]
fn hover_caption_names_file_folder_and_age() {
    let mut h = harness_for(model(art()), [1180.0, 1400.0]);
    open_visuals(&mut h, "Visuals (13), art");
    h.get_by_label("visual frame-001.png").hover();
    h.run();
    h.get_by_label_contains("/home/user/replay-viewer-shots/s1-4/shots");
    h.get_by_label_contains("1m ago");
}

#[test]
fn only_visible_tiles_load_on_a_full_2000_grid() {
    // 2,000 DISTINCT real files (one shared file would be one cache entry: the bound could not
    // fail). Small, so generating them is quick.
    let items: Vec<GalleryImage> = (0..GALLERY_MAX)
        .map(|i| {
            let real = picture(&format!("lazy{i}.png"), 8, 8, [90, 90, 255]);
            tile(&real, "/home/user/lazy", &format!("{i}.png"), i as i64)
        })
        .collect();
    let g = Gallery {
        total: 11_000,
        items,
    };
    let mut h = harness_for(model(g), [1180.0, 900.0]);
    open_visuals(&mut h, "Visuals (11,000), art");
    let (held, _) = h.state().images.resident();
    let drawn = count(&h, "visual ");
    assert!(held > 0, "the visible ones load");
    assert!(
        held <= 40 && drawn <= 40,
        "only the rows on screen load: {held} held, {drawn} tiles laid out, of {VISUALS_PAGE} listed"
    );
}

// ------------------------------------------------------------------ paging

/// Tall enough for all of 2,000 tiles, so the footer is on screen.
fn paging_harness(g: Gallery, label: &str) -> Harness<'static, ObservatoryApp> {
    let mut h = harness_for(model(g), [3000.0, 30_000.0]);
    open_visuals(&mut h, label);
    h
}

#[test]
fn shows_400_then_show_older_adds_400_up_to_what_was_sent_then_says_what_is_not_listed() {
    let mut g = missing(GALLERY_MAX);
    g.total = 11_000;
    let mut h = paging_harness(g, "Visuals (11,000), art");
    assert_eq!(count(&h, "visual "), VISUALS_PAGE, "400 listed at first");
    assert_eq!(
        count(&h, "older images not listed"),
        0,
        "not yet at the end"
    );
    for listed in [800, 1_200, 1_600, 2_000] {
        let label = format!(
            "Show older ({} more)",
            view::count_label((GALLERY_MAX - listed + VISUALS_PAGE) as u64)
        );
        h.get_by_label(&label).click();
        h.run();
        assert_eq!(count(&h, "visual "), listed, "after {label}");
    }
    assert_eq!(count(&h, "Show older"), 0, "everything received is listed");
    h.get_by_label("9,000 older images not listed (newest 2,000 only)");
}

#[test]
fn a_short_gallery_has_no_footer() {
    let h = {
        let mut h = harness_for(model(missing(7)), [1180.0, 4000.0]);
        open_visuals(&mut h, "Visuals (7), art");
        h
    };
    assert_eq!(count(&h, "visual "), 7);
    assert_eq!(count(&h, "Show older"), 0);
    assert_eq!(count(&h, "not listed"), 0);
}

#[test]
fn an_empty_gallery_says_so() {
    let mut h = harness_for(model(Gallery::default()), [1180.0, 900.0]);
    open_visuals(&mut h, "Visuals (0), art");
    h.get_by_label("No images in this project's folders yet.");
}

// ------------------------------------------------------------------ live frames

fn hello() -> Frame {
    Frame::Hello {
        protocol: observatory_core::wire::PROTOCOL,
        distro: Some("Ubuntu".into()),
        note: None,
        seats: Vec::new(),
    }
}

fn item(path: &str, mtime_ms: i64) -> GalleryItem {
    GalleryItem {
        path: path.into(),
        mtime_ms,
        size: 10,
    }
}

fn gallery_frame(project: &str, total: u32, items: Vec<GalleryItem>) -> Frame {
    Frame::Gallery {
        project: project.into(),
        total,
        items,
    }
}

fn galleries(st: &LiveState) -> Vec<(String, Option<Gallery>)> {
    st.view_model(&Seats::default(), NOW, utc_offset)
        .projects
        .into_iter()
        .map(|p| (p.name, p.gallery))
        .collect()
}

#[test]
fn a_gallery_frame_becomes_the_projects_visuals_and_replaces_whole() {
    let mut st = LiveState::default();
    assert!(st.apply(hello()));
    let first = vec![
        item("/home/u/shots/b.png", 2_000_500),
        item("/home/u/shots/a.png", 1_000_000),
    ];
    assert!(st.apply(gallery_frame("game", 2, first.clone())));
    let g = galleries(&st);
    assert_eq!(g.len(), 1, "a project with only a gallery is listed: {g:?}");
    let gal = g[0].1.clone().expect("gallery");
    assert_eq!(g[0].0, "game");
    assert_eq!(gal.total, 2);
    let names: Vec<&str> = gal.items.iter().map(|i| i.image.name.as_str()).collect();
    assert_eq!(names, ["b.png", "a.png"], "order as sent (newest first)");
    assert_eq!(gal.items[0].modified, 2_000, "ms → s");
    assert_eq!(gal.items[0].folder, "/home/u/shots");
    assert_eq!(
        gal.items[0].image.path.as_deref(),
        Some("/home/u/shots/b.png")
    );

    assert!(
        !st.apply(gallery_frame("game", 2, first)),
        "same list: nothing moved"
    );

    // a.png deleted, c.png added: the new frame replaces the list.
    let second = vec![
        item("/home/u/shots/c.png", 3_000_000),
        item("/home/u/shots/b.png", 2_000_500),
    ];
    assert!(st.apply(gallery_frame("game", 2, second)));
    let gal = galleries(&st)[0].1.clone().unwrap();
    let names: Vec<&str> = gal.items.iter().map(|i| i.image.name.as_str()).collect();
    assert_eq!(names, ["c.png", "b.png"]);

    // Changed (same path, new mtime) counts as a change too.
    assert!(st.apply(gallery_frame(
        "game",
        2,
        vec![
            item("/home/u/shots/c.png", 3_000_000),
            item("/home/u/shots/b.png", 9_000_000),
        ]
    )));
    assert!(st.apply(gallery_frame("game", 0, vec![])), "emptied");
    assert_eq!(galleries(&st)[0].1.clone().unwrap(), Gallery::default());
}

#[test]
fn hello_forgets_galleries() {
    let mut st = LiveState::default();
    st.apply(hello());
    st.apply(gallery_frame("game", 1, vec![item("/x/a.png", 1)]));
    assert!(
        st.apply(hello()),
        "a restart with only a gallery held still repaints"
    );
    assert!(galleries(&st).is_empty());
}

#[test]
fn a_gallery_attaches_to_the_project_with_its_agents_in_name_order() {
    use observatory_core::Session;
    let mut st = LiveState::default();
    st.apply(hello());
    let mut s = Session::default();
    s.meta.session_id = "s1".into();
    s.meta.agent_name = Some("Orca".into());
    st.apply(Frame::Session {
        project: "replay-viewer".into(),
        session: Box::new(s),
    });
    st.apply(gallery_frame(
        "asset-pipeline",
        1,
        vec![item("/x/a.png", 1)],
    ));
    st.apply(gallery_frame("replay-viewer", 1, vec![item("/x/b.png", 1)]));
    st.apply(gallery_frame("a-first", 1, vec![item("/x/c.png", 1)]));
    let vm = st.view_model(&Seats::default(), NOW, utc_offset);
    let names: Vec<(&str, usize, bool)> = vm
        .projects
        .iter()
        .map(|p| (p.name.as_str(), p.agents.len(), p.gallery.is_some()))
        .collect();
    assert_eq!(
        names,
        [
            ("a-first", 0, true),
            ("asset-pipeline", 0, true),
            ("replay-viewer", 1, true)
        ]
    );
}

#[test]
fn gallery_paths_map_like_chat_images() {
    let items = [
        item("/home/u/_scratch/a.png", 1),
        item("/mnt/d/renders/output/b.png", 1),
    ];
    let g = map_gallery(2, &items, Some("Ubuntu"), true);
    assert_eq!(
        g.items[0].image.src,
        ImageSrc::File(r"\\wsl.localhost\Ubuntu\home\u\_scratch\a.png".into())
    );
    assert_eq!(
        g.items[1].image.src,
        ImageSrc::File(r"D:\renders\output\b.png".into())
    );
    assert_eq!(
        g.items[1].image.path.as_deref(),
        Some("/mnt/d/renders/output/b.png"),
        "the enlarged view shows the path as the bridge named it"
    );
    let linux = map_gallery(1, &items[..1], None, false);
    assert_eq!(
        linux.items[0].image.src,
        ImageSrc::File("/home/u/_scratch/a.png".into())
    );
    let no_distro = map_gallery(1, &items[..1], None, true);
    assert!(matches!(
        no_distro.items[0].image.src,
        ImageSrc::Unreadable(_)
    ));
}

// ------------------------------------------------------------------ snapshots

#[test]
fn snapshot_visuals_grid() {
    let mut h = harness_for(model(art()), [1180.0, 900.0]);
    open_visuals(&mut h, "Visuals (13), art");
    h.snapshot("visuals_grid_dark");
}

#[test]
fn snapshot_visuals_sidebar_demo() {
    let mut app = ObservatoryApp::demo();
    app.images = ImageCache::inline();
    let mut h = Harness::builder()
        .with_size(vec2(1180.0, 900.0))
        .with_theme(Theme::Dark)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.run();
    open_visuals(&mut h, "Visuals (10,909), asset-pipeline");
    h.snapshot("visuals_sidebar_dark");
}

#[test]
fn counts_are_thousands_separated() {
    for (n, s) in [
        (0, "0"),
        (7, "7"),
        (999, "999"),
        (1_000, "1,000"),
        (10_909, "10,909"),
        (1_234_567, "1,234,567"),
    ] {
        assert_eq!(view::count_label(n), s);
    }
}

#[test]
fn a_stale_visuals_selection_falls_back_to_the_chat() {
    // Project 9 does not exist; project 1 ("plain") has no gallery. Neither may panic.
    for stale in [9, 1] {
        let mut app = ObservatoryApp::new(model(missing(3)), Clock::Fixed(NOW));
        app.images = ImageCache::inline();
        app.visuals = Some(stale);
        let mut h = Harness::builder()
            .with_size(vec2(1180.0, 900.0))
            .with_theme(Theme::Dark)
            .with_context_setup(ObservatoryApp::install)
            .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
        h.run();
        assert_eq!(h.state().visuals, None, "stale {stale}");
        h.get_by_label(observatory_app::prompt::DEMO_NOTE);
    }
}

/// A 4K window shows more tiles than the thumbnail cache's normal size. The grid must
/// settle (nothing loaded again once everything on screen is in), and leaving it frees the
/// cache back down to its normal size.
#[test]
fn a_4k_grid_with_more_tiles_than_the_cache_settles() {
    use observatory_app::images::MAX_THUMBS;
    let items: Vec<GalleryImage> = (0..400)
        .map(|i| {
            let real = picture(&format!("big{i}.png"), 8, 8, [255, 90, 90]);
            tile(&real, "/home/user/big", &format!("{i}.png"), i as i64)
        })
        .collect();
    let mut h = harness_for(model(Gallery { total: 400, items }), [3840.0, 2160.0]);
    open_visuals(&mut h, "Visuals (400), art");
    let drawn = count(&h, "visual ");
    assert!(drawn > MAX_THUMBS, "the window really shows more: {drawn}");
    let loads = h.state().images.thumb_loads();
    assert!(
        loads >= drawn as u64,
        "the counter counts: {loads} loads for {drawn} tiles"
    );
    for _ in 0..5 {
        h.step();
    }
    assert_eq!(
        h.state().images.thumb_loads(),
        loads,
        "settled: no tile is loaded again"
    );
    assert_eq!(count(&h, "loading"), 0);
    assert_eq!(
        h.state().images.resident().0,
        drawn,
        "every tile on screen held"
    );
    h.get_by_label("Painter, seat, idle, 1m").click();
    h.run();
    assert!(
        h.state().images.resident().0 <= MAX_THUMBS,
        "off screen again: back to at most {MAX_THUMBS}, held {}",
        h.state().images.resident().0
    );
}
