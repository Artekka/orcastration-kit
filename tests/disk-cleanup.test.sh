#!/usr/bin/env bash
# Tests for the kit's disk cleanup, ported from the project whose SSD filled (>=170 GB of old Docker images,
# worktrees and leftovers): scripts/retro-worktrees.sh, scripts/docker-cache-cap.sh, scripts/gate-disk-guard.sh and its wiring into
# scripts/gate-throttle.sh. Run: bash tests/disk-cleanup.test.sh
# Safety: every repo is a throwaway under mktemp (a bare "origin" plus a clone); `df` and `docker` are FAKE scripts, so no real
# disk, image or container is read or touched; HOME, git config and the runtime dir are temp; no network, no tmux.
set -u
unset TMUX TMUX_PANE
unset KIT_GATE_MIN_FREE_GB   # the guard tests below pass their own value; a caller's 0 would switch the guard off under test
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RW="$ROOT/scripts/retro-worktrees.sh"; DC="$ROOT/scripts/docker-cache-cap.sh"; DG="$ROOT/scripts/gate-disk-guard.sh"; GT="$ROOT/scripts/gate-throttle.sh"
pass=0; fail=0; SANDBOXES=()
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
cleanup() { local d; for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G() { git "$@" >/dev/null 2>&1; }
TMP="$(mktemp -d)"; SANDBOXES+=("$TMP")

# ── A. retro-worktrees.sh ─────────────────────────────────────────────────────────────────────────────────────────────────────
# sandbox: SB/origin.git (bare) and SB/work (the clone = the main working tree; the script runs from a tree inside SB)
sandbox() {
  SB="$(mktemp -d)"; SANDBOXES+=("$SB")
  git init -q --bare -b main "$SB/origin.git"
  git clone -q "$SB/origin.git" "$SB/work" 2>/dev/null; G -C "$SB/work" checkout -q -b main
  echo hi > "$SB/work/README.md"; G -C "$SB/work" add README.md; G -C "$SB/work" commit -q -m seed; G -C "$SB/work" push -q origin main
  G -C "$SB/work" fetch -q origin
}
# tree NAME MERGED: a worktree on a new branch NAME made at origin/main; MERGED=1 also puts one commit on origin/main.
# Files are aged 3 hours so the 30-minute idle check passes.
tree() {
  local path="$SB/${1//\//-}"
  G -C "$SB/work" worktree add -q -b "$1" "$path" origin/main
  if [ "$2" = 1 ]; then
    echo x > "$path/${1//\//-}.txt"; G -C "$path" add . ; G -C "$path" commit -q -m "feat: $1"
    G -C "$path" push -q origin "$1:main"; G -C "$SB/work" fetch -q origin
  fi
  find "$path" -type f -not -path '*/.git/*' -exec touch -d '3 hours ago' {} + 2>/dev/null
  TREE="$path"
}
rw() { (cd "$SB/work" && bash "$RW" "$@" 2>&1; echo "rc=$?"); }

sandbox
out="$(rw)"; has "no --prefix: usage" "usage: scripts/retro-worktrees.sh" "$out"; has "no --prefix: exit 2" "rc=2" "$out"
out="$(rw --prefix '')"; has "an empty prefix is refused (it would match every worktree)" "rc=2" "$out"
out="$(rw --bogus)"; has "an unknown option is refused" "rc=2" "$out"
out="$(rw --prefix s5e30)"; has "a prefix without a closing slash is refused (it would match s5e307/)" "rc=2" "$out"

sandbox; tree s5e307/a 1; a="$TREE"
out="$(rw --prefix s5e307/)"
has "a merged, clean, idle tree is removed" "retro-worktrees: removed $(cd "$SB" && pwd -P)/s5e307-a" "$out"
has "the summary line" "retro-worktrees: removed 1, kept 0" "$out"
[ ! -d "$a" ] && ok || bad "the tree directory is still there"
[ -n "$(git -C "$SB/work" branch --list 's5e307/a')" ] && ok || bad "the branch ref was deleted (it must stay)"

sandbox; tree s5e307/a 1; tree other/b 1
out="$(rw --prefix s5e307/)"
hasnt "another prefix is not even mentioned" "other-b" "$out"; [ -d "$TREE" ] && ok || bad "a tree with another prefix was removed"

sandbox; tree s5e307/a 1; echo dirty > "$TREE/new.txt"
out="$(rw --prefix s5e307/)"
has "a dirty tree is kept with the reason" "kept" "$out"; has "dirty reason" "uncommitted or untracked" "$out"; [ -d "$TREE" ] && ok || bad "a dirty tree was removed"

# an untracked node_modules SYMLINK (a link to a shared install) is not work: the tree goes, the link with it, the install stays
sandbox; tree s5e307/a 1; mkdir "$SB/shared-nm"; echo keep > "$SB/shared-nm/f"; ln -s "$SB/shared-nm" "$TREE/node_modules"
out="$(rw --prefix s5e307/)"
has "a tree whose only extra is a node_modules symlink is removed" "retro-worktrees: removed" "$out"; [ ! -d "$TREE" ] && ok || bad "the tree with a node_modules link is still there"
[ "$(cat "$SB/shared-nm/f")" = keep ] && ok || bad "the link's target was touched"

# keep rule: an IGNORED file that is not rebuildable output (a secrets file such as .env) keeps an otherwise merged, clean, idle tree
sandbox; printf '.env\n' >> "$SB/work/.git/info/exclude"; tree s5e307/a 1; echo 'TOKEN=x' > "$TREE/.env"; find "$TREE" -type f -not -path '*/.git/*' -exec touch -d '3 hours ago' {} +
out="$(rw --prefix s5e307/)"
has "an ignored non-build file (.env) keeps the tree" "ignored file that is not rebuildable output" "$out"; [ -f "$TREE/.env" ] && ok || bad "the .env file was deleted with its tree"
# keep rule: the shared check itself refuses a tree whose branch has local commits that origin/main lacks
sandbox; tree s5e307/a 0; echo y > "$TREE/y.txt"; G -C "$TREE" add y.txt; G -C "$TREE" commit -q -m "local only"; find "$TREE" -type f -not -path '*/.git/*' -exec touch -d '3 hours ago' {} +
out="$(cd "$SB/work" && . "$ROOT/scripts/lib-builder-worktree.sh" && worktree_removal_blocker "$TREE" s5e307/a "" 2>&1)"
has "a worktree with local commits not on origin/main is kept" "1 commit(s) not on origin/main" "$out"

sandbox; tree s5e307/a 0; echo y > "$TREE/y.txt"; G -C "$TREE" add y.txt; G -C "$TREE" commit -q -m "unmerged work"; find "$TREE" -type f -not -path '*/.git/*' -exec touch -d '3 hours ago' {} +
out="$(rw --prefix s5e307/)"
has "an unmerged branch is kept" "is not merged into origin/main" "$out"; [ -d "$TREE" ] && ok || bad "an unmerged tree was removed"

sandbox; tree s5e307/a 1
( cd "$TREE" && exec sleep 30 ) & holder=$!; sleep 0.3
out="$(rw --prefix s5e307/)"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
has "a merged, idle tree with a live process cwd inside is kept" "has its cwd inside it" "$out"; [ -d "$TREE" ] && ok || bad "a tree with a live process inside was removed"

sandbox; tree s5e307/a 1; touch "$TREE/README.md"
out="$(rw --prefix s5e307/)"
has "a tree with a file changed in the last 30 minutes is kept" "a file changed in the last 30 min" "$out"; [ -d "$TREE" ] && ok || bad "a fresh tree was removed"

sandbox; tree s5e307/a 1; here="$TREE"
out="$(cd "$here" && bash "$RW" --prefix s5e307/ 2>&1; echo "rc=$?")"
has "the worktree it runs in is never removed" "it is the worktree this ran in" "$out"; [ -d "$here" ] && ok || bad "the tree it ran in was removed"
sandbox; det="$SB/det"; G -C "$SB/work" worktree add -q --detach "$det" origin/main
out="$(rw --prefix s5e307/)"; hasnt "a detached tree is skipped silently" "det" "$out"; [ -d "$det" ] && ok || bad "a detached tree was removed"

sandbox; tree s5e307/a 1
out="$(rw --prefix s5e307/ --dry-run)"
has "--dry-run says 'would remove'" "would remove" "$out"; has "--dry-run summary" "retro-worktrees: would remove 1, kept 0" "$out"; [ -d "$TREE" ] && ok || bad "--dry-run removed a tree"

sandbox; tree s5e307/a 1; ta="$TREE"; tree s5e307/b 1; tb="$TREE"; echo d > "$tb/dirty.txt"; tree s5e307/c 1; tc="$TREE"
out="$(rw --prefix s5e307/)"; has "several trees: the clean ones go, the dirty one stays" "retro-worktrees: removed 2, kept 1" "$out"
[ ! -d "$ta" ] && [ -d "$tb" ] && [ ! -d "$tc" ] && ok || bad "wrong set removed"

# never --force: a git shim on PATH records every `worktree remove` and passes everything through to the real git
sandbox; tree s5e307/a 1; REAL_GIT="$(command -v git)"; mkdir -p "$SB/shim"
printf '#!/usr/bin/env bash\n[ "${1:-}" = worktree ] && [ "${2:-}" = remove ] && echo "$*" >> "%s/git.calls"\nexec "%s" "$@"\n' "$SB" "$REAL_GIT" > "$SB/shim/git"; chmod +x "$SB/shim/git"
out="$(cd "$SB/work" && PATH="$SB/shim:$PATH" bash "$RW" --prefix s5e307/ 2>&1; echo "rc=$?")"
has "the shim saw the removal" "removed" "$out"; has "git worktree remove was called" "worktree remove" "$(cat "$SB/git.calls" 2>/dev/null)"
case "$(cat "$SB/git.calls" 2>/dev/null)" in *--force*|*" -f"*) bad "retro-worktrees must never pass --force to git worktree remove" ;; *) ok ;; esac

# ── B. docker-cache-cap.sh (a FAKE docker records its argv) ───────────────────────────────────────────────────────────────────
FD="$TMP/fakedocker"; CALLS="$TMP/docker.calls"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n[ -n "${FAKE_DOCKER_FAIL:-}" ] && exit 1\nexit 0\n' "$CALLS" > "$FD"; chmod +x "$FD"
dc() { : > "$CALLS"; KIT_DOCKER_BIN="$FD" "$@" bash "$DC" "${ARGS[@]}" 2>&1; echo "rc=$?"; }
ARGS=(); out="$(: > "$CALLS"; KIT_DOCKER_BIN="$FD" bash "$DC" 2>&1; echo "rc=$?")"
eq "default cap: exactly one call, the build cache only, 40GB" "builder prune --force --max-used-space 40GB" "$(cat "$CALLS")"; has "exit 0" "rc=0" "$out"
out="$(: > "$CALLS"; KIT_BUILD_CACHE_KEEP=10GB KIT_DOCKER_BIN="$FD" bash "$DC" 2>&1; echo "rc=$?")"
has "KIT_BUILD_CACHE_KEEP overrides the cap" "--max-used-space 10GB" "$(cat "$CALLS")"
out="$(: > "$CALLS"; FAKE_DOCKER_FAIL=1 KIT_DOCKER_BIN="$FD" bash "$DC" 2>&1; echo "rc=$?")"
has "a failing prune only warns" "WARNING: docker builder prune failed" "$out"; has "and still exits 0" "rc=0" "$out"
out="$(: > "$CALLS"; KIT_DOCKER_BIN="$FD" bash "$DC" --dry-run 2>&1; echo "rc=$?")"
has "--dry-run names the command" "would run:" "$out"; eq "--dry-run runs nothing" "" "$(cat "$CALLS")"
out="$(KIT_DOCKER_BIN="$TMP/no-such-docker" bash "$DC" 2>&1; echo "rc=$?")"
has "no docker: a note" "not found; nothing to trim" "$out"; has "no docker: exit 0" "rc=0" "$out"
out="$(KIT_DOCKER_BIN="$FD" bash "$DC" --bogus 2>&1; echo "rc=$?")"; has "an unknown argument is refused" "rc=2" "$out"
case "$(cat "$CALLS")" in *"--all"*|*"system prune"*) bad "docker-cache-cap must prune the BUILD cache only" ;; *) ok ;; esac

# ── C. gate-disk-guard.sh (a FAKE df reports $FAKE_FREE_GB) ───────────────────────────────────────────────────────────────────
FDF="$TMP/fakedf"
cat > "$FDF" <<'DF'
#!/usr/bin/env bash
[ "${FAKE_DF_BROKEN:-}" = 1 ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "fake 999999999 1 $(( ${FAKE_FREE_GB:-100} * 1024 * 1024 )) 1% ${KIT_GATE_DISK_PATH:-/}"
DF
chmod +x "$FDF"
dg() { local free=$1; shift; (cd "$TMP" && env KIT_DF_BIN="$FDF" FAKE_FREE_GB="$free" "$@" bash "$DG" 2>&1; echo "rc=$?"); }
out="$(dg 5)"; has "refuses below the default 20 GB" "GATE REFUSED: only 5 GB free" "$out"; has "refusal exits 1" "rc=1" "$out"
has "the refusal tells what to do" "retro-worktrees.sh" "$out"
out="$(dg 50)"; has "proceeds above the default" "rc=0" "$out"; hasnt "silent when there is room" "REFUSED" "$out"
out="$(dg 20)"; has "at exactly the threshold it proceeds (-lt, not -le)" "rc=0" "$out"
out="$(dg 19)"; has "one GB under refuses" "rc=1" "$out"
out="$(dg 50 KIT_GATE_MIN_FREE_GB=60)"; has "KIT_GATE_MIN_FREE_GB raises the minimum" "rc=1" "$out"
out="$(dg 5 KIT_GATE_MIN_FREE_GB=2)"; has "KIT_GATE_MIN_FREE_GB lowers the minimum" "rc=0" "$out"
out="$(dg 0 KIT_GATE_MIN_FREE_GB=0)"; has "0 turns the guard off" "rc=0" "$out"
out="$(dg 5 KIT_GATE_MIN_FREE_GB=lots)"; has "a non-number warns" "WARNING: KIT_GATE_MIN_FREE_GB='lots' is not a number; using 20" "$out"; has "and falls back to 20 (5 GB refused)" "rc=1" "$out"
out="$(dg 5 FAKE_DF_BROKEN=1)"; has "an unreadable df warns" "could not read free space; continuing" "$out"; has "and does not block" "rc=0" "$out"
out="$(dg 5 KIT_GATE_DISK_PATH=/data)"; has "the refusal names the disk checked" "free on /data" "$out"
# the team block sets the minimum when the env does not (read from the main checkout)
sandbox; mkdir -p "$SB/work/docs/orchestration"; printf 'gate_min_free_gb: 60\n' > "$SB/work/docs/orchestration/ORCHESTRATION.md"
out="$(cd "$SB/work" && env KIT_DF_BIN="$FDF" FAKE_FREE_GB=50 bash "$DG" 2>&1; echo "rc=$?")"; has "gate_min_free_gb: in the team block sets the minimum" "rc=1" "$out"
out="$(cd "$SB/work" && env KIT_DF_BIN="$FDF" FAKE_FREE_GB=50 KIT_GATE_MIN_FREE_GB=30 bash "$DG" 2>&1; echo "rc=$?")"; has "the env beats the team block" "rc=0" "$out"

# ── D. gate-throttle.sh runs the guard before it queues ───────────────────────────────────────────────────────────────────────
command -v flock >/dev/null 2>&1 && {
  RTD="$TMP/rt"; mkdir -p "$RTD"; : > "$TMP/ran"
  gt() { local free=$1; shift; (cd "$TMP" && env KIT_RUNTIME_DIR="$RTD" GATE_POLL=0.1 GATE_MAX_LOAD=1000000 GATE_SLOTS=2 KIT_DF_BIN="$FDF" FAKE_FREE_GB="$free" "$@" bash "$GT" bash -c 'echo ran >> "$0"' "$TMP/ran" 2>&1; echo "rc=$?"); }
  out="$(gt 5)"; has "a low disk refuses the gate (exit 1)" "rc=1" "$out"; has "with the guard's message" "GATE REFUSED" "$out"
  eq "the command did not run" 0 "$(wc -l < "$TMP/ran")"
  eq "and no ticket or run entry was created" "" "$(ls "$RTD/queue" "$RTD/running" 2>/dev/null | tr -d '\n')"
  printf 'OLD LOG\n' > "$TMP/keep.log"
  out="$(cd "$TMP" && env KIT_RUNTIME_DIR="$RTD" GATE_POLL=0.1 GATE_SLOTS=2 KIT_DF_BIN="$FDF" FAKE_FREE_GB=5 bash "$GT" --log "$TMP/keep.log" bash -c true 2>&1; echo "rc=$?")"
  has "--log: a refused gate exits 1" "rc=1" "$out"; eq "--log: a refusal leaves the earlier log intact" "OLD LOG" "$(cat "$TMP/keep.log")"
  out="$(gt 100)"; has "enough disk: the gate runs" "rc=0" "$out"; eq "the command ran once" 1 "$(wc -l < "$TMP/ran")"
  out="$(gt 5 KIT_GATE_MIN_FREE_GB=1)"; has "a lowered minimum lets it through" "rc=0" "$out"
  # a project that did not copy the guard script has no check
  mkdir -p "$TMP/noguard/scripts"; cp "$GT" "$ROOT/scripts/lib-kit-home.sh" "$TMP/noguard/scripts/"; : > "$TMP/ran"
  out="$(cd "$TMP" && env KIT_RUNTIME_DIR="$RTD" GATE_POLL=0.1 GATE_MAX_LOAD=1000000 GATE_SLOTS=2 KIT_DF_BIN="$FDF" FAKE_FREE_GB=1 bash "$TMP/noguard/scripts/gate-throttle.sh" bash -c 'echo ran >> "$0"' "$TMP/ran" 2>&1; echo "rc=$?")"
  has "without the guard script the throttle just runs" "rc=0" "$out"
}

# ── E. pins: what travels with a project, what the docs and the retro skill say ───────────────────────────────────────────────
for s in retro-worktrees.sh docker-cache-cap.sh gate-disk-guard.sh; do
  [ -x "$ROOT/scripts/$s" ] && ok || bad "scripts/$s is not executable"
  grep -q "$s" "$ROOT/scripts/bootstrap.sh" && ok || bad "bootstrap.sh does not install $s"
  grep -q "$s" "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install $s"
done
grep -q 'lib-builder-worktree.sh' "$ROOT/scripts/retro-worktrees.sh" && ok || bad "retro-worktrees.sh no longer sources lib-builder-worktree.sh (it travels with it)"
grep -q 'retro-worktrees.sh --prefix' "$ROOT/skills/retro/SKILL.md" && ok || bad "the retro skill does not run retro-worktrees.sh --prefix (Step 4b)"
grep -q 'Step 4b counts' "$ROOT/skills/retro/SKILL.md" && ok || bad "the retro skill's final summary does not report the Step 4b counts"
grep -q '^## Disk cleanup' "$ROOT/README.md" && ok || bad "README.md has no 'Disk cleanup' section"
grep -q 'Disk cleanup' "$ROOT/CHANGELOG.md" && ok || bad "CHANGELOG.md has no 'Disk cleanup' entry"

echo "disk-cleanup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
