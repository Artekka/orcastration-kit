#!/usr/bin/env python3
"""Which kit skills a project's sessions actually run, from its Claude Code session logs.
usage: python3 scripts/skill-usage.py <~/.claude/projects/<slug>> [--days N] [--kit <kit root>]
Counts each skill started as a slash command (/orcastration-kit:<name>) or through the Skill tool, per skill in the
kit's skills/ folder, and lists the ones no session ran. Reads the logs one line at a time; main threads and subagents."""
import argparse, collections, datetime, glob, json, os, re
ap = argparse.ArgumentParser()
ap.add_argument('logs'); ap.add_argument('--days', type=int, default=0)
ap.add_argument('--kit', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
a = ap.parse_args()
kit = sorted(d for d in os.listdir(os.path.join(a.kit, 'skills')) if os.path.isfile(os.path.join(a.kit, 'skills', d, 'SKILL.md')))
since = ''
if a.days:
    since = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=a.days)).strftime('%Y-%m-%dT%H:%M:%S')
# The kit's plugin id, and the id it had before 0.17.0: logs written under the earlier id count too.
KIT = r'orc(?:a|he)stration-kit'
CMD = re.compile(r'<command-name>/' + KIT + r':([a-z0-9-]+)</command-name>')
TOOL = re.compile(KIT + r':(.+)')
uses = collections.Counter(); sessions = collections.defaultdict(set); files = 0
for f in glob.glob(os.path.join(os.path.expanduser(a.logs), '**', '*.jsonl'), recursive=True):
    files += 1
    for line in open(f, errors='replace'):
        if 'stration-kit:' not in line or line.startswith('{"type":"api-request'):
            continue
        try: d = json.loads(line)
        except ValueError: continue
        if since and (d.get('timestamp') or '') < since: continue
        m = d.get('message') or {}
        found = []
        if d.get('type') == 'user':
            c = m.get('content')
            t = c if isinstance(c, str) else ' '.join(x.get('text', '') for x in c or [] if isinstance(x, dict))
            found = CMD.findall(t or '')
        elif d.get('type') == 'assistant':
            for x in m.get('content') or []:
                if isinstance(x, dict) and x.get('type') == 'tool_use' and x.get('name') == 'Skill':
                    s = str((x.get('input') or {}).get('skill', ''))
                    t = TOOL.fullmatch(s)
                    if t: found.append(t.group(1))
        for s in found:
            uses[s] += 1; sessions[s].add(d.get('sessionId') or f)
print(f'{files} log files' + (f', last {a.days} days' if a.days else ''))
print(f'{"skill":18} {"uses":>6} {"sessions":>9}')
for s in sorted(kit, key=lambda k: (-uses[k], k)):
    print(f'{s:18} {uses[s]:6} {len(sessions[s]):9}')
never = [s for s in kit if not uses[s]]
print('never run: ' + (', '.join(never) if never else 'none'))
