# Review of D4 (`d4-survivors.md`): the 12 open survivors and the 4 unreached places

Adversarial read-only review at `d5b2ab9` (worktree `.worktrees/s3f`; last code commit `e599ae1`). Nothing was built, run
or timed. Every `path:line` is relative to the worktree at `d5b2ab9`. The mutant texts were checked against
`.build-s3f/c21/tools/mut-c3.py`, `mut-c3fix.py`, `mut-c4fix.py` and `mut-b.py`, and each original text still matches
the source at HEAD.

## Verdict: CORRECTED

The report's structure holds, and so do its two removals and its reading of `followedLane`. Five points need correcting
before a ruling can use it:

- Three test shapes state the wrong answer under the mutant or under correct code (r8, p7, b22-no-waiter-owner). A
  fixer who copied those assertions would see red on unmutated code, or would assert a kill that is not there.
- The f7 kill is racy in `followVisitedFirst`. S3-R26 item 12's answer 1 does not cover f7, because its state arises in
  both orders, so it needs a deterministic 2/2 kill in both orders.
- r2b cannot be classed EQUIVALENT. The report names a production path that breaks its own argument.

Every recommended production change is a removal. Every other change is a test or an invariant clause, and
`invariantViolations()` has no production caller. So no actor turn grows, and the 8.5 ms target is not at risk from
this work. No public or package signature changes.

## What was confirmed

- **§1, `followedLane`'s lane.**
  - One production caller: `throttled`, `EngineFailures.swift:350`. The only other caller is the bench,
    `BenchSync.swift:2957`.
  - The lane feeds only `retryPolicy` → `Backoff.delay` (`EngineSupport.swift:201-216`). That reads `maxRetryAfter`,
    `baseDelay` and `maxDelay`, never `maxAttemptsPerRun`.
  - `.exhausted` against `.until` is fixed at arrival (`:351-358`) and replayed unchanged (`replayThrottle`,
    `EngineFollow.swift:937-955`).
  - No 429 path counts an attempt against a cap. The claim lane is not involved.
  - Under a tuning whose lanes straddle the Retry-After (`shortInteractiveRetry`, `EngineFollowBarrierAnswerTests.swift:439`),
    the flip changes answers.
  - **Precision the report omits.** The flip changes the answers of non-user waiters on the job: under `.until`, a
    prefetch waiter waits and the retry serves it; under `.exhausted`, it gets `serverUnavailable`. It also changes the
    answers of other callers through the origin's throttle. It does not change the answer of a user waiter on the job.
    Under `.until` the park fails that waiter fast with `serverUnavailable(retryAfter: wait)` once the wait exceeds 2 s
    (`failFastError`, `EngineJobs.swift:842-846`). Under `.exhausted` it gets `serverUnavailable(retryAfter: 60)`. That
    is the same case, and S3-R16 1(a) excludes Retry-After values. This is what breaks §3.8 and §3.7's p7 text (M1, M2).
- **§2: `replayVerdict`'s second guard is unreachable (both halves).**
  - The record has one writer, `defersFailure` (`EngineFollow.swift:501`). It is cleared by the replay (`:881`), by
    `removeJob` (`EngineJobs.swift:475`; `removeJob` is the only `jobs.removeValue` outside shutdown, `:451`) and by
    shutdown (`EngineShutdown.swift:134`).
  - Epochs are written only by creation (`EngineJobs.swift:164`) and by a start (`EngineDispatch.swift:705-706`).
    `dispatch` is reached only from `pump` (`EngineDispatch.swift:132`, `:157`), which returns behind the barrier and
    during the drain (`:95`).
  - Exactly 17 `transition(…, to: .queued)` sites exist. I re-walked the whole-job writers too
    (`EngineDispatch.swift:750`, `:913`; `EngineFailures.swift:27`, `:37`, `:291`; `EngineJobs.swift:55`, `:169`, `:535`,
    `:555`). None writes a stale state onto a failed job whose verdict waits.
  - The one non-obvious reset is the `.spaceFailure` replay clearing `attemptEnd` (`EngineFollow.swift:390`). It would
    need a `.spaceFailure` event and a verdict record on the same epoch. Each attempt has one exit, and `spaceFailed`
    writes no record (`EngineFailures.swift:571-579`). So it does not arise.
  - The removal with an epoch clause and a clause test is sound, and the arithmetic of the saving is right
    (512 × 2 × ~0.05 µs ≈ 0.05 ms).
- **§3.1: r7's `atEnd` is always false.**
  - `failed()` has one caller, `finishAttempt` (`EngineDispatch.swift:959`), behind `job.active?.attempt ==
    request.attempt` (`:931`).
  - `active` is non-nil only while the job is downloading (`EngineJobs.swift:51-54`).
  - The throttle arm runs synchronously (`EngineFailures.swift:124-125`).
  - `waitingTarget` is `nil` for a downloading job (`EngineFollow.swift:1580-1581`).
  - So the removal is right.
- **§3.3, b23 ×2.** Both mutants survive rr21-T13 for the reason given. The two new arguments separate them, and both
  orders reach the arm, because the batch is owed in both.
- **§3.5, the settle slice.** `steps` carries across the three loops, and each check is `==`, not `>=`
  (`EngineShutdown.swift:174-219`). So with 600 owed answers and no jobs or waiters left, the correct code records
  `[512, 88]` and the drop-mutant records `[600]`, as stated. Existing precedent for the shutdown-while-owed shape: T-A3,
  `EngineOwedAnswersTests.swift:190-202`.
- **§3.7 r5, §3.9 vy, §3.10 r2c, §3.11 b22-no-run-owner.** The mutant behaviour and the kill hold as described, with the
  corrections below. vy's window was re-derived:
  - `publish` calls `bringInbound(H)` (`EngineDispatch.swift:1026`) after `transition(.verifying)` (`:1022`) and before
    it writes `rerouteOnPass` (`:1039`).
  - The start clears `rerouteOnPass` (`:741`).
  - So `rerouteOnVisit(H)` is `[]` there (`EngineFollow.swift:1141-1144`), and the mutant passes every remaining item.

## Must-fix

**M1. §3.8 (r8): the mutant does not give U X's bytes.**

Under r8 the 429 is decided `.until`. The drain joins U to X, and `replayThrottle` parks X throttled 60 s. U is a user
waiter, so `failFast` answers it `serverUnavailable(retryAfter: ~60)` at once (`EngineDispatch.swift:476-488`,
`EngineJobs.swift:842-846`). That is the same case it gets under `.exhausted`. U's answer does not separate the mutant.
The `throttled` flag does (correct: false; mutant: true), and so does the group member's outcome. Replacement text:

> r8 test: X (zz-x) downloads for a prefetch-lane waiter P (`downloadingWaiter(x, c, lane: .prefetch)`), with no
> group. Release X's 429 (Retry-After 60, `shortInteractiveRetry`) while U's unlisted join waits, in `sweepFollowsFirst`.
> - Visit-first: U is on X, so the lane is user and the decision `.exhausted`: `throttled == false`, and U and P both
>   get `serverUnavailable`.
> - Under r8: U's join is skipped, so the lane is P's prefetch and the decision `.until`: `throttled == true`, P waits,
>   and X's retry serves P X's bytes (`starts(X) == 2`). U is answered `serverUnavailable` in both: same case, not a
>   kill.
> - The kill is P's answer (1(a)) and `throttled` (R-SYN-5's throttle at arrival, 1(b)), 2/2 in `sweepFollowsFirst`
>   under S3-R26 12.1.

**M2. §3.7 (p7): under the mutant, J gets `serverUnavailable`, not Z's bytes.**

Z's 429 is decided at arrival, while the batch still waits, so the pins are intact and the decision is `.until` under p7
as under correct code. The drain then re-routes J (p7: under K2) onto Z, which is failed with its verdict waiting. The
verdict parks Z throttled, which fails J (a user waiter) fast. The kill still holds, because `.notFound` and
`serverUnavailable` are different cases. Replacement text:

> Under p7, J follows K2 onto Z, whose throttle park answers it `serverUnavailable(retryAfter: ~60)`. The test asserts
> `J == .failure(.notFound)`, which kills p7 2/2 in both orders (1(a)). Do not assert Z's bytes for the mutant.

**M3. §3.6 (b22-no-waiter-owner): the correct-code answers of W1…W4 are wrong.**

Under correct code, Y's 429 throttles the origin for 60 s at arrival (`EngineFailures.swift:353`). W1…W4's job on Z is
created in the drain and gated only at the drain's end, so it parks throttled and fails the four user waiters fast. This
is the precedent of rr21-T12's `.movedOn` (`EngineFollowBarrierRerouteOwnerTests.swift:126-133`). Under the mutant
there is no throttle, and W1…W4 get Z's bytes. Replacement text:

> Visit-first, in both orders: `throttled == true`, P gets Y's 24 bytes after the retry, W1…W4 get `serverUnavailable`
> (behind the origin's throttle, as rr21-T12 `.movedOn`), W5 gets `.cancelled`, and K gets O's 16 bytes. Under the
> mutant (`sweepFollowsFirst`): `throttled == false`, P gets `serverUnavailable(retryAfter: 60)`, and W1…W4 get Z's
> bytes.

Also settle UNCONFIRMED 3 from the code: a `.removal` spends no drain id. `replayRemoval` (`EngineFollow.swift:1008-1015`)
does not touch `drainIDsLeft`, and `.removal` does not end a drain batch (`endsDrainBatch`, `EngineFollow.swift:1763-1769`).
So `moved: 5` is enough: the first turn makes zz-a1…zz-a4 and leaves zz-a5's item owed.

**M4. §3.4 (f7): the kill is racy in `followVisitedFirst`, and answer 1 does not apply.**

The state (a delisted id that the publication captured) arises in both orders, so S3-R24 item 3's 2/2 in both orders
stands (S3-R26 item 12's answer 1, last sentence).

The race: in `followVisitedFirst`, `followOwed` is false at the commit. The mutant's `holdForManifest`
(`EngineCatchUp.swift:145-151`) schedules a store re-read. T-R1's `releaser` lets that read's store unit run, and
`manifestCaughtUp` then clears `heldForManifest` (`EngineCatchUp.swift:262-265`). The test reads the set after
`commitOwing` returns, which races that landing. `sweepFollowsFirst` is deterministic, because `followOwed` keeps the
hold until the follow ends. Replacement text:

> f7 test: build on T-R1 (`commitHoldsNothingForIDsMovedAway`), with v4 omitting zz-a3. Before releasing O's unit, put
> one apply in flight and hold it: `holdNextApplyFollow()`, then `applyAndFollow` of a manifest with the same ids and a
> changed filler, then await `applyFollowHeld && appliesInFlight == 1`. This is the shape of `capturedRefused`
> (`EngineFollowBarrierRerouteCapturedTests.swift:45-52`). With `manifestCatchUps ≥ 1`, `holdForManifest` inserts
> without scheduling, and nothing clears the set until `releaseApplyFollow()`.
> - Read `heldForManifest` after the commit and before the release: `[]` under correct code, `[O]` under f7, in both
>   orders.
> - Then release the apply and assert the answers: W1 and W2 get W's 20 bytes, W3 `.notFound`, K O's 16; no violations.
>
> If the in-flight apply changes the commit's path (UNCONFIRMED), the fallback is this: kill 2/2 in
> `sweepFollowsFirst`, and record the visit-first gap as a residual of S3-R16 item 2, since f7's difference is a hold and
> one re-read (timing only). That fallback needs the orchestrator's ruling, because answer 1 does not cover a state
> visit-first can build.

**M5. §3.12 (r2b): not EQUIVALENT. It is open.**

S3-R19 item 2 needs "no decision, answer or state differs" on every path. The report itself names a production queue
that breaks its arrival-order argument: a take-off batch put back at the head with `layers: []` (`landTakeOff` →
`oweReroutes`, `EngineFollow.swift:632-640`, `:651-659`) ahead of events that have layers.

There the mutant reuses the next layered event's layer, built with `previous = N`. That layer drops a live verdict V
with `deferredAfter ≤ N` from the take-off's first-layer `ends`, which correct code (`previous == nil`) keeps
(`EngineFollow.swift:701-711`). The take-off is non-empty only when a follow was owed at the deferral
(`recordDeferredVerdict`, `EngineFollow.swift:553-561`), so the state is sweep-only, and answer 1's citation route is
available. Replacement text:

> r2b is OPEN, not EQUIVALENT. Its only distinguishing state is a take-off batch at the queue's head (no layers) with a
> later layered event whose last apply N postdates a live verdict V. An apply then lands between two drain turns, and
> the take-off's first layer must hold V in `ends`. It matters only for a take-off item whose entry names V's content.
> Until a test kills it 2/2 in `sweepFollowsFirst` (with answer 1's citation that the take-off is empty when no follow
> is owed), or the state is shown unbuildable, it is blocking under S3-R16 1(e).

The `made` cache stays: its saving is measured (`EngineFollow.swift:687-689`), and it is not a SIMPLIFY candidate. The
report is right on that point.

## Should-fix

1. **§3.1, the mutant scripts after r7's removal.** r6's mutant text (`mut-c4fix.py:42`, `if join.chain != nil, !atEnd {`)
   also contains `!atEnd`. Rewrite it as `if join.chain != nil {`, alongside r7's and r8's. Re-run r6, which was killed,
   in its LANE list after the removal, so that its kill rests on a run of this code (G2). Add 2 runs to the estimate.
2. **§3.11, UNCONFIRMED 1, settled from the code:**
   - `settleRun(.cancelled)` (`EngineCommands.swift:973`, then `EngineRuns.swift:748-757`) resumes `awaitRunSettlement`.
   - `runSteps` returns `.failed(.cancelled)` with no further await (`EngineRuns.swift:259-266`).
   - `performRun` calls `finishRun` (`:117-121`), which sets `run = nil` (`:828`).
   - `stageOwedRun` holds no run settlement (`EngineFollowBarrierRerouteRunTests.swift:49-74`).

   So the state arises. The test must await `$0.state.run == nil`, not only `settlement != nil`: until then
   `state.run?.token == item.token` still passes (`EngineFailures.swift:867-870`). Drop the "UNREACHABLE candidate"
   fallback.
3. **§3.9 (vy).** State explicitly that the follow's follow-up turns stay held from T's 429 until H's release.
   `makeInboundNow` schedules a follow-up whenever a move is still owed (`EngineFollow.swift:1482-1484`), and that turn
   would make the zz-h3 move while H still downloads, so the state would never arise. The step-5 `#require` catches it,
   but the hold is part of the shape.
4. **§3.5.**
   - Prefer extending T-A3 (`shutdownAnswersTheOwedCallersWithTheCommitsAnswers`) with a 600-caller argument over a new
     test. It already holds the follow-ups and shuts down.
   - The drop-mutant gives `[600 + jobs freed]`. That is `[600]` only because C's job was retired at the commit. Assert
     `slices == [512, 88]` exactly.
   - The SIMPLIFY alternative's "about 20 ns per waiter, 0.2 ms at 10,000" is not measured. It adds work to
     `drainEverything`'s single turn, which already sorts the waiter keys. If anyone takes it, the shutdown turn must be
     benched. The test route is the right one.
5. **§3.3.** Under `.prefetchWaiters`, also record W3's answer (X's bytes) and the job set after the replay. The
   `#require` at the purge ends a no-kind run, but say in the test that W1 and W2 are leaked under the mutant by design.
6. **§0, the table.** For r8, the class of the difference is 1(a) on P and 1(b) on R-SYN-5's throttle at arrival, not on
   U. For f7, the "Kills in" column is "both orders, with an in-flight apply" (M4). For r2b, the class is OPEN (M5).
7. **§4, the estimate.** Add r6's re-run (2 runs). Add 1-2 h for f7's in-flight-apply shape. Move r2b from "report,
   0.5 h" to "build or argue, 4-6 h", since M5 makes it blocking. New totals: about 24-30 h of writing, 28-30 mutant
   runs, and one gate run.

## What the ruling must add

1. **r2b is open and blocking under S3-R16 1(e) (M5).** The fixer builds the take-off-at-head test in
   `EngineFollowBarrierRerouteTakeOffFixture.swift`, killed 2/2 in `sweepFollowsFirst` with answer 1's citation, or
   argues in the draft that no take-off item's entry can name a later verdict's content, citing every writer of
   `rerouteFor` and the take-off's ids. "EQUIVALENT in arrival order" is not accepted.
2. **f7 needs 2/2 in both orders (M4).** State whether the in-flight-apply shape is required, or whether the
   sweep-first-only fallback is accepted as an S3-R16 item 2 residual for this one branch.
3. **§1's default-tuning case** (a lane-dependent backoff length that fails another user fast from the third attempt;
   UNCONFIRMED 6). Rule whether this is S3-R16 item 2 ("which lane's backoff policy applies") or a probe-first 1(a)
   item. The report leaves it open.
4. **The removal texts.** Use these, so the doc and invariant edits are not left to taste:
   - `EngineFailures.swift`: delete `:834` and the `!atEnd` conjunct at `:840`. Replace `:829-833` with: "The lane is
     read only at a downloading job's 429 (`throttled`), never at an attempt's end, so no pin of this job holds a
     waiting join: a chained join reaches it only where the engine's copy maps its id here."
   - `EngineFollow.swift`: delete `:882-884`. Replace `:876`'s last sentence with: "While its record waits, the job is
     present, failed and at the record's epoch (`invariantViolations()`), so the replay checks the record only."
   - `EngineCommands.swift`, after `:2283`: add the clause `verdictsAfterFollow.filter { self.state.jobs[$0.key]?.epoch
     != $0.value.epoch }`, reported as "N jobs whose failure verdict waits for a follow are at another epoch". Add one
     `violations(after:)` test that sets the job `.queued`, then bumps its epoch, and expects each clause. That test
     kills both clauses' drop-mutants 2/2.
5. **The corrected expected answers** of M1-M3 replace the report's text for r8, p7 and b22-no-waiter-owner. Each new
   test's first run on unmutated code must be green before its kill counts.

## Order of work (amended)

1. The r7 removal, with r6's and r8's mutant texts updated and r6 re-run.
2. The `replayVerdict` removal, with the epoch clause and the clause test.
3. b23 ×2.
4. The settle slice (on T-A3).
5. f7 with the in-flight apply (M4).
6. b22-no-waiter-owner (M3).
7. p7 + r5 (M2).
8. r8 (M1).
9. vy.
10. r2c.
11. b22-no-run-owner.
12. r2b (M5).

Steps 1 to 4 add nothing to a timed path and can land first, one commit each.
