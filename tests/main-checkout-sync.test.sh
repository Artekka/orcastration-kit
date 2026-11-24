#!/usr/bin/env bash
# Tests for scripts/main-checkout-sync.sh and scripts/sync-main-checkout.sh: the shared checkout fast-forwards to origin/main
# and does NOTHING else. Every case builds a throwaway bare "origin" plus two clones (the shared checkout under test, and a
# pusher that advances origin) under a temp dir; the real checkout is never touched. Run: bash tests/main-checkout-sync.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/main-checkout-sync.sh"; WRAP="$ROOT/scripts/sync-main-checkout.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1: want '$2' got '$3'"; }
G() { git -c user.email=t@example.com -c user.name=T -c core.hooksPath=/dev/null "$@"; }

fresh() {  # new origin, shared clone, pusher clone; one seed commit on main
  rm -rf "$TMP/o" "$TMP/s" "$TMP/p"; mkdir -p "$TMP/o"
  G init -q --bare -b main "$TMP/o/origin.git"
  G clone -q "$TMP/o/origin.git" "$TMP/p" 2>/dev/null; G -C "$TMP/p" checkout -q -b main
  echo seed > "$TMP/p/a.txt"; G -C "$TMP/p" add a.txt; G -C "$TMP/p" commit -q -m seed; G -C "$TMP/p" push -q origin main
  G clone -q "$TMP/o/origin.git" "$TMP/s" 2>/dev/null
  printf '.local\n' >> "$TMP/s/.git/info/exclude"
}
upstream() {  # <file> <body>: a new commit on origin/main (via the pusher)
  echo "$2" > "$TMP/p/$1"; G -C "$TMP/p" add "$1"; G -C "$TMP/p" commit -q -m "up $1"; G -C "$TMP/p" push -q origin main
}
run() { (cd "$TMP/s" && env MAIN_SYNC_REPO="$TMP/s" "$@" bash "$SCRIPT" 2>&1; echo "rc=$?"); }

fresh
out="$(run)"; has "already current" "main-checkout: current" "$out"; has "exit 0" "rc=0" "$out"
upstream b.txt one; upstream c.txt two
out="$(run)"; has "behind: fast-forwards" "main-checkout:" "$out"; has "says the commit count" "(2 commits)" "$out"; has "exit 0" "rc=0" "$out"
eq "the checkout moved to origin/main" "$(G -C "$TMP/s" rev-parse origin/main)" "$(G -C "$TMP/s" rev-parse HEAD)"
[ -f "$TMP/s/c.txt" ] && ok || bad "the new file did not arrive"

fresh; upstream b.txt one; G -C "$TMP/s" checkout -q -b side
out="$(run)"; has "off main: skip" "skip (not on main: on branch side)" "$out"; has "exit 0" "rc=0" "$out"
eq "an off-main checkout is not moved" "$(G -C "$TMP/s" rev-parse HEAD)" "$(G -C "$TMP/s" rev-parse side)"; [ ! -f "$TMP/s/b.txt" ] && ok || bad "a skip changed files"

fresh; upstream b.txt one; G -C "$TMP/s" checkout -q --detach
out="$(run)"; has "detached: skip" "skip (detached HEAD)" "$out"

fresh; upstream b.txt one; : > "$TMP/s/.git/MERGE_HEAD"
out="$(run)"; has "mid merge: skip" "skip (MERGE_HEAD in progress)" "$out"; rm -f "$TMP/s/.git/MERGE_HEAD"

fresh; upstream b.txt upstream-body; echo mine > "$TMP/s/b.txt"
out="$(run)"; has "a dirty untracked path that would be overwritten: skip" "skip (" "$out"; has "exit 0" "rc=0" "$out"
has "the skip line names the file that blocks" "b.txt" "$(printf '%s\n' "$out" | grep 'skip (')"
eq "the local file is untouched" "mine" "$(cat "$TMP/s/b.txt")"; hasnt "no merge happened" "main-checkout: " "$(printf '%s\n' "$out" | grep -v skip | grep -v rc=)"

fresh; upstream .local ignored-upstream; echo precious > "$TMP/s/.local"
out="$(run)"; has "an ignored local file that would be overwritten: skip" "skip (" "$out"; eq "the ignored file is untouched (--no-overwrite-ignore)" "precious" "$(cat "$TMP/s/.local")"

fresh; echo local > "$TMP/s/l.txt"; G -C "$TMP/s" add l.txt; G -C "$TMP/s" commit -q -m local; upstream b.txt one
out="$(run)"; has "diverged: skip" "skip (diverged from origin/main, not a fast-forward)" "$out"
fresh; echo local > "$TMP/s/l.txt"; G -C "$TMP/s" add l.txt; G -C "$TMP/s" commit -q -m local
out="$(run)"; has "ahead of origin: skip" "skip (local main is ahead of origin/main)" "$out"

fresh; upstream b.txt one; rm -rf "$TMP/o/origin.git"
out="$(run)"; has "fetch failed: skip" "skip (fetch failed)" "$out"; has "exit 0" "rc=0" "$out"
fresh; out="$(cd "$TMP" && env MAIN_SYNC_REPO="$TMP/nope" bash "$SCRIPT" 2>&1; echo "rc=$?")"; has "no checkout: skip" "skip (no git checkout at" "$out"

# nothing is stashed, reset or forced: a tracked-file edit that does not collide survives the fast-forward
fresh; echo edited >> "$TMP/s/a.txt"; upstream b.txt one
out="$(run)"; has "a non-colliding tracked edit still fast-forwards" "main-checkout:" "$out"; has "the edit survives" "edited" "$(cat "$TMP/s/a.txt")"
eq "no stash was created" "" "$(G -C "$TMP/s" stash list)"

# dirty files and the incoming commits (by design): a dirty TRACKED file that the incoming commits touch blocks the move and is named;
# a dirty file they do not touch (tracked or untracked) does not block it, and it stays exactly as it was.
fresh; echo mine >> "$TMP/s/a.txt"; upstream a.txt incoming-a
out="$(run)"; has "a dirty tracked file the incoming commits touch: skip" "skip (" "$out"; has "and the skip line names it" "a.txt" "$(printf '%s\n' "$out" | grep 'skip (')"
eq "no move when the dirty file is touched" "$(G -C "$TMP/s" rev-parse HEAD)" "$(G -C "$TMP/s" rev-parse refs/heads/main)"
[ "$(G -C "$TMP/s" rev-parse HEAD)" != "$(G -C "$TMP/s" rev-parse origin/main)" ] && ok || bad "the checkout moved over a dirty file the commits touch"
eq "the dirty file is untouched" "$(printf 'seed\nmine')" "$(cat "$TMP/s/a.txt")"
fresh; echo mine >> "$TMP/s/a.txt"; echo wip > "$TMP/s/wip.txt"; upstream b.txt one
out="$(run)"; has "an unrelated dirty tracked file and an untracked one: the checkout still moves" "main-checkout: " "$out"; hasnt "and it is not a skip" "skip (" "$out"
eq "the checkout moved to origin/main" "$(G -C "$TMP/s" rev-parse origin/main)" "$(G -C "$TMP/s" rev-parse HEAD)"
eq "the unrelated dirty file stays as it was" "$(printf 'seed\nmine')" "$(cat "$TMP/s/a.txt")"; eq "the untracked file stays" "wip" "$(cat "$TMP/s/wip.txt")"

# the wrapper: from a linked worktree it moves the MAIN checkout, prints one line, always exits 0
fresh; upstream b.txt one; G -C "$TMP/s" worktree add -q -b wt "$TMP/wt" 2>/dev/null
out="$(cd "$TMP/wt" && bash "$WRAP" 2>&1; echo "rc=$?")"; has "wrapper: moved main from a worktree" "main-checkout:" "$out"; has "wrapper: exit 0" "rc=0" "$out"
eq "wrapper: one line plus rc" 2 "$(printf '%s\n' "$out" | wc -l)"
eq "wrapper: the main checkout moved" "$(G -C "$TMP/s" rev-parse origin/main)" "$(G -C "$TMP/s" rev-parse HEAD)"
out="$(cd "$TMP" && bash "$WRAP" 2>&1; echo "rc=$?")"; has "wrapper outside a checkout: skip, exit 0" "skip (not in a git checkout)" "$out"; has "wrapper rc" "rc=0" "$out"

echo "main-checkout-sync: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
