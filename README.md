<p align="center"><img src="assets/orcastration-kit-logo.png" alt="Orcastration Kit logo: an orca leaping from a wave beside a gear" width="520"></p>

# Orcastration Kit

<p align="center"><img src="assets/orcastration-kit-banner.jpg" alt="An orca developer at a desk directing four agents on a screen under the Orcastration Kit logo" width="820"></p>

Run **several Claude Code sessions on one repo at the same time** without file collisions,
lost work, or confabulated green: a shared claimable board, one git worktree per session,
and every piece of work verified by a session that didn't build it. Proven on the origin
project: three concurrent sessions, ~15 workstreams, one evening, zero collisions.

## Quickstart — a seat and two siblings (5 minutes)

```bash
# 1. Install into your repo (normal shell, not inside Claude; on Windows run `wsl` first)
cd ~/projects/myapp
claude plugin marketplace add Artekka/orcastration-kit
claude plugin install orcastration-kit@artekka-kits --scope project

# 2. Set up the repo and start the team — inside Claude; tell it your test command,
#    then accept "Seat + 2 siblings" and approve the one command it runs
claude
/orcastration-kit:kit-init
```

Three windows open: **Orca** (the seat) and **Sib1**, **Sib2** (siblings). Talk only to the seat:

```text
You> add rows for: <task A>; <task B>, and get them built
Orca> filed rows, assigned A to Sib1 and B to Sib2 (disjoint file fences)
      ... Sib1 and Sib2 each build in their own worktree and report ...
Orca> Sib2 reads Sib1's row (contract only); B goes to a fresh verifier agent, because the seat never makes a mutual pair; both PASS; merged one at a time, gate green
```

That's the whole loop: the seat plans, assigns, routes verification and merges; the siblings build.
Walkthrough, Windows/macOS/Linux notes and failure modes: **[`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md)**.
How the whole loop fits together: **[`HOW-IT-WORKS.md`](HOW-IT-WORKS.md)**. Terms:
[`docs/GLOSSARY.md`](docs/GLOSSARY.md).

## One way to run it

A **seat** session plans, assigns, routes verification, merges one row at a time, deploys in trains and recycles full
sessions. You talk only to the seat; the siblings build. Start with the Quickstart above; reopen the windows later with
`bash scripts/start-team.sh` (opens the seat + 2 siblings), see [GETTING-STARTED §3](docs/GETTING-STARTED.md#3-who-does-what-the-seat-and-the-siblings).

This repo is a Claude Code **plugin** and its own **marketplace** (`artekka-kits`).
A project "depends" on the kit the way it depends on a package: install it, get the
workflow; upgrade it, get the newly distilled lessons.

## What's inside

| Piece | What it does |
|---|---|
| `skills/kit-init` | `/orcastration-kit:kit-init` — scaffold a project (board + overlay + scripts + CLAUDE.md section), idempotent |
| `skills/orchestrate` | the seat loop: banner, single-allocator, briefed rows, DAG + disjoint fences, sibling-session verification, one-at-a-time reconcile, wave-train deploys, LOG slot, sibling + seat recycling, approvals through the seat |
| `skills/orient` | session orientation: multi-session non-negotiables, five-bullet state, READY signal to the seat |
| `skills/board` | claim/update/close rows, per-session prefixes, the shared-checkout write recipe, status-not-narrative + archiving |
| `skills/verify-feature` | subagent verification — the fallback when no independent sibling session is free |
| `skills/orient-brief` | `/orcastration-kit:orient-brief <ROW>`: the lean start for a builder: the row's brief and the live seat banner arrive already loaded, then one READY line to the seat |
| `skills/assemble-train` · `skills/audit-train` | release trains: the seat lands approved rows one merge at a time with a dry run (`trial.sh`, `cptrial.sh`, `gsum.sh`) · a validator sweeps the finished train (`audit.sh` exits 0 when every merge is clean, 1 when a line needs explaining, 2 on a usage error) |
| `deploy_policy: ask \| auto-when-green` | the Deploy block of `ORCHESTRATION.md`: whether the seat asks you before every deploy (default) or deploys a green, audited train on its own and tells you after |
| `scripts/gate-throttle.sh` · `scripts/quiet-mode.sh` | run heavy commands through N machine-wide slots plus a priority slot (`gate_slots`); a second slot only while 3 GB of memory is available (`GATE_MIN_FREE_MB`); `--log <file>` writes the gate's log with the tested commit first and its exit code last; first come, first served, load-aware (tasks stuck in D state are not load), ONE slot per worktree (exit 3; `GATE_ALLOW_SECOND_SLOT=1` is the seat's escape), the priority list re-read on every poll, a TERM/HUP stops the command's whole process tree, and the command gets `GATE_WORKERS` (CPUs / slots, at least 2); **deploy mode**: while a priority gate runs, new normal gates wait and every other running gate's process tree is confined (taskset, reversible, nothing signaled) to the first 25% of the CPUs (`GATE_DEPLOY_OTHERS_PCT`, at least 2), each process getting its own mask back on exit, on a dead owner and at the next start; `gate_reuse_check:` / `GATE_REUSE_CHECK` asks first whether the tree already has a green record (a hit exits 0 without queueing) · quiet mode holds every new run while you use the machine (`status` also says whether deploy mode is on) |
| `station/` | **optional** Orcastration Station, adapted from Omar's Observatory: a Windows window (plus a WSL bridge) that watches every agent of several teams and can type to one in tmux; see the README section "Orcastration Station"; `kit-init` asks (default: CLI) |
| `plugins/status-hud` | **optional** second plugin (`status-hud@artekka-kits`): a band or pane that shows every session's context fill, model and activity; `kit-init` asks (default: no), `/hud band\|pane\|off\|quiet` switches it. Host meters work on Linux and WSL only |
| `HOW-IT-WORKS.md` · `docs/how-it-works.html` | the guide to the whole loop: one diagram, one short section per system (what it does, why it exists, which setting changes it), and how to make it your own |
| `skills/falsify` | mutation-prove a guard/test can fail: commit GREEN first, diff-verified mutant, prediction written before the run, red observed unfiltered, byte-clean restore, re-green |
| `skills/reconcile` | land one worktree at a time onto main, push merges immediately, re-prove the gate there |
| `skills/retro` | session close-out; in orchestrator mode skips deploy and replies "retro complete" to the seat |
| `skills/post-feature` · `skills/bootstrap-project` | per-feature close-out checklist · bare directory → kit-adopted project |
| `agents/verifier.md` | the read-only verifier subagent (contract-only, four checks, structured verdict) |
| `hooks/` | SessionStart hook: fresh sessions in a repo with a board are told to orient and send READY to the seat; silent no-op elsewhere · `worktree-guard.sh` (PreToolUse on Edit/Write/MultiEdit/NotebookEdit): with `worktrees: enforced` in ORCHESTRATION.md, blocks edits in the main checkout except `docs/orchestration/**`, the log and the status doc; no-op otherwise (the default is `advised`) · `git-guard.sh` (PreToolUse on Bash): with `git_guard: on`, blocks `git stash` (except list/show), `git add -A`/`.`/`--all`, `git commit -a`, `git pull --rebase` with the safe alternative; no-op otherwise (default `off`) · `discard-guard.py`, `pkill-full-guard.py`, `prettier-dir-guard.py`, `conflict-marker-guard.py` (PreToolUse on Bash) and `sendmessage-sha-guard.py` (PreToolUse on SendMessage): with `safety_guards: on`, refuse a discard of uncommitted edits, `pkill -f`, `prettier --write` on a directory, a commit that would carry a conflict marker, and a message that names a sha git cannot resolve (python3; they fail open). Tests: `bash tests/run.sh` |
| `scripts/start-team.sh` | open the seat + N siblings, each in its own window (terminal auto-detected), default names, skips any already running; `--dry-run`, `--terminal <backend>` / `--terminal list`, `--model` / `--effort` (always passed explicitly) |
| `scripts/recycle-sibling.sh` | replace a session with a fresh `claude --name X`: **in the same tab** when it runs under `sibling-shell.sh`, else a new window first and then SIGTERM the old one (`--new-tab` forces that); `--dry-run` (prints `mode:`), `--terminal`, `--account` (keeps each session on its own Claude Code account), `--model` / `--effort` (always passed, never inherited: the lane picks the model) |
| `scripts/sibling-shell.sh` | the respawn loop every tab the kit opens runs: starts `claude` as a child and, when `recycle-sibling.sh` leaves it a hand-off file, starts the next one in the same tab (crash-loop guard: two instant exits in a row stop it) |
| `scripts/tmux-session.sh` | one command to start (or reach) the tmux session that holds the team: `--seat Orca --model 'opus[1m]'` opens the seat as the session's first window under `sibling-shell.sh`, then attaches; `--install-command orca` writes a launcher so a reboot costs one word (`--install-windows` adds a Windows `orca.cmd` and a Windows Terminal profile on WSL). Loads `scripts/tmux/agents.tmux.conf` (mouse, extended keys so Shift+Enter works, stable window names). No tmux installed: the seat runs in the current terminal. |
| `scripts/seat-merge.sh` | the seat's merge path: `seat-merge.sh <branch> <READ-sha> "<message>"` merges **origin/<branch>** (never a local branch of that name) onto a fresh origin/main with `--no-ff`, runs your format check and checks on the MERGED tree, and pushes the checked sha only when all are green. Refuses a moved branch tip, a dirty tree, the shared checkout, a missing formatter, a second run in the same worktree; yields (bounded) to a waiting pusher's ticket; redoes the merge when only board/log commits landed meanwhile; removes the builder's worktree when provably idle. Config: a `seat_merge:` block in `docs/orchestration/ORCHESTRATION.md` (`format_cmd`, `install_cmd`, repeatable `check: name \| globs \| command`, `allowed_paths`) or `SEAT_MERGE_*` env vars; see the script header. Needs `scripts/lib-builder-worktree.sh` and `scripts/lib-waiting-tickets.sh` beside it; `bootstrap.sh` and kit-init copy all three. |
| `scripts/pending-work.sh` | the seat's poll for built work that never reached main (`bash scripts/pending-work.sh [--json]`, exit 0 clean / 3 listed): rows whose board text says READ PASS / GREEN-FINAL (or your approval word) but whose branch is not on origin/main (cherry-picked and superseded branches are skipped), stalled branches, a GREEN-FINAL commit that is on no remote, and recent branches cut from a stale main. Read-only. Hooks (`pending_work:` block in ORCHESTRATION.md, or `PENDING_*` env): board and archive paths, the row-id regex, which commit prefixes are docs-only |
| `scripts/lib-launch.sh` | the shared launcher both scripts source: detects the terminal backend — `tmux` (already inside tmux), `wsl-wt` / `wsl-conhost` (Windows + WSL), `macos-iterm` / `macos-terminal`, `gitbash-cmd`, `linux-<emulator>` (gnome-terminal, konsole, xfce4-terminal, kitty, alacritty, wezterm, foot, xterm, `$TERMINAL`, x-terminal-emulator), `tmux-detached` (SSH / headless), else `manual` (prints the commands, exits 2). Override: `--terminal` flag > `terminal:` in the team block > auto |
| `scripts/ctx-fill.py` | measure a session's REAL context fill from its transcript; `--window 1m\|200k` picks the marks (350K/400K on 1M, 120K/150K on 200K); a Haiku transcript implies 200K. `--line` prints one measured paste line for a report; `--check "<line>"` verifies it (exact fill at the claimed time, zone-aware, 30-minute limit, any account); `--host <ssh-target>` runs it on another machine (`KIT_REMOTE_REPO` names the checkout there) |
| `scripts/statusline-ctx.sh` | optional statusline: live context fill vs the 350K/400K marks (120K/150K on a 200K window) (yellow = self-report, red = hand over); enable via `templates/settings-snippets.md` |
| `scripts/bootstrap.sh` | the mechanical half of `bootstrap-project` (idempotent, `--dry-run`) |
| `templates/` | `AGENT_BOARD.md` (banner/handover/READY/archive shapes), `ORCHESTRATION.md` (gate, deploy, team, validator, doc paths), `AI_CONTEXT.md` + `build-log.md` (institutional memory), `CLAUDE-section.md`, `CLAUDE-slimness.md` (keep the always-loaded file slim), `briefs/` (row brief template + README), settings snippet, optional agents + memory starter |
| `docs/GETTING-STARTED.md` | first-timer walkthrough: install → kit-init → seat + siblings → recycling → failure modes |
| `docs/MULTI-ACCOUNT.md` | **optional:** run one team across several Claude Code accounts — `CLAUDE_CONFIG_DIR` per account, the shared session registry that makes cross-account messaging work, `--account` on both launch scripts |
| `docs/GLOSSARY.md` | the kit's vocabulary (seat, sibling, row, fence, gate, READ, wave train …) |
| `tests/` | `bash tests/run.sh` — git guard (every awk found), statusline, bootstrap idempotency + dry-run, multi-account launch, model/effort launch flags, ctx-fill marks and `--line`/`--check`/`--host` |
| `docs/LESSONS.md` | the distilled incident-backed lessons — the upgrade payload |
| `docs/EXAMPLE-SESSION.md` | **a real annotated 12-hour session** — one seat, three sibling builders, two deploy trains, and the six things the seat got wrong |

**What the WORK/QUIET chip does and when you'll see it:** The chip is a switch for the kit's quiet mode. QUIET holds every NEW test/gate run started through `scripts/gate-throttle.sh` while you use the machine yourself; runs already going finish, and WORK lets new ones start normally. It only helps if your team runs its gate through that throttle, so the chip appears only when `scripts/quiet-mode.sh` exists in the session's directory (or quiet mode is already on). No throttle, no chip. If a press fails, the chip turns red and says `failed` for a minute, and the toast says why. `/hud help` repeats this, and `quietModeRequiresFile` changes the file it looks for (empty always shows the chip).

**Generic vs project-specific:** the kit never hardcodes a gate or deploy command.
Project specifics live in the consuming repo's `docs/orchestration/ORCHESTRATION.md`
(created by kit-init); every kit skill reads it first. That split is what makes lessons
portable: they land here once and every project pulls them on upgrade.

## Install

Per repo (recommended — the kit is active only in the repos you install it into).
Run from inside the repo:

```bash
claude plugin marketplace add Artekka/orcastration-kit   # or a local path
claude plugin install orcastration-kit@artekka-kits --scope project   # or --scope local
```

Even when installed more widely, its hooks stay silent unless the repo carries
the opt-in marker `docs/orchestration/.kit-hooks` (created by `kit-init`); the worktree guard
additionally needs `worktrees: enforced`.

Then, in each project: run `/orcastration-kit:kit-init` once (it copies the scripts into
`scripts/`), then `bash scripts/start-team.sh`. Step by step: [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md).

Per-project (self-describing repo — teammates/machines get the plugin offered
automatically) — add to the project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "artekka-kits": {
      "source": { "source": "github", "repo": "Artekka/orcastration-kit" }
    }
  },
  "enabledPlugins": { "orcastration-kit@artekka-kits": true }
}
```

## Upgrade

```bash
claude plugin marketplace update artekka-kits
claude plugin update orcastration-kit
```

Read `CHANGELOG.md` for what changed. New lessons/hardenings = minor bump. A breaking
board-format/protocol change = major bump with a migration note. After upgrading, re-run
`/orcastration-kit:kit-init` in a project to be offered the template deltas (managed
markers keep your customizations safe).

## Upgrading from 0.16

0.17.0 renames the plugin id from `orchestration-kit` to `orcastration-kit`, so the product, the repo and the id
are spelled the same way. The marketplace carries a `renames` map: when Claude Code cannot find the old id, it follows
the map and migrates the `enabledPlugins` key in your user settings to the new id.
Project and local settings (`.claude/settings.json`, `.claude/settings.local.json`) may keep the old key; change it there
by hand as shown below. Because the marketplace is a git repo, the new id needs one install, once:

```bash
claude plugin marketplace update artekka-kits
/plugin install orcastration-kit@artekka-kits      # in a session; or: claude plugin install orcastration-kit@artekka-kits --scope project
```

Then restart the sessions and type `/orcastration-kit:<skill>` from then on (the old `/orchestration-kit:` prefix stops working).

If a project or local settings file still names the old id, or your Claude Code is too old to know the `renames` map
(the old id reports "not found in marketplace"), do it by hand:

```bash
claude plugin uninstall orchestration-kit --scope project
claude plugin install orcastration-kit@artekka-kits --scope project
```

and in `.claude/settings.json` and `.claude/settings.local.json` change the key `"orchestration-kit@artekka-kits"` under
`enabledPlugins` to `"orcastration-kit@artekka-kits"`.
Settings an admin manages are not rewritten for you; ask the admin to change that key.

The state folder moves with the id: the scripts now use `~/.orcastration-kit/`. When only the 0.16 folder `~/.orchestration-kit/` exists,
the first script to run makes the new name a link to it and says so in one line, so tabs that started on 0.16 keep their
recycle hand-offs. Project CLAUDE.md sections that carry the 0.16 marker are still recognized by `kit-init`, which offers the
new marker in its delta.

In each project adopted on 0.16, run `/orcastration-kit:kit-init` once more: the launch scripts it copied into `scripts/`
still start sessions with the old command prefix, and kit-init offers to refresh them (it asks first, because they may carry
local edits).

## The workflow in one paragraph

The seat takes the board with an `ORCHESTRATOR ACTIVE` banner; siblings `/orcastration-kit:orient` and send
READY. `git fetch origin && git rebase origin/main` → read `docs/orchestration/AGENT_BOARD.md`
→ the seat assigns a row (message + board, disjoint file fences) → the sibling builds in its
**own worktree** (never `git add -A`, never `git stash`) → a **different sibling session**
verifies it against the contract only (PASS required) → the seat reconciles
**one worktree at a time** onto main, re-proving the overlay's gate with the literal
pass line → update the board, release the fence → deploy only via the exclusive DEPLOY
row claim, in wave trains. Full sessions retro, reply "retro complete", and are recycled.
Every rule traces to a paid-for incident — see `docs/LESSONS.md`.

## What's new

v0.17.0: the plugin id is `orcastration-kit`, spelled like the product; see Upgrading from 0.16 above for the one install step.

v0.16.3: the title reads Orcastration Kit and the README carries the banner; the plugin id is unchanged.

v0.16.2: the Orcastration Kit logo at the top of this README.

v0.16.1: the merge script and the throttle take the fixes of the project they came from: committed conflict markers are refused, a signal ends a merge run at once, fetches and pushes retry transient denials, an orphan holding the lock is named, and a priority line ending in `/` matches its own tree.

v0.16.0: the Orcastration Station (`station/`, adapted from Omar's Observatory): an optional Windows window plus a WSL bridge that watches every agent of several teams and can type to one in tmux. Built from source for now (prebuilt binaries arrive in 0.17.0); `kit-init` asks which interface you want, CLI or the Station, and CLI stays as it was; CI builds and tests it on every push.

v0.15.0: recycling checks the model before it touches anything: one shared guard (`lib-model-tag.sh`) refuses a model name the CLI would only reject at the first prompt, and a recycle signals only a process that is still the session it named.

v0.14.0: three seat-poll tools: `bottleneck-watch.sh` (flags a merge, gate or idle main past its time budget, and a session stuck on a permission prompt), `main-checkout-sync.sh` (fast-forwards the shared checkout; a dirty file the incoming commits do not touch never stops it, one they touch does and the skip line names it) and a context window read from the session's own launch (`ctx-fill.py` needs no `--window` for your own session).

v0.13.0: five safety hooks, off until you turn them on (`safety_guards: on`): they refuse a discard of uncommitted edits, `pkill -f`, `prettier --write` on a directory, a commit that carries a conflict marker, and a message that cites a sha git cannot resolve.

v0.11.0: the guarded seat merge (`seat-merge.sh`), `pending-work.sh`, the tmux entry point (`tmux-session.sh`), a hardened `gate-throttle.sh` (deploy mode, one slot per worktree, a reuse-check hook), a measured, checkable context fill (`ctx-fill.py --line`), and disk cleanup (`retro-worktrees.sh`, `docker-cache-cap.sh`, a low-disk guard).

v0.10.0: the kit has one way to run, a seat plus siblings; the two-terminal practice setup is gone. The CHANGELOG says what to do if you used it.

v0.9.0: Team mode (a seat + siblings) is the default start; Solo is now Practice mode, where you play the orchestrator by hand with two sibling terminals to learn the loop.

v0.8.2: the status HUD's WORK/QUIET chip shows only where the quiet-mode script exists, explains itself, and shows a failed press in red.
v0.8.1: the guide's loop diagram fits phones, and the guide explains `LAUNCH_LIVE_RECHECK` (a refused recycle).
v0.8.0: release trains (`assemble-train`, `audit-train`) and a `deploy_policy` setting (ask or auto-when-green),
the gate throttle and quiet mode, a session cap (`max_sessions`), non-blocking questions, the lean
`orient-brief` start, a recycle that refuses while the old session still has live shells, the optional
status HUD plugin, and a guide to the whole loop: [`HOW-IT-WORKS.md`](HOW-IT-WORKS.md). Details in `CHANGELOG.md`.
v0.7.0: recycling in place. A recycled session now restarts in the SAME terminal tab (a respawn wrapper, `scripts/sibling-shell.sh`, runs
every tab the kit opens), with a fresh context, an explicit model and its own account. A session started by hand moves over at
its next recycle. See "Recycling in place" below.
v0.6.0: a model per lane (`--model` / `--effort` on both launch scripts, always passed, never inherited),
lean builder starts (`/orcastration-kit:orient --brief <ROW>` from a brief file), per-window context marks
(120K/150K on a 200K window), optional multi-account teams, and a note on keeping `CLAUDE.md` slim.
v0.5.0: solo mode as the starting path, a git guard hook (on in team mode, off solo), the `falsify` skill, a
context-fill statusline, MIT LICENSE, tests (`bash tests/run.sh`), a glossary, and the worked
example session. Full history: [`CHANGELOG.md`](CHANGELOG.md).

## Disk cleanup

A team that builds, tests and deploys all day fills a disk: worktrees nobody removed, Docker build layers from every deploy, test containers left running. One project lost 170 GB this way. The kit now carries three small guards. Each is plain bash, and each can be dry-run.

| Script | What it removes or refuses | What it always keeps |
|---|---|---|
| `scripts/retro-worktrees.sh --prefix <branch-prefix> [--dry-run]` (the `/retro` skill runs it as Step 4b) | worktrees of YOUR session whose branch is already on `origin/main` | an unmerged branch; a tree with uncommitted or untracked files, an unusual ignored file, a commit `origin/main` lacks, a file changed in the last 30 minutes, or a process running inside it; the worktree it runs in; every branch ref, so no commit is lost. It never uses `--force`, and an empty prefix is refused. |
| `scripts/docker-cache-cap.sh [--dry-run]` | the OLDEST Docker build-cache layers, down to `KIT_BUILD_CACHE_KEEP` (default `40GB`) | the most recently used layers; images and containers (it prunes the build cache only). Call it after a deploy that passed its health check, never before. A failure only warns. |
| `scripts/gate-disk-guard.sh` (`gate-throttle.sh` runs it before it queues) | nothing: it REFUSES to start a gate when free space is under the minimum | the disk as it was. The minimum is `KIT_GATE_MIN_FREE_GB`, or `gate_min_free_gb:` in the team block, default 20 GB; `0` turns it off; `KIT_GATE_DISK_PATH` picks the disk (default `/`). |

Try them without changing anything: `bash scripts/retro-worktrees.sh --prefix s5e307/ --dry-run` prints `would remove N, kept M` with the reason for every tree it keeps, and `bash scripts/docker-cache-cap.sh --dry-run` prints the command it would run. `bootstrap.sh` and the `kit-init` skill copy all three scripts (and the worktree safety check that `retro-worktrees.sh` and `seat-merge.sh` share).

## If you use tmux

`scripts/tmux-session.sh` is the one entry point. It creates (or reaches) the tmux session that holds the team, opens the seat in its own window, and attaches:

```bash
bash scripts/tmux-session.sh --seat Orca --model 'opus[1m]' --prompt 'Orient and orchestrate'
bash scripts/tmux-session.sh --install-command orca --seat Orca --model 'opus[1m]'   # then just: orca
```

- **One session per repo.** The name is `RECYCLE_TMUX_SESSION` if set, else the main checkout's directory name with anything outside `[A-Za-z0-9_-]` made `_` (`REPO_DIR` picks another checkout). `start-team.sh` and `recycle-sibling.sh` name their windows by the same function (`launch_tmux_session`), so every new window joins this session.
- **Recycling stays in place.** The seat's window runs `sibling-shell.sh`, the respawn loop, so `recycle-sibling.sh` replaces the session in the same window.
- **`--session NAME` names only this script's session.** If you also launch from outside tmux (`start-team.sh`, `recycle-sibling.sh` in another terminal), use RECYCLE_TMUX_SESSION, not --session: only the environment variable reaches those launchers.
- **`--install-command CMD`** writes `~/.local/bin/CMD`, a launcher that attaches when the session exists and creates it otherwise. A file at that path that the script did not write is refused.
- **WSL:** `--install-windows` adds a `CMD.cmd` and a Windows Terminal profile fragment, so a reboot costs two words.
- tmux does not survive a reboot or a WSL VM stop; run the command again, then recycle the sessions.
- Without tmux installed, `--seat` runs the seat directly in the current terminal.

## Recycling in place (v0.7.0)

`start-team.sh` and `recycle-sibling.sh` open each tab running `scripts/sibling-shell.sh <Name>`, which runs `claude` as its child. To
recycle, `recycle-sibling.sh <Name>` leaves the wrapper a small hand-off file (model, effort, permission mode, account, prompt) under
`~/.orcastration-kit/sessions/`, SIGTERMs only the old `claude`, and the wrapper starts the fresh one in the same tab. Same tab, no
stray windows, and nothing the old context held is lost, because a recycle only runs after the session replied "retro complete".
It opens a new tab instead (running the wrapper, so that session recycles in place next time) when there is no old process, the old
one was started by hand, you pass `--new-tab`, the machine has no `setsid` (macOS) and the seat is recycling itself, or the in-place
attempt times out (60 s; `RECYCLE_INPLACE_TIMEOUT`). The seat can recycle itself in place: the script prints a log path
(`~/.orcastration-kit/sessions/<Name>.recycle.log`), hands the work to a detached copy of itself and exits, and the copy ends the seat's
session about 2 s later (`RECYCLE_DETACH_DELAY`) so the seat's last command finishes first. `--dry-run` prints `mode: in-place` or `mode: new-tab`, and `detach: yes|no` for a self-recycle. `LAUNCH_NO_WRAPPER=1` opens tabs with a bare
`claude` as before.

**What is tested where.** The in-place path reads the process tree, so it needs `pgrep`: it is tested on Linux (and WSL), including
the `ps` code path that macOS uses (forced with `LAUNCH_NO_PROC=1`), but it has **not been run on a real Mac or in Git Bash**. Git
Bash (no `pgrep`) and the `manual` backend keep launching a bare `claude` and the old new-window recycle. On WSL a kit path that
contains a space cannot cross the `wt.exe` command line, so those tabs fall back to a bare `claude` too.

## Orcastration Station

Orcastration Station, adapted from Omar's Observatory. It is a desktop window for watching, and typing to, several kit teams at once. Every agent has its own terminal; the Station puts them all in one place: a sidebar of every agent in every project you list, and the selected agent's chat rendered like Claude Code's own panel (Markdown, folded tool calls, live updates). It lives in `station/` and is **optional**: the kit works the same without it, and a CLI-only team never needs it. It reads; it starts and stops nothing.

**The two programs.**

- **`observatory.exe`** is a native Rust window (eframe/egui, no web view) for Windows.
- **`observatory-bridge`** is a small program inside WSL. The window starts it over `wsl.exe`; the two talk in JSON lines on stdin and stdout, with no network port. The bridge reads Claude Code's session logs (`~/.claude/projects/**.jsonl`) and session registry (`~/.claude/sessions/*.json`) locally, follows them with inotify, and sends parsed messages to the window.

Until 0.17.0 the programs, the config folders (`~/.config/observatory/`, `~/.local/share/observatory/`) and the `OBSERVATORY_*` environment variables keep the working name `observatory`. The commands below use those names as they are.

**What you get.** One sidebar group per project (seats first, then siblings, each with a status dot: working, idle, needs you, gone). The selected agent's chat, with your messages as bubbles, replies as Markdown, tool calls folded to one line, thinking behind a toggle, and a restarted agent continuing the same thread after a divider. Images agents save appear as thumbnails, and each project can show a **Visuals** gallery of folders you list. A list of the claude.ai pages agents published. Typing to an agent that runs in tmux (rules below). Out of scope on purpose: approve and deny buttons, diffs, editing code, starting or stopping sessions.

**Requirements.**

- Windows 10/11 with WSL2 (developed on Ubuntu). The window runs on Windows; the bridge and every build step run in WSL.
- In WSL: a Rust toolchain via rustup with the `x86_64-pc-windows-gnu` target, the MinGW cross compiler (`gcc-mingw-w64-x86-64` on Ubuntu), `python3` and `git`. `tmux` only for typing.
- Claude Code sessions started the kit's way (`claude --name <Name>`), in tmux if you want to type to them.

**Install.** Prebuilt binaries arrive in 0.17.0; until then the one path is to build from source, in WSL, from a checkout of this repository (a plugin cache copy is not one):

The rustup line downloads an installer script from sh.rustup.rs and runs it (`curl | sh`). To avoid that, install rustup by hand ([the manual install page](https://rust-lang.github.io/rustup/installation/other.html)) with `RUSTUP_HOME` and `CARGO_HOME` set to the same two folders, then continue at the `rustup target add` line.

```bash
cd station
export OBSERVATORY_RUST_DIR=~/observatory-rust   # rustup, cargo and a target dir per checkout live here
RUSTUP_HOME=$OBSERVATORY_RUST_DIR/rustup CARGO_HOME=$OBSERVATORY_RUST_DIR/cargo \
  sh -c 'curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'
. scripts/env.sh && rustup target add x86_64-pc-windows-gnu
bash scripts/deploy.sh --dry-run --install-root /mnt/c/Apps/OrcastrationStation   # every step, nothing built
bash scripts/deploy.sh --install-root /mnt/c/Apps/OrcastrationStation
```

`deploy.sh` runs the gate first, builds both programs, copies `observatory.exe` and `VERSION.txt` into the folder you chose and the bridge into `~/.local/share/observatory/bin` (the window looks for it there), proves each copy by sha256, and makes a desktop shortcut named "Orcastration Station". It has no default install folder. It refuses a dirty `station/` folder, a `station/` folder that is not on `origin/main` (`--allow-unlanded` overrides), and a gate whose last line is not `GATE PASS (<N> tests)`. To try the window with built-in sample sessions and no bridge: `. scripts/env.sh && cargo run -p observatory-app -- --demo` (WSLg). `station/README.md` has the details, and `station/docs/BRIEF.md` is the product spec.

**Config.** The bridge reads one JSON file, outside the repository: `--config <path>`, else `$OBSERVATORY_BRIDGE_CONFIG`, else `$XDG_CONFIG_HOME/observatory/bridge.json`, else `~/.config/observatory/bridge.json`. Every field is optional; an unknown field is an error the bridge reports, then it starts with defaults. Without a file only sessions started in the home folder appear, with a sidebar note saying where the file goes. The window reads it once at startup.

| key | default | meaning |
|---|---|---|
| `projects[].name` / `.root` | required | the sidebar heading; the folder (a session belongs to the project whose `root` or `worktree_roots` holds its launch folder, longest match wins) |
| `projects[].worktree_roots` | `[]` | folders holding the project's kit worktrees |
| `projects[].gallery` | `[]` | image folders for the Visuals view, scanned recursively (`*` and `?` match in a path segment) |
| `projects[].exact` | `false` | claim only `root` itself (use it for the home folder) |
| `seats` | `[]` | names shown as seats; with none set, the kit's default seat name `Orca` |
| `cutoff_days` / `liveness_secs` / `coalesce_ms` | `7` / `5` / `250` | how far back to read at startup (`0` = all); how often running processes are re-checked; how long updates to one session wait to go out together |

**Typing to an agent: the safety rules.** Typing is the only thing the Station does besides reading, so it is narrow on purpose.

- **Only on an explicit Send.** Nothing is typed until you click Send or press Enter (Shift+Enter is a new line). Nothing sends on startup, reconnect or focus, and a draft is never resent on its own.
- **Only to the selected agent's own live tmux pane.** At send time the bridge finds the pane from the running process tree (that agent's `claude` process and the tmux pane it is in), never by name. It refuses when the agent is not running, is not in tmux, or the process or pane is ambiguous.
- **Sent only when the agent's status is known to be safe.** Claude Code's session registry must say `idle` (the prompt is open), `busy` (a turn runs; the message queues) or `shell` (a shell command runs beside the open prompt). If it says `waiting` (a question or permission dialog is open), gives no status, or gives any other value, nothing is sent and the window says why.
- **Sent only while the idle input box is on screen.** Right before the paste and right before the Enter, the bridge reads the pane's visible text (`tmux capture-pane -p`, read only). It types only when Claude Code's idle input box is at the bottom of the screen; any other screen (a question, a permission dialog, a shell, an empty or unknown screen) refuses, and the window says why. If the screen cannot be read, or the read takes over two seconds, the send is refused too. This catches a dialog that opened before Claude Code wrote "waiting" to its registry.
- The text is pasted as one block (`tmux load-buffer` plus a bracketed `paste-buffer`, so newlines stay inside the message), the pane is checked again, then Enter is pressed once. If the re-check finds that something changed after the paste began, the window says the result is uncertain and keeps your draft. A change in the moment between the last check and the Enter is not detected (see the limits).

**Known limits.**

- **A question that opens at the wrong moment.** The status and screen checks happen just before the paste. If the agent opens a question in the instant between those checks and the paste, the pasted text lands in the question, though the bridge does not press Enter on it (the checks before the Enter no longer see the input box). Whether stray keys can pick an option in a real dialog has not been tested.
- **A change right before the Enter.** The last checks (status, pane, screen) run just before Enter is pressed. If a question opens in the few milliseconds between them and the Enter, it is not detected, and the Enter goes to whatever is on screen then. Nothing checks the pane after the Enter.
- **The screen check depends on how Claude Code draws its input box.** A send types only when the bottom of the pane shows the input box as Claude Code 2.1.322 draws it: a rule of `─` (it may carry the session name), the `❯` prompt row and any typed rows, a second rule, then up to six status or hint rows that start with two spaces. That shape comes from real `tmux capture-pane` captures. If a future Claude Code draws the box differently, every send is refused until the check is updated: an unknown screen refuses, it never sends. The refusal tests for the question menu and the permission dialog use shapes derived from Claude Code's code, not captured from a live dialog.
- **What `shell` means is inferred, not documented.** Claude Code's registry reports `shell` for some live sessions. On one machine with ten live sessions (each registry file checked against its process's start time in `/proc`), every `shell` entry had a running shell child process and no idle entry did, so `shell` reads as "a shell command runs beside the open prompt". Sending is allowed for it. If a future Claude Code uses `shell` for something else, this rule needs checking again. Any status the bridge does not know is refused.
- **The privacy checks are heuristics.** `real-data-check.py` does not yet catch timestamps rounded to the second or with zeroed milliseconds, epoch-millisecond numbers, or ids with changed case or dashes. `clean-tree.py` does not catch a term split across lines, a term inside base64, `%xx` or HTML entities, or a term spelled only with hex letters inside a long hex run.
- **The log format is undocumented.** The parser follows Claude Code's local files as they are today and skips unknown record types. A new Claude Code version can still change what shows.
- **Windows with WSL only, for now.** The window expects the bridge at `~/.local/share/observatory/bin/observatory-bridge` in the default WSL distro. The bridge itself starts directly on Linux, but there is no native Linux window build or installer yet (planned for 0.17.0).
- Pages older than `cutoff_days` do not appear in the pages list. Raise it to see older ones, at some cost in startup time.

**Choosing it in setup.** `/orcastration-kit:kit-init` asks once: interface = CLI (the default; nothing changes) or the Station. The answer is stored as `interface: cli | station` in the team block of `ORCHESTRATION.md`. Choosing the Station prints the install steps above and runs nothing.

## Assumed plugins (user-level — documented, never copied)

The workflow assumes nothing beyond stock Claude Code. These user-level plugins are
routinely present on the origin setup and complement the kit, but the kit never installs
or requires them: `superpowers` (TDD/debugging discipline), `code-review`, a token/context
hygiene plugin. If a skill here references one, treat it as optional.

## Security

Report a vulnerability privately, never in a public issue: see [SECURITY.md](SECURITY.md) for the
supported versions, the private reporting channel and what to expect. CI scans every push and pull
request for secrets, and `tests/leak-guard.test.sh` keeps personal paths and keys out of the repo.

## Contributing

Pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, `bash tests/run.sh`, the
branch and PR flow, commit messages and the optional pre-push secret scan. Everyone follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Contributors

- Miles Brown (@MilesBrown34): also presented the disk-cleanup issue behind `retro-worktrees.sh`, `docker-cache-cap.sh` and the low-disk guard
- Naga/Omie (@Babasher): presented the disk-cleanup issue behind the same scripts
