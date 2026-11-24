#!/usr/bin/env bash
# Tests for the session cap (team block `max_sessions:`): the parser, the warning, and both launchers
# warning before they pass it (never refusing). KIT_CLAUDE_COUNT pins the host count, so the result does not
# depend on how many real sessions this machine runs; one case checks the real counter counts by name.
# Run: bash tests/session-cap.test.sh   Linux only (SKIP elsewhere). Every `claude` is a stand-in process.
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
SUITE=session-cap
. "$(dirname "$0")/inplace-harness.sh"
START="$ROOT/scripts/start-team.sh"
# The sibling prefix is unique per run: the default "Sib" made Sib1 match a REAL session named Sib1 on a host
# that runs a team, so start-team counted one fewer added name and the over-cap cases went red there only.
SIBP=$(nameFor CapSib)
conf() { mkdir -p "$SB/repo/docs/orchestration"; printf 'team:\n  seat:             CapSeat\n  prefix:           %s\n  siblings:         1\n%s\n' "$SIBP" "$1" > "$SB/repo/docs/orchestration/ORCHESTRATION.md"; }
capfn() {  # <adding> → stderr of launch_cap_warn after parsing the sandbox repo's team block
  KIT_CLAUDE_COUNT="${HOSTN:-5}" bash -c '. "$1"; launch_team_conf "$2"; launch_cap_warn "$3"' _ "$ROOT/scripts/lib-launch.sh" "$SB/repo" "$1" 2>&1
}

sandbox
conf ""; eq "no max_sessions: no warning" "" "$(capfn 5)"
conf "  max_sessions:     abc"; eq "invalid max_sessions: ignored" "" "$(capfn 5)"
conf "  max_sessions:     0"; eq "max_sessions 0: ignored" "" "$(capfn 5)"
conf "  max_sessions:     7"; eq "5 running + 2 = 7: at the cap, no warning" "" "$(capfn 2)"
conf "  max_sessions:     6"; out="$(capfn 2)"
has "5 running + 2 > 6: warns" "passes max_sessions (6)" "$out"
has "the warning says how many run" "5 Claude sessions already run" "$out"
has "the warning says what to do" "Retire one first" "$out"
# the real counter counts processes NAMED claude, not command lines that start with "claude" (stand-ins)
( exec -a "claude --name ZzCapDecoy$$ x" sleep 60 ) </dev/null >/dev/null 2>&1 & DEC=$!; disown "$DEC"; PIDS+=("$DEC")
real="$(bash -c '. "$1"; pgrep -x claude | wc -l' _ "$ROOT/scripts/lib-launch.sh" | tr -d ' ')"
got="$(bash -c '. "$1"; TEAM_MAX=1; launch_cap_warn 0' _ "$ROOT/scripts/lib-launch.sh" 2>&1)"
if [ "$real" -gt 1 ]; then has "real counter: counts named claude processes" "$real Claude sessions" "$got"; else eq "real counter: no named claude here, no warning at cap 1" "" "$got"; fi
kill -KILL "$DEC" 2>/dev/null
# no claude running at all: pgrep exits 1, and under the launchers' `set -euo pipefail` that must not end the
# script (it once did, silently, right after the `terminal` line); the count is 0 and the warning still works
mkdir -p "$SB/nopgrep"; printf '#!/bin/sh\nexit 1\n' > "$SB/nopgrep/pgrep"; chmod +x "$SB/nopgrep/pgrep"
got="$(PATH="$SB/nopgrep:$PATH" bash -c 'set -euo pipefail; . "$1"; TEAM_MAX=1; launch_cap_warn 2; echo SURVIVED' _ "$ROOT/scripts/lib-launch.sh" 2>&1)"
has "no claude running (pgrep exits 1): set -e caller survives" "SURVIVED" "$got"
has "no claude running: counts 0 and still warns" "0 Claude sessions already run" "$got"

# start-team dry run: warns, still plans the launches (a warning, never a refusal)
run_in_sb FAKE_TERM_MODE=forbid KIT_CLAUDE_COUNT=5 -- bash "$START" --repo "$SB/repo" --terminal linux-xterm --dry-run
eq "start-team over the cap: exit 0" 0 "$RC"
has "start-team over the cap: warns" "passes max_sessions (6)" "$ERR"
has "start-team over the cap: still plans the seat" "LAUNCH CapSeat" "$OUT"
conf "  max_sessions:     100000"
run_in_sb FAKE_TERM_MODE=forbid KIT_CLAUDE_COUNT=5 -- bash "$START" --repo "$SB/repo" --terminal linux-xterm --dry-run
hasnt "start-team under the cap: no warning" "max_sessions" "$ERR"

# start-team counts only the names it will ADD: with the seat already running, 5 + 1 sibling = 6 is at the
# cap of 6 and must not warn, and the plan says SKIP for the running seat. Without it, 5 + 2 = 7 warns.
sn=$(nameFor SEAT)
printf 'team:\n  seat:             %s\n  prefix:           %s\n  siblings:         1\n  max_sessions:     6\n' "$sn" "$SIBP" > "$SB/repo/docs/orchestration/ORCHESTRATION.md"
( exec -a "claude --name $sn x" sleep 120 ) </dev/null >/dev/null 2>&1 &
RUNSEAT=$!; disown "$RUNSEAT"; PIDS+=("$RUNSEAT")
wait_for "running seat stand-in" pgrep -f "^claude --name ${sn}( |\$)"
run_in_sb FAKE_TERM_MODE=forbid KIT_CLAUDE_COUNT=5 -- bash "$START" --repo "$SB/repo" --terminal linux-xterm --dry-run
hasnt "start-team: a name already running is not counted as added (no warning at the cap)" "passes max_sessions" "$ERR"
has "start-team: the running seat is skipped" "SKIP   $sn" "$OUT"
kill -KILL "$RUNSEAT" 2>/dev/null
wait_for "running seat gone" bash -c "! pgrep -f '^claude --name ${sn}( |\$)'"
run_in_sb FAKE_TERM_MODE=forbid KIT_CLAUDE_COUNT=5 -- bash "$START" --repo "$SB/repo" --terminal linux-xterm --dry-run
has "start-team: with the seat not running, 5 + 2 > 6 warns" "passes max_sessions (6)" "$ERR"

# recycle: a name with no old process adds one (warns); a name with an old process replaces it (no warning)
conf "  max_sessions:     5"; n=$(nameFor CAP)
recycle FAKE_TERM_MODE=forbid KIT_CLAUDE_COUNT=5 -- --dry-run "$n"
has "recycle of a new name over the cap: warns" "passes max_sessions (5)" "$ERR"
( exec -a "claude --name $n x" sleep 120 ) </dev/null >/dev/null 2>&1 &
LOOSE=$!; disown "$LOOSE"; PIDS+=("$LOOSE")
wait_for "loose claude" pgrep -f "^claude --name ${n}( |\$)"
recycle FAKE_TERM_MODE=forbid KIT_CLAUDE_COUNT=5 -- --dry-run "$n"
hasnt "recycle that replaces a session: no warning" "max_sessions" "$ERR"
kill -KILL "$LOOSE" 2>/dev/null

finish
