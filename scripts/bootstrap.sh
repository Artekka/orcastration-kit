#!/usr/bin/env bash
# orchestration-kit bootstrap — spin a directory up as a kit-adopted project.
#
# Usage: bash bootstrap.sh <target-dir> [--dry-run] [--with-team-agents]
#
# IDEMPOTENT by the kit-init rule: a file is written ONLY if missing (a live
# board/overlay/CLAUDE.md is state, not scaffolding). Re-running is safe and
# reports SKIP for everything that already exists. --dry-run prints every
# action (MKDIR/INIT/CREATE/SKIP) without touching the filesystem.
#
# NOT installed by this script (deliberately):
#   - the autoCompact setting — user config; the bootstrap-project SKILL offers
#     it approval-gated from templates/settings-snippets.md. (The SessionStart
#     hook ships with the plugin itself.)
#   - plugins — user-level; see README "Assumed plugins".
#   - team agents — only with --with-team-agents (user-level defs take
#     precedence; project copies are for machines/collaborators without them).
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: bootstrap.sh <target-dir> [--dry-run] [--with-team-agents]}"
DRY=0; TEAM=0
for arg in "${@:2}"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --with-team-agents) TEAM=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "[bootstrap] $*"; }
run() { if [ "$DRY" -eq 1 ]; then say "DRY: $*"; else "$@"; fi; }

# install <src-relative-to-kit> <dst-relative-to-target>
install_if_missing() {
  local src="$KIT_ROOT/$1" dst="$TARGET/$2"
  if [ -e "$dst" ]; then
    say "SKIP  $2 (exists — live files are never overwritten)"
  else
    say "CREATE $2"
    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
  fi
}

# ── 1. Directory + git ──────────────────────────────────────────────────────
if [ ! -d "$TARGET" ]; then say "MKDIR $TARGET"; run mkdir -p "$TARGET"; fi
if [ ! -d "$TARGET/.git" ]; then say "INIT  git repository"; run git -C "$TARGET" init -q; else say "SKIP  git init (repo exists)"; fi

# ── 2. Board + overlay + CLAUDE starter ─────────────────────────────────────
install_if_missing templates/AGENT_BOARD.md docs/orchestration/AGENT_BOARD.md
install_if_missing templates/ORCHESTRATION.md docs/orchestration/ORCHESTRATION.md
install_if_missing templates/briefs/README.md docs/orchestration/briefs/README.md
install_if_missing templates/briefs/_TEMPLATE.md docs/orchestration/briefs/_TEMPLATE.md
install_if_missing templates/CLAUDE-slimness.md docs/orchestration/CLAUDE-slimness.md
if [ -e "$TARGET/CLAUDE.md" ]; then
  if grep -q "orchestration-kit v" "$TARGET/CLAUDE.md" 2>/dev/null; then
    say "SKIP  CLAUDE.md section (managed marker present — upgrades diff, not clobber)"
  else
    say "NOTE  CLAUDE.md exists WITHOUT the kit section — offer templates/CLAUDE-section.md as an APPEND (human approval), never overwrite"
  fi
else
  install_if_missing templates/CLAUDE-section.md CLAUDE.md
fi

# ── 2b. Session scripts (context measurement + sibling recycling) ────────────
for f in lib-launch.sh start-team.sh recycle-sibling.sh ctx-fill.py statusline-ctx.sh gate-throttle.sh quiet-mode.sh seat-merge.sh lib-waiting-tickets.sh lib-builder-worktree.sh pending-work.sh tmux-session.sh tmux/agents.tmux.conf sibling-shell.sh retro-worktrees.sh docker-cache-cap.sh gate-disk-guard.sh; do
  install_if_missing "scripts/$f" "scripts/$f"
done
[ "$DRY" -eq 1 ] || chmod +x "$TARGET"/scripts/{start-team.sh,recycle-sibling.sh,ctx-fill.py,statusline-ctx.sh,gate-throttle.sh,quiet-mode.sh,seat-merge.sh,pending-work.sh,tmux-session.sh,sibling-shell.sh,retro-worktrees.sh,docker-cache-cap.sh,gate-disk-guard.sh}

# ── 2c. Institutional-memory docs (status doc + append-only log) ─────────────
install_if_missing templates/AI_CONTEXT.md docs/AI_CONTEXT.md
install_if_missing templates/build-log.md docs/timeline/build-log.md

# ── 3. Skills (orchestration core only — extras/ stay opt-in) ───────────────
for s in "$KIT_ROOT"/skills/*/; do
  name="$(basename "$s")"
  install_if_missing "skills/$name/SKILL.md" ".claude/skills/$name/SKILL.md"
  for f in "$s"*; do   # a skill's helper files (e.g. orient-brief/brief.sh) travel with it
    case "$(basename "$f")" in SKILL.md) ;; *) [ -f "$f" ] && install_if_missing "skills/$name/$(basename "$f")" ".claude/skills/$name/$(basename "$f")" ;; esac
  done
done

# ── 4. Agents ───────────────────────────────────────────────────────────────
install_if_missing agents/verifier.md .claude/agents/verifier.md
if [ "$TEAM" -eq 1 ]; then
  for a in "$KIT_ROOT"/templates/agents/*.md; do
    install_if_missing "templates/agents/$(basename "$a")" ".claude/agents/$(basename "$a")"
  done
else
  say "SKIP  team agents (pass --with-team-agents; user-level defs take precedence anyway)"
fi

# ── 5. Memory starter ───────────────────────────────────────────────────────
# Seeds the agnostic starter into the project's home memory store only if that
# store does not exist yet (an existing store is live state).
# -m: resolve without requiring the path to exist — a dry run into a target
# whose PARENT doesn't exist yet is the flagship bare-directory case, and a
# bare `realpath` dies there (truncating the printed plan under set -e).
MEMDIR="$HOME/.claude/projects/$(realpath -m "$TARGET" | sed 's|/|-|g')/memory"
if [ -d "$MEMDIR" ]; then
  say "SKIP  memory starter ($MEMDIR exists — live store)"
else
  say "CREATE memory starter → $MEMDIR ($(find "$KIT_ROOT/templates/memory-starter" -name 'feedback_*.md' | wc -l) curated memories + a generated index)"
  run mkdir -p "$MEMDIR"
  if [ "$DRY" -eq 0 ]; then
    cp "$KIT_ROOT"/templates/memory-starter/feedback_*.md "$MEMDIR/"
    {
      echo "# Memory index (seeded by orchestration-kit bootstrap)"
      echo
      for f in "$MEMDIR"/feedback_*.md; do
        desc="$(grep -m1 '^description:' "$f" | sed 's/^description: //')"
        echo "- [$(basename "$f" .md)]($(basename "$f")) — $desc"
      done
    } > "$MEMDIR/MEMORY.md"
  fi
fi

# ── 6. Close ────────────────────────────────────────────────────────────────
say "DONE. Not installed by design: the autoCompact setting (templates/settings-snippets.md — approval-gated), plugins (user-level), extras/ (opt-in)."
say "Next: fill docs/orchestration/ORCHESTRATION.md (gate, classes, deploy, locked) WITH the human — never guess a gate."
