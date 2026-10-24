# Adversarial review #2 — `docs/design/sync.md`

> **Historical.** A Stage 1 adversarial review of a design draft, kept as written; each finding's resolution is in [ARCHITECTURE.md](../../ARCHITECTURE.md) §12, which with [DECISIONS.md](../../DECISIONS.md) is authoritative.

> **Lens:** liveness and resources. That covers lane starvation, retry storms, the circuit breaker, backoff on `ManualTimeSource`, unbounded buffers and backpressure, idle silence, network and power policy, free space and eviction before a plan, main-actor cost, the feasibility of P-1/P-4/P-7/P-8/P-9/P-12/P-14, and whether 90 % coverage of Sync is reachable.
> **Reviewer:** did not write the design. **Read:** `CLAUDE.md`, SPEC §1.4, 4.2, 4.5, 5.6, 5.8, 5.9, 6 and 7.3, `docs/RECON.md`, ADR-001…011, `docs/BASELINE.md`, `sync.md` in full, `store.md` (the parts the engine depends on), `Scripts/verify.sh`, `Scripts/gates.py`, `Scripts/quality-gates.json`, and the drafter's probes in `.build-probe-sync/`. I also read `reviews/sync-1.md` after writing my findings, so that overlaps are marked rather than repeated (§3).
> **Evidence:** every Swift or SDK claim below was compiled and, where it says so, **run** in `.build-probe-review-sync-2/` (git-ignored) with Apple Swift 6.4, the iPhoneOS 27 SDK and macOS 27 on an M3. Nothing outside this repository was written. Probe index: §5.

---

## 1. Summary

| ID | Severity | Finding | Violates |
|---|---|---|---|
| S2-01 | **critical** | The half-open breaker also wedges when its probe fails for a **different cause**. The most likely case is `offline`, because the probe fires at an arbitrary time. A wedged breaker hangs `ensureAvailable` and keeps the watcher alive forever. This extends S1-03. | R-SYN-5, R-SYN-10, R-SYN-13, R-SYN-14 |
| S2-02 | **critical** | With the store-owned reaper (X-4, as `store.md` §4.5 chose), `blocked(.awaitingSpace)` has **no wake-up source at all**. `ensureAvailable` then waits forever. X-4's "either satisfies P-14" is false. | R-SYN-10, R-SYN-11, liveness |
| S2-03 | major | One `429 Retry-After` blocks every queued job (origin throttle). §12.5 then ends the run and drops its interests, with no pending-run flag. The remaining sync waits for the next launch, which is the D-2 defect again. | R-SYN-5, R-SYN-6, D-2 |
| S2-04 | major | Integrity re-download loop. The counter lives in `Job` and dies with it, and the interactive cap (2) is below `maxIntegrityFailures` (3). T20 also contradicts `store.md`'s persisted `nextEligibleAt`. Each visit to a corrupt asset downloads it again, without bound. | R-INT-3, R-SYN-5 |
| S2-05 | major | An ambiguous object 403 is persisted as quarantine "until the entry changes". A transient key or edge fault therefore removes assets **permanently**, and every half-open probe adds one more. | R-NET-6, SPEC §2.3, R-SYN-5 |
| S2-06 | major | The §12.1 formula fails a run with **nothing to fetch** whenever usage exceeds the budget (negative `budgetRoom`). No stamp is written, so every launch fails again. | R-SYN-6, R-SYN-9, R-SYN-11 |
| S2-07 | major | The phase-1 space check is all-or-nothing, and `protecting: inScopeIDs` protects everything in scope. A catalog larger than the default budget therefore **never syncs anything**, not even `essential` assets that fit. `onDemand` assets cannot be evicted. | R-SYN-6, R-SYN-11, R-CLN-4 |
| S2-08 | major | Unknown sizes are estimated at 8 MiB each in phase 1. A manifest without `byteSize`, which R-MAN-1 allows, fails spuriously with `insufficientSpace`. No fixture exercises this. | R-MAN-1, R-SYN-11 |
| S2-09 | major | The phase-3 headroom ledger forgets committed bytes, so the disk can fill past `reserveFreeBytes`. | R-SYN-11, promise 3 |
| S2-10 | major | The pipeline cap gates the **user** branch of `pump()`. With `free > 0` there is no preemption. A page the user opens waits for bulk verify and commit work. | H-4, R-SYN-3 |
| S2-11 | major | Every async API awaits the whole `open()`, which includes migration hashing of the legacy cache. `resolve` therefore waits seconds on the upgrade launch. | promise 1, H-4 |
| S2-12 | major | The snapshot swap is O(1), but the **release of the previous snapshot runs on main**. Measured: 2.9 ms at 100k (32.6 ms unshared) with the design's precomputed URLs. The store also makes a CoW copy per publish, which is O(N²) per sync. | P-8, promise 4, C2 |
| S2-13 | major | The fallback chain's bundle step does file-system work on main. The first `locate` measured **14–18 ms**, and `FakeFileSystem` cannot see it, so P-8 is blind. | C2, P-8, R-STO-7 |
| S2-14 | major | Benchmarks run **concurrently** (verified), which contaminates P-9, P-1, P-6 and P-12. R-9's `DispatchSourceTimer` alternative cannot detect pool starvation: it saw 22 ms while the pool was blocked for 1.2 s. | P-9, Q-5 |
| S2-15 | major | `@available(macOS 15.0, *)` on a `@Suite` **does not compile** with this toolchain, and a plain suite cannot store the fake. As written, the time-based test plan does not build. | H-8, Q-4, every `ManualTimeSource` test |
| S2-16 | major | Backoff and breaker jitter come from one RNG in actor-arrival order. One seed produced **3 different per-asset schedules in 200 runs**, so those tests will flake. | H-8, R-SYN-5, Q-5 |
| S2-17 | major | H-9: §10.4's subject bound ignores pruned ids, so it grows without bound over time. Terminal events from bulk work are never rate-limited, which floods the UI. A stored `events` stream keeps its subscription alive. | H-9, R-SYN-12 |
| S2-18 | major | P-12 is measured with fakes only. The first `URLSession` costs 3–7 ms (background another 3.5–7 ms). If the composition root builds the transport in `init`, the 1 ms budget is missed while the benchmark passes. | P-12 |
| S2-19 | major | The control stream is never finished. A consumer of an `AsyncStream` whose continuation is dropped **never ends** (verified), so the live transport leaks one task per transfer. The fake ends its own task, which hides this. Extends S1-11(C). | R-SYN-14, P-14, P-7 (production) |
| S2-20 | minor | `user.batch` (`ensureAvailable`) starves prefetch and preempts one transfer per `pump()`. The "bounded by human interaction rate" claim is false for batch work. | R-SYN-3 claim, promise 1 |
| S2-21 | minor | The breaker's escalation is defeated when its probe is a cached manifest `304`: trips reset, and a 5xx outage is retried every 30 s forever. | R-SYN-5 |
| S2-22 | minor | Some small maps have no stated bound: the unknown-id negative cache, `ProgressThrottle` keys, and the consumed prefix of the lane FIFOs. This complements S1-10. | H-9, R-SYN-14 |
| S2-23 | minor | Bulk and prefetch read `…ForImportantUsage` capacity, which counts purgeable space. Opportunistic capacity is the right figure for them (verified at iOS 15). | R-SYN-7, promise 3 |
| S2-24 | minor | Progress has no trailing emission, so the UI can show a stale `syncing(c/t)` for the whole of a backoff. | R-SYN-12, prior-art progress semantics |
| S2-25 | minor | Thermal pause and resume has no hysteresis, and run restarts on satisfied-path edges are not debounced, so flapping produces churn. | R-SYN-7, R-SYN-13 |
| S2-26 | minor | 90 % for Sync is reachable only with three seams: one post-await revalidation funnel, an injectable planner, and a debug-safe illegal-transition hook. | Q-2 |
| S2-27 | minor | "Nothing happens before t" cannot be asserted after `advance(to:)`. Tests need positive witnesses, such as `time.nextDeadline`. | Q-4, Q-8 probe "ignore Retry-After" |
| S2-28 | minor | A point-admission fetch can return a newer, unapplied manifest. If its ETag is ever stored, later runs get `304` and never reconcile. | R-NET-5, R-SYN-8 |
| S2-29 | minor | `pump()` does not enforce `interactiveConcurrencyAtCritical`, and the semantics of `popValid(fitting:)` are unspecified. | R-SYN-7, R-SYN-3 |

---

## 2. Findings

### S2-01 · critical · The half-open breaker wedges on any probe outcome that is not "success" or "same cause"

S1-03 covers cancelled, preempted and superseded probes. This finding adds failures with a different cause, and their consequences for `ensureAvailable` and idle silence.

**Design text.** §8.3 "Half-open": "Success → `closed` … Failure **with the same cause** → `open(trips + 1)`." The state is `halfOpen(cause, trips, probe: TransferID?)`. §8.1 gives `offline` and `cancelled` no breaker input.

**Timeline.**
1. The origin returns 503 on 5 of the last 20 outcomes, and the breaker opens `open(.server5xx, until: t+30 s)`.
   - The bulk run ends `.blocked(.circuitOpen)` with `pendingRunOnBreakerClose`.
   - An `ensureAvailable(scope: .tags(["dlc3"]))` caller's 40 jobs move to `blocked(.circuitOpen)`.
2. At t+30 s the alarm makes the state `halfOpen(probe: nil)`. `pump()` admits one `ensureAvailable` job, J, as the probe, giving `halfOpen(probe: J)`.
3. The phone is in a lift, and J fails with `offline`. That is not the same cause (5xx), so `record` gives no transition. §8.1 sends J to `failed(.whenOnline)`.
4. The state stays `halfOpen(probe: J)` forever. Only one probe is allowed, so `admit` rejects everything else.
   - The heap holds no breaker deadline, because the half-open alarm was consumed.
   - T19 (path satisfied) re-queues J and the other 39 jobs into the same rejecting gate.
5. Consequences:
   - `ensureAvailable` waits forever. It throws only on cancellation, and its jobs are never terminal.
   - Every `resolve` of a missing asset fails fast with `.serverUnavailable` until relaunch.
   - The jobs keep the watcher (`NWPathMonitor` plus two observers) alive for the life of the process, so R-SYN-14 is never reached.

The same wedge follows a probe that fails `notFound`, `forbiddenAmbiguous`, `integrity` or `tooLarge` while the cause is 5xx, or `server(5xx)` while the cause is auth.

**Violates:** R-SYN-5 (the breaker must re-close), R-SYN-10, R-SYN-13, R-SYN-14/P-14, promise 1.

**Smallest fix.** Make probe resolution total:
- `success` → `closed`.
- `failure(sameCause)` → `open(trips + 1)`.
- Any other exit from `downloading` (different-cause failure, `offline`, `cancelled`, `paused`, T13, T21, T22, T23) → `halfOpen(probe: nil)` with the same trips, then `pump()`.
- Add a heap entry `.probeWatchdog(transferID)` at `probeStart + requestTimeout` that does the same.

Tests:
- `R-SYN-5: a half-open probe that fails offline re-arms the probe instead of wedging the breaker`
- `R-SYN-10: ensureAvailable completes after a breaker recovers from an abandoned probe`

### S2-02 · critical · `blocked(.awaitingSpace)` has no wake-up once X-4 adopts the store-owned reaper

**Design text.** §12.1 phase 3: "reclaim pending (GC deadline **in the heap**) → `blocked(.awaitingSpace)`; the alarm runs GC, `freeSpace` is re-read, `pump()`". §8.1: ENOSPC → `blocked(.awaitingSpace)` "if a reclaim is pending".
- §17.1 X-4 says either the engine's alarm or "a store-owned reaper task … satisfies P-14".
- X-7 proposes that "reaper deletions emit nothing".
- `store.md` §4.5 chose the store-owned reaper.

**Timeline** (with X-4 resolved as `store.md` designs it).
1. `ensureAvailable(scope: .tags(["dlc3"]))`: phase 1 plans 600 MiB and evicts 200 MiB of out-of-scope blobs. `apply` dooms them, and they become deletable 10 s after the mirror acknowledges (`store.md` §4.4).
2. User-batch jobs start. The user branch of `pump()` skips the headroom ledger. Job J hits ENOSPC. Doomed blobs exist, so J moves to `blocked(.awaitingSpace)`.
3. At t+10 s the store's reaper unlinks 200 MiB. The engine is told nothing:
   - its heap has no `.storeDeadline`, because the store owns that sleeper;
   - the reaper emits nothing (X-7);
   - the conditions stream does not change.
4. J stays blocked forever, and `ensureAvailable` never returns. In a bulk run, §12.5 ends the run instead (S1-14, S2-03).

**Violates:** R-SYN-10, R-SYN-11 (the design's own test "fetches wait for space reclaimed after the grace window"), liveness. Under the drafter's alternative (the engine alarm drives `store.nextDeadline()`), the wake exists. The flaw is the claim that the two are interchangeable.

**Smallest fix.** Phase C must keep **one** wake path for reclaimed space. Either:
- the engine's alarm drives the store's deadlines (the original §3.2 shape), or
- the store exposes `func awaitReclaim(after generation: UInt64) async`, resumed by each reaper deletion batch, which the engine awaits in one owned task only while some job is `awaitingSpace`.

Test: `R-SYN-11: a fetch blocked on ENOSPC resumes after the store's reaper frees doomed blobs (ManualTimeSource)`.

### S2-03 · major · A single 429 ends the bulk run (throttle counts as "blocked")

This extends S1-14, which covers `awaitingSpace` and offline. Throttling is not covered there.

**Design text.** §8.2: Retry-After is "an *origin-wide* throttle. No transfer to that origin starts before `until`", and the job goes to `blocked(.throttled)`. §12.5: "when every remaining job is blocked … the run ends immediately … drops its interests, and sets `pendingRunOnConditions` / `pendingRunOnBreakerClose`".

**Timeline.**
1. A bulk run has 1,000 fetches, with `max = 4`. Transfer #57 gets `429 Retry-After: 20`, so the origin is throttled until t+20.
2. `pump()` evaluates the queued jobs. `gate(.bulk)` rejects them on the throttle, and T4 sets 943 jobs to `blocked(.throttled(until))`.
3. The three running transfers commit. Now every remaining job is blocked, so the run ends `.blocked(.throttled, partial)` and drops its interests. T12 removes the 944 jobs. Neither pending flag applies.
4. At t+20 the `.throttleEnd` alarm fires on an empty table. No stamp exists, so with `.oncePerAppVersion` the remaining 944 assets wait for the next launch.

A 20-second server hint aborted the sync: the failure mode of D-2 ("the first failure aborts the whole sync"), reached through a different path.

**Violates:** R-SYN-5 (honouring Retry-After means waiting, then retrying), R-SYN-6, D-2.

**Smallest fix.** A run ends early only when every remaining job is blocked on a reason with **no scheduled or awaited unblock**: policy, offline, breaker open beyond a horizon, or `insufficientSpace`. `throttled(until)` and `awaitingSpace` keep the run alive, because their wakes already exist (heap entry or reclaim await, S2-02). An alternative is `pendingRunOnThrottleEnd`.

Test: `R-SYN-5: a 429 with Retry-After pauses the bulk run and the same run completes after the throttle ends`.

### S2-04 · major · Integrity re-download loop: the counter dies with the `Job`, and T20 bypasses the store's backoff

**Design text.**
- §5.1: `Job.attempts` holds "transient / integrity / auth counters".
- §8.2: interactive `maxAttemptsPerRun: 2`, `maxIntegrityFailures: 3`; "a user waiter … after `maxAttemptsPerRun` (2) … gets the error, and the job keeps only its non-user interests".
- T12 removes a job with no interests.
- T20: "user requests skip the backoff wait".
- `store.md` §5.4 persists integrity bookkeeping per record. It sets `quarantined(until: now + 60 s·10^(n−1))` and `nextEligibleAt`, and it **rejects early publishes with `.assetFailed`**. It expects the engine to "read `nextEligibleAt` … and never fetch earlier". `sync.md` never reads it.

**Timeline** (sync.md as written). The CDN serves corrupt bytes for a 40 MB video V, for example because of a publisher bug.
1. The user opens V's page and `resolve(V)` runs: T1, download 40 MB, T9 mismatch, a 0–0.25 s backoff, then attempt 2 and another mismatch. That reaches the interactive cap, so the waiter gets `.integrityFailure`. No non-user interest remains, so T12 removes the job **and its `integrity = 2`**.
2. 2 < 3, so no quarantine is ever persisted from a resolve-only path.
3. The user swipes back. `locate` misses, `fetch` calls `resolve(V)`, and a new job starts from 0: another 80 MB. `PrefetchWindowController` also prefetches V whenever it enters ±2, each time as a new job with no backoff memory.
4. The download count is unbounded, and so are data and battery use.

**Timeline** (merged with `store.md`, X-3). The store counts failures, but T1 and T20 never consult `nextEligibleAt`. Each visit inside the store's quarantine window downloads 40 MB, and the store rejects it at `publish` (`.assetFailed`) without counting it. The loop is still unbounded.

**Violates:** R-INT-3 ("no infinite re-download loop"), R-SYN-5 (attempt caps).

**Smallest fix.**
- The store's persisted record is the single owner of integrity backoff.
- T1, T2 and T20 read it from the snapshot or planning view synchronously. When `nextEligibleAt > now`, `resolve` fails fast with `.integrityFailure` and starts no transfer, and `prefetch` skips the asset.
- T20 never applies to integrity dispositions.
- Counters are never discarded with a `Job`.

Test: `R-INT-3: repeated resolve and prefetch of a corrupt asset download it at most maxIntegrityAttempts times across job lifetimes and relaunches`.

### S2-05 · major · An ambiguous 403 becomes a permanent, persisted quarantine

**Design text.** §5.1: `untilEntryChanges // R-INT-3 / 404 / ambiguous 403: persisted as quarantine in the index`. §8.1 sends `forbiddenAmbiguous` to `failed(.untilEntryChanges)`. §8.3 opens the auth breaker after 3 distinct 403s and probes "the next dispatched job".

**Timeline.**
1. A CloudFront Function deploy rejects the current app key for 15 minutes. Equivalently, the key is rotated while v1.0 is still installed. SPEC §2.3 says a 403 is ambiguous between a bad key and a missing object.
2. Prefetch and resolve of known ids get object 403s for A, B and C, and D is in flight. All four become persisted `untilEntryChanges`, and the breaker opens.
3. Half-open probes run after cooldowns of 300, 600, 1,200, 2,400 and then 3,600 s, each jittered by U[0.5c, c]. Each picks a **different** asset (the quarantined ones are skipped by T2), gets a 403, and persists one more quarantine. A day of outage costs roughly 25–45 assets.
4. The key is fixed, or the user installs v1.1. Every quarantined asset still has an unchanged manifest entry: same checksum, same content-addressed key. Its entry never changes, so the asset is **permanently** unavailable on that device. `lookup` misses, and `resolve` fails `.authRejected(.ambiguous)` at T2 without a request.

**Violates:** R-NET-6 and SPEC §2.3 (a 403 must not be silently treated as "missing"), R-SYN-5, promise 1.

**Smallest fix.**
- An ambiguous 403 gives `failed(.nextRun)`, kept in memory, plus the auth-suspect counter. It is never persisted.
- When the auth breaker trips, convert this epoch's ambiguous-403 dispositions to `blocked(.circuitOpen)`.
- Persist "probably missing" only after another object from the same origin succeeded (the key works), and then with a TTL as well as "until the entry changes".

Test: `R-NET-6: assets that got 403 while the key was rejected become fetchable once the key works again`.

### S2-06 · major · A run with zero fetch bytes fails whenever usage exceeds the budget

**Design text.** §12.1: `budgetRoom = budget − (used − pruneBytes)`; `shortfall = max(0, need − min(available, budgetRoom))`. `store.md` §6.0 sets the default budget to `0.5 × (storeUsage + availableCapacity)` and `reserveFreeBytes` to 256 MiB.

**Timeline** (numbers).
1. First sync: available 6.5 GiB, catalog 3.0 GiB, budget 3.25 GiB. It fits, and the device syncs.
2. Weeks later the user has filled the disk: available 2.0 GiB, usage 3.0 GiB, so the budget is 2.5 GiB.
3. The app updates, so a sync is due. The manifest is unchanged, so `need = 0`.
   - `available' = 1.75 GiB` and `budgetRoom = 2.5 − 3.0 = −0.5 GiB`.
   - `shortfall = max(0, 0 − min(1.75, −0.5)) = 0.5 GiB`, so the plan is `needsEviction`.
   - `evictionPlan(protecting: inScope(.all) ∪ leased)` returns `nil`.
   - The run fails `.insufficientSpace(required: 0 + reserve, available: 2.0 GiB)`. The error is self-contradictory.
4. No stamp is written, so the same failure repeats at every launch, forever.

**Violates:** R-SYN-6, R-SYN-9 (the sync stays due with no way out), R-SYN-11 (the typed error is wrong).

**Smallest fix.**
- `need == 0` ⇒ `.fits`.
- `shortfall = max(0, need − max(0, min(available, budgetRoom)))`.
- Being already over budget is a maintenance eviction (R-CLN-4 hysteresis). It is never a reason to fail a run.

Property test: `R-SYN-11: a plan with zero fetch bytes is always assessed as fits`.

### S2-07 · major · The all-or-nothing phase 1 and `protecting: inScopeIDs` stop a catalog larger than the budget from syncing at all

**Design text.** §12.1: "`evictionPlan(toFree: shortfall, protecting: inScopeIDs ∪ leased)` … `nil` means it cannot be reached → **fail now**". `store.md` §6.4 cross-WP note: "the planner must not bulk-refetch `standard` assets beyond the budget, or the store would thrash."

**Timeline** (fresh install).
1. The catalog is 3.0 GiB: 200 MiB `essential` and 2.8 GiB `standard`. Available space is 4 GiB, so the default budget is 2 GiB.
2. `shortfall = 3.0 − min(3.75, 2.0) = 1.0 GiB`, and the store is empty, so there is nothing to evict. The run fails with zero side effects.
3. Every launch repeats this. The 200 MiB of `essential` assets, which fit easily, are never fetched. The prior art downloaded everything.

**Further facets.**
- **`onDemand` cannot be evicted.** In `.all` scope the run does not fetch `onDemand` entries (`includeOnDemand = false`), yet they are protected as in scope, although R-CLN-4 makes them the first eviction candidates. Spurious failures follow whenever `onDemand` content fills the budget.
- **Protecting only the fetch set causes thrash.** If eviction may instead remove present in-scope `standard` assets to fit missing ones, the next run re-fetches what this run evicted. The store designer predicted exactly this.

**Violates:** R-SYN-6 (one shortage aborts the whole sync), R-SYN-11 ("a shortage evicts (policy permitting)"), R-CLN-4, promise 1 for `essential` assets.

**Smallest fix.**
- Phase 1 admits the **largest prefix** of `fetches` in `(rank, manifestIndex)` order that fits `min(available, budgetRoom) + evictable`. Evictable means not in the fetch prefix, not essential, not pinned and not leased; `onDemand` outside the prefix is evictable.
- The remainder becomes `skipped(.overBudget)`, and the run ends `.completeWithFailures` with a partial report.
- Only if the essential tier itself does not fit does the run fail with zero side effects.
- Bulk runs never re-plan in-scope `standard` assets that were evicted. Those are refetched lazily by `resolve`.

### S2-08 · major · An 8 MiB estimate per unknown size makes legacy manifests fail with `insufficientSpace`

**Design text.** §12.1: `need = plan.totals.fetchBytes  // unknown sizes × unknownSizeEstimate (8 MiB)`.

**Timeline.** R-MAN-1 keeps `byteSize` optional, and the prior art's `CDNAsset.byteSize: Int?` is documented as "if the CDN can report it". Every shipped fixture carries it (`Tests/Fixtures/manifests/README.md` §1, and checked: 13/13 entries in every series file), so no test reaches this path.
- A catalog of 2,000 entries without `byteSize` gives `need = 15.6 GiB`, so `.insufficientSpace` on nearly every phone, at every launch, for a catalog that may total 300 MB.
- 300 entries give 2.3 GiB.

**Violates:** R-MAN-1 ("every manifest published today … behaves as before"), R-SYN-11 (no spurious refusal).

**Smallest fix.**
- Phase 1 sums known bytes only, plus `min(estimate × unknownCount, cap)`.
- Unknown-size fetches are admitted one at a time by the phase-3 ledger and bounded by R-NET-7's early abort.
- Add a fixture series with `byteSize` absent.

### S2-09 · major · The headroom ledger forgets committed bytes, so the disk fills past the reserve

**Design text.** §12.1 phase 3: `headroom = volumeAvailable − reserve − Σ expectedBytes(jobs in downloading ∪ verifying ∪ committing)`. `freeSpace` is re-read only after GC.

**Timeline.**
1. Raw free space is 756 MiB and the reserve is 256 MiB, so `available` is 500 MiB. The plan has 10 × 100 MiB. Eviction plans 500 MiB of out-of-scope blobs, deletable only after the 10 s grace.
2. At t0, five fetches are admitted (Σ = 500 MiB) and the sixth goes to `awaitingSpace`.
3. At t0+4 s (fast Wi-Fi) those five commit. 500 MiB are on disk, so physical free space equals the reserve. They leave the Σ, but `volumeAvailable` is unchanged, so the ledger shows 500 MiB of headroom and admits five more.
4. At about t0+6 s the volume is full: transfers hit ENOSPC, and so do the store's index commits (`store.md` uses `reserveFreeBytes` as the commit guard), as well as other apps. The reaper's frees arrive at t0+10 s or later.

**Violates:** R-SYN-11, promise 3 ("the device is never filled").

**Smallest fix.**
- Compute `headroom = lastRead − reserve − Σ in-flight expected − Σ bytes committed since lastRead`.
- Re-read free space with one off-main call every 64 MiB committed, and after each reaper batch (S2-02).

### S2-10 · major · The pipeline cap gates the user lane, so a page waits for bulk bookkeeping

**Design text.** §7.3: `while free > 0 ∧ |pipeline| < depth × max: if gate(.userInitiated) ∧ let j = user…: start(j)`. Preemption runs only `if … free == 0`. §7.4 says that with `max == 1`, "preemption guarantees the user job starts after one actor turn".

**Timeline A** (`max = 1`, so `reserved = 0` and the cap is 2).
1. Bulk B1 is verifying a 250 MiB video, about 0.3–0.6 s of hashing on the store's single queue. Bulk B2 is downloading. The pipeline holds 2, which is the cap.
2. The user opens a page, and `resolve(X)` queues X. The loop does not run because the pipeline is full. `free == 0`, so B2 is paused (`.pause`) and marked `preempting`.
3. The pipeline is still 2, because B2 stays `downloading` until `.paused` arrives. X starts only after both B1's verification and B2's pause acknowledgement. That is "one actor turn" only by luck. S1-16 notes that `pump()` does not loop after preempting.

**Timeline B** (`max = 4`, `reserved = 1`, so `nonUserCap = 3` and the cap is 8).
1. Three bulk jobs are downloading. Five bulk jobs sit in `verifying`/`committing` because:
   - the store's serial blocking queue is busy with a 16 ms index commit and GC or maintenance units, or
   - the main actor is busy (decoding a large image) and the snapshot-install acknowledgement that ends `committing` is late.
2. `free = 1` but `|pipeline| = 8`, so the user's X waits, and no preemption happens because `free > 0`.
3. Once X starts, its verification shares the serial queue round-robin with four bulk verifications, at 1/5 of the throughput.

**Violates:** H-4 ("a page the user just opened must overtake a 1 GB bulk sync"), R-SYN-3.

**Smallest fix.**
- The user branch checks only `free > 0`. Either the pipeline cap applies only to non-user lanes, or `reserved` pipeline places are kept for the user.
- Re-run the dispatch loop after marking a preemption victim.
- `store.md`'s blocking executor gets a high-QoS unit queue for interactive verification.

Test: `R-SYN-3: a userInitiated request starts while the pipeline is full of bulk verifications`.

### S2-11 · major · `resolve` waits for the whole `open()`, including legacy-migration hashing

**Design text.** §13.2: `start()` covers "root resolution, lock, index load, legacy migration, launch reconciliation, staging GC, publishing the first snapshot…", and "every async API awaits `ensureStarted()`" (RE-S26). `store.md` §2.6 runs migration "inside `open()`, before the first snapshot". `store.md` §7 R4 hashes the whole legacy catalog at "about 0.4 s per GB at the measured Mac throughput, more on older devices", and publishes snapshots every 64 adoptions, which only `lookup` can use.

**Timeline.**
1. This is the first launch after the upgrade, with a 2 GiB legacy cache. `start()` begins migration: about 0.8 s on this Mac and several seconds on an older iPhone (not measured on a device).
2. The user opens a page whose asset is not adopted yet, or is new. `lookup` misses, so step 3 runs `resolve(X)`, which awaits `ensureStarted()` for the rest of migration, reconciliation (256 fan-out listings) and staging GC. Only then does the user-initiated download begin.

**Violates:** promise 1 ("fetched immediately at top priority"), H-4.

**Smallest fix.**
- `ensureStarted()` waits for lock, index load and the first publish only (P-2: 25 ms).
- Migration, the rest of launch reconciliation and staging GC run as an engine-owned maintenance task at bulk priority.
- A `resolve` for an id whose legacy file is still pending adopts that one file first (priority adoption), or else downloads at userInitiated.
- If publishing before the blob listing is judged unsafe (OS-purge detection), the one requested id is checked with a single `itemInfo` off-main, and the full listing is not awaited.

### S2-12 · major · Main-actor cost of a snapshot swap is the release of the old one, plus the store's per-publish CoW copy

**Design text.**
- §13.3: `publish` is a swap.
- D-KIT-1: each record carries a precomputed `AssetLocation` (with `URL`).
- `store.md` §4.3: "Publication cadence: after every mutating API call (one install per publish …). Coalescing at ≤ 10 Hz is an allowed optimisation if P-8 needs it." "The first mutation after a publication pays one copy-on-write copy."

**Measured** (probe Q2, release build, on the main actor). This is the time to drop the last reference to the previous snapshot inside `install`.

| entry shape | N | shared entries (normal CoW publish) | unshared (rebuilt snapshot) | store-side CoW per publish |
|---|---:|---:|---:|---:|
| `store.md` (BlobKey, no URL) | 10,000 | 0.05 ms | 0.20 ms | 0.05 ms |
| `sync.md` (precomputed URL) | 10,000 | 0.11 ms | **1.28 ms** (max 2.30) | 0.19 ms |
| `store.md` | 100,000 | 1.54 ms | 6.20 ms | 2.53 ms |
| `sync.md` | 100,000 | **2.86 ms** | **32.6 ms** (max 37.4) | 6.29 ms |

**Timeline.** A bulk sync of 100,000 small assets (allowed by R-MAN-2) at about 200 publishes per second:
- one install per publish costs about 200 × 2.9 ms ≈ 0.6 s of main-thread time per second of sync, which is continuous jank while the user scrolls;
- the store spends 200 × 2.5–6.3 ms per second on CoW copies, which is O(N) per asset and O(N²) per sync, and each copy blocks a pool thread for up to 6 ms.

Who drops the last reference is racy, because the engine's `latestSnapshot` sometimes still holds it, so the cost lands on main nondeterministically. At 10k the shared case is fine, but the unshared case already exceeds `ui_call_ms_max` (1 ms).

**Violates:** P-8 (main-thread cost attributable to the module), promise 4, C2 at the R-MAN-2 ceiling.

**Smallest fix.**
1. `install` returns the previous snapshot to its async caller, or the store keeps `lastPublished` alive across the await and drops it afterwards. Either way the release happens off-main, deterministically.
2. Coalesce installs to ≤ 10 Hz, except interactive commits. Make this mandatory rather than optional.
3. Drop the precomputed `URL` (D-KIT-1) and compute it at lookup (the store measured p99 2.75 µs against a 25 µs budget). In Q2 that cuts the CoW copy by 2.5–3.5× and makes the unshared release 5–6× cheaper.

### S2-13 · major · The bundle step does file-system work on the main thread, where `FakeFileSystem` cannot see it

**Design text.**
- §13.4: `@MainActor public func locate(_:kind:)` performs "Steps 1–2, synchronous: bundle (each candidate in order)".
- The default argument is `MainBundleLookup()`, which calls `Bundle.main.url(forResource:withExtension:)`.
- §13.3 P-8 proof: "`FakeFileSystem` recording the calling thread".

**Measured** (probe Q7, a bundle with 6,000 resource files). The first `locate` of an image (4 candidates) took **14.1–17.9 ms on main**. Warm calls took 4.4–4.9 µs. The first lookup enumerates the bundle directory on the calling thread. This is module code (`MainBundleLookup` is the module's live default), not app code, and it bypasses the `FileSystem` seam. `R-STO-7`/P-8 therefore pass while the first page after launch drops a frame.

**Violates:** C2, P-8 (0 file-system calls on main; ≤ 1 ms per UI-facing call), R-STO-7 (the proof is blind to this).

**Smallest fix.** Either:
- build a `BundleIndex` (a set of `name.ext`) off-main in `start()` with one `FileSystem` listing unit of `Bundle.main.resourceURL`, and have `locate` probe that set; or
- move the bundle step into the carousel's UIKit adapter, alongside asset catalogs.

In both cases, the P-8 benchmark counts `BundleLookup` calls made on main.

### S2-14 · major · Benchmarks run concurrently, and R-9's timer alternative cannot detect pool starvation

**Verified** (probe package `pkg/`, `swift test -c release`).
- Separate suites run **in parallel**: the P-6 and P-9 stand-ins overlapped exactly (0–426 ms).
- `@Suite(.serialized)` serializes only its own tests.
- `Scripts/verify.sh` passes no `--no-parallel` to the perf step, and `Scripts/` is frozen.

So:
- P-9's heartbeat shares the cooperative pool and the cores with P-6 (256 MiB hash), P-7 (1 GiB sync) and P-13 (10k-blob GC);
- P-1's p99 shares the main actor with P-8, and P-12's 1 ms shares the cores with all of them.

The results are flaky, or report false failures.

**Verified** (probe Q5). With every cooperative thread blocked for 1.2 s (24 × 400 ms non-yielding units):

| heartbeat | max gap |
|---|---:|
| `Task.sleep` heartbeat | 1,200 ms |
| `DispatchSourceTimer` callback | **22 ms** |
| `DispatchSourceTimer` → `Task` hop latency | 1,178 ms |

R-9's option "measure with a `DispatchSourceTimer`" therefore makes P-9 vacuous unless each tick hops into a `Task`.

**Violates:** P-9 (validity), Q-5 (stability), and indirectly P-1, P-6 and P-12.

**Smallest fix.**
- Put every benchmark under one top-level `@Suite(.serialized) struct ZTronAssetKitBenchmarks` with nested `…Benchmarks` suites. Verified: nested suites then run strictly one after another.
- P-9 measures `Task` wake-up latency, either with `Task.sleep` or with timer→`Task` hop latency, recorded in Phase C as a benchmark-only real-time wait (Q-4).

### S2-15 · major · `@available(macOS 15.0, *)` suites do not compile, so the `ManualTimeSource` test plan fails to build

**Design text.** §9.3: "Suites that use it are annotated `@available(macOS 15.0, *)`". The same appears in §15 (intro) and R-10.

**Verified** (probe package `pkg/`, real `swift test`).
1. `@available(macOS 15.0, *) @Suite struct …` fails with: **"Attribute 'Suite' cannot be applied to this structure because it has been marked '@available(macOS 15.0, *)'"**, and every `@Test` inside it fails the same way.
2. A non-gated suite cannot store the fake either: `struct EngineSuite { let time = ManualTimeSource() }` fails with "'ManualTimeSource' is only available in macOS 15.0 or newer" (probe Q4).
3. `@available` on an individual `@Test` function **does** work.
4. SwiftPM builds test targets with `-target arm64-apple-macos14.0` and library targets (and therefore `ZTronAssetTestSupport`) at 12.0.

**Violates:** H-8, Q-4. The suites for R-SYN-5/13/14/16 and P-14 do not build as specified. `sync-1.md` §3 also assumed the suite annotation works.

**Smallest fix.** Back `ManualTimeSource` and `RecordingLogTap` with `OSAllocatedUnfairLock` under `@available(macOS 13.0, iOS 16.0, *)`.
- Every test target builds at macOS 14, so tests use it with **no annotation at all**.
- Its `@unchecked Sendable` lives in the SDK (`os.swiftmodule`: `public struct OSAllocatedUnfairLock<State> : @unchecked Swift::Sendable`), so the unsafe gate stays at 0.
- Verified: compiled and passed in the probe package.

The fallback is a per-`@Test` `@available` annotation, with fakes created as locals rather than stored properties.

### S2-16 · major · One seeded RNG drawn in actor-arrival order does not reproduce backoff schedules

**Design text.** §8.2: "The RNG is the engine's own … With `SeededRandom` in tests, the whole schedule is reproducible; tests compute the expected delays by calling `Backoff.delay` with an identically seeded generator". The breaker draws its jitter from the same generator (§8.3 `record(…, using: &rng)`).

**Verified** (probe Q10). Four driver tasks report a failure "at once", and one seeded SplitMix64 in an actor draws per arrival. Over 200 runs with **the same seed** there were **3 distinct per-asset schedules** (197 / 2 / 1). For example, the "sustained 5xx opens the breaker" test needs at least 5 failures with `max = 4`, so concurrent arrivals are guaranteed. Q-5 runs the full suite 3×, plus TSan.

**Violates:** H-8 (determinism), R-SYN-5 tests, Q-5 (zero flakes).

**Smallest fix.**
- Jitter is a pure function of `(seed, stableHash(assetID or originID), attempt or trip)`. Use FNV-1a or a SHA-256 prefix, not `Hasher`, which is seeded per process.
- Verified: compiles and links at iOS 15 next to the design's existential plumbing (probe Q9).
- The engine RNG is kept only for draws whose order the engine itself determines.

### S2-17 · major · H-9: the subject bound is not a bound, terminal events flood the UI, and a stored stream pins its subscription

**Design text.**
- §10.4: "S (subjects) ≤ |applied manifest ∪ job ids| + 5 … bounded and independent of time and of event volume."
- §10.1 says terminal events are "never dropped"; only the progress class is rate-limited (§10.5).
- §10.2: "Consumer breaks out of the loop: the stream and its closure are released → the lease's deinit → unsubscribe."

**Timelines.**
1. **Pruned ids.** `.assetRemoved(id, .pruned)` is a subject for an id that has **left** the applied manifest. A stalled subscriber keeps one slot per id ever removed in the process. With `.atMostEvery(i)` and a publisher that renames ids at a churn of c per generation, the queue holds 10k + k·c slots after k generations: it grows with time. S1-19 found the same flaw in P; this one is in S.
2. **Terminal flood.** A 10,000-asset bulk sync delivers 10,000 `.assetAvailable` events to **every** subscriber, in bursts of hundreds after each coalesced commit (`store.md`: ≤ 4 commits/s). A UI subscriber on main pays one main-actor turn per event. §10.5 already suppresses per-asset *progress* for bulk work but not per-asset *terminals*.
3. **Stored stream.** A view model that keeps `let events = client.events` and breaks out of its loop leaves the lease alive, because the stream holds it. The subscription stays registered and buffers up to P + S slots (about 1.5 MB at 10k). `events` is also a computed property, so every read registers a new subscriber.

**Violates:** H-9 ("never grow without bound **or flood the UI**"), R-SYN-12.

**Smallest fix.**
- Bulk-lane terminals collapse into one coalescible `.assetsChanged(generation:, available:, failed:, removed:)` per commit. Per-asset terminals are kept only for ids with a user or prefetch interest. Pruned removals fold into it.
- Add a hard per-subscriber cap with an explicit `.resync(generation)` marker, the alternative that R-2 already names.
- Replace the `events` property with a method `makeEventStream()`, documented as "holding the stream holds the subscription".

### S2-18 · major · P-12 is measured with fakes, but the composition root may create the transport's sessions in `init`

**Design text.** §13.2 lists what `init` creates (store, engine, mirror) and what it does not read (`Bundle`, `UserDefaults`, `FileManager`, `ProcessInfo`). It is silent about `RemoteSource`. "Only the facade composes concrete types." The P-12 benchmark "reads `FakeFileSystem.calls` and wall time".

**Measured** (probe Q11, this Mac).
- The first `URLSession(configuration:delegate:delegateQueue:)` in a process takes **3.2–7.3 ms**.
- The first background (discretionary) session takes another **3.6–6.8 ms**.

If `AssetClient.init` builds the R-NET-2/R-NET-3 sessions, real `init` is 3–14× over `init_ms_max` (1 ms), while the benchmark passes.

**Violates:** P-12 (honesty of the measurement).

**Smallest fix.**
- The transport creates its sessions lazily inside its own actor, on `start()` or the first transfer, and off the caller's thread.
- The P-12 benchmark runs with `AssetEnvironment.live` (temporary root) as well as with fakes.

### S2-19 · major · The control stream is never finished, so the live transport's control reader leaks one task per transfer

This extends S1-11(C) with runtime evidence and the test gap.

**Verified** (probe Q1).
- **(a)** A consumer iterating an `AsyncStream` whose last continuation is released without `finish()` **never ends**. It ended only when the probe's watchdog cancelled it.
- **(b, c)** In contrast, dropping the *consumer side* fires `onTermination`, and a later `yield` returns `.terminated`, so RE-S12 holds.

**Timeline.** §3.3 has the transport "read" `control`, and no transition finishes it.
1. A live transport that reads it the natural way, with `Task { for await c in control { … } }` per transfer, leaves that task suspended after `.staged`/`.failed`. It retains whatever it captured (the `URLSessionTask`, delegate state).
2. A 10,000-asset sync leaves 10,000 tasks behind. Idle silence and P-7 fail **in production**.
3. Every test passes, because `FakeRemoteSource` "consumes control in one task per transfer, which ends with the transfer" (§15.1), ending its own task.

**Violates:** R-SYN-14, P-14 and P-7 in production. The test plan cannot detect it.

**Smallest fix.**
- The engine calls `control.finish()` on every exit from `downloading`: T5, T6, T7, T13, T21, T22, T23.
- The contract adds: "the transport stops reading `control` at its terminal update".
- Add a census test against the real URLSession backend with `LoopbackHTTPServer`: after N transfers, `backend.liveControlReaders == 0`.

### S2-20 · minor · `user.batch` starves prefetch and preempts on every `pump()`

§7.4 says non-user work waits only while user jobs are continuously queued, which is "bounded by human interaction rate". One `ensureAvailable(.all)` puts up to 100k jobs into `user.batch` for its whole duration:
- "non-user work never starts while a user job waits", and
- `preemptLowerLanes` pauses one running prefetch or bulk transfer per `pump()` (`user queue non-empty ∧ free == 0`).

The neighbour pages' prefetch therefore never runs during the call. Demotion (T15 in reverse) can also leave a non-user transfer in the reserved slot.

**Fix.**
- Only `user.single` preempts.
- Batch work takes at most `max − reserved` slots and ages against prefetch.
- A demoted transfer that occupies the reserved slot is the first preemption victim.

### S2-21 · minor · A manifest probe defeats the breaker's escalation

The half-open probe may be "the manifest fetch of a pending run". The manifest is served `max-age=60, must-revalidate` (SPEC §2.3), so during an S3 object 5xx outage the edge can answer the conditional fetch with `304`. The breaker closes and trips reset, the run re-trips after 5 object failures, and the cooldown stays at the 30 s base instead of doubling to 600 s.

**Fix.** For the 5xx cause the probe is an object transfer, and trips reset only after K successful object transfers.

### S2-22 · minor · Small maps without a stated bound (complements S1-10, which covers the heap and the watcher)

- **Unknown-id negative cache (§6.5).** Expiry is either an alarm per miss (60 s without idle silence) or lazy (grows with every distinct misspelt id).
- **`ProgressThrottle.lastEmitted[.transfer(id)]`** is never pruned.
- **Lane FIFOs (§7.2).** "Compaction when stale entries outnumber live ones" must also count the consumed prefix `[0, head)`. Otherwise a long session of prefetches grows the arrays without bound.

**Fix.**
- A capped LRU negative cache (for example 256 entries) with lazy expiry.
- Delete throttle keys at the terminal event.
- Compact when `head > live`.

### S2-23 · minor · Bulk work should read opportunistic capacity

§3.2 and `store.md` read `volumeAvailableCapacityForImportantUsage` for every lane. Apple distinguishes opportunistic (prefetch, bulk) from important (user-requested) work. On this host "important" exceeds "opportunistic" by **20.3 GB** (probe Q8), so bulk sync may push the OS into purging other apps' caches. Both keys compile at iOS 15 (probe Q8).

**Fix.** Use opportunistic capacity for bulk and prefetch admission and for phase 1 of bulk runs, and important capacity for userInitiated work and `ensureAvailable`.

### S2-24 · minor · No trailing progress

§10.5 has no trailing emission. If the last progress updates before a 5-minute backoff were suppressed, the shim shows `syncing(1,230/1,240)` for 5 minutes while the real count is 1,239.

**Fix.** Publish run progress, exempt from the throttle, on every job park or terminal transition.

### S2-25 · minor · Flapping

- **Thermal.** Bulk and prefetch pause at `.serious` and resume below it with no hysteresis. The sync's own heat can drive pause/resume cycles of every bulk transfer.
- **Network.** Each satisfied edge with `pendingRunOnConditions` starts a full run: manifest fetch, plan, and job materialisation (S1-15). A subway ride can start dozens of runs.

**Fix.**
- Resume one thermal level below the pause level.
- Start a pending run only after the path has stayed satisfied for, say, 5 s (one alarm entry), with back-off across consecutive blocked runs.

### S2-26 · minor · What 90 % coverage of `ZTronAssetSync` needs

There are 26 awaits, each followed by the (L) and (E) checks. Two awaits cannot be held by any listed seam:
- RE-S07, `SyncPlanner.planOffActor`, a `static` function;
- RE-S08, the main-actor drain.

Their unwind branches are therefore covered only by races, so coverage would vary from run to run. In addition:
- the `assertionFailure` path in `transition` cannot reach its release-mode counter line in a debug build;
- a Q-8 mutant that trips it crashes the whole test process instead of failing one test.

With these fixed, my rough estimate (about 3,300 lines of Sync, about 330 lines of slack) makes 90 % reachable:
- one `revalidate(after:)` funnel, covered once;
- the planner injected as a `@Sendable (PlanInput) async -> SyncPlan` closure in the engine configuration;
- an `onIllegalTransition` hook, whose default asserts.

### S2-27 · minor · Negative-in-time assertions need a positive witness

`R-SYN-5: no transfer starts before a 429's Retry-After elapses` cannot be checked as "nothing yet" after `advance(to: until − ε)`, because the alarm task may simply not have run. `waitUntil` only witnesses positive events.

**Fix.**
- Assert `time.nextDeadline == until`, and that the job is in `blocked(.throttled(until))`.
- Then `advance` and await the start.

This also kills the Q-8 probe "ignore Retry-After" quickly instead of after a one-minute `timeLimit`.

### S2-28 · minor · Point admission must never store the ETag of a manifest it did not apply

§6.5's single-flight fetch for an unknown id can return `200` with a newer manifest. Only one entry is point-admitted. If that response's ETag reaches the stamp or the transport's conditional cache, the next run's `If-None-Match` gets `304`, plans the old applied manifest against itself, and never reconciles the new catalog.

**Fix.**
- Only the applied manifest's ETag is ever sent.
- The fetched body is cached in memory for the next run.

### S2-29 · minor · `pump()` details that are unspecified

- `interactiveConcurrencyAtCritical` (§11.2) is never checked in the user branch.
- `popValid(fitting:)` is unspecified. "Skip to the first job that fits" starves large assets. "Head-of-line" stalls the lane.

**Fix.** Specify both; head-of-line with an aging override is the safer default.

---

## 3. Overlaps with `sync-1.md`

Each item below was found independently and is cross-referenced here.

- **S1-03** (abandoned probe). S2-01 adds different-cause failures, the `ensureAvailable` hang and the watcher that never exits.
- **S1-11(C)** (control never finished). S2-19 adds the runtime proof and the gap that the fake hides.
- **S1-14** (`awaitingSpace` run settling). S2-03 adds the 429 throttle path, and S2-02 the case where no wake-up exists at all.
- **S1-15** (one `Job` per planned fetch). Independently measured in probe Q3/Q3b:
  - jobs, lane FIFO and per-job interest maps take +10.5 MiB at 10k and **+147.9 MiB at 100k**, plus the plan copy (1.7 / 16.8 MiB);
  - materialising them is one actor turn of 3.5–7.4 ms at 10k and **61–74 ms at 100k**.

  This confirms C2 and P-7 at the R-MAN-2 ceiling. P-7's benchmark should run 1 GiB at two asset counts (for example 1,000 and 100,000) and assert the delta does not grow.
- **S1-16** (`pump()` does not loop after preempting). This is the `max == 1` half of S2-10.
- **S1-08** (`sync()` and shared work in a caller's task). I reached the same conclusion and do not repeat it.

---

## 4. Areas attacked that held (what was tried)

- **Live conditions source (P7).** P7 was only compiled. I **ran** it on macOS (probe Q6):
  - the first element arrived;
  - a `NSProcessInfoPowerStateDidChange` posted from a global queue reached the observer without a Swift 6 isolation trap;
  - `pathUpdateHandler` is `@Sendable` in the SDK, as `Network.swiftinterface` shows.

  The iOS 15 typecheck shows zero diagnostics. Each `conditions()` call owns its own monitor, so a late termination hop cannot cancel a successor's monitor.
- **Watcher churn on idle→busy.** Restarting the source took median 0.18 ms and at most 5.34 ms to the first element over 20 cycles (probe Q12). Tearing the watcher down when idle is cheap. S1-10's point that it must be cancelled stands.
- **Dropping an un-iterated or abandoned transfer stream (RE-S12, T13).** `onTermination` fires and a later `yield` returns `.terminated` (probe Q1b/c). This holds.
- **`ManualTimeSource` registration race.** `advance` can run before the alarm task has registered its sleeper. This is benign, because `sleep(until:)` takes an absolute deadline and returns at once when it has passed (re-read `p5_time.swift`).
- **Backoff RNG plumbing at iOS 15.** An `any RandomNumberGenerator & Sendable` held by the actor and passed as `inout some RandomNumberGenerator` compiles and links with `-warnings-as-errors` (probe Q9). Only the ordering fails (S2-16).
- **P-1 and P-4.** Lookup itself is fine: 0.21 µs in the drafter's P11, and 2.75 µs with URL construction in `store.md`. The cost is in the release on swap (S2-12). The P-4 prototype (1.74 ms, ×1.82) builds no `Job`s, so S1-15's cost lies outside P-4. Not re-measured.
- **Retry storms on the run path.** With jobs that stay in the table, `maxAttemptsPerRun` plus the 5xx breaker bound the retries per run. The unbounded paths are job removal (S2-04), persisted quarantine (S2-05) and manifest probes (S2-21).
- **Unknown-id fetch storms.** Bounded at ≤ 1 fetch per 60 s by the negative cache. Only the cache's own size is unbounded (S2-22).
- **Bulk vs prefetch starvation.** Aging needs no timer, because it is evaluated on every slot release. The bound "bulkAging + one non-user transfer" holds when no `user.batch` work is present.
- **Stalled-subscriber interleavings.** A cancel landing between `registration.value` and `pull` is safe, because `pull` on an unknown id returns `nil` (`p4_events.swift`).
- **Capacity keys.** Both `volumeAvailableCapacityFor{Important,Opportunistic}Usage` typecheck at `arm64-apple-ios15.0` (probe Q8).
- **Snapshot atomicity (R-STO-13).** The swap is one main-actor assignment, so it holds. Only its cost is at issue (S2-12).

## 5. Probe index (`.build-probe-review-sync-2/`, git-ignored)

| Probe | What it shows |
|---|---|
| `q1_streams.swift` | (a) A consumer never ends after its continuation is dropped without `finish()`. (b) An un-iterated, dropped stream fires `onTermination`. (c) A dropped consumer side terminates the stream. |
| `q2_snapshot_release.swift` | Main-thread release and CoW copy costs for store-shape and sync-shape snapshots at 10k and 100k (table in S2-12). |
| `q3_job_memory.swift`, `q3b_job_time.swift` | Footprint of the job, lane and interest tables, and the time to materialise them in one actor turn (§3). |
| `q4_stored.swift` | A plain suite cannot store a macOS 15 fake (compile error at a macOS 14 test target). |
| `pkg/` (SwiftPM + Swift Testing) | `@available` on a `@Suite` is rejected and on a `@Test` is accepted. An `OSAllocatedUnfairLock` fake works unannotated. Suites run concurrently. A `.serialized` parent serializes nested suites. Test targets build at macOS 14.0, libraries at 12.0. |
| `q5_heartbeat.swift` | `Task.sleep` heartbeat 1,200 ms, `DispatchSourceTimer` 22 ms, timer→`Task` 1,178 ms with the pool blocked. Side note: the first version crashed (SIGTRAP) because a non-`Sendable` GCD handler formed in implicitly-`@MainActor` `main()` trips Swift 6's dynamic isolation check. That is a trap to avoid in benchmark code. |
| `q6_p7_lib.swift` + `q6_main.swift` | P7 runs, handles off-actor notifications, and shows 0 diagnostics at iOS 15. |
| `q7_bundle.swift` + `fake.bundle/` | First `locate` 14.1–17.9 ms on main; warm 4.4–4.9 µs. |
| `q8_capacity.swift`, `q8_run.swift` | Both capacity keys at iOS 15. On the host, important 330.6 GB vs opportunistic 310.3 GB. |
| `q9_rng.swift` | The design's RNG plumbing and the order-independent jitter both compile and link for `arm64-apple-ios15.0` with `-warnings-as-errors`. |
| `q10_order.swift` | One seed gives 3 per-asset schedules in 200 runs. |
| `q11_session.swift` | First foreground `URLSession` 3.2–7.3 ms; first background session 3.6–6.8 ms. |
| `q12_main.swift` | Watcher restart to first element: median 0.18 ms, max 5.34 ms. |

**Not verified.**
- iOS 15.0 *runtime* behaviour (design R-1).
- On-device numbers: hashing rate, bundle sizes, `URLSession` creation cost, migration duration.
- Whether CloudFront answers `304` for the manifest while S3 objects 5xx. S2-21 rests on SPEC §2.3's `max-age=60`.
- Whether consumers on Swift < 6.2 can parse `@concurrent`; only Swift 6.4 is installed, as `sync-1.md` also notes.

## 6. Notes for Phase C (cross-design)

- **X-4 / X-7.** Choose the reaper model together with the `awaitingSpace` wake-up (S2-02). They are not independent.
- **X-3 and `store.md` §5.4.** Integrity backoff has exactly one owner, and the engine's T1, T2 and T20 must read it (S2-04).
- **`store.md` §4.3.** Install coalescing must be mandatory, and the old snapshot must be released off-main (S2-12).
- **`store.md` §6.0 and §6.4.** The default budget `0.5 × (usage + free)` combined with the all-or-nothing phase 1 means large catalogs never sync (S2-06, S2-07). Decide the prefix-plan policy and record it as NEEDS-HUMAN-REVIEW, since it is a product choice.
- **`ZTronAssetTestSupport`.** Use `OSAllocatedUnfairLock` (macOS 13) instead of `Mutex` (S2-15). That removes every `@available` annotation from the tests.
