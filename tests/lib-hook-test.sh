#!/usr/bin/env bash
# Shared helpers for the hook tests (source it): ok / bad / has / eq, `drive` (runs tests/lib-hook-cases.py and counts its lines),
# `feed` (one hook call from a JSON string) and `mkjson` (the PreToolUse JSON for one command). Not a test itself.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
drive() {  # drive <hook> <case file> <refuse|allow> [extra lib-hook-cases args...]
  local hook=$1 cases=$2 expect=$3 line; shift 3
  while IFS= read -r line; do
    if [ "$line" = ok ]; then ok; else bad "$line"; fi
  done < <(python3 -I "$ROOT/tests/lib-hook-cases.py" --hook "$hook" --cases "$cases" --expect "$expect" "$@" 2>&1)
}
mkjson() {  # mkjson <tool> <field> <value> [cwd]
  python3 -c 'import json,sys; d={"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}
if len(sys.argv)>4: d["cwd"]=sys.argv[4]
print(json.dumps(d))' "$@"
}
feed() {  # feed <hook> <stdin text> [env assignments...] -> prints "rc=N" then stderr
  local hook=$1 input=$2 err rc; shift 2
  err="$(printf '%s' "$input" | env -i PATH="$PATH" HOME="$HOME" KIT_HOOKS_CHECK_ONLY=1 "$@" python3 -I "$hook" 2>&1 >/dev/null)"; rc=$?
  printf 'rc=%s %s' "$rc" "$err"
}
finish() { echo "$1: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }
