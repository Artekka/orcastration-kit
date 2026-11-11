---
name: orient-brief
description: Lean start for a builder or verifier the seat assigned a row. Use as `/orchestration-kit:orient-brief <ROW>`. The row's brief (docs/orchestration/briefs/<ROW>.md, from origin) and the board's live banner arrive already injected into this text; then ListAgents + ctx-fill and the READY signal. Replaces `/orchestration-kit:orient --brief <ROW>`, which still works as a fallback.
argument-hint: <ROW>
allowed-tools: Bash(bash *orient-brief/brief.sh*)
---

# Orient (lean): row $0

Everything below the line was produced by `brief.sh` before you saw this text (fetch, the brief from origin else this checkout, the board banner). Nothing to fetch or `cat`.

!`bash "${CLAUDE_SKILL_DIR}/brief.sh" '$0'`

## Do now

1. A `NO BRIEF` line = tell the seat and run the full `/orchestration-kit:orient`. A `NO BANNER` line = no seat: ask the human.
2. Load the cross-session tools first (they are deferred): `ToolSearch` with `select:ListAgents,SendMessage`.
3. In ONE turn, in parallel: `ListAgents` (its first line = your name + ref) and `python3 scripts/ctx-fill.py ${CLAUDE_SESSION_ID}` as its own command (it finds your window; never read one from the model id). Paste the `current` line verbatim.
4. The multi-session rules still bind (CLAUDE.md loads with the session): your own worktree, `git fetch origin || { sleep 2; git fetch origin; } && git rebase origin/main` before claiming, row ids under your own prefix. Restate them in one line in READY.
5. Send READY (`SendMessage` to the seat the banner names) as your LAST act, then follow the brief. Skip the status doc, the log, `git log`, the test check and the five-bullet summary.

```
READY <PREFIX> [<ref>] · model <id> · fill `current   NNN,NNN` · marks <prompt>/<handover> · saw <seat Name [ref]> era-<N> · <one line: what you can take> · seen: <rows whose builder narrative you already read — or "none">
```

| Field | Rule |
|---|---|
| `[<ref>]` | The first line of `ListAgents` ("This session is Sib1 [57f3ab]"), never the session uuid |
| `fill` / `marks` | The ctx-fill `current` and `marks` lines verbatim (1M → 350K/400K, 200K → 120K/150K) |
| `model` | The exact id in your env block (it names no window) |
| `saw` | The seat and era the banner names; none → "no banner seen" |
| `seen:` | Your independence disclosure, stated unasked: it decides which rows you may later verify |
| SendMessage fails | Name + ref repeated in an error → resend with the ref. Still failing → an `AVAILABLE <prefix>` line under the banner on the board |

Full detail: Step 7 of `/orchestration-kit:orient`.
