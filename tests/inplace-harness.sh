# inplace-harness.sh — shared helpers for sibling-shell.test.sh and recycle-inplace.test.sh (sourced).
#
# Safety, because these tests touch processes: every `claude` is a STUB on PATH (a bash script that
# records its argv, then either exits or `exec -a`s into a holder whose cmdline is
# `claude --name <Name> ...`, so pgrep sees it). HOME is a temp dir (no nvm, no real account dirs), the
# terminal emulator is a stand-in `xterm` on PATH, names carry this process's pid, and cleanup SIGKILLs
# only the exact pids the stubs recorded, after re-reading their /proc cmdline. Never `pkill -f`, never a
# real session. In-place recycling reads /proc (the ps fallback is exercised with LAUNCH_NO_PROC=1), so
# these suites run on Linux only and say SKIP elsewhere.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/sibling-shell.sh"; RECYCLE="$ROOT/scripts/recycle-sibling.sh"
# A kit path with whitespace: the WSL launcher refuses such repo paths by design (wt.exe/conhost command lines),
# and these suites pass the kit's own path through those command lines, so they would FAIL for that reason
# alone. Say so and skip instead; run them from a checkout whose path has no spaces.
case "$ROOT" in *[[:space:]]*) echo "${SUITE:-inplace}: SKIP (the kit's path has a space: $ROOT; launch command lines refuse it by design. Run from a path without spaces)"; exit 0 ;; esac
if [ ! -r /proc/self/status ] || ! command -v pgrep >/dev/null 2>&1; then
  echo "${SUITE:-inplace}: SKIP (needs /proc and pgrep: Linux)"; exit 0
fi
pass=0; fail=0
SANDBOXES=(); PIDS=()
# A prompt with spaces, quotes, `;`, `&&`, `$`, a backtick, a glob, a backslash and a newline.
TRICKY=$'it\'s a "quoted" ; echo $HOME `id` * && (x) \\ done\nline two'

ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL $1"; }
eq()   { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
ne()   { if [ "$3" != "$2" ]; then ok; else bad "$1: did not want [$2]"; fi; }
has()  { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
rematch() { if printf '%s\n' "$3" | grep -Eq -- "$2"; then ok; else bad "$1: want /$2/ in: $3"; fi; }
renomatch() { if printf '%s\n' "$3" | grep -Eq -- "$2"; then bad "$1: did not want /$2/ in: $3"; else ok; fi; }
exists() { if [ -e "$2" ]; then ok; else bad "$1: want $2 to exist"; fi; }
absent() { if [ -e "$2" ]; then bad "$1: did not want $2"; else ok; fi; }

alive() {  # a killed child lingers as a zombie until reaped; kill -0 still succeeds on one
  kill -0 "$1" 2>/dev/null || return 1
  ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null
}
cmdline() { { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null || true; }
not_alive() { ! alive "$1"; }
ppid_of() { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }
wait_for() {  # <what> <command...> — polls up to 20 s
  local what="$1" i; shift
  for i in $(seq 1 200); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 0.1; done
  bad "timed out waiting for $what"; return 1
}

# sandbox: sets SB (root) and creates HOME/bin/stub/state/repo. Writes the stub claude and holders.
sandbox() {
  SB="$(mktemp -d)"; SANDBOXES+=("$SB")
  mkdir -p "$SB/home" "$SB/bin" "$SB/stub" "$SB/state" "$SB/repo"
  : > "$SB/fake-wt.exe"   # exists so a WSL DRY-RUN finds a wt.exe; nothing ever executes it
  cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
d=$STUB_DIR
n=$(( $(wc -l < $d/launches 2>/dev/null || echo 0) + 1 ))
printf "%s %s %s\n" "$$" "$PPID" "${CLAUDE_CONFIG_DIR-unset}" >> $d/launches
printf '%s\0' "$@" > $d/argv.$n
stage() { mkdir -p $SIBLING_STATE_DIR; cp $1 $SIBLING_STATE_DIR/$2.next.tmp && mv -f $SIBLING_STATE_DIR/$2.next.tmp $SIBLING_STATE_DIR/$2.next; }
[ -f $d/handoff.$n ] && stage $d/handoff.$n "$2"
[ -f $d/handoff.always ] && [ "$n" -lt 10 ] && stage $d/handoff.always "$2"
# Padding first: the hijack line must sit PAST the byte offset bash has reached, or a wrapper that
# goes back to the file after `main` returns would find EOF and look immune.
[ -n "${STUB_REWRITE:-}" ] && { yes "" | head -n 20000; echo "echo HIJACKED >&2"; } > $STUB_REWRITE
case " ${STUB_SLOW:-} " in *" $n "*) sleep ${STUB_SLOW_SECS:-1.3} ;; esac
[ -f $d/mode.$n ] && STUB_MODE=$(cat $d/mode.$n)   # a per-launch mode beats STUB_MODE
case "${STUB_MODE:-exit}" in
  exit) exit "${STUB_EXIT:-0}" ;;
  term-trap) exec -a "claude $*" bash $d/holder-term.sh ;;
  ignore-term) exec -a "claude $*" bash $d/holder-ignore.sh ;;
  term-decoy) exec -a "claude $*" bash $d/holder-decoy.sh "$2" ;;
  self-recycle) exec -a "claude $*" bash $d/holder-self.sh ;;
esac
STUB
  chmod +x "$SB/bin/claude"
  # term-trap records the SIGTERM it receives; ignore-term never exits; term-decoy spawns a
  # `claude --name <Name>` that is NOT a child of the wrapper (setsid: parent = init) and ignores TERM.
  printf '%s\n' "trap 'date +%s.%N > \$STUB_DIR/sigterm-at.\$\$; echo TERM >> \$STUB_DIR/sigterm.\$\$; exit 0' TERM" 'while :; do sleep 0.2; done' > "$SB/stub/holder-term.sh"
  printf '%s\n' "trap '' TERM" 'while :; do sleep 0.2; done' > "$SB/stub/holder-ignore.sh"
  # self-recycle is the seat: it runs the recycle script the way the seat's shell tool does (one
  # `bash -c` layer; the trailing `; true` keeps that layer from exec-ing the script), then holds like
  # term-trap so the SIGTERM it receives is recorded. SELF_RECYCLE_CMD is the full command line.
  printf '%s\n' "trap 'date +%s.%N > \$STUB_DIR/sigterm-at.\$\$; echo TERM >> \$STUB_DIR/sigterm.\$\$; exit 0' TERM" \
    'bash -c "$SELF_RECYCLE_CMD > $STUB_DIR/self.out 2> $STUB_DIR/self.err; true"' \
    'while :; do sleep 0.2; done' > "$SB/stub/holder-self.sh"
  cat > "$SB/stub/holder-decoy.sh" <<'HOLD'
trap 'setsid bash -c "exec -a \"claude --name \$0 decoy\" sleep 120" $1 </dev/null >/dev/null 2>&1 & echo $! >> $STUB_DIR/decoy.pids' TERM
while :; do sleep 0.2; done
HOLD
  # The terminal emulator stand-in (`--terminal linux-xterm`): records its argv, then runs the tab's
  # command detached, exactly as a real tab would. FAKE_TERM_MODE=forbid must never be reached.
  cat > "$SB/bin/xterm" <<'TERM'
#!/usr/bin/env bash
if [ "${FAKE_TERM_MODE:-run}" = forbid ]; then touch "$FAKE_TERM_DIR/TERM-WAS-CALLED"; exit 99; fi
printf '%s\n' "$@" >> "$FAKE_TERM_DIR/fake-term.args"
cmd="${@: -1}"
setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
echo $! >> "$FAKE_TERM_DIR/fake-term.pids"
TERM
  chmod +x "$SB/bin/xterm"
}

# The environment every case runs in (sourced into a subshell via `env`): the sandbox, not this session.
sbenv() {  # prints NAME=VALUE words for `env`; extra pairs may follow as arguments
  printf '%s\n' "PATH=$SB/bin:$PATH" "HOME=$SB/home" "SIBLING_STATE_DIR=$SB/state" "STUB_DIR=$SB/stub" \
    "SIBLING_MIN_RUN_SECS=0" "FAKE_TERM_DIR=$SB" "DISPLAY=:0" "RECYCLE_POLL_SECS=0.2" "RECYCLE_INPLACE_TIMEOUT=20" \
    "FAKE_TERM_MODE=run" "MODEL_PREFLIGHT=0" "KIT_RUNTIME_DIR=$SB/runtime" \
    "WSL_DISTRO_NAME=" "WSL_INTEROP=" "TMUX=" "WT_EXE=$SB/no-such-wt.exe" "$@"
}
# ISOLATION (the m7 incident, 2026-10-03): lib-launch auto-detects the terminal. On a WSL box that is the
# REAL wt.exe (derived from cmd.exe's %USERNAME% when WT_EXE is unset), so any run that reaches the
# auto-detect path (e.g. a mutant that drops --terminal) opened a real Windows Terminal tab on the
# user's screen. The defaults above make the sandbox non-WSL, non-tmux and point WT_EXE at a path that
# does not exist; a case that needs the WSL dry-run text passes SB_WSL_ENV (a fake wt.exe FILE, never run).
sb_wsl_env() { printf '%s\n' "WSL_DISTRO_NAME=TestDistro" "WT_EXE=$SB/fake-wt.exe"; }
# env -u CLAUDE_CONFIG_DIR (this session may run under one); a case that wants it passes it explicitly.
run_in_sb() {  # <env pairs...> -- <command...>   (sets RC OUT ERR)
  local pairs=() cmd=() seen=0 a
  for a in "$@"; do
    if [ "$seen" = 0 ] && [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then pairs+=("$a"); else cmd+=("$a"); fi
  done
  local words=() w
  while IFS= read -r w; do words+=("$w"); done < <(sbenv ${pairs[@]+"${pairs[@]}"})
  local unset_cfg=(-u CLAUDE_CONFIG_DIR)
  for a in ${pairs[@]+"${pairs[@]}"}; do case "$a" in CLAUDE_CONFIG_DIR=*) unset_cfg=() ;; esac; done
  ERR="$SB/last.err"
  OUT="$(env ${unset_cfg[@]+"${unset_cfg[@]}"} "${words[@]}" timeout 120 "${cmd[@]}" 2>"$ERR")"; RC=$?
  ERR="$(cat "$SB/last.err")"
}
run_wrapper() { run_in_sb "$@" -- bash "${WRAPPER_UNDER_TEST:-$WRAPPER}" "${WRAPPER_ARGS[@]}"; }

# Stub bookkeeping.
nlaunch() { if [ -f "$SB/stub/launches" ]; then wc -l < "$SB/stub/launches" | tr -d ' '; else echo 0; fi; }
launch_pid() { sed -n "${1}p" "$SB/stub/launches" | awk '{print $1}'; }
launch_ppid() { sed -n "${1}p" "$SB/stub/launches" | awk '{print $2}'; }
launch_cfg() { sed -n "${1}p" "$SB/stub/launches" | awk '{print $3}'; }
cfgs() { awk '{printf "%s%s", sep, $3; sep=","}' "$SB/stub/launches"; }
argv_of() { tr '\0' '|' < "$SB/stub/argv.$1"; }   # NUL-delimited on disk, so a newline in a prompt survives
last_arg_is() {  # <launch N> <expected text> — byte-exact compare of the stub's last argv element
  python3 - "$SB/stub/argv.$1" "$2" <<'PY'
import sys
p = open(sys.argv[1], 'rb').read().split(b'\0'); p.pop()
sys.exit(0 if p and p[-1] == sys.argv[2].encode() else 1)
PY
}
# a hand-off in the documented format; the prompt is base64 so ANY text round-trips
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
handoff() {  # <model> <effort> <account> <prompt> [mode]  -> text of the file
  printf 'model=%s\neffort=%s\naccount_dir=%s\nprompt_b64=%s\n' "$1" "$2" "$3" "$(b64 "$4")"
  if [ -n "${5:-}" ]; then printf 'mode=%s\n' "$5"; fi
}
stage_handoff() { printf '%s' "$2" > "$SB/stub/handoff.$1"; }   # $1 = launch number or "always"

# A real wrapper process (the real script, the stub claude), in the background. Sets WPID.
start_wrapper() {  # <Name> <env pairs...>
  local name="$1"; shift
  local words=() w
  while IFS= read -r w; do words+=("$w"); done < <(sbenv "$@")
  env -u CLAUDE_CONFIG_DIR "${words[@]}" bash "$WRAPPER" "$name" --model 'opus[1m]' </dev/null >/dev/null 2>&1 &
  WPID=$!; disown "$WPID"; PIDS+=("$WPID")
  wait_for "launch 1 of $name" test -f "$SB/stub/launches"
}
# A stand-in wrapper: runs as `bash <dir>/sibling-shell.sh <wrapperName>` and parents one
# `claude --name <childName>` (a renamed sleep, or a script so a case can run recycle FROM INSIDE the
# old claude, as the seat does). Sets SWPID and SCPID.
stand_in_wrapper() {  # <wrapperName> <childName> [child-script-text] [env pairs...]
  local wname="$1" cname="$2" script="${3:-}"; shift; shift; shift 2>/dev/null || true
  local dir="$SB/standin-$wname" childExec="sleep 120" words=() w
  mkdir -p "$dir"
  if [ -n "$script" ]; then printf '%s\n' "$script" > "$dir/child.sh"; childExec="bash $dir/child.sh"; fi
  printf '#!/usr/bin/env bash\nbash -c '"'"'exec -a "claude --name %s x" %s'"'"' &\nwait\n' "$cname" "$childExec" > "$dir/sibling-shell.sh"
  while IFS= read -r w; do words+=("$w"); done < <(sbenv "$@")
  env -u CLAUDE_CONFIG_DIR "${words[@]}" bash "$dir/sibling-shell.sh" "$wname" </dev/null >/dev/null 2>&1 &
  SWPID=$!; disown "$SWPID"; PIDS+=("$SWPID")
  wait_for "stand-in child of $cname" pgrep -f "^claude --name ${cname}( |\$)"
  SCPID="$(pgrep -f "^claude --name ${cname}( |\$)" | head -1)"; PIDS+=("$SCPID")
}

# recycle-sibling.sh in the sandbox against the stand-in terminal. Sets RC OUT ERR.
recycle() {  # <env pairs...> -- <recycle args...>
  local pairs=() args=() seen=0 a
  for a in "$@"; do
    if [ "$seen" = 0 ] && [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then pairs+=("$a"); else args+=("$a"); fi
  done
  run_in_sb ${pairs[@]+"${pairs[@]}"} -- bash "$RECYCLE" --repo "$SB/repo" --terminal linux-xterm "${args[@]}"
}

nameFor() { echo "Zz$1$$"; }

cleanup() {
  local sb f p c
  for sb in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
    # the stubs' own pids and their parents (a tab's wrapper), each re-checked against its cmdline below
    if [ -f "$sb/stub/launches" ]; then while read -r p pp _; do PIDS+=("$p" "$pp"); done < "$sb/stub/launches"; fi
    for f in "$sb/fake-term.pids" "$sb/stub/decoy.pids"; do
      if [ -f "$f" ]; then while read -r p; do PIDS+=("$p"); done < "$f"; fi
    done
  done
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    c="$(cmdline "$p")"
    case "$c" in *"claude --name Zz"*|*sibling-shell.sh*) kill -KILL "$p" 2>/dev/null || true ;; esac
  done
  for sb in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$sb"; done
}
trap cleanup EXIT

finish() { echo "${SUITE:-inplace}: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }
