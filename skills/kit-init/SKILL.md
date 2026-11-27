---
name: kit-init
description: Initialize a project for the multi-session orchestration workflow — scaffold the shared AGENT_BOARD, the ORCHESTRATION.md project overlay, the institutional-memory docs (AI_CONTEXT + build log), the session scripts (start-team, recycle-sibling, ctx-fill), and (with approval) the CLAUDE.md starter section. Use on any project adopting the orcastration-kit, when the user says "set up the board", "init the orchestration kit", "make this project multi-session ready". Idempotent — safe to re-run; never overwrites an existing file.
---

# kit-init

Scaffold a repo for the seat + siblings workflow. Sources: `${CLAUDE_PLUGIN_ROOT}/templates/` and `${CLAUDE_PLUGIN_ROOT}/scripts/`. **Every file is created only if missing** — an existing board, overlay, log, status doc or script is live state, never scaffolding.

## Steps

1. **Copy what's missing** (prints CREATE/SKIP per file):
   ```bash
   K="${CLAUDE_PLUGIN_ROOT}"
   # Named variables only: the skill loader replaces dollar-digit tokens in this file with the invocation's args.
   put() { if [ -e "$DST" ]; then echo "SKIP   $DST (exists)"; else mkdir -p "$(dirname "$DST")" && cp "$SRC" "$DST" && echo "CREATE $DST"; fi; }
   for p in templates/AGENT_BOARD.md:docs/orchestration/AGENT_BOARD.md \
            templates/ORCHESTRATION.md:docs/orchestration/ORCHESTRATION.md \
            templates/briefs/README.md:docs/orchestration/briefs/README.md \
            templates/briefs/_TEMPLATE.md:docs/orchestration/briefs/_TEMPLATE.md \
            templates/CLAUDE-slimness.md:docs/orchestration/CLAUDE-slimness.md \
            templates/AI_CONTEXT.md:docs/AI_CONTEXT.md \
            templates/build-log.md:docs/timeline/build-log.md; do
     SRC="$K/${p%%:*}" DST="${p#*:}" put
   done
   [ -e docs/orchestration/.kit-hooks ] || { printf '%s\n' "# opt-in marker: the orcastration-kit SessionStart hook runs only in repos carrying this file. Delete it to silence the hook." > docs/orchestration/.kit-hooks && echo "CREATE docs/orchestration/.kit-hooks"; }
   for f in lib-launch.sh lib-kit-home.sh start-team.sh recycle-sibling.sh ctx-fill.py statusline-ctx.sh gate-throttle.sh quiet-mode.sh seat-merge.sh lib-waiting-tickets.sh lib-builder-worktree.sh pending-work.sh tmux-session.sh tmux/agents.tmux.conf sibling-shell.sh retro-worktrees.sh docker-cache-cap.sh gate-disk-guard.sh bottleneck-watch.sh lib-prompt-dialog.sh main-checkout-sync.sh sync-main-checkout.sh launched_window.py lib-model-tag.sh lib-git-retry.sh lib-conflict-markers.sh lib-mono-clock.sh lib-disk-sweep-launch.sh disk-sweep.sh disk-sweep-cron.sh; do SRC="$K/scripts/$f" DST="scripts/$f" put; done
   chmod +x scripts/start-team.sh scripts/recycle-sibling.sh scripts/ctx-fill.py scripts/statusline-ctx.sh scripts/gate-throttle.sh scripts/quiet-mode.sh scripts/seat-merge.sh scripts/pending-work.sh scripts/tmux-session.sh scripts/sibling-shell.sh scripts/retro-worktrees.sh scripts/docker-cache-cap.sh scripts/gate-disk-guard.sh scripts/disk-sweep.sh scripts/disk-sweep-cron.sh scripts/bottleneck-watch.sh scripts/main-checkout-sync.sh scripts/sync-main-checkout.sh scripts/launched_window.py
   ```
   If the overlay names different doc paths (ORCHESTRATION.md → Docs), use those instead.
   **Disk sweep (0.18.0), on by default:** the `.kit-hooks` marker also turns on the scheduled disk sweep. The SessionStart hook
   starts `disk-sweep-cron.sh` in the background at most once a day (and `gate-disk-guard.sh` starts it early under 50 GB free).
   Its first run is a dry run; the next session start shows the report. Tell the human in one line what was scheduled and the
   command that turns it off: `bash <kit>/scripts/disk-sweep.sh --off` (README "Disk sweep").
   **Scripts copied on 0.16 (before the 0.17.0 id rename):** `put` never overwrites, so a project adopted on 0.16 keeps launch scripts whose default prompt is the 0.16 command prefix, which no longer exists, and copies of gate-throttle.sh, quiet-mode.sh and seat-merge.sh that write to the 0.16 state folder (a second throttle slot set when the 0.16 name's link is missing). List them with `bash "$K/scripts/kit-refresh.sh"` (read-only; `STALE` lines). Any → show the list and ask the human ONCE whether to refresh. Yes → `bash "$K/scripts/kit-refresh.sh" --apply`: it works on `scripts/` in the folder it runs from (a linked `scripts/` is refused, exit 3) and replaces only copies whose exact bytes are a kit 0.16 version (never a project-edited copy), that are regular files (no symlink, no second hard link, writable), and that the project's git tracks with no uncommitted change (so `git diff -- scripts/` shows the refresh and `git checkout -- <file>` undoes one); it creates any library they source that is missing (new untracked files: undo by deleting them) and prints `LEFT <file> (<reason>)` with the manual step for the rest (exit 3). Report each `REFRESH`/`CREATE`/`LEFT` line, stage the refreshed files with the CREATE paths, and show the human `git diff --stat -- scripts/`. Until then, pass the prompt explicitly (`recycle-sibling.sh <Name> /orcastration-kit:orient`).
2. **Fill the overlay** (only if just created) — infer candidates from the repo (`package.json` scripts, `Makefile`, CI config), then ASK the human to confirm: gate command + pass-proof line, never-run commands, deploy vehicle (or "none"), validator seat (optional), locked items. Never silently guess a gate. Leave the `team:` block at its defaults unless the human wants other names.
3. **Write AI_CONTEXT.md** (only if just created) — never leave it a template.
   **First ask, once — ONE `AskUserQuestion`:** "No orientation doc found. How should I learn this project?" → **Search the project (Recommended)** · **I'll give you an outline** (a file path, or paste it in your reply) · **Both — my outline first, then check it against the project**. With an outline: read it, treat it as the human's word on purpose/priorities, and verify its factual claims (paths, commands, versions) against the repo — the repo wins on facts, flag any mismatch. The doc you then write is the record, so this question never repeats.
   Survey (search path, or to check an outline):
   ```bash
   ls; cat README* CLAUDE.md 2>/dev/null | head -200      # purpose, setup, conventions
   ls package.json pyproject.toml Cargo.toml go.mod Makefile 2>/dev/null   # stack + scripts
   find . -maxdepth 2 -type d -not -path './.git*' -not -path '*/node_modules*' | head -60
   ls docs .github/workflows 2>/dev/null; git log --oneline -30; git tag --sort=-v:refname | head -3
   ```
   Fill EVERY section: version (tag/manifest), test count (one gate run, literal pass line), what works, in flight (open branches), architecture quick-ref (path → what it is), deferred work (TODO/FIXME hotspots, open issues if visible). Mark anything inferred-not-verified `(unverified)`. Ask the human ONE `AskUserQuestion` for what the repo can't tell you: top priority right now + working-style preferences (offer "skip"). Also append the first log entry: `Milestone 1 — <date>: adopted orcastration-kit (baseline: <version>, <test line>)`.
4. **CLAUDE.md section** — offer to append `templates/CLAUDE-section.md` (managed block `<!-- orcastration-kit vX -->`). Requires the human's yes; no CLAUDE.md → offer to create it with just this section. Marker already present → diff against the new template and propose the delta. The 0.16 marker spelling (opening `<!-- orchestration-kit vX -->`, closing `<!-- /orchestration-kit -->`) counts as present, and the delta rewrites both to the new ones (`<!-- orcastration-kit vX -->`, `<!-- /orcastration-kit -->`).
5. **Memory** — nothing to create. Claude Code makes its auto-memory (`~/.claude/projects/<slug>/memory/`) itself; `/orcastration-kit:retro` writes lessons there.
6. **Commit** — stage exactly the paths reported CREATE (never `git add -A`), `git commit -m "chore(orchestration): adopt orcastration-kit vX"`, `git push`.
7. **Ask to start the team — ONE `AskUserQuestion` call, three questions.** Never run start-team without the answers.
   First detect the terminal backend (no question — shown in the summary; override later with `terminal:` in the team block):
   ```bash
   bash scripts/start-team.sh --dry-run --siblings 0 | grep -E '^(backend|reason) '   # backend + why it was picked
   ```

   | Q | Options (first = recommended) |
   |---|---|
   | "Start the team now? You can change the team size, names, permission mode or worktree setting at any time — just ask Claude to change it." | **Seat + 2 siblings (Recommended)** · **Choose how many** (follow up: 1–9) |
   | "Permission mode for the team's sessions?" | **Normal (Recommended)** — asks before risky actions (no flag) · **Auto** — `--permission-mode auto`: Claude Code's automatic permission checks decide instead of prompting · **Accept edits** — `--permission-mode acceptEdits`: file edits approved automatically, commands still ask |
   | "Separate worktrees per session? Sessions are instructed to use their own worktree either way; some workflows deliberately share one tree or file between agents, so enforcement is optional." | **Advised (Recommended)** — every session is told to use its own worktree, but nothing blocks it · **Enforced** — a hook blocks edits in the main checkout except board/log files |

   On a start answer, run it through Bash — say in one line first: "Your OK on the next Bash prompt is the final go-ahead to open the windows."
   ```bash
   bash scripts/start-team.sh --siblings <N> --mode <normal|auto|accept-edits>
   ```
   `--mode` is saved to the `team:` block (`permission_mode:`) so recycles reuse it — commit that change (explicit path). Backend `manual` (nothing here can open windows) → say so, and instead of launching show the per-window commands from `bash scripts/start-team.sh --siblings <N> --mode <mode> --dry-run` (`by hand` lines): one terminal each, in the repo. `tmux-detached` → also tell the human `tmux attach -t <session>` (the script prints it).
   **Platform check (say it before launching, from the dry run's `backend` line):** `gitbash-cmd` or `manual` → recycling cannot happen in place (no `pgrep`): each recycle opens a new window and the human closes the old one. `wsl-*` with a space or `;`/quote in the repo path → refused by the WSL launcher; move the repo to a plain path (`~/projects/<name>`). macOS → a seat self-recycle opens a new tab (no `setsid`). Claude Code older than the tested version (`claude --version`, GETTING-STARTED §0) → `claude update` first.
   Persist the worktree answer, and set the git guard **from the start answer — no question**: every start (seat + 1–9 siblings) → `git_guard: on` and `ctx_guard: on`. Then commit that path:
   ```bash
   C=docs/orchestration/ORCHESTRATION.md
   setkey() {  # KEY=<key> VAL=<value> setkey   (named variables: the skill loader eats dollar-digit tokens)
     if grep -Eq "^[[:space:]]+$KEY:" "$C"; then sed -i -E "s/^([[:space:]]+$KEY:[[:space:]]*).*/\1$VAL/" "$C"
     elif grep -q '^team:[[:space:]]*$' "$C"; then sed -i "/^team:[[:space:]]*\$/a\  $KEY:        $VAL" "$C"
     else printf '\nteam:\n  %s:        %s\n' "$KEY" "$VAL" >> "$C"; fi
   }
   KEY=worktrees VAL=<advised|enforced> setkey; KEY=git_guard VAL=on setkey; KEY=ctx_guard VAL=on setkey
   git add "$C" && git commit -m "chore(orchestration): worktrees + git_guard + ctx_guard settings"
   ```
   Both take effect at once: the plugin's PreToolUse hooks read the file on every call (only in repos with `.kit-hooks`).
8. **End-of-setup summary** (print it): files created/skipped · gate + deploy recorded · "Windows will open via: <backend> (change any time — just ask Claude)" (for `manual`: "Windows can't be opened automatically here — run these commands, one terminal each:" + the commands) · team started (names, mode) or the command to start it · "talk to the seat window; siblings report to it" · "Each session is instructed to work in its own worktree; this is [advised/enforced] — change it any time by asking Claude." (fill in the answer) · "Risky git commands (stash, add -A, commit -a, pull --rebase, force-push) are [blocked — on, set by kit-init when it starts the team; say "turn off the git guard" to relax it] — change it any time by asking Claude." · and this line verbatim: **"You can change any of this — team size, names, permission mode, gate or deploy commands — at any time. Just ask Claude to change it."**
9. **Status HUD (optional) — ONE `AskUserQuestion`**, after the summary: "Install the status HUD? It draws every session's context fill, model and activity (plus host load) above the seat's prompt. Change it any time — just ask Claude." → **No (Recommended)** · **Yes**. Put the answer in `HUD=` and run (it needs the `claude` CLI; it installs for the default account and every logged-in `~/.claude-acctN`, and shows the HUD only in the seat named in the `team:` block):
   ```bash
   HUD=<yes|no>
   if [ "$HUD" != yes ]; then echo "SKIP status HUD (not installed; say \"install the status HUD\" any time)"; else
     SEAT=$(sed -nE 's/^[[:space:]]+seat:[[:space:]]*([^[:space:]#]+).*/\1/p' docs/orchestration/ORCHESTRATION.md | head -1)
     QF="${KIT_RUNTIME_DIR:-$HOME/.orcastration-kit/runtime}/quiet-mode"
     VALS=$(printf '{"showForNames":"%s","quietModeFlagFile":"%s","quietModeOnCmd":"bash scripts/quiet-mode.sh on","quietModeOffCmd":"bash scripts/quiet-mode.sh off"}' "${SEAT:-Orca}" "$QF")
     for D in default "$HOME"/.claude-acct*; do
       # an extra account counts when logged in; macOS keeps logins in the Keychain, so there every dir counts
       if [ "$D" = default ]; then unset CLAUDE_CONFIG_DIR; SJ="$HOME/.claude/settings.json"; WHO="the default account"
       elif [ -d "$D" ] && { [ "$(uname -s)" = Darwin ] || [ -e "$D/.credentials.json" ]; }; then export CLAUDE_CONFIG_DIR="$D"; SJ="$D/settings.json"; WHO="$D"
       else continue; fi
       # a status HUD already loaded from a folder (CLAUDE_CODE_PLUGIN_DIRS, in this shell or that account's settings env)
       PD="$(grep -o '"CLAUDE_CODE_PLUGIN_DIRS"[^,}]*' "$SJ" 2>/dev/null) ${CLAUDE_CODE_PLUGIN_DIRS:-}"
       case "$PD" in *status-hud*)
         echo "SKIP status HUD for $WHO: a status HUD already loads there through CLAUDE_CODE_PLUGIN_DIRS (${PD# }); two copies would both draw and the configure step fails. Remove that entry from the settings env, then ask again."
         continue ;; esac
       if ! claude plugin install status-hud@artekka-kits --scope project; then
         echo "status HUD install FAILED for $WHO (claude's own message is above; tell the human)"
       elif ! printf '%s' "$VALS" | claude plugin configure status-hud@artekka-kits --values-stdin; then
         echo "status HUD installed for $WHO, but configuring it FAILED (claude's own message is above): the plugin is installed and runs with its defaults (its default showForNames is the seat name, so it draws only in the seat's window; set showForNames to your seat). Tell the human, and offer to retry: printf '%s' '$VALS' | claude plugin configure status-hud@artekka-kits --values-stdin${CLAUDE_CONFIG_DIR:+ (with CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR)}"
       else
         echo "status HUD installed for $WHO (shown in: ${SEAT:-Orca})"
       fi
     done
     unset CLAUDE_CONFIG_DIR
   fi
   ```
   On Yes, commit `.claude/settings.json` if the install changed it (explicit path), and tell the human: "The HUD appears in the seat's window from its next start; `/hud band`, `/hud pane` or `/hud off` switch it, `/hud quiet` toggles quiet mode."
10. **Interface (optional) — ONE `AskUserQuestion`**, after the HUD step: "How do you want to watch and talk to your team? Change it any time — just ask Claude." → **CLI (Recommended)** — the terminals you already have; nothing changes · **Orcastration Station** — an optional desktop window (Windows with WSL) that shows every agent's chat and can type to one in tmux; v0.16.0 prints the install paths and installs nothing. Put the answer in `IFACE=` and run it from the plugin (the script is not copied into the project):
   ```bash
   IFACE=<cli|station>
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/station-interface.sh" "$IFACE"
   ```
   Show the human the script's output as it is. A `cli` answer writes nothing. A `station` answer sets `interface: station` in the overlay (commit that file by explicit path) and prints the install steps; run no installer yourself.
11. **Offer the tour (last thing, whatever the HUD answer was)** — ask in plain text, one line: "Want the tour? `HOW-IT-WORKS.md` explains the whole loop in one diagram: the seat, the board, builders in their own worktrees, independent checks, trains, and every setting you can change." On Yes, give the link `https://github.com/Artekka/orcastration-kit/blob/main/HOW-IT-WORKS.md` (the same page ships as `docs/how-it-works.html` in the plugin) and summarize the loop in five lines. On No, say it stays linked from the README and `docs/GETTING-STARTED.md`.

## Rules

- Idempotent: never overwrite; re-running reports SKIP for everything that exists.
- The plugin ships its hooks itself — nothing to install in `.claude/settings.json`: SessionStart (fresh sessions are told to orient + send READY) PreToolUse `worktree-guard.sh` (a no-op unless `worktrees: enforced`) PreToolUse `git-guard.sh` on Bash (a no-op unless `git_guard: on`), and the context guard `ctx-guard.py` on PostToolUse + UserPromptSubmit (a no-op unless `ctx_guard: on`; needs `python3`). All run only in repos carrying `.kit-hooks`.
