---
name: bootstrap-project
description: Spin up a NEW project (or adopt an existing directory) with the full orcastration-kit workflow in one pass — mkdir/git init if needed, board + overlay + CLAUDE starter, core skills, verifier agent, optional team agents, curated agnostic-memory starter, then the approval-gated auto-compact-off setting. Idempotent; never overwrites a live file. Use when the human says "bootstrap a project", "spin up a new project with the kit", "set this directory up for orchestration".
---

# bootstrap-project

Superset of `/orcastration-kit:kit-init`: kit-init scaffolds the board/overlay into an existing repo; this one takes a bare directory to a fully kit-adopted project. The mechanical work lives in `scripts/bootstrap.sh` so it is deterministic and dry-runnable.

## Steps

1. **Dry-run first, show the plan:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap.sh" <target-dir> --dry-run [--with-team-agents]
   ```
   Every line is MKDIR/INIT/CREATE/SKIP/NOTE. Show the human; confirm the target and whether team agents are wanted (`--with-team-agents` — user-level agent defs take precedence, so project copies only matter on machines/for collaborators without them).
2. **Run it for real** (same command minus `--dry-run`). Re-running later is safe: existing files always SKIP — a live board, overlay, CLAUDE.md, or memory store is state, not scaffolding.
3. **Fill the overlay WITH the human.** Open `docs/orchestration/ORCHESTRATION.md`: gate command + pass-proof line, change classes, never-run commands, deploy vehicle, locked items. Infer candidates from the repo; NEVER silently guess a gate.
4. **CLAUDE.md when it already existed:** the script only NOTEs it. Offer `templates/CLAUDE-section.md` as an append (managed marker `<!-- orcastration-kit vX -->`); requires the human's yes.
5. **Settings snippet — approval-gated** (`templates/settings-snippets.md`): `autoCompact: false` (the no-/compact house flow). It edits `.claude/settings.json` (user config) — apply only on an explicit yes, after verifying the key against the current Claude Code version. The SessionStart hook ships with the plugin; nothing to add.
6. **Commit** in the target repo: `chore(orchestration): bootstrap orcastration-kit vX` (X = the installed kit version, from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`).
7. **Next step:** `bash scripts/start-team.sh` (seat + 2 siblings, each in its own window; `--dry-run` to preview) — offer to run it.

## Rules

- Idempotent via install-only-if-missing; the ONLY overwrite path is a kit UPGRADE diffing against a managed marker, proposed as a delta.
- Plugins are user-level: document (README "Assumed plugins"), never copy.
- extras/ (e.g. backfill) are take-or-leave: mention, don't install.
