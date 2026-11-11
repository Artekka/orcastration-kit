# Agent Orchestration Board — shared across Claude Code instances

> **What this is:** the live coordination surface for ALL Claude sessions working on this
> repo at the same time. Read it AFTER the project's orientation docs, BEFORE claiming any
> work. Every edit is committed AND pushed at once (`/orchestration-kit:board` → shared-checkout recipe).
>
> **This board carries STATUS, not narrative.** Briefs go to builders by message; write-ups,
> verdict transcripts and post-mortems go to the log, and the board links to them. Past
> ~60 KB it is archived verbatim (table below) and rewritten to status only.
>
> Project-specific values (gate, deploy, change classes, validator, locked areas) live in
> `ORCHESTRATION.md` next to this file — the protocol below is generic.

## Archives — authoritative history. GREP, never read one whole.

| Archive | Covers |
|---|---|
| — none yet — | — |

```bash
grep -n '<ROW-ID>' docs/orchestration/archive/BOARD_ARCHIVE_*.md | cut -c1-200
```

## Protocol (mandatory)

| Rule | Why |
|---|---|
| **Refresh, then claim by a PUSHED board edit** — `git fetch origin && git rebase origin/main` (never `git pull --rebase`). | Sessions share `.git/FETCH_HEAD`; an unpushed claim is invisible. |
| **Every session works in its own git worktree** — the main thread too. | Shared-tree edits get swept into a sibling's commit. |
| **Never `git add -A` / `.` / `commit -a`; never `git stash`.** | Wildcards annex siblings' WIP; stash refs are shared across worktrees. |
| **Board writes: HEAD guard → `git diff HEAD --quiet` → `git add <board> && git commit` as ONE command → push.** | The shared index lets a sibling's staged hunk ride your commit. |
| **New rows use YOUR session prefix** (`<tag>-1`, `<tag>-2`) — never highest-id + 1. | A read-then-write counter with no lock collides silently. |
| **One owner per row. The fence column is a hard no-edit zone for everyone else.** | Reconcile conflicts are the #1 cross-session failure. |
| **Independent verification at every hand-off** — by a sibling that did not build the row (no mutual pairs), reporting to the seat. | An impl+test pair can confabulate the same wrong belief. |
| **Reconcile ONE row at a time; push merges immediately.** | Parallel landings lose work; an unpushed merge gets linearized. |
| **Run the gate from inside your own worktree; read the literal pass line.** | A gate run from the wrong tree prints a legitimate green for a tree you are not in. |
| **DEPLOY and LOG are exclusive slots** — claim in writing before running. | Racing a deploy corrupts the cutover; racing a counter duplicates it. |
| **Locked items need the human's sign-off.** | Silent contract drift is worse than a missing feature. |

**Session tag:** `<Name> [<ref>]` — the `--name` the terminal was launched with plus the ref `ListAgents` prints for it (e.g. `Sib1 [57f3ab]`). **Row prefix:** derived from the tag (`S1-`, `S2-`; the seat's e.g. `ORC3-` per era).

## Statuses

`OPEN` → `CLAIMED` → `BUILDING` (worktree) → `READ` (sibling verification) → `RECONCILE` → `ON MAIN <sha>` → `DEPLOYED <version>`.
`BLOCKED(<on what>)` allowed anywhere. Verdicts: `PASS` / `DEVIATES` / `BROKEN` + `DERIVED` or `CONSISTENCY-CHECKED`.

---

## Seat banner — SHAPE ONLY, no seat is active

The first seat pastes this at the TOP of the file (above the archive table), fills it in, and
deletes this section (the shape stays in the plugin's `templates/AGENT_BOARD.md`). While this
section is here, no orchestrator is active.

````markdown
## 🎛 ORCHESTRATOR ACTIVE — era-<N> · <SeatName> `[<ref>]` · seated <HH:MM TZ YYYY-MM-DD> · prefix `<P>-` · <model>, <window> window (from ctx-fill) · fill <NNN,NNN> measured
**Siblings: report to `<SeatName> [<ref>]`.** ⛔ All human approvals/questions route through the SEAT · Validator = `<Name>` (never builds) · siblings don't spawn agents unless the human asks.
**Slots:** DEPLOY FREE · LOG FREE (next <N>) · resource windows: none open

**Roster (from READY signals only — never from ListAgents):**

| Session | Prefix | Fill @ READY | Lane | seen: |
|---|---|---|---|---|
| Sib1 `[<ref>]` | S1- | <NNN,NNN> | builder | none |
| Validator `[<ref>]` | V- | <NNN,NNN> | READ only | none |

READY signal (sent by SendMessage; board fallback: an "AVAILABLE <prefix>" line under the banner):
READY <PREFIX> [<ref>] · model <id> · fill <current> · marks <prompt>/<handover> · saw <seat Name [ref]> era-<N> · <what you can take> · seen: <rows already read | none>

⏭ **HANDOVER (era-<N> → <N+1>), <HH:MM TZ>** (seat fill <NNN,NNN> measured; nothing of the seat's in flight):
✅ LIVE <version> (main `<sha>`) · DEPLOY FREE · LOG FREE, next <N>
**SEAT OWES, in order:** (1) READs owed: <row> `<sha>` → <eligible verifier> · (2) train contents: <rows> · (3) in-flight builds: <row> <Name> · (4) human's queue: <questions awaiting rulings>
````

---

## Live board — last updated: <session tag>

### In flight (do NOT touch their fences)

| Row | Task | Status | Owner | Fence (files this row owns) | Verdict / gate line |
|---|---|---|---|---|---|
| S1-1 | <task> | BUILDING | Sib1 `[<ref>]` | <exact files / dirs> | — |

### Open (unclaimed)

| Row | Task | Notes |
|---|---|---|
| ORC1-1 | <task> | <pointer to brief/log, suspected cause> |

### Recently landed

- `<on-main sha>` <row> — READ PASS (DERIVED, <verifier>) · `<literal gate pass line>`
