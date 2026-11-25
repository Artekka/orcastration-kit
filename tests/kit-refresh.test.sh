#!/usr/bin/env bash
# Tests for scripts/kit-refresh.sh: kit-init's refresh of a project's script copies made on 0.16 (before the 0.17.0 id
# rename). A STALE copy (differs from the kit's and still names the 0.16 command prefix or the 0.16 folder) is replaced
# only when the project's git tracks it with no uncommitted change, so `git diff` shows the refresh and
# `git checkout -- <file>` undoes it. Untracked or edited-but-uncommitted copies are left, each with its reason.
# Run: bash tests/kit-refresh.test.sh   (temp git repos; nothing outside the temp dir is touched)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; RF="$ROOT/scripts/kit-refresh.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
}
rf() { OUT="$(cd "$P" && bash "$RF" "$@" 2>&1)"; RC=$?; }

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
for f in $WRITERS; do grep -qF "$OLDN" "$P/scripts/$f" && bad "2: scripts/$f still names the 0.16 folder" || ok; done
eq "2 the current lib is untouched" "" "$(cd "$P" && git status --porcelain scripts/lib-builder-worktree.sh)"
# the refreshed writer runs: quiet-mode on/off under a fake HOME lands in the new folder
HOME="$TMP/apply-home" bash -c 'unset KIT_RUNTIME_DIR; mkdir -p "$HOME"; bash "$1/scripts/quiet-mode.sh" on' _ "$P" >/dev/null 2>&1
[ -f "$TMP/apply-home/.orcastration-kit/runtime/quiet-mode" ] && ok || bad "2: the refreshed quiet-mode.sh did not write under the new folder"
rf --apply; eq "2 second apply exit" 0 "$RC"; has "2 second apply: nothing stale" "nothing to refresh" "$OUT"

# 3. Unsafe copies are left, with the reason: uncommitted edits, untracked, outside a git repo.
proj unsafe; echo "# a local edit" >> "$P/scripts/quiet-mode.sh"
git -C "$P" rm -q --cached scripts/seat-merge.sh
rf --apply
eq "3 apply exit 3 (something left)" 3 "$RC"
has "3 dirty copy left" "LEFT   scripts/quiet-mode.sh (uncommitted changes" "$OUT"
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

echo "kit-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
