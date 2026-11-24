#!/usr/bin/env bash
# Tests for scripts/ctx-fill.py: per-window marks, --window, Haiku detection. Run: bash tests/ctx-fill.test.sh
# Needs python3. Transcripts are synthetic .jsonl files passed by path; nothing under ~/.claude is read.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CF="$ROOT/scripts/ctx-fill.py"
command -v python3 >/dev/null 2>&1 || { echo "ctx-fill: skipped (no python3)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
has() {  # <label> <want substring> <got>
  case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac
}
hasnt() {  # <label> <unwanted substring> <got>
  case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac
}
transcript() {  # <file> <model> <context tokens> — one assistant turn whose prompt was exactly N tokens
  printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' "$2" "$3" > "$1"
}
cf() { python3 "$CF" "$@" 2>&1; }
T="$TMP/t.jsonl"

# 1. 1M window: 350K / 400K, whatever the model string says.
transcript "$T" claude-opus-5 109326
out="$(cf "$T" --window 1m)"
has "1m marks" "marks     prompt 350,000 | handover 400,000  (1,000,000 window)" "$out"
has "1m verdict" "OK -- 240,674 to the prompt mark" "$out"
has "current is the measured prompt" "current   109,326" "$out"

# 2. 200K window: 120K / 150K. Both spellings of the flag, and the old numeric form.
for w in 200k 200K 200000 200,000; do
  out="$(cf "$T" --window "$w")"
  has "--window $w marks" "marks     prompt 120,000 | handover 150,000  (200,000 window)" "$out"
done
has "--window=200k form" "(200,000 window)" "$(cf "$T" --window=200k)"
transcript "$T" claude-sonnet-5-5 130000
has "200K at 130K -> prompt mark" "AT PROMPT MARK" "$(cf "$T" --window 200k)"
transcript "$T" claude-sonnet-5-5 151000
has "200K at 151K -> past handover" "PAST HANDOVER" "$(cf "$T" --window 200k)"
has "same 151K on a 1M window is fine" "OK -- " "$(cf "$T" --window 1m)"

# 3. A window in between scales: 60% / 75% of it, capped at the 1M marks.
transcript "$T" claude-opus-5 1000
has "300K window marks" "prompt 180,000 | handover 225,000  (300,000 window)" "$(cf "$T" --window 300000)"
has "2M window is capped at the 1M marks" "prompt 350,000 | handover 400,000" "$(cf "$T" --window 2000000)"

# 4. Unknown window: the transcript's model string cannot say, so BOTH marks are printed and the
#    verdict is conditional. Opus and Sonnet come in 200K and 1M and record the same string.
transcript "$T" claude-opus-5 140000
out="$(cf "$T")"
has "unknown window says so" "UNKNOWN" "$out"
has "unknown prints the 1M marks" "marks     IF 1M:   prompt 350,000 | handover 400,000" "$out"
has "unknown prints the 200K marks" "marks     IF 200K: prompt 120,000 | handover 150,000" "$out"
has "unknown + past the 200K prompt mark is a warning, not OK" "AT the 200K prompt mark" "$out"
hasnt "unknown never claims OK past the small mark" "verdict   OK" "$out"
transcript "$T" claude-opus-5 100000
has "unknown + under the small mark is OK on either" "OK on either window" "$(cf "$T")"

# 5. Haiku has no 1M variant, so a haiku model string PROVES a 200K window (it can only lower it).
transcript "$T" claude-haiku-4-5-20251001 130000
out="$(cf "$T")"
has "haiku -> 200K window" "200,000  (model is Haiku" "$out"
has "haiku uses the 200K marks" "prompt 120,000 | handover 150,000  (200,000 window)" "$out"
has "haiku at 130K -> prompt mark" "AT PROMPT MARK" "$out"
#    ...but an explicit --window wins over the model name.
has "--window beats the haiku rule" "(1,000,000 window)" "$(cf "$T" --window 1m)"

# 6. A transcript that already reached more than 200K PROVES a large window (a lower bound).
transcript "$T" claude-opus-5 250000
out="$(cf "$T")"
has "peak > 200K proves a large window" "PROVEN" "$out"
has "proven window uses the 1M marks" "prompt 350,000 | handover 400,000  (1,000,000 window)" "$out"

# 7. A bad --window is refused, not guessed.
out="$(cf "$T" --window huge; echo "rc=$?")"
has "bad --window refused" "--window must be" "$out"
has "bad --window rc != 0" "rc=1" "$out"

# 8. A session that hit its wall is never told it is OK, whatever the marks.
{ transcript "$T" claude-opus-5 90000; printf '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Prompt is too long"}]}}\n' >> "$T"; }
out="$(cf "$T" --window 200k)"
has "wall hit" "WALL ALREADY HIT" "$out"

echo "ctx-fill: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
