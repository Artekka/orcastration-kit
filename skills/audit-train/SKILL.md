---
name: audit-train
description: Independently AUDIT an assembled train branch as a validator — every first-parent merge's second parent equals its approved SHA, every merge tree equals a fresh `git merge-tree --write-tree P1 P2` except declared resolutions, regen-only commits reproduced byte-identical, gate deltas checked against test counts, and a fresh-install typecheck on the final tip. Use when the seat assigns "audit train N", "train FINAL audit", "audit the train as it lands" — read-only; the assembler merges, you verify.
---

# audit-train

Read-only lane. Report to the SEAT only (never answer the assembler). State per verdict whether it was **DERIVED** (you recomputed it) or **consistency-checked** (you compared claims).

| name | meaning |
|---|---|
| `BASE` | the train's base: the last approved main SHA |
| `TIP` | the train branch tip you audit (`git fetch origin` first; audit what is PUSHED, never a local checkout) |
| `SP` | your evidence dir: ORCHESTRATION.md → `evidence dir:` (default `~/.orcastration-kit/scratch/<YYYY>/<Month>/<row>/`), never `/tmp` |
| `H` | this skill's base directory (printed above this text when the skill loads): `audit.sh` lives there |

⚠ `audit.sh` takes NAMED variables, never positionals: the skill loader replaces positional tokens in this text with the invocation's arguments.

## 1. Sweep the merges
```bash
cd <the repo> || exit 1
printf '%s\n' <rider sha 1> <rider sha 2> … > "$SP/approved"     # the seat's approved SHAs, one per line
BASE=<base> TIP=<tip> APPROVED="$SP/approved" bash "$H/audit.sh" | tee "$SP/audit-<tip>.txt"
```
Exit 0 = every merge tree-equal (and approved); 1 = at least one line to explain (`tree_eq=NO`, `approved=NO`, an octopus); 2 = usage. `SINGLE` lines never change it: check each against §2.

**Positive control first:** run it over an already-audited range AND over one merge known to conflict (`mt_rc` must read 1 there). A sweep that cannot show NO proves nothing.

## 2. Per line

| line | pass condition |
|---|---|
| `MERGE … approved=YES … tree_eq=YES` | `p2` is the seat's approved SHA for that rider |
| `MERGE … tree_eq=NO` | the `resolved:` paths are exactly the DECLARED ones; `git diff <merge-tree> <landed> -- <path>` shows only the declared hunks; the resolved blob = the declared side's blob (or the declared union) |
| `MERGE … approved=NO` | a finding unless the seat approved it under another SHA: verify with `git merge-base --is-ancestor` before accepting |
| `SINGLE` | declared (regen / seal note / seat-ordered test flip); touches only its declared paths |
| `OCTOPUS` | audit by hand; undeclared = a finding |
| anything undeclared | ask the seat; verify the answer in git before accepting |

**Declared `--merge-base=X` where X is not a common ancestor:** compare the declared tree with the DEFAULT merge (`git merge-tree --write-tree P1 P2`); they may differ only in the conflict-marker lines of the declared hunks.

## 3. Regen-only commits: reproduce, never trust
```bash
git worktree add --detach "$SP/wt-regen" <REGEN_SHA>^ && cd "$SP/wt-regen" || exit 1
# install + build derived artifacts, then the regen command(s) copied VERBATIM from the regen commit body
git ls-files -mo --exclude-standard -z | git update-index --add --remove -z --stdin \
 && [ "$(git write-tree)" = "$(git rev-parse <REGEN_SHA>^{tree})" ] && echo REPRODUCED || echo DIFF
```
The `ls-files | update-index` line stages every change by path (new, changed, deleted): the git guard refuses `git add -A`.

Pass = `REPRODUCED` (the whole tree, byte-identical) AND any hand edit in the commit is exactly the declared text (`git diff --word-diff <REGEN_SHA>^ <REGEN_SHA> -- <file>`). A generated file whose header stamps "the last commit touching its inputs" differs on the committed merge by that stamp alone: reproduce from the pre-commit state instead (`git checkout --detach <P1> && git merge --no-commit --no-ff <P2>`, regenerate, stage with the `ls-files | update-index` line, compare `write-tree` with the merge's tree).

## 4. Gate deltas
Cite the assembler's gate line; verify each count delta against the rider: run the rider's new or changed test files (or the stage) at P1 vs at the merge, with a fresh install and rebuilt derived artifacts at EACH checkout. An unexplained delta is a finding. A re-gate after an install fix supersedes provisional lines.

## 5. FINAL
- Sweep `BASE..TIP` once more, in one pass, at the pushed tip.
- On the tip in a clean worktree: fresh install + build → the overlay's typecheck/lint/format checks over `git diff --name-only BASE TIP` → the expected-red test (if any) now green.
- If the tip's tree equals a gated candidate's tree (`git rev-parse <X>^{tree}`), that candidate's gate describes the tip.
- Verdict: **CLEAN** or **FINDINGS** (each with severity, file, failure), DERIVED or consistency-checked, plus an explicit "not covered by me" line. Remove your worktrees.
