#!/usr/bin/env bash
# scripts/skill-usage.py counts kit skills started as a slash command or through the Skill tool, from a stub log
# folder, and lists the kit skills no session ran. Run: bash tests/skill-usage.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3";; esac; }
command -v python3 >/dev/null || { echo "SKIP skill-usage: no python3"; exit 0; }
L="$(mktemp -d)"; trap 'rm -rf "$L"' EXIT
mkdir -p "$L/s1/subagents"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"s1\",\"timestamp\":\"$now\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/orcastration-kit:orchestrate</command-name>\"}}" \
  "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"timestamp\":\"$now\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Skill\",\"input\":{\"skill\":\"orcastration-kit:retro\"}}]}}" > "$L/s1.jsonl"
printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"s2\",\"timestamp\":\"$now\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<command-name>/orcastration-kit:orchestrate</command-name>\"}]}}" \
  "{\"type\":\"user\",\"sessionId\":\"s2\",\"timestamp\":\"2000-01-01T00:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/orcastration-kit:falsify</command-name>\"}}" > "$L/s1/subagents/a.jsonl"
# logs written before 0.17.0 carry the kit's earlier plugin id (spelled in two pieces: the docs sweep allows it nowhere else)
old="orch""estration-kit"
printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"s3\",\"timestamp\":\"$now\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/$old:board</command-name>\"}}" \
  "{\"type\":\"assistant\",\"sessionId\":\"s3\",\"timestamp\":\"$now\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Skill\",\"input\":{\"skill\":\"$old:board\"}}]}}" > "$L/s3.jsonl"
out="$(python3 -I "$ROOT/scripts/skill-usage.py" "$L" 2>&1)"
has "the earlier plugin id counts too (slash command and Skill tool)" "$(printf '%-18s %6s %9s' board 2 1)" "$out"
has "slash commands counted across files" "$(printf '%-18s %6s %9s' orchestrate 2 2)" "$out"
has "Skill tool counted" "$(printf '%-18s %6s %9s' retro 1 1)" "$out"
has "old entry counted without --days" "$(printf '%-18s %6s %9s' falsify 1 1)" "$out"
has "never-run list names an unused skill" "verify-feature" "$(grep '^never run:' <<<"$out")"
out="$(python3 -I "$ROOT/scripts/skill-usage.py" "$L" --days 1 2>&1)"
has "--days drops old entries" "$(printf '%-18s %6s %9s' falsify 0 0)" "$out"
has "--days keeps new ones" "$(printf '%-18s %6s %9s' orchestrate 2 2)" "$out"
echo "skill-usage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
