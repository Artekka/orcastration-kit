#!/usr/bin/env bash
# PreToolUse hook (orcastration-kit) for Read|Grep and Bash: OPTIONAL secrets guard. A session never reads a
# key store: the paths the project lists under `never_read:` in docs/orchestration/ORCHESTRATION.md are refused
# for the Read tool, for Grep (a search inside one, or one that would sweep through one), and for a Bash command
# whose text names one (cat, less, gpg, cp ... anything). A key a session needs is the human's job to supply.
#
# NO-OP (exit 0, no output) unless ALL hold:
#   - the session's repo carries the opt-in marker docs/orchestration/.kit-hooks;
#   - docs/orchestration/ORCHESTRATION.md has a `never_read:` block with at least one `- <path>` line below it
#     (the list is the switch: no list, no guard). `~` means the home directory; a directory covers everything
#     beneath it; an entry with `*` is a shell pattern matched against the whole path (e.g. `- *.pem`).
# Both are read from the MAIN checkout (first `git worktree list` entry), so linked worktrees follow it.
# Optional `allow_read:` block (same format): one FILE by its exact path (`~` = home) is let through although a
# never_read entry covers it, until the human removes the line: a Read of exactly that path, a Grep of that one
# file, and a Bash command naming it (K below; "K" and 'K' count as K) in one of these shapes only:
#   NAME=K [NAME2=v ...] <program> <args>          (env, timeout N before it are fine)
#   export NAME=K; <program> <args>                 (or &&)
#   cat K                                           (with | wc -c, | head -c N)
# each optionally after `cd <dir> &&`, with redirections (2>&1, > file) and a last pipe into wc, head or tail.
# Every other word is plain: no other $ of any kind, no quote, backslash, backtick, glob, brace or parenthesis,
# no second K, and none of find, [[, for, select, case, set, declare, typeset, local, readonly, function, alias,
# eval, source, ., read, mapfile, readarray, xargs, exec. Any other command naming K is refused (its message
# names the shapes); one in shape is then checked as any command, K blanked out (a listed path left in it,
# e.g. `cd <listed folder> &&`, is refused). Anything else under never_read stays refused: the folder, a
# sibling, a glob, a `..`, `.` or `//` spelling (the allow match is on the exact spelling, so normalizing only
# ever refuses more).
# An allow entry that is a directory, a symlink, a pattern (* ? [) or not a plain absolute path is ignored.
# Paths are compared NORMALIZED, on both sides (the entries and the path a tool names), by text alone (no
# filesystem access): `~`, `$HOME` and `${HOME}` expanded, `//` collapsed, `.` dropped, `..` resolved, a trailing
# `/` dropped. A relative path is resolved against the call's working directory: the hook input's `cwd` (Read,
# Grep and Bash calls carry it), else CLAUDE_PROJECT_DIR; when neither is known a relative path is refused. In a
# Bash command every path-like word (holding a `/`, starting with `~` or `$HOME`, or `.`/`..`) is checked that way,
# a relative one also against each `cd`/`pushd` target in the same command; the call's own `cwd` is one of the
# words, so a command run inside a listed path is refused too. The command's words are read twice: split at
# quotes and operators as before, and as bash splits them (JSON escapes decoded, quotes removed and the quoted and
# plain pieces of one word joined: "$HOME"/.netrc, ~/'a'/b; \x outside quotes = x; $'..' and $".." read as '..'
# and ".."; a word that is itself a command, as in bash -c '..', sh -c "..", "$(..)", is split again, three
# levels deep; each word is checked whole and in its pieces around = @ : ,). cd targets chain: a relative one is
# resolved against the cd before it as well as the working directory (cd a && cd b = a/b); a bare `cd` goes home;
# -L/-P/-e/-@ flags are skipped and `--` ends them. `~` inside quotes is taken as home too (bash would not expand
# it: refuses more).
# It is a speed bump for an agent, not a sandbox: a path reached through a variable, a glob in the folder part
# (`secre*/`) or in the file-name part of a file entry (`~/.net*`), brace expansion (`~/.{netrc,x}`), `~user`,
# `~+`, `~-`, escapes inside $'..' (\x2f), a directory flag other than cd/pushd (`tar -C`, `git -C`, `env -C`,
# `make -C`), `cd -`, a command nested deeper than three levels, a symlink (links are not followed) or a script
# is not seen, nor what the program does with K once it has it (a script or interpreter that derives the folder
# from the NAME=K value, a file it writes that a later command runs). Known gaps, by choice: pattern entries are
# not checked in Bash commands (only on the paths Read and Grep name), and the Glob tool is not registered, so
# the file NAMES in a listed folder can be listed (never their contents). Deliberately no set -e: a hook must
# never break a tool call.
# Bounded run time: Claude Code drops a hook that passes its time limit and runs the command unchecked, so a Bash
# command with more than 64 distinct cd/pushd targets, or one needing more than 120,000 path checks, is refused
# ("split it into smaller commands") instead of checked for minutes; a word with no `..` is checked only against
# the targets that can lead into an entry (one equal to, above or inside it, or /).
# Dependencies: bash, git, grep, sed, awk, sort.
#
# Test mode: SECRETS_GUARD_CONF=<file> and SECRETS_GUARD_HOME=<dir> skip the repo lookup and use that list.

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

json_str() {  # first value of a top-level-looking string key (JSON escapes inner quotes as \")
  printf '%s' "$input" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -n1 \
    | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' -e 's#\\/#/#g'
}
tool="$(json_str tool_name)"
case "$tool" in Read|Grep|Bash) ;; *) exit 0 ;; esac

home="${SECRETS_GUARD_HOME:-$HOME}"
if [ -n "${SECRETS_GUARD_CONF:-}" ]; then
  conf="$SECRETS_GUARD_CONF"
else
  cwd="$(json_str cwd)"; [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  [ -d "$cwd" ] || exit 0
  main="$(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  [ -n "$main" ] && [ -d "$main" ] || exit 0
  [ -f "$main/docs/orchestration/.kit-hooks" ] || exit 0
  conf="$main/docs/orchestration/ORCHESTRATION.md"
fi
[ -f "$conf" ] || exit 0
# The entries: the `- ` lines right after `never_read:` (blank lines and comments between them are fine).
block() { awk -v key="$1" '
  $0 ~ "^[[:space:]]*" key ":[[:space:]]*(#.*)?$" { on = 1; next }
  on && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+#.*$/, ""); sub(/[[:space:]]+$/, ""); gsub(/^`|`$/, ""); if ($0 != "") print; next }
  on && /^[[:space:]]*(#.*)?$/ { next }
  on { on = 0 }
' "$conf" 2>/dev/null; }
entries="$(block never_read)"
[ -n "$entries" ] || exit 0

# Where a relative path starts: the call's own cwd, else CLAUDE_PROJECT_DIR; "" = unknown (relative is refused).
wd="$(json_str cwd)"; [ -n "$wd" ] || wd="${CLAUDE_PROJECT_DIR:-}"

# norm path: each stdin line is a path -> its normalized absolute form ("?" = relative, no working directory).
# norm cmd:  stdin is a Bash call's text -> the first word that lands in a listed (non-pattern) entry, normalized,
#            else "?" when a relative path-like word has no working directory to start from, else nothing.
norm() { awk -v mode="$1" -v home="$home" -v wd="$wd" -v ents="${2:-}" '
  function nrm(p,   n, s, i, k, out, st) {
    n = split(p, s, "/"); k = 0
    for (i = 1; i <= n; i++) {
      if (s[i] == "" || s[i] == ".") continue
      if (s[i] == "..") { if (k > 0) k--; continue }
      st[++k] = s[i]
    }
    out = ""; for (i = 1; i <= k; i++) out = out "/" st[i]
    return out == "" ? "/" : out
  }
  function xp(t) {
    if (t == "~" || t == "$HOME" || t == "${HOME}") return home
    if (substr(t, 1, 2) == "~/") return home substr(t, 2)
    if (substr(t, 1, 6) == "$HOME/") return home substr(t, 6)
    if (substr(t, 1, 8) == "${HOME}/") return home substr(t, 8)
    return t
  }
  function absn(t, base) { t = xp(t); if (substr(t, 1, 1) == "/") return nrm(t); if (base == "") return "?"; return nrm(base "/" t) }
  function inside(p,   k) { for (k = 1; k <= ne; k++) if (E[k] != "" && (p == E[k] || index(p, E[k] "/") == 1)) return 1; return 0 }
  # a work budget: past CHECKCAP path checks the command is refused ("?big") rather than let the hook overrun
  function check(p) { if (++nchk > CHECKCAP) { print "?big"; done = 1; exit } if (inside(p)) { print p; done = 1; exit } }
  # rel(k): can a word with no ".." segment, resolved against target b[k], land in an entry? Only when b[k] is
  # "/", equal to an entry, above one, or inside one: the resolved path always starts with b[k].
  function rel(k,   e) {
    if (k in RB) return RB[k]
    if (b[k] == "/") return RB[k] = 1
    for (e = 1; e <= ne; e++) if (E[e] != "" && (b[k] == E[e] || index(E[e], b[k] "/") == 1 || index(b[k], E[e] "/") == 1)) return RB[k] = 1
    return RB[k] = 0
  }
  # a cd/pushd target to resolve words against: duplicates dropped; past CDCAP distinct targets the command is
  # refused at once ("?cd"), because every word is checked against every target and the hook must finish inside
  # its time limit (a hook past its limit is dropped and the command runs unchecked)
  function addb(x) { if (x in seenb) return; seenb[x] = 1; if (nb >= CDCAP) { print "?cd"; done = 1; exit } b[++nb] = x }
  mode == "path" { print absn($0, wd); next }
  mode == "ents" { if (index($0, "*")) print $0 "\t" $0; else { r = absn($0, ""); if (r != "?") print r "\t" $0 }; next }
  # tok: appends the command as bash splits it into words to T[1..nt] ("\001" marks an operator or the end): quotes removed
  # and the quoted and plain pieces of one word joined, \x = x outside quotes, $'..' and $".." read as '..' and "..".
  function tok(s,   i, n, c, q, cur, inw, nx) {
    n = length(s); q = ""; cur = ""; inw = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (q == "\047") { if (c == "\047") q = ""; else cur = cur c; continue }
      if (q == "\"") {
        if (c == "\"") { q = ""; continue }
        if (c == "\\") { nx = substr(s, i + 1, 1); if (nx ~ /[$`"\\]/) { cur = cur nx; i++; continue } if (nx == "\n") { i++; continue } }
        cur = cur c; continue
      }
      if (c == "$" && substr(s, i + 1, 1) ~ /[\047"]/) continue
      if (c == "\047" || c == "\"") { q = c; inw = 1; continue }
      if (c == "\\") { nx = substr(s, ++i, 1); if (nx != "\n" && nx != "") { cur = cur nx; inw = 1 } continue }
      if (c ~ /[ \t\r\n]/) { if (inw) T[++nt] = cur; cur = ""; inw = 0; continue }
      if (c ~ /[;|&()<>`]/) { if (inw) T[++nt] = cur; cur = ""; inw = 0; T[++nt] = "\001"; continue }
      cur = cur c; inw = 1
    }
    if (inw) T[++nt] = cur
    T[++nt] = "\001"
  }
  function cw(t,   bare, j, up) {  # one word: a path-like word, or a bare word (no /) as a name inside a working directory
    if (t == "" || substr(t, 1, 1) == "-") return
    bare = !(index(t, "/") || t == "." || t == ".." || substr(t, 1, 1) == "~" || t ~ /^\$\{?HOME/)
    t = xp(t)
    if (substr(t, 1, 1) == "/") { check(nrm(t)); return }
    if (nb == 0) { if (!bare) unk = 1; return }
    up = index("/" t "/", "/../")
    for (j = 1; j <= nb; j++) if (up || rel(j)) check(nrm(b[j] "/" t))
  }
  { buf = buf $0 "\n" }
  END {
    if (mode != "cmd" || done) exit
    ne = split(ents, E, "\n")
    # the command (decoded) and the rest of the call (raw JSON: its \n and \t escapes read as spaces)
    k = index(buf, "\002"); if (k) { cmd = substr(buf, 1, k - 1); rest = substr(buf, k + 1) } else { cmd = buf; rest = "" }
    gsub(/\\[nt]/, " ", rest)
    n = split(cmd " " rest, w, /[[:space:];|&()<>`\047"=@:,]+/)
    # a word that is itself a command (bash -c '..', "$(..)", ssh h ".."): split again, three levels deep
    nt = 0; tok(cmd); s0 = 1
    for (lv = 1; lv <= 3; lv++) { e0 = nt; for (i = s0; i <= e0; i++) if (T[i] != "\001" && T[i] ~ /[ \t\r\n\047"\\;|&()<>`]/) tok(T[i]); s0 = e0 + 1 }
    nb = 0; CDCAP = 64; CHECKCAP = 120000; nchk = 0; if (wd != "") addb(absn(wd, ""))
    for (i = 1; i < n; i++)
      if ((w[i] == "cd" || w[i] == "pushd") && w[i + 1] != "" && substr(w[i + 1], 1, 1) != "-") {
        x = absn(w[i + 1], wd); if (x == "?") unk = 1; else addb(x)
      }
    # cd/pushd on the bash words: flags skipped, a bare cd goes home, a relative target resolved against the
    # previous target too (cd a && cd b = a/b), as well as against the working directory
    cur = (wd != "") ? absn(wd, "") : ""
    for (i = 1; i < nt; i++) {
      if (T[i] != "cd" && T[i] != "pushd") continue
      for (j = i + 1; j < nt && T[j] ~ /^-[LPe@]+$/; j++) ;
      if (T[j] == "--") j++   # "--" ends the flags: the next word is the target (none = home, for cd)
      t = T[j]
      if (t == "\001") { if (T[i] == "cd") { cur = nrm(home); addb(cur) } continue }
      if (t == "-") continue
      x = absn(t, cur); y = absn(t, wd)
      if (x != "?") addb(x); if (y != "?") addb(y)
      if (x == "?" && y == "?") unk = 1
      cur = (x != "?") ? x : y; if (cur == "?") cur = ""
    }
    for (i = 1; i <= n; i++) cw(w[i])
    # each bash word whole, and its pieces around = @ : , (NAME=path, --file=path, user@host:path)
    for (i = 1; i <= nt; i++) {
      if (T[i] == "\001") continue
      cw(T[i]); m = split(T[i], pc, /[=@:,]+/); if (m > 1) for (j = 1; j <= m; j++) cw(pc[j])
    }
    if (unk) print "?"
  }'; }

# The entries normalized once ("<normalized>\t<as written>"); a pattern stays as written, a relative entry is dropped.
nentries="$(printf '%s\n' "$entries" | norm ents)"

expand() {  # ~ and $HOME -> the home directory; trailing / dropped (the as-written spellings of the text check)
  local p="$1"
  case "$p" in "~") p="$home" ;; "~/"*) p="$home/${p#\~/}" ;; '$HOME') p="$home" ;; '$HOME/'*) p="$home/${p#\$HOME/}" ;; esac
  printf '%s' "${p%/}"
}
hit=""
guarded() {  # <normalized absolute path> [sweep] [no patterns]: inside, equal to, or (sweep) above a listed entry?
  local p="$1" sweep="${2:-0}" nopat="${3:-0}" x e
  while IFS=$'\t' read -r x e; do
    [ -n "$x" ] || continue
    case "$x" in
      *\**) [ "$nopat" = 1 ] && continue; case "$p" in $x) hit="$e"; return 0 ;; esac ;;
      *) case "$p" in "$x"|"$x"/*) hit="$e"; return 0 ;; esac
         [ "$sweep" = 1 ] && { [ "$p" = / ] || case "$x" in "$p"/*) true ;; *) false ;; esac; } && { hit="$e"; return 0; } ;;
    esac
  done <<<"$nentries"
  return 1
}
absolute() {  # as written, for the exact allow_read match: relative -> against the working directory (if known)
  local p="$1"
  case "$p" in "~"|"~/"*|'$HOME'|'$HOME/'*) p="$(expand "$p")" ;; esac
  if [ "${p#/}" = "$p" ] && [ -n "$wd" ]; then p="$wd/$p"; fi
  printf '%s' "$p"
}

# The allowed files: plain absolute file paths only (no pattern, no . / .. / // spelling, no directory, no symlink).
allowed=""
while IFS= read -r e; do
  [ -n "$e" ] || continue
  x="$(expand "$e")"
  case "$x" in /*) ;; *) continue ;; esac
  case "$x" in *[\*\?\[]*|*//*|*/./*|*/../*|*/..) continue ;; esac
  [ -d "$x" ] || [ -L "$x" ] && continue
  allowed="$allowed$x"$'\n'
done <<<"$(block allow_read)"
is_allowed() { [ -n "$allowed" ] && [ -n "$1" ] && printf '%s' "$allowed" | grep -qxF -- "$1"; }

json_cmd() {  # <cmd|rest>: tool_input.command with its JSON escapes decoded (cmd), or the input without that value
  printf '%s' "$input" | awk -v want="$1" 'BEGIN { RS = "\001" } { s = s $0 } END {
    k = index(s, "\"command\""); i = k + 9; n = length(s)
    while (k && i <= n && substr(s, i, 1) ~ /[ \t\r\n:]/) i++
    if (!k || substr(s, i, 1) != "\"") { if (want == "rest") printf "%s", s; exit }
    st = i; i++; out = ""
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "\"") break
      if (c == "\\") {
        e = substr(s, i + 1, 1); i += 2
        if (e == "n") c = "\n"; else if (e == "t") c = "\t"; else if (e == "r") c = "\r"
        else if (e == "b" || e == "f") c = " "; else if (e == "u") c = "`"; else c = e   # \uXXXX: a marker, never a plain word
      } else i++
      out = out c
    }
    if (want == "cmd") printf "%s", out; else printf "%s", substr(s, 1, st - 1) substr(s, i + 1)
  }'
}
# Bash with an allow list: a command that names an allowed file passes only in one of the shapes the header lists
# (the file reaches one program as an environment value, or cat reads it whole); any other command naming an
# allowed file under never_read is refused. A command in shape is then checked as before, the file blanked out.
allow_bash() {
  local cmd rest list len x form c hitx="" re W A AK P R T F S1 S2 S3 nl=$'\n' k=$'\001'
  cmd="$(json_cmd cmd)"; rest="$(json_cmd rest | sed 's#\\/#/#g')"
  list="$(while IFS= read -r x; do
      [ -n "$x" ] || continue
      for form in "$x" "~/${x#"$home"/}" "\$HOME/${x#"$home"/}"; do
        case "$form" in "~/$x"|"\$HOME/$x") continue ;; esac
        case "$cmd$nl$rest" in *"$form"*) printf '%s\t%s\t%s\n' "${#form}" "$x" "$form" ;; esac
      done
    done <<<"$allowed" | sort -rn)"   # longest first: an allowed name that starts another is replaced after it
  [ -n "$list" ] || return 0
  c="$cmd"
  while IFS=$'\t' read -r len x form; do
    [ -n "$form" ] || continue
    case "$c" in *"$form"*) guarded "$x" && hitx="$x" ;; esac
    c="${c//"$form"/$k}"; rest="${rest//"$form"/<allowed file>}"
  done <<<"$list"
  re="\"$k\""; c="${c//"$re"/$k}"; re="'$k'"; c="${c//"$re"/$k}"   # "K" and 'K' are K
  case "$c" in *"$k"*) ;; *) bcmd="$cmd"; brest="$rest"; return 0 ;; esac
  # The shapes. W: a plain word (no $, quote, backslash, glob, brace, paren or the allowed file).
  W='[A-Za-z0-9_./:%+,=@~-]+'
  A='[A-Za-z_][A-Za-z0-9_]*=('"$W"')?'; AK='[A-Za-z_][A-Za-z0-9_]*='"$k"
  P='((timeout[ 	]+[0-9]+[smhd]?|env)[ 	]+)*'
  R='([ 	]*[0-9]?(>>?|<)(&[0-9]+|[ 	]*'"$W"'))*'
  T='([ 	]*[|][ 	]*(wc|head|tail)([ 	]+'"$W"')*)?'
  S1="$P(($A|$AK)[ 	]+)*$AK([ 	]+($A|$AK))*[ 	]+$P$W([ 	]+$W)*$R$T"     # NAME=K [NAME2=v ...] program args
  S2="export[ 	]+$AK[ 	]*(;|&&)[ 	]*$P$W([ 	]+$W)*$R$T"                # export NAME=K; program args
  S3="cat[ 	]+$k$R$T"                                                      # cat K [| wc -c]
  re="^[ 	]*(cd[ 	]+$W[ 	]*&&[ 	]*)?($S1|$S2|$S3)[ 	]*\$"
  F='(^|[ 	;&|])(find|eval|source|[.]|declare|typeset|local|readonly|set|for|select|case|function|alias|mapfile|readarray|read|xargs|exec|\[\[)([ 	;&|]|$)'
  if [[ ! $c =~ $re ]] || [[ $c =~ $F ]]; then
    [ -n "$hitx" ] || { bcmd="$cmd"; brest="$rest"; return 0; }
    what="a command naming the allowed file $hitx outside the allowed shapes: NAME=<file> before one program"
    what="$what (env, timeout N, a leading cd <dir> && and a pipe into wc, head or tail are fine), export NAME=<file>;"
    what="$what <program>, or cat <file> | wc -c; no other \$, backtick, find, [[, for, set, declare, eval or source"
    return 0
  fi
  bcmd="${c//$k/<allowed file>}"; brest="$rest"
}

nowd="a relative path, and the hook knows no working directory to resolve it against"
what=""; why="That path is listed under never_read in docs/orchestration/ORCHESTRATION.md: sessions never read key stores."
case "$tool" in
  Read)
    path="$(json_str file_path)"; [ -n "$path" ] || exit 0
    is_allowed "$(absolute "$path")" && exit 0
    np="$(printf '%s\n' "$path" | norm path)"
    if [ "$np" = "?" ]; then what="reading $path ($nowd)"; else guarded "$np" && what="reading $path"; fi ;;
  Grep)
    path="$(json_str path)"; [ -n "$path" ] || path="."
    is_allowed "$(absolute "$path")" && exit 0
    np="$(printf '%s\n' "$path" | norm path)"
    if [ "$np" = "?" ]; then what="searching $path ($nowd)"; else guarded "$np" 1 && what="searching $path"; fi ;;
  Bash)
    # the command with its JSON escapes decoded (\" -> "), and the rest of the call (cwd, description ...) as sent
    bcmd="$(json_cmd cmd)"; brest="$(json_cmd rest | sed 's#\\/#/#g')"
    # 0. an allowed file passes only in the allowed shapes, then is blanked out of the text (allow_bash)
    [ -n "$allowed" ] && allow_bash
    body="$bcmd"$'\n'"$brest"
    # 1. the text as written names a listed path (in any of its spellings)
    [ -z "$what" ] && while IFS= read -r e; do
      [ -n "$e" ] || continue
      x="$(expand "$e")"; case "$x" in *\**) continue ;; esac   # patterns are checked on real paths only
      for form in "$x" "~/${x#"$home"/}" "\$HOME/${x#"$home"/}"; do
        case "$form" in "~/$x"|"\$HOME/$x") continue ;; esac     # x was not under home: skip the made-up forms
        case "$body" in *"$form"*) hit="$e"; what="a command naming $form"; break 2 ;; esac
      done
    done <<<"$entries"
    # 2. a word of the command, normalized (relative ones against the working directory and each cd target),
    #    lies in a listed path; patterns are not checked here (a known gap, see the header)
    if [ -z "$what" ]; then
      ents=""; while IFS=$'\t' read -r x e; do case "$x" in ""|*\**) ;; *) ents="$ents$x"$'\n' ;; esac; done <<<"$nentries"
      np="$(printf '%s\002%s' "$bcmd" "$brest" | norm cmd "$ents" | head -n1)"
      if [ "$np" = "?big" ]; then what="a command too long to check in time (split it into smaller commands)"
      elif [ "$np" = "?cd" ]; then what="a command with more than 64 cd/pushd targets, too many to check in time (split it into smaller commands)"
      elif [ "$np" = "?" ]; then what="a command with $nowd"
      elif [ -n "$np" ]; then guarded "$np" 0 1; what="a command reaching $np"; fi
    fi ;;
esac
[ -n "$what" ] || exit 0
case "$what" in *"$nowd"*) why="With a never_read list in force, a path the hook cannot place is refused rather than passed." ;; esac

reason="Blocked by orcastration-kit secrets guard: $what. $why If the work needs a key, stop and ask the human (through the seat under a banner); it is theirs to supply. The human can remove the entry, or let one file through by its exact path under allow_read."
reason="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
