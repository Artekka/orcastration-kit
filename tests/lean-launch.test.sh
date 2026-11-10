#!/usr/bin/env bash
# Tests for the model-per-lane launch flags (--model / --effort; docs/GETTING-STARTED.md "Model per lane").
# Run: bash tests/lean-launch.test.sh
# Nothing is launched: every call is --dry-run. LAUNCH_CMD_OVERRIDE (which replaces the whole
# `claude --name ...` part, flags included) is used ONLY for the inheritance test, where a stand-in
# process has to be findable; everything else reads the real command line the script would run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; RS="$ROOT/scripts/recycle-sibling.sh"; ST="$ROOT/scripts/start-team.sh"
# A kit path with whitespace: the WSL launcher refuses such repo paths by design (wt.exe/conhost command lines),
# and these suites pass the kit's own path through those command lines, so they would FAIL for that reason
# alone. Say so and skip instead; run them from a checkout whose path has no spaces.
case "$ROOT" in *[[:space:]]*) echo "lean-launch: SKIP (the kit's path has a space: $ROOT; launch command lines refuse it by design. Run from a path without spaces)"; exit 0 ;; esac
TMP="$(mktemp -d)"; pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
has() {  # <label> <want substring> <got>
  case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac
}
hasnt() {  # <label> <unwanted substring> <got>
  case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac
}
count() {  # <label> <want N> <needle> <got> — occurrences of a fixed string
  local n; n="$(printf '%s\n' "$4" | grep -oF -- "$3" | wc -l | tr -d ' ')"
  if [ "$n" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: want $2x '$3', got ${n}x in: $4"; fi
}
# Every invocation of the scripts under test goes through lrun, and nothing else (the R0 census below
# fails if a call site bypasses it). lrun is a SANDBOX: HOME is the temp dir; the host is made to look like
# WSL with a wt.exe that is an empty FILE we own (WT_EXE), not the Windows Terminal the probe would find
# through cmd.exe's %USERNAME%; and every real Windows/macOS/tmux tool the launcher could execute is
# shadowed on PATH by a stand-in that records REAL-TOOL-CALLED and exits 99 (R0 (d) fails if one ran).
FAKE_WT="$TMP/fake-wt.exe"; : > "$FAKE_WT"
STUBS="$TMP/real-tool-stubs"; mkdir -p "$STUBS"
for t in wt.exe powershell.exe cmd.exe osascript tmux; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 99\n' "$t" "$TMP/REAL-TOOL-CALLED" > "$STUBS/$t"; chmod +x "$STUBS/$t"
done
lrun() { env HOME="$TMP" WSL_DISTRO_NAME=TestDistro WSL_INTEROP= TMUX= "WT_EXE=$FAKE_WT" "PATH=$STUBS:$PATH" "$@"; }
rs() { lrun bash "$RS" --dry-run --terminal manual --repo "$ROOT" "$@" 2>&1; }
# Unique names: start-team SKIPS a name that is already running, and a developer running this suite
# is usually inside a session called Orca / Sib1.
st() { lrun bash "$ST" --dry-run --terminal manual --repo "$ROOT" --seat ZzSeat --prefix ZzSib "$@" 2>&1; }

# R0. ISOLATION tripwire (the same hole as tests/recycle-inplace.test.sh R0, 2026-10-03). The WSL backends
#     probe the host for wt.exe / powershell.exe / cmd.exe, so run with the REAL environment a case reaches
#     the real Windows tools; only --dry-run stood between this file and a real window. Everything runs
#     through lrun, which must give the scripts a sandbox, and this block proves it. DRY-RUN only.
SELF="${LEAN_LAUNCH_SELF:-$0}"
# (a) census: no call site of the scripts under test bypasses lrun (a guard that lists its call sites is
#     blind to a new one, so this reads the file's own text for the pattern instead of naming cases)
bypass="$(grep -nE 'bash "\$(RS|ST|tool)"' "$SELF" | grep -v 'lrun bash' | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -z "$bypass" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL R0 census: call sites that bypass lrun: $bypass"; fi
# (b) a forced wsl-wt dry run resolves to the sandbox's fake wt.exe and distro, and names no Windows path
wt_out="$(lrun bash "$RS" --dry-run --terminal wsl-wt --repo "$ROOT" ZzNone 2>&1)"
has "R0 wsl-wt dry run: the wt.exe is the sandbox's fake file" "wt.exe     $FAKE_WT" "$wt_out"
has "R0 wsl-wt dry run: the sandbox distro" "distro     TestDistro" "$wt_out"
hasnt "R0 wsl-wt dry run: no real Windows path (/mnt/c)" "/mnt/c/" "$wt_out"
# (c) the path the WSL probe itself resolves is the fake file, not one derived from cmd.exe's %USERNAME%
probe="$(lrun bash -c '. "$1"; _launch_wsl_probe >/dev/null 2>&1; printf %s "${LAUNCH_WT:-}"' _ "$ROOT/scripts/lib-launch.sh")"
if [ "$probe" = "$FAKE_WT" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL R0 the WSL probe resolved '$probe', want the fake $FAKE_WT"; fi

# 1. Default: a model is ALWAYS passed; effort only when given.
out="$(rs ZzNone)"
has "default model flag in the command" '--model opus\[1m\]' "$out"
has "default model named in the dry-run" "model      opus[1m] (default)" "$out"
hasnt "no --effort unless asked" "--effort" "$out"
has "effort line says not passed" "effort     default (not passed)" "$out"

# 2. Explicit: the flags land in the command, after --name, before the prompt.
out="$(rs --model 'sonnet[1m]' --effort high ZzNone)"
has "explicit model + effort in order" '--name ZzNone --model sonnet\[1m\] --effort high /orchestration-kit:orient' "$out"
has "explicit source shown" "model      sonnet[1m] (--model)" "$out"
out="$(rs --model haiku ZzNone)"
has "bare model id (haiku, no [1m])" '--model haiku' "$out"
out="$(rs --model=claude-sonnet-5-5 --effort=max ZzNone)"
has "--flag=value form" '--model claude-sonnet-5-5 --effort max' "$out"
out="$(rs --mode auto --model 'sonnet[1m]' ZzNone)"
has "mode flag and model flag coexist" '--permission-mode auto --model sonnet\[1m\]' "$out"
out="$(rs --mode bypass-available --model 'sonnet[1m]' ZzNone)"
has "bypass-available: Shift+Tab may switch to bypass, the session starts normal" '--allow-dangerously-skip-permissions --model sonnet\[1m\]' "$out"
hasnt "bypass-available never starts in bypass" "--dangerously-skip-permissions " "$(printf '%s' "$out" | sed 's/--allow-dangerously-skip-permissions//g')"
out="$(rs --mode bypass ZzNone)"; has "a bare 'bypass' is not a mode" "--mode must be" "$out"

# A lean-start prompt (`orient --brief <ROW>`) passes launch validation on a POSIX and a WSL backend
# and reaches the command intact.
for b in manual wsl-wt; do
  out="$(lrun bash "$RS" --dry-run --terminal "$b" --repo "$ROOT" --model 'sonnet[1m]' ZzNone "/orchestration-kit:orient --brief ROW-12" 2>&1; echo "rc=$?")"
  has "brief prompt accepted on $b" "orient\\ --brief\\ ROW-12" "$out"
  has "brief prompt exits 0 on $b" "rc=0" "$out"
done

# 3. Refusals: exit 64 like --account, and nothing is printed as a plan.
for bad in 'x;y' 'opus 1m' "o'pus" 'Opus' 'opus[2m]' '$(id)'; do
  out="$(rs --model "$bad" ZzNone; echo "rc=$?")"
  has "model '$bad' refused rc 64" "rc=64" "$out"
  has "model '$bad' says why" "--model must look like" "$out"
  hasnt "model '$bad' prints no command" "claude --name" "$out"
done
for bad in ultra HIGH 'hi gh' 'high;x'; do
  out="$(rs --effort "$bad" ZzNone; echo "rc=$?")"
  has "effort '$bad' refused rc 64" "rc=64" "$out"
  has "effort '$bad' says why" "--effort must be one of" "$out"
done
out="$(st --model 'x;y' --siblings 1; echo "rc=$?")"
has "start-team refuses a bad model rc 64" "rc=64" "$out"
out="$(st --effort ultra --siblings 1; echo "rc=$?")"
has "start-team refuses a bad effort rc 64" "rc=64" "$out"

# 4. Recycle NEVER inherits the old session's model (unlike its account). A stand-in session that is
#    running on haiku is recycled with no flag and must come back on the default, not on haiku.
if command -v pgrep >/dev/null 2>&1; then
  export LAUNCH_CMD_OVERRIDE='bash -c sleep 30;: {name}'
  bash -c 'sleep 30;:' ZzOld --model haiku --effort low & pids="$pids $!"
  sleep 1
  out="$(rs ZzOld)"
  has "the stand-in is found as the old session" "old pids   " "$out"
  hasnt "old pids is not empty" "old pids   none" "$out"
  has "recycled with no flag -> default model" "model      opus[1m] (default)" "$out"
  hasnt "old model not inherited" "haiku" "$out"
  has "recycled with no flag -> effort not passed" "effort     default (not passed)" "$out"
  out="$(rs --model 'sonnet[1m]' ZzOld)"
  has "recycled with --model -> that model" "model      sonnet[1m] (--model)" "$out"
  unset LAUNCH_CMD_OVERRIDE
else
  echo "skip inheritance test: no pgrep"
fi

# 5. start-team: the one --model / --effort reaches EVERY window (seat + siblings).
out="$(st --siblings 2 --model 'sonnet[1m]' --effort low)"
count "start-team: 3 windows carry --model" 3 '--model sonnet\[1m\] --effort low' "$out"
out="$(st --siblings 2)"
count "start-team default: 3 windows carry the default model" 3 '--model opus\[1m\]' "$out"

# 6. Every backend, every quoting family (posix, WSL, cmd.exe, osascript argv, tmux). Forced and
#    unavailable here is fine for --dry-run: the command line is built regardless.
backends="tmux tmux-detached wsl-wt wsl-conhost macos-iterm macos-terminal gitbash-cmd linux-gnome-terminal linux-konsole linux-xfce4-terminal linux-kitty linux-alacritty linux-wezterm linux-foot linux-xterm linux-x-terminal-emulator"
for b in $backends; do
  for tool in rs st; do
    if [ "$tool" = rs ]; then out="$(lrun bash "$RS" --dry-run --terminal "$b" --repo "$ROOT" --model 'sonnet[1m]' --effort high ZzNone 2>&1)"
    else out="$(lrun bash "$ST" --dry-run --terminal "$b" --repo "$ROOT" --seat ZzSeat --prefix ZzSib --siblings 1 --model 'sonnet[1m]' --effort high 2>&1)"; fi
    case "$out" in
      *'--model sonnet\[1m\] --effort high'*|*'--model sonnet[1m] --effort high'*) pass=$((pass+1)) ;;  # posix-quoted | cmd.exe (unquoted)
      *) fail=$((fail+1)); echo "FAIL backend $b ($tool): model/effort missing from the launch command: $out" ;;
    esac
  done
done

# 7. The default model is configurable in the team block; flags override it; a bad block value is
#    ignored with a warning (the same leniency as permission_mode) and the built-in default stands.
R="$TMP/repo"; mkdir -p "$R/docs/orchestration"
printf 'team:\n  seat: Orca\n  model: sonnet[1m]\n  effort: medium\n' > "$R/docs/orchestration/ORCHESTRATION.md"
out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" ZzNone 2>&1)"
has "team block model" "model      sonnet[1m] (team block)" "$out"
has "team block effort" "effort     medium (team block)" "$out"
has "team block reaches the command" '--model sonnet\[1m\] --effort medium' "$out"
out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" --model haiku ZzNone 2>&1)"
has "flag beats the team block" "model      haiku (--model)" "$out"
# A bad block value is REFUSED, exit 64, not ignored: warning and quietly
# launching on the default model is the silent-wrong-model failure the block exists to prevent.
printf 'team:\n  model: not;a;model\n' > "$R/docs/orchestration/ORCHESTRATION.md"
out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" ZzNone 2>&1; echo "rc=$?")"
has "bad team model refused rc 64" "rc=64" "$out"
has "bad team model says why" "team block: model 'not;a;model' is not valid" "$out"
hasnt "bad team model prints no command" "claude --name" "$out"
printf 'team:\n  effort: ultra\n' > "$R/docs/orchestration/ORCHESTRATION.md"
out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" ZzNone 2>&1; echo "rc=$?")"
has "bad team effort refused rc 64" "rc=64" "$out"
has "bad team effort says why" "team block: effort 'ultra' is not valid" "$out"
# The block is read (and refused) before flags apply, so a broken file is fixed, not routed around.
printf 'team:\n  model: not;a;model\n' > "$R/docs/orchestration/ORCHESTRATION.md"
out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" --model haiku ZzNone 2>&1; echo "rc=$?")"
has "a valid --model does not route around a broken team block" "rc=64" "$out"

# 8. A model value must look like a model, not a flag. A flag-shaped value would be
#    spliced into `claude --name N --model <value> ...` and read by claude as ITS OWN flag
#    (`--model --dangerously-skip-permissions`), so every entry point refuses it with exit 64:
#    both scripts, both the `--model V` and `--model=V` spellings.
for bad in '--effort' '--dangerously-skip-permissions' '-x' '.' '-' '--'; do
  for tool in rs st; do
    for form in sep eq; do
      if [ "$form" = sep ]; then margs=(--model "$bad"); else margs=("--model=$bad"); fi
      # start-team has no positional name; recycle-sibling needs one AFTER the flag, so the value is
      # not consumed as the name. `--effort high` rides along: the exact shape from the READ.
      if [ "$tool" = rs ]; then out="$(rs "${margs[@]}" --effort high ZzNone; echo "rc=$?")"
      else out="$(st "${margs[@]}" --effort high --siblings 1; echo "rc=$?")"; fi
      has "F1 $tool $form model '$bad' refused rc 64" "rc=64" "$out"
      hasnt "F1 $tool $form model '$bad' prints no command" "claude --name" "$out"
    done
  done
done
# The team-block path shares the validator and is REFUSED too (exit 64, seat ruling): a flag-shaped
# `model:` / `effort:` in ORCHESTRATION.md must never reach the command line, and must not be
# swallowed into a warning plus a silent default either. Both scripts.
for bad in '--effort' '--dangerously-skip-permissions' '-x' '.'; do
  printf 'team:\n  model: %s\n' "$bad" > "$R/docs/orchestration/ORCHESTRATION.md"
  out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" ZzNone 2>&1; echo "rc=$?")"
  has "F1 recycle-sibling team block model '$bad' refused rc 64" "rc=64" "$out"
  has "F1 recycle-sibling team block model '$bad' says why" "team block: model '$bad' is not valid" "$out"
  hasnt "F1 recycle-sibling team block model '$bad' prints no command" "claude --name" "$out"
  out="$(lrun bash "$ST" --dry-run --terminal manual --repo "$R" --seat ZzSeat --prefix ZzSib --siblings 1 2>&1; echo "rc=$?")"
  has "F1 start-team team block model '$bad' refused rc 64" "rc=64" "$out"
  has "F1 start-team team block model '$bad' says why" "team block: model '$bad' is not valid" "$out"
  hasnt "F1 start-team team block model '$bad' prints no command" "claude --name" "$out"
done
printf 'team:\n  effort: --dangerously-skip-permissions\n' > "$R/docs/orchestration/ORCHESTRATION.md"
for tool in rs st; do
  if [ "$tool" = rs ]; then out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" ZzNone 2>&1; echo "rc=$?")"
  else out="$(lrun bash "$ST" --dry-run --terminal manual --repo "$R" --seat ZzSeat --prefix ZzSib --siblings 1 2>&1; echo "rc=$?")"; fi
  has "F1 $tool team block flag-shaped effort refused rc 64" "rc=64" "$out"
  has "F1 $tool team block flag-shaped effort says why" "team block: effort '--dangerously-skip-permissions' is not valid" "$out"
  hasnt "F1 $tool team block flag-shaped effort prints no command" "claude --name" "$out"
done

# Unknown flags and a `-`-led positional (a name or a prompt) are refused, not passed through to
# claude: `recycle-sibling.sh ZzNone --bogus` used to exit 0 with `--bogus` in argv. A third
# positional is refused too. (A prompt that starts with `/` is the normal case and stays fine.)
for badargs in "--bogus ZzNone" "ZzNone --bogus" "ZzNone -x" "-x" "--dangerously-skip-permissions ZzNone" \
               "ZzNone /orchestration-kit:orient extra"; do
  # shellcheck disable=SC2086  # word-splitting the case string into argv is the point
  out="$(rs $badargs; echo "rc=$?")"
  has "recycle-sibling refuses '$badargs' rc 64" "rc=64" "$out"
  hasnt "recycle-sibling '$badargs' prints no command" "claude --name" "$out"
  # The flag arm and launch_check_args both refuse a `-`-led word, so rc 64 alone cannot tell which one
  # fired (falsify M4: deleting the arm survived). Pin the arm's own diagnosis, which is also the one a
  # human needs ("unknown flag: --bogus", not "name must not start with '-'").
  case "$badargs" in
    *extra) has "recycle-sibling '$badargs' says too many arguments" "too many arguments" "$out" ;;
    *) has "recycle-sibling '$badargs' says unknown flag" "unknown flag: " "$out" ;;
  esac
done
for badargs in "--bogus" "-x" "extra"; do
  # shellcheck disable=SC2086
  out="$(st $badargs --siblings 1; echo "rc=$?")"
  has "start-team refuses '$badargs' rc 64" "rc=64" "$out"
  hasnt "start-team '$badargs' prints no command" "claude --name" "$out"
done

# The shared check is the last line of defense for a name or prompt a caller built itself (the flag
# parsers above refuse `-x` first, so only a direct call reaches it).
for pair in "-x|/orchestration-kit:orient" "ZzNone|-x" "ZzNone|--dangerously-skip-permissions"; do
  out="$(bash -c '. "$1/scripts/lib-launch.sh"; launch_check_args "$2" "$3"; echo ok' _ "$ROOT" "${pair%%|*}" "${pair#*|}" 2>&1; echo "rc=$?")"
  has "launch_check_args refuses '$pair' rc 64" "rc=64" "$out"
  hasnt "launch_check_args '$pair' does not pass" "ok" "${out%rc=*}"
done
out="$(bash -c '. "$1/scripts/lib-launch.sh"; launch_check_args ZzNone /orchestration-kit:orient; echo ok' _ "$ROOT" 2>&1; echo "rc=$?")"
has "launch_check_args accepts a normal name + slash prompt" "ok" "$out"

# -h/--help prints the usage and is NOT reported as an unknown flag (the `-*)` arm would otherwise
# swallow it with a misleading "unknown flag: --help").
for tool in "$RS" "$ST"; do
  for h in -h --help; do
    out="$(lrun bash "$tool" "$h" 2>&1; echo "rc=$?")"
    has "$(basename "$tool") $h prints the usage" "Usage:" "$out"
    hasnt "$(basename "$tool") $h is not an unknown flag" "unknown" "$out"
  done
done

# 9. An EMPTY or MISSING value is a refusal (rc 64), for both flags and both scripts:
#    `--model`, `--model ''`, `--model=`, same for `--effort`. "Given" is tracked apart from "empty":
#    an empty value used to read as "not given" and silently launched on the default model.
for flag in model effort; do
  for tool in rs st; do
    for form in missing emptyarg emptyeq; do
      case "$form" in
        missing)  fargs=("--$flag") ;;
        emptyarg) fargs=("--$flag" "") ;;
        emptyeq)  fargs=("--$flag=") ;;
      esac
      if [ "$tool" = rs ]; then
        # A missing value is the LAST argument: nothing for the flag to consume.
        out="$(rs ZzNone "${fargs[@]}"; echo "rc=$?")"
      else out="$(st --siblings 1 "${fargs[@]}"; echo "rc=$?")"; fi
      has "F2 $tool --$flag ($form) refused rc 64" "rc=64" "$out"
      hasnt "F2 $tool --$flag ($form) prints no command" "claude --name" "$out"
    done
  done
done
# An empty value is refused even when the team block would have supplied one (flags override the
# block, so "given and empty" must not fall through to it).
printf 'team:\n  model: sonnet[1m]\n  effort: medium\n' > "$R/docs/orchestration/ORCHESTRATION.md"
for tool in rs st; do
  for flag in model effort; do
    if [ "$tool" = rs ]; then out="$(lrun bash "$RS" --dry-run --terminal manual --repo "$R" "--$flag=" ZzNone 2>&1; echo "rc=$?")"
    else out="$(lrun bash "$ST" --dry-run --terminal manual --repo "$R" --seat ZzSeat --prefix ZzSib --siblings 1 "--$flag=" 2>&1; echo "rc=$?")"; fi
    has "F2 $tool empty --$flag does not fall through to the team block" "rc=64" "$out"
  done
done

# R0 (d): no stand-in for a real tool (wt.exe, powershell.exe, cmd.exe, osascript, tmux) was ever executed
if [ -e "$TMP/REAL-TOOL-CALLED" ]; then fail=$((fail+1)); echo "FAIL R0 a real-tool stand-in was executed: $(cat "$TMP/REAL-TOOL-CALLED")"; else pass=$((pass+1)); fi

echo "lean-launch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
