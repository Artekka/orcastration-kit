#!/usr/bin/env bash
# kit-init's interface question (scripts/station-interface.sh): a CLI answer changes nothing; a Station answer sets one
# line in the overlay's team block, prints the two install paths and RUNS NOTHING (no cargo, curl, gh, git, wsl).
# Run: bash tests/station-interface.test.sh   (needs bash, awk, sed)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/station-interface.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
# Stand-ins that record any call: the script must never reach them.
mkdir -p "$SB/bin"
for c in cargo rustup curl wget gh git wsl.exe powershell.exe claude sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/called"\nexit 99\n' "$c" "$SB" > "$SB/bin/$c"; chmod +x "$SB/bin/$c"
done
run() { OUT="$(PATH="$SB/bin:$PATH" bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
fresh() { cp "$ROOT/templates/ORCHESTRATION.md" "$SB/o.md"; }

# 1. the shipped template defaults to cli
grep -qE '^[[:space:]]+interface:[[:space:]]+cli[[:space:]]' "$ROOT/templates/ORCHESTRATION.md" && ok || bad "1 the template does not default to 'interface: cli'"

# 2. a CLI answer on a template: the file is byte-identical
fresh; cp "$SB/o.md" "$SB/before.md"
run cli --overlay "$SB/o.md"
[ "$RC" -eq 0 ] && ok || bad "2 cli exited $RC: $OUT"
cmp -s "$SB/o.md" "$SB/before.md" && ok || bad "2 a CLI answer changed the overlay"

# 3. a CLI answer on an overlay with no interface: line (an older overlay): still byte-identical, no line added
grep -vE '^[[:space:]]+interface:' "$ROOT/templates/ORCHESTRATION.md" > "$SB/o.md"; cp "$SB/o.md" "$SB/before.md"
run cli --overlay "$SB/o.md"
cmp -s "$SB/o.md" "$SB/before.md" && ok || bad "3 a CLI answer added a line to an older overlay"

# 4. a Station answer: the value changes, only that line differs, both paths are printed
fresh; cp "$SB/o.md" "$SB/before.md"
run station --overlay "$SB/o.md"
[ "$RC" -eq 0 ] && ok || bad "4 station exited $RC: $OUT"
grep -qE '^[[:space:]]+interface:[[:space:]]+station' "$SB/o.md" && ok || bad "4 the overlay does not say 'interface: station'"
[ "$(diff "$SB/before.md" "$SB/o.md" | grep -c '^[<>]')" -eq 2 ] && ok || bad "4 more than the interface line changed"
echo "$OUT" | grep -q 'Prebuilt binaries: arrive in 0.17.0' && ok || bad "4 the prebuilt path is not stated"
echo "$OUT" | grep -q 'Build from source' && ok || bad "4 the build-from-source path is not printed"
echo "$OUT" | grep -q "adapted from Omar's Observatory" && ok || bad "4 the credit line is missing"

# 5. a Station answer runs nothing
[ -e "$SB/called" ] && bad "5 a stand-in program was called: $(cat "$SB/called")" || ok

# 6. a Station answer on an older overlay adds the line under terminal:, once; run twice = same file
grep -vE '^[[:space:]]+interface:' "$ROOT/templates/ORCHESTRATION.md" > "$SB/o.md"
run station --overlay "$SB/o.md"; cp "$SB/o.md" "$SB/once.md"; run station --overlay "$SB/o.md"
[ "$(grep -cE '^[[:space:]]+interface:' "$SB/o.md")" -eq 1 ] && ok || bad "6 the interface line is not exactly one"
cmp -s "$SB/o.md" "$SB/once.md" && ok || bad "6 a second Station answer changed the file again"
awk '/^[[:space:]]+terminal:/{t=NR} /^[[:space:]]+interface:/{i=NR} END{exit !(t && i==t+1)}' "$SB/o.md" && ok || bad "6 the line is not right under terminal:"

# 7. a CLI answer after a Station answer puts it back
run cli --overlay "$SB/o.md"
grep -qE '^[[:space:]]+interface:[[:space:]]+cli' "$SB/o.md" && ok || bad "7 cli did not set the line back"

# 8. bad use: no choice, a wrong word, no overlay
run; [ "$RC" -eq 64 ] && ok || bad "8 no choice exited $RC"
run maybe --overlay "$SB/o.md"; [ "$RC" -eq 64 ] && ok || bad "8 a wrong word exited $RC"
run station --overlay "$SB/none.md"; [ "$RC" -eq 2 ] && ok || bad "8 a missing overlay exited $RC"

# 9. kit-init asks the question and runs this script from the plugin, not from the project
K="$ROOT/skills/kit-init/SKILL.md"
grep -q 'station-interface.sh' "$K" && ok || bad "9 kit-init does not run station-interface.sh"
grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/station-interface.sh' "$K" && ok || bad "9 kit-init does not run it from the plugin root"
grep -q 'A `cli` answer writes nothing' "$K" && ok || bad "9 kit-init does not say a CLI answer writes nothing"

echo "station-interface: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
