#!/usr/bin/env bash
# Tests for the sibling name pool (`names:` in the team block, `--names` on start-team.sh).
# Run: bash tests/sibling-names.test.sh
# Nothing is launched: every call is --dry-run --terminal manual, in the same sandbox as
# tests/lean-launch.test.sh (HOME is a temp dir; real Windows/macOS/tmux tools are shadowed by stand-ins).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/scripts/start-team.sh"
case "$ROOT" in *[[:space:]]*) echo "sibling-names: SKIP (the kit's path has a space: $ROOT)"; exit 0 ;; esac
TMP="$(mktemp -d)"; pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL $1: want '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail=$((fail+1)); echo "FAIL $1: did not want '$2' in: $3" ;; *) pass=$((pass+1)) ;; esac; }
count() {
  local n; n="$(printf '%s\n' "$4" | grep -cE -- "$3")"
  if [ "$n" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: want $2 lines matching '$3', got $n in: $4"; fi
}
STUBS="$TMP/real-tool-stubs"; mkdir -p "$STUBS"
for t in wt.exe powershell.exe cmd.exe osascript tmux; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 99\n' "$t" "$TMP/REAL-TOOL-CALLED" > "$STUBS/$t"; chmod +x "$STUBS/$t"
done
lrun() { env HOME="$TMP" WSL_DISTRO_NAME= WSL_INTEROP= TMUX= "PATH=$STUBS:$PATH" "$@"; }
st() { lrun bash "$ST" --dry-run --terminal manual --repo "$ROOT" --seat ZzSeat "$@" 2>&1; echo "rc=$?"; }

# 1. A pool from the flag, in list order: the first N names, and no numbered siblings.
out="$(TEAM_NAMES_SHUFFLE=0 st --siblings 2 --names ZzMars,ZzVenus,ZzJuno)"
has "flag pool: first name launched" "LAUNCH ZzMars" "$out"
has "flag pool: second name launched" "LAUNCH ZzVenus" "$out"
hasnt "flag pool: only N siblings" "LAUNCH ZzJuno" "$out"
hasnt "flag pool: no numbered sibling" "Sib1" "$out"
has "flag pool: the seat still launches" "LAUNCH ZzSeat" "$out"
has "flag pool: dry-run names the pool" "names=ZzMars,ZzVenus,ZzJuno" "$out"
has "flag pool: exit 0" "rc=0" "$out"

# 2. A pool from the team block of a repo's ORCHESTRATION.md.
R="$TMP/repo"; mkdir -p "$R/docs/orchestration"; git -C "$R" init -q
printf 'team:\n  seat:             ZzSeat\n  names:            ZzJanus,ZzPluto\n  siblings:         2\n' > "$R/docs/orchestration/ORCHESTRATION.md"
out="$(TEAM_NAMES_SHUFFLE=0 lrun bash "$ST" --dry-run --terminal manual --repo "$R" 2>&1; echo "rc=$?")"
has "team block pool: first name" "LAUNCH ZzJanus" "$out"
has "team block pool: second name" "LAUNCH ZzPluto" "$out"
has "team block pool: config source shown" "config: team: block" "$out"

# 3. The seat's own name in the pool is never a sibling.
out="$(TEAM_NAMES_SHUFFLE=0 st --siblings 2 --names ZzSeat,ZzDiana,ZzFlora)"
count "seat in pool: launched once" 1 '^LAUNCH ZzSeat$' "$out"
has "seat in pool: next names used" "LAUNCH ZzFlora" "$out"

# 4. A pool too small for N, and a bad name, both refuse with exit 64.
out="$(st --siblings 3 --names ZzMars,ZzVenus)"
has "small pool: refused" "rc=64" "$out"
has "small pool: says why" "usable names for 3 siblings" "$out"
out="$(st --siblings 1 --names 'ZzMars,Zz Bad')"
has "bad name: refused" "rc=64" "$out"

# 5. A pool name that is already running is kept (SKIP), and counts toward N.
(exec -a "claude --name ZzJuno" sleep 60) & pids="$pids $!"
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f '^claude --name ZzJuno( |$)' >/dev/null && break; sleep 0.2; done
out="$(TEAM_NAMES_SHUFFLE=0 st --siblings 2 --names ZzCeres,ZzJuno,ZzVesta)"
has "running name: kept" "SKIP   ZzJuno" "$out"
has "running name: one more drawn" "LAUNCH ZzCeres" "$out"
hasnt "running name: no third sibling" "LAUNCH ZzVesta" "$out"

# 6. Shuffled draws always come from the pool, distinct, N of them.
for _ in 1 2 3 4 5 6; do
  out="$(st --siblings 3 --names ZzA,ZzB,ZzC,ZzD,ZzE)"
  count "shuffle: three siblings plus the seat" 4 '^LAUNCH ' "$out"
  got="$(printf '%s\n' "$out" | sed -n 's/^LAUNCH //p' | grep -v ZzSeat | sort)"
  if [ "$(printf '%s\n' "$got" | sort -u | wc -l)" = 3 ] && ! printf '%s\n' "$got" | grep -qvE '^Zz[A-E]$'; then
    pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL shuffle: want 3 distinct pool names, got: $got"; fi
done

# 7. No pool: numbered siblings, as before.
out="$(st --siblings 2 --prefix ZzSib)"
has "no pool: numbered sibling 1" "LAUNCH ZzSib1" "$out"
has "no pool: numbered sibling 2" "LAUNCH ZzSib2" "$out"

# 8. Numbered: w1-<name>, w2-<name>... in list order; a running one keeps its number, a new one takes the lowest free.
out="$(TEAM_NAMES_SHUFFLE=0 st --siblings 2 --names ZzOrion,ZzApollo,ZzMars --numbered w)"
has "numbered: first" "LAUNCH w1-ZzOrion" "$out"
has "numbered: second" "LAUNCH w2-ZzApollo" "$out"
count "numbered: only N" 0 '^LAUNCH .*ZzMars' "$out"
(exec -a "claude --name w2-ZzCeres" sleep 60) & pids="$pids $!"
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f '^claude --name w2-ZzCeres( |$)' >/dev/null && break; sleep 0.2; done
out="$(TEAM_NAMES_SHUFFLE=0 st --siblings 3 --names ZzPluto,ZzCeres,ZzJanus --numbered w)"
has "numbered: running keeps its number" "SKIP   w2-ZzCeres" "$out"
has "numbered: lowest free number" "LAUNCH w1-ZzPluto" "$out"
has "numbered: skips the held number" "LAUNCH w3-ZzJanus" "$out"
count "numbered: no second Ceres" 0 '^LAUNCH .*ZzCeres' "$out"
printf 'team:\n  seat:             ZzSeat\n  names:            ZzJanus,ZzPluto\n  numbered:         w\n  siblings:         2\n' > "$R/docs/orchestration/ORCHESTRATION.md"
out="$(TEAM_NAMES_SHUFFLE=0 lrun bash "$ST" --dry-run --terminal manual --repo "$R" 2>&1; echo "rc=$?")"
has "numbered from the team block" "LAUNCH w1-ZzJanus" "$out"
out="$(st --siblings 1 --names ZzMars --numbered 'w1')"
has "numbered: bad prefix refused" "rc=64" "$out"

if [ -e "$TMP/REAL-TOOL-CALLED" ]; then fail=$((fail+1)); echo "FAIL a real-tool stand-in was executed: $(cat "$TMP/REAL-TOOL-CALLED")"; else pass=$((pass+1)); fi
echo "sibling-names: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
