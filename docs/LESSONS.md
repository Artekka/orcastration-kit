# Distilled Lessons — why the protocol is shaped this way

Each rule below was paid for by a real incident. New lessons land here (with provenance)
and ship to every consuming project on the next kit upgrade — that propagation is the
kit's whole reason to exist.

*Added:* marks text added to an original lesson; lessons 61 on are additions.

## Coordination

1. **Claim before work; one owner per row; file fences are hard.**
   *Provenance:* three concurrent sessions partitioned ~15 workstreams in one evening with
   zero file collisions — only because every row carried an explicit file fence and claims
   were committed before work started (origin project, 2026-08-08).

2. **Worktree isolation for every implementation agent.** Concurrent sessions and their
   subagents never share main's working tree; non-isolated agents silently co-edit files.
   *Provenance:* origin-project memory `feedback_isolate_worktree_for_concurrent_sessions`.
   *Added:* When builders must share one worktree, give each an exclusive file list, commit
   shared hooks first, run tests under one lock, and restore any singleton a test touches;
   parallel runs overwrite each other.

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
   *Added:* A check can silently run on less (an unreadable file skipped, a last line dropped, a
   test that cannot run here): each must fail the gate, and a pass line depends on its own
   checks' failure count.

10. **Read the REAL pass line, unpiped.** Pipes mask exit codes; a background-task
    completion notification masks a failing exit; a process can print its pass summary and
    then crash in teardown. Assert the literal "N passed / 0 failed" summary AND a clean
    exit, from output you captured yourself.
    *Provenance:* origin-project memories `feedback_pipe_masks_exit_code`,
    `feedback_background_test_notification_masks_exit`.
    *Added:* Count failures from the full log, never a cut or filtered one, and never prove a
    setting by a filtered log line; cuts hide reds. Join a gate and its push with `&&`, never
    `;`.

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
    *Added:* Run the same check on the untouched base and report only the failures the change
    adds; before blaming a merge, compare the failing output on the merge and both parents.

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
    *Added:* Mint document and decision codes on main only, by the seat, and recount after every
    merge: two branches that each add one merge cleanly into a single increment.

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
    *Added:* After a crash or a row takeover, audit every worktree before any work: dirty files,
    unpushed commits, lost gate logs, stale locks and unlogged scratch files; the last session
    may have left work half done.

21. **Mutation/falsification commands: one explicit target tree, stderr visible.** Never
    leave earlier path guesses in a compound command; never `2>/dev/null` anything that
    edits files; after restore, diff-verify EVERY tree the command string could have
    reached, not just the one the test reads. And a mutant you haven't diff-verified as
    APPLIED proves nothing.
    *Added:* A mutant counts only if its diff changes the guarded line, its selection is not
    empty, and the measured value moved; keep the falsify record in the commit message.

22. **A change that ADDS test output needs one pass through the real gate stage** — gates
    that classify stage output by pattern make output part of the interface; a realistic
    fixture string in test logs can impersonate an infra-error signal and false-RED every
    session's gate. Capture loggers in tests (and assert they fired); never reword a
    fixture away from the real message to dodge a classifier.

23. **Doc-agent diffs are APPEND-ONLY and fact-checked line-by-line before commit.** A
    delegated log write once replaced a 32k-line institutional log with an 82-line stub,
    with fabricated details; `git diff` deletions must be zero for an append, and every
    factual claim is checked against what actually happened.
    *Added:* The same holds for scripted cuts and find-and-replace: read every removed line,
    because a pattern can delete more than intended.

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
    *Added:* After the first push, cherry-pick instead of rebasing. Squash only onto the merge
    base and read `git show --stat` before pushing: a file the branch never touched is a hidden
    revert.

32. **Run the gate from inside your own worktree.** A gate script that `cd`s to its own
    directory gates the tree it lives in and prints a legitimate green for a tree you are not in.
    *Added:* Write git commands as `git -C <worktree>`, because the shell can drift back to the
    shared checkout. Commit before the gate, write the log's SHA line after the slot is
    acquired, and never edit a tree while its gate waits.

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
    *Added:* Quote numbers and times from a command run in the same turn, never from memory;
    remembered figures drift.

38. **Measure the right object.** Identify a session from an authoritative id, never "most
    recently modified". Checking a property of the wrong object raises confidence, not accuracy.
    *Added:* Measure your own session by its own id. A check that reads the constant it guards
    or the code under test, or a guard pasted onto another kind of object, can never fail: read
    the raw value and write the expected value into the test.

39. **Recycle launch-first, then SIGTERM.** Open the fresh session, wait until its process
    exists, then SIGTERM (not KILL) the old one — no seat is ever empty and the old transcript
    flushes. Only after "retro complete".

40. **All human approvals route through the seat.** Siblings stop and message the seat; the seat
    batches questions to the human in ONE terminal. Scattered prompts across terminals stall
    silently when nobody is watching that window.
    *Added:* Relay only settled rulings to a builder; while the base is unsettled send one
    proposal, not a stream of questions, and open a design with the owner's earlier rulings.
    Every change of course costs a rebuild.

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
    *Added:* Check a change to a shared function at every call site, since one caller may
    already apply it. Test a scan pattern on the real file first.

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
    *Added:* Pin every entry path into a feature, not only the main one, and show an event fires
    where its effect lives before wiring to it.

46. **A guard that compares NAMES cannot see TYPES.** An entire family of drift guards
    compared key sets; flipping a field's declared type in the *canonical schema* left the
    dedicated drift guard green at 47/47. The only backstop was the compiler, and only
    *incidentally* — one file built typed literals while its neighbor used a cast. Decide
    explicitly whether a guard covers types, and write down which backstop you are relying
    on. Relying on one without knowing it is the failure.
    *Added:* The same holds for a helper accepted by its name: read what it returns.

47. **A restore check must assert TWO things: tree clean AND the fix still present.** A
    mutation-restore run against a baseline that never carried the fix is a **delete**, not
    a restore — and it prints `nothing to commit, working tree clean` plus a GREEN gate on
    the *pre-fix* SHA. Clean status alone cannot distinguish restored from deleted. Always
    commit GREEN before mutating.
    *Added:* After undoing a planted bug, clear compiled caches such as `__pycache__`, and run
    gates with compiled-file writes off; a stale cache keeps running the bug, and the writes
    dirty the tree.

48. **A mutant that reds for the wrong reason is not evidence.** A "mutant" that *inserted*
    a duplicate step rather than *relocating* one produced a red — but proved only
    sensitivity to placement, not that the guard catches the reorder it was written for.
    Diff-verify every mutant; a red you wanted is the easiest thing in the world to accept.
    *Added:* Predict the exact failing check before running a mutant; a red from another check,
    or from a run that did not build what it ran, proves nothing. Falsify in the gate's own mode
    with one mutant per bound and per path, flip a policy constant once, and try path filters
    with `..`, absolute and case variants. A planted bug proves a new test only if the old suite
    misses it.

49. **Report the non-findings.** An audit that finds a defect in everything it inspects is
    usually an audit performing thoroughness — the useful output is *which* items were wrong
    and *why the others were not*. For a sweep, the negative results are half the
    deliverable: "your two hypotheses are falsified across 39 suites" is what lets an
    orchestrator ship without hedging.

50. **Propose an omission with the evidence that makes it safe, not the conclusion.** "I
    skipped the integration re-run — here is the diff proving nothing in those paths
    changed" is a thirty-second decision. "Should be fine" costs a full re-run.
    *Added:* A number that feeds a human decision is reproduced a second way and quoted
    unrounded; rounding can hide a value that fails the limit.

51. **A test file that overstates its own coverage is worse than a missing test, because
    the next reader stops looking.** A coverage claim is a claim: it needs the same evidence
    as a behavioral one. *Provenance:* a header fixed an over-claim about code scope and
    introduced a fresh one about test coverage **in the same edit** — the tidy sentence
    arrives first, and repairing a claim feels careful enough to skip checking the new one.
    *Added:* A pin that only prints the builder's claimed value proves nothing: mutate the claim
    away, and if the pin stays green, that is the finding.

52. **The hedge is the untidy part, and a write-up wants a clean rule — whoever is writing.**
    An orchestrator turned a builder's "I ran no sweep" into "patience saved a sibling's
    run," and its "a small piece of evidence" into "a natural experiment." A builder turned
    "three of six sites guarded" into "the state is unreachable." **The self-inflicted case
    is harder to catch, because there is no second party whose qualifier you notice yourself
    dropping.** When a builder qualifies a claim, the qualifier IS part of the finding.
    *Added:* Call an untraced gap "not explained", never "noise", and a value "display only"
    only after listing every reader. An automated reply on someone's behalf can invent facts:
    correct it, never build on it.

53. **Sweeps run from a SHA-pinned worktree, and you must replay your scoping patterns
    against the full file list before claiming coverage.** A shared checkout moves under a
    long sweep as siblings commit, making chunks incomparable and attribution worthless.
    And scoped chunks silently drop anything the patterns miss — one suite matched no chunk
    pattern and had never run; the report would have said "149/149" having run 148. **The
    omission is invisible from inside the chunking.**
    *Added:* "Every item is covered" must come from a script over the real list, quoted with its
    count; a list rebuilt from memory or tags misses items.

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
    *Added:* A number in a code comment may be stale: re-measure it on the current base and
    quote the commit.

59. **Fail-open vs fail-closed is the load-bearing property of any client-side guard.** A
    disable derived from data that may not have loaded must degrade to *enabled* — the
    server's refusal is the real guard. A false disable silently denies a legitimate action
    with no error and no recourse, which is far worse than the dead click it replaced.

60. **A guard that cries wolf gets deleted.** Measure a marker/heuristic set against the real
    corpus before shipping it: a first-choice marker matched three files, two of which were
    unrelated. Precision is what keeps a guard alive long enough to catch anything.

    *Added:* Before a check counts, show it passes today's accepted output and fails each
    known-bad case, including anything the human rejected. A validator needs a planted fault it
    must refuse, a parser accepts every form the source uses, and a layout walk skips clipped
    and closed content.

## Measurement, pipelines and test design (added)

61. **Run a guard after the last step that changes its input, and before any step that erases
    it.**
    Anywhere else it judges input it never saw and stays green on everything. Report its count
    before any repair pass runs, and read a refusing check's code before proposing a fix.

62. **A measuring guard shows its work and cannot be steered by what it measures.**
    Draw its sample points on the output it judges, take reference points only from parts the
    input cannot move, fail closed when they are missing, and count a part sunk inside a shape
    as a negative gap; otherwise the input can pass by moving the ruler.

63. **A mutant that stays green means a second path recovers the result.**
    Find that path before calling the check weak, switch the paths off in stacked steps, and say
    the check proves only the one path. After a change moves what a check aims at, rerun every
    mutant aimed at it and at checks that share its state.

64. **Judge a change per row, never on a total.**
    A total within tolerance can hide one source far outside it. Run one unchanged probe on base
    and tip, print a line per source, apply the tolerance per row, and prove the diff can go
    non-empty; "old data" fixtures are built by the old code.

65. **Find a cause one path at a time.**
    Pin one path per run and try fixes as patches on a temp copy. A failure that depends on the
    path taken cannot be bisected commit by commit; reproduce it in a minimal script. Measure a
    "missing" step's output at every later stage before rewriting it, and when one new random
    draw shifts a seeded run, compare the old code with the old code plus that draw.

66. **Control randomness; never count repeats.**
    "Passed 3 of 3" proves nothing about a chance failure: force the roll at the step instead.
    Before calling a seeded number steady, vary every seed that feeds it and set bands from the
    measured spread. Compensate a generator's drift only after two rounds agree, and only once.

67. **Test the worst real case and every input.**
    After moving a threshold, probe each input at empty, half and full, and check a layout on
    the largest real count and longest label; typical cases pass where the extremes break.
    Before a long optimisation, check the targets can be met together; before a slow job, view
    the guide from every angle beside the owner's reference.

68. **Test a lock on the filesystem where it lives; its release removes only its own entry.**
    A race test on local disk says nothing about a network mount. Use a temp path shaped like
    the real one, and give each run a unique owner (tool, host, process id).

69. **Heavy background work runs as one gated script.**
    Size a fan-out by free memory, not cores, and run a chain as one script with a status file
    per step. Record each process id at launch and stop by that id, since stopping a shell
    leaves its children running. Rerun a cut-off batch whole, and move old outputs away before
    rerunning a tool that skips existing ones.

70. **A record counts only if something reads it and stops on a mismatch.**
    A settings stamp nobody checks is decoration: give it a reader that fails on a difference,
    and compare a delivered file's checksum with its source in the same command.

71. **Test-design traps.**
    Each test sets up its own state and passes alone and among its neighbours (report "k fails
    in N runs"). Give async actions a late-resolving stub, look nodes up again after a
    re-render, sort by parsed value, build time-based seeds from now and falsify them with the
    clock moved ahead, compare a stub with the platform's documented contract, and check a data
    dump's age before blaming a seed. Shared state and timing make passes that do not repeat.

72. **When the look is the requirement, read the drawn pixels.**
    A model check can pass while the screen shows the wrong thing. Measure at full resolution in
    the delivered view, one metric per property, still look at every changed picture, and open
    it yourself before asking a human to judge it; a headless browser draws no frames.

73. **Visual-check traps.**
    Averages hide local defects: score the worst small window, not a region average. Measure
    steadiness at one fixed scale per route and pin anchors to a steady value, not each frame's
    extreme. Compare an edited outline with the original at several scales, check a mask covers
    the flagged spot, prove a batch fix changed only its mask, keep colour keys distinct after
    every transform, and build a pick sheet on fixed anchors, one scale and one baseline.
