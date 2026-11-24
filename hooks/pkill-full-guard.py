#!/usr/bin/env python3
"""pkill -f guard: a Claude Code PreToolUse hook (Bash) that refuses `pkill -f` / `pkill --full`.

Why: sibling sessions share one host and often one command line (a gate, a test run, a tmux pane), so a pattern kill takes down
another session's work. A text rule ("never pkill -f by pattern") kept being broken; a rule that keeps being broken needs a
mechanism, so this hook refuses the command before it runs. NO-OP unless the kit's safety guards are on (hooks/lib/kitgate.py).

Refused (exit 2, ONE stderr line naming the rule and the safe form): a `pkill` command with `--full`, or a short flag cluster that holds
`f`, in any position: `-f`, `-9f`, `-fi`, `-u x -f`, `-TERM -f`, `pkill pat -f`. The command is found inside `;`/`&&`/`|` chains, subshells,
`bash -c`/`eval`, `$(...)`, backticks, env prefixes and wrappers (sudo, timeout, nohup ...).
Allowed: pkill by exact name or with -x, `pkill -u f` (f is the user name), `pkill -uf` (-u takes `f` as its value), `pgrep -f` (read-only),
`kill <pid>`, `killall`, and any text that only MENTIONS pkill -f (echo, grep, a commit message, a heredoc body, a comment).
Parsing is hooks/lib/shellscan.py. Anything unreadable FAILS OPEN (exit 0).
No override: the rule has no legitimate exception, the safe form always exists (find the exact pid, `kill <pid>`).

ALSO covered: the remote command of `ssh` (plain, quoted, after `sudo`/`sh -c`, options before or after the host): every word after `ssh` is
looked at, a word named pkill starts a pkill command, a quoted remote string is judged like `bash -c`. Cost: a host or option value
literally named "pkill" followed by -f is refused (harmless direction). ssh's own options are not modeled. Also `--f`, `--fu`, `--ful` (getopt_long takes any
unique prefix of --full).

STATED LIMITS (a guard against accidents, not a sandbox). NOT modeled, so these pass: aliases and wrapper functions, a flag built by
substitution (`pkill $F x`), a script file that runs pkill -f internally, `find -exec pkill -f`, `watch pkill -f`, `coproc`,
`bash <<EOF` bodies (heredoc bodies are dropped), nesting deeper than 6, `python -c` / `node -e` that shell out, ssh through a
ProxyCommand or a config alias that runs a command, a remote command whose pkill name is built by the remote shell, and ssh options
that carry a command (`-o RemoteCommand=...`, `-o LocalCommand=...`).
"""
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_DEPTH = 6
# pkill short options whose value is the NEXT word (or the rest of the cluster): letters after one of these are a value, not flags.
# Checked against `pkill --help` (procps-ng 4.0.4): -q -g -G -O -P -s -t -u -U -F -r take a value; -c (--count) does not.
VALUE_SHORT = set("qgGOPstuUFr")
# pkill long options whose value is the NEXT word when not attached with `=` (`--ns 1`, `--signal TERM`).
VALUE_LONG = {
    "--ns", "--nslist", "--cgroup", "--signal", "--queue", "--pgroup", "--group", "--session", "--terminal",
    "--euid", "--uid", "--pidfile", "--runstates", "--older", "--parent",
}
MSG = (
    "pkill-full-guard: REFUSED `pkill {form}`: a pattern kill matches every session's command line, and sibling sessions share the host "
    "(never pkill -f by pattern). Find the exact pid (`pgrep -f <pattern>` to look, it is read-only), then `kill <pid>`."
)


def load_lib(name):
    """A sibling module under hooks/lib, loaded by path (python3 -I keeps this script's directory off sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "lib", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def full_flag(args):
    """The offending flag of a pkill argument list (`-9f`, `--full`), or None. Stops at `--`; skips the value of -u/-U/..."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return None
        if a in VALUE_LONG:
            i += 2
            continue
        if a.startswith("--") and "--full".startswith(a):
            return a  # getopt_long takes any unique prefix; `--f` is the only long option starting with f (checked on this host)
        if a.startswith("-") and not a.startswith("--") and len(a) > 1:
            for k, ch in enumerate(a[1:]):
                if ch == "f":
                    return a
                if ch in VALUE_SHORT:
                    if k == len(a) - 2:
                        i += 1  # value is the next word (`-u x`); attached (`-uf`) is consumed by the rest of this cluster
                    break
        i += 1
    return None


def judge(sweep, command, depth=0):
    """The refused form (`<args>`) of the first `pkill -f` in `command`, else None."""
    text, subs, _ = sweep.scan(sweep.strip_heredocs(command))
    if depth < MAX_DEPTH:
        for body in subs:
            hit = judge(sweep, body, depth + 1)
            if hit:
                return hit
    for words in map(sweep.strip_redirects, sweep.simple_commands(text)):
        if depth < MAX_DEPTH:
            for inner in sweep.nested_commands(words):
                hit = judge(sweep, inner, depth + 1)
                if hit:
                    return hit
        start, _ = sweep.command_start(words)
        if start >= len(words):
            continue
        # `$(true)pkill` is a command word that expands to `pkill`: the scan leaves a placeholder in front of the name, so drop it
        # (an empty or unknown substitution reads as pkill: a refusal in the harmless direction)
        name = re.sub(r"^(?:__SUB__\d+__)+", "", words[start].rsplit("/", 1)[-1])
        if name == "pkill":
            flag = full_flag(words[start + 1 :])
            if flag:
                return flag
        elif name == "ssh" and depth < MAX_DEPTH:
            # ssh takes options after the host too, so its options are NOT modeled: every later word is looked at. A word whose
            # basename is pkill starts a pkill command; a word with a space is a quoted remote command, judged like `bash -c`.
            for k in range(start + 1, len(words)):
                w = words[k]
                # the remote shell RE-JOINS the words after the host with spaces and parses the result, so a word can end a command that
                # another word starts (`ssh h "x=1;pkill" -f y`, `ssh h true\;pkill -f x`): judge the joined tail as shell text too
                hit = judge(sweep, " ".join(words[k:]), depth + 1)
                if hit:
                    return hit
                if w.rsplit("/", 1)[-1] == "pkill":
                    flag = full_flag(words[k + 1 :])
                    if flag:
                        return flag
                elif any(c.isspace() for c in w):
                    hit = judge(sweep, w, depth + 1)
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
        cwd = hook.get("cwd") if isinstance(hook.get("cwd"), str) else None
        if not load_lib("kitgate").enabled(cwd):
            return 0
        hit = judge(load_lib("shellscan"), command)
    except Exception:  # fail open: a broken hook must never block all work
        return 0
    if hit:
        print(MSG.format(form=hit + " ..."), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
