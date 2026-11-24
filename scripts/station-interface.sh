#!/usr/bin/env bash
# kit-init's interface question: CLI (the default) or the Orcastration Station window.
# Usage: bash scripts/station-interface.sh <cli|station> [--overlay FILE]    (run from the plugin, never copied into a project)
#   cli      the default. Writes NOTHING when the overlay has no `interface:` line; when it holds `station`, sets it back to `cli`.
#   station  sets `interface: station` in the team block (adds the line under `terminal:` if missing) and PRINTS the two
#            install paths. It runs nothing: no cargo, curl, gh, git or wsl. Prebuilt binaries arrive in 0.17.0.
# The overlay is docs/orchestration/ORCHESTRATION.md unless --overlay says otherwise. Exit 0 done, 64 bad usage, 2 no overlay.
set -u
CHOICE="${1:-}"; [ $# -gt 0 ] && shift
OVERLAY=docs/orchestration/ORCHESTRATION.md
while [ $# -gt 0 ]; do
  case "$1" in
    --overlay) OVERLAY="${2:?--overlay needs a file}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done
case "$CHOICE" in cli|station) ;; *) echo "usage: station-interface.sh <cli|station> [--overlay FILE]" >&2; exit 64 ;; esac
[ -f "$OVERLAY" ] || { echo "no overlay at $OVERLAY (run kit-init's copy step first)" >&2; exit 2; }

has_line() { grep -qE '^[[:space:]]+interface:' "$OVERLAY"; }
set_line() {  # replace the value of the existing line, or add the line under `terminal:` in the team block
  local tmp; tmp="$(mktemp)"
  if has_line; then
    sed -E "s/^([[:space:]]+interface:[[:space:]]*)[A-Za-z]+/\1$1/" "$OVERLAY" > "$tmp"
  else
    awk -v v="$1" '{print} /^[[:space:]]+terminal:/ && !done {match($0,/^[[:space:]]+/); printf "%sinterface:        %s\n", substr($0,1,RLENGTH), v; done=1}' "$OVERLAY" > "$tmp"
  fi
  cat "$tmp" > "$OVERLAY"; rm -f "$tmp"
}

if [ "$CHOICE" = cli ]; then
  if has_line && ! grep -qE '^[[:space:]]+interface:[[:space:]]*cli([[:space:]]|#|$)' "$OVERLAY"; then set_line cli; echo "interface: cli (was station)"
  else echo "interface: cli (the default; nothing changed)"; fi
  exit 0
fi
grep -qE '^[[:space:]]+terminal:' "$OVERLAY" || { echo "the overlay has no team block with a terminal: line; add 'interface: station' by hand" >&2; exit 2; }
set_line station
cat <<'TXT'
interface: station (written to the overlay)

Orcastration Station, adapted from Omar's Observatory: a Windows window (plus a WSL bridge) for watching and typing to your agents.
Nothing was installed or started. There are two ways to get it; the README section "Orcastration Station" has the full steps:
  1. Prebuilt binaries: arrive in 0.17.0 (not available in this version).
  2. Build from source, in WSL, from a checkout of the kit repository (a plugin cache copy is not one):
       cd station && bash scripts/deploy.sh --dry-run --install-root <a Windows folder under /mnt/c>
     then the same command without --dry-run. It needs rustup, the x86_64-pc-windows-gnu target and MinGW.
TXT
