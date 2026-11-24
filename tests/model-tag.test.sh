#!/usr/bin/env bash
# Tests for scripts/lib-model-tag.sh, the one model guard every launcher shares: shape, the family-name-without-
# claude- refusal, bare aliases skipping the CLI, and the CLI preflight (cached per model + CLI version + account,
# a refusal only on a DEFINITIVE answer, anything else fails open with one warning).
# Run: bash tests/model-tag.test.sh   Needs bash, python3, sha256sum or shasum, timeout. Every `claude` is a stand-in.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib-model-tag.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
command -v timeout >/dev/null 2>&1 || { echo "model-tag: SKIP (no timeout command)"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || { echo "model-tag: SKIP (no sha256sum or shasum)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; RT="$TMP/rt"; CALLS="$TMP/calls"; mkdir -p "$BIN" "$RT"
# The stand-in CLI. `--version` prints $STUB_VERSION; a `-p` call logs "<acct>|<model>" and answers per STUB_MODE:
#   ok = a real answer (modelUsage filled) · unknown = the unknown-model answer · garbage = not JSON · slow = outlasts the timeout
#   noise = ok, plus the `unrecognized_model` stderr line the real CLI prints even for valid ids.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "${STUB_VERSION:-9.9.9} (Stand-in)"; exit 0; fi
model=""; while [ $# -gt 0 ]; do [ "$1" = --model ] && model="$2"; shift; done
echo "${CLAUDE_CONFIG_DIR:-default}|$model" >> "$STUB_CALLS"
case "${STUB_MODE:-ok}" in
  ok)      echo '{"result":"ok","modelUsage":{"x":{"inputTokens":1}}}' ;;
  noise)   echo "warning: unrecognized_model" >&2; echo '{"result":"ok","modelUsage":{"x":{"inputTokens":1}}}' ;;
  unknown) echo '{"result":"There is an issue with the selected model (x).","modelUsage":{}}' ;;
  login)   echo '{"result":"Please run /login","modelUsage":{}}' ;;
  garbage) echo 'not json at all' ;;
  slow)    sleep 30 ;;
esac
STUB
chmod +x "$BIN/claude"
# run <acct|-> <model> [env pairs...] -> sets RC ERR; the lib is sourced in a fresh bash each time
run() {
  local acct="$1" model="$2"; shift 2
  RC=0
  ERR="$(env PATH="$BIN:$PATH" KIT_RUNTIME_DIR="$RT" STUB_CALLS="$CALLS" MODEL_PREFLIGHT_TIMEOUT=2 MODEL_PREFLIGHT_KILL_AFTER=1 "$@" \
    bash -c '. "$1"; model_tag_check "$2" ${3:+"$3"}; rc=$?; echo "ERR:$MODEL_TAG_ERR" >&2; exit $rc' _ "$LIB" "$model" "$([ "$acct" = - ] && echo "" || echo "$acct")" 2>&1 >/dev/null)" || RC=$?
}
ncalls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
reset() { rm -rf "$RT" "$CALLS"; mkdir -p "$RT"; }

# T1. Shape: what may be a model at all (offline, layers 1 and 2).
for m in 'opus[1m]' sonnet haiku fable claude-opus-5-5 'claude-sonnet-5-5[1m]'; do
  reset; run - "$m" MODEL_PREFLIGHT=0; eq "T1 accepts $m" 0 "$RC"
done
for m in '' Opus '-x' '.x' 'opus 1' 'opus[2m]' 'opus;x'; do
  reset; run - "$m" MODEL_PREFLIGHT=0; eq "T1 refuses shape [$m]" 64 "$RC"
done

# T2. A family name plus a version without the claude- prefix is never a model; the error names both fixes.
for m in opus-5-5 'sonnet-5-5[1m]' haiku-4-5 fable-5-2 'fable-5-2[1m]'; do
  reset; run - "$m" MODEL_PREFLIGHT=0; eq "T2 refuses $m" 64 "$RC"
  has "T2 $m: names the claude- prefix" "needs the claude- prefix (claude-$m)" "$ERR"
  has "T2 $m: names the bare alias" "use the bare alias (${m%%-*})" "$ERR"
done

# T3. The bare aliases never touch the CLI: they track the newest model of the family.
for m in opus 'opus[1m]' sonnet 'sonnet[1m]' haiku fable; do
  reset; run - "$m"; eq "T3 alias $m passes" 0 "$RC"
done
eq "T3 no alias called the CLI" 0 "$(ncalls)"

# T4. A full id asks the CLI once; the PASS is cached, so the second launch costs nothing.
reset; run - claude-opus-5-5 STUB_MODE=ok; eq "T4 a known full id passes" 0 "$RC"; eq "T4 one CLI call" 1 "$(ncalls)"
run - claude-opus-5-5 STUB_MODE=ok; eq "T4 second launch passes" 0 "$RC"; eq "T4 still one CLI call (cached)" 1 "$(ncalls)"
# the cache key holds the CLI version and the account: a new CLI, or another account, asks again
run - claude-opus-5-5 STUB_MODE=ok STUB_VERSION=10.0.0; eq "T4 a new CLI version asks again" 2 "$(ncalls)"
run "$TMP/acct-b" claude-opus-5-5 STUB_MODE=ok; eq "T4 another account asks again" 3 "$(ncalls)"
has "T4 the call ran under that account" "$TMP/acct-b|claude-opus-5-5" "$(cat "$CALLS")"
run "$TMP/acct-b" claude-opus-5-5 STUB_MODE=ok; eq "T4 that account is cached too" 3 "$(ncalls)"

# T4b. The account ARGUMENT decides, not the caller's env: an explicit empty argument is the DEFAULT account (the CLI runs with
#      CLAUDE_CONFIG_DIR unset and the cache key says "default"); no argument at all uses the caller's CLAUDE_CONFIG_DIR.
drive() {  # <explicit-empty|none> <env account dir>
  local call='model_tag_check claude-opus-5-5'; [ "$1" = explicit-empty ] && call='model_tag_check claude-opus-5-5 ""'
  env PATH="$BIN:$PATH" KIT_RUNTIME_DIR="$RT" STUB_CALLS="$CALLS" CLAUDE_CONFIG_DIR="$2" MODEL_PREFLIGHT_TIMEOUT=2 bash -c ". '$LIB'; $call" >/dev/null 2>&1
}
reset; drive explicit-empty "$TMP/acct-env"
eq "T4b an explicit empty account runs the CLI with CLAUDE_CONFIG_DIR unset" "default|claude-opus-5-5" "$(cat "$CALLS")"
drive explicit-empty "$TMP/acct-other"; eq "T4b ... and is cached under the default account, whatever the env says" 1 "$(ncalls)"
reset; drive none "$TMP/acct-env"
eq "T4b no argument at all: the caller's account" "$TMP/acct-env|claude-opus-5-5" "$(cat "$CALLS")"

# T5. A DEFINITIVE unknown-model answer refuses (exit 64), says which model, and is NOT cached.
reset; run - claude-opus-9-9 STUB_MODE=unknown; eq "T5 unknown model refused" 64 "$RC"
has "T5 names the model" "does not know the model 'claude-opus-9-9'" "$ERR"
has "T5 names the aliases" "try the alias opus[1m], sonnet[1m] or haiku" "$ERR"
run - claude-opus-9-9 STUB_MODE=unknown; eq "T5 asked again (a refusal is never cached)" 2 "$(ncalls)"
run - claude-opus-9-9 STUB_MODE=ok; eq "T5 once the CLI knows it, it passes" 0 "$RC"

# T6. Anything that is not a definitive answer fails OPEN with one warning: a login problem, garbage, a timeout.
for mode in login garbage slow; do
  reset; run - claude-opus-5-5 STUB_MODE=$mode; eq "T6 $mode: launches anyway" 0 "$RC"
  has "T6 $mode: one warning line" "model-tag: warning: the CLI gave no definitive answer" "$ERR"
  [ -z "$(ls "$RT/model-preflight" 2>/dev/null)" ] && ok || bad "T6 $mode: an inconclusive answer was cached"
done
# the real CLI prints `unrecognized_model` on stderr even for a valid id: it is not a signal
reset; run - claude-opus-5-5 STUB_MODE=noise; eq "T6 stderr noise is not a refusal" 0 "$RC"

# T7. Switches and absences: MODEL_PREFLIGHT=0 skips the CLI; no claude on PATH, or one that prints no version, warns and passes.
reset; run - claude-opus-9-9 STUB_MODE=unknown MODEL_PREFLIGHT=0; eq "T7 MODEL_PREFLIGHT=0 skips the CLI" 0 "$RC"; eq "T7 no CLI call" 0 "$(ncalls)"
NB="$TMP/nobin"; mkdir -p "$NB"
for t in env timeout head sha256sum shasum cut python3 mkdir sed cat bash; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NB/$t"; done
RC=0; ERR="$(env PATH="$NB" KIT_RUNTIME_DIR="$RT" "$NB/bash" -c '. "$1"; model_tag_check claude-opus-5-5; echo "rc=$?"' _ "$LIB" 2>&1)" || RC=$?
has "T7 no claude on PATH: passes" "rc=0" "$ERR"; has "T7 no claude on PATH: warns" "no claude on PATH" "$ERR"
# an empty version prints " (Stand-in)", which is still a version; use a stub that prints nothing for the no-version case
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/nover"; chmod +x "$TMP/nover"; mkdir -p "$TMP/bin2"; cp "$TMP/nover" "$TMP/bin2/claude"
RC=0; ERR="$(env PATH="$TMP/bin2:$PATH" KIT_RUNTIME_DIR="$RT" bash -c '. "$1"; model_tag_check claude-opus-5-5; echo "rc=$?"' _ "$LIB" 2>&1)" || RC=$?
has "T7 no version: passes" "rc=0" "$ERR"; has "T7 no version: warns" "gave nothing" "$ERR"

# T8. The cache lives under KIT_RUNTIME_DIR (not /tmp), and the guard has one home: no launcher keeps its own copy of the model regex.
reset; run - claude-opus-5-5 STUB_MODE=ok
[ -n "$(ls "$RT/model-preflight" 2>/dev/null)" ] && ok || bad "T8 the PASS is not under KIT_RUNTIME_DIR/model-preflight"
for f in scripts/recycle-sibling.sh scripts/sibling-shell.sh scripts/lib-launch.sh scripts/start-team.sh; do
  if grep -n 'a-z0-9\.-\]\*' "$ROOT/$f" >/dev/null 2>&1; then bad "T8 $f keeps its own model regex"; else ok; fi
  grep -q 'lib-model-tag.sh\|launch_preflight_model\|model_tag_' "$ROOT/$f" && ok || bad "T8 $f does not use the shared guard"
done

echo "model-tag: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
