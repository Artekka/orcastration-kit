#!/usr/bin/env bash
# Skill files must survive the skill loader. When a skill is invoked WITH arguments, Claude Code replaces
# `$ARGUMENTS`, `$ARGUMENTS[N]` and every `$N` (a dollar sign and digits) in the rendered SKILL.md with the
# arguments, including inside fenced shell and awk. The file on disk stays correct, so only the RENDERED
# text breaks: `/orchestration-kit:orient --brief ROW` once turned the banner awk's `$0` into "--brief",
# which matched no line and told the builder "no banner, no seat" on a live team.
# Two layers: (1) a static ban on positional tokens in every skill file, with an exact-count allowlist;
# (2) the shell blocks that use variables are RENDERED with arguments, as the loader does, and then run.
# Run: bash tests/skill-positional.test.sh      (needs bash, git, awk, python3; no network)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }

# ---- (1) static ban ---------------------------------------------------------------------------
# Banned: $N, ${N}, $@, $*, $ARGUMENTS, $ARGUMENTS[N]. ${N}, $@ and $* are not replaced by the loader
# today, but they are positionals all the same and the next loader may take them. Use named variables.
# ALLOW: "<path relative to the repo>=<exact count>" for a deliberate use (e.g. a skill that injects its
# own argument). An exact count, so a second, accidental use in the same file still fails.
ALLOW=(
  "skills/orient-brief/SKILL.md=2"   # $0 in the title and in the injected brief.sh call: the row id, on purpose
)
scan="$(cd "$ROOT" && python3 - "${ALLOW[@]}" <<'PY'
import os, re, sys
allow = dict(a.split("=", 1) for a in sys.argv[1:])
pat = re.compile(r"\$(?:\d|\{\d+\}|@|\*|ARGUMENTS)")
files = []
for top in ("skills", "extras", "plugins"):
    for d, _, fs in os.walk(top, followlinks=True):
        files += [os.path.join(d, f) for f in fs if f.endswith(".md") and "/skills/" in "/" + os.path.join(d, f)]
print(f"SCANNED {len(files)}")
for f in sorted(files):
    hits = [(i + 1, m.group(0)) for i, line in enumerate(open(f, encoding="utf8")) for m in pat.finditer(line)]
    want = int(allow.get(f, 0))
    if len(hits) != want:
        print(f"BAD {f}: {len(hits)} positional token(s), allowed {want}: " + ", ".join(f"{n}:{t}" for n, t in hits))
for f in allow:
    if not os.path.exists(f):
        print(f"STALE allowlist entry {f}: file missing")
PY
)"
n="$(printf '%s\n' "$scan" | sed -n 's/^SCANNED //p')"
[ "${n:-0}" -ge 10 ] && ok || bad "static: the scan saw only ${n:-0} skill files (expected 10+): the walk is blind"
if printf '%s\n' "$scan" | grep -q '^BAD\|^STALE'; then bad "static: $(printf '%s\n' "$scan" | grep '^BAD\|^STALE')"; else ok; fi

# ---- (2) render with arguments, then run -----------------------------------------------------------
# The loader's patterns: $ARGUMENTS[N] and $N take the Nth whitespace-separated argument (0-based),
# $ARGUMENTS takes them all.
render() {  # <skill file> <args string>  → the rendered text on stdout
  python3 - "$1" "$2" <<'PY'
import re, sys
text, args = open(sys.argv[1], encoding="utf8").read(), sys.argv[2]
parts = args.split()
pick = lambda m: parts[int(m.group(1))] if int(m.group(1)) < len(parts) else ""
text = re.sub(r"\$ARGUMENTS\[(\d+)\]", pick, text)
text = re.sub(r"\$ARGUMENTS", lambda m: args, text)
text = re.sub(r"\$(\d+)(?!\w)", pick, text)
sys.stdout.write(text)
PY
}

# 2a. orient lean step 2 (the banner awk), rendered with `--brief ROW-1`, against a live-shaped board.
render "$ROOT/skills/orient/SKILL.md" "--brief ROW-1" > "$TMP/orient.md"
step2="$(python3 - "$TMP/orient.md" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf8"):
    if line.startswith("| 2 |"):
        m = re.search(r"`(git show [^`]+)`", line)
        print(m.group(1).replace("\\|", "|") if m else "")
        break
PY
)"
has "orient: step 2 command extracted" "awk" "$step2"
REPO="$TMP/repo"; git init -q -b main "$REPO"; mkdir -p "$REPO/docs/orchestration"
cat > "$REPO/docs/orchestration/AGENT_BOARD.md" <<'BOARD'
# Board
## Archives
| a | b |
## (era-2 header, superseded) ORCHESTRATOR ACTIVE — **era-2**
- stale row
## 🎛 ORCHESTRATOR ACTIVE — **era-3 · Seat `[abc123]`** · prefix `S3-`
- row S3-1 → Sib1
BOARD
git -C "$REPO" add -A && git -C "$REPO" commit -qm board
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
out="$(cd "$REPO" && bash -c "$step2" 2>&1)"
has "orient rendered with args: step 2 still prints the live banner" "era-3 · Seat" "$out"
hasnt "orient rendered with args: step 2 skips the superseded header" "stale row" "$out"

# 2b. kit-init step 1 (copy what's missing), rendered with arguments, run in an empty repo.
block() {  # <rendered file> <marker text> → the first ```bash block after the marker
  python3 - "$1" "$2" <<'PY'
import sys
text, marker = open(sys.argv[1], encoding="utf8").read(), sys.argv[2]
i = text.index(marker); a = text.index("```bash\n", i) + 8; b = text.index("```", a)
print("\n".join(l[3:] if l.startswith("   ") else l for l in text[a:b].splitlines()))
PY
}
render "$ROOT/skills/kit-init/SKILL.md" "--yes team" > "$TMP/kit-init.md"
INIT="$TMP/init"; git init -q -b main "$INIT"
copy="$(block "$TMP/kit-init.md" "Copy what's missing")"
out="$(cd "$INIT" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$copy" 2>&1)"
has "kit-init rendered with args: creates the board" "CREATE docs/orchestration/AGENT_BOARD.md" "$out"
has "kit-init rendered with args: creates the brief template" "CREATE docs/orchestration/briefs/_TEMPLATE.md" "$out"
has "kit-init rendered with args: copies the scripts" "CREATE scripts/recycle-sibling.sh" "$out"
has "kit-init rendered with args: copies the gate throttle" "CREATE scripts/gate-throttle.sh" "$out"
has "kit-init rendered with args: copies quiet mode" "CREATE scripts/quiet-mode.sh" "$out"
cmp -s "$ROOT/templates/AGENT_BOARD.md" "$INIT/docs/orchestration/AGENT_BOARD.md" && ok || bad "kit-init: the copied board is not the template"
out="$(cd "$INIT" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$copy" 2>&1)"
has "kit-init second run: skips existing files" "SKIP   docs/orchestration/AGENT_BOARD.md (exists)" "$out"
hasnt "kit-init second run: creates nothing" "CREATE docs/orchestration/AGENT_BOARD.md" "$out"

# 2c. kit-init setkey, rendered with arguments: placeholders filled, the commit line dropped.
setk="$(block "$TMP/kit-init.md" "Persist the worktree answer" | grep -v '^git add' \
  | sed -e 's/<advised|enforced>/enforced/' -e 's/<on if a team was started, else off>/on/g')"
(cd "$INIT" && bash -c "$setk") >/dev/null 2>&1
C="$INIT/docs/orchestration/ORCHESTRATION.md"
grep -Eq '^[[:space:]]+worktrees:[[:space:]]*enforced[[:space:]]*$' "$C" && ok || bad "kit-init setkey: worktrees not set to enforced: $(grep -n 'worktrees' "$C")"
grep -Eq '^[[:space:]]+git_guard:[[:space:]]*on[[:space:]]*$' "$C" && ok || bad "kit-init setkey: git_guard not set to on: $(grep -n 'git_guard' "$C")"
grep -Eq '^[[:space:]]+ctx_guard:[[:space:]]*on[[:space:]]*$' "$C" && ok || bad "kit-init setkey: ctx_guard not set to on: $(grep -n 'ctx_guard' "$C")"

echo "skill-positional: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
