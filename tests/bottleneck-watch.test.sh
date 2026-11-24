#!/usr/bin/env bash
# Tests for scripts/bottleneck-watch.sh: the seat's outlier poll. The process list is a FAKE (BOTTLENECK_PS_FILE) whose pids are
# real idle `sleep` processes started inside the sandbox worktrees, so the script's cwd checks see the right trees. The repo is a
# throwaway (bare origin + clone + worktrees). tmux is a fake script (BOTTLENECK_TMUX). Nothing real is signaled.
# Run: bash tests/bottleneck-watch.test.sh
set -u
unset TMUX TMUX_PANE RECYCLE_TMUX_SESSION   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BW="$ROOT/scripts/bottleneck-watch.sh"
TMP="$(mktemp -d)"
# alive() runs in a command substitution, so the pids are recorded in a file, not an array
cleanup() { for p in $(cat "$TMP/pids" 2>/dev/null); do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
G() { git -c user.email=t@example.com -c user.name=T -c core.hooksPath=/dev/null "$@"; }

# repo: origin.git, MAIN (the clone, on main), a recent merge commit on main, worktree W1 on branch b1 (cut at main's tip)
O="$TMP/origin.git"; M="$TMP/main"
G init -q --bare -b main "$O"; G clone -q "$O" "$M" 2>/dev/null; G -C "$M" checkout -q -b main 2>/dev/null
echo a > "$M/a.txt"; G -C "$M" add a.txt; G -C "$M" commit -q -m seed
G -C "$M" checkout -q -b feat; echo f > "$M/f.txt"; G -C "$M" add f.txt; G -C "$M" commit -q -m feat
G -C "$M" checkout -q main; G -C "$M" merge -q --no-ff feat -m "merge feat"; G -C "$M" push -q origin main
G -C "$M" worktree add -q -b b1 "$TMP/w1" main
alive() {  # <dir>: a real idle process whose cwd is <dir>; prints its pid
  ( cd "$1" && exec sleep 600 ) </dev/null >/dev/null 2>&1 & local p=$!; echo "$p" >> "$TMP/pids"; echo "$p"
}
P_W1="$(alive "$TMP/w1")"; P_OUT="$(alive "$TMP")"
run() {  # <ps lines...> then env in $ENVV: runs the script against the fake list
  printf '%s\n' "$@" > "$TMP/ps.txt"
  (cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE="$TMP/ps.txt" BOTTLENECK_NO_FETCH=1 BOTTLENECK_FREE_GB=500 BOTTLENECK_TMUX=/nonexistent $ENVV bash "$BW" 2>&1; echo "rc=$?")
}
ENVV="BUDGET_NO_MERGE=100000"
min() { echo $(( $1 * 60 )); }   # minutes → etimes seconds

out="$(run)"; has "an empty list is clean" "bottleneck-watch: 0 outlier(s)" "$out"; has "exit 0" "rc=0" "$out"
has "tmux missing is one warning, not an outlier" "WARNING: tmux not found" "$out"

# ---- seat-merge ----
out="$(run "$P_W1 1 S+ $(min 56) bash scripts/seat-merge.sh b1 $(G -C "$M" rev-parse main)")"
has "a seat-merge past its budget is flagged" "OUTLIER: seat-merge pid $P_W1 (b1) at 56 min, budget 55." "$out"; has "exit 3" "rc=3" "$out"
out="$(run "$P_W1 1 S+ $(min 54) bash scripts/seat-merge.sh b1 $(G -C "$M" rev-parse main)")"; has "inside its budget is quiet" "0 outlier(s)" "$out"
out="$(run "$P_W1 1 S+ $(min 54) /usr/bin/bash /home/u/x/scripts/seat-merge.sh b1 $(G -C "$M" rev-parse main)")"; has "an absolute-path start is read the same" "0 outlier(s)" "$out"
out="$(run "$P_OUT 1 S+ $(min 99) bash scripts/seat-merge.sh b1 $(G -C "$M" rev-parse main)")"; has "a process outside this repo's worktrees is ignored" "0 outlier(s)" "$out"
out="$(run "$P_W1 1 S+ $(min 99) bash scripts/seat-merge.sh trial-x $(G -C "$M" rev-parse main)")"; has "a trial-* replay is not a queue row" "0 outlier(s)" "$out"
out="$(run "$P_W1 1 S+ $(min 99) bash scripts/seat-merge.sh b1 $(G -C "$M" rev-parse main)" "$((P_W1+1)) $P_W1 S $(min 99) bash scripts/seat-merge.sh b1 x")"; has "the child of a merge wrapper is judged once" "bottleneck-watch: 1 outlier(s)" "$out"
# a branch that conflicts with main
G -C "$M" checkout -q -b c1 main~1 2>/dev/null; echo X > "$M/f.txt"; G -C "$M" add f.txt; G -C "$M" commit -q -m clash; CS="$(G -C "$M" rev-parse HEAD)"; G -C "$M" checkout -q main
out="$(run "$P_W1 1 S+ $(min 3) bash scripts/seat-merge.sh c1 $CS")"; has "a merge that conflicts with main is flagged at once" "conflicts with main on f.txt" "$out"
out="$(run "$P_W1 1 S+ $(min 3) bash scripts/seat-merge.sh c1 0000000000000000000000000000000000000000")"; has "an unknown sha is a warning, not a verdict" "WARNING: git merge-tree could not judge" "$out"

# ---- gate-throttle: running, queued, stale ----
out="$(run "$P_W1 1 S+ $(min 71) bash scripts/gate-throttle.sh pnpm gate" "$((P_W1+1)) $P_W1 S $(min 71) bash -c gate")"
has "a running gate past its budget is flagged" "OUTLIER: gate pid $P_W1 at 71 min, budget 70" "$out"
out="$(run "$P_W1 1 S+ $(min 5) bash scripts/gate-throttle.sh pnpm gate" "$((P_W1+1)) $P_W1 S $(min 5) bash -c gate")"; has "a young running gate is quiet" "0 outlier(s)" "$out"
out="$(run "$P_W1 1 S+ $(min 71) bash scripts/gate-throttle.sh pnpm gate" "$((P_W1+1)) $P_W1 S $(min 71) sleep 1")"
has "a throttle whose child only sleeps is QUEUED, and an old one is flagged" "1 gate(s) queued in the throttle; the oldest (pid $P_W1) has waited 71 min" "$out"
out="$(run "$P_W1 1 S+ $(min 5) bash scripts/gate-throttle.sh pnpm gate" "$((P_W1+1)) $P_W1 S $(min 5) sleep 1")"; has "a young queued gate is an info line" "1 gate(s) queued in the throttle; oldest 5 min." "$out"; has "and not an outlier" "0 outlier(s)" "$out"
# stale: a branch whose tip is on main (merged) but not on the first-parent line, in a tree
G -C "$M" worktree add -q -b done1 "$TMP/w2" feat 2>/dev/null; P_W2="$(alive "$TMP/w2")"
out="$(run "$P_W2 1 S+ $(min 5) bash scripts/gate-throttle.sh pnpm gate" "$((P_W2+1)) $P_W2 S $(min 5) bash -c gate")"
has "a gate on a branch already merged into main looks stale" "looks stale: done1 is already on main" "$out"
out="$(run "$P_W1 1 S+ $(min 5) bash scripts/gate-throttle.sh pnpm gate" "$((P_W1+1)) $P_W1 S $(min 5) bash -c gate")"; hasnt "a branch cut at main's tip is not stale" "stale" "$out"
# origin/<branch> moved past the tree's head
G -C "$M" checkout -q -b mv1 main 2>/dev/null; G -C "$M" worktree add -q "$TMP/w3" -b mv2 main 2>/dev/null; echo m > "$TMP/w3/m.txt"; G -C "$TMP/w3" add m.txt; G -C "$TMP/w3" commit -q -m m1
H3="$(G -C "$TMP/w3" rev-parse HEAD)"; echo n > "$TMP/w3/n.txt"; G -C "$TMP/w3" add n.txt; G -C "$TMP/w3" commit -q -m m2; G -C "$TMP/w3" push -q origin mv2; G -C "$TMP/w3" reset -q --hard "$H3"; G -C "$M" checkout -q main
G -C "$M" fetch -q origin; P_W3="$(alive "$TMP/w3")"
out="$(run "$P_W3 1 S+ $(min 5) bash scripts/gate-throttle.sh pnpm gate" "$((P_W3+1)) $P_W3 S $(min 5) bash -c gate")"; has "origin/<branch> past the tree's head looks stale" "looks stale: origin/mv2 moved past it" "$out"

# ---- zombies ----
out="$(run "50 1 T $(min 10) bash scripts/chain1.sh" "51 50 Z 5 [sleep] <defunct>" "52 50 Z 9 [python3] <defunct>")"
has "a poll-sleep zombie is only counted" "1 poll-sleep zombie(s)" "$out"; has "another zombie under a stopped parent is an outlier" "OUTLIER: zombie pid 52" "$out"

# ---- no merge on main ----
out="$(cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE=/dev/null BOTTLENECK_NO_FETCH=1 BOTTLENECK_FREE_GB=500 BOTTLENECK_TMUX=/nonexistent BUDGET_NO_MERGE=0 bash "$BW" 2>&1; echo "rc=$?")"
sleep 1; out="$(cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE=/dev/null BOTTLENECK_NO_FETCH=1 BOTTLENECK_FREE_GB=500 BOTTLENECK_TMUX=/nonexistent BUDGET_NO_MERGE=-1 bash "$BW" 2>&1; echo "rc=$?")"
has "no recent merge on main is flagged" "OUTLIER: no merge on main for" "$out"

# ---- permission prompts (fake tmux) ----
FT="$TMP/faketmux"; cat > "$FT" <<'F'
#!/usr/bin/env bash
case "$1" in
  has-session) [ "${FAKE_SESSION:-yes}" = yes ] ;;
  list-panes) printf '%%1\t@1\tSib9\n%%2\t@2\tSib8\n' ;;
  capture-pane) case "$4" in %1) cat "$FAKE_SCREEN1" ;; *) echo "just working" ;; esac ;;
  display-message) echo kit ;;
esac
F
chmod +x "$FT"
printf 'Bash command\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' > "$TMP/screen1"
runt() { (cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE=/dev/null BOTTLENECK_NO_FETCH=1 BOTTLENECK_FREE_GB=500 BUDGET_NO_MERGE=100000 BOTTLENECK_TMUX="$FT" RECYCLE_TMUX_SESSION=kit FAKE_SCREEN1="$TMP/screen1" "$@" bash "$BW" 2>&1; echo "rc=$?"); }
out="$(runt)"; has "a pane showing a permission dialog is flagged" "OUTLIER: window 'Sib9' (@1, pane %1) shows a permission prompt" "$out"; hasnt "a quiet pane is not" "Sib8" "$out"; has "it says nothing was sent" "Nothing was sent." "$out"
printf 'the report quotes "Do you want to proceed" in prose only\n' > "$TMP/screen1"
out="$(runt)"; has "prose that quotes the phrase is not a dialog" "0 outlier(s)" "$out"
out="$(runt FAKE_SESSION=no)"; has "no such session: a warning" "WARNING: no tmux session 'kit'" "$out"; has "and no outlier" "0 outlier(s)" "$out"

# ---- disk, fetch, unreadable list ----
out="$(ENVV="BUDGET_NO_MERGE=100000 BOTTLENECK_FREE_GB=3" run | head -3)"; out="$(cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE=/dev/null BOTTLENECK_NO_FETCH=1 BOTTLENECK_FREE_GB=3 BOTTLENECK_TMUX=/nonexistent BUDGET_NO_MERGE=100000 bash "$BW" 2>&1; echo "rc=$?")"
has "low free space is flagged" "OUTLIER: free space is 3 GB (limit 20 GB)" "$out"
out="$(cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE=/dev/null BOTTLENECK_NO_FETCH=1 BOTTLENECK_FREE_GB=lots BOTTLENECK_TMUX=/nonexistent BUDGET_NO_MERGE=100000 bash "$BW" 2>&1; echo "rc=$?")"; has "an unreadable free-space value is a warning" "WARNING: free space could not be read" "$out"
out="$(cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE="$TMP/does-not-exist" BOTTLENECK_NO_FETCH=1 BOTTLENECK_TMUX=/nonexistent bash "$BW" 2>&1; echo "rc=$?")"; has "an unreadable process list exits 1" "rc=1" "$out"
out="$(cd "$M" && env BOTTLENECK_REPO="$M" BOTTLENECK_PS_FILE=/dev/null BOTTLENECK_FREE_GB=500 BOTTLENECK_TMUX=/nonexistent BUDGET_NO_MERGE=100000 bash -c 'cd "$1" && git remote set-url origin /nonexistent/x && bash "$2"' _ "$M" "$BW" 2>&1; echo "rc=$?")"
has "a failed fetch is a warning, not a silent judgment" "WARNING: git fetch origin failed" "$out"

echo "bottleneck-watch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
