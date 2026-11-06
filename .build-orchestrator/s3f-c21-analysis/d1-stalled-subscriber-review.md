# Review of D1 (`d1-stalled-subscriber.md`): the stalled subscriber's cost in a 10,000-id commit

This is an adversarial, read-only review for ruling S3-R27. Nothing was built, run or measured. Code is cited as
path:line at `d5b2ab9`, relative to `.worktrees/s3f`. The report's figures were checked against the logs:
- `.build-s3f/c21/each/c12-sort.out:7-11`;
- `gates/bench.log` and `gates-b/bench.log`, lines 178 and 322-341.

All of them match. The turn figures it uses lie 0.005 ms below the heartbeats.

## Verdict: CORRECTED

The recommendation stands: route (a) with c3 first, c1 only if needed, and (b) only as the fallback. It is the
smallest route that can reach 8.5 ms with one stalled subscriber. Its order and content argument holds against the
code. It changes no public or package signature, and it needs no new await, state that crosses turns, or unsafe
construct.

Three things in it are wrong or missing, and the ruling must fix them:
1. One claim behind a2's equivalence and cost argument is false for batches that coalesce.
2. The decision rule does not say which figure triggers route (b).
3. One sibling path is left unpinned: the `.failed` arm, which pays the same per-subscriber cost plus a sort of
   10,000 ids.

Four of the report's UNCONFIRMED items can be settled from the code (see "Settled").

## What was checked and holds

- **The per-event path** (report §2.1).
  - `publishTerminal` loops over `ascending` and calls `broadcast(_:to:)` once per id (EngineJobs.swift:799-804).
  - `broadcast` makes one in-place `subscribers[key]?.publish` access per key per event (EngineEvents.swift:17-40).
  - On a stalled queue, `publish` does a lookup that misses (SubscriberQueue.swift:124), a second hashed insert
    (:135), the peak update (:136), the `order` append (:137), and a `compactIfNeeded` that returns at its guard
    (:172-176). That guard is false throughout a 10,000-id batch into a fresh queue: stored order entries are about
    equal to the live slots.
  - The report is right that the rate limiter, coalescing, per-event allocation and per-subscriber numbering cost
    nothing here.
- **A likely source of the unattributed ~40 %.**
  - `AssetID.==` and `hash(into:)` are public and not `@inlinable`, in another module
    (Sources/ZTronAssetModel/Identity/AssetID.swift:56-71).
  - Swift's dictionary stores no hash per bucket, so every occupied bucket on a probe path costs one cross-module
    `EventSlot ==`. Every id in the benchmark is 6 bytes long, so the `utf8.count` guard always passes and the
    comparison goes on to the `String ==` call.
  - At an average load of about 0.56, a miss passes about 2 occupied buckets, and so does the insert.
  - Both a1 and a2 cut this. a2 also lowers the load factor during the batch to an average of about 0.3, because
    the final table is allocated first.
  - So the report's optimistic reading is at least as plausible as its central one (UNCONFIRMED; the probe in its §4
    settles it).
- **a1 is equivalent.**
  - `peakLiveCount >= slots.count` always holds: only the insert arm raises the count, and it updates the peak
    (:135-136).
  - Nothing reaches the progress arm with `finished` set: the guard at :113 returns first, and `.clientEnd` is not
    a progress slot.
  - `updateValue` returns the replaced `Live`, and its release equals today's overwrite.
  - The existing `subscriberQueueOrder` does not kill "drop `slot.isProgress`". Its `a` stays second either way
    (Tests/ZTronAssetSyncTests/Engine/EngineUnitTests.swift:14-31). T-A-1 is needed, as the report says.
- **a3 is equivalent.**
  - The queues are independent.
  - The sequences equal today's: no other publication runs inside `publishTerminal`.
  - Each key gets at most one hand-off per batch: `pending` cannot be set again inside the turn, because `pull` is
    engine-isolated (EngineEvents.swift:146-172).
  - The resumes run in the same key order, and only after the turn.
  - The predicates the report did not grep:
    - `liveCount == 0` (EngineEventsTests.swift:105, :116) is only met by single-event progress publishes, which
      take the `CollectionOfOne` path unchanged;
    - `bufferedEvents >= 1` (EngineIdleTests.swift:192) is monotone.
- **`Array.reserveCapacity` grows to the exact size, so `order` must not be reserved per commit.** This is correct and
  important. A per-commit `order.reserveCapacity(count + n)` reallocates on every commit: O(n) each, quadratic over
  many small commits.
- **(b)'s premises.**
  - No SPEC MUST orders an event against an answer: R-SYN-12 is SPEC.md:237, H-9 is SPEC.md:33.
  - The must_not is real (`integrate-c21.md:447`, "Do not defer the broadcasts or the binding").
  - The shutdown and drain sites are right: EngineLifecycle.swift:532-533, EngineShutdown.swift:57-62.
- **The arithmetic** of the figure tables (report §3) is internally consistent, given its inputs.

## Settled (UNCONFIRMED items closed from the code)

1. **Item 8, the heap's tie order after c1: no effect.** `DeadlineHeap` is a sorted array ordered by
   `(at, sequence)`, where `sequence` is the insertion order (DeadlineHeap.swift:27-28, :50-64). The order in which
   c1 removes keys cannot change which entry fires first.
2. **Item 6, the store contract `locations.keys ⊆ binding`: true on every path.**
   - `performPublish` splits `ids` into `extensionGroups`, which deduplicates them
     (AssetStore+Publish.swift:126, :283-297).
   - The primary group binds through `bindVerifiedFile`, then `placeAndBind`, then `bindRecords`
     (AssetStore+References.swift:152-171, :243). Each other group goes through `bindCopy`, which also ends in
     `bindRecords` or `placeAndBind` (AssetStore+Publish.swift:305-345), and is merged in (:151-156).
   - `bindRecords` writes keys only from its `ids` (AssetStore+References.swift:258-283).
   - `stillBound` only filters (AssetStore+Publish.swift:181-196).
   - So `locations.count == ascending.count` implies that every id of `ascending` is bound. `ascending` is
     `job.assets.sorted()` taken before the publish await (EngineDispatch.swift:1058), so it has no duplicates.
   - The contract is WP-B's and is not written in `publish`'s doc (AssetStore.swift:200-219). See should-fix 4.
3. **Item 5, whether T-ORDER kills c3's forced-true mutant: in `sweepFollowsFirst` only, and that is enough.**
   - In that order the commit applies on arrival, behind the barrier, while zz-o5 is still in X's `job.assets`.
     `subtractAssets` and `setInterest` trim interests, never `assets` (EngineState.swift:903-948). So a forced
     `allBound` announces zz-o5, and `announced == bound` fails (EngineCommitWindowTests.swift:64-65).
   - In `followVisitedFirst`, the visit removed zz-o5 from `job.assets` before the commit, so the mutant survives
     there.
   - The branch's own drop-mutant, "always look up", is Equivalent (S3-R19 item 2).
4. **c1's first arm is reached by T-PG4.** At its commit, `lastEmitted` holds the one key `.transfer(zz-p1)` and the
   job holds three ids (EngineCommitWindowTests.swift:174-230), so `lastEmitted` is the smaller.

## Must-fix

### M1. a2's over-reservation when a batch coalesces

The report says, in a2's "It changes capacity only", that capacity "never shrinks today either: the same table is
reached by insertion inside the same turn". That is true only when every event of the batch is new to the queue.

Take a stalled queue that already holds the batch's subjects: a re-commit of the same ids after a content change, or
an `assetFailed` followed by a retry's `assetAvailable`.
- `reserveCapacity(slots.count + n)` then doubles a table that insertion would never grow. That re-hashes every live
  slot inside the commit's turn: about 10,000 entries, estimated 0.4–0.8 ms (UNCONFIRMED).
- It also doubles that queue's table memory, beyond sync.md:831's figure for a stalled subscriber.
- Today's code pays no growth in that shape, and no pin measures it: every `commitTurns` run starts from a fresh
  queue (BenchSyncCycle21.swift:802-889).

H-9 still holds: the bound is twice the subjects.

Replacement text for the ruling:

> a2: `publishAll` reserves `slots.count + n` only when `slots.count + n > 2 * slots.capacity`, that is, when
> insertion alone would double the table at least twice. Otherwise it reserves nothing: insertion grows the table at
> most once, to the size the reservation would give. The guard's drop-mutant changes only capacity, so it is
> Equivalent (S3-R19 item 2); the draft records the argument. Record a re-announcement shape once, outside the gate:
> `commitTurns(.waitersStalledSubscriber)` with the queue already holding all 10,000 ids' `assetAvailable` from an
> earlier commit, its own turn best of 3 with its load. A miss of `c2Budget` at a load of 10 or less is blocking
> (S3-R16 1(f)).

With the guard, the fresh-queue case the benchmark measures still reserves once. For example, a queue holding 3
slots with a capacity of 3–6 receives n = 10,000.

### M2. The decision rule's trigger for (b)

The report's §4 item 4 says: "If (a) + c3 + c1 still misses, the remainder is the pessimistic reading. Only (b) then
reaches 8.5 ms." It does not say which bar "misses" refers to.

- (b) reverses a ruled must_not and adds 7–9 branches against S3-R16 item 3's "prefer removal".
- The 10 ms bar is the blocking one, and 8.5 ms is the design target.

A fixer that reads "misses" as "above 8.5" would start (b) on, say, 8.7 ms.

Replacement text:

> After (a) + c3, and c1 if needed, `commitTurns(.waitersStalledSubscriber)` at or below 8.5 ms (best of 3, 1-minute
> load ≤ 10) closes D1. 8.5–10 ms is recorded "at the edge" with its loads and is not blocking. It does not start
> (b). Only a figure above `c2Budget` at a load of 10 or less is blocking (S3-R16 1(f)). It is reported to the
> orchestrator with the four per-step figures (today's, a1, a1 + a2, `publishAll`), and (b) needs a new ruling that
> lifts `integrate-c21.md:447` for the commit's terminal events.

### M3. The `.failed` arm is the same per-subscriber cost on an unpinned path

- `publishTerminal`'s `.failed` arm broadcasts one `assetFailed` per id of `job.assets`, after
  `job.assets.sorted()` (EngineJobs.swift:805-808): about 3.0 ms at 10,000 ids (profile-40ms.md §4: 3.01 ms).
- With one stalled subscriber it pays the same 0.30–0.34 µs per event on top.
- S3-R26 answer 4 makes "one subscriber, which may be stalled" the reference set's subscriber count
  (s3-rulings-s3f.md:661). So a 10,000-id resolution that fails at a lane above `.bulk` is inside the reference set.
- No benchmark measures it with a subscriber. The only subscribed benchmarks are BenchSync.swift:1418 and :2475 and
  BenchSyncCycle21.swift:856.
- The nearest figure, `deferBehindVerdictTurns(.notFoundUsers)`, is 6.26 ms with no subscriber
  (`gates-b/bench.log:291`). Whether that turn reaches the `.failed` arm with all 10,000 ids is UNCONFIRMED. If it
  does, one stalled subscriber puts it near 9.3 ms.

a3 covers this arm, and the report already routes it through `broadcastAll`.

Replacement text:

> Add a recorded BenchSync case: 10,000 user waiters on one job that fails at `.userInitiated` (a 404, resolved by
> `resolveAll(.failed)`), with one stalled subscriber, own turn and heartbeat best of 3, with loads. It is measured
> after a3. A miss at a load of 10 or less is blocking (S3-R16 1(f), S3-R25 item 3). The arm keeps its
> `job.assets.sorted()`: ascending order, S3-R26 answer 2 and `integrate-c21.md`'s must_not on iterating a Set.

## Should-fix

1. **c1's saving exceeds the report's own model.** It uses 0.25–0.5 ms from design2:311. Its own `.waiters` model
   puts the cost c1 removes at 0.25–0.38 ms (report §3, the removeJob lookups row), and a cut cannot save more than
   it removes. So c3 + c1 is 0.45–0.73 ms. The one-stalled central figure on the c12 base becomes 7.82–8.46 ms,
   where the report has 7.70–8.46; the upper end is unchanged. Two subscribers: 9.18–10.18 ms.
2. **The exclusivity trap in a3.**
   - The lazy `map` passed to `broadcastAll` is evaluated inside `self.state.subscribers[key]?.publishAll(...)`,
     which is under a modify access to the actor's `state`.
   - So the closure must not read `self.state`. `self.state.generation` inside it is a runtime exclusivity trap.
     The report's code captures `let generation` first, and the ruling should require that.
   - Do not pass a `lazy.filter` either. Its `count` is O(n), and every subscriber would re-run the filter's two
     hashes per id. Build the `announced` array once, as the report does.
3. **T-A-3 is underspecified.** "`metrics.eventsCoalesced` counts one re-announced id" needs a setup that makes one
   id live in the stalled queue before the commit. For example, a held earlier failure leaves `assetFailed(id)`
   unread, then the 3-id commit announces it. Without that setup, the `coalesced ? 1 : 0` mutant is not killed.
4. **c3 rests on WP-B's undocumented contract.** Record under "Proposed document changes" an ARCHITECTURE §4.3
   note: "`AssetStore.publish` returns locations only for ids of `binding`". Also add a sentence to
   `publishTerminal`'s doc comment that names the dependency. If the store ever returned extra keys, c3 would
   announce an unbound id, and only T-ORDER's `sweepFollowsFirst` run would catch it.
5. **"Already ruled" is overstated for a2.** s3-rulings-s3f.md:523/:526 rule `reserveCapacity` as the remedy for a
   `groupStalledSubscriber` miss only. S3-R27 should authorise a2 explicitly for `waitersStalledSubscriber`, with
   M1's guard and without `order`. This replaces critic-commit-window.md:112's `reserveCapacity(slots:order:)`.
6. **c6 (`guard !keys.isEmpty` in `publishTerminal`) is worth taking.**
   - `manyGroups` is at the edge with no subscriber: 9.34, 9.17 and 9.48 ms. a3 removes only the per-event
     broadcast overhead at S=0. The filter's two hashes per id, about 0.5–0.7 ms, stay unless c6 skips them.
   - The guard is Equivalent: no queue exists to compare sequences, and no state changes between `removeJob`'s
     `notifyObservers` (EngineJobs.swift:492) and `publishTerminal`.
   - This is outside D1's question, but cheap. The orchestrator may rule it with D1 or leave it to the `manyGroups`
     work.
7. **The probe's controls.** The scratch probe of report §4 item 3 should also time a1 + a2 into a queue that
   already holds the subjects (M1's shape). Its ids should be the benchmark's 6-byte small strings, plus one run with
   ids over 15 bytes.
   - The benchmark's ids retain nothing (BenchSync.swift:3862-3866).
   - Real ids over 15 UTF-8 bytes are heap strings, and each `EventSlot` and `Live` copy retains them.
   - That cost is not in any figure: UNCONFIRMED, and not blocking.
8. **c1's tests.**
   - T-PG4 already reaches c1's `lastEmitted` arm (Settled 4), so name it beside T-C1-1.
   - T-C1-1 must make `lastEmitted` hold another job's `.transfer` key and a `.run` key. That kills "no
     `job.assets` filter" and "no `.transfer` filter".
   - The arm choice's drop-mutant is Equivalent.
9. **The `publishAll` hand-off branch.** Its drop-mutant is killed in engine tests only by a hang: the waiting pull
   is never resumed. T-A-2's pending-pull case should assert the hand-off directly, so that the kill does not rest on
   a time limit. Do it inside `withCheckedContinuation`, resuming the returned continuation so nothing leaks.

## What the ruling must add

- M1's guard and its recorded re-announcement shape.
- M2's trigger wording.
- M3's `.failed`-arm case.
- Should-fix 5: authorise a2 explicitly for `waitersStalledSubscriber`.
- The order of work and its measurements:
  1. a1, then a2 with its guard, then a3, then c3;
  2. measure `commitTurns(.waiters)`, `.waitersStalledSubscriber`, `.groupStalledSubscriber` and `.manyGroups`, and
     the two-subscriber case, best of 3 with loads, after a3 and again after c3;
  3. c1 only if `waitersStalledSubscriber` is still above 8.5 ms.

  Each step is committed with its figure. The four `publish` variants' probe figures go in the draft.
- **The branches, and how each is killed (S3-R16 1(e)):**

  | Branch | Kill |
  |---|---|
  | a1's compound `if` | T-A-1 (both flips of `replaced`, and dropping `isProgress`) |
  | a2's reserve and guard | Equivalent (S3-R19 item 2) |
  | `publishAll`'s hand-off `if let` | T-A-2 |
  | `coalesced ? 1 : 0` | T-A-3, with should-fix 3's setup |
  | c3's `allBound` | forced true: T-ORDER, `sweepFollowsFirst`, 2/2; dropped: Equivalent |
  | c1's two arms, if taken | T-C1-1 and T-PG4 |

  Run `covdiff` over every changed line (S3-R25 item 10).
- **The two-subscriber figure stays "open, for the owner"** (s3-rulings-s3f.md:664). The expected 9.2–10.2 ms on the
  c12 base and 9.6–10.7 ms on gate run 2's base (UNCONFIRMED) may still miss C2. Each app `events` consumer is one
  engine subscriber (Sources/ZTronAssetKit/Facade/ClientLifecycle.swift:252, :328). Only (b), or an event-shape
  change, makes the figure independent of the subscriber count. An event-shape change is public (S3-R6) and so is
  the owner's call.

## What a one-cycle fixer would most likely land (UNCONFIRMED)

With (a) + c3 + c1 on the c12 base:
- one stalled subscriber: 7.8–8.5 ms central;
- the full range: 7.1–9.3 ms;
- on gate run 2's busier base: 8.3–9.0 ms central.

Below 10 ms is very likely. Below 8.5 ms is likely only on a quiet host. Under M2 a figure of 8.5–10 ms is recorded at
the edge and does not start (b).
