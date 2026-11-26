#!/usr/bin/env bash
# What `/orcastration-kit:orient-brief <ROW>` injects into the skill text before the session reads it:
# the row's brief and the board's live ORCHESTRATOR ACTIVE section. ALWAYS exits 0, because the skill
# loader aborts the whole skill on a non-zero exit; every failure prints a NO BRIEF / NO BANNER /
# FETCH FAILED line the session can act on instead.
# Accepted residual: the loader pastes the row into the injected command as text, so a row id holding a
# single quote could break out of its quoting before this script runs. Only the seat mints row ids, and
# the skill's `allowed-tools` makes any extra subcommand fail the permission check.
# Usage (by the skill): bash brief.sh <ROW>     Env: BRIEF_BRANCH overrides the default branch.
row="${1:-}"
if ! [[ "$row" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "NO BRIEF: bad or missing row id (usage: /orcastration-kit:orient-brief <ROW>); tell the seat and fall back to /orcastration-kit:orient"
  exit 0
fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "NO BRIEF: not inside a git repository; start the session in the project and run it again"
  exit 0
fi

# Origin first: a plain cat of this checkout misses a brief the seat pushed after this checkout last rebased.
git fetch -q origin 2>/dev/null || { sleep 2; git fetch -q origin 2>/dev/null; } || echo "FETCH FAILED: origin may be stale"
branch="${BRIEF_BRANCH:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')}"
branch="${branch:-main}"

echo "=== BRIEF ($row) ==="
git show "origin/$branch:docs/orchestration/briefs/$row.md" 2>/dev/null \
  || cat "docs/orchestration/briefs/$row.md" 2>/dev/null \
  || echo "NO BRIEF for $row (not on origin/$branch, not in this checkout): tell the seat and fall back to /orcastration-kit:orient"

echo
echo "=== BOARD BANNER ==="
# From the live ORCHESTRATOR ACTIVE heading (never a superseded one) to the next heading of any depth (`## `,
# `### ` …), and at most 6000 characters: a board that keeps old rows or older seats' handover notes under
# the banner would otherwise hand every builder that history as if it were current. Regex-only awk:
# no dollar-digit tokens anywhere near a skill.
board="$(git show "origin/$branch:docs/orchestration/AGENT_BOARD.md" 2>/dev/null || cat docs/orchestration/AGENT_BOARD.md 2>/dev/null)"
banner="$(printf '%s\n' "$board" \
  | awk '/^##+ /{ if (on) exit; if (/ORCHESTRATOR ACTIVE/ && !/[Ss][Uu][Pp][Ee][Rr][Ss][Ee][Dd][Ee][Dd]/) on=1 } on { n += length + 1; if (n > 6000) { print "[banner cut at 6000 characters; the rest is on the board]"; exit } print }' \
  | head -60)"
if [ -n "$banner" ]; then
  printf '%s\n' "$banner"
else
  echo "NO BANNER: no live ORCHESTRATOR ACTIVE section on the board, so there is no seat. Ask the human."
fi
exit 0
