# Getting started — a seat + siblings, with a Solo practice mode

For someone who today opens a terminal and runs `claude` in one repo — on **Windows (WSL),
macOS or Linux**. Two paths, in this order:

1. **Team mode (default)** — one **seat** (an orchestrator session you talk to) plans, assigns,
   verifies and merges for two or more **siblings** (builders), each in its own window.
   ([§3](#3-team-mode--who-does-what-the-default))
2. **Practice mode (Solo)** — you play the orchestrator by hand with two sibling terminals, to learn how
   siblings claim rows, build in worktrees and verify each other. ([§4](#4-practice-mode-solo-be-the-orchestrator-yourself))

New words (seat, sibling, row, fence, gate …) are defined in [`GLOSSARY.md`](GLOSSARY.md).
Want the big picture first? [`HOW-IT-WORKS.md`](../HOW-IT-WORKS.md) explains the whole loop in one diagram (`kit-init` offers it at the end of setup).

## 0. What you need

- **Windows (WSL), macOS or Linux**, with Claude Code installed (`claude --version` works in
  your terminal; on Windows, inside WSL).
- A git repo (e.g. `~/projects/myapp`) with a remote you can push to.
- The launch script picks how to open windows on your machine — see the per-OS notes below.
- **A recent Claude Code** — run `claude update` first. The seat and siblings talk to each other
  with Claude Code's **built-in** SendMessage / ListAgents tools (nothing to install); they are
  newer features, so an old version may not have them. **Tested on Claude Code 2.1.296.** The kit
  relies on: cross-session SendMessage / ListAgents, plugin skills that run a command before the
  skill text loads (`/orchestration-kit:orient-brief`), and hooks that add context
  (PostToolUse / UserPromptSubmit, for the context guard).
- **python3** (context measurement and the context guard) and **flock** (the gate throttle; on
  macOS `brew install flock`; without it the throttle warns and runs your gate unthrottled).

### Windows (WSL)

You open **CMD**, type `wsl`, and run `claude` inside WSL. Claude Code must be installed
**inside WSL** (`claude --version` works after `wsl`). Keep the repo in the Linux filesystem
(`~/…`), not under `/mnt/c/…`, and with no spaces in its path — git and worktrees are much
faster there, and the Windows launcher requires it. Windows open in **Windows Terminal** if you
have it, else in plain console windows.

Git Bash without WSL also works, less well: windows open as `cmd.exe` consoles, but Git Bash
has no `pgrep`, so the scripts can't see which sessions are running — recycling opens the fresh
window and asks you to close the old one yourself.

### macOS

Use Terminal or iTerm2. Windows open in **iTerm2** when you run the setup from iTerm2 (or it's
running), else in **Terminal**. The first time, macOS asks whether your terminal may control
Terminal/iTerm2 ("automation" permission) — allow it, or no windows appear.

### Linux

On a desktop session, windows open in your terminal emulator: `$TERMINAL` if you set it, else
the first one found of x-terminal-emulator, gnome-terminal, konsole, xfce4-terminal, kitty,
alacritty, wezterm, foot, xterm.

### Over SSH, headless, or already in tmux

If you run the setup **inside tmux**, each session opens as a new tmux window (on any OS). Over
**SSH** or on a machine with no desktop, the sessions open in a detached tmux session named
after the repo — attach with `tmux attach -t <repo-name>` (the script prints the exact
command). No tmux installed → the script prints one command per window for you to run.

To see what your machine supports: `bash scripts/start-team.sh --terminal list`. To pick one
yourself, ask Claude ("open the team in tmux"), set `terminal:` in the `team:` block of
`docs/orchestration/ORCHESTRATION.md`, or pass `--terminal <backend>`.

## 1. Install the plugin (once)

In a terminal (on Windows: a WSL terminal), **from inside the repo you want to use it in**
(type these at the normal `$` prompt, not inside Claude):

```bash
cd ~/projects/myapp
claude plugin marketplace add Artekka/orcastration-kit
claude plugin install orchestration-kit@artekka-kits --scope project
```

`--scope project` turns the kit on for **this repo only** — your other projects are
untouched. (Use `--scope local` instead if you don't want the setting committed for
collaborators.) Repeat the `install` line inside any other repo you want it in.
Already inside Claude? The same commands work as `/plugin marketplace add …` and
`/plugin install …`; restart Claude afterwards.

## 2. Set up your repo (once per repo)

Open **one** terminal in the repo and start Claude. On Windows, that's one CMD window:

```
wsl
cd ~/projects/myapp
claude
```

On macOS or Linux: `cd ~/projects/myapp && claude`.

In that Claude session run:

```
/orchestration-kit:kit-init
```

It creates the board, your project settings, the status doc and log, and the launch scripts,
and asks you a few questions:

| It asks | Example answer |
|---|---|
| Gate command + the line that proves it passed | `npm test` → `Tests: 42 passed, 0 failed` |
| Deploy command (or "none") | `npm run deploy` |
| A validator (optional) | "none" for now |
| Locked files (optional) | `src/pricing.ts` |

Last, it asks **three questions** — whether to start the team now (and how many siblings),
which permission mode the sessions should use, and whether separate worktrees per session are
advised or enforced. The git guard (below) follows your first answer: **on** if you start a
team, **off** in practice (Solo) mode.

**Team mode (default):** answer with a team size ("Seat + 2 siblings"), approve the one command it runs,
and the windows open: **Orca** (the seat) and **Sib1**, **Sib2** (siblings). The setup summary
says how they open on your machine ("Windows will open via: …"). You can close the setup session; continue at [§3](#3-team-mode--who-does-what-the-default).

**Practice mode (Solo):** answer **Practice mode (Solo)** to learn the loop by hand first (nothing is started),
pick the other two, and continue at [§4](#4-practice-mode-solo-be-the-orchestrator-yourself).

**Start with 1 seat + 2 siblings.** You can change the team size, names, permission mode or worktree setting at
any time — just ask Claude to change it.

**Permission modes** (saved in `docs/orchestration/ORCHESTRATION.md`, so recycled sessions reopen the same way):

- **Normal** (recommended) — each session asks you before risky actions, in its own window.
  Safest while you learn the workflow.
- **Auto** (`--permission-mode auto`) — Claude Code's automatic permission checks decide most
  actions instead of prompting you, so the team runs with fewer interruptions.
- **Accept edits** (`--permission-mode acceptEdits`) — file edits are approved automatically;
  commands still ask.

Change it later by asking Claude ("switch the team to normal permissions"), by editing
`permission_mode:` in the `team:` block, or with `bash scripts/start-team.sh --mode auto`.
It applies to sessions opened from then on.

**Worktrees: advised vs enforced** (saved as `worktrees:` in the same `team:` block). Either way,
every session is instructed to work in its own git worktree, so two sessions never edit the same
checkout at once.

- **Advised** (recommended) — the instruction only; nothing blocks an edit. Pick this if your
  workflow deliberately shares one tree or file between agents (pairing two sessions on one
  branch, a helper agent writing into the tree another session owns, one-person repos), or while
  you learn the workflow.
- **Enforced** — a hook blocks file edits in the main checkout, so a session that forgot to
  create its worktree is stopped and told how. The board, the log and the status doc stay
  editable in place (they are committed within seconds by design), as does anything outside the
  repo. Pick this once several sessions run at the same time and a stray edit on main has cost
  you work.

Switch any time by asking Claude ("enforce worktrees", "make worktrees advised again"), or by
editing `worktrees:` in `docs/orchestration/ORCHESTRATION.md`. It takes effect on the next edit.

**Git guard: on in team mode, off in practice (Solo) mode** (saved as `git_guard:` in the same `team:`
block; kit-init sets it from your start answer). Four git habits that
are harmless alone damage other sessions' work in a shared repo:

| Blocked when on | Why | Claude is told to use |
|---|---|---|
| `git stash` (except `list` / `show`) | Stashes are shared by every worktree; a pop can take another session's work | commit WIP on its branch, or copy to a scratch dir |
| `git add -A` / `--all` / `.` / `-u` with no paths | Stages other sessions' uncommitted files | `git add <explicit paths>` |
| `git commit -a` / `--all` | Same, at commit time | `git add <paths> && git commit` |
| `git pull --rebase` | Races on the shared `.git/FETCH_HEAD` | `git fetch origin && git rebase origin/main` |

It only reads Claude's Bash commands (quoted text and commit messages that merely *mention* these
are fine); you can still run anything yourself in your own terminal. Change it with "turn on the
git guard" / "turn off the git guard", or `git_guard: on|off`.

Chose Practice mode (Solo), or want to reopen missing windows? Run `bash scripts/start-team.sh` (or ask
Claude to). Sessions already running are skipped; `--dry-run` previews without opening anything.

## 3. Team mode — who does what (the default)

| Seat (Orca) | Siblings (Sib1, Sib2, …) |
|---|---|
| Talks to **you**. Give it tasks in plain language | Talk to the seat, not to you |
| Turns tasks into board rows, each with a file "fence" | Build one row at a time in their **own git worktree** |
| Assigns rows so fences never overlap | Report at milestones: claimed → failing test → passing → done |
| Picks a **different** sibling to verify each finished row | Verify each other's rows when asked (never their own) |
| Merges rows onto main **one at a time**, runs the gate | Never merge to main, never deploy |
| Deploys in batches ("wave trains"; `assemble-train` builds one, a validator runs `audit-train` on it), keeps the log | Send any question or permission prompt to the seat |
| Asks you for decisions and approvals — all in its window | — |

Your job: talk to the seat window. You can ignore the sibling windows — if a sibling needs
you, the seat says so.

**Deploys:** by default (`deploy_policy: ask` in the Deploy block of `ORCHESTRATION.md`) the seat asks you before
every deploy. Say "deploy on your own when green" to switch to `auto-when-green`: a train whose rows all passed
their independent check and whose gate is green ships without a question, and the seat tells you what shipped.
**Questions:** with `questions: non-blocking` the seat asks in plain text, keeps everything else moving and
re-asks when you next type; the default `blocking` waits at the prompt. **Session cap:** `max_sessions` in the
team block warns before a launch would pass the number of sessions your machine can carry.

**Check the sessions can hear each other** (once, after the windows open): in the seat window ask
*"list the other Claude sessions"*. If it names Sib1, Sib2 … messaging works. If it doesn't,
run `claude update` in each window and restart the team. Even without messaging the workflow
still runs — the board file (`docs/orchestration/AGENT_BOARD.md`) is the guaranteed channel:
siblings post `AVAILABLE` / status lines there and the seat reads it. It's just slower, because
nobody gets pinged.

## 4. Practice mode (Solo): be the orchestrator yourself

A practice ground for learning the loop by hand. Here **you** sit in the seat's chair, by hand, with two sibling
terminals, so you learn how siblings claim rows, build in worktrees and verify each other before you trust a seat to
do it. The board and independent verification are most of the value; the seat automates the coordinating you do here.
Choose **Practice mode (Solo)** in `kit-init` (it starts nothing; the git and context guards stay off), then:

```bash
# Terminal 1 = sibling Dev1 (on Windows: `wsl` first)
cd ~/projects/myapp && claude --name Dev1 /orchestration-kit:orient
# Terminal 2 = sibling Dev2
cd ~/projects/myapp && claude --name Dev2 /orchestration-kit:orient
```

**Guided demo — you play the seat.** Type these yourself; each line is something a seat would do:

| Step | Where | You say | What happens |
|---|---|---|---|
| 1. File two rows | Dev1 | "add rows to the board for: fix the login timeout; add CSV export" | Rows `Dev1-1`, `Dev1-2` appear on `docs/orchestration/AGENT_BOARD.md`, committed + pushed |
| 2. Hand one to each | Dev1 | "claim Dev1-1 and build it in your own worktree" | Claims the row (with a file fence), works on its own branch |
| | Dev2 | "claim Dev1-2 and build it in your own worktree" | Same, with a fence that doesn't overlap |
| 3. Cross-verify | Dev2 (when Dev1 is done) | "verify Dev1-1 against its row — contract only, don't fix anything" | Dev2 never saw Dev1's reasoning, so it checks the work against the row, not the author's intent. Or run `/orchestration-kit:verify-feature` |
| | Dev1 (when Dev2 is done) | "verify Dev1-2 against its row — contract only" | The mirror image: each row is checked by the session that did NOT build it |
| 4. Merge | Dev1 (after PASS) | "/orchestration-kit:reconcile Dev1-1" | Lands the branch on main, re-runs your gate, closes the row. Do the other row the same way, one at a time |

**Why the demo has a mutual pair:** with only two sessions, Dev1 and Dev2 must read each other's row. In team mode the seat avoids that (A reads B, so B does not read A: reciprocity is a bias) by using a third sibling or the verifier subagent for the other row.

Rules that make this safe (the sessions already know them): each session edits in its own git
worktree, stages explicit paths, never stashes, and verifies the *other* session's rows, never
its own. When a session's context fills, run `/orchestration-kit:retro` in it, then relaunch it
with `claude --name <Name> --model <model> /orchestration-kit:orient` (a bare `/clear` keeps the terminal's old model).

**Ready to graduate?** Move to team mode when you are the bottleneck: relaying between windows,
deciding who takes what. Say "turn on the git guard" (team mode's default), then
`bash scripts/start-team.sh` opens a seat + siblings; [§3](#3-team-mode--who-does-what-the-default) covers it.

## 5. What you get

| Piece | What it is |
|---|---|
| `/orchestration-kit:orchestrate` | The seat's loop — plans, assigns, verifies, merges, deploys, recycles |
| `/orchestration-kit:orient` | A fresh session catches up and tells the seat it's READY |
| `/orchestration-kit:board` | Claiming, updating and archiving board rows |
| `/orchestration-kit:orient-brief` | Lean start for a builder: the row's brief and the seat banner arrive already loaded (`/orchestration-kit:orient-brief <ROW>`) |
| `/orchestration-kit:assemble-train` · `/orchestration-kit:audit-train` | Team mode: land approved rows onto a train branch one merge at a time with a dry run · a validator checks the finished train before it ships |
| Status HUD (optional plugin) | A band above the prompt showing every session's context fill, model and activity. `kit-init` asks once (default: no); `/hud band`, `/hud pane`, `/hud off`, `/hud quiet` switch it. Host load meters work on Linux and WSL only |
| `/orchestration-kit:falsify` | Prove a new test or guard can actually fail (mutation check) before trusting it |
| `/orchestration-kit:reconcile` | Merging one finished worktree onto main and re-running the gate |
| `/orchestration-kit:retro` | Closing a session: lessons saved, board updated, work committed |
| `/orchestration-kit:verify-feature` | Subagent verification — fallback when no sibling is free to verify |
| `/orchestration-kit:post-feature` · `/orchestration-kit:kit-init` · `/orchestration-kit:bootstrap-project` | Per-feature checklist · repo setup · new-project setup |
| SessionStart hook (automatic) | Every fresh session in a repo with a board is told to orient and report to the seat. Silent in other repos |
| Worktree guard (PreToolUse hook) | Only with `worktrees: enforced`: blocks edits in the main checkout except board/log/status files. Silent otherwise |
| Git guard (PreToolUse hook on Bash) | Only with `git_guard: on`: refuses `git stash`, `git add -A` / `.`, `git commit -a`, `git pull --rebase` and tells Claude the safe command. Silent otherwise |
| `docs/orchestration/AGENT_BOARD.md` | The shared board: who is doing what, and which files they own |
| `docs/orchestration/ORCHESTRATION.md` | Your project's settings: gate, deploy, team names, doc paths |
| `docs/AI_CONTEXT.md` · `docs/timeline/build-log.md` | Status doc (read first by every session) · append-only history |
| `scripts/start-team.sh` · `scripts/recycle-sibling.sh` · `scripts/ctx-fill.py` | Open the team · replace a full session · measure a session's context |
| Memory | Automatic: Claude Code keeps per-project memory under `~/.claude/projects/…/memory/`; `retro` saves lessons there |

**What the WORK/QUIET chip does and when you'll see it:** The chip is a switch for the kit's quiet mode. QUIET holds every NEW test/gate run started through `scripts/gate-throttle.sh` while you use the machine yourself; runs already going finish, and WORK lets new ones start normally. It only helps if your team runs its gate through that throttle, so the chip appears only when `scripts/quiet-mode.sh` exists in the session's directory (or quiet mode is already on). No throttle, no chip. If a press fails, the chip turns red and says `failed` for a minute, and the toast says why. `/hud help` repeats this, and `quietModeRequiresFile` changes the file it looks for (empty always shows the chip).

## 6. Recycling when a session fills up

Long sessions degrade as their context fills. The kit replaces them cleanly instead of `/compact`.

1. Each session measures itself with `python3 scripts/ctx-fill.py`. On a 1M-token model it
   self-reports around **350K** and hands over by **400K** (200K model: ~120K / ~150K; tell it which with `--window 1m|200k`).
   Optional: show it permanently in the status bar — add
   `"statusLine": { "type": "command", "command": "bash scripts/statusline-ctx.sh" }` to
   `.claude/settings.json` (or ask Claude: "add the context statusline"). It turns yellow at the
   self-report mark and red at handover.
2. The seat tells that sibling to retro. The sibling saves lessons, updates the board,
   commits, and replies **"retro complete"**.
3. The seat runs `bash scripts/recycle-sibling.sh Sib1 --model 'sonnet[1m]'` (the model for
   that lane; see "Model per lane" below): the fresh session starts **in the same tab**, because every
   tab the kit opens runs a small respawn wrapper (`scripts/sibling-shell.sh`). A session you
   started by hand has no wrapper, so its first recycle opens a **new window** (the way
   `start-team.sh` does on your machine: Windows Terminal, Terminal/iTerm2, your Linux emulator or a
   tmux window) running one, and closes the old one only after the fresh one is up. `--dry-run`
   prints `mode: in-place` or `mode: new-tab`; `--new-tab` forces the new window.
4. The seat recycles itself the same way after writing a handover note on the board. If the
   script can't run, the seat asks you to close that window and relaunch it with
   `claude --name <Name> --model <model> /orchestration-kit:orient` (siblings) or
   `claude --name <SeatName> --model 'opus[1m]' /orchestration-kit:orchestrate` (seat). A bare `/clear`
   keeps the terminal's OLD model; if you do `/clear`, run `/model <model>` first.

### Model per lane

Not every row needs your strongest model, and a fresh session must never start on whatever model the
old terminal happened to have. The seat picks a model **by work type** when it launches a session:

| Work | Model |
|---|---|
| Heavy reasoning and verification (core logic, migrations, security, money, every READ of those), the seat, the validator | `opus[1m]` |
| Routine features, UI, plumbing, test-only fixes | `sonnet[1m]` |
| Board and log entries, write-ups, anything stating SHAs, counts or verdicts | `sonnet[1m]` (facts need a model that doesn't fabricate) |
| Copy changes, mechanical sweeps, searches that only locate code | `haiku` (the small model never writes facts) |

`scripts/recycle-sibling.sh <Name> --model <m> [--effort <e>]` and `scripts/start-team.sh --model <m>`
always pass the model explicitly. Change the default for every launch with `model:` in the team block
of `docs/orchestration/ORCHESTRATION.md`. A bad value exits 64 before anything launches; `--dry-run`
prints the model and effort. Bounded one-off jobs (a search, a mechanical sweep) can be subagents; long
builds and every verification are sessions. Details: the orchestrate skill, "Model per lane".

### Lean start for a builder

The seat writes a **brief file** per row (`docs/orchestration/briefs/<ROW>.md`, from
`templates/briefs/_TEMPLATE.md`) and the builder starts with `/orchestration-kit:orient-brief <ROW>`
(the brief and the board banner arrive already injected into the skill text, so there is nothing to read first):
the brief + the board banner, then READY. A full orient reads a whole project to learn one row; the
brief is the row. Keep `CLAUDE.md` slim too (`docs/orchestration/CLAUDE-slimness.md`): it is re-read on every
turn of every session.

## 7. Common failure modes

| Symptom | Cause → fix |
|---|---|
| Siblings sit idle; the seat says nobody is ready | Siblings end orientation with a READY message. Tell the sibling: "send READY to the seat" |
| No new windows appear | Run `bash scripts/start-team.sh --dry-run` to see which terminal it picked and why; `--terminal list` shows the alternatives. On macOS, allow the "automation" prompt. Over SSH / tmux-detached: `tmux attach -t <repo-name>`. Still nothing → see Advanced, open them by hand |
| Sessions keep asking for permission | That's Normal mode. Ask Claude to "switch the team to auto permissions", or say yes in each window |
| `start-team.sh` exits 2 | It found no terminal it can open windows in (no WSL, tmux, macOS, desktop emulator). It prints the `claude --name …` command for each window — run them by hand, or install tmux |
| `Cannot rebase onto multiple branches` | Someone used `git pull --rebase`. Use `git fetch origin && git rebase origin/main` |
| `cannot lock ref 'refs/remotes/origin/main'` | Two sessions fetched at once. Harmless — run it again |
| Your edit shows up inside someone else's commit | Someone ran `git add -A` or edited outside a worktree. Stage explicit paths only |
| Work disappeared after `git stash pop` | Stashes are shared between worktrees. Never stash; commit instead |
| Tests green in a sibling, red on main | The gate ran from the wrong folder. Run it from inside your own worktree |
| A session gets vague or repeats itself | Context is full. Measure with `ctx-fill.py`; retro and recycle. Turn on the context guard (`ctx_guard: on`) so sessions are told for you |
| "SendMessage / ListAgents is not available" | They are deferred tools: load them first with ToolSearch (`select:ListAgents,SendMessage`). Still missing → `claude update` |
| A message fails with "N agents are named X" | `ListAgents` shows several sessions with that name (old ones linger in the list). Resend to `X [ref]`, the ref from the listing |
| `orient-brief` prints `NO BANNER` | No live `ORCHESTRATOR ACTIVE` section on the pushed board (only superseded ones, or the seat never pushed). Ask the seat to push its banner |
| `orient-brief` prints `NO BRIEF` | The brief is neither on origin nor in this checkout. The seat must commit + push `docs/orchestration/briefs/<ROW>.md` before assigning |
| `recycle-sibling.sh` exits 3 | The old session still has live shells (a background gate, a loop); a recycle would kill or orphan them. Wait, or have that session stop them; `--force` only if they are disposable. An idle session refused over a shell that is gone a moment later: set `LAUNCH_LIVE_RECHECK=3` (the guide's "If a recycle is refused" explains the two-look check) |
| A recycle opened a new tab instead of reusing the old one | The old session was started by hand (not under `sibling-shell.sh`), or no `setsid` (macOS) for a seat self-recycle, or Git Bash. It moves over at its next recycle |
| Gates never start | Quiet mode is on (`bash scripts/quiet-mode.sh status`), the load is above `GATE_MAX_LOAD`, available memory is below `GATE_MIN_FREE_MB` while one gate already runs, or all `gate_slots` are busy (status lists who) |
| The hooks do nothing | They are opt-in: the repo needs `docs/orchestration/.kit-hooks`, plus `git_guard: on` / `ctx_guard: on` / `worktrees: enforced` for each guard |

## 8. Changing things later

Nothing here is fixed. Ask Claude — in the seat's window, or any Claude session in the repo —
and it will make the change for you. For example:

| You say | What changes |
|---|---|
| "make it 3 siblings" | `siblings:` in the `team:` block; `start-team.sh` opens Sib3 |
| "switch the team to normal permissions" | `permission_mode:` in the `team:` block; applies to sessions opened from then on |
| "open the team in tmux" / "use iTerm" | `terminal:` in the `team:` block (`tmux`, `tmux-detached`, `macos-iterm`, … or `auto`) |
| "enforce worktrees" / "make worktrees advised" | `worktrees:` in the `team:` block; takes effect on the next edit |
| "turn on the git guard" / "turn off the git guard" | `git_guard:` in the `team:` block; takes effect on the next command |
| "rename the siblings to Worker1…" | `prefix:` in the `team:` block (then recycle the old windows) |
| "deploy on your own when the train is green" / "ask me before deploying" | `deploy_policy: auto-when-green` / `ask` in the Deploy section of `ORCHESTRATION.md` |
| "ask me questions without blocking" / "go back to blocking questions" | `questions: non-blocking` / `blocking` in `ORCHESTRATION.md` |
| "cap the team at 6 sessions" | `max_sessions: 6` in the `team:` block |
| "install the status HUD" / "turn the HUD off" | `claude plugin install status-hud@artekka-kits`, then `/hud off` to hide it |
| "our tests run with `make check` now" | the Gate section of `docs/orchestration/ORCHESTRATION.md` |
| "deploy with `npm run release`" | the Deploy section of `ORCHESTRATION.md` |
| "add a column for reviewer to the board" | `docs/orchestration/AGENT_BOARD.md` layout |
| "make orient also read docs/ARCHITECTURE.md" | a project-level copy of the skill in `.claude/skills/` |

## 9. Advanced / customize

- **Other names, sizes or modes:** `bash scripts/start-team.sh --seat Lead --prefix Dev --siblings 3 --mode auto`,
  or set them once in the `team:` block of `docs/orchestration/ORCHESTRATION.md`.
- **Opening a session by hand** (no automatic windows, e.g. native Windows without WSL): one terminal per session,
  in the repo:
  ```
  claude --name Orca --model 'opus[1m]' /orchestration-kit:orchestrate    # add --permission-mode auto etc. after the name
  claude --name Sib1 --model 'sonnet[1m]' /orchestration-kit:orient
  claude --name Sib2 --model 'sonnet[1m]' /orchestration-kit:orient
  ```
  Always pass `--model` (the lane's model, "Model per lane" above): a session started without it runs on
  whatever the account default is, and a bare `/clear` in an old terminal keeps that terminal's model, so relaunch with `--model`.
  `--name` (long form, first) is required: sessions message each other by that name, and the
  scripts find a running session by matching `claude --name <Name>`. Keep names one word.
- **A dedicated validator:** add a sibling that only verifies and never builds, and name it
  in ORCHESTRATION.md → Validator seat. It is independent of every row by construction.
- **Upgrading the plugin:** ask Claude "update the kit" (`/orchestration-kit:kit-update`), or by hand
  `claude plugin marketplace update artekka-kits`, then
  `claude plugin update orchestration-kit@artekka-kits`, restart sessions, and re-run
  `/orchestration-kit:kit-init` (it only adds what's missing). kit-init never overwrites a project's copied
  session scripts; `scripts/kit-update.sh projects` lists the older ones and `refresh <project>` replaces them.
- Further reading: `skills/orchestrate/SKILL.md` (the seat's loop) and `docs/LESSONS.md`
  (why each rule exists).
