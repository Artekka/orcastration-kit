#!/usr/bin/env bash
# Refuse to start a gate when free space is below the minimum. gate-throttle.sh runs it before it queues.
# WHY: leaked test-container volumes, old images and build output filled a host disk to 100%. A gate writes a lot
# (builds, containers), so it must not run into a full disk.
# Minimum, in GB: env KIT_GATE_MIN_FREE_GB, else `gate_min_free_gb:` in the team block of docs/orchestration/ORCHESTRATION.md
# (read from the MAIN checkout), else 20. 0 turns the guard off. The disk checked is KIT_GATE_DISK_PATH (default /).
# Exit 0 = go ahead (also when the free space cannot be read: never block on a measurement we do not have), 1 = refused.
# Seam for tests: KIT_DF_BIN (default `df`).
set -uo pipefail
min="${KIT_GATE_MIN_FREE_GB:-}"
if [ -z "$min" ]; then
  main="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  min="$(sed -n 's/^[[:space:]]*gate_min_free_gb:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${main:-.}/docs/orchestration/ORCHESTRATION.md" 2>/dev/null | head -n1)"
fi
min="${min:-20}"
[[ "$min" =~ ^[0-9]+$ ]] || { echo "WARNING: KIT_GATE_MIN_FREE_GB='$min' is not a number; using 20" >&2; min=20; }
[ "$min" -eq 0 ] && exit 0
path="${KIT_GATE_DISK_PATH:-/}"
avail_kb=$("${KIT_DF_BIN:-df}" -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')
[[ "$avail_kb" =~ ^[0-9]+$ ]] || { echo "disk guard: could not read free space; continuing" >&2; exit 0; }
free_gb=$((avail_kb / 1024 / 1024))
# Under the disk sweep's floor (KIT_SWEEP_FLOOR_GB, default 50) in a kit-adopted repo: start the background disk sweep early.
# It never waits and never changes this guard's answer (Art, 11-25: warn and sweep early, never refuse a worktree).
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "$LIBDIR/lib-disk-sweep-launch.sh" ] && [ -f "$LIBDIR/lib-kit-home.sh" ]; then
  ( . "$LIBDIR/lib-kit-home.sh" && . "$LIBDIR/lib-disk-sweep-launch.sh" && top=$(git rev-parse --show-toplevel 2>/dev/null) \
      && disk_sweep_launch_if_due "$top" floor \
      && echo "disk guard: ${free_gb} GB free is under the disk sweep floor; a background disk sweep started (its report: ~/.orcastration-kit/disk-sweep/)" ) 2>/dev/null || true
fi
if [ "$free_gb" -lt "$min" ]; then
  echo "⛔ GATE REFUSED: only ${free_gb} GB free on ${path} (need ${min}). Free some space (scripts/retro-worktrees.sh, scripts/docker-cache-cap.sh), or lower KIT_GATE_MIN_FREE_GB, then try again."
  exit 1
fi
exit 0
