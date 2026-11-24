#!/usr/bin/env bash
# Leak guard: no committed secret or personal detail in the kit's own files. Fails on
#   - a /home/<user> or /Users/<user> path (placeholder users like u, x, you, user are allowed)
#   - an email address (only noreply forms and the reserved example.* domains are allowed)
#   - AWS, GitHub, Anthropic and OpenAI key shapes
#   - a private-key header
#   - a project word: the originating project's name or one of its board row ids (the deny list is in CLASSES)
# It scans every tracked file plus untracked files that are not ignored, so a planted file fails before
# it is committed. Part 1 plants each class in a sandbox (the scanner must catch it); part 2 scans the repo.
# The planted values are built from pieces at run time, so this file never holds a matching string itself.
# Run: bash tests/leak-guard.test.sh   (needs bash, git, grep)
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# ---- the classes: label TAB extended regex (grep -E) ------------------------------------------------
CLASSES="$(cat <<'EOF'
home-path	(^|[[:space:]"'`=:(,])(/mnt/[^\\/[:space:]]+|/var|/(var/)?tmp([\\/][^\\/[:space:]]+)*|[A-Za-z]:|[\\/]{2,}[^\\/[:space:]]+[\\/]+[^\\/[:space:]]+|file:(//|%2[Ff]%2[Ff])[^\\/[:space:]%]*|~|\.\.|\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*))?([\\/]+\.\.)*([\\/]|%2[Ff]|%5[Cc])+(home|users)([\\/]|%2[Ff]|%5[Cc])+[A-Za-z0-9_][A-Za-z0-9._-]*
email	[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}
aws-key	\b(AKIA|ASIA)[0-9A-Z]{16}\b
github-token	\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}
github-token	\bgithub_pat_[A-Za-z0-9_]{22,}
anthropic-key	\bsk-ant-[A-Za-z0-9_-]{20,}
openai-key	\bsk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}
private-key	-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----
# project-word: the kit is public, so a project's name and its board row ids must not ship. The deny list is these two
# patterns; a bracket in the name keeps this file from matching itself. Add a word by adding a line.
project-word	einherj[a]r
project-word	orca[0-9]+[a-z]*-[0-9]+
# any session-prefix row id with letters after a number before the dash (340h, 340hd, 7a, 106a); the kit's own example ids
# (S2E10-3, S2-1, O7-1, T9-6) end in digits before the dash and never match.
project-word	\b[a-z]{1,6}[0-9]+[a-z]+([0-9]+[a-z]+)?-[0-9]+[a-z]?\b
EOF
)"
# home-path (READ r0-r2): home or users counts only as the FIRST directory of an absolute path. That is, at the start of a
# line or after whitespace, a quote, =, :, ( or , (so src/pages/Home/x and GET /api/users/1 are not homes), or right after a
# known root: /mnt/<x>, /var, /tmp or /var/tmp (any segments), a drive C:, a UNC \\host\share, file:// or file:%2F%2F, ~,
# .. segments, or a $VAR / ${VAR}. Separators are / or \ (repeated, JSON-escaped) or URL-encoded %2F / %5C, in any case.
# SAFE_HOME lists the only safe prefixes, the test sandboxes this repo uses: $SB, ${SB}, $TMPDIR, ${TMPDIR}, and ONE
# mktemp-style /tmp segment (name.XXXXXX). Any .. in between is never safe. .gitleaks.toml holds the same rule; part 3
# feeds it the same cases, so the two cannot drift.
# Matches that are fine. Each is checked against the matched text alone, never the whole line, so an
# allowed path on a line cannot hide a real one beside it.
ALLOW_HOME='^(u|x|you|user|username|me|name|example|runner|public|default|shared|home|users)$'
SAFE_HOME='^[[:space:]"'"'"'`=:(,]?(\$(\{(SB|TMPDIR)\}|(SB|TMPDIR))|/tmp/[A-Za-z0-9_-]*\.[A-Za-z0-9]{6,})([\\/]|%2[Ff]|%5[Cc])+(home|users)([\\/]|%2[Ff]|%5[Cc])+[A-Za-z0-9_][A-Za-z0-9._-]*$'
ALLOW_EMAIL='(@users\.noreply\.github\.com|^noreply@anthropic\.com|^noreply@github\.com|^git@github\.com|@example\.(com|org|net))$'
# The openai shape also catches every Anthropic key; report those once, as anthropic-key.
ALLOW_OPENAI='^sk-ant-'

leak_scan() {  # <dir> → "label file:line: match" per finding, nothing when clean
  local dir="$1" label re allow f
  local files=()
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do [ -f "$dir/$f" ] && files+=("$f"); done \
      < <(git -C "$dir" ls-files -z --cached --others --exclude-standard)
  else
    while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(cd "$dir" && find . -type f -print0)
  fi
  [ "${#files[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r label re; do
    case "$label" in home-path) allow="$ALLOW_HOME" ;; email) allow="$ALLOW_EMAIL" ;; openai-key) allow="$ALLOW_OPENAI" ;; *) allow='' ;; esac
    # -I skips binary files; -o prints each match on its own line; -H keeps file:line: with one file
    local gi=""; { [ "$label" = home-path ] || [ "$label" = project-word ]; } && gi=i   # a home path in any case (C:\USERS, /HOME)
    (cd "$dir" && grep -HonIE$gi -- "$re" "${files[@]}" 2>/dev/null) | while IFS= read -r hit; do
      local m="${hit#*:}"; m="${m#*:}"
      local subject="$m" icase=""
      if [ "$label" = home-path ]; then
        printf '%s\n' "$m" | grep -qiE -- "$SAFE_HOME" && continue   # a test sandbox, not a home
        case "$m" in [[:space:]\"\'\`=:\(,]*) m="${m:1}" ;; esac   # drop the boundary character from the report
        subject="$(printf '%s' "$m" | sed -E 's/.*([\\/]|%2[Ff]|%5[Cc])//')"   # the user name: the allow-list is about who
        icase=i
      fi
      if [ -n "$allow" ] && printf '%s\n' "$subject" | grep -q${icase}E -- "$allow"; then continue; fi
      echo "$label ${hit%%:*}:$(printf '%s' "${hit#*:}" | cut -d: -f1): $m"
    done
  done <<< "$CLASSES"
}

# ---- (1) the scanner catches each class, and lets the allowed forms through ------------------------
SB="$(mktemp -d "${TMPDIR:-/tmp}/leak-guard.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
plant() {  # <label> <file content>: the scanner must report <label> for it
  rm -rf "$SB/s"; mkdir -p "$SB/s"; printf '%s\n' "$2" > "$SB/s/planted.txt"
  local out; out="$(leak_scan "$SB/s")"
  case "$out" in *"$1 planted.txt:1:"*) ok ;; *) bad "scanner missed a planted $1 (got: ${out:-nothing})" ;; esac
}
clean() {  # <label> <file content>: the scanner must report nothing
  rm -rf "$SB/s"; mkdir -p "$SB/s"; printf '%s\n' "$2" > "$SB/s/allowed.txt"
  local out; out="$(leak_scan "$SB/s")"
  [ -z "$out" ] && ok || bad "allowed form flagged ($1): $out"
}
A=A; Z=0123456789ABCDEF; L=abcdefghijklmnopqrstuvwxyz0123456789
HOME_RED=(
  "cd /ho""me/jdoe/projects"
  "open /Us""ers/jdoe/Library"
  "a placeholder /home/u beside a real path /ho""me/jdoe"
  "WSL: /mnt/c/Us""ers/jdoe/Documents"
  "WSL lower case: /mnt/d/us""ers/jdoe"
  "open file:///ho""me/jdoe/index.html"
  "mac: file:///Us""ers/jdoe/x"
  "host: file://localhost/ho""me/jdoe/x"
  "cd ~/../ho""me/jdoe"
  'C:\Us''ers\jdoe\AppData'
  'json: "C:\\Us''ers\\jdoe"'
  "C:/Us""ers/jdoe/x"
  "PATH=/usr/bin:/ho""me/jdoe/bin"
  "//ho""me/jdoe"
  "//Us""ers/jdoe"
  "/us""ers/jdoe"
  "/HO""ME/jdoe"
  'C:\US''ERS\jdoe'
  '\\wsl$\Ubuntu\ho''me\jdoe'
  '\\wsl.localhost\Ubuntu\ho''me\jdoe'
  'json: "\\\\wsl$\\Ubuntu\\ho''me\\jdoe"'
  "%2Fho""me%2Fjdoe"
  "file:%2F%2F%2Fho""me%2Fjdoe"
  "%5CUs""ers%5Cjdoe"
  "%2fho""me%2fjdoe"
  "/var/ho""me/jdoe"
  "/mnt/wsl/ho""me/jdoe"
  '..\ho''me\jdoe'
  "\$HOME/../ho""me/jdoe"
  "/tmp/../ho""me/jdoe"
  "\$SB beside /ho""me/jdoe"
  "\${REMOTE}/ho""me/jdoe/x"
  "\$SRC/ho""me/jdoe/x"
  "\$X/Us""ers/jdoe"
  "\$SB/../ho""me/jdoe"
  "/tmp/rootfs/ho""me/jdoe"
  "/var/tmp/ho""me/jdoe"
  "/TMP/x/ho""me/jdoe"
  "(see /ho""me/jdoe)"
  "a,/ho""me/jdoe"
)
HOME_CLEAN=(
  "HOME=/home/u and /home/user/x and /Users/you/x and /home/<user> and /home/\$USER"
  'sandbox: "$SB/home/jdoe" "${SB}/home/jdoe" "$TMPDIR/home/jdoe" ${TMPDIR}/Users/jdoe /tmp/leak-guard.Ab12Cd/home/jdoe "$SB/home/.claude-acct2"'
  'placeholders: /mnt/c/Users/you C:\Users\Public C:\Users\%USERNAME% file:///home/user/x ../home/u /HOME/U %2Fhome%2Fu /Users/Shared'
  'code: src/pages/Home/Dashboard.tsx routes/users/list.ts GET /api/users/123 https://example.com/home/welcome Settings/Home/Profile'
  'prose: the /home/users page'
)
for c in "${HOME_RED[@]}"; do plant home-path "$c"; done
for c in "${HOME_CLEAN[@]}"; do clean home-path "$c"; done
plant email          "mail jane.doe""@""gmail.com"
plant aws-key        "key=${A}KIA${Z}"
plant aws-key        "key=${A}SIA${Z}"
plant github-token   "token=gh""p_${L}"
plant github-token   "token=gh""p_${L}XYZ"   # a longer tail than 36
plant github-token   "token=github""_pat_${L}_${L}"
plant anthropic-key  "ANTHROPIC_API_KEY=sk-""ant-api03-${L}"
plant openai-key     "OPENAI_API_KEY=sk-""proj-${L}"
plant openai-key     "OPENAI_API_KEY=sk-""${L}"
plant private-key    "-----BEGIN ""PRIVATE KEY-----"
plant private-key    "-----BEGIN ""OPENSSH PRIVATE KEY-----"
plant private-key    "-----BEGIN ""RSA PRIVATE KEY-----"
plant project-word   "ported from the Einherj""ar project"
plant project-word   "ported from the EINHERJ""AR project"
plant project-word   "fixed in OR""CA322-9 r1"
plant project-word   "row ORCA340""h-231 shipped"
plant project-word   "row OR""CA106-1 shipped"
plant project-word   "sibling S2E340""hd-3 built it"
plant project-word   "sibling S5E340""h-1 built it"
plant project-word   "collision O7""a-1 renamed"
plant project-word   "row VE106""a-1 shipped"
clean project-word   "the kit's own example ids S2E10-3, S2-1, O7-1 and T9-6; also utf8-1, x86-64, sha256-1, base64-1"
clean project-word   "ported from the project that grew the script; ORCA is a word, row ids are not shipped"
# UUID fragments from the Station's synthetic fixtures (a letter, digits, letters, then a dash and digits): hex ids are not row ids
clean project-word   "synthetic ids e15a-5086 c5dd-5827 f0ec-516b b31b-508a d980d86f-5958 f2b362bd-022f be2d-61458207687a e7ce-5306"
clean email          "Co-Authored-By: Claude <noreply""@anthropic.com> and 12345+someone""@users.noreply.github.com"
clean email          "t""@example.com, git""@github.com:owner/repo.git, plugin@marketplace-name"
clean anthropic-key  "an Anthropic key starts with sk-ant- and the docs never show one"
# The only finding for an Anthropic key is anthropic-key, not openai-key too.
rm -rf "$SB/s"; mkdir -p "$SB/s"; printf '%s\n' "sk-""ant-api03-${L}" > "$SB/s/one.txt"
[ "$(leak_scan "$SB/s" | wc -l | tr -d ' ')" = 1 ] && ok || bad "an Anthropic key is reported more than once: $(leak_scan "$SB/s")"
# Untracked files that are not ignored are scanned; ignored ones are not.
rm -rf "$SB/g"; mkdir -p "$SB/g"; git -C "$SB/g" init -q
printf 'ignored.txt\n' > "$SB/g/.gitignore"; printf '%s\n' "/ho""me/jdoe" > "$SB/g/new.txt"; printf '%s\n' "/ho""me/jdoe" > "$SB/g/ignored.txt"
out="$(leak_scan "$SB/g")"
case "$out" in *"new.txt:1:"*) ok ;; *) bad "untracked file not scanned (got: ${out:-nothing})" ;; esac
case "$out" in *"ignored.txt"*) bad "ignored file scanned: $out" ;; *) ok ;; esac

# ---- (3) parity: .gitleaks.toml's home-path rule flags exactly the same cases -----------------------------
# The rule's regex and allowlists are read from the toml and applied with Python's re (the same syntax subset as gitleaks'
# RE2 here), so CI's gitleaks scan cannot drift from this guard. With a real gitleaks on PATH (CI's gitleaks job), each case
# also goes through the binary itself, default rules and global allowlist included.
CASES="$SB/home-cases.txt"; : > "$CASES"
for c in "${HOME_RED[@]}"; do printf 'R\t%s\n' "$c" >> "$CASES"; done
for c in "${HOME_CLEAN[@]}"; do printf 'C\t%s\n' "$c" >> "$CASES"; done
if [ ! -f "$ROOT/.gitleaks.toml" ]; then
  echo "SKIP gitleaks parity: no .gitleaks.toml in this repo (a copy of this guard elsewhere, e.g. the pre-push hook's sandbox)"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
  drift="$(python3 -I - "$ROOT/.gitleaks.toml" "$CASES" <<'EOF'
import re, sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
rule = next(r for r in cfg.get("rules", []) if r["id"] == "home-path")
rx, grp = re.compile(rule["regex"]), rule.get("secretGroup", 0)
allows = [(a.get("regexTarget", "secret"), [re.compile(x) for x in a.get("regexes", [])]) for a in rule.get("allowlists", [])]
def allowed(m):
    target = {"secret": m.group(grp), "match": m.group(0)}
    return any(any(x.search(target.get(t, m.group(grp))) for x in xs) for t, xs in allows)
for line in open(sys.argv[2], encoding="utf-8"):
    want, text = line.rstrip("\n").split("\t", 1)
    got = "R" if any(not allowed(m) for m in rx.finditer(text)) else "C"
    if got != want:
        print(f"want {'flagged' if want == 'R' else 'clean'}, gitleaks rule says {'flagged' if got == 'R' else 'clean'}: {text}")
EOF
)"
  [ -z "$drift" ] && ok || bad "the .gitleaks.toml home-path rule drifted from this guard:"$'\n'"$drift"
else
  echo "SKIP gitleaks parity (regex): python3 with tomllib (3.11+) is not available"
fi
if [ -f "$ROOT/.gitleaks.toml" ] && command -v gitleaks >/dev/null 2>&1; then
  rm -rf "$SB/gl"; mkdir -p "$SB/gl"; i=0
  while IFS=$'\t' read -r want text; do i=$((i + 1)); printf '%s\n' "$text" > "$SB/gl/$want-$i.txt"; done < "$CASES"
  gitleaks dir "$SB/gl" -c "$ROOT/.gitleaks.toml" --no-banner --report-format csv --report-path "$SB/gl.csv" >/dev/null 2>&1
  [ -s "$SB/gl.csv" ] || bad "gitleaks wrote no report (it failed to run with .gitleaks.toml)"
  flagged="$(awk -F, 'NR > 1 && $1 == "home-path" { print $3 }' "$SB/gl.csv" | sed 's#.*/##' | sort -u)"
  miss=""
  for f in "$SB"/gl/*.txt; do
    b="${f##*/}"; hit=C; grep -qxF "$b" <<<"$flagged" && hit=R
    [ "$hit" = "${b%%-*}" ] || miss="$miss"$'\n'"  gitleaks says $hit, want ${b%%-*}: $(cat "$f")"
  done
  [ -z "$miss" ] && ok || bad "real gitleaks disagrees with this guard:$miss"
elif [ -f "$ROOT/.gitleaks.toml" ]; then
  echo "SKIP gitleaks parity (binary): gitleaks is not on PATH (CI's gitleaks job runs this case)"
fi

# ---- (2) the repo itself is clean -------------------------------------------------------------------
found="$(leak_scan "$ROOT")"
if [ -z "$found" ]; then ok; else
  bad "leaks in the repo (remove them, or use a placeholder like /home/u or a noreply address):"
  printf '%s\n' "$found" | head -40 | sed 's/^/  /'
fi

echo "leak-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
