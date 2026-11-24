#!/usr/bin/env python3
"""prettier directory guard: a Claude Code PreToolUse hook (Bash) that refuses `prettier --write` (or -w) on a directory.

Why: a `prettier --write <dir>` run rewrote files outside the row, twice, and the discard guard then blocked the revert. The rule
("write only the files you changed") was text only; this hook refuses the command before it runs. NO-OP unless the kit's safety
guards are on (hooks/lib/kitgate.py).

Refused (exit 2, ONE stderr line naming the rule and the safe form): a `prettier` call that carries `--write` or a short cluster holding
`w` AND at least one path argument that is `.`, `..`, ends in `/`, is a directory on disk (relative paths resolve against the hook's cwd),
or is a glob that matches a directory. The call is found in every segment split on `&&`, `;`, `|`, in subshells, `bash -c`/`eval`, and
behind wrappers (`npx`, `npx prettier@3`, `pnpm exec`, `pnpm -C <dir>`, `yarn`, `./node_modules/.bin/`, `xargs`, `env`, `time` ...). A
`find ... -exec prettier --write {}` is refused when find can list directories: `-type d`, or no `-type` and no name/path filter.
`--write=true` counts as --write (`--write=false` does not).
Allowed: file paths, globs that match files, `--check`/`-c`/`-l` on a directory, a call with no `--write`, a `--write` with no path
(`xargs` supplies them), and any text that only MENTIONS prettier (echo, grep, a commit message). A path that does not exist passes.
Parsing is hooks/lib/shellscan.py. Anything unreadable FAILS OPEN (exit 0).
No override: the safe form always exists (name the files: `prettier --write $(git diff --name-only -- '*.ts')`).

STATED LIMITS (a guard against accidents, not a sandbox): aliases, `pnpm format`-style scripts that run prettier internally, a path built by
substitution (`prettier --write $D`), `cd x && prettier --write y` where y is a directory only under x (resolved against the hook's cwd,
so it passes unless it also exists there), and a value of a prettier option this list does not know (read as a path).
"""
import glob
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_DEPTH = 6
# words that may sit between the command start and `prettier` (a package runner or a second wrapper)
RUNNERS = {"npx", "pnpm", "pnpx", "yarn", "bunx", "bun", "npm", "exec", "dlx", "run", "xargs", "env", "time", "node", "sudo", "nice"}
# prettier options whose value is the NEXT word when not attached with `=`. Only value options: the booleans (--use-tabs,
# --experimental-ternaries, --support-info, ...) take no value, so the word after them IS a path (r1: they were here and hid `src`).
VALUE_LONG = {
    "--config", "--ignore-path", "--parser", "--plugin", "--cache-location", "--cache-strategy", "--log-level", "--stdin-filepath",
    "--end-of-line", "--tab-width", "--print-width", "--config-precedence", "--object-wrap", "--quote-props",
    "--trailing-comma", "--arrow-parens", "--prose-wrap", "--html-whitespace-sensitivity", "--embedded-language-formatting",
    "--cursor-offset", "--range-start", "--range-end", "--find-config-path", "--file-info",
}
# runner options whose value is the NEXT word (`pnpm -C dir prettier`, `pnpm --filter x exec prettier`, `npx -p pkg prettier`): the scan skips both
RUNNER_VALUE_OPTS = {"-C", "--dir", "--filter", "-F", "--prefix", "--cwd", "-p", "--package", "--workspace"}
MSG = (
    "prettier-dir-guard: REFUSED `prettier {form}`: --write on a directory rewrites files outside your row (a past run did this twice)"
    ". Name the files: `prettier --write <file> ...` or `git diff --name-only -- <paths> | xargs prettier --write`."
)


def load_lib(name):
    """A sibling module under hooks/lib, loaded by path (python3 -I keeps this script's directory off sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "lib", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def is_dir_arg(arg, cwd):
    """True when a prettier path argument names a directory (`.`, `..`, a trailing `/`, a real directory, or a glob that matches one)."""
    if arg in (".", "..") or arg.endswith("/"):
        return True
    path = arg if os.path.isabs(arg) else os.path.join(cwd, arg)
    if any(c in arg for c in "*?["):
        try:
            return any(os.path.isdir(m) for m in glob.glob(path, recursive=True)[:2000])
        except OSError:
            return False
    return os.path.isdir(path)


def parse_args(args):
    """(is --write, path arguments) of the words after `prettier`."""
    write, paths, i = False, [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            paths += args[i + 1 :]
            break
        if a == "--write" or (a.startswith("-") and not a.startswith("--") and len(a) > 1 and "w" in a[1:]):
            write = True
        elif a.startswith("--write="):
            write = a.split("=", 1)[1].lower() not in ("false", "0", "no", "off")
        elif a in VALUE_LONG:
            i += 1  # its value is the next word
        elif not a.startswith("-"):
            paths.append(a)
        i += 1
    return write, paths


def write_on_dir(args, cwd):
    """The offending argument list (joined) when `args` (everything after the word prettier) is a --write on a directory, else None."""
    write, paths = parse_args(args)
    if write and any(is_dir_arg(p, cwd) for p in paths):
        return "--write " + " ".join(paths)
    return None


FIND_FILTERS = {"-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-wholename", "-iwholename"}


def find_exec_hit(words):
    """The refused form when `find ... -exec prettier --write {}` can hand prettier a directory, else None.

    find lists directories unless `-type f` (or another file-only type) or a name/path filter narrows it; a `-type d` always does."""
    types = [words[i + 1] for i, w in enumerate(words) if w == "-type" and i + 1 < len(words)]
    lists_dirs = "d" in types or (not types and not any(w in FIND_FILTERS for w in words))
    if not lists_dirs:
        return None
    for i, w in enumerate(words):
        if w in ("-exec", "-execdir", "-ok", "-okdir"):
            inner = words[i + 1 :]
            if "+" in inner:
                inner = inner[: inner.index("+")]
            k = prettier_index(inner, 0)
            if k is not None:
                write, paths = parse_args(inner[k + 1 :])
                if write and "{}" in paths:
                    return "--write {}  (find lists directories)"
    return None


def prettier_index(words, start):
    """Index of the `prettier` word when this simple command runs it (directly or behind runners), else None.

    `prettier@3` (a version suffix) counts; a runner option that takes a value (`pnpm -C x`, `--filter x`) is stepped over whole."""
    k, seen = start, 0
    while k < len(words) and seen < 8:
        w = words[k]
        base = w.rsplit("/", 1)[-1]
        if not base.startswith("@"):
            base = base.split("@", 1)[0]
        if base in ("prettier", "prettier.cjs", "prettier.js"):
            return k
        if w in RUNNER_VALUE_OPTS:
            k += 2
        elif base in RUNNERS or w.startswith("-"):
            k += 1
        else:
            return None
        seen += 1
    return None


def judge(sweep, command, cwd, depth=0):
    """The refused form of the first `prettier --write <dir>` in `command`, else None."""
    text, subs, _ = sweep.scan(sweep.strip_heredocs(command))
    if depth < MAX_DEPTH:
        for body in subs:
            hit = judge(sweep, body, cwd, depth + 1)
            if hit:
                return hit
    for words in map(sweep.strip_redirects, sweep.simple_commands(text)):
        if depth < MAX_DEPTH:
            for inner in sweep.nested_commands(words):
                hit = judge(sweep, inner, cwd, depth + 1)
                if hit:
                    return hit
        start, _ = sweep.command_start(words)
        if start >= len(words):
            continue
        k = prettier_index(words, start)
        if k is not None:
            hit = write_on_dir(words[k + 1 :], cwd)
            if hit:
                return hit
        if words[start].rsplit("/", 1)[-1] == "find":
            hit = find_exec_hit(words[start + 1 :])
            if hit:
                return hit
    return None


def main():
    try:
        hook = json.load(sys.stdin)
        if hook.get("tool_name") != "Bash":
            return 0
        command = hook.get("tool_input", {}).get("command")
        if not isinstance(command, str):
            return 0
        cwd = hook.get("cwd") if isinstance(hook.get("cwd"), str) else os.getcwd()
        if not load_lib("kitgate").enabled(cwd):
            return 0
        hit = judge(load_lib("shellscan"), command, cwd)
    except Exception:  # fail open: a broken hook must never block all work
        return 0
    if hit:
        print(MSG.format(form=hit), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
