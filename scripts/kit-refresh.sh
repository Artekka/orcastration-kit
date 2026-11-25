#!/usr/bin/env bash
# kit-refresh.sh (orcastration-kit): refresh a project's copies of the kit's scripts that were made on 0.16, before the
# 0.17.0 id rename. kit-init copies scripts only when they are missing, so a project adopted on 0.16 keeps:
#   - launch scripts whose default prompt is the 0.16 command prefix, which no longer exists, and
#   - gate-throttle.sh, quiet-mode.sh and seat-merge.sh, which write to the 0.16 state folder. While such a copy runs,
#     the state folder can split in two (two throttle slot sets) when the 0.16 name's link is missing.
# Run it from the project root, with the kit's own copy:  bash "$K/scripts/kit-refresh.sh" [--apply]
#   no flag   list what is stale; change nothing
#   --apply   replace each stale copy with the kit's, and create the libraries a refreshed script sources when missing
# The project is the folder you run it from (not git's top level). Its promises: it never writes outside the project,
# never replaces content that is not a known kit 0.16 version, and changes nothing without --apply.
# scripts/ must be a real folder of the project (not a symlink, and `cd scripts && pwd -P` = "$(pwd -P)/scripts"),
# else exit 3 with nothing changed. Every later check and write runs inside scripts/ on the bare file name.
# A copy is STALE when it differs from the kit's and still names the 0.16 command prefix or the 0.16 folder.
# It is replaced only when ALL of these hold, else it is LEFT with the reason:
#   - its exact bytes (git hash-object --no-filters; the file mode is not hashed) are a known kit 0.16 version of that
#     script (the list below), so a project-edited copy is never replaced;
#   - it is a regular file: no symlink, no second hard link, and writable (`-w`);
#   - the project's git tracks it with no uncommitted change, so `git diff` shows the refresh and `git checkout` undoes it.
# A copy that differs but names nothing from 0.16 (a project's edit on 0.17) is never touched (DIFFERS).
# Every write (REFRESH and CREATE) is one safe write: a temp file in scripts/, the mode set, then `mv -f` onto the name;
# a failed write is LEFT (could not replace) and no temp file stays behind. A dangling link at a library name is LEFT.
# CDPATH is unset first, so `cd scripts` always enters this project's scripts/.
# Git's repo-discovery variables (GIT_DIR, GIT_WORK_TREE, ...) are unset first: a caller's shell may carry them, and the
# project's own git must decide what is tracked (unset, not refused: kit-init runs this in the user's shell).
# Limits (README): a bind mount is not seen; do not edit scripts/ while it runs (nor put a folder or link at a name
# between the check and the move); case-folding file systems: exact names
# only; a read-only copy is found by the shell's -w test, which root always passes.
# Exit: 0 = done (or nothing to do) · 3 = something was left (or scripts/ is not a real project folder) · 64 = usage.
# Maintainers: after a new 0.16.x tag (there will be none) regenerate the list: bash scripts/kit-refresh.sh --print-known
# (tests/kit-refresh.test.sh checks it against the tags). KIT_REFRESH_TEST_KNOWN is a TEST seam: a file of extra
# "<file> <blob>" lines, so the suite can run without the tags (CI's shallow clone has none). It is read only when
# KIT_REFRESH_TEST=1 is set too, and then one stderr line says so; a normal run ignores it.
# BEGIN known-0.16 (generated: bash scripts/kit-refresh.sh --print-known; the git blob of each script at the v0.16.* tags)
# gate-throttle.sh 235b6008eff83d8c57e186287f834e8af9503769
# gate-throttle.sh 57cc5bbf26aa4b67077c937c6790a80ddc3ac422
# lib-launch.sh 948d2fb0b5b13262b4e8fb863adcc730f57ff622
# lib-model-tag.sh 7d47892d1d182295c865a5955428c503a8dbe39d
# quiet-mode.sh 02fee083162055f2226b2c8fdc81e7a8f749c65e
# recycle-sibling.sh a9aca4454172d9f27a5b9b21de16d7b74c6df376
# seat-merge.sh a182069e940bc3a3084fc7dd0e238742e2d58524
# seat-merge.sh daba70a858bcb0466a818e2191b78bdbb9eada63
# sibling-shell.sh 688b7ff2b5dfce08923ef58706caade239f72c47
# start-team.sh b6f3303aa8dbf7a1104627b8ebeab029ac4b29c2
# END known-0.16
set -u
unset CDPATH   # a caller's CDPATH would steer `cd scripts` into another folder's scripts/
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
APPLY=0
FILES="start-team.sh recycle-sibling.sh sibling-shell.sh lib-launch.sh lib-model-tag.sh gate-throttle.sh quiet-mode.sh seat-merge.sh"
case "${1:-}" in
  --apply) APPLY=1 ;;
  --print-known)   # maintainer: the list above, from the v0.16.* tags of the kit repo this script sits in
    kd="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    tags="$(git -C "$kd" tag -l 'v0.16.*' 2>/dev/null)"
    [ -n "$tags" ] || { echo "kit-refresh: no v0.16.* tags in $kd (git fetch --tags first)" >&2; exit 1; }
    for t in $tags; do for f in $FILES; do b="$(git -C "$kd" rev-parse -q --verify "$t:scripts/$f" 2>/dev/null)" && echo "$f $b"; done; done | LC_ALL=C sort -u
    exit 0 ;;
  "") ;;
  *) echo "usage: kit-refresh.sh [--apply]   (run from the project root)" >&2; exit 64 ;;
esac
K="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -d scripts ] || { echo "kit-refresh: no scripts/ folder here; run it from the project root" >&2; exit 64; }
OLD_PREFIX="/orch""estration-kit:"; OLD_FOLDER=".orch""estration-kit"   # the 0.16 prefix and folder (split: docs-pins sweep)
RUNNABLE=" start-team.sh recycle-sibling.sh sibling-shell.sh gate-throttle.sh quiet-mode.sh seat-merge.sh "
# every library the refreshed scripts source; one that is missing is created (lib-kit-home.sh is new in 0.17.0)
LIBS="lib-kit-home.sh lib-launch.sh lib-model-tag.sh lib-builder-worktree.sh lib-waiting-tickets.sh lib-git-retry.sh lib-conflict-markers.sh lib-mono-clock.sh"
# scripts/ must be a real folder of THIS project (physical paths): a linked scripts/ would carry every write elsewhere,
# even into a parent repo that holds the link target.
root="$(pwd -P)"; sdir="$(cd scripts && pwd -P)"
if [ -L scripts ] || [ "$sdir" != "$root/scripts" ]; then
  echo "kit-refresh: scripts/ is a symlink or resolves outside the project ($sdir, project $root); nothing was changed. Refresh those copies by hand." >&2; exit 3
fi
KNOWN="$(sed -n '/^# BEGIN known-0.16/,/^# END known-0.16/p' "${BASH_SOURCE[0]}" | sed '1d;$d' | sed 's/^# //')"
if [ "${KIT_REFRESH_TEST:-}" = 1 ] && [ -n "${KIT_REFRESH_TEST_KNOWN:-}" ] && [ -f "$KIT_REFRESH_TEST_KNOWN" ]; then
  echo "kit-refresh: TEST seam on: extra known versions from KIT_REFRESH_TEST_KNOWN=$KIT_REFRESH_TEST_KNOWN" >&2
  KNOWN="$KNOWN
$(cat "$KIT_REFRESH_TEST_KNOWN")"
fi
cd scripts || exit 3   # from here on every check and write uses the bare file name
in_git=0; git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1
um="$(umask)"; MODE_FILE="$(printf '%o' $((0666 & ~um)))"; MODE_RUN="$(printf '%o' $((0777 & ~um)))"
tmp=""; trap '[ -n "$tmp" ] && rm -f -- "$tmp"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
safe_write() {  # <src> <name> <mode>: a temp file here, the mode set, mv -f onto the name. 0 = written
  tmp="$(mktemp ./.kit-refresh.XXXXXX 2>/dev/null)" || { tmp=""; return 1; }
  if cp "$1" "$tmp" 2>/dev/null && chmod "$3" "$tmp" 2>/dev/null \
     && ! [ -d "$2" ] && mv -f "$tmp" "$2" 2>/dev/null; then   # mv onto a folder (or a link to one) would move INTO it
    tmp=""; return 0
  fi
  rm -f -- "$tmp"; tmp=""; return 1
}
links() {  # <name>: the hard-link count, empty when stat cannot tell
  local n; n="$(stat -c %h -- "$1" 2>/dev/null || stat -f %l -- "$1" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) echo "" ;; *) echo "$n" ;; esac
}
stale=0 refreshed=0 left=0 created=""
for f in $FILES; do
  dst="scripts/$f"; src="$K/scripts/$f"
  [ -e "$f" ] || [ -L "$f" ] || continue
  cmp -s "$f" "$src" && continue
  if [ -L "$f" ]; then   # no link is ever followed: the target may be outside the project, or shared
    echo "LEFT   $dst (a symlink; the refresh never writes through a link: replace it by hand with $src)"; left=$((left + 1)); continue
  fi
  if ! grep -qF -e "$OLD_PREFIX" -e "$OLD_FOLDER" "$f"; then
    echo "DIFFERS $dst (names nothing from 0.16; left as it is)"; continue
  fi
  stale=$((stale + 1))
  if [ "$APPLY" = 0 ]; then echo "STALE  $dst"; continue; fi
  if ! printf '%s\n' "$KNOWN" | grep -qxF "$f $(git hash-object --no-filters -- "$f" 2>/dev/null)"; then
    echo "LEFT   $dst (edited by the project: not a kit 0.16 version. Compare: diff -u $dst $src ; then copy by hand: cp $src $dst)"; left=$((left + 1)); continue
  fi
  if [ "$in_git" = 0 ] || ! git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    echo "LEFT   $dst (not tracked by git, so a refresh could not be undone; compare it with $src and copy by hand)"; left=$((left + 1)); continue
  fi
  if ! git diff --quiet HEAD -- "$f" 2>/dev/null; then
    echo "LEFT   $dst (uncommitted changes; commit or discard them, then run this again)"; left=$((left + 1)); continue
  fi
  n="$(links "$f")"
  if [ "$n" != 1 ]; then
    echo "LEFT   $dst (hard-linked: ${n:-an unknown number of} names share this file, so another name would keep the old copy; copy by hand with $src)"; left=$((left + 1)); continue
  fi
  if [ ! -w "$f" ]; then
    echo "LEFT   $dst (read-only; make it writable or copy by hand with $src)"; left=$((left + 1)); continue
  fi
  mode="$MODE_FILE"; case "$RUNNABLE" in *" $f "*) mode="$MODE_RUN" ;; esac
  if ! safe_write "$src" "$f" "$mode"; then
    echo "LEFT   $dst (could not replace it: the folder is not writable or the move failed; copy by hand with $src)"; left=$((left + 1)); continue
  fi
  echo "REFRESH $dst"; refreshed=$((refreshed + 1))
done
if [ "$APPLY" = 1 ] && [ "$refreshed" -gt 0 ]; then
  for l in $LIBS; do
    [ -e "$l" ] && continue
    if [ -L "$l" ]; then   # a dangling link: never written through, and the refreshed scripts would source nothing
      echo "LEFT   scripts/$l (a dangling link at a library name; the refreshed scripts source it: remove the link, then copy $K/scripts/$l by hand)"; left=$((left + 1)); continue
    fi
    if safe_write "$K/scripts/$l" "$l" "$MODE_FILE"; then
      echo "CREATE  scripts/$l"; created="$created scripts/$l"
    else
      echo "LEFT   scripts/$l (could not create it; copy by hand with $K/scripts/$l)"; left=$((left + 1))
    fi
  done
fi
[ "$stale" -gt 0 ] || echo "kit-refresh: nothing to refresh"
if [ "$APPLY" = 1 ] && [ "$refreshed" -gt 0 ]; then echo "kit-refresh: review with: git diff -- scripts/   (undo one: git checkout -- scripts/<file>)"; fi
if [ -n "$created" ]; then echo "kit-refresh: created as new untracked files:$created (git checkout does not remove them; to undo, delete them)"; fi
[ "$left" -eq 0 ] || exit 3
exit 0
