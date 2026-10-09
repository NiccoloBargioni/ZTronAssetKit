# Unsafe audit (C1, R-ENV-4, Q-3)

The unsafe gate (`python3 Scripts/gates.py unsafe`) scans **all** of `Sources/`, `ZTronAssetTestSupport` included, for `@unchecked Sendable`, `nonisolated(unsafe)`, `unsafeBitCast`, `Unmanaged<`, `unowned(unsafe)`, `withUnsafeMutable*`, `UnsafeMutable(Raw)Pointer`, `assumeIsolated` and `@preconcurrency`. At most 3 audited escapes are allowed in total; each must be marked `// UNSAFE-AUDIT: U-nnn` in code and justified here (the invariant that makes it safe, and the test that fails if the invariant breaks).

## Current state

**0 of 3 escapes are used** (contract-fix round 2, 2026-10-04: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; again on the merged Level 2 head at the Level 2 close, 2026-10-09, ADR-050).

How the design avoids them (ARCHITECTURE §2):
- State lives in actors (`AssetStore`, `SyncEngine`; in TestSupport `SteppedBlockingExecutor`, `ScriptedSnapshotSink`, `FakeDeviceConditionsSource`, `FakeMemoryPressureSource`), `@MainActor` classes (`SnapshotMirror`, `PrefetchWindowController`, `BackgroundEventsRelay`, `PurgeableCacheRelay`) or immutable `Sendable` classes with `let`s only (`AssetClient`, `PrefetchHandle`, `SessionDelegate`, `TaskMailbox`, `HTTPRemoteSource`).
- A value that cannot observe shared state does not promise to: `StagingSink` makes no after-close promise (an immutable sink would need a lock to see the store close); shutdown ordering protects the store instead (ADR-039).
- URLSession delegates hold only `Sendable` `let`s and forward into `AsyncStream.Continuation`s, so they are `Sendable` without `@unchecked` (transport.md TC-1).
- Test fakes with synchronous APIs use `Synchronization.Mutex` behind `@available(macOS 15.0, iOS 18.0, *)` (ADR-014); `Mutex` is not an unsafe pattern. Production code uses it only under ADR-003's ADR-050 exception: inside code gated `@available(iOS 26.0, macOS 26.0, *)` (the Apple-hosted tier), never `@unchecked`, with no `await` and no I/O inside a critical section, in exactly three types: `PackTransferStop` (request, read and claim of a stop), `HashingChunkSource` (the hasher update of one chunk, the finalise and the stop flag; the base reader's I/O runs outside the lock) and `FileHandleChunkReader` (publishes the handle only; the open and every read run outside the lock). Code at the iOS 15 floor uses no `Mutex`.
- Memory measurement for P-6/P-7 (`task_info`) lives in `Tests/ZTronAssetKitBenchmarks`, which the gate does not scan (ADR-040).

## Audited escapes

None. A work package that believes it needs one reports to the orchestrator first, with the invariant and the test that would fail.
