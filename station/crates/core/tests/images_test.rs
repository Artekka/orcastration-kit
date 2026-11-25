//! Images in the chat, by reference. Fixtures: `synthetic_image_refs.jsonl` and
//! `synthetic_images.jsonl`, both written from invented values — see `fixtures/README.md`.
//! Expected paths are literals derived by hand from the fixture lines; offsets are checked against
//! the raw file bytes with serde_json, never through the parser under test.

use observatory_core::lines::LineBuffer;
use observatory_core::session::{ImageRef, bash_image_paths, is_image_path, resolve_path};
use observatory_core::{ItemKind, Session};
use serde_json::Value;

const OBS: &str = include_str!("fixtures/synthetic_image_refs.jsonl");
const SYN: &str = include_str!("fixtures/synthetic_images.jsonl");

/// Parse `text` the way the bridge does: absolute offsets, fed in `chunk`-byte reads.
fn parse(text: &str, chunk: usize) -> Session {
    let mut s = Session::new("-home-user-my-app", "img");
    s.meta.log_path = Some("/log.jsonl".into());
    s.home = Some("/home/user".into());
    let mut b = LineBuffer::new();
    for part in text.as_bytes().chunks(chunk) {
        for l in b.push_lines(part) {
            s.push_line_at(&l.text, l.offset, l.len);
        }
    }
    s
}

fn images(k: &ItemKind) -> &[ImageRef] {
    match k {
        ItemKind::UserText { images, .. } => images,
        ItemKind::ToolCall(c) => &c.images,
        _ => &[],
    }
}

/// Independent read-back: the bytes at the ref's offset are one JSON line whose block (and part)
/// is a base64 image of the ref's media type.
fn resolves(text: &str, r: &ImageRef) -> bool {
    let ImageRef::Embedded {
        line_offset: Some(off),
        line_len,
        block,
        part,
        media_type,
        ..
    } = r
    else {
        return false;
    };
    let bytes = text.as_bytes();
    let (a, b) = (*off as usize, (*off + *line_len) as usize);
    if b > bytes.len() || (b < bytes.len() && bytes[b] != b'\n' && bytes[b] != b'\r') {
        return false;
    }
    let Ok(v) = serde_json::from_slice::<Value>(&bytes[a..b]) else {
        return false;
    };
    let mut img = &v["message"]["content"][*block];
    if let Some(p) = part {
        img = &img["content"][*p];
    }
    img["type"] == "image"
        && img["source"]["type"] == "base64"
        && img["source"]["data"].is_string()
        && img["source"]["media_type"].as_str() == media_type.as_deref()
}

#[test]
fn pasted_images_are_refs_that_resolve_to_their_bytes() {
    let s = parse(OBS, 1 << 20);
    let ItemKind::UserText { text, images } = &s.items[0].kind else {
        panic!("{:?}", s.items[0].kind)
    };
    assert!(text.starts_with("Here are the screenshots."));
    let shape: Vec<_> = images
        .iter()
        .map(|r| match r {
            ImageRef::Embedded {
                block,
                part,
                media_type,
                path,
                ..
            } => (*block, *part, media_type.clone(), path.clone()),
            other => panic!("{other:?}"),
        })
        .collect();
    let png = Some("image/png".to_owned());
    assert_eq!(
        shape,
        vec![
            (1, None, png.clone(), None),
            (2, None, png, None),
            (3, None, Some("image/jpeg".into()), None)
        ]
    );
    for r in images {
        assert!(resolves(OBS, r), "{r:?}");
    }
}

#[test]
fn read_with_an_image_result_is_one_thumbnail_not_two() {
    let s = parse(OBS, 1 << 20);
    let ItemKind::ToolCall(c) = &s.items[1].kind else {
        panic!("{:?}", s.items[1].kind)
    };
    assert_eq!(c.name, "Read");
    assert_eq!(c.images.len(), 1, "{:?}", c.images);
    let r = &c.images[0];
    assert!(
        matches!(
            r,
            ImageRef::Embedded {
                block: 0,
                part: Some(0),
                ..
            }
        ),
        "the embedded image wins: {r:?}"
    );
    assert_eq!(
        r.path(),
        Some("/home/user/my-app/shots/after/narrow_dark.png"),
        "the read file is its caption"
    );
    assert!(resolves(OBS, r));
}

#[test]
fn bash_paths_resolve_against_the_record_cwd() {
    let s = parse(OBS, 1 << 20);
    let ItemKind::ToolCall(c) = &s.items[2].kind else {
        panic!()
    };
    assert_eq!(c.name, "Bash");
    let paths: Vec<_> = c.images.iter().map(|r| r.path().unwrap()).collect();
    // The command starts `cd <scratchpad> && python3 -c "…c.save('mini.png')…"`: the relative
    // `mini.png` lands in the scratchpad it was written to, not in the record's cwd.
    assert_eq!(
        paths,
        [
            "/home/user/my-app/shots/3.png",
            "/tmp/claude-1000/-home-user-my-app/7f1430eb-eb93-5fca-b7e1-34614e29f112/scratchpad/mini.png",
            "/home/user/my-app/shots/1.png",
        ]
    );
    assert!(c.images.iter().all(|r| matches!(r, ImageRef::File { .. })));
}

#[test]
fn api_request_blob_lines_yield_nothing() {
    let s = parse(OBS, 1 << 20);
    assert_eq!(
        s.items.len(),
        3,
        "user text, Read, Bash; the blob adds no item"
    );
    let blob = OBS.lines().nth(4).unwrap();
    assert!(blob.contains("\"api-request-blob\"") && blob.contains("\"image\""));
    let alone = parse(&format!("{blob}\n"), 1 << 20);
    assert!(alone.items.is_empty());
}

#[test]
fn offsets_stay_absolute_when_lines_split_across_reads() {
    let whole = parse(OBS, 1 << 20);
    for chunk in [7, 1000, 4096] {
        let split = parse(OBS, chunk);
        assert_eq!(split.items, whole.items, "chunk {chunk}");
    }
    // The later lines' refs (Read result on line 3) still resolve after 7-byte reads.
    let split = parse(OBS, 7);
    let all: Vec<_> = split.items.iter().flat_map(|i| images(&i.kind)).collect();
    let embedded: Vec<_> = all
        .iter()
        .filter(|r| matches!(r, ImageRef::Embedded { .. }))
        .collect();
    assert_eq!(embedded.len(), 4);
    for r in embedded {
        assert!(resolves(OBS, r), "{r:?}");
    }
}

#[test]
fn synthetic_named_files_and_malformed_blocks() {
    let s = parse(SYN, 1 << 20);
    let call = |id: &str| {
        s.items
            .iter()
            .find_map(|i| match &i.kind {
                ItemKind::ToolCall(c) if c.id == id => Some(c),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no call {id}"))
    };
    let paths = |id: &str| -> Vec<String> {
        call(id)
            .images
            .iter()
            .map(|r| r.path().unwrap_or("<none>").to_owned())
            .collect()
    };
    assert_eq!(
        paths("t1"),
        ["/home/user/proj/out/A.PNG"],
        "Write, any case"
    );
    assert_eq!(
        paths("t2"),
        ["/home/user/proj/img/b.webp"],
        "Edit, relative"
    );
    assert_eq!(
        paths("t3"),
        ["D:\\pics\\output\\c.jpg"],
        "Windows path kept; url / sourceless result parts are not readable images"
    );
    assert!(matches!(call("t3").images[0], ImageRef::File { .. }));
    assert_eq!(
        paths("t4"),
        [
            "/home/user/shots/d.jpeg",
            "/home/user/proj/e.jpg",
            "/home/user/proj/q.webp"
        ],
        "globs, braces and variables are skipped"
    );
    assert_eq!(
        paths("t5"),
        ["/home/user/proj/gone.png"],
        "error result: file stays"
    );
    let early = &call("t6").images;
    assert_eq!(early.len(), 1);
    assert!(
        matches!(&early[0], ImageRef::Embedded { path: Some(p), .. } if p == "/home/user/proj/early.png"),
        "a result that came first still wins: {early:?}"
    );
    assert!(resolves(SYN, &early[0]));
    assert!(call("t7").images.is_empty(), "Grep never names images");
    let odd = s
        .items
        .iter()
        .find_map(|i| match &i.kind {
            ItemKind::UserText { text, images } if text == "odd images" => Some(images),
            _ => None,
        })
        .unwrap();
    assert!(
        odd.is_empty(),
        "blocks without base64 data are not thumbnails"
    );
    assert_eq!(s.stats.unknown_blocks, 1, "the type:7 block");
    assert_eq!(s.stats.malformed, 0);
}

#[test]
fn path_helpers() {
    assert!(is_image_path("a.PNG") && is_image_path("/x/y.jpeg") && is_image_path("z.WebP"));
    assert!(!is_image_path(".png") && !is_image_path("a.dds") && !is_image_path("a.png.txt"));
    assert_eq!(
        resolve_path("../b/./c.png", Some("/w/a"), None).as_deref(),
        Some("/w/b/c.png")
    );
    assert_eq!(
        resolve_path("c.png", None, None),
        None,
        "no cwd: not guessed"
    );
    assert_eq!(
        resolve_path("~/c.png", Some("/w"), None),
        None,
        "no home: not guessed"
    );
    assert_eq!(resolve_path("~bob/c.png", Some("/w"), Some("/h")), None);
    assert_eq!(
        resolve_path("E:/shots/c.png", None, None).as_deref(),
        Some("E:/shots/c.png")
    );
    assert_eq!(
        bash(r#"convert "in.jpg" -resize 50% out.png>log; echo x.png=1 *.jpg"#),
        ["/w/in.jpg", "/w/out.png"],
        "x.png=1 is one word, not a file; a pattern is never a file"
    );
}

/// Bash image paths as the app gets them, from cwd `/w` with home `/h`.
fn bash(cmd: &str) -> Vec<String> {
    bash_image_paths(cmd, Some("/w"), Some("/h"))
}

#[test]
fn bash_relative_paths_follow_the_last_cd() {
    // Each separator: `&&`, `;`, newline.
    assert_eq!(
        bash("cd /other/dir && python shot.py --out shot.png"),
        ["/other/dir/shot.png"]
    );
    assert_eq!(
        bash("cd /a; x a.png\ncd b\ny b.png"),
        ["/a/a.png", "/a/b/b.png"]
    );
    assert_eq!(bash("a.png && cd ~/s && b.png"), ["/w/a.png", "/h/s/b.png"]);
    assert_eq!(
        bash("cd sub && cd ../t && c.png"),
        ["/w/t/c.png"],
        "relative cd from the cwd so far"
    );
    assert_eq!(bash("cd && c.png"), ["/h/c.png"], "bare cd goes home");
    assert_eq!(
        bash("cd /x && convert --out=o.png in.webp"),
        ["/x/o.png", "/x/in.webp"]
    );
    // Absolute paths never depend on a cd.
    assert_eq!(bash("cd $D && ls /abs/a.png"), ["/abs/a.png"]);
}

#[test]
fn bash_unfollowable_cd_drops_relative_paths() {
    for cmd in [
        "cd $OUT && convert a.png b.png",
        "cd \"$OUT\" && convert a.png b.png",
        "cd - && view a.png b.png",
        "pushd /x && view a.png b.png",
        "(cd /x && view a.png) && b.png",
        "false || cd /x; view a.png b.png",
        "ls | cd /x; view a.png b.png",
        "cd /x & view a.png b.png",
        "if true; then cd /x; fi; view a.png b.png",
        "sudo cd /x && view a.png b.png",
        "cd `pwd`/x && view a.png b.png",
        "cd /x/* && view a.png b.png",
    ] {
        assert_eq!(bash(cmd), Vec::<String>::new(), "{cmd}");
    }
    // Paths BEFORE the doubtful cd keep the cwd.
    assert_eq!(bash("view a.png && cd $X && view b.png"), ["/w/a.png"]);
    // An inline script that changes directory itself: its relative paths are dropped too.
    assert_eq!(
        bash("python -c \"import os; os.chdir('/q'); open('r.png'); open('/abs/s.png')\""),
        ["/abs/s.png"]
    );
}

#[test]
fn bash_quotes_heredocs_and_comments() {
    assert_eq!(
        bash(r#"cp "my shot.png" /tmp/b.png"#),
        ["/w/my shot.png", "/tmp/b.png"]
    );
    assert_eq!(bash("cp 'a b.png' c\\ d.png"), ["/w/a b.png", "/w/c d.png"]);
    assert_eq!(
        bash("cat <<EOF > notes.md\nsee foo.png\nEOF\nview bar.png"),
        ["/w/bar.png"]
    );
    assert_eq!(
        bash("cat <<-'X' >n\n\tfoo.png\n\tX\nview bar.png"),
        ["/w/bar.png"]
    );
    assert_eq!(
        bash("grep x <<< foo.png; echo hi # see c.png"),
        Vec::<String>::new()
    );
    assert_eq!(bash("ls docs/*.png; echo out.png"), ["/w/out.png"]);
    assert_eq!(
        bash("convert in.PNG -resize 50% out.webp"),
        ["/w/in.PNG", "/w/out.webp"]
    );
    assert_eq!(
        bash("view a.png &>log; view b.png"),
        ["/w/a.png", "/w/b.png"]
    );
    // Inline scripts: whole string literals only. Shapes seen in the live logs.
    assert_eq!(
        bash("cd /d && py -c \"for n in ('a_1.png','b_1.png'): Image.open(n)\""),
        ["/d/a_1.png", "/d/b_1.png"],
        "a tuple of literals is two files, not one token across the comma"
    );
    assert_eq!(
        bash("py -c \"D='/x'; a=Image.open(D+'/t.png'); b=Image.open(f'w-{n:02d}.png')\""),
        Vec::<String>::new(),
        "built-up names are expressions, never files"
    );
    assert_eq!(
        bash("py -c \"im.save(fp='o.png'); Image.open('/abs/i.png')\""),
        ["/w/o.png", "/abs/i.png"]
    );
    assert_eq!(
        bash("bash -c 'convert a.png b.png'"),
        ["/w/a.png", "/w/b.png"],
        "a quoted shell script is read as words"
    );
    // Patterns are never files: a quoted regex, brackets and `+` in code.
    assert_eq!(
        bash(r#"cd /d && grep -oE '/[^ ]+\.png' a.txt"#),
        Vec::<String>::new()
    );
    assert_eq!(
        bash(r#"grep -oE "g[0-9]+/out/ui-[0-9]+\.png|s01/x.png" R.md"#),
        ["/w/s01/x.png"],
        "only the whole alternative"
    );
    assert_eq!(
        bash(r#"py -c "x=['a.png', 'b.png']; y={'k': 'c.png'}""#),
        ["/w/a.png", "/w/b.png", "/w/c.png"]
    );
    // No cwd: relative paths are not guessed; absolute ones still count.
    assert_eq!(
        bash_image_paths("view a.png /z/b.png", None, None),
        ["/z/b.png"]
    );
}

/// A name that is only one piece of a longer path, a pattern, a file in another directory
/// or on another machine, or a literal `~`, is dropped (never shown as the wrong picture).
#[test]
fn bash_built_up_names_and_other_places_name_nothing() {
    for cmd in [
        // Code that builds a path from pieces.
        r#"python3 -c "print(os.path.join('/data', 'a.png'))""#,
        r#"python3 -c "os.path.join(D,'a.png')""#,
        r#"node -e "path.join(__dirname, 'a.png')""#,
        r#"python3 -c "Path('/data').joinpath('a.png')""#,
        r#"python3 -c "for f in ['d.png', 'e.png']: Image.open(os.path.join(SRC, f))""#,
        r#"python3 -c "for f in ('d.png', 'e.png'): Image.open(os.path.join(SRC, f))""#,
        // A literal next to an operator, another literal, or a method call.
        r#"python3 -c "p = Path('/data') / 'b.png'""#,
        r#"python3 -c "p = (Path.home() / 'b.png')""#,
        r#"python3 -c "D='/data/'; Image.open(D + 'c.png')""#,
        r#"python3 -c "Image.open('c.png' + suffix)""#,
        r#"python3 -c "Image.open('/data/%s' % 'c.png')""#,
        r#"python3 -c "Image.open('/data/' 'f.png')""#,
        r#"python3 -c "Image.open('/data/'  \"f.png\")""#,
        r#"python3 -c "Image.open('c.png'.replace('c', 'd'))""#,
        // Code that runs in another directory, or a non-local name.
        r#"python3 -c "subprocess.run(['ls', 'w.png'], cwd='/data')""#,
        r#"python3 -c "open('http://x/u.png')""#,
        // Python never expands `~`.
        r#"python3 -c "open('~/t.png')""#,
        // A command run in another directory.
        "make -C /data OUT=l.png",
        "git -C /data add m.png",
        "git show HEAD:j.png",
        "tar -C /data -xf a.tar m.png",
        "env -C /data ls m.png",
        "env --chdir=/data ls m.png",
        "npm --prefix /data run x -- m.png",
        "uv --directory /data run x m.png",
        r#"env -C /data python3 -c "open('a.png')""#,
        // Patterns.
        "find shots -name g.png",
        "find . -iname 'g.png' -o -path g.png",
        // Text or a script that may cd.
        r#"eval "cd /data"; ls h.png"#,
        "cd /data; source env.sh; ls x.png",
        "cd /data; . env.sh; ls x.png",
        // Another machine or a container.
        "ssh box ls /srv/r.png r.png",
        "docker exec c ls /srv/r.png",
        "kubectl exec p -- ls /srv/r.png",
        // A quoted or escaped `~` is literal: it means ./~/i.png.
        r#"ls "~/i.png""#,
        "ls '~/i.png'",
        r"ls \~/i.png",
        // A cd that may fail while the script goes on.
        "cd /data || true; ls s.png",
    ] {
        assert_eq!(bash(cmd), Vec::<String>::new(), "{cmd}");
    }
}

#[test]
fn bash_plain_names_next_to_the_dropped_forms_still_count() {
    let cases: [(&str, &[&str]); 12] = [
        (
            r#"python3 -c "Image.open(os.path.expanduser('~/t.png'))""#,
            &["/h/t.png"],
        ),
        (r#"python3 -c "Image.open('/abs/k.png')""#, &["/abs/k.png"]),
        (
            r#"python3 -c "shutil.copy('a.png', 'b.png')""#,
            &["/w/a.png", "/w/b.png"],
        ),
        (
            r#"python3 -c "os.path.join(D, x); open('/abs/j.png')""#,
            &["/abs/j.png"],
        ),
        ("git -C /data show HEAD:j.png > k.png", &["/w/k.png"]),
        ("ssh box cat /srv/r.png > here.png", &["/w/here.png"]),
        ("scp box:r.png ./s.png", &["/w/s.png"]),
        ("find shots -newer ref.png", &["/w/ref.png"]),
        ("grep -C 3 x a.png", &["/w/a.png"]),
        // `~"/q.png"` is `./~/q.png` to bash (R1): only the plain `~/k.png` counts.
        ("ls ~/k.png ~\"/q.png\"", &["/h/k.png"]),
        ("cd /data || exit 1; ls k.png", &["/data/k.png"]),
        ("cd /data && bash -c 'ls w.png'", &["/data/w.png"]),
    ];
    for (cmd, want) in cases {
        assert_eq!(bash(cmd), want, "{cmd}");
    }
}

/// Bash expands a `~` only when nothing from it up to the first unquoted `/` is
/// quoted. Expected values are what `printf '[%s]\n' <form>` printed in bash (HOME=/h).
#[test]
fn bash_tilde_with_any_quoted_char_before_the_slash_is_literal() {
    for (cmd, want) in [
        ("ls ~\"/q.png\"", &[][..]),
        ("ls \"~\"/q.png", &[]),
        ("ls ~'/'q.png", &[]),
        ("ls ~\\/q.png", &[]),
        ("ls ~/\"q.png\"", &["/h/q.png"]),
        ("ls ~/'q'.png", &["/h/q.png"]),
    ] {
        assert_eq!(bash(cmd), want, "{cmd}");
    }
}

/// A quoted `~` in a cd target means `./~/…`: the cd is not followed, so relative
/// names after it are dropped (absolute ones still count).
#[test]
fn bash_cd_to_a_quoted_tilde_is_not_followed() {
    for (cmd, want) in [
        ("cd \"~/sub\" && ls a.png", &[][..]),
        ("cd ~\"/sub\" && ls a.png", &[]),
        ("cd '~'/sub; ls a.png", &[]),
        ("cd \"~/sub\" && ls /abs/b.png", &["/abs/b.png"]),
        ("cd ~/\"sub\" && ls a.png", &["/h/sub/a.png"]),
        ("cd ~/sub && ls a.png", &["/h/sub/a.png"]),
    ] {
        assert_eq!(bash(cmd), want, "{cmd}");
    }
}

/// After `=`, bash expands `~` only in an assignment-shaped word (`NAME=`, `NAME+=`,
/// unquoted), even as an argument; `--out=~/a.png` and friends keep a literal `~`.
#[test]
fn bash_tilde_after_equals_only_in_assignment_shaped_words() {
    for (cmd, want) in [
        ("convert x.png --out=~/a.png", &["/w/x.png"][..]),
        ("tool -o=~/a.png", &[]),
        ("tool x=y=~/a.png", &[]),
        ("tool \"x\"=~/a.png", &[]),
        ("tool x\\=~/a.png", &[]),
        ("tool 1x=~/a.png", &[]),
        ("tool O\"UT\"=~/a.png", &[]),
        ("tool OUT=\"~\"/a.png", &[]),
        ("tool OUT=~\"/a.png\"", &[]),
        ("make OUT=~/a.png", &["/h/a.png"]),
        ("tool X+=~/a.png", &["/h/a.png"]),
        ("OUT=~/a.png tool", &["/h/a.png"]),
    ] {
        assert_eq!(bash(cmd), want, "{cmd}");
    }
}

/// Redirections after a cd are not its arguments.
#[test]
fn bash_cd_with_redirections_is_followed() {
    for (cmd, want) in [
        ("cd /data 2>/dev/null && ls s.png", "/data/s.png"),
        ("cd /data >/dev/null 2>&1 && ls s.png", "/data/s.png"),
        ("cd /data &>/dev/null; ls s.png", "/data/s.png"),
        ("cd /data 2> err.log; ls s.png", "/data/s.png"),
    ] {
        assert_eq!(bash(cmd), [want], "{cmd}");
    }
    // Still unsure: a pipeline, two targets.
    assert_eq!(
        bash("cd /data 2>/dev/null | cat; ls s.png"),
        Vec::<String>::new()
    );
    assert_eq!(
        bash("cd /data x 2>/dev/null; ls s.png"),
        Vec::<String>::new()
    );
}

/// A bare word with `+` in code is an expression (`ab+.png` in a regex), not a name.
#[test]
fn bash_plus_in_code_is_an_expression() {
    assert_eq!(bash("bash -c 'grep -E ab+.png log'"), Vec::<String>::new());
    assert_eq!(
        bash("bash -c 'ls ab.png'"),
        ["/w/ab.png"],
        "same shape without +"
    );
}

#[test]
fn image_refs_round_trip_on_the_wire_without_bytes() {
    let s = parse(OBS, 1 << 20);
    let line = observatory_core::Frame::Session {
        project: "my-app".into(),
        session: Box::new(s.clone()),
    }
    .to_line();
    let tiny = OBS
        .split("\"data\": \"")
        .nth(1)
        .and_then(|r| r.split('"').next())
        .unwrap();
    assert!(tiny.len() > 20);
    assert!(!line.contains(tiny), "no image bytes in frames");
    assert!(line.contains(r#""source":"embedded""#) && line.contains(r#""source":"file""#));
    let back = observatory_core::Frame::from_line(&line).unwrap();
    let observatory_core::Frame::Session { session, .. } = back else {
        panic!()
    };
    assert_eq!(session.items, s.items);
    assert_eq!(session.meta.log_path.as_deref(), Some("/log.jsonl"));
}
