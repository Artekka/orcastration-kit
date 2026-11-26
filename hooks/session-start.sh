#!/usr/bin/env bash
# SessionStart hook (orcastration-kit). Fires on fresh sessions only (matcher startup|clear;
# resume/compact re-entries are skipped by hooks.json).
#
# NO-OP (exit 0, no output) unless the session's repo carries the opt-in marker
# docs/orchestration/.kit-hooks (written by kit-init). A board alone is NOT enough: a repo can run
# its own orchestration workflow, and a user-scope install must never nag a project that didn't opt in.
# Deliberately no set -e: a hook must never fail a session start.

input="$(cat 2>/dev/null || true)"
dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$dir" ]; then
  dir="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "$dir" ] || dir="$PWD"
[ -d "$dir" ] || exit 0
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
[ -f "$top/docs/orchestration/.kit-hooks" ] || exit 0

msg="This repo uses the orcastration-kit multi-session workflow. Before any other work, run /orcastration-kit:orient. Then check the top of docs/orchestration/AGENT_BOARD.md for an ORCHESTRATOR ACTIVE banner: if one names ANOTHER session as the seat, end orientation by sending that seat a READY signal (SendMessage) and wait for its assignment instead of asking the user for work; route any question or approval to the seat. If you were launched as the seat (/orcastration-kit:orchestrate), take or resume the seat per that skill."
# The scheduled disk sweep (scripts/disk-sweep-cron.sh): started here in the background at most once a day, or under the
# free-space floor. The hook never waits for it and never fails because of it. The first run on a machine is a dry run, and the
# next session start shows its report to the user (systemMessage), once.
user_msg=""
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
if [ -n "$root" ] && [ -f "$root/scripts/lib-disk-sweep-launch.sh" ] && [ -f "$root/scripts/lib-kit-home.sh" ]; then
  user_msg="$(
    . "$root/scripts/lib-kit-home.sh" 2>/dev/null && . "$root/scripts/lib-disk-sweep-launch.sh" 2>/dev/null || exit 0
    kh="$(kit_home 2>/dev/null)" || exit 0
    off="bash \"$root/scripts/disk-sweep.sh\" --off"
    m=""
    if [ -f "$kh/disk-sweep/unseen-report" ]; then
      rep="$(head -n1 "$kh/disk-sweep/unseen-report" 2>/dev/null)"; mode="$(sed -n 2p "$kh/disk-sweep/unseen-report" 2>/dev/null)"
      mv -f "$kh/disk-sweep/unseen-report" "$kh/disk-sweep/seen-report" 2>/dev/null || rm -f "$kh/disk-sweep/unseen-report"
      if [ "$mode" = --dry-run ]; then
        m="Disk sweep: its first run was a dry run and removed nothing. Report: $rep. From the next run it removes what such a report lists (idle merged worktrees, old build output, browser leftovers; dirty work is saved first). Turn it off: $off"
      else
        m="Disk sweep: some items need a decision. Report: $rep. Turn the sweep off: $off"
      fi
    fi
    disk_sweep_launch_if_due "$top" >/dev/null 2>&1; rc=$?
    main="$(disk_sweep_main "$top" 2>/dev/null)"
    if [ "$rc" = 0 ] && [ ! -e "$(disk_sweep_first_marker "$kh" "${main:-$top}")" ]; then
      m="${m:+$m }Disk sweep is on: a background dry run started now (nothing is removed on the first run; its report shows at your next session start). After that it runs at most once a day at low priority. Turn it off: $off"
    fi
    printf '%s' "$m"
  ) 2>/dev/null" || user_msg=""
fi
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  '; }
if [ -n "$user_msg" ]; then
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s %s"}}\n' "$(esc "$user_msg")" "$msg" "$(esc "$user_msg")"
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
fi
exit 0
