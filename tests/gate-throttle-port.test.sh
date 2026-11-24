#!/usr/bin/env bash
# Tests for the gate-throttle.sh features ported from a project that has run the throttle daily (ORCA322-7):
#   unknown --option refusal · start-time stamps that survive load · the priority list re-read on every poll with one
#   canonical path form · ONE slot per worktree · a signal stops the command's whole tree · D-state-aware load ·
#   the worker cap handed to the command.
# The base behavior (slots, order, quiet mode, load, stale locks) stays in tests/gate-throttle.test.sh.
# Run: bash tests/gate-throttle-port.test.sh   (needs bash, git, flock, timeout; skips without flock)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
# the disk guard (scripts/gate-disk-guard.sh) refuses under 20 GB free: this suite is about throttling, not disk, so it must not turn red on a full host (ORCA324-5 r1)
export KIT_GATE_MIN_FREE_GB=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; GT="$ROOT/scripts/gate-throttle.sh"; QM="$ROOT/scripts/quiet-mode.sh"
command -v flock >/dev/null 2>&1 || { echo "gate-throttle-port: skipped (no flock)"; exit 0; }
command -v timeout >/dev/null 2>&1 || { echo "gate-throttle-port: skipped (no timeout)"; exit 0; }
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export KIT_RUNTIME_DIR="$TMP/rt" GATE_POLL=0.1 GATE_MAX_LOAD=1000000 LOG="$TMP/log" GATE_SLOTS=1
unset GATE_ALLOW_SECOND_SLOT GATE_WORKERS KIT_CPUS KIT_CPUS_ALL
mkdir -p "$TMP/a" "$TMP/b" "$TMP/c"
echo 0 > "$TMP/dzero"; export KIT_DSTATE_COUNT_FILE="$TMP/dzero"   # no /proc scan unless a test asks for it
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1: want '$2' got '$3'"; }

HOLD="$TMP/hold.sh"
cat > "$HOLD" <<'EOF'
#!/usr/bin/env bash
echo "start $1" >> "$LOG"
while [ ! -e "$(dirname "$LOG")/release-$1" ] && [ -d "$(dirname "$LOG")" ]; do sleep 0.05; done
echo "end $1" >> "$LOG"
EOF
release() { : > "$TMP/release-$1"; }
waitfor() { local i=0 n=$(( ${2:-10} * 20 )); while ! grep -qx "$1" "$LOG" 2>/dev/null; do i=$((i+1)); [ "$i" -gt "$n" ] && return 1; sleep 0.05; done; }
bg() {  # <name> [dir] — a throttled HOLD in the background; sets LAST to the throttle's pid
  (cd "${2:-$TMP}" && exec bash "$GT" bash "$HOLD" "$1" 2>>"$TMP/err") & LAST=$!; PIDS+=($LAST)
}
reset() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=(); rm -rf "$TMP/rt" "$LOG" "$TMP"/release-* "$TMP/err"; }
gone() {  # <pid> [seconds] — wait for a process to be gone
  local i=0 n=$(( ${2:-5} * 20 )); while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt "$n" ] && return 1; sleep 0.05; done; return 0
}

# ── 1. an unknown --option is refused before anything is created ──────────────
reset
out="$(timeout 10 bash "$GT" --status 2>&1; echo "rc=$?")"
has "unknown option exits 2" "rc=2" "$out"
has "unknown option is named" "unknown option '--status'" "$out"
[ -z "$(ls "$KIT_RUNTIME_DIR/queue" 2>/dev/null)" ] && ok || bad "an unknown option left a ticket in the queue"

# ── 2. start-time stamps: numeric, shared by the throttle and quiet-mode.sh ───
reset
bg A "$TMP/a"; waitfor "start A" || bad "A never started"
bg B "$TMP/b"; sleep 0.4
t="$(ls "$KIT_RUNTIME_DIR"/queue | grep -E '^[0-9]{10}\.[0-9]+$' | head -1)"
if [ -r /proc/$$/stat ]; then
  case "$(sed -n 2p "$KIT_RUNTIME_DIR/queue/$t")" in ''|*[!0-9]*) bad "ticket line 2 is not a /proc start time: $(sed -n 2p "$KIT_RUNTIME_DIR/queue/$t")" ;; *) ok ;; esac
  r="$(ls "$KIT_RUNTIME_DIR"/running | head -1)"
  case "$(sed -n 2p "$KIT_RUNTIME_DIR/running/$r")" in ''|*[!0-9]*) bad "run entry line 2 is not a start time" ;; *) ok ;; esac
fi
out="$(bash "$QM" status)"
has "quiet-mode status lists the running command" "hold.sh A" "$out"
has "quiet-mode status lists the waiter (same start-time form)" "#1 pid" "$out"
eq "quiet-mode status prints a run entry on ONE line" "1" "$(printf '%s\n' "$out" | grep -c 'hold.sh A')"
printf '%s\n' "$out" | grep -qE '^[0-9]+$' && bad "quiet-mode status leaked the start-time line" || ok
release A; release B; waitfor "end B"

# ── 3. the priority list is re-read on EVERY poll, in one canonical path form ─
reset
mkdir -p "$TMP/c" "$TMP/real/sub" "$TMP/d/sub"; ln -s "$TMP/real" "$TMP/link"
bg A "$TMP/a"; waitfor "start A"
bg C "$TMP/c"; sleep 0.4
! grep -qx "start C" "$LOG" && ok || bad "C started with no free slot and no priority"
mkdir -p "$KIT_RUNTIME_DIR"; printf '%s\n' "$(cd "$TMP/c" && pwd -P)" > "$KIT_RUNTIME_DIR/gate-priority.txt"
waitfor "start C" 5 && ok || bad "a priority line added AFTER C queued was not picked up"
has "the change is announced once" "priority list now on for this tree" "$(cat "$TMP/err")"
release A; release C; waitfor "end C"
# a list line written through a symlink matches the real directory the throttle runs in
reset
bg A "$TMP/a"; waitfor "start A"
printf '%s\n' "$TMP/link" > "$KIT_RUNTIME_DIR/gate-priority.txt"
bg P "$TMP/real"; waitfor "start P" 5 && ok || bad "a priority line through a symlink did not match the real dir"
release A; release P; waitfor "end P"
# a trailing "/" means "inside this directory", not the directory itself
reset
bg A "$TMP/a"; waitfor "start A"
printf '%s\n' "$TMP/d/" > "$KIT_RUNTIME_DIR/gate-priority.txt"
bg S "$TMP/d/sub"; waitfor "start S" 5 && ok || bad "a trailing-slash priority line did not cover a subdirectory"
bg D "$TMP/d"; sleep 0.5
! grep -qx "start D" "$LOG" && ok || bad "a trailing-slash priority line also covered the directory itself"
release A; release S; release D; waitfor "end D"

# ── 4. ONE slot per worktree ──────────────────────────────────────────────────
R="$TMP/repo"; git init -q -b main "$R"; git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TMP/wt1" -b wt1 2>/dev/null; git -C "$R" worktree add -q "$TMP/wt2" -b wt2 2>/dev/null
mkdir -p "$TMP/wt1/sub" "$TMP/plain"
reset; export GATE_SLOTS=3
bg A "$TMP/wt1"; waitfor "start A" || bad "A never started"
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo second >> "$LOG"' 2>&1; echo "rc=$?")"
has "a second throttle from the same worktree is refused (exit 3)" "rc=3" "$out"
has "the refusal names the rule and the holder" "one slot per worktree" "$out"
has "the refusal says the holder is running" "running" "$out"
! grep -qx second "$LOG" && ok || bad "the refused command ran"
out="$(cd "$TMP/wt1/sub" && timeout 10 bash "$GT" bash -c 'echo sub >> "$LOG"' 2>&1; echo "rc=$?")"
has "a subdirectory of the worktree is the same worktree" "rc=3" "$out"
out="$(cd "$TMP/wt2" && timeout 10 bash "$GT" bash -c 'echo other >> "$LOG"' 2>&1; echo "rc=$?")"
has "another worktree is not refused" "rc=0" "$out"; grep -qx other "$LOG" && ok || bad "the other worktree's command did not run"
out="$(cd "$TMP/wt1" && GATE_ALLOW_SECOND_SLOT=1 timeout 10 bash "$GT" bash -c 'echo escape >> "$LOG"' 2>&1; echo "rc=$?")"
has "GATE_ALLOW_SECOND_SLOT=1 lifts the rule" "rc=0" "$out"
release A; waitfor "end A"; sleep 0.3
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo again >> "$LOG"' 2>&1; echo "rc=$?")"
has "after the holder finished the worktree may start again" "rc=0" "$out"
# a WAITING throttle counts too
reset; export GATE_SLOTS=1
bg A "$TMP/wt2"; waitfor "start A"; bg W "$TMP/wt1"; sleep 0.4
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo third >> "$LOG"' 2>&1; echo "rc=$?")"
has "a waiting throttle blocks a second one from its worktree" "rc=3" "$out"
has "the refusal says the holder is waiting" "waiting" "$out"
release A; release W; waitfor "end W"
# a directory that is no git tree is its own key
reset; export GATE_SLOTS=3
bg A "$TMP/plain"; waitfor "start A"
out="$(cd "$TMP/plain" && timeout 10 bash "$GT" bash -c 'echo p >> "$LOG"' 2>&1; echo "rc=$?")"
has "a non-git directory is its own worktree key" "rc=3" "$out"
release A; waitfor "end A"
# 8 starts at one instant from one worktree: exactly one is admitted (the check runs under the ticket flock)
for round in 1 2 3; do
  reset; export GATE_SLOTS=8
  for n in 1 2 3 4 5 6 7 8; do bg "r$n" "$TMP/wt1"; done
  sleep 1.5
  started="$(grep -c '^start' "$LOG" 2>/dev/null)"; started="${started:-0}"
  eq "8 simultaneous starts, round $round: one admitted" "1" "$started"
  for n in 1 2 3 4 5 6 7 8; do release "r$n"; done
  sleep 0.3
done
export GATE_SLOTS=1

# ── 5. a signal stops the command's WHOLE tree ────────────────────────────────
TREE="$TMP/tree.sh"
cat > "$TREE" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$LOG")"
sleep 300 & echo $! > "$d/grandchild.pid"
echo $$ > "$d/payload.pid"
echo "start T" >> "$LOG"
wait
EOF
for sig in TERM HUP; do
  reset; rm -f "$TMP/grandchild.pid" "$TMP/payload.pid"
  (cd "$TMP/a" && exec bash "$GT" bash "$TREE" 2>>"$TMP/err") & tp=$!; PIDS+=($tp)
  waitfor "start T" || bad "tree payload never started"
  gc="$(cat "$TMP/grandchild.pid")"; pp="$(cat "$TMP/payload.pid")"
  kill -$sig "$tp"; wait "$tp" 2>/dev/null; rc=$?
  eq "$sig exit code" "$([ $sig = TERM ] && echo 143 || echo 129)" "$rc"
  gone "$pp" 5 && ok || bad "$sig: the payload outlived the throttle"
  gone "$gc" 5 && ok || bad "$sig: the payload's own child outlived the throttle"
  [ -z "$(ls "$KIT_RUNTIME_DIR/running" 2>/dev/null)" ] && ok || bad "$sig: the run entry was left behind"
  rm -f "$LOG"
done
# a payload that ignores TERM is KILLed after GATE_STOP_GRACE seconds
STUBBORN="$TMP/stubborn.sh"
cat > "$STUBBORN" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
echo $$ > "$(dirname "$LOG")/stubborn.pid"
echo "start S" >> "$LOG"
while :; do sleep 0.2; done
EOF
reset; rm -f "$TMP/stubborn.pid"
(cd "$TMP/a" && exec env GATE_STOP_GRACE=1 bash "$GT" bash "$STUBBORN" 2>>"$TMP/err") & tp=$!; PIDS+=($tp)
waitfor "start S" || bad "stubborn payload never started"
sp="$(cat "$TMP/stubborn.pid")"; kill -TERM "$tp"; wait "$tp" 2>/dev/null
gone "$sp" 6 && ok || bad "a payload that ignores TERM was never KILLed"
# a signal while still WAITING in the line: exits at once, drops its ticket
reset
bg A "$TMP/a"; waitfor "start A"; bg B "$TMP/b"; sleep 0.4
[ -n "$(ls "$KIT_RUNTIME_DIR/queue" | grep -E '^[0-9]{10}\.')" ] && ok || bad "B has no ticket while waiting"
kill -TERM "$LAST"; wait "$LAST" 2>/dev/null; rc=$?
eq "TERM while queued: exit 143" "143" "$rc"
[ -z "$(ls "$KIT_RUNTIME_DIR/queue" | grep -E '^[0-9]{10}\.')" ] && ok || bad "TERM while queued left the ticket"
release A; waitfor "end A"

# ── 6. load: tasks stuck in uninterruptible sleep (D) are not load ─────────────
echo "5.00 1 1 1/1 1" > "$TMP/loadavg"
run_load() {  # <name> -> exit code of a throttled `true` within 3 s (124 = still held)
  (cd "$TMP/a" && KIT_LOADAVG_FILE="$TMP/loadavg" GATE_MAX_LOAD=2 timeout 3 bash "$GT" true 2>"$TMP/err.load"); echo $?
}
reset; rm -f "$TMP/dcount"
eq "load 5 >= 2 with no D-state tasks holds the line" "124" "$(KIT_DSTATE_COUNT_FILE="$TMP/dcount" run_load)"
has "the hold names the load" "holding: load 5.00" "$(cat "$TMP/err.load")"
reset; echo 4 > "$TMP/dcount"
eq "load 5 minus 4 D-state tasks = 1 < 2 admits" "0" "$(KIT_DSTATE_COUNT_FILE="$TMP/dcount" run_load)"
reset; echo 99 > "$TMP/dcount"
eq "effective load is floored at 0 (more D-state tasks than load)" "0" "$(KIT_DSTATE_COUNT_FILE="$TMP/dcount" run_load)"
# the scan itself: a fake /proc with 4 tasks in D state (comm with spaces and a paren) and 2 sleeping
reset; mkdir -p "$TMP/proc"
for n in 101 102 103 104; do mkdir -p "$TMP/proc/$n"; echo "$n (kworker/u8:1 (x) y) D 2 0 0 0" > "$TMP/proc/$n/stat"; done
for n in 201 202; do mkdir -p "$TMP/proc/$n"; echo "$n (bash) S 1 0 0 0" > "$TMP/proc/$n/stat"; done
eq "four D-state tasks in a fake /proc are subtracted" "0" "$(KIT_DSTATE_COUNT_FILE= KIT_PROC_DIR="$TMP/proc" KIT_DSTATE_GAP=0.1 run_load)"
rm -rf "$TMP/proc/10"[1-4]
eq "no D-state tasks: the load holds" "124" "$(KIT_DSTATE_COUNT_FILE= KIT_PROC_DIR="$TMP/proc" KIT_DSTATE_GAP=0.1 run_load)"

# ── 7. the worker cap handed to the command ──────────────────────────────────
reset
workers() {  # [env...] -> what the command saw in GATE_WORKERS
  (cd "$TMP/a" && env "$@" timeout 10 bash "$GT" bash -c 'echo "$GATE_WORKERS"' 2>"$TMP/err.w")
}
eq "8 CPUs / 2 slots = 4 workers" "4" "$(workers KIT_CPUS=8 KIT_CPUS_ALL=8 GATE_SLOTS=2)"
eq "8 CPUs / 4 slots = 2 workers" "2" "$(workers KIT_CPUS=8 KIT_CPUS_ALL=8 GATE_SLOTS=4)"
eq "held to this process's CPU mask" "4" "$(workers KIT_CPUS=4 KIT_CPUS_ALL=32 GATE_SLOTS=2)"
eq "floored at 2" "2" "$(workers KIT_CPUS=8 KIT_CPUS_ALL=8 GATE_SLOTS=8)"
eq "a caller's GATE_WORKERS wins" "3" "$(workers KIT_CPUS=8 KIT_CPUS_ALL=8 GATE_SLOTS=2 GATE_WORKERS=3)"
eq "a bad GATE_WORKERS is ignored" "4" "$(workers KIT_CPUS=8 KIT_CPUS_ALL=8 GATE_SLOTS=2 GATE_WORKERS=lots)"
has "the throttle says what it chose and why" "GATE_WORKERS=4" "$(cat "$TMP/err.w")"

# ── 8. r1 (READ of 322-7): stale-fixture tests for the liveness rules, each with a mutant that must turn it red ────────────────
pstart() { if [ -r "/proc/$1/stat" ]; then sed 's/^.*) //' "/proc/$1/stat" | cut -d' ' -f20; else ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; fi; }   # the throttle's start-time form
WRONG="Mon Jan  1 00:00:00 2001"
# 8a. quiet-mode status: a run entry whose pid is LIVE but belongs to another process (reuse) is not listed, and is removed
reset; sleep 60 & rq=$!; PIDS+=("$rq"); mkdir -p "$KIT_RUNTIME_DIR/running"
printf '0\t%s\t%s\n%s\n' "$TMP/reused" "build" "$WRONG" > "$KIT_RUNTIME_DIR/running/$rq"
out="$(bash "$QM" status)"
hasnt "quiet-mode status skips a run entry whose pid was reused" "$TMP/reused" "$out"
[ ! -e "$KIT_RUNTIME_DIR/running/$rq" ] && ok || bad "the reused-pid run entry was not removed"
printf '0\t%s\t%s\n%s\n' "$TMP/holder" "build" "$(pstart "$rq")" > "$KIT_RUNTIME_DIR/running/$rq"
out="$(bash "$QM" status)"
has "quiet-mode status lists a run entry whose start time matches" "pid $rq  0 $TMP/holder build" "$out"
[ -e "$KIT_RUNTIME_DIR/running/$rq" ] && ok || bad "a live holder's run entry was removed"
kill "$rq" 2>/dev/null; wait "$rq" 2>/dev/null

# 8b. one slot per worktree: a DEAD ticket from my worktree does not refuse a start (dead pid, and a live pid that was reused)
export GATE_SLOTS=3
reset; mkdir -p "$KIT_RUNTIME_DIR/queue"
true & dp=$!; wait "$dp"
printf '%s\n%s\n' "$TMP/wt1" "12345" > "$KIT_RUNTIME_DIR/queue/0000000005.$dp"
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo deadticket >> "$LOG"' 2>&1; echo "rc=$?")"
has "a ticket of a dead pid from my worktree does not refuse" "rc=0" "$out"
reset; mkdir -p "$KIT_RUNTIME_DIR/queue"; sleep 60 & sq=$!; PIDS+=("$sq")
printf '%s\n%s\n' "$TMP/wt1" "$WRONG" > "$KIT_RUNTIME_DIR/queue/0000000005.$sq"
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo reusedticket >> "$LOG"' 2>&1; echo "rc=$?")"
has "a ticket whose pid is live but reused does not refuse" "rc=0" "$out"
printf '%s\n%s\n' "$TMP/wt1" "$(pstart "$sq")" > "$KIT_RUNTIME_DIR/queue/0000000005.$sq"
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo liveticket >> "$LOG"' 2>&1; echo "rc=$?")"
has "a ticket with the right start time from my worktree refuses" "rc=3" "$out"
has "and says the holder is waiting" "waiting" "$out"
kill "$sq" 2>/dev/null; wait "$sq" 2>/dev/null

# 8c. one slot per worktree: a run entry whose pid is live but reused does not refuse; one with the right start time does
reset; mkdir -p "$KIT_RUNTIME_DIR/running"; sleep 60 & rq=$!; PIDS+=("$rq")
printf '0\t%s\t%s\n%s\n' "$TMP/wt1" "build" "$WRONG" > "$KIT_RUNTIME_DIR/running/$rq"
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo reusedrun >> "$LOG"' 2>&1; echo "rc=$?")"
has "a run entry whose pid was reused does not refuse" "rc=0" "$out"
printf '0\t%s\t%s\n%s\n' "$TMP/wt1" "build" "$(pstart "$rq")" > "$KIT_RUNTIME_DIR/running/$rq"
out="$(cd "$TMP/wt1" && timeout 10 bash "$GT" bash -c 'echo liverun >> "$LOG"' 2>&1; echo "rc=$?")"
has "a run entry with the right start time from my worktree refuses" "rc=3" "$out"
has "and says the holder is running" "running" "$out"
kill "$rq" 2>/dev/null; wait "$rq" 2>/dev/null
export GATE_SLOTS=1

# 8d. D-state load: only tasks STILL in D a second sample later count; a burst that ends between the samples does not
reset; mkdir -p "$TMP/proc"; echo "5.00 1 1 1/1 1" > "$TMP/loadavg"
for n in 101 102 103 104; do mkdir -p "$TMP/proc/$n"; echo "$n (kworker/u8:1 (x) y) D 2 0 0 0" > "$TMP/proc/$n/stat"; done
( sleep 0.6; for n in 101 102 103 104; do echo "$n (kworker/u8:1 (x) y) S 2 0 0 0" > "$TMP/proc/$n/stat"; done ) & PIDS+=($!)
eq "tasks in D at the first sample but gone at the second do not lower the load (the line holds)" "124" "$(KIT_DSTATE_COUNT_FILE= KIT_PROC_DIR="$TMP/proc" KIT_DSTATE_GAP=1.5 run_load)"
for n in 101 102 103 104; do echo "$n (kworker/u8:1 (x) y) D 2 0 0 0" > "$TMP/proc/$n/stat"; done
eq "tasks still in D at the second sample are subtracted (the line admits)" "0" "$(KIT_DSTATE_COUNT_FILE= KIT_PROC_DIR="$TMP/proc" KIT_DSTATE_GAP=0.3 run_load)"

# 8e. KILL escalation: a pid that died during the grace window and was REUSED by an unrelated process must not be KILLed.
#     The reuse is forced in a private pid namespace (unshare -Urpf, writing ns_last_pid); skipped where that is not allowed.
PAYLOAD="$TMP/reuse-payload.sh"
cat > "$PAYLOAD" <<'EOS'
#!/usr/bin/env bash
# TERM kills the child at once; this shell lingers ~1 s in its TERM trap, so the throttle's grace loop keeps running
d="$(dirname "$LOG")"
trap 'SECONDS=0; while [ "$SECONDS" -lt 1 ]; do :; done; exit 0' TERM
sleep 300 & echo $! > "$d/child.pid"
echo "start R" >> "$LOG"
wait
EOS
NS="$TMP/reuse-ns.sh"
cat > "$NS" <<'EOS'
#!/usr/bin/env bash
# runs INSIDE the pid namespace; prints SURVIVED or KILLED or NOREUSE
d="$(dirname "$LOG")"; rm -f "$d/child.pid"
(cd "$d" && GATE_STOP_GRACE=3 exec bash "$GT" bash "$PAYLOAD") 2>>"$d/err" & tp=$!
i=0; while ! grep -qx "start R" "$LOG" 2>/dev/null || [ ! -s "$d/child.pid" ]; do i=$((i+1)); [ "$i" -gt 200 ] && { echo NOSTART; exit 0; }; sleep 0.05; done
pc="$(cat "$d/child.pid")"
kill -TERM "$tp"
i=0; while kill -0 "$pc" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 100 ] && { echo NOREUSE; exit 0; }; sleep 0.02; done
inn=""
for try in 1 2 3 4 5 6 7 8; do
  echo $((pc - 1)) > /proc/sys/kernel/ns_last_pid 2>/dev/null || { echo NOREUSE; exit 0; }
  sleep 300 & inn=$!
  [ "$inn" = "$pc" ] && break
  kill "$inn" 2>/dev/null; wait "$inn" 2>/dev/null; inn=""
done
[ -n "$inn" ] || { echo NOREUSE; exit 0; }
wait "$tp" 2>/dev/null
if kill -0 "$inn" 2>/dev/null; then echo SURVIVED; else echo KILLED; fi
kill "$inn" 2>/dev/null
EOS
reset
if unshare -Urpf --mount-proc bash -c 'echo 0 > /proc/sys/kernel/ns_last_pid' >/dev/null 2>&1; then
  res="$(GT="$GT" PAYLOAD="$PAYLOAD" LOG="$LOG" unshare -Urpf --mount-proc bash "$NS" 2>/dev/null | tail -1)"
  eq "an unrelated process that reused a tree member's pid survives the KILL escalation" "SURVIVED" "$res"
else
  echo "gate-throttle-port: 8e skipped (no user+pid namespaces)"
fi


echo "gate-throttle-port: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
