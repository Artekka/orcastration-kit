#!/usr/bin/env bash
# Every PreToolUse hook the kit ships finishes inside HALF its configured time limit on worst-case inputs.
# Why: Claude Code drops a hook that passes its limit and runs the tool call unchecked, with no message, so a
# slow guard fails open on exactly the large commands nobody tested. The hooks and their limits are read from
# hooks/hooks.json, so a new hook is timed without editing this file. Inputs are about 200 KB each: many quotes, one long word, many heredocs, a long
# cd chain, a look-behind breaker, many cd targets times many words, climbing words, a large Edit, a long path.
#   bash tests/hook-time.test.sh            (HOOK_TIME_ROOT=<kit copy> times another copy's hooks)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="${HOOK_TIME_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "hook-time: skipped (no python3)"; exit 0; }
command -v timeout >/dev/null 2>&1 || { echo "hook-time: skipped (no timeout)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# an opted-in repo with a never_read list (made-up paths), so the guards do their full work
R="$TMP/repo"; mkdir -p "$R/docs/orchestration" "$TMP/home/.vault"
git -C "$R" init -q 2>/dev/null
printf 'team:\n  seat: Atlas\n\n## Secrets\n\nnever_read:\n  - ~/.vault/\n  - ~/.keys/deploy.pem\n' > "$R/docs/orchestration/ORCHESTRATION.md"
: > "$R/docs/orchestration/.kit-hooks"; : > "$R/docs/orchestration/AGENT_BOARD.md"
git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init 2>/dev/null
export SECRETS_GUARD_HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$ROOT"
python3 -I - "$ROOT/hooks/hooks.json" "$R" <<'EOF'
import json, re, subprocess, sys, time
hooks_json, repo = sys.argv[1], sys.argv[2]
N = 200_000
def bash(c): return {"command": c}
SHAPES = {
    "Bash": {
        "many quotes": bash("echo " + '"a" ' * (N // 4)),
        "one long word": bash("echo " + "x" * N),
        "many heredocs": bash("".join(f"cat <<E{i}\nbody\nE{i}\n" for i in range(N // 20))),
        "long cd chain": bash(" && ".join(["cd sub && git status"] * (N // 24))),
        "look-behind breaker": bash("echo " + "name-," * (N // 6)),
        "cd targets x words": bash(" && ".join(f"cd /opt/d{i}" for i in range(60)) + " && ls " + " ".join(f"w{i}/x" for i in range(N // 8))),
        "climbing words": bash(" && ".join(f"cd /opt/d{i}" for i in range(60)) + " && ls " + " ".join(f"../w{i}" for i in range(N // 7))),
    },
    "Edit": {"large edit": {"file_path": repo + "/docs/orchestration/AGENT_BOARD.md", "old_string": "x", "new_string": "row 12:34Z done\n" * (N // 16)},
             "long path": {"file_path": repo + "/a" + "/./b/.." * (N // 8), "old_string": "x", "new_string": "y"}},
    "Write": {"large write": {"file_path": repo + "/docs/orchestration/AGENT_BOARD.md", "content": "row 12:34Z done\n" * (N // 16)}},
    "Read": {"long path": {"file_path": repo + "/a" + "/./b/.." * (N // 8)}},
    "Grep": {"long pattern and path": {"pattern": "a|" * (N // 2), "path": repo + "/a" + "/./b/.." * (N // 16)}},
}
pre = json.load(open(hooks_json))["hooks"].get("PreToolUse", [])
passed = failed = timed = 0
for entry in pre:
    matcher = entry.get("matcher", "")
    tools = [t for t in SHAPES if not matcher or re.fullmatch(matcher, t) or t in matcher.split("|")]
    for h in entry.get("hooks", []):
        if h.get("type") != "command":
            continue
        limit = float(h.get("timeout", 60))
        for tool in tools:
            for shape, ti in SHAPES[tool].items():
                payload = json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "cwd": repo, "tool_name": tool, "tool_input": ti})
                t0 = time.monotonic()
                try:
                    subprocess.run(["bash", "-c", h["command"]], input=payload, text=True, cwd=repo,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=limit)
                    took = time.monotonic() - t0
                except subprocess.TimeoutExpired:
                    took = limit
                timed += 1
                name = re.sub(r'.*/hooks/([^"\s]+).*', r"\1", h["command"])
                if took <= limit / 2:
                    passed += 1
                else:
                    failed += 1
                    print(f"FAIL {name} on {tool} '{shape}': {took:.1f} s, over half its {limit:.0f} s limit (past the limit the call runs unchecked)")
if timed < 20:
    failed += 1; print(f"FAIL only {timed} hook runs were timed; is hooks/hooks.json read?")
print(f"hook-time: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
EOF
