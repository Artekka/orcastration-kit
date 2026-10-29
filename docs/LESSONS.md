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
   PRS (2026-10-26): A check fed by a file or a machine tool can run on less, or on nothing,
   without saying so: a shell `while read` loop drops a last line with no newline (`|| [ -n
   "$line" ]` keeps it), an unreadable file is skipped silently (test `-r` first), and a line that
   matches no expected form is ignored unless the loop rejects it. A test that cannot run on this
   machine (a missing tool or browser) fails in the gate's own result line, never drops its pages
   or passes with zero checks; the number of pages built is part of the population the count
   asserts. The runner may hide build output, so a missing input must show in the result itself
   (see 10). A probe's or mutant's selection is a population too: count what it picked,
   abort with a message when the count is zero, and report the count next to the verdict (see 69).
   Make each pass line depend on the failure count of its own checks, and when adding a pin, count
   the unconditional ok prints; an unconditional pass line stays green when its checks fail. A
   span with no check of its own prints "ok" only for "no error was logged": say so, and back it
   with a logger that counts errors only (see 10).

10. **Read the REAL pass line, unpiped.** Pipes mask exit codes; a background-task
    completion notification masks a failing exit; a process can print its pass summary and
    then crash in teardown. Assert the literal "N passed / 0 failed" summary AND a clean
    exit, from output you captured yourself.
    *Provenance:* origin-project memories `feedback_pipe_masks_exit_code`,
    `feedback_background_test_notification_masks_exit`.
    PRS (2026-10-26): Score every falsify result and failure count from the full, untruncated
    log, never from the gate's shortened output or a cut-down list, and quote the count of red
    lines found there; a red past the cut reads as a surviving mutant (see 9). When a wrapper
    deletes its log on failure, run each mutant through the wrapper (for the exit status) and
    through a runner that keeps the log (for the lines), timed-out case included. A timeout on a
    shared gate slot means load, not a failure: rerun with a longer limit before scoring it.

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
    PRS (2026-10-26): For a check that runs outside the main test, run it on an untouched copy
    of the base too and report only the failures the change adds; a failure the base also shows
    is not the change's. Before blaming a failure outside the change on a merge, compare (`cmp`)
    the failing check's built output on the merged tree and on both parents: if it is
    byte-identical on all three, the merge did not cause it.

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
    PRS (2026-10-26): In multi-worktree sessions run every git write as `git -C <worktree>`: the
    shell's working directory can reset to the shared checkout, so a bare `commit`, `checkout`
    or `merge` lands in the shared tree. Reads may stay bare (see 2).

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
    PRS (2026-10-26): Quote every fill number in a READY, report or handover from the measuring
    script's `current` line, run in that same turn, never from memory; take a time stamp on a
    board, log or handover from `date -u` run in that turn, never from memory or from the last
    stamp you saw. Remembered figures drift.

38. **Measure the right object.** Identify a session from an authoritative id, never "most
    recently modified". Checking a property of the wrong object raises confidence, not accuracy.
    PRS (2026-10-26): For your own context fill, take your identity from your own listing (the
    agent listing's first line, or your env block) and measure that session's transcript; the
    newest file in the folder may be a sibling's.

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
    PRS (2026-10-26): Before trusting a text scan to build the list, test its pattern on the
    real file: a pattern too narrow (letters only, where items hold digits) leaves the list
    short. When the verifier rebuilds the list from a fresh data dump, it first compares the
    dump's newest item time with the seed's build time, and reports an item newer than the build
    as seed drift, not the builder's defect.

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
    PRS (2026-10-26): The same holds for entry paths: a feature tested only from its top-level
    entry leaves every other way into it unchecked. Pin each other path with a check that
    measures the change it should cause (the before and after numbers), not only that the page
    still loads.

46. **A guard that compares NAMES cannot see TYPES.** An entire family of drift guards
    compared key sets; flipping a field's declared type in the *canonical schema* left the
    dedicated drift guard green at 47/47. The only backstop was the compiler, and only
    *incidentally* — one file built typed literals while its neighbor used a cast. Decide
    explicitly whether a guard covers types, and write down which backstop you are relying
    on. Relying on one without knowing it is the failure.
    PRS (2026-10-26): In a check or a review, never accept a helper call on the strength of the
    helper's name: the helper may return something other than its name promises. Open what it
    returns (read its body or call it on a known case), not just what it is called.

47. **A restore check must assert TWO things: tree clean AND the fix still present.** A
    mutation-restore run against a baseline that never carried the fix is a **delete**, not
    a restore — and it prints `nothing to commit, working tree clean` plus a GREEN gate on
    the *pre-fix* SHA. Clean status alone cannot distinguish restored from deleted. Always
    commit GREEN before mutating.
    PRS (2026-10-26): After undoing a planted bug, wipe the compiled cache (Python's
    `__pycache__`), or a compiled copy of the bug can still run against the restored source. Run
    tests and gates with compiled-file writes off (for Python, `PYTHONDONTWRITEBYTECODE=1`):
    written cache files leave the tree dirty, and the next gate's dirty-tree check fails
    (see 63).

48. **A mutant that reds for the wrong reason is not evidence.** A "mutant" that *inserted*
    a duplicate step rather than *relocating* one produced a red — but proved only
    sensitivity to placement, not that the guard catches the reorder it was written for.
    Diff-verify every mutant; a red you wanted is the easiest thing in the world to accept.
    PRS (2026-10-26): A red counts only when this run built the page it ran: a failed build
    leaves old pages in the output folder, and a red from them belongs to an older mutant. Wipe
    the output folder before each mutant build, and stop on a failed build instead of running
    whatever pages are there. For a code mutant, write down before the run which named check
    should fail and with what message: a red that arrives through another check, or a flip
    hidden behind an earlier failure, is an unclean falsify, not a pass. Predict only the
    guard's own effect line; what the program does after the guard fires is a guess: write it
    down as one, and never score it. Say which checks still run after the first failure: a run
    that stops at its first red never reaches the later ones, so a prediction that counts on
    them cannot be scored. Before running a mutant, read its diff: it must show the guarded line
    removed or changed, because a diff of only added lines disables nothing. Keep the falsify
    record (the diff, the prediction, the red line seen) in a commit message on the branch, and
    keep the mutated files, so a reviewer can rerun it.

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
    mutate the claim away and predict GREEN; a mutant that survives is the finding.

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
    PRS (2026-10-26): A number in a code comment carries no commit: a balance or tuning figure
    quoted from a comment may describe code that has changed since. Before offering such a
    number for a decision, re-run the simulation or measurement on the current base and quote
    the commit SHA beside each number.

59. **Fail-open vs fail-closed is the load-bearing property of any client-side guard.** A
    disable derived from data that may not have loaded must degrade to *enabled* — the
    server's refusal is the real guard. A false disable silently denies a legitimate action
    with no error and no recourse, which is far worse than the dead click it replaced.

60. **A guard that cries wolf gets deleted.** Measure a marker/heuristic set against the real
    corpus before shipping it: a first-choice marker matched three files, two of which were
    unrelated. Precision is what keeps a guard alive long enough to catch anything.
    PRS (2026-10-26): The other side is recall: a parser of hand-written status markers must
    accept every form the source actually uses, or one missed form silently files those entries
    under the wrong status. Count the forms first (bold, bulleted, quoted, italic notes), and
    derive the expected table a second, independent way before trusting the parser's output.
    Content clipped by an ancestor with hidden overflow, or inside a closed `<details>`, still
    has client rects: make a right-edge overflow walk clip each rect by its overflow ancestors
    and skip closed `<details>`, or it reports hidden text as overflow (the opposite trap, a
    missed overflow, is 74).

## Guards, gate logs and worktree git (harvest 2026-10-15)

*One orchestrated day of tool-building rows, each read by a sibling verifier. Every lesson below
came from a verifier finding or a falsify run that went red where the builder expected green.*

61. **A guard that scans state must run before any step that erases what it scans** — or that
    step must record what it erased, and the guard reads the record. A guard placed after the
    erasing step can never fire; it prints green on every input. Order the pipeline so the scan
    sees the input, and prove each guard red by mutating what produces its input (the writer),
    not just the guard itself; a mutant of the guard alone cannot show that its input never
    reaches it.
    PRS (2026-10-26): A guard's count is valid only for the stage it ran at: also place it after
    the last step that moves its input, or run it again there and quote that count (see 87).
    When a change removes a UI element, grep every test helper, wait and measure that references
    it, then build and run every planted mutant once after the change; a mutant whose anchor
    vanished, or that no longer goes red, is a dead check, and a helper that waits for a removed
    element passes or hangs for the wrong reason. Re-aiming a check (a new selector, region or
    threshold) is such a step too: rerun every mutant aimed at it, and the mutants of checks
    that read the same shared state (browser storage, a cache, a saved file).

62. **A measuring guard draws its measured landmarks on the output it judges.** A sample too
    sparse to land on the feature can still give a plausible number and a clean log. Draw the
    sampled points on the rendered output and emit that overlay with the verdict: a measurement
    nobody can see is a measurement nobody can check.

63. **Write the gate log's SHA line inside the throttled command, after the slot is acquired.**
    A header written before the wait can name a commit the tree no longer holds by the time the
    gate runs, so a green log vouches for the wrong SHA. Print `SHA $(git rev-parse HEAD)` as
    the first line the throttled command itself runs; the verifier compares the slot time
    against the reflog. Extends 32.
    A gate queue copies the tree when its slot frees, not when the run was queued, so edits made
    while waiting are what gets tested. Do not edit the tree while a queued gate waits, or run
    it from a snapshot made at queue time.
    Commit before the gate run, so the SHA line names the saved version and the log vouches for
    a tree with no uncommitted edits.


64. Retired, see 30.

65. **Falsify a path or name filter with its escape variants, and prove each layer bites on its
    own.** A filter can miss a name it never anticipated, or check only the first path segment,
    so `allowed/../forbidden` passes. Plant `..`, absolute-path and case variants of every
    forbidden name, not just the names themselves. When the guard is layered (a name check, then
    a content check), patch the earlier layer out in-process and show the later one still goes
    red on its own: a layered guard whose inner layer never fires alone is one guard, not two.
    The same holds for finding paths in files: a search by spelling (one drive letter, one
    prefix) misses relative paths such as `../../x` and paths on other drives. Resolve every
    path-like string to the place it points and judge the target, not how it is written.
    Falsify a name-tied exemption with real in-between data placed under the protected name,
    before any hand-shaped body.

66. **A check that compares a clamped accessor can never fail: compare the underlying value.** A
    getter that caps its result (`min(value, max)`) reads exactly "max" on every overflow, so a
    "does not exceed the max" test through it passes on what it should catch. Assert on the raw
    stored value, and falsify by pushing the raw value past the cap: if the check stays green,
    it is reading the clamp.

67. **A probe number that feeds a human ruling is cross-checked by a second path first.** Before
    a probe's number goes to the person deciding, reproduce it another way (a fixture built by
    the real code path, or a real run) and say in the report that both agree; a wrong number
    shapes a ruling that must then be re-asked.
    Give the number at full precision whenever someone will set a limit from it: quote the
    script's own output, unrounded, and round only in prose that sets no limit. A rounded value
    can set a limit the real value fails.

68. Retired, see 74.

69. **An input mutant proves it changed the measured feature before its PASS or FAIL counts.** A
    mutation that left the measured feature unchanged makes a pass look like proof and a fail
    look like a hole. Log the measured value before and after the mutation next to the verdict:
    a mutant that moved nothing is no evidence either way (see 21 and 48 for code mutants).
    Before trusting a probe's number, or a mutant's verdict, show that it moves the quantity the
    check reads; a probe that changes a neighbouring value reports nothing about the one under
    test.


70. Retired, see 48.

71. **"Old data" fixtures are built by the OLD code, in its own worktree.** Fixtures written by
    the new code in "old mode" carry its assumptions and can pass a migration that real old
    saves would break. Check out the commit before the change in a separate worktree, produce
    the fixtures there, record that commit in the fixture's header, and only then test the new
    code on them.

72. **A claim of "within plus or minus N percent" is checked per row, not on the total.** Report
    the change for each source separately and apply the tolerance to each row; a total within
    tolerance proves only that the errors cancel.

73. **Test a lock's atomicity on the filesystem where the real lock lives.** Exclusive create
    can behave differently on a network-style mount (a 9p or SMB share) than on local disk. Run
    the race, and its falsify, with the temp folder on that same mount, and use a temp path with
    the same shape as the real one (spaces included): a test run only on local disk says
    nothing about the mount, and a path without spaces hides quoting bugs in the test itself.

74. **A measuring guard must not let the measured object choose its own landmarks.** Landmarks
    found by a heuristic (the largest step in a profile, the widest slice) move with the input
    they judge. Pin landmarks to something the input cannot reshape (a skeleton's joints, a
    certified reference basis), and fail closed when they are missing (see 62: draw them on the
    output too).
    A check that re-centres on the shape it measures follows that shape the same way and can
    pass gross defects: test it on known-bad pictures before trusting it.
    Containment is the same trap: a child measured against its own box's edge passes when the
    overflowing child widens that box. Measure against an edge the defect cannot move (the
    screen, a fixed parent, a width set in the test).
    A gap measured to an outline must also catch a part inside the shape, which a distance to
    the nearest outline point reads as "touching". Give a point inside the shape a negative gap,
    so a part that sinks in fails, and plant one inside to prove it.
    PRS (2026-10-26): A guard whose limits are fractions of a total takes that total only from
    parts the input cannot extend (named anchors, a fixed skeleton), or refuses an input whose
    reference parts are not the expected ones; an added part can grow the total and shrink every
    ratio under its limit.

75. Retired, see 48.

76. **After a scripted marker-to-marker cut, grep for the lines it removed.** The range can
    swallow lines meant to stay, and nothing fails until much later. After any cut by pattern or
    marker, list the removed lines (`git diff | grep '^-'`) and check each one was meant to go,
    before the next step builds on the file.
    The same goes for a find-and-replace that splices text into the middle of a line: edit whole
    lines, then read the diff to see each changed line in full.

77. Retired, see 38.

78. **A lock helper's release removes only the exact line it wrote, and its default owner is
    unique per run.** Write an owner unique to the run (tool, host and process id) unless the
    caller names one; fixed default names let two unnamed runs each believe they hold the lock.
    On release or trap, compare the whole owner line before removing anything; a release that
    skips the comparison can free a lock another run has taken since. Never use a real session's
    name as the default (see 73).

79. Retired, see 37.

80. **Parity with the old version is proved on the whole report, not on the numbers you picked.**
    Per-number checks can all pass while rules behave differently. When the goal is "same as
    before", write the old code's full output once (a report, a probe of every rule) and `diff`
    the new one against it; zero lines of difference is the proof. Then make the diff fail on
    purpose (a mutant) so the comparison is known to see a change (see 40 and 72).
    Probe every regime the rules read (time of day, per-frame versus per-snapshot, the rare
    branches), not only the moment where the check is convenient; a change can show only there.
    PRS (2026-10-26): The mutant changes one input that must move the output, and the diff must
    go non-empty: a comparison can miss the changed part (the wrong file, a cached copy, a section
    the generator skips). After moving a threshold or a scale, list each run-time input that feeds
    a rule and probe it empty, middle and full on both versions, per rule, reading raw values,
    never through a clamped accessor (see 66); some rules may still read the input on the old
    scale. A scenario that holds two inputs equal cannot tell them apart: vary the input that
    separates two readings of a rule. Run one probe script unchanged on the base and the tip, free
    of calls that exist on only one side (or pick the call at run time), print one line per action
    at each input level, and diff line by line; separate or summed probes let differences cancel.

81. Retired, see 80.


82. **Never chain a commit after a gate with `;`.** `run-gate; git commit ...` commits even when
    the gate fails, and the log then shows a green-looking commit on red code. Join them with
    `&&`, or run the gate, read its pass line, and commit in a separate step (see 63).
    Run a script that edits a file and asserts its own result in one `&&` chain with the commit,
    never with `;` or on a new line, or have the commit step check that the diff shows the
    change: a failed assert writes nothing, and the commit ships the old text under a message
    that claims the edit.

83. Retired, see 80.

84. **A test that takes its expected value from the constant it guards cannot fail on that
    constant.** Change the constant and the code and the expectation move together, so the check
    stays green. Write the ruled value into the test itself. To falsify, mutate the constant
    AND, separately, delete the call it drives; both must turn the check red (see 48).
    The same goes for an oracle that calls the function it checks: its expected value changes
    with any change to that function, so it passes every change. Take the expected value from
    the ruling or from a value written down before the change, never from the code under test.
    A helper in the test that re-implements the code's formula is the same oracle: a bug copied
    into both stays green. Where the formula cannot be avoided, also pin one case with its value
    written out by hand.


85. Retired, see 80.

86. **"Every item is covered" comes from a script over the list, never from memory.** Memory
    misses items. Before claiming full coverage, loop over the list's real source (the file, the
    table, the grep) and print each item with where it is covered; quote that output, including
    its count.
    A test that trusts the data's own tags cannot catch a mis-tagged entry: rebuild the
    population from the file itself (the real column, the real text) instead of from a tag the
    entry carries, then compare the two counts.


87. **When a repair pass runs before a check, report the check's count before the repair too.**
    A local cleanup (a relax, a smooth, an auto-fix) can turn a defect into one the metric no
    longer measures while the gate reads green. Print the metric before and after the repair; a
    large drop is a finding to look at, not a pass (see 62: measure on the output).
    A check whose zone sits inside the zone a fix just cleaned passes by construction. Report a
    wider, independent read of the same output next to it, and keep the human-eye check as the
    evidence.

88. **After a machine crash, audit before assigning any work.** A crash can leave unpushed
    branches, uncommitted files, lost gate logs and locks naming dead sessions. Before any
    sibling gets work: check every worktree for dirty files and unpushed commits (push a rebase
    under a new branch name, never a force-push), commit shared memory left behind, treat every
    gate log under a temp folder as lost and re-run those gates, check each lock against a live
    owner, and hold the siblings until the audit is done.

89. **Relay only a settled human ruling to a builder.** Forwarding each step of the human's
    thinking sends the builder a string of specs, each superseding the last. Collect the whole
    answer first, ask "is that final?", then send the builder one spec.

90. **A visual check done on thumbnails is not a check; give each property its own measured
    check.** An image can look right at thumbnail size and be wrong at full size, and a metric
    for one property passes errors in another. Measure at full resolution with a number, and
    check each property separately (style is not geometry: the angle, the outline and the
    proportions each get their own metric).
    Check in the same view as the final output; a simplified render can differ by pixels from
    the real one. Measure with the camera, projection and resolution the delivered output uses,
    or show first that the cheaper view gives the same numbers.
    The converse also holds: after a batch passes its number checks, still look at every changed
    picture or artifact at full size. Numbers measure what they were built for (a count or size
    metric misses a flipped frame or stray specks); only the look sees the rest.

91. **Prove a new check red on the artifact the human actually rejected, not only on a made-up
    broken case.** An invented case can fail in a way the real one does not. Run the check on the
    rejected artifact itself (the picture, the file, the saved run) before calling it a guard for
    that complaint; if it stays green there, it does not guard it (see 69 and 48).
    Before building a check for a reviewer's complaint, measure what actually differs between the
    rejected output and an accepted one, or the check may test the wrong property.
    A hole or regression count proves nothing until it has run on the real failing case. Check that
    its window covers the whole claim (the crop, every layer the complaint is about) and that it
    counts leaks open to the edge, not only enclosed holes.
    Run every new check against the code before the fix and label each one: a check that fails there
    reproduces the complaint; one that passes there is a regression guard, worth keeping, but no
    proof that the fix addressed the complaint.

92. **When inheriting a row, list its scratch files by modification time against the branch
    tip.** A row left by a session that ended abruptly can hold unlogged attempts newer than the
    last commit, with work the branch still lacks. Before starting, list the row's scratch and
    output files sorted by time next to the tip's commit time: any file newer than the tip is an
    unlogged attempt, to be read, logged or discarded on purpose (see 88).

93. Retired, see 105.

94. **Before proposing how to satisfy a refusing check, trace where the check takes its input.**
    The check may read a live, derived value (an evaluated result, not the stored field), so an
    edit to the input you assumed changes nothing. Read the check's own code to the point where
    its input enters, name that input, and only then propose a change to it (see 67).

95. Retired, see 9.

96. **A gap you have not isolated is "not explained", never "noise"; a quantity is "display
    only" only after every consumer is traced.** A gap written off as noise hides its cause, and
    a display-only value can feed a rule two calls away. Write "not explained" until the gap has
    been reproduced and attributed to a named cause; call a value display-only only after
    listing every reader of it (grep each consumer, quote the list) (see 72 and 80).

97. **A failure that depends on the path cannot be bisected by one run per commit.** When a
    failure shows only on some routes, a good run on a commit proves nothing. Read the crash
    frame, reproduce the engine fact it names in a minimal script, and prove the fix with a
    check that can fail (a mutant that restores the bug turns it red), not with a green run of
    the long scenario (see 48).

98. **A liveness guard compares to the thing it guards; pasted for another kind of object it
    silently aborts.** It then fails every time and quietly stops a scripted run while the lint
    and smoke tests stay green. For each guard site, say what object it guards and which object
    the guard compares against, and plant a case per kind (no guard, wrong guard, right guard)
    in the lint; falsify by pasting the guard onto the other kind and checking it goes red
    (see 48 and 97). A guard counts only where it controls the use: plant cases where the guard
    is nested away from the use, is a no-op (`if G: pass`) or is joined by `and not G`, and
    require the lint to flag each.

99. **A refit that wins back broken bars can quietly move the bars it does not score.** Put
    every bar that must hold into the refit's cost, not only the ones that failed, and report
    all bars before and after the refit (see 62 and 94).

100. **Before wiring an effect to an event, prove the event can fire where the effect lives.**
    If the event does not run there, the hook is dead code that only a probe can reach. Name the
    event, name the screen or state the effect lives in, and show a run in which the event fires
    there (a log line from the real path, not from the probe) before building on it (see 105).

101. **Prove a cause by pinning one path at a time, and measure options as patch scripts on the
    probe's temp copy.** Changing several candidate causes together leaves a better result
    unattributable, and editing the product to try options leaves changes to revert. Pin or
    remove one path per run and record which pin moved the number; apply each option as a patch
    script to a temporary copy of the tree, so a proposal milestone commits no product change
    (see 96).
    When a defect survives a fix to one stage of a pipeline, swap components before the next
    fix: hold one stage, vary the other (A/B renders or runs), and see which stage carries the
    defect. A scalar meter can confirm a wrong cause: one computed in the wrong space or over
    zones of mixed scale can move with each fix while the defect stays (see 90).
    Before an A/B, read the settings the existing evidence was produced with, so the comparison
    varies only what you mean to vary.
    The same flaw in the same spot on every seed comes from the input, not the random draw:
    check the input picture before fixing the outputs.
    PRS (2026-10-26): When a new random draw shifts a seeded run, build the old code plus only
    that one draw and run both on the same seeds: if they match, the change is drift from the
    shifted sequence, not a fault; compare the kinds of outcome, not the seeds.

102. Retired, see 10.

103. **Size a parallel fan-out by free memory, not by cores.** A fan-out sized by core count can
    start many heavy processes at once and run the machine out of memory. Start at most two
    heavy processes, and start each only when the free memory reported by the system is at least
    3 GB; wait otherwise (see 88).
    On a shared GPU or similar scarce device, gate each job on the CURRENT baseline before it
    starts, not only on a peak limit: a sampler that reads once a second cannot stop a load
    spike, and a neighbour that just finished may still hold its memory. Memory-mapped arrays
    still count in resident size: two mapped files diffed together read as the sum of both, so
    budget each process as frames x size x item size for everything open at once, and stream
    one frame at a time.

104. **Stopping a background shell task leaves its child processes running.** A leftover child
    keeps holding memory and locks. Record each heavy run's process id at launch (a file next to
    its log) and stop it by that exact id; never by a name match, which can also kill your own
    shell or another session's run.
    The same holds for a wrapper (a shell launcher, a detached start): killing the program
    leaves the wrapper alive, so at the end of a session list your own processes by start time
    and stop the wrappers too. When a row moves to another agent mid-run, kill your queued gate
    chain by id and check the throttle queue for leftover tickets.

105. **A READ of a factor in a shared function lists every caller.** A caller may apply the
    factor again or skip it. Grep every caller, quote the list, and state for each whether it
    applies the factor itself.
    The same applies to a claim that code never runs or is dead: cite a full caller grep on the
    object's real class (subclass overrides included) or a probe; "runs but is never seen" is a
    separate verdict.
    The same goes for "X unchanged" lines in records (a changelog, a decision log): cite the
    search behind each one.
    PRS (2026-10-26): A test either drives the call site itself or checks the exact call text
    (grep the line, count the factor per site), and falsifies by doubling the factor at one
    site; a helper can be right while a caller applies its factor again. Next to a per-site
    check, assert the exact total number of call sites so a site added elsewhere cannot go
    unchecked, and falsify by adding one extra call in another function.

106. **After every delivery, assert the delivered file's md5 against its source.** An older or
    partial copy left at the destination can be used as if it were the source. Compare the md5
    of the delivered file with the source's in the same command that delivers it, and fail the
    step when they differ.

107. **Before a long optimization against extrapolated targets, check the targets can be met
    together.** Targets each extrapolated on its own can drift apart until no solution meets
    them all, and the run stalls for hours. Before the long run, evaluate every target at the
    extremes and at the points beyond the measured range, and test that one candidate (or a
    cheap relaxation) can satisfy them all at once; if not, reconcile the targets first
    (see 99).
    A target defined on a flat render of a three-dimensional scene (the share of one part hidden
    behind another) is checked against the render's layer draw order before it becomes a pass
    line: parts drawn on a layer below the covered part can hide none of it, so a target that
    counts on them can never be met.

108. **Run a long background chain as one script, memory-gated per step, with a status file per
    step.** Separate background commands can be killed partway by the low-memory reaper, with
    nothing to show which step finished, which was running and which never started. Put the
    chain in one script that waits for free memory before each step and writes each step's own
    status file (started, exit code, end time) next to its log, so a reaped chain shows exactly
    where it stopped and can resume from there (see 103 and 104).

109. **A planted bug proves a new test only if the old tests miss it.** If the old tests also go
    red on it, the new test adds nothing that is not already guarded. Run each planted bug
    against the old suite too and record both results: the new test earns its place only on a
    bug the old suite leaves green (see 48).

110. **Falsify a check in the mode the real gate runs it.** A check with a quick and a strict
    mode may be unable to fail in its default one. Prove a check red with the same flags,
    environment and mode the gate itself uses, and make the gate name that mode explicitly
    instead of relying on a default.

111. **A stamp that records how something was made counts only if something reads it and stops
    on a mismatch.** A stamp nothing compares with the settings in force can never catch a
    mismatch. Wherever a stamp exists, add the reader that compares it with the live values and
    fails on any difference, and prove that reader red by changing one setting (see 80).

112. **Before pinning an anchor per frame to a measured extreme, measure the motion the pin
    adds.** Each frame's extreme (its lowest pixel, say) moves with the content, so the pinned
    result can bounce more than the source drifts. Measure the anchor's motion in the source,
    then in the pinned result, and pin to a value that is steady across frames (a median over
    the animation, per direction) when the pinned result moves more than the source (see 90).

113. **Measure a "missing" step's output at every later stage before rewriting it.** A step that
    looks idle may be firing but under-correcting while later stages widen the gap. Read the
    step's own output and each later stage's input and output for a few items before changing
    it; fix the stage where the gap appears, not the one that looks idle.

114. **After a batch fix, a mask-only composite plus an md5 count proves the fix touched only
    what it should.** Re-running the whole pipeline changes pixels outside the fixed area, on
    frames the fix should not touch. Composite the fixed result into the old frame through the
    fix's mask only, then count by md5 how many outputs differ from before: the count must equal
    the number meant to change, and the differing pixels must lie inside the mask (see 80).

115. Retired, see 144.

116. **Judge a guide on every view before spending a long job on it.** A guide right from one
    view can be wrong from another, and the fault shows only after the slow job has run. Before
    any slow or scarce job (a GPU run, a render, a bake), look at the guide from each view the
    output will be judged in, and reject it there first (see 107).

117. **A pick-by-eye sheet shows the candidate between fixed anchors, at one scale, on one
    baseline.** Candidates at different sizes and baselines, with numbers on the picture, cannot
    be told apart by eye. Put the candidate between its fixed neighbours, at one scale and a
    shared baseline; put zoom-ins and measurements in the written note, not on the sheet.

118. Retired, see 61.

119. **When the look is the requirement, a headless check of the model is not the check; read the
    drawn pixels and add a mutant only the pixel read can kill.** The model can hold the right
    numbers while the drawn result is wrong (a draw mode that skips a tint, a multiplier never
    checked on the output). A pin that stores a value beside the draw call, or calls the update
    itself, cannot see the effect. Read the rendered pixels inside the subject's own mask, and
    prove the check red by mutating the effect itself (its colour, its draw order), not the number
    the pin reads (see 84 and 100).
    A headless browser on virtual time draws no frames, so animation-frame and resize-observer
    callbacks may never run there: check a fix that lives in such a callback by reading its code
    (or in a real browser), and say which; a green headless run proves nothing about it.
    When every automatic check passes but the result is visual, whoever presents it for a human
    decision opens the result first.

120. **A probe run that dies part-way gives no results: rerun the whole set.** If a run is cut
    off, none of its numbers count, or partial results pass as findings: rerun the whole set
    and quote only from a complete run (see 9).
    A run on the code before a fix often crashes at the same place every time, so a plain rerun
    repeats the crash. Cut out the crashing block (it counts as a fail for its own checks),
    rerun, and repeat until every check has a verdict on the pre-fix code.

121. **A metric that ranks things must be run on the reference pair it is meant to rank, and on
    wrong references.** A broken meter can rank candidates against what a person sees. Before
    trusting a metric, score it on a pair whose order is known: every right pair must beat every
    wrong pair (a shifted frame, the other view), and the margin is reported. A meter that
    cannot separate known pairs is broken; fix or drop it before it ranks candidates (see 69).
    PRS (2026-10-26): The same holds for a camera or vanishing-point check: run it on copies of
    a good picture shifted up, down and sideways, one axis at a time and require a FAIL for
    each, and on the reference itself and require a PASS; a check that passes the shifted copies
    or fails the reference does not measure the camera (see 91 and 124).

122. **Before a ladder of edits, test the largest step on the hardest case; calibrate an edit
    check with a null edit and a mutant.** A method's size ceiling only shows on its largest
    step, so trying small steps first hides it. Trust a check with a quantisation floor (the
    smallest change it can see) only after it passes a null edit (no change) and fails a mutant
    (a known-bad change); a fail without that calibration may be the floor itself.
    Run a new picture check on the picture already accepted first; if that one fails, the check
    is wrong, not the picture.
    Run a "fits" check (one row, no overflow, no wrap) on the real worst case: the largest count
    of items and the longest label the data holds, not a small fixture, which can fit while the
    real data wraps.
    Measure a layout guarantee (at least N items per row, fits one row) where the user sees it:
    across the whole page, on the real item count and size spread, with the previous layout as a
    mutant that must fail. A per-container count on a tidy fixture can pass while most rows on
    the real page hold one item (see 74).
    Take a never-fail baseline from clean input: an output made from an input that already held
    the defect carries the defect, so checks that pass on it prove nothing. Prove the checks can
    pass on clean reference data first.

123. **A shape gate on an edited outline is relative to the original over the same rows, checked
    at several scales, and reported as a pass fraction.** Absolute curvature bars flag the
    figure's own bends where the defect sits, so compare against the original over the same
    rows. One scale misses flat-bottomed defects: check several scales and prove the gate red
    with a planted flat-bottom mutant. When a bar sits at the measure's noise floor it passes
    only in pockets of the parameter grid: report the pass fraction, never just "pass"
    (see 110).

124. **A validator needs a pin that feeds it a planted fault.** A validator run only on clean
    real data has branches nobody has proved. Plant a bad copy for each branch (a missing slot,
    a wrong reference) and require the validator to refuse it (see 98 and 109).
    When the planted fault drops a record, first count the places that point at it (every
    reference, link or index entry that names it) and predict that many faults. A checker that
    reports a different count has a finding: it misses a dangling link, or reports one twice
    (see 48).
    The same holds for any detector: before its PASS counts, show it firing on a planted case
    known to hold the defect. A detector that never fires looks exactly like a clean result.

125. Retired, see 9.

126. **Rebase only before the first push; after it, cherry-pick onto the pushed tip and
    re-gate.** A rebase after a push forces a force-push or leaves two histories. Before the
    push, rebase freely; once pushed, move later work by cherry-pick onto the pushed tip and run
    the gate again at the new tip, so no force-push is needed (see 88).

127. **Compensating a non-deterministic generator's drift needs two rounds that agree first.** A
    generator that pulls its output back toward its own bias drifts differently each run, so a
    one-shot compensation can over-correct. Measure the drift in two independent rounds,
    compensate only when they agree, and compensate once at most.

128. **A design row's seam table includes the owner's earlier rulings on the topic, built or
    not.** Before a design is proposed, grep the decisions file for rulings on the topic,
    including ones never built; a proposal that ignores an unbuilt ruling reopens a settled
    question. Open the document with what already exists.

129. **Parallel builders in one worktree: exclusive file lists, shared hooks committed first,
    one locked test runner; silent side effects and singletons get their own checks.** Give each
    builder an exclusive file list, let the lead commit the shared hooks first, and run tests
    through a single runner under a file lock. A claim kept true by a silent side effect (a
    parity draw that keeps two streams aligned) needs its own assert and a mutant that removes
    the effect. Tests that share one process restore any singleton state they touch.

130. **Flip a policy constant once before calling a change green.** Move a constant that sets a
    policy (a floor, a cap) once to another value and rerun the suite: the pins that go red are
    the scenario-bound ones, tied to the value rather than to the rule. Rewrite each of them
    relative to the constant, or name it as bound.

131. **A steadiness check measures at one fixed scale per route.** A pipeline that normalises
    each frame (to the same height, say) hides exactly the drift a size or steadiness check is
    looking for. Measure at one fixed scale per route, and before reading a result confirm no
    stage resized the frames individually (see 112).
    A batch step that derives a setting from the whole set (a median size, a shared box) must
    keep the old set's setting when new items join, or adding items quietly changes the old
    outputs and the new ones. Pass the setting in from the original set, prove a run with the
    new items alone equals a run with all of them, and check that the setting really reaches the
    step (an environment value can be dropped on the way into another program).

132. **A two-sided bound needs a mutant per side.** One side can survive a mutant while the
    other side holds the check red. Falsify each side separately: one mutant that breaks the
    lower limit, one that breaks the upper, and report both results (see 48).
    The same holds for a rule with several trigger paths: a guard proven through one path can
    leave another unguarded. List the paths the rule names and give each its own single-change
    mutant; the rule is proven only when each of them turns red.

133. **An automated quick reply to a person can invent facts or promise work nobody started;
    correct it in the full answer and never build on it.** When a channel answers instantly on
    the coordinator's behalf, the coordinator reads every such reply, corrects it in the full
    answer, and builds only on what the person actually said, not on what the quick reply
    claimed.

134. **While the base model is not agreed, send one proposal, not a fan-out of
    questions.** Detailed questions ask the person to rule on parts of something that may
    change. Send a single proposal for the base first; open the detailed questions after it is
    agreed, one per real fork.

135. **Every async UI action gets one check with a deliberately late stub.** A stub that
    resolves at once hides in-flight races, such as a redraw that re-arms a button while a save
    or a remote call is still pending. For each async action, add one check whose stub resolves
    late, fire a redraw (or the rebuild the real screen does) before it resolves, and assert the
    in-flight state holds: the control stays disabled, nothing is sent twice, the result lands
    once.

136. **Before a long round of redoing work toward a person's target, put today's result beside
    that person's own reference.** A summary of the wish can carry the wrong detail, and the
    round then chases it. Make one layout sheet with the current result next to the owner's
    reference before the long round starts; a summary of a wish is not the target
    (see 107 and 116).

137. Retired, see 101.

138. **Fix a chance flake by forcing the roll at the step, not by counting repeats.** A streak
    of passes proves nothing when the roll barely varies across runs. Force the roll at the step
    (set the seed or the value right before it) and show the test fails exactly when the roll is
    under the chance and passes otherwise; then make the test hold the roll it needs (see 97).

139. **A test that passes only because an earlier test reset the state hides an order bug.**
    Run after a different test, it fails. Run a new or suspect test alone and after the tests
    around it, and report a flake as "k fails in N runs" with N stated, never as "flaky"
    (see 138).
    In a scripted page or fixture, each check sets up its own preconditions (open the item it
    needs, pick the group, reset the filter) instead of relying on where the check before it
    left the page; otherwise a mutant that breaks one step turns a later, unrelated check red,
    and the red names the wrong check.

140. **Sort by the parsed value, never by the raw text.** Sorting keys in mixed formats as text
    puts newer items among older ones, so a "latest" pick is wrong. Parse each key to its value
    (a time, a number) before sorting, and test the sort with mixed formats.

141. **A new colour key must stay distinct from every existing key after every transform the
    tool applies.** Keys distinct in their raw values can collide after a transform, so two
    regions read as one. Check each new key against all existing keys at every stage that
    transforms colours (fades, tints, quantising), not only at the value written.

142. **Before calling a seeded number steady, vary every seed that feeds it and measure the
    spread.** A seed group nobody varied can move the number well outside a band set from one
    seed. List every seed site that feeds the number, vary them all, and set any band from the
    measured spread; prefer an exact check on a path with no random draws to a "within N
    percent" check (see 72 and 101).
    The same holds for any noise source, not only seeds: variants that cannot move the number
    read zero spread. Include at least one variant that can move it, and report which variants
    did (see 69).

143. **A count that two branches each raise by one merges to a single raise, with no
    conflict.** The merge sees the same edit on both sides and keeps one, so the expected count
    falls one short of the checks that run. Recount every such number after each merge or
    rebase that brings in another branch (see 16).

144. **A mutant that stays green means a second path recovers: find it before calling the check
    weak.** Another piece of code can reach the same result by a different route. Find that
    second path, mutate both together to see the red, and state what the check proves: that at
    least one of the two paths works, not that the mutated one does (see 51 and 109).
    A tool that places a part itself is such a second path for a planted case: its own placement
    step can quietly move a bad placement planted before it ran, so the plant proves nothing.
    Pin the placement (turn the tool's placing off, or plant after it) and confirm the planted
    case is still wrong in the output before its red counts.
    PRS (2026-10-26): When two fixes cover for each other, a fix whose trigger appears only
    after the other is removed cannot go red alone: switch them off in steps from one saved
    state (A off; A and B off; all off), say in the prediction which step should turn which
    check red, and score each step from its own result.

145. **After a change that rebuilds the nodes, look them up again; a held reference reads a
    detached copy.** The detached node's state never changes, so a test holding it passes
    whatever the live page shows. After any step that re-renders, query the live node again, and
    prove the test red with a mutant that breaks the live one.

146. **A region-average check cannot see a patch edge.** A patch whose average matches its
    surroundings passes a mean colour and mean brightness check while a hard seam runs along its
    border. Also compare the jump across the patch edge with the jumps inside the region, and
    prove the check red on a planted patch with a hard edge (see 87 and 124).
    Score a local defect on the worst small window, never on a mean over the whole object: a
    mark a few pixels wide averages away. Slide a small window over the object, report the worst
    window's score against the bound, and prove it red on one planted small defect.
    Feathering a paste moves the jump inward, so a seam check that reads only the edge ring goes
    blind: measure the inner rings too, and plant the hard cut past the feather width (see 87).

147. Retired, see 121.

148. **A stand-in for a platform API counts only after it is compared with the platform's own
    contract.** A stub can match the real call in one behaviour and miss another (a full-write
    call that replaces the whole document). Before a check built on a stub or fake counts,
    compare the stand-in's behaviour with the platform's documented contract (docs or types),
    cite the line, and add one check for each behaviour the contract names that the stub does
    not.

149. Retired, see 42.

150. **Squash only onto the merge base; read the diff stat before any push.** After the main
    branch moves, a `git reset --soft origin/main` followed by one commit silently reverts every
    newer commit on main, because the index still holds the branch's older copies of those
    files. Squash onto `git merge-base HEAD origin/main` instead, and before any push read
    `git show --stat` of the commit for files the branch never touched; any such file is a
    revert in disguise (see 126).

151. **A tool that skips existing outputs turns a rerun into a no-op.** Move old outputs away
    (never copy them) before rerunning a tool with a skip-if-exists rule, or the old outputs are
    read as new. Treat a run whose start and end state match, with no resource peak, as a run that
    did nothing (see 69 and 80).
