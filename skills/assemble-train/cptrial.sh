#!/usr/bin/env bash
# cptrial.sh (orcastration-kit, assemble-train): simulate cherry-picking ONE commit onto a base (a rider that
# must land by cherry-pick, e.g. one whose branch also carries a commit that would revert a later fix).
# Run as:  B=<base commit> C=<commit to pick> bash cptrial.sh   (chain one call per commit, in order)
# Named variables only (the skill loader eats positionals). Same output as trial.sh; the SYNTH has ONE parent.
B=${B:?set B=<base commit>}; C=${C:?set C=<commit to pick>}
git rev-parse -q --verify "$B^{commit}" >/dev/null || { echo "B=$B is not a commit here" >&2; exit 2; }
P=$(git rev-parse -q --verify "$C^1") || { echo "C=$C has no parent here" >&2; exit 2; }
if git merge-base --is-ancestor "$C" "$B"; then
  echo "pick $C onto $B: ALREADY-ON-TRAIN (the commit is an ancestor of the base: picking it changes nothing)"
  echo "SYNTH $(git rev-parse "$B")"; exit 0
fi
OUT=$(git -c core.quotePath=false merge-tree --write-tree --name-only --messages --merge-base="$P" "$B" "$C"); RC=$?
[ "$RC" -le 1 ] || { echo "merge-tree failed (rc $RC): $OUT" >&2; exit 2; }
T=$(printf '%s\n' "$OUT" | head -1)
echo "pick $C onto $B: RC=$RC tree=${T:0:8}"
[ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | tail -n +2
git -c core.quotePath=false diff -z --name-only "$P" "$C" | while IFS= read -r -d "" f; do
  t=$(git rev-parse -q --verify "$T:$f" || echo ABSENT); r=$(git rev-parse -q --verify "$C:$f" || echo ABSENT)
  h=$(git rev-parse -q --verify "$B:$f" || echo ABSENT)
  if [ "$t" = "$r" ] && [ "$r" = "$h" ]; then s=SAME; elif [ "$t" = "$r" ]; then s=RIDER; elif [ "$t" = "$h" ]; then s=TRAIN; else s=NEITHER; fi
  echo "  $s $f"
done
echo "SYNTH $(echo trial | git commit-tree "$T" -p "$B")"
exit "$RC"
