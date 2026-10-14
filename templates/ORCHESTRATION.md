# Project Orchestration Config — the overlay the kit's skills read

> Generic protocol lives in the kit (`orchestration-kit` plugin) and in `AGENT_BOARD.md`'s
> protocol table. THIS file holds everything project-specific. Every kit skill reads this
> file first and defers to it. Keep it short, keep it true.

## Gate

The trusted fast verification command(s) and what a REAL pass looks like.

```
command:      <e.g. npm test | make check | cargo test --workspace>
pass proof:   <the literal summary line to assert, e.g. "Tests N passed / 0 failed" per suite —
               NEVER trust exit code alone; a chained clean run can mask an earlier failure>
never run:    <known-flaky full-suite commands and WHY, e.g. "full parallel test — container storm">
slow path:    <the exhaustive gate reserved for pre-deploy / before a train, and when it's required>
run from:     INSIDE your own worktree (a script that cd's to its own dir gates the tree it lives in)
throttle:     bash scripts/gate-throttle.sh <command>   (host-wide slots: `gate_slots:` in the team block)
```

- **One full gate per tree.** Builders run the touched test files directly while they work (RED
  proofs, mutants, mid-row checks) and the FULL gate once, at GREEN-FINAL. A verifier reading at the
  builder's GREEN-FINAL SHA uses the builder's gate log at that SHA as gate evidence (it checks the
  printed counts itself) and runs only the extra files and mutants it needs. Mutants never go
  through the full gate.
- **Every whole-suite run goes through the throttle**, the full gate and any whole test suite alike,
  so N sessions on one machine never run N heavy suites at once (load flakes look like real reds).
  One or a few test files may run directly.
- `bash scripts/quiet-mode.sh on|off|status` frees the machine for the human: no NEW throttled run
  starts while it is on; running ones finish. The seat turns it on and off when the human asks.

## Change classes

Path patterns → risk class → extra gate + verifier escalation. Classes listed here as
high-risk get an AUTO independent verification before reconcile.

| Path pattern | Class | Extra gate | Verifier model |
|---|---|---|---|
| `<e.g. src/engine/**>` | `<e.g. golden-critical>` | `<e.g. goldens byte-identical>` | strongest available |
| `<e.g. **/migrations/**, schema files>` | `migration` | `<boot/constraint check>` | strongest available |
| `<e.g. billing/auth paths>` | `economy` / `security` | `<value/path tracing>` | strongest available |
| everything else | `standard` | — | default strong model |

## Deploy

```
vehicle:      <the ONE command the seat runs for a wave train, e.g. make deploy | gh workflow run deploy>
exclusivity:  claim the DEPLOY slot on the board first; under an ORCHESTRATOR ACTIVE banner only the seat deploys
post-deploy:  <how to verify the deploy actually took, e.g. bundle marker / health URL>
deploy_policy: ask             # ask | auto-when-green
```

- `deploy_policy: ask` (default): the seat asks the human before every deploy. `auto-when-green`: the seat
  deploys a train whose rows all passed their READ and whose gate is green without asking, then tells the
  human what shipped. Hotfixes the human asked for ship at once under either policy.

## Locked

Constants, formulas, fixtures, and files that subagents must NEVER change without the
human's explicit sign-off in-context:

- `<e.g. balance constants in src/constants.ts>`
- `<e.g. golden fixtures>`

## Sessions

```
board path:     docs/orchestration/AGENT_BOARD.md
archive dir:    docs/orchestration/archive/   (BOARD_ARCHIVE_<YYYY-MM-DD>.md; archive past ~60 KB)
tag scheme:     <Name> [<ref>]  — Name = the terminal's `claude --name`, ref = from ListAgents
context marks:  1M window: self-report ~350K, hand over by ~400K · 200K window: ~120K / ~150K
evidence dir:   ~/.orchestration-kit/scratch/<YYYY>/<Month>/<row>/   (probe scripts, gate/run logs, READ evidence, mutant outputs)
questions:      blocking   (blocking | non-blocking — see the orchestrate skill §11)
                measure: python3 scripts/ctx-fill.py <uuid> --window 1m|200k   (never bytes ÷ 4)
start team:     bash scripts/start-team.sh [--dry-run] [--siblings N]   (skips names already running)
recycle:        bash scripts/recycle-sibling.sh <Name> [prompt] [--model M] [--effort E]   (prints commands + exits 2 where no terminal can be opened)
```

Team — `scripts/start-team.sh` and `scripts/recycle-sibling.sh` read this block (flags override
it; without it the defaults are seat `Orca`, siblings `Sib1`..`Sib2`, normal permissions). Keep
the `team:` line unindented and the keys indented. `permission_mode` is one of `normal`
(asks before risky actions), `accept-edits` (`--permission-mode acceptEdits`), `auto`
(`--permission-mode auto`), `bypass-available` (`--allow-dangerously-skip-permissions`: starts
like `normal`; Shift+Tab can then switch to bypass, which has no permission checks at all); `start-team.sh --mode X` saves it here so recycles reuse it.
`worktrees` is `advised` (every session is instructed to work in its own git worktree; nothing
blocks it) or `enforced` (the kit's PreToolUse hook blocks file edits in the main checkout, except
`docs/orchestration/**`, the log and the status doc — needs the `.kit-hooks` marker). Keep
`advised` if your workflow deliberately shares one tree or file between agents.
`git_guard` is `off` or `on`. With `on` (and the `.kit-hooks` marker) the kit's PreToolUse Bash
hook blocks `git stash` (except `list`/`show`), `git add -A`/`--all`/`.`/`-u` without paths,
`git commit -a`/`--all` and `git pull --rebase`, telling Claude the safe alternative. Default:
`off` in practice (Solo) mode; kit-init sets `on` when it starts a team (seat + siblings). A human can still
run those in their own terminal.
`ctx_guard` is `off` or `on`. With `on` (and the `.kit-hooks` marker) the kit's context guard
(PostToolUse + UserPromptSubmit) measures each session's fill on every tool call and prompt and,
from the warn mark up, injects one line: approaching (300K), report now (350K), hand over now
(400K); on a 200K window 100K/120K/150K. It repeats every ~15K of growth (8K on 200K) and on
every prompt, so nobody has to remember to measure. Same default as `git_guard`: kit-init sets
`on` for a team, `off` in practice (Solo) mode. `context_window` (`1m` or `200k`, default `1m`) picks the marks for
the guard; a session whose transcript names a Haiku model always gets the 200K marks.
`max_sessions` (unset = no check): the most Claude sessions this machine should run, the seat and every
verifier included. `start-team.sh` and `recycle-sibling.sh` warn (never refuse) before passing it. Each
session holds several GB of RAM; on WSL, Windows kills the whole VM when it runs out of commit, with
nothing logged inside Linux. After such a crash, relaunch ONE session at a time and check it is up
before the next. Lower it if the machine struggles; raise it only with RAM to spare.
`gate_slots` (default 2) is how many throttled runs (`scripts/gate-throttle.sh`) may run at once on
this machine, plus one priority slot for the paths the seat lists in
`~/.orchestration-kit/runtime/gate-priority.txt` (release/train gates). Lower it if gates flake under load.
`model` / `effort` (both optional) set the default for every launch: `model` is `opus[1m]`, `sonnet[1m]`, `haiku` or a full model id (default `opus[1m]`), `effort` one of `low|medium|high|xhigh|max` (default: not passed). The launch scripts ALWAYS pass `--model` and never inherit the old session's, so a recycled session starts on the model its lane needs, not on whatever the terminal had. `--model` / `--effort` flags override the block; a bad value in the block is ignored with a warning, a bad flag exits 64. Per-lane choices: orchestrate skill, "Model per lane".
`terminal` picks how session windows open: `auto` (detect) or one of `wsl-wt`, `wsl-conhost`,
`tmux`, `tmux-detached`, `macos-iterm`, `macos-terminal`, `gitbash-cmd`, `linux-<emulator>`
(e.g. `linux-gnome-terminal`), `manual`. `bash scripts/start-team.sh --terminal list` shows
what is available on this machine; a `--terminal` flag overrides this key.
You can change any of this at any time — just ask Claude to change it.

```
team:
  seat:             Orca
  prefix:           Sib
  siblings:         2
  permission_mode:  normal
  worktrees:        advised
  git_guard:        off
  ctx_guard:        off
  context_window:   1m
  gate_slots:       2
  max_sessions:     8
  terminal:         auto
```

`evidence dir`: every scratch file a session makes (probes, logs it will quote, a verifier's evidence)
goes here, never under `/tmp` or a per-session temp dir: a reboot or a crashed VM wipes `/tmp`, and with
it the evidence a verdict rests on. Quote the path in reports so the next reader can open it.
`questions` is how the seat asks the human: `blocking` (the prompt waits for the answer; most people
prefer it) or `non-blocking` (for a human who steps away: text + a push notification, work that does not
depend on the answer keeps moving).

## Docs (institutional memory)

```
status doc:   docs/AI_CONTEXT.md           # what orient reads first: current state, deferred work
log:          docs/timeline/build-log.md   # append-only: Edit (append after the last lines), NEVER Write
memory:       Claude Code's auto-memory (~/.claude/projects/<slug>/memory/) — created by Claude Code; retro writes lessons there
```

## Validator seat

A sibling that NEVER builds — it only READs (verifies), re-reads fix rounds, verifies trains,
falsifies guards, and measures. Independent of every row because it built none of them.

```
validator:      <e.g. Check — or "none: any non-builder sibling READs">
lanes:          READ · re-read · train/merge verification · falsification · measurement
never:          build or fix rounds (a validator that builds loses its independence)
```

## Test hazards

Project-specific traps that make a red untrustworthy or a green vacuous:

- `<e.g. integration tests flake under container concurrency — run files one at a time>`
- `<e.g. piping test output masks the exit code — always read the real summary line>`
