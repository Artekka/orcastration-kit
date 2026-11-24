#!/usr/bin/env python3
"""Report a Claude Code session's REAL context fill (orchestration-kit).

The only honest number is the `usage` block the API returns on each assistant turn:
    input_tokens + cache_read_input_tokens + cache_creation_input_tokens
That is the prompt size the model actually saw. Everything else is a guess -- and the
popular guess, `bytes / 4` of the session jsonl, over-reports by roughly 30-60% with a bias
that is not stable, so no threshold expressed against it is safe.

What this CANNOT tell you: the session's context WINDOW. The transcript's `model` field does
not carry it (a 1M-window variant and a 200K-window variant can record the same model string).
The only authoritative source is the session's OWN system-prompt environment block. What the
transcript CAN prove is a lower bound: a session that reached N tokens has a window >= N.

Usage:
    python3 scripts/ctx-fill.py                    # this session (from $CLAUDE_CODE_SESSION_ID)
    python3 scripts/ctx-fill.py <session-uuid>     # a specific session
    python3 scripts/ctx-fill.py <path/to/x.jsonl>  # a specific transcript file
    python3 scripts/ctx-fill.py --all              # every session of this project, newest first
    python3 scripts/ctx-fill.py <uuid> --window 1m|200k --line
                                                   # ONE paste line for a report; needs --window
    python3 scripts/ctx-fill.py --check "<pasted line>"
                                                   # the seat's check: MATCH / STALE / MISMATCH, exit 0 / 3 (2 = not a line)
    python3 scripts/ctx-fill.py --host <ssh-target> <uuid> ...
                                                   # run it on that host (KIT_REMOTE_REPO = its checkout)
    ... --window 1m|200k|<tokens>                  # state the window (from YOUR env block)

Marks: self-report at the PROMPT mark, hand the terminal over by the HANDOVER mark.
    1M window (>= 500K)       -> 350,000 / 400,000 (absolute)
    200K window (every Haiku) -> 120,000 / 150,000 (60% / 75% of the window)
    anything in between       -> 60% / 75% of the window, capped at the 1M marks
Why the small window is not 70% / 80%: a seat on a ~200K window died at 175,725 tokens with no
handover, so a 160K handover leaves too little margin for the retro itself.

Which window? Never the transcript's model string for Opus or Sonnet: both come in 200K and 1M and
record the same string. The one safe model rule only ever LOWERS the window: Haiku has no 1M
variant, so a `haiku` model string means 200K. --window (what your env block says) beats everything;
with none of those the window is UNKNOWN and BOTH sets of marks are printed.
Transcripts live at ~/.claude/projects/<slug>/<uuid>.jsonl, where <slug> is the session's
working directory with every non-alphanumeric character replaced by '-'.
"""
import calendar
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time

CLAUDE_HOME = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
PROJECTS = os.path.join(CLAUDE_HOME, "projects")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

ABS_PROMPT, ABS_HANDOVER = 350_000, 400_000
SMALL_WINDOW = 200_000
LARGE_WINDOW = 1_000_000
LARGE_FROM = 500_000   # a window at or above this uses the absolute marks
PROMPT_PCT, HANDOVER_PCT = 0.60, 0.75   # of a smaller window: 200K -> 120K / 150K
WINDOW_ALIASES = {"1m": LARGE_WINDOW, "200k": SMALL_WINDOW}
TOO_LONG = "Prompt is too long"


def slug(path):
    """Claude Code's project-dir name for a working directory."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def project_dir():
    return os.path.join(PROJECTS, slug(os.getcwd()))


def marks(window):
    """(prompt, handover) for a window in tokens. Unknown is handled by the caller (both sets)."""
    if window is None or window >= LARGE_FROM:
        return ABS_PROMPT, ABS_HANDOVER
    return min(ABS_PROMPT, int(window * PROMPT_PCT)), min(ABS_HANDOVER, int(window * HANDOVER_PCT))


def parse_window(text):
    """`1m`, `200k`, `200000`, `200,000`, `200_000` -> tokens; anything else -> None."""
    t = text.strip().lower().replace("_", "").replace(",", "")
    if t in WINDOW_ALIASES:
        return WINDOW_ALIASES[t]
    return int(t) if t.isdigit() and int(t) > 0 else None


def resolve_window(model, peak, stated):
    """(window or None, how it was known). Evidence, not a lookup table: see the module docstring."""
    if stated:
        return stated, "STATED by you with --window (from your env block, not the transcript)"
    if peak > SMALL_WINDOW:
        return LARGE_WINDOW, f"PROVEN: this session already reached {peak:,}"
    if model and "haiku" in model.lower():
        return SMALL_WINDOW, "model is Haiku, which has only a 200K window"
    return None, "UNKNOWN"


def find(uuid):
    """The cwd's project dir first; then any project (a worktree session has its own slug)."""
    here = os.path.join(project_dir(), uuid + ".jsonl")
    if os.path.exists(here):
        return here
    hits = glob.glob(os.path.join(PROJECTS, "*", uuid + ".jsonl"))
    return hits[0] if len(hits) == 1 else (None if not hits else sys.exit(
        "uuid found in several project dirs -- pass the .jsonl path:\n  " + "\n  ".join(hits)))


def measure(path):
    """Return (model, peak, final, turns, too_long, wall_at, recovered)."""
    model, peak, final, turns = None, 0, 0, 0
    too_long, wall_at, recovered = 0, 0, False
    with open(path) as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except (ValueError, TypeError):
                continue
            if o.get("type") != "assistant":
                continue
            msg = o.get("message") or {}
            content = msg.get("content")
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "text" and TOO_LONG in b.get("text", "")
                for b in content
            ):
                too_long += 1
                wall_at, recovered = peak, False
            u = msg.get("usage") or {}
            ctx = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                   + u.get("cache_creation_input_tokens", 0))
            if ctx:
                model = msg.get("model") or model
                peak, final, turns = max(peak, ctx), ctx, turns + 1
                if too_long:
                    recovered = True
    return model, peak, final, turns, too_long, wall_at, recovered


def verdict_of(window, peak, final, too_long, recovered, wall_at):
    """(code, text) of the verdict. The code is the status token of the `--line` paste line."""
    small_prompt, small_handover = marks(SMALL_WINDOW)
    prompt_mark = handover_mark = None
    if window is not None:
        prompt_mark, handover_mark = marks(window)
    # A session that already hit its wall must never read "OK" because it sits under a mark
    # calibrated for a larger window.
    if too_long and not recovered:
        return "WALL-HIT", f"!! WALL ALREADY HIT at {peak:,} -- this session is dead, not 'approaching' anything"
    if too_long:
        return "RECOVERED", f"~  RECOVERED from a wall at {wall_at:,}; judge it on `current`"
    if window is None and final >= small_handover:
        return "UNKNOWN-PAST-200K-HANDOVER", f"?  PAST the 200K handover mark ({small_handover:,}) IF this is a 200K window -- read your env block NOW"
    if window is None and final >= small_prompt:
        return "UNKNOWN-AT-200K-PROMPT", f"?  AT the 200K prompt mark ({small_prompt:,}) IF this is a 200K window -- read your env block NOW"
    if window is None:
        return "UNKNOWN-OK", f"OK on either window -- {small_prompt - final:,} to the 200K prompt mark"
    if final >= handover_mark:
        return "PAST-HANDOVER", "!! PAST HANDOVER -- retro now, then recycle (an in-flight row may finish first)"
    if final >= prompt_mark:
        return "AT-PROMPT-MARK", "!  AT PROMPT MARK -- self-report to the seat (or the human, if no seat)"
    return "OK", f"OK -- {prompt_mark - final:,} to the prompt mark"


def report(path, stated):
    uuid = os.path.basename(path)[:-6]
    model, peak, final, turns, too_long, wall_at, recovered = measure(path)
    if not turns:
        print(f"{uuid}  (no assistant turns with usage yet)")
        return
    window, how = resolve_window(model, peak, stated)
    small_prompt, small_handover = marks(SMALL_WINDOW)
    if window is not None:
        prompt_mark, handover_mark = marks(window)
        window_note = f"{window:,}  ({how})"
        marks_lines = [f"marks     prompt {prompt_mark:,} | handover {handover_mark:,}  ({window:,} window)"]
    else:
        prompt_mark = handover_mark = None
        window_note = (f"UNKNOWN -- not knowable from a transcript: {model} comes in both sizes. Read your OWN env "
                       f"block and re-run with --window 1m or --window 200k.")
        marks_lines = [f"marks     IF 1M:   prompt {ABS_PROMPT:,} | handover {ABS_HANDOVER:,}",
                       f"marks     IF 200K: prompt {small_prompt:,} | handover {small_handover:,}"]

    _code, verdict = verdict_of(window, peak, final, too_long, recovered, wall_at)

    print(f"session   {uuid}")
    print(f"model     {model}   (names the window only for Haiku)")
    print(f"window    {window_note}")
    print(f"current   {final:,}")
    print(f"peak      {peak:,}   over {turns} assistant turns")
    for line in marks_lines:
        print(line)
    print(f"verdict   {verdict}")


# ---- a fill report is measured, then checkable ------------------------------------------------------------
# Guessed fills ("~200K" for a real 223K) are the failure this exists to stop. `--line` prints the ONE line a report
# pastes; `--check` lets the seat verify it: it takes the fill at the last assistant turn at or before the claimed time
# and requires EXACT equality, so an understated guess (240K when 263K was real) fails as surely as an overstated one
# (a "measured now >= claimed" rule would pass the understated one). The age limit keeps an old true line from
# vouching for a fill that has moved on.
STATUS_CODES = {"OK", "AT-PROMPT-MARK", "PAST-HANDOVER", "WALL-HIT", "RECOVERED"}
CLAIM_MAX_AGE_S = 30 * 60
STAMP_FMT = "%Y-%m-%d %H:%M:%S"
LINE_RE = re.compile(
    r"^fill ([\d,]+) / ([\d,]+) \u00b7 marks ([\d,]+)/([\d,]+) \u00b7 ([A-Z-]+) \u00b7 "
    r"measured (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (\S+) \u00b7 session ([0-9a-f]{8})$"
)


def now_epoch():
    """Wall clock; CTX_FILL_NOW (epoch seconds) is the test seam."""
    return float(os.environ.get("CTX_FILL_NOW") or time.time())


def entry_fill(o):
    """The prompt size of one assistant entry, or 0."""
    u = (o.get("message") or {}).get("usage") or {}
    return u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)


def recent_fills(path, limit):
    """The fills at the last two DISTINCT assistant turns whose timestamp, floored to the second, is <= limit (epoch).

    THE one selection `--line` and `--check` both use. The session's jsonl gets a turn's entry only AFTER that turn's
    tool result, so a `--line` run inside a tool call cannot see its own turn (it measures the previous one), while the
    entry for the running turn, timestamped BEFORE the stamp, is in the file when the seat checks. A genuine line is
    therefore one of the last two fills at its stamp: `--line` reads [-1] of what it can see, `--check` accepts either
    of the last two of what it sees now. An exact number cannot be guessed, so this keeps the check honest.

    Floored to the second, because the line's stamp has whole seconds: a turn at 22:20:00.750 and a stamp of 22:20:00
    are the same moment. Consecutive entries with the same fill (one API response written as several entries) are one turn.
    """
    fills = []
    with open(path) as fh:
        for raw in fh:
            try:
                o = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if o.get("type") != "assistant":
                continue
            ctx, ts = entry_fill(o), o.get("timestamp")
            if not ctx or not isinstance(ts, str) or len(ts) < 19:
                continue
            try:
                at = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            except ValueError:
                continue
            if at <= limit and (not fills or fills[-1] != ctx):
                fills.append(ctx)
    return fills[-2:]


# Zone abbreviation -> hours east of UTC. `--line` stamps `%Z`, so the token names the zone that wrote the line.
# Reading the stamp in the CHECKER's zone made a PDT line look 420 minutes stale under TZ=UTC, and made 01:30 PDT vs
# 01:30 PST (the US fall-back repeated hour) a coin flip. A static map, not tz data: `%Z` abbreviations are ambiguous
# worldwide, and the US ones below are what a line written here prints.
TZ_OFFSET_HOURS = {
    "UTC": 0, "GMT": 0, "Z": 0,
    "PST": -8, "PDT": -7, "MST": -7, "MDT": -6, "CST": -6, "CDT": -5,
    "EST": -5, "EDT": -4, "AKST": -9, "AKDT": -8, "HST": -10,
}


def claim_epoch(stamp, tz):
    """Epoch seconds of a `--line` stamp, using its zone token; an unknown token keeps the checker's local zone."""
    wall = calendar.timegm(time.strptime(stamp, STAMP_FMT))  # the wall clock as if it were UTC
    if tz in TZ_OFFSET_HOURS:
        return wall - TZ_OFFSET_HOURS[tz] * 3600
    # The host's own pair (standard, daylight) covers zones outside the map when checker and writer share a host.
    if tz == time.tzname[0]:
        return wall + time.timezone
    if time.daylight and tz == time.tzname[1]:
        return wall + time.altzone
    return time.mktime(time.strptime(stamp, STAMP_FMT))


def make_line(path, window):
    """The paste line for a transcript, or exits 2 (it never prints a guessed number)."""
    if window is None:
        print(
            "--line needs --window 1m|200k (the window your OWN environment block names): "
            "the transcript cannot tell, so the line would carry a guess.",
            file=sys.stderr,
        )
        sys.exit(2)
    uuid = os.path.basename(path)[:-6]
    model, peak, final, turns, too_long, wall_at, recovered = measure(path)
    if not turns:
        print(f"{uuid[:8]}: no assistant turns with usage yet, nothing to measure", file=sys.stderr)
        sys.exit(2)
    now = now_epoch()
    seen = recent_fills(path, int(now))
    if seen:
        final = seen[-1]  # the same selection --check uses: the last turn this run can see in the file
    win, _how = resolve_window(model, peak, window)
    code, _text = verdict_of(win, peak, final, too_long, recovered, wall_at)
    prompt_mark, handover_mark = marks(win)
    stamp = time.strftime(STAMP_FMT + " %Z", time.localtime(now))
    return (
        f"fill {final:,} / {win:,} \u00b7 marks {prompt_mark:,}/{handover_mark:,} \u00b7 {code} \u00b7 "
        f"measured {stamp} \u00b7 session {uuid[:8]}"
    )


def account_projects_dirs():
    """Every account's projects dir: ~/.claude, ~/.claude-acct*, and $CLAUDE_CONFIG_DIR.

    One session's own PROJECTS reads a single account, so a seat on account 1 could not find an account-2 sibling.
    """
    home = os.path.expanduser("~")
    roots = [os.path.join(home, ".claude")] + sorted(glob.glob(os.path.join(home, ".claude-acct*")))
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        roots.insert(0, os.path.expanduser(cfg))
    out = []
    for r in roots:
        d = os.path.join(r, "projects")
        if os.path.isdir(d) and d not in out:
            out.append(d)
    return out


def find_by_prefix(prefix):
    """{uuid: path} of every transcript whose uuid starts with `prefix`, in every account and project dir."""
    found = {}
    for root in account_projects_dirs():
        for p in sorted(glob.glob(os.path.join(root, "*", prefix + "*.jsonl"))):
            found.setdefault(os.path.basename(p)[:-6], p)
    return found


def check_line(text):
    """Verify a pasted `--line`. Returns the exit code (0 MATCH, 3 STALE/MISMATCH/NOSESSION/AMBIGUOUS, 2 not a line)."""
    claim = text.strip().strip("`\"'").strip()
    m = LINE_RE.match(claim)
    not_a_line = "not a ctx-fill line (guessed?): paste the output of `ctx-fill.py <uuid> --window <1m|200k> --line` verbatim"
    if not m:
        print(not_a_line, file=sys.stderr)
        return 2
    fill, window, pm, hm = (int(m.group(i).replace(",", "")) for i in (1, 2, 3, 4))
    code, stamp, tz, prefix = m.group(5), m.group(6), m.group(7), m.group(8)
    if marks(window) != (pm, hm) or code not in STATUS_CODES:
        print(not_a_line, file=sys.stderr)
        return 2
    claimed_at = claim_epoch(stamp, tz)
    when = f"{stamp} {tz}"

    found = find_by_prefix(prefix)
    if not found:
        print(f"NOSESSION  no transcript with the prefix {prefix} in any account's project dirs")
        return 3
    if len(found) > 1:
        print(f"AMBIGUOUS  {len(found)} sessions start with {prefix}: " + ", ".join(sorted(found)))
        return 3
    path = next(iter(found.values()))
    now_fill = measure(path)[2]
    grown = f"now {now_fill:,} ({now_fill - fill:+,} since the claim)"

    age = now_epoch() - claimed_at
    if age < -60:
        print(f"MISMATCH  the claim is dated in the future ({when}, session {prefix}); {grown}")
        return 3
    if age > CLAIM_MAX_AGE_S:
        print(f"STALE  the claim is {int(age // 60)} min old (limit {CLAIM_MAX_AGE_S // 60}); claimed {fill:,}; {grown}")
        return 3
    fills = recent_fills(path, int(claimed_at))
    if not fills:
        print(f"MISMATCH  no assistant turn at or before {when} (session {prefix}); claimed {fill:,}")
        return 3
    if fill not in fills:
        seen = " or ".join(f"{f:,}" for f in reversed(fills))
        print(f"MISMATCH  claimed {fill:,}, the transcript had {seen} at {when} (session {prefix}); {grown}")
        return 3
    print(f"MATCH  {fill:,} equals the transcript at {when} (session {prefix}); {grown}")
    return 0


def remote_repo():
    """The kit checkout on the remote host, expanded ON the remote side.

    KIT_REMOTE_REPO wins. Otherwise this checkout's own path is assumed to exist there too, written relative to $HOME
    when it lives under it (the usual case: both machines keep the project under their own home).
    """
    env = os.environ.get("KIT_REMOTE_REPO")
    if env:
        return env
    root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    home = os.path.realpath(os.path.expanduser("~"))
    return "$HOME/" + os.path.relpath(root, home) if root.startswith(home + os.sep) else root


def run_on_host(host, rest):
    """`--host <ssh-target>` runs this same script on that host and relays its output and exit code.

    The session uuid you pass must belong to a session running there, so the transcript is read where it lives.
    """
    cmd = 'python3 "' + remote_repo() + '/scripts/ctx-fill.py" ' + " ".join(shlex.quote(a) for a in rest)
    r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, cmd])
    return r.returncode


def detect():
    """This session's transcript from an authoritative source -- or refuse. Never guess
    (e.g. "most recently modified jsonl"): measuring the wrong object is not measuring."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if UUID_RE.match(sid):
        path = find(sid)
        if path:
            return path, "CLAUDE_CODE_SESSION_ID"
    sys.exit(
        "REFUSING TO GUESS: no authoritative session id in the environment.\n"
        "Pass it explicitly:  python3 scripts/ctx-fill.py <uuid>\n"
        "Your uuid is the path segment after the project slug in your scratchpad directory\n"
        "(named in your own system prompt), or run /status in the session."
    )


def main():
    argv = sys.argv[1:]
    if "--host" in argv:
        i = argv.index("--host")
        if i + 1 >= len(argv):
            sys.exit("usage: ctx-fill.py --host <ssh-target> [args]")
        sys.exit(run_on_host(argv[i + 1], argv[:i] + argv[i + 2:]))
    window = None
    for i, a in enumerate(argv):
        if a == "--window" or a.startswith("--window="):
            val = a.split("=", 1)[1] if "=" in a else (argv[i + 1] if i + 1 < len(argv) else "")
            window = parse_window(val)
            if window is None:
                sys.exit(f"--window must be 1m, 200k or a token count (e.g. 200000); got '{val}'")
            del argv[i:i + (1 if "=" in a else 2)]
            break
    if window is None and os.environ.get("CTX_WINDOW"):
        window = parse_window(os.environ["CTX_WINDOW"])

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # the paste line carries U+00B7 separators
    if "--check" in argv:
        i = argv.index("--check")
        if i + 1 >= len(argv):
            sys.exit('usage: ctx-fill.py --check "<pasted line>"')
        sys.exit(check_line(argv[i + 1]))
    want_line = "--line" in argv
    argv = [a for a in argv if a != "--line"]

    if "--all" in argv:
        paths = sorted(glob.glob(os.path.join(project_dir(), "*.jsonl")), key=os.path.getmtime, reverse=True)
        if not paths:
            sys.exit(f"no transcripts under {project_dir()}")
        for p in paths:
            report(p, window)
            print()
        return
    if argv:
        arg = argv[0]
        path = arg if arg.endswith(".jsonl") else find(arg)
    else:
        path, via = detect()
        print(f"(identified from {via})")
    if not path or not os.path.exists(path):
        sys.exit(f"No such session transcript: {argv[0] if argv else '?'} (looked under {PROJECTS})")
    if want_line:
        print(make_line(path, window))
        return
    report(path, window)


if __name__ == "__main__":
    main()
