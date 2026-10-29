# ZTronAssetKit — specification

**Authority.** This file is authoritative for *what* to build. `PROMPT.md` is authoritative for *how to work*. `CLAUDE.md` holds the standing rules.
**Format.** Requirements are single lines of the exact form `- **R-XXX-n [MUST|SHOULD|MAY]** text` — `Scripts/gates.py trace` parses them, so never reformat them. Budgets are `P-n` (thresholds in `Scripts/quality-gates.json`), quality gates are `Q-n`, invariants are `I-n`, hard problems are `H-n`.
**Honesty.** Statements marked *(verified)* were checked against the real code or Apple/AWS documentation. Statements marked *(hint)* are starting points you must verify with the compiler or the SDK before relying on them.

---

## 1. Context, scope, hard problems

### 1.1 Context
ZTronCarousel / ZTronCarouselCore (SwiftPM, Swift 6 language mode, `StrictConcurrency=complete`, iOS 15+) render media pages: `BasicImagePage` (HEIC/PNG/JPG), `ZTronSVGView` (SVG outlines), `BasicVideoPage` (MP4); WAV/MP3 audio is also published. To stay inside the App Store size budget, media ship from a remote catalog described by a manifest. Today that logic lives in `ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/` and grew incrementally. **ZTronAssetKit replaces it** with a purpose-built, rigorously tested module that owns the whole path from "a manifest exists at an origin" to "a verified file URL reaches a UI component", **and the lifetime of every byte the module puts on the device**.

### 1.2 The promises the app makes to its user
1. **No mid-use waiting.** If the app had a chance to sync, an asset is either already local and verified, or it is fetched immediately at top priority and cached. Prefetching keeps the carousel's neighbouring pages ready.
2. **Catalog changes are cheap and correct.** Changed bytes re-download (only those); a moved directory/name costs zero downloads; a removed asset is deleted from the device.
3. **The device is never filled and never confused.** Storage is budgeted, evictable content is evicted least-recently-used, and the OS purging, corrupting or half-writing files is survivable without user action.
4. **Nothing janks scrolling or drains the battery.** No main-thread I/O, bounded parallelism, no polling, power- and network-aware.

### 1.3 Scope
**In:** manifest fetch/validation/diff · download · integrity · on-device storage layout · index/snapshot · sync planning/scheduling · cleanup (prune, orphan GC, staging GC, quota eviction, purge, OS-purge recovery, corruption repair) · the Apple-hosted tier · the carousel-facing API · migration from the prior-art layout · observability · the compatibility layer in ZTronCarouselCore.
**Out:** UI; paywall/filter logic (the module exposes a generic `AssetScope`, nothing more); the remote infrastructure (`Infrastructure/aws`, `publish.py`); app-side Apple-hosting prerequisites (download extension, Info.plist keys, App Group) — document, don't implement; the ZTronDataModel database.

### 1.4 Hard problems — `docs/ARCHITECTURE.md` must resolve each with a decision *and* a test
- **H-1 Crash consistency.** The app can be killed or the phone can lose power at any instruction.
- **H-2 Snapshot vs deletion.** The UI reads an in-memory snapshot synchronously; files are deleted asynchronously. A reader must never be handed a URL that is about to vanish.
- **H-3 Single-flight and cancellation.** N callers want one asset; one cancels; the rest must be unaffected; the transfer dies only when *nobody* is left.
- **H-4 Priority.** A page the user just opened must overtake a 1 GB bulk sync already in flight.
- **H-5 Actor reentrancy.** Every `await` inside an actor is a window where state changed; each one needs an explicit re-validation.
- **H-6 Background transfers across relaunch.** A background `URLSession` finishes while the app is dead; the next launch must re-attach, not duplicate or lose work.
- **H-7 Double residency.** On the Apple tier the OS keeps a pack *and* the module may keep a copy.
- **H-8 Time and determinism.** Backoff, refresh intervals, grace windows — all testable without sleeping.
- **H-9 Backpressure.** Progress/event streams must never grow without bound or flood the UI.
- **H-10 Migration.** Existing installs have `Library/Caches/CDNAssets`, `manifest.json`, `local-checksums.json` and `UserDefaults` sync stamps; none of it may be re-downloaded or orphaned.

---

## 2. Prior art

### 2.1 Where it lives *(verified)*
`ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/` — 11 files:

| File | Role today |
|---|---|
| `CDNAsset.swift` | manifest entry: `identifier`, `fileExtension`, `remotePath`, `localPathComponents`, `localFileName?`, `byteSize?`, `checksum?` |
| `CDNProviding.swift` | `fetchManifest()`, `downloadAsset(_:progress:)` |
| `StaticManifestCDNProvider.swift` | URLSession GET transport; manifest with `reloadIgnoringLocalCacheData`; per-request headers |
| `AWSCloudFrontCDNProvider.swift` | AWS tier: domain + key prefix, app-key header, SHA-256 verification of each download |
| `BackgroundAssetsCDNProvider.swift` | Apple tier (iOS 26+): catalog from an essential asset pack; per-asset `ensureLocalAvailability` + `contents(at:)` copy |
| `CDNProviderFactory.swift` | tier selection (`#available(iOS 26)`), `CDNConfiguration`, `install` |
| `CDNLocalStore.swift` | `Library/Caches/CDNAssets/<pretty path>`, applied-manifest index `manifest.json`, `local-checksums.json`, reconcile (migrate/prune), checksum-aware `hasAsset` |
| `CDNAssetResolver.swift` | on-demand resolve: fetch-first manifest, reconcile, download if missing/stale |
| `CDNSyncCoordinator.swift` | `@MainActor ObservableObject`; `CDNRefreshPolicy`; bulk sync; `verifyFullyAvailable`/`verifyAndRepair`; stamps in `UserDefaults` |
| `CDNSyncProgress.swift` | `idle / upToDate / syncing(fraction,completedCount,totalCount) / complete / failed(reason)` |
| `NetworkAvailabilityMonitor.swift` | `NWPathMonitor`-based retry-when-available |

Consumers: `BasicImagePage` (bundle → local cache → network; candidate extensions `heic, png, jpg, jpeg`), `BasicVideoPage` (bundle → local; extension from the descriptor), `ZTronSVGView`, `CarouselComponent`. The 128 CDN-related tests currently in `Tests/ZTronCarouselCoreTests` (verify the count) are your **characterization baseline**.

### 2.2 Behaviours to preserve
Manifest wire format (§R-MAN-1) · changed checksum ⇒ re-download that asset only · changed directory ⇒ no download · removed entry ⇒ deletion · **reconcile before download** (so moves cost nothing) · **fetch-first resolver** (the applied index is applied state, never a cache consulted instead of a fetch that can succeed) · refresh policies `.oncePerAppVersion` (default) / `.everyLaunch` / `.atMostEvery(interval)`, all of which also re-sync on an app-version change · the three-step fallback chain with steps 1–2 synchronous · two tiers: AWS on iOS 15–25, Apple-hosted on iOS 26+ (the boundary is Apple's, not ours: `AssetPackManager` is iOS 26.0+).

### 2.3 Remote-side facts *(verified; do not re-litigate)*
S3 behind one CloudFront distribution (EU+US edges). `manifest.json` is served with `Cache-Control: max-age=60, must-revalidate`; objects at content-addressed keys `media/<sha256[:16]>/<name>.<ext>` with `public, max-age=31536000, immutable`. A CloudFront Function requires header `x-zombietron-app-key`; no/unknown key ⇒ `403` with an empty body. S3 answers `403` (not 404) for missing keys behind OAC, so a `403` is ambiguous between "bad key" and "no such object". The app key is a scraper filter, not authentication. Apple tier: catalog JSON lives in an *essential* pack (`ZTronCatalog`), media in an *on-demand* pack (`ZTronMedia`); `remotePath` there is `"<packID>/<path inside pack>"`. The example manifests in `Manifests/` (checksum change, directory change, removal — both tiers) are fixtures; reuse them if present in the repo.

### 2.4 Defects of the prior art *(verified in the code — confirm in Stage 0; every one has a requirement below that fixes it)*
- **D-1** One `URLSession` is created *per download* ⇒ no connection reuse, a TLS handshake per asset. → R-NET-2
- **D-2** The bulk sync is a serial `for` loop with `try await`; the first failure aborts the whole sync. → R-SYN-3, R-SYN-6
- **D-3** Foreground-only transfers: nothing continues when the app is suspended. → R-NET-3
- **D-4** No resume, no size cap, no free-space check, no quota/eviction. → R-NET-7/8, R-SYN-11, R-CLN-4
- **D-5** Seven concurrency escape hatches: three `@unchecked Sendable` (`CDNLocalStore`, `NetworkAvailabilityMonitor`, the download delegate) and four `nonisolated(unsafe)` (the resolver's global `installed`, the store's two dictionaries, the monitor's retry table). → R-ENV-4
- **D-6** The sync stamp lives in `UserDefaults` while the files live in `Caches`: after an OS purge the app believes it is synced. → R-STO-2, R-CLN-7
- **D-7** Downloaded files are moved into `tmp` first and leak if the app is killed. → R-STO-3, R-CLN-3
- **D-8** Progress spawns a `Task { @MainActor }` per callback. → R-SYN-12
- **D-9** The manifest is decoded with no limits or validation. → R-MAN-2/3
- **D-10** The pretty-path layout makes a directory change a set of non-atomic file moves. → §4.3
- **D-11** The Apple tier copies each file out of the pack (double residency) via `contents(at:)`. → R-APL-3, R-CLN-10
- **D-12** One unresolved inference: that `AssetPackManager.DownloadStatusUpdate.downloading`'s payload is a Foundation `Progress`. → R-APL-2

---

## 3. Toolchain and platform

- Swift **6.3 or newer** toolchain, **Swift 6 language mode**, strict concurrency complete (the default in Swift 6 mode — also set it explicitly). Check `swift --version`; if older than 6.3, stop and report.
- `// swift-tools-version:` the lowest value that gives Swift 6 mode (**6.0**) unless you use a manifest feature that needs more — downstream packages (ZTronCarouselCore is tools-version 6.0) must be able to depend on this package. The 6.3 requirement is for *building and testing here*, not for consumers.
- **Deployment floor: iOS 15** (matches ZTronCarouselCore). A newer API needs `@available` gating with a working fallback, or an ADR proposing to raise the floor. Never silently raise it. Hosts for tests: macOS, as low as the test framework allows.
- **Warnings-as-errors is enforced by `Scripts/verify.sh` on the command line, never in `Package.swift`** — `unsafeFlags` are rejected for dependencies, and a manifest-level `treatAllWarnings(as: .error)` would break downstream builds when the compiler adds a warning.
- Zero third-party runtime dependencies. Test-only dependencies need an ADR (default: none; Swift Testing ships with the toolchain).
- Foundation-first core: the Model/Storage/Sync targets import Foundation, CryptoKit, os, Network only — **no UIKit, SwiftUI, Combine** (R-CAR-9) — so `swift test` runs on a macOS host without a simulator.

---

## 4. Architecture

### 4.1 Targets (names are fixed — `quality-gates.json` refers to them)

| Target | Depends on | Contains |
|---|---|---|
| `ZTronAssetModel` | — | values, manifest decode/validate/diff, errors, the `RemoteSource` / `TransferBackend` / `TimeSource` contracts |
| `ZTronAssetStorage` | Model | `FileSystem` abstraction, store, index, blobs, integrity, GC/eviction/purge, migration, snapshot |
| `ZTronAssetTransport` | Model | URLSession backends, redirect/key safety, conditional manifest fetch, reachability |
| `ZTronAssetAppleHosted` | Model | BackgroundAssets source (`#if canImport(BackgroundAssets)`, `@available(iOS 26.0, *)`) |
| `ZTronAssetSync` | Model, Storage | planner, engine, scheduling, policies — talks to Transport/AppleHosted **only** through Model protocols |
| `ZTronAssetKit` | all of the above | facade `AssetClient`, main-actor snapshot mirror, observability, composition root, public re-exports |
| `ZTronAssetTestSupport` | Model, Storage | fakes: `FakeFileSystem` (crash points + fault injection), `FakeRemoteSource`, `ManualTimeSource`, `SeededRandom`, `LoopbackHTTPServer` — **not a product** |

No cycles. Only the facade composes concrete types. Two files are reserved for code that can only run on a device: `ZTronAssetTransport/BackgroundSessionBackend.swift` and `ZTronAssetAppleHosted/LiveAssetPackBackend.swift` — each a thin conformer (≤ 250 lines) over a protocol whose logic is fully tested; they are the *only* coverage exclusions (≤ 3 % of lines, enforced).

### 4.2 Concurrency model
- State lives in actors: `actor AssetStore` (storage), `actor SyncEngine` (scheduling). The facade is a `Sendable` final class with immutable stored properties.
- **Synchronous lookup for UI** reads an immutable `AssetSnapshot` value mirrored onto the main actor (`@MainActor final class SnapshotMirror`). The engine publishes a new snapshot; the mirror swaps it. No locks, no `@unchecked`. Reads are isolated reads — O(1), no I/O.
- Blocking work (hashing, copying, directory enumeration) never runs on a cooperative-pool thread for more than ~10 ms at a stretch. *(hint)* Without `Mutex` (iOS 18+), `OSAllocatedUnfairLock` (iOS 16+) and custom actor executors (iOS 17+/18+) at an iOS 15 floor, the portable options are a dedicated GCD queue bridged with `withCheckedContinuation`/`withTaskCancellationHandler`, or chunked work with `Task.yield()` between chunks — decide by ADR and prove it with P-9.
- URLSession delegates are `final`, immutable-state, and forward events into an `AsyncStream.Continuation` (which is `Sendable`) — *(hint)* this usually lets an `NSObject` delegate be `Sendable` without `@unchecked`; if the compiler disagrees, that is one of the ≤ 3 audited escapes.
- Cancellation is structural. Every `await` in an actor documents, in a comment block `// REENTRANCY:`, which invariants are re-validated after resumption; `docs/ARCHITECTURE.md` carries the ledger (H-5).
- Forbidden: `DispatchQueue.main.sync`, semaphores or `DispatchGroup.wait` on a thread that participates in Swift concurrency, global mutable state, `static var`. `static let shared` only for immutable configuration.
- All environment (file system, time, randomness, reachability, power state, remote sources) arrives through one `AssetEnvironment` value; `.live` is the only place that touches the real world.

### 4.3 On-disk layout (recommended — deviate only by ADR) and invariants
Content-addressed blobs + one atomically replaced index:

```
<root>/ZTronAssetKit/v1/
  store.lock                    advisory lock (single writer)
  index.bin                     schemaVersion, generation, applied manifest, per-asset records, sync stamp
  blobs/<aa>/<sha256>.<ext>     immutable, written once, named by the hash of its bytes
  staging/<uuid>.part|.resume   in-progress downloads (owned by an active transfer or garbage)
```

Why: a directory change is an index edit (no file moves — fixes D-10); an atomic update is "write a new blob, flip one index entry, collect the old blob"; identical bytes dedupe; the index can be **rebuilt from blob names + the last manifest** after corruption; no manifest-supplied text ever becomes a path component (R-SEC-2).

Invariants (each needs a test):
- **I-1** Every file under `blobs/` is complete and its name equals the SHA-256 of its bytes.
- **I-2** After launch reconciliation, every `present` index entry references an existing blob, or is flagged `needsHeal`.
- **I-3** A blob is deleted only *after* a snapshot without it was published and its grace window passed (H-2).
- **I-4** Nothing under `staging/` is ever referenced by the index or the snapshot.
- **I-5** The index generation strictly increases; any committed prefix of generations is a valid state.

### 4.4 Storage location — an explicit decision with a default
Default: **`Application Support/` with `isExcludedFromBackup = true`**, file protection `completeUntilFirstUserAuthentication`. Reason: promise 1 cannot hold if the OS may silently purge essential assets from `Caches`; therefore the module owns eviction (R-CLN-4). `StorageLocation.caches` remains selectable for catalogs that are fully regenerable. Record the decision and its trade-offs in `DECISIONS.md` as **NEEDS-HUMAN-REVIEW**; do not change the default without an ADR.

### 4.5 Public API sketch *(illustrative — names may change, contracts may not)*
```swift
public struct AssetID: Hashable, Sendable, Codable, ExpressibleByStringLiteral { … }
public struct AssetClientConfiguration: Sendable { remote, storage: StoragePolicy, network: NetworkPolicy, refresh: RefreshPolicy, … }

public final class AssetClient: Sendable {
    public init(configuration: AssetClientConfiguration, environment: AssetEnvironment = .live)
    public func start() async                                              // open store, load snapshot, maintenance, sync per refresh policy
    @MainActor public func lookup(_ id: AssetID, extensions: [String]) -> AssetLocation?   // O(1), no I/O
    public func resolve(_ id: AssetID, priority: AssetPriority) async throws(AssetError) -> URL
    public func prefetch(_ ids: [AssetID], priority: AssetPriority) -> PrefetchHandle
    public func availability(scope: AssetScope) async -> AvailabilityReport              // no network
    public func ensureAvailable(scope: AssetScope) async throws(AssetError) -> AvailabilityReport
    public func withAsset<T: Sendable>(_ id: AssetID, _ body: @Sendable (URL) async throws -> T) async throws -> T  // lease
    public var events: AsyncStream<AssetEvent> { get }                                    // multi-subscriber, bounded
    public func storageReport() async -> StorageReport
    public func purge(_ request: PurgeRequest) async throws -> PurgeResult
    public func performMaintenance(timeBudget: TimeInterval) async
    public func shutdown() async
}
```

---

## 5. Requirements

Every **MUST** needs at least one test whose `@Test("…")` display name begins with the requirement ID (`@Test("R-STO-3: a blob never appears at its final path before verification")`). Every **SHOULD** you do not implement needs a line in `DECISIONS.md` naming the ID and the reason. Tests that cite an ID not in this file fail the trace gate.

### 5.1 Manifest and model — `ZTronAssetModel`

- **R-MAN-1 [MUST]** Decode both wire shapes — the current bare JSON array of assets, and an envelope `{ "schemaVersion": Int, "assets": [...] }` — ignoring unknown fields; every field beyond the seven existing ones (`identifier`, `fileExtension`, `remotePath`, `localPathComponents`, `localFileName`, `byteSize`, `checksum`) is optional, so every manifest published today still decodes and behaves as before. Round-trip tests use the shipped example manifests.
- **R-MAN-2 [MUST]** Treat the manifest as untrusted input. Limits: ≤ 100,000 entries; ≤ 32 MiB payload; `identifier` non-empty, ≤ 256 UTF-8 bytes, no control characters; `fileExtension` matches `[A-Za-z0-9]{1,8}`; `checksum` is 64 hex characters when present; `byteSize` within `0…maxAssetBytes`; `remotePath` relative, ≤ 1,024 bytes, no `..` segment, scheme, authority or control character. Structural violations (undecodable, over limits, duplicate identifiers) reject the whole manifest with a typed error; per-entry violations quarantine that entry with a diagnostic and never crash.
- **R-MAN-3 [MUST]** Fuzzed input — random bytes, truncated and mutated manifests, deeply nested JSON, huge strings — never crashes, never takes longer than 1 s for 32 MiB, and never allocates more than 4× the payload. Seeded generator; failing seeds are printed.
- **R-MAN-4 [MUST]** `ManifestDiff` classifies every identifier exactly once as `added`, `removed`, `contentChanged` (checksum differs), `metadataChanged` (same checksum; `remotePath`, directory, file name, tags or policy differ) or `unchanged`, in O(n). Property tests: `diff(a,a)` is all-unchanged; applying `diff(a,b)` to `a` yields `b`; classification is a partition.
- **R-MAN-5 [MUST]** Content identity is the SHA-256 when present. Entries without a checksum (legacy) are supported with documented weaker semantics: existence-only trust, re-download only when `remotePath` changes.
- **R-MAN-6 [SHOULD]** Optional extension fields: `tags: [String]` and `policy: "essential" | "standard" | "onDemand"` (default `standard`), consumed by scoping (R-CAR-5) and eviction (R-CLN-4). Absent fields reproduce today's behaviour exactly.
- **R-MAN-7 [MUST]** All model types are `Sendable` value types — `Hashable`/`Codable` where meaningful — and perform no I/O.

### 5.2 Storage — `ZTronAssetStorage`

- **R-STO-1 [MUST]** All persistent state lives under one root directory with the documented, versioned layout of §4.3 (or the ADR'd alternative); `docs/ARCHITECTURE.md` specifies every file and its meaning. Nothing is written elsewhere — not `UserDefaults`, not `tmp` — except OS-owned URLSession temp files, which are moved into `staging/` immediately.
- **R-STO-2 [MUST]** Lifetime coupling: everything that describes the store's contents (applied manifest, per-asset records, last-sync stamp, refresh bookkeeping) lives *inside* the root, so deleting or purging the root resets all of it together. Legacy `UserDefaults` sync keys are migrated once, then removed.
- **R-STO-3 [MUST]** Blobs are immutable and published atomically: a blob never appears under its final path until fully written, size-checked and hash-verified; publishing is a same-volume atomic rename.
- **R-STO-4 [MUST]** The index is replaced atomically (write temp → durable flush → rename), carries `schemaVersion` and a strictly increasing `generation`, and a torn, corrupt or newer-schema index never causes blobs to be deleted: rebuild it from blob names plus the last known manifest where possible, otherwise start empty and re-sync.
- **R-STO-5 [MUST]** Crash safety, exhaustively: for a scripted multi-asset scenario, injecting a crash at *every* file-system operation boundary and reopening the store leaves invariants I-1…I-5 intact. The test enumerates every crash point; it does not sample.
- **R-STO-6 [MUST]** Every file-system effect goes through a small injectable `FileSystem` abstraction (real and in-memory conformers) that supports fault injection (ENOSPC, EIO, EACCES, rename failure, partial write) and crash points. No production code outside the real conformer touches `FileManager` or POSIX.
- **R-STO-7 [MUST]** Zero file-system or hashing work on the main thread, proven by the fake recording the calling thread during every UI-facing API (`lookup`, `prefetch`, `events`, `resolve` entry).
- **R-STO-8 [MUST]** The root is excluded from backup and uses file-protection class `completeUntilFirstUserAuthentication` (so background work after first unlock can proceed); verified through the fake's attribute recording, with a device check in `docs/DEVICE-TEST-PLAN.md`.
- **R-STO-9 [MUST]** Single writer: a second open of the same root (second client, test runner, extension) is detected via an advisory lock and fails or queues deterministically instead of corrupting state.
- **R-STO-10 [MUST]** The storage location is an explicit, documented decision with the default of §4.4 and a configurable alternative.
- **R-STO-11 [MUST]** Legacy migration: if the prior-art layout (`Library/Caches/CDNAssets` + `manifest.json` + `local-checksums.json`) exists, adopt every file whose checksum verifies — moved, not re-downloaded — drop the rest, remove the legacy directory, and do so idempotently and crash-safely. Tested with fixtures generated by running the prior-art code.
- **R-STO-12 [SHOULD]** A compact binary index meeting P-2, with a golden fixture committed per schema version under `Tests/Fixtures/` and a migration chain test.
- **R-STO-13 [MUST]** Readers get an immutable `AssetSnapshot` value with O(1) lookup; mutation never exposes torn state; publishing a snapshot is atomic with respect to readers.

### 5.3 Integrity

- **R-INT-1 [MUST]** SHA-256 is computed by streaming with bounded memory (buffer ≤ 1 MiB), off the cooperative pool, and is cancellation-aware.
- **R-INT-2 [MUST]** Every download is verified — size first, then hash — before publication. A mismatch deletes the staged bytes, throws a typed error, is counted in metrics, and is never published.
- **R-INT-3 [MUST]** Repeated mismatches for one asset back off and finally mark it `failed` until its manifest entry changes — no infinite re-download loop.
- **R-INT-4 [SHOULD]** Throttled, resumable deep verification of resident blobs (`verifyIntegrity`), repairing corrupt entries.
- **R-INT-5 [MUST]** Entries without a checksum are admitted only when `allowUnverifiedAssets` is true (default true, for compatibility) and are flagged `unverified` in every report.
- **R-INT-6 [MUST]** The recorded checksum is the hash of the bytes the module actually wrote, never the manifest's claim.

### 5.4 Transport — `ZTronAssetTransport`

- **R-NET-1 [MUST]** `RemoteSource` and `TransferBackend` abstractions let the whole engine run against fakes with no network.
- **R-NET-2 [MUST]** One long-lived foreground `URLSession` (HTTP/2 connection reuse) whose delegate multiplexes tasks and is `Sendable` without `@unchecked`; per-download sessions are forbidden (D-1). Proved by P-10 against the loopback server.
- **R-NET-3 [SHOULD]** A discretionary background `URLSession` for bulk transfers, re-attaching in-flight tasks after relaunch (`getAllTasks` reconciled with engine state) and exposing the AppDelegate hook (`handleBackgroundEvents(identifier:completionHandler:)`); falls back to foreground when the hook is not wired. Lives in `BackgroundSessionBackend.swift`.
- **R-NET-4 [MUST]** The app key is sent only to allow-listed hosts and stripped on any cross-host or non-HTTPS redirect; HTTPS only; ≤ 5 redirects. The key type redacts itself in `description`, `debugDescription`, `Mirror`, logs, errors and diagnostics — tested with a canary key. *(hint)* Assume custom headers survive redirects unless stripped.
- **R-NET-5 [MUST]** Manifest fetch is a conditional request (`If-None-Match` with the stored ETag), handles `304`, and never returns a stale copy from URLSession's own cache.
- **R-NET-6 [MUST]** HTTP and URL errors map to a closed `TransferError` taxonomy the engine acts on: transient (timeout, connection lost, 5xx, 429 with `Retry-After`), permanent-missing (404/410), authentication (401/403), integrity, insufficient space, cancelled, offline. A `403` is reported as authentication-rejected *or* possibly-missing per §2.3, never silently one of them.
- **R-NET-7 [MUST]** The final staged size is compared to `byteSize` (never `Content-Length`, which is the compressed size when the server compresses); a transfer announcing more than `maxAssetBytes` is aborted early.
- **R-NET-8 [SHOULD]** Interrupted downloads resume (resume data or `Range` with `If-Range`); resumed bytes are never trusted without the final hash.
- **R-NET-9 [MUST]** Reachability uses `NWPathMonitor` behind a protocol, is event-driven (no polling) and exposes `satisfied`, `expensive`, `constrained`.
- **R-NET-10 [MUST]** Engine priority maps to URLSession task priority / scheduling in a documented table, with engine-level tests that a promoted asset is scheduled first.

### 5.5 Apple-hosted tier — `ZTronAssetAppleHosted`

- **R-APL-1 [MUST]** Conforms to the same `RemoteSource` contract; compiled only where BackgroundAssets exists and annotated `@available(iOS 26.0, *)`; all logic is exercised through a fake `PackBackend`; only `LiveAssetPackBackend.swift` touches the real framework.
- **R-APL-2 [MUST]** Resolve against the *installed SDK* (its `.swiftinterface` / headers; web docs only as a cross-check) and record in `docs/APPLE-API-VERIFICATION.md`: the payload type of `AssetPackManager.DownloadStatusUpdate.downloading` (D-12); whether a stable file URL for a pack file exists (so assets can be served in place); the API to remove a pack; update-check semantics. Anything unresolvable stays behind the protocol, marked `UNVERIFIED`.
- **R-APL-3 [SHOULD]** Avoid double residency (D-11): serve in place if the SDK supports stable URLs, else adopt-and-release (R-CLN-10). Decision in an ADR.
- **R-APL-4 [MUST]** Catalog-in-pack mode: the manifest JSON is read from an *essential* pack; update checks are best-effort; offline falls back to the last installed catalog.
- **R-APL-5 [MUST]** Tier selection (iOS ≥ 26 *and* an Apple source configured ⇒ Apple; otherwise AWS; an `awsOnly` kill switch) is a pure function with exhaustive tests; the only `#available` check in the module lives there.

### 5.6 Sync — `ZTronAssetSync`

- **R-SYN-1 [MUST]** The planner is a pure, deterministic function `(manifest, snapshot, scope, policy, freeSpace) → SyncPlan` listing fetch / relocate / prune work, byte totals and a stable order. Property-tested.
- **R-SYN-2 [MUST]** The engine is an actor-isolated state machine with validated transitions — `absent → queued → downloading → verifying → committing → present`, plus `failed(retryAt)` and `blocked(reason)`. Every `await` carries a `// REENTRANCY:` note naming what is re-validated.
- **R-SYN-3 [MUST]** Bounded parallelism (default 4, configurable 1…16) with three priority lanes — `userInitiated` > `prefetch` > `bulk`. A request for an in-flight bulk asset promotes it; for a queued one it jumps the queue (D-2, H-4).
- **R-SYN-4 [MUST]** Single-flight: concurrent requests for one asset share one transfer. The transfer is cancelled only when the last interested caller cancels; each caller's cancellation is independent (H-3).
- **R-SYN-5 [MUST]** Retries use exponential backoff with full jitter through injected randomness and `TimeSource`, honour `Retry-After`, cap attempts per asset, and trip a circuit breaker after repeated authentication failures or sustained 5xx.
- **R-SYN-6 [MUST]** One failing asset never aborts a sync. Failures are recorded per asset and the run ends `complete`, `completeWithFailures` or `blocked`, with a partial-success report (D-2).
- **R-SYN-7 [MUST]** Bulk work obeys `NetworkPolicy` (cellular, Low Data Mode, expensive networks), Low Power Mode and thermal state; explicit user-initiated requests may override per policy.
- **R-SYN-8 [MUST]** Reconcile-before-download is preserved: relocations and prunes are applied before any fetch, so moves cost zero downloads.
- **R-SYN-9 [MUST]** Refresh policies `.oncePerAppVersion` (default), `.everyLaunch`, `.atMostEvery(TimeInterval)`; an app-version change always triggers a sync; the stamp lives in the index (R-STO-2); `isSyncDue` and `lastSyncedAt` equivalents exist.
- **R-SYN-10 [MUST]** `availability(scope:)` (present / missing / stale / failed counts, no network) and `ensureAvailable(scope:)` (reconcile and fetch what is missing at user-initiated priority) both honour cancellation — the "never a mid-use download" guarantee.
- **R-SYN-11 [MUST]** Free space is checked before executing any plan; a shortage evicts (policy permitting), otherwise fails with a typed `insufficientSpace(required:available:)` and no partial side effects (D-4).
- **R-SYN-12 [MUST]** Progress and events are a multi-subscriber broadcast of `AsyncStream<AssetEvent>` with bounded buffering: newest-wins for progress, rate-limited (default ≤ 10 Hz), terminal events never dropped; a terminating subscriber releases its resources; no unbounded queue anywhere (D-8, H-9).
- **R-SYN-13 [MUST]** Assets that failed as `offline` or `transient` are retried when the network path becomes satisfied, without polling.
- **R-SYN-14 [MUST]** The engine is idle-silent: with nothing to do it owns no timer and no scheduled task (introspectable counters equal zero).
- **R-SYN-15 [MUST]** `shutdown()` cancels all tasks, finishes all streams and flushes the index; any API used afterwards fails with a typed error; tests prove no task leaks.
- **R-SYN-16 [SHOULD]** `performMaintenance(timeBudget:)` runs GC, eviction and deep verification inside a budget suitable for a `BGProcessingTask` handler that the app registers.

### 5.7 Cleanup — storage lifecycle

- **R-CLN-1 [MUST]** Prune: blobs not referenced by the applied manifest are removed after relocation, respecting leases and the grace window.
- **R-CLN-2 [MUST]** Orphan GC (mark and sweep): any file in `blobs/` or `staging/` that is neither referenced nor owned by an active transfer is removed after a grace period; idempotent and crash-safe.
- **R-CLN-3 [MUST]** Staging GC: partial files and resume data without an owner, or older than a threshold, are removed at launch and after sync (D-7).
- **R-CLN-4 [MUST]** Quota: `StoragePolicy` carries a budget (absolute bytes or a fraction of free space) and `reserveFreeBytes`. Eviction order: not `essential`/pinned, not leased, not accessed within `minimumResidency`, least-recently-used first (ties: larger first), down to a hysteresis target (default 90 % of budget). (D-4)
- **R-CLN-5 [MUST]** Eviction and prune never remove a leased asset or one accessed within the grace window, and snapshot publication always precedes file deletion (I-3, H-2).
- **R-CLN-6 [MUST]** User-initiated `purge(.all | .evictable | .scope(…))` returns bytes freed, leaves the store consistent, and makes a sync due afterwards.
- **R-CLN-7 [MUST]** OS-purge recovery: if the root or its blobs vanish or are partly emptied between launches, launch reconciliation detects it, resets the sync stamp, and heals through re-sync or lazy resolve — no crash, no stale "synced" claim (D-6).
- **R-CLN-8 [MUST]** Unreadable or corrupt assets: `reportUnreadable(id)` quarantines the entry, removes the blob, and schedules a re-download with backoff.
- **R-CLN-9 [MUST]** `StorageReport`: bytes by kind and by state, pinned / evictable / staging / orphan bytes, free disk, last cleanup time.
- **R-CLN-10 [SHOULD]** After verified adoption from an Apple pack, release the OS-held duplicate when policy allows (D-11, R-APL-3).
- **R-CLN-11 [MAY]** A `MemoryPressureSource` protocol lets the carousel register derived in-memory caches (decoded images) for purging on memory warnings; the UIKit implementation lives outside the module. Inventory any ad-hoc carousel caches in Stage 0 and say what you did.
- **R-CLN-12 [MUST]** Every cleanup operation is idempotent (a second run is a no-op) and safe under cancellation at any suspension point.

### 5.8 Carousel integration — `ZTronAssetKit` and ZTronCarouselCore

- **R-CAR-1 [MUST]** The `AssetClient` facade exposes at least: synchronous main-actor `lookup` (O(1), no I/O), async `resolve` (priority, cancellation), `prefetch` returning a cancellable handle, `availability`, `ensureAvailable`, `events`, `storageReport`, `purge`, `performMaintenance`, `shutdown`.
- **R-CAR-2 [MUST]** Fallback-chain parity with the prior art's `BasicImagePage`: bundle → local → network, steps 1–2 synchronous, step 3 asynchronous, with candidate-extension lookup (`heic, png, jpg, jpeg`; `svg`; video via the descriptor's extension; audio `wav, mp3`) and identical observable behaviour.
- **R-CAR-3 [MUST]** A prefetch-window helper takes ordered identifiers and a current index and yields a prioritised set (±N, default 2), cancelling assets that left the window and never duplicating transfers.
- **R-CAR-4 [MUST]** Handles cancel on `cancel()` and on deinit, leaving no transfer running for nobody (ref-counted via R-SYN-4).
- **R-CAR-5 [MUST]** `AssetScope` (all / identifiers / tags / prefix — a value type, no closures) lets ZTronCarouselCore map paywall and filter state to "what to keep and prefetch"; the module imports none of that code.
- **R-CAR-6 [MUST]** Compatibility shims in ZTronCarouselCore keep every pre-existing public CDN symbol compiling (`CDNAsset`, `CDNProviding`, `CDNLocalStore`, `CDNAssetResolver.installed`, `CDNSyncCoordinator`, `CDNRefreshPolicy`, `CDNProviderFactory` / `CDNConfiguration`, `NetworkAvailabilityMonitor`), deprecated where redundant, with the existing CDN tests passing unchanged or ported one-to-one per `MIGRATION.md` (no test silently deleted).
- **R-CAR-7 [MUST]** Errors are typed, UI-mappable, `Sendable` and `Equatable`: offline, authRejected, notFound, insufficientSpace, integrityFailure, serverUnavailable, cancelled, storageUnavailable.
- **R-CAR-8 [SHOULD]** A lease API (`withAsset(id) { url in … }`) pins an asset while in use (long video playback) so eviction cannot pull the file away.
- **R-CAR-9 [MUST]** No production target imports UIKit, SwiftUI or Combine. Bridges (Combine `ObservableObject`, ZTronObservation) live in ZTronCarouselCore.

### 5.9 Observability and security

- **R-OBS-1 [MUST]** `os.Logger` and `OSSignposter` (subsystem `com.ztron.assetkit`; categories `store`, `sync`, `transport`, `apple`) with signpost intervals for plan, transfer, verify, commit, gc, eviction; privacy-annotated; no secrets.
- **R-OBS-2 [MUST]** An in-memory `MetricsSnapshot` (bytes downloaded, requests, retries and failures by class, hits/misses, evictions, GC bytes) is readable through the API and tested.
- **R-OBS-3 [SHOULD]** `diagnosticReport()` returns JSON (versions, configuration minus secrets, state counts, last N errors) for support.
- **R-SEC-1 [MUST]** No secret ever appears in logs, errors, reports, `dump` or `Mirror` output (canary-key test).
- **R-SEC-2 [MUST]** No path derived from manifest text can escape the root; manifest-supplied names are never used as path components without sanitisation (traversal tests, fuzz).
- **R-SEC-3 [MUST]** No `NSAllowsArbitraryLoads`, no private API, no runtime hacks.

### 5.10 Environment and engineering

- **R-ENV-1 [MUST]** Time and randomness are injected (`TimeSource`, seeded generator); `Date()`, `DispatchTime.now()`, `Task.sleep` and `SystemRandomNumberGenerator` appear in production code only inside the live conformers.
- **R-ENV-2 [MUST]** The deployment floor matches ZTronCarouselCore (iOS 15) unless an ADR says otherwise; newer APIs are `@available`-gated with a working fallback.
- **R-ENV-3 [MUST]** Zero third-party runtime dependencies.
- **R-ENV-4 [MUST]** Zero `@unchecked Sendable`, `nonisolated(unsafe)`, `unsafeBitCast`, `Unmanaged`, `unowned(unsafe)`, mutable-pointer use, `assumeIsolated` or `@preconcurrency`, except at most three audited exceptions, each marked `// UNSAFE-AUDIT: U-nnn` in code and justified in `docs/UNSAFE-AUDIT.md` (invariant that makes it safe, and the test that would fail if the invariant broke). Enforced by the unsafe gate (D-5).
- **R-ENV-5 [MUST]** The module builds clean (zero warnings) in debug and release under `-warnings-as-errors` with Swift ≥ 6.3, and compiles for iOS (`generic/platform=iOS`) as well as the macOS test host.
- **R-ENV-6 [SHOULD]** Public async APIs use typed throws where the compiler and the iOS 15 floor allow; otherwise a single closed `AssetError`.

---

## 6. Performance budgets

Reference: an Apple-silicon Mac, **release** configuration, N = 10,000 assets unless stated. Benchmarks are Swift Testing suites **named `*Benchmarks`** (`verify.sh` skips them in the normal run and runs them with `-c release`). Every threshold is **read from `Scripts/quality-gates.json` → `budgets`** — no literal thresholds in benchmark code; the file is hash-pinned. If a budget is genuinely infeasible, attach a profile and propose a new number in `DECISIONS.md` for the human; never edit the file or a benchmark to make it pass. Every benchmark's display name starts with its ID (`@Test("P-1: lookup stays O(1) and under budget")`). Budgets are *scaling-aware* where possible (ratios), because absolute numbers vary by machine and ratios don't.

| ID | What is measured | Budget (see JSON keys) |
|---|---|---|
| P-1 | `lookup` on the main actor, warm, N = 10,000 | p99 ≤ `lookup_p99_us`; time at N=10,000 ≤ `scale_ratio_max` × time at N=100 |
| P-2 | Cold index load, off the main thread | ≤ `index_load_ms` |
| P-3 | Remote manifest decode + validate (≈ 3.3 MB JSON) | ≤ `manifest_decode_validate_ms` |
| P-4 | Plan (diff + scope + ordering), 10,000 vs 10,000 with 10 % churn | ≤ `plan_ms`; doubling N grows time ≤ `doubling_ratio_max` × |
| P-5 | Index commit; sustained commit rate during a bulk sync | ≤ `index_commit_ms`; ≤ `commits_per_s_max` per second |
| P-6 | Streaming SHA-256 of a 256 MiB file | ≥ `hash_mb_per_s_min` MB/s and ≥ `vs_oneshot_min_ratio` × one-shot in-memory CryptoKit throughput; memory delta ≤ `memory_delta_mib_max` MiB |
| P-7 | Peak memory added by a bulk sync of a synthetic `catalog_gib` GiB catalog (fake source, real files); delta must not grow with catalog size | ≤ `sync_memory_delta_mib_max` MiB |
| P-8 | Main-thread cost attributable to the module | ≤ `main_thread_fs_calls_max` file-system calls or hashes on main; every UI-facing call ≤ `ui_call_ms_max` ms |
| P-9 | Cooperative-pool health: `concurrent_resolves` concurrent resolves + hashing while a heartbeat task ticks every `heartbeat_tick_ms` ms | heartbeat gap p99 ≤ `heartbeat_gap_ms_p99_max` ms |
| P-10 | Connection reuse: `assets` small assets over a loopback server | ≤ `connections_max` TCP connections |
| P-11 | Parallel speed-up: `assets` assets, `server_latency_ms` ms server latency, concurrency `concurrency` vs 1 | ≥ `speedup_min` × faster |
| P-12 | `AssetClient.init` | ≤ `init_ms_max` ms and no I/O on the caller's thread |
| P-13 | Reclaiming `blobs` blobs (eviction/GC) | ≤ `gc_total_s_max` s in total, in batches ≤ `batch_ms_max` ms between suspension points, judged on the p99 of the batch durations (owner ruling 2026-10-29, ADR-050 option A) |
| P-14 | Idle cost after quiescence | ≤ `idle_timers_max` timers and ≤ `idle_tasks_max` scheduled tasks (engine introspection) |

---

## 7. Test strategy and quality gates

### 7.1 Gates (all enforced by `bash Scripts/verify.sh --full`; thresholds in `Scripts/quality-gates.json`)

| ID | Gate | Pass condition |
|---|---|---|
| Q-1 | Build | zero warnings, debug **and** release, `-warnings-as-errors`; compiles for `generic/platform=iOS` |
| Q-2 | Coverage | line coverage ≥ **80 %** overall, ≥ 70 % for every production target, ≥ **90 %** for `ZTronAssetStorage` and `ZTronAssetSync`; the only exclusions are the two reserved device-only files (≤ 3 % of lines) and `ZTronAssetTestSupport` |
| Q-3 | Strict concurrency | Swift 6 mode; unsafe gate clean (≤ 3 audited escapes); full suite clean under Thread Sanitizer |
| Q-4 | Determinism | no real sleeping or wall-clock waits in tests (only `ManualTimeSource`); seeds printed; tests order-independent and parallel-safe; no network except an ephemeral-port loopback server |
| Q-5 | Stability | the full suite passes N consecutive times (`tests.full_run_repeats`) — zero flakes |
| Q-6 | Traceability | every MUST requirement and every budget `P-n` has ≥ 1 test whose display name starts with its ID; no test cites an unknown ID |
| Q-7 | Documentation | 100 % of `public`/`open` declarations carry `///` (≤ 10 `docs:exempt`) |
| Q-8 | Mutation probes | ≥ 12 deliberate defects injected by an *independent* agent, each caught by at least one test (§7.4) |
| Q-9 | Harness integrity | `Scripts/` unchanged since tag `harness-frozen`; `quality-gates.json` hash equals the one in the goal condition |
| Q-10 | Compatibility | the pre-existing CDN tests pass through the ZTronCarouselCore shims (or are ported one-to-one per `MIGRATION.md`) |

### 7.2 Rules for tests
Swift Testing (`@Test`, `#expect`, `#require`, `confirmation`, parameterised `arguments:`); `.timeLimit(.minutes(1))` on anything that awaits, so a deadlock fails instead of hanging. One behaviour per test; the name states it. **Coverage is a floor, not the goal**: no assertion-free tests, no `#expect(true)`, no tests of private details to touch lines, no excluded code. When a line is hard to cover the design usually needs a seam — add the seam. Property and model-based tests use a seeded generator and print the failing seed.

### 7.3 Mandatory scenarios (each must exist; most map to MUST requirements)
- **Crash at every boundary** during: first sync · checksum-change update · directory change · removal · eviction · legacy migration (R-STO-5, R-STO-11).
- **Faults:** ENOSPC mid-download and mid-index-commit · EIO on rename · EACCES · a torn index · a newer-schema index · a second opener hitting the lock.
- **Concurrency:** 100 callers on one asset with random cancellations (single-flight) · a cancellation storm · priority promotion of an in-flight bulk transfer · shutdown mid-flight (no leaked tasks) · event subscribers that stall or terminate.
- **Network (fake backend and loopback server):** 403 circuit breaker · 429 with `Retry-After` · 5xx backoff on `ManualTimeSource` · offline→online recovery · redirect to another host strips the key · manifest `304` · gzip response with decoded size ≠ `Content-Length` · announced size over the cap · truncated body · connection reset mid-download with resume.
- **Manifest:** the shipped example series (both tiers) · fuzz · limit boundaries · duplicate identifiers · traversal attempts · every optional field absent.
- **Storage lifecycle:** OS-purge simulation between launches (delete `blobs/`, delete the root, delete half the blobs) · LRU order, essential/pinned, leases, grace window, hysteresis · snapshot-before-delete ordering · backup/protection attributes recorded · golden index fixtures per schema version.
- **Model-based:** random operation sequences (store, relocate, remove, evict, crash + reopen) checked against a trivial in-memory oracle with I-1…I-5 asserted after every step.
- **Facade parity:** the cases from the prior art's `BasicImagePageFallbackTests`, re-expressed on `AssetClient`; `lookup` performs zero file-system calls on the main thread.
- **Compatibility:** the pre-existing CDN tests run against the shims.

### 7.4 Mutation probes (Q-8)
In Stage 3 an agent that did **not** write the code injects ≥ 12 deliberate defects one at a time and records, in `docs/MUTATION-PROBES.md`, the diff and the test that failed. Suggested probes: skip hash verification · publish a blob before verification · delete before publishing the snapshot · drop the lock · ignore `Retry-After` · keep the app key on a cross-host redirect · cancel a transfer when *any* waiter cancels · off-by-one in LRU order · treat `403` as transient · forget to reset the sync stamp after a purge · evict a leased asset · swallow ENOSPC. A surviving mutant ⇒ write the missing test.

---

## 8. Deliverables

Package `ZTronAssetKit` (targets of §4.1; library product `ZTronAssetKit`), tests per target, `Scripts/` (frozen after Stage 0), and under `docs/`: `RECON.md`, `BASELINE.md`, `ARCHITECTURE.md` (layout, invariants, state machines, the REENTRANCY ledger, the ten hard problems), `DECISIONS.md` (ADRs; **NEEDS-HUMAN-REVIEW** tags), `UNSAFE-AUDIT.md`, `APPLE-API-VERIFICATION.md`, `MUTATION-PROBES.md`, `TRACEABILITY.md` (generated), `DEVICE-TEST-PLAN.md` (what only a physical device can prove: background session re-attachment, Apple-hosted packs through TestFlight, low-storage behaviour, memory warnings), `VERIFICATION.md` (what was run, its output, what was *not* verified), `RESIDUAL-RISKS.md`. In ZTronCarouselCore, on its own branch: the adapters and shims, `MIGRATION.md`, the pre-existing tests passing. A `README.md` with a 20-line quick start.

---

## Appendix A — Swift 6 diagnostics already met in this codebase *(verified)*
1. A `@MainActor` static function used as the default argument of a `@Sendable` closure parameter ⇒ error in a nonisolated context. Fix: make the function `nonisolated`.
2. A non-`Sendable` descriptor type captured by a `Task` or escaping `@Sendable` closure. Fix: carry a `Sendable` value (the identifier `String`) across the boundary, never the object.
3. A mutable local `var` captured by an escaping `@Sendable` closure. Fix: keep the state in an actor, or publish it through a stream — never mutate a captured local from a concurrent closure.

## Appendix B — iOS 15 floor traps *(hint — the compiler is the authority; every availability error is a design signal, never a reason to raise the floor or annotate the whole module)*
`Mutex`/`Synchronization` (iOS 18) · `OSAllocatedUnfairLock` (iOS 16) · `Observation` (iOS 17) · `Duration`, `Clock`, `ContinuousClock`, `Task.sleep(for:)` (iOS 16 — use `Task.sleep(nanoseconds:)` or your `TimeSource`) · `URL(filePath:)`, `URL.appending(path:)` (iOS 16 — use `appendingPathComponent`) · `Regex` (iOS 16) · custom actor and task executors (iOS 17/18) · `AsyncStream.makeStream(of:)` (check) · `Task.immediate` (check). Available at iOS 15: `CryptoKit`, `Network.framework`, `os.Logger`, `OSSignposter`, async `URLSession` APIs, `withTaskCancellationHandler`, `AsyncStream`, typed throws (compile-time).

## Appendix C — verifying Apple APIs without guessing
Prefer the installed SDK: `SDK=$(xcrun --sdk iphoneos --show-sdk-path)`; search `$SDK/System/Library/Frameworks/BackgroundAssets.framework` and `$SDK/usr/lib/swift` for `.swiftinterface` / `.tbd` / headers and read the declaration and its `@available`. A 20-line probe file compiled with `xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios15.0` answers "does this exist at iOS 15?" definitively. Use web documentation only as a cross-check, and record the evidence in `docs/APPLE-API-VERIFICATION.md`.
