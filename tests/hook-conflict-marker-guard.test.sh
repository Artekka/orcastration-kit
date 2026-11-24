#!/usr/bin/env bash
# Tests for hooks/conflict-marker-guard.py: a commit-making git command is refused while the staged content, or what an earlier command of
# the same chain stages, holds a conflict marker at column 0. Run: bash tests/hook-conflict-marker-guard.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
. "$(dirname "$0")/lib-hook-test.sh"
command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || { echo "hook-conflict-marker-guard: SKIP (no python3 or git)"; exit 0; }
H="$ROOT/hooks/conflict-marker-guard.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G() { git -c user.email=t@example.test -c user.name=T -c core.hooksPath=/dev/null "$@"; }
S="<<<<<<<"; M="======="; E=">>>>>>>"   # built here so this file holds no marker line at column 0
new() { rm -rf "$TMP/r"; G init -q -b main "$TMP/r"; mkdir -p "$TMP/r/d"; echo base > "$TMP/r/u.txt"; echo base > "$TMP/r/d/m.txt"; G -C "$TMP/r" add .; G -C "$TMP/r" commit -q -m init; }
mark() { printf 'one\n%s HEAD\nmine\n%s\ntheirs\n%s topic\n' "$S" "$M" "$E" > "$TMP/r/$1"; }
run() { feed "$H" "$(mkjson Bash command "$1" "$TMP/r")" "${@:2}"; }
new; mark u.txt; G -C "$TMP/r" add u.txt
for c in 'git commit -m x' 'git commit --amend --no-edit' 'git cherry-pick --continue' 'git rebase --continue' 'git merge --continue' 'git am --continue' 'git revert --continue' 'git am --resolved' 'git am -r' 'git status && git commit -m x' 'cd . && git -C . commit -m x'; do
  out="$(run "$c")"; has "refuses staged markers: $c" "rc=2" "$out"; has "names file:line: $c" "u.txt:2" "$out"
done
for c in 'git status' 'git add u.txt' 'git diff' 'git rebase -r main' 'git rebase --rebase-merges main' 'git cherry-pick -r abc' 'git merge -r topic' 'git push'; do eq "not judged: $c" "rc=0 " "$(run "$c")"; done
eq "ALLOW_CONFLICT_MARKERS=1 prefix" "rc=0 " "$(run 'ALLOW_CONFLICT_MARKERS=1 git commit -m x')"
eq "ALLOW_CONFLICT_MARKERS=1 environment" "rc=0 " "$(run 'git commit -m x' ALLOW_CONFLICT_MARKERS=1)"
# what an EARLIER command of the chain stages (nothing is staged yet when the hook runs)
new; mark u.txt; mark d/m.txt
for c in 'git add -u && git commit -m x' 'git add -A && git cherry-pick --continue' 'git add --all && git rebase --continue' 'git add . && git merge --continue' 'git add u.txt && git commit -m x' 'git add d && git commit -m x' 'git commit -a -m x' 'git commit -am x'; do
  has "refuses a chained stage: $c" "rc=2" "$(run "$c")"
done
eq "an unstaged marker alone passes" "rc=0 " "$(run 'git commit -m x')"
eq "a path without a marker passes" "rc=0 " "$(run 'git add d/none.txt && git commit -m x')"
# only column-0 marker lines count; a lone ======= (a setext underline) is documentation
new; printf 'Title\n=======\nbody\n' > "$TMP/r/u.txt"; G -C "$TMP/r" add u.txt; eq "a lone ======= passes" "rc=0 " "$(run 'git commit -m x')"
printf '  %s HEAD\n  x\n  %s topic\nquote "%s" in text\n' "$S" "$E" "$S" > "$TMP/r/u.txt"; G -C "$TMP/r" add u.txt; eq "indented or quoted marker text passes" "rc=0 " "$(run 'git commit -m x')"
for stdin in 'not json' '' '{}' "$(mkjson Read command 'git commit -m x' "$TMP/r")" "$(mkjson Bash command "git commit -m 'x" "$TMP/r")"; do   # this guard says so on stderr when it fails open (deliberate)
  out="$(feed "$H" "$stdin")"; has "fail open on [${stdin:0:30}]" "rc=0" "$out"; case "$out" in *"rc=2"*) bad "refused: $stdin" ;; *) ok ;; esac
done
eq "a cwd that is not a repo fails open" "rc=0 " "$(feed "$H" "$(mkjson Bash command 'git commit -m x' "$TMP")")"
finish hook-conflict-marker-guard
