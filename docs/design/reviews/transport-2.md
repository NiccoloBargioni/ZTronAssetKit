# Adversarial review #2 — `docs/design/transport.md`

> **Lens:** lifecycle and platform. This review covers:
> - background-session re-attachment across relaunch (duplicated or lost work);
> - delegate `Sendable` conformance without `@unchecked`;
> - `URLSession` invalidation and leaks;
> - double residency on the Apple tier, and its offline catalog fallback;
> - iOS 15 availability;
> - whether the coverage floors are reachable with only two excluded files of ≤ 250 lines;
> - whether P-10 and P-11 can pass on a loopback server.
>
> **Reviewer:** Phase B reviewer `review-transport-2`, who did not write the design. **Date:** 2026-10-04.
>
> **Read:**
> - `CLAUDE.md`;
> - SPEC §1.4, §2.3, §4.1–4.3, §5.2–5.5, §5.7, §5.9, §6 (P-10, P-11, P-14), §7.3, Appendix B and Appendix C;
> - `docs/RECON.md`, `docs/DECISIONS.md` (ADR-001…011), `docs/BASELINE.md`;
> - `docs/APPLE-API-VERIFICATION.md` §1, §4 and §5;
> - `docs/design/transport.md`, all of it;
> - the contracts the transport plugs into: `docs/design/store.md` §2.4, §3 and §6.3, and `docs/design/sync.md` §7 and §8;
> - the drafter's prototype and logs in `.build-probe-transport/` (read-only);
> - `NSURLSession.h` from the iPhoneOS 27.0 SDK.
>
> **Method:** I checked every claim that depends on Swift or SDK behaviour with a compiled probe in `.build-probe-review-transport-2/` (git-ignored).
> - **Toolchain:** Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27, a macOS 27 host (Apple M3).
> - **Runtime probes:** `swiftc -O -target arm64-apple-macos12.0`. The URLSession probes use Swift 5 mode because they use probe-only locks; the other runtime probes use Swift 6.
> - **Compile probes:** `-typecheck -swift-version 6 -warnings-as-errors -enable-experimental-feature StrictConcurrency=complete`, at `arm64-apple-ios15.0` and at `arm64-apple-macos12.0`.
> - **Not probed:** I did not create a background `URLSession`. Doing so registers state in `nsurlsessiond` outside this repository, which the owner directive forbids, and relaunch behaviour is device-only anyway. The background findings are therefore argued from the header text and the design's own sequence, and they are marked as such.
> - §4 lists every probe and its output file.
>
> **Scope:** I wrote only this file and the probe directory. §6 reports the one exception: the temp files that `URLSession` itself puts in the per-user temp directory.

---

## 1. Summary

| ID | Sev. | Finding | Violates |
|---|---|---|---|
| T2-01 | **critical** | Every foreground download that does not complete leaves its partial bytes as `CFNetworkDownload_*.tmp` in the OS temp directory. This happens on `cancel()`, pause, a failure and `invalidateAndCancel()` alike, and the file is still there after the process exits. Nothing in the design can see the file or delete it. This team's own experiments today left **752 files (793.9 MiB)** there. | R-STO-1, R-CLN-3, R-CLN-4, R-CLN-9, D-7 (reopened), promise 3 |
| T2-02 | **critical** | Staging names are deterministic, and the design itself runs two producers of the same name at once (§10.5 "both", §10.8 promotion). The store publishes **by path**. The result is a blob whose bytes do not match its name. A forced-interleaving probe published 40,000 bytes under the hash of a 3 MB file. | I-1, R-STO-3, R-INT-2 |
| T2-03 | **critical** | Launch reconciliation joins a staging listing (taken in `open()`) with a `getAllTasks` snapshot (taken when the session is created), and the OS converts live tasks into staged files *between* the two. Step 6 then deletes that work. If the launch is offline, `wanted = ∅` cancels every live background task. | H-6 ("lose"), R-NET-3, R-CLN-3 |
| T2-04 | major | `invalidateAndCancel()` returns before the delegate's callbacks run (measured: 2.5 ms later), so staging writes land after `store.close()`. For the background session, "invalidate" either cancels the OS's work or leaves the identifier bound (NSURLSession.h:306-308). | R-SYN-15, R-STO-9, H-6 |
| T2-05 | major | The background backend cannot offer the synchronous `TransferHandle` without unstructured tasks. The excluded driver also holds untested decisions: it never writes the pause intent, so a background pause is reported as `cancelled`, and it discards the data that `cancelByProducingResumeData()` returns. | X-T1's own argument, R-NET-3, H-4, Q-2 intent |
| T2-06 | major | Attempt numbers are per process, but OS task tags outlive the process. The reconciler's "highest attempt" rule, the stale-attempt rule and the TransferID-keyed waiters therefore compare numbers that cannot be compared. Two tasks can even carry identical tags. | H-6 (duplicate, misrouted terminals) |
| T2-07 | major | Garbage or truncated resume data fails with **−1002**, which the table maps to `rejected(.invalidURL)`. The data is never discarded, so the asset fails on every run. Read literally, rule 3 also discards valid resume data whenever a resumed request fails offline. | R-NET-8, R-SYN-6, R-SYN-13 |
| T2-08 | major | "One fresh restart inside the same `transfer()`" (§7.2 rule 3) cannot be built on a mailbox that `didCompleteWithError` finishes and a handle that holds `let task`. After the restart, pause, cancel and setPriority all reach a dead task. | H-3, H-4, R-NET-10, X-T10 |
| T2-09 | major | A background session also makes R-NET-7 (the size cap) and R-NET-4's "≤ 5 redirects" unenforceable while the app is not running. ADR-T1 lists only the key. | R-NET-7, R-NET-4 |
| T2-10 | major | With background enabled, the coordinator's pump lives forever, so the engine is never idle-silent. | R-SYN-14, P-14 |
| T2-11 | major | Nothing defines who creates the background session at a background launch. Every reading fails: the events are never drained, a full `start()` sync runs in a background window, or the delegate writes into a store that is not open. | R-NET-3, H-6, R-STO-9 |
| T2-12 | major | On the Apple tier, catalog/pack version skew (including the OS's silent background pack updates) is classified as integrity. R-INT-3 then persists a quarantine of *good* content until the catalog entry changes, which may be never. | R-APL-4, promise 1 |
| T2-13 | major | H-7 is not solved for the SPEC's own layout (one on-demand media pack). With a scope or a quota, "release when every entry is adopted" never fires. Pack bytes are invisible to the quota and to `StorageReport`. After a release, one eviction costs a whole-pack re-download. | H-7, R-APL-3, R-CLN-10, R-CLN-4, R-CLN-9 |
| T2-14 | major | On the Apple tier, OS awaits whose return is unknown sit in the request path. `checkForUpdates()` is awaited *before* the installed catalog is read. A pack `ensure` that runs in a caller's task makes one caller's cancellation cancel every other caller. | R-APL-4, H-3, R-SYN-10 |
| T2-15 | major | For P-11, sync's reserved interactive slot turns "concurrency 5" into a 4-way bulk run. Re-measured, the transport alone is then 4.0–4.3× (not 5.35×), and the engine may add at most 0.46–0.55 s of fixed cost per run. | P-11 |
| T2-16 | minor | `BackgroundEventsRelay`'s main-actor `init` cannot be called from the nonisolated `AssetClient.init`. This is a compile error at both floors; the fix compiles. | Q-1 |
| T2-17 | minor | The app delegate's completion handler can be lost: through the lifecycle-buffer overflow, through a false "hook not wired" verdict, or because the cap ignores re-attached tasks. | R-NET-3 |
| T2-18 | minor | Two crash points: a kill during an Apple-tier staging write leaves an adoptable, truncated `.part`, which counts as an integrity strike; and the temp name of the atomic `.resume` write is unspecified, so the file is never collected. | R-INT-3, R-CLN-3 |
| T2-19 | minor | The session leaks when the backend is dropped without `shutdown()` (NSURLSession.h:247-250). F-24 contradicts R-SYN-15. | R-SYN-15 |
| T2-20 | minor | The catalog digest takes 10.75 ms at the 32 MiB cap on the pool. `.notModified` drops `removedSources`. | C2, R-APL-4 |
| T2-21 | minor | That `taskDescription` persists across relaunch is stated as fact but is unverified. The `guard`-line formatting is a coverage-only device. | C7, G4 intent |

§3 lists the areas that held, with what I tried against each.

---

## 2. Findings

Line references (`l.n`) are to `docs/design/transport.md` unless stated otherwise. "Prototype" means the drafter's `.build-probe-transport/pkg/Sources/`.

### T2-01 · critical · Download-task partials leak into the OS temp directory on every transfer that does not complete

**Design text.**
- ADR-T4 (l.656) persists the resume data in `staging/<id>.resume`, "deleted on completion, on content change and by staging GC".
- Consumer cancellation, `handle.cancel()` and the `SizeGuard` abort all call `task.cancel()` (§4.3, §4.5; prototype `ForegroundBackend.swift` `onTermination`, `SessionDelegate.swift` `didWriteData`).
- Shutdown calls `invalidateAndCancel()` (§4.1).
- store.md §6.3 l.741 says: *"This fixes D-7: nothing goes to tmp and nothing leaks."*
- SPEC R-STO-1 allows OS-owned URLSession temp files only if they are *"moved into staging/ immediately"*.

**Facts (probe `lifecycle2`).** Each scenario stalls the download after a unique byte count, so the leftover can be attributed by size. The output is in `out/lifecycle2.txt`.

| Scenario | What the design does | Partial left in the per-user temp dir |
|---|---|---|
| S-a | `cancel(byProducingResumeData:)`, then the data is dropped and the session invalidated | `CFNetworkDownload_vReiFr.tmp`, 700,001 bytes |
| S-b | plain `cancel()`: consumer cancel, `handle.cancel()`, or a SizeGuard abort. No resume data exists, so nothing in the design even knows the file exists. | `CFNetworkDownload_SfL1xq.tmp`, 700,002 bytes |
| S-c | `invalidateAndCancel()` (shutdown) | `CFNetworkDownload_Wb9Ewg.tmp`, 700,003 bytes |
| after exit | `stat` at 05:40:45, after the process ended | all three still present |

- The resume data names its partial only through `NSURLSessionResumeInfoTempFileName`, inside an `NSKeyedArchiver` archive (`out/resume-keys.txt`). That is a private format, which the design's own §5.4 argument says it may not parse (R-SEC-3).
- **Field evidence.** The user temp dir holds 752 such files, 793.9 MiB in total, all born today between 04:xx and 05:xx (`out/tmp-partials.txt`). 702 of them are exactly 1,048,576 bytes. That matches the "drop after 1 MiB" scenarios of the drafter's E-5, E-14, E-16 and E-17: every resumable failure that was not resumed left its partial behind.

**Timeline (carousel, R-CAR-3).**
1. The user swipes through a gallery of 40 MB videos. The ±2 prefetch window cancels each asset that leaves it.
2. Each cancellation calls `handle.cancel()`, then `task.cancel()`, and leaves the bytes received so far in `tmp/`.
3. After 100 swipes there are about 100 partials. They are invisible to:
   - the quota (R-CLN-4);
   - `StorageReport`'s staging bytes (R-CLN-9);
   - `purge` (R-CLN-6);
   - staging GC (R-CLN-3).
4. Other paths add more files:
   - resume data over 256 KiB is dropped (l.297);
   - the 416, authentication and integrity paths discard only `.resume`, so the partial it pointed to stays.

On iOS the app's `tmp/` is purged only opportunistically, and its size is charged to the app (cadence UNVERIFIED). Promise 3 ("the device is never filled") does not hold.

**Violates:** R-STO-1, R-CLN-3, R-CLN-4, R-CLN-9, D-7 (reopened), and H-9 in spirit (unbounded growth). **Critical** (unbounded resource growth).

**Fix (smallest that closes the leak).** Foreground asset and manifest transfers become **data tasks that stream into staging**:
- The per-task mailbox holds `let file: FileHandle` on `staging/<name>`. `NSFileHandle` is `NS_SWIFT_SENDABLE` (store.md SDK facts), so the mailbox stays immutable and `Sendable`.
- The mailbox implements only `didReceive response` (allow 200/206, else cancel) and `didReceive data`, which appends synchronously on the delegate queue. That queue is neither main nor the pool (C2), and the write goes through the sync `FileSystem` seam (R-STO-6).
- The cap uses the handle's offset as the written size.
- Resume is `Range: bytes=<staged size>-` plus `If-Range: <ETag>`. A pure validator accepts the result only on a 206 whose `Content-Range` matches; anything else truncates and takes the 200.
- Partial bytes then never leave the root. GC, the report and purge all see them.
- ADR-T4 (the key at rest inside resume data), RK-8 and T2-07 disappear.
- The "stateful" objection of §6 and §7.2 rule 5 amounts to one immutable `let`, the same pattern as the continuation.
- Background tasks keep download tasks (their partials live in the daemon's space; UNVERIFIED).

**Fallback, if download tasks are kept.** Record the leak in an ADR, and have `start()` delete `CFNetworkDownload_*.tmp` older than the process start from `FileManager.default.temporaryDirectory`, through the seam.
- That is safe, because foreground partials die with their process.
- Cross-launch resume becomes impossible. S-d shows a missing partial causes a silent restart from byte 0 (correct, but slower), so ADR-T4 loses its reason.

### T2-02 · critical · Same-name staging with overlapping producers publishes a blob whose bytes do not match its name

**Design text.**
- l.567: *"the engine single-flights per content, so two live transfers never share an id. A stale `.part` from an earlier attempt is replaced by the rename. This is safe because the bytes are content-addressed and hash-checked at publish."*
- The design nevertheless overlaps producers of one id in two places:
  - §10.5 l.829: *"`.part` and a live task for the same id → both `.adoptStaged` and `.attach`; the first verified result wins"*;
  - §10.8 l.859: a background pause is asynchronous while foreground attempt n+1 starts, and *"a verified success from any attempt satisfies the waiters"*.
- The delegate renames *before* it classifies (l.556–557), so a truncated close-delimited body sits at `staging/<id>.part` before it is reported as `integrity(.truncated)`.
- The store publishes by path (store.md D2, D6 and §2.4.2):
  - it hashes in 1 MiB units, each reopening the path, on the bulk queue;
  - it issues `F_BARRIERFSYNC` on the path;
  - it calls `renamex_np(RENAME_EXCL)` by path, on the metadata queue, where the call can wait behind an index commit of 11–21 ms.

**Timeline (§10.8 promotion).**
1. Bulk X runs in the background session (attempt 3, 95 %). The user opens X. The engine calls `bgHandle.pause()`, and the cancel is in flight over XPC.
2. Before the cancel lands, the OS finishes attempt 3. The delegate renames file A to `staging/X.part` and yields `.finished(X, 3, .staged)`.
3. A stale success satisfies the waiters, so the engine publishes. The bulk queue hashes A unit by unit, and the hash matches.
4. Foreground attempt 4 (no resume data, so from byte 0) gets a close-delimited body cut at 40,000 bytes. Its delegate renames B onto `staging/X.part` and only then reports `truncated`.
5. The store's rename unit runs: `staging/X.part → blobs/<hash(A)>`. It moves B.
6. `blobs/<hash(A)>` now holds B's 40,000 bytes. I-1 fails. The snapshot serves a truncated video, and an index rebuild (R-STO-4) would trust the blob's name.

§10.5's "both" row gives the same race: `adoptStaged(X)` hashes the old `.part` while the attached live task finishes.

**Evidence (probe `samename`, real FS calls, interleaving forced).** `blob name = 743fd190…, blob size = 40000, sha256(blob) = 433a5a67…, I-1 holds: false` (`out/samename.txt`).

**Violates:** I-1, R-STO-3, R-INT-2 (bytes published without being hashed). **Critical.**

**Fix.** Apply either change; both together are better.
1. Use per-attempt names, `<TransferID>.<epoch>-<attempt>.part|.resume` (epoch from T2-06). Names stay deterministic, C4-clean and self-describing for H-6. The reconciler then sees each attempt's file separately.
2. In the store, `publish` first claims the file with one rename to a private name (`staging/<name>.publishing`), then hashes, syncs and renames that name. No later producer can swap the inode under it. This costs one crash boundary, and a `.publishing` file found at launch is garbage. This change also closes store-1 S1-12.

### T2-03 · critical · Launch reconciliation loses work

**Design text.**
- §10.5 l.811–820 orders the launch as:
  1. `store.open()` lists staging;
  2. `reattachedTransfers()` (`getAllTasks`);
  3. manifest and plan, with *"wanted = TransferID of every entry the plan will fetch"*;
  4. *(not a separate step here)*;
  5. execute;
  6. `collectStaging(keeping: claimed)`, where *"everything not claimed in 5 is garbage"*.
- The prototype's `LiveBackgroundSessionDriver` creates the session in `init`, which happens during step 2.
- §10.6 says creating the session *"is what makes the OS deliver events"*.

**Facts.**
- A completed task is no longer outstanding, so `getAllTasks` does not list it.
- The delegate moves the file synchronously (S-4).
- NSURLSession.h:1288–1291: if the user force-quits the app, *"the system cancels all of the session's background transfers"*. Those cancellations arrive as `didCompleteWithError` on the next session creation. Whether resume data comes with them is UNVERIFIED.

**Timeline A: completed while the app was dead, the case H-6 names.**
1. Run 1 hands X (900 MB, bulk) to the background session, and the app is jetsammed. The OS finishes X.
2. Launch 2, step 1: `open()` lists staging as `{}`.
3. Step 2 creates the session. The OS delivers `didFinishDownloadingTo(X)`, the delegate writes `staging/X.part`, and `.finished(X, .staged)` is buffered in the coordinator. `getAllTasks` returns `[]`.
4. Step 4: `plan(live: [], staged: {}, wanted: {X})` plans nothing for X.
5. Step 6: `collectStaging(keeping: [])` deletes `staging/X.part`.
6. The run fetches X. Either the buffered `.staged(X)` is claimed and publication fails with ENOENT, or a fresh 900 MB download starts. Either way the work is lost.

**Timeline A′ (force quit).** Same as A, but with a `.resume` written at step 3 and deleted at step 6. The download restarts from zero.

**Timeline B (offline launch).**
1. Launch 2 happens in airplane mode. Step 3's manifest fetch fails `.offline`, and the run ends `blocked(.offline)` without a fetch plan, so `wanted = ∅`.
2. Step 4 emits `.cancel` for every live task.
3. Those were background tasks that the OS waits on until connectivity returns (S-7) and would have finished by itself. All of that in-flight work is discarded because one launch was offline.

**Timeline C (the planned test passes for the wrong reason).** `R-NET-3: a download completed while the app was dead is adopted from staging` passes if the fake driver places the file before `open()`. The fake would then encode an order that the real OS does not give.

**Violates:** H-6 ("not lose"), R-NET-3, R-CLN-3 (GC deletes owned work). **Critical:** the hard problem's core property fails in its most common case.

**Fix.**
1. **Change the order:** create the session → `getAllTasks` → list staging → reconcile. A task moves only from live to staged, never back. With the live snapshot taken first, every task appears in at least one of the two sets. If it appears in both, the "both" row applies, which is safe after T2-02.
2. `wanted` is the set of *applied-manifest* (index) entries that are not present, never the run's network plan. A live task for an applied entry that is not present is never cancelled.
3. `collectStaging` keeps every name whose TransferID is in `wanted`, plus the coordinator's unclaimed outcomes.
4. `FakeBackgroundSessionDriver` delivers its queued completions only at "session creation", so the test fails on today's order.

### T2-04 · major · Shutdown: callbacks run after invalidation, and the background session has no safe shutdown

**Design text.**
- §3.3 l.274–275: `invalidate()` means *"Shutdown (R-SYN-15): invalidateAndCancel(); the session releases its delegate."*
- The prototype's `invalidate()` is synchronous and does not wait.
- `BackgroundTransferCoordinator` is a `TransferBackend`, but `BackgroundSessionDriver` has no invalidate method.

**Facts.**
- Probe L1 (`out/lifecycle.txt`):
  - `invalidateAndCancel() RETURNED` at 20.16 ms;
  - `didCompleteWithError(−999)` at 22.61 ms;
  - `didBecomeInvalidWithError` at 22.65 ms.
- NSURLSession.h:306–308: *"When invalidating a background session, it is not safe to create another background session with the same identifier until URLSession:didBecomeInvalidWithError: has been issued."*
- `invalidateAndCancel` *"Cancels all outstanding tasks"* (:311).

**Timeline A (foreground: writes after close).**
1. The engine preempts a bulk transfer with `pause()`. Then `shutdown()` begins.
2. `backend.invalidate()` returns at once. The engine flushes, and `store.close()` releases the lock.
3. On the delegate queue, the pause callback and `didCompleteWithError` run `storeResumeData` (`staging/X.resume`), and any completion already queued runs `adoptDownload`. All of it lands in a root this client no longer owns.
4. A new `AssetClient` in the same process (purge-and-restart flows, every test that reopens) has opened the root. Its `staging/X.*` files are overwritten by the old client: T2-02's hazard, now across clients.

**Timeline B (background: work lost).** `shutdown()` with background enabled calls `coordinator.invalidate()` as documented, which runs `invalidateAndCancel()` on the background session. The OS cancels every background transfer, including a 900 MB video at 95 %.

**Timeline C (background: undefined).** To keep the OS work, `coordinator.invalidate()` does nothing. A later `AssetClient` in the same process then builds a second `LiveBackgroundSessionDriver` with the same identifier while the first session is still valid, which the header forbids.

**Violates:** R-SYN-15, R-STO-9, H-6.

**Fix.**
- `invalidate()` awaits the session's `didBecomeInvalidWithError` before `store.close()`. L1 shows it comes after every task callback, so the sink is quiet once it arrives.
- On shutdown, a background session is *detached*, not invalidated: consumption stops and the OS tasks survive.
- The session object lives in an app-lifetime `BackgroundTransferHost` that the app passes into `AssetClient`. That is not global state, and a later client reuses the host instead of building a second session.
- `finishTasksAndInvalidate()` is used only on an explicit "disable background" path.
- Delete F-24's *"recreates the backend at the next start()"* (l.1073). Under R-SYN-15, APIs fail after shutdown.

### T2-05 · major · The background backend cannot honour the synchronous handle, and the excluded driver makes untested decisions

**Design text.**
- `TransferHandle` (l.148–157) is synchronous and nonisolated. X-T1 justifies this by rejecting an unordered control path because it can lose `.pause`.
- In `BackgroundSessionDriver` (l.785–793), `startDownload` returns `Void`, and `cancel(taskIdentifier:producingResumeData:) async` and `setPriority(taskIdentifier:_:) async` look the task up through `allTasks`.
- l.776 says the driver makes *"no decisions inside"*.

**Problem 1: no synchronous path.** A background handle can reach the driver only through `Task { await coordinator… }`.
- A promotion is `setPriority` followed by `pause`; preemption is `pause` and then perhaps `cancel`. Each pair becomes two unstructured tasks with no ordering. That is exactly the hazard X-T1 rejects: sync-1 S1-06 measured inversions in 41–53 % of runs.
- Each of those tasks is unowned at shutdown (R-SYN-15).

**Problem 2: untested logic in the excluded file.** The prototype's `BackgroundSessionBackend.swift` l.59–66:
- runs `_ = await download.cancelByProducingResumeData()` **without first writing the `pause` field** into `taskDescription`. The stateless classifier (`Classifier.swift` l.151–163) therefore reports `.cancelled(.byClient)` and never `.paused`, and §10.8's promotion waits for a `.paused` that never comes;
- **discards the returned data**. Whether a background session also puts that data in the error's `userInfo` is UNVERIFIED. For an ephemeral session it does (L2: `userInfoHasResumeData=true`).

The file is coverage-excluded and the fake driver implements its own version, so no test can fail on either line.

**Fix.**
- `startDownload` returns, and `snapshot()` carries, the `URLSessionDownloadTask` itself (`Sendable`, S-1), wrapped as `BackgroundTaskRef`.
- The background handle then does what the foreground handle does, synchronously and in call order: write the pause tag, call `cancel(byProducingResumeData:)`, set `priority`.
- Probe `relay_init_fixed`: such a handle (a final class holding `let task`) typechecks clean at iOS 15 and macOS 12 with no escape.
- The driver shrinks to session creation plus passthrough. That also lowers the device-only line share (RK-6).

### T2-06 · major · Attempt numbers are per process, but tags outlive the process

**Design text.**
- `attempt` is *"engine-assigned, monotone per id"* (l.129), and it is persisted in the OS task's tag.
- The reconciler keeps *"highest attempt for that id"* and cancels *"a lower duplicate attempt"* (l.824–825).
- §10.8 ignores a stale attempt's terminal unless it is a success.
- Coordinator waiters are keyed `[TransferID: Waiter]` (l.795).
- The engine's counters live in memory.

**Timeline.**
1. Launch 2 re-attaches (X, attempt 1, from process 1). The scope excludes X for now, for example because the paywall state has not yet refreshed (R-CAR-5). The reconciler emits `.cancel(task)`, and the cancel goes out over XPC.
2. The paywall state refreshes and X is wanted again. The engine's counters started at 1 in this process, so it hands (X, attempt 1) to the background session. The new tag is identical to the old one.
3. The old task's cancellation completes as `.finished(tag(X,1), .failed(.cancelled(.byClient)))`. The coordinator routes it by TransferID, and **the new transfer's stream ends with `cancelled`**. The new OS task keeps running for nobody, and its later `.staged` sits unclaimed (its `.part` is then subject to T2-02).
4. At a later launch with two live tasks for X, "highest attempt" compares numbers from different processes. `taskIdentifier` is unique only within a session (header :690–693), so it cannot break the tie by recency either.

**Violates:** H-6 (duplicate work, misrouted terminals). **Major.**

**Fix.**
- Add a launch epoch to the tag: `ztak2 <id> <epoch>.<attempt> …`, where the epoch is the store's generation at `open()` or a counter persisted in `index.bin`. This is deterministic and C4-clean.
- Order attempts by (epoch, attempt). The engine seeds a re-attached job from the tag.
- The coordinator routes OS-originated events by task identity (the `BackgroundTaskRef` of T2-05). A handle's stream accepts only its own task's terminal.

### T2-07 · major · Unusable resume data fails with −1002, is classified `rejected`, and is never discarded

**Design text.**
- §3.4.2 l.405: −1002 maps to `rejected(.invalidURL)`.
- §7.2 rule 3 (l.700): *"A resumed task that fails before any response (unusable data) … → transient(.resumeRejected) → discardResumeData"*.
- §3.4.3: `rejected` maps to `failed(.nextRun)`.
- Staging GC keeps the `.resume` of every wanted id.

**Facts (probe `lifecycle2`, child processes, `out/lifecycle2-children.txt`).**
- `downloadTask(withResumeData:)` with 23 bytes of garbage, or with the first half of genuine resume data, completes in about 3 ms with `NSURLErrorDomain −1002` and **sends no request**.
- Resume data whose partial no longer exists (S-d) silently restarts from byte 0: no `Range` header, no error.

**Timeline.**
1. X's `.resume` becomes unusable. Possible causes: a torn write if the atomic write is not truly atomic (T2-18), an archive from before an iOS update, or background resume data handed to the foreground session (RK-8).
2. `transfer(X)` creates the task from the resume data and gets −1002. The classifier's table answers first with `rejected(.invalidURL)`, so the job becomes `failed(.nextRun)` and **the data is not discarded**.
3. Every later run gets the same −1002. GC keeps the file because it is claimed. X never downloads again, and R-INT-3's bounded backoff never applies.
4. The converse is also wrong. If rule 3 is implemented literally ("fails before any response"), an offline resume (−1009, −1004 or −1001 before any response) discards valid resume data.

**Violates:** R-NET-8, R-SYN-6, R-SYN-13. **Major.**

**Fix.** Add a pure classifier row keyed on a `resumed` flag in the tag:
- resumed, −1002, no response → `transient(.resumeRejected)`, and the delegate discards the data before it yields;
- the network family (−1009, −1004, −1001, −1005, DNS) keeps the data.

Add the two probe vectors as test inputs.

### T2-08 · major · An internal restart does not fit the stateless mailbox

**Design text.**
- §7.2 rule 3 (l.700) promises *"one immediate fresh restart inside the same `transfer()`"*, and the test plan (§16.3) has a matching test.
- In the prototype, `didCompleteWithError` ends with `defer { mailbox.continuation.finish() }`.
- `URLSessionTransferHandle` holds `let task`.
- `onTermination` captures the first task.

**Timeline.**
1. `transfer(X)` with resume data creates task T1, mailbox M and handle H with `task = T1`.
2. T1 fails `resumeRejected`. `didCompleteWithError` finishes M, so the stream ends.
3. A restart T2 needs a new stream, because M is finished. H's `pause`, `cancel` and `setPriority` still reach T1, which is dead, and `onTermination` cancels T1 as well. Promotion (R-NET-10), preemption (H-4) and cancellation (H-3) silently do nothing to T2, and T2 runs for nobody once the consumer leaves.

A mutable task reference would need a lock (no `Mutex` or `OSAllocatedUnfairLock` at iOS 15, so `@unchecked`; compare the drafter's NEG-1), or a forwarding task plus an ordered control stream. The second option is X-T1's rejected design, and it contradicts X-T10's "0 tasks".

**Fix.** Drop the internal restart.
- Report `.failed(.transient(.resumeRejected))`, after the delegate has discarded the data.
- The engine re-issues at once with `resume: .discardExisting` and attempt + 1, with no backoff (one pure row in sync §8.1).
- Rename the test to `R-NET-8: unusable resume data is discarded and the engine restarts the download without backoff`.

### T2-09 · major · A background session also defeats the size cap and the redirect limit

**Design text.**
- T-9 and ADR-T1 gate background use only on the key's redirect exposure.
- R-NET-7 is enforced in `didWriteData` (SizeGuard, §4.3, §7.1).

**Facts.**
- `didWriteData` runs in the app's process.
- While the app is suspended or dead, the daemon downloads without calling the delegate, and it follows redirects itself (S-3).
- `countOfBytesClientExpectsToReceive` is only a hint.

**Timeline.**
1. Bulk X (`byteSize` 5 MB) goes to the background session, either under `.acceptedByOwner` or from an origin that needs no key. The app is suspended.
2. The origin, or a same-origin redirect chain, streams 20 GB. The daemon writes all of it.
3. At relaunch, `didFinishDownloadingTo` renames the whole file into `staging/` (adopt first, l.556) and only then reports `sizeMismatch`.
4. The disk filled while the app could not intervene. R-NET-7's *"aborted early"* fails, and so does promise 3.
5. Separately, a same-origin chain of more than 5 hops is followed and cannot be counted: there is no URLProtocol hop property without the redirect delegate. R-NET-4's *"≤ 5 redirects"* fails.

**Fix.**
- ADR-T1 lists R-NET-7 and R-NET-4's hop limit as accepted risks of `.enabled`.
- Background eligibility also requires `expectedBytes != nil`.
- `BackgroundTaskSnapshot` gains `expectedBytes`. The pure reconciler then cancels any re-attached task whose expected or received bytes exceed the tag's `maxBytes`.
- In background mode, `didFinishDownloadingTo` reads the file size *before* the rename and leaves an oversize file to the OS.

### T2-10 · major · With background enabled, the engine is never idle-silent

**Design text.**
- l.796 has one pump task over `driver.events`, *"alive only while the background backend exists (i.e. only when enabled)"*.
- X-T10 says to report it in `EngineIntrospection`.
- SPEC R-SYN-14 (MUST): *"with nothing to do it owns no timer and no scheduled task"*.
- P-14 sets `idle_tasks_max: 0`.

**Timeline.** Background is enabled and the sync is complete, with no OS task outstanding. The pump stays suspended in `for await` for the rest of the process. Introspection reports one task, so R-SYN-14 fails, and P-14 fails in that configuration.

**Fix.**
- Start the pump on demand: when the coordinator hands a task to the OS, when the reattach step finds live tasks, or when the hook fires.
- End it when nothing is outstanding and no hook is pending.
- Probe `stream_semantics` (`out/stream_semantics.txt`) shows this works:
  - breaking out of `for await` does not terminate a stream whose value is still held;
  - a later, sequential `for await` receives the next elements (`A second loop got 3`, `got 4`);
  - `onTermination` fires only when the last reference to the stream goes away.
- The coordinator keeps the stream, and events that arrive while no pump runs stay buffered (bound: T2-17).

### T2-11 · major · Nothing defines who creates the background session at a background launch

**Design text.**
- §10.6 l.843 step (2): *"a task asks the coordinator to make sure the background session with that identifier exists"*.
- The coordinator exists only after `start()`, because the sources are built in `start()` (l.479–481).
- sync.md: `start()` also runs migration and maintenance and launches the due run.

**Timeline A (the hook fires, `start()` not called).**
1. The OS relaunches the app in the background for events. The app forwards the hook but defers `start()` to UI appearance, which is common because a background launch has no UI.
2. No coordinator exists, so the session is never created and the events stay queued.
3. The handler is never called. iOS suspends the app when its budget runs out and may throttle later background launches. The work is picked up at the next foreground launch, under T2-03.

**Timeline B (the hook calls the full `start()`).** A due sync run starts *foreground* transfers in a background window of about 30 s. They are cut off at suspension and leak partials (T2-01). If `start()` fails, for example because the lock is held by an extension (R-STO-9), the handler is never completed.

**Timeline C (the session is created before `store.open()`).** The delegate's synchronous `adoptDownload` renames into `staging/` of a root whose lock is not held and whose migration has not run. `open()` lists staging concurrently with those renames.

**Fix.**
- `handleBackgroundEvents` calls `ensureStarted(.backgroundEvents)`: `store.open()`, then session creation, with **no run and no maintenance**.
- The relay completes on every exit path: success, start failure and shutdown.
- It completes as soon as `.backgroundEventsFinished` is dequeued. Every preceding file is already in staging (S-4), and T2-03's reconciliation adopts it. Committing first only spends the background budget.

### T2-12 · major · Apple tier: version skew quarantines good content

**Design text.**
- F-30 and §11.4 l.964: when the pack and catalog disagree, *"adoption fails the hash (integrity) … R-INT-3 backoff plus one best-effort checkForUpdates(); the system's own background update eventually converges"*.
- sync.md §8.1 l.632: after 3 integrity failures the entry becomes `failed(.untilEntryChanges)` with a **persisted quarantine**, and the planner skips quarantined entries (sync.md l.292).
- AAV §1.4 (BAAssetPackManager.h:58): *"the system automatically polls for updates periodically in the background"*.
- The default refresh policy is `.oncePerAppVersion`.

**Timeline A (the catalog is newer, the design's own case).**
1. An app update ships catalog v2, with X's new checksum, in the essential pack. ZTronMedia is still v1 on the device.
2. Adoption hashes the v1 bytes, which fail against v2 three times within one run (`maxAttemptsPerRun` is 4). A quarantine keyed on X's v2 fingerprint is persisted.
3. The OS updates ZTronMedia to v2. X's entry is unchanged, so the quarantine stands. **X never downloads** until a later catalog changes its entry.

**Timeline B (the media pack is newer).** The OS updates ZTronMedia in the background between app versions. The applied catalog is not re-read, because of `.oncePerAppVersion`. Every asset not yet adopted fails three times and is quarantined until the next app version. Promise 1 fails for a whole version.

**Violates:** R-APL-4 (*"offline falls back"* assumes the catalog stays usable), promise 1. R-INT-3 is misapplied: it targets corrupt downloads (D-16), not upstream skew.

**Fix.**
- On the Apple tier, key the quarantine on (entry fingerprint, `AssetPack.version` of the source pack). `AssetPack.version` is a 26.0 API, already inside `LiveAssetPackBackend`. A pack update then lifts the quarantine.
- Classify a mismatch seen while `checkForUpdates` lists that pack in `updatingIDs` as `transient(.sourceVersionSkew)`, not integrity.
- After any Apple-tier mismatch, re-read the installed catalog. It is local and cheap. Apply it if its digest changed.

### T2-13 · major · H-7 is not solved for one on-demand media pack

**Design text.**
- §11.4 option C (l.950): release a media pack *"only when every catalog entry mapped to it is adopted"*, and residency is *"bounded by one pack size"*.
- F-32 and l.962 recommend ranking Apple-adopted assets low for eviction.
- SPEC §2.3 has a single on-demand pack, `ZTronMedia`, for all media.
- R-CAR-5 has scopes, R-MAN-6 has `onDemand` (sync skips such entries), and R-CLN-4 has a quota.

**Timeline A (scope).** The user's scope excludes paywalled content, so those ZTronMedia entries are never adopted. `packsToRelease` therefore never returns ZTronMedia. The whole catalog stays resident in the pack, and the in-scope part is resident a second time in `blobs/`, forever. `onDemand` entries cause the same.

**Timeline B (quota).** The quota is smaller than the catalog, so the adopted set never covers the pack, and the pack is never released. The device holds the pack plus up to the full budget in blobs. R-CLN-4 and R-CLN-9 count only the blobs, so the user's budget is exceeded by the size of the pack.

**Timeline C (after a release).** The pack was released, then the quota evicts X. Opening X runs `ensureAvailable(ZTronMedia)`, which re-downloads the whole pack (GBs) for one asset. Timelines A and B then keep the pack resident.

"Bounded by one pack size" therefore means bounded by the whole catalog.

**Violates:** H-7, R-APL-3 and R-CLN-10 (SHOULD: the ADR must say this), R-CLN-4, R-CLN-9, promise 3.

**Fix.**
1. The planner's rule becomes *"every entry is adopted **or** excluded by the current keep-scope or policy"*. ADR-T2 records the consequence: content that later comes into scope needs a whole-pack re-download.
2. While a pack is released, Apple-adopted assets are not evictable, or eviction releases the pack first.
3. Add `sourceHeldBytes` (installed `AssetPack.downloadSize`) to `StorageReport`, and count it toward the quota while a pack is retained.
4. `README` and `MIGRATION.md` tell publishers that per-scope media packs are what makes release effective.
5. Persist the planner's `alreadyReleased` input in `index.bin`. The design never says where it lives.

### T2-14 · major · Apple tier: awaits that may not return sit in the manifest and resolve paths

**Design text.**
- §11.2 l.915–925 awaits `try? backend.checkForUpdates()` **before** it reads the installed catalog. A missing catalog pack leads to `ensureAvailable` once.
- §11.3 l.936: `PackAvailabilityCoordinator.ensure` is single-flight per pack.
- l.942: whether cancelling `ensureLocalAvailability` stops the OS download is *"UNVERIFIED (harmless either way)"*.
- AAV §1.6: `checkForUpdates` *"waits for any downloads that it schedules to be registered"*.
- Offline behaviour of `checkForUpdates`, `assetPack(withID:)` and `ensureLocalAvailability` is undocumented. AAV §5 lists only the error types.

**Timeline A (offline catalog).**
1. The device is offline, and `fetchManifest` awaits `checkForUpdates` first.
2. If that call waits for connectivity instead of throwing (UNVERIFIED either way), the installed catalog is never read.
3. R-APL-4's *"offline falls back to the last installed catalog"* is then never reached, and the manifest single-flight blocks every run.

**Timeline B (H-3).**
1. `resolve(X)` and `resolve(Y)` share the pack. The first caller's task runs the `ensure`, and the second joins it.
2. The first caller cancels, for example on a swipe.
3. If the `ensure` runs in that caller's task, its cancellation cancels Y too. That is the same defect as sync-1 S1-08.
4. If instead `ensureLocalAvailability` ignores cancellation, a cancelled resolve cannot return until a multi-GB pack finishes (R-SYN-10).

The fact under the "harmless either way" claim, whether the await returns on cancellation, is the one that matters.

**Fix.**
- Read the installed catalog **first**.
- Run the update check best-effort in a source-owned task, and report its `removedSources` on the next fetch.
- The `ensure` runs in a coordinator-owned task. Waiters await coordinator continuations that are resumed on cancellation (`withTaskCancellationHandler`). The OS await is cancelled only when the last waiter leaves.
- The engine bounds manifest fetches with its `TimeSource` deadline (C4) and falls back to the applied manifest.

### T2-15 · major · P-11: "concurrency 5" is a 4-way bulk run

**Design text.**
- §14 l.1092: *"Two fresh clients with maxConcurrentTransfers = concurrency and 1 … ratio ≥ speedup_min"*.
- sync.md l.563: `reservedInteractiveSlots = 1`, effectively `min(this, max − 1)`. l.584: `nonUserCap = max − reserved`.
- A sync run is bulk work. At `max = 5`, it therefore runs **4** transfers.

**Numbers.** These come from my re-run of the drafter's E-2 (`out/rerun-E1-E2.txt`).

| Quantity | Value |
|---|---|
| Concurrency 1 | 3,680 ms |
| Concurrency 5 | 688 ms (5.35×) |
| Per-request latency | ≈ 17–18 ms, independent of concurrency |
| 4-way run (estimated) | ≈ 860–920 ms, a transport-only ratio of 4.0–4.3× |

- With a fixed per-run cost F on both sides, the ratio is (3.68 + F) / (0.86…0.92 + F). It stays ≥ 3 only while **F ≤ 0.46–0.55 s**; at 5-way the limit would be F ≤ 0.81 s.
- F covers the store open, the manifest fetch and apply with its durable commit, the plan, and the final coalesced commit (≤ 250 ms + 13–21 ms, from store.md's numbers). F ≈ 0.30–0.35 s, which predicts **3.2–3.4×**.
- That is a 7–13 % margin on an M3, before per-asset serial work on the store's queues: barrier sync plus a hash unit per blob.
- The benchmark would also measure a 4-way run under the name "concurrency 5".

**Fix.**
- The P-11 benchmark sets `reservedInteractiveSlots = 0`, or drives the parallel side through `ensureAvailable`, whose user lane may use every slot. Effective concurrency then equals `budgets.P-11.concurrency`, and the benchmark asserts that.
- Measure F separately in Stage 2 (RK-4).

### T2-16 · minor · The relay cannot be built by `AssetClient.init`

- The prototype has `@MainActor public final class BackgroundEventsRelay { private var pending = [:]; public init() {} }`.
- Probe `relay_init` (`out/typecheck.txt`): constructing it from a `Sendable` final class's nonisolated `init` fails at iOS 15 and at macOS 12 with `error: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context`.
- `relay_init_fixed`: with `nonisolated public init()`, exit 0 at both floors. The defaulted dictionary is accepted.

### T2-17 · minor · The completion handler can be lost

There are three ways:
1. **Buffer overflow.** The lifecycle buffer is `.bufferingOldest(4 × maxTasks + 8)`, sized from *this* process's configuration (l.574). A relaunch burst contains every task of earlier processes, and an app update may have lowered `maxTasks`. Oldest-first overflow drops the newest element, which is `.backgroundEventsFinished`, so `relay.complete` never runs.
2. **False "not wired" verdict.** §10.7 (l.853) disables background when `didFinishEvents` is processed before UIKit's call has reached `relay.accept` on main. The header (:1663–1671) only says the message follows *"an application has received"* the UIKit call; it does not order the delegate queue against main. The handler that is accepted a moment later is then never completed.
3. **The cap ignores re-attached tasks.** The engine's cap counts only tasks it handed over itself.

**Fix.**
- The relay keeps "finished identifiers", and `accept` for an identifier that has already finished completes at once.
- Size the buffer as `max(maxTasks, live tasks at reattach)`.
- Count re-attached tasks against `maxTasks`.
- "Not wired" only logs; it does not disable.

### T2-18 · minor · Crash points in the transport's own file operations

**(a) Apple-tier staging writes.**
- `writeStaged` appends 1 MiB units to `staging/<id>.part`. A kill after unit k of n leaves a truncated file under the adoptable name.
- At launch the reconciler emits `adoptStaged`, publication's size check fails, and that counts as an integrity strike (sync T9). Three kills during long adoptions quarantine the entry.
- **Fix:** write `<name>.tmp` and rename it to `.part` after the last unit, a single boundary. Launch `adoptStaged` failures never count toward R-INT-3.

**(b) The `.resume` atomic write.**
- The temp name of the "atomic write of `staging/<id>.resume`" (l.297) is unspecified. `StagingFileName(parsing:)` returns nil for it, and store §6.3 deletes only `.part` and `.resume`. A crash between the write and the rename leaves a foreign file that is never collected.
- **Fix:** use a fixed temp name, `<id>.resume.tmp`, that the parser recognises and treats as garbage.

### T2-19 · minor · The session leaks without `shutdown()`; F-24

- NSURLSession.h:247–250: the session keeps its delegate until it is invalidated, and *"your app leaks memory until it exits"*.
- Paths with no `shutdown()`:
  - `start()` failing after the source was built (the R-STO-9 lock tests);
  - an `AssetClient` released without `shutdown()` (tests, the R-CAR-6 shims);
  - the drafter's E-1c, which leaked 50 sessions.
- **Fix:** `deinit { session.invalidateAndCancel() }` in the foreground backend. The call is synchronous on a `Sendable` session.
- F-24 conflicts with R-SYN-15 (see T2-04).

### T2-20 · minor · The catalog digest runs on the pool, and `.notModified` drops removals

- Probe `catalog_digest`: a one-shot SHA-256 of 32 MiB takes **10.75 ms**, best of 7, on the M3. The realistic 3.3 MB catalog takes 1.56 ms. The prototype hashes inside an async function (`CatalogReader.fetch`), so at the R-MAN-2 cap it crosses C2's ~10 ms, and devices are slower.
  - **Fix:** compute the digest in ≤ 1 MiB units on Storage's bulk executor; `writeStaged` can return it.
- When the catalog is unchanged but `checkForUpdates` removed packs, `.notModified` carries no `removedSources`, so prune learns of the removals only from 404s.
  - **Fix:** `notModified(removedSources:)`.

### T2-21 · minor · An unverified premise and a coverage device

- **(a) Unverified premise.** l.566 says *"the OS persists [taskDescription] for background tasks across relaunch (H-6)"*. The header (:781–785) says only *"The system doesn't interpret this value"*. All of H-6 rests on this claim, so it must be marked UNVERIFIED (C7) and go first in `DEVICE-TEST-PLAN.md`. The same applies to *"getAllTasks right after session creation lists every task of the previous process"*.
- **(b) Coverage device.** §11.5 l.994 writes the `else` on the `guard` line so that line coverage counts it as executed. That is a coverage-only device (G4 in spirit). Write it normally and accept one uncovered line; the target needs only 70 %.

---

## 3. Areas attacked that held (what was tried)

1. **`Sendable` delegate and mailbox without `@unchecked`.** This holds. What I tried:
   - **The T2-05 handle variant.** I wrote a handle that holds the OS task (`relay_init_fixed`). It typechecks at iOS 15 and macOS 12 with no escape.
   - **The pause rewrite.** `taskDescription` is an atomic Objective-C property (NSURLSession.h:785: `(nullable, copy)`, no `nonatomic`). `pause()` rewriting it while the delegate queue reads it is therefore not a data race.
   - **Cancel before `resume()` (L4).** `didCompleteWithError` is still delivered, and the mailbox is deallocated right after (`Mailbox deinit`). So there is no leak through the cycle task → mailbox → continuation → `onTermination` → task. Inside `didCompleteWithError`, `task.delegate` is still the mailbox (`taskDelegateNil=false`), as §4.3 claims.
   - **Pause through `cancel(byProducingResumeData:)` (L2).** The callback runs before `didCompleteWithError`, and the error's `userInfo` carries the data. `.paused(resumable:)` can therefore be derived without state in the foreground.
2. **AsyncStream lifetime (`stream_semantics`).**
   - Termination happens only when the last reference to the stream value goes away. A handle that is dropped therefore cancels its task through `onTermination`, which is the behaviour the design wants.
   - Re-iterating sequentially works.
3. **iOS 15 and macOS 12 availability.**
   - `AsyncStream.makeStream` typechecks at iOS 15 (`out/stream_semantics.ios15.txt`).
   - `URLSession.allTasks`, `taskDescription`, `cancel(byProducingResumeData:)` and `priority` typecheck in `relay_init_fixed` at both floors.
   - I found no API in the design newer than the floor. The only compile failure is the isolation error of T2-16. I did not re-run the drafter's TC-1.
4. **P-10.** I re-ran E-1:
   - 5 TCP connections for 500 × 1 KiB at concurrency 5 with a cap of 6;
   - E-1b: 8 new connections at a cap of 8 and concurrency 16.

   P-10 holds. At `maxConcurrentTransfers ≥ 7`, the formula of §8 gives a cap of 8, equal to the budget, which leaves no margin. The benchmark should run the default 4 (cap 6).
5. **P-11 at the transport level.** I re-measured 5.35×. The engine-level risk is T2-15.
6. **Coverage.** It is feasible apart from T2-05. Every type outside the two excluded files has a macOS path:
   - pure tests;
   - the loopback server;
   - the fake driver;
   - `FakePackBackend` on the macOS 27 host, with `@available(macOS 26, *)` on each test;
   - `LiveDeviceConditionsSource` on the host, with an injected `NotificationCenter`.

   Two details:
   - A foreground session never sends `urlSessionDidFinishEvents`, so only a direct call in a test reaches it. That is acceptable as a behavioural test that asserts the yielded event.
   - The `@unknown default` arms are single uncovered lines.

   The device-only share falls if T2-05 moves the logic out of the driver.
7. **The unsafe budget for test fakes.**
   - A fake handle that records synchronous calls (`FakeTransferHandle` in TestSupport) can forward them into an `AsyncStream.Continuation`, which is `Sendable` and keeps order, instead of using a lock. That costs 0 escapes and needs no `Mutex`.
   - `FakeBackgroundSessionDriver` is in a test target, which the gate does not scan.
8. **Redirects and the key.** These are outside this lens and were not re-attacked.

---

## 4. Evidence (run in this session, `.build-probe-review-transport-2/`)

| Probe | Command (abridged) | Result | Output |
|---|---|---|---|
| `lifecycle` (L1–L4) | `swiftc -O -swift-version 5 -target arm64-apple-macos12.0 src/lifecycle.swift`; run against an in-process NWListener | **L1:** invalidate returned at 20.16 ms, callbacks at 22.61 / 22.65 ms. **L2:** `userInfoHasResumeData=true`; the callback runs before `didCompleteWithError`. **L4:** cancel before resume is delivered, and the mailbox is freed. | `out/lifecycle.txt`, `out/resume.bin`, `out/resume-keys.txt` |
| `lifecycle2` (S-a…S-f) | same flags; unique stall sizes 700,001 / 700,002 / 700,003 | Partials left for all three of S-a, S-b and S-c, still present after exit. S-d restarts silently from 0. S-e and S-f give −1002 with no request. | `out/lifecycle2.txt`, `out/lifecycle2-children.txt` |
| temp-dir census | `stat` over `CFNetworkDownload_*.tmp` in `getconf DARWIN_USER_TEMP_DIR` (read-only) | 752 files, 793.9 MiB, born 04:xx–05:xx; 702 of them are exactly 1 MiB | `out/tmp-partials.txt` |
| `samename` | `swiftc -O -swift-version 6` | I-1 holds: **false** (a 40,000-byte blob under a 3 MB hash) | `out/samename.txt` |
| `relay_init`, `relay_init_fixed` | `-typecheck -swift-version 6 -warnings-as-errors -enable-experimental-feature StrictConcurrency=complete` at `arm64-apple-ios15.0` and `arm64-apple-macos12.0` | `relay_init`: error at both floors. Fixed version: exit 0 at both. | `out/typecheck.txt` |
| `stream_semantics` | Swift 6 runtime (macOS 12 target), plus an iOS 15 typecheck | Break plus re-iterate works; `onTermination` fires only on the last drop; iOS 15 exit 0 | `out/stream_semantics.txt`, `out/stream_semantics.ios15.txt` |
| E-1 / E-2 re-run | the drafter's release `Experiments` binary, `E-1,E-2`, run directory inside my probe dir | 5 connections; 8 new at cap 8; 3,680 ms vs 688 ms = 5.35× | `out/rerun-E1-E2.txt` |
| `catalog_digest` | Swift 6, `-O` | SHA-256: 1.56 ms for 3.3 MB; 10.75 ms for 32 MiB | `out/catalog_digest.txt` |
| SDK text | `NSURLSession.h` (iPhoneOS 27.0) | :247–250 leak; :306–308 identifier reuse; :785 `taskDescription` attributes; :1288–1291 force-quit; :1663–1671 `didFinishEvents` | — |

---

## 5. Tests to add (display names cite SPEC IDs only)

| Name | Finding |
|---|---|
| `R-CLN-3: a cancelled, paused or failed foreground transfer leaves no bytes outside the store root` | T2-01; on macOS, attribute by unique size as `lifecycle2` does |
| `R-STO-3: a second producer renaming onto a staging name during publication never changes the published bytes` | T2-02 |
| `R-NET-3: a download the OS completes when the session is re-created at launch is adopted, not re-downloaded` | T2-03; the fake delivers on creation |
| `R-NET-3: launching offline cancels no live background task for an applied, missing entry` | T2-03 |
| `R-SYN-15: shutdown returns only after the session delegate's last callback and nothing is written to staging afterwards` | T2-04 |
| `R-NET-3: pausing a background transfer yields paused with resume data` | T2-05; driver logic moved into tested code |
| `R-NET-3: the terminal of a cancelled re-attached task never ends another transfer's stream` | T2-06 |
| `R-NET-8: unusable resume data (NSURLError -1002) is discarded and the download restarts` | T2-07 |
| `R-NET-8: a resumed request that fails offline keeps its resume data` | T2-07 |
| `R-NET-7: a re-attached background task over maxBytes is cancelled at launch` | T2-09 |
| `R-SYN-14: with background enabled and nothing outstanding, the engine owns no task` | T2-10 |
| `R-NET-3: handleBackgroundEvents before start opens the store, drains events, completes the handler and starts no run` | T2-11 |
| `R-APL-4: a pack update lifts an integrity quarantine caused by catalog and pack skew` | T2-12 |
| `R-CLN-10: an entry outside the keep-scope does not block the release of its pack when policy allows` | T2-13 |
| `R-APL-4: an update check that never returns does not delay the installed catalog` | T2-14 |
| `R-SYN-4: cancelling one of two resolves in the same pack leaves the other's ensure running` | T2-14 |
| `P-11` asserts that its effective transfer concurrency equals `budgets.P-11.concurrency` | T2-15 |

---

## 6. Files outside the repository

`URLSession` writes download temp files to the per-user temp directory.
- I set `TMPDIR` to a directory inside the repository. Both `NSTemporaryDirectory()` and CFNetwork still used `/var/folders/7y/…/T/` (`out/lifecycle.txt`, first line).
- CLAUDE.md allows `rm` only inside `.build*`, so **I did not delete anything there.** These files remain:

| File | Size (bytes) | Origin |
|---|---|---|
| `CFNetworkDownload_vReiFr.tmp` | 700,001 | my `lifecycle2` probe |
| `CFNetworkDownload_SfL1xq.tmp` | 700,002 | my `lifecycle2` probe |
| `CFNetworkDownload_Wb9Ewg.tmp` | 700,003 | my `lifecycle2` probe |
| `CFNetworkDownload_zA1dGN.tmp` | 700,001 | my `lifecycle2` probe |
| up to 3 files born at 05:38:17 | — | possibly my first `lifecycle` run; other agents' probes were running at the same time, so I cannot attribute them with certainty |
| 752 earlier files | 793.9 MiB in total | this team's earlier experiments |

**For the human:** once no probe is running, `rm "$(getconf DARWIN_USER_TEMP_DIR)"CFNetworkDownload_*.tmp` reclaims them.

**For the orchestrator:** a probe that uses download tasks cannot honour "nothing outside the repository". The data-task design of T2-01 would make it possible.
