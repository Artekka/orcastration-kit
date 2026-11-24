#!/usr/bin/env bash
# Tests for scripts/ctx-fill.py --line / --check / --host: a fill report is measured, then checkable.
# The seat pastes `--line` output into a report and verifies it with `--check`. The check compares the claim with
# the fill at the last assistant turn at or before the claimed time by EXACT equality, so an understated guess
# fails as surely as an overstated one. Run: bash tests/ctx-fill-line.test.sh
# Needs python3. HOME is a sandbox with two fake accounts; the clock is CTX_FILL_NOW (epoch seconds), TZ=UTC.
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux: a suite run in a pane once renamed real windows (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CF="$ROOT/scripts/ctx-fill.py"
command -v python3 >/dev/null 2>&1 || { echo "ctx-fill-line: skipped (no python3)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has() {  # <label> <want substring> <got>
  case "$3" in *"$2"*) ok ;; *) bad "$1: want '$2' in: $3" ;; esac
}
hasnt() {  # <label> <unwanted substring> <got>
  case "$3" in *"$2"*) bad "$1: did not want '$2' in: $3" ;; *) ok ;; esac
}
starts() {  # <label> <want prefix> <got>   (a substring test cannot tell MATCH from MISMATCH)
  case "$3" in "$2"*) ok ;; *) bad "$1: want output starting with '$2', got: $3" ;; esac
}
eq() {  # <label> <want> <got>
  [ "$2" = "$3" ] && ok || bad "$1: want '$2' got '$3'"
}

export HOME="$TMP/home"; export TZ=UTC; unset CLAUDE_CONFIG_DIR CLAUDE_CODE_SESSION_ID
ACCT1="$HOME/.claude/projects/-work-app"
ACCT2="$HOME/.claude-acct2/projects/-work-app--worktrees-s5"   # a worktree project dir on a second account
mkdir -p "$ACCT1" "$ACCT2"

# transcript <file> <ts:fill>... — assistant turns with a timestamp and an exact prompt size
transcript() {
  local f="$1"; shift
  python3 - "$f" "$@" <<'PY'
import json, sys
f, turns = sys.argv[1], sys.argv[2:]
with open(f, "w") as fh:
    for t in turns:
        ts, fill = t.rsplit(":", 1) if t.count("Z:") else (None, t)
        o = {"type": "assistant", "message": {"model": "claude-sonnet-5-5",
             "usage": {"input_tokens": 10, "cache_read_input_tokens": int(fill) - 10, "cache_creation_input_tokens": 0},
             "content": [{"type": "text", "text": "ok"}]}}
        if ts:
            o["timestamp"] = ts
        fh.write(json.dumps(o) + "\n")
PY
}
epoch() { date -u -d "${2:-2026-10-30} $1" +%s; }                 # epoch "22:30:00" [day]
cf()    { python3 "$CF" "$@" 2>&1; }                              # stdout+stderr
cfo()   { python3 "$CF" "$@" 2>/dev/null; }                       # stdout only
T3="2026-10-30T22:00:00.500Z:100000 2026-10-30T22:10:00.250Z:240000 2026-10-30T22:20:00.750Z:263053"
U=3f9a1c2e-0000-4000-8000-000000000001
# shellcheck disable=SC2086
transcript "$ACCT2/$U.jsonl" $T3
transcript "$ACCT1/aaaa0001-0000-4000-8000-000000000002.jsonl" $T3
# two sessions sharing the 8-char prefix bbbb0002, one per account
transcript "$ACCT1/bbbb0002-0000-4000-8000-000000000003.jsonl" $T3
transcript "$ACCT2/bbbb0002-ffff-4000-8000-000000000004.jsonl" $T3

line() {  # <fill> <hms> [window] [marks] [status] [prefix]
  echo "fill $1 / ${3:-1,000,000} · marks ${4:-350,000/400,000} · ${5:-OK} · measured 2026-10-30 $2 UTC · session ${6:-3f9a1c2e}"
}
check() { CTX_FILL_NOW="$(epoch "$2")" python3 "$CF" --check "$1" 2>&1; echo "rc=$?"; }   # <claim> <now hms>

# ── --line: exactly one paste line ───────────────────────────────────────────
F="$TMP/$U.jsonl"; transcript "$F" $T3
out="$(CTX_FILL_NOW="$(epoch 22:42:07)" cfo "$F" --window 1m --line)"
eq "--line exact output" "fill 263,053 / 1,000,000 · marks 350,000/400,000 · OK · measured 2026-10-30 22:42:07 UTC · session 3f9a1c2e" "$out"

status_at() {  # <fill> <window> -> the --line output
  local f="$TMP/c0000001-0000-4000-8000-000000000009.jsonl"
  transcript "$f" "2026-10-30T22:00:00.000Z:$1"
  CTX_FILL_NOW="$(epoch 22:01:00)" cfo "$f" --window "$2" --line
}
has "OK below the prompt mark" " · OK · " "$(status_at 349999 1m)"
has "AT-PROMPT-MARK at 350,000" " · AT-PROMPT-MARK · " "$(status_at 350000 1m)"
has "PAST-HANDOVER at 400,000" " · PAST-HANDOVER · " "$(status_at 400000 1m)"
has "200K window line" "fill 130,000 / 200,000 · marks 120,000/150,000 · AT-PROMPT-MARK · " "$(status_at 130000 200k)"
has "a token-count window works too" "fill 130,000 / 200,000 · marks 120,000/150,000" "$(status_at 130000 200000)"

# --line needs a stated window: the transcript cannot tell, so a line would carry a guess
out="$(cf "$F" --line; echo "rc=$?")"
has "--line without --window exits 2" "rc=2" "$out"
has "--line without --window says why" "--window" "$out"
hasnt "--line without --window prints no fill line" "fill 263" "$out"

# a wall hit is a status of its own, never OK
W="$TMP/c0000002-0000-4000-8000-000000000009.jsonl"
{ transcript "$W" "2026-10-30T22:00:00.000Z:90000"; printf '{"type":"assistant","timestamp":"2026-10-30T22:00:30.000Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Prompt is too long"}]}}\n' >> "$W"; }
has "wall-hit status in the line" " · WALL-HIT · " "$(CTX_FILL_NOW="$(epoch 22:01:00)" cfo "$W" --window 200k --line)"

# ── --check ──────────────────────────────────────────────────────────────────
out="$(check "$(line 263,053 22:20:30)" 22:30:00)"
starts "MATCH (found via account 2's worktree dir)" "MATCH" "$out"; has "MATCH exit 0" "rc=0" "$out"
out="$(check "$(line 240,000 22:15:00)" 22:40:00)"
starts "an older claim matches its own turn" "MATCH" "$out"
has "growth since the claim is printed" "263,053" "$out"
out="$(check "$(line 250,000 22:20:30)" 22:30:00)"
has "understated guess is a MISMATCH" "MISMATCH" "$out"; has "MISMATCH exit 3" "rc=3" "$out"
has "mismatch shows the claim" "250,000" "$out"; has "mismatch shows the real fill" "263,053" "$out"
out="$(check "$(line 240,000 22:20:30)" 22:30:00)"
starts "the previous turn's fill is allowed (flush lag)" "MATCH" "$out"
out="$(check "$(line 100,000 22:20:30)" 22:30:00)"
has "two turns back is a MISMATCH" "MISMATCH" "$out"
out="$(check "$(line 270,000 22:20:30)" 22:30:00)"
has "overstated guess is a MISMATCH" "MISMATCH" "$out"
out="$(check "$(line 263,053 22:20:30)" 23:00:00)"
has "a claim over 30 minutes old is STALE" "STALE" "$out"; has "STALE exit 3" "rc=3" "$out"
out="$(check "$(line 263,053 22:45:00)" 22:30:00)"
has "a future claim is a MISMATCH" "MISMATCH" "$out"; has "future says so" "future" "$out"
out="$(check "$(line 263,053 22:20:00)" 22:25:00)"
starts "stamp has whole seconds: turn at :00.750 matches :00" "MATCH" "$out"
out="$(check "$(line 100,000 21:00:00)" 21:10:00)"
has "a claim before the first turn has nothing to match" "MISMATCH" "$out"
out="$(check "\`$(line 263,053 22:20:30)\`" 22:30:00)"
starts "backtick-wrapped line accepted" "MATCH" "$out"
out="$(check "\"$(line 263,053 22:20:30)\"" 22:30:00)"
starts "quoted line accepted" "MATCH" "$out"

for badclaim in "fill about 200K" "~200K" "current   263,053" \
    "fill 263,053 / 1,000,000 · measured 2026-10-30 22:20:30 UTC" \
    "$(line 263,053 22:20:30 1,000,000 120,000/150,000)" \
    "$(line 263,053 22:20:30 300,000 350,000/400,000)" \
    "$(line 263,053 22:20:30 1,000,000 350,000/400,000 MADE-UP)"; do
  out="$(check "$badclaim" 22:30:00)"
  has "not a line: $badclaim" "rc=2" "$out"
  has "not a line message: $badclaim" "not a ctx-fill line (guessed?)" "$out"
done
out="$(check "$(line 263,053 22:20:30 1,000,000 350,000/400,000 OK deadbeef)" 22:30:00)"
has "NOSESSION" "NOSESSION" "$out"; has "NOSESSION exit 3" "rc=3" "$out"
out="$(check "$(line 263,053 22:20:30 1,000,000 350,000/400,000 OK bbbb0002)" 22:30:00)"
has "AMBIGUOUS (one per account)" "AMBIGUOUS" "$out"; has "AMBIGUOUS exit 3" "rc=3" "$out"

# --line then --check on a transcript tail: --line runs INSIDE a tool call, so it cannot see its own turn.
D="$TMP/home/.claude/projects/-work-app"
transcript "$D/dddd0004-0000-4000-8000-000000000008.jsonl" "2026-10-31T02:05:50.000Z:294947" "2026-10-31T02:05:55.958Z:295858"
BEFORE="$TMP/dddd0004-before.jsonl"; transcript "$BEFORE" "2026-10-31T02:05:50.000Z:294947"
made="$(CTX_FILL_NOW="$(date -u -d '2026-10-31 02:05:57' +%s)" cfo "$BEFORE" --window 1m --line)"
has "mid-turn line carries the visible (previous) fill" "fill 294,947" "$made"
out="$(CTX_FILL_NOW="$(date -u -d '2026-10-31 02:15:00' +%s)" python3 "$CF" --check "$made" 2>&1; echo "rc=$?")"
starts "a mid-turn line matches once its turn is flushed" "MATCH" "$out"
claim() { echo "fill $1 / 1,000,000 · marks 350,000/400,000 · OK · measured 2026-10-31 02:05:57 UTC · session dddd0004"; }
for g in 290,000 294,449 296,457; do
  out="$(CTX_FILL_NOW="$(date -u -d '2026-10-31 02:15:00' +%s)" python3 "$CF" --check "$(claim $g)" 2>&1; echo "rc=$?")"
  has "neither of the last two fills: $g" "MISMATCH" "$out"
done
out="$(CTX_FILL_NOW="$(date -u -d '2026-10-31 02:15:00' +%s)" python3 "$CF" --check "$(claim 295,858)" 2>&1)"
starts "the latest fill matches" "MATCH" "$out"

# one selection: --line reports the last TIMESTAMPED turn; an untimestamped final entry is not checkable
transcript "$TMP/sel.jsonl" "2026-10-30T22:00:00.000Z:100000" "300000"
has "--line ignores an untimestamped final entry" "fill 100,000 / 1,000,000" "$(CTX_FILL_NOW="$(epoch 22:05:00)" cfo "$TMP/sel.jsonl" --window 1m --line)"
# one API response written as two entries counts as one turn
transcript "$HOME/.claude/projects/-work-app/eeee0005-0000-4000-8000-000000000009.jsonl" \
  "2026-10-30T22:00:00.000Z:100000" "2026-10-30T22:10:00.000Z:240000" "2026-10-30T22:10:01.000Z:240000"
out="$(check "$(line 100,000 22:10:30 1,000,000 350,000/400,000 OK eeee0005)" 22:20:00)"
starts "a duplicated entry is one turn: the previous fill still matches" "MATCH" "$out"

# ── the stamp's zone token is honored (a PDT line is not 420 minutes stale under TZ=UTC) ──
transcript "$HOME/.claude/projects/-work-app/f0f0f0f0-0000-4000-8000-000000000010.jsonl" \
  "2026-10-31T04:10:00.000Z:150000" \
  "2026-11-01T08:00:00.000Z:100000" "2026-11-01T08:29:00.000Z:200000" \
  "2026-11-01T09:00:00.000Z:300000" "2026-11-01T09:29:00.000Z:400000"
tzclaim() { echo "fill $1 / 1,000,000 · marks 350,000/400,000 · OK · measured $2 · session f0f0f0f0"; }
tzcheck() { CTX_FILL_NOW="$(date -u -d "$1" +%s)" TZ="${3:-UTC}" python3 "$CF" --check "$2" 2>&1; echo "rc=$?"; }
starts "a PDT line under TZ=UTC is a MATCH, not STALE" "MATCH" "$(tzcheck 2026-10-31T04:20:00Z "$(tzclaim 150,000 '2026-10-30 21:15:00 PDT')")"
starts "the same PDT line under the zone that wrote it" "MATCH" "$(tzcheck 2026-10-31T04:20:00Z "$(tzclaim 150,000 '2026-10-30 21:15:00 PDT')" America/Los_Angeles)"
# the repeated fall-back hour: 01:30 PDT (08:30Z) and 01:30 PST (09:30Z) are different moments
starts "01:30 PDT sees the first pass" "MATCH" "$(tzcheck 2026-11-01T08:40:00Z "$(tzclaim 200,000 '2026-11-01 01:30:00 PDT')")"
starts "01:30 PST sees the second pass" "MATCH" "$(tzcheck 2026-11-01T09:40:00Z "$(tzclaim 400,000 '2026-11-01 01:30:00 PST')")"
has "01:30 PST is not the first pass" "MISMATCH" "$(tzcheck 2026-11-01T09:40:00Z "$(tzclaim 200,000 '2026-11-01 01:30:00 PST')")"

# ── --host: run the same script on another machine over ssh and relay its output and exit code ──
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SSH_ARGS_OUT"
echo "remote said hi"
exit "${SSH_RC:-0}"
SH
chmod +x "$BIN/ssh"
export SSH_ARGS_OUT="$TMP/ssh.args"
out="$(PATH="$BIN:$PATH" SSH_RC=0 cf --host user@host 3f9a1c2e --window 1m --line; echo "rc=$?")"
has "--host relays the remote output" "remote said hi" "$out"; has "--host relays exit 0" "rc=0" "$out"
args="$(cat "$SSH_ARGS_OUT")"
has "--host targets the host" "user@host" "$args"
has "--host runs ctx-fill.py remotely with the args" "scripts/ctx-fill.py" "$args"
has "--host passes the uuid and flags through" "--window" "$args"
hasnt "--host does not forward its own flag" "--host" "$args"
has "--host never prompts for a password" "BatchMode=yes" "$args"
out="$(PATH="$BIN:$PATH" SSH_RC=3 cf --host user@host --check x; echo "rc=$?")"
has "--host relays a non-zero exit code" "rc=3" "$out"
# the remote checkout: KIT_REMOTE_REPO wins; with none, the local checkout's path under $HOME is assumed on the remote too
PATH="$BIN:$PATH" KIT_REMOTE_REPO='$HOME/elsewhere/proj' cf --host user@host x >/dev/null
has "KIT_REMOTE_REPO sets the remote checkout" '$HOME/elsewhere/proj/scripts/ctx-fill.py' "$(cat "$SSH_ARGS_OUT")"
out="$(cf --host; echo "rc=$?")"
has "--host without a target is a usage error" "usage" "$out"
hasnt "no project name is hard-coded" "einherj""ar" "$(cat "$CF")"

echo "ctx-fill-line: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
