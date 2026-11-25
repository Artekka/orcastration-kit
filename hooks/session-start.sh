#!/usr/bin/env bash
# SessionStart hook (orcastration-kit). Fires on fresh sessions only (matcher startup|clear;
# resume/compact re-entries are skipped by hooks.json).
#
# NO-OP (exit 0, no output) unless the session's repo carries the opt-in marker
# docs/orchestration/.kit-hooks (written by kit-init). A board alone is NOT enough: a repo can run
# its own orchestration workflow, and a user-scope install must never nag a project that didn't opt in.
# Deliberately no set -e: a hook must never fail a session start.

input="$(cat 2>/dev/null || true)"
dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$dir" ]; then
  dir="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "$dir" ] || dir="$PWD"
[ -d "$dir" ] || exit 0
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
[ -f "$top/docs/orchestration/.kit-hooks" ] || exit 0

msg="This repo uses the orcastration-kit multi-session workflow. Before any other work, run /orcastration-kit:orient. Then check the top of docs/orchestration/AGENT_BOARD.md for an ORCHESTRATOR ACTIVE banner: if one names ANOTHER session as the seat, end orientation by sending that seat a READY signal (SendMessage) and wait for its assignment instead of asking the user for work; route any question or approval to the seat. If you were launched as the seat (/orcastration-kit:orchestrate), take or resume the seat per that skill."
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
exit 0
