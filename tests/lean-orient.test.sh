#!/usr/bin/env bash
# Tests for the lean `/orchestration-kit:orient --brief <ROW>` steps and the model-per-lane / recycle
# wording. The lean steps are COMMANDS in a table in skills/orient/SKILL.md; this
# suite EXTRACTS them from the skill file and runs them against a real fixture, so editing the skill to
# something broken turns it red (a copy of the command in this file would stay green).
# Run: bash tests/lean-orient.test.sh      (needs bash, git, awk, python3; no network)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orient/SKILL.md"; ORCH="$ROOT/skills/orchestrate/SKILL.md"
GS="$ROOT/docs/GETTING-STARTED.md"; BRIEF_T="$ROOT/templates/briefs/_TEMPLATE.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }

# The backticked commands of one row of the lean-mode table, `\|` unescaped back to `|`, one per line.
cmds() {  # <step number>
  python3 - "$SKILL" "$1" <<'PY'
import re, sys
skill, step = sys.argv[1], sys.argv[2]
for line in open(skill, encoding="utf8"):
    if line.startswith(f"| {step} |"):
        for m in re.finditer(r"`([^`]+)`", line):
            print(m.group(1).replace("\\|", "|"))
        break
PY
}
first_with() {  # <prefix> — first line of stdin that starts with the prefix
  local p="$1" l
  while IFS= read -r l; do case "$l" in "$p"*) printf '%s\n' "$l"; return 0 ;; esac; done; return 1
}

# ---- fixture: bare origin, a seat clone that pushes, and a builder clone that is STALE ----------
ORIGIN="$TMP/origin.git"; SEAT="$TMP/seat"; BUILDER="$TMP/builder"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$SEAT" 2>/dev/null
mkdir -p "$SEAT/docs/orchestration/briefs"
# A board shaped like a live one: an archive table, rules, `---` rulers, THEN the banner, THEN an
# older banner header that is superseded.
cat > "$SEAT/docs/orchestration/AGENT_BOARD.md" <<'BOARD'
# Agent Orchestration Board

## Archives
| archive | covers |
|---|---|
| a | b |

---

## Protocol
- rule one
---
## 🎛 ORCHESTRATOR ACTIVE — **era-9 · Zed `[abc123]`** · prefix `Z9-`
- row Z9-1 → Sib1
## (era-8 header, superseded) ORCHESTRATOR ACTIVE — **era-8 · Old `[000000]`**
- stale row
BOARD
(cd "$SEAT" && git add docs && git commit -q -m board && git push -q origin HEAD:main)
# The builder clones NOW, before the brief exists: its checkout is the stale one.
git clone -q "$ORIGIN" "$BUILDER" 2>/dev/null
printf '# Z9-1 — the brief\nSeat: Zed [abc123]\n' > "$SEAT/docs/orchestration/briefs/Z9-1.md"
(cd "$SEAT" && git add docs && git commit -q -m brief && git push -q origin HEAD:main)
run() { (cd "$BUILDER" && bash -c "$1" 2>"$TMP/err"); }

# ---- F3 step 1: the brief comes from origin (fetch with one retry, then `git show origin/main:`) ----
run "cat docs/orchestration/briefs/Z9-1.md" >/dev/null 2>&1 && bad "positive control: a plain cat of the stale checkout must NOT see the pushed brief" || ok
step1="$(cmds 1)"
fetch="$(printf '%s\n' "$step1" | first_with 'git fetch')"
show="$(printf '%s\n' "$step1" | first_with 'git show origin/main:docs/orchestration/briefs/')"
[ -n "$fetch" ] && ok || bad "step 1 has no 'git fetch' command: $step1"
[ -n "$show" ] && ok || bad "step 1 has no 'git show origin/main:docs/orchestration/briefs/' command: $step1"
has "step 1 retries the fetch once" "|| { sleep 2; git fetch origin; }" "$fetch"
if [ -n "$fetch" ] && [ -n "$show" ]; then
  out="$(run "$fetch
${show//<ROW>/Z9-1}")"
  [ "$out" = "$(printf '# Z9-1 — the brief\nSeat: Zed [abc123]')" ] && ok || bad "step 1 commands did not print the pushed brief: $out"
  hasnt "step 1 fetch is clean" "fatal" "$(cat "$TMP/err")"
fi
row1="$(grep '^| 1 |' "$SKILL" || true)"
has "step 1 falls back to the working tree" 'cat docs/orchestration/briefs/<ROW>.md' "$row1"
has "step 1 falls back to the seat" "seat" "$row1"

# ---- F3 step 2: the board extraction is anchored on the banner, not on the first `---` -----------
old="$(run "git fetch -q origin && git show origin/main:docs/orchestration/AGENT_BOARD.md | sed -n '1,/^---\$/p' | head -60")"
hasnt "positive control: the OLD 'first 60 lines up to the first ---' shows NO banner on this board" "ORCHESTRATOR ACTIVE" "$old"
board="$(cmds 2 | first_with 'git show origin/main:docs/orchestration/AGENT_BOARD.md')"
[ -n "$board" ] && ok || bad "step 2 has no board-extraction command: $(cmds 2)"
if [ -n "$board" ]; then
  out="$(run "git fetch -q origin
$board")"
  has "step 2 prints the CURRENT banner" 'ORCHESTRATOR ACTIVE — **era-9 · Zed `[abc123]`**' "$out"
  has "step 2 prints the banner's rows" "row Z9-1 → Sib1" "$out"
  hasnt "step 2 stops before the superseded header" "superseded" "$out"
  hasnt "step 2 stops before the superseded rows" "stale row" "$out"
  [ "$(printf '%s\n' "$out" | wc -l)" -le 60 ] && ok || bad "step 2 prints more than 60 lines"
  # No banner on the board prints nothing (the builder is told: no seat).
  pipeline="${board#git show origin/main:docs/orchestration/AGENT_BOARD.md | }"
  none="$(run "git show origin/main:docs/orchestration/AGENT_BOARD.md | sed '/ORCHESTRATOR ACTIVE/d' | $pipeline")"
  [ -z "$none" ] && ok || bad "a board without a banner must print nothing: $none"
fi

# a heading that says `superseded` is never taken for the current banner, so a board
# left with ONLY superseded banner headings prints nothing (no seat), not a stale era's section.
if [ -n "$board" ]; then
  pipeline="${board#git show origin/main:docs/orchestration/AGENT_BOARD.md | }"
  printf '%s\n' "# Board" "## (era-8 header, superseded) 🎛 ORCHESTRATOR ACTIVE — **era-8 · Old \`[def456]\`**" "old row X8-1 → Sib9" \
    "## (era-7 header, SUPERSEDED) ORCHESTRATOR ACTIVE — era-7" "older row" "## Open rows" "row Q-1" > "$TMP/superseded-board.md"
  out="$(bash -c "cat '$TMP/superseded-board.md' | $pipeline" 2>&1)"
  [ -z "$out" ] && ok || bad "a board holding only superseded banners must print nothing: $out"
  # ...and a superseded header ABOVE the live one is skipped, the live one printed.
  printf '%s\n' "# Board" "## (era-8 header, superseded) ORCHESTRATOR ACTIVE — era-8" "old row X8-1" \
    "## 🎛 ORCHESTRATOR ACTIVE — **era-9 · Zed \`[abc123]\`**" "row Z9-1 → Sib1" "## Open rows" "row Q-1" > "$TMP/mixed-board.md"
  out="$(bash -c "cat '$TMP/mixed-board.md' | $pipeline" 2>&1)"
  has "a superseded header above the live banner is skipped" "row Z9-1 → Sib1" "$out"
  hasnt "the superseded section above is not printed" "old row X8-1" "$out"
  hasnt "the section after the banner is not printed" "row Q-1" "$out"
fi

# ---- F3: READY names the seat + era the builder saw ---------------------------------------------
readies="$(grep '^READY <PREFIX>' "$SKILL" || true)"
[ -n "$readies" ] && ok || bad "no READY format line found in the orient skill"
while IFS= read -r r; do
  [ -z "$r" ] && continue
  has "READY format names the seat + era" 'saw <seat Name [ref]> era-<N>' "$r"
done <<EOF
$readies
EOF
# The other copies of the READY format (the board template the seat reads, the orchestrate skill's
# inline format) must agree with the skill, or a seat copies a stale one.
has "board template READY format names the seat + era" 'saw <seat Name [ref]> era-<N>' "$(grep '^READY <PREFIX>' "$ROOT/templates/AGENT_BOARD.md")"
has "board template READY format carries model + marks" 'model <id> · fill <current> · marks <prompt>/<handover>' "$(grep '^READY <PREFIX>' "$ROOT/templates/AGENT_BOARD.md")"
has "orchestrate READY format names the seat + era" 'saw <seat Name [ref]> era-<N>' "$(grep 'Wait for \*\*READY\*\*' "$ORCH")"
has "brief template names the seat" "| seat |" "$(cat "$BRIEF_T")"

# ---- F4: board/log/fact-writing lanes sit on the MID model, never the small one ------------------
table_rows() {  # <file> <heading regex> — the `|` rows under the heading, up to the next heading
  awk -v h="$2" '$0 ~ h {on=1; next} on && /^#/ {exit} on && /^\|/' "$1"
}
for spec in "$ORCH|^## 3a" "$GS|^### Model per lane"; do
  f="${spec%%|*}"; h="${spec#*|}"; t="$(table_rows "$f" "$h")"; n="$(basename "$(dirname "$f")")/$(basename "$f")"
  [ -n "$t" ] && ok || bad "$n: no model table under '$h'"
  fact_row="$(printf '%s\n' "$t" | grep -i 'board' | grep -i 'log' || true)"
  [ -n "$fact_row" ] && ok || bad "$n: no row for board/log lanes"
  has "$n: board/log lane is on sonnet[1m]" 'sonnet[1m]' "$fact_row"
  hasnt "$n: board/log lane is never on haiku as its model" '| `haiku`' "$fact_row"
  small="$(printf '%s\n' "$t" | grep '`haiku`' || true)"
  [ -n "$small" ] && ok || bad "$n: no haiku row"
  hasnt "$n: the haiku row does not take board/log edits" "board" "$small"
  hasnt "$n: the haiku row does not take docs/log edits" "Docs" "$small"
  case "$small" in *[Ff]acts*|*"never writes"*|*fabricat*|*invent*) ok ;; *) bad "$n: the haiku row must say the small model never writes facts: $small" ;; esac
done
has "orchestrate keeps the 'small model never writes facts' rule" "The small model never writes facts" "$(cat "$ORCH")"

# ---- F5: nowhere is a user told to bare `/clear` (or "clear" a terminal) to recycle ---------------
# A bare /clear keeps the terminal's OLD model. Scan EVERY shipped .md (templates/memory-starter/ ships
# into every adopter's memory) plus the launch scripts' and hook's own comment/usage text for the WORD
# clear (/clear, clear, cleared, clears, clearing; not "clearly") and for /reset and /new.
# HOW: each ALLOWED phrase is stripped from the line by OCCURRENCE, then the line fails on
# any clear-word LEFT. There is deliberately NO line-wide exemption: the orchestrate skill writes whole
# paragraphs as single ~600-char lines, so a line that is allowed for one phrase must not hide a second,
# bad one ("Never pre-announce a clear. Tell the human it is safe to clear." was invisible to the 5c guard).
F5_ALLOW=(
  'uptime survives `?/clear`?'                    # ListAgents liveness
  'evaporate on `?/clear`?'                       # what a retro saves
  '`?/clear`? destroys (unpersisted )?context'    # why the handshake exists
  '[Rr]etro-before-clear'                         # the handshake's own name
  'Never pre-announce a clear'
  'Retro should come before a clear'              # a quoted user line
  'a clear output'                                # the adjective
  'startup[|]clear'                               # the SessionStart matcher
  'startup or /clear'
  'terminals were cleared before'                 # a past incident, told as history
  'Nowhere does the kit tell a user to bare `/clear` to recycle'
  '(a )?bare `/clear`( in an old terminal)? keeps (the|its|that)( terminal'"'"'s)?( OLD| old)?( model|$)'   # the warning itself, up to "keeps the ... model" (or wrapped after "keeps the")
  'never a bare `/clear`'
  'if you (do|must) `/clear`, run `/model'                  # the safe way, model first
  '(^|[.)] +)A bare `/clear`$'                              # that warning wrapped at the line end, only as a sentence start
)
# f5_left <line>: what is left of the line after the allowed phrases are removed, if it still holds
# a clear-word (or /reset, /new). Empty output = the line is fine.
F5_HIT='(^|[^[:alnum:]_])clear(s|ed|ing)?([^[:alnum:]_]|$)|/(reset|new)([^[:alnum:]_]|$)'
f5_left() {
  local rest="$1" ph
  for ph in "${F5_ALLOW[@]}"; do rest="$(printf '%s' "$rest" | sed -E "s#${ph}##g")"; done
  printf '%s' "$rest" | grep -Ei -- "$F5_HIT" || true
}
n_scan=0; scanned=""
while IFS= read -r f; do
  n_scan=$((n_scan+1)); scanned="$scanned ${f#"$ROOT"/}"
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    left="$(f5_left "$l")"
    [ -z "$left" ] || bad "F5 ${f#"$ROOT"/} still says clear/reset/new after the allowed phrases are removed: $(printf '%s' "$left" | cut -c1-240)"
  done < <(grep -Ei -- "$F5_HIT" "$f" || true)   # only candidate lines pay for the per-phrase strip
done < <(find -H "$ROOT" \( -name '*.md' -o -path "$ROOT/scripts/*.sh" -o -path "$ROOT/hooks/*.sh" \) -not -path '*/.git/*' | LC_ALL=C sort)
[ "$n_scan" -ge 45 ] && ok || bad "F5 scan found only $n_scan files (the find is broken?)"
# The scan must REACH the files that matter most, by name (a bare count floor would let one drop out).
for must in templates/memory-starter/feedback_retro_before_clear_handshake.md skills/orchestrate/SKILL.md \
            docs/GETTING-STARTED.md docs/LESSONS.md templates/CLAUDE-section.md scripts/recycle-sibling.sh hooks/session-start.sh; do
  case " $scanned " in *" $must "*) ok ;; *) bad "F5 scan does not reach $must" ;; esac
done
# Pinned holes (committed negative fixtures): synthetic one-line paragraphs shaped like the real ones.
# Each carries ALLOWED phrases AND one bad instruction; the guard must flag exactly the bad one. These were
# the lines the 5c line-wide exemption let through (K8 from the reader, H1-H3 from the seat).
for fx in \
  'Retro-before-clear is a **handshake** (LESSON 24): order → explicit "retro complete" → tell the human it is safe to `/clear`, one terminal at a time. Never pre-announce a clear.' \
  'Retro-before-clear is a **handshake** (LESSON 24): order → explicit "retro complete" → recycle, one terminal at a time. Never pre-announce a clear. Once it replies, tell the human the terminal is safe to clear.' \
  'then relaunch it with `claude --name <Name> --model <m> /orient` (a bare `/clear` keeps the terminal'"'"'s old model), or simply `/clear` the old terminal.' \
  '(launch fresh → wait → SIGTERM old, or have the human `/clear` it; no `--model` = the default, never the old session'"'"'s) | Script exits 2' \
  'then relaunch it with `--model` (a bare `/clear` keeps the old model); or `/reset` it.' \
  'then relaunch it with `--model`, or open a `/new` session.' \
  'close it with `--model` set, or Clear the terminal.' \
  'A bare `/clear` keeps things simple: use it to recycle.' \
  'In a hurry, to recycle use a bare `/clear`' \
  'To recycle, tell the human: A bare `/clear`' ; do   # the last: its sentence continues on the NEXT line ("and carry on."); only a sentence-START "A bare `/clear`" may end a line
  [ -n "$(f5_left "$fx")" ] && ok || bad "F5 hole not caught (the guard passes this line): $fx"
done
# ...and the legitimate phrasings, alone and combined on one long line, are NOT flagged (false-flag control).
for fx in \
  'a bare `/clear` keeps that terminal'"'"'s OLD model; if you must `/clear`, run `/model <lane model>` first, then `/orchestration-kit:orient`' \
  'terminal uptime survives `/clear`. Retro-before-clear is a **handshake**. Never pre-announce a clear. A bounded job with a clear output.' \
  'closed and relaunched with an explicit `--model` (a bare `/clear` keeps the old model).' \
  'never a bare `/clear`) when recycling isn'"'"'t available.' \
  'A bare `/clear`' \
  '(`hooks/hooks.json`, startup|clear): tells a fresh session; (startup or /clear) too.' ; do
  [ -z "$(f5_left "$fx")" ] && ok || bad "F5 false flag on a legitimate line: $fx => $(f5_left "$fx")"
done
# The recycle row's line carries `--model` for the script, so the line check above cannot see its
# fallback clause; pin the old phrasings directly (a bare /clear keeps the terminal's OLD model).
hasnt "orchestrate no longer says a terminal is 'safe to /clear'" "safe to /clear" "$(cat "$ORCH")"
hasnt "orchestrate no longer says '/clear this terminal'" "/clear this terminal" "$(cat "$ORCH")"
has "orchestrate: recycle fallback relaunches with an explicit model" 'claude --name <Name> --model <lane model>' "$(cat "$ORCH")"
has "orchestrate: seat handover fallback relaunches with an explicit model" "claude --name Orca --model 'opus[1m]'" "$(cat "$ORCH")"
has "getting-started: by-hand section carries --model" "--model" "$(awk '/Opening a session by hand/{on=1} on{print} /^## /&&on&&!/Advanced/{exit}' "$GS" | head -20)"

echo "lean-orient: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
