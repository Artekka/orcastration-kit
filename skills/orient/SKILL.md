---
name: orient
description: Bring a fresh session up to speed on a kit-adopted project — restate the multi-session non-negotiables, read the ground rules, the orchestration overlay, the live board, and recent git history, then summarize state in five bullets and report availability to any active orchestrator. With `--brief <ROW>` it runs a lean mode for a builder who was assigned a row: read the row's brief and the board banner only, then send READY. Use at session start ("orient me", "where are we", "catch me up") or when invoked on a project without context. If the project ships its own richer /orient, prefer that one.
---

# orient

Load a fresh session's working memory without the human re-explaining. End state: five bullets + a productive next question (or a report to the orchestrator).

## Lean mode: `/orchestration-kit:orient --brief <ROW>` (fallback)

Prefer `/orchestration-kit:orient-brief <ROW>`: it runs steps 1–2 below before the session reads anything (the brief and banner arrive injected). This table is the same start by hand, for a host that cannot run skill-injected commands.

For a builder the seat assigned a row that has a brief file (`docs/orchestration/briefs/<ROW>.md`, made from `templates/briefs/_TEMPLATE.md`). A full orient costs ~100K tokens of a fresh context; the brief already holds what this row needs. The full mode below stays for the seat, for a lone session, and for any start without a brief.

| step | do |
|---|---|
| 1 | `git fetch origin \|\| { sleep 2; git fetch origin; }`, then `git show origin/main:docs/orchestration/briefs/<ROW>.md` — the row's whole contract, as the seat pushed it (substitute your default branch for `main`; a plain `cat` of your own checkout misses a brief it has not rebased onto yet). Not on origin/main → `cat docs/orchestration/briefs/<ROW>.md`; in neither → tell the seat, then fall back to the full mode |
| 2 | `git show origin/main:docs/orchestration/AGENT_BOARD.md \| awk '/^## /{ if (on) exit; if (/ORCHESTRATOR ACTIVE/ && !/[Ss][Uu][Pp][Ee][Rr][Ss][Ee][Dd][Ee][Dd]/) on=1 } on' \| head -60` — the CURRENT banner's own section, from its `ORCHESTRATOR ACTIVE` heading to the next `## ` (who the seat is, the era's rows, the standing rules it names; a header that says `superseded` is never taken for the live banner, so a board holding only superseded banners prints nothing). Anchored on the banner, not on line counts: the archive table and `---` rulers above it are skipped. No output = no banner = no seat: ask the human |
| 3 | `python3 scripts/ctx-fill.py <uuid>` as its own command — its `window` line is your window (Claude Code's own figure, else the team block's); never read one from the model id |
| 4 | `ToolSearch` with `select:ListAgents,SendMessage` first (they are deferred tools: calling one unloaded fails), then `ListAgents` (first line = your name + ref), then the READY signal of Step 7 |

Skip: the status doc, the log, `git log`, the overlay (unless the brief names no gate command — then read `ORCHESTRATION.md` → Gate only), the test-health check and the five-bullet summary. `CLAUDE.md` loads with the session, so the Step 0 rules (worktree, refresh before claiming, row prefix) still apply: follow them and restate them in one line in READY.

## Step 0 — The multi-session non-negotiables (restate in your summary)

1. **ALL edits happen in your own worktree** — the main thread's included (instructed by default; enforced by a hook only if ORCHESTRATION.md says `worktrees: enforced`). Board/docs edits in the shared checkout are committed within seconds via the board-write recipe (`/orchestration-kit:board`). Never `git add -A` / `.` / `git commit -a`; never `git stash` (stash refs are shared across worktrees) — a hook refuses these if ORCHESTRATION.md says `git_guard: on`. A dirty status you didn't cause is a sibling at work — leave it.
2. **Refresh before claiming** — `git fetch origin && git rebase origin/main` (NOT `git pull --rebase`: shared FETCH_HEAD race). `cannot lock ref` = a sibling's fetch won; retry: `git fetch origin || { sleep 2; git fetch origin; } && git rebase origin/main`. A claim is only real once pushed. OPEN rows and briefs are hypotheses — verify against the CODE.
3. **New rows carry YOUR session prefix** (`<tag>-1`, `<tag>-2` …) — never the board's highest id + 1 (LESSON 16). State your prefix in the summary.
4. **Run the gate from INSIDE your own worktree** and check its printed counts against your delta — a script that `cd`s to its own directory gates whichever tree it lives in.
5. **The board is status, not narrative.** Archives (`docs/orchestration/archive/BOARD_ARCHIVE_*.md`) are grepped, never read whole: `grep -n '<ROW-ID>' docs/orchestration/archive/*.md | cut -c1-200`.
6. **Questions and approvals go to the seat** when a banner stands — never to the human in your terminal.

## Steps 1–6 — The reads, in order

1. The status doc (ORCHESTRATION.md → Docs; default `docs/AI_CONTEXT.md`) — note how stale its "Last refresh" is.
   **Missing, or still has `<…>` placeholders? → bootstrap mode:** orient from an outline the human provides and/or the project itself — `README*`, `CLAUDE.md`, the package manifest(s), `ls docs/`, a 2-level directory listing, `git log --oneline -30`. Then:
   | You are | Do |
   |---|---|
   | The seat, or a lone session (no banner) | **First ask, once — ONE `AskUserQuestion`:** "No orientation doc found. How should I learn this project?" → **Search the project (Recommended)** · **I'll give you an outline** (a file path, or paste it in your reply) · **Both — my outline first, then check it against the project**. With an outline: read it, treat it as the human's word on purpose/priorities, and verify its factual claims (paths, commands, versions) against the repo — the repo wins on facts, flag any mismatch. The doc you then write is the record, so this question never repeats. Then write/fill the status doc (mark guesses `(unverified)`), commit it via the board-write recipe, say so in your summary |
   | A sibling under a banner | Do NOT write it (concurrent writers) — orient from the sources, and put "status doc missing/template" in your READY so the seat fills it |
2. `CLAUDE.md` top to bottom — the ground rules. (Claude Code's auto-memory index loads by itself.)
3. `docs/orchestration/ORCHESTRATION.md` — gate, change classes, deploy, validator, locked items, hazards.
4. The last two entries of the log (default `docs/timeline/build-log.md`: `tail -120`) — what shipped, what's in flight. Log older than the latest commits ⇒ unlogged work; note it.
5. The board — every open row's fence is a no-edit zone for you.
6. `git log --oneline -20` + `git status`. Don't run the full test suite — trust the status doc's counts unless the docs look stale, then run a fast targeted subset only.

## Summarize in five bullets

1. Current version + latest shipped chunk. 2. What works today. 3. Top deferred items. 4. Suite health (from the status doc, not a fresh run). 5. In-flight work / stale docs. Then your row prefix + one line confirming the Step-0 rules.

## Step 7 — Roster handshake (banner-aware)

`ListAgents` reports terminal **liveness** only — uptime survives `/clear`, so a fresh context and a spent one look identical. Rosters are built from **READY signals**, never from a listing.

| You are | Do |
|---|---|
| Sibling · `ORCHESTRATOR ACTIVE` banner | Send READY to the named seat as your LAST orientation act. Don't ask the human for work. The human still outranks the seat if they type in YOUR terminal |
| Sibling · no banner | Ask the human what to work on |
| The seat | Re-run `ListAgents` at the end of orientation, then WAIT for READY signals — never infer readiness from the listing |

**READY signal** (load the tools with `ToolSearch` with `select:ListAgents,SendMessage` first (they are deferred tools: calling one unloaded fails); `SendMessage` to the seat; board note `AVAILABLE <prefix>` under the banner only if SendMessage fails):
```
READY <PREFIX> [<ref>] · model <id> · fill <current from ctx-fill, verbatim> · marks <prompt>/<handover> · saw <seat Name [ref]> era-<N> · <what you can take> · seen: <rows whose builder narrative you've already read, or "none">
```
- `<ref>` = your own identity line from `ListAgents` (e.g. "This session is Sib1 [57f3ab]") — not your session uuid.
- `model <id>` = the exact model id in YOUR env block. The seat chose your model by lane at launch; stating it lets the seat check the lane got the model it asked for. The id names no window: a 1M launch can show it without `[1m]`.
- Fill = `python3 scripts/ctx-fill.py <uuid>` run as its own command, output pasted verbatim. `marks` = the `marks` line it printed for the window it found (1M → 350K/400K, 200K → 120K/150K).
- If ctx-fill says the window is UNKNOWN, say so in READY and use the 1M marks until the seat answers; never lower your window from the model id, and never ask for a recycle on that reading. The seat settles it from the launch (`--model`) and the team block's `context_window`.
- `saw <seat Name [ref]> era-<N>` = the seat and era named by the banner you read (lean step 2). A builder that cannot name them did not see the banner: re-run step 2, or say "no banner seen".
- `seen:` is your independence disclosure — it decides which rows you may later verify.
- If the banner's era/seat looks stale against the board body, say so in READY.

Don't start work until direction arrives (human or seat).
