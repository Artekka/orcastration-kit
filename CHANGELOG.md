# Changelog — orchestration-kit

Newest first.

## Unreleased

## 0.11.0 — 2026-11-24

The stack of tools that one project has run daily, now in the kit: tmux entry point, the seat's guarded merge, pending-work, a hardened gate-throttle with deploy mode, a measured context fill, and disk cleanup.

### Disk cleanup

A kit user's SSD filled (170 GB of old Docker layers, worktrees and leftovers), so the guards the originating project runs daily are in the kit (plain bash, each with a dry run; see the README section "Disk cleanup").

- **Added: a project-word class in the leak guard** (the originating project's name and its board row ids fail it; a planted one turns it red) and pins for the bug-report placeholder and the README "What's new" version.
- **Fixed: `gate-throttle.sh --log` no longer empties an existing log when the gate is refused** (disk guard, one slot per worktree, reuse check); the log is emptied only where the command starts.
- **Fixed: `retro-worktrees.sh --prefix` must end with `/`** (a bare `s5e30` also matched `s5e307/…`).
- **Added: `scripts/retro-worktrees.sh --prefix <branch-prefix> [--dry-run]`** — removes the retiring session's worktrees whose branch is already on `origin/main`. Keeps an unmerged branch, any tree with uncommitted or untracked files, a commit `origin/main` lacks, a file changed in the last 30 minutes or a process inside it, and the worktree it runs in; never `--force`; branch refs stay. An empty prefix is refused. The `retro` skill runs it as Step 4b and reports its counts.
- **Added: `scripts/docker-cache-cap.sh [--dry-run]`** — trims the Docker build cache to `KIT_BUILD_CACHE_KEEP` (default `40GB`), keeping the most recently used layers. Call it after a deploy passed its health check. A failure only warns; no docker is a note.
- **Added: `scripts/gate-disk-guard.sh`**, run by `gate-throttle.sh` before it queues: it refuses (exit 1) when free space is under `KIT_GATE_MIN_FREE_GB` / `gate_min_free_gb:` (default 20 GB, `0` = off, `KIT_GATE_DISK_PATH` picks the disk). An unreadable `df` never blocks.
- **Changed: `bootstrap.sh` and the `kit-init` skill copy the three scripts.**
- **Added: `tests/disk-cleanup.test.sh`** (fake `df` and `docker`; throwaway repos).
- Thanks to Naga/Omie (@Babasher) and Miles (@MilesBrown34) for presenting the disk-cleanup issues.

tmux entry point, ported from a project that has run it daily.

- **Added: `scripts/tmux-session.sh`** — starts or reaches the tmux session for the team, optionally with the seat as its first window (`--seat Name --model M [--effort E] [--prompt P]`), `--install-command CMD` to write a one-word launcher, `--install-windows` (WSL) to add a Windows `CMD.cmd` and a Windows Terminal profile. Falls back to running the seat in the current terminal when tmux is not installed. The default session name follows `launch_tmux_session`, so `start-team`/`recycle-sibling` add windows to the same session.
- **Added: `scripts/tmux/agents.tmux.conf`** — mouse, 200k history, true color, extended keys (Shift+Enter), passthrough, stable window names.
- **Changed: `sibling-shell.sh`** names its tmux window `<Name>` once when it runs in a tmux pane.
- **Fixed: bootstrap.sh and the kit-init skill now copy `seat-merge.sh` with its two libs** (`lib-waiting-tickets.sh`, `lib-builder-worktree.sh`), which a new project was missing; `tests/bootstrap.test.sh` pins all three.
- **Changed: `gate-throttle.sh`**, ported from a project that has run it daily.
  - An unknown `--option` is refused (exit 2) instead of being queued as a command.
  - ONE slot per worktree: a second throttle from a worktree that already holds a slot or waits is refused (exit 3), checked under the ticket lock; `GATE_ALLOW_SECOND_SLOT=1` is the seat's escape.
  - The priority list is re-read on every poll, in one canonical path form (symlinks resolved; a trailing `/` means inside the directory); a change is announced once.
  - A TERM or HUP stops the command's whole process tree (then KILL after `GATE_STOP_GRACE`, default 5 s, for a process that ignored it); the throttle exits 143 / 129.
  - Load: tasks stuck in uninterruptible sleep (D state) are subtracted from the load average (two samples `KIT_DSTATE_GAP` apart), so a hung driver cannot hold every gate.
  - Start times come from `/proc/<pid>/stat` (ps `lstart` drifted under load and made live tickets look dead; `ps` stays the fallback without `/proc`); `quiet-mode.sh status` uses the same function. A run entry is now two lines (slot/dir/command, start time).
  - The command gets `GATE_WORKERS` = CPUs / slots (held to the CPU mask, at least 2) unless you set it.
  - Not ported (own row): the project gate's own `--reuse-check` flag (the throttle's hook for it is ported; deploy mode is below).
- **Added: `tests/gate-throttle-port.test.sh`** (55 checks); `tests/gate-throttle.test.sh` sets `GATE_ALLOW_SECOND_SLOT=1` because it starts several throttles from one directory on purpose.
- **Docs: `--session` names only `tmux-session.sh`'s own session.** README, GETTING-STARTED and the `--install-command` help say to use `RECYCLE_TMUX_SESSION`, not `--session`, when you also launch from outside tmux; a test pins the line in all three.
- **Added: `ctx-fill.py --line`, `--check` and `--host`** — a fill report is measured, then checkable. `--window 1m|200k|<tokens> --line` prints one paste line (`fill N / W · marks P/H · STATUS · measured <stamp> <zone> · session <id8>`); `--check "<line>"` verifies it against the transcript in any account's project dirs: exact equality with one of the last two distinct fills at the claimed time (a mid-turn line cannot see its own turn), the stamp's zone token honored, a 30-minute age limit, exit 0 MATCH / 3 STALE, MISMATCH, NOSESSION, AMBIGUOUS / 2 not a line. `--host <ssh-target>` runs the script on another machine (`KIT_REMOTE_REPO`, else this checkout's path under `$HOME`). Verdict codes come from one `verdict_of()` shared by the report and the line.
- **Changed: the `tmux-detached` backend** starts its session with the same config when the file ships.
- **Fixed: one tmux session-name rule.** `launch_tmux_session` (lib-launch.sh) now honors `RECYCLE_TMUX_SESSION`, and `tmux-session.sh` takes its default name from that same function (and honors `REPO_DIR`), so the entry point and every later `start-team`/`recycle-sibling` window land in one session. README "If you use tmux" and a GETTING-STARTED paragraph document the entry point.
- **Added: `tests/tmux-session.test.sh`** (76 checks, stub tmux, no real server).
- **Added: `scripts/seat-merge.sh`** (+ `lib-builder-worktree.sh`, `lib-waiting-tickets.sh`) — the seat's guarded merge, ported from the project where 25 fix rounds hardened it. Project-specific parts are config hooks (`seat_merge:` block or `SEAT_MERGE_*` env): format command, install command, path-selected checks, the board/log paths that may land during a long check. Not ported: the hosted-bundle and page-reader selection (those become `check:` lines).
- **Added: `scripts/pending-work.sh`** — the seat's poll for built work that never reached main, ported from a project that ran it every ten minutes. Sections: PASSED, NOT ON MAIN · IDLE · UNPUSHED GREEN-FINAL · BEHIND MAIN; `--json`; exit 0 clean / 3 listed / 2 usage; read-only. Project parts are config hooks (`pending_work:` block in ORCHESTRATION.md or `PENDING_*` env): `board_path`, `archive_path`, `row_id_regex`, `docs_prefixes`. Not ported: the sprite-hub approvals section (it read a production database). bootstrap.sh and kit-init copy it; `templates/ORCHESTRATION.md` documents the block.
- **Fixed: bootstrap.sh and the kit-init skill now also copy `tmux-session.sh` and `scripts/tmux/agents.tmux.conf`** (the entry point loads the conf from its own directory); `tests/bootstrap.test.sh` pins both.
- **Fixed: bootstrap.sh and the kit-init skill also copy `sibling-shell.sh`** (`tmux-session.sh --seat` and the in-place recycle both run it from their own directory).
- **Fixed: the kit suite no longer touches the caller's tmux.** `tests/run.sh` starts every test without `TMUX`/`TMUX_PANE`, every test file unsets both, and `tests/no-real-tmux.test.sh` runs the launcher suites with a fake pane and a logging `tmux` and fails on any call (a suite run inside a tmux pane had renamed real windows).
- **Added: tests** for gate-throttle's and quiet-mode's liveness rules on stale fixtures (a reused live pid in a ticket or a run entry, a dead ticket, a burst of D-state tasks that ends between the two samples, a pid reused during the KILL grace window); each goes red with its mutant.
- **Added: gate-throttle deploy mode** — while a gate that took the priority slot runs, new normal gates wait (one notice) and every other running throttled gate's process tree is confined with `taskset` to the first `GATE_DEPLOY_OTHERS_PCT` (25) percent of the CPUs, at least 2. Affinity, not nice (reversible without privileges); nothing is signaled or stopped. Each process gets its OWN recorded mask back when the priority throttle exits (TERM/INT/HUP too), from its monitor when it dies without a trap, and at the top of every throttle start; a pid whose start time changed is never touched; priority gates are never confined. Without `taskset` (`KIT_TASKSET_BIN` names it) it is an admission hold with a note. A run entry gains a third line `prio=0|1`. `quiet-mode.sh status` prints `deploy mode: ON (<dir>)|OFF`.
- **Added: the reuse-check hook** — `GATE_REUSE_CHECK` or `gate_reuse_check:` in the team block names a command run as `<it> <your command and args>` before a ticket is taken; exit 0 = a green record exists, so the throttle exits 0 without queueing or running the command; any other exit queues as usual. The throttle still defines no flag of its own: a `--reuse-check` after the command reaches your gate, and a leading one is refused.
- **Added: `tests/gate-throttle-deploy.test.sh`** (58 checks; the mask cases need 4+ CPUs, two need 8).
- **Added: `tests/pending-work.test.sh`** (75 checks on throwaway repos with planted commit dates).
- **Added: `tests/seat-merge.test.sh`** (131 checks on throwaway repos).
- **Added: a `seat_merge:` section in `templates/ORCHESTRATION.md`** documenting every hook (`format_cmd`, `install_cmd`, `check`, `allowed_paths`, `yield_max_s`, `yield_poll_s`, `idle_minutes`, `SEAT_MERGE_RUNTIME_DIR`) with a recommended `check:` line whose globs are `*`; a test parses the block as written. seat-merge.sh states that config is read BEFORE the merge, and its runtime dir now follows `KIT_RUNTIME_DIR` like `gate-throttle.sh`.

## 0.10.0 — 2026-11-24

- **Removed: Solo Mode (the "Practice mode (Solo)" answer).** The kit now has one way to run: a seat plus siblings. Why: nobody needs a practice mode; it started nothing, and the team start is the same loop with the coordinating done for you. What changed: kit-init's start question has no practice answer, so every start turns the git guard and the context guard on; the README, GETTING-STARTED (the practice section is gone and later sections moved up one number), the guide, the glossary and the overlay template describe one way to run; the glossary reads "no banner = no seat". The words "Team mode" and "default" are gone too, since there is no other mode to be the default of; the section anchor is now `#3-who-does-what-the-seat-and-the-siblings`. The guide no longer offers a "Two sessions, no seat" size: the smallest setup it describes is a seat plus siblings. No script or hook branched on the mode, so nothing else changes. **If you used Solo Mode:** nothing breaks. Your committed `docs/orchestration/ORCHESTRATION.md` keeps its values (`git_guard: off`, `ctx_guard: off` stay off until you change them). To learn the loop by hand, open two sessions yourself and use the board; to run it with a seat, run `bash scripts/start-team.sh`. What you lose is only the kit-init answer that started nothing and set both guards off.
- **Added: a docs pin** that fails if "solo mode", "Practice mode" or the old mode table come back in the README, kit-init, the guide or the glossary, and a pin that fails if `plugin.json`, `marketplace.json` and the newest CHANGELOG heading disagree on the version.
- **Changed: the GitHub repository is now `Artekka/orcastration-kit`** (was `claude-orchestration-kit`). Install with `claude plugin marketplace add Artekka/orcastration-kit`; the plugin id (`orchestration-kit@artekka-kits`), its slash commands and `~/.orchestration-kit/` do not change. GitHub redirects the old URL, so existing installs keep working. README, GETTING-STARTED, CONTRIBUTING, SECURITY, the issue-template link and the Code of Conduct contact link use the new name; the plugin manifest gains `homepage` and `repository`.
- **Fixed: a team start with no Claude running exited silently.** (PRS 2026-10-17)
- **New: `gate-throttle.sh --log <file>`.** (PRS 2026-10-15)
- **New: memory-aware gate slots.** (PRS 2026-10-16)
- **New, status HUD: model badges.** (PRS 2026-10-14)
- **New, status HUD: session state at a glance.** (PRS 2026-10-14)
- Thanks to @MilesBrown34 for #3, #4, #10, #11 and #12.

## 0.9.0 — 2026-10-14

Team mode is now the default; Solo is a practice mode.

- **Changed: the README quickstart, GETTING-STARTED and the guide lead with Team mode** (seat + siblings). The 5-minute path is `kit-init`, accept "Seat + 2 siblings", talk to the seat.
- **Changed: Solo becomes "Practice mode (Solo)"**, the third answer of kit-init's start question (was "Not now"). It starts nothing and routes as before (git guard and context guard off). GETTING-STARTED §4 is a practice ground with a guided demo: you play the orchestrator, file two rows, hand one to each sibling terminal, and let each verify the other's. Sections moved: Team is now §3, Practice §4, "What you get" §5.
- **Added: a docs pin** (`tests/docs-pins.test.sh`) that fails if kit-init's first start option stops being the team start, if the last option is not "Practice mode (Solo)", or if the docs call Solo the recommended start again.
- Script behavior is unchanged; only the default answer and the wording moved.

## 0.8.2 — 2026-10-13

The status HUD's WORK/QUIET chip now shows only where it can work, says what it does, and no longer fails silently.

- **Changed: the chip is hidden without the toggle script.** New `quietModeRequiresFile` (default `scripts/quiet-mode.sh`, resolved against the session's directory). A project with no throttle script shows no chip; a chip whose quiet mode is already ON stays so you can turn it off. An empty value always shows the chip. If you use your own on/off commands, set `quietModeRequiresFile` to an empty value to keep the chip.
- **Fixed: a failed press was invisible.** The chip turns red and reads `failed` for 60 seconds (still pressable to retry), and the toast carries `exit N: first output line`.
- **Added: explanations.** Press toasts say what QUIET/WORK did, the pane shows a caption under the chips, `/hud help` prints it, and README, GETTING-STARTED and the guide page have a paragraph "What the WORK/QUIET chip does and when you'll see it".

## 0.8.1 — 2026-10-13

Polish for the guide page and its troubleshooting notes. No behavior change in any script.

- **Fixed: `docs/how-it-works.html` on a phone.** The loop diagram used to scroll sideways inside its box and cut off the Seat. Under 700 px wide the page now shows a stacked version of the same diagram (every node, nothing cut off, no sideways scrolling).
- **Fixed: diagram labels.** The "PASS" label no longer sits on an arrow, and "fix round" is moved off its arrow in both diagrams. A new check in `tests/how-it-works.test.sh` fails if any label overlaps an arrow, if the stacked diagram loses a node, or if the phone layout stops being swapped in.
- **Documented: `LAUNCH_LIVE_RECHECK`.** The guide explains the recycle refusal (exit 3), the two-look check that ignores short-lived shells, when to set `LAUNCH_LIVE_RECHECK=3`, and `--force`. A test pins the documented default to the one in `scripts/lib-launch.sh`.

## 0.8.0 — 2026-10-13

The catch-up release: ten days of practice from the project that runs this kit daily, in generic form.

- **New: release trains.** `assemble-train` lands approved rows onto a train branch one merge at a time, with a dry run before each and a full gate per row. `audit-train` is a validator's independent sweep of the finished train (`audit.sh` exits 0 when every merge is clean, 1 when a line needs explaining, 2 on a usage error).
- **New: `deploy_policy: ask | auto-when-green`** in the Deploy block of `ORCHESTRATION.md` (default `ask`). The seat's deploy step follows it.
- **New: gate throttle and quiet mode.** `scripts/gate-throttle.sh` runs heavy commands through `gate_slots` machine-wide slots plus a priority slot; `scripts/quiet-mode.sh on|off|status` holds new runs while you use the machine. Tickets carry the waiter's start time, so a reused process id no longer blocks the line.
- **New: one full gate per tree** and "whole-suite runs go through the throttle", written into the overlay template.
- **New: session cap.** `max_sessions` in the team block; `start-team.sh` and `recycle-sibling.sh` warn before a launch passes it. It counts processes named `claude`.
- **New: non-blocking questions.** `questions: blocking | non-blocking`; a permission request is one copy-pastable shell command, never a prose "please approve".
- **New: `/orchestration-kit:orient-brief <ROW>`**, the lean start: the row's brief and the live seat banner arrive already loaded.
- **New: evidence dir** (`~/.orchestration-kit/scratch/…`): scratch and READ evidence never live in `/tmp`.
- **Changed: `recycle-sibling.sh` refuses (exit 3) while the old session still has live shells**; `--force` overrides. The retro reply says `background: none` when it is safe.
- **Changed: skills load `SendMessage` and `ListAgents` through ToolSearch first**, and the docs gain a requirements list, a platform check and troubleshooting rows.
- **New, optional: the status HUD** as a second plugin in this marketplace (`status-hud@artekka-kits`): a band or pane above the prompt with every session's context fill, model and activity. `kit-init` asks (default: no); `/hud band|pane|off|quiet` switches it. Host meters work on Linux and WSL only.
- **New: `HOW-IT-WORKS.md`** (and a self-contained `docs/how-it-works.html`): one diagram of the whole loop, one short section per system, how to make it your own. `kit-init` offers it at the end.
- **Fixed: the `kit-init` HUD step** no longer says "nothing else was changed" when the install worked and the configure step failed; it says the plugin is installed with defaults and how to configure it.

## 0.7.1 — 2026-10-13

A bug fix and the first piece of the 0.8.0 catch-up, released early.

- **Fixed: `/orchestration-kit:orient --brief <ROW>` showed no seat banner on a live team.** The skill
  loader replaces positional tokens (`$0`, `$1`, …) inside skill bodies with the skill's own arguments,
  so the banner filter matched nothing and a new session concluded there was no seat. `orient` step 2 and
  `kit-init` no longer use positional tokens, an extras example uses a named placeholder, and
  `tests/skill-positional.test.sh` bans them in every loader-rendered file (rendering the real blocks
  with arguments, the way the loader does, then running them).
- **New, opt-in: context guard hook** (`hooks/ctx-guard.py`, PostToolUse + UserPromptSubmit). With
  `ctx_guard: on` in your team config (kit-init turns it on for a team start, off for solo) and the
  `docs/orchestration/.kit-hooks` marker, each session gets a `CONTEXT GUARD:` line as it nears its
  report and hand-over marks (`context_window: 1m|200k`). It reads the main checkout's config, so
  worktrees work, and it fails silent: it can never break a session.

## 0.7.0 — 2026-10-03

Recycling in place. A recycled session now restarts in the SAME terminal tab instead of opening a new
one. Ported from a project that has run this daily (its respawn wrapper, hand-off file, atomic revoke,
account writer, ancestor guard and the seat's detached self-recycle), generalized to the kit's backends and file layout.

### Recycle in the same tab

- **`scripts/sibling-shell.sh <Name> [--mode M] --model M [--effort E] [prompt]` (new):** the respawn
  loop a team tab runs. It starts `claude --name <Name> ...` as a child; when the child exits it looks
  for a hand-off file and, if `recycle-sibling.sh` left one, starts the next session in the same tab.
  No file = a plain `/exit`, and the tab closes as it always did. A crash-loop guard stops it when
  `claude` dies within 5 s twice in a row (a bad model id or a logged-out account), instead of
  respinning forever. The whole loop is parsed up front, so a plugin update that rewrites the file
  under a days-long wrapper cannot make bash resume in the middle of new text.
- **`recycle-sibling.sh` has two modes**, and `--dry-run` (or `DRY_RUN=1`) prints which one with a
  `mode:` line, and the final summary repeats it:
  - **in-place** when exactly one old `claude` exists and its parent is a `sibling-shell.sh` wrapper for
    the SAME name: write the hand-off file (model, effort, permission mode, account, and the prompt as
    one line of base64 so quotes, `;`, `$` and newlines survive), SIGTERM only the old `claude`, and
    wait for a fresh one that is a child of that very wrapper. No terminal is needed.
  - **new-tab** (the old behavior, now starting the wrapper) when there is no old process, the old one
    was started by hand, several match, `--new-tab` is passed, the seat recycles itself on a machine
    without `setsid` (or its Claude adopts orphaned processes, see below), or an in-place attempt times
    out after 60 s (`RECYCLE_INPLACE_TIMEOUT`).
- **The seat recycles itself in place too.** When the seat runs `recycle-sibling.sh` from its own shell,
  the session it targets is an ancestor of the script, and killing it in place would cut the script's own
  process chain. The script now prints a log path, re-runs a copy of itself detached (`setsid -f`, so it
  is outside the old session's process tree), and exits; the copy waits `RECYCLE_DETACH_DELAY` (2 s) so
  the seat's own command can finish and its transcript flush, then does the normal in-place hand-off. The
  copy keeps the seat's account and writes everything it prints to `<state dir>/<Name>.recycle.log`, the
  path printed first, so a failure after the old session ends is still diagnosable. A copy never detaches
  again; if it cannot get out of the old session's tree within `RECYCLE_DETACH_WAIT` (10 s, e.g. that
  session adopts orphans), it falls back to the new-tab path, which opens the tab before it ends the old
  session. A session not under the wrapper, or a machine with no `setsid` (macOS), uses the new tab as
  before, and `--dry-run` prints `detach: yes|no` beside `mode:`.
- **Safe by construction:** the hand-off is written to a temp file and moved into place; the wrapper
  claims it with an atomic `mv` and the recycler revokes an unclaimed one the same way, so exactly one
  of them wins (a plain `rm` would let a tab open after the wrapper had already started a session, and
  leave two sessions under one name). A same-name `claude` that is not a child of the wrapper never counts
  as the fresh one. A wrapper started for a different name is never taken for yours. The account is
  kept from the old session; the permission mode is NOT: a recycle uses the mode you give it with `--mode`,
  else the team block's `permission_mode:`, else normal, and writes that into the hand-off.
- **Every tab the kit opens now runs the wrapper** (`start-team.sh` and the recycle's new-tab path), on
  tmux, WSL, macOS, and Linux emulators, so a team started by the kit recycles in place from its first
  recycle. A session started by hand moves over at its next recycle. Git Bash (cmd.exe windows, no
  `pgrep`) and the `manual` backend keep a bare `claude`. `LAUNCH_NO_WRAPPER=1` turns it off.
- New env: `SIBLING_STATE_DIR` (hand-off dir, default `~/.orchestration-kit/sessions`),
  `RECYCLE_INPLACE_TIMEOUT`, `RECYCLE_CLAIMED_GRACE` (extra wait once the wrapper has claimed the
  hand-off, 30 s), `RECYCLE_POLL_SECS`, `RECYCLE_DETACH_DELAY` (2 s) and `RECYCLE_DETACH_WAIT` (10 s) for
  the seat's self-recycle, `LAUNCH_NO_PROC=1` (use `ps` instead of `/proc`; tests only).

### What is tested where

In-place recycling reads the process tree (`/proc`, else `ps`) and needs `pgrep`. The new suites run on
Linux (and WSL) and say SKIP elsewhere; the `ps` code path macOS would use is exercised by forcing it
(`LAUNCH_NO_PROC=1`), but it has **not been run on a real Mac or in Git Bash**. On WSL, a kit install path
containing a space cannot cross the `wt.exe` command line, so those tabs fall back to a bare `claude`.

### Tests

- `tests/sibling-shell.test.sh` (wrapper: argv order, hand-off relaunch and consumption, byte-exact
  prompt round trip, account per launch, permission mode, crash-loop guard incl. the no-`EPOCHREALTIME`
  clock, refusal of malformed hand-offs, bad arguments exit 64, survives being rewritten mid-run) and
  `tests/recycle-inplace.test.sh` (mode decision, end-to-end in-place, timeout fallback, decoy and
  wrong-name wrappers, the claimed-hand-off race, account inheritance, the self-recycle at depth 1 and 2,
  the `ps` parity path, the wrapper in every backend's tab command; plus the seat's real self-recycle
  with its account and delay, the old session adopting orphans, a slow launcher, no `setsid`, the
  no-detach-twice guard and a session not under the wrapper). Shared helpers in
  `tests/inplace-harness.sh`; every `claude` is a stub and cleanup kills only recorded pids. The test
  sandbox cannot reach a real terminal: it is pinned to non-WSL, non-tmux with `WT_EXE` pointing nowhere, and
  test R0 fails if auto-detect could resolve anything but the stub terminal.

## 0.6.0 — 2026-10-02

A model per lane, leaner builder starts, per-window context marks, and optional multi-account
teams. Ported from a project that ran the same package for a week (its launch flags, briefs,
lean orient and window-aware marks), generalized to the kit's backends and file layout.

### A model per lane

- **`--model M` and `--effort E` on `recycle-sibling.sh` and `start-team.sh`**, on every terminal
  backend (tmux, WSL, macOS, Git Bash/cmd.exe, Linux emulators), implemented once in `lib-launch.sh`
  (`launch_set_model`, `launch_model_flags`, `launch_resolve_model`). **A model is always passed
  explicitly**, so a fresh session never silently inherits whatever the old terminal or the account
  default happened to be; a recycle does not read the old session's model (its account, by contrast,
  is inherited on purpose). Default `opus[1m]`, configurable with `model:` / `effort:` in the
  `team:` block of `ORCHESTRATION.md`; flags override it. `--effort` is passed only when given.
  `--model` must look like `opus[1m]` / `sonnet[1m]` / `haiku` / a full model id and `--effort` is one
  of `low|medium|high|xhigh|max`; anything else exits 64 like `--account`, before anything launches.
  A bad value in the team block is ignored with a warning. `--dry-run` prints both.
  `start-team.sh --model` applies one model to the whole team; per-lane models go through recycle.
- **`skills/orchestrate` §3a, "Model per lane":** a lane table written by work type (heavy
  reasoning/verification → top tier, 1M; routine features/UI → mid tier, 1M; docs/mechanical → small
  tier, never writes facts), and the hybrid subagent policy (bounded jobs → subagents; long builds,
  every verification and user-facing work → sessions; subagents die with their parent). The recycle
  and seat-recycle commands in §9/§10 now carry `--model`.
- **`tests/lean-launch.test.sh`** (88 checks): default, explicit, `--flag=value`, six bad models and
  four bad efforts refused with exit 64, an `orient --brief <ROW>` prompt accepted on POSIX and WSL, no inheritance on recycle (a stand-in running on a different
  model), `start-team` reaching every window, all 16 backends and quoting families, team-block
  default/override/bad value. Mutation-checked: three mutants (default model not passed, validation
  off, model inherited on recycle) each turn it red.

### Leaner starts

- **`/orchestration-kit:orient --brief <ROW>`:** a lean mode for a builder assigned a row. It reads the
  row's brief file and the top of the board only, measures its fill, and sends READY. A full orient
  costs about 100K tokens of a fresh context; the brief already holds what the row needs.
- **READY now carries `model <id>` and `marks <prompt>/<handover>`** next to the fill, so the seat
  can see the lane got the model it asked for.
- **`templates/briefs/`:** `_TEMPLATE.md` (goal, numbered acceptance, fence, seam map, base, gate,
  model/effort, report protocol) and a README. Installed to `docs/orchestration/briefs/` by
  `bootstrap.sh` and kit-init. The seat commits and pushes the brief, then sends an assign message
  that only names the file. `orchestrate` §2 now points at it instead of an inline template.
- **Launch values are validated like input.** A model must start with a letter (`^[a-z][a-z0-9.-]*(\[1m\])?$`), so
  `--model --dangerously-skip-permissions`, `-x` and `.` are refused with exit 64 and never reach the
  `claude` command line, in both scripts and for `model:` / `effort:` in the team block (a bad block
  value now refuses to launch instead of warning and running the default). An empty or missing
  `--model` / `--effort` (`--model`, `--model ''`, `--model=`) is exit 64 too, tracked as "given" apart
  from "empty" so it cannot fall through to the block. `recycle-sibling.sh` refuses unknown flags, a
  `-`-led name or prompt, and a third positional.
- **Lean orient is runnable.** Step 1 is `git fetch` (one retry) then `git show origin/main:<brief>`,
  falling back to the working tree and then to the seat; step 2 extracts the current `ORCHESTRATOR
  ACTIVE` banner section only. READY names the seat and era the builder saw (`saw <seat [ref]> era-<N>`),
  and the brief template has a `seat` row. `tests/lean-orient.test.sh` extracts those commands from the
  skill and runs them against a bare origin, a stale clone and a live-shaped board.
- **Board, log and fact-writing lanes run on the mid model**, never the small one (the small model never
  writes facts). Nowhere does the kit tell a user to bare `/clear` to recycle: a bare `/clear` keeps the
  terminal's old model, so every fallback relaunches with an explicit `--model` (or `/model` first).
- **`templates/CLAUDE-slimness.md`:** why `CLAUDE.md` must stay slim (it is the startup floor, re-read
  every turn of every session) and how: rules in the file, narrative in a dated, linked archive;
  compress rationale, never the command, flag or guard. `CLAUDE-section.md` gains a short "Models"
  note and points at it. `bootstrap.sh` and kit-init install it to
  `docs/orchestration/CLAUDE-slimness.md`, the path the section names.

### Per-window context marks

- **`scripts/ctx-fill.py`:** `--window 1m|200k` (a token count still works). Marks: 1M window →
  350K/400K; **200K window → 120K/150K** (60%/75%; anything in between scales, capped at the 1M
  marks). A transcript naming a Haiku model proves a 200K window, the one model rule that can only
  lower it; Opus and Sonnet record the same string at 200K and 1M, so for them the window stays
  UNKNOWN, both sets of marks are printed, and the verdict is conditional until you pass `--window`.
- **The 200K marks moved from 140K/160K to 120K/150K** everywhere (ctx-fill, `statusline-ctx.sh`,
  the orchestrate table, CLAUDE-section, the ORCHESTRATION template, GETTING-STARTED, GLOSSARY,
  settings-snippets). Why: a seat on a ~200K window died at 175,725 tokens with no handover, so a 160K
  handover left too little room for the retro itself.
- **`tests/ctx-fill.test.sh`** (28 checks) and the extended statusline test (9) pin the marks. Mutation-checked:
  70%/80% marks, the Haiku rule off, and `--window` ignored each turn ctx-fill red.

### Multi-account (optional)

- **`docs/MULTI-ACCOUNT.md`:** run one team across several Claude Code accounts. Each account gets
  its own config dir via `CLAUDE_CONFIG_DIR` (`~/.claude-acctN` convention, a `claudeN` alias).
  Shared links for `sessions/` (the registry `ListAgents` reads, without which other-account
  sessions are invisible and unreachable), `projects/` (memories, transcripts, ctx-fill),
  `skills/` and `agents/`; `settings.json` is copied and `.credentials.json` is never shared.
  Covers the `ln -s`-into-an-existing-dir pitfall.
- **`--account N|DIR` on `recycle-sibling.sh` and `start-team.sh`.** A recycle with no flag
  inherits the old session's account from its process environment (`/proc/<pid>/environ`, or
  `ps eww` on macOS). Refused with exit 64: a missing dir, no login, or unsafe characters in the
  path. An optional `ACCOUNT` file labels the dir in dry-run and launch output. Implemented once
  in `lib-launch.sh` (`launch_set_account`, `launch_account_of_pid`, `_launch_env`) for every
  backend, including the cmd.exe `set VAR=...&&` form.
- **`tests/multi-account.test.sh`** (11 checks: default, explicit, inherit, override, three
  refusals, start-team). Mutation-checked: dropping inheritance turns it red.

## 0.5.0 — 2026-09-30

The public-release pass: an easier first path, one more guard, and the tests to back it.

- **Solo mode is the starting path.** README opens with a 5-minute "two terminals, one repo"
  quickstart; GETTING-STARTED §3 "Start small: solo mode" (board + cross-verification, no seat).
  Team mode (seat + siblings) is labeled Advanced. kit-init's "Not now" answer routes to solo.
- **Git guard hook (opt-in):** `hooks/git-guard.sh`, PreToolUse on Bash. With the `.kit-hooks`
  marker and `git_guard: on` in ORCHESTRATION.md it refuses `git stash` (except list/show),
  `git add -A` / `--all` / `.` / `:/` / `-u` without paths, `git commit -a` / `--all`, and
  `git pull --rebase`, with the reason and the safe command. Shell-style tokenizer in POSIX awk
  (quotes, comments, heredocs, `$(...)`, `bash -c`), so text that merely mentions these isn't
  blocked. **On by default in team mode, off in solo mode:** kit-init sets `git_guard: on` when
  it starts a team (seat + siblings) and `off` on "Not now"; the template default is `off`.
- **`falsify` skill:** mutation-prove a test or guard can fail — commit GREEN first, prediction
  written before the run, anchored + diff-verified mutant, red observed unfiltered, byte-clean
  restore, re-green; scoring and mutant-design tables. Stack-agnostic.
- **Context-fill statusline (optional):** `scripts/statusline-ctx.sh` shows the real fill against
  the 350K / 400K marks (70% / 80% under a 500K window); green / yellow "self-report" / red
  "hand over". Copied by kit-init and bootstrap; enable via `templates/settings-snippets.md`.
- **Tests:** `bash tests/run.sh` — git guard (55 command cases under every awk found + end-to-end
  opt-in gating), statusline (bands, 200K marks, overrides), bootstrap (dry-run touches nothing,
  second run is a no-op, live files never overwritten).
- **Ported from two never-published local releases** (their 0.4.0 / 0.4.1 numbers were reused
  above for other work): `docs/EXAMPLE-SESSION.md` (an annotated 12-hour seat + 3 siblings
  session, including the seat's six mistakes); LESSONS 42–60 (enumeration as deliverable,
  per-hit verdicts, restore = clean AND fix present, wrong-reason mutants, hedges, knobs over
  etiquette, train coupling, fail-open client guards …); verifier hardening (rebuild
  enumerations, reproduce mutants, authorized exceptions, count deltas, false signals, compile
  to prove "output unchanged", mirror assertions, delta re-verify); verify-feature's
  contract-items table; orchestrate brief rules, push verification and train coupling.
- **`LICENSE`** (MIT — plugin.json already declared it). **`docs/GLOSSARY.md`**.
- Leak sweep: internal row ids removed from lesson provenance. CHANGELOG is now newest-first.

## 0.4.5 — 2026-09-29

- **Cross-platform session launcher.** `lib-launch.sh` detects the OS and terminal and picks a
  backend: `tmux` (already inside tmux — first, even on WSL or a desktop), `wsl-wt` /
  `wsl-conhost` (Windows + WSL, unchanged), `tmux-detached` over SSH, `macos-iterm` /
  `macos-terminal` (osascript), `gitbash-cmd` (Git Bash: `cmd.exe /c start`), `linux-<emulator>`
  (`$TERMINAL`, x-terminal-emulator, gnome-terminal, konsole, xfce4-terminal, kitty, alacritty,
  wezterm, foot, xterm — each with its own "run this command" syntax), `tmux-detached` when
  headless, else `manual` (prints the per-window commands, exits 2 — the old non-WSL behavior).
- Override precedence: `--terminal <backend>` flag > `terminal:` in the ORCHESTRATION.md `team:`
  block (template default `auto`) > auto-detect. `--terminal list` prints every backend and
  whether it is available here. A forced backend that is not available refuses a real launch
  (exit 64); `--dry-run` still shows its command lines.
- Every backend runs the same `cd <repo> && [nvm] && claude --name <Name> [mode] <prompt>`;
  launch-first-then-SIGTERM and the `pgrep -f "^claude --name <Name>( |$)"` fresh-process wait
  are unchanged (the pattern is valid for BSD pgrep on macOS too). Without pgrep (Git Bash)
  launches are reported unverified and `recycle-sibling.sh` never kills the old session.
- One quoting function per backend family; the WSL no-`;`/`"`/`'` rule (and the no-spaces repo
  path rule) now applies to WSL only. `--dry-run` prints the backend, why it was chosen, and the
  exact command per session.
- `kit-init`: no new question — the setup summary says "Windows will open via: <backend>";
  on `manual` it shows the commands instead of launching.
- Docs: GETTING-STARTED covers Windows (WSL), macOS, Linux and SSH/headless/tmux; README
  "What's inside"; ORCHESTRATION template `terminal:` key; orchestrate recycle row; the stale
  `v0.4.0` in bootstrap-project's commit message is now `vX` (the installed version).
- GETTING-STARTED: SendMessage / ListAgents are built into Claude Code (nothing to install) —
  update first, a one-line "list the other Claude sessions" check, and the board-only fallback.

## 0.4.4 — 2026-09-29

- **Optional worktree enforcement.** New `worktrees: advised | enforced` key in the
  ORCHESTRATION.md `team:` block (default `advised` — today's behavior: every session is
  instructed to use its own worktree, nothing blocks it).
- New PreToolUse hook `hooks/worktree-guard.sh` (Edit|Write|MultiEdit|NotebookEdit): with
  `worktrees: enforced` and the `.kit-hooks` marker, denies edits whose target resolves inside the
  MAIN checkout (first `git worktree list` entry), with a reason telling Claude to create or use its
  own worktree. Always allowed: linked worktrees, `docs/orchestration/**`, the log and status doc
  (paths from ORCHESTRATION.md → Docs), anything outside the repo. Any parse error allows; no
  `set -e`; no network; two git calls.
- `kit-init` step 7 asks a third question in the same `AskUserQuestion` ("Separate worktrees per
  session?" — Advised (Recommended) / Enforced), persists it to the `team:` block, and the
  end-of-setup summary states which one is active.
- Docs: GETTING-STARTED "Worktrees: advised vs enforced" (incl. shared-tree workflows, how to
  switch); README hook row; CLAUDE-section (marker v0.4.4) and orient Step 0 note the rule is
  instructed by default, enforced only if the repo opted in.

## 0.4.3 — 2026-09-29

- No orientation doc? The seat (or `kit-init`, or a lone session) asks ONCE how to learn the project:
  search the repo, use an outline the human provides (path or paste), or both (outline checked
  against the repo — the repo wins on facts). The doc it then writes means the question never repeats.
  Siblings never ask; they flag it to the seat.

## 0.4.2 — 2026-09-29

- `kit-init` writes a real `AI_CONTEXT.md` by surveying the repo (README, CLAUDE.md, manifests,
  directory tree, git history, one gate run) plus one question to the human, and seeds the first
  build-log entry — no template left behind.
- `orient` bootstrap mode: if the status doc is missing or still a template, orient from the
  project itself; the seat (or a lone session) writes the doc, siblings flag it in READY instead.

## 0.4.1 — 2026-09-29

- Per-repo by default: install docs now use `claude plugin install … --scope project`
  (or `--scope local`), so the kit is active only in the repos it's installed into.
- The SessionStart hook is opt-in per repo: it runs only where `docs/orchestration/.kit-hooks`
  exists (written by `kit-init`). A repo with its own board but no marker is never nudged.

## 0.4.0 — 2026-09-29

The seat + siblings upgrade: everything a single-session user needs to run one orchestrator
and 2+ builder sessions on one repo (Windows + WSL first-class).

- **`orchestrate` rewritten** (≤200 lines): seat banner + handover block, single-allocator
  table, row brief template (briefs by message, board = status), DAG with disjoint fences,
  READY-signal rosters (`ListAgents` = liveness only), hand-off verification by a SIBLING
  SESSION (no self-reads, no mutual pairs, report to the seat, DERIVED vs
  CONSISTENCY-CHECKED), a recommended never-builds validator seat, one-at-a-time reconcile
  with push-merges-immediately, wave-train deploys via ORCHESTRATION.md's vehicle, LOG slot,
  sibling lifecycle via `recycle-sibling.sh`, seat context self-check (350K/400K on 1M
  windows; 70%/80% on 200K), all human approvals routed through the seat.
- **Zero-setup team:** `start-team.sh` opens the seat (`Orca`, `/orchestration-kit:orchestrate`)
  and N siblings (`Sib1`.., `/orchestration-kit:orient`) each in its own window; skips names
  already running; names/count from flags > the overlay's optional `team:` block > defaults;
  `--dry-run`. Shares `lib-launch.sh` with `recycle-sibling.sh` so the two cannot drift.
- **Plugin-shipped SessionStart hook** (`hooks/hooks.json`, startup|clear): tells a fresh
  session to run `/orchestration-kit:orient` and send READY to an active seat; silent no-op
  (exit 0, no output) in repos without `docs/orchestration/AGENT_BOARD.md`. The v0.3.0
  settings-snippet hook is retired (remove it if you copied it).
- **Namespaced skill names everywhere** (`/orchestration-kit:<skill>`) — launch prompts, docs
  and cross-references use the form that resolves for a plugin install.
- **Institutional-memory scaffolding:** kit-init/bootstrap create `docs/AI_CONTEXT.md` and
  `docs/timeline/build-log.md` from templates if absent (paths in ORCHESTRATION.md → Docs);
  orient reads them; retro/orchestrate append to the log with Edit, never Write; lessons go to
  Claude Code's auto-memory (never generated by the kit).
- **New scripts** (kit-init + bootstrap copy them into `scripts/`, never overwriting):
  `ctx-fill.py` — real context fill from the transcript's usage block, refuses to guess the
  session, `--window` scaling; `recycle-sibling.sh` — launch-first-then-SIGTERM on
  Windows+WSL, auto-detects distro / main checkout / wt.exe, conhost fallback when Windows
  Terminal is absent, `--dry-run`, exits 2 with manual instructions elsewhere.
- **orient:** Step 0 gains fetch+rebase (not `pull --rebase`), gate-from-own-worktree,
  archive grep, approvals-via-seat; Step 7 READY signal format.
- **board:** shared-checkout write recipe (HEAD guard, `git diff HEAD --quiet`, add+commit
  as one command, immediate push), status-not-narrative, verbatim dated archives past ~60 KB.
- **reconcile / retro / kit-init / bootstrap:** HEAD guard + push merges immediately;
  "retro complete · fill" reply to the seat; scripts copied idempotently.
- **Templates:** AGENT_BOARD gains archive table, banner, roster, READY and handover shapes;
  ORCHESTRATION gains run-from, deploy-vehicle-for-trains, session names/marks, validator
  seat; CLAUDE-section v0.4.0 non-negotiables + context lifecycle.
- **docs/GETTING-STARTED.md** (new): install (2 commands) → one CMD window → `wsl` → `claude`
  → `/orchestration-kit:kit-init` → `bash scripts/start-team.sh`; "what you get" table;
  manual `--name` launches under Advanced. **LESSONS 28–41.**
- **Team launch from setup:** kit-init ends with ONE `AskUserQuestion` (start the team now —
  seat + 2 siblings / choose how many / not now; permission mode — Normal / Auto / Accept
  edits), then runs `start-team.sh` itself only on a yes (the Bash prompt is the final OK).
- **Permission modes:** `start-team.sh` and `recycle-sibling.sh` take
  `--mode normal|accept-edits|auto` → no flag / `--permission-mode acceptEdits` /
  `--permission-mode auto`. `start-team --mode` saves `permission_mode:` in the `team:` block;
  recycles reuse it (the seat's too). Dry-run prints the exact `claude` command per session.
  A permission-bypassing mode is deliberately not offered by the scripts.
- **"Change it any time — just ask Claude"** lines in kit-init's question and summary, both
  script headers, the ORCHESTRATION team block, and a GETTING-STARTED "Changing things later"
  section with example asks.
- **Memory starter scrubbed:** 6 personal-preference memories dropped (session style, UI-mockup
  habit, deploy cadence, blanket approval, branch/push policy, link formatting); the other 25
  genericized (no project names, tools, people or channels); INDEX rewritten.
- `recycle-sibling.sh` defaults the seat's prompt to `/orchestration-kit:orchestrate` when the
  name is the configured seat.
- Version note: `0.3.0` was already tagged, so this release is `0.4.0`.

## 0.3.0 — 2026-08-21

The orchestrated-autonomy port (from the origin project's pilot, 2026-08-20/21) + the
`bootstrap-project` super-init. New: orchestrate, bootstrap-project (+ scripts/bootstrap.sh,
idempotent + --dry-run), post-feature, generic team-agent templates (optional,
install-only-if-missing, user-level precedence), agnostic memory starter (31: 30 ratified + 1 canonical merge,
trust grants excluded), extras/backfill, settings-snippets template (SessionStart hook +
auto-compact off, one approval step), LESSONS 16–27. Refreshed: orient, reconcile, retro,
verify-feature, board, CLAUDE-section (v0.3.0 marker), verifier (model-pinned;
bypassPermissions demoted to an opt-in comment — trust grants never ship as defaults).

## 0.2.0 — 2026-08-08

- New skill: `retro` — the write-back half of `orient` (board close-out, lesson
  distillation with upstream-to-kit propagation, status-doc refresh, clean-handoff
  check). Without it, LESSONS.md had no trigger to accrete — the upgrade payload
  only grows if session-end prompts the write. (the maintainer's observation, night one.)

## 0.1.0 — 2026-08-08

Initial release, extracted from the origin project's multi-session workflow
(the 2026-08-08 three-session evening: ~15 workstreams, zero collisions).

- Board template + claim protocol (fences, statuses, committed edits, session tags).
- Project overlay model (`ORCHESTRATION.md`: gate, change classes, deploy, locked, hazards).
- Skills: kit-init, board, verify-feature, reconcile, orient.
- Agent: `verifier` (contract-only, read-only, four checks, structured verdict).
- LESSONS.md v1: 15 incident-backed rules, including the two added the night of
  extraction — never `git stash` in worktree agents (shared stash refs), and
  exclusive DEPLOY-row claims.
