#!/usr/bin/env bash
# Tests for the safety hooks' opt-in switch (hooks/lib/kitgate.py) and their wiring in hooks/hooks.json. Run: bash tests/hook-gate.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
. "$(dirname "$0")/lib-hook-test.sh"
command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || { echo "hook-gate: SKIP (no python3 or git)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G() { git -c user.email=t@example.com -c user.name=T -c core.hooksPath=/dev/null "$@"; }
HOOK="$ROOT/hooks/pkill-full-guard.py"
call() {  # call <cwd> -> the hook WITHOUT the test seam, for `pkill -f x`
  printf '%s' "$(mkjson Bash command 'pkill -f x' "$1")" | env -i PATH="$PATH" HOME="$HOME" python3 -I "$HOOK" >/dev/null 2>&1; echo "rc=$?"
}
R="$TMP/r"; G init -q -b main "$R"; mkdir -p "$R/docs/orchestration"; echo x > "$R/f"; G -C "$R" add f; G -C "$R" commit -q -m init
eq "no marker, no config: allowed" "rc=0" "$(call "$R")"
touch "$R/docs/orchestration/.kit-hooks"
eq "marker but no ORCHESTRATION.md: allowed" "rc=0" "$(call "$R")"
printf 'team:\n  safety_guards:    off\n' > "$R/docs/orchestration/ORCHESTRATION.md"; eq "safety_guards: off: allowed" "rc=0" "$(call "$R")"
printf 'team:\n  safety_guards:    on   # comment\n' > "$R/docs/orchestration/ORCHESTRATION.md"; eq "marker + safety_guards: on: refused" "rc=2" "$(call "$R")"
G -C "$R" worktree add -q -b wt "$TMP/wt"; eq "a linked worktree follows the MAIN checkout's setting" "rc=2" "$(call "$TMP/wt")"
printf 'team:\n  safety_guards:    onward\n' > "$R/docs/orchestration/ORCHESTRATION.md"; eq "a value that only starts with 'on': allowed" "rc=0" "$(call "$R")"
printf 'team:\n  safety_guards:    on\n' > "$R/docs/orchestration/ORCHESTRATION.md"; rm "$R/docs/orchestration/.kit-hooks"; eq "config on but no marker: allowed" "rc=0" "$(call "$R")"
eq "not a repo: allowed" "rc=0" "$(call "$TMP")"
eq "a cwd that does not exist: allowed" "rc=0" "$(call "$TMP/nope")"
# wiring: every hook script is registered, blocking hooks do not swallow their exit code, the file is valid JSON
python3 - "$ROOT" <<'PY' && ok || bad "hooks.json wiring (see above)"
import json, os, sys
root = sys.argv[1]
d = json.load(open(os.path.join(root, "hooks", "hooks.json")))
cmds = [h["command"] for ev in d["hooks"].values() for blk in ev for h in blk["hooks"]]
blocking = ("discard-guard", "pkill-full-guard", "prettier-dir-guard", "conflict-marker-guard", "sendmessage-sha-guard")
missing = [f for f in sorted(os.listdir(os.path.join(root, "hooks"))) if f.endswith((".py", ".sh")) and not any(f in c for c in cmds)]
if missing:
    print("not registered in hooks.json:", missing); sys.exit(1)
for n in blocking:
    c = [x for x in cmds if n in x]
    if len(c) != 1 or "|| true" in c[0] or "exec python3" not in c[0] or "command -v python3" not in c[0]:
        print("bad wiring for", n, c); sys.exit(1)
pre = d["hooks"]["PreToolUse"]
by = {b["matcher"]: [h["command"] for h in b["hooks"]] for b in pre}
if not any("sendmessage-sha-guard" in c for c in by.get("SendMessage", [])):
    print("sendmessage-sha-guard is not under the SendMessage matcher"); sys.exit(1)
PY
finish hook-gate
