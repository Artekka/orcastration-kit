# shellcheck shell=bash
# lib-launch.sh — shared launcher for start-team.sh and recycle-sibling.sh (orchestration-kit).
# Sourced, never run. One copy of the launch logic so the two scripts can't drift.
# Written for bash 3.2+ (macOS /bin/bash): no associative arrays, no ${x,,}, no empty-array expansion.
#
# Opens a NEW terminal window (or tmux window) running, in the repo's main checkout:
#     cd <repo> && [. ~/.nvm/nvm.sh &&] claude --name <Name> [mode flags] --model <M> [--effort <E>] <prompt>
# The backend is picked per machine. Precedence: --terminal flag > `terminal:` in the team block
# of docs/orchestration/ORCHESTRATION.md > auto-detect, in this order:
#
#   tmux            $TMUX set (inside tmux)     tmux new-window -d -n <Name> -c <repo> 'bash -lc ...'
#                   (first, even on WSL or a desktop: the user chose tmux)
#   wsl-wt          WSL + wt.exe found          wt.exe new-tab -> wsl.exe -> bash -lc (conhost fallback)
#   wsl-conhost     WSL, no wt.exe              powershell Start-Process conhost.exe -> wsl.exe
#   tmux-detached   over SSH ($SSH_CONNECTION/$SSH_TTY), tmux installed — checked before any GUI
#   macos-iterm     macOS + ($TERM_PROGRAM=iTerm.app or iTerm2 running)   osascript: new window, write text
#   macos-terminal  macOS otherwise             osascript: Terminal `do script`
#   gitbash-cmd     Git Bash / MSYS ($MSYSTEM) + cmd.exe   cmd.exe /c start ... cmd.exe /k "..."
#   linux-<emu>     Linux + $DISPLAY/$WAYLAND_DISPLAY; first of $TERMINAL, x-terminal-emulator,
#                   gnome-terminal, konsole, xfce4-terminal, kitty, alacritty, wezterm, foot, xterm
#   tmux-detached   no GUI, tmux installed      detached session named after the repo (new-window each)
#   manual          nothing usable              print the per-window commands; the scripts exit 2
#
# Quoting: one function per backend family (_launch_q_wsl / _launch_q_posix / _launch_q_cmd;
# macOS passes the command to osascript as argv, so AppleScript never parses it).
#   * WSL only: wt.exe splits its own subcommands on `;`, and embedded `"` / `'` cross Windows argv
#     and PowerShell quoting badly — the WSL command line must contain none of them.
#   * WSL only: wsl.exe stays BARE inside the wt.exe / conhost command line — Windows resolves it
#     there; the /mnt/c/Windows/System32/wsl.exe form can return rc 0 and spawn nothing.
#     wt.exe / cmd.exe / powershell.exe are called by FULL path: the shell's PATH may lack them.
#   * Global: names are [A-Za-z0-9_-], prompts letters/digits/space and / . _ : , @ = + -.
#   * `bash -lc` is non-interactive, so ~/.bashrc usually returns before loading nvm; if nvm is
#     installed it is sourced explicitly, or the new session has no node on PATH. macOS windows
#     type the command into the user's own interactive login shell instead (zsh or bash).
#
# Sessions are identified by `pgrep -f "^claude --name <Name>( |$)"` — they MUST be started
# with the long flag, first. The same extended regex works with procps pgrep (Linux) and BSD
# pgrep (macOS). Git Bash has no pgrep: launches there are reported unverified, and
# recycle-sibling.sh never SIGTERMs what it cannot see.
#
# Test hook (tests only, never in docs for users): LAUNCH_CMD_OVERRIDE replaces the
# `claude --name ...` part (`{name}` is substituted); the pgrep pattern then matches it instead.

LAUNCH_NAME_RE='^[A-Za-z0-9_-]+$'
LAUNCH_PROMPT_RE='^[A-Za-z0-9 /._:,@=+-]*$'
LAUNCH_EMULATORS="gnome-terminal konsole xfce4-terminal kitty alacritty wezterm foot xterm"

# Permission modes (claude --help, v2.1.x). Every mode keeps Claude Code's permission checks:
# normal = no flag (asks before risky actions), accept-edits = --permission-mode acceptEdits
# (file edits auto-approved, commands still ask), auto = --permission-mode auto.
LAUNCH_MODE="${LAUNCH_MODE:-normal}"
launch_valid_mode() { case "$1" in normal|accept-edits|auto) return 0 ;; *) return 1 ;; esac; }
launch_mode_flags() {
  case "$1" in
    accept-edits) printf -- '--permission-mode acceptEdits ' ;;
    auto) printf -- '--permission-mode auto ' ;;
    *) printf '' ;;
  esac
}
# Model and effort (docs/GETTING-STARTED.md "Model per lane"). The lane decides the model, so --model
# is ALWAYS passed explicitly: a fresh session must never silently inherit whatever the old terminal,
# the account default or the last `/model` happened to be. A recycle does NOT read the old session's
# model either (unlike its account, which is inherited on purpose: that is where the login lives).
# Default, first found: --model flag > (the seat only) `seat_model:` in the team block > `model:` in the team
# block of ORCHESTRATION.md > LAUNCH_DEFAULT_MODEL (below). `seat_model:` lets the seat sit a tier above or below
# its lanes without a flag on every seat launch and recycle; the lanes still get the model the seat picks. --effort is passed only when given (flag > team block `effort:`), else the CLI's own default.
# Validated before anything launches: a malformed model or unknown effort is refused, exit 64, whether it
# came from a flag, an EMPTY flag value, or the team block (a bad block value is refused too: warning and
# quietly launching on the default is the silent-wrong-model failure this block exists to prevent).
LAUNCH_DEFAULT_MODEL="opus[1m]"   # the seat and the top-tier lanes; an alias, so it tracks the newest opus
# Must START with a letter: a leading `-` is a flag (`--model --dangerously-skip-permissions` would hand
# claude a second flag) and a leading `.` is no model id. Lowercase letters, digits, `.` and `-` only.
LAUNCH_MODEL_RE='^[a-z][a-z0-9.-]*(\[1m\])?$'   # opus[1m] | sonnet[1m] | haiku | fable | a full model id
LAUNCH_MODEL="$LAUNCH_DEFAULT_MODEL"; LAUNCH_MODEL_SRC="default"
LAUNCH_EFFORT=""; LAUNCH_EFFORT_SRC=""
launch_valid_model()  { [[ "$1" =~ $LAUNCH_MODEL_RE ]]; }
launch_valid_effort() { case "$1" in low|medium|high|xhigh|max) return 0 ;; *) return 1 ;; esac; }
launch_set_model() {  # <model> <source label>
  launch_valid_model "$1" || {
    echo "--model must look like opus[1m], sonnet[1m], haiku, fable or a full model id (lowercase letters, digits . -): '$1'" >&2; exit 64; }
  LAUNCH_MODEL="$1"; LAUNCH_MODEL_SRC="${2:---model}"
}
launch_set_effort() {  # <effort> <source label>
  launch_valid_effort "$1" || { echo "--effort must be one of low|medium|high|xhigh|max: '$1'" >&2; exit 64; }
  LAUNCH_EFFORT="$1"; LAUNCH_EFFORT_SRC="${2:---effort}"
}
launch_model_flags() {  # <quote-fn> — `--model M ` plus `--effort E ` when given
  printf -- '--model %s ' "$("$1" "$LAUNCH_MODEL")"
  if [ -n "$LAUNCH_EFFORT" ]; then printf -- '--effort %s ' "$LAUNCH_EFFORT"; fi
}
# Accounts (optional; docs/MULTI-ACCOUNT.md). Each Claude Code account keeps its login and config in
# its own directory, chosen by CLAUDE_CONFIG_DIR (unset = the default ~/.claude). Convention: account
# N>1 lives in ~/.claude-acctN. LAUNCH_ACCOUNT_DIR empty = the default account, and no prefix is added.
# The prefix is an environment assignment, not argv, so the pgrep pattern below is unaffected.
LAUNCH_ACCOUNT_DIR="${LAUNCH_ACCOUNT_DIR:-}"
launch_account_dir_for() {  # <N|dir|''> -> config dir ('' = default account)
  case "$1" in
    ''|1) printf '' ;;
    *[!0-9]*) printf '%s' "$1" ;;
    *) printf '%s' "$HOME/.claude-acct$1" ;;
  esac
}
# The account a RUNNING session uses: its CLAUDE_CONFIG_DIR ('' = default or unreadable).
launch_account_of_pid() {  # <pid>
  if [ -r "/proc/$1/environ" ]; then
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1
  elif [ "$(uname -s)" = Darwin ]; then
    ps eww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1
  fi
}
launch_set_account() {  # <N|dir|''>
  LAUNCH_ACCOUNT_DIR="$(launch_account_dir_for "$1")"
  [ -n "$LAUNCH_ACCOUNT_DIR" ] || return 0
  case "$LAUNCH_ACCOUNT_DIR" in *[\;\"\'\ %^\&\|\<\>]*)
    echo "account dir must not contain spaces or ; \" ' % ^ & | < > : $LAUNCH_ACCOUNT_DIR" >&2; exit 64 ;; esac
  if [ ! -d "$LAUNCH_ACCOUNT_DIR" ]; then
    echo "account dir $LAUNCH_ACCOUNT_DIR does not exist — set it up first (docs/MULTI-ACCOUNT.md)" >&2; exit 64
  fi
  # Linux/WSL keep the login in .credentials.json; macOS keeps it in the Keychain, so skip the check there.
  if [ "$(uname -s)" != Darwin ] && [ ! -f "$LAUNCH_ACCOUNT_DIR/.credentials.json" ]; then
    echo "account dir $LAUNCH_ACCOUNT_DIR has no login — start Claude Code with it once and /login" >&2; exit 64
  fi
}
# Display name: the first line of an optional ACCOUNT file in the config dir, else the dir itself.
launch_account_label() {
  local d="${LAUNCH_ACCOUNT_DIR:-$HOME/.claude}" l
  l="$(head -1 "$d/ACCOUNT" 2>/dev/null || true)"
  printf '%s' "${l:-$d}"
  if [ -z "$LAUNCH_ACCOUNT_DIR" ]; then printf ' (default account)'; fi
}
_launch_env() {  # <quote-fn> — the CLAUDE_CONFIG_DIR prefix, or nothing for the default account
  [ -n "$LAUNCH_ACCOUNT_DIR" ] || return 0
  if [ "$1" = _launch_q_cmd ]; then
    local w="$LAUNCH_ACCOUNT_DIR"
    if command -v cygpath >/dev/null 2>&1; then w="$(cygpath -w "$w")"; fi
    printf 'set CLAUDE_CONFIG_DIR=%s&& ' "$w"   # cmd.exe: no space before && or it joins the value
  else
    printf 'CLAUDE_CONFIG_DIR=%s ' "$(printf '%q' "$LAUNCH_ACCOUNT_DIR")"
  fi
}

launch_set_mode() {
  launch_valid_mode "$1" || { echo "--mode must be normal|accept-edits|auto: '$1'" >&2; exit 64; }
  LAUNCH_MODE="$1"
}

launch_valid_name()   { [[ "$1" =~ $LAUNCH_NAME_RE ]]; }
launch_valid_prompt() { [[ "$1" =~ $LAUNCH_PROMPT_RE ]]; }

launch_check_args() {  # <name> <prompt> — exit 64 on unsafe input
  launch_valid_name "$1" || { echo "name must match [A-Za-z0-9_-]+ : '$1'" >&2; exit 64; }
  # A `-`-led name or prompt would be read by claude as one of ITS flags (`claude --name N -x`).
  case "$1" in -*) echo "name must not start with '-': '$1'" >&2; exit 64 ;; esac
  case "$2" in -*) echo "prompt must not start with '-' (it would be read as a claude flag): '$2'" >&2; exit 64 ;; esac
  launch_valid_prompt "$2" || {
    echo "prompt may only contain letters, digits, spaces and / . _ : , @ = + -  (no ; \" ' ): '$2'" >&2
    exit 64
  }
}

launch_is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ]; }
_launch_os() { uname -s 2>/dev/null || echo unknown; }

# Main checkout of the current repo (not the current worktree), unless REPO_DIR/--repo set it.
# Path characters are checked per backend (launch_init), not here.
launch_repo() {
  local repo="${1:-${REPO_DIR:-}}" common
  if [ -z "$repo" ]; then
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ] && [ "$(basename "$common")" = ".git" ]; then
      repo="$(dirname "$common")"
    else
      repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
  fi
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    echo "no repo dir: run inside the repo, or pass --repo DIR / set REPO_DIR" >&2; exit 64
  fi
  printf '%s\n' "$repo"
}

# ---------------------------------------------------------------- backend detection

_launch_win() { command -v "$1" 2>/dev/null || echo "$2"; }

_launch_wsl_probe() {  # sets LAUNCH_WT LAUNCH_PS once (WSL only)
  [ -n "${_LAUNCH_WSL_PROBED:-}" ] && return 0
  _LAUNCH_WSL_PROBED=1
  LAUNCH_PS="$(_launch_win powershell.exe /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)"
  local cmd_exe winuser
  cmd_exe="$(_launch_win cmd.exe /mnt/c/Windows/System32/cmd.exe)"
  LAUNCH_WT="${WT_EXE:-}"
  if [ -z "$LAUNCH_WT" ]; then
    # cd /mnt/c first: cmd.exe warns about UNC paths when started from a Linux directory.
    winuser="$( (cd /mnt/c 2>/dev/null; "$cmd_exe" /c "echo %USERNAME%" 2>/dev/null) | tr -d '\r')" || winuser=""
    [ -n "$winuser" ] && LAUNCH_WT="/mnt/c/Users/${winuser}/AppData/Local/Microsoft/WindowsApps/wt.exe"
  fi
  if [ -n "$LAUNCH_WT" ] && [ ! -e "$LAUNCH_WT" ]; then LAUNCH_WT=""; fi
}

_launch_has_gui() { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }
_launch_over_ssh() { [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; }

# Every backend name, in auto-detect priority order (tmux-detached listed once).
launch_backend_names() {
  local e names="tmux wsl-wt wsl-conhost macos-iterm macos-terminal gitbash-cmd"
  if [ -n "${TERMINAL:-}" ]; then names="$names linux-$(basename "${TERMINAL%% *}")"; fi
  names="$names linux-x-terminal-emulator"
  for e in $LAUNCH_EMULATORS; do
    case " $names " in *" linux-$e "*) ;; *) names="$names linux-$e" ;; esac
  done
  # shellcheck disable=SC2086  # word-splitting the space-separated list is the point
  printf '%s\n' $names tmux-detached manual
}

launch_known_backend() {  # <name> — any listed name, or linux-<anything>
  case "$1" in
    wsl-wt|wsl-conhost|tmux|tmux-detached|macos-iterm|macos-terminal|gitbash-cmd|manual) return 0 ;;
    linux-?*) [[ "${1#linux-}" =~ ^[A-Za-z0-9._+-]+$ ]] ;;
    *) return 1 ;;
  esac
}

# Binary for a linux-<emu> backend: $TERMINAL when its basename matches, else <emu> on PATH.
_launch_emu_bin() {  # <emu>
  if [ -n "${TERMINAL:-}" ] && [ "$(basename "${TERMINAL%% *}")" = "$1" ]; then
    command -v "${TERMINAL%% *}" 2>/dev/null && return 0
  fi
  command -v "$1" 2>/dev/null
}

_launch_iterm_running() {
  [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || pgrep -xq iTerm2 2>/dev/null
}

# launch_backend_check <backend> — 0 when usable here; LAUNCH_WHY says why (or why not).
launch_backend_check() {
  local b="$1" os; os="$(_launch_os)"; LAUNCH_WHY=""
  case "$b" in
    wsl-wt)
      launch_is_wsl || { LAUNCH_WHY="not WSL"; return 1; }
      _launch_wsl_probe
      [ -n "$LAUNCH_WT" ] || { LAUNCH_WHY="wt.exe not found (set WT_EXE to its full path)"; return 1; }
      LAUNCH_WHY="WSL (${WSL_DISTRO_NAME}) and wt.exe at $LAUNCH_WT" ;;
    wsl-conhost)
      launch_is_wsl || { LAUNCH_WHY="not WSL"; return 1; }
      _launch_wsl_probe
      [ -e "$LAUNCH_PS" ] || { LAUNCH_WHY="powershell.exe not reachable (WSL interop off?)"; return 1; }
      LAUNCH_WHY="WSL (${WSL_DISTRO_NAME}), plain console windows via powershell.exe" ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || { LAUNCH_WHY="tmux not installed"; return 1; }
      [ -n "${TMUX:-}" ] || { LAUNCH_WHY="not inside tmux (\$TMUX unset)"; return 1; }
      LAUNCH_WHY="running inside tmux (\$TMUX set): new windows in this tmux session" ;;
    tmux-detached)
      command -v tmux >/dev/null 2>&1 || { LAUNCH_WHY="tmux not installed"; return 1; }
      LAUNCH_WHY="tmux installed: windows in a detached session (tmux attach -t $(launch_tmux_session))" ;;
    macos-iterm)
      [ "$os" = Darwin ] || { LAUNCH_WHY="not macOS"; return 1; }
      if _launch_iterm_running; then LAUNCH_WHY="macOS, iTerm2 running"; return 0; fi
      [ -d /Applications/iTerm.app ] || { LAUNCH_WHY="iTerm2 not installed"; return 1; }
      LAUNCH_WHY="macOS, iTerm2 installed (not running now)" ;;
    macos-terminal)
      [ "$os" = Darwin ] || { LAUNCH_WHY="not macOS"; return 1; }
      command -v osascript >/dev/null 2>&1 || { LAUNCH_WHY="osascript not found"; return 1; }
      LAUNCH_WHY="macOS, Terminal.app via osascript" ;;
    gitbash-cmd)
      [ -n "${MSYSTEM:-}" ] || { LAUNCH_WHY="not Git Bash/MSYS (\$MSYSTEM unset)"; return 1; }
      command -v cmd.exe >/dev/null 2>&1 || command -v cmd >/dev/null 2>&1 || { LAUNCH_WHY="cmd.exe not reachable"; return 1; }
      LAUNCH_WHY="Git Bash (\$MSYSTEM=$MSYSTEM): cmd.exe windows; no pgrep, so launches are unverified" ;;
    linux-?*)
      local emu="${b#linux-}" bin
      [ "$os" = Linux ] || { LAUNCH_WHY="not Linux"; return 1; }
      _launch_has_gui || { LAUNCH_WHY="no GUI (\$DISPLAY and \$WAYLAND_DISPLAY unset)"; return 1; }
      bin="$(_launch_emu_bin "$emu")" || { LAUNCH_WHY="$emu not installed"; return 1; }
      LAUNCH_WHY="Linux desktop, $emu at $bin" ;;
    manual) LAUNCH_WHY="always available: prints the commands to run by hand" ;;
    *) LAUNCH_WHY="unknown backend"; return 1 ;;
  esac
  return 0
}

# Auto-detect. Sets LAUNCH_BACKEND LAUNCH_REASON.
launch_detect() {
  local os e; os="$(_launch_os)"
  # tmux first, even on WSL or a desktop: the user chose to work in tmux.
  if launch_backend_check tmux; then LAUNCH_BACKEND=tmux; LAUNCH_REASON="auto: $LAUNCH_WHY"; return; fi
  if launch_is_wsl; then
    if launch_backend_check wsl-wt; then LAUNCH_BACKEND=wsl-wt; LAUNCH_REASON="auto: $LAUNCH_WHY"; return; fi
    LAUNCH_BACKEND=wsl-conhost; LAUNCH_REASON="auto: WSL (${WSL_DISTRO_NAME}), wt.exe not found -> console windows"; return
  fi
  if _launch_over_ssh; then
    if launch_backend_check tmux-detached; then
      LAUNCH_BACKEND=tmux-detached; LAUNCH_REASON="auto: SSH session (GUI windows would open on the remote screen), $LAUNCH_WHY"; return
    fi
    LAUNCH_BACKEND=manual; LAUNCH_REASON="auto: SSH session and tmux not installed"; return
  fi
  if [ "$os" = Darwin ]; then
    if _launch_iterm_running; then LAUNCH_BACKEND=macos-iterm; LAUNCH_REASON="auto: macOS, iTerm2 running"; return; fi
    LAUNCH_BACKEND=macos-terminal; LAUNCH_REASON="auto: macOS, Terminal.app"; return
  fi
  if [ -n "${MSYSTEM:-}" ]; then
    if launch_backend_check gitbash-cmd; then LAUNCH_BACKEND=gitbash-cmd; LAUNCH_REASON="auto: $LAUNCH_WHY"; return; fi
    LAUNCH_BACKEND=manual; LAUNCH_REASON="auto: Git Bash without a reachable cmd.exe"; return
  fi
  if [ "$os" = Linux ] && _launch_has_gui; then
    if [ -n "${TERMINAL:-}" ] && launch_backend_check "linux-$(basename "${TERMINAL%% *}")"; then
      LAUNCH_BACKEND="linux-$(basename "${TERMINAL%% *}")"; LAUNCH_REASON="auto: \$TERMINAL, $LAUNCH_WHY"; return
    fi
    for e in x-terminal-emulator $LAUNCH_EMULATORS; do
      if launch_backend_check "linux-$e"; then LAUNCH_BACKEND="linux-$e"; LAUNCH_REASON="auto: $LAUNCH_WHY"; return; fi
    done
  fi
  if launch_backend_check tmux-detached; then
    LAUNCH_BACKEND=tmux-detached; LAUNCH_REASON="auto: no GUI terminal found, $LAUNCH_WHY"; return
  fi
  LAUNCH_BACKEND=manual; LAUNCH_REASON="auto: no supported terminal found (no WSL, tmux, macOS, Git Bash or Linux GUI emulator)"
}

# --terminal list
launch_list_backends() {
  local b auto
  launch_detect; auto="$LAUNCH_BACKEND"
  printf '%-26s %-10s %s\n' BACKEND AVAILABLE DETAIL
  while IFS= read -r b; do
    if launch_backend_check "$b"; then
      printf '%-26s %-10s %s%s\n' "$b" yes "$LAUNCH_WHY" "$([ "$b" = "$auto" ] && echo '   <- auto-detect picks this')"
    else
      printf '%-26s %-10s %s\n' "$b" no "$LAUNCH_WHY"
    fi
  done < <(launch_backend_names)
  echo "override: --terminal <backend>, or 'terminal: <backend>' in the team: block (auto = detect)"
}

# ---------------------------------------------------------------- init + command building

launch_tmux_session() {  # tmux session name for tmux-detached: the repo's basename, tmux-safe
  local base; base="$(basename "${LAUNCH_REPO:-${REPO:-$PWD}}")"
  printf '%s' "$base" | tr -c 'A-Za-z0-9_-' '_'
}

# launch_init <repo> <terminal-override-or-empty>
# Sets LAUNCH_REPO LAUNCH_NVM LAUNCH_BACKEND LAUNCH_REASON LAUNCH_FORCED LAUNCH_AVAILABLE
# LAUNCH_CAN_VERIFY (+ LAUNCH_DISTRO LAUNCH_WT LAUNCH_PS on WSL). Exit 64 on a bad override.
# shellcheck disable=SC2034  # LAUNCH_FORCED / LAUNCH_AVAILABLE are read by the scripts
launch_init() {
  LAUNCH_REPO="$(launch_repo "${1:-}")" || exit 64
  local want="${2:-}"
  LAUNCH_FORCED=0; LAUNCH_AVAILABLE=1
  if [ -n "$want" ] && [ "$want" != auto ]; then
    launch_known_backend "$want" || {
      echo "unknown terminal backend '$want' — see: scripts/start-team.sh --terminal list" >&2; exit 64; }
    LAUNCH_BACKEND="$want"; LAUNCH_FORCED=1
    if launch_backend_check "$want"; then LAUNCH_REASON="forced: $LAUNCH_WHY"
    else LAUNCH_REASON="forced, but NOT available here: $LAUNCH_WHY"; LAUNCH_AVAILABLE=0; fi
  else
    launch_detect
  fi
  LAUNCH_DISTRO="${WSL_DISTRO_NAME:-}"
  case "$LAUNCH_BACKEND" in wsl-*) _launch_wsl_probe ;; esac
  LAUNCH_NVM=""
  case "$LAUNCH_BACKEND" in
    gitbash-cmd|manual) ;;  # Windows node / the user's own shell
    *) if [ -s "$HOME/.nvm/nvm.sh" ]; then LAUNCH_NVM=". $(printf '%q' "$HOME/.nvm/nvm.sh") && "; fi ;;
  esac
  LAUNCH_CAN_VERIFY=1
  command -v pgrep >/dev/null 2>&1 || LAUNCH_CAN_VERIFY=0
  case "$LAUNCH_BACKEND" in
    wsl-*) case "$LAUNCH_REPO" in *[\;\"\'\ ]*)
      echo "repo path must not contain spaces or ; \" ' on WSL (wt.exe/conhost command lines): $LAUNCH_REPO" >&2; exit 64 ;; esac ;;
  esac
}

# The part identified by pgrep: `claude --name N [flags] prompt` (or the test override).
_launch_core() {  # <name> <prompt> <quote-fn>
  if [ -n "${LAUNCH_CMD_OVERRIDE:-}" ]; then printf '%s%s' "$(_launch_env "$3")" "${LAUNCH_CMD_OVERRIDE//\{name\}/$1}"; return; fi
  if launch_use_wrapper; then
    # The tab runs the respawn wrapper (sibling-shell.sh), which runs `claude --name <Name> ...` as its
    # child: same pgrep pattern, and the next recycle of this session can happen in this very tab.
    local mflag=""
    [ "$LAUNCH_MODE" = normal ] || mflag="--mode $LAUNCH_MODE "
    printf '%sbash %s %s %s%s%s' "$(_launch_env "$3")" "$("$3" "$(launch_wrapper)")" "$1" "$mflag" "$(launch_model_flags "$3")" "$("$3" "$2")"
    return
  fi
  # --name stays FIRST: launch_pattern matches "^claude --name <Name>( |$)".
  printf '%sclaude --name %s %s%s%s' "$(_launch_env "$3")" "$1" "$(launch_mode_flags "$LAUNCH_MODE")" "$(launch_model_flags "$3")" "$("$3" "$2")"
}

# Quoting, one per backend family.
_launch_q_posix() { printf '%q' "$1"; }  # tmux, linux-*, macos-* (a POSIX shell parses it)
_launch_q_wsl() {  # wt.exe / PowerShell: validated, never quoted — ; " ' are refused outright
  case "$1" in *[\;\"\']*) echo "WSL command lines must not contain ; \" ' : $1" >&2; return 64 ;; esac
  printf '%q' "$1"
}
_launch_q_cmd() {  # cmd.exe: the global prompt whitelist already excludes its metacharacters
  case "$1" in *[\"%^\&\|\<\>]*) echo "cmd.exe command lines must not contain \" % ^ & | < > : $1" >&2; return 64 ;; esac
  printf '%s' "$1"
}

# launch_cmd <name> <prompt> — the shell command every POSIX backend runs.
launch_cmd() {
  local q=_launch_q_posix
  case "$LAUNCH_BACKEND" in wsl-*) q=_launch_q_wsl ;; esac
  printf 'cd %s && %s%s' "$(printf '%q' "$LAUNCH_REPO")" "$LAUNCH_NVM" "$(_launch_core "$1" "$2" "$q")"
}

# Git Bash: a cmd.exe command line (Windows path, native Windows claude).
_launch_cmd_line() {
  local win="$LAUNCH_REPO"
  if command -v cygpath >/dev/null 2>&1; then win="$(cygpath -w "$LAUNCH_REPO")"; fi
  printf 'cd /d %s && %s' "$win" "$(_launch_core "$1" "$2" _launch_q_cmd)"
}

launch_pattern() {
  if [ -n "${LAUNCH_CMD_OVERRIDE:-}" ]; then
    printf '^%s( |$)' "$(printf '%s' "${LAUNCH_CMD_OVERRIDE//\{name\}/$1}" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
    return
  fi
  printf '^claude --name %s( |$)' "$1"
}
launch_pids() { [ "${LAUNCH_CAN_VERIFY:-1}" = 1 ] || return 0; pgrep -f "$(launch_pattern "$1")" || true; }

# Fills the global array LAUNCH_ARGV with the argv that opens one window.
_launch_argv() {  # <name> <prompt>
  local name="$1" prompt="$2" cmd emu bin
  case "$LAUNCH_BACKEND" in
    wsl-wt)
      LAUNCH_ARGV=("$LAUNCH_WT" -w 0 new-tab --title "$name" wsl.exe -d "$LAUNCH_DISTRO" --cd "$LAUNCH_REPO" -e bash -lc "$(launch_cmd "$name" "$prompt")") ;;
    wsl-conhost)
      LAUNCH_ARGV=("$LAUNCH_PS" -NoProfile -Command "$(_launch_ps_cmd "$name" "$prompt")") ;;
    tmux)
      LAUNCH_ARGV=(tmux new-window -d -n "$name" -c "$LAUNCH_REPO" "bash -lc $(_launch_q_posix "$(launch_cmd "$name" "$prompt")")") ;;
    tmux-detached)
      LAUNCH_ARGV=(tmux new-window -d -t "$(launch_tmux_session):" -n "$name" -c "$LAUNCH_REPO" "bash -lc $(_launch_q_posix "$(launch_cmd "$name" "$prompt")")") ;;
    macos-iterm)
      LAUNCH_ARGV=(osascript -e 'on run argv' -e 'tell application "iTerm"' -e 'activate'
        -e 'set w to (create window with default profile)' -e 'tell current session of w'
        -e 'set name to (item 2 of argv)' -e 'write text (item 1 of argv)'
        -e 'end tell' -e 'end tell' -e 'end run' "$(launch_cmd "$name" "$prompt")" "$name") ;;
    macos-terminal)
      LAUNCH_ARGV=(osascript -e 'on run argv' -e 'tell application "Terminal"' -e 'activate'
        -e 'set t to do script (item 1 of argv)' -e 'set custom title of t to (item 2 of argv)'
        -e 'end tell' -e 'end run' "$(launch_cmd "$name" "$prompt")" "$name") ;;
    gitbash-cmd)
      # The title arg carries a space so MSYS quotes it — start takes the first QUOTED arg as the title.
      LAUNCH_ARGV=(cmd.exe /c start "claude $name" cmd.exe /k "$(_launch_cmd_line "$name" "$prompt")") ;;
    linux-?*)
      emu="${LAUNCH_BACKEND#linux-}"
      bin="$(_launch_emu_bin "$emu" || echo "$emu")"
      cmd="$(launch_cmd "$name" "$prompt")"
      case "$emu" in
        gnome-terminal) LAUNCH_ARGV=("$bin" --title "$name" -- bash -lc "$cmd") ;;
        konsole)        LAUNCH_ARGV=("$bin" -p "tabtitle=$name" -e bash -lc "$cmd") ;;
        xfce4-terminal) LAUNCH_ARGV=("$bin" --title "$name" -x bash -lc "$cmd") ;;  # -e takes ONE string; -x takes argv
        kitty)          LAUNCH_ARGV=("$bin" --title "$name" bash -lc "$cmd") ;;
        alacritty)      LAUNCH_ARGV=("$bin" --title "$name" -e bash -lc "$cmd") ;;
        wezterm)        LAUNCH_ARGV=("$bin" start --cwd "$LAUNCH_REPO" -- bash -lc "$cmd") ;;
        foot)           LAUNCH_ARGV=("$bin" --title "$name" bash -lc "$cmd") ;;
        xterm)          LAUNCH_ARGV=("$bin" -T "$name" -e bash -lc "$cmd") ;;
        *)              LAUNCH_ARGV=("$bin" -e bash -lc "$cmd") ;;  # x-terminal-emulator / unknown $TERMINAL: -e is the convention
      esac ;;
    *) LAUNCH_ARGV=() ;;
  esac
}

_launch_ps_cmd() {
  printf "Start-Process conhost.exe -ArgumentList 'wsl.exe -d %s --cd %s -e bash -lc \"%s\"'" \
    "$LAUNCH_DISTRO" "$LAUNCH_REPO" "$(launch_cmd "$1" "$2")"
}

_launch_print_argv() { printf '%q' "${LAUNCH_ARGV[0]}"; printf ' %q' "${LAUNCH_ARGV[@]:1}"; echo; }

# ---------------------------------------------------------------- in-place recycle (v0.7.0)

# Every tab the kit opens runs scripts/sibling-shell.sh, a respawn loop around `claude`. A recycle of a
# session that runs under it needs no new tab: recycle-sibling.sh leaves the wrapper a hand-off file
# (model, effort, mode, account, prompt), SIGTERMs only the old claude, and the wrapper starts the fresh
# one in the SAME tab. Anything else (no old process, an old one started by hand, --new-tab, a timeout)
# opens a new tab that runs the wrapper, so a hand-started session moves over at its next recycle.
launch_state_dir() { printf '%s' "${SIBLING_STATE_DIR:-$HOME/.orchestration-kit/sessions}"; }
launch_wrapper() { printf '%s/sibling-shell.sh' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; }

# True when a tab's command should run the wrapper rather than a bare claude. Not for: the test
# override, a missing wrapper, LAUNCH_NO_WRAPPER (an escape hatch), Git Bash (cmd.exe windows run the
# native claude and have no bash to run the wrapper) or the manual backend (a command for a human to
# type). On WSL the wrapper path must also be free of spaces and ; " ' (the wt.exe / conhost line).
launch_use_wrapper() {
  [ -z "${LAUNCH_CMD_OVERRIDE:-}" ] || return 1
  [ -z "${LAUNCH_NO_WRAPPER:-}" ] || return 1
  [ -f "$(launch_wrapper)" ] || return 1
  case "${LAUNCH_BACKEND:-}" in
    gitbash-cmd|manual|"") return 1 ;;
    wsl-*) case "$(launch_wrapper)" in *[\;\"\'\ ]*) return 1 ;; esac ;;
  esac
  return 0
}

# Process facts, from /proc when the kernel has it (exact argv), else from ps (macOS, BSD).
# LAUNCH_NO_PROC=1 forces the ps branch: tests use it to cover macOS on a Linux box.
_launch_use_proc() { [ -z "${LAUNCH_NO_PROC:-}" ] && [ -r "/proc/$1/status" ]; }
launch_ppid_of() {  # <pid>
  if _launch_use_proc "$1"; then awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null || true
  else ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ' || true; fi
}
# The sibling-shell.sh wrapper that is <pid>'s PARENT and was started for <name>, else nothing: the
# Name must match, or a session whose parent is another sibling's wrapper would take its hand-off.
launch_wrapper_pid_of() {  # <pid> <name>
  local par prev="" arg; par="$(launch_ppid_of "$1")"
  [ -n "$par" ] && [ "$par" -gt 1 ] 2>/dev/null || return 0
  if _launch_use_proc "$par" && [ -r "/proc/$par/cmdline" ]; then
    while IFS= read -r arg || [ -n "$arg" ]; do
      if [ "$prev" = sibling-shell.sh ] && [ "$arg" = "$2" ]; then echo "$par"; return 0; fi
      prev="${arg##*/}"
    done < <(tr '\0' '\n' < "/proc/$par/cmdline" 2>/dev/null)
  elif ps -o command= -p "$par" 2>/dev/null | grep -Eq "(^|[ /])sibling-shell\.sh $2( |\$)"; then
    echo "$par"
  fi
  return 0
}
# True iff <pid> is on THIS shell's own parent chain (the seat recycling itself runs the script from
# inside the claude it targets: an in-place SIGTERM would cut the chain the wait loop runs in).
launch_is_ancestor() {  # <pid>
  local anc=$$
  while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null; do
    [ "$anc" != "$1" ] || return 0
    anc="$(launch_ppid_of "$anc")"
  done
  return 1
}

# Live shells under the old session(s): `<pid> <elapsed> <args>` per line, else nothing. A recycle SIGTERMs
# the old claude, and its background shells (a gate run, a loop, a long prune) die with it or run on orphaned
# with nobody to read their result; "retro complete" says the work is committed, not that nothing still runs.
# Shell children (bash/sh/zsh/dash/ksh/fish) are what Claude Code's Bash tool leaves running; MCP servers
# (node, python, npm …) are permanent children and are not counted. A shell that is OUR ancestor is the
# seat's own tool call running this script (a self-recycle), so it is skipped. Subagents run inside the
# claude process and are invisible here: the retro reply has to say none are running.
# One look: "<pid> <start time>" for every shell child of the given pids that is not our own ancestor.
_launch_live_look() {  # <pid>...
  local table p c comm st
  table="$(ps -A -o pid=,ppid=,comm= 2>/dev/null)" || return 0
  for p in "$@"; do
    for c in $(printf '%s\n' "$table" | awk -v p="$p" '$2 == p { print $1 }'); do
      comm="$(printf '%s\n' "$table" | awk -v c="$c" '$1 == c { print $3 }')"; comm="${comm##*/}"; comm="${comm#-}"
      case "$comm" in bash|sh|zsh|dash|ksh|fish) ;; *) continue ;; esac
      launch_is_ancestor "$c" && continue
      st="$(ps -o lstart= -p "$c" 2>/dev/null | tr -s ' ' '_')"
      printf '%s %s\n' "$c" "${st:-?}"   # no lstart on this ps: pid-only match, never drop the shell
    done
  done
}

launch_live_shells() {  # <pid>...
  # Two looks, LAUNCH_LIVE_RECHECK seconds apart (default 1.5); a shell counts only if the SAME process (pid
  # and start time) is there both times. Claude Code runs the statusline as a short-lived `sh -c` child of
  # claude, so one look caught an idle session's statusline about 6% of the time and refused it. Work worth
  # protecting (a gate run, a loop) lives far longer than the gap. No shell at the first look = no wait.
  local first second c st et args
  first="$(_launch_live_look "$@")"
  [ -n "$first" ] || return 0
  sleep "${LAUNCH_LIVE_RECHECK:-1.5}"
  second="$(_launch_live_look "$@")"
  while read -r c st; do
    [ -n "$c" ] && [ -n "$st" ] || continue
    printf '%s\n' "$second" | grep -qxF "$c $st" || continue
    # gone since the second look: not live, and printing it would leave a bare pid with no time or command
    et="$(ps -o etime= -p "$c" 2>/dev/null | tr -d ' ')"; [ -n "$et" ] || continue
    args="$(ps -o args= -p "$c" 2>/dev/null | cut -c1-160)"
    printf '%s %s %s\n' "$c" "$et" "${args:-?}"
  done <<< "$first"
}

# The hand-off, written tmp + mv so the wrapper never reads half of it. The prompt travels as base64 on
# one line, so no quote, `;`, `$` or newline needs escaping between here and claude's argv.
launch_write_handoff() {  # <name> <prompt> — model/effort/mode/account come from the LAUNCH_* globals
  local dir next tmp; dir="$(launch_state_dir)"; next="$dir/$1.next"; tmp="$next.tmp.$$"
  mkdir -p "$dir" || return 1
  {
    printf 'model=%s\n' "$LAUNCH_MODEL"
    printf 'effort=%s\n' "$LAUNCH_EFFORT"
    printf 'mode=%s\n' "$LAUNCH_MODE"
    printf 'account_dir=%s\n' "$LAUNCH_ACCOUNT_DIR"
    printf 'prompt_b64=%s\n' "$(printf '%s' "$2" | base64 | tr -d '\n')"
  } > "$tmp" || return 1
  mv -f -- "$tmp" "$next"
}

# launch_wait_inplace <name> <old-pid> <wrapper-pid> <seconds> — sets LAUNCH_FRESH; true iff a
# `claude --name <name>` that is a CHILD OF THAT WRAPPER showed up. A same-name process elsewhere does
# not count, or a decoy would report a recycle that never happened.
launch_wait_inplace() {
  local end=$((SECONDS + $4)) pid; LAUNCH_FRESH=""
  while [ "$SECONDS" -lt "$end" ]; do
    for pid in $(launch_pids "$1"); do
      [ "$pid" = "$2" ] && continue
      if [ "$(launch_ppid_of "$pid")" = "$3" ]; then LAUNCH_FRESH="$pid"; break; fi
    done
    [ -n "$LAUNCH_FRESH" ] && break
    # A dead wrapper will never relaunch; do not wait out the timeout for it.
    kill -0 "$3" 2>/dev/null || break
    sleep "${RECYCLE_POLL_SECS:-1}"
  done
  [ -n "$LAUNCH_FRESH" ]
}

# launch_recycle_inplace <name> <prompt> <old-pid> <wrapper-pid>
#   0  done: LAUNCH_FRESH is the fresh claude, started by the SAME wrapper
#   1  fell back: nothing will relaunch it and the hand-off is gone; the caller opens a new tab
#   2  STOP: the wrapper owns the hand-off and is alive but no claude appeared; a new tab now would
#      run two sessions under one name, so the caller must not open one
launch_recycle_inplace() {
  local name="$1" prompt="$2" old="$3" wpid="$4" next revoked
  local t="${RECYCLE_INPLACE_TIMEOUT:-60}" g="${RECYCLE_CLAIMED_GRACE:-30}"
  next="$(launch_state_dir)/$name.next"; revoked="$next.revoked.$$"
  launch_write_handoff "$name" "$prompt" || { echo "cannot write the hand-off file in $(launch_state_dir); using a new tab" >&2; return 1; }
  # SIGTERM the old claude ONLY: signalling the wrapper would end the very loop that starts the next one.
  kill -TERM "$old" 2>/dev/null || true
  if launch_wait_inplace "$name" "$old" "$wpid" "$t"; then
    return 0
  # No fresh child yet. REVOKE the hand-off the way the wrapper claims it: an atomic mv, so exactly one
  # of us wins. A plain `rm -f` succeeds whether or not the wrapper already took the file, and opening
  # a tab after the wrapper has claimed it leaves TWO live sessions under one name.
  elif mv -- "$next" "$revoked" 2>/dev/null; then
    rm -f -- "$revoked"
    echo "no fresh '${name}' appeared under wrapper ${wpid} within ${t}s; removed the unclaimed hand-off, falling back to a new tab" >&2
    return 1
  elif ! kill -0 "$wpid" 2>/dev/null; then
    echo "wrapper ${wpid} claimed the hand-off for '${name}' and then exited; nothing will relaunch it, falling back to a new tab" >&2
    return 1
  elif launch_wait_inplace "$name" "$old" "$wpid" "$g"; then
    return 0
  fi
  echo "wrapper ${wpid} claimed the hand-off for '${name}' but no fresh claude appeared within a further ${g}s; NOT opening a tab (that would run two '${name}'). Check the session's tab." >&2
  return 2
}

# ---------------------------------------------------------------- team block

# Optional `team:` block in docs/orchestration/ORCHESTRATION.md: an unindented `team:` line,
# then indented `key: value` lines. Sets TEAM_SEAT TEAM_PREFIX TEAM_N TEAM_MODE TEAM_TERMINAL
# TEAM_MODEL TEAM_EFFORT (empty when absent; template placeholders like <Orca> are ignored for the
# name/mode keys, but an invalid model/effort EXITS 64, since silently launching on the default model
# is the failure this block exists to prevent).
launch_team_conf() {  # <repo>
  local conf="$1/docs/orchestration/ORCHESTRATION.md" k v
  # shellcheck disable=SC2034  # TEAM_CONF is read by start-team.sh
  TEAM_CONF="$conf"; TEAM_SEAT=""; TEAM_PREFIX=""; TEAM_N=""; TEAM_MODE=""; TEAM_TERMINAL=""; TEAM_MODEL=""; TEAM_EFFORT=""; TEAM_MAX=""; TEAM_SEAT_MODEL=""
  [ -f "$conf" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      seat) TEAM_SEAT="$v" ;; prefix) TEAM_PREFIX="$v" ;; siblings) TEAM_N="$v" ;;
      permission_mode) TEAM_MODE="$v" ;; terminal) TEAM_TERMINAL="$v" ;;
      model) TEAM_MODEL="$v" ;; seat_model) TEAM_SEAT_MODEL="$v" ;; effort) TEAM_EFFORT="$v" ;; max_sessions) TEAM_MAX="$v" ;;
    esac
  done < <(awk '
    /^team:[[:space:]]*$/ { on=1; next }
    on && /^[[:space:]]+[a-z_]+:/ { k=$1; sub(":", "", k); v=$2; print k "=" v; next }
    on { on=0 }' "$conf")
  launch_valid_name "$TEAM_SEAT" || TEAM_SEAT=""
  launch_valid_name "$TEAM_PREFIX" || TEAM_PREFIX=""
  [[ "$TEAM_N" =~ ^[0-9]$ ]] || TEAM_N=""
  [[ "$TEAM_MAX" =~ ^[1-9][0-9]*$ ]] || TEAM_MAX=""
  launch_valid_mode "$TEAM_MODE" || TEAM_MODE=""
  if [ -n "$TEAM_MODEL" ] && ! launch_valid_model "$TEAM_MODEL"; then
    echo "team block: model '$TEAM_MODEL' is not valid (opus[1m], sonnet[1m], haiku, fable or a full model id; fix ${conf#"$1"/}) — refusing to launch" >&2; exit 64
  fi
  if [ -n "$TEAM_SEAT_MODEL" ] && ! launch_valid_model "$TEAM_SEAT_MODEL"; then
    echo "team block: seat_model '$TEAM_SEAT_MODEL' is not valid (opus[1m], sonnet[1m], haiku, fable or a full model id; fix ${conf#"$1"/}) — refusing to launch" >&2; exit 64
  fi
  if [ -n "$TEAM_EFFORT" ] && ! launch_valid_effort "$TEAM_EFFORT"; then
    echo "team block: effort '$TEAM_EFFORT' is not valid (low|medium|high|xhigh|max; fix ${conf#"$1"/}) — refusing to launch" >&2; exit 64
  fi
  if [ "$TEAM_TERMINAL" != auto ] && ! launch_known_backend "$TEAM_TERMINAL"; then TEAM_TERMINAL=""; fi
}

# Session cap (team block `max_sessions:`; unset = no check). Every Claude session holds GBs of RAM, and a
# host that runs out does not slow down politely: a WSL VM is killed by Windows with nothing logged inside
# Linux. This WARNS (it never refuses: the human may know better) when launching <adding> more sessions would
# pass the cap. The count is every process NAMED `claude` on this host (any repo, any account); an argv match
# would also count test stand-ins and anything whose command line merely starts with "claude".
# KIT_CLAUDE_COUNT overrides the count (tests only, so they do not depend on what this host runs).
# pgrep exits 1 when nothing matches: `|| true` keeps that from failing the pipeline, since the launchers run
# with `set -euo pipefail` and would otherwise exit silently whenever no Claude session is running yet.
launch_cap_warn() {  # <adding>
  [ -n "${TEAM_MAX:-}" ] || return 0
  local n; n="${KIT_CLAUDE_COUNT:-$( { pgrep -x claude 2>/dev/null || true; } | wc -l | tr -d ' ')}"
  if [ $((n + $1)) -gt "$TEAM_MAX" ]; then
    echo "warning: ${n} Claude sessions already run on this host; launching ${1} more passes max_sessions (${TEAM_MAX}). Retire one first (retro, then close it), or raise max_sessions in the team block." >&2
  fi
  return 0
}

# launch_resolve_model <flag-model> <model-given 0|1> <flag-effort> <effort-given 0|1> [for-the-seat 0|1]
# flags > team block (`seat_model:` first when the session launched is the seat) > defaults; exit 64 on a bad flag. "Given" is tracked apart from "empty": an empty
# `--model=` is a GIVEN, invalid value (refused), never "not given" (which would fall through to the block).
# Call after launch_team_conf. Never reads a running session: nothing is inherited.
launch_resolve_model() {
  if [ "${2:-0}" = 1 ]; then launch_set_model "$1" "--model"
  elif [ "${5:-0}" = 1 ] && [ -n "${TEAM_SEAT_MODEL:-}" ]; then launch_set_model "$TEAM_SEAT_MODEL" "team block seat_model"
  elif [ -n "${TEAM_MODEL:-}" ]; then launch_set_model "$TEAM_MODEL" "team block"; fi
  if [ "${4:-0}" = 1 ]; then launch_set_effort "$3" "--effort"
  elif [ -n "${TEAM_EFFORT:-}" ]; then launch_set_effort "$TEAM_EFFORT" "team block"; fi
}

# Persist permission_mode in the team block (adding the block if missing) so recycles relaunch
# in the same mode. Touches nothing else in the file.
launch_save_mode() {  # <repo> <mode>
  local conf="$1/docs/orchestration/ORCHESTRATION.md" tmp
  if [ ! -f "$conf" ]; then echo "note: ${conf} absent — permission mode not saved" >&2; return 0; fi
  tmp="$(mktemp)"
  awk -v mode="$2" '
    /^team:[[:space:]]*$/ { print; on=1; found=1; next }
    on && /^[[:space:]]+permission_mode:/ { print "  permission_mode: " mode; done=1; next }
    on && !/^[[:space:]]+[a-z_]+:/ { if (!done) print "  permission_mode: " mode; done=1; on=0 }
    { print }
    END {
      if (on && !done) print "  permission_mode: " mode
      if (!found) { print ""; print "team:"; print "  permission_mode: " mode }
    }' "$conf" > "$tmp" && cat "$tmp" > "$conf"
  rm -f "$tmp"
  echo "saved      permission_mode: $2 in ${conf#"$1"/} (commit it so every session sees it)"
}

# ---------------------------------------------------------------- describe / open

launch_describe_env() {
  echo "backend    $LAUNCH_BACKEND"
  echo "reason     $LAUNCH_REASON"
  echo "repo       $LAUNCH_REPO"
  case "$LAUNCH_BACKEND" in
    wsl-*) echo "distro     $LAUNCH_DISTRO"; echo "wt.exe     ${LAUNCH_WT:-absent -> conhost windows}" ;;
    tmux-detached) echo "tmux       session '$(launch_tmux_session)' (created if missing) — attach with: tmux attach -t $(launch_tmux_session)" ;;
  esac
  if [ -n "$LAUNCH_NVM" ]; then echo "nvm        sourced ($HOME/.nvm/nvm.sh)"; else echo "nvm        not sourced"; fi
  echo "account    $(launch_account_label)"
  echo "model      $LAUNCH_MODEL ($LAUNCH_MODEL_SRC)"
  if [ -n "$LAUNCH_EFFORT" ]; then echo "effort     $LAUNCH_EFFORT ($LAUNCH_EFFORT_SRC)"; else echo "effort     default (not passed)"; fi
  if [ "$LAUNCH_MODE" = normal ]; then echo "mode       normal (no flag)"; else echo "mode       $LAUNCH_MODE -> $(launch_mode_flags "$LAUNCH_MODE")"; fi
  if [ "$LAUNCH_CAN_VERIFY" != 1 ]; then echo "verify     no pgrep here: launches cannot be confirmed, running sessions cannot be detected"; fi
}

# The exact command a human runs by hand in a terminal (manual backend, failures).
launch_manual_cmd() {  # <name> <prompt>
  local save="$LAUNCH_NVM"; LAUNCH_NVM=""
  if [ "$LAUNCH_BACKEND" = gitbash-cmd ]; then _launch_cmd_line "$1" "$2"
  else local b="$LAUNCH_BACKEND"; LAUNCH_BACKEND=manual; launch_cmd "$1" "$2"; LAUNCH_BACKEND="$b"; fi
  LAUNCH_NVM="$save"
}

launch_describe() {  # <name> <prompt> — print what launch_open would run
  if [ "$LAUNCH_BACKEND" = manual ]; then echo "by hand    $(launch_manual_cmd "$1" "$2")"; return; fi
  if [ "$LAUNCH_BACKEND" = gitbash-cmd ]; then echo "command    $(_launch_cmd_line "$1" "$2")"
  else echo "command    $(launch_cmd "$1" "$2")"; fi
  if [ "$LAUNCH_BACKEND" = tmux-detached ]; then
    printf 'first      tmux has-session -t %q 2>/dev/null || tmux new-session -d -s %q -c %q\n' \
      "=$(launch_tmux_session)" "$(launch_tmux_session)" "$LAUNCH_REPO"
  fi
  _launch_argv "$1" "$2"
  printf 'would run  '; _launch_print_argv
  if [ "$LAUNCH_BACKEND" = wsl-wt ]; then
    echo "fallback   $LAUNCH_PS -NoProfile -Command \"$(_launch_ps_cmd "$1" "$2")\""
  fi
}

# launch_wait_fresh <name> <old-pids> <polls of 2s> — sets LAUNCH_FRESH; 0 when a new pid exists
launch_wait_fresh() {
  local name="$1" old="$2" polls="$3" _
  LAUNCH_FRESH=""
  for _ in $(seq 1 "$polls"); do
    LAUNCH_FRESH="$(launch_pids "$name" | grep -vxF -e "${old:-__none__}" || true)"
    [ -n "$LAUNCH_FRESH" ] && return 0
    sleep 2
  done
  return 1
}

_launch_spawn() {  # run LAUNCH_ARGV; GUI emulators are detached so they outlive this script
  case "$LAUNCH_BACKEND" in
    linux-*) ( nohup "${LAUNCH_ARGV[@]}" >/dev/null 2>&1 & ) ;;
    gitbash-cmd) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${LAUNCH_ARGV[@]}" ;;
    *) "${LAUNCH_ARGV[@]}" ;;
  esac
}

# launch_open <name> <prompt> <old-pids> — open a window, wait for the fresh process.
# 0 + LAUNCH_FRESH on success (LAUNCH_FRESH=unverified when there is no pgrep); 1 otherwise.
launch_open() {
  local name="$1" prompt="$2" old="$3" s
  case "$LAUNCH_BACKEND" in
    manual) return 1 ;;
    wsl-wt)
      _launch_argv "$name" "$prompt"
      if "${LAUNCH_ARGV[@]}" && launch_wait_fresh "$name" "$old" 10; then return 0; fi
      echo "wt.exe did not produce a '$name' session; falling back to a conhost window" >&2
      "$LAUNCH_PS" -NoProfile -Command "$(_launch_ps_cmd "$name" "$prompt")" || true
      launch_wait_fresh "$name" "$old" 15; return ;;
    tmux-detached)
      s="$(launch_tmux_session)"
      if ! tmux has-session -t "=$s" 2>/dev/null; then
        tmux new-session -d -s "$s" -c "$LAUNCH_REPO" || return 1
      fi ;;
  esac
  _launch_argv "$name" "$prompt"
  _launch_spawn || return 1
  if [ "$LAUNCH_CAN_VERIFY" != 1 ]; then LAUNCH_FRESH="unverified"; return 0; fi
  launch_wait_fresh "$name" "$old" 15
}
