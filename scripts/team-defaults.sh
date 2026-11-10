#!/usr/bin/env bash
# team-defaults.sh — apply YOUR team defaults to a project's `team:` block (orchestration-kit).
#
# The kit's own defaults (seat Orca, siblings Sib1, Sib2) suit anyone. Your own go in one file per machine,
# ${KIT_STATE_DIR:-~/.orchestration-kit}/team-defaults, one `key: value` per line, for example:
#   seat_prefix:     Atlas            the seat becomes Atlas-<project initials>, e.g. Atlas-BS for "Book Shop"
#   names:           Mars,Venus,Vulcan
#   numbered:        w                siblings w1-Mars, w2-Venus...
#   permission_mode: auto             any mode start-team.sh --mode accepts
# Any other `team:` key (siblings, max_sessions, gate_slots, tab_color...) is copied as written.
# kit-init runs this on a project it has just set up; run it yourself on an older project. Without the file
# it does nothing.
#
# Usage: scripts/team-defaults.sh [--repo DIR] [--dry-run]           apply the file to a project
#        scripts/team-defaults.sh --save-own SEAT NAMES [--numbered PFX] [--mode MODE]
#                                       save your own: seat prefix, sibling names (comma list), e.g.
#                                       --save-own Atlas Ceres,Juno,Vesta --numbered w
#        scripts/team-defaults.sh --save-kit    save "the kit's names" (Orca, Sib1, Sib2): the file then holds no keys
#        scripts/team-defaults.sh --show        print the saved choice, or nothing when none is saved yet
# kit-init asks once per machine (no file yet) and saves the answer with --save-own or --save-kit.
# Exit 0 applied (or nothing to do), 1 no overlay in the repo, 64 usage.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-launch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-launch.sh"   # launch_valid_name / launch_valid_mode
REPO="."; DRY=0
DEF="${KIT_STATE_DIR:-$HOME/.orchestration-kit}/team-defaults"
case "${1:-}" in
  --show) [ ! -f "$DEF" ] || cat "$DEF"; exit 0 ;;
  --save-kit)
    mkdir -p "$(dirname "$DEF")"
    printf '%s\n' "# Team names: the kit's own (seat Orca, siblings Sib1, Sib2). Asked once by kit-init; edit or delete to change." > "$DEF"
    echo "saved: the kit's names (Orca, Sib1, Sib2) in $DEF"; exit 0 ;;
  --save-own)
    [ $# -ge 3 ] || { echo "--save-own needs SEAT and NAMES, e.g. --save-own Atlas Ceres,Juno,Vesta" >&2; exit 64; }
    seat="$2"; names="$3"; shift 3
    launch_valid_name "$seat" || { echo "seat '$seat': letters, digits, _ and - only" >&2; exit 64; }
    IFS=',' read -ra ns <<<"$names"
    [ "${#ns[@]}" -ge 1 ] || { echo "names: a comma list, e.g. Ceres,Juno,Vesta" >&2; exit 64; }
    for n in "${ns[@]}"; do launch_valid_name "$n" || { echo "name '$n': letters, digits, _ and - only" >&2; exit 64; }; done
    num=""; mode=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --numbered) [ $# -ge 2 ] || { echo "--numbered needs 1-4 letters, e.g. w" >&2; exit 64; }
          num="$2"; [[ "$num" =~ ^[A-Za-z]{1,4}$ ]] || { echo "numbered: 1-4 letters, e.g. w" >&2; exit 64; }; shift ;;
        --mode) [ $# -ge 2 ] || { echo "--mode needs a permission mode" >&2; exit 64; }
          mode="$2"; launch_valid_mode "$mode" || { echo "--mode '$mode' is not a mode start-team.sh accepts" >&2; exit 64; }; shift ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
      esac
      shift
    done
    mkdir -p "$(dirname "$DEF")"
    {
      echo "# Team names: your own. kit-init applies them to every project it sets up; edit or delete to change."
      echo "seat_prefix:     $seat"
      echo "names:           $names"
      [ -z "$num" ] || echo "numbered:        $num"
      [ -z "$mode" ] || echo "permission_mode: $mode"
    } > "$DEF"
    echo "saved your team names in $DEF:"; sed -n '2,$p' "$DEF"; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; REPO="${1:?--repo needs a directory}" ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
CONF="$REPO/docs/orchestration/ORCHESTRATION.md"
[ -f "$DEF" ] || { echo "no team defaults ($DEF): nothing to apply"; exit 0; }
[ -f "$CONF" ] || { echo "no $CONF: set the kit up first (/orchestration-kit:kit-init)" >&2; exit 1; }

# Project initials: the words of the folder name (spaces, - and _, and camelCase), first letters, at most 3;
# one word gives its first two letters. "Book Shop" -> BS, "appleAndApricot" -> AAA, "hedgehog" -> HE.
initials() {
  local words out="" w
  words="$(printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g; s/[-_]+/ /g' | tr -cd 'A-Za-z0-9 ')"
  # shellcheck disable=SC2086  # split into words on purpose
  set -- $words
  [ $# -gt 0 ] || { printf 'X'; return; }
  if [ $# -eq 1 ]; then printf '%s' "${1:0:2}" | tr '[:lower:]' '[:upper:]'; return; fi
  for w in "$@"; do out="$out${w:0:1}"; done
  printf '%s' "${out:0:3}" | tr '[:lower:]' '[:upper:]'
}

pairs=()
while IFS= read -r line; do
  line="${line%%#*}"
  [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*[:=][[:space:]]*([^[:space:]]+)[[:space:]]*$ ]] || continue
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
  if [ "$k" = seat_prefix ]; then
    k=seat; v="$v-$(initials "$(basename "$(cd "$REPO" && pwd -P)")")"
  fi
  if [ "$k" = permission_mode ] && ! launch_valid_mode "$v"; then
    echo "skipped permission_mode '$v': not a mode start-team.sh accepts (fix $DEF)" >&2; continue
  fi
  pairs+=("$k=$v")
done < "$DEF"
[ "${#pairs[@]}" -gt 0 ] || { echo "team defaults hold no keys (the kit's names): nothing to apply"; exit 0; }

for kv in "${pairs[@]}"; do echo "team: ${kv%%=*} -> ${kv#*=}"; done
[ "$DRY" -eq 0 ] || { echo "[dry-run] nothing written"; exit 0; }

# Rewrite the block: a key already there keeps its place (value replaced), a new key goes at the block's end.
tmp="$(mktemp)"
awk -v spec="$(printf '%s\n' "${pairs[@]}")" '
  BEGIN { n = split(spec, L, "\n"); for (i = 1; i <= n; i++) if (L[i] != "") { p = index(L[i], "="); k = substr(L[i], 1, p - 1); val[k] = substr(L[i], p + 1); order[++m] = k } }
  function flush(   i) { for (i = 1; i <= m; i++) if (!(order[i] in done)) printf "  %-17s %s\n", order[i] ":", val[order[i]]; flushed = 1 }
  /^team:[[:space:]]*$/ { inblk = 1; print; next }
  inblk && /^[[:space:]]+[a-z_]+:/ {
    k = $1; sub(":", "", k)
    if (k in val) { printf "  %-17s %s\n", k ":", val[k]; done[k] = 1; next }
    print; next
  }
  inblk { flush(); inblk = 0 }
  { print }
  END { if (inblk) flush(); else if (!flushed) { print ""; print "team:"; flush() } }
' "$CONF" > "$tmp"
cat "$tmp" > "$CONF"; rm -f "$tmp"
echo "applied to ${CONF#"$REPO"/}"
