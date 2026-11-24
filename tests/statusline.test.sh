#!/usr/bin/env bash
# Tests for scripts/statusline-ctx.sh. Run: bash tests/statusline.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SL="$ROOT/scripts/statusline-ctx.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
transcript() {  # <file> <input> <cache_read> <cache_creation>  — older turn first, then the measured one
  {
    echo '{"type":"user","message":{"role":"user","content":"hi \"type\":\"assistant\" \"usage\""}}'
    echo '{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"cache_read_input_tokens":999999,"cache_creation_input_tokens":0,"output_tokens":5}}}'
    printf '{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"y"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":7,"cache_creation":{"ephemeral_5m_input_tokens":0}}}}\n' "$2" "$4" "$3"
    echo '{"type":"system","subtype":"x"}'
  } > "$1"
}
check() {  # <label> <want substring> <stdin json> [env...]
  local label="$1" want="$2" in="$3"; shift 3
  local got; got="$(printf '%s' "$in" | env NO_COLOR=1 "$@" bash "$SL")"
  case "$got" in *"$want"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $label: want '$want' got '$got'" ;; esac
}
T="$TMP/t.jsonl"
transcript "$T" 2000 200000 10000
check "below prompt (sums 3 fields, last turn only)" "ctx 212K · prompt 350K · handover 400K" "{\"transcript_path\":\"$T\"}"
transcript "$T" 1000 355000 4000
check "at prompt mark" "ctx 360K ▲ self-report now · handover 400K" "{\"transcript_path\":\"$T\"}"
transcript "$T" 0 401000 0
check "past handover" "ctx 401K ■ HAND OVER" "{\"transcript_path\":\"$T\"}"
transcript "$T" 0 130000 0
check "200K window from input -> 120K/150K marks" "ctx 130K ▲ self-report now · handover 150K" "{\"transcript_path\":\"$T\",\"context_window\":{\"context_window_size\":200000}}"
transcript "$T" 0 151000 0
check "200K window past its handover" "ctx 151K ■ HAND OVER" "{\"transcript_path\":\"$T\",\"context_window\":{\"context_window_size\":200000}}"
transcript "$T" 0 119000 0
check "200K window below its prompt mark" "ctx 119K · prompt 120K · handover 150K" "{\"transcript_path\":\"$T\",\"context_window\":{\"context_window_size\":200000}}"
transcript "$T" 0 150000 0
check "CTX_WINDOW env wins" "ctx 150K · prompt 350K" "{\"transcript_path\":\"$T\",\"context_window\":{\"context_window_size\":200000}}" CTX_WINDOW=1000000
check "fallback to current_usage in input" "ctx 42K" '{"transcript_path":"/nonexistent","context_window":{"current_usage":{"input_tokens":2000,"cache_read_input_tokens":40000,"cache_creation_input_tokens":0}}}'
out="$(printf '{}' | bash "$SL"; echo "rc=$?")"
[ "$out" = "rc=0" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nothing to measure: want silent rc=0, got '$out'"; }
echo "statusline: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
