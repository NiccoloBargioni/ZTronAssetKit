# WP-E (Apple-hosted tier) — ADR drafts and proposed REENTRANCY rows

Owner: WP-E, Stage 2, level L2. Scope: every WP-E stub in `Sources/ZTronAssetAppleHosted` (`AppleHostedRemoteSource`,
`LiveAssetPackBackend`), the tier's tests and `FakePackBackend` in `Tests/ZTronAssetAppleHostedTests` (ADR-040). No
public or package signature changed (checked against tag `contracts`); every new type is internal. The orchestrator
numbers these into `DECISIONS.md` and ARCHITECTURE §10 at merge.

New internal files: `AppleSourceState.swift` (the source's only mutable state, an actor), `PackAvailabilityCoordinator.swift`
(single-flight `ensureAvailable`), `PackCopier.swift` (every staging call), `AppleCatalogReader.swift`, `PackTransfer.swift`
(handle, stop request, driver), `HashingChunkSource.swift`, `PackProgressScaler.swift` (+ `PackProgress(snapshotOf:)`),
`PackErrorMapping.swift`.

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
  domain and code go to the `apple` log). Rows of §3.4.2 that would yield `integrity` or `rejected` are deliberately
  not reused: an undocumented pack error is never integrity (AAV §1.8). Staging: `insufficientSpace` →
  `insufficientSpace(expectedBytes)`, `io` → `localIO`, `nameInUse` → `localIO(EEXIST)` and the file is **not**
  discarded (it is someone else's). Reader open: `packNotFound` → `.notInstalled`, `fileNotFound` → `.notFound` (both
  make the source make the pack available), others → `.system`/`.readFailed`.

## E-6 — Single-flight pack availability (`PackAvailabilityCoordinator`)

- **Decision.** One flight (a coordinator-owned task) per pack runs `ensureAvailable`; callers wait on continuations
  registered on the actor and resumed exactly once by `complete`, `leave` (the caller's cancellation handler) or
  `close`. A cancelled caller leaves at once; the flight is cancelled only when its last waiter left (T2-14 Timeline B).
  Progress fans out as values to every waiter; the outcome is delivered only after every progress value was, so a
  waiter's stream is complete before its terminal element. Stale flights are ignored by flight id.
- **Consequences.** If the OS ignores cancellation, a cancelled flight's task lives until the OS returns (UNVERIFIED,
  AAV §5); nobody waits on it and a new caller starts a new flight.

## E-7 — Progress (R-APL-2)

- **Decision.** `PackProgress(snapshotOf: Foundation.Progress)` reads `completedUnitCount`/`totalUnitCount` once at the
  live boundary (D-12); an indeterminate total becomes 0/0; completed is clamped. `PackProgressScaler` reports
  `fraction × expectedBytes`, quantised to 1 % steps of the asset (plus the final value), monotonic, ≤ the asset size,
  so at most 101 progress elements per waiter. No progress for an unknown or zero `expectedBytes`.

## E-8 — Transfer handle controls

- **Decision.** `pause()`/`cancel()` record the first stop in a `Mutex` (iOS 26 code, E-1) and cancel the driver
  task; the driver alone yields the single terminal element (`.paused(resumable: false)` — packs never resume — or
  `.failed(.cancelled(.byClient))`), discarding a copy that completed meanwhile. A consumer dropping the stream
  (`onTermination(.cancelled)`) is a cancel. `setPriority` is a no-op (`supportsPriority == false`).

## E-9 — Shutdown (`invalidate()`)

- **Decision.** `AppleSourceState` admits every staging call (`PackCopier`); `invalidate()` closes admission, closes
  the coordinator (every pack waiter ends `.cancelled`), cancels the update check, then drains: it returns after every
  admitted staging call returned. After that, transfers and fetches fail `.cancelled(.byClient)` without touching
  staging, and a copy that finishes after close leaves its file for the next launch's staging GC (ADR-028).

## E-10 — Releases: once per catalog generation, in memory · NEEDS-HUMAN-REVIEW (residual)

- **Decision.** `reclaimSourceCopies` plans with `PackReleasePlanner` (keep-scope = `excludedRemotePaths`), marks
  planned packs in flight (a concurrent reclaim never plans them again), removes them in order, and counts a
  `packNotFound` removal as released. The released set is per **catalog generation** (the catalog pseudo-ETag of the
  last successful fetch); a new digest clears it. A failed removal is reported in `ReclaimReport.failed` and planned
  again next time. An invalid `catalogPackID` releases nothing.
- **Residual.** transport-2 T2-13 fix 5 asked to persist `alreadyReleased` in `index.bin`; no contract field exists, so
  it lives in memory. Effect: after a relaunch, a pack the OS re-downloaded may be released once more per process
  (bounded: once per pack per process, never a loop within one). Persisting it needs a store field (orchestrator).

## E-11 — `sourceCopyBytes()`

- **Decision.** Media packs (never the catalog pack) with at least one adopted entry in the **last**
  `AdoptionReport` the source received, minus packs released in the current generation, summed from
  `PackBackend.installedBytes` (`nil` → 0, negative clamped). 0 before the first report.

## E-12 — `LiveAssetPackBackend` (device-only, coverage-excluded)

- **Decision.** Only the verified 26.0 surface (AAV §1.1, re-checked against the installed macOS 27 SDK interface
  lines 77, 123, 124, 129, 135, 147, 152, 157, 166–167, 266, 280). `ensureAvailable`: a watcher task maps
  `statusUpdates(forAssetPackWithID:)` `.downloading` to `PackProgress(snapshotOf:)` and is cancelled when
  `ensureLocalAvailability(of: assetPack(withID:))` returns. `installedBytes`: `AssetPack.downloadSize` of a pack whose
  `status(ofAssetPackWithID:)` contains `.downloaded` — the 26.0 surface has no installed size, so this is an
  **UNVERIFIED approximation** (compressed download size; for `DEVICE-TEST-PLAN.md`). The reader opens
  `descriptor(for:searchingInAssetPackWithID:)` on its first `nextChunk` (inside the bulk executor) and reads through
  `FileHandle(fileDescriptor:closeOnDealloc: true)`; the handle lives in a `Mutex` (E-1). Error mapping:
  `ManagedBackgroundAssetsError` → `packNotFound`/`fileNotFound`, anything else → `.system(NSError domain, code)`;
  the reader's mapping to `SourceFailure` is in the tested `PackErrorMapping`. Executable lines: see the coverage
  report's device-only line.

## E-13 — Test seams and test placement

- Internal seams used through `@testable import`: `PackAvailabilityCoordinator.waiterCount(on:)` /
  `waitForWaiters(on:count:)`, `AppleSourceState.settleUpdateCheck()` / `waitForDrain()`. They let tests synchronise on
  actor state without sleeping, and each returns when the calling task is cancelled, so a defect that makes a wait
  endless fails the test at its `.timeLimit` instead of hanging the run (found by the mutation probes below: a
  non-cancellable seam kept a probe run alive for 30 minutes). `FakePackBackend.releaseEnsure`/`releaseCheck` issued
  before the call reaches its hold finish that hold at once (a release-before-hold race hung one run under load).
- `R-APL-3: an adopted asset is served from blobs and never from a pack location` is written at the source level: at
  L2 the store is WP-B's stub, so the test asserts that what reaches the engine is a staging copy of this transfer
  (no pack location exists in any output), that the pack's release leaves the copy intact, and that no pack file is
  opened again. The store/engine end-to-end proof belongs to WP-F/WP-G with the merged store.
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

## Mutation probes run by the author (not a substitute for Stage 3's independent ones)

Each mutant applied alone to `Sources/ZTronAssetAppleHosted`, the tier's tests run, the file restored; all 8 killed:
skew reported as integrity (3 skew tests fail); no single-flight (3: concurrent fetches, cancelled waiter, per-waiter
progress); `invalidate` without drain (2: invalidate drain, catalog copy outliving invalidate); released set not reset
per catalog generation (1); `notModified` dropping removals (1); unscaled progress (2); flight cancelled on any leave
(1); update check awaited before the catalog read (4, the hanging-check test among them).

## Proposed REENTRANCY rows (ARCHITECTURE §10, new subsection for `ZTronAssetAppleHosted` actors)

| Row | Await | Re-validated afterwards |
|---|---|---|
| e-1 | `AppleSourceState.drain()`: `withCheckedContinuation` | nothing: a terminal wait registered synchronously and resumed only by the `endStaging()` turn that reached zero; `close()` ran first, so nothing is admitted afterwards |
| e-2 | `AppleSourceState.scheduleUpdateCheck`'s task: `backend.checkForUpdates()` | `finishCheck` runs on the actor and only clears `checkTask` and appends findings; a `close()` meanwhile is harmless (no new check starts after close, and none starts while this one is recorded as running) |
| e-3 | `AppleSourceState.settleUpdateCheck()` (test seam): `task.value` | nothing: a terminal wait; the caller re-reads the report |
| e-4 | `PackAvailabilityCoordinator.ensure`: `withTaskCancellationHandler` + `withCheckedContinuation` | nothing is read after resumption (the outcome travels in the continuation); `join`, `leave`, `complete` and `close` each re-read the waiter and flight tables, and a waiter is resumed exactly once by whichever removes it |
| e-5 | `PackAvailabilityCoordinator.waitForWaiters` (test seam) | nothing: a terminal wait resumed by the turn that reached the count, or by `close` |
| e-6 | the flight task created in `join`: `await Self.fly(...)` | nothing runs after it; `fly` reports through `broadcast` and `complete`, which drop a stale flight by id |
| e-7 | `AppleSourceState.waitForDrain()` (test seam) | nothing: a terminal wait resumed by the `drain()` turn that registered its waiter or the `endStaging()` turn that reached zero |

## Contract changes

None requested. Optional for the orchestrator (E-10): a persisted "released packs per catalog generation" field
would close T2-13 fix 5 across relaunches.
