#!/usr/bin/env bash
# Guard: no kit test may reach the CALLER'S tmux. Since the tmux port, sibling-shell.sh runs
# `tmux rename-window -t $TMUX_PANE <Name>`, so a suite run inside a tmux pane renamed the REAL window (ZzW...), and the
# `tmux` backend of lib-launch.sh keys on $TMUX. Every test file must therefore unset both before it starts anything, and
# tests/run.sh must start each file without them. Run: bash tests/no-real-tmux.test.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
SELF="no-real-tmux.test.sh"

# 1. static: run.sh starts every file without TMUX / TMUX_PANE; every test file unsets them before its first command
grep -q 'env -u TMUX -u TMUX_PANE bash "\$t"' "$ROOT/tests/run.sh" && ok || bad "run.sh does not start each test with env -u TMUX -u TMUX_PANE"
for f in "$ROOT"/tests/*.test.sh; do
  n="$(basename "$f")"; [ "$n" = "$SELF" ] && continue
  first="$(grep -n -v -E '^[[:space:]]*(#|$)' "$f" | head -1)"
  unsetn="$(grep -n -E '^unset TMUX TMUX_PANE' "$f" | head -1 | cut -d: -f1)"
  if [ -z "$unsetn" ]; then bad "$n never runs 'unset TMUX TMUX_PANE'"
  elif [ "${first%%:*}" -lt "$unsetn" ] && ! printf '%s' "$first" | grep -q -E '^[0-9]+:set -'; then bad "$n runs a command before 'unset TMUX TMUX_PANE': ${first#*:}"
  else ok; fi
done

# 2. dynamic: the suites that start launchers, run with a fake pane and a logging tmux on PATH, call no tmux at all
case "$ROOT" in *" "*) echo "no-real-tmux: dynamic half skipped (the checkout path has a space, so the launcher suites skip themselves and prove nothing)"; echo "no-real-tmux: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; exit ;; esac
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT; mkdir -p "$SB/bin"
printf '#!/usr/bin/env bash\necho "tmux $*" >> "%s/tmux.log"\nexit 0\n' "$SB" > "$SB/bin/tmux"; chmod +x "$SB/bin/tmux"
: > "$SB/tmux.log"
for f in $(grep -l -E 'sibling-shell\.sh|recycle-sibling\.sh|start-team\.sh|lib-launch\.sh' "$ROOT"/tests/*.test.sh); do
  n="$(basename "$f")"
  case "$n" in "$SELF"|tmux-session.test.sh) continue ;; esac   # tmux-session stubs its own tmux and starts with env -u itself
  : > "$SB/tmux.log"
  TMUX="$SB/fake-sock,1,0" TMUX_PANE=%99 PATH="$SB/bin:$PATH" bash "$f" >/dev/null 2>&1 </dev/null
  if [ -s "$SB/tmux.log" ]; then bad "$n called tmux with a fake pane: $(head -2 "$SB/tmux.log" | tr '\n' '|')"; else ok; fi
done
echo "no-real-tmux: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
