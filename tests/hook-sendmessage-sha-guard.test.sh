#!/usr/bin/env bash
# Tests for hooks/sendmessage-sha-guard.py: a message that names a sha git cannot resolve is refused; real commit, tree and blob
# shas, refs in brackets, ids, paths and color codes pass. Run: bash tests/hook-sendmessage-sha-guard.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
. "$(dirname "$0")/lib-hook-test.sh"
command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || { echo "hook-sendmessage-sha-guard: SKIP (no python3 or git)"; exit 0; }
H="$ROOT/hooks/sendmessage-sha-guard.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G() { git -c user.email=t@example.com -c user.name=T -c core.hooksPath=/dev/null "$@"; }
G init -q -b main "$TMP/repo"; echo hello > "$TMP/repo/a.txt"; G -C "$TMP/repo" add a.txt; G -C "$TMP/repo" commit -q -m init
SHA="$(G -C "$TMP/repo" rev-parse HEAD)"; SHORT="${SHA:0:10}"
TREE="$(G -C "$TMP/repo" rev-parse 'HEAD^{tree}')"; BLOB="$(G -C "$TMP/repo" rev-parse HEAD:a.txt)"
FAKE=deadbee1234   # holds a letter and a digit, resolves to nothing
msg() { feed "$H" "$(mkjson SendMessage message "$1" "$TMP/repo")"; }
for m in "tip $FAKE is green" "a..$FAKE" "$FAKE" "see $SHORT and $FAKE"; do has "refuses: $m" "rc=2" "$(msg "$m")"; done
out="$(msg "see $SHORT and $FAKE")"; has "names the failing token" "$FAKE" "$out"; case "$out" in *"$SHORT"*) bad "named the good token too" ;; *) ok ;; esac
for m in "tip $SHA" "tip $SHORT" "tree ${TREE:0:10}" "blob ${BLOB:0:10}" "ref [$FAKE]" "session deadbee1" "session id: deadbee1" "job deadbee1" \
         "path src/$FAKE/x" "file.$FAKE" "color #FF00FF" "uuid 3fa85f64-5717-4562-b3fc-2c963f66afa6" "no hex here" "deadbeef" "1234567" "word facade1"; do
  out="$(msg "$m")"; if [ "$m" = "word facade1" ]; then has "passes or refuses cleanly: $m" "rc=" "$out"; else eq "passes: $m" "rc=0 " "$out"; fi
done
eq "a non-SendMessage tool passes" "rc=0 " "$(feed "$H" "$(mkjson Bash command "echo $FAKE" "$TMP/repo")")"
for stdin in 'not json' '' '{}' '{"tool_name":"SendMessage","tool_input":{}}'; do eq "fail open on [$stdin]" "rc=0 " "$(feed "$H" "$stdin")"; done
eq "a cwd that is not a repo fails open" "rc=0 " "$(feed "$H" "$(mkjson SendMessage message "tip $FAKE" "$TMP")")"
eq "no git on PATH fails open" "rc=0 " "$(printf '%s' "$(mkjson SendMessage message "tip $FAKE" "$TMP/repo")" | env -i PATH=/nonexistent HOME="$HOME" KIT_HOOKS_CHECK_ONLY=1 "$(command -v python3)" -I "$H" >/dev/null 2>&1; echo "rc=$? ")"
finish hook-sendmessage-sha-guard
