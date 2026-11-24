#!/usr/bin/env bash
# A retiring session removes its MERGED worktrees (run by /retro, Step 4b). Ported from a project whose disk filled with
# hundreds of stale worktrees.
# Usage: scripts/retro-worktrees.sh --prefix <branch-prefix> [--dry-run]     (e.g. --prefix s5e307/)
# Candidates: worktrees (git worktree list --porcelain) whose branch starts with the prefix. A tree whose tip is not an
# ancestor of origin/main is kept (its commits are not on main yet). The rest go through worktree_removal_blocker
# (scripts/lib-builder-worktree.sh, the check seat-merge.sh uses): clean, no non-rebuildable ignored file, no commit beyond
# origin/main, no file changed in the last 30 min, no process cwd inside. Skipped silently: other prefixes, detached trees.
# The worktree this runs in is never removed. Never `--force`; branch refs stay, so no commit is lost.
# --prefix is REQUIRED and may not be empty: an empty prefix would match every worktree on the host.
# One removed/kept line per candidate, then "retro-worktrees: removed N, kept M" (--dry-run: "would remove N, kept M").

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-builder-worktree.sh
. "$LIB/lib-builder-worktree.sh"

usage() { echo 'usage: scripts/retro-worktrees.sh --prefix <branch-prefix> [--dry-run]' >&2; exit 2; }
prefix=""; have_prefix=0; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || usage; prefix=$2; have_prefix=1; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
[ "$have_prefix" = 1 ] && [ -n "$prefix" ] || usage
# A prefix without its closing slash would also match a longer session id (s5e30 matches s5e307/a): require the slash.
case "$prefix" in */) ;; *) echo "retro-worktrees: --prefix must end with / (e.g. s5e307/), or it can match another session's branches" >&2; exit 2 ;; esac

here=$(git rev-parse --show-toplevel) || exit 2
# One retry. A stale origin/main only makes fewer trees look merged, which is the safe direction.
git fetch origin >/dev/null 2>&1 || { sleep 2; git fetch origin >/dev/null 2>&1; } || echo "retro-worktrees: fetch failed; using the local origin/main" >&2

removed=0; kept=0; verb=removed; [ "$dry" = 1 ] && verb="would remove"
handle() {  # $1 = path, $2 = branch
  local path=$1 br=$2 why err
  if [ -d "$path" ] && [ "$(cd "$path" && pwd -P)" = "$(cd "$here" && pwd -P)" ]; then
    echo "retro-worktrees: kept $path: it is the worktree this ran in"; kept=$((kept + 1)); return
  fi
  if ! git merge-base --is-ancestor "refs/heads/$br" origin/main 2>/dev/null; then
    echo "retro-worktrees: kept $path: branch $br is not merged into origin/main"; kept=$((kept + 1)); return
  fi
  why=$(worktree_removal_blocker "$path" "$br" "$here")
  if [ -n "$why" ]; then echo "retro-worktrees: kept $path: $why"; kept=$((kept + 1)); return; fi
  path=$(cd "$path" && pwd -P)
  if [ "$dry" = 1 ]; then echo "retro-worktrees: would remove $path"; removed=$((removed + 1)); return; fi
  if err=$(git worktree remove "$path" 2>&1); then echo "retro-worktrees: removed $path"; removed=$((removed + 1))
  else echo "retro-worktrees: kept $path: git refused to remove it ($(printf '%s' "$err" | head -1))"; kept=$((kept + 1)); fi
}

cur=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) cur=${line#worktree } ;;
    "branch refs/heads/$prefix"*) handle "$cur" "${line#branch refs/heads/}" ;;
  esac
done < <(git worktree list --porcelain)
echo "retro-worktrees: $verb $removed, kept $kept"
