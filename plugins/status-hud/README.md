# Status HUD

A Claude Code mod that shows, pixel-style in the terminal, what every session is doing and how loaded the machine is.
It is project-agnostic: it knows nothing about any repo until you configure it.

It ships with the orchestration kit as an **optional** component: `/orchestration-kit:kit-init` asks whether to install it (default No), and you can add or remove it any time — just ask Claude.
This copy was renamed from the upstream HUD's `gameMode*` keys to `quietMode*` (and its slash command to `/hud quiet`) to match the kit's quiet mode; an install configured with the old keys must be reconfigured.

Two looks, one setting (`variant`):

- **band**: a framed band of up to 10 rows above the prompt. Host meters on the left, one row per session on the right, mode chips along the bottom.
- **pane**: a side pane about 60 columns wide with a half-block sprite header, bigger meters, a load graph, a clickable session list and the selected session's detail.

Only the sessions named in `showForNames` (default `Orca`, the kit's default seat; kit-init sets it to yours) draw it; every other session still runs the mod and writes its heartbeat, so the shown HUD lists all of them. `/hud band` or `/hud pane` in a hidden session shows it there until that session ends.

Switch while running with `/hud band`, `/hud pane` or `/hud off`. The choice is remembered across sessions. `/hud quiet` toggles the kit's quiet mode. `/hud` alone prints a one-line summary.

## What it shows

- **Every session**: name, a dot (by account, blue = account 1, purple = account 2; or by project, see Dots), context bar and size, busy/shell/idle glyph, and the last tool or prompt as the activity line.
  Colors: green below the amber mark, amber from it, red from the report mark. Every color has a second cue: `~` after the size at amber, `!` at red.
  A session that crosses the report mark **flashes red** for `flashSeconds`.
- **Host**: CPU load against the thread count (with sparkline), RAM, disks, GPU utilization and temperature, VRAM.
- **Windows commit limit** (WSL): amber at `commitWarnPct`, red at `commitCritPct`. This is a real failure mode: Windows hits its commit limit and stops the WSL VM while the Linux side looks fine, with nothing logged inside Linux.
- **Chips**: WORK/QUIET (shown only where the kit's quiet-mode script exists; clickable when both commands are configured; red `failed` for a minute after a failed press) and the session count from the left; alerts against the right edge (on a row of their own in the pane), most urgent first: Windows commit, sessions over the report mark, load high.
- **Dots**: by Claude account (default), or by project (`dotMode: project`), so one HUD tells several projects' teams apart. A session's project is the main checkout of its directory (a sibling in its own worktree counts). Its dot color is, first that applies: the color of its own terminal tab when the launcher that opened it set `CLAUDE_TAB_COLOR`; the color the kit's launcher recorded for the project in `<kitRuntimeDir>/tab-colors` (lines `<repo path><TAB>#rrggbb`); `tab_color: #rrggbb` in the team block of the project's `docs/orchestration/ORCHESTRATION.md`; else a fixed color picked from the project's name. Missing files are skipped. In project mode the key row names each project in its color and the sessions title counts projects. Hex colors are drawn as 24-bit color where the terminal says it supports it (`COLORTERM=truecolor`).

## How it works

Every session that runs the mod reports itself and reads everyone else, through plain files in the status directory (default `~/.claude-status-hud`):

| File | Written by | Holds |
|---|---|---|
| `sessions/<id>.json` | each session, every `refreshSeconds` | name, model, account, context used and window, state, activity |
| `host.json` | whichever session finds it older than 5 s | load, RAM, disks, GPU, commit, history for the sparklines |

- **Privacy.** The activity line is the tool's own description (or just its name), never your prompt text, a raw command, a file path or a URL. The status directory is created `0700` and its files `0600`; a directory that already exists (say you point `statusDir` at a shared folder) keeps its mode.
- A session is **gone** after `staleSeconds` without a heartbeat and its file is deleted at twice that. A clean exit deletes its own file.
- **One writer for host metrics.** A session that finds `host.json` stale takes a `mkdir` lock (atomic), runs one shell script for `/proc/loadavg`, `nproc`, `/proc/meminfo`, `df` and `nvidia-smi`, writes the result via tmp file and `mv`, and releases. The others skip. The lock holds an owner token and its start time; only its owner releases it, and a lock older than 60 s (longer than the longest live hold, 25 s) is a dead writer's: one session wins an atomic rename of it and deletes it. Orphaned `.tmp` files are swept after `staleSeconds`.
- The Windows commit reading runs `commitCmd` (about a second) at most every `commitSeconds`.
- **Drawing reads state only.** A timer fills the state from the files; the band and pane never shell out or touch the disk when they draw.
- A session's name comes from its `--name` argument and its account from `CLAUDE_CONFIG_DIR`, both read off the parent `claude` process once at start. Override with the `sessionName` option or the `CLAUDE_HUD_NAME` env var.

## Install

With the orchestration kit (recommended): run `/orchestration-kit:kit-init` and answer Yes to the Status HUD question, or ask Claude to "install the status HUD". That runs, for each account the team uses:

```bash
claude plugin install status-hud@artekka-kits --scope project
claude plugin configure status-hud@artekka-kits --values-stdin <<'JSON'
{ "showForNames": "<your seat name>" }
JSON
```

By hand, without the kit's marketplace:

```bash
# one session, for trying it
claude --plugin-dir /path/to/plugins/status-hud

# every session, without installing: add this to the env block of ~/.claude/settings.json
# (and of each extra account's settings.json, e.g. ~/.claude-acct2/settings.json)
CLAUDE_CODE_PLUGIN_DIRS=/path/to/plugins/status-hud
```

The `env` route is a settings edit, so do it deliberately; nothing in the kit makes it for you.

## Configure

All options are `userConfig` fields, shown in `/config` and stored under `pluginConfigs` in settings. To set several at once without editing JSON by hand:

```bash
claude plugin configure status-hud@artekka-kits --values-stdin <<'JSON'
{
  "variant": "band",
  "contextAmberMark": "300000",
  "contextReportMark": "350000",
  "flashSeconds": "6",
  "commitWarnPct": "85",
  "commitCritPct": "95",
  "mounts": "/",
  "staleSeconds": "120",
  "showForNames": "Orca",
  "quietModeFlagFile": "~/.orchestration-kit/runtime/quiet-mode",
  "quietModeOnCmd": "bash scripts/quiet-mode.sh on",
  "quietModeOffCmd": "bash scripts/quiet-mode.sh off"
}
JSON
```

Installed from the kit's marketplace the id is `status-hud@artekka-kits`; loaded with `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS` it is `status-hud@inline`. A second account needs its own run: `CLAUDE_CONFIG_DIR=~/.claude-acct2 claude plugin configure ...` (kit-init does this for every logged-in `~/.claude-acctN`).

If you edit settings JSON by hand instead, write numbers as numbers (`"contextReportMark": 350000`): a string in a number field stops the module from loading.

The quiet-mode values above are the defaults: the flag file the kit's `scripts/quiet-mode.sh` writes (under `KIT_RUNTIME_DIR` if you set it, else `~/.orchestration-kit/runtime`), and its on and off commands, which run in the session's directory (your repo).

| Option | Default | Meaning |
|---|---|---|
| `variant` | `band` | `band`, `pane` or `off`. `/hud` changes it at run time. |
| `contextAmberMark` | 300000 | Tokens at which a session turns amber. |
| `contextReportMark` | 350000 | Tokens at which it turns red and flashes. Raise or lower it to taste. |
| `flashSeconds` | 6 | Flash length after crossing the report mark. 0 turns the flash off. |
| `commitWarnPct` / `commitCritPct` | 85 / 95 | Windows commit amber and red levels. |
| `commitCmd` | PowerShell one-liner | Prints `<limitKB> <freeKB>`. Empty disables the commit reading (not on WSL). |
| `commitSeconds` | 30 | Minimum seconds between commit readings. |
| `mounts` | `/` | Comma-separated mount points for the disk meters. |
| `showForNames` | `Orca` | Comma-separated session names that draw the HUD (exact, case-sensitive). Empty shows it in every session. kit-init sets your seat. |
| `dotMode` | `account` | `account` or `project` (see Dots above). |
| `hideItems` | (none) | Comma-separated item ids to switch off; see Items below. |
| `kitRuntimeDir` | `~/.orchestration-kit/runtime` | Where the kit's launcher records project tab colors (`tab-colors`), read for project dots. |
| `statusDir` | `~/.claude-status-hud` | Shared directory. All sessions must use the same one. |
| `sessionName` | (detected) | Override the detected session name. |
| `refreshSeconds` | 3 | Heartbeat and redraw interval. |
| `staleSeconds` | 120 | When a silent session counts as gone. |
| `cpuRedLoad` | 0 | Load at which CPU turns red. 0 means 90% of the thread count. |
| `quietModeFlagFile` | `~/.orchestration-kit/runtime/quiet-mode` | If this file exists, quiet mode is on (cheap check, preferred). A leading `~` means your home. |
| `quietModeStatusCmd` | (none) | Alternative, used when the flag file is empty: exit code 0 means on. |
| `quietModeOnCmd` / `quietModeOffCmd` | `bash scripts/quiet-mode.sh on` / `off` | Run by the Quiet Mode chip and `/hud quiet`. Both are needed for the chip to be clickable. |
| `quietModeRequiresFile` | `scripts/quiet-mode.sh` | The chip shows only when this file exists in the session's directory (or quiet mode is already on). Empty always shows it. |

The Quiet Mode chip is hidden unless a flag file or status command is configured and the script above exists here. It is a button: click it while the band has focus (click the band, or ctrl+x then tab), or use `/hud quiet`. `/hud help` explains it. If you use your own on/off commands, set `quietModeRequiresFile` to an empty value to keep the chip.

**What the WORK/QUIET chip does and when you'll see it:** The chip is a switch for the kit's quiet mode. QUIET holds every NEW test/gate run started through `scripts/gate-throttle.sh` while you use the machine yourself; runs already going finish, and WORK lets new ones start normally. It only helps if your team runs its gate through that throttle, so the chip appears only when `scripts/quiet-mode.sh` exists in the session's directory (or quiet mode is already on). No throttle, no chip. If a press fails, the chip turns red and says `failed` for a minute, and the toast says why. `/hud help` repeats this, and `quietModeRequiresFile` changes the file it looks for (empty always shows the chip).

## Items

Every drawn item has an id for `hideItems`. Unknown ids are ignored. The setup page (`docs/status-hud-guide.html` in the kit, opened set to your current settings by `bash scripts/hud-guide.sh open`) shows each one numbered on a picture drawn by this plugin's own layout code: keep or remove each, pick the dot mode, and copy one line that `bash scripts/hud-guide.sh apply '<line>'` saves (only `dotMode` and known `hideItems` ids). After a layout change, rebuild the page with `bash scripts/hud-guide.sh build` (node 22.18 or later; `tests/hud-guide.test.sh` fails while it is out of date).

| Area | Ids |
|---|---|
| Host | `host-title`, `cpu`, `history`, `ram`, `win`, `gpu`, `vram`, `disk`, `disk2` |
| Sessions | `sessions-title`, `context-key`, `state-key`, `dot-key`, `dot`, `model`, `bar`, `tokens`, `state`, `activity`, `column2`, `frame-title` |
| Chips | `work-mode`, `count`, `warnings` |

`dot-key` is the project key (project mode only); `disk2` is any disk after the first; `column2` is the band's second column of session rows (off: one column and `+N more`); `warnings` is every alert chip.

## Develop

```bash
tsc -p .                              # type-check (the engine lays .claude-plugin/types when it loads the mod)
claude plugin validate .
claude plugin test .
npx tsx scripts/preview.ts band 180   # print the band for sample data; also: pane 60, band 100 10, band 180 10 1
bash ../../scripts/hud-guide.sh build # rebuild the setup page (docs/status-hud-guide.html) after a layout change
```

Layout and logic are plain modules in `lib/`; `hooks/register.tsx` only wires them to the engine. Tests use fakes for files and processes, plus an engine-level mock world in `tests/world.ts`.

## Limits

- Known issue (accepted): the stale-lock takeover can in theory hit an ABA race: if a writer's lock is judged dead and renamed away at the same instant a new owner takes it, the new owner's run may be removed. The worst case is one missed host reading, since the next refresh simply retries.

- Host readings come from /proc (`/proc/loadavg`, `/proc/meminfo`) plus `nproc`, `df` and `nvidia-smi`, so they work on Linux and WSL. On macOS (no /proc) no host reading is taken: the host meters stay empty, while every session row, context bar and chip works as usual. The GPU meters need `nvidia-smi`.
- Terminal and desktop surfaces only (the engine raises the band there); other surfaces get nothing.
- The Windows commit reading needs WSL interop. On a machine without it, set `commitCmd` empty.
- A peer's context is visible only if that peer runs the mod too; a session without it is absent from the list.
