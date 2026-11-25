# shellcheck shell=bash
# lib-mono-clock.sh: stage durations from the MONOTONIC clock. Sourced, never executed.
#   t0=$(mono_now) ... echo "took $(mono_elapsed "$t0")s"
# Why: bash's $SECONDS follows the realtime clock, and on a host whose realtime clock steps backward under load (a VM) a
# stage printed "took -1s" across a second boundary. /proc/uptime is CLOCK_BOOTTIME, which never steps back.
# $MONO_CLOCK_FILE replaces /proc/uptime (a test seam: a file whose first field is the seconds).
# A time line is display only, so nothing here may fail a caller: an unreadable clock or start prints 0, and so does a negative span.

# The clock's seconds (two decimals, as /proc/uptime has them), or nothing when it cannot be read.
# Always returns 0 and writes nothing to stderr. `2>/dev/null` comes BEFORE `<file` because bash applies redirections left to
# right; `read` returns 1 at EOF without a trailing newline yet still sets the field, so its status is ignored and the field
# decides; `|| :` keeps `t0=$(mono_now)` alive under `set -e`.
mono_now() {
  local up="" _
  read -r up _ 2>/dev/null <"${MONO_CLOCK_FILE:-/proc/uptime}" || :
  printf '%s' "$up"
}

# Whole seconds (rounded down, never below 0) from <t0, a mono_now value> to now.
mono_elapsed() {
  awk -v a="${1:-}" -v b="$(mono_now)" 'BEGIN {
    num = "^[0-9]+([.][0-9]+)?$"
    d = (a ~ num && b ~ num) ? b - a : 0
    printf "%d\n", (d > 0 ? int(d) : 0)
  }'
}
