#!/usr/bin/env python3
"""Case driver for the hook tests (tests/hook-*.test.sh): feeds each case to a PreToolUse hook as the JSON Claude Code sends, and prints
one line per case: `ok` or `FAIL <why>`. A case file is JSON lines: a string (the command) or [command, expected-substring].

  python3 -I tests/lib-hook-cases.py --hook H --cases F --expect refuse|allow [--cwd DIR] [--tool Bash --field command] [--fix SUBSTR]

refuse = exit 2, ONE stderr line, the substring (when the row has one) and --fix in it. allow = exit 0, nothing on stderr.
The hook runs with a minimal environment and KIT_HOOKS_CHECK_ONLY=1 (the opt-in switch is tested on its own in tests/hook-gate.test.sh).
"""
import argparse
import json
import os
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--hook", required=True)
ap.add_argument("--cases", required=True)
ap.add_argument("--expect", choices=("refuse", "allow"), required=True)
ap.add_argument("--cwd", default=None)
ap.add_argument("--tool", default="Bash")
ap.add_argument("--field", default="command")
ap.add_argument("--fix", default="")
a = ap.parse_args()
env = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""), "KIT_HOOKS_CHECK_ONLY": "1"}
for line in open(a.cases, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    cmd, want = (row, "") if isinstance(row, str) else (row[0], row[1] if len(row) > 1 else "")
    payload = {"tool_name": a.tool, "tool_input": {a.field: cmd}}
    if a.cwd:
        payload["cwd"] = a.cwd
    r = subprocess.run(["python3", "-I", a.hook], input=json.dumps(payload), capture_output=True, text=True, timeout=30, env=env)
    if a.expect == "refuse":
        lines = [x for x in r.stderr.split("\n") if x]
        if r.returncode != 2:
            print(f"FAIL refuse {cmd!r}: exit {r.returncode}")
        elif len(lines) != 1:
            print(f"FAIL refuse {cmd!r}: stderr has {len(lines)} lines")
        elif want and want not in r.stderr:
            print(f"FAIL refuse {cmd!r}: stderr lacks {want!r}")
        elif a.fix and a.fix not in r.stderr:
            print(f"FAIL refuse {cmd!r}: stderr lacks {a.fix!r}")
        else:
            print("ok")
    else:
        if r.returncode != 0 or r.stderr:
            print(f"FAIL allow {cmd!r}: exit {r.returncode} stderr {r.stderr.strip()[:100]!r}")
        else:
            print("ok")
