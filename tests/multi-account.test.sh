#!/usr/bin/env bash
# Tests for the optional multi-account launch (docs/MULTI-ACCOUNT.md). Run: bash tests/multi-account.test.sh
# No real Claude session is started: LAUNCH_CMD_OVERRIDE stands in for `claude --name`, and a stand-in
# process carries CLAUDE_CONFIG_DIR exactly as a session started with `claudeN` would.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; RS="$ROOT/scripts/recycle-sibling.sh"; ST="$ROOT/scripts/start-team.sh"
TMP="$(mktemp -d)"; pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
has() {  # <label> <want substring> <got>
  case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac
}
hasnt() {  # <label> <unwanted substring> <got>
  case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac
}

# Two fake account dirs: one logged in (with a label), one never logged in.
A2="$TMP/acct2"; A3="$TMP/acct3"; mkdir -p "$A2" "$A3"
: > "$A2/.credentials.json"; echo "acct2 · test label" > "$A2/ACCOUNT"
export LAUNCH_CMD_OVERRIDE='bash -c sleep 30;: {name}'
run() { HOME="$TMP" bash "$RS" --dry-run --terminal manual --repo "$ROOT" "$@" 2>&1; }

# 1. No old session, no flag -> default account, no prefix.
out="$(run ZzNone)"
has "default account label" "(default account)" "$out"
hasnt "default account adds no prefix" "CLAUDE_CONFIG_DIR=" "$out"

# 2. Explicit --account 2 -> ~/.claude-acct2 (HOME points at TMP, so link the convention path).
ln -s "$A2" "$TMP/.claude-acct2"
out="$(run --account 2 ZzNone)"
has "--account 2 prefix" "CLAUDE_CONFIG_DIR=$TMP/.claude-acct2 " "$out"
has "--account 2 label from ACCOUNT file" "acct2 · test label" "$out"

# 3. Inherit: a running stand-in started under acct2 is relaunched on acct2 with no flag.
if [ -r /proc/self/environ ] || [ "$(uname -s)" = Darwin ]; then
  CLAUDE_CONFIG_DIR="$A2" bash -c 'sleep 30;:' ZzSib & pids="$pids $!"
  sleep 1
  out="$(run ZzSib)"
  has "inherits the old session's account" "CLAUDE_CONFIG_DIR=$A2 " "$out"
  out="$(run --account 1 ZzSib)"
  hasnt "--account 1 overrides inheritance" "CLAUDE_CONFIG_DIR=" "$out"
else
  echo "skip inherit tests: no /proc and not macOS"
fi

# 4. Refusals: a dir with no login, a missing dir, a dir with a space.
out="$(run --account "$A3" ZzNone; echo "rc=$?")"
has "no-login dir refused" "has no login" "$out"; has "no-login rc 64" "rc=64" "$out"
out="$(run --account 9 ZzNone; echo "rc=$?")"
has "missing dir refused" "does not exist" "$out"
mkdir -p "$TMP/has space"; : > "$TMP/has space/.credentials.json"
out="$(run --account "$TMP/has space" ZzNone; echo "rc=$?")"
has "space in dir refused" "must not contain spaces" "$out"

# 5. start-team puts the whole team on one account.
out="$(HOME="$TMP" bash "$ST" --dry-run --terminal manual --repo "$ROOT" --siblings 1 --account 2 2>&1)"
has "start-team --account prefixes the seat" "CLAUDE_CONFIG_DIR=$TMP/.claude-acct2 " "$out"

echo "multi-account: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
