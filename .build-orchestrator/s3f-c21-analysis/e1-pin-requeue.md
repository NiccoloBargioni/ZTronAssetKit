# E1: correct #1, the pin after an ENOENT re-queue (analysis for S3-R27 item 12)

Code: `.worktrees/s3f`, branch `wp/s3f`, HEAD `d5b2ab9`; every `path:line` is at `d5b2ab9`. I built, tested and ran
nothing. The only measured figures are the correctness verifier's, in
`.build-orchestrator/s3f-probes-c21/PROBE-C21C-PIN-ENOENT-404.log` (two rounds per case, the same both times). Every
other claim comes from reading the code, and is labelled "code reading" or "estimate". Process note: one read-only
`sed` ran with a `cd` into the worktree, against the task's rule. It changed nothing, and every other command used
`git -C` or absolute paths.

## 1. The mechanism (confirmed)

The shape is rr21-T8b's (`EngineFollowBarrierRerouteRequeueTests.swift:24-147`):

1. O's commit owes the re-routes of zz-a1…zz-a3 under K0, which maps them to X's content. With owe=true this is a
   batch (site 1). With owe=false in `sweepFollowsFirst` it is three joins deferred with chains (R18, log:6, 8).
2. K1's adoption (`adoptApplied`, EngineJobs.swift:1183-1186 → `layerOwedReroutes`, EngineFollow.swift:691-721) adds
   the layer `L1 = (outgoing: K0, ends: {X: e})`, because X is verifying (`publishingEnds`, :725-733). K1's follow
   then runs `appliesFollowed += 1` (:48) in the same synchronous call (EngineRuns.swift:369/:393;
   EngineCatchUp.swift:223/:229).
3. X's claim finds ENOENT for the cancelled attempt's file. `publicationFailed` runs `recordPublicationEnd`
   (EngineDispatch.swift:1259), giving `attemptEnd = (failedAfter: n, deferredAfter: nil)` with n equal to
   `appliesFollowed` after K1. Then the ENOENT arm (:1274-1283) runs `transition(.queued)` and `enqueue` at the same
   epoch e, with no re-route. Nothing starts X again behind the barrier, since the pump is barred.
4. At the replay, `rerouteListing` (EngineFollow.swift:774-779) or `joinListing` (:785-790) calls `followLayers`
   (:794-820), with the entry from K0 naming X. The pin check at :800-809 sees:
   - `L1.ends[X] == e`;
   - `jobs[X]` at epoch e, in state `.queued`, with its end still recorded;
   - no `reroutePinCommits[(X, e)]`, whose only writer is `committed`, EngineDispatch.swift:1133.

   `waitingTarget(X, epoch: e)` returns nil from its `.queued` arm (:1581-1582), and the missing commit record makes
   `return nil` at :806-808. The caller follows the engine's copy, K1, onto W's content, and W's job is created at the
   replay (log:2, "W's job true").

Visit-first does something else here. Its re-route at O's commit joined the pair to X while X published. K1's visit
passed X (RR-14), and the ENOENT re-routed nothing (D-13), so the pair rode X's fresh attempt, and that attempt's
outcome answered it. The engine answers with W's outcome instead. The two agree only when X's fresh attempt commits,
because X's commit under K1 re-routes the pair to W. That is rr21-T8b's case, and the reason `58b278e` left the pin
alone. Its message says the pin's `waitingTarget(_:epoch:)` "is unchanged (rr21-T8b)", and that commit fixed only the
move's arm (:1562-1564) and `rerouteOnVisit`'s `.queued` arm (:1153-1157).

Measured with X's fresh attempt failing with a 404 (log lines 1-9):

| order | owe | path | W1…W3 | V2 | W requested |
|---|---|---|---|---|---|
| followVisitedFirst | false | the reference: the commit re-routes at once | notFound ×3 | notFound | no |
| followVisitedFirst | true | batch → `rerouteListing` | ok(20 B) ×3 | notFound | yes |
| sweepFollowsFirst | false | chained joins → `joinListing` (code reading: the probe's `pinned` reads batches only) | ok(20 B) ×3 | notFound | yes |
| sweepFollowsFirst | true | batch → `rerouteListing` | ok(20 B) ×3 | notFound | yes |

The probe's `#expect` (`VerifyC21CorrectPinENOENTProbes.swift:200`) compares owe=true with owe=false within one
order, so only the followVisitedFirst case recorded an issue (log:5). In `sweepFollowsFirst`, owe=false goes through
the broken pin too. Its break comes from comparing the logged answers with the reference row, and that comparison is
mine. K got 16 B in every case, and no case broke an invariant.

The root cause is answer 6.3's premise. S3-R26 item 12's answer 6.3 (`s3-rulings-s3f.md:680-685`) says "the
reference had re-routed the pair at that end". That is true of a commit and of a supersede. It is false of an ENOENT
re-queue. So the claim that this "equals the reference" with no apply between fails even with zero applies.

## 2. The verifier's fix, steps 1-5

**Step 1 (the test)** is right. It needs three additions: K's 16 B, X holding zz-a1…zz-a3 and zz-x after the replay,
and `violations.isEmpty`. As T-E1 it takes `arguments: LaneDropVisit.allCases, [false, true]`, which is two
collections, the most `@Test` takes. Three of its four cases are red on `d5b2ab9` (measured via the probe). The
(followVisitedFirst, false) case is the reference's own path. It never reaches the fix, and it pins the reference's
answers.

**Step 2 (the keep predicate)**, `job.state == .queued && job.attemptEnd?.failedAfter == appliesFollowed`, is right
when no apply has come since the end.
- `failedAfter == appliesFollowed` means no layer was adopted after the end. Every copy adopted while events wait is
  followed in the same synchronous call. The launch adoption (EngineLifecycle.swift:399) has no follow, but no event
  waits then.
- `.queued` at the layer's epoch, with the end recorded, has two sources: the ENOENT arm, or T20 (`relane`'s failed
  arm, EngineJobs.swift:307).
- Write the nil case as `?.failedAfter ==`, which is false for nil, and add no branch of its own (2c351e8's argument).

What X can be doing at the pin check, by code reading:

| X at the pin check | predicate | visit-first | verdict |
|---|---|---|---|
| ENOENT re-queued, no apply since | keep | rides X | right |
| ENOENT re-queued, an apply since | drop | that apply's visit moved it, as met queued (`rerouteOnVisit`) | step 3's case |
| T20 re-queued in its bookkeeping (deferredAfter nil) | keep | T20 only if the reference's join also came in the bookkeeping | siblings 1 and 2 (§3), wrong either way |
| `.blocked` at e | drop | rides X | sibling 3: no reachable park behind the barrier (only the pump parks a queued job) |
| superseded or removed after the end | drop | moved at that visit | T-E4 below |
| committed again, a second ENOENT, a new epoch | n/a | n/a | unreachable: X cannot start behind the barrier |

So the `.queued` conjunct's drop-mutant is Equivalent on every reachable state, and leaving it out keeps `.blocked`
right. The epoch check is Equivalent too, but keep it, as `waitingTarget` does.

**Step 3 as written is wrong, and it is not what visit-first does.** "Continue the walk from that apply's layer as the
commit pin does" hands the entry to the copy at the re-queue. Visit-first never re-routes at an ENOENT. The pair
stays on X until the first visit after the re-queue moves it under that apply's copy. With exactly one apply since,
today's `return nil` already gives that copy, and is exact. Two counterexamples, by code reading, where today's code
is right and step 3 breaks:

- **(a), which is T-E2.** K1 drops zz-a1…a3 while X publishes, and K2 lists them at U after the re-queue. Visit-first
  gives U's bytes, and so does today's code. Step 3 takes K1, which lacks the ids, so it gives T21, `.notFound`.
- **(b).** K1 maps the pair to W, W is publishing at K2's adoption and fails terminally, and K2 maps the pair to U.
  Visit-first gives U's bytes. Step 3 pins W and gives W's error.

How it composes: step 3's serial can go into `reroutePinCommits` itself, and the jump at :810 then works, but with
the wrong entry. Two more shapes separate the variants (code reading):

- **T-E3.** After the re-queue, K2 drops the pair and K3 re-lists it at U. Visit-first: K2's visit gives T21,
  `.notFound`, and U is never requested. Today: nil, then K3, then U's bytes, a D5 break (`integrate-rr21.md:315`).
  Step 3, and a walk-on that keeps the entry X and steps to the next layer, both get it right.
- **T-E4.** T-E3 with K2 also moving zz-x off X. X holds only zz-x (the pair is owed), so K2's visit supersedes X
  (EngineFollow.swift:1177-1178) and `jobs[X]` is nil at the replay. Today, and a walk-on keyed on X's state: nil,
  then K3, then U's bytes; visit-first gives `.notFound`. Only a record kept at the re-queue still sees that end.

**The route: R1, the re-queue kept with its entry.** In the ENOENT arm, while events wait (the same guard as
`committed`, :1132):

```swift
self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: true)
```

In `followLayers`, after `waitingTarget` returns nil (:806-810):

```swift
guard let end = self.state.reroutePinCommits[VerdictKey(transfer: entry.transferID, epoch: epoch)] else { return nil }
let next = Int(end.serial &- serial)            // the first layer adopted after that end (D4)
if end.keepsEntry {                              // re-queued there: the pair rode the fresh attempt
    guard next < layers.count else { return layer.outgoing }   // no apply since
    index = next + 1                             // that apply's visit moved it, as met queued
} else {
    index = next                                 // a commit: the copy in force at it
}
```

- `index` strictly increases, so the walk ends. A `continue` back to `next` would loop if X were ever in that layer's
  ends.
- R1 reads no job state, so it covers T-E1 to T-E4, `.blocked` and a later supersede alike.
- It reuses the record's clears (`endWorldHistory`, :372; shutdown, EngineShutdown.swift:130) and its three clauses
  (EngineCommands.swift:2239-2250). The "still at its end" clause holds, because a re-queued X is not at its end.
- The form is the fixer's choice: a flag on the value, or a sibling map with its own clears and clauses. Record it.

**"There is no layer per commit" does not forbid a serial record.** The commit record is already one, an index into
the existing layers, made under answer 6.3's last bullet. Nothing in R1 adds a layer, so `s3-rulings-s3f.md:449`
("a layer per commit, unless…") is not engaged. Three texts, all ruling texts, are what must be amended:
- answer 6.3's first bullet (:680-681);
- RR-21's "A pin holds only while `waitingTarget(transfer, epoch:)` holds" (:441);
- `integrate-rr21.md`'s D6 (:316-318), its residual (:597), and its must_not (:586, "do not fix … the waitingTarget
  window this cycle"), which S3-R26 item 5 (ii) lifted for the move only.

D6's last sentence, "No new job of a former target is created from an old copy", should be scoped to the commit and
supersede ends. R1's kept pin returns an old copy: it joins X's existing job or, in §3's untraced removal edge, a new
job of X's content, which is the content visit-first's pair rides.

**Callers and orders.**
- `rerouteListing` is reached when the commit owes, in both orders.
- `joinListing` is reached when the commit does not owe, in `sweepFollowsFirst`. In `followVisitedFirst` it is reached
  only by a user join behind an owed batch; T-E1 does not need that case.
- `followedLane` reads both callers (EngineFailures.swift:843 and :876). With R1, a re-queued X's pair no longer counts
  toward a downloading W's 429 lane. That matches the reference, and the lane decides only the retry policy
  (S3-R27 item 5).

**Step 4 (rr21-T8b at :124) is one to one under G3.** The new expectation is just as exact:
`replayed.x == (ids + [xID]).sorted() && replayed.w.isEmpty` ("the replay keeps K1's pin: X's re-queued job holds
zz-a1…zz-a3 and zz-x; W has no job yet"). The answers at :142 (K 16, V2 18, W 20 ×3) do not change: X's fresh attempt
commits under K1 and re-routes the pair to W.
- Two edits the step does not name: the loop at :127 must deliver `(xT, xBytes)` before `(wT, wBytes)`, since W's job
  now appears only at X's commit (in the old order :128 waits until the time limit); and the name (:25) and docs
  (:8-23, "follows the copy then") are rewritten.
- No `MIGRATION.md` entry (cycle 21's own test, not a CDN test); the draft records old and new. rr21-T8b stops killing
  `i5-pin-fold` (s3f.md:6563-6565, :6601): with no apply since, the fold and R1 agree, so the kill moves to T-E2.

**Step 5 (records) is right but incomplete.** See §7, step 5.

## 3. The class

Each cell: the end × the applies between that end and the replay × the outcome of the job that visit-first's pair
rides (X's fresh attempt after an ENOENT; the next target J after a commit or a supersede).

| end | applies | outcome | `d5b2ab9` | R1 |
|---|---|---|---|---|
| ENOENT | 0 | X commits (an apply after the replay is timing) | same (rr21-T8b, by another route) | same |
| ENOENT | 0 | X terminal: 404/410 → notFound (measured); integrity, auth, the store's notFound/assetFailed/unverified/storage, the ENOSPC verdict, a 429 beyond the caps (code reading, EngineFailures.swift:83-213, EngineDispatch.swift:1261-1303) | **break** | covered |
| ENOENT | 0 | transient, retried | same if it ends in a commit; **break** if it ends terminal (retries spent or fail-fast) | covered |
| ENOENT | 0 | the caller's own cancel | `.cancelled` in both (answer 6.1's timing class); a system cancel re-queues, giving the next attempt's row | same |
| ENOENT | 1 | any | same: the engine's copy is the one visit's copy (T-E2) | same |
| ENOENT | ≥2, X kept | an intermediate copy drops the pair, or pins it on a publishing job | **break** (T-E3) | covered |
| ENOENT | ≥1, X superseded by the first visit since | as above | **break** (T-E4) | covered |
| ENOENT | 0, X dropped by a removal replayed before the batch (`sweepFollowsFirst` only; not traced) | any | **break** (W's outcome) | the pin joins a new job of X's content, so the answers equal (UNCONFIRMED) |
| commit | any | any, including the next target's own ENOENT | same (`reroutePinCommits`, PIN-END tests) | same; the nested ENOENT is covered |
| supersede | 0 | any | same: visit-first re-routed at the supersede under the copy then | same |
| supersede | ≥1 | J at an end at a later adoption and J terminal; or an intermediate drop with a later re-listing | **break**, UNCONFIRMED (P-S) | **not covered** |

A supersede with ≥1 apply is exactly the shape that answer 6.3's third bullet says to probe. `PROBE-RR21-PIN-END`'s
`superseded:` argument supersedes O (site 3), never the pinned X, so the pinned job's supersede was never probed. The
draft's claim that it is "exact unless the requeued job publishes again" (s3f.md:5821-5823) has an empty condition,
because nothing publishes again behind the barrier.

**The three UNCONFIRMED siblings** (s3f.md:6604-6607; the first item listed there is correct #1 itself):

1. **The drain's replay of a user join during the read.** `relane`'s guard (EngineJobs.swift:307) holds only for
   `inFollowVisit`, or for a verdict already deferred. A drain replay inside an ENOSPC free-space read therefore
   T20-re-queues X, and its space verdict is skipped. The comment at :308-311 claims the drain's events are covered.
   - The pin's own replay is a member: the batch joins X (failed, its end recorded) with user waiters, which triggers
     T20.
   - **Probe P-1.** rr21-T8b's shape, with X's publication failing `.fileSystem(.noSpace)` and the free-space read
     held; the drain released inside the read; `interactiveRetry.maxAttemptsPerRun = 1`, so the verdict answers
     instead of retrying. Run both orders; the window opens in `sweepFollowsFirst` (S3-R26 answer 1).
   - **Visit-first:** `insufficientSpace` with its figures for the pair and for V2, and X requested once.
2. **`followAfterVerdict`'s joins during the read.** It sets `visitingAfterVerdict` (EngineFollow.swift:855), not
   `inFollowVisit`, so the same guard misses it.
   - **Probe P-2.** Y's verdict deferred; an apply K after it maps Y's user id to X's content while X publishes; X's
     ENOSPC read held; the drain gives Y's verdict inside the read. Run both orders.
   - **Visit-first:** K's visit joined X while it published, so X's ENOSPC verdict answers the id.
3. **`analyse-g4-reach.md` (b)'s park at the same epoch while the barrier holds.** Unlikely, by code reading. Only the
   pump parks a queued job, and the other park callers act on downloading, failed or parked jobs. Under R1 it is moot
   for the pin, but the move's `.queued` arm (:1563) still depends on it.
   - **Probe P-3.** Shape A and rr21-T8b, with a conditions edge or a space sweep replayed between the re-queue and
     the move or the replay, and `#require(state == .queued)` there. Run both orders.
   - **Visit-first:** the id rides X.
   - If it ever shows `.blocked`, that is the move's own finding.

For P-1 and P-2, a different answer is blocking; the route is `relane`'s guard, as an item of its own. `metrics.promotions`
(the draft's fifth entry) changes a metric only, never an answer.

**Probe P-S** (the supersede row). PIN-END's shape with X's own publication superseded: the store holds a manifest
that moves zz-x, as `superseded:` does for O. Two sub-shapes:
- (i) K2, which maps the pair to U, adopted while J (W) publishes, then J's publication fails terminally (wrong
  bytes, an integrity failure);
- (ii) K2 drops the pair, and K3 re-lists it at U.

Run both orders, owing. Visit-first: (i) J's integrity failure; (ii) `.notFound`. `d5b2ab9` and R1, by code reading:
U's bytes in both. If red, the route is to write the commit's record (`keepsEntry: false`) at the `.superseded` arm
(EngineDispatch.swift:1261-1268), since visit-first re-routes at a supersede under the copy then, as at a commit.

## 4. The branches R1 adds, and their kills

The tests are all in `EngineFollowBarrierRerouteRequeueTests.swift`, built from rr21-T8b's fixture, owe=true, in both
orders, unless a row says otherwise.

- **T-E1:** the probe as a test (§2). Red on `d5b2ab9` (measured).
- **T-E2:** K1 drops zz-a1…a3, X's ENOENT, then K2 lists them at U, and X's fresh attempt returns a 404. Visit-first:
  W1…W3 get U's bytes, V2 gets `.notFound`. Green on `d5b2ab9` (code reading).
- **T-E3:** K1 as in rr21-T8b; after the re-queue, K2 drops the pair and K3 lists it at U. Visit-first: `.notFound`,
  and U never requested. Red on `d5b2ab9` (code reading).
- **T-E4:** T-E3 with K2 also mapping zz-x to Y, so that X is superseded. Visit-first: W1…W3 `.notFound`, V2 Y's bytes.
  Red on `d5b2ab9` (code reading).

| branch | mutant | killed by | reached in |
|---|---|---|---|
| the ENOENT arm's write | dropped | T-E1: today's W bytes | owe=true in both orders; owe=false in `sweepFollowsFirst` |
| the write's `!eventsAfterFollow.isEmpty` | forced true | no answer changes; the clause "the follow barrier is down with N commits kept" in any D-13 test that re-queues with the barrier down and checks `invariantViolations()` (the fixer names it), else the twin of `committed`'s own guard | n/a |
| `end.keepsEntry` | dropped (treated as a commit) | T-E1: K1, giving W; and T-E2: K1 lacks the ids, giving `.notFound` | both orders |
| `next < layers.count` | forced true (always keep) | T-E2: K0, giving X, giving `.notFound` instead of U | both orders |
| `next < layers.count` | forced false | T-E1: the engine's copy, W | both orders |
| `i5-pin-fold` (re-run) | `.queued` returns the job in `waitingTarget(_:epoch:)` | T-E2: moved from rr21-T8b | both orders |
| the record, not X's state, decides | replaced by a walk-on keyed on X's state | T-E4: X superseded, giving U's bytes | both orders |

Each kill counts at 2/2 in each order that reaches the branch, after a green first run of the unmutated code in both
orders (S3-R27 item 5's rule). A kill by a hang does not count, which is why T-E1's loop must not wait for W's job.
Optional: a site-3 variant (`superseded:` on O), and a user join behind the batch so that `joinListing` is reached
in `followVisitedFirst`.

## 5. Interactions

- **Item 5.** d4 review's replacement text for :829-833 ("a chained join reaches it only where the engine's copy maps
  its id here") stays true under R1: the walk still only turns the engine's copy away, and R1's keep maps the id to
  the re-queued X, never to the downloading job. r6's and r8's rewritten mutants, p7/r5's pin-end test (a commit end),
  f7 (EngineDispatch.swift:1152) and b22 (:861-870) are not touched. Under p7, a flag-form record is forgotten too; no
  new kill duty, since T-E1 walks before the batch ends.
- **Item 6.** The changes sit on other lines. R1 shifts EngineFollow.swift below :820 by about 8 lines, so the
  `replayVerdict` lines at :876 and :882-884 must be relocated by content. Item 6's epoch clause reads
  `verdictsAfterFollow`, not the record.
- **Item 7.** T-E1 to T-E4 read state after the drain loop with the holds released, as rr21-T8b does at :120-124.
  `RacingSource` delivers only what the test scripts, and a start does not change X's ids, so classify them as d5
  classified rr21-T8b.
- **RR-21's sites.** R1 is in `followLayers`, so it serves every batch (sites 1, 2 and 3) and every chained join the
  same way.
- **Step.** Item 12 is a named S3-R16 1(a) finding, so it goes in item 10's step 1. It lands before item 6's removal,
  which is in step 2 and shares EngineFollow.swift, and before the C2 routes. Keep the mapping "correct #1 → item 12"
  in the draft's status list (item 10).

## 6. C2

All figures here are estimates; I ran no benchmark. The per-layer basis is the cycle-21 fixer's own measurement in
the comment at EngineFailures.swift:829-833: 10,000 joins through two layers added 3.74 ms, about 0.19 µs per
join-layer.

- **The ENOENT turn** gets one dictionary write while events wait, well under 1 µs.
- **Drain turns** (`continueReroutes`, `replayJoin`; at most 512 ids a turn) and **`followedLane` at a 429**: an id
  pinned to a re-queued X goes on past the pin instead of stopping, at most the rest of its walk, O(layers), the bound
  and work of an unpinned id. Worst cases: about 0.2 ms a drain turn (512 ids, two layers) and about 2 ms for 10,000
  such lane items, no more than the no-early-stop walk `lane429WhileOwed` already times.
- No timed case has an ENOENT-re-queued job (per their doc comments), so their paths and figures should not change.
  No new inventory row: `followLayers` stays O(layers) an id, the ENOENT arm gains O(1). Re-measure
  `applyWhileOwedLayers`, `lane429WhileOwed` and `joinChainTurns` under item 9.

## 7. The recommended route

1. **Red first** (item 10, step 1; `d5b2ab9` in place of `8e1fb24`).
   - Commit T-E1 failing on its own. Run it on `d5b2ab9` first (G2): the probe is the verifier's run, not the fixer's.
   - Run T-E3 and T-E4 on `d5b2ab9`. Each one that is red joins that commit. One that is green lands with the fix, and
     its `d5b2ab9` result is recorded.
2. **The fix, in one commit.**
   - R1: the write, the `followLayers` branch, and the type or the map.
   - rr21-T8b's one-to-one change: :124, the loop order at :127, the name and the docs. It must land in the same
     commit, because the old :124 is red under R1.
   - T-E2, green. All four new tests green in both orders.
3. **The kills of §4,** 2/2 per order. Record them in the draft's mutant line, where `i5-pin-fold` moves to T-E2.
4. **The probes P-S, P-1, P-2 and P-3,** both orders, with visit-first's answers as above. A different answer is
   blocking: P-S's route is the commit-shaped record at `.superseded`; P-1's and P-2's is `relane`'s guard. Each red
   one gets its own failing commit, then its fix.
5. **Records.** The code docs at EngineFollow.swift:765-773, :1561 ("An owed re-route's pin keeps the end's own
   window" is now false), EngineState.swift:217-221 and the ENOENT arm's comment (EngineDispatch.swift:1275-1278).
   The draft at s3f.md:5695-5700 (rr21-T8b), :5821-5823 (the residual, and "The records go when the last batch is
   replayed whole", wrong: production clears them at `endWorldHistory`), :6563-6565 and :6601-6607 (the fold's kill;
   the first sibling confirmed and fixed) and :6814-6816 (RR-21's ruling-3 residual). The ruling texts (§2) are the
   orchestrator's.
6. **Hours, estimated.**
   - 5-7 h for steps 1-3 and 5. Basis: T-E1's shape already exists in the probe; d4 §6 costs a pin-end-style test at
     1-3 h; about 1 h of code and docs; about 1 h of mutant runs.
   - Add 3-5 h for step 4's four probes.
   - Any sibling fix is not included.

## What the ruling must say

1. Correct #1 is confirmed and blocking (S3-R16 1(a)): measured, 3 of 4 cases answer W's bytes where visit-first
   answers `.notFound` (PROBE-C21C-PIN-ENOENT-404.log:2, 4, 6-9). It is item 12, at item 10's step 1, red first on
   `d5b2ab9`.
2. Adopt R1: while events wait, the ENOENT arm keeps (X, epoch) with `copySerial`, flagged as a re-queue. With no copy
   adopted since, `followLayers` returns the pinned copy; otherwise it moves the kept entry under the copy adopted at
   the first layer after the re-queue.
3. Reject step 3 as written (the entry handed to the copy at the end): shapes (a), which is T-E2, and (b) break under
   it, and today's code answers both right. A walk-on keyed on X's state misses X superseded after the re-queue
   (T-E4), so it is acceptable only with T-E4 run first, and T-E4 blocks if red.
4. Tests in `EngineFollowBarrierRerouteRequeueTests.swift`: T-E1 (visit × owe, the reference's answers, X holding the
   pair, no request for W), T-E3 and T-E4 committed red if red on `d5b2ab9`, and T-E2 as a green control. Every one
   is green in both orders on the fix before any kill counts.
5. rr21-T8b changes one to one: at :124 X holds zz-a1…zz-a3 and zz-x and W has no job, the loop delivers X before W,
   and the name and docs say the pin holds, while the answers at :142 stay. The draft records old and new; no
   `MIGRATION.md` entry is needed.
6. Kill R1's write, `keepsEntry` and keep branches as §4 lists, 2/2 in each order that reaches them. `i5-pin-fold`'s
   kill moves from rr21-T8b to T-E2.
7. Amend answer 6.3's first bullet, RR-21's "A pin holds only while `waitingTarget` holds", and `integrate-rr21.md`'s
   D6 and its residual: an ENOENT re-queue keeps the pin, since visit-first re-routes only at a commit or a supersede.
   Lift `integrate-rr21.md:586`'s must_not for this fix; "There is no layer per commit" stands, as a kept serial is
   no layer.
8. Run P-S in both orders (X's own publication superseded with a later apply: J at an end with J's terminal failure,
   and an intermediate drop), answer 6.3's own probe never run for the pinned job. A different answer is blocking,
   with the commit-shaped record at the `.superseded` arm as the route.
9. Probe siblings 1 and 2 (T20 during the read, from the drain's replays and from `followAfterVerdict`) in both
   orders; a different answer is blocking, with `relane`'s guard as its own item. Sibling 3 needs only P-3's
   `#require(.queued)` for the move caller, since R1 makes it moot for the pin.
10. Records: the docs at EngineFollow.swift:765-773 and :1561, EngineState.swift:217-221 and the ENOENT arm; the draft
    at s3f.md:5695-5700, :5821-5823 (with the wrong "records go when the last batch is replayed whole"), :6563-6565,
    :6601-6607 and :6814-6816.
11. C2: no new inventory row, since `followLayers` stays O(layers) an id and the ENOENT arm gains O(1). Re-measure
    `applyWhileOwedLayers`, `lane429WhileOwed` and `joinChainTurns` under item 9 (estimate: 0.2 ms or less a drain
    turn).
12. Budget (estimated): 5-7 fixer hours for the fix with its tests, kills and records, plus 3-5 for the four probes.
    Any sibling fix is not included.
