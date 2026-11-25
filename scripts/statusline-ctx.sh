#!/usr/bin/env bash
# Claude Code statusline (orcastration-kit, optional): the session's REAL context fill against
# the kit's marks — self-report at the PROMPT mark, hand the terminal over by the HANDOVER mark.
#
#   ctx 212K · prompt 350K · handover 400K          (green: fine)
#   ctx 361K ▲ self-report now · handover 400K       (yellow)
#   ctx 405K ■ HAND OVER — retro, then recycle       (red)
#
# Same measure as scripts/ctx-fill.py: input + cache_read + cache_creation tokens off the LAST
# assistant turn's `usage` block in the transcript (never bytes ÷ 4).
# Marks: window >= 500K or unknown -> 350K / 400K; smaller window -> 60% / 75% of it (200K -> 120K / 150K,
# the same marks as scripts/ctx-fill.py: a 200K-window seat died at 175,725 with no handover).
# Window, first found: CTX_WINDOW env > `context_window_size` in the statusline input > unknown.
#
# Enable — add to .claude/settings.json (project) or ~/.claude/settings.json (every repo):
#   "statusLine": { "type": "command", "command": "bash scripts/statusline-ctx.sh" }
# Already have a statusline? Pipe the same stdin to both and join the outputs.
# Env: CTX_WINDOW=200000 to state your window; NO_COLOR=1 for plain text.
# Dependencies: bash, grep, sed, tail. Prints nothing (exit 0) when there is nothing to measure.

input="$(cat 2>/dev/null || true)"

num() {  # <key> <text> -> first integer value of "key":N
  printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" 2>/dev/null | head -n1 | grep -o '[0-9]*$'
}
fill_of() {  # <text containing a usage block> -> summed context tokens
  local a b c
  a="$(num input_tokens "$1")"; b="$(num cache_read_input_tokens "$1")"; c="$(num cache_creation_input_tokens "$1")"
  printf '%s' $(( ${a:-0} + ${b:-0} + ${c:-0} ))
}

tp="$(printf '%s' "$input" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
  | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' -e 's#\\/#/#g')"
cur=0
if [ -n "$tp" ] && [ -f "$tp" ]; then
  line="$(tail -n 400 "$tp" 2>/dev/null | grep '"type":"assistant"' | grep '"usage"' | tail -n1)"
  [ -n "$line" ] && cur="$(fill_of "$line")"
fi
if [ "$cur" -eq 0 ]; then   # fallback: a usage block in the statusline input itself, if the harness sends one
  cu="$(printf '%s' "$input" | grep -o '"current_usage"[[:space:]]*:[[:space:]]*{[^}]*}' | head -n1)"
  [ -n "$cu" ] && cur="$(fill_of "$cu")"
fi
[ "$cur" -gt 0 ] 2>/dev/null || exit 0

win="${CTX_WINDOW:-}"
case "$win" in ''|*[!0-9]*) win="$(num context_window_size "$input")" ;; esac
prompt=350000; handover=400000
if [ -n "$win" ] && [ "$win" -gt 0 ] && [ "$win" -lt 500000 ]; then
  prompt=$(( win * 60 / 100 )); handover=$(( win * 75 / 100 ))
fi

k() { printf '%sK' $(( ($1 + 500) / 1000 )); }
if [ -n "${NO_COLOR:-}" ]; then g=""; y=""; r=""; z=""; else g=$'\033[32m'; y=$'\033[33m'; r=$'\033[31m'; z=$'\033[0m'; fi
if [ "$cur" -ge "$handover" ]; then
  printf '%sctx %s ■ HAND OVER — retro, then recycle%s\n' "$r" "$(k "$cur")" "$z"
elif [ "$cur" -ge "$prompt" ]; then
  printf '%sctx %s ▲ self-report now · handover %s%s\n' "$y" "$(k "$cur")" "$(k "$handover")" "$z"
else
  printf '%sctx %s%s · prompt %s · handover %s\n' "$g" "$(k "$cur")" "$z" "$(k "$prompt")" "$(k "$handover")"
fi
exit 0
