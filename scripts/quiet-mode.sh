#!/usr/bin/env bash
# quiet-mode.sh (orchestration-kit): free the machine for the human (a game, a call, a render) without
# killing anything. While quiet mode is on, scripts/gate-throttle.sh starts no NEW command; running ones
# finish. Sessions should also hold off on their own heavy work (headless browsers, renders) until it is off.
# Usage: bash scripts/quiet-mode.sh on|off|status
# State: the flag file "$KIT_RUNTIME_DIR/quiet-mode" (default ~/.orchestration-kit/runtime), shared with
# gate-throttle.sh. The status lists what the throttle is running and who is waiting, from the throttle's
# own records (no process-name guessing).
set -u
RT="${KIT_RUNTIME_DIR:-$HOME/.orchestration-kit/runtime}"
FLAG="$RT/quiet-mode"

# The same start-time function as gate-throttle.sh (see there): the two must agree, or no waiter is listed.
proc_start() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    s="$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20)"
    [ -n "$s" ] && { printf '%s' "$s"; return; }
  fi
  ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'
}

status() {
  if [ -f "$FLAG" ]; then echo "quiet mode: ON (since $(cat "$FLAG"))"; else echo "quiet mode: OFF"; fi
  # Deploy mode (a priority gate is running and the others are confined, see gate-throttle.sh): ON only while its owner is the
  # same live process (pid + start time), so a dead owner's leftover state reads OFF.
  local da="$RT/deploy-mode/active" dpid dstart deploy="OFF"
  if [ -f "$da" ]; then
    dpid="$(sed -n 's/^pid=//p' "$da" | head -n1)"; dstart="$(sed -n 's/^lstart=//p' "$da" | head -n1)"
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null && [ "$(proc_start "$dpid")" = "$dstart" ]; then
      deploy="ON ($(sed -n 's/^cwd=//p' "$da" | head -n1))"
    fi
  fi
  echo "deploy mode: $deploy"
  local f pid any=0
  echo "--- running (slot, dir, command)"
  for f in "$RT"/running/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"
    # a run entry is two lines: slot/dir/command, then the holder's start time (pid reuse = not the holder)
    if kill -0 "$pid" 2>/dev/null && [ "$(proc_start "$pid")" = "$(sed -n 2p "$f")" ]; then
      printf '  pid %s  %s\n' "$pid" "$(sed -n 1p "$f" | tr '\t' ' ')"; any=1
    else
      rm -f "$f"   # a dead holder's record; its kernel lock is already gone
    fi
  done
  [ "$any" = 1 ] || echo "  none"
  echo "--- waiting, in order (#position pid dir)"
  local pos=0
  for f in $(ls "$RT/queue" 2>/dev/null | grep -E '^[0-9]{10}\.[0-9]+$' | sort); do
    pid="${f#*.}"
    # the same liveness rule as gate-throttle.sh: the pid AND the start time recorded in the ticket
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(proc_start "$pid")" = "$(sed -n 2p "$RT/queue/$f" 2>/dev/null)" ] || continue
    pos=$((pos + 1)); printf '  #%s pid %s  %s\n' "$pos" "$pid" "$(sed -n 1p "$RT/queue/$f" 2>/dev/null)"
  done
  [ "$pos" -gt 0 ] || echo "  none"
  if [ -r /proc/loadavg ]; then echo "--- load: $(cut -d' ' -f1-3 /proc/loadavg)"; fi
  if command -v free >/dev/null 2>&1; then echo "--- memory"; free -g 2>/dev/null | grep '^Mem:'; fi
  return 0
}

case "${1:-}" in
  on) mkdir -p "$RT" && date '+%Y-%m-%dT%H:%M:%S%z' > "$FLAG"; status ;;
  off) rm -f "$FLAG"; status ;;
  status) status ;;
  *) echo "usage: quiet-mode.sh on|off|status" >&2; exit 64 ;;
esac
