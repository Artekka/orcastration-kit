#!/usr/bin/env bash
# Orcastration Station deploy: slow gate -> release builds -> install -> sha256 proof -> VERSION.txt -> shortcut.
#
# Usage: bash scripts/deploy.sh [--dry-run] [--allow-unlanded] [--install-root DIR]
#                                [--bridge-dir DIR] [--shortcut-dir DIR | --no-shortcut]
#
#   --dry-run          print every step (and whether the guards would refuse); build and copy nothing.
#   --allow-unlanded   deploy a commit that is not on origin/main (the seat's own smoke tests only).
#   --install-root     where observatory.exe + VERSION.txt go (a WSL path, e.g. /mnt/c/Apps/OrcastrationStation).
#                      No built-in default: the flag, else $OBSERVATORY_INSTALL_ROOT, else `install_root=<dir>`
#                      in $OBSERVATORY_DEPLOY_CONF (default ~/.config/observatory/deploy.conf). None set = refused.
#   --bridge-dir       where the WSL bridge binary goes         (default ~/.local/share/observatory/bin)
#   --shortcut-dir     where 'Orcastration Station.lnk' goes (default: the Windows Desktop when the install root came
#                      from the env or the config file, else the install root itself, so test runs that
#                      pass --install-root never touch the real Desktop)
#
# Installed paths (the app hard-wires the bridge path; change both together):
#   <install root>/observatory.exe, <install root>/VERSION.txt
#   ~/.local/share/observatory/bin/observatory-bridge   (only once crates/bridge exists)
#
# Writes nothing else except cargo's target dir. Refuses to deploy a dirty Station folder or a commit that is not
# on origin/main (unless --allow-unlanded), and refuses unless the slow gate's LAST line is
# `GATE PASS (<N> tests)` AND the gate exited 0, and refuses if the tree or HEAD changed while the gate
# ran. Installs copy to `<name>.new`, check the copy succeeded and its sha256 equals the build, and only
# then rename over the old one, so a failed copy or replacing a running observatory.exe (Windows locks
# it) fails loudly and leaves the old one intact.
#
# Test hook: DEPLOY_GATE_CMD (one shell command, run with bash -c) replaces the slow gate, and is
# honoured ONLY when --install-root and --bridge-dir both resolve under $HOME, not under /mnt/ (drvfs is
# case-insensitive, so no string compare is safe there), and the bridge dir is not its real default.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib-shortcut.sh"
cd "$HERE/.."
REPO="$(pwd)"

DRY=0 ALLOW_UNLANDED=0 SHORTCUT=1 WOULD_REFUSE=0
INSTALL_ROOT="" ROOT_FROM=""
DEFAULT_BRIDGE_DIR="$HOME/.local/share/observatory/bin"
BRIDGE_DIR="$DEFAULT_BRIDGE_DIR"
SHORTCUT_DIR=""

die() { echo "DEPLOY REFUSED: $*" >&2; exit 1; }
# recheck <phase>: what the gate passed must be what gets built and installed: same commit, still clean.
recheck() {
  [ "$(git rev-parse HEAD)" = "$HEAD_AT_START" ] || die "HEAD moved during $1 ($SHA -> $(git rev-parse --short HEAD)); the gate result does not cover it"
  [ -z "$(git status --porcelain -- .)" ] || die "the Station folder became dirty during $1; the gate result does not cover it"
  echo "ok: after $1 the tree is still clean and HEAD is still $SHA"
}
step() { echo; echo "== $*"; }
# run: execute (or, in a dry run, only print) one mutating command.
run() {
  if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else echo "+ $*"; "$@"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --allow-unlanded) ALLOW_UNLANDED=1 ;;
    --install-root) INSTALL_ROOT="${2:?--install-root needs a dir}"; ROOT_FROM=flag; shift ;;
    --bridge-dir) BRIDGE_DIR="${2:?--bridge-dir needs a dir}"; shift ;;
    --shortcut-dir) SHORTCUT_DIR="${2:?--shortcut-dir needs a dir}"; shift ;;
    --no-shortcut) SHORTCUT=0 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done

# The install root, when no --install-root: the env, then the private config file. No default.
DEPLOY_CONF="${OBSERVATORY_DEPLOY_CONF:-$HOME/.config/observatory/deploy.conf}"
if [ -z "$ROOT_FROM" ] && [ -n "${OBSERVATORY_INSTALL_ROOT:-}" ]; then
  INSTALL_ROOT="$OBSERVATORY_INSTALL_ROOT" ROOT_FROM=env
fi
if [ -z "$ROOT_FROM" ] && [ -f "$DEPLOY_CONF" ]; then
  INSTALL_ROOT="$(sed -n 's/^[[:space:]]*install_root[[:space:]]*=[[:space:]]*//p' "$DEPLOY_CONF" | tail -n1 | tr -d '\r')"
  [ -n "$INSTALL_ROOT" ] && ROOT_FROM=config
fi
[ -n "$INSTALL_ROOT" ] || die "no install root: pass --install-root DIR, set OBSERVATORY_INSTALL_ROOT, or put install_root=DIR in $DEPLOY_CONF"
echo "install root: $INSTALL_ROOT (from ${ROOT_FROM/flag/--install-root})"

. scripts/env.sh
SHA="$(git rev-parse --short HEAD)"
HEAD_AT_START="$(git rev-parse HEAD)"
VERSION="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -n1)"
EXE_BUILT="$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/observatory.exe"
echo "deploy: Orcastration Station $VERSION ($SHA) from $REPO$([ "$DRY" = 1 ] && echo '  [DRY RUN]')"

# ---------------------------------------------------------------- 1. only landed, clean code ships
step "1. tree is clean and on origin/main"
refusals=()
# Scoped to this folder (the kit's other files are not what ships): a dirty file elsewhere in the repo does not refuse.
if [ -n "$(git status --porcelain -- .)" ]; then
  refusals+=("the Station folder is dirty (git status --porcelain -- . is not empty)")
fi
# No fetch here: siblings share FETCH_HEAD. A stale origin/main can only refuse, never wrongly admit.
LANDED=1
# Landed = HEAD is on origin/main, or this folder's tree is byte-identical to origin/main's (a commit elsewhere in
# the kit that is not pushed yet does not change what ships). A folder that differs from main's is never landed.
if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null \
   && ! { t_head="$(git rev-parse -q --verify 'HEAD:./' 2>/dev/null)" && [ -n "$t_head" ] && [ "$t_head" = "$(git rev-parse -q --verify 'origin/main:./' 2>/dev/null)" ]; }; then
  LANDED=0
  if [ "$ALLOW_UNLANDED" = 1 ]; then
    echo "note: $SHA is not on origin/main; deploying anyway (--allow-unlanded)"
  else
    refusals+=("$SHA is not on origin/main (only landed code ships; --allow-unlanded overrides)")
  fi
fi
if [ ${#refusals[@]} -gt 0 ]; then
  for r in "${refusals[@]}"; do echo "  - $r"; done
  [ "$DRY" = 1 ] && { echo "[dry-run] a real run would stop here: DEPLOY REFUSED"; WOULD_REFUSE=1; }
  [ "$DRY" = 1 ] || die "${refusals[0]}"
elif [ "$LANDED" = 1 ]; then
  echo "ok: clean, $SHA is on origin/main"
else
  echo "ok: clean; $SHA is NOT on origin/main (allowed by --allow-unlanded)"
fi

# ---------------------------------------------------------------- 2. slow gate, pass line verified
# The test hook may only replace the gate when nothing real can be installed. Allow-list, not a
# compare against the defaults: both targets must resolve (realpath -m: symlinks, .., trailing /) under
# $HOME and not under /mnt/ (Windows drives; case-insensitive, so no string compare is safe there), and
# the bridge dir must not be the real one.
under() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }
if [ -n "${DEPLOY_GATE_CMD:-}" ]; then
  GATE=(bash -c "$DEPLOY_GATE_CMD")
  GATE_SHOWN="DEPLOY_GATE_CMD (test hook): $DEPLOY_GATE_CMD"
  hook_refusal=""
  home_r="$(realpath -m -- "$HOME")"
  for t in "install root:$INSTALL_ROOT" "bridge dir:$BRIDGE_DIR"; do
    tr_="$(realpath -m -- "${t#*:}")"
    if under "$tr_" /mnt || ! under "$tr_" "$home_r"; then
      hook_refusal="DEPLOY_GATE_CMD is a test hook: the ${t%%:*} ${t#*:} (= $tr_) must be under $home_r and not under /mnt/"
      break
    fi
  done
  if [ -n "$hook_refusal" ]; then :
  elif [ "$(realpath -m -- "$BRIDGE_DIR")" = "$(realpath -m -- "$DEFAULT_BRIDGE_DIR")" ]; then
    hook_refusal="DEPLOY_GATE_CMD is a test hook and cannot replace the gate for the real bridge dir $DEFAULT_BRIDGE_DIR (pass --bridge-dir)"
  fi
else
  # The kit's gate-throttle.sh: this tree's own copy, else the repo root's, else none.
  THROTTLE=scripts/gate-throttle.sh
  [ -f "$THROTTLE" ] || THROTTLE="$(git rev-parse --show-toplevel)/scripts/gate-throttle.sh"
  if [ -f "$THROTTLE" ]; then GATE=(bash "$THROTTLE" bash scripts/gate.sh --release); else GATE=(bash scripts/gate.sh --release); fi
  GATE_SHOWN="${GATE[*]}"
  hook_refusal=""
fi
step "2. slow gate: $GATE_SHOWN"
if [ -n "$hook_refusal" ]; then
  echo "  - $hook_refusal"
  [ "$DRY" = 1 ] && { echo "[dry-run] a real run would stop here: DEPLOY REFUSED"; WOULD_REFUSE=1; }
  [ "$DRY" = 1 ] || die "$hook_refusal"
fi
GATE_LOG="$CARGO_TARGET_DIR/deploy-gate-$SHA.log"
if [ "$DRY" = 1 ]; then
  echo "[dry-run] $GATE_SHOWN > $GATE_LOG 2>&1   (must exit 0 AND end with: GATE PASS (<N> tests))"
  echo "[dry-run] then re-check: tree still clean and HEAD still $SHA"
else
  # No pipe: the gate's own exit status lands in $rc. An array, so nothing is word-split or globbed.
  "${GATE[@]}" > "$GATE_LOG" 2>&1
  rc=$?
  last="$(tail -n 1 "$GATE_LOG")"
  echo "gate exit $rc, last line: $last   (log: $GATE_LOG)"
  [ "$rc" -eq 0 ] || die "the gate exited $rc"
  [[ "$last" =~ ^GATE\ PASS\ \([0-9]+\ tests\)$ ]] || die "the gate's last line is not 'GATE PASS (<N> tests)'"
  # What the gate passed must be what gets built: same commit, still no local changes.
  recheck "the gate"
fi

# ---------------------------------------------------------------- 3. release builds
step "3. release builds"
run cargo build --release --locked --target x86_64-pc-windows-gnu -p observatory-app
[ "$DRY" = 1 ] || [ -f "$EXE_BUILT" ] || die "built exe not found at $EXE_BUILT"
BRIDGE_BUILT=""
if [ -d crates/bridge ]; then
  # The bridge's binary name comes from cargo itself, not from a guess.
  BRIDGE_BIN="$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c '
import json, sys, os
m = json.load(sys.stdin)
for p in m["packages"]:
    if os.path.dirname(p["manifest_path"]).endswith("/crates/bridge"):
        print(p["name"]); [print(t["name"]) for t in p["targets"] if "bin" in t["kind"]]
' | sed -n '1p;2p' | paste -sd' ')"
  read -r BRIDGE_PKG BRIDGE_BIN <<<"$BRIDGE_BIN"
  [ -n "${BRIDGE_BIN:-}" ] || die "crates/bridge exists but cargo reports no binary target in it"
  run cargo build --release --locked -p "$BRIDGE_PKG" --bin "$BRIDGE_BIN"
  BRIDGE_BUILT="$CARGO_TARGET_DIR/release/$BRIDGE_BIN"
  [ "$DRY" = 1 ] || [ -f "$BRIDGE_BUILT" ] || die "built bridge not found at $BRIDGE_BUILT"
else
  echo "note: no crates/bridge yet; skipping the bridge build and install"
fi
[ "$DRY" = 1 ] || echo "observatory.exe: $(stat -c %s "$EXE_BUILT") bytes"
if [ "$DRY" = 1 ]; then echo "[dry-run] then re-check: tree still clean and HEAD still $SHA"; else recheck "the build"; fi

# ---------------------------------------------------------------- 4. install (copy, then rename)
# install_one <built> <dest dir> <dest name>: copy to .new, check the copy (exit status AND sha256
# against the build), and only then rename over the old one. Any failure removes .new and dies, so the
# old installed copy is never replaced by a partial one.
install_one() {
  local src="$1" dir="$2" name="$3" a b
  local new="$dir/$name.new"
  run mkdir -p "$dir"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] cp -f $src $new   (must exit 0)"
    echo "[dry-run] sha256 $src == sha256 $new   (before the rename)"
    echo "[dry-run] mv -f $new $dir/$name"
    return
  fi
  echo "+ cp -f $src $new"
  if ! cp -f "$src" "$new"; then
    rm -f "$new"
    die "copying $src to $new failed (disk full? permissions?). The old $dir/$name is untouched."
  fi
  a="$(sha256sum "$src" | cut -d' ' -f1)"
  b="$(sha256sum "$new" | cut -d' ' -f1)"
  echo "$b  copied    $new"
  if [ "$a" != "$b" ]; then
    rm -f "$new"
    die "the copy $new does not match the build ($b != $a). The old $dir/$name is untouched."
  fi
  echo "+ mv -f $new $dir/$name"
  if ! mv -f "$new" "$dir/$name"; then
    rm -f "$new"
    die "could not replace $dir/$name (is Orcastration Station running? close it and deploy again). The old copy is untouched."
  fi
}
step "4. install"
install_one "$EXE_BUILT" "$INSTALL_ROOT" observatory.exe
[ -n "$BRIDGE_BUILT" ] && install_one "$BRIDGE_BUILT" "$BRIDGE_DIR" observatory-bridge

# ---------------------------------------------------------------- 5. proof + VERSION.txt
step "5. sha256 proof"
verify() {
  if [ "$DRY" = 1 ]; then echo "[dry-run] sha256 $1 == sha256 $2"; return; fi
  local a b
  a="$(sha256sum "$1" | cut -d' ' -f1)"
  b="$(sha256sum "$2" | cut -d' ' -f1)"
  echo "$a  built     $1"
  echo "$b  installed $2"
  [ "$a" = "$b" ] || die "installed $2 does not match the build"
  echo "$a  $(basename "$2")" >> "$VERSION_TMP"
}
VERSION_TMP="$CARGO_TARGET_DIR/deploy-VERSION-$SHA.txt"
[ "$DRY" = 1 ] || printf 'Orcastration Station %s (%s)\ndeployed %s\n\n' "$VERSION" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VERSION_TMP"
verify "$EXE_BUILT" "$INSTALL_ROOT/observatory.exe"
[ -n "$BRIDGE_BUILT" ] && verify "$BRIDGE_BUILT" "$BRIDGE_DIR/observatory-bridge"
run cp -f "$VERSION_TMP" "$INSTALL_ROOT/VERSION.txt"

# ---------------------------------------------------------------- 6. desktop shortcut (idempotent)
step "6. shortcut"
if [ "$SHORTCUT" = 0 ]; then
  echo "skipped (--no-shortcut)"
else
  if [ -z "$SHORTCUT_DIR" ]; then
    if [ "$ROOT_FROM" != flag ]; then
      desk="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')" | tr -d '\r')"
      [ -n "$desk" ] || die "could not find the Windows Desktop folder"
      SHORTCUT_DIR="$(wslpath -u "$desk")"
    else
      SHORTCUT_DIR="$INSTALL_ROOT"
    fi
  fi
  lnk_win="$(wslpath -w "$SHORTCUT_DIR")\\Orcastration Station.lnk"
  exe_win="$(wslpath -w "$INSTALL_ROOT")\\observatory.exe"
  dir_win="$(wslpath -w "$INSTALL_ROOT")"
  # One fixed file name: re-running rewrites the same .lnk, never a second one. Paths are quoted by lib-shortcut.sh.
  ps="$(shortcut_ps "$lnk_win" "$exe_win" "$dir_win")"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] powershell.exe: Orcastration Station.lnk in $SHORTCUT_DIR -> $exe_win (rewritten only if it points elsewhere)"
  else
    powershell.exe -NoProfile -Command "$ps" | tr -d '\r' || die "shortcut creation failed"
  fi
fi

echo
if [ "$DRY" = 1 ]; then
  echo "DRY RUN DONE: nothing was built or copied"
  [ "$WOULD_REFUSE" = 0 ] || { echo "(exit 3: a real run would be REFUSED; see the refusal above)"; exit 3; }
else
  echo "DEPLOYED Orcastration Station $VERSION ($SHA) -> $INSTALL_ROOT"
fi
