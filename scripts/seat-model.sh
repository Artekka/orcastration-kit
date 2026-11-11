#!/usr/bin/env bash
# seat-model.sh — choose the model and effort YOUR seat starts on, once, for every project on this machine
# (orchestration-kit).
#
# The seat is the session you talk to all day, so its model is a personal choice. This saves it in
# ${KIT_STATE_DIR:-~/.orchestration-kit}/seat-model, and every seat start and seat recycle on this machine
# uses it (start-team.sh, recycle-sibling.sh <Seat>), ahead of a project's `seat_model:` / `model:`. A
# --model or --effort flag still wins. The other sessions are untouched: the seat picks their models by lane.
#
# Usage: scripts/seat-model.sh                      a short menu: the model (its context window in a column
#                                                   of its own), then the effort
#        scripts/seat-model.sh --show               the saved choice on one line
#        scripts/seat-model.sh --label              the same, short ("fable · high"), for a menu line
#        scripts/seat-model.sh --set MODEL [EFFORT] save without the menu
#   MODEL   fable | opus[1m] | sonnet[1m] | haiku | a full model id | project (no choice here: each project's
#           own setting decides)
#   EFFORT  low | medium | high | xhigh | max | default (the model's own default; nothing is passed)
# The file is written in place, so a settings file you keep elsewhere and link here stays a link.
# Exit 0 saved or unchanged, 64 usage or a value that is no model or effort.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-launch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-launch.sh"   # launch_valid_model / launch_valid_effort
STATE="${KIT_STATE_DIR:-$HOME/.orchestration-kit}"; FILE="$STATE/seat-model"
NO_MODEL="each project's own setting"; NO_MODEL_SHORT="project's own"; NO_EFFORT="the model's default"

get() { [ -f "$FILE" ] || return 0; sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$FILE" | tail -1 | sed 's/[[:space:]]*$//'; }
label() {  # "fable · high" | "fable" | "project's own · high" | "project's own"
  local m e; m="$(get model)"; e="$(get effort)"
  printf '%s%s\n' "${m:-$NO_MODEL_SHORT}" "${e:+ · $e}"
}
show() {
  local m e; m="$(get model)"; e="$(get effort)"
  echo "seat model: ${m:-$NO_MODEL} · effort: ${e:-$NO_EFFORT}"
}
save() {  # <model or ''> <effort or ''>
  mkdir -p "$STATE" || { echo "cannot make $STATE" >&2; exit 1; }
  { echo "# Your seat's model and effort on this machine, for every project (scripts/seat-model.sh writes this)."
    [ -z "$1" ] || echo "model: $1"
    [ -z "$2" ] || echo "effort: $2"
  } > "$FILE" || { echo "cannot write $FILE" >&2; exit 1; }
}
norm_model() {  # <typed> -> the value to save ('' = project); exit 64 when it is no model
  case "$1" in project|"") printf '' ;; *)
    launch_valid_model "$1" || { echo "not a model: '$1' (fable, opus[1m], sonnet[1m], haiku, a full model id, or project)" >&2; exit 64; }
    printf '%s' "$1" ;; esac
}
norm_effort() {  # <typed> -> the value to save ('' = the model's default); exit 64 when it is no effort
  case "$1" in default|"") printf '' ;; *)
    launch_valid_effort "$1" || { echo "not an effort: '$1' (low, medium, high, xhigh, max, or default)" >&2; exit 64; }
    printf '%s' "$1" ;; esac
}

case "${1:-}" in
  -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --show) show; exit 0 ;;
  --label) label; exit 0 ;;
  --set)
    [ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: seat-model.sh --set MODEL [EFFORT]" >&2; exit 64; }
    m="$(norm_model "$2")" || exit 64
    if [ $# -eq 3 ]; then e="$(norm_effort "$3")" || exit 64; else e="$(get effort)"; fi
    save "$m" "$e"; show; exit 0 ;;
  "") ;;
  *) echo "usage: seat-model.sh [--show | --label | --set MODEL [EFFORT]]" >&2; exit 64 ;;
esac

m="$(get model)"; e="$(get effort)"
echo ""
echo "  Seat model, for every project you start on this machine   (now: ${m:-$NO_MODEL})"
echo "        model     context"
echo "    [1] fable     1M        the tier above opus"
echo "    [2] opus      1M        top tier"
echo "    [3] sonnet    1M        mid tier"
echo "    [4] haiku     200K      small tier"
echo "    [o] other               type a model id"
echo "    [p] project             no choice here: each project's own setting decides"
echo "    [Enter] keep"
a=""; read -r -p "  Model: " a || exit 0
case "$(printf '%s' "$a" | tr -d '[:space:]')" in
  1) m="fable" ;; 2) m="opus[1m]" ;; 3) m="sonnet[1m]" ;; 4) m="haiku" ;;
  [oO]) t=""; read -r -p "  Model id: " t || exit 0
        if launch_valid_model "$t"; then m="$t"; else echo "  Not a model id: '$t'. Kept."; fi ;;
  [pP]) m="" ;;
  "") ;;
  *) echo "  Pick 1-4, o, p, or Enter. Kept." ;;
esac
echo "  Effort for the seat   (now: ${e:-$NO_EFFORT})"
echo "    [1] low   [2] medium   [3] high   [4] xhigh   [5] max   [d] the model's default   [Enter] keep"
a=""; read -r -p "  Effort: " a || { save "$m" "$e"; show; exit 0; }
case "$(printf '%s' "$a" | tr -d '[:space:]')" in
  1) e="low" ;; 2) e="medium" ;; 3) e="high" ;; 4) e="xhigh" ;; 5) e="max" ;;
  [dD]) e="" ;;
  "") ;;
  *) echo "  Pick 1-5, d, or Enter. Kept." ;;
esac
save "$m" "$e"
echo "  saved — $(show)"
