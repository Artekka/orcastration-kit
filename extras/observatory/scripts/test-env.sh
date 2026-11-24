#!/usr/bin/env bash
# Guard for scripts/env.sh: each tree must build into ITS OWN cargo target dir.
# Usage: bash scripts/test-env.sh        Last line: "TEST-ENV ALL PASS (<n> checks)" or "TEST-ENV FAILED <n>".
#
# Makes two throwaway worktrees of HEAD in a unique mktemp dir (A, and B = A plus one extra #[test] in
# core's fixtures_test), copies THIS tree's env.sh + gate.sh into both, then checks:
#   T4 FIRST, the cross-tree repro, order B, A, B, with A's files forced OLDER than B's build (the
#      condition under which a shared dir hands A B's binary): each run must report its own count
#   T1 derivation: root == subdir, A != B, name shape, the dir exists after sourcing (deploy writes into it)
#   T2 a caller-set dir OUTSIDE the rust dir ($OBSERVATORY_RUST_DIR, default ~/observatory-rust) survives sourcing, gate.sh, gate-throttle (normalized)
#   T3 table of spellings: refused ones exit non-zero with REFUSED; own-dir spellings resolve to own
#   T5 refusal under `bash -i scripts/gate.sh` stops the gate; interactive sourcing unsets the value
# Concurrent runs are safe (unique paths). Writes only under its mktemp dir and the two trees' target
# dirs under <rust dir>/targets; all removed on exit.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BASE=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/observatory-test-env.XXXXXX") || exit 1
# This tree's folder inside its git repo ("" at the repo root): A and B are that folder in each worktree.
PFX=$(git -C "$ROOT" rev-parse --show-prefix)
WA=$BASE/te-a; WB=$BASE/te-b; A=$WA/$PFX; B=$WB/$PFX; A=${A%/}; B=${B%/}; CUSTOM=$BASE/custom-target
# The kit's gate-throttle.sh: this tree's own copy, else the repo root's.
THROTTLE=$ROOT/scripts/gate-throttle.sh
[ -f "$THROTTLE" ] || THROTTLE="$(git -C "$ROOT" rev-parse --show-toplevel)/scripts/gate-throttle.sh"
OR=${OBSERVATORY_RUST_DIR:-$HOME/observatory-rust}
FX=crates/core/tests/fixtures_test.rs
td() { (cd "$1" && unset CARGO_TARGET_DIR && . "$(git rev-parse --show-toplevel)/${PFX}scripts/env.sh" && echo "$CARGO_TARGET_DIR"); }
cleanup() {
  for t in "$WA" "$WB"; do
    [ -d "$t" ] || continue
    d=$(td "$t" 2>/dev/null); case "$d" in "$OR/targets/te-"?-????????) rm -rf "$d" ;; esac
    git -C "$ROOT" worktree remove --force "$t" 2>/dev/null
  done
  rm -rf "$BASE"
}
trap cleanup EXIT
for w in "$WA" "$WB"; do
  git -C "$ROOT" worktree add -q --detach "$w" HEAD || { echo "TEST-ENV FAILED setup"; exit 1; }
  t=$w/$PFX; cp "$ROOT/scripts/env.sh" "$t/scripts/env.sh"; cp "$ROOT/scripts/gate.sh" "$t/scripts/gate.sh"
done
printf '\n#[test]\nfn only_in_tree_b() {}\n' >> "$B/$FX"
na=$(grep -c '^#\[test\]' "$A/$FX"); nb=$(grep -c '^#\[test\]' "$B/$FX")

nf=0; np=0
ok() { echo "PASS $1"; np=$((np+1)); }
bad() { echo "FAIL $1"; nf=$((nf+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2' want '$3'"; fi; }
[ "$nb" -eq $((na+1)) ] && ok "T0 test sets differ ($na vs $nb)" || bad "T0 setup: $na vs $nb"

# T4 first: nothing has built tree A yet.
fixtures() { (cd "$1" && unset CARGO_TARGET_DIR && . scripts/env.sh && cargo test -p observatory-core --test fixtures_test 2>&1) |
  grep -E '^test result:' | sed -E 's/.*ok\. ([0-9]+) passed.*/\1/'; }
chk "T4 tree b runs its own fixtures_test" "$(fixtures "$B")" "$nb"
find "$A" -path "$A/.git" -prune -o -type f -exec touch -d '2 days ago' {} +
chk "T4 tree a (sources older than b's build) runs its own" "$(fixtures "$A")" "$na"
chk "T4 tree b again" "$(fixtures "$B")" "$nb"

ta=$(td "$A"); tb=$(td "$B")
chk "T1 subdir == root" "$(td "$A/crates/core")" "$ta"
[ "$ta" != "$tb" ] && ok "T1 trees differ" || bad "T1 trees share $ta"
case "$ta" in "$OR/targets/te-a-"????????) ok "T1 name shape" ;; *) bad "T1 name shape $ta" ;; esac
[ -d "$ta" ] && ok "T1 dir exists after sourcing" || bad "T1 $ta not created"
nd=$(cd "$A" && CARGO_TARGET_DIR=$CUSTOM/new bash -c '. scripts/env.sh && [ -d "$CARGO_TARGET_DIR" ] && echo yes')
chk "T1 an override dir is created too" "$nd" "yes"

src() { (cd "$A" && CARGO_TARGET_DIR=$1 bash -c '. scripts/env.sh && echo "$CARGO_TARGET_DIR"' 2>/dev/null); }
chk "T2 outside override respected" "$(src "$CUSTOM")" "$CUSTOM"
chk "T2 outside override normalized" "$(src "$CUSTOM//x/../")" "$CUSTOM"
got=$(cd "$A" && CARGO_TARGET_DIR=$CUSTOM timeout 20 bash scripts/gate.sh 2>&1 | grep '^gate target:')
chk "T2 override survives gate.sh" "$got" "gate target: $CUSTOM"
got=$(cd "$A" && CARGO_TARGET_DIR=$CUSTOM GATE_SLOTS=99 timeout 60 bash "$THROTTLE" bash scripts/gate.sh 2>&1 | grep '^gate target:')
chk "T2 override survives gate-throttle" "$got" "gate target: $CUSTOM"

ln -s "$OR/target" "$BASE/link-to-old"
rel_old=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$OR/target" "$A")
rel_b=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$tb" "$A")
bname=${tb#"$OR/targets/"}; aname=${ta#"$OR/targets/"}
refuse=("$OR/target" "$OR/target/" "$OR/target//" "${OR%/*}//${OR##*/}/target" "$OR/./target"
  "$BASE/link-to-old" "$rel_old" "~/observatory-rust/target" "$OR//targets/$bname" "$rel_b" "$tb"
  "$OR" "$OR/targets" "$OR/anything-else")
for v in "${refuse[@]}"; do
  out=$(cd "$A" && CARGO_TARGET_DIR=$v bash -c '. scripts/env.sh && echo "LEAK $CARGO_TARGET_DIR"' 2>&1); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q 'env.sh: REFUSED' && ! echo "$out" | grep -q LEAK; then
    ok "T3 refused '$v'"; else bad "T3 NOT refused '$v' (rc=$rc): $out"; fi
done
for v in "$ta" "$OR//targets/$aname" "$OR/targets/./$aname/" "$OR/x/../targets/$aname"; do
  chk "T3 own-dir spelling '$v' resolves to own" "$(src "$v")" "$ta"
done

out=$(cd "$A" && CARGO_TARGET_DIR=$OR/target timeout 20 bash -i scripts/gate.sh 2>&1); rc=$?
if [ $rc -ne 0 ] && ! echo "$out" | grep -qE '^gate tree|GATE PASS'; then ok "T5 bash -i gate.sh stops on refusal (rc=$rc)"
else bad "T5 bash -i gate.sh went on (rc=$rc): $(echo "$out" | grep -E '^gate' | head -2)"; fi
out=$(cd "$A" && CARGO_TARGET_DIR=$OR/target bash -ic '. scripts/env.sh; echo "rc=$? val=${CARGO_TARGET_DIR:-unset}"' 2>&1)
echo "$out" | grep -q 'rc=1 val=unset' && ok "T5 interactive source: return 1, value unset" || bad "T5 interactive: $out"

if [ $nf -eq 0 ]; then echo "TEST-ENV ALL PASS ($np checks)"; else echo "TEST-ENV FAILED $nf"; exit 1; fi
