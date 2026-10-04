# ZTronAssetKit — architecture

**Status.** Stage 1 contracts, contract-fix round 2 (2026-10-04). Merges the three Phase A designs (`docs/design/store.md`, `sync.md`, `transport.md`) and the six Phase B reviews (`docs/design/reviews/*.md`) into one authoritative design. Where this document and a design disagree, **this document wins**; the designs remain the detailed rationale, measurements and probe evidence. Decisions are ADR-001…045 in `DECISIONS.md`.

**Standalone package (owner directive, ADR-006).** Nothing is ever written outside this repository. `../ZTronCarouselCore` and `../ZTronCarousel` are read-only prior art. R-CAR-6's compatibility shims live in `Tests/ZTronAssetCompatibilityTests` (ADR-033).

**How to read it.** §1–§2 the package and its concurrency model; §3 every file on disk; §4–§8 the per-layer design; §9 the hard problems H-1…H-10, each with a decision and exact test names; §10 the REENTRANCY ledger; §11 every requirement and budget → target → work package → test; §12 every review finding → resolution; §13 the dispositions of the two contract-fix reviews (§13.2 is round 2); §14 coverage seams; §15 hygiene items for the human.

---

## 1. Targets, dependencies and ownership

| Target | Depends on | Contract files (Stage 1, orchestrator-owned) | Implemented by |
|---|---|---|---|
| `ZTronAssetModel` | — | `Identity/`, `Manifest/`, `Policy/`, `Scope/`, `Errors/`, `Environment/`, `Transfer/`, `Events/`, `Reports/`, `Tier/` | WP-A (manifest decoding, validation; everything else is complete) |
| `ZTronAssetStorage` | Model | `Layout/StoreLayout.swift`, `Snapshot/AssetSnapshot.swift`, `Store/{AssetStore,AssetRecord,StoreError,StoreTypes}.swift`, `Staging/StoreStagingSink.swift`, `FileSystem/LiveFileSystem.swift`, `Migration/LiveLegacyDefaults.swift` | WP-B (`FileSystem`, `Store`, `Index`, `Blobs`, `Lock`, `Snapshot`), WP-C (`Integrity`, `Cleanup`, `Eviction`, `Migration`) |
| `ZTronAssetTransport` | Model | `HTTPRemoteSource.swift`, `Session/ForegroundSession.swift`, `Policy/{PriorityAndSize,TransportSecurity}.swift`, `Classify/TransferClassifier.swift`, `Conditions/LiveDeviceConditionsSource.swift`, `Background/BackgroundSupport.swift`, `BackgroundSessionBackend.swift` | WP-D |
| `ZTronAssetAppleHosted` | Model | `PackTypes.swift`, `AppleHostedRemoteSource.swift`, `AppleHostedTier.swift`, `LiveAssetPackBackend.swift` | WP-E |
| `ZTronAssetSync` | Model, Storage | `Planning/SyncPlan.swift`, `Engine/{SyncEngine,EngineSupport,JobState}.swift`, `Refresh/RefreshDecision.swift` | WP-F |
| `ZTronAssetKit` | all above | `Facade/`, `Mirror/`, `Prefetch/`, `Fallback/`, `Composition/`, `Observability/`, `Memory/` | WP-G |
| `ZTronAssetTestSupport` | Model, Storage | every file (fake interfaces; `ManualTimeSource`, `InlineBlockingExecutor`, `SteppedBlockingExecutor`, `ScriptedSnapshotSink`, `SeededRandom`, `FakeDeviceConditionsSource`, `FakeMemoryPressureSource`, `FakeLegacyDefaults`, `RecordingLogTap`, `FakeTransferHandle`, `FakeAppVersionSource`, `FakeRemoteSourceFactory` with `StagingAttachable` are complete; ADR-045) | WP-H |
| Test targets | — | one per production target, `ZTronAssetKitBenchmarks`, `ZTronAssetCompatibilityTests` (R-CAR-6, ADR-033) | the owning WP |

What "contract" means here: every public and package type, protocol and signature is fixed; small pure functions whose semantics the design pins exactly are implemented and tested now (tier selection, layout and blob-name parsing, snapshot lookup, error mappings, transition table, refresh decision, backoff, size guard, priority table, security-policy check, pack release planner, prefetch window, candidate extensions, mirror install/ack, prefetch-handle release ordering, the purgeable-cache relay, `AssetLog`). Everything else is a `fatalError("WP-x: … not implemented")` stub that names its owner. A work package may add internal types freely; changing a contract signature is an orchestrator change (CLAUDE.md P1).

Only the composition root (`ZTronAssetKit/Composition/LiveEnvironment.swift`) names live conformers. Sync talks to Transport and AppleHosted only through Model protocols (`RemoteSource`, `TransferHandle`, `StagingSink`).

## 2. Concurrency model and environment

- **Actors hold state.** `AssetStore` (Storage) and `SyncEngine` (Sync) are actors. `AssetClient` is a `Sendable` final class with immutable stored properties. `SnapshotMirror`, `PrefetchWindowController` and `BackgroundEventsRelay` are `@MainActor` classes with `nonisolated init`, so the nonisolated `AssetClient.init` creates them (transport-2 T2-16).
- **One environment value** (SPEC §4.2, ADR-038): `AssetEnvironment` (Model) carries `FileSystem`, two `BlockingExecutor`s (metadata, bulk), `TimeSource`, `RandomSource`, `DeviceConditionsSource`, `RemoteSourceFactory`, `AppVersionSource`, `LegacyDefaults`, optional `MemoryPressureSource` and `LogTap`. `.live()` is built in the facade, performs no I/O (P-12) and builds fresh conformers per call (ADR-038).
- **Blocking work** (ADR-003 as fixed by ADR-038): `BlockingExecutor.run(_:)` takes a bounded, non-throwing `@Sendable` unit; `run(throwing:)` rethrows typed errors through `Result`. Units: one rename, one ≤ 1 MiB read plus hash update, one index commit, 64 unlinks, one listing. Live: `DispatchBlockingExecutor` (serial queue, `autoreleaseFrequency: .workItem`); tests: `InlineBlockingExecutor`, and `SteppedBlockingExecutor` to hold a unit at a known point (H-5). The live conformers outside the store run their blocking first reads in one unit too: the bundle enumeration (`AssetFallbackChain.prepare`) and `Info.plist` (`LiveAppVersionSource`) (ADR-038).
- **Time** (H-8): `TimeSource` has a wall clock (`now`, persisted stamps and LRU only), a monotonic clock (`monotonicNow`, every in-process deadline), an awake clock (`uptimeNow`, deletion grace only, ADR-017) and `sleep(until:)`. Tests use `ManualTimeSource`; nothing ever sleeps for real except the P-11 benchmark's loopback latency.
- **Randomness** (ADR-024): one seed; every draw is keyed by what is drawn.
- **Tasks.** The store owns no task (ADR-022). The engine owns: one alarm (iff its deadline heap is non-empty), one conditions watcher (iff work exists), one driver per transfer in flight, at most one run, one task per store-touching entry point (ADR-039), and one memory-pressure observer (iff a live `PurgeableCache` is registered, ADR-044). Every owned task is keyed by a unique spawn id. The foreground transport owns none; the background coordinator owns one pump only while a background transfer is outstanding (transport-2 T2-10).
- **Unsafe budget** (C1, R-ENV-4): **0 of 3** escapes are used in all of `Sources/`, `ZTronAssetTestSupport` included (`UNSAFE escapes found=0`). Test fakes with synchronous APIs use `Synchronization.Mutex` behind `@available(macOS 15.0, iOS 18.0, *)`; tests that use them carry `@available(macOS 15.0, *)` on each `@Test` function, never on a `@Suite` (ADR-014, verified). Memory probes for P-6/P-7 live in `Tests/ZTronAssetKitBenchmarks` (ADR-040). No planned escape exists; if a WP believes it needs one, it reports to the orchestrator first.
- **Typed throws** (ADR-004, ADR-042): public async APIs throw `AssetError` (`.shutDown` after shutdown, R-SYN-15); `withAsset` stays untyped; internal layers use `ManifestError`, `TransferError`, `StoreError`, `StagingError`, `PackError`, `FileSystemError`.

## 3. On-disk layout (R-STO-1, ADR-001, ADR-012, ADR-013)

The root is `<base>/ZTronAssetKit/v1/`, where `<base>` is `Library/Application Support` (default, excluded from backup, protection `completeUntilFirstUserAuthentication`), `Library/Caches`, or a custom directory (`StorageLocation`). Every URL is built by `StoreLayout`; no manifest-supplied text is ever a path component (R-SEC-2). This is every file the module creates:

| Path (relative to `<base>`) | Kind | Writer | Content and format | Write protocol | Read by | Removed by |
|---|---|---|---|---|---|---|
| `ZTronAssetKit/` | dir | `open()` | container | `createDirectory`, then barrier-sync of `<base>` (store-1 S1-02) | — | never by the module |
| `ZTronAssetKit/v1/` | dir | `open()` | the root; backup-excluded, protected | created, attributes applied and re-checked at every open (R-STO-8) | — | never |
| `v1/store.lock` | file | `open()` | empty; `O_EXLOCK` held for the store's lifetime; token records `(st_dev, st_ino)` | `acquireExclusiveLock` | kernel; identity re-checked before every commit (store-1 S1-08) | never |
| `v1/index.bin` | file | commit unit | the current generation: 64-byte header (magic `ZTAKIDX\0`, `schemaVersion` 1, flags, `generation`, `bodyLength` ≤ 64 MiB, `writtenAtMillis`, `storeID`, launch epoch, section count), sections STAMPS / STRINGS / RECORDS / DOOMED (with `DoomReason`), SHA-256 trailer (store.md §2.3 + ADR-012) | temp → sync → rename `bin→prev` → rename `tmp→bin` → root sync (§4.1) | load rule (§4.2) | replaced by the next commit |
| `v1/index.prev` | file | commit unit | the previous generation, same format | rename of `index.bin` | load rule (fallback) | replaced; removed on ENOSPC at commit to make room (ADR-015) |
| `v1/index.tmp` | file | commit unit | the generation being committed | `write(.truncate)` + barrier (ordered) or full sync (durable) | load rule (may win: synced before any rename) | renamed to `index.bin`, or removed when invalid |
| `v1/blobs/` | dir | `open()` | content-addressed blobs | created; dirtied at every open (ADR-015) | — | never |
| `v1/blobs/<aa>/` | dir | publish, adoption | fan-out by the first two hex digits | created on demand; barrier-synced before the commit that references a blob in it | — | never |
| `v1/blobs/<aa>/<64 hex>.<ext>` | file | publish, legacy and Apple adoption | the asset bytes; name = SHA-256 of the bytes (I-1); `<ext>` re-validated `[a-z0-9]{1,8}` | claim → size → hash → sidecar removed → barrier → `rename(.exclusive)` (§4.3); a `corrupt` name is replaced (ADR-018) | readers via URL; launch reconciliation lists names only | the reaper, after ack + awake-clock grace + commit + no lease (§4.4) |
| `v1/staging/` | dir | `open()` | in-progress transfers | created | — | never |
| `v1/staging/<TransferID>.<epoch>-<seq>.part` | file | transport (data-task appends, ADR-019; background download moves) | partial or complete download bytes | `createPartial` / `appendPartial` / `continuePartial` (exclusive) / `adoptDownload` (exclusive) | `publish` (after claiming it), resume | staging GC (§4.5), `discard` |
| `…​.parttmp` | file | Apple-tier writer | a `.part` being written by a renaming writer | write then exclusive rename to `.part` | — | staging GC |
| `…​.resume` | file | transport | `ResumeSidecar` JSON: name, `If-Range` validator, received and expected bytes; **no URL, header or key** | write `.resumetmp`, rename | resume planning, launch reconciliation | removed by `publish` before its barrier (store-2 S2-05), by GC, or when a complete `.part` of the same transfer exists |
| `…​.resumetmp` | file | transport | the sidecar's atomic-write temporary | — | — | staging GC |
| `…​.verifying` | file | `publish` | a `.part` claimed by the store: no producer writes this name (store-1 S1-12) | exclusive rename of `.part` | `publish` | renamed into `blobs/`, or removed on failure / at launch |

**Nothing else is written.** No `UserDefaults` (the legacy key is read once and removed after a durable "done" commit, ADR-029), no `tmp` (foreground transfers are data tasks, ADR-019), no URL cache (ephemeral, cache-less session). OS-owned files: a background download's temp file is moved into staging before the delegate returns (possibly after the store closed: it is then reconciled at the next launch, ADR-039); Apple packs are the OS's (their bytes reach `StorageReport.sourceCopyBytes` through `RemoteSource.sourceCopyBytes()`, ADR-027).

**Names.** `TransferID` is `c-<sha256>` (content with a checksum), `l-<sha256(id ‖ 0x00 ‖ remotePath)>` (checksum-less, ADR-034) or `m-manifest`. `epoch` is the store's launch epoch (the generation allocated at `open()`; persisted and strictly increasing across launches), `seq` the engine's start counter; so attempt tokens order across relaunches (transport-2 T2-06) and two starts never share a name. Anything in `staging/` that does not parse is foreign and collected; anything in `blobs/` that does not parse as `<64 lowercase hex>.<[a-z0-9]{1,8}>` in the right fan-out is foreign and deleted at launch, never adopted.

## 4. Storage (H-1, H-2, H-10; WP-B, WP-C)

store.md §1–§7 is the detailed design. Amendments from the reviews are normative and listed here.

### 4.1 Commit protocol (R-STO-4, I-5; ADR-015)
1. Barrier-sync every fan-out that received or **adopted** a blob since the last commit, then `blobs/` if dirty (it is dirty after every open).
2. `write(index.tmp, .truncate)`.
3. `synchronizeFile(index.tmp, .barrier)` for an ordered commit, `.full` for a durable one.
4. `rename(index.bin → index.prev, .replacing)`.
5. `rename(index.tmp → index.bin, .replacing)`.
6. `synchronizeDirectory(root, .barrier)` (ordered) or `.full` plus `ZTronAssetKit` and `<base>` (durable).

The generation is allocated **when the state is captured**, before the unit is submitted, and is incremented for every attempt (store-1 S1-16, store-2 S2-13). DOOMED is derived from the blob table at capture (ADR-018). Commits are coalesced to ≤ 4/s; the last commit of a run flushes as soon as the window allows (P-11 tail, transport RK-4). On ENOSPC at step 2: remove `index.tmp` and `index.prev`, retry once; the in-memory state stays authoritative and deletions that need the newer generation wait.

### 4.2 Load rule
Read `index.bin`, `index.tmp`, `index.prev` in ≤ 1 MiB units; validate size (`64 + bodyLength + 32` exactly, after checking `bodyLength ≤ 64 MiB`), magic, schema and trailer; never trap (store-1 S1-04): `nextGeneration = 1 + max(generation over headers that parsed)` computed with `addingReportingOverflow`, an overflow or a generation ≥ 2⁶² makes that header malformed. Choose the newest valid generation; `degraded` when none is valid, when `index.bin` exists but is invalid, or when any candidate has a newer schema. In degraded mode orphans **and DOOMED keys** are protected until the next `apply` plus adoption (store-1 S1-11). At load, `DOOMED := DOOMED \ referenced` and the repair is counted.

### 4.3 Publication (R-STO-3, R-INT-1/2/6)
`publish(staged, binding: ids, expecting: identity)`: (1) every id's record still has `identity`, else `.superseded` before any hashing (sync.md X-3); (2) claim: `rename(.part → .verifying, .exclusive)`; (3) size check against `byteSize` and the cap, without hashing; (4) streaming SHA-256 in ≤ 1 MiB units on the bulk executor, cancellation-aware; (5) compare with the checksum (or record the digest for checksum-less entries, R-INT-5/6); (6) `removeItem(.resume)`; (7) `acquireReference(key)` (ADR-018: awaits an in-flight publication or deletion of the same key, rescues `doomed(.unreferenced)`, dedupes onto `live`); (8) barrier `.verifying`, create the fan-out, `rename(.verifying → blob, .exclusive)` (EEXIST: compare sizes; a `corrupt` key is replaced with `.replacing`); (9) after every await re-validate the records' identity: on a change throw `.superseded`, never return a URL (store-2 S2-15); (10) records `present`, integrity history cleared, `markDirty(.soon)`, snapshot published. Checksum-less and rescue publishes are committed before they return (store-1 S1-05). Integrity failures delete the staged bytes, count a metric and persist R-INT-3 bookkeeping (ADR-032).

### 4.4 Deletion and the I-3 protocol (H-2; ADR-016, ADR-017, ADR-018, ADR-022)
`deletable(k)` ⇔ `doomed(k)` ∧ an acknowledged snapshot **of this epoch** without `k` exists ∧ `uptimeNow ≥ ackUptime + deletionGrace` ∧ the generation that dropped `k` is committed ∧ no lease ∧ no publication of `k` in flight ∧ a fresh no-op install after the deadline was acknowledged. Only time-blocked keys contribute to `nextDeadline()`; lease release, acknowledgement and commit completion re-arm the engine's alarm. Unlinks run in units of 64 in sorted order. A failed unlink keeps the key doomed with backoff. Launch DOOMED keys (from a previous instance) enter the blob table as doomed and wait for the first ack plus grace (store-2 S2-07). Doom reasons `purged` and `corrupt` are never re-adopted or rescued.

### 4.5 Launch (store.md §2.6 as amended; ADR-028, ADR-029)
`open()`: resolve the base and create `ZTronAssetKit` and `v1` (syncing `<base>` after creating the container) → lock → apply attributes, create `blobs/`, `staging/` → load (§4.2) → list blobs (256 units) → **list nothing in staging yet** → reconcile records: a present record whose blob is missing or the wrong size becomes `needsHeal` and the bad name is doomed `corrupt`; an unreferenced, non-doomed blob is bound to every record that expects it and is `absent(neverFetched|evicted|healing)`, `needsHeal` or stale (adoption dirties the fan-out) → OS-purge detection resets the stamp (R-CLN-7) → legacy phase 1 → root barrier → commit if anything changed → publish the first snapshot. Staging is listed only by the engine's launch reconciliation (§6.4), and collected after it.

### 4.6 Cleanup and space (R-CLN-*)
Prune, orphan GC (mark and sweep after a full listing, `orphanGrace`), staging GC (`stagingClaimGrace`, `stagingMaxAge`), quota eviction (entries outside the retention scope first, then LRU; ties larger first, then hash; never essential, pinned, leased or accessed within `max(minimumResidency, deletionGrace)`; `available + pendingReclaim` used in every budget decision, store-2 S2-06), purge (stamp cleared in the same commit, `purgeEpoch` bumped; returns after the selection is reaped, rescued or deferred by a lease), quarantine (`corrupt` doom), deep verification (cursor by `verifiedAt`). Every operation is idempotent and cancellation-safe (store.md §6.9).

### 4.6a Retention scope and the adoption report (H-7; ADR-027)
`setRetentionScope(_:)` (in-memory, any phase, starts as `.all`, pushed by the engine after `open()` and on every app change) orders eviction and defines `AdoptionReport.excludedRemotePaths`; it deletes and fetches nothing. `adoptionReport()` is atomic: it captures the applied manifest's remote paths, the present-at-current-content records and the exclusions synchronously, commits the holding generation **durably**, and returns only what it captured (REENTRANCY R15), so a pack is released only for adoptions that survive power loss (store-1 S1-10).

### 4.7 Legacy migration (H-10; ADR-029)
Phase 1 inside `open()` (plan from `manifest.json` and `local-checksums.json`, driven by a **non-following** recursive listing; entries matched against listed regular files, store-2 S2-10; duplicates keep the first; one ordered commit). Phase 2 after `open()` in engine-owned batches (`migrateLegacy(maxFiles:)`), with adopt-on-demand for a resolve or lease (`adoptLegacyNow`). Phase 3 durable commit; phase 4 tree removal, then the key. The stamp migrates only when every legacy entry was adopted.

## 5. Snapshot and the main-actor mirror (R-STO-13; ADR-016)

`AssetSnapshot` (`package`) holds only present assets with precomputed `AssetLocation`s; lookup is one dictionary probe plus a case-insensitive extension match. `SnapshotMirror.install` swaps only for a greater `SnapshotKey(epoch, version)` and returns `InstallAck { installed, accesses, retired }`; the store acknowledges only its own epoch; `retired` lets the store release the replaced snapshot off the main actor (sync-2 S2-12); `reset()` is explicit (shutdown). Bulk-work snapshot installs are rate-limited to ≤ 10 Hz (`SyncTuning.snapshotInstallInterval`); user-initiated commits install at once. The engine never hands out a URL derived from a snapshot copy (store-2 S2-12).

## 6. Transport and the Apple tier (WP-D, WP-E)

### 6.1 Sessions (R-NET-2, ADR-019)
One ephemeral, cache-less foreground session per `HTTPRemoteSource`, built in `start()`; `httpMaximumConnectionsPerHost` clamped 1…8 (P-10); no `httpAdditionalHeaders`; `waitsForConnectivity = false`; request timeout on the session **and** every request. Data tasks; the stateless `SessionDelegate` (immutable `let`s, `Sendable` without escapes) appends each chunk into staging through `StagingSink` on the delegate queue; per-task routing through the task's `TaskMailbox`. `invalidate()` returns after the foreground delegate's last callback (transport-2 T2-04), which is what keeps staging writes from landing after `store.close()`: `StagingSink` is immutable and promises nothing after close (ADR-039); `deinit` invalidates too (T2-19).

### 6.2 Redirects and the key (R-NET-4, R-SEC-1)
`RedirectPolicy.decide`: refuse past 5 hops, refuse non-HTTPS (plain HTTP only for loopback under the package-only `loopbackTesting` policy), refuse hosts outside the allow-list; keep the key only while every hop stays on the original origin, never re-add it. The key is attached per request by the request factory after `TransportSecurityPolicy.check`. A 403 after we withheld the key is `rejected(.keyWithheldOnRedirect)` (transport-1 TR1-6). No `URLRequest`, `URLResponse`, `URLError` or `NSError` is stored in any error, event, report or log; only `ResponseFacts`.

### 6.3 Manifest, size, resume (R-NET-5/7/8)
Conditional GET with `If-None-Match`, 304 → `notModified`, never a cache answer; the 32 MiB cap enforced while streaming. `SizeGuard.verdict` aborts on written > cap, announced > cap + slack, or written > `byteSize` (TR1-8); the staged size is compared with `byteSize`, never `Content-Length`. Resume: `Range: bytes=<offset>-` + `If-Range: <strong ETag | Last-Modified>` from our sidecar; only a 206 whose `Content-Range` starts at the offset is appended, anything else restarts from zero; −1002/416/validator mismatch → `transient(.resumeRejected)` and the next attempt starts fresh (TR1-4, T2-07, T2-08). Checksum-less transfers are never resumed (TR1-3). Resumed bytes are always hashed.

### 6.4 Background session and launch reconciliation (R-NET-3, H-6; ADR-026, ADR-028)
Off by default; bulk and key-free only unless the owner accepts redirect exposure. The device-only driver (`BackgroundSessionBackend.swift`, ≤ 250 lines, excluded from coverage) is decision-free; the coordinator, tag codec, reconciler and relay are tested on macOS with `FakeBackgroundSessionDriver`. Launch order: open → source → `activate()` → `reattachedTransfers()` → `stagingInventory()` → `TransferReconciler.plan(live:staged:wanted:)` (`wanted` = applied entries not present) → execute → `collectStaging(keeping:)`. `AssetClient.handleBackgroundEvents` stores UIKit's handler in the relay and completes it after the engine reports the session's preceding events staged (at once after shutdown). Shutdown releases the background session without waiting for the OS's tasks (`finishTasksAndInvalidate`); a file the OS moves into staging after close is an ordinary staged file for the next launch's reconciliation (ADR-039).

### 6.5 Reachability and power (R-NET-9)
`LiveDeviceConditionsSource`: an actor owns `NWPathMonitor` and the notification tokens; one serial queue feeds full snapshots into a `.bufferingNewest(1)` stream; termination stops observation. `ConditionsMapping` is pure (implemented, tested).

### 6.6 Apple tier (R-APL-*, H-7; ADR-027)
Everything runs against `PackBackend`; only `LiveAssetPackBackend.swift` (≤ 250 lines, excluded) imports BackgroundAssets, using the iOS 26.0 surface. Catalog read from the essential pack before any update check is awaited (T2-14); digest `"sha256:<hex>"` is the pseudo-ETag; `removedSources` reported even on `notModified` (T2-20). Assets are streamed into staging and published through the hash path; skew is `transient(.sourceVersionSkew)` (T2-12). `PackReleasePlanner` (implemented) releases a media pack only when every catalog entry in it is adopted in a durably committed generation or excluded by the keep-scope; its inputs come from `AssetStore.adoptionReport()` (§4.6a), the keep-scope being the client's retention scope. `sourceCopyBytes()` sums `PackBackend.installedBytes` of adopted, unreleased packs for `StorageReport` (WP-E). **The package's single `#available`** (all of `Sources/`, `ZTronAssetTestSupport` included, ADR-014) is in `AppleHostedTier.resolve`, which feeds `TierSelection.select` (pure, Model, tested over all 16 inputs).

### 6.7 Loopback server (ADR-011)
An actor over `NWListener` on `127.0.0.1`; connection drops in gating tests use FIN (`closeAfter`), never RST (non-deterministic, transport.md E-16); mid-flight states use `stallAfter` + `stop()`; `LiveLoopbackDelay` sleeps only in the P-11 benchmark.

## 7. Sync engine (WP-F)

sync.md is the detailed design; these sections are normative, including every amendment. The defaults referred to as "ARCHITECTURE §7" in `SyncTuning` are those of sync.md §7.1 with the review amendments recorded in ADR-036.

### 7.1 Per-asset state machine (R-SYN-2)

`absent` and `present` are derived from the store; only outstanding work has a job (keyed by `TransferID`, ADR-020). Legal transitions are exactly `JobStateKind.allows(from:to:)` (implemented and tested):

| From | To | Events (sync.md §5.2 rows) |
|---|---|---|
| — (absent) | queued | interest added for an applied or point-admitted entry (T1); quarantined → no job (T2) |
| queued | downloading | dispatched by `pump()` (T3) |
| queued | blocked | lane gated by policy, breaker, throttle or space (T4) |
| downloading | verifying | `.staged` (T5) |
| downloading | failed | `.failed` with a retry disposition (T6) |
| downloading | blocked | offline / space / policy pause (T6, T16 + policy) |
| downloading | queued | `.paused` after preemption, or content superseded (T7, T22) |
| verifying | committing | store verification passed (T8) |
| verifying | failed | integrity failure (T9) |
| verifying | queued | content superseded with interests left (T22) |
| committing | failed | store failure |
| committing | queued | `.superseded` with interests left (T11) |
| failed | queued | alarm, satisfied-path edge, user request (T18–T20) |
| failed | failed | disposition re-armed |
| blocked | queued | the gate admits (T17) |
| blocked | blocked | the reason changed |
| any | — (job removed) | committed → present (T10); last interest left and not verifying/committing (T12, T13); verifying/committing finished with no interest (sync-1 S1-01); pruned (T21); shutdown (T23) |

Removal goes through one synchronous funnel (`retire`): a job with no interest that is not verifying or committing is removed and its driver cancelled; out of verifying/committing with no interest it is removed instead of retried (sync-1 S1-01). Re-attached background transfers get a system interest the first run claims or releases. An illegal transition is a debug assertion and a `MetricsSnapshot.illegalTransitions` increment; every engine test asserts 0. A transfer stream that ends without a terminal element fails the job with `transient(.incompleteCallbackSequence)` (sync-1 S1-11).

### 7.2 Single-flight, interests and continuations (R-SYN-4, R-CAR-4, H-3)

Interests (`InterestToken`) are waiters (`resolve`), groups (prefetch handles, `ensureAvailable`), runs and system interests. A job's lane is the maximum of its interests; withdrawing the highest demotes it (and re-runs admission, sync-1 S1-07). **Every continuation kind** — waiters, groups, runs, `start` and `sync` joiners, `waitUntil` — lives in a token-keyed table and is resumed only through `removeValue`; every table is settled at registration (a run with zero fetches completes at once, sync-1 S1-02), on each transition, on withdrawal, on purge (the active run ends `failed(.cancelled)`) and at shutdown. A caller's cancellation hops to the actor and withdraws only its token. Shared work (start, manifest fetch, runs, store-touching entry points) runs in engine-owned tasks, never in a caller's task (ADR-039).

### 7.3 Planner and stable order (R-SYN-1, R-SYN-8, P-4)

`SyncPlanner.plan(manifest:snapshot:scope:policy:freeSpace:)` is pure: one pass over the manifest (O(1) record probes), one pass over the applied manifest for prunes, a sort of the fetches only. **Fetch order is `(AssetPolicy.rank, manifestIndex)`**: essential before standard before on-demand, then publisher order (the prior art's serial order); relocations, reuses and skips in manifest order; prunes in applied-manifest order. No output depends on dictionary or set iteration. Reconciliation (relocations, reuses, prunes, the adopted manifest) is committed by `AssetStore.apply` before any fetch is enqueued (R-SYN-8); a seeded property test pins `ApplyReport == plan.reconcile` (ADR-030). Planned fetches become jobs only within the pipeline plus `runLookahead` (sync-1 S1-15); the rest stay a cursor into the plan.

### 7.4 Lanes, dispatch and promotion (R-SYN-3, H-4)

Three lanes, `userInitiated` (split into `single` before `batch`) > `prefetch` > `bulk`; one slot reserved for user work; bulk ages ahead of prefetch after `bulkAging`. The pipeline cap gates **non-user lanes only** (sync-2 S2-10). Promotion of a running transfer is `handle.setPriority` inside the synchronous `join` (ADR-021); a queued job jumps to the user queue; when no slot is free a lower-lane transfer is preempted with `pause()` (never the breaker's probe). `pump()` loops after marking a victim (sync-1 S1-16). Priority changes are issued before any other start in the same actor turn (sync-1 S1-06). `interactiveConcurrencyAtCritical` caps user work at `.critical` thermal state.

### 7.5 Priority → URLSession (R-NET-10)

| Engine lane | Engine scheduling | `URLSessionTask.priority` | Session |
|---|---|---|---|
| `userInitiated` | first; reserved slot; may preempt a lower lane | `highPriority` = **0.75** | foreground |
| `prefetch` | second | `defaultPriority` = **0.5** | foreground |
| `bulk` | last; ages ahead of prefetch after 30 s | `lowPriority` = **0.25** | foreground; background only under ADR-026 |

Implemented as `AssetPriority.urlSessionTaskPriority` and tested. The priority is a hint; H-4 is guaranteed by the engine's lanes. Effective in-flight transfers per origin stay ≤ `httpMaximumConnectionsPerHost` (≤ 8).

### 7.6 `TransferError` → engine action → `AssetError` (R-NET-6, R-CAR-7)

| `TransferError` | Engine action | Breaker input | `AssetError` to waiters |
|---|---|---|---|
| `offline(reason)` | `failed(.whenOnline)`; re-queued on a satisfied-path edge (R-SYN-13); counts as blocked for run settling | none (a probe returns to half-open) | `.offline` |
| `transient(.timedOut / .connectionLost / .cannotConnect / .dnsFailure / .secureConnectionFailed / .badServerResponse / .unknown, nil)` | `failed(.at(backoff))`, early re-queue on a path edge | none | `.serverUnavailable(retryAfter: nil)` |
| `transient(.serverError, retryAfter)` | backoff (Retry-After as lower bound) | 5xx window | `.serverUnavailable(retryAfter:)` |
| `transient(.throttled, retryAfter)` | origin throttle until the clamped deadline; jobs `blocked(.throttled)`; a throttle-only blocked run sets a pending run (sync-2 S2-03) | none | `.serverUnavailable(retryAfter:)` |
| `transient(.resumeRejected)` | discard partial and sidecar; immediate fresh attempt (no backoff) | none | — (retried) |
| `transient(.authenticationChallenge)` | backoff; heals on a path change (proxy, captive portal) | none | `.serverUnavailable(retryAfter: nil)` |
| `transient(.sourceVersionSkew)` | backoff + one best-effort update check (Apple tier) | none | `.serverUnavailable(retryAfter: nil)` |
| `transient(.backgroundSessionUnavailable)` | retry in the foreground; background disabled for the process | none | — (retried) |
| `transient(.localIO)` / `.incompleteCallbackSequence` | backoff | none | `.serverUnavailable(retryAfter: nil)` |
| `permanentMissing` | `failed(.untilEntryChanges)` (persisted, store) | none | `.notFound` |
| `authentication(.forbiddenAmbiguous(e))`, asset | `failed(.nextRun)`; auth-suspect counter by distinct asset; **never quarantined** (sync-2 S2-05) | auth (3 distinct assets) | `.authRejected(.ambiguous)` |
| `authentication(.forbiddenAmbiguous(e))`, manifest, `e.hint == .keyRejectedLikely` | run ends `blocked(.circuitOpen)` | auth opens at once (an engine inference, never a transport verdict) | `.authRejected(.confirmed)` |
| `integrity(…)` (transport) / `StoreError.integrity` | R-INT-3 bookkeeping in the store; backoff, then `failed(.untilEntryChanges)` after `maxIntegrityAttempts` | none | `.integrityFailure` |
| `insufficientSpace` | `blocked(.awaitingSpace)` if the store has pending reclaim (woken by `runDueWork`), else `blocked(.insufficientSpace)` | none | `.insufficientSpace(required:available:)` with the store's figures |
| `rejected(violation)` | `failed(.nextRun)`; counted by violation | none | `.serverUnavailable(retryAfter: nil)` |
| `cancelled(.byClient)` | not a failure (T13 or T7) | probe → half-open | `.cancelled` |
| `cancelled(.bySystem)` | re-queued by the next run | probe → half-open | — |

`TransferError.failureClass` and `assetError(now:)` (Model) and `StoreError.assetError` (Storage) implement the right-hand columns and are tested; the engine overrides the two inferences noted (confirmed auth, measured free space).

### 7.7 Circuit breaker (R-SYN-5; ADR-031)

Per origin (`RemoteSource.originID`), a pure value (`CircuitBreaker`) owned by the engine. **Auth:** opens at once on a manifest 403 whose hint is key-rejected; ambiguous object 403s open it after 3 distinct assets with no intervening object success; cooldown 300 s doubling to 3,600 s with keyed jitter. **5xx:** sliding window of 20 outcomes, opens at ≥ 5 samples and ≥ 50 % 5xx; cooldown 30 s doubling to 600 s. **Half-open:** exactly one probe; success closes and resets trips (a cached manifest 304 never counts, sync-2 S2-21); a same-cause failure re-opens with `trips + 1`; **any other exit** (different cause, offline, cancelled, paused, superseded, shutdown) returns to `halfOpen(probe: nil)`; a probe silent for `probeWatchdog` (60 s) is abandoned. While open, `resolve` fails fast and runs end `blocked(.circuitOpen)` with a pending run on close.

### 7.8 Timers and idle silence (R-SYN-14, P-14, H-8; ADR-022)

Deadlines are data in one min-heap `(deadline, seq, reason)`: retries, throttle end, breaker cooldown and probe watchdog, store deadlines (`AssetStore.nextDeadline()`), pending-run debounce. One alarm task exists iff the heap is non-empty; firing drains due entries in `(deadline, seq)` order, re-validating each against epochs, then calls `store.runDueWork()` if a store deadline was due and re-arms. Stale entries are removed eagerly on withdrawal and settle (sync-1 S1-10). The conditions watcher exists iff work exists and is cancelled by the engine when it goes idle. **Idle** = no job, no run, no pending run, empty heap ⇒ `EngineIntrospection.isIdleSilent`, plus the environment census (`ManualTimeSource.pendingSleepers == 0`, `FakeRemoteSource.activeTransfers == 0`, `FakeDeviceConditionsSource.activeObservers == 0`, awaited with `waitForObservers(equalTo:)`). A registered `PurgeableCache` keeps one memory-pressure observer, which is work: R-SYN-14 and P-14 are measured with none registered.

### 7.9 Events and backpressure (R-SYN-12, H-9; ADR-023)

Pull-based per-subscriber queues behind `AsyncStream(unfolding:onCancel:)`; registration on first pull; released on cancel, deinit and shutdown. Progress events coalesce newest-wins per key at ≤ 10 Hz with a trailing emission after a quiet period (sync-2 S2-24). Terminal events coalesce per subject and are never dropped; bulk per-asset outcomes fold into `syncProgress`/`syncFinished`; a pruned id's subject retires with its `assetRemoved`; a transfer's progress key retires with the transfer. `clientShutDown` is delivered last on every path, waiting and lagging subscribers alike.

### 7.10 Runs, space, refresh, purge, maintenance, shutdown

- **Run:** single-flight (`sync()` joiners share the outcome), over the retention scope (ADR-027) → conditional manifest fetch (single-flight with point admission; a point-admission fetch never stores its ETag, sync-2 S2-28) → decode on the bulk executor (P-3, C2) → `freeSpace()` → plan (off-actor) → space decision **before any mutation** → `store.apply(manifest, etag:, eviction:)` → enqueue → settle → `markSynced(_:ifPurgeEpoch:)` only for `.complete`.
- **Space (R-SYN-11, ADR-025):** `available = volume(opportunistic for bulk/prefetch, important for user work) − reserve + pendingReclaim`; `budgetRoom = max(0, budget − (used − pruneBytes))`; a plan with zero fetch bytes always fits (sync-2 S2-06); unknown sizes are not estimated (S2-08); over budget → largest fitting prefix (essential first) or, with the policy off, `insufficientSpace` with zero side effects. Per-fetch headroom ledger counts bytes in flight **and committed since the last free-space read** (S2-09).
- **Unknown ids (prior-art resolver parity):** one single-flight conditional fetch; a waiter is answered from the newest manifest seen (fetched or applied), never `.notFound` while a run's fetch holds a newer one (sync-1 S1-13); negative cache 60 s, LRU-bounded.
- **Refresh (R-SYN-9):** `RefreshDecision.isSyncDue` (implemented, tested). The stamp lives in the index (R-STO-2).
- **Purge (R-CLN-6):** `purgeEpoch` bumped before any await; the active run ends `failed(.cancelled)`; non-user interests on purged ids withdrawn; user waiters re-queue; the store clears the stamp in the same commit.
- **Maintenance (R-SYN-16):** deadline on the monotonic clock; staging GC → orphan GC → eviction → deep verification in bounded batches; cancellation honoured between batches.
- **Retention scope (R-CAR-5, ADR-027):** `setRetentionScope(_:)` replaces the engine's scope (the next bulk run's) and pushes it to the store in an owned task (RE-S33); it starts no run.
- **Pins (R-CLN-4, ADR-044):** `setPinned(_:pinned:)` through the store in an owned task.
- **Memory pressure (R-CLN-11, ADR-044):** `observeMemoryPressure(epoch:handler:)` starts or stops one owned observer of `AssetEnvironment.memoryPressure`; only the newest epoch applies; the handler (the facade's relay) may stop it from inside; shutdown stops it.
- **Storage report and diagnostics:** `storageReport()` adds `RemoteSource.sourceCopyBytes()` to the store's report (RE-S32); `diagnostics()` returns `EngineDiagnostics` (counters, the last 32 `DiagnosticError`s, app version, launch epoch, generation, stamp, retention scope).
- **Shutdown (R-SYN-15, ADR-039, ADR-042):** see ADR-039's order; `AssetClient.shutdown()` then resets the mirror so `lookup` returns `nil` and closes the cache relay. `AssetClient.deinit` spawns `engine.shutdown()`; shutdown in `created` never opens the store. Afterwards every engine entry point returns `.failure(.shutDown)` (`sync`: `.failed(.shutDown)`; `registerGroup`: holds nothing; a new event stream yields `clientShutDown` and finishes); releases and `shutdown()` are idempotent no-ops.

## 8. Facade (WP-G)

`AssetClient(configuration:environment: = .live())`: stores values, creates the mirror, the store and engine actors, the background relay and the purgeable-cache relay; no I/O, no task, no `Bundle`/`UserDefaults` read, no URLSession (P-12, sync-2 S2-18). `start()` is single-flight; every async API awaits it. `lookup` (main actor) reads the mirror only. `resolve` returns a URL; `prefetch` returns a `PrefetchHandle` whose release is ordered after its registration and, for a re-lane, after the successor's registration (`cancel(after:)`), the task holding the old handle until that release ran so its deinit cannot release early (sync-1 S1-05, implemented and tested); `awaitRegistration()` reports `.shutDown`. The handle reaches the engine through `PrefetchRegistry` (`SyncEngine` conforms; tests use a gated fake). `PrefetchWindow.targets` (implemented): current, +1, −1, +2, −2…; `PrefetchWindowController` creates the new handle before releasing the old. `withAsset` leases through the engine (so lease release re-arms the alarm). The fallback chain (`AssetFallbackChain`): `prepare(kinds:)` builds the bundle index in one unit on the client's bulk executor (C2, ADR-038); `locate` is bundle → local, synchronous, no file-system work on main; `fetch` is `resolve` plus the candidate-extension check (ADR-037). Retention scope (`configuration.retentionScope`, `setRetentionScope(_:)`), pins (`pin`, `unpin`) and purgeable caches (`register`, `unregister`, main actor, held weakly by `PurgeableCacheRelay`) are ADR-027 and ADR-044. Observability: `AssetLog` lives in the Model (subsystem `com.ztron.assetkit`, categories `store`/`sync`/`transport`/`apple`, `hashed(_:)`, `emit(_:tap:)`), every line also to the optional `LogTap` with its subsystem (ADR-043); `MetricsSnapshot`; `DiagnosticReport` (Codable, no `AppKey`) from `SyncEngine.diagnostics()`. After `shutdown()` every API fails with `.shutDown` as ADR-042 lists. SPEC §4.1's "public re-exports" are one `@_exported import ZTronAssetModel` in `AssetClientConfiguration.swift`, so apps import only `ZTronAssetKit` (the only product); it is a compile-time attribute with no runtime effect, not a private API in the sense of R-SEC-3.

## 9. Hard problems: decisions and tests

Each test name below is the exact `@Test` display name the owning WP writes (the trace gate reads only `R-…` and `P-…` IDs, so tests are named by requirement). Names marked *(exists)* are in the repository now.

**H-1 Crash consistency.** Content-addressed immutable blobs, one atomically replaced whole-state index with a SHA-256 trailer, references made durable in dependency order, idempotent reconciliation (store.md §1; ADR-012, ADR-015, ADR-018); `FakeFileSystem` enumerates every mutation under four crash modes and kill→power-loss pairs across two lifetimes.
- `R-STO-5: crash at every file-system boundary during a first sync preserves I-1…I-5`
- `R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5`
- `R-STO-5: power loss after a durable commit keeps the store root reachable`
- `R-STO-4: a torn index.tmp is ignored and the newest valid generation wins`
- `R-STO-12: a header with a maximal generation or body length never traps`

**H-2 Snapshot vs deletion.** Epoch reclamation with acknowledged publication: delete only after an acknowledged snapshot of this epoch without the blob, awake-clock grace, a committed generation, no lease, no in-flight publication, and a fresh acknowledgement after the deadline (ADR-016, ADR-017).
- `R-CLN-5: deletion waits for the acknowledged snapshot without the blob, the grace window and every lease`
- `R-CLN-5: a sink that keeps an older or foreign snapshot never counts as acknowledgement`
- `R-CLN-5: deletion grace uses the awake clock and a fresh acknowledgement after a device sleep`
- `R-STO-13: the mirror ignores an out-of-order snapshot and acknowledges what readers see` *(exists)*

**H-3 Single-flight and cancellation.** One job per `TransferID`, ref-counted interests, continuations resumed only through `removeValue`, cancellation withdraws one token (ADR-020, §7.2).
- `R-SYN-4: 100 callers on one asset with seeded random cancellations share one transfer and each resumes exactly once`
- `R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels`
- `R-SYN-4: two identifiers with the same checksum share one transfer and both become present`
- `R-SYN-10: ensureAvailable cancelled as its last member commits resumes exactly once`
- `R-CAR-3: a re-laned prefetch handle releases its old interest only after the successor registered` *(exists; fails on the round-1 release logic)*
- `R-CAR-4: a handle released without cancel() releases its interest on deinit` *(exists)*

**H-4 Priority.** Three lanes, a reserved user slot, in-place promotion through the synchronous handle, queue jump, preemption with resume (ADR-021, §7.4, §7.5).
- `R-SYN-3: a userInitiated request for an in-flight bulk asset promotes it without restarting the transfer`
- `R-SYN-3: with concurrency 1 a userInitiated request preempts the bulk transfer, which later resumes`
- `R-NET-10: a promoted asset's priority change reaches the transport before any other transfer starts`
- `R-NET-10: AssetPriority maps to URLSessionTask priorities 0.75, 0.5 and 0.25` *(exists)*

**H-5 Actor reentrancy.** Epoch-validated jobs, re-validation after every await, the store re-checks its phase and the record revision, the ledger of §10 (each row is a `// REENTRANCY:` comment in code). Store rows are tested by holding the unit behind the await with `SteppedBlockingExecutor` and acting on the actor meanwhile (ADR-045).
- `R-SYN-2: 10,000 seeded random operations never leave the transition table and keep every engine invariant`
- `R-INT-2: a manifest change during the publish rename yields superseded and never returns the URL`
- `R-CLN-5: two identifiers with identical bytes published concurrently keep the blob until both are removed`

**H-6 Background transfers across relaunch.** Opt-in background session; attempt-unique, self-describing staging names; launch order session → tasks → staging → reconcile → GC (ADR-013, ADR-026, ADR-028).
- `R-NET-3: a live background task is re-attached after relaunch, not duplicated`
- `R-NET-3: a download completed while the app was dead is adopted from staging, not re-downloaded`
- `R-NET-3: an offline launch cancels no live background task`
- `R-CLN-3: a staged file handed off by a relaunched background session survives launch staging GC`

**H-7 Double residency.** Adopt-and-release with durable commit before release (`AssetStore.adoptionReport()`, atomic), keep-scope exclusions from the retention scope, source bytes reported through `RemoteSource.sourceCopyBytes()` (ADR-027).
- `R-CLN-10: a media pack is released only after every catalog entry in it is adopted or excluded` *(exists)*
- `R-CLN-10: a pack is released only after the adopting generation is durably committed`
- `R-CLN-10: a publish that lands during the adoption report's durable commit is not reported adopted`
- `R-CLN-10: entries outside the retention scope never block a pack release`
- `R-APL-3: an adopted asset is served from blobs and never from a pack location`
- `R-CLN-9: storageReport counts bytes the OS still holds in adopted packs`

**H-8 Time and determinism.** `TimeSource` (wall, monotonic, awake, sleep), one engine alarm, keyed randomness, `ManualTimeSource` (ADR-017, ADR-022, ADR-024).
- `R-ENV-1: ManualTimeSource wakes sleepers in deadline then registration order` *(exists)*
- `R-ENV-1: a cancelled ManualTimeSource sleeper throws promptly and leaves no sleeper behind` *(exists)*
- `R-SYN-5: backoff delays are full jitter keyed by asset and attempt and reproducible from the seed` *(exists)*
- `R-SYN-5: no transfer starts before a 429's Retry-After elapses on ManualTimeSource`

**H-9 Backpressure.** Pull-based bounded queues, newest-wins progress at ≤ 10 Hz, never-dropped terminal events, bulk outcomes folded into run progress (ADR-023).
- `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync`
- `R-SYN-12: clientShutDown is the last event every subscriber receives`
- `R-SYN-12: transfer progress published to subscribers never exceeds 10 Hz per asset under ManualTimeSource`

**H-10 Migration.** Adopt-by-hash via same-volume rename in committed phases; phase 2 after open with adopt-on-demand; stamp migrated only on full adoption; key removed only after a durable commit (ADR-029).
- `R-STO-11: legacy files whose checksum verifies are moved into blobs, not re-downloaded`
- `R-STO-5: crash at every boundary during legacy migration preserves I-1…I-5 and adopts every verified file`
- `R-STO-11: lookups hit adopted legacy files while migration is still running, and no snapshot precedes reconciliation`
- `R-SEC-2: a legacy entry whose directory component is a symbolic link is dropped and nothing outside the legacy root moves`

## 10. REENTRANCY ledger (H-5, C3)

Every `await` inside an actor carries `// REENTRANCY: <row> — <what is re-validated>`. Two checks follow **every** await in both actors and are not repeated per row: the lifecycle/phase (engine: `running`, else unwind with `.shutDown`; store: `open`, else drop the mutation, store-1 S1-09) and, in the engine, the job's epoch (a stale continuation is abandoned). A new await without a row is a review failure.

### 10.1 `AssetStore`

| Row | Await | Re-validated afterwards |
|---|---|---|
| R1 | units inside `open()` | phase `opening`; async APIs await `open`; synchronous APIs threw `.notOpen` meanwhile (store-2 S2-07) |
| R2 | hash units in `publish` | every bound record still has the expected identity and revision, else `.superseded` before more work |
| R3 | `acquireReference` awaiting an in-flight publication or deletion of the same key | `blobTable[k]` re-read and decided anew (live → dedupe, doomed → rescue if `unreferenced`, absent → rename) (store-2 S2-01) |
| R4 | claim and rename units in `publish` | identity and revision again (store-2 S2-15); on a change `k` is doomed with `droppedInGeneration = 0`, no URL is returned; `publishing[k]` removed; every table update is read-modify-write |
| R5 | commit unit | `committedGeneration = max(…)` with the generation allocated at capture; mutations made meanwhile stay dirty; on failure `dirtyDirectories` restored; no new commit once closing |
| R6 | `sink.install` | the ack counts only if `installed.epoch == launchEpoch`; `ackedVersion = max`; ack time recorded on the awake clock; accesses merged; `retired` released here, off main |
| R7 | deletion unit | keys in `.deleting` are gone, or back to `doomed` with backoff on failure; waiting publishers resumed |
| R8 | `Task.yield()` between eviction or reconciliation chunks | per candidate: still present, unleased, not accessed since selection, still evictable |
| R9 | purge's grace wait (in the caller's engine-owned task) | deletable state recomputed from scratch; phase |
| R10 | listing units in `collectGarbage` | the sweep set is computed after the full listing against `blobTable ∪ publishing`, `mtime < now − orphanGrace`, not degraded |
| R11 | migration units | the legacy file still exists, its blob is still absent, its record still expects it |
| R12 | `runDueWork`'s fresh no-op install | the awake-clock deadline passed **before** the install; deletable state recomputed after the ack (ADR-017) |
| R13 | `freeSpace()` unit | the figures are a snapshot; `apply` re-validates each eviction victim |
| R14 | `stagingInventory()` / `collectStaging` listing units | the kept set is the caller's claims ∪ store-side live reservations at sweep time, plus `stagingClaimGrace` |
| R15 | `adoptionReport()`'s durable commit | nothing: the report is the state captured **before** the await (manifest paths, present records, retention-scope exclusions); mutations made meanwhile are not reported; on failure throw and report nothing (store-1 S1-10) |

### 10.2 `SyncEngine` (sync.md §5.4 as amended)

| Row | Await | Re-validated afterwards |
|---|---|---|
| RE-S01 | `start` task: `store.open()` | L; if shutdown began, close the store and finish with `.shutDown`; the snapshot is adopted only if newer |
| RE-S02 | `start`: `appVersion.currentAppVersion()` | L |
| RE-S03 | `start`: `remoteSources.makeRemoteSource(…)` | L; a source built after shutdown began is invalidated at once |
| RE-S04 | run: single-flight manifest fetch | L; run epoch; applied only if its fetch sequence is newer than the last applied |
| RE-S05 | run: decode on the bulk executor | L; run epoch |
| RE-S06 | run: `store.freeSpace()` | L; run epoch |
| RE-S07 | run: planner off the actor | L; run epoch; the store may have advanced (tolerated: `apply` diffs against current state, ADR-030) |
| RE-S08 | *(removed: LRU stamps arrive through `InstallAck`, X-5)* | — |
| RE-S09 | run: `store.apply(manifest, etag:, eviction:)` | jobs of pruned ids → T21; jobs whose identity changed → T22; no generation guard (sync-1 S1-12) |
| RE-S10 | run: awaiting run completion (token table) | L; the outcome is computed from the run ledger at resume time |
| RE-S11 | run: `store.markSynced(_:ifPurgeEpoch:)` | L; `.purgeRaced` leaves the sync due |
| RE-S12 | driver: `remote.transfer(request)` | E; job still `downloading` with interests; otherwise the handle is cancelled at once |
| RE-S13 | driver: each element of `handle.updates` | E; terminal elements apply T5/T6/T7; a stream that ends without one fails the job (sync-1 S1-11) |
| RE-S14 | driver: `store.publish(staged, binding:, expecting:)` | E; `.superseded` → T22/T11; the result goes to the interests present **now** |
| RE-S15 | *(merged into RE-S14: publication is one call, X-3)* | — |
| RE-S16 | alarm: `time.sleep(until:)` | the alarm token is current; due entries recomputed from `monotonicNow()`, never from the scheduled deadline |
| RE-S17 | watcher: `conditions.conditions()` | watcher token current and still needed, else the stream is dropped |
| RE-S18 | watcher: each element | watcher token; L; apply, then `pump()`; exit when idle |
| RE-S19 | point admission: manifest fetch | each unknown-id waiter still registered; answered from the newest manifest seen (sync-1 S1-13) |
| RE-S20 | `ensureAvailable`: group completion | L; group still registered; report recomputed from the store |
| RE-S21 | shutdown: joining owned tasks | lifecycle `shuttingDown`; nothing new spawns; the loop iterates a copy |
| RE-S22 | shutdown: `remote.invalidate()` then `store.close()` | — (terminal); invalidate returns after the **foreground** delegate's last callback (transport-2 T2-04) and the Apple source's in-flight `writeStaged`; a background session is released without waiting (ADR-039) |
| RE-S23 | maintenance: each store batch | L; deadline; `Task.isCancelled` |
| RE-S24 | purge: `store.purge(request)` | `purgeEpoch` was bumped before the await; afterwards jobs for purged ids are removed or re-queued (user waiters) |
| RE-S25 | the `join` family (`withTaskCancellationHandler` + `withCheckedContinuation`) | nothing: the body runs synchronously on the actor |
| RE-S26 | every entry point awaiting `start` | L (start may have degraded or shutdown begun) |
| RE-S27 | alarm: `store.runDueWork()` | L; reaped bytes wake `awaitingSpace` jobs; re-arm from the store's new `nextDeadline()` (ADR-022) |
| RE-S28 | `start`: background `activate()`, `reattachedTransfers()`, `store.stagingInventory()` | L; the reconciliation plan is computed after all three, in that order (ADR-028) |
| RE-S29 | migration batch: `store.migrateLegacy(maxFiles:)` | L; continues only while legacy work remains and the lifecycle is running |
| RE-S30 | entry-point owned tasks (purge, leases, pins, maintenance, `reportUnreadable`) | L; the caller's waiter still registered; a lease acquired after shutdown began is released at once |
| RE-S31 | memory-pressure observer: each element, then the `handler` call | L; the observer's epoch is still the applied one, else exit; a stop requested from inside the handler ends the loop after it returns |
| RE-S32 | `storageReport`: `store.storageReport()`, then `remote.sourceCopyBytes()` | L; the two figures are independent snapshots; 0 when no source exists yet |
| RE-S33 | `setRetentionScope`: owned task pushing the scope to the store | L; a scope set meanwhile has a newer sequence number and wins (the stale push is skipped) |
| RE-S34 | pack release: `store.adoptionReport()`, then `remote.reclaimSourceCopies(report)` | L; the report is the store's durable capture (R15); a release that races an eviction of a reported entry costs only a re-download, never data |

## 11. Requirements and budgets → target → work package → test

Every one of the 90 requirements and 14 budgets. *Test* is the `@Test` display name (or names) the work package writes; *(exists)* marks tests already in the repository. Gates that run outside Swift Testing are named where they are the primary proof (Q-n of SPEC §7.1). WP-I owns documentation; WP-H the fakes every test uses.

| ID | Level | Target | WP | Test (display name) |
|---|---|---|---|---|
| R-MAN-1 | MUST | Model | A | `R-MAN-1: both wire shapes of every shipped example manifest decode and round-trip with unknown fields ignored` |
| R-MAN-2 | MUST | Model | A | `R-MAN-2: every structural violation rejects the manifest and every per-entry violation quarantines only that entry`<br>`R-MAN-2: limit boundaries accept the limit and reject one past it` |
| R-MAN-3 | MUST | Model | A | `R-MAN-3: seeded fuzz of random, truncated, mutated and deeply nested manifests never traps and stays within 1 s and 4x the payload` |
| R-MAN-4 | MUST | Model | A | `R-MAN-4: applying diff(a, b) to a yields b and every identifier is classified exactly once` *(exists)*<br>`R-MAN-4: seeded manifests diff against themselves as all unchanged` |
| R-MAN-5 | MUST | Model | A | `R-MAN-5: a checksum-less entry changes content identity only when its remotePath changes` *(exists)* |
| R-MAN-6 | SHOULD | Model | A | `R-MAN-6: absent tags and policy reproduce the prior art's behaviour` |
| R-MAN-7 | MUST | Model | A | `R-MAN-7: every Model value round-trips through Codable where declared and is usable across tasks without isolation` |
| R-STO-1 | MUST | Storage | B | `R-STO-1: every mutation the store performs targets a URL under the versioned root`<br>`R-STO-1: a cancelled, paused or failed foreground transfer leaves no byte outside the store root` |
| R-STO-2 | MUST | Storage | B | `R-STO-2: deleting the root resets manifest, records, ETag and sync stamp together` |
| R-STO-3 | MUST | Storage | B | `R-STO-3: a blob never appears at its final path before size check, hash verification and barrier`<br>`R-STO-3: bytes appended to a staged file after publication begins are never published` |
| R-STO-4 | MUST | Storage | B | `R-STO-4: a torn index.tmp is ignored and the newest valid generation wins`<br>`R-STO-4: a degraded fallback deletes no blob listed in the older generation's doomed set` |
| R-STO-5 | MUST | Storage | B, H | `R-STO-5: crash at every file-system boundary during a first sync preserves I-1…I-5`<br>`R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5` |
| R-STO-6 | MUST | Storage | B, H | `R-STO-6: the fake and live file systems agree on the shared conformance contract`<br>`R-STO-6: ENOSPC during an index commit keeps the previous generation and retries` |
| R-STO-7 | MUST | Kit, Storage | G, B | `R-STO-7: lookup, prefetch, events and resolve entry make zero file-system calls on the main thread` |
| R-STO-8 | MUST | Storage | B | `R-STO-8: the root is excluded from backup and uses completeUntilFirstUserAuthentication` |
| R-STO-9 | MUST | Storage | B | `R-STO-9: a second store on the same root fails with locked deterministically`<br>`R-STO-9: a replaced root is detected before the next commit` |
| R-STO-10 | MUST | Storage, Kit | B | `R-STO-10: the default location is Application Support and caches or custom roots are selectable` |
| R-STO-11 | MUST | Storage | C | `R-STO-11: legacy files whose checksum verifies are moved into blobs, not re-downloaded`<br>`R-STO-11: a vanished legacy directory drops the UserDefaults stamp without claiming synced` |
| R-STO-12 | SHOULD | Storage | B | `R-STO-12: the v1 golden index fixture decodes and re-encodes byte-identically` |
| R-STO-13 | MUST | Storage, Kit | B, G | `R-STO-13: snapshot lookup returns present assets only and matches extensions case-insensitively` *(exists)*<br>`R-STO-13: snapshot keys order by epoch before version across store instances` *(exists)*<br>`R-STO-13: the mirror ignores an out-of-order snapshot and acknowledges what readers see` *(exists)* |
| R-INT-1 | MUST | Storage | C | `R-INT-1: streaming SHA-256 equals CryptoKit one-shot for 0, 1, 1 MiB−1, 1 MiB, 1 MiB+1 and 5 MiB` |
| R-INT-2 | MUST | Storage | C | `R-INT-2: a checksum mismatch deletes the staged bytes, throws integrity, counts a metric and publishes nothing` |
| R-INT-3 | MUST | Storage, Sync | C, F | `R-INT-3: repeated mismatches back off and finally mark the asset failed until its manifest entry changes` |
| R-INT-4 | SHOULD | Storage | C | `R-INT-4: deep verification repairs a corrupted resident blob within its byte budget` |
| R-INT-5 | MUST | Storage | C | `R-INT-5: unverified entries are rejected when allowUnverifiedAssets is false and flagged unverified otherwise` |
| R-INT-6 | MUST | Storage | C | `R-INT-6: the recorded blob hash is the digest of the written bytes, not the manifest claim` |
| R-NET-1 | MUST | Model, Sync | A, F | `R-NET-1: TransferID accepts only [0-9a-z-] up to 96 bytes with a known prefix` *(exists)*<br>`R-NET-1: StagingFileName round-trips through its parser and rejects foreign names` *(exists)*<br>`R-NET-1: FakeRemoteSourceFactory hands the store's staging sink to an attachable source before returning it` *(exists)*<br>`R-NET-1: the engine completes a sync against FakeRemoteSource with no network` |
| R-NET-2 | MUST | Transport | D | `R-NET-2: 500 downloads through one backend use at most maxConnectionsPerHost TCP connections` |
| R-NET-3 | SHOULD | Transport | D | `R-NET-3: the background identifier is stable, namespaced and recognised by the hook` *(exists)*<br>`R-NET-3: a download completed while the app was dead is adopted from staging, not re-downloaded` |
| R-NET-4 | MUST | Transport | D | `R-NET-4: plain HTTP is refused by the production policy even for loopback hosts` *(exists)*<br>`R-NET-4: the foreground session configuration has no httpAdditionalHeaders and no URLCache` *(exists)*<br>`R-NET-4: a cross-host redirect to an allow-listed host is followed without the app key` |
| R-NET-5 | MUST | Transport | D | `R-NET-5: ETag rejects empty values, values over 256 bytes and control characters` *(exists)*<br>`R-NET-5: a manifest fetch sends If-None-Match with the stored ETag and maps 304 to notModified` |
| R-NET-6 | MUST | Transport, Model | D, A | `R-NET-6: every TransferError maps to one failure class and the documented AssetError` *(exists)*<br>`R-NET-6: HTTP statuses map to the closed taxonomy` |
| R-NET-7 | MUST | Transport | D | `R-NET-7: the size guard aborts when the written or announced size exceeds the cap or byteSize is exceeded` *(exists)*<br>`R-NET-7: a gzip response is accepted when the decoded size equals byteSize though Content-Length differs` |
| R-NET-8 | SHOULD | Transport | D | `R-NET-8: a connection dropped mid-download resumes with Range and If-Range and the staged file is complete` |
| R-NET-9 | MUST | Transport | D | `R-NET-9: path mapping exposes satisfied, expensive and constrained exactly, and thermal maps to four levels` *(exists)*<br>`R-NET-9: the live conditions source yields the current state first, then on change, without polling` |
| R-NET-10 | MUST | Transport, Sync | D, F | `R-NET-10: AssetPriority maps to URLSessionTask priorities 0.75, 0.5 and 0.25` *(exists)*<br>`R-NET-10: a promoted asset's priority change reaches the transport before any other transfer starts` |
| R-APL-1 | MUST | AppleHosted | E | `R-APL-1: the Apple source satisfies RemoteSource end to end against a fake PackBackend` |
| R-APL-2 | MUST | AppleHosted | E | `R-APL-2: pack download progress reaches the engine as byte values scaled to the asset size (plus docs/APPLE-API-VERIFICATION.md)` |
| R-APL-3 | SHOULD | AppleHosted | E | `R-APL-3: an adopted asset is served from blobs and never from a pack location` |
| R-APL-4 | MUST | AppleHosted | E | `R-APL-4: the catalog is read from the essential pack and its digest is the ETag` |
| R-APL-5 | MUST | AppleHosted, Model | E | `R-APL-5: tier selection is correct for all 16 input combinations` *(exists)*<br>`R-APL-5: the awsOnly kill switch selects AWS on an OS that supports the Apple tier` *(exists)*<br>`R-APL-5: the package contains exactly one #available` (scans all of `Sources/`, `ZTronAssetTestSupport` included, ADR-014) |
| R-SYN-1 | MUST | Sync | F | `R-SYN-1: the plan is identical for equal inputs built in different dictionary orders` |
| R-SYN-2 | MUST | Sync | F | `R-SYN-2: the transition table admits exactly the listed transitions` *(exists)*<br>`R-SYN-2: 10,000 seeded random operations never leave the transition table and keep every engine invariant` |
| R-SYN-3 | MUST | Sync | F | `R-SYN-3: a userInitiated request for an in-flight bulk asset promotes it without restarting the transfer` |
| R-SYN-4 | MUST | Sync | F | `R-SYN-4: 100 callers on one asset with seeded random cancellations share one transfer and each resumes exactly once` |
| R-SYN-5 | MUST | Sync | F | `R-SYN-5: backoff delays are full jitter keyed by asset and attempt and reproducible from the seed` *(exists)*<br>`R-SYN-5: no transfer starts before a 429's Retry-After elapses on ManualTimeSource` |
| R-SYN-6 | MUST | Sync | F | `R-SYN-6: one failing asset among 100 never aborts the sync and is listed in the report` |
| R-SYN-7 | MUST | Sync | F | `R-SYN-7: bulk pauses on Low Data Mode and resumes when it is turned off` |
| R-SYN-8 | MUST | Sync, Storage | F, B | `R-SYN-8: reconcile is committed before the first transfer starts`<br>`R-SYN-8: a metadata-only manifest change completes the run and writes the stamp` |
| R-SYN-9 | MUST | Sync | F | `R-SYN-9: refresh policies decide due-ness exhaustively including app-version change and clock skew` *(exists)*<br>`R-SYN-9: the stamp is stored in the index and written only after a complete run` |
| R-SYN-10 | MUST | Sync | F | `R-SYN-10: availability counts present, missing, stale and failed without any network request` |
| R-SYN-11 | MUST | Sync, Storage | F, C | `R-SYN-11: a plan that cannot fit even after eviction fails with insufficientSpace and leaves index, blobs and staging byte-identical` |
| R-SYN-12 | MUST | Sync | F | `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync` |
| R-SYN-13 | MUST | Sync | F | `R-SYN-13: assets that failed offline are retried when the path becomes satisfied without any timer` |
| R-SYN-14 | MUST | Sync | F | `R-SYN-14: after a sync quiesces the engine owns zero timers and zero tasks and observes nothing` |
| R-SYN-15 | MUST | Sync, Kit | F, G | `R-SYN-15: shutdown mid-flight cancels every transfer, finishes every stream and leaves zero owned tasks, sleepers and observers`<br>`R-SYN-15: every API called after shutdown fails with shutDown` (walks ADR-042's list)<br>`R-SYN-15: no foreground staging write lands after the store is closed`<br>`R-SYN-15: a prefetch handle made after shutdown reports shutDown and holds nothing` *(exists)* |
| R-SYN-16 | SHOULD | Sync | F | `R-SYN-16: maintenance stops at its time budget on ManualTimeSource and resumes verification where it stopped` |
| R-CLN-1 | MUST | Storage | C | `R-CLN-1: prune removes blobs of removed entries only after acknowledgement and grace` |
| R-CLN-2 | MUST | Storage | C | `R-CLN-2: orphan GC removes unreferenced blobs older than the orphan grace` |
| R-CLN-3 | MUST | Storage | C | `R-CLN-3: staging GC removes unowned partial files at launch and after sync`<br>`R-CLN-3: a staged file handed off by a relaunched background session survives launch staging GC` |
| R-CLN-4 | MUST | Storage | C | `R-CLN-4: eviction removes least-recently-used first, larger first on ties, down to 90 % of budget` |
| R-CLN-5 | MUST | Storage | C | `R-CLN-5: deletion waits for the acknowledged snapshot without the blob, the grace window and every lease` |
| R-CLN-6 | MUST | Storage, Sync | C, F | `R-CLN-6: purge all returns bytes freed, leaves the store consistent and makes a sync due` |
| R-CLN-7 | MUST | Storage | C | `R-CLN-7: deleting blobs/ between launches resets the sync stamp and heals lazily` |
| R-CLN-8 | MUST | Storage, Sync | C, F | `R-CLN-8: reportUnreadable quarantines the entry, removes the blob after grace and schedules a re-download` |
| R-CLN-9 | MUST | Storage, Sync | C, F | `R-CLN-9: storageReport sums bytes by kind and state with pinned, evictable, staging, orphan and free space`<br>`R-CLN-9: storageReport counts bytes the OS still holds in adopted packs` |
| R-CLN-10 | SHOULD | AppleHosted, Storage, Sync | E, B, F | `R-CLN-10: a media pack is released only after every catalog entry in it is adopted or excluded` *(exists)*<br>`R-CLN-10: the catalog pack is never released and keepPacks never releases` *(exists)*<br>`R-CLN-10: a pack is released only after the adopting generation is durably committed`<br>`R-CLN-10: entries outside the retention scope never block a pack release` |
| R-CLN-11 | MAY | Model, Kit, Sync | G, F | `R-CLN-11: the cache relay purges every live cache, stops observing when none is left and refuses registration after shutdown` *(exists)*<br>`R-CLN-11: a registered purgeable cache is purged on a memory-pressure event` |
| R-CLN-12 | MUST | Storage | C | `R-CLN-12: every cleanup operation run twice is a no-op the second time` |
| R-CAR-1 | MUST | Kit | G | `R-CAR-1: every async API awaits start so a resolve before start succeeds`<br>`R-CAR-1: init touches neither the file system nor Bundle and spawns no task` |
| R-CAR-2 | MUST | Kit | G | `R-CAR-2: image, svg, video and audio kinds use the prior-art candidate extensions in order` *(exists)*<br>`R-CAR-2: a bundle hit wins over a local copy` |
| R-CAR-3 | MUST | Kit | G | `R-CAR-3: window targets are current, then ±1, then ±2, clamped at both ends` *(exists)*<br>`R-CAR-3: a repeated identifier keeps its closest occurrence and an out-of-range index yields nothing` *(exists)*<br>`R-CAR-3: moving the window by one cancels exactly the asset that left and starts exactly the one that entered`<br>`R-CAR-3: a re-laned prefetch handle releases its old interest only after the successor registered` *(exists)* |
| R-CAR-4 | MUST | Kit | G | `R-CAR-4: a handle released without cancel() releases its interest on deinit` *(exists, against a fake registry; WP-G adds the engine-level variant)*<br>`R-CAR-4: cancel() before the registration landed releases the interest right after it` *(exists)* |
| R-CAR-5 | MUST | Model, Sync, Storage | A, F, C | `R-CAR-5: identifier, tag and prefix scopes select the same entries in planning and availability`<br>`R-CAR-5: the retention scope bounds bulk runs and evicts excluded entries first without deleting anything by itself` |
| R-CAR-6 | MUST | Tests/ZTronAssetCompatibilityTests | G | `R-CAR-6: CDNAsset keeps the prior-art initialiser, wire format and resolvedFileName` *(exists)*<br>`R-CAR-6: a CDNAsset converts to a ManifestEntry and back without loss` *(exists)*<br>`R-CAR-6: sync outcomes and refresh policies map to the prior-art cases` *(exists)* |
| R-CAR-7 | MUST | Model, Storage, Kit | A, B, G | `R-CAR-7: every StoreError maps to the documented AssetError` *(exists)*<br>`R-CAR-7: resolve throws a typed AssetError that callers switch over exhaustively` |
| R-CAR-8 | SHOULD | Kit, Storage | G, C | `R-CAR-8: withAsset releases its lease when the body throws or is cancelled` |
| R-CAR-9 | MUST | all production targets | I | `R-CAR-9: no production source imports UIKit, SwiftUI or Combine` |
| R-OBS-1 | MUST | Model, all | A, all | `R-OBS-1: log lines carry the module subsystem and their category and render identifiers as stable hashes` *(exists)*<br>`R-OBS-1: every log line uses subsystem com.ztron.assetkit and one of the four categories with identifiers hashed` |
| R-OBS-2 | MUST | Kit, Sync | G, F | `R-OBS-2: metrics count bytes, requests, retries and failures by class, hits, misses, evictions and GC bytes` |
| R-OBS-3 | SHOULD | Kit, Sync | G, F | `R-OBS-3: diagnosticReport is valid JSON with state counts and the last errors and never the canary key` |
| R-SEC-1 | MUST | Model, Transport, Kit | A, D, G | `R-SEC-1: AppKey and ResumeData redact themselves under description, reflection and dump` *(exists)*<br>`R-SEC-1: the canary key appears in no description, dump, Mirror, error, event, metric or captured log line` |
| R-SEC-2 | MUST | Storage, AppleHosted | B, C, E | `R-SEC-2: every store URL is built under the versioned root from validated names only` *(exists)*<br>`R-SEC-2: blob names parse only as 64 lowercase hex digits and a lowercase extension` *(exists)*<br>`R-SEC-2: pack locations reject traversal, empty and dot segments and invalid pack ids` *(exists)*<br>`R-SEC-2: manifest text never becomes a path component of the store` |
| R-SEC-3 | MUST | all production targets | I | `R-SEC-3: no file under Sources/ declares NSAllowsArbitraryLoads, an ATS exception or a private API` |
| R-ENV-1 | MUST | Model, TestSupport | A, H | `R-ENV-1: ManualTimeSource wakes sleepers in deadline then registration order` *(exists)*<br>`R-ENV-1: a cancelled ManualTimeSource sleeper throws promptly and leaves no sleeper behind` *(exists)*<br>`R-ENV-1: no production source outside the live conformers calls Date(), DispatchTime.now(), Task.sleep or SystemRandomNumberGenerator` |
| R-ENV-2 | MUST | Package | orchestrator | `R-ENV-2: the package's deployment floors are iOS 15 and macOS 12 (manifest scan; the Q-1 iOS build is the primary proof)` |
| R-ENV-3 | MUST | Package | orchestrator | `R-ENV-3: Package.swift declares no package dependencies` |
| R-ENV-4 | MUST | all of Sources/ | all | `R-ENV-4: the unsafe-pattern scan of Sources/ finds at most three escapes, each audited (the unsafe gate Q-3 is the primary proof; today 0)` |
| R-ENV-5 | MUST | all | orchestrator | `R-ENV-5: Package.swift sets Swift 6 language mode and strict concurrency and no warnings-as-errors flag (Q-1 builds are the primary proof)` |
| R-ENV-6 | SHOULD | Kit | G | `R-ENV-6: every public async API of AssetClient except withAsset, sync and shutdown throws AssetError typed` (ADR-042) |
| P-1 | BUDGET | Kit (`ZTronAssetKitBenchmarks`) | G | `P-1: lookup on the main actor stays under lookup_p99_us at 10,000 assets and scales within scale_ratio_max` |
| P-2 | BUDGET | Storage (`ZTronAssetKitBenchmarks`) | B | `P-2: cold index load of 10,000 records off the main thread is under budget` |
| P-3 | BUDGET | Model (`ZTronAssetKitBenchmarks`) | A | `P-3: decoding and validating the 3.3 MB reference manifest stays under manifest_decode_validate_ms` |
| P-4 | BUDGET | Sync (`ZTronAssetKitBenchmarks`) | F | `P-4: planning 10,000 vs 10,000 entries with 10% churn stays within plan_ms and scales by at most doubling_ratio_max` |
| P-5 | BUDGET | Storage (`ZTronAssetKitBenchmarks`) | B | `P-5: index commit of 10,000 records is under budget and a bulk sync commits at most 4 per second` |
| P-6 | BUDGET | Storage (`ZTronAssetKitBenchmarks`) | C | `P-6: streaming SHA-256 of 256 MiB meets the throughput floor, the one-shot ratio and the memory cap` |
| P-7 | BUDGET | Sync, Kit (`ZTronAssetKitBenchmarks`) | F, G | `P-7: a 1 GiB synthetic bulk sync adds at most sync_memory_delta_mib_max MiB and does not grow with catalog size` |
| P-8 | BUDGET | Kit (`ZTronAssetKitBenchmarks`) | G | `P-8: UI-facing calls make zero main-thread file-system calls and each stays within ui_call_ms_max` |
| P-9 | BUDGET | Sync, Kit (`ZTronAssetKitBenchmarks`) | F, G | `P-9: 64 concurrent resolves plus hashing keep the heartbeat gap p99 within budget` |
| P-10 | BUDGET | Transport (`ZTronAssetKitBenchmarks`) | D | `P-10: 500 small assets over a loopback server use at most connections_max TCP connections` |
| P-11 | BUDGET | Transport, Sync (`ZTronAssetKitBenchmarks`) | D, F | `P-11: assets with server latency sync at least speedup_min times faster at the configured concurrency than at 1` |
| P-12 | BUDGET | Kit (`ZTronAssetKitBenchmarks`) | G | `P-12: AssetClient.init completes within init_ms_max and performs no file-system call` |
| P-13 | BUDGET | Storage (`ZTronAssetKitBenchmarks`) | C | `P-13: reclaiming 10,000 blobs finishes under budget in batches of bounded duration` |
| P-14 | BUDGET | Sync (`ZTronAssetKitBenchmarks`) | F | `P-14: after quiescence the engine owns at most idle_timers_max timers and idle_tasks_max tasks` |

Counts: 90 requirements (78 MUST, 11 SHOULD, 1 MAY) and 14 budgets = 104 IDs. Every SHOULD and the MAY is planned for implementation; none is declined in this round. Benchmarks read every threshold from `Scripts/quality-gates.json` through `QualityBudgets` (`Tests/ZTronAssetKitBenchmarks/QualityBudgets.swift`), run serialized in one parent suite (sync-2 S2-14), and live in the benchmark target (ADR-010).

## 12. Review findings → resolution

All 86 critical and major findings of the six Phase B reviews (19 critical, 67 major), then the 41 minor ones. *Resolved* means the contract or this document now prescribes the fix (with the ADR or section that holds it) and names the regression test the owning WP writes; *(exists)* marks a test already in the repository. No critical or major finding is rejected.

### 12.1 store-1 (crash consistency)

| ID | Sev | Resolution | Regression test |
|---|---|---|---|
| S1-01 | critical | Resolved, ADR-015, §4.1, §4.5: `open()` dirties `blobs/` and barrier-syncs the root before launch deletions; every adoption dirties its fan-out; `FakeFileSystem.processKill` keeps the volatile split; R-STO-5 enumerates kill→power-loss pairs | `R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5` |
| S1-02 | critical | Resolved, ADR-015, §3: `<base>` barrier-synced after creating `ZTronAssetKit`; durable commits full-sync `ZTronAssetKit` and `<base>` (`StoreLayout.container`) | `R-STO-5: power loss after a durable commit keeps the store root reachable` |
| S1-03 | critical | Resolved, ADR-018: `DoomReason` persisted; adoption never binds purged, quarantined or failed records; a failed unlink stays doomed | `R-CLN-6: a purge is not undone by a power loss after the reaper ran`; `R-CLN-8: a quarantined blob resurrected by power loss is never re-adopted` |
| S1-04 | critical | Resolved, §4.2: overflow-checked `nextGeneration`, generations ≥ 2⁶² malformed, `bodyLength` bound checked before arithmetic | `R-STO-12: a header with a maximal generation or body length never traps` |
| S1-05 | major | Resolved, ADR-018, §4.3: adoption iterates records, `apply` adopts before deref, checksum-less and rescue publishes commit before returning, `apply` short-circuits on the committed digest | `R-STO-5: a deduplicated or rescued publish that returned is present after a kill`; `R-INT-5: an unverified publish that returned survives a kill without a re-download` |
| S1-06 | major | Resolved, ADR-018: `corrupt` doom reason; a verified publish replaces a corrupt name; EEXIST compares sizes | `R-CLN-7: a truncated blob is replaced by the next verified download` |
| S1-07 | major | Resolved, ADR-015, §4.1: ENOSPC at commit removes `index.tmp`/`index.prev` and retries; `open()` never fails on a post-load commit (read-only) | `R-SYN-11: eviction frees space while every index commit fails with ENOSPC`; `R-CLN-6: purge on a full volume returns bytes freed` |
| S1-08 | major | Resolved: `FileLockToken.identity` (dev, ino) checked before every commit; lock released on every throwing path of `open()`; directories to `v1` → lock → attributes | `R-STO-9: a replaced root is detected before the next commit`; `R-STO-9: a failed open releases the lock` |
| S1-09 | major | Resolved, ADR-039, `AssetStore` contract: phase `closing`, in-flight units drained, every resumption re-checks the phase | `R-SYN-15: no store mutation or commit happens after close returns` |
| S1-10 | major | Resolved, ADR-027, §4.6a: `AssetStore.adoptionReport()` captures synchronously, commits durably and reports only what it captured (round 2; REENTRANCY R15); release after that durable commit | `R-CLN-10: a pack is released only after the adopting generation is durably committed`; `R-CLN-10: a publish that lands during the adoption report's durable commit is not reported adopted` |
| S1-11 | major | Resolved, §4.2: in degraded mode DOOMED keys are protected like orphans until the next apply plus adoption | `R-STO-4: a degraded fallback deletes no blob listed in the older generation's doomed set` |
| S1-12 | major | Resolved, §4.3, ADR-013: `publish` claims `.part` → `.verifying` before hashing; producers never hold a descriptor after completion | `R-STO-3: bytes appended to a staged file after publication begins are never published` |
| S1-13 | major | Resolved, ADR-017, ADR-022: no reaper loop; `nextDeadline()` covers time-only blockers; lease/ack/commit re-arm the engine's alarm | `R-SYN-14: a doomed but leased blob leaves no running reaper task` |

### 12.2 store-2 (snapshot, deletion, determinism)

| ID | Sev | Resolution | Regression test |
|---|---|---|---|
| S2-01 | critical | Resolved, ADR-018: `acquireReference`, `publishing: [BlobKey: Task]`, read-modify-write after every await; apply and migration use the same operation; ADR-020 also removes most concurrent same-key publications | `R-CLN-5: two identifiers with identical bytes published concurrently keep the blob until both are removed`; `R-CLN-2: a superseded publication never leaves its key unprotected while another publication of the same key is in flight`; `R-CLN-1: a manifest that re-adds a key being deleted waits for the deletion and re-downloads` |
| S2-02 | critical | Resolved, ADR-016: `SnapshotKey(epoch, version)`, `InstallAck.installed`, own-epoch acks only, explicit `reset()` (implemented in `SnapshotMirror`) | `R-CLN-5: a sink that keeps an older or foreign snapshot never counts as acknowledgement`; `R-STO-13: the mirror ignores an out-of-order snapshot and acknowledges what readers see` *(exists)* |
| S2-03 | critical | Resolved, ADR-022, ADR-017: no store task; deadlines only for time-blocked keys; orphans doomed with `droppedInGeneration = 0`; failed unlinks back off | `P-14: a doomed key blocked only by a lease leaves the store with no running task and no armed timer`; `R-CLN-5: releasing the last lease on an eligible blob deletes it without any time advance` |
| S2-04 | critical | Resolved, ADR-018: DOOMED derived at capture; load repair `DOOMED \ referenced` counted in `StoreMetrics.doomedRepairs`; checker asserts `DOOMED ∩ referenced = ∅` | `R-STO-5: a blob reaped and then republished before the lazy commit survives a crash and the next launch` |
| S2-05 | critical | Resolved, §4.3, ADR-013: `publish` removes the sidecar before its barrier; per-attempt names and the `.verifying` claim mean no resume ever appends into a published inode | `R-STO-5: crash at every file-system boundary during a first sync preserves I-1…I-5` (scenario includes a resumable pair) |
| S2-06 | major | Resolved, §4.6: `FreeSpace.pendingReclaim` added to availability in every budget decision | `R-CLN-4: evicting twice within the grace window frees no more than evicting once` |
| S2-07 | major | Resolved, §4.4: launch DOOMED keys wait for the first ack plus grace; `open()` returns after the first snapshot; synchronous APIs before open throw `.notOpen`; leases end at close | `R-CLN-5: reopening the same root in one process never deletes a blob within the grace window of its last acknowledgement` |
| S2-08 | major | Resolved, ADR-022: no store-owned task (`runDueWork()` is called explicitly); every collection becomes file ops in sorted order; ScenarioRunner asserts the crash run's op prefix; `ManualTimeSource.waitForSleepers` | `R-STO-5: the crash run performs the clean run's operations in the same order up to the crash point` |
| S2-09 | major | Resolved, ADR-029: phase 2 after open, adopt-on-demand, no snapshot before reconciliation | `R-STO-11: lookups hit adopted legacy files while migration is still running, and no snapshot precedes reconciliation` |
| S2-10 | major | Resolved, §4.7: migration driven by a non-following listing; entries matched against listed regular files; no standardization check | `R-SEC-2: a legacy entry whose directory component is a symbolic link is dropped and nothing outside the legacy root moves` |
| S2-11 | major | Resolved, ADR-028: `stagingClaimGrace`, GC after launch reconciliation, store-side reservations never collected | `R-CLN-3: a staged file handed off by a relaunched background session survives launch staging GC` |
| S2-12 | major | Resolved, ADR-016: `AssetSnapshot` is `package`; the engine resolves through `store.location(for:)`; one-call publication; one timer owner | `R-CLN-5: every URL handed out stays readable for at least the grace window` |
| S2-13 | major | Resolved, §4.1, `SnapshotKey` doc: versions and generations allocated at capture, before any await | `R-CLN-5: a deref during an in-flight commit or install never makes its blob deletable before a later commit and acknowledgement` |
| S2-14 | major | Resolved, ADR-017: awake-clock grace (`TimeSource.uptimeNow`), fresh acknowledgement after the deadline, consumer contract on `AssetLocation` | `R-CLN-5: deletion grace uses the awake clock and a fresh acknowledgement after a device sleep` |
| S2-15 | major | Resolved, §4.3: identity re-validated after every await; `.superseded`, no URL | `R-INT-2: a manifest change during the publish rename yields superseded and never returns the URL` |
| S2-16 | major | Resolved, ADR-014 (verified with the compiler this round) | `R-ENV-1: ManualTimeSource wakes sleepers in deadline then registration order` *(exists)* |

### 12.3 sync-1 (engine liveness and cancellation)

| ID | Sev | Resolution | Regression test |
|---|---|---|---|
| S1-01 | critical | Resolved, §7.1: one `retire` funnel; no-interest jobs leave verifying/committing by removal, never retry; re-attached transfers get a system interest | `R-SYN-4: a job whose last interest left during verification is not retried after an integrity failure`; `R-SYN-2: a stale commit with no interests removes the job and frees its pipeline slot` |
| S1-02 | critical | Resolved, §7.2: every continuation kind in a token table, resumed only via `removeValue`, settled at registration, transition, withdrawal, purge and shutdown | `R-SYN-8: a metadata-only manifest change completes the run and writes the stamp`; `R-SYN-10: ensureAvailable cancelled as its last member commits resumes exactly once`; `R-CLN-6: purge ends the active run with failed(cancelled)` |
| S1-03 | critical | Resolved, ADR-031, §7.7: `CircuitBreaker.Outcome.abandoned`, total probe resolution, probe never preempted | `R-SYN-5: a half-open probe cancelled by its last caller lets the next request probe` |
| S1-04 | critical | Resolved, ADR-039: store-touching entry points are engine-owned tasks; shutdown joins them before closing; shutdown in `created` never opens | `R-SYN-15: shutdown during a purge's grace window leaves no deletion after close and no pending sleeper` |
| S1-05 | major | Resolved, §8. Round 1's `cancel(after:)` ordered its own release but let the dropped handle's deinit release early (contract-fix round 2, issue 3); fixed in round 2: the ordered release's task holds the handle, so the deinit release runs afterwards and is a no-op | `R-CAR-3: a re-laned prefetch handle releases its old interest only after the successor registered` *(exists; 4 issues on the round-1 logic, green on the fix)*; `R-CAR-3: a neighbour that becomes current is promoted without a second transfer` (1,000 promotions under load) |
| S1-06 | major | Resolved, ADR-021: synchronous handle controls, no control stream; `FakeTransferHandle` records order under a lock | `R-NET-10: a promoted asset's priority change reaches the transport before any other transfer starts` |
| S1-07 | major | Resolved, §7.2, §7.4: every lane change re-runs admission for blocked, failed and running jobs; a demoted transfer on a refused lane is paused | `R-SYN-7: a user resolve of a policy-blocked bulk asset starts at once and its demotion pauses it again` |
| S1-08 | major | Resolved, ADR-039: shared work in engine-owned tasks; a caller's cancellation withdraws only its interest | `R-SYN-4: cancelling one caller of a shared manifest fetch neither cancels nor waits for the others` |
| S1-09 | major | Resolved, ADR-039: owned tasks keyed by unique spawn ids; the alarm body unregisters itself | `R-SYN-15: a replaced alarm or watcher never unregisters its successor and shutdown joins every owned task` |
| S1-10 | major | Resolved, §7.8: heap compacted eagerly; the engine cancels the watcher when idle | `R-SYN-14: after a sync quiesces the engine owns zero timers and zero tasks and observes nothing` |
| S1-11 | major | Resolved, §7.1: a stream without a terminal element fails the job; the handle is cancelled on every driver exit | `R-SYN-2: a transfer stream that ends without a terminal element fails the job instead of stranding it` |
| S1-12 | major | Resolved, ADR-030: no whole-snapshot generation guard; per-entry identity guard at publication | `R-SYN-10: ensureAvailable during a bulk sync never fails with storageUnavailable because of concurrent commits` |
| S1-13 | major | Resolved, §7.10: unknown-id waiters answered from the newest manifest seen | `R-CAR-2: an identifier present in a manifest fetched during planning is never answered notFound` |
| S1-14 | major | Resolved, ADR-022, §7.10: `awaitingSpace` woken by `runDueWork`; `failed(.whenOnline)` counts as blocked for settling; pending-run flags | `R-SYN-11: fetches wait for space reclaimed after the grace window instead of failing`; `R-SYN-6: an offline run ends blocked and a new run starts when the path is satisfied` |
| S1-15 | major | Resolved, §7.3: jobs materialised only within pipeline + `runLookahead` | `R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs`; `P-7: a 1 GiB synthetic bulk sync adds at most sync_memory_delta_mib_max MiB and does not grow with catalog size` |

### 12.4 sync-2 (engine budgets, space, determinism)

| ID | Sev | Resolution | Regression test |
|---|---|---|---|
| S2-01 | critical | Resolved, ADR-031: total probe resolution plus `probeWatchdog` | `R-SYN-5: a half-open probe that fails offline re-arms the probe instead of wedging the breaker`; `R-SYN-10: ensureAvailable completes after a breaker recovers from an abandoned probe` |
| S2-02 | critical | Resolved, ADR-022: the engine's alarm drives `store.runDueWork()`; reaped bytes wake `awaitingSpace` | `R-SYN-11: a fetch blocked on ENOSPC resumes after the store's reaper frees doomed blobs` |
| S2-03 | major | Resolved, §7.6, §7.10: a throttle-only blocked run sets a pending run at the throttle's end | `R-SYN-5: a run blocked by Retry-After resumes in a new run when the throttle ends` |
| S2-04 | major | Resolved, ADR-032: integrity bookkeeping persisted in the store; every lane honours `nextEligibleAt` | `R-INT-3: visiting a corrupt asset repeatedly never downloads it more than maxIntegrityAttempts times` |
| S2-05 | major | Resolved, ADR-031: an ambiguous object 403 fails for the run only | `R-SYN-5: an ambiguous 403 is never retried with backoff and never quarantines the asset beyond the run` |
| S2-06 | major | Resolved, §7.10: `budgetRoom` clamped at 0; zero fetch bytes always fit | `R-SYN-11: a run with nothing to fetch completes when usage exceeds the budget` |
| S2-07 | major | Resolved, ADR-025: largest fitting prefix, essential first; protection limited to the fetched set | `R-SYN-11: a catalog larger than the budget syncs its largest fitting prefix essential-first` |
| S2-08 | major | Resolved, §7.10: no unknown-size estimate in the plan (`PlanTotals.fetchBytes` counts known sizes); per-fetch ledger | `R-SYN-11: a manifest without byteSize never fails the space check with insufficientSpace` |
| S2-09 | major | Resolved, §7.10: committed bytes stay in the ledger until the next free-space read | `R-SYN-11: committed bytes stay in the headroom ledger so the reserve is never crossed` |
| S2-10 | major | Resolved, §7.4: the pipeline cap gates non-user lanes only | `R-SYN-3: a user-initiated job starts while bulk work fills the verify and commit pipeline` |
| S2-11 | major | Resolved, ADR-029 | `R-STO-11: a resolve during migration adopts that legacy file first and never waits for the whole catalog` |
| S2-12 | major | Resolved, ADR-016, §5: `InstallAck.retired` releases the old snapshot off main (implemented); bulk installs ≤ 10 Hz; the store's present table is maintained incrementally | `P-8: UI-facing calls make zero main-thread file-system calls and each stays within ui_call_ms_max` |
| S2-13 | major | Resolved, ADR-037: bundle index built off main by `AssetFallbackChain.prepare` (implemented) | `P-8: the fallback chain's bundle step does no work on the main thread` |
| S2-14 | major | Resolved, §11 note: benchmarks run serialized under one parent suite; the P-9 heartbeat is a cooperative-pool task timed with `LiveTimeSource` (benchmarks are exempt from Q-4's no-sleep rule, which binds the deterministic suite) | `P-9: 64 concurrent resolves plus hashing keep the heartbeat gap p99 within budget` |
| S2-15 | major | Resolved, ADR-014 (as store-2 S2-16) | `R-ENV-1: a cancelled ManualTimeSource sleeper throws promptly and leaves no sleeper behind` *(exists)* |
| S2-16 | major | Resolved, ADR-024 (implemented in `Backoff.delay`) | `R-SYN-5: backoff delays are full jitter keyed by asset and attempt and reproducible from the seed` *(exists)* |
| S2-17 | major | Resolved, ADR-023, §7.9: bulk outcomes folded into run events; pruned subjects retired; registration on first pull | `R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync` |
| S2-18 | major | Resolved, §8: no URLSession in `AssetClient.init`; the source is built by `RemoteSourceFactory` in `start()` (implemented) | `P-12: AssetClient.init completes within init_ms_max and performs no file-system call` (run with `.live()` as well as fakes) |
| S2-19 | major | Resolved, ADR-021: no control stream exists | `R-SYN-14: no task outlives a transfer in the live foreground backend` |

### 12.5 transport-1 and transport-2

| ID | Sev | Resolution | Regression test |
|---|---|---|---|
| TR1-1 | critical | Resolved, ADR-020, ADR-013, §4.3: single-flight per content, per-attempt names, exclusive renames, `.verifying` claim | `R-SYN-4: two identifiers with the same checksum share one transfer and both become present`; `R-STO-3: a second producer of the same content never replaces a staged file under publication` |
| TR1-2 | major | Resolved, ADR-019: data tasks append into staging | `R-STO-1: a cancelled, paused or failed foreground transfer leaves no byte outside the store root` |
| TR1-3 | major | Resolved, §6.3: checksum-less transfers are never resumed; every staged file is hashed and the digest recorded (R-INT-6) | `R-NET-8: checksum-less transfers are never resumed` |
| TR1-4 | major | Resolved, ADR-019, §6.3: no URLSession resume data on the foreground path; −1002/416/validator mismatch → `resumeRejected`, partial discarded, fresh attempt | `R-NET-8: a refused or invalid resume discards the partial and restarts from zero in the next attempt` |
| TR1-5 | major | Resolved, ADR-019: sidecars hold only a validator; a resumed request is rebuilt with the current key | `R-NET-8: a resumed request carries the current key, never a stale one` |
| TR1-6 | major | Resolved, ADR-031 (`ForbiddenEvidence.keyPresented`, `PolicyViolation.keyWithheldOnRedirect` in the Model) | `R-NET-6: a 403 after the key was withheld on a cross-origin redirect is reported as keyWithheldOnRedirect` |
| TR1-7 | major | Resolved: `ForbiddenEvidence.hint` checks body shape before purpose (implemented) | `R-NET-6: every TransferError maps to one failure class and the documented AssetError` *(exists)*; `R-NET-6: an XML 403 on the manifest is object-missing-likely, never key rejection` |
| TR1-8 | major | Resolved: `SizeGuard` aborts on `byteSize` and treats −1 as unknown; written bytes measured in staging (implemented) | `R-NET-7: the size guard aborts when the written or announced size exceeds the cap or byteSize is exceeded` *(exists)* |
| T2-01 | critical | Resolved, ADR-019. The ~794 MiB of `CFNetworkDownload_*.tmp` left by earlier probes are outside the repository and must be removed by the human (§15) | `R-STO-1: a cancelled, paused or failed foreground transfer leaves no byte outside the store root` |
| T2-02 | critical | Resolved, ADR-013, §4.3 (as TR1-1) | `R-STO-3: a second producer of the same content never replaces a staged file under publication` |
| T2-03 | critical | Resolved, ADR-028: session → tasks → staging → reconcile → GC; `wanted` = applied entries not present; the fake driver delivers completions only on `activate()` | `R-NET-3: a download completed while the app was dead is adopted from staging, not re-downloaded`; `R-NET-3: an offline launch cancels no live background task` |
| T2-04 | major | Resolved, ADR-039, `RemoteSource.invalidate` contract: the foreground session returns after its delegate's last callback; invalidate before close. Narrowed in round 2: the background session is released without waiting, its late staging files are reconciled at the next launch, and `StagingSink` promises nothing after close (`StagingError.closed` removed) | `R-SYN-15: no foreground staging write lands after the store is closed` |
| T2-05 | major | Resolved, §6.4: the driver is decision-free (`cancel` returns the resume data; the coordinator records the pause intent) | `R-NET-3: a background pause is reported paused and keeps its resume data` |
| T2-06 | major | Resolved, ADR-013: `TransferAttempt(epoch, sequence)` with a persisted epoch | `R-NET-3: attempts from different launches order by launch epoch and never collide` |
| T2-07 | major | Resolved (as TR1-4) | `R-NET-8: a refused or invalid resume discards the partial and restarts from zero in the next attempt` |
| T2-08 | major | Resolved, ADR-021: a restart is a new attempt with a new handle | `R-NET-8: an invalid resume yields resumeRejected and the engine's next attempt starts fresh` |
| T2-09 | major | Resolved, ADR-026: `.acceptedByOwner` covers the key, the hop limit and the size cap (documented on `KeyRedirectExposure`) | `R-NET-3: a key-bearing transfer never uses the background session unless the owner accepted redirect exposure` |
| T2-10 | major | Resolved, §2: the coordinator's pump exists only while a background transfer is outstanding | `R-SYN-14: with background enabled and nothing outstanding the engine owns no task` |
| T2-11 | major | Resolved, ADR-028: the background session is created only by `start()` (or by background-event handling, which starts the client first) after the store is open; a background launch runs no sync unless one is due | `R-NET-3: handling background events before start opens the store first and runs no sync` |
| T2-12 | major | Resolved, ADR-032 (`TransientCause.sourceVersionSkew` in the Model) | `R-APL-4: a catalog and pack version skew is transient and never quarantines the asset` |
| T2-13 | major | Resolved, ADR-027: keep-scope exclusions (implemented in `PackReleasePlanner`) fed by the retention scope (`AssetClientConfiguration.retentionScope`, `setRetentionScope(_:)`, round 2), `StorageReport.sourceCopyBytes` fed by `RemoteSource.sourceCopyBytes()` (round 2), eviction ranking | `R-CLN-10: a media pack is released only after every catalog entry in it is adopted or excluded` *(exists)*; `R-CLN-10: entries outside the retention scope never block a pack release`; `R-CLN-9: storageReport counts bytes the OS still holds in adopted packs` |
| T2-14 | major | Resolved, §6.6: the update check is scheduled, never awaited before reading the installed catalog; pack availability is single-flight in an owned task | `R-APL-4: a hanging update check never delays reading the installed catalog` |
| T2-15 | major | Resolved, §11: the P-11 benchmark syncs through `ensureAvailable`, whose user-initiated batch lane may use every slot, reserved one included; the final commit flushes as soon as the P-5 window allows (§4.1) | `P-11: assets with server latency sync at least speedup_min times faster at the configured concurrency than at 1` |

### 12.6 Minor findings

| ID | Disposition |
|---|---|
| store-1 S1-14 | Accepted (ADR-015): ordered commits barrier-sync the temp file; `.full` only for durable commits; the I-5 checker states its model assumption. |
| store-1 S1-15 | Accepted: the `fsync` fallback applies only to ENOTSUP/EINVAL/ENOTTY (`LiveFileSystem` doc); table test `R-STO-6: every errno and Cocoa error maps to the closed FileSystemError taxonomy`. |
| store-1 S1-16 | Accepted (§4.1): generations allocated at capture; the auditor decodes the committed index. |
| store-1 S1-17 | Accepted (ADR-028): unpaired `.resume` files survive `stagingClaimGrace`; staging bytes count in the reserve check and `StorageReport.stagingBytes`. |
| store-1 S1-18 | Accepted (§4.7, ADR-029): non-following listing; EEXIST in phase 2 is dedupe after the existing blob is known durable; no snapshot before reconciliation; the EXDEV copy is hashed while copying. |
| store-2 S2-17 | Accepted (as store-1 S1-04). |
| store-2 S2-18 | Accepted: `makeRoom` continues past a newly leased candidate to the next LRU candidates, or rolls the marks back. |
| store-2 S2-19 | Accepted: access stamps are a catalog-bounded map delivered in `InstallAck.accesses`; future times clamped (`recordAccesses` doc). |
| store-2 S2-20 | Accepted (`AssetStore.purge` doc): terminates when each selected key is reaped, rescued or deferred by a lease; phase checked after every await. |
| store-2 S2-21 | Accepted (§4.7): vacuous truth excluded (no entries ⇒ stamp not migrated), `inProgress` resumes, and an overlap of legacy root and store root is refused at configuration. |
| store-2 S2-22 | Accepted (ADR-018): quarantine dooms as `corrupt`, never rescued. |
| store-2 S2-23 | Accepted (§4.5): a size contradiction dooms the name as `corrupt`; 7c skips it. |
| store-2 S2-24 | Accepted (§4.3): checksum-less publishes commit before returning. |
| store-2 S2-25 | Accepted (ADR-015): one retry after freeing `index.tmp`/`index.prev`; then `degradedReadOnly` with exponential retry on the engine's alarm; `requireCommitted` throws `.insufficientSpace`. |
| store-2 S2-26 | Accepted: live file-system tests and benchmarks use a per-test directory under the scratch path inside this repository (`.build-*/tmp-tests/`), never the system temp directory; `LiveLegacyDefaults` is the one deliberately untested seam (§14). |
| store-2 S2-27 | Accepted: a P-13 "batch" is one 64-unlink unit; deletable keys are kept in an ordered set so selection is O(batch). |
| sync-1 S1-16 | Accepted (§7.4): `pump()` loops after marking a victim. |
| sync-1 S1-17 | Accepted: drivers are spawned with the job's lane priority (`TaskPriority` mapped from `AssetPriority`) and promotion does not need to raise it (the transport's priority is the effective lever). |
| sync-1 S1-18 | Declined: a `cancel()` racing the registration hop may still start one request; the transfer is cancelled one actor turn later, which costs at most one request per swipe. Fixing it needs synchronous engine registration, i.e. a lock (`@unchecked`) the budget forbids. Measured cost is bounded and recorded for P-10. |
| sync-1 S1-19 | Accepted (ADR-023): progress keys retire with their transfer; subscribers are dropped at shutdown after `clientShutDown`, so `subscribers == 0` holds. |
| sync-2 S2-20 | Accepted (§7.4): `user.batch` preempts at most one transfer per batch and never starves prefetch beyond one slot. |
| sync-2 S2-21 | Accepted (§7.7): a cached 304 never resets the trip count. |
| sync-2 S2-22 | Accepted: the negative cache is LRU-bounded (`unknownIDCacheCapacity`), throttle keys retire with transfers, lane FIFOs compact. |
| sync-2 S2-23 | Accepted: `CapacityPurpose.opportunistic` for bulk and prefetch, `.important` for user work (`FileSystem.availableCapacity(at:for:)`). |
| sync-2 S2-24 | Accepted (§7.9): a trailing progress emission after a quiet period. |
| sync-2 S2-25 | Accepted: thermal hysteresis (`PowerPolicy.resumeBackgroundAtThermal`) and run-restart debounce (`SyncTuning.pendingRunDebounce`). |
| sync-2 S2-26 | Accepted (§14): one post-await revalidation funnel, the planner injectable (`SyncPlanning`, `SyncEngine.init(store:environment:configuration:planner:)`, added in round 2), illegal transitions counted rather than trapped in release. |
| sync-2 S2-27 | Accepted: `ManualTimeSource.pendingSleepers`, `nextDeadline`, `waitForSleepers(atLeast:)` exist (implemented). |
| sync-2 S2-28 | Accepted (§7.10, `AssetStore.admit` doc): point admission never stores an ETag. |
| sync-2 S2-29 | Accepted (§7.4): `interactiveConcurrencyAtCritical` enforced; `popValid(fitting:)` returns the first valid job whose known size fits the ledger, unknown sizes always fit. |
| transport-1 TR1-9 | Moot under ADR-019 (no archived requests on the foreground path); for background resume data the policy is checked against the archived current request. |
| transport-1 TR1-10 | Accepted: the request factory joins `baseURL` and a validated `remotePath` by percent-encoded path components only, rejecting `?`, `#` and encoded dot segments (`PolicyViolation.invalidURL`). |
| transport-1 TR1-11 | Accepted (ADR-031): 401/−1012/−1013 are `transient(.authenticationChallenge)`. |
| transport-1 TR1-12 | Accepted (implemented): `PackID` rejects `.` and `..`; `PackLocation` validates every component (`R-SEC-2: pack locations reject traversal, empty and dot segments and invalid pack ids` *(exists)*). |
| transport-1 TR1-13 | Accepted: allowed hosts are trailing-dot-stripped (implemented in `TransportSecurityPolicy`); oversize is classified before pause; one sidecar write per pause; foreign staging names are collected. |
| transport-2 T2-16 | Accepted (implemented): `BackgroundEventsRelay` and `SnapshotMirror` have `nonisolated init`. |
| transport-2 T2-17 | Accepted: the background task cap counts re-attached tasks; a handler is completed even when its events overflowed (completion after the staged-file reconcile). |
| transport-2 T2-18 | Accepted: Apple-tier writes go through `.parttmp` then an exclusive rename; `.resumetmp` is a parsed kind collected by GC (ADR-013). |
| transport-2 T2-19 | Accepted (implemented): `ForegroundTransferBackend.deinit` invalidates its session. |
| transport-2 T2-20 | Accepted: the catalog digest runs on the bulk executor; `ManifestFetchResult.notModified(removedSources:)` keeps removals (implemented in the Model). |
| transport-2 T2-21 | Accepted: `taskDescription` persistence across relaunch is listed as unverified (DEVICE-TEST-PLAN); there is no `guard`-line coverage device (the tier check is plain code whose `osSupportsAppleTier == false` decision is covered through `TierSelection.select`). |

## 13. Review dispositions

### 13.1 Contract-fix round 1

The independent review of the Stage 1 contracts raised 20 issues (11 blocking). Each is fixed as described, or partly declined with the reason given.

| # | Issue | Disposition |
|---|---|---|
| 1 | Build: targets declared without sources; staged deletions of the skeleton | **Fixed.** Contract sources for all 7 targets; 8 test targets with behaviour tests (37 in the normal run plus 1 in the benchmark target; none assertion-free); debug, release and iOS builds clean under `-warnings-as-errors`; `--quick` green. The git index still records the skeleton deletions; the orchestrator commits. |
| 2 | `TransferPurpose` undeclared | **Fixed.** `Sources/ZTronAssetModel/Transfer/TransferPurpose.swift`, as transport.md:246 specifies, documented. |
| 3 | `ARCHITECTURE.md` missing | **Fixed.** This document: §11 covers all 104 IDs with target, WP and test; §9 one section per H-n with decisions and exact test names; §10 the ledger; §3 every file on disk; §7.1 the state machine; §7.5 the priority table; §7.6 the error-to-action table; §7, §7.3, §7.5, §7.6, §7.7 and §3, the sections the code cites, exist. |
| 4 | ADRs cited but missing | **Fixed.** ADR-012…041, including every cited number (013, 017, 019, 020, 024, 025, 026, 027, 035, 036), NEEDS-HUMAN-REVIEW on layout, security, retention, defaults, shims and facade deviations. Storage location (SPEC §4.4) stays ADR-001; its numeric defaults are ADR-035. The R-CAR-6 shim location is ADR-033. Provisional design ADR numbers are mapped in DECISIONS.md. |
| 5 | Model types missing | **Fixed.** `Transfer/` (`RemoteSource`, `RemoteSourceFactory`, `TransferBackend`, `TransferHandle`, `TransferUpdate`, `TransferControl`, `TransferRequest`, `TransferJob`, `ManifestRequest`, `ManifestFetchResult`, `ETag`, `StagedFile`, `ReattachedTransfer`, `ResumeSidecar`, `ResumeData`, `StagingSink`), `Environment/` (`AssetEnvironment`, `BlockingExecutor` + `DispatchBlockingExecutor`, `FileSystem`, `LegacyDefaults`, `AppVersionSource`, `LogTap`, `MemoryPressureSource`), `Events/` (`AssetEvent`, `SyncProgress`, `TransferProgress`, `RetryDisposition`, `BlockReason`, `CircuitState`), `Reports/` (`AvailabilityReport`, `StorageReport`, `SyncReport`, `SyncOutcome`, `MetricsSnapshot`, `PurgeRequest`, `PurgeResult`, `AssetLocation`, `SyncStamp`, `PlanTotals`), `Tier/` (`TierInputs` with `osSupportsAppleTier`, `TierSelection`). |
| 6 | Storage contract missing | **Fixed, with one placement deviation.** `AssetStore` actor; `AssetSnapshot`, `SnapshotEntry`, `SnapshotKey`; `AssetRecord`, `Residency`, `DoomReason`; `StoreError` with its `AssetError` mapping; `SnapshotSink` + `InstallAck` (the acknowledgement proves what is installed); leases; `StoreStagingSink`; `LiveFileSystem`; `LiveLegacyDefaults`. **Deviation:** the `FileSystem` protocol, `FileSystemError` and `LegacyDefaults` are declared in the Model (ADR-038) because the single `AssetEnvironment` (SPEC §4.2) must hold them; their live conformers are in Storage, the only code that touches POSIX, `FileManager` or `UserDefaults`. Fault injection, the deterministic crash-point sequence, calling-thread recording and attribute recording are on `FakeFileSystem` (TestSupport); the free-space query is `availableCapacity(at:for:)`. |
| 7 | Sync contract missing | **Fixed, with one placement deviation.** `SyncPlanner.plan(manifest:snapshot:scope:policy:freeSpace:)`, `SyncPlan`, `PlannedFetch`, `ReconcileStep`, `SpaceAssessment`, `SyncEngine` (`awaitAsset`, `registerGroup`/`releaseGroup`, runs, introspection), `EngineIntrospection` (`package`, readable by benchmarks), `RefreshDecision`, `JobState`/`JobStateKind`, `CircuitBreaker`, `Backoff`, `LaneAdmission`, `TransferReconciler`. **Deviation:** `SyncStamp` is in the Model, because the store persists it inside the index (R-STO-2) and Storage cannot see Sync. |
| 8 | Transport, AppleHosted, Kit contracts missing | **Fixed.** Transport: `HTTPRemoteSource`, `SessionDelegate` (`Sendable` with `let`s only, no escape), `TaskMailbox`, `ForegroundTransferBackend`, `LiveDeviceConditionsSource`, `BackgroundSessionDriver` (decision-free) and `BackgroundSessionBackend.swift`, `BackgroundEventsRelay`, `TransportSecurityPolicy`, `RedirectPolicy`, `SizeGuard`, `TransferClassifier`. AppleHosted: `PackBackend`, `PackFileReader`, `PackID`, `PackLocation`, `PackError`, `PackReleasePlanner`, `AppleHostedRemoteSource` (`@available(iOS 26.0, macOS 26.0, *)` inside `#if canImport(BackgroundAssets)`), `LiveAssetPackBackend.swift`, `AppleHostedTier` (the single `#available`). Kit: `AssetClient`, `AssetClientConfiguration`, `SnapshotMirror`, `PrefetchHandle`, `PrefetchWindow`, `PrefetchWindowController`, `BundleLookup`, `AssetFallbackChain`, `handleBackgroundEvents`, `diagnosticReport`, `AssetEnvironment.live`. No URLSession is created in `AssetClient.init`. |
| 9 | TestSupport fakes missing | **Fixed.** All declared; `ManualTimeSource` (with `pendingSleepers`, `nextDeadline`, `wakeLog`, `waitForSleepers`, `sleepDevice`), `InlineBlockingExecutor`, `SeededRandom`, `FakeDeviceConditionsSource` (actor), `FakeLegacyDefaults`, `RecordingLogTap`, `FakeTransferHandle`, `FakeAppVersionSource`, `FakeRemoteSourceFactory` implemented; the rest are interfaces for WP-H. 0 escapes; Mutex fakes gated, tests gated per `@Test` (verified). |
| 10 | 86 critical/major review findings without resolution | **Fixed.** §12: every one resolved with its ADR or section and a named regression test; none rejected; minors dispositioned. |
| 11 | R-CAR-6 shims have no target | **Fixed.** `ZTronAssetCompatibilityTests` added to Package.swift (ADR-033) with `Shims/` (`CDNAsset`, `CDNSyncProgress`, `CDNRefreshPolicy`, `CDNProviding`) and three R-CAR-6 tests; the adapters over `AssetClient` are WP-G's in the same target. |
| 12 | `@available` on suites rejected | **Fixed.** ADR-014 records per-`@Test` gating (single-platform `@available(macOS 15.0, *)`), verified by `SyncContractTests`, `AppleHostedContractTests` and `KitContractTests`. |
| 13 | APPLE-API-VERIFICATION §3.2 inaccurate | **Fixed.** §3.2 and §0 Q3 corrected with build-manifest evidence and an ungated `.timeLimit` test (ADR-041); the macOS floor stays 12. |
| 14 | R-MAN-5 diff vs single-flight key | **Fixed.** `byteSize` dropped from `ContentIdentity.unverified` (ADR-034); test `R-MAN-5: a checksum-less entry changes content identity only when its remotePath changes`. |
| 15 | `MonotonicInstant.adding` | **Fixed.** `+infinity` saturates to `UInt64.max`; the headroom check runs in the integer domain with `addingReportingOverflow`; tested. |
| 16 | `ManifestDiff` cannot be applied; `change(of:)` O(n) | **Fixed in part.** The diff now carries `targetOrder` and `upserts` and offers `applied(to:)`; the R-MAN-4 property is tested. **Declined:** an index of the classes, because the five class lists are public mutable arrays and a second structure would have to be kept in sync by every mutator; `change(of:)` is documented as diagnostics and tests only. |
| 17 | `KeyRedirectExposure.acceptedByOwner` violates R-NET-4/R-NET-7 by opt-in | **Fixed as an owner decision.** ADR-026 (NEEDS-HUMAN-REVIEW) states the trade-off for the key, the hop limit and the size cap; the default stays `.refuse` and R-NET-4 tests cover it. The case is kept until the owner decides. |
| 18 | `CFNetworkDownload_*.tmp` outside the repository | **Fixed in the design** (ADR-019: data tasks; loopback tests and benchmarks use only the data-task path). **Not deleted:** the files are outside the repository; §15 gives the human the cleanup command. |
| 19 | Memory probes vs the unsafe budget | **Fixed.** ADR-040 and the `QualityBudgets.swift` doc comment: memory helpers live in `Tests/ZTronAssetKitBenchmarks`, never in `Sources/`. |
| 20 | Target dependencies of TestSupport | **Fixed.** `RemoteSource`, `TransferBackend` and `StagingSink` are in the Model; `FakePackBackend` is in `Tests/ZTronAssetAppleHostedTests`, `FakeBackgroundSessionDriver` in `Tests/ZTronAssetTransportTests` (ADR-040); TestSupport keeps its declared dependencies. |

Further amendments made while resolving the reviews: `TimeSource.uptimeNow()` (ADR-017), `InstallAck.retired` (sync-2 S2-12), `RemoteSource.handleBackgroundEvents(identifier:)` (R-NET-3 completion protocol), `ManifestFetchResult.notModified(removedSources:)` (transport-2 T2-20), `StagingFileName` is `Codable` (sidecars).

### 13.2 Contract-fix round 2

The second independent review of the Stage 1 contracts raised 12 issues (2 blocking). All 12 are fixed; nothing is declined. Where a fix deviates from the reviewer's suggested shape, the reason is given. ADRs: ADR-042…045 (new), ADR-014, ADR-027, ADR-038, ADR-039 (amended).

| # | Issue | Disposition |
|---|---|---|
| 1 | **Blocking.** R-SYN-15: APIs non-throwing after shutdown | **Fixed, option (a)** (ADR-042, NEEDS-HUMAN-REVIEW for the signatures). Facade: `start`, `availability`, `subscribe`, `isSyncDue`, `lastSyncedAt`, `storageReport`, `performMaintenance` (now returns `MaintenanceReport`), `reportUnreadable`, `metrics`, `diagnosticReport` are `async throws(AssetError)`; the engine methods return `Result<_, AssetError>` (`registerGroup`, `subscribe`, `backgroundSessionEventsPending` too). Shapes that cannot throw fail in their typed way: `sync` → `SyncOutcome.failed(.shutDown)` (kept non-throwing because its outcome already carries `AssetError`; a second channel would duplicate it); `prefetch` stays synchronous (P-8) and the handle gained `awaitRegistration() throws(AssetError)`; a new `events` stream yields `clientShutDown` and finishes; `lookup` returns `nil`; `register(_:)` throws. Releases and `shutdown()` stay idempotent. Tests: `R-SYN-15: every API called after shutdown fails with shutDown` (planned, §11) and `R-SYN-15: a prefetch handle made after shutdown reports shutDown and holds nothing` *(exists)*. |
| 2 | **Blocking.** `.stage(Data)` cannot reach the store's staging sink | **Fixed as suggested** (ADR-045): `StagingAttachable` (ungated) in TestSupport, `FakeRemoteSource` conforms (`attach(staging:)`, `attachedStaging`), `FakeRemoteSourceFactory.makeRemoteSource` attaches before returning (a cast, no `#available`). `.stage(Data)` is specified to write through the sink (`createPartial`, `appendPartial`) and report `.staged`; without a sink it fails with `transient(.localIO)`. Test `R-NET-1: FakeRemoteSourceFactory hands the store's staging sink to an attachable source before returning it` *(exists)*. |
| 3 | `PrefetchHandle` re-lane: deinit releases before the successor registers (S1-05 regression) | **Fixed; failing test first.** `cancel(after:)` now runs its ordered release in a task that holds `self`, so the deinit release runs after it and is a no-op (the registry ignores released tokens, which are never reused). `PrefetchRegistry` (Kit, `SyncEngine` conforms) makes the handle testable with a slow-registration fake. `R-CAR-3: a re-laned prefetch handle releases its old interest only after the successor registered` recorded 4 issues against the round-1 logic (`released != nil`, holders, log order, `minimumHolders == ["a": 1]`) and passes on the fix; `R-CAR-4` deinit and early-cancel tests added. |
| 4 | `StorageReport.sourceCopyBytes` unreachable from Sync | **Fixed as suggested:** `RemoteSource.sourceCopyBytes() async -> Int64`; `HTTPRemoteSource` returns 0 (implemented); `AppleHostedRemoteSource` sums `PackBackend.installedBytes` of adopted, unreleased packs (WP-E stub); `FakeRemoteSource.setSourceCopyBytes(_:)` (implemented); `SyncEngine.storageReport()` documents the fill (RE-S32). |
| 5 | No atomic durable adoption report | **Fixed** with a narrower signature: `AssetStore.adoptionReport() async throws(StoreError) -> AdoptionReport`. The exclusions come from the store's retention scope (issue 6) instead of an `excluding:` argument, so eviction and release read one source of truth. §4.6a, §6.6, REENTRANCY R15 and RE-S34. |
| 6 | No keep/retention scope | **Fixed with both suggested forms:** `AssetClientConfiguration.retentionScope` (default `.all`) and `EngineConfiguration.retentionScope` for launch, plus `AssetClient.setRetentionScope(_:)` / `SyncEngine.setRetentionScope(_:)` / `AssetStore.setRetentionScope(_:)` for paywall changes at run time (a configuration value alone could not follow a purchase). It scopes bulk runs, orders eviction and feeds `excludedRemotePaths`; it deletes and fetches nothing. Recorded in ADR-027. |
| 7 | `StagingSink` `.closed` unimplementable; background invalidate waits for hours | **Fixed as suggested:** the `.closed` promise **and** the then-unproduced `StagingError.closed` case are removed; `StagingSink` documents the T2-04 ordering instead. `RemoteSource.invalidate` waits only for the foreground delegate (and the Apple source's `writeStaged`); the background session is released without waiting and late files are reconciled at the next launch (ADR-028, ADR-039). The test is narrowed to `R-SYN-15: no foreground staging write lands after the store is closed`. |
| 8 | Seams for H-5, snapshot acks, census waits, planner | **Fixed as suggested** (ADR-045), and implemented with tests: `SteppedBlockingExecutor` (actor), `ScriptedSnapshotSink` (package actor), `FakeDeviceConditionsSource.waitForObservers(equalTo:)`, plus `FakeMemoryPressureSource`; `SyncPlanning`/`StandardSyncPlanner` and `SyncEngine.init(store:environment:configuration:planner:)`. |
| 9 | R-CLN-11, pins, diagnostics have no entry point | **Fixed** (ADR-044): `@MainActor register(_:) throws(AssetError)` / `unregister(_:)` over `PurgeableCacheRelay` (weak, epoch-ordered; implemented and tested) and `SyncEngine.observeMemoryPressure(epoch:handler:)` (one owned observer only while a live cache is registered); `pin(_:)` / `unpin(_:)` through `SyncEngine.setPinned(_:pinned:)`; `SyncEngine.diagnostics() -> Result<EngineDiagnostics, AssetError>` (async, because it reads the store's generation and stamp). `DiagnosticError` moved to the Model. |
| 10 | `AssetLog` unreachable below the facade; `LogLine` has no subsystem | **Fixed as suggested** (ADR-043): `AssetLog` in `ZTronAssetModel/Environment/AssetLog.swift` with `hashed(_:)`, `emit(_:tap:)` and `log(_:_:_:tap:)`; `LogLine.subsystem`. Test `R-OBS-1: log lines carry the module subsystem and their category and render identifiers as stable hashes` *(exists; logs at `.debug`, which the unified log does not persist by default)*. |
| 11 | C2 in `prepare(kinds:)` and `LiveAppVersionSource`; R-STO-6 scope; `static var live` | **Fixed:** the bundle enumeration runs in one unit on the client's bulk executor (an internal accessor, same module); `LiveAppVersionSource(executor:)` reads `Info.plist` on the metadata executor; ADR-038 records R-STO-6's scope; `.live` became `static func live(legacyDefaultsSuiteName: String? = nil)` and `init`'s default is `.live()`. |
| 12 | ADR-014 option (d) vs the single `#available`; device-only line share | **Fixed:** option (d) rejected in ADR-014, and the R-APL-5 scan is stated to cover all of `Sources/`. Device-only files get a working ceiling of **100 executable lines each** (§14), and the first Stage 2 coverage run must report the `device-only-excluded` share; today both files are stubs (53 and 41 source lines). |

Further amendments made while resolving this review: `EngineIntrospection.memoryPressureObserverActive`, `EngineDiagnostics`, `AssetStore.setRetentionScope(_:)`, `PrefetchHandle` is built through `package init(registry:ids:priority:)`.

## 14. Coverage plan and seams (Q-2)

- **Excluded (device-only):** `Sources/ZTronAssetTransport/BackgroundSessionBackend.swift` and `Sources/ZTronAssetAppleHosted/LiveAssetPackBackend.swift`, each a thin, decision-free conformer (SPEC ceiling ≤ 250 lines; 53 and 41 source lines today). `ZTronAssetTestSupport` is excluded. **Working ceiling: 100 executable lines per file** (contract-fix round 2, issue 12). Both files compile on the macOS host (BackgroundAssets is importable on macOS 27), so llvm-cov counts their lines against `device_only_max_lines_fraction` (3 %): two files at the 250-line SPEC ceiling would need about 16,000 production lines to pass, while 200 executable lines need about 6,500. Measured in round 2 over the stub contracts (the gate's own export over all 8 test bundles, into `.build-probe-cfix2/`): `COVERAGE device-only-excluded lines=50 share=1.56% max=3.0% OK`, against 3,162 counted production lines. The first Stage 2 coverage run reports the share again (`COVERAGE device-only-excluded … share=`), and a WP whose file grows past 100 executable lines moves logic into the tested side (`BackgroundTransferCoordinator`, `AppleHostedRemoteSource`).
- **Every other production line runs on macOS with fakes.** Storage: `FakeFileSystem` + `InlineBlockingExecutor` + `ManualTimeSource`; `LiveFileSystem` against per-test directories **inside this repository** (under the scratch path), never the system temp directory; the errno and Cocoa-error mappings are pure functions. Sync: `FakeRemoteSource` (attached to the real store's staging sink by `FakeRemoteSourceFactory`, ADR-045), `FakeDeviceConditionsSource` and `FakeMemoryPressureSource` (census waits), a real `AssetStore` over `FakeFileSystem`, `SteppedBlockingExecutor` to hold store units, `ScriptedSnapshotSink` where the facade's mirror is out of reach; one post-await revalidation funnel, an injectable planner (`SyncPlanning`), illegal transitions counted (sync-2 S2-26). Storage: the same executor and sink for the REENTRANCY rows R2–R15. Transport: the loopback server (data tasks), `FakeBackgroundSessionDriver`, the `.background` delegate paths driven through a foreground session, pure classifier/parser/guard tables, `LiveDeviceConditionsSource` on the host. AppleHosted: `FakePackBackend`. Kit: a real client over fakes; `PrefetchRegistry` fakes for handle ordering; the cache relay directly.
- **Known deliberately untested lines:** `LiveLegacyDefaults` (3 lines): exercising it would write `~/Library/Preferences`, outside this repository (owner directive).
- **Budgets per target:** Storage and Sync ≥ 90 %, every other production target ≥ 70 %, overall ≥ 80 % (`Scripts/quality-gates.json`). Not measured in this round (contracts are stubs); the first coverage report comes from Stage 2.
- **Not verified here (goes to `VERIFICATION.md` / `DEVICE-TEST-PLAN.md`):** any iOS 15 *runtime* behaviour (compile-time only), background-session relaunch re-attachment, Apple-hosted packs end to end, `taskDescription` persistence across relaunch, `F_BARRIERFSYNC`/`F_FULLFSYNC` semantics and costs on device, file protection on device, real network transitions, HTTP/2 against CloudFront.

## 15. Hygiene items for the human (outside this repository)

Nothing in this round wrote outside the repository on purpose, and this package must never do so. Two items need the owner, because CLAUDE.md forbids agents to delete outside the repository:
1. **`CFNetworkDownload_*.tmp` partials** left by earlier Stage 1 probes (download tasks, the defect ADR-019 removes): 762 files in the per-user temp directory at the time of this round (about 794 MiB per the transport-2 review). Remove with `rm "$(getconf DARWIN_USER_TEMP_DIR)"CFNetworkDownload_*.tmp`.
2. **Two xcodebuild error result bundles** created by this round's contract author when two mistyped `xcrun --sdk` invocations failed (the SDK name and target were passed as one word): `/var/folders/7y/s6b_jp997bl6j5yw9d17lvfm0000gn/T/ResultBundle_2026-04-10_11-28-0015.xcresult` and `…-0016.xcresult`. Remove with `rm -rf /var/folders/7y/s6b_jp997bl6j5yw9d17lvfm0000gn/T/ResultBundle_2026-04-10_11-28-001{5,6}.xcresult`. Every later command of this round set `TMPDIR` and the Swift module cache to `.build-probe-cfix1/` inside the repository.

Toolchain side effects of the mandated harness commands themselves (SwiftPM and Xcode caches under `~/Library`) are outside this package's control and are not changed by this round.

Contract-fix round 2 wrote nothing outside the repository on purpose: `xcodebuild` and the iOS typecheck ran with `TMPDIR` and the module cache under `.build-probe-cfix2/`, builds used `.build-cfix2`. The test `R-OBS-1: log lines carry…` emits one `.debug` line through `os.Logger`; the unified log keeps debug lines in memory only by default.
