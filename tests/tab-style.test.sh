#!/usr/bin/env bash
# Tests for the Windows Terminal tab style: the distro's profile (-p) and one tab color per repo (--tabColor),
# set by `tab_profile:` / `tab_color:` in the team block. Run: bash tests/tab-style.test.sh (dry runs, sandboxed)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/scripts/start-team.sh"
case "$ROOT" in *[[:space:]]*) echo "tab-style: SKIP (the kit's path has a space: $ROOT)"; exit 0 ;; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
FAKE_WT="$TMP/fake-wt.exe"; : > "$FAKE_WT"
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
for t in wt.exe powershell.exe cmd.exe osascript tmux; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 99\n' "$t" "$TMP/REAL-TOOL-CALLED" > "$STUBS/$t"; chmod +x "$STUBS/$t"
done
lrun() { env HOME="$TMP" WSL_DISTRO_NAME=TestDistro WSL_INTEROP= TMUX= "WT_EXE=$FAKE_WT" "PATH=$STUBS:$PATH" "$@"; }
mkrepo() { mkdir -p "$1/docs/orchestration"; git -C "$1" init -q; [ -z "${2:-}" ] || printf 'team:\n%b' "$2" > "$1/docs/orchestration/ORCHESTRATION.md"; }
st() { lrun bash "$ST" --dry-run --terminal "${T:-wsl-wt}" --repo "$1" --seat ZzSeat --siblings 1 --prefix ZzSib 2>&1; }
color_of() { printf '%s\n' "$1" | grep -o -- '--tabColor \\\{0,1\}#[0-9a-fA-F]\{6\}' | head -1 | sed 's/.*#/#/'; }

# 1. Defaults on wsl-wt: the distro's profile, and a tab color.
A="$TMP/a"; mkrepo "$A"
out="$(st "$A")"
has "default profile is the distro" "new-tab -p TestDistro --title ZzSeat" "$out"
ca="$(color_of "$out")"; [ -n "$ca" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL no --tabColor in: $out"; }
# every tab of one launch gets the same color
n="$(printf '%s\n' "$out" | grep -o -- "--tabColor \\\\$ca" | wc -l | tr -d ' ')"; [ "$n" -ge 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL want the seat and sibling on $ca, got $n tab(s)"; }
# 2. The color is remembered for the repo, and another repo gets a different one.
out="$(st "$A")"; [ "$(color_of "$out")" = "$ca" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL color changed on re-run: $ca -> $(color_of "$out")"; }
B="$TMP/b"; mkrepo "$B"; cb="$(color_of "$(st "$B")")"
[ -n "$cb" ] && [ "$cb" != "$ca" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL second repo color '$cb' should differ from '$ca'"; }
has "colors recorded" "$A" "$(cat "$TMP/.orchestration-kit/runtime/tab-colors")"
# The record's format is a contract (other tools read it): one "<repo path><TAB>#rrggbb" line per repo.
grep -qxF "$(printf '%s\t%s' "$A" "$ca")" "$TMP/.orchestration-kit/runtime/tab-colors" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL want the line '$A<TAB>$ca' in: $(cat "$TMP/.orchestration-kit/runtime/tab-colors")"; }
[ "$(grep -c . "$TMP/.orchestration-kit/runtime/tab-colors")" = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL want one line per repo (2) in: $(cat "$TMP/.orchestration-kit/runtime/tab-colors")"; }
# A recycled sibling's tab gets its repo's color too.
out="$(lrun bash "$ROOT/scripts/recycle-sibling.sh" ZzSib1 --dry-run --terminal wsl-wt --repo "$A" 2>&1)"
has "recycle: same tab color" "--tabColor \\$ca" "$out"; has "recycle: the session is told its color" "CLAUDE_TAB_COLOR=$ca" "$out"
# 3. The team block overrides: a fixed color and profile, or none.
C="$TMP/c"; mkrepo "$C" '  tab_profile:      Ubuntu-22.04\n  tab_color:        #123456\n'
out="$(st "$C")"; has "fixed profile" "-p Ubuntu-22.04" "$out"; has "fixed color" "--tabColor \\#123456" "$out"
# The tab tells its session its color (the HUD's dot) and that Windows Terminal draws 24-bit color.
has "tab color reaches the session" "CLAUDE_TAB_COLOR=#123456" "$out"; has "truecolor declared" "COLORTERM=truecolor" "$out"
D="$TMP/d"; mkrepo "$D" '  tab_profile:      none\n  tab_color:        none\n'
out="$(st "$D")"; hasnt "profile none" "new-tab -p" "$out"; hasnt "color none" "--tabColor" "$out"; hasnt "no color, no CLAUDE_TAB_COLOR" "CLAUDE_TAB_COLOR" "$out"
E="$TMP/e"; mkrepo "$E" '  tab_color:        red;evil\n'
out="$(st "$E")"; hasnt "invalid color ignored (not passed through)" "red;evil" "$out"
# 4. Other backends are unchanged.
out="$(T=tmux st "$A")"; hasnt "tmux: no wt flags" "--tabColor" "$out"; hasnt "tmux: no tab color" "CLAUDE_TAB_COLOR" "$out"

if [ -e "$TMP/REAL-TOOL-CALLED" ]; then fail=$((fail+1)); echo "FAIL a real-tool stand-in was executed: $(cat "$TMP/REAL-TOOL-CALLED")"; else pass=$((pass+1)); fi
echo "tab-style: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
