"""Opt-in switch shared by the kit's safety-guard hooks (discard, pkill, sendmessage-sha, prettier-dir, conflict-marker).

A guard is a NO-OP (it allows everything) unless BOTH hold, read from the MAIN checkout (the first entry of `git worktree list`,
so linked worktrees follow the main repo's setting):
  - the repo carries the opt-in marker docs/orchestration/.kit-hooks (kit-init creates it);
  - docs/orchestration/ORCHESTRATION.md says `safety_guards: on` in the team block (default `off`).
Anything unreadable counts as off: a broken switch must never block a tool call. Test seam: KIT_HOOKS_CHECK_ONLY=1 skips the
switch (the hook then judges every command), so a test needs no repo with a marker.
Loaded by path (importlib), because a hook runs with `python3 -I`, which keeps the script's own directory off sys.path.
"""
import os
import re
import subprocess

ON_RE = re.compile(r"^[ \t]*safety_guards:[ \t]*(on|enforced|true|yes)([ \t]|#|$)", re.M)


def enabled(cwd):
    """True when the guards are switched on for the repo that holds `cwd` (False: allow everything)."""
    if os.environ.get("KIT_HOOKS_CHECK_ONLY") == "1":
        return True
    try:
        here = cwd if isinstance(cwd, str) and os.path.isdir(cwd) else os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
        out = subprocess.run(
            ["git", "-C", here, "worktree", "list", "--porcelain"], capture_output=True, text=True, timeout=3
        )
        if out.returncode != 0:
            return False
        first = out.stdout.split("\n", 1)[0]
        main = first[len("worktree "):] if first.startswith("worktree ") else ""
        if not main or not os.path.isfile(os.path.join(main, "docs", "orchestration", ".kit-hooks")):
            return False
        with open(os.path.join(main, "docs", "orchestration", "ORCHESTRATION.md"), encoding="utf-8", errors="replace") as f:
            return bool(ON_RE.search(f.read()))
    except Exception:
        return False
