#!/usr/bin/env bash
# bottleneck-watch.sh: flags anything past its time budget. Run it at every seat poll.
# Why: a 4 h merge jam went unnoticed because the polls had no budgets. A poll that only asks "is anything wrong?" finds nothing
# wrong with a merge that has run for four hours; a budget turns "slow" into a flag.
#   bash scripts/bottleneck-watch.sh        (from the main checkout or any worktree of the repo)
# Exit 0 = nothing to act on; exit 3 = at least one OUTLIER line, act this poll; exit 1 = the process list could not be read.
# Read-only. It names the thing to CHECK and never orders a kill: the seat decides (a stale-looking gate can be a builder's live work).
#
# What it judges (each budget is in minutes; override with the env var):
#   seat-merge.sh process        BUDGET_MERGE (55)   also: it conflicts with origin/main (git merge-tree), or a stuck "zombie" parent
#   gate-throttle.sh running     BUDGET_GATE (70)    also: its worktree's branch is already on main, or origin/<branch> moved past it (stale)
#   gate-throttle.sh queued      BUDGET_GATE         the oldest waiter; fewer than that prints one info line
#   no merge on origin/main      BUDGET_NO_MERGE (90) the newest first-parent merge commit is older than that
#   a pane waiting on a permission prompt (tmux): that session cannot read a message; the line says how to look and what to do
#   free space on the disk of this checkout: under BUDGET_FREE_GB (20) GB
# Only processes whose cwd is inside a worktree of THIS repo count: a test fixture or another project's script is not yours.
#
# Test seams: BOTTLENECK_REPO (the repo, default: this script's), BOTTLENECK_PS_FILE (a file of `ps -eo pid=,ppid=,stat=,etimes=,args=`
# lines), BOTTLENECK_TMUX (replaces the tmux command), BOTTLENECK_FREE_GB (replaces df), BOTTLENECK_NO_FETCH=1 (skip the fetch).
# Tmux session scanned: RECYCLE_TMUX_SESSION, else the current tmux session when $TMUX is set, else the main checkout's directory name
# (the rule scripts/recycle-sibling.sh uses). No tmux, no server or no such session: one WARNING and no outlier.
# Every tmux call is bounded (BOTTLENECK_TMUX_TIMEOUT seconds, default 5): a stopped or hung tmux server must not hang the poll. A
# call that times out is one WARNING and no outlier, like a missing server.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BOTTLENECK_REPO:-$HERE}" || exit 1
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)") || exit 1
cd "$MAIN" || exit 1
MAIN=$(pwd -P)
BUDGET_MERGE=${BUDGET_MERGE:-55} BUDGET_GATE=${BUDGET_GATE:-70} BUDGET_NO_MERGE=${BUDGET_NO_MERGE:-90} BUDGET_FREE_GB=${BUDGET_FREE_GB:-20}
n=0
flag() { echo "OUTLIER: $*"; n=$((n + 1)); }
warn() { echo "WARNING: $*"; }
# A failed fetch leaves origin/main old, and every judgment below reads it: say so instead of judging quietly.
if [ "${BOTTLENECK_NO_FETCH:-}" != 1 ]; then
  git fetch -q origin 2>/dev/null || warn "git fetch origin failed; the judgments below read a possibly old origin/main."
fi
if [ -n "${BOTTLENECK_PS_FILE:-}" ]; then
  procs=$(cat "$BOTTLENECK_PS_FILE" 2>/dev/null) || { echo "bottleneck-watch: cannot read the process list" >&2; exit 1; }
else
  procs=$(ps -eo pid=,ppid=,stat=,etimes=,args= 2>/dev/null) || { echo "bottleneck-watch: cannot read the process list" >&2; exit 1; }
fi
# Scripts also start by absolute path (`bash /…/scripts/gate-throttle.sh`) or by their shebang (`/bin/bash /…/scripts/x.sh`):
# rewrite those rows to the relative form once, so every pattern and parent lookup below sees one shape.
procs=$(sed -E 's#^( *[0-9]+ +[0-9]+ +[A-Za-z+<]+ +[0-9]+ )(/[^ ]*/)?(bash|sh) +([^ ]*/)?scripts/#\1bash scripts/#' <<<"$procs")
cwd_of() { readlink "/proc/$1/cwd" 2>/dev/null; }
# The worktrees of this repo (the main checkout is the first entry).
wt_list=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
in_worktrees() {
  local c w; c=$(cwd_of "$1"); [ -n "$c" ] || return 1
  while IFS= read -r w; do [ -n "$w" ] || continue; case "$c" in "$w"|"$w"/*) return 0 ;; esac; done <<<"$wt_list"
  return 1
}
# True when no child of $1 does anything but sleep (a poll loop: the throttle queue, a merge yielding).
only_sleeps() { ! awk -v p="$1" '$2 == p && $5 != "sleep" { f = 1 } END { exit !f }' <<<"$procs"; }
state_of() { awk -v p="$1" '$1 == p { print $3; exit }' <<<"$procs"; }

# A gate on work that moved on holds a slot for nothing. Only a tree on a branch: a detached gate is on purpose.
stale_gate() {  # $1 = pid. Prints "<sha9>|<why>", or nothing.
  local cwd head br up
  cwd=$(cwd_of "$1"); [ -n "$cwd" ] || return 0
  br=$(git -C "$cwd" symbolic-ref -q --short HEAD 2>/dev/null) || return 0
  head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || return 0
  if git merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
    # A branch cut at main's tip, with no commits of its own yet, sits ON main's first-parent line and is not stale. Work that landed
    # through a merge commit (a --no-ff merge) is reachable from main but is not on that line.
    git rev-list --first-parent origin/main 2>/dev/null | grep -qx "$head" && return 0
    echo "${head:0:9}|$br is already on main"
    return 0
  fi
  up=$(git rev-parse -q --verify "refs/remotes/origin/$br") || return 0
  [ "$up" != "$head" ] && git merge-base --is-ancestor "$head" "$up" 2>/dev/null && echo "${head:0:9}|origin/$br moved past it"
  return 0
}

queued_oldest=0 queued_n=0 queued_pid="" poll_zombies=0
while read -r pid ppid stat secs args; do
  [ -n "${pid:-}" ] || continue
  min=$((secs / 60))
  case "$stat" in
    Z*)
      # A finished child nobody reaped. Under a stopped (SIGSTOPped) parent it never goes away, and a wait on it hangs forever.
      case "$(state_of "$ppid")" in
        T*)
          # A stopped chain's poll `sleep` is always a zombie while a front merge runs: that is the plan. Counted into one summary
          # line below; any other zombie under a stopped parent is still its own outlier.
          if [ "$args" = "[sleep] <defunct>" ]; then poll_zombies=$((poll_zombies + 1)); continue; fi
          flag "zombie pid $pid (${min} min) under stopped parent pid $ppid: a wait on it hangs. Check the parent; a SIGKILL of the parent reaps it and wakes what waits on it." ;;
      esac
      continue ;;
  esac
  case "$args" in
    "bash scripts/seat-merge.sh "*)
      # The child of a merge wrapper is the same merge: judge the outer one only.
      grep -qE "^ *$ppid +[0-9]+ +[A-Za-z+<]+ +[0-9]+ bash scripts/seat-merge\.sh " <<<"$procs" && continue
      in_worktrees "$pid" || continue
      set -- $args; branch=${3:-}; sha=${4:-}
      case "$branch" in trial-*) continue ;; esac   # a validator's replay on a throwaway origin, not a queue row
      if [ -n "$sha" ]; then
        mt=$(git merge-tree --write-tree --name-only origin/main "$sha" 2>/dev/null); rc=$?
        # Exit 1 with a tree id on stdout = conflicts. An unknown sha also exits 1, but prints no tree id: that is an error.
        if [ "$rc" = 1 ] && grep -qE '^[0-9a-f]{40,64}$' <<<"$(head -1 <<<"$mt")"; then
          real=$(sed -n '2,/^$/p' <<<"$mt" | grep -v '^$')
          flag "seat-merge pid $pid ($branch, ${min} min) conflicts with main on $(head -3 <<<"$real" | paste -sd, -): check it."
          continue
        elif [ "$rc" != 0 ]; then
          warn "git merge-tree could not judge seat-merge pid $pid ($branch): exit $rc (bad sha, or an error). No verdict on conflicts."
        fi
      fi
      [ "$min" -le "$BUDGET_MERGE" ] || flag "seat-merge pid $pid ($branch) at ${min} min, budget ${BUDGET_MERGE}." ;;
    "bash scripts/gate-throttle.sh"*)
      in_worktrees "$pid" || continue
      # A throttle that only sleeps is waiting for a slot; one with a command under it is running.
      if only_sleeps "$pid"; then
        queued_n=$((queued_n + 1))
        [ "$min" -le "$queued_oldest" ] || { queued_oldest=$min; queued_pid=$pid; }
        continue
      fi
      # The throttle's own parent being a throttle is a wrapper: judge the outer one.
      grep -qE "^ *$ppid +[0-9]+ +[A-Za-z+<]+ +[0-9]+ bash scripts/gate-throttle\.sh" <<<"$procs" && continue
      where="cwd $(cwd_of "$pid" | sed 's#.*/##')"
      found=$(stale_gate "$pid")
      if [ -n "$found" ]; then
        flag "gate pid $pid (${min} min, $where) on ${found%%|*} looks stale: ${found#*|}. Check it."
      elif [ "$min" -gt "$BUDGET_GATE" ]; then
        flag "gate pid $pid at ${min} min, budget ${BUDGET_GATE} ($where)."
      fi ;;
  esac
done <<<"$procs"

[ "$poll_zombies" -eq 0 ] || echo "bottleneck-watch: $poll_zombies poll-sleep zombie(s) under stopped parents (paused on purpose; they go away when it resumes them)."
if [ "$queued_n" -gt 0 ]; then
  if [ "$queued_oldest" -gt "$BUDGET_GATE" ]; then
    flag "$queued_n gate(s) queued in the throttle; the oldest (pid $queued_pid) has waited ${queued_oldest} min, budget ${BUDGET_GATE}."
  else
    echo "bottleneck-watch: $queued_n gate(s) queued in the throttle; oldest ${queued_oldest} min."
  fi
fi

# The clock reads every first-parent merge on main, whatever its subject: rows land as merge commits, and a subject is a convention.
last=$(git log origin/main --first-parent --merges -1 --format=%ct 2>/dev/null)
if [ -n "$last" ]; then
  age=$(( ($(date +%s) - last) / 60 ))
  [ "$age" -le "$BUDGET_NO_MERGE" ] || flag "no merge on main for ${age} min, budget ${BUDGET_NO_MERGE}."
  said="last merge ${age} min ago"
else
  said="no merge in this history"
fi

# shellcheck source=lib-prompt-dialog.sh
source "$HERE/lib-prompt-dialog.sh"
scan_prompt_panes() {
  local tmux_bin="${BOTTLENECK_TMUX:-tmux}" session tmo="${BOTTLENECK_TMUX_TIMEOUT:-5}" bound=""
  # `timeout` (GNU) or `gtimeout` (macOS coreutils); with neither, the calls run unbounded and the warning below says so.
  if command -v timeout >/dev/null 2>&1; then bound=timeout; elif command -v gtimeout >/dev/null 2>&1; then bound=gtimeout; fi
  tm() { if [ -n "$bound" ]; then "$bound" -k 1 "$tmo" "$tmux_bin" "$@"; else "$tmux_bin" "$@"; fi; }
  if ! command -v "$tmux_bin" >/dev/null 2>&1; then
    warn "tmux not found ($tmux_bin); panes were not scanned for permission prompts."
    return 0
  fi
  if [ -n "${RECYCLE_TMUX_SESSION:-}" ]; then session="$RECYCLE_TMUX_SESSION"
  elif [ -n "${TMUX:-}" ] && session=$(tm display-message -p '#S' 2>/dev/null) && [ -n "$session" ]; then :
  else session=$(basename "$MAIN" | tr '.:' '--')
  fi
  local hrc=0
  tm has-session -t "=$session" 2>/dev/null || hrc=$?
  if [ "$hrc" = 124 ] || [ "$hrc" = 137 ]; then
    warn "tmux did not answer within ${tmo}s (a stopped or hung server?); panes were not scanned for permission prompts."
    return 0
  elif [ "$hrc" != 0 ]; then
    warn "no tmux session '$session' (no server, or its socket is hidden); panes were not scanned for permission prompts."
    return 0
  fi
  [ -n "$bound" ] || warn "no timeout command: the tmux calls below are unbounded."
  local pid wid wname screen pat
  while IFS=$'\t' read -r pid wid wname; do
    [ -n "$pid" ] || continue
    # No -S/-E: capture-pane then prints the visible screen only, which is the point (an answered prompt scrolls away).
    screen=$(tm capture-pane -p -t "$pid" 2>/dev/null) || continue
    for pat in "${PROMPT_PATTERNS[@]}"; do
      if prompt_dialog "$pat" <<<"$screen"; then
        flag "window '$wname' ($wid, pane $pid) shows a permission prompt (\"$pat\"): that session cannot read a message. CHECK: tmux capture-pane -p -t $pid; answer it or tell the user. Nothing was sent."
        break
      fi
    done
  done < <(tm list-panes -s -t "=$session" -F $'#{pane_id}\t#{window_id}\t#{window_name}' 2>/dev/null)
}
scan_prompt_panes

free_gb="${BOTTLENECK_FREE_GB:-$(df -Pk "$MAIN" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')}"
if [[ "$free_gb" =~ ^[0-9]+$ ]]; then
  [ "$free_gb" -ge "$BUDGET_FREE_GB" ] || flag "free space is $free_gb GB (limit $BUDGET_FREE_GB GB). CHECK: bash scripts/retro-worktrees.sh --dry-run and bash scripts/docker-cache-cap.sh --dry-run; nothing was changed."
else
  warn "free space could not be read; the disk alarm did not run."
fi

echo "bottleneck-watch: $n outlier(s); $said"
[ "$n" -eq 0 ] || exit 3
