//! Images in the chat — thumbnails, "+N more", the enlarged view, placeholders, lazy
//! loading and the memory rules. Image files are generated into cargo's target tmp dir (never
//! the live logs); the paths SHOWN are fixed strings, so snapshots do not depend on the tree.

use std::path::PathBuf;

use egui::{Key, Theme, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use observatory_app::images::{ImageCache, RECHECK, THUMB_MAX_H};
use observatory_app::model::{Agent, ChatItem, Image, ImageSrc, Project, Role, Status, ViewModel};
use observatory_app::{Clock, ObservatoryApp};

const NOW: i64 = 1_795_000_000;

fn dir() -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("v1-7-images");
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A w×h gradient (deterministic pixels) saved as `name`; returns its path.
fn picture(name: &str, w: u32, h: u32, tint: [u8; 3]) -> String {
    let p = dir().join(name);
    let img = image::RgbImage::from_fn(w, h, |x, y| {
        image::Rgb([
            (tint[0] as u32 * x / w.max(1)) as u8,
            (tint[1] as u32 * y / h.max(1)) as u8,
            tint[2],
        ])
    });
    // Tests run in parallel and share these files: write aside, then rename into place, so a
    // reader never sees a half-written image.
    let tmp = dir().join(format!("tmp-{:?}-{name}", std::thread::current().id()));
    img.save(&tmp).unwrap();
    std::fs::rename(&tmp, &p).unwrap();
    p.to_string_lossy().into_owned()
}

/// Write `text` to `path` atomically (see [`picture`]).
fn write_atomic(path: &std::path::Path, text: &str) {
    let tmp = path.with_extension(format!("{:?}.tmp", std::thread::current().id()));
    std::fs::write(&tmp, text).unwrap();
    std::fs::rename(&tmp, path).unwrap();
}

/// A log file whose second line embeds `png` as a pasted image block; returns the source.
fn embedded(png_path: &str) -> ImageSrc {
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD.encode(std::fs::read(png_path).unwrap());
    let first = r#"{"type":"user","message":{"content":"hi"}}"#;
    let second = format!(
        r#"{{"type":"user","message":{{"content":[{{"type":"text","text":"look"}},{{"type":"image","source":{{"type":"base64","media_type":"image/png","data":"{data}"}}}}]}}}}"#
    );
    let log = dir().join("pasted.jsonl");
    write_atomic(&log, &format!("{first}\n{second}\n"));
    ImageSrc::Embedded {
        log: log.to_string_lossy().into_owned(),
        offset: first.len() as u64 + 1,
        len: second.len() as u64,
        block: 1,
        part: None,
    }
}

fn img(src: ImageSrc, name: &str, path: Option<&str>) -> Image {
    Image {
        src,
        name: name.into(),
        path: path.map(str::to_owned),
        hide_if_missing: false,
    }
}

fn file(real: &str, shown: &str) -> Image {
    let name = shown.rsplit('/').next().unwrap();
    img(ImageSrc::File(real.into()), name, Some(shown))
}

fn model() -> ViewModel {
    let a = picture("a.png", 320, 200, [255, 120, 40]);
    let b = picture("b.jpg", 200, 300, [40, 200, 255]);
    let wide = picture("wide.png", 900, 300, [200, 255, 60]);
    let small = picture("small.webp.png", 60, 40, [255, 255, 255]);
    // A shell command naming 8 files: marked like the real mapping marks Bash paths (render
    // nothing when missing), all present here.
    let batch: Vec<Image> = (0..8)
        .map(|i| Image {
            hide_if_missing: true,
            ..file(&a, &format!("/home/user/shots/frame{i}.png"))
        })
        .collect();
    let items = vec![
        ChatItem::User {
            text: "two screenshots".into(),
            images: vec![
                img(embedded(&a), "pasted image", None),
                file(&b, "/home/user/shots/b.jpg"),
            ],
        },
        ChatItem::ToolCall {
            summary: "Read shots/wide.png".into(),
            input: "{}".into(),
            output: Some("[image]".into()),
            is_error: false,
            images: vec![file(&wide, "/home/user/shots/wide.png")],
        },
        ChatItem::ToolCall {
            summary: "Ran make-shots".into(),
            input: "{}".into(),
            output: None,
            is_error: false,
            images: batch,
        },
        // A Read of a file that is gone keeps its "image unavailable" placeholder (a Bash card
        // would show nothing for it).
        ChatItem::ToolCall {
            summary: "Read shots/gone.png".into(),
            input: "{}".into(),
            output: Some("File does not exist.".into()),
            is_error: true,
            images: vec![img(
                ImageSrc::File("/nonexistent/shots/gone.png".into()),
                "gone.png",
                Some("/nonexistent/shots/gone.png"),
            )],
        },
        ChatItem::User {
            text: String::new(),
            images: vec![file(&small, "/home/user/shots/small.png")],
        },
    ];
    ViewModel {
        projects: vec![Project {
            name: "my-app".into(),
            agents: vec![Agent {
                name: "Pix".into(),
                role: Role::Sibling,
                status: Status::Idle,
                last_activity: Some(NOW - 60),
                model: None,
                permission_mode: None,
                turn_started: None,
                items,
                pages: vec![],
                target: Default::default(),
            }],
            gallery: None,
        }],
        note: None,
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

/// One frame only (no settling): what the window shows the first time it draws.
fn first_frame(vm: ViewModel, size: [f32; 2]) -> Harness<'static, ObservatoryApp> {
    let mut app = ObservatoryApp::new(vm, Clock::Fixed(NOW));
    app.images = ImageCache::inline();
    let mut h = Harness::builder()
        .with_size(vec2(size[0], size[1]))
        .with_theme(Theme::Dark)
        .with_context_setup(ObservatoryApp::install)
        .build_ui_state(|ui, app: &mut ObservatoryApp| app.ui(ui), app);
    h.step();
    h
}

fn harness() -> Harness<'static, ObservatoryApp> {
    // Tall enough that the whole chat is on screen (the chat sticks to the bottom).
    harness_for(model(), [1180.0, 1400.0])
}

fn count(h: &Harness<'_, ObservatoryApp>, label: &str) -> usize {
    h.query_all_by_label_contains(label).count()
}

#[test]
fn thumbnails_six_then_more() {
    let mut h = harness();
    // The Bash card shows 6 of 8 (frame0..frame5); frame6 and frame7 wait.
    assert_eq!(count(&h, "image frame"), 6);
    h.get_by_label("+2 more").click();
    h.run();
    assert_eq!(count(&h, "image frame"), 8);
    assert!(h.query_by_label("+2 more").is_none());
}

#[test]
fn missing_file_is_a_placeholder_with_its_path() {
    let h = harness();
    h.get_by_label("image unavailable /nonexistent/shots/gone.png");
    // Every other thumbnail loaded (embedded one included).
    for l in [
        "image pasted image",
        "image b.jpg",
        "image wide.png",
        "image small.png",
    ] {
        h.get_by_label(l);
    }
}

#[test]
fn thumbnails_are_at_most_160_tall_and_keep_aspect() {
    let h = harness();
    let wide = h.get_by_label("image wide.png").rect();
    assert!(wide.height() <= THUMB_MAX_H as f32 + 0.5, "{wide:?}");
    assert!(
        (wide.width() / wide.height() - 3.0).abs() < 0.05,
        "{wide:?}"
    );
    let tall = h.get_by_label("image b.jpg").rect();
    assert!((tall.height() - THUMB_MAX_H as f32).abs() < 0.5, "{tall:?}");
    let small = h.get_by_label("image small.png").rect();
    assert!(
        (small.height() - 40.0).abs() < 0.5,
        "never enlarged: {small:?}"
    );
}

#[test]
fn enlarge_then_escape_frees_the_full_image() {
    let mut h = harness();
    assert!(!h.state().images.resident().1);
    h.get_by_label("image wide.png").click();
    h.run();
    assert!(h.state().images.open.is_some());
    assert!(h.state().images.resident().1, "full size held while open");
    h.get_by_label("/home/user/shots/wide.png");
    h.key_press(Key::Escape);
    h.run();
    assert!(h.state().images.open.is_none());
    assert!(!h.state().images.resident().1, "freed on close");
}

#[test]
fn click_outside_closes_and_pasted_has_no_path() {
    let mut h = harness();
    h.get_by_label("image pasted image").click();
    h.run();
    h.get_by_label("pasted image"); // the viewer's title
    assert_eq!(
        h.state().images.open.as_ref().unwrap().path,
        None,
        "no path for a paste"
    );
    h.hover_at(egui::pos2(5.0, 5.0));
    h.event(egui::Event::PointerButton {
        pos: egui::pos2(5.0, 5.0),
        button: egui::PointerButton::Primary,
        pressed: true,
        modifiers: Default::default(),
    });
    h.event(egui::Event::PointerButton {
        pos: egui::pos2(5.0, 5.0),
        button: egui::PointerButton::Primary,
        pressed: false,
        modifiers: Default::default(),
    });
    h.run();
    assert!(h.state().images.open.is_none());
}

#[test]
fn enlarged_fits_the_window_and_keeps_aspect() {
    let mut vm = model();
    let items = &mut vm.projects[0].agents[0].items;
    items.retain(|i| matches!(i, ChatItem::ToolCall { summary, .. } if summary.contains("wide")));
    let mut h = harness_for(vm, [700.0, 500.0]);
    h.get_by_label("image wide.png").click();
    h.run();
    let shown = h
        .query_all_by_role(egui::accesskit::Role::Image)
        .map(|n| n.rect())
        .max_by(|a, b| a.width().total_cmp(&b.width()))
        .unwrap();
    assert!(shown.width() <= 700.0 * 0.9, "{shown:?}");
    assert!(
        (shown.width() / shown.height() - 3.0).abs() < 0.05,
        "{shown:?}"
    );
}

#[test]
fn off_screen_thumbnails_are_not_loaded() {
    // 60 DISTINCT files: one shared file would be one cache entry and the count could not fail.
    let mut vm = model();
    vm.projects[0].agents[0].items = (0..60)
        .map(|i| {
            let real = picture(&format!("lazy{i}.png"), 64, 64, [90, 90, 255]);
            ChatItem::User {
                text: format!("shot {i}"),
                images: vec![file(&real, &format!("/home/user/lazy/{i}.png"))],
            }
        })
        .collect();
    let h = harness_for(vm, [1180.0, 900.0]);
    let (held, _) = h.state().images.resident();
    assert!(held > 0, "the visible ones load");
    assert!(held < 20, "only what is on screen loads: {held} of 60");
}

#[test]
fn snapshot_chat_with_thumbnails() {
    let mut h = harness();
    h.snapshot("images_chat_dark");
}

#[test]
fn snapshot_enlarged() {
    let mut h = harness();
    h.get_by_label("image wide.png").click();
    h.run();
    h.snapshot("images_enlarged_dark");
}

#[test]
fn right_aligned_row_keeps_reading_order() {
    let h = harness();
    let pasted = h.get_by_label("image pasted image").rect();
    let b = h.get_by_label("image b.jpg").rect();
    assert!(pasted.right() <= b.left() + 0.5, "{pasted:?} then {b:?}");
}

/// Human ruling: a file named only in a shell command renders NOTHING when it is missing
/// and does not count toward "+N more"; a Read's missing file keeps its placeholder.
fn bash_model() -> ViewModel {
    let ok = picture("bash-ok.png", 120, 80, [255, 200, 0]);
    let bash = |real: &str, shown: &str| Image {
        hide_if_missing: true,
        ..file(real, shown)
    };
    // 6 present + 2 missing: without the row's up-front check, the 6 shown are all present, so
    // the missing one past them is never drawn, never checked, and "+1 more" stays forever.
    let mut images: Vec<Image> = (0..6)
        .map(|i| bash(&ok, &format!("/home/user/out/ok{i}.png")))
        .collect();
    images.insert(
        1,
        bash("/nonexistent/bash/gone1.png", "/nonexistent/bash/gone1.png"),
    );
    // Past the first 6: only the row's up-front check can drop it from "+N more".
    images.push(bash(
        "/nonexistent/bash/gone2.png",
        "/nonexistent/bash/gone2.png",
    ));
    let mut vm = model();
    vm.projects[0].agents[0].items = vec![
        ChatItem::ToolCall {
            summary: "Ran convert".into(),
            input: "{}".into(),
            output: None,
            is_error: false,
            images, // 8 refs: 6 present, 2 missing
        },
        ChatItem::ToolCall {
            summary: "Ran rm".into(),
            input: "{}".into(),
            output: None,
            is_error: false,
            images: vec![bash(
                "/nonexistent/bash/only.png",
                "/nonexistent/bash/only.png",
            )],
        },
        ChatItem::ToolCall {
            summary: "Read gone.png".into(),
            input: "{}".into(),
            output: None,
            is_error: true,
            images: vec![img(
                ImageSrc::File("/nonexistent/read/gone.png".into()),
                "gone.png",
                Some("/nonexistent/read/gone.png"),
            )],
        },
    ];
    vm
}

#[test]
fn missing_bash_files_render_nothing_read_keeps_its_placeholder() {
    let h = harness_for(bash_model(), [1180.0, 900.0]);
    assert_eq!(
        count(&h, "/nonexistent/bash/"),
        0,
        "no placeholder, no label"
    );
    assert_eq!(count(&h, "image ok"), 6, "all 6 present ones shown");
    assert!(
        h.query_by_label_contains("more").is_none(),
        "8 refs but 2 hidden: 6 fit, no +N more"
    );
    h.get_by_label("image unavailable /nonexistent/read/gone.png");
    // The all-missing Bash card is just its card.
    h.get_by_label_contains("Ran rm");
}

/// A tool call is logged before its command writes the file: the image shows up once the file
/// exists (rechecked while on screen), without reopening the chat.
#[test]
fn bash_file_written_after_the_call_appears() {
    let p = dir().join("written-later.png");
    let _ = std::fs::remove_file(&p);
    let real = p.to_string_lossy().into_owned();
    let mut vm = model();
    vm.projects[0].agents[0].items = vec![ChatItem::ToolCall {
        summary: "Ran render".into(),
        input: "{}".into(),
        output: None,
        is_error: false,
        images: vec![Image {
            hide_if_missing: true,
            ..file(&real, "/home/user/out/later.png")
        }],
    }];
    let mut h = harness_for(vm, [1180.0, 900.0]);
    assert_eq!(count(&h, "later.png"), 0, "not there yet: nothing drawn");
    picture("written-later.png", 90, 60, [0, 255, 120]);
    h.state_mut().images.advance_clock(RECHECK);
    h.run();
    h.get_by_label("image later.png");
    let _ = std::fs::remove_file(&p);
}

#[test]
fn missing_bash_files_never_flash_and_more_is_right_on_the_first_frame() {
    let h = first_frame(bash_model(), [1180.0, 900.0]);
    assert_eq!(count(&h, "image ok"), 6, "the frame really drew the row");
    assert_eq!(
        count(&h, "/nonexistent/bash/"),
        0,
        "no placeholder, even for a frame"
    );
    assert!(
        h.query_by_label_contains("more").is_none(),
        "no stale +N more"
    );
}

/// The chat of [`bash_file_written_after_the_call_appears`], idle (no turn running: the app's
/// own tick is 60 s), showing one Bash file at `real`.
fn idle_with_file(real: &str) -> ViewModel {
    let mut vm = model();
    let a = &mut vm.projects[0].agents[0];
    a.turn_started = None;
    a.items = vec![ChatItem::ToolCall {
        summary: "Ran render".into(),
        input: "{}".into(),
        output: None,
        is_error: false,
        images: vec![Image {
            hide_if_missing: true,
            ..file(real, "/home/user/out/later.png")
        }],
    }];
    vm
}

/// The soonest repaint the next frame asks for.
fn soonest_repaint(h: &mut Harness<'_, ObservatoryApp>) -> std::time::Duration {
    let asked = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = asked.clone();
    h.ctx
        .set_request_repaint_callback(move |i| sink.lock().unwrap().push(i.delay));
    h.step();
    let asked = asked.lock().unwrap();
    asked
        .iter()
        .copied()
        .min()
        .expect("the frame asked for a repaint")
}

/// An idle window still rechecks a missing file on screen every RECHECK, on the real
/// clock (no `advance_clock`): the picture appears within ~3 s, not at the next 60 s tick.
#[test]
fn idle_window_shows_a_file_written_later_within_the_recheck() {
    let p = dir().join("written-later-idle.png");
    let _ = std::fs::remove_file(&p);
    let real = p.to_string_lossy().into_owned();

    // Control: the same idle chat with the file already there asks for nothing sooner than 60 s.
    let there = picture("there-idle.png", 90, 60, [0, 120, 255]);
    let mut c = harness_for(idle_with_file(&there), [1180.0, 900.0]);
    assert!(
        soonest_repaint(&mut c) >= std::time::Duration::from_secs(60),
        "control is idle"
    );

    let mut h = harness_for(idle_with_file(&real), [1180.0, 900.0]);
    assert_eq!(count(&h, "later.png"), 0, "not there yet: nothing drawn");
    let wait = soonest_repaint(&mut h);
    assert!(
        wait <= RECHECK && wait >= RECHECK / 2,
        "a missing file on screen asks for a frame at its recheck, got {wait:?}"
    );
    picture("written-later-idle.png", 90, 60, [0, 255, 120]);
    std::thread::sleep(wait + std::time::Duration::from_millis(100));
    h.step();
    h.step();
    h.get_by_label("image later.png");
    let _ = std::fs::remove_file(&p);
}
