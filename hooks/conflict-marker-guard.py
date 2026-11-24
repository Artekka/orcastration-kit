#!/usr/bin/env python3
"""Conflict-marker guard: a Claude Code PreToolUse hook that refuses a commit-making git command while the content it would
commit holds a merge-conflict marker.

Why: a failed resolve script was followed by an unchained `git add` + `--continue` four times, and conflict markers were committed.
Text rules did not stop it. NO-OP unless the kit's safety guards are on (hooks/lib/kitgate.py).

It reads the PreToolUse JSON on stdin, uses hooks/lib/shellscan.py (chains, `bash -c`, `$(...)`, `cd` and `git -C` followed), and
judges each git command. Refused = exit 2 with ONE stderr line naming each file:line and the fix. Anything it cannot read
(malformed JSON, a non-Bash tool, an unbalanced quote, no repo, git failing or timing out) FAILS OPEN: a broken hook must never block
all work. A crash inside the judge also exits 0, with one stderr line saying so.

Judged commands: `git commit`, `git cherry-pick|rebase|merge|revert|am --continue` (and `git am --resolved` / `-r`, its old names).
What counts: an ADDED line, at column 0, that is `<<<<<<< ` + anything, exactly `=======`, or `>>>>>>> ` + anything. A lone `=======`
(no `<<<<<<< ` or `>>>>>>> ` line in the same file's counted lines) is documentation, such as a setext underline, and passes. Sources:
  1. the STAGED content: `git diff --cached -U0` (never the working tree, so an unstaged marker passes);
  2. what an EARLIER command of the same chain would stage, because the hook runs before the chain does and nothing is staged yet:
     `git add <file>` (the file on disk), `git add <dir|glob|.>`, `-u`, `-A`, `--all` (the modified or unmerged tracked files under
     the path, per `git status --porcelain`), and `git commit -a|--all|-am` (all of them).
No-false-refusal rules (pinned by tests): only column-0 lines count (a marker inside a string, an indented sample or a quoted doc
line passes), and ALLOWLIST below names the few paths that hold markers at column 0 on purpose.
Override: `ALLOW_CONFLICT_MARKERS=1 git commit ...` (a prefix assignment) or ALLOW_CONFLICT_MARKERS=1 in the hook's environment.
Read-only: every git call runs with `--no-optional-locks`, so `git status` never refreshes `.git/index`. Time-bounded: one deadline
(CONFLICT_MARKER_GUARD_DEADLINE_S, default 8 s, under the registered 10 s hook timeout) covers the whole run; past it the hook fails
open with one stderr line.
Known gaps (deliberate-evasion shapes): `git commit <path>` (commits the path from disk), `git add` of an UNTRACKED file through a
directory or glob, aliases and wrapper functions, a path list built by substitution, an `add`/`commit` in a script the command
only runs, and `git commit --dry-run` (judged like a commit).
"""
import importlib.util
import json
import os
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GIT_TIMEOUT_S = 5
MAX_LISTED = 20
MAX_BYTES = 5_000_000
DEADLINE_S = 8.0  # the registered hook timeout is 10 s; a hanging git must not use it all
# Paths (relative to the repo root) that hold marker lines at column 0 on purpose: this guard and its test.
ALLOWLIST = {
    "hooks/conflict-marker-guard.py",
    "tests/hooks-conflict-marker.test.sh",
}
FIX = (
    "Fix: resolve the markers in each file (keep the right side, delete the marker lines), `git add` it again, then retry "
    "(or prefix the command with ALLOW_CONFLICT_MARKERS=1 if the marker text is intended)."
)
CONTINUING = {"cherry-pick", "rebase", "merge", "revert", "am"}
CONTINUE_FLAGS = {"--continue"}
AM_RESOLVED = {"--resolved", "-r"}  # `git am --resolved` is the old name of --continue
ADD_BROAD = {"-u", "--update", "-A", "--all"}


def load_lib(name):
    """A sibling module under hooks/lib, loaded by path (python3 -I keeps this script's directory off sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "lib", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Deadline(BaseException):
    """Raised by the alarm. A BaseException so the helpers' `except Exception` (which fail open per call) cannot swallow it."""


def on_alarm(signum, frame):
    raise Deadline()


def marker_kind(line):
    """'<' start, '=' middle, '>' end marker, else None (the line has its CR/LF already stripped)."""
    if line.startswith("<<<<<<< "):
        return "<"
    if line == "=======":
        return "="
    if line.startswith(">>>>>>> "):
        return ">"
    return None


def git(directory, *args):
    """stdout of `git -C directory args`, or None when git failed or timed out (the caller fails open)."""
    try:
        out = subprocess.run(
            ["git", "--no-optional-locks", "-C", directory, "-c", "core.quotepath=off", *args],
            capture_output=True, text=True, errors="replace", timeout=GIT_TIMEOUT_S,
        )
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None


def staged_hits(top):
    """{(path, line number, kind)} of marker lines ADDED in the index versus HEAD (a new repo with no HEAD diffs against the empty tree)."""
    out = git(top, "diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--no-renames")
    if out is None:
        return set()
    hits, path, lineno = set(), None, 0
    for raw in out.split("\n"):
        if raw.startswith("+++ "):
            name = raw[4:].strip().strip('"')
            path = name[2:] if name.startswith("b/") else None  # /dev/null = a deletion
        elif raw.startswith("@@"):
            try:
                lineno = int(raw.split("+", 1)[1].split()[0].split(",")[0])
            except (IndexError, ValueError):
                lineno = 0
        elif raw.startswith("+") and not raw.startswith("+++") and path:
            kind = marker_kind(raw[1:].rstrip("\r"))
            if kind:
                hits.add((path, lineno, kind))
            lineno += 1
    return hits


def file_hits(top, rel):
    """{(rel, line number, kind)} of marker lines in the working-tree file `rel` (relative to the repo root)."""
    full = os.path.join(top, rel)
    try:
        if not os.path.isfile(full) or os.path.getsize(full) > MAX_BYTES:
            return set()
        with open(full, "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return set()
    return {(rel, n, k) for n, line in enumerate(text.split("\n"), 1) for k in [marker_kind(line.rstrip("\r"))] if k}


def dirty_files(top, where, pathspecs):
    """Tracked files modified or unmerged in the working tree under `pathspecs` ([] = everything), relative to the repo root."""
    out = git(where, "status", "--porcelain=v1", "-z", "--untracked-files=no", *(["--", *pathspecs] if pathspecs else []))
    if out is None:
        return []
    entries, files, i = out.split("\0"), [], 0
    while i < len(entries):
        e = entries[i]
        i += 1
        if len(e) < 4:
            continue
        if e[0] in "RC":
            i += 1  # a rename / copy entry carries its origin as the next field
        files.append(e[3:])
    return files


def add_targets(args, sweep):
    """(broad flag, pathspecs, usable) for a `git add <args>`; usable False = a path only a substitution reveals (fail open)."""
    broad, paths, rest, i = False, [], False, 0
    while i < len(args):
        a = args[i]
        if rest:
            paths.append(a)
        elif a == "--":
            rest = True
        elif a in sweep.ADD_LONG_VALUE:
            i += 1
        elif a in ADD_BROAD or (a.startswith("-") and not a.startswith("--") and set(a[1:]) & {"u", "A"}):
            broad = True
        elif not (a.startswith("-") and len(a) > 1):
            paths.append(a)
        i += 1
    ok = not any(sweep.SUB in p or "$" in p or "`" in p for p in paths)
    return broad, paths, ok


def commit_all(args):
    """True for `git commit -a`, `--all` or a short cluster holding `a` before its value letter (`-am`, `-sa`)."""
    value_letters = set("mFCct")
    for a in args:
        if a == "--":
            break
        if a == "--all":
            return True
        if a.startswith("-") and not a.startswith("--"):
            for ch in a[1:]:
                if ch == "a":
                    return True
                if ch in value_letters:
                    break
    return False


def judge(sweep, command, here, depth=0):
    """(form, repo directory, [(path, line)]) for the first continuing command in `command` that would commit a marker, else None."""
    text, subs, _ = sweep.scan(sweep.strip_heredocs(command))
    if depth < 6:
        for body in subs:
            hit = judge(sweep, body, here, depth + 1)
            if hit:
                return hit
    planned = []  # (toplevel, where, broad, pathspecs): what earlier `git add`s of this command line will stage
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
        if name == "add":
            broad, paths, ok = add_targets(args, sweep)
            top = sweep.git_toplevel(where)
            if ok and top:
                planned.append((top, where, broad, paths))
            continue
        everything = False
        if name == "commit":
            form, everything = "git commit", commit_all(args)
        elif name in CONTINUING and (CONTINUE_FLAGS & set(args) or (name == "am" and AM_RESOLVED & set(args))):
            # Name the flag that continues. `-r` / `--resolved` are only `git am`'s old names for --continue; on any other
            # command `-r` is another option (rebase -r = --rebase-merges) and must never head the message.
            # The condition above lets AM_RESOLVED in for `am` only, and the sort puts --continue first, so `rebase -r --continue` reads --continue.
            form = "git " + name + " " + next(a for a in sorted(args, key=lambda x: x not in CONTINUE_FLAGS) if a in CONTINUE_FLAGS | AM_RESOLVED)
        else:
            continue
        if any(w == "ALLOW_CONFLICT_MARKERS=1" for w in words[:start]):
            continue
        top = sweep.git_toplevel(where)
        if not top:
            continue
        if os.environ.get("CONFLICT_MARKER_GUARD_TEST_CRASH") == "1":
            raise RuntimeError("test crash")  # pinned by the fail-open test
        found = staged_hits(top)
        for ptop, pwhere, broad, paths in planned:
            if ptop != top:
                continue
            if broad and not paths:
                files = dirty_files(top, pwhere, [])
            else:
                files = []
                for p in paths:
                    full = p if os.path.isabs(p) else os.path.join(pwhere, p)
                    if os.path.isfile(full):
                        files.append(os.path.relpath(os.path.realpath(full), top))
                    else:
                        files += dirty_files(top, pwhere, [p])
            for rel in files:
                found |= file_hits(top, rel)
        if everything:
            for rel in dirty_files(top, where, []):
                found |= file_hits(top, rel)
        found = {h for h in found if h[0] not in ALLOWLIST}
        # a lone `=======` (no start or end marker in the same file) is documentation, not a conflict
        real = {h[0] for h in found if h[2] in "<>"}
        found = {(p, n) for p, n, k in found if p in real}
        if found:
            return form, where, sorted(found)
    return None


def main():
    try:
        try:
            budget = float(os.environ.get("CONFLICT_MARKER_GUARD_DEADLINE_S", DEADLINE_S))
        except ValueError:
            budget = DEADLINE_S
        signal.signal(signal.SIGALRM, on_alarm)
        signal.setitimer(signal.ITIMER_REAL, max(budget, 0.05))
        hook = json.load(sys.stdin)
        if hook.get("tool_name") != "Bash":
            return 0
        command = hook.get("tool_input", {}).get("command")
        if not isinstance(command, str) or os.environ.get("ALLOW_CONFLICT_MARKERS") == "1":
            return 0
        cwd = hook.get("cwd") if isinstance(hook.get("cwd"), str) else None
        if not load_lib("kitgate").enabled(cwd):
            return 0
        hit = judge(load_lib("shellscan"), command, cwd or os.getcwd())
    except Deadline:  # fail open: a hanging git must not hold the command past the hook timeout
        print(f"conflict-marker-guard: failed open (deadline of {budget:g} s passed); the command was not checked", file=sys.stderr)
        return 0
    except Exception as e:  # fail open: a broken hook must never block all work
        print(f"conflict-marker-guard: failed open ({type(e).__name__}: {e}); the command was not checked", file=sys.stderr)
        return 0
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    if hit:
        form, where, found = hit
        listed = ", ".join(f"{p}:{n}" for p, n in found[:MAX_LISTED]) + (
            f" (+{len(found) - MAX_LISTED} more)" if len(found) > MAX_LISTED else ""
        )
        print(
            f"conflict-marker-guard: refused `{form}`: conflict markers (<<<<<<<, =======, >>>>>>>) would be committed in {where}: {listed}. {FIX}",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
