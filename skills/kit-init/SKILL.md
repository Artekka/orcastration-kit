---
name: kit-init
description: Initialize a project for the multi-session orchestration workflow — scaffold the shared AGENT_BOARD, the ORCHESTRATION.md project overlay, the institutional-memory docs (AI_CONTEXT + build log), the session scripts (start-team, recycle-sibling, ctx-fill), and (with approval) the CLAUDE.md starter section. Use on any project adopting the orchestration-kit, when the user says "set up the board", "init the orchestration kit", "make this project multi-session ready". Idempotent — safe to re-run; never overwrites an existing file.
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
   [ -e docs/orchestration/.kit-hooks ] || { printf '%s\n' "# opt-in marker: the orchestration-kit SessionStart hook runs only in repos carrying this file. Delete it to silence the hook." > docs/orchestration/.kit-hooks && echo "CREATE docs/orchestration/.kit-hooks"; }
   for f in lib-launch.sh start-team.sh recycle-sibling.sh ctx-fill.py statusline-ctx.sh gate-throttle.sh quiet-mode.sh; do SRC="$K/scripts/$f" DST="scripts/$f" put; done
   chmod +x scripts/start-team.sh scripts/recycle-sibling.sh scripts/ctx-fill.py scripts/statusline-ctx.sh scripts/gate-throttle.sh scripts/quiet-mode.sh
   ```
   If the overlay names different doc paths (ORCHESTRATION.md → Docs), use those instead.
2. **Fill the overlay** (only if just created) — infer candidates from the repo (`package.json` scripts, `Makefile`, CI config), then ASK the human to confirm: gate command + pass-proof line, never-run commands, deploy vehicle (or "none"), validator seat (optional), locked items. Never silently guess a gate. Then the team's names.
   **Once per machine** — when `bash "${CLAUDE_PLUGIN_ROOT}/scripts/team-defaults.sh" --show` prints nothing, ask in plain text (the answer is typed names, not a choice from a list): "Team names: use the kit's (the orchestrator is `Orca`, the siblings `Sib1`, `Sib2`...), or name them yourself? Your own: one orchestrator name, which gets each project's initials added so every project's orchestrator is unique (e.g. `Atlas-BS` for Book Shop), and a list of sibling names drawn at random, optionally numbered (`w1-Ceres`, `w2-Juno`). Saved for every project on this machine; change it any time by asking Claude." Save the answer: the kit's names → `bash "${CLAUDE_PLUGIN_ROOT}/scripts/team-defaults.sh" --save-kit`; their own → `bash "${CLAUDE_PLUGIN_ROOT}/scripts/team-defaults.sh" --save-own <Orchestrator> <Name1,Name2,...> [--numbered w]`.
   **Every project** — apply the saved names: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/team-defaults.sh" --repo .`, and say what it set (it prints each key; with the kit's names it changes nothing). The file (`~/.orchestration-kit/team-defaults`) may also hold other `team:` keys, e.g. `permission_mode:`; they are applied the same way. Beyond that, leave the `team:` block at its defaults unless the human wants other names.
3. **Write AI_CONTEXT.md** (only if just created) — never leave it a template.
   **First ask, once — ONE `AskUserQuestion`:** "No orientation doc found. How should I learn this project?" → **Search the project (Recommended)** · **I'll give you an outline** (a file path, or paste it in your reply) · **Both — my outline first, then check it against the project**. With an outline: read it, treat it as the human's word on purpose/priorities, and verify its factual claims (paths, commands, versions) against the repo — the repo wins on facts, flag any mismatch. The doc you then write is the record, so this question never repeats.
   Survey (search path, or to check an outline):
   ```bash
   ls; cat README* CLAUDE.md 2>/dev/null | head -200      # purpose, setup, conventions
   ls package.json pyproject.toml Cargo.toml go.mod Makefile 2>/dev/null   # stack + scripts
   find . -maxdepth 2 -type d -not -path './.git*' -not -path '*/node_modules*' | head -60
   ls docs .github/workflows 2>/dev/null; git log --oneline -30; git tag --sort=-v:refname | head -3
   ```
   Fill EVERY section: version (tag/manifest), test count (one gate run, literal pass line), what works, in flight (open branches), architecture quick-ref (path → what it is), deferred work (TODO/FIXME hotspots, open issues if visible). Mark anything inferred-not-verified `(unverified)`. Ask the human ONE `AskUserQuestion` for what the repo can't tell you: top priority right now + working-style preferences (offer "skip"). Also append the first log entry: `Milestone 1 — <date>: adopted orchestration-kit (baseline: <version>, <test line>)`.
4. **CLAUDE.md section** — offer to append `templates/CLAUDE-section.md` (managed block `<!-- orchestration-kit vX -->`). Requires the human's yes; no CLAUDE.md → offer to create it with just this section. Marker already present → diff against the new template and propose the delta.
5. **Memory** — nothing to create. Claude Code makes its auto-memory (`~/.claude/projects/<slug>/memory/`) itself; `/orchestration-kit:retro` writes lessons there.
6. **Commit** — stage exactly the paths reported CREATE (never `git add -A`), `git commit -m "chore(orchestration): adopt orchestration-kit vX"`, `git push`.
7. **Ask to start the team — ONE `AskUserQuestion` call, three questions.** Never run start-team without the answers.
   First detect the terminal backend (no question — shown in the summary; override later with `terminal:` in the team block):
   ```bash
   bash scripts/start-team.sh --dry-run --siblings 0 | grep -E '^(backend|reason) '   # backend + why it was picked
   ```

   | Q | Options (first = recommended) |
   |---|---|
   | "Start the team now? You can change the team size, names, permission mode or worktree setting at any time — just ask Claude to change it." | **Seat + 2 siblings (Recommended)** · **Choose how many** (follow up: 1–9) · **Practice mode (Solo)** — you play the orchestrator by hand with two sibling terminals; see GETTING-STARTED Practice |
   | "Permission mode for the team's sessions?" | **Normal (Recommended)** — asks before risky actions (no flag) · **Auto** — `--permission-mode auto`: Claude Code's automatic permission checks decide instead of prompting · **Accept edits** — `--permission-mode acceptEdits`: file edits approved automatically, commands still ask |
   | "Separate worktrees per session? Sessions are instructed to use their own worktree either way; some workflows deliberately share one tree or file between agents, so enforcement is optional." | **Advised (Recommended)** — every session is told to use its own worktree, but nothing blocks it · **Enforced** — a hook blocks edits in the main checkout except board/log files |

   On a start answer, run it through Bash — say in one line first: "Your OK on the next Bash prompt is the final go-ahead to open the windows."
   ```bash
   bash scripts/start-team.sh --siblings <N> --mode <normal|auto|accept-edits>
   ```
   `--mode` is saved to the `team:` block (`permission_mode:`) so recycles reuse it — commit that change (explicit path). **Practice mode (Solo)** → start nothing; show the team command for later and point at GETTING-STARTED "Practice". Backend `manual` (nothing here can open windows) → say so, and instead of launching show the per-window commands from `bash scripts/start-team.sh --siblings <N> --mode <mode> --dry-run` (`by hand` lines): one terminal each, in the repo. `tmux-detached` → also tell the human `tmux attach -t <session>` (the script prints it).
   **Platform check (say it before launching, from the dry run's `backend` line):** `gitbash-cmd` or `manual` → recycling cannot happen in place (no `pgrep`): each recycle opens a new window and the human closes the old one. `wsl-*` with a space or `;`/quote in the repo path → refused by the WSL launcher; move the repo to a plain path (`~/projects/<name>`). macOS → a seat self-recycle opens a new tab (no `setsid`). Claude Code older than the tested version (`claude --version`, GETTING-STARTED §0) → `claude update` first.
   Persist the worktree answer, and set the git guard **from the start answer — no question**: a team start (seat + 1–9 siblings) → `git_guard: on` and `ctx_guard: on`; **Practice mode (Solo)** → both `off`. Then commit that path:
   ```bash
   C=docs/orchestration/ORCHESTRATION.md
   setkey() {  # KEY=<key> VAL=<value> setkey   (named variables: the skill loader eats dollar-digit tokens)
     if grep -Eq "^[[:space:]]+$KEY:" "$C"; then sed -i -E "s/^([[:space:]]+$KEY:[[:space:]]*).*/\1$VAL/" "$C"
     elif grep -q '^team:[[:space:]]*$' "$C"; then sed -i "/^team:[[:space:]]*\$/a\  $KEY:        $VAL" "$C"
     else printf '\nteam:\n  %s:        %s\n' "$KEY" "$VAL" >> "$C"; fi
   }
   KEY=worktrees VAL=<advised|enforced> setkey; KEY=git_guard VAL=<on if a team was started, else off> setkey; KEY=ctx_guard VAL=<on if a team was started, else off> setkey
   git add "$C" && git commit -m "chore(orchestration): worktrees + git_guard + ctx_guard settings"
   ```
   Both take effect at once: the plugin's PreToolUse hooks read the file on every call (only in repos with `.kit-hooks`).
8. **End-of-setup summary** (print it): files created/skipped · gate + deploy recorded · "Windows will open via: <backend> (change any time — just ask Claude)" (for `manual`: "Windows can't be opened automatically here — run these commands, one terminal each:" + the commands) · team started (names, mode) or the command to start it · "talk to the seat window; siblings report to it" · "Each session is instructed to work in its own worktree; this is [advised/enforced] — change it any time by asking Claude." (fill in the answer) · "Risky git commands (stash, add -A, commit -a, pull --rebase) are [blocked — on by default in team mode/not blocked — off in practice (Solo) mode; say "turn on the git guard" when you add more sessions] — change it any time by asking Claude." · and this line verbatim: **"You can change any of this — team size, names, permission mode, gate or deploy commands — at any time. Just ask Claude to change it."**
9. **Status HUD (optional) — ONE `AskUserQuestion`**, after the summary: "Install the status HUD? It draws every session's context fill, model and activity (plus host load) above the seat's prompt. Change it any time — just ask Claude." → **No (Recommended)** · **Yes**. Put the answer in `HUD=` and run (it needs the `claude` CLI; it installs for the default account and every logged-in `~/.claude-acctN`, and shows the HUD only in the seat named in the `team:` block):
   ```bash
   HUD=<yes|no>
   if [ "$HUD" != yes ]; then echo "SKIP status HUD (not installed; say \"install the status HUD\" any time)"; else
     SEAT=$(sed -nE 's/^[[:space:]]+seat:[[:space:]]*([^[:space:]#]+).*/\1/p' docs/orchestration/ORCHESTRATION.md | head -1)
     QF="${KIT_RUNTIME_DIR:-$HOME/.orchestration-kit/runtime}/quiet-mode"
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
10. **Offer the tour (last thing, whatever the HUD answer was)** — ask in plain text, one line: "Want the tour? `HOW-IT-WORKS.md` explains the whole loop in one diagram: the seat, the board, builders in their own worktrees, independent checks, trains, and every setting you can change." On Yes, give the link `https://github.com/Artekka/orcastration-kit/blob/main/HOW-IT-WORKS.md` (the same page ships as `docs/how-it-works.html` in the plugin) and summarize the loop in five lines. On No, say it stays linked from the README and `docs/GETTING-STARTED.md`.

## Rules

- Idempotent: never overwrite; re-running reports SKIP for everything that exists.
- The plugin ships its hooks itself — nothing to install in `.claude/settings.json`: SessionStart (fresh sessions are told to orient + send READY) PreToolUse `worktree-guard.sh` (a no-op unless `worktrees: enforced`) PreToolUse `git-guard.sh` on Bash (a no-op unless `git_guard: on`), and the context guard `ctx-guard.py` on PostToolUse + UserPromptSubmit (a no-op unless `ctx_guard: on`; needs `python3`). All run only in repos carrying `.kit-hooks`.
