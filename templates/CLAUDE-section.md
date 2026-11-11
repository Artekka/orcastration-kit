<!-- orchestration-kit v0.8.0 — managed section; upgrades diff against this marker -->
## Multi-session orchestration (orchestration-kit)

This project runs the multi-session claimable-board workflow from the `orchestration-kit`.
Protocol table lives in the board file; project specifics in `docs/orchestration/ORCHESTRATION.md`.

### The non-negotiables

1. **Every session works in its own worktree** — the main thread included. This is instructed
   by default, and enforced by a hook only if the repo opted in (`worktrees: enforced` in
   `docs/orchestration/ORCHESTRATION.md`). Never
   `git add -A` / `.` / `git commit -a` (a wildcard annexes a sibling's live WIP); never
   `git stash` (stash refs are shared across worktrees). A dirty status you didn't cause is
   a sibling at work — leave it alone.
2. **Refresh before claiming:** `git fetch origin && git rebase origin/main` — NOT
   `git pull --rebase` (sessions race on the shared `.git/FETCH_HEAD`). "cannot lock ref" =
   a sibling's fetch won; retry `git fetch origin || { sleep 2; git fetch origin; } && git rebase origin/main`.
   Claim by a committed + PUSHED board edit. OPEN rows and briefs are hypotheses — verify
   against the code.
3. **Board writes in the shared checkout:** `[ "$(git symbolic-ref -q HEAD)" = refs/heads/main ]`,
   then `git diff HEAD --quiet` (the index is shared too), then `git add <board> && git commit`
   as ONE command, then push immediately.
4. **New board rows carry a per-session prefix** (`<tag>-1`, `<tag>-2` …). Never read the
   board's highest id and add one — that read-then-write has no lock and git can't catch it.
5. **The board carries status, not narrative.** Past ~60 KB it is archived verbatim to
   `docs/orchestration/archive/BOARD_ARCHIVE_<date>.md`. Grep archives; never read one whole.
6. **Run the gate from inside your own worktree** and read the literal pass line. Whole-suite
   runs go through `scripts/gate-throttle.sh`; one full gate per tree (touched files mid-row,
   the full gate once at GREEN-FINAL).
7. **Independent verification at every hand-off** — by a SIBLING SESSION that didn't build
   the row (no mutual pairs), contract only, reporting to the seat and stating whether it
   DERIVED its verdict or only consistency-checked. The verifier reports; it never fixes.
8. **Reconcile one row at a time**; push merges immediately; quote on-main SHAs only.
9. **Deploys and log numbers are exclusive slots** — claimed in writing BEFORE running.
10. **Locked items** (ORCHESTRATION.md → Locked) need the human's sign-off.

### Orchestrator-led mode

When the board carries an **`ORCHESTRATOR ACTIVE`** banner: one session (the seat) plans,
assigns, reconciles and deploys; siblings build. Row IDs for planned work, log numbers,
version bumps and the DEPLOY + LOG slots belong to the seat (mid-task discoveries keep your
own prefix). Siblings never deploy and **never ask the human directly — questions and
approvals go to the seat**. A fresh session ends `/orchestration-kit:orient` by sending READY to the seat;
`ListAgents` shows liveness only, never readiness.
Open or refill the team with `bash scripts/start-team.sh` (skips sessions already running).

### Context lifecycle

Never `/compact`. With `ctx_guard: on` a hook measures for you: a `CONTEXT GUARD:` line is an
order (report at the report mark; stop and hand over at the handover mark). Otherwise measure fill with `python3 scripts/ctx-fill.py` (never `bytes ÷ 4`; the
window is the `window` line it prints, never a reading of your model id).
1M window: self-report at ~350K, hand over by ~400K; 200K window: ~120K / ~150K. Report your
fill AND your model with every hand-off. Then the handshake: seat orders `/orchestration-kit:retro` →
you reply "retro complete" → the seat recycles your terminal in place, in the same tab (`scripts/recycle-sibling.sh`)
or the human relaunches it with an explicit `--model` (a bare `/clear` keeps the old model). A row already in flight finishes first.

### Models

The seat picks each session's model by lane when it launches it (`scripts/recycle-sibling.sh <Name>
--model <m>`; table in the orchestrate skill, "Model per lane"). A recycled session never inherits
one. State your model (the id in your env block) and your window (ctx-fill's `window` line) in READY. Builders start
with `/orchestration-kit:orient-brief <ROW>` when the seat gave them a brief file.

> Keep this file slim: it is re-read on every turn of every session. Rules here, narrative in a
> linked archive (`docs/orchestration/CLAUDE-slimness.md`).

### Testing gate (fill per project in ORCHESTRATION.md)

Use the project's layered gate, never its known-flaky full suite. Verify the printed pass
summary yourself — exit codes lie through pipes and background-task notifications. If the
gate prints which tree it gated, read that line. A change that ADDS test output gets one
pass through the real gate stage before hand-off.

### Skill authoring (applies to new skills here)

A skill's SKILL.md loads fully into context on every invocation — author as a terse schema:
frontmatter → H1 → step headers → fenced commands → tables for mappings. One-line "why" per
non-obvious step; war stories go to memory files, linked by slug. Compress rationale, never
commands, flags, guards, or pass/fail assertions.

### Doc routine

After every meaningful chunk: the doc agent appends a log entry AND refreshes the status doc
(version, test count, deferred list) in the SAME pass — coupled so they can't drift. Its
diff must be append-only for the log and fact-checked line-by-line before commit.
<!-- /orchestration-kit -->
