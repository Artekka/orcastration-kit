#!/usr/bin/env bash
# seat-merge.sh — the seat's merge path: merge a READ-passed branch onto a fresh origin/main, run the project's checks on
# the MERGED tree, and push only when they are green. Ported from the project that grew it, where 25 fix rounds hardened it;
# every project-specific part is a config hook (see CONFIG below).
#
#   scripts/seat-merge.sh <branch> <expected-sha> "<merge message>"      (run from a clean merge worktree)
#
# Why it exists: two branches that are each green alone can break the project together, and a merge pushed after running
# only SOME of the checks sends the red to main. This script runs the format check and every configured check on the tree
# that will actually be pushed, and refuses (exit 1, nothing pushed) otherwise.
#
# What is merged is origin/<branch> and NOTHING else: every worktree shares one ref store, so a local <branch> of the
# builder (stale, or ahead with unreviewed commits) is always there and must never be picked. <expected-sha> is the sha the
# verifier's READ passed; the script refuses when origin/<branch> is anywhere else, and prints the merged sha + subject.
#
# Steps: usage → not the shared checkout → yield to a waiting ticket (bounded) → per-worktree lock → formatter installed
# → no tracked changes → fetch → resolve origin/<branch>, compare to <expected-sha> → already in origin/main = "nothing to
# merge", exit 0 → detach at origin/main → `merge --no-ff` (an untracked file in the way and a conflict each get their own
# refusal) → format check → install + checks → push the CHECKED merge sha (`git push origin "$merged":main`, never `HEAD`:
# a commit made in this worktree after the check would ride along unchecked) → confirm `git branch -r --contains` lists
# origin/main → remove the builder's worktree when it is provably idle. Never forces: a lost race is a refusal, re-run it.
# Red or conflict → nothing is pushed. A conflict is aborted; after a red the merged HEAD stays detached for inspection (the
# last line says so and how to reset it).
# Also: every origin fetch and push retries a transient connection or auth denial (lib-git-retry.sh), and never a rejection by
# the remote; HEAD must sit on origin/main at the start, so a re-run after a red needs the printed reset first (a stale merge
# worktree would otherwise feed the next run its own refused tree); committed conflict markers in the merged tree are listed and
# refused before the format check; the install and every check run as a background job the script waits on, so TERM, INT or
# HUP to the script ends the run at once (exit 128+n) and ends the job; a refused run keeps its check log; stage times come from
# the monotonic clock; after a pushed merge the main checkout is fast-forwarded (scripts/sync-main-checkout.sh).
#
# CONFIG (a hook is optional; the environment variable wins over the config file):
#   When: the config is read BEFORE the merge, from the ORCHESTRATION.md this worktree has checked out (not from the merged
#     tree). A branch that edits the seat_merge: block therefore cannot gate, or ungate, its own merge; the change applies to
#     the next run, once the worktree has caught up (after a green run it sits on the merged commit, so it has).
#   File: an unindented `seat_merge:` line in docs/orchestration/ORCHESTRATION.md, then indented `key: value` lines:
#     format_cmd:   the format check, run on the merged tree. Default: `pnpm format:check` (or `npm run format:check`
#                   without a pnpm-lock.yaml) when package.json has a "format:check" script, else none (a note says so).
#                   Env SEAT_MERGE_FORMAT_CMD. The default needs node_modules/.bin/prettier in the worktree and is refused
#                   BEFORE git is touched without it; a configured command brings its own tool and is not asked for one.
#     install_cmd:  run once before the checks, only when at least one check applies (a merge worktree with a stale
#                   install would give a false green). Default none. Env SEAT_MERGE_INSTALL_CMD.
#     check:        repeatable: `name | globs | command`. `globs` = space-separated path patterns matched against the files
#                   the merge changes (`*` matches any path, `docs/*` a directory); `*` alone = every merge. The command
#                   runs in the worktree with SEAT_MERGE_TOUCHED (the changed paths, one per line), SEAT_MERGE_MERGED (the
#                   merge sha) and SEAT_MERGE_CHECK (the name). A red check is rerun ONCE alone (load flakes); red twice
#                   refuses. Env SEAT_MERGE_CHECKS: the same lines, newline-separated, replaces the file's.
#                   Use it for the test guards, for tests that read generated pages, for a stale-build check.
#     allowed_paths: space-separated path prefixes (default `docs/orchestration/ docs/timeline/build-log.md docs/AI_CONTEXT.md`).
#                   When the push loses a race to commits that touch ONLY these paths, the SAME merge is redone onto the
#                   new origin/main and pushed without re-running the checks (at most 3 times). Env SEAT_MERGE_ALLOWED_PATHS.
#     yield_max_s / yield_poll_s: see YIELD below (defaults 3600 / 5). Env SEAT_MERGE_YIELD_MAX_S / SEAT_MERGE_YIELD_POLL_S.
#     marker_exempt: repeatable: a path prefix the conflict-marker scan skips (default none). Env SEAT_MERGE_MARKER_EXEMPT
#                   (newline-separated).
#     idle_minutes: a builder worktree with a file changed this recently is kept (default 30). Env SEAT_MERGE_IDLE_MINUTES.
# Env only: SEAT_MERGE_LOG_DIR (where a refused run keeps its check log), SEAT_MERGE_REPO (the directory to run in; a test seam), SEAT_MERGE_RUNTIME_DIR (default KIT_RUNTIME_DIR, the
#   runtime dir gate-throttle.sh and quiet-mode.sh share, else $HOME/.orchestration-kit/runtime; the lock and the tickets
#   live there, never inside the worktree),
#   SEAT_MERGE_ALLOW_SHARED_CHECKOUT=1 (skip the linked-worktree check; for tests that use plain clones).
#
# YIELD: before it takes its lock the script waits while a LIVE pusher holds a ticket, <runtime>/seat-merge/<tool>-<pid>.waiting
# (contents `<pid> <starttime>`; scripts/lib-waiting-tickets.sh). Back-to-back merges that keep the lock for long would
# otherwise starve a push that retries every 30 s. Bounded by yield_max_s: past it, warn and go on, so a stuck ticket can
# never deadlock the merge chain. A dead owner's ticket is ignored and removed.

die() { echo "seat-merge: REFUSED. $1" >&2; exit 1; }

[ $# -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || { echo 'usage: scripts/seat-merge.sh <branch> <expected-sha> "<merge message>"' >&2; exit 2; }
branch="${1#origin/}"; expected="$2"; msg="$3"

# Libraries are resolved before the cd below.
SEAT_MERGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-builder-worktree.sh
. "$SEAT_MERGE_LIB/lib-builder-worktree.sh"
# shellcheck source=lib-waiting-tickets.sh
. "$SEAT_MERGE_LIB/lib-waiting-tickets.sh"
# shellcheck source=lib-git-retry.sh
. "$SEAT_MERGE_LIB/lib-git-retry.sh"
# shellcheck source=lib-conflict-markers.sh
. "$SEAT_MERGE_LIB/lib-conflict-markers.sh"
# shellcheck source=lib-mono-clock.sh
. "$SEAT_MERGE_LIB/lib-mono-clock.sh"

# One EXIT trap for the temp file, the running job and the kept log. There is NO TERM/INT/HUP trap here: they exist only around
# the job that runs the install and the checks (signals_on / signals_off below), so a signal to the pid ends every other step at
# once. bash defers a trapped signal until a FOREGROUND child ends, so a trap left on would slow a kill during a git step.
glog="" job="" merge_ok="" checks_started=""
seat_merge_signals_on() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; }
seat_merge_signals_off() { trap - HUP INT TERM; }
# Runs "$@" as a background job writing to $glog, and waits for it: its pid is $job (the EXIT cleanup ends it), its status is the
# return value. `wait` returns at once on a trapped signal, which a foreground child would defer. The job's output is redirected
# HERE, not at the call: a redirect on the call is still open when a trapped signal runs the EXIT cleanup, and the cleanup's own
# messages would land in the log instead of on stderr.
seat_merge_bg_wait() {
  local rc
  "$@" >"$glog" 2>&1 &
  job=$!
  wait "$job"
  rc=$?
  job=""
  return "$rc"
}
# Ends the running job: its direct children (a check's own processes) and the job itself. A process a check put in the
# BACKGROUND itself survives; that is stated, not fixed.
seat_merge_end_job() {
  [ -n "$job" ] || return 0
  pkill -TERM -P "$job" 2>/dev/null
  kill -TERM "$job" 2>/dev/null
  return 0
}
# A refused run keeps its check log (the temp file is removed at exit, so a red could not be classified afterwards). The trigger
# is "the merge did not finish" (merge_ok), NOT the exit status: on TERM/INT/HUP bash runs the EXIT trap with $?=0. A green
# run keeps nothing. The folder is SEAT_MERGE_LOG_DIR (default <runtime>/seat-merge/logs); its path and the last failure lines
# go to stderr.
keep_check_log() {
  [ "$merge_ok" != 1 ] && [ -n "$checks_started" ] && [ -s "${glog:-}" ] || return 0
  local dir dest
  dir="${SEAT_MERGE_LOG_DIR:-$RT/seat-merge/logs}"
  mkdir -p "$dir" 2>/dev/null || { echo "seat-merge: WARNING: could not create $dir; the check log was not kept" >&2; return 0; }
  # tr before cut: cut's trailing newline is then the last character, which $( ) strips
  dest="$dir/$(printf '%s' "${branch:-run}-${merged:-nomerge}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-80)-$(date +%H%M%S)-$$.log"
  cp -- "$glog" "$dest" 2>/dev/null || { echo "seat-merge: WARNING: could not copy the check log to $dest; it was not kept" >&2; return 0; }
  { echo "seat-merge: check log kept: $dest"; grep -E 'FAIL|[Ff]ailed|[Aa]ssert|expected|not ok' "$glog" | tail -40; } >&2
}
cleanup() { seat_merge_end_job; keep_check_log; rm -f "${glog:-}"; }
trap 'cleanup' EXIT

cd "${SEAT_MERGE_REPO:-.}" || exit 2
wt=$(git rev-parse --show-toplevel) || exit 2

# ---- config: env > the seat_merge: block > defaults
conf="$wt/docs/orchestration/ORCHESTRATION.md"
conf_get() {  # <key>: every value of the key in the seat_merge: block, one per line (the rest of the line, trimmed)
  [ -f "$conf" ] || return 0
  awk -v want="$1" '
    /^seat_merge:[[:space:]]*$/ { on=1; next }
    on && /^[[:space:]]+[a-z_]+:/ {
      line=$0; sub(/^[[:space:]]+/, "", line); k=line; sub(/:.*/, "", k)
      if (k == want) { v=line; sub(/^[a-z_]+:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print v }
      next }
    on { on=0 }' "$conf"
}
conf_one() { conf_get "$1" | tail -n1; }   # a single-valued key: the last one wins
FORMAT_CMD="${SEAT_MERGE_FORMAT_CMD:-$(conf_one format_cmd)}"
INSTALL_CMD="${SEAT_MERGE_INSTALL_CMD:-$(conf_one install_cmd)}"
CHECKS="${SEAT_MERGE_CHECKS:-$(conf_get check)}"
ALLOWED_PATHS="${SEAT_MERGE_ALLOWED_PATHS:-$(conf_one allowed_paths)}"
# Path prefixes the conflict-marker scan skips (files that hold markers on purpose, such as a doc that quotes them). One per
# `marker_exempt:` line, or newline-separated in the env variable.
MARKER_EXEMPT="${SEAT_MERGE_MARKER_EXEMPT:-$(conf_get marker_exempt)}"
[ -n "$ALLOWED_PATHS" ] || ALLOWED_PATHS="docs/orchestration/ docs/timeline/build-log.md docs/AI_CONTEXT.md"
yield_max="${SEAT_MERGE_YIELD_MAX_S:-$(conf_one yield_max_s)}"; yield_max="${yield_max:-3600}"
yield_poll="${SEAT_MERGE_YIELD_POLL_S:-$(conf_one yield_poll_s)}"; yield_poll="${yield_poll:-5}"
export SEAT_MERGE_IDLE_MINUTES="${SEAT_MERGE_IDLE_MINUTES:-$(conf_one idle_minutes)}"

# The default format check: only when the project has one. A custom command brings its own tool.
default_format=0
if [ -z "$FORMAT_CMD" ] && [ -f "$wt/package.json" ] && grep -q '"format:check"' "$wt/package.json"; then
  if [ -f "$wt/pnpm-lock.yaml" ]; then FORMAT_CMD="pnpm format:check"; else FORMAT_CMD="npm run format:check"; fi
  default_format=1
fi

# One run per worktree. Two runs in one merge worktree race on one index and HEAD. A non-blocking flock on a per-worktree
# file, taken BEFORE git is touched. The file lives in the runtime dir (never /tmp, never inside the worktree), keyed by the
# worktree's absolute path. The kernel holds the flock, not the file, so a lock left by a dead run (or by a reboot) never
# blocks. The holder writes its pid into the file for the refusal message.
RT="${SEAT_MERGE_RUNTIME_DIR:-${KIT_RUNTIME_DIR:-$HOME/.orchestration-kit/runtime}}"
# Never in the shared checkout. A failed run leaves the worktree detached on an UNPUSHED merge, which under the one shared
# checkout would sit under every sibling's `git status`. A linked worktree has its own git dir; the main working tree's git
# dir IS the common dir.
if [ "${SEAT_MERGE_ALLOW_SHARED_CHECKOUT:-}" != 1 ] && [ "$(cd "$(git rev-parse --git-dir)" && pwd -P)" = "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" ]; then
  die "$wt is the shared checkout, not a linked worktree. Run it in its own merge worktree: git worktree add --detach <path> origin/main (then cd there and install), so a refused run never leaves the shared checkout detached on an unpushed merge."
fi
lockfile="$RT/seat-merge/$(printf %s "$wt" | sha256sum | cut -c1-16).lock"
mkdir -p "$RT/seat-merge" || exit 2
# YIELD (see the header). Both numbers are whole seconds: a poll of 0 spins forever, "1h" or "0.5" would die on the
# arithmetic below (a non-number in `[ -ge ]` is false, so the loop never ends): fall back to the defaults and say so once.
[[ "$yield_max" =~ ^[0-9]{1,6}$ ]] || { echo "seat-merge: WARNING: ignoring yield_max_s='$yield_max' (whole seconds, at most 6 digits); using 3600" >&2; yield_max=3600; }
[[ "$yield_poll" =~ ^[1-9][0-9]*$ ]] || { echo "seat-merge: WARNING: ignoring yield_poll_s='$yield_poll' (whole seconds, at least 1); using 5" >&2; yield_poll=5; }
yielded=0
announced=""
while waiting=$(waiting_tickets "$RT/seat-merge") && [ -n "$waiting" ]; do
  if [ "$yielded" -ge "$yield_max" ]; then
    echo "seat-merge: WARNING: waited ${yielded}s for pusher pid $(head -n1 <<<"$waiting") and its ticket is still there; proceeding anyway" >&2
    break
  fi
  if [ -z "$announced" ]; then
    echo "seat-merge: yielding to pusher pid $(head -n1 <<<"$waiting") (waiting ticket); up to ${yield_max}s"
    announced=1
  fi
  sleep "$yield_poll"
  yielded=$((yielded + yield_poll))
done
# <> opens read-write WITHOUT truncating, so a refused second run cannot erase the live holder's pid.
exec 8<>"$lockfile" || exit 2
if ! flock -n 8; then
  # A killed seat-merge leaves its child (a test run) holding this lock. Still refused (that child may still write in the
  # worktree), but an orphan is named with the command that frees it, not reported as another run. This run's own fd 8 is on the
  # lock too, so $$ is left out of the holders. No visible holder (another user's process): the usual message.
  live=0 orphans=""
  # 8>&-: the command substitution's subshell (and its find) would inherit fd 8 and list itself as a holder.
  for p in $(seat_merge_lock_holders "$lockfile" 8>&-); do
    [ "$p" = "$$" ] && continue
    [ -e "/proc/$p" ] || continue  # exited since the listing: no holder
    if seat_merge_in_tree "$p"; then live=1; break; fi
    orphans+="$p "
  done
  if [ "$live" = 0 ] && [ -n "$orphans" ]; then
    for p in $orphans; do
      echo "seat-merge: REFUSED — the lock for $wt is held only by orphan pid $p ($(tr '\0' ' ' 2>/dev/null <"/proc/$p/cmdline" | cut -c1-160)), not by a live seat-merge.sh (a killed merge's child). Free it with: kill $p, then run again." >&2
    done
    exit 1
  fi
  echo "seat-merge: REFUSED — another seat-merge is running in $wt (pid $(tr -dc '0-9' <"$lockfile"))" >&2
  exit 1
fi
echo "$$" >"$lockfile"

# The default format check needs the worktree's own install. Without one the merge would succeed and then die at the check
# ("prettier: not found"), which spends the worktree's one run. Refused BEFORE git is touched, so the worktree stays usable.
if [ "$default_format" = 1 ] && [ ! -e "$wt/node_modules/.bin/prettier" ]; then
  die "no node_modules/.bin/prettier in $wt, so the format check cannot run after the merge. Install first, then re-run: (cd $wt && <your install command, e.g. pnpm install --offline --frozen-lockfile>)"
fi

# Tracked changes only: an untracked file cannot change a merge, and `git merge` itself refuses to overwrite one.
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the tree has tracked changes (dirty). Commit them or use a clean merge worktree."

git_net seat-merge fetch origin || die "fetch failed"

# HEAD must be on origin/main before anything reads from this tree. A format or check red leaves the worktree on its UNPUSHED
# merge; the next run would then read config and scripts from the refused branch's tree. After the fetch: a HEAD pushed since the
# last fetch is fine, and so is an older main. A conflict aborts back to main, so it needs no reset.
if ! git merge-base --is-ancestor HEAD origin/main; then
  stuck=$(git rev-parse --short=9 HEAD)
  die "HEAD $stuck is not on origin/main: this worktree still sits on a refused merge or a local commit. Nothing was touched. In a builder worktree do NOT reset: unpushed commits on a detached HEAD are lost; use a merge worktree. Otherwise reset it, then re-run: cd \"$wt\" && git checkout --detach origin/main"
fi

tip=$(git rev-parse -q --verify "refs/remotes/origin/$branch^{commit}") || die "no origin/$branch (only origin/<branch> is ever merged, never a local branch of that name). Push it first."
want=$(git rev-parse -q --verify "$expected^{commit}") || die "expected sha '$expected' is not a commit here"
[ "$tip" = "$want" ] || die "origin/$branch is at ${tip:0:9}, not the reviewed ${want:0:9}. Re-READ the new tip, or pass the sha that passed."
subject=$(git log -1 --format=%s "$tip")

if git merge-base --is-ancestor "$tip" origin/main; then
  echo "seat-merge: nothing to merge (origin/$branch ${tip:0:9} is already in origin/main)"
  exit 0
fi
echo "seat-merge: merging origin/$branch ${tip:0:9} \"$subject\""

git checkout -q --detach origin/main || die "cannot detach at origin/main"
# The conflict-marker exempt list was read above from THIS tree's config (origin/main, before the merge), never from the merged
# tree, so a branch cannot exempt its own markers.
CONFLICT_MARKERS_EXEMPT_TEXT="$MARKER_EXEMPT"; export CONFLICT_MARKERS_EXEMPT_TEXT
if ! mout=$(git merge --no-ff -q -m "$msg" "$tip" 2>&1); then
  git merge --abort >/dev/null 2>&1
  if grep -q 'untracked working tree files' <<<"$mout"; then
    die "an untracked file is in the way (not a conflict): $(grep -E '^[[:space:]]' <<<"$mout" | tr -s '[:space:]' ' '). Move it away, then re-run."
  fi
  die "merge conflict merging origin/$branch ${tip:0:9} onto origin/main (merge aborted, nothing pushed). Rebase the branch onto origin/main in its own worktree."
fi
merged=$(git rev-parse HEAD)

reset_hint() {
  echo "seat-merge: this worktree is detached on an UNPUSHED merge (${merged:0:9}); never push it by hand. Reset it: cd \"$wt\" && git checkout --detach origin/main"
}
guard_refuse() {
  {
    echo "seat-merge: REFUSED. $1 NOT pushed."
    echo "Fix it ON THE BRANCH (in its own worktree), commit, push, re-READ the new tip, then run seat-merge.sh again."
    reset_hint
  } >&2
  exit 1
}

# ---- committed conflict markers, listed up front, BEFORE the format check (a file with markers usually fails the formatter first
# and would hide the cause). The scan reads the MERGED tree (this worktree is at it). rc 2 = git itself failed: refuse, never "none".
markers_out=$(conflict_markers_report "$wt"); markers_rc=$?
if [ "$markers_rc" != 0 ]; then
  printf '%s\n' "$markers_out" >&2
  if [ "$markers_rc" = 1 ]; then guard_refuse "the merged tree has committed conflict markers (listed above)."; fi
  guard_refuse "the conflict-marker scan could not run (above)."
fi

# ---- the format check, on the merged tree
if [ -n "$FORMAT_CMD" ]; then
  if ! out=$(bash -c "$FORMAT_CMD" 2>&1); then
    files=$(printf '%s\n' "$out" | sed -n 's/^\[warn\] \([^ ].*[^ ]\)$/\1/p' | grep -v '^Code style issues' | tr '\n' ' ')
    {
      echo "seat-merge: REFUSED. The format check failed on the merged tree. NOT pushed."
      printf '%s\n' "$out" | tail -20
      echo "Fix it ON THE BRANCH (in its own worktree), commit, push, re-READ the new tip, then run seat-merge.sh again.${files:+ Files: $files}"
      reset_hint
    } >&2
    exit 1
  fi
else
  echo "seat-merge: no format check configured (set format_cmd in the seat_merge: block); skipped"
fi

# ---- the configured checks, on the merged tree
# The net diff of the merge (merged^1..merged) is the tree under test.
touched=$(git -c core.quotePath=false diff --no-renames --name-only "$merged^1" "$merged")
glog=$(mktemp "${TMPDIR:-/tmp}/seat-merge-check-XXXXXX") || guard_refuse "cannot make a temp file for the check log."
touched_matches() {  # <globs>: does any changed path match any pattern? (a pattern's * matches any characters, '/' included)
  local g p rc=1
  set -f   # the patterns are matched below, never expanded against the current directory
  for g in $1; do
    if [ "$g" = '*' ]; then rc=0; break; fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2053  # the pattern is meant to glob
      if [[ "$p" == $g ]]; then rc=0; break 2; fi
    done <<<"$touched"
  done
  set +f
  return $rc
}
names=(); globs=(); cmds=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  IFS='|' read -r cname cglobs ccmd <<<"$line"
  cname=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$cname"); cglobs=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$cglobs")
  ccmd=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$ccmd")
  # The command is the rest of the line after the second `|` (it may contain `|` itself).
  ccmd=$(sed -E 's/^[^|]*\|[^|]*\|[[:space:]]*//;s/[[:space:]]*$//' <<<"$line")
  if [ -z "$cname" ] || [ -z "$cglobs" ] || [ -z "$ccmd" ]; then
    guard_refuse "a check line is malformed ('$line'); it must be: name | globs | command."
  fi
  names+=("$cname"); globs+=("$cglobs"); cmds+=("$ccmd")
done <<<"$CHECKS"
selected=()
for i in "${!names[@]}"; do
  if touched_matches "${globs[$i]}"; then selected+=("$i"); fi
done
if [ "${#selected[@]}" -gt 0 ]; then
  checks_started=1
  checks_t0=$(mono_now)
  # Each command is a background job the script waits on, with the signal traps on only across it (see the top of this file).
  seat_merge_signals_on
  if [ -n "$INSTALL_CMD" ]; then
    # A stale install in the merge worktree would give a false green after a dependency change.
    seat_merge_bg_wait bash -c "$INSTALL_CMD" || { seat_merge_signals_off; tail -5 "$glog" >&2; guard_refuse "the install before the checks failed ($INSTALL_CMD)."; }
  fi
  export SEAT_MERGE_TOUCHED="$touched" SEAT_MERGE_MERGED="$merged"
  for i in "${selected[@]}"; do
    export SEAT_MERGE_CHECK="${names[$i]}"
    if ! seat_merge_bg_wait bash -c "${cmds[$i]}"; then
      echo "seat-merge: check '${names[$i]}' was red; rerunning once, alone"
      seat_merge_bg_wait bash -c "${cmds[$i]}" || { seat_merge_signals_off; tail -20 "$glog" >&2; guard_refuse "the check '${names[$i]}' is red on the merged tree (twice)."; }
    fi
    echo "seat-merge: check '${names[$i]}' green"
  done
  seat_merge_signals_off
  echo "seat-merge: checks took $(mono_elapsed "$checks_t0")s"
elif [ "${#names[@]}" -eq 0 ]; then
  echo "seat-merge: no checks configured (add check: lines to the seat_merge: block); only the format check ran"
else
  echo "seat-merge: ${#names[@]} check(s) configured, none apply to the paths this merge changes"
fi

# ---- a push lost to a board/log-only commit is redone, not refused. Cause: the checks can take many minutes; a board or build-log
# commit landing in that window makes the push non-fast-forward, and refusing the whole merge wasted the run. When every
# commit in <checked merge's parent 1>..origin/main touches only the allowed paths, the SAME merge (--no-ff, same message,
# same second parent = the READ sha) is redone onto the new origin/main and pushed without re-running the checks. At most 3
# retries; any foreign path upstream, a conflict on the redo, a redo whose tree differs from the checked one outside the
# allowed paths, or the 4th lost push refuses, with nothing forced.
allowed() {
  local a rc=1
  set -f
  for a in $ALLOWED_PATHS; do
    case "$a" in */) [[ "$1" == "$a"* ]] && { rc=0; break; } ;; *) [ "$1" = "$a" ] && { rc=0; break; } ;; esac
  done
  set +f
  return $rc
}
not_allowed() { local f; while IFS= read -r f; do allowed "$f" || printf '%s\n' "$f"; done | sort -u; }
foreign_paths() {  # $1 = rev range: every path outside the allowed ones that any commit in it touches (merges included)
  local sha
  for sha in $(git rev-list "$1"); do
    git -c core.quotePath=false diff-tree --no-commit-id --name-only -r -m "$sha"
  done | not_allowed
}
push_refuse() {  # $1 = why. Nothing was pushed.
  {
    echo "seat-merge: REFUSED. push failed (nothing forced): $1 NOT pushed."
    echo "seat-merge: this worktree is detached and the checked merge (${checked:0:9}) is NOT pushed; never push it by hand. Reset it: cd \"$wt\" && git checkout --detach origin/main"
  } >&2
  exit 1
}
checked=$merged; base=$(git rev-parse "$merged^1"); tries=0
until git_net seat-merge push origin "$merged":main; do
  git_net seat-merge fetch origin || push_refuse "fetch failed after the rejected push."
  [ "$(git rev-parse origin/main)" != "$(git rev-parse "$merged^1")" ] || push_refuse "origin/main did not move, so this is not a lost race."
  tries=$((tries + 1))
  [ "$tries" -le 3 ] || push_refuse "origin/main moved again on each of 3 retries; run seat-merge.sh again."
  fp=$(foreign_paths "$base..origin/main")
  [ -z "$fp" ] || push_refuse "origin/main moved during the checks by commits outside the allowed paths ($(printf '%s' "$fp" | head -3 | tr '\n' ' ')); the checks ran on a tree without them. Re-run seat-merge.sh."
  git checkout -q --detach origin/main || push_refuse "cannot detach at the new origin/main."
  git merge-base --is-ancestor "$tip" origin/main && push_refuse "origin/$branch ${tip:0:9} is already in the new origin/main."
  if ! git merge --no-ff -q -m "$msg" "$tip" >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1
    push_refuse "the merge redone onto the new origin/main hit a conflict (or an untracked file in the way) and was aborted."
  fi
  new=$(git rev-parse HEAD)
  [ "$(git rev-parse "$new^2")" = "$tip" ] || push_refuse "the redone merge's second parent is not the READ sha ${tip:0:9}."
  # The redone tree may differ from the checked one only in the allowed paths, or the checks no longer vouch for it.
  outside=$(git diff --no-renames --name-only "$checked" "$new" | not_allowed)
  [ -z "$outside" ] || push_refuse "the redone merge differs from the checked one outside the allowed paths ($(printf '%s' "$outside" | head -3 | tr '\n' ' '))."
  merged=$new
  echo "seat-merge: origin/main moved during the checks by allowed-path-only commits: merge redone (${merged:0:9}), retry ${tries}, checks not re-run"
done
retries="$tries retries"; [ "$tries" -ne 1 ] || retries="1 retry"

# ---- the merged row's builder worktree is dead weight once its branch is on main (hundreds fill a disk). Removed only when it is
# provably idle: not this merge worktree, not the main working tree, no tracked, modified or untracked file (`status
# --porcelain` covers all three), and no process with its cwd inside it. Otherwise one line says why it was kept. Never
# `--force`: `git worktree remove` refuses a dirty or locked tree on its own, as a second guard. The local branch ref stays,
# so no commit is lost. A failure here never fails a merge that is already pushed.
cleanup_builder_worktree() {  # $1 = branch
  local br=$1 path="" line cur="" why
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur=${line#worktree }  ;;
      "branch refs/heads/$br") path=$cur ;;
    esac
  done < <(git worktree list --porcelain)
  [ -n "$path" ] || return 0   # no worktree has the branch checked out: nothing to remove
  why=$(worktree_removal_blocker "$path" "$br" "$wt")
  if [ -n "$why" ]; then echo "seat-merge: kept builder worktree $path: $why"; return 0; fi
  path=$(cd "$path" && pwd -P)
  local idle="${SEAT_MERGE_IDLE_MINUTES:-30}" err
  if err=$(worktree_remove_clean "$path" 2>&1); then echo "seat-merge: removed builder worktree $path (clean: no tracked, untracked or non-rebuildable ignored file; no commit beyond origin/main; no file changed in $idle min; no process cwd inside)"
  else echo "seat-merge: kept builder worktree $path: git refused to remove it ($(printf '%s' "$err" | head -1))"; fi
}
if git branch -r --contains "$merged" | grep -qE '^[[:space:]]*origin/main$'; then
  merge_ok=1
  echo "seat-merge: pushed ${merged} (origin/main contains it) · ${retries}"
  cleanup_builder_worktree "$branch" || true
  # Move the main checkout to the new origin/main (never fails a merge that is already pushed). This script refuses to run in the
  # shared checkout, so the fast-forward never rewrites the file bash is reading.
  bash "$SEAT_MERGE_LIB/sync-main-checkout.sh" || true
else
  echo "seat-merge: pushed ${merged} but origin/main does not list it" >&2
  exit 1
fi
