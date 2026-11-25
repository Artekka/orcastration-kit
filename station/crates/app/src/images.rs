//! Chat images: where an image can be read from on this machine, reading it (read-only),
//! decoding it (PNG / JPEG / WebP only), and a small texture cache.
//!
//! Memory rules: the view model holds only [`Image`] references, never bytes. A thumbnail is
//! requested only when its spot in the chat is on screen; the worker thread reads and decodes it,
//! shrinks it to at most [`THUMB_MAX_H`] px tall, and drops the full-size pixels at once. At most
//! [`MAX_THUMBS`] thumbnails stay resident (least recently drawn go first), more only while more
//! than that are on screen at once (a 4K Visuals grid): what was drawn in the last two frames
//! is never dropped, or the grid would reload the same tiles every frame. The full-size image
//! exists only while the enlarged view is open.
//!
//! Every failure (gone, rewritten log, not an image, too big) becomes an "image unavailable"
//! placeholder with the reason; nothing here panics on bad input.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use observatory_core::ImageRef;
use serde_json::Value;

pub const THUMB_MAX_H: u32 = 160;
/// Very wide images are capped too, so one thumbnail cannot fill the row.
pub const THUMB_MAX_W: u32 = 480;
pub const MAX_THUMBS: usize = 200;
/// Refuse files and log lines bigger than this (a log line with one pasted image is < 1 MB).
const MAX_BYTES: u64 = 64 << 20;
/// Largest side the decoder accepts (decompression-bomb guard).
const MAX_SIDE: u32 = 16_384;

/// Where to read an image on this machine.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ImageSrc {
    /// An image file (a path this process can open).
    File(String),
    /// An image block inside a log line: the log (a path this process can open), the line's
    /// byte offset and length, the block in `message.content`, the part in a `tool_result`.
    Embedded {
        log: String,
        offset: u64,
        len: u64,
        block: usize,
        part: Option<usize>,
    },
    /// Cannot be read from here; the reason.
    Unreadable(String),
}

/// One image in the chat, by reference.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Image {
    pub src: ImageSrc,
    /// The file name, or "pasted image" / "tool result image".
    pub name: String,
    /// The full path as the agent named it (shown in the enlarged view), when it is a file.
    pub path: Option<String>,
    /// Render nothing (not even a placeholder) when it cannot be read: a file named only in a
    /// shell command, which is often a scratch file deleted since (human ruling).
    pub hide_if_missing: bool,
}

fn is_windows_abs(p: &str) -> bool {
    let b = p.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/')
}

/// A path as named in a WSL log → a path this process can open. `windows`: this app runs on
/// Windows (WSL paths go through `\\wsl.localhost\<distro>`, `/mnt/<d>/…` maps to `D:\…`);
/// otherwise it runs inside Linux and WSL paths are used as they are.
pub fn host_path(p: &str, distro: Option<&str>, windows: bool) -> Result<String, String> {
    if is_windows_abs(p) {
        return if windows {
            Ok(p.replace('/', "\\"))
        } else {
            Err("a Windows path; not readable here".into())
        };
    }
    if !p.starts_with('/') {
        return Err("not an absolute path".into());
    }
    if !windows {
        return Ok(p.to_owned());
    }
    let b = p.as_bytes();
    if p.starts_with("/mnt/")
        && b.len() >= 6
        && b[5].is_ascii_alphabetic()
        && (b.len() == 6 || b[6] == b'/')
    {
        let drive = (b[5] as char).to_ascii_uppercase();
        return Ok(format!(
            "{drive}:\\{}",
            p.get(7..).unwrap_or("").replace('/', "\\")
        ));
    }
    match distro {
        Some(d) => Ok(format!(r"\\wsl.localhost\{d}{}", p.replace('/', "\\"))),
        None => Err("the bridge did not say its WSL distro".into()),
    }
}

fn file_name(p: &str) -> String {
    p.rsplit(['/', '\\'])
        .next()
        .filter(|n| !n.is_empty())
        .unwrap_or(p)
        .to_owned()
}

impl Image {
    /// The app's image for a core reference from a session whose log is `log_path`.
    pub fn from_ref(
        r: &ImageRef,
        log_path: Option<&str>,
        distro: Option<&str>,
        windows: bool,
    ) -> Self {
        match r {
            ImageRef::File { path } => Image {
                src: host_path(path, distro, windows)
                    .map_or_else(ImageSrc::Unreadable, ImageSrc::File),
                name: file_name(path),
                path: Some(path.clone()),
                hide_if_missing: false,
            },
            ImageRef::Embedded {
                line_offset,
                line_len,
                block,
                part,
                path,
                ..
            } => {
                let src = match (line_offset, log_path) {
                    (Some(offset), Some(log)) => match host_path(log, distro, windows) {
                        Ok(log) => ImageSrc::Embedded {
                            log,
                            offset: *offset,
                            len: *line_len,
                            block: *block,
                            part: *part,
                        },
                        Err(why) => ImageSrc::Unreadable(why),
                    },
                    _ => ImageSrc::Unreadable("its place in the log is unknown".into()),
                };
                let name = match (path, part) {
                    (Some(p), _) => file_name(p),
                    (None, Some(_)) => "tool result image".into(),
                    (None, None) => "pasted image".into(),
                };
                Image {
                    src,
                    name,
                    path: path.clone(),
                    hide_if_missing: false,
                }
            }
        }
    }
}

/// The encoded bytes of `src` (read-only opens only).
pub fn read_bytes(src: &ImageSrc) -> Result<Vec<u8>, String> {
    match src {
        ImageSrc::Unreadable(why) => Err(why.clone()),
        ImageSrc::File(p) => {
            let mut f = File::open(p).map_err(|e| format!("cannot open: {e}"))?;
            let n = f.metadata().map_err(|e| e.to_string())?.len();
            if n > MAX_BYTES {
                return Err(format!("too big ({n} bytes)"));
            }
            let mut out = Vec::with_capacity(n as usize);
            f.read_to_end(&mut out).map_err(|e| e.to_string())?;
            Ok(out)
        }
        ImageSrc::Embedded {
            log,
            offset,
            len,
            block,
            part,
        } => {
            if *len == 0 || *len > MAX_BYTES {
                return Err("the log line is empty or too big".into());
            }
            let mut f = File::open(log).map_err(|e| format!("cannot open the log: {e}"))?;
            f.seek(SeekFrom::Start(*offset))
                .map_err(|e| e.to_string())?;
            let mut line = vec![0u8; *len as usize];
            f.read_exact(&mut line)
                .map_err(|_| "the log is shorter than before (rewritten?)".to_owned())?;
            embedded_bytes(&line, *block, *part)
        }
    }
}

/// Decode the base64 image at `block` (and `part`) of one log line. Anything else is an error:
/// a line that changed since the bridge read it is never guessed at.
pub fn embedded_bytes(line: &[u8], block: usize, part: Option<usize>) -> Result<Vec<u8>, String> {
    let v: Value = serde_json::from_slice(line)
        .map_err(|_| "the log line changed (not the line the bridge read)".to_owned())?;
    let mut img = v
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.get(block));
    if let Some(p) = part {
        img = img.and_then(|b| b.get("content")).and_then(|c| c.get(p));
    }
    let img = img.ok_or("no such block in the log line")?;
    let src = img
        .get("source")
        .filter(|_| img.get("type").and_then(Value::as_str) == Some("image"))
        .ok_or("not an image block")?;
    if src.get("type").and_then(Value::as_str) != Some("base64") {
        return Err("not a base64 image".into());
    }
    let data = src
        .get("data")
        .and_then(Value::as_str)
        .ok_or("no image data")?;
    base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|_| "bad base64".into())
}

/// Decoded RGBA pixels, shrunk to fit `max` (w, h) when given. PNG, JPEG and WebP only.
pub fn decode(bytes: &[u8], max: Option<(u32, u32)>) -> Result<egui::ColorImage, String> {
    use image::ImageFormat;
    let fmt = image::guess_format(bytes).map_err(|_| "not a PNG, JPEG or WebP image".to_owned())?;
    if !matches!(
        fmt,
        ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::WebP
    ) {
        return Err("not a PNG, JPEG or WebP image".into());
    }
    let mut r = image::ImageReader::with_format(Cursor::new(bytes), fmt);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    r.limits(limits);
    let mut img = r.decode().map_err(|e| format!("cannot decode: {e}"))?;
    if let Some((w, h)) = max
        && (img.width() > w || img.height() > h)
    {
        img = img.thumbnail(w, h);
    }
    let rgba = img.to_rgba8();
    let size = [rgba.width() as usize, rgba.height() as usize];
    Ok(egui::ColorImage::from_rgba_unmultiplied(
        size,
        rgba.as_raw(),
    ))
}

/// Read and decode, as a thumbnail (`full == false`) or full size.
pub fn load(src: &ImageSrc, full: bool) -> Result<egui::ColorImage, String> {
    load_within(src, (!full).then_some((THUMB_MAX_W, THUMB_MAX_H)))
}

/// Read and decode, shrunk to fit `max` (width, height) when given.
pub fn load_within(src: &ImageSrc, max: Option<(u32, u32)>) -> Result<egui::ColorImage, String> {
    let bytes = read_bytes(src)?;
    decode(&bytes, max)
}

/// How often a file thumbnail on screen is checked again: a missing or unreadable one (a tool
/// call is logged before its command writes the file), or a loaded one that may be overwritten.
pub const RECHECK: Duration = Duration::from_secs(3);

/// A file's size and modification time: when either changes, the file is read again.
type Stamp = (u64, SystemTime);

fn file_stamp(src: &ImageSrc) -> Option<Stamp> {
    let ImageSrc::File(p) = src else {
        return None;
    };
    let m = std::fs::metadata(p).ok()?;
    Some((m.len(), m.modified().unwrap_or(UNIX_EPOCH)))
}

/// The largest side the enlarged image may have: what the GPU accepts, and no more than the
/// window's longer side in pixels (the viewer only ever shrinks the image to fit the window).
pub fn full_side(ctx: &egui::Context) -> u32 {
    let (gpu, ppp) = ctx.input(|i| (i.max_texture_side, i.pixels_per_point));
    let screen = ctx.content_rect();
    let window = (screen.width().max(screen.height()) * ppp).ceil().max(1.0) as usize;
    gpu.min(window).clamp(1, MAX_SIDE as usize) as u32
}

/// A cache entry.
#[derive(Clone)]
pub enum Slot {
    Pending,
    Ready(egui::TextureHandle),
    Failed(String),
}

struct Job {
    src: ImageSrc,
    full: bool,
    max: Option<(u32, u32)>,
    /// A recheck: the stamp the slot was made from. The file is read only if it changed.
    recheck: Option<Option<Stamp>>,
}

struct Done {
    src: ImageSrc,
    full: bool,
    /// `None`: a recheck found the file unchanged.
    loaded: Option<(Result<egui::ColorImage, String>, Option<Stamp>)>,
}

/// Stamp first, then read: a write that lands in between changes the stamp, so the next
/// recheck reads the file again (never the other way round, which could miss it).
fn run(job: Job) -> Done {
    let stamp = file_stamp(&job.src);
    let loaded = match job.recheck {
        Some(prev) if prev == stamp => None,
        _ => Some((load_within(&job.src, job.max), stamp)),
    };
    Done {
        src: job.src,
        full: job.full,
        loaded,
    }
}

struct Worker {
    jobs: Sender<Job>,
    done: Receiver<Done>,
}

impl Worker {
    fn spawn(ctx: &egui::Context) -> Option<Self> {
        let (jobs, job_rx) = channel::<Job>();
        let (done_tx, done) = channel();
        let ctx = ctx.clone();
        std::thread::Builder::new()
            .name("observatory-images".into())
            .spawn(move || {
                for job in job_rx {
                    if done_tx.send(run(job)).is_err() {
                        break;
                    }
                    ctx.request_repaint();
                }
            })
            .ok()?;
        Some(Worker { jobs, done })
    }
}

struct Thumb {
    slot: Slot,
    /// The frame it was last drawn in (least recently drawn are dropped first).
    drawn: u64,
    /// What the file looked like when `slot` was made (files only).
    stamp: Option<Stamp>,
    /// When it was last loaded or checked.
    checked: Instant,
    /// A recheck is on the worker; the old slot stays shown until it answers.
    checking: bool,
}

/// Thumbnails by source, the one enlarged image, and which image is open.
pub struct ImageCache {
    thumbs: HashMap<ImageSrc, Thumb>,
    full: Option<(ImageSrc, Slot)>,
    frame: u64,
    /// Decode on a worker thread (the window) or inline (tests: deterministic frames).
    background: bool,
    worker: Option<Worker>,
    /// Added to the clock (tests step past [`RECHECK`] without sleeping).
    skew: Duration,
    /// The image shown enlarged, if any.
    pub open: Option<Image>,
    /// Thumbnails loaded for the first time (rechecks not counted); tests check a grid settles.
    loads: u64,
}

impl Default for ImageCache {
    fn default() -> Self {
        Self::background()
    }
}

impl ImageCache {
    pub fn background() -> Self {
        ImageCache {
            thumbs: HashMap::new(),
            full: None,
            frame: 0,
            background: true,
            worker: None,
            skew: Duration::ZERO,
            open: None,
            loads: 0,
        }
    }

    /// Decodes on the UI thread, so a test's next frame already shows the image.
    pub fn inline() -> Self {
        ImageCache {
            background: false,
            ..Self::background()
        }
    }

    /// Move this cache's clock forward (tests).
    pub fn advance_clock(&mut self, by: Duration) {
        self.skew += by;
    }

    fn now(&self) -> Instant {
        Instant::now() + self.skew
    }

    /// How many thumbnails were loaded for the first time (a reload after eviction counts).
    pub fn thumb_loads(&self) -> u64 {
        self.loads
    }

    /// (thumbnails held, whether a full-size image is held).
    pub fn resident(&self) -> (usize, bool) {
        (
            self.thumbs
                .values()
                .filter(|t| matches!(t.slot, Slot::Ready(_)))
                .count(),
            matches!(self.full, Some((_, Slot::Ready(_)))),
        )
    }

    /// Once per frame: take finished decodes, drop the least recently drawn thumbnails.
    pub fn begin_frame(&mut self, ctx: &egui::Context) {
        self.frame += 1;
        let mut done = Vec::new();
        if let Some(w) = &self.worker {
            while let Ok(d) = w.done.try_recv() {
                done.push(d);
            }
        }
        for d in done {
            self.apply(ctx, d);
        }
        if self.thumbs.len() > MAX_THUMBS {
            let mut by_age: Vec<(u64, ImageSrc)> = self
                .thumbs
                .iter()
                // Drawn this frame or the last: on screen now, so never dropped (`frame` was just
                // bumped, so the frame that just ended is `frame - 1`).
                .filter(|(_, t)| !matches!(t.slot, Slot::Pending) && t.drawn + 1 < self.frame)
                .map(|(k, t)| (t.drawn, k.clone()))
                .collect();
            by_age.sort_by_key(|(t, _)| *t);
            let extra = self.thumbs.len() - MAX_THUMBS;
            for (_, k) in by_age.into_iter().take(extra) {
                self.thumbs.remove(&k);
            }
        }
    }

    /// Store a finished load or recheck where it belongs (dropped if that entry is gone).
    fn apply(&mut self, ctx: &egui::Context, d: Done) {
        let now = self.now();
        if d.full {
            if let (Some((src, s)), Some((result, _))) = (&mut self.full, d.loaded)
                && *src == d.src
            {
                *s = to_slot(ctx, &d.src, true, result);
            }
            return;
        }
        let Some(t) = self.thumbs.get_mut(&d.src) else {
            return;
        };
        t.checking = false;
        t.checked = now;
        if let Some((result, stamp)) = d.loaded {
            t.slot = to_slot(ctx, &d.src, false, result);
            t.stamp = stamp;
        }
    }

    /// Run `job` now (inline) or hand it to the worker. `Err` if the worker is gone.
    fn dispatch(&mut self, ctx: &egui::Context, job: Job) -> Result<(), ()> {
        if !self.background {
            let d = run(job);
            self.apply(ctx, d);
            return Ok(());
        }
        if self.worker.is_none() {
            self.worker = Worker::spawn(ctx);
        }
        match &self.worker {
            Some(w) if w.jobs.send(job).is_ok() => Ok(()),
            _ => Err(()),
        }
    }

    /// The thumbnail for `src`; starts loading it the first time. Call only when it is visible.
    /// A file's thumbnail is checked again every [`RECHECK`] while it is drawn.
    pub fn thumb(&mut self, ctx: &egui::Context, src: &ImageSrc) -> Slot {
        let (frame, now) = (self.frame, self.now());
        if let Some(t) = self.thumbs.get_mut(src) {
            t.drawn = frame;
            let due = matches!(src, ImageSrc::File(_))
                && !matches!(t.slot, Slot::Pending)
                && !t.checking
                && now.duration_since(t.checked) >= RECHECK;
            if !due {
                schedule_recheck(ctx, src, t, now);
                return t.slot.clone();
            }
            t.checking = true;
            t.checked = now;
            let job = Job {
                src: src.clone(),
                full: false,
                max: Some((THUMB_MAX_W, THUMB_MAX_H)),
                recheck: Some(t.stamp),
            };
            if self.dispatch(ctx, job).is_err()
                && let Some(t) = self.thumbs.get_mut(src)
            {
                t.checking = false;
            }
            return self.thumbs.get(src).map_or(Slot::Pending, |t| {
                schedule_recheck(ctx, src, t, now);
                t.slot.clone()
            });
        }
        let first = match src {
            ImageSrc::Unreadable(why) => Slot::Failed(why.clone()),
            _ => Slot::Pending,
        };
        self.thumbs.insert(
            src.clone(),
            Thumb {
                slot: first.clone(),
                drawn: frame,
                stamp: None,
                checked: now,
                checking: false,
            },
        );
        if matches!(first, Slot::Failed(_)) {
            return first;
        }
        self.loads += 1;
        let job = Job {
            src: src.clone(),
            full: false,
            max: Some((THUMB_MAX_W, THUMB_MAX_H)),
            recheck: None,
        };
        if self.dispatch(ctx, job).is_err()
            && let Some(t) = self.thumbs.get_mut(src)
        {
            t.slot = Slot::Failed("the image reader stopped".into());
        }
        self.thumbs.get(src).map_or(Slot::Pending, |t| {
            schedule_recheck(ctx, src, t, now);
            t.slot.clone()
        })
    }

    /// The thumbnail state for `src` if it was ever requested (never starts a load).
    pub fn peek(&self, src: &ImageSrc) -> Option<Slot> {
        self.thumbs.get(src).map(|t| t.slot.clone())
    }

    /// The full-size image for `src` (replaces any other one held), no larger than
    /// [`full_side`] allows.
    pub fn full(&mut self, ctx: &egui::Context, src: &ImageSrc) -> Slot {
        if let Some((held, s)) = &self.full
            && held == src
        {
            return s.clone();
        }
        let first = match src {
            ImageSrc::Unreadable(why) => Slot::Failed(why.clone()),
            _ => Slot::Pending,
        };
        self.full = Some((src.clone(), first.clone()));
        if matches!(first, Slot::Failed(_)) {
            return first;
        }
        let side = full_side(ctx);
        let job = Job {
            src: src.clone(),
            full: true,
            max: Some((side, side)),
            recheck: None,
        };
        if self.dispatch(ctx, job).is_err() {
            self.full = Some((src.clone(), Slot::Failed("the image reader stopped".into())));
        }
        self.full.as_ref().map_or(Slot::Pending, |(_, s)| s.clone())
    }

    /// Close the enlarged view and free its pixels.
    pub fn close(&mut self) {
        self.open = None;
        self.full = None;
    }
}

/// A drawn file thumbnail that failed (the file may not be written yet) or is being checked
/// asks for a frame when its next recheck is due, so the picture appears within [`RECHECK`] even
/// when nothing else repaints the window (an idle agent).
/// While a check is in flight it waits a whole [`RECHECK`]: the worker repaints when it answers,
/// and a check that overruns must not turn into a repaint every frame (a 0 ms delay).
fn schedule_recheck(ctx: &egui::Context, src: &ImageSrc, t: &Thumb, now: Instant) {
    if matches!(src, ImageSrc::File(_)) && (t.checking || matches!(t.slot, Slot::Failed(_))) {
        let wait = if t.checking {
            RECHECK
        } else {
            RECHECK.saturating_sub(now.saturating_duration_since(t.checked))
        };
        ctx.request_repaint_after(wait);
    }
}

fn to_slot(
    ctx: &egui::Context,
    src: &ImageSrc,
    full: bool,
    r: Result<egui::ColorImage, String>,
) -> Slot {
    match r {
        Ok(img) => {
            let name = format!("{}:{src:?}", if full { "full" } else { "thumb" });
            Slot::Ready(ctx.load_texture(name, img, egui::TextureOptions::LINEAR))
        }
        Err(why) => Slot::Failed(why),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD;

    fn png(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        image::RgbImage::from_pixel(w, h, image::Rgb([10, 200, 30]))
            .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
            .unwrap();
        out
    }

    /// The delays `schedule_recheck` asks for, on a fresh context.
    fn recheck_delays(t: &Thumb, now: Instant) -> Vec<Duration> {
        let ctx = egui::Context::default();
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = seen.clone();
        ctx.set_request_repaint_callback(move |i| sink.lock().unwrap().push(i.delay));
        schedule_recheck(&ctx, &ImageSrc::File("/x/a.png".into()), t, now);
        seen.lock().unwrap().clone()
    }

    /// A check that overruns RECHECK never asks for a 0 ms repaint (a busy loop).
    #[test]
    fn an_overrunning_check_waits_a_whole_recheck() {
        let now = Instant::now() + RECHECK * 10;
        let thumb = |checking: bool, ago: Duration| Thumb {
            slot: Slot::Failed("not there yet".into()),
            drawn: 0,
            stamp: None,
            checked: now - ago,
            checking,
        };
        assert_eq!(
            recheck_delays(&thumb(true, RECHECK * 2), now),
            [RECHECK],
            "in flight and overdue: wait a whole RECHECK, never 0"
        );
        assert_eq!(
            recheck_delays(&thumb(false, Duration::from_secs(1)), now),
            [RECHECK - Duration::from_secs(1)],
            "failed and idle: the rest of the interval"
        );
    }

    #[test]
    fn host_paths() {
        let d = Some("Ubuntu");
        assert_eq!(
            host_path("/home/u/a.png", d, true).unwrap(),
            r"\\wsl.localhost\Ubuntu\home\u\a.png"
        );
        assert_eq!(host_path("/mnt/d/x/a.png", d, true).unwrap(), r"D:\x\a.png");
        assert_eq!(
            host_path("/mnt/data/a.png", d, true).unwrap(),
            r"\\wsl.localhost\Ubuntu\mnt\data\a.png"
        );
        assert_eq!(host_path("D:/x/a.png", d, true).unwrap(), r"D:\x\a.png");
        assert!(
            host_path("/home/u/a.png", None, true).is_err(),
            "no distro: not guessed"
        );
        assert!(host_path("rel/a.png", d, true).is_err());
        assert_eq!(
            host_path("/home/u/a.png", None, false).unwrap(),
            "/home/u/a.png"
        );
        assert!(host_path(r"D:\x\a.png", d, false).is_err());
    }

    #[test]
    fn embedded_bytes_only_from_the_exact_block() {
        let data = STANDARD.encode(png(3, 2));
        let line = format!(
            r#"{{"message":{{"content":[{{"type":"text","text":"x"}},{{"type":"image","source":{{"type":"base64","media_type":"image/png","data":"{data}"}}}},{{"type":"tool_result","content":[{{"type":"text","text":"t"}},{{"type":"image","source":{{"type":"base64","data":"{data}"}}}}]}}]}}}}"#
        );
        let l = line.as_bytes();
        assert_eq!(embedded_bytes(l, 1, None).unwrap(), png(3, 2));
        assert_eq!(embedded_bytes(l, 2, Some(1)).unwrap(), png(3, 2));
        assert!(embedded_bytes(l, 0, None).is_err(), "text block");
        assert!(embedded_bytes(l, 2, Some(0)).is_err(), "text part");
        assert!(embedded_bytes(l, 9, None).is_err(), "no such block");
        assert!(
            embedded_bytes(&l[..l.len() - 5], 1, None).is_err(),
            "cut line"
        );
        let url = br#"{"message":{"content":[{"type":"image","source":{"type":"url","url":"https://x"}}]}}"#;
        assert!(embedded_bytes(url, 0, None).is_err());
        let bad =
            br#"{"message":{"content":[{"type":"image","source":{"type":"base64","data":"!!"}}]}}"#;
        assert!(embedded_bytes(bad, 0, None).is_err());
        // A document block carries a base64 source too (a PDF): never decoded as an image.
        let doc = format!(
            r#"{{"message":{{"content":[{{"type":"document","source":{{"type":"base64","data":"{data}"}}}}]}}}}"#
        );
        assert!(embedded_bytes(doc.as_bytes(), 0, None).is_err());
    }

    #[test]
    fn rewritten_log_is_unavailable_not_a_guess() {
        let dir = std::env::temp_dir().join(format!("obs-v1-7-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("s.jsonl");
        let data = STANDARD.encode(png(2, 2));
        let first = r#"{"a":1}"#;
        let second = format!(
            r#"{{"message":{{"content":[{{"type":"image","source":{{"type":"base64","data":"{data}"}}}}]}}}}"#
        );
        std::fs::write(&log, format!("{first}\n{second}\n")).unwrap();
        let src = ImageSrc::Embedded {
            log: log.to_string_lossy().into_owned(),
            offset: first.len() as u64 + 1,
            len: second.len() as u64,
            block: 0,
            part: None,
        };
        assert!(load(&src, false).is_ok());
        std::fs::write(&log, format!("{{\"b\":22}}\n{second}\n")).unwrap(); // shifted by one byte
        assert!(load(&src, false).is_err());
        std::fs::write(&log, first).unwrap(); // truncated
        assert!(load(&src, false).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn decode_formats_and_thumbnail_size() {
        let t = decode(&png(900, 300), Some((THUMB_MAX_W, THUMB_MAX_H))).unwrap();
        assert_eq!(t.size, [480, 160]);
        let t = decode(&png(200, 600), Some((THUMB_MAX_W, THUMB_MAX_H))).unwrap();
        assert_eq!(t.size, [53, 160]);
        let t = decode(&png(40, 20), Some((THUMB_MAX_W, THUMB_MAX_H))).unwrap();
        assert_eq!(t.size, [40, 20], "small images are not enlarged");
        assert_eq!(decode(&png(900, 300), None).unwrap().size, [900, 300]);
        let gif = b"GIF89a\x01\x00\x01\x00\x00\x00\x00;";
        assert!(decode(gif, None).is_err());
        let bmp = b"BM\x1e\x00\x00\x00\x00\x00\x00\x00\x1a\x00\x00\x00";
        assert!(decode(bmp, None).is_err());
        assert!(decode(b"not an image", None).is_err());
        assert!(decode(&png(4, 4)[..20], None).is_err(), "truncated png");
    }

    #[test]
    fn load_downscales_thumbnails_and_keeps_full_size() {
        let dir = std::env::temp_dir().join(format!("obs-v1-7-load-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("big.png");
        std::fs::write(&p, png(1200, 800)).unwrap();
        let src = ImageSrc::File(p.display().to_string());
        assert_eq!(load(&src, false).unwrap().size, [240, 160]);
        assert_eq!(load(&src, true).unwrap().size, [1200, 800]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cache_keeps_at_most_max_thumbs() {
        let dir = std::env::temp_dir().join(format!("obs-v1-7-lru-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ctx = egui::Context::default();
        let mut c = ImageCache::inline();
        let p = dir.join("a.png");
        std::fs::write(&p, png(4, 4)).unwrap();
        for i in 0..(MAX_THUMBS + 25) {
            c.begin_frame(&ctx);
            // Entry 0 is the real file; the rest are distinct (missing) paths, cached as failed.
            let src = if i == 0 {
                ImageSrc::File(p.display().to_string())
            } else {
                ImageSrc::File(format!("{}?{i}", p.display()))
            };
            let _ = c.thumb(&ctx, &src);
        }
        c.begin_frame(&ctx);
        assert!(c.thumbs.len() <= MAX_THUMBS, "{}", c.thumbs.len());
        // The newest survived, the oldest went.
        assert!(c.thumbs.contains_key(&ImageSrc::File(format!(
            "{}?{}",
            p.display(),
            MAX_THUMBS + 24
        ))));
        assert!(
            !c.thumbs
                .contains_key(&ImageSrc::File(p.display().to_string()))
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("obs-v1-7-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn ready_size(s: Slot) -> Option<[usize; 2]> {
        match s {
            Slot::Ready(t) => Some(t.size()),
            _ => None,
        }
    }

    #[test]
    fn missing_file_appears_once_written_within_the_recheck() {
        let dir = tmp("later");
        let p = dir.join("later.png");
        let src = ImageSrc::File(p.display().to_string());
        let ctx = egui::Context::default();
        let mut c = ImageCache::inline();
        c.begin_frame(&ctx);
        assert!(
            matches!(c.thumb(&ctx, &src), Slot::Failed(_)),
            "missing at first"
        );
        std::fs::write(&p, png(4, 4)).unwrap();
        c.begin_frame(&ctx);
        assert!(
            matches!(c.thumb(&ctx, &src), Slot::Failed(_)),
            "not read again before RECHECK (no disk read every frame)"
        );
        c.advance_clock(RECHECK);
        c.begin_frame(&ctx);
        assert_eq!(ready_size(c.thumb(&ctx, &src)), Some([4, 4]));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn overwritten_file_shows_the_new_image() {
        let dir = tmp("over");
        let p = dir.join("shot.png");
        std::fs::write(&p, png(4, 4)).unwrap();
        let src = ImageSrc::File(p.display().to_string());
        let ctx = egui::Context::default();
        let mut c = ImageCache::inline();
        c.begin_frame(&ctx);
        assert_eq!(ready_size(c.thumb(&ctx, &src)), Some([4, 4]));
        std::fs::write(&p, png(6, 3)).unwrap();
        c.advance_clock(RECHECK);
        c.begin_frame(&ctx);
        assert_eq!(ready_size(c.thumb(&ctx, &src)), Some([6, 3]), "new pixels");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unchanged_file_keeps_its_texture() {
        let dir = tmp("same");
        let p = dir.join("same.png");
        std::fs::write(&p, png(4, 4)).unwrap();
        let src = ImageSrc::File(p.display().to_string());
        let ctx = egui::Context::default();
        let mut c = ImageCache::inline();
        c.begin_frame(&ctx);
        let Slot::Ready(a) = c.thumb(&ctx, &src) else {
            panic!("not loaded")
        };
        c.advance_clock(RECHECK);
        c.begin_frame(&ctx);
        let Slot::Ready(b) = c.thumb(&ctx, &src) else {
            panic!("lost on recheck")
        };
        assert_eq!(a.id(), b.id(), "an unchanged file is not decoded again");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn embedded_image_is_never_retried() {
        let dir = tmp("emb");
        let log = dir.join("s.jsonl");
        let line = format!(
            r#"{{"message":{{"content":[{{"type":"image","source":{{"type":"base64","data":"{}"}}}}]}}}}"#,
            STANDARD.encode(png(3, 3))
        );
        let src = ImageSrc::Embedded {
            log: log.display().to_string(),
            offset: 0,
            len: line.len() as u64,
            block: 0,
            part: None,
        };
        let ctx = egui::Context::default();
        let mut c = ImageCache::inline();
        c.begin_frame(&ctx);
        assert!(matches!(c.thumb(&ctx, &src), Slot::Failed(_)), "no log yet");
        std::fs::write(&log, &line).unwrap();
        c.advance_clock(RECHECK * 3);
        c.begin_frame(&ctx);
        assert!(
            matches!(c.thumb(&ctx, &src), Slot::Failed(_)),
            "embedded: never retried"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One frame with this GPU limit and window size, so `ctx.input` reports them.
    fn ctx_with(max_texture_side: usize, window: egui::Vec2) -> egui::Context {
        let ctx = egui::Context::default();
        let raw = egui::RawInput {
            max_texture_side: Some(max_texture_side),
            screen_rect: Some(egui::Rect::from_min_size(egui::Pos2::ZERO, window)),
            ..Default::default()
        };
        let mut out = ctx.run_ui(raw, |_| {});
        out.textures_delta.clear();
        ctx
    }

    #[test]
    fn enlarged_texture_fits_the_gpu_limit() {
        let dir = tmp("gpu");
        let p = dir.join("wide.png");
        std::fs::write(&p, png(9000, 8)).unwrap();
        let src = ImageSrc::File(p.display().to_string());
        // A window wider than the GPU limit: only the GPU limit binds.
        let ctx = ctx_with(8192, egui::vec2(12_000.0, 800.0));
        assert_eq!(full_side(&ctx), 8192);
        let mut c = ImageCache::inline();
        let size = ready_size(c.full(&ctx, &src)).expect("loads, does not panic");
        assert!(size[0] <= 8192 && size[1] >= 1, "{size:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enlarged_texture_is_no_bigger_than_the_window() {
        let dir = tmp("win");
        let p = dir.join("big.png");
        std::fs::write(&p, png(3000, 1500)).unwrap();
        let src = ImageSrc::File(p.display().to_string());
        let ctx = ctx_with(16_384, egui::vec2(1000.0, 600.0));
        assert_eq!(full_side(&ctx), 1000);
        let mut c = ImageCache::inline();
        assert_eq!(ready_size(c.full(&ctx, &src)), Some([1000, 500]));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn background_worker_rechecks_a_missing_file() {
        let dir = tmp("bg-later");
        let p = dir.join("later.png");
        let src = ImageSrc::File(p.display().to_string());
        let ctx = egui::Context::default();
        let mut c = ImageCache::background();
        let settle = |c: &mut ImageCache, want_ready: bool| {
            let t0 = std::time::Instant::now();
            loop {
                c.begin_frame(&ctx);
                let s = c.thumb(&ctx, &src);
                if matches!(s, Slot::Ready(_)) == want_ready && !matches!(s, Slot::Pending) {
                    return;
                }
                assert!(t0.elapsed().as_secs() < 10, "worker never answered");
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        };
        settle(&mut c, false);
        std::fs::write(&p, png(4, 4)).unwrap();
        c.advance_clock(RECHECK);
        settle(&mut c, true);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn background_worker_delivers() {
        let dir = std::env::temp_dir().join(format!("obs-v1-7-bg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("a.png");
        std::fs::write(&p, png(5, 5)).unwrap();
        let ctx = egui::Context::default();
        let mut c = ImageCache::background();
        let src = ImageSrc::File(p.display().to_string());
        assert!(matches!(c.thumb(&ctx, &src), Slot::Pending));
        let t0 = std::time::Instant::now();
        loop {
            c.begin_frame(&ctx);
            if let Slot::Ready(_) = c.thumb(&ctx, &src) {
                break;
            }
            assert!(t0.elapsed().as_secs() < 10, "worker never delivered");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
