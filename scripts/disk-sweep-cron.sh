#!/usr/bin/env bash
# disk-sweep-cron.sh (orcastration-kit): the scheduled run of scripts/disk-sweep.sh. The SessionStart hook starts it in the
# background at most once a day (and gate-disk-guard.sh under the free-space floor); it also works by hand or from cron.
# Usage: disk-sweep-cron.sh [--repo DIR] [--if-due [--floor-only]]
#   --if-due      run only when still due (checked again under the lock: ten sessions starting together run ONE sweep)
# Rules:
#   - The off switch (~/.orcastration-kit/disk-sweep.off, `disk-sweep.sh --off`) wins: nothing runs.
#   - ONE sweep per machine at a time: a lock the kernel holds (flock, else perl's flock; else a lock folder with the owner's pid).
#   - The start stamp (~/.orcastration-kit/disk-sweep/last/<project>, one per project) is written BEFORE the sweep, so a crashed run does not loop.
#   - An unreadable free-space number means "do not sweep" (exit 3), logged.
#   - A running gate does NOT skip the sweep (Art's pick, 11-25): the sweep's own keep rules (live process, recent file) protect it.
#   - The FIRST run on a machine is a dry run (--dry-run); the next session start shows its report. Later runs pass --apply.
#   - Low priority: nice 19 and ionice idle when the machine has them.
# Log: ~/.orcastration-kit/disk-sweep/cron.log. Test seam: KIT_SWEEP_CRON_SWEEP (the sweep script).
set -uo pipefail
unset CDPATH
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-kit-home.sh
. "$HERE_DIR/lib-kit-home.sh"
# shellcheck source=lib-disk-sweep-launch.sh
. "$HERE_DIR/lib-disk-sweep-launch.sh"

repo=""; ifdue=0; floor_only=""; orig_args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "usage: disk-sweep-cron.sh [--repo DIR] [--if-due [--floor-only]]" >&2; exit 2; }; repo=$2; shift 2 ;;
    --if-due) ifdue=1; shift ;;
    --floor-only) floor_only=floor; shift ;;
    *) echo "usage: disk-sweep-cron.sh [--repo DIR] [--if-due [--floor-only]]" >&2; exit 2 ;;
  esac
done
KH=$(kit_home) || exit 2
LOGDIR="$KH/disk-sweep"; mkdir -p -- "$LOGDIR" || exit 2
LOG="$LOGDIR/cron.log"
log() { local l; l="$(date '+%Y-%m-%d %H:%M') disk-sweep-cron: $*"; printf '%s\n' "$l"; printf '%s\n' "$l" >> "$LOG" 2>/dev/null; }
[ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || { log "FAILED: not inside a git repo and no --repo"; exit 2; }
if [ -e "$KH/disk-sweep.off" ]; then log "the scheduled sweep is turned off ($KH/disk-sweep.off); nothing to do"; exit 0; fi

# ── one sweep per machine ────────────────────────────────────────────────────────────────────────────────────────────────────
LOCK="$KH/disk-sweep.lock"
if [ -z "${KIT_SWEEP_LOCKED:-}" ]; then
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$LOCK" || { log "FAILED: cannot open the lock $LOCK"; exit 2; }
    flock -n 9 || { log "another disk sweep is running; this one exits"; exit 0; }
  elif command -v perl >/dev/null 2>&1; then
    # perl takes the lock (flock(2), held by the kernel) and execs this script again with the lock fd kept open ($^F).
    KIT_SWEEP_LOCKED=1 perl -MFcntl=:flock -e '$^F = 255; my $l = shift; open(my $f, ">>", $l) or exit 74;
      flock($f, LOCK_EX | LOCK_NB) or exit 75; exec @ARGV or exit 127' "$LOCK" bash "$0" ${orig_args[@]+"${orig_args[@]}"}
    rc=$?
    [ "$rc" -eq 75 ] && { log "another disk sweep is running; this one exits"; exit 0; }
    [ "$rc" -eq 74 ] && { log "FAILED: cannot open the lock $LOCK"; exit 2; }
    exit "$rc"
  else
    # no flock and no perl: a lock folder that names its owner; a dead owner's folder is taken over once.
    if ! mkdir "$LOCK.d" 2>/dev/null; then
      owner=$(cat "$LOCK.d/pid" 2>/dev/null)
      if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then log "another disk sweep is running; this one exits"; exit 0; fi
      rm -rf -- "$LOCK.d"; mkdir "$LOCK.d" 2>/dev/null || { log "another disk sweep is running; this one exits"; exit 0; }
    fi
    echo $$ > "$LOCK.d/pid"; trap 'rm -rf -- "$LOCK.d"' EXIT
  fi
fi

if [ "$ifdue" = 1 ]; then
  why=$(disk_sweep_due "$repo" "$KH" "$floor_only") || { log "not due any more (another session's sweep started it); nothing to do"; exit 0; }
  log "due: $why"
fi
main=$(disk_sweep_main "$repo") || { log "FAILED: $repo is not a git repo"; exit 2; }
STAMP=$(disk_sweep_stamp "$KH" "$main")
mkdir -p -- "$(dirname "$STAMP")" && date +%s > "$STAMP" || { log "FAILED: cannot write the stamp $STAMP"; exit 2; }

free=$(disk_sweep_free_gb "$repo")
if ! [[ "$free" =~ ^[0-9]+$ ]]; then log "UNKNOWN: free space on $repo could not be read; not sweeping"; exit 3; fi

FIRST="$KH/disk-sweep.first-run-done"
if [ -e "$FIRST" ]; then mode=--apply
else mode=--dry-run; log "first run on this machine: dry run (nothing is removed; from the next run the sweep removes what its report lists)"; fi
pre=()
command -v nice >/dev/null 2>&1 && pre+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && pre+=(ionice -c3)
SWEEP="${KIT_SWEEP_CRON_SWEEP:-$HERE_DIR/disk-sweep.sh}"
log "sweeping $repo (${free} GB free, $mode)"
out=$(${pre[@]+"${pre[@]}"} bash "$SWEEP" --repo "$repo" "$mode" 2>&1); rc=$?
printf '%s\n' "$out" >> "$LOG" 2>/dev/null
report=$(printf '%s\n' "$out" | sed -n 's/^disk-sweep: report //p' | tail -1)
if [ "$rc" -ne 0 ]; then log "FAILED: the sweep exited $rc"; exit "$rc"; fi
# The next session start shows the report: always after the first run, and later when something needs a decision.
if [ "$mode" = --dry-run ] || printf '%s\n' "$out" | grep -q '^disk-sweep: needs a decision'; then
  [ -n "$report" ] && printf '%s\n%s\n' "$report" "$mode" > "$LOGDIR/unseen-report"
fi
[ "$mode" = --dry-run ] && : > "$FIRST"
log "sweep exited 0; report ${report:-none}"
exit 0
