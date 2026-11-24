#!/usr/bin/env python3
"""Real-data check: fails when an id-, uuid-, sha- or timestamp-like token in the shippable tree
is a REAL value: a whole native value in the local Claude Code logs, or a commit in this repo.

Test fixtures must be invented, never copied (or scrambled) from a real log. This check reads
the logs (read-only) and looks for each token from the tree as a native JSON value there:
  a whole string value (sessionId, uuid, timestamp, id ...) equal to the token,
  a path or URL value whose last segment is the token,
  a uuid value whose first block is an 8-hex token,
  a number (6+ digits) under the same key (pid, procStart ...).
Free text never counts: a tool result, a command, a message or a file a session wrote can hold
any token (this very check's runs print them), so values under those keys are skipped. Stage 1 is
a fast fixed-string grep; stage 2 parses each matched line as JSON. Hex tokens are also looked up
as commits in every git repo a logged session ran in (real SHAs).

Hits print as `file:line: <kind> token #N`; the tokens themselves never reach a log unless
--show is given.

Usage: python3 scripts/real-data-check.py [--repo DIR] [--logs DIR] [--show]
  logs: $OBSERVATORY_CLAUDE_LOGS, else ~/.claude/projects
  exit 0 = clean, or SKIPPED (no logs dir, not strict) · 1 = hits · 2 = unusable input
Strict mode (missing logs FAIL instead of SKIPPING), the same switch as scripts/clean-tree.py:
  OBSERVATORY_STRICT_CHECKS=1, or a file named `strict-checks` in the config dir
  ($OBSERVATORY_CONFIG_DIR, else $XDG_CONFIG_HOME/observatory, else ~/.config/observatory).
"""
import argparse, json, os, re, subprocess, sys, tempfile

SHIP = ['crates', 'scripts', 'Cargo.toml', 'Cargo.lock', 'docs/BRIEF.md', 'README.md', '.claude', ':(glob)*']

UUID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
RX = [
    ('uuid', re.compile(r'(?<![0-9a-f-])' + UUID + r'(?![0-9a-f-])', re.I)),
    ('timestamp', re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?')),
    ('prefixed-id', re.compile(r'\b(?:msg|toolu|req|srvtoolu|file)_[A-Za-z0-9]{8,}\b')),
    ('hex', re.compile(r'(?<![0-9A-Za-z_-])[0-9a-f]{6,40}(?![0-9A-Za-z_])')),
    ('base62-id', re.compile(r'(?<![0-9A-Za-z_-])[A-Za-z0-9]{16,32}(?![0-9A-Za-z_-])')),
]
KEYNUM = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*(\d{4,})\b')


def tree_files(repo):
    out = subprocess.run(['git', '-C', repo, 'ls-files', '-z', '--'] + SHIP,
                         capture_output=True, check=True).stdout
    return sorted(set(p for p in out.decode().split('\0') if p))


def texts(data):
    yield data.decode('utf-8', 'replace')
    if data.count(b'\0') * 4 > len(data):  # UTF-16 text (e.g. Windows tool output)
        yield data.decode('utf-16-le', 'replace')


def interesting(kind, tok):
    if kind == 'hex':  # all-digit hex only matters as a commit (looked up separately)
        return any(c.isdigit() for c in tok)
    if kind == 'base62-id':  # mixed case AND a digit: an opaque id, not a word or a constant
        return (any(c.isdigit() for c in tok) and any(c.isupper() for c in tok)
                and any(c.islower() for c in tok))
    return True


def collect(repo, files):
    """token -> (kind, [(file, line)]) ; (key, num) -> [(file, line)]"""
    toks, nums = {}, {}
    for f in files:
        p = os.path.join(repo, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        data = open(p, 'rb').read()
        for t in texts(data):
            for ln, line in enumerate(t.splitlines(), 1):
                line = re.sub(r'\\[ntr]', ' ', line)  # JSON/Rust escapes glue a token to a letter
                for kind, rx in RX:
                    for m in rx.finditer(line):
                        tok = m.group(0)
                        if interesting(kind, tok):
                            toks.setdefault(tok, (kind, []))[1].append((f, ln))
                for m in KEYNUM.finditer(line):
                    nums.setdefault((m.group(1), m.group(2)), []).append((f, ln))
    return toks, nums


FREE_TEXT = {'content', 'text', 'stdout', 'stderr', 'output', 'message', 'thinking', 'summary',
             'description', 'command', 'prompt', 'snippet', 'result', 'query', 'body', 'markdown'}


def patterns(toks, nums):
    """Stage 1: fixed strings that can only occur where a token ENDS a JSON string value (the closing
    quote is a real one: inside an escaped string it would read \\"), or starts a uuid value."""
    pat = set()
    for tok, (kind, _) in toks.items():
        if kind == 'hex' and tok.isdigit():  # all-digit hex: only a commit lookup, never a log id
            continue
        pat.add('%s"' % tok)
        if kind == 'hex' and len(tok) == 8:
            pat.add('"%s-' % tok)
    for (k, n) in nums:
        if len(n) >= 6:  # short numbers ("maxLength":1000) collide by chance
            pat.add('"%s":%s' % (k, n))
    return pat


def walk(v, key=None):
    if isinstance(v, dict):
        for k, x in v.items():
            yield from walk(x, k)
    elif isinstance(v, list):
        for x in v:
            yield from walk(x, key)
    else:
        yield key, v


def scan_logs(logs, toks, nums):
    """Stage 2: every log line stage 1 matched is parsed as JSON; a token is REAL when a native value
    (not free text: a tool result, a command, a message) equals it, ends in /TOK, or is a uuid that
    starts with an 8-hex token; a number is real when the same key carries the same value."""
    pat = patterns(toks, nums)
    short = {t for t, (k, _) in toks.items() if k == 'hex' and len(t) == 8}
    numset = {(k, int(n)) for (k, n) in nums if len(n) >= 6}
    found = set()
    with tempfile.NamedTemporaryFile('w', delete=False) as fh:
        fh.write('\n'.join(sorted(pat)) + '\n')
        pfile = fh.name
    try:
        p = subprocess.Popen(['grep', '-r', '-h', '-F', '-a', '--include=*.jsonl', '-f', pfile, logs],
                             stdout=subprocess.PIPE)
        for raw in p.stdout:
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            for key, v in walk(rec):
                if isinstance(v, bool):
                    continue
                if isinstance(v, int):
                    if (key, v) in numset:
                        found.add(('num', key, str(v)))
                    continue
                if not isinstance(v, str) or key in FREE_TEXT:
                    continue
                if v in toks:
                    found.add(v)
                tail = v.rsplit('/', 1)[-1]
                if tail != v and tail in toks:
                    found.add(tail)
                if len(v) == 36 and v[8:9] == '-' and v[:8] in short:
                    found.add(v[:8])
        rc = p.wait()
        if rc not in (0, 1):
            print('real-data: FAIL (grep over %s failed, exit %d)' % (logs, rc))
            sys.exit(2)
        return found
    finally:
        os.unlink(pfile)


def repos(repo, logs):
    """This repo plus every git repo a logged session ran in (native "cwd" values), one per git dir."""
    r = subprocess.run(['grep', '-r', '-h', '-o', '-a', '--include=*.jsonl', '"cwd":"[^"\\\\]*"', logs],
                       capture_output=True)
    cwds = sorted(set(l[7:-1] for l in r.stdout.decode('utf-8', 'replace').splitlines()))
    seen, out = set(), []
    for d in [repo] + cwds:
        if not os.path.isdir(d):
            continue
        g = subprocess.run(['git', '-C', d, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                           capture_output=True)
        key = g.stdout.decode().strip()
        if g.returncode == 0 and key and key not in seen:
            seen.add(key)
            out.append(d)
    return out


def commits(dirs, hexes):
    found = set()
    if not hexes:
        return found
    inp = ''.join(h + '^{commit}\n' for h in hexes).encode()
    for d in dirs:
        r = subprocess.run(['git', '-C', d, 'cat-file', '--batch-check'], input=inp, capture_output=True)
        for h, line in zip(hexes, r.stdout.decode().splitlines()):
            if line.split(' ')[1:2] == ['commit']:
                found.add(h)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    ap.add_argument('--logs', default=os.environ.get('OBSERVATORY_CLAUDE_LOGS',
                                                     os.path.expanduser('~/.claude/projects')))
    ap.add_argument('--show', action='store_true', help='print the tokens too (private use only)')
    a = ap.parse_args()
    cfg = (os.environ.get('OBSERVATORY_CONFIG_DIR')
           or os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'observatory'))
    require = (os.environ.get('OBSERVATORY_STRICT_CHECKS') == '1'
               or os.path.exists(os.path.join(cfg, 'strict-checks')))
    if not os.path.isdir(a.logs):
        if require:
            print('real-data: FAIL (strict: no Claude logs at %s)' % a.logs)
            sys.exit(2)
        print('real-data: SKIPPED (no Claude logs at %s)' % a.logs)
        sys.exit(0)
    files = tree_files(a.repo)
    if not files:
        print('real-data: FAIL (no files listed: not a git checkout?)')
        sys.exit(2)
    toks, nums = collect(a.repo, files)
    hit = scan_logs(a.logs, toks, nums)
    shas = commits(repos(a.repo, a.logs), sorted(t for t, (k, _) in toks.items() if k == 'hex' and len(t) >= 7))
    rows = []
    for i, tok in enumerate(sorted(toks), 1):
        kind, where = toks[tok]
        why = []
        if tok in hit:
            why.append('log value')
        if tok in shas:
            why.append('repo commit')
        if why:
            rows.append((kind, tok, where, '+'.join(why)))
    for (k, n), where in sorted(nums.items()):
        if ('num', k, n) in hit:
            rows.append(('number "%s"' % k, n, where, 'log value'))
    for i, (kind, tok, where, why) in enumerate(rows, 1):
        for f, ln in where:
            print('%s:%d: %s %s #%d%s' % (f, ln, kind, why, i, (' ' + tok) if a.show else ''))
    if rows:
        print('real-data: FAIL (%d real tokens, %d places; %d tokens over %d files checked)'
              % (len(rows), sum(len(r[2]) for r in rows), len(toks) + len(nums), len(files)))
        sys.exit(1)
    print('real-data: PASS (%d tokens over %d files checked against %s)'
          % (len(toks) + len(nums), len(files), a.logs))


if __name__ == '__main__':
    main()
