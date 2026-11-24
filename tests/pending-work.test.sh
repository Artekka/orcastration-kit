#!/usr/bin/env bash
# Tests for scripts/pending-work.sh: ported from the project that grew the script, with its fix history.
# Run: bash tests/pending-work.test.sh   (PENDING_SCRIPT=<path> points the run at a mutant copy)
# Safety: every repo is a throwaway under mktemp (a bare "origin" plus a clone); committer dates are planted so every age is
# exact against a fixed PENDING_NOW; PENDING_NO_FETCH=1, no network; git config is isolated.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PW="${PENDING_SCRIPT:-$ROOT/scripts/pending-work.sh}"
pass=0; fail=0; SANDBOXES=()
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
cleanup() { local d; for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G() { git "$@" >/dev/null 2>&1; }

NOW=1800000000; H=3600; D=86400
BOARD_PATH=docs/orchestration/AGENT_BOARD.md

# repo NAME: R=<work clone>, RO=<its bare origin>, both under a fresh sandbox; main starts empty.
repo() {
  SB="$(mktemp -d)"; SANDBOXES+=("$SB"); R="$SB/$1"; RO="$SB/$1-origin.git"
  git init -q --bare -b main "$RO"; mkdir -p "$R"; git -C "$R" init -q -b main; git -C "$R" remote add origin "$RO"
}
# cm FILE CONTENT WHEN [MSG]: one commit on the current branch, dated WHEN (seconds since the epoch).
cm() {
  mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; G -C "$R" add "$1"
  GIT_AUTHOR_DATE="@$3 +0000" GIT_COMMITTER_DATE="@$3 +0000" git -C "$R" commit -q -m "${4:-$1}" >/dev/null 2>&1
}
# br NAME [START]: a new branch (default off main); co BRANCH: switch.
br() { G -C "$R" checkout -q -b "$1" "${2:-main}"; }
co() { G -C "$R" checkout -q "$1"; }
sha() { git -C "$R" rev-parse HEAD; }
# pw <env pairs...> -- <args...> -> RC OUT ERR, run inside $R
pw() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  RC=0
  ( cd "$R" && env PENDING_NO_FETCH=1 PENDING_NOW="$NOW" "${envs[@]}" bash "$PW" "$@" ) >"$SB/out" 2>"$SB/err" </dev/null || RC=$?
  OUT="$(cat "$SB/out")"; ERR="$(cat "$SB/err")"
}
# jl SECTION: the sorted branch names of a --json section, one per line; jid: the ids.
jl() { python3 -c 'import json,sys; print("\n".join(sorted(r["branch"] for r in json.load(sys.stdin)[sys.argv[1]])))' "$1" <"$SB/out"; }
jid() { python3 -c 'import json,sys; print("\n".join(sorted(r["id"] for r in json.load(sys.stdin)[sys.argv[1]])))' "$1" <"$SB/out"; }
all_branches() { python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(r["branch"] for k in d for r in d[k]))' <"$SB/out"; }
b() { echo "origin/feat/$1"; }

# ---- the main fixture: one branch per case, one board committed ON MAIN (the script reads it with `git show`)
repo work
BOARD="✅ KIT900-1 delta READ PASS derived (merged already)
✅ KIT900-2 READ PASS derived, waiting on the seat
✅ KIT900-4 CLEARED (its commit was cherry-picked to main)
KIT900-3 is still building
KIT900-8 READ PASS (the branch is older than a week)
✅ KIT901-1 READ PASS (r0; its r1 shipped through another branch)
✅ KIT902-1 READ PASS (main only names KIT902-10, a different row)
✅ KIT903-1 READ PASS (main only names it in a docs commit)
KIT904-1 built · 93-B READ PASS derived (the PASS belongs to the shorthand row)
KIT905-1 sent back to the builder; 129 r2 delta PASS (also shorthand)
✅ KIT906-1 15:3x READ PASS (a clock time is not shorthand)
✅ KIT907-1 READ PASS (main only mentions it in a commit BODY)"
cm base.txt base $((NOW - 6*D))
br feat/kit900-3; cm three.txt three $((NOW - 20*H)); co main            # IDLE and behind: cut from the 6-day-old base
br feat/kit900-9; cm nine.txt nine $((NOW - 1800)); co main              # BEHIND: a 30-minute-old tip on the 6-day-old base
br feat/kit900-1; cm one.txt one $((NOW - 3*D)); co main
GIT_AUTHOR_DATE="@$((NOW - 3*D)) +0000" GIT_COMMITTER_DATE="@$((NOW - 3*D)) +0000" G -C "$R" merge --no-ff -q -m "merge 900-1" feat/kit900-1
# 901-1: the stale r0 branch stays; its r1 merged into main with the row id in the subject
br feat/kit901-1; cm r0.txt r0 $((NOW - 8*H)); co main
br feat/kit901-1-r1; cm r1.txt r1 $((NOW - 7*H)) "fix: KIT901-1 r1 the real fix"; co main
GIT_AUTHOR_DATE="@$((NOW - 6*H)) +0000" GIT_COMMITTER_DATE="@$((NOW - 6*H)) +0000" G -C "$R" merge --no-ff -q -m "merge KIT901-1 r1" feat/kit901-1-r1
for n in 902-1 903-1 904-1 905-1 906-1 907-1; do br "feat/kit$n"; cm "$n.txt" "$n" $((NOW - 5*H)); co main; done
cm ten.txt ten $((NOW - 4*H)) "fix: KIT902-10 a different row"
cm heldback.txt h $((NOW - 270*60)) "fix: an unrelated change

KIT907-1 held back, rebuild without it"
cm boardnote.txt n $((NOW - 210*60)) "docs(board): KIT903-1 READ PASS noted"
br feat/kit900-4; cm four.txt four $((NOW - 4*H)) four; co main
GIT_AUTHOR_DATE="@$((NOW - 3*H)) +0000" GIT_COMMITTER_DATE="@$((NOW - 3*H)) +0000" G -C "$R" cherry-pick feat/kit900-4   # same patch, new SHA
cm "$BOARD_PATH" "$BOARD" $((NOW - H)) tip
br feat/kit900-2; cm two.txt two $((NOW - 1800)); co main                # PASSED, NOT ON MAIN: 30 min old, based on the main tip
br feat/kit900-5; cm five.txt five $((NOW - 5*H)); co main               # IDLE: 5 h old
br feat/kit900-6; cm six.txt six $((NOW - 600)); co main                 # fresh: nothing to say
br feat/kit900-8; cm eight.txt eight $((NOW - 9*D)); co main             # older than the 7-day window
G -C "$R" push -q origin --all; G -C "$R" fetch -q origin
# the working tree's board clears nothing; only the copy on origin/main names the cleared rows
printf 'a stale working copy that clears nothing\n' > "$R/$BOARD_PATH"

pw -- --json; eq "T1 exit" 3 "$RC"
eq "T1 PASSED, NOT ON MAIN lists the cleared, unmerged rows" "$(printf '%s\n' "$(b kit900-2)" "$(b kit902-1)" "$(b kit903-1)" "$(b kit906-1)" "$(b kit907-1)")" "$(jl passed_not_on_main)"
row=$(python3 -c 'import json; d=json.load(open("'"$SB"'/out"))["passed_not_on_main"]; r=[x for x in d if x["id"]=="KIT900-2"][0]; print(r["age"], r["tip"], r["reason"])')
has "T1 age is 30m" "30m " "$row"; has "T1 reason counts the commit" "1 commit" "$row"
case "$row" in *" "[0-9a-f]????????" "*) ok ;; *) bad "T1 tip is 9 hex chars: $row" ;; esac
all="$(all_branches)"
hasnt "T2 merged (ancestor of main) not listed" "$(b kit900-1)" "$all"
hasnt "T3 patch-equivalent on main (git cherry) not listed" "$(b kit900-4)" "$all"
hasnt "T4 a stale r0 is dropped when a non-docs commit on main names its row" "$(b kit901-1)" "$all"
has "T5 exact id boundary: main naming KIT902-10 does not ship KIT902-1" KIT902-1 "$(jid passed_not_on_main)"
has "T6 a docs commit naming the row does not ship it" KIT903-1 "$(jid passed_not_on_main)"
has "T7 only a SUBJECT ships a row; a body saying held back does not" KIT907-1 "$(jid passed_not_on_main)"
hasnt "T8 a keyword after bare shorthand '93-B' is not blamed on the id before it" KIT904-1 "$(jid passed_not_on_main)"
hasnt "T8 same for '129 r2'" KIT905-1 "$(jid passed_not_on_main)"
has "T9 a clock time is not shorthand" KIT906-1 "$(jid passed_not_on_main)"
eq "T10 IDLE: unmerged, not-passed, tip older than 2 h" "$(printf '%s\n' "$(b kit900-3)" "$(b kit900-5)" "$(b kit904-1)" "$(b kit905-1)")" "$(jl idle)"
hasnt "T11 stale AND behind reads IDLE, not BEHIND" "$(b kit900-3)" "$(jl behind_main)"
eq "T12 BEHIND MAIN: recent tip on a base more than 2 h older than main" "$(b kit900-9)" "$(jl behind_main)"
has "T12 behind reason" "behind origin/main" "$(python3 -c 'import json; print(json.load(open("'"$SB"'/out"))["behind_main"][0]["reason"])')"
hasnt "T13 a fresh branch is skipped" "$(b kit900-6)" "$all"
hasnt "T13 an out-of-window branch is skipped" "$(b kit900-8)" "$all"
eq "T13 a branch is listed once" "$(printf '%s\n' "$all" | sort | uniq | wc -l)" "$(printf '%s\n' "$all" | wc -l)"
eq "T14 json has no hub section" 0 "$(python3 -c 'import json; print(int("hub_approvals" in json.load(open("'"$SB"'/out"))))')"
pw --; eq "T15 text exit" 3 "$RC"
has "T15 header passed" "== PASSED, NOT ON MAIN (5) ==" "$OUT"; has "T15 header behind" "== BEHIND MAIN (1) ==" "$OUT"
has "T15 header idle" "== IDLE (4) ==" "$OUT"; has "T15 header unpushed" "== UNPUSHED GREEN-FINAL (0) ==" "$OUT"
hasnt "T15 no hub section" "HUB" "$OUT"
case "$OUT" in *"KIT900-2 · origin/feat/kit900-2 · "*" · 30m · "*) ok ;; *) bad "T15 row shape: $OUT" ;; esac

# 16. nothing pending: exit 0 and a line saying so (and the repo has no board)
repo clean; cm a.txt a $((NOW - D)); G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw --; eq "T16 exit 0" 0 "$RC"; has "T16 says nothing pending" "nothing pending" "$OUT"

# 17. usage: an unknown argument, and --help, exit 2; a missing main ref exits 2 naming it
pw -- --nope; eq "T17 unknown arg exit" 2 "$RC"; has "T17 names the argument" "--nope" "$ERR"
pw -- --help; eq "T17 --help exit" 2 "$RC"; has "T17 --help shows usage" "Usage:" "$ERR"
repo nomain; cm a.txt a $((NOW - D)); pw -- ; eq "T17 no origin/main exit" 2 "$RC"; has "T17 says which ref" "origin/main" "$ERR"
pw PENDING_MAIN_REF=origin/trunk -- ; eq "T17 PENDING_MAIN_REF is honored (a missing ref)" 2 "$RC"; has "T17 names origin/trunk" "origin/trunk" "$ERR"

# ---- UNPUSHED GREEN-FINAL: a reported GREEN-FINAL SHA (or cleared branch) that is on NO remote
repo up
cm base.txt base $((NOW - 3*D)); G -C "$R" push -q origin main
declare -A SH
br feat/kit910-1; cm 910-1.txt a $((NOW - 2*H)); SH[1]=$(sha); co main                  # reported, never pushed -> LISTED
br feat/kit910-2; cm 910-2.txt b $((NOW - 2*H)); SH[2]=$(sha); G -C "$R" push -q origin feat/kit910-2; co main   # pushed
br feat/kit910-3; cm 910-3.txt c $((NOW - 2*H)); SH[3]=$(sha); co main                  # patch reached main under another SHA
GIT_AUTHOR_DATE="@$((NOW - 90*60)) +0000" GIT_COMMITTER_DATE="@$((NOW - 90*60)) +0000" G -C "$R" cherry-pick feat/kit910-3
br feat/kit910-5; cm 910-5.txt e $((NOW - 2*H)); SH[5]=$(sha); co main                  # the board says NOT GREEN-FINAL
br feat/kit910-6; cm 910-6.txt f $((NOW - 2*H)); SH[6]=$(sha); co main                  # main names the row -> shipped
cm 910-6-main.txt m $((NOW - 80*60)) "fix: KIT910-6 shipped through r1"
cm 910-8-r0.txt r0 $((NOW - 3*H)) "fix: KIT910-8 r0 shipped"                              # named BEFORE the r1 tip: hides nothing
br feat/hotfix-r1; cm 910-8.txt r1 $((NOW - 90*60)); SH[8]=$(sha); co main
cm 910-9-r0.txt r0 $((NOW - 3*H)) "fix: KIT910-9 r0 shipped"
br feat/kit910-9; cm 910-9.txt r1 $((NOW - 90*60)); co main                               # same shape through the local-branch path
br feat/kit910-7; cm 910-7.txt g $((NOW - 2*H)); co main                                  # cleared with NO sha, branch never pushed
UBOARD="✅ KIT910-1 GREEN-FINAL ${SH[1]:0:9} gate green
✅ KIT910-2 GREEN-FINAL ${SH[2]:0:9} gate green
✅ KIT910-3 GREEN-FINAL ${SH[3]:0:9} gate green
✅ KIT910-4 GREEN-FINAL deadbeefcafe0 (a hash no commit has)
KIT910-5 not GREEN-FINAL ${SH[5]:0:9} yet
✅ KIT910-6 GREEN-FINAL ${SH[6]:0:9} gate green
✅ KIT910-7 READ PASS derived
✅ KIT910-8 r1 GREEN-FINAL ${SH[8]:0:9} gate green
✅ KIT910-9 r1 READ PASS derived"
cm "$BOARD_PATH" "$UBOARD" $((NOW - H)) tip; G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw -- --json
eq "T20 lists the unpushed GREEN-FINAL rows" "$(printf '%s\n' KIT910-1 KIT910-7 KIT910-8 KIT910-9)" "$(jid unpushed_green_final)"
for id in KIT910-2 KIT910-3 KIT910-4 KIT910-5 KIT910-6; do hasnt "T21 $id not listed" "$id" "$(jid unpushed_green_final)"; done
one=$(python3 -c 'import json; d=json.load(open("'"$SB"'/out"))["unpushed_green_final"]; r=[x for x in d if x["id"]=="KIT910-1"][0]; print(r["branch"], r["tip"], r["reason"])')
has "T22 names the local branch" "feat/kit910-1 " "$one"; has "T22 9-char tip" "${SH[1]:0:9} " "$one"; has "T22 why" "on no remote" "$one"
pw --; eq "T23 text exit" 3 "$RC"; has "T23 header" "== UNPUSHED GREEN-FINAL (4) ==" "$OUT"
case "$OUT" in *"KIT910-1 · feat/kit910-1 · "[0-9a-f]????????" · "*) ok ;; *) bad "T23 row shape: $OUT" ;; esac
G -C "$R" push -q origin feat/kit910-1; G -C "$R" fetch -q origin
pw -- --json; eq "T24 pushing the branch clears the row" "$(printf '%s\n' KIT910-7 KIT910-8 KIT910-9)" "$(jid unpushed_green_final)"

# ---- config hooks (nothing project-specific is baked in)
# 25. row_id_regex: a project whose rows read T-12 (the default regex wants PREFIX+NUMBER-NUMBER)
repo cfg
cm base.txt base $((NOW - 3*D)); G -C "$R" push -q origin main
br feat/t-12; cm t12.txt t $((NOW - 30*60)); G -C "$R" push -q origin feat/t-12; co main
cm "$BOARD_PATH" "✅ T-12 READ PASS derived" $((NOW - H)) tip; G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw -- --json; hasnt "T25 the default row regex does not read T-12" T-12 "$(jid passed_not_on_main)"
pw PENDING_ROW_REGEX='T-[0-9]+' -- --json; eq "T25 PENDING_ROW_REGEX reads T-12" T-12 "$(jid passed_not_on_main)"
eq "T25 and names its branch" "$(b t-12)" "$(jl passed_not_on_main)"

# 26. docs prefixes: which commit subjects do NOT count as shipping. Default: docs( and docs:
repo pref
cm base.txt base $((NOW - 3*D)); G -C "$R" push -q origin main
br feat/kit920-1; cm k.txt k $((NOW - 3*H)); G -C "$R" push -q origin feat/kit920-1; co main
cm n.txt n $((NOW - 2*H)) "chore(board): KIT920-1 noted"
cm "$BOARD_PATH" "✅ KIT920-1 READ PASS derived" $((NOW - H)) tip; G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw -- --json; eq "T26 a chore(board) commit naming the row ships it (not a docs prefix by default)" "" "$(jid passed_not_on_main)"
pw PENDING_DOCS_PREFIXES='docs( docs: chore(board)' -- --json; eq "T26 PENDING_DOCS_PREFIXES makes chore(board) a docs prefix" KIT920-1 "$(jid passed_not_on_main)"
pw PENDING_DOCS_PREFIXES='chore(board)' -- --json; eq "T26 a replaced list drops docs( as well" KIT920-1 "$(jid passed_not_on_main)"

# 27. board and archive paths: env, and the pending_work: block of ORCHESTRATION.md (env wins)
repo paths
cm base.txt base $((NOW - 3*D)); G -C "$R" push -q origin main
br feat/kit930-1; cm k.txt k $((NOW - 30*60)); G -C "$R" push -q origin feat/kit930-1; co main
cm notes/BOARD.md "✅ KIT930-1 READ PASS derived" $((NOW - H)) board
cm docs/orchestration/ORCHESTRATION.md "pending_work:
  board_path:     notes/BOARD.md
  archive_path:   notes/old" $((NOW - H)) conf
G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw -- --json; eq "T27 board_path from the pending_work: block" KIT930-1 "$(jid passed_not_on_main)"
pw PENDING_BOARD_PATH=nowhere.md -- --json; eq "T27 env wins over the block" "" "$(jid passed_not_on_main)"
# archive: a dated archive file inside the window is read; one older than the window is not
cm notes/old/BOARD_ARCHIVE_2027-01-14.md "✅ KIT930-1 GREEN-FINAL cleared long ago" $((NOW - H)) arch
cm notes/BOARD.md "nothing cleared here" $((NOW - H)) board2
G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw -- --json; eq "T27 an archive inside the window clears the row" KIT930-1 "$(jid passed_not_on_main)"
pw PENDING_DAYS=0.01 -- --json; eq "T27 PENDING_DAYS narrows the window" "" "$(jid passed_not_on_main)"
pw PENDING_STALE_HOURS=6 -- --json; eq "T27 PENDING_STALE_HOURS is honored (no IDLE at 6 h)" "" "$(jid idle)"

# 27b. the CONFIG-FILE path of docs_prefixes and row_id_regex (the env path is covered above); the environment wins over the block
repo pref2
cm base.txt base $((NOW - 3*D)); G -C "$R" push -q origin main
br feat/kit921-1; cm k.txt k $((NOW - 3*H)); G -C "$R" push -q origin feat/kit921-1; co main
br feat/t-77; cm t.txt t $((NOW - 30*60)); G -C "$R" push -q origin feat/t-77; co main
cm n.txt n $((NOW - 2*H)) "chore(board): KIT921-1 noted"
cm docs/orchestration/ORCHESTRATION.md "pending_work:
  docs_prefixes:  docs( chore(board)
  row_id_regex:   T-[0-9]+" $((NOW - H)) conf
cm "$BOARD_PATH" "✅ KIT921-1 READ PASS derived
✅ T-77 READ PASS derived" $((NOW - H)) tip
G -C "$R" push -q origin main; G -C "$R" fetch -q origin
pw -- --json; eq "T27b row_id_regex from the block reads T-77 (and not KIT921-1)" T-77 "$(jid passed_not_on_main)"
pw PENDING_ROW_REGEX='KIT[0-9]+-[0-9]+' -- --json; eq "T27b the environment wins over the block's row_id_regex (KIT921-1 reads, T-77 does not)" KIT921-1 "$(jid passed_not_on_main)"
pw PENDING_ROW_REGEX='KIT[0-9]+-[0-9]+|T-[0-9]+' -- --json; eq "T27b docs_prefixes from the block: chore(board) is docs-only, so KIT921-1 is still pending" "KIT921-1
T-77" "$(jid passed_not_on_main)"
pw PENDING_ROW_REGEX='KIT[0-9]+-[0-9]+|T-[0-9]+' PENDING_DOCS_PREFIXES='docs(' -- --json; eq "T27b the environment wins over the block's docs_prefixes (chore(board) now ships KIT921-1)" T-77 "$(jid passed_not_on_main)"

# 28. the script carries nothing project-specific and is read-only
S="$(cat "$PW" 2>/dev/null)"
for w in ORCA sprite hub-approvals PENDING_HUB mockup_review; do hasnt "T28 no '$w' in the script" "$w" "$S"; done
before=$(git -C "$R" for-each-ref | md5sum); pw -- --json; eq "T28 refs are unchanged by a run" "$before" "$(git -C "$R" for-each-ref | md5sum)"

# 29. templates/ORCHESTRATION.md documents the pending_work: block (every hook); README and CHANGELOG name the script
tb="$(awk '/^pending_work:[[:space:]]*$/{on=1;print;next} on&&/^[[:space:]]+[a-z_]+:/{print;next} on{exit}' "$ROOT/templates/ORCHESTRATION.md")"
for k in board_path archive_path row_id_regex docs_prefixes; do has "T29 template pending_work: block carries $k" "  $k:" "$tb"; done
has "T29 README has the script's row" 'scripts/pending-work.sh`' "$(cat "$ROOT/README.md")"
has "T29 CHANGELOG names the script" 'scripts/pending-work.sh' "$(cat "$ROOT/CHANGELOG.md")"

echo "pending-work: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
