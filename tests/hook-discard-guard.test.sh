#!/usr/bin/env bash
# Tests for hooks/discard-guard.py: a command that would overwrite uncommitted edits is refused, naming the paths; clean paths, other
# worktrees, ALLOW_DISCARD=1 and anything unreadable pass. Run: bash tests/hook-discard-guard.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
. "$(dirname "$0")/lib-hook-test.sh"
command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || { echo "hook-discard-guard: SKIP (no python3 or git)"; exit 0; }
H="$ROOT/hooks/discard-guard.py"; C="$ROOT/tests/hook-cases"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G() { git -c user.email=t@example.com -c user.name=T -c core.hooksPath=/dev/null "$@"; }
R="$TMP/repo"; mkdir -p "$R/sub" "$TMP/plain"
G init -q -b main "$R"; for f in a.txt b.txt staged.txt sub/c.txt; do echo one > "$R/$f"; done
G -C "$R" add a.txt b.txt staged.txt sub/c.txt; G -C "$R" commit -q -m init
G -C "$R" worktree add -q -b other "$TMP/clean"
# dirty bodies differ in SIZE from "one": a same-size rewrite can hide in git's stat cache
echo dirty > "$R/a.txt"; echo dirty > "$R/staged.txt"; G -C "$R" add staged.txt; echo dirty > "$R/sub/c.txt"; echo u > "$R/untracked.txt"
drive "$H" "$C/discard.refuse.jsonl" refuse --cwd "$R" --fix "Commit or copy them first"
drive "$H" "$C/discard.allow.jsonl" allow --cwd "$R"
# a dirty file in ANOTHER worktree does not count
printf '%s\n' '"git checkout -- a.txt"' '"git restore a.txt"' '"git reset --hard"' '"git checkout -- ."' '"git checkout -f main"' > "$TMP/clean.cases"
drive "$H" "$TMP/clean.cases" allow --cwd "$TMP/clean"
printf '%s\n' '"git reset --hard"' '"git checkout -f main"' > "$TMP/plain.cases"; drive "$H" "$TMP/plain.cases" allow --cwd "$TMP/plain"
# override: a prefix assignment of the command, or the hook's environment; ALLOW_DISCARD=0 and a prefix on another command do not override
out="$(feed "$H" "$(mkjson Bash command 'ALLOW_DISCARD=1 git reset --hard' "$R")")"; eq "prefix override" "rc=0 " "$out"
out="$(feed "$H" "$(mkjson Bash command 'git reset --hard' "$R")" ALLOW_DISCARD=1)"; eq "environment override" "rc=0 " "$out"
out="$(feed "$H" "$(mkjson Bash command 'ALLOW_DISCARD=0 git checkout -- a.txt' "$R")")"; has "ALLOW_DISCARD=0 does not override" "rc=2" "$out"
out="$(feed "$H" "$(mkjson Bash command 'ALLOW_DISCARD=1 git status; git checkout -- a.txt' "$R")")"; has "a prefix on another command does not override" "rc=2" "$out"
# fail open
for stdin in 'not json' '' '{}' "$(mkjson Read command 'git reset --hard' "$R")" "$(mkjson Bash command "git checkout -- 'a.txt" "$R")" "$(mkjson Bash command 'git checkout -- a.txt' "$TMP/does-not-exist")"; do
  out="$(feed "$H" "$stdin")"; eq "fail open on [${stdin:0:40}]" "rc=0 " "$out"
done
# the message lists at most 20 paths
M="$TMP/many"; G init -q -b main "$M"; for i in $(seq -w 0 24); do echo 1 > "$M/f$i.txt"; done
G -C "$M" add .; G -C "$M" commit -q -m init; for i in $(seq -w 0 24); do echo 22 > "$M/f$i.txt"; done
out="$(feed "$H" "$(mkjson Bash command 'git reset --hard' "$M")")"; has "lists 20, counts the rest" "(+5 more)" "$out"
case "$out" in *f24.txt*) bad "the 25th path was listed" ;; *) ok ;; esac
finish hook-discard-guard
