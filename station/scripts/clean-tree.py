#!/usr/bin/env python3
"""Clean-tree check: fails when a denylisted term appears in the shippable tree, in a file's
CONTENTS or its PATH. The denylist is private and lives OUTSIDE the repo:
  $OBSERVATORY_DENYLIST, else <config dir>/denylist.txt
  <config dir> = $OBSERVATORY_CONFIG_DIR, else $XDG_CONFIG_HOME/observatory, else ~/.config/observatory
One term per line; blank lines and lines starting with `#` are ignored.

Matching is on NORMALISED text, so a term cannot hide behind spelling:
  - case is ignored; the joiners `_ - . / \\ : = @` are dropped, and so is a line break with the
    indentation after it: `Some_Name`, `some-name`, `some.name`, `SomeName` and a term split
    across two lines all match the term `some-name`. Spaces and other punctuation stay boundaries
    (`some name` and `some, name` do not match `somename`);
  - a term glued to other text matches (`xSomeNamey`): it is a substring search;
  - JSON / Rust / JS escapes (`\\u0073`, `\\u{73}`, `\\x73`) are decoded first, and a file that
    looks like UTF-16 is also read as UTF-16 (LE and BE);
  - uuids and dash-free hex runs of 16+ characters (hashes) are opaque: a term that happens to
    be spelled by random hex digits is not a leak (`ab12-cd34` and short SHAs are still read);
  - file paths are checked the same way.
Hits print as `file:line: term #N` (N = the term's line in the denylist), so the terms themselves
never reach a log.

Strict mode (a missing denylist FAILS instead of SKIPPING): OBSERVATORY_STRICT_CHECKS=1, or a file
named `strict-checks` in the config dir. A stranger's checkout has neither, so its gate SKIPs.

Usage: python3 scripts/clean-tree.py [<repo dir>]
  exit 0 = clean, or SKIPPED (no denylist, not strict) · 1 = hits · 2 = unusable denylist / tree
"""
import os, re, subprocess, sys

SHIP = ['crates', 'scripts', 'Cargo.toml', 'Cargo.lock', 'docs/BRIEF.md', 'README.md', '.claude', ':(glob)*']
ESC = re.compile(r'\\u\{([0-9a-fA-F]{1,6})\}|\\u([0-9a-fA-F]{4})|\\x([0-9a-fA-F]{2})')


def config_dir():
    if os.environ.get('OBSERVATORY_CONFIG_DIR'):
        return os.environ['OBSERVATORY_CONFIG_DIR']
    if os.environ.get('XDG_CONFIG_HOME'):
        return os.path.join(os.environ['XDG_CONFIG_HOME'], 'observatory')
    return os.path.expanduser('~/.config/observatory')


def strict(cfg):
    return os.environ.get('OBSERVATORY_STRICT_CHECKS') == '1' or os.path.exists(os.path.join(cfg, 'strict-checks'))


JOIN = set('_-./\\:=@')
HEX = re.compile(r'(?<![0-9A-Za-z-])(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
                 r'|[0-9a-fA-F]{16,})(?![0-9A-Za-z-])')


def norm(s):
    return squash(s)[0]


def unescape(s):
    def one(m):
        try:
            return chr(int(m.group(1) or m.group(2) or m.group(3), 16))
        except ValueError:
            return m.group(0)
    return ESC.sub(one, s)


def texts(data):
    yield data.decode('utf-8', 'replace')
    if data.count(b'\0') * 8 > len(data):  # many NULs: UTF-16 (either order)
        yield data.decode('utf-16-le', 'replace')
        yield data.decode('utf-16-be', 'replace')


def squash(text):
    """The normalised stream of `text` and, per kept char, the 1-based line it came from."""
    text = HEX.sub(' ', unescape(text))
    out, lines, ln, join = [], [], 1, False
    for c in text:
        if c == '\n':
            ln += 1
            join = True  # the line break and the indentation after it vanish
            continue
        if join and c in ' \t\r':
            continue
        join = False
        lc = c.lower()
        if lc.isalnum():
            out.append(lc)
            lines.append(ln)
        elif c in JOIN:
            continue
        elif out and out[-1] != ' ':
            out.append(' ')
            lines.append(ln)
    return ''.join(out), lines


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    cfg = config_dir()
    path = os.environ.get('OBSERVATORY_DENYLIST') or os.path.join(cfg, 'denylist.txt')
    if not os.path.exists(path):
        if strict(cfg):
            print('clean-tree: FAIL (strict: no denylist at %s)' % path)
            sys.exit(2)
        print('clean-tree: SKIPPED (no denylist at %s)' % path)
        sys.exit(0)
    terms = []
    for n, raw in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
        t = raw.strip()
        if t and not t.startswith('#'):
            t = norm(t).strip()
            if not t:
                print('clean-tree: FAIL (denylist line %d has no letters or digits)' % n)
                sys.exit(2)
            terms.append((n, t))
    if not terms:
        print('clean-tree: FAIL (denylist %s has no terms: it could never fail)' % path)
        sys.exit(2)
    r = subprocess.run(['git', '-C', repo, 'ls-files', '-z', '--'] + SHIP, capture_output=True)
    files = sorted(set(p for p in r.stdout.decode().split('\0') if p))
    if r.returncode or not files:
        print('clean-tree: FAIL (no files listed: not a git checkout?)')
        sys.exit(2)
    hits = 0
    for f in files:
        found = set()
        pn = norm(f)
        for n, t in terms:
            if t in pn:
                found.add(('(path)', n))
        p = os.path.join(repo, f)
        if os.path.isfile(p) and not os.path.islink(p):
            data = open(p, 'rb').read()
            for text in texts(data):
                s, lines = squash(text)
                for n, t in terms:
                    i = s.find(t)
                    while i >= 0:
                        found.add((lines[i], n))
                        i = s.find(t, i + 1)
        for where, n in sorted(found, key=lambda x: (str(x[0]), x[1])):
            print('%s:%s: term #%d' % (f, where, n))
            hits += 1
    if hits:
        print('clean-tree: FAIL (%d hits; %d terms over %d files)' % (hits, len(terms), len(files)))
        sys.exit(1)
    print('clean-tree: PASS (%d terms over %d files)' % (len(terms), len(files)))


if __name__ == '__main__':
    main()
