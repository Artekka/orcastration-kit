#!/usr/bin/env bash
# Tests for skills/orient-brief: brief.sh against real fixtures (a bare origin, a STALE clone that has not
# pulled the brief yet, a local-only brief, missing brief, bad row ids, no banner, no origin at all), and the
# skill's injected command, rendered with a row argument the way the loader renders it, then run.
# brief.sh must ALWAYS exit 0: the loader drops the whole skill on a non-zero exit.
# Run: bash tests/orient-brief.test.sh      (needs bash, git, awk, python3; no network)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; BS="$ROOT/skills/orient-brief/brief.sh"; SK="$ROOT/skills/orient-brief/SKILL.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }
run() {  # <dir> <row> → stdout+stderr; sets RC
  OUT="$(cd "$1" && bash "$BS" "$2" 2>&1)"; RC=$?
}

ORIGIN="$TMP/origin.git"; SEAT="$TMP/seat"; BUILDER="$TMP/builder"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$SEAT" 2>/dev/null
mkdir -p "$SEAT/docs/orchestration/briefs"
cat > "$SEAT/docs/orchestration/AGENT_BOARD.md" <<'BOARD'
# Board
## Archives
| a | b |
## (era-2 header, superseded) ORCHESTRATOR ACTIVE — **era-2 · Old**
- stale row
## 🎛 ORCHESTRATOR ACTIVE — **era-3 · Seat `[abc123]`** · prefix `S3-`
- row S3-1 → Sib1
## Protocol
- not part of the banner
BOARD
git -C "$SEAT" add -A && git -C "$SEAT" commit -qm board && git -C "$SEAT" push -q origin main 2>/dev/null
git clone -q "$ORIGIN" "$BUILDER" 2>/dev/null          # cloned BEFORE the brief exists: stale
printf '# S3-1 brief\nacceptance: the brief text\n' > "$SEAT/docs/orchestration/briefs/S3-1.md"
git -C "$SEAT" add -A && git -C "$SEAT" commit -qm brief && git -C "$SEAT" push -q origin main 2>/dev/null

# 1. a stale clone still gets the brief from origin, plus the live banner only
run "$BUILDER" S3-1
[ "$RC" = 0 ] && ok || bad "exit $RC on the happy path"
has "stale clone: the brief comes from origin" "acceptance: the brief text" "$OUT"
has "the live banner" "era-3 · Seat" "$OUT"
hasnt "never the superseded banner" "stale row" "$OUT"
hasnt "the banner stops at the next ## " "not part of the banner" "$OUT"
hasnt "no failure lines on the happy path" "NO B" "$OUT"
[ ! -e "$BUILDER/docs/orchestration/briefs/S3-1.md" ] && ok || bad "brief.sh changed the builder's working tree"

# 2. a brief only in this checkout (not pushed yet) is read from the working tree
printf 'local only brief\n' > "$BUILDER/local.md"; mkdir -p "$BUILDER/docs/orchestration/briefs"
cp "$BUILDER/local.md" "$BUILDER/docs/orchestration/briefs/L-1.md"
run "$BUILDER" L-1; has "local-only brief is read" "local only brief" "$OUT"

# 2b. the fix-round case: this checkout holds an OLDER copy of a brief that origin has since updated. Origin
#     must win (a local-first read would hand the builder the stale contract).
mkdir -p "$BUILDER/docs/orchestration/briefs"
printf '# S3-1 brief\nacceptance: STALE LOCAL COPY\n' > "$BUILDER/docs/orchestration/briefs/S3-1.md"
run "$BUILDER" S3-1
has "older local brief: origin's copy wins" "acceptance: the brief text" "$OUT"
hasnt "older local brief: the stale local text is not served" "STALE LOCAL COPY" "$OUT"
rm -f "$BUILDER/docs/orchestration/briefs/S3-1.md"

# 3. no brief anywhere: NO BRIEF, exit 0, banner still shown
run "$BUILDER" S3-404; [ "$RC" = 0 ] && ok || bad "missing brief: exit $RC"
has "missing brief says so" "NO BRIEF for S3-404" "$OUT"; has "missing brief: banner still shown" "era-3 · Seat" "$OUT"

# 4. bad row ids never reach git, exit 0
for r in "" "../etc/passwd" "a b" "x;id" "-rf" "'q"; do
  run "$BUILDER" "$r"; [ "$RC" = 0 ] && ok || bad "row [$r]: exit $RC"
  has "row [$r] refused" "NO BRIEF: bad or missing row id" "$OUT"
  hasnt "row [$r] printed no banner section" "=== BOARD BANNER" "$OUT"
done

# 5. a board with no live banner: NO BANNER
sed -i 's/^## 🎛 ORCHESTRATOR ACTIVE/## 🎛 (era-3 header, superseded) ORCHESTRATOR ACTIVE/' "$SEAT/docs/orchestration/AGENT_BOARD.md"
git -C "$SEAT" commit -qam retire && git -C "$SEAT" push -q origin main 2>/dev/null
run "$BUILDER" S3-1; has "only superseded banners: NO BANNER" "NO BANNER" "$OUT"; [ "$RC" = 0 ] && ok || bad "no banner: exit $RC"

# 6. no origin at all: FETCH FAILED, local brief + local board still served, exit 0
LONE="$TMP/lone"; git init -q -b main "$LONE"; mkdir -p "$LONE/docs/orchestration/briefs"
printf 'lone brief\n' > "$LONE/docs/orchestration/briefs/Z-1.md"
printf '## 🎛 ORCHESTRATOR ACTIVE — **era-1 · Lone**\n- r\n' > "$LONE/docs/orchestration/AGENT_BOARD.md"
run "$LONE" Z-1; [ "$RC" = 0 ] && ok || bad "no origin: exit $RC"
has "no origin: says the fetch failed" "FETCH FAILED" "$OUT"; has "no origin: local brief" "lone brief" "$OUT"
has "no origin: local board banner" "era-1 · Lone" "$OUT"

# 7. outside a git repo: NO BRIEF, exit 0
mkdir -p "$TMP/plain"; run "$TMP/plain" S3-1; [ "$RC" = 0 ] && ok || bad "outside git: exit $RC"
has "outside git says so" "not inside a git repository" "$OUT"

# 8. the skill's injected line, rendered with a row the way the loader does ($0 → the first argument,
#    ${CLAUDE_SKILL_DIR} → the skill's folder), then run from the stale clone after the board is restored
git -C "$SEAT" revert --no-edit HEAD >/dev/null && git -C "$SEAT" push -q origin main 2>/dev/null
inj="$(python3 - "$SK" "$ROOT/skills/orient-brief" <<'PY'
import re, sys
text, d = open(sys.argv[1], encoding="utf8").read(), sys.argv[2]
text = re.sub(r"\$(\d+)(?!\w)", lambda m: ["S3-1"][int(m.group(1))] if int(m.group(1)) < 1 else "", text)
text = text.replace("${CLAUDE_SKILL_DIR}", d)
m = re.search(r"^!`(.+)`$", text, re.M)
print(m.group(1) if m else "")
PY
)"
has "the skill has one injected command" "brief.sh" "$inj"
OUT="$(cd "$BUILDER" && bash -c "$inj" 2>&1)"
has "rendered skill: injects the brief" "acceptance: the brief text" "$OUT"
has "rendered skill: injects the live banner" "era-3 · Seat" "$OUT"
# allowed-tools must cover the injected command, or the loader's permission check blocks it
grep -q '^allowed-tools: Bash(bash \*orient-brief/brief.sh\*)' "$SK" && ok || bad "allowed-tools does not cover the injected brief.sh call"

echo "orient-brief: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
