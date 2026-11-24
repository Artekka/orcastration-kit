#!/usr/bin/env bash
# Start (or reach) the tmux session that holds the agent sessions, optionally open the seat's window, then attach.
# Ported from a project that has run it daily. It is the user's entry point; the tmux backends of
# lib-launch.sh / recycle-sibling.sh use the same session name rule for every new window, so a repo has ONE session.
#
#   scripts/tmux-session.sh [--session NAME] [--seat NAME --model M [--effort E] [--prompt P]] [--no-attach]
#   scripts/tmux-session.sh --install-command CMD [--session NAME] [--seat NAME --model M [--effort E] [--prompt P]]
#
#   (no flags)            create the session if absent (detached, with scripts/tmux/agents.tmux.conf), then attach
#                         (switch-client when already inside tmux)
#   --session NAME        the session name; default RECYCLE_TMUX_SESSION, else the main checkout's directory name (REPO_DIR
#                         overrides the checkout) with every character outside [A-Za-z0-9_-] made `_`. The rule is
#                         lib-launch.sh launch_tmux_session, the one function every tmux window of the kit is named by.
#                         No project name is baked in.
#   --seat NAME           also open a window NAME running `sibling-shell.sh NAME --model M [--effort E]` (the respawn
#                         loop, so recycle-sibling.sh can recycle it in place). The model is always explicit (exit 64).
#                         --prompt P is the session's first prompt (default /orient). After a reboot:
#                           scripts/tmux-session.sh --seat Orca --model 'opus[1m]' --prompt 'Orient and orchestrate'
#                         A window already named NAME is left alone.
#   --no-attach           set everything up and stop (used by tests and over SSH); prints the attach command.
#                         --session names only THIS script's session: if you also launch from outside tmux, use
#                         RECYCLE_TMUX_SESSION, not --session, so every launcher agrees on one name.
#   --install-command CMD writes an executable $HOME/.local/bin/CMD that runs THIS checkout's tmux-session.sh with the
#                         other arguments given here (extra arguments typed after CMD are appended). Nothing is baked in
#                         but those arguments. Idempotent: rewriting a launcher this script wrote is fine; any other file
#                         at that path is refused (exit 65). Warns when $HOME/.local/bin is not on PATH. Example, so a
#                         reboot costs two words (`wsl`, then `orca`):
#                           scripts/tmux-session.sh --install-command orca --seat Orca --model 'opus[1m]' --prompt 'Orient and orchestrate'
#                         The installed command: session exists -> attach (switch-client inside tmux), never a second seat
#                         window; absent -> create it with the seat as its first window, then attach. Works from any cwd.
#   --install-windows     (only with --install-command; WSL only, else exit 69) ALSO makes `CMD` work from Windows: writes
#                         CMD.cmd (`wsl.exe -d <this distro> -e bash -lc "<the launcher above>" %*`) into %USERPROFILE%\bin and a
#                         Windows Terminal FRAGMENT profile (Fragments/<session>/CMD.json; settings.json is never edited).
#                         If that bin dir is not on the Windows USER Path it prints the one PowerShell line that adds it and
#                         changes nothing. --windows-distro current|default: `current` (the default) bakes this distro's name
#                         (WSL_DISTRO_NAME, unquoted, [A-Za-z0-9._-] only) as `wsl.exe -d <name>`; `default` leaves -d out so
#                         Windows picks its default distro. No config file is read here; a kit config would hold this key.
#                         --windows-bin-dir DIR / --windows-fragments-dir DIR (WSL paths) override the
#                         defaults. Same marker rule: a foreign CMD.cmd or fragment is refused (exit 65) before anything is
#                         written. Neither flag is baked into the launcher.
# No tmux installed: with --seat the seat runs directly in the current terminal (cd to the checkout first), so the same
# command works from a plain Windows Terminal tab; without --seat there is nothing to run (exit 69).
# Env: RECYCLE_TMUX (the tmux binary; a test stand-in), RECYCLE_TMUX_SESSION; test stand-ins for --install-windows:
# RECYCLE_CMD_EXE, RECYCLE_WSLPATH, RECYCLE_POWERSHELL, RECYCLE_WSL_INTEROP (the file whose presence means "this is WSL"),
# RECYCLE_WIN_SYSTEM32 (where the cmd.exe / powershell.exe fallbacks live; default /mnt/c/Windows/System32).
# tmux does not survive a WSL VM kill or a host reboot; run this again afterwards and recycle the sessions.
set -euo pipefail

usage() { echo "usage: scripts/tmux-session.sh [--session NAME] [--seat NAME --model M [--effort E] [--prompt P]] [--no-attach]" >&2; }
session="" seat="" model="" effort="" prompt="" attach=1 install=""
install_windows=0 win_bin_dir="" win_frag_dir="" win_distro="" distro_arg=""
baked=()   # the arguments --install-command writes into the launcher (never --no-attach: the launcher attaches)
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ $# -ge 2 ] || { usage; exit 64; }; session="$2"; baked+=("$1" "$2"); shift 2 ;;
    --seat) [ $# -ge 2 ] || { usage; exit 64; }; seat="$2"; baked+=("$1" "$2"); shift 2 ;;
    --model) [ $# -ge 2 ] || { usage; exit 64; }; model="$2"; baked+=("$1" "$2"); shift 2 ;;
    --effort) [ $# -ge 2 ] || { usage; exit 64; }; effort="$2"; baked+=("$1" "$2"); shift 2 ;;
    --prompt) [ $# -ge 2 ] || { usage; exit 64; }; prompt="$2"; baked+=("$1" "$2"); shift 2 ;;
    --install-command) [ $# -ge 2 ] || { usage; exit 64; }; install="$2"; shift 2 ;;
    --install-windows) install_windows=1; shift ;;
    --windows-bin-dir) [ $# -ge 2 ] || { usage; exit 64; }; win_bin_dir="$2"; shift 2 ;;
    --windows-fragments-dir) [ $# -ge 2 ] || { usage; exit 64; }; win_frag_dir="$2"; shift 2 ;;
    --windows-distro) [ $# -ge 2 ] || { usage; exit 64; }; win_distro="$2"
      case "$win_distro" in current|default) ;; *) echo "--windows-distro must be 'current' or 'default'; got '$win_distro'" >&2; exit 64 ;; esac; shift 2 ;;
    --no-attach) attach=0; shift ;;
    *) echo "unknown argument '$1'" >&2; usage; exit 64 ;;
  esac
done
if [ -n "$seat" ]; then
  [[ "$seat" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || { echo "--seat name must match ^[A-Za-z][A-Za-z0-9_-]{0,31}\$; got '$seat'" >&2; exit 64; }
  [[ "$model" =~ ^[a-z][a-z0-9.-]*(\[1m\])?$ ]] || { echo "--seat needs an explicit --model (opus[1m], sonnet[1m], haiku or a full id); got '$model'" >&2; exit 64; }
  case "$effort" in ''|low|medium|high|xhigh|max) ;; *) echo "--effort must be one of low|medium|high|xhigh|max; got '$effort'" >&2; exit 64 ;; esac
fi

if [ -z "$install" ] && { [ "$install_windows" = 1 ] || [ -n "$win_bin_dir" ] || [ -n "$win_frag_dir" ] || [ -n "$win_distro" ]; }; then
  echo "--install-windows and --windows-* only work together with --install-command" >&2; exit 64
fi
if [ "$install_windows" = 0 ] && { [ -n "$win_bin_dir" ] || [ -n "$win_frag_dir" ] || [ -n "$win_distro" ]; }; then
  echo "--windows-bin-dir, --windows-fragments-dir and --windows-distro only work together with --install-windows" >&2; exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
# The MAIN checkout (the dir holding the shared .git), the same rule as recycle-sibling.sh. REPO_DIR wins, as it does in
# lib-launch.sh launch_repo.
git_common=$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR" ]; then checkout="$REPO_DIR"
elif [ -n "$git_common" ] && [ "$(basename "$git_common")" = .git ]; then checkout="$(dirname "$git_common")"
else checkout=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || dirname "$script_dir"); fi
# The default name comes from lib-launch.sh launch_tmux_session (RECYCLE_TMUX_SESSION, else the checkout's directory name),
# the function the tmux backends of start-team / recycle-sibling use for every new window, so a repo has ONE session.
# shellcheck source=lib-launch.sh
. "$script_dir/lib-launch.sh"
[ -n "$session" ] || session="$(LAUNCH_REPO="$checkout" launch_tmux_session)"
[ -n "$session" ] || session=agents
if [ -n "$install" ]; then
  [[ "$install" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || { echo "--install-command name must match ^[A-Za-z][A-Za-z0-9_-]{0,31}\$; got '$install'" >&2; exit 64; }
  bin_dir="$HOME/.local/bin"
  target="$bin_dir/$install"
  marker="# tmux-session.sh launcher (generated; reinstall with --install-command, do not edit)"
  if [ -e "$target" ] && ! grep -qxF -- "$marker" "$target" 2>/dev/null; then
    echo "refusing to overwrite $target: it was not written by tmux-session.sh --install-command" >&2
    exit 65
  fi
  # Bake the MAIN checkout's copy (the dir holding the shared .git), not the worktree this one runs from: a launcher that
  # points into .worktrees/<x> dies when that worktree is pruned (READ LOW-2). No main copy yet (an unmerged branch) = this one.
  baked_script="$script_dir/tmux-session.sh"
  main_git=$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$main_git" ] && [ "$(basename "$main_git")" = .git ] && [ -f "$(dirname "$main_git")/scripts/tmux-session.sh" ]; then
    baked_script="$(dirname "$main_git")/scripts/tmux-session.sh"
  fi
  gen_marker="tmux-session.sh launcher (generated"
  if [ "$install_windows" = 1 ]; then
    # Everything Windows is resolved and checked BEFORE the first write, so a refusal leaves no half install.
    interop="${RECYCLE_WSL_INTEROP:-/proc/sys/fs/binfmt_misc/WSLInterop}"
    cmd_exe="${RECYCLE_CMD_EXE:-cmd.exe}" wslpath_bin="${RECYCLE_WSLPATH:-wslpath}" ps_bin="${RECYCLE_POWERSHELL:-powershell.exe}"
    if [ ! -e "$interop" ] || ! command -v "$wslpath_bin" >/dev/null 2>&1; then
      echo "--install-windows needs WSL (no $interop, or no wslpath); nothing was written" >&2; exit 69
    fi
    # A WSL shell with appendWindowsPath off has no cmd.exe / powershell.exe on PATH; the System32 copies are always there
    # (RECYCLE_WIN_SYSTEM32 is the test seam for that directory).
    sys32="${RECYCLE_WIN_SYSTEM32:-/mnt/c/Windows/System32}"
    if [ -z "${RECYCLE_CMD_EXE:-}" ] && ! command -v cmd.exe >/dev/null 2>&1; then cmd_exe="$sys32/cmd.exe"; fi
    if [ -z "${RECYCLE_POWERSHELL:-}" ] && ! command -v powershell.exe >/dev/null 2>&1; then ps_bin="$sys32/WindowsPowerShell/v1.0/powershell.exe"; fi
    winvar() { "$cmd_exe" /c "echo %$1%" 2>/dev/null | tr -d '\r' || true; }
    userprofile=$(winvar USERPROFILE) localappdata=$(winvar LOCALAPPDATA)
    case "$userprofile$localappdata" in ''|*'%'*) echo "could not read %USERPROFILE% / %LOCALAPPDATA% through $cmd_exe; nothing was written" >&2; exit 69 ;; esac
    if [ -n "$win_bin_dir" ]; then win_bin_w=$("$wslpath_bin" -w "$win_bin_dir"); else
      win_bin_w="$userprofile\\bin"; win_bin_dir=$("$wslpath_bin" -u "$win_bin_w"); fi
    [ -n "$win_frag_dir" ] || win_frag_dir=$("$wslpath_bin" -u "$localappdata\\Microsoft\\Windows Terminal\\Fragments")
    # The distro goes in UNQUOTED: wsl.exe keeps literal quote characters in `-d "Name"` (WSL_E_DISTRO_NOT_FOUND), so a name
    # that would need quoting is refused instead. `--windows-distro default` leaves -d out (the Windows default distro).
    if [ "${win_distro:-current}" = current ] && [ -n "${WSL_DISTRO_NAME:-}" ]; then
      [[ "$WSL_DISTRO_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "WSL_DISTRO_NAME '$WSL_DISTRO_NAME' has characters outside [A-Za-z0-9._-], which wsl.exe -d cannot take unquoted; use --windows-distro default. Nothing was written" >&2; exit 64; }
      distro_arg=" -d $WSL_DISTRO_NAME"
    fi
    cmd_file="$win_bin_dir/$install.cmd"
    frag_file="$win_frag_dir/$session/$install.json"
    cmd_marker_line="@REM $gen_marker; reinstall with --install-command, do not edit)"
    frag_marker_line="  \"_generated\": \"$gen_marker; reinstall with --install-command, do not edit)\","
    for f in "$cmd_file" "$frag_file"; do
      # Exact-line match (CRs stripped), like the WSL launcher's: a file that merely mentions the marker is not ours.
      want_line="$cmd_marker_line"; [ "$f" != "$frag_file" ] || want_line="$frag_marker_line"
      if [ -e "$f" ] && ! { tr -d '\r' < "$f" | grep -qxF -- "$want_line"; } 2>/dev/null; then
        echo "refusing to overwrite $f: it was not written by tmux-session.sh --install-command; nothing was written" >&2; exit 65
      fi
    done
  fi
  mkdir -p "$bin_dir"
  tmp="$target.tmp.$$"
  {
    printf '#!/usr/bin/env bash\n%s\n' "$marker"
    printf 'exec bash %q' "$baked_script"
    for a in "${baked[@]}"; do printf ' %q' "$a"; done
    printf ' "$@"\n'
  } > "$tmp"
  chmod +x "$tmp"
  mv -f -- "$tmp" "$target"
  echo "installed $target"
  case ":$PATH:" in *":$bin_dir:"*) ;; *) echo "WARNING: $bin_dir is not on PATH; add it (for example in ~/.profile) or type $target" >&2 ;; esac
  if [ "$install_windows" = 1 ]; then
    # The launcher's absolute path is the one just written above (same $target), so the .cmd and the WSL file never drift.
    # bash -lc '"$0" "$@"' <launcher> <typed words>: wsl.exe -e passes argv straight through, and the login shell runs the
    # launcher with the words as its arguments. The launcher is $0 (one word), so a HOME with a space needs no quoting inside
    # the -c string. The inner quotes are backslash-escaped for the Windows argv parser.
    inner='"\"$0\" \"$@\""'
    wsl_line="wsl.exe${distro_arg} -e bash -lc $inner \"$target\""
    mkdir -p "$win_bin_dir" "$win_frag_dir/$session"
    printf '%s\r\n@%s %%*\r\n' "$cmd_marker_line" "$wsl_line" > "$cmd_file"
    jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
    h=$(printf 'tmux-session:%s:%s' "$session" "$install" | md5sum | cut -c1-32)
    guid="{${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}}"
    printf '{\n%s\n  "profiles": [\n    {\n      "name": "%s",\n      "guid": "%s",\n      "commandline": "%s"\n    }\n  ]\n}\n' \
      "$frag_marker_line" "$(jesc "${seat:-$install}")" "$guid" "$(jesc "$wsl_line")" > "$frag_file"
    echo "installed $cmd_file and $frag_file"
    user_path=$("$ps_bin" -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','User')" 2>/dev/null | tr -d '\r' || true)
    on_path=0
    IFS=';' read -ra entries <<< "$user_path"
    want="${win_bin_w%\\}"
    for e in "${entries[@]}"; do
      e="${e%\\}"; [ "${e,,}" != "${want,,}" ] || on_path=1
    done
    if [ "$on_path" = 0 ]; then
      echo "$win_bin_w is not on the Windows user Path, so typing $install in cmd/PowerShell will not find it. To add it (run in PowerShell; this script did NOT change it):"
      echo "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$win_bin_w', 'User')"
    fi
    echo "Windows Terminal: reopen it; profile '${seat:-$install}' appears in the dropdown (fragment, works without the Path step)."
    exit 0
  fi
  echo "Windows Terminal profile command line (optional, one click): wsl.exe -e bash -lc $install"
  exit 0
fi
conf="$script_dir/tmux/agents.tmux.conf"
tmux_bin="${RECYCLE_TMUX:-tmux}"
if ! command -v "$tmux_bin" >/dev/null 2>&1; then
  # No tmux (a plain Windows Terminal tab, a box without it): the seat still starts, directly in THIS terminal and from the
  # checkout, under the same respawn wrapper, so `orca` works everywhere. Nothing to run without a seat.
  [ -n "$seat" ] || { echo "tmux is not installed (looked for '$tmux_bin') and no --seat was given, so there is nothing to run" >&2; exit 69; }
  echo "tmux is not installed (looked for '$tmux_bin'): running the seat directly in this terminal" >&2
  cd "$checkout"
  seat_argv=("$script_dir/sibling-shell.sh" "$seat" --model "$model")
  [ -z "$effort" ] || seat_argv+=(--effort "$effort")
  [ -z "$prompt" ] || seat_argv+=("$prompt")
  exec bash "${seat_argv[@]}"
fi

seat_cmd=""
[ -z "$seat" ] || seat_cmd="bash $(printf '%q' "$script_dir/sibling-shell.sh") ${seat} --model $(printf '%q' "$model")${effort:+ --effort $effort}${prompt:+ $(printf '%q' "$prompt")}"
seat_started=0
if ! "$tmux_bin" has-session -t "=${session}" 2>/dev/null; then
  # -f only applies when this starts the server; a running server is covered by the source-file below.
  if [ -n "$seat" ]; then
    # The seat is the session's FIRST window, so a fresh session has no stray empty shell beside it.
    "$tmux_bin" -f "$conf" new-session -d -s "$session" -n "$seat" -c "$checkout" -- bash -lc "$seat_cmd"
    seat_started=1
  else
    "$tmux_bin" -f "$conf" new-session -d -s "$session" -c "$checkout"
  fi
fi
"$tmux_bin" source-file "$conf" >/dev/null 2>&1 || true

if [ -n "$seat" ] && [ "$seat_started" = 0 ]; then
  if "$tmux_bin" list-windows -t "=${session}" -F '#{window_name}' 2>/dev/null | grep -qxF -- "$seat"; then
    echo "window '${seat}' already exists in session '${session}'; left alone" >&2
  else
    "$tmux_bin" new-window -d -t "=${session}:" -n "$seat" -c "$checkout" -- bash -lc "$seat_cmd"
  fi
fi

[ "$attach" = 1 ] || { echo "session '${session}' is ready (checkout ${checkout}); attach with: tmux attach -t ${session}"; exit 0; }
if [ -n "${TMUX:-}" ]; then exec "$tmux_bin" switch-client -t "=${session}"; fi
exec "$tmux_bin" attach-session -t "=${session}"
