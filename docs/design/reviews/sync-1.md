# Adversarial review #1 — `docs/design/sync.md`
> **Historical.** A Stage 1 adversarial review of a design draft, kept as written; each finding's resolution is in [ARCHITECTURE.md](../../ARCHITECTURE.md) §12, which with [DECISIONS.md](../../DECISIONS.md) is authoritative.\
> **Lens:** actor reentrancy, single-flight and cancellation. Covers interleavings at every `await`, the last-interest rule, cancellation storms, continuation leaks and double resumes, promotion races, prefetch-handle `deinit`, shutdown mid-flight and leaked tasks.
> **Reviewer:** Phase B reviewer `review-sync-1`, who did not write the design. **Date:** 2026-10-04.
> **Read:** `CLAUDE.md`; SPEC §1.4, §3, §4.1–4.5, §5.6, §5.8, §5.9, §5.10, §6, §7; `docs/RECON.md`; `docs/DECISIONS.md` (ADR-001…011); `docs/BASELINE.md`; `docs/design/sync.md` (all of it); `docs/design/store.md` §4.2, §4.4–4.6, §6.5 (the contracts the engine calls); the drafter's probes in `.build-probe-sync/`.
> **Method:** every claim that depends on Swift or SDK behaviour was checked by a compiled probe in `.build-probe-review-sync-1/` (git-ignored). Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), iPhoneOS 27.0 SDK, macOS 27 host (Apple M3, 8 cores). Runtime probes were built with `-O -swift-version 6 -target arm64-apple-macos12.0`. iOS checks used `xcrun --sdk iphoneos swiftc -emit-library -parse-as-library -O -warnings-as-errors -target arm64-apple-ios15.0 -swift-version 6`. Probe outputs are in §4.
> **Scope:** nothing outside this repository was read for writing or written. Only this file and the probe directory were created.

---

## 1. Summary

| ID | Sev. | Finding | Violates |
|---|---|---|---|
| S1-01 | **critical** | Several transitions leave a job with **zero interests**: T9, T11, T22, offline T6, the §8.2 interactive cap and F29. The result is downloads for nobody, or a zombie `committing` job that holds a pipeline slot forever. | R-SYN-4, R-CAR-4, design invariant 2, R-SYN-14/P-14, liveness |
| S1-02 | **critical** | Completion continuations other than `waiters` have no exactly-once discipline. A **zero-fetch run** (the R-SYN-8 directory-move case) never completes. Purge's "cancel the run" does not wake it (probe R8). The last member and a withdrawal can both resume an `ensureAvailable` group, which is a double-resume trap. | R-SYN-6, R-SYN-8, R-SYN-9, R-SYN-10, H-3, P-14 |
| S1-03 | **critical** | If the half-open breaker's single probe is cancelled, preempted or superseded, the breaker stays **half-open forever**. Every resolve then fails fast until relaunch. | R-SYN-5, promise 1, liveness |
| S1-04 | **critical** | `shutdown()` quiesces only owned tasks. A `purge` asleep in the store's grace window, `start()`/`open()` and `ensureAvailable` keep running after `store.close()`. They can write without the lock, and they can **delete a blob that a new client has re-published**. | R-SYN-15, R-STO-9, I-2, I-3, H-2 |
| S1-05 | major | The `PrefetchWindowController` claim "the new handle is created BEFORE the old one is cancelled, so interest never drops to zero" is false. Probe R1 restarted the transfer in 1.6–2.0 % of promotions under load. The same race restarts a transfer on carousel cell reuse. | R-CAR-3, R-SYN-3, Q-5 |
| S1-06 | major | The control stream `.bufferingNewest(1)` **drops `.pause`** when a `.setPriority` follows (probe R2a). The preempted transfer then runs on outside the ledger. Promotion is also not ordered before the next start: probe R6 inverted it in 41–53 % of runs, so the R-NET-10 test is a coin flip. | R-SYN-3, R-NET-10, Q-5 |
| S1-07 | major | A lane change re-runs admission only for `queued`/`downloading` jobs. A user `resolve` of a policy- or offline-blocked bulk asset hangs until conditions change. A demoted transfer keeps running on a lane that is not allowed. | R-SYN-7, R-CAR-2, promise 1 |
| S1-08 | major | Shared work runs in a caller's task or is awaited through `Task.value`: `start`/`ensureStarted`, the shared manifest fetch and `sync()` runs. One caller's cancellation kills others' work, or cancellation is ignored (probe R4a). Shutdown can wait on an unowned network fetch. | R-SYN-4, R-SYN-10, R-SYN-15, H-3 |
| S1-09 | major | `ownedTasks` keys are not unique per spawn. A predecessor's `taskEnded(key)` unregisters its successor (driver, alarm, watcher or run), so shutdown neither cancels nor joins it. The alarm body never calls `taskEnded`. | R-SYN-15, P-14 |
| S1-10 | major | Idle silence fails in three ways. Lazily deleted heap entries keep the alarm armed for up to 300 s, or 3,600 s for throttle and breaker entries, after the work has gone. The watcher suspended in `for await` never notices that the engine went idle. | R-SYN-14, P-14 |
| S1-11 | major | Driver exit paths are incomplete. A transfer stream that ends without a terminal element leaves the job in `downloading` forever (probe R2d). The statement "cancellation returns nil" is false (probe R2c). The control continuation is never finished. | R-SYN-2, R-SYN-3, liveness |
| S1-12 | major | Whole-snapshot `expectedGeneration` treats **any** concurrent publish as a conflict. Under a running bulk sync, `ensureAvailable` re-plans three times and then throws `.storageUnavailable`. | R-SYN-10, R-SYN-6, R-CAR-7 |
| S1-13 | major | If point admission runs during a run's planning window, it can answer `.notFound` for an id that the freshly fetched manifest contains, and then negatively cache it for 60 s. | R-CAR-2, prior-art resolver parity |
| S1-14 | major | The run-settling rule is contradictory. Jobs that are all `blocked(.awaitingSpace)` end the run with nothing left to resume it, which contradicts the design's own R-SYN-11 test. `failed(.whenOnline)` is not counted as blocked, so `sync()` hangs offline. | R-SYN-11, R-SYN-6 |
| S1-15 | major | Enqueueing every planned fetch as a `Job` costs a **70 ms actor turn and +121.5 MiB at 100,000 entries** (probe R3), and job memory grows linearly with the asset count. | C2, P-7 |
| S1-16 | minor | `pump()` does not loop after it marks a victim, so the user job waits for `.paused` instead of "one actor turn". | §7.4 claim, H-4 |
| S1-17 | minor | A driver's priority is inherited from whatever task ran `pump()`, and promotion cannot raise it. | H-4 |
| S1-18 | minor | `cancel()` immediately after `prefetch` still starts a transfer, which wastes one request per prefetched id per swipe. | R-CAR-4 (waste), P-10 |
| S1-19 | minor | For a stalled subscriber, `.transfer(id)` progress slots outlive their transfers, so the §10.4 bound `P ≤ max + 3` is wrong. A stalled subscriber also keeps the engine alive after shutdown, and `subscribers == 0` cannot hold. | H-9, R-SYN-12, R-SYN-15 |

Areas that held after a genuine attempt are listed in §3, with what was tried.

---

## 2. Findings

Notation: `E` is the engine actor and `S` is the store actor. "Hop" means an unstructured `Task` that awaits the engine. Line references are to `docs/design/sync.md`.

### S1-01 · critical · Jobs with zero interests: downloads for nobody, and zombie pipeline slots

**Design text.** T14 (`verifying, committing | last interest leaves | (unchanged) | finish locally`, l.394) deliberately creates jobs with no interests. The transitions out of those states carry no interest guard: T9 (l.389), T22 (l.402) and T11 (l.391, which guards only the non-empty case). Invariant 2 (l.497) says "Every job has at least one interest, or is in `verifying`/`committing`". The table itself breaks it.

**Timeline A: T14 → T9 → T18 → T3, a download for nobody.**
1. Handle H (prefetch) is the only interest in asset X. X's job J receives `.staged` and moves to `verifying` (T5). J's driver suspends at `await store.verify` (RE-S14).
2. The user swipes, and the controller cancels H. The release hop reaches E, J's interests become empty, and T14 leaves J in `verifying`.
3. The CDN object is truncated, so the hash mismatches. T9 sets `failed(.at(t + backoff))`, pushes `.retry(X, e)` and arms the alarm. J now has no interests and is not in `verifying`/`committing`, so invariant 2 is broken.
4. The alarm fires. T18 makes J `queued`, `pump()` applies T3, and J is `downloading`. **A transfer runs for nobody** (R-CAR-4: "leaving no transfer running for nobody"). It repeats up to `maxAttemptsPerRun` (4), so four wasted downloads.

**Timeline B: T14 → T11 with no interests, a zombie job and an engine stall.**
1. J is `committing` with no interests (T14).
2. A reconcile from `ensureAvailable` or a run has committed a new fingerprint for X in S, but E has not yet processed that apply's result (RE-S09 runs only after the `apply` await returns). J's commit throws `.staleEntry`.
3. T11 requires "interests non-empty", and no row covers the empty case. The driver exits, and J stays `committing` with no driver.
4. J counts against `|pipeline| < depth × max` forever, so after `2 × max` such events `pump()` never dispatches again. Because `jobs` is non-empty, the watcher stays alive (P-14). Waiters on any asset hang, and there is no timeout.

**Timeline C: T22 on a T14 job.** A run's reconcile changes X's fingerprint while J (no interests) verifies. T22 makes J `queued (new entry)` with "interests carried over", which is an empty set, and J downloads the new content for nobody.

**Timeline D: offline T6 and the §8.2 interactive cap.** A `resolve(.userInitiated)` is J's only interest. The transfer fails `.offline`, and §8.1 resumes the waiter with `.offline`. J is parked in `failed(.whenOnline)` with no interests. The satisfied edge then applies T19 (`queued`) and J downloads for nobody. The §8.2 cap ("the job keeps only its non-user interests") has the same gap when there are none.

**Timeline E: F29.** Re-attached background transfers are "adopted as verifying / downloading jobs" during `start()`, before any run exists, and with no interest specified. The last-interest rule then either cancels them immediately, losing exactly the work H-6 must keep, or lets them run for nobody.

**Violates:** R-SYN-4 and R-CAR-4 (A, C, D); design invariant 2; liveness and R-SYN-14/P-14 (B).
**Smallest fix.** Route every transition and every interest removal through one synchronous funnel, `retire(id, epoch)`:
- `interests.isEmpty ∧ state ∉ {verifying, committing}` ⇒ remove the job, cancel the driver, finish the control stream and tombstone the ticket.
- Out of `verifying`/`committing` (T9, T11, T22) with no interests ⇒ remove the job. Quarantine bookkeeping stays in the store.
- Re-attached transfers get a `system(.reattached)` interest, which the first run claims or releases.
- Debug-assert after every mutation that invariant 2 holds and that every job in `downloading ∪ verifying ∪ committing` has a live driver.

Tests: `R-SYN-4: a job whose last interest left during verification is not retried after an integrity failure`; `R-SYN-2: a stale commit with no interests removes the job and frees its pipeline slot`.

### S1-02 · critical · Run and group completions: never resumed (zero-fetch run) or resumed twice

**Design text.** RE-S10: "`await runGroup.completion` (continuation resumed when the run's last job is terminal)". §12.2 step 3: "Register one group interest … on every fetch; await completion". §12.4 step 2: "Cancel the active run". Exactly-once is argued only for `waiters` (invariant 3, l.498).

**Timeline A: the metadata-only catalog change, which is the design's headline R-SYN-8 case.**
1. The new manifest changes only `localPathComponents`. RE-S04…RE-S09 succeed, `plan.fetches == []`, and the reconcile is committed.
2. The run reaches RE-S10 and awaits `runGroup.completion`. There is **no job**, so no "last job" ever becomes terminal, and the run is suspended forever.
3. `sync()` never returns. RE-S11 never writes the stamp, so the sync stays due, and the next launch runs again and hangs again. The run task stays alive, which keeps the watcher alive ("a run is active"), so P-14 is never reached. Only shutdown step 3 releases it.

The same hang occurs when every planned fetch was committed by a resolve between RE-S07 and enqueue. `ensureAvailable` hangs the same way whenever its scope needs no fetch.

**Timeline B: purge "cancels" a run.** The run is suspended at RE-S10. `purge()` calls `runTask.cancel()`. **Probe R8:** a task suspended on a `CheckedContinuation` stored in an actor is still suspended 500 yields after `cancel()`. The run does not end `.failed(.cancelled)`, and it keeps its interests unless purge drops them.

**Timeline C: double resume, which traps.**
1. `ensureAvailable` registers group G with one member, A. A commits; `finish` → `groups[G]?.memberFinished(A)` → G's completion is resumed with the report. Nothing in the design removes G from `groups` at that point.
2. In the same instant the caller's task is cancelled. The cancellation handler is still installed until the operation returns, so `onCancel` sends a hop that runs `withdraw(G)`. G is still in `groups`, so the completion is resumed with `.cancelled`.
3. A `CheckedContinuation` resumed twice traps (the design's own §15.11 relies on that trap).

**Other completions with no stated resumer on every exit path:** `sync()` joiners, `start()` joiners, the second caller of `shutdown()`, `waitUntil` continuations (a test that waits across shutdown leaks), and any second `pending` pull at `.clientShutDown`. §10.3 resumes only "the first pending continuation".

**Violates:** R-SYN-6 (the run must end), R-SYN-8/R-SYN-9 (stamp after a completed metadata-only sync), R-SYN-10 (cancellation), H-3 exactly-once, R-SYN-14/P-14. Timeline C is a crash.
**Smallest fix.** Give every completion kind the `waiters` discipline. Store it in `[Token: CheckedContinuation]` and resume it **only** through `removeValue`. `settle(groupOrRun)` is a synchronous function that runs at registration time (no members ⇒ resume immediately), after every job transition, after every withdrawal, in purge (which resumes with `.failed(.cancelled)`) and in shutdown (which drains every table). `deinit` asserts that every table is empty.

Tests: `R-SYN-8: a metadata-only manifest change completes the run and writes the stamp`; `R-SYN-10: ensureAvailable cancelled as its last member commits resumes exactly once`; `R-CLN-6: purge ends the active run with failed(cancelled)`.

### S1-03 · critical · A half-open breaker whose probe is abandoned never recovers

**Design text.** §8.3: "At `until` … exactly **one** probe is admitted … Success → `closed` … Failure with the same cause → `open(trips + 1)`". The state is `halfOpen(cause, trips, probe: TransferID?)`. §8.1: "`cancelled` | not a failure: T13 (abandoned) or T7 (paused)", and no breaker input.

**Timeline.**
1. A 5xx burst opens the breaker for 30 s. The alarm fires at `until`, and the state becomes `halfOpen(probe: nil)`.
2. The user opens page P, and `resolve(X)` reaches `pump`. `admit` returns `.probe`, the state becomes `halfOpen(probe: T_X)`, and X's transfer starts.
3. 200 ms later the user swipes away. `withdraw` empties X's interests, T13 runs and the transport reports `.cancelled`. That is "not a failure", so `record` is never called.
4. The breaker stays `halfOpen(probe: T_X)`, and `admit` rejects everyone else because exactly one probe is allowed. Every queued job moves to `blocked(.circuitOpen)` and every `resolve` fails fast with `.serverUnavailable`. No deadline exists for a half-open state, so nothing ever changes it. **All network work stops until relaunch.**

The same thing happens when the probe is preempted (T16 → `.paused`), paused by thermal policy, superseded by T22, or when the probe is the run's manifest fetch and that run is cancelled by purge.

**Violates:** R-SYN-5 (the breaker must re-close), promise 1, liveness. This is a cancellation-induced livelock.
**Smallest fix.** Add `record(.abandoned(transferID))` on every driver exit that is neither success nor failure (the S1-11 funnel), which returns the state to `halfOpen(probe: nil)` so the next dispatch probes. Exclude the probe from preemption victims.

Test: `R-SYN-5: a half-open probe cancelled by its last caller lets the next request probe`.

### S1-04 · critical · Shutdown closes the store under operations it does not own

**Design text.** §12.7 cancels and joins only `ownedTasks` (drivers, alarm, watcher, run), then `await store.close()`. Entry points (`purge`, `performMaintenance`, `ensureAvailable` steps 1–2, `reportUnreadable`, `storageReport`, `withAsset`, and `start()` itself) run in caller tasks. Per `store.md` §6.5 step 4, `purge` sleeps `until: ack + grace` (10 s) **inside** the store call, on the caller's task. `close()` cancels only store-owned tasks.

**Timeline A: a blob re-published by a new client is deleted.**
1. Client A calls `purge(.evictable)`. The engine (RE-S24) awaits `store.purge`. S commits the records as absent with `DOOMED{k}`, then suspends in `sleep(until: ack + grace)`.
2. `A.shutdown()` runs. Steps 1–4 find no owned task for the purge. Step 5, `store.close()`, interleaves at S's suspension point: a durable flush, then the lock is released. `shutdown()` returns.
3. Client B opens the same root (any test that reopens a root, or a second client in one process) and takes the lock. B processes `DOOMED{k}` at launch. Later B resolves asset Y, whose content hash is k: `publish` makes blob k live and records Y as present(k).
4. A's purge wakes and runs `reapEligible()`. A's in-memory blob table still says k is doomed and eligible, so it calls `removeItem(blobs/…/k)`.
5. B's index now says present(k) but the file is gone. I-2 is broken mid-session and B's `lookup` hands out a URL to a missing file (H-2). With `ManualTimeSource`, the R-SYN-15 assertion `pendingSleepers == 0` also fails while the purge sleeps.

**Timeline B: `start()` racing `shutdown()`.**
1. `Task { await client.start() }` runs. `store.open()` takes `store.lock` and starts migration units (H-10 can take seconds).
2. `await client.shutdown()`. Step 5's `close()` interleaves with `open()` at one of its awaits and releases the lock, and `shutdown()` returns. RE-S01 runs only after `open()` returns.
3. `open()` resumes and keeps writing (migration, an index commit) **without the lock**. Then `client2.start()` on the same root acquires the lock, giving two writers (R-STO-9). Depending on timing, `client2` instead gets `.locked`, intermittently.

**Also:** a `performMaintenance` batch or an `ensureAvailable` `apply` that lands after `close()` gets `.closed`, which maps to `.storageUnavailable` instead of `.shutDown` (R-SYN-15's typed error). `AssetClient.deinit` runs `shutdown()` while the lifecycle is still `created`, and the design does not say that this must not open the store.

**Violates:** R-SYN-15 (flush, no leaked work), R-STO-9, I-2, I-3, H-2.
**Smallest fix.** Every store-touching entry point runs as an **engine-owned task**, and the caller joins it through the waiter pattern. That makes shutdown steps 2 and 4 cover it, and it gives independent cancellation for free (see S1-08). `start()` is an owned task. Shutdown in `created` goes straight to `shutDown`. Cross-design request to the store: every resumption after an await inside `AssetStore` re-checks `closed` and aborts before any mutation (add this to the store's REENTRANCY rows R2/R3/R9), and `close()` awaits in-flight units.

Test: `R-SYN-15: shutdown during a purge's grace window leaves no deletion after close and no pending sleeper`.

### S1-05 · major · Window promotion and cell reuse drop interest to zero, which restarts the transfer

**Design text.** §6.4: "Priority changed → the new handle is created BEFORE the old one is cancelled, so interest never drops to zero in between and the transfer is never restarted." The new handle's registration and the old handle's release are **two independent unstructured tasks**. The handle's `init` and `release` are nonisolated, so both tasks start on the global executor. Nothing orders their arrival at E.

**Timeline (probe R1, which uses the design's `PrefetchHandle` verbatim).**
1. The main actor calls `update`. It creates new handle N (registration task T_N), then cancels old handle O and drops it. O's release tasks, T_O and T_O′, await `O.registration.value`, which has already completed.
2. T_O reaches E first. X's interests become empty, T13 cancels the transfer, and the partial bytes are discarded.
3. T_N reaches E. T1 and T3 start a new transfer from byte 0.

**Measured:** 1 restart in 60,000 promotions on an idle host, and **313, 375 and 399 restarts out of 20,000 (1.6–2.0 %)** with 12 busy cooperative-pool tasks, which is the condition of a parallel Swift Testing run. Under Q-5 (three repeats, zero flakes), `R-CAR-3: a neighbour that becomes current is promoted without a second transfer` will flake.

**Same class:** carousel cell reuse. `resolve(X)` is cancelled (its `onCancel` hop W is queued) and the new cell immediately calls `resolve(X)`. W and the new join race; when W wins, the transfer restarts.

**Violates:** R-CAR-3 ("never duplicating transfers"), R-SYN-3 ("promotes it", which implies no restart), Q-5.
**Smallest fix.** The controller sends **one versioned message per update**: `engine.setWindow(controllerID, seq, targets)`. E diffs old and new targets synchronously and ignores `seq ≤ last`, so the new interest exists before the old one is removed, in one actor step. Handles inside the window become engine-side membership. Optionally, add `lingerInterval` (alarm-driven, default 0 in tests) before T13 to absorb cell-reuse churn.

### S1-06 · major · The control stream loses `.pause`, and promotion is not ordered before the next start

**Design text.** §3.3: control is `.bufferingNewest(1)`, "priority changes coalesce correctly: only the latest priority matters". T16: `control.yield(.pause)`; "its slot is free now". R-NET-10 test: "a promoted asset's priority change reaches the transport before any other transfer starts".

**Timeline A: probe R2a, the lost pause.**
1. `max = 1`, and bulk B is downloading. `resolve(U)` reaches `pump`, and T16 yields `.pause` and marks B `preempting`. Its slot counts as free and U starts.
2. Before the transport's control task reads, `resolve(B)` triggers T15, which yields `.setPriority(.userInitiated)`. The buffer drops `.pause`: the yield returns `dropped(.pause)`, and the transport sees only `[.setPriority(.userInitiated)]`.
3. B is never paused, so T7 never arrives. B stays `preempting`, which is excluded from `running`, for the rest of its transfer, possibly 1 GB. Two transfers run at `max = 1`. Each further user request can add another, up to `2 × max` concurrent transfers for the duration of whole transfers rather than "typically 1" briefly.

**Timeline B: probe R6, promotion ordering.** T15 yields `.setPriority` to A's control stream, and `pump()` starts bulk C in the same turn (C's driver calls `remote.transfer`). The fake transport's per-transfer control task (§15.1) and C's driver race to the fake. **`start(C)` was logged before `priority(A)` in 8,582, 10,539, 8,204 and 8,095 of 20,000 runs (41–53 %)**, idle or loaded. The R-NET-10 test is a coin flip. In production, URLSession can start C before A's priority is raised.

**Violates:** R-SYN-3 (bounded parallelism), R-NET-10, Q-5.
**Smallest fix.** Replace the control stream with a **synchronous `Sendable` handle** returned by `transfer`: `protocol TransferControl: Sendable { func setPriority(_ p: AssetPriority); func pause() }`. The live backend is a final class with `let task: URLSessionTask`. `NSURLSessionTask` is `NS_SWIFT_SENDABLE` in the iPhoneOS 27 SDK (`NSURLSession.h:686`), and probe R7 compiles at iOS 15 with `-warnings-as-errors` and zero escapes. The fake can use a Mutex-backed log (test-only, already allowed). E calls the handle inside the join body, so the call is totally ordered before any `Task` spawned afterwards in the same turn.

Minimal alternative, which fixes A but not B: a state-valued directive, `struct TransferDirective { var priority: AssetPriority; var pauseRequested: Bool }`, with newest-wins and a sticky pause.

### S1-07 · major · Promotion and demotion do not re-run admission for blocked or failed jobs

**Design text.** T15 covers only `queued, downloading`. T17 fires only on a conditions, breaker, throttle or space **change**. T20 is limited to `failed` + `userInitiated`. §11.2: user requests are "allowed" under every policy and "attempted" when offline. §11.3: running bulk or prefetch transfers are paused when they become disallowed.

**Timeline.**
1. Low Data Mode is on (`bulkOnConstrained = false`). A run enqueues X, and `pump` applies T4, so X is `blocked(.policy)`.
2. The user opens X's page. `resolve(.userInitiated)` misses the fast path, and `addInterest` raises J's lane to `userInitiated`. No transition applies to `blocked`, so J stays blocked.
3. The `resolve` hangs until Low Data Mode is turned off. That is mid-use waiting, and it contradicts §11.2.

**Offline variant:** a run left X `blocked(.offline)`, and the user's `resolve` hangs instead of throwing `.offline`. So `R-CAR-2: an offline fetch fails with offline and succeeds after the path becomes satisfied` passes or hangs depending on whether a run reached X first.

**Demotion variant:** X is running at user lane under Low Data Mode, and the user leaves. `relane` sends only `.setPriority(.bulk)`, so a bulk transfer continues on Low Data Mode (R-SYN-7).

**Violates:** R-SYN-7, R-CAR-2, promise 1.
**Smallest fix.** Every lane change calls `readmit(job)` synchronously. A `blocked` job, or a `failed` job not quarantined, re-evaluates `gate(newLane)`: it becomes `queued`, or user waiters fail immediately with the §11.2 error. A running job whose new lane is not allowed receives the policy pause (T16-like).

Tests: `R-SYN-7: a userInitiated request for a policy-blocked bulk asset starts immediately`; `R-SYN-7: demoting a running transfer into a disallowed lane pauses it`.

### S1-08 · major · Shared work is run in, or awaited through, a caller's task

**Design text.** "Every async API awaits `ensureStarted()`" (§13.2), with the mechanism unspecified; the natural single-flight is `await startTask.value`. The point-admission manifest fetch "is shared with any run that is fetching" (§6.5), with its owner unspecified. `sync()`: "a second caller joins the active run" (§12.5). Owned tasks are only "drivers + alarm + watcher + run" (§8.4). §2.1 itself rejects `Task.value`, because a cancelled awaiter does not return.

**Timelines.**
- **A.** A first launch after an update migrates a 1 GiB legacy cache inside `open()`. Three `resolve`s await `ensureStarted()`, and one of them is cancelled. **Probe R4a:** a cancelled awaiter of `task.value` is still suspended after 200 yields, until the shared task finishes. If instead `start` runs inline in the first caller's task, cancelling that caller aborts `open()` (ADR-003 units check cancellation), and the client becomes `degraded` for everyone.
- **B.** Run R is fetching the manifest on a slow network, and `resolve(unknown Y)` joins that fetch. Then `purge` cancels R (§12.4 step 2), and Y's caller receives an error although it never cancelled. Conversely, if the fetch runs in Y's task and Y is cancelled, R fails `.failed(.cancelled)`.
- **C.** A run awaiting the manifest fetch through `Task.value` ignores its own cancellation. Shutdown step 4 then waits for the network: 60 s on the URLSession default, or forever with `FakeRemoteSource .hold`, so the test hits its `timeLimit`.
- **D.** If a `sync()`-initiated run executes in its first caller's task, cancelling that caller cancels every joiner's run.
- **E.** RE-S24 fails purged non-user waiters with `.cancelled`, so a caller that never cancelled receives `.cancelled` (H-3 independence; R-CAR-7 UI mapping).

**Violates:** R-SYN-4, R-SYN-10 ("honour cancellation"), R-SYN-15, H-3.
**Smallest fix.** Every piece of shared work (start, each manifest fetch, each run) is an **engine-owned task**. Every caller joins through token, continuation and `withdraw`, exactly like `resolve`, and never through `Task.value`. Withdrawing the last joiner cancels the shared work only if no run or system interest remains. Purge reports a distinct cause (`.notFound`, or a `RemovalReason.purged` in the event) instead of `.cancelled`.

### S1-09 · major · `ownedTasks` keys collide, so successors become invisible to shutdown

**Design text.** §8.4: "`ownedTasks: [TaskKey: Task<Void, Never>]` … body ends with `await self.taskEnded(key)`". `TaskKey` is not defined. The alarm code `Task { [weak self] in try? await time.sleep(until:); await self?.alarmFired(token) }` has no `taskEnded`.

**Timeline.**
1. X's job goes through T13, and driver D1 is cancelled but still unwinding, at `await remote.transfer` or the next element.
2. `resolve(X)` arrives again (S1-05 makes this common), and T1 and T3 spawn driver D2 under `ownedTasks[.driver(X)]`, overwriting D1's entry.
3. D1 ends and calls `taskEnded(.driver(X))`, which **removes D2's entry**.
4. `shutdown()` neither cancels nor joins D2. The transport keeps transferring after shutdown (`FakeRemoteSource.activeTransfers ≠ 0`), and D2 later calls into a shut-down engine.

The same applies to `.alarm` (re-arming cancels A1 and arms A2, then A1's end unregisters A2), `.watcher` (an idle-to-work restart) and `.run`. If the alarm is registered at all, its entry is never removed, so `ownedTasks` never reaches 0.

**Violates:** R-SYN-15 ("tests prove no task leaks"), R-SYN-14/P-14 (the census is wrong in both directions).
**Smallest fix.** Use `TaskKey = UInt64`, a spawn sequence. `taskEnded(seq)` removes exactly that entry, and role indexes (`alarmSeq`, `watcherSeq`, `job.transfer.driverSeq`) point at sequences. The alarm ends with `taskEnded(seq)` like every owned task. Re-arming and shutdown cancel it, so a strong `self` is fine.

### S1-10 · major · The idle-silence mechanism leaves timers and observers alive

**Design text.** §8.4: entries "are validated when they fire (epochs), and stale ones are skipped"; "One alarm task, armed iff the heap is non-empty"; "Idle = … ∧ heap empty". Test: `R-SYN-14: one alarm serves many retry deadlines and is cancelled when the last one is withdrawn`. Watcher: "If no longer needed, the watcher exits" (RE-S18).

**Timelines.**
- **A.** Bulk job J fails with a 5xx, and `.retry(J, e)` is scheduled at +300 s (`maxDelay`). The run ends `completeWithFailures`, or J's last interest is withdrawn, so J is removed. The stale heap entry remains, so the alarm stays armed for up to 300 s: `armedTimers = 1`, `ownedTasks = 1`, `pendingSleepers = 1`. P-14 fails, and the design's own R-SYN-14 test contradicts lazy deletion.
- **B.** A 503 with `Retry-After: 3600` leaves a `.throttleEnd` entry after all work has gone, so the timer lives for an hour. An open breaker with no waiting job keeps a `.breakerHalfOpen` timer for up to 3,600 s.
- **C.** The engine becomes idle while the watcher is suspended in `for await c in stream`. No conditions change arrives, so RE-S18 never runs. The watcher and `NWPathMonitor` live forever (`activeObservers = 1`).

**Violates:** R-SYN-14, P-14 (`idle_timers_max = 0`, `idle_tasks_max = 0`).
**Smallest fix.**
- Use an indexed min-heap with removal by reason key: remove `.retry(id)` when the job is removed, or keep a live-entry count and disarm at 0.
- Schedule `.throttleEnd` and `.breakerHalfOpen` only while at least one job is blocked on them or a pending run waits for them. Otherwise the pure `admit(at:)` resolves them lazily.
- Add one `becameIdle()` hook, called from the S1-01 funnel, that **cancels** the watcher and the alarm.

### S1-11 · major · Driver exit paths: a stream with no terminal, a buffered terminal after cancel, an unfinished control stream

**Design text.** §3.3: "the last element is always terminal". RE-S13: "Driver cancellation returns `nil`, and the loop exits without any state change (T13 already applied)".

**Timelines.**
- **A (probe R2d).** The transport finishes the stream without a terminal element, for example after a session invalidation, a background-session reset or a transport bug. The driver's `for await` ends with `nil`, and `Task.isCancelled == false`. No rule covers this, so the job stays `downloading`. The slot is never released, waiters hang with no timeout, and `max` such events stall the engine.
- **B (probe R2c).** T13 cancels a driver whose `.staged` is already buffered. **The cancelled driver still receives `[.staged("staging/x.part")]`**, so the RE-S13 statement is false. Correctness then depends on the `E` check being applied to that element. The staged file has no owner until the next staging GC (R-CLN-3 runs only at launch and after a sync). Under a swipe storm on large media that is disk growth.
- **C.** No step calls `control.finish()`. The transport's per-transfer control consumer must notice termination on its own, or it leaks.

**Violates:** R-SYN-2 (validated transitions), R-SYN-3 (slot accounting), liveness, R-CLN-3 (timely staging release).
**Smallest fix.** Add one `driverExited(job, epoch, outcome)` funnel:
- `nil` without a terminal element, and not cancelled, ⇒ `.failed(.transient)`.
- An element received after T13 ⇒ `releaseStaging` at once.
- Always call `control.finish()`.
- Always report probe abandonment (S1-03).

Correct the RE-S13 text.

### S1-12 · major · Whole-snapshot optimistic concurrency starves reconcilers under load

**Design text.** RE-S07: "The snapshot may have advanced (a resolve committed): tolerated, because RE-S09 rejects a stale base". RE-S09: "On `.staleGeneration`: re-plan (at most `maxReplans` = 3, then the run fails with `.storageUnavailable`)". X-1 keeps `expectedGeneration:` on the store's `apply`. `ensureAvailable` step 2 also reconciles.

**Timeline.**
1. Bulk run R is downloading small assets, and each `publish` advances the snapshot or commit generation.
2. The user taps "download chapter", which calls `ensureAvailable` (E). E fetches (304), plans against generation g, then calls `apply(…, expectedGeneration: g)`.
3. One of R's drivers has published during E's window, so `apply` throws `.staleGeneration`. The window spans a metadata-queue hop (`freeSpace`, queued behind 11–16 ms index commits per `store.md` §4.6), the planner and a main-actor hop (the access drain).
4. Steps 2–3 repeat three more times, and **E throws `.storageUnavailable`** although storage is fine. A fresh-install launch run planning while point admissions and prefetches publish hits the same pattern.

**Violates:** R-SYN-10, R-SYN-6, and R-CAR-7 (the wrong typed error reaches the UI).
**Smallest fix.**
- Make the preconditions precise: `apply` checks the applied-manifest digest plus per-record revisions, only for the ids the reconcile step touches (`store.md` records already carry `revision`). Publishes of unrelated ids never conflict.
- Skip `apply` when the reconcile step is empty, which is the normal case for `ensureAvailable` after a run.
- Treat exhaustion as "retry after the next publish", never as `.storageUnavailable`.

### S1-13 · major · Point admission during a run's planning window returns a false `.notFound`

**Design text.** §6.5 and RE-S19: "Found → T1 with point admission; else → `.notFound` and a negative cache until `unknownIDRefetchInterval`". RE-S04 applies results by fetch sequence. The design does not say which manifest RE-S19 consults, or which ETag the conditional fetch sends.

**Timeline.**
1. Run R reaches RE-S04 and fetches M2 (200, ETag E2), which adds Y. R suspends at RE-S05 (decode, ≤ 80 ms), RE-S06, RE-S07 and RE-S09.
2. The carousel resolves Y. Y is not in the applied manifest M1, so it goes to `unknownWaiters[Y]`. R's fetch has already completed, so a new conditional fetch starts with `If-None-Match: E2` (the latest seen). It returns 304.
3. RE-S19 consults the applied manifest M1, where Y is absent. Y gets **`.notFound` and is negatively cached for 60 s**, although the fresh manifest contains it. If the fetch had sent E1 instead, it would re-download M2 in full (3.3 MB plus decode) for a manifest E already holds.

**Violates:** R-CAR-2 parity (`an identifier unknown to a freshly fetched manifest fails with notFound`; Y is known to it), prior-art resolver behaviour (`CDNAssetResolver.swift:36-63`).
**Smallest fix.** Keep `latestValidated: (seq, etag, manifest)` in E, set at RE-S05. Point admission consults it first, and a 304 means "`latestValidated` is current". When a run applies a manifest, it clears negative-cache entries for ids that manifest contains.

### S1-14 · major · The run-settling rule contradicts R-SYN-11 and depends on timing offline

**Design text.** §12.1 phase 3: "reclaim pending → `blocked(.awaitingSpace)`; the alarm runs GC, `freeSpace` is re-read, `pump()`". §12.5: "when every remaining job is blocked (policy, breaker, space), the run ends immediately … drops its interests, and sets `pendingRunOnConditions` / `pendingRunOnBreakerClose`".

**Timeline A.**
1. The plan needs 600 MB. The eviction plan frees 700 MB and is committed with the reconcile, but the deletions wait out the 10 s grace window (I-3).
2. Phase 3 makes every fetch `blocked(.awaitingSpace)`, so per §12.5 the run ends `.blocked` at once and drops its interests, and the jobs are removed.
3. No `pendingRunOnSpace` exists, so after GC nothing resumes. This contradicts the design's own test `R-SYN-11: fetches wait for space reclaimed after the grace window instead of failing`.

**Timeline B.** Offline before dispatch, the jobs become `blocked(.offline)` and the run ends `.blocked(.offline)` immediately. Offline mid-flight, the jobs become `failed(.whenOnline)`, which is not "blocked", so the run never settles while offline and `sync()` hangs for hours. The same conditions give two outcomes depending on timing.

**Violates:** R-SYN-11, R-SYN-6 (a deterministic outcome).
**Smallest fix.** Define `settled(job)` explicitly:
- `blocked(.awaitingSpace)` is unsettled while a reclaim deadline exists in the heap.
- `failed(.whenOnline)` counts as `blocked(.offline)`.
- Alternatively, add `pendingRunOnSpace`.

### S1-15 · major · One `Job` per planned fetch blows the C2 actor-turn limit and P-7 memory at scale

**Design text.** §12.1 phase 2: "Then fetches are enqueued" (jobs are created on E with no await). §13.8 P-7: "Jobs exist only for outstanding work". On a fresh install, every asset is outstanding.

**Measured (probe R3).** The `Job` shape follows §5.1. Entry strings are shared with the plan (copy-on-write), there is one interest, and there is a lane-queue entry and a run-member set.

| F | Enqueue actor turn (best of 5) | Run-drop turn (§12.5, worst) | Job-table footprint |
|---:|---:|---:|---:|
| 10,000 | 3.4–4.0 ms | 1.8–2.2 ms | +9.2 MiB |
| 100,000 (R-MAN-2 cap) | **70.1–70.3 ms** | **44.6–48.5 ms** | **+121.5 MiB** |

C2 (~10 ms per stretch on a cooperative thread) is exceeded above roughly 25,000 entries. At the cap, the job table alone exceeds P-7's 48 MiB, before the manifest and the plan. The design's own test name ("… and does not grow with catalog size") fails for any variant that scales the asset count, because job memory grows linearly with F.

**Smallest fix.** A run keeps `fetches` as a **cursor** and materialises at most `pipelineDepth × max` jobs plus a small look-ahead. `pump()` refills from the cursor. An id that is already a job (wanted by a waiter or handle) just gains the run interest. Dropping a run is O(materialised jobs). Apply the same to `ensureAvailable` groups.

### S1-16 · minor · Preemption frees a slot that `pump()` does not use

§7.3 marks the victim after the dispatch loop has exited, so the freed slot is used only at the next `pump()`, which is T7, when `.paused` arrives after the transport has produced resume data. That contradicts §7.4, "With `max == 1`, preemption guarantees the user job starts after one actor turn". **Fix:** after marking the victim, `continue` the dispatch loop, because the ledger already counts the slot as free.

### S1-17 · minor · Driver priority is accidental

`Task {}` inside `pump()` inherits the priority of the current task. That can be a `withdraw` hop spawned from a background-QoS cancel, the alarm task, or a bulk run. A driver spawned for a bulk job that is later promoted keeps background priority for its stream handling, `verify` hops and `commit`. The user waiter awaits a continuation, not the driver, so no priority escalation happens. **Fix:** spawn every driver with `Task(priority: .userInitiated)`. Lane differentiation then comes from engine scheduling and URLSession priority.

### S1-18 · minor · `cancel()` right after `prefetch` still costs a request

Probe P6 counted only interest groups. Because the release correctly waits for `registration.value`, `registerGroup` always runs first, and T1/T3 can start the transfer before T13 cancels it. That is one wasted HTTP request per prefetched id per fast swipe. **Fix:** `cancel()` and `deinit` call `registration.cancel()` synchronously (`Task.cancel()` is thread-safe and the handle stays `let`-only), and `registerGroup` returns `nil` if `Task.isCancelled` at entry. The release hop is unchanged.

### S1-19 · minor · The event-queue bound and stalled subscribers at shutdown

§10.4 bounds progress keys at `max + 3` because `transfer(id)` exists "only for running user/prefetch transfers". But a stalled subscriber's `.transfer(id)` slot stays live after the transfer ends, because `.asset(id)` is a different slot. So P is at most the number of distinct user/prefetch assets transferred, not `max + 3`. **Fix:** publishing the terminal event for `.asset(id)` removes that subscriber's `.transfer(id)` slot.

Also, a stalled subscriber that still holds its stream keeps the engine and its backlog alive after shutdown, so the R-SYN-15 assertion `subscribers == 0` cannot hold for it. State that the test drains or drops its probes before asserting, or drop non-terminal slots when the subscriber's queue finishes.

---

## 3. Areas attacked that held (what was tried)

- **Exactly-once for `waiters`.** Every resume site was enumerated: `finish`, `withdraw`, T21, RE-S19, the §8.2 cap and shutdown's wholesale drain. Each goes through `waiters.removeValue`, inside one synchronous actor step. Cancel racing completion (F3), a pre-cancelled caller (F4) and cancellation between the fast-path check and registration (the hop withdraws afterwards) all hold. The drafter's P2 (200 seeds × 100 callers) exercises these paths. S1-02 is the exception, for the *other* continuation tables.
- **Pre-cancelled sleeper in `ManualTimeSource`.** Re-read `.build-probe-sync/p5_time.swift`. The `Task.isCancelled` check is inside the same `Mutex.withLock` that registers the sleeper, so a cancellation that arrives before registration cannot strand it. This holds.
- **`deinit` escaping `self`.** I wrote `SubscriptionLease.deinit` in house style with explicit `self.` captures inside `Task {}`. Swift 6.4 **rejects** it ("capture of 'self' in a closure that outlives deinit", probe R4b), and the let-copy form compiles at iOS 15 with `-warnings-as-errors`. No runtime hazard.
- **Dropping an un-iterated transfer stream (RE-S12).** Probe R2b: the producer's `onTermination(.cancelled)` fires and a later `yield` returns `.terminated`. This holds on the macOS 27 runtime. iOS 15 runtime behaviour remains R-1 in the design.
- **Subscription release.** Cancel while suspended in `pull`, cancel between `registration.value` and `pull` (`pull` on an unknown id returns `nil`, as P4's `guard` shows), and break-then-drop all hold. P4's two prototype bugs are fixed in the design text.
- **Shutdown join deadlock.** Shutdown is suspended at `await t.value` while owned tasks need E for `taskEnded`. The actor is free during that suspension, so there is no deadlock. Step 3 (resume waiters) precedes step 4 (join), so drivers never wait for waiters.
- **Alarm supersession.** A stale `alarmFired(token)` is a no-op, and the successor alarm drains due entries, including when `sleep(until:)` returns immediately for a past deadline. This holds (apart from the bookkeeping issue in S1-09).
- **Crash points around the stamp.** I considered a crash between the last `publish` and `markSynced`, during `close()`'s durable flush, and between `apply` and the first fetch. `store.md`'s `requireCommitted` orders publishes before the stamp, so every crash leaves "no stamp ⇒ due" or a complete stamp. This holds, given the store contract.
- **Purge and stamp ordering (R-CLN-6).** I tried a run that starts after `purgeEpoch += 1` and finishes after the purge. `store.md` §6.5 commits the purge synchronously on its first turn, before any run started after the bump can plan, and X-6's in-turn check precedes `markSynced`. I found no failing interleaving. S1-04 and S1-08 cover the other purge hazards.
- **Unsafe gate.** None of the proposed fixes needs an escape. The synchronous `TransferControl` handle compiles at iOS 15 with 0 escapes (probe R7, `NSURLSessionTask` is `NS_SWIFT_SENDABLE`). Fakes may use `Mutex` behind `@available(macOS 15, iOS 18, *)`.
- **`@concurrent` (§4.1, P7).** Probe R5: under this package's settings (tools 6.0, Swift 6 mode, `NonisolatedNonsendingByDefault` off), a plain `nonisolated static func … async` already runs off the caller's actor, and only with that feature on does it stay on the caller's actor. `@concurrent` is therefore redundant here. **Not verified:** whether consumers building with Swift < 6.2 (SPEC §3 allows consumers below 6.3) can parse `@concurrent`. Only Xcode 27 / Swift 6.4 is installed. Phase C should either use a plain `nonisolated` function or confirm the minimum consumer compiler.

---

## 4. Probe evidence (`.build-probe-review-sync-1/`)

| Probe | Question | Command | Output |
|---|---|---|---|
| `r1_window_order.swift` | Can an old handle's release overtake a new handle's registration (§6.4)? | `xcrun swiftc -parse-as-library -O -swift-version 6 -target arm64-apple-macos12.0 … && ./r1 [load]` | idle: `0`, `0`, `1` restarts of 20,000. Loaded (12 busy pool tasks): **`375`, `313`, `399` of 20,000** |
| `r2_streams.swift` | (a) Does `.pause` survive a later `.setPriority` with `.bufferingNewest(1)`? (b) Does dropping an un-iterated stream terminate it? (c) Is a buffered terminal delivered after cancel? (d) Can a stream end with no terminal? | same flags; also the iOS 15 command | (a) `transport sees [setPriority(userInitiated)]; second yield result: dropped(pause)`. (b) `onTermination(cancelled); later yield -> terminated`. (c) `cancelled driver still received: [staged("staging/x.part")]`. (d) `consumer saw [progress(10)] then nil, Task.isCancelled=false`. iOS 15 compile exit 0 |
| `r3_enqueue.swift` | Actor-turn time and memory to enqueue F jobs (§12.1, §5.1) | same flags | `F=10000 … 4.0 ms; … 2.2 ms; +9.2 MiB` / `F=100000 … 70.1 ms; … 48.5 ms; +121.5 MiB` (second run: 3.4 / 70.3 ms, 1.8 / 44.6 ms) |
| `r4_value_and_deinit.swift` | (a) Does a cancelled awaiter of `task.value` return early? (b) Is a `self`-capturing `Task` in `deinit` accepted? | iOS 15 and macOS commands | (a) `still suspended after 200 yields despite cancel()`. (b) iOS 15: `error: capture of 'self' in a closure that outlives deinit`. The let-copy form gives iOS 15 exit 0 and `unsubscribed: 1` |
| `r5_offactor.swift` | Is `@concurrent` needed for off-actor planning under this manifest? | with and without `-enable-upcoming-feature NonisolatedNonsendingByDefault` | default: `plain … ran on main = false; @concurrent ran on main = false`. With the feature: `plain … = true; @concurrent … = false` |
| `r6_promotion_order.swift` | Does a promoted transfer's `setPriority` reach the fake before the next transfer starts (R-NET-10 test)? | same flags `[load]` | **`8582`, `10539` (idle); `8204`, `8095` (loaded) of 20,000** with `start(B)` first |
| `r7_handle.swift` | Does a synchronous `Sendable` transfer handle over `URLSessionTask` compile at iOS 15 with no escape? | iOS 15 command | exit 0. SDK: `NSURLSession.h:686 NS_SWIFT_SENDABLE` precedes `@interface NSURLSessionTask` |
| `r8_run_completion.swift` | Does `runTask.cancel()` wake a run suspended on an engine-held `CheckedContinuation` (RE-S10, §12.4)? | same flags | `run task still suspended 500 yields after cancel()` |

---

## 5. Notes for Phase C

1. S1-01, S1-03 and S1-11 share one root cause: the transition table has no single exit funnel. One `retire` / `driverExited` pair, with invariants asserted after every mutation, closes all three.
2. S1-02, S1-04 and S1-08 share another: the design owns only some of its suspended work. "Every piece of shared or store-touching work is an engine-owned task, and every caller joins through the waiter pattern" closes all three, and it makes R-SYN-15 provable from `ownedTasks` alone.
3. S1-05 and S1-06 share a third: ordering is assumed across independently scheduled tasks. Make ordering-critical messages synchronous on the engine (a versioned window update, and a synchronous transfer handle).
4. S1-04 needs a matching change in `store.md`: every resumption re-checks `closed`, and `close()` waits for in-flight units.
