#!/usr/bin/env bash
# gsum.sh (orcastration-kit, assemble-train): the verdict lines of a gate log, verbatim, with line numbers.
# Run as:  L=<gate log> bash gsum.sh        Optional GSUM_RE=<extended regex> = your gate's own summary lines
# (set it once from ORCHESTRATION.md -> Gate "pass proof"). Named variables only (the skill loader eats positionals).
L=${L:?set L=<gate log>}
[ -r "$L" ] || { echo "L=$L is not readable" >&2; exit 2; }
RE=${GSUM_RE:-'Test Files|^ *Tests? |[0-9]+ (passed|failed)|\bFAIL|GATE (GREEN|RED)|REAL_EXIT|exit code|ERROR'}
grep -nE "$RE" "$L" | cut -c1-200
exit 0
