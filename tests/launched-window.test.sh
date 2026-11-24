#!/usr/bin/env bash
# Tests for scripts/launched_window.py and its two callers (scripts/ctx-fill.py, hooks/ctx-guard.py): the context window a
# session was LAUNCHED with, read from its own `claude --model <tag>` argument (the environment block drops "[1m]").
# The process tree is a FAKE (LAUNCHED_WINDOW_PROC_ROOT); nothing real is read. Run: bash tests/launched-window.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LW="$ROOT/scripts/launched_window.py"; CF="$ROOT/scripts/ctx-fill.py"; GD="$ROOT/hooks/ctx-guard.py"
command -v python3 >/dev/null 2>&1 || { echo "launched-window: skipped (no python3)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
empty() { [ -z "$2" ] && ok || bad "$1: want no output, got: $2"; }

PR="$TMP/proc"; CFG="$TMP/cfg"; mkdir -p "$PR" "$CFG/sessions"
proc() {  # <pid> <ppid> <comm> <argv...>: one fake process
  local pid=$1 ppid=$2 comm=$3; shift 3
  mkdir -p "$PR/$pid"; printf '%s (%s) S %s 0 0 0\n' "$pid" "$comm" "$ppid" > "$PR/$pid/stat"
  : > "$PR/$pid/cmdline"; for a in "$@"; do printf '%s\0' "$a" >> "$PR/$pid/cmdline"; done
}
win() { python3 "$LW" --proc-root "$PR" --pid "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["window"])'; }

proc 100 1 bash bash
proc 101 100 claude claude --model "claude-opus-5-5[1m]"; proc 102 101 bash bash; proc 103 102 python3 python3 x.py
proc 110 1 bash bash
proc 111 110 claude claude --model claude-sonnet-5-5; proc 112 111 bash bash
proc 120 1 bash bash; proc 121 120 claude claude; proc 122 121 bash bash
proc 130 1 bash bash; proc 131 130 claude claude "--model=claude-haiku-5-5[1m]"; proc 132 131 bash bash
proc 140 1 bash bash; proc 141 140 claude claude --model claude-opus-5-5 --model "claude-opus-5-5[1m]"; proc 142 141 bash bash
proc 150 1 bash bash; proc 151 150 claude claude --model "claude-opus-5-5[1m]"; proc 152 151 claude claude; proc 153 152 bash bash
proc 160 1 bash bash; proc 161 160 bash bash
[ "$(win 103)" = 1m ] && ok || bad "a [1m] tag is 1m (got $(win 103))"
[ "$(win 112)" = 200k ] && ok || bad "any other explicit tag is 200k (got $(win 112))"
[ "$(win 122)" = None ] && ok || bad "no --model is unknown, not a guess (got $(win 122))"
[ "$(win 132)" = 200k ] && ok || bad "Haiku has no 1M variant: [1m] on it is still 200k, --model=tag form (got $(win 132))"
[ "$(win 142)" = 1m ] && ok || bad "the LAST --model wins (got $(win 142))"
[ "$(win 153)" = None ] && ok || bad "the FIRST claude ancestor answers even with no flag; a nested claude never reads its grandparent (got $(win 153))"
[ "$(win 161)" = None ] && ok || bad "no claude ancestor is unknown (got $(win 161))"

# ---- ctx-fill: the own session needs no --window; a peer transcript does ----
UUID=11111111-2222-4333-8444-555555555555; OTHER=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
printf '{"sessionId":"%s"}' "$UUID" > "$CFG/sessions/101.json"; printf '{"sessionId":"%s"}' "$UUID" > "$CFG/sessions/111.json"
export CLAUDE_CONFIG_DIR="$CFG"
tr() {  # <file> <model> <tokens>
  printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' "$2" "$3" > "$1"
}
T="$TMP/$UUID.jsonl"; tr "$T" claude-opus-5-5 109326; T2="$TMP/$OTHER.jsonl"; tr "$T2" claude-opus-5-5 109326
cfl() { env LAUNCHED_WINDOW_PROC_ROOT="$PR" LAUNCHED_WINDOW_START_PID="$1" LAUNCHED_WINDOW_CONFIG_DIR="$CFG" python3 "$CF" "${@:2}" 2>&1; }
out="$(cfl 103 "$T")"; has "own session, launched 1m: 1M marks with no --window" "(1,000,000 window)" "$out"; has "and it says where the window came from" "LAUNCHED" "$out"
out="$(cfl 112 "$T")"; has "own session, launched 200k: the 200K marks" "(200,000 window)" "$out"
out="$(cfl 103 "$T" --window 200k)"; has "an explicit --window wins over the launch" "(200,000 window)" "$out"
out="$(cfl 103 "$T2")"; hasnt "a peer's transcript never gets this session's window" "(1,000,000 window)" "$out"; hasnt "and it is not stamped 200K either" "(200,000 window)" "$out"
out="$(cfl 103 "$T" --line)"; has "--line works with no --window for the own session" "fill 109,326 / 1,000,000" "$out"
tr "$T" claude-opus-5-5 260000; out="$(cfl 112 "$T")"; has "a proven-large peak beats a launched 200k (a /model switch is not in argv)" "(1,000,000 window)" "$out"

# ---- ctx-guard: no context_window line -> the launched window decides; a declared line wins ----
REPO="$TMP/repo"; git init -q -b main "$REPO"; mkdir -p "$REPO/docs/orchestration"; : > "$REPO/docs/orchestration/.kit-hooks"
conf() { printf 'team:\n  seat: Orca\n  ctx_guard: on\n%s\n' "$1" > "$REPO/docs/orchestration/ORCHESTRATION.md"; }
tx() { printf '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$(( $2 - 1000 ))" > "$1"; }
guard() {  # <pid> <session id> <transcript>
  printf '{"transcript_path":"%s","session_id":"%s","hook_event_name":"PostToolUse","cwd":"%s"}' "$3" "$2" "$REPO" \
    | env KIT_STATE_DIR="${GSTATE:-$TMP/state}" LAUNCHED_WINDOW_PROC_ROOT="$PR" LAUNCHED_WINDOW_START_PID="$1" LAUNCHED_WINDOW_CONFIG_DIR="$CFG" python3 "$GD"
}
G1="$TMP/$UUID-g.jsonl"; tx "$G1" 130000
# Every guard case gets its OWN state dir: the guard rate-limits what it says (one line per ~15K of growth per session), so a case that
# shares the dir with the one before it can be silent because that one spoke, and a "silent" assertion would prove nothing.
gs() { GSTATE="$TMP/state-$1"; export GSTATE; }
conf ""; gs a; empty "no declared window, launched 1m, 130K: silent (the 1M marks)" "$(guard 103 "$UUID" "$G1")"
gs b; out="$(guard 112 "$UUID" "$G1")"; has "launched 200k, 130K: speaks (past the 120K mark)" "crossed" "$out"
conf "  context_window: 1m"; gs c; empty "a declared 1m beats a launched 200k (fresh state: the same call with no declaration speaks)" "$(guard 112 "$UUID" "$G1")"
conf ""; gs d; empty "a peer's session id is not this claude: the 1m default, silent" "$(guard 112 "$OTHER" "$G1")"
# the OWNING session id ($UUID, pid 112 sits under claude 111): the launched 200k is reached, and a fill above 200K must still
# not be judged on the 200K marks (it would say "PAST the 150K handover mark" there)
tx "$G1" 380000; conf ""; gs e; out="$(guard 112 "$UUID" "$G1")"
has "a fill above 200K is judged on the 1M marks even for a launched 200k" "350K" "$out"; hasnt "and never on the 200K marks" "150K" "$out"

echo "launched-window: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
