#!/usr/bin/env bash
# Tests for scripts/gate-throttle.sh and scripts/quiet-mode.sh: exit code, slot limit, first-come order,
# dead tickets, quiet mode, the priority slot, load admission, stale locks, gate_slots from the team block,
# the no-flock fallback, and --log (commit and dirty count first, read when the slot is taken; exit code
# last). Every run uses a private runtime dir and a fast poll.
# Run: bash tests/gate-throttle.test.sh   (needs bash, git, flock, timeout; skips without flock)
# Every direct call carries a timeout, so a regression that blocks shows as a FAIL, not a hung suite.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
# the disk guard (scripts/gate-disk-guard.sh) refuses under 20 GB free: this suite is about throttling, not disk, so it must not turn red on a full host
export KIT_GATE_MIN_FREE_GB=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; GT="$ROOT/scripts/gate-throttle.sh"; QM="$ROOT/scripts/quiet-mode.sh"
command -v flock >/dev/null 2>&1 || { echo "gate-throttle: skipped (no flock)"; exit 0; }
command -v timeout >/dev/null 2>&1 || { echo "gate-throttle: skipped (no timeout)"; exit 0; }
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export KIT_RUNTIME_DIR="$TMP/rt" GATE_POLL=0.1 GATE_MAX_LOAD=1000000 LOG="$TMP/log"
# These tests start several throttles from one directory on purpose; the one-slot-per-worktree rule has its own tests (gate-throttle-port).
export GATE_ALLOW_SECOND_SLOT=1
export KIT_DSTATE_COUNT_FILE="$TMP/dzero"; echo 0 > "$TMP/dzero"   # no /proc scan (it sleeps a second per poll when a task sits in D state)
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }

# A payload that logs "start X", holds until $TMP/release-X exists, then logs "end X".
HOLD="$TMP/hold.sh"
cat > "$HOLD" <<'EOF'
#!/usr/bin/env bash
echo "start $1" >> "$LOG"
while [ ! -e "$(dirname "$LOG")/release-$1" ] && [ -d "$(dirname "$LOG")" ]; do sleep 0.05; done   # never outlive the sandbox
echo "end $1" >> "$LOG"
EOF
release() { : > "$TMP/release-$1"; }
waitfor() {  # <text> [seconds] — wait until the log has the line
  local i=0 n=$(( ${2:-10} * 20 ))
  while ! grep -qx "$1" "$LOG" 2>/dev/null; do i=$((i+1)); [ "$i" -gt "$n" ] && return 1; sleep 0.05; done
}
bg() {  # <name> [dir] — start a throttled HOLD in the background (from dir, default $TMP)
  (cd "${2:-$TMP}" && exec bash "$GT" bash "$HOLD" "$1" 2>>"$TMP/err") & PIDS+=($!)
}
order() { grep '^start' "$LOG" | cut -d' ' -f2 | tr '\n' ' '; }
reset() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=(); rm -rf "$TMP/rt" "$LOG" "$TMP"/release-* "$TMP/err"; }

# 1. exit code passes through; usage error is 64
GATE_SLOTS=1 timeout 20 bash "$GT" bash -c 'exit 7' 2>/dev/null; [ $? -eq 7 ] && ok || bad "exit code of the command is not passed through"
timeout 20 bash "$GT" 2>/dev/null; [ $? -eq 64 ] && ok || bad "no command: want exit 64"

# 2. one slot: B waits for A; 3. first come, first served: B (queued first) runs before C
reset; export GATE_SLOTS=1
bg A; waitfor "start A" || bad "A never started"
bg B; sleep 0.4; bg C; sleep 0.4
has "one slot: only A runs while A holds it" "A " "$(order)"
[ "$(order)" = "A " ] && ok || bad "one slot: something started beside A: $(order)"
release A; waitfor "start B" || bad "B never started after A released"
sleep 0.4; [ "$(order)" = "A B " ] && ok || bad "first come: want 'A B ' while B holds, got '$(order)'"
release B; waitfor "start C" || bad "C never started"; release C; waitfor "end C"
[ "$(order)" = "A B C " ] && ok || bad "first come: want A B C, got $(order)"

# 4. a dead waiter's ticket is skipped (and deleted)
reset
bg A; waitfor "start A"
# a pid known to be dead: a child this shell started and reaped (a fixed number can be live on big pid_max hosts)
sleep 0 & dead=$!; wait "$dead"
mkdir -p "$KIT_RUNTIME_DIR/queue"; printf '%s\n%s\n' "$TMP" "Mon Jan  1 00:00:00 2001" > "$KIT_RUNTIME_DIR/queue/0000000000.$dead"
bg B; sleep 0.3; release A; waitfor "start B" 5 && ok || bad "a dead ticket ahead blocked the line"
[ ! -e "$KIT_RUNTIME_DIR/queue/0000000000.$dead" ] && ok || bad "the dead ticket was not deleted"
release B; waitfor "end B"

# 4b. pid reuse: a ticket whose pid is LIVE but belongs to another process (its start time differs) is dead.
#     Tickets survive a reboot by design, so after one a stale ticket's pid can be anyone's.
reset
sleep 60 & squat=$!; PIDS+=("$squat")
mkdir -p "$KIT_RUNTIME_DIR/queue"; printf '%s\n%s\n' "$TMP/gone" "Mon Jan  1 00:00:00 2001" > "$KIT_RUNTIME_DIR/queue/0000000000.$squat"
GATE_SLOTS=1 timeout 10 bash "$GT" bash -c 'echo reuse-ok >> "$LOG"' 2>/dev/null
grep -qx reuse-ok "$LOG" && ok || bad "a stale ticket on a reused (live) pid blocked the line"
[ ! -e "$KIT_RUNTIME_DIR/queue/0000000000.$squat" ] && ok || bad "the stale reused-pid ticket was not deleted"
# ...and a ticket with the RIGHT start time for that live pid still holds its place
pstart() { if [ -r "/proc/$1/stat" ]; then sed 's/^.*) //' "/proc/$1/stat" | cut -d' ' -f20; else ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; fi; }   # the throttle's start-time form
printf '%s\n%s\n' "$TMP/live" "$(pstart "$squat")" > "$KIT_RUNTIME_DIR/queue/0000000000.$squat"
GATE_SLOTS=1 timeout 2 bash "$GT" bash -c 'echo jumped >> "$LOG"' 2>/dev/null
! grep -qx jumped "$LOG" && ok || bad "a live waiter's ticket (right start time) was skipped"
out="$(bash "$QM" status)"; has "quiet-mode status lists the live waiter with its dir" "pid $squat  $TMP/live" "$out"
# a ticket whose pid is alive but whose recorded start time is someone else's must NOT be listed as waiting
sleep 60 & sq2=$!; PIDS+=("$sq2")
printf '%s\n%s\n' "$TMP/wrongstart" "Mon Jan  1 00:00:00 2001" > "$KIT_RUNTIME_DIR/queue/0000000001.$sq2"
out="$(bash "$QM" status)"
hasnt "quiet-mode status skips a ticket whose start time does not match its live pid" "$TMP/wrongstart" "$out"
has "quiet-mode status still lists the real waiter beside it" "$TMP/live" "$out"
rm -f "$KIT_RUNTIME_DIR/queue/0000000001.$sq2"; kill "$sq2" 2>/dev/null; wait "$sq2" 2>/dev/null
kill "$squat" 2>/dev/null; wait "$squat" 2>/dev/null

# 5. quiet mode: no new start while on; starts after off; GATE_IGNORE_QUIET=1 bypasses
reset
out="$(bash "$QM" on)"; has "quiet-mode on: says ON" "quiet mode: ON" "$out"
bg A; sleep 0.6; ! grep -q "start A" "$LOG" 2>/dev/null && ok || bad "quiet mode: A started while quiet mode was on"
has "quiet mode: the waiter says why" "QUIET MODE is on" "$(cat "$TMP/err")"
out="$(bash "$QM" status)"; has "quiet-mode status lists the waiter" "#1 pid" "$out"
GATE_IGNORE_QUIET=1 timeout 20 bash "$GT" bash -c 'echo bypass >> "$LOG"' 2>/dev/null
grep -qx bypass "$LOG" && ok || bad "GATE_IGNORE_QUIET=1 did not bypass quiet mode"
bash "$QM" off >/dev/null; waitfor "start A" 5 && ok || bad "A did not start after quiet mode turned off"
out="$(bash "$QM" status)"; has "quiet-mode status shows the running command" "hold.sh A" "$out"
release A; waitfor "end A"

# 6. the priority slot: a prio-listed dir runs while the normal slot is held and others queue
reset
mkdir -p "$TMP/train" "$KIT_RUNTIME_DIR"; printf '%s\n' "$(cd "$TMP/train" && pwd -P)" > "$KIT_RUNTIME_DIR/gate-priority.txt"
bg A; waitfor "start A"; bg B; sleep 0.3
bg P "$TMP/train"; waitfor "start P" 5 && ok || bad "priority: the train dir did not get the priority slot"
! grep -q "start B" "$LOG" && ok || bad "priority: B jumped the queue"
release A; release B; release P; waitfor "end B"; waitfor "end P"

# 7. load admission: the head waits while load is high; the priority slot ignores load
reset
echo "99.00 1 1 1/1 1" > "$TMP/loadavg"
KIT_LOADAVG_FILE="$TMP/loadavg" GATE_MAX_LOAD=4 bg A; sleep 0.6
! grep -q "start A" "$LOG" 2>/dev/null && ok || bad "load: A started at load 99 >= 4"
has "load: the waiter says why" "holding: load 99.00" "$(cat "$TMP/err")"
mkdir -p "$TMP/train"; printf '%s\n' "$(cd "$TMP/train" && pwd -P)" > "$KIT_RUNTIME_DIR/gate-priority.txt"
KIT_LOADAVG_FILE="$TMP/loadavg" GATE_MAX_LOAD=4 bg P "$TMP/train"; waitfor "start P" 5 && ok || bad "load: the priority slot waited on load"
# While the priority gate P runs, deploy mode holds new normal gates by design (tests/gate-throttle-deploy.test.sh), so A can only
# start once P has finished AND the load has dropped.
echo "1.00 1 1 1/1 1" > "$TMP/loadavg"; sleep 0.8
! grep -q "start A" "$LOG" 2>/dev/null && ok || bad "load: A started while the priority gate P (deploy mode) still ran"
release P; waitfor "end P" 5; waitfor "start A" 5 && ok || bad "load: A did not start once P finished and load dropped"
release A; release P; waitfor "end A"; waitfor "end P"

# 8. a lock FILE left by a dead holder (e.g. after a reboot) is not a held lock
reset; mkdir -p "$KIT_RUNTIME_DIR/locks"; : > "$KIT_RUNTIME_DIR/locks/gate-slot-1.lock"
timeout 20 bash "$GT" bash -c 'echo stale-ok >> "$LOG"' 2>/dev/null; grep -qx stale-ok "$LOG" && ok || bad "a leftover lock file blocked the slot"

# 9. gate_slots from the team block (read from the main checkout, also from a worktree); GATE_SLOTS overrides
reset; unset GATE_SLOTS
R="$TMP/repo"; git init -q -b main "$R"; mkdir -p "$R/docs/orchestration"
printf 'team:\n  seat: Orca\n  gate_slots:       2\n' > "$R/docs/orchestration/ORCHESTRATION.md"
git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TMP/wt" -b wt 2>/dev/null
bg A "$TMP/wt"; bg B "$TMP/wt"; waitfor "start A" && waitfor "start B" && ok || bad "gate_slots: 2 did not give two slots"
bg C "$TMP/wt"; sleep 0.5; ! grep -q "start C" "$LOG" && ok || bad "gate_slots: 2 ran a third"
release A; waitfor "start C" 5 && ok || bad "gate_slots: C did not take the freed slot"
release B; release C; waitfor "end C"
reset; (cd "$R" && GATE_SLOTS=1 timeout 20 bash "$GT" bash -c 'echo env-ok >> "$LOG"' 2>/dev/null); grep -qx env-ok "$LOG" && ok || bad "GATE_SLOTS env did not run"

# 9b. a daemon the command leaves behind does not keep the slot (the command runs with the lock fd closed)
reset
GATE_SLOTS=1 timeout 10 bash "$GT" bash -c 'sleep 30 & echo $! > "$(dirname "$LOG")/daemon.pid"' 2>/dev/null
[ -s "$TMP/daemon.pid" ] && PIDS+=("$(cat "$TMP/daemon.pid")")
GATE_SLOTS=1 timeout 5 bash "$GT" bash -c 'echo after-daemon >> "$LOG"' 2>/dev/null
grep -qx after-daemon "$LOG" && ok || bad "a background child of the previous command still held the only slot"
kill "$(cat "$TMP/daemon.pid")" 2>/dev/null

# 9c. the default runtime dir is under HOME, never /tmp, and both scripts agree on it (quiet mode is a file
#     they share: if they disagreed, quiet mode would silently do nothing)
H="$TMP/home"; mkdir -p "$H"
out="$(env -u KIT_RUNTIME_DIR HOME="$H" bash "$QM" on)"
[ -f "$H/.orcastration-kit/runtime/quiet-mode" ] && ok || bad "quiet-mode default flag is not at \$HOME/.orcastration-kit/runtime/quiet-mode"
env -u KIT_RUNTIME_DIR HOME="$H" GATE_SLOTS=1 timeout 2 bash "$GT" bash -c 'echo default-dir >> "$LOG"' 2>/dev/null
! grep -qx default-dir "$LOG" 2>/dev/null && ok || bad "gate-throttle did not see quiet mode at the default dir (the two scripts disagree)"
[ -d "$H/.orcastration-kit/runtime/locks" ] && ok || bad "gate-throttle default runtime dir is not under HOME"
grep -n 'KIT_RUNTIME_DIR:-' "$GT" "$QM" | grep -q '/tmp' && bad "a default runtime dir names /tmp" || ok
env -u KIT_RUNTIME_DIR HOME="$H" bash "$QM" off >/dev/null

# 10. no flock: warns and runs unthrottled
out="$(KIT_FLOCK_BIN=/nonexistent/flock timeout 20 bash "$GT" bash -c 'echo ran' 2>&1)"
has "no flock: still runs the command" "ran" "$out"; has "no flock: says it is unthrottled" "UNTHROTTLED" "$out"

# 11. --log: commit and dirty count first, the command's output, exit code last; the slot line stays on stderr
reset; export GATE_SLOTS=1
L="$TMP/repo-log"; git init -q -b main "$L"
git -C "$L" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
err="$(cd "$L" && timeout 20 bash "$GT" --log "$TMP/gate.log" bash -c 'echo to-out; echo to-err >&2; exit 7' 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 7 ] && ok || bad "--log: exit code not passed through (got $rc)"
[ "$(sed -n 1p "$TMP/gate.log")" = "SHA $(git -C "$L" rev-parse HEAD)" ] && ok || bad "--log: line 1 is not the commit: $(sed -n 1p "$TMP/gate.log")"
sed -n 2p "$TMP/gate.log" | grep -Eq '^started [0-9]{2}:[0-9]{2}:[0-9]{2} dirty=0$' && ok || bad "--log: line 2 is not 'started HH:MM:SS dirty=0': $(sed -n 2p "$TMP/gate.log")"
has "--log: stdout in the log" "to-out" "$(cat "$TMP/gate.log")"; has "--log: stderr in the log" "to-err" "$(cat "$TMP/gate.log")"
[ "$(tail -n 1 "$TMP/gate.log")" = "exit 7" ] && ok || bad "--log: last line is not 'exit 7': $(tail -n 1 "$TMP/gate.log")"
has "--log: the slot line stays on stderr" "slot 1 acquired" "$err"; hasnt "--log: the slot line is not in the log" "acquired" "$(cat "$TMP/gate.log")"

# 11a. --log on a tree with uncommitted or untracked paths is refused: gate evidence must name a committed tree
: > "$L/untracked"
err="$(cd "$L" && timeout 20 bash "$GT" --log "$TMP/dirty.log" bash -c 'echo dirty-ran' 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 65 ] && ok || bad "--log dirty: want exit 65, got $rc"
hasnt "--log dirty: the command did not run" "dirty-ran" "$(cat "$TMP/dirty.log")"
has "--log dirty: the log says why" "REFUSED dirty=1" "$(cat "$TMP/dirty.log")"; has "--log dirty: stderr says why" "REFUSED" "$err"
(cd "$L" && timeout 20 bash "$GT" bash -c 'echo plain-ran' 2>/dev/null) | grep -q plain-ran && ok || bad "a plain run (no --log) on a dirty tree still runs"
rm -f "$L/untracked"

# 11a2. --log: a tree that changes DURING the run makes it void (exit 66): an edit or a commit while the gate runs
err="$(cd "$L" && timeout 20 bash "$GT" --log "$TMP/void.log" bash -c 'echo mid > probe.txt; exit 0' 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 66 ] && ok || bad "--log changed tree: want exit 66, got $rc"
has "--log changed tree: the log says VOID" "VOID: the tree changed during the run" "$(cat "$TMP/void.log")"
has "--log changed tree: the log names the path" "probe.txt" "$(cat "$TMP/void.log")"
[ "$(tail -n 1 "$TMP/void.log")" = "exit 66" ] && ok || bad "--log changed tree: last line is not 'exit 66'"
has "--log changed tree: stderr says VOID" "VOID" "$err"
rm -f "$L/probe.txt"
(cd "$L" && timeout 20 bash "$GT" --log "$TMP/void2.log" bash -c 'git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m mid' 2>/dev/null); rc=$?
[ "$rc" -eq 66 ] && ok || bad "--log commit during the run: want exit 66, got $rc"
(cd "$L" && timeout 20 bash "$GT" --log "$TMP/void3.log" bash -c 'exit 3' 2>/dev/null); rc=$?
[ "$rc" -eq 3 ] && ok || bad "--log unchanged tree: the command's own exit code passes through (got $rc)"

# 11b. --log reads the commit when the slot is taken, not while waiting: a commit made in the queue is the one logged
reset; export GATE_SLOTS=1
bg A; waitfor "start A" || bad "--log queue: A never started"
(cd "$L" && exec bash "$GT" --log "$TMP/queued.log" bash -c 'echo queued-ran >> "$LOG"' 2>>"$TMP/err") & PIDS+=($!); qpid=$!
sleep 0.4; ! grep -q queued-ran "$LOG" && ok || bad "--log queue: the logged run did not wait for the slot"
git -C "$L" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m two
release A; wait "$qpid"
[ "$(sed -n 1p "$TMP/queued.log")" = "SHA $(git -C "$L" rev-parse HEAD)" ] && ok || bad "--log queue: logged $(sed -n 1p "$TMP/queued.log"), want the commit made while it waited"

# 11c. --log usage and an unwritable log; no flock still writes the log
timeout 20 bash "$GT" --log 2>/dev/null; [ $? -eq 64 ] && ok || bad "--log with no file: want exit 64"
timeout 20 bash "$GT" --log "$TMP/x.log" 2>/dev/null; [ $? -eq 64 ] && ok || bad "--log with no command: want exit 64"
timeout 20 bash "$GT" --log "$TMP/no/such/dir/x.log" true 2>/dev/null; [ $? -eq 73 ] && ok || bad "--log to an unwritable path: want exit 73"
(cd "$L" && KIT_FLOCK_BIN=/nonexistent/flock timeout 20 bash "$GT" --log "$TMP/noflock.log" bash -c 'echo nf-ran' 2>/dev/null)
[ "$(sed -n 1p "$TMP/noflock.log")" = "SHA $(git -C "$L" rev-parse HEAD)" ] && [ "$(tail -n 1 "$TMP/noflock.log")" = "exit 0" ] && ok \
  || bad "no flock: --log did not write SHA first and exit last: $(cat "$TMP/noflock.log")"
# 12. memory admission: the second normal slot only while MemAvailable >= GATE_MIN_FREE_MB (default 3072);
#     below it one normal slot at a time. KIT_MEMINFO_FILE fakes /proc/meminfo; unreadable = admit.
meminfo() { printf 'MemTotal:       16000000 kB\nMemFree:          100000 kB\nMemAvailable:   %d kB\n' "$(( $1 * 1024 ))" > "$TMP/meminfo"; }
two_run() {  # <label> <expect: together|alone> — A holds, B queued; do they run together?
  bg A; waitfor "start A" || bad "$1: A never started"
  bg B; sleep 0.6
  if [ "$2" = together ]; then [ "$(order)" = "A B " ] && ok || bad "$1: want A and B together, got '$(order)'"
  else [ "$(order)" = "A " ] && ok || bad "$1: want only A, got '$(order)'"; fi
}
reset; export GATE_SLOTS=2 KIT_MEMINFO_FILE="$TMP/meminfo"; unset GATE_MIN_FREE_MB
meminfo 1000; two_run "low memory (1000 MB)" alone
release A; waitfor "start B" || bad "low memory: B never started after A released"; release B; waitfor "end B"
reset; meminfo 8000; two_run "ample memory (8000 MB)" together
reset; meminfo 3072; two_run "exactly the floor (3072 MB)" together
reset; rm -f "$TMP/meminfo"; two_run "unreadable meminfo" together
reset; meminfo 1000; GATE_MIN_FREE_MB=500 two_run "knob GATE_MIN_FREE_MB=500 with 1000 MB" together
reset; unset KIT_MEMINFO_FILE

# Killed while queued: an outer timeout that fires before the slot is held leaves a record that the command
# never ran (before: an empty --log and exit 124, read as a real timeout). Killed after the slot: no such line.
reset
GATE_SLOTS=1 bg QA; waitfor "start QA" 5
(cd "$TMP" && GATE_SLOTS=1 timeout 2 bash "$GT" --log "$TMP/q.log" bash -c 'echo queued-ran >> "$LOG"' 2>"$TMP/qerr"); qrc=$?
[ "$qrc" -eq 124 ] && ok || bad "killed in the queue: want timeout's 124, got $qrc"
has "the --log says the command never ran" "KILLED WHILE QUEUED after" "$(cat "$TMP/q.log" 2>/dev/null)"
has "stderr says it too" "KILLED WHILE QUEUED" "$(cat "$TMP/qerr")"
! grep -qx queued-ran "$LOG" && ok || bad "the queued command ran"
release QA; waitfor "end QA" 5
(cd "$TMP" && GATE_SLOTS=1 timeout 1 bash "$GT" --log "$TMP/r.log" bash -c 'echo slot-ran >> "$LOG"; sleep 5' 2>/dev/null)
grep -qx slot-ran "$LOG" && ok || bad "the command did not start once the slot was free"
hasnt "a run killed after taking the slot is not called queued" "QUEUED" "$(cat "$TMP/r.log" 2>/dev/null)"

echo "gate-throttle: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
