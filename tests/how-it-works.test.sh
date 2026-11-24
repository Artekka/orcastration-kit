#!/usr/bin/env bash
# HOW-IT-WORKS.md and docs/how-it-works.html: the "tour" guide (kit v0.8).
# A guide that drifts from the kit is worse than none, so this pins:
#   (1) both files exist and are private-free (no project, person, path or account that is not the kit's);
#   (2) the MD carries ONE Mermaid flowchart of the whole loop;
#   (3) every system has a section with the three labels (What it does / Why it exists / The knob),
#       in the MD AND in the HTML (same slugs), and a "Make it your own flavor" section with a worked example;
#   (4) the HTML is self-contained (opens from disk: no CDN, no external script/style/font) and has a
#       dark default + light toggle;
#   (5) doc-drift: every kit path and every team-block key the guide names exists in the tree.
# Sections still waiting on a parallel v0.8 item carry a `> verify at merge` marker (MD) / class="pending"
# (HTML); the marker counts must match, and PENDING below lists the paths those sections may name before
# the reconcile pass. Run: bash tests/how-it-works.test.sh   (needs bash, python3; no network)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

# slug|heading: the systems the guide must explain, in this order. The HTML section id is the slug.
SECTIONS=(
  "seat-board|The seat, the board and one allocator"
  "briefs|Briefs and the lean start"
  "worktrees|Worktrees and fences"
  "gate|Tests first, the gate and the throttle"
  "read|Independent READ and falsify"
  "trains|Release trains and the deploy policy"
  "context|Context guard, retro and recycle"
  "accounts|Multi-account and the session cap"
  "questions|Non-blocking questions"
  "hud|The status HUD"
)
# Paths a "verify at merge" section may name before the parallel items land (remove entries at reconcile).
PENDING=()
# Team-block keys the guide must explain AND templates/ORCHESTRATION.md must define.
KEYS=(worktrees git_guard ctx_guard context_window gate_slots permission_mode model effort terminal)

MD="$ROOT/HOW-IT-WORKS.md"; HTML="$ROOT/docs/how-it-works.html"

# ---- (1) exist + private-free ----------------------------------------------------------------
[ -f "$MD" ]   && ok || bad "HOW-IT-WORKS.md missing"
[ -f "$HTML" ] && ok || bad "docs/how-it-works.html missing"
if [ -f "$MD" ] && [ -f "$HTML" ]; then
  # The brief's private list, plus machine paths and account-ish strings. Case-insensitive.
  priv='einherjar|camelot|artekkaos|darkage|dark age|tekkaman|/home/[a-z0-9._-]+/|/mnt/[a-z]/|discord|gamelabs|@gmail|@artekka|session_0|claude\.ai/code|\bart\b|pnpm gate|\bOrca\b'
  # the public marketplace id (plugin@artekka-kits) is the one allowed use of the handle
  hits="$(sed 's/@artekka-kits//g' "$MD" "$HTML" | grep -n -i -E "$priv" | head -5)"
  [ -z "$hits" ] && ok || bad "private strings in the guide: $hits"
  # US English (the kit's own text is US): the usual British spellings, none allowed.
  brit="$(sed 's/aria-labelledby//g' "$MD" "$HTML" | grep -n -i -E '\b(colour|behaviour|favour|centre|grey|defence|honour|licence|organis|analys(e|ing)\b|cancelled|labelled|modelled|catalogue)' | head -3)"
  [ -z "$brit" ] && ok || bad "British spelling: $brit"
fi
[ -f "$MD" ] && [ -f "$HTML" ] || { echo "RESULT pass=$pass fail=$fail"; exit 1; }

# ---- (2) one Mermaid flowchart -----------------------------------------------------------------
mer="$(python3 - "$MD" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
blocks = re.findall(r"```mermaid\n(.*?)```", t, re.S)
print(f"BLOCKS {len(blocks)}")
if len(blocks) == 1:
    b = blocks[0]
    print("FLOWCHART" if re.match(r"\s*(flowchart|graph)\s", b) else "NOTFLOW")
    print(f"EDGES {len(re.findall(r'-->|-\.->|==>', b))}")
    low = b.lower()
    for w in ("seat", "board", "worktree", "builder", "validator", "train", "gate", "deploy", "recycle"):
        if w not in low: print(f"MISSING {w}")
PY
)"
echo "$mer" | grep -q '^BLOCKS 1$' && ok || bad "want exactly one mermaid block: $(echo "$mer" | head -1)"
echo "$mer" | grep -q '^FLOWCHART$' && ok || bad "mermaid block is not a flowchart/graph"
e="$(echo "$mer" | sed -n 's/^EDGES //p')"; [ "${e:-0}" -ge 9 ] && ok || bad "mermaid flowchart has ${e:-0} edges, want >= 9 (the whole loop)"
echo "$mer" | grep -q '^MISSING' && bad "mermaid flowchart lacks: $(echo "$mer" | grep '^MISSING' | tr '\n' ' ')" || ok

# ---- (3) per-system sections ------------------------------------------------------------------
LABELS=("What it does" "Why it exists" "The knob")
for row in "${SECTIONS[@]}"; do
  slug="${row%%|*}"; title="${row#*|}"
  out="$(python3 - "$MD" "$HTML" "$slug" "$title" <<'PY'
import re, sys
md, html, slug, title = open(sys.argv[1], encoding="utf8").read(), open(sys.argv[2], encoding="utf8").read(), sys.argv[3], sys.argv[4]
labels = ["What it does", "Why it exists", "The knob"]
# MD: a `### <title>` heading (a trailing "(optional)"-style suffix is allowed), body up to the next ##/###.
m = re.search(r"^###\s+" + re.escape(title) + r"[^\n]*\n(.*?)(?=^##|\Z)", md, re.S | re.M)
if not m: print("MD-NO-SECTION")
else:
    for l in labels:
        if not re.search(r"^\*\*" + re.escape(l) + r":?\*\*", m.group(1), re.M): print("MD-NO-LABEL " + l)
    if re.search(r"^> verify at merge$", m.group(1), re.M): print("MD-PENDING")
# HTML: <section id="slug" ...> ... </section>
h = re.search(r'<section[^>]*\bid="' + re.escape(slug) + r'"([^>]*)>(.*?)</section>', html, re.S)
if not h: print("HTML-NO-SECTION")
else:
    for l in labels:
        if l not in h.group(2): print("HTML-NO-LABEL " + l)
    if title not in re.sub(r"<[^>]+>", "", h.group(2)): print("HTML-NO-TITLE")
    if 'pending' in h.group(1) or 'class="pending' in h.group(0)[:300]: print("HTML-PENDING")
PY
)"
  if echo "$out" | grep -q '^MD-NO\|^HTML-NO'; then bad "section $slug: $(echo "$out" | grep '^MD-NO\|^HTML-NO' | tr '\n' ';')"; else ok; fi
  # the pending marker must agree between the two renderings
  a="$(echo "$out" | grep -c '^MD-PENDING')"; b="$(echo "$out" | grep -c '^HTML-PENDING')"
  [ "$a" = "$b" ] && ok || bad "section $slug: verify-at-merge marker only in one of MD($a)/HTML($b)"
done

for must in "## Make it your own flavor" "### What to tune first" "### What is safe to drop" "### Add your own rule, skill or hook" "## The honest version" "## Why merges stay clean"; do
  grep -q -F "$must" "$MD" && ok || bad "HOW-IT-WORKS.md lacks the heading '$must'"
done
# the worked example: a fenced block inside "Add your own rule, skill or hook"
python3 - "$MD" <<'PY' && ok || bad "no fenced worked example under 'Add your own rule, skill or hook'"
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
m = re.search(r"^### Add your own rule, skill or hook\n(.*?)(?=^##|\Z)", t, re.S | re.M)
sys.exit(0 if m and "```" in m.group(1) else 1)
PY
for must in "Make it your own flavor" "What to tune first" "What is safe to drop" "Add your own rule, skill or hook" "The honest version" "Why merges stay clean"; do
  grep -q -F "$must" "$HTML" && ok || bad "how-it-works.html lacks '$must'"
done

# ---- (4) HTML is self-contained, dark default + light toggle ---------------------------------
ext="$(grep -n -i -E '(src|href)="https?:|@import|url\(\s*["'"'"']?https?:|<script[^>]*\ssrc=|<link[^>]*rel="stylesheet"' "$HTML" | head -3)"
[ -z "$ext" ] && ok || bad "how-it-works.html is not self-contained: $ext"
grep -q -i '<meta name="viewport"' "$HTML" && ok || bad "how-it-works.html has no viewport meta (phones)"
grep -q '<html[^>]*data-theme="dark"' "$HTML" && ok || bad "how-it-works.html: <html> must carry data-theme=\"dark\" (dark is the default; light is the option)"
grep -q 'id="theme-toggle"' "$HTML" && ok || bad "how-it-works.html has no #theme-toggle button"
python3 - "$HTML" <<'PY' && ok || bad "how-it-works.html: default theme is not dark (a :root dark palette first, [data-theme=light] second)"
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
a, b = t.find(":root{"), t.find('[data-theme="light"]')
sys.exit(0 if a >= 0 and b > a else 1)
PY
grep -q '<svg' "$HTML" && ok || bad "how-it-works.html has no inline SVG diagram"

# ---- (5) doc-drift: named paths and keys exist ------------------------------------------------
drift="$(python3 - "$ROOT" "$MD" "${PENDING[@]:-}" <<'PY'
import os, re, sys
root, md = sys.argv[1], sys.argv[2]
pending = {p for p in sys.argv[3:] if p}
t = open(md, encoding="utf8").read()
seen = set()
for tok in re.findall(r"`([^`\n]+)`", t):
    tok = tok.strip().split()[0] if tok.strip() else ""
    m = re.match(r"^((?:scripts|skills|hooks|templates|docs|tests|extras|agents|plugins)/[A-Za-z0-9_./-]+)$", tok)
    if not m or "<" in tok: continue
    p = m.group(1).rstrip("/.")
    if p.startswith("docs/orchestration/"):
        # the CONSUMING repo's layout: not a kit file, but the kit must install/name it
        base = os.path.basename(p)
        found = any(base in open(os.path.join(d, f), encoding="utf8", errors="ignore").read()
                    for top in ("skills", "scripts", "templates", "hooks")
                    for d, _, fs in os.walk(os.path.join(root, top)) for f in fs)
        if not found: print("UNKNOWN-CONSUMER-PATH " + p)
        continue
    if p in seen: continue
    seen.add(p)
    if not os.path.exists(os.path.join(root, p)) and p not in pending:
        print("MISSING-PATH " + p)
for l in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", t):
    if re.match(r"^[a-z]+:", l): continue
    if not os.path.exists(os.path.join(os.path.dirname(md), l)): print("BROKEN-LINK " + l)
print(f"PATHS {len(seen)}")
PY
)"
echo "$drift" | grep -q '^MISSING-PATH\|^BROKEN-LINK\|^UNKNOWN-CONSUMER' && bad "$(echo "$drift" | grep '^MISSING-PATH\|^BROKEN-LINK\|^UNKNOWN-CONSUMER' | tr '\n' ' ')" || ok
n="$(echo "$drift" | sed -n 's/^PATHS //p')"; [ "${n:-0}" -ge 12 ] && ok || bad "doc-drift scan saw only ${n:-0} paths (expected 12+): the guide names too few kit files, or the scan is blind"
for k in "${KEYS[@]}"; do
  grep -q -E "^[[:space:]]+$k:|\`$k\`" "$ROOT/templates/ORCHESTRATION.md" && ok || bad "key '$k' is not defined in templates/ORCHESTRATION.md"
  grep -q -F "\`$k\`" "$MD" && ok || bad "HOW-IT-WORKS.md never names the knob \`$k\`"
done

# ---- (f) the marker and the allowlist cannot drift apart ----------------------------------------
# Reconcile empties PENDING and removes every marker. A marker left behind with an empty allowlist
# means a section was never verified; an allowlist entry left with no marker is a dead exception.
nm="$(grep -c -x '> verify at merge' "$MD")"; nh="$(grep -o '<\(section\|p\)[^>]*data-pending="true"' "$HTML" | wc -l | tr -d ' ')"
if [ "${#PENDING[@]}" -eq 0 ]; then
  [ "$nm" -eq 0 ] && ok || bad "(f) $nm 'verify at merge' marker(s) remain in HOW-IT-WORKS.md but the PENDING allowlist is empty"
  [ "$nh" -eq 0 ] && ok || bad "(f) $nh data-pending element(s) remain in the HTML but the PENDING allowlist is empty"
else
  [ "$nm" -gt 0 ] && ok || bad "(f) PENDING lists ${#PENDING[@]} path(s) but no 'verify at merge' marker is left: empty the list"
fi
# no pending styling is left in either diagram rendering
grep -q 'classDef pending\|class [a-z]* pending' "$MD" || grep -q 'box [a-z ]*pending' "$HTML" && bad "(f) pending diagram styling remains" || ok
# every marker in the MD has its twin in the HTML, and the other way round
[ "$nm" = "$nh" ] && ok || bad "(f) $nm '> verify at merge' marker(s) in the MD but $nh data-pending element(s) in the HTML"

# ---- (i) small pins: registration snippet parses; recycle claim is qualified; links are real ------
python3 - "$MD" <<'PY' && ok || bad "(i) the registration snippet under 'Add your own' is missing or is not valid JSON that names the hook"
import json, re, sys
t = open(sys.argv[1], encoding="utf8").read()
m = re.search(r"^### Add your own rule, skill or hook\n(.*?)(?=^##|\Z)", t, re.S | re.M)
b = re.search(r"```json\n(.*?)```", m.group(1), re.S) if m else None
d = json.loads(b.group(1))
cmd = d["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
sys.exit(0 if d["hooks"]["PreToolUse"][0]["matcher"] == "Bash" and "no-push-main.sh" in cmd else 1)
PY
python3 - "$MD" <<'PY' && ok || bad "(i) the recycle claim must say 'same tab' only under the sibling-shell wrapper, else a new window"
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
m = re.search(r"^### Context guard, retro and recycle\n(.*?)(?=^###|^## |\Z)", t, re.S | re.M)
b = m.group(1) if m else ""
sys.exit(0 if "same tab" in b and "sibling-shell.sh" in b and "new window" in b else 1)
PY
python3 - "$HTML" "$ROOT/docs" <<'PY' && ok || bad "(i) 'Where to go next' in the HTML must be real links to files that exist next to it"
import os, re, sys
t = open(sys.argv[1], encoding="utf8").read()
m = re.search(r'<section id="next">(.*?)</section>', t, re.S)
hrefs = re.findall(r'<a href="([^"#]+)"', m.group(1)) if m else []
sys.exit(0 if len(hrefs) >= 4 and all(os.path.exists(os.path.join(sys.argv[2], h)) for h in hrefs) else 1)
PY
# one arrow per builder ends on the validator's top edge (y=332, left column)
n="$(grep -c 'class="arrow" d="M[0-9]* 278[^"]*V332"' "$HTML")"
[ "$n" -ge 3 ] && ok || bad "(i) the SVG draws $n builder arrow(s) into the validator, want 3 (every builder)"
# the worked example's hook is opt-in (the .kit-hooks marker), never a default
grep -q '\.kit-hooks' "$MD" && ok || bad "the guide never mentions the opt-in .kit-hooks marker"

# ---- (g) the worked example hook really works: deny a push to main, silent otherwise, opt-in -----
ex="$(python3 - "$MD" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
m = re.search(r"^### Add your own rule, skill or hook\n(.*?)(?=^##|\Z)", t, re.S | re.M)
b = re.search(r"```bash\n(.*?)```", m.group(1), re.S) if m else None
print(b.group(1) if b else "", end="")
PY
)"
if [ -z "$ex" ]; then bad "(g) no bash example found"; else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  printf '%s\n' "$ex" > "$TMP/hook.sh"
  git -C "$TMP" init -q repo 2>/dev/null
  runhook() { printf '{"tool_input":{"command":"%s"}}' "$1" | (cd "$TMP/repo" && bash "$TMP/hook.sh") 2>&1; }
  out="$(runhook 'git push origin main')"; echo "$out" | grep -q '"permissionDecision":"deny"' && bad "(g) denied without the opt-in marker" || ok
  mkdir -p "$TMP/repo/docs/orchestration" && : > "$TMP/repo/docs/orchestration/.kit-hooks"
  git -C "$TMP/repo" symbolic-ref HEAD refs/heads/feature-x
  runhook() { printf '{"tool_input":{"command":"%s"}}' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" | (cd "$TMP/repo" && bash "$TMP/hook.sh") 2>&1; }
  for c in 'git push origin main' 'git push -u origin main' 'git push origin HEAD:main' 'git push origin +main' \
           'git push origin HEAD:refs/heads/main' 'git push origin :main' 'git push --force-with-lease origin main' \
           'cd sub && git push origin main' 'git status; git push origin main' 'git add x | git push origin main'; do
    out="$(runhook "$c")"; echo "$out" | grep -q '"permissionDecision":"deny"' && ok || bad "(g) did not deny: $c"
  done
  for c in 'git push origin feature-x' 'git push origin feat/main-menu' 'git status' 'echo maintain' \
           'git push origin feat-x && git checkout main' 'git push origin feat-x; git log main' 'git push origin feat-x | tee main' \
           'git commit -m "git push origin main"' 'git commit -m "x && git push origin main"' 'echo "git push origin main"' \
           'git push' 'git push -u origin' ; do
    out="$(runhook "$c")"; [ -z "$out" ] && ok || bad "(g) blocked a harmless command: $c -> $out"
  done
  # a bare `git push` from main pushes main: that one must deny
  git -C "$TMP/repo" symbolic-ref HEAD refs/heads/main
  out="$(runhook 'git push')"; echo "$out" | grep -q '"permissionDecision":"deny"' && ok || bad "(g) bare git push from main was not denied"
  out="$(runhook 'git push -u origin')"; echo "$out" | grep -q '"permissionDecision":"deny"' && ok || bad "(g) git push -u origin from main was not denied"
  out="$(runhook 'git push origin HEAD')"; echo "$out" | grep -q '"permissionDecision":"deny"' && ok || bad "(g) git push origin HEAD from main was not denied"
  git -C "$TMP/repo" symbolic-ref HEAD refs/heads/feature-x
  out="$(runhook 'git push origin HEAD')"; [ -z "$out" ] && ok || bad "(g) git push origin HEAD from a feature branch was blocked: $out"
fi

# ---- (j) the recycle-refusal knob is documented with the code's real default ---------------------
def="$(sed -n 's/.*LAUNCH_LIVE_RECHECK:-\([0-9.]*\)}.*/\1/p' "$ROOT/scripts/lib-launch.sh" | head -1)"
[ -n "$def" ] && ok || bad "(j) could not read the LAUNCH_LIVE_RECHECK default from scripts/lib-launch.sh"
for f in "$MD" "$HTML"; do
  # the knob name and its default in ONE sentence (no period between them), so neither can drift apart
  grep -qE "LAUNCH_LIVE_RECHECK[^.]*default ${def//./\\.}\)" "$f" && ok || bad "(j) $f must say LAUNCH_LIVE_RECHECK ... (default $def) in one sentence (the code's default)"
done

# ---- (k) the loop diagram: a stacked variant for narrow screens, and no label sitting on an arrow --
python3 - "$HTML" <<'PY' && ok || bad "(k) loop diagram: see the message above"
import re, sys
h = open(sys.argv[1], encoding="utf8").read()
svgs = re.findall(r'<svg class="(wide|tall)"[^>]*>(.*?)</svg>', h, re.S)
kinds = [k for k, _ in svgs]
if sorted(kinds) != ["tall", "wide"]: print("want one wide and one tall SVG, got", kinds); sys.exit(1)
body = dict(svgs)
nw, nt = (len(re.findall(r'<g class="box ', body[k])) for k in ("wide", "tall"))
if nw != nt: print(f"the tall diagram has {nt} boxes, the wide one {nw}: every node must appear in both"); sys.exit(1)
if not re.search(r'@media \(max-width:\d+px\)\{[^}]*svg\.wide\{display:none\}[^}]*svg\.tall\{display:block\}', h): print("no media rule swaps the wide diagram for the tall one"); sys.exit(1)
if re.search(r'svg\.wide\{[^}]*min-width', h) is None: print("the wide diagram lost its min-width"); sys.exit(1)
if re.search(r'\.diagram svg\{[^}]*min-width', h): print("a min-width on every diagram SVG pushes the tall one past a phone screen"); sys.exit(1)
# no italic note label overlaps a drawn arrow segment (M/H/V paths only)
for kind, b in svgs:
    segs = []
    for d in re.findall(r'<path class="arrow[^"]*" d="([^"]+)"', b):
        x = y = 0
        for c, v in re.findall(r'([MHV])\s*(-?[\d.]+)', d):
            v = float(v)
            if c == "M": x = v; y = float(re.search(r'M\s*-?[\d.]+\s*(-?[\d.]+)', d).group(1)); continue
            nx, ny = (v, y) if c == "H" else (x, v)
            segs.append((min(x, nx), min(y, ny), max(x, nx), max(y, ny))); x, y = nx, ny
    for m in re.finditer(r'<text x="([\d.]+)" y="([\d.]+)" class="note"( text-anchor="(\w+)")?>([^<]+)</text>', b):
        x, y, anc, s = float(m.group(1)), float(m.group(2)), m.group(4) or "start", m.group(5)
        w = sum(9 if ch.isupper() else 6.5 for ch in s); l = x - w if anc == "end" else x - w / 2 if anc == "middle" else x
        box = (l, y - 12, l + w, y + 3)
        for a in segs:
            if a[0] <= box[2] and a[2] >= box[0] and a[1] <= box[3] and a[3] >= box[1]:
                print(f"{kind} diagram: the label '{s}' overlaps an arrow segment {a}"); sys.exit(1)
PY

echo "RESULT pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
