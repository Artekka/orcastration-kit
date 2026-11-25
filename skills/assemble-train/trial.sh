#!/usr/bin/env bash
# trial.sh (orcastration-kit, assemble-train): simulate merging a rider onto a base without touching any ref.
# Run as:  B=<base commit> R=<rider commit> bash trial.sh      (in the train's repo)
# Named variables only: the skill loader replaces positional tokens in a rendered skill with its arguments.
# Prints: the merge result (RC=0 clean, 1 conflict, with git's conflict messages), then for every file the
# RIDER changed (merge-base..R) which side's blob the merged tree holds:
#   RIDER   = the rider's blob landed            TRAIN = the base's blob kept (the rider's change did not land)
#   SAME    = the base already holds the rider's blob (cherry-picked, or the same change made twice)
#   NEITHER = a 3-way result: verify it by content (apply the rider's patch to the train's copy)
# Last, a SYNTH commit (parents B and R) to chain the next trial on:  B=<SYNTH> R=<next rider> bash trial.sh
# A rider that is already an ancestor of the base prints ALREADY-ON-TRAIN, and its SYNTH is the base itself.
B=${B:?set B=<base commit>}; R=${R:?set R=<rider commit>}
git rev-parse -q --verify "$B^{commit}" >/dev/null || { echo "B=$B is not a commit here" >&2; exit 2; }
git rev-parse -q --verify "$R^{commit}" >/dev/null || { echo "R=$R is not a commit here" >&2; exit 2; }
if git merge-base --is-ancestor "$R" "$B"; then
  echo "rider $R onto $B: ALREADY-ON-TRAIN (the rider is an ancestor of the base: merging it changes nothing)"
  echo "SYNTH $(git rev-parse "$B")"; exit 0
fi
OUT=$(git -c core.quotePath=false merge-tree --write-tree --name-only --messages "$B" "$R"); RC=$?
[ "$RC" -le 1 ] || { echo "merge-tree failed (rc $RC): $OUT" >&2; exit 2; }
T=$(printf '%s\n' "$OUT" | head -1)
echo "rider $R onto $B: RC=$RC tree=${T:0:8}"
[ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | tail -n +2
MB=$(git merge-base "$B" "$R")
git -c core.quotePath=false diff -z --name-only "$MB" "$R" | while IFS= read -r -d "" f; do
  t=$(git rev-parse -q --verify "$T:$f" || echo ABSENT); r=$(git rev-parse -q --verify "$R:$f" || echo ABSENT)
  h=$(git rev-parse -q --verify "$B:$f" || echo ABSENT)
  if [ "$t" = "$r" ] && [ "$r" = "$h" ]; then s=SAME; elif [ "$t" = "$r" ]; then s=RIDER; elif [ "$t" = "$h" ]; then s=TRAIN; else s=NEITHER; fi
  echo "  $s $f"
done
echo "SYNTH $(echo trial | git commit-tree "$T" -p "$B" -p "$R")"
exit "$RC"
