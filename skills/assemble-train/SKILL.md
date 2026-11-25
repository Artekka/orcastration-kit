---
name: assemble-train
description: Land READ-PASS riders onto a train branch one merge at a time — chained merge-tree trials, which-side-won per file, blob identity, a full gate per rider with deltas predicted from test counts, push after each, and a state note. Use when the seat assigns an ASSEMBLER lane ("assemble train N", "land these riders onto the train", "phase B riders") — merges only, never edits to a rider.
---

# assemble-train

The seat owns the rider list, the order and every ruling. The assembler merges, measures and reports. **A conflict or an unexpected red is information: stop, report, wait for a ruling.** The auditor (`/orcastration-kit:audit-train`) re-derives all of this afterwards, so every claim you make must be checkable in git.

| name | meaning |
|---|---|
| `W` | the train worktree the seat names (never the shared checkout) |
| `S` | your evidence dir: ORCHESTRATION.md → `evidence dir:` (default `~/.orcastration-kit/scratch/<YYYY>/<Month>/<row>/`), never `/tmp` (a reboot wipes it) |
| `H` | this skill's base directory (printed above this text when the skill loads): `trial.sh`, `cptrial.sh`, `gsum.sh` live there |
| gate | ORCHESTRATION.md → Gate `command`, run through the throttle (`bash scripts/gate-throttle.sh <command>`) |

⚠ The helpers take NAMED variables (`B=<base> R=<rider> bash "$H/trial.sh"`), never positionals: the skill loader replaces positional tokens in this text with the invocation's arguments.

## 0. Preconditions (stop if any fails)
```bash
git -C "$W" status --short | wc -l                                         # 0
git -C "$W" fetch -q origin && git -C "$W" rev-parse --short HEAD origin/<train-branch>   # equal
git -C "$W" reflog -8 --format='%h %gs'                                    # only commit/merge entries: never rebased
```
⛔ Never `git rebase` in `$W`. ⛔ Never commit the board from `$W`: its copy is stale, and a commit of it silently reverts later board edits.

**Taking over from another assembler** (the branch is checked out in their worktree, so git refuses a second one): `git worktree add -b <you>/train-asm <path> origin/<train-branch>`, push with `git push origin HEAD:<train-branch>` (fast-forward only: a stray push from the old worktree bounces yours instead of being overwritten). Install dependencies there, then run one **baseline gate** before the first landing; it must reproduce the previous assembler's numbers.

## 1. Trial the WHOLE phase before the GO (touches no refs)
Chain in landing order, each trial on the previous `SYNTH`:
```bash
cd "$W" || exit 1
B=<train tip> R=<rider1> bash "$H/trial.sh"      # → RC, RIDER/TRAIN/NEITHER per rider file, SYNTH <sha1>
B=<sha1>      R=<rider2> bash "$H/trial.sh"      # → SYNTH <sha2> …
B=<base>      C=<commit> bash "$H/cptrial.sh"    # a CHERRY-PICK-ONLY rider: one call per commit, in order
```

| trial result | action |
|---|---|
| `RC=1` (conflict) | **STOP.** Report the hunk (`git show <tree>:<file>` around `<<<<<<<`), the merge-base and why. Offer (A) union-resolve in the merge · (B) the builder rebases · (C) a pre-merge row. Wait for the ruling. |
| `RC=1` on files outside the rider's payload (rider cut from a trial chain) | History-only conflict: the rider's blob equals released main's and the file is absent from `git diff --name-only <payload-base> <rider>`. `git merge-tree --write-tree --merge-base=<payload-base> <tip> <rider>` is the true tree. Ask for ruling A; assert landed tree = that tree in the merge body. |
| `ALREADY-ON-TRAIN` | The rider is an ancestor of the base: it is already merged (its `SYNTH` is the base, so the chain goes on). Tell the seat: a duplicate in the list, or a rider that landed earlier. Never land it again. |
| `SAME <file>` | The base already holds the rider's blob (cherry-picked earlier, or the same change made twice). Every file SAME = the rider adds nothing: ask the seat whether it is a duplicate before the GO. |
| `TRAIN <file>` | The rider's blob did NOT land (the train already holds another version). Explain it before the GO. |
| `NEITHER <file>` | A real 3-way merge. **Verify by content:** `git diff <rider-base> <rider> -- <file>` applied with `patch` to the train's copy, then `git hash-object` = the landed blob. |
| `NEITHER` verified, rider cut from an OLDER base than a stacked earlier rider | A content match proves the text, not the scope (a call into a function an earlier rider moved still merges clean and still fails to load). **Measure the rider's test files at that SYNTH**: a file reporting 0 tests with a non-zero exit is a load failure, not +0. STOP; offer (B) or (D) cut the rider. |
| a rider whose base lacks an earlier registrant (registry / index file) | Expect an import-anchor conflict. Trial it; never predict it. |
| rider cut from MAIN, not the train | The merge also carries every main commit since the train's last main merge. `git diff <last main merge> <rider-base> -- <code paths>` must be empty (docs-only carry); say so in the merge body. Non-empty → STOP: it is an unannounced main merge. |

**Cherry-pick riders:** land with `git cherry-pick -x <c1> <c2>`. A NEITHER file also needs: the later fix's ADDED lines all present in the landed blob AND mostly ABSENT from the rider's own blob (the positive control that a blob landing would have reverted the fix).

## 2. Predict the deltas before reading any gate
- Count test declarations per changed test file, train side vs rider side (`git show <sha>:<file> | grep -cE '<your framework's test-declaration regex>'`), and assign each file to its gate stage. Files ±1 from `git diff --name-status` (a rename is net 0 files; a modified file adds tests, not files).
- **The regex counts declarations; the gate counts runs.** A data-driven test (`each`/parametrize/table) runs once per row; a loop that wraps test declarations runs once per element. Count the rows/elements, typed and multi-line forms included. Skipped/todo tests show in the gate's summary, not in the regex: grep the diff for them and predict them separately.
- **Census tests outside the diff grow too:** a test that walks a registry gains cases when a rider extends that registry, without appearing in the rider's diff. On any miss, attribute it per file (machine-readable reporter, before vs after), never by guessing.
- **Many loops? Measure instead:** for each chained SYNTH, in a SCRATCH worktree (`git worktree add --detach <path> <SYNTH>` + install), run each changed test file alone with a machine-readable reporter and read its total. Stage delta = sum of per-file differences. Never measure in `$W` while a gate runs there.
- ⛔ Every script that moves HEAD starts with `cd <abs path> || exit 1` (or uses `git -C`): the shell's cwd can reset to the SHARED checkout, and a failed `cd … &&` there moves the shared HEAD.
- **A reader's delta is against the READER's base.** Before calling a miss, list the riders the reader's base lacks.
- An equal count can hide a swap: `git diff <base> <rider> -- <file> | grep -E '^[-+].*<test-declaration regex>'` should be empty.
- **Classify the rider from `git diff --stat`, never from the brief.** Product files in a high-risk class (ORCHESTRATION.md → Change classes) mean that class's extra gate. Player/user-visible product changes mean a release note is owed: tell the seat.

**Pre-landing probe** (optional; worth it while READs are out): `git -C "$W" checkout --detach <last SYNTH>`, run the full gate, compare with the predictions, `git checkout <branch>`. It catches riders that are each green on their own base but break a shared guard only when combined. **Mandatory when:**
- a rider's tests record behavior through a module that an earlier rider on this train changed after the rider's base;
- the train carries a test file the rider's base lacks and the rider changes what it measures;
- a rider's base predates the previous train and touches a module that train's tests drive;
- **merging MAIN into a train:** a clean auto-merge can duplicate an import both sides added (typecheck-only red: grep merged import lists for repeats); main's new tests can be calibrated to a constant the train changed (premise reds: route to a builder as a test-only fix, land as KNOWN-RED on the seat's ruling); a generated file both sides regenerated can auto-merge stale (rerun its generator's check).

## 3. Per rider (strictly one at a time)
```bash
cd "$W" || exit 1
cat > "$S/msg-rN.txt" <<'MSG'      # quoted heredoc, never printf: printf reads '% s' in a title as a format spec
merge(train<N>): <ROW> <title> <rider sha>

READ: <record path/SHA> · findings: <ids>
MSG
git merge --no-ff -q -F "$S/msg-rN.txt" <rider-tip>
git push -q origin <train-branch>    # IMMEDIATELY (a hand-resolved merge: only after its acceptance checks)
```
- **Message body:** the READ record and finding ids only, never characterizations. A merge body is an orientation surface.
- **Checks after landing:** landed tree = the trial tree · every rider-owned file (`git diff --name-only <train-base>...<rider>`, THREE dots; two dots also lists main's own changes and false-alarms) has `git rev-parse <rider>:<f>` = `HEAD:<f>` · only the rider's files changed vs the previous tip · earlier riders' fixes survive (their ADDED lines present, not blob equality, when a later rider legitimately edited the file). For a STACKED rider: absent lines ⊆ the lines the rider's own reviewed diff removed (`git diff <rider-base> <rider> -- <f> | grep '^-'`); anything else absent was lost in the merge.
- **Hand-resolved conflict (ruling A):** build the expected file BEFORE resolving, run the formatter on it, then hash it. Assert the working-copy conflict equals the trial's (normalize marker labels: `sed -E 's/^(<<<<<<<|>>>>>>>) .*/\1/'`). Acceptance, all BEFORE push: an exact `+/-` line diff vs the previous tip, blob = the expected file, gate green. The body names the file and "union of …, no other edit".
- **Gate:** from INSIDE `$W`, in the background, logged:
  ```bash
  cd "$W" && bash scripts/gate-throttle.sh <gate command> > "$S/gate-rN-<sha>.log" 2>&1; echo "REAL_EXIT=$?" >> "$S/gate-rN-<sha>.log"
  L="$S/gate-rN-<sha>.log" bash "$H/gsum.sh"     # GSUM_RE=<regex> for your gate's own summary lines
  ```
  Deltas are measured against the previous TRAIN tip; branch-local absolutes do not carry. Count failed tests into totals.
- A gate that refuses on untracked test files: `git add` the file if it belongs to the rider, else move it to `$S`.
- A crash at teardown after a clean pass summary: re-run that stage alone, then the full gate. It is not a regression.
- **Expected red:** read EVERY failing title against the named set. Any red outside it → stop before the next rider, even when the cause looks the same.
- A `+0` rider: say what the zero is consistent with (a fixture inside existing cases, comment-only) and run the file alone as a positive control.

**Many riders under load: script the landing loop.** Each iteration lands (the §3 checks), pushes, gates, then compares every stage's own summary to the predicted string, STOPPING on red or any mismatch.
- ⛔ **Pass on the gate's red-stage SET, never on count lines alone** (a count-only loop has passed riders whose typecheck was red). Positive-control the checker on an old known-pass log and an old known-red log before arming it.
- After every merge and resume: reinstall dependencies and rebuild derived artifacts (fatal on failure); a silent stale build gives false reds.
- ⛔ **Syntax-check the loop with `bash -n` ONLY.** `source` or `bash -c "source …"` RUNS it (a rider once merged and pushed ungated that way).
- ⛔ **Never run the loop AS a Monitor command:** the monitor's expiry kills it mid-gate or mid-merge. Run it detached (`setsid nohup bash "$S/land.sh" > "$S/land.log" 2>&1 < /dev/null & disown`) and Monitor a `tail -F` of the log.
- ⛔ **Resume = skip only what is PUSHED.** Test the rider's subject against `origin/<train>`, never the local log. If HEAD's subject is the rider's, gate it, then push.
- `while read … done <<'LIST'` feeds the list on stdin, and the gate or `git merge` inside the loop can eat it: give each `</dev/null`.
- Riders approved mid-run stay out of the running loop: queue a follow-on script behind a waiter that polls the log for the previous loop's `ALL-LANDED` marker and exits on `STOP`.

## 4. Report at every landing
- Load the tools first: `ToolSearch` with `select:ListAgents,SendMessage` (deferred tools: calling one unloaded fails). Then `SendMessage` to the seat WITH its `[ref]` from a fresh `ListAgents` (stale sessions can share the seat's name; the ref changes on every recycle). Include: merge SHA, the gate lines, deltas vs prediction, the blob result, your context fill.
- Board cell in the shared checkout (never `$W`), guard → edit → stage → commit → push as ONE command:
  ```bash
  git fetch -q origin && git merge -q --ff-only origin/main && git diff HEAD --quiet -- docs/orchestration/AGENT_BOARD.md \
   && <edit your cell> && git add docs/orchestration/AGENT_BOARD.md \
   && git commit -m "chore(orchestration): <PREFIX> …" -- docs/orchestration/AGENT_BOARD.md && git push -q origin main
  ```
  `merge --ff-only`, not `rebase` (a sibling's unrelated WIP makes rebase refuse). Report the SHA from commit's own `[main <sha>]` line, never `rev-parse HEAD` (a sibling can commit in between). Stamp times from `date`.

## 5. Generated-file commits (regen)
A train that ends with a regenerated artifact: get any date/round key from the seat first; **dry-run the regen** in a scratch worktree at the final SYNTH (`git add -A && git write-tree` = the target); the real regen must reproduce it byte-identical before commit. FINAL = the full gate PLUS the production build (the gate cannot see a file the build does not ship).

## 6. State note: `docs/orchestration/seals/train<N>-state.md` on the train branch
Docs only (`git diff --quiet <code-tip> HEAD -- <code paths>`), pushed. It holds: the tip and a table (rider · rider tip · merge SHA · READ record) · the special checks (hand-resolved files, 3-way files, stale-blob expectations) · the known-red set as exact titles + failure lines, with "no tip from <sha> may deploy" if any is user-visible · per-rider deltas vs predictions and the total (it must close exactly) · the next phase's order · the ⛔ worktree rules. If builders wait on the tip, send the SHA before the gate result.
