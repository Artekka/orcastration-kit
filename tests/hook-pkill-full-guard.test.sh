#!/usr/bin/env bash
# Tests for hooks/pkill-full-guard.py: 50 refused forms, 62 allowed forms, the one-line message, fail-open. Run: bash tests/hook-pkill-full-guard.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
. "$(dirname "$0")/lib-hook-test.sh"
command -v python3 >/dev/null 2>&1 || { echo "hook-pkill-full-guard: SKIP (no python3)"; exit 0; }
H="$ROOT/hooks/pkill-full-guard.py"; C="$ROOT/tests/hook-cases"
drive "$H" "$C/pkill.refuse.jsonl" refuse --fix "kill <pid>"
drive "$H" "$C/pkill.allow.jsonl" allow
out="$(feed "$H" "$(mkjson Bash command 'pkill -f vitest')")"
has "refusal names the rule" "pkill-full-guard: REFUSED" "$out"; has "refusal names the safe form" "kill <pid>" "$out"; has "exit 2" "rc=2" "$out"
for stdin in 'not json' '' '{}' '{"tool_name":"Read","tool_input":{"command":"pkill -f x"}}' '{"tool_name":"Bash","tool_input":{}}' '{"tool_name":"Bash","tool_input":{"command":"pkill -f '"'"'x"}}'; do
  out="$(feed "$H" "$stdin")"; eq "fail open on [$stdin]" "rc=0 " "$out"
done
finish hook-pkill-full-guard
