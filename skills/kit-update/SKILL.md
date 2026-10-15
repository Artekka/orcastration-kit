---
name: kit-update
description: Update the installed orchestration kit (and the status HUD) to the newest version the marketplace offers — show what changed, warn that open sessions keep the old version until restarted, run the plugin update on the human's yes, then list kit projects whose copied session scripts are now older and offer to refresh them. Use when the human says "update the kit", "is there a new kit version", "upgrade orchestration-kit".
---

# kit-update

One confirmed update, never an automatic one: open sessions keep the version they started with, so updating under a running team leaves it on mixed versions until each window restarts. The script is `${CLAUDE_PLUGIN_ROOT}/scripts/kit-update.sh` (`status`, `run`, `projects`, `refresh`).

## Steps

1. **What is available** — refresh and compare:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/kit-update.sh" status --fetch
   ```
   Exit 0 → say it is up to date and stop. Exit 10 → read the newer version's section of the marketplace copy's `CHANGELOG.md` (the marketplace folder is `installLocation` in `~/.claude/plugins/known_marketplaces.json`) and summarize it in plain words, three lines at most.
2. **Ask once, in plain text:** "Update from <old> to <new> now? Open sessions, this one included, keep <old> until you restart them; a running team keeps working on <old> meanwhile." If a team is mid-task, suggest waiting for a quiet moment.
3. **On yes**, run it without its own question (the human just answered):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/kit-update.sh" run --yes
   ```
   When step 1 said "the same version with newer changes" (a kit installed from a local folder that changed
   without a version bump), add `--reinstall`: Claude Code installs by version, so a plain update would keep
   the old copy. Report its lines. A failure leaves the old version installed; say so and show the error.
4. **Projects** — the run ends with the projects whose copies of the kit's session scripts (`scripts/start-team.sh` and the others kit-init copies once) differ from the new kit. If it lists any, ask once: "Refresh those copies? Each replaced file is kept as `<file>.bak-<date>`." On yes, for each listed project:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/kit-update.sh" refresh <project folder>
   ```
   then run that project's gate and commit the refreshed files there by explicit path. A project that edited its copies on purpose: show the difference first and let the human choose.
5. **Close with the restart line:** "Restart open Claude sessions (and the team) to use <new>; `/orchestration-kit:kit-init` in a project adds any new template files it lacks."

## Rules
- Never run the update without the human's yes in this conversation.
- Never refresh a project's scripts without a yes; never delete the `.bak-<date>` copies.
