#!/usr/bin/env bash
# Tests for scripts/kit-refresh.sh: kit-init's refresh of a project's script copies made on 0.16 (before the 0.17.0 id
# rename). A STALE copy (differs from the kit's and still names the 0.16 command prefix or the 0.16 folder) is replaced
# only when its content is a known kit 0.16 version of that script (never a project-edited copy), it is a regular file
# inside the project (no symlink, scripts/ not outside the root), and the project's git tracks it with no uncommitted
# change. Everything else is LEFT with its reason (exit 3).
# The known 0.16 versions are the git blobs at the v0.16.* tags, embedded in kit-refresh.sh. Test copies here are
# synthetic, so their hashes are passed through the test seam KIT_REFRESH_TEST_KNOWN ("<file> <blob>" lines); case 6
# also refreshes the REAL tagged copies with no seam when the tags are present.
# Run: bash tests/kit-refresh.test.sh   (temp git repos; nothing outside the temp dir is touched)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; RF="$ROOT/scripts/kit-refresh.sh"
TMP0="$(mktemp -d)"; trap 'chmod -R u+w "$TMP0" 2>/dev/null; rm -rf "$TMP0"' EXIT
TMP="$TMP0/k r"; mkdir -p "$TMP/home"; export HOME="$TMP/home"   # a path with a space; a fake HOME (never the real one)
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want '$2', got '$3'"; }
has() { case "$3" in *"$2"*) ok;; *) bad "$1: want '$2' in: $3";; esac; }
OLDN=".orch""estration-kit"; OLDP="/orch""estration-kit:"   # the 0.16 folder and command prefix, split for docs-pins
[ -f "$RF" ] || { echo "FAIL scripts/kit-refresh.sh is missing"; echo "kit-refresh: $pass passed, 1 failed"; exit 1; }
WRITERS="gate-throttle.sh quiet-mode.sh seat-merge.sh"
LAUNCH="start-team.sh recycle-sibling.sh sibling-shell.sh lib-launch.sh lib-model-tag.sh"
# a 0.16 copy: the kit's own file with the 0.16 folder (writers) or the 0.16 prefix (launch scripts) put back
old016() {  # <file> -> stdout
  case " $WRITERS " in
    *" $1 "*) printf '# 0.16 copy\nRT="${KIT_RUNTIME_DIR:-$HOME/%s/runtime}"\n' "$OLDN"; cat "$ROOT/scripts/$1" ;;
    *) printf '# 0.16 copy\nprompt="%sorient"\n' "$OLDP"; cat "$ROOT/scripts/$1" ;;
  esac
}
proj() {  # <name>: a git project with every listed script as a committed 0.16 copy, no lib-kit-home.sh
  P="$TMP/$1"; mkdir -p "$P/scripts"; git -C "$P" init -q; git -C "$P" config user.email t@t; git -C "$P" config user.name t
  local f; for f in $WRITERS $LAUNCH; do old016 "$f" > "$P/scripts/$f"; chmod +x "$P/scripts/$f"; done
  cp "$ROOT/scripts/lib-builder-worktree.sh" "$P/scripts/"   # a lib that is already current stays as it is
  git -C "$P" add -A && git -C "$P" commit -qm adopt
  KNOWN="$TMP/$1.known"; : > "$KNOWN"
  for f in $WRITERS $LAUNCH; do echo "$f $(git -C "$P" hash-object "scripts/$f")" >> "$KNOWN"; done
}
rf() { OUT="$(cd "$P" && KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" "$@" 2>&1)"; RC=$?; }
rf_noseam() { OUT="$(cd "$P" && env -u KIT_REFRESH_TEST -u KIT_REFRESH_TEST_KNOWN bash "$RF" "$@" 2>&1)"; RC=$?; }
nottmp() {  # <label> <dir>: no temp file of the safe write is left behind
  eq "$1: no temp file left" "" "$(find "$2" -name '.kit-refresh.*' 2>/dev/null)"; }
ROOTUSER=0; [ "$(id -u)" = 0 ] && ROOTUSER=1   # root passes every -w test and writes into read-only folders

# 1. Dry run (no --apply): lists each stale copy, changes nothing.
proj dry; before="$(cd "$P" && git status --porcelain; md5sum scripts/*)"
rf
eq "1 dry run exit" 0 "$RC"
for f in $WRITERS $LAUNCH; do has "1 lists $f" "STALE  scripts/$f" "$OUT"; done
eq "1 nothing changed" "$before" "$(cd "$P" && git status --porcelain; md5sum scripts/*)"

# 2. --apply on a clean tracked project: every stale copy equals the kit's, runnables keep +x, the missing lib-kit-home.sh
#    (new in 0.17.0, sourced by the three writers) is created, git diff shows exactly the refreshed files.
proj apply; rf --apply
eq "2 apply exit" 0 "$RC"
for f in $WRITERS $LAUNCH; do
  cmp -s "$P/scripts/$f" "$ROOT/scripts/$f" && ok || bad "2: scripts/$f was not replaced by the kit's copy"
  has "2 reports $f" "REFRESH scripts/$f" "$OUT"
done
for f in gate-throttle.sh quiet-mode.sh seat-merge.sh start-team.sh recycle-sibling.sh sibling-shell.sh; do
  [ -x "$P/scripts/$f" ] && ok || bad "2: scripts/$f lost its +x"
done
cmp -s "$P/scripts/lib-kit-home.sh" "$ROOT/scripts/lib-kit-home.sh" && ok || bad "2: lib-kit-home.sh was not created"
has "2 reports the created lib" "CREATE  scripts/lib-kit-home.sh" "$OUT"
# the review line names every created library and says how to remove it (untracked: delete, not git checkout)
has "2 review line names the created lib" "scripts/lib-kit-home.sh" "$(printf '%s\n' "$OUT" | grep -F 'new untracked')"
has "2 review line: remove by deleting" "delete" "$(printf '%s\n' "$OUT" | grep -F 'new untracked')"
for f in $WRITERS; do grep -qF "$OLDN" "$P/scripts/$f" && bad "2: scripts/$f still names the 0.16 folder" || ok; done
eq "2 the current lib is untouched" "" "$(cd "$P" && git status --porcelain scripts/lib-builder-worktree.sh)"
# the refreshed writer runs: quiet-mode on/off under a fake HOME lands in the new folder
HOME="$TMP/apply-home" bash -c 'unset KIT_RUNTIME_DIR; mkdir -p "$HOME"; bash "$1/scripts/quiet-mode.sh" on' _ "$P" >/dev/null 2>&1
[ -f "$TMP/apply-home/.orcastration-kit/runtime/quiet-mode" ] && ok || bad "2: the refreshed quiet-mode.sh did not write under the new folder"
nottmp "2" "$P"
rf --apply; eq "2 second apply exit" 0 "$RC"; has "2 second apply: nothing stale" "nothing to refresh" "$OUT"

# 3. Unsafe copies are left, with the reason: edited by the project, uncommitted changes, untracked, outside a git repo.
proj unsafe; echo "# a local edit" >> "$P/scripts/quiet-mode.sh"
git -C "$P" rm -q --cached scripts/seat-merge.sh
cp "$P/scripts/start-team.sh" "$TMP/st.keep"; echo "# edit" >> "$P/scripts/start-team.sh"; git -C "$P" commit -qam edit; cp "$TMP/st.keep" "$P/scripts/start-team.sh"
rf --apply
eq "3 apply exit 3 (something left)" 3 "$RC"
has "3 edited copy left" "LEFT   scripts/quiet-mode.sh (edited by the project" "$OUT"
has "3 edited: the manual step" "diff -u scripts/quiet-mode.sh" "$OUT"
has "3 known content but uncommitted change left" "LEFT   scripts/start-team.sh (uncommitted changes" "$OUT"
has "3 untracked copy left" "LEFT   scripts/seat-merge.sh (not tracked by git" "$OUT"
grep -q "a local edit" "$P/scripts/quiet-mode.sh" && ok || bad "3: the uncommitted edit was overwritten"
cmp -s "$P/scripts/seat-merge.sh" "$ROOT/scripts/seat-merge.sh" && bad "3: the untracked copy was overwritten" || ok
cmp -s "$P/scripts/gate-throttle.sh" "$ROOT/scripts/gate-throttle.sh" && ok || bad "3: the clean copy beside them was not refreshed"
P="$TMP/nogit"; mkdir -p "$P/scripts"; old016 gate-throttle.sh > "$P/scripts/gate-throttle.sh"
rf --apply; eq "3 no git exit 3" 3 "$RC"; has "3 no git: left" "LEFT   scripts/gate-throttle.sh (not tracked by git" "$OUT"

# 4. A copy that differs but carries no 0.16 name (a project edit on 0.17) is never touched, only reported.
proj edit17; cp "$ROOT/scripts/gate-throttle.sh" "$P/scripts/gate-throttle.sh"; echo "# project tweak" >> "$P/scripts/gate-throttle.sh"
git -C "$P" commit -qam tweak; rf --apply
has "4 reported as differing" "DIFFERS scripts/gate-throttle.sh" "$OUT"
grep -q "project tweak" "$P/scripts/gate-throttle.sh" && ok || bad "4: a 0.17 project edit was overwritten"

# 5. Links and paths outside the project are never written through (no link following at all).
proj links; OUTSIDE="$TMP/outside"; mkdir -p "$OUTSIDE"
mv "$P/scripts/gate-throttle.sh" "$OUTSIDE/gate-throttle.sh"; ln -s "$OUTSIDE/gate-throttle.sh" "$P/scripts/gate-throttle.sh"
cp "$P/scripts/quiet-mode.sh" "$P/qm-real.sh"; rm "$P/scripts/quiet-mode.sh"; ln -s ../qm-real.sh "$P/scripts/quiet-mode.sh"
git -C "$P" add -A && git -C "$P" commit -qm links
echo "gate-throttle.sh $(git hash-object "$OUTSIDE/gate-throttle.sh")" >> "$KNOWN"
before_out="$(md5sum "$OUTSIDE/gate-throttle.sh")"; before_in="$(md5sum "$P/qm-real.sh")"
rf --apply
eq "5 apply exit 3" 3 "$RC"
has "5 link to outside left" "LEFT   scripts/gate-throttle.sh (a symlink" "$OUT"
has "5 link inside left" "LEFT   scripts/quiet-mode.sh (a symlink" "$OUT"
eq "5 the outside file is untouched" "$before_out" "$(md5sum "$OUTSIDE/gate-throttle.sh")"
eq "5 the inside target is untouched" "$before_in" "$(md5sum "$P/qm-real.sh")"
[ -L "$P/scripts/gate-throttle.sh" ] && [ -L "$P/scripts/quiet-mode.sh" ] && ok || bad "5: a link was replaced"
# scripts/ itself is a link to a folder outside the project: nothing is written there
proj outdir; mv "$P/scripts" "$TMP/outdir-scripts"; ln -s "$TMP/outdir-scripts" "$P/scripts"
before="$(md5sum "$TMP"/outdir-scripts/*)"
rf --apply
eq "5 outside scripts/ exit 3" 3 "$RC"
has "5 outside scripts/ refused" "outside the project" "$OUT"
eq "5 outside scripts/ untouched" "$before" "$(md5sum "$TMP"/outdir-scripts/*)"

# 6. The embedded list of known 0.16 versions equals the v0.16.* tags (skipped loudly without tags), and the real
#    tagged copies refresh with no test seam.
if [ -n "$(git -C "$ROOT" tag -l 'v0.16.*' 2>/dev/null)" ]; then
  gen="$(cd "$ROOT" && bash "$RF" --print-known 2>&1)"
  emb="$(sed -n '/^# BEGIN known-0.16/,/^# END known-0.16/p' "$RF" | sed '1d;$d' | sed 's/^# //')"
  [ -n "$gen" ] && [ "$gen" = "$emb" ] && ok || bad "6 the embedded known list differs from the tags; regenerate with: bash scripts/kit-refresh.sh --print-known"
  tag="$(git -C "$ROOT" tag -l 'v0.16.*' | sort -V | tail -n1)"
  P="$TMP/real"; mkdir -p "$P/scripts"; git -C "$P" init -q; git -C "$P" config user.email t@t; git -C "$P" config user.name t
  for f in $WRITERS $LAUNCH; do git -C "$ROOT" show "$tag:scripts/$f" > "$P/scripts/$f"; done
  git -C "$P" add -A && git -C "$P" commit -qm adopt
  rf_noseam --apply
  eq "6 real $tag copies: exit" 0 "$RC"
  for f in $WRITERS $LAUNCH; do cmp -s "$P/scripts/$f" "$ROOT/scripts/$f" && ok || bad "6: the real $tag copy of $f was not refreshed"; done
else
  echo "SKIP 6: no v0.16.* tags in this checkout (CI's shallow clone): the known-list check and the real-copy case did not run"
fi
# without the seam, a synthetic copy is not a known version: LEFT as edited
proj noseam; rf_noseam --apply
eq "6 unknown content exit 3" 3 "$RC"
has "6 unknown content left as edited" "LEFT   scripts/gate-throttle.sh (edited by the project" "$OUT"

# 7. The test seam needs its own switch: KIT_REFRESH_TEST_KNOWN alone is ignored (a normal run); with KIT_REFRESH_TEST=1
#    it is used and one stderr line says so.
proj seam; OUT="$(cd "$P" && env -u KIT_REFRESH_TEST KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "7 the variable alone is ignored: exit 3" 3 "$RC"
has "7 the variable alone: left as edited" "LEFT   scripts/gate-throttle.sh (edited by the project" "$OUT"
case "$OUT" in *"REFRESH scripts/"*) bad "7 the variable alone refreshed a copy";; *) ok;; esac
ERR="$(cd "$P" && KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" 2>&1 >/dev/null)"
eq "7 with the switch: one stderr line" 1 "$(printf '%s\n' "$ERR" | grep -c 'KIT_REFRESH_TEST_KNOWN')"
SO="$(cd "$P" && KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" 2>/dev/null)"
case "$SO" in *KIT_REFRESH_TEST_KNOWN*) bad "7 the seam line went to stdout";; *) ok;; esac
rf --apply; eq "7 with the switch: used (exit 0)" 0 "$RC"

# 8. A hard-linked copy is LEFT (a second name shares the file); the other name, outside the project, keeps its bytes.
proj hard; OH="$TMP/outside hard"; mkdir -p "$OH"; mv "$P/scripts/gate-throttle.sh" "$OH/gate-throttle.sh"
ln "$OH/gate-throttle.sh" "$P/scripts/gate-throttle.sh"; git -C "$P" add -A && git -C "$P" commit -qm hard
before="$(md5sum < "$OH/gate-throttle.sh")"; rf --apply
eq "8 hard link exit 3" 3 "$RC"
has "8 hard link left" "LEFT   scripts/gate-throttle.sh (hard-linked" "$OUT"
eq "8 the outside name keeps its bytes" "$before" "$(md5sum < "$OH/gate-throttle.sh")"
eq "8 the copy keeps its bytes" "$before" "$(md5sum < "$P/scripts/gate-throttle.sh")"
cmp -s "$P/scripts/quiet-mode.sh" "$ROOT/scripts/quiet-mode.sh" && ok || bad "8: the plain copy beside it was not refreshed"

# 9. The known-version hash is byte-exact (no git filters): a CRLF working copy under core.autocrlf=true hashes, with
#    filters, to the known LF blob, but its bytes are not a kit 0.16 version: LEFT. The file mode is not hashed.
proj crlf; git -C "$P" config core.autocrlf true
sed 's/$/\r/' "$P/scripts/gate-throttle.sh" > "$TMP/crlf.tmp" && cat "$TMP/crlf.tmp" > "$P/scripts/gate-throttle.sh"
git -C "$P" add -A 2>/dev/null; git -C "$P" commit -qm crlf 2>/dev/null
eq "9 precondition: the CRLF copy is clean in git" "" "$(git -C "$P" status --porcelain)"
chmod -x "$P/scripts/quiet-mode.sh"; git -C "$P" commit -qam mode
before="$(md5sum < "$P/scripts/gate-throttle.sh")"; rf --apply
eq "9 CRLF exit 3" 3 "$RC"
has "9 CRLF copy left as edited" "LEFT   scripts/gate-throttle.sh (edited by the project" "$OUT"
eq "9 CRLF copy keeps its bytes" "$before" "$(md5sum < "$P/scripts/gate-throttle.sh")"
has "9 a copy with another mode is still known" "REFRESH scripts/quiet-mode.sh" "$OUT"

# 10. scripts/ must be a real folder of the project (the folder the script runs from), even when a parent repo holds the
#     link target: exit 3, nothing changed, dry run and apply.
PAR="$TMP/parent repo"; mkdir -p "$PAR/shared scripts" "$PAR/proj"; git -C "$PAR" init -q; git -C "$PAR" config user.email t@t; git -C "$PAR" config user.name t
for f in $WRITERS $LAUNCH; do old016 "$f" > "$PAR/shared scripts/$f"; done
ln -s "../shared scripts" "$PAR/proj/scripts"; git -C "$PAR" add -A && git -C "$PAR" commit -qm adopt
P="$PAR/proj"; KNOWN="$TMP/parent.known"; : > "$KNOWN"; for f in $WRITERS $LAUNCH; do echo "$f $(git hash-object "$PAR/shared scripts/$f")" >> "$KNOWN"; done
before="$(cd "$PAR" && md5sum "shared scripts"/*; git status --porcelain)"
rf; eq "10 linked scripts/ dry run exit 3" 3 "$RC"
rf --apply; eq "10 linked scripts/ apply exit 3" 3 "$RC"
has "10 refused" "nothing was changed" "$OUT"
case "$OUT" in *"REFRESH scripts/"*|*"CREATE  scripts/"*) bad "10 a linked scripts/ was written";; *) ok;; esac
eq "10 nothing changed" "$before" "$(cd "$PAR" && md5sum "shared scripts"/*; git status --porcelain)"

# 11. Git's repo-discovery variables from the caller's shell are ignored: the project's own git decides.
#     a) GIT_DIR + GIT_WORK_TREE name a repo whose work tree is a parent: the project has no git of its own, so LEFT.
M2="$TMP/m2 parent"; GD="$TMP/m2 gitdir"; P="$M2/proj"; mkdir -p "$P/scripts"; old016 gate-throttle.sh > "$P/scripts/gate-throttle.sh"
GIT_DIR="$GD" GIT_WORK_TREE="$M2" git init -q; GIT_DIR="$GD" git config user.email t@t; GIT_DIR="$GD" git config user.name t
(cd "$M2" && GIT_DIR="$GD" GIT_WORK_TREE="$M2" git add -A && GIT_DIR="$GD" GIT_WORK_TREE="$M2" git commit -qm adopt)
KNOWN="$TMP/m2.known"; echo "gate-throttle.sh $(git hash-object "$P/scripts/gate-throttle.sh")" > "$KNOWN"
before="$(md5sum < "$P/scripts/gate-throttle.sh")"
OUT="$(cd "$P" && GIT_DIR="$GD" GIT_WORK_TREE="$M2" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "11a exit 3" 3 "$RC"
has "11a left: not tracked by the project's git" "LEFT   scripts/gate-throttle.sh (not tracked by git" "$OUT"
eq "11a unchanged" "$before" "$(md5sum < "$P/scripts/gate-throttle.sh")"
#     b) GIT_WORK_TREE alone set to a parent folder: the project's own repo still decides, so the copies refresh.
proj m2b; OUT="$(cd "$P" && GIT_WORK_TREE="$TMP" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "11b exit 0" 0 "$RC"; has "11b refreshed" "REFRESH scripts/gate-throttle.sh" "$OUT"

# 12. CREATE writes through no link: a missing library whose name is a dangling link to outside is not created there.
proj clink; OC="$TMP/create outside"; mkdir -p "$OC"; ln -s "$OC/lib-kit-home.sh" "$P/scripts/lib-kit-home.sh"
git -C "$P" add -A && git -C "$P" commit -qm clink; rf --apply
[ -e "$OC/lib-kit-home.sh" ] && bad "12: CREATE wrote through the link" || ok
eq "12 dangling link counts toward exit 3" 3 "$RC"
has "12 dangling link reported" "LEFT   scripts/lib-kit-home.sh (a dangling link at a library name" "$OUT"
[ -L "$P/scripts/lib-kit-home.sh" ] && ok || bad "12: the link was replaced"
has "12 the copies beside it refresh" "REFRESH scripts/gate-throttle.sh" "$OUT"
nottmp "12" "$P"

# 13. A failed write is LEFT (could not replace), counts toward exit 3, is never printed as REFRESH, and leaves no temp file.
if [ "$ROOTUSER" = 0 ]; then
  #   a) a read-only scripts/ folder
  proj rodir; before="$(md5sum "$P"/scripts/*)"; chmod a-w "$P/scripts"; rf --apply; chmod u+w "$P/scripts"
  eq "13a read-only folder exit 3" 3 "$RC"
  has "13a left" "LEFT   scripts/gate-throttle.sh (could not replace" "$OUT"
  case "$OUT" in *"REFRESH scripts/"*) bad "13a a failed write was printed as REFRESH";; *) ok;; esac
  eq "13a nothing changed" "$before" "$(md5sum "$P"/scripts/*)"; nottmp "13a" "$P"
  #   b) a read-only copy in a writable scripts/ (the [ -w ] test)
  proj rofile; chmod a-w "$P/scripts/gate-throttle.sh"; before="$(md5sum < "$P/scripts/gate-throttle.sh")"; rf --apply
  eq "13b read-only copy exit 3" 3 "$RC"
  has "13b left" "LEFT   scripts/gate-throttle.sh (read-only" "$OUT"
  eq "13b unchanged" "$before" "$(md5sum < "$P/scripts/gate-throttle.sh")"
else
  echo "SKIP 13a/13b: running as root (every file passes -w); the read-only cases did not run"
fi
#   c) mv fails (a shim on PATH)
SH="$TMP/shim mv"; mkdir -p "$SH"; printf '#!/bin/sh\nexit 1\n' > "$SH/mv"; chmod +x "$SH/mv"
proj mvfail; before="$(md5sum "$P"/scripts/*)"
OUT="$(cd "$P" && PATH="$SH:$PATH" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "13c failed mv exit 3" 3 "$RC"
has "13c left" "LEFT   scripts/seat-merge.sh (could not replace" "$OUT"
case "$OUT" in *"REFRESH scripts/"*|*"CREATE  scripts/"*) bad "13c a failed mv was printed as REFRESH or CREATE";; *) ok;; esac
eq "13c nothing changed" "$before" "$(md5sum "$P"/scripts/*)"; nottmp "13c" "$P"
#   d) a folder appears at the name between the copy and the move: mv must not move the new file INTO it
SC="$TMP/shim cp"; mkdir -p "$SC"; REALCP="$(command -v cp)"
printf '#!/bin/sh\n"%s" "$@" || exit 1\ncase "$1 $2" in */gate-throttle.sh*.kit-refresh.*) if [ -f gate-throttle.sh ]; then rm -f gate-throttle.sh; mkdir gate-throttle.sh; fi;; esac\n' "$REALCP" > "$SC/cp"; chmod +x "$SC/cp"
proj race; OUT="$(cd "$P" && PATH="$SC:$PATH" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "13d folder at the name exit 3" 3 "$RC"
has "13d left" "LEFT   scripts/gate-throttle.sh (could not replace" "$OUT"
case "$OUT" in *"REFRESH scripts/gate-throttle.sh"*) bad "13d printed REFRESH for the folder";; *) ok;; esac
eq "13d the folder stays empty" "" "$(ls -A "$P/scripts/gate-throttle.sh" 2>/dev/null)"
nottmp "13d" "$P"
#   g) CDPATH from the caller's shell is ignored: `cd scripts` must enter the project's scripts/, never the scripts/ of a
#      folder named in CDPATH (a false refusal, or with a weaker folder check, writes into that other folder)
CD="$TMP/cdpath other"; mkdir -p "$CD/scripts"; for f in $WRITERS $LAUNCH; do old016 "$f" > "$CD/scripts/$f"; done
before_cd="$(md5sum "$CD"/scripts/*)"; before_ls="$(ls -A "$CD/scripts")"
proj cdp; OUT="$(cd "$P" && CDPATH="$CD" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "13g CDPATH exit 0" 0 "$RC"
has "13g refreshed in the project" "REFRESH scripts/gate-throttle.sh" "$OUT"
cmp -s "$P/scripts/gate-throttle.sh" "$ROOT/scripts/gate-throttle.sh" && ok || bad "13g: the project's copy was not refreshed"
eq "13g the CDPATH folder is untouched" "$before_cd" "$(md5sum "$CD"/scripts/*)"
eq "13g no file created in the CDPATH folder" "$before_ls" "$(ls -A "$CD/scripts")"
#   e) a link raced in at a CREATE name between the check and the write is replaced by the move, never written through
SL="$TMP/shim ln"; OL="$TMP/race outside"; mkdir -p "$SL" "$OL"
printf '#!/bin/sh\ncase "$1" in */lib-kit-home.sh) ln -s "%s/lib-kit-home.sh" lib-kit-home.sh 2>/dev/null;; esac\nexec "%s" "$@"\n' "$OL" "$REALCP" > "$SL/cp"; chmod +x "$SL/cp"
proj crace; OUT="$(cd "$P" && PATH="$SL:$PATH" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "13e CREATE race exit" 0 "$RC"
[ -e "$OL/lib-kit-home.sh" ] && bad "13e: CREATE wrote through a raced-in link" || ok
[ -f "$P/scripts/lib-kit-home.sh" ] && [ ! -L "$P/scripts/lib-kit-home.sh" ] && ok || bad "13e: the raced-in link was not replaced by the file"
nottmp "13e" "$P"
#   f) a TERM while the temp file exists: the run stops and the trap removes the temp file
ST="$TMP/shim term"; mkdir -p "$ST"
printf '#!/bin/sh\n"%s" "$@" || exit 1\ncase "$1 $2" in */gate-throttle.sh*.kit-refresh.*) kill -TERM "$PPID";; esac\n' "$REALCP" > "$ST/cp"; chmod +x "$ST/cp"
proj term; OUT="$(cd "$P" && PATH="$ST:$PATH" KIT_REFRESH_TEST=1 KIT_REFRESH_TEST_KNOWN="$KNOWN" bash "$RF" --apply 2>&1)"; RC=$?
eq "13f TERM exit" 143 "$RC"
case "$OUT" in *"REFRESH scripts/gate-throttle.sh"*) bad "13f a stopped write was printed as REFRESH";; *) ok;; esac
nottmp "13f" "$P"

echo "kit-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
