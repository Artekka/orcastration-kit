#!/usr/bin/env bash
# Pins for rules that live in skill/template text (no script to execute): the evidence dir, the question
# modes, permission asks as a command, the ToolSearch preload before ListAgents/SendMessage, the tested
# Claude Code version, and the troubleshooting rows for this release's mechanisms.
# Run: bash tests/docs-pins.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
pin() {  # <label> <file> <fixed string>
  grep -qF -- "$3" "$ROOT/$2" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: '$3' not in $2"; }
}
T=templates/ORCHESTRATION.md; O=skills/orchestrate/SKILL.md; G=docs/GETTING-STARTED.md
pin "evidence dir in the overlay" $T "evidence dir:   ~/.orcastration-kit/scratch/<YYYY>/<Month>/<row>/"
grep -n 'evidence dir:' "$ROOT/$T" | grep -q '/tmp' && { fail=$((fail+1)); echo "FAIL the evidence dir names /tmp"; } || pass=$((pass+1))
pin "evidence dir in the brief template" templates/briefs/_TEMPLATE.md "the evidence dir (ORCHESTRATION.md), never \`/tmp\`"
pin "questions key, default blocking" $T "questions:      blocking"
pin "question modes table" $O "| \`blocking\` (default) |"
pin "non-blocking keeps a HUMAN QUEUE" $O "\`HUMAN QUEUE\` line"
pin "permission asks are a command" $O "Permission requests are a command, not prose."
for f in skills/orient/SKILL.md $O skills/orient-brief/SKILL.md skills/assemble-train/SKILL.md; do pin "ToolSearch preload in $f" "$f" "select:ListAgents,SendMessage"; done
pin "ToolSearch preload in retro" skills/retro/SKILL.md "select:SendMessage"
pin "tested Claude Code version" $G "Tested on Claude Code 2.1.296."
for row in "recycle-sibling.sh\` exits 3" "prints \`NO BANNER\`" "Gates never start" "The hooks do nothing" "SendMessage / ListAgents is not available"; do pin "troubleshooting: $row" $G "$row"; done
pin "kit-init platform check" skills/kit-init/SKILL.md "**Platform check"
pin "max_sessions in the overlay" $T "max_sessions:     8"
# One way to run the kit (0.10.0): Team is the only mode. The start question's FIRST option is the team start; the
# practice (Solo) mode is gone and must not come back in the README, kit-init, the guide or the glossary.
K=skills/kit-init/SKILL.md; R=README.md
row="$(grep -F 'Start the team now?' "$ROOT/$K" | head -1)"
case "$row" in *"| **Seat + 2 siblings (Recommended)** ·"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL kit-init start question: first option is not '**Seat + 2 siblings (Recommended)**'";; esac
pin "kit-init writes both guards on, on every path (manual backend included)" $K "KEY=git_guard VAL=on setkey; KEY=ctx_guard VAL=on setkey"
pin "every start turns the guards on" $K "every start (seat + 1–9 siblings) → \`git_guard: on\` and \`ctx_guard: on\`"
# The README keeps its dated "What's new" history lines (v0.9.0, v0.5.0) as they were; they are the only exception.
RH="$(mktemp)"; grep -vE '^v0\.(9\.0|5\.0):' "$ROOT/$R" > "$RH"
for stale in "team mode" "team-mode" "(the default)" "Two sessions:" "Pick your size" "solo mode" "Practice mode" "practice (Solo)" "Solo (practice)" "Solo practice" "Solo** (start here)" "recommended first time" "recommended start" "Team** (Advanced)" "Not now" "The way to begin" "Start solo"; do
  for f in README.md $G docs/GLOSSARY.md HOW-IT-WORKS.md docs/how-it-works.html .claude-plugin/plugin.json $K $T; do
    src="$ROOT/$f"; [ "$f" = README.md ] && src="$RH"
    grep -qiF -- "$stale" "$src" && { fail=$((fail+1)); echo "FAIL removed wording '$stale' is back in $f"; } || pass=$((pass+1))
  done
done
rm -f "$RH"
# The README has no "choose a mode" step: no mode table and no second mode heading.
grep -qE '^## (Two modes|Practice mode)' "$ROOT/$R" && { fail=$((fail+1)); echo "FAIL README has a mode-choice heading again"; } || pass=$((pass+1))
# 0.17.0: the plugin id is orcastration-kit, one spelling everywhere it is the id (install, enabledPlugins key,
# /orcastration-kit:<skill>, the state folder). The 0.16 id may appear only where it is history or the upgrade path:
# CHANGELOG entries (not its title), the README "Upgrading from 0.16" section, the marketplace renames map, the
# recorded Station fixture, and code lines that carry "0.16" because they read the 0.16 folder or marker.
OLD="orch""estration-kit"
pin "plugin.json name is the new id" .claude-plugin/plugin.json '"name": "orcastration-kit"'
pin "README install command" README.md "claude plugin install orcastration-kit@artekka-kits"
pin "GETTING-STARTED install command" $G "claude plugin install orcastration-kit@artekka-kits"
pin "README command prefix" README.md "/orcastration-kit:kit-init"
pin "README upgrade block" README.md "## Upgrading from 0.16"
pin "README upgrade: the one install step" README.md "/plugin install orcastration-kit@artekka-kits"
pin "README upgrade: the old-Claude-Code fallback" README.md "claude plugin uninstall $OLD --scope project"
pin "CHANGELOG upgrade block" CHANGELOG.md "Upgrading from 0.16"
# kit-init only creates missing files, so launch scripts copied on 0.16 keep the old prefix: kit-init must offer the refresh
pin "kit-init detects 0.16 launch scripts" skills/kit-init/SKILL.md "grep -lF '/$OLD:' scripts/*.sh"
pin "kit-init refresh list" skills/kit-init/SKILL.md "(start-team.sh recycle-sibling.sh sibling-shell.sh lib-launch.sh lib-model-tag.sh lib-kit-home.sh;"
pin "README upgrade: re-run kit-init for the copied scripts" README.md "In each project adopted on 0.16, run \`/orcastration-kit:kit-init\` once more"
grep -qF "plugin id is \`$OLD\`" "$ROOT/README.md" && { fail=$((fail+1)); echo "FAIL the 0.16.3 two-spellings note is still in the README"; } || pass=$((pass+1))
# marketplace: entry name = plugin.json name, and the renames map sends the 0.16 id to it (Claude Code rewrites the keys)
rn="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1])); old=sys.argv[2]
names=[p['name'] for p in m['plugins']]
print('ok' if 'orcastration-kit' in names and old not in names and m.get('renames',{}).get(old)=='orcastration-kit' else 'bad %r %r'%(names,m.get('renames')))
" "$ROOT/.claude-plugin/marketplace.json" "$OLD")"
[ "$rn" = ok ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL marketplace entry or renames map: $rn"; }
# `claude plugin validate .` checks the renames chain; it runs only where the claude CLI is on PATH
if command -v claude >/dev/null 2>&1; then
  vout="$(cd "$ROOT" && timeout 60 claude plugin validate . 2>&1)" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL claude plugin validate .: $vout"; }
else
  echo "SKIP claude plugin validate: the claude CLI is not on PATH (the JSON-shape pin above still runs)"
fi
# the sweep: every other line naming the 0.16 id fails
stray="$(cd "$ROOT" && grep -rnIF --exclude-dir=.git --exclude-dir=target --exclude-dir=node_modules -- "$OLD" . | awk -v old="$OLD" '
  { split($0, a, ":"); f=a[1]; sub(/^\.\//, "", f); line=$0; sub(/^[^:]*:[^:]*:/, "", line) }
  f == "CHANGELOG.md" && line !~ /^# / { next }
  f == "station/crates/core/tests/fixtures/synthetic_session.jsonl" || f == "station/crates/core/tests/fixtures/README.md" || f == "station/crates/core/tests/fixtures_test.rs" { next }
  f == ".claude-plugin/marketplace.json" && line ~ /^ *"[a-z-]+": "orcastration-kit"/ { next }
  index(line, "0.16") { next }
  { sub(/^\.\//, ""); print }')"
up="$(awk '/^## Upgrading from 0\.16/{on=1;next} on && /^## /{on=0} on' "$ROOT/README.md")"
stray="$(printf '%s\n' "$stray" | while IFS= read -r l; do
  [ -z "$l" ] && continue
  case "$l" in README.md:*) t="${l#README.md:}"; t="${t#*:}"; printf '%s\n' "$up" | grep -qxF -- "$t" && continue;; esac
  printf '%s\n' "$l"; done)"
[ -z "$stray" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the 0.16 id outside history/upgrade lines ($(printf '%s\n' "$stray" | wc -l) lines):"; printf '%s\n' "$stray" | cut -c1-160 | head -20; }
# Version: plugin.json, marketplace.json and the newest CHANGELOG heading must agree (0.10.0 shipped as one number).
pv="$(grep -m1 '"version"' "$ROOT/.claude-plugin/plugin.json" | sed 's/.*"version": *"\([^"]*\)".*/\1/')"
# The orcastration-kit entry BY NAME: the status-hud entry (or any other) can never satisfy this pin.
mv="$(python3 -c "import json,sys; print(next((p.get('version','') for p in json.load(open(sys.argv[1]))['plugins'] if p['name']=='orcastration-kit'), ''))" "$ROOT/.claude-plugin/marketplace.json")"
cv="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' "$ROOT/CHANGELOG.md" | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
[ -n "$pv" ] && [ "$pv" = "$mv" ] && [ "$pv" = "$cv" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL version mismatch: plugin.json=$pv marketplace.json=$mv newest CHANGELOG heading=$cv"; }
# The bug-report placeholder and the first line under README "What's new" name the same version.
bv="$(grep -m1 -E 'placeholder: "[0-9]' "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml" | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
[ "$bv" = "$pv" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bug-report placeholder is '$bv', plugin.json is '$pv'"; }
rv="$(awk '/^## What.s new/{on=1;next} on && /^v[0-9]+\.[0-9]+\.[0-9]+/{sub(/^v/,"");sub(/:.*/,"");print;exit}' "$ROOT/README.md")"
[ "$rv" = "$pv" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL README What's new starts at '$rv', plugin.json is '$pv'"; }
# the orchestrate skill lists the seat's poll, and every script it names ships
for sc in pending-work.sh bottleneck-watch.sh main-checkout-sync.sh; do
  pin "orchestrate poll names $sc" $O "bash scripts/$sc"
  [ -f "$ROOT/scripts/$sc" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the poll names scripts/$sc but it does not ship"; }
done
echo "docs-pins: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
