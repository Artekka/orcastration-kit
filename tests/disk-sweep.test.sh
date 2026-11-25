#!/usr/bin/env bash
# Tests for the scheduled disk sweep: scripts/disk-sweep.sh, scripts/disk-sweep-cron.sh, scripts/lib-disk-sweep-launch.sh,
# the SessionStart hook that starts it and gate-disk-guard.sh's early start. Run: bash tests/disk-sweep.test.sh
# Safety: every repo is a throwaway under mktemp (a bare "origin" plus a clone); HOME, the kit state folder, the temp folder,
# the scratch root and the report folder are temp; `df` and `docker` are FAKE scripts, so no real disk, image or container is
# read or touched. Every deleting path runs only inside these sandboxes. No network, no tmux.
set -u
unset TMUX TMUX_PANE KIT_SWEEP_SCRATCH KIT_SWEEP_AUTO KIT_SWEEP_LAUNCH KIT_SWEEP_CRON_SWEEP KIT_GATE_MIN_FREE_GB KIT_SWEEP_FLOOR_GB
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS="$ROOT/scripts/disk-sweep.sh"; DW="$ROOT/scripts/disk-sweep-cron.sh"; DL="$ROOT/scripts/lib-disk-sweep-launch.sh"
DG="$ROOT/scripts/gate-disk-guard.sh"; HOOK="$ROOT/hooks/session-start.sh"
pass=0; fail=0; SANDBOXES=(); HOLDERS=()
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
yes_() { if [ "$2" = 0 ]; then ok; else bad "$1"; fi; }   # yes_ "msg" "$?"
cleanup() {
  local p d
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done
  for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do chmod -R u+w "$d" 2>/dev/null; rm -rf "$d"; done
}
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G() { git "$@" >/dev/null 2>&1; }
TMP="$(cd "$(mktemp -d)" && pwd -P)"; SANDBOXES+=("$TMP")

# A FAKE df: free space from $FAKE_FREE_GB, use from $FAKE_PCT; FAKE_DF_BROKEN=1 fails.
FDF="$TMP/fakedf"
cat > "$FDF" <<'DF'
#!/usr/bin/env bash
[ "${FAKE_DF_BROKEN:-}" = 1 ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "fake 999999999 1 $(( ${FAKE_FREE_GB:-100} * 1024 * 1024 )) ${FAKE_PCT:-40}% /"
DF
chmod +x "$FDF"

# sandbox: SB/origin.git (bare), SB/work (the main checkout), SB/home (HOME), SB/tmp (the temp folder), SB/reports.
sandbox() {
  SB="$(cd "$(mktemp -d)" && pwd -P)"; SANDBOXES+=("$SB")
  git init -q --bare -b main "$SB/origin.git"
  git clone -q "$SB/origin.git" "$SB/work" 2>/dev/null; G -C "$SB/work" checkout -q -b main
  echo hi > "$SB/work/README.md"; G -C "$SB/work" add README.md; G -C "$SB/work" commit -q -m seed; G -C "$SB/work" push -q origin main
  G -C "$SB/work" fetch -q origin
  mkdir -p "$SB/home" "$SB/tmp" "$SB/reports"
}
# age DIR DAYS: every file and folder in DIR (the tree's .git link file too) gets an mtime DAYS days back.
age() { find "$1" -exec touch -h -d "$2 days ago" {} + 2>/dev/null; }
# tree NAME MERGED [DAYS]: a worktree on a new branch NAME at origin/main; MERGED=1 also lands one commit of it on origin/main.
tree() {
  local path="$SB/${1//\//-}"
  G -C "$SB/work" worktree add -q -b "$1" "$path" origin/main
  if [ "$2" = 1 ]; then
    echo x > "$path/${1//\//-}.txt"; G -C "$path" add . ; G -C "$path" commit -q -m "feat: $1"
    G -C "$path" push -q origin "$1:main"; G -C "$SB/work" fetch -q origin
  fi
  age "$path" "${3:-3}"
  TREE="$path"
}
# commit_in TREE: one more commit on the tree's branch (not pushed)
commit_in() { echo "$RANDOM" > "$1/c$RANDOM.txt"; G -C "$1" add . ; G -C "$1" commit -q -m more; }
NODOCKER="$TMP/no-such-docker"
# ds [env...] -- [args...]: run the sweep from the main checkout with the sandbox's HOME, temp folder and report folder.
ds() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  (cd "$SB/work" && env HOME="$SB/home" KIT_SWEEP_TMP="$SB/tmp" KIT_SWEEP_DOCKER="$NODOCKER" KIT_SWEEP_DF="$FDF" \
    KIT_SWEEP_REPORT_DIR="$SB/reports" ${envs[@]+"${envs[@]}"} bash "$DS" --repo "$SB/work" "$@" 2>&1; echo "rc=$?")
}
gone() { if [ ! -e "$2" ]; then ok; else bad "$1 (still there: $2)"; fi; }
there() { if [ -e "$2" ]; then ok; else bad "$1 (missing: $2)"; fi; }
branch_stays() { if [ -n "$(git -C "$SB/work" branch --list "$1")" ]; then ok; else bad "branch $1 was deleted (it must stay)"; fi; }

# ── A. the command line: DRY RUN by default ─────────────────────────────────────────────────────────────────────────────────────
sandbox; tree s1/a 1; a="$TREE"
out="$(ds)"
has "no flag is a dry run: it says 'would remove'" "would remove $a" "$out"
there "no flag removes nothing (dry run is the default)" "$a"
has "the dry run names its report" "disk-sweep: report $SB/reports/" "$out"
r="$(ls "$SB/reports" | head -1)"; has "the dry run's report is named -dry-run" "-dry-run.txt" "$r"
out="$(ds -- --apply --dry-run)"; there "--apply with --dry-run changes nothing" "$a"
out="$(ds -- --apply)"
has "--apply removes a merged, clean, idle tree" "removed $a" "$out"; gone "--apply removed the merged tree" "$a"; branch_stays s1/a
has "the run prints free space before and after" "free before" "$out"; has "... and after" "after" "$out"
rep="$(ls "$SB/reports"/*.txt | grep -v dry-run | head -1)"; there "--apply writes a dated report" "$rep"
head -6 "$rep" > "$TMP/head"; has "the report's top says free before/after" "free before" "$(cat "$TMP/head")"
has "the report's top says freed per class" "freed:" "$(cat "$TMP/head")"; has "the report's top says kept per reason" "kept:" "$(cat "$TMP/head")"
out="$(ds -- --bogus)"; has "an unknown flag is refused (exit 2)" "rc=2" "$out"
out="$(cd "$TMP" && env HOME="$SB/home" KIT_SWEEP_DF="$FDF" bash "$DS" --repo "$TMP" 2>&1; echo "rc=$?")"; has "--repo that is not a git repo: exit 2" "rc=2" "$out"
# --repo defaults to the git top level of the current folder
sandbox; tree s1/a 1; a="$TREE"
out="$(cd "$SB/work" && env HOME="$SB/home" KIT_SWEEP_TMP="$SB/tmp" KIT_SWEEP_DOCKER="$NODOCKER" KIT_SWEEP_DF="$FDF" KIT_SWEEP_REPORT_DIR="$SB/reports" bash "$DS" 2>&1)"
has "with no --repo the current repo is swept" "would remove $a" "$out"

# ── B. worktree keep rules ──────────────────────────────────────────────────────────────────────────────────────────────────────
sandbox; tree s1/a 1 1; a="$TREE"
out="$(ds -- --apply)"; has "a file changed inside the age (2 days) keeps a merged tree" "kept $a" "$out"; there "a fresh merged tree stays" "$a"
out="$(ds -- --apply --urgent)"; gone "--urgent shortens the age to 1 day" "$a"
sandbox; tree s1/a 1 1.5; a="$TREE"
out="$(ds FAKE_PCT=90 -- --apply)"; has "85% used or more turns urgent on by itself" "urgent" "$out"; gone "the automatic urgent run removed a 1.5-day tree" "$a"
# the ignored-file check: an ignored file that is not rebuildable output (.env) keeps a merged, clean, idle tree (not 14 days idle)
sandbox; printf '.env\n' >> "$SB/work/.git/info/exclude"; tree s1/a 1; a="$TREE"; echo 'TOKEN=x' > "$a/.env"; age "$a" 3
out="$(ds -- --apply)"
has "an ignored non-build file (.env) keeps the tree" "ignored file that is not rebuildable output" "$out"; there "the .env tree stays" "$a/.env"
sandbox; tree s1/a 1; a="$TREE"; echo dirty > "$a/new.txt"; age "$a" 3
out="$(ds -- --apply)"; has "an untracked file keeps a 3-day tree" "uncommitted or untracked" "$out"; there "the dirty 3-day tree stays" "$a/new.txt"
sandbox; tree s1/a 1; a="$TREE"
( cd "$a" && exec sleep 60 ) & HOLDERS+=($!); h=$!; sleep 0.3
out="$(ds -- --apply)"; kill "$h" 2>/dev/null; wait "$h" 2>/dev/null
has "a live process with its cwd inside keeps the tree" "live process" "$out"; there "the tree with a live process stays" "$a"
sandbox; tree s1/a 1; a="$TREE"
sleep 60 < "$a/README.md" & HOLDERS+=($!); h=$!; sleep 0.3
out="$(ds -- --apply)"; kill "$h" 2>/dev/null; wait "$h" 2>/dev/null
has "a live process holding a file open keeps the tree" "live process" "$out"; there "the tree with an open file stays" "$a"
sandbox; tree s1/a 1; a="$TREE"; G -C "$SB/work" worktree lock --reason "parked by hand" "$a"
out="$(ds -- --apply)"; has "a locked worktree is kept" "locked" "$out"; there "a locked tree stays" "$a"
sandbox; tree s1/a 1; a="$TREE"
out="$(cd "$a" && env HOME="$SB/home" KIT_SWEEP_TMP="$SB/tmp" KIT_SWEEP_DOCKER="$NODOCKER" KIT_SWEEP_DF="$FDF" KIT_SWEEP_REPORT_DIR="$SB/reports" bash "$DS" --apply 2>&1)"
has "the tree it runs in is kept" "it is the worktree this ran in" "$out"; there "the tree it ran in stays" "$a"
there "the main checkout is never removed" "$SB/work/README.md"
# board: a board line names the branch (an open row) keeps it; a done line does not; no board = one "skipped" line
sandbox; tree s1/a 1; a="$TREE"; tree s1/b 1; b="$TREE"
out="$(ds)"; has "no board: one skipped line" "skipped: no board" "$out"
mkdir -p "$SB/work/docs/orchestration"
printf '# board\n🔨 **ROW-1 CLAIMED** builder on s1/a\n✅ **ROW-2 DONE** merged from s1/b\n' > "$SB/work/docs/orchestration/AGENT_BOARD.md"
G -C "$SB/work" add docs; G -C "$SB/work" commit -q -m board; G -C "$SB/work" push -q origin main; G -C "$SB/work" fetch -q origin
out="$(ds -- --apply)"
has "an open board line that names the branch keeps the tree" "the board names it" "$out"; there "the open-row tree stays" "$a"
gone "a DONE line does not keep the tree" "$b"

# ── C. unmerged branches (rule a: 14 days, clean, origin has the SAME tip) ─────────────────────────────────────────────────────
sandbox; tree s1/a 0; a="$TREE"; commit_in "$a"; G -C "$a" push -q origin s1/a; G -C "$SB/work" fetch -q origin; age "$a" 15
out="$(ds -- --apply)"; has "rule a removes the folder" "rule a" "$out"; gone "an unmerged clean tree, 15 days idle, origin same tip, is removed" "$a"; branch_stays s1/a
sandbox; tree s1/a 0; a="$TREE"; commit_in "$a"; G -C "$a" push -q origin s1/a; G -C "$SB/work" fetch -q origin; age "$a" 5
out="$(ds -- --apply)"; there "an unmerged tree idle only 5 days stays" "$a"
# the same-tip check: origin has the branch, but at another commit
sandbox; tree s1/a 0; a="$TREE"; commit_in "$a"; G -C "$a" push -q origin s1/a; commit_in "$a"; G -C "$SB/work" fetch -q origin; age "$a" 15
out="$(ds -- --apply)"; has "a tip that differs from origin's keeps the tree" "differs from origin" "$out"; there "the tree whose tip differs stays" "$a"
sandbox; tree s1/a 0; a="$TREE"; commit_in "$a"; age "$a" 15
out="$(ds -- --apply)"; has "a branch origin does not have keeps the tree" "origin has no copy" "$out"; there "the never-pushed tree stays" "$a"

# ── D. detached trees (rule b: a keep ref first, read back) ─────────────────────────────────────────────────────────────────────
sandbox; d="$SB/det"; G -C "$SB/work" worktree add -q --detach "$d" origin/main; commit_in "$d"; sha="$(git -C "$d" rev-parse HEAD)"; age "$d" 15
out="$(ds -- --apply)"; has "rule b names the keep ref" "refs/kit-sweep-keep/det" "$out"; gone "a detached tree on an unpushed commit, 15 days idle, goes" "$d"
eq "the keep ref holds the commit" "$sha" "$(git -C "$SB/work" rev-parse -q --verify refs/kit-sweep-keep/det)"
sandbox; d="$SB/det"; G -C "$SB/work" worktree add -q --detach "$d" origin/main; age "$d" 3
out="$(ds -- --apply)"; gone "a detached tree on a commit origin/main has follows the 2-day rule" "$d"
sandbox; d="$SB/det"; G -C "$SB/work" worktree add -q --detach "$d" origin/main; commit_in "$d"; age "$d" 5
out="$(ds -- --apply)"; there "a detached tree on an unpushed commit, 5 days idle, stays" "$d"

# ── E. dirty idle trees are SAVED, read back, then removed (Art's pick, 11-25) ─────────────────────────────────────────────────
sandbox; printf '.env\n' >> "$SB/work/.git/info/exclude"; tree s1/a 1; a="$TREE"
echo changed >> "$a/README.md"; echo new > "$a/new.txt"; echo 'TOKEN=x' > "$a/.env"; age "$a" 15
out="$(ds)"; has "a dry run says it would save and remove a dirty idle tree" "would save and remove $a" "$out"; there "the dry run kept the dirty tree" "$a/new.txt"
eq "the dry run wrote no save" "" "$(ls "$SB/home/.orcastration-kit/disk-sweep/saved" 2>/dev/null)"
out="$(ds -- --apply)"; has "the apply run says it saved the tree" "saved $a" "$out"; gone "the saved dirty tree is removed" "$a"; branch_stays s1/a
sv="$(find "$SB/home/.orcastration-kit/disk-sweep/saved" -mindepth 2 -maxdepth 2 -type d -name 's1-a-*' | head -1)"
there "the save folder exists" "$sv/changes.patch"; there "the untracked files are in a tar" "$sv/files.tar"
has "the patch holds the tracked change" "+changed" "$(cat "$sv/changes.patch" 2>/dev/null)"
tl="$(tar -tf "$sv/files.tar" 2>/dev/null)"; has "the tar holds the untracked file" "new.txt" "$tl"; has "the tar holds the ignored .env" ".env" "$tl"
has "the save says how to undo it" "git worktree add" "$(cat "$sv/info.txt" 2>/dev/null)"
G -C "$SB/work" worktree add -q "$SB/restore" s1/a; (cd "$SB/restore" && git apply "$sv/changes.patch" && tar -xf "$sv/files.tar") >/dev/null 2>&1
eq "the saved work restores byte for byte (README)" "$(printf 'hi\nchanged')" "$(cat "$SB/restore/README.md" 2>/dev/null)"
eq "the saved work restores byte for byte (new.txt)" "new" "$(cat "$SB/restore/new.txt" 2>/dev/null)"
r="$(ls "$SB/reports"/*.txt | grep -v dry-run | head -1)"; has "the report states the saved size and removal date" "removed after" "$(cat "$r")"
# a hidden edit (skip-worktree) cannot be saved: kept and listed for the orchestrator
sandbox; tree s1/a 1; a="$TREE"; echo hidden >> "$a/README.md"; G -C "$a" update-index --skip-worktree README.md; echo u > "$a/u.txt"; age "$a" 15
out="$(ds -- --apply)"; has "a skip-worktree tree is listed as needing a decision" "needs a decision" "$out"; there "the skip-worktree tree stays" "$a"
# a save older than 30 days goes
sandbox; old="$SB/home/.orcastration-kit/disk-sweep/saved/x/old-20260101"; mkdir -p "$old"; echo p > "$old/changes.patch"; age "$SB/home/.orcastration-kit/disk-sweep/saved/x" 31
out="$(ds -- --apply)"; gone "a saved bundle older than 30 days is removed" "$old"

# ── F. rebuildable bulk inside idle trees ───────────────────────────────────────────────────────────────────────────────────────
mknm() {  # mknm DIR: a node_modules of 20 real files
  mkdir -p "$1/node_modules/p"; local i; for i in $(seq 1 20); do echo "$i" > "$1/node_modules/p/f$i.js"; done
}
sandbox; printf 'node_modules/\n' >> "$SB/work/.git/info/exclude"; tree s1/a 0; a="$TREE"; commit_in "$a"; mknm "$a"; age "$a" 3
out="$(ds -- --apply)"; gone "a real-copy node_modules in an idle kept tree is removed" "$a/node_modules"; there "the tree itself stays" "$a"
has "the line names node_modules" "node_modules" "$out"
sandbox; printf 'node_modules/\n' >> "$SB/work/.git/info/exclude"; tree s1/a 0; a="$TREE"; commit_in "$a"
mkdir -p "$SB/store" "$a/node_modules/p"; for i in $(seq 1 20); do echo "$i" > "$SB/store/f$i"; ln "$SB/store/f$i" "$a/node_modules/p/f$i.js"; done; age "$a" 3
out="$(ds -- --apply)"; there "a hard-linked (shared) node_modules stays" "$a/node_modules/p/f1.js"
sandbox; printf 'node_modules/\n' >> "$SB/work/.git/info/exclude"; tree s1/a 0; a="$TREE"; commit_in "$a"; mknm "$a"; age "$a" 1
out="$(ds -- --apply)"; there "node_modules in a tree used yesterday stays" "$a/node_modules/p/f1.js"
# build output found by content (index.html + an assets folder), whatever its name
sandbox; printf 'dist-*/\n' >> "$SB/work/.git/info/exclude"; tree s1/a 1; a="$TREE"
mkdir -p "$a/dist-m1/assets"; echo '<html>' > "$a/dist-m1/index.html"; echo 'x' > "$a/dist-m1/assets/a.js"; age "$a" 3
out="$(ds -- --apply)"; has "a saved build copy is found by content" "build output" "$out"; gone "the merged tree with only a build copy extra goes" "$a"
sandbox; printf 'dist-*/\n' >> "$SB/work/.git/info/exclude"; tree s1/a 0; a="$TREE"; commit_in "$a"
mkdir -p "$a/dist-r2/assets" "$a/site/assets"; echo '<html>' > "$a/dist-r2/index.html"; echo x > "$a/dist-r2/assets/a.js"
echo '<html>' > "$a/site/index.html"; echo x > "$a/site/assets/s.js"; G -C "$a" add site; G -C "$a" commit -q -m site; age "$a" 3
out="$(ds -- --apply)"; gone "an ignored build copy in a kept tree is removed" "$a/dist-r2"; there "a TRACKED folder of the same shape stays" "$a/site/index.html"

# ── G. headless browser leftovers in the temp folder ───────────────────────────────────────────────────────────────────────────
sandbox; mkdir -p "$SB/tmp/playwright-artifacts-1" "$SB/tmp/playwright-artifacts-2" "$SB/tmp/.org.chromium.Chromium.abc" "$SB/tmp/other"
echo x > "$SB/tmp/playwright-artifacts-1/f"; echo x > "$SB/tmp/.org.chromium.Chromium.abc/f"; echo x > "$SB/tmp/other/f"; echo x > "$SB/tmp/playwright-artifacts-2/f"
age "$SB/tmp" 1; touch "$SB/tmp/playwright-artifacts-2/f"
out="$(ds -- --apply)"; gone "an old playwright folder goes" "$SB/tmp/playwright-artifacts-1"; gone "an old chromium profile goes" "$SB/tmp/.org.chromium.Chromium.abc"
there "a fresh playwright folder stays" "$SB/tmp/playwright-artifacts-2"; there "other temp folders are never touched" "$SB/tmp/other/f"
sandbox; mkdir -p "$SB/tmp/playwright-artifacts-9"; age "$SB/tmp" 1
( cd "$SB/tmp/playwright-artifacts-9" && exec sleep 60 ) & HOLDERS+=($!); h=$!; sleep 0.3
out="$(ds -- --apply)"; kill "$h" 2>/dev/null; wait "$h" 2>/dev/null; there "a leftover a live process holds stays" "$SB/tmp/playwright-artifacts-9"

# ── H. Docker build cache: the freed number is Docker's own before/after ──────────────────────────────────────────────────────
FDK="$TMP/fakedocker"; DCALLS="$TMP/docker.calls"; DSTATE="$TMP/docker.state"
cat > "$FDK" <<DK
#!/usr/bin/env bash
echo "\$*" >> "$DCALLS"
case "\$1 \${2:-}" in
  "system df") if [ -f "$DSTATE" ]; then echo "Images|5GB"; echo "Build Cache|10GB"; else echo "Images|5GB"; echo "Build Cache|30GB"; fi ;;
  "images "*) echo "1GB" ;;
  "builder prune") touch "$DSTATE" ;;
  "ps "*) : ;;
esac
exit 0
DK
chmod +x "$FDK"
sandbox; : > "$DCALLS"; rm -f "$DSTATE"
out="$(ds KIT_SWEEP_DOCKER="$FDK" -- --apply)"
has "the cache is trimmed to the cap" "builder prune --force --max-used-space 20GB" "$(cat "$DCALLS")"
has "freed comes from Docker's own count (30 GB before, 10 GB after)" "freed 20.0 GB" "$out"
c="$(cat "$DCALLS")"; hasnt "never docker system prune" "system prune" "$c"; hasnt "never a volume" "volume" "$c"; hasnt "never an image removal" "rmi" "$c"; hasnt "never image rm" "image rm" "$c"
sandbox; : > "$DCALLS"; rm -f "$DSTATE"; out="$(ds KIT_SWEEP_DOCKER="$FDK")"; hasnt "a dry run prunes nothing" "builder prune" "$(cat "$DCALLS")"; has "a dry run says what it would trim" "would trim" "$out"
sandbox; out="$(ds)"; has "no docker: one skipped line" "skipped: docker" "$out"

# ── I. scratch folder (optional): bulk inside idle folders ──────────────────────────────────────────────────────────────────────
sandbox; out="$(ds)"; has "no scratch folder: one skipped line" "skipped: no scratch folder" "$out"
sandbox; S="$SB/scratch"; mkdir -p "$S/2026/x" "$S/y" "$S/z/build/assets" "$S/w"
mknm "$S/2026/x"; echo note > "$S/2026/x/notes.txt"; mknm "$S/y"; touch "$S/y/.keep"
echo '<html>' > "$S/z/build/index.html"; echo x > "$S/z/build/assets/a.js"; mknm "$S/w"; age "$S" 8; touch "$S/w/fresh.txt"
out="$(ds KIT_SWEEP_SCRATCH="$S" -- --apply)"
gone "node_modules in an idle scratch folder goes" "$S/2026/x/node_modules"; there "the folder's own files stay" "$S/2026/x/notes.txt"
has "a PURGED.txt line records what went" "node_modules" "$(cat "$S/2026/x/PURGED.txt" 2>/dev/null)"
there "a folder with .keep is kept whole" "$S/y/node_modules"; gone "a build copy in scratch is found by content" "$S/z/build"
there "a folder with a file changed in 7 days is kept" "$S/w/node_modules"

# ── J. never --force, never branch -D, never a volume; no home literal, no project name ──────────────────────────────────────────
code() { grep -v '^[[:space:]]*#' "$@" 2>/dev/null; }
SWEEP_FILES=("$DS" "$DW" "$DL" "$ROOT"/scripts/lib-disk-sweep*.sh)
c="$(code "${SWEEP_FILES[@]}")"
case "$c" in *"worktree remove --force"*|*"worktree remove -f"*) bad "a sweep script passes --force to git worktree remove" ;; *) ok ;; esac
case "$c" in *"branch -D"*) bad "a sweep script runs git branch -D" ;; *) ok ;; esac
case "$c" in *"system prune"*|*"volume rm"*|*"volume prune"*|*" rmi "*|*"image rm"*|*"image prune"*) bad "a sweep script touches Docker images or volumes" ;; *) ok ;; esac
if grep -n '/home/' "${SWEEP_FILES[@]}" >/dev/null 2>&1; then bad "a sweep script has a /home/ literal"; else ok; fi
if grep -in 'einherjar' "${SWEEP_FILES[@]}" >/dev/null 2>&1; then bad "a sweep script names a project"; else ok; fi
[ -x "$DS" ] && [ -x "$DW" ] && ok || bad "the sweep scripts are not executable"
# a git shim on PATH records every `worktree remove`
sandbox; tree s1/a 1; REAL_GIT="$(command -v git)"; mkdir -p "$SB/shim"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -C ] && [ "${3:-}" = worktree ] && [ "${4:-}" = remove ] && echo "$*" >> "%s/git.calls"\n[ "${1:-}" = worktree ] && [ "${2:-}" = remove ] && echo "$*" >> "%s/git.calls"\nexec "%s" "$@"\n' "$SB" "$SB" "$REAL_GIT" > "$SB/shim/git"; chmod +x "$SB/shim/git"
out="$(ds PATH="$SB/shim:$PATH" -- --apply)"; has "the shim saw a worktree removal" "worktree remove" "$(cat "$SB/git.calls" 2>/dev/null)"
case "$(cat "$SB/git.calls" 2>/dev/null)" in *--force*|*" -f "*) bad "the sweep passed --force to git worktree remove" ;; *) ok ;; esac

# ── K. the off switch ───────────────────────────────────────────────────────────────────────────────────────────────────────────
sandbox
out="$(HOME="$SB/home" bash "$DS" --off 2>&1)"; there "--off writes the off file" "$SB/home/.orcastration-kit/disk-sweep.off"; has "--off says how to turn it on" "--on" "$out"
out="$(HOME="$SB/home" bash "$DS" --status 2>&1)"; has "--status says off" "off" "$out"
out="$(cd "$SB/work" && HOME="$SB/home" KIT_SWEEP_DF="$FDF" bash "$DW" --repo "$SB/work" 2>&1; echo "rc=$?")"; has "the wrapper does nothing while off" "turned off" "$out"
out="$(HOME="$SB/home" bash "$DS" --on 2>&1)"; gone "--on removes the off file" "$SB/home/.orcastration-kit/disk-sweep.off"

# ── L. the wrapper: first run is a dry run, one sweep at a time, stamp at start, unknown free space = no sweep, low priority ─────
KH() { echo "$SB/home/.orcastration-kit"; }
dw() { (cd "$SB/work" && env HOME="$SB/home" KIT_SWEEP_TMP="$SB/tmp" KIT_SWEEP_DOCKER="$NODOCKER" KIT_SWEEP_DF="$FDF" KIT_SWEEP_REPORT_DIR="$SB/reports" "$@" bash "$DW" --repo "$SB/work" 2>&1; echo "rc=$?"); }
sandbox; tree s1/a 1; a="$TREE"
out="$(dw)"; has "the first run on a machine is a dry run" "first run on this machine: dry run" "$out"; there "the first run removed nothing" "$a"
there "the first run left a report for the next session start" "$(KH)/disk-sweep/unseen-report"
there "the stamp is written" "$(KH)/disk-sweep.last"
out="$(dw)"; gone "the second run applies" "$a"
# a fake sweep: records its args and its nice value, sleeps, exits with $FAKE_RC
FS="$TMP/fakesweep"
cat > "$FS" <<'FSW'
#!/usr/bin/env bash
echo "$* nice=$(ps -o ni= -p $$ | tr -d ' ')" >> "$FAKE_SWEEP_LOG"
sleep "${FAKE_SLEEP:-0}"
echo "disk-sweep: report /nowhere/report.txt"
exit "${FAKE_RC:-0}"
FSW
chmod +x "$FS"
sandbox; L="$SB/sweep.log"
out="$(dw KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L" FAKE_RC=1)"; has "a failed sweep is logged FAILED" "FAILED" "$out"
there "the stamp is written at the start even when the sweep fails (no loop)" "$(KH)/disk-sweep.last"
case "$(cat "$L")" in *"nice=19"*) ok ;; *) command -v nice >/dev/null 2>&1 && bad "the sweep does not run at low priority: $(cat "$L")" || ok ;; esac
sandbox; L="$SB/sweep.log"
( dw KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L" FAKE_SLEEP=3 >/dev/null ) & first=$!; sleep 1
out="$(dw KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L")"; wait "$first"
has "a second wrapper while one runs exits at once" "another disk sweep is running" "$out"; eq "only one sweep ran" 1 "$(wc -l < "$L")"
sandbox; L="$SB/sweep.log"; : > "$L"
out="$(dw KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L" FAKE_DF_BROKEN=1)"; has "an unreadable free space means no sweep (exit 3)" "rc=3" "$out"; eq "no sweep ran" 0 "$(wc -l < "$L")"
# no ionice, setsid, flock or stat on PATH (macOS, plain Linux): the wrapper still runs, one at a time
NB="$TMP/nobin"; mkdir -p "$NB"
IFS=: read -r -a pdirs <<< "$PATH"
for d in ${pdirs[@]+"${pdirs[@]}"}; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do n=$(basename "$f"); case "$n" in ionice|setsid|flock|stat) continue ;; esac; [ -e "$NB/$n" ] || ln -s "$f" "$NB/$n" 2>/dev/null; done
done
sandbox; L="$SB/sweep.log"; tree s1/a 1; a="$TREE"
( dw PATH="$NB" KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L" FAKE_SLEEP=3 >/dev/null ) & first=$!; sleep 1
out="$(dw PATH="$NB" KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L")"; wait "$first"
has "without flock a second wrapper still exits at once" "another disk sweep is running" "$out"; eq "without flock only one sweep ran" 1 "$(wc -l < "$L")"
out="$(dw PATH="$NB")"; out="$(dw PATH="$NB")"; gone "without ionice/setsid/flock/stat the real sweep still removes" "$a"

# ── M. the SessionStart hook and the launcher ───────────────────────────────────────────────────────────────────────────────────
FL="$TMP/fakelaunch"; printf '#!/usr/bin/env bash\necho "$*" >> "$FAKE_LAUNCH_LOG"\n' > "$FL"; chmod +x "$FL"
optin() { mkdir -p "$SB/work/docs/orchestration"; : > "$SB/work/docs/orchestration/.kit-hooks"; }
hk() { (cd "$SB/work" && printf '{"cwd":"%s"}' "$SB/work" | env HOME="$SB/home" CLAUDE_PROJECT_DIR="$SB/work" KIT_SWEEP_DF="$FDF" KIT_SWEEP_LAUNCH="$FL" FAKE_LAUNCH_LOG="$SB/launch.log" "$@" bash "$HOOK" 2>&1); }
json_ok() { printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }
sandbox; optin; t0=$(date +%s); out="$(hk)"; t1=$(date +%s)
json_ok "$out"; yes_ "the hook prints valid JSON" $?
has "the hook keeps its orient message" "orcastration-kit:orient" "$out"; has "the hook says the sweep is on" "isk sweep" "$out"
has "the hook names the off command" "--off" "$out"
has "the hook launched a sweep (no stamp yet)" "$SB/work" "$(cat "$SB/launch.log" 2>/dev/null)"
[ $((t1 - t0)) -le 3 ] && ok || bad "the hook took $((t1 - t0)) s (it must never wait)"
mkdir -p "$(KH)"; date +%s > "$(KH)/disk-sweep.last"; : > "$SB/launch.log"
out="$(hk)"; eq "a fresh stamp and room on disk: no launch" "" "$(cat "$SB/launch.log")"
out="$(hk FAKE_FREE_GB=30)"; has "under the floor (50 GB): a launch even with a fresh stamp" "$SB/work" "$(cat "$SB/launch.log")"
: > "$SB/launch.log"; touch "$(KH)/disk-sweep.off"; rm -f "$(KH)/disk-sweep.last"
out="$(hk)"; eq "off: no launch" "" "$(cat "$SB/launch.log")"; rm -f "$(KH)/disk-sweep.off"
mkdir -p "$(KH)/disk-sweep"; printf '%s\n' "$SB/reports/2026-11-25-dry-run.txt" > "$(KH)/disk-sweep/unseen-report"; date +%s > "$(KH)/disk-sweep.last"
out="$(hk)"; json_ok "$out"; yes_ "the report message is valid JSON" $?
has "the next session start shows the first report" "2026-11-25-dry-run.txt" "$out"; has "the report message is shown to the user" "systemMessage" "$out"
gone "the report is shown once" "$(KH)/disk-sweep/unseen-report"
sandbox; out="$(hk)"; eq "a repo that did not opt in: no output" "" "$out"; eq "... and no launch" "" "$(cat "$SB/launch.log" 2>/dev/null)"
out="$(hk KIT_SWEEP_AUTO=0)"; eq "KIT_SWEEP_AUTO=0 never launches" "" "$(cat "$SB/launch.log" 2>/dev/null)"
# ten sessions starting together start ONE sweep (the real launcher and wrapper, a fake sweep)
sandbox; optin; L="$SB/sweep.log"; : > "$L"
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( cd "$SB/work" && printf '{}' | env HOME="$SB/home" CLAUDE_PROJECT_DIR="$SB/work" KIT_SWEEP_DF="$FDF" KIT_SWEEP_CRON_SWEEP="$FS" FAKE_SWEEP_LOG="$L" FAKE_SLEEP=2 bash "$HOOK" >/dev/null 2>&1 ) &
done
wait; n=0; while [ "$n" -lt 50 ] && [ ! -s "$L" ]; do sleep 0.1; n=$((n+1)); done; sleep 3
eq "ten session starts at once ran one sweep" 1 "$(wc -l < "$L")"
# gate-disk-guard starts the sweep early under the floor; its refusal is unchanged
sandbox; optin; : > "$SB/launch.log"
out="$(cd "$SB/work" && env HOME="$SB/home" KIT_DF_BIN="$FDF" KIT_SWEEP_DF="$FDF" FAKE_FREE_GB=30 KIT_SWEEP_LAUNCH="$FL" FAKE_LAUNCH_LOG="$SB/launch.log" bash "$DG" 2>&1; echo "rc=$?")"
has "the guard lets a 30 GB gate run" "rc=0" "$out"; has "the guard started a sweep under the 50 GB floor" "$SB/work" "$(cat "$SB/launch.log")"
: > "$SB/launch.log"
out="$(cd "$SB/work" && env HOME="$SB/home" KIT_DF_BIN="$FDF" KIT_SWEEP_DF="$FDF" FAKE_FREE_GB=5 KIT_SWEEP_LAUNCH="$FL" FAKE_LAUNCH_LOG="$SB/launch.log" bash "$DG" 2>&1; echo "rc=$?")"
has "the guard still refuses under 20 GB" "rc=1" "$out"; has "and still starts the sweep" "$SB/work" "$(cat "$SB/launch.log")"
sandbox; : > "$SB/launch.log"
out="$(cd "$SB/work" && env HOME="$SB/home" KIT_DF_BIN="$FDF" KIT_SWEEP_DF="$FDF" FAKE_FREE_GB=30 KIT_SWEEP_LAUNCH="$FL" FAKE_LAUNCH_LOG="$SB/launch.log" bash "$DG" 2>&1)"
eq "the guard in a repo that did not opt in starts nothing" "" "$(cat "$SB/launch.log")"

# ── N. docs and version pins ───────────────────────────────────────────────────────────────────────────────────────────────────
grep -q '"version": "0.18.0"' "$ROOT/.claude-plugin/plugin.json" && ok || bad "plugin.json is not 0.18.0"
first="$(grep -m1 -A3 '^## ' "$ROOT/CHANGELOG.md")"
has "the CHANGELOG's newest entry is 0.18.0" "0.18.0" "$first"
has "the CHANGELOG's first line says what the kit removes by itself" "removes idle merged worktrees" "$first"
has "the CHANGELOG's first line says dry run first" "dry run" "$first"; has "the CHANGELOG's first line says how to turn it off" "--off" "$first"
grep -q '^## Disk sweep' "$ROOT/README.md" && ok || bad "README.md has no 'Disk sweep' section"
grep -q 'disk-sweep/' "$ROOT/README.md" && ok || bad "README.md does not say where the report goes"
grep -q 'disk-sweep' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "the setup skill does not mention the disk sweep"

echo "disk-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
