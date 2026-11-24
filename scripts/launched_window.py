#!/usr/bin/env python3
"""The context window a session was LAUNCHED with, read from its own `claude --model <tag>` argv .

Why: CLI 2.1.322 drops "[1m]" from the environment block, so a fresh session on a 1M model read "200K" there and its READY
stated the wrong window; the seat corrected each one by hand. The launched tag survives in the session process's argv
(scripts/recycle-sibling.sh passes `--model <tag>`; sibling-shell.sh relaunches claude with it), so the authority is the
FIRST `claude` ancestor of the caller. No file: a live process cannot be stale, and a session Art starts by hand is covered.

Rules:
  * walk ppid from the start pid; the first ancestor whose argv[0] is `claude` answers, even with no --model (a nested claude
    or a subagent never reads its grandparent);
  * `--model <tag>` and `--model=<tag>`; a tag ending `[1m]` is 1m, any other explicit tag is 200k; no flag, no value or no
    claude ancestor is None (callers keep refusing to guess);
  * the proc root is a parameter (tests pass a fake tree); callers read it from LAUNCHED_WINDOW_PROC_ROOT and the start pid
    from LAUNCHED_WINDOW_START_PID (test seams; defaults /proc and the caller's own pid).

Residual: a `/model` switch inside the session is NOT in argv. ctx-fill's proven-large peak still overrides a launched 200k
upward, an explicit `--window` always wins, and ctx-guard never judges a fill above 200K on the 200K marks.
Usage: launched_window.py [--proc-root DIR] [--pid N]   prints {"window": "1m"|"200k"|null, "tag", "pid", "session_id", "session_ids"}
"""
import json
import os
import sys

DEFAULT_PROC = "/proc"
MAX_DEPTH = 64  # a process tree never nests this deep; bounds a corrupt fake tree


def _read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


def _ppid(proc_root, pid):
    """Field 4 of /proc/<pid>/stat, parsed after the LAST ')' because comm may hold spaces and parentheses."""
    stat = _read(os.path.join(proc_root, str(pid), "stat")).decode("utf-8", "replace")
    rest = stat[stat.rfind(")") + 2 :].split()
    try:
        return int(rest[1])
    except (IndexError, ValueError):
        return 0


def _argv(proc_root, pid):
    raw = _read(os.path.join(proc_root, str(pid), "cmdline"))
    return [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a != b""]


def _env_value(proc_root, pid, key):
    for item in _read(os.path.join(proc_root, str(pid), "environ")).split(b"\0"):
        if item.startswith(key.encode() + b"="):
            return item[len(key) + 1 :].decode("utf-8", "replace")
    return None


def model_from_argv(argv):
    """The value of --model / --model=, or None."""
    found = None
    for i, a in enumerate(argv):  # the CLI takes the LAST --model, so keep scanning
        if a == "--model":
            found = argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith("--") else None
        elif a.startswith("--model="):
            found = a.split("=", 1)[1] or None
    return found


def window_of_tag(tag):
    if "haiku" in tag.lower():
        return "200k"  # Haiku has no 1M variant, so a [1m] suffix on it is still 200K
    return "1m" if tag.lower().endswith("[1m]") else "200k"


def _registry_id(config_dir, pid):
    """The CURRENT session id Claude Code keeps in <config>/sessions/<pid>.json (the environ one is the launch id, shared by every claude on the host, and is never used)."""
    try:
        with open(os.path.join(config_dir, "sessions", f"{pid}.json"), "rb") as fh:
            return json.load(fh).get("sessionId")
    except (OSError, ValueError, AttributeError):
        return None


def launched_window(proc_root=DEFAULT_PROC, pid=None, config_dir=None):
    """Dict for the first claude ancestor of `pid` (default: this process); every value None when there is none.

    session_ids = the id that process answers to: the live <config dir>/sessions/<pid>.json sessionId ONLY (the
    environ CLAUDE_CODE_SESSION_ID is inherited unchanged by every claude on the host, so it never names a session). The config dir is `config_dir`, else that process's CLAUDE_CONFIG_DIR,
    else ~/.claude.
    """
    none = {"window": None, "tag": None, "pid": None, "session_id": None, "session_ids": []}
    cur = os.getpid() if pid is None else pid
    for _ in range(MAX_DEPTH):
        if cur <= 1:
            return none
        argv = _argv(proc_root, cur)
        if argv and os.path.basename(argv[0]) == "claude":
            tag = model_from_argv(argv)
            cfg = config_dir or _env_value(proc_root, cur, "CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
            reg_id = _registry_id(os.path.expanduser(cfg), cur)
            return {
                "window": window_of_tag(tag) if tag else None,
                "tag": tag,
                "pid": cur,
                "session_id": reg_id,
                "session_ids": [reg_id] if reg_id else [],
            }
        nxt = _ppid(proc_root, cur)
        if nxt == cur:
            return none
        cur = nxt
    return none


def from_env():
    """launched_window() with the callers' test seams applied."""
    root = os.environ.get("LAUNCHED_WINDOW_PROC_ROOT") or DEFAULT_PROC
    start = os.environ.get("LAUNCHED_WINDOW_START_PID")
    return launched_window(
        root, int(start) if start and start.isdigit() else None, os.environ.get("LAUNCHED_WINDOW_CONFIG_DIR") or None
    )


def owns(lw, uuid):
    """True when the claude process in `lw` answers to the session `uuid` (its live registry id)."""
    return bool(lw["window"] and uuid and uuid in lw["session_ids"])


def window_for_session(uuid):
    """The launched window (1m / 200k) ONLY when this claude process is the session `uuid`; else None.

    A seat measuring a peer's transcript must never stamp its own window on it, so a missing or different session id
    (the live sessions/<pid>.json id) answers None.
    """
    lw = from_env()
    return lw["window"] if owns(lw, uuid) else None


def main(argv):
    root, pid = DEFAULT_PROC, None
    it = iter(argv)
    for a in it:
        if a == "--proc-root":
            root = next(it, DEFAULT_PROC)
        elif a == "--pid":
            v = next(it, "")
            pid = int(v) if v.isdigit() else None
    print(json.dumps(launched_window(root, pid)))


if __name__ == "__main__":
    main(sys.argv[1:])
