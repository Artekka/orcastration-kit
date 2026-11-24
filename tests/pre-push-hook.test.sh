#!/usr/bin/env bash
# Tests for the opt-in pre-push secret scan (.github/hooks/): the installer never replaces a different
# hook without --force, honors core.hooksPath and uninstalls only its own hook; the hook passes the right
# commit range to gitleaks, stops the push on a finding, on a missing gitleaks, and on a leak-guard red.
# gitleaks is a stub here (it records its arguments), so the test needs no network and no real gitleaks.
# Run: bash tests/pre-push-hook.test.sh   (needs bash, git)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/.github/hooks/install-pre-push.sh"
HOOK_SRC="$ROOT/.github/hooks/pre-push"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-hook.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
# Isolate from the user's git config (a global core.hooksPath would change where hooks live).
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$SB/gitconfig"
printf '[user]\n\tname = Test\n\temail = t@example.com\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
mkdir -p "$SB/bin"
cat > "$SB/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
EOF
chmod +x "$SB/bin/gitleaks"
export STUB_LOG="$SB/gitleaks.args"
BASE_PATH="$PATH"

git init -q --bare "$SB/remote.git"
git init -q "$SB/repo"; cd "$SB/repo" || exit 1
git remote add origin "$SB/remote.git"
echo one > a.txt; git add a.txt; git commit -qm one
HOOKS="$(git rev-parse --path-format=absolute --git-path hooks)"

# ---- installer --------------------------------------------------------------------------------------
out="$(bash "$INSTALL" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok || bad "install: exit $rc ($out)"
cmp -s "$HOOK_SRC" "$HOOKS/pre-push" && ok || bad "install: the hook is not a copy of .github/hooks/pre-push"
[ -x "$HOOKS/pre-push" ] && ok || bad "install: the hook is not executable"
out="$(bash "$INSTALL" 2>&1)"; [ $? = 0 ] && ok || bad "install twice: not idempotent ($out)"
printf '#!/bin/sh\necho mine\n' > "$HOOKS/pre-push"
out="$(bash "$INSTALL" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok || bad "a different hook exists: want exit 1, got $rc"
has "a different hook exists: says how to replace it" "--force" "$out"
grep -q 'echo mine' "$HOOKS/pre-push" && ok || bad "a different hook exists: it was changed without --force"
out="$(bash "$INSTALL" --uninstall 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'echo mine' "$HOOKS/pre-push" && ok || bad "uninstall removed a hook that is not ours (exit $rc)"
out="$(bash "$INSTALL" --force 2>&1)"; rc=$?
[ "$rc" = 0 ] && cmp -s "$HOOK_SRC" "$HOOKS/pre-push" && ok || bad "--force: did not install ($out)"
grep -q 'echo mine' "$HOOKS/pre-push.bak" 2>/dev/null && ok || bad "--force: the old hook was not kept as pre-push.bak"
out="$(bash "$INSTALL" --uninstall 2>&1)"; [ ! -e "$HOOKS/pre-push" ] && ok || bad "uninstall: our hook is still there ($out)"
out="$(bash "$INSTALL" --bogus 2>&1)"; [ $? = 64 ] && ok || bad "unknown option: want exit 64"
git config core.hooksPath "$SB/custom-hooks"
bash "$INSTALL" >/dev/null 2>&1
[ -x "$SB/custom-hooks/pre-push" ] && ok || bad "core.hooksPath: the hook is not in the configured hooks dir"
git config --unset core.hooksPath; rm -rf "$SB/custom-hooks"
bash "$INSTALL" >/dev/null 2>&1

# ---- the hook on a real push ------------------------------------------------------------------------
push() {  # [env pairs...] → sets RC OUT (git push origin main)
  : > "$STUB_LOG"
  OUT="$(env PATH="$SB/bin:$BASE_PATH" "$@" git push -q origin main 2>&1)"; RC=$?
}
remote_head() { git --git-dir="$SB/remote.git" rev-parse -q --verify refs/heads/main 2>/dev/null; }

push STUB_RC=1
[ "$RC" != 0 ] && ok || bad "gitleaks finding: the push was not stopped"
[ -z "$(remote_head)" ] && ok || bad "gitleaks finding: the remote got the branch anyway"
has "gitleaks finding: says why" "gitleaks found a possible secret" "$OUT"

push STUB_RC=0
[ "$RC" = 0 ] && ok || bad "clean push: stopped (exit $RC): $OUT"
first="$(git rev-parse HEAD)"
[ "$(remote_head)" = "$first" ] && ok || bad "clean push: the remote does not have main"
args="$(cat "$STUB_LOG")"
has "new branch: scans only commits no remote has" "--log-opts=$first --not --remotes" "$args"
has "the hook uses the repo config" "--config .gitleaks.toml" "$args"

echo two > a.txt; git commit -qam two
push STUB_RC=0
has "update: scans old..new" "--log-opts=$first..$(git rev-parse HEAD)" "$(cat "$STUB_LOG")"

# gitleaks missing: PATH without the stub. Skip if a real gitleaks is installed system-wide.
if PATH="$BASE_PATH" command -v gitleaks >/dev/null 2>&1; then
  echo "SKIP gitleaks-missing case: a real gitleaks is on PATH ($(PATH="$BASE_PATH" command -v gitleaks))"
else
  echo three > a.txt; git commit -qam three
  OUT="$(git push -q origin main 2>&1)"; RC=$?
  [ "$RC" != 0 ] && ok || bad "gitleaks missing: the push was not stopped"
  has "gitleaks missing: says how to fix it" "gitleaks is not installed" "$OUT"
  has "gitleaks missing: names the bypass" "--no-verify" "$OUT"
  git reset -q --hard HEAD~1
fi

# the leak guard runs on the working tree when the repo has it
mkdir -p tests; cp "$ROOT/tests/leak-guard.test.sh" tests/
git add tests; git commit -qm guard
printf 'cd /ho%s\n' "me/jdoe/x" > notes.txt
push STUB_RC=0
[ "$RC" != 0 ] && ok || bad "leak-guard red: the push was not stopped"
has "leak-guard red: says why" "the leak guard failed" "$OUT"
rm -f notes.txt
push STUB_RC=0
[ "$RC" = 0 ] && ok || bad "leak-guard green: the push was stopped: $OUT"

echo "pre-push-hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
