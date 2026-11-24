# Glossary

The kit's vocabulary, in one place. Skills and lessons use these words without re-defining them.

| Term | Meaning |
|---|---|
| **Board** | `docs/orchestration/AGENT_BOARD.md` — the shared, committed file where sessions claim and track work. Status only, no narrative |
| **Row** | One unit of work on the board: id · title · status · owner · fence · SHA · verdict |
| **Row prefix** | Each session numbers its own rows (`Dev1-1`, `Dev1-2` …) so two sessions can never mint the same id |
| **Claim** | Marking a row as yours on the board, then committing + pushing. An unpushed claim is not a claim |
| **Fence** | The exact files/dirs a row may edit. Fences of rows in flight at the same time must not overlap |
| **Shared checkout** | The repo's main working directory. Every session's HEAD and index live there, so only quick board/doc commits happen in it |
| **Worktree** | A separate git working directory (`git worktree add`) — each session builds in its own |
| **Gate** | The project's trusted test command (set in `ORCHESTRATION.md`) |
| **Pass-proof line** | The literal summary line that proves the gate passed (e.g. `Tests: 42 passed, 0 failed`). Exit code alone is not proof |
| **Overlay** | `docs/orchestration/ORCHESTRATION.md` — the project-specific settings every skill reads first (gate, deploy, team, docs) |
| **Team** | One seat that coordinates, plus two or more siblings that build, each in its own window. This is how the kit runs |
| **Seat** | The orchestrator session (default name `Orca`). Talks to you; plans, assigns, verifies-by-proxy, merges, deploys. Never writes feature code |
| **Sibling** | A builder session (default names `Sib1`, `Sib2` …). Talks to the seat, not to you |
| **Banner** | `ORCHESTRATOR ACTIVE` block at the top of the board naming the current seat. No banner = no seat |
| **Era** | One seat's tenure. When a seat is recycled, the next one starts era N+1 (in the banner) |
| **Handover** | The note a retiring seat leaves under the banner: slots held, rows in flight, what's owed |
| **READY** | The message a freshly oriented sibling sends the seat: fill, what it can take, which rows it has `seen:` |
| **READ** | A verification pass by a session that did not build the row |
| **Verifier** | Whoever does a READ — a sibling session (preferred) or the `verifier` subagent (fallback) |
| **Contract only** | The verifier gets the row/spec + diff + gate, never the builder's reasoning |
| **PASS / DEVIATES / BROKEN** | Verdicts: matches spec and works / works but drifts from spec / doesn't work |
| **DERIVED / CONSISTENCY-CHECKED** | Whether a verdict re-derived the answer from ground truth, or only checked it agreed with the board. Only DERIVED is verification |
| **Roundtrip** | DEVIATES/BROKEN findings go back to the same builder, then a scoped delta re-verify |
| **Validator** | An optional sibling that only verifies and never builds — independent of every row |
| **Reconcile** | Landing one verified branch onto main and re-running the gate there. One at a time |
| **Wave train** | Deploying 1–3 reconciled rows together; hotfixes go immediately |
| **DEPLOY slot / LOG slot** | Board claims that make deploys and log-entry numbering exclusive |
| **Fill** | A session's measured context size (`scripts/ctx-fill.py`, or the statusline) |
| **Prompt mark / handover mark** | Fill at which a session self-reports (~350K on a 1M window) / must hand over (~400K). 200K window: 120K / 150K (60% / 75%) |
| **Lane / model per lane** | The kind of work a row is (heavy reasoning, routine, mechanical). The seat launches each session on the model its lane needs (`--model`); a recycle never inherits one |
| **Brief** | The row's contract as a file (`docs/orchestration/briefs/<ROW>.md`): goal, acceptance, fence, seam map, gate, model. Builders start with `/orchestration-kit:orient-brief <ROW>`: the brief and banner arrive pre-injected |
| **Retro** | `/orchestration-kit:retro` — save lessons, update board, commit, reply "retro complete" |
| **Recycle** | Replace a full session with a fresh one: launch the new window first, then close the old |
| **Status doc / log** | `docs/AI_CONTEXT.md` (read first by every session) / `docs/timeline/build-log.md` (append-only history) |
| **Goldens** | Snapshot/fixture tests whose output must stay byte-identical |
| **Mutant / survivor** | A deliberate defect applied to prove a test can fail (`/orchestration-kit:falsify`) / a mutant no test caught |
