#!/usr/bin/env bash
# start-team.sh — open the seat + N sibling Claude sessions, each in its own window (orchestration-kit).
#
# Zero setup: with no flags and no config it opens `Orca` (/orchestration-kit:orchestrate) and
# `Sib1`..`Sib2` (/orchestration-kit:orient) in the repo's main checkout, in normal permission
# mode. Names already running are SKIPPED, so re-running only fills the gaps. The terminal is
# detected per machine (WSL, tmux, macOS Terminal/iTerm2, Linux desktop emulators, Git Bash;
# see lib-launch.sh); with nothing usable it prints the commands to run by hand and exits 2.
# You can change the team size, names, permission mode or terminal at any time — just ask Claude.
#
# Usage:
#   scripts/start-team.sh [--dry-run] [--siblings N] [--seat NAME] [--prefix PFX] [--names A,B,C]
#                         [--numbered PFX] [--mode normal|accept-edits|auto] [--model M] [--effort E]
#                         [--terminal BACKEND|auto|list] [--repo DIR]
#   --terminal list   print every backend and whether it is available here, then exit
#   --names A,B,C     name siblings from this pool instead of <prefix>1..N: names already running are
#                     kept, the rest are drawn at random (TEAM_NAMES_SHUFFLE=0 keeps list order)
#   --numbered PFX    with a pool: number the siblings, PFX1-<name>, PFX2-<name>... (e.g. w -> w1-Mars);
#                     a running one keeps its number, and a new one takes the lowest free number
#   --account N|DIR   launch the whole team on that Claude Code account (docs/MULTI-ACCOUNT.md)
#   --model M         the model for EVERY window (opus[1m] | sonnet[1m] | haiku | a full id). Always
#                     passed explicitly; default = the team block's `model:`, else opus[1m]. One value
#                     for the whole team: give each lane its own with `recycle-sibling.sh <Name> --model`.
#   --effort E        low|medium|high|xhigh|max; passed only when given. Bad values exit 64.
#
# Precedence: flags > the optional `team:` block in docs/orchestration/ORCHESTRATION.md > defaults.
# A --mode flag is saved into that block (permission_mode:) so recycles relaunch in the same mode.
#   team:
#     seat:             Orca
#     prefix:           Sib
#     names:            Mars,Venus,Vulcan   (optional: a pool of sibling names, comma list, no spaces)
#     numbered:         w                   (optional, with names: siblings w1-Mars, w2-Venus...)
#     siblings:         2
#     permission_mode:  normal
#     terminal:         auto
#     model:            opus[1m]      (optional: the default for every launch)
#     effort:           high          (optional)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-launch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-launch.sh"

usage() { sed -n '11,37p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

SEAT_PROMPT="/orchestration-kit:orchestrate"
SIB_PROMPT="/orchestration-kit:orient"
DRY=0; REPO=""; f_seat=""; f_prefix=""; f_n=""; f_mode=""; f_term=""; f_account=""; f_model=""; f_effort=""; f_model_set=0; f_effort_set=0; f_names=""; f_numbered=""
# A flag whose value is missing is exit 64 like a bad value (`${1:?}` would exit 1).
need_value() { [ "$1" -ge 2 ] || { echo "$2 needs a value: $3" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --siblings) shift; f_n="${1:?--siblings needs a number}" ;;
    --seat) shift; f_seat="${1:?--seat needs a name}" ;;
    --prefix) shift; f_prefix="${1:?--prefix needs a name prefix}" ;;
    --names) shift; f_names="${1:?--names needs a comma list, e.g. Mars,Venus,Vulcan}" ;;
    --numbered) shift; f_numbered="${1:?--numbered needs 1-4 letters, e.g. w}" ;;
    --mode) shift; f_mode="${1:?--mode needs normal|accept-edits|auto}" ;;
    --account) shift; f_account="${1:?--account needs a number (1, 2, 3...) or a config directory}" ;;
    # f_model_set / f_effort_set record "given", apart from "empty": `--model=` is a given, invalid value.
    --model) need_value $# --model "a model id, e.g. opus[1m]"; shift; f_model="$1"; f_model_set=1 ;;
    --model=*) f_model="${1#--model=}"; f_model_set=1 ;;
    --effort) need_value $# --effort "low|medium|high|xhigh|max"; shift; f_effort="$1"; f_effort_set=1 ;;
    --effort=*) f_effort="${1#--effort=}"; f_effort_set=1 ;;
    --terminal) shift; f_term="${1:?--terminal needs a backend, auto, or list}" ;;
    --repo) shift; REPO="${1:?--repo needs a directory}" ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done

REPO="$(launch_repo "$REPO")" || exit 64
if [ "$f_term" = list ]; then launch_list_backends; exit 0; fi
launch_team_conf "$REPO"

seat="${f_seat:-${TEAM_SEAT:-Orca}}"
prefix="${f_prefix:-${TEAM_PREFIX:-Sib}}"
n="${f_n:-${TEAM_N:-2}}"
if ! [[ "$n" =~ ^[0-9]$ ]]; then echo "--siblings must be 0..9: '$n'" >&2; exit 64; fi
launch_set_mode "${f_mode:-${TEAM_MODE:-normal}}"
launch_set_account "$f_account"
launch_resolve_model "$f_model" "$f_model_set" "$f_effort" "$f_effort_set"

names=("$seat"); prompts=("$SEAT_PROMPT")
pool_csv="${f_names:-${TEAM_NAMES:-}}"; num=""
if [ -n "$pool_csv" ]; then
  # A name pool: keep the pool's names that are already running (a re-run fills gaps, as with numbers),
  # then draw the rest at random. The seat's own name is never a sibling.
  IFS=',' read -ra pool <<<"$pool_csv"
  # Numbered siblings (`numbered: w`): w1-<name>, w2-<name>... A running one keeps its number.
  num="${f_numbered:-${TEAM_NUMBERED:-}}"
  [[ -z "$num" || "$num" =~ ^[A-Za-z]{1,4}$ ]] || { echo "numbered: '$num' must be 1-4 letters, e.g. w" >&2; exit 64; }
  live=(); idle=(); seen=" "
  for nm in "${pool[@]}"; do
    launch_valid_name "$nm" || { echo "names: '$nm' is not a valid session name (letters, digits, _ and - only)" >&2; exit 64; }
    [ "$nm" = "$seat" ] && continue
    case "$seen" in *" $nm "*) continue ;; esac
    seen="$seen$nm "
    held=""
    if [ -n "$num" ]; then
      for k in 1 2 3 4 5 6 7 8 9; do [ -z "$(launch_pids "$num$k-$nm")" ] || { held="$num$k-$nm"; break; }; done
    fi
    [ -n "$held" ] || [ -z "$(launch_pids "$nm")" ] || held="$nm"
    if [ -n "$held" ]; then live+=("$held"); else idle+=("$nm"); fi
  done
  if [ "$(( ${#live[@]} + ${#idle[@]} ))" -lt "$n" ]; then
    echo "names: the pool has $(( ${#live[@]} + ${#idle[@]} )) usable names for $n siblings; add names or lower --siblings" >&2; exit 64
  fi
  if [ "${TEAM_NAMES_SHUFFLE:-1}" != 0 ] && [ "${#idle[@]}" -gt 1 ]; then
    if command -v shuf >/dev/null 2>&1; then mapfile -t idle < <(printf '%s\n' "${idle[@]}" | shuf)
    else
      for ((i = ${#idle[@]} - 1; i > 0; i--)); do j=$((RANDOM % (i + 1))); t="${idle[$i]}"; idle[$i]="${idle[$j]}"; idle[$j]="$t"; done
    fi
  fi
  for nm in "${live[@]+"${live[@]}"}"; do
    [ "$(( ${#names[@]} - 1 ))" -lt "$n" ] || break
    names+=("$nm"); prompts+=("$SIB_PROMPT")
  done
  k=0
  for nm in "${idle[@]+"${idle[@]}"}"; do
    [ "$(( ${#names[@]} - 1 ))" -lt "$n" ] || break
    if [ -n "$num" ]; then
      # The lowest number no running sibling of this pool holds.
      while :; do
        k=$((k + 1))
        [ "$k" -le 9 ] || { echo "numbered: no free number 1-9 for $nm" >&2; exit 64; }
        case " ${live[*]-} " in *" $num$k-"*) continue ;; esac
        break
      done
      nm="$num$k-$nm"
    fi
    names+=("$nm"); prompts+=("$SIB_PROMPT")
  done
else
  for i in $(seq 1 "$n"); do names+=("${prefix}${i}"); prompts+=("$SIB_PROMPT"); done
fi
for i in "${!names[@]}"; do launch_check_args "${names[$i]}" "${prompts[$i]}"; done

launch_init "$REPO" "${f_term:-${TEAM_TERMINAL:-}}"

if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] nothing will be launched or saved"
  launch_describe_env
  src="none (built-in defaults)"
  if [ -n "$TEAM_SEAT$TEAM_PREFIX$TEAM_NAMES$TEAM_N$TEAM_MODE$TEAM_TERMINAL" ]; then src="team: block in ${TEAM_CONF#"$REPO"/}"; fi
  echo "team       seat=${seat} siblings=${n} ${pool_csv:+names=${pool_csv} }${num:+numbered=${num} }prefix=${prefix} mode=${LAUNCH_MODE} terminal=${f_term:-${TEAM_TERMINAL:-auto}}   config: ${src}; flags override"
  if [ "$LAUNCH_BACKEND" = manual ]; then echo "manual     nothing can open windows here; a real run prints these commands and exits 2"; fi
else
  if [ "$LAUNCH_FORCED" = 1 ] && [ "$LAUNCH_AVAILABLE" = 0 ]; then
    echo "terminal '$LAUNCH_BACKEND' — $LAUNCH_REASON. See: scripts/start-team.sh --terminal list" >&2; exit 64
  fi
  if [ -n "$f_mode" ] && [ "$f_mode" != "$TEAM_MODE" ]; then launch_save_mode "$REPO" "$LAUNCH_MODE"; fi
  if [ "$LAUNCH_BACKEND" = manual ]; then
    echo "No terminal this script can open windows in ($LAUNCH_REASON)." >&2
    echo "Open one terminal per session and run:" >&2
    for i in "${!names[@]}"; do echo "  $(launch_manual_cmd "${names[$i]}" "${prompts[$i]}")" >&2; done
    exit 2
  fi
  echo "terminal   $LAUNCH_BACKEND ($LAUNCH_REASON)"
fi

# Session cap: count the names this run would actually open (running ones are skipped below).
adding=0; for nm in "${names[@]}"; do [ -n "$(launch_pids "$nm")" ] || adding=$((adding + 1)); done
launch_cap_warn "$adding"

failed=0
for i in "${!names[@]}"; do
  name="${names[$i]}"; prompt="${prompts[$i]}"
  running="$(launch_pids "$name")"
  if [ -n "$running" ]; then
    echo "SKIP   $name — already running (pid $(echo "$running" | tr '\n' ' ' | sed 's/ $//'))"
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    echo "LAUNCH $name"
    launch_describe "$name" "$prompt" | sed 's/^/       /'
    continue
  fi
  if launch_open "$name" "$prompt" ""; then
    if [ "$LAUNCH_FRESH" = unverified ]; then echo "OPENED $name (not verifiable here: no pgrep)"
    else echo "OPENED $name (pid $LAUNCH_FRESH)"; fi
  else
    echo "FAILED $name — no process appeared; open a terminal and run: $(launch_manual_cmd "$name" "$prompt")" >&2
    failed=1
  fi
done
if [ "$DRY" -eq 0 ] && [ "$failed" -eq 0 ]; then
  if [ "$LAUNCH_BACKEND" = tmux-detached ]; then echo "attach with: tmux attach -t $(launch_tmux_session)"; fi
  echo "Team up. Talk to the seat (${seat}); siblings report to it."
  echo "You can change the team size, names, permission mode or terminal any time — just ask Claude."
fi
exit "$failed"
