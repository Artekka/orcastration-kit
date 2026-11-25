# Settings snippets — offered by bootstrap-project, APPROVAL-GATED

These edit the project's `.claude/settings.json` — user configuration. The bootstrap OFFERS
them; it never applies them without a yes.

## SessionStart hook — nothing to add

Since v0.4.0 the plugin ships its own SessionStart hook (`hooks/hooks.json`): on a fresh
session (startup or /clear) in a repo that has `docs/orchestration/AGENT_BOARD.md`, it tells
the session to run `/orcastration-kit:orient` and, if an `ORCHESTRATOR ACTIVE` banner names
another session, to send that seat a READY signal instead of asking the user for work. In any
other repo it is a silent no-op. If you copied the v0.3.0 hook snippet into
`.claude/settings.json`, remove it — otherwise sessions get the nudge twice.

## Context-fill statusline (optional)

Shows the session's real context fill against the kit's marks in Claude Code's status bar —
`ctx 212K · prompt 350K · handover 400K`, yellow at the prompt mark (self-report), red past
handover (retro, then recycle). Same measure as `scripts/ctx-fill.py`. `kit-init` copies
`scripts/statusline-ctx.sh`; enable it in `.claude/settings.json` (or `~/.claude/settings.json`
for every repo, after copying the script somewhere stable):

```json
"statusLine": { "type": "command", "command": "bash scripts/statusline-ctx.sh" }
```

On a 200K-window model set `CTX_WINDOW=200000` in the session's environment (marks become
120K / 150K) unless Claude Code already passes the window size to the statusline. Already
have a statusline? Have your script call this one with the same stdin and join the outputs.

## Auto-compact off — the no-/compact house flow

The CLAUDE-section carries the rule (never /compact; context pressure → retro, then recycle).
This setting makes the automatic side match:

```json
"autoCompact": false
```

> Verify the key name against the current Claude Code version before applying (`/config`
> lists it as "Auto-compact"); if it has moved, apply the equivalent toggle rather than a
> dead key.
