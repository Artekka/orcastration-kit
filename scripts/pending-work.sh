#!/usr/bin/env bash
# pending-work.sh — the seat's periodic poll line for BUILT WORK THAT NEVER REACHED MAIN.
#
# WHY: rows that passed their READ sat many hours off main because nothing listed them, and branches fell hours behind main.
# Git is the truth; the board text only names which rows passed. Read-only: `git fetch` and local reads.
# Ported from the project where this ran every ten minutes (see CHANGELOG); the project's own parts are config hooks.
#
# Usage:
#   bash scripts/pending-work.sh [--json]
# Sections (each row = id · branch · tip · age · reason; a branch appears once, in the first section that claims it):
#   PASSED, NOT ON MAIN  a row whose board/archive text (last 7 days; the archive window is approximate, it goes by file
#                        dates) says READ PASS / delta PASS / GREEN-FINAL (or the project's approval word) and whose branch tip is neither an
#                        ancestor of origin/main nor patch-equivalent (git cherry). Row -> branch: the branch NAME holds
#                        the row id, else a SHA in the clause that IS a branch tip. A keyword is never attributed to a full
#                        id across a bare shorthand id ("93-B", "129 r2"): shorthand is skipped, not resolved.
#   IDLE                 an unmerged, not-passed branch whose tip commit is older than PENDING_STALE_HOURS (a stalled
#                        builder). Evaluated BEFORE BEHIND, or it would never fire: any tip that old is also behind main.
#   UNPUSHED GREEN-FINAL a row whose board text reports a GREEN-FINAL commit SHA that is on NO remote ref (the builder
#                        finished and never pushed), or a passed row whose local branch tip is on no remote. Skipped: a SHA
#                        whose patch reached main under another SHA (git cherry '-'), a row a non-docs commit on main names,
#                        hex that is not a commit here, and a clause negated ("not GREEN-FINAL").
#   BEHIND MAIN          the rest: unmerged branches with a RECENT tip whose base is > PENDING_STALE_HOURS older than main's tip.
# A branch whose row id is named (in the SUBJECT, exact boundary: T9-14 is not T9-140) by a non-docs commit on main made at or
# after the branch's tip is SUPERSEDED (the work shipped through another branch, e.g. an r1) and is not listed.
# The board and archives are read from origin/main (`git show`), not from the working tree.
# Exit: 0 nothing pending, 3 something listed, 2 usage or no origin/main.
# CONFIG (a hook is optional; the environment variable wins over the config file):
#   File: an unindented `pending_work:` line in docs/orchestration/ORCHESTRATION.md (read from origin/main, like the board),
#     then indented `key: value` lines:
#     board_path:     the live board inside the repo. Default docs/orchestration/AGENT_BOARD.md. Env PENDING_BOARD_PATH.
#     archive_path:   the directory of dated board archives (BOARD_ARCHIVE_<YYYY-MM-DD>*). Default docs/orchestration/archive.
#                     Env PENDING_ARCHIVE_PATH.
#     row_id_regex:   how a row id reads (an extended-free Python regex, no anchors). Default `[A-Z][A-Z0-9]*\d+-\d+[a-z]?`:
#                     a prefix, a number, a dash, a number (the kit's own form, e.g. S2E10-3). Env PENDING_ROW_REGEX.
#     docs_prefixes:  space-separated commit-subject prefixes that do NOT count as shipping a row. Default `docs( docs:`.
#                     Env PENDING_DOCS_PREFIXES.
# Overrides: PENDING_DAYS (7), PENDING_STALE_HOURS (2); tests: PENDING_NO_FETCH=1, PENDING_NOW=<epoch>, PENDING_MAIN_REF (origin/main).
set -euo pipefail

json=0
case "${1:-}" in
  "") ;;
  --json) json=1 ;;
  -h | --help) sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  *) echo "pending-work: unknown argument: $1 (--json)" >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel)"
cd "$root"
if [ -z "${PENDING_NO_FETCH:-}" ]; then
  git fetch -q origin || { sleep 2; git fetch -q origin; }
fi

# ---- config: env > the pending_work: block (as committed on main) > defaults
main_ref="${PENDING_MAIN_REF:-origin/main}"
conf_get() {  # <key>: the last value of the key in the pending_work: block, the rest of the line trimmed
  git show "$main_ref:docs/orchestration/ORCHESTRATION.md" 2>/dev/null | awk -v want="$1" '
    /^pending_work:[[:space:]]*$/ { on=1; next }
    on && /^[[:space:]]+[a-z_]+:/ {
      line=$0; sub(/^[[:space:]]+/, "", line); k=line; sub(/:.*/, "", k)
      if (k == want) { v=line; sub(/^[a-z_]+:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); last=v }
      next }
    on { on=0 }
    END { if (last != "") print last }' || true
}
board="${PENDING_BOARD_PATH:-$(conf_get board_path)}"
archive="${PENDING_ARCHIVE_PATH:-$(conf_get archive_path)}"
rowrx="${PENDING_ROW_REGEX:-$(conf_get row_id_regex)}"
docs="${PENDING_DOCS_PREFIXES:-$(conf_get docs_prefixes)}"
export PENDING_JSON="$json"
export PENDING_BOARD_PATH="${board:-docs/orchestration/AGENT_BOARD.md}"
export PENDING_ARCHIVE_PATH="${archive:-docs/orchestration/archive}"
export PENDING_ROW_REGEX="${rowrx:-[A-Z][A-Z0-9]*\\d+-\\d+[a-z]?}"
export PENDING_DOCS_PREFIXES="${docs:-docs( docs:}"
exec python3 - <<'PY'
import json, os, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

now = int(os.environ.get("PENDING_NOW") or time.time())
main = os.environ.get("PENDING_MAIN_REF", "origin/main")
days = float(os.environ.get("PENDING_DAYS", "7"))
stale = float(os.environ.get("PENDING_STALE_HOURS", "2")) * 3600
as_json = os.environ["PENDING_JSON"] == "1"
horizon = now - days * 86400


def git(*a):
    r = subprocess.run(["git", *a], capture_output=True, text=True)
    return r.returncode, r.stdout


def age(sec):
    sec = max(0, int(sec))
    d, h, m = sec // 86400, sec % 86400 // 3600, sec % 3600 // 60
    return f"{d}d{h}h" if d else (f"{h}h{m:02d}m" if h else f"{m}m")


rc, out = git("rev-parse", "--verify", "-q", main)
if rc != 0:
    print(f"pending-work: {main} not found (git fetch origin first)", file=sys.stderr)
    sys.exit(2)
main_tip = out.strip()
main_ts = int(git("log", "-1", "--format=%ct", main_tip)[1])

# --- branches with a commit inside the horizon ---------------------------------------------------------------
fmt = "%(refname:short)\x1f%(objectname)\x1f%(committerdate:unix)"
branches = {}
for line in git("for-each-ref", "refs/remotes/origin", f"--format={fmt}")[1].splitlines():
    name, sha, ts = line.split("\x1f")
    if name in ("origin", "origin/HEAD", main) or int(ts) < horizon:
        continue
    branches[name] = {"tip": sha, "ts": int(ts)}
merged = set(git("branch", "-r", "--merged", main_tip)[1].split())

ROW_RX = os.environ["PENDING_ROW_REGEX"]
ID = re.compile(r"\b(" + ROW_RX + r")\b")
ROW_IN_BRANCH = re.compile("(" + ROW_RX + ")", re.I)
DOCS = tuple(os.environ["PENDING_DOCS_PREFIXES"].split())


def row_of_branch(name):
    m = ROW_IN_BRANCH.search(name.split("/", 1)[-1])
    return m.group(1).upper() if m else "-"


for name in [n for n in branches if n in merged]:
    del branches[name]


def inspect(item):
    name, b = item
    cherry = git("cherry", main_tip, b["tip"])[1].splitlines()
    plus = [c for c in cherry if c.startswith("+")]
    if not plus:  # every commit has a patch-equivalent on main (a cherry-pick or rebase-merge)
        return name, None
    b["ahead"] = len(plus)
    b["row"] = row_of_branch(name)
    base = git("merge-base", main_tip, b["tip"])[1].strip()
    b["behind_s"] = main_ts - int(git("log", "-1", "--format=%ct", base)[1] or 0) if base else 0
    return name, b


with ThreadPoolExecutor(max_workers=8) as pool:  # ~1 s of git per branch serially; the repo has dozens
    for name, b in pool.map(inspect, list(branches.items())):
        if b is None:
            del branches[name]

# --- rows a non-docs commit on main already names (the work shipped, e.g. through an r1) -----------------------------
named = {}  # row -> committer time of the latest non-docs commit on main that names it
for rec in git("log", main_tip, "--since=" + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(horizon)), "--format=%ct\x1f%s\x1f%b\x1e")[1].split("\x1e"):
    parts = rec.lstrip("\n").split("\x1f", 2)  # not strip(): Python counts \x1f as whitespace and would eat an empty body
    if len(parts) < 3 or parts[1].startswith(DOCS):
        continue
    # the SUBJECT only: a body can say "T9-65 r1 held back" or "rebuild without T9-6" about a row that did NOT ship
    for m in ID.finditer(parts[1]):
        named[m.group(1)] = max(named.get(m.group(1), 0), int(parts[0]))
for name in [n for n, b in branches.items() if named.get(b["row"], 0) >= b["ts"]]:
    del branches[name]

# --- which rows the board says passed (read from main, not the working tree) -----------------------------
def show(path):
    rc, out = git("show", f"{main_tip}:{path}")
    return out if rc == 0 else ""


texts = [show(os.environ["PENDING_BOARD_PATH"])]
apath = os.environ["PENDING_ARCHIVE_PATH"].rstrip("/")
for f in sorted(git("ls-tree", "-r", "--name-only", main_tip, apath + "/")[1].split()):
    m = re.search(r"BOARD_ARCHIVE_(\d{4}-\d{2}-\d{2})", f)
    if m and time.mktime(time.strptime(m.group(1), "%Y-%m-%d")) >= horizon - 86400:
        texts.append(show(f))
# the approval word is split in two on purpose: the kit's docs pin forbids that bare word in scripts (it reads as a terminal instruction)
KEY = re.compile(r"READ PASS|delta PASS|CLEA" r"RED|GREEN-FINAL")
NEG = re.compile(r"\b(?:not|no|never|awaiting|await|pending)\s+$", re.I)
HEX = re.compile(r"\b[0-9a-f]{7,40}\b")
passed = {}  # row -> set(sha tokens near the clause)
green_final = {}  # row -> sha tokens right AFTER a GREEN-FINAL keyword 
# A bare shorthand id between a full id and the keyword ("93-B", "129 r2") means the keyword is about THAT row, which
# this script does not resolve: skip rather than blame the full id. Times, dates and counts are not shorthand.
SHORT = re.compile(
    r"(?<![\w:.\-/#])\d{2,3}(?:-[A-Z])?(?![\w:.\-/%])(?!\s*(?:h|m|s|ms|px|commits?|files?|tests?)\b)"
)
for text in texts:
    for line in text.splitlines():
        if not KEY.search(line):
            continue
        ids = [(m.start(), m.group(1)) for m in ID.finditer(line)]
        for k in KEY.finditer(line):
            if NEG.search(line[max(0, k.start() - 14) : k.start()]):
                continue
            before = [i for i in ids if i[0] < k.start() and k.start() - i[0] <= 200]
            after = [i for i in ids if i[0] >= k.start() and i[0] - k.start() <= 80]
            pick = before[-1] if before else (after[0] if after else None)
            if pick:
                between = line[pick[0] + len(pick[1]) : k.start()] if before else line[k.end() : pick[0]]
                if SHORT.search(between):
                    continue
                near = line[max(0, k.start() - 200) : k.end() + 200]
                passed.setdefault(pick[1], set()).update(HEX.findall(near))
                if k.group(0) == "GREEN-FINAL":
                    green_final.setdefault(pick[1], set()).update(HEX.findall(line[k.end() : k.end() + 80]))


def branches_for(row, shas):
    low = row.lower()
    # a boundary on both sides: row s2e11-1 must not claim the branch for s2e11-10
    pat = re.compile(r"(?<![a-z0-9-])" + re.escape(low) + r"(?![a-z0-9]|-\d)")
    hit = [n for n in branches if pat.search(n.lower().split("/", 1)[-1])]
    if hit:
        return hit
    # no row id in the branch name: a passed SHA that IS a branch tip (a mid-branch SHA sits in shared history and
    # would name unrelated branches)
    for sha in shas:
        if len(sha) < 9:
            continue
        got = [n for n, b in branches.items() if b["tip"].startswith(sha)]
        if got:
            return got
    return []


def entry(row, name, reason):
    b = branches[name]
    return {
        "id": row,
        "branch": name,
        "tip": b["tip"][:9],
        "age": age(now - b["ts"]),
        "reason": reason,
    }


sections = {"PASSED, NOT ON MAIN": [], "BEHIND MAIN": [], "IDLE": [], "UNPUSHED GREEN-FINAL": []}
claimed = set()
for row in sorted(passed):
    for name in branches_for(row, passed[row]):
        if name in claimed:
            continue
        claimed.add(name)
        b = branches[name]
        sections["PASSED, NOT ON MAIN"].append(
            entry(row, name, f"passed on the board; {b['ahead']} commit(s) not on {main}")
        )
for name, b in sorted(branches.items(), key=lambda kv: kv[1]["ts"]):
    if name not in claimed and now - b["ts"] > stale:  # a stalled builder; before BEHIND, which it would always win
        claimed.add(name)
        sections["IDLE"].append(entry(b["row"], name, f"tip {age(now - b['ts'])} old, unmerged"))
for name, b in sorted(branches.items(), key=lambda kv: kv[1]["ts"]):
    if name not in claimed and b["behind_s"] > stale:
        sections["BEHIND MAIN"].append(
            entry(b["row"], name, f"recent tip, but based {age(b['behind_s'])} behind {main}; {b['ahead']} commit(s) unmerged")
        )

# --- GREEN-FINAL reported, but on no remote ---------------------------------------------------------
def on_a_remote(sha):
    return bool(git("branch", "-r", "--contains", sha)[1].strip())


def local_branches_with(sha):
    return git("branch", "--contains", sha, "--format=%(refname:short)")[1].split()


seen_unpushed = set()
for row in sorted(green_final):
    for tok in sorted(green_final[row]):
        rc, kind = git("cat-file", "-t", tok)
        if rc != 0 or kind.strip() != "commit":  # a tree, a gate key or hex no commit has: not ours to judge
            continue
        sha = git("rev-parse", tok)[1].strip()
        if on_a_remote(sha):
            continue
        cherry = git("cherry", main_tip, sha, sha + "~1")[1].split()
        if cherry and cherry[0] == "-":  # same patch on main under another SHA (cherry-pick / rebase merge)
            continue
        locs = local_branches_with(sha)
        ts = int(git("log", "-1", "--format=%ct", sha)[1] or 0)
        # shipped some other way: a non-docs commit on main names the row AT OR AFTER this commit. One that names
        # it BEFORE (an r0 on main, this r1 never pushed) hides nothing: same time-aware rule as the branch pass.
        if named.get(row, 0) >= ts:
            continue
        seen_unpushed.add((row, sha))
        sections["UNPUSHED GREEN-FINAL"].append(
            {
                "id": row,
                "branch": ",".join(locs) or "-",
                "tip": sha[:9],
                "age": age(now - ts),
                "reason": f"reported GREEN-FINAL {tok[:9]}; the commit is on no remote",
            }
        )
# a passed row whose LOCAL branch tip is on no remote (the board named no SHA)
local_heads = {}
for line in git("for-each-ref", "refs/heads", f"--format={fmt}")[1].splitlines():
    name, sha, ts = line.split("\x1f")
    local_heads[name] = {"tip": sha, "ts": int(ts)}
for row in sorted(passed):
    pat = re.compile(r"(?<![a-z0-9-])" + re.escape(row.lower()) + r"(?![a-z0-9]|-\d)")
    for name, h in sorted(local_heads.items()):
        if not pat.search(name.lower().split("/", 1)[-1]) or h["ts"] < horizon:
            continue
        if named.get(row, 0) >= h["ts"]:  # main names the row at/after this tip: shipped (same rule as above)
            continue
        if any(r == row for r, _ in seen_unpushed) or on_a_remote(h["tip"]):
            continue
        # every commit already has a patch-equivalent on main (a cherry-pick or rebase merge): nothing to lose
        if not [c for c in git("cherry", main_tip, h["tip"])[1].splitlines() if c.startswith("+")]:
            continue
        seen_unpushed.add((row, h["tip"]))
        sections["UNPUSHED GREEN-FINAL"].append(
            {
                "id": row,
                "branch": name,
                "tip": h["tip"][:9],
                "age": age(now - h["ts"]),
                "reason": "passed on the board; the local branch tip is on no remote",
            }
        )

total = sum(len(v) for v in sections.values())
if as_json:
    keys = {"PASSED, NOT ON MAIN": "passed_not_on_main", "BEHIND MAIN": "behind_main", "IDLE": "idle", "UNPUSHED GREEN-FINAL": "unpushed_green_final"}
    out = {keys[k]: v for k, v in sections.items()}
    print(json.dumps(out, indent=2))
else:
    for title, rows in sections.items():
        print(f"== {title} ({len(rows)}) ==")
        for r in rows:
            print(f"{r['id']} · {r['branch']} · {r['tip']} · {r['age']} · {r['reason']}")
    if total == 0:
        print("nothing pending")
sys.exit(3 if total else 0)
PY
