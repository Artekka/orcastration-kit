#!/usr/bin/env bash
# kit-word.sh — your own word for starting the kit (orchestration-kit). kit-init asks for it.
#
# Typing the word opens the project picker (kit-launch.sh): pick a project and its team starts, or
# the kit is offered when the project does not have it yet. The word is a shell function in a marked
# block at the end of your shell's rc file, so remove takes out exactly what install put in.
#
# Usage:
#   kit-word.sh install <word> [--projects DIR] [--rc FILE] [--replace]
#   kit-word.sh remove [--rc FILE]
#   kit-word.sh show [--rc FILE]
#   <word>        lowercase letters, digits, - or _, starting with a letter (e.g. team, go, crew)
#   --projects    the folder your projects live in (saved in launcher.conf)
#   --rc          default ~/.zshrc when your shell is zsh, else ~/.bashrc
#   --replace     take the word even when it already names a command, alias or function
#                 (the block goes at the end of the rc file, so it wins over earlier definitions)
# The word calls ${KIT_STATE_DIR:-~/.orchestration-kit}/bin/kit-launch, which finds the installed
# kit each time (`claude plugin list --json`), so kit updates need no re-install.
# Exit 0 done, 1 refused (the word is taken), 64 usage.
set -uo pipefail

STATE="${KIT_STATE_DIR:-$HOME/.orchestration-kit}"
BEGIN="# >>> orchestration-kit word >>>"
END="# <<< orchestration-kit word <<<"
usage() { sed -n '8,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
word=""; projects=""; rc=""; replace=0
while [ $# -gt 0 ]; do
  case "$1" in
    --projects) projects="${2:?--projects needs a folder}"; shift ;;
    --rc) rc="${2:?--rc needs a file}"; shift ;;
    --replace) replace=1 ;;
    -*) usage ;;
    *) [ -z "$word" ] || usage; word="$1" ;;
  esac
  shift
done
if [ -z "$rc" ]; then case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc" ;; *) rc="$HOME/.bashrc" ;; esac; fi

strip_block() { [ -f "$rc" ] || return 0; awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$rc"; }
current_word() { [ -f "$rc" ] && awk -v b="$BEGIN" -v e="$END" '$0==b{inb=1;next} $0==e{inb=0} inb && /^[a-z][a-z0-9_-]*\(\)/{sub(/\(\).*/,""); print; exit}' "$rc"; }

set_conf() {  # <key> <value>: replace or add one line of launcher.conf
  local f="$STATE/launcher.conf"
  mkdir -p "$STATE"; touch "$f"
  { grep -v "^[[:space:]]*$1[[:space:]]*=" "$f"; printf '%s=%s\n' "$1" "$2"; } > "$f.tmp" && mv "$f.tmp" "$f"
}

write_shim() {
  mkdir -p "$STATE/bin"
  cat > "$STATE/bin/kit-launch" <<'SHIM'
#!/usr/bin/env bash
# Written by orchestration-kit's kit-word.sh: find the installed kit (a folder install is read live
# from its folder), then run its project picker. Re-run `kit-word.sh install` to rewrite this file.
root="$(claude plugin list --json 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    if p.get("id", "").startswith("orchestration-kit@") and p.get("enabled", True):
        print(p.get("readFromFolder") or p.get("installPath") or ""); break
' 2>/dev/null)"
[ -n "$root" ] && [ -f "$root/scripts/kit-launch.sh" ] || root="$(cat "$(dirname "$0")/kit-root" 2>/dev/null)"
[ -f "$root/scripts/kit-launch.sh" ] || { echo "kit-launch: cannot find the orchestration kit (is the plugin installed? claude plugin list)" >&2; exit 1; }
exec bash "$root/scripts/kit-launch.sh" "$@"
SHIM
  chmod +x "$STATE/bin/kit-launch"
  # The fallback when `claude plugin list` cannot answer: the kit this script ran from.
  (cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd) > "$STATE/bin/kit-root"
}

case "$cmd" in
  install)
    [[ "$word" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "the word must be lowercase letters, digits, - or _, starting with a letter: '$word'" >&2; exit 64; }
    if [ "$replace" -eq 0 ] && [ "$(current_word)" != "$word" ]; then
      # Is it taken? Ask an interactive shell (rc files stop early otherwise) that has read the rc file
      # without our block; PATH commands, builtins and keywords count too.
      tmp_rc="$(mktemp)"; strip_block > "$tmp_rc"
      taken="$(bash --norc --noprofile -i -c ". $(printf '%q' "$tmp_rc") >/dev/null 2>&1 </dev/null; type -t $(printf '%q' "$word")" 2>/dev/null </dev/null | tail -1)"
      rm -f "$tmp_rc"
      if [ -n "$taken" ]; then
        echo "'$word' already names a $taken on this machine. Pick another word, or take it over with --replace." >&2
        exit 1
      fi
    fi
    write_shim
    set_conf word "$word"
    [ -z "$projects" ] || set_conf projects_dir "$projects"
    { strip_block; printf '%s\n%s() { bash "%s" "$@"; }\n%s\n' "$BEGIN" "$word" "$STATE/bin/kit-launch" "$END"; } > "$rc.kit-tmp"
    cat "$rc.kit-tmp" > "$rc" && rm -f "$rc.kit-tmp"   # cat keeps the rc file's own permissions and links
    echo "Installed: type '$word' in a new terminal (or run: source $rc) to pick a project."
    ;;
  remove)
    [ -n "$(current_word)" ] || { echo "No kit word in $rc."; exit 0; }
    strip_block > "$rc.kit-tmp" && cat "$rc.kit-tmp" > "$rc" && rm -f "$rc.kit-tmp"
    echo "Removed the kit word from $rc (open a new terminal for it to go)."
    ;;
  show)
    w="$(current_word)"
    if [ -n "$w" ]; then echo "word: $w   (in $rc)"; else echo "word: none set in $rc"; fi
    [ ! -f "$STATE/launcher.conf" ] || sed 's/^/  /' "$STATE/launcher.conf"
    ;;
  *) usage ;;
esac
