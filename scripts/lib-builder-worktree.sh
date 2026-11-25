#!/usr/bin/env bash
# The one removal-safety check shared by scripts/seat-merge.sh (a merged row's builder worktree) and any retro step that
# retires merged worktrees. Source it; it defines functions only.
#
# worktree_removal_blocker <path> <branch> <exempt-worktree> [detached]
#   Prints ONE reason (no "kept" prefix) when the tree must NOT be removed, and nothing when it may be. Returns 0 either way.
#   <exempt-worktree> is a tree that is never removed (the caller's own); pass "" for none. Run it inside the repo.
#   detached: the literal word "detached" skips only the "commits not on origin/main" check, for a caller (scripts/disk-sweep.sh)
#   that proves another way that origin has every commit (the same tip on origin, or a keep ref written first). Any other value
#   (or none) keeps the check.
#   The order is the safety order: every check fails closed (a git or find error keeps the tree).
#   `git worktree remove` deletes IGNORED files a plain status omits, hence the ignored / skip-worktree / ahead / recent checks.
#
# worktree_remove_clean <path>
#   `git worktree remove <path>` (never --force) after unlinking the tree's untracked node_modules SYMLINKS, which a plain remove
#   refuses as untracked files. Only a symlink whose name is exactly node_modules goes, and `rm` on a link never touches its target.
#   Any other uncommitted or untracked entry: nothing is unlinked, one line on stderr, return 1. Call it after the blocker said "".

# An untracked node_modules SYMLINK: .gitignore's `node_modules/` matches a directory only, so git lists a link as "?? node_modules".
# It is rebuildable (a link to an install), so neither the blocker nor worktree_remove_clean counts it as work. A regular file or a
# directory of that name, and any quoted path, do not match.
_bw_nm_link() {  # $1 = tree path, $2 = one porcelain line
  local e
  case "$2" in "?? node_modules" | "?? "*/node_modules) e=${2#?? } ;; *) return 1 ;; esac
  [ -L "$1/$e" ]
}
worktree_removal_blocker() {
  local path=$1 br=$2 exempt=${3:-} detached=${4:-} first line st dirty ign hidden ahead idle recent cwdlink target sdirs cls kind rest
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
  dirty=$(printf '%s\n' "$st" | grep -v '^!! ' | while IFS= read -r line; do
    [ -n "$line" ] || continue
    _bw_nm_link "$path" "$line" && continue
    printf '%s\n' "$line"; break
  done)
  if [ -n "$dirty" ]; then echo "it has uncommitted or untracked files ($dirty)"; return 0; fi
  # any ignored entry (`!! `) outside this allowlist of rebuildable output keeps the tree.
  ign=$(printf '%s\n' "$st" | sed -n 's/^!! //p' | while IFS= read -r ign; do
    case "$ign" in
      # Each entry is output a command regenerates, never hand-written: node_modules (an install), dist (a build), *.tsbuildinfo (tsc),
      # .turbo and coverage (caches), __pycache__ (python bytecode).
      node_modules/ | */node_modules/ | dist/ | */dist/ | *.tsbuildinfo | .turbo/ | */.turbo/ | coverage/ | */coverage/ | __pycache__/ | */__pycache__/) ;;
      *) printf '%s\n' "$ign"; break ;;
    esac
  done)
  if [ -n "$ign" ]; then echo "it has an ignored file that is not rebuildable output ($ign)"; return 0; fi
  # a skip-worktree (S) or assume-unchanged (lowercase) entry hides local edits from status.
  if ! hidden=$(git -C "$path" -c core.quotePath=false ls-files -v 2>&1); then echo "git ls-files failed ($(printf '%s' "$hidden" | head -1))"; return 0; fi
  hidden=$(printf '%s\n' "$hidden" | grep -E '^[a-zS] ' || true)
  # A CONE sparse tree (a small worktree that checks out only a few folders) marks every file outside its set skip-worktree, so the
  # check above would keep all of them forever. There an `S` entry is exempt only when it lies OUTSIDE the set: its folder is neither
  # inside a listed folder nor an ancestor of one (a cone also keeps the files directly in an ancestor folder), and a root file is
  # always inside. A lowercase tag (assume-unchanged), a hand-set `S` inside the set, a quoted path, and any non-cone sparse tree
  # still keep the tree (fail closed).
  if [ -n "$hidden" ] && [ "$(git -C "$path" config --get core.sparseCheckout 2>/dev/null)" = true ] \
    && [ "$(git -C "$path" config --get core.sparseCheckoutCone 2>/dev/null)" = true ]; then
    sdirs=$(git -C "$path" sparse-checkout list 2>/dev/null) || sdirs=""
    if [ -n "$sdirs" ]; then
      # awk classifies: "K<TAB>entry" keeps the tree at once; "O<TAB>path" is outside the set. An outside entry still keeps the tree when
      # the path EXISTS on disk: with sparse.expectFilesOutsideOfPatterns=true git leaves the S bit on a present file and status hides
      # it, so work written there would look like "outside the set" and be deleted.
      cls=$(printf '%s\n' "$hidden" | awk -v dirs="$sdirs" '
        BEGIN { n = split(dirs, D, "\n") }
        { if (substr($0, 1, 1) != "S") { print "K\t" $0; exit }
          p = substr($0, 3); inside = 0
          if (substr(p, 1, 1) == "\"") inside = 1
          else { d = p
            if (!sub(/\/[^\/]*$/, "", d)) inside = 1
            else for (i = 1; i <= n; i++) { x = D[i]; sub(/^\//, "", x); sub(/\/$/, "", x); if (x == "") continue
              if (d == x || index(d, x "/") == 1 || index(x, d "/") == 1) inside = 1 } }
          if (inside) { print "K\t" $0; exit }
          print "O\t" p }')
      hidden=""
      while IFS=$'\t' read -r kind rest; do
        case "$kind" in
          K) hidden=$rest; break ;;
          O) if [ -e "$path/$rest" ] || [ -L "$path/$rest" ]; then hidden="S $rest"; break; fi ;;
        esac
      done <<< "$cls"
    else hidden=$(printf '%s\n' "$hidden" | head -1); fi
  else hidden=$(printf '%s\n' "$hidden" | head -1); fi
  if [ -n "$hidden" ]; then echo "it has a skip-worktree or assume-unchanged file ($hidden)"; return 0; fi
  # commits on the local branch that origin/main lacks would be stranded on a branch nobody looks at.
  if [ "$detached" != detached ]; then
    ahead=$(git rev-list --count "origin/main..refs/heads/$br" 2>/dev/null || echo "?")
  else ahead=0; fi
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

worktree_remove_clean() {
  local path=$1 st line links=() l
  if ! st=$(git -C "$path" status --porcelain --untracked-files=normal 2>&1); then
    echo "git status failed ($(printf '%s' "$st" | head -1))" >&2; return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if _bw_nm_link "$path" "$line"; then links+=("$path/${line#?? }"); continue; fi
    echo "it has uncommitted or untracked files ($line)" >&2; return 1
  done <<< "$st"
  for l in ${links[@]+"${links[@]}"}; do rm -- "$l" || return 1; done
  git worktree remove "$path"
}
