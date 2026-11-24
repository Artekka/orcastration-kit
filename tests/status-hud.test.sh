#!/usr/bin/env bash
# The optional Status HUD (plugins/status-hud): the vendored mod is scrubbed and speaks the kit's quiet
# mode, the marketplace lists it, tests/run.sh runs its own suite, and kit-init's HUD step (rendered with
# arguments, as the skill loader does) installs and configures it for the team's seat on a Yes and does
# nothing on a No. No real Claude runs: a stub `claude` on PATH records every call.
# Run: bash tests/status-hud.test.sh      (needs bash, python3; no network)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HUD="$ROOT/plugins/status-hud"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has()   { case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac; }

# ---- the vendored mod ------------------------------------------------------------------------------
M="$HUD/.claude-plugin/plugin.json"
[ -f "$M" ] && ok || bad "missing $M"
[ -f "$HUD/hooks/register.tsx" ] && [ -f "$HUD/lib/config.ts" ] && ok || bad "vendored sources missing"
[ -e "$HUD/.claude-plugin/marketplace.json" ] && bad "the HUD's own marketplace.json was vendored (the kit's lists it)" || ok
man="$(python3 - "$M" <<'PY' 2>&1
import json, sys
m = json.load(open(sys.argv[1]))
u = m.get("userConfig", {})
print("author=" + m.get("author", {}).get("name", ""))
print("keys=" + ",".join(sorted(u)))
print("seatdefault=" + str(u.get("showForNames", {}).get("default")))
print("flagdefault=" + str(u.get("quietModeFlagFile", {}).get("default")))
print("ondefault=" + str(u.get("quietModeOnCmd", {}).get("default")))
PY
)"
has "manifest: author is the kit owner" "author=Artekka" "$man"
S="If you use your own on/off commands, set \`quietModeRequiresFile\` to an empty value to keep the chip."
has "README: own-commands users are told how to keep the chip" "$S" "$(cat "$HUD/README.md")"
has "CHANGELOG: own-commands users are told how to keep the chip" "$S" "$(cat "$ROOT/CHANGELOG.md")"
for k in quietModeFlagFile quietModeStatusCmd quietModeOnCmd quietModeOffCmd quietModeRequiresFile showForNames; do has "manifest: key $k" "$k" "$man"; done
hasnt "manifest: no gameMode keys" "gameMode" "$man"
has "manifest: showForNames defaults to the kit's default seat" "seatdefault=Orca" "$man"
has "manifest: quiet-mode flag defaults to the kit's runtime file" "flagdefault=~/.orchestration-kit/runtime/quiet-mode" "$man"
has "manifest: on command is the kit's quiet-mode script" "ondefault=bash scripts/quiet-mode.sh on" "$man"
has "manifest: the chip is gated on the kit's quiet-mode script" '"default": "scripts/quiet-mode.sh"' "$(cat "$M")"
# every place a user learns the HUD explains the WORK/QUIET chip (what it does, when it shows)
for f in "$HUD/README.md" "$ROOT/README.md" "$ROOT/HOW-IT-WORKS.md" "$ROOT/docs/GETTING-STARTED.md" "$ROOT/docs/how-it-works.html"; do
  t="$(cat "$f" 2>/dev/null)"
  has "$(basename "$f"): chip paragraph heading" "What the WORK/QUIET chip does and when you'll see it" "$t"
  has "$(basename "$f"): chip paragraph says it needs the throttle script" "quiet-mode.sh" "$t"
  has "$(basename "$f"): chip paragraph says a failed press shows" "failed" "$t"
  has "$(basename "$f"): chip paragraph says no throttle means no chip" "No throttle, no chip" "$t"
done

# game mode is gone everywhere except the one README line that names the rename
gm="$(grep -rnIiE 'game.?mode' "$HUD" | grep -v '/README.md:.*renamed from' )"
[ -z "$gm" ] && ok || bad "game mode still named in the vendored mod: $gm"
grep -qiE 'renamed from.*gameMode' "$HUD/README.md" 2>/dev/null && ok || bad "README: want one line naming the rename from the upstream gameMode* keys"
grep -q '/hud quiet' "$HUD/README.md" 2>/dev/null && ok || bad "README: want the /hud quiet command"
grep -qi 'ABA' "$HUD/README.md" 2>/dev/null && ok || bad "README: the lock ABA known issue must stay"
# no machine paths, project names, row ids, version strings from the original host, or dated incidents
priv="$(grep -rnIE '/home/[a-z]+/|ORCA[0-9]|v0\.[0-9]{3}\.|20[0-9]{2}-[0-9]{2}-[0-9]{2}|claude-status-hud\b@' "$HUD" | grep -v '/home/u\b\|/home/u/' )"
[ -z "$priv" ] && ok || bad "machine paths / project ids / dates under plugins/status-hud: $priv"
# READ LOW-5: no host fingerprint in the examples (a second mount and its size), and the README reads cleanly
fp="$(grep -rnIE '/mnt/n|10150' "$HUD")"
[ -z "$fp" ] && ok || bad "host fingerprint in the HUD examples: $fp"
hasnt "README: no doubled 'style'" "pixel-style terminal style" "$(cat "$HUD/README.md" 2>/dev/null)"
# READ LOW-6: the README says where host readings come from and what other systems show
has "README: host readings are /proc-based (Linux, WSL)" "Host readings come from /proc" "$(cat "$HUD/README.md" 2>/dev/null)"
has "README: says what macOS shows" "macOS" "$(cat "$HUD/README.md" 2>/dev/null)"

# ---- marketplace + run.sh ----------------------------------------------------------------------------
mk="$(python3 - "$ROOT/.claude-plugin/marketplace.json" <<'PY' 2>&1
import json, sys
for p in json.load(open(sys.argv[1]))["plugins"]:
    print(p["name"] + "=" + p["source"])
PY
)"
has "marketplace: the kit stays" "orchestration-kit=./" "$mk"
has "marketplace: lists the HUD" "status-hud=./plugins/status-hud" "$mk"
run="$(cat "$ROOT/tests/run.sh")"
has "run.sh: runs the HUD's own suite" "claude plugin test" "$run"
has "run.sh: skips it without claude" "SKIP" "$run"
# the stage really SKIPs when claude is absent (PATH without it), and does not fail the run
stage="$(python3 - "$ROOT/tests/run.sh" <<'PY'
import sys
t = open(sys.argv[1]).read()
a = t.find("# ---- status-hud"); b = t.find("# ----", a + 5)
print(t[a:b] if a >= 0 else "")
PY
)"
[ -n "$stage" ] && ok || bad "run.sh: no '# ---- status-hud' stage block"
mkdir -p "$TMP/nobin"; for b in bash sh dirname cat grep sed head command; do p=$(command -v "$b") && ln -sf "$p" "$TMP/nobin/$b"; done
out="$(cd "$ROOT/tests" && rc=0 PATH="$TMP/nobin" bash -c "$stage"'; echo "rc=$rc"' 2>&1)"
has "run.sh stage without claude: SKIP with a reason" "SKIP status-hud" "$out"
has "run.sh stage without claude: the run stays green" "rc=0" "$out"
# READ LOW-4: a failing HUD suite fails the run
mkdir -p "$TMP/failbin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/failbin/claude"; chmod +x "$TMP/failbin/claude"
out="$(cd "$ROOT/tests" && rc=0 PATH="$TMP/failbin:$PATH" bash -c "$stage"'; echo "rc=$rc"' 2>&1)"
has "run.sh stage with a failing HUD suite: the run is red" "rc=1" "$out"

# ---- kit-init's HUD step ----------------------------------------------------------------------------
render() {  # <skill file> <args string>  → the rendered text (the loader's $ARGUMENTS / $N substitution)
  python3 - "$1" "$2" <<'PY'
import re, sys
text, args = open(sys.argv[1], encoding="utf8").read(), sys.argv[2]
parts = args.split()
pick = lambda m: parts[int(m.group(1))] if int(m.group(1)) < len(parts) else ""
text = re.sub(r"\$ARGUMENTS\[(\d+)\]", pick, text)
text = re.sub(r"\$ARGUMENTS", lambda m: args, text)
text = re.sub(r"\$(\d+)(?!\w)", pick, text)
sys.stdout.write(text)
PY
}
block() {  # <rendered file> <marker text> → the first ```bash block after the marker, de-indented
  python3 - "$1" "$2" <<'PY'
import sys
text, marker = open(sys.argv[1], encoding="utf8").read(), sys.argv[2]
i = text.find(marker)
if i < 0: sys.exit(0)
a = text.index("```bash\n", i) + 8; b = text.index("```", a)
print("\n".join(l[3:] if l.startswith("   ") else l for l in text[a:b].splitlines()))
PY
}
KI="$ROOT/skills/kit-init/SKILL.md"
has "kit-init: a Status HUD step" "Status HUD" "$(cat "$KI")"
has "kit-init: the HUD question defaults to No" "No (Recommended)" "$(cat "$KI")"
has "kit-init: the HUD question says it can change" "change it any time" "$(cat "$KI")"
render "$KI" "--yes team" > "$TMP/ki.md"
hudblk="$(block "$TMP/ki.md" "Status HUD")"
[ -n "$hudblk" ] && ok || bad "kit-init: no bash block after 'Status HUD'"

# a fake repo with a team seat, a fake HOME with a logged-in second account and a never-logged-in third
P="$TMP/proj"; mkdir -p "$P/docs/orchestration"
printf '%s\n' '# overlay' '```' 'team:' '  seat:             Captain' '  prefix:           Mate' '```' > "$P/docs/orchestration/ORCHESTRATION.md"
H="$TMP/home"; mkdir -p "$H/.claude-acct2" "$H/.claude-acct3"; : > "$H/.claude-acct2/.credentials.json"
mkdir -p "$TMP/bin"; LOG="$TMP/claude.log"; : > "$LOG"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL dir=%s args=%s\n' "${CLAUDE_CONFIG_DIR:-default}" "$*"
  case "$*" in *--values-stdin*) printf 'STDIN %s\n' "$(cat)";; esac; } >> "$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "stub: refused" >&2; exit 1; }
case "$*" in *configure*) [ -z "${STUB_FAIL_CONF:-}" ] || { echo "stub: configure refused" >&2; exit 1; };; esac
STUB
chmod +x "$TMP/bin/claude"
runhud() {  # HUD answer → output; the stub's log is in $LOG
  : > "$LOG"
  # hermetic: the host running this suite may load a HUD folder itself; HUD_PD sets one on purpose
  (cd "$P" && env -u CLAUDE_CODE_PLUGIN_DIRS ${HUD_PD:+CLAUDE_CODE_PLUGIN_DIRS="$HUD_PD"} HOME="$H" STUB_LOG="$LOG" PATH="$TMP/bin:$PATH" HUD_ANSWER="$1" \
     bash -c "$(printf '%s\n' "$hudblk" | sed "s/^HUD=<yes|no>.*/HUD=\$HUD_ANSWER/")" 2>&1)
}
out="$(runhud no)"; calls="$(cat "$LOG")"
[ -z "$calls" ] && ok || bad "HUD No: claude was called: $calls"
has "HUD No: says it skipped" "SKIP" "$out"

out="$(runhud yes)"; calls="$(cat "$LOG")"
n=$(grep -c 'args=plugin install status-hud@artekka-kits' "$LOG")
[ "$n" -eq 2 ] && ok || bad "HUD Yes: want 2 installs (default + logged-in acct2), got $n: $calls"
has "HUD Yes: the default account" "CALL dir=default args=plugin install status-hud@artekka-kits" "$calls"
has "HUD Yes: the second account" "CALL dir=$H/.claude-acct2 args=plugin install" "$calls"
hasnt "HUD Yes: a never-logged-in account is left alone" ".claude-acct3" "$calls"
has "HUD Yes: configured from stdin" "args=plugin configure status-hud@artekka-kits --values-stdin" "$calls"
vals="$(sed -n 's/^STDIN //p' "$LOG" | head -1)"
v="$(printf '%s' "$vals" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("seat=" + d.get("showForNames", "")); print("flag=" + d.get("quietModeFlagFile", ""))
print("on=" + d.get("quietModeOnCmd", "")); print("off=" + d.get("quietModeOffCmd", ""))
print("strings=" + str(all(isinstance(x, str) for x in d.values())))' 2>&1)"
has "HUD Yes: showForNames = the team's seat" "seat=Captain" "$v"
has "HUD Yes: quiet-mode flag file under the kit runtime dir" "flag=$H/.orchestration-kit/runtime/quiet-mode" "$v"
has "HUD Yes: quiet-mode on" "on=bash scripts/quiet-mode.sh on" "$v"
has "HUD Yes: quiet-mode off" "off=bash scripts/quiet-mode.sh off" "$v"
has "HUD Yes: values are single-line strings (configure --values-stdin)" "strings=True" "$v"
has "HUD Yes: reports what it did" "status HUD" "$out"

# READ LOW-2: a failing install says so (it used to fall through silently)
out="$(STUB_FAIL=1 runhud yes)"
has "HUD Yes, claude fails: says it failed" "FAILED" "$out"
hasnt "HUD Yes, claude fails: no success line" "status HUD installed" "$out"
# READ 4b LOW: install ok + configure fails must not claim "nothing was changed": the plugin IS installed
out="$(STUB_FAIL_CONF=1 runhud yes)"
has "HUD Yes, configure fails: says configuring failed" "configuring it FAILED" "$out"
has "HUD Yes, configure fails: says the plugin is installed with defaults" "installed and runs with its defaults" "$out"
has "HUD Yes, configure fails: says how to retry" "claude plugin configure status-hud@artekka-kits --values-stdin" "$out"
hasnt "HUD Yes, configure fails: never says nothing was changed" "nothing else was changed" "$out"
# READ LOW-2: an account that already loads a status HUD through CLAUDE_CODE_PLUGIN_DIRS is explained and skipped
printf '{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "/opt/x/claude-status-hud" } }\n' > "$H/.claude-acct2/settings.json"
out="$(runhud yes)"; calls="$(cat "$LOG")"
has "HUD Yes, acct2 loads the upstream HUD: explained" "CLAUDE_CODE_PLUGIN_DIRS" "$out"
hasnt "HUD Yes, acct2 loads the upstream HUD: not installed there" "dir=$H/.claude-acct2" "$calls"
has "HUD Yes, acct2 loads the upstream HUD: the default account still gets it" "CALL dir=default args=plugin install" "$calls"
rm -f "$H/.claude-acct2/settings.json"
out="$(HUD_PD=/opt/y/status-hud runhud yes)"; calls="$(cat "$LOG")"
has "HUD Yes, this shell loads a HUD dir: explained" "CLAUDE_CODE_PLUGIN_DIRS" "$out"
# READ LOW-3: macOS keeps logins in the Keychain, so a second account has no .credentials.json there
mkdir -p "$TMP/darwin"; printf '#!/bin/sh\necho Darwin\n' > "$TMP/darwin/uname"; chmod +x "$TMP/darwin/uname"
: > "$LOG"
out="$(cd "$P" && env -u CLAUDE_CODE_PLUGIN_DIRS HOME="$H" STUB_LOG="$LOG" PATH="$TMP/darwin:$TMP/bin:$PATH" HUD_ANSWER=yes \
  bash -c "$(printf '%s\n' "$hudblk" | sed "s/^HUD=<yes|no>.*/HUD=\$HUD_ANSWER/")" 2>&1)"
n=$(grep -c 'args=plugin install' "$LOG")
[ "$n" -eq 3 ] && ok || bad "HUD Yes on macOS: every ~/.claude-acctN dir counts (want 3 installs, got $n): $(cat "$LOG")"

echo "status-hud: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
