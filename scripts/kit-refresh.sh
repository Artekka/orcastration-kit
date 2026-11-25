#!/usr/bin/env bash
# kit-refresh.sh (orcastration-kit): refresh a project's copies of the kit's scripts that were made on 0.16, before the
# 0.17.0 id rename. kit-init copies scripts only when they are missing, so a project adopted on 0.16 keeps:
#   - launch scripts whose default prompt is the 0.16 command prefix, which no longer exists, and
#   - gate-throttle.sh, quiet-mode.sh and seat-merge.sh, which write to the 0.16 state folder. While such a copy runs,
#     the state folder can split in two (two throttle slot sets) when the 0.16 name's link is missing.
# Run it from the project root, with the kit's own copy:  bash "$K/scripts/kit-refresh.sh" [--apply]
#   no flag   list what is stale; change nothing
#   --apply   replace each stale copy with the kit's, and create the libraries a refreshed script sources when missing
# A copy is STALE when it differs from the kit's and still names the 0.16 command prefix or the 0.16 folder.
# It is replaced only when the project's git tracks it with no uncommitted change, so `git diff` shows exactly what the
# refresh changed (a project's own edits included) and `git checkout -- <file>` undoes it. Anything else is LEFT, with
# the reason. A copy that differs but names nothing from 0.16 (a project's edit on 0.17) is never touched (DIFFERS).
# Exit: 0 = done (or nothing to do) · 3 = --apply left at least one stale copy · 64 = usage.
set -u
APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "") ;;
  *) echo "usage: kit-refresh.sh [--apply]   (run from the project root)" >&2; exit 64 ;;
esac
K="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -d scripts ] || { echo "kit-refresh: no scripts/ folder here; run it from the project root" >&2; exit 64; }
OLD_PREFIX="/orch""estration-kit:"; OLD_FOLDER=".orch""estration-kit"   # the 0.16 prefix and folder (split: docs-pins sweep)
FILES="start-team.sh recycle-sibling.sh sibling-shell.sh lib-launch.sh lib-model-tag.sh gate-throttle.sh quiet-mode.sh seat-merge.sh"
RUNNABLE=" start-team.sh recycle-sibling.sh sibling-shell.sh gate-throttle.sh quiet-mode.sh seat-merge.sh "
# every library the refreshed scripts source; one that is missing is created (lib-kit-home.sh is new in 0.17.0)
LIBS="lib-kit-home.sh lib-launch.sh lib-model-tag.sh lib-builder-worktree.sh lib-waiting-tickets.sh lib-git-retry.sh lib-conflict-markers.sh lib-mono-clock.sh"
in_git=0; git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1
stale=0 refreshed=0 left=0
for f in $FILES; do
  dst="scripts/$f"; src="$K/scripts/$f"
  [ -f "$dst" ] || continue
  cmp -s "$dst" "$src" && continue
  if ! grep -qF -e "$OLD_PREFIX" -e "$OLD_FOLDER" "$dst"; then
    echo "DIFFERS $dst (names nothing from 0.16; left as it is)"; continue
  fi
  stale=$((stale + 1))
  if [ "$APPLY" = 0 ]; then echo "STALE  $dst"; continue; fi
  if [ "$in_git" = 0 ] || ! git ls-files --error-unmatch -- "$dst" >/dev/null 2>&1; then
    echo "LEFT   $dst (not tracked by git, so a refresh could not be undone; compare it with $src and copy by hand)"; left=$((left + 1)); continue
  fi
  if ! git diff --quiet HEAD -- "$dst" 2>/dev/null; then
    echo "LEFT   $dst (uncommitted changes; commit or discard them, then run this again)"; left=$((left + 1)); continue
  fi
  cp "$src" "$dst" && case "$RUNNABLE" in *" $f "*) chmod +x "$dst" ;; esac
  echo "REFRESH $dst"; refreshed=$((refreshed + 1))
done
if [ "$APPLY" = 1 ] && [ "$refreshed" -gt 0 ]; then
  for l in $LIBS; do
    [ -e "scripts/$l" ] && continue
    cp "$K/scripts/$l" "scripts/$l" && echo "CREATE  scripts/$l"
  done
fi
[ "$stale" -gt 0 ] || echo "kit-refresh: nothing to refresh"
if [ "$APPLY" = 1 ] && [ "$refreshed" -gt 0 ]; then echo "kit-refresh: review with: git diff -- scripts/   (undo one: git checkout -- scripts/<file>)"; fi
[ "$left" -eq 0 ] || exit 3
exit 0
