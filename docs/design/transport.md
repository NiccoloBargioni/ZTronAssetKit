# Design — transport and the Apple-hosted tier (`ZTronAssetTransport`, `ZTronAssetAppleHosted`)

**Status:** Stage 1, Phase A draft by the transport drafter, for Phase B adversaries and Phase C contracts.
**Owns:** H-6, H-7 · R-NET-1…10 · R-APL-1…5 · R-SEC-1 · R-SEC-3 · R-CLN-10 · budgets P-10 and P-11.
**Read:** CLAUDE.md; SPEC §2 (§2.3 remote facts are authoritative), §4.1, §4.2, §5.4, §5.5, §5.9, §6, App. B and C; `docs/RECON.md`; `docs/DECISIONS.md` (ADR-001…011); `docs/BASELINE.md`; `docs/APPLE-API-VERIFICATION.md` (relied on, and cited as **AAV §n**). I also read the parallel `docs/design/sync.md` and `docs/design/store.md` to reconcile interfaces (§15). Prior art: `StaticManifestCDNProvider.swift`, `BackgroundAssetsCDNProvider.swift`, `NetworkAvailabilityMonitor.swift` (read-only).
**Evidence:** everything marked **E-n**, **TC-n**, **NEG-n** or **CAP-n** was run in this session on the toolchain below. Prototype sources, build logs and raw output are in `.build-probe-transport/` (git-ignored). §17 shows how to reproduce them. Nothing in this document comes from memory without being marked *(unverified)*.

| Item | Value |
|---|---|
| Toolchain | Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1), Xcode 27.0, host macOS 27.0 (arm64, Apple M3) |
| Prototype | 2,651 lines in 4 modules (`TransportProto`, `AppleProto`, `LoopbackProto`, `Experiments`). Clean release build at the macOS 12 floor with `-warnings-as-errors`: **0 errors, 0 warnings** (`out/build-macos12-release.txt`). |
| Floors | iOS 15.0 / macOS 12.0, Swift 6 language mode, `StrictConcurrency=complete` |
| Unsafe-gate patterns in all prototype sources | **0** (the 9 regexes of `quality-gates.json`, §17) |

---

## 0. Decisions at a glance

| # | Decision | Why (evidence) |
|---|---|---|
| T-1 | **One long-lived, ephemeral foreground `URLSession`** with a cache-less configuration and `httpMaximumConnectionsPerHost = 6` (never more than 8). | 500 × 1 KiB at concurrency 5 used **5** TCP connections, against 50 for 50 downloads with the D-1 pattern (E-1). P-10 needs ≤ 8. |
| T-2 | **Stateless delegate.** One `final class SessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable` holding only `let`s. Per-transfer routing goes through a **per-task mailbox** (`URLSessionTask.delegate`, iOS 15+) that implements no method, so URLSession forwards every callback to the session delegate, which reads `task.delegate`. **No table, no lock, no `@unchecked`, no pump task.** | Compiles clean for iOS 15 and macOS 12 (TC-1). A `var` breaks it (NEG-1, NEG-2). 0 task messages fell back to the session stream (E-10). |
| T-3 | **Deterministic staging names** `staging/<TransferID>.part` and `.resume`, where `TransferID = "c-" + sha256`. The name travels in `URLSessionTask.taskDescription`, so `didFinishDownloadingTo` moves the file synchronously without any per-task state, and background tasks keep it across relaunch. | C4 (no UUID randomness). H-6 needs it: a staged file is self-describing at launch. Deviates from SPEC §4.3 `<uuid>` and from store.md → ADR-T3, **NEEDS-HUMAN-REVIEW**. |
| T-4 | Engine-facing transfers return a **`TransferHandle`** whose `setPriority` / `pause` / `cancel` are **synchronous and nonisolated**. It replaces sync.md's control stream: no per-transfer consumer task, and no `.bufferingNewest(1)` coalescing that can swallow a `.pause`. | E-17: promote → `0.75`, pause → `.paused(resumable: true)`, resume → 206, hash OK. |
| T-5 | **Closed `TransferError`** with 8 cases. The 403 ambiguity is a dedicated case, `authentication(.forbiddenAmbiguous(ForbiddenEvidence))`, carrying a *hint* and never a verdict. Errors carry no URL, header or `URLError` object. | E-8 maps every status through the real delegate. §2.3. |
| T-6 | **Redirects:** allow-listed hosts only; HTTPS only (plain HTTP only for loopback, and only through a `package` test policy); ≤ 5 hops, counted with a `URLProtocol` request property. The key survives only while every hop stays on the original origin. **The key is never put in `httpAdditionalHeaders`.** | E-6a…f. E-6b proves custom headers survive redirects. E-6c proves `httpAdditionalHeaders` defeats stripping. |
| T-7 | **Conditional manifest fetch** through a *download task*: `If-None-Match`, 304 → `notModified`, an ephemeral session with `urlCache = nil` and `.reloadIgnoringLocalCacheData`, and the 32 MiB cap enforced while streaming. | E-7: 304 passes through, and no cached copy is served even under `max-age=60`. E-9c. |
| T-8 | **Size:** compare the staged (decoded) size with `byteSize`; abort early when the *announced* or *written* size exceeds the cap. **Resume** with URLSession resume data (which sends `Range` + `If-Range`). Resumed bytes always go through the store's hash. | E-3 (gzip: Content-Length 988, decoded 315,000), E-4b, E-9a/b, E-5 (resume OK, and a lying server is caught only by the hash), E-14/E-16. |
| T-9 | **H-6:** the background session is built (thin driver ≤ 250 lines; coordinator, reconciler and hook all testable) but **off by default**. A key-bearing transfer may use it only when the owner explicitly accepts that **R-NET-4 cannot be enforced in a background session**. | NSURLSession.h: *"For tasks in background sessions, redirections will always be followed and this method will not be called."* E-13: the background session sent the canary key to the redirect target. ADR-T1, **NEEDS-HUMAN-REVIEW**. |
| T-10 | **H-7:** adopt-and-release. Stream the pack file (`descriptor` → `FileHandle`) into staging → hash → blob. `remove(assetPackWithID:)` runs once **every** catalog entry of that media pack is adopted. The catalog pack is never released. | AAV §1.4: no stable URL. AAV §1.5: removal is whole-pack. ADR-T2, **NEEDS-HUMAN-REVIEW** (default retention). |
| T-11 | **Tier selection** is a pure function plus the module's **only** `#available`, written as a single-line `guard`. The Apple tier uses only the 26.0 API surface. | AAV §1.2 and §2. Compiles clean at both floors (TC-1). |
| T-12 | **Reachability and power** come from one `DeviceConditionsSource` (sync.md's types). Its live conformer keeps `NWPathMonitor` and the observer tokens in an actor, and both inputs are delivered on **one serial queue**, so each element is a consistent snapshot. | E-18. TC-1. CAP-1 (no diagnostic for capturing `NWPathMonitor`, but the design does not depend on that). |
| T-13 | **LoopbackHTTPServer:** an actor over `NWListener`. The "connection drops mid-body" scenario uses **FIN truncation**, never RST. A stall mode makes "mid-flight" deterministic. | E-16 (three runs of 100): FIN gave 100/100 `connectionLost(resumable: true)` every time, worst case 5–13 ms. RST gave 93–99/100; the rest timed out after the full request timeout. E-17. |

---

## 1. Scope, placement and what each target owns

| Target | Contents from this design | Coverage |
|---|---|---|
| `ZTronAssetModel` | `TransferID`, `StagingFileName`, `ETag`, `NetworkAccess`, `TransferRoute`, `TransferRequest`, `ManifestRequest`/`Result`/`Payload`, `StagedFile`, `TransferUpdate`, `TransferHandle`, `RemoteSource`, `RemoteSourceCapabilities`, `ReattachedTransfer`, `AdoptionReport`, `TransferError` and its sub-enums, `RetryAfter`, `StagingSink`, `ChunkSource`, `StagingError`, `TransferBackend`, `TransferJob`, `ResumeData`, `AppKey`, `DeviceConditions*` (sync.md's types) | normal (≥ 70 %) |
| `ZTronAssetTransport` | `HTTPRemoteSource`, `RequestFactory`, `TransportSecurityPolicy`, `RedirectPolicy`, `Origin`, `TransferTag`, `TransferClassifier`, `RetryAfterParser`, `SizeGuard`, `ProgressQuantizer`, `SessionDelegate`, `TaskMailbox`, `ForegroundTransferBackend`, `URLSessionTransferHandle`, `BackgroundTransferCoordinator`, `BackgroundSessionIdentifier`, `BackgroundEventsRelay`, `LiveDeviceConditionsSource`, `ConditionsMapping`; **`BackgroundSessionBackend.swift`** (thin, excluded) | ≥ 70 %; every line except the excluded file is reachable from macOS (§16.9) |
| `ZTronAssetAppleHosted` | `PackID`, `PackLocation`, `PackProgress`, `PackError`, `PackUpdateCheck`, `PackFileReader`, `PackBackend`, `AppleTierConfiguration`, `PackRetention`, `AppleHostedRemoteSource`, `CatalogReader`, `PackAvailabilityCoordinator`, `PackReleasePlanner`, `PackErrorMapping`, `TierSelection`; **`LiveAssetPackBackend.swift`** (thin, excluded) | ≥ 70 % |
| `ZTronAssetSync` | `TransferReconciler` (the pure launch-reconciliation function of §10.5, specified here and owned by WP-F) | ≥ 90 % |
| `ZTronAssetTestSupport` | `LoopbackHTTPServer`, `LoopbackRequest`/`Response`/`Ending`/`Encoding`, `LoopbackDelay` (`NoLoopbackDelay`, `LiveLoopbackDelay`), `Gzip`, `FakeTransferBackend`, `FakeRemoteSource` (the sync design's), `FakeDeviceConditionsSource` (the sync design's) | excluded; unsafe and docs gates still apply |
| `Tests/ZTronAssetTransportTests` | `FakeBackgroundSessionDriver` (the protocol lives in Transport, and TestSupport cannot see Transport) | — |
| `Tests/ZTronAssetAppleHostedTests` | `FakePackBackend` (same reason) | — |

---

## 2. SDK facts this design rests on (installed SDK, read verbatim)

| # | Fact | Source |
|---|---|---|
| S-1 | `NSURLSession`, `NSURLSessionTask`, `NSURLSessionDownloadTask` and `NSURLSessionDelegate` are `NS_SWIFT_SENDABLE`, so every delegate conformer must be `Sendable`. | `NSURLSession.h:201, 686, 928, 1642` (iPhoneOS27.0 SDK) |
| S-2 | Task delegate: *"Methods not implemented on this delegate will still be forwarded to the session delegate. Cannot be modified after task resumes. Not supported on background session. Delegate is strongly referenced until the task completes, after which it is reset to `nil`."* `API_AVAILABLE(macos(12.0), ios(15.0))`. | `NSURLSession.h:717-726` |
| S-3 | *"For tasks in background sessions, redirections will always be followed and this method will not be called."* | `NSURLSession.h:1732-1733` |
| S-4 | *"The delegate should copy or move the file at the given location to a new location as it will be removed when the delegate message returns."* | `NSURLSession.h` download delegate |
| S-5 | Resume needs GET, a server that supports `Range`, and an `ETag` or `Last-Modified`. Resume data arrives under `NSURLSessionDownloadTaskResumeData` in the error's `userInfo`. | `NSURLSession.h:637-645, 1873, 1942` |
| S-6 | `HTTPMaximumConnectionsPerHost`: *"This limit is per session … The default value is 6."* | `NSURLSession.h:1472-1476` |
| S-7 | `waitsForConnectivity` and `taskIsWaitingForConnectivity` are ignored for background sessions. `earliestBeginDate` has no effect for foreground sessions. | `NSURLSession.h:740, 1714-1720` |
| S-8 | `NSURLErrorNetworkUnavailableReason` is **unavailable in Swift**; use `URLError.NetworkUnavailableReason` (`cellular = 0`, `expensive = 1`, `constrained = 2`). Background cancel reasons are 0 (force quit), 1 (background updates disabled) and 2 (insufficient system resources). | compiler error in the first build (§17); `NSURLError.h:47-78` |
| S-9 | UIKit's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` passes a plain `void (^)(void)` (not `NS_SWIFT_SENDABLE`), on the main actor. | `UIApplication.h:460` |
| S-10 | Completion-handler APIs called from an `async` context raise *"consider using asynchronous alternative function"*, which is fatal under `-warnings-as-errors`. Use `await task.cancelByProducingResumeData()` in async code. The completion form is fine inside synchronous `onCancel` closures. | first build (§17) |
| S-11 | The BackgroundAssets facts: `.downloading(AssetPack, Foundation.Progress)`; no stable pack-file URL; whole-pack `remove`; `checkForUpdates()` best effort; essential vs on-demand is build-time data; every switch needs `@unknown default`; the gate must be `@available(iOS 26.0, macOS 26.0, *)`. | AAV §0, §1.2–1.8 |

---

## 3. Contracts (exact Swift signatures, for Phase C)

The names follow sync.md where it already defines a type (`AssetPriority`, `DeviceConditions`, `TransferUpdate`, `ReattachedTransfer`, `originID`). Where this design deviates, §15 says why. **What the prototype compiles** (`.build-probe-transport/pkg/Sources/`): the identity and error types, `TransferUpdate`/`TransferHandle`, the tag, classifier, parser, guard and quantiser, the security policy and redirect decision, the delegate, mailbox, foreground backend and handle, the conditions source, the background split (driver protocol, live driver, reconciler, relay), and the Apple seam with its live backend and tier selection. **Specified here but not prototyped:** `RemoteSource`, `HTTPRemoteSource`, `AppleHostedRemoteSource`, `BackgroundTransferCoordinator`, `ChunkSource` and the extended `StagingSink`. The prototype's `TransferBackend` still exposes an awaiting `run(…)` plus `reprioritise`; the handle-based shape below is the proposal, and the handle mechanics are what E-17 proves. The final shape in Phase C adds `///` to every public declaration (the docs gate).

### 3.1 Identity, names, validated values (`ZTronAssetModel`)

```swift
/// Deterministic identity of one transfer and the stem of its staging files.
/// Alphabet [0-9a-z-], 1…96 bytes: it can never contain a path separator (R-SEC-2).
public struct TransferID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String)
    /// "c-<64 lowercase hex>": the content key for an entry with a checksum.
    public static func content(sha256Hex: String) -> TransferID?
    /// "l-<64 hex>" = SHA-256(identifier ‖ 0x00 ‖ remotePath) for legacy checksum-less entries (R-MAN-5).
    public static func legacy(digestHex: String) -> TransferID?
    /// The single manifest transfer (the engine single-flights manifest fetches).
    public static let manifest: TransferID            // "m-manifest"
}

public enum StagingFileKind: Sendable, Hashable { case download, resumeData }

/// The only names the transport ever writes under staging/.
public struct StagingFileName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public static func download(_ id: TransferID) -> StagingFileName     // "<id>.part"
    public static func resumeData(_ id: TransferID) -> StagingFileName   // "<id>.resume"
    /// Inverse, used by launch reconciliation and staging GC; nil for foreign names.
    public init?(parsing fileName: String)
    public var transferID: TransferID { get }
    public var kind: StagingFileKind { get }
}

/// Opaque entity tag stored verbatim (weak tags included). Untrusted: 1…256 printable ASCII bytes, else nil.
public struct ETag: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String)
}

/// Per-request OS-enforced permissions derived from NetworkPolicy (R-SYN-7, sync.md §11.2).
public struct NetworkAccess: Sendable, Hashable {
    public var allowsCellular: Bool = true
    public var allowsExpensive: Bool = true
    public var allowsConstrained: Bool = true
}

public enum TransferRoute: Sendable, Hashable {
    case foreground
    /// May use the background session if it is enabled and safe for this request (§10.7); else foreground.
    case backgroundEligible
}

public enum ResumePolicy: Sendable, Hashable { case ifAvailable, discardExisting }
```

### 3.2 The engine-facing source (`RemoteSource`) and its handle

```swift
public struct TransferRequest: Sendable, Hashable {
    public var id: TransferID
    public var attempt: UInt32                 // engine-assigned, monotone per id; tags events (§10.8)
    public var remotePath: String              // already validated by R-MAN-2 (relative, no "..", no scheme)
    public var expectedBytes: Int64?           // manifest byteSize
    public var maxBytes: Int64                 // StoragePolicy.maxAssetBytes
    public var priority: AssetPriority
    public var access: NetworkAccess
    public var route: TransferRoute
    public var resume: ResumePolicy
}

public enum TransferUpdate: Sendable, Hashable {
    case progress(received: Int64, expected: Int64?)
    case staged(StagedFile)                    // terminal
    case paused(resumable: Bool)               // terminal, after pause()
    case failed(TransferError)                 // terminal
}

/// A running transfer. All methods are synchronous and nonisolated, so the engine can promote, pause or
/// cancel from actor-isolated synchronous code (sync.md §3.3 "promotion inside join cannot await").
public protocol TransferHandle: Sendable {
    var id: TransferID { get }
    /// Single consumer. `.bufferingNewest(4)`: progress may coalesce; the terminal element is never dropped
    /// because nothing is yielded after it. If the consuming task is cancelled, the stream terminates and the
    /// transfer is cancelled (onTermination).
    var updates: AsyncStream<TransferUpdate> { get }
    func setPriority(_ priority: AssetPriority)      // R-NET-10; takes effect immediately
    func pause()                                     // cancel producing resume data → .paused(resumable:)
    func cancel()                                    // cancel discarding partial bytes → .failed(.cancelled(.byClient))
}

/// A complete download sitting in staging/<id>.part, size-checked against byteSize, NOT hash-verified.
public struct StagedFile: Sendable, Hashable {
    public var id: TransferID
    public var name: StagingFileName
    public var byteCount: Int64                // on-disk (decoded) bytes
    public var resumed: Bool                   // some bytes came from an earlier attempt (R-NET-8)
    public var httpStatus: Int?                // nil on the Apple tier
    public var etag: ETag?
}

public struct ManifestRequest: Sendable, Hashable {
    public var ifNoneMatch: ETag?
    public var maxBytes: Int64                 // 32 MiB (R-MAN-2)
    public var access: NetworkAccess
    public var allowsUpdateCheck: Bool         // Apple tier: best-effort checkForUpdates() first (R-APL-4)
}
public enum ManifestOrigin: Sendable, Hashable { case network, installedPack(updateChecked: Bool) }
public struct ManifestPayload: Sendable, Hashable {
    public var bytes: Data                     // ≤ maxBytes, undecoded (decoding is the Model's, R-MAN-2/3)
    public var etag: ETag?                     // HTTP ETag, or "sha256:<hex>" of the catalog on the Apple tier
    public var origin: ManifestOrigin
    public var removedSources: Set<String>     // Apple tier: pack ids removed by the update check
}
public enum ManifestFetchResult: Sendable, Hashable {
    case notModified
    case fetched(ManifestPayload)
}

public enum AssetTier: Sendable, Hashable { case aws, appleHosted }
public struct RemoteSourceCapabilities: Sendable, Hashable {
    public var tier: AssetTier
    public var supportsPriority: Bool          // AWS: true; Apple: false (the OS schedules packs)
    public var supportsResume: Bool            // AWS: true; Apple: false
    public var supportsBackground: Bool        // true only if the background session is enabled AND usable
    public var keepsSourceCopies: Bool         // Apple: true (R-CLN-10 applies)
}

public struct ReattachedTransfer: Sendable, Hashable {
    public var id: TransferID
    public var attempt: UInt32
    public var isRunning: Bool
    public var bytesReceived: Int64
}

public struct AdoptionReport: Sendable, Hashable {
    public var manifestRemotePaths: [String]   // every entry of the applied manifest
    public var adoptedRemotePaths: Set<String> // entries present, verified, in blobs/
}
public struct ReclaimReport: Sendable, Hashable {
    public var released: [String]              // source copies (packs) released
    public var failed: [String: TransferError]
}

public protocol RemoteSource: Sendable {
    /// Circuit-breaker and throttle key (sync.md §8.3): scheme://host for HTTP, "apple-hosted" for packs.
    var originID: String { get }
    var capabilities: RemoteSourceCapabilities { get }
    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult
    /// Starts, or re-attaches to, transfer `request.id`. Never creates a second OS task for an id that is
    /// already live (H-6). `async` only because resume data may be read from staging first.
    func transfer(_ request: TransferRequest) async -> any TransferHandle
    /// H-6: live transfers left by an earlier process. Consumed once by start(), BEFORE staging GC.
    func reattachedTransfers() async -> [ReattachedTransfer]
    /// Cancels a re-attached transfer the engine no longer wants (there is no handle for it yet).
    func cancelTransfer(_ id: TransferID) async
    /// R-CLN-10: releases source-held duplicates of adopted content when policy allows. No-op for HTTP.
    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport
}
```

**Typed throws.** `throws(TransferError)` on a protocol requirement used through `any RemoteSource` is accepted at both floors (AAV §3 #3, and TC-1 compiles `throws(StagingError)` and `throws(PackError)` requirements). No typed-throws closure is stored anywhere (AAV §3 #4).

### 3.3 The transport-facing backend (`TransferBackend`), staging and resume data

```swift
/// One job for a TransferBackend. It carries NO secret: the backend attaches the key (§5).
public struct TransferJob: Sendable, Hashable {
    public var id: TransferID
    public var attempt: UInt32
    public var url: URL
    public var purpose: TransferPurpose        // .asset | .manifest
    public var ifNoneMatch: ETag?
    public var expectedBytes: Int64?
    public var maxBytes: Int64
    public var priority: AssetPriority
    public var access: NetworkAccess
}
public enum TransferPurpose: String, Sendable, Hashable { case asset, manifest }
public enum TransferBackendKind: String, Sendable, Hashable { case foreground, background }

/// Opaque URLSession resume data. It embeds the archived request INCLUDING ITS HEADERS (E-5:
/// resumeDataContainsAppKey = true), so it redacts itself and never leaves transport + staging.
public struct ResumeData: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let bytes: Data
    package init(bytes: Data)
    public var description: String { get }          // "ResumeData(<n> bytes, redacted)"
    public var debugDescription: String { get }
    public var customMirror: Mirror { get }         // no children
}

public struct LiveTransfer: Sendable, Hashable {
    public var id: TransferID
    public var attempt: UInt32
    public var backend: TransferBackendKind
    public var isRunning: Bool
    public var bytesReceived: Int64
    public var priority: Float                      // observable for R-NET-10 tests
}

public protocol TransferBackend: Sendable {
    var kind: TransferBackendKind { get }
    /// Foreground: creates, tags and resumes a download task. Background: attach-or-create by id.
    func start(_ job: TransferJob, resumeData: ResumeData?) async -> any TransferHandle
    func liveTransfers() async -> [LiveTransfer]
    func cancel(_ id: TransferID, keepingResumeData: Bool) async
    /// Shutdown (R-SYN-15): invalidateAndCancel(); the session releases its delegate.
    func invalidate() async
}

public enum StagingError: Error, Sendable, Hashable {
    case insufficientSpace
    case io(posixCode: Int32)
    case tooLarge(limit: Int64)
    case source(SourceFailure)                 // a ChunkSource (pack reader) failed
}
public enum SourceFailure: Sendable, Hashable { case notFound, notInstalled, readFailed, system(domain: String, code: Int) }

/// Blocking pull of ≤ maxBytes. Called only on Storage's bulk executor (ADR-003); nil at EOF.
public protocol ChunkSource: Sendable {
    func nextChunk(maxBytes: Int) throws(StagingError) -> Data?
}

/// Implemented by ZTronAssetStorage over its FileSystem seam (R-STO-6); the transport never touches FileManager.
public protocol StagingSink: Sendable {
    /// SYNCHRONOUS. Runs on URLSession's serial delegate queue (not main, not the cooperative pool, C2) before
    /// the OS deletes `location` (S-4). Same-volume rename (EXDEV → bounded copy). Returns the on-disk size.
    func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64
    /// SYNCHRONOUS, best effort, ≤ 256 KiB (larger is dropped). Atomic write of staging/<id>.resume.
    func storeResumeData(_ data: ResumeData, for id: TransferID)
    func loadResumeData(for id: TransferID) async -> ResumeData?
    func discardResumeData(for id: TransferID) async
    /// Manifest path: reads staging/<name> (≤ maxBytes) off the pool, then the caller discards it.
    func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data
    func discardStaged(_ name: StagingFileName) async
    /// Apple tier: pulls `source` in ≤ 1 MiB units on the bulk executor into staging/<name>. Returns the size.
    func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64
}
```

### 3.4 The closed error taxonomy (R-NET-6)

```swift
public enum TransferError: Error, Sendable, Hashable {
    case offline(OfflineReason)
    case transient(TransientCause, retryAfter: RetryAfter?)
    case permanentMissing(httpStatus: Int)                     // 404, 410 (and Apple fileNotFound/assetPackNotFound)
    case authentication(AuthenticationFailure)                 // 401; 403 → forbiddenAmbiguous
    case integrity(IntegrityFailure)
    case insufficientSpace(requiredBytes: Int64?)
    case rejected(PolicyViolation)                             // our own policy refused it; not retried within a run
    case cancelled(CancellationCause)
}
public enum OfflineReason: Sendable, Hashable {
    case noConnection, cellularDenied, expensiveDenied, constrainedDenied, roamingDisabled, callActive
}
public enum TransientCause: Sendable, Hashable {
    case timedOut, connectionLost(resumable: Bool), cannotConnect, dnsFailure
    case secureConnectionFailed(urlErrorCode: Int), badServerResponse
    case serverError(httpStatus: Int)                          // 5xx (+ Retry-After when sent)
    case throttled                                             // 429 (+ Retry-After)
    case resumeRejected                                        // 416, or resume data unusable
    case backgroundSessionUnavailable(urlErrorCode: Int)       // -995/-996/-997
    case localIO(posixCode: Int32)
    case incompleteCallbackSequence                            // defensive: the stream ended without a terminal
    case unknown(urlErrorCode: Int)
}
/// As received (RFC 9110 §10.2.3). The ENGINE turns it into a deadline with its TimeSource and clamps it
/// (sync.md §8.2 maxRetryAfter); the transport never reads a clock.
public enum RetryAfter: Sendable, Hashable { case seconds(UInt32), date(Date) }

public enum AuthenticationFailure: Sendable, Hashable {
    case unauthorized(httpStatus: Int)                         // 401, or URLSession auth failures (status 0)
    /// SPEC §2.3: a 403 means EITHER "the CloudFront Function rejected the key" OR "the object is missing behind
    /// OAC". Reported as both possibilities, with evidence. The engine decides (breaker, sync.md §8.3).
    case forbiddenAmbiguous(ForbiddenEvidence)
}
public struct ForbiddenEvidence: Sendable, Hashable {
    public var purpose: TransferPurpose
    public var bodyBytes: Int64                                // the CloudFront Function's 403 has an empty body
    public var contentTypeIsXML: Bool                          // S3's AccessDenied is application/xml
    public var hint: ForbiddenHint { get }                     // .keyRejectedLikely | .objectMissingLikely | .undetermined
}
public enum ForbiddenHint: Sendable, Hashable { case keyRejectedLikely, objectMissingLikely, undetermined }

public enum IntegrityFailure: Sendable, Hashable {
    case sizeMismatch(expected: Int64, actual: Int64)          // staged > byteSize
    case truncated(expected: Int64?, received: Int64)          // staged < byteSize, or a zero-byte resource
    case oversize(announced: Int64?, limit: Int64)             // the cap (R-NET-7 / R-MAN-2 32 MiB)
    case undecodableContent(urlErrorCode: Int)                 // a corrupt gzip stream
}
public enum PolicyViolation: Sendable, Hashable {
    case insecureScheme, hostNotAllowed, redirectRefused(RedirectRefusal)
    case unexpectedStatus(Int), unexpectedNotModified, invalidURL
}
public enum RedirectRefusal: Sendable, Hashable {
    case insecureScheme, hostNotAllowed, tooManyRedirects, invalidLocation
    case unenforceableInBackground                             // §10.7: detected after the fact; the bytes are discarded
}
public enum CancellationCause: Sendable, Hashable { case byClient, bySystem(SystemCancellationReason) }
public enum SystemCancellationReason: Sendable, Hashable {
    case userForceQuitApplication, backgroundUpdatesDisabled, insufficientSystemResources, unknown(Int)
}
```

The hint rule (pure, tested): a manifest 403, or an empty body → `.keyRejectedLikely`; an XML body → `.objectMissingLikely`; anything else → `.undetermined`. E-8 shows both real shapes coming through the delegate: `403-empty` gives `bodyBytes: 0`, and `403-xml` gives `bodyBytes: 40, contentTypeIsXML: true`.

#### 3.4.1 Mapping table: HTTP status → `TransferError` (pure `TransferClassifier`)

| Final status | Result | Notes |
|---|---|---|
| 200, 206 | staged, then the size checks of §7 | 206 only on a resumed request |
| 304 | `notModified` if `If-None-Match` was sent, else `rejected(.unexpectedNotModified)` | E-7 |
| 3xx (refused redirect delivered as final) | `rejected(.redirectRefused(reason))` | the reason is recomputed purely from `Location` (§5.2) |
| 401 | `authentication(.unauthorized(401))` | |
| 403 | `authentication(.forbiddenAmbiguous(evidence))` | E-8 |
| 404, 410 | `permanentMissing(status)` | |
| 408 | `transient(.timedOut, retryAfter)` | |
| 416 | `transient(.resumeRejected, nil)` + discard resume data | |
| 429 | `transient(.throttled, retryAfter)` | E-8: `Retry-After: 7` → `.seconds(7)` |
| 500…599 | `transient(.serverError(status), retryAfter)` | E-8: 503 with an HTTP-date → `.date(2026-10-21 07:28:00 UTC)` |
| any other | `rejected(.unexpectedStatus(status))` | E-8: 400 |

#### 3.4.2 Mapping table: `URLError` code → `TransferError` (pure `TransferClassifier`)

| Code(s) | Result |
|---|---|
| −999 `cancelled` | `integrity(.oversize)` if the cap was exceeded (re-derived from the task's byte counts, since the delegate keeps no memory). `.paused` if the tag carries the pause intent (§4.5). `cancelled(.bySystem(reason))` when `NSURLErrorBackgroundTaskCancelledReasonKey` is present. Otherwise `cancelled(.byClient)`. |
| −1001 `timedOut` | `transient(.timedOut)` |
| −1005 `networkConnectionLost` | `transient(.connectionLost(resumable: resume data present))` |
| −1004 `cannotConnectToHost` | `transient(.cannotConnect)` |
| −1003 `cannotFindHost`, −1006 `dnsLookupFailed` | `transient(.dnsFailure)` |
| −1009 `notConnectedToInternet` | `offline(...)` by `URLError.NetworkUnavailableReason`: cellular → `.cellularDenied`, expensive → `.expensiveDenied`, constrained → `.constrainedDenied`, none → `.noConnection` |
| −1018 `internationalRoamingOff` / −1019 `callIsActive` / −1020 `dataNotAllowed` | `offline(.roamingDisabled)` / `offline(.callActive)` / `offline(.cellularDenied)` |
| −1007 `httpTooManyRedirects` | `rejected(.redirectRefused(.tooManyRedirects))` |
| −1010 `redirectToNonExistentLocation` | `rejected(.redirectRefused(.invalidLocation))` |
| −1022 `appTransportSecurityRequiresSecureConnection` | `rejected(.insecureScheme)` |
| −1000 `badURL`, −1002 `unsupportedURL` | `rejected(.invalidURL)` |
| −1012 / −1013 user authentication | `authentication(.unauthorized(0))` |
| −1011 `badServerResponse`, −1017 `cannotParseResponse` | `transient(.badServerResponse)` |
| −1014 `zeroByteResource` | `integrity(.truncated(expected, 0))` |
| −1015, −1016, −3006, −3007 (decoding) | `integrity(.undecodableContent(code))` |
| −1200…−1206 (TLS) | `transient(.secureConnectionFailed(code))` (a captive portal heals on a path change) |
| −3000…−3005 (file) | `insufficientSpace` if the underlying POSIX error is `ENOSPC`, else `transient(.localIO(errno))` |
| −995 / −996 / −997 (background session) | `transient(.backgroundSessionUnavailable(code))`; the background backend then falls back to foreground |
| −1, and anything else | `transient(.unknown(code))` |

`Retry-After` (`RetryAfterParser`, pure) accepts delta-seconds (≤ 10 digits) and **all three HTTP-date formats**: RFC 9110 §5.6.7 says *"a recipient that parses a timestamp value … MUST accept all three"*. The parser is hand-written (no `DateFormatter`, no locale, no `Regex` at the floor). E-15 gives `784111777` for the RFC example in each of the three forms, matching Python's `email.utils`. Garbage, negative values and 11-digit values give `nil` (absent), so the engine's own backoff applies. **The prototype's first version had an off-by-one month** (October parsed as September, first E-8 run), which is why the test plan has a vector test.

#### 3.4.3 Engine action and facade error (proposal; owned by sync.md §8.1)

| `TransferError` | sync.md row | Proposed `AssetError` (R-CAR-7) |
|---|---|---|
| `offline` | offline → `failed(.whenOnline)` | `.offline` |
| `transient(.serverError, nil)` | server(5xx) → backoff + 5xx breaker window | `.serverUnavailable(retryAfter: nil)` |
| `transient(_, retryAfter: x?)` (429, 503) | throttled → origin throttle | `.serverUnavailable(retryAfter: x)` |
| other `transient` | transient → backoff, early re-queue on a path edge | `.serverUnavailable(retryAfter: nil)` |
| `permanentMissing` | notFound → `failed(.untilEntryChanges)` | `.notFound` |
| `authentication(.unauthorized)` | authRejected → breaker opens | `.authRejected(.confirmed)` |
| `authentication(.forbiddenAmbiguous(e))` | object 403 → auth-suspect counter. **When `e.purpose == .manifest`, sync.md's row opens the breaker at once.** That is an engine inference, not a transport verdict: a deleted `manifest.json` also yields 403 behind OAC. | `.authRejected(.ambiguous)` |
| `integrity` | tooLarge/sizeMismatch → R-INT-3 backoff | `.integrityFailure` |
| `insufficientSpace` | blocked(.insufficientSpace) | `.insufficientSpace(...)` |
| `rejected` | **missing from sync.md §8.1**. Proposal: `failed(.nextRun)`, no retry within the run, counted in metrics by violation. | `.serverUnavailable(retryAfter: nil)` (no closer R-CAR-7 case) |
| `cancelled(.byClient)` | not a failure | `.cancelled` |
| `cancelled(.bySystem)` | re-queue at the next run | — |

### 3.5 Device conditions (R-NET-9 plus the power half of R-SYN-7)

The types are sync.md §3.1's (`NetworkConditions`, `PowerConditions`, `ThermalLevel`, `DeviceConditions`, `DeviceConditionsSource`). This design supplies the live conformer:

```swift
public final class LiveDeviceConditionsSource: DeviceConditionsSource {
    public init(center: NotificationCenter = .default)
    public func conditions() async -> AsyncStream<DeviceConditions>   // .bufferingNewest(1); full snapshots
}
public enum ConditionsMapping {                                       // pure, tested exhaustively
    public static func network(satisfied: Bool, expensive: Bool, constrained: Bool) -> NetworkConditions
    public static func thermal(_ state: ProcessInfo.ThermalState) -> ThermalLevel   // @unknown → .critical
}
```

### 3.6 Configuration and construction (public surface reached through `AssetClientConfiguration.remote`)

```swift
public struct HTTPSourceConfiguration: Sendable, Hashable {
    public var baseURL: URL                               // https://<distribution>/ ; its host is allow-listed implicitly
    public var manifestPath: String = "manifest.json"
    public var appKey: AppKey?                            // sent only to allow-listed HTTPS origins (§5)
    public var additionalAllowedHosts: Set<String> = []
    public var maxConnectionsPerHost: Int = 6             // clamped 1…8 (§8)
    public var requestTimeout: TimeInterval = 30          // applied to the session AND to every URLRequest (§4.1)
    public var maxResumeDataBytes: Int = 256 * 1024
    public var background: BackgroundTransferPolicy = .disabled
}
public enum BackgroundTransferPolicy: Sendable, Hashable {
    case disabled                                         // default: every transfer is foreground
    /// The app attests that it forwards application(_:handleEventsForBackgroundURLSession:completionHandler:) (§10.6).
    case enabled(BackgroundTransferOptions)
}
public struct BackgroundTransferOptions: Sendable, Hashable {
    public var namespace: String = "default"              // → com.ztron.assetkit.bg.<namespace>.v1 (§10.3)
    public var discretionary: Bool = true
    public var maxTasks: Int = 32                         // tasks handed to the OS at once; bounds the event buffer (§4.4)
    public var keyRedirectExposure: KeyRedirectExposure = .refuse
}
public enum KeyRedirectExposure: Sendable, Hashable {
    case refuse            // default: a request carrying the app key never uses the background session (R-NET-4 holds)
    case acceptedByOwner   // the owner accepts that the OS follows redirects WITH the key in background (S-3, E-13); ADR-T1
}

public final class HTTPRemoteSource: RemoteSource {
    /// Production: HTTPS-only policy; the live foreground backend (one URLSession, < 0.05 ms, E-12) is created here,
    /// so the facade constructs this source in AssetClient.start(), never in init (P-12). No lazy mutable state.
    public init(configuration: HTTPSourceConfiguration, staging: any StagingSink)
    /// Tests and benchmarks (same package): loopback policy and injected backends (FakeTransferBackend or a real
    /// ForegroundTransferBackend against LoopbackHTTPServer).
    package init(configuration: HTTPSourceConfiguration, staging: any StagingSink, policy: TransportSecurityPolicy,
                 foreground: any TransferBackend, background: (any TransferBackend)?)
}
```

---

## 4. The foreground `URLSession` (R-NET-2)

### 4.1 Configuration (`ForegroundSessionSettings.makeConfiguration()`)

| Property | Value | Why |
|---|---|---|
| base | `.ephemeral` | Nothing is written outside the store root (R-STO-1); no disk cache, cookies or credentials. |
| `urlCache` | `nil` | R-NET-5: no cache can answer, or rewrite, a conditional request (E-7). |
| `requestCachePolicy` | `.reloadIgnoringLocalCacheData` | Belt and braces; also set per request. |
| `httpCookieStorage` / `httpShouldSetCookies` / `urlCredentialStorage` | `nil` / `false` / `nil` | No state. |
| `httpMaximumConnectionsPerHost` | `6` by default, clamped to `1…8` | P-10 (≤ 8, E-1/E-1b) and P-11 (concurrency 5 needs ≥ 5 HTTP/1.1 connections, E-2). Engine rule: §8. |
| `httpShouldUsePipelining` | `false` | Default; pipelining is head-of-line fragile. |
| `waitsForConnectivity` | `false` | Fail fast with `.offline`; the engine waits on `DeviceConditions` (R-SYN-13), so no slot is held by a waiting task. |
| `timeoutIntervalForRequest` | 30 s (configurable) | **Also set on every `URLRequest`**: the request's own `timeoutInterval` overrides the session's. E-16 measured 30 s despite a 5 s session value until the factory used the setting. |
| `tlsMinimumSupportedProtocolVersion` | `.TLSv12` | CloudFront supports 1.2/1.3. |
| `httpAdditionalHeaders` | `[:]` | **Never the app key** (E-6c, §5.3). |
| delegate queue | `nil` → URLSession's own serial `OperationQueue` | Per-task callbacks are ordered. The synchronous staging move runs off the main thread and off the cooperative pool (C2). |

**One session per `HTTPRemoteSource`, for the life of the client.** It is created in `AssetClient.start()`, not `init` (P-12). Creating it costs < 0.05 ms (E-12), but `start()` is where sync.md defers everything else (§13.2). `shutdown()` calls `invalidateAndCancel()`, which releases the delegate: URLSession retains its delegate until invalidation, so without this step it leaks.

### 4.2 The delegate is `Sendable` without `@unchecked`: the proof

```swift
public final class SessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let mode: SessionMode                                    // .foreground | .background
    let staging: any StagingSink                             // Sendable protocol
    let policy: TransportSecurityPolicy                      // value
    let events: AsyncStream<SessionEvent>.Continuation       // Sendable
    let progress: AsyncStream<TransferProgress>.Continuation?// background progress only
}
/// Per-task mailbox: deliberately implements no delegate method, so every callback reaches SessionDelegate (S-2).
public final class TaskMailbox: NSObject, URLSessionTaskDelegate, Sendable {
    let continuation: AsyncStream<TransferUpdate>.Continuation
}
```

| Probe | iOS 15 | macOS 12 | Output |
|---|---|---|---|
| **TC-1** the whole prototype (`SessionDelegate`, `TaskMailbox`, the backend, the handle, the classifier, security, conditions, the background split, the Apple tier and the loopback server), `-swift-version 6 -warnings-as-errors -enable-experimental-feature StrictConcurrency=complete` | exit 0, 0 errors, 0 warnings | exit 0, 0 errors, 0 warnings | `out/typecheck.ios15.txt`, `out/typecheck.macos12.txt` |
| **NEG-1** the same mailbox with one `var delivered = 0` | **error**: `stored property 'delivered' of 'Sendable'-conforming class 'TaskMailbox' is mutable` | same | `out/mutable_mailbox.*.txt` |
| **NEG-2** a delegate with no explicit `Sendable` and a `var tasks` table | **warning** (fatal under `-warnings-as-errors`): `stored property 'tasks' of 'Sendable'-conforming class 'SessionDelegate' is mutable` | same | `out/nonsendable_delegate.*.txt`; S-1 makes every conformer implicitly `Sendable` |

So the prior art's per-download `@unchecked Sendable` delegate with a lock (D-1, D-5) has two compile-checked replacements: the immutable session delegate and the immutable mailbox. **The transport spends 0 of the 3 audited escapes.** The runtime side was checked too. **E-20** ran the prototype under Thread Sanitizer (`swift test --sanitize=thread`) with:

- 200 downloads at concurrency 16;
- every 7th consumer cancelled mid-flight;
- a stalled transfer promoted and paused from a detached task.

It passed with **no TSan report**.

### 4.3 Callback flow, and the synchronous move into staging (C4, S-4)

```
start(job):  task = session.downloadTask(with: requestFactory.makeRequest(job))   // or withResumeData:
             task.taskDescription = TransferTag(job).encoded    // "ztak1 <id> <attempt> <expected|-> <limit> <purpose>[ pause]"
             task.priority = job.priority.urlSessionTaskPriority
             task.countOfBytesClientExpectsToReceive = job.expectedBytes ?? unknown
             task.delegate = TaskMailbox(continuation)          // before resume (S-2)
             continuation.onTermination = { if .cancelled → task.cancel() }
             task.resume(); return URLSessionTransferHandle(task, tag, updates)

didWriteData            tag ← taskDescription; if SizeGuard.mustAbort(written, announced, limit) → task.cancel(); return
                        if ProgressQuantizer.crossesBoundary → route(.progress)                (stateless rate limit)
didFinishDownloadingTo  tag ← taskDescription; facts ← HTTPURLResponse
                        background mode ∧ origin(currentRequest) ≠ origin(originalRequest) → route(.failed(.rejected(.unenforceableInBackground)))
                        status ∈ {200, 206} → size = try staging.adoptDownload(location, as: .download(tag.id))  ← SYNCHRONOUS
                        route(TransferClassifier.classifyFinished(tag, facts, bodyBytes, staged, sentConditional, redirectRefusal))
didCompleteWithError    error == nil → mailbox.finish() (the terminal was already sent at didFinish)
                        resume data in userInfo → staging.storeResumeData(...)                ← SYNCHRONOUS
                        tag.pauseRequested ∧ −999 → route(.paused(resumable: data != nil)); else route(.failed(classify(error)))
                        mailbox.finish()
willPerformHTTPRedirection  completionHandler(RedirectPolicy.apply(RedirectPolicy.decide(...)))   (§5.2)
route(task, update)     task.delegate as? TaskMailbox → mailbox.yield(update)   else → events/progress (background)
```

- **Why `taskDescription` carries the tag.** It is the only per-task slot that (a) the stateless delegate can read synchronously, (b) the OS persists for background tasks across relaunch (H-6), and (c) is a thread-safe property of a `Sendable` class, so a pause intent can be written onto the live task (§4.5). It carries no secret. Parsing is strict (6 or 7 fields, ≤ 256 bytes, a validated `TransferID`). An undecodable tag cancels the task. Fuzzed in §16.
- **Deterministic name.** The destination is `staging/<TransferID>.part`, a pure function of the tag. No reservation round-trip is needed before a transfer starts, so the engine's synchronous `pump()` can start one, and nothing random is involved (C4). The engine single-flights per content (sync.md §6), so two live transfers never share an id. A stale `.part` from an earlier attempt is replaced by the rename. This is safe because the bytes are content-addressed and hash-checked at publish.
- **The mailbox is visible in every callback.** No hang and no `incompleteCallbackSequence` occurred in any run, including failures delivered at `didCompleteWithError` (E-4a, E-5, E-14, E-16). E-10 counted 0 messages routed to the session stream for a mailbox task. S-2's "reset to nil after the task completes" happens after the session delegate's `didCompleteWithError`.

### 4.4 Backpressure (H-9)

- **Progress** is rate-limited **statelessly**. A chunk is reported only when it crosses a quantum boundary (`max(256 KiB, expected/64)`), plus once for the first chunk, so a transfer emits ≤ 65 + size/256 KiB events. E-17 shows `163219, 327111, 851398, 1048576` for a 3 MiB file stalled at 1 MiB. sync.md §10.5 then coalesces to ≤ 10 Hz.
- **Per-transfer stream** `.bufferingNewest(4)`: the terminal element is always the last one yielded, then `finish()`, so it can never be the one dropped.
- **Background lifecycle stream**: terminals only, `.bufferingOldest(4 × maxBackgroundTasks + 8)`. The engine caps the tasks handed to the background session (default 32), and each yields at most one terminal, so overflow is impossible while the cap holds. If it ever happened, the staged file plus `getAllTasks` reconciliation (§10.5) recovers it. Background progress goes to a separate `.bufferingNewest(64)` stream, so a progress flood can never evict a terminal event. **This was a defect in my first prototype**: both were in one stream.

### 4.5 Cancellation, pause and the handle

- **Consumer cancellation.** `for await` over an `AsyncStream` ends **as soon as the consuming task is cancelled, before URLSession reports anything**. My first prototype therefore returned `incompleteCallbackSequence` instead of `cancelled` (E-10, first run). Rule: the stream's `onTermination(.cancelled)` cancels the URLSession task, and an awaiting helper checks `Task.isCancelled` after the loop and reports `.cancelled(.byClient)` (E-10 final: `cancelled(byClient)`). A `.part` staged in the race window is collected by staging GC (I-4 holds; F-12).
- **`pause()`** (preemption, sync.md §7.3; promotion of a background transfer, §10.8) rewrites `taskDescription` with the `pause` field, then calls `cancel(byProducingResumeData:)`, whose callback stores the data. The stateless delegate sees the intent on the task and yields `.paused(resumable: data present)`. E-17: `paused(resumable: true)`, `resumeDataStored=true`, and the resumed attempt returned **206** with `Range: bytes=1048576-` and a matching hash.
- **`setPriority`** sets `task.priority` synchronously. E-17 read `0.75` back through `liveTransfers()` right after the call.
- **`cancel()`** gives `.failed(.cancelled(.byClient))` (E-17).
- **Why a handle and not sync.md's control stream:** see §15 X-T1.

### 4.6 Connection reuse and parallelism (P-10, P-11)

| Run | Result |
|---|---|
| **E-1** 500 × 1 KiB, one session, `maxConnectionsPerHost = 6`, concurrency 5 | 500 staged, **5 TCP connections**, 500 requests, 91–115 ms (four runs) |
| **E-1b** 500 × 1 KiB, a new session with max 8, concurrency 16 | **8** additional connections (13 cumulative). The cap binds even when the engine over-subscribes. |
| **E-1c** D-1 anti-pattern: one session per download, 50 downloads | **50** connections |
| **E-2** 200 × 2 KiB, 10 ms server latency, concurrency 1 vs 5 (best of two) | 3.32–3.71 s vs 0.59–0.72 s ⇒ **5.20–5.64×** in four full runs; two are retained in `out/` (P-11 needs ≥ 3×) |

The loopback is plain HTTP/1.1, so reuse is keep-alive (CloudFront in production uses HTTP/2, one connection). **Engine-side risk for P-11:** the transport speed-up leaves headroom only if the engine adds less than about 0.5 s of fixed tail per run. A commit pacer that waits a full window before the final flush (store P-5: ≤ 4 commits/s) would bring 5.6× down to under 3×: (3.6 + 1.0) / (0.7 + 1.0) ≈ 2.7. The final group commit of a run must flush as soon as the 4/s window allows (risk RK-4).

---

## 5. Redirects, the app key, and secrets (R-NET-4, R-SEC-1, R-SEC-3)

### 5.1 Policy

```swift
public enum PlaintextPermission: Sendable, Hashable { case never, loopbackOnly }
public struct TransportSecurityPolicy: Sendable, Hashable {
    public let allowedHosts: Set<String>        // lowercased, trailing dot stripped; default: [baseURL.host]
    public let plaintext: PlaintextPermission
    public let maxRedirects: Int                // clamped to 0…5
    public let keyHeaderName: String            // "x-zombietron-app-key" (§2.3)
    /// The only constructor an app can reach: HTTPS only.
    public static func production(allowedHosts: Set<String>) -> TransportSecurityPolicy
    /// Package-visible (tests and benchmarks are in the package; apps are not): http only for 127.0.0.1 / ::1 / localhost.
    package static func loopbackTesting(allowedHosts: Set<String>, maxRedirects: Int = 5) -> TransportSecurityPolicy
    public func check(_ origin: Origin?) -> PolicyViolation?   // nil = allowed
}
```

**R-SEC-3.** The package ships no `Info.plist` and no ATS key; production cannot express plain HTTP at all. The loopback benchmarks and tests run in the macOS test process, where plain HTTP to `127.0.0.1` works without any ATS exception. Every E-run above shows it in a command-line process, and **E-19** shows it inside the real `swift test` runner (Swift Testing): 50 sequential GETs, all 200, over **1** reused connection. Whether an iOS *app* would need `NSAllowsLocalNetworking` for the loopback case is irrelevant here (no loopback in production) and **not verified**.

### 5.2 The redirect decision (pure; `RedirectPolicy.decide`)

| Check, in order | Refusal | Evidence |
|---|---|---|
| hop = previous hop + 1 > `maxRedirects` (5) | `.tooManyRedirects` | E-6d: 7 same-origin redirects → refused; **6** requests at A (the original plus 5 hops) |
| proposed scheme is not `https` (unless `loopbackOnly` and the host is loopback) | `.insecureScheme` | pure test (no TLS on loopback) |
| proposed host ∉ `allowedHosts` | `.hostNotAllowed` | E-6e: refused; the foreign host received **0** requests |
| else **follow**. Keep the key ⇔ proposed origin == original origin **and** previous origin == original origin; otherwise strip it. | — | E-6a: cross-host → key at A, **absent** at B. E-6f: A → B → A → **absent** at the final A (monotone). E-6d: same-origin hops keep it on every hop. |

- **Hop counting without state.** Each followed request carries its hop number in a `URLProtocol` request property (`URLProtocol.setProperty(_:forKey:in:)`). This is in-process metadata and is never sent. The next redirect reads it from `task.currentRequest`. E-6d proves the count survives hops. URLSession's own limit (−1007) is higher, so ours binds.
- **Refusal** means calling the completion handler with `nil`, so the 3xx is delivered as the final response. `didFinishDownloadingTo` then recomputes the reason from `Location` (pure) and reports `rejected(.redirectRefused(reason))`.
- **Origin** means scheme + lowercased host without a trailing dot + effective port (443/80 by default). A port change counts as cross-origin.

### 5.3 Why stripping must happen in the delegate, and only there

| Run | Key at the redirect target |
|---|---|
| **E-6b** default `URLSession`, no delegate, key as a request header | **present** (`CANARY-…`): custom headers survive redirects, confirming the SPEC hint |
| **E-6c** key in `httpAdditionalHeaders`, our stripping delegate active | **present**: session-level headers are re-applied on every hop, so stripping the request cannot remove them |
| **E-6a** key as a request header, our delegate | **absent** |

Rules: (1) the key is added **only** by `RequestFactory.makeRequest(for:)`, and only when the request's origin passes `check` (allow-listed and HTTPS); (2) `httpAdditionalHeaders` is always empty (tested); (3) resumed requests re-send the archived headers (E-5: `keyOnResumedRequest=true`), so a resumed task whose `originalRequest` fails `check` is cancelled before `resume()`.

### 5.4 The key type and redaction (R-SEC-1)

```swift
public struct AppKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let secret: String                  // readable inside the package only (SE-0386); apps can create, never read
    public init(_ secret: String)
    public var description: String { "AppKey(<redacted>)" }
    public var debugDescription: String { "AppKey(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
// Deliberately NOT Codable/Encodable, so it cannot reach diagnosticReport() JSON.
```

**E-11:** `description`, `String(reflecting:)` and `dump` all print `AppKey(<redacted>)`; the Mirror has 0 children; leaks=false. `ResumeData` dumps as `ResumeData(23 bytes, redacted)`. **`dump(URLRequest)` leaks the header value (true)**, while `URLRequest.description` and `debugDescription` do not. Hence: **no `URLRequest`, `URLResponse`, `URLError` or `NSError` is ever stored in an error, event, report or log.** `URLError.userInfo` can reach the task, and from the task the request with its headers. The classifier copies codes and the few needed header values into plain values (`ResponseFacts`). `os.Logger` lines in category `transport` contain only the TransferID prefix, host (`.public`), status, error class and byte counts. The canary test (§16) checks every surface.

**Resume data embeds the key** (E-5: `resumeDataContainsAppKey=true`, ~8 KB plists). Options: (a) persist it in `staging/<id>.resume`; (b) keep it in memory only (lost on relaunch, which is when a big video most needs it); (c) rewrite the archived request to strip the key. (c) edits a private archive format, which violates R-SEC-3. **Decision: (a).** The file lives inside the protected, backup-excluded root (ADR-001). It is deleted on completion, on content change and by staging GC, and it never appears in diagnostics (only counts). The key is a scraper filter shipped inside the app binary (§2.3), and nsurlsessiond persists the same headers for any background task anyway. ADR-T4, **NEEDS-HUMAN-REVIEW** (a security choice).

---

## 6. Conditional manifest fetch (R-NET-5)

1. `HTTPRemoteSource.fetchManifest(request)` builds `TransferJob(id: .manifest, purpose: .manifest, ifNoneMatch: request.ifNoneMatch, expectedBytes: nil, maxBytes: 32 MiB, priority: .userInitiated)`. The engine single-flights manifest fetches.
2. **Request:** `GET <base>/manifest.json`, the key (if allow-listed), `If-None-Match: <stored ETag>` when one is stored, `.reloadIgnoringLocalCacheData`, and a session without a `URLCache`. E-7 recorded the full header set: `accept, accept-encoding, accept-language, connection, host, user-agent, x-zombietron-app-key`. URLSession adds **no** conditional or cache headers of its own. **No `Cache-Control: no-cache`**: the CloudFront edge's `max-age=60, must-revalidate` (§2.3) is acceptable staleness, while URLSession's local cache is not.
3. **304** → `ManifestFetchResult.notModified`. E-7: `notModified(httpStatus: 304)`, and URLSession passed the 304 through unchanged. A 304 to an unconditional request is `rejected(.unexpectedNotModified)`.
4. **200** → staged as `staging/m-manifest.part` → `staging.readStaged(…, maxBytes: 32 MiB)` off the pool → discarded → `.fetched(ManifestPayload(bytes, etag: ETag(rawValue: header), origin: .network))`. E-7's third request had no ETag and still reached the server despite `max-age=60`.
5. **The ETag** is stored by the store in `index.bin` (store.md §2.1; R-STO-2). An ETag that fails `ETag.init?` (more than 256 bytes, or non-printable) is not stored, and the next fetch is unconditional.
6. **The 32 MiB cap is enforced while streaming**, not after: `SizeGuard` in `didWriteData` cancels when the written bytes exceed 32 MiB, or as soon as the announced length exceeds it beyond the small gzip slack (E-9c: 32 MiB + 1 byte → `oversize(announced: 33554433, limit: 33554432)`; here the written count tripped it, because one byte over is inside the slack). Memory is never more than 1× payload in transport (the bytes sit on disk until `readStaged`), which leaves R-MAN-3's 4× budget to the decoder.

**Download task vs data task.** A data task would stream `Data` chunks into the mailbox and accumulate them in the waiter (bounded by the cap through `countOfBytesReceived`). Rejected: it is a second code path with a second cap implementation, background sessions do not support data tasks (`NSURLSession.h:677`), and it holds the payload in memory while it arrives.

---

## 7. Size, truncation and resume (R-NET-7, R-NET-8)

### 7.1 Size

| Check | Where | Evidence |
|---|---|---|
| **Staged size vs `byteSize`**, never `Content-Length` | `classifyFinished`, after the synchronous move | **E-3** gzip: `Content-Length` 988 (encoded), decoded and staged **315,000** = `byteSize` → staged. URLSession sent `Accept-Encoding: gzip, deflate` and decoded transparently. |
| Close-delimited body shorter than `byteSize` | same | **E-4b**: 40,000 of 100,000 → `integrity(.truncated(expected: 100000, received: 40000))`. URLSession considers this complete, so only the `byteSize` comparison catches it. |
| Body shorter than its `Content-Length` | URLSession (−1005) | **E-4a**: `transient(.connectionLost(resumable: false))` (no ETag, so no resume data) |
| Staged larger than `byteSize` | `classifyFinished` | `integrity(.sizeMismatch)` (pure test) |
| **Announced** size over the cap → abort early | `didWriteData` | **E-9a**: 10 MiB announced, 1 MiB cap → `oversize(announced: 10485760, …)` in 3–5 ms; no progress was emitted before the abort |
| **Written** size over the cap (no `Content-Length`) | `didWriteData` | **E-9b**: close-delimited 3 MiB, 1 MiB cap → `oversize(announced: nil, …)` in 2–6 ms |

`SizeGuard.mustAbort(written:announced:limit:) = written > limit ∨ announced > limit + limit/1024 + 64`. The slack covers gzip framing (+18 bytes, plus about 0.03 % on incompressible data) in case a CDN reports the encoded length. In E-3 URLSession reported `totalBytesExpectedToWrite = 315000` under gzip (first runs, `out/experiments.txt`), not the encoded 988, so the slack is a safety margin, not a dependency. Because the delegate keeps no memory, an oversize cancellation is **re-derived** at `didCompleteWithError(−999)` from `countOfBytesReceived` / `countOfBytesExpectedToReceive`, and reported as `integrity(.oversize)`, not `cancelled`.

### 7.2 Resume

| Run | Result |
|---|---|
| **E-5 honest**: 4 MiB with `ETag` + `Accept-Ranges`, dropped after 1 MiB | attempt 1 `transient(.connectionLost(resumable: true))` (or `timedOut` when RST was missed, §12), resume data 8,047 bytes, stored. Attempt 2 sent **`Range: bytes=1048576-`**, **`If-Range: "v1-abc"`** → **206**, staged 4,194,304 bytes, **hash matches** |
| **E-5 liar**: same, but the server serves a tampered tail under the same ETag | attempt 2 → 206, size OK, **hash does NOT match**. Only the store's hash (R-INT-2) catches it. |
| **E-14 / E-16**: FIN after 1 MiB of 2 MiB, 100 × | **100/100** `connectionLost(resumable: true)` with resume data, worst 6.8 ms |
| **E-17**: pause on a stalled transfer, then resume | `paused(resumable: true)` → 206 from 1,048,576, hash OK |

Rules:
1. Resume data is URLSession's (`downloadTask(withResumeData:)`). URLSession sends `Range` + `If-Range` itself (E-5). An `If-Range` mismatch makes the server send 200 with the full body, which URLSession writes from zero.
2. **Resumed bytes are never trusted.** `StagedFile.resumed = true`, and the store hashes *every* staged file before publication (store.md §5.3). There is no "skip hash if resumed" or "skip hash if size matches" path. Mutation probe Q-8 "skip hash verification" is killed by `R-NET-8: resumed bytes from a lying server never reach blobs/` (§16).
3. A resumed task that fails before any response (unusable data), or with 416 → `transient(.resumeRejected)` → `discardResumeData` → **one immediate fresh restart inside the same `transfer()`**. This is a transport-internal fallback, not an engine retry.
4. A resumed attempt that ends in an integrity failure discards the resume data, so the next attempt starts from zero.
5. **Range + If-Range on our own `.part`** (the alternative SPEC names) would need data tasks writing through a per-task file handle. That is stateful, unsupported in background sessions, and duplicates what URLSession already does (E-5). Rejected.

---

## 8. Priority mapping and scheduling (R-NET-10)

| Engine lane (sync.md §7) | `URLSessionTask.priority` | Engine scheduling | Session | OS access flags (from `NetworkPolicy`) |
|---|---|---|---|---|
| `userInitiated` | `highPriority` = **0.75** (E-10/E-17 read back) | first; reserved slot; may preempt (`pause()`) a lower lane | foreground only | per policy; `userInitiatedOverridesPolicy` sets all three to `true` |
| `prefetch` | `defaultPriority` = **0.5** | second | foreground | `allowsExpensive/Constrained` per policy |
| `bulk` | `lowPriority` = **0.25** (E-10 initial value) | last; ages ahead of prefetch | foreground; background only if §10.7 allows | per policy |

**Corrects sync.md §7.4**, which lists 1.0 and 0.0; the constants are 0.75 and 0.25 (measured). `URLSessionTask.priority` is a *hint*. It orders tasks waiting for a connection slot and weights HTTP/2 streams. H-4 is guaranteed by the engine's lanes, not by URLSession. Therefore:

- **Effective in-flight ≤ `httpMaximumConnectionsPerHost`.** In sync.md the reserved interactive slot is *inside* `maxConcurrentTransfers`; only a preempted transfer that is still producing resume data can briefly exceed it (sync §7.3). The source therefore configures `maxConnectionsPerHost = min(8, max(6, maxConcurrentTransfers + 1))`. With sync.md's default of 4 that is 6. With 16 it is 8 (P-10). Above 8 in flight, URLSession queues internally by priority: still correct (E-1b), but the lane order then relies on the hint, so the engine's slot count should not exceed 8 for one origin (recommendation to WP-F).
- **Promotion of a running transfer:** `handle.setPriority(.userInitiated)` changes the task in place; it is not restarted (E-17). **Promotion of a queued job:** engine-only. **Promotion of a background transfer:** §10.8.
- Per-request OS enforcement: `URLRequest.allowsExpensiveNetworkAccess` / `allowsConstrainedNetworkAccess` / `allowsCellularAccess` come from `NetworkAccess`. When the engine's admission (sync.md §11.2) and the OS disagree, the OS fails fast with −1009 and a reason, mapped to `offline(.expensiveDenied/.constrainedDenied/.cellularDenied)`, and the engine waits for a conditions edge.

---

## 9. Reachability and power (R-NET-9, R-SYN-7)

```swift
actor ConditionsObservation {                       // owns everything non-Sendable
    private var monitor: NWPathMonitor?
    private var tokens: [NSObjectProtocol] = []
    private var stopped = false                      // start/stop may arrive in either order
    func start(_ c: AsyncStream<DeviceConditions>.Continuation)   // one serial DispatchQueue for both inputs:
        //  monitor.pathUpdateHandler           → c.yield(snapshot(path, ProcessInfo))
        //  NSProcessInfoPowerStateDidChange,
        //  thermalStateDidChangeNotification   → OperationQueue(underlyingQueue: same queue) → c.yield(snapshot(monitor.currentPath, ProcessInfo))
    func stop()                                      // cancel monitor, remove observers
}
// conditions(): makeStream(.bufferingNewest(1)); onTermination → Task { await observation.stop() }; await observation.start(c)
```

- **Event-driven, no polling, no long-lived task.** The only task is the one-shot hop that stops the observation in `onTermination` (sync.md §8.4 counts it as unowned).
- **Consistent snapshots.** Both inputs run on one serial queue, and every element carries the full `(path, power)` state, so newest-wins buffering cannot lose a field. The alternative, partial `.network` / `.power` elements, can drop the last network change behind a power change under newest-wins buffering. Rejected.
- **E-18:** the first element is the current state (`satisfied: true, expensive: false, constrained: false, lowPower: false, thermal: nominal`). Posting `NSProcessInfoPowerStateDidChange` yields a second element. No sleeping.
- **`NWPathMonitor` capture (CAP-1):** capturing it in an `@Sendable` closure produces **no diagnostic** at iOS 15 / macOS 12, with or without `-warnings-as-errors` (`out/capture_monitor.*.txt`). That agrees with AAV §3 #7 and not with sync.md's §11.1 claim of a warning. Its `Sendable` conformance is declared iOS 17 / macOS 14 and is not enforced as a marker. **This design does not depend on it**: the monitor is created and cancelled inside the actor. The only capture is the observer closure reading `monitor.currentPath`, which is the documented-thread-safe API, on the monitor's own queue.
- **Observer tokens** (`any NSObjectProtocol`) captured in a `@Sendable` closure are a hard **error** at both floors (CAP-0, `out/capture_token.*.txt`: `capture of 'token' with non-Sendable type 'any NSObjectProtocol' in a '@Sendable' closure`). That is why they live in the actor.
- **Testability:** `ConditionsMapping` is pure and covered exhaustively. The live class is covered by E-18-style tests on the macOS host (current state, a posted notification, termination → `isObserving == false`). Real Wi-Fi/cellular/Low Data transitions are device-only (`DEVICE-TEST-PLAN.md`).

---

## 10. Background session (H-6, R-NET-3)

### 10.1 The facts that decide it

- S-3: **in a background session the redirect delegate is never called and redirects are always followed.**
- **E-13** (a background session created from a command-line process on macOS 27; it works): A answered 302 to `localhost:<B>`. **B received the canary app key** (`keyAtB=CANARY-…`). With the post-hoc check, the outcome is `rejected(.redirectRefused(.unenforceableInBackground))`, but the header had already been sent. Detection cannot un-send a header.
- S-2: background tasks cannot carry the per-task mailbox, so routing must go through `taskDescription` and a session stream.
- S-7: `waitsForConnectivity` is ignored; `earliestBeginDate` and `isDiscretionary` apply.

### 10.2 Decision (H-6), with alternatives

| Option | Description | Verdict |
|---|---|---|
| **A** Foreground only | Decline R-NET-3 (SHOULD). Bulk sync continues in `BGProcessingTask` windows (`performMaintenance`, R-SYN-16) and at the next launch. | Safe and simple, but leaves D-3 entirely open. Rejected as *the only* mode. |
| **B** Background session for bulk, key attached, always on | Re-attachment via `taskDescription`, staged files and `getAllTasks`. | **Violates R-NET-4 (MUST)** on any redirect (S-3, E-13). Rejected. |
| **C** Background session with a persistent transfer journal (taskIdentifier → asset, written before `resume()`) | Precise mapping. | Duplicates what the OS persists (`taskDescription`), costs a commit per start (P-5), and has a crash window between journal and task. It does not solve R-NET-4 either. Rejected. |
| **D** Background session for everything, user-initiated included | Out-of-process daemon start latency; discretionary scheduling; `priority` barely matters. | Breaks H-4. Rejected. |
| **E (chosen)** **B's machinery, off by default, with the key gate** | The background session is used only when (1) `BackgroundTransferPolicy.enabled(…)` (the app attests that it forwards the AppDelegate hook), (2) the transfer is `bulk` and `.backgroundEligible`, and (3) **either the request carries no app key, or the owner set `keyRedirectExposure = .acceptedByOwner`**. A post-hoc origin check discards bytes that arrived through a cross-origin redirect. A hook that is detected as not wired disables background for the process (§10.7). | R-NET-4 holds by default. R-NET-3 is fully implemented and tested, and enabled by an explicit, reviewable owner decision. **ADR-T1, NEEDS-HUMAN-REVIEW.** |

Consequence: with today's AWS tier (key always required, §2.3), production bulk transfers stay foreground **unless the owner opts in**. On iOS 26+ the Apple tier's packs are background-downloaded by the OS anyway (essential and prefetch policies, AAV §1.7).

### 10.3 Identifier scheme

`com.ztron.assetkit.bg.<namespace>.v1`, where `namespace` is `[0-9a-z-]{1,32}` from configuration (default `"default"`). It is never derived from a path: the container path changes across reinstalls, and the identifier must not. `BackgroundSessionIdentifier.isOurs(_:)` (prefix and suffix) is the hook's ownership test, so the app can route other sessions' events elsewhere. App extensions sharing a session need `sharedContainerIdentifier` (−995); that is out of scope and the error is mapped.

### 10.4 The split (only the driver is device-only)

```swift
// ZTronAssetTransport/BackgroundSessionBackend.swift — the ONLY file that creates a background session
// (prototype: 74 lines; coverage-excluded; no decisions inside)
public final class LiveBackgroundSessionDriver: BackgroundSessionDriver {
    public init(identifier: BackgroundSessionIdentifier, staging: any StagingSink, policy: TransportSecurityPolicy,
                discretionary: Bool, maxTasks: Int)
    // background(withIdentifier:), isDiscretionary, sessionSendsLaunchEvents = true, urlCache nil, cookies off,
    // httpMaximumConnectionsPerHost 4, httpAdditionalHeaders [:]; the SAME SessionDelegate in .background mode.
}

// ZTronAssetTransport — tested on macOS with FakeBackgroundSessionDriver (TransportTests)
public protocol BackgroundSessionDriver: Sendable {
    var identifier: BackgroundSessionIdentifier { get }
    var events: AsyncStream<SessionEvent> { get }              // .finished(tag, outcome) | .backgroundEventsFinished | .invalidated
    var progress: AsyncStream<TransferProgress> { get }
    func startDownload(_ request: URLRequest, resumeData: ResumeData?, tag: TransferTag, priority: Float, expectedBytes: Int64?)
    func snapshot() async -> [BackgroundTaskSnapshot]          // getAllTasks → (taskIdentifier, tag?, state, bytesReceived)
    func cancel(taskIdentifier: Int, producingResumeData: Bool) async
    func setPriority(taskIdentifier: Int, _ priority: Float) async
}
actor BackgroundTransferCoordinator: TransferBackend {         // kind = .background
    // waiters: [TransferID: Waiter]; unclaimed outcomes: [TransferID: TransferUpdate] (bounded by maxTasks);
    // one pump task over driver.events, alive only while the background backend exists (i.e. only when enabled).
    func start(_ job: TransferJob, resumeData: ResumeData?) async -> any TransferHandle   // attach-or-create by id
}
@MainActor public final class BackgroundEventsRelay {          // stores the UIKit completion handler (S-9)
    public func accept(identifier: String, completionHandler: @escaping () -> Void) -> Bool
    public func complete(identifier: String)
}
// ZTronAssetSync — pure; owned by WP-F, specified in §10.5
enum TransferReconciler { static func plan(live:staged:wanted:) -> [ReconcileAction] }
```

The shared `SessionDelegate` in `.background` mode, the tag codec, the classifier, the post-hoc origin check, the reconciler, the coordinator and the relay are all ordinary tested code. The `.background` delegate paths are covered on macOS by giving a *foreground* session a `SessionDelegate(mode: .background)` and tasks without a mailbox (the E-6c / E-13 technique). E-13 also shows that a real background session runs in a macOS test process. An optional, non-gating integration test may use it, but relaunch re-attachment stays device-only.

### 10.5 Launch re-attachment and reconciliation

Order inside `AssetClient.start()`:

```
1  store.open()                — lock, index, migration; staging is LISTED but NOT collected (change requested from store.md §2.6 step 7d)
2  source.reattachedTransfers() — getAllTasks → ReattachedTransfer list (empty when background is disabled)
3  manifest + plan             — wanted = { TransferID of every entry the plan will fetch }
4  actions = TransferReconciler.plan(live: 2, staged: staging names from 1, wanted: 3)
5  execute actions             — attach (transfer(request) joins the live OS task), cancelTransfer, publish staged, resume
6  store.collectStaging(keeping: claimed)  — only now; everything not claimed in 5 is garbage (R-CLN-3)
```

| Input state | Action | H-6 property |
|---|---|---|
| live task, tag decodes, id ∈ wanted, running or suspended, highest attempt for that id | `.attach(id, taskIdentifier)`: the engine's `transfer()` for that id joins it | **not duplicated** |
| live task with a foreign or undecodable tag, id ∉ wanted, or a lower duplicate attempt | `.cancel(taskIdentifier)` | no work for nobody |
| `staging/<id>.part` exists, id ∈ wanted | `.adoptStaged(id)`: the store publishes it through the normal hash path; on mismatch it is deleted and re-fetched | **not lost** (bytes that finished while the app was dead) |
| `staging/<id>.resume` exists, id ∈ wanted, no live task | `.resume(id)` | partial work kept |
| any staging name not claimed above | `.discardStaged(name)` | R-CLN-3 |
| `.part` and a live task for the same id | both `.adoptStaged` and `.attach`; the first verified result wins and the engine then cancels the other | no wasted bytes |

The prototype (`Background.swift`, `BackgroundReconciler.plan`) is deterministic: sorted output, attempts ordered high to low. This launch reconciliation also covers **foreground** downloads that were staged but not yet published when the app died. That is store.md's F2 case, which today re-fetches.

### 10.6 The AppDelegate hook

```swift
extension AssetClient {
    /// Forward application(_:handleEventsForBackgroundURLSession:completionHandler:). Returns false for identifiers
    /// that are not ours. The handler is UIKit's plain () -> Void (S-9), so it never leaves the main actor.
    @MainActor public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool
}
```

Sequence: (1) on main, `relay.accept` stores the handler synchronously; (2) a task asks the coordinator to make sure the background session with that identifier exists, since creating it is what makes the OS deliver events. Order (1) before (2) is guaranteed because (2) is started after (1) returns. (3) The delegate moves each finished file into staging synchronously and yields `.finished`. (4) `urlSessionDidFinishEvents` yields `.backgroundEventsFinished(id)`, which is **after** every preceding event in the same stream. (5) The coordinator processes the stream in order. Once the engine has committed (or at least staged) the preceding outcomes, it calls `await relay.complete(identifier:)` on main. Bytes are already durable in staging at (3), so if the app is suspended before commit, §10.5 adopts them at the next launch.

### 10.7 Falling back to foreground

A `.backgroundEligible` transfer runs in the foreground when **any** of these holds:

- the policy is `.disabled` (the default);
- the request would carry the key and `keyRedirectExposure != .acceptedByOwner`;
- the lane is not `bulk`;
- the background session reported −995/−996/−997 (that job retries in the foreground, and background is disabled for the process);
- **the hook was detected as not wired**: `urlSessionDidFinishEvents` arrived while the relay held no handler for that identifier, which only happens when the OS launched the app for background events and the app did not forward the hook. Background is then disabled for the process and a fault is logged.

The attestation flag cannot be verified any other way without UIKit (R-CAR-9).

### 10.8 Promotion and the attempt rule

A bulk transfer in the background session that gains a `userInitiated` interest (H-4) gets `pause()` on its background handle (cancel producing resume data). The engine then starts `attempt + 1` in the **foreground** with that resume data. Resume data from a background download task is *(unverified)* to be accepted by a foreground session: if it is rejected, §7.2 rule 3 restarts fresh. **Rule:** a terminal from a stale attempt is ignored *unless* it is a success. A verified success from any attempt satisfies the waiters (content-addressed, hash-checked), and the engine cancels the rest.

---

## 11. Apple-hosted tier (R-APL-1…5, R-CLN-10, H-7)

### 11.1 The seam

```swift
// ZTronAssetAppleHosted — the whole target sits under #if canImport(BackgroundAssets) (true on both SDKs, AAV §2).
// These types mention no BackgroundAssets type, so they are testable on any host with FakePackBackend.
public struct PackID: Hashable, Sendable { public let rawValue: String; public init?(rawValue: String) }  // [A-Za-z0-9._-]{1,64}
public struct PackLocation: Hashable, Sendable {          // "<packID>/<path inside pack>" (§2.3)
    public let pack: PackID
    public let path: String
    public init?(remotePath: String)
}
public struct PackProgress: Sendable, Hashable { public var completed: Int64; public var total: Int64 }  // D-12: never Foundation.Progress
public enum PackError: Error, Sendable, Hashable {
    case packNotFound, fileNotFound, tooLarge(limit: Int), readFailed
    case system(domain: String, code: Int)                // undocumented errors (AAV §1.8, UNVERIFIED types)
}
public struct PackUpdateCheck: Sendable, Hashable { public var updating: Set<PackID>; public var removed: Set<PackID> }
/// Opens lazily on the first read, so every blocking call happens on Storage's bulk executor (via ChunkSource).
public protocol PackFileReader: ChunkSource {}
public protocol PackBackend: Sendable {
    func reader(for path: String, in pack: PackID) -> any PackFileReader          // non-blocking
    func ensureAvailable(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async throws(PackError)
    func checkForUpdates() async throws(PackError) -> PackUpdateCheck
    func remove(_ pack: PackID) async throws(PackError)
}
public enum PackRetention: Sendable, Hashable { case keepPacks, releaseAfterAdoption }
public struct AppleTierConfiguration: Sendable, Hashable {
    public var catalog: PackLocation                       // default "ZTronCatalog/catalog.json"
    public var retention: PackRetention                    // default .releaseAfterAdoption (ADR-T2, NEEDS-HUMAN-REVIEW)
    public var updateCheckOnManifestFetch: Bool = true
}
@available(iOS 26.0, macOS 26.0, *)                        // R-APL-1 (written with macOS: AAV §1.2 ba11)
public final class AppleHostedRemoteSource: RemoteSource {
    public init(configuration: AppleTierConfiguration, backend: any PackBackend, staging: any StagingSink)
    // originID "apple-hosted"; capabilities: tier .appleHosted, priority/resume/background false, keepsSourceCopies true
}
```

**`LiveAssetPackBackend.swift`** (the only file importing BackgroundAssets; prototype **104 lines**; `@available(iOS 26.0, macOS 26.0, *)`). The prototype compiles the eager variant (`contents(of:in:maxBytes:)` and `openFile(_:in:)`). The lazy `reader(for:in:)` proposed above is the same calls moved into the reader's first `read`, so the descriptor open also runs on Storage's bulk executor.

- uses only the 26.0 surface: `assetPack(withID:)`, `ensureLocalAvailability(of:)`, `statusUpdates(forAssetPackWithID:)`, `descriptor(for:searchingInAssetPackWithID:)`, `checkForUpdates()`, `remove(assetPackWithID:)`;
- maps `.downloading(_, Progress)` to a `PackProgress` value at the boundary, with `@unknown default` in every switch;
- wraps the descriptor in `FileHandle(fileDescriptor:closeOnDealloc: true)` + `read(upToCount:)` (no mutable pointer);
- references `AssetPackManager.shared` only inside method bodies (constructing the type touches nothing, AAV §1.7 b);
- error mapping: `ManagedBackgroundAssetsError` → `packNotFound` / `fileNotFound`; anything else → `.system(domain, code)`. The pure `PackErrorMapping` then maps `PackError` → `TransferError`. An `NSURLErrorDomain` code reuses the §3.4.2 table; everything else → `transient(.unknown)`; **never** integrity.
- TC-1: compiles at iOS 15 and macOS 12 inside its availability context (deprecations are reported against the deployment target, so none appear, AAV §1.2).

### 11.2 Catalog in the essential pack (R-APL-4) and offline fallback

```
fetchManifest(request):
  if request.allowsUpdateCheck ∧ config.updateCheckOnManifestFetch:
      try? backend.checkForUpdates()            // best effort: returns after scheduling, never waits (AAV §1.6);
                                                // failure ⇒ origin = .installedPack(updateChecked: false)
  bytes ← staging.writeStaged(.download(.manifest), from: backend.reader(catalog.path, catalog.pack), maxBytes: 32 MiB)
          then readStaged + discardStaged       // all blocking reads on Storage's bulk executor
  etag  ← "\"sha256:<hex of bytes>\""           // pseudo-ETag: unchanged catalog ⇒ .notModified, same engine path as HTTP 304
  if etag == request.ifNoneMatch → .notModified
  else .fetched(ManifestPayload(bytes, etag, origin: .installedPack(updateChecked:), removedSources: check.removed))
  catalog pack not installed (notFound / notInstalled):
      try ensureAvailable(catalog.pack) once, then re-read; failing that → TransferError (offline/transient/permanentMissing)
```

There are **two fallback levels for "offline falls back to the last installed catalog"**: (1) the catalog JSON inside the on-disk essential pack (readable offline; `checkForUpdates` failure is swallowed); (2) when even that is unreadable, the error leaves the engine's applied manifest in `index.bin` in force (sync.md: a failed manifest fetch does not unapply anything). `removedSources` feeds prune: an entry whose pack the system removed or obsoleted is *missing*, never *present*, unless it was already adopted into `blobs/`.

### 11.3 Asset fetch: adopt into blobs

```
transfer(request):  loc ← PackLocation(remotePath) else .failed(.rejected(.invalidURL))
  1  try staging.writeStaged(.download(id), from: backend.reader(loc.path, loc.pack), maxBytes: request.maxBytes)
     — succeeds when the pack is installed (no network)
  2  on .source(.notFound | .notInstalled): PackAvailabilityCoordinator.ensure(loc.pack)   // single-flight per pack (actor)
       progress: PackProgress → .progress(received: fraction × expectedBytes, expected) (quantised); then retry 1 once
  3  size check vs expectedBytes → .staged(StagedFile(httpStatus: nil, resumed: false)) → the engine publishes via the hash path
  4  after ensure, fileNotFound again → .failed(.permanentMissing(404)): the catalog and the pack disagree
```

`setPriority` is a no-op (the OS schedules packs). `pause`/`cancel` cancel the waiter. Whether cancelling `ensureLocalAvailability` stops the OS download is **UNVERIFIED** (harmless either way).

### 11.4 H-7 double residency — decision, with alternatives

| Option | Residency | Verdict |
|---|---|---|
| **A** Serve in place via `url(for:)` | single copy | Rejected on SDK facts (AAV §1.4): the URL is valid for the current process only, can dangle, is not pack-scoped (namespace collisions), resolving it blocks, and the bytes can change on a background pack update **without R-INT-2 verification**. `lookup` (P-8: zero file-system calls on main) could not return it without a per-process off-main warm-up. Quota and eviction (R-CLN-4) could not account for OS-held bytes. |
| **B** Adopt and keep the pack (prior art, D-11) | permanent ×2 | Rejected as the default (it is the defect); offered as `retention: .keepPacks` for owners who never want a pack re-download. |
| **C (chosen) Adopt and release** | ×2 only between the first adoption in a pack and its release; bounded by one pack size | Stream into staging → hash → blob (R-STO-3). `PackReleasePlanner` releases a media pack only when **every** catalog entry mapped to it is adopted (removal is whole-pack, AAV §1.5), never the catalog pack, at most once per `(pack, catalog generation)`. Then `remove(assetPackWithID:)` (R-CLN-10). |
| **D** APFS clone (`fclonefileat` from the pack descriptor) | physical ×1 even before release | Compiles at the floor and works between ordinary files on the host (AAV §1.4). Whether the sandbox allows cloning **from the OS pack store** is UNVERIFIED (device). Deferred: an optional `StagingSink` fast path, keeping C as the fallback. |

```swift
public enum PackReleasePlanner {        // pure; ZTronAssetAppleHosted
    public static func packsToRelease(catalogEntries: [PackLocation], adopted: Set<PackLocation>, catalogPack: PackID,
                                      retention: PackRetention, alreadyReleased: Set<PackID>) -> [PackID]
}
```

Consequences:

- **An evicted or corrupted asset whose pack was released** comes back only by re-downloading the *whole* pack (`ensureAvailable`). Recommendation to WP-B/WP-F: rank Apple-adopted assets after ordinary evictable ones, or treat them as `essential`, when `retention == .releaseAfterAdoption`.
- **Packs that come back.** Whether a removed essential or prefetch pack is re-downloaded on the next app update is UNVERIFIED (AAV §5). The planner releases again at most once per catalog generation, so there is never a loop.
- **Pack and catalog skew.** If an updated catalog arrives before its media pack updates, adoption fails the hash (`integrity`). That triggers R-INT-3 backoff plus one best-effort `checkForUpdates()`; the system's own background update eventually converges.
- `reclaimSourceCopies(AdoptionReport)` is the engine's hook for running the planner after a sync. HTTP sources return an empty report.

### 11.5 Tier selection (R-APL-5): the module's only `#available`

```swift
public struct TierInputs: Sendable, Hashable { osSupportsAppleTier, appleConfigured, awsConfigured, awsOnly: Bool }
public enum TierUnavailable: Error, Sendable, Hashable { case noSourceConfigured }
public enum TierSelection {
    /// Pure; all 16 combinations tested.
    public static func select(_ inputs: TierInputs) -> Result<AssetTier, TierUnavailable>
    /// The ONLY #available in the package. The Apple source is constructed INSIDE the availability region,
    /// so no caller needs a second check. Tests pass a fake PackBackend; production passes nil and gets the live one.
    public static func live(apple: AppleTierConfiguration?, awsOnly: Bool, aws: (any RemoteSource)?,
                            staging: any StagingSink, packBackend: (any PackBackend)? = nil)
        -> Result<any RemoteSource, TierUnavailable>
}
// body (prototype, AppleProto/AppleTier.swift):
//   guard #available(iOS 26.0, macOS 26.0, *) else { return Self.build(TierInputs(osSupportsAppleTier: false, …), aws: aws, makeApple: nil) }
//   return Self.build(TierInputs(osSupportsAppleTier: true, …), aws: aws,
//                     makeApple: apple.map { c in { AppleHostedRemoteSource(c, backend: packBackend ?? LiveAssetPackBackend(), …) } })
```

| os ≥ 26 | Apple configured | `awsOnly` | AWS configured | Result |
|---|---|---|---|---|
| ✓ | ✓ | ✗ | any | `.appleHosted` |
| ✓ | ✓ | ✓ | ✓ / ✗ | `.aws` / `.noSourceConfigured` |
| ✓ | ✗ | any | ✓ / ✗ | `.aws` / `.noSourceConfigured` |
| ✗ | any | any | ✓ / ✗ | `.aws` / `.noSourceConfigured` |

- **Coverage on a macOS 27 host**, where the condition is always true: the `else` is written on the `guard` line itself, so line coverage counts it as executed. The *decision* for `osSupportsAppleTier == false` is covered through `select`/`build` (AAV §2 consequence).
- **A second `#available` was avoidable.** The 26.4 and 27 APIs (`requireLatestVersion:`, `localStatus`, `manifest`) would each need a rung. The 26.0 surface suffices: `checkForUpdates()` gives update checks; `ensureLocalAvailability(of:)` (deprecated in 26.4, no warning at a 15 target) and an installed-pack read give offline detection. ADR-T7. Risk: a future SDK *removes* a deprecated 26.0 API; Q-1 would catch it at build time.
- `AssetPackManager.shared` is never touched by `init`, by tier selection, or by tests (`LiveAssetPackBackend()` is constructed but only called on device).

---

## 12. `LoopbackHTTPServer` (ZTronAssetTestSupport; ADR-011)

```swift
public struct LoopbackRequest: Sendable, Hashable {
    public let connection: Int        // 1-based accept order (P-10 assertions)
    public let sequence: Int          // global request order
    public let pathSequence: Int      // n-th request for this target: scripts "first drop, then 206" purely
    public let method: String, target: String
    public let headers: [String: String]           // lowercased names
    public func header(_ name: String) -> String?
}
public enum LoopbackEnding: Sendable, Hashable {
    case complete
    case closeAfter(bodyBytes: Int)    // FIN mid-body: deterministic "connection lost" (E-16 100/100)
    case resetAfter(bodyBytes: Int)    // RST via forceCancel(): NOT deterministic (E-16: 1–7 % → request timeout)
    case stallAfter(bodyBytes: Int)    // hold the connection open until stop(): deterministic mid-flight (E-17)
}
public enum LoopbackEncoding: Sendable, Hashable { case identity, gzip }
public struct LoopbackResponse: Sendable {
    public var status: Int, headers: [String: String], body: Data
    public var encoding: LoopbackEncoding, ending: LoopbackEnding
    public var latencyNanoseconds: UInt64
    public var rangeETag: String?       // sends ETag + Accept-Ranges; honours Range / If-Range → 206 + Content-Range
    public var omitContentLength: Bool  // close-delimited body
}
public protocol LoopbackDelay: Sendable { func wait(nanoseconds: UInt64) async }
public struct NoLoopbackDelay: LoopbackDelay {}            // default: correctness tests never sleep (C4, Q-4)
public struct LiveLoopbackDelay: LoopbackDelay {}          // Task.sleep: ONLY the P-11 benchmark uses it
public typealias LoopbackHandler = @Sendable (LoopbackRequest) -> LoopbackResponse
public actor LoopbackHTTPServer {
    public init(delay: any LoopbackDelay = NoLoopbackDelay(), handler: @escaping LoopbackHandler)
    public func start() async throws -> UInt16   // NWListener: requiredLocalEndpoint 127.0.0.1, .any port, requiredInterfaceType .loopback; no acceptLocalOnly (the iOS Simulator resets 127.0.0.1 connections to such a listener; docs/adr-drafts/ios.md item 3)
    public func stop()                            // cancels the listener and every connection (stalled ones included)
    public var acceptedConnections: Int { get }   // P-10
    public var requests: [LoopbackRequest] { get }// key-stripping and Range assertions
}
public enum Gzip { public static func compress(_ data: Data) -> Data; public static func crc32(_ data: Data) -> UInt32 }
```

- **Implementation (prototype, 295 lines).** The actor owns the listener, the connection table, the counters and the log. Each connection is served by one async loop: `receive` and `send` are bridged with `withCheckedContinuation`; the buffer is a local `var` in that loop; HTTP/1.1 keep-alive with `Content-Length`; `Connection: close` honoured. Gzip is RFC 1952 framing around `NSData.compressed(using: .zlib)` (raw DEFLATE) with a plain-Swift CRC-32 (E-3 self-check: round trip OK).
- **Zero escapes, no `Mutex`** (the Mutex option of the brief is not needed): 0 unsafe-pattern matches; TC-1 compiles it for iOS 15 and macOS 12. The `NWListener`/`NWConnection` captures in `@Sendable` handlers rely on the same unenforced marker conformance as `NWPathMonitor` (CAP-1), on a test-only path.
- **Determinism rules for tests:** one server per test (ephemeral port, parallel-safe); `NoLoopbackDelay`; connection drops use `closeAfter` (FIN), **never `resetAfter`** (E-16), which is documented as unsuitable for gating tests; mid-flight states use `stallAfter` plus `stop()`; tests set `requestTimeout` to 10 s so a missed event fails long before `.timeLimit`.
- **Q-4 note.** `LiveLoopbackDelay` sleeps for real, but only inside the P-11 benchmark, whose subject *is* wall time (same ruling requested by sync.md R-9).

---

## 13. Failure analysis

| # | Failure | What happens | Invariant / requirement | Test (§16) |
|---|---|---|---|---|
| F-1 | Killed between task creation and `resume()` | No OS task exists; the next run plans the fetch again. | — | `R-NET-3: …tasks for content…`; model |
| F-2 | Killed after the OS finished a background download but before the delegate ran | The OS redelivers `didFinishDownloadingTo` when the session is recreated *(device, UNVERIFIED)*; otherwise the bytes are re-fetched. | H-6 (bounded loss: bytes, never state) | DEVICE-TEST-PLAN |
| F-3 | Killed after the synchronous move, before publish | `staging/<id>.part` adopted at launch (§10.5) through the hash path. | H-6, I-1, I-4 | `R-NET-3: a download completed while the app was dead…` |
| F-4 | `adoptDownload` hits ENOSPC/EIO | `insufficientSpace` / `transient(.localIO)`; the temp file is deleted by the OS. | R-SYN-11 | `R-NET-6: ENOSPC…` |
| F-5 | Progress flood, slow consumer | Newest-wins per transfer; the terminal is never dropped. Background terminals are in their own bounded stream. | H-9 | `R-NET-2: …mailbox…`, quantiser property |
| F-6 | Background lifecycle buffer overflow (cap exceeded) | Impossible while the engine's `maxTasks` holds. If it happened: staged file plus `getAllTasks` reconcile. | H-6, H-9 | coordinator test with a full buffer |
| F-7 | Consumer cancelled | `onTermination` cancels the task; `.cancelled(.byClient)` (E-10). | R-SYN-4 | `R-NET-2: cancelling the consumer…` |
| F-8 | RST mid-body | 93–99 % `connectionLost(resumable:)`, the rest `timedOut` after the request timeout (E-16, three runs of 100). Both are transient and resumable. | R-NET-6/8 | (RST is not used in gating tests) |
| F-9 | Body shorter than `Content-Length` | −1005 → transient, resumable when an ETag is present (E-4a, E-14). | R-NET-7 | `R-NET-7: a body shorter than its Content-Length…` |
| F-10 | Close-delimited short body | `integrity(.truncated)` (E-4b). | R-NET-7 | `R-NET-7: a close-delimited body…` |
| F-11 | gzip | The decoded size is compared; `Content-Length` ignored (E-3). | R-NET-7 | `R-NET-7: a gzip response…` |
| F-12 | Staged file whose waiter was cancelled in the same instant | Unclaimed `.part` → staging GC. | I-4, R-CLN-3 | store's staging GC tests |
| F-13 | Resume from a lying server (same ETag, different bytes) | Size OK, hash fails → staged bytes deleted, resume data discarded, R-INT-3 backoff (E-5 liar). | R-NET-8, R-INT-2 | `R-NET-8: resumed bytes from a lying server never reach blobs/` |
| F-14 | Unusable resume data, or 416 | `resumeRejected` → discard → one fresh restart within the transfer. | R-NET-8 | `R-NET-8: invalid resume data…`, `…416…` |
| F-15 | Resume data stale after an app update with a new key | Resumed request 403 → evidence → the engine counts it; resume data discarded after any auth failure. | R-NET-6 | `R-NET-8: an authentication failure on a resumed request discards…` |
| F-16 | Cross-host redirect (foreground) | Key stripped; followed only if allow-listed (E-6a/e). | R-NET-4 | §16 redirect suite |
| F-17 | Redirect loop / more than 5 hops | Refused at hop 6 (E-6d). | R-NET-4 | `R-NET-4: …the sixth hop is refused` |
| F-18 | HTTPS → HTTP downgrade | Refused (`insecureScheme`). | R-NET-4 | `R-NET-4: an HTTPS to HTTP downgrade is refused` |
| F-19 | Redirect inside a background session | Key already sent (S-3, E-13). Bytes refused after the fact; background never carries the key by default. | R-NET-4 vs R-NET-3 | `R-NET-4: a background-mode delegate refuses…`, `R-NET-3: a key-bearing transfer never uses the background session…` |
| F-20 | 403 | `forbiddenAmbiguous(evidence)`; the engine's breaker decides. | R-NET-6, §2.3 | `R-NET-6: 403…`, `R-SYN-5: …breaker…` |
| F-21 | Absurd `Retry-After` (far future, 11 digits, garbage) | Transport: parsed or `nil`. Engine: clamps to `maxRetryAfter`. | H-8 | `R-NET-6: Retry-After…` |
| F-22 | Malicious ETag (huge, control characters) | `ETag.init?` → nil → not stored. | R-MAN-2 spirit | `R-NET-5: ETag rejects…` |
| F-23 | 304 to an unconditional request | `rejected(.unexpectedNotModified)`. | R-NET-5 | `R-NET-5: a 304 without…` |
| F-24 | Session invalidated unexpectedly | `.invalidated` → all handles fail transient; the facade recreates the backend at the next `start()`. | R-SYN-15 | `R-NET-2: invalidation fails every live transfer…` |
| F-25 | Conditions start/stop race | The `stopped` flag makes a late `start` a no-op. | R-NET-9, P-14 | `R-NET-9: terminating…` |
| F-26 | Hook not wired | Detected at `didFinishEvents` with no handler → background off for the process. | R-NET-3 | `R-NET-3: didFinishEvents without a registered handler…` |
| F-27 | App and extension share an identifier | −996 → `backgroundSessionUnavailable` → foreground fallback. | R-NET-3 | classifier table |
| F-28 | Apple: catalog pack missing offline | Offline error; the applied manifest stays. | R-APL-4 | `R-APL-4: a missing catalog pack while offline…` |
| F-29 | Apple: pack removed or obsolete | `removedSources` → not-yet-adopted entries missing; adopted ones stay. | R-APL-4 | `R-APL-4: packs removed by the update check…` |
| F-30 | Apple: pack and catalog skew | Hash fails → backoff + one `checkForUpdates`. | R-INT-3 | `R-APL-2: …skew…` |
| F-31 | Apple: released pack re-downloaded by the OS | Released again, at most once per catalog generation. | H-7 | `R-CLN-10: a pack that comes back…` |
| F-32 | Apple: asset of a released pack evicted | Whole-pack re-download on the next resolve; eviction ranking mitigates. | H-7 | engine / store eviction test (WP-B/F) |
| F-33 | Delegate leak (URLSession retains its delegate) | `shutdown` → `invalidateAndCancel`. | R-SYN-15 | `R-NET-2: shutdown invalidates the session…` |
| F-34 | `URLRequest` / `URLError` leaking the key into logs or errors | Never stored; only plain facts are copied (E-11). | R-SEC-1 | canary test |

---

## 14. Budgets owned here

| Budget | How it is met | Measured (transport only, this session) | Benchmark design (`ZTronAssetKitBenchmarks`, release, thresholds read from `quality-gates.json`) |
|---|---|---|---|
| **P-10** ≤ `connections_max` (8) for `assets` (500) | One session; `maxConnectionsPerHost ≤ 8` (§8) | **5** at concurrency 5 / max 6; **8** at concurrency 16 / max 8 (E-1, E-1b) | `AssetClient` with the package loopback policy → sync of a 500-entry manifest of 1 KiB assets → `#expect(server.acceptedConnections <= budgets.P-10.connections_max)` |
| **P-11** ≥ `speedup_min` (3×) for `assets` (200), `server_latency_ms` (10), `concurrency` (5) vs 1 | Parallel HTTP/1.1 connections; no per-request session | **5.20–5.64×** (E-2, four runs) | Two fresh clients with `maxConcurrentTransfers` = `concurrency` and 1, `LiveLoopbackDelay`, best of 3 wall times per side, ratio ≥ `speedup_min`. **Risk RK-4:** the engine's final commit tail. |

---

## 15. Reconciliation with `sync.md` and `store.md` (Phase C to decide)

| # | Topic | Other design | This design | Proposed resolution |
|---|---|---|---|---|
| X-T1 | Engine-facing transfer control | sync §3.3: `transfer(_:control: AsyncStream<TransferControl>) -> AsyncStream<TransferUpdate>`, control `.bufferingNewest(1)` | `transfer(_:) -> any TransferHandle` with **synchronous** `setPriority` / `pause` / `cancel` (§3.2), plus `updates` | Adopt the handle. It satisfies sync's constraint ("promotion inside `join` cannot await") with no consumer task per transfer (P-14: the control stream needs one, alive until the engine finishes the stream) and no coalescing hazard: under `.bufferingNewest(1)`, `.pause` followed by `.setPriority` before the consumer runs **loses the pause**. If sync keeps the stream, the transport adapts with one consumer task per transfer, and the buffer must become `.bufferingNewest(2)` with pause as a sticky flag. |
| X-T2 | R-NET-10 constants | sync §7.4: `highPriority (1.0)`, `lowPriority (0.0)` | **0.75 / 0.5 / 0.25** measured (E-10, E-17) | Correct sync §7.4. |
| X-T3 | Manifest call | `fetchManifest(ifNoneMatch: String?)` → `.notModified \| .fetched(Data, etag)` | `fetchManifest(ManifestRequest)` with `maxBytes`, `access`, `allowsUpdateCheck`; the payload carries `origin` and `removedSources` | Adopt the struct: the Apple tier needs the update-check flag and returns removals; the cap is a parameter, not a constant. |
| X-T4 | Error names | `notFound`, `server(status)`, `throttled(retryAfter)`, `authRejected`, `tooLarge`, `sizeMismatch` | §3.4 (nested by engine action), plus `rejected` | Use §3.4; the mapping is §3.4.3. **Add a `rejected` row to sync §8.1.** Keep the manifest-403 inference in the engine, labelled as an inference. |
| X-T5 | Staging names | store §2.1/§4.2: `staging/<UUID>.part`, `reserveStaging(for: AssetID)` with UUIDs from the seeded `RandomSource` | `staging/<TransferID>.part\|.resume`, a pure function of the content hash | Deterministic names (C4 as the brief demands, no reservation round trip before `pump()` starts a transfer, self-describing at launch for H-6). The store keeps claims as `Set<TransferID>`. Layout deviation from SPEC §4.3 → ADR-T3, **NEEDS-HUMAN-REVIEW**. |
| X-T6 | Launch staging GC | store §2.6 step 7d deletes every `.part` without a parseable `.resume` **inside `open()`** | §10.5: staging is listed in `open()` but collected only **after** re-attachment and reconciliation | Change 7d: keep `<TransferID>.part` whose content key is an expected, not-present checksum of the applied manifest (adopt it through `publish`, which hashes), and defer every other deletion to `collectStaging(keeping:)` after the engine's reconcile. Otherwise a background download finished while the app was dead is destroyed: **H-6 "lose"**. |
| X-T7 | Blocking reads for the Apple tier | store §3: `BlockingExecutor` lives in Storage | The Apple tier needs no executor: pack reads are `ChunkSource`s pulled by `StagingSink.writeStaged` on Storage's bulk executor | Add `writeStaged`, `readStaged`, `discardStaged` to the sink (§3.3). |
| X-T8 | Device conditions | sync §11: the live conformer belongs to transport; merged stream | `LiveDeviceConditionsSource` (§9), sync's types, one serial queue, full snapshots | Agreed. CAP-1 contradicts sync's §11.1 / R-3 warning claim; harmless, since both designs use an actor owner. |
| X-T9 | Re-attachment | sync §3.3 `reattachedTransfers()` consumed once by `start()` | Same, plus `cancelTransfer(_:)` and the pure `TransferReconciler` in Sync (§10.5), run **before** staging GC | Add `cancelTransfer`; place the reconciler in `ZTronAssetSync`. |
| X-T10 | P-14 census | Engine counts drivers, alarm, watcher | The foreground transport owns **0** tasks (no pump, no forwarder). The background coordinator owns one pump, only when background is enabled. Conditions: one transient stop-hop on termination. | The census is unaffected in the default configuration; report the coordinator's pump in `EngineIntrospection` when enabled. |

---

## 16. Test plan

Every MUST owned here has at least one test whose display name begins with its ID (Q-6). The trace gate parses only `R-…` and `P-…` IDs, so H-6 and H-7 tests are named by their requirements (R-NET-3, R-APL-3, R-CLN-10). Suites that await use `.timeLimit(.minutes(1))`, which needs `@available(macOS 13.0, *)` on each **test function** (AAV §3.2; the orchestrator's ruling). Loopback tests use `NoLoopbackDelay` and a 10 s request timeout. All `arguments:` tables are exhaustive, and fuzz tests are seeded and print the seed.

### 16.1 Model (`Tests/ZTronAssetModelTests`)
- `R-NET-1: TransferID accepts only [0-9a-z-] up to 96 bytes and never contains a path separator` (seeded fuzz)
- `R-NET-1: StagingFileName round-trips through its parser and rejects foreign names`
- `R-NET-5: ETag rejects values over 256 bytes or with control characters`
- `R-NET-6: every TransferError case is distinguishable by equality` (arguments: all cases)
- `R-SEC-1: AppKey and ResumeData redact themselves under String(describing:), String(reflecting:), dump and Mirror`

### 16.2 Classifier and pure policy (`Tests/ZTronAssetTransportTests`)
- `R-NET-6: HTTP statuses map to the closed taxonomy` (arguments: §3.4.1, every row)
- `R-NET-6: URLError codes map to the closed taxonomy` (arguments: §3.4.2, every code)
- `R-NET-6: a 403 is reported as forbiddenAmbiguous with evidence, never as notFound or a confirmed rejection`
- `R-NET-6: the 403 hint is key-rejected for an empty body or a manifest, object-missing for an XML body`
- `R-NET-6: notConnectedToInternet maps to the offline reason given by URLError.NetworkUnavailableReason`
- `R-NET-6: a cancellation after the size cap was exceeded is reported as oversize, not cancelled`
- `R-NET-6: background cancel reasons map to cancelled by the system`
- `R-NET-6: ENOSPC under a file error maps to insufficientSpace`
- `R-NET-6: Retry-After parses delta-seconds and all three HTTP-date formats` (arguments: E-15 vectors)
- `R-NET-6: an unparsable, negative or over-long Retry-After is treated as absent`
- `R-NET-7: SizeGuard aborts exactly when the written or announced size exceeds the cap` (property)
- `R-NET-7: the progress quantiser emits at most 65 plus size/256 KiB reports per transfer` (property)
- `R-NET-10: AssetPriority maps to URLSessionTask priorities 0.75, 0.5 and 0.25`
- `R-NET-3: TransferTag round-trips through taskDescription and rejects foreign or over-long tags` (seeded fuzz)
- `R-NET-4: the redirect decision keeps the key only while every hop stays on the original origin` (arguments: origin triples)
- `R-NET-4: an HTTPS to HTTP downgrade is refused`
- `R-NET-4: plain HTTP is refused by the production policy even for loopback hosts`
- `R-NET-4: the foreground session configuration has no httpAdditionalHeaders and no URLCache`
- `R-SEC-3: no file under Sources/ declares NSAllowsArbitraryLoads or an ATS exception`

### 16.3 Foreground backend against `LoopbackHTTPServer`
- `R-NET-2: 500 downloads through one backend use at most maxConnectionsPerHost TCP connections`
- `R-NET-2: every task update reaches its own transfer through the mailbox and none through the session stream`
- `R-NET-2: a finished download is renamed into staging under its TransferID before the delegate returns` (also cites R-STO-1 in the store's suite)
- `R-NET-2: cancelling the consumer cancels the URLSession task and reports cancelled by the client`
- `R-NET-2: invalidation fails every live transfer and finishes the session stream`
- `R-NET-2: shutdown invalidates the session so the delegate is released`
- `R-NET-6: status mapping through the real delegate matches the pure table` (arguments: E-8 routes)
- `R-NET-4: a cross-host redirect to an allow-listed host is followed without the app key` (§7.3 scenario)
- `R-NET-4: a redirect to a host outside the allow-list is refused and that host receives no request`
- `R-NET-4: same-origin redirects keep the key and the sixth hop is refused`
- `R-NET-4: once stripped, the key never returns on a redirect back to the original origin`
- `R-NET-4: a background-mode delegate refuses bytes that arrived through a cross-origin redirect`
- `R-NET-4: a resumed task whose archived request fails the policy is cancelled before it starts`
- `R-SEC-1: the canary key appears in no description, dump, Mirror, error, event, metric or captured log line`. This runs every scenario of this section with `AppKey("CANARY-…")` and scans all outputs; `.resume` files are excluded with the documented reason (§5.4).
- `R-NET-5: a manifest fetch sends If-None-Match with the stored ETag and maps 304 to notModified` (§7.3 scenario)
- `R-NET-5: URLSession never answers a manifest fetch from its own cache, even within max-age`
- `R-NET-5: a 304 without a conditional request is rejected`
- `R-NET-5: a manifest over 32 MiB is aborted while streaming`
- `R-NET-7: a gzip response is accepted when the decoded size equals byteSize though Content-Length differs` (§7.3)
- `R-NET-7: an announced size over maxAssetBytes aborts before any progress is reported` (§7.3)
- `R-NET-7: a close-delimited body shorter than byteSize is reported as truncated` (§7.3 truncated body)
- `R-NET-7: a body shorter than its Content-Length is reported as a lost connection`
- `R-NET-8: a connection dropped mid-download resumes with Range and If-Range and the staged file is complete` (§7.3; FIN via `closeAfter`)
- `R-NET-8: pause on a stalled transfer yields paused(resumable: true) and stores resume data`
- `R-NET-8: invalid resume data falls back to one fresh download within the same transfer`
- `R-NET-8: a 416 on a resumed request discards the resume data`
- `R-NET-8: an authentication failure on a resumed request discards the resume data`
- `R-NET-10: setPriority on a running transfer changes URLSessionTask.priority synchronously` (`stallAfter`)

### 16.4 Conditions
- `R-NET-9: the live conditions source yields the current state first, then on change, without polling`
- `R-NET-9: terminating the conditions stream stops path monitoring and removes the observers`
- `R-NET-9: path mapping exposes satisfied, expensive and constrained exactly` (arguments: 8 combinations)
- `R-NET-9: thermal states map to four levels and unknown future states to critical`

### 16.5 Background (fake driver; `FakeBackgroundSessionDriver` keeps "OS" tasks across coordinator instances)
- `R-NET-3: the background identifier is stable, namespaced and recognised by the hook`
- `R-NET-3: a live background task is re-attached after relaunch, not duplicated`
- `R-NET-3: a download completed while the app was dead is adopted from staging, not re-downloaded`
- `R-NET-3: live tasks for content the manifest no longer wants are cancelled at launch`
- `R-NET-3: the reconciliation plan is deterministic and accounts for every live task and staged file` (property, in `ZTronAssetSyncTests`)
- `R-NET-3: staging GC runs after reconciliation and keeps every adopted or resumed name` (integration with the store; WP-F/WP-B)
- `R-NET-3: the completion handler runs once, after every event that preceded didFinishEvents`
- `R-NET-3: without the hook wired, background-eligible transfers run in the foreground`
- `R-NET-3: a key-bearing transfer never uses the background session unless the owner accepted redirect exposure`
- `R-NET-3: didFinishEvents without a registered handler disables background transfers for the process`
- `R-NET-3: promoting a background transfer pauses it and continues it in the foreground with its resume data`
- `R-NET-3: a success from a stale attempt satisfies the waiters and a stale failure is ignored`

### 16.6 Apple tier (`FakePackBackend`, `@available(macOS 26, *)` on each test function, never on a suite, AAV §3 #21)
- `R-APL-1: the Apple source satisfies RemoteSource end to end against a fake PackBackend`
- `R-APL-1: constructing the Apple source and selecting the tier call no pack API`
- `R-APL-1: concurrent fetches of assets in one pack trigger one ensureAvailable`
- `R-APL-2: pack download progress reaches the engine as byte values scaled to the asset size`
- `R-APL-2: undocumented pack errors map to transient and never to integrity`
- `R-APL-2: an asset whose pack bytes do not match the catalog checksum fails integrity and triggers one update check`
- `R-APL-3: an adopted asset is served from blobs and never from a pack location`
- `R-APL-4: the catalog is read from the essential pack and its digest is the ETag`
- `R-APL-4: an unchanged catalog yields notModified`
- `R-APL-4: a failing update check still returns the installed catalog, marked not update-checked`
- `R-APL-4: a missing catalog pack while offline reports offline and leaves the applied manifest in force` (with the engine)
- `R-APL-4: packs removed by the update check are reported to the engine`
- `R-APL-5: tier selection is correct for all 16 input combinations`
- `R-APL-5: the awsOnly kill switch selects AWS on an OS that supports the Apple tier`
- `R-APL-5: the package contains exactly one #available` (source scan)
- `R-CLN-10: a media pack is released only after every catalog entry in it is adopted`
- `R-CLN-10: the catalog pack is never released`
- `R-CLN-10: retention keepPacks never releases`
- `R-CLN-10: a pack that comes back after release is released at most once per catalog generation`

### 16.7 SPEC §7.3 network scenarios: where each lives

| Scenario | Transport test (above) | Engine / facade test (owner) |
|---|---|---|
| 403 circuit breaker | `R-NET-6: a 403 is reported as forbiddenAmbiguous…` | `R-SYN-5: ambiguous 403s on three distinct assets open the auth breaker and stop requests to the loopback server` (WP-F/G) |
| 429 with `Retry-After` | `R-NET-6: Retry-After parses…`; E-8 route | `R-SYN-5: no transfer starts before a 429's Retry-After elapses on ManualTimeSource` (sync.md) |
| 5xx backoff on `ManualTimeSource` | 5xx row of §3.4.1 | `R-SYN-5: sustained 503s back off with full jitter and open the 5xx breaker` (sync.md) |
| offline → online | `R-NET-9: the live conditions source…`; −1009 row | `R-SYN-13: an offline failure is retried on a path-satisfied edge without polling` (sync.md) |
| redirect to another host strips the key | `R-NET-4: a cross-host redirect…` | — |
| manifest 304 | `R-NET-5: a manifest fetch sends If-None-Match…` | — |
| gzip, decoded ≠ `Content-Length` | `R-NET-7: a gzip response…` | — |
| announced size over the cap | `R-NET-7: an announced size over maxAssetBytes…` | — |
| truncated body | `R-NET-7: a close-delimited body…` + `…shorter than its Content-Length…` | — |
| connection reset mid-download with resume | `R-NET-8: a connection dropped mid-download resumes…` | `R-NET-8: resumed bytes from a lying server never reach blobs/` (Kit, real store) |

### 16.8 Benchmarks
- `P-10: 500 small assets over a loopback server use at most connections_max TCP connections`
- `P-11: assets with server latency sync at least speedup_min times faster at the configured concurrency than at 1`

### 16.9 Coverage plan
Transport: everything except `BackgroundSessionBackend.swift` runs on macOS: the loopback server covers the backend, delegate, handle and security; pure tests cover the classifier, parser, guard, quantiser and tag; the fake driver covers the coordinator and relay; one live run plus pure mapping covers conditions. `urlSessionDidFinishEvents` and the background-mode branches are covered by calling the delegate through a foreground session in `.background` mode (behavioural, with event assertions). AppleHosted: everything except `LiveAssetPackBackend.swift`, through `FakePackBackend`. The two excluded files total 178 physical lines in the prototype. Keep them minimal: the 3 % cap is measured on executable lines across the whole package.

### 16.10 Mutation probes this plan kills (Q-8)
Keep the key on a cross-host redirect → `R-NET-4: a cross-host redirect…`. Put the key in `httpAdditionalHeaders` → `R-NET-4: the foreground session configuration…`. Treat 403 as transient → `R-NET-6: a 403 is reported…` (and sync's R-SYN-5). Skip the hash for resumed bytes → `R-NET-8: resumed bytes from a lying server…`. Compare `Content-Length` instead of the staged size → `R-NET-7: a gzip response…`. Drop the streaming cap → `R-NET-5: a manifest over 32 MiB…`. Ignore `Retry-After` → `R-NET-6: Retry-After…` + `R-SYN-5`. Remove the post-hoc background origin check → `R-NET-4: a background-mode delegate…`. Run staging GC before reconciliation → `R-NET-3: staging GC runs after reconciliation…`.

---

## 17. Evidence and reproduction

All paths are relative to `.build-probe-transport/` (git-ignored). The commands run through the Bash tool with the sandbox disabled, as the brief requires.

| ID | Command | Result | Output |
|---|---|---|---|
| build | `cd pkg && swift build -c release --scratch-path ../scratch -Xswiftc -warnings-as-errors` (after `rm -rf ../scratch`) | exit 0, **0 errors, 0 warnings**, `Build complete!`, at the macOS 12 floor, Swift 6 | `out/build-macos12-release.txt` |
| TC-1 | `bash typecheck.sh`: `xcrun --sdk {iphoneos,macosx} swiftc -target {arm64-apple-ios15.0, arm64-apple-macos12.0} -swift-version 6 -warnings-as-errors -package-name ztron -enable-experimental-feature StrictConcurrency=complete -parse-as-library`. Emits the `TransportProto` module, then type-checks `LoopbackProto` and `AppleProto` against it. | `ios15: exits=3/3 errors=0 warnings=0`; `macos12: exits=3/3 errors=0 warnings=0` | `out/typecheck.{ios15,macos12}.txt` |
| NEG-1/2 | `swiftc -typecheck … neg/{mutable_mailbox,nonsendable_delegate}.swift` (both floors) | NEG-1 error, exit 1; NEG-2 warning, which is an error under `-warnings-as-errors` | `out/mutable_mailbox.*.txt`, `out/nonsendable_delegate.*.txt` |
| CAP-0/1 | `swiftc -typecheck … cap/capture_token.swift` and `cap/capture_monitor.swift` (both floors; CAP-1 also with `-warnings-as-errors`) | CAP-0 (observer token captured): error, exit 1; CAP-1 (`NWPathMonitor` captured): exit 0, no diagnostic | `out/capture_token.*.txt`, `out/capture_monitor.*.txt` |
| unsafe | `grep -rcE '<the 9 unsafe regexes of quality-gates.json>' pkg/Sources` | **0** | — |
| E-1…E-18 | `./scratch/out/Products/Release/Experiments "$PWD/run" [E-n,…]` | 69 result lines, `DONE`, exit 0 | `out/experiments-final.txt` (full run), `out/experiments*.txt` (earlier runs, including the defects found and fixed) |
| E-19 | `cd testpkg && swift test --scratch-path ../scratch-testpkg -Xswiftc -warnings-as-errors` (the loopback server inside the Swift Testing runner) | `✔ … passed`; 50/50 GETs, 1 TCP connection | `out/swifttest-loopback.txt` |
| E-20 | `cd testpkg && swift test --scratch-path ../scratch-testpkg-tsan --sanitize=thread` (the transport prototype plus the server) | 2 tests passed; 0 `ThreadSanitizer` reports | `out/swifttest-transport-tsan.txt`, `out/swifttest-loopback-tsan.txt` |

**Defects in my own prototype that the experiments caught** (each now in the test plan): (1) `URLRequest.timeoutInterval` silently overrode the session timeout (E-16, 30 s); (2) consumer cancellation reported `incompleteCallbackSequence` (E-10); (3) the IMF-fixdate month was off by one (E-8 first run); (4) background progress shared the bounded lifecycle stream (§4.4); (5) `NSURLErrorNetworkUnavailableReason` and the completion-handler `cancel(byProducingResumeData:)` in async code did not compile under `-warnings-as-errors` (S-8, S-10).

**Not verified in this session** (goes to `docs/VERIFICATION.md` and `DEVICE-TEST-PLAN.md`): relaunch re-attachment of a real background session (H-6), and whether the OS redelivers `didFinishDownloadingTo` after a crash (F-2); whether a foreground session accepts resume data from a background task (§10.8); Apple-hosted packs end to end (ensure, read, remove; whether released packs come back; cloning from the pack store; cancelling `ensureLocalAvailability`); real Wi-Fi/cellular/Low Data/Low Power transitions; HTTP/2 behaviour against CloudFront (only HTTP/1.1 loopback was measured); ATS behaviour of a loopback URL inside an iOS app (no production relevance); any iOS 15 *runtime* behaviour (compile-time only).

---

## 18. Proposed ADRs (text for Phase C; this drafter did not edit `DECISIONS.md`)

- **ADR-T1 Background transfers are opt-in and never carry the app key by default (H-6, R-NET-3 vs R-NET-4)**: §10.2. **NEEDS-HUMAN-REVIEW.** Ask: may key-bearing bulk transfers use a background session whose redirects cannot be controlled?
- **ADR-T2 Apple tier: adopt-and-release, default `releaseAfterAdoption` (H-7, R-APL-3, R-CLN-10)**: §11.4. **NEEDS-HUMAN-REVIEW** (default retention, and the whole-pack re-download cost on eviction).
- **ADR-T3 Stateless delegate with per-task mailbox; deterministic staging names `<TransferID>.part\|.resume`**: §4.2, §4.3, X-T5. **NEEDS-HUMAN-REVIEW** (on-disk layout deviation from SPEC §4.3).
- **ADR-T4 Resume data persisted in `staging/` although it embeds the app key**: §5.4. **NEEDS-HUMAN-REVIEW** (security).
- **ADR-T5 `TransferHandle` with synchronous controls instead of a control stream**: X-T1 (Phase C with sync).
- **ADR-T6 Download tasks for the manifest; an ephemeral, cache-less session; the cap enforced while streaming**: §6.
- **ADR-T7 Apple tier limited to the 26.0 API surface, so there is a single `#available` (R-APL-5)**: §11.5.
- **ADR-T8 The test "connection reset" scenario uses FIN truncation; RST is documented as non-deterministic**: §12, E-16.

## 19. Open risks

| # | Risk | Mitigation / ask |
|---|---|---|
| RK-1 | R-NET-3 is effectively inert in production until the owner accepts ADR-T1. | Owner decision; the code and tests exist either way. |
| RK-2 | Store launch GC (store.md §2.6 step 7d) would delete H-6 adoptable `.part` files. | X-T6, Phase C. |
| RK-3 | Deterministic staging names conflict with store.md's UUID reservations. | X-T5, Phase C, with a layout ADR. |
| RK-4 | P-11 is safe at the transport level (5.2–5.6×), but the engine's final-commit tail could push it under 3×. | The engine flushes the last group commit as soon as the P-5 window allows; measure early in Stage 2. |
| RK-5 | Q-1 gap: unenforced `Sendable` markers (`NWPathMonitor`, `NWListener`, `NWConnection`) give no diagnostic at the floor, so the compiler proves less than it seems to. | Actor ownership in production code; test-only use in the server. |
| RK-6 | Device-only cap (3 % of package lines): the two excluded files are 178 physical lines in the prototype. | Keep them thin; WP-D/E report their executable-line counts. |
| RK-7 | `.timeLimit` needs macOS 13 at a macOS 12 floor (AAV §3.2). | Orchestrator ruling: `@available` per test function, or a macOS 13 test floor. |
| RK-8 | Resume data from a background session in a foreground session is unverified. | §7.2 rule 3 restarts fresh, so correctness does not depend on it. |
| RK-9 | Undocumented BackgroundAssets error types (AAV §1.8). | Defensive mapping to transient, never integrity; device test plan. |
