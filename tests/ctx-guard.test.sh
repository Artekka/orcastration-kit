#!/usr/bin/env bash
# Tests for hooks/ctx-guard.py: opt-in gating, marks per window, rate limit, reset after /clear, robustness,
# and its registration in hooks/hooks.json. Run: bash tests/ctx-guard.test.sh   (needs bash, git, python3)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; G="$ROOT/hooks/ctx-guard.py"
command -v python3 >/dev/null 2>&1 || { echo "ctx-guard: skipped (no python3)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export KIT_STATE_DIR="$TMP/state" KIT_HUD_DIR="$TMP/hud"   # the status bar's records: none unless a test writes one
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
empty() { [ -z "$2" ] && ok || bad "$1: want no output, got: $2"; }

REPO="$TMP/repo"; git init -q -b main "$REPO"; mkdir -p "$REPO/docs/orchestration"
conf() { printf 'team:\n  seat: Orca\n%s\n' "$1" > "$REPO/docs/orchestration/ORCHESTRATION.md"; }
marker() { : > "$REPO/docs/orchestration/.kit-hooks"; }
# A transcript whose last assistant turn used <fill> tokens on <model>. Earlier lines (a user line, a smaller
# assistant turn) make sure the LAST usage block is the one read.
tx() {  # <file> <fill> [model]
  local m="${3:-claude-opus-x}"
  {
    echo '{"type":"user","message":{"content":"hi"}}'
    echo "{\"type\":\"assistant\",\"message\":{\"model\":\"$m\",\"usage\":{\"input_tokens\":5,\"cache_read_input_tokens\":10,\"cache_creation_input_tokens\":0}}}"
    echo "{\"type\":\"assistant\",\"message\":{\"model\":\"$m\",\"usage\":{\"input_tokens\":1000,\"cache_read_input_tokens\":$(( $2 - 1500 )),\"cache_creation_input_tokens\":500}}}"
  } > "$1"
}
run() {  # <transcript> <session id> [event] → hook stdout
  printf '{"transcript_path":"%s","session_id":"%s","hook_event_name":"%s","cwd":"%s"}' "$1" "$2" "${3:-PostToolUse}" "$REPO" \
    | python3 "$G"
}
T="$TMP/t.jsonl"

# --- opt-in gating
tx "$T" 380000
empty "no marker, no config: silent" "$(run "$T" g1)"
conf "  ctx_guard: on"; empty "config on but no .kit-hooks marker: silent" "$(run "$T" g2)"
marker; conf "  ctx_guard: off"; empty "marker + ctx_guard: off: silent" "$(run "$T" g3)"
conf "  git_guard: on"; empty "marker, key absent: silent (default off)" "$(run "$T" g4)"
# each gating check has its own session id: a shared one would let the rate limit silence a check
conf "  ctx_guard: on"; out="$(run "$T" g5)"
has "on + 380K (1M): report line" "crossed the 350K self-report mark" "$out"
has "output is a hook JSON with additionalContext" '"additionalContext"' "$out"
has "hookEventName echoes the event" '"hookEventName": "PostToolUse"' "$out"
# from a worktree: the marker and config are read from the MAIN checkout
git -C "$REPO" commit -q --allow-empty -m init; git -C "$REPO" worktree add -q "$TMP/wt" -b wt
out="$(printf '{"transcript_path":"%s","session_id":"wt1","hook_event_name":"PostToolUse","cwd":"%s"}' "$T" "$TMP/wt" | python3 "$G")"
has "a worktree session reads the main checkout's config" "self-report mark" "$out"

# --- marks on a 1M window
tx "$T" 299000; empty "1M: 299K is below the warn mark" "$(run "$T" m1)"
tx "$T" 310000; has "1M: 310K warns" "approaching the 350K self-report mark" "$(run "$T" m2)"
tx "$T" 405000; has "1M: 405K is past the handover mark" "PAST the 400K handover mark" "$(run "$T" m3)"

# --- marks on a 200K window: Haiku in the transcript, or context_window: 200k in the config
tx "$T" 125000 claude-haiku-x; has "haiku: 125K crossed the 120K report mark" "crossed the 120K self-report mark" "$(run "$T" h1)"
tx "$T" 155000 claude-haiku-x; has "haiku: 155K past the 150K handover" "PAST the 150K handover mark" "$(run "$T" h2)"
tx "$T" 99000 claude-haiku-x; empty "haiku: 99K below the 100K warn" "$(run "$T" h3)"
tx "$T" 125000; empty "opus at 125K on the default 1M window: silent" "$(run "$T" h4)"
conf "  ctx_guard: on
  context_window: 200k"
has "context_window: 200k makes opus at 125K report" "crossed the 120K self-report mark" "$(run "$T" h5)"
conf "  ctx_guard: on"

# --- the window Claude Code itself reports (the status bar's record of the session) beats the team block and the
#     model name, both ways; a record with no token reading yet is the status bar's default, not a measurement
hud() {  # <session id> <window> <tokens>
  mkdir -p "$KIT_HUD_DIR/sessions"
  printf '{"id":"%s","name":"Mars","model":"opus","tokens":%s,"window":%s,"at":1}' "$1" "$3" "$2" > "$KIT_HUD_DIR/sessions/$1.json"
}
conf "  ctx_guard: on
  context_window: 200k"
tx "$T" 125000; hud w1 1000000 125000
empty "measured 1M window inside a 200k team block: 125K is silent" "$(run "$T" w1)"
tx "$T" 310000; out="$(run "$T" w1)"
has "measured 1M window inside a 200k team block: warns at the 1M marks" "approaching the 350K self-report mark" "$out"
has "the line names where the window came from" "Claude Code's own figure" "$out"
conf "  ctx_guard: on"
tx "$T" 125000; hud w2 200000 125000
has "measured 200K window inside a 1m team block: reports at 120K" "crossed the 120K self-report mark" "$(run "$T" w2)"
tx "$T" 125000 claude-haiku-x; hud w3 1000000 125000
empty "measured 1M window beats the Haiku rule" "$(run "$T" w3)"
tx "$T" 125000 claude-haiku-x; hud w4 1000000 0
has "a record with no token reading is not a measurement: the Haiku rule stands" "crossed the 120K self-report mark" "$(run "$T" w4)"
tx "$T" 310000; printf 'not json' > "$KIT_HUD_DIR/sessions/w5.json"
has "a broken record falls back to the team block" "the team block's context_window" "$(run "$T" w5)"
rm -rf "$KIT_HUD_DIR"

# --- rate limit: once per STEP (15K on 1M) of growth, a newly crossed mark always speaks, prompts always speak
tx "$T" 310000; has "rate: first call speaks" "CONTEXT GUARD" "$(run "$T" r1)"
tx "$T" 315000; empty "rate: +5K says nothing" "$(run "$T" r1)"
tx "$T" 326000; has "rate: +16K speaks again" "CONTEXT GUARD" "$(run "$T" r1)"
tx "$T" 340000; empty "rate: +14K says nothing" "$(run "$T" r1)"
tx "$T" 351000; has "rate: crossing 350K speaks even within one step (+11K)" "self-report mark" "$(run "$T" r1)"
tx "$T" 352000; has "rate: a prompt always speaks" "CONTEXT GUARD" "$(run "$T" r1 UserPromptSubmit)"
has "rate: the prompt event is echoed" '"hookEventName": "UserPromptSubmit"' "$(run "$T" r1 UserPromptSubmit)"
# --- after /clear the fill drops: the state resets, and the next climb speaks at the warn mark again
tx "$T" 50000; empty "clear: 50K silent" "$(run "$T" r1)"
tx "$T" 305000; has "clear: the next climb past warn speaks" "approaching" "$(run "$T" r1)"

# --- robustness: never an error, never output
empty "garbage stdin: silent" "$(echo 'not json' | python3 "$G" 2>&1)"
empty "missing transcript: silent" "$(run "$TMP/nope.jsonl" x1 2>&1)"
echo '{"type":"assistant","message":{}}' > "$TMP/nousage.jsonl"; empty "no usage: silent" "$(run "$TMP/nousage.jsonl" x2 2>&1)"
printf '{"transcript_path":"%s","session_id":"../../escape","hook_event_name":"PostToolUse","cwd":"%s"}' "$T" "$REPO" | python3 "$G" >/dev/null 2>&1
[ ! -e "$TMP/escape.last" ] && ok || bad "a session id with ../ wrote outside the state dir"
echo 'x' | python3 "$G" >/dev/null 2>&1; [ $? -eq 0 ] && ok || bad "exit code is not 0 on bad input"

# --- registration: both events, through python3 with a no-python fallback, never failing the session
H="$ROOT/hooks/hooks.json"
reg="$(python3 -c '
import json,sys
h=json.load(open(sys.argv[1]))["hooks"]
for ev in ("PostToolUse","UserPromptSubmit"):
    cmds=[x["command"] for e in h.get(ev,[]) for x in e["hooks"]]
    print(ev, any("ctx-guard.py" in c and c.rstrip().endswith("|| true") for c in cmds))
' "$H")"
has "hooks.json: PostToolUse runs ctx-guard" "PostToolUse True" "$reg"
has "hooks.json: UserPromptSubmit runs ctx-guard" "UserPromptSubmit True" "$reg"

echo "ctx-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
