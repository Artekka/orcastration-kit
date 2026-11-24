#!/usr/bin/env bash
# Tests for scripts/tmux-session.sh, scripts/tmux/agents.tmux.conf, sibling-shell.sh's window naming and the
# tmux-detached backend's config (ORCA322-2, ported from the Einherjar project's ORCA292-1).
# Run: bash tests/tmux-session.test.sh
# Safety: tmux is a STUB on PATH / in RECYCLE_TMUX that only appends its argv to a log; `claude` is a stub too;
# HOME is a temp dir. No real tmux server, Windows tool or session is ever touched.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0; SANDBOXES=()
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
exists() { if [ -e "$2" ]; then ok; else bad "$1: want $2 to exist"; fi; }
absent() { if [ -e "$2" ]; then bad "$1: did not want $2"; else ok; fi; }
cleanup() { local d; for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

# sandbox: a throwaway git repo named $1 holding a COPY of scripts/ (so the script's "main checkout" is the sandbox, not
# the kit), a stub tmux that logs and keeps a tiny state, a stub claude, and a temp HOME.
sandbox() {
  SB="$(mktemp -d)"; SANDBOXES+=("$SB")
  REPO="$SB/${1:-proj}"; mkdir -p "$REPO" "$SB/home" "$SB/bin" "$SB/state"
  git -C "$REPO" init -q 2>/dev/null
  cp -r "$ROOT/scripts" "$REPO/scripts" 2>/dev/null || true
  : > "$SB/state/sessions"; : > "$SB/state/windows"; : > "$SB/tmux.log"
  cat > "$SB/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# Logs "arg|arg|..." and fakes just enough state: sessions, windows (session:name).
printf '%s|' "$@" >> "$TMUX_LOG"; echo >> "$TMUX_LOG"
[ "${1:-}" = -f ] && shift 2
cmd="${1:-}"; shift || true
arg_after() { local w="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$w" ] && { printf '%s' "${2:-}"; return; }; shift; done; }
case "$cmd" in
  has-session) t="$(arg_after -t "$@")"; grep -qxF "${t#=}" "$STATE/sessions" ;;
  new-session) s="$(arg_after -s "$@")"; echo "$s" >> "$STATE/sessions"; n="$(arg_after -n "$@")"; [ -z "$n" ] || echo "$s:$n" >> "$STATE/windows" ;;
  new-window) t="$(arg_after -t "$@")"; t="${t#=}"; t="${t%:}"; n="$(arg_after -n "$@")"; [ -z "$n" ] || echo "$t:$n" >> "$STATE/windows" ;;
  list-windows) t="$(arg_after -t "$@")"; t="${t#=}"; sed -n "s/^$t://p" "$STATE/windows" ;;
  *) : ;;
esac
STUB
  cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$CLAUDE_LOG"; echo >> "$CLAUDE_LOG"
exit 0
STUB
  chmod +x "$SB/bin/tmux" "$SB/bin/claude"
  : > "$SB/claude.log"
  TS="$REPO/scripts/tmux-session.sh"
}
# run <env pairs...> -- <command...>   -> RC OUT ERR ; HOME and the stubs are always set
run() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  RC=0
  env -u TMUX -u TMUX_PANE HOME="$SB/home" PATH="$SB/bin:$PATH" STATE="$SB/state" TMUX_LOG="$SB/tmux.log" CLAUDE_LOG="$SB/claude.log" \
    RECYCLE_TMUX="$SB/bin/tmux" "${envs[@]}" "$@" >"$SB/out" 2>"$SB/err" </dev/null || RC=$?
  OUT="$(cat "$SB/out")"; ERR="$(cat "$SB/err")"
}
log() { cat "$SB/tmux.log"; }

# 1. A fresh session with a seat: -f conf, the seat is the FIRST window (named, in the checkout), running the respawn wrapper.
sandbox proj
run -- bash "$TS" --session agents --seat Orca --model 'opus[1m]' --effort high --prompt 'Orient and orchestrate' --no-attach
eq "T1 exit 0" 0 "$RC"
has "T1 new-session with the conf" "-f|$REPO/scripts/tmux/agents.tmux.conf|new-session|-d|-s|agents|-n|Orca|-c|$REPO|--|bash|-lc|" "$(log)"
has "T1 the window runs sibling-shell with the explicit model" "sibling-shell.sh Orca --model opus\\[1m\\] --effort high Orient\\ and\\ orchestrate" "$(log)"
has "T1 the running server also sources the conf" "source-file|$REPO/scripts/tmux/agents.tmux.conf|" "$(log)"
hasnt "T1 no attach with --no-attach" "attach-session" "$(log)"
has "T1 prints the attach command" "attach with: tmux attach -t agents" "$OUT"

# 1b. Attach outside tmux = attach-session; inside tmux ($TMUX set) = switch-client. Exact session match (=NAME).
sandbox proj
run -- bash "$TS" --session agents
has "T1b attach-session" "attach-session|-t|=agents|" "$(log)"
sandbox proj
run TMUX=/tmp/x,1,0 -- bash "$TS" --session agents
has "T1b switch-client inside tmux" "switch-client|-t|=agents|" "$(log)"
hasnt "T1b no attach-session inside tmux" "attach-session" "$(log)"

# 1c. No --seat: a plain session, no named window.
sandbox proj
run -- bash "$TS" --session agents --no-attach
has "T1c plain new-session" "new-session|-d|-s|agents|-c|$REPO|" "$(log)"
hasnt "T1c no window name" "|-n|" "$(log)"

# 2. An existing session: no new-session; a missing seat window is added, an existing one is left alone.
sandbox proj
echo agents >> "$SB/state/sessions"
run -- bash "$TS" --session agents --seat Orca --model haiku --no-attach
hasnt "T2 no new-session on an existing session" "new-session" "$(log)"
has "T2 new-window for the missing seat" "new-window|-d|-t|=agents:|-n|Orca|-c|$REPO|" "$(log)"
run -- bash "$TS" --session agents --seat Orca --model haiku --no-attach
eq "T2 second run exit 0" 0 "$RC"
eq "T2 exactly one new-window ever" 1 "$(grep -c '^new-window|' "$SB/tmux.log")"
has "T2 says the window was left alone" "window 'Orca' already exists in session 'agents'; left alone" "$ERR"

# 3. Argument validation: the model is always explicit, names and effort are checked, unknown arguments refused.
sandbox proj
run -- bash "$TS" --seat Orca --no-attach;                      eq "T3 seat without model" 64 "$RC"
run -- bash "$TS" --seat 'bad name' --model haiku --no-attach;  eq "T3 bad seat name" 64 "$RC"
run -- bash "$TS" --seat Orca --model 'Opus 1m' --no-attach;    eq "T3 bad model" 64 "$RC"
run -- bash "$TS" --seat Orca --model haiku --effort huge --no-attach; eq "T3 bad effort" 64 "$RC"
run -- bash "$TS" --bogus;                                      eq "T3 unknown argument" 64 "$RC"
run -- bash "$TS" --install-windows --no-attach;                eq "T3 --install-windows alone" 64 "$RC"
eq "T3 nothing reached tmux" "" "$(log)"

# 4. The default session name is the main checkout's directory name made tmux-safe the SAME way recycle/launch names it
#    (lib-launch.sh launch_tmux_session), so this script and a later recycle never open two sessions for one repo.
sandbox 'my.proj:x'
run -- bash "$TS" --no-attach
eq "T4 exit 0" 0 "$RC"
has "T4 session from the directory name" "new-session|-d|-s|my_proj_x|" "$(log)"
want="$(bash -c ". '$ROOT/scripts/lib-launch.sh'; LAUNCH_REPO='$REPO' launch_tmux_session")"
eq "T4 same rule as lib-launch launch_tmux_session" "my_proj_x" "$want"
sandbox proj
run RECYCLE_TMUX_SESSION=from-env -- bash "$TS" --no-attach
has "T4 RECYCLE_TMUX_SESSION overrides" "new-session|-d|-s|from-env|" "$(log)"

# 4b. ONE name rule (READ MED-1): RECYCLE_TMUX_SESSION and REPO_DIR steer lib-launch's tmux-detached windows too, and this
#     script takes its default from the SAME function, so a recycle never opens a second session outside the first.
sandbox proj
got="$(RECYCLE_TMUX_SESSION=from-env bash -c ". '$ROOT/scripts/lib-launch.sh'; LAUNCH_REPO='$REPO' launch_tmux_session")"
eq "T4b launch_tmux_session honors RECYCLE_TMUX_SESSION" "from-env" "$got"
got="$(env -u RECYCLE_TMUX_SESSION bash -c ". '$ROOT/scripts/lib-launch.sh'; LAUNCH_REPO='$REPO' launch_tmux_session")"
eq "T4b without it, the repo's directory name" "proj" "$got"
run RECYCLE_TMUX_SESSION=from-env -- bash "$TS" --no-attach
has "T4b tmux-session.sh and the launcher name the same session" "new-session|-d|-s|from-env|" "$(log)"
OTHER="$SB/other.repo"; mkdir -p "$OTHER"
run REPO_DIR="$OTHER" -- bash "$TS" --no-attach
has "T4b REPO_DIR names the session, as it does for the launcher" "new-session|-d|-s|other_repo|" "$(log)"
got="$(REPO_DIR="$OTHER" bash -c ". '$ROOT/scripts/lib-launch.sh'; LAUNCH_REPO=\"\$(launch_repo)\" launch_tmux_session")"
eq "T4b the launcher resolves REPO_DIR to the same name" "other_repo" "$got"
hasnt "T4b the name rule lives in ONE place (no second tr in tmux-session.sh)" "tr -c" "$(cat "$TS")"
has "T4b tmux-session.sh asks the launcher for the name" "launch_tmux_session" "$(cat "$TS")"

# 4c. Docs warn that --session names only this script's session (READ LOW): launches from outside tmux need RECYCLE_TMUX_SESSION.
for f in README.md docs/GETTING-STARTED.md scripts/tmux-session.sh; do
  has "T4c $f says to use RECYCLE_TMUX_SESSION, not --session" "RECYCLE_TMUX_SESSION, not --session" "$(tr '\n#' '  ' < "$ROOT/$f" | tr -s ' ')"
done

# 5. No tmux installed: without a seat there is nothing to run (69); with a seat the wrapper runs directly, from the checkout.
sandbox proj
run RECYCLE_TMUX=/nonexistent/tmux -- bash "$TS" --session agents
eq "T5 no tmux, no seat" 69 "$RC"
has "T5 says why" "tmux is not installed" "$ERR"
printf '#!/usr/bin/env bash\necho "CWD=$PWD ARGS=$*"\n' > "$REPO/scripts/sibling-shell.sh"
run RECYCLE_TMUX=/nonexistent/tmux -- bash "$TS" --session agents --seat Orca --model haiku --effort low --prompt 'go now'
eq "T5 no tmux, with seat runs the wrapper" 0 "$RC"
has "T5 wrapper args" "ARGS=Orca --model haiku --effort low go now" "$OUT"
has "T5 runs in the checkout" "CWD=$REPO" "$OUT"

# 6. --install-command writes ONE launcher with the baked arguments; idempotent; a foreign file is never overwritten.
sandbox proj
run -- bash "$TS" --install-command orca --session agents --seat Orca --model 'opus[1m]' --prompt 'Orient and orchestrate'
eq "T6 exit 0" 0 "$RC"
L="$SB/home/.local/bin/orca"
exists "T6 launcher written" "$L"; if [ -x "$L" ]; then ok; else bad "T6 launcher executable"; fi
has "T6 marker" "# tmux-session.sh launcher (generated; reinstall with --install-command, do not edit)" "$(cat "$L")"
has "T6 bakes the arguments" "--seat Orca --model opus\\[1m\\] --prompt Orient\\ and\\ orchestrate" "$(cat "$L")"
has "T6 forwards typed words" '"$@"' "$(cat "$L")"
hasnt "T6 never bakes --no-attach" "--no-attach" "$(cat "$L")"
has "T6 warns that ~/.local/bin is not on PATH" "not on PATH" "$ERR"
before="$(cat "$L")"; run -- bash "$TS" --install-command orca --session agents --seat Orca --model 'opus[1m]' --prompt 'Orient and orchestrate'
eq "T6 reinstall is fine" 0 "$RC"; eq "T6 reinstall is byte-identical" "$before" "$(cat "$L")"
printf 'my own script\n' > "$SB/home/.local/bin/mine"
run -- bash "$TS" --install-command mine --seat Orca --model haiku
eq "T6 foreign file refused" 65 "$RC"; eq "T6 foreign file untouched" "my own script" "$(cat "$SB/home/.local/bin/mine")"
run -- bash "$TS" --install-command 'bad name'; eq "T6 bad command name" 64 "$RC"
# the launcher itself runs the script (stub tmux): session absent -> seat is the first window
run -- bash "$L" --no-attach
eq "T6 the launcher runs" 0 "$RC"
has "T6 the launcher created the session with the seat" "new-session|-d|-s|agents|-n|Orca|" "$(log)"

# 7. --install-windows (WSL only): refused with nothing written elsewhere, and with stand-ins writes .cmd + a fragment.
sandbox proj
run RECYCLE_WSL_INTEROP=/nonexistent -- bash "$TS" --install-command orca --install-windows --seat Orca --model haiku
eq "T7 refused off WSL" 69 "$RC"
absent "T7 nothing written on refusal" "$SB/home/.local/bin/orca"
mkdir -p "$SB/win/user" "$SB/win/local"
cat > "$SB/bin/fake-cmd.exe" <<STUB
#!/usr/bin/env bash
case "\$*" in *USERPROFILE*) echo 'C:\\Users\\u' ;; *LOCALAPPDATA*) echo 'C:\\Users\\u\\AppData\\Local' ;; esac
STUB
cat > "$SB/bin/fake-wslpath" <<STUB
#!/usr/bin/env bash
# -u C:\\x -> $SB/win/x ; -w PATH -> C:\\ + PATH
if [ "\$1" = -w ]; then printf 'C:\\\\mapped%s\n' "\$2"; else printf '%s\n' "$SB/win/\$(printf '%s' "\$2" | tr '\\\\' '/' | sed 's#^C:/##')"; fi
STUB
printf '#!/usr/bin/env bash\necho "C:\\\\Windows"\n' > "$SB/bin/fake-ps"
chmod +x "$SB/bin/fake-cmd.exe" "$SB/bin/fake-wslpath" "$SB/bin/fake-ps"
touch "$SB/interop"
WENV=(RECYCLE_WSL_INTEROP="$SB/interop" RECYCLE_CMD_EXE="$SB/bin/fake-cmd.exe" RECYCLE_WSLPATH="$SB/bin/fake-wslpath" RECYCLE_POWERSHELL="$SB/bin/fake-ps" WSL_DISTRO_NAME=TestDistro)
run "${WENV[@]}" -- bash "$TS" --install-command orca --install-windows --session agents --seat Orca --model haiku
eq "T7 install-windows exit 0" 0 "$RC"
CMDF="$SB/win/Users/u/bin/orca.cmd"; FRAG="$SB/win/Users/u/AppData/Local/Microsoft/Windows Terminal/Fragments/agents/orca.json"
exists "T7 orca.cmd" "$CMDF"; exists "T7 fragment" "$FRAG"
has "T7 cmd passes typed words through wsl.exe with the distro unquoted" "wsl.exe -d TestDistro -e bash -lc" "$(cat "$CMDF")"
has "T7 cmd ends with %*" "%*" "$(cat "$CMDF")"
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FRAG" 2>/dev/null; then ok; else bad "T7 fragment is valid JSON"; fi
has "T7 fragment names the profile" '"name": "Orca"' "$(cat "$FRAG")"
run "${WENV[@]}" WSL_DISTRO_NAME='Bad Distro' -- bash "$TS" --install-command orca2 --install-windows --seat Orca --model haiku
eq "T7 a distro name that needs quoting is refused" 64 "$RC"
absent "T7 and nothing was written for it" "$SB/home/.local/bin/orca2"
printf 'foreign\n' > "$CMDF"
run "${WENV[@]}" -- bash "$TS" --install-command orca --install-windows --session agents --seat Orca --model haiku
eq "T7 a foreign orca.cmd is refused" 65 "$RC"; eq "T7 and left alone" "foreign" "$(cat "$CMDF")"

# 8. The tmux config pins the settings Claude Code needs.
CONF="$ROOT/scripts/tmux/agents.tmux.conf"
exists "T8 conf exists" "$CONF"
conf="$(cat "$CONF" 2>/dev/null)"
for line in "set -g mouse on" "set -g extended-keys on" "set -g allow-passthrough on" "set -g allow-rename off" "set -g renumber-windows on" "set -g history-limit 200000" "set -g escape-time 10"; do
  has "T8 conf has: $line" "$line" "$conf"
done
hasnt "T8 conf names no project" "einherjar" "$(printf '%s' "$conf" | tr 'A-Z' 'a-z')"

# 9. sibling-shell.sh names its tmux window <Name> once; no TMUX_PANE = no tmux call.
sandbox proj
mkdir -p "$SB/state/sess"
run SIBLING_STATE_DIR="$SB/state/sess" SIBLING_TMUX="$SB/bin/tmux" TMUX_PANE=%7 -- bash "$ROOT/scripts/sibling-shell.sh" Wk --model haiku go
eq "T9 wrapper exit 0" 0 "$RC"
has "T9 renamed the pane's window" "rename-window|-t|%7|Wk|" "$(log)"
eq "T9 claude still ran" "--name|Wk|--model|haiku|go|" "$(cat "$SB/claude.log")"
: > "$SB/tmux.log"
run SIBLING_STATE_DIR="$SB/state/sess" SIBLING_TMUX="$SB/bin/tmux" -- bash "$ROOT/scripts/sibling-shell.sh" Wk --model haiku go
eq "T9 no TMUX_PANE, no tmux call" "" "$(log)"
: > "$SB/tmux.log"
run SIBLING_STATE_DIR="$SB/state/sess" SIBLING_TMUX=/nonexistent/tmux TMUX_PANE=%7 -- bash "$ROOT/scripts/sibling-shell.sh" Wk --model haiku go
eq "T9 a missing tmux never fails the wrapper" 0 "$RC"

# 10. The tmux-detached backend starts its session with the same config (mouse, extended keys), and only when the file exists.
sandbox proj
OUT10="$(env HOME="$SB/home" PATH="$SB/bin:$PATH" STATE="$SB/state" TMUX_LOG="$SB/tmux.log" bash -c "
  . '$ROOT/scripts/lib-launch.sh'
  launch_wait_fresh() { return 0; }
  _launch_spawn() { return 0; }
  LAUNCH_REPO='$REPO'; LAUNCH_BACKEND=tmux-detached; LAUNCH_CAN_VERIFY=1; LAUNCH_NVM=''
  launch_open Wk go '' >/dev/null 2>&1; echo rc=\$?" 2>&1)"
has "T10 launch_open succeeded" "rc=0" "$OUT10"
has "T10 detached session created with the kit conf" "-f|$ROOT/scripts/tmux/agents.tmux.conf|new-session|-d|-s|proj|" "$(log)"

echo "tmux-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
