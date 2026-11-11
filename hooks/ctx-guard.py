#!/usr/bin/env python3
"""Context guard (orchestration-kit): measures the session's context fill on every tool call and prompt.

Why: "self-report at 350K, hand over by 400K" depended on each session remembering to run ctx-fill.py,
and on the origin project seats kept missing it (sessions found at 378K, 411K, 462K; one ran into the
1M wall at 972K and could no longer answer). A rule everyone breaks needs a mechanism.

How: Claude Code runs this as a PostToolUse and UserPromptSubmit hook with JSON on stdin
(transcript_path, session_id, hook_event_name). It reads the transcript TAIL for the last assistant
`usage` block (the same sum ctx-fill.py uses), stays silent below the warn mark, and above it injects one
short additionalContext line, again every STEP tokens of growth (and on every prompt), so it cannot be
forgotten without adding a line to every tool call.

Opt-in: silent unless the repo's main checkout carries docs/orchestration/.kit-hooks AND
docs/orchestration/ORCHESTRATION.md says `ctx_guard: on`.

Window, per session, first found:
  1. Claude Code's own figure for THIS session, as the status bar (plugins/status-hud) records it in
     <status dir>/sessions/<session id>.json. It beats the team block both ways: a session on a small
     window gets the small marks inside a 1m team, and a 1M session keeps the large marks inside a team
     block someone set to 200k.
  2. `context_window: 1m|200k` in the team block (default 1m); a transcript naming a Haiku model is 200K
     (while the fill fits in 200K).
Never the model id: it names no window (a 1M launch can show the bare id), and sessions that read one
from it handed over at a third of their room.
Never fails: any error = no output, exit 0.
"""
import json
import os
import re
import subprocess
import sys

TAIL_BYTES = 512 * 1024
STATE_DIR = os.path.join(os.environ.get("KIT_STATE_DIR") or os.path.expanduser("~/.orchestration-kit"), "ctx-guard")
HUD_DIR = os.environ.get("KIT_HUD_DIR") or os.path.expanduser("~/.claude-status-hud")  # the status bar's statusDir
LARGE_FROM = 500_000   # a window at or above this uses the large marks (same line as scripts/ctx-fill.py)
MARKS = {
    "large": {"warn": 300_000, "report": 350_000, "handover": 400_000, "wall": 1_000_000, "step": 15_000},
    "small": {"warn": 100_000, "report": 120_000, "handover": 150_000, "wall": 200_000, "step": 8_000},
}
ON = re.compile(r"^[ \t]*ctx_guard:[ \t]*(on|true|yes|enforced)([ \t#]|$)", re.M)
WINDOW = re.compile(r"^[ \t]*context_window:[ \t]*(\S+)", re.M)


def main_checkout(cwd):
    """The main worktree of the repo holding cwd (the marker and overlay live there), or None."""
    try:
        out = subprocess.run(["git", "-C", cwd, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    first = out.splitlines()[0] if out else ""
    return first[len("worktree "):] if first.startswith("worktree ") else None


def config(cwd):
    """(enabled, small_window) for the repo holding cwd."""
    top = main_checkout(cwd)
    if not top or not os.path.isfile(os.path.join(top, "docs/orchestration/.kit-hooks")):
        return False, False
    try:
        text = open(os.path.join(top, "docs/orchestration/ORCHESTRATION.md"), encoding="utf8").read()
    except OSError:
        return False, False
    w = WINDOW.search(text)
    return bool(ON.search(text)), bool(w and w.group(1).lower() in ("200k", "200000"))


def hud_window(sid):
    """The window Claude Code itself reports for this session, as the status bar recorded it, or None.

    Trusted only once the record carries a token reading: until its first reading the status bar writes
    its own default window, which is not a measurement."""
    try:
        with open(os.path.join(HUD_DIR, "sessions", f"{sid}.json"), encoding="utf8") as fh:
            o = json.load(fh)
        window, tokens = o.get("window"), o.get("tokens")
        if (isinstance(window, (int, float)) and not isinstance(window, bool) and window >= 50_000
                and isinstance(tokens, (int, float)) and not isinstance(tokens, bool) and tokens > 0):
            return int(window)
    except (OSError, ValueError, AttributeError):
        pass
    return None


def last_usage(path):
    """(fill, model) from the last assistant turn that carries usage, reading only the tail."""
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(max(0, size - TAIL_BYTES))
        lines = fh.read().split(b"\n")
    for raw in reversed(lines):
        if b'"assistant"' not in raw or b'"usage"' not in raw:
            continue
        try:
            o = json.loads(raw)
        except ValueError:
            continue  # the first line of the tail is usually cut in half
        if o.get("type") != "assistant":
            continue
        msg = o.get("message") or {}
        u = msg.get("usage") or {}
        fill = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
        if fill:
            return fill, msg.get("model") or ""
    return 0, ""


def k(n):
    return f"{n // 1000}K"


def message(fill, m, source=""):
    return _order(fill, m) + (f" Window {k(m['wall'])}: {source}." if source else "")


def _order(fill, m):
    if fill >= m["handover"]:
        return (f"CONTEXT GUARD: fill {k(fill)} is PAST the {k(m['handover'])} handover mark (wall {k(m['wall'])}). "
                f"Stop taking new work now. Sibling: finish or park the row, report your fill to the seat, run "
                f"/orchestration-kit:retro and reply \"retro complete\". Seat: wait for your own subagents and background "
                f"shells, write the handover block under the board banner, then recycle yourself with "
                f"scripts/recycle-sibling.sh. Tell the human in one line that you are recycling.")
    if fill >= m["report"]:
        return (f"CONTEXT GUARD: fill {k(fill)} crossed the {k(m['report'])} self-report mark. Report it now "
                f"(sibling: to the seat; seat: on the board banner and to the human), start no new row, and hand "
                f"over before {k(m['handover'])}.")
    return (f"CONTEXT GUARD: fill {k(fill)}, approaching the {k(m['report'])} self-report mark. Finish in-flight "
            f"work; do not start a large row.")


def main():
    try:
        hook = json.load(sys.stdin)
        path = hook.get("transcript_path") or ""
        event = hook.get("hook_event_name") or "PostToolUse"
        sid = re.sub(r"[^A-Za-z0-9_-]", "_", hook.get("session_id") or os.path.basename(path)[:-6])
        if not path or not os.path.exists(path):
            return
        enabled, small_window = config(hook.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
        if not enabled:
            return
        fill, model = last_usage(path)
        measured = hud_window(sid)
        if measured:
            small, source = measured < LARGE_FROM, "Claude Code's own figure for this session"
        elif small_window:
            small, source = True, "the team block's context_window"
        elif "haiku" in model.lower() and fill <= MARKS["small"]["wall"]:
            small, source = True, "a Haiku model"
        else:
            small, source = False, "the team block's context_window (default 1m)"
        m = MARKS["small" if small else "large"]
        if fill < m["warn"]:
            return
        # Rate limit: speak again only after STEP more tokens, when a mark is newly crossed, or on a prompt.
        os.makedirs(STATE_DIR, exist_ok=True)
        state_file = os.path.join(STATE_DIR, f"{sid}.last")
        try:
            last = int(open(state_file).read().strip() or 0)
        except (OSError, ValueError):
            last = 0
        if last and fill < last:
            last = 0  # the session was cleared or compacted: start over
        crossed = any(last < m[key] <= fill for key in ("warn", "report", "handover"))
        if not crossed and fill - last < m["step"] and event != "UserPromptSubmit":
            return
        with open(state_file, "w") as fh:
            fh.write(str(fill))
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": message(fill, m, source)}}))
    except Exception:
        return  # a guard must never break the session it guards


if __name__ == "__main__":
    main()
