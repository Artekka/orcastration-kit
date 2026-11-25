---
name: feedback_multisession_board_orchestration_default
description: Run substantial work through the multi-session claimable AGENT_BOARD workflow (orcastration-kit) by default
metadata:
  type: feedback
---

The default for substantial work: a **shared claimable board**
(`docs/orchestration/AGENT_BOARD.md`) coordinating several Claude Code sessions, each working in
its own worktree with file fences, independent verification at hand-offs, one-at-a-time
reconciles, and an exclusive deploy slot.

**Why:** three concurrent sessions partitioned ~15 workstreams in one evening without a single
file collision; the board made claims, fences and status visible across sessions.

**How to apply:**
- At session start on a substantial task list, orient, read the board (the protocol lives in the
  file), claim rows by a committed + pushed edit, build in your own worktree, get a
  sibling-session verification before reconcile, reconcile one at a time, deploy via the slot.
- Never `git stash` in a worktree (stash refs are shared across worktrees).
- The orcastration-kit plugin carries the whole workflow; its CHANGELOG tracks the version.
