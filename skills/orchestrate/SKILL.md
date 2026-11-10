---
name: orchestrate
description: Run the orchestrated-autonomy loop as the ACTIVE ORCHESTRATOR ("the seat") coordinating sibling Claude sessions on a kit-adopted project — take the seat via the board banner, intake tasks into briefed fenced rows, decompose into a dependency DAG, assign siblings (SendMessage + board), track phase-boundary reports, gate every hand-off with a SIBLING-SESSION verifier, reconcile one row at a time, deploy in wave trains, allocate log numbers via the LOG slot, route all human approvals, and recycle siblings (and itself) when context fills. Use when the human says "orchestrate", "take the seat", "run the board", or hands over a batch of tasks while sibling sessions are active.
---

# orchestrate

One session (the **seat**) plans, assigns, verifies-by-proxy, lands and ships; 2+ **siblings** build in their own worktrees. Exists because distributed writers minting shared IDs / mutating shared state with no lock collide silently (LESSONS 16–17, 28–60). Project specifics (gate, deploy, validator, board path) come from `docs/orchestration/ORCHESTRATION.md`.

## 0 · Take the seat

```bash
git fetch origin && git rebase origin/main          # NOT `git pull --rebase` — shared FETCH_HEAD race (LESSON 29)
# exit 1 "cannot lock ref 'refs/remotes/origin/main'" = a sibling's fetch won the lock; nothing rebased. Retry once:
git fetch origin || { sleep 2; git fetch origin; } && git rebase origin/main
```

0. Fresh seat → do the `/orchestration-kit:orient` reads first (Steps 0–6; skip its READY step — you are the one receiving READYs).
1. Read the board top to bottom (archives: grep only, never whole). Another `ORCHESTRATOR ACTIVE` banner with a live seat → do NOT take it; ask the human.
2. Post the banner at the TOP of the board (shape: the board's "Seat banner — SHAPE ONLY" section, or `${CLAUDE_PLUGIN_ROOT}/templates/AGENT_BOARD.md`): seat name + `[ref]`, era/date, your row prefix, model + window **from your own env block**, measured fill, standing rules. **Commit + push immediately** (board-write recipe, §6) — an unpushed banner is invisible.
3. Measure yourself: `python3 scripts/ctx-fill.py` → paste `current` into the banner.
4. Load the cross-session tools: `ToolSearch` with `select:ListAgents,SendMessage` first (they are deferred tools: calling one unloaded fails). `ListAgents` shows who is **reachable**, never who is **ready** — terminal uptime survives `/clear`. Build the roster from READY signals only (§3). Re-run `ListAgents` right before publishing any roster/dispatch plan.
5. **Siblings not running?** Offer the human `bash scripts/start-team.sh` (opens any missing seat/sibling window; skips names already running; `--dry-run` to preview) and run it on a yes.

## 1 · Single-allocator (while the banner stands)

| Shared resource | Minted/held by |
|---|---|
| Planned-work row IDs (`<seatprefix>-n`) | Seat only |
| Log / milestone number | Seat, inside a LOG-slot claim |
| Version bump / release-note version | Seat, at deploy time |
| DEPLOY slot · LOG slot | Seat only |
| Sibling mid-task discoveries | Sibling's OWN prefix (`<sibprefix>-n`) — never a shared counter |

## 2 · Intake → briefed rows

Every ask (human plain language, external tracker, issue queue) becomes a row under your prefix. The board line carries **status only**; the **brief goes to the builder by message** (a narrative board briefs its own verifiers).

**Row brief = a file**, `docs/orchestration/briefs/<ROW>.md`, from `${CLAUDE_PLUGIN_ROOT}/templates/briefs/_TEMPLATE.md` (goal · numbered acceptance · fence · seam map from your own Explore pass · base branch · gate · **model/effort** · report protocol). **Commit + push it BEFORE the assign message**, which then only names the file. The builder starts with `/orchestration-kit:orient-brief <ROW>` (the brief + banner arrive injected; no project orient); the verifier reads the brief + the diff. Keep it contract-only — a brief that narrates your reasoning briefs your own verifiers.
Every brief is a hypothesis — a builder correcting it upward is expected, not insubordination.

| Brief rule | Why |
|---|---|
| **Never illustrate a "find every X" requirement.** Name the enumeration itself as the deliverable ("send me the table, then fix"); the verifier rebuilds it independently | An illustration inside a requirement is read AS the requirement — two rows guarded exactly the 3 named sites of populations of 8 and 13 (LESSON 42) |
| **"X is broken" rows report the POPULATION COUNT before building.** Say "zero" out loud on the row | Zero is a finding; two rows died that way in one session (LESSON 58) |

## 3 · DAG + assignment

1. Decompose into a DAG: nodes = fenced rows, edges = verify-gated hand-offs. **Concurrent nodes' fences must be disjoint** — check BEFORE assigning, including each row's acceptance-criteria surface (tests, fixtures, docs it must touch).
2. Wait for **READY** from each sibling (format in `/orchestration-kit:orient` Step 7): `READY <PREFIX> [<ref>] · model <id> · fill <current> · marks <p>/<h> · saw <seat Name [ref]> era-<N> · <can take> · seen: <rows already read>`. The `seen:` list decides who may later VERIFY what.
3. **Assignment = SendMessage + the same assignment on the board row** (an undelivered message is silent; the board always works).
4. First reply confirms receipt. No reply in ~10 min → check the board; still nothing → banner note, reassign when someone frees up.

## 3a · Model per lane

The seat chooses a session's model at launch; a recycled session **never inherits one** (the launch scripts always pass `--model`). Pick by the kind of work. The names are aliases that track the newest model of each tier; `1m` = the 1M-token window, and a 200K-window tier has its own context marks (§10).

| Lane (by work type) | Model |
|---|---|
| Heavy reasoning and verification: core logic and math, data migrations, security, money/billing, anything whose bug is silent; **every READ of those**; the seat; the validator | top tier, 1M — `opus[1m]` |
| Routine work: UI, wire/schema plumbing, ordinary features, test-only fixes | mid tier, 1M — `sonnet[1m]` |
| Board and log entries, write-ups, anything that states SHAs, counts or verdicts | mid tier, 1M — `sonnet[1m]` (facts need a model that does not fabricate) |
| Copy changes, mechanical sweeps, searches that only locate code | small tier, 200K window — `haiku` (never writes facts, see below) |

- Launch: `bash scripts/recycle-sibling.sh <Name> [prompt] --model <m> [--effort <e>]`; `start-team.sh --model <m>` gives the whole team one model. The default when you pass nothing is the team block's `model:` in `ORCHESTRATION.md`, else `opus[1m]`.
- **The small model never writes facts** — log entries, board entries, verdicts, measured numbers, SHAs. Small models invent them. Give it text to move, not claims to make.
- Put the model on the row's brief so the builder, the verifier and the next seat can see what the lane was given.

**Subagents vs sessions (hybrid policy):**

| Use | When |
|---|---|
| **Subagent** (model pinned by its agent type) | A bounded job with a clear output: a seam-map search, a mechanical sweep, a test-only fix, a measurement script, a single-file change. Starts at ~10–25K tokens against a session's orient cost |
| **Session** | A long builder row with fix rounds; **every verification** (a peer has its own context, a subagent inherits the dispatcher's framing); user-facing work; anything that needs the human |

- A subagent **dies with its parent**: the seat dispatches only SHORT ones (a long row would be lost on recycle). A builder may dispatch its own.
- Subagents share the same gate/toolchain: they do not add gate parallelism.
- The `verifier` subagent (`/orchestration-kit:verify-feature`) stays the fallback when no independent sibling is free (§5).

## 4 · Track

- Siblings report at phase boundaries: claimed → RED → GREEN + self-gate (literal pass line) → blocked/done.
- Silent >30 min mid-build → `git log origin/main` + board + message. Truly stalled → banner the stall, reassign (never two silent owners on one row).
- A correction that changes a builder's next hour goes in a **top-of-board banner**, not only a message.
- **A knob beats etiquette** (LESSON 54). Before telling siblings "don't run X", check whether the toolchain runs X for them; if so the rule is unachievable — ship an env knob and announce it. "I didn't run X" ≠ "X didn't run".
- **Keep a builder's hedges when you summarize** (LESSON 52). "A small piece of evidence" stays exactly that on the board.

## 5 · Hand-off verify gate — a SIBLING SESSION verifies

Every hand-off edge (downstream consumes upstream output) and every high-risk class in ORCHESTRATION.md gets an independent READ before reconcile.

| Rule | Why |
|---|---|
| The verifier is **another sibling session**, not a subagent you spawn | A peer has its own context window; your subagent inherits the seat's framing — and you've read the builder's reports all wave |
| **Nobody verifies their own row** | Self-review judges against the model already built |
| **No mutual pairs** (A reads B ⇒ B doesn't read A) | Reciprocity is a bias |
| Verifier gets the **contract only**: row goal + acceptance + fence + diff/branch + gate command | Withholding the builder's reasoning is the SEAT's discipline |
| Verifier **reports to the seat**, never messages the builder, never fixes | Negotiating with the author ≠ independent; fixing masks drift |
| Pick a verifier whose `seen:` doesn't include the builder's narrative for that row | Independence is per-row, not per-session |
| Verdict must state **DERIVED** (re-derived from spec/ground truth) or **CONSISTENCY-CHECKED** (only checked against the board's claim) | Every sibling reads the board, so all are anchored by the seat's framing; only DERIVED is verification |
| Instruct: "falsify the brief, don't confirm it" | Counteracts the shared anchor |

**Validator seat (recommended):** one sibling (ORCHESTRATION.md → Validator) that **never builds** — READ, re-read, train/merge verification, falsification, measurement. A terminal that never builds is independent of every row. Others may READ when it's busy. Never hand the validator a build or fix round.

**The contract also carries** (each omission has produced a wrong verdict): authorized exceptions you approved (fence extensions, bundled work) · "rebuild any enumeration from scratch, don't check the builder's" · for "output unchanged" claims, "compile/build base + head and compare" · the environment's false-signal shapes (killed background run = NON-result; crash after passing summaries ≠ red; pass summary + non-zero exit = REAL failure; never pipe the gate) · reference gate counts for main and the branch's base.

Verdicts: **PASS** → reconcile. **DEVIATES/BROKEN** → findings to the SAME builder (fix-roundtrip) → scoped delta re-read; downstream blocked until PASS (LESSON 18). The subagent `verifier` (`/orchestration-kit:verify-feature`) remains the fallback when no independent sibling is free — say so on the row. **Context independence first, then model:** launch the verifier session on its lane's model (§3a — top tier for the high-risk classes) with `--model`; never trade a fresh context for a model match.

## 6 · Reconcile + board writes

- **One row at a time** (`/orchestration-kit:reconcile`), never parallel. Before each: no foreign rebase in progress; `git status` in the builder's worktree.
- After `git merge --no-ff`, **push immediately** (before notes, before the gate) — an unpushed merge gets linearized by the next plain rebase and the builder's SHAs never reach origin. Refresh with `git rebase --rebase-merges origin/main` while a merge is unpushed.
- Quote **on-main** SHAs only: `git branch -r --contains <sha> | grep -q origin/main`.
- ⚠ **`git push origin main` from INSIDE a worktree pushes that worktree's stale local `main`** — success line, nothing landed. Merge + push from the shared checkout and **verify every push by re-reading the remote** (the `--contains` check above).

**Board write in the shared checkout (every time):**
```bash
[ "$(git symbolic-ref -q HEAD)" = refs/heads/main ] || { echo "shared checkout not on main — STOP"; exit 1; }
git diff HEAD --quiet || { echo "shared tree/index dirty — a sibling's staged hunk would ride your commit; wait"; exit 1; }
# edit the board, then stage + commit AS ONE COMMAND (the index is shared):
git add docs/orchestration/AGENT_BOARD.md && git commit -m "chore(orchestration): <what>"
git push origin main                                # never HEAD:main
```
"nothing added to commit" + "Everything up-to-date" right after a write = a sibling's commit swept your hunk; re-check `git log -1 -p`.

**Board size:** status, not narrative. Past ~60 KB → `cp` it verbatim to `docs/orchestration/archive/BOARD_ARCHIVE_<YYYY-MM-DD>.md`, add a row to the board's archive table, rewrite the live board to status only. Archives are grepped, never read whole.

## 7 · Deploys and the log (§8 moved here)

**Before claiming the DEPLOY or LOG slot, read `deploy-and-log.md` in this skill's folder** (wave trains, the deploy steps and post-deploy check, the append-only log recipe). The two rules that shape every plan:

- **Deploy policy** = ORCHESTRATION.md → Deploy `deploy_policy:`. `ask` (default): ask the human before running the vehicle. `auto-when-green`: a train whose rows all passed READ and whose gate is green deploys without asking. Siblings never deploy while the banner stands.
- Log and milestone numbers are allocated only inside a LOG-slot claim (§1).

## 9 · Sibling lifecycle

**Before recycling anyone, read `recycle-and-handover.md` in this skill's folder** (the dry-run live-work check, in-place vs new-tab, exit codes, the relaunch fallback `claude --name <Name> --model <lane model> "/orchestration-kit:orient"`).

| Signal | Action |
|---|---|
| Sibling self-reports fill at the prompt mark; incoherent status; stale claim | SendMessage **"run /orchestration-kit:retro now"** + board note. A row already in flight finishes first |
| Sibling replies **"retro complete … background: none"** | ONLY NOW recycle, by the steps in `recycle-and-handover.md` (no `--model` = the default, never the old session's) |
| Fresh sibling sends READY | Assign the next DAG node (check `seen:` before giving it a READ) |

Retro-before-clear is a **handshake** (LESSON 24): order → explicit "retro complete" → recycle, one terminal at a time. Never pre-announce a clear.

## 10 · Seat context self-check

| Window (read your OWN env block) | Self-report | Hand over by |
|---|---|---|
| ~1M | ~350K | ~400K |
| ~200K (every small-tier model) | ~120K (60%) | ~150K (75%) |

- Measure: `python3 scripts/ctx-fill.py <uuid> --window <1m|200k>` (window from your env block) — sums input + cache_read + cache_creation off the last assistant turn. **Never `bytes ÷ 4`** (biased high 30–60%, unstably). **Never infer a window from a transcript's model string** — the one safe exception only lowers it: a small-tier (`haiku`) string means 200K, and ctx-fill applies it. (A seat on a ~200K window died at 175,725 tokens with no handover: that is why the small window's marks sit at 120K/150K, not 140K/160K.)
- At handover: **read `recycle-and-handover.md` §10 first** (finish what is in verify, wait for your own subagents and shells, write the handover block, run your retro, then recycle the seat; fallback relaunch `claude --name Orca --model 'opus[1m]' /orchestration-kit:orchestrate`).
- Include your measured fill + model in every handover and every roster report.

## 11 · The human's loop — all approvals through the seat

- Siblings **never** ask the human in their terminal. A permission prompt/denial or design question → the sibling stops and messages the seat → the seat asks the human HERE (batched) → relays the ruling (or runs the action itself). Restate this in every READY ack.
- Irreducible human work: design forks (surface BEFORE building), on-device checks, secrets, activations, and relaunching a terminal (`claude --name <Name> --model <lane model> …`, never a bare `/clear`) when recycling isn't available.
- **How the seat asks** (ORCHESTRATION.md → `questions:`):

| Mode | Do |
|---|---|
| `blocking` (default) | `AskUserQuestion`, batched. Most people expect and prefer the prompt |
| `non-blocking` (the human opted in) | While any sibling work is in flight, never block: ask in plain text (options, a recommendation, what waits on it), send a push notification, and keep everything that does not depend on the answer moving. Keep open questions on a `HUMAN QUEUE` line in the banner; lead your next reply with it when the human types anything. A blocking prompt is still fine when the human is at the terminal and nothing else waits |

- **Permission requests are a command, not prose.** First check the rule is not already there (`jq '.permissions.allow' .claude/settings.local.json`), then give ONE idempotent command the human pastes as `! <command>`, e.g. `jq '.permissions.allow |= (. + ["Bash(npm test:*)"] | unique)' .claude/settings.local.json > .claude/s.tmp && mv .claude/s.tmp .claude/settings.local.json`, plus one line on what it allows. Sessions never edit permission settings themselves, and never ask a sibling to run what their own permissions blocked.
- The seat writes: board, briefs, reconciles, deploys, logs. It does **not** write feature code.
