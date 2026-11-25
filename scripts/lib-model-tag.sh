# shellcheck shell=bash
# lib-model-tag.sh — the ONE place that decides whether a --model value may launch a session. Sourced by
# lib-launch.sh (every launcher), recycle-sibling.sh and sibling-shell.sh, so no script keeps its own copy.
#
# Why: a model id the CLI does not know is not refused at launch. The TUI opens and refuses only at the first
# prompt, so the wrapper's quick-exit check never fires and the tab sits there with the wrong or no model.
# Layers, cheapest first:
#   1. shape: lowercase letters, digits, . and -, optional [1m] (a leading - or . would be a flag, or no id at all);
#   2. a family name plus a version WITHOUT the claude- prefix (opus-5-5) is never a model: refused, valid forms named;
#   3. only the bare aliases (opus|sonnet|haiku|fable, optional [1m]) skip the CLI: they track the newest model of
#      the family;
#   4. anything else, a full id included (a valid shape does not make a model), asks the CLI once and the PASS is
#      cached per model + CLI version + account, because an alias moves with the CLI;
#   5. a refusal needs a DEFINITIVE answer: JSON with an empty modelUsage whose text says "selected model" (what an
#      unknown model returns, at zero tokens). A timeout, a login error, garbage output or a missing CLI fails OPEN
#      with one warning line, so an offline host can still recycle.
#
# API (callers print MODEL_TAG_ERR with their own prefix and exit 64):
#   model_tag_static    <model>             layers 1-2, offline; return 0 | 64 (sets MODEL_TAG_ERR)
#   model_tag_preflight <model> [acct dir]  layers 3-5; return 0 | 64 (sets MODEL_TAG_ERR); acct dir given but empty = the default account;
#                                           no acct dir argument at all = $CLAUDE_CONFIG_DIR
#   model_tag_check     <model> [acct dir]  both
# Env: MODEL_PREFLIGHT=0 skips layers 4-5 (offline hosts, tests); MODEL_PREFLIGHT_TIMEOUT seconds (default 20),
# MODEL_PREFLIGHT_VERSION_TIMEOUT (default 10) and MODEL_PREFLIGHT_KILL_AFTER (default 5: the SIGKILL after the
# timeout's SIGTERM). The cache lives in ${KIT_RUNTIME_DIR:-~/.orcastration-kit/runtime}/model-preflight.

# The state home (kit_home) travels with this lib, so every script that sources it (lib-launch, sibling-shell) has it.
# shellcheck source=lib-kit-home.sh
# No dirname: this lib must load with an empty PATH (tests/model-tag.test.sh T7), so the directory is cut from BASH_SOURCE.
_mt_dir="${BASH_SOURCE[0]%/*}"; [ "$_mt_dir" = "${BASH_SOURCE[0]}" ] && _mt_dir=.
. "$_mt_dir/lib-kit-home.sh" || { echo "lib-model-tag: lib-kit-home.sh is missing beside this file" >&2; return 64 2>/dev/null || exit 64; }
MODEL_TAG_FORMS="opus[1m], sonnet[1m], haiku or a full model id (a claude- name)"
MODEL_TAG_ERR=""

model_tag_static() {  # <model>
  local m="${1-}"
  MODEL_TAG_ERR=""
  if ! [[ "$m" =~ ^[a-z][a-z0-9.-]*(\[1m\])?$ ]]; then
    MODEL_TAG_ERR="--model must look like $MODEL_TAG_FORMS; got '$m'"
    return 64
  fi
  if [[ "$m" =~ ^(opus|sonnet|haiku|fable)-[0-9] ]]; then
    MODEL_TAG_ERR="--model must look like $MODEL_TAG_FORMS; got '$m': a family name plus a version needs the claude- prefix (claude-$m), or use the bare alias (${m%%-*})"
    return 64
  fi
  return 0
}

_model_tag_warn() { echo "model-tag: warning: $* (launching anyway; MODEL_PREFLIGHT=0 silences the check)" >&2; }

model_tag_preflight() {  # <model> [acct dir]
  # An EXPLICIT account argument, even an empty one, is the account this launch will use ('' = the default account: the CLI runs with
  # CLAUDE_CONFIG_DIR unset and the cache key says "default"). The caller's own CLAUDE_CONFIG_DIR is used only when no argument is given.
  local m="${1-}" acct
  if [ $# -ge 2 ]; then acct="$2"; else acct="${CLAUDE_CONFIG_DIR:-}"; fi
  MODEL_TAG_ERR=""
  [[ "$m" =~ ^(opus|sonnet|haiku|fable)(\[1m\])?$ ]] && return 0
  [ "${MODEL_PREFLIGHT:-1}" = 0 ] && return 0
  if ! command -v claude >/dev/null 2>&1; then _model_tag_warn "no claude on PATH, so '$m' was not checked"; return 0; fi
  local ver key dir out verdict cwd rt
  if [ -n "${KIT_RUNTIME_DIR:-}" ]; then rt="$KIT_RUNTIME_DIR"
  else
    # A kit home that cannot be a folder refuses the launch (kit_home printed why), never a silent unchecked launch.
    rt="$(kit_home)" || { MODEL_TAG_ERR="the kit state folder ~/.orcastration-kit cannot be used (see the line above), so '$m' was not checked"; return 64; }
    rt="$rt/runtime"
  fi
  # -k: SIGKILL this long after the SIGTERM, so a claude that ignores TERM cannot hang a launch past the stated timeout.
  local kill="${MODEL_PREFLIGHT_KILL_AFTER:-5}"
  ver="$(timeout -k "$kill" "${MODEL_PREFLIGHT_VERSION_TIMEOUT:-10}" claude --version 2>/dev/null </dev/null | head -1)" || true
  if [ -z "$ver" ]; then _model_tag_warn "claude --version gave nothing, so '$m' was not checked"; return 0; fi
  key="$(printf '%s\n%s\n%s\n' "$m" "$ver" "${acct:-default}" | sha256sum 2>/dev/null | cut -c1-32)"
  [ -n "$key" ] || key="$(printf '%s\n%s\n%s\n' "$m" "$ver" "${acct:-default}" | shasum -a 256 2>/dev/null | cut -c1-32)"
  if [ -z "$key" ]; then _model_tag_warn "no sha256sum or shasum, so '$m' was not checked"; return 0; fi
  dir="$rt/model-preflight"
  [ -f "$dir/$key" ] && return 0
  # An empty scratch dir as cwd: the project's own CLAUDE.md would otherwise be read into this one-word prompt. No tools, no skills.
  cwd="$rt/model-preflight-cwd"; mkdir -p "$cwd" 2>/dev/null || cwd="."
  # -u first: with the default account the caller's variable must not leak into the check.
  out="$(cd "$cwd" && env -u CLAUDE_CONFIG_DIR ${acct:+CLAUDE_CONFIG_DIR="$acct"} timeout -k "$kill" "${MODEL_PREFLIGHT_TIMEOUT:-20}" claude --model "$m" -p ok --output-format json --tools "" --disable-slash-commands 2>/dev/null </dev/null)" || true
  verdict="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    mu = d.get("modelUsage")
    if isinstance(mu, dict) and mu:
        print("ok")
    elif isinstance(mu, dict) and "selected model" in str(d.get("result", "")):
        print("unknown")
    else:
        print("inconclusive")
except Exception:
    print("inconclusive")
' 2>/dev/null)" || verdict=inconclusive
  case "$verdict" in
    ok)
      mkdir -p "$dir" 2>/dev/null && printf '%s %s\n' "$m" "$ver" > "$dir/$key" 2>/dev/null || true
      return 0 ;;
    unknown)
      MODEL_TAG_ERR="--model must look like $MODEL_TAG_FORMS; the CLI does not know the model '$m' ($ver); try the alias opus[1m], sonnet[1m] or haiku, or a full id"
      return 64 ;;
    *)
      _model_tag_warn "the CLI gave no definitive answer for '$m'"
      return 0 ;;
  esac
}

model_tag_check() {  # <model> [acct dir]  (the account argument keeps its meaning: absent = the caller's env, '' = the default account)
  model_tag_static "${1-}" || return $?
  if [ $# -ge 2 ]; then model_tag_preflight "${1-}" "$2"; else model_tag_preflight "${1-}"; fi
}
