#!/usr/bin/env bash
# Tests for scripts/sibling-shell.sh, the respawn-loop wrapper a team terminal runs (v0.7.0).
# Run: bash tests/sibling-shell.test.sh   Linux only (SKIP elsewhere). Nothing real is launched: every
# `claude` is a stub on PATH (see tests/inplace-harness.sh).
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
SUITE=sibling-shell
. "$(dirname "$0")/inplace-harness.sh"
# shellcheck source=../scripts/lib-launch.sh
. "$ROOT/scripts/lib-launch.sh"
W() { WRAPPER_ARGS=("$@"); run_wrapper ${WENV[@]+"${WENV[@]}"}; }

# 1. claude runs with --name FIRST and an explicit --model/--effort, then the prompt.
sandbox; WENV=(); n=$(nameFor W1)
W "$n" --model 'opus[1m]' --effort high "/orcastration-kit:orient --brief X"
eq "W1 exit 0" 0 "$RC"; eq "W1 one launch" 1 "$(nlaunch)"
eq "W1 argv" "--name|$n|--model|opus[1m]|--effort|high|/orcastration-kit:orient --brief X|" "$(argv_of 1)"
# default prompt when none is given
sandbox; n=$(nameFor W1d); W "$n" --model haiku
eq "W1 default prompt is the orient skill" "--name|$n|--model|haiku|/orcastration-kit:orient|" "$(argv_of 1)"

# 1b. --mode: the permission flags sit between --name and --model, exactly where lib-launch.sh puts them.
for m in normal accept-edits auto; do
  sandbox; n=$(nameFor W1m); W "$n" --mode "$m" --model 'sonnet[1m]' "go"
  want="--name|$n|$(launch_mode_flags "$m" | sed 's/ $//' | tr ' ' '|')|"
  [ "$m" = normal ] && want="--name|$n|"
  eq "W1b mode $m (same flags as launch_mode_flags)" "${want}--model|sonnet[1m]|go|" "$(argv_of 1)"
done

# 2. A hand-off relaunches in the SAME wrapper, and the file is consumed exactly once.
sandbox; n=$(nameFor W2)
stage_handoff 1 "$(handoff 'sonnet[1m]' high '' 'next prompt')"
W "$n" --model 'opus[1m]'
eq "W2 exit 0" 0 "$RC"; eq "W2 exactly two launches: initial + one hand-off" 2 "$(nlaunch)"
eq "W2 argv of the relaunch" "--name|$n|--model|sonnet[1m]|--effort|high|next prompt|" "$(argv_of 2)"
absent "W2 hand-off consumed" "$SB/state/$n.next"
eq "W2 no consumed/tmp leftovers" "" "$(ls -A "$SB/state")"

# 2b. An empty effort in the hand-off passes no --effort flag.
sandbox; n=$(nameFor W2b)
stage_handoff 1 "$(handoff haiku '' '' p)"
W "$n" --model 'opus[1m]' --effort max
eq "W2b no --effort after an empty effort" "--name|$n|--model|haiku|p|" "$(argv_of 2)"

# 2c. The hand-off's mode changes the next launch's permission flags; an absent mode keeps the current one.
sandbox; n=$(nameFor W2c)
stage_handoff 1 "$(handoff haiku '' '' p auto)"
W "$n" --mode accept-edits --model 'opus[1m]'
eq "W2c mode from the hand-off" "--name|$n|--permission-mode|auto|--model|haiku|p|" "$(argv_of 2)"
sandbox; n=$(nameFor W2d)
stage_handoff 1 "$(handoff haiku '' '' p)"
W "$n" --mode accept-edits --model 'opus[1m]'
eq "W2d absent mode keeps the current one" "--name|$n|--permission-mode|acceptEdits|--model|haiku|p|" "$(argv_of 2)"

# 3. No hand-off: the wrapper exits with the child's exit code (a plain /exit still closes the tab).
sandbox; n=$(nameFor W3); WENV=(STUB_EXIT=3); W "$n" --model 'opus[1m]'; WENV=()
eq "W3 exit code is the child's" 3 "$RC"; eq "W3 one launch, no relaunch" 1 "$(nlaunch)"

# 4. A prompt with spaces, quotes, ;, $, a backtick, a glob and a newline round-trips byte-exact, and
#    nothing in it is executed.
sandbox; n=$(nameFor W4)
stage_handoff 1 "$(handoff 'opus[1m]' '' '' "$TRICKY #2")"
W "$n" --model 'opus[1m]' "$TRICKY"
eq "W4 exit 0" 0 "$RC"
last_arg_is 1 "$TRICKY" && ok || bad "W4 initial prompt byte-exact"
last_arg_is 2 "$TRICKY #2" && ok || bad "W4 hand-off prompt byte-exact"
renomatch "W4 nothing executed" 'uid=' "$OUT$ERR"

# 5. The account comes from the hand-off per iteration: set, then cleared back to the default account.
sandbox; n=$(nameFor W5)
stage_handoff 1 "$(handoff 'opus[1m]' '' /x/acct2 a)"
stage_handoff 2 "$(handoff 'opus[1m]' '' '' b)"
WENV=(CLAUDE_CONFIG_DIR=/x/initial); W "$n" --model 'opus[1m]'; WENV=()
eq "W5 exit 0" 0 "$RC"; eq "W5 account per launch" "/x/initial,/x/acct2,unset" "$(cfgs)"

# 6. Crash-loop guard: two fast exits in a row stop the loop even though a hand-off keeps arriving.
sandbox; n=$(nameFor W6)
stage_handoff always "$(handoff no-such-model '' '' x)"
WENV=(SIBLING_MIN_RUN_SECS=5); W "$n" --model 'opus[1m]'; WENV=()
eq "W6 stopped after the 2nd fast exit, not at the stub's own cap" 2 "$(nlaunch)"
ne "W6 non-zero exit" 0 "$RC"
rematch "W6 says why" 'exited within 5s twice in a row' "$ERR"
absent "W6 the pending hand-off is not left behind" "$SB/state/$n.next"
# 6b. ... and it counts CONSECUTIVE fast exits: a slow run in between resets it.
sandbox; n=$(nameFor W6b)
stage_handoff always "$(handoff 'opus[1m]' '' '' x)"
WENV=(SIBLING_MIN_RUN_SECS=1 STUB_SLOW=2); W "$n" --model 'opus[1m]'; WENV=()
eq "W6b fast, slow (resets), fast, fast = four launches" 4 "$(nlaunch)"
rematch "W6b still stops with the message" 'twice in a row' "$ERR"
# 6c. The same guard on the no-EPOCHREALTIME clock (macOS /bin/bash 3.2 has none): whole-second date fallback.
sandbox; n=$(nameFor W6c)
stage_handoff always "$(handoff no-such-model '' '' x)"
WENV=(SIBLING_MIN_RUN_SECS=5 SIBLING_NO_EPOCHREALTIME=1); W "$n" --model 'opus[1m]'; WENV=()
eq "W6c fallback clock: stopped after the 2nd fast exit" 2 "$(nlaunch)"

# 7. A malformed or model-less hand-off is refused, not launched.
i=0
for case in "bad model|$(handoff 'Opus;rm -rf' '' '' x)" "bad effort|$(handoff 'opus[1m]' bogus '' x)" \
            "no model|effort=high"$'\n'"prompt_b64=eA==" "unknown key|$(handoff 'opus[1m]' '' '' x)"$'\nmodle=haiku' \
            "bad mode|$(handoff 'opus[1m]' '' '' x bogus)"; do
  label="${case%%|*}"; text="${case#*|}"; i=$((i+1))
  sandbox; n=$(nameFor W7); stage_handoff 1 "$text"$'\n'
  W "$n" --model 'opus[1m]'
  ne "W7 $label: non-zero" 0 "$RC"; eq "W7 $label: nothing launched from it" 1 "$(nlaunch)"
  rematch "W7 $label: says refused" 'refus' "$ERR"
done

# 8. Bad arguments exit 64 before anything launches (the model is always explicit).
sandbox
for args in "" "$(nameFor W8)" "$(nameFor W8) --model Opus" "$(nameFor W8) --model opus[1m] --effort bogus" \
            "$(nameFor W8) --model opus[1m] --modle x" "$(nameFor W8) --model opus[1m] a b" \
            "$(nameFor W8) --model opus[1m] --mode bogus" "$(nameFor W8) --model" "$(nameFor W8) --mode"; do
  # shellcheck disable=SC2086  # the case strings are space-separated words on purpose
  W $args; eq "W8 [$args] exits 64" 64 "$RC"
done
eq "W8 nothing launched" 0 "$(nlaunch)"

# 9. The wrapper survives its own script file being rewritten in place mid-run (the loop is parsed up
#    front): the stub truncates and rewrites a COPY on launch 1, then asks for a relaunch.
sandbox; n=$(nameFor W9); cp "$WRAPPER" "$SB/sibling-shell-copy.sh"; cp "$ROOT/scripts/lib-model-tag.sh" "$SB/lib-model-tag.sh"
stage_handoff 1 "$(handoff 'opus[1m]' '' '' again)"
WRAPPER_UNDER_TEST="$SB/sibling-shell-copy.sh"; WENV=(STUB_REWRITE="$SB/sibling-shell-copy.sh"); W "$n" --model 'opus[1m]'; WENV=(); unset WRAPPER_UNDER_TEST
eq "W9 two launches" 2 "$(nlaunch)"; hasnt "W9 the rewritten text never ran" HIJACKED "$OUT$ERR"; eq "W9 exit 0" 0 "$RC"

# 10. The shared model guard at the wrapper: a family name plus a version needs the claude- prefix (refused offline, nothing
#     launched); a full id with the prefix launches.
sandbox; n=$(nameFor W10); W "$n" --model 'fable-5-2[1m]'
eq "W10 fable-5-2[1m] exits 64" 64 "$RC"; has "W10 names the claude- prefix" "needs the claude- prefix" "$ERR"; eq "W10 nothing launched" 0 "$(nlaunch)"
sandbox; n=$(nameFor W10b); W "$n" --model claude-opus-5-5
eq "W10b a claude- full id launches" 0 "$RC"; eq "W10b one launch" 1 "$(nlaunch)"

# 11. The same guard on a HAND-OFF: a model without the prefix is refused, only the first launch ran.
sandbox; n=$(nameFor W11); stage_handoff 1 "$(handoff 'opus-5-5' '' '' x)"$'\n'
W "$n" --model 'opus[1m]'
ne "W11 non-zero" 0 "$RC"; eq "W11 only the first launch" 1 "$(nlaunch)"; has "W11 says why" "model refused" "$ERR"

# 12. The CLI half on a hand-off: a full id the CLI does not know is refused before the launch (a real preflight, MODEL_PREFLIGHT back on,
#     a stand-in CLI that answers the unknown-model way); a known one launches; an alias never calls the CLI.
sandbox; n=$(nameFor W12); mkdir -p "$SB/pfbin"
cat > "$SB/pfbin/claude" <<'PF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "9.9.9 (Stand-in)"; exit 0; fi
if [ "${1:-}" = --name ]; then exec "$SB_REAL_CLAUDE" "$@"; fi
echo "$*" >> "$SB_PF_CALLS"
if [ "${PF_MODE:-unknown}" = unknown ]; then echo '{"result":"There is an issue with the selected model (x).","modelUsage":{}}'
else echo '{"result":"ok","modelUsage":{"x":{"inputTokens":1}}}'; fi
PF
chmod +x "$SB/pfbin/claude"
PFW=("PATH=$SB/pfbin:$SB/bin:$PATH" MODEL_PREFLIGHT=1 "SB_PF_CALLS=$SB/pf.calls" "SB_REAL_CLAUDE=$SB/bin/claude")
stage_handoff 1 "$(handoff 'claude-opus-9-9' '' '' x)"$'\n'
WENV=("${PFW[@]}"); W "$n" --model 'opus[1m]'; WENV=()
ne "W12 an unknown full id on a hand-off: non-zero" 0 "$RC"; eq "W12 only the first launch ran" 1 "$(nlaunch)"; has "W12 says the CLI does not know it" "does not know the model" "$ERR"
eq "W12 the alias launch never called the CLI (one preflight call, for the hand-off)" 1 "$(wc -l < "$SB/pf.calls" | tr -d ' ')"

# 12c. M1: a hand-off to the DEFAULT account (empty account_dir) from a wrapper that runs on a second account is checked against the
#      default account: the stand-in CLI must see CLAUDE_CONFIG_DIR unset, not the wrapper's own. (The launch then proceeds.)
sandbox; n=$(nameFor W12c); mkdir -p "$SB/home/.claude-acct2"; mk_pfbin
stage_handoff 1 "$(handoff 'claude-opus-9-9' '' '' x)"$'\n'
WENV=("${PFENV[@]}" PF_MODE=ok "CLAUDE_CONFIG_DIR=$SB/home/.claude-acct2"); W "$n" --model 'opus[1m]'; WENV=()
eq "W12c the hand-off launched" 2 "$(nlaunch)"
eq "W12c the CLI ran under the DEFAULT account, not the wrapper's second account" "default|--model claude-opus-9-9 -p ok --output-format json --tools  --disable-slash-commands" "$(cat "$SB/pf.calls")"
eq "W12c and the fresh session got the variable unset" "unset" "$(launch_cfg 2)"

# 13. What the wrapper puts in claude's argv is exactly what scripts/launched_window.py reads: a [1m] tag is a 1M window, any other tag 200K.
#     The recorded argv of a launch becomes a fake process (claude + that argv) under a fake /proc.
sandbox; n=$(nameFor W13); W "$n" --model 'sonnet[1m]' go
fakep="$SB/fakeproc"; mkdir -p "$fakep/501" "$fakep/500"
printf '500 (bash) S 1 0 0 0\n' > "$fakep/500/stat"; : > "$fakep/500/cmdline"
printf '501 (claude) S 500 0 0 0\n' > "$fakep/501/stat"; { printf 'claude\0'; cat "$SB/stub/argv.1"; } > "$fakep/501/cmdline"
eq "W13 the wrapper's argv reads as a 1M window" 1m "$(python3 "$ROOT/scripts/launched_window.py" --proc-root "$fakep" --pid 501 | python3 -c 'import json,sys; print(json.load(sys.stdin)["window"])')"
sandbox; n=$(nameFor W13b); W "$n" --model claude-sonnet-5-5 go
fakep="$SB/fakeproc"; mkdir -p "$fakep/501" "$fakep/500"
printf '500 (bash) S 1 0 0 0\n' > "$fakep/500/stat"; : > "$fakep/500/cmdline"
printf '501 (claude) S 500 0 0 0\n' > "$fakep/501/stat"; { printf 'claude\0'; cat "$SB/stub/argv.1"; } > "$fakep/501/cmdline"
eq "W13b a tag without [1m] reads as a 200K window" 200k "$(python3 "$ROOT/scripts/launched_window.py" --proc-root "$fakep" --pid 501 | python3 -c 'import json,sys; print(json.load(sys.stdin)["window"])')"

finish
