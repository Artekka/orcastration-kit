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
if [ "$free_gb" -lt "$min" ]; then
  echo "⛔ GATE REFUSED: only ${free_gb} GB free on ${path} (need ${min}). Free some space (scripts/retro-worktrees.sh, scripts/docker-cache-cap.sh), or lower KIT_GATE_MIN_FREE_GB, then try again."
  exit 1
fi
exit 0
