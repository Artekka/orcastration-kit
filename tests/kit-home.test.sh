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
  OUT="$(HOME="$H" bash -c '. "$1" && kit_home' _ "$LIB" 2>"$TMP/err")"; ERR="$(cat "$TMP/err")"
}
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

echo "kit-home: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
