# Observatory — product brief

> Source of truth for WHAT Observatory is. Project-, team- and machine-specific values never live in
> the repository: they go in the private bridge config (`crates/bridge/README.md` → Config).

## Why

People who run one or more orchestration-kit teams have every agent in its own terminal: a
`claude --name <Name>` session per agent, a seat (`Orca` by the kit's defaults) and its siblings
(`Sib1`…). Terminal text is hard to read across many agents. Observatory is **one window where every
agent's chat, in every configured project, reads like the VS Code Claude panel**.

## Scope

In scope: readable chat, one sidebar for every configured project, live updates, and typing to an
agent that runs in tmux.
OUT of scope: approve/deny buttons, per-change review, diffs, code editing, completions, starting
sessions from the app. The kit's scripts keep starting and restarting agents.

## Stack

- **Native Rust, eframe/egui.** No web UI, no Chromium/Edge/WebView2/Electron/Tauri. No Bevy.
- **One Windows `.exe`** (`x86_64-pc-windows-gnu`, cross-built from WSL), plus a small **bridge**
  binary inside WSL that the .exe runs over `wsl.exe` and talks to with JSON lines on stdio.
  No network port. The bridge reads logs locally (fast, inotify works) and sends parsed messages, so
  the .exe never reads big files over `\\wsl.localhost`.
- Toolchain: `. scripts/env.sh` (its own copy under `$OBSERVATORY_RUST_DIR`, default `~/observatory-rust`).
- Lightweight is a requirement: small binary, low idle CPU (no busy redraw loop; repaint on new data).

## Interaction model (inspiration: GitHub Copilot desktop app)

From GitHub's docs for the Copilot app: the sidebar is the main navigation, "sessions are grouped by
repository in the sidebar", you "click any session to switch to it", and the session chat fills the
main pane with the prompt box at the bottom. Observatory maps that to:

- **Sidebar**: one group per configured project. Seats first (names from the config's `seats`),
  siblings below. Each row: name, role, status dot (working / idle / needs you / gone), last-activity
  age. With no config, only sessions started in the home folder appear, plus one line saying where the
  config goes.
- **Main pane**: the selected agent's chat. Header shows the name, project, model, and permission mode
  where the log has them.
- **Prompt box** at the bottom: typing to the selected agent (see Typing).

## Chat rendering

- Your messages are right-aligned bubbles. The agent's messages are full-width rendered Markdown:
  headings, lists, bold, tables, links, and code blocks with syntax highlighting.
- Tool calls fold into one line each (`Read docs/…`, `Ran git log …`, `Edited src/… +12 −3`,
  `Messaged Sib1`). Click to expand input and output, which are truncated and monospace.
- Thinking blocks are hidden by default, with a toggle.
- **Restarts**: when a new session with the same agent name appears, continue the same thread with a
  divider "Orca restarted · <time>". Older sessions stay scrollable.
- Readability first: a good proportional UI font plus a mono font (bundled, open-licensed), generous
  line height, ~70-character text column, dark and light themes.
- **Live**: Claude Code writes each finished block (text, tool call, result) as a JSONL line. So
  updates arrive block by block, not word by word. Show "working… 0:45" under the last message while
  the agent is mid-turn.

## Data source (Claude Code's local files; verify upward on each new version)

- Logs: `~/.claude/projects/<dir-slug>/<session-uuid>.jsonl`, the slug being the launch folder with
  `/` and `.` replaced, for example `-home-user-my-app/`. Kit sessions in worktrees have their own
  slugs, so a project lists its worktree folders too.
- An `{"type":"agent-name","agentName":"Sib1","sessionId":…}` record names the agent.
- Message records are `type: user | assistant | system`. `message.content` is a string or a list
  of blocks: `text`, `thinking`, `tool_use`, `tool_result`. Each block can arrive as its own line
  sharing a `message.id`.
- `system` + `subtype: turn_duration` marks a turn ending (→ idle). `subtype: away_summary` is a
  recap Claude writes for the user.
- Many other record types exist (`attachment`, `custom-title`, `mode`, `permission-mode`, …).
  **Unknown types are skipped, never a crash.** The format is undocumented, so keep the parser in one
  module with fixture tests. Fixtures are synthetic and labelled: no real log line is committed.
- Running agents: the session registry `~/.claude/sessions/<pid>.json` (pid, session id, name,
  status, tmux pane), checked against `/proc`; `claude --name <Name>` in the process list as a
  fallback. `status: waiting` means a question or dialog is open: the agent shows "needs you".

## Typing

Agents that run in tmux can be typed to. The bridge finds the selected agent's pane from the process
tree at send time, pastes the text (`load-buffer` + `paste-buffer`), then presses Enter once. It
refuses when the target is unclear, the agent isn't in tmux, or a question is open on its screen.

## Visuals

Images and pages the agents make, read-only:

- **Images in the chat**: when an agent saves, opens or shows an image, a thumbnail appears in that
  agent's conversation; click to enlarge.
- **Gallery per project**: a "Visuals" view with a live, newest-first thumbnail grid of the folders
  the project's config lists (`gallery`). PNG/JPG/WebP.
- **Artifact pages list**: every claude.ai page the agents published (title, agent, time); a click opens it
  in the normal browser, never inside the app (no embedded web UI).

## Install

`scripts/deploy.sh` builds both binaries and installs the `.exe` into a folder you choose
(`--install-root`, `$OBSERVATORY_INSTALL_ROOT`, or `install_root=` in
`~/.config/observatory/deploy.conf`; there is no built-in default) plus a desktop shortcut, and the
bridge into `~/.local/share/observatory/bin`.
