# shellcheck shell=bash
# lib-git-retry.sh: retry a git network command (fetch, push, ls-remote against origin) on a TRANSIENT failure only.
# Why: a host's SSH daemon can deny two of three connections for hours. A merge script that tried a fetch twice and a push
# once was refused AFTER its checks had passed, and every refusal threw away a full check run.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib-git-retry.sh"
#
# git_net <prefix> <git args...>
#   Runs `git <args>` up to $GIT_NET_TRIES times (default 8). stdout passes straight through (a caller may capture it);
#   stderr is captured per attempt and then printed unchanged, so a caller's `2>/dev/null` still silences it.
#   A failure is retried ONLY when git_net_transient says so; any other failure returns at once with git's exit code.
#   Before retry k it prints "<prefix>: transient git failure, retry k/<tries-1>" to stderr and sleeps
#   k * $GIT_NET_BACKOFF_S seconds (default 2: 2+4+...+14 = 56 s over 8 tries; tests set 0). After the last transient
#   failure it prints "<prefix>: transient git failure, gave up after N tries" and returns git's code, so the caller's
#   existing refusal runs exactly as before.
# git_net_transient <stderr text>: 0 = transient (a connection or auth denial), 1 = not.
#   A rejection by the remote (non-fast-forward, fetch first, a hook, a protected ref) is NEVER transient, even when its
#   stderr also carries a connection line ("the remote end hung up"): retrying it as one would replay a lost race N times
#   instead of taking the caller's redo path, and would hammer a refusal that cannot change. A missing repository is not
#   transient either (hosts print "Repository not found" before "Could not read").

GIT_NET_PERMANENT_RE='\[rejected\]|\[remote rejected\]|non-fast-forward|\(fetch first\)|hook declined|protected branch|Repository not found|does not appear to be a git repository'
GIT_NET_TRANSIENT_RE='Permission denied \(publickey\)|Could not read from remote repository|Connection reset|Connection timed out|Connection closed by|Connection refused|kex_exchange_identification|ssh: connect to host|ssh_exchange_identification|the remote end hung up unexpectedly|Could not resolve hostname|Temporary failure in name resolution'

git_net_transient() {
  grep -qE "$GIT_NET_PERMANENT_RE" <<<"$1" && return 1
  grep -qE "$GIT_NET_TRANSIENT_RE" <<<"$1"
}

git_net() {
  local prefix=$1; shift
  local tries=${GIT_NET_TRIES:-8} backoff=${GIT_NET_BACKOFF_S:-2} k=1 rc err
  # Whole numbers only: a non-number in `[ -lt ]` is false and silently changes the loop.
  [[ "$tries" =~ ^[1-9][0-9]?$ ]] || { echo "$prefix: WARNING: ignoring GIT_NET_TRIES='$tries' (a whole number, 1-99); using 8" >&2; tries=8; }
  [[ "$backoff" =~ ^[0-9]{1,3}$ ]] || { echo "$prefix: WARNING: ignoring GIT_NET_BACKOFF_S='$backoff' (whole seconds, 0-999); using 2" >&2; backoff=2; }
  while :; do
    # stdout goes to fd 3 (the caller's stdout), stderr to $err. No temp file.
    { err=$(git "$@" 2>&1 1>&3 3>&-); rc=$?; } 3>&1
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    [ "$rc" = 0 ] && return 0
    git_net_transient "$err" || return "$rc"
    if [ "$k" -ge "$tries" ]; then
      echo "$prefix: transient git failure, gave up after $tries tries" >&2
      return "$rc"
    fi
    echo "$prefix: transient git failure, retry $k/$((tries - 1))" >&2
    sleep $((k * backoff))
    k=$((k + 1))
  done
}
