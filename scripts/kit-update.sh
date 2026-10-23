#!/usr/bin/env bash
# kit-update.sh — update the installed orchestration kit (and the status HUD, when installed), then say
# what else needs doing. Nothing updates on its own: open sessions keep the version they started with,
# so an update is something you choose, at a quiet moment.
#
# Usage:
#   kit-update.sh status [--fetch]    the installed version and the newest one the marketplace offers;
#                                     --fetch refreshes the marketplace first (network). A marketplace
#                                     that is a local git folder whose commit differs from the installed
#                                     one at the same version counts as newer (run --reinstall). Exit 0
#                                     up to date, 10 an update is available, 1 the kit is not installed
#   kit-update.sh run [--yes] [--reinstall] [--projects DIR]
#                                     1. says how many Claude sessions are open (they keep the old
#                                        version until restarted) and asks before going on (--yes: no ask)
#                                     2. claude plugin marketplace update <marketplace>
#                                     3. claude plugin update orchestration-kit@<marketplace>, and (the HUD's installed
#                                        copy refreshed from the folder when it is behind at the same version)
#                                        status-hud@<marketplace> when it is installed
#                                     4. the project report below
#                                     --reinstall: uninstall and install instead of update, for a kit
#                                     changed without a version bump (Claude Code installs by version)
#   kit-update.sh projects [--projects DIR]
#                                     projects with the kit set up whose copies of the kit's session
#                                     scripts differ from the installed kit (kit-init copies them once
#                                     and never overwrites them)
#   kit-update.sh refresh <project>   copy the installed kit's session scripts over that project's
#                                     copies; each replaced file is kept as <file>.bak-<date>
# DIR defaults to projects_dir= in ~/.orchestration-kit/launcher.conf, else ~/projects.
# Env: CLAUDE_CONFIG_DIR (default ~/.claude), KIT_STATE_DIR (default ~/.orchestration-kit).
# Exit 0 done, 1 failed or declined, 10 (status) update available, 64 usage.
set -uo pipefail

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE="${KIT_STATE_DIR:-$HOME/.orchestration-kit}"
PLUGIN=orchestration-kit
# The scripts kit-init copies into a project (keep in step with skills/kit-init/SKILL.md step 1).
SESSION_SCRIPTS="lib-launch.sh start-team.sh recycle-sibling.sh ctx-fill.py statusline-ctx.sh gate-throttle.sh quiet-mode.sh"

usage() { sed -n '6,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
die() { echo "kit-update: $*" >&2; exit 1; }

json() {  # <python expression over j (the parsed file)> <file>: prints the result, '' on any error
  python3 -c 'import json,sys
try:
    j = json.load(open(sys.argv[2])); r = eval(sys.argv[1])
    print("" if r is None else r)
except Exception:
    print("")' "$1" "$2" 2>/dev/null
}

installed_key() {  # the installed kit's "orchestration-kit@<marketplace>"
  json "next((k for k in j.get('plugins', {}) if k.split('@')[0] == '$PLUGIN'), None)" "$CFG/plugins/installed_plugins.json"
}
installed() {  # <field> of the installed kit's (first) record
  json "j['plugins']['$(installed_key)'][0].get('$1')" "$CFG/plugins/installed_plugins.json"
}
marketplace() { local k; k="$(installed_key)"; printf '%s' "${k#*@}"; }
available() {  # the version the marketplace's local copy offers
  local loc; loc="$(json "j['$(marketplace)'].get('installLocation')" "$CFG/plugins/known_marketplaces.json")"
  [ -n "$loc" ] || return 0
  local v; v="$(json "next((p.get('version') for p in j.get('plugins', []) if p.get('name') == '$PLUGIN'), None)" "$loc/.claude-plugin/marketplace.json")"
  [ -n "$v" ] || v="$(json "j.get('version')" "$loc/.claude-plugin/plugin.json")"
  printf '%s' "$v"
}
source_commit() {  # the marketplace folder's git commit, when it is a local git folder
  local loc; loc="$(json "j['$(marketplace)'].get('installLocation')" "$CFG/plugins/known_marketplaces.json")"
  [ -n "$loc" ] && git -C "$loc" rev-parse HEAD 2>/dev/null
}
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }  # <a> <b>: b is newer

sync_hud() {  # <marketplace>: a directory marketplace keeps the HUD's installed copy by version, so changes that keep
  # the version never reach it through `plugin update`; copy the folder over the installed copy when they differ.
  local mp="$1" loc src dst
  loc="$(json "j['$mp'].get('installLocation')" "$CFG/plugins/known_marketplaces.json")"; src="$loc/plugins/status-hud"
  dst="$(json "next((p.get('installPath') for p in j['plugins'].get('status-hud@$mp', [])), '')" "$CFG/plugins/installed_plugins.json")"
  [ -n "$loc" ] && [ -d "$src" ] && [ -n "$dst" ] && [ -d "$dst" ] || return 0
  [ "$(cd "$src" && pwd -P)" != "$(cd "$dst" && pwd -P)" ] || return 0
  if diff -rq -x node_modules -x .git "$src" "$dst" >/dev/null 2>&1; then return 0; fi
  rm -rf "${dst:?}"/* "${dst:?}"/.[!.]* 2>/dev/null
  cp -a "$src"/. "$dst"/ && echo "status-hud: the installed copy was behind the folder (same version, newer files); refreshed"
}

projects_dir() {
  local d=""
  [ -f "$STATE/launcher.conf" ] && d="$(sed -n 's/^[[:space:]]*projects_dir[[:space:]]*=[[:space:]]*//p' "$STATE/launcher.conf" | tail -1 | sed 's/[[:space:]]*$//')"
  case "$d" in "~"|"~/"*) d="$HOME${d#\~}" ;; esac
  printf '%s' "${d:-$HOME/projects}"
}

cmd_status() {
  local fetch=0; [ "${1:-}" = "--fetch" ] && fetch=1
  [ -n "$(installed_key)" ] || die "$PLUGIN is not installed (claude plugin install $PLUGIN@<marketplace>)"
  if [ "$fetch" -eq 1 ]; then claude plugin marketplace update "$(marketplace)" >/dev/null 2>&1 || echo "kit-update: could not refresh $(marketplace); showing what is known" >&2; fi
  local have want; have="$(installed version)"; want="$(available)"
  if [ -n "$want" ] && newer "$have" "$want"; then
    echo "$PLUGIN $have installed; $want available"; return 10
  fi
  local src inst; src="$(source_commit)"; inst="$(installed gitCommitSha)"
  if [ -n "$src" ] && [ -n "$inst" ] && [ "$src" != "$inst" ] && [ "$want" = "$have" ]; then
    echo "$PLUGIN $have installed; the same version with newer changes (${src:0:7}): run --reinstall"; return 10
  fi
  echo "$PLUGIN $have installed; up to date${want:+ ($want)}"
}

open_sessions() {  # KIT_UPDATE_SESSIONS fixes the count (tests)
  if [ -n "${KIT_UPDATE_SESSIONS:-}" ]; then echo "$KIT_UPDATE_SESSIONS"; return; fi
  pgrep -x claude 2>/dev/null | wc -l | tr -d ' '
}

cmd_projects() {
  local dir="$1" root p f n=0 diffs
  root="$(installed installPath)"
  [ -d "$root/scripts" ] || die "cannot find the installed kit's scripts (installPath: ${root:-none})"
  [ -d "$dir" ] || { echo "Projects: no folder $dir"; return 0; }
  for p in "$dir"/*/; do
    p="${p%/}"; [ -f "$p/docs/orchestration/ORCHESTRATION.md" ] || continue
    diffs=""
    for f in $SESSION_SCRIPTS; do
      [ -f "$p/scripts/$f" ] && [ -f "$root/scripts/$f" ] && ! cmp -s "$p/scripts/$f" "$root/scripts/$f" && diffs="$diffs $f"
    done
    [ -n "$diffs" ] || continue
    [ "$n" -gt 0 ] || echo "Projects with older copies of the kit's scripts (kit-update.sh refresh <project> replaces them):"
    n=$((n+1)); echo "  $(basename "$p"):$diffs"
  done
  [ "$n" -gt 0 ] || echo "Projects: every kit project's script copies match the installed kit."
}

cmd_refresh() {
  local p="${1:-}" root f n=0 stamp
  [ -n "$p" ] || usage
  [ -f "$p/docs/orchestration/ORCHESTRATION.md" ] || die "$p does not have the kit set up"
  root="$(installed installPath)"; stamp="$(date +%Y%m%d)"
  for f in $SESSION_SCRIPTS; do
    [ -f "$p/scripts/$f" ] && [ -f "$root/scripts/$f" ] && ! cmp -s "$p/scripts/$f" "$root/scripts/$f" || continue
    cp -p "$p/scripts/$f" "$p/scripts/$f.bak-$stamp" && cp "$root/scripts/$f" "$p/scripts/$f" && echo "REFRESH $p/scripts/$f" && n=$((n+1))
  done
  echo "$n file(s) refreshed in $(basename "$p"); commit them there (explicit paths) once its gate passes."
}

cmd_run() {
  local yes=0 re=0 dir="" mp before after s a
  while [ $# -gt 0 ]; do
    case "$1" in --yes) yes=1 ;; --reinstall) re=1 ;; --projects) shift; dir="${1:?--projects needs a folder}" ;; *) usage ;; esac; shift
  done
  [ -n "$dir" ] || dir="$(projects_dir)"
  [ -n "$(installed_key)" ] || die "$PLUGIN is not installed"
  mp="$(marketplace)"; before="$(installed version)"
  s="$(open_sessions)"
  if [ "$s" -gt 0 ]; then
    echo "$s Claude session(s) are open, this one included if you run this from a chat. They keep $PLUGIN $before until restarted."
  fi
  if [ "$yes" -eq 0 ]; then
    read -r -p "Update $PLUGIN now? [y/N] " a || a=""
    case "$a" in [yY]*) ;; *) echo "Not updated."; return 1 ;; esac
  fi
  claude plugin marketplace update "$mp" || die "could not refresh the marketplace $mp"
  if [ "$re" -eq 1 ]; then
    claude plugin uninstall "$PLUGIN@$mp" || die "could not uninstall $PLUGIN@$mp; $PLUGIN $before is still installed"
    claude plugin install "$PLUGIN@$mp" || die "the reinstall failed: install it with: claude plugin install $PLUGIN@$mp"
  else
    claude plugin update "$PLUGIN@$mp" || die "the plugin update failed; $PLUGIN $before is still installed"
  fi
  if [ -n "$(json "j['plugins'].get('status-hud@$mp')" "$CFG/plugins/installed_plugins.json")" ]; then
    claude plugin update "status-hud@$mp" || echo "kit-update: the status HUD did not update; it keeps working as it was" >&2
    sync_hud "$mp"
  fi
  after="$(installed version)"
  if [ "$re" -eq 1 ]; then echo "==> $PLUGIN $after reinstalled from $mp. Restart open sessions to use it."
  elif [ "$after" = "$before" ]; then echo "==> $PLUGIN $after: already the newest."
  else echo "==> $PLUGIN $before -> $after. Restart open sessions to use it; the old version stays installed until then."; fi
  cmd_projects "$dir"
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  run) shift; cmd_run "$@" ;;
  projects) shift; [ "${1:-}" = "--projects" ] && { cmd_projects "${2:?--projects needs a folder}"; exit; }; cmd_projects "$(projects_dir)" ;;
  refresh) shift; cmd_refresh "$@" ;;
  *) usage ;;
esac
