#!/usr/bin/env bash
# Tests for scripts/seat-merge.sh (+ lib-builder-worktree.sh, lib-waiting-tickets.sh): ported from the project that grew the script,
# with its fix history. Run: bash tests/seat-merge.test.sh
# Safety: every repo is a throwaway under mktemp (a bare "origin", a builder clone, a merge clone); HOME and the runtime dir are
# temp; git config is isolated; no network. Processes are killed only by exact pid.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SM="$ROOT/scripts/seat-merge.sh"
pass=0; fail=0; SANDBOXES=(); PIDS=()
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
cleanup() { local p d; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done; for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G() { git "$@" >/dev/null 2>&1; }

# sandbox: SB/origin.git (bare), SB/builder (clone), SB/merge (clone = the merge worktree under test), SB/other (a second pusher).
sandbox() {
  SB="$(mktemp -d)"; SANDBOXES+=("$SB"); mkdir -p "$SB/home" "$SB/rt" "$SB/bin"
  git init -q --bare -b main "$SB/origin.git"
  git clone -q "$SB/origin.git" "$SB/builder" 2>/dev/null; G -C "$SB/builder" checkout -q -b main
  mkdir -p "$SB/builder/docs/orchestration" "$SB/builder/src"
  echo base > "$SB/builder/src/a.txt"; echo board > "$SB/builder/docs/orchestration/BOARD.md"
  extra_seed
  G -C "$SB/builder" add -A; G -C "$SB/builder" commit -q -m seed; G -C "$SB/builder" push -q origin main
  git clone -q "$SB/origin.git" "$SB/merge" 2>/dev/null; git clone -q "$SB/origin.git" "$SB/other" 2>/dev/null
}
extra_seed() { :; }
# branch NAME FILE CONTENT: a branch off origin/main with one commit, pushed; BSHA = its sha.
branch() {
  G -C "$SB/builder" fetch -q origin; G -C "$SB/builder" checkout -q -B "$1" origin/main
  mkdir -p "$(dirname "$SB/builder/$2")"; printf '%s\n' "$3" > "$SB/builder/$2"
  G -C "$SB/builder" add "$2"; G -C "$SB/builder" commit -q -m "feat: $1"; G -C "$SB/builder" push -q -f origin "$1"
  BSHA=$(git -C "$SB/builder" rev-parse HEAD)
}
# sm <env pairs...> -- <args...>  -> RC OUT ERR
sm() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  RC=0
  env HOME="$SB/home" PATH="$SB/bin:$PATH" SEAT_MERGE_REPO="$SB/merge" SEAT_MERGE_RUNTIME_DIR="$SB/rt" SEAT_MERGE_ALLOW_SHARED_CHECKOUT=1 \
    SEAT_MERGE_FORMAT_CMD=true "${envs[@]}" bash "$SM" "$@" >"$SB/out" 2>"$SB/err" </dev/null || RC=$?
  OUT="$(cat "$SB/out")"; ERR="$(cat "$SB/err")"
}
omain() { git -C "$SB/origin.git" rev-parse main; }

# 1. usage
sandbox; sm -- onlyone; eq "T1 usage exit" 2 "$RC"; has "T1 usage text" "usage:" "$ERR"

# 2. the happy path: a --no-ff merge whose second parent is the READ sha, pushed, confirmed; nothing else on main
sandbox; branch feat src/b.txt new; before=$(omain)
sm -- feat "$BSHA" "merge: feat"
eq "T2 exit 0" 0 "$RC"; has "T2 says what it merges" "merging origin/feat ${BSHA:0:9} \"feat: feat\"" "$OUT"; has "T2 pushed line" "(origin/main contains it) · 0 retries" "$OUT"
eq "T2 second parent is the READ sha" "$BSHA" "$(git -C "$SB/origin.git" rev-parse "main^2")"; eq "T2 first parent is the old main" "$before" "$(git -C "$SB/origin.git" rev-parse "main^1")"
eq "T2 merge message" "merge: feat" "$(git -C "$SB/origin.git" log -1 --format=%s main)"

# 3. only origin/<branch> is ever merged: a stale local branch of the same name in the merge clone is ignored
sandbox; branch feat src/b.txt new
G -C "$SB/merge" checkout -q -b feat; echo evil > "$SB/merge/src/evil.txt"; G -C "$SB/merge" add -A; G -C "$SB/merge" commit -q -m "local only"; G -C "$SB/merge" checkout -q main
sm -- feat "$BSHA" "merge: feat"
eq "T3 exit 0" 0 "$RC"; eq "T3 the local-only commit never reached main" "" "$(git -C "$SB/origin.git" ls-tree -r --name-only main | grep evil || true)"
eq "T3 the pushed file did" src/b.txt "$(git -C "$SB/origin.git" ls-tree -r --name-only main | grep 'b.txt')"

# 4. refusals before any merge
sandbox; branch feat src/b.txt new; before=$(omain)
sm -- feat 0000000000000000000000000000000000000000 "m"; eq "T4 unknown expected sha" 1 "$RC"; has "T4 says so" "is not a commit here" "$ERR"
sm -- nosuch "$BSHA" "m"; eq "T4 no origin branch" 1 "$RC"; has "T4 says only origin" "no origin/nosuch" "$ERR"
branch feat src/b.txt newer
sm -- feat "$(git -C "$SB/merge" rev-parse origin/main)" "m"; eq "T4 tip moved from the reviewed sha" 1 "$RC"; has "T4 names both" "not the reviewed" "$ERR"
eq "T4 main untouched by every refusal" "$before" "$(omain)"

# 5. already in origin/main = nothing to merge, exit 0
sandbox; branch feat src/b.txt new; sm -- feat "$BSHA" "m"; sm -- feat "$BSHA" "m"
eq "T5 exit 0" 0 "$RC"; has "T5 nothing to merge" "nothing to merge" "$OUT"

# 6. a dirty (tracked) tree is refused; an untracked file in the way and a conflict each get their own refusal; nothing pushed
sandbox; branch feat src/b.txt new; before=$(omain)
echo dirty >> "$SB/merge/src/a.txt"; sm -- feat "$BSHA" "m"; eq "T6 dirty" 1 "$RC"; has "T6 dirty text" "tracked changes" "$ERR"; G -C "$SB/merge" checkout -- src/a.txt
echo mine > "$SB/merge/src/b.txt"; sm -- feat "$BSHA" "m"; eq "T6 untracked in the way" 1 "$RC"; has "T6 own message" "untracked file is in the way (not a conflict)" "$ERR"; rm "$SB/merge/src/b.txt"
sandbox; branch feat src/a.txt "feature side"; G -C "$SB/other" pull -q; echo "main side" > "$SB/other/src/a.txt"; G -C "$SB/other" commit -qam "main edit"; G -C "$SB/other" push -q origin main; before=$(omain)
sm -- feat "$BSHA" "m"; eq "T6 conflict" 1 "$RC"; has "T6 conflict text" "merge conflict" "$ERR"; eq "T6 main untouched" "$before" "$(omain)"; eq "T6 the conflict was aborted (clean tree)" "" "$(git -C "$SB/merge" status --porcelain)"

# 7. the format check runs on the MERGED tree; red = nothing pushed, the worktree is left detached with a reset hint
sandbox; branch feat src/b.txt new; before=$(omain)
sm SEAT_MERGE_FORMAT_CMD='echo "[warn] src/b.txt"; echo "[warn] Code style issues found"; exit 1' -- feat "$BSHA" "m"
eq "T7 exit 1" 1 "$RC"; has "T7 refused" "The format check failed on the merged tree. NOT pushed." "$ERR"; has "T7 lists the file" "Files: src/b.txt" "$ERR"; has "T7 reset hint" "git checkout --detach origin/main" "$ERR"
eq "T7 main untouched" "$before" "$(omain)"; eq "T7 worktree detached on the merge" "" "$(git -C "$SB/merge" symbolic-ref -q HEAD || true)"
# the format command sees the merged tree (after the red above the worktree needs the printed reset first)
G -C "$SB/merge" checkout -q --detach origin/main
sm SEAT_MERGE_FORMAT_CMD='test -f src/b.txt' -- feat "$BSHA" "m"; eq "T7 the check ran on the merged tree" 0 "$RC"
# no format check configured = a note, not a failure
sandbox; branch feat src/b.txt new; sm SEAT_MERGE_FORMAT_CMD= -- feat "$BSHA" "m"; eq "T7 no format check: exit 0" 0 "$RC"; has "T7 says skipped" "no format check configured" "$OUT"

# 8. the default format check refuses BEFORE git is touched when the formatter is not installed
sandbox
extra_seed() { printf '{"scripts":{"format:check":"true"}}\n' > "$SB/builder/package.json"; }
sandbox; extra_seed() { :; }
branch feat src/b.txt new; head0=$(git -C "$SB/merge" rev-parse HEAD)
printf '{"scripts":{"format:check":"true"}}\n' > "$SB/builder/package.json"; G -C "$SB/builder" add package.json; G -C "$SB/builder" commit -qm pkg; G -C "$SB/builder" push -q origin HEAD:main
G -C "$SB/merge" pull -q; head0=$(git -C "$SB/merge" rev-parse HEAD); branch feat2 src/c.txt c
sm SEAT_MERGE_FORMAT_CMD= -- feat2 "$BSHA" "m"; eq "T8 refused" 1 "$RC"; has "T8 says why" "no node_modules/.bin/prettier" "$ERR"; eq "T8 HEAD unchanged (git untouched)" "$head0" "$(git -C "$SB/merge" rev-parse HEAD)"
mkdir -p "$SB/merge/node_modules/.bin"; : > "$SB/merge/node_modules/.bin/prettier"
printf '#!/usr/bin/env bash\necho "npm $*" >> "%s/npm.log"\n' "$SB" > "$SB/bin/npm"; chmod +x "$SB/bin/npm"
sm SEAT_MERGE_FORMAT_CMD= -- feat2 "$BSHA" "m"; eq "T8 with the install it merges" 0 "$RC"; has "T8 ran the project's own script via npm" "npm run format:check" "$(cat "$SB/npm.log" 2>/dev/null)"

# 9. checks: selected by touched path, rerun once on red, refuse on red twice, get the env, install runs only when one applies
sandbox; branch feat src/b.txt new; G -C "$SB/merge" fetch -q
sm SEAT_MERGE_CHECKS=$'srcs | src/* | echo "$SEAT_MERGE_CHECK:$SEAT_MERGE_TOUCHED:${SEAT_MERGE_MERGED:0:7}" > '"$SB"$'/env.out\ndocsonly | docs/* | touch '"$SB"'/docs-ran' SEAT_MERGE_INSTALL_CMD="touch $SB/installed" -- feat "$BSHA" "m"
eq "T9 exit 0" 0 "$RC"; has "T9 the src check ran with its env" "srcs:src/b.txt:" "$(cat "$SB/env.out")"; eq "T9 the docs check did not (no docs path touched)" no "$([ -e "$SB/docs-ran" ] && echo yes || echo no)"; eq "T9 install ran" yes "$([ -e "$SB/installed" ] && echo yes || echo no)"
sandbox; branch feat src/b.txt new
sm SEAT_MERGE_CHECKS="docsonly | docs/* | touch $SB/docs-ran" SEAT_MERGE_INSTALL_CMD="touch $SB/installed" -- feat "$BSHA" "m"; eq "T9 no check applies: install skipped" no "$([ -e "$SB/installed" ] && echo yes || echo no)"; has "T9 says none apply" "none apply" "$OUT"
sandbox; branch feat src/b.txt new; before=$(omain)
sm SEAT_MERGE_CHECKS="flaky | * | [ -f $SB/n ] || { touch $SB/n; exit 1; }" -- feat "$BSHA" "m"; eq "T9 red once = rerun, then green" 0 "$RC"; has "T9 says it reran" "was red; rerunning once" "$OUT"
sandbox; branch feat src/b.txt new; before=$(omain)
sm SEAT_MERGE_CHECKS="broken | * | echo boom; exit 1" -- feat "$BSHA" "m"; eq "T9 red twice refuses" 1 "$RC"; has "T9 names the check" "the check 'broken' is red on the merged tree (twice)" "$ERR"; eq "T9 main untouched" "$before" "$(omain)"
G -C "$SB/merge" checkout -q --detach origin/main   # the red above left the worktree on its merge
sm SEAT_MERGE_CHECKS="no-pipes-here" -- feat "$BSHA" "m"; eq "T9 a malformed check line refuses" 1 "$RC"; has "T9 malformed text" "malformed" "$ERR"
sandbox; branch feat src/b.txt new; sm -- feat "$BSHA" "m"; has "T9 no checks configured is said, not silent" "no checks configured" "$OUT"

# 10. config from the seat_merge: block in ORCHESTRATION.md; the environment wins
sandbox
mkdir -p "$SB/builder/docs/orchestration"
printf 'team:\n  seat: Orca\n\nseat_merge:\n  format_cmd: touch %s/fmt-ran\n  check: blk | src/* | touch %s/blk-ran\n' "$SB" "$SB" > "$SB/builder/docs/orchestration/ORCHESTRATION.md"
G -C "$SB/builder" add -A; G -C "$SB/builder" commit -qm conf; G -C "$SB/builder" push -q origin main; G -C "$SB/merge" pull -q
branch feat src/b.txt new
sm SEAT_MERGE_FORMAT_CMD= -- feat "$BSHA" "m"
eq "T10 exit 0" 0 "$RC"; eq "T10 format_cmd from the block" yes "$([ -e "$SB/fmt-ran" ] && echo yes || echo no)"; eq "T10 check from the block" yes "$([ -e "$SB/blk-ran" ] && echo yes || echo no)"
rm -f "$SB/fmt-ran" "$SB/blk-ran"; branch feat2 src/c.txt c
sm SEAT_MERGE_FORMAT_CMD="touch $SB/env-fmt" SEAT_MERGE_CHECKS="envchk | * | touch $SB/env-chk" -- feat2 "$BSHA" "m"
eq "T10 env format wins" yes "$([ -e "$SB/env-fmt" ] && echo yes || echo no)"; eq "T10 env format: block's did not run" no "$([ -e "$SB/fmt-ran" ] && echo yes || echo no)"; eq "T10 env checks replace the block's" no "$([ -e "$SB/blk-ran" ] && echo yes || echo no)"

# 11. the shared checkout is refused (a linked worktree is required)
sandbox; branch feat src/b.txt new
sm SEAT_MERGE_ALLOW_SHARED_CHECKOUT= -- feat "$BSHA" "m"; eq "T11 shared checkout refused" 1 "$RC"; has "T11 says why" "is the shared checkout, not a linked worktree" "$ERR"
G -C "$SB/merge" worktree add -q --detach "$SB/lw" origin/main
sm SEAT_MERGE_ALLOW_SHARED_CHECKOUT= SEAT_MERGE_REPO="$SB/lw" -- feat "$BSHA" "m"; eq "T11 a linked worktree is accepted" 0 "$RC"

# 12. one run per worktree: a second run is refused with the holder's pid; a lock left by a dead run does not block
sandbox; branch feat src/b.txt new
( sm SEAT_MERGE_FORMAT_CMD="echo \$\$ > $SB/fmtpid; exec sleep 60" -- feat "$BSHA" "m"; echo "$RC" > "$SB/first.rc" ) &
first=$!
for _ in $(seq 1 100); do [ -s "$SB/fmtpid" ] && break; sleep 0.1; done
holder=$(cat "$SB/rt/seat-merge/"*.lock 2>/dev/null | tr -dc '0-9')
PIDS+=("$(cat "$SB/fmtpid" 2>/dev/null)")
RC=0; env HOME="$SB/home" SEAT_MERGE_REPO="$SB/merge" SEAT_MERGE_RUNTIME_DIR="$SB/rt" SEAT_MERGE_ALLOW_SHARED_CHECKOUT=1 SEAT_MERGE_FORMAT_CMD=true bash "$SM" feat "$BSHA" m >"$SB/out2" 2>"$SB/err2" || RC=$?
eq "T12 second run refused" 1 "$RC"; has "T12 names the holder pid" "another seat-merge is running" "$(cat "$SB/err2")"; has "T12 with its pid" "(pid $holder)" "$(cat "$SB/err2")"
kill "$(cat "$SB/fmtpid")" 2>/dev/null; wait "$first" 2>/dev/null
eq "T12 the first run ended refused (format red), not pushed" 1 "$(cat "$SB/first.rc" 2>/dev/null)"
G -C "$SB/merge" checkout -q --detach origin/main
sm -- feat "$BSHA" "m"; eq "T12 a dead holder's lock file never blocks" 0 "$RC"

# 13. yield to a waiting ticket, bounded
sandbox; branch feat src/b.txt new
mkdir -p "$SB/rt/seat-merge"
bash -c 'exec -a docs-push-fake sleep 120' & pp=$!; PIDS+=("$pp"); sleep 0.2
st=$(sed -n 's/.*) //p' "/proc/$pp/stat" | awk '{print $20}'); echo "$pp $st" > "$SB/rt/seat-merge/docs-push-$pp.waiting"
sm SEAT_MERGE_YIELD_MAX_S=2 SEAT_MERGE_YIELD_POLL_S=1 -- feat "$BSHA" "m"
eq "T13 exit 0 after the bound" 0 "$RC"; has "T13 announces the yield" "yielding to pusher pid $pp" "$OUT"; has "T13 warns at the bound and proceeds" "waited 2s for pusher pid $pp" "$ERR"
# a ticket whose owner is gone (or whose pid is another program) is ignored and removed, with no wait
sandbox; branch feat src/b.txt new; mkdir -p "$SB/rt/seat-merge"; echo "999999 1" > "$SB/rt/seat-merge/docs-push-999999.waiting"
start=$SECONDS; sm SEAT_MERGE_YIELD_MAX_S=30 -- feat "$BSHA" "m"
eq "T13 dead ticket: exit 0" 0 "$RC"; hasnt "T13 dead ticket: no yield" "yielding" "$OUT"; eq "T13 dead ticket removed" no "$([ -e "$SB/rt/seat-merge/docs-push-999999.waiting" ] && echo yes || echo no)"
sandbox; branch feat src/b.txt new; mkdir -p "$SB/rt/seat-merge"
sleep 120 & rp=$!; PIDS+=("$rp"); echo "$rp 1" > "$SB/rt/seat-merge/docs-push-$rp.waiting"
sm SEAT_MERGE_YIELD_MAX_S=30 -- feat "$BSHA" "m"; hasnt "T13 a reused pid (wrong command, wrong start time) is no owner" "yielding" "$OUT"
# bad bounds fall back to the defaults with a warning
sandbox; branch feat src/b.txt new; sm SEAT_MERGE_YIELD_MAX_S=1h SEAT_MERGE_YIELD_POLL_S=0 -- feat "$BSHA" "m"
has "T13 bad max warned" "ignoring yield_max_s='1h'" "$ERR"; has "T13 bad poll warned" "ignoring yield_poll_s='0'" "$ERR"

# 14. a push lost to commits that touch only the allowed paths is redone without re-running the checks; a foreign path refuses
race() {  # <path>: a commit to origin/main from the second clone, run as a check
  printf '#!/usr/bin/env bash\ncd "%s" && git pull -q && mkdir -p "$(dirname "%s")" && echo r >> "%s" && git add -A && git commit -qm race && git push -q origin HEAD:main\n' "$SB/other" "$1" "$1" > "$SB/bin/race.sh"; chmod +x "$SB/bin/race.sh"
}
sandbox; branch feat src/b.txt new; race docs/orchestration/BOARD.md
sm SEAT_MERGE_CHECKS="race | * | bash $SB/bin/race.sh; echo ran >> $SB/checkruns" -- feat "$BSHA" "m"
eq "T14 exit 0" 0 "$RC"; has "T14 says it redid the merge" "merge redone" "$OUT"; has "T14 one retry" "· 1 retry" "$OUT"; eq "T14 the checks ran once (not re-run on the redo)" 1 "$(wc -l < "$SB/checkruns")"
eq "T14 the redone merge keeps the READ sha as 2nd parent" "$BSHA" "$(git -C "$SB/origin.git" rev-parse main^2)"; eq "T14 the racer's board commit is on main" r "$(git -C "$SB/origin.git" show main:docs/orchestration/BOARD.md | tail -1)"
sandbox; branch feat src/b.txt new; race src/foreign.txt; G -C "$SB/merge" fetch -q
sm SEAT_MERGE_CHECKS="race | * | bash $SB/bin/race.sh" -- feat "$BSHA" "m"
eq "T14 foreign path refuses" 1 "$RC"; has "T14 says outside the allowed paths" "outside the allowed paths (src/foreign.txt" "$ERR"; has "T14 nothing forced" "NOT pushed" "$ERR"
eq "T14 main is the racer's, our merge is not on it" "" "$(git -C "$SB/origin.git" log main --format=%H | grep -x "$BSHA" || true)"
sandbox; branch feat src/b.txt new; race src/foreign.txt
sm SEAT_MERGE_ALLOWED_PATHS="src/ docs/orchestration/" SEAT_MERGE_CHECKS="race | * | bash $SB/bin/race.sh" -- feat "$BSHA" "m"; eq "T14 allowed_paths is configurable" 0 "$RC"

# 15. the merged row's builder worktree: removed when provably idle, kept (with the reason) otherwise
sandbox; branch feat src/b.txt new
G -C "$SB/merge" fetch -q; G -C "$SB/merge" worktree add -q "$SB/bw" -b feat origin/feat
sm SEAT_MERGE_IDLE_MINUTES=0 -- feat "$BSHA" "m"; eq "T15 exit 0" 0 "$RC"; has "T15 removed the idle worktree" "removed builder worktree" "$OUT"; eq "T15 it is gone" no "$([ -d "$SB/bw" ] && echo yes || echo no)"
sandbox; branch feat src/b.txt new; G -C "$SB/merge" fetch -q; G -C "$SB/merge" worktree add -q "$SB/bw" -b feat origin/feat; echo wip > "$SB/bw/untracked.txt"
sm SEAT_MERGE_IDLE_MINUTES=0 -- feat "$BSHA" "m"; has "T15 dirty worktree kept with the reason" "kept builder worktree" "$OUT"; has "T15 reason" "uncommitted or untracked" "$OUT"; eq "T15 still there" yes "$([ -d "$SB/bw" ] && echo yes || echo no)"
sandbox; branch feat src/b.txt new; G -C "$SB/merge" fetch -q; G -C "$SB/merge" worktree add -q "$SB/bw" -b feat origin/feat
sm -- feat "$BSHA" "m"; has "T15 a file changed in the last 30 min keeps it" "a file changed in the last 30 min" "$OUT"

# 16. the CHECKED merge sha is what is pushed, never HEAD: a commit made in the worktree after the merge must not ride along
sandbox; branch feat src/b.txt new
sm SEAT_MERGE_CHECKS="sneaky | * | git commit --allow-empty -qm sneaky" -- feat "$BSHA" "m"
eq "T16 exit 0" 0 "$RC"; eq "T16 the sneaky commit is not on main" "" "$(git -C "$SB/origin.git" log main --format=%s | grep -x sneaky || true)"; eq "T16 main's tip is the checked merge" "m" "$(git -C "$SB/origin.git" log -1 --format=%s main)"

# 17. a rejected push with NO race (origin/main did not move) is a plain refusal, not a retry loop (READ LOW-1: mutant S14,
#     deleting that guard, used to survive because only the race paths were tested).
sandbox; branch feat src/b.txt new
printf '#!/bin/sh\nexit 1\n' > "$SB/origin.git/hooks/pre-receive"; chmod +x "$SB/origin.git/hooks/pre-receive"
sm SEAT_MERGE_CHECKS="count | * | echo ran >> $SB/checkruns" -- feat "$BSHA" "m"
eq "T17 exit 1" 1 "$RC"; has "T17 says the push failed" "push failed" "$ERR"; has "T17 says origin/main did not move" "did not move" "$ERR"
hasnt "T17 no retry" "retry" "$OUT"; eq "T17 the checks ran once" 1 "$(wc -l < "$SB/checkruns")"
has "T17 nothing forced, the reset hint is the last line" "git checkout --detach origin/main" "$(tail -n1 "$SB/err")"

# 18. the runtime dir follows KIT_RUNTIME_DIR like gate-throttle.sh and quiet-mode.sh (READ LOW-3); SEAT_MERGE_RUNTIME_DIR wins
sandbox; branch feat src/b.txt new
sm SEAT_MERGE_RUNTIME_DIR= KIT_RUNTIME_DIR="$SB/kitrt" -- feat "$BSHA" "m"
eq "T18 exit 0" 0 "$RC"; eq "T18 the lock lives under KIT_RUNTIME_DIR" 1 "$(ls "$SB/kitrt/seat-merge"/*.lock 2>/dev/null | wc -l | tr -d ' ')"
eq "T18 and not under HOME" no "$([ -d "$SB/home/.orchestration-kit" ] && echo yes || echo no)"
sandbox; branch feat src/b.txt new
sm KIT_RUNTIME_DIR="$SB/kitrt" -- feat "$BSHA" "m"
eq "T18 SEAT_MERGE_RUNTIME_DIR beats KIT_RUNTIME_DIR" 0 "$(ls "$SB/kitrt/seat-merge" 2>/dev/null | wc -l | tr -d ' ')"

# 19. config is read from THIS worktree's checkout BEFORE the merge (READ LOW-2): a branch that adds a red check does not
#     gate its own merge; the next run, from the merged tree, does. The header says so.
sandbox
extra_seed() { :; }
branch feat docs/orchestration/ORCHESTRATION.md "$(printf 'seat_merge:\n  check: boom | * | false')"
sm SEAT_MERGE_CHECKS= -- feat "$BSHA" "m"
eq "T19 the branch's own new check does not gate its merge" 0 "$RC"
branch feat2 src/c.txt new; G -C "$SB/merge" checkout -q --detach origin/main
sm SEAT_MERGE_CHECKS= -- feat2 "$BSHA" "m2"
eq "T19 from the merged tree the new check applies and is red" 1 "$RC"; has "T19 names the check" "boom" "$ERR"
has "T19 the header says the config is read before the merge" "read BEFORE the merge" "$(sed -n 1,60p "$SM")"

# 20. templates/ORCHESTRATION.md documents the seat_merge: block: every hook, a recommended `*` check, and the block parses
T="$ROOT/templates/ORCHESTRATION.md"
tb="$(awk '/^seat_merge:[[:space:]]*$/{on=1;print;next} on&&/^[[:space:]]+[a-z_]+:/{print;next} on{exit}' "$T")"
for k in format_cmd install_cmd check allowed_paths yield_max_s yield_poll_s idle_minutes marker_exempt; do
  has "T20 template seat_merge: block carries $k" "  $k:" "$tb"
done
has "T20 the recommended check runs on every merge (globs *)" "| * |" "$tb"
for k in format_cmd install_cmd allowed_paths yield_max_s yield_poll_s idle_minutes marker_exempt SEAT_MERGE_LOG_DIR SEAT_MERGE_RUNTIME_DIR; do
  has "T20 the template prose explains $k" "$k" "$(cat "$T")"
done
sandbox; branch feat src/b.txt new
mkdir -p "$SB/merge/docs/orchestration"
sed -E 's/<[^>]*>/true/g' "$T" > "$SB/merge/docs/orchestration/ORCHESTRATION.md"
sm SEAT_MERGE_FORMAT_CMD= SEAT_MERGE_CHECKS= SEAT_MERGE_ALLOWED_PATHS= -- feat "$BSHA" "m"
eq "T20 the template's block runs as written (placeholders filled)" 0 "$RC"; has "T20 its * check ran" "check '" "$OUT"


# ---- ported fixes (kit 0.16.1) ----
reset_wt() { G -C "$SB/merge" checkout -q --detach origin/main; }
lockfile_of() { printf '%s/rt/seat-merge/%s.lock' "$SB" "$(printf %s "$(cd "$SB/merge" && git rev-parse --show-toplevel)" | sha256sum | cut -c1-16)"; }
M7='<<<<<<<'; M8='======='; M9='>>>>>>>'

# 21. committed conflict markers in the merged tree are listed and refused BEFORE the format check; nothing is pushed
sandbox; branch feat src/b.txt "$(printf 'x\n%s HEAD\nmine\n%s\ntheirs\n%s other\n' "$M7" "$M8" "$M9")"; before=$(omain)
sm SEAT_MERGE_FORMAT_CMD="touch $SB/fmt-ran" -- feat "$BSHA" "m"
eq "T21 exit 1" 1 "$RC"; has "T21 says markers" "committed conflict markers" "$ERR"; has "T21 lists file and line" "src/b.txt:2: $M7 HEAD" "$ERR"
eq "T21 refused before the format check" no "$([ -e "$SB/fmt-ran" ] && echo yes || echo no)"; eq "T21 main untouched" "$before" "$(omain)"; has "T21 reset hint" "git checkout --detach origin/main" "$ERR"
# a lone ======= (a setext underline) is not a conflict
sandbox; branch feat src/b.txt "$(printf 'Title\n%s\nbody\n' "$M8")"; sm -- feat "$BSHA" "m"; eq "T21 a lone rule line merges" 0 "$RC"
# markdown is scanned; an exempt prefix (config line or env) is skipped
sandbox; branch feat docs/n.md "$(printf '%s a\nb\n%s\nc\n%s z\n' "$M7" "$M8" "$M9")"; sm -- feat "$BSHA" "m"; eq "T21 markdown is scanned" 1 "$RC"; reset_wt
sm SEAT_MERGE_MARKER_EXEMPT=$'# quoted on purpose\ndocs/n.md' -- feat "$BSHA" "m"; eq "T21 an exempt prefix is skipped" 0 "$RC"
# the exempt list comes from the tree BEFORE the merge: a branch that adds its own exemption does not get it
sandbox; mkdir -p "$SB/builder/docs/orchestration"; printf 'seat_merge:\n  check: ok | docs/none/* | true\n' > "$SB/builder/docs/orchestration/ORCHESTRATION.md"
G -C "$SB/builder" add -A; G -C "$SB/builder" commit -qm conf; G -C "$SB/builder" push -q origin main; G -C "$SB/merge" pull -q
G -C "$SB/builder" fetch -q origin; G -C "$SB/builder" checkout -q -B feat origin/main
printf 'seat_merge:\n  marker_exempt: src/\n  check: ok | docs/none/* | true\n' > "$SB/builder/docs/orchestration/ORCHESTRATION.md"; mkdir -p "$SB/builder/src"; printf '%s a\nb\n%s\nc\n%s z\n' "$M7" "$M8" "$M9" > "$SB/builder/src/q.txt"
G -C "$SB/builder" add -A; G -C "$SB/builder" commit -qm "feat: self-exempt"; G -C "$SB/builder" push -q -f origin feat; BSHA=$(git -C "$SB/builder" rev-parse HEAD)
sm -- feat "$BSHA" "m"; eq "T21 a branch cannot exempt its own markers" 1 "$RC"; has "T21 names the file" "src/q.txt" "$ERR"

# 22. TERM, INT and HUP end the run at once as 128+n, end the running check, and keep the check log
for sg in TERM:143 INT:130 HUP:129; do
  name=${sg%%:*}; want=${sg##*:}
  sandbox; branch feat src/b.txt new; before=$(omain)
  ( env HOME="$SB/home" PATH="$SB/bin:$PATH" SEAT_MERGE_REPO="$SB/merge" SEAT_MERGE_RUNTIME_DIR="$SB/rt" SEAT_MERGE_ALLOW_SHARED_CHECKOUT=1 SEAT_MERGE_FORMAT_CMD=true \
      SEAT_MERGE_CHECKS="slow | * | echo 'FAIL-line from the check'; echo \$\$ > $SB/chk.pid; sleep 60" \
      python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("bash", ["bash"] + sys.argv[1:])' "$SM" feat "$BSHA" "m" >"$SB/out" 2>"$SB/err" </dev/null; echo $? > "$SB/rc" ) & smpid=$!; PIDS+=("$smpid")
  # (a background job of a non-interactive shell starts with SIGINT ignored, and an ignored signal cannot be trapped: the launcher above restores it)
  for _ in $(seq 1 50); do [ -s "$SB/chk.pid" ] && break; sleep 0.1; done
  chkpid=$(cat "$SB/chk.pid" 2>/dev/null)
  # the subshell's child is the script: signal the script itself, not the subshell
  scr=$(pgrep -P "$smpid" -f seat-merge.sh | head -n1); [ -n "$scr" ] || scr=$smpid
  kill -s "$name" "$scr"; t0=$SECONDS; wait "$smpid" 2>/dev/null
  eq "T22 $name exits $want" "$want" "$(cat "$SB/rc")"; [ $((SECONDS - t0)) -le 5 ] && ok || bad "T22 $name took over 5 s to end the run"
  sleep 0.3; eq "T22 $name: the check is gone" no "$(kill -0 "$chkpid" 2>/dev/null && echo yes || echo no)"
  has "T22 $name: the log is kept" "check log kept:" "$(cat "$SB/err")"; has "T22 $name: its failure line is shown" "FAIL-line from the check" "$(cat "$SB/err")"
  eq "T22 $name: main untouched" "$before" "$(omain)"
done

# 23. every origin fetch and push retries a TRANSIENT denial, never a rejection by the remote
sandbox; branch feat src/b.txt new; real_git=$(command -v git)
cat > "$SB/bin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in fetch|push) n=\$(cat "$SB/n.\$1" 2>/dev/null || echo 0); echo \$((n+1)) > "$SB/n.\$1"
  lim=0; [ "\$1" = fetch ] && lim=\${FAIL_fetch:-0}; [ "\$1" = push ] && lim=\${FAIL_push:-0}
  if [ "\$n" -lt "\$lim" ]; then echo "git@host: Permission denied (publickey)." >&2; echo "fatal: Could not read from remote repository." >&2; exit 128; fi ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$SB/bin/git"
sm GIT_NET_BACKOFF_S=0 FAIL_fetch=2 FAIL_push=1 -- feat "$BSHA" "m"
eq "T23 exit 0 after transient denials" 0 "$RC"; has "T23 says it retried the fetch" "transient git failure, retry 1/7" "$ERR"; eq "T23 the push ran twice (one denial)" 2 "$(cat "$SB/n.push")"
# all denied: gives up, the caller's refusal runs, nothing pushed
sandbox; branch feat src/b.txt new; cp "$SB/../$(basename "$SB")/bin/git" "$SB/bin/git" 2>/dev/null
cat > "$SB/bin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in fetch) echo "ssh: connect to host h port 22: Connection timed out" >&2; exit 128 ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$SB/bin/git"; before=$(omain)
sm GIT_NET_BACKOFF_S=0 GIT_NET_TRIES=3 -- feat "$BSHA" "m"; eq "T23 gives up: exit 1" 1 "$RC"; has "T23 says gave up" "gave up after 3 tries" "$ERR"; has "T23 the refusal runs" "fetch failed" "$ERR"; eq "T23 main untouched" "$before" "$(omain)"
# a rejection by the remote is never retried (one push call, then the plain refusal)
sandbox; branch feat src/b.txt new
cat > "$SB/bin/git" <<EOF
#!/usr/bin/env bash
[ "\$1" = push ] && echo x >> "$SB/pushes"
exec "$real_git" "\$@"
EOF
chmod +x "$SB/bin/git"; printf '#!/bin/sh\necho "remote: denied by hook" >&2\nexit 1\n' > "$SB/origin.git/hooks/pre-receive"; chmod +x "$SB/origin.git/hooks/pre-receive"
sm GIT_NET_BACKOFF_S=0 -- feat "$BSHA" "m"; eq "T23 rejected push: exit 1" 1 "$RC"; eq "T23 rejected push ran once" 1 "$(wc -l < "$SB/pushes")"; hasnt "T23 no retry line" "transient" "$ERR"

# 24. HEAD must be on origin/main at the start: a re-run after a red needs the printed reset first
sandbox; branch feat src/b.txt new; before=$(omain)
sm SEAT_MERGE_CHECKS="red | * | exit 1" -- feat "$BSHA" "m"; eq "T24 the first run is red" 1 "$RC"
sm -- feat "$BSHA" "m"; eq "T24 a re-run without the reset is refused" 1 "$RC"; has "T24 says HEAD is not on origin/main" "is not on origin/main" "$ERR"; has "T24 prints the reset" "git checkout --detach origin/main" "$ERR"; eq "T24 main untouched" "$before" "$(omain)"
reset_wt; sm -- feat "$BSHA" "m"; eq "T24 after the reset it merges" 0 "$RC"
# a local commit on the merge worktree is refused too, and nothing is touched
sandbox; branch feat src/b.txt new; echo local > "$SB/merge/src/loc.txt"; G -C "$SB/merge" add src/loc.txt; G -C "$SB/merge" commit -qm "local commit"; h0=$(git -C "$SB/merge" rev-parse HEAD)
sm -- feat "$BSHA" "m"; eq "T24 local commit: refused" 1 "$RC"; eq "T24 HEAD untouched" "$h0" "$(git -C "$SB/merge" rev-parse HEAD)"

# 25. stage time comes from the monotonic clock ($MONO_CLOCK_FILE is the seam), never $SECONDS
sandbox; branch feat src/b.txt new; echo "100.00 5.00" > "$SB/mono"
sm MONO_CLOCK_FILE="$SB/mono" SEAT_MERGE_CHECKS="clk | * | echo 107.60 1.0 > $SB/mono" -- feat "$BSHA" "m"
eq "T25 exit 0" 0 "$RC"; has "T25 the check time is the clock's span" "checks took 7s" "$OUT"
sandbox; branch feat src/b.txt new; echo "100.00 5.00" > "$SB/mono"
sm MONO_CLOCK_FILE="$SB/mono" SEAT_MERGE_CHECKS="clk | * | echo 90.00 1.0 > $SB/mono" -- feat "$BSHA" "m"; has "T25 a clock that went back prints 0, not a negative" "checks took 0s" "$OUT"

# 26. an orphan holding the lock is named with the command that clears it; a live seat-merge is still "another seat-merge"
sandbox; branch feat src/b.txt new; mkdir -p "$SB/rt/seat-merge"; lk=$(lockfile_of)
bash -c 'exec 8<>"$0"; flock -n 8 || exit 9; exec sleep 120' "$lk" & orph=$!; PIDS+=("$orph"); sleep 0.3
sm -- feat "$BSHA" "m"; eq "T26 orphan: exit 1" 1 "$RC"; has "T26 names the orphan pid" "held only by orphan pid $orph" "$ERR"; has "T26 gives the clearing command" "kill $orph" "$ERR"
kill "$orph" 2>/dev/null; wait "$orph" 2>/dev/null
bash -c 'exec 8<>"$0"; flock -n 8 || exit 9; exec -a seat-merge.sh sleep 120' "$lk" & live=$!; PIDS+=("$live"); sleep 0.3
sm -- feat "$BSHA" "m"; eq "T26 live holder: exit 1" 1 "$RC"; has "T26 live holder: another seat-merge" "another seat-merge is running" "$ERR"; hasnt "T26 not called an orphan" "orphan" "$ERR"

# 27. after a pushed merge the main checkout is moved on (sync-main-checkout.sh runs; it never fails the merge)
sandbox; branch feat src/b.txt new; sm -- feat "$BSHA" "m"
eq "T27 exit 0" 0 "$RC"; has "T27 the sync line is printed" "main-checkout:" "$OUT"


# 28. the builder-worktree removal check: an untracked node_modules SYMLINK is rebuildable (and unlinked, never its target),
#     python bytecode is rebuildable output, and a cone sparse tree's hidden files outside its set do not keep it forever
. "$ROOT/scripts/lib-builder-worktree.sh"
bw_new() {  # <name>: a clean builder worktree on its own branch at origin/main; sets W
  sandbox; G -C "$SB/merge" fetch -q; W="$SB/$1"; G -C "$SB/merge" worktree add -q "$W" -b "br-$1" origin/main
}
blocker() { ( cd "$SB/merge" && SEAT_MERGE_IDLE_MINUTES=0 worktree_removal_blocker "$W" "br-$1" "" ); }
bw_new a; mkdir "$SB/realnm"; echo keep > "$SB/realnm/x"; ln -s "$SB/realnm" "$W/node_modules"
eq "T28 an untracked node_modules symlink is not work" "" "$(blocker a)"
( cd "$SB/merge" && worktree_remove_clean "$W" ) >/dev/null 2>&1; eq "T28 remove_clean removes the tree" no "$([ -d "$W" ] && echo yes || echo no)"; eq "T28 the link's target is untouched" keep "$(cat "$SB/realnm/x")"
bw_new b; mkdir "$W/node_modules"; echo mine > "$W/node_modules/x"
has "T28 a real untracked node_modules directory is work" "uncommitted or untracked" "$(blocker b)"
bw_new c; ln -s "$SB/rl" "$W/node_modules"; echo wip > "$W/notes.txt"
( cd "$SB/merge" && worktree_remove_clean "$W" ) >"$SB/o" 2>&1; rc=$?; eq "T28 remove_clean refuses another untracked file" 1 "$rc"; has "T28 says which" "notes.txt" "$(cat "$SB/o")"; eq "T28 and unlinks nothing" yes "$([ -L "$W/node_modules" ] && echo yes || echo no)"
bw_new d; printf '__pycache__/\nsecret.env\n' >> "$SB/merge/.git/info/exclude"; mkdir -p "$W/src/__pycache__"; : > "$W/src/__pycache__/m.pyc"
eq "T28 ignored python bytecode is rebuildable output" "" "$(blocker d)"
: > "$W/secret.env"; has "T28 another ignored file keeps the tree" "ignored file that is not rebuildable output (secret.env)" "$(blocker d)"
bw_new e; G -C "$W" sparse-checkout init --cone; G -C "$W" sparse-checkout set src
eq "T28 a cone tree: hidden files outside its set do not keep it" "" "$(blocker e)"
G -C "$W" update-index --assume-unchanged src/a.txt; has "T28 a lowercase assume-unchanged tag keeps it, sparse or not" "skip-worktree or assume-unchanged file (h src/a.txt)" "$(blocker e)"
G -C "$W" update-index --no-assume-unchanged src/a.txt
# with sparse.expectFilesOutsideOfPatterns a PRESENT file outside the set keeps its S bit and status hides it: that may be work
G -C "$W" config sparse.expectFilesOutsideOfPatterns true; mkdir -p "$W/docs/orchestration"; echo work > "$W/docs/orchestration/BOARD.md"
has "T28 a present file outside the set is kept" "skip-worktree or assume-unchanged file (S docs/orchestration/BOARD.md)" "$(blocker e)"
bw_new f; G -C "$W" update-index --skip-worktree src/a.txt; has "T28 a non-sparse tree keeps a skip-worktree file" "skip-worktree or assume-unchanged file" "$(blocker f)"

# 29. the merged row's builder worktree with only a node_modules symlink extra is removed by seat-merge itself
sandbox; branch feat src/b.txt new; G -C "$SB/merge" fetch -q; G -C "$SB/merge" worktree add -q "$SB/bw" -b feat origin/feat; mkdir "$SB/shared-nm"; ln -s "$SB/shared-nm" "$SB/bw/node_modules"
sm SEAT_MERGE_IDLE_MINUTES=0 -- feat "$BSHA" "m"; has "T29 removed the worktree that held a node_modules link" "removed builder worktree" "$OUT"; eq "T29 it is gone" no "$([ -d "$SB/bw" ] && echo yes || echo no)"; eq "T29 the install behind the link stays" yes "$([ -d "$SB/shared-nm" ] && echo yes || echo no)"

echo "seat-merge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
