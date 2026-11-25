#!/usr/bin/env bash
# The Station's shell scripts, moved into the kit repo: station/scripts/deploy.sh and env.sh must judge ONLY the
# Station folder (a dirty or unpushed file elsewhere in the kit must not refuse a deploy), and env.sh must name its
# cargo target dir after the Station. Stand-ins only: deploy.sh runs with --dry-run (it prints every cargo step, it
# calls none), so this suite never needs cargo, Rust, a network or a Windows host.
# Run: bash tests/station-scripts.test.sh   (needs bash, git, sha256sum, realpath)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home"; mkdir -p "$HOME"
export OBSERVATORY_RUST_DIR="$SB/rust"
unset CARGO_TARGET_DIR OBSERVATORY_INSTALL_ROOT OBSERVATORY_DEPLOY_CONF DEPLOY_GATE_CMD
GIT="git -c user.name=t -c user.email=t@example.com"

# a kit-shaped repo: README.md at the root plus station/ with the real scripts and a Cargo.toml version line
git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/main" 2>/dev/null
mkdir -p "$SB/main/station/scripts"
cp "$ROOT/station/scripts/deploy.sh" "$ROOT/station/scripts/env.sh" "$ROOT/station/scripts/lib-shortcut.sh" "$SB/main/station/scripts/"
printf '[workspace.package]\nversion = "9.9.9"\n' > "$SB/main/station/Cargo.toml"
echo kit > "$SB/main/README.md"
( cd "$SB/main" && git add -A && $GIT commit -qm init && git push -q origin HEAD:main && git fetch -q origin ) 2>/dev/null

# dry <dir>: run the Station's deploy.sh in a dry run from <dir>; sets OUT and RC
dry() { OUT="$(cd "$1/station" && bash scripts/deploy.sh --dry-run --no-shortcut --install-root "$HOME/inst" --bridge-dir "$HOME/bin" 2>&1)"; RC=$?; }
reset_main() { ( cd "$SB/main" && git checkout -q -- . 2>/dev/null; git clean -fdq; git reset -q --hard origin/main ) 2>/dev/null; }

# 1. clean and landed: accepted
dry "$SB/main"
[ "$RC" -eq 0 ] && ok || bad "1 a clean landed tree was refused (rc=$RC): $OUT"
echo "$OUT" | grep -q 'ok: clean, .* is on origin/main' && ok || bad "1 no 'ok: clean ... on origin/main' line"

# 2. dirt OUTSIDE station/ (a changed root file and an untracked one): still accepted
echo changed >> "$SB/main/README.md"; echo x > "$SB/main/stray.txt"
dry "$SB/main"
[ "$RC" -eq 0 ] && ok || bad "2 a dirty file outside station/ refused the deploy (rc=$RC): $OUT"
echo "$OUT" | grep -qi 'dirty' && bad "2 dirt outside station/ was reported: $OUT" || ok
reset_main

# 3. dirt INSIDE station/: refused (dry run exits 3 and names the folder)
echo '# edit' >> "$SB/main/station/Cargo.toml"
dry "$SB/main"
[ "$RC" -eq 3 ] && ok || bad "3 a dirty Station folder was not refused (rc=$RC): $OUT"
echo "$OUT" | grep -q 'the Station folder is dirty' && ok || bad "3 the refusal does not name the Station folder"
reset_main

# 4. an unpushed commit OUTSIDE station/: the Station's tree equals main's, so it counts as landed
echo more >> "$SB/main/README.md"; ( cd "$SB/main" && git add README.md && $GIT commit -qm "kit-only change" )
dry "$SB/main"
[ "$RC" -eq 0 ] && ok || bad "4 an unpushed commit outside station/ refused the deploy (rc=$RC): $OUT"
echo "$OUT" | grep -q 'is on origin/main' && ok || bad "4 not reported as on origin/main"
reset_main

# 5. an unpushed commit INSIDE station/: not landed, refused
echo '# local' >> "$SB/main/station/Cargo.toml"; ( cd "$SB/main" && git add station/Cargo.toml && $GIT commit -qm "station change" )
dry "$SB/main"
[ "$RC" -eq 3 ] && ok || bad "5 an unpushed Station commit was not refused (rc=$RC): $OUT"
echo "$OUT" | grep -q 'is not on origin/main' && ok || bad "5 the refusal does not say 'not on origin/main'"
reset_main

# 5b. HEAD is an ancestor of main but main's Station folder has moved on (an older checkout): landed by ancestry
( cd "$SB/main" && git checkout -q -- . 2>/dev/null; true )
git clone -q "$SB/origin.git" "$SB/pusher" 2>/dev/null
( cd "$SB/pusher" && echo '# newer' >> station/Cargo.toml && git add station/Cargo.toml && $GIT commit -qm newer && git push -q origin HEAD:main ) 2>/dev/null
( cd "$SB/main" && git fetch -q origin ) 2>/dev/null
dry "$SB/main"
[ "$RC" -eq 0 ] && ok || bad "5b an old checkout whose HEAD is on main was refused (rc=$RC): $OUT"
echo "$OUT" | grep -q 'ok: clean, .* is on origin/main' && ok || bad "5b not reported as on origin/main"
reset_main

# 6. the product name in what a user reads from the deploy; the old shortcut name is gone
dry "$SB/main"
echo "$OUT" | grep -q 'deploy: Orcastration Station 9.9.9' && ok || bad "6 the deploy banner does not say Orcastration Station"
grep -q 'Observatory.lnk' "$ROOT/station/scripts/deploy.sh" && bad "6 deploy.sh still names Observatory.lnk" || ok
grep -q 'Orcastration Station.lnk' "$ROOT/station/scripts/deploy.sh" && ok || bad "6 deploy.sh does not name the new shortcut"

# 7. env.sh: the target dir is station-<tree folder>-<8 hex>, one per tree, created on sourcing
td() { ( cd "$1/station" && . scripts/env.sh >/dev/null 2>&1 && echo "$CARGO_TARGET_DIR" ); }
ta="$(td "$SB/main")"
case "$ta" in "$SB/rust/targets/station-main-"????????) ok ;; *) bad "7 target dir shape: '$ta'" ;; esac
[ -d "$ta" ] && ok || bad "7 target dir not created"
git clone -q "$SB/origin.git" "$SB/other" 2>/dev/null; mkdir -p "$SB/other/station/scripts"
cp "$ROOT/station/scripts/env.sh" "$SB/other/station/scripts/"
tb="$(td "$SB/other")"
[ -n "$tb" ] && [ "$ta" != "$tb" ] && ok || bad "7 two trees share a target dir: '$ta' '$tb'"
[ "$(cd "$SB/main/station/scripts" && . env.sh >/dev/null 2>&1 && echo "$CARGO_TARGET_DIR")" = "$ta" ] && ok || bad "7 a subfolder gives another dir"

# 8. the shortcut PowerShell: a single quote inside a path is doubled, so it cannot end the string early or run code
. "$ROOT/station/scripts/lib-shortcut.sh"
ps="$(shortcut_ps "D:\\apps\\O'Brien\\Orcastration Station.lnk" "D:\\apps\\O'Brien\\observatory.exe" "D:\\apps\\O'Brien")"
case "$ps" in *"CreateShortcut('D:\\apps\\O''Brien\\Orcastration Station.lnk')"*) ok ;; *) bad "8 the .lnk path is not quoted: $ps" ;; esac
case "$ps" in *"TargetPath='D:\\apps\\O''Brien\\observatory.exe'"*) ok ;; *) bad "8 the exe path is not quoted: $ps" ;; esac
case "$ps" in *"WorkingDirectory='D:\\apps\\O''Brien'"*) ok ;; *) bad "8 the working dir is not quoted: $ps" ;; esac
inj="$(shortcut_ps "D:\\a" "x'; calc; '" "D:\\a")"
case "$inj" in *"TargetPath='x''; calc; '''"*) ok ;; *) bad "8 an injected quote ends the string: $inj" ;; esac
plain="$(shortcut_ps "D:\\a\\s.lnk" "D:\\a\\o.exe" "D:\\a")"
case "$plain" in *"CreateShortcut('D:\\a\\s.lnk')"*"TargetPath='D:\\a\\o.exe'"*) ok ;; *) bad "8 a plain path changed: $plain" ;; esac

# 9. a real run with stand-in cargo and a stand-in gate: the re-check after the gate looks at station/ ONLY
cat > "$SB/bin-cargo" <<'CARGO'
#!/bin/sh
echo "cargo $*" >> "$STAND_LOG"
case "$*" in *"-p observatory-app"*) mkdir -p "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release" && echo exe > "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/observatory.exe" ;; esac
exit 0
CARGO
mkdir -p "$SB/standins"; cp "$SB/bin-cargo" "$SB/standins/cargo"; chmod +x "$SB/standins/cargo"
export STAND_LOG="$SB/cargo.log"
real() {  # <gate command>: a real deploy run (stand-in cargo, test-hook gate), from a clean main checkout
  reset_main; : > "$STAND_LOG"
  OUT="$(cd "$SB/main/station" && PATH="$SB/standins:$PATH" DEPLOY_GATE_CMD="$1" bash scripts/deploy.sh --no-shortcut --install-root "$HOME/inst2" --bridge-dir "$HOME/bin2" 2>&1)"; RC=$?
}
real 'touch ../outside.txt; echo "GATE PASS (3 tests)"'
[ "$RC" -eq 0 ] && ok || bad "9 a change OUTSIDE station/ during the gate refused the deploy (rc=$RC): $OUT"
echo "$OUT" | grep -q 'DEPLOYED Orcastration Station 9.9.9' && ok || bad "9 no DEPLOYED line: $OUT"
real 'touch new-file.txt; echo "GATE PASS (3 tests)"'
[ "$RC" -ne 0 ] && ok || bad "9 a change INSIDE station/ during the gate did not refuse"
echo "$OUT" | grep -q 'the Station folder became dirty during the gate' && ok || bad "9 the refusal does not name the Station folder: $OUT"
real 'echo "GATE PASS (3 tests)"'
grep -c -- 'cargo build --release --locked' "$STAND_LOG" | grep -qx 1 && ok || bad "9 the app build did not pass --locked: $(cat "$STAND_LOG")"
[ "$(grep -c 'cargo build.*--locked' "$ROOT/station/scripts/deploy.sh")" -eq 2 ] && ok || bad "9 deploy.sh does not pass --locked on both cargo build lines"

# 11. the workflow pins what must not float: the Rust version, and the cargo-audit install that survives a cache hit
W="$ROOT/.github/workflows/test.yml"
grep -qE '^ +RUST_VERSION: "1\.[0-9]+\.[0-9]+"' "$W" && ok || bad "11 test.yml has no pinned RUST_VERSION"
grep -qE 'rustup (toolchain install|default) +stable' "$W" && bad "11 test.yml installs the floating 'stable'" || ok
grep -q 'cargo install cargo-audit --version 0.23.0 --locked --force' "$W" && ok || bad "11 test.yml's cargo-audit install is not pinned and forced"
grep -q "cargo audit --version.*grep -qF '0.23.0' ||" "$W" && ok || bad "11 the cargo-audit install is not skipped on a version match"

echo "station-scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
