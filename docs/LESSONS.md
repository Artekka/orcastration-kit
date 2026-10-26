# Distilled Lessons — why the protocol is shaped this way

Each rule below was paid for by a real incident. New lessons land here (with provenance)
and ship to every consuming project on the next kit upgrade — that propagation is the
kit's whole reason to exist.

## Coordination

1. **Claim before work; one owner per row; file fences are hard.**
   *Provenance:* three concurrent sessions partitioned ~15 workstreams in one evening with
   zero file collisions — only because every row carried an explicit file fence and claims
   were committed before work started (origin project, 2026-08-08).

2. **Worktree isolation for every implementation agent.** Concurrent sessions and their
   subagents never share main's working tree; non-isolated agents silently co-edit files.
   *Provenance:* origin-project memory `feedback_isolate_worktree_for_concurrent_sessions`.

3. **NEVER `git stash` inside a worktree agent.** Stash refs are SHARED across all
   worktrees of a repo; two agents stashing concurrently popped each other's WIP. Prove a
   RED state via `git commit` + `git reset --soft`, or copy files to a scratchpad.
   *Provenance:* origin-project B1/B2 stash collision, 2026-08-08.

4. **Sequential reconciles; exclusive deploy.** Land one worktree at a time onto main;
   claim the DEPLOY row before deploying. Parallel landings lose work; racing a deploy
   corrupts the cutover.
   *Provenance:* origin-project M376/M377 two-session coordination.

5. **Commit board edits immediately.** Uncommitted board state is invisible to other
   sessions and gets swept into someone else's commit.

6. **Stale status docs cause duplicate rebuilds.** A "BUILD pending" line for work that
   was actually finished on a branch nearly caused a full re-implementation. When work
   lands somewhere non-obvious (a held branch), the status doc must say so, with the
   branch name and the reason it's held.
   *Provenance:* origin-project ADR-0041 near-miss, 2026-08-08.

## Verification

7. **Independent verify at every hand-off edge.** A sibling implementation+test pair can
   confabulate the SAME wrong belief — wrong code + wrong test agree, and TDD shows green
   that means nothing. The verifier receives the contract only (spec + diff), never the
   implementer's reasoning, and judges against canonical ground truth (the spec/ADR/
   constants), never against a sibling's test.
   *Provenance:* origin-project memory `feedback_multiagent_false_green_trace_semantics`.

8. **The verifier reports; it never edits.** A verifier that "helpfully" fixes masks the
   drift it exists to catch.

9. **No vacuous green.** A check that found nothing wrong and a check that ran on nothing
   are indistinguishable unless you assert the match/population count — "0 failed" out of
   0 run is not a pass.
   A check fed by a file or a machine tool can run on less, or on nothing, without saying so. A
   shell `while read` loop drops a last line with no newline (`|| [ -n "$line" ]` keeps it), an
   unreadable file is skipped silently (test `-r` first), and a line that matches no expected form
   is ignored unless the loop rejects it. A test that cannot run on this machine (a missing tool or
   browser) fails in the gate's own result line; it never drops its pages or passes with zero
   checks, and the number of pages built is part of the population the count asserts. The runner may
   hide build output, so a missing input must show in the result itself (see 98 and 120).

10. **Read the REAL pass line, unpiped.** Pipes mask exit codes; a background-task
    completion notification masks a failing exit; a process can print its pass summary and
    then crash in teardown. Assert the literal "N passed / 0 failed" summary AND a clean
    exit, from output you captured yourself.
    *Provenance:* origin-project memories `feedback_pipe_masks_exit_code`,
    `feedback_background_test_notification_masks_exit`.

11. **Gate red ≠ code red.** Know the project's infra-flake modes (e.g. one test
    container per file saturating Docker) and encode the trusted gate + the never-run
    commands in `ORCHESTRATION.md`. An untrustworthy red wastes every session's time.

12. **Gate green ≠ boots.** Unit-green says nothing about schema/seed/boot integrity;
    migrations need a boot or constraint check in the gate for their change class.
    *Provenance:* origin-project memory `feedback_gate_green_but_boot_crashloops`.

13. **Re-verify subagent claims at reconcile.** "Pre-existing failure", "flake", and
    "done" are claims, not facts, until the reconciler re-runs the named suite in
    isolation and sees it with its own eyes.
    For a check that runs outside the main test, run it on an untouched copy of the base too and
    report only the failures the change adds; a failure the base also shows is not the change's.
    *Provenance:* origin-project memory `feedback_verify_subagent_failure_claims`.
    Before blaming a failure outside the change on a merge, compare (`cmp`) the failing check's
    built output on the merged tree and on both parents: if it is byte-identical on all three, the
    merge did not cause it. Report what remains as k fails in N runs (see 134).

## Scope discipline

14. **Locked constants / spec-locked formulas need the human's sign-off.** Subagents get
    the list of locked items in their brief and treat it as read-only.
    *Provenance:* origin-project memory `feedback_guard_locked_constants_from_subagents`.

15. **The board is institutional memory at the hand-off grain.** Closed rows keep their
    verifier verdict, real gate lines, and released fences — the next session's context
    starts there.

## Orchestrated autonomy (harvest 2026-08-19 → 2026-08-21)

16. **Per-session row-ID prefixes — never a shared counter.** "Read the highest and add one"
    is a read-then-write with no lock; sessions append in different places so git never
    conflicts, both ids go live, and a grep returns two unrelated rows that look deliberate.
    Prefix = session tag (`O7-1`, `FQ-2`); collisions become impossible by construction.
    *Provenance:* six manual reconciliations in two days (origin project).

17. **Milestone/log numbers are allocated through a claimed LOG slot** (same shape as the
    DEPLOY slot). Any shared monotonic counter needs a single allocator while concurrent
    sessions run.

18. **A verify arc of DEVIATES → fix-roundtrip → delta-PASS is the system WORKING.** The
    verifier's findings are the record's most valuable content; a fully green suite can
    still carry spec drift. Roundtrip fixes land at the layer the finding names, falsified
    one-red-each.

19. **Announce resource windows on the board** — gate runs, integration/testcontainer runs,
    deploys, AND dev-stack boots on a shared daemon. A sibling's sweeper, deploy, or
    resource-hungry run is a killer for anything it can't see.

20. **After ANY interrupted cherry-pick / rebase sequence: count the picks.** A conflict
    abort can silently DROP a commit from the sequence; compare landed commits against the
    branch's commit list before declaring the landing complete.
    *Provenance:* a green branch's GREEN commit vanished from a landing mid-sequence
    (origin project, 2026-08-21); caught by counting the landed commits against the branch's
    intended list — the byte-diff against the branch tip was the repair's verification,
    not the detection.

21. **Mutation/falsification commands: one explicit target tree, stderr visible.** Never
    leave earlier path guesses in a compound command; never `2>/dev/null` anything that
    edits files; after restore, diff-verify EVERY tree the command string could have
    reached, not just the one the test reads. And a mutant you haven't diff-verified as
    APPLIED proves nothing.

22. **A change that ADDS test output needs one pass through the real gate stage** — gates
    that classify stage output by pattern make output part of the interface; a realistic
    fixture string in test logs can impersonate an infra-error signal and false-RED every
    session's gate. Capture loggers in tests (and assert they fired); never reword a
    fixture away from the real message to dodge a classifier.

23. **Doc-agent diffs are APPEND-ONLY and fact-checked line-by-line before commit.** A
    delegated log write once replaced a 32k-line institutional log with an 82-line stub,
    with fabricated details; `git diff` deletions must be zero for an append, and every
    factual claim is checked against what actually happened.

24. **Retro-before-clear is a HANDSHAKE.** `/clear` destroys unpersisted context; the retro
    converts it into memories and tied-off state. Order: retro order → the session's
    explicit "retro complete" → only then close the terminal and relaunch it with an explicit
    `--model` (a bare `/clear` keeps the old model), one terminal at a time.

25. **No mid-orchestration `/compact`.** Context quality is load-bearing at hand-offs;
    compaction mid-arc loses exactly the correction/decision detail the next phase needs.
    Context pressure → the retro-before-clear handshake instead.

26. **Inserting a step into an ordered, PERSISTED sequence is a migration.** If a cursor
    stores a position and only resolves forward, a mid-list insertion strands everyone
    already past that index — precisely the users it was written to protect. Ship the
    backfill + a guard in the same change. Projects carrying such sequences should elevate
    this into their own CLAUDE.md.
    *Provenance:* a tutorial-step insertion soft-locked the project owner's own account
    (origin project).

27. **Never expose user PII in public channels or shared artifacts** — usernames, emails,
    ids stay out of anything that leaves the project's private surface.

## Multi-session hardening (harvest 2026-08-22 → 2026-09-29)

28. **The INDEX is shared, not just the tree.** Explicit staging protects your commit from
    others' files, not your staged file from THEIR commit. Board writes in the shared
    checkout: HEAD guard → `git diff HEAD --quiet` → `git add <path> && git commit` as one
    command → push. "Nothing added" + "up-to-date" right after a write = you were swept.

29. **`git pull --rebase` races on the shared `.git/FETCH_HEAD`** ("Cannot rebase onto
    multiple branches"). Use `git fetch origin && git rebase origin/main`. A `cannot lock ref`
    exit is a lost fetch race — retry once; never wrap it in a loop that ends on `sleep`'s 0.

30. **Guard the shared checkout's HEAD before any write.** A sibling's failed `cd` can leave
    it detached on a trial branch; a later push of `HEAD:main` then ships ungated commits.
    Check `git symbolic-ref -q HEAD` = `refs/heads/main`; push `origin main`, never `HEAD:main`.

31. **Push a `merge --no-ff` immediately.** A plain rebase before the push linearizes the merge;
    the builder's SHAs never reach origin and a branch stacked on them conflicts later.

32. **Run the gate from inside your own worktree.** A gate script that `cd`s to its own
    directory gates the tree it lives in and prints a legitimate green for a tree you are not in.

33. **Siblings verify siblings — not subagents.** A subagent the seat spawns inherits the seat's
    framing; a peer session has its own context. Nobody verifies their own row, no mutual
    pairs, the verifier reports to the seat, and every verdict says DERIVED or
    CONSISTENCY-CHECKED — only the former is verification.

34. **A dedicated validator that never builds** is independent of every row by construction.
    Hand it READs, re-reads, train checks and falsification; never a build or fix round.

35. **A narrative board briefs its own verifiers.** Keep the board to status; briefs go to the
    builder by message; archive verbatim past ~60 KB and grep archives, never read them whole
    (an unreadable board is the same as no board).

36. **`ListAgents` is liveness, not readiness.** Terminal uptime survives `/clear`, so a fresh
    context and a spent one look identical. Rosters come from READY signals — otherwise the
    seat waits for siblings while siblings wait for the seat.

37. **Measure context; never estimate it.** Sum input + cache_read + cache_creation off the last
    assistant turn. `bytes ÷ 4` over-reports 30–60% with an unstable bias. The window is not in
    the transcript — read it from the session's own env block; a threshold calibrated for 1M
    never fires on a 200K session before it dies.

38. **Measure the right object.** Identify a session from an authoritative id, never "most
    recently modified". Checking a property of the wrong object raises confidence, not accuracy.

39. **Recycle launch-first, then SIGTERM.** Open the fresh session, wait until its process
    exists, then SIGTERM (not KILL) the old one — no seat is ever empty and the old transcript
    flushes. Only after "retro complete".

40. **All human approvals route through the seat.** Siblings stop and message the seat; the seat
    batches questions to the human in ONE terminal. Scattered prompts across terminals stall
    silently when nobody is watching that window.

41. **A suite nothing runs rots silently.** A fast DB-free gate is right per change, but some
    exhaustive sweep must run before trains or nightly — a change can be green on its own
    evidence and break a suite one directory over.

## Enumeration, evidence and honest claims (harvest 2026-08-28)

*One 12-hour orchestrated session, three sibling builders, two deploy trains, nine rows
shipped, two rows killed. Every lesson below came from a verifier finding, a sibling
correcting the orchestrator, or a sibling correcting itself.*

42. **The enumeration is the deliverable; the fix is the easy part.** Two independent rows
    failed identically the same day: each brief said "find every X" and then *illustrated*
    with three examples, and each builder fixed exactly those three. Independent
    re-enumeration found **eight** and **thirteen**. An illustration placed inside a
    requirement gets read AS the requirement. Name the enumeration as the artifact you
    want, and have the verifier rebuild it from scratch rather than check the builder's.
    Before trusting a text scan to build the list, test its pattern on the real file: a tag pattern
    that allowed only letters missed the tags that held digits, and the list came up short.
    *Provenance:* origin project — one row guarded 3 of 8 sites, another fixed 6 of 19 comments.

43. **A term-sweep converges only when every hit gets a written verdict.** Iterative
    "search and fix" rounds do not converge: round 1 found 9, round 2 fixed 6, round 3
    found 11 more. The cause is **not** vocabulary — the searches were fine. A grep over a
    large repo returns mostly noise, so the reader **unconsciously filters by plausibility**
    and a hit in a file that looks like someone else's area is skipped without a decision
    being made. Forcing a typed verdict per hit removes the filter, because "unrelated"
    must be *written* rather than assumed. Generalizes to any audit-by-grep.

44. **When a fact is documented more than once, fixing ONE copy makes the others harder to
    find** — the fixed copy stops matching your grep and reads as done. Work twin-first:
    find a poison case, look for its bleed twin immediately; fix a mirror, fix its source.
    *Provenance:* one type file carried the same rider doc **four** times; a round whose
    stated purpose was "I fixed one half and left the twin" then fixed the wrong pair.

45. **A component test cannot see a regime that never mounts the component.** A feature
    shipped fully working — and absent on the one device/breakpoint the original reporter
    used — because a different component is substituted there. All its tests rendered the
    component directly. Pin the **composition** that chooses the component, and assert the
    regime is actually active so the test cannot pass by falling through to the other path.
    The same holds for entry paths: a feature built and tested only from its top-level entry
    leaves every other way into it unchecked. Pin each other path with a check that measures the
    change it should cause (the before and after numbers), not only that the page still loads.

46. **A guard that compares NAMES cannot see TYPES.** An entire family of drift guards
    compared key sets; flipping a field's declared type in the *canonical schema* left the
    dedicated drift guard green at 47/47. The only backstop was the compiler, and only
    *incidentally* — one file built typed literals while its neighbor used a cast. Decide
    explicitly whether a guard covers types, and write down which backstop you are relying
    on. Relying on one without knowing it is the failure.
    The same holds for a checker that accepts a helper by its name: a reviewer passed a call
    because the helper's name promised the right thing, while the helper returned something
    else. Open what the helper returns (read its body or call it on a known case), not just
    what it is called.

47. **A restore check must assert TWO things: tree clean AND the fix still present.** A
    mutation-restore run against a baseline that never carried the fix is a **delete**, not
    a restore — and it prints `nothing to commit, working tree clean` plus a GREEN gate on
    the *pre-fix* SHA. Clean status alone cannot distinguish restored from deleted. Always
    commit GREEN before mutating.
    After undoing a planted bug, wipe the compiled cache (Python's `__pycache__`), or a compiled
    copy of the bug can still run against the restored source.
    The same cache has a second effect: a test run that writes compiled files into the tree leaves
    it dirty, and the next gate's dirty-tree check fails (see 63). Run tests and gates with
    compiled-file writes off (for Python, `PYTHONDONTWRITEBYTECODE=1`).

48. **A mutant that reds for the wrong reason is not evidence.** A "mutant" that *inserted*
    a duplicate step rather than *relocating* one produced a red — but proved only
    sensitivity to placement, not that the guard catches the reorder it was written for.
    Diff-verify every mutant; a red you wanted is the easiest thing in the world to accept.
    A red counts only when this run built the page it ran: a mutant whose build failed left the
    last run's pages in the output folder, and the runner replayed them, so the "red" came from
    an older mutant. Wipe the output folder before each mutant build, and stop on a failed build
    instead of running whatever pages are there.

49. **Report the non-findings.** An audit that finds a defect in everything it inspects is
    usually an audit performing thoroughness — the useful output is *which* items were wrong
    and *why the others were not*. For a sweep, the negative results are half the
    deliverable: "your two hypotheses are falsified across 39 suites" is what lets an
    orchestrator ship without hedging.

50. **Propose an omission with the evidence that makes it safe, not the conclusion.** "I
    skipped the integration re-run — here is the diff proving nothing in those paths
    changed" is a thirty-second decision. "Should be fine" costs a full re-run.

51. **A test file that overstates its own coverage is worse than a missing test, because
    the next reader stops looking.** A coverage claim is a claim: it needs the same evidence
    as a behavioral one. *Provenance:* a header fixed an over-claim about code scope and
    introduced a fresh one about test coverage **in the same edit** — the tidy sentence
    arrives first, and repairing a claim feels careful enough to skip checking the new one.
    A pin that only prints a value the builder claims is the same over-claim: mutate the
    claim away and predict GREEN; a mutant that survives is the finding.

52. **The hedge is the untidy part, and a write-up wants a clean rule — whoever is writing.**
    An orchestrator turned a builder's "I ran no sweep" into "patience saved a sibling's
    run," and its "a small piece of evidence" into "a natural experiment." A builder turned
    "three of six sites guarded" into "the state is unreachable." **The self-inflicted case
    is harder to catch, because there is no second party whose qualifier you notice yourself
    dropping.** When a builder qualifies a claim, the qualifier IS part of the finding.

53. **Sweeps run from a SHA-pinned worktree, and you must replay your scoping patterns
    against the full file list before claiming coverage.** A shared checkout moves under a
    long sweep as siblings commit, making chunks incomparable and attribution worthless.
    And scoped chunks silently drop anything the patterns miss — one suite matched no chunk
    pattern and had never run; the report would have said "149/149" having run 148. **The
    omission is invisible from inside the chunking.**

54. **A standing instruction that a tool violates automatically is not a standing
    instruction.** "Don't clean the shared containers" was unachievable, because the gate
    invokes that cleanup at stage 1. The fix is a knob (an env var raising the liveness
    floor), not a rule. Corollary: **"I didn't run X" is not the same claim as "X didn't
    run"** — report on the tooling's behavior, not only your own actions.

55. **Couple two changes into one train when the INTERMEDIATE state is worse than either
    endpoint** — not merely because they are related. Shipping an ordering fix without its
    replay-parity companion would have released a version whose own fix made replays lie.

56. **Memory recall runs on the description, not the body — check what a description is
    retrievable BY, not just whether it is correct.** An accurate, indexed, week-old memory
    answered a question three sessions had; none found it, because its description named the
    *subsystem* and never the *tool everyone runs*. **A memory retrievable only by people
    already thinking about its topic is retrievable mainly by people who don't need it.**
    This is a writing-time discipline. The wrong conclusion is "write more memories."

57. **Knowing a rule does not prevent the failure it describes.** A builder cited the
    restore-was-a-delete rule to the orchestrator hours before walking into it. Recall is
    not the bottleneck; *applying a rule while inside the situation it describes* is a
    separate skill. Build the check into the procedure rather than trusting recall.

58. **Killing a row on zero population is a good outcome, not a wasted afternoon.** Two rows
    died that way in one session — one because a backfill described in the *future tense* had
    actually shipped five weeks earlier, so an audit believed the comment over the data.
    Require the population count *before* the build, and say "zero" out loud so nobody
    re-files it.
    A number in a code comment carries no commit: a balance or tuning figure quoted from a comment
    may describe code that has changed since. Before offering such a number for a decision, re-run
    the simulation or measurement on the current base and quote the commit SHA beside each number.

59. **Fail-open vs fail-closed is the load-bearing property of any client-side guard.** A
    disable derived from data that may not have loaded must degrade to *enabled* — the
    server's refusal is the real guard. A false disable silently denies a legitimate action
    with no error and no recourse, which is far worse than the dead click it replaced.

60. **A guard that cries wolf gets deleted.** Measure a marker/heuristic set against the real
    corpus before shipping it: a first-choice marker matched three files, two of which were
    unrelated. Precision is what keeps a guard alive long enough to catch anything.
    The other side is recall: a parser of hand-written status markers must accept every form the
    source actually uses. Count the forms first (bold, bulleted, quoted, italic notes), and derive
    the expected table a second, independent way before trusting the parser's output; one missed
    form silently files those entries under the wrong status.
    A browser layout walk cries wolf the same way: content clipped by an ancestor with hidden
    overflow, or inside a closed `<details>`, still has client rects. A right-edge overflow walk
    clips each rect by its overflow ancestors and skips closed `<details>`, or it reports hidden
    text as overflow (the opposite trap, a missed overflow, is 68).

## Guards, gate logs and worktree git (harvest 2026-10-15)

*One orchestrated day of tool-building rows, each read by a sibling verifier. Every lesson below
came from a verifier finding or a falsify run that went red where the builder expected green.*

61. **A guard's verdict holds only for the stage it ran at: run it after the last step that changes
    what it looks at and before any step that erases it** — or that erasing step must record what it
    erased, and the guard reads the record. A guard scanning a model's named parts for forbidden
    names ran after an export step that deletes those parts, so it could never fire; it printed
    green on every input. Only mutating the *writer* (feeding it a forbidden key) showed it. The
    other order fails too: a check counted defects part-way through a pipeline and passed; a later
    step reshaped the geometry and the final output failed the same check. Order the pipeline so the
    scan sees the final input: place the guard after the last step that moves its input, or run it
    again there and quote that count (see 84), and before any step that erases it. Prove each guard
    red by mutating what produces its input, not just the guard itself.

62. **A measuring guard draws its measured landmarks on the output it judges.** A proportion
    check passed a ratio of 0.16 because its slice sample was too sparse to land on the feature
    it claimed to measure; the number looked plausible and the log looked clean. Only an overlay
    of the sampled points on the rendered output showed they missed the feature. A measurement
    nobody can see is a measurement nobody can check: emit the overlay with the verdict.

63. **Write the gate log's SHA line inside the throttled command, after the slot is acquired.**
    A header written before the wait for a gate slot can name a commit the tree no longer holds
    by the time the gate runs (a rebase or a new commit lands during the wait), so a green log
    vouches for the wrong SHA. Print `SHA $(git rev-parse HEAD)` as the first line the throttled
    command itself runs; the verifier compares the slot time against the reflog. Extends 32.
    The same wait decides what is tested: a gate queue copies the tree when its slot frees, not
    when the run was queued, so edits made while waiting are what gets tested (and what the log
    vouches for). Do not edit the tree while a queued gate waits, or run it from a snapshot made
    at queue time.
    Commit before the gate run, so the SHA line names the saved version and the log vouches for a
    tree with no uncommitted edits.

64. **In multi-worktree sessions run every git write as `git -C <worktree>`.** The shell's
    working directory can reset to the shared checkout between commands, so a bare `git commit`,
    `checkout` or `merge` meant for a worktree lands in the shared tree instead — one stray
    checkout detached the shared main. Name the tree on every write; reads may stay bare.
    Extends 2 (worktree isolation) and 30 (guard the shared checkout's HEAD).

65. **Falsify a path or name filter with its escape variants, and prove each layer bites on
    its own.** A name denylist missed a forbidden item whose name it never anticipated; the
    whitelist that replaced it checked only the first path segment, so `allowed/../forbidden`
    passed. Plant `..`, absolute-path and case variants of every forbidden name, not just the
    names themselves. When the guard is layered (a name check, then a content check), patch
    the earlier layer out in-process and show the later one still goes red on its own: a
    layered guard whose inner layer never fires alone is one guard, not two.
    The same holds for finding paths in files: a search by spelling (one drive letter, one
    prefix) misses relative paths such as `../../x` and paths on other drives. Resolve every
    path-like string to the place it points and judge the target, not how it is written.
    A name-tied exemption is falsified with real in-between data placed under the protected
    name, before any hand-shaped body.

66. **A check that compares a clamped accessor can never fail: compare the underlying value.**
    A getter that caps its result at a maximum (`min(value, max)`) reads exactly "max" whether
    the stored value is at the cap or far past it, so a test asserting "does not exceed the max"
    through that getter passes on every overflow it was written to catch. Assert on the raw
    stored value, and falsify by pushing the raw value past the cap: if the check stays green,
    it is reading the clamp.

67. **A probe number that feeds a human ruling is cross-checked by a second path first.** A
    probe meant to measure a "full" store filled it to half: one accessor counted per unit, the
    other the total of two units. The number it reported shaped a design ruling, which then had
    to be re-asked when a real run disagreed by a factor of several. Before a probe's number goes
    to the person deciding, reproduce it another way (a fixture built by the real code path, or a
    real run) and say in the report that both agree.
    Give the number at full precision whenever someone will set a limit from it. A value
    reported as "0.030" was really 0.030329; the reviewer set the limit at 0.03, and the real
    value failed it. Quote the script's own output, unrounded, and round only in prose that sets
    no limit.

68. **A measuring guard takes its landmarks, reference length and containing edge only from things
    the input cannot move, fails closed when they are missing, and is tried on known-bad input.**
    The measured object must not choose its own landmarks. A guard that found its reference points
    by a heuristic (the largest step in a profile, the widest slice) could be steered by the input
    it judged: a small shape change moved the "largest step" to a different place, and the
    measurement followed it. Pin landmarks to something the input cannot reshape (a skeleton's
    joints, a certified reference basis), and fail closed when they are missing (see 62: draw them
    on the output too).
    A guard measured in fractions of a total takes the total only from parts that cannot be
    stretched. A shape guard expressed its limits as fractions of the model's overall height, read
    from the lowest to the highest point. An added base part lowered the lowest point by a few
    centimetres, which grew the "height" and shrank every ratio under its limit, so a model the
    guard should refuse passed. Take the reference length from parts the input cannot extend (named
    anchors, a fixed skeleton), or refuse any input whose reference parts are not the expected ones.
    A check that re-centres on the shape it measures follows that shape the same way: test it on
    known-bad pictures before trusting it (one such check passed arms drawn far too thick).
    Containment is the same trap: "the child stays inside its box" measured against the box's own
    edge passes when the overflowing child widens that box. Measure against an edge the defect
    cannot move (the screen, a fixed parent, a width set in the test).

69. **A mutant or probe counts only after you show it took effect: its diff removes or changes the
    guarded line, its selection picked at least one item, and the measured value moved.** A falsify
    run fed a deliberately bad input to a guard and the guard passed it, which looked like a hole;
    another run "passed" correctly, which looked like proof. In both, the mutation had not changed
    the feature the guard measures. Log the measured value before and after the mutation next to the
    verdict: a mutant that moved nothing is no evidence either way (see 21 and 48 for code mutants).
    The same holds for a probe: before trusting a probe's number, or a mutant's verdict, show that
    it moves the quantity the check reads. A probe that changes a neighbouring value reports nothing
    about the one under test.
    A code mutant removes or replaces the guarded line; a diff that only adds lines is a no-op. A
    mutant meant to disable a check added a line beside it and left the check itself in place, so
    the guard still ran and the "mutant" proved nothing. Before running a mutant, read its diff: it
    must show the guarded line as removed (`-`) or changed. A diff with only `+` lines does not
    disable anything (see 48 and 70).
    A probe or mutant whose selection is empty passes vacuously: make it abort on an empty pick. A
    mutant that was meant to alter "every item matching X" matched none, changed nothing, and the
    check stayed green, which read as a guard that held. Count what the selection picked and abort
    with a message when the count is zero; report the count next to the verdict.
    Keep the falsify record (the mutant's diff, the prediction, the red line seen) in a commit
    message on the branch, and keep the mutated files, so a reviewer can rerun it.

70. **For a code mutant, predict the exact failure message it should cause, not just red or
    green.** A mutant that removes one check can turn the run red through a different check that
    happens to fire too, and a bare "went red" accepts that as proof. Write down which named
    check should fail and with what message, then compare. A red that arrives through another
    check, or a check whose flip is hidden behind an earlier failure, is reported as an unclean
    falsify, not a pass.
    Predict only the guard's own effect line: the message or value the guard itself emits when
    it fires. What the program does after the guard has fired is a guess, so it is written down
    as a guess and never scored as part of the falsify.
    Say which checks still run after the first failure: a run that stops at its first red never
    reaches the later checks, so a prediction that counts on them cannot be scored.

71. **"Old data" fixtures are built by the OLD code, in its own worktree.** A migration test
    loads saved data from before a format change. Fixtures written by the new code in "old
    mode" carry the new code's assumptions and can pass a migration that real old saves would
    break. Check out the commit before the change in a separate worktree, produce the fixtures
    there, record that commit in the fixture's header, and only then test the new code on them.

72. **Never judge a change on a total: run one unchanged probe on base and tip, print one line per
    source or action at each input level, apply any tolerance per row, and diff line by line.** A
    claim of "within plus or minus N percent" is checked per row, not on the total. A re-tune
    reported every total within -4 to +2 percent of the old numbers; one of the sources feeding a
    total had moved +60 percent, cancelled out by others. Report the change for each source
    separately and apply the tolerance to each row; a total within tolerance proves only that the
    errors cancel.
    For a parity review, run one probe script unchanged on the base and on the tip, and diff per
    action and per input level, never per total. Two probes written for each side, or a probe that
    sums its results, let opposite differences cancel and let each side measure something slightly
    different. Keep the probe free of calls that exist on only one side (or pick the call at run
    time), print one line per action at each input level (empty, half, full), and diff the two
    outputs line by line.

73. **Test a lock's atomicity on the filesystem where the real lock lives.** A race test for a
    create-if-absent lock ran in a local temp folder and passed; the real lock file sits on a
    network-style mount (a 9p or SMB share), where exclusive create can behave differently. Run
    the race, and its falsify, with the temp folder on that same mount, and use a temp path with
    the same shape as the real one (spaces included): a test that only ever ran on local disk
    says nothing about the mount, and a path without spaces hides quoting bugs in the test
    itself.

74. **A gap measured to an outline must also catch a part that sits inside the shape.** A spacing
    check that took the distance to the nearest outline point read a part buried inside as
    "touching" and passed it. Give a point inside the shape a negative gap, so a part that sinks in
    fails, and plant one inside to prove it.

75. **After a scripted marker-to-marker cut, grep for the lines it removed.** A script that
    deleted everything between two markers also swallowed three settings that sat inside the
    range; nothing failed until a probe run showed the settings missing. After any cut by
    pattern or marker, list the removed lines (`git diff | grep '^-'`) and check each one was
    meant to go, before the next step builds on the file.
    The same goes for a find-and-replace that splices text into the middle of a line: edit whole
    lines, then read the diff to see each changed line in full.

76. **A context-fill measure reads YOUR transcript, picked by your own session id, never the
    newest file.** The script measures whichever transcript it is given. A fresh session that
    took the newest transcript in the folder measured a sibling's 173K as its own. Take your
    identity from your own listing (the agent listing's first line, or your env block), find
    the transcript that belongs to it, and measure that one.

77. **A lock helper's release removes only the exact line it wrote, and its default owner is
    unique per run.** A release that deleted the lock without comparing owners could free a
    lock another run had taken since; fixed default owner names let two unnamed runs each
    believe they held it. Write an owner unique to the run (tool, host and process id) unless
    the caller names one, and on release or trap compare the whole owner line before removing
    anything. Never use a real session's name as the default (see 73; 76 on session identity).

78. **Quote context fill from the measuring script's output, never from memory.** A verifier
    reported about 175K in a status line while its real fill was 300K, past the report mark,
    and kept working. Every fill number in a READY, report or handover is the script's
    `current` line pasted from a run made in that same turn.
    Time stamps follow the same rule: a stamp on a board, log or handover comes from `date -u`
    run in that turn, never from memory or from the last stamp you saw.

79. **Parity with the old version is proved by diffing the old code's whole output against the new,
    and a zero-line diff counts only after a mutant shows it can differ.** A change meant to leave
    the results as they were passed every per-number check, and a reviewer still found rules that
    behaved differently. When the goal is "same as before", write the old code's full output once (a
    report, a probe of every rule) and `diff` the new one against it; zero lines of difference is
    the proof, not the numbers you picked (see 72).
    A byte-identical comparison ("the report is identical") proves nothing if the comparison never
    reads the part that changed (the wrong file, a cached copy, a section the generator skips).
    Before quoting a zero-line diff as proof, make it fail on purpose: change one input that must
    move the output (a mutant), rerun, and see the diff go non-empty, so the comparison is known to
    see a change.
    Sample the odd moments as well as the usual one. A "nothing changed" check looked at the normal
    case only, while the change showed only at night, or on single frames. Probe every regime the
    rules read (time of day, per-frame versus per-snapshot, the rare branches), not only the moment
    where the check is convenient (see 80).

80. **After moving a threshold or a scale, sweep every run-time input the rules read, not only
    the default.** A rescale matched the old results with the default inputs and diverged once a
    state value the user controls (a fill level, a count, a carried amount) was at half or
    full: some rules still read a value that included that input on the new scale. List each
    input that feeds a rule, probe at its empty, middle and full values on both versions, and
    compare per rule (see 66: never read through a clamped accessor).
    A scenario that holds two inputs equal cannot tell them apart: when two readings of a rule
    differ only where two inputs differ (one counts a value once, the other twice), vary the
    input that separates the readings, or both readings pass on the pinned case.

81. **Never chain a push or a "done" claim after a gate with `;`.** Commit first (see 63), then
    `run-gate && git push`: with `;` the push, or a "gate green" report, goes out even when the gate
    fails, and red code reaches others under a green-looking commit. Join them with `&&`, or run the
    gate, read its pass line, and push in a separate step; a red gate is fixed in a new commit.
    The same holds for a script that edits a file and asserts its own result: run it in one `&&`
    chain with the commit, never with `;` or on a new line, or have the commit step check that the
    diff shows the change. A failed assert writes nothing, and the commit ships the old text under
    a message that claims the edit.

82. **A test that takes its expected value from the constant it guards cannot fail on that
    constant.** A check computed "what should happen" from the same setting the code used, so
    setting it to zero moved the code and the expectation together and the check stayed green.
    Write the ruled value into the test itself. To falsify, mutate the constant AND, separately,
    delete the call it drives; both must turn the check red (see 70 and 69).
    The same goes for an oracle that calls the function it checks: its expected value changes
    with any change to that function, so it passes every change. Take the expected value from
    the ruling or from a value written down before the change, never from the code under test.
    A helper in the test that re-implements the code's formula is the same oracle: a bug copied
    into both stays green. Where the formula cannot be avoided, also pin one case with its value
    written out by hand.

83. **"Every item is covered" comes from a script over the list, never from memory.** A write-back
    reported that every item on a list was ruled, tested and migrated; a script over the same list
    then found one item missed and one never ruled. Before claiming full coverage, loop over the
    list's real source (the file, the table, the grep) and print each item with where it is
    covered; quote that output, including its count.
    A test that trusts the data's own tags cannot catch a mis-tagged entry: rebuild the
    population from the file itself (the real column, the real text) instead of from a tag the
    entry carries, then compare the two counts.

84. **When a repair pass runs before a check, report the check's count before the repair too.** A
    local cleanup (a relax, a smooth, an auto-fix) ran before a metric and turned its red into a
    visible artifact the metric no longer measured (folds became wrinkles) while the gate read
    green. Print the metric before and after the repair; a large drop is a finding to look at,
    not a pass (see 62: measure on the output).
    The same blindness hides in the check's zone: a check whose zone sits inside the zone a fix
    just cleaned passes by construction. Report a wider, independent read of the same output
    next to it, and keep the human-eye check as the evidence.

85. **After a machine crash, audit before assigning any work.** A crash left a rebased branch
    unpushed in one worktree, shared memory files uncommitted, gate logs gone with the temp
    folder, and a lock naming a dead session. Before any sibling gets work: check every worktree
    for dirty files and unpushed commits (push a rebase under a new branch name, never a
    force-push), commit shared memory left behind, treat every gate log under a temp folder as
    lost and re-run those gates, check each lock against a live owner, and hold the siblings
    until the audit is done.

86. **Relay only a settled human ruling to a builder.** The seat forwarded each step of the
    human's thinking as it came in, and one builder got five specs in fifteen minutes, each
    superseding the last. Collect the whole answer first, ask "is that final?", then send the
    builder one spec.

87. **A visual check done on thumbnails is not a check; give each property its own measured
    check.** A review passed images that looked right at contact-sheet size, and a line-style
    metric passed a view that was turned 15–20° from the one asked for. Measure at full
    resolution with a number, and check each property separately (style is not geometry: the
    angle, the outline and the proportions each get their own metric).
    Check in the same view as the final output. A shape check passed on a flat, simplified
    render while the real pictures, made through the normal camera, moved 3 to 4 pixels. Measure
    with the camera, projection and resolution the delivered output uses, or show first that the
    cheaper view gives the same numbers.
    The converse also holds: after a batch passes its number checks, still look at every changed
    picture or artifact at full size. A count or a size metric passed a frame that was flipped and
    another with stray specks; numbers measure what they were built for, and only the look sees
    the rest.

88. **Prove a new check red on the artifact the human actually rejected, not only on a made-up
    broken case.** A check passed a hand-built bad example and still passed the very output a
    reviewer had refused, because the invented case failed in a way the real one did not. Run
    the check on the rejected artifact itself (the picture, the file, the saved run) before
    calling it a guard for that complaint; if it stays green there, it does not guard it (see
    69).
    Before building a check for a reviewer's complaint, measure what actually differs between the
    rejected output and an accepted one: a "too wide" complaint was a taller header, not wider
    columns, and the planned column check would have passed the rejected output.
    A hole or regression count proves nothing until it has run on the real failing case. Check
    that its window covers the whole claim (the crop, every layer the complaint is about) and
    that it counts leaks open to the edge, not only enclosed holes: a count over a cropped or
    single-layer window, or one that fills only closed gaps, read zero on the very output that
    was refused.
    Run every new check against the code before the fix and label each one: a check that fails there
    reproduces the complaint; a check that passes there is a regression guard, still worth keeping,
    but no proof that the fix addressed the complaint.

89. **When inheriting a row, list its scratch files by modification time against the branch tip.**
    A builder took over a row from a session that ended abruptly; its scratch folder held
    attempts newer than the last commit, never logged, one of them the working version of a
    step the branch still lacked. Before starting, list the row's scratch and output files
    sorted by time next to the tip's commit time: any file newer than the tip is an unlogged
    attempt, to be read, logged or discarded on purpose (see 85).

90. **A factor in a shared function is checked at every call site, not only where it is defined; a
    test drives the sites and a READ lists every caller.** A test checked a helper's result and the
    helper was right, while one caller multiplied the result by the same factor again; the total was
    off by that factor and every check stayed green. A review likewise confirmed a factor was
    applied correctly in the function that owns it, without listing who calls the function, and one
    caller applied the same factor again or skipped it. Grep every caller, quote the list, and state
    for each whether it applies the factor itself.
    A check that never runs the call site cannot see a site that applies a factor twice. Either
    drive the call site itself, or check the exact call text (grep the line, count the factor's
    occurrences per site), and falsify by doubling the factor at one site. Next to a per-site check,
    also assert the exact total number of call sites, so a site added elsewhere cannot go unchecked,
    and falsify by adding one extra call in another function.
    The same applies to a claim that code never runs or is dead: cite a full caller grep on the
    object's real class (subclass overrides included) or a probe; "runs but is never seen" is a
    separate verdict. The same goes for "X unchanged" lines in records (a changelog, a decision
    log): cite the search behind each one.

91. **Before proposing how to satisfy a refusing check, trace where the check takes its input.**
    A guard refused an object and the first fix proposed edited the stored data it was assumed to
    read; the guard actually read a live, derived value (an evaluated result, not the stored
    field), so the edit changed nothing. Read the check's own code to the point where its input
    enters, name that input, and only then propose a change to it (see 67).

92. **A gap you have not isolated is "not explained", never "noise"; a quantity is "display
    only" only after every consumer is traced.** A small unexplained difference between two runs
    was written off as noise, and a value labelled display-only fed a rule two calls away.
    Write "not explained" until the gap has been reproduced and attributed to a named cause; call
    a value display-only only after listing every reader of it (grep each consumer, quote the
    list) (see 72 and 80).

93. **A failure that depends on the path cannot be bisected by one run per commit.** A crash
    appeared only on some routes through a long scenario, so a good run on a commit proved
    nothing and a bisect pointed at three different commits. Read the crash frame, reproduce the
    engine fact it names in a minimal script, and prove the fix with a check that can fail (a
    mutant that restores the bug turns it red), not with a green run of the long scenario (see 70
    and 69).

94. **A liveness guard compares to the thing it guards; pasted for another kind of object it
    silently aborts.** A guard written for one kind of node (a level) was copied to guard a
    different kind (a child overlay that is never the level), so the guard failed every time
    and the scripted run quietly stopped; the lint and the smoke test stayed green and only
    the full playthrough saw it. For each guard site, say what object it guards and which
    object the guard compares against, and plant a case per kind (no guard, wrong guard, right
    guard) in the lint; falsify by pasting the guard onto the other kind and checking it goes
    red (see 70 and 93). A guard counts only where it controls the use: plant cases where the
    guard is nested away from the use, is a no-op (`if G: pass`) or is joined by `and not G`,
    and require the lint to flag each.

95. **A refit that wins back broken bars can quietly move the bars it does not score.** A
    geometry refit repaired the failing measurements while a neighbouring measurement it never
    scored drifted past its limit (a notch went from −1.4 to −1.8 mm). Put every bar that
    must hold into the refit's cost, not only the ones that failed, and report all bars
    before and after the refit (see 62 and 91).

96. **Before wiring an effect to an event, prove the event can fire where the effect lives.**
    An effect was hooked to a clock tick that does not run on the screen the effect belongs
    to, so the hook was dead code that only a probe could reach. Name the event, name the
    screen or state the effect lives in, and show a run in which the event fires there (a
    log line from the real path, not from the probe) before building on it (see 90).

97. **Prove a cause by pinning one path at a time, and measure options as patch scripts on the
    probe's temp copy.** Several candidate causes were changed together, so a better result
    could not be attributed; and trying options by editing the product left changes to be
    reverted. Pin or remove one path per run and record which pin moved the number; apply each
    option as a patch script to a temporary copy of the tree, so a proposal milestone commits
    no product change (see 92).
    When a defect survives a fix to one stage of a pipeline, swap components before the next
    fix: hold one stage, vary the other (A/B renders or runs), and see which stage carries the
    defect. A scalar meter can confirm a wrong cause: a meter computed in the wrong space or
    over zones of mixed scale moved with each fix while the defect stayed, and several refits
    were spent on a stage that was not at fault (see 87).
    Before an A/B, read the settings the existing evidence was produced with (an earlier
    sheet was already rendered with shadows off), so the comparison varies only what you
    mean to vary.
    The same flaw in the same spot on every seed comes from the input, not the random draw: check
    the input picture before fixing the outputs.

98. **A gate that truncates error output can hide the reds a mutant should cause.** A falsify
    run was scored from a gate's shortened output (the first lines of the failure), and a
    mutant that did turn a guard red looked as if it survived because its message fell past the
    cut. Score every falsify result from the untruncated log (the full output file, not the
    gate's summary), and quote the count of red lines found there (see 69).
    Wrappers that delete the run log on failure hide the very lines a mutant should leave:
    run each mutant through the wrapper (for the exit status) and through a runner that
    keeps the log (for the lines), including the timed-out case. A timeout on a shared gate
    slot means load, not a failure: rerun with a longer limit before scoring it; until that
    rerun, a timeout is a claim, like a flake (see 13).
    Count failures from the full log, never from a cut-down list: a list cut at 40 lines hid 16 of
    56 failures.

99. **Size a parallel fan-out by free memory, not by cores.** A fan-out was sized by the
    processor count, started many heavy processes at once and ran the machine out of memory
    close to a crash. Start at most two heavy processes, and start each only when the free
    memory reported by the system is at least 3 GB; wait otherwise (see 85).
    On a shared GPU or similar scarce device, gate each job on the CURRENT baseline before
    it starts, not only on a peak limit: a sampler that reads once a second cannot stop a
    load spike, and a neighbour that just finished may still hold its memory. Memory-mapped
    arrays still count in resident size: two mapped files diffed together read as the sum of
    both, so budget each process as frames x size x item size for everything open at once,
    and stream one frame at a time.

100. **Stopping a background shell task leaves its child processes running.** A task was
    stopped and the engine process it had started kept running, holding memory and a lock.
    Record each heavy run's process id at launch (a file next to its log) and stop it by that
    exact id; never by a name match, which can also kill your own shell or another session's
    run.
    The same holds for a wrapper (a shell launcher, a detached start): killing the program
    leaves the wrapper alive, so at the end of a session list your own processes by start
    time and stop the wrappers too. When a row moves to another agent mid-run, kill your
    queued gate chain by id and check the throttle queue for leftover tickets.

101. **After every delivery, assert the delivered file's md5 against its source.** A file was
    copied to its destination and used on the belief that the copy was the source; an older or
    partial copy had been left there. Compare the md5 of the delivered file with the source's
    in the same command that delivers it, and fail the step when they differ.

102. **Before a long optimization against extrapolated targets, check the targets can be met
    together.** An optimizer was set to hit several targets (a fill, an aspect ratio, a
    ratio against the source range), each extrapolated on its own beyond the measured range.
    The separate curves drifted apart, no solution met them all, and the run stalled for hours
    on a target nothing could satisfy. Before the long run, evaluate every target at the
    extremes and at the points beyond the measured range, and test that one candidate (or a
    cheap relaxation) can satisfy them all at once; if not, reconcile the targets first (see 95).
    A target defined on a flat render of a three-dimensional scene (the share of one part hidden
    behind another) is checked against the render's layer draw order before it becomes a pass line:
    parts drawn on a layer below the covered part can hide none of it, so a target that counts on
    them can never be met.

103. **Run a long background chain as one script, memory-gated per step, with a status file per
    step.** A chain of heavy gate steps was started as separate background commands; the
    system's low-memory reaper killed it partway, and nothing showed which step had finished,
    which was running and which never started. Put the chain in one script that waits for free
    memory before each step and writes each step's own status file (started, exit code, end
    time) next to its log, so a reaped chain shows exactly where it stopped and can resume
    at the first step with no finished status file (see 99 and 100). This holds for
    independent gate steps; a probe set cut off part-way is rerun whole (see 115).

104. **A planted bug proves a new test only if the old tests miss it.** To show a new test works, a
    bug was planted and the test went red, but the existing tests went red on that same bug, so
    the new test added nothing that was not already guarded. Run each planted bug against the
    old suite too and record both results: the new test earns its place only on a bug the old
    suite leaves green (see 70 and 69).

105. **Falsify a check in the mode the real gate runs it.** A check had a quick mode and a
    strict mode and ran in the quick one by default, where it could not fail. Prove a check red
    with the same flags, environment and mode the gate itself uses, and make the gate name that
    mode explicitly instead of relying on a default.

106. **A stamp that records how something was made counts only if something reads it and stops on a
    mismatch.** A tool wrote the settings it used next to its output, and nothing ever compared
    that note with the settings in force, so a mismatch could never be caught. Wherever a stamp
    exists, add the reader that compares it with the live values and fails on any difference,
    and prove that reader red by changing one setting (see 79).

107. **Before pinning an anchor per frame to a measured extreme, measure the motion the pin adds.**
    An animation's ground point was pinned frame by frame to the lowest pixel of each frame. The
    source drifted about 2 px; the pins made the result bounce 6 to 7 px, because each frame's
    lowest pixel moves with the content. Measure the anchor's motion in the source, then in the
    pinned result, and pin to a value that is steady across frames (a median over the
    animation, per direction) when the pinned result moves more than the source (see 87).

108. **Measure a "missing" step's output at every later stage before rewriting it.** A step
    thought to do nothing was about to be rewritten; it was firing and only under-correcting
    (it lifted a far leg to 0.93 of the target), a later gamma grade doubled the remaining gap,
    and the last stage reported ok for a frame it had got wrong. Read the step's own output
    and each later stage's input and output for a few items before changing it; fix the stage
    where the gap appears, not the one that looks idle.

109. **After a batch fix, a mask-only composite plus an md5 count proves the fix touched only what
    it should.** A fix meant to change 30 of 288 frames was first applied by re-running the
    whole pipeline, which changed 6 to 47 px per frame outside the fixed area on frames it
    should not have touched. Composite the fixed result into the old frame through the fix's
    mask only, then count by md5 how many outputs differ from before: the count must equal
    the number meant to change (here 30 changed, 258 identical), and the differing pixels must
    lie inside the mask (see 79).

110. **A mutant that stays green means a second path recovers the result: find it, switch the paths
    off in stacked steps, and say the check proves only that at least one path works.** A mutant
    removed one fix and the check stayed green, because another piece of code reached the same
    result by a different route. In another run two fixes covered for each other, so switching off
    one left the run green and the test looked weak: a fix whose trigger appears only after another
    fix is removed cannot go red alone. Find the second path before calling the check weak, mutate
    both together to see the red, and stack the mutants: switch the paths off in steps from one
    saved state (A off; A and B off; all off), say in the prediction which step should turn which
    check red, and score each step from its own result (see 97 and 104). State what the check
    proves: that at least one of the paths works, not that the mutated one does (see 51).
    A tool that places a part itself is such a second path for a planted case. A bad placement
    planted before the tool ran was quietly moved back by the tool's own placement step, so the
    check saw a good result and the plant proved nothing. Pin the placement (turn the tool's placing
    off, or plant after it) and confirm the planted case is still wrong in the output before its red
    counts.

111. **Judge a guide on every view before spending a long job on it.** A reference guide looked right
    from the front and was wrong from the side; the fault was found only after the slow
    job had run. Before any slow or scarce job (a GPU run, a render, a bake), look at the guide
    from each view the output will be judged in, and reject it there first (see 102).

112. **A pick-by-eye sheet shows the candidate between fixed anchors, at one scale, on one
    baseline.** Candidates drawn at different sizes and baselines, with numbers printed on the
    picture, could not be told apart by eye. Put the candidate between its fixed neighbours,
    at one scale and a shared baseline; put zoom-ins and measurements in the written
    note, not on the sheet.

113. **After a change moves what a check aims at, grep every helper that references it and rerun
    every mutant aimed at it and at checks that share its state.** When a change removes a UI
    element, grep every test helper, wait and measure that references it, then build and run every
    planted mutant once after the change. A mutant whose anchor vanished, or that no longer goes
    red, is a dead check, and a helper that waits for a removed element passes or hangs for the
    wrong reason.
    Re-aiming a check (a new selector, region or threshold) is such a change too: rerun every mutant
    aimed at it, and also the mutants of checks that read the same shared state (browser storage, a
    cache, a saved file). A setting written during one check's run turned an unrelated mutant green.

114. **When the look is the requirement, a headless check of the model is not the check; read the
    drawn pixels and add a mutant only the pixel read can kill.** A test confirmed that a glow
    was scheduled with the right numbers and passed while the drawn glow came out white at
    night, because one draw mode skips the scene's tint; a divided-out multiplier was never
    checked on the drawn result either. A pin that stores a value beside the draw call, or
    calls the update itself, cannot see the effect. Read the rendered pixels inside the
    subject's own mask, and prove the check red by mutating the effect itself (its colour,
    its draw order), not the number the pin reads (see 82 and 96).
    A headless browser on virtual time draws no frames, so animation-frame and resize-observer
    callbacks may never run there. A fix that lives in such a callback is checked by reading its
    code (or in a real browser), and the report says which; a green headless run proves nothing
    about it.
    The same applies to whoever presents a look for a human decision: when every automatic check
    passes but the result is visual, the coordinator opens the result itself before asking for the
    decision. Checks passed for three rounds while the look failed, and only opening the picture
    showed it.

115. **A probe run that dies part-way gives no results: rerun the whole set.** A long run of
    probes crashed after some had finished, and the finished ones were quoted as findings.
    If a run is cut off, none of its numbers count; rerun the whole set and quote only from a complete run
    (see 69).
    A run on the code before a fix often crashes at the same place every time, so a plain rerun
    repeats the crash. Cut out the crashing block (it counts as a fail for its own checks), rerun,
    and repeat until every check has a verdict on the pre-fix code.

116. **Before a check or metric counts, calibrate it on cases with a known answer: it must pass the
    known-good case and fail each known-bad case, and the margin is reported.** A metric that ranks
    things must be run on the reference pair it is meant to rank, and on wrong references. A
    person's by-eye read contradicted a similarity meter that ranked a candidate level with the
    larger reference while reading 64 percent. Before trusting a metric, score it on a pair whose
    order is known: every right pair must beat every wrong pair (a shifted frame, the other view),
    and the margin is reported. A meter that cannot separate known pairs is broken; fix or drop it
    before it ranks candidates (see 69).
    A camera or vanishing-point check is proved on shifted copies and on the reference itself. A
    check meant to say "the picture keeps the reference camera" passed pictures made with a
    different camera, and another read junk on every input, the reference included. Run it on copies
    of a good picture shifted up, down and sideways, one axis at a time, and require a FAIL for
    each; run it on the reference picture and require a PASS. A check that passes the shifted copies
    or fails the reference does not measure the camera (see 88 and 119).
    An edit check with a quantisation floor (the smallest change it can see) is trusted only after
    it passes a null edit (no change) and fails a mutant (a known-bad change); a fail without that
    calibration may be the floor itself.
    Run a new picture check on the picture already accepted first; if that one fails, the check is
    wrong, not the picture.
    A never-fail baseline must come from clean input. An output made from an input that already held
    the defect carries the defect, so checks that pass on it prove nothing; prove the checks can
    pass on clean reference data first.

117. **Test on the worst real case first: the largest edit step on the hardest case before a ladder
    of edits, and a fit or layout check on the real worst case across the whole page.** A method's
    size ceiling only shows on its largest step, so trying small steps first hides it (calibrating
    the edit check itself: see 116).
    A "fits" check (one row, no overflow, no wrap) runs on the real worst case: the largest count of
    items and the longest label the data holds, not a small fixture. A layout that fits five short
    entries can wrap at twelve long ones while the fixture stays green.
    Measure a layout guarantee (at least N items per row, fits one row) where the user sees it:
    across the whole page, on the real item count and size spread, with the previous layout as a
    mutant that must fail. A per-container count on a tidy fixture passed while most rows on the
    real page held one item (see 68).

118. **A shape gate on an edited outline is relative to the original over the same rows,
    checked at several scales, and reported as a pass fraction.** Absolute curvature bars
    flag the figure's own bends where the defect sits, so compare against the original over
    the same rows. One scale misses flat-bottomed defects: check several scales and prove
    the gate red with a planted flat-bottom mutant. When a bar sits at the measure's noise
    floor it passes only in pockets of the parameter grid (4 of 54 here): report the pass
    fraction, never just "pass" (see 105).

119. **A validator needs a pin that feeds it a planted fault.** A validator run only on
    clean real data has branches nobody has proved: its checks survived mutants and a bad
    copy was never tried. Plant a bad copy for each branch (a missing slot, a wrong
    reference) and require the validator to refuse it (see 94 and 104).
    When the planted fault drops a record, first count the places that point at it (every
    reference, link or index entry that names it) and predict that many faults. A checker that
    reports a different count has a finding: it misses a dangling link, or reports one twice
    (see 70).
    The same holds for any detector: before its PASS counts, show it firing on a planted case
    that is known to hold the defect. A detector that never fires looks exactly like a clean result.

120. **A pass line is conditional on exactly the checks it claims; a span with no checks
    says only "no error logged".** A pass line printed unconditionally stays green when its
    checks fail. Make each pass line depend on the failure count of its own checks, and when
    adding a pin, count the unconditional ok prints (20 of 20 were found). A span that holds
    no check of its own prints "ok" only for "no error was logged": say so, and back it with
    a logger that counts errors only (see 98).

121. **Rebase only before the first push; after it, cherry-pick onto the pushed tip and
    re-gate.** A rebase after a push forces a force-push or leaves two histories. Before the
    push, rebase freely, unless the branch holds an unpushed `merge --no-ff`: a rebase
    linearizes it, so push that merge first (see 31); once pushed, move later work by
    cherry-pick onto the pushed tip and run the gate again at the new tip, so no force-push is
    needed (see 85).

122. **Compensating a non-deterministic generator's drift needs two rounds that agree
    first.** A generator that pulls its output back toward its own bias drifts differently
    each run. A one-shot compensation over-corrected (a width +1.9 became -2.1). Measure the
    drift in two independent rounds, compensate only when they agree, and compensate once at
    most.

123. **A design row's seam table includes the owner's earlier rulings on the topic,
    built or not.** Before a design is proposed, grep the decisions file for rulings on the
    topic, including ones never built. An unbuilt ruling reframes the row: a proposal that
    ignores it reopens a settled question. Open the document with what already exists.

124. **Parallel builders in one worktree: exclusive file lists, shared hooks committed
    first, one locked test runner; silent side effects and singletons get their own
    checks.** Give each builder an exclusive file list, let the lead commit the shared hooks
    first, and run tests through a single runner under a file lock. A claim kept true by a
    silent side effect (a parity draw that keeps two streams aligned) needs its own assert
    and a mutant that removes the effect. Tests that share one process restore any singleton
    state they touch.

125. **Flip a policy constant once before calling a change green.** A constant that sets
    a policy (a floor, a cap) is moved once to another value and the suite rerun: the pins
    that go red are the scenario-bound ones, tied to the value rather than to the rule. Five
    pins went red when a floor moved from 12 to 8; each is either rewritten relative to the
    constant or named as bound.

126. **A steadiness check measures at one fixed scale per route.** A pipeline that
    normalises each frame (to the same height, say) hides exactly the drift a size or
    steadiness check is looking for. Measure at one fixed scale per route, and before
    reading a result confirm no stage resized the frames individually (see 107).
    A batch step that derives a setting from the whole set (a median size, a shared box) must
    keep the old set's setting when new items join, or adding items quietly changes the old
    outputs and the new ones. Pass the setting in from the original set, prove a run with the
    new items alone equals a run with all of them, and check that the setting really reaches
    the step (an environment value can be dropped on the way into another program).

127. **A two-sided bound needs a mutant per side.** A check with a lower and an upper
    limit can survive a mutant on one side while the other side holds it red. Falsify each
    side separately: one mutant that breaks the lower limit, one that breaks the upper, and
    report both results (see 70).
    The same holds for a rule with several trigger paths. A rule that fires on path X or path
    Y is proven only when one single-change mutant on each path turns red: a guard proven
    through one path left the other one unguarded. List the paths the rule names and give
    each its own mutant.

128. **An automated quick reply to a person can invent facts or promise work nobody
    started; correct it in the full answer and never build on it.** A channel that answers
    instantly on the coordinator's behalf stated facts that were false and said work was
    under way when none had been started. The coordinator reads every such reply, corrects
    it in the full answer, and builds only on what the person actually said, not on what the
    quick reply claimed.

129. **While the base model is not agreed, send one proposal, not a fan-out of
    questions.** When the foundation of a design is undecided, a set of detailed questions
    asks the person to rule on parts of something that may change. Send a single proposal
    for the base first; open the detailed questions after it is agreed, one per real fork.

130. **Every async UI action gets one check with a deliberately late stub.** A test stub that
    resolves at once hides in-flight races: a redraw while a save or a remote call was still
    pending re-armed a button, and the instant stub never left a window for it. For each
    async action, add one check whose stub resolves late, fire a redraw (or the rebuild the
    real screen does) before it resolves, and assert the in-flight state holds: the control
    stays disabled, nothing is sent twice, the result lands once.

131. **Before a long round of redoing work toward a person's target, put today's result beside
    that person's own reference.** A round of re-posing was aimed at a coordinator's summary of
    what the owner wanted; set beside the owner's own reference picture, the summary had the
    wrong detail and the round chased it. Make one layout sheet with the current result next
    to the owner's reference before the long round starts; a summary of a wish is not the
    target (see 102 and 111).

132. **When a new random draw shifts a seeded run, compare the old code against the old code
    plus only that one draw.** Adding one draw to a seeded sequence moves every draw after it,
    so a long run took a different path and stopped somewhere new, which read as a new bug.
    Build the old code plus only the new draw and run both on the same seeds: if they match,
    the change is drift from the shifted sequence, not a fault; compare the kinds of outcome,
    not the seeds (see 97).

133. **Fix a chance flake by forcing the roll at the step, not by counting repeats.** A test
    failed now and then because a random roll under a chance changed the outcome, and "passed
    3 of 3 runs alone" proved nothing because the roll barely varied there. Force the roll at
    the step (set the seed or the value right before it) and show the test fails exactly when
    the roll is under the chance and passes otherwise; then make the test hold the roll it
    needs (see 93).

134. **A test that passes only because an earlier test reset the state hides an order bug.**
    A check passed in the full suite because a test before it emptied the shared state; run
    after a different test it failed, and alone it passed again. Run a new or suspect test
    alone and after the tests around it, and report a flake as "k fails in N runs" with N
    stated, never as "flaky" (see 133).
    In a scripted page or fixture, each check sets up its own preconditions (open the item it
    needs, pick the group, reset the filter) instead of relying on where the check before it
    left the page; otherwise a mutant that breaks one step turns a later, unrelated check red,
    and the red names the wrong check.

135. **Sort by the parsed value, never by the raw text.** A list stamped in two date formats
    was sorted as text, so newer items landed among older ones and the "latest" pick was
    wrong. Parse each key to its value (a time, a number) before sorting, and test the sort
    with mixed formats.

136. **A new colour key must stay distinct from every existing key after every transform the tool
    applies.** A key chosen distinct in its raw value collided with an old key once the tool's fade
    to black was applied, so two regions read as one. Check each new key against all existing keys
    at every stage that transforms colours (fades, tints, quantising), not only at the value
    written.

137. **Before calling a seeded number steady, vary every seed that feeds it and measure the
    spread.** A tolerance band was set on a number after varying one seed; a second group of seeds
    nobody varied moved it well outside the band. List every seed site that feeds the number, vary
    them all, and set any band from the measured spread; prefer an exact check on a path with no
    random draws to a "within N percent" check (see 72 and 132).
    The same holds for any noise source, not only seeds: a sweep of crops and thresholds on an
    all-or-nothing mask read zero spread because none of the variants could move the number. Include
    at least one variant that can move it, and report which variants did (see 69).

138. **A count that two branches each raise by one merges to a single raise, with no conflict.** Two
    branches each raised an expected-count line from N to N+1; the merge saw the same edit on both
    sides and kept one, so the expected count fell one short of the checks that now ran. Recount
    every such number after each merge or rebase that brings in another branch (see 16).

139. **After a change that rebuilds the nodes, look them up again; a held reference reads a
    detached copy.** A test kept a reference to a page element, then triggered a change that
    rebuilt the list. The reference now pointed at the old, detached node, whose state never
    changes, so the test passed whatever the live page showed. After any step that re-renders,
    query the live node again, and prove the test red with a mutant that breaks the live one.

140. **A region-average check cannot see a patch edge.** A patched region whose average matched
    its surroundings passed a check on mean colour and mean brightness while a hard seam ran
    along the patch's border. Also compare the jump across the patch edge with the jumps inside
    the region, and prove the check red on a planted patch with a hard edge (see 84 and 119).
    More generally, score a local defect on the worst small window, never on a mean over the whole
    object: a mark a few pixels wide averages away over a full figure. Slide a small window over
    the object, report the worst window's score against the bound, and prove it red on one planted
    small defect.
    Feathering a paste moves the jump inward, so a seam check that reads only the edge ring goes
    blind: measure the inner rings too, and plant the hard cut past the feather width (see 84).

141. **A stand-in for a platform API counts only after it is compared with the platform's own
    contract.** A test stub of a database's update call deep-merged nested objects, and checks
    built on it passed. Only reading the platform's type file confirmed that the real call merges
    the same way, and the same reading showed that the full-write call replaces the whole
    document, a hazard the stub never modelled. Before a check built on a stub or fake counts,
    compare the stand-in's behaviour with the platform's documented contract (docs or types), cite
    the line, and add one check for each behaviour the contract names that the stub does not.

142. **A reader rebuilding a list from a fresh data dump checks the seed's age first.** A verifier
    rebuilt an enumeration from a live dump and found an item the builder's checked-in seed lacked;
    the item had been added after the build, so the seed's own `--check` was stale, not wrong when
    written. Before scoring a mismatch as the builder's fault, compare the dump's newest item time
    with the seed's build time, and report an item newer than the build as seed drift, not a defect.

143. **Squash only onto the merge base; read the diff stat before any push.** After the main branch
    moved, a `git reset --soft origin/main` followed by one commit squashed a branch onto the new
    tip, and that commit silently reverted every newer commit on main, because the index still held
    the branch's older copies of those files. Squash onto `git merge-base HEAD origin/main` instead,
    and before any push read `git show --stat` of the commit for files the branch never touched; any
    such file is a revert in disguise (see 121).

144. **A tool that skips existing outputs turns a rerun into a no-op.** A job copied its old outputs
    aside before a rerun; the tool skipped every item whose output file still existed, so the rerun
    did nothing and the old outputs were read as new ones. Move old outputs away (never copy them)
    before rerunning a tool with a skip-if-exists rule, and treat a run whose start and end state
    match, with no resource peak, as a run that did nothing (see 69 and 79).

## Old numbers (before the 2026-10-26 renumber)

Lessons 61–151 were condensed to 61–144; older commits, boards and briefs cite the old numbers,
so read them through this table (a split lesson lists both parts).

| Old | New | Old | New | Old | New |
|---|---|---|---|---|---|
| 61 | 61 | 92 | 89 | 123 | 118 |
| 62 | 62 | 93 | 90 | 124 | 119 |
| 63 | 63 | 94 | 91 | 125 | 120 |
| 64 | 64 | 95 | 69 | 126 | 121 |
| 65 | 65 | 96 | 92 | 127 | 122 |
| 66 | 66 | 97 | 93 | 128 | 123 |
| 67 | 67 | 98 | 94 | 129 | 124 |
| 68 | 68 | 99 | 95 | 130 | 125 |
| 69 | 69 | 100 | 96 | 131 | 126 |
| 70 | 70 | 101 | 97 | 132 | 127 |
| 71 | 71 | 102 | 98 | 133 | 128 |
| 72 | 72 | 103 | 99 | 134 | 129 |
| 73 | 73 | 104 | 100 | 135 | 130 |
| 74 | 68 + 74 | 105 | 90 | 136 | 131 |
| 75 | 69 | 106 | 101 | 137 | 132 |
| 76 | 75 | 107 | 102 | 138 | 133 |
| 77 | 76 | 108 | 103 | 139 | 134 |
| 78 | 77 | 109 | 104 | 140 | 135 |
| 79 | 78 | 110 | 105 | 141 | 136 |
| 80 | 79 | 111 | 106 | 142 | 137 |
| 81 | 80 | 112 | 107 | 143 | 138 |
| 82 | 81 | 113 | 108 | 144 | 110 |
| 83 | 79 | 114 | 109 | 145 | 139 |
| 84 | 82 | 115 | 110 | 146 | 140 |
| 85 | 72 | 116 | 111 | 147 | 116 |
| 86 | 83 | 117 | 112 | 148 | 141 |
| 87 | 84 | 118 | 61 + 113 | 149 | 142 |
| 88 | 85 | 119 | 114 | 150 | 143 |
| 89 | 86 | 120 | 115 | 151 | 144 |
| 90 | 87 | 121 | 116 |  |  |
| 91 | 88 | 122 | 116 + 117 |  |  |
