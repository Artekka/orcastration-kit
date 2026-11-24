#!/usr/bin/env bash
# Tests for scripts/recycle-sibling.sh in-place mode and the wrapper-aware tab commands (v0.7.0).
# Run: bash tests/recycle-inplace.test.sh   Linux only (SKIP elsewhere). Nothing real is launched: every
# `claude` is a stub on PATH and the terminal is a stand-in `xterm` (tests/inplace-harness.sh).
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
SUITE=recycle-inplace
. "$(dirname "$0")/inplace-harness.sh"
FORBID=(FAKE_TERM_MODE=forbid)          # a terminal that must never run: it leaves a marker if called
ORIENT="/orchestration-kit:orient"

# R0. ISOLATION tripwire (the m7 incident, 2026-10-03: a mutant made a detached copy lose --terminal, it
#     auto-detected the terminal, and on this WSL box that was the REAL wt.exe: a Windows Terminal tab opened
#     on the user's screen). With NO --terminal the sandbox must resolve to the stub xterm, and the wt.exe path
#     the WSL probe would use must be empty (WT_EXE points nowhere and the probe's %USERNAME% derivation is
#     skipped), so no path from a test can reach a real terminal. DRY-RUN only: nothing is launched here.
#     tests/falsify-driver preflight runs exactly this block and refuses to mutate unless it is green.
sandbox; n=$(nameFor R0)
run_in_sb -- bash "$RECYCLE" --repo "$SB/repo" --dry-run "$n"
eq "R0 dry run exit 0" 0 "$RC"
rematch "R0 no --terminal: auto-detect picks the stub xterm" '^backend +linux-xterm$' "$OUT"
renomatch "R0 ...never a WSL backend" '^backend +wsl' "$OUT"
words=(); while IFS= read -r w; do words+=("$w"); done < <(sbenv)
wtpath="$(env -u CLAUDE_CONFIG_DIR "${words[@]}" bash -c '. "$1"; _launch_wsl_probe >/dev/null 2>&1; printf %s "${LAUNCH_WT:-}"' _ "$ROOT/scripts/lib-launch.sh")"
eq "R0 the wt.exe the WSL probe would use is empty (no path can reach the real one)" "" "$wtpath"
[ -z "$wtpath" ] || [ ! -e "$wtpath" ] && ok || bad "R0 the resolved wt.exe path exists: $wtpath"

# R1. --dry-run / DRY_RUN=1 name the mode they WOULD use: in-place only for a lone claude whose parent is
#     the wrapper; --new-tab forces the old behavior; a dry run changes nothing.
sandbox; n=$(nameFor R1)
dry() { recycle "${FORBID[@]}" -- --dry-run "$@" "$n"; }
dry;                         rematch "R1 no old process" '^mode: new-tab$' "$OUT"
recycle "${FORBID[@]}" DRY_RUN=1 -- "$n"; rematch "R1 DRY_RUN=1 works like --dry-run" '^mode: new-tab$' "$OUT"
# an old claude that is NOT under a wrapper (a bare `claude`, parent = this test)
( exec -a "claude --name $n x" sleep 120 ) </dev/null >/dev/null 2>&1 &
LOOSE=$!; disown "$LOOSE"; PIDS+=("$LOOSE")
wait_for "loose claude" pgrep -f "^claude --name ${n}( |\$)"
dry;                         rematch "R1 old claude started by hand" '^mode: new-tab$' "$OUT"
kill -KILL "$LOOSE" 2>/dev/null
wait_for "loose claude gone" bash -c "! pgrep -f '^claude --name ${n}( |\$)'"
# an old claude under a real wrapper
start_wrapper "$n" STUB_MODE=term-trap; W1PID=$WPID
dry;                         rematch "R1 lone claude under the wrapper" '^mode: in-place$' "$OUT"
rematch "R1 names the old pid" '^old pids +[0-9]+' "$OUT"
dry --new-tab;               rematch "R1 --new-tab forces new-tab" '^mode: new-tab$' "$OUT"
eq "R1 a dry run launched nothing" 1 "$(nlaunch)"
alive "$W1PID" && ok || bad "R1 wrapper still alive"
absent "R1 the terminal was never called" "$SB/TERM-WAS-CALLED"
absent "R1 no hand-off written" "$SB/state/$n.next"

# R2. In place, end to end: same wrapper pid, new child pid, the old child got SIGTERM, the wrapper did NOT.
sandbox; n=$(nameFor R2)
start_wrapper "$n" STUB_MODE=term-trap; W2PID=$WPID; OLD="$(launch_pid 1)"
eq "R2 the stub's parent is the wrapper" "$W2PID" "$(launch_ppid 1)"
WCMD="$(cmdline "$W2PID")"
recycle "${FORBID[@]}" STUB_MODE=term-trap -- "$n" "$ORIENT --brief ROW-1" --model 'sonnet[1m]' --effort high --mode accept-edits
eq "R2 exit 0" 0 "$RC"; has "R2 summary says in-place" "mode: in-place" "$OUT"
absent "R2 no new tab in the in-place path" "$SB/TERM-WAS-CALLED"
eq "R2 exactly one relaunch" 2 "$(nlaunch)"
eq "R2 the fresh claude is a child of the SAME wrapper" "$W2PID" "$(launch_ppid 2)"
ne "R2 a new pid" "$OLD" "$(launch_pid 2)"
eq "R2 argv (model, effort, permission mode, prompt)" "--name|$n|--permission-mode|acceptEdits|--model|sonnet[1m]|--effort|high|$ORIENT --brief ROW-1|" "$(argv_of 2)"
wait_for "old claude's SIGTERM record" test -f "$SB/stub/sigterm.$OLD"
eq "R2 the old child received SIGTERM" "TERM" "$(cat "$SB/stub/sigterm.$OLD")"
wait_for "old claude gone" not_alive "$OLD"
alive "$W2PID" && ok || bad "R2 wrapper still alive (never signalled)"
eq "R2 wrapper is the same program" "$WCMD" "$(cmdline "$W2PID")"
alive "$(launch_pid 2)" && ok || bad "R2 fresh claude alive"
eq "R2 hand-off consumed, no tmp/revoked leftovers" "" "$(ls -A "$SB/state")"

# R3. Timeout fallback: no fresh child under the wrapper -> hand-off removed, new-tab path used, and said so.
sandbox; n=$(nameFor R3)
start_wrapper "$n" STUB_MODE=ignore-term; W3PID=$WPID; OLD="$(launch_pid 1)"
recycle RECYCLE_INPLACE_TIMEOUT=2 STUB_MODE=ignore-term -- "$n" go --model haiku
eq "R3 exit 0" 0 "$RC"; rematch "R3 says it fell back" 'falling back to a new tab' "$ERR"
has "R3 summary says new-tab" "mode: new-tab" "$OUT"
absent "R3 an unconsumed hand-off would make the wrapper launch a duplicate later" "$SB/state/$n.next"
alive "$OLD" && ok || bad "R3 the stubborn old claude was only asked to stop"
alive "$W3PID" && ok || bad "R3 wrapper alive"
eq "R3 the wrapper never relaunched (one stub launch under it, one under the tab's own wrapper)" 2 "$(nlaunch)"
has "R3 the new tab runs the WRAPPER" "sibling-shell.sh" "$(cat "$SB/fake-term.args")"

# R3b. A same-name claude that is NOT a child of the wrapper does not count as the in-place relaunch.
sandbox; n=$(nameFor R3b)
start_wrapper "$n" STUB_MODE=term-decoy
recycle RECYCLE_INPLACE_TIMEOUT=2 STUB_MODE=term-decoy -- "$n" go --model haiku
exists "R3b the decoy must have been spawned" "$SB/stub/decoy.pids"
eq "R3b exit 0" 0 "$RC"; rematch "R3b fell back to a new tab" 'falling back to a new tab' "$ERR"; has "R3b mode new-tab" "mode: new-tab" "$OUT"

# R5. A wrapper for a DIFFERENT Name is never taken for ours (positive control: same shape, same Name).
sandbox; mine=$(nameFor R5a); other=$(nameFor R5b); control=$(nameFor R5c)
start_wrapper "$other" STUB_MODE=term-trap; OTHERW=$WPID; OTHERC="$(launch_pid 1)"
stand_in_wrapper "$other" "$mine" ""; IMPC=$SCPID
stand_in_wrapper "$control" "$control" ""
recycle "${FORBID[@]}" -- --dry-run "$control"; rematch "R5 same shape + matching Name = in-place" '^mode: in-place$' "$OUT"
recycle "${FORBID[@]}" -- --dry-run "$mine";    rematch "R5 same shape + other Name = new-tab" '^mode: new-tab$' "$OUT"
recycle STUB_MODE=term-trap -- "$mine" go --model haiku
eq "R5 exit 0" 0 "$RC"; has "R5 took the new-tab path" "mode: new-tab" "$OUT"
absent "R5 no hand-off for the other sibling" "$SB/state/$other.next"; absent "R5 no hand-off for ours" "$SB/state/$mine.next"
alive "$OTHERW" && ok || bad "R5 other wrapper alive"; alive "$OTHERC" && ok || bad "R5 other claude alive"
absent "R5 other claude never signalled" "$SB/stub/sigterm.$OTHERC"

# R6a. Race: the wrapper already claimed the hand-off but its child is slow to appear -> keep waiting, no
#      second tab (an `rm -f` fallback opened one anyway and left TWO sessions under one name).
sandbox; n=$(nameFor R6a)
start_wrapper "$n" STUB_MODE=term-trap STUB_SLOW=2
recycle "${FORBID[@]}" RECYCLE_INPLACE_TIMEOUT=1 RECYCLE_CLAIMED_GRACE=20 -- "$n" go --model haiku
absent "R6a no tab: that would be a duplicate" "$SB/TERM-WAS-CALLED"
eq "R6a exit 0" 0 "$RC"; has "R6a in-place" "mode: in-place" "$OUT"
renomatch "R6a did not claim to remove a consumed hand-off" 'removed the (unclaimed )?hand-off' "$ERR"
eq "R6a two launches" 2 "$(nlaunch)"; last_arg_is 2 go && ok || bad "R6a prompt reached the relaunch"
# R6b. ... and a claimed hand-off whose child never appears stops WITHOUT opening a tab, and says so.
sandbox; n=$(nameFor R6b)
start_wrapper "$n" STUB_MODE=term-trap STUB_SLOW=2 STUB_SLOW_SECS=8
recycle "${FORBID[@]}" RECYCLE_INPLACE_TIMEOUT=1 RECYCLE_CLAIMED_GRACE=2 -- "$n" go --model haiku
eq "R6b exit 1" 1 "$RC"; rematch "R6b says it did not open a tab" 'NOT opening a tab' "$ERR"; rematch "R6b says claimed" 'claimed' "$ERR"
absent "R6b the terminal was never called" "$SB/TERM-WAS-CALLED"; absent "R6b hand-off consumed" "$SB/state/$n.next"

# R7. The hand-off carries the account: inherit the old claude's, then --account 2, then --account 1.
sandbox; n=$(nameFor R7)
for a in 2 3; do mkdir -p "$SB/home/.claude-acct$a"; echo '{}' > "$SB/home/.claude-acct$a/.credentials.json"; done
start_wrapper "$n" STUB_MODE=term-trap CLAUDE_CONFIG_DIR="$SB/home/.claude-acct3"
go() { recycle "${FORBID[@]}" -- "$n" go --model haiku "$@"; eq "R7 exit 0 [$*]" 0 "$RC"; has "R7 in-place [$*]" "mode: in-place" "$OUT"; }
go; go --account 2; go --account 1
A2="$SB/home/.claude-acct$((1+1))"; A3="$SB/home/.claude-acct$((1+2))"
eq "R7 account per launch: inherited, inherited, account 2, default" "$A3,$A3,$A2,unset" "$(cfgs)"
absent "R7 the terminal was never called" "$SB/TERM-WAS-CALLED"

# R8. Seat self-recycle: a target claude that is an ANCESTOR of the running recycle is still in-place, but
#     DETACHES first (v0.7.0 took a new tab here). Same process shape run from outside is in-place with
#     detach: no (the control), so the ancestry walk is the only difference. R8d adds a shell layer: the
#     walk is deeper than the direct parent, and a direct-parent-only walk would report detach: no and let
#     the in-place SIGTERM cut the script's own parent chain.
sandbox; n=$(nameFor R8); control=$(nameFor R8c)
RUNIN="bash $RECYCLE --repo $SB/repo --terminal linux-xterm --dry-run"
stand_in_wrapper "$n" "$n" "$RUNIN $n > $SB/inside.out 2> $SB/inside.err
sleep 120" "${FORBID[@]}"
wait_for "recycle output from inside the old claude" grep -q '^mode:' "$SB/inside.out"
rematch "R8 from inside: in-place" '^mode: in-place$' "$(cat "$SB/inside.out")"
rematch "R8 from inside: detach" '^detach: yes$' "$(cat "$SB/inside.out")"
rematch "R8 says why" 'ancestor' "$(cat "$SB/inside.err")"
stand_in_wrapper "$control" "$control" ""
recycle "${FORBID[@]}" -- --dry-run "$control"
rematch "R8 control from outside: in-place" '^mode: in-place$' "$OUT"; renomatch "R8 control: no ancestor note" 'ancestor' "$ERR"
rematch "R8 control from outside: no detach" '^detach: no$' "$OUT"
sandbox; n=$(nameFor R8d)
stand_in_wrapper "$n" "$n" "bash -c \"$RUNIN $n > $SB/d2.out 2> $SB/d2.err; true\"
sleep 120" "${FORBID[@]}"
wait_for "recycle output from two shells below the old claude" grep -q '^mode:' "$SB/d2.out"
rematch "R8d depth 2: in-place" '^mode: in-place$' "$(cat "$SB/d2.out")"; rematch "R8d depth 2: detach" '^detach: yes$' "$(cat "$SB/d2.out")"
rematch "R8d says why" 'ancestor' "$(cat "$SB/d2.err")"

# R4. No old process: the new tab runs the WRAPPER with an explicit model, so every session moves over at
#     its next recycle. (Runs the real command through the stand-in terminal.)
sandbox; n=$(nameFor R4)
recycle STUB_MODE=term-trap -- "$n" "$ORIENT --brief X" --model 'sonnet[1m]' --effort low
eq "R4 exit 0" 0 "$RC"; has "R4 new-tab" "mode: new-tab" "$OUT"
tab="$(grep sibling-shell.sh "$SB/fake-term.args")"
has "R4 the tab command runs the wrapper with the explicit model" "$n --model sonnet\\[1m\\] --effort low" "$tab"
eq "R4 the wrapper started claude with that argv" "--name|$n|--model|sonnet[1m]|--effort|low|$ORIENT --brief X|" "$(argv_of 1)"
eq "R4 ...as a child of a sibling-shell.sh process" "sibling-shell.sh" "$(basename "$(cmdline "$(launch_ppid 1)" | awk '{print $2}')")"

# R9. Every tab command runs the wrapper, on every backend that can run it; bare claude elsewhere.
sandbox; n=$(nameFor R9)
cmds() { recycle -- --dry-run --terminal "$1" "$n" go --model haiku --mode auto; }
tabline() { printf '%s\n' "$OUT" | grep -E '^[[:space:]]*(command|by hand) '; }   # the command, not the pgrep note beside it
for b in tmux tmux-detached linux-xterm linux-kitty macos-terminal macos-iterm wsl-wt wsl-conhost; do
  run_in_sb $(sb_wsl_env) -- bash "$RECYCLE" --repo "$SB/repo" --dry-run --terminal "$b" "$n" go --model haiku --mode auto
  has "R9 $b runs the wrapper" "sibling-shell.sh $n --mode auto --model haiku go" "$(tabline)"
  hasnt "R9 $b has no bare claude --name" "claude --name" "$(tabline)"
done
for b in manual gitbash-cmd; do
  run_in_sb -- bash "$RECYCLE" --repo "$SB/repo" --dry-run --terminal "$b" "$n" go --model haiku --mode auto
  has "R9 $b keeps a bare claude" "claude --name $n --permission-mode auto --model haiku go" "$(tabline)"
  hasnt "R9 $b does not use the wrapper" "sibling-shell.sh" "$(tabline)"
done
run_in_sb LAUNCH_NO_WRAPPER=1 -- bash "$RECYCLE" --repo "$SB/repo" --dry-run --terminal tmux "$n" go --model haiku
has "R9 LAUNCH_NO_WRAPPER=1 keeps a bare claude" "claude --name $n --model haiku go" "$(tabline)"; hasnt "R9 ...and no wrapper" "sibling-shell.sh" "$(tabline)"
# the tab command carries no bare `;` and no quote on WSL (wt.exe splits on `;`, quotes cross Windows argv)
run_in_sb $(sb_wsl_env) -- bash "$RECYCLE" --repo "$SB/repo" --dry-run --terminal wsl-wt "$n" go --model 'sonnet[1m]'
line="$(tabline)"
renomatch "R9 wsl command has no bare ;" '(^|[^\\]);' "$line"; hasnt "R9 wsl command has no double quote" '"' "$line"
# a wrapper path with a space cannot cross the WSL command line: bare claude, and the user is told
mkdir -p "$SB/with space"; cp -R "$ROOT/scripts" "$SB/with space/scripts"
run_in_sb $(sb_wsl_env) -- bash "$SB/with space/scripts/recycle-sibling.sh" --repo "$SB/repo" --dry-run --terminal wsl-wt "$n" go --model haiku
has "R9 spaced wrapper path on WSL: bare claude" "claude --name $n --model haiku go" "$(tabline)"; hasnt "R9 ...no wrapper" "sibling-shell.sh" "$(tabline)"
run_in_sb -- bash "$SB/with space/scripts/recycle-sibling.sh" --repo "$SB/repo" --dry-run --terminal tmux "$n" go --model haiku
has "R9 spaced wrapper path elsewhere is fine (quoted)" "sibling-shell.sh $n --model haiku go" "$(tabline)"
# start-team opens its tabs under the wrapper too
run_in_sb -- bash "$ROOT/scripts/start-team.sh" --repo "$SB/repo" --dry-run --terminal tmux --seat ZzSeat --prefix ZzSib --siblings 1
has "R9 start-team: tab command runs the wrapper" "sibling-shell.sh ZzSeat" "$(tabline)"

# R10. The ps fallback (macOS, BSD: no /proc) decides exactly as the /proc path does.
sandbox; mine=$(nameFor RAa); other=$(nameFor RAb); control=$(nameFor RAc); loose=$(nameFor RAd)
stand_in_wrapper "$other" "$mine" ""
stand_in_wrapper "$control" "$control" ""
( exec -a "claude --name $loose x" sleep 120 ) </dev/null >/dev/null 2>&1 &
LP=$!; disown "$LP"; PIDS+=("$LP"); wait_for "loose claude" pgrep -f "^claude --name ${loose}( |\$)"
for NOPROC in "" 1; do
  tag="${NOPROC:+ps}"; tag="${tag:-/proc}"
  recycle LAUNCH_NO_PROC=$NOPROC -- --dry-run "$control"; rematch "R10 [$tag] matching Name: in-place" '^mode: in-place$' "$OUT"
  recycle LAUNCH_NO_PROC=$NOPROC -- --dry-run "$mine";    rematch "R10 [$tag] other wrapper's Name: new-tab" '^mode: new-tab$' "$OUT"
  recycle LAUNCH_NO_PROC=$NOPROC -- --dry-run "$loose";   rematch "R10 [$tag] started by hand: new-tab" '^mode: new-tab$' "$OUT"
done
kill -KILL "$LP" 2>/dev/null
# the ancestor guard on the ps path
sandbox; n=$(nameFor RAe)
stand_in_wrapper "$n" "$n" "bash $RECYCLE --repo $SB/repo --terminal linux-xterm --dry-run $n > $SB/inside.out 2> $SB/inside.err
sleep 120" "${FORBID[@]}" LAUNCH_NO_PROC=1
wait_for "recycle output from inside (ps path)" grep -q '^mode:' "$SB/inside.out"
rematch "R10 [ps] ancestor guard: detach, in-place" '^detach: yes$' "$(cat "$SB/inside.out")"
rematch "R10 [ps] ancestor guard: in-place" '^mode: in-place$' "$(cat "$SB/inside.out")"

# ---- self-recycle: the seat detaches a copy of the script out of the old claude's process tree ----
# pids of detached recycle copies for <Name>: recycle-sibling.sh processes that carry RECYCLE_DETACHED.
detached_copies() {  # <Name>
  local p; for p in $(pgrep -f "recycle-sibling\.sh .*$1" 2>/dev/null || true); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q '^RECYCLE_DETACHED='; then echo "$p"; fi
  done
}
have_copy() { [ -n "$(detached_copies "$1")" ]; }
ppid_chain() { local p; p="$(ppid_of "$1")"; while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do echo "$p"; p="$(ppid_of "$p")"; done; }
sid_of() { sed 's/^.*) //' "/proc/$1/stat" | awk '{print $4}'; }
launches_ge() { [ "$(nlaunch)" -ge "$1" ]; }
file_has() { grep -Eq -- "$2" "$1" 2>/dev/null; }

# R11. The REAL seat self-recycle under the wrapper: launch 1 is the seat and runs the real recycle script
#      from inside itself (a tab would be a failure: the terminal is forbidden). The call returns at once
#      and PRINTS the log path; a detached copy outside the old claude's tree and session then does the
#      in-place hand-off, SIGTERMs only the old claude, and the fresh one starts under the SAME wrapper.
#      The seat runs on a non-default account: the copy must hand that account on (a dropped account would launch the
#      fresh seat on the default account with CLAUDE_CONFIG_DIR unset).
sandbox; n=$(nameFor R11)
acct="$SB/home/.claude-acct4"; mkdir -p "$acct"; echo '{}' > "$acct/.credentials.json"
printf self-recycle > "$SB/stub/mode.1"; printf term-trap > "$SB/stub/mode.2"
start_wrapper "$n" "SELF_RECYCLE_CMD=bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n go --model haiku" \
  FAKE_TERM_MODE=forbid RECYCLE_DETACH_DELAY=4 CLAUDE_CONFIG_DIR="$acct"
W11=$WPID; OLD="$(launch_pid 1)"
wait_for "the seat's recycle call to return" file_has "$SB/stub/self.out" 'log:'
t_returned="$(date +%s.%N)"
logp="$(sed -n 's/.*log: //p' "$SB/stub/self.out" | head -1)"
has "R11 the printed log is in the state dir" "$SB/state" "$logp"
wait_for "the detached copy" have_copy "$n"
copy="$(detached_copies "$n" | head -1)"
hasnt "R11 the copy is not below the old claude" " $OLD " " $(ppid_chain "$copy" | tr '\n' ' ') "
ne "R11 the copy has its own session" "$(sid_of "$OLD")" "$(sid_of "$copy")"
alive "$OLD" && ok || bad "R11 the delay has not run out: the old claude is still up"
wait_for "the fresh claude" launches_ge 2
eq "R11 the fresh claude is a child of the SAME wrapper" "$W11" "$(launch_ppid 2)"
wait_for "old claude gone" not_alive "$OLD"
eq "R11 the old claude was SIGTERMed" "TERM" "$(cat "$SB/stub/sigterm.$OLD" 2>/dev/null)"
# RECYCLE_DETACH_DELAY=4: the SIGTERM lands about 4 s after the seat's call returned, so its own tool call
# can reach the transcript first. 3 s of slack for the poll; a copy with no delay lands it in well under 1 s.
awk -v a="$(cat "$SB/stub/sigterm-at.$OLD" 2>/dev/null || echo 0)" -v b="$t_returned" 'BEGIN{exit !(a-b>=3.0)}' \
  && ok || bad "R11 the SIGTERM landed $(awk -v a="$(cat "$SB/stub/sigterm-at.$OLD" 2>/dev/null || echo 0)" -v b="$t_returned" 'BEGIN{printf "%.2f", a-b}') s after the seat's call returned; want >= 3 (RECYCLE_DETACH_DELAY=4)"
alive "$W11" && ok || bad "R11 the wrapper was never signalled"
last_arg_is 2 go && ok || bad "R11 the prompt reached the fresh claude"
absent "R11 hand-off consumed" "$SB/state/$n.next"; absent "R11 no tab" "$SB/TERM-WAS-CALLED"
eq "R11 the seat itself runs on the account" "$acct" "$(launch_cfg 1)"
eq "R11 the fresh launch carries the seat's account" "$acct" "$(launch_cfg 2)"
wait_for "the copy's summary in the printed log" file_has "$logp" 'fresh .*mode: in-place'
has "R11 the copy's summary names the inherited account" "$acct" "$(cat "$logp")"

# R12. A copy that cannot leave the old claude's tree falls back to the new tab. The old claude is a child
#      SUBREAPER (it adopts every orphan below it), so the detached copy is reparented INTO its tree. After
#      RECYCLE_DETACH_WAIT the copy gives up on in-place and uses launch-first-then-kill, which survives
#      losing the parent chain. The outcome alone cannot tell the paths apart (an in-place attempt kills
#      the old claude first, then falls back to a tab anyway), so the old claude records whether the tab
#      already existed when its SIGTERM landed.
sandbox; n=$(nameFor R12); d="$SB/subreaper"; mkdir -p "$d"
cat > "$d/subreaper.py" <<EOF_PY
import ctypes, os
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)
os.execv("/bin/bash", ["claude --name $n x", "$d/child.sh"])
EOF_PY
cat > "$d/child.sh" <<EOF_SH
trap 'if [ -e $SB/fake-term.args ]; then echo tab-first; else echo term-first; fi > $SB/sub.term; exit 0' TERM
bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n go --model haiku > $SB/sub.out 2>&1
sleep 120 & wait \$!
EOF_SH
stand_in_wrapper "$n" "$n" "exec python3 $d/subreaper.py" STUB_MODE=term-trap RECYCLE_DETACH_WAIT=2 RECYCLE_DETACH_DELAY=0
wait_for "the old claude's SIGTERM record" test -f "$SB/sub.term"
eq "R12 the tab existed before the old claude was signalled" "tab-first" "$(cat "$SB/sub.term")"
has "R12 the new tab runs the WRAPPER" "sibling-shell.sh" "$(cat "$SB/fake-term.args")"
logp="$(sed -n 's/.*log: //p' "$SB/sub.out" | head -1)"
wait_for "the copy's note" file_has "$logp" 'still inside .*falling back to a new tab'
rematch "R12 the copy says it fell back" 'still inside .*falling back to a new tab' "$(cat "$logp")"
rematch "R12 the copy's summary says new-tab" 'mode: new-tab' "$(cat "$logp")"

# R13. The copy waits out the window in which its launcher is still alive, then stays in place (no spurious
#      new tab). `setsid -f` normally orphans the copy within milliseconds, but until the launching script
#      has exited the copy IS inside the old claude's tree. A setsid shim that keeps the script alive for
#      1.5 s widens that window: a copy that checked once and gave up would open a tab here.
sandbox; n=$(nameFor R13)
printf '%s\n' '#!/usr/bin/env bash' '[ "${1:-}" != -f ] || shift' '"$@" &' 'sleep 1.5' > "$SB/bin/setsid"; chmod +x "$SB/bin/setsid"
printf self-recycle > "$SB/stub/mode.1"; printf term-trap > "$SB/stub/mode.2"
start_wrapper "$n" "SELF_RECYCLE_CMD=bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n go --model haiku" \
  FAKE_TERM_MODE=forbid RECYCLE_DETACH_DELAY=0
W13=$WPID
wait_for "the fresh claude" launches_ge 2
eq "R13 the fresh claude is a child of the SAME wrapper" "$W13" "$(launch_ppid 2)"
absent "R13 no spurious tab" "$SB/TERM-WAS-CALLED"
logp="$(sed -n 's/.*log: //p' "$SB/stub/self.out" | head -1)"
wait_for "the copy's summary" file_has "$logp" 'fresh .*mode: in-place'
renomatch "R13 the copy never fell back" 'falling back' "$(cat "$logp")"

# R14. No `setsid` (macOS): a self-recycle uses the new tab, not a half-detach, and says why. A PATH holding
#      every tool the script needs EXCEPT setsid; the old claude is under the wrapper and the script runs
#      inside it, so the missing setsid alone separates detach from new-tab.
sandbox; n=$(nameFor R14); tools="$SB/tools-no-setsid"; mkdir -p "$tools"
for t in bash env sleep pgrep awk tr sed head wc dirname basename mkdir cat date sort grep uname id cut readlink ps base64 mv rm; do
  tp="$(command -v "$t" 2>/dev/null || true)"; [ -z "$tp" ] || ln -s "$tp" "$tools/$t"
done
ln -s "$SB/bin/xterm" "$tools/xterm"
[ ! -e "$tools/setsid" ] && ok || bad "R14 setsid must be absent from the test PATH"
stand_in_wrapper "$n" "$n" "bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n > $SB/nosetsid.out 2> $SB/nosetsid.err
sleep 120" DRY_RUN=1 FAKE_TERM_MODE=forbid PATH="$tools"
wait_for "recycle output without setsid" file_has "$SB/nosetsid.out" '^mode:'
rematch "R14 new-tab" '^mode: new-tab$' "$(cat "$SB/nosetsid.out")"
rematch "R14 no detach" '^detach: no$' "$(cat "$SB/nosetsid.out")"
rematch "R14 says setsid is missing" 'setsid is missing' "$(cat "$SB/nosetsid.err")"

# R15. Fork guard: a detached copy (RECYCLE_DETACHED set) never detaches again. One still inside the old
#      claude's tree and detaching AGAIN would respawn itself without end; DRY_RUN never forks, so the
#      decision is read without risking that: the copy must say detach: no and fall back to new-tab.
sandbox; n=$(nameFor R15)
stand_in_wrapper "$n" "$n" "bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n > $SB/copy.out 2> $SB/copy.err
sleep 120" DRY_RUN=1 FAKE_TERM_MODE=forbid RECYCLE_DETACHED=1 RECYCLE_DETACH_WAIT=1
wait_for "the copy's decision" file_has "$SB/copy.out" '^mode:'
rematch "R15 new-tab" '^mode: new-tab$' "$(cat "$SB/copy.out")"
rematch "R15 no detach" '^detach: no$' "$(cat "$SB/copy.out")"
rematch "R15 says it is still inside" 'still inside' "$(cat "$SB/copy.err")"
renomatch "R15 did not detach again" 'detaching a copy' "$(cat "$SB/copy.err")"

# R16. A self-recycle whose old claude is NOT under the wrapper stays new-tab with no detach: nothing would
#      relaunch it in place. Same ancestry as R8 (the script runs inside the claude it targets), but the
#      claude's parent is an ordinary shell, not a sibling-shell.sh <Name>.
sandbox; n=$(nameFor R16); d="$SB/no-wrapper"; mkdir -p "$d"
printf '%s\n' "bash $RECYCLE --repo $SB/repo --terminal linux-xterm $n > $SB/nw.out 2> $SB/nw.err" "sleep 120" > "$d/child.sh"
words=(); while IFS= read -r w; do words+=("$w"); done < <(sbenv DRY_RUN=1 FAKE_TERM_MODE=forbid)
env -u CLAUDE_CONFIG_DIR "${words[@]}" bash -c "exec -a 'claude --name $n x' bash $d/child.sh" </dev/null >/dev/null 2>&1 &
LP=$!; disown "$LP"; PIDS+=("$LP")
wait_for "recycle output from an unwrapped claude" file_has "$SB/nw.out" '^mode:'
rematch "R16 new-tab" '^mode: new-tab$' "$(cat "$SB/nw.out")"
rematch "R16 no detach" '^detach: no$' "$(cat "$SB/nw.out")"
renomatch "R16 no detach note" 'detach' "$(cat "$SB/nw.err")"

finish
