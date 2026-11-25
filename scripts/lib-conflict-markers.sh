#!/usr/bin/env bash
# lib-conflict-markers.sh: list committed conflict markers in a merged tree. Sourced by seat-merge.sh.
# Why: a merge that COMMITS markers into a file no test reads goes green on every check and ships. The scan is a few
# hundred milliseconds, so it runs first, before the format check (a file with markers usually fails the formatter first and
# would hide the cause).
#
# conflict_markers_report <root> [rev] [include_md] [path...]
#   root        the git worktree to scan (tracked files only: an untracked file is in no merge or push)
#   rev         "" = the working tree; a commit or tree = read that revision instead
#   include_md  default 1: *.md is scanned too (prose that quotes markers belongs on the exempt list). 0 skips it.
#   path...     narrow the scan to these paths
# Prints one "file:line: <marker line>" per marker; returns 1 if any, 0 if none, 2 if git itself failed (never "none").
# A "=======" line counts ONLY between a "<<<<<<<" and its ">>>>>>>" (a setext underline or a yaml rule is not a conflict).
# Path prefixes on the exempt list are skipped. The list is $CONFLICT_MARKERS_EXEMPT_TEXT (newline-separated; '#' lines are
# comments; set even when empty). seat-merge.sh reads it ONCE before the merge, so a merged branch cannot exempt itself.
conflict_markers_report() {
  local root="${1:-.}" rev="${2:-}" md="${3:-1}" exempt_text="${CONFLICT_MARKERS_EXEMPT_TEXT-}" out rc
  [ "$#" -gt 3 ] && shift 3 || shift "$#"
  local -a spec=(.)
  [ "$#" -gt 0 ] && spec=("$@")
  [ "$md" = 0 ] && spec+=(':(exclude)*.md')
  local -a args=(-C "$root" grep -nIE '^(<{7}|>{7})( |$)|^={7}$')
  [ -n "$rev" ] && args+=("$rev")
  args+=(-- "${spec[@]}")
  out="$(git "${args[@]}" 2>&1)"; rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'conflict-markers: git grep failed (status %s): %s\n' "$rc" "$(printf '%s' "$out" | head -1)" >&2
    return 2
  fi
  [ "$rc" -eq 1 ] && return 0   # git grep: 1 = no match
  printf '%s\n' "$out" | REV="$rev" EXT="$exempt_text" awk -F: '
    BEGIN { n = split(ENVIRON["EXT"], raw, "\n"); m = 0
            for (i = 1; i <= n; i++) if (raw[i] !~ /^#/ && raw[i] != "") P[m++] = raw[i]
            rev = ENVIRON["REV"] }
    {
      line = $0
      if (rev != "" && index(line, rev ":") == 1) line = substr(line, length(rev) + 2)
      split(line, f, ":"); path = f[1]; no = f[2]
      txt = substr(line, length(path) + length(no) + 3)
      skip = 0; for (i = 0; i < m; i++) if (index(path, P[i]) == 1) skip = 1
      if (skip) next
      if (path != last) { open = 0; last = path }
      if (txt ~ /^<<<<<<</) open = 1
      else if (txt ~ /^=======$/) { if (!open) next }
      else if (txt ~ /^>>>>>>>/) open = 0
      printf "%s:%s: %s\n", path, no, txt; found = 1
    }
    END { exit found ? 1 : 0 }'
  return "${PIPESTATUS[1]}"
}
