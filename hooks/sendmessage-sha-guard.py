#!/usr/bin/env python3
"""SendMessage sha guard: a Claude Code PreToolUse hook that refuses a message naming a sha git cannot resolve.

Why: sessions send messages that cite a commit sha that does not exist (a typo, a sha from another tree, a made-up one). The reader
then chases a ghost. A cited sha is checkable in milliseconds, so the hook checks it. NO-OP unless the kit's safety guards are on
(hooks/lib/kitgate.py).

How: it reads the PreToolUse JSON on stdin. For SendMessage, it takes tool_input.message and finds every token of 7 to 40 hex
characters that holds at least one letter AND one digit. Each is run through `git rev-parse --verify --quiet <tok>^{object}` in the
repo of the session's cwd (any worktree sees every object). A token that fails is refused (exit 2, ONE stderr line naming the token(s)).
Any object counts (commit, TREE, blob), not only a commit: validators cite trees and blobs to prove a tip.
Skipped (not a sha): a token touching a letter, digit, `/`, `-`, `_` or `#` (a path, a uuid, a word, a color code, `0x...`), a token
after a single `.` (`file.abc1234`, `./x`) but NOT after `..` (both sides of `a..b` are checked), a token in square brackets (a
session ref `[7a6f05]`), and the 8 hex after the word `session` (ctx-fill's own line) or `job` / `job id` (a job id; a `:`, `=` or `,`
may sit between). Upper case is read as lower case. A message with more than 30 distinct candidates checks the first 30 only.

Anything it cannot read (malformed JSON, no message, git missing, a timeout, a cwd that is not a repo) FAILS OPEN with exit 0:
a broken hook must never block all messages. It never rewrites the message.
Seam (tests): SENDMESSAGE_SHA_GUARD_REPO is the repo to ask (default: the repo of the hook's cwd).
Wiring: hooks/hooks.json, PreToolUse with matcher SendMessage.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_TOKENS = 30
GIT_TIMEOUT_S = 3
# 7 to 40 hex characters not touching a word character or one of / - # (path, uuid, color code, longer word) and not after a single `.` (`file.abc1234`);
# `[..]`, "session " and "job " are cut below
TOKEN_RE = re.compile(r"(?<![\w/\-#])(?<![^.]\.)[0-9a-fA-F]{7,40}(?![\w/\-])(?!\.\w)")
SESSION_RE = re.compile(r"\b(?:session|job)(?:\s+id)?[\s:=,]+[0-9a-f]{8}\b", re.I)
BRACKET_RE = re.compile(r"\[[0-9a-fA-F]{7,40}\]")


def candidates(message):
    """Distinct hex tokens in `message` that could be a commit sha, in order of appearance."""
    text = BRACKET_RE.sub(" ", SESSION_RE.sub(" ", message))
    seen, out = set(), []
    for m in TOKEN_RE.finditer(text):
        tok = m.group(0).lower()
        if tok in seen or not (re.search(r"[a-f]", tok) and re.search(r"\d", tok)):
            continue
        seen.add(tok)
        out.append(tok)
    return out[:MAX_TOKENS]


def load_lib(name):
    """A sibling module under hooks/lib, loaded by path (python3 -I keeps this script's directory off sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "lib", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def repo_dir(cwd):
    env = os.environ.get("SENDMESSAGE_SHA_GUARD_REPO")
    if env:
        return env
    here = cwd if isinstance(cwd, str) and os.path.isdir(cwd) else os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    top = subprocess.run(
        ["git", "-C", here, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=GIT_TIMEOUT_S
    )
    if top.returncode != 0:
        raise RuntimeError("not a repo")
    return top.stdout.strip()


def unresolved(tokens, repo):
    """The tokens git says are no commit. git exit 1 = unknown; any other failure (not a repo, no git) raises -> fail open."""
    bad = []
    for tok in tokens:
        r = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--verify", "--quiet", tok + "^{object}"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_S,
        )
        if r.returncode == 1:
            bad.append(tok)
        elif r.returncode != 0:
            raise RuntimeError("git failed")
    return bad


def main():
    try:
        hook = json.load(sys.stdin)
        if hook.get("tool_name") != "SendMessage":
            return 0
        message = hook.get("tool_input", {}).get("message")
        if not isinstance(message, str):
            return 0
        cwd = hook.get("cwd") if isinstance(hook.get("cwd"), str) else None
        tokens = candidates(message)
        if not tokens or not load_lib("kitgate").enabled(cwd):
            return 0
        bad = unresolved(tokens, repo_dir(cwd))
    except Exception:  # fail open: a broken hook must never block all messages
        return 0
    if bad:
        print(
            "sendmessage-sha-guard: REFUSED: git cannot resolve " + ", ".join(bad) + " to an object. Run `git rev-parse --short <ref>` for "
            "the real sha (or `git log -1 --format=%h <branch>`), fix the message, and send again. A word that only looks like a sha: "
            "write it with a non-hex letter or in a path.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
