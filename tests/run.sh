#!/usr/bin/env bash
# Run every kit test script: bash tests/run.sh   (no network; needs bash, git, awk; python3 for ctx tests)
cd "$(dirname "$0")" || exit 1
rc=0
for t in ./*.test.sh; do
  echo "== $t"
  env -u TMUX -u TMUX_PANE bash "$t" || rc=1   # a test never reaches the caller's tmux (no-real-tmux.test.sh)
done
# ---- status-hud: the optional HUD's own suite (TypeScript, run by the claude CLI; skipped without it)
if command -v claude >/dev/null 2>&1; then
  echo "== status-hud (claude plugin test)"
  claude plugin test ../plugins/status-hud || rc=1
else
  echo "== SKIP status-hud: the claude CLI is not on PATH (the HUD's suite runs with: claude plugin test plugins/status-hud)"
fi
# ----
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
