#!/usr/bin/env bash
# Tests for scripts/hud-guide.sh: the status HUD's setup page (built from the HUD's own drawing code), opening it
# set to the current settings, and applying the line it copies. Run: bash tests/hud-guide.test.sh
# Sandboxed: `claude`, explorer.exe, wslpath, open and xdg-open are stand-ins; no browser opens, no setting changes.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; G="$ROOT/scripts/hud-guide.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
rc_is() { [ "$2" = "$3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: want exit $2, got $3"; }; }
B="$TMP/bin"; mkdir -p "$B"
cat > "$B/claude" <<EOF
#!/usr/bin/env bash
if [ "\$*" = "plugin configure status-hud@artekka-kits --json" ]; then
  echo '{"inputs":{"dotMode":"project","hideItems":"history,dot-key","variant":"band"}}'
elif [ "\$*" = "plugin configure status-hud@artekka-kits --values-stdin" ]; then cat > "$TMP/configured"
else echo "unexpected: \$*" >> "$TMP/unexpected"; exit 9; fi
EOF
for t in explorer.exe wslpath open xdg-open; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/opened"\n' "$t" "$TMP" > "$B/$t"; done
chmod +x "$B"/*
g() { env PATH="$B:$PATH" HOME="$TMP" KIT_RUNTIME_DIR="$TMP/rt" bash "$G" "$@" 2>&1; }

# The shipped page is current with the HUD's drawing code (needs node 22.18+ to rebuild; skipped without).
if node --experimental-transform-types -e 0 >/dev/null 2>&1; then
  out="$(g check)"; rc_is "page is up to date (else: bash scripts/hud-guide.sh build)" 0 $?
else echo "hud-guide: SKIP the up-to-date check (node without --experimental-transform-types)"; fi
P="$ROOT/docs/status-hud-guide.html"; page="$(cat "$P")"
hasnt "page has its data" "/*__GUIDE_DATA__*/null" "$page"
has "page ships with no preset" "const PRESET = null;" "$page"
# Every item in the README's Items table is in the guide, and every guide item has a description.
for id in $(sed -n 's/^| \(Host\|Sessions\|Chips\) | \(.*\) |$/\2/p' "$ROOT/plugins/status-hud/README.md" | tr -d '`' | tr ',' ' '); do
  has "README item $id is in the guide" "\"id\":\"$id\"" "$page"
done
# ...and the other way: the page offers only items this HUD draws (ids the README lists), and no option it lacks.
readme_ids=" $(sed -n 's/^| \(Host\|Sessions\|Chips\) | \(.*\) |$/\2/p' "$ROOT/plugins/status-hud/README.md" | tr -d '`' | tr ',\n' '  ' | tr -s ' ') "
for id in $(grep -o '"id":"[a-z0-9-]*"' "$P" | sed 's/"id":"\(.*\)"/\1/' | sort -u); do
  has "guide item $id is a README item" " $id " "$readme_ids"
done
for gone in face cpu-mark perm-mode gates queue holding extra live next; do
  hasnt "the page does not offer $gone (not in this HUD)" "\"id\":\"$gone\"" "$page"
done
for opt in sessionFaces headerIcon; do hasnt "the page does not offer $opt" "$opt" "$page"; done
# Every item but the second disk (no room beside the GPU meters) is placed on the picture.
python3 - "$P" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL some items have no place on the picture"; }
import json, re, sys
d = json.loads(re.search(r'const DATA = (\{.*?\});\n', open(sys.argv[1], encoding='utf-8').read(), re.S).group(1))
missing = [i['id'] for i in d['items'] if not i['at'] and i['id'] != 'disk2']
sys.exit(1 if missing else 0) if not missing else (print('not placed:', missing), sys.exit(1))
PY

# open: a copy set to the current settings, opened in the browser.
out="$(g open)"; rc_is "open: exit 0" 0 $?
has "open: says where the page is" "$TMP/rt/hud-guide.html" "$out"
has "open: preset from the current settings" 'const PRESET = {"dotMode": "project", "hideItems": "history,dot-key"};' "$(cat "$TMP/rt/hud-guide.html")"
has "open: a browser was asked" "$TMP/rt/hud-guide.html" "$(cat "$TMP/opened" 2>/dev/null)"
hasnt "open: the shipped page is untouched" "history,dot-key" "$(cat "$P")"

# apply: only the HUD's choices, only known ids.
out="$(g apply 'Apply my status HUD choices (orchestration-kit: bash scripts/hud-guide.sh apply in the kit): {"dotMode":"project","hideItems":"context-key,history"}')"; rc_is "apply: exit 0" 0 $?
has "apply: sent to configure" '"hideItems": "context-key,history"' "$(cat "$TMP/configured")"
out="$(g apply '{"dotMode":"account","hideItems":""}')"; rc_is "apply: bare JSON works too" 0 $?
rm -f "$TMP/configured"
out="$(g apply 'HUD choices: {"hideItems":"cpu,nope"}')"; rc_is "apply: unknown id refused" 1 $?; has "names it" "nope" "$out"
out="$(g apply 'HUD choices: {"statusDir":"/tmp/x"}')"; rc_is "apply: other options refused" 1 $?
out="$(g apply 'HUD choices: {"sessionFaces":"on"}')"; rc_is "apply: options this HUD lacks refused" 1 $?
out="$(g apply 'hello')"; rc_is "apply: not a choices line" 1 $?
[ ! -e "$TMP/configured" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a refused line still reached configure"; }
[ ! -e "$TMP/unexpected" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL unexpected claude calls: $(cat "$TMP/unexpected")"; }

echo "hud-guide: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
