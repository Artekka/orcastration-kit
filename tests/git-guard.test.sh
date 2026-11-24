#!/usr/bin/env bash
# Tests for hooks/git-guard.sh. Run: bash tests/git-guard.test.sh
# Part 1 feeds sample commands through the tokenizer (GIT_GUARD_CHECK_ONLY=1) under every awk
# found (gawk, mawk, nawk, busybox). Part 2 checks the opt-in gating end to end in a temp repo.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/git-guard.sh"
pass=0; fail=0

json_cmd() {  # <command text> -> hook input JSON
  local esc
  esc="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | awk 'NR>1{printf "\\n"} {printf "%s", $0}')"
  printf '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"x"}}' "$esc"
}
expect() {  # <expected rule or "allow"> <command>
  local got
  got="$(json_cmd "$2" | GIT_GUARD_CHECK_ONLY=1 PATH="$AWKDIR:$PATH" bash "$HOOK")"
  [ -n "$got" ] || got=allow
  if [ "$got" = "$1" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL [%s] want %s got %s: %s\n' "$AWKNAME" "$1" "$got" "$2"; fi
}

cases() {
  # --- blocked ---
  expect stash       'git stash'
  expect stash       'git stash push -m wip'
  expect stash       'git stash pop'
  expect stash       'git stash -u'
  expect stash       'git stash apply stash@{0}'
  expect stash       'git -C ../other stash'
  expect stash       'cd repo && git stash && git pull'
  expect stash       '(cd repo; git stash)'
  expect stash       'FOO=1 git stash'
  expect stash       'bash -c "git stash"'
  expect stash       'echo hi | git stash'
  expect add-all     'git add -A'
  expect add-all     'git add --all'
  expect add-all     'git add .'
  expect add-all     'git add -- .'
  expect add-all     'git add :/'
  expect add-all     'git add -Av'
  expect add-all     'git add -u'
  expect add-all     'git add . && git commit -m "x"'
  expect add-all     "git status
git add -A"
  expect commit-all  'git commit -a'
  expect commit-all  'git commit --all -m x'
  expect commit-all  'git commit -am "fix things"'
  expect commit-all  'git commit -m "x" -a'
  expect commit-all  'git --no-pager commit -a -m x'
  expect pull-rebase 'git pull --rebase'
  expect pull-rebase 'git pull --rebase origin main'
  expect pull-rebase 'git pull -r'
  expect pull-rebase 'git pull --rebase=merges'
  expect pull-rebase 'git fetch && git pull --rebase'
  # --- allowed ---
  expect allow 'git stash list'
  expect allow 'git stash show -p stash@{0}'
  expect allow 'git stash --help list'          # first non-option word is list
  expect allow 'git add src/a.ts docs/b.md'
  expect allow 'git add -p src/a.ts'
  expect allow 'git add -u src/'
  expect allow 'git add -- -A'
  expect allow 'git commit -m "use git add -A carefully"'
  expect allow 'git commit -m "-a is bad"'
  expect allow 'git commit -F msg.txt'
  expect allow 'git commit --message -a'
  expect allow 'git pull'
  expect allow 'git pull --no-rebase'
  expect allow 'git pull --rebase=false'
  expect allow 'git pull -Xours'
  expect allow 'git fetch origin && git rebase origin/main'
  expect allow 'echo "never git stash"'
  expect allow "echo 'git add -A'"
  expect allow 'grep -n "git commit -a" README.md'
  expect allow 'ls # git stash'
  expect allow 'git log --oneline -5'
  expect allow 'npm test'
  expect allow 'git commit -m "$(cat <<'"'"'EOF'"'"'
Explain why "git add -A" and git stash are banned.
git commit -a too
EOF
)"'
  expect allow "cat > notes.md <<EOF
git stash
git add -A
EOF
git add notes.md"
  expect stash "cat > notes.md <<EOF
harmless
EOF
git stash"
}

AWKS=""
for a in gawk mawk nawk original-awk busybox; do command -v "$a" >/dev/null 2>&1 && AWKS="$AWKS $a"; done
[ -n "$AWKS" ] || AWKS=" awk"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for a in $AWKS; do
  AWKNAME="$a"; AWKDIR="$TMP/awk-$a"; mkdir -p "$AWKDIR"
  if [ "$a" = busybox ]; then printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$AWKDIR/awk"
  else printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$a")" > "$AWKDIR/awk"; fi
  chmod +x "$AWKDIR/awk"
  cases
done

# --- Part 2: opt-in gating, end to end ---
AWKNAME=e2e; AWKDIR="$TMP"
R="$TMP/repo"; mkdir -p "$R" && git -C "$R" init -q
e2e() {  # <want deny|allow> <label> <cwd>
  local out
  out="$(json_cmd 'git stash' | sed "s#^{#{\"cwd\":\"$3\",#" | CLAUDE_PROJECT_DIR=/nonexistent bash "$HOOK")"
  case "$out" in *'"permissionDecision":"deny"'*) out=deny ;; '') out=allow ;; *) out="bad-output:$out" ;; esac
  if [ "$out" = "$1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL [e2e] $2: want $1 got $out"; fi
}
e2e allow "no marker, no config" "$R"
mkdir -p "$R/docs/orchestration"; printf 'team:\n  git_guard:        on\n' > "$R/docs/orchestration/ORCHESTRATION.md"
e2e allow "config on but no .kit-hooks marker" "$R"
touch "$R/docs/orchestration/.kit-hooks"
e2e deny  "marker + git_guard: on" "$R"
mkdir -p "$R/sub/dir"; e2e deny "from a subdirectory" "$R/sub/dir"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TMP/wt" -b wt 2>/dev/null
e2e deny  "from a linked worktree (reads the main checkout's setting)" "$TMP/wt"
sed -i.bak 's/git_guard:.*/git_guard:        off/' "$R/docs/orchestration/ORCHESTRATION.md"
e2e allow "git_guard: off" "$R"
e2e allow "outside any repo" "$TMP"
out="$(printf '{"tool_input":{"command":"git stash"},"cwd":"%s"}' "$R" | bash "$HOOK"; echo "exit=$?")"
[ "$out" = "exit=0" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [e2e] off: want silent exit 0, got: $out"; }
sed -i.bak 's/git_guard:.*/git_guard: on/' "$R/docs/orchestration/ORCHESTRATION.md"
out="$(json_cmd 'git stash' | sed "s#^{#{\"cwd\":\"$R\",#" | bash "$HOOK")"
case "$out" in *'"permissionDecisionReason":"Blocked by orchestration-kit git guard. git stash is blocked'*) pass=$((pass+1)) ;;
  *) fail=$((fail+1)); echo "FAIL [e2e] deny reason text: $out" ;; esac

echo "git-guard: awks:$AWKS — $pass passed, $fail failed"
[ "$fail" -eq 0 ]
