# D1: what a stalled subscriber costs a 10,000-id commit's turn, and the routes to 8.5 ms

Read-only analysis for ruling S3-R27. Work package WP-F (`ZTronAssetSync`), branch `wp/s3f`, worktree
`.worktrees/s3f`, HEAD `d5b2ab9` (the last code commit is `e599ae1`). Nothing was built, run or measured for this
report. Every figure is either quoted from a log, with its path and line, or is an estimate and marked as one. Code
is cited as path:line at `d5b2ab9`, relative to the worktree. The logs under `.build-s3f/` are untracked files in the
worktree. Files under `.build-orchestrator/` are cited from the main checkout.

## 0. In brief

- **The cost.** A stalled subscriber adds 3.03–3.43 ms to the commit's turn. That is 0.30–0.34 µs per event per
  subscriber, and all of it is in `publishTerminal`'s 10,000 `broadcast` calls (EngineJobs.swift:801-803, then
  EngineEvents.swift:17-40, then SubscriberQueue.swift:112-140).
- **What the cost is made of.** It is hash-table work. Per event and subscriber there are about 3.2 SipHash-ed
  `EventSlot` hashes:
  - the coalescing lookup, which misses;
  - the insert;
  - 1.23 re-hashes, from the slot table's 12 doublings.

  On top of that:
  - one hashed in-place access to `subscribers`;
  - allocating and first touching about 2.6 MB of tables;
  - the `order` append.

  The following cost nothing:
  - the rate limiter;
  - coalescing beyond the lookup;
  - per-event allocation;
  - per-subscriber sequence numbering.
- **How much the model explains.** The model accounts for 168–295 ns of the measured 303–343 ns. The rest is
  unattributed, because no profile of this turn exists.
- **Route (a)** makes publishing cheaper without changing any order or content:
  - one hash per terminal publish;
  - one `reserveCapacity` per subscriber per commit;
  - one access per subscriber per commit.

  It needs no ruling and adds no branch overall. Estimated saving: about 1.7 ms per subscriber (central). With one
  stalled subscriber the turn would be **8.55–8.91 ms central** on the quietest measured base (range 7.95–9.70).
  That is at the edge, and not reliably below it.
- **(a) + c3 + c1 is the smallest route expected to reach 8.5 ms or less.** c3 and c1 are two cuts in the commit's own
  turn that do not depend on the subscriber count, worth 0.45–0.85 ms together.
  - One stalled subscriber: **7.70–8.46 ms central** on the c12 base, 8.24–9.00 on gate run 2's busier base.
  - Two subscribers: 9.06–10.18 ms (c12 base), 9.60–10.72 (gate run 2), down from 13.67–14.22. That stays "open, for
    the owner".
- **Route (b)** owes the events past the commit's turn.
  - What it gives: the commit's turn drops to about the `.waiters` figure, 7.2–7.85 ms, for any number of subscribers.
  - What it costs:
    - it reverses a must_not (integrate-c21.md:447) and so needs a new ruling;
    - it needs an argument under H-9;
    - it adds 7–9 branches.
  - No SPEC MUST and no existing test pins "the event before the answer". The follow-ups can keep that order by
    draining a resolution's events before its answers, at about 20 more turns of answer latency.
- **Route (c) alone cannot reach 8.5 ms with a subscriber.** With its safe cuts the turn is 9.45–9.85 ms; with two
  restructures as well, 8.35–9.05.

## 1. The measured figures

The commit's own turn is timed inside the actor (`commitTurnMarksForTests`). Each figure is the best of 3, in ms. The
heartbeat figure (`SyncBench.longestWait`) is 0.005–0.008 ms above the turn, so the gate measures the commit's own
turn. The answer follow-ups never set it.

| Source | `.waiters` | 1 stalled | 2 stalled | Δ, 1st subscriber | Δ, 2nd subscriber |
|---|---|---|---|---|---|
| `2c351e8`, `.build-s3f/c21/each/c12-sort.out:7-11` (load 4.18–4.33, from the task) | 7.268 | 10.300 | 13.730 | 3.032 | 3.430 |
| Gate run 1, `.build-s3f/c21/gates/bench.log:322-341` (1-min load 5.14–7.58) | 7.299 | 10.442 | 13.670 | 3.143 | 3.228 |
| Gate run 2, `.build-s3f/c21/gates-b/bench.log:322-341` (1-min load 5.06–5.25; 15-min 9.3–9.5) | 7.803 | 11.081 | 14.220 | 3.278 | 3.139 |

- **Per event.** The Δ divided by 10,000 events gives **0.303–0.343 µs per event per subscriber.** The figure is linear
  in the subscriber count: the second subscriber costs about what the first does.
- **Same path, other measurements.**
  - The R-SYN-12 ratio test measures a whole sync with 10,000 `assetRemoved` events. With nobody subscribed against
    one stalled subscriber, it reads 8.252 → 11.771 ms (`gates/bench.log:178`) and 9.585 → 12.773 ms
    (`gates-b/bench.log:178`). That is +3.52 and +3.19 ms, or 0.32–0.35 µs per event.
  - `groupStalledSubscriber` takes the same per-event path with one interest: 8.706 (`c12-sort.out:9`), 8.684
    (`gates/bench.log:331`) and 9.442 ms (`gates-b/bench.log:331`).
- **The base varies by 0.54 ms between runs.** `.waiters` measured 7.27–7.81 ms across the three runs. A design whose
  one-subscriber figure lands near 8.2 ms therefore has little margin on a busy host.

## 2. Question 1: where the ~3 ms go, per event per subscriber

### 2.1 The path of one event to one stalled subscriber

The benchmark is `SyncBench.commitTurn`, BenchSyncCycle21.swift:802-889:
- 10,000 user waiters wait on one job.
- One subscriber registers after the waiters (:854-857) and never pulls.
- The download is released with one `.progress` (:859), so the subscriber's queue holds the replay slots, and
  `lastEmitted` holds `.transfer(s00000)`.
- The ids are 6-character small strings (`"s%05d"`, BenchSync.swift:3862-3866), so copying them retains nothing.

In the commit's turn (EngineDispatch.swift:1081-1100), `committed` calls `resolveAll`, which calls `removeJob`
(EngineJobs.swift:718) and then `publishTerminal` (:719). From there, one event goes through these steps:

1. **`publishTerminal`** (EngineJobs.swift:795-810).
   - It filters each id of `ascending` with `locations[asset] != nil && job.assets.contains(asset)` (:802). This is two
     hashes, paid once per id whatever the subscriber count.
   - Then it calls `broadcast(_:to:)` (:803), with the keys sorted once (:799; step C8).
2. **`broadcast(_:to:)`** (EngineEvents.swift:17-40).
   - It numbers the event (:18-19), once per event.
   - It creates an empty hand-off array (:20), which allocates nothing.
   - For each key it calls `self.state.subscribers[key]?.publish(event, sequence:)` (:22). This is an in-place
     `_modify` on the actor's `state`, under a dynamic exclusivity check. It SipHashes the `UInt64` key, then moves the
     `SubscriberQueue` value out of the table and back in.
   - Then come the metric and hand-off checks (:25-34), the resumes (:36-38, none here) and `notifyObservers()`
     (:39). With no observer registered, `notifyObservers()` is two emptiness checks (EngineCommands.swift:1709-1736).
3. **`publish`** (SubscriberQueue.swift:112-140), on a stalled queue and a new subject.
   - The guards run (:113-122), then `EventSlot(event)` (:123; `.assetAvailable` becomes `.asset(id)`, :60-61).
   - The coalescing lookup `self.slots[slot]` misses (:124).
   - The insert `self.slots[slot] = Live(...)` hashes the slot a second time and grows the table when it is full
     (:135).
   - Then `peakLiveCount` is updated (:136), the event is appended to `order` (:137), and `compactIfNeeded` returns at
     its first check (:138, :172-176).

### 2.2 The parts, estimated

These are estimates (UNCONFIRMED), calibrated on profile-40ms.md §4
(`.build-orchestrator/s3f-c20-analysis/profile-40ms.md:181-190`):
- a `Set<AssetID>` insert costs 62 ns into a growing set and 31 ns into a reserved one;
- a 66-byte `TransferID` hash costs 48 ns, so a 6-character id hashes for less.

The assumed sizes:
- an `EventSlot` key of 24 B stride;
- a `Live` value of 8 + 48 B, using sync.md's "event ≤ 48 B" (docs/design/sync.md:831);
- an `order` entry of 32 B.

| Part | Code | ns per event per subscriber | ms per 10,000 |
|---|---|---|---|
| **A.** The queue's access through `subscribers`: exclusivity begin and end on `state`, UInt64 SipHash, probe, `_modify` move out and back | EngineEvents.swift:21-22 | 25–45 | 0.25–0.45 |
| **B.** The preamble and the slot: `finished`, `.clientShutDown`, empty-with-pending, `EventSlot.init` | SubscriberQueue.swift:113-123, :42-67 | 8–10 | 0.08–0.10 |
| **C.** The coalescing lookup, a miss: one `EventSlot` hash through `String.hash(into:)`, then about 3 probes at the average load of 0.56 | :124 | 25–35 | 0.25–0.35 |
| **D.** The insert: a second hash and probe, uniqueness and capacity checks, writing the key and the 56 B value (two cache lines, in the separate key and value arrays) | :135 | 30–45 | 0.30–0.45 |
| **E.** Slot-table growth. 10,002 live slots need 16,384 buckets at the 3/4 load factor. From 4 buckets the table doubles 12 times, at counts 4, 7, 13 … 6,145. That moves 3 + 6 + … + 6,144 ≈ 12,285 elements, 1.23 per event, each re-hashed. It allocates and first touches about 32,760 buckets × 80 B ≈ 2.6 MB of tables (about 160 pages of 16 KB) and frees 12 superseded tables. | :135 | 50–90 | 0.50–0.90 |
| **F+H.** `peakLiveCount` and the compaction check | :136, :138 | ~5 | ~0.05 |
| **G.** The `order` append, with about 14 geometric reallocations up to about 320 KB | :137 | 10–15 | 0.10–0.15 |
| **I.** `AssetEvent` and `EventSlot` copies into `Live`, the key and the `order` entry | :123, :135, :137 | 5–10 | 0.05–0.10 |
| **J.** Cache displacement: the queue writes about 3 MB of fresh memory beside the commit's own per-id working set (waiters, interests, `locations`, `boundContent`, `owedAnswers`) | none | 10–40 | 0.10–0.40 |
| **Sum** | | **168–295** | **1.68–2.95** |
| **Measured** (Δ ÷ 10,000, §1) | | **303–343** | **3.03–3.43** |

### 2.3 What the question names that costs nothing here

- **The rate limiter: 0.** Terminal events go to `broadcast` directly. `offerProgress` (EngineEvents.swift:44-62) sees
  only the release's one `transferProgress` (EngineDispatch.swift:915). `removeJob` retires that key once per
  subscriber (EngineJobs.swift:488-490, then EngineEvents.swift:82-86).
- **Coalescing beyond the lookup: 0.** The commit's ids are distinct and new to the queue, so the replace and move arms
  (SubscriberQueue.swift:125-133) never run.
- **Sequence numbering: 0 per subscriber.** It costs one increment per event, 3–5 ns, paid with or without
  subscribers (EngineEvents.swift:18-19). Per subscriber, numbering is only the 8-byte stores inside D and G.
- **Per-event allocation: 0.**
  - The hand-off array stays empty, so it allocates nothing.
  - The keys are sorted once (EngineJobs.swift:799).
  - `.assetAvailable` is not `indirect` (Sources/ZTronAssetModel/Events/AssetEvent.swift:123-151).
  - The small-string ids retain nothing.

  Allocation happens only at the 12 table doublings and about 14 `order` reallocations, and those are counted in E
  and G.
- **`AssetEvent` copies: 5–10 ns** (part I).

### 2.4 How well the model fits

The parts add up to 168–295 ns against the measured 303–343 ns, so between a few per cent and about half of the cost is
unattributed. The likely places are:
- hashing through the non-inlined `Hasher.combine(bytes:)` and `String` paths, which are among the top self-time
  functions in the profiled shapes (profile-40ms.md:144-172);
- the real cost of a 16 KB page fault;
- part J.

There is no profile of this turn. §4's probe settles it.

## 3. Question 2: the routes, ranked

The ranking weighs four things:
- whether the current rulings allow the route;
- whether it changes any order or content;
- how many branches it adds;
- the figure it reaches.

Throughout, **"central"** means the unattributed cost scales with the modelled parts. **"Range"** runs from the
optimistic reading (the unattributed cost goes with the removed parts) to the pessimistic one (it all stays).

### Rank 1: route (a), a cheaper publish that changes no order or content

All three changes are in WP-F's files: SubscriberQueue.swift, EngineEvents.swift and EngineJobs.swift.

#### a1. One hash per terminal publish (SubscriberQueue.swift:123-139)

```swift
let slot = EventSlot(event)
if slot.isProgress, var live = self.slots[slot], !self.finished, !SubscriberQueue.isAnotherRun(event, than: live.event) {
    live.event = event
    self.slots[slot] = live
    return (nil, true)
}
let replaced = self.slots.updateValue(Live(sequence: sequence, event: event), forKey: slot) != nil
self.peakLiveCount = max(self.peakLiveCount, self.slots.count)
self.order.append((sequence, slot))
self.compactIfNeeded()
return (nil, replaced)
```

| Case | Today | With a1 | Hashes, today → a1 |
|---|---|---|---|
| Progress, live, same run | replaced in place, keeps its sequence, returns `(nil, true)` (:125-128) | the same, in the first arm | 2 → 2 |
| Progress, live, another run | a new `Live` at the tail, append, compact, `(nil, true)` (:130-133) | `updateValue` gives `replaced == true`; `peakLiveCount` unchanged; append, compact | 2 → 2 |
| Progress, none live | insert, peak, append, compact, `(nil, false)` (:135-139) | `updateValue` gives `false`; the same | 2 → 2 |
| Terminal, live | a new `Live` at the tail, `(nil, true)` (:130-133) | `replaced == true`; the same | 2 → **1** |
| Terminal, none live (the commit's case) | insert, `(nil, false)` (:135-139) | `replaced == false`; the same | 2 → **1** |

- **Why it is equivalent.**
  - `peakLiveCount` is raised after every insert (:136), and only an insert raises `slots.count`. So
    `peakLiveCount ≥ slots.count` always holds, and raising it after a replacement changes nothing.
  - In the progress arm, `!self.finished` always holds, because only `.clientShutDown` sets `finished` (:116-118) and
    its slot is terminal. The condition is kept as today.
- **Saving.** Part C: 25–35 ns, or 0.25–0.35 ms per stalled subscriber.
- **Branches: −1.** The live-terminal arm (:130-133) and the insert arm (:135-139) merge.
- **Mutants.**
  - Flipping `replaced` to `false` is killed by `subscriberQueueOrder`'s `moved.coalesced`
    (Tests/ZTronAssetSyncTests/Engine/EngineUnitTests.swift:21).
  - Flipping it to `true` (a fresh publish reported as coalesced) is killed by no test today. The same holds for
    today's :139, because no test reads `coalesced == false` or `eventsCoalesced`. T-A-1 below closes this.

#### a2. One slot-table growth per subscriber per commit

- **The change.** `slots.reserveCapacity(slots.count + n)` runs once per subscriber per batch, inside a3's
  `publishAll`. Without a3, it runs once per key before `publishTerminal`'s loop (EngineJobs.swift:799-803).
- **Why calling it per commit is safe.** `Dictionary.reserveCapacity` sizes the table to a power-of-two bucket count,
  so calling it per commit stays geometric (amortised O(1)).
- **`order` must not be reserved per commit.** `Array.reserveCapacity` allocates exactly what is asked, so repeated
  small commits would reallocate `order` every time. The critic's `reserveCapacity(slots:order:)`
  (`.build-orchestrator/s3f-c20-analysis/critic-commit-window.md:112`) should drop `order`. `append` already grows it
  geometrically.
- **It changes capacity only.** The take order, `liveCount`, `peakLiveCount` and `storedOrderCount` are unchanged.
  - Over-reservation is bounded by the commit's ids, which are subjects, so H-9's "bounded by keys and subjects"
    (sync.md:831) holds.
  - Capacity never shrinks today either: the same table is reached by insertion inside the same turn.
- **Saving.** The re-hashes and moves of part E (31–43 ns), plus about half of E's allocation, first-touch and free
  cost (8–20 ns), give 39–63 ns, or 0.39–0.63 ms per subscriber.
  - The calibration is the measured 62 → 31 ns for `Set<AssetID>`, which has 16 B buckets. `[EventSlot: Live]` moves
    about five times the bytes.
- **Branches: 0.** Dropping the call gives an Equivalent mutant (capacity only), as critic-commit-window.md:112
  already records. Record it under S3-R19 item 2. It is pinned by `commitTurns(.waitersStalledSubscriber)` and
  `commitTurns(.groupStalledSubscriber)` (BenchSyncCycle21.swift:138-154).
- **Already ruled.** It is the contingency already ruled for `groupStalledSubscriber`
  (`.build-orchestrator/s3-rulings-s3f.md:524`, :526; integrate-c21.md:375).

#### a3. One access per subscriber per commit, on one publish path

```swift
// SubscriberQueue: `publish` each of `events` with sequences first, first + 1, …, after one table growth for all of
// them; the queue ends as after one `publish` each. At most the first event is handed off.
mutating func publishAll(_ events: some Collection<AssetEvent>, from first: UInt64)
    -> (handOff: (CheckedContinuation<AssetEvent?, Never>, AssetEvent)?, coalesced: Int) {
    self.slots.reserveCapacity(self.slots.count + events.count)          // a2
    var handOff: (CheckedContinuation<AssetEvent?, Never>, AssetEvent)?
    var coalesced = 0
    var sequence = first
    for event in events {
        let published = self.publish(event, sequence: sequence)
        sequence += 1
        coalesced += published.coalesced ? 1 : 0
        if let continuation = published.handOff {
            handOff = (continuation, event)
        }
    }
    return (handOff, coalesced)
}

// EngineEvents.swift:17-40 becomes:
func broadcast(_ event: AssetEvent, to keys: [UInt64]) {
    self.broadcastAll(CollectionOfOne(event), to: keys)
}

func broadcastAll(_ events: some Collection<AssetEvent>, to keys: [UInt64]) {
    let first = self.state.lastEventSequence + 1
    self.state.lastEventSequence += UInt64(events.count)
    var handOffs: [(CheckedContinuation<AssetEvent?, Never>, AssetEvent)] = []
    for key in keys {
        guard let published = self.state.subscribers[key]?.publishAll(events, from: first) else { continue }
        self.state.metrics.eventsCoalesced += published.coalesced            // was a branch (:25-27)
        if let handOff = published.handOff {                                 // as :28-34
            handOffs.append(handOff)
            self.state.metrics.eventsDelivered += 1
            if let queue = self.state.subscribers[key], queue.finished, queue.isEmpty {
                self.state.subscribers[key] = nil
            }
        }
    }
    for (continuation, event) in handOffs { continuation.resume(returning: event) }
    self.notifyObservers()
}

// publishTerminal (EngineJobs.swift:799-808): the ids once, then one batch.
var announced: [AssetID] = []
announced.reserveCapacity(ascending.count)            // a fresh local array: an exact reserve is right here
for asset in ascending where locations[asset] != nil && job.assets.contains(asset) {
    announced.append(asset)
}
let generation = self.state.generation
self.broadcastAll(announced.lazy.map { .assetAvailable($0, generation: generation) }, to: keys)
// .failed: self.broadcastAll(job.assets.sorted().lazy.map { .assetFailed($0, error, .nextRun) }, to: keys)
```

- **Why it is equivalent.**
  - Queues are independent, so visiting them subscriber by subscriber instead of event by event cannot change any
    queue's content or order.
  - The sequences are the same numbers, because no other publication runs inside `publishTerminal` (C8's premise,
    EngineEvents.swift:14-16).
  - The metrics are sums.
  - A hand-off goes to the same subscribers, in key order, with the first event.
  - Resumed continuations run only after this turn, because `pull` is engine-isolated (EngineEvents.swift:146-172).
    So resuming them after the batch, instead of after event 1's loop, cannot be observed.
  - The removal of a finished, empty queue (:31-33) cannot fire for an asset event, because only `.clientShutDown`
    sets `finished`.
  - A single event takes the same code through `CollectionOfOne`, so there is one path and no allocation.
- **The one difference.**
  - **Observers.** They are evaluated once per batch instead of once per event. Every test predicate that was grepped
    is monotone over a batch: the only `bufferedEvents ==` predicate is `== 0`, in `cancelledSubscriberIsRemoved`
    (Tests/ZTronAssetSyncTests/Engine/EngineEventsTests.swift:146), which no commit reaches. A predicate that is true
    only in the middle of a batch would stop firing. That every `waitUntil` and `awaitCondition` predicate is monotone
    is UNCONFIRMED.
  - **Capacity only:** a single event reserves `count + 1`. On a queue that is exactly full, this can grow the table
    one doubling before a later insert would have. It never changes content.
- **Saving.**
  - Per subscriber: part A (25–45 ns) and part of B (3–5 ns), or 0.28–0.5 ms.
  - Independent of the subscriber count: the per-event broadcast overhead at S=0 (10–19 ns), less the id array
    (5–10 ns). Net −0.05 to −0.1 ms.
- **Branches: net 0 to +1.**
  - The coalesced branch (:25-27) becomes arithmetic: −1.
  - The `if let` that collects the hand-off inside `publishAll` is new: +1. Every test whose consumer waits on an
    empty queue when an asset event arrives reaches it (the `EventProbe` users,
    Sources/ZTronAssetTestSupport/RecordingFakes.swift:976-1060).
  - `coalesced ? 1 : 0` is killed by T-A-3.
- **Optional, outside the question.** The prune announcements, EngineRuns.swift:386-391 and EngineCatchUp.swift:226,
  call `broadcast(_:)`. It sorts the keys on every call (EngineEvents.swift:10-12), which allocates once per event.
  `broadcastAll` over the pruned ids would fix that too, and would also improve the R-SYN-12 ratio.

#### Tests and pins for (a)

S3-R23 item 3 asks for one deterministic test and one BenchSync case per bound. (a) adds no bound, so the existing
pins carry its figure.

- **T-A-1 (unit, a1).**
  - Setup: publish `assetAvailable(a)`, then `(b)`, then `assetFailed(a)`.
  - It checks:
    - the take order is `b`, then `a`;
    - the first publish reports `coalesced == false` and the third reports `true`;
    - `liveCount == 2` and `peakLiveCount == 2`.
  - It kills "drop `slot.isProgress`" (then `a` would keep its first place) and both flips of `replaced`.
- **T-A-2 (unit, a3, equivalence).**
  - Setup: seeded sequences (SplitMix64, as in `subscriberQueueBound`, EngineUnitTests.swift:46-63) of terminal and
    progress events, retires and takes. One copy goes through `publishAll` and another through one `publish` per event.
  - It checks that the two queues have identical `take()` sequences, `liveCount`, `peakLiveCount`,
    `storedOrderCount`, coalesced counts and hand-off.
  - It includes a queue with a pending pull, where only the first event is handed off.
- **T-A-3 (engine, a3), `arguments: LaneDropVisit.allCases`.**
  - Setup: a commit of 3 ids with two subscribers, one waiting on an empty queue and one stalled.
  - It checks:
    - the waiting subscriber gets the first id's `assetAvailable`, then the other two, in ascending order;
    - the stalled queue holds all three, in ascending order;
    - `metrics.eventsCoalesced` counts one re-announced id;
    - `eventsDelivered` counts the hand-off.
- **Existing pins.**
  - `commitTurns`, all four shapes (BenchSyncCycle21.swift:138-154): gated at 10 ms best of 3. The setup check at :148,
    `buffered >= 10_000`, is unchanged.
  - `commitTwoStalledSubscribersTurns` (:159-173): recorded.
  - `pruneAnnouncementTurns` (Tests/ZTronAssetKitBenchmarks/BenchSync.swift:297-315), and the R-SYN-12 ratio test.
  - `stalledSubscriberIsBounded` (EngineEventsTests.swift:20-64) and `subscriberQueueBound`.

#### Figures for (a), with the arithmetic

- **Removed, in the model:** a1 25–35 + a2 39–63 + a3 28–50 = **92–148 ns per event per subscriber.**
- **Left, in the model:** B 5 + D 30–45 + E's first touch 11–27 + G 10–15 + F+H 5 + I 5–10 + J 10–40 = 76–147 ns.
- **Left as measured, per subscriber, at 10,000 ids:**
  - optimistic, the model's remainder: 0.76–1.47 ms;
  - **central, proportional:** 45–50 % of 3.03–3.43 ms, or **1.36–1.72 ms**;
  - pessimistic, the measured Δ less the modelled removal (3.03–3.43 − 0.92–1.48): 1.55–2.51 ms.
- **One stalled subscriber** = base − 0.075 + remainder. **Two** = base − 0.075 + 2 × remainder.

| Base (`.waiters`) | 1 stalled, central | 1 stalled, range | 2 stalled, central | 2 stalled, range |
|---|---|---|---|---|
| c12, 7.268 | **8.55–8.91** | 7.95–9.70 | **9.91–10.63** | 8.71–12.21 |
| Gate run 1, 7.299 | 8.58–8.94 | 7.98–9.73 | 9.94–10.66 | 8.74–12.24 |
| Gate run 2, 7.803 | 9.09–9.45 | 8.49–10.24 | 10.45–11.17 | 9.25–12.75 |

- **`groupStalledSubscriber`** (8.68–9.44 today) drops to about 6.8–7.0 ms (c12 and gate run 1) and 7.6–7.8 ms (gate
  run 2), central. That clears the shape S3-R26 had left to `reserveCapacity` alone.
- **Risks.**
  - The size of the unattributed share decides whether (a) alone reaches the edge.
  - Observers are evaluated once per batch.
  - Reserving `order` per commit would be quadratic.
  - There is now one shared path for every broadcast. T-A-2 guards it.

### Rank 1, completed: (a) with cuts in the commit's own turn, from (c)

The `.waiters` commit turn has already shed most of profile-40ms.md's classes
(`.build-orchestrator/s3f-c20-analysis/profile-40ms.md:84-93`):

| Class | In this turn |
|---|---|
| Transfer-id formatting | None. `committed` classifies by `sameTransfer`, and only unbound ids (EngineDispatch.swift:1145-1152). |
| Jobs-table access | O(1) per commit (EngineDispatch.swift:1128-1143; EngineJobs.swift:692, :717-718). |
| Sorting | None in this turn. The binding is sorted at EngineDispatch.swift:1058, before the publication's await, and `publishTerminal` walks `ascending`. |
| Manifest lookups | Unbound ids only. |
| `decisionNow()` copy | Not on the waiter path: only `deliver`'s `.system` arm (EngineJobs.swift:641). |
| `retireProgress`/`removeJob` | Part of c1. |
| Other Set and Dictionary work, and "everything else" (retain/release, malloc/free) | What remains. c1, c3, c7 and c4 are its pieces. |

The `.waiters` base modelled at S=0 is UNCONFIRMED: it accounts for 3.0–4.7 ms of the measured 7.27 ms.

| Part | Code | ms |
|---|---|---|
| `bind` | EnginePresence.swift:61-70 | 0.35–0.5 |
| The interest pass | EngineDispatch.swift:1143-1162 | 0.5–0.8 |
| Delivery to 10,000 waiters, owed | EngineJobs.swift:704-716, :600-620 | 0.9–1.5 |
| Freeing the interests when `resolveAll` returns | | 0.3–0.6 |
| `removeJob`'s `lastEmitted` lookups | :488-490 | 0.25–0.38 |
| `publishTerminal`'s filter and empty broadcasts | :799-808 | 0.7–0.9 |

The candidates:

| Cut | Change | Saving (estimate) | Branches | Kill and pin | Verdict |
|---|---|---|---|---|---|
| **c3** | In `publishTerminal` (EngineJobs.swift:802): `let allBound = locations.count == ascending.count`, then the filter `(allBound \|\| locations[asset] != nil) && job.assets.contains(asset)` | 1 hash per id: **0.2–0.35 ms**, at any subscriber count | +1 | Forcing `allBound` to `false` is Equivalent; pinned by `commitTurns`. Forcing it to `true` announces an unbound id still in `job.assets`; T-ORDER should kill it (EngineCommitWindowTests.swift:18-79: 8 ids, the store binds 7, zz-o5 unbound). UNCONFIRMED in both visit orders: it depends on zz-o5 still being in `job.assets` at the commit. `Job.assets` is "every asset bound at publication" (EngineState.swift:786-787) and grows only at EngineJobs.swift:175 and EngineMoves.swift:350. | **Take**, with (a) |
| **c1** | In `removeJob` (EngineJobs.swift:484-490): when `lastEmitted.count < job.assets.count`, walk `lastEmitted`'s `.transfer` keys filtered by `job.assets.contains`; otherwise keep today's walk | **0.25–0.5 ms**. design2-commit-window.md:311 estimates 0.5 ms. | +2 | Per design2 :311, the mutants that retire `.run` or another job's slots need new tests. T-C1-1: two jobs with progress and a run's progress; removing one retires exactly its own `.transfer` key, in `lastEmitted`, `trailing`, the heap and each subscriber's slot. The arm choice is Equivalent. It needs a BenchSync case with many progress keys and many removals in one turn, or the O(k)-per-removal risk stays unpinned (UNCONFIRMED that one exists). | **Take** if (a) + c3 measures above 8.5 ms |
| c7 | Deferred deallocation: `resolveAll` parks its `job` copy in the state, and a follow-up turn drops it | 0.3–0.6 ms. design2 :313 estimates "about 0.6 ms of frees". | +1–2 | An invariant clause ("parked jobs have a follow-up"); shutdown releases them | Reserve |
| c4 | Fuse `committed`'s pass with `resolveAll`'s delivery | about 0.5 ms (design2 :314) | Restructures `resolveAll` for one caller | Re-route order risk | Reserve |
| c6 | `guard !keys.isEmpty` at `publishTerminal`'s top | 0.7–0.9 ms at S=0 only. Helps `.waiters` and `manyGroups` (9.16–9.48), **not** S ≥ 1. | +1 | Equivalent: only `lastEventSequence` and the observer passes change | Optional, outside the question |
| c2 | Skip `committed`'s unbound pass on counts | — | — | **Unsafe**: in a reachable state it answers `.notFound` (design2 :312; analyse-state-cost.md Q1) | Reject |
| c5 | Skip `bind` when the prune would drop it | 0.4–0.6 ms | — | The commit's own re-routes and `answerPresent` read `boundContent` in the same turn (design2 :308) | Reject |

**Figures, central (range in brackets).**

| Route | 1 stalled, c12 base | 1 stalled, gate run 1 | 1 stalled, gate run 2 | 2 stalled, c12 base | 2 stalled, gate run 2 |
|---|---|---|---|---|---|
| (a) + c3 | 8.20–8.71 | 8.23–8.74 | 8.74–9.25 | | |
| **(a) + c3 + c1** (c = 0.45–0.85) | **7.70–8.46** (7.10–9.25) | 7.73–8.49 | 8.24–9.00 | 9.06–10.18 | 9.60–10.72 |

### Rank 2: route (b), the commit's terminal events owed past its turn, as one FIFO

**Shape.** Everything is internal: no public or package signature changes (S3-R6).

- **State.** Beside `owedAnswers` (EngineState.swift:119-138):
  - `owedEvents: [OwedEvent]`, with a head index, a follow-up key and a held test seam;
  - `enum OwedEvent { case publish(AssetEvent, upTo: UInt64), retire(EventSlot) }`.
  - `upTo` is `lastSubscriber` at owing time. Keys are monotonic (EngineEvents.swift:116), so a subscriber that
    registers later never receives events from before its registration (design2-commit-window.md:307).
- **Owing.** `publishTerminal` (EngineJobs.swift:795-810) appends its events when the resolution owes, that is, when
  it has more than `answersPerTurn` interests or events.
  - The threshold leaves untouched the tests that read queues directly: T-ORDER (8 ids),
    `commitAnnouncesNoIDItsJobNoLongerHolds` (EngineCommitWindowTests.swift:90-163, 2 ids),
    EngineFollowBarrierRerouteAnnounceTests.swift:79-85, and T-PG3's injection (EngineCommitWindowTests.swift:377-380).
- **Joining.**
  - `broadcast(_:to:)` (EngineEvents.swift:17-40) appends while the FIFO is not empty. That keeps the global order: a
    later `assetRemoved` of an owed id ends last in a stalled queue, which is design2 :307's objection, answered.
  - `retireProgress`'s per-subscriber retire (EngineEvents.swift:82-86) appends `.retire(slot)` while the FIFO is not
    empty. Without it, an owed `transferProgress` would re-create a retired slot and break P3
    (EngineCommands.swift:1962-1967).
- **Drain.** A follow-up modelled on `answerFollowUp` (EngineJobs.swift:749-772):
  - `guard isRunning`;
  - at most `answersPerTurn` entries a turn. Better: `answersPerTurn / max(1, subscribers)`, because a turn's cost
    grows with events × subscribers;
  - each publish goes only to keys ≤ `upTo`;
  - it reschedules while entries remain;
  - it needs a `// REENTRANCY:` row (C3).
- **Shutdown.** The FIFO is flushed before `clientShutDown` (EngineLifecycle.swift:533), like `drainEverything`'s
  owed answers (EngineShutdown.swift:57-60). A flush in one turn is again about 3 ms per subscriber at 10,000 ids, so
  it may have to be sliced.
- **Invariants.**
  - An `answerViolations`-like clause (EngineCommands.swift:1976-1990): the head lies within the table, and owed events
    imply a scheduled follow-up.
  - P1–P3 (EngineCommands.swift:1954-1967) are restated to cover owed retires and owed progress.
  - The order bound (:1870) is unaffected.
- **Benchmark.** `commitUnanswered` (BenchSyncCycle21.swift:894-896) must also wait for owed events. Otherwise
  `buffered` is read before the drain, and the setup check at :148 fails.
- **Introspection.** Keep `owedEvents` out of `EngineIntrospection`, which is a package type (EngineSupport.swift:63-101).

**Does a SPEC MUST or an existing test pin "terminal event buffered no later than its waiter's resume"? No.**

- **The SPEC.** R-SYN-12 (SPEC.md:237) covers bounded buffering, newest-wins progress, rate limits and "terminal
  events never dropped". Nothing in the R-SYN list (SPEC.md:225-245) orders events against answers. H-9 is SPEC.md:33.
- **Today the order holds by construction, not by any pin.** `resolveAll` queues the owed answers (EngineJobs.swift:
  704-716) and then publishes (:719) in the same turn. The answers are resumed in later turns.
- **The tests.**
  - The tests that read queues directly pin "buffered in the turn that removes the job". They read after
    `awaitCondition { $0.state.jobs[x] == nil }`: EngineCommitWindowTests.swift:18-79 and :90-163, and
    EngineFollowBarrierRerouteAnnounceTests.swift:79-85. Their commits are below the threshold.
  - `EventProbe.next(where:)` waits for a match (RecordingFakes.swift:976-1060), so timing cannot affect it.
  - The owed-answer tests read no events: EngineOwedAnswersTests.swift:122-240. They set `answersPerTurn = 4` at :39,
    so they would owe events under (b).
  - UNCONFIRMED: five Kit suites subscribe and were not read line by line: ObservabilityTests, FacadeUnitTests,
    EventContinuityModelTests, FacadeReopenTests and FacadeLifecycleTests.

**Can the follow-ups keep "an id's terminal event is published no later than its answer is resumed"? Yes.**

- **How.** The drain publishes all of a resolution's owed events before it resumes any of that resolution's owed
  answers. Either the answer follow-up waits while those events are owed, or one FIFO of owed work places the
  resolution's events before its answers.
- **The cost.** The first owed answer moves from the first follow-up turn to after ceil(10,000 / 512) = 20 drain
  turns. That is about 4–10 ms more latency per caller at one or two subscribers.
- **Interleaving per id is not an option.**
  - It would need the answers in ascending id order: a sort of 10,000 ids, 3.01 ms in the commit's turn
    (profile-40ms.md:187).
  - Or it would need the events in table order, which breaks S3-R26 answer 2's ascending order
    (s3-rulings-s3f.md:659).
- **If the ruling drops the property** (nothing pins it), the two follow-ups run side by side and answer latency is
  unchanged.

**Conflicts that need a ruling.**
- integrate-c21.md:447, "Do not defer the broadcasts or the binding", is bound to step 6 (s3-rulings-s3f.md:504).
  design2-commit-window.md:307 kept the FIFO "only as a fallback".
- H-9 and sync.md §10.4 (sync.md:831) require a bound "independent of time and of event volume". The FIFO holds
  uncoalesced events while it is not empty, so it is bounded only by the ids of resolutions not yet drained plus the
  events published meanwhile. Either coalesce inside the FIFO, or rule that bound acceptable.
- S3-R16's list of non-blocking differences names answer timing, not event timing. Event timing between the two
  `LaneDropVisit` orders would need adding to it.

**New branches: about 7–9.**
1. Owe or publish now.
2. Join while not empty.
3. Retire through the FIFO.
4. `guard isRunning`.
5. The per-turn cap and the reschedule.
6. The `upTo` filter.
7. The held seam.
8. The shutdown flush.
9. If the order is kept, the answer follow-up's wait for owed events.

Each needs a deterministic test that kills its drop-mutant 2/2. The tests, all with `LaneDropVisit.allCases`:
- the per-turn bound, through a seam (S3-R23 item 3);
- the global order (`assetRemoved` after an owed `assetAvailable`);
- the registration stamp;
- the retire through the FIFO, keeping P3;
- `clientShutDown` last;
- event before answer, per id;
- the invariants report owed events that have no follow-up.

The BenchSync cases: `commitTurns`, with its window extended to the drain, and a drain-turn case at two subscribers.

**Figures.**
- **The commit's turn** is about the base, ±0.05 ms. Appending 10,000 events to the FIFO, 0.08–0.15 ms, replaces the
  empty broadcasts, 0.10–0.19 ms. That gives **7.2–7.3 ms (c12 base), 7.25–7.35 (gate run 1) and 7.75–7.85 (gate
  run 2), for one or two subscribers.**
- **Drain turns:** 512 × (subscribers × 0.30–0.34 µs + about 0.02 µs). That is 0.16–0.18 ms at one subscriber and
  0.32–0.36 ms at two, over 20 turns. About half that with (a) in the drain.
- **The answers' turns** stay at about 0.5 ms (EngineJobs.swift:727-731).
- **The last event** reaches the subscriber about 20 turns later than today.

**Risks.**
- It needs a new ruling, the H-9 argument and the S3-R16 addition above.
- It adds state that crosses turns, with new invariant clauses and a REENTRANCY row.
- Answer latency grows if the order is kept.
- The shutdown flush has its own C2 cost.
- `bufferedEvents` lags during the drain: tests waiting on `>= k` still pass, and no `== k` predicate meets a commit.

### Rank 3: route (c) alone

- **Safe cuts, c1 + c3 (−0.45 to −0.85 ms).** One stalled subscriber: 10.300 → **9.45–9.85** (c12) and 11.081 →
  10.23–10.63 (gate run 2).
- **Adding c4 and c7 (−0.8 to −1.1 ms more), two restructures:** **8.35–9.05** (c12).
- **Two subscribers:** 13.730 → 11.8–13.3 (c12, all four cuts).
- **Verdict.** Not the smallest route. The per-subscriber 3 ms stays, so it alone cannot reach 8.5 ms.

## 4. Question 3: recommendation

1. **Land (a) and c3 in one step.**
   - a1: one `updateValue` on the terminal path of `publish`.
   - a2: one `slots.reserveCapacity` per subscriber per batch. Never reserve `order` per commit.
   - a3: `broadcastAll` and `publishAll` as the one publish path, with `publishTerminal` publishing its ids as one
     batch.
   - c3: skip `locations[asset] != nil` when `locations.count == ascending.count`.

   All of this is in WP-F's files, needs no ruling, and changes no order or content. The net branch count is 0 to +1.
   The tests are T-A-1, T-A-2 and T-A-3, and T-ORDER for c3 (confirm the kill, or add a direct test).
2. **Add c1 if `waitersStalledSubscriber` is still above 8.5 ms,** with T-C1-1 and a BenchSync case for its arm
   choice. c7 is the next lever.
3. **Measure first, once the verifiers' C2 runs are done.**
   - A scratch probe, not committed, like PROBE-C21-PURGE-PARTS. It times 10,000 distinct terminal publishes into one
     fresh `SubscriberQueue` four ways: today's `publish`, a1, a1 + a2, and `publishAll`. This settles parts C, D and E
     and the unattributed share.
   - Then `commitTurns(.waiters)` and `commitTurns(.waitersStalledSubscriber)` after each step, best of 3, at a
     1-minute load of 10 or less.
4. **Decision rule.** Success is `waitersStalledSubscriber` at 8.5 ms or less, best of 3, at a 1-minute load of 10 or
   less.
   - Equivalently: after (a), the per-subscriber Δ must be at most 8.5 − the new `.waiters`. That is about
     1.75–2.15 ms on the c12 base after c3 + c1 (8.5 − (7.268 − 0.075 − 0.45..0.85)), and 1.2–1.6 ms on gate run
     2's base.
   - If (a) + c3 + c1 still misses, the remainder is the pessimistic reading. Only (b) then reaches 8.5 ms, and (b)
     needs a ruling that lifts integrate-c21.md:447 for the commit's terminal events.
5. **The two-subscriber figure.**
   - (a) + c3 + c1 takes it from 13.67–14.22 ms to about 9.1–10.2 ms (c12 base), or 9.6–10.7 ms (gate run 2): at C2.
     It stays "open, for the owner" (s3-rulings-s3f.md:664).
   - Only (b) makes it independent of the subscriber count, at about 7.2–7.85 ms.
   - The facade subscribes once per app event consumer (critic-commit-window.md:179; ClientLifecycle.swift:252,
     :328). So the subscriber count is the app's choice, which is the owner's question.

## 5. UNCONFIRMED

1. **The parts of §2.2.**
   - There is no profile of this turn. Between a few per cent and about half of the measured 303–343 ns is
     unattributed.
   - The bucket sizes are assumptions: an `EventSlot` stride of 24 B; `Live` of 56 B, using sync.md:831's "event
     ≤ 48 B"; an `order` entry of 32 B.
   - The page-fault cost per 16 KB page is assumed.
2. **The savings and figures** of a1, a2, a3, c1, c3, c4, c7 and (b), which rest on §2.2. The three readings of the
   unattributed share give the ranges.
3. **The standard library's behaviour**, taken from its design and not checked in this toolchain's sources: a single
   probe in `updateValue`, power-of-two growth in `Dictionary.reserveCapacity`, and the exact size from
   `Array.reserveCapacity`.
4. **The S=0 composition of `.waiters`:** 3.0–4.7 ms modelled against 7.27 ms measured.
5. **Whether T-ORDER kills c3's forced-arm mutant in both `LaneDropVisit` orders.** It depends on zz-o5 still being in
   `job.assets` at the commit.
6. **The store contract `locations.keys ⊆ binding`.** It is confirmed where `bindRecords` builds the map
   (Sources/ZTronAssetStorage/Store/AssetStore+References.swift:258-282). `placeAndBind` was not read.
7. **Whether any `waitUntil` or `awaitCondition` predicate relies on being evaluated in the middle of a batch.** Only
   the `bufferedEvents ==` predicates were grepped.
8. **The heap's tie order** after c1 retires keys in a different hash order.
9. **Whether a BenchSync case exists** with many live progress keys and many job removals in one turn, which c1's arm
   choice would need.
10. **That no Kit facade test pins event-before-answer.** The five suites that subscribe were not read line by line.
11. **(b)'s details:** the branch count, the cost of a drain turn, the C2 cost of the shutdown flush, and whether the
    FIFO must coalesce to satisfy H-9.
12. **c7's share of frees:** 0.3–0.6 ms.
