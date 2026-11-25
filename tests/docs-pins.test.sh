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
# recorded Station fixture, kit-init's two upgrade lines (the copied-scripts note and step 4), and the lines tagged
# "the 0.16 folder" in lib-kit-home.sh and ctx-guard.py, where the id may appear only as the folder name (.<id>).
# A line that merely mentions "0.16" elsewhere is a stray.
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
pin "kit-refresh detects the 0.16 prefix and folder" scripts/kit-refresh.sh 'grep -qF -e "$OLD_PREFIX" -e "$OLD_FOLDER"'
pin "kit-init runs the refresh" skills/kit-init/SKILL.md 'bash "$K/scripts/kit-refresh.sh" --apply'
pin "kit-init refresh dry run first" skills/kit-init/SKILL.md 'bash "$K/scripts/kit-refresh.sh"`'
# kit-refresh's written limits (713b r4), one line each in the README and the CHANGELOG
for lim in \
  "kit-refresh limit: a bind mount at or above scripts/ is not seen (it compares paths only)." \
  "kit-refresh limit: do not edit scripts/ while it runs; an edit made between its check and its write is lost, and a folder or link put at a name between its check and its move is LEFT (a folder, or a link to one) or replaced (any other link)." \
  "kit-refresh limit: on a case-folding file system (macOS, Windows) it knows only the exact file names; rename a copy whose name differs in case first." \
  "kit-refresh limit: a read-only copy in a writable scripts/ is LEFT by the shell's \`-w\` test, which root always passes."; do
  pin "README: $lim" README.md "$lim"; pin "CHANGELOG: $lim" CHANGELOG.md "$lim"
done
# the written limit of the one-folder rule (713b r2), in the README and the CHANGELOG
LIMIT="one folder unless the 0.16 name's link is deleted while a 0.16 copy runs first, or HOME cannot hold links; kit-init's refresh closes it"
pin "README one-folder limit" README.md "$LIMIT"
pin "CHANGELOG one-folder limit" CHANGELOG.md "$LIMIT"
pin "CHANGELOG fresh-install link" CHANGELOG.md "a fresh install makes ~/.orcastration-kit and links the 0.16 name to it"
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
# the sweep: every other line naming the 0.16 id fails. stray_lines <tree root> prints each stray line as path:line:text,
# so the probes below can run it on a small temp tree (a stray line in a doc must turn it red).
stray_lines() {
  local root="$1" st up
  st="$(cd "$root" && grep -rnIF --exclude-dir=.git --exclude-dir=target --exclude-dir=node_modules -- "$OLD" . | awk -v old="$OLD" '
  { split($0, a, ":"); f=a[1]; sub(/^\.\//, "", f); line=$0; sub(/^[^:]*:[^:]*:/, "", line) }
  f == "CHANGELOG.md" && line !~ /^# / { next }
  f == "station/crates/core/tests/fixtures/synthetic_session.jsonl" || f == "station/crates/core/tests/fixtures/README.md" || f == "station/crates/core/tests/fixtures_test.rs" { next }
  f == ".claude-plugin/marketplace.json" && line ~ /^ *"[a-z-]+": "orcastration-kit"/ { next }
  f == "skills/kit-init/SKILL.md" && (line ~ /^   \*\*Scripts copied on 0\.16 / || line ~ /^4\. \*\*CLAUDE\.md section\*\* /) { next }
  (f == "scripts/lib-kit-home.sh" || f == "hooks/ctx-guard.py") && index(line, "the 0.16 folder") { rest = line; gsub("\\." old, "", rest); if (!index(rest, old)) next }
  { sub(/^\.\//, ""); print }')"
  up="$(awk '/^## Upgrading from 0\.16/{on=1;next} on && /^## /{on=0} on' "$root/README.md" 2>/dev/null)"
  printf '%s\n' "$st" | while IFS= read -r l; do
    [ -z "$l" ] && continue
    case "$l" in README.md:*) t="${l#README.md:}"; t="${t#*:}"; printf '%s\n' "$up" | grep -qxF -- "$t" && continue;; esac
    printf '%s\n' "$l"; done
}
stray="$(stray_lines "$ROOT")"
[ -z "$stray" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the 0.16 id outside history/upgrade lines ($(printf '%s\n' "$stray" | wc -l) lines):"; printf '%s\n' "$stray" | cut -c1-160 | head -20; }
# Probes (0.17.0 READ): the allowlist is the named places only. A line that merely mentions "0.16" is no pass.
PT="$(mktemp -d)"; trap 'rm -rf "$PT"' EXIT
PROBE="Run /$OLD:orient after 0.16."
probe_tree() {  # a temp tree holding the real copies of every file with allowed 0.16-id lines
  local f
  rm -rf "$PT/t"; mkdir -p "$PT/t"
  for f in README.md CHANGELOG.md .claude-plugin/marketplace.json skills/kit-init/SKILL.md scripts/lib-kit-home.sh hooks/ctx-guard.py docs/GETTING-STARTED.md; do
    mkdir -p "$PT/t/$(dirname "$f")"; cp "$ROOT/$f" "$PT/t/$f"
  done
}
probe_tree; out="$(stray_lines "$PT/t")"
[ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL probe control: the copied files alone are not clean: $(printf '%s' "$out" | head -3)"; }
for f in docs/GETTING-STARTED.md README.md skills/kit-init/SKILL.md scripts/lib-kit-home.sh hooks/ctx-guard.py CHANGELOG.md; do
  probe_tree
  case "$f" in CHANGELOG.md) printf '# %s\n' "$PROBE" >> "$PT/t/$f";; *) printf '%s\n' "$PROBE" >> "$PT/t/$f";; esac
  out="$(stray_lines "$PT/t")"
  case "$out" in *"$f:"*"$PROBE"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL probe: '$PROBE' appended to $f is not a stray line";; esac
done
# A line tagged "the 0.16 folder" may name the 0.16 id only as the folder (.<id>); a command on it is a stray (READ r1, LOW-2).
for f in scripts/lib-kit-home.sh hooks/ctx-guard.py; do
  probe_tree; TAGGED="# the 0.16 folder ~/.$OLD: run /$OLD:orient after it"
  printf '%s\n' "$TAGGED" >> "$PT/t/$f"; out="$(stray_lines "$PT/t")"
  case "$out" in *"$f:"*"/$OLD:orient"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL probe: a tagged line in $f carrying /$OLD:orient is not a stray line";; esac
done
# README: the renames map migrates USER settings only (Claude Code's marketplace schema: "migrates user settings to the
# new name"); project and local settings get the manual step. Never claim the CLI rewrites them.
pin "README upgrade: renames migrates user settings" README.md "migrates the \`enabledPlugins\` key in your user settings"
pin "README upgrade: project and local settings by hand" README.md "Project and local settings (\`.claude/settings.json\`, \`.claude/settings.local.json\`) may keep the old key"
grep -qF "user, project and local settings" "$ROOT/README.md" && { fail=$((fail+1)); echo "FAIL README still says the CLI rewrites user, project and local settings"; } || pass=$((pass+1))
# kit-init step 4 names BOTH 0.16 markers, the opening and the closing one
pin "kit-init: the 0.16 opening marker" skills/kit-init/SKILL.md "opening \`<!-- $OLD vX -->\`"
pin "kit-init: the 0.16 closing marker" skills/kit-init/SKILL.md "closing \`<!-- /$OLD -->\`"
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
