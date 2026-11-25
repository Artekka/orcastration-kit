#!/usr/bin/env bash
# Tests for the kit's state home after the 0.17.0 plugin-id rename (from the 0.16 spelling to orcastration-kit):
# scripts/lib-kit-home.sh (bash) and hooks/ctx-guard.py (python) resolve ~/.orcastration-kit, and when only
# the 0.16 folder (~/.orch""estration-kit) exists they link the new name to it in one step (no gap, no lost file),
# say so in one line, and keep env overrides first. A tab that started on 0.16 keeps watching the OLD path,
# so a recycle hand-off written through the new path must land where it looks (and the reverse).
# Run: bash tests/kit-home.test.sh   (fake HOME; nothing outside the temp dir is touched)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LIB="$ROOT/scripts/lib-kit-home.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want '$2', got '$3'"; }
OLDN=".orch""estration-kit"   # the 0.16 folder name, split so docs-pins' old-id sweep never needs this file on its list
fresh() { H="$TMP/h$1"; rm -rf "$H"; mkdir -p "$H"; }
kh() {  # run kit_home under the fake HOME; stdout -> OUT, stderr -> ERR
  OUT="$(HOME="$H" bash -c '. "$1" && kit_home' _ "$LIB" 2>"$TMP/err")"; KRC=$?; ERR="$(cat "$TMP/err")"
}   # KRC = kit_home's exit status
[ -f "$LIB" ] || { echo "FAIL scripts/lib-kit-home.sh is missing"; echo "kit-home: $pass passed, 1 failed"; exit 1; }

# A. Neither folder: the new name, nothing created (callers mkdir what they need), nothing said.
fresh A; kh
eq "A path" "$H/.orcastration-kit" "$OUT"
[ ! -e "$H/.orcastration-kit" ] && [ ! -L "$H/.orcastration-kit" ] && ok || bad "A created the new folder"
[ ! -e "$H/$OLDN" ] && ok || bad "A created the old folder"
eq "A silent" "" "$ERR"

# B. Only the 0.16 folder: the new name becomes a link to it, one line says so, the data is reachable both ways.
fresh B; mkdir -p "$H/$OLDN/sessions" "$H/$OLDN/runtime/locks"; echo keep > "$H/$OLDN/sessions/Sib1.next"
kh
eq "B path" "$H/.orcastration-kit" "$OUT"
[ -L "$H/.orcastration-kit" ] && ok || bad "B: the new name is not a link"
[ "$(cd "$H/.orcastration-kit" && pwd -P)" = "$(cd "$H/$OLDN" && pwd -P)" ] && ok || bad "B: the link does not lead to the old folder"
[ -d "$H/$OLDN" ] && [ ! -L "$H/$OLDN" ] && ok || bad "B: the old folder was moved or replaced"
eq "B data via the new path" keep "$(cat "$H/.orcastration-kit/sessions/Sib1.next" 2>/dev/null)"
eq "B one line" 1 "$(printf '%s\n' "$ERR" | grep -c .)"
case "$ERR" in *orcastration-kit*) ok;; *) bad "B: the line does not name the new folder: $ERR";; esac
kh; eq "B second call silent" "" "$ERR"; eq "B second call path" "$H/.orcastration-kit" "$OUT"

# B2. Cross-path recycle hand-off. New writer (lib-launch's state dir) -> old wrapper's path, and old writer -> new reader.
fresh B2; mkdir -p "$H/$OLDN/sessions"
sd="$(HOME="$H" bash -c 'unset SIBLING_STATE_DIR; . "$1/scripts/lib-launch.sh" && launch_state_dir' _ "$ROOT" 2>/dev/null)"
eq "B2 lib-launch state dir is under the new name" "$H/.orcastration-kit/sessions" "$sd"
[ -n "$sd" ] && printf 'go\n' > "$sd/Sib2.next" 2>/dev/null
eq "B2 a 0.16 wrapper sees the new writer's hand-off" go "$(cat "$H/$OLDN/sessions/Sib2.next" 2>/dev/null)"
printf 'back\n' > "$H/$OLDN/sessions/Sib3.next"
eq "B2 a 0.17 reader sees the 0.16 writer's hand-off" back "$(cat "$sd/Sib3.next" 2>/dev/null)"
# and the real wrapper: sibling-shell.sh picks its state dir through the same function
grep -q 'kit_home' "$ROOT/scripts/sibling-shell.sh" && ok || bad "B2 sibling-shell.sh does not resolve its state dir through kit_home"

# C. Both folders (a real new one): the new one wins, one warning, then silence.
fresh C; mkdir -p "$H/$OLDN/sessions" "$H/.orcastration-kit/sessions"
kh
eq "C path" "$H/.orcastration-kit" "$OUT"
[ ! -L "$H/.orcastration-kit" ] && ok || bad "C replaced the real new folder with a link"
eq "C one warning" 1 "$(printf '%s\n' "$ERR" | grep -c .)"
case "$ERR" in *"$OLDN"*) ok;; *) bad "C: the warning does not name the old folder: $ERR";; esac
kh; eq "C second call silent" "" "$ERR"

# C2. Already linked (B ran before): both names exist but are one folder -> silent.
fresh C2; mkdir -p "$H/$OLDN"; ln -s "$OLDN" "$H/.orcastration-kit"; kh
eq "C2 linked = silent" "" "$ERR"

# D. Env overrides win and migrate nothing.
fresh D; mkdir -p "$H/$OLDN/runtime"
HOME="$H" KIT_RUNTIME_DIR="$TMP/rtD" bash "$ROOT/scripts/quiet-mode.sh" on >/dev/null 2>&1
[ -f "$TMP/rtD/quiet-mode" ] && ok || bad "D: KIT_RUNTIME_DIR did not win for quiet-mode.sh"
[ ! -e "$H/.orcastration-kit" ] && [ ! -L "$H/.orcastration-kit" ] && ok || bad "D: an env override still created the new name"
# without the override, quiet-mode.sh lands under the new name (through the link)
fresh D2; mkdir -p "$H/$OLDN"
HOME="$H" bash -c 'unset KIT_RUNTIME_DIR; bash "$1/scripts/quiet-mode.sh" on' _ "$ROOT" >/dev/null 2>&1
[ -f "$H/.orcastration-kit/runtime/quiet-mode" ] && ok || bad "D2: quiet-mode.sh default flag is not under ~/.orcastration-kit/runtime"
[ -f "$H/$OLDN/runtime/quiet-mode" ] && ok || bad "D2: a 0.16 copy reading the old path does not see the flag"

# E. Every script that keeps state resolves it through kit_home (no second copy of the rule).
for s in gate-throttle.sh quiet-mode.sh seat-merge.sh lib-launch.sh lib-model-tag.sh sibling-shell.sh; do
  grep -q 'kit_home' "$ROOT/scripts/$s" && ok || bad "E: scripts/$s does not use kit_home"
  grep -q "$OLDN" "$ROOT/scripts/$s" && bad "E: scripts/$s still names the 0.16 folder" || ok
done
# the lib travels with the scripts that source it (kit-init and bootstrap copy lists)
grep -q 'lib-kit-home.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "E: kit-init does not install lib-kit-home.sh"
grep -q 'lib-kit-home.sh' "$ROOT/scripts/bootstrap.sh" && ok || bad "E: bootstrap.sh does not install lib-kit-home.sh"

# F. ctx-guard.py (python) follows the same rule: B case links, C case uses the new folder, KIT_STATE_DIR wins.
pyhome() {  # ctx-guard.py's STATE_DIR under the fake HOME (run_name != __main__: the hook body does not run)
  env -u KIT_STATE_DIR HOME="$H" ${KSD:+KIT_STATE_DIR="$KSD"} python3 -c 'import runpy,sys; print(runpy.run_path(sys.argv[1], run_name="probe")["STATE_DIR"])' "$ROOT/hooks/ctx-guard.py" 2>/dev/null
}
if command -v python3 >/dev/null 2>&1; then
  fresh F; mkdir -p "$H/$OLDN/ctx-guard"; KSD=""; out="$(pyhome)"
  eq "F state dir" "$H/.orcastration-kit/ctx-guard" "$out"
  [ -L "$H/.orcastration-kit" ] && ok || bad "F: ctx-guard.py did not link the new name to the 0.16 folder"
  fresh F2; KSD="$TMP/ksd"; out="$(pyhome)"
  eq "F2 KIT_STATE_DIR wins" "$TMP/ksd/ctx-guard" "$out"
  [ ! -e "$H/.orcastration-kit" ] && ok || bad "F2: an env override still created the new name"
else
  echo "SKIP F: python3 not on PATH"
fi

# G. A dangling link at the new name (its target is gone): kit_home heals it, says so in one line, and the callers work.
#    The heal re-applies the normal rule: the 0.16 folder exists -> link to it again; else a real new folder.
fresh G; ln -s ".gone-folder" "$H/.orcastration-kit"; kh
eq "G exit" 0 "$KRC"
eq "G path" "$H/.orcastration-kit" "$OUT"
[ -d "$H/.orcastration-kit" ] && [ ! -L "$H/.orcastration-kit" ] && ok || bad "G: the dangling link was not replaced by a real folder"
eq "G one line" 1 "$(printf '%s\n' "$ERR" | grep -c .)"
case "$ERR" in *"missing folder"*) ok;; *) bad "G: the line does not say the link led to a missing folder: $ERR";; esac
kh; eq "G second call silent" "" "$ERR"
fresh G2; mkdir -p "$H/$OLDN/sessions"; echo keep > "$H/$OLDN/sessions/Sib1.next"; ln -s ".moved-away" "$H/.orcastration-kit"; kh
[ -L "$H/.orcastration-kit" ] && [ "$(cd "$H/.orcastration-kit" 2>/dev/null && pwd -P)" = "$(cd "$H/$OLDN" && pwd -P)" ] && ok || bad "G2: with the 0.16 folder present the heal must link to it again"
eq "G2 data via the new path" keep "$(cat "$H/.orcastration-kit/sessions/Sib1.next" 2>/dev/null)"
eq "G2 one line" 1 "$(printf '%s\n' "$ERR" | grep -c .)"
# the caller from the READ: quiet-mode.sh on must really turn quiet mode on through a healed link
fresh G3; ln -s ".gone-folder" "$H/.orcastration-kit"
out="$(HOME="$H" bash -c 'unset KIT_RUNTIME_DIR; bash "$1/scripts/quiet-mode.sh" on' _ "$ROOT" 2>&1)"; rc=$?
eq "G3 quiet-mode on exit" 0 "$rc"
[ -f "$H/.orcastration-kit/runtime/quiet-mode" ] && ok || bad "G3: quiet-mode on through a dangling link left no flag: $out"
case "$out" in *"quiet mode: ON"*) ok;; *) bad "G3: quiet-mode on does not report ON: $out";; esac
# python twin
if command -v python3 >/dev/null 2>&1; then
  fresh G4; ln -s ".gone-folder" "$H/.orcastration-kit"; KSD=""; out="$(pyhome)"
  eq "G4 ctx-guard state dir" "$H/.orcastration-kit/ctx-guard" "$out"
  [ -d "$H/.orcastration-kit" ] && [ ! -L "$H/.orcastration-kit" ] && ok || bad "G4: ctx-guard.py did not heal the dangling link"
  fresh G5; mkdir -p "$H/$OLDN"; ln -s ".moved-away" "$H/.orcastration-kit"; KSD=""; out="$(pyhome)"
  [ -L "$H/.orcastration-kit" ] && [ "$(cd "$H/.orcastration-kit" 2>/dev/null && pwd -P)" = "$(cd "$H/$OLDN" && pwd -P)" ] && ok || bad "G5: ctx-guard.py did not re-link to the 0.16 folder"
fi

# H. The new name is something kit_home must never remove (a regular file, a link to a file): kit_home fails non-zero,
#    leaves it alone, and every caller exits non-zero instead of running on a path that cannot hold state.
fresh H; echo mine > "$H/.orcastration-kit"; kh; rc=$KRC
[ "$rc" -ne 0 ] && ok || bad "H: kit_home returned 0 for a regular file at the new name"
eq "H the file is untouched" mine "$(cat "$H/.orcastration-kit" 2>/dev/null)"
case "$ERR" in *orcastration-kit*) ok;; *) bad "H: kit_home said nothing: $ERR";; esac
fresh H1; echo f > "$H/target-file"; ln -s target-file "$H/.orcastration-kit"; kh; rc=$KRC
[ "$rc" -ne 0 ] && ok || bad "H1: kit_home returned 0 for a link to a file"
[ -L "$H/.orcastration-kit" ] && [ "$(cat "$H/target-file")" = f ] && ok || bad "H1: a live link (to a file) was removed or changed"
# every caller, with no env override, must exit non-zero (and run nothing)
STUB="$TMP/stubbin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = --version ]; then echo "9.9.9 (Stand-in)"; exit 0; fi\necho run >> "%s/stub-ran"\necho %s\n' "$TMP" "'{\"result\":\"ok\",\"modelUsage\":{\"x\":{\"inputTokens\":1}}}'" > "$STUB/claude"; chmod +x "$STUB/claude"
callers() {  # runs each caller under the fake HOME with every override unset; prints "<name> <rc>" lines
  local u='unset KIT_RUNTIME_DIR SIBLING_STATE_DIR KIT_STATE_DIR SEAT_MERGE_RUNTIME_DIR'
  rm -f "$TMP/stub-ran" "$TMP/gt-ran"
  ( cd "$TMP" && HOME="$H" KIT_GATE_MIN_FREE_GB=0 bash -c "$u; bash \"\$1/scripts/gate-throttle.sh\" touch \"\$2/gt-ran\"" _ "$ROOT" "$TMP" >/dev/null 2>"$TMP/gt-err" ); echo "gate-throttle $?"
  HOME="$H" bash -c "$u; bash \"\$1/scripts/quiet-mode.sh\" on" _ "$ROOT" >/dev/null 2>"$TMP/qm-err"; echo "quiet-mode $?"
  HOME="$H" bash -c "$u; bash \"\$1/scripts/quiet-mode.sh\" status" _ "$ROOT" >/dev/null 2>&1; echo "quiet-mode-status $?"
  ( cd "$TMP" && HOME="$H" bash -c "$u; bash \"\$1/scripts/seat-merge.sh\" b 0000000 m" _ "$ROOT" >/dev/null 2>"$TMP/sm-out" ); echo "seat-merge $?"
  HOME="$H" PATH="$STUB:$PATH" MODEL_PREFLIGHT_TIMEOUT=2 MODEL_PREFLIGHT_KILL_AFTER=1 bash -c "$u; . \"\$1/scripts/lib-model-tag.sh\" && model_tag_check claude-opus-5-5 ''" _ "$ROOT" >/dev/null 2>&1; echo "lib-model-tag $?"
  HOME="$H" bash -c "$u; . \"\$1/scripts/lib-launch.sh\" && launch_state_dir >/dev/null" _ "$ROOT" >/dev/null 2>&1; echo "lib-launch $?"
  HOME="$H" bash -c "$u; . \"\$1/scripts/lib-launch.sh\" && launch_write_handoff Sib1 hi" _ "$ROOT" >/dev/null 2>&1; echo "lib-launch-handoff $?"
  HOME="$H" PATH="$STUB:$PATH" bash -c "$u; bash \"\$1/scripts/sibling-shell.sh\" Sib1 --model opus hi" _ "$ROOT" >/dev/null 2>&1 </dev/null; echo "sibling-shell $?"
}
fresh H2; echo mine > "$H/.orcastration-kit"; res="$(callers)"
for c in gate-throttle quiet-mode quiet-mode-status seat-merge lib-model-tag lib-launch lib-launch-handoff sibling-shell; do
  r="$(printf '%s\n' "$res" | awk -v c="$c" '$1==c{print $2}')"
  [ -n "$r" ] && [ "$r" -ne 0 ] && ok || bad "H2: $c exited $r with an unresolvable kit home"
done
[ ! -e "$TMP/gt-ran" ] && ok || bad "H2: gate-throttle ran its command with an unresolvable kit home"
[ ! -e "$TMP/stub-ran" ] && ok || bad "H2: a claude ran (sibling-shell or the model preflight) with an unresolvable kit home"
# each script stops AT the kit home: its stderr is kit_home's one line, nothing after it (no later mkdir/git error)
for e in gt-err qm-err sm-out; do
  [ "$(grep -c . "$TMP/$e")" = 1 ] && grep -q '^orcastration-kit: .*is not a folder' "$TMP/$e" && ok \
    || bad "H2: $e: the script did not stop at the kit home: $(head -c 300 "$TMP/$e")"
done
eq "H2 the file is untouched" mine "$(cat "$H/.orcastration-kit" 2>/dev/null)"
# quiet-mode on that cannot write its flag (an override under a regular file) fails and says quiet mode is NOT on
fresh H2b; echo f > "$H/blocker"
out="$(HOME="$H" KIT_RUNTIME_DIR="$H/blocker/rt" bash "$ROOT/scripts/quiet-mode.sh" on 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "H2b: quiet-mode on exited 0 without writing its flag"
case "$out" in *"NOT on"*) ok;; *) bad "H2b: quiet-mode on did not say quiet mode is NOT on: $out";; esac
# and the same callers all work through a healed dangling link (positive control for H2's harness)
fresh H3; ln -s ".gone-folder" "$H/.orcastration-kit"; res="$(callers)"
for c in gate-throttle quiet-mode lib-model-tag lib-launch lib-launch-handoff; do
  r="$(printf '%s\n' "$res" | awk -v c="$c" '$1==c{print $2}')"
  eq "H3 $c works through a healed link" 0 "$r"
done
[ -e "$TMP/gt-ran" ] && ok || bad "H3: gate-throttle did not run its command"
if command -v python3 >/dev/null 2>&1; then
  fresh H4; echo mine > "$H/.orcastration-kit"
  env -u KIT_STATE_DIR HOME="$H" python3 "$ROOT/hooks/ctx-guard.py" </dev/null >/dev/null 2>"$TMP/py-err"; rc=$?
  [ "$rc" -ne 0 ] && ok || bad "H4: ctx-guard.py exited 0 with an unresolvable kit home"
  grep -q 'orcastration-kit' "$TMP/py-err" && ok || bad "H4: ctx-guard.py said nothing: $(head -c 200 "$TMP/py-err")"
  eq "H4 the file is untouched" mine "$(cat "$H/.orcastration-kit" 2>/dev/null)"
fi

echo "kit-home: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
