#!/usr/bin/env bash
# recycle-sibling.sh — replace a named Claude Code session with a fresh one (orchestration-kit).
#
# Two modes (v0.7.0). Run ONLY after the session replied "retro complete" (the retro-before-clear
# handshake); SIGTERM, never KILL, so the old transcript flushes either way.
#   in-place  The old `claude`'s parent is a scripts/sibling-shell.sh <Name> wrapper (the respawn loop
#             every tab the kit opens runs). Write the wrapper a hand-off file, SIGTERM ONLY the old
#             claude (never the wrapper), and wait for a fresh `claude --name <Name>` under the SAME
#             wrapper. Same tab, fresh context, explicit model. Kill-then-launch: safe because the
#             session already said "retro complete". No terminal is needed for this path.
#             SELF-RECYCLE (the target claude is an ancestor of this script, i.e. the seat runs it
#             from its own shell tool): the script first re-runs a copy of itself detached
#             (`setsid -f`, log path printed), exits, and the copy does the in-place hand-off from
#             outside the old claude's process tree. No `setsid` (macOS) = new-tab, as before.
#   new-tab   No old process, an old one NOT under a wrapper (started by hand), --new-tab, several
#             old processes, a self-recycle that cannot detach (no `setsid`, or the old claude adopts
#             its orphans), or an in-place attempt that timed out: open a NEW window running the
#             wrapper (so that session recycles in place from then on), wait until the fresh process
#             exists, THEN SIGTERM the old one — launch-first-then-kill, so no seat is ever empty.
# Terminal detection, quoting, nvm: see lib-launch.sh. Where no fresh process can be confirmed (Git
# Bash: no pgrep) the old one is never killed, and in-place is not attempted.
# With no usable terminal ('manual') the new-tab path prints what to do by hand and exits 2.
# You can change the team's names, permission mode or terminal at any time — just ask Claude.
#
# Usage:
#   scripts/recycle-sibling.sh [--dry-run] [--mode normal|accept-edits|auto|bypass-available] [--account N|DIR]
#                              [--model M] [--effort E] [--new-tab] [--force]
#                              [--terminal BACKEND|auto|list] [--repo DIR] <Name> [prompt]
#     prompt defaults to /orchestration-kit:orient, or /orchestration-kit:orchestrate for the seat.
#     mode / terminal default to the team block (ORCHESTRATION.md), else normal / auto-detect.
#     account: the fresh session INHERITS the old one's Claude Code account (its CLAUDE_CONFIG_DIR);
#     --account N|DIR moves it (1 = default ~/.claude, N = ~/.claude-acctN). docs/MULTI-ACCOUNT.md
#     model: ALWAYS passed to the fresh session, never inherited from the old one (the account is,
#     the model is not). --model M = opus[1m] | sonnet[1m] | haiku | a full model id; default = the
#     team block's `model:`, else opus[1m]. --effort low|medium|high|xhigh|max is passed only when
#     given. Bad values exit 64. The lane -> model table is in skills/orchestrate ("Model per lane").
#     --new-tab: skip the in-place path and open a new window, as before v0.7.0.
#     Live work: the old session's live shells (background gate runs, loops) die or run on orphaned when
#     it is SIGTERMed, so the script REFUSES (exit 3) and lists them while any are running. Wait for them,
#     or have the session stop them; --force recycles anyway. Subagents are invisible to this check: the
#     session's "retro complete" must say none are running. --dry-run lists the live shells too.
#   scripts/recycle-sibling.sh Orca          # seat self-recycle
#   scripts/recycle-sibling.sh Sib2 --model 'sonnet[1m]' --effort high
#   DRY_RUN=1 scripts/recycle-sibling.sh <Name>   # same as --dry-run; prints `mode: in-place|new-tab`
#
# Env overrides: REPO_DIR (repo to open in), WT_EXE (full path to wt.exe), SIBLING_STATE_DIR (hand-off
# dir, default ~/.orchestration-kit/sessions), RECYCLE_INPLACE_TIMEOUT (seconds to wait for the in-place
# child, default 60), RECYCLE_CLAIMED_GRACE (extra seconds once the wrapper has claimed the hand-off,
# default 30), RECYCLE_POLL_SECS (default 1), RECYCLE_DETACH_DELAY (seconds the detached copy of a
# self-recycle waits before the SIGTERM, default 2), RECYCLE_DETACH_WAIT (seconds it waits to leave the
# old claude's process tree, default 10), LAUNCH_NO_WRAPPER=1 (open tabs with a bare claude).
set -euo pipefail
orig_args=("$@")   # the detached copy of a self-recycle re-runs with exactly these
# shellcheck source-path=SCRIPTDIR source=lib-launch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-launch.sh"

usage() { sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }

DRY=0; [ -z "${DRY_RUN:-}" ] || DRY=1; FORCE_NEW_TAB=0; FORCE=0; REPO=""; MODE=""; TERM_OPT=""; ACCOUNT=""; MODEL=""; EFFORT=""; MODEL_SET=0; EFFORT_SET=0; args=()
# A flag whose value is missing is exit 64 like a bad value (`${1:?}` would exit 1).
need_value() { [ "$1" -ge 2 ] || { echo "$2 needs a value: $3" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --new-tab) FORCE_NEW_TAB=1 ;;
    --force) FORCE=1 ;;
    --repo) shift; REPO="${1:?--repo needs a directory}" ;;
    --mode) shift; MODE="${1:?--mode needs normal|accept-edits|auto|bypass-available}" ;;
    --account) shift; ACCOUNT="${1:?--account needs a number (1, 2, 3...) or a config directory}" ;;
    # MODEL_SET / EFFORT_SET record "given", apart from "empty": `--model=` is a given, invalid value.
    --model) need_value $# --model "a model id, e.g. opus[1m]"; shift; MODEL="$1"; MODEL_SET=1 ;;
    --model=*) MODEL="${1#--model=}"; MODEL_SET=1 ;;
    --effort) need_value $# --effort "low|medium|high|xhigh|max"; shift; EFFORT="$1"; EFFORT_SET=1 ;;
    --effort=*) EFFORT="${1#--effort=}"; EFFORT_SET=1 ;;
    --terminal) shift; TERM_OPT="${1:?--terminal needs a backend, auto, or list}" ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ "${#args[@]}" -le 2 ] || { echo "too many arguments (<Name> [prompt] only; quote a prompt that has spaces): ${args[*]}" >&2; usage; }
REPO="$(launch_repo "$REPO")" || exit 64
if [ "$TERM_OPT" = list ]; then launch_list_backends; exit 0; fi
[ "${#args[@]}" -ge 1 ] || usage
name="${args[0]}"
launch_team_conf "$REPO"
default_prompt="/orchestration-kit:orient"
if [ "$name" = "${TEAM_SEAT:-Orca}" ]; then default_prompt="/orchestration-kit:orchestrate"; fi
prompt="${args[1]:-$default_prompt}"
launch_check_args "$name" "$prompt"
launch_set_mode "${MODE:-${TEAM_MODE:-normal}}"
launch_resolve_model "$MODEL" "$MODEL_SET" "$EFFORT" "$EFFORT_SET"
launch_init "$REPO" "${TERM_OPT:-${TEAM_TERMINAL:-}}"
# A recycle replaces a session; only one with no old process adds one to the host.
[ -n "$(launch_pids "${args[0]}")" ] || launch_cap_warn 1

manual_help() {
  cat >&2 <<HELP
No terminal this script can open windows in ($LAUNCH_REASON). Do it by hand:
  1. Open a new terminal.
  2. Run:  $(launch_manual_cmd "$name" "$prompt")
  3. Once the fresh session is up, close the old '${name}' terminal (or: pkill -TERM -f '$(launch_pattern "$name")').
HELP
}

old="$(launch_pids "$name")"
if [ -n "$ACCOUNT" ]; then
  launch_set_account "$ACCOUNT"
elif [ -n "$old" ]; then  # keep the session on the account it was running on
  launch_set_account "$(launch_account_of_pid "$(printf '%s\n' "$old" | head -1)")"
fi

# Which mode? In-place needs EXACTLY one old claude whose PARENT is a `sibling-shell.sh <Name>` wrapper
# for this very Name, and a way to see processes (pgrep). Anything else is the new-tab path.
mode=new-tab; wrapper_pid=""
if [ "$FORCE_NEW_TAB" = 0 ] && [ "${LAUNCH_CAN_VERIFY:-0}" = 1 ] && [ -n "$old" ] \
   && [ "$(printf '%s\n' "$old" | wc -l | tr -d ' ')" = 1 ]; then
  wrapper_pid="$(launch_wrapper_pid_of "$old" "$name")"
fi
# Seat self-recycle: when the target claude is an ANCESTOR of this very script (the seat recycling
# itself from its own shell), the in-place SIGTERM would cut our own parent chain before the wait loop
# could finish. v0.7.0 answered with a new tab; now we DETACH instead: re-run a copy of ourselves in a
# new session (`setsid -f`, so it is reparented to init at once) and exit; the copy does the normal
# in-place hand-off from outside the old claude's tree. The copy re-checks the walk (RECYCLE_DETACHED
# is set) and, if the old claude adopts its orphans (a child subreaper) so the copy is still inside,
# falls back to the new tab, whose launch-first-then-kill order survives that.
detach=no
if [ -n "$wrapper_pid" ] && launch_is_ancestor "$old"; then
  if [ -n "${RECYCLE_DETACHED:-}" ]; then
    end=$((SECONDS + ${RECYCLE_DETACH_WAIT:-10}))
    while launch_is_ancestor "$old" && [ "$SECONDS" -lt "$end" ]; do sleep 0.2; done
    if launch_is_ancestor "$old"; then
      echo "detached copy is still inside claude ${old}'s process tree (it adopts its orphans); in-place would SIGTERM our own parent chain, falling back to a new tab" >&2
      wrapper_pid=""
    fi
  elif command -v setsid >/dev/null 2>&1; then
    echo "target claude ${old} is an ancestor of this script (self-recycle): detaching a copy out of its process tree, then recycling in place" >&2
    detach=yes
  else
    echo "target claude ${old} is an ancestor of this script (self-recycle) and setsid is missing: in-place would SIGTERM our own parent chain; using a new tab" >&2
    wrapper_pid=""
  fi
fi
[ -z "$wrapper_pid" ] || mode=in-place

# Live work under the old session (see launch_live_shells). The detached copy of a self-recycle skips it:
# the parent already checked, and the seat's own tool shell, an ancestor then, is no longer one now.
live=""
if [ -n "$old" ] && [ -z "${RECYCLE_DETACHED:-}" ] && [ "${LAUNCH_CAN_VERIFY:-0}" = 1 ]; then
  # shellcheck disable=SC2086  # $old is a newline-separated pid list
  live="$(launch_live_shells $old)"
fi

if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] nothing will be launched or killed"
  launch_describe_env
  launch_describe "$name" "$prompt"
  echo "mode: ${mode}"
  echo "detach: ${detach}"
  if [ -n "$live" ]; then
    printf 'live work  %s\n' "$(printf '%s\n' "$live" | head -1)"; printf '%s\n' "$live" | sed 1d | sed 's/^/           /'
    if [ "$FORCE" = 1 ]; then echo "           --force: a real run recycles anyway"; else echo "           a real run refuses (exit 3) without --force"; fi
  else
    echo "live work  none"
  fi
  if [ "$LAUNCH_CAN_VERIFY" = 1 ]; then
    echo "old pids   ${old:-none} (matched: pgrep -f '$(launch_pattern "$name")') -> SIGTERM after the fresh one appears"
  else
    echo "old pids   unknown (no pgrep) -> nothing is killed; close the old '$name' window by hand"
  fi
  exit 0
fi

if [ -n "$live" ] && [ "$FORCE" = 0 ]; then
  {
    echo "refusing to recycle '${name}': its session still has live shells, which a SIGTERM would kill or orphan:"
    printf '%s\n' "$live" | sed 's/^/  pid /'
    echo "Wait for them to finish (or have '${name}' stop them), then run this again. --force recycles anyway."
  } >&2
  exit 3
fi

if [ "$detach" = yes ]; then
  # The copy's stdout/stderr go to a log, because this process (and the seat's tool call that holds it)
  # is gone by the time the copy fails or finishes. Print the path BEFORE detaching so a failure after
  # the old claude dies is still diagnosable. The copy reads the same flags back from $orig_args.
  mkdir -p "$(launch_state_dir)"
  detach_log="$(launch_state_dir)/$name.recycle.log"
  : > "$detach_log"
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  echo "detaching: a copy will SIGTERM claude ${old} in ${RECYCLE_DETACH_DELAY:-2}s and restart '${name}' in place under wrapper ${wrapper_pid}; log: ${detach_log}"
  RECYCLE_DETACHED=1 setsid -f bash "$self" "${orig_args[@]}" > "$detach_log" 2>&1 < /dev/null
  exit 0
fi

if [ "$mode" = in-place ]; then
  # A detached copy waits a beat first, so the seat's own tool call (which printed the log path and
  # returned) can reach its transcript before the SIGTERM below ends that session.
  [ -z "${RECYCLE_DETACHED:-}" ] || sleep "${RECYCLE_DETACH_DELAY:-2}"
  rc=0; launch_recycle_inplace "$name" "$prompt" "$old" "$wrapper_pid" || rc=$?
  case "$rc" in
    0) echo "fresh ${name}: ${LAUNCH_FRESH} · mode: in-place · account $(launch_account_label) · model ${LAUNCH_MODEL} · SIGTERM old: ${old} · $(date '+%H:%M:%S %Z')"
       exit 0 ;;
    2) exit 1 ;;
  esac
  mode=new-tab   # fell back: the hand-off is gone and nothing will relaunch it
fi

if [ "$LAUNCH_FORCED" = 1 ] && [ "$LAUNCH_AVAILABLE" = 0 ]; then
  echo "terminal '$LAUNCH_BACKEND' — $LAUNCH_REASON. See: scripts/recycle-sibling.sh --terminal list" >&2; exit 64
fi
if [ "$LAUNCH_BACKEND" = manual ]; then manual_help; exit 2; fi

if ! launch_open "$name" "$prompt" "$old"; then
  echo "no fresh '$name' process appeared; the old one is left running: ${old:-none}" >&2
  exit 1
fi
if [ "$LAUNCH_FRESH" = unverified ]; then
  echo "opened a fresh ${name} window (${LAUNCH_BACKEND}) but cannot confirm it here (no pgrep)."
  echo "Nothing was killed: once the new window is up, close the old '${name}' window yourself."
  exit 0
fi

# shellcheck disable=SC2086  # $old may hold several pids, one per line
# (In the in-place fallback `old` may already be dead: it was SIGTERMed there.)
if [ -n "$old" ]; then kill -TERM $old 2>/dev/null || true; fi
echo "fresh ${name}: ${LAUNCH_FRESH} · mode: ${mode} · account $(launch_account_label) · model ${LAUNCH_MODEL} · SIGTERM old: ${old:-none} · via ${LAUNCH_BACKEND} · $(date '+%H:%M:%S %Z')"
if [ "$LAUNCH_BACKEND" = tmux-detached ]; then echo "attach with: tmux attach -t $(launch_tmux_session)"; fi
