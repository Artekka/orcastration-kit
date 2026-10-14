#!/usr/bin/env bash
# hud-guide.sh — the status HUD's setup page: every item numbered on a picture, Keep / Remove for each,
# the dot choice, and "Copy my choices" (orchestration-kit). kit-init offers it after installing the HUD.
#
# Usage:
#   hud-guide.sh open             open the page in your browser, set to your current HUD settings
#   hud-guide.sh apply '<line>'   save the line the page copied ("Apply my status HUD choices ...: {...}") to the HUD's settings
#   hud-guide.sh build            (kit developers) rebuild docs/status-hud-guide.html from the HUD's drawing code
#   hud-guide.sh check            (tests) exit 1 when docs/status-hud-guide.html is out of date
# open and apply use `claude plugin configure status-hud@artekka-kits` (CLAUDE_CONFIG_DIR picks the account).
# apply accepts only dotMode and hideItems with known item ids (the items this HUD draws); options it is not
# given keep their values. build and check need node 22.18 or later.
# Exit 0 done, 1 failed or refused, 64 usage.
set -uo pipefail

KIT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HUD="$KIT/plugins/status-hud"
PAGE="$KIT/docs/status-hud-guide.html"
PLUGIN="status-hud@artekka-kits"
usage() { sed -n '5,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

# render <preset json|null>: the page, with the guide data and the preset filled in, on stdout
render() {
  local data
  data="$(cd "$HUD/scripts" && node --no-warnings --experimental-transform-types --import ./ts-resolve.mjs guide.ts)" || { echo "hud-guide: node could not draw the HUD (needs node 22.18+)" >&2; return 1; }
  DATA="$data" PRESET="$1" python3 -c '
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("/*__GUIDE_DATA__*/null", os.environ["DATA"]).replace("/*__PRESET__*/null", os.environ["PRESET"])
sys.stdout.write(t)' "$HUD/scripts/guide-template.html"
}
ids() { sed -n "s/^  { id: '\([a-z0-9-]*\)'.*/\1/p" "$HUD/scripts/guide.ts"; }

case "${1:-}" in
  build) render null > "$PAGE.tmp" && mv "$PAGE.tmp" "$PAGE" && echo "wrote $PAGE" ;;
  check)
    render null > "${TMPDIR:-/tmp}/hud-guide.$$" || exit 1
    if cmp -s "${TMPDIR:-/tmp}/hud-guide.$$" "$PAGE"; then rm -f "${TMPDIR:-/tmp}/hud-guide.$$"; echo "hud-guide: up to date"
    else rm -f "${TMPDIR:-/tmp}/hud-guide.$$"; echo "hud-guide: docs/status-hud-guide.html is out of date; run: bash scripts/hud-guide.sh build" >&2; exit 1; fi ;;
  open)
    out="${KIT_RUNTIME_DIR:-$HOME/.orchestration-kit/runtime}/hud-guide.html"; mkdir -p "$(dirname "$out")"
    preset="$(claude plugin configure "$PLUGIN" --json 2>/dev/null | python3 -c '
import json, sys
try: i = json.load(sys.stdin).get("inputs", {})
except Exception: print("null"); sys.exit()
print(json.dumps({k: i.get(k, "") for k in ("dotMode", "hideItems")}))' 2>/dev/null)"
    [ -n "$preset" ] || preset=null
    # The shipped page with the preset swapped in: no node needed on the user's machine.
    PRESET="$preset" python3 -c '
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
sys.stdout.write(t.replace("const PRESET = null;", "const PRESET = " + os.environ["PRESET"] + ";", 1))' "$PAGE" > "$out" || exit 1
    echo "The HUD setup page: $out"
    if command -v wslpath >/dev/null 2>&1 && command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$(wslpath -w "$out")" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then open "$out"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$out" >/dev/null 2>&1 &
    else echo "Open that file in your browser."; fi ;;
  apply)
    [ $# -ge 2 ] || usage
    vals="$(LINE="$2" IDS="$(ids | tr '\n' ',')" python3 -c '
import json, os, sys
line = os.environ["LINE"].strip()
if "{" in line: line = line[line.index("{"):]  # the line from the page starts with what to do with it
try: v = json.loads(line)
except Exception: sys.exit("not a HUD choices line: " + os.environ["LINE"][:80])
known = set(filter(None, os.environ["IDS"].split(",")))
out = {}
for k, x in v.items():
    if k == "dotMode" and x in ("account", "project"): out[k] = x
    elif k == "hideItems" and isinstance(x, str):
        bad = [i for i in x.split(",") if i and i not in known]
        if bad: sys.exit("unknown item ids: " + ",".join(bad))
        out[k] = x
    else: sys.exit("not a HUD choice: %s=%r" % (k, x))
print(json.dumps(out))')" || exit 1
    printf '%s' "$vals" | claude plugin configure "$PLUGIN" --values-stdin || { echo "hud-guide: claude plugin configure failed (its message is above)" >&2; exit 1; }
    echo "Saved: $vals. The HUD redraws with it from each session's next start." ;;
  *) usage ;;
esac
