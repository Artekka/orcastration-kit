#!/usr/bin/env bash
# Train skills: the assembler's trial helpers and the auditor's merge sweep, run against a throwaway repo
# whose riders cover every case the skills name (clean, 3-way NEITHER, conflict, cherry-pick-only), plus a
# train landed with one clean merge, one hand-resolved merge and one single commit. Also pins the deploy
# policy knob (default ask) in the overlay template and the seat's skill.
# The helpers take NAMED variables only (B=, R=, C=, L=, BASE=, TIP=): the skill loader replaces positional
# tokens in a rendered skill, so a helper that read positionals would get the invocation's args instead.
# Run: bash tests/train.test.sh      (needs bash, git >= 2.38 for merge-tree --write-tree; no network)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }

ASM="$ROOT/skills/assemble-train"; AUD="$ROOT/skills/audit-train"
for f in "$ASM/trial.sh" "$ASM/cptrial.sh" "$ASM/gsum.sh" "$AUD/audit.sh"; do
  [ -f "$f" ] && ok || bad "missing helper $f"
done

# ---- the repo -------------------------------------------------------------------------------------
R="$TMP/repo"; git init -q -b main "$R"; cd "$R" || exit 1
seq 1 9 > a.txt; seq 1 9 > b.txt; echo c > c.txt; echo d > d.txt
git add -A && git commit -qm base; BASE0=$(git rev-parse HEAD)
# r1: clean, a.txt line 2 only
git checkout -q -b r1 "$BASE0"; sed -i 's/^2$/two/' a.txt; git commit -qam r1; R1=$(git rev-parse HEAD)
# r2: a.txt line 2 differently (conflicts with r1) + c.txt
git checkout -q -b r2 "$BASE0"; sed -i 's/^2$/TWO/' a.txt; echo c2 > c.txt; git commit -qam r2; R2=$(git rev-parse HEAD)
# r3: b.txt line 8 (the train also edits b.txt line 1 below, so b.txt merges 3-way = NEITHER) + d.txt
git checkout -q -b r3 "$BASE0"; sed -i 's/^8$/eight/' b.txt; echo d3 > d.txt; git commit -qam r3; R3=$(git rev-parse HEAD)
# r4: two commits; only the second is wanted (cherry-pick-only rider)
git checkout -q -b r4 "$BASE0"; echo junk > c.txt; git commit -qam r4a; sed -i 's/^9$/nine/' a.txt; git commit -qam r4b; R4B=$(git rev-parse HEAD)
# the train: base + one train-only commit on b.txt line 1
git checkout -q -b train "$BASE0"; sed -i 's/^1$/one/' b.txt; git commit -qam "train: b line 1"; TIP0=$(git rev-parse HEAD)

# ---- trial.sh ------------------------------------------------------------------------------------
out="$(B=$TIP0 R=$R1 bash "$ASM/trial.sh" 2>&1)"
has "trial clean: RC=0" "RC=0" "$out"
has "trial clean: a.txt won by the rider" "RIDER a.txt" "$out"
hasnt "trial clean: the train-only file is not the rider's" "b.txt" "$out"
S1=$(printf '%s\n' "$out" | sed -n 's/^SYNTH //p')
[ -n "$S1" ] && [ "$(git rev-parse "$S1^1")" = "$TIP0" ] && [ "$(git rev-parse "$S1^2")" = "$R1" ] && ok \
  || bad "trial clean: SYNTH is not a 2-parent commit TIP0+R1: '$S1'"
[ "$(git rev-parse train)" = "$TIP0" ] && ok || bad "trial moved a ref"

out="$(B=$S1 R=$R2 bash "$ASM/trial.sh" 2>&1)"
has "trial chained conflict: RC=1" "RC=1" "$out"
has "trial chained conflict: names the file" "a.txt" "$out"

out="$(B=$TIP0 R=$R2 bash "$ASM/trial.sh" 2>&1)"
has "trial r2 alone: clean against the train" "RC=0" "$out"

out="$(B=$S1 R=$R3 bash "$ASM/trial.sh" 2>&1)"
has "trial 3-way: RC=0" "RC=0" "$out"
has "trial 3-way: b.txt is NEITHER side's blob" "NEITHER b.txt" "$out"
has "trial 3-way: d.txt is the rider's" "RIDER d.txt" "$out"
hasnt "trial 3-way: an earlier rider's file is not listed" "a.txt" "$out"

# the train already carries the rider's edit plus one more hunk: the merged blob is the TRAIN's, not the rider's
git checkout -q -b r5 "$BASE0"; sed -i 's/^5$/five/' a.txt; git commit -qam r5; R5=$(git rev-parse HEAD)
git checkout -q -b t5 "$BASE0"; sed -i -e 's/^5$/five/' -e 's/^7$/seven/' a.txt; git commit -qam t5; T5=$(git rev-parse HEAD)
out="$(B=$T5 R=$R5 bash "$ASM/trial.sh" 2>&1)"
has "trial: a rider edit the train already holds (plus more) shows TRAIN" "TRAIN a.txt" "$out"

# READ MED-1: a rider that is ALREADY on the train. Merged: an ancestor of the base. Cherry-picked: every file's
# merged blob = the rider's = the base's, which must not read as "the rider's blob landed".
git checkout -q -b t6 "$TIP0"; git merge -q --no-ff -m "t6 has r1" "$R1" >/dev/null 2>&1; T6=$(git rev-parse HEAD)
out="$(B=$T6 R=$R1 bash "$ASM/trial.sh" 2>&1)"
has "trial: a rider merged into the base is flagged" "ALREADY-ON-TRAIN" "$out"
git checkout -q -b t7 "$TIP0"; git cherry-pick "$R1" >/dev/null 2>&1 || bad "setup: cherry-pick of r1 onto t7 failed"; T7=$(git rev-parse HEAD)
out="$(B=$T7 R=$R1 bash "$ASM/trial.sh" 2>&1)"
has "trial: a cherry-picked rider's file reads SAME" "SAME a.txt" "$out"
hasnt "trial: ...not RIDER" "RIDER a.txt" "$out"
hasnt "trial: a cherry-pick is not an ancestor" "ALREADY-ON-TRAIN" "$out"
out="$(B=$T7 C=$R1 bash "$ASM/cptrial.sh" 2>&1)"
has "cptrial: a commit the base already holds reads SAME" "SAME a.txt" "$out"
# READ 4b LOW: a commit that is an ANCESTOR of the base (T6 holds r1 by merge) is flagged and its SYNTH is the base
out="$(B=$T6 C=$R1 bash "$ASM/cptrial.sh" 2>&1)"; rc=$?
has "cptrial: an ancestor commit is flagged" "ALREADY-ON-TRAIN" "$out"
has "cptrial: ...and its SYNTH is the base itself" "SYNTH $T6" "$out"
[ "$rc" -eq 0 ] && ok || bad "cptrial: ALREADY-ON-TRAIN must exit 0, got $rc"

# READ MED-2: non-ASCII paths (git quotes them in --name-only output unless told not to)
git checkout -q -b b8 "$BASE0"; seq 1 9 > "é.txt"; git add "é.txt"; git commit -qm b8; B8=$(git rev-parse HEAD)
git checkout -q -b r8 "$B8"; sed -i 's/^8$/eight/' "é.txt"; echo u > "ü.txt"; git add "ü.txt"; git commit -qam r8; R8=$(git rev-parse HEAD)
git checkout -q -b t8 "$B8"; sed -i 's/^1$/one/' "é.txt"; git commit -qam t8; T8=$(git rev-parse HEAD)
out="$(B=$T8 R=$R8 bash "$ASM/trial.sh" 2>&1)"
has "trial non-ASCII: a both-sides 3-way merge is NEITHER" "NEITHER é.txt" "$out"
has "trial non-ASCII: a rider-only new file is RIDER" "RIDER ü.txt" "$out"
out="$(B=$T8 C=$R8 bash "$ASM/cptrial.sh" 2>&1)"
has "cptrial non-ASCII: NEITHER" "NEITHER é.txt" "$out"
git checkout -q train

out="$(R=$R1 bash "$ASM/trial.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "trial without B= must fail"
has "trial without B= names the variable" "B=" "$out"
out="$(bash "$ASM/trial.sh" "$TIP0" "$R1" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "trial must ignore positional args (got rc 0)"
# READ LOW-4: no positional FALLBACK either (`B=${B:-<first arg>}` would pass the line above when R is unset)
out="$(R=$R1 bash "$ASM/trial.sh" "$TIP0" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "trial: B from a positional arg must not be taken (got rc 0)"
has "trial: names B= even when an arg is given" "B=" "$out"
out="$(B=$TIP0 bash "$ASM/cptrial.sh" "$R4B" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "cptrial: C from a positional arg must not be taken (got rc 0)"

# ---- cptrial.sh ----------------------------------------------------------------------------------
out="$(B=$TIP0 C=$R4B bash "$ASM/cptrial.sh" 2>&1)"
has "cptrial: RC=0" "RC=0" "$out"
has "cptrial: only the picked commit's file" "RIDER a.txt" "$out"
hasnt "cptrial: the skipped parent commit's file stays out" "c.txt" "$out"
SC=$(printf '%s\n' "$out" | sed -n 's/^SYNTH //p')
[ -n "$SC" ] && [ "$(git rev-list --parents -n1 "$SC" | wc -w)" -eq 2 ] && [ "$(git show "$SC:c.txt")" = c ] && ok \
  || bad "cptrial: SYNTH must be one-parent with c.txt untouched: '$SC'"
out="$(B=$TIP0 bash "$ASM/cptrial.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "cptrial without C= must fail"

# ---- gsum.sh -------------------------------------------------------------------------------------
L="$TMP/gate.log"
printf '%s\n' "setup noise" "  Test Files  12 passed (12)" "      Tests  340 passed | 2 todo (342)" "chatter" "GATE GREEN" "REAL_EXIT=0" > "$L"
out="$(L=$L bash "$ASM/gsum.sh" 2>&1)"
has "gsum: the Tests line" "340 passed" "$out"
has "gsum: the exit line" "REAL_EXIT=0" "$out"
hasnt "gsum: noise dropped" "chatter" "$out"
out="$(L=$L GSUM_RE='chatter' bash "$ASM/gsum.sh" 2>&1)"
has "gsum: the project's own pattern wins" "chatter" "$out"
out="$(bash "$ASM/gsum.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "gsum without L= must fail"

# ---- land a train, then audit it -----------------------------------------------------------------
git merge -q --no-ff -m "merge(train): r1" "$R1"; M1=$(git rev-parse HEAD)
git merge -q --no-ff -m "merge(train): r3" "$R3" >/dev/null 2>&1; M3=$(git rev-parse HEAD)
git merge --no-ff -m "merge(train): r2 (hand-resolved a.txt)" "$R2" >/dev/null 2>&1
sed -i -e '/^<<<<<<<\|^=======\|^>>>>>>>/d' -e '/^two$/d' a.txt; git add a.txt; git commit -qm "merge(train): r2 (hand-resolved a.txt)"; M2=$(git rev-parse HEAD)
git cherry-pick -x "$R4B" >/dev/null 2>&1; P4=$(git rev-parse HEAD)
TIP=$(git rev-parse HEAD)

out="$(BASE=$TIP0 TIP=$TIP bash "$AUD/audit.sh" 2>&1)"
n=$(printf '%s\n' "$out" | grep -cE '^(MERGE|SINGLE) ')
[ "$n" -eq 4 ] && ok || bad "audit: want 4 first-parent lines, got $n: $out"
has "audit: clean merge r1" "MERGE ${M1:0:9} p2=${R1:0:9} mt_rc=0 tree_eq=YES" "$out"
has "audit: 3-way merge r3 is still tree-equal" "MERGE ${M3:0:9} p2=${R3:0:9} mt_rc=0 tree_eq=YES" "$out"
has "audit: the hand-resolved merge" "MERGE ${M2:0:9} p2=${R2:0:9} mt_rc=1 tree_eq=NO" "$out"
has "audit: the resolved path is listed" "resolved: a.txt" "$out"
has "audit: the cherry-pick is a SINGLE" "SINGLE ${P4:0:9}" "$out"
first=$(printf '%s\n' "$out" | grep -E '^(MERGE|SINGLE) ' | head -1)
has "audit: oldest first" "${M1:0:9}" "$first"
# the rider ids are ordinary commits, not first-parent; they must not appear as lines
hasnt "audit: rider commits are not swept" "SINGLE ${R1:0:9}" "$out"
# READ LOW-1: the exit code reflects the WHOLE sweep: 0 = every merge tree-equal, 1 = something to explain
BASE=$TIP0 TIP=$TIP bash "$AUD/audit.sh" >/dev/null 2>&1; rc=$?
eq_rc() { [ "$2" = "$3" ] && ok || bad "$1: want rc $2, got $3"; }
eq_rc "audit: a resolved merge (not last) makes the sweep exit 1" 1 "$rc"
BASE=$TIP0 TIP=$M3 bash "$AUD/audit.sh" >/dev/null 2>&1; rc=$?
eq_rc "audit: all merges tree-equal exits 0" 0 "$rc"

# READ 4b LOW: the "resolved:" list prints a non-ASCII path as written (git quotes it as "\303\251.txt" unless told not to)
git checkout -q -b t9 "$T8"; git merge -q --no-ff -m "merge(train): r8" "$R8" >/dev/null 2>&1 || bad "setup: t9 merge of r8 failed"
echo hand-edit >> "é.txt"; git commit -qa --amend --no-edit; T9=$(git rev-parse HEAD)
out="$(BASE=$T8 TIP=$T9 bash "$AUD/audit.sh" 2>&1)"; rc=$?
has "audit non-ASCII: the merge is not tree-equal" "tree_eq=NO" "$out"
has "audit non-ASCII: the resolved path is listed as written" "resolved: é.txt" "$out"
eq_rc "audit non-ASCII: exits 1" 1 "$rc"
# READ 4b LOW: an octopus merge is never swept silently: it prints OCTOPUS and the sweep exits 1
git checkout -q -b t10 "$BASE0"; git merge -q --no-ff -m "octopus r1 r3" "$R1" "$R3" >/dev/null 2>&1 || bad "setup: octopus merge failed"
T10=$(git rev-parse HEAD)
out="$(BASE=$BASE0 TIP=$T10 bash "$AUD/audit.sh" 2>&1)"; rc=$?
has "audit octopus: flagged" "OCTOPUS ${T10:0:9} parents=3" "$out"
eq_rc "audit octopus: exits 1" 1 "$rc"
git checkout -q train

# approved list: every p2 must be named in it
printf '%s\n' "$R1" "$R3" > "$TMP/approved"
out="$(BASE=$TIP0 TIP=$TIP APPROVED="$TMP/approved" bash "$AUD/audit.sh" 2>&1)"
has "audit approved: r1 is approved" "p2=${R1:0:9} approved=YES" "$out"
has "audit approved: r2 is NOT in the list" "p2=${R2:0:9} approved=NO" "$out"
printf '%s\n' "$R1" > "$TMP/approved1"
BASE=$TIP0 TIP=$M3 APPROVED="$TMP/approved1" bash "$AUD/audit.sh" >/dev/null 2>&1; rc=$?
eq_rc "audit: a clean merge missing from the approved list exits 1" 1 "$rc"
out="$(TIP=$TIP bash "$AUD/audit.sh" "$TIP0" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "audit: BASE from a positional arg must not be taken (got rc 0)"

# runs against the repo it is called in, never a fixed path
out="$(cd "$TMP" && BASE=$TIP0 TIP=$TIP bash "$AUD/audit.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "audit outside a repo must fail"
out="$(TIP=$TIP bash "$AUD/audit.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "audit without BASE= must fail"
has "audit without BASE= names the variable" "BASE=" "$out"

# ---- deploy policy knob --------------------------------------------------------------------------
T="$ROOT/templates/ORCHESTRATION.md"; O="$ROOT/skills/orchestrate/SKILL.md"
dep="$(awk '/^## Deploy/{on=1;next} /^## /{on=0} on' "$T")"
printf '%s\n' "$dep" | grep -Eq '^deploy_policy:[[:space:]]+ask([[:space:]]|$)' && ok || bad "template Deploy: want 'deploy_policy: ask' as the default: $dep"
has "template Deploy: names the other value" "auto-when-green" "$dep"
s7="$(awk '/^## 7 /{on=1;next} /^## /{on=0} on' "$O")"
has "orchestrate §7 reads deploy_policy" "deploy_policy" "$s7"
has "orchestrate §7: ask" "ask" "$s7"
has "orchestrate §7: auto-when-green" "auto-when-green" "$s7"

# ---- the skills point at their helpers and carry no project-private text --------------------------
for s in "$ASM/SKILL.md" "$AUD/SKILL.md"; do
  [ -f "$s" ] && ok || { bad "missing $s"; continue; }
  head -5 "$s" | grep -q '^name: ' && ok || bad "$s: no frontmatter name"
done
has "assemble-train calls trial.sh" "trial.sh" "$(cat "$ASM/SKILL.md" 2>/dev/null)"
has "assemble-train calls cptrial.sh" "cptrial.sh" "$(cat "$ASM/SKILL.md" 2>/dev/null)"
has "audit-train calls audit.sh" "audit.sh" "$(cat "$AUD/SKILL.md" 2>/dev/null)"
priv="$(grep -nIiE 'pnpm|vitest|/home/|AIDriver|strandh' "$ASM"/* "$AUD"/* 2>/dev/null)"
[ -z "$priv" ] && ok || bad "train skills carry project-specific text: $priv"

echo "train: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
