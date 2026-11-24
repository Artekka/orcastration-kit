"""Shell-command scanner shared by the kit's Python hooks (discard-guard, pkill-full-guard).

Splits a Bash tool command into simple commands: heredoc bodies dropped, quotes kept, `bash -c` / `eval` / `$(...)` bodies
returned for a recursive look, `cd` and `git -C` followed. It is a tokenizer for a guard against ACCIDENTS, not a shell: aliases,
functions, `eval` of a variable and scripts are not inspected. Extracted from the tokenizer of the project that first wrote it
(git-sweep-guard.py); no rule of any guard lives here. A hook loads it by path (importlib), because a hook runs with
`python3 -I`, which keeps the script's own directory off sys.path.
"""
import os
import re
import shlex
import subprocess

# Shell keywords that run the next word as a command (`if x; then git stash; fi`, `{ git add -A; }`, `! git stash`).
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "{", "}", "!"}


# Wrapper commands that run the next command: (options that take a separate value, positional words to skip first).
WRAPPERS = {
    "env": ({"-u", "--unset", "-C", "--chdir"}, 0),
    "command": (set(), 0),
    "exec": ({"-a"}, 0),
    "nohup": (set(), 0),
    "time": (set(), 0),
    "sudo": ({"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t"}, 0),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, 0),
    "nice": ({"-n", "--adjustment"}, 0),
    "xargs": ({"-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"}, 0),
    "stdbuf": ({"-i", "-o", "-e"}, 0),
    "flock": ({"-w", "--timeout", "-E", "--conflict-exit-code"}, 1),  # the lock file comes first
    "setsid": (set(), 0),
    "ionice": ({"-c", "--class", "-n", "--classdata", "-p"}, 0),
    "chrt": (set(), 0),
}


# Wrapper options whose value is itself a command string (`env -S "git stash"`, `flock f -c "git stash"`).
STRING_OPTS = {"env": {"-S", "--split-string"}, "flock": {"-c", "--command"}}


SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


DURATION = re.compile(r"^[0-9]+(\.[0-9]+)?[smhd]?$")


ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


# git's global options that take the NEXT token as their value (`git -C dir add -A`).
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}


SEPARATORS = {";", "&", "|", "(", ")", "\n"}


# The delimiter may be bare, backslash-quoted (<<\EOF) or quoted with any text (<<'X-EOF').
HEREDOC = re.compile(
    r"""(?<!<)<<(?!<)(-?)\s*(?:\\([A-Za-z_][A-Za-z0-9_]*)|'([^'\n]+)'|"([^"\n]+)"|([A-Za-z_][A-Za-z0-9_]*))"""
)


def split_heredocs(text):
    """(text without heredoc bodies, the bodies): each body and its terminator line is dropped; the line that opens a heredoc stays."""
    out, bodies, pending = [], [], []
    for line in text.split("\n"):
        if pending:
            dash, word = pending[0]
            if (line.lstrip("\t") if dash else line) == word:
                pending.pop(0)
            else:
                bodies.append(line)
            continue
        out.append(line)
        pending = [(m.group(1) == "-", next(g for g in m.groups()[1:] if g is not None)) for m in HEREDOC.finditer(line)]
    return "\n".join(out), bodies


def strip_heredocs(text):
    """Drop every heredoc body and its terminator line; the line that opens a heredoc stays."""
    return split_heredocs(text)[0]


SUB = "__SUB__"


# Redirect operators as the lexer returns them; the word after one is its target, an optional digit before is the fd.
REDIRECT_OPS = {">", ">>", "<", "<<", "<<<", ">&", "<&", "&>", "&>>", ">|"}  # `>|` = the noclobber override


# A `#` starts a comment only at the start of a word.
WORD_START = set(" \t\r\n;&|()<>")


def scan(s, i=0, mode="top", subs=None):
    """Quote-aware pre-pass. Returns (clean text, command-substitution bodies, index where it stopped).

    Drops comments, joins backslash-newline, decodes $'...' into a plain quoted word and replaces every $(...) and
    backtick substitution (also inside double quotes) with an indexed placeholder word (SUB_INDEX), returning its raw body
    (subs[index]) so the caller can check it. mode: top | dq (inside "...") | sub (inside $(...)) | bt (inside backticks). An unterminated quote is
    copied through as is, so shlex fails on it and the hook fails open.
    """
    out, n, paren = [], len(s), 0
    subs = [] if subs is None else subs  # shared with the "..." scans below, so a placeholder index names its own body
    while i < n:
        c = s[i]
        if mode == "dq" and c == '"':
            break
        if mode == "bt" and c == "`":
            break
        if mode == "sub":
            if c == "(":
                paren += 1
            elif c == ")":
                if paren == 0:
                    break
                paren -= 1
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                out.append(" ")
            else:
                out.append(s[i : i + 2])
            i += 2
            continue
        if c == "'" and mode != "dq":
            j = s.find("'", i + 1)
            if j < 0:
                out.append(s[i:])
                return "".join(out), subs, n
            out.append(s[i : j + 1])
            i = j + 1
            continue
        if c == "$" and s.startswith("$'", i) and mode != "dq":
            j, buf = i + 2, []
            while j < n and s[j] != "'":
                if s[j] == "\\" and j + 1 < n:
                    j += 1
                buf.append(s[j])
                j += 1
            if j >= n:
                out.append(s[i:])
                return "".join(out), subs, n
            out.append("'" + "".join(buf).replace("'", "") + "'")
            i = j + 1
            continue
        if c == '"' and mode != "dq":
            body, _, j = scan(s, i + 1, "dq", subs)
            if j >= n:
                out.append('"' + body)
                return "".join(out), subs, n
            out.append('"' + body + '"')
            i = j + 1
            continue
        if c == "$" and s.startswith("$(", i):
            _, _, j = scan(s, i + 2, "sub")
            out.append(f"{SUB}{len(subs)}__")
            subs.append(s[i + 2 : j])
            i = min(j + 1, n)
            continue
        if c == "`" and mode != "bt":
            _, _, j = scan(s, i + 1, "bt")
            out.append(f"{SUB}{len(subs)}__")
            subs.append(s[i + 1 : j].replace("\\`", "`"))
            i = min(j + 1, n)
            continue
        if c == "#" and mode in ("top", "sub") and (i == 0 or s[i - 1] in WORD_START):
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out), subs, i


def simple_commands(text, marks=False):
    """Split a shell command line into simple commands (lists of words); quoted text stays one word.
    marks: a ( or ) also yields SUBSHELL_OPEN / SUBSHELL_CLOSE, so a caller can scope a `cd` to its subshell (r1)."""
    # The newline is an operator character here: it separates commands, so it must come back as a token (with
    # whitespace_split it would otherwise stay inside a word, and `git status<newline>git stash` read as one command).
    lex = shlex.shlex(text, posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    # Split only at whitespace and the operators: every other character (@ % + : , …) stays in its word, so
    # `-c user.email=a@b.c` is one value. With punctuation_chars, Python 3.8+ still splits at ; & | ( ).
    lex.whitespace_split = True
    lex.commenters = ""
    cmd, out = [], []
    for tok in lex:
        # An operator token splits when it holds a separator (`&&`, `;\n`, `)|`). `2>&1` splits too, which is
        # harmless: the `1` becomes a command of its own that runs nothing.
        if tok in REDIRECT_OPS:
            cmd.append(tok)  # `>&` and `&>` hold a separator character but are redirects, not command breaks
        elif tok and all(c in "();<>|&\n" for c in tok) and any(c in SEPARATORS for c in tok):
            for c in tok if marks else "":
                if c in "()":
                    if cmd:
                        out.append(cmd)
                        cmd = []
                    out.append(SUBSHELL_OPEN if c == "(" else SUBSHELL_CLOSE)
                elif c in SEPARATORS and cmd:
                    out.append(cmd)
                    cmd = []
            if cmd:
                out.append(cmd)
            cmd = []
        else:
            cmd.append(tok)
    if cmd:
        out.append(cmd)
    return out


def strip_redirects(words):
    """Drop redirections (`2>/dev/null`, `>&1`, `<<EOF`) so they cannot hide the command word or pose as a pathspec."""
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w in REDIRECT_OPS:
            i += 2
        elif w.isdigit() and i + 1 < len(words) and words[i + 1] in REDIRECT_OPS:
            i += 3
        else:
            out.append(w)
            i += 1
    return out


def command_start(words):
    """(index of the word that really runs, command strings given to wrapper options like `env -S`).

    Skips keywords, env assignments and wrapper commands together with their own options."""
    i, extras = 0, []
    while i < len(words):
        w = words[i]
        base = w.rsplit("/", 1)[-1]
        if w in KEYWORDS or ASSIGN.match(w):
            i += 1
        elif base in WRAPPERS:
            valued, positional = WRAPPERS[base]
            string_opts = STRING_OPTS.get(base, ())
            i += 1
            while i < len(words):
                x = words[i]
                if x in string_opts:
                    if i + 1 < len(words):
                        extras.append(words[i + 1])
                    i += 2
                elif any(x.startswith(o + "=") for o in string_opts if o.startswith("--")):
                    extras.append(x.split("=", 1)[1])
                    i += 1
                elif x in valued:
                    i += 2
                elif x.startswith("-") and len(x) > 1 or DURATION.match(x) or ASSIGN.match(x):
                    i += 1
                elif positional:
                    positional -= 1
                    i += 1
                else:
                    break
        else:
            break
    return i, extras


def git_subcommand(words):
    """(subcommand, its args) when this simple command runs git, else None."""
    i, _ = command_start(words)
    if i >= len(words) or words[i].rsplit("/", 1)[-1] != "git":
        return None
    i += 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in GIT_VALUE_OPTS else 1
    if i >= len(words):
        return None
    return words[i], words[i + 1 :]


def nested_commands(words):
    """The command strings a nested shell (`bash -c STR`), `eval` or a wrapper option would run: same check for them."""
    i, found = command_start(words)
    if i >= len(words):
        return found
    base = words[i].rsplit("/", 1)[-1]
    if base == "eval":
        found.append(" ".join(words[i + 1 :]))
    elif base in SHELLS:
        for j in range(i + 1, len(words)):
            w = words[j]
            if w.startswith("-") and not w.startswith("--") and "c" in w[1:]:
                if j + 1 < len(words):
                    found.append(words[j + 1])
                break
            if not w.startswith("-"):
                break
    return found


def resolve_dir(base, target):
    """`target` resolved against `base`, or None for anything the hook cannot know (variable, substitution, ~, empty)."""
    if not target or any(c in target for c in "$`~") or SUB in target:
        return None
    path = target if os.path.isabs(target) else os.path.join(base, target)
    return path if os.path.isdir(path) else None


VAR_REF = re.compile(r"\$\{(\w+)\}|\$(\w+)")


def expand_word(word, assigns):
    """`word` with a leading ~, $HOME / ${HOME} and every in-line assigned $NAME / ${NAME} expanded, or None when a variable
    nobody assigned in this command line, a substitution or a `~user` is left (the value cannot be known from the text)."""
    if SUB in word or "`" in word:
        return None
    home = os.environ.get("HOME")
    if word == "~" or word.startswith("~/"):
        if not home:
            return None
        word = home + word[1:]
    def sub(m):
        name = m.group(1) or m.group(2)
        val = home if name == "HOME" and (assigns is None or name not in assigns) else (assigns or {}).get(name)
        return val if val is not None else "\x00"
    word = VAR_REF.sub(sub, word)
    return None if "\x00" in word or "$" in word or word.startswith("~") else word


def step_dir(base, target, assigns, planned=()):
    """Where a `cd <target>` / `git -C <target>` run from `base` ends up: None = unknown (an unexpandable word, or `base` itself
    unknown for a relative target); `base` when the directory is missing (the shell stays where it was), unless an earlier
    `git worktree add` of this line names it (`planned`): that directory will exist by the time the shell gets there."""
    word = expand_word(target, assigns) if target else None
    if word is None:
        return None
    if not os.path.isabs(word):
        if base is None:
            return None
        word = os.path.join(base, word)
    return word if os.path.isdir(word) or os.path.normpath(word) in planned else base


def git_where(words, here, assigns=None, strict=False, planned=()):
    """The directory a `git ... commit` runs in: the cwd moved by every `-C <dir>` before the subcommand.
    strict: in-line assignments, $HOME and ~ are expanded, and a target that cannot be
    known makes the result None; otherwise an unknown target keeps the last known directory (as before)."""
    i, _ = command_start(words)
    j, where = i + 1, here
    while j < len(words) and words[j].startswith("-"):
        if words[j] == "-C" and j + 1 < len(words):
            if strict:
                where = step_dir(where, words[j + 1], assigns, planned)
            else:
                where = resolve_dir(where, words[j + 1]) or where
        j += 2 if words[j] in GIT_VALUE_OPTS else 1
    return where


ADD_LONG_VALUE = {"--chmod", "--pathspec-from-file"}


def git_toplevel(directory):
    """Realpath of the worktree root that holds `directory`, or None (not a repo, git missing, timeout)."""
    try:
        out = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=3
        )
    except Exception:
        return None
    return os.path.realpath(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None
