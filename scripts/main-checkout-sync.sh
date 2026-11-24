#!/usr/bin/env bash
# main-checkout-sync.sh: keep the SHARED main checkout on origin/main. Every session starts there and loads its rules, skills
# and scripts from it, but the seat works in worktrees, so nothing moves it: it drifts hundreds of commits behind and every hook
# runs stale. Run it from the seat's periodic poll, or right after a push lands (scripts/sync-main-checkout.sh does that).
#
# It only ever fast-forwards. In any other state it prints ONE `main-checkout: skip (<reason>)` line, changes nothing and exits 0,
# so a poll never fails on a sibling's work. It never stashes, never forces, never resets and never touches a file it does not
# update: `git merge --ff-only` itself refuses when a dirty or untracked file would be overwritten, and that refusal is kept.
# `--no-overwrite-ignore` extends it to git-IGNORED local files (git overwrites those by default): a git-excluded settings file
# that holds a hook must survive.
#
# Target: the MAIN worktree (first entry of `git worktree list`), whichever worktree's copy of this script runs.
# Env: MAIN_SYNC_REPO overrides the target (tests point it at a throwaway clone); MAIN_SYNC_NO_FETCH=1 skips the fetch (test seam).
# Output (one line): `main-checkout: current <sha9>` | `main-checkout: <old> → <new> (<n> commits)` | `main-checkout: skip (<reason>)`.
# Exit 0 always except a usage problem: a poll must not fail because the checkout could not move.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skip() { echo "main-checkout: skip ($1)"; exit 0; }

repo="${MAIN_SYNC_REPO:-$(git -C "$here" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')}"
[ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || skip "no git checkout at '${repo:-?}'"
g() { git -C "$repo" "$@"; }

# Run before the fetch (cheap exit) AND again right after it: the fetch can take seconds, and a sibling may switch
# branches or start a rebase in that window. Each skip exits, so the second call only matters when state changed.
guards() {
  local ref name p
  ref="$(g symbolic-ref -q HEAD)"
  [ -n "$ref" ] || skip "detached HEAD"
  [ "$ref" = "refs/heads/main" ] || skip "not on main: on branch ${ref#refs/heads/}"
  for name in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    p="$(g rev-parse --git-path "$name")"
    case "$p" in /*) ;; *) p="$repo/$p" ;; esac
    [ -e "$p" ] && skip "$name in progress"
  done
}
guards

if [ "${MAIN_SYNC_NO_FETCH:-}" != "1" ]; then
  # One retry with a pause: `fetch || { sleep 2; fetch; }`. A loop that ends in `sleep` exits 0 even after every fetch failed.
  g fetch -q origin 2>/dev/null || { sleep 2; g fetch -q origin 2>/dev/null; } || skip "fetch failed"
  guards
fi

new="$(g rev-parse -q --verify refs/remotes/origin/main)" || skip "no origin/main"
old="$(g rev-parse HEAD)"
[ "$old" = "$new" ] && { echo "main-checkout: current ${old:0:9}"; exit 0; }
if ! g merge-base --is-ancestor "$old" "$new"; then
  if g merge-base --is-ancestor "$new" "$old"; then skip "local main is ahead of origin/main"; fi
  skip "diverged from origin/main, not a fast-forward"
fi

if ! err="$(g merge --ff-only --no-overwrite-ignore -q origin/main 2>&1)"; then
  first="$(printf '%s\n' "$err" | sed -n '/[^[:space:]]/{s/^\(error\|fatal\): //;p;q}')"
  skip "${first:-merge refused}"
fi
echo "main-checkout: ${old:0:9} → $(g rev-parse HEAD | cut -c1-9) ($(g rev-list --count "$old..HEAD") commits)"
exit 0
