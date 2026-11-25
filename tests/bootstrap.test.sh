#!/usr/bin/env bash
# Tests for scripts/bootstrap.sh: dry-run touches nothing, a second run is a no-op, live files
# are never overwritten. HOME is sandboxed so the memory-starter step writes into the temp dir.
# Run: bash tests/bootstrap.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; BS="$ROOT/scripts/bootstrap.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL $*"; }
snap() { (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs cksum); }
P="$TMP/proj/app"   # parent does not exist yet: the bare-directory case

out="$(bash "$BS" "$P" --dry-run 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok || bad "dry-run exit $rc"
[ ! -e "$TMP/proj" ] && ok || bad "dry-run created the target"
[ ! -e "$HOME/.claude" ] && ok || bad "dry-run created the memory dir"
echo "$out" | grep -q '^\[bootstrap\] CREATE docs/orchestration/AGENT_BOARD.md' && ok || bad "dry-run did not list the board"
echo "$out" | grep -q 'DONE' && ok || bad "dry-run plan truncated (no DONE line)"

out="$(bash "$BS" "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok || bad "first run exit $rc: $out"
for f in docs/orchestration/AGENT_BOARD.md docs/orchestration/ORCHESTRATION.md CLAUDE.md docs/AI_CONTEXT.md \
         docs/timeline/build-log.md scripts/ctx-fill.py scripts/statusline-ctx.sh scripts/gate-throttle.sh scripts/quiet-mode.sh scripts/seat-merge.sh scripts/lib-waiting-tickets.sh scripts/lib-builder-worktree.sh scripts/pending-work.sh scripts/tmux-session.sh scripts/tmux/agents.tmux.conf scripts/sibling-shell.sh scripts/retro-worktrees.sh scripts/docker-cache-cap.sh scripts/gate-disk-guard.sh scripts/bottleneck-watch.sh scripts/lib-prompt-dialog.sh scripts/main-checkout-sync.sh scripts/sync-main-checkout.sh scripts/launched_window.py scripts/lib-git-retry.sh scripts/lib-conflict-markers.sh scripts/lib-mono-clock.sh .claude/agents/verifier.md \
         .claude/skills/orchestrate/SKILL.md .claude/skills/falsify/SKILL.md .claude/skills/orient-brief/brief.sh \
         docs/orchestration/briefs/README.md docs/orchestration/briefs/_TEMPLATE.md \
         docs/orchestration/CLAUDE-slimness.md; do
  [ -f "$P/$f" ] && ok || bad "first run did not create $f"
done
# F6: the CLAUDE.md section tells every adopter to keep the file slim and points at the
# slimness note, so the note must exist at the path the section names IN THE ADOPTING PROJECT.
ptr="$(grep -o 'docs/orchestration/CLAUDE-slimness.md' "$P/CLAUDE.md" | head -1)"
[ "$ptr" = docs/orchestration/CLAUDE-slimness.md ] && ok || bad "installed CLAUDE.md does not point at docs/orchestration/CLAUDE-slimness.md"
grep -q 'templates/CLAUDE-slimness.md' "$P/CLAUDE.md" && bad "installed CLAUDE.md points at the kit-only path templates/CLAUDE-slimness.md" || ok
# a dry run lists it, and kit-init's copy block installs it too
bash "$BS" "$TMP/dry2" --dry-run 2>&1 | grep -q '^\[bootstrap\] CREATE docs/orchestration/CLAUDE-slimness.md' && ok || bad "dry-run did not list CLAUDE-slimness.md"
grep -q 'CLAUDE-slimness.md' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install CLAUDE-slimness.md"
grep -q 'templates/CLAUDE-slimness.md:docs/orchestration/CLAUDE-slimness.md' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init put line for CLAUDE-slimness.md missing or wrong destination"
# a live copy is never overwritten
echo "# my slimness note" > "$P/docs/orchestration/CLAUDE-slimness.md"
bash "$BS" "$P" >/dev/null 2>&1
[ "$(cat "$P/docs/orchestration/CLAUDE-slimness.md")" = "# my slimness note" ] && ok || bad "a live CLAUDE-slimness.md was overwritten"
cp "$ROOT/templates/CLAUDE-slimness.md" "$P/docs/orchestration/CLAUDE-slimness.md"
[ -x "$P/scripts/start-team.sh" ] && ok || bad "start-team.sh not executable"
[ -x "$P/scripts/seat-merge.sh" ] && ok || bad "seat-merge.sh not executable"
# seat-merge sources its two libs from its own directory, so all three must travel together
for lib in lib-waiting-tickets.sh lib-builder-worktree.sh lib-git-retry.sh lib-conflict-markers.sh lib-mono-clock.sh; do
  grep -q "$lib" "$ROOT/scripts/seat-merge.sh" && ok || bad "seat-merge.sh no longer sources $lib (update this pin)"
  grep -q "quiet-mode.sh .*$lib" "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install $lib"
  bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q "^\\[bootstrap\\] CREATE scripts/$lib" && ok || bad "dry-run did not list $lib"
done
grep -q 'seat-merge.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install seat-merge.sh"
# tmux-session.sh loads scripts/tmux/agents.tmux.conf from its own directory, so the two travel together
[ -x "$P/scripts/tmux-session.sh" ] && ok || bad "tmux-session.sh not executable"
grep -q 'tmux/agents.tmux.conf' "$ROOT/scripts/tmux-session.sh" && ok || bad "tmux-session.sh no longer loads tmux/agents.tmux.conf (update this pin)"
bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q '^\[bootstrap\] CREATE scripts/tmux-session.sh' && ok || bad "dry-run did not list tmux-session.sh"
bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q '^\[bootstrap\] CREATE scripts/tmux/agents.tmux.conf' && ok || bad "dry-run did not list tmux/agents.tmux.conf"
cmp -s "$ROOT/scripts/tmux/agents.tmux.conf" "$P/scripts/tmux/agents.tmux.conf" && ok || bad "installed agents.tmux.conf differs from the kit's"
grep -q 'tmux-session.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install tmux-session.sh"
grep -q 'for f in .*tmux/agents.tmux.conf.*; do SRC="\$K/scripts/\$f"' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install scripts/tmux/agents.tmux.conf"
grep -q 'chmod +x .*scripts/tmux-session.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not chmod tmux-session.sh"
# sibling-shell.sh: tmux-session.sh --seat and the in-place recycle both run "$script_dir/sibling-shell.sh"
grep -q 'sibling-shell.sh' "$ROOT/scripts/tmux-session.sh" && ok || bad "tmux-session.sh no longer runs sibling-shell.sh (update this pin)"
grep -q 'sibling-shell.sh' "$ROOT/scripts/recycle-sibling.sh" && ok || bad "recycle-sibling.sh no longer uses sibling-shell.sh (update this pin)"
[ -x "$P/scripts/sibling-shell.sh" ] && ok || bad "sibling-shell.sh not executable"
bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q '^\[bootstrap\] CREATE scripts/sibling-shell.sh' && ok || bad "dry-run did not list sibling-shell.sh"
grep -q 'pending-work.sh tmux-session.sh tmux/agents.tmux.conf sibling-shell.sh retro-worktrees.sh docker-cache-cap.sh gate-disk-guard.sh bottleneck-watch.sh lib-prompt-dialog.sh main-checkout-sync.sh sync-main-checkout.sh launched_window.py lib-model-tag.sh lib-git-retry.sh lib-conflict-markers.sh lib-mono-clock.sh; do SRC' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install sibling-shell.sh"
grep -q 'chmod +x .*scripts/sibling-shell.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not chmod sibling-shell.sh"
# lib-model-tag.sh is sourced from its own directory by lib-launch.sh and sibling-shell.sh: it must install with them
[ -f "$P/scripts/lib-model-tag.sh" ] && ok || bad "lib-model-tag.sh was not installed"
bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q '^\[bootstrap\] CREATE scripts/lib-model-tag.sh' && ok || bad "dry-run did not list lib-model-tag.sh"
# bottleneck-watch.sh sources lib-prompt-dialog.sh from its own directory; sync-main-checkout.sh runs main-checkout-sync.sh from its;
# ctx-fill.py imports launched_window.py from its: each group travels together and the scripts are executable
for f in bottleneck-watch.sh main-checkout-sync.sh sync-main-checkout.sh launched_window.py; do
  [ -x "$P/scripts/$f" ] && ok || bad "$f not executable"
  bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q "^\[bootstrap\] CREATE scripts/$f" && ok || bad "dry-run did not list $f"
done
# pending-work.sh is one file (its python is inline), installed and made executable by both paths
[ -x "$P/scripts/pending-work.sh" ] && ok || bad "pending-work.sh not executable"
bash "$BS" "$TMP/dry3" --dry-run 2>&1 | grep -q '^\[bootstrap\] CREATE scripts/pending-work.sh' && ok || bad "dry-run did not list pending-work.sh"
grep -q 'quiet-mode.sh .*pending-work.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not install pending-work.sh"
grep -q 'chmod +x .*scripts/pending-work.sh' "$ROOT/skills/kit-init/SKILL.md" && ok || bad "kit-init does not chmod pending-work.sh"
[ -d "$P/.git" ] && ok || bad "no git repo"
ls "$HOME"/.claude/projects/*/memory/MEMORY.md >/dev/null 2>&1 && ok || bad "memory starter index not written"
[ ! -e "$P/.claude/agents/architect.md" ] && ok || bad "team agents installed without --with-team-agents"

before="$(snap "$P")"
out="$(bash "$BS" "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok || bad "second run exit $rc"
echo "$out" | grep -q 'CREATE' && bad "second run created something: $(echo "$out" | grep CREATE | head -3)" || ok
[ "$before" = "$(snap "$P")" ] && ok || bad "second run changed files"

echo "# my live board" > "$P/docs/orchestration/AGENT_BOARD.md"
bash "$BS" "$P" >/dev/null 2>&1
[ "$(cat "$P/docs/orchestration/AGENT_BOARD.md")" = "# my live board" ] && ok || bad "a live file was overwritten"

before="$(snap "$P")"
bash "$BS" "$P" --dry-run --with-team-agents >/dev/null 2>&1
[ "$before" = "$(snap "$P")" ] && ok || bad "dry-run on an existing project changed files"

# 0.17.0 plugin-id rename: a fresh install writes the new managed marker, and a project still carrying the 0.16
# marker is recognized (SKIP + diff, never a second section appended), and the scripts' state-home lib travels with them.
OLDM="<!-- orch""estration-kit v0.8.0 — managed section; upgrades diff against this marker -->"
head -1 "$P/CLAUDE.md" | grep -q '^<!-- orcastration-kit v' && ok || bad "a fresh CLAUDE.md does not open with the orcastration-kit marker"
[ -f "$P/scripts/lib-kit-home.sh" ] && ok || bad "first run did not create scripts/lib-kit-home.sh"
P16="$TMP/p16"; mkdir -p "$P16"; printf '%s\n## Multi-session orchestration\n' "$OLDM" > "$P16/CLAUDE.md"
out="$(bash "$BS" "$P16" 2>&1)"
echo "$out" | grep -q 'SKIP  CLAUDE.md section' && ok || bad "a 0.16-marker CLAUDE.md is not recognized as the kit section: $(echo "$out" | grep CLAUDE.md)"
echo "$out" | grep -q 'NOTE  CLAUDE.md exists WITHOUT' && bad "a 0.16-marker CLAUDE.md is reported as having no kit section" || ok
bash "$BS" "$P" --bogus >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok || bad "unknown flag exit $rc (want 2)"

echo "bootstrap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
