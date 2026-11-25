#!/usr/bin/env bash
# Tests for scripts/lib-git-retry.sh: a transient connection or auth denial is retried, a rejection by the remote never is.
# Run: bash tests/git-retry.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0; SANDBOXES=()
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
eq()  { if [ "$3" = "$2" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
cleanup() { local d; for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT
# shellcheck source=../scripts/lib-git-retry.sh
. "$ROOT/scripts/lib-git-retry.sh"

# 1. git_net_transient: connection and auth denials are transient
while IFS= read -r t; do
  git_net_transient "$t" && ok || bad "T1 should be transient: $t"
done <<'TXT'
git@host: Permission denied (publickey).
fatal: Could not read from remote repository.
ssh: connect to host h port 22: Connection timed out
Connection reset by 1.2.3.4 port 22
kex_exchange_identification: Connection closed by remote host
fatal: the remote end hung up unexpectedly
ssh: Could not resolve hostname h: Temporary failure in name resolution
TXT

# 2. a rejection or a missing repository is never transient, even when a connection line is in the same text
while IFS= read -r t; do
  git_net_transient "$t" && bad "T2 must NOT be transient: $t" || ok
done <<'TXT'
 ! [rejected]        main -> main (fetch first)
 ! [remote rejected] main -> main (hook declined)
 ! [rejected]        main -> main (non-fast-forward) fatal: the remote end hung up unexpectedly
remote: Repository not found. fatal: Could not read from remote repository.
error: failed to push: protected branch hook declined, Connection reset by peer
just some other failure
TXT

# 3. git_net: retries the transient failure, passes stdout through, stops at the bound
SB=$(mktemp -d); SANDBOXES+=("$SB"); mkdir -p "$SB/bin"
cat > "$SB/bin/git" <<STUB
#!/usr/bin/env bash
n=\$(cat "$SB/n" 2>/dev/null || echo 0); echo \$((n+1)) > "$SB/n"
if [ "\$n" -lt "\${FAILS:-0}" ]; then echo "\${FAILTEXT:-Permission denied (publickey).}" >&2; exit 128; fi
echo "stdout-of-git \$*"
STUB
chmod +x "$SB/bin/git"
export PATH="$SB/bin:$PATH" GIT_NET_BACKOFF_S=0
rm -f "$SB/n"; out=$(FAILS=2 git_net t fetch origin 2>"$SB/err"); rc=$?
eq "T3 succeeds after two transient failures" 0 "$rc"; eq "T3 stdout passes through" "stdout-of-git fetch origin" "$out"; eq "T3 three git calls" 3 "$(cat "$SB/n")"; has "T3 names retry 2" "t: transient git failure, retry 2/7" "$(cat "$SB/err")"
rm -f "$SB/n"; FAILS=99 GIT_NET_TRIES=3 git_net t push origin main >/dev/null 2>"$SB/err"; rc=$?
eq "T3 gives up with git's exit code" 128 "$rc"; eq "T3 three tries only" 3 "$(cat "$SB/n")"; has "T3 says gave up" "t: transient git failure, gave up after 3 tries" "$(cat "$SB/err")"
rm -f "$SB/n"; FAILS=99 FAILTEXT=" ! [rejected] main -> main (non-fast-forward)" git_net t push origin main >/dev/null 2>"$SB/err"; rc=$?
eq "T3 a rejection returns at once" 128 "$rc"; eq "T3 and runs git once" 1 "$(cat "$SB/n")"
# bad numbers fall back to the defaults with a warning
rm -f "$SB/n"; out=$(GIT_NET_TRIES=abc git_net t fetch 2>&1); has "T3 a bad GIT_NET_TRIES warns" "ignoring GIT_NET_TRIES='abc'" "$out"

echo "git-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
