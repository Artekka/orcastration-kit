#!/usr/bin/env bash
# sibling-shell.sh — the respawn loop a team terminal runs, so a recycle can happen in the SAME tab
# (orchestration-kit v0.7.0).
#
#   scripts/sibling-shell.sh <Name> [--mode M] --model M [--effort E] [prompt]
#       (prompt defaults to /orchestration-kit:orient; --mode is normal|accept-edits|auto|bypass-available)
#
# It runs `claude --name <Name> [mode flags] --model M [--effort E] <prompt>` as a CHILD, not via exec.
# When the child exits it looks for a hand-off file; if scripts/recycle-sibling.sh left one, it starts
# the next claude from it IN THE SAME TAB. No file = a plain /exit, and the wrapper exits so the tab
# closes as it always did. That is what makes a recycle in-place: recycle-sibling.sh writes the file,
# SIGTERMs only the old claude, and this loop does the launch. The order is kill-then-launch, which is
# safe because a recycle only ever runs after the session replied "retro complete": nothing the old
# context held is still needed.
# start-team.sh and recycle-sibling.sh open every new terminal tab running this wrapper, so a team
# started by the kit recycles in place from its first recycle on. A session started by hand (a bare
# `claude`) is not under a wrapper: its first recycle opens a new tab that runs one.
#
# HAND-OFF FILE  ${SIBLING_STATE_DIR:-$HOME/.orchestration-kit/sessions}/<Name>.next
#   model=opus[1m]        required: the model is always explicit, never inherited
#   effort=high           optional; empty = no --effort flag
#   mode=auto             optional permission mode. recycle-sibling.sh always writes it (its --mode, else the
#                         team block's permission_mode:, else normal), never the old session's mode. Absent
#                         (a hand-written file only) = the wrapper keeps the mode it was started with
#   account_dir=/home/x/.claude-acctN   CLAUDE_CONFIG_DIR for this launch; empty = the default account (unset)
#   prompt_b64=<base64>   the prompt, base64 on ONE line, so spaces, quotes, `;`, `$`, backticks and
#                         newlines survive with no shell parsing of the file at all
# The file is read with a plain line loop and never sourced or eval'd. Unknown keys, a malformed
# model/effort/mode or a missing model are REFUSED (the wrapper exits non-zero) rather than launched.
# The writer moves a finished temp file into place (tmp + mv), so this loop never sees a half file.
#
# CRASH-LOOP GUARD: if claude exits within SIBLING_MIN_RUN_SECS (default 5) twice in a row, the
# wrapper stops even if a hand-off is waiting, and says why. A bad model id or a logged-out account
# makes claude die at once; without this the loop would respin forever.
#
# Why `main` and the one-line `main "$@"; exit $?` at the bottom: bash reads a script a few bytes at
# a time while it runs, and this one lives for days. If the file is rewritten in place meanwhile
# (an editor, a checkout, a plugin update) bash would resume at its old byte offset in the NEW text.
# Parsing the whole loop as one function, and ending on a line that never returns to the file, rules
# that out.
#
# Env (tests set these): SIBLING_STATE_DIR, SIBLING_MIN_RUN_SECS. The child inherits this shell's
# stdin/stdout, which is why it is a foreground child (a `&` job would lose the terminal's stdin).
# Written for bash 3.2+ (macOS /bin/bash).
set -uo pipefail

main() {
  local name="" model="" effort="" mode="normal" prompt="/orchestration-kit:orient" have_prompt=0
  local state_dir="${SIBLING_STATE_DIR:-$HOME/.orchestration-kit/sessions}"
  local min_run="${SIBLING_MIN_RUN_SECS:-5}"
  local model_re='^[a-z][a-z0-9.-]*(\[1m\])?$'

  while [ $# -gt 0 ]; do
    case "$1" in
      --model) [ $# -ge 2 ] || { echo "sibling-shell: --model needs a model id" >&2; return 64; }; model="$2"; shift 2 ;;
      --effort) [ $# -ge 2 ] || { echo "sibling-shell: --effort needs low|medium|high|xhigh|max" >&2; return 64; }; effort="$2"; shift 2 ;;
      --mode) [ $# -ge 2 ] || { echo "sibling-shell: --mode needs normal|accept-edits|auto|bypass-available" >&2; return 64; }; mode="$2"; shift 2 ;;
      -*) echo "sibling-shell: unknown flag '$1' (flags: --model M, --effort E, --mode M)" >&2; return 64 ;;
      *)
        if [ -z "$name" ]; then name="$1"
        elif [ "$have_prompt" = 0 ]; then prompt="$1"; have_prompt=1
        else echo "sibling-shell: too many arguments; quote a prompt that has spaces" >&2; return 64
        fi
        shift ;;
    esac
  done
  [ -n "$name" ] || { echo "usage: sibling-shell.sh <Name> [--mode M] --model M [--effort E] [prompt]" >&2; return 64; }
  [[ "$model" =~ $model_re ]] || { echo "sibling-shell: --model must look like opus[1m], sonnet[1m], haiku or a full model id; got '$model'" >&2; return 64; }
  case "$effort" in ''|low|medium|high|xhigh|max) ;; *) echo "sibling-shell: --effort must be one of low|medium|high|xhigh|max; got '$effort'" >&2; return 64 ;; esac
  case "$mode" in normal|accept-edits|auto|bypass-available) ;; *) echo "sibling-shell: --mode must be one of normal|accept-edits|auto|bypass-available; got '$mode'" >&2; return 64 ;; esac

  local next="$state_dir/$name.next"
  local fast=0 rc start end elapsed claimed
  while :; do
    # EPOCHREALTIME (bash 5) when present, else whole seconds from `date`: $SECONDS only ticks in whole
    # seconds, so an instant exit that straddles a tick would read as a 1 s run. Milliseconds either way.
    start=$(now_ms)
    # The child's argv is exactly `claude --name <Name> [mode flags] --model M [--effort E] <prompt>`:
    # --name stays FIRST, because pgrep -f "^claude --name <Name>( |$)" finds the child by it.
    run_claude "$name" "$mode" "$model" "$effort" "$prompt"
    rc=$?
    end=$(now_ms)
    elapsed=$((end - start))

    # Consume the hand-off: mv is atomic, so a file is claimed by exactly one reader, and the claimed
    # copy is deleted below whatever we then decide. An unconsumed file would relaunch a duplicate.
    claimed="$next.claimed.$$"
    if ! mv -- "$next" "$claimed" 2>/dev/null; then
      return "$rc"                      # no hand-off: a plain exit closes the tab
    fi

    if [ "$elapsed" -lt $((min_run * 1000)) ]; then fast=$((fast + 1)); else fast=0; fi
    if [ "$fast" -ge 2 ]; then
      rm -f -- "$claimed"
      echo "sibling-shell: claude exited within ${min_run}s twice in a row; not relaunching ${name} (a hand-off was waiting). Check the model id and that the account is logged in." >&2
      [ -t 0 ] && read -r -p "Press Enter to close this tab. " _
      return 1
    fi

    local m="" e="" md="" a="" p64="" have_a=0 line key val bad=""
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      key="${line%%=*}"; val="${line#*=}"
      case "$key" in
        model) m="$val" ;;
        effort) e="$val" ;;
        mode) md="$val" ;;
        account_dir) a="$val"; have_a=1 ;;
        prompt_b64) p64="$val" ;;
        *) bad="unknown key '$key'" ;;
      esac
    done < "$claimed"
    rm -f -- "$claimed"
    [[ "$m" =~ $model_re ]] || bad="${bad:-model must be explicit and well-formed; got '$m'}"
    case "$e" in ''|low|medium|high|xhigh|max) ;; *) bad="${bad:-bad effort '$e'}" ;; esac
    case "$md" in ''|normal|accept-edits|auto|bypass-available) ;; *) bad="${bad:-bad mode '$md'}" ;; esac
    if [ -n "$bad" ]; then
      echo "sibling-shell: refusing the hand-off for ${name} (${bad}); not launching it." >&2
      return 1
    fi

    model="$m"; effort="$e"
    [ -z "$md" ] || mode="$md"
    # `|| true`: a prompt that is not valid base64 becomes an empty one, which falls back to the default
    # orient prompt. `--decode` (not -d) is the spelling both GNU and macOS base64 accept.
    prompt=$(printf '%s' "$p64" | base64 --decode 2>/dev/null || true)
    [ -n "$prompt" ] || prompt="/orchestration-kit:orient"
    # The account is part of the hand-off: empty means the default account, so unset the variable a
    # previous iteration may have exported.
    if [ "$have_a" = 1 ]; then
      if [ -n "$a" ]; then export CLAUDE_CONFIG_DIR="$a"; else unset CLAUDE_CONFIG_DIR; fi
    fi
  done
}

now_ms() {
  local t
  # SIBLING_NO_EPOCHREALTIME is a test switch: it forces the `date` branch (bash 3.2 has no EPOCHREALTIME).
  if [ -z "${SIBLING_NO_EPOCHREALTIME:-}" ] && [ -n "${EPOCHREALTIME:-}" ]; then t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000))
  else echo $(($(date +%s) * 1000)); fi
}

# The one place claude's argv is built. The mode flags mirror lib-launch.sh's launch_mode_flags (a test
# compares the two, so they cannot drift).
run_claude() {  # <name> <mode> <model> <effort> <prompt>
  local mflag=()
  case "$2" in
    accept-edits) mflag=(--permission-mode acceptEdits) ;;
    auto) mflag=(--permission-mode auto) ;;
    bypass-available) mflag=(--allow-dangerously-skip-permissions) ;;
  esac
  if [ -n "$4" ]; then
    claude --name "$1" ${mflag[@]+"${mflag[@]}"} --model "$3" --effort "$4" "$5"
  else
    claude --name "$1" ${mflag[@]+"${mflag[@]}"} --model "$3" "$5"
  fi
}

main "$@"; exit $?
