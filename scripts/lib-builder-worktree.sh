#!/usr/bin/env bash
# The one removal-safety check shared by scripts/seat-merge.sh (a merged row's builder worktree) and any retro step that
# retires merged worktrees. Source it; it defines functions only.
#
# worktree_removal_blocker <path> <branch> <exempt-worktree>
#   Prints ONE reason (no "kept" prefix) when the tree must NOT be removed, and nothing when it may be. Returns 0 either way.
#   <exempt-worktree> is a tree that is never removed (the caller's own); pass "" for none. Run it inside the repo.
#   The order is the safety order: every check fails closed (a git or find error keeps the tree).
#   `git worktree remove` deletes IGNORED files a plain status omits, hence the ignored / skip-worktree / ahead / recent checks.
worktree_removal_blocker() {
  local path=$1 br=$2 exempt=${3:-} first line st dirty ign hidden ahead idle recent cwdlink target
  first=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
  if [ ! -d "$path" ]; then echo "its directory is gone (git worktree prune removes the entry)"; return 0; fi
  path=$(cd "$path" && pwd -P)
  if [ -n "$exempt" ] && [ -d "$exempt" ] && [ "$path" = "$(cd "$exempt" && pwd -P)" ]; then echo "it is the merge worktree this ran in"; return 0; fi
  if [ -n "$first" ] && [ -d "$first" ] && [ "$path" = "$(cd "$first" && pwd -P)" ]; then echo "it is the main working tree"; return 0; fi
  # ONE status call, with --untracked-files=normal given explicitly. A shared `status.showUntrackedFiles=no`
  # (or a bad value that makes git exit 128) made a plain call print nothing, which read as "clean" and let
  # `git worktree remove` delete the untracked and ignored files. Fail closed: any non-zero git exit keeps the tree.
  if ! st=$(git -C "$path" status --porcelain --untracked-files=normal --ignored=matching 2>&1); then
    echo "git status failed, so the tree cannot be shown clean ($(printf '%s' "$st" | head -1))"; return 0
  fi
  dirty=$(printf '%s\n' "$st" | grep -v '^!! ' | head -1)
  if [ -n "$dirty" ]; then echo "it has uncommitted or untracked files ($dirty)"; return 0; fi
  # any ignored entry (`!! `) outside this allowlist of rebuildable output keeps the tree.
  ign=$(printf '%s\n' "$st" | sed -n 's/^!! //p' | while IFS= read -r ign; do
    case "$ign" in
      node_modules/ | */node_modules/ | dist/ | */dist/ | *.tsbuildinfo | .turbo/ | */.turbo/ | coverage/ | */coverage/) ;;
      *) printf '%s\n' "$ign"; break ;;
    esac
  done)
  if [ -n "$ign" ]; then echo "it has an ignored file that is not rebuildable output ($ign)"; return 0; fi
  # a skip-worktree (S) or assume-unchanged (lowercase) entry hides local edits from status.
  if ! hidden=$(git -C "$path" ls-files -v 2>&1); then echo "git ls-files failed ($(printf '%s' "$hidden" | head -1))"; return 0; fi
  hidden=$(printf '%s\n' "$hidden" | grep -m1 -E '^[a-zS] ' || true)
  if [ -n "$hidden" ]; then echo "it has a skip-worktree or assume-unchanged file ($hidden)"; return 0; fi
  # commits on the local branch that origin/main lacks would be stranded on a branch nobody looks at.
  ahead=$(git rev-list --count "origin/main..refs/heads/$br" 2>/dev/null || echo "?")
  if [ "$ahead" != 0 ]; then echo "branch $br has $ahead commit(s) not on origin/main"; return 0; fi
  # a live session has no cwd in its worktree between two commands, so the process scan below can miss it. A file
  # changed in the last $idle minutes (default 30) means someone is working there. Dependency and build output is skipped.
  idle="${SEAT_MERGE_IDLE_MINUTES:-30}"
  if ! recent=$(find "$path" \( -name node_modules -o -name dist -o -name .turbo -o -name coverage \) -prune -o -type f -mmin "-$idle" -print -quit 2>/dev/null); then
    echo "find could not scan it, so it cannot be shown idle"; return 0
  fi
  if [ -n "$recent" ]; then echo "a file changed in the last $idle min (${recent#"$path"/})"; return 0; fi
  for cwdlink in /proc/[0-9]*/cwd; do
    target=$(readlink "$cwdlink" 2>/dev/null) || continue
    case "$target" in "$path"|"$path"/*) echo "a process (pid $(basename "$(dirname "$cwdlink")")) has its cwd inside it"; return 0 ;; esac
  done
  return 0
}
