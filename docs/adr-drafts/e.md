# WP-E (Apple-hosted tier) — ADR drafts and proposed REENTRANCY rows

Owner: WP-E, Stage 2, level L2. Scope: every WP-E stub in `Sources/ZTronAssetAppleHosted` (`AppleHostedRemoteSource`,
`LiveAssetPackBackend`), the tier's tests and `FakePackBackend` in `Tests/ZTronAssetAppleHostedTests` (ADR-040). No
public or package signature changed (checked against tag `contracts`); every new type is internal. The orchestrator
numbers these into `DECISIONS.md` and ARCHITECTURE §10 at merge.

New internal files: `AppleSourceState.swift` (the source's only mutable state, an actor), `PackAvailabilityCoordinator.swift`
(single-flight `ensureAvailable`), `PackCopier.swift` (every staging call), `AppleCatalogReader.swift`, `PackTransfer.swift`
(handle, stop request, driver), `HashingChunkSource.swift`, `PackProgressScaler.swift` (+ `PackProgress(snapshotOf:)`),
`PackErrorMapping.swift`, `FileHandleChunkReader.swift` (the live reader's mechanics, plus `PackUpdateCheck(updatingIDs:removedIDs:)`),
`ReleaseSurvey.swift` (fix round 1: the sliced release decision, E-16). Fix round 1 also changed the **bodies** of two
contract types in `PackTypes.swift` (`PackID.init?(rawValue:)`, `PackLocation.init?(remotePath:)`; no signature
changed, E-15) — flagged for the orchestrator. The L2 close-out changed the **body** of the contract function
`AppleHostedTier.resolve` (it now delegates to an internal overload that takes the tier decision as a test seam;
the public signature is unchanged, E-13) — flagged likewise.

## E-1 — The catalog digest and the asset check are computed inside the staging pull

- **Context.** transport-2 T2-20: a one-shot SHA-256 of a catalog at the 32 MiB cap takes 10.75 ms on the pool (C2);
  the accepted fix is "the catalog digest runs on the bulk executor", but `StagingSink.writeStaged` returns only a
  size and the source has no `BlockingExecutor`. T2-12 needs the source to tell catalog/pack skew from a good copy.
- **Options.** (a) Hash `readStaged`'s `Data` on the pool in 1 MiB slices with `Task.yield()` (C2-compliant, not on
  the bulk executor). (b) Change `writeStaged` to return a digest (contract change). (c) Wrap the pack reader in a
  `ChunkSource` that hashes each chunk as the sink pulls it — the pull runs inside the store's bulk executor in
  ≤ 1 MiB units.
- **Decision.** (c), `HashingChunkSource`. Its hasher lives in a `Synchronization.Mutex`, which is legal here because
  the type is `@available(iOS 26.0, macOS 26.0, *)` like the whole tier (iOS 26 ⊃ iOS 18). APPLE-API-VERIFICATION §4.7
  ("no Mutex in production") is read as applying to floor-15 code; the iOS build under `-warnings-as-errors` proves the
  gating. The same digest is the catalog's pseudo-ETag and the asset's checksum comparison (E-4).
- **Consequences.** No contract change, no pool hashing. An asset copied from a pack is hashed twice (here and by the
  store's publication hash, which never trusts a source, R-INT-2): one extra SHA-256 pass per Apple-tier adoption,
  on the bulk executor.

## E-2 — Pseudo-ETag format

- **Decision.** `"sha256:<64 lowercase hex>"` **including the double quotes**, so the value looks like a strong HTTP
  tag (transport.md §11.2 writes `"\"sha256:<hex>\""`). 73 printable bytes, always a valid `ETag`. `ifNoneMatch` equal
  to it → `.notModified(removedSources:)`.

## E-3 — The update check is source-owned, scheduled after the read, never awaited

- **Context.** transport-2 T2-14 fix: "Read the installed catalog first. Run the update check best-effort in a
  source-owned task, and report its `removedSources` on the next fetch."
- **Decision.** `fetchManifest` (1) snapshots what *finished* checks found (`AppleSourceState.checkReport()`),
  (2) reads the installed catalog, (3) schedules one `checkForUpdates()` in a task the state actor owns, single-flight
  (no second check while one runs), only when `request.allowsUpdateCheck && configuration.updateCheckOnManifestFetch`,
  (4) on success reports the snapshot and acknowledges it. `removedSources` = pack ids removed by checks that finished
  before the fetch began and that no earlier successful fetch reported (each reported once, on `notModified` too,
  T2-20; kept across a failed fetch). `origin = .installedPack(updateChecked:)` is `true` only when the last finished,
  not yet reported check succeeded. A skew (E-4) also schedules one check. `invalidate()` cancels the check, never
  awaits it (the OS may not return, AAV §5).
- **Consequences.** The first fetch of a process always says `updateChecked: false`; a hanging check never delays a
  fetch (tested). Removals reach prune one fetch late, which is what the review asked.

## E-4 — Catalog/pack skew is transient (T2-12, ADR-032); deviation from transport.md §11.3 step 4

- **Decision.** Each of these is `transient(.sourceVersionSkew)`, discards the staged copy, and schedules one
  best-effort update check: the staged SHA-256 differs from the checksum a content `TransferID` (`c-<hex>`) encodes;
  the staged size differs from `expectedBytes`; the pack file is larger than `expectedBytes` (the copy is capped at
  `expectedBytes` when it is known and ≤ `maxBytes`, so it stops early); the file is still missing after the pack
  was made available. transport.md §11.3 step 4 said `permanentMissing(404)` for the last case; that would persist a
  404 until the catalog entry changes (R-NET-6), i.e. exactly T2-12's Timeline A, so ADR-032's rule wins.
  `packNotFound` from `ensureAvailable` (the system does not know the pack) stays `permanentMissing(404)`
  (AAV §1.8). A file over `maxBytes` when the catalog size is unknown or over the cap is `integrity(.oversize)`, as on
  HTTP. Legacy (`l-`) transfers carry no checksum and are checked by size only.
- **Consequences.** A publisher error (catalog checksum wrong for good) is retried with backoff instead of quarantined;
  the engine's breaker and backoff bound it. Never integrity from the source for skew.

## E-5 — Error mapping (`PackErrorMapping`, pure)

- **Decision.** `packNotFound`/`fileNotFound` → `permanentMissing(404)`; `tooLarge` → `integrity(.oversize)`;
  `readFailed` → `transient(.localIO(EIO))`; `.system(domain, code)`: `NSURLErrorDomain` keeps the connectivity rows
  of transport.md §3.4.2 (−1009/−1018/−1019/−1020 offline; −1001, −1005, −1004, −1003/−1006, −1011/−1017, −1200…−1206
  transient) and every other code is `transient(.unknown(code))`; any other domain is `transient(.unknown(0))` (the
  domain and code go to the `apple` log), except a full disk (fix round 2): `NSPOSIXErrorDomain` `ENOSPC` and
  `NSCocoaErrorDomain` `NSFileWriteOutOfSpaceError` (640) are `insufficientSpace(requiredBytes: nil)`, so the engine
  runs its space handling (§7.6: `blocked(.awaitingSpace / .insufficientSpace)`) instead of backing off into a full
  device. Which errors BackgroundAssets really throws stays UNVERIFIED (AAV §1.8; request below). Rows of §3.4.2 that would yield `integrity` or `rejected` are deliberately
  not reused: an undocumented pack error is never integrity (AAV §1.8). Staging: `insufficientSpace` →
  `insufficientSpace(expectedBytes)`, `io` → `localIO`, `nameInUse` → `localIO(EEXIST)` and the file is **not**
  discarded (it is someone else's). Reader open: `packNotFound` → `.notInstalled`, `fileNotFound` → `.notFound` (both
  make the source make the pack available), others → `.system`/`.readFailed`.

## E-6 — Single-flight pack availability (`PackAvailabilityCoordinator`)

- **Decision.** One flight (a coordinator-owned task) per pack runs `ensureAvailable`; callers wait on continuations
  registered on the actor and resumed exactly once by `complete`, `leave` (the caller's cancellation handler) or
  `close`. A cancelled caller leaves at once; the flight is cancelled only when its last waiter left (T2-14 Timeline B).
  Progress fans out as values to every waiter; the outcome is delivered only after every progress value was, so a
  waiter's stream is complete before its terminal element. Stale flights are ignored by flight id. The flight itself
  runs in `PackFlight` (a non-actor enum, fix round 1) so no await of it sits lexically inside the actor. Progress
  streams (flight → coordinator, coordinator → driver) buffer the newest **64** values (fix round 1): progress only
  grows and is quantised afterwards, so dropping the oldest keeps memory bounded however chatty the OS is; the
  verifier proposed `.bufferingNewest(1)`, which would make the delivered sequence depend on scheduling and every
  progress test flaky, while 64 keeps a test's short burst whole.
- **Consequences.** If the OS ignores cancellation, a cancelled flight's task lives until the OS returns (UNVERIFIED,
  AAV §5); nobody waits on it and a new caller starts a new flight. Tested (fix round 1): such a flight's outcome and
  progress never reach a newer flight's waiter (`FakePackBackend` step `holdIgnoringCancellation`). The stale branch
  of `broadcast` is **not reachable through the source deterministically**: cancelling a flight's task also ends its
  progress stream (an `AsyncStream` iterator returns `nil` when its task is cancelled), so a stale value is at most
  one already taken from the stream when the cancellation landed — a scheduling race. The guard stays (defence for
  that one value). Fix round 2: `broadcast` is the coordinator's internal interface to its flights, so a test now
  calls it with an id that is not the current flight's while a waiter waits and expects only the current flight's
  progress (`R-APL-2: progress reported under another flight's id never reaches the current flight's waiters`;
  removing `flight.id == flightID` fails it). The flight-id guard is now covered and verified.
- **Declined (fix round 2): re-adopting abandoned flights.** If the OS ignores cancellation (UNVERIFIED), each round
  of "last waiter leaves, a new one joins" during one download leaves one more abandoned flight (its OS await and
  its `statusUpdates` watcher) alive until the OS download ends. Re-adopting a cancelled-but-running flight is not
  safe: when the OS **does** honour cancellation (the case AAV §5 expects), that flight ends with the cancellation
  error, which the new waiter would receive as a spurious failure. A grace period before cancelling needs a clock
  the source does not have (C4: no `TimeSource` reaches a `RemoteSource`) and contradicts T2-14 Timeline B. The
  growth is bounded by the swipes made during one download and freed when it ends; the observation ("abandoned
  flights per swipe while a pack downloads") is requested for DEVICE-TEST-PLAN next to AAV §5 (below).

## E-7 — Progress (R-APL-2)

- **Decision.** `PackProgress(snapshotOf: Foundation.Progress)` reads `completedUnitCount`/`totalUnitCount` once at the
  live boundary (D-12); an indeterminate total becomes 0/0; completed is clamped. `PackProgressScaler` reports
  `fraction × expectedBytes`, quantised to steps of 1 % of the asset **rounded up** (plus the final value), monotonic,
  ≤ the asset size, so at most 101 progress elements per waiter: after the first value at most 100 full steps fit
  below the size, and a final partial step replaces one. No progress for an unknown or zero `expectedBytes`.
  (Fix round 1: the step used to round down, so assets of 100…~300 bytes got up to ~2× that; a test now feeds sizes
  1…10,001 one unit at a time and the property test's bound is 101.) Fix round 2: the value is exact 128-bit integer
  arithmetic, `total.dividingFullWidth(expectedBytes.multipliedFullWidth(by: completed)).quotient` (at most
  `expectedBytes` because `completed ≤ total`, so it cannot overflow). The `Double` product trapped for sizes within
  512 bytes of `Int64.max` (reachable through the public `transfer` and an uncapped `ManifestLimits.maxAssetBytes`)
  and was inexact (0.29 × 100 → 28); regression test with `expectedBytes = Int64.max`.

## E-8 — Transfer handle controls

- **Decision.** `pause()`/`cancel()` record the first stop in a `Mutex` (iOS 26 code, E-1) and cancel the driver
  task; the driver alone yields the single terminal element (`.paused(resumable: false)` — packs never resume — or
  `.failed(.cancelled(.byClient))`), discarding a copy that completed meanwhile. A consumer dropping the stream
  (`onTermination(.cancelled)`) is a cancel. `setPriority` is a no-op (`supportsPriority == false`).
- **Fix round 1.** (a) A copy stops at its next chunk once the stop is requested: `HashingChunkSource` asks a
  `shouldStop` closure before every chunk and throws a source failure (domain `ZTronAssetAppleHosted.copyStopped`,
  `ECANCELED`), so the sink aborts at the next ≤ 1 MiB unit and removes its temporary file; the copier recognises the
  stop by the reader's flag (`PackCopier.Outcome.stopped`). A stop before a copy thus opens no pack file (tested), which
  also covers "check the stop before each copy" without a second, race-only check. (b) `deliver` checks the terminal
  yield: when the consumer dropped the stream between the stop check and the yield, a `.staged` copy is discarded
  (tested through `deliver` on an ended stream; the race itself has no suspension point to hold).
- **L2 close-out (verifier round 3, non-blocking).** "Terminal claimed" and "stop requested" are now one decision
  under the stop's `Mutex`: the driver calls `PackTransferStop.claimTerminal()`, which marks the terminal claimed and
  returns the stop recorded so far; `request(_:)` records nothing after the claim. A pause or cancel therefore either
  lands before the claim and becomes the terminal element (`.paused(resumable: false)` /
  `.failed(.cancelled(.byClient))`, a staged copy discarded) or lands after it and is a no-op, as a control after the
  terminal element is (ADR-021); nothing between the claim and the yield is visible to the consumer. The
  post-attempt step is `PackTransferDriver.conclude(_:)` (since cycle 3 it takes the proposed terminal element, E-10),
  a documented test seam (E-13): `PackTransferStopTests`
  stages a copy, records a stop and concludes (cancel and pause both end stopped and discard the copy), concludes
  and then records a stop (ignored, copy intact), and races a request against a claim 500 times (the stop is
  recorded exactly when the claim reports it). The verifier could not reproduce the original window (no suspension
  point); the old code has no claim, so the new tests failed to compile against it rather than failing at run time.

## E-9 — Shutdown (`invalidate()`)

- **Decision.** `AppleSourceState` admits every staging call (`PackCopier`); `invalidate()` closes admission, closes
  the coordinator (every pack waiter ends `.cancelled`), cancels the update check, then drains: it returns after every
  admitted staging call returned. After that, transfers and fetches fail `.cancelled(.byClient)` without touching
  staging. Fix round 1: closing also requests `AppleSourceState.shutdown`, so a copy in flight stops at its next
  chunk and removes its file (the drain no longer waits for whole pack files, possibly hundreds of MB on the serial
  bulk executor); a copy that had already written its last chunk finishes, and if its transfer was stopped its file
  is left for the next launch's staging GC (ADR-028). Tested for transfers and for the catalog.

## E-10 — Releases: once per catalog generation, in memory · NEEDS-HUMAN-REVIEW (residual)

- **Decision.** `reclaimSourceCopies` plans with `PackReleasePlanner` (keep-scope = `excludedRemotePaths`), marks
  planned packs in flight (a concurrent reclaim never plans them again), removes them in order, and counts a
  `packNotFound` removal as released. The released set is per **catalog generation** (the catalog pseudo-ETag of the
  last successful fetch); a new digest clears it. A failed removal is reported in `ReclaimReport.failed` and planned
  again next time. An invalid `catalogPackID` releases nothing. **A pack is released at most once per pack per
  catalog generation and is never re-armed within one** (ADR-027 literally; orchestrator ruling, L2 close-out
  cycle 3, below): a pack that comes back after its release — restored by the OS, or downloaded again on demand by a
  transfer of this source, whatever that transfer ended with — stays installed until the next catalog generation,
  and its `installedBytes` keep counting in `sourceCopyBytes()` meanwhile (E-11).
- **Fix round 1.** (a) The first digest of a process does **not** start a new generation: releases made before the
  first successful fetch (an offline launch's maintenance) belong to the generation it opens, so they are neither
  repeated nor reported twice (tested). Generations are a counter bumped when the released set is cleared, and a
  release counts only for the generation it was planned in. (b) *Withdrawn in L2 close-out cycle 3.* A transfer
  whose pack wait ended `.available` forgot the pack's release, so the pack was released once more in the same
  generation once its entries were adopted again.
- **History of (b), all superseded by the cycle 3 ruling.** L2 close-out (verifier round 3, blocking, PROBE-R3-1):
  (b) as first written re-armed the release for a file missing from the pack too (skew), so each maintenance run
  removed the pack and each retry downloaded it again (probe: 3 skewed transfers, 4 releases, 4 removals); it was
  narrowed to a downloaded pack whose copy staged (`conclude` forgot the release for a `.staged` terminal element).
  Fix round 2 (verifier PROBE-R2-3): a forget arriving while that pack's release call ran was remembered
  (`forgottenWhileReleasing`). The close-out verifiers then showed that even the narrowed (b) still looped and could
  fire for a copy nobody received: PROBE-C1-1g (an entry the retention scope excludes but the pack holds, viewed on
  demand: 4 request-then-reclaim rounds in one generation, `released=5 removes=5 mediaEnsures=4`) and PROBE-C1-6
  (`conclude` re-armed the release before `run()` yielded, so a consumer dropping the stream in that window left the
  release re-armed although the staged copy was discarded: `copyDelivered=false released=2 removes=2`).
- **Orchestrator ruling (L2 close-out cycle 3).** ADR-027's decision stands literally: a pack is released at most
  once per pack per catalog generation and is never re-armed within a generation; E-10(b)'s re-arm is withdrawn. A
  pack downloaded again on demand after its release stays installed until the next catalog generation, and its
  `installedBytes` keep counting in `sourceCopyBytes`. This removes PROBE-C1-1g's whole-pack re-download loop and
  PROBE-C1-6's re-arm-before-yield defect together.
- **Implementation (cycle 3).** The re-arm path is deleted: `AppleSourceState.forgetRelease`, its
  `forgottenWhileReleasing` set and the check in `finishRelease` (a release call's success now always counts for the
  generation it was planned in, even when a transfer downloaded the pack around the removal), and the driver's
  `AttemptResult.downloaded` with the forget in `conclude` (`conclude(_:)` now takes the proposed terminal element and
  touches no release). Tests, each run against the old code first (`Test run with 100 tests in 14 suites failed
  after 0.379 seconds with 23 issues`; the four below failed with 11, 3, 5 and 4 issues, in this order), then green:
  - new, `R-CLN-10: requesting an excluded asset after its pack's release removes the pack once per catalog
    generation, never in a loop` (PROBE-C1-1g's timeline: 4 rounds, then a new catalog generation releases it once
    again, then 2 more rounds; one removal and one download per generation);
  - replaces `R-CLN-10: only a delivered staged copy re-arms the release of a pack downloaded on demand` (it asserted
    the withdrawn re-arm): `R-CLN-10: a copy staged from a pack downloaded on demand that reaches no consumer leaves
    the pack released for the generation` (PROBE-C1-6, driven through `PackTransferDriver.run()` over a stream nobody
    holds);
  - replaces `R-CLN-10: a released pack that a transfer downloaded again is released again once adopted`: `R-CLN-10: a
    released pack a transfer downloaded again for an adopted asset stays installed until the next catalog generation`
    (same timeline; now the pack stays, its bytes count, and the next generation releases it);
  - replaces `R-CLN-10: a pack a transfer downloaded again while its release call was running is released again once
    adopted`: `R-CLN-10: a pack a transfer downloaded again while its release call was running stays released for that
    generation` (same `holdRemove`/`releaseRemove` timeline; one removal until the next generation).
  `R-CLN-10: a transfer that ends in skew never re-arms its pack's release within a catalog generation` (PROBE-R3-1)
  is unchanged and still passes. None of the replaced tests is a pre-existing CDN test (G3); each assertion they lose
  is the withdrawn behaviour, and each replacement asserts the ruled one on the same timeline.
- **Consequence.** An asset viewed on demand after its pack's release keeps the whole pack installed for the rest of
  the catalog generation (bounded: one download and one removal per pack per generation, never a loop). For WP-F: a
  pack id can appear in `ReclaimReport.released` again in a later generation; the engine must treat `released` as
  "removed now", not as a set it accumulates without duplicates.
- **(c) Declined.** Keying generations on the digest the **engine applied** (a fetched catalog the engine rejects
  also starts a generation here) needs that digest in `AdoptionReport` — a contract change.
- **Residual.** transport-2 T2-13 fix 5 asked to persist `alreadyReleased` in `index.bin`; no contract field exists, so
  it lives in memory. Effect: after a relaunch, a pack the OS re-downloaded may be released once more per process
  (bounded: once per pack per process, never a loop within one). Persisting it needs a store field (orchestrator).
  Orchestrator ruling (L2 close-out): released packs stay tracked in memory, once per process; persisting them is
  deferred (this entry stays NEEDS-HUMAN-REVIEW). The optional `AdoptionReport` digest field of (c) is declined.

## E-11 — `sourceCopyBytes()`

- **Decision.** Media packs (never the catalog pack) with at least one adopted entry in the **last**
  `AdoptionReport` the source received, summed from `PackBackend.installedBytes` (`nil` → 0, negative clamped). 0
  before the first report. Fix round 1: released packs are **no longer subtracted** — `installedBytes` is `nil` for a
  removed pack (fake and live: no `.downloaded` status), and a released pack a transfer downloaded again really holds
  bytes twice on the device, which `StorageReport.sourceCopyBytes` must show (R-CLN-9; regression test from the
  verifier's PROBE-1). Since cycle 3 (E-10) such a pack stays installed, and counted, until the next catalog
  generation releases it. Adopted entries are found among the manifest entries (`AdoptionReport` documents adopted paths
  as entries of the applied manifest), see E-16.
- **L2 close-out (verifier round 3, non-blocking, PROBE-R3-2).** The sum saturates at `Int64.max`
  (`addingReportingOverflow`): `PackBackend` is public and injectable, and two packs reporting `Int64.max / 2 + 1`
  bytes trapped the process (SIGTRAP; the test `R-CLN-9: sourceCopyBytes saturates instead of trapping when the
  installed sizes sum past Int64.max` crashed the test helper with signal 5 before the fix). Negative sizes still
  count as 0.
- **Limitation (fix round 2, handed to WP-F).** The adopted packs are known only from an `AdoptionReport`, which only
  `reclaimSourceCopies` delivers, and they live in memory: a fresh source (every launch) reports 0 until its first
  reclaim, as does a source whose `catalogPackID` is invalid (it releases and records nothing). `RemoteSource` has no
  other way to hand the report over without a contract change. So the engine must run `reclaimSourceCopies` (its
  maintenance step) before the first `storageReport()` it answers, and WP-F's
  `R-CLN-9: storageReport counts bytes the OS still holds in adopted packs` (RE-S32) should cover a fresh source
  instance (request below).

## E-12 — `LiveAssetPackBackend` (device-only, coverage-excluded)

- **Decision.** Only the verified 26.0 surface (AAV §1.1, re-checked against the installed macOS 27 SDK interface
  lines 77, 123, 124, 129, 135, 147, 152, 157, 166–167, 266, 280). `ensureAvailable`: a watcher task maps
  `statusUpdates(forAssetPackWithID:)` `.downloading` to `PackProgress(snapshotOf:)` and is cancelled when
  `ensureLocalAvailability(of: assetPack(withID:))` returns. `installedBytes`: `AssetPack.downloadSize` of a pack whose
  `status(ofAssetPackWithID:)` contains `.downloaded` — the 26.0 surface has no installed size, so this is an
  **UNVERIFIED approximation** (compressed download size; for `DEVICE-TEST-PLAN.md`). The reader is the tested
  `FileHandleChunkReader`: the live file only supplies its opener (`descriptor(for:searchingInAssetPackWithID:)` →
  `FileHandle(fileDescriptor:closeOnDealloc: true)`), which runs on the first `nextChunk`, inside the bulk executor;
  the handle lives in a `Mutex` (E-1) and reads go through `read(upToCount:)`. L2 close-out (Mutex ruling): the open
  and every read now run outside the lock, which only publishes the handle between pulls; should two first pulls
  overlap, the handle stored first wins (tested deterministically by a pull nested inside the opener; a
  last-store-wins mutant fails it). Error mapping:
  `ManagedBackgroundAssetsError` → `packNotFound`/`fileNotFound`, anything else → `.system(NSError domain, code)`
  (tested on the host by constructing the errors; the manager is never touched). Measured: **81 llvm-cov lines**
  (working ceiling 100); `COVERAGE device-only-excluded lines=110 share=1.74% max=3.0% OK` with WP-D's file at L2.

## E-13 — Test seams and test placement

- Internal seams used through `@testable import`: `PackAvailabilityCoordinator.waiterCount(on:)` /
  `waitForWaiters(on:count:registered:)` / `waitForStaleCompletions(_:)`, `AppleSourceState.settleUpdateCheck()` /
  `waitForDrain(registered:)`, `PackTransferDriver.deliver(_:to:copier:)`, `ReleaseSurvey.survey(…, sliceSize:,
  pause:)`. The `registered` hooks (fix round 1) run on the actor once a seam wait is registered, so the seam tests
  cancel a wait known to be pending and assert it returned while its condition was still unmet (the three earlier
  "Seams:" tests only ran the pre-cancelled branch and asserted always-true facts; replaced). The pre-cancelled
  branches of the two seam waits (a task cancelled before it calls the seam) are now the only seam lines no test
  reaches; they guard against a hop that runs before registration and are kept. `GatedStagingSink` holds a write
  either before its first chunk (`.beforeWrite`: tests of copies stopped at a chunk) or after its last
  (`.afterWrite`: tests of copies that finished before a stop or a close), and `FakePackBackend` gained
  `holdIgnoringCancellation` and `releaseEnsure(_:with:oldestOnly:)` for the stale-flight test (E-6).
- **Seam tests (fix round 2, for the orchestrator).** The four `Seams:` tests in `AppleTestSeamTests` verify that the
  internal test-only waits (`waitForWaiters`, `waitForDrain`, `settleUpdateCheck`) end when their caller is cancelled
  or the coordinator closes; they carry no requirement ID because they verify test infrastructure, and the seams'
  lines count as production lines. Each fails at its `.timeLimit` if its seam ignored cancellation, so none is
  assertion-free. Whether internal seams in production targets, and tests of them, are accepted is an orchestrator
  decision for DECISIONS (request below); the alternative is a test-support protocol for the waits.
- **Trace labels (fix round 2).** The four pure error-mapping tests are `R-NET-6` (the closed taxonomy); only the
  `LiveAssetPackBackend.packError` boundary test keeps `R-APL-2` (the BackgroundAssets error types). The update-check
  identifier test moved to `AppleCatalogTests`. `R-APL-4: a pack file of another size than the catalog's is skew,
  stopped at the catalog size` now asserts the stop: the sink receives `maxBytes` 10 (not the 1 MiB cap) and the
  source logs the oversize path (a `cap = maxBytes` mutant fails it).
- Coverage after fix round 1 (gate export over every test bundle): `COVERAGE target=ZTronAssetAppleHosted lines=
  99.50% (1203/1209)`; the six lines not reached are `AppleHostedTier.swift:43,48` (contract code), the two
  pre-cancelled seam branches above and the stale `broadcast` branch (E-6). Fix round 2: `COVERAGE
  target=ZTronAssetAppleHosted lines= 99.51% (1222/1228)`; `llvm-cov show` lists `AppleHostedTier.swift:43,48`, the
  two pre-cancelled seam branches (`AppleSourceState.swift:120`, `PackAvailabilityCoordinator.swift:131`) and
  `AppleSourceState.swift:67` (`endStaging` while another staging call still runs: reached only when two copies
  overlap by scheduling — round 1's run reached it, this one did not; `invalidate` waiting for every write is tested
  with one held write). The stale `broadcast` branch is now covered (E-6). The seam waits let tests synchronise on
  actor state without sleeping, and each returns when the calling task is cancelled, so a defect that makes a wait
  endless fails the test at its `.timeLimit` instead of hanging the run (found by the mutation probes below: a
  non-cancellable seam kept a probe run alive for 30 minutes). `FakePackBackend.releaseEnsure`/`releaseCheck` issued
  before the call reaches its hold finish that hold at once (a release-before-hold race hung one run under load).
- **L2 close-out.** Two seams were added under the ruling below: `PackTransferDriver.conclude(_:)` (the step after a
  finished attempt, E-8) and the internal `AppleHostedTier.resolve(…, select:)` overload, which takes the tier
  decision so the `.noSourceConfigured` returns for a decision naming a tier the configuration cannot build (the
  verifier's 0-hit `AppleHostedTier.swift:43,48`) are reached; the public `resolve` passes `TierSelection.select`,
  which never makes such a decision, so the seam is inert in production (cycle 3: the orchestrator acknowledged this
  overload, a declaration added to the contract file `AppleHostedTier.swift`, as covered by the E-13 ratification; no
  change). Tests: `AppleTierResolutionTests` (R-APL-5:
  every configuration resolving to `.noSourceConfigured` builds no source and touches no pack; a decision without a
  buildable source fails closed and sees the OS fact and the configuration; resolve follows the injected decision).
  The four `Seams:` tests keep no requirement ID: they verify test-only waits (that a cancelled or closed wait
  returns), and no SPEC requirement covers test infrastructure; the waits stay documented as test seams, internal,
  and unreachable from production paths. Coverage (gate export over all 8 test bundles): `COVERAGE
  target=ZTronAssetAppleHosted lines= 99.76% (1255/1258) min=70.0 OK`. The three lines not reached are the two
  pre-cancelled seam branches (`AppleSourceState.swift:120`, `PackAvailabilityCoordinator.swift:131`) and the
  implicit closure of `packBackend ?? LiveAssetPackBackend()` in `resolve` (it builds the device-only live backend,
  which no test constructs).
  Cycle 3 (the re-arm path deleted, E-10): `COVERAGE target=ZTronAssetAppleHosted lines= 99.76% (1242/1245)
  min=70.0 OK` and `COVERAGE device-only-excluded lines=110 share=1.69% max=3.0% OK`; the same three lines are not
  reached (the seam branch is now `AppleSourceState.swift:119`).
- `R-APL-3: an adopted asset is served from blobs and never from a pack location` is written at the source level: at
  L2 the store is WP-B's stub, so the test asserts that what reaches the engine is a staging copy of this transfer
  (no pack location exists in any output), that the pack's release leaves the copy intact, and that the release opens
  no pack file (fix round 1: the open count is now taken before the reclaim; it was taken after, which made the
  check always true). The store/engine end-to-end proof belongs to WP-F/WP-G with the merged store — see "Requests
  for the orchestrator". The name is the one ARCHITECTURE §11 assigns to WP-E, so it is kept; this test is the
  source-level half (fix round 2 verifier: agreed).
- Additional tests beyond §11 (transport.md §16.6 and the review dispositions): single-flight, cancelled waiter,
  last-waiter cancel, pause, stream drop, invalidate drain, skew variants, removal reporting, offline catalog,
  releases once per generation, failed releases, `sourceCopyBytes`, error-mapping tables, the R-OBS-1 `transfer`
  interval, the R-APL-5 `#available` scan.
- Only asset transfers are wrapped in the R-OBS-1 `transfer` interval (category `apple`); the catalog fetch is not
  a `TransferHandle` transfer.

## E-14 — What the `apple` log lines carry (R-OBS-1)

- **Decision.** Lines name packs (publisher configuration, not user data), byte counts and the transfer **attempt
  token** (`epoch-sequence`, which also names the staging file); never a `TransferID`, a remote path or an asset
  identifier, so WP-A's call-site scan (`R-OBS-1: every log line uses subsystem …`) passes without hashing. Errors are
  logged as `String(describing:)` of `PackError`/`StagingError`, bound to `reason` first: those enums carry only
  domains, codes and limits, never an identifier. The `transfer` interval's message is `attempt <token>`.
- **L2 close-out (verifier round 3, blocking: R-OBS-1 flake).** The driver ended the interval after `deliver`, whose
  `yield`/`finish` resume the consumer on another thread, so a consumer could see the terminal update while the
  interval was still open (the verifier saw the test fail at repetitions 398 and 808 under load). The interval now
  ends before the terminal element is yielded, on every path. Both R-OBS-1 tests read the tap **when the terminal
  update arrives** (`collectNotingIntervals`), and `R-OBS-1: a failed, cancelled or paused Apple transfer closes its
  interval before its terminal update` covers skew, cancel and pause. Evidence: against the old driver,
  `--repeat-until fail --maximum-repetitions 3000` failed at repetition 76 (both tests; load average 2.9 on 8
  cores); with the fix, 3000 repetitions passed (figures in the close-out report).
- **L2 close-out cycle 3 (verifier, non-blocking: test strength).** Both tests above read the tap on the consumer's
  thread, so they catch the old ordering only by chance (the verifier needed 319 repetitions under load 16–30). A
  deterministic regression test now drives `PackTransferDriver.run()` with a continuation the test creates, whose
  `onTermination` snapshots the tap's interval events; `finish()` runs that handler synchronously on the driver's
  task, so the snapshot is taken exactly when the stream ends: `R-OBS-1: the transfer interval is already closed when
  the driver ends its stream`. Evidence, in a scratch copy of the package (`.build-e/mut/obs`) with the old ordering
  mutant (`interval.end()` after `deliver`): 3 of 3 single runs failed (the snapshot held only the `began` edge), and
  `--repeat-until pass --maximum-repetitions 200` failed all 200 repetitions; against the fixed driver,
  `--repeat-until fail --maximum-repetitions 1000` passed all 1000.

## E-15 — `PackLocation` splits at `/` scalars; ASCII fast path (fix round 1) · contract body change, no signature

- **Context.** The C2 finding measured ~2.4 µs per `PackLocation(remotePath:)` (the Unicode property lookup per scalar
  and an `Array(utf8)` copy in `PackID`). While speeding it up, the `Character`-based split showed a defence-in-depth
  gap (R-SEC-2): a combining mark after a slash makes `"/\u{301}"` one `Character`, so `"ZTronMedia/../\u{301}x"`
  was accepted although its second path component is `..` where a file system splits it.
- **Decision.** Split at every `/` **scalar** (the UTF-8 byte 0x2F occurs only as that scalar); a dot segment is a
  component of one or two `.` scalars; the control check consults the Unicode table only for non-ASCII scalars (ASCII
  controls are exactly U+0000…U+001F and U+007F); `PackID` iterates the UTF-8 view without copying. Tested first
  (`PackLocationTests`: three hidden dot segments, scalar-exact round trip, controls U+0000/1F/7F/85/9F).
- **Consequences.** Stricter on hidden dot segments; a path whose segment starts with a combining mark is now
  accepted (it was rejected only because the slash was absorbed). Measured, release build: 1.48 → 0.56 µs per parse.
  The contract tests (`AppleHostedContractTests`) pass unchanged. Orchestrator: this is a body change in a contract
  file implemented by WP-E.

## E-16 — The release decision is surveyed in slices off the state actor (C2, fix round 1)

- **Context.** `planRelease` parsed every manifest, adopted and excluded path and ran the planner in one actor turn:
  47 ms at 10,000 entries and 512 ms at R-MAN-2's 100,000 (verifier, release build), holding a pool thread and the
  actor every transfer needs for staging admission.
- **Decision.** `ReleaseSurvey.survey` runs in the `reclaimSourceCopies` caller's task (not on the actor), parses
  only the manifest entries, 1,000 per slice with `Task.yield()` between slices, and matches adopted/excluded paths
  against the report's string sets (same membership: a remote path and its `PackLocation` correspond one to one).
  Each slice is decided by `PackReleasePlanner` (the single release rule); a pack is settled when it appears in some
  slice and no slice found an unsettled entry of it. The actor turn only filters the survey by the released and
  in-flight sets, as they are then.
- **Evidence.** Tests: a 100,000-entry report pauses after every 1,000 entries (99 pauses); a seeded property test
  (300 rounds, slice sizes 1…8, invalid paths, `keepPacks`) matches `PackReleasePlanner` over the whole report.
  Measured with a one-off release-build probe (`-enable-testing`, not committed: timing has no place in the
  deterministic suite and WP-E owns no benchmark file): 100,000 entries in 100 slices, 1.0 ms per slice on average,
  4.7 ms for the slowest. A P-9-style benchmark of a maintenance run at 100,000 entries would be the durable proof
  (request below).

## E-17 — Network access policy is the engine's: BackgroundAssets cannot honour `NetworkAccess` (L2 close-out)

- **Context.** Verifier round 3 (non-blocking): `TransferRequest.access` and `ManifestRequest.access` (the
  OS-enforced network permissions) are ignored by the Apple tier, so `ensureAvailable` and `checkForUpdates` (from a
  manifest fetch or a skew) download over whatever network the OS chooses; a Wi-Fi-only or constrained-network
  policy is not enforced for pack downloads.
- **Decision (orchestrator ruling).** The tier ignores `access` **by necessity**: the verified BackgroundAssets 26.0
  surface (AAV §1.1) has no per-call network constraint for `ensureLocalAvailability(of:)` or `checkForUpdates()`.
  The tier gets no policy code. **WP-F must gate Apple-tier dispatch (transfers that may make a pack available) and
  update checks (manifest fetches with `allowsUpdateCheck`) on its own `DeviceConditions`**; the orchestrator assigns
  that obligation to the WP-F rows of ARCHITECTURE §11.
- **Consequences.** A transfer the engine dispatches may download a whole pack on any network the OS allows; a
  skew's best-effort update check is scheduled by the source regardless of policy (it is reached only through a
  dispatched transfer, so the engine's gate bounds it). Rows requested for APPLE-API-VERIFICATION §5 and
  DEVICE-TEST-PLAN (below): which networks the OS uses for on-demand packs and update checks, and whether the app's
  cellular settings apply.

## Orchestrator rulings (L2 close-out)

- **Mutex.** ADR-003 and APPLE-API-VERIFICATION §4.7 forbid `Mutex` in production because it is unavailable at the
  iOS 15 floor. The Apple-hosted tier is gated `@available(iOS 26.0, macOS 26.0, *)` as a whole, so
  `Synchronization.Mutex` is **ratified** inside code whose every use site carries that gate (never in ungated code,
  never `@unchecked`). Each critical section stays free of awaits and I/O: `PackTransferStop` (request, read, claim),
  `HashingChunkSource` (hasher update of one ≤ 1 MiB chunk and finalise, stop flag; the base reader's I/O runs
  outside the lock), `FileHandleChunkReader` (publishes the handle only; its open and reads were moved out of the
  lock in this close-out, E-12).
- **Ratified:** E-1 (the extra hash pass for skew detection), E-4 (a file missing after the pack was made available
  is `transient(.sourceVersionSkew)`, ADR-032), E-15 (the stricter `PackID`/`PackLocation` bodies, body-only), E-13
  (internal test seams in the production target, documented as test seams, never public, inert on production paths;
  their tests carry a requirement ID where one applies — see E-13 for the four `Seams:` tests, which have none).
- **E-10:** released packs stay tracked in memory, once per process; persisting them needs a store field and is
  deferred (the entry stays). The optional `AdoptionReport` digest field is declined for now.
- **NetworkAccess:** E-17.

## Orchestrator rulings (L2 close-out cycle 3)

- **ADR-027 / E-10(b).** ADR-027's decision stands literally: a pack is released at most once per pack per catalog
  generation and is never re-armed within a generation; E-10(b)'s re-arm is withdrawn. A pack downloaded again on
  demand after its release stays installed until the next catalog generation, and its `installedBytes` keep counting
  in `sourceCopyBytes`. Implemented in E-10 (failing tests first; the re-arm path deleted).
- **E-13.** The internal `resolve(…, select:)` overload in `AppleHostedTier.swift` is acknowledged under the E-13
  ratification (no change).

## Requests for the orchestrator (L2 close-out)

- **ARCHITECTURE §11, WP-F rows (E-17):** WP-F gates Apple-tier dispatch and manifest fetches that allow an update
  check on its own `DeviceConditions`, since the tier cannot honour `NetworkAccess`.
- **APPLE-API-VERIFICATION §5 / DEVICE-TEST-PLAN (E-17):** the networks BackgroundAssets uses for on-demand pack
  downloads and update checks, and whether the app's cellular-data setting constrains them.
- **ARCHITECTURE §11, WP-F or WP-G row (repeat of rounds 1 and 2, verifier round 3 agreed):** the end-to-end R-APL-3
  test (an asset adopted from a `FakePackBackend` source is served from `blobs/` after its pack is released);
  WP-E's test stays the source half.
- **DECISIONS ADR-003 and APPLE-API-VERIFICATION §4.7 (row 19 and item 7), cycle 3:** amend both at merge with the
  ratified Mutex exception (see "Orchestrator rulings (L2 close-out)"). Row 19 says "Not allowed in production" and
  item 7 says no `Mutex` in production; a later verifier reading them would flag the tier's three gated uses as
  violations. The exception: `Synchronization.Mutex` is allowed only inside code gated
  `@available(iOS 26.0, macOS 26.0, *)`, never `@unchecked`, with no await and no I/O in a critical section; it is
  used by exactly three types, `PackTransferStop`, `HashingChunkSource` and `FileHandleChunkReader`.
- **ARCHITECTURE §6.6 (cycle 3, E-10/E-11):** "`sourceCopyBytes()` sums `PackBackend.installedBytes` of adopted,
  unreleased packs" predates fix round 1; the sum covers every media pack holding adopted content, released or not,
  because a released pack reports no bytes and one downloaded again after its release stays installed until the next
  catalog generation.

## Requests for the orchestrator (fix round 1)

- **ARCHITECTURE §11:** add to the WP-F or WP-G rows (a) the engine half of "R-APL-4: a missing catalog pack while
  offline reports offline and leaves the applied manifest in force" (E tests only the source half), and (b) an
  end-to-end R-APL-3 test: an asset adopted from a `FakePackBackend`-backed source is served from `blobs/` after
  its pack was released.
- **APPLE-API-VERIFICATION §5 / DEVICE-TEST-PLAN:** add E-12's `installedBytes ≈ AssetPack.downloadSize` (compressed
  size, UNVERIFIED approximation feeding `StorageReport.sourceCopyBytes`) when E-12 is merged (WP-E does not own those
  files).
- **Benchmarks (optional):** a timed maintenance-run case at 100,000 manifest entries (E-16), e.g. in P-9.

## Requests for the orchestrator (fix round 2)

- **ARCHITECTURE §11, WP-F R-CLN-9 row / RE-S32 (E-11):** the engine runs `reclaimSourceCopies` before the first
  `storageReport()`, and `R-CLN-9: storageReport counts bytes the OS still holds in adopted packs` covers a fresh
  source instance (a relaunch).
- **ARCHITECTURE §11, WP-F or WP-G row (repeat of round 1):** the end-to-end R-APL-3 test (an asset adopted from a
  `FakePackBackend` source is served from `blobs/` after its pack is released); WP-E's test stays the source half.
- **DECISIONS:** whether internal test seams in production targets, and the `Seams:` tests that exercise them,
  are accepted (E-13); if not, the waits move behind a test-support protocol.
- **APPLE-API-VERIFICATION §5 / DEVICE-TEST-PLAN:** (a) abandoned pack flights per swipe while a pack downloads, if
  `ensureLocalAvailability`/`statusUpdates` ignore cancellation (E-6, declined change); (b) which error a pack
  download throws on a full disk, and that it reaches the engine as `insufficientSpace` (E-5).

## Mutation probes run by the author (not a substitute for Stage 3's independent ones)

Each mutant applied alone to `Sources/ZTronAssetAppleHosted`, the tier's tests run, the file restored; all 8 killed:
skew reported as integrity (3 skew tests fail); no single-flight (3: concurrent fetches, cancelled waiter, per-waiter
progress); `invalidate` without drain (2: invalidate drain, catalog copy outliving invalidate); released set not reset
per catalog generation (1); `notModified` dropping removals (1); unscaled progress (2); flight cancelled on any leave
(1); update check awaited before the catalog read (4, the hanging-check test among them). Fix round 2, each
killed: the copy cap returning `maxBytes` (the size-skew test, 2 expectations); `broadcast` without the flight-id
check (the foreign-flight progress test); `forgetRelease` without `forgottenWhileReleasing` (the release-race test,
3 expectations, run before the fix); the `Double` scaler (the exact-arithmetic test traps, run before the fix); no
out-of-space row (3 expectations, run before the fix). L2 close-out, each new test run against the old code
before its fix: the interval ended after `deliver` (both R-OBS-1 tests failed at repetition 76 of
`--repeat-until fail`); the release forgotten on every `.available` pack wait (the PROBE-R3-1 test, 5 issues, 4
removals); the unsaturated `+=` (the saturation test crashed the test helper with signal 5).
L2 close-out cycle 3: the R-OBS-1 ordering mutant (`interval.end()` after `deliver`) against the deterministic
interval test (3/3 single runs and 200/200 repetitions failed, scratch copy); the re-arm code itself, as the old
behaviour, against the four E-10 tests (23 issues).

## Proposed REENTRANCY rows (ARCHITECTURE §10, new subsection for `ZTronAssetAppleHosted` actors)

| Row | Await | Re-validated afterwards |
|---|---|---|
| e-1 | `AppleSourceState.drain()`: `withCheckedContinuation` | nothing: a terminal wait registered synchronously and resumed only by the `endStaging()` turn that reached zero; `close()` ran first, so nothing is admitted afterwards |
| e-2 | `AppleSourceState.scheduleUpdateCheck`'s task: `backend.checkForUpdates()` | `finishCheck` runs on the actor and only clears `checkTask` and appends findings; a `close()` meanwhile is harmless (no new check starts after close, and none starts while this one is recorded as running) |
| e-3 | `AppleSourceState.settleUpdateCheck()` (test seam): `task.value` | nothing: a terminal wait; the caller re-reads the report |
| e-4 | `PackAvailabilityCoordinator.ensure`: `withTaskCancellationHandler` + `withCheckedContinuation` | nothing is read after resumption (the outcome travels in the continuation); `join`, `leave`, `complete` and `close` each re-read the waiter and flight tables, and a waiter is resumed exactly once by whichever removes it |
| e-5 | `PackAvailabilityCoordinator.wait(for:registered:)`, and the `await self.wait(…)` calls in `waitForWaiters` / `waitForStaleCompletions` (test seams; cited at each call since fix round 2) | nothing: a terminal wait resumed by the turn that made the condition hold, by `close`, or by the cancellation turn; the caller re-reads the census |
| e-6 | the flight task created in `join`: `await PackFlight.fly(...)` | nothing runs after it; `fly` reports through `broadcast` and `complete`, which drop a stale flight by id |
| e-7 | `AppleSourceState.waitForDrain()` (test seam) | nothing: a terminal wait resumed by the `drain()` turn that registered its waiter or the `endStaging()` turn that reached zero |
| e-8 | `Task { await self.leave(id) / releaseConditionWaiters() / releaseDrainObservers() }` in the `onCancel` handlers of `ensure`, the coordinator's seam waits and `waitForDrain` | a hop onto the actor from a cancellation handler, which cannot touch actor state synchronously; the hopped call re-reads the table it changes, so a continuation already resumed and removed by the regular path is never resumed twice |

## Contract changes

None requested. Optional for the orchestrator (E-10): a persisted "released packs per catalog generation" field
would close T2-13 fix 5 across relaunches.
