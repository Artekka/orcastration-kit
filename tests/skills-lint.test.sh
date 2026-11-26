#!/usr/bin/env bash
# Every shipped skill and agent is well-formed: frontmatter `name:` equals its folder (agents: its file name), a
# `description:` of at most 1024 characters, every `${CLAUDE_PLUGIN_ROOT}/<path>` and every markdown link it cites
# exists, every "`<file>` in this skill's folder" exists beside its SKILL.md, and no skill, agent or template carries
# a personal home path (/home/<user>/, /Users/<user>/, C:\Users\<user>\). With KIT_PRIVATE_WORDS=<file> (one word
# per line) it also refuses any of those words. Run: bash tests/skills-lint.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
front() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1' "$1"; }   # the frontmatter lines

check_one() {  # <file> <expected name>
  local f="$1" want="$2" fm name desc rel
  rel="${f#"$ROOT"/}"
  fm="$(front "$f")"
  [ -n "$fm" ] && ok || { bad "$rel: no frontmatter"; return; }
  name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)"
  [ "$name" = "$want" ] && ok || bad "$rel: name '$name' is not '$want'"
  desc="$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1)"
  [ -n "$desc" ] && ok || bad "$rel: no description"
  [ "${#desc}" -le 1024 ] && ok || bad "$rel: description is ${#desc} characters (max 1024)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -e "$ROOT/$p" ] && ok || bad "$rel cites \${CLAUDE_PLUGIN_ROOT}/$p, which does not exist"
  done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$f" | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||; s|\.$||' | sort -u)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in http*|mailto:*) continue ;; esac
    [ -e "$(dirname "$f")/$p" ] && ok || bad "$rel links to $p, which does not exist"
  done < <(grep -oE '\]\([^)#[:space:]]+' "$f" | sed 's/^](//' | sort -u)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -e "$(dirname "$f")/$p" ] && ok || bad "$rel names \`$p\` in its folder, which does not exist"
  done < <(grep -oE '`[A-Za-z0-9_.-]+` in this skill'"'"'s folder' "$f" | sed 's/^`//; s/`.*//' | sort -u)
}

n=0
for d in "$ROOT"/skills/*/; do d="${d%/}"
  [ -f "$d/SKILL.md" ] || { bad "skills/$(basename "$d") has no SKILL.md"; continue; }
  check_one "$d/SKILL.md" "$(basename "$d")"; n=$((n+1))
done
for a in "$ROOT"/agents/*.md; do
  [ -f "$a" ] || continue
  check_one "$a" "$(basename "$a" .md)"; n=$((n+1))
done
[ "$n" -gt 0 ] && ok || bad "no skills found under skills/"

# personal paths: a real user folder, not a placeholder like /home/<user>/ or /home/you/
hits="$(grep -rnIE '/home/[a-z][a-z0-9_-]*/|/Users/[A-Za-z][A-Za-z0-9_-]*/|C:\\\\Users\\\\[A-Za-z]' "$ROOT/skills" "$ROOT/agents" "$ROOT/templates" 2>/dev/null \
  | grep -vE '/home/(user|you|me|name|example)/|/Users/(user|you|me|name|example)/' || true)"
[ -z "$hits" ] && ok || bad "personal home paths in shipped text:
$hits"

if [ -n "${KIT_PRIVATE_WORDS:-}" ] && [ -f "$KIT_PRIVATE_WORDS" ]; then
  hits="$(grep -v '^[[:space:]]*$' "$KIT_PRIVATE_WORDS" | grep -rnIiwF -f - "$ROOT/skills" "$ROOT/agents" "$ROOT/templates" 2>/dev/null || true)"
  [ -z "$hits" ] && ok || bad "private words in shipped text (KIT_PRIVATE_WORDS): $(printf '%s\n' "$hits" | cut -d: -f1,2 | sort -u | tr '\n' ' ')"
fi

echo "skills-lint: $pass passed, $fail failed ($n skills and agents)"
[ "$fail" -eq 0 ]
