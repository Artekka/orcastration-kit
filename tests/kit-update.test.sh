#!/usr/bin/env bash
# Tests for scripts/kit-update.sh. Sandboxed: a fake Claude config, a fake marketplace and a stub `claude`
# on PATH that records what it was asked and "installs" the marketplace's version. No network.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; U="$ROOT/scripts/kit-update.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
rc_is() { [ "$2" = "$3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: want exit $2, got $3"; }; }

export CLAUDE_CONFIG_DIR="$TMP/cfg" KIT_STATE_DIR="$TMP/state" KIT_UPDATE_SESSIONS=0
MP="$TMP/market"; P="$CLAUDE_CONFIG_DIR/plugins"; mkdir -p "$P" "$MP/.claude-plugin" "$KIT_STATE_DIR" "$TMP/bin"
installed() {  # <kit version> <path> [hud]
  local hud=""; [ -n "${3:-}" ] && hud=', "status-hud@mk": [{"scope": "user", "installPath": "/x", "version": "0.1"}]'
  printf '{"version": 2, "plugins": {"orchestration-kit@mk": [{"scope": "user", "installPath": "%s", "version": "%s"}]%s}}\n' "$2" "$1" "$hud" > "$P/installed_plugins.json"
}
offer() { printf '{"name": "mk", "plugins": [{"name": "orchestration-kit", "source": "./", "version": "%s"}]}\n' "$1" > "$MP/.claude-plugin/marketplace.json"; }
printf '{"mk": {"source": {"source": "directory", "path": "%s"}, "installLocation": "%s"}}\n' "$MP" "$MP" > "$P/known_marketplaces.json"
# two installed copies of the kit's scripts, old and new
for v in 1.0 1.1; do mkdir -p "$TMP/cache/$v/scripts"; for f in lib-launch.sh start-team.sh recycle-sibling.sh ctx-fill.py statusline-ctx.sh gate-throttle.sh quiet-mode.sh; do echo "$f $v" > "$TMP/cache/$v/scripts/$f"; done; done
# the stub claude: logs its arguments; "plugin update orchestration-kit@mk" installs the offered version
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/claude.log"
if [ "\$1 \$2 \$3" = "plugin update orchestration-kit@mk" ]; then
  v="\$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$MP/.claude-plugin/marketplace.json")"
  sed -i "s|\"installPath\": \"[^\"]*\", \"version\": \"[^\"]*\"|\"installPath\": \"$TMP/cache/\$v\", \"version\": \"\$v\"|" "$P/installed_plugins.json"
fi
exit "\${STUB_RC:-0}"
EOF
chmod +x "$TMP/bin/claude"; export PATH="$TMP/bin:$PATH"

# --- status
installed 1.0 "$TMP/cache/1.0"; offer 1.0
out="$("$U" status)"; rc_is "status: up to date exits 0" 0 $?; has "status: says up to date" "1.0 installed; up to date" "$out"
offer 1.1
out="$("$U" status)"; rc_is "status: newer available exits 10" 10 $?; has "status: names both" "1.0 installed; 1.1 available" "$out"
offer 1.0.9; out="$("$U" status)"; rc_is "status: 1.0.9 is newer than 1.0" 10 $?
offer 0.9; out="$("$U" status)"; rc_is "status: an older offer is no update" 0 $?
offer 1.10; installed 1.9 "$TMP/cache/1.0"; out="$("$U" status)"; rc_is "status: 1.10 is newer than 1.9 (version order, not text)" 10 $?
: > "$TMP/claude.log"; "$U" status --fetch >/dev/null; has "status --fetch refreshes the marketplace" "plugin marketplace update mk" "$(cat "$TMP/claude.log")"
mv "$P/installed_plugins.json" "$TMP/ip"; out="$("$U" status 2>&1)"; rc_is "status: not installed" 1 $?; has "status: says how to install" "not installed" "$out"; mv "$TMP/ip" "$P/installed_plugins.json"

# --- projects
installed 1.1 "$TMP/cache/1.1"; PR="$TMP/projects"
mkdir -p "$PR/old/docs/orchestration" "$PR/old/scripts" "$PR/new/docs/orchestration" "$PR/new/scripts" "$PR/nokit/scripts"
touch "$PR/old/docs/orchestration/ORCHESTRATION.md" "$PR/new/docs/orchestration/ORCHESTRATION.md"
cp "$TMP/cache/1.0/scripts/"* "$PR/old/scripts/"; cp "$TMP/cache/1.1/scripts/"* "$PR/new/scripts/"; cp "$TMP/cache/1.0/scripts/"* "$PR/nokit/scripts/"
rm "$PR/old/scripts/quiet-mode.sh"   # a project may lack one; that is not a difference
out="$("$U" projects --projects "$PR")"
has "projects: the old one listed" "old: lib-launch.sh start-team.sh" "$out"; hasnt "projects: a missing file is not listed" "quiet-mode.sh" "$out"
hasnt "projects: an up-to-date one is not" "new:" "$out"; hasnt "projects: no kit, not listed" "nokit" "$out"
printf 'projects_dir=%s\n' "$PR" > "$KIT_STATE_DIR/launcher.conf"
out="$("$U" projects)"; has "projects: dir from launcher.conf" "old:" "$out"

# --- refresh
out="$("$U" refresh "$PR/old")"; has "refresh: counts" "6 file(s) refreshed in old" "$out"
cmp -s "$PR/old/scripts/start-team.sh" "$TMP/cache/1.1/scripts/start-team.sh"; rc_is "refresh: copy is the kit's" 0 $?
has "refresh: old kept" "start-team.sh 1.0" "$(cat "$PR/old/scripts/start-team.sh.bak-"*)"
[ ! -e "$PR/old/scripts/quiet-mode.sh" ]; rc_is "refresh: adds nothing new" 0 $?
out="$("$U" projects --projects "$PR")"; has "projects: all match after refresh" "every kit project's script copies match" "$out"
out="$("$U" refresh "$PR/nokit" 2>&1)"; rc_is "refresh: refuses a project without the kit" 1 $?

# --- run
installed 1.0 "$TMP/cache/1.0" hud; offer 1.1; cp "$TMP/cache/1.0/scripts/start-team.sh" "$PR/new/scripts/start-team.sh"
: > "$TMP/claude.log"
out="$(printf 'n\n' | KIT_UPDATE_SESSIONS=2 "$U" run 2>&1)"; rc_is "run: no is no" 1 $?
has "run: says sessions keep the old version" "2 Claude session(s) are open" "$out"; has "run: declined" "Not updated." "$out"
[ ! -s "$TMP/claude.log" ]; rc_is "run: declined runs nothing" 0 $?
out="$(printf 'y\n' | "$U" run 2>&1)"; rc_is "run: yes updates" 0 $?
log="$(cat "$TMP/claude.log")"
has "run: refreshes the marketplace" "plugin marketplace update mk" "$log"; has "run: updates the kit" "plugin update orchestration-kit@mk" "$log"
has "run: updates the HUD when installed" "plugin update status-hud@mk" "$log"
has "run: before -> after" "orchestration-kit 1.0 -> 1.1" "$out"; has "run: restart advice" "Restart open sessions" "$out"
has "run: project report after" "new: start-team.sh" "$out"
: > "$TMP/claude.log"; installed 1.1 "$TMP/cache/1.1"
out="$("$U" run --yes 2>&1)"; has "run --yes: no question, already newest" "already the newest" "$out"
hasnt "run: no HUD update when not installed" "status-hud" "$(cat "$TMP/claude.log")"
out="$(STUB_RC=1 "$U" run --yes 2>&1)"; rc_is "run: a failed refresh stops" 1 $?; has "run: says what failed" "could not refresh the marketplace" "$out"
out="$("$U" 2>&1)"; rc_is "usage" 64 $?
# the script list must match what kit-init copies
init="$(sed -n 's/^ *for f in \(.*\); do SRC="\$K\/scripts.*/\1/p' "$ROOT/skills/kit-init/SKILL.md")"
mine="$(sed -n 's/^SESSION_SCRIPTS="\(.*\)"$/\1/p' "$U")"
[ -n "$init" ] && [ "$init" = "$mine" ]; rc_is "session-script list matches kit-init's" 0 $?

echo "kit-update: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
