#!/usr/bin/env bash
# Tests for hooks/prettier-dir-guard.py: --write on a directory is refused, everything else passes, fail-open. Run: bash tests/hook-prettier-dir-guard.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
. "$(dirname "$0")/lib-hook-test.sh"
command -v python3 >/dev/null 2>&1 || { echo "hook-prettier-dir-guard: SKIP (no python3)"; exit 0; }
H="$ROOT/hooks/prettier-dir-guard.py"; C="$ROOT/tests/hook-cases"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src/deep" "$TMP/pkgs/a"; echo x > "$TMP/src/a.ts"; echo '{}' > "$TMP/b.json"   # the cases' directories and files
drive "$H" "$C/prettier.refuse.jsonl" refuse --cwd "$TMP" --fix "Name the files"
drive "$H" "$C/prettier.allow.jsonl" allow --cwd "$TMP"
for stdin in 'not json' '' '{}' '{"tool_name":"Read","tool_input":{"command":"prettier --write ."}}' '{"tool_name":"Bash","tool_input":{}}'; do
  out="$(feed "$H" "$stdin")"; eq "fail open on [$stdin]" "rc=0 " "$out"
done
finish hook-prettier-dir-guard
