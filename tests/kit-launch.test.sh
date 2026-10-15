#!/usr/bin/env bash
# Tests for scripts/kit-launch.sh (the project picker) and scripts/kit-word.sh (your word for it).
# Run: bash tests/kit-launch.test.sh   (sandboxed: a fake HOME, nothing is launched)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; L="$ROOT/scripts/kit-launch.sh"; W="$ROOT/scripts/kit-word.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
rc_is() { [ "$2" = "$3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: want exit $2, got $3"; }; }
H="$TMP/home"; P="$H/work"; S="$H/.orchestration-kit"
mkdir -p "$P/Kit App/docs/orchestration" "$P/Kit App/scripts" "$P/plain" "$P/Kit App-Test" "$P/_archive"
: > "$P/Kit App/docs/orchestration/ORCHESTRATION.md"; : > "$P/Kit App/scripts/start-team.sh"
mkdir -p "$S"; printf 'projects_dir=~/work\nword=zzgo\n' > "$S/launcher.conf"
pick() { printf '%b' "$1" | env HOME="$H" KIT_LAUNCH_DRY=1 bash "$L" "${@:2}" 2>&1; }
VER="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -1)"

# --- kit-launch.sh
out="$(pick '' --list)"
has "list: kit project" "kit  Kit App" "$out"; has "list: plain project" "-    plain" "$out"; hasnt "list: no trial copies" "Kit App-Test" "$out"; hasnt "list: no _ folders" "_archive" "$out"
out="$(pick 'q\n')"; has "menu: titled with the word" "zzgo — pick a project" "$out"
has "menu: names the kit and its version" "orchestration-kit $VER" "$out"
has "menu: a kit project offers team or chat" "kit: team or chat" "$out"
out="$(pick '1\nt\n')"; has "kit project: team runs its own start-team.sh" "RUN in $P/Kit App: bash $P/Kit App/scripts/start-team.sh" "$out"
out="$(pick '1\n C \n')"; has "kit project: one chat (case and spaces ignored)" "RUN in $P/Kit App: claude" "$out"; hasnt "chat: no team" "start-team" "$out"
out="$(pick '1\nx\nq\n')"; hasnt "team/chat: a bad pick runs nothing" "RUN" "$out"; has "team/chat: says what to pick" "Pick t, c, or b" "$out"
out="$(pick '1\nb\nq\n')"; hasnt "team/chat: back returns to the menu" "RUN" "$out"
out="$(pick 't\n' 'Kit App')"; has "named project skips the menu" "start-team.sh" "$out"; hasnt "named: no menu" "pick a project" "$out"
out="$(pick '2\ns\n')"; has "no kit: set it up" "RUN in $P/plain: claude /orchestration-kit:kit-init" "$out"
out="$(pick '2\nc\n')"; has "no kit: plain chat" "RUN in $P/plain: claude" "$out"; hasnt "plain chat has no prompt" "kit-init" "$out"
out="$(pick '2\nb\nq\n')"; hasnt "back returns to the menu" "RUN" "$out"
out="$(pick 'n\nfresh\n')"; has "new project: kit-init in it" "RUN in $P/fresh: claude /orchestration-kit:kit-init" "$out"
[ -d "$P/fresh/.git" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL new project is not a git repo"; }
out="$(pick 'n\n../x\nq\n')"; has "new project: refuses a path" "Not a usable folder name" "$out"
out="$(pick '' nope)"; rc_is "unknown project: exit 1" 1 $?
# A git worktree (a .git file) is not a project; before_start runs first, with the folder.
mkdir -p "$P/kit-app-wt"; echo "gitdir: $P/Kit App/.git/worktrees/x" > "$P/kit-app-wt/.git"
hasnt "worktree not listed" "kit-app-wt" "$(pick 'q\n')"
printf 'before_start=~/bin/trust.sh --if-mine\n' >> "$S/launcher.conf"
out="$(pick 'c\n' plain)"; has "before_start runs with the folder" "BEFORE $H/bin/trust.sh --if-mine $P/plain" "$out"
sed -i '/^before_start=/d' "$S/launcher.conf"
# update_cmd: [u] appears only when set, and runs it
out="$(pick 'q\n')"; hasnt "update: no [u] without update_cmd" "[u]" "$out"
out="$(pick 'u\nq\n')"; has "update: u without update_cmd is not a choice" "Pick a number, n, or q." "$out"
printf 'update_cmd=~/bin/kit-up.sh --now\n' >> "$S/launcher.conf"
out="$(pick 'q\n')"; has "update: [u] in the menu" "[u] update the kit" "$out"
out="$(pick 'u\n')"; has "update: u runs update_cmd, ~ expanded" "UPDATE $H/bin/kit-up.sh --now" "$out"
sed -i '/^update_cmd=/d' "$S/launcher.conf"
# header_cmd replaces the kit line; a silent or failing one falls back to the version.
mkdir -p "$H/bin"; printf '#!/bin/sh\necho "My kit 1.0 + 2 notes"\necho second line\n' > "$H/bin/head.sh"; chmod +x "$H/bin/head.sh"
printf 'header_cmd=~/bin/head.sh\n' >> "$S/launcher.conf"
out="$(pick 'q\n')"; has "header_cmd: its first line" "My kit 1.0 + 2 notes" "$out"; hasnt "header_cmd: only the first line" "second line" "$out"
hasnt "header_cmd: replaces the version line" "orchestration-kit $VER" "$out"
printf '#!/bin/sh\nexit 1\n' > "$H/bin/head.sh"
out="$(pick 'q\n')"; has "header_cmd silent: version line back" "orchestration-kit $VER" "$out"
sed -i '/^header_cmd=/d' "$S/launcher.conf"
# news: runs news_cmd, or says none is set.
out="$(pick '' news)"; has "news: none set" "No news command set" "$out"; has "news: still names the version" "orchestration-kit $VER" "$out"
printf '#!/bin/sh\necho "news from $1"\n' > "$H/bin/news.sh"; chmod +x "$H/bin/news.sh"
printf 'news_cmd=~/bin/news.sh arg1\n' >> "$S/launcher.conf"
out="$(pick '' news)"; has "news: runs news_cmd with its words" "news from arg1" "$out"

# chat_args: extra arguments for [c] one chat only, never for kit-init or the team.
printf 'chat_args=--allow-dangerously-skip-permissions --model haiku\n' >> "$S/launcher.conf"
out="$(pick 'c\n' plain)"; has "chat_args on a plain chat" "RUN in $P/plain: claude --allow-dangerously-skip-permissions --model haiku" "$out"
out="$(pick 'c\n' 'Kit App')"; has "chat_args on a kit project's chat" "RUN in $P/Kit App: claude --allow-dangerously-skip-permissions --model haiku" "$out"
out="$(pick 's\n' plain)"; hasnt "chat_args not on kit-init" "--model haiku" "$out"
sed -i '/^chat_args=/d' "$S/launcher.conf"

# --- kit-word.sh
RC="$H/.bashrc"; printf 'alias ll=ls\ntaken() { :; }\n' > "$RC"
w() { env HOME="$H" SHELL=/bin/bash bash "$W" "$@" 2>&1; }
out="$(w install 'Bad Word')"; rc_is "bad word: exit 64" 64 $?
out="$(w install taken)"; rc_is "a function in the rc file: refused" 1 $?; has "says what it is" "already names a function" "$out"
out="$(w install ls)"; rc_is "a PATH command: refused" 1 $?
out="$(w install ll)"; rc_is "an alias: refused" 1 $?
out="$(w install zzgo --projects '~/work')"; rc_is "install: exit 0" 0 $?
has "block in rc" 'zzgo() { bash "'"$S"'/bin/kit-launch" "$@"; }' "$(cat "$RC")"
has "rc kept" "alias ll=ls" "$(cat "$RC")"
[ -x "$S/bin/kit-launch" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL no shim"; }
has "conf saved" "projects_dir=~/work" "$(cat "$S/launcher.conf")"
out="$(w install zzgo)"; rc_is "re-install of the same word: fine" 0 $?
n="$(grep -c '^# >>> orchestration-kit word >>>$' "$RC")"; [ "$n" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL want one block, got $n"; }
out="$(w install taken --replace)"; rc_is "--replace takes a used word" 0 $?
hasnt "the old word's block is gone" "zzgo()" "$(cat "$RC")"
out="$(w show)"; has "show: the word" "word: taken" "$out"
# The block really defines a working function, and the shim falls back to the recorded kit.
out="$(env HOME="$H" PATH="/usr/bin:/bin" KIT_LAUNCH_DRY=1 bash -c ". '$RC' >/dev/null 2>&1; type -t taken; printf 'q\n' | taken" 2>&1)"
has "word is a function" "function" "$out"; has "word opens the picker" "pick a project" "$out"
out="$(w remove)"; hasnt "remove: block gone" "orchestration-kit word" "$(cat "$RC")"; has "remove: rest kept" "taken() { :; }" "$(cat "$RC")"

echo "kit-launch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
