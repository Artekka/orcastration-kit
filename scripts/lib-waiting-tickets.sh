#!/usr/bin/env bash
# lib-waiting-tickets.sh — the waiting-ticket protocol between a pusher and scripts/seat-merge.sh (sourced; defines functions only).
# Cause (in the project this came from): back-to-back merges kept their lock for 45 min, so a push that retried every 30 s
# never got in. A pusher that wants in keeps a ticket, <runtime>/seat-merge/<tool>-<pid>.waiting, from the moment it reaches the
# lock check until it exits. A seat-merge about to start reads the tickets and yields (bounded; see seat-merge.sh), so the waiting
# pusher goes before the next merge. A ticket whose owner is gone is ignored and removed: the owner must be a live process whose
# command line names <tool> (a reused pid does not count), and the ticket is `<pid> <starttime>` whose starttime must equal the live
# process's. The ticket is never a lock; the flock in seat-merge.sh stays the only mutual exclusion.
#
# A pusher writes its ticket like this (bash):  echo "$$ $(sed -n 's/.*) //p' /proc/$$/stat | awk '{print $20}')" > "$dir/<tool>-$$.waiting"
# and removes it on exit (trap). A ticket with only a pid is accepted when the process started before the ticket was written.

# ticket_starttime <pid>: field 22 of /proc/<pid>/stat = the process start in clock ticks since boot. A reused pid has another
# starttime. Empty when the process is gone. The comm field (2) may hold spaces and parens, so cut at the LAST ") " and take
# the 20th field after it.
ticket_starttime() {
  sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}
# ticket_started_before <pid> <ticket>: the pid-only form. A name match alone is not an identity (a reused pid running
# `tail <tool>.log` would hold a merge for the whole bound). The real owner started BEFORE it wrote its ticket, so the process
# start time (now - etimes) must not be after the ticket's mtime; one second of slack covers etimes rounding down.
ticket_started_before() {
  local pid=$1 ticket=$2 age mtime
  age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -dc '0-9')
  mtime=$(stat -c %Y "$ticket" 2>/dev/null)
  [ -n "$age" ] && [ -n "$mtime" ] && [ $(($(date +%s) - age)) -le $((mtime + 1)) ]
}
# ticket_owner_ok <pid> <starttime|""> <ticket> <tool>: is this ticket's owner the live <tool> process that wrote it?
ticket_owner_ok() {
  local pid=$1 start=$2 ticket=$3 tool=$4
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$tool" || return 1
  if [ -n "$start" ]; then
    [ "$(ticket_starttime "$pid")" = "$start" ]
  else
    ticket_started_before "$pid" "$ticket"
  fi
}
# waiting_tickets <dir>: print the pid of every live waiting pusher, one per line; remove the tickets of dead ones.
waiting_tickets() {
  local dir=$1 f pid start tool
  for f in "$dir"/*-*.waiting; do
    [ -e "$f" ] || continue
    tool=$(basename "$f" .waiting); tool=${tool%-*}   # <tool>-<pid>.waiting
    pid="" start=""
    read -r pid start _ <"$f" 2>/dev/null || true
    pid=$(tr -dc '0-9' <<<"$pid")
    start=$(tr -dc '0-9' <<<"$start")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ticket_owner_ok "$pid" "$start" "$f" "$tool"; then
      echo "$pid"
    else
      rm -f "$f"
    fi
  done
}
