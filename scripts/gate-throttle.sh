#!/usr/bin/env bash
# gate-throttle.sh (orchestration-kit): run a heavy command (your gate, a whole test suite) only when one of
# N host-wide slots is free, so several sessions on one machine do not run N full gates at once and flake
# on load. Usage, from inside YOUR worktree:
#   bash scripts/gate-throttle.sh <command> [args...]        e.g. bash scripts/gate-throttle.sh npm test
#   bash scripts/gate-throttle.sh --log <file> <command> [args...]
# Exit code = the command's exit code.
# --log:     once the slot is held, the command's output (stdout and stderr) goes to <file>, which opens
#            with "SHA <full commit>" and "started <HH:MM:SS> dirty=<changed paths>" read at that moment
#            (not while waiting: a commit made in the queue would make the log name the wrong code) and
#            ends with "exit <code>". The slot line stays on stderr.
#
# Slots:     `gate_slots:` in the team block of docs/orchestration/ORCHESTRATION.md (default 2);
#            GATE_SLOTS overrides it.
# Priority:  one extra slot for release/train gates. A command may take it only if its working directory
#            starts with a line of "$RT/gate-priority.txt" (one path prefix per line; the seat owns it).
#            The priority slot ignores the queue and the load check.
# Fair order: each waiter takes a numbered ticket; only the oldest LIVE waiter may try for a normal slot
#            (polling alone is not first-come-first-served: a gate once waited 1.5 h while later arrivals
#            took freed slots). A dead waiter's ticket is skipped and deleted.
# Load:      the head of the line takes a normal slot only while the 1-minute load average is below
#            GATE_MAX_LOAD (default 0.9 x CPU count). Unreadable load = admit.
# Memory:    a normal slot beyond the first is admitted only while the system's available memory
#            (MemAvailable in /proc/meminfo) is at least GATE_MIN_FREE_MB (default 3072). Below that, one
#            normal slot at a time. Unreadable = admit. KIT_MEMINFO_FILE points at a stand-in (tests).
# Quiet mode: while "$RT/quiet-mode" exists (scripts/quiet-mode.sh on), no NEW command starts; running
#            ones finish. GATE_IGNORE_QUIET=1 is the seat's escape for a hotfix gate; while quiet
#            mode is on it also skips the line, because the waiters ahead of it are parked.
# Runtime dir: $KIT_RUNTIME_DIR, default ~/.orchestration-kit/runtime. Not /tmp: a reboot wipes /tmp.
#            A lock file that survives a reboot is harmless, because flock locks are held by the kernel,
#            not by the file: the holder died with the machine, so the next command simply takes it.
# One slot per worktree: a throttle whose worktree (the git toplevel of its directory, else the directory) already holds a
#            slot or waits in the line is refused at once, exit 3, before it takes a ticket. GATE_ALLOW_SECOND_SLOT=1
#            is the seat's escape. Why: one session's parallel runs once held 2 of 3 slots for hours while 8 gates queued.
# Priority list: re-read on EVERY poll, each line in one canonical form (symlinks resolved; a trailing "/" means "inside
#            this directory, not the directory itself"), so a path the seat adds while a gate waits takes effect.
# Signals:   TERM/HUP stop the command's WHOLE process tree (TERM, then KILL after GATE_STOP_GRACE seconds, default 5, for
#            any process that ignored it); the throttle exits 143 / 129. Never `pkill -f`.
# Load:      tasks stuck in uninterruptible sleep (D state, e.g. a hung driver) use no CPU but count in loadavg; the
#            effective load is loadavg minus the tasks still in D state a second sample later (GATE_DSTATE_GAP).
# Workers:   the command gets GATE_WORKERS (a positive integer): CPUs / slots, held to this process's CPU mask, at least 2.
#            A test runner can read it (jest --maxWorkers, vitest, pytest -n). A GATE_WORKERS you set yourself wins.
# Deploy mode: while a gate that took the PRIORITY slot runs, (1) no NEW normal gate is admitted (it waits in line, with one
#            notice), and (2) every OTHER running throttled gate's process tree is confined to the first
#            GATE_DEPLOY_OTHERS_PCT (default 25) percent of the CPUs, at least 2, so the release gate gets the rest. Each process
#            gets back EXACTLY the mask it had before. Affinity, not nice: an unprivileged process cannot lower a nice value again,
#            and a crash would leave gates niced for good. Nothing is ever signaled, stopped or paused. State in
#            "$RT/deploy-mode/". Restore happens when the priority throttle exits (any signal TERM/INT/HUP included), from its
#            monitor when it dies without a trap (SIGKILL), and at the top of EVERY throttle start, so a killed release gate
#            cannot leave anything confined. A pid whose start time changed is never touched. Needs taskset(1)
#            (KIT_TASKSET_BIN names it); without it deploy mode is an admission hold only, with a note. quiet-mode.sh status
#            says whether it is on. Seams: KIT_DEPLOY_POLL (monitor period, default 5 s), KIT_DEPLOY_SWEEP_DELAY.
# Reuse check: `GATE_REUSE_CHECK` or `gate_reuse_check:` in the team block names a command asked BEFORE the throttle takes a
#            ticket, run as `<that command> <your command and args>`. Exit 0 = the tree already has a green record: its output
#            passes through and the throttle exits 0 without queueing or running anything. Any other exit = queue as usual. The
#            throttle has no flag of its own for this: a `--reuse-check` belongs to YOUR gate and, after the command, reaches it.
# Needs flock(1) (util-linux; macOS: `brew install flock`). Without it, it warns and runs unthrottled.
set -u
log=""
if [ "${1:-}" = --log ]; then
  [ $# -ge 3 ] && [ -n "$2" ] || { echo "usage: gate-throttle.sh [--log <file>] <command> [args...]" >&2; exit 64; }
  log="$2"; shift 2
  # append, not truncate: a refusal below (disk guard, one slot per worktree, reuse check) must leave an earlier log intact;
  # the log is emptied only where the command actually starts (the redirect further down).
  : >> "$log" || { echo "gate-throttle: cannot write the log $log" >&2; exit 73; }
fi
[ $# -ge 1 ] || { echo "usage: gate-throttle.sh [--log <file>] <command> [args...]" >&2; exit 64; }
# The command, logged when --log was given: commit and dirty count first, read now, exit code last.
run() {
  [ -z "$log" ] && { "$@"; return $?; }
  local rc
  {
    echo "SHA $(git rev-parse HEAD 2>/dev/null || echo none)"
    echo "started $(date +%H:%M:%S) dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    "$@"; rc=$?
    echo "exit $rc"
    return $rc
  } > "$log" 2>&1
}
# The script has no other --flags of its own. A leading --word is a typo (`--status` once was queued as a COMMAND and held a ticket),
# so refuse before anything is created.
case "$1" in
  --?*)
    echo "gate-throttle: unknown option '$1'. This script takes a command to run in a gate slot, not options." >&2
    echo "usage: bash scripts/gate-throttle.sh [--log <file>] <command> [args...]" >&2
    exit 2
    ;;
esac
# Low disk: refuse before any ticket exists (scripts/gate-disk-guard.sh; KIT_GATE_MIN_FREE_GB or `gate_min_free_gb:` sets the
# minimum, default 20 GB, 0 = off). A project that did not copy the guard script simply has no check.
_guard="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/gate-disk-guard.sh"
if [ -f "$_guard" ]; then bash "$_guard" || exit 1; fi
RT="${KIT_RUNTIME_DIR:-$HOME/.orchestration-kit/runtime}"
FLOCK="${KIT_FLOCK_BIN:-flock}"
if ! command -v "$FLOCK" >/dev/null 2>&1; then
  echo "gate-throttle: flock not found (Linux: util-linux; macOS: brew install flock); running UNTHROTTLED" >&2
  run "$@"; exit $?
fi
locks_dir="$RT/locks"; qdir="$RT/queue"; rdir="$RT/running"
mkdir -p "$locks_dir" "$qdir" "$rdir" || exit 1

# Slots: env > team block > 2. The overlay is read from the MAIN checkout, so a worktree gets the same value.
slots="${GATE_SLOTS:-}"
if [ -z "$slots" ]; then
  main="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  conf="${main:-.}/docs/orchestration/ORCHESTRATION.md"
  slots="$(sed -n 's/^[[:space:]]*gate_slots:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$conf" 2>/dev/null | head -n1)"
fi
case "$slots" in ''|*[!0-9]*|0) slots=2 ;; esac
poll="${GATE_POLL:-5}"
reuse_cmd="${GATE_REUSE_CHECK:-}"
if [ -z "$reuse_cmd" ]; then
  main_wt="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  reuse_cmd="$(sed -n 's/^[[:space:]]*gate_reuse_check:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "${main_wt:-.}/docs/orchestration/ORCHESTRATION.md" 2>/dev/null | head -n1)"
fi

# The priority list is re-read on EVERY poll (refresh_prio, top of the wait loop), not once at start: a gate that queued
# before the seat added its worktree used to sit on the normal slots forever, and a removed path kept the priority slot.
# Only the slot choice follows the file: a gate that already holds a slot has left the loop.
prio=0
here="$(pwd -P)"
prio_seen=""   # last prio value; empty until the first read, so the start-up read stays silent
refresh_prio() {
  local p slash
  prio=0
  if [ -f "$RT/gate-priority.txt" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # One canonical form: $here is `pwd -P`; a list line written through a symlink never matched it. A trailing "/"
      # (inside this directory) is kept, which realpath would drop.
      slash=""; case "$p" in */) slash="/" ;; esac
      p="$(realpath -m -P -- "$p" 2>/dev/null || printf '%s' "$p")${slash}"
      case "$here" in "$p"*) prio=1 ;; esac
    done < "$RT/gate-priority.txt"
  fi
  # One line per CHANGE (never per poll): tests and operators can wait on it instead of guessing poll timing.
  if [ -n "$prio_seen" ] && [ "$prio_seen" != "$prio" ]; then
    echo "gate-throttle: priority list now $([ "$prio" = 1 ] && echo on || echo off) for this tree" >&2
  fi
  prio_seen=$prio
}
refresh_prio

alive() { kill -0 "$1" 2>/dev/null; }
# A process's start time: with the pid it names ONE process. A ticket whose pid now belongs to a different process (pid reuse,
# often after a reboot, since tickets survive one) has a different start time and counts as dead. Read from /proc/<pid>/stat
# field 22 (clock ticks since boot), NOT `ps -o lstart=`: ps derives lstart from the wall clock, so under load the SAME process
# reported different values inside one minute and live tickets looked dead. Without /proc (macOS) fall back to lstart.
# quiet-mode.sh carries the same function: the two must agree, or its status lists no waiters.
proc_start() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    s="$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20)"
    [ -n "$s" ] && { printf '%s' "$s"; return; }
  fi
  ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'
}
ticket_alive() {  # <ticket file> <pid>
  local want; want="$(sed -n 2p "$1" 2>/dev/null)"
  [ -n "$want" ] && alive "$2" && [ "$(proc_start "$2")" = "$want" ]
}

quiet_told=0
quiet_wait() {
  [ "${GATE_IGNORE_QUIET:-}" = 1 ] && return 0
  while [ -f "$RT/quiet-mode" ]; do
    if [ "$quiet_told" = 0 ]; then echo "gate-throttle: QUIET MODE is on; waiting for it to turn off..." >&2; quiet_told=1; fi
    sleep "$poll"
  done
}

# A zombie (killed, not yet reaped by its parent) still has a /proc entry but is not running anything.
pid_running() {
  alive "$1" || return 1
  [ -r "/proc/$1/stat" ] || return 0
  [ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)" != "Z" ]
}
# pid + all its descendants, one per line
tree_of() {
  ps -eo pid=,ppid= 2>/dev/null | awk -v r="$1" '{ p[$1] = $2 }
    END { out[r] = 1; ch = 1
          while (ch) { ch = 0; for (x in p) if (!(x in out) && (p[x] in out)) { out[x] = 1; ch = 1 } }
          for (x in out) print x }'
}

# ONE slot per worktree. The key is the worktree: the git toplevel of the caller's directory (the same from any subdirectory),
# or the directory itself when it is no git tree. A throttle that WAITS in the line (ticket) or HOLDS a slot (run entry) from
# the same worktree refuses this start. The tickets are scanned BEFORE the run entries: a winner writes its run entry first and
# drops its ticket after, so a start that finds no ticket is guaranteed to find the run entry. Scanned the other way round, a
# winner could register and drop its ticket between the two scans and both would come up empty.
top_of() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$1"; }
second_slot_holder() {  # prints "<pid> <running|waiting>" of a live throttle from MY worktree, else nothing
  local mine f pid dir
  mine="$(top_of "$(pwd -P)")"
  for f in "$qdir"/[0-9]*.[0-9]*; do
    [ -f "$f" ] || continue
    pid="${f##*.}"
    ticket_alive "$f" "$pid" || continue
    dir="$(sed -n 1p "$f")"
    [ "$(top_of "$dir")" = "$mine" ] && { echo "$pid waiting"; return 0; }
  done
  for f in "$rdir"/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"
    pid_running "$pid" && [ "$(proc_start "$pid")" = "$(sed -n 2p "$f")" ] || continue
    dir="$(sed -n 1p "$f" | cut -f2)"
    [ "$(top_of "$dir")" = "$mine" ] && { echo "$pid running"; return 0; }
  done
  return 0
}

my_ticket=""
take_ticket() {
  local n held
  exec 8>"$qdir/lock"; "$FLOCK" 8
  # The check runs HERE, under the same flock that writes the ticket. As a separate step before it, N starts at one instant
  # all passed the check before any wrote a ticket.
  if [ "${GATE_ALLOW_SECOND_SLOT:-}" != 1 ]; then
    held="$(second_slot_holder)"
    if [ -n "$held" ]; then
      echo "gate-throttle: REFUSED. one slot per worktree: a throttle from $(top_of "$(pwd -P)") is already ${held#* } (pid ${held%% *}). Wait for it to finish, then run this again. (The seat can override with GATE_ALLOW_SECOND_SLOT=1.)" >&2
      exit 3
    fi
  fi
  n="$(cat "$qdir/counter" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$qdir/counter"
  my_ticket="$(printf '%010d.%d' "$n" "$$")"
  # line 1: the waiter's dir (for status), line 2: its start time (liveness). Written whole, then renamed
  # into place, so a reader never sees a ticket without its start time and takes it for dead.
  printf '%s\n%s\n' "$(pwd -P)" "$(proc_start $$)" > "$qdir/.new.$$" && mv -f "$qdir/.new.$$" "$qdir/$my_ticket"
  exec 8>&-
}
drop_ticket() { [ -n "$my_ticket" ] && rm -f "${qdir:?}/${my_ticket:?}"; my_ticket=""; }
am_head() {  # 0 = I am the oldest live waiter (dead waiters' tickets are deleted on the way)
  local f pid
  for f in $(ls "$qdir" 2>/dev/null | grep -E '^[0-9]{10}\.[0-9]+$' | sort); do
    [ "$f" = "$my_ticket" ] && return 0
    pid="${f#*.}"
    ticket_alive "$qdir/$f" "$pid" && return 1
    rm -f "${qdir:?}/${f:?}"
  done
  return 0
}

cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
max_load="${GATE_MAX_LOAD:-$(awk -v n="$cpus" 'BEGIN { printf "%.2f", n * 0.9 }')}"
load_now() {
  if [ -n "${KIT_LOADAVG_FILE:-}" ]; then cut -d' ' -f1 "$KIT_LOADAVG_FILE" 2>/dev/null
  elif [ -r /proc/loadavg ]; then cut -d' ' -f1 /proc/loadavg
  else sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'; fi
}
# loadavg counts tasks in uninterruptible sleep (D state) as load. When a driver hangs, hundreds of tasks sit in D: loadavg
# reads ~150 at 95% idle CPU and every queued gate is held forever. D-state sleepers use no CPU, so the effective load is
# loadavg minus the D-state count, floored at 0. One awk over /proc/[0-9]*/stat (the state is the first field after the LAST
# ")", because comm may contain spaces and parens); a failed or timed-out scan yields 0. loadavg is a 1-minute average but a
# D-state count is one instant, so only tasks STILL in D a second sample KIT_DSTATE_GAP (1 s) later count: a hung driver's
# tasks stay put, a burst of ordinary I/O sleepers comes and goes. Seams: KIT_PROC_DIR (default /proc),
# KIT_DSTATE_COUNT_FILE (a ready count; skips the scan), KIT_DSTATE_GAP.
dstate_pids() {
  local t=""; command -v timeout >/dev/null 2>&1 && t="timeout 3"
  $t awk 'FNR==1 { s=$0; sub(/^.*\) /, "", s); if (substr(s,1,1)=="D") { n=split(FILENAME, a, "/"); print a[n-1] } }' \
    "${KIT_PROC_DIR:-/proc}"/[0-9]*/stat 2>/dev/null | sort
}
dstate_count() {
  local n a b
  if [ -n "${KIT_DSTATE_COUNT_FILE:-}" ]; then
    n="$(head -n1 "$KIT_DSTATE_COUNT_FILE" 2>/dev/null)"
  else
    a="$(dstate_pids)"
    if [ -z "$a" ]; then n=0; else
      sleep "${KIT_DSTATE_GAP:-1}"
      b="$(dstate_pids)"
      n="$(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b") 2>/dev/null | wc -l)"
    fi
  fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}
load_ok() {
  local l d; l="$(load_now)"
  [ -z "$l" ] && return 0
  d="$(dstate_count)"
  awk -v l="$l" -v d="$d" -v m="$max_load" 'BEGIN { e = l - d; if (e < 0) e = 0; exit !(e < m) }'
}

# The worker cap for the command: CPUs / slots, held to this process's CPU mask (a gate pinned to fewer CPUs), floored at 2.
# Seams: KIT_CPUS (the mask's count), KIT_CPUS_ALL (all CPUs). A caller's own positive-integer GATE_WORKERS wins.
workers_decide() {
  local mask all note=""
  mask="${KIT_CPUS:-$(nproc 2>/dev/null || echo "$cpus")}"
  all="${KIT_CPUS_ALL:-$(nproc --all 2>/dev/null || echo "$mask")}"
  case "${GATE_WORKERS:-}" in
    '') ;;
    *[!0-9]*|0*) note="GATE_WORKERS=$GATE_WORKERS ignored (not a positive integer); "; GATE_WORKERS="" ;;
  esac
  if [ -n "${GATE_WORKERS:-}" ]; then WORKERS_WHY="set by the caller"; return; fi
  GATE_WORKERS=$(( all / slots )); WORKERS_WHY="${note}$all CPUs / $slots slots"
  if [ "$GATE_WORKERS" -gt "$mask" ]; then GATE_WORKERS="$mask"; WORKERS_WHY="$WORKERS_WHY, held to this process's CPU mask ($mask)"; fi
  if [ "$GATE_WORKERS" -lt 2 ]; then GATE_WORKERS=2; WORKERS_WHY="$WORKERS_WHY, floored at 2"; fi
}

# A TERM/INT/HUP to the throttle stops its OWN child tree. The command used to be a foreground child with only an EXIT trap, so
# killing the throttle left the command (and everything it started) running on a tree that may change under it. The command now
# runs in the background and is `wait`ed on, because bash defers a trap until a FOREGROUND child ends but runs it at once for
# `wait`. The tree is read BEFORE anything is signaled (a TERM'd parent orphans its children), every member is TERMed, and a
# survivor after GATE_STOP_GRACE seconds (5) gets KILL only if its start time still matches (pid reuse). A signal that arrives
# while the throttle still queues has no child and just exits; the EXIT trap then drops the ticket and the run entry.
# NOTE: a throttle started with the signal ignored (`cmd &` from a non-job-control shell ignores INT; nohup ignores HUP)
# cannot trap it; TERM is the one every caller can rely on.
child=""
stop_tree() {  # <root pid>
  local root="$1" p q s end i any
  local -a pids=() starts=()
  # Add every process under <pid> that is not in the set yet and TERM it. Called for the root first, then for every
  # still-running member on each pass of the grace loop: a payload's own TERM trap may start a process after the first
  # snapshot, and that one is still a child of a member until the member exits.
  snap() {
    for q in $(tree_of "$1"); do
      case " ${pids[*]:-} " in *" $q "*) continue ;; esac
      s="$(proc_start "$q")"; [ -n "$s" ] || continue
      pids+=("$q"); starts+=("$s")
      kill -TERM "$q" 2>/dev/null
    done
  }
  snap "$root"
  end=$((SECONDS + ${GATE_STOP_GRACE:-5}))
  while [ "$SECONDS" -lt "$end" ]; do
    any=0
    for p in "${pids[@]}"; do
      pid_running "$p" || continue
      any=1
      snap "$p"
    done
    [ "$any" = 0 ] && return 0
    sleep 0.1
  done
  for i in "${!pids[@]}"; do
    pid_running "${pids[$i]}" && [ "$(proc_start "${pids[$i]}")" = "${starts[$i]}" ] && kill -KILL "${pids[$i]}" 2>/dev/null
  done
  return 0
}
launching=0 pending_sig=""
on_signal() {  # <exit code>
  # Between `"$@" &` and `child=$!` the child exists but is not recorded yet; stopping now would find nothing and leave the
  # tree running. Remember the signal; the launch code replays it once `child` is set.
  if [ "$launching" = 1 ] && [ -z "$child" ]; then pending_sig="$1"; return; fi
  trap '' TERM INT HUP   # a second signal must not re-enter while the tree is being stopped
  [ -z "$child" ] || stop_tree "$child"
  exit "$1"
}

TASKSET="${KIT_TASKSET_BIN:-taskset}"
dm_dir="$RT/deploy-mode"
dm_active="$dm_dir/active"
dm_confined="$dm_dir/confined"
dm_poll="${KIT_DEPLOY_POLL:-5}"
dm_pct="${GATE_DEPLOY_OTHERS_PCT:-25}"
dm_owner=0   # 1 in the throttle that entered deploy mode
dm_mon=""    # pid of that throttle's own monitor helper (never a gate)
dm_told=0
dm_field() { sed -n "s/^$1=//p" "$dm_active" 2>/dev/null | head -n 1; }
# 0 = a live priority gate owns deploy mode (its pid exists and is the same process).
dm_live() {
  [ -f "$dm_active" ] || return 1
  local pid want
  pid="$(dm_field pid)"; want="$(dm_field lstart)"
  [ -n "$pid" ] && pid_running "$pid" && [ "$(proc_start "$pid")" = "$want" ]
}
# <pid> <lstart>: the recorded original mask of that exact process, or nothing.
dm_orig_of() {
  awk -F'|' -v p="$1" -v s="$2" '$1 == p && $2 == s { print $3; exit }' "$dm_confined" 2>/dev/null
}
dm_confined_mask() { sed -n 's/^#mask=//p' "$dm_confined" 2>/dev/null | head -n 1; }
# Give every confined process its mask back. (1) each RECORDED process gets ITS OWN recorded mask (a child with a
# custom mask keeps it; a process whose start time changed is never touched). (2) A process born after the last
# sweep inherited the confined mask and is in no record: walk each registered gate's CURRENT tree and give every
# process still sitting on exactly the confined mask its gate's recorded original.
dm_restore() {
  [ -f "$dm_confined" ] || return 0
  local pid start mask f gpid gstart rootorig cmask cur p
  cmask="$(dm_confined_mask)"
  while IFS='|' read -r pid start mask; do
    case "$pid" in ""|"#"*) continue ;; esac
    pid_running "$pid" && [ "$(proc_start "$pid")" = "$start" ] || continue
    "$TASKSET" -a -p "$mask" "$pid" >/dev/null 2>&1
  done < "$dm_confined"
  if [ -n "$cmask" ]; then
    for f in "$rdir"/*; do
      [ -f "$f" ] || continue
      gpid="${f##*/}"; gstart="$(sed -n 2p "$f")"
      pid_running "$gpid" && [ "$(proc_start "$gpid")" = "$gstart" ] || continue
      rootorig="$(dm_orig_of "$gpid" "$gstart")"
      [ -n "$rootorig" ] || continue
      for p in $(tree_of "$gpid"); do
        [ -n "$(dm_orig_of "$p" "$(proc_start "$p")")" ] && continue   # recorded: handled above
        cur="$("$TASKSET" -p "$p" 2>/dev/null | sed 's/.*: //')"
        [ "$cur" = "$cmask" ] && "$TASKSET" -a -p "$rootorig" "$p" >/dev/null 2>&1
      done
    done
  fi
  rm -f "$dm_confined"
}
# A dead owner's state is repaired by whoever notices first: give every confined process its mask back.
dm_stale_check() {
  [ -f "$dm_active" ] || { [ -f "$dm_confined" ] && dm_restore; return 0; }
  dm_live && return 0
  dm_restore
  rm -f "$dm_active"
}
dm_others_cpulist() {
  local n k
  n="$(nproc 2>/dev/null || echo 4)"
  k=$(( (n * dm_pct + 99) / 100 ))
  [ "$k" -lt 2 ] && k=2
  [ "$k" -ge "$n" ] && return 1   # nothing to take away on a 1-2 CPU host
  echo "0-$((k - 1))"
}
# One sweep: confine every other registered gate's tree that is not confined yet.
# 0 = deploy mode still belongs to <owner> and that process is running.
dm_owner_ok() {
  [ "$(sed -n 's/^pid=//p' "$dm_active" 2>/dev/null | head -n 1)" = "$1" ] && pid_running "$1"
}
dm_sweep() {  # <owner pid> <cpu list>
  local owner="$1" cpus="$2" f gpid gstart gprio p pstart cur cmask
  cmask="$(dm_confined_mask)"
  for f in "$rdir"/*; do
    [ -f "$f" ] || continue
    gpid="${f##*/}"
    [ "$gpid" = "$owner" ] && continue
    gstart="$(sed -n 2p "$f")"; gprio="$(sed -n 3p "$f")"
    if [ ! -d "/proc/$gpid" ] || [ "$(proc_start "$gpid")" != "$gstart" ]; then rm -f "$f"; continue; fi
    [ "$gprio" = "prio=1" ] && continue   # never confine a priority gate
    for p in $(tree_of "$gpid"); do
      # test seam : widens the window between "the tree was read" and "a process is
      # touched", so the leave-during-sweep race can be provoked on purpose. Unset = no effect.
      [ -n "${KIT_DEPLOY_SWEEP_DELAY:-}" ] && sleep "$KIT_DEPLOY_SWEEP_DELAY"
      pstart="$(proc_start "$p")"; [ -n "$pstart" ] || continue
      [ -n "$(dm_orig_of "$p" "$pstart")" ] && continue
      cur="$("$TASKSET" -p "$p" 2>/dev/null | sed 's/.*: //')"; [ -n "$cur" ] || continue
      # Already on the confined mask and in no record = born confined (it inherited the mask). Recording that
      # mask as its "original" would pin it forever; dm_restore frees it from its gate's recorded mask instead.
      [ -n "$cmask" ] && [ "$cur" = "$cmask" ] && continue
      # Re-check the owner right before touching anything: a leave/crash that restored while this sweep was
      # mid-flight must not be undone by the sweep's stale view.
      dm_owner_ok "$owner" || return 0
      echo "$p|$pstart|$cur" >> "$dm_confined"   # this process's OWN mask
      "$TASKSET" -a -p -c "$cpus" "$p" >/dev/null 2>&1
    done
  done
}
dm_enter() {  # called by the priority throttle once it holds slot 5
  command -v "$TASKSET" >/dev/null 2>&1 || { echo "gate-throttle: deploy mode: taskset missing, admission hold only" >&2; }
  local cpus="" me="$$" mystart
  cpus="$(dm_others_cpulist)" || cpus=""
  mystart="$(proc_start $$)"
  mkdir -p "$dm_dir"
  # header: the mask the others are confined to (a hex bitmap of CPUs 0..k-1), so a restore can tell an
  # inherited-confined process from one that merely has a custom mask
  if [ -n "$cpus" ]; then printf '#mask=%x\n' $(( (1 << (${cpus#0-} + 1)) - 1 )) > "$dm_confined"; else : > "$dm_confined"; fi
  (
    exec 9>&- </dev/null >/dev/null 2>&1
    until [ -f "$dm_active" ]; do sleep 0.1; [ -d "/proc/$me" ] || exit 0; done
    while :; do
      if [ "$(proc_start "$me")" != "$mystart" ] || [ "$(sed -n 's/^pid=//p' "$dm_active" 2>/dev/null)" != "$me" ]; then
        # owner died (no trap ran) or deploy mode ended: give everything back, drop a dead owner's state
        dm_restore
        [ -d "/proc/$me" ] || rm -f "$dm_active"
        exit 0
      fi
      [ -n "$cpus" ] && command -v "$TASKSET" >/dev/null 2>&1 && dm_sweep "$me" "$cpus"
      sleep "$dm_poll"
    done
  ) &
  dm_mon=$!
  printf 'pid=%s\nlstart=%s\ncwd=%s\nmonitor=%s\n' "$me" "$mystart" "$(pwd -P)" "$dm_mon" > "$dm_dir/.active.$$" \
    && mv -f "$dm_dir/.active.$$" "$dm_active"
  dm_owner=1
  echo "gate-throttle: DEPLOY MODE on: new normal gates wait, running ones are confined to CPUs ${cpus:-none}" >&2
}
dm_leave() {
  [ "$dm_owner" = 1 ] || return 0
  dm_owner=0
  # Stop OUR OWN monitor helper first (never a gate), so no sweep is mid-flight while we restore.
  if [ -n "$dm_mon" ]; then pkill -P "$dm_mon" 2>/dev/null; kill "$dm_mon" 2>/dev/null; wait "$dm_mon" 2>/dev/null; dm_mon=""; fi
  dm_restore
  rm -f "$dm_active"
}
on_exit() {
  drop_ticket
  rm -f "${rdir:?}/$$"
  dm_leave
}
# Reuse check: before any ticket exists, so a hit never queues.
if [ -n "$reuse_cmd" ]; then
  if bash -c "$reuse_cmd"' "$@"' gate-throttle-reuse-check "$@"; then exit 0; fi
fi
dm_stale_check
min_free_mb="${GATE_MIN_FREE_MB:-3072}"
case "$min_free_mb" in ''|*[!0-9]*) min_free_mb=3072 ;; esac
mem_avail_mb() {  # available memory in MB; empty when unreadable
  local f="${KIT_MEMINFO_FILE:-/proc/meminfo}"
  [ -r "$f" ] || return 0
  awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' "$f" 2>/dev/null
}
mem_ok() {  # 0 = a normal slot beyond the first may start
  local m; m="$(mem_avail_mb)"
  [ -z "$m" ] && return 0
  [ "$m" -ge "$min_free_mb" ]
}
running_normal() {  # how many normal-slot commands are running now (live pid, numeric slot)
  local f n=0 pid
  for f in "$rdir"/*; do
    [ -e "$f" ] || continue
    pid="${f##*/}"
    # line 1 only: the run entry also has a start-time line and a prio line
    case "$(head -n 1 "$f" 2>/dev/null | cut -f1)" in ''|*[!0-9]*) continue ;; esac
    alive "$pid" && n=$((n + 1))
  done
  echo "$n"
}
mem_told=0
take_ticket
trap on_exit EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP
load_told=0
while :; do
  cands=""
  refresh_prio
  # Deploy mode: while a priority gate runs, a normal gate waits in line (its ticket stays), with one notice. A priority gate is
  # never held. The state is re-checked each pass, so a dead deployer releases the line.
  dm_stale_check
  if [ "$prio" != 1 ] && dm_live; then
    if [ "$dm_told" = 0 ]; then
      echo "gate-throttle: DEPLOY MODE: a release gate is running ($(dm_field cwd)); waiting for it to finish..." >&2
      dm_told=1
    fi
    sleep "$poll"
    continue
  fi
  dm_told=0
  # The quiet-mode escape also skips the line: the waiters ahead are parked in quiet mode and would hold it forever.
  if am_head || { [ "${GATE_IGNORE_QUIET:-}" = 1 ] && [ -f "$RT/quiet-mode" ]; }; then
    if load_ok; then
      cands="$(seq 1 "$slots")"; load_told=0
      if [ "$slots" -gt 1 ] && ! mem_ok && [ "$(running_normal)" -ge 1 ]; then
        cands=""
        if [ "$mem_told" = 0 ]; then
          echo "gate-throttle: next in line, holding: $(mem_avail_mb) MB available < $min_free_mb MB (GATE_MIN_FREE_MB); one slot until memory frees" >&2; mem_told=1
        fi
      else mem_told=0; fi
    elif [ "$load_told" = 0 ]; then
      echo "gate-throttle: next in line, holding: load $(load_now) >= $max_load (GATE_MAX_LOAD)" >&2; load_told=1
    fi
  fi
  [ "$prio" = 1 ] && cands="prio $cands"
  for i in $cands; do
    quiet_wait
    exec 9>"$locks_dir/gate-slot-$i.lock"
    if "$FLOCK" -n 9; then
      # The run entry goes in BEFORE the ticket is dropped, so there is no gap where a second start from this worktree sees
      # neither one. Line 1: slot, dir, command (tab-separated; what quiet-mode.sh status prints). Line 2: start time.
      # Line 3: prio=1 for a gate in the priority slot or on the priority list (deploy mode never confines those).
      printf '%s\t%s\t%s\n%s\nprio=%s\n' "$i" "$(pwd -P)" "$*" "$(proc_start $$)" "$([ "$i" = prio ] && echo 1 || echo "$prio")" > "$rdir/$$"
      [ "$i" = prio ] && dm_enter
      drop_ticket
      echo "gate-throttle: slot $i acquired $(date +%H:%M:%S) in $(pwd -P)" >&2
      workers_decide; export GATE_WORKERS
      echo "gate-throttle: GATE_WORKERS=$GATE_WORKERS ($WORKERS_WHY)" >&2
      launching=1
      # 9>&-: the command does not inherit the lock fd, so a daemon it leaves behind (a dev server, a watcher) cannot keep
      # the slot after it returns. This shell's own fd 9 holds the lock until exit. Background + wait: see on_signal;
      # `<&0` keeps stdin, which a non-job-control `&` would replace with /dev/null. `wait` returns the command's own status,
      # so the exit code passes through unchanged.
      run "$@" 9>&- <&0 &
      child=$!
      launching=0
      [ -z "$pending_sig" ] || on_signal "$pending_sig"
      wait "$child"; rc=$?
      child=""
      exit $rc
    fi
    exec 9>&-
  done
  sleep "$poll"
done
