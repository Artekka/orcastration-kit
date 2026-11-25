#!/usr/bin/env bash
# PreToolUse hook (orcastration-kit) for Bash: OPTIONAL git guard. Blocks the git commands that
# silently damage OTHER sessions' work when several sessions share one repo:
#
#   git stash ...            (anything except `stash list` / `stash show`) - stash refs are shared
#                            by every worktree; one session's pop can take another's WIP
#   git add -A | --all | . | :/   and   git add -u with no pathspec - stages other sessions' files
#   git commit -a | --all | -am ... - same, at commit time
#   git pull --rebase | -r   - races on the shared .git/FETCH_HEAD
#
# NO-OP (exit 0, no output) unless ALL hold:
#   - the session's repo carries the opt-in marker docs/orchestration/.kit-hooks;
#   - docs/orchestration/ORCHESTRATION.md says `git_guard: on` (default is `off`).
# Both are read from the MAIN checkout (first `git worktree list` entry), so linked worktrees
# follow the main repo's setting.
#
# The command is tokenized shell-style (quotes, escapes, comments, heredoc bodies, $(...) inside
# double quotes, `bash -c '...'`), so `echo "never git stash"` or a commit message mentioning
# `git add -A` is not blocked. It is a speed bump for an agent, not a sandbox: aliases, eval and
# scripts are not inspected. Deliberately no set -e: a hook must never break a tool call.
# Dependencies: bash, git, awk, grep, sed (POSIX awk; no Python, no jq).
#
# Test mode: GIT_GUARD_CHECK_ONLY=1 skips the opt-in checks and prints the rule id (or nothing).

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0
case "$input" in *git*) ;; *) exit 0 ;; esac   # cheap exit: no 'git' anywhere

if [ "${GIT_GUARD_CHECK_ONLY:-}" != 1 ]; then
  cwd="$(printf '%s' "$input" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 \
    | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' -e 's#\\/#/#g')"
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  [ -d "$cwd" ] || exit 0
  main="$(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  [ -n "$main" ] && [ -d "$main" ] || exit 0
  [ -f "$main/docs/orchestration/.kit-hooks" ] || exit 0
  conf="$main/docs/orchestration/ORCHESTRATION.md"
  [ -f "$conf" ] || exit 0
  grep -Eq '^[[:space:]]*git_guard:[[:space:]]*(on|enforced|true|yes)([[:space:]]|#|$)' "$conf" 2>/dev/null || exit 0
fi

rule="$(printf '%s' "$input" | awk '
function decode(s,   out, i, c, n) {   # JSON string body -> text
  out = ""; i = 1
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\\") {
      n = substr(s, i + 1, 1)
      if (n == "n") out = out "\n"; else if (n == "t") out = out "\t"
      else if (n == "r") out = out ""; else if (n == "u") { out = out "?"; i += 4 }
      else out = out n
      i += 2; continue
    }
    out = out c; i++
  }
  return out
}
function endword() { if (inword) { nw++; W[nw] = cur }; cur = ""; inword = 0 }
function endseg() { endword(); if (nw > 0) check(); nw = 0 }
function isopt(x) { return substr(x, 1, 1) == "-" }
function hit(r) { if (verdict == "") verdict = r }
function check(   k, w, sub_, j, a, dd, upd, np, skip, m, ch, base) {
  k = 1
  while (k <= nw) {
    w = W[k]
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w == "sudo" || w == "command" || w == "exec" || w == "time" \
        || w == "nice" || w == "nohup" || w == "env" || w == "builtin" || w == "!") { k++; continue }
    break
  }
  if (k > nw) return
  base = W[k]; sub(/.*\//, "", base)
  if (base == "bash" || base == "sh" || base == "zsh" || base == "dash" || base == "ksh") {
    for (j = k + 1; j < nw; j++) if (W[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { nq++; Q[nq] = W[j + 1]; break }
    return
  }
  if (base != "git") return
  k++
  while (k <= nw && isopt(W[k])) {
    w = W[k]
    if (w == "-C" || w == "-c" || w == "--git-dir" || w == "--work-tree" || w == "--namespace" \
        || w == "--config-env" || w == "--super-prefix") k += 2; else k++
  }
  if (k > nw) return
  sub_ = W[k]
  if (sub_ == "stash") {
    for (j = k + 1; j <= nw; j++) if (!isopt(W[j])) break
    if (j <= nw && (W[j] == "list" || W[j] == "show")) return
    hit("stash"); return
  }
  if (sub_ == "add") {
    dd = 0; upd = 0; np = 0
    for (j = k + 1; j <= nw; j++) {
      a = W[j]
      if (!dd && a == "--") { dd = 1; continue }
      if (!dd && substr(a, 1, 2) == "--") {
        if (a == "--all" || a == "--no-ignore-removal") { hit("add-all"); return }
        if (a == "--update") upd = 1
        continue
      }
      if (!dd && a ~ /^-[A-Za-z]+$/) {
        if (index(a, "A")) { hit("add-all"); return }
        if (index(a, "u")) upd = 1
        continue
      }
      np++
      if (a == "." || a == "./" || a == ":/" || a == ":/:" || a == ":(top)") { hit("add-all"); return }
    }
    if (upd && np == 0) hit("add-all")
    return
  }
  if (sub_ == "commit") {
    skip = 0
    for (j = k + 1; j <= nw; j++) {
      a = W[j]
      if (skip) { skip = 0; continue }
      if (a == "--") break
      if (substr(a, 1, 2) == "--") {
        if (a == "--all") { hit("commit-all"); return }
        if (a == "--message" || a == "--file" || a == "--author" || a == "--date" || a == "--template" \
            || a == "--reuse-message" || a == "--reedit-message" || a == "--fixup" || a == "--squash" \
            || a == "--trailer" || a == "--cleanup") skip = 1
        continue
      }
      if (a ~ /^-./) {
        for (m = 2; m <= length(a); m++) {
          ch = substr(a, m, 1)
          if (ch == "a") { hit("commit-all"); return }
          if (index("mFCct", ch)) { if (m == length(a)) skip = 1; break }
        }
      }
    }
    return
  }
  if (sub_ == "pull") {
    for (j = k + 1; j <= nw; j++) {
      a = W[j]
      if (a == "--") break
      if (a == "--rebase" || (a ~ /^--rebase=/ && a != "--rebase=false" && a != "--rebase=no")) { hit("pull-rebase"); return }
      if (a ~ /^-[A-Za-z]+$/) {
        for (m = 2; m <= length(a); m++) {
          ch = substr(a, m, 1)
          if (ch == "r") { hit("pull-rebase"); return }
          if (index("sXo", ch)) break
        }
      }
    }
  }
}
function tokenize(t,   i, L, c, n, nl, line, d, q, sp) {
  i = 1; L = length(t); st = ""; sd = 0; cur = ""; inword = 0; nw = 0; nh = 0
  while (i <= L) {
    c = substr(t, i, 1)
    if (st == "s") { if (c == "\047") st = ""; else cur = cur c; i++; continue }
    if (st == "d") {
      if (c == "\\") { n = substr(t, i + 1, 1); if (n != "\n") cur = cur n; i += 2; continue }
      if (c == "$" && substr(t, i + 1, 1) == "(") { sd++; S[sd] = "d"; st = ""; endseg(); i += 2; continue }
      if (c == "\"") st = ""; else cur = cur c
      i++; continue
    }
    if (c == "\\") { n = substr(t, i + 1, 1); if (n != "\n") { cur = cur n; inword = 1 }; i += 2; continue }
    if (c == "\047") { st = "s"; inword = 1; i++; continue }
    if (c == "\"") { st = "d"; inword = 1; i++; continue }
    if (c == "#" && !inword) { while (i <= L && substr(t, i, 1) != "\n") i++; continue }
    if (c == " " || c == "\t") { endword(); i++; continue }
    if (c == "\n") {
      endseg(); i++
      for (q = 1; q <= nh; q++) {            # skip heredoc bodies queued on this line
        while (i <= L) {
          nl = index(substr(t, i), "\n"); line = (nl ? substr(t, i, nl - 1) : substr(t, i))
          i = (nl ? i + nl : L + 1)
          if (HS[q]) sub(/^\t+/, "", line)
          if (line == HD[q]) break
        }
      }
      nh = 0; continue
    }
    if (c == "<" && substr(t, i, 2) == "<<" && substr(t, i, 3) != "<<<") {
      endword(); i += 2; sp = 0
      if (substr(t, i, 1) == "-") { sp = 1; i++ }
      while (substr(t, i, 1) == " " || substr(t, i, 1) == "\t") i++
      d = ""
      while (i <= L) {
        c = substr(t, i, 1)
        if (c ~ /[ \t\n;&|()<>]/) break
        if (c != "\047" && c != "\"" && c != "\\") d = d c
        i++
      }
      nh++; HD[nh] = d; HS[nh] = sp; continue
    }
    if (c == "$" && substr(t, i + 1, 1) == "(") { sd++; S[sd] = ""; endseg(); i += 2; continue }
    if (c == "(") { sd++; S[sd] = ""; endseg(); i++; continue }
    if (c == ")") { endseg(); if (sd > 0) { st = S[sd]; sd-- }; i++; continue }
    if (c == ";" || c == "&" || c == "|" || c == "`") { endseg(); i++; continue }
    cur = cur c; inword = 1; i++
  }
  endseg()
}
{ buf = buf $0 "\n" }
END {
  if (!match(buf, /"command"[ \t\r\n]*:[ \t\r\n]*"/)) exit 0
  rest = substr(buf, RSTART + RLENGTH); s = ""; i = 1
  while (i <= length(rest)) {
    c = substr(rest, i, 1)
    if (c == "\\") { s = s substr(rest, i, 2); i += 2; continue }
    if (c == "\"") break
    s = s c; i++
  }
  verdict = ""; nq = 1; Q[1] = decode(s); qi = 0
  while (qi < nq && qi < 20) { qi++; tokenize(Q[qi]) }
  if (verdict != "") print verdict
}
')"

[ -n "$rule" ] || exit 0
if [ "${GIT_GUARD_CHECK_ONLY:-}" = 1 ]; then printf '%s\n' "$rule"; exit 0; fi

case "$rule" in
  stash) why="git stash is blocked: stash refs are shared by every worktree of this repo, so one session's stash or pop can take another session's work. Instead commit your WIP on your own branch (git commit -m wip, later git reset --soft HEAD~1) or copy the files to a scratch directory. git stash list and git stash show stay allowed." ;;
  add-all) why="Staging everything is blocked (git add -A / --all / . / :/ / -u without paths): in a repo shared by several sessions it stages other sessions' uncommitted files into your commit. Stage explicit paths instead: git add path/to/file another/file." ;;
  commit-all) why="git commit -a / --all is blocked: it commits every modified tracked file, including other sessions' work in progress. Stage explicit paths, then commit: git add path/to/file && git commit -m msg." ;;
  pull-rebase) why="git pull --rebase is blocked: sessions sharing one .git race on .git/FETCH_HEAD (Cannot rebase onto multiple branches). Use: git fetch origin && git rebase origin/main (retry the fetch once if it reports cannot lock ref)." ;;
  *) exit 0 ;;
esac
reason="Blocked by orcastration-kit git guard. $why This guard is on because docs/orchestration/ORCHESTRATION.md sets git_guard: on. A human can still run the command in their own terminal, or turn the guard off with git_guard: off (or by asking Claude to)."
reason="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
