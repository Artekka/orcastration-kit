# observatory-bridge

Runs inside WSL. Follows the Claude Code session logs of the configured projects and writes
`observatory_core::wire::Frame` JSON lines on stdout for the Windows app
(`wsl.exe … observatory-bridge`). Diagnostics go to stderr. It only reads files.

```
observatory-bridge [--once] [--config <path>] [--claude-dir <dir>] [--cutoff-days <n>]
```

- `--once` prints `hello` and the startup frames, then exits (for tests and for checking by hand).
- `--claude-dir` defaults to `~/.claude`.

## Config

Path: `--config`, else `$OBSERVATORY_BRIDGE_CONFIG`, else `$XDG_CONFIG_HOME/observatory/bridge.json`,
else `~/.config/observatory/bridge.json`. The file is yours: it stays outside the repository.

With **no file**, the bridge watches only sessions started in the home folder itself (the
`~ (home)` project) and its `hello` carries a one-line note, shown in the app's sidebar, saying where
the file goes. If the file is unreadable or malformed, the bridge prints a warning on stderr, puts
the same line in that note, and starts with the same defaults. It never fails to start over its config.

### Worked example

Two orcastration-kit teams, each project with its kit worktrees, one with a screenshot gallery, plus
the home folder:

```json
{
  "projects": [
    {
      "name": "web-shop",
      "root": "~/web-shop",
      "worktree_roots": ["~/web-shop-worktrees"],
      "gallery": ["~/web-shop/e2e/*/screenshots"]
    },
    {
      "name": "data-pipeline",
      "root": "~/code/data-pipeline",
      "worktree_roots": ["~/code/data-pipeline-worktrees", "/srv/scratch/pipeline-wt"],
      "gallery": ["/mnt/c/Users/me/Pictures/pipeline-renders"]
    },
    {"name": "~ (home)", "root": "~", "exact": true}
  ],
  "seats": ["Orca", "Atlas"],
  "cutoff_days": 7,
  "liveness_secs": 5,
  "coalesce_ms": 250
}
```

| key | default | meaning |
|---|---|---|
| `projects` | only `~ (home)` | the projects to watch; a session belongs to the project whose `root` or `worktree_roots` contains its launch folder (the longest match wins) |
| `projects[].name` | required | shown as the project's heading |
| `projects[].root` | required | the project's folder |
| `projects[].worktree_roots` | `[]` | folders holding the project's worktrees; each subfolder counts as the project |
| `projects[].gallery` | `[]` | image folders for the project's Visuals view, scanned recursively; a `*` or `?` in a path segment matches any folder name there |
| `projects[].exact` | `false` | claim only `root` itself, not its subfolders (use it for the home folder) |
| `seats` | `[]` | agent names shown as seats (first in the sidebar). The app's `--seats` / `OBSERVATORY_SEATS` override this; with neither, the app uses the kit's default seat name, `Orca` |
| `cutoff_days` | `7` | at startup, read only session files changed in the last N days (`0` = all) |
| `liveness_secs` | `5` | how often running processes are re-checked |
| `coalesce_ms` | `250` | updates to one session within this window go out as one frame |

A leading `~/` (or a bare `~`) in a path means `$HOME`. Every field is optional. Unknown fields are
an error, so a typo shows up as a warning instead of being silently ignored. The full rules are in
`src/config.rs`.

## What it sends

1. `hello`.
2. One full `session` frame for each session file modified in the last `cutoff_days`
   (`<claude>/projects/<slug>/<id>.jsonl`, top level of slug dirs a project claims).
3. Updates (the rule is in `src/bridge.rs`). New lines in a session send one `patch` with only the
   items they appended or completed, coalesced per session within `coalesce_ms`. A new or rewritten
   file sends a full `session` frame. A process that ends sends `gone`, and a revived one sends a
   header-only `patch`. A partial last line waits for its newline.

Changes are picked up by inotify (the `notify` crate), not by polling. Liveness (Running/Gone) comes
from `<claude>/sessions/<pid>.json` (only `*.json` files are read, never `*.key`), checked against
`/proc`, with a `claude --name` + cwd fallback (`src/liveness.rs`). `NeedsYou` while the registry says `waiting` (a question or dialog is open; sends are refused then).

## Read-only

All filesystem access is in `src/fsro.rs`. `tests/read_only.rs` checks that no other module touches
the filesystem and that fsro has no call that can write. `tests/live_test.rs` checks that every file
descriptor a running bridge holds is `O_RDONLY`, and that the tree is byte-identical before and after
a run.
