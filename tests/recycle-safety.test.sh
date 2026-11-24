#!/usr/bin/env bash
# Tests for the live-work refusal in scripts/recycle-sibling.sh: a session whose claude still has a live
# shell child (a background gate run, a loop) is NOT recycled without --force; MCP-style non-shell children
# never count; --dry-run lists what is live. The self-recycle path (the recycle running inside the seat's
# own tool shell) is covered by tests/recycle-inplace.test.sh, which must stay green with this check on.
# Run: bash tests/recycle-safety.test.sh   Linux only (SKIP elsewhere). Every `claude` is a stand-in process.
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
SUITE=recycle-safety
. "$(dirname "$0")/inplace-harness.sh"
FORBID=(FAKE_TERM_MODE=forbid)
launches_ge() { [ "$(nlaunch)" -ge "$1" ]; }
file_has() { grep -Eq -- "$2" "$1" 2>/dev/null; }

# A stand-in claude named <Name> whose child is <kind>: "shell" = a live `bash -c` (what the Bash tool leaves
# running), "plain" = a sleep (what an MCP server looks like to this check: not a shell). Records every pid.
fake_claude() {  # <name> <shell|plain>
  local body
  if [ "$2" = shell ]; then body='bash -c "sleep 120; true" & wait'; else body='sleep 120 & wait'; fi
  ( exec -a "claude --name $1 x" bash -c "$body" ) </dev/null >/dev/null 2>&1 &
  FC=$!; disown "$FC"; PIDS+=("$FC")
  wait_for "fake claude $1" pgrep -f "^claude --name ${1}( |\$)"
  wait_for "its child" pgrep -P "$FC"
  local c; for c in $(pgrep -P "$FC"); do PIDS+=("$c"); CHILD=$c; done
}
stop_fake() {  # kill the exact recorded pids of this fake and wait until its name is gone
  kill -KILL "$CHILD" "$FC" 2>/dev/null
  wait_for "fake claude gone" bash -c "! pgrep -f '^claude --name ${1}( |\$)'"
}

# S1. a live shell child: dry-run lists it; a real run refuses with exit 3 and touches nothing
sandbox; n=$(nameFor S1)
fake_claude "$n" shell
recycle "${FORBID[@]}" -- --dry-run "$n"
rematch "S1 dry run lists the live shell" "^live work +${CHILD} " "$OUT"
has "S1 dry run says a real run refuses" "refuses (exit 3) without --force" "$OUT"
recycle "${FORBID[@]}" -- "$n"
eq "S1 real run exits 3" 3 "$RC"
has "S1 says why" "still has live shells" "$ERR"
has "S1 names the pid" "pid ${CHILD} " "$ERR"
has "S1 says how to override" "--force" "$ERR"
alive "$FC" && ok || bad "S1 the old claude was killed"
alive "$CHILD" && ok || bad "S1 the live shell was killed"
eq "S1 nothing launched" 0 "$(nlaunch)"
absent "S1 the terminal was never called" "$SB/TERM-WAS-CALLED"

# S2. --force: the dry run says so, and a real run gets past the check (the forbidden terminal then stops it)
recycle "${FORBID[@]}" -- --dry-run --force "$n"
has "S2 dry run notes --force" "--force: a real run recycles anyway" "$OUT"
recycle "${FORBID[@]}" -- --force "$n"
ne "S2 --force does not refuse" 3 "$RC"
hasnt "S2 --force: no refusal text" "still has live shells" "$ERR"
stop_fake "$n"

# S3. a non-shell child (an MCP server, a sleep) is not live work
sandbox; n=$(nameFor S3)
fake_claude "$n" plain
recycle "${FORBID[@]}" -- --dry-run "$n"
rematch "S3 non-shell child: live work none" '^live work +none$' "$OUT"
stop_fake "$n"

# S4. no old process at all: live work none, no refusal
sandbox; n=$(nameFor S4)
recycle "${FORBID[@]}" -- --dry-run "$n"
rematch "S4 no old process: live work none" '^live work +none$' "$OUT"

# S5. The seat's self-recycle while its own tool shell is still alive. The seat runs the recycle from a shell
#     that is its claude's child; that shell is the recycle's ANCESTOR, so the first check skips it. The
#     detached copy is no longer below it, and in real use the tool shell can outlive the call by a moment
#     (here: `; sleep 3`), so the copy must not check again (the parent already did) or the seat would
#     refuse to recycle itself on its own tool call.
sandbox; n=$(nameFor S5)
printf self-recycle > "$SB/stub/mode.1"; printf term-trap > "$SB/stub/mode.2"
# The harness redirects the LAST command of SELF_RECYCLE_CMD (here the sleep), so the recycle writes its own files.
start_wrapper "$n" "SELF_RECYCLE_CMD=bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n go --model haiku > $SB/stub/s5.out 2> $SB/stub/s5.err; sleep 3" \
  FAKE_TERM_MODE=forbid RECYCLE_DETACH_DELAY=1
OLD="$(launch_pid 1)"
wait_for "the seat's recycle call to print its log" file_has "$SB/stub/s5.out" 'log:'
logp="$(sed -n 's/.*log: //p' "$SB/stub/s5.out" | head -1)"
hasnt "S5 the seat's own call did not refuse" "still has live shells" "$(cat "$SB/stub/s5.err" 2>/dev/null)"
wait_for "the fresh claude" launches_ge 2
wait_for "old claude gone" not_alive "$OLD"
eq "S5 the old seat was SIGTERMed" "TERM" "$(cat "$SB/stub/sigterm.$OLD" 2>/dev/null)"
hasnt "S5 the detached copy did not refuse" "still has live shells" "$(cat "$logp" 2>/dev/null)"

# S6. An IDLE session: Claude Code runs the statusline as a short-lived `sh -c` child of claude every few
#     seconds, so a single look catches one now and then and refused an idle session (exit 3). Here the stand-in
#     claude keeps a fresh short `sh -c` child alive almost all the time; each lives well under the re-check
#     interval, so no single shell is there at both looks. `; true` keeps sh from exec'ing sleep (it stays sh).
sandbox; n=$(nameFor S6)
( exec -a "claude --name $n x" bash -c 'while :; do sh -c "sleep 0.3; true"; done' ) </dev/null >/dev/null 2>&1 &
FC=$!; disown "$FC"; PIDS+=("$FC")
wait_for "fake claude $n" pgrep -f "^claude --name ${n}( |\$)"
wait_for "its first transient sh" pgrep -P "$FC"
recycle "${FORBID[@]}" -- --dry-run "$n"
rematch "S6 transient sh children: live work none" '^live work +none$' "$OUT"
recycle "${FORBID[@]}" -- "$n"
ne "S6 a real run does not refuse an idle session" 3 "$RC"
hasnt "S6 no refusal text" "still has live shells" "$ERR"
# no bare `pid N` line (a child that exited mid-check printed one, with empty etime and args)
if printf '%s\n' "$OUT" "$ERR" | grep -Eq '^ *(pid +)?[0-9]+ *$'; then bad "S6 a bare pid line: $(printf '%s\n' "$OUT" "$ERR" | grep -E '^ *(pid +)?[0-9]+ *$')"; else ok; fi
kill -KILL "$FC" 2>/dev/null; pkill -KILL -P "$FC" 2>/dev/null
wait_for "fake claude gone" bash -c "! pgrep -f '^claude --name ${n}( |\$)'"

# S7. launch_live_shells in isolation, with a fake `ps` that serves one process table per look. Pins what S6
#     cannot see from outside: a shell counts only if the SAME process (pid + start time) is there at both
#     looks, a shell that vanished is never printed as a bare pid, and a clean first look does not wait.
S7="$(mktemp -d)"; PIDS+=()
cat > "$S7/drv.sh" <<'DRV'
. "$LIB"
launch_is_ancestor() { return 1; }
sleep() { echo "$1" >> "$S7/slept"; }
ps() {
  case "$*" in
    "-A -o pid=,ppid=,comm=") n=$(( $(cat "$S7/n") + 1 )); echo "$n" > "$S7/n"; cat "$S7/table.$n" 2>/dev/null || cat "$S7/table.1" ;;
    "-o lstart= -p "*)       cat "$S7/lstart.$(cat "$S7/n").$4" 2>/dev/null ;;
    "-o etime= -p "*)        cat "$S7/etime.$4" 2>/dev/null ;;
    "-o args= -p "*)         cat "$S7/args.$4" 2>/dev/null ;;
  esac
}
launch_live_shells 100
DRV
s7() {  # <name> → output of launch_live_shells for the files currently in $S7
  echo 0 > "$S7/n"; rm -f "$S7/slept"
  LIB="$ROOT/scripts/lib-launch.sh" S7="$S7" bash "$S7/drv.sh" 2>&1
}
s7reset() { rm -f "$S7"/table.* "$S7"/lstart.* "$S7"/etime.* "$S7"/args.*; }
s7live() {  # a shell 200 under pid 100 at both looks, same start time
  s7reset
  echo "200 100 sh" > "$S7/table.1"; echo "200 100 sh" > "$S7/table.2"
  echo "Tue Oct 13 09:00:00 2026" > "$S7/lstart.1.200"; echo "Tue Oct 13 09:00:00 2026" > "$S7/lstart.2.200"
  echo " 01:23" > "$S7/etime.200"; echo "bash gate.sh --all" > "$S7/args.200"
}
s7live;                  eq "S7 the same shell at both looks is live work" "200 01:23 bash gate.sh --all" "$(s7)"
eq "S7 it waited the default 1.5 s between looks" "1.5" "$(cat "$S7/slept" 2>/dev/null)"
s7live; echo "Tue Oct 13 09:00:07 2026" > "$S7/lstart.2.200"
eq "S7 a REUSED pid (new start time at the second look) is not live" "" "$(s7)"
s7live; echo "201 100 sh" > "$S7/table.2"
eq "S7 a transient shell (a different pid at the second look) is not live" "" "$(s7)"
s7live; rm -f "$S7/etime.200"
eq "S7 a shell gone at print time prints nothing, not a bare pid" "" "$(s7)"
s7reset; echo "300 100 node" > "$S7/table.1"
eq "S7 no shell at the first look: nothing" "" "$(s7)"
[ ! -e "$S7/slept" ] && ok || bad "S7 waited although the first look was empty"
s7live; rm -f "$S7"/lstart.*
eq "S7 a ps without lstart falls back to a pid-only match (never drops the shell)" "200 01:23 bash gate.sh --all" "$(s7)"
rm -rf "$S7"

finish
