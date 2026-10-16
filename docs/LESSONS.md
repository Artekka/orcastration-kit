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
    *Provenance:* origin-project memory `feedback_verify_subagent_failure_claims`.

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

46. **A guard that compares NAMES cannot see TYPES.** An entire family of drift guards
    compared key sets; flipping a field's declared type in the *canonical schema* left the
    dedicated drift guard green at 47/47. The only backstop was the compiler, and only
    *incidentally* — one file built typed literals while its neighbor used a cast. Decide
    explicitly whether a guard covers types, and write down which backstop you are relying
    on. Relying on one without knowing it is the failure.

47. **A restore check must assert TWO things: tree clean AND the fix still present.** A
    mutation-restore run against a baseline that never carried the fix is a **delete**, not
    a restore — and it prints `nothing to commit, working tree clean` plus a GREEN gate on
    the *pre-fix* SHA. Clean status alone cannot distinguish restored from deleted. Always
    commit GREEN before mutating.

48. **A mutant that reds for the wrong reason is not evidence.** A "mutant" that *inserted*
    a duplicate step rather than *relocating* one produced a red — but proved only
    sensitivity to placement, not that the guard catches the reorder it was written for.
    Diff-verify every mutant; a red you wanted is the easiest thing in the world to accept.

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

59. **Fail-open vs fail-closed is the load-bearing property of any client-side guard.** A
    disable derived from data that may not have loaded must degrade to *enabled* — the
    server's refusal is the real guard. A false disable silently denies a legitimate action
    with no error and no recourse, which is far worse than the dead click it replaced.

60. **A guard that cries wolf gets deleted.** Measure a marker/heuristic set against the real
    corpus before shipping it: a first-choice marker matched three files, two of which were
    unrelated. Precision is what keeps a guard alive long enough to catch anything.

## Guards, gate logs and worktree git (harvest 2026-10-15)

*One orchestrated day of tool-building rows, each read by a sibling verifier. Every lesson below
came from a verifier finding or a falsify run that went red where the builder expected green.*

61. **A guard that scans state must run before any step that erases what it scans** — or that
    step must record what it erased, and the guard reads the record. A guard scanning a mesh's
    shape keys for forbidden names ran after a bake step that deletes shape keys, so it could
    never fire; it printed green on every input. Only mutating the *writer* (feeding it a
    forbidden key) showed it. Order the pipeline so the scan sees the input, and prove each guard
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

68. **A guard measured in fractions of a total takes the total only from parts that cannot be
    stretched.** A shape guard expressed its limits as fractions of the model's overall height,
    read from the lowest to the highest point. An added base part lowered the lowest point by a few
    centimetres, which grew the "height" and shrank every ratio under its limit, so a model the
    guard should refuse passed. Take the reference length from parts the input cannot extend (named
    anchors, a fixed skeleton), or refuse any input whose reference parts are not the expected ones.

69. **An input mutant proves it changed the measured feature before its PASS or FAIL counts.** A
    falsify run fed a deliberately bad input to a guard and the guard passed it, which looked
    like a hole; another run "passed" correctly, which looked like proof. In both, the mutation
    had not changed the feature the guard measures. Log the measured value before and after the
    mutation next to the verdict: a mutant that moved nothing is no evidence either way (see 21
    and 48 for code mutants).
    The same holds for a probe: before trusting a probe's number, or a mutant's verdict, show
    that it moves the quantity the check reads. A probe that changes a neighbouring value
    reports nothing about the one under test.


70. **For a code mutant, predict the exact failure message it should cause, not just red or
    green.** A mutant that removes one check can turn the run red through a different check that
    happens to fire too, and a bare "went red" accepts that as proof. Write down which named
    check should fail and with what message, then compare. A red that arrives through another
    check, or a check whose flip is hidden behind an earlier failure, is reported as an unclean
    falsify, not a pass.

71. **"Old data" fixtures are built by the OLD code, in its own worktree.** A migration test
    loads saved data from before a format change. Fixtures written by the new code in "old
    mode" carry the new code's assumptions and can pass a migration that real old saves would
    break. Check out the commit before the change in a separate worktree, produce the fixtures
    there, record that commit in the fixture's header, and only then test the new code on them.

72. **A claim of "within plus or minus N percent" is checked per row, not on the total.** A
    re-tune reported every total within -4 to +2 percent of the old numbers; one of the sources
    feeding a total had moved +60 percent, cancelled out by others. Report the change for each
    source separately and apply the tolerance to each row; a total within tolerance proves only
    that the errors cancel.

73. **Test a lock's atomicity on the filesystem where the real lock lives.** A race test for a
    create-if-absent lock ran in a local temp folder and passed; the real lock file sits on a
    network-style mount (a 9p or SMB share), where exclusive create can behave differently. Run
    the race, and its falsify, with the temp folder on that same mount, and use a temp path with
    the same shape as the real one (spaces included): a test that only ever ran on local disk
    says nothing about the mount, and a path without spaces hides quoting bugs in the test
    itself.

74. **A measuring guard must not let the measured object choose its own landmarks.** A guard
    that found its reference points by a heuristic (the largest step in a profile, the widest
    slice) could be steered by the mesh it judged: a small shape change moved the "largest step"
    to a different place, and the measurement followed it. Pin landmarks to something the input
    cannot reshape (a skeleton's joints, a certified reference basis), and fail closed when they
    are missing (see 62: draw them on the output too).

75. **A falsify mutant removes or replaces the guarded line; a diff that only adds lines is a
    no-op.** A mutant meant to disable a check added a line beside it and left the check itself
    in place, so the guard still ran and the "mutant" proved nothing. Before running a mutant,
    read its diff: it must show the guarded line as removed (`-`) or changed. A diff with only
    `+` lines does not disable anything (see 48 and 70).

76. **After a scripted marker-to-marker cut, grep for the lines it removed.** A script that
    deleted everything between two markers also swallowed three settings that sat inside the
    range; nothing failed until a probe run showed the settings missing. After any cut by
    pattern or marker, list the removed lines (`git diff | grep '^-'`) and check each one was
    meant to go, before the next step builds on the file.

77. **A context-fill measure reads YOUR transcript, picked by your own session id, never the
    newest file.** The script measures whichever transcript it is given. A fresh session that
    took the newest transcript in the folder measured a sibling's 173K as its own. Take your
    identity from your own listing (the agent listing's first line, or your env block), find
    the transcript that belongs to it, and measure that one.

78. **A lock helper's release removes only the exact line it wrote, and its default owner is
    unique per run.** A release that deleted the lock without comparing owners could free a
    lock another run had taken since; fixed default owner names let two unnamed runs each
    believe they held it. Write an owner unique to the run (tool, host and process id) unless
    the caller names one, and on release or trap compare the whole owner line before removing
    anything. Never use a real session's name as the default (see 73).

79. **Quote context fill from the measuring script's output, never from memory.** A verifier
    reported about 175K in a status line while its real fill was 300K, past the report mark,
    and kept working. Every fill number in a READY, report or handover is the script's
    `current` line pasted from a run made in that same turn.

80. **Parity with the old version is proved on the whole report, not on the numbers you picked.**
    A change meant to leave the results as they were passed every per-number check, and a
    reviewer still found rules that behaved differently. When the goal is "same as before", write
    the old code's full output once (a report, a probe of every rule) and `diff` the new one
    against it; zero lines of difference is the proof. Then make the diff fail on purpose (a
    mutant) so the comparison is known to see a change (see 40 and 72).

81. **After moving a threshold or a scale, sweep every run-time input the rules read, not only
    the default.** A rescale matched the old results with the default inputs and diverged once a
    state value the player controls (a fill level, a count, a carried amount) was at half or
    full: some rules still read a value that included that input on the new scale. List each
    input that feeds a rule, probe at its empty, middle and full values on both versions, and
    compare per rule (see 66: never read through a clamped accessor).
    A scenario that holds two inputs equal cannot tell them apart: when two readings of a rule
    differ only where two inputs differ (one counts a value once, the other twice), vary the
    input that separates the readings, or both readings pass on the pinned case.


82. **Never chain a commit after a gate with `;`.** `run-gate; git commit ...` commits even when
    the gate fails, and the log then shows a green-looking commit on red code. Join them with
    `&&`, or run the gate, read its pass line, and commit in a separate step (see 63).

83. **A byte-identical before/after comparison counts only after a mutant shows it can differ.**
    "The report is identical" proves nothing if the comparison never reads the part that changed
    (the wrong file, a cached copy, a section the generator skips). Before quoting a zero-line
    diff as proof, change one input that must move the output, rerun, and see the diff go
    non-empty (see 80).

84. **A test that takes its expected value from the constant it guards cannot fail on that
    constant.** A check computed "what should happen" from the same setting the code used, so
    setting it to zero moved the code and the expectation together and the check stayed green.
    Write the ruled value into the test itself. To falsify, mutate the constant AND, separately,
    delete the call it drives; both must turn the check red (see 70 and 75).
    The same goes for an oracle that calls the function it checks: its expected value changes
    with any change to that function, so it passes every change. Take the expected value from
    the ruling or from a value written down before the change, never from the code under test.


85. **For a parity review, run one probe script unchanged on the base and on the tip, and diff
    per action and per input level, never per total.** Two probes written for each side, or a
    probe that sums its results, let opposite differences cancel and let each side measure
    something slightly different. Keep the probe free of calls that exist on only one side (or
    pick the call at run time), print one line per action at each input level (empty, half,
    full), and diff the two outputs line by line.

86. **"Every item is covered" comes from a script over the list, never from memory.** A write-back
    reported that every item on a list was ruled, tested and migrated; a script over the same list
    then found one item missed and one never ruled. Before claiming full coverage, loop over the
    list's real source (the file, the table, the grep) and print each item with where it is
    covered; quote that output, including its count.
    A test that trusts the data's own tags cannot catch a mis-tagged entry: rebuild the
    population from the file itself (the real column, the real text) instead of from a tag the
    entry carries, then compare the two counts.


87. **When a repair pass runs before a check, report the check's count before the repair too.** A
    local cleanup (a relax, a smooth, an auto-fix) ran before a metric and turned its red into a
    visible artifact the metric no longer measured (folds became wrinkles) while the gate read
    green. Print the metric before and after the repair; a large drop is a finding to look at,
    not a pass (see 62: measure on the output).
    The same blindness hides in the check's zone: a check whose zone sits inside the zone a fix
    just cleaned passes by construction. Report a wider, independent read of the same output
    next to it, and keep the human-eye check as the evidence.

88. **After a machine crash, audit before assigning any work.** A crash left a rebased branch
    unpushed in one worktree, shared memory files uncommitted, gate logs gone with the temp
    folder, and a lock naming a dead session. Before any sibling gets work: check every worktree
    for dirty files and unpushed commits (push a rebase under a new branch name, never a
    force-push), commit shared memory left behind, treat every gate log under a temp folder as
    lost and re-run those gates, check each lock against a live owner, and hold the siblings
    until the audit is done.

89. **Relay only a settled human ruling to a builder.** The seat forwarded each step of the
    human's thinking as it came in, and one builder got five specs in fifteen minutes, each
    superseding the last. Collect the whole answer first, ask "is that final?", then send the
    builder one spec.

90. **A visual check done on thumbnails is not a check; give each property its own measured
    check.** A review passed images that looked right at contact-sheet size, and a line-style
    metric passed a view that was turned 15–20° from the one asked for. Measure at full
    resolution with a number, and check each property separately (style is not geometry: the
    angle, the outline and the proportions each get their own metric).

91. **Prove a new check red on the artifact the human actually rejected, not only on a made-up
    broken case.** A check passed a hand-built bad example and still passed the very output a
    reviewer had refused, because the invented case failed in a way the real one did not. Run
    the check on the rejected artifact itself (the picture, the file, the saved run) before
    calling it a guard for that complaint; if it stays green there, it does not guard it (see
    69 and 75).
    Before building a check for a reviewer's complaint, measure what actually differs between the
    rejected output and an accepted one: a "slimmer" complaint was a thicker waist, not narrower
    hips, and the planned hip check would have passed the rejected image.

92. **When inheriting a row, list its scratch files by modification time against the branch tip.**
    A builder took over a row from a session that ended abruptly; its scratch folder held
    attempts newer than the last commit, never logged, one of them the working version of a
    step the branch still lacked. Before starting, list the row's scratch and output files
    sorted by time next to the tip's commit time: any file newer than the tip is an unlogged
    attempt, to be read, logged or discarded on purpose (see 88).

93. **A check that never runs the call site cannot see a site that applies a factor twice.**
    A test checked a helper's result and the helper was right, while one caller multiplied the
    result by the same factor again; the total was off by that factor and every check stayed
    green. Either drive the call site itself, or check the exact call text (grep the line,
    count the factor's occurrences per site), and falsify by doubling the factor at one site.
    Next to a per-site check, also assert the exact total number of call sites, so a site added
    elsewhere cannot go unchecked, and falsify by adding one extra call in another function.

94. **Before proposing how to satisfy a refusing check, trace where the check takes its input.**
    A guard refused an object and the first fix proposed edited the stored data it was assumed to
    read; the guard actually read a live, derived value (an evaluated result, not the stored
    field), so the edit changed nothing. Read the check's own code to the point where its input
    enters, name that input, and only then propose a change to it (see 67).

95. **A probe or mutant whose selection is empty passes vacuously: make it abort on an empty
    pick.** A mutant that was meant to alter "every item matching X" matched none, changed
    nothing, and the check stayed green, which read as a guard that held. Count what the
    selection picked and abort with a message when the count is zero; report the count next to
    the verdict (see 69).

96. **A gap you have not isolated is "not explained", never "noise"; a quantity is "display
    only" only after every consumer is traced.** A small unexplained difference between two runs
    was written off as noise, and a value labelled display-only fed a rule two calls away.
    Write "not explained" until the gap has been reproduced and attributed to a named cause; call
    a value display-only only after listing every reader of it (grep each consumer, quote the
    list) (see 72 and 81).

97. **A failure that depends on the path cannot be bisected by one run per commit.** A crash
    appeared only on some routes through a long scenario, so a good run on a commit proved
    nothing and a bisect pointed at three different commits. Read the crash frame, reproduce the
    engine fact it names in a minimal script, and prove the fix with a check that can fail (a
    mutant that restores the bug turns it red), not with a green run of the long scenario (see 70
    and 75).

98. **A liveness guard compares to the thing it guards; pasted for another kind of object it
    silently aborts.** A guard written for one kind of node (a level) was copied to guard a
    different kind (a child overlay that is never the level), so the guard failed every time
    and the scripted run quietly stopped; the lint and the smoke test stayed green and only
    the full playthrough saw it. For each guard site, say what object it guards and which
    object the guard compares against, and plant a case per kind (no guard, wrong guard, right
    guard) in the lint; falsify by pasting the guard onto the other kind and checking it goes
    red (see 70 and 97). A guard counts only where it controls the use: plant cases where the
    guard is nested away from the use, is a no-op (`if G: pass`) or is joined by `and not G`,
    and require the lint to flag each.

99. **A refit that wins back broken bars can quietly move the bars it does not score.** A
    geometry refit repaired the failing measurements while a neighbouring measurement it never
    scored drifted past its limit (a notch went from −1.4 to −1.8 mm). Put every bar that
    must hold into the refit's cost, not only the ones that failed, and report all bars
    before and after the refit (see 62 and 94).

100. **Before wiring an effect to an event, prove the event can fire where the effect lives.**
    An effect was hooked to a clock tick that does not run on the screen the effect belongs
    to, so the hook was dead code that only a probe could reach. Name the event, name the
    screen or state the effect lives in, and show a run in which the event fires there (a
    log line from the real path, not from the probe) before building on it (see 93).

101. **Prove a cause by pinning one path at a time, and measure options as patch scripts on the
    probe's temp copy.** Several candidate causes were changed together, so a better result
    could not be attributed; and trying options by editing the game left changes to be
    reverted. Pin or remove one path per run and record which pin moved the number; apply each
    option as a patch script to a temporary copy of the tree, so a proposal milestone commits
    no game change (see 96).

102. **A gate that truncates error output can hide the reds a mutant should cause.** A falsify
    run was scored from a gate's shortened output (the first lines of the failure), and a
    mutant that did turn a guard red looked as if it survived because its message fell past the
    cut. Score every falsify result from the untruncated log (the full output file, not the
    gate's summary), and quote the count of red lines found there (see 95).

103. **Size a parallel fan-out by free memory, not by cores.** A fan-out was sized by the
    processor count, started many heavy processes at once and ran the machine out of memory
    close to a crash. Start at most two heavy processes, and start each only when the free
    memory reported by the system is at least 3 GB; wait otherwise (see 88).

104. **Stopping a background shell task leaves its child processes running.** A task was
    stopped and the engine process it had started kept running, holding memory and a lock.
    Record each heavy run's process id at launch (a file next to its log) and stop it by that
    exact id; never by a name match, which can also kill your own shell or another session's
    run.

105. **A READ of a factor in a shared function lists every caller.** A review confirmed a
    factor was applied correctly in the function that owns it, without listing who calls the
    function, and one caller applied the same factor again or skipped it. Grep every caller,
    quote the list, and state for each whether it applies the factor itself (see 93).

106. **After every delivery, assert the delivered file's md5 against its source.** A file was
    copied to its destination and used on the belief that the copy was the source; an older or
    partial copy had been left there. Compare the md5 of the delivered file with the source's
    in the same command that delivers it, and fail the step when they differ.
