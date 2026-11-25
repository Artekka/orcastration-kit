#!/usr/bin/env bash
# PreToolUse hook (orcastration-kit) for Edit|Write|MultiEdit|NotebookEdit: OPTIONAL worktree
# enforcement. Blocks file edits in the repo's MAIN checkout so every session works in its own
# linked worktree.
#
# NO-OP (exit 0, no output) unless ALL hold:
#   - the target file's repo carries the opt-in marker docs/orchestration/.kit-hooks;
#   - docs/orchestration/ORCHESTRATION.md says `worktrees: enforced` (default is `advised`);
#   - the file resolves inside the MAIN worktree (first entry of `git worktree list`), not a linked one;
#   - the file is not allowlisted: docs/orchestration/**, the log and the status doc (paths from
#     ORCHESTRATION.md -> Docs; defaults docs/timeline/build-log.md, docs/AI_CONTEXT.md). Those are
#     edited in place and committed within seconds by design.
# Anything unparseable, or outside a git repo, is allowed. Deliberately no set -e: a hook must never
# break a tool call. No network; two git calls at most.

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# First value of a top-level-looking string key. JSON escapes any quote inside a string as \",
# so '"key"' followed by ':' can only match a real key, never file content.
json_str() {
  printf '%s' "$input" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -n1 \
    | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' -e 's#\\/#/#g'
}

path="$(json_str file_path)"
[ -n "$path" ] || path="$(json_str notebook_path)"
[ -n "$path" ] || exit 0
case "$path" in *\\*) exit 0 ;; esac   # escaped chars we don't decode: allow rather than guess

if [ "${path#/}" = "$path" ]; then       # relative -> resolve against the session cwd
  cwd="$(json_str cwd)"
  [ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  path="$cwd/$path"
fi

# Nearest existing ancestor directory (Write may target a file or dirs that don't exist yet).
dir="$(dirname -- "$path")"; rest="$(basename -- "$path")"
while [ ! -d "$dir" ]; do
  rest="$(basename -- "$dir")/$rest"; dir="$(dirname -- "$dir")"
  case "$dir" in /|.) break ;; esac
done
[ -d "$dir" ] || exit 0
phys="$(cd -- "$dir" 2>/dev/null && pwd -P)" || exit 0
full="$phys/$rest"

top="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null)" || exit 0          # git call 1
[ -n "$top" ] || exit 0
main="$(git -C "$phys" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"  # git call 2
[ -n "$main" ] || exit 0
main="$(cd -- "$main" 2>/dev/null && pwd -P)" || exit 0
[ "$top" = "$main" ] || exit 0          # file lives in a linked worktree -> allowed

conf="$main/docs/orchestration/ORCHESTRATION.md"
[ -f "$main/docs/orchestration/.kit-hooks" ] || exit 0
[ -f "$conf" ] || exit 0
grep -Eq '^[[:space:]]*worktrees:[[:space:]]*enforced([[:space:]]|#|$)' "$conf" 2>/dev/null || exit 0

rel="${full#"$main"/}"
[ "$rel" != "$full" ] || exit 0         # not under the main checkout -> allowed

docpath() {  # <key regex> <default>
  local v
  v="$(sed -n -E "s/^[[:space:]]*($1):[[:space:]]*([^[:space:]#]+).*/\\2/p" "$conf" 2>/dev/null | head -n1)"
  case "$v" in ''|'<'*) v="$2" ;; esac
  printf '%s' "${v#./}"
}
case "$rel" in
  docs/orchestration/*) exit 0 ;;
  "$(docpath 'log' 'docs/timeline/build-log.md')") exit 0 ;;
  "$(docpath 'status doc' 'docs/AI_CONTEXT.md')") exit 0 ;;
esac

repo="$(basename -- "$main")"
reason="Blocked by orcastration-kit: this repo enforces one git worktree per session, and $rel is in the MAIN checkout ($main). Create or use your own worktree, then make this edit there: git worktree add ../$repo-<session> -b <branch> (or the EnterWorktree tool if available). Board, log and status-doc files stay editable in place. The user can turn enforcement off by setting worktrees: advised in docs/orchestration/ORCHESTRATION.md, or by asking Claude to change it."
reason="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
