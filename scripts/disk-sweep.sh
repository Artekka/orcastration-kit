#!/usr/bin/env bash
# disk-sweep.sh (orcastration-kit): frees disk space a multi-session project leaves behind, safely, and writes a report.
# Ported from a project whose disk filled to 99% with idle worktrees, build copies, browser leftovers and Docker build cache.
#
# Usage: disk-sweep.sh [--repo DIR] [--apply] [--dry-run] [--urgent]
#        disk-sweep.sh --off | --on | --status
#   (no flag)  DRY RUN, the default: print every kept / would-remove line and change nothing.
#   --apply    really remove. The scheduled run (disk-sweep-cron.sh) passes it from the second run on a machine.
#   --dry-run  with --apply, wins: change nothing.
#   --urgent   shorter ages (also automatic at KIT_SWEEP_URGENT_PCT, default 85% used).
#   --repo     the project to sweep (default: the git top level of the current folder). The kit runs this script from its
#              plugin folder, so the project never comes from the script's own location.
#   --off / --on / --status   the switch for the scheduled run (a file: ~/.orcastration-kit/disk-sweep.off).
#
# Fail-safe: when in doubt, KEEP. Never `git worktree remove --force`, never `git branch -D`, never `docker system prune`,
# never a Docker volume or image. Each candidate prints one line: "kept <what>: <reason>" or "removed <what>"
# ("would remove" in a dry run). Bash 3.2+ (macOS /bin/bash): no associative arrays, no mapfile.
#
#  1. worktrees of the repo. Kept: the main checkout, the tree this runs in, a locked tree (`git worktree lock`), a tree an open
#     board line names (docs/orchestration/AGENT_BOARD.md on origin; a line saying DONE / ON MAIN / MERGED / SHIPPED / ✅ is not
#     open), a tree a live process holds (cwd, an open file, a command line), a tree a Docker compose project uses, a file changed
#     inside the age (counting node_modules and build output), and every reason of worktree_removal_blocker
#     (scripts/lib-builder-worktree.sh: uncommitted, untracked, an ignored file that is not rebuildable output, a hidden edit).
#     a. merged into origin's default branch, clean: removed after 2 days idle (urgent 1).
#     b. rule a, NOT merged: the folder goes after 14 days idle when the tree is clean and origin has the SAME tip. The branch stays.
#     c. rule b, a detached HEAD on a commit no remote has: refs/kit-sweep-keep/<folder> is written and READ BACK first, then the
#        folder goes after 14 days idle. Undo: git worktree add <path> refs/kit-sweep-keep/<folder>.
#     d. a DIRTY tree idle 14 days: its work is SAVED (changes.patch from `git diff HEAD --binary`, files.tar of untracked files and
#        ignored files that are not rebuildable output, info.txt with the undo steps) under ~/.orcastration-kit/disk-sweep/saved/,
#        READ BACK (checksums, the tar's list, `git apply --check` on a scratch index), then the tree is reset, cleaned and removed.
#        A tree with a hidden edit (skip-worktree, assume-unchanged), or whose save fails, is kept and listed under "needs a decision".
#        Saves older than 30 days are removed.
#     e. inside every IDLE tree (kept or not): ignored node_modules folders that are real copies (most files not hard-linked, as
#        npm and yarn install them; pnpm's shared store is left alone) and ignored build output found by its content (an
#        index.html beside an assets folder, whatever the folder is called) are removed first.
#  2. headless browser leftovers in the temp folder (KIT_SWEEP_TMP, else $TMPDIR, else /tmp): playwright-artifacts-*,
#     playwright_chromiumdev_profile-*, .org.chromium.Chromium.*. Kept when a live process holds one or a file changed in 6 h.
#  3. Docker build cache, trimmed with `docker builder prune --max-used-space <cap>` when it is over the cap:
#     cap = max(KIT_SWEEP_CACHE_CAP GB (default 20), 1.5 x the largest image), at most 40% of the free disk.
#     The freed number is Docker's own count before and after.
#  4. a scratch folder (KIT_SWEEP_SCRATCH, optional): node_modules, build output found by content and browser profiles inside a
#     folder with no file changed in 7 days and no .keep file. A line per item goes to PURGED.txt beside it first. Git checkouts in
#     scratch are left alone.
# Absent pieces (no Docker, no scratch folder, no board, no origin) each print one "skipped: <why>" line.
# Report: KIT_SWEEP_REPORT_DIR (default ~/.orcastration-kit/disk-sweep/reports/<repo>-<id>/) / <date>-<time>[-dry-run].txt.
# Its first six lines: free space before and after (df), freed per class, kept per reason, what needs a decision, saved bundles.
#
# Config (env): KIT_SWEEP_SCRATCH, KIT_SWEEP_TMP, KIT_SWEEP_DOCKER (default docker), KIT_SWEEP_CACHE_CAP (GB), KIT_SWEEP_URGENT_PCT,
# KIT_SWEEP_PROTECTED (colon list never touched), KIT_SWEEP_REPORT_DIR, KIT_SWEEP_SAVE_DIR.
# Test seams: KIT_SWEEP_DF (a df stand-in), KIT_SWEEP_DISK_PCT, KIT_SWEEP_RM (the deleter, called with one path).
set -uo pipefail
unset CDPATH
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-kit-home.sh
. "$HERE_DIR/lib-kit-home.sh"
# shellcheck source=lib-builder-worktree.sh
. "$HERE_DIR/lib-builder-worktree.sh"
# shellcheck source=lib-disk-sweep-launch.sh
. "$HERE_DIR/lib-disk-sweep-launch.sh"

usage() { echo 'usage: disk-sweep.sh [--repo DIR] [--apply] [--dry-run] [--urgent]  |  --off | --on | --status   (no --apply = dry run)' >&2; exit 2; }
apply=0; force_dry=0; urgent=0; repo=""; switch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --dry-run) force_dry=1; shift ;;
    --urgent) urgent=1; shift ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --off|--on|--status) switch=${1#--}; shift ;;
    *) usage ;;
  esac
done
KH=$(kit_home) || exit 2
OFF="$KH/disk-sweep.off"
case "$switch" in
  off) : > "$OFF" || exit 2; echo "disk-sweep: the scheduled sweep is OFF. Turn it on again: bash \"$HERE_DIR/disk-sweep.sh\" --on"; exit 0 ;;
  on) rm -f -- "$OFF"; echo "disk-sweep: the scheduled sweep is ON (it runs at most once a day, at a session start). Turn it off: bash \"$HERE_DIR/disk-sweep.sh\" --off"; exit 0 ;;
  status)
    if [ -e "$OFF" ]; then echo "disk-sweep: the scheduled sweep is off"; else echo "disk-sweep: the scheduled sweep is on"; fi
    for f in "$KH"/disk-sweep/last/*; do [ -f "$f" ] && echo "disk-sweep: $(basename "$f"): last started $(date -r "$(cat "$f")" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$(cat "$f")" '+%Y-%m-%d %H:%M' 2>/dev/null)"; done
    exit 0 ;;
esac
dry=1; if [ "$apply" = 1 ] && [ "$force_dry" = 0 ]; then dry=0; fi
verb=removed; [ "$dry" = 1 ] && verb="would remove"

# ── the repo ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
[ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "disk-sweep: not inside a git repo; pass --repo DIR" >&2; exit 2; }
[ -d "$repo" ] || { echo "disk-sweep: --repo $repo is not a folder" >&2; exit 2; }
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "disk-sweep: $repo is not a git repo" >&2; exit 2; }
MAIN=$(cd "$(dirname "$common")" && pwd -P) || exit 2
# the tree this runs in: the current folder's top level, when it belongs to the same repo
here=""
if t=$(git rev-parse --show-toplevel 2>/dev/null) && c=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [ "$c" = "$common" ]; then
  here=$(cd "$t" && pwd -P)
fi
cd "$MAIN" || exit 2

DF="${KIT_SWEEP_DF:-df}"
DOCKER="${KIT_SWEEP_DOCKER:-docker}"
TMPROOT="${KIT_SWEEP_TMP:-${TMPDIR:-/tmp}}"; TMPROOT=${TMPROOT%/}
SCRATCH="${KIT_SWEEP_SCRATCH:-}"; SCRATCH=${SCRATCH%/}
CACHE_CAP_GB="${KIT_SWEEP_CACHE_CAP:-20}"; [[ "$CACHE_CAP_GB" =~ ^[0-9]+$ ]] || CACHE_CAP_GB=20
URGENT_PCT="${KIT_SWEEP_URGENT_PCT:-85}"; [[ "$URGENT_PCT" =~ ^[0-9]+$ ]] || URGENT_PCT=85
PROTECTED="${KIT_SWEEP_PROTECTED:-}"
repokey=$(disk_sweep_repokey "$MAIN")
REPORT_DIR="${KIT_SWEEP_REPORT_DIR:-$KH/disk-sweep/reports/$repokey}"
SAVE_ROOT="${KIT_SWEEP_SAVE_DIR:-$KH/disk-sweep/saved}"
SAVE_DIR="$SAVE_ROOT/$repokey"
SAVE_DAYS=30; IDLE_DAYS=14; SCRATCH_DAYS=7

free_kb() { "$DF" -Pk "$MAIN" 2>/dev/null | awk 'NR==2 {print $4}'; }
gb() { awk -v k="$1" 'BEGIN { if (k ~ /^[0-9]+$/) printf "%.1f", k/1048576; else printf "?" }'; }
free_before=$(free_kb)
pct="${KIT_SWEEP_DISK_PCT:-$("$DF" -Pk "$MAIN" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')}"
auto_urgent=0
if [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -ge "$URGENT_PCT" ] && [ "$urgent" = 0 ]; then urgent=1; auto_urgent=1; fi
if [ "$urgent" = 1 ]; then wt_days=1; else wt_days=2; fi

mkdir -p -- "$REPORT_DIR" || exit 2
find "$REPORT_DIR" -mindepth 1 -maxdepth 1 -type d -name '.run-*' -mmin +1440 -exec rm -rf -- {} + 2>/dev/null
RUN_TMP=$(mktemp -d "$REPORT_DIR/.run-XXXXXX") || exit 2
trap 'rm -rf -- "$RUN_TMP"' EXIT
detail="$RUN_TMP/detail"; FREED="$RUN_TMP/freed.tsv"; KEPT="$RUN_TMP/kept.tsv"; DECIDE="$RUN_TMP/decide.txt"; SAVED="$RUN_TMP/saved.tsv"
: > "$detail"; : > "$FREED"; : > "$KEPT"; : > "$DECIDE"; : > "$SAVED"
out() { printf 'disk-sweep: %s\n' "$*" | tee -a "$detail"; }
keep() {  # $1 class, $2 what, $3 reason
  out "kept $2: $3"
  # one line per reason, without the per-item detail in brackets, so the summary stays short
  printf '%s\n' "$3" | sed -E 's/ \(.*$//; s/pid [0-9]+/pid N/; s/branch [^ ]+ /branch /' >> "$KEPT"
}
freed() {  # $1 class, $2 what, $3 kb
  out "$verb $2 ($(( ${3:-0} / 1024 )) MB)"
  printf '%s\t%s\n' "$1" "${3:-0}" >> "$FREED"
}
kb_of() { du -sk -- "$1" 2>/dev/null | awk '{print $1}'; }
del_path() { if [ -n "${KIT_SWEEP_RM:-}" ]; then "$KIT_SWEEP_RM" "$1"; else rm -rf -- "$1"; fi; }
# recent <path> <minutes>: prints the first FILE changed inside the age (prune nothing: a build in progress writes in dist/).
# Returns 1 when find could not scan, so the caller keeps.
recent() { find "$1" -xdev -mindepth 1 -type f -mmin "-$2" -print -quit 2>/dev/null; }
is_protected() {  # $1 path → 0 when it is under a KIT_SWEEP_PROTECTED entry
  local IFS=: p
  for p in $PROTECTED; do [ -n "$p" ] || continue; p=${p%/}; case "$1/" in "$p"/*) return 0 ;; esac; done
  return 1
}
[ "$dry" = 1 ] && out "DRY RUN: nothing is changed (pass --apply to remove)"
[ "$urgent" = 1 ] && out "urgent: worktree age 1 day$( [ "$auto_urgent" = 1 ] && printf ' (the disk is %s%% used)' "$pct")"

# ── live processes: one snapshot of every cwd, open file and command line ──────────────────────────────────────────────────
HELD="$RUN_TMP/held"; : > "$HELD"; held_ok=1
if [ -r /proc/self/cmdline ]; then
  {
    ls -l /proc/[0-9]*/cwd /proc/[0-9]*/fd/ 2>/dev/null | sed -n 's/.* -> //p'
    cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n'
  } > "$HELD" 2>/dev/null
elif command -v lsof >/dev/null 2>&1; then
  { lsof -nP -Fn 2>/dev/null | sed -n 's/^n//p'; ps -axo command= 2>/dev/null | tr ' ' '\n'; } > "$HELD"
else
  held_ok=0
  out "skipped: live-process check (no /proc and no lsof); every worktree and leftover is kept"
fi
held() {  # $1 canonical path → 0 when a process names it or something inside it
  grep -qxF -- "$1" "$HELD" || grep -qF -- "$1/" "$HELD"
}

# ── origin, the default branch, the board ──────────────────────────────────────────────────────────────────────────────────
origin_ok=1; fetch_ok=1
if ! git remote get-url origin >/dev/null 2>&1; then
  origin_ok=0; fetch_ok=0; out "skipped: no origin remote, so no worktree can be shown merged; every worktree is kept"
elif ! git fetch --prune origin >/dev/null 2>&1; then
  sleep 2
  git fetch --prune origin >/dev/null 2>&1 || { fetch_ok=0; out "fetch failed: using the local copy of origin; unmerged and detached trees are kept"; }
fi
DEF=""
if [ "$origin_ok" = 1 ]; then
  DEF=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || DEF=""
  [ -n "$DEF" ] || DEF=origin/main
  git rev-parse -q --verify "$DEF^{commit}" >/dev/null 2>&1 || { origin_ok=0; out "skipped: $DEF cannot be resolved; every worktree is kept"; }
fi
BOARD="$RUN_TMP/board"; board_ok=0
if [ "$origin_ok" = 1 ] && git show "$DEF:docs/orchestration/AGENT_BOARD.md" > "$BOARD" 2>/dev/null && [ -s "$BOARD" ]; then
  grep -Eiv 'DONE|ON MAIN|MERGED|SHIPPED|✅' "$BOARD" > "$BOARD.open" 2>/dev/null; board_ok=1
else
  out "skipped: no board (docs/orchestration/AGENT_BOARD.md on $DEF), so no tree is kept for a board row"
fi
board_names() {  # $1 branch → 0 when an open board line names it as a whole word
  local re
  [ "$board_ok" = 1 ] && [ -n "$1" ] || return 1
  re=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  grep -Eq "(^|[^A-Za-z0-9/_.-])$re(\$|[^A-Za-z0-9/_-])" "$BOARD.open"
}

# Docker compose projects whose working dir or config file lives in a tree. Docker present but not answering = keep every tree.
compose_ok=1; COMPOSE="$RUN_TMP/compose"; : > "$COMPOSE"
if command -v "$DOCKER" >/dev/null 2>&1; then
  for lbl in working_dir config_files; do
    "$DOCKER" ps -a --format "{{.Label \"com.docker.compose.project.$lbl\"}}" >> "$COMPOSE" 2>/dev/null || { compose_ok=0; break; }
  done
  tr ',' '\n' < "$COMPOSE" > "$COMPOSE.1" && mv -f "$COMPOSE.1" "$COMPOSE"
fi

# ── rebuildable bulk: real-copy node_modules and build output found by content ──────────────────────────────────────────────
is_build_copy() { [ -f "$1/index.html" ] && [ -d "$1/assets" ] && [ ! -L "$1" ]; }
# A node_modules folder is a REAL copy (npm, yarn) when fewer than half of its files are hard links (pnpm links every file to its
# store). A sample of at most 2000 files decides; an empty folder is not a copy worth a line.
is_real_nm() {
  local total shared
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  total=$(find "$1" -type f -print 2>/dev/null | head -n 2000 | wc -l | tr -d ' ')
  shared=$(find "$1" -type f -links +1 -print 2>/dev/null | head -n 2000 | wc -l | tr -d ' ')
  [ "${total:-0}" -gt 0 ] && [ $(( ${shared:-0} * 2 )) -lt "$total" ]
}
# strip_bulk <tree>: removes the ignored real-copy node_modules and build copies of an idle tree. Only IGNORED entries count:
# a tracked or untracked folder of the same shape is someone's work.
strip_bulk() {
  local t=$1 line e p kb kind
  while IFS= read -r line; do
    e=${line#!! }; e=${e%/}
    case "$e" in \"*) continue ;; esac
    p="$t/$e"; [ -d "$p" ] && [ ! -L "$p" ] || continue
    kind=""
    case "$e" in node_modules|*/node_modules) is_real_nm "$p" && kind="node_modules (a real copy; reinstall to rebuild)" ;; esac
    [ -z "$kind" ] && is_build_copy "$p" && kind="build output (index.html + assets; rebuild with the build command)"
    [ -n "$kind" ] || continue
    kb=$(kb_of "$p")
    if [ "$dry" = 0 ] && ! del_path "$p"; then keep bulk "$p" "rm failed"; continue; fi
    case "$kind" in node_modules*) freed node_modules "$p: $kind" "$kb" ;; *) freed build-output "$p: $kind" "$kb" ;; esac
  done < <(git -C "$t" status --porcelain --ignored=matching --untracked-files=normal 2>/dev/null | grep '^!! ')
}

# ── dirty idle trees: save, read back, then remove (Art's pick 11-25: the work is saved before the tree goes) ───────────────
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else cksum "$1" | awk '{print $1 "-" $2}'; fi
}
ignored_keepers() {  # $1 tree → the ignored entries that are NOT rebuildable output (they go into the save)
  git -C "$1" -c core.quotePath=false status --porcelain --ignored=matching --untracked-files=normal 2>/dev/null | sed -n 's/^!! //p' |
    while IFS= read -r e; do
      case "$e" in
        node_modules/ | */node_modules/ | dist/ | */dist/ | *.tsbuildinfo | .turbo/ | */.turbo/ | coverage/ | */coverage/ | __pycache__/ | */__pycache__/) continue ;;
      esac
      is_build_copy "$1/${e%/}" && continue
      printf '%s\n' "$e"
    done
}
# dirty_tree <path> <branch or ""> <sha> <why> [prefix]: the blocker kept the tree (<why> is its reason). A dirty reason and 14
# idle days → save + remove; any other case → kept with "<prefix>; <why>".
dirty_tree() {
  local p=$1 br=$2 sha=$3 why=$4 pre=${5:-} r hidden list sd n kb pt tt line e tl fail="" idx label
  case "$why" in
    "it has uncommitted or untracked files"*|"it has an ignored file that is not rebuildable output"*|"it has a skip-worktree or assume-unchanged file"*) ;;
    *) keep worktrees "$p" "${pre:+$pre; }$why"; return ;;
  esac
  r=$(recent "$p" $(( IDLE_DAYS * 1440 ))) || { keep worktrees "$p" "find could not scan it"; return; }
  if [ -n "$r" ]; then keep worktrees "$p" "${pre:+$pre; }$why"; return; fi
  label=${br:-detached}
  hidden=$(git -C "$p" ls-files -v 2>/dev/null | grep -E '^[a-zS] ' | head -1)
  if [ -n "$hidden" ]; then
    printf '%s · %s · a hidden edit (%s): save it by hand, then remove the tree\n' "$p" "$label" "$hidden" >> "$DECIDE"
    keep worktrees "$p" "needs a decision: a skip-worktree or assume-unchanged file ($hidden)"; return
  fi
  list="$RUN_TMP/list.$$"; : > "$list"
  git -C "$p" -c core.quotePath=false ls-files -o --exclude-standard 2>/dev/null > "$list.u" || fail="git ls-files failed"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _bw_nm_link "$p" "?? $line" && continue
    printf '%s\n' "$line" >> "$list"
  done < "$list.u"
  ignored_keepers "$p" >> "$list"
  if grep -q '^"' "$list"; then fail="a file name git quotes (special characters)"; fi
  if [ -n "$fail" ]; then
    printf '%s · %s · cannot be saved: %s\n' "$p" "$label" "$fail" >> "$DECIDE"
    keep worktrees "$p" "needs a decision: $fail"; return
  fi
  if [ "$dry" = 1 ]; then
    out "would save and remove $p (dirty, idle $IDLE_DAYS days; branch $label)"; printf 'worktrees\t%s\n' "$(kb_of "$p")" >> "$FREED"; return
  fi
  # a detached commit no remote has gets its keep ref first (the patch applies on top of it)
  if [ -z "$br" ] && ! on_remote "$sha"; then keep_ref "$p" "$sha" || { printf '%s · detached · the keep ref could not be written\n' "$p" >> "$DECIDE"; keep worktrees "$p" "needs a decision: the keep ref could not be written"; return; }; fi
  sd="$SAVE_DIR/$(basename "$p")-$(date +%Y%m%d)"; n=2
  while [ -e "$sd" ]; do sd="$SAVE_DIR/$(basename "$p")-$(date +%Y%m%d)-$n"; n=$((n + 1)); done
  mkdir -p -- "$sd" || { fail="could not make $sd"; }
  [ -n "$fail" ] || git -C "$p" diff HEAD --binary > "$sd/changes.patch" 2>/dev/null || fail="git diff failed"
  if [ -z "$fail" ] && [ -s "$list" ]; then (cd "$p" && tar -cf "$sd/files.tar" -T "$list") 2>/dev/null || fail="tar failed"; fi
  if [ -z "$fail" ]; then
    pt=$(sha256_of "$sd/changes.patch"); tt=""; [ -f "$sd/files.tar" ] && tt=$(sha256_of "$sd/files.tar")
    {
      echo "saved by disk-sweep.sh on $(date '+%Y-%m-%d %H:%M')"
      echo "tree: $p"; echo "branch: $label"; echo "head: $sha"
      echo "changes.patch sha256: $pt"; [ -n "$tt" ] && echo "files.tar sha256: $tt"
      echo "undo (run in $MAIN): git worktree add \"$p\" ${br:-$sha}  &&  cd \"$p\"  &&  git apply \"$sd/changes.patch\"$( [ -n "$tt" ] && printf '  &&  tar -xf "%s/files.tar"' "$sd")"
      echo "this save is removed after $SAVE_DAYS days"
    } > "$sd/info.txt" || fail="could not write info.txt"
  fi
  # read back: the checksums, the tar's list against the input list, and the patch against HEAD on a scratch index
  if [ -z "$fail" ] && [ "$(sha256_of "$sd/changes.patch")" != "$pt" ]; then fail="the patch did not read back"; fi
  if [ -z "$fail" ] && [ -s "$list" ]; then
    if [ "$(sha256_of "$sd/files.tar")" != "$tt" ]; then fail="the tar did not read back"
    elif ! tl=$(tar -tf "$sd/files.tar" 2>/dev/null); then fail="the tar cannot be listed"
    else
      while IFS= read -r e; do
        e=${e%/}
        printf '%s\n' "$tl" | grep -qxF -e "$e" -e "$e/" || { fail="the tar lacks $e"; break; }
      done < "$list"
    fi
  fi
  if [ -z "$fail" ] && [ -s "$sd/changes.patch" ]; then
    idx="$RUN_TMP/index.check"; rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$p" read-tree HEAD 2>/dev/null && GIT_INDEX_FILE="$idx" git -C "$p" apply --cached --check "$sd/changes.patch" 2>/dev/null \
      || fail="the patch does not apply to HEAD"
    rm -f "$idx"
  fi
  if [ -n "$fail" ]; then
    printf '%s · %s · the save failed (%s); the partial save is in %s\n' "$p" "$label" "$fail" "$sd" >> "$DECIDE"
    keep worktrees "$p" "needs a decision: the save failed ($fail)"; return
  fi
  printf '%s\t%s\n' "$sd" "$(kb_of "$sd")" >> "$SAVED"
  kb=$(kb_of "$p")
  # The work is saved and read back: discard it in the tree, then the plain (never forced) remove.
  if git -C "$p" reset -q --hard HEAD 2>/dev/null && git -C "$p" clean -q -fdx 2>/dev/null && worktree_remove_clean "$p" >/dev/null 2>&1; then
    out "saved $p to $sd (undo: see $sd/info.txt)"; freed worktrees "$p (dirty work saved)" "$kb"
  else
    printf '%s · %s · saved to %s, but git refused to remove the tree\n' "$p" "$label" "$sd" >> "$DECIDE"
    keep worktrees "$p" "needs a decision: saved, but git refused to remove it"
  fi
}

# ── worktrees ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
on_remote() {  # $1 sha → 0 when the default branch or (after a good fetch) any origin branch contains it
  git merge-base --is-ancestor "$1" "$DEF" 2>/dev/null && return 0
  [ "$fetch_ok" = 1 ] && [ -n "$(git for-each-ref --count=1 --contains "$1" --format='%(refname)' refs/remotes/origin 2>/dev/null)" ]
}
KEEPREFS="$RUN_TMP/keeprefs"; : > "$KEEPREFS"
# keep_ref <path> <sha>: writes refs/kit-sweep-keep/<folder> (or <folder>-<sha8> when the name holds another commit), create-only,
# and reads it back. Prints the ref; returns 1 when it could not be written or read back.
keep_ref() {
  local name ref cur got
  name=$(basename "$1"); ref="refs/kit-sweep-keep/$name"
  git check-ref-format "$ref" 2>/dev/null || return 1
  cur=$(git rev-parse -q --verify "$ref" 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "$2" ]; then
    ref="refs/kit-sweep-keep/$name-$(printf '%s' "$2" | cut -c1-8)"; cur=$(git rev-parse -q --verify "$ref" 2>/dev/null)
    [ -z "$cur" ] || [ "$cur" = "$2" ] || return 1
  fi
  if [ "$cur" != "$2" ]; then git update-ref "$ref" "$2" "" 2>/dev/null || return 1; fi
  got=$(git rev-parse -q --verify "$ref" 2>/dev/null)
  [ "$got" = "$2" ] || return 1
  printf '%s\n' "$ref" >> "$KEEPREFS"; printf '%s' "$ref"
}
extra_keep() {  # $1 path, $2 age in days → one reason, or nothing
  local r
  if [ "$compose_ok" != 1 ]; then echo "docker did not answer, so a compose project using it cannot be ruled out"; return; fi
  if [ -s "$COMPOSE" ] && grep -qF -- "$1" "$COMPOSE"; then echo "a docker compose project uses it"; return; fi
  if [ "$held_ok" != 1 ]; then echo "live processes cannot be checked on this machine"; return; fi
  if held "$1"; then echo "a live process holds it (cwd, open file or command line)"; return; fi
  r=$(recent "$1" $(( $2 * 1440 ))) || { echo "find could not scan it"; return; }
  if [ -n "$r" ]; then echo "a file changed in the last $2 day(s) (${r#"$1"/})"; return; fi
}
remove_tree() {  # $1 path, $2 what to print
  local kb; kb=$(kb_of "$1")
  if [ "$dry" = 1 ]; then freed worktrees "$2" "$kb"; return; fi
  if worktree_remove_clean "$1" >/dev/null 2>&1; then freed worktrees "$2" "$kb"
  else keep worktrees "$1" "git refused to remove it"; fi
}
wt_one() {  # $1 path, $2 branch ("" = detached), $3 locked ("1" or "")
  local p=$1 br=$2 why sha
  if [ "$3" = 1 ]; then keep worktrees "$p" "locked (git worktree lock)"; return; fi
  if [ ! -d "$p" ]; then keep worktrees "$p" "its directory is gone (git worktree prune removes the entry)"; return; fi
  p=$(cd "$p" && pwd -P)
  if [ "$p" = "$MAIN" ]; then return; fi
  if [ -n "$here" ] && [ "$p" = "$here" ]; then keep worktrees "$p" "it is the worktree this ran in"; return; fi
  if [ "$origin_ok" != 1 ]; then keep worktrees "$p" "origin cannot be read"; return; fi
  if [ -n "$br" ] && board_names "$br"; then keep worktrees "$p" "the board names it (an open line names branch $br)"; return; fi
  if is_protected "$p"; then keep worktrees "$p" "a protected path"; return; fi
  sha=$(git -C "$p" rev-parse --verify -q HEAD 2>/dev/null) || { keep worktrees "$p" "its HEAD cannot be resolved"; return; }
  # idle trees lose their rebuildable bulk first, kept or not
  if [ -z "$(extra_keep "$p" "$wt_days")" ]; then strip_bulk "$p"; fi
  if [ -n "$br" ] && git merge-base --is-ancestor "refs/heads/$br" "$DEF" 2>/dev/null; then
    why=$(SEAT_MERGE_IDLE_MINUTES=$(( wt_days * 1440 )) worktree_removal_blocker "$p" "$br" "$here")
    if [ -n "$why" ]; then dirty_tree "$p" "$br" "$sha" "$why"; return; fi
    why=$(extra_keep "$p" "$wt_days"); if [ -n "$why" ]; then keep worktrees "$p" "$why"; return; fi
    remove_tree "$p" "$p (merged into $DEF; branch $br stays)"
  elif [ -n "$br" ]; then   # rule a
    why=$(SEAT_MERGE_IDLE_MINUTES=$(( IDLE_DAYS * 1440 )) worktree_removal_blocker "$p" "$br" "$here" detached)
    if [ -n "$why" ]; then dirty_tree "$p" "$br" "$sha" "$why" "branch $br is not merged"; return; fi
    if [ "$fetch_ok" != 1 ]; then keep worktrees "$p" "branch $br is not merged and the fetch failed"; return; fi
    local ot; ot=$(git rev-parse -q --verify "refs/remotes/origin/$br^{commit}" 2>/dev/null)
    if [ -z "$ot" ]; then keep worktrees "$p" "branch $br is not merged and origin has no copy of it"; return; fi
    if [ "$ot" != "$sha" ]; then keep worktrees "$p" "branch $br is not merged and its tip differs from origin/$br"; return; fi
    why=$(extra_keep "$p" "$IDLE_DAYS"); if [ -n "$why" ]; then keep worktrees "$p" "branch $br is not merged; $why"; return; fi
    remove_tree "$p" "$p (rule a: branch $br stays here and on origin; undo: git worktree add $p $br)"
  elif on_remote "$sha"; then
    why=$(SEAT_MERGE_IDLE_MINUTES=$(( wt_days * 1440 )) worktree_removal_blocker "$p" "" "$here" detached)
    if [ -n "$why" ]; then dirty_tree "$p" "" "$sha" "$why"; return; fi
    why=$(extra_keep "$p" "$wt_days"); if [ -n "$why" ]; then keep worktrees "$p" "$why"; return; fi
    remove_tree "$p" "$p (detached on a commit origin has)"
  else   # rule b
    if [ "$fetch_ok" != 1 ]; then keep worktrees "$p" "detached on a commit origin may lack, and the fetch failed"; return; fi
    why=$(SEAT_MERGE_IDLE_MINUTES=$(( IDLE_DAYS * 1440 )) worktree_removal_blocker "$p" "" "$here" detached)
    if [ -n "$why" ]; then dirty_tree "$p" "" "$sha" "$why" "detached on a commit no remote has"; return; fi
    why=$(extra_keep "$p" "$IDLE_DAYS"); if [ -n "$why" ]; then keep worktrees "$p" "detached on a commit no remote has; $why"; return; fi
    local ref="refs/kit-sweep-keep/$(basename "$p")"
    if [ "$dry" = 1 ]; then remove_tree "$p" "$p (rule b: $ref is written first; undo: git worktree add $p $ref)"; return; fi
    ref=$(keep_ref "$p" "$sha") || { keep worktrees "$p" "detached on a commit no remote has; the keep ref could not be written or read back"; return; }
    remove_tree "$p" "$p (rule b: $ref; undo: git worktree add $p $ref)"
  fi
}
sweep_worktrees() {
  local line cur="" br="" lk="" n=0 paths=() brs=() lks=() i
  # porcelain prints "locked" after the branch line, so collect each record first
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) if [ -n "$cur" ]; then paths[n]=$cur; brs[n]=$br; lks[n]=$lk; n=$((n + 1)); fi; cur=${line#worktree }; br=""; lk="" ;;
      "branch refs/heads/"*) br=${line#branch refs/heads/} ;;
      locked|"locked "*) lk=1 ;;
    esac
  done < <(git worktree list --porcelain)
  if [ -n "$cur" ]; then paths[n]=$cur; brs[n]=$br; lks[n]=$lk; n=$((n + 1)); fi
  i=0; while [ "$i" -lt "$n" ]; do wt_one "${paths[i]}" "${brs[i]}" "${lks[i]}"; i=$((i + 1)); done
}

# ── saved bundles older than 30 days ────────────────────────────────────────────────────────────────────────────────────────
sweep_saves() {
  local d kb
  [ -d "$SAVE_ROOT" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -n "$(recent "$d" $(( SAVE_DAYS * 1440 )))" ] && continue
    kb=$(kb_of "$d")
    if [ "$dry" = 0 ] && ! del_path "$d"; then keep saves "$d" "rm failed"; continue; fi
    freed saves "$d (a save older than $SAVE_DAYS days)" "$kb"
  done < <(find "$SAVE_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
}

# ── headless browser leftovers ──────────────────────────────────────────────────────────────────────────────────────────────
sweep_headless() {
  local p kb
  [ -d "$TMPROOT" ] || { out "skipped: no temp folder ($TMPROOT)"; return; }
  for p in "$TMPROOT"/playwright-artifacts-* "$TMPROOT"/playwright_chromiumdev_profile-* "$TMPROOT"/.org.chromium.Chromium.*; do
    [ -e "$p" ] || continue
    if [ -L "$p" ]; then keep headless "$p" "it is a symlink"; continue; fi
    p=$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")
    if [ "$held_ok" != 1 ]; then keep headless "$p" "live processes cannot be checked"; continue; fi
    if held "$p"; then keep headless "$p" "a live process holds it"; continue; fi
    if [ -n "$(find "$p" -mmin -360 -print -quit 2>/dev/null)" ]; then keep headless "$p" "a file changed in the last 6 h"; continue; fi
    kb=$(kb_of "$p")
    if [ "$dry" = 0 ] && ! del_path "$p"; then keep headless "$p" "rm failed"; continue; fi
    freed headless "$p" "$kb"
  done
}

# ── Docker build cache ──────────────────────────────────────────────────────────────────────────────────────────────────────
to_bytes() {  # "42.3GB" "512MB" "1.2kB" → bytes
  awk -v s="$1" 'BEGIN{ if (match(s,/[A-Za-z]+$/)) {u=substr(s,RSTART); n=substr(s,1,RSTART-1)+0} else {u="B"; n=s+0}
    m=1; if(u~/^[kK]/)m=1e3; else if(u~/^M/)m=1e6; else if(u~/^G/)m=1e9; else if(u~/^T/)m=1e12; printf "%.0f", n*m }'
}
cache_size() { "$DOCKER" system df --format '{{.Type}}|{{.Size}}' 2>/dev/null | awk -F'|' '$1=="Build Cache"{print $2}'; }
sweep_docker() {
  local cache after big free cap_b cap_gb cur_b aft_b
  if ! command -v "$DOCKER" >/dev/null 2>&1; then out "skipped: docker is not installed"; return; fi
  cache=$(cache_size)
  if [ -z "$cache" ]; then out "skipped: docker did not report a build cache size (is the daemon running?)"; return; fi
  cur_b=$(to_bytes "$cache")
  big=$("$DOCKER" images --format '{{.Size}}' 2>/dev/null | while read -r s; do to_bytes "$s"; echo; done | sort -n | tail -1)
  free=$(free_kb)
  cap_b=$(awk -v big="${big:-0}" -v free="${free:-0}" -v base="$CACHE_CAP_GB" 'BEGIN{ c=base*1e9; b=1.5*big; if(b>c)c=b;
    if (free > 0) { l=0.4*free*1024; if(l<c)c=l }; printf "%.0f", c }')
  cap_gb=$(awk -v c="$cap_b" 'BEGIN{printf "%d", c/1e9}')
  if [ "$cur_b" -le "$cap_b" ]; then keep docker "build cache ($cache)" "within the cap of ${cap_gb} GB"; return; fi
  if [ "$dry" = 1 ]; then out "would trim the docker build cache from $cache down to ${cap_gb} GB"; return; fi
  if ! "$DOCKER" builder prune --force --max-used-space "${cap_gb}GB" >/dev/null 2>&1; then keep docker "build cache" "docker builder prune failed"; return; fi
  after=$(cache_size); aft_b=$(to_bytes "${after:-0}")
  if [ -z "$after" ]; then out "trimmed the docker build cache (was $cache); docker did not report the size after, so nothing is counted"; return; fi
  out "docker build cache: freed $(awk -v a="$cur_b" -v b="$aft_b" 'BEGIN{printf "%.1f", (a-b)/1e9}') GB (Docker's count: $cache before, $after after)"
  printf 'docker\t%s\n' $(( (cur_b - aft_b) / 1024 )) >> "$FREED"
}

# ── scratch folder ──────────────────────────────────────────────────────────────────────────────────────────────────────────
in_checkout() {  # $1 path under $SCRATCH → 0 when a folder between it and the root holds .git
  local d=$1
  while [ "$d" != "$SCRATCH" ] && [ "$d" != / ] && [ -n "$d" ]; do [ -e "$d/.git" ] && return 0; d=$(dirname "$d"); done
  return 1
}
has_keep() {
  local d=$1
  while [ -n "$d" ] && [ "$d" != / ]; do [ -e "$d/.keep" ] && return 0; [ "$d" = "$SCRATCH" ] && break; d=$(dirname "$d"); done
  return 1
}
sweep_scratch() {
  local item kind top kb idle_list rel parent r
  if [ -z "$SCRATCH" ]; then out "skipped: no scratch folder (set KIT_SWEEP_SCRATCH to sweep one)"; return; fi
  [ -d "$SCRATCH" ] || { out "skipped: the scratch folder $SCRATCH does not exist"; return; }
  SCRATCH=$(cd "$SCRATCH" && pwd -P)
  # which top folders are idle, decided BEFORE any delete (a PURGED.txt line changes a folder's time)
  idle_list="$RUN_TMP/scratch-idle"; : > "$idle_list"
  for top in "$SCRATCH"/*/; do
    top=${top%/}; [ -d "$top" ] && [ ! -L "$top" ] || continue
    r=$(recent "$top" $(( SCRATCH_DAYS * 1440 ))) && [ -z "$r" ] && printf '%s\n' "$top" >> "$idle_list"
  done
  while IFS= read -r item; do
    [ -e "$item" ] || continue
    kind=""
    case "$(basename "$item")" in
      node_modules) kind="node_modules (reinstall to rebuild)" ;;
      index.html) item=$(dirname "$item"); is_build_copy "$item" && kind="build output (rebuild with the build command)" ;;
      playwright-artifacts-*|playwright_chromiumdev_profile-*|.org.chromium.Chromium.*) kind="browser profile" ;;
    esac
    [ -n "$kind" ] && [ -e "$item" ] && [ ! -L "$item" ] || continue
    rel=${item#"$SCRATCH"/}; top="$SCRATCH/${rel%%/*}"
    if [ "$top" = "$item" ]; then keep scratch "$item" "a top folder of the scratch root is never removed whole"; continue; fi
    if ! grep -qxF -- "$top" "$idle_list"; then keep scratch "$item" "its folder has a file changed in the last $SCRATCH_DAYS days"; continue; fi
    if has_keep "$(dirname "$item")"; then keep scratch "$item" "a .keep file holds its folder"; continue; fi
    if in_checkout "$(dirname "$item")"; then keep scratch "$item" "it is inside a git checkout"; continue; fi
    if is_protected "$item"; then keep scratch "$item" "a protected path"; continue; fi
    if [ "$held_ok" != 1 ] || held "$item"; then keep scratch "$item" "a live process holds it (or processes cannot be checked)"; continue; fi
    kb=$(kb_of "$item"); parent=$(dirname "$item")
    if [ "$dry" = 0 ]; then
      printf '%s\t%s\t%s\t%s KB\n' "$(date '+%Y-%m-%d %H:%M')" "$item" "$kind" "$kb" >> "$parent/PURGED.txt" 2>/dev/null || { keep scratch "$item" "PURGED.txt could not be written"; continue; }
      del_path "$item" || { keep scratch "$item" "rm failed"; continue; }
    fi
    freed scratch "$item: $kind" "$kb"
  done < <(find "$SCRATCH" -mindepth 2 \( -name .git -prune \) -o \( -type d \( -name node_modules -o -name 'playwright-artifacts-*' -o -name 'playwright_chromiumdev_profile-*' -o -name '.org.chromium.Chromium.*' \) -prune -print \) -o \( -type f -name index.html -print \) 2>/dev/null)
}

sweep_worktrees
sweep_saves
sweep_headless
sweep_docker
sweep_scratch

# ── report ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
free_after=$(free_kb)
stamp=$(date +%Y-%m-%d-%H%M)
report="$REPORT_DIR/$stamp$( [ "$dry" = 1 ] && printf -- '-dry-run').txt"
freed_line=$(awk -F'\t' '{s[$1]+=$2; t+=$2} END { n=0; for (k in s) { printf "%s%s %d MB", (n++ ? ", " : ""), k, s[k]/1024 }; if (n == 0) printf "nothing"; printf " (total %d MB)", t/1024 }' "$FREED")
kept_line=$(sort "$KEPT" | uniq -c | sort -rn | awk '{c=$1; $1=""; sub(/^ /,""); printf "%s%d %s", (n++ ? "; " : ""), c, $0} END { if (n == 0) printf "nothing" }')
nd=$(wc -l < "$DECIDE" | tr -d ' ')
saved_line=$(awk -F'\t' -v days="$SAVE_DAYS" -v d="$(date -v+${SAVE_DAYS}d +%Y-%m-%d 2>/dev/null || date -d "+$SAVE_DAYS days" +%Y-%m-%d 2>/dev/null)" \
  '{n++; t+=$2} END { printf "saved bundles this run: %d, %d MB, in %s; each is removed after %d days (these after %s)", n, t/1024, "'"$SAVE_DIR"'", days, d }' "$SAVED")
{
  echo "disk-sweep $(date '+%Y-%m-%d %H:%M') ($( [ "$dry" = 1 ] && echo "DRY RUN" || echo applied)$( [ "$urgent" = 1 ] && echo ", urgent")) repo $MAIN"
  echo "free before $(gb "$free_before") GB, after $(gb "$free_after") GB"
  echo "freed$( [ "$dry" = 1 ] && echo " (would free)"): $freed_line"
  echo "kept: $kept_line"
  echo "needs a decision: $nd$( [ "$nd" -gt 0 ] && echo " (listed below; the orchestrator empties this list)")"
  echo "$saved_line"
  echo
  if [ "$nd" -gt 0 ]; then echo "## needs a decision"; cat "$DECIDE"; echo; fi
  echo "## every line"
  cat "$detail"
} > "$report" || { echo "disk-sweep: could not write the report $report" >&2; exit 1; }
out "free before $(gb "$free_before") GB, after $(gb "$free_after") GB"
out "freed$( [ "$dry" = 1 ] && echo " (would free)"): $freed_line"
out "kept: $kept_line"
[ "$nd" -gt 0 ] && out "needs a decision: $nd (see the report)"
echo "disk-sweep: report $report"
exit 0
