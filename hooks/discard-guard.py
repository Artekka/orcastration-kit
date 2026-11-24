#!/usr/bin/env python3
"""Discard guard: a Claude Code PreToolUse hook that refuses a git command which would throw away uncommitted edits.

Why: `git checkout -- <path>`, `git checkout <ref> -- <path>`, `git restore <path>` and `git reset --hard` overwrite the working tree
with no way back, and a worktree often holds edits this session did not make (a sibling's WIP, a half-done file). A text rule
("don't revert a dirty tree you didn't cause") kept failing, so this hook refuses the command when the paths it would overwrite have
uncommitted edits IN THAT WORKTREE, and names them.

It reads the PreToolUse JSON on stdin, splits the Bash command into simple commands (hooks/lib/shellscan.py: heredoc bodies dropped,
quotes kept, `bash -c`/`eval`/`$(...)` checked recursively, `cd`/`git -C` followed), and judges each git command. Refused = exit 2
with ONE stderr line naming the form, the dirty paths and the fix. Anything it cannot read (malformed JSON, a non-Bash tool, an
unbalanced quote, no repo, git failing or timing out, a path only a substitution reveals) FAILS OPEN: a broken hook must never block
all work. NO-OP unless the kit's safety guards are on (hooks/lib/kitgate.py: marker docs/orchestration/.kit-hooks and
`safety_guards: on` in ORCHESTRATION.md).

Refused, when `git diff --name-only HEAD -- <paths>` (staged or unstaged edits against HEAD, in the worktree the command runs in)
is not empty:
  - `git checkout [<ref>] -- <path>...`
  - `git checkout <path>...`, `git checkout <ref> <path>...`   (no `--`: the first word is a ref only when `git rev-parse --verify
                                                  -q <word>^{commit}` succeeds AND no path of that name exists; the rest are pathspecs)
  - `git checkout -f|--force [<ref>]`, `git switch -f|--force|--discard-changes`   (a "branch switch" that throws edits away:
                                                  judged against every tracked edit in the worktree)
  - `git restore [options] <path>...`             unless it is `--staged` alone (the index only; the working tree is kept)
  - `git reset --hard [<ref>]`                    every tracked edit in the worktree
Never refused: a clean path, an untracked path (git refuses those itself), a dirty file in ANOTHER worktree, `reset --soft/--mixed`,
`git restore --staged`, `git checkout <branch>`, `git switch <branch>`.
Override: `ALLOW_DISCARD=1 git checkout -- x` (a prefix assignment of the command) or ALLOW_DISCARD=1 in the hook's own environment.
Known gaps (deliberate-evasion shapes): aliases and wrapper functions, a path list built by substitution, `git checkout -p`,
`git stash`-style cousins (the kit's git-guard.sh owns those), and `git clean`.
"""
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GIT_TIMEOUT_S = 3
MAX_LISTED = 20


def load_lib(name):
    """A sibling module under hooks/lib, loaded by path (python3 -I keeps this script's directory off sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "lib", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# git restore options that take the NEXT word as their value (`--source=<ref>` is one word and needs nothing).
RESTORE_VALUE_OPTS = {"-s", "--source"}


def restore_target(args):
    """(touches the working tree, pathspecs) for `git restore <args>`."""
    staged = worktree = False
    paths, i, rest = [], 0, False
    while i < len(args):
        a = args[i]
        if rest:
            paths.append(a)
        elif a == "--":
            rest = True
        elif a in ("--staged", "-S"):
            staged = True
        elif a in ("--worktree", "-W"):
            worktree = True
        elif a in RESTORE_VALUE_OPTS:
            i += 1  # `-s <ref>` / `--source <ref>`: the ref is not a path
        elif a.startswith("-") and len(a) > 1:
            if not a.startswith("--"):  # combined short flags (`-SW`)
                staged = staged or "S" in a[1:]
                worktree = worktree or "W" in a[1:]
        else:
            paths.append(a)
        i += 1
    return (worktree or not staged), paths


# git checkout / switch options that take the NEXT word as their value (a new branch name, not a path or a ref).
CHECKOUT_VALUE_OPTS = {"-b", "-B", "--orphan"}
SWITCH_VALUE_OPTS = {"-c", "-C", "--create", "--force-create", "--orphan"}


def is_force(a):
    """True for `-f`, `--force`, or a combined short flag holding f (`-fq`)."""
    return a == "--force" or (a.startswith("-") and not a.startswith("--") and "f" in a[1:])


def is_ref(directory, word):
    """True when `word` names a commit and no file of that name exists; None = git could not answer (fail open)."""
    if os.path.lexists(os.path.join(directory, word)):
        return False
    try:
        out = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--verify", "-q", word + "^{commit}"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_S,
        )
    except Exception:
        return None
    return out.returncode == 0


def checkout_target(args, directory):
    """(form, pathspecs) for a `git checkout <args>` that can discard edits, else None.

    With `--`: everything after it is a pathspec. Without: the first word is a ref only when it names a commit and no path of that
    name exists (`git checkout .`, `a.ts`, `HEAD a.ts` discard; `git checkout main` switches); `-f` makes even a plain switch a discard.
    """
    if "--" in args:
        paths = args[args.index("--") + 1 :]
        return "git checkout " + ("<ref> " if args and args[0] != "--" else "") + "-- " + " ".join(paths), paths
    force, words, i = False, [], 0
    while i < len(args):
        a = args[i]
        if a in CHECKOUT_VALUE_OPTS:
            i += 1
        elif a.startswith("-") and len(a) > 1:
            force = force or is_force(a)
        else:
            words.append(a)
        i += 1
    ref = False
    if words:
        ref = is_ref(directory, words[0])
        if ref is None:
            return None
    paths = words[1:] if ref else words
    if paths:
        return "git checkout " + " ".join(words), paths
    if force:
        return "git checkout -f" + (" " + words[0] if words else ""), []
    return None


def switch_discards(args):
    """`git switch -f|--force|--discard-changes` throws away tracked edits; returns its form or None."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in SWITCH_VALUE_OPTS:
            i += 1
        elif a == "--discard-changes" or is_force(a):
            return "git switch " + a
        i += 1
    return None


def dirty_paths(sweep, directory, paths):
    """Tracked paths with edits against HEAD (staged or unstaged) under `paths` ([] = the whole worktree), or None to fail open."""
    if any(sweep.SUB in p or "$" in p or "`" in p for p in paths):
        return None  # only a substitution reveals the path: cannot judge
    try:
        out = subprocess.run(
            ["git", "-C", directory, "diff", "--name-only", "HEAD", "--", *paths],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_S,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None  # not a repo, no HEAD yet, a bad pathspec: git will say so itself
    return [p for p in out.stdout.split("\n") if p]


def judge(sweep, command, here, depth=0):
    """(form, directory, dirty paths) for the first discarding git command in `command` that would lose edits, else None."""
    text, subs, _ = sweep.scan(sweep.strip_heredocs(command))
    if depth < 6:
        for body in subs:
            hit = judge(sweep, body, here, depth + 1)
            if hit:
                return hit
    for words in map(sweep.strip_redirects, sweep.simple_commands(text)):
        if depth < 6:
            for inner in sweep.nested_commands(words):
                hit = judge(sweep, inner, here, depth + 1)
                if hit:
                    return hit
        start, _ = sweep.command_start(words)
        if start < len(words) and words[start].rsplit("/", 1)[-1] == "cd":
            args = [w for w in words[start + 1 :] if w != "--" and not (w.startswith("-") and len(w) > 1)]
            here = (sweep.resolve_dir(here, args[0]) if args else None) or here
            continue
        sub = sweep.git_subcommand(words)
        if not sub:
            continue
        name, args = sub
        where = sweep.git_where(words, here)
        if name == "checkout":
            target = checkout_target(args, where)
            paths, form = (target[1], target[0]) if target else (None, None)
        elif name == "switch":
            form = switch_discards(args)
            paths = [] if form else None
        elif name == "restore":
            touches, paths = restore_target(args)
            if not touches:
                continue
            form = "git restore " + " ".join(paths)
        elif name == "reset" and "--hard" in args:
            paths, form = [], "git reset --hard"
        else:
            continue
        if paths is None:
            continue
        if any(w == "ALLOW_DISCARD=1" for w in words[:start]):
            continue
        dirty = dirty_paths(sweep, where, paths)
        if dirty:
            return form.strip(), where, dirty
    return None


def main():
    try:
        hook = json.load(sys.stdin)
        if hook.get("tool_name") != "Bash":
            return 0
        command = hook.get("tool_input", {}).get("command")
        if not isinstance(command, str) or os.environ.get("ALLOW_DISCARD") == "1":
            return 0
        cwd = hook.get("cwd") if isinstance(hook.get("cwd"), str) else None
        if not load_lib("kitgate").enabled(cwd):
            return 0
        hit = judge(load_lib("shellscan"), command, cwd or os.getcwd())
    except Exception:  # fail open: a broken hook must never block all work
        return 0
    if hit:
        form, where, dirty = hit
        listed = ", ".join(dirty[:MAX_LISTED]) + (f" (+{len(dirty) - MAX_LISTED} more)" if len(dirty) > MAX_LISTED else "")
        print(
            f"discard-guard: refused `{form}`: uncommitted edits in {where} would be lost: {listed}. "
            "Commit or copy them first (or prefix the command with ALLOW_DISCARD=1 if the loss is intended).",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
