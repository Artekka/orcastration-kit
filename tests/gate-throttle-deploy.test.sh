#!/usr/bin/env bash
# Tests for gate-throttle.sh DEPLOY MODE and the reuse-check hook, ported from a project that has run them daily (ORCA322-9):
#   a priority gate that runs confines every OTHER running gate's tree to a CPU subset (taskset; affinity is reversible, nice is
#   not), holds new normal gates, never signals anyone, and gives each process back its OWN recorded mask on exit, on a dead owner
#   (monitor) and at the next throttle start (a SIGKILLed release gate cannot leave anything confined).
#   GATE_REUSE_CHECK / gate_reuse_check: ask first whether the tree already has a green record; a hit exits 0 without queueing.
# The base behavior stays in tests/gate-throttle.test.sh and tests/gate-throttle-port.test.sh.
# Run: bash tests/gate-throttle-deploy.test.sh   (needs bash, flock, timeout, taskset; the mask cases need 4+ CPUs)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
# the disk guard (scripts/gate-disk-guard.sh) refuses under 20 GB free: this suite is about throttling, not disk, so it must not turn red on a full host (ORCA324-5 r1)
export KIT_GATE_MIN_FREE_GB=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; GT="$ROOT/scripts/gate-throttle.sh"; QM="$ROOT/scripts/quiet-mode.sh"
command -v flock >/dev/null 2>&1 || { echo "gate-throttle-deploy: skipped (no flock)"; exit 0; }
command -v timeout >/dev/null 2>&1 || { echo "gate-throttle-deploy: skipped (no timeout)"; exit 0; }
command -v taskset >/dev/null 2>&1 || { echo "gate-throttle-deploy: skipped (no taskset)"; exit 0; }
TMP="$(mktemp -d)"; PIDS=(); STRAYS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"} ${STRAYS[@]+"${STRAYS[@]}"}; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT
export KIT_RUNTIME_DIR="$TMP/rt" GATE_POLL=0.1 GATE_MAX_LOAD=1000000 GATE_SLOTS=2 KIT_DEPLOY_POLL=0.3 GATE_DEPLOY_OTHERS_PCT=25
unset GATE_ALLOW_SECOND_SLOT GATE_WORKERS KIT_CPUS KIT_CPUS_ALL GATE_REUSE_CHECK
echo 0 > "$TMP/dzero"; export KIT_DSTATE_COUNT_FILE="$TMP/dzero"
RT="$KIT_RUNTIME_DIR"; ACTIVE="$RT/deploy-mode/active"
NPROC="$(nproc)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1: want '$2' got '$3'"; }
mask()  { taskset -p "$1" 2>/dev/null | sed 's/.*: //'; }
until_() {  # <seconds> <command...>: poll until it succeeds
  local n=$(( $1 * 10 )) i=0; shift
  while ! "$@" 2>/dev/null; do i=$((i+1)); [ "$i" -gt "$n" ] && return 1; sleep 0.1; done; return 0
}
fileset() { [ -s "$1" ]; }
gone() { [ ! -e "$1" ]; }
differs() { [ "$(mask "$1")" != "$2" ]; }
equals() { [ "$(mask "$1")" = "$2" ]; }
reset() {
  local p; for p in ${PIDS[@]+"${PIDS[@]}"} ${STRAYS[@]+"${STRAYS[@]}"}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null
  PIDS=(); STRAYS=(); rm -rf "$TMP/rt" "$TMP"/*.pid "$TMP/go"; mkdir -p "$TMP/rel" "$TMP/work" "$TMP/rt"
  printf '%s\n' "$TMP/rel" > "$RT/gate-priority.txt"
}
# a normal gate that RUNS: its payload is a sleep whose pid lands in $1.pid; sets NT (throttle pid) and NS (the sleep's pid)
normal() {  # <name> [env...]
  local n="$1"; shift
  (cd "$TMP/work" && exec env "$@" bash "$GT" bash -c "sleep 120 & echo \$! > '$TMP/$n.pid'; wait" 2>>"$TMP/err") & NT=$!; PIDS+=($NT)
  until_ 10 fileset "$TMP/$n.pid" || bad "normal gate $n never started"
  NS="$(cat "$TMP/$n.pid" 2>/dev/null)"; STRAYS+=("$NS")
}
# a priority gate (cwd on the priority list) holding the priority slot ~60 s; sets PT and PS
prio() {  # [env...]
  (cd "$TMP/rel" && exec env "$@" bash "$GT" bash -c "sleep 60 & echo \$! > '$TMP/prio.pid'; wait" 2>>"$TMP/err") & PT=$!; PIDS+=($PT)
  until_ 10 fileset "$TMP/prio.pid" || bad "priority gate never started"
  PS="$(cat "$TMP/prio.pid" 2>/dev/null)"; STRAYS+=("$PS")
}
# The design floor is 2 CPUs (test 12), so on a 4-CPU runner the quarter (1) is below the floor: the cap is max(2, quarter).
ceil_quarter() { local q=$(( (NPROC * 25 + 99) / 100 )); echo $(( q < 2 ? 2 : q )); }
popcount() { printf '%d' "0x$1" | awk '{ n=$1; c=0; while (n>0) { c+=n%2; n=int(n/2) } print c }'; }

# ── 1. confine a running normal gate, restore its exact mask; the priority gate keeps every CPU ──
if [ "$NPROC" -ge 4 ]; then
  reset; normal A; before="$(mask "$NS")"
  prio; until_ 10 fileset "$ACTIVE" || bad "deploy mode never became active"
  until_ 10 differs "$NS" "$before" && ok || bad "the running normal gate was never confined"
  c="$(popcount "$(mask "$NS")")"
  [ "$c" -ge 2 ] && [ "$c" -le "$(ceil_quarter)" ] && ok || bad "confined to $c CPUs (want 2..$(ceil_quarter))"
  sleep 1.2; eq "the priority gate keeps its full mask" "$before" "$(mask "$PS")"
  kill -TERM "$PS"
  until_ 10 gone "$ACTIVE" && ok || bad "deploy state was not removed after the priority gate finished"
  until_ 10 equals "$NS" "$before" && ok || bad "the normal gate did not get its exact original mask back"
else echo "gate-throttle-deploy: mask cases skipped (< 4 CPUs)"; fi

# ── 2. nothing is ever signaled or stopped ──
reset; normal A; prio; until_ 10 fileset "$ACTIVE"; sleep 0.8
for p in "$NT" "$NS"; do
  [ -d "/proc/$p" ] && ok || bad "pid $p died"
  [ "$(sed 's/^.*) //' "/proc/$p/stat" | cut -c1)" != T ] && ok || bad "pid $p was stopped"
done
kill -TERM "$PS"

# ── 3. admission: no new normal gate while deploy mode is on; one notice; runs once it ends ──
reset; prio; until_ 10 fileset "$ACTIVE"
out="$(cd "$TMP/work" && timeout 3 bash "$GT" true 2>&1; echo "rc=$?")"
has "a new normal gate waits in line (timed out)" "rc=124" "$out"
has "with a DEPLOY MODE notice" "DEPLOY MODE" "$out"
eq "exactly one notice" 1 "$(printf '%s\n' "$out" | grep -c 'DEPLOY MODE')"
kill -TERM "$PS"; until_ 10 gone "$ACTIVE" || bad "state not removed"
out="$(cd "$TMP/work" && timeout 20 bash "$GT" true 2>&1; echo "rc=$?")"
has "after the priority gate exited the normal gate runs" "rc=0" "$out"

# ── 4. a second priority-listed gate is not held by the admission wait ──
reset; prio; until_ 10 fileset "$ACTIVE"
out="$(cd "$TMP/rel" && GATE_ALLOW_SECOND_SLOT=1 timeout 10 bash "$GT" true 2>&1; echo "rc=$?")"   # same worktree as the release gate: the seat's escape
has "premise: the second priority-listed gate ran" "rc=0" "$out"
hasnt "a priority-listed gate is not held by deploy mode" "DEPLOY MODE" "$out"
kill -TERM "$PS"

# ── 5. a SIGKILLed release gate leaves state that the NEXT throttle start repairs ──
if [ "$NPROC" -ge 4 ]; then
  reset; normal A; before="$(mask "$NS")"; prio; until_ 10 fileset "$ACTIVE"
  until_ 10 differs "$NS" "$before" || bad "never confined"
  mon="$(sed -n 's/^monitor=//p' "$ACTIVE")"
  kill -KILL "$PT" "$mon" 2>/dev/null; kill -KILL "$PS" 2>/dev/null; sleep 0.2
  [ "$(mask "$NS")" != "$before" ] && ok || bad "premise: nothing may have restored yet"
  mkdir -p "$TMP/other"   # not $TMP/work: the normal gate A still runs there (one slot per worktree)
  out="$(cd "$TMP/other" && timeout 30 bash "$GT" true 2>&1; echo "rc=$?")"
  has "the next start is not blocked by the dead deploy state" "rc=0" "$out"
  eq "and it gave the mask back" "$before" "$(mask "$NS")"
  [ ! -e "$ACTIVE" ] && ok || bad "the dead state was not removed"
fi

# ── 5b. the start-of-run repair happens even when that start is REFUSED (one slot per worktree) before the wait loop ──
reset; normal A; sleep 120 & dm=$!; STRAYS+=("$dm"); mkdir -p "$RT/deploy-mode"
printf 'pid=999999\nlstart=1\ncwd=%s\nmonitor=999998\n' "$TMP/rel" > "$ACTIVE"
out="$(cd "$TMP/work" && timeout 10 bash "$GT" true 2>&1; echo "rc=$?")"
has "premise: the second start from the worktree is refused" "rc=3" "$out"
[ ! -e "$ACTIVE" ] && ok || bad "a refused start left a dead owner's deploy state behind"

# ── 6. an orphaned monitor restores by itself when its priority gate dies ──
reset; normal A; before="$(mask "$NS")"; prio; until_ 10 fileset "$ACTIVE"
[ "$NPROC" -ge 4 ] && { until_ 10 differs "$NS" "$before" || bad "never confined"; }
kill -KILL "$PT" 2>/dev/null; kill -KILL "$PS" 2>/dev/null
until_ 20 gone "$ACTIVE" && ok || bad "the monitor did not clean up a dead owner's state"
eq "and the mask is back" "$before" "$(mask "$NS")"

# ── 7. TERM and HUP to the priority throttle restore and drop the state (the EXIT trap) ──
for sig in TERM HUP; do
  reset; normal A; before="$(mask "$NS")"; prio; until_ 10 fileset "$ACTIVE"
  kill -$sig "$PT"; wait "$PT" 2>/dev/null
  until_ 10 gone "$ACTIVE" && ok || bad "$sig: state left behind"
  until_ 10 equals "$NS" "$before" && ok || bad "$sig: mask not restored"
done

# ── 8. quiet-mode.sh status says whether deploy mode is on ──
reset
has "status says deploy mode OFF" "deploy mode: OFF" "$(bash "$QM" status)"
prio; until_ 10 fileset "$ACTIVE"
has "status shows ON with the release gate's directory" "deploy mode: ON ($TMP/rel)" "$(bash "$QM" status)"
kill -TERM "$PS"

# ── 9. each process is restored to ITS OWN mask; a child born after the last sweep is freed too ──
if [ "$NPROC" -ge 8 ]; then
  reset
  (cd "$TMP/work" && exec bash "$GT" bash -c "taskset -c 2-5 sleep 120 & echo \$! > '$TMP/custom.pid'; wait" 2>>"$TMP/err") & NT=$!; PIDS+=($NT)
  until_ 10 fileset "$TMP/custom.pid"; cu="$(cat "$TMP/custom.pid")"; STRAYS+=("$cu")
  eq "premise: the custom child has its own mask" 3c "$(mask "$cu")"; rootb="$(mask "$NT")"
  prio; until_ 10 fileset "$ACTIVE"; until_ 10 differs "$cu" 3c || bad "custom child never confined"
  kill -TERM "$PS"; until_ 10 gone "$ACTIVE"
  until_ 10 equals "$cu" 3c && ok || bad "the custom-mask child was not restored to ITS mask"
  eq "the root keeps its own" "$rootb" "$(mask "$NT")"
  reset
  (cd "$TMP/work" && exec bash "$GT" bash -c "sleep 120 & echo \$! > '$TMP/early.pid'; while [ ! -f '$TMP/go' ]; do sleep 0.1; done; sleep 120 & echo \$! > '$TMP/late.pid'; wait" 2>>"$TMP/err") & NT=$!; PIDS+=($NT)
  until_ 10 fileset "$TMP/early.pid"; ea="$(cat "$TMP/early.pid")"; STRAYS+=("$ea"); before="$(mask "$ea")"
  par="$(sed 's/^.*) //' "/proc/$ea/stat" | cut -d' ' -f2)"; parb="$(mask "$par")"
  prio KIT_DEPLOY_POLL=30; until_ 10 fileset "$ACTIVE"
  until_ 10 differs "$ea" "$before" || bad "early child never confined"; until_ 10 differs "$par" "$parb" || bad "parent never confined"
  : > "$TMP/go"; until_ 10 fileset "$TMP/late.pid"; la="$(cat "$TMP/late.pid")"; STRAYS+=("$la")
  [ "$(mask "$la")" = "$(mask "$par")" ] && ok || bad "premise: the late child was not born confined"
  kill -TERM "$PS"; until_ 10 gone "$ACTIVE"
  until_ 10 equals "$la" "$before" && ok || bad "a child born after the last sweep was not freed"
fi

# ── 10. pid reuse: a recorded entry whose start time no longer matches is never touched; the stale state IS processed ──
reset; sleep 120 & dm=$!; STRAYS+=("$dm"); before="$(mask "$dm")"
mkdir -p "$RT/deploy-mode"
printf 'pid=999999\nlstart=1\ncwd=%s\nmonitor=999998\n' "$TMP/rel" > "$ACTIVE"
printf '#mask=7f\n%s|1|1\n' "$dm" > "$RT/deploy-mode/confined"
out="$(cd "$TMP/work" && timeout 30 bash "$GT" true 2>&1; echo "rc=$?")"
has "a dead deploy owner does not block" "rc=0" "$out"
[ ! -e "$ACTIVE" ] && ok || bad "the stale state was not processed"
eq "the reused pid's mask was left alone" "$before" "$(mask "$dm")"

# ── 11. a priority-listed gate in a NORMAL slot is never confined ──
reset; prio; until_ 10 fileset "$ACTIVE"
(cd "$TMP/rel" && exec env GATE_ALLOW_SECOND_SLOT=1 bash "$GT" bash -c "sleep 120 & echo \$! > '$TMP/prio2.pid'; wait" 2>>"$TMP/err") & PIDS+=($!)   # same worktree as the release gate: the seat's escape
until_ 10 fileset "$TMP/prio2.pid" || bad "premise: the second priority-listed gate never started"
p2="$(cat "$TMP/prio2.pid")"; STRAYS+=("$p2")
sleep 1.5; eq "a second priority-listed gate keeps the full mask (not read from a racing 'before')" "$(mask "$PS")" "$(mask "$p2")"
kill -TERM "$PS"

# ── 12. never confined to fewer than 2 CPUs, however small the percentage ──
if [ "$NPROC" -ge 4 ]; then
  reset; normal A GATE_DEPLOY_OTHERS_PCT=1; before="$(mask "$NS")"; prio GATE_DEPLOY_OTHERS_PCT=1
  until_ 10 fileset "$ACTIVE"; until_ 10 differs "$NS" "$before" || bad "never confined"
  eq "exactly 2 CPUs at 1%" 2 "$(popcount "$(mask "$NS")")"
  kill -TERM "$PS"
fi

# ── 13. no taskset: a note, and the admission hold still works ──
reset; (cd "$TMP/rel" && exec env KIT_TASKSET_BIN=no-such-taskset bash "$GT" bash -c "sleep 60 & echo \$! > '$TMP/prio.pid'; wait" 2>"$TMP/err.nt") & PT=$!; PIDS+=($PT)
until_ 10 fileset "$TMP/prio.pid"; PS="$(cat "$TMP/prio.pid")"; STRAYS+=("$PS"); until_ 10 fileset "$ACTIVE"
has "the missing taskset is said" "taskset missing, admission hold only" "$(cat "$TMP/err.nt")"
out="$(cd "$TMP/work" && timeout 3 bash "$GT" true 2>&1; echo "rc=$?")"
has "new normal gates are still held" "rc=124" "$out"
kill -TERM "$PS"

# ── 14. the run entry records the priority flag (line 3) ──
reset; normal A; prio; until_ 10 fileset "$ACTIVE"
eq "a normal gate's run entry says prio=0" "prio=0" "$(sed -n 3p "$RT/running/$NT")"
eq "the priority gate's run entry says prio=1" "prio=1" "$(sed -n 3p "$RT/running/$PT")"
kill -TERM "$PS"

# ── 15. reuse check: the hook runs BEFORE a ticket; exit 0 = a green record exists, so exit 0 without queueing ──
reset; : > "$TMP/ran"
HIT="$TMP/hit.sh"; printf '#!/usr/bin/env bash\necho "reusing green for: $*"\nexit 0\n' > "$HIT"
MISS="$TMP/miss.sh"; printf '#!/usr/bin/env bash\necho "no record for: $*"\nexit 3\n' > "$MISS"
out="$(cd "$TMP/work" && GATE_REUSE_CHECK="bash $HIT" timeout 10 bash "$GT" bash -c 'echo ran >> "$0"' "$TMP/ran" 2>&1; echo "rc=$?")"
has "a hit exits 0" "rc=0" "$out"; has "the hook's output passes through" "reusing green for: bash -c" "$out"
eq "a hit does not run the command" 0 "$(wc -l < "$TMP/ran")"
[ -z "$(ls "$RT/queue" 2>/dev/null | grep -E '^[0-9]{10}\.')" ] && ok || bad "a hit left a ticket"
[ -z "$(ls "$RT/running" 2>/dev/null)" ] && ok || bad "a hit left a run entry"
out="$(cd "$TMP/work" && GATE_REUSE_CHECK="bash $MISS" timeout 10 bash "$GT" bash -c 'echo ran >> "$0"' "$TMP/ran" 2>&1; echo "rc=$?")"
has "a miss queues and runs the command" "rc=0" "$out"; eq "the command ran once" 1 "$(wc -l < "$TMP/ran")"
has "the miss output passes through" "no record for" "$out"
# the hook comes from the team block too (env wins)
mkdir -p "$TMP/conf/docs/orchestration"; git init -q "$TMP/conf" 2>/dev/null
printf 'team:\n  gate_reuse_check: bash %s\n' "$HIT" > "$TMP/conf/docs/orchestration/ORCHESTRATION.md"
: > "$TMP/ran"
out="$(cd "$TMP/conf" && timeout 10 bash "$GT" bash -c 'echo ran >> "$0"' "$TMP/ran" 2>&1; echo "rc=$?")"
has "gate_reuse_check: in the team block is read" "reusing green for" "$out"; eq "and the command did not run" 0 "$(wc -l < "$TMP/ran")"
out="$(cd "$TMP/conf" && GATE_REUSE_CHECK="bash $MISS" timeout 10 bash "$GT" bash -c 'echo ran >> "$0"' "$TMP/ran" 2>&1; echo "rc=$?")"
has "the environment wins over the block" "no record for" "$out"
# no hook: nothing changes
: > "$TMP/ran"; (cd "$TMP/work" && timeout 10 bash "$GT" bash -c 'echo ran >> "$0"' "$TMP/ran" >/dev/null 2>&1); eq "no hook: the command just runs" 1 "$(wc -l < "$TMP/ran")"

# ── 16. a --reuse-check meant for the GATE passes through; the throttle defines no flags of its own ──
reset
out="$(cd "$TMP/work" && timeout 10 bash "$GT" bash -c 'echo "gate got: $*"' _ --reuse-check pnpm 2>&1; echo "rc=$?")"
has "--reuse-check after the command reaches the command" "gate got: --reuse-check pnpm" "$out"
out="$(cd "$TMP/work" && timeout 10 bash "$GT" --reuse-check bash -c true 2>&1; echo "rc=$?")"
has "a LEADING --reuse-check is refused (exit 2)" "rc=2" "$out"; has "and named" "unknown option '--reuse-check'" "$out"

# ── 17. (ORCA322-9 r1) a child born confined that a LATER sweep sees is not pinned ──
# Test 9 stops the monitor after one sweep. Here the monitor keeps sweeping (0.3 s) while the late child sits on the confined mask:
# the sweep must skip it (recording the confined mask as its "original" would pin it forever), so the restore frees it from its
# gate's recorded mask. Mutant: drop the born-confined skip in dm_sweep.
if [ "$NPROC" -ge 8 ]; then
  reset
  (cd "$TMP/work" && exec bash "$GT" bash -c "sleep 120 & echo \$! > '$TMP/early.pid'; while [ ! -f '$TMP/go' ]; do sleep 0.1; done; sleep 120 & echo \$! > '$TMP/late.pid'; wait" 2>>"$TMP/err") & NT=$!; PIDS+=($NT)
  until_ 10 fileset "$TMP/early.pid"; ea="$(cat "$TMP/early.pid")"; STRAYS+=("$ea"); before="$(mask "$ea")"
  par="$(sed 's/^.*) //' "/proc/$ea/stat" | cut -d' ' -f2)"
  prio; until_ 10 fileset "$ACTIVE"; until_ 10 differs "$ea" "$before" || bad "early child never confined"
  : > "$TMP/go"; until_ 10 fileset "$TMP/late.pid"; la="$(cat "$TMP/late.pid")"; STRAYS+=("$la")
  [ "$(mask "$la")" = "$(mask "$par")" ] && ok || bad "premise: the late child was not born confined"
  sleep 1.5   # several sweeps SEE the late child while the deploy runs
  kill -TERM "$PS"; until_ 10 gone "$ACTIVE"
  until_ 10 equals "$la" "$before" && ok || bad "a born-confined child that a later sweep saw stayed pinned"
else echo "gate-throttle-deploy: test 17 skipped (< 8 CPUs)"; fi

# ── 18. (ORCA322-9 r1) restore frees an UNRECORDED confined process even when a record with a WRONG start time names its pid ──
# A dead deployer's state built by hand (no real deploy runs): the root is registered and recorded, the child sits on the confined
# mask (3) and its record belongs to a reused pid. Mutant: dm_orig_of matches by pid only (the child would count as "recorded").
if [ "$NPROC" -ge 4 ]; then
  reset
  bash -c "sleep 120 & echo \$! > '$TMP/t.pid'; wait" & root=$!; PIDS+=($root)
  until_ 10 fileset "$TMP/t.pid"; ch="$(cat "$TMP/t.pid")"; STRAYS+=("$ch")
  full="$(mask "$root")"; taskset -a -p 3 "$ch" >/dev/null
  rstart="$(sed 's/^.*) //' "/proc/$root/stat" | cut -d' ' -f20)"
  mkdir -p "$RT/running" "$RT/deploy-mode"
  printf '%s\n%s\nprio=0\n' "$TMP/work" "$rstart" > "$RT/running/$root"
  printf 'pid=999999\nlstart=1\ncwd=%s\nmonitor=999998\n' "$TMP/rel" > "$ACTIVE"
  printf '#mask=3\n%s|%s|%s\n%s|1|ff\n' "$root" "$rstart" "$full" "$ch" > "$RT/deploy-mode/confined"
  eq "premise: the child sits on the confined mask" 3 "$(mask "$ch")"
  (cd "$TMP/work" && timeout 30 bash "$GT" true >/dev/null 2>&1)
  eq "the wrong-start record does not count as recorded: the child gets its gate's mask" "$full" "$(mask "$ch")"
fi

# ── 19. (ORCA322-9 r1) a leave while a sweep is mid-flight does not re-confine what it just restored ──
# KIT_DEPLOY_SWEEP_DELAY makes every sweep dawdle after reading the tree, so the leave lands INSIDE a sweep. The sweep visits the
# gate's processes one by one, so the throttle AND its payload are both sampled: whichever the sweep had not reached yet at the
# leave is the one a sweep without the owner re-check would confine afterwards. The masks are SAMPLED for 4 s, because the stale
# sweep re-confines only until the monitor heals it. Mutant: drop the owner re-check in dm_sweep.
if [ "$NPROC" -ge 4 ]; then
  reset; normal A; before="$(mask "$NS")"; beforeT="$(mask "$NT")"
  prio KIT_DEPLOY_SWEEP_DELAY=1.5; until_ 10 fileset "$ACTIVE"
  anyconf() { [ "$(mask "$NS")" != "$before" ] || [ "$(mask "$NT")" != "$beforeT" ]; }
  until_ 45 anyconf || bad "the first sweep never confined the gate"
  sleep 0.4   # the next process is now asleep inside the delay
  kill -TERM "$PS"; until_ 10 gone "$ACTIVE" || bad "deploy state was not removed after the leave"
  seen=""; for _ in $(seq 40); do seen="$seen $(mask "$NS")/$(mask "$NT")"; sleep 0.1; done
  u="$(tr ' ' '\n' <<<"$seen" | sort -u | grep -v '^$' | tr '\n' ' ')"
  eq "a leave mid-sweep: no process of the gate was re-confined" "$before/$beforeT " "$u"
fi

# ── 20. (ORCA322-9 r1) INT to the priority throttle restores and drops the state (the EXIT trap), like TERM and HUP in test 7 ──
# A job started with `&` from a non-interactive shell ignores INT and cannot trap it, so the throttle is started through python3
# with the default disposition restored (exec keeps it).
if [ "$NPROC" -ge 4 ] && command -v python3 >/dev/null 2>&1; then
  reset; normal A; before="$(mask "$NS")"
  (cd "$TMP/rel" && exec python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$GT" bash -c "sleep 60 & echo \$! > '$TMP/prio.pid'; wait" 2>>"$TMP/err") & PT=$!; PIDS+=($PT)
  until_ 10 fileset "$TMP/prio.pid"; PS="$(cat "$TMP/prio.pid" 2>/dev/null)"; STRAYS+=("$PS")
  until_ 10 fileset "$ACTIVE"; until_ 10 differs "$NS" "$before" || bad "INT: the normal gate was never confined"
  kill -INT "$PT"; wait "$PT" 2>/dev/null
  until_ 10 gone "$ACTIVE" && ok || bad "INT: state left behind"
  until_ 10 equals "$NS" "$before" && ok || bad "INT: mask not restored"
  # The trap also stops the throttle's own child tree (stop_tree). Without an INT trap the throttle dies at once and the payload
  # runs on. Mutant: drop the INT trap.
  until_ 15 gone "/proc/$PS" && ok || bad "INT: the payload (pid $PS) is still running after the INT"
else echo "gate-throttle-deploy: INT test skipped (< 4 CPUs or no python3)"; fi

echo "gate-throttle-deploy: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
