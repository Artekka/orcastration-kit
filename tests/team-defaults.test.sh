#!/usr/bin/env bash
# Tests for scripts/team-defaults.sh (your own team defaults applied to a project's team: block).
# Run: bash tests/team-defaults.test.sh   (sandboxed: temp state dir and repos)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TD="$ROOT/scripts/team-defaults.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
rc_is() { [ "$2" = "$3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: want exit $2, got $3"; }; }
td() { env KIT_STATE_DIR="$TMP/state" bash "$TD" "$@" 2>&1; }
mk() { mkdir -p "$1/docs/orchestration"; cp "$ROOT/templates/ORCHESTRATION.md" "$1/docs/orchestration/ORCHESTRATION.md"; }
blk() { awk '/^team:/{on=1;next} on&&/^[[:space:]]/{print;next} on{exit}' "$1/docs/orchestration/ORCHESTRATION.md"; }

R="$TMP/Book Shop"; mk "$R"
out="$(td --repo "$R")"; rc_is "no defaults file: exit 0" 0 $?; has "says so" "nothing to apply" "$out"
has "no file: block untouched" "seat:             Orca" "$(blk "$R")"

mkdir -p "$TMP/state"
printf 'seat_prefix:  Atlas   # the seat\nnames:        Mars,Venus,Vulcan\nnumbered:     w\npermission_mode: auto\n' > "$TMP/state/team-defaults"
out="$(td --repo "$R" --dry-run)"; has "dry run lists" "team: seat -> Atlas-BS" "$out"
has "dry run writes nothing" "seat:             Orca" "$(blk "$R")"
out="$(td --repo "$R")"; rc_is "apply: exit 0" 0 $?
b="$(blk "$R")"
has "seat from the prefix and initials" "seat:             Atlas-BS" "$b"
has "existing key replaced in place" "permission_mode:  auto" "$b"
has "new key added" "names:            Mars,Venus,Vulcan" "$b"
has "numbered added" "numbered:         w" "$b"
hasnt "the old seat is gone" "Orca" "$b"
has "other keys kept" "worktrees:        advised" "$b"
out="$(td --repo "$R")"; [ "$(blk "$R" | grep -c '^  names:')" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rerun duplicated a key"; }

A="$TMP/appleAndApricot"; mk "$A"; td --repo "$A" >/dev/null; has "camelCase initials" "Atlas-AAA" "$(blk "$A")"
H="$TMP/hedgehog"; mk "$H"; td --repo "$H" >/dev/null; has "one word: two letters" "Atlas-HE" "$(blk "$H")"
N="$TMP/none"; mkdir -p "$N"; out="$(td --repo "$N")"; rc_is "no overlay: exit 1" 1 $?

# Saving the choice (kit-init asks once per machine).
S2="$TMP/state2"; t2() { env KIT_STATE_DIR="$S2" bash "$TD" "$@" 2>&1; }
out="$(t2 --show)"; [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL --show with nothing saved printed: $out"; }
out="$(t2 --save-kit)"; rc_is "save-kit: exit 0" 0 $?; has "save-kit: --show now prints" "the kit" "$(t2 --show)"
K="$TMP/kitnames"; mk "$K"; out="$(t2 --repo "$K")"; has "kit names: nothing applied" "nothing to apply" "$out"; has "kit names: Orca stays" "seat:             Orca" "$(blk "$K")"
out="$(t2 --save-own Atlas Ceres,Juno,Vesta --numbered w --mode auto)"; rc_is "save-own: exit 0" 0 $?
f="$(cat "$S2/team-defaults")"; has "save-own: seat" "seat_prefix:     Atlas" "$f"; has "save-own: names" "names:           Ceres,Juno,Vesta" "$f"; has "save-own: numbered" "numbered:        w" "$f"
O="$TMP/Lunch Diary"; mk "$O"; t2 --repo "$O" >/dev/null; has "own names applied" "seat:             Atlas-LD" "$(blk "$O")"
out="$(t2 --save-own 'At las' Ceres)"; rc_is "save-own: bad seat refused" 64 $?
out="$(t2 --save-own Atlas 'Ceres,Ju no')"; rc_is "save-own: bad name refused" 64 $?
# permission_mode: any mode lib-launch accepts (launch_valid_mode), nothing else.
out="$(t2 --save-own Atlas Ceres --mode accept-edits)"; rc_is "save-own: a valid mode" 0 $?; has "save-own: mode saved" "permission_mode: accept-edits" "$(cat "$S2/team-defaults")"
out="$(t2 --save-own Atlas Ceres --mode bogus)"; rc_is "save-own: bad mode refused" 64 $?
printf 'names: Ceres,Juno\npermission_mode: bogus\n' > "$S2/team-defaults"
M="$TMP/modes"; mk "$M"; out="$(t2 --repo "$M")"; has "apply: bad mode skipped, says so" "skipped permission_mode 'bogus'" "$out"
b="$(blk "$M")"; hasnt "apply: bad mode not written" "bogus" "$b"; has "apply: other keys still applied" "names:            Ceres,Juno" "$b"

# start-team reads the result: the seat and numbered pool names.
out="$(env HOME="$TMP" KIT_STATE_DIR="$TMP/state" TEAM_NAMES_SHUFFLE=0 WSL_DISTRO_NAME= WSL_INTEROP= TMUX= bash "$ROOT/scripts/start-team.sh" --dry-run --terminal manual --repo "$R" 2>&1)"
has "start-team: the seat" "LAUNCH Atlas-BS" "$out"; has "start-team: numbered" "LAUNCH w1-Mars" "$out"

echo "team-defaults: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
