# Design — sync engine and `AssetClient` facade

> **Stage 1, Phase A, drafter (b).** Scope: `ZTronAssetSync` (WP-F) and the `ZTronAssetKit` facade (WP-G).
> **Status:** draft for adversarial review (Phase B). Phase C merges it into `docs/ARCHITECTURE.md` and the ADRs.
> **Owns:** H-3, H-4, H-5, H-8, H-9 · R-SYN-1…16 · R-CAR-1…5, R-CAR-7, R-CAR-8 · R-OBS-1…3 · R-ENV-1 · P-1, P-4, P-7, P-8, P-9, P-12, P-14.
> **Inputs read:** SPEC §1, §4.1, §4.2, §4.5, §5.6, §5.8, §5.9, §6, §7.3; `docs/RECON.md` (§5 especially); ADR-001…011; prior art
> `CDNSyncCoordinator.swift`, `CDNAssetResolver.swift`, `CDNSyncProgress.swift`, plus `CDNLocalStore.swift`,
> `NetworkAvailabilityMonitor.swift`, `CDNProviding.swift` and the three fallback call sites, read only.
> **Standalone package (ADR-006):** nothing outside this repository is written. The sibling repos are prior art only. Every Swift 6
> pattern this design depends on was compiled for `arm64-apple-ios15.0` in `.build-probe-sync/` (§16).

---

## 0. Decisions at a glance

| ID | Decision | Rejected alternatives | Evidence |
|---|---|---|---|
| **D-SYNC-1** (H-3) | One `Job` per asset inside `actor SyncEngine`. Every caller holds an `InterestToken`. Waiters are `CheckedContinuation<Result<AssetLocation, AssetError>, Never>` stored in the actor and resumed **only** through `waiters.removeValue(forKey:)`. A caller's cancellation hops back to the actor through one unstructured `Task` spawned in `onCancel`. The transfer is cancelled when the job's interest set becomes empty. | per-waiter one-shot `AsyncStream`; a shared `Task` whose `.value` everyone awaits; a lock-protected registry | §16 P2: iOS 15 compile, plus 200 seeds × 100 callers at runtime |
| **D-SYNC-2** (H-4) | Three FIFO lanes (`userInitiated` > `prefetch` > `bulk`), one slot reserved for `userInitiated`, in-place promotion of a running transfer through a per-transfer **control stream**, and queue-jumping for a queued job. Preemption with resume data is the fallback when every slot is taken. Bulk work ages ahead of prefetch work. | one global priority heap; a fixed pool per lane; preempt-only | §7 |
| **D-SYNC-3** (H-5) | Every job carries an `epoch` that each `await` re-checks. Store mutations use optimistic concurrency (`expectedGeneration`). No await sits between reading an invariant and acting on it. The REENTRANCY ledger in §5.4 records what each await re-validates. | a single mailbox task that serialises the engine; custom executors (iOS 17+) | §5.4 |
| **D-SYNC-4** (H-8) | `TimeSource` provides wall time, a monotonic clock in `UInt64` nanoseconds, and `sleep(until:) async throws(CancellationError)`. **One** engine alarm multiplexes every deadline. `ManualTimeSource` uses `Synchronization.Mutex` and exists only in tests (`@available(macOS 15, iOS 18, *)`). | `Clock`/`ContinuousClock` (iOS 16); one sleeping task per deadline; an async `now()` | §16 P5 |
| **D-SYNC-5** (H-9) | Pull-based subscriber queues live inside the engine actor and are exposed through `AsyncStream(unfolding:onCancel:)`. Progress is newest-wins per key and throttled at the source to ≤ 10 Hz without a timer. Terminal events are coalesced per subject and never dropped. A subscription is released on cancel, on stream deallocation, or at shutdown. | push `AsyncStream` with `bufferingNewest`/`bufferingOldest`; an unbounded buffer; one shared stream | §16 P4, P9 |
| **D-SYNC-6** | The planner is a pure `static func`. It runs off the actor (`@concurrent`), never derives output order from `Dictionary` iteration, and is O(M + S + F log F). | planning on the actor; incremental planning | §16 P10: 1.74 ms at 10k, ×1.82 when N doubles |
| **D-SYNC-7** | The free-space decision is made on pure data **before the first mutation**. A physical-headroom ledger then admits each fetch individually. | check-as-you-go; reserve-on-dispatch only | §12.1 |
| **D-SYNC-8** | The sync stamp lives in the index and is written only when a run ends `.complete` (prior-art parity). A `purgeEpoch` guard stops a run that finishes after a purge from re-stamping. | stamp on any finished run; stamp in `UserDefaults` (D-6) | §12.3 |
| **D-SYNC-9** | Device conditions arrive as a stream. The watcher task exists **only while there is work**. `NWPathMonitor` is owned by an actor, because its `Sendable` conformance is iOS 17+. | `NWPathMonitor` captured in `@Sendable` closures; a permanent watcher | §16 P3, P7 |
| **D-KIT-1** | `AssetClient.lookup` reads the main-actor snapshot mirror only: O(1), zero I/O. The bundle step of the fallback chain lives in `AssetFallbackChain` behind an injected `BundleLookup`. | bundle lookup inside `lookup`; a bundle index prebuilt in `init` | §16 P11: p99 0.21 µs |
| **D-KIT-2** | `init` stores values and creates actors: no I/O, no `Bundle` reads. `start()` is single-flight and idempotent, and every async API awaits it. | opening the store in `init`; a lazy store open on the first `lookup` | §13.2 |
| **D-KIT-3** | Public async APIs use `throws(AssetError)`. `withAsset` stays untyped because it runs a caller's throwing closure (ADR-004). | untyped `throws` everywhere; returning `Result` | §16 P2 |
| **D-KIT-4** | LRU access stamps accumulate in the main-actor mirror and are drained by the engine before any eviction decision. No task is created per lookup. | one `Task` per lookup; no access tracking on lookup | §13.3 |

---

## 1. Constraints this design must satisfy

- **iOS 15 floor (ADR-005).** Not available: `Mutex`, `OSAllocatedUnfairLock`, Atomics, custom executors, `Clock`/`Duration`, Observation, `Regex`, `URL(filePath:)`. Every primitive used below was compiled for `arm64-apple-ios15.0` (§16).
- **Unsafe budget: 3 escapes in total, including test support; this design uses 0.** All mutable state sits in actors (`SyncEngine`, `AssetStore`), in `@MainActor` classes (`SnapshotMirror`, `PrefetchWindowController`), or in immutable `Sendable` classes with `let` fields only (`PrefetchHandle`, `SubscriptionLease`, `AssetClient`). The only lock is `Mutex` inside the **test-only** `ManualTimeSource`. `Mutex` is not an unsafe-gate pattern, and it compiles at the iOS 15 floor behind `@available(iOS 18.0, macOS 15.0, *)` (§16 P5).
- **Coverage ≥ 90 % for `ZTronAssetSync` and ≥ 70 % for `ZTronAssetKit`.** Every engine line is reachable from macOS through fakes. The seams are `RemoteSource`, `AssetStore` (with `FakeFileSystem`), `DeviceConditionsSource`, `TimeSource`, `RandomSource`, `BundleLookup`, `AppVersionSource`, `AccessLogSource` and `LogTap`. Live conformers in these two targets are tiny and covered (§15.9).
- **No polling, idle silence.** Every wake-up is an event (a transfer update, a conditions change, a caller) or the single alarm. When idle, the engine holds no timer, no task and no observation (§8.4).
- **Prior-art behaviours preserved** (RECON §5):

| Prior art (read) | Preserved as |
|---|---|
| `syncIfNeeded` runs once per app version and marks success only after every asset is present (`CDNSyncCoordinator.swift:65-92`) | `RefreshDecision` (§12.3); the stamp is written only when a run ends `.complete` |
| Reconcile before download (`CDNSyncCoordinator.swift:76-85`) | `SyncPlan.reconcile` is committed in **one** store mutation before any fetch is enqueued (R-SYN-8) |
| `verifyFullyAvailable` (`:105-108`) and `verifyAndRepair` (`:116-125`) | `availability(scope:)` (no network) and `ensureAvailable(scope:)` / `sync(.force)` |
| Progress `idle / upToDate / syncing(fraction, completed, total) / complete / failed(reason)` (`CDNSyncProgress.swift:10-25`) | `AssetEvent.syncProgress` / `.syncFinished` with `SyncOutcome`; the shim mapping is in §10.6 |
| On-demand resolve fetches the manifest only for an **unknown** id and **never reconciles** (`CDNAssetResolver.swift:36-63`, `CDNLocalStore.swift:270-276`) | "Point admission" (§6.5): an unknown id triggers a single-flight conditional manifest fetch and commits that one entry; full reconciliation happens only in runs |
| Candidate-extension filter on the network step (`CDNAssetResolver.swift:46`) | `AssetFallbackChain` (§13.4) |
| Retry-on-connectivity for failed on-demand fetches (`NetworkAvailabilityMonitor.swift`, `ZTronSVGView.swift:168-183`) | R-SYN-13 re-queues parked jobs when the path is satisfied; the UI is told by `.conditionsChanged` (§11) |

- **Defects this design closes:** D-2 (a serial loop aborts on the first failure) → independent jobs and `SyncOutcome` (R-SYN-6); D-8 (a `Task` per progress callback) → newest-wins streams and a pull-based broadcast (R-SYN-12); D-15 (main-thread I/O) → `lookup` reads a value (P-8); D-19 (mutable global `installed`) → an `AssetClient` instance; D-6 (`UserDefaults` stamp) → stamp in the index (R-SYN-9).

---

## 2. Hard problems: decisions with alternatives

### 2.1 H-3 — Single-flight and cancellation

**Problem.** N callers want asset X. One cancels, and the others must be unaffected. The transfer may die only when nobody is left. No waiter may ever be leaked or resumed twice.

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A. Continuations in the actor** *(chosen)* | `join` registers a `CheckedContinuation<Result<…>, Never>` inside the `nonisolated(nonsending)` `withCheckedContinuation` body, which runs synchronously on the actor. `onCancel` spawns `Task { await engine.withdraw(token) }`. Every resume goes through `waiters.removeValue(forKey:)`. | Textbook pattern. Exactly-once is structural: one dictionary, one actor. Relies only on primitives present since iOS 13. Typed errors flow through `Result`. | One short-lived unstructured task per cancellation. The cancelled caller wakes after one actor turn, which is bounded because the engine never blocks (ADR-003). |
| B. Per-waiter one-shot `AsyncStream` | The engine `yield`s the result. A cancelled waiter's `next()` returns `nil` (AsyncStream's own cancellation), then the waiter calls `withdraw` itself. | No spawned task. The cancelled caller wakes immediately. | One stream allocation, with an internal lock, per waiter. Correctness then depends on the **iOS 15.0 runtime's** AsyncStream cancellation, which cannot be verified on this Mac. "Exactly once" is implicit rather than visible in our code. |
| C. Shared `Task<URL, Error>` per asset | Callers `await task.value`. | Trivial. | `await task.value` does **not** return when the *awaiting* task is cancelled, so cancellation is not independent. Rejected. |
| D. Registry behind `NSLock` | A class plus a lock. | Synchronous cancellation. | Needs `@unchecked Sendable`, which burns the escape budget (R-ENV-4). Rejected. |

**Decision: A.** Its pre-cancelled path is closed by a `Task.isCancelled` check *inside* the synchronous body. If the task was cancelled before `join` ran, `onCancel` fires first and its `withdraw` finds nothing, while the body resumes `.cancelled` without registering anything. Both paths were exercised at runtime (§16 P2).
**Consequences.** (1) Cancellation hops are not engine-owned tasks: they finish in one actor turn and are not counted by P-14. (2) Tests wait for hops with the engine's `waitUntil` observation hook (§15.1), never by sleeping. (3) Option B stays documented as the fallback if Phase B finds a flaw in A.

### 2.2 H-4 — Priority

**Problem.** A page the user just opened must overtake a 1 GB bulk sync that is already in flight.

| Option | Pros | Cons |
|---|---|---|
| **A. Three lanes + a reserved interactive slot + in-place promotion + queue jump + preemption fallback** *(chosen)* | A user request almost never waits for a slot: one is reserved. A request for an asset already downloading in bulk is promoted **without restarting** it. A preempted transfer resumes from resume data. | The most moving parts, so it needs the model-based tests of §15.2. |
| B. One global heap ordered by priority, no reservation | Simple. | If every slot holds a 250 MB bulk transfer, the user waits for one of them to finish, so H-4 fails. |
| C. A fixed pool per lane (for example 1 user + 1 prefetch + 2 bulk) | Isolation. | Idle lanes waste capacity, and "concurrency 4" stops meaning 4. |
| D. Preempt-only (cancel a bulk transfer for every user request) | Simple. | Wastes the bytes already received when the server lacks `Range` support, and thrashes on fast swiping. |

**Decision: A** (details in §7). **Consequences:** the transport must honour a priority change within one actor turn and support `pause` with resume data (§3.3). Background-session transfers are migrated to the foreground session when promoted; that belongs to the transport design (H-6).

### 2.3 H-5 — Actor reentrancy

| Option | Pros | Cons |
|---|---|---|
| **A. Epoch-validated jobs, optimistic store generations, a ledger** *(chosen)* | No blocking. Each await has a written invariant, so a reviewer can check them one by one. | Discipline: every new await needs a ledger row (C3), checked in review. |
| B. A single internal mailbox task that processes commands one at a time | No interleaving inside the engine. | It is a permanent task, which breaks P-14. One slow `await` (a store commit) blocks every resolve behind it, which breaks H-4. |
| C. Non-reentrant execution through custom executors | — | iOS 17+ (custom actor executors) and iOS 18+ (task executors); not available at the floor. |

**Decision: A.** Rules: (R1) After every `await`, re-read `self.lifecycle`, and re-read the job from `self.jobs` comparing its `epoch` with the one captured before the await. (R2) Never hold a copy of a `Job` across an await; mutate through `self.jobs[id]`. (R3) Store mutations carry `expectedGeneration` or `expectedFingerprint`, and the store rejects stale ones. (R4) Pure functions (planner, admission, backoff) take value snapshots and return values, so they have no reentrancy at all. The ledger is §5.4.

### 2.4 H-8 — Time and determinism

| Option | Pros | Cons |
|---|---|---|
| **A. `TimeSource` protocol (wall + monotonic `UInt64` ns + `sleep(until:)`), one engine alarm, `ManualTimeSource` on `Mutex` (tests only)** *(chosen)* | Works at iOS 15. Deterministic: one engine sleeper means the wake order is the engine's own `(deadline, seq)` heap order, not task scheduling. Tests advance time synchronously and never sleep (Q-4). | The fake needs a lock → `Mutex` (macOS 15+), so test suites that use it carry `@available(macOS 15.0, *)`. The host is macOS 27; the package floor stays macOS 12. |
| B. Swift `Clock` / `ContinuousClock` / `Duration` | Standard. | iOS 16+. Rejected (C5). |
| C. One `Task.sleep` task per deadline (per retry) | Simple. | Many timers, a nondeterministic wake order under a fake clock, and P-14 cannot be met while any retry is pending. |
| D. `func now() async` so the fake can be an actor | No lock. | Every time read becomes an await, i.e. a reentrancy window, in pure decision code. Rejected. |

**Decision: A** (contract in §9).

### 2.5 H-9 — Backpressure

| Option | Pros | Cons |
|---|---|---|
| **A. Pull-based per-subscriber queues inside the engine; `AsyncStream(unfolding:onCancel:)`; progress coalesced per key and throttled at the source; terminal events coalesced per subject** *(chosen)* | The consumer's pace drives delivery, so nothing piles up beyond one slot per key or subject. Ordering is exactly publication order (§10.3). A stalled subscriber costs a bounded, computable amount of memory (§10.4). | One actor hop per delivered event; a few hundred lines of queue code, fully unit-testable. |
| B. Push `AsyncStream` per subscriber, `.bufferingNewest(k)` | No custom code. | When a subscriber stalls, the *oldest* elements are dropped, and that includes terminal events (§16 P9 shows `.bufferingNewest` discarding every earlier element). `.unbounded` violates "no unbounded queue". |
| C. One shared `AsyncStream` | Trivial. | AsyncStream is single-consumer, so there is no multi-subscriber delivery. |
| D. Combine `PassthroughSubject` | Familiar. | Combine is forbidden in production targets (C6, R-CAR-9). |

**Decision: A** (§10). **Consequence:** "never dropped" is defined precisely as *the latest terminal event of every subject is always delivered, in publication order*. A newer terminal event for the **same** subject supersedes an older one; that is coalescing, and the bound depends on it (§10.4). Phase B should attack this definition (§17).

---

## 3. Components and the contracts this design needs (input to Phase C)

```
           @MainActor                     any isolation                          actors
 ┌───────────────────────────┐   ┌──────────────────────────────┐   ┌──────────────────────────────────────┐
 │ SnapshotMirror            │◀──│ AssetClient (final, Sendable) │──▶│ SyncEngine (ZTronAssetSync)          │
 │  snapshot: AssetSnapshot  │   │  lookup  → mirror (sync)      │   │  jobs, lanes, waiters, interests,    │
 │  accessLog (LRU stamps)   │   │  resolve/prefetch/ensure…     │   │  scheduler(1 alarm), breaker,        │
 │ PrefetchWindowController  │   │  events → engine subscriber   │   │  events (subscriber queues), run     │
 └───────────▲───────────────┘   └──────────────┬───────────────┘   └──┬───────────┬───────────┬──────────┘
             │ publish(snapshot) (store's sink) │                      │           │           │
             └──────────────────────────────────┴──────── AssetStore (actor, Storage) │ RemoteSource │ DeviceConditionsSource
                                                                                       (Transport/Apple tier, Model protocol)
 Environment: TimeSource · RandomSource · FileSystem · BlockingExecutor · AppVersionSource · BundleLookup · LogTap
```

The engine talks to Transport and AppleHosted **only** through Model protocols (SPEC §4.1). The facade is the only composition root.

### 3.1 Model contracts this design defines (proposed, exact)

```swift
// ZTronAssetModel — time & randomness (R-ENV-1, H-8). Full semantics in §9.
public struct MonotonicInstant: Sendable, Hashable, Comparable, Codable {
    public let nanoseconds: UInt64
    public init(nanoseconds: UInt64)
    public func adding(seconds: TimeInterval) -> MonotonicInstant          // saturating; negative clamps to +0
    public func seconds(since earlier: MonotonicInstant) -> TimeInterval  // 0 when earlier > self
}
public protocol TimeSource: Sendable {
    func now() -> Date                                                     // wall clock (persisted stamps, LRU)
    func monotonicNow() -> MonotonicInstant                                // keeps counting during device sleep
    func sleep(until deadline: MonotonicInstant) async throws(CancellationError)
}
public protocol RandomSource: Sendable {
    func makeGenerator() -> any RandomNumberGenerator & Sendable           // engine owns the mutable copy
}

// ZTronAssetModel — priority, scope, conditions.
public enum AssetPriority: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
    case bulk = 0, prefetch = 1, userInitiated = 2
}
public enum AssetScope: Sendable, Hashable, Codable {                      // R-CAR-5: values only, no closures
    case all
    case identifiers(Set<AssetID>)
    case tags(Set<String>)
    case prefix(String)
}
public struct NetworkConditions: Sendable, Hashable { public var satisfied, expensive, constrained: Bool }
public enum ThermalLevel: Int, Sendable, Hashable, Comparable { case nominal, fair, serious, critical }
public struct PowerConditions: Sendable, Hashable { public var lowPowerMode: Bool; public var thermal: ThermalLevel }
public struct DeviceConditions: Sendable, Hashable { public var network: NetworkConditions; public var power: PowerConditions }
public protocol DeviceConditionsSource: Sendable {
    /// Event-driven, never polled: the first element is the current state and later elements arrive on change.
    /// Terminating the stream (iterator cancelled or dropped) stops the underlying observation.
    func conditions() async -> AsyncStream<DeviceConditions>
}
```

### 3.2 What the engine requires from `AssetStore` (storage designer, Phase C to reconcile)

| Call (engine view) | Required semantics |
|---|---|
| `open() async throws(StoreError) -> AssetSnapshot` | Lock (R-STO-9), load or rebuild the index, migrate legacy data (H-10), run launch reconciliation (R-CLN-7) and staging GC. Publishes the first snapshot to its sinks. |
| `var snapshot: AssetSnapshot` | The latest committed snapshot, read-only. |
| `freeSpace() async throws(StoreError) -> FreeSpace` | One `volumeAvailableCapacityForImportantUsage` read through `FileSystem`, off the main thread, plus the store's used bytes and resolved budget. |
| `apply(_ step: ReconcileStep, eviction: EvictionPlan?, expectedGeneration: UInt64) async throws(StoreError) -> AssetSnapshot` | **One** atomic index commit. Throws `.staleGeneration` if the generation moved. Blob deletions are deferred until the snapshot is published and the grace window has passed (I-3). |
| `evictionPlan(toFree: Int64, protecting: Set<AssetID>, now: Date) -> EvictionPlan?` | Pure over snapshot, leases and access stamps (R-CLN-4). `nil` when the target cannot be reached. |
| `stagingSlot(for: TransferID) -> StagingSlot` | A path under `staging/` owned by that transfer (I-4). |
| `verify(_ staged: StagedFile, expecting: ExpectedContent) async throws(StoreError) -> VerifiedBlob` | Size, then a streaming hash off the pool, then the atomic publish of an **unreferenced** blob (R-STO-3, R-INT-1/2/6). |
| `commit(_ blob: VerifiedBlob, for entry: ManifestEntry, expectedFingerprint: EntryFingerprint, urgency: CommitUrgency) async throws(StoreError) -> AssetSnapshot` | Flips the index entry. Throws `.staleEntry` if the applied manifest's fingerprint for that id changed. Group commit for `.background` (P-5); immediate flush for `.interactive`. |
| `recordStamp(_ stamp: SyncStamp, ifPurgeEpoch: UInt64) async throws(StoreError)` | Writes the stamp unless a purge happened since the run began (§12.3). |
| `purge(_: PurgeRequest) async throws(StoreError) -> PurgeResult` | Clears the stamp in the same commit (R-CLN-6). |
| `recordAccesses(_: [AssetID: Date])`, `quarantine(_: AssetID, fingerprint:)`, `lease`/`release` | R-CLN-4, R-INT-3, R-CAR-8. |
| `nextDeadline() -> MonotonicInstant?`, `collectGarbage(until: MonotonicInstant) async -> GCReport` | GC grace deadlines are **driven by the engine's single alarm**, so the store owns no timer (P-14). |
| `close() async` | Flush, unlock (R-SYN-15). |

`AssetSnapshot` must offer, in O(1) or as precomputed values: `generation`, `appliedManifest` (entries in manifest order plus an id → index map), `record(for:)` (present / stale / needsHeal / quarantined(fingerprint), blob checksum and bytes, a precomputed `AssetLocation`, policy, tags, `verified`), `hasBlob(checksum:)` for dedupe, `usedBytes`, `stamp`, and an **ordered** record sequence for deterministic iteration.

### 3.3 What the engine requires from `RemoteSource` (transport and Apple-tier designers)

```swift
public protocol RemoteSource: Sendable {
    var originID: String { get }                                           // circuit-breaker / throttle key
    func fetchManifest(ifNoneMatch etag: String?) async throws(TransferError) -> ManifestFetchResult   // .notModified | .fetched(Data, etag)
    /// Starts (or re-attaches to) one transfer. `control` is read by the transport: `.setPriority(p)` takes
    /// effect within one turn (URLSessionTask.priority, R-NET-10); `.pause` cancels producing resume data and
    /// ends the update stream with `.paused`. Dropping/cancelling the returned stream's consumer cancels the
    /// transfer and discards partial bytes. Buffering is `.bufferingNewest(1)`; the last element is always terminal.
    func transfer(_ request: TransferRequest, control: AsyncStream<TransferControl>) async -> AsyncStream<TransferUpdate>
    func reattachedTransfers() async -> [ReattachedTransfer]               // H-6 hook, consumed once by start()
}
public enum TransferControl: Sendable, Equatable { case setPriority(AssetPriority), pause }
public enum TransferUpdate: Sendable, Equatable {
    case progress(received: Int64, expected: Int64?)
    case staged(StagedFile)                    // terminal: complete bytes in the staging slot
    case paused(resumable: Bool)               // terminal: after .pause
    case failed(TransferError)                 // terminal
}
```

Why a **control stream** rather than an `async func setPriority`: the engine promotes inside the synchronous body of `join`, which cannot `await`. Yielding into an `AsyncStream.Continuation` is synchronous, ordered, `Sendable`, and needs no spawned task. With `.bufferingNewest(1)` priority changes coalesce correctly: only the latest priority matters.

`TransferError` (R-NET-6) must at least distinguish `offline`, `transient`, `server(status)`, `throttled(retryAfter)`, `notFound`, `forbiddenAmbiguous` (403 on an object), `authRejected` (401, or 403 on the manifest), `tooLarge`, `sizeMismatch`, `insufficientSpace`, `cancelled`. §8.1 maps each one to an engine action.

---

## 4. The planner (R-SYN-1, R-SYN-8, R-SYN-11 assessment, P-4)

### 4.1 Signature

```swift
// ZTronAssetSync/Planning/SyncPlanner.swift
public enum SyncPlanner {
    /// Pure and deterministic: same inputs ⇒ an equal plan, in any process (no Dictionary iteration feeds the output).
    public static func plan(
        manifest: ValidatedManifest,     // Model: R-MAN-2-validated; `entries` in manifest order + `index: [AssetID: Int]`
        snapshot: AssetSnapshot,         // Storage: applied manifest, per-asset records, blob set, generation
        scope: AssetScope,               // which entries this run fetches (relocations/prunes are catalog-wide)
        policy: PlanningPolicy,          // allowUnverifiedAssets, includeOnDemand, reserve, budget, unknownSizeEstimate
        freeSpace: FreeSpace             // volume available, store used bytes, resolved budget
    ) -> SyncPlan

    /// The engine's entry point: runs `plan` off the engine actor (C2) on the global concurrent executor.
    @concurrent static func planOffActor(_ input: PlanInput) async -> SyncPlan
}

public struct SyncPlan: Sendable, Equatable {
    public let baseGeneration: UInt64            // snapshot generation the plan was computed against
    public let manifestDigest: ManifestDigest    // what applying the plan makes "applied"
    public let reconcile: ReconcileStep          // applied FIRST, in one store commit (R-SYN-8)
    public let fetches: [PlannedFetch]           // stable order (§4.3)
    public let skipped: [PlannedSkip]            // manifest order
    public let totals: PlanTotals
    public let space: SpaceAssessment
}
public struct ReconcileStep: Sendable, Equatable {
    public let relocations: [Relocation]         // same content, new metadata (path components, file name, remotePath, tags, policy)
    public let reuses: [Reuse]                   // content already present as a blob (dedupe / renamed id): bind id → blob
    public let prunes: [Prune]                   // id gone from the manifest: index removal; blob deletion deferred (I-3)
    public let adopts: ValidatedManifest         // the manifest that becomes "applied" by this commit
}
public struct PlannedFetch: Sendable, Equatable {
    public let id: AssetID
    public let entry: ManifestEntry
    public let fingerprint: EntryFingerprint     // checksum, or (remotePath, byteSize) for legacy entries (R-MAN-5)
    public let reason: FetchReason               // .added / .contentChanged / .missingBlob / .legacyPathChanged / .healStale
    public let rank: UInt8                       // policy rank: essential 0, standard 1, onDemand 2
    public let manifestIndex: Int
}
public enum SkipReason: Sendable, Hashable { case outOfScope, onDemandPolicy, unverifiedDisallowed, integrityQuarantined, invalidEntry }
public struct PlanTotals: Sendable, Equatable {
    public var fetchCount, fetchUnknownSizeCount, relocationCount, reuseCount, pruneCount, skippedCount, unchangedCount: Int
    public var fetchBytes, pruneBytes: Int64     // fetchBytes counts known sizes + unknownSizeEstimate × unknown
}
public enum SpaceAssessment: Sendable, Equatable {
    case fits
    case needsEviction(bytes: Int64)                       // shortfall the engine asks the store to evict
    case insufficient(required: Int64, available: Int64)   // only if policy forbids eviction
}
```

### 4.2 Algorithm: one pass over each side, no Dictionary iteration in output order

```
for (i, e) in manifest.entries.enumerated():                        // manifest order ⇒ deterministic
    old = snapshot.applied.index[e.id].map(snapshot.record)          // O(1)
    if old is present ∧ fingerprint(old.entry) == fingerprint(e):
        if old.entry ≠ e { reconcile.relocations += (e.id, old→e) }   // metadataChanged: zero bytes (R-SYN-8)
        else { unchanged += 1 }
        continue
    if ¬scope.contains(e) { skipped += (i, .outOfScope); continue }
    if e.policy == .onDemand ∧ ¬policy.includeOnDemand { skipped += .onDemandPolicy; continue }
    if e.checksum == nil ∧ ¬policy.allowUnverifiedAssets { skipped += .unverifiedDisallowed; continue }   // R-INT-5
    if snapshot.quarantine(e.id) == fingerprint(e) { skipped += .integrityQuarantined; continue }       // R-INT-3
    if let c = e.checksum, snapshot.hasBlob(checksum: c) { reconcile.reuses += (e.id, c); continue }    // dedupe
    fetches += PlannedFetch(reason: old == nil ? .added : old!.isPresent ? .contentChanged : .missingBlob, …)
for r in snapshot.orderedRecords where manifest.index[r.id] == nil:   // applied-manifest order
    reconcile.prunes += (r.id, r.blob, r.bytes)
fetches.sort { ($0.rank, $0.manifestIndex) < ($1.rank, $1.manifestIndex) }   // F log F, F ≈ churn
space = assess(totals, freeSpace, policy)                            // §12.1
```

`fingerprint(e)` is `e.checksum`, or `(remotePath, byteSize)` when `checksum == nil` (R-MAN-5: a legacy entry is re-downloaded only when its `remotePath` changes). A *stale* record (content changed, old blob still present) stays readable through `lookup` (prior-art parity) until the new blob commits.

**Complexity:** O(M + S) dictionary probes plus O(F log F) for the sort. The output never depends on `Dictionary`/`Set` iteration order, which Swift randomises per process (per-process hash seeding). A prototype of exactly this loop (§16 P10, release, M = S = 10,000, 10 % churn) takes **1.74 ms**, and **3.16 ms** at 20,000 (ratio **1.82**). P-4 allows 20 ms and a ratio of 2.5.

### 4.3 Stable order

The order of `fetches` is `(rank, manifestIndex)`: essential before standard before on-demand, then the publisher's manifest order, which is also the prior art's serial order. `relocations`, `reuses` and `skipped` follow manifest order; `prunes` follow applied-manifest order. Removing or changing an unrelated entry never reorders the others (a property test checks this).

### 4.4 Reconcile before download (R-SYN-8)

The engine commits `plan.reconcile` (relocations, reuses, prunes and the adopted manifest) as **one** `store.apply(…, expectedGeneration: plan.baseGeneration)` **before enqueuing any fetch**. A directory change is therefore an index edit costing zero downloads, and a renamed id with identical bytes is a `Reuse` costing zero downloads. Prior-art parity: on-demand `resolve` never reconciles (§6.5).

### 4.5 Property tests (seeded generator; the failing seed is printed — Q-4)

A generator builds `(applied manifest, records with present / stale / needsHeal / quarantined, new manifest)` from a seed: random adds, removes, checksum changes, metadata-only changes, id renames with identical checksums, legacy entries without checksums, policies and tags.

| # | Property | Display name |
|---|---|---|
| 1 | Determinism: `plan(x) == plan(x)` even when the snapshot is rebuilt with dictionaries of different capacity and insertion order | `R-SYN-1: the plan is identical for equal inputs built in different dictionary orders` |
| 2 | Partition: every id in `new ∪ applied` is in exactly one of unchanged, relocation, reuse, fetch, prune, skipped | `R-SYN-1: every identifier lands in exactly one plan bucket` |
| 3 | Identity: `plan(a, snapshot(a))` has no work | `R-SYN-1: planning an applied manifest against itself yields no work` |
| 4 | Metadata-only churn ⇒ zero fetches and zero fetch bytes | `R-SYN-8: a directory or file-name change plans zero downloads` |
| 5 | Idempotence: `plan(m, oracleApply(plan(m, s), s))` has no work | `R-SYN-1: re-planning after applying a plan yields no work` |
| 6 | Oracle: applying the plan to an in-memory model makes every in-scope entry present at its fingerprint and removes every pruned id | `R-SYN-1: applying a plan to the oracle reaches the manifest's in-scope state` |
| 7 | Scope monotonicity: `S ⊆ T` ⇒ `fetches(S) ⊆ fetches(T)`; prunes and relocations do not depend on scope | `R-SYN-1: narrowing the scope only removes fetches` |
| 8 | Order: fetches sorted by `(rank, manifestIndex)`, and stable under unrelated removals | `R-SYN-1: fetch order is stable and essential-first` |
| 9 | Totals equal the sums of the lists | `R-SYN-1: plan totals equal the sums of their lists` |
| 10 | Space is monotone: more free space never turns `fits` into `insufficient` | `R-SYN-11: more free space never worsens the space assessment` |
| 11 | Legacy entries are re-fetched only when `remotePath` changes | `R-SYN-1: a checksum-less entry is re-fetched only when its remotePath changes` |
| 12 | Quarantine holds until the fingerprint changes | `R-INT-3: a quarantined entry is skipped until its manifest fingerprint changes` |
| 13 | `allowUnverifiedAssets == false` skips checksum-less entries | `R-INT-5: unverified entries are skipped when allowUnverifiedAssets is false` |

**P-4 benchmark** (`ZTronAssetKitBenchmarks`, release): `P-4: planning 10,000 vs 10,000 entries with 10% churn stays within plan_ms and scales by at most doubling_ratio_max`. Fixed seed; churn is 2.5 % each of added, removed, content-changed and metadata-changed. Median of 21 runs after 3 warm-ups, at N = 10,000 and N = 20,000. Thresholds are read from `Scripts/quality-gates.json` (ADR-010).

---

## 5. The per-asset state machine (R-SYN-2)

### 5.1 Representation

`absent` and `present` are **derived from the snapshot**: no job record exists for them. Only in-progress assets have a `Job`, so engine memory scales with outstanding work, not with catalog size (P-7).

```swift
struct Job {                                   // engine-internal, actor-isolated, never copied across an await (rule R2)
    let id: AssetID
    var entry: ManifestEntry
    var fingerprint: EntryFingerprint
    var state: JobState
    var epoch: UInt64                          // bumped on every (re)start, supersede and abandon
    var interests: [InterestToken: Interest]   // ref-counted interest (§6); Interest = (lane, kind: waiter|group|run|system, batch: Bool)
    var lane: AssetPriority                    // == max(interests.lane); recomputed on every add/remove
    var ticket: UInt64                         // lane-queue ticket for lazy deletion (§7.2)
    var enqueuedAt: MonotonicInstant           // aging (§7.4)
    var attempts: Attempts                     // transient / integrity / auth counters (§8)
    var transfer: ActiveTransfer?              // TransferID, control continuation, driver Task, bytes received, preempting flag
    var signpost: OSSignpostIntervalState?     // R-OBS-1 (Sendable at iOS 15 — §16 P3)
}
enum JobState: Sendable, Equatable {
    case queued
    case downloading
    case verifying
    case committing
    case failed(RetryDisposition, AssetError)
    case blocked(BlockReason)
}
public enum RetryDisposition: Sendable, Equatable {
    case at(MonotonicInstant)    // backoff deadline (alarm-driven)
    case whenOnline              // parked until the path becomes satisfied (R-SYN-13)
    case nextRun                 // attempt cap reached for this run
    case untilEntryChanges       // R-INT-3 / 404 / ambiguous 403: persisted as quarantine in the index
}
public enum BlockReason: Sendable, Equatable {
    case offline, policy(PolicyBlock), circuitOpen(BreakerCause), throttled(until: MonotonicInstant), awaitingSpace, insufficientSpace
}
```

### 5.2 Transition table (guards evaluated on the actor, synchronously)

| # | From | Event | Guard | To | Actions |
|---|---|---|---|---|---|
| T1 | absent | interest added (`want(lane)`) | entry ∈ applied manifest (or point-admitted §6.5); not quarantined for this fingerprint; lifecycle `.running` | queued | push to `lanes[lane]`; `pump()` |
| T2 | absent | `want` | quarantined for this fingerprint | — (no job) | waiter resumed `.failure(stored error)` |
| T3 | queued | `pump` picks it | free slot for its lane (§7.3) ∧ `admission(lane)` allows ∧ headroom covers expected bytes (§12.1) | downloading | create the control stream; spawn the driver (owned task); `remote.transfer(…)` |
| T4 | queued | `pump` evaluates it | lane blocked by policy / breaker / throttle / space | blocked(reason) | park; the watcher or the alarm wakes it |
| T5 | downloading | update `.staged` | job epoch current | verifying | release the transfer slot; keep the pipeline slot (§7.3) |
| T6 | downloading | update `.failed(e)` | — | failed(disp, err) or blocked | disposition per §8.1; arm the alarm if `.at` |
| T7 | downloading | update `.paused` | was preempted, or a policy pause | queued (head of lane) or blocked(policy) | the resume data stays in staging |
| T8 | verifying | store `verify` ok | epoch current ∧ fingerprint still applied | committing | — |
| T9 | verifying | store `verify` throws integrity | — | failed(`.at` or `.untilEntryChanges` after `maxIntegrityFailures`) | counted (R-INT-2/3); quarantine persisted when capped |
| T10 | committing | store `commit` ok | — | **present** (job removed) | resume waiters `.success`; emit `.assetAvailable`; release interests |
| T11 | committing | `commit` throws `.staleEntry` | interests non-empty | queued (new fingerprint) | epoch += 1 |
| T12 | queued, blocked, failed | last interest leaves | — | absent (job removed) | queued: tombstone the lane ticket |
| T13 | downloading | last interest leaves | — | absent | `driver.cancel()` → stream consumer cancelled → transport cancels (R-SYN-4) |
| T14 | verifying, committing | last interest leaves | — | (unchanged) | finish locally: the bytes are already on disk; no network involved |
| T15 | queued, downloading | promote (`lane` rises) | — | same state | queued: re-push to the back of the higher lane; downloading: `control.yield(.setPriority)` |
| T16 | downloading | preempted | a `userInitiated` job is waiting ∧ no free slot ∧ this job's lane < `userInitiated` | downloading (preempting) → T7 | `control.yield(.pause)`; its slot is freed in the ledger immediately |
| T17 | blocked | conditions / breaker / throttle / space change | the gate now admits | queued | `pump()` |
| T18 | failed(`.at(t)`) | alarm | `t ≤ monotonicNow()` ∧ breaker admits | queued | — |
| T19 | failed(`.whenOnline`), failed(`.at`, transient) | path becomes satisfied (edge) | — | queued | R-SYN-13 |
| T20 | failed(any but `.untilEntryChanges`) | `want(.userInitiated)` | breaker and throttle admit | queued | user requests skip the backoff wait |
| T21 | any job | entry pruned (reconcile) | — | absent | waiters `.failure(.notFound)`; cancel the transfer |
| T22 | any job | entry fingerprint changed (reconcile) | — | queued (new entry), epoch += 1 | cancel any running transfer; interests carried over |
| T23 | any job | shutdown | — | absent | waiters `.failure(.shutDown)`; tasks cancelled and joined |
| T24 | present | blob vanished / evicted / purged / `reportUnreadable` | — | absent (snapshot) | a system interest is added if healing is wanted (R-CLN-8) |
| T25 | absent | reconcile `Reuse` | blob present | present | index edit only, no job |

**Illegal transitions** (anything else; in particular): `absent → downloading|verifying|committing`; `queued → verifying|committing|present`; `downloading → committing|present`; `verifying → downloading|present`; `committing → downloading|verifying`; `present → downloading|verifying|committing` (content change goes through T22); `failed|blocked → downloading|verifying|committing|present`. They are enforced by one pure function, `JobState.allows(_ next: JobState) -> Bool`, used by the only mutator, `transition(_:to:)`. A violation is a programming error: `assertionFailure` in debug, a no-op plus a `metrics.illegalTransitions` increment in release. Every test asserts that the counter is 0, and Q-8 mutation probes are expected to trip it.

### 5.3 Engine lifecycle

`created → starting → running → shuttingDown → shutDown`, plus `degraded(storageUnavailable)` when `store.open()` fails. Every entry point checks the lifecycle synchronously before doing anything else: `created` awaits `start()`; `shuttingDown`/`shutDown` fail with `.shutDown`; `degraded` fails with `.storageUnavailable`.

### 5.4 REENTRANCY ledger (initial — C3, H-5)

Every `await` inside `SyncEngine` gets the comment `// REENTRANCY: RE-Snn — <what is re-validated>`. After **every** await, two checks always run: (L) `lifecycle == .running`, else unwind with `.shutDown`; and (E) the job is re-read from `self.jobs[id]` and its `epoch` compared with the captured value, else the stale continuation is abandoned. The table lists the additional, specific re-validations.

| ID | Await (site) | Re-validated afterwards |
|---|---|---|
| RE-S01 | `start`: `await store.open()` | L. If shutdown began meanwhile: `await store.close()` and return `.shutDown`. The snapshot is adopted only if its generation exceeds the current one. |
| RE-S02 | `start`: `await appVersion.current()` | L. |
| RE-S03 | `start`: `await remote.reattachedTransfers()` | L. Each re-attached asset is adopted only if its entry is still applied and no job exists for it (otherwise the reattached stream is dropped, which cancels it). |
| RE-S04 | run: `await fetchManifestSingleFlight()` | L; the run's `epoch` is still current. A result is applied only if its fetch sequence number is greater than `lastAppliedFetchSeq`, so an older concurrent fetch can never overwrite a newer one. |
| RE-S05 | run: `await executor.run { decodeAndValidate }` (off the pool, ADR-003; P-3 ≤ 80 ms must not run on a cooperative thread) | L; run epoch. |
| RE-S06 | run: `await store.freeSpace()` | L; run epoch. |
| RE-S07 | run: `await SyncPlanner.planOffActor(…)` | L; run epoch. The snapshot may have advanced (a resolve committed): tolerated, because RE-S09 rejects a stale base. |
| RE-S08 | run: `await accessLog.drainAccesses()` then `await store.recordAccesses(…)` (only if eviction is needed) | L; run epoch. |
| RE-S09 | run: `await store.apply(reconcile, eviction, expectedGeneration:)` | On `.staleGeneration`: re-plan (at most `maxReplans` = 3, then the run fails with `.storageUnavailable`). On success: jobs whose ids were pruned go through T21; jobs whose fingerprint changed go through T22; `latestSnapshot = max(by: generation)`. |
| RE-S10 | run: `await runGroup.completion` (continuation resumed when the run's last job is terminal) | L. The outcome is computed from the run ledger **at resume time**, not from state captured earlier. |
| RE-S11 | run: `await store.recordStamp(stamp, ifPurgeEpoch:)` | L. The store refuses if `purgeEpoch` moved: a purge during the run means the sync is still due (R-CLN-6). |
| RE-S12 | driver: `await remote.transfer(request, control:)` | E; job state is still `.downloading`; interests are non-empty. If not, the returned stream is dropped without iterating, which terminates it so the transport cancels. |
| RE-S13 | driver: each iteration of `for await update in stream` | E. `.progress`: update counters and offer throttled progress (§10.5). Terminal elements: T5 / T6 / T7. Driver cancellation returns `nil`, and the loop exits without any state change (T13 already applied). |
| RE-S14 | driver: `await store.verify(staged, expecting:)` | E; the fingerprint is still the applied one (if not: T22, and the verified blob is left unreferenced for GC). |
| RE-S15 | driver: `await store.commit(blob, entry, expectedFingerprint:, urgency:)` | E (the job may have gained or lost interests: the result is delivered to the waiters present **now**); `.staleEntry` → T11. |
| RE-S16 | alarm task: `await time.sleep(until:)` | The alarm token is still current (a re-arm supersedes the old alarm); due items are recomputed from `monotonicNow()`, never from the scheduled deadline (handles early or late wake-ups and device sleep). |
| RE-S17 | watcher: `await conditionsSource.conditions()` | The watcher token is still current and the watcher still needed (if the engine went idle meanwhile, drop the stream, which stops observation). |
| RE-S18 | watcher: each iteration of `for await c in stream` | Watcher token; L. Apply `c`, then `pump()`. If no longer needed, the watcher exits. |
| RE-S19 | resolve of an unknown id: `await fetchManifestSingleFlight()` (point admission) | For each pending unknown-id waiter: still registered (it may have withdrawn). Found → T1 with point admission; else → `.notFound` and a negative cache until `unknownIDRefetchInterval`. |
| RE-S20 | `ensureAvailable`: `await group.completion` | L; group still registered (it may have withdrawn). The report is recomputed from the current snapshot. |
| RE-S21 | `shutdown`: `for t in ownedTasks { await t.value }` | Lifecycle is `.shuttingDown`, so no new task can be spawned (`pump`, `arm` and `ensureWatcher` all check it). Tasks that end during the loop remove themselves; the loop iterates a copy. |
| RE-S22 | `shutdown`: `await store.close()` | — (terminal). |
| RE-S23 | `performMaintenance`: each `await store.collectGarbage(until:)` / `evict` / `verifyBatch` | L; deadline (`monotonicNow() < deadline`); `Task.isCancelled` (BGProcessingTask expiry). |
| RE-S24 | `purge`: `await store.purge(request)` | `purgeEpoch` was bumped **before** the await. Afterwards, jobs for purged ids go through T21-like removal (waiters `.failure(.cancelled)` unless they are `userInitiated`, which re-queue). |
| RE-S25 | the `join` family (`await withTaskCancellationHandler { await withCheckedContinuation … }`) | Nothing on the actor: the body is synchronous and the result is delivered by value. |
| RE-S26 | every entry point: `await ensureStarted()` | L (start may have failed into `degraded`, or shutdown may have begun). |

The facade (`AssetClient`) is not an actor. `SnapshotMirror` and `PrefetchWindowController` are `@MainActor` and contain no `await`, so they have no ledger rows. The store's own awaits (including `await sink.publish(snapshot)` to the mirror) belong to the storage ledger.

---

## 6. Single-flight with ref-counted interest (R-SYN-4, R-CAR-3, R-CAR-4)

### 6.1 Interest model

An **interest** is a reason for a job to exist: `waiter` (one `resolve` call), `group` (a prefetch handle, or `ensureAvailable` over a set of assets), `run` (a bulk sync), or `system` (healing after `reportUnreadable`, R-CLN-8). Interests are keyed by `InterestToken` (a `UInt64` from an actor-isolated counter, so allocation is deterministic). A job's lane is the maximum lane among its interests. **A job is cancelled exactly when its interest map becomes empty** (T12/T13); verification and commit, which are local and already paid for, finish anyway (T14).

### 6.2 How N callers await one transfer — exact mechanism (compiled and run: §16 P2)

```swift
// SyncEngine (actor). Waiter = (asset, continuation). Every resume goes through removeValue ⇒ at most once.
private var waiters: [InterestToken: Waiter] = [:]

func awaitAsset(_ id: AssetID, lane: AssetPriority) async -> Result<AssetLocation, AssetError> {
    let token = self.tokens.next()
    return await withTaskCancellationHandler {
        // nonisolated(nonsending) overload (SDK: @_alwaysEmitIntoClient, iOS 13+): the body runs synchronously
        // on this actor, so "check, register, promote, pump" happen with no suspension in between.
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<AssetLocation, AssetError>, Never>) in
            if Task.isCancelled { continuation.resume(returning: .failure(.cancelled)); return }      // pre-cancelled caller
            if let immediate = self.fastPath(id) { continuation.resume(returning: immediate); return }  // present / shutDown / quarantined / breaker
            self.waiters[token] = Waiter(asset: id, continuation: continuation)
            self.addInterest(token, to: id, lane: lane, kind: .waiter)  // creates the job (T1) or joins/promotes (T15/T20)
            self.pump()
        }
    } onCancel: {
        Task { await self.withdraw(token) }        // not isolated: hop back; a no-op if already resumed
    }
}

func withdraw(_ token: InterestToken) {
    guard let waiter = self.waiters.removeValue(forKey: token) else { return }     // completion won the race
    waiter.continuation.resume(returning: .failure(.cancelled))
    self.removeInterest(token, from: waiter.asset)   // last one out ⇒ T12/T13 (transfer cancelled); else relane (demotion)
    self.notifyObservers()
}

private func finish(_ id: AssetID, with result: Result<AssetLocation, AssetError>) {   // T10 / terminal failure
    guard let job = self.jobs.removeValue(forKey: id) else { return }
    for token in job.interests.keys {                // interests present NOW (RE-S15), not at transfer start
        self.waiters.removeValue(forKey: token)?.continuation.resume(returning: result)
        self.groups[token]?.memberFinished(id, result) // prefetch handles / ensureAvailable / runs
    }
}
```

**Invariants (asserted in debug after every mutation and checked by the tests):**
1. Every `waiters` key is also an interest of `jobs[waiter.asset]`, or of the unknown-id table (§6.5).
2. Every job has at least one interest, or is in `verifying`/`committing`.
3. A continuation is resumed only on the path that removed it from `waiters`. Because removal and resumption happen in one synchronous actor step, double resume is impossible.
4. **No leak:** every path that removes a job (T10, T12, T13, T21, T23) drains the waiters of every interest it holds; `shutdown` drains `waiters` wholesale. The engine's `deinit` asserts that `waiters` is empty.

**Independence of one caller's cancellation.** `withdraw` removes exactly one token. Other waiters, their lanes and the transfer are untouched unless that token was the last interest. **Demotion:** if the withdrawn token carried the highest lane, `relane` lowers the job's lane, which yields `.setPriority(lower)` on a running transfer or moves a queued job down, so a cancelled user request does not leave a bulk asset at user priority.

**Point at which a caller is "in".** Registration happens inside the synchronous continuation body, so a caller is either fully registered (waiter and interest) or resumed immediately. There is no window in which the job exists without the waiter, or the reverse.

### 6.3 Prefetch handles that cancel on `cancel()` and on deinit (R-CAR-4) — compiled and run: §16 P3, P6

```swift
public final class PrefetchHandle: Sendable {        // only `let`s of Sendable types ⇒ Sendable without @unchecked
    private let registration: Task<InterestToken?, Never>    // nil if the engine refused (shut down)
    private let engine: SyncEngine
    init(engine: SyncEngine, ids: [AssetID], lane: AssetPriority) {
        self.engine = engine
        self.registration = Task { await engine.registerGroup(ids, lane: lane) }
    }
    /// Idempotent: the engine ignores tokens it no longer knows.
    public func cancel() { Self.release(self.registration, self.engine) }
    deinit { Self.release(self.registration, self.engine) }
    private static func release(_ registration: Task<InterestToken?, Never>, _ engine: SyncEngine) {
        // Ordered after the registration it undoes: a release can never overtake its own registration,
        // so "cancel immediately after prefetch" cannot leave a transfer running for nobody.
        Task { if let token = await registration.value { await engine.releaseGroup(token) } }
    }
}
```

`prefetch` is synchronous (a UI-facing call, P-8 ≤ 1 ms) and creates one registration task. `cancel()` then deinit releases twice, and the second release is a no-op. P6 created 1,000 handles, cancelled them at random immediately and dropped them at random: **0 interest groups remained**. `public func prefetch(_ ids: [AssetID], priority: AssetPriority = .prefetch) -> PrefetchHandle` puts every id under one group token. Ids already present are not enqueued; ids already in flight just gain an interest (single-flight, so never a duplicate transfer).

### 6.4 The prefetch-window helper (R-CAR-3)

```swift
public struct PrefetchWindow: Sendable, Hashable {
    public var radius: Int                                  // default 2
    /// Pure. Order: current, +1, −1, +2, −2, …; out-of-range indices are clamped away; duplicate ids keep their
    /// closest occurrence. The current page gets `.userInitiated`, every neighbour `.prefetch`.
    public static func targets(ids: [AssetID], current: Int, radius: Int) -> [(id: AssetID, priority: AssetPriority, distance: Int)]
}

@MainActor public final class PrefetchWindowController {
    public nonisolated init(client: AssetClient, radius: Int = 2)
    /// O(radius): diffs the old and new targets. New id → a handle. Id left the window → handle.cancel().
    /// Priority changed (a neighbour became current) → the new handle is created BEFORE the old one is cancelled,
    /// so interest never drops to zero in between and the transfer is never restarted.
    public func update(ids: [AssetID], current: Int)
    public func cancelAll()
}
```

The controller holds `[AssetID: (PrefetchHandle, AssetPriority)]`. Releasing the controller releases its handles, and each handle's deinit releases its interest. Tests: `R-CAR-3: moving the window by one cancels exactly the asset that left and starts exactly the one that entered`; `R-CAR-3: a neighbour that becomes current is promoted without a second transfer`; `R-CAR-3: overlapping windows never duplicate a transfer`.

### 6.5 Unknown ids: fetch-first point admission (prior-art resolver parity)

If `resolve(id)` names an id that is not in the applied manifest, the waiter goes into `unknownWaiters[id]`, and one single-flight conditional manifest fetch starts (it is shared with any run that is fetching). When it returns (RE-S19): if the id is present, the engine **point-admits** that one entry, committing a single index entry later with T1…T10, without reconciling anything else (preserving `CDNLocalStore.swift:270-276`). If the id is absent, the waiter fails with `.notFound`, and the id is negatively cached for `unknownIDRefetchInterval` (default 60 s, matching the manifest's `max-age=60`), so a page full of unknown ids cannot cause a fetch storm.

---

## 7. Priority lanes, promotion, bounded parallelism (R-SYN-3, R-NET-10)

### 7.1 Configuration

```swift
public struct SyncConfiguration: Sendable, Equatable {
    public var maxConcurrentTransfers: Int = 4        // clamped to 1…16 by init; a clamp is recorded in diagnostics
    public var reservedInteractiveSlots: Int = 1      // effective min(this, max − 1): 0 when max == 1
    public var pipelineDepth: Int = 2                 // jobs in downloading ∪ verifying ∪ committing ≤ depth × max
    public var bulkAging: TimeInterval = 30           // §7.4
    public var preemptLowerLanes: Bool = true
    public var retry: RetryPolicy = .background
    public var interactiveRetry: RetryPolicy = .interactive
    public var breaker: CircuitBreakerPolicy = .default
    public var progressInterval: TimeInterval = 0.1   // ≤ 10 Hz per progress key (R-SYN-12)
    public var unknownIDRefetchInterval: TimeInterval = 60
    public var maxReplans: Int = 3
}
```

### 7.2 Lane queues

There is one FIFO per lane, plus a split `userInitiated` lane: `single` (individual `resolve` calls) is served before `batch` (`ensureAvailable`), so the page just opened still overtakes a 300-asset `ensureAvailable`. Each queue is an array with a head index and **lazy deletion**: an entry `(ticket, id)` is valid only if `jobs[id]?.ticket == ticket ∧ state == .queued`. Withdrawal and promotion are O(1) (bump the ticket). Compaction happens when stale entries outnumber live ones. Memory stays within 2 × live entries.

### 7.3 Dispatch (`pump()`, synchronous, no await)

```
free        = max − |running \ preempting|                      // a slot is "running" from T3 until T5/T6/T7
nonUserCap  = max − reserved
while free > 0 ∧ |pipeline| < depth × max:
    if gate(.userInitiated) ∧ let j = user.single.popValid() ?? user.batch.popValid(): start(j); continue
    guard |running where lane < .userInitiated| < nonUserCap else break
    guard user.single.isEmpty ∧ user.batch.isEmpty else break    // non-user work never starts while a user job waits
    order = (bulk.head waited ≥ bulkAging) ? [bulk, prefetch] : [prefetch, bulk]
    guard let j = order.lazy.compactMap({ gate($0) ? lane[$0].popValid(fitting: headroom) : nil }).first else break
    start(j)
if preemptLowerLanes ∧ user queue non-empty ∧ free == 0:
    victim = running.filter { lane < .userInitiated ∧ ¬preempting }
                    .min(by: (lane, bytesReceived, −startSeq))      // lowest lane, least work lost, newest
    victim?.control.yield(.pause); mark preempting                   // T16; its slot is free now
```

`gate(lane)` = network/power admission (§11) ∧ breaker admission ∧ origin throttle (§8) ∧ lifecycle. **Bound:** at most `max` transfers count as running. While a preempted transfer is producing resume data, the real number of open transfers can exceed `max` by the number of in-progress preemptions (≤ `max`, typically 1). This is stated, counted (`metrics.preemptions`) and tested.

### 7.4 Promotion, queue jump, starvation

- **Promotion of a running bulk transfer (H-4):** a `resolve` on an asset in `downloading` at `bulk` adds a `userInitiated` interest (T15). The job's lane becomes `userInitiated`; `control.yield(.setPriority(.userInitiated))` maps to `URLSessionTask.priority = URLSessionTask.highPriority` inside the transport (R-NET-10 table below). The transfer is **not restarted**, and its slot moves from the non-user count to the user count, which may let another bulk job start. If the transport ran it on the background (discretionary) session, it migrates the transfer to the foreground session using resume data (transport design, H-6).
- **Queue jump:** a queued bulk job that gains a `userInitiated` interest is re-pushed to the back of `user.single` (T15). It overtakes every bulk and prefetch job and is FIFO among user requests.
- **Starvation analysis.**
  - `userInitiated`: with `max ≥ 2` and `reserved = 1`, the first user job never waits for a slot. Further concurrent user jobs either preempt a lower lane (if enabled) or wait FIFO behind other *user* jobs only. With `max == 1`, preemption guarantees the user job starts after one actor turn.
  - `prefetch`: waits only while a user job is queued, or while non-user slots are full. Prefetch demand is bounded by window sizes (`2·radius` per controller).
  - `bulk`: once its head has waited `bulkAging` (30 s), it outranks prefetch for the next non-reserved slot. Bulk therefore waits at most `bulkAging + one non-user transfer duration`, unless user jobs are continuously *queued* (meaning every slot is taken by user work). That is the intended priority, and it is bounded by human interaction rate.
  - Aging needs **no timer**: it is evaluated whenever `pump()` runs, which happens on every slot release.
- **R-NET-10 engine ↔ URLSession table** (the transport implements it; the engine test asserts the order of `setPriority`/start calls on the fake):

| Lane | Engine order | `URLSessionTask.priority` | Session |
|---|---|---|---|
| userInitiated | first; reserved slot; may preempt | `highPriority` (1.0) | foreground |
| prefetch | second | `defaultPriority` (0.5) | foreground |
| bulk | third; ages ahead of prefetch | `lowPriority` (0.0) | background discretionary if wired (R-NET-3), else foreground |

---

## 8. Retries, backoff, circuit breaker, timers and idle silence (R-SYN-5, R-SYN-13, R-SYN-14, P-14)

### 8.1 Error → action

| Failure (TransferError / StoreError) | Disposition | Breaker input | `AssetError` to waiters |
|---|---|---|---|
| `offline` | `failed(.whenOnline)` (R-SYN-13) | — | `.offline` |
| `transient` (timeout, connection lost) | `failed(.at(backoff))`, re-queued early on a path-satisfied edge (T19) | — | `.serverUnavailable(retryAfter: nil)` |
| `server(5xx)` | `failed(.at(backoff))` | 5xx window | `.serverUnavailable(retryAfter: nil)` |
| `throttled(retryAfter)` (429 / 503 + header) | **origin throttle** until `now + clamp(retryAfter)`; the job re-queues `blocked(.throttled)` | — | `.serverUnavailable(retryAfter:)` |
| `notFound` (404 / 410) | `failed(.untilEntryChanges)`, quarantined | — | `.notFound` |
| `forbiddenAmbiguous` (403 on an object — bad key **or** missing object behind OAC, SPEC §2.3) | `failed(.untilEntryChanges)` for this asset | auth-suspect counter | `.authRejected(.ambiguous)` |
| `authRejected` (401, or 403 on the manifest) | breaker opens at once | auth trip | `.authRejected(.confirmed)` |
| `tooLarge`, `sizeMismatch`, store integrity | `failed(.at(backoff))`; after `maxIntegrityFailures` (3) → `failed(.untilEntryChanges)` + persisted quarantine (R-INT-3) | — | `.integrityFailure` |
| `insufficientSpace` (ENOSPC) | `blocked(.awaitingSpace)` if a reclaim is pending, else `blocked(.insufficientSpace)` | — | `.insufficientSpace(required:available:)` |
| `cancelled` | not a failure: T13 (abandoned) or T7 (paused) | — | `.cancelled` |
| store I/O / lock | run ends `.failed(.storageUnavailable)` after 3 consecutive | — | `.storageUnavailable` |

### 8.2 Backoff with full jitter, Retry-After, attempt caps

```swift
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval, maxDelay: TimeInterval
    public var maxAttemptsPerRun: Int, maxIntegrityFailures: Int
    public var maxRetryAfter: TimeInterval, interactiveMaxWait: TimeInterval
    public static let background  = RetryPolicy(baseDelay: 1,    maxDelay: 300, maxAttemptsPerRun: 4, maxIntegrityFailures: 3, maxRetryAfter: 3600, interactiveMaxWait: 0)
    public static let interactive = RetryPolicy(baseDelay: 0.25, maxDelay: 2,   maxAttemptsPerRun: 2, maxIntegrityFailures: 3, maxRetryAfter: 3600, interactiveMaxWait: 2)
}
enum Backoff {
    /// Full jitter: U[0, min(maxDelay, baseDelay · 2^(attempt−1))], honouring Retry-After as a lower bound.
    static func delay(attempt: Int, retryAfter: TimeInterval?, policy: RetryPolicy,
                      using rng: inout some RandomNumberGenerator) -> TimeInterval?   // nil ⇒ retryAfter > maxRetryAfter ⇒ `.nextRun`
}
```

- Each job uses `interactiveRetry` while its lane is `userInitiated`, else `retry`. A user waiter never sits through a 5-minute backoff: after `maxAttemptsPerRun` (2) it gets the error, and the job keeps only its non-user interests.
- `retryAt = monotonicNow() + delay`. The RNG is the engine's own `any RandomNumberGenerator & Sendable` from `RandomSource.makeGenerator()`. It is actor-isolated mutable state, so it needs no lock. With `SeededRandom` in tests, the whole schedule is reproducible; tests compute the expected delays by calling `Backoff.delay` with an identically seeded generator, so no magic literals are needed.
- **Retry-After** (429/503) is an *origin-wide* throttle. No transfer to that origin starts before `until`. A `userInitiated` request waits if `until − now ≤ interactiveMaxWait` (2 s), otherwise fails fast with `.serverUnavailable(retryAfter:)`. Values above `maxRetryAfter` (1 h) give `.nextRun`.
- After the cap: `failed(.nextRun)`. The job leaves the table, is recorded in the run ledger (`completeWithFailures`), and is retried by the next run. No loop is possible, because both the per-run cap and the R-INT-3 quarantine are persisted.

### 8.3 Circuit breaker (per `originID`)

```swift
struct CircuitBreaker: Sendable, Equatable {        // pure value; engine-owned; time is passed in
    enum State: Equatable { case closed, open(cause: BreakerCause, until: MonotonicInstant, trips: Int), halfOpen(cause: BreakerCause, trips: Int, probe: TransferID?) }
    mutating func record(_ outcome: Outcome, at now: MonotonicInstant, using rng: inout some RandomNumberGenerator) -> [BreakerTransition]
    func admit(at now: MonotonicInstant) -> Admission   // .allow | .probe | .reject(cause, until)
}
```

| Trigger | Rule (defaults in `CircuitBreakerPolicy`) |
|---|---|
| **Auth** | Opens immediately on `authRejected` (manifest 401/403, or any 401). Ambiguous object 403s open it when **3 distinct assets** get 403 with no intervening success. Cooldown 300 s, doubling per trip, up to 3,600 s, with jitter U[0.5c, c]. |
| **Sustained 5xx** | Sliding window of the last 20 transfer outcomes: opens when there are ≥ 5 samples and the 5xx ratio is ≥ 0.5. Cooldown 30 s, doubling, up to 600 s. |
| **Half-open** | At `until` (an alarm deadline), exactly **one** probe is admitted: the next dispatched job, or the manifest fetch of a pending run. Success → `closed` and trips reset. Failure with the same cause → `open(trips + 1)`. |
| **While open** | Queued jobs → `blocked(.circuitOpen)`. `resolve` fails fast with `.authRejected(.confirmed)` or `.serverUnavailable`, never hanging. A run ends `.blocked(.circuitOpen)` and sets `pendingRunOnBreakerClose`, so the half-open probe is the next run's manifest fetch. Event `.circuitChanged`. |

Q-8 probe "treat 403 as transient" is caught by `R-SYN-5: an ambiguous 403 is never retried with backoff`. Probe "ignore Retry-After" is caught by `R-SYN-5: no transfer starts before a 429's Retry-After elapses on ManualTimeSource`.

### 8.4 How timers are represented, and idle silence (R-SYN-14, P-14)

- **Deadlines are data.** `WakeupScheduler` is a min-heap of `(deadline: MonotonicInstant, seq: UInt64, reason)`. Reasons: `.retry(id, epoch)`, `.breakerHalfOpen(epoch)`, `.throttleEnd(epoch)`, `.storeDeadline` (GC grace, R-CLN-2/I-3, taken from `store.nextDeadline()`). Entries are validated when they fire (epochs), and stale ones are skipped. There is no per-deadline task.
- **One alarm task**, armed iff the heap is non-empty: `Task { [weak self] in try? await time.sleep(until: earliest); await self?.alarmFired(token) }`. When the earliest deadline changes, the old alarm is cancelled and a new one armed. `alarmFired` drains every due entry in `(deadline, seq)` order. That order is fixed by the engine, not by task scheduling, which is the basis of determinism under `ManualTimeSource`. Then it re-arms.
- **Watcher task** (conditions, §11), alive iff `jobs` is non-empty, or a run is active, or `pendingRunOnConditions`.
- **Driver tasks**: one per transfer in `downloading`/`verifying`/`committing`. **Run task**: at most one, for the run that `start()` launches.
- **Owned-task census:** each owned task is registered in `ownedTasks: [TaskKey: Task<Void, Never>]` when spawned. Its body ends with `await self.taskEnded(key)`, which runs even after cancellation. Cancellation hops and handle releases are not owned, because they complete in one actor turn.
- **Introspection** (`package` access for tests and benchmarks, also summarised in `diagnosticReport()`):

```swift
package struct EngineIntrospection: Sendable, Equatable {
    package var lifecycle: Lifecycle
    package var jobsByState: [JobStateKind: Int]
    package var queued: [AssetPriority: Int]
    package var running: Int, preempting: Int, waiters: Int, interests: Int, groups: Int
    package var armedTimers: Int            // 0 or 1 (the alarm)
    package var scheduledDeadlines: Int     // heap entries
    package var ownedTasks: Int             // drivers + alarm + watcher + run
    package var watcherActive: Bool
    package var subscribers: Int, bufferedEvents: Int
}
package func waitUntil(_ predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async   // event-driven, re-evaluated after every mutation
```

**Idle = `jobs` empty ∧ no run ∧ no pending run ∧ heap empty.** Then the watcher has exited, the alarm is not armed, and nothing else exists: `armedTimers == 0 ∧ ownedTasks == 0`. P-14 is measured on top of this introspection **and** on the environment census, which is stronger than self-report: `ManualTimeSource.pendingSleepers == 0`, `FakeRemoteSource.activeTransfers == 0`, `FakeConditionsSource.activeObservers == 0`.

---

## 9. `TimeSource` — contract and determinism (H-8, R-ENV-1, Q-4)

### 9.1 Contract (exact; iOS 15; no `Clock`/`Duration` — compiled: §16 P5)

- `now() -> Date` — wall clock. Used **only** where the value outlives the process: the sync stamp (`atMostEvery`), LRU access stamps, report timestamps. It may jump in either direction; consumers must tolerate that (§12.3).
- `monotonicNow() -> MonotonicInstant` — never decreases within a process and keeps counting during device sleep. Used for every in-process deadline: backoff, breaker cooldown, Retry-After, aging, progress throttle, maintenance budgets, GC grace. Never persisted.
- `sleep(until:) async throws(CancellationError)` — returns immediately if `deadline <= monotonicNow()`. Throws promptly on task cancellation. May return early or late; **callers re-check the time** (RE-S16).

### 9.2 Live conformers (the only places that touch the real world — R-ENV-1, C4)

```swift
public struct LiveTimeSource: TimeSource {                 // ZTronAssetModel
    public func now() -> Date { Date() }
    public func monotonicNow() -> MonotonicInstant { .init(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC)) }  // Darwin: counts during sleep
    public func sleep(until deadline: MonotonicInstant) async throws(CancellationError) {
        let now = self.monotonicNow(); guard deadline > now else { return }
        do { try await Task.sleep(nanoseconds: deadline.nanoseconds - now.nanoseconds) } catch { throw CancellationError() }
    }
}
public struct SystemRandomSource: RandomSource { public func makeGenerator() -> any RandomNumberGenerator & Sendable { SystemRandomNumberGenerator() } }
```

`Task.sleep(nanoseconds:)` may not advance while the device sleeps. That is harmless, because the alarm re-validates against `CLOCK_MONOTONIC` when it wakes and re-arms. They are covered on macOS without sleeping: a past-deadline `sleep` returns, and a cancelled one-hour `sleep` throws immediately (§16 P5 ran exactly this).

### 9.3 `ManualTimeSource` (ZTronAssetTestSupport) — semantics

```swift
@available(macOS 15.0, iOS 18.0, *)                        // Synchronization.Mutex; tests run on macOS 27
public final class ManualTimeSource: TimeSource {          // Sendable without @unchecked: only `let state: Mutex<State>`
    public init(wall: Date = Date(timeIntervalSince1970: 1_700_000_000), monotonic: MonotonicInstant = .init(nanoseconds: 1_000_000_000))
    public func advance(by seconds: TimeInterval)          // moves wall AND monotonic; resumes every sleeper with
                                                           // deadline <= new now, in (deadline, registration seq) order
    public func advance(to deadline: MonotonicInstant)
    public func setWallClock(_ date: Date)                 // wall jumps (user changed the date); monotonic unchanged
    public var pendingSleepers: Int { get }
    public var nextDeadline: MonotonicInstant? { get }
    public var wakeLog: [UInt64] { get }                   // registration seqs in wake order (asserted by its own tests)
}
```

- **No real sleeping, ever.** `sleep` registers a continuation under the mutex. `advance` resumes due sleepers *synchronously*. Cancellation removes the sleeper under the same mutex, so exactly-once is guaranteed by removal (P5: wake order `[2, 4, 3, 1]` for deadlines 3/1/2/1 s registered in that order; a cancelled sleeper threw; 0 sleepers left).
- **Deterministic wake order** at two levels: (1) the time source orders sleepers by `(deadline, seq)`; (2) the engine has a **single** sleeper, the alarm, so every engine-level ordering comes from its own heap.
- **How a test proceeds after advancing:** `time.advance(by: 4)` and then `await engine.waitUntil { $0.queued[.bulk] == 1 }`, or `await probe.next(where:)` on an event subscriber. Both are event-driven continuations, never polling. Every awaiting test carries `.timeLimit(.minutes(1))` (§7.2), so a missed wake-up fails instead of hanging.
- Suites that use it are annotated `@available(macOS 15.0, *)`. `SeededRandom` (SplitMix64, a struct) needs no lock and no availability gate.

---

## 10. Events and backpressure (R-SYN-12, H-9)

### 10.1 `AssetEvent` (Model; `Sendable`, `Equatable`)

```swift
public enum AssetEvent: Sendable, Equatable {
    // coalescible ("progress class"): newest wins per key, ≤ 1/progressInterval per key
    case snapshotChanged(generation: UInt64)                          // key .snapshot
    case conditionsChanged(DeviceConditions)                          // key .conditions
    case syncProgress(SyncRunID, SyncProgress)                        // key .run
    case transferProgress(AssetID, TransferProgress)                  // key .transfer(id); userInitiated/prefetch lanes only
    // terminal ("subject class"): never dropped; coalesced per subject
    case clientStarted(generation: UInt64)                            // subject .client
    case syncStarted(SyncRunID, SyncTrigger)                          // subject .runStarted
    indirect case syncFinished(SyncRunID, SyncOutcome)                // subject .runFinished (indirect: keeps the enum small)
    case assetAvailable(AssetID, generation: UInt64)                  // subject .asset(id)
    case assetFailed(AssetID, AssetError, RetryDisposition)           // subject .asset(id)
    case assetRemoved(AssetID, RemovalReason)                         // subject .asset(id): pruned / evicted / purged
    case circuitChanged(CircuitState)                                 // subject .breaker
    indirect case maintenanceFinished(MaintenanceReport)              // subject .maintenance
    case clientShutDown                                               // subject .client; always the last event
}
public struct SyncProgress: Sendable, Equatable { public var fraction: Double; public var completedCount, totalCount: Int; public var bytesReceived, bytesExpected: Int64 }
public struct TransferProgress: Sendable, Equatable { public var received: Int64; public var expected: Int64? }
```

### 10.2 Subscription: pull-based, released on every exit path (compiled and run: §16 P4)

```swift
// SyncEngine
nonisolated func makeEventStream() -> AsyncStream<AssetEvent> {
    let lease = SubscriptionLease(engine: self)                 // final class, `let`s only ⇒ Sendable
    return AsyncStream(unfolding: { await lease.next() },       // consumer pace drives delivery
                       onCancel: { lease.cancel() })            // consumer task cancelled ⇒ hop ⇒ unsubscribe
}
final class SubscriptionLease: Sendable {
    let engine: SyncEngine
    let registration: Task<SubscriberID?, Never>                 // registers + replays current state (§10.6)
    func next() async -> AssetEvent? { guard let id = await registration.value else { return nil }; return await engine.pull(id) }
    func cancel() { … Task { await engine.unsubscribe(await registration.value) } }
    deinit       { … Task { await engine.unsubscribe(await registration.value) } }   // stream released ⇒ unsubscribe
}
```

- **Cancellation while suspended in `pull`**: `onCancel` → hop → `unsubscribe` resumes the pending continuation with `nil` → `for await` ends.
- **Consumer `break`s out of the loop**: the stream and its closure are released → the lease's `deinit` → unsubscribe.
- **Shutdown**: `.clientShutDown` is enqueued last; the queue then drains and the next `pull` returns `nil`.

P4 exercised all three: a cancelled subscriber and a breaking one left 2 subscribers (live + stalled); releasing the stalled stream left **0**.

`public var events: AsyncStream<AssetEvent>` registers asynchronously, which suits UI. `public func subscribe() async -> AsyncStream<AssetEvent>` returns only after registration and replay, which is what tests use for determinism.

### 10.3 Per-subscriber queue and ordering

```swift
struct SubscriberQueue {
    var slots: [SlotKey: (seq: UInt64, event: AssetEvent)]     // one live slot per progress key / subject
    var order: [(seq: UInt64, key: SlotKey)]                   // append-only FIFO; entry valid iff slots[key].seq == seq
    var head: Int
    var pending: [CheckedContinuation<AssetEvent?, Never>]     // concurrent next() calls on this stream (normally ≤ 1)
    var finished: Bool
}
```

- **publish(e):** if `pending` is non-empty and the queue is empty, resume the first pending continuation directly (zero buffering). Otherwise:
  - progress key already live: **replace the event in place, keeping its seq and position** (newest-wins);
  - subject already live: **move it**, giving it a new seq at the tail. The old order entry goes stale, so the subject's latest outcome is delivered in the position of its latest occurrence;
  - otherwise append.
- **take:** advance `head` past stale entries and return the first live slot. **Order = publication order** of each slot's (latest) occurrence, across both classes. The first P4 run revealed that draining terminal slots ahead of progress reorders events, which this single-queue design rules out.
- **`finished` is set on every delivery path.** Publishing `.clientShutDown` marks the queue finished *before* deciding between a direct hand-off to a pending `pull` and buffering. The P4 prototype first set it only on the buffered path, and a subscriber that was already waiting received the event but then waited forever (caught at runtime: §16 P4). Test: `R-SYN-12: clientShutDown is the last event every subscriber receives`, run with the subscriber both waiting and lagging.
- Compaction rewrites `order` when stale entries outnumber live ones, so `order` stays within 2 × live + 1.

### 10.4 The memory bound (H-9: "no unbounded queue anywhere")

Live slots per subscriber ≤ `P + S`, where
- `P` (progress keys) ≤ `max + 3`: `transfer(id)` only for running user/prefetch transfers (≤ `max`), plus `.run`, `.snapshot` and `.conditions`;
- `S` (subjects) ≤ `|applied manifest ∪ job ids| + 5` ≤ 100,000 + 16 + 5. The catalog cap comes from R-MAN-2; `.asset(id)` subjects only exist for manifest ids, and an unknown id's `.notFound` is returned to its caller, never broadcast.

At ≈ 150 B per live slot (event ≤ 48 B thanks to `indirect` on the two large cases, dictionary overhead, two order entries), one **stalled** subscriber costs at most ≈ **1.5 MB for a 10,000-asset catalog** and ≈ 15 MB at the 100,000-entry ceiling. That is bounded and independent of time and of event volume. Prototype P4b replays a stalled subscriber through a 10,000-asset sync (5 progress updates per asset over 4 transfer keys, 1,000 assets failing and then succeeding, then shutdown): **10,005 live slots** (4 progress + 10,000 subjects + 1 client) and a peak of 12,005 order entries, within 2 × live + 1. A subscriber that keeps up costs 0 buffered slots. `metrics.eventsCoalesced` counts replacements. Test: `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync`.

### 10.5 Rate limiting at the source, with no timer

`ProgressThrottle` keeps `lastEmitted[key]: MonotonicInstant`. A progress update is published iff `now − last ≥ progressInterval` (0.1 s ⇒ ≤ 10 Hz per key). Suppressed updates are simply **not published**: there is no trailing timer, because the newer value comes with the next update, and every transfer ends with a terminal event (`assetAvailable` / `assetFailed`) that supersedes any suppressed final progress. Bulk transfers publish no per-asset progress, only the aggregate `syncProgress` at ≤ 10 Hz. Worst-case stream rate is therefore `10 × (1 + running user/prefetch transfers)` events/s, i.e. 10–50 Hz at the default `max = 4`, with typical UI load at 10–20 Hz. The source-side transfer stream is already newest-wins (`.bufferingNewest(1)`; P9 shows 99,999 progress yields collapse to the terminal element for a slow consumer). Test: `R-SYN-12: transfer progress published to subscribers never exceeds 10 Hz per asset under ManualTimeSource`.

### 10.6 Initial replay and prior-art progress mapping

On registration, a subscriber receives the current `snapshotChanged`, the current `conditionsChanged` (if known), and, if a run is active, `syncStarted` plus the latest `syncProgress`. A late subscriber therefore sees current state without polling. Mapping to `CDNSyncProgress` (for the R-CAR-6 shims, ADR-006): `idle` = no run event yet; `upToDate` = `syncFinished(.notDue)`; `syncing(f, c, t)` = `syncProgress`; `complete` = `syncFinished(.complete)`; `failed(reason)` = `syncFinished(.completeWithFailures | .blocked | .failed)` with `String(describing:)` of the outcome. The prior art's "progress never moves backwards" rule (`CDNSyncCoordinator.swift:154-164`) holds by construction: `completedCount` is monotone within a run.

---

## 11. Network and power policy (R-SYN-7, R-SYN-13)

### 11.1 Inputs (event-driven, no polling)

One `DeviceConditionsSource` (§3.1) merges three inputs: `NWPathMonitor` (`status == .satisfied`, `isExpensive`, `isConstrained`, R-NET-9); `NSProcessInfoPowerStateDidChange` (`isLowPowerModeEnabled`); and `ProcessInfo.thermalStateDidChangeNotification`. The live conformer belongs to the transport design (reachability lives in `ZTronAssetTransport`, §4.1). Two constraints are imposed here, both verified by the compiler:
- `NWPathMonitor`'s `Sendable` conformance is **iOS 17+**: capturing it in a `@Sendable` closure warns at iOS 15 (§16 P3). That warning is **not** escalated by `-warnings-as-errors`, so it would slip through Q-1 (§17).
- The monitor and the notification tokens are therefore owned by an **actor**. The stream's `onTermination` hops to it to `cancel()` and `removeObserver`. This compiles clean at iOS 15 (§16 P7).

**The watcher runs only while there is work** (§8.4). When the engine goes idle, the watcher exits, the stream terminates and the monitor is cancelled, so an idle client observes nothing. When work arrives, `ensureWatcher()` starts it again. The first element is the current state; until it arrives, bulk and prefetch wait, while `userInitiated` proceeds optimistically.

### 11.2 Admission per lane (pure: `LaneAdmission.evaluate(lane:conditions:network:power:) -> Admission`)

```swift
public struct NetworkPolicy: Sendable, Equatable {
    public var bulkOnExpensive = true              // prior-art parity: the launch sync ran on any network
    public var bulkOnConstrained = false           // Low Data Mode: the user asked for less data
    public var prefetchOnExpensive = true
    public var prefetchOnConstrained = false
    public var userInitiatedOverridesPolicy = true // explicit requests always go (R-SYN-7 "may override per policy")
}
public struct PowerPolicy: Sendable, Equatable {
    public var bulkInLowPowerMode = false
    public var prefetchInLowPowerMode = true
    public var pauseBackgroundAtThermal: ThermalLevel = .serious
    public var interactiveConcurrencyAtCritical = 1
}
```

| Condition | userInitiated | prefetch | bulk |
|---|---|---|---|
| path not satisfied | attempted (transport fails fast → `.offline`) | not started (`blocked(.offline)`) | not started (`blocked(.offline)`) |
| expensive (cellular, hotspot) | allowed | `prefetchOnExpensive` | `bulkOnExpensive` |
| constrained (Low Data Mode) | allowed | `prefetchOnConstrained` | `bulkOnConstrained` |
| Low Power Mode | allowed | `prefetchInLowPowerMode` | `bulkInLowPowerMode` |
| thermal ≥ `pauseBackgroundAtThermal` | allowed (≤ `interactiveConcurrencyAtCritical` at `.critical`) | paused | paused |

### 11.3 What pauses, what resumes

- **Becoming disallowed:** queued jobs of that lane are evaluated lazily at dispatch (T4 → `blocked(reason)`). **Running** bulk/prefetch transfers receive `.pause` (resume data kept, T7 → `blocked(.policy)`). `userInitiated` transfers are never paused by policy.
- **Becoming allowed** (an edge in the conditions stream): every `blocked(reason)` job whose reason no longer applies → `queued` (T17); then `pump()`.
- **Offline → online (R-SYN-13):** on the edge `satisfied: false → true` (and on an interface change while satisfied), every `failed(.whenOnline)` job and every transient `failed(.at)` job is re-queued immediately (T19); attempt counters are kept. A run that ended `blocked(.offline)` set `pendingRunOnConditions`, so a new run starts with trigger `.conditionsChanged`. The breaker still gates. Subscribers get `.conditionsChanged`, which replaces the prior art's `retryWhenAvailable` registry (the carousel re-resolves on it).
- Test fake: `actor FakeConditionsSource: DeviceConditionsSource` with `send(_:)` and `activeObservers`; `conditions()` is `async`, so the fake needs no lock.

---

## 12. Runs: space, availability, refresh, purge, maintenance, shutdown

### 12.1 Free space and eviction-before-plan, with no partial side effects (R-SYN-11)

**Phase 1 — decide on pure data, before the first mutation.**

```
available = freeSpace.volumeAvailable − policy.reserveFreeBytes          // physical, now
budgetRoom = freeSpace.budget − (freeSpace.used − plan.totals.pruneBytes) // logical end state (prunes free later)
need = plan.totals.fetchBytes                                             // unknown sizes × unknownSizeEstimate (8 MiB)
shortfall = max(0, need − min(available, budgetRoom))
```

- `shortfall == 0` → `.fits`.
- `shortfall > 0` and eviction is permitted → `evictionPlan = store.evictionPlan(toFree: shortfall, protecting: inScopeIDs ∪ leased, now:)`. Eviction never removes an asset the same plan would fetch again. `nil` means it cannot be reached → **fail now**.
- Otherwise the run ends `.failed(.insufficientSpace(required: need + reserve, available: volumeAvailable))`. **Nothing has been written**: no reconcile, no eviction, no transfer, no staging file. Test: `R-SYN-11: a plan that cannot fit even after eviction fails with insufficientSpace and leaves index, blobs and staging byte-identical` (`FakeFileSystem` tree digest before and after; zero mutating calls recorded).

**Phase 2 — one atomic mutation.** `store.apply(plan.reconcile, eviction: evictionPlan, expectedGeneration:)` commits reconcile and eviction **together** in a single index commit; blob deletions are deferred (I-3). Then fetches are enqueued.

**Phase 3 — physical headroom ledger (admission per fetch).** Evicted and pruned blobs are freed only after the grace window, while downloads start immediately. So `pump()` admits a fetch only if `headroom ≥ expectedBytes`, where `headroom = volumeAvailable − reserve − Σ expectedBytes(jobs in downloading ∪ verifying ∪ committing)`. If there is not enough:
- reclaim pending (GC deadline in the heap) → `blocked(.awaitingSpace)`; the alarm runs GC, `freeSpace` is re-read, `pump()`. Event-driven, no polling.
- nothing pending → `blocked(.insufficientSpace)`; the run ends `.blocked(.insufficientSpace)`.

An ENOSPC from another app filling the disk mid-run is per-asset (§8.1), and its staged bytes are removed by the store.

### 12.2 `availability(scope:)` and `ensureAvailable(scope:)` (R-SYN-10)

```swift
public struct AvailabilityReport: Sendable, Equatable, Codable {
    public var scope: AssetScope
    public var total, present, missing, stale, failed, unverified: Int
    public var bytesMissing: Int64
    public var manifestFresh: Bool            // true iff a manifest fetch succeeded (or returned 304) for this report
    public var generation: UInt64
    public var isComplete: Bool { self.missing == 0 && self.stale == 0 && self.failed == 0 }
}
```

- **`availability(scope:)`** is `async`, with **no network and no file-system I/O**. It is a pure function over the latest snapshot and the engine's failure ledger, run off the actor (`@concurrent`) for large scopes. Cancellation: checked between chunks of 2,048 entries.
- **`ensureAvailable(scope:) async throws(AssetError) -> AvailabilityReport`** (fetch-first, like `verifyFullyAvailable` + `verifyAndRepair`):
  1. Single-flight conditional manifest fetch. If offline or unreachable, fall back to the applied manifest: if the scope is complete, **return** the report with `manifestFresh = false`; otherwise **throw** the mapped error (`.offline`, …).
  2. Plan with `scope` (`includeOnDemand = true` when the scope is `.identifiers`), space-check (§12.1), reconcile.
  3. Register **one group interest** at `userInitiated` (batch sub-queue, §7.2) on every fetch; await completion inside `withTaskCancellationHandler`. **Cancellation:** the group is withdrawn (one hop), each job loses one interest, so jobs also wanted by a bulk run keep running and the rest are cancelled. The call throws `.cancelled`.
  4. Return the recomputed report. Per-asset failures do **not** throw; the caller checks `isComplete`. It throws only when the guarantee cannot be attempted at all: `.offline` with missing assets, `.insufficientSpace`, `.authRejected`, `.serverUnavailable` (breaker open), `.shutDown`, `.cancelled`, `.storageUnavailable`.

### 12.3 Refresh policies, `isSyncDue`, `lastSyncedAt`, and the stamp in the index (R-SYN-9)

```swift
public enum RefreshPolicy: Sendable, Hashable { case oncePerAppVersion, everyLaunch, atMostEvery(TimeInterval) }  // default .oncePerAppVersion
public struct SyncStamp: Sendable, Hashable, Codable {   // persisted INSIDE index.bin (R-STO-2), never UserDefaults
    public var appVersion: String          // "<CFBundleShortVersionString>+<CFBundleVersion>" (prior-art format, RECON §5)
    public var completedAt: Date           // TimeSource.now() at completion
    public var manifestETag: String?
    public var manifestDigest: ManifestDigest
}
enum RefreshDecision {                      // pure; exhaustively tested
    static func isSyncDue(policy: RefreshPolicy, stamp: SyncStamp?, appVersion: String,
                          now: Date, syncedThisLaunch: Bool) -> Bool
}
```

| Case | Due? |
|---|---|
| `stamp == nil` (fresh install, purge, OS-purge recovery R-CLN-7, corrupt index) | yes |
| `stamp.appVersion != appVersion` | **always** yes |
| `.oncePerAppVersion` | no |
| `.everyLaunch` | iff `¬syncedThisLaunch` (in-memory) |
| `.atMostEvery(i)` | iff `now − completedAt ≥ i`, **or** `completedAt > now + 300 s` (the wall clock went backwards: sync rather than stay stuck) |

- **The stamp is written only when a run ends `.complete`**, as the run's last store call (RE-S11), guarded by `ifPurgeEpoch`. This is prior-art parity: an interrupted or partial sync is retried on the next launch (`CDNSyncCoordinator.swift:10-15`). A forced repair that completes also stamps. That is harmless and true; the prior art skipped it only because its flag meant "once per version".
- `isSyncDue() async -> Bool` and `lastSyncedAt() async -> Date?` read the engine's snapshot copy: no I/O, no network.
- The legacy `UserDefaults` key `ZTronCarouselCore.CDNSyncCoordinator.lastSyncedVersion` is migrated into the stamp by the store's migration (H-10), with `completedAt` set to the migration time (so `.atMostEvery` stays not-due for one interval), and then removed.

### 12.4 Purge makes a sync due (R-CLN-6)

`purge(_:) async throws(AssetError) -> PurgeResult`:
1. `purgeEpoch += 1` (before any await, RE-S24).
2. Cancel the active run (outcome `.failed(.cancelled)`; its stamp write is refused by the epoch guard).
3. Withdraw bulk and prefetch interests on purged ids. `userInitiated` waiters for purged ids re-queue: the user is looking at that page.
4. `store.purge(request)` clears the stamp **in the same index commit** as the purge.
5. Emit `.assetRemoved(id, .purged)` and `.snapshotChanged`. Afterwards `isSyncDue() == true` and `lastSyncedAt() == nil`.

Q-8 probe "forget to reset the sync stamp after a purge" is caught by `R-CLN-6: purge(.evictable) makes isSyncDue true and clears lastSyncedAt`.

### 12.5 Run lifecycle and outcome (R-SYN-6)

`sync(_ mode: SyncMode = .ifDue) async -> SyncOutcome` is single-flight: a second caller joins the active run and receives the same outcome. Its steps are RE-S04 … RE-S11. Each job is independent, so one failure never aborts the run (D-2).

```swift
public enum SyncOutcome: Sendable, Equatable {
    case notDue(lastSyncedAt: Date?)
    case complete(SyncReport)
    case completeWithFailures(SyncReport)          // ≥ 1 asset failed; the stamp is NOT written
    case blocked(BlockReason, SyncReport)          // policy / breaker / space blocked all remaining work
    case failed(AssetError)                        // nothing could start (manifest unreachable, insufficientSpace, shutDown, cancelled)
}
public struct SyncReport: Sendable, Equatable, Codable {
    public var runID: SyncRunID, trigger: SyncTrigger, startedAt: Date, finishedAt: Date, manifestFresh: Bool
    public var planned: PlanTotals
    public var fetched, reused, relocated, pruned, evicted, failedCount: Int
    public var bytesDownloaded: Int64
    public var failures: [AssetFailure]            // sorted by id; first 1,000 (failedCount is exact)
}
```

**`blocked` semantics:** when every remaining job is blocked (policy, breaker, space), the run ends immediately as `.blocked(reason, partial report)`, drops its interests, and sets `pendingRunOnConditions` / `pendingRunOnBreakerClose`. A fresh run starts automatically when the gate opens. Nothing waits on a timer, and no job lingers for nobody.

### 12.6 `performMaintenance(timeBudget:)` (R-SYN-16)

`deadline = monotonicNow() + timeBudget`. Steps: drain access stamps → staging GC → orphan GC → eviction down to the hysteresis target → resumable deep verification (R-INT-4, cursor persisted by the store). Each is an `await store.x(until: deadline)` that processes bounded batches (P-13: ≤ 5 ms each), checking the deadline and `Task.isCancelled` between batches (RE-S23). Designed for a `BGProcessingTask` handler, whose expiration handler cancels the task. Emits `.maintenanceFinished(report)`. Test: `R-SYN-16: maintenance stops at its time budget on ManualTimeSource and resumes verification where it stopped`.

### 12.7 `shutdown()` (R-SYN-15)

Single-flight and idempotent: a second call awaits the first.
1. `lifecycle = .shuttingDown`. From now on, every entry point fails with `.shutDown`, and `pump`, `arm` and `ensureWatcher` refuse to spawn.
2. Cancel every owned task (drivers, alarm, watcher, run). The transfer streams terminate, so the transport cancels.
3. Resume every waiter with `.failure(.shutDown)`; fail pending groups; resolve unknown-id waiters.
4. `for t in ownedTasks.values { await t.value }` (RE-S21): every owned task has **finished**, not merely been cancelled.
5. `await store.close()`: flush the index, release the lock.
6. Publish `.clientShutDown` (the last event); queues drain, then `nil`. Then `lifecycle = .shutDown`.
7. The facade empties the mirror, so `lookup` returns `nil`: no URL is handed out after the store's guarantees end.

`AssetClient.deinit` spawns `Task { await engine.shutdown() }` (the same pattern as P3), so a client dropped without calling shutdown still releases everything.

**Proof (SPEC §7.3):** `R-SYN-15: shutdown mid-flight cancels every transfer, finishes every stream and leaves zero owned tasks, sleepers and observers`. Assertions: `ownedTasks == 0`, `armedTimers == 0`, `waiters == 0`, `subscribers == 0`; `ManualTimeSource.pendingSleepers == 0`; `FakeRemoteSource.activeTransfers == 0`; `FakeConditionsSource.activeObservers == 0`; every pending `resolve` threw `.shutDown`; every subscriber's last event is `.clientShutDown`; a later `resolve` throws `.shutDown`; `lookup` returns `nil`.

---

## 13. The facade `AssetClient` (SPEC §4.5; R-CAR-1, 2, 4, 5, 7, 8; R-OBS-1…3; P-1, P-8, P-12)

### 13.1 Surface (exact; `ZTronAssetKit`)

```swift
public final class AssetClient: Sendable {          // immutable stored properties only
    public init(configuration: AssetClientConfiguration, environment: AssetEnvironment = .live)
    public func start() async                        // idempotent, single-flight; see 13.2
    @MainActor public func lookup(_ id: AssetID, extensions: [String] = []) -> AssetLocation?    // O(1), zero I/O
    public func resolve(_ id: AssetID, priority: AssetPriority = .userInitiated) async throws(AssetError) -> URL
    public func prefetch(_ ids: [AssetID], priority: AssetPriority = .prefetch) -> PrefetchHandle
    public func availability(scope: AssetScope) async -> AvailabilityReport
    public func ensureAvailable(scope: AssetScope) async throws(AssetError) -> AvailabilityReport
    public func withAsset<T: Sendable>(_ id: AssetID, _ body: @Sendable (URL) async throws -> T) async throws -> T   // lease (R-CAR-8)
    public var events: AsyncStream<AssetEvent> { get }
    public func subscribe() async -> AsyncStream<AssetEvent>
    public func sync(_ mode: SyncMode = .ifDue) async -> SyncOutcome
    public func isSyncDue() async -> Bool
    public func lastSyncedAt() async -> Date?
    public func storageReport() async -> StorageReport
    public func purge(_ request: PurgeRequest) async throws(AssetError) -> PurgeResult
    public func performMaintenance(timeBudget: TimeInterval) async
    public func reportUnreadable(_ id: AssetID) async                              // R-CLN-8
    public func metrics() async -> MetricsSnapshot                                 // R-OBS-2
    public func diagnosticReport() async -> Data                                   // R-OBS-3, JSON
    public func shutdown() async
}
public struct AssetLocation: Sendable, Hashable {
    public let url: URL
    public let fileExtension: String
    public let integrity: Integrity                   // .verified | .unverified (R-INT-5)
    public let isStale: Bool                          // content changed upstream, new bytes not yet committed
}
```

`purge` is typed (`throws(AssetError)`), a deliberate narrowing of SPEC §4.5's untyped sketch (ADR-004). `withAsset` stays untyped because the body is the caller's.

### 13.2 `init` and `start()` — what is deferred (P-12)

`init` (≤ 1 ms, **no I/O on the caller's thread**) only: validates and clamps the configuration (pure); stores it and the environment; creates `AssetStore` (an actor whose initializer touches nothing: the root URL is resolved in `open()` through `FileSystem`); creates `SyncEngine` (empty tables, empty subscriber set); creates `SnapshotMirror` through its `nonisolated init` with `AssetSnapshot.empty` (compiled: §16 P3). It does not read `Bundle`, `UserDefaults` or `FileManager`, does not access `ProcessInfo`, and starts no task.

**Deferred to `start()`:** root resolution, lock, index load (P-2), legacy migration (H-10), launch reconciliation (R-CLN-7), staging GC (R-CLN-3), publishing the first snapshot to the mirror, reading the app version (`AppVersionSource`, i.e. `Bundle.main.infoDictionary`, off-main), re-attaching background transfers (H-6), the refresh decision, and launching the due run as an engine-owned task. **`start()` returns when the client is ready**; it does not wait for the sync. Callers that want to wait use `sync()`.

**Every async API awaits `ensureStarted()`** (RE-S26), so `resolve` before `start` neither hangs nor fails. `lookup` before `start()` completes returns `nil` (empty mirror). That is a deliberate deviation: the prior art loaded its manifest synchronously on first access, which was itself main-thread I/O (D-15). The fallback chain then reaches step 3, which completes from local storage as soon as the store is open (§17 R-6).

Tests: `P-12: AssetClient.init completes within init_ms_max and performs no file-system call` (benchmark; reads `FakeFileSystem.calls` and wall time) and `R-CAR-1: init touches neither the file system nor Bundle and spawns no task`.

### 13.3 `lookup` and `SnapshotMirror` (P-1, P-8, R-STO-7, R-STO-13)

```swift
@MainActor public final class SnapshotMirror {
    public private(set) var snapshot: AssetSnapshot
    nonisolated public init(initial: AssetSnapshot)
    /// The store's snapshot sink: monotonic (older generations are ignored, so an out-of-order publish is harmless).
    /// Returning from this call is the "published" acknowledgement the store needs before it may delete (I-3, H-2).
    public func publish(_ snapshot: AssetSnapshot)
    func lookup(_ id: AssetID, extensions: [String], now: Date) -> AssetLocation?   // dictionary probe + extension filter
    func drainAccesses() -> [AssetID: Date]                                          // AccessLogSource (§3.2, D-KIT-4)
}
```

`lookup` = one dictionary probe on the immutable `AssetSnapshot`, with a precomputed `AssetLocation` (no URL building), plus `extensions.isEmpty || extensions.contains(location.fileExtension)`, plus one access-stamp write into `accessLog[id] = time.now()`. The access log is bounded by catalog size: one entry per asset, latest wins. It is drained by the engine before any eviction decision (RE-S08) and during maintenance. **Zero file-system calls, zero hashing, zero tasks.** Prototype: p99 **0.21 µs** at N = 10,000, against a 25 µs budget; p99 ratio 10k/100 = **0.62**, against 3.0 (§16 P11).

**P-8 proof:** the benchmark and the test `R-STO-7: lookup, prefetch, events and resolve entry make zero file-system calls on the main thread` run every UI-facing call on the main actor with `FakeFileSystem` recording the calling thread, then assert `mainThreadCalls == 0` and each call ≤ `ui_call_ms_max`. The `resolve` entry measured is the synchronous part up to its first suspension.

### 13.4 The fallback chain without UIKit (R-CAR-2)

```swift
public protocol BundleLookup: Sendable {                       // the bundle step is the caller's
    func url(forResource name: String, withExtension ext: String) -> URL?
}
public struct MainBundleLookup: BundleLookup { … Bundle.main.url(forResource:withExtension:) … }   // live
public enum AssetKind: Sendable, Hashable {
    case image                                                 // ["heic", "png", "jpg", "jpeg"] (BasicImagePage order)
    case svg                                                   // ["svg"]
    case video(fileExtension: String)                          // the descriptor's extension (BasicVideoPage)
    case audio                                                 // ["wav", "mp3"]
    public var candidateExtensions: [String] { get }
}
public struct AssetFallbackChain: Sendable {
    public init(client: AssetClient, bundle: any BundleLookup = MainBundleLookup())
    /// Steps 1–2, synchronous: bundle (each candidate in order), then local (the snapshot, no I/O).
    @MainActor public func locate(_ id: AssetID, kind: AssetKind) -> ChainHit?      // .bundle(URL) | .local(AssetLocation)
    /// Step 3, asynchronous, userInitiated: resolve (fetch-first for unknown ids, single-flight, typed errors).
    public func fetch(_ id: AssetID, kind: AssetKind) async throws(AssetError) -> URL
}
```

- `AssetClient.lookup` itself never touches the bundle, keeping P-1/P-8 pure. The bundle step uses the injected `BundleLookup`, exactly what the prior art did in UI code. Asset catalogs (`UIImage(named:)`) stay in the carousel's UIKit adapter (R-CAR-9).
- **Deliberate deviation (for owner review):** the prior art's step 2 (`existingLocalURL`) returned a manifest-known local file **without** checking candidate extensions (`CDNLocalStore.swift:157-163`), while step 3 checked them (`CDNAssetResolver.swift:46`). The chain applies the extension filter in both steps, so it never hands an `.mp4` to an image decoder. A parity test documents this.
- **Parity cases** (§15.9) re-express the prior-art behaviour. There are no pre-existing tests to port (BASELINE).

### 13.5 `resolve`, `prefetch`, `withAsset`, `events` semantics

- **`resolve`:** `ensureStarted` → `engine.awaitAsset(id, lane)` (§6.2): fast path if present (no transfer, `metrics.resolveHits`); joins an in-flight job (`resolveJoins`, promoting it); or point-admits an unknown id (§6.5). Cancelling the caller's task → `.cancelled` for that caller only.
- **`prefetch`:** synchronous, returns a handle (§6.3); `priority` is normally `.prefetch`, and `.bulk` is allowed for warm-up lists.
- **`withAsset`:** `lease = try await store.lease(id)`; resolve if not present; run `body(url)`; release the lease in every path (success, throw, cancellation). While leased, eviction and prune never delete the blob (R-CLN-5).
- **`events`/`subscribe`:** §10.

### 13.6 Typed errors (R-CAR-7) and typed throws at iOS 15 (ADR-004, R-ENV-6)

```swift
public enum AssetError: Error, Sendable, Equatable {
    case offline
    case authRejected(AuthRejection)                      // .confirmed (401 / manifest 403) | .ambiguous (object 403: bad key OR missing object)
    case notFound
    case insufficientSpace(required: Int64, available: Int64)
    case integrityFailure
    case serverUnavailable(retryAfter: TimeInterval?)
    case cancelled
    case storageUnavailable
    case shutDown                                         // R-SYN-15: any API after shutdown
}
```

This is the R-CAR-7 set, plus `shutDown` (R-SYN-15) and the R-NET-6 ambiguity flag on `authRejected` (a 403 is never silently one or the other). Mapping: `TransferError` per §8.1; `StoreError` → `.storageUnavailable`, except ENOSPC → `.insufficientSpace` and integrity → `.integrityFailure`; a structurally invalid manifest (R-MAN-2) → `.serverUnavailable(retryAfter: nil)`, because the server published something unusable and the user cannot fix it. The internal error is kept for diagnostics. **Typed throws at iOS 15 compile and link**: `public func resolve(…) async throws(AssetError) -> URL`, a stored `@Sendable () async throws(AssetError) -> Int`, generic `throws(E)`, and `do throws(AssetError) { } catch { switch error … }` (§16 P2). Internally the engine carries `Result<_, AssetError>` through `CheckedContinuation<_, Never>`, so no untyped throwing continuation is needed.

### 13.7 Observability (R-OBS-1, R-OBS-2, R-OBS-3)

- **Logging:** `enum AssetLog` holds `static let` `Logger`s and `OSSignposter`s (immutable configuration) for subsystem `com.ztron.assetkit`, categories `store`, `sync`, `transport`, `apple`. All three types are `Sendable` at iOS 15 (§16 P3). Signpost intervals: `plan` (sync), `transfer` (sync: an interval spanning `downloading`, with its `OSSignpostIntervalState` held in the `Job`), `verify`, `commit`, `gc`, `eviction` (store). Privacy: counts and states are `.public`; ids and URLs are `.private(mask: .hash)`; the app key is never interpolated (its type redacts itself, R-NET-4/R-SEC-1).
- **Test seam:** every log call goes through `AssetLog.emit(category, level, message)`, which also feeds an optional `LogTap` from the environment (`nil` in `.live`). Tests assert the rendered text: canary key absent, ids hashed. `os.Logger` output itself is not inspected.
- **`MetricsSnapshot`** (`Sendable`, `Equatable`, `Codable`): `bytesDownloaded`; `manifestRequests` / `manifestNotModified`; `transferRequests`; `retries[FailureClass]` / `failures[FailureClass]`; `lookupHits` / `lookupMisses` (main-actor counters in the mirror); `resolveHits` / `resolveJoins` / `resolveTransfers`; `promotions`, `preemptions`; `evictions`, `evictedBytes`, `gcBytes` (store); `integrityFailures`; `breakerTrips`; `eventsCoalesced`, `eventsDelivered`; `illegalTransitions` (must be 0). `metrics()` composes engine, store and mirror counters: one hop each, values only.
- **`diagnosticReport()`:** JSON of `DiagnosticReport` (`Codable`): module version, index schema and generation, app version, the configuration with secrets replaced by `"<redacted>"`, engine introspection counts, breaker state, the stamp, the last 32 errors (ring buffer: time, asset id, internal error description, class), plus metrics and the storage report. Test: `R-OBS-3: diagnosticReport is valid JSON, contains state counts and the last errors, and never the canary key`.

### 13.8 Budgets carried by this design

| Budget | Mechanism | Prototype / argument |
|---|---|---|
| P-1 | Dictionary probe on an immutable value; precomputed `AssetLocation` | p99 0.21 µs at 10k; ratio 0.62 (P11) |
| P-4 | Single-pass planner, sort only the churn, off-actor | 1.74 ms; ×1.82 when N doubles (P10) |
| P-7 | Jobs exist only for outstanding work; transfers stream to disk; hashing in ≤ 1 MiB buffers (store); pipeline ≤ `2 × max`; event queues bounded (§10.4) | Memory scales with outstanding *count*, never with catalog *bytes*. Benchmark: `P-7: a 1 GiB synthetic bulk sync adds at most sync_memory_delta_mib_max MiB` |
| P-8 | `lookup` is a value read; `prefetch`/`events` create one handle and one task; no file system on main | Asserted by thread-recording `FakeFileSystem` |
| P-9 | The engine never blocks: manifest decode on the blocking executor (ADR-003); planner off-actor (~2 ms); hashing off-pool (store) | `P-9: 64 concurrent resolves plus hashing keep heartbeat gap p99 within budget` |
| P-12 | `init` allocates three objects, does no I/O, starts no task | §13.2 |
| P-14 | One alarm iff deadlines exist; watcher iff work exists; census | §8.4 |

---

## 14. Failure analysis

| # | Failure | Where | Detection | Engine response | Visible to | Test (display-name prefix) |
|---|---|---|---|---|---|---|
| F1 | One of N waiters cancels | `withdraw` | `onCancel` hop | Only that waiter resumes `.cancelled`; the transfer continues | that caller | R-SYN-4 |
| F2 | The last waiter cancels mid-download | T13 | interests empty | `driver.cancel()` → stream terminated → transport cancels; staging removed by GC | — | R-SYN-4, R-CAR-4 |
| F3 | Cancellation hop arrives after completion | `withdraw` | `removeValue == nil` | no-op (exactly-once) | — | R-SYN-4 |
| F4 | Caller cancelled before `join` runs | continuation body | `Task.isCancelled` | resumes `.cancelled` without registering | that caller | R-SYN-4 |
| F5 | User opens a page whose asset is in bulk flight | T15 | interest lane rises | `.setPriority(.userInitiated)`, no restart | — | R-SYN-3 |
| F6 | All slots hold bulk; user needs a new asset | `pump` | user queue non-empty, `free == 0` | reserved slot, else preempt (pause with resume) | — | R-SYN-3 |
| F7 | Manifest 403 / 401 | breaker | `authRejected` | breaker opens; run `.blocked(.circuitOpen)`; resolves fail fast | `.authRejected(.confirmed)` | R-SYN-5 |
| F8 | One object 403s (OAC missing key) | §8.1 | `forbiddenAmbiguous` | that asset `untilEntryChanges`; breaker only after 3 distinct | `.authRejected(.ambiguous)` | R-SYN-5 |
| F9 | Sustained 5xx | breaker window | ratio ≥ 0.5 over ≥ 5 | open → half-open probe after cooldown | `.serverUnavailable` | R-SYN-5 |
| F10 | 429 + Retry-After | origin throttle | `throttled` | no transfer before `until`; user waits ≤ 2 s or fails fast | `.serverUnavailable(retryAfter:)` | R-SYN-5 |
| F11 | Offline mid-sync | transfers fail `offline` | `failed(.whenOnline)` | parked; satisfied edge → re-queued | `.conditionsChanged` | R-SYN-13 |
| F12 | Repeated hash mismatch | T9 | integrity counter | backoff → quarantine until the entry changes (no loop) | `.integrityFailure` | R-INT-3 |
| F13 | Not enough space even after eviction | §12.1 phase 1 | pure check | run fails, **zero mutations** | `.insufficientSpace` | R-SYN-11 |
| F14 | Disk fills during the run (another app) | transfer / verify ENOSPC | store error | per-asset `blocked`; run `.blocked(.insufficientSpace)` | event | R-SYN-11 |
| F15 | A resolve commits while a run plans | RE-S09 | `.staleGeneration` | re-plan (≤ 3) | — | R-SYN-2 |
| F16 | Manifest entry changes while its job runs | T22 / RE-S15 | fingerprint check | cancel and restart with the new entry; interests carried | — | R-SYN-2 |
| F17 | Asset removed while a user waits | T21 | reconcile prunes it | waiter `.notFound` | that caller | R-SYN-2 |
| F18 | App killed mid-sync | — | next launch | no stamp ⇒ due; staging GC; committed blobs kept; only the remainder is fetched | — | R-SYN-9 (+ storage H-1) |
| F19 | Purge during a run | RE-S11 | `purgeEpoch` moved | the run cannot stamp; sync stays due | — | R-CLN-6 |
| F20 | Subscriber stalls | `SubscriberQueue` | — | bounded coalescing (§10.4) | — | R-SYN-12 |
| F21 | Subscriber cancelled / breaks / drops the stream | lease | `onCancel` / `deinit` | unsubscribe; pending pull resumed `nil` | — | R-SYN-12 |
| F22 | Handle never cancelled (leaked) | `PrefetchHandle.deinit` | ARC | release hop | — | R-CAR-4 |
| F23 | Wall clock jumps | `RefreshDecision` | `completedAt > now + 300 s` | treat as due | — | R-SYN-9 |
| F24 | Device sleeps through a backoff | alarm | wakes early or late | re-check `monotonicNow()`, re-arm | — | H-8 tests |
| F25 | Shutdown mid-flight | §12.7 | — | cancel, join, flush, finish streams | `.shutDown` | R-SYN-15 |
| F26 | Main actor busy when the store publishes | store sink await | — | deletion waits for the acknowledgement (safe direction) | — | storage I-3 |
| F27 | `store.open` fails (lock held, EIO) | RE-S01 | `StoreError` | lifecycle `.degraded`; lookups return `nil`; resolves throw | `.storageUnavailable` | R-CAR-7 |
| F28 | A programming error attempts an illegal transition | `transition` | `allows == false` | debug assert; release counter | metrics | R-SYN-2 |
| F29 | Background transfer finished while the app was dead | `start` RE-S03 | `reattachedTransfers()` | adopted as `verifying` / `downloading` jobs | — | transport H-6 |
| F30 | Unknown-id storm (a page of misspelt ids) | §6.5 | negative cache | ≤ 1 manifest fetch per 60 s | `.notFound` | R-CAR-2 |

---

## 15. Test plan

Swift Testing. Every test that awaits carries `.timeLimit(.minutes(1))`. One behaviour per test. Seeded generators print their seed on failure. No sleeping: time only moves through `ManualTimeSource.advance`, and progress is observed through `engine.waitUntil` or `EventProbe.next(where:)`. Suites that use `ManualTimeSource` are `@available(macOS 15.0, *)`. Display names start with the requirement ID, as `gates.py trace` requires. Names below are final unless Phase C renames a requirement.

### 15.1 Fakes and seams requested from WP-H (`ZTronAssetTestSupport`, zero unsafe escapes)

| Fake | Shape | Notes |
|---|---|---|
| `FakeRemoteSource` | `actor`, conforms to `RemoteSource` | Per-asset script: `.stage(bytes)`, `.fail(TransferError)`, `.hold` (until `release(id, with:)`), `.progress([Int64])`, manifest responses (200 / 304 / 403 / 429 + Retry-After). Records `starts` (in order), `priorityChanges`, `pauses`, `cancellations`, `activeTransfers`. It consumes `control` in one task per transfer, which ends with the transfer. |
| `FakeConditionsSource` | `actor`, `DeviceConditionsSource` | `send(_:)`, `activeObservers`. |
| `ManualTimeSource` | `final class`, `Mutex` (`@available(macOS 15, iOS 18, *)`) | §9.3. |
| `SeededRandom` | `struct`, `RandomSource` + `RandomNumberGenerator` (SplitMix64) | `makeGenerator()` returns a copy. |
| `RecordingBundleLookup`, `FakeAppVersionSource` | structs with `let` dictionaries | — |
| `RecordingLogTap` | `final class`, `Mutex` (macOS 15) | R-OBS-1, R-SEC-1. |
| `EventProbe` | `actor` | Subscribes through `subscribe()`; `next(where:)`; `drain()`; `all`. |
| `FakeFileSystem` | storage designer | Records the calling thread for P-8 / R-STO-7. |

Engine test hooks use `package` access (verified to compile: §16 P3): `introspect()`, `waitUntil(_:)`, `alarmEpoch`.

### 15.2 State machine and model-based (R-SYN-2)
- `R-SYN-2: the transition table admits exactly the listed transitions`: exhaustive over (state × event), with every other pair rejected.
- `R-SYN-2: 10,000 seeded random operations never leave the transition table and keep every engine invariant`: operations are want / withdraw / stage / fail / verify-fail / commit-stale / promote / conditions / alarm / reconcile(prune, change) / purge / shutdown. Checked against a trivial oracle (interest sets, the expected terminal result per waiter). `illegalTransitions == 0`.
- `R-SYN-2: a job superseded during verification never commits its stale content`
- `R-SYN-2: a resolve committing during planning forces a re-plan and loses no update`
- `R-SYN-2: an asset removed from the manifest while a user waits fails that waiter with notFound`

### 15.3 Single-flight and cancellation (R-SYN-4; SPEC §7.3 concurrency scenarios)
- `R-SYN-4: 100 callers on one asset with seeded random cancellations share one transfer and each resumes exactly once` (asserts `FakeRemoteSource.starts.count == 1`, success for survivors, `.cancelled` for the cancelled; 50 seeds)
- `R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels` (`cancellations` stays 0 until the last withdrawal, then 1)
- `R-SYN-4: a cancellation storm of 1,000 interleaved joins and withdrawals across 50 assets leaves no waiter, interest or transfer behind`
- `R-SYN-4: a caller cancelled before joining fails with cancelled and registers nothing`
- `R-SYN-4: a cancellation racing completion yields success or cancelled but never both`
- `R-SYN-4: withdrawing the highest-priority interest demotes the running transfer`

### 15.4 Handles and the window (R-CAR-3, R-CAR-4)
- `R-CAR-4: cancelling a prefetch handle cancels transfers wanted by nobody else`
- `R-CAR-4: a handle released without cancel() releases its interest on deinit`
- `R-CAR-4: cancel() immediately after prefetch never leaves a transfer running`
- `R-CAR-4: a prefetched asset also awaited by resolve keeps downloading after the handle is cancelled`
- `R-CAR-3: window targets are current, then ±1, then ±2, clamped at both ends`
- `R-CAR-3: moving the window by one cancels exactly the asset that left and starts exactly the one that entered`
- `R-CAR-3: a neighbour that becomes current is promoted without a second transfer`
- `R-CAR-3: overlapping windows never duplicate a transfer`

### 15.5 Lanes and parallelism (R-SYN-3, R-NET-10)
- `R-SYN-3: a userInitiated request for an in-flight bulk asset promotes it without restarting the transfer` (SPEC §7.3 promotion scenario)
- `R-SYN-3: a userInitiated request for a queued bulk asset jumps ahead of every bulk and prefetch job`
- `R-SYN-3: with every slot busy in bulk, a new userInitiated asset starts in the reserved slot`
- `R-SYN-3: with concurrency 1 a userInitiated request preempts the bulk transfer, which later resumes`
- `R-SYN-3: never more than maxConcurrentTransfers transfers count as running for every setting 1…16`
- `R-SYN-3: concurrency outside 1…16 is clamped and reported in diagnostics`
- `R-SYN-3: a bulk job waiting longer than bulkAging overtakes prefetch work`
- `R-NET-10: a promoted asset's priority change reaches the transport before any other transfer starts`

### 15.6 Retries, breaker, conditions, idle (R-SYN-5, -6, -7, -13, -14, R-ENV-1)
- `R-SYN-5: 5xx failures retry at full-jitter delays reproduced from the seed on ManualTimeSource`
- `R-SYN-5: no transfer starts before a 429's Retry-After elapses on ManualTimeSource`
- `R-SYN-5: an asset stops retrying after maxAttemptsPerRun and the run completes with failures`
- `R-SYN-5: three ambiguous 403s on distinct assets open the auth breaker but one does not`
- `R-SYN-5: an ambiguous 403 is never retried with backoff`
- `R-SYN-5: a manifest 403 opens the breaker and resolve fails fast without a request`
- `R-SYN-5: sustained 5xx opens the breaker and a single half-open probe closes it`
- `R-SYN-6: one failing asset among 100 never aborts the sync and is listed in the report`
- `R-SYN-6: a run blocked by policy ends blocked and a new run starts when the policy admits`
- `R-SYN-7: bulk pauses on Low Data Mode and resumes when it is turned off`
- `R-SYN-7: Low Power Mode pauses bulk but not userInitiated`
- `R-SYN-7: thermal serious pauses running bulk transfers with resume data`
- `R-SYN-7: expensive networks follow NetworkPolicy for bulk and prefetch`
- `R-SYN-13: assets that failed offline are retried when the path becomes satisfied without any timer`
- `R-SYN-13: transient failures in backoff are retried early on a satisfied edge`
- `R-SYN-14: after a sync quiesces the engine owns zero timers and zero tasks and observes nothing`
- `R-SYN-14: one alarm serves many retry deadlines and is cancelled when the last one is withdrawn`
- `R-ENV-1: no production source outside the live conformers calls Date(), DispatchTime.now(), Task.sleep or SystemRandomNumberGenerator` (scans `Sources/` via `#filePath`)
- `R-ENV-1: LiveTimeSource returns immediately for a past deadline and throws promptly when cancelled`
- `R-ENV-1: ManualTimeSource wakes sleepers in deadline then registration order`

### 15.7 Events (R-SYN-12; SPEC §7.3 stalled and terminating subscribers)
- `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync`
- `R-SYN-12: terminal events reach a stalled subscriber in publication order after it resumes`
- `R-SYN-12: transfer progress published to subscribers never exceeds 10 Hz per asset under ManualTimeSource`
- `R-SYN-12: a subscriber cancelled while waiting is removed and its pending pull returns nil`
- `R-SYN-12: a subscriber that breaks out of its loop is removed when its stream is released`
- `R-SYN-12: two subscribers receive the same terminal events independently of each other's pace`
- `R-SYN-12: a new subscriber first receives the current snapshot and run progress`
- `R-SYN-12: clientShutDown is the last event every subscriber receives`

### 15.8 Runs, availability, refresh, space, shutdown (R-SYN-6 … -11, -15, -16, R-CLN-6)
- `R-SYN-8: reconcile is committed before the first transfer starts`
- `R-SYN-9: refresh policies decide due-ness exhaustively including app-version change and clock skew`
- `R-SYN-9: the stamp is stored in the index and written only after a complete run`
- `R-SYN-9: deleting the store root makes the next launch due`
- `R-CLN-6: purge(.evictable) makes isSyncDue true and clears lastSyncedAt`
- `R-CLN-6: a run finishing after a purge does not write the stamp`
- `R-SYN-10: availability counts present, missing, stale and failed without any network request`
- `R-SYN-10: ensureAvailable fetches missing in-scope assets at userInitiated priority`
- `R-SYN-10: cancelling ensureAvailable cancels transfers wanted by nobody else and throws cancelled`
- `R-SYN-10: ensureAvailable offline returns a complete report from the applied manifest or throws offline`
- `R-SYN-11: a plan that cannot fit even after eviction fails with insufficientSpace and leaves index, blobs and staging byte-identical`
- `R-SYN-11: eviction is committed with reconcile and never evicts an in-scope asset`
- `R-SYN-11: fetches wait for space reclaimed after the grace window instead of failing`
- `R-SYN-15: shutdown mid-flight cancels every transfer, finishes every stream and leaves zero owned tasks, sleepers and observers` (SPEC §7.3)
- `R-SYN-15: every API after shutdown fails with shutDown and lookup returns nil`
- `R-SYN-15: concurrent shutdown calls are idempotent`
- `R-SYN-16: maintenance stops at its time budget on ManualTimeSource and resumes verification where it stopped`

### 15.9 Facade, parity, errors, observability (R-CAR-1, -2, -5, -7, -8, R-OBS-*, R-STO-7, R-STO-13, R-SEC-1)
- **Parity (SPEC §7.3 "facade parity"):**
  - `R-CAR-2: a bundle hit wins over a local copy`
  - `R-CAR-2: image candidates are tried in heic, png, jpg, jpeg order`
  - `R-CAR-2: a local asset is found synchronously with zero file-system calls when the bundle misses`
  - `R-CAR-2: a local asset whose extension is not a candidate is not returned`
  - `R-CAR-2: when bundle and local both miss, fetch downloads at userInitiated and the next locate hits local`
  - `R-CAR-2: an identifier unknown to a freshly fetched manifest fails with notFound`
  - `R-CAR-2: an offline fetch fails with offline and succeeds after the path becomes satisfied`
  - `R-CAR-2: svg, video and audio kinds use their candidate extensions`
  - `R-CAR-2: a stale local copy is returned while its new content downloads`
  - `R-CAR-2: misspelt identifiers trigger at most one manifest fetch per refetch interval`
- `R-CAR-1: init touches neither the file system nor Bundle and spawns no task`
- `R-CAR-1: every async API awaits start so a resolve before start succeeds`
- `R-CAR-5: identifier, tag and prefix scopes select the same entries in planning and availability`
- `R-CAR-7: every TransferError and StoreError maps to the documented AssetError`
- `R-CAR-7: resolve throws a typed AssetError that callers switch over exhaustively`
- `R-CAR-8: a leased asset survives eviction and purge until the lease ends`
- `R-CAR-8: withAsset releases its lease when the body throws or is cancelled`
- `R-STO-7: lookup, prefetch, events and resolve entry make zero file-system calls on the main thread`
- `R-STO-13: lookup never observes a torn snapshot while generations are published concurrently`
- `R-OBS-1: every log line uses subsystem com.ztron.assetkit and one of the four categories with identifiers hashed`
- `R-OBS-1: plan, transfer, verify, commit, gc and eviction signpost intervals begin and end in pairs`
- `R-OBS-2: metrics count bytes, requests, retries and failures by class, hits, misses, evictions and GC bytes`
- `R-OBS-3: diagnosticReport is valid JSON with state counts and the last errors and never the canary key`
- `R-SEC-1: no log line, error, report or Mirror of AssetClient contains the canary key`
- **Live conformers** (coverage without sleeping): `LiveTimeSource` (above); `R-CAR-1: the live environment builds an AssetClient without starting anything`; `MainBundleLookup` and `LiveAppVersionSource` are exercised against the test bundle.

### 15.10 Benchmarks (`ZTronAssetKitBenchmarks`, release; thresholds read from `quality-gates.json`)
- `P-1: lookup on the main actor stays under lookup_p99_us at 10,000 assets and scales within scale_ratio_max`
- `P-4: planning 10,000 vs 10,000 entries with 10% churn stays within plan_ms and scales by at most doubling_ratio_max`
- `P-7: a 1 GiB synthetic bulk sync adds at most sync_memory_delta_mib_max MiB and does not grow with catalog size` (fake source, real files; `phys_footprint` sampled by a helper in the benchmark target, not in `Sources/`)
- `P-8: UI-facing calls make zero main-thread file-system calls and each stays within ui_call_ms_max`
- `P-9: 64 concurrent resolves plus hashing keep the heartbeat gap p99 within budget`
- `P-12: AssetClient.init completes within init_ms_max and performs no file-system call`
- `P-14: after quiescence the engine owns at most idle_timers_max timers and idle_tasks_max tasks` (`ManualTimeSource`; also asserts `pendingSleepers == 0`, `activeTransfers == 0`, `activeObservers == 0`)

### 15.11 Mutation probes this plan is designed to kill (Q-8)
| Probe | Killed by |
|---|---|
| Cancel the transfer when **any** waiter cancels | `R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels` |
| Ignore `Retry-After` | `R-SYN-5: no transfer starts before a 429's Retry-After elapses…` |
| Treat 403 as transient | `R-SYN-5: an ambiguous 403 is never retried with backoff` |
| Forget to reset the stamp after purge | `R-CLN-6: purge(.evictable) makes isSyncDue true…` |
| Resume a waiter twice / skip `removeValue` | the 100-caller test (a CheckedContinuation double resume traps) |
| Drop terminal events in favour of progress | `R-SYN-12: terminal events reach a stalled subscriber in publication order…` |
| Apply fetches before reconcile | `R-SYN-8: reconcile is committed before the first transfer starts` |
| Leave the watcher running when idle | `R-SYN-14: after a sync quiesces…` |

---

## 16. Compiler and runtime evidence

All probes live in `.build-probe-sync/` (git-ignored by `.build*`). Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), iPhoneOS 27.0 SDK. iOS commands:
`xcrun --sdk iphoneos swiftc -emit-library -parse-as-library -O -warnings-as-errors -target arm64-apple-ios15.0 -swift-version 6 <probe>.swift -o /dev/null`
This is a **full compile and link**, not only `-typecheck`, so back-deployment problems in SIL/IR generation would also surface. Runtime probes were built with `-target arm64-apple-macos12.0` and run on the macOS 27 host.

| Probe | What it proves | iOS 15 compile (`-warnings-as-errors`) | Runtime (macOS 27) |
|---|---|---|---|
| P1 `p1_streams.swift` | `AsyncStream.makeStream(of:bufferingPolicy:)`; `AsyncStream(_:bufferingPolicy:_:)` with `yield` results and `onTermination`; `AsyncStream(unfolding:onCancel:)` with an actor-backed `produce` | exit 0, 0 diagnostics | — |
| P2 `p2_singleflight.swift` | Actor + `withTaskCancellationHandler` + `withCheckedContinuation` whose body mutates actor state synchronously; `onCancel` → `Task` hop; `public func resolve() async throws(AssetError)`; a stored `@Sendable () async throws(AssetError) -> Int`; generic `throws(E)`; `do throws(AssetError)` | exit 0, 0 diagnostics | **200 seeds × 100 callers**, random cancellations: every caller resumed exactly once; "transfer cancelled" counted only when all 100 left; 0 waiters left. Pre-cancelled caller: `.cancelled`, nothing registered |
| P3 `p3b_handles.swift` | `PrefetchHandle` (`final class`, `let`s only) releasing in `cancel()` and `deinit` via `Task`; `@MainActor` mirror with a `nonisolated init` created from a nonisolated `init`; `Logger`, `OSSignposter`, `OSSignpostIntervalState` are `Sendable`; `clock_gettime_nsec_np(CLOCK_MONOTONIC)`; `Task.sleep(nanoseconds:)`; `package` access | exit 0, 0 diagnostics | — |
| P3 `p3_handles.swift` (variant) | Requiring `NWPathMonitor: Sendable` | **warning: "conformance of 'NWPathMonitor' to 'Sendable' is only available in iOS 17.0 or newer"** (macOS 14 on the host). **Not** escalated by `-warnings-as-errors` (exit 0), whereas a control warning in `p8_w.swift` was escalated (exit 1) | — |
| P4 `p4_events.swift` | Pull-based hub: `AsyncStream(unfolding:onCancel:)`, `SubscriptionLease` with release in `deinit`, continuation-backed `pull` | exit 0, 0 diagnostics | Cancelled and breaking subscribers removed (2 left: live + stalled); the stalled subscriber held **4 progress + 100 terminal slots** after 10,000 progress + 100 terminal events, in 8 of 8 runs; 0 subscribers after the stalled stream was released. Two prototype bugs found at runtime, both now covered by the design: (a) draining terminal slots before progress reorders events (fixed by the §10.3 single ordered queue, P4b); (b) `finished` set only on the buffered path made a subscriber that was already waiting hang after receiving shutdown (fixed: set on every path, §10.3; 8/8 runs then completed) |
| P4b `p4b_queue.swift` | The §10.3 `SubscriberQueue` (in-place progress, subject moved to tail, lazy deletion, compaction) | exit 0, 0 diagnostics | Stalled subscriber over 10,000 assets: **10,005 live slots**, peak 12,005 order entries (≤ 2 × live + 1); delivery in latest-publication order; 1,000 `failed` outcomes superseded by later `committed` for the same subject (coalescing, as defined in §2.5); `.shutdown` delivered last |
| P5 `p5_time.swift` | `TimeSource` with `sleep(until:) async throws(CancellationError)`; `LiveTimeSource`; `ManualTimeSource` on `Mutex` behind `@available(macOS 15.0, iOS 18.0, *)` | exit 0, 0 diagnostics (deployment target iOS 15) | Wake order `[2, 4, 3, 1]` (expected `[2, 4, 3, 1]`); cancelled sleeper threw; 0 sleepers left; live: a past deadline returned and a cancelled one-hour sleep threw immediately |
| P6 `p6_main.swift` | Handle release ordering | — | 1,000 handles, random immediate `cancel()` and random drop: **0** interest groups left |
| P7 `p7_conditions.swift` | Actor-owned `NWPathMonitor` + `NotificationCenter` observers feeding `AsyncStream.makeStream(…, .bufferingNewest(1))`, with `onTermination` hopping to stop; `@concurrent` function called from an actor | exit 0, 0 diagnostics | — |
| P9 `p9_main.swift` | `.bufferingNewest(1)` transfer stream with a slow consumer | — | Consumer saw only `[.finished("staging/x.part")]`; 99,999 progress yields displaced: the terminal element always survives |
| P10 `p10_planner.swift` | Planner prototype (§4.2), release | — | N = 10k: **1.74 ms**, N = 20k: **3.16 ms**, ratio **1.82** (best of 15); 500 fetches, 250 relocations, 250 prunes |
| P11 `p11_lookup.swift` | `@MainActor` mirror lookup with an extension filter, release | — | p99 **0.333 µs** at N = 100 and **0.208 µs** at N = 10k; ratio **0.62** |

SDK declarations read from `iPhoneOS27.0.sdk/usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-ios.swiftinterface`:
- `AsyncStream.makeStream` is `@available(iOS 13.0) @backDeployed(before: iOS 17.0)`.
- `withCheckedContinuation` and `withTaskCancellationHandler` have `@_alwaysEmitIntoClient nonisolated(nonsending)` overloads, available from iOS 13 (the latter with typed `throws(Failure)` and a `sending` `onCancel`). The older `isolation:` overloads are `@backDeployed(before: iOS 18.0)`.
- `AsyncStream.init(unfolding:onCancel:)` is part of the original iOS 13 surface. Its `@preconcurrency` lives in the SDK, not in our sources, so it does not count against the unsafe gate.

---

## 17. Open risks and questions for Phase B / Phase C

| # | Risk / question | Mitigation or ask |
|---|---|---|
| R-1 | **The iOS 15.0 runtime's** behaviour for `AsyncStream(unfolding:)` cancellation, `withTaskCancellationHandler` hops, and deinit-spawned tasks is proven only on macOS 27 (compilation proves availability, not behaviour). | Add to `DEVICE-TEST-PLAN.md`: run the R-SYN-4 / R-SYN-12 / R-CAR-4 suites on an iOS 15 simulator or device. |
| R-2 | "Terminal events never dropped" is implemented as *the latest terminal event of every subject*. A stalled subscriber's backlog is O(catalog), about 1.5 MB at 10k assets and 15 MB at 100k. | Adversaries should attack the definition. The alternative is a hard per-subscriber cap with a `resync` marker, which is smaller but is a visible drop. |
| R-3 | **Q-1 gap:** availability-of-`Sendable` warnings (for example `NWPathMonitor`) are not escalated by `-warnings-as-errors`, and `verify.sh` does not grep build logs. They would pass the "zero warnings" gate. | Report to the orchestrator (Scripts/ is frozen). Reviewers grep `warning:` in `.verify-logs`. This design avoids the case (actor-owned monitor). |
| R-4 | The transport must honour the `control` stream (`setPriority` within one turn; `pause` → resume data) and migrate promoted background-session transfers to the foreground session. | Phase C: reconcile §3.3 with the transport design (H-6). |
| R-5 | The storage contract needs `expectedGeneration` on `apply`, the two-phase `verify`/`commit` with a fingerprint guard, group commit with `urgency`, a snapshot-sink acknowledgement (I-3), deadlines driven by the engine's alarm, and `recordStamp(ifPurgeEpoch:)`. | Phase C: reconcile §3.2 with the storage design. |
| R-6 | Deviation: `lookup` returns local hits only after `start()` has published the first snapshot (the prior art read its manifest synchronously on main, which was D-15). Pages shown in the first tens of milliseconds after launch go through step 3, which completes from disk. | NEEDS-HUMAN-REVIEW (behavioural deviation, compatibility). |
| R-7 | Deviation: the extension filter is applied in step 2 as well (§13.4). | NEEDS-HUMAN-REVIEW (compatibility shims). |
| R-8 | The defaults for the 403 heuristic (3 distinct assets), the breaker windows and the policy defaults (`bulkOnExpensive = true`, `bulkInLowPowerMode = false`, Low Data Mode pauses bulk and prefetch) are judgement calls. | Owner review; every value lives in a configuration struct. |
| R-9 | P-9's heartbeat must tick in real time (10 ms), while Q-4 forbids real sleeping in tests. | Phase C ruling: benchmarks (excluded from the deterministic suite) may use a real-time heartbeat, or measure with a `DispatchSourceTimer`. |
| R-10 | `ManualTimeSource` and `RecordingLogTap` need macOS 15 (`Mutex`). Suites that use them carry `@available(macOS 15.0, *)` while the package's macOS floor stays 12. | Accepted per the brief. The alternative (actor fakes with async `now()`) was rejected (§2.4). |
| R-11 | `purge` during a run keeps `userInitiated` work alive but cancels the run. An owner may prefer purge to wait for the run. | Owner review. |

### 17.1 Reconciliation with `docs/design/store.md` (read after drafting; Phase C to decide)

The storage drafter's design landed in parallel. Where it chose differently from §3.2:

| # | Topic | `store.md` | This design (§3.2) | Proposed resolution |
|---|---|---|---|---|
| X-1 | Manifest application | `apply(_ manifest: ValidatedManifest, etag:) -> ApplyReport`: the store diffs and applies (relocate, prune → doomed, stale, adopt by hash) | `apply(ReconcileStep, eviction:, expectedGeneration:)`, computed by the planner | Keep the store's API, but (a) add `expectedGeneration:` (H-5, RE-S09); (b) the planner and `apply` must use the **same** R-MAN-4 `ManifestDiff`; (c) add the test `R-SYN-8: the store's ApplyReport equals the plan's reconcile step for seeded manifests` so the two cannot diverge. R-SYN-11's "no partial side effects" still holds, because the space decision (§12.1 phase 1) precedes `apply`. |
| X-2 | Space and eviction | `makeRoom(forAdditionalBytes:)`: "dry run, then evict" in one call | A pure `evictionPlan` before any mutation, then eviction committed with reconcile | Split `makeRoom` into a pure `evictionPlan(toFree:protecting:)` (the dry run) plus execution. The engine must be able to refuse **before** `apply` (§12.1). |
| X-3 | Publication | `publish(reservation, for:)`: verify and commit in one await; the expectation comes from the record (R-INT-6) | Separate `verify` / `commit` with a fingerprint guard | Accept one await (states V and C collapse into one engine await; §5.2 keeps both states for reporting). **Required addition:** `publish(…, expecting: EntryFingerprint)` returns `.staleEntry` **before hashing** when the record's fingerprint changed mid-transfer. Otherwise a legitimate catalog update is mis-counted as an integrity failure and can wrongly quarantine the asset (R-INT-3). |
| X-4 | Timers | A store-owned reaper task and a deferred-commit sleep, each existing only while pending | The engine's single alarm drives `store.nextDeadline()` | Either satisfies P-14. If the store keeps its own reaper, `EngineIntrospection` must add the store's task and timer counts, and wake order across the two sleepers is no longer engine-determined. Tests then rely on the environment census (`ManualTimeSource.pendingSleepers == 0`) and on `waitUntil` predicates rather than on cross-actor order. |
| X-5 | LRU access stamps | `SnapshotSink.install(_:) async -> [AssetID]`: the mirror returns ids accessed since the last install; the store re-installs before eviction to drain them | `AccessLogSource.drainAccesses()` called by the engine (RE-S08) | Adopt the store's contract: the mirror implements `install` (swap, then return the accessed ids). RE-S08 disappears from the engine ledger. |
| X-6 | Stamp | `markSynced(appVersion:)`, `markSyncDue()`, `syncStamp()` | `recordStamp(_:ifPurgeEpoch:)` | Adopt the store's calls. The purge guard moves to the engine: check `purgeEpoch` unchanged, then send `markSynced` in the same synchronous segment. Purge must be routed through the engine (it is: `AssetClient.purge` → engine → store), so the store actor serialises `markSynced` before any later `purge`. |
| X-7 | Store → engine events | `events: any StoreEventSink`, "non-blocking; bounded downstream (WP-F)" | Events are derived from the return values of store calls | Open. A synchronous sink into the engine actor needs either a hop per event (the D-8 pattern) or a long-lived consumer task (breaks P-14). Proposal: store calls return their removal and eviction facts, the engine publishes them, and reaper deletions emit nothing (the `assetRemoved` event was already published when the asset was unreferenced). |

## 18. Proposed ADRs (text for Phase C; this drafter did not edit `DECISIONS.md`)

- **ADR-S1 Single-flight via actor-held continuations and ref-counted interests (H-3)** — §2.1, D-SYNC-1.
- **ADR-S2 Lanes with a reserved interactive slot, in-place promotion through a transfer control stream, and preemption with resume data (H-4)** — §2.2, §7.
- **ADR-S3 Reentrancy discipline: epochs, optimistic generations, ledger (H-5)** — §2.3, §5.4.
- **ADR-S4 `TimeSource` without `Clock`; one engine alarm; `Mutex` only in a test-only fake (H-8)** — §2.4, §9.
- **ADR-S5 Pull-based event broadcast with per-key and per-subject coalescing (H-9)** — §2.5, §10.
- **ADR-S6 Facade: `lookup` is snapshot-only; the bundle step is injected; `init` does no I/O; `start()` is single-flight** — §13. Includes R-6 and R-7 as **NEEDS-HUMAN-REVIEW**.
- **ADR-S7 Network and power policy defaults** — §11.2. **NEEDS-HUMAN-REVIEW** (product choice).
