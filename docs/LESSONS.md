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
   PRS (2026-10-26): A check fed by a file or tool can silently run on less or nothing (see 10):
   count each population, probe selections included (see 69), and tie each pass line to its
   checks.

10. **Read the REAL pass line, unpiped.** Pipes mask exit codes; a background-task
    completion notification masks a failing exit; a process can print its pass summary and
    then crash in teardown. Assert the literal "N passed / 0 failed" summary AND a clean
    exit, from output you captured yourself.
    *Provenance:* origin-project memories `feedback_pipe_masks_exit_code`,
    `feedback_background_test_notification_masks_exit`.
    PRS (2026-10-26): Score every falsify result and failure count from the full, untruncated
    log, never the gate's shortened output, because a red past the cut reads as a surviving
    mutant (see 9).

11. **Gate red ≠ code red.** Know the project's infra-flake modes (e.g. one test
    container per file saturating Docker) and encode the trusted gate + the never-run
    commands in `ORCHESTRATION.md`. An untrustworthy red wastes every session's time.

12. **Gate green ≠ boots.** Unit-green says nothing about schema/seed/boot integrity;
    migrations need a boot or constraint check in the gate for their change class.
    *Provenance:* origin-project memory `feedback_gate_green_but_boot_crashloops`.

13. **Re-verify subagent claims at reconcile.** "Pre-existing failure", "flake", and
    "done" are claims, not facts, until the reconciler re-runs the named suite in
    isolation and sees it with its own eyes.
    *Provenance:* origin-project memory `feedback_verify_subagent_failure_claims`.
    PRS (2026-10-26): Report only the failures a change adds over an untouched base, and blame a
    merge only when the failing output is not byte-identical on the merge and both parents.

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
    PRS (2026-10-26): In multi-worktree sessions run every git write as `git -C <worktree>`,
    since the shell's directory can reset to the shared checkout; reads may stay bare (see 2).

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
    PRS (2026-10-26): Quote every fill number and time stamp from the measuring script or
    `date -u` run in that same turn, never from memory; remembered figures drift.

38. **Measure the right object.** Identify a session from an authoritative id, never "most
    recently modified". Checking a property of the wrong object raises confidence, not accuracy.
    PRS (2026-10-26): For your own context fill, take your identity from your own listing or env
    block and measure that session's transcript, because the newest file in the folder may be a
    sibling's.

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
    *Provenance:* origin project — one row guarded 3 of 8 sites, another fixed 6 of 19 comments.
    PRS (2026-10-26): Test a scan's pattern on the real file before it builds the list; a
    verifier rebuilding from a fresh dump reports items newer than the seed's build as seed
    drift.

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
    PRS (2026-10-26): The same holds for entry paths: pin each way into a feature besides its
    top-level entry with a check that measures the change it should cause, not only that the
    page loads.

46. **A guard that compares NAMES cannot see TYPES.** An entire family of drift guards
    compared key sets; flipping a field's declared type in the *canonical schema* left the
    dedicated drift guard green at 47/47. The only backstop was the compiler, and only
    *incidentally* — one file built typed literals while its neighbor used a cast. Decide
    explicitly whether a guard covers types, and write down which backstop you are relying
    on. Relying on one without knowing it is the failure.
    PRS (2026-10-26): In a check or review, never accept a helper call on the strength of its
    name; open what it returns, by reading its body or calling it on a known case.

47. **A restore check must assert TWO things: tree clean AND the fix still present.** A
    mutation-restore run against a baseline that never carried the fix is a **delete**, not
    a restore — and it prints `nothing to commit, working tree clean` plus a GREEN gate on
    the *pre-fix* SHA. Clean status alone cannot distinguish restored from deleted. Always
    commit GREEN before mutating.
    PRS (2026-10-26): After undoing a planted bug, wipe the compiled cache, or the bug can still
    run; run gates with compiled-file writes off, so cache files never dirty the tree (see 63).

48. **A mutant that reds for the wrong reason is not evidence.** A "mutant" that *inserted*
    a duplicate step rather than *relocating* one produced a red — but proved only
    sensitivity to placement, not that the guard catches the reorder it was written for.
    Diff-verify every mutant; a red you wanted is the easiest thing in the world to accept.
    PRS (2026-10-26): A red counts only from a page this run built and from the check predicted
    in writing beforehand, and a mutant's diff must remove or change the guarded line.

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
    PRS (2026-10-26): A pin that only prints a value the builder claims is the same over-claim:
    mutate the claim away and predict green, and a mutant that survives is the finding.

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
    PRS (2026-10-26): A number in a code comment carries no commit; before offering one for a
    decision, re-run the measurement on the current base and quote the commit SHA beside each
    number.

59. **Fail-open vs fail-closed is the load-bearing property of any client-side guard.** A
    disable derived from data that may not have loaded must degrade to *enabled* — the
    server's refusal is the real guard. A false disable silently denies a legitimate action
    with no error and no recourse, which is far worse than the dead click it replaced.

60. **A guard that cries wolf gets deleted.** Measure a marker/heuristic set against the real
    corpus before shipping it: a first-choice marker matched three files, two of which were
    unrelated. Precision is what keeps a guard alive long enough to catch anything.
    PRS (2026-10-26): The other side is recall: a parser of hand-written markers must accept
    every form the source uses, and an overflow walk must skip hidden content (the opposite
    trap, a missed overflow, is 74).

## Guards, gate logs and worktree git (harvest 2026-10-15)

*One orchestrated day of tool-building rows, each read by a sibling verifier. Every lesson below
came from a verifier finding or a falsify run that went red where the builder expected green.*

61. **A guard that scans state must run before any step that erases what it scans, or read that
    step's record of what it erased.** A guard placed after the erasing step can never fire and
    prints green on every input; prove it red by mutating the writer of its input, not only the
    guard.
    PRS (2026-10-26): A guard's count holds only for the stage it ran at, so run it again after
    the last step that moves its input (see 87).

62. **A measuring guard draws its measured landmarks on the output it judges.** A sample too
    sparse to land on the feature can still give a plausible number and a clean log; a
    measurement nobody can see is a measurement nobody can check.

63. **Write the gate log's SHA line after the gate slot is acquired; commit first, and never
    edit the tree while a gate waits unless it runs from a snapshot.** The queue tests the tree as it is when the slot frees,
    so a header written earlier can vouch for code that was never tested. Extends 32.

64. Retired, see 30.

65. **Falsify a path or name filter with its escape variants, and prove each layer bites on its
    own.** A filter can check only the first path segment and let a `..` path through, and a
    layered guard whose inner layer never fires alone is one guard, not two.

66. **A check through a clamped accessor can never fail: compare the underlying value.** A
    getter that caps its result reads exactly the cap on every overflow, so a "does not exceed
    the max" test through it passes on what it should catch.

67. **A probe number that feeds a human ruling is cross-checked by a second path first.**
    Reproduce it another way (a fixture built by the real code path, or a real run) and say both
    agree; a wrong number shapes a ruling that must then be re-asked.

68. Retired, see 74.

69. **An input mutant proves it changed the measured feature before its PASS or FAIL counts.** A
    mutation that moved nothing makes a pass look like proof and a fail look like a hole, so log
    the measured value before and after it, next to the verdict (see 21 and 48 for code
    mutants).

70. Retired, see 48.

71. **"Old data" fixtures are built by the OLD code, in its own worktree.** Fixtures written by
    the new code in "old mode" carry its assumptions, and can pass a migration that real old
    saves would break.

72. **A claim of "within plus or minus N percent" is checked per row, not on the total.** A
    total within tolerance proves only that the errors cancel, so report the change for each
    source and apply the tolerance to each row.

73. **Test a lock's atomicity on the filesystem where the real lock lives.** Exclusive create
    can behave differently on a network-style mount than on local disk, so a race run only on
    local disk says nothing about the mount.

74. **A measuring guard must not let the measured object choose its own landmarks.** Landmarks a
    heuristic finds move with the input they judge, so pin them to something the input cannot
    reshape and fail closed when they are missing (see 62).
    PRS (2026-10-26): A guard whose limits are fractions of a total takes that total only from
    parts the input cannot extend, or refuses an input whose reference parts are unexpected.

75. Retired, see 48.

76. **After a scripted marker-to-marker cut, grep for the lines it removed.** The range can
    swallow lines meant to stay, and nothing fails until much later; check each removed line was
    meant to go before the next step builds on the file.

77. Retired, see 38.

78. **A lock helper's release removes only the exact line it wrote, and its default owner is
    unique per run.** Fixed default names let two unnamed runs each believe they hold the lock,
    and a release that skips comparing the owner line can free a lock another run has taken
    since (see 73).

79. Retired, see 37.

80. **Parity with the old version is proved on the whole report, not on the numbers you
    picked.** Per-number checks can all pass while rules behave differently: diff the new full
    output against the old, then make the diff fail on purpose (see 40 and 72).
    PRS (2026-10-26): After moving a threshold or scale, probe every input that feeds a rule on
    both versions, reading raw values, never through a clamped accessor (see 66).

81. Retired, see 80.

82. **Never chain a commit after a gate with `;`.** The commit then runs even when the gate
    fails, and the log shows a green-looking commit on red code. Join them with `&&`, or read
    the pass line and commit in a separate step (see 63).

83. Retired, see 80.

84. **A test that takes its expected value from the constant it guards cannot fail on that
    constant.** Change the constant and the expectation moves with it, so the check stays green;
    write the ruled value into the test itself (see 48).

85. Retired, see 80.

86. **"Every item is covered" comes from a script over the list, never from memory.** Memory
    misses items; loop over the list's real source, print each item with where it is covered,
    and quote that output with its count.

87. **When a repair pass runs before a check, report the check's count before the repair too.**
    A local cleanup can turn a defect into one the metric no longer measures while the gate
    reads green; a large drop is a finding, not a pass (see 62).

88. **After a machine crash, audit before assigning any work.** A crash can leave unpushed
    branches, uncommitted files, lost gate logs and locks naming dead sessions, so every sibling
    waits until the audit is done.

89. **Relay only a settled human ruling to a builder.** Forwarding each step of the human's
    thinking sends the builder a string of specs, each superseding the last; collect the whole
    answer and confirm it is final first.

90. **A visual check done on thumbnails is not a check; give each property its own measured
    check.** An image can look right at thumbnail size and be wrong at full size, and a metric
    for one property passes errors in another.

91. **Prove a new check red on the artifact the human actually rejected, not only on a made-up
    broken case.** An invented case can fail in a way the real one does not; a check that stays
    green on the rejected artifact does not guard that complaint (see 69 and 48).

92. **When inheriting a row, list its scratch files by modification time against the branch
    tip.** A session that ended abruptly can leave unlogged attempts newer than the last commit;
    read, log or discard each one on purpose (see 88).

93. Retired, see 105.

94. **Before proposing how to satisfy a refusing check, trace where the check takes its input.**
    The check may read a live, derived value rather than the stored field, so an edit to the
    input you assumed changes nothing (see 67).

95. Retired, see 9.

96. **A gap you have not isolated is "not explained", never "noise"; a quantity is "display
    only" only after every consumer is traced.** A gap written off as noise hides its cause, and
    a display-only value can feed a rule two calls away (see 72 and 80).

97. **A failure that depends on the path cannot be bisected by one run per commit.** When it
    shows only on some routes, a good run proves nothing: reproduce the fact the crash frame
    names in a minimal script, and prove the fix with a check that can fail (see 48).

98. **A liveness guard compares to the thing it guards; pasted for another kind of object it
    silently aborts.** It then fails every time and quietly stops a scripted run while the lint
    and smoke tests stay green; prove it red by pasting it onto the other kind (see 48 and 97).

99. **A refit that wins back broken bars can quietly move the bars it does not score.** Put
    every bar that must hold into the refit's cost, not only the ones that failed, and report
    all bars before and after (see 62 and 94).

100. **Before wiring an effect to an event, prove the event can fire where the effect lives.**
    If the event never runs there, the hook is dead code that only a probe can reach; show it
    firing from the real path, not the probe (see 105).

101. **Prove a cause by pinning one path at a time, and measure options as patch scripts on the
    probe's temp copy.** Changing several causes together leaves a better result unattributable,
    and editing the product to try options leaves changes to revert (see 96). A scalar meter can
    move with each fix while the defect stays (see 90). PRS (2026-10-26): When a new random draw
    shifts a seeded run, compare the old code plus only that draw on the same seeds before
    calling it a fault.

102. Retired, see 10.

103. **Size a parallel fan-out by free memory, not by cores.** A fan-out sized by core count can
    start many heavy processes at once and run the machine out of memory; start each heavy
    process only when enough memory is free (see 88).

104. **Stopping a background shell task leaves its child processes running: stop each heavy run
    by the process id recorded at launch.** A leftover child keeps holding memory and locks, and
    a stop by name match can kill your own shell or another session's run.

105. **A READ of a factor in a shared function lists every caller.** A caller may apply the
    factor again or skip it, so grep every caller, quote the list, and state for each whether it
    applies the factor itself.
    PRS (2026-10-26): A test drives each call site or checks its exact call text, because a
    helper can be right while a caller applies its factor again.

106. **After every delivery, assert the delivered file's md5 against its source.** An older or
    partial copy left at the destination can be used as if it were the source, so compare in the
    same command that delivers it and fail the step on a mismatch.

107. **Before a long optimization against extrapolated targets, check the targets can be met
    together.** Targets each extrapolated on its own can drift apart until no solution meets
    them all, and the run stalls for hours (see 99).

108. **Run a long background chain as one script, memory-gated per step, with a status file per
    step.** Separate commands can be reaped partway with nothing to show which step finished;
    per-step status shows exactly where the chain stopped, so it can resume there (see 103 and
    104).

109. Retired, see the falsify skill (its "Discriminating mutant" step).

110. **Falsify a check in the mode the real gate runs it.** A check with a quick and a strict
    mode may be unable to fail in its default one, so use the gate's own flags, environment and
    mode, and make the gate name that mode.

111. **A stamp that records how something was made counts only if something reads it and stops
    on a mismatch.** A stamp nothing compares with the live settings can never catch a mismatch;
    prove its reader red by changing one setting (see 80).

112. **Before pinning an anchor per frame to a measured extreme, measure the motion the pin
    adds.** Each frame's extreme moves with the content, so the pinned result can bounce more
    than the source drifts (see 90).

113. **Measure a "missing" step's output at every later stage before rewriting it.** A step that
    looks idle may be firing but under-correcting while later stages widen the gap; fix the
    stage where the gap appears, not the one that looks idle.

114. **After a batch fix, a mask-only composite plus an md5 count proves the fix touched only
    what it should.** Re-running the whole pipeline changes pixels outside the fixed area; the
    count of changed outputs must equal the number meant to change (see 80).

115. Retired, see 144.

116. **Judge a guide on every view before spending a long job on it.** A guide right from one
    view can be wrong from another, and the fault shows only after the slow job has run
    (see 107).

117. **A pick-by-eye sheet shows the candidate between fixed anchors, at one scale, on one
    baseline.** Candidates at different sizes and baselines, with numbers on the picture, cannot
    be told apart by eye.

118. Retired, see 61.

119. **When the look is the requirement, a headless check of the model is not the check; read
    the drawn pixels and add a mutant only the pixel read can kill.** The model can hold the
    right numbers while the drawn result is wrong, and a pin beside the draw call cannot see the
    effect (see 84 and 100).

120. **A probe run that dies part-way gives no results: rerun the whole set.** If a cut-off
    run's numbers count, partial results pass as findings; quote only from a complete run (see
    9).

121. **A metric that ranks things must be run on the reference pair it is meant to rank, and on
    wrong references.** A broken meter can rank candidates against what a person sees; if every
    right pair does not beat every wrong pair, fix or drop it (see 69). PRS (2026-10-26): A
    camera check must fail shifted copies of a good picture and pass the reference itself
    (see 91 and 124).

122. **Before a ladder of edits, test the largest step on the hardest case; calibrate an edit
    check with a null edit and a mutant.** A method's size ceiling only shows on its largest
    step, and an uncalibrated check's fail may be its own quantisation floor (see 74).

123. **A shape gate on an edited outline is relative to the original over the same rows, checked
    at several scales, and reported as a pass fraction.** Absolute bars flag the figure's own
    bends, one scale misses flat-bottomed defects, and a bar at the noise floor passes only in
    pockets of the parameter grid (see 110).

124. **A validator needs a pin that feeds it a planted fault.** A validator run only on clean
    real data has branches nobody has proved: plant a bad copy for each branch and require a
    refusal (see 98). When the fault drops a record, predict one fault per reference to it; a
    different count is a finding (see 48).

125. Retired, see 9.

126. **Rebase only before the first push; after it, cherry-pick onto the pushed tip and
    re-gate.** A rebase after a push forces a force-push or leaves two histories (see 88).

127. **Compensating a non-deterministic generator's drift needs two rounds that agree first.**
    The drift differs each run, so a one-shot compensation can over-correct; compensate only
    when two independent rounds agree, and once at most.

128. **A design row's seam table includes the owner's earlier rulings on the topic, built or
    not.** A proposal that ignores an unbuilt ruling reopens a settled question, so grep the
    decisions file for the topic before proposing.

129. **Parallel builders in one worktree: exclusive file lists, shared hooks committed first,
    one locked test runner; silent side effects and singletons get their own checks.** A claim
    kept true by a silent side effect needs its own assert and a mutant that removes the effect.

130. **Flip a policy constant once before calling a change green.** The pins that go red are
    tied to the value rather than to the rule; rewrite each relative to the constant, or name it
    as bound.

131. **A steadiness check measures at one fixed scale per route.** A pipeline that normalises
    each frame (to the same height, say) hides exactly the drift a size or steadiness check is
    looking for (see 112).

132. **A two-sided bound needs a mutant per side.** One side can survive a mutant while the
    other side holds the check red, so falsify each side separately and report both results
    (see 48).

133. **An automated quick reply to a person can invent facts or promise work nobody started;
    correct it in the full answer and never build on it.** Build only on what the person
    actually said, not on what the quick reply claimed.

134. **While the base model is not agreed, send one proposal, not a fan-out of questions.**
    Detailed questions ask the person to rule on parts of something that may change; open them
    after the base is agreed, one per real fork.

135. **Every async UI action gets one check with a deliberately late stub.** A stub that
    resolves at once hides in-flight races, such as a redraw that re-arms a button while a save
    is still pending.

136. **Before a long redo round, put today's result beside the owner's own reference.** A
    summary of what someone wants can carry the wrong detail, and the whole round then chases it
    (see 107 and 116).

137. Retired, see 101.

138. **Fix a chance flake by forcing the roll at the step, not by counting repeats.** A streak
    of passes proves nothing when the roll barely varies across runs; show the test fails
    exactly when the roll is under the chance (see 97).

139. **A test that passes only because an earlier test reset the state hides an order bug.** Run
    after a different test, it fails; run a new or suspect test alone and after its neighbours,
    and report a flake as "k fails in N runs", never as "flaky" (see 138).

140. **Sort by the parsed value, never by the raw text.** Sorting keys in mixed formats as text
    puts newer items among older ones, so a "latest" pick is wrong.

141. **A new colour key must stay distinct from every existing key after every transform the
    tool applies.** Keys distinct in their raw values can collide after a fade, tint or
    quantise, so two regions read as one.

142. **Before calling a seeded number steady, vary every seed that feeds it and measure the
    spread.** A seed group nobody varied can move the number well outside a band set from one
    seed; set any band from the measured spread (see 72 and 101). Variants that cannot move the
    number read zero spread, so include one that can (see 69).

143. **After each merge or rebase that brings in another branch, recount any count both branches
    raised by one.** The merge sees the same edit on both sides and keeps one, with no conflict,
    so the expected count falls one short of the checks that run (see 16).

144. **A mutant that stays green means a second path recovers: find it before calling the check
    weak.** Mutate both paths together to see the red; the check proves that at least one path
    works, not that the mutated one does (see 51). PRS (2026-10-26): When two fixes cover for
    each other, switch them off in steps from one saved state and score each step from its own
    result.

145. **After a change that rebuilds the nodes, look them up again; a held reference reads a
    detached copy.** The detached node never changes, so a test holding it passes whatever the
    live page shows.

146. **A region-average check cannot see a patch edge.** A patch whose average matches its
    surroundings passes a mean check while a hard seam runs along its border; compare the jump
    across the edge with jumps inside, and prove it red on a planted hard edge (see 87 and 124).
    Feathering moves the jump inward, so measure the inner rings too (see 87).

147. Retired, see 121.

148. **A stand-in for a platform API counts only after it is compared with the platform's own
    contract.** A stub can match the real call in one behaviour and miss another (a full-write
    call that replaces the whole document); cite the contract line it was checked against.

149. Retired, see 42.

150. **Squash only onto the merge base; read the diff stat before any push.** After main moves,
    a soft reset to `origin/main` plus one commit silently reverts every newer commit on main; a
    file in the stat that the branch never touched is a revert in disguise (see 126).

151. **A tool that skips existing outputs turns a rerun into a no-op.** Move old outputs away
    (never copy them) before rerunning, or they are read as new; a run whose start and end state
    match, with no resource peak, did nothing (see 69 and 80).
