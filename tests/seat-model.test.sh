#!/usr/bin/env bash
# Tests for scripts/seat-model.sh: your own seat model and effort, saved once per machine.
# Run: bash tests/seat-model.test.sh   Nothing is launched and nothing outside a temp folder is written.
# (That the launch scripts USE the choice is tested in tests/lean-launch.test.sh, section 7c.)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SM="$ROOT/scripts/seat-model.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export KIT_STATE_DIR="$TMP/state"; F="$KIT_STATE_DIR/seat-model"
pass=0; fail=0
has()   { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
is()    { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: want '$2', got '$3'"; fi; }
sm() { bash "$SM" "$@" 2>&1; }

# 1. Nothing saved yet: each project's own setting decides, and no file is made by looking.
has "no choice yet: --show says so" "seat model: each project's own setting · effort: the model's default" "$(sm --show)"
is "no choice yet: --label" "project's own" "$(sm --label)"
[ ! -e "$F" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL --show made the file"; }

# 2. --set saves a model and an effort; --set with a model alone keeps the effort.
has "--set fable high" "seat model: fable · effort: high" "$(sm --set fable high)"
has "the file has the model line" "model: fable" "$(cat "$F")"
has "the file has the effort line" "effort: high" "$(cat "$F")"
is "--label is the short form" "fable · high" "$(sm --label)"
sm --set 'opus[1m]' >/dev/null
is "a model alone keeps the effort" "opus[1m] · high" "$(sm --label)"
sm --set claude-some-model-9 max >/dev/null
is "a full model id is accepted" "claude-some-model-9 · max" "$(sm --label)"

# 3. `project` and `default` clear a choice: the line leaves the file.
sm --set project >/dev/null
is "project: no model, effort kept" "project's own · max" "$(sm --label)"
hasnt "project: no model line in the file" "model:" "$(grep -v '^#' "$F")"
sm --set fable default >/dev/null
is "default: no effort" "fable" "$(sm --label)"
hasnt "default: no effort line in the file" "effort:" "$(grep -v '^#' "$F")"

# 4. A value that is no model or effort is refused, exit 64, and the file is left as it was.
before="$(cat "$F")"
for bad in 'x;y' '--dangerously-skip-permissions' '.' 'Opus'; do
  out="$(sm --set "$bad"; echo "rc=$?")"; has "model '$bad' refused rc 64" "rc=64" "$out"; has "model '$bad' says why" "not a model" "$out"
done
out="$(sm --set fable ultra; echo "rc=$?")"; has "effort 'ultra' refused rc 64" "rc=64" "$out"; has "effort 'ultra' says why" "not an effort" "$out"
is "a refused value changes nothing" "$before" "$(cat "$F")"
out="$(sm --bogus; echo "rc=$?")"; has "an unknown option is usage, rc 64" "rc=64" "$out"

# 5. The menu: a number picks, Enter keeps, o takes a typed id, p clears the model, a wrong key keeps.
sm --set fable high >/dev/null
out="$(printf '2\n4\n' | sm)"
has "menu: lists fable" "[1] fable" "$out"
has "menu: shows the current choice" "(now: fable)" "$out"
is "menu: 2 then 4 = opus[1m] at xhigh" "opus[1m] · xhigh" "$(sm --label)"
printf '\n\n' | sm >/dev/null;            is "menu: Enter, Enter keeps both" "opus[1m] · xhigh" "$(sm --label)"
printf 'o\nclaude-some-model-9\n\n' | sm >/dev/null; is "menu: o takes a typed id" "claude-some-model-9 · xhigh" "$(sm --label)"
out="$(printf 'o\nnot;a;model\n\n' | sm)"; has "menu: a bad typed id is kept out" "Not a model id" "$out"
is "menu: a bad typed id changes nothing" "claude-some-model-9 · xhigh" "$(sm --label)"
printf 'p\nd\n' | sm >/dev/null;          is "menu: p and d clear both" "project's own" "$(sm --label)"
printf '1\n9\n' | sm >/dev/null;          is "menu: a wrong effort key keeps the effort" "fable" "$(sm --label)"
printf '4\n' | sm >/dev/null;             is "menu: input ending after the model still saves it" "haiku" "$(sm --label)"

# 6. A settings file kept elsewhere and linked here stays a link, and the real file gets the change.
mkdir -p "$TMP/elsewhere"; rm -f "$F"; : > "$TMP/elsewhere/seat-model"; ln -s "$TMP/elsewhere/seat-model" "$F"
sm --set 'sonnet[1m]' medium >/dev/null
[ -L "$F" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the linked file was replaced by a plain file"; }
has "the real file behind the link got the choice" "model: sonnet[1m]" "$(cat "$TMP/elsewhere/seat-model")"

echo "seat-model: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
