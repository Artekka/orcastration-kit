#!/usr/bin/env bash
# sync-main-checkout.sh: fast-forward the MAIN checkout to origin/main right after a push lands (a merge script, a board push).
# Why: pushes come from worktrees, so the shared checkout every session starts in sits far behind and every hook runs stale
# scripts. The seat's periodic poll was the only thing moving it.
#   bash scripts/sync-main-checkout.sh        (from any worktree or the main checkout)
# MAIN = the parent of the git common dir. The work is scripts/main-checkout-sync.sh's, pointed at MAIN: a no-op unless MAIN is on
# refs/heads/main (or mid rebase/merge); `merge --ff-only --no-overwrite-ignore` only, so git itself refuses over a dirty path;
# never stash, reset or touch a dirty file. Prints ONE line. Exit 0 always: a push that already landed must not fail because the
# checkout could not move.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -z "$common" ]; then echo "main-checkout: skip (not in a git checkout)"; exit 0; fi
MAIN="$(dirname "$common")"
out="$(MAIN_SYNC_REPO="$MAIN" bash "$here/main-checkout-sync.sh" 2>&1 | head -n 1)"
echo "${out:-main-checkout: skip (no result)}"
exit 0
