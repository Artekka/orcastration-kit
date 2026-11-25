#!/usr/bin/env bash
# lib-disk-sweep-launch.sh (orcastration-kit): decides whether the scheduled disk sweep is due and starts it in the background.
# Sourced by hooks/session-start.sh (at most once a day, or under the floor) and scripts/gate-disk-guard.sh (under the floor only).
# Source lib-kit-home.sh first. Bash 3.2+. Functions only; nothing here waits for the sweep or fails its caller.
#
#   disk_sweep_launch_if_due <repo> [floor]
#     0 = a sweep was started · 1 = the sweep is turned off · 2 = not due · 3 = not started (KIT_SWEEP_AUTO=0, the repo did not
#     opt in to the kit's hooks, or the state folder is unusable). "floor" = start only when free space is under the floor.
#     Due (per project: each project has its own stamp): no run yet, the last start is over a day old (KIT_SWEEP_EVERY_S, default 86400), or free space is under the floor
#     (KIT_SWEEP_FLOOR_GB, else `disk_sweep_floor_gb:` in the team block, else 50) and the last start is over an hour old.
#   The wrapper (disk-sweep-cron.sh --if-due) checks again under its lock, so ten sessions starting together run ONE sweep.
#   Test seam: KIT_SWEEP_LAUNCH, a command run (in the foreground) with the repo instead of the real background start.
_DSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

disk_sweep_main() { local c; c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1; (cd "$(dirname "$c")" && pwd -P); }
# disk_sweep_repokey <main checkout>: the project's name in the kit's state folder (the folder name plus a number from its path,
# so two checkouts named alike do not share a stamp, a report folder or a save folder).
disk_sweep_repokey() { printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | cksum | awk '{print $1 % 100000}')"; }
# disk_sweep_stamp <kit home> <main checkout>: the file holding the epoch second this project's last sweep started.
disk_sweep_stamp() { printf '%s/disk-sweep/last/%s' "$1" "$(disk_sweep_repokey "$2")"; }
# disk_sweep_first_marker <kit home> <main checkout>: present once this project's first (dry) run is done.
disk_sweep_first_marker() { printf '%s/disk-sweep/first-run-done/%s' "$1" "$(disk_sweep_repokey "$2")"; }
disk_sweep_free_gb() { "${KIT_SWEEP_DF:-df}" -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print int($4/1024/1024)}'; }
disk_sweep_floor_gb() {  # $1 main checkout
  local f="${KIT_SWEEP_FLOOR_GB:-}"
  [ -n "$f" ] || f=$(sed -n 's/^[[:space:]]*disk_sweep_floor_gb:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/docs/orchestration/ORCHESTRATION.md" 2>/dev/null | head -n1)
  [[ "${f:-}" =~ ^[0-9]+$ ]] || f=50
  echo "$f"
}
# disk_sweep_due <repo> <kit home> [floor]: prints why it is due and returns 0, or returns 1.
disk_sweep_due() {
  local main last now age free floor every
  main=$(disk_sweep_main "$1") || return 1
  now=$(date +%s); last=$(cat "$(disk_sweep_stamp "$2" "$main")" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=""
  age=$(( now - ${last:-0} ))
  every="${KIT_SWEEP_EVERY_S:-86400}"; [[ "$every" =~ ^[0-9]+$ ]] || every=86400
  free=$(disk_sweep_free_gb "$main"); floor=$(disk_sweep_floor_gb "$main")
  if [[ "$free" =~ ^[0-9]+$ ]] && [ "$free" -lt "$floor" ] && [ "$age" -ge 3600 ]; then echo "${free} GB free is under the ${floor} GB floor"; return 0; fi
  [ "${3:-}" = floor ] && return 1
  if [ -z "$last" ]; then echo "no sweep has run for this project yet"; return 0; fi
  if [ "$age" -ge "$every" ]; then echo "the last sweep started over a day ago"; return 0; fi
  return 1
}
# disk_sweep_detach <cmd...>: starts the command in its own session, input and output closed, and returns at once.
disk_sweep_detach() {
  if command -v setsid >/dev/null 2>&1; then setsid "$@" </dev/null >/dev/null 2>&1 &
  elif command -v perl >/dev/null 2>&1; then perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' "$@" </dev/null >/dev/null 2>&1 &
  else nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
}
disk_sweep_launch_if_due() {
  local repo=$1 mode=${2:-} kh main
  [ "${KIT_SWEEP_AUTO:-1}" = 0 ] && return 3
  main=$(disk_sweep_main "$repo") || return 3
  [ -f "$main/docs/orchestration/.kit-hooks" ] || return 3
  kh=$(kit_home 2>/dev/null) || return 3
  [ -e "$kh/disk-sweep.off" ] && return 1
  disk_sweep_due "$main" "$kh" "$mode" >/dev/null || return 2
  if [ -n "${KIT_SWEEP_LAUNCH:-}" ]; then "$KIT_SWEEP_LAUNCH" "$main" >/dev/null 2>&1; return 0; fi
  disk_sweep_detach bash "$_DSL_DIR/disk-sweep-cron.sh" --repo "$main" --if-due ${mode:+--floor-only}
  return 0
}
