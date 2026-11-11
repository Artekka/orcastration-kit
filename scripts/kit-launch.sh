#!/usr/bin/env bash
# kit-launch.sh — the project picker behind your start word (orchestration-kit).
#
# kit-word.sh install <word> makes <word> run this. It lists the projects in your projects folder;
# picking one with the kit set up (docs/orchestration/ORCHESTRATION.md) offers its team
# (scripts/start-team.sh) or one plain Claude chat there. Picking one without the kit offers to set
# it up (/orchestration-kit:kit-init) or open a plain Claude chat. [n] makes a new project.
# The menu's second line names the installed kit and its version.
#
# Usage: kit-launch.sh [project]      a name in the projects folder skips the menu
#        kit-launch.sh --list         the projects and whether each has the kit, then exit
#        kit-launch.sh news           run news_cmd (below), then exit
# Settings, in ${KIT_STATE_DIR:-~/.orchestration-kit}/launcher.conf (key=value; kit-word.sh writes it):
#   projects_dir=~/projects           where projects live (default ~/projects)
#   before_start=~/bin/trust.sh       optional: a command run before anything starts in a folder, with the
#                                     folder as its last argument (e.g. to mark it trusted in Claude Code)
#   header_cmd=~/bin/kit-status.sh    optional: a command whose first output line replaces the kit/version
#                                     line (e.g. to add your own notes about the kit); 3 s limit
#   news_cmd=~/bin/kit-news.sh        optional: what `<word> news` runs
#   update_cmd=~/bin/kit-update.sh    optional: the menu gains [u] update the kit, which runs it in this
#                                     terminal (e.g. a Claude chat that runs /orchestration-kit:kit-update);
#                                     exit 2 from it means "nothing to update": the menu stays open
#   chat_args=--model sonnet          optional: extra claude arguments for [c] one chat
# Folders ending in -Test (trial copies), folders starting with _ (e.g. _archive), git worktrees (a .git
# file, not a folder: a sibling's working copy of another project) and the kit's own folder are not listed.
# Exit 0 done or quit, 1 no such project, 64 usage.
set -uo pipefail

KIT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STATE="${KIT_STATE_DIR:-$HOME/.orchestration-kit}"
CONF="$STATE/launcher.conf"

conf() {  # <key> -> its value, ~ expanded; '' when unset
  [ -f "$CONF" ] || return 0
  local v; v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -1 | sed 's/[[:space:]]*$//')"
  case "$v" in "~"|"~/"*) v="$HOME${v#\~}" ;; esac
  printf '%s' "$v"
}
PROJECTS="$(conf projects_dir)"
if [ -z "$PROJECTS" ]; then PROJECTS="$HOME/projects"; fi
WORD="$(conf word)"; [ -n "$WORD" ] || WORD="kit"

has_kit() { [ -f "$1/docs/orchestration/ORCHESTRATION.md" ]; }

kit_version() {  # the installed kit's version, from its plugin manifest
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$KIT/.claude-plugin/plugin.json" 2>/dev/null | head -1
}

kit_line() {  # header_cmd's first line, else "orchestration-kit <version>"
  local hc line=""; hc="$(conf header_cmd)"
  if [ -n "$hc" ]; then
    local -a cmd; read -ra cmd <<<"$hc"
    if command -v timeout >/dev/null 2>&1; then line="$(timeout 3 "${cmd[@]}" 2>/dev/null | head -1)"
    else line="$("${cmd[@]}" 2>/dev/null | head -1)"; fi
  fi
  [ -n "$line" ] || line="orchestration-kit $(kit_version)"
  printf '%s' "$line"
}

# run <dir> <command...>: start it in <dir>, in this terminal. KIT_LAUNCH_DRY=1 prints it instead (tests).
run() {
  local dir="$1" before; shift
  before="$(conf before_start)"
  if [ -n "${KIT_LAUNCH_DRY:-}" ]; then
    [ -z "$before" ] || printf 'BEFORE %s %s\n' "$before" "$dir"
    printf 'RUN in %s: %s\n' "$dir" "$*"; return 0
  fi
  cd "$dir" || { echo "cannot enter $dir" >&2; return 1; }
  if [ -n "$before" ]; then
    local -a cmd; read -ra cmd <<<"$before"
    "${cmd[@]}" "$dir" || echo "    (before_start failed: $before)" >&2
  fi
  exec "$@"
}

chat() {  # <project>: one plain Claude chat, with chat_args= when set
  local -a extra=(); read -ra extra <<<"$(conf chat_args)"
  run "$1" claude ${extra[@]+"${extra[@]}"}
}

start_team() {  # <project>
  local p="$1" st="$1/scripts/start-team.sh"
  echo "==> $(basename "$p"): starting its team"
  # The project's own copy first: it is the version the project's gate was run against.
  if [ -f "$st" ]; then run "$p" bash "$st"; else run "$p" bash "$KIT/scripts/start-team.sh" --repo "$p"; fi
}

team_or_chat() {
  local p="$1" a=""
  read -r -p "    [t] team   [c] one Claude chat   [b] back : " a || return 1
  case "$(printf '%s' "$a" | tr -d '[:space:]')" in
    [tT]) start_team "$p" ;;
    [cC]) chat "$p" ;;
    [bB]|"") return 2 ;;
    *) echo "    Pick t, c, or b."; return 2 ;;
  esac
}

set_up_or_chat() {
  local p="$1" a=""
  echo "==> $(basename "$p") does not have the kit set up yet."
  read -r -p "    [s] set it up now   [c] just open a Claude chat there   [b] back : " a || return 1
  case "$a" in
    [sS]*) run "$p" claude "/orchestration-kit:kit-init" ;;
    [cC]*) chat "$p" ;;
    *) return 2 ;;
  esac
}

update_kit() {  # runs update_cmd= in this terminal (KIT_LAUNCH_DRY=1 prints it); 2 = nothing to update
  local -a cmd; read -ra cmd <<<"$(conf update_cmd)"
  if [ -n "${KIT_LAUNCH_DRY:-}" ] && [ -z "${KIT_LAUNCH_RUN_UPDATE:-}" ]; then printf 'UPDATE %s\n' "${cmd[*]}"; return 0; fi
  "${cmd[@]}"
}

open_project() { if has_kit "$1"; then team_or_chat "$1"; else set_up_or_chat "$1"; fi; }

new_project() {
  local name="" dir
  read -r -p "    New project name: " name || return 1
  case "$name" in ""|*/*|.*) echo "    Not a usable folder name: '$name'"; return 2 ;; esac
  dir="$PROJECTS/$name"
  [ ! -e "$dir" ] || { echo "    $dir already exists"; return 2; }
  mkdir -p "$dir" && git -C "$dir" init -q && echo "==> made $dir (a new git repo)"
  run "$dir" claude "/orchestration-kit:kit-init"
}

PROJ=()
list_projects() {
  PROJ=()
  local d
  [ -d "$PROJECTS" ] || return 0
  while IFS= read -r -d '' d; do
    case "$d" in *-Test) continue ;; esac
    [ -f "$d/.git" ] && continue
    [ "$(cd "$d" && pwd -P)" = "$(cd "$KIT" && pwd -P)" ] && continue
    PROJ+=("$d")
  done < <(find "$PROJECTS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '_*' -print0 | sort -z)
}

list_projects
case "${1:-}" in
  -h|--help) sed -n "2,23p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --list)
    for d in "${PROJ[@]+"${PROJ[@]}"}"; do if has_kit "$d"; then echo "kit  $(basename "$d")"; else echo "-    $(basename "$d")"; fi; done
    exit 0 ;;
  news)
    nc="$(conf news_cmd)"
    [ -n "$nc" ] || { echo "No news command set (news_cmd= in $CONF). Installed: orchestration-kit $(kit_version)."; exit 0; }
    read -ra cmd <<<"$nc"; exec "${cmd[@]}" ;;
  -*) echo "usage: kit-launch.sh [project] | --list | news" >&2; exit 64 ;;
  "") ;;
  *)
    [ -d "$PROJECTS/$1" ] || { echo "no project '$1' in $PROJECTS" >&2; exit 1; }
    open_project "$PROJECTS/$1"; exit $? ;;
esac

KLINE="$(kit_line)"
while :; do
  echo ""
  echo "  $WORD — pick a project   ($PROJECTS)"
  echo "  $KLINE"
  echo "  ------------------------------------------------"
  [ "${#PROJ[@]}" -gt 0 ] || echo "  (no projects yet)"
  for i in "${!PROJ[@]}"; do
    if has_kit "${PROJ[i]}"; then tag="kit: team or chat"; else tag="no kit yet"; fi
    printf '  [%d] %-28s %s\n' "$((i+1))" "$(basename "${PROJ[i]}")" "$tag"
  done
  echo "  ------------------------------------------------"
  if [ -n "$(conf update_cmd)" ]; then echo "  [n] new project   [u] update the kit   [q] quit"
  else echo "  [n] new project   [q] quit"; fi
  c=""
  read -r -p "  Select: " c || exit 0
  case "$c" in
    [qQ]) exit 0 ;;
    [nN]) new_project; rc=$?; [ "$rc" -eq 2 ] || exit "$rc" ;;
    [uU]) if [ -n "$(conf update_cmd)" ]; then update_kit; rc=$?; [ "$rc" -eq 2 ] || exit "$rc"
          else echo "  Pick a number, n, or q."; fi ;;
    *)
      if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#PROJ[@]}" ]; then
        open_project "${PROJ[$((c-1))]}"; rc=$?; [ "$rc" -eq 2 ] || exit "$rc"
      else
        echo "  Pick a number, n, or q."
      fi ;;
  esac
done
