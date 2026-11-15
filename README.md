# ZTronAssetKit

ZTronAssetKit puts an app's remote media (images, SVG, video, audio) on the device and owns every byte it stores
there. This page describes the package from the outside: what it is for, what each module offers, how a SwiftUI app
adopts it, and what is known to be wrong or unproven. How it works inside is in [HANDBOOK.md](HANDBOOK.md) (the
integrator's guide) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Intent

ZTronCarousel shows pages of media that are published to a CDN, not shipped in the app. The package replaces the
`CDN/` code of ZTronCarouselCore with one component that takes the whole job, so that a page never waits on, or
breaks because of, how its file got to the device.

| You give it | It gives you | It owns |
|---|---|---|
| An origin: a CloudFront distribution with a `manifest.json` and an app key, and optionally Apple-hosted asset packs (iOS 26 or later) | A file URL for an asset identifier: at once when the file is bundled or stored, after a download otherwise | One directory, `<Application Support>/ZTronAssetKit/v1/` by default, and every file in it |
| What to keep, as a value: everything, a set of identifiers, tags, or an identifier prefix | State a view can render: launch phase, sync progress and outcome, network and power conditions | The schedule: when to sync, what to download first, when to retry, what to evict |
| The pages around the one on screen | Typed errors a UI can switch over (`AssetError`, nine cases) and a stream of events | Integrity: every stored file was hashed against the manifest's SHA-256 when it was written |

What it promises, in the terms a caller can observe:

- **The page on screen comes first.** Work runs in three lanes, user-initiated above prefetch above bulk sync, so a
  page the user opens overtakes a sync that is already downloading.
- **One download per content**, however many callers wait for it, and a caller that gives up cancels only itself.
- **A process kill or power loss at any point leaves a state the next launch reconciles.** Files are immutable and
  named by their hash, and the index is replaced atomically.
- **Storage is bounded.** A byte budget (half of the store's usage plus the free space by default), a 256 MiB
  reserve of free space, least-recently-used eviction, and a purge the user can trigger.
- **Looking a file up never blocks the main thread**: no I/O, O(1).
- **No secret leaves through logs, errors, reports or reflection**, and the app key is sent only to allow-listed
  HTTPS origins.

What it is not: an image decoder or a view library; the infrastructure that publishes the catalog; paywall logic (an
app maps its own to the "what to keep" value); or the app-side setup of Apple-hosted packs (the downloader extension,
its Info.plist keys and the App Group stay with the app).

| | |
|---|---|
| Platforms | iOS 15.0 and macOS 12.0. The Apple-hosted tier runs on iOS 26 or macOS 26 and later. |
| Toolchain | Swift 6.3 or newer to build and test; Swift 6 language mode with complete strict concurrency. |
| Dependencies | None beyond Apple's SDKs and the Swift toolchain. |
| Product | One library, `ZTronAssetKit`, with two importable modules: `ZTronAssetKit` (the core) and `ZTronAssetSwiftUI` (the SwiftUI facade over it). |

## Quick adoption (SwiftUI)

Add the package and link its one product:

```swift
// Package.swift of the app or package that uses it
dependencies: [
    .package(path: "../ZTronAssetKit"),
],
targets: [
    .target(name: "MyFeature", dependencies: [.product(name: "ZTronAssetKit", package: "ZTronAssetKit")]),
]
```

In an Xcode app project, add the package and link the `ZTronAssetKit` product to the app target.

Then describe one library by chaining calls, inject it at the root view, and ask it for files:

<!-- quick-adoption:begin -->
```swift
import SwiftUI
import ZTronAssetSwiftUI

@main
struct CarouselApp: App {
    // One library for the app's lifetime, described by a chain; nothing is opened until `start()`.
    @StateObject private var assets = AssetLibrary
        .origin(URL(string: "https://assets.example.com/")!)   // the CloudFront distribution
        .appKey("PLACEHOLDER-APP-KEY")                          // from secure configuration; never logged
        .retain(.tags(["free"]))                                // what a sync keeps on the device
        .refresh(.atMostEvery(24 * 60 * 60))                    // at most one launch sync a day
        .bundled(.image)                                        // images also ship in the app bundle
        .library()

    var body: some Scene {
        WindowGroup {
            CarouselPage(id: "page-1")
                .environmentObject(self.assets)
                .task { await self.assets.start() }             // opens the store, launches the due sync
        }
    }
}

struct CarouselPage: View {
    @EnvironmentObject private var assets: AssetLibrary
    let id: AssetID
    @State private var file: Result<URL, AssetError>?

    var body: some View {
        VStack {
            switch self.file {
            case .success(let url)?: AsyncImage(url: url)
            case .failure(let error)?: Text("Unavailable: \(String(describing: error))")
            case nil: ProgressView()
            }
            if case .running(let progress?) = self.assets.syncActivity {
                ProgressView(value: progress.fraction)          // published state: the sync in flight
            }
        }
        .task(id: self.id) {
            self.file = nil
            let file: Result<URL, AssetError>
            do throws(AssetError) {
                // Bundle, then local store, then network; the page on screen overtakes any sync.
                file = .success(try await self.assets.url(for: self.id, kind: .image))
            } catch {
                file = .failure(error)
            }
            if !Task.isCancelled {
                self.file = file                                // a page that moved on keeps its own state
            }
        }
    }
}
```
<!-- quick-adoption:end -->

This snippet is compiled with the package's tests, under Swift 6 and warnings as errors, and a test fails when the
two copies differ ([`QuickAdoption.swift`](Tests/ZTronAssetSwiftUITests/QuickAdoption.swift)). It has not been run
inside an app.

What to know before pasting it:

- **Create one library and keep it.** A store location admits one client at a time: a second library, process or
  extension on the same location fails to start, with `phase == .failed(.storageUnavailable(.locked))`. Releasing
  the library shuts its client down.
- **`start()` does not throw.** It publishes `.ready`, or the failure, in `phase`. It returns when the store is open,
  not when a sync has finished. Any asynchronous call starts the library too, so a view may ask for a file before
  the root view's task ran.
- **A store that could not be opened stays failed for that library.** The client never opens a store twice, so
  calling `start()` again answers the same failure. Recovering, for example once the other holder of a locked
  store is gone, takes a new library; a `@StateObject` cannot be replaced, so an app that must recover keeps the
  library in an object of its own.
- **The published state does not say that a file arrived.** `phase`, `conditions` and `syncActivity` describe the
  library; `generation` is assigned when the catalog changed (a manifest was applied, a purge ran), not when one
  asset landed. A view that shows a file awaits `url(for:kind:)` in a `.task` and keeps the answer in its own
  state, as the snippet does. `lookup` and `locate` answer what is on the device at that instant, and can miss an
  asset for a moment after it was answered.
- **Use the URL you were handed, soon.** A URL stays readable for at least the deletion grace (10 s of awake time by
  default) after a snapshot without the asset was installed. A video player holds a lease with `withAsset(_:_:)`
  for as long as it plays.
- **The key in the example is a placeholder.** The chain wraps the string in `AppKey`, which prints as
  `AppKey(<redacted>)` and cannot be read back; where the string comes from is the app's concern.
- **For a carousel**, call `updatePrefetchWindow(ids:current:)` on every page change: the current page is fetched at
  user-initiated priority, its neighbours are prefetched, and what left the window is cancelled.

An app that does not use SwiftUI, or wants full control, uses `AssetClient` from `import ZTronAssetKit` instead; its
quick start is in [HANDBOOK.md](HANDBOOK.md).

## Public API by module

The package has eight modules. Two are importable by an app, one is re-exported by both, and five exist for the
package's own layering and tests. `public` in the last five means "visible to the package's other modules", not
"supported for apps": only the product's two modules and the model they re-export are API.

| Module | Importable by an app | Role |
|---|---|---|
| [`ZTronAssetSwiftUI`](#ztronassetswiftui-the-swiftui-facade) | yes | `AssetLibrary`, an `ObservableObject` over the core, and the chain that creates it |
| [`ZTronAssetKit`](#ztronassetkit-the-core-facade) | yes | `AssetClient`, the fallback chain, prefetch, diagnostics, the live environment |
| [`ZTronAssetModel`](#ztronassetmodel-values-errors-events-and-seams) | re-exported by the two above | Values, errors, events, policies and the protocols behind which the real world is injected |
| [`ZTronAssetStorage`](#modules-that-are-not-app-api) | no | The store: files, index, integrity, cleanup, eviction, migration |
| [`ZTronAssetTransport`](#modules-that-are-not-app-api) | no | URLSession transfers, redirect and key safety, reachability |
| [`ZTronAssetAppleHosted`](#modules-that-are-not-app-api) | no | The Apple-hosted tier over BackgroundAssets |
| [`ZTronAssetSync`](#modules-that-are-not-app-api) | no | The planner and the sync engine |
| [`ZTronAssetTestSupport`](#modules-that-are-not-app-api) | no (not in the product) | Fakes for the package's tests |

### `ZTronAssetSwiftUI`: the SwiftUI facade

`import ZTronAssetSwiftUI` also exports `ZTronAssetKit` and `ZTronAssetModel`, so a SwiftUI app imports one module.
No call of the facade takes an options or configuration value: a library is described by a chain of calls. Its
`client` property is the way out to the core, whose `AssetClient` does have one.

**Creating a library.** A chain starts at `AssetLibrary.origin(_:)` or `AssetLibrary.appleHosted()`, each step returns
a new stage (`AssetLibrary.Setup`), and `library()` ends it. Steps are independent of their order, a later step for
the same knob wins, and a step left out keeps the package's default. A key-path step sets one knob and takes that
knob's value only (`AssetLibrarySetting`: a flag, a number, a string, a URL or a choice between cases), so a whole
policy value cannot be passed through it; a knob of a nested policy is reached by a longer key path,
`.tuning(\.retry.maxDelay, 60)`. The HTTP steps describe the origin's tier and have no effect on a chain without an
origin.

| Step | What it sets | Default |
|---|---|---|
| `origin(_ baseURL:)` | The CloudFront distribution, `https://<distribution>/` | none: a chain names an origin, the Apple tier, or both |
| `appKey(_ secret:)` | The app key the origin requires | no key |
| `manifest(at:)` | The manifest's path relative to the origin | `manifest.json` |
| `http(_ keyPath:, _ value:)` | Any other knob of the HTTP tier: `.http(\.requestTimeout, 20)` | `HTTPSourceConfiguration`'s |
| `backgroundTransfers()`, `backgroundTransfers(_ keyPath:, _ value:)` | Bulk transfers may use a background `URLSession`; the app attests it forwards the background-events hook | off |
| `appleHosted()`, `appleHosted(_ keyPath:, _ value:)` | Adds the Apple-hosted tier for iOS 26 and later | off |
| `awsOnly(_:)` | Kill switch: never select the Apple-hosted tier | off |
| `store(in:)` | Where the store lives: `.applicationSupport`, `.caches`, `.custom(URL)` | `.applicationSupport` |
| `budget(_:)` | The byte budget: `.unlimited`, `.bytes`, `.fractionOfFreeSpace` | `.fractionOfFreeSpace(0.5)` |
| `storage(_ keyPath:, _ value:)` | Any other storage knob: `.storage(\.deletionGrace, 30)` | `StoragePolicy`'s |
| `legacy(_ keyPath:, _ value:)` | Migration from the prior art's cache: `.legacy(\.enabled, false)` | enabled |
| `refresh(_:)` | When a launch sync is due | `.oncePerAppVersion` |
| `retain(_:)` | What to keep, at launch | `.all` |
| `network(_ keyPath:, _ value:)`, `power(_ keyPath:, _ value:)` | Which lanes run on cellular, in Low Data Mode, in Low Power Mode, under thermal pressure | `NetworkPolicy`'s, `PowerPolicy`'s |
| `tuning(_ keyPath:, _ value:)`, `limits(_ keyPath:, _ value:)` | Concurrency, retries, circuit breaker; the limits a manifest is held to | `SyncTuning`'s, `ManifestLimits`'s |
| `prefetchRadius(_:)` | Neighbours kept warm on each side of the current page | 2 |
| `bundled(_ kinds:...)` | Media kinds shipped in the app bundle, indexed by `start()` | none; a kind is indexed when first asked for |
| `bundle(_:)` | The bundle lookup behind the fallback chain | `Bundle.main` |
| `memoryPressure(from:)` | The app's memory-warning source, without which registered caches are never purged | none |
| `library()` | Ends the chain: creates the client and the library; no I/O | |

`AssetLibrary(client:)` wraps a client the app built itself, for example with its own `AssetEnvironment`.

**State a view observes** (`@Published`, read-only):

| Property | Type | Meaning |
|---|---|---|
| `phase` | `AssetLibrary.Phase` | `.idle`, `.starting`, `.ready`, `.failed(AssetError)`, `.shutDown` |
| `generation` | `UInt64?` | The store's index generation; assigned when the catalog changed (a manifest applied, a purge, a reopened store), not when one asset arrives |
| `conditions` | `DeviceConditions?` | Network and power state as the client last read it (see [risks](#known-risks-and-defects)) |
| `syncActivity` | `AssetLibrary.SyncActivity` | `.idle`, `.running(SyncProgress?)`, `.finished(SyncOutcome)` |

**Calls.** Each forwards to the core; the asynchronous ones throw `AssetError` unless noted.

| Call | Answers | Notes |
|---|---|---|
| `start()` | | Opens the store, launches the due sync; publishes its result in `phase`. A store that failed to open stays failed for this library |
| `shutdown()` | | Cancels everything, flushes the index; every call that needs the store fails with `.shutDown` afterwards |
| `lookup(_:extensions:)` | `AssetLocation?` | Synchronous, no I/O: the stored file, if any |
| `locate(_:kind:)` | `ChainHit?` | Synchronous, no I/O: the bundled file, else the stored one |
| `url(for:kind:)` | `URL` | Bundle, then store, then network at user-initiated priority |
| `resolve(_:priority:)` | `URL` | The network step alone; answers a stored asset without a transfer |
| `withAsset(_:_:)` | the body's value | Runs the body while a lease keeps the file from eviction and purge; rethrows the body's error |
| `prefetch(_:priority:)` | `PrefetchHandle` | Keeps assets warm until the handle is cancelled or released |
| `updatePrefetchWindow(ids:current:)`, `cancelPrefetchWindow()` | | The carousel's window around the current page |
| `pin(_:)`, `unpin(_:)` | | Pinned assets are never evicted; a purge still removes them |
| `reportUnreadable(_:)` | | Quarantines a file the UI could not decode and downloads it again |
| `sync(_:)` | `SyncOutcome` | `.ifDue` or `.force`; reports failures in its outcome instead of throwing |
| `isSyncDue()`, `lastSyncedAt()` | `Bool`, `Date?` | The sync stamp |
| `availability(scope:)` | `AvailabilityReport` | Present, missing, stale, failed, unverified; no network |
| `ensureAvailable(scope:)` | `AvailabilityReport` | Downloads what is missing in the scope, now |
| `setRetentionScope(_:)` | | Replaces what to keep; deletes and fetches nothing by itself |
| `storageReport()` | `StorageReport` | Bytes by kind and state, pinned, evictable, free space |
| `purge(_:)` | `PurgeResult` | `.all`, `.evictable` or `.scope`; returns after the deletion grace |
| `performMaintenance(timeBudget:)` | `MaintenanceReport` | Garbage collection, eviction and deep verification, for a background task |
| `metrics()`, `diagnosticReport()` | `MetricsSnapshot`, `Data` | Counters; JSON for support, without secrets |
| `events`, `subscribe()` | `AsyncStream<AssetEvent>` | Every client event, including the per-asset ones the published state leaves out |
| `register(_:)`, `unregister(_:)` | | A derived in-memory cache to purge on memory pressure |
| `handleBackgroundEvents(identifier:completionHandler:)` | `Bool` | The app delegate's background-session hook; an accepted call starts the library |
| `client` | `AssetClient` | The core client, for everything this facade does not repeat |

### `ZTronAssetKit`: the core facade

No UIKit, SwiftUI or Combine. `import ZTronAssetKit` also exports `ZTronAssetModel`.

| Type | Kind | What it offers |
|---|---|---|
| `AssetClient` | final class, `Sendable` | The facade the table below lists |
| `AssetClientConfiguration` | struct | Everything a client is configured with: `remote`, `location`, `storage`, `legacy`, `network`, `power`, `refresh`, `tuning`, `limits`, `prefetchRadius`, `retentionScope` |
| `AssetFallbackChain` | struct | Bundle, then local, then network: `prepare(kinds:)`, `locate(_:kind:)`, `fetch(_:kind:)` |
| `AssetKind` | enum | `.image`, `.svg`, `.video(fileExtension:)`, `.audio`, each with its candidate extensions |
| `ChainHit` | enum | Where the chain found an asset: `.bundle(URL)` or `.local(AssetLocation)` |
| `BundleLookup`, `MainBundleLookup`, `BundleResourceKey` | protocol, struct, struct | The bundle step and its live conformer over `Bundle.main` |
| `PrefetchHandle` | final class | A prefetch registration: `awaitRegistration()`, `cancel()`; released on deinit |
| `PrefetchWindow`, `PrefetchWindowController` | enum, final class | The pure window (`targets(ids:current:radius:)`) and the controller that keeps it prefetched (`update(ids:current:)`, `cancelAll()`) |
| `DiagnosticReport` | struct | The decoded shape of `diagnosticReport()` |
| `AssetEnvironment.live(legacyDefaultsSuiteName:)` | static function | The real world: file system, clocks, network, reachability, logging |
| `LiveRemoteSourceFactory`, `LiveAppVersionSource` | structs | The live tier selection and app-version reader that environment uses |

`AssetClient(configuration:environment:)` performs no I/O. Its calls:

| Call | Answers |
|---|---|
| `start()`, `shutdown()` | Lifecycle; `start()` is idempotent and every asynchronous call awaits it |
| `lookup(_:extensions:)` | `AssetLocation?`, on the main actor, no I/O |
| `resolve(_:priority:)` | `URL` |
| `prefetch(_:priority:)` | `PrefetchHandle` |
| `withAsset(_:_:)` | The body's value, under a lease |
| `availability(scope:)`, `ensureAvailable(scope:)` | `AvailabilityReport` |
| `sync(_:)`, `isSyncDue()`, `lastSyncedAt()` | `SyncOutcome`, `Bool`, `Date?` |
| `setRetentionScope(_:)`, `pin(_:)`, `unpin(_:)` | |
| `storageReport()`, `purge(_:)`, `performMaintenance(timeBudget:)` | `StorageReport`, `PurgeResult`, `MaintenanceReport` |
| `reportUnreadable(_:)` | |
| `metrics()`, `diagnosticReport()` | `MetricsSnapshot`, `Data` |
| `events`, `subscribe()` | `AsyncStream<AssetEvent>` |
| `register(_:)`, `unregister(_:)` | Purgeable caches, on the main actor |
| `handleBackgroundEvents(identifier:completionHandler:)` | `Bool`, on the main actor |
| `configuration` | The configuration it was created with |

### `ZTronAssetModel`: values, errors, events and seams

Every type an app passes to or receives from the two facades, and the protocols behind the package's seams.

| Area | Public types | What they are |
|---|---|---|
| Identity | `AssetID`, `AssetFileExtension`, `ContentHash`, `StableHash`, `TransferID`, `TransferAttempt`, `StagingFileName` | An asset's identifier, a file's SHA-256, and the names derived from them |
| What to keep and when | `AssetScope`, `AssetPriority`, `PrefetchTarget`, `RefreshPolicy`, `SyncMode` | The scope value (all, identifiers, tags, prefix), the three lanes, when a sync is due |
| Remote | `RemoteConfiguration`, `HTTPSourceConfiguration`, `AppKey`, `BackgroundTransferPolicy`, `BackgroundTransferOptions`, `KeyRedirectExposure`, `AppleTierConfiguration`, `PackRetention`, `AssetTier`, `TierInputs`, `TierSelection`, `TierUnavailable` | The two tiers, the redacting key wrapper, and the pure tier decision |
| Storage policy | `StorageLocation`, `StorageBudget`, `StoragePolicy`, `LegacyMigrationPolicy` | Where the store lives, its budget and grace windows, the prior-art cache to migrate |
| Device policy and tuning | `NetworkPolicy`, `PowerPolicy`, `SyncTuning`, `RetryPolicy`, `CircuitBreakerPolicy` | Which lanes run under which conditions; concurrency, retries, breaker |
| Manifest | `ManifestEntry`, `AssetPolicy`, `ContentIdentity`, `ValidatedManifest`, `ManifestDecoder`, `ManifestDecodingOptions`, `ManifestLimits`, `ManifestWireShape`, `ManifestDiff`, `ManifestChange`, `ManifestError`, `ManifestUndecodableReason`, `ManifestEntryViolation`, `RemotePathViolation`, `QuarantinedEntry` | The catalog: decoding untrusted JSON under limits, validation with per-entry quarantine, diffing |
| Answers | `AssetLocation`, `AssetIntegrity`, `AvailabilityReport`, `StorageReport`, `ResidencyBytes`, `PurgeRequest`, `PurgeResult`, `SyncOutcome`, `SyncReport`, `PlanTotals`, `AssetFailure`, `SyncStamp`, `MetricsSnapshot`, `FailureClass`, `FailureCounts`, `DiagnosticError` | What the facades return |
| Errors | `AssetError`, `AuthRejection`, `StorageUnavailableReason`; internally `TransferError`, `OfflineReason`, `TransientCause`, `RetryAfter`, `AuthenticationFailure`, `ForbiddenEvidence`, `ForbiddenHint`, `TransferIntegrityFailure`, `PolicyViolation`, `RedirectRefusal`, `CancellationCause`, `SystemCancellationReason` | The closed error every public call throws, and the richer transfer taxonomy it is mapped from |
| Events | `AssetEvent`, `SyncRunID`, `SyncTrigger`, `SyncProgress`, `TransferProgress`, `RemovalReason`, `MaintenanceReport`, `RetryDisposition`, `PolicyBlock`, `BlockReason`, `BreakerCause`, `CircuitState` | Everything a subscriber sees |
| Environment seams | `AssetEnvironment`, `FileSystem` (with `FileItemKind`, `FileIdentity`, `FileItemInfo`, `SyncLevel`, `WriteMode`, `RenameMode`, `StandardDirectory`, `CapacityPurpose`, `ProtectionClass`, `StoreAttributes`, `FileLockToken`, `FileSystemError`), `BlockingExecutor`, `DispatchBlockingExecutor`, `TimeSource`, `LiveTimeSource`, `MonotonicInstant`, `RandomSource`, `SystemRandomSource`, `SplitMix64`, `KeyedRandom`, `DeviceConditionsSource`, `DeviceConditions`, `NetworkConditions`, `PowerConditions`, `ThermalLevel`, `AppVersionSource`, `LegacyDefaults`, `MemoryPressureSource`, `MemoryPressureLevel`, `PurgeableCache` | The protocols and values through which time, randomness, the file system, reachability and power are injected, so tests replace them |
| Logging | `AssetLog`, `LogSink`, `OSLogSink`, `TapOnlyLogSink`, `LogRoute`, `LogTap`, `LogLine`, `LogCategory`, `LogLevel`, `LogInterval`, `LogIntervalName`, `LogIntervalEvent` | Subsystem `com.ztron.assetkit`; identifiers are hashed in every line |
| Transfer contracts | `RemoteSource`, `RemoteSourceFactory`, `RemoteSourceCapabilities`, `TransferBackend`, `TransferBackendKind`, `TransferJob`, `TransferRequest`, `TransferHandle`, `TransferUpdate`, `TransferControl`, `TransferPurpose`, `TransferRoute`, `NetworkAccess`, `StagingSink`, `StagedFile`, `StagingError`, `ChunkSource`, `SourceFailure`, `ResumePoint`, `ResumeValidator`, `ResumeSidecar`, `ResumeData`, `LiveTransfer`, `ReattachedTransfer`, `AdoptionReport`, `ReclaimReport`, `ETag`, `ManifestRequest`, `ManifestOrigin`, `ManifestPayload`, `ManifestFetchResult` | The protocols the engine speaks to a tier through; an app meets them only if it writes its own source |

### Modules that are not app API

| Module | Top-level public types | Why they are public |
|---|---|---|
| `ZTronAssetStorage` | `LiveFileSystem`, `LiveLegacyDefaults` | The live conformers the composition root names; the store itself (`AssetStore`) is package-internal |
| `ZTronAssetTransport` | `HTTPRemoteSource`, `ForegroundTransferBackend`, `SessionDelegate`, `SessionMode`, `SessionEvent`, `TaskMailbox`, `BackgroundSessionDriver`, `LiveBackgroundSessionDriver`, `BackgroundSessionIdentifier`, `BackgroundTaskSnapshot`, `BackgroundEventsRelay`, `TransportSecurityPolicy`, `RedirectPolicy`, `PlaintextPermission`, `Origin`, `TransferClassifier`, `ResponseFacts`, `RetryAfterParser`, `SizeGuard`, `SizeVerdict`, `LiveDeviceConditionsSource`, `ConditionsMapping` | The HTTP tier, its sessions, its security policy and classification, and reachability, composed by `ZTronAssetKit` |
| `ZTronAssetAppleHosted` | `AppleHostedRemoteSource`, `AppleHostedTier`, `PackBackend`, `LiveAssetPackBackend`, `PackID`, `PackLocation`, `PackProgress`, `PackUpdateCheck`, `PackError`, `PackFileReader`, `PackReleasePlanner` | The Apple-hosted tier and the seam over BackgroundAssets, composed by `ZTronAssetKit` |
| `ZTronAssetSync` | none | The engine and planner are visible to the package only |
| `ZTronAssetTestSupport` | 45, among them `FakeFileSystem`, `FakeRemoteSource`, `ManualTimeSource`, `SeededRandom`, `FakeDeviceConditionsSource`, `FakeMemoryPressureSource`, `InlineBlockingExecutor`, `SteppedBlockingExecutor`, `LoopbackHTTPServer`, `RecordingLogTap`, `GeneratedPayload` | Fakes with crash points and fault injection; not part of the product |

The prior art's CDN symbols (`CDNAsset`, `CDNLocalStore`, `CDNAssetResolver`, `CDNSyncCoordinator` and the rest)
exist as compatibility shims over `AssetClient` in
[`Tests/ZTronAssetCompatibilityTests/Shims/`](Tests/ZTronAssetCompatibilityTests/Shims/), a test target: they are
not in the product, and adopting them in ZTronCarouselCore is a step of [docs/MIGRATION.md](docs/MIGRATION.md).

## Known risks and defects

The full ledger is [docs/RESIDUAL-RISKS.md](docs/RESIDUAL-RISKS.md) (88 entries, `RES-nn` below), what was and was
not verified is [docs/VERIFICATION.md](docs/VERIFICATION.md), and what only a device can show is
[docs/DEVICE-TEST-PLAN.md](docs/DEVICE-TEST-PLAN.md). This is the part of them an adopter should read first. Every
figure is from the development Mac (Apple silicon); no device was measured.

### Defects: wrong or red today

| What | Effect on an app | Where |
|---|---|---|
| **The package's own Definition of Done does not pass.** `verify.sh --full` ends `VERIFY: FAIL (1 failed: benchmarks)`, with every other step passing. The owner accepted this end state. | None by itself; it is the two rows below. | VERIFICATION §4.1 and §7 |
| A purge over about 10,000 identifiers holds the sync engine for 17.82-64.00 ms in one turn, in six measured shapes, against a 10 ms limit. More purge shapes miss by estimate, the largest about half a second. | Calls into the library wait that long while such a purge runs. Nothing is lost or answered wrongly. | RES-01, RES-03, RES-04, RES-07 |
| Answering many waiters from the store at once holds the engine for 11.10-13.93 ms in one turn (measured by a probe, not a committed benchmark). | As above; it needs no purge. | RES-05 |
| Deleting 10,000 files: the 99th percentile of a deletion batch exceeds its 5 ms bound on about 30 % of runs, through stalled unlinks. | None on correctness; a thread is held for 7.9-13.6 ms at worst. | RES-02 |
| A request for an asset can be answered `notFound` although the store lists it, when it races the application of an older manifest that omits the asset. Not fixed and not ruled on: it waits for the owner. | A wrong answer for that request, which the caller cannot tell from a missing asset. | RES-15 |
| An asset whose file extension is not a candidate of the requested kind is downloaded at user-initiated priority, stored, and only then refused with `notFound`. `url(for:kind:)` inherits this. | One wasted download that preempts prefetch, for a catalog entry of the wrong kind. | RES-70 |
| With `allowUnverifiedAssets` off, an entry without a checksum is downloaded and then refused with `integrityFailure`. | One wasted download per such request. | RES-37 |
| `lookup` and `locate` can miss an asset for up to about 0.2 s after `resolve` or `url(for:kind:)` returned it. | Use the URL that was returned rather than looking the asset up again. | RES-88 |
| On a full disk, whether a request is answered `insufficientSpace` or served after a second attempt depends on the order of two internal events. | Both answers are legal; the user may see either. | RES-10 |

### Risks, with their trigger and standing

| Risk | Trigger | Standing | Where |
|---|---|---|---|
| Turns of 27-55 ms each after an outage (an estimate, not measured) | Thousands of transiently failed downloads retried at once | Open: no ruling | RES-08 |
| Production gate reads cost more than any benchmark shows (15-60 ms per 10,000, by estimate): the benchmarks' fake origin skips URL parsing | Every large engine turn, in production | Open: no ruling | RES-09 |
| A request waits about 0.15 s before it can start | A catalog change that moves about 10,000 entries | Accepted | RES-32 |
| Engine turns of about 40 ms | More than four holders of one asset (several groups that keep the same asset), or two event subscribers that both stall | Accepted: outside the 10 ms bar by the owner's ruling | RES-33 |
| Store turns of 18-41 ms; total time quadratic in the number of user-initiated downloads | Catalogs near the 100,000-entry limit; thousands of user-initiated downloads in one session | Accepted | RES-44, RES-45, RES-56 |
| An evicted asset whose content is still stored under another identifier is downloaded again | Eviction of content shared between entries | Recorded; a change request is pending | RES-46 |
| Orphaned bytes are never collected | A store that stays busy across every garbage-collection run | Recorded; a change request is pending | RES-47 |
| A store whose directory was deleted or replaced while the app runs is used until a failure or a commit detects it | The system purging a `.caches` store, or anything else replacing the directory | Accepted | RES-69 |
| A manifest whose entry array exceeds 2 MiB of unusually short entries is rejected; paths with empty or `.` segments, trailing slashes or backslashes are refused | Such a published manifest | Accepted | RES-79, RES-77 |
| Registered caches are never purged on a memory warning | No `memoryPressure(from:)` step (the UIKit source lives outside the package) | Accepted | RES-81 |
| An app that enables background transfers without forwarding the background-events hook is not detected | `backgroundTransfers()` without the app-delegate wiring | Accepted; device-only | RES-65 |
| A user request that joins a running background download keeps that download's priority | Background transfers | Accepted | RES-66 |
| In a background session the redirect hop limit and the size cap are checked only after the fact; with `keyRedirectExposure` set to `.acceptedByOwner` the app key can also reach a redirect target | Background transfers | Waits for the owner | ADR-026 |
| A store in an App Group container is unsupported unless the app shuts its library down whenever it is backgrounded and creates a new one when it returns: a lock held in a shared container while the app is suspended risks termination by the system | `store(in: .custom(_:))` pointing into a shared container | Documented limit | `StorageLocation.custom`; [HANDBOOK.md](HANDBOOK.md), "Configuration" |

### The SwiftUI facade: new, and what follows from that

`ZTronAssetSwiftUI` was added on 2026-11-15 ([ADR-058](docs/DECISIONS.md)). It adds no behaviour to the core, but it
is the least exercised part of the package:

- Its tests run a real client over a fake file system, clock and origin; what ran, and where, is in
  [docs/VERIFICATION.md](docs/VERIFICATION.md) §7. It has never run inside an app: its published state was observed
  through Combine, never through a rendered view, and the quick adoption snippet is compiled, not executed.
- It is the one production target that imports Combine. The requirement that forbade that (R-CAR-9) was amended on
  the owner's instruction; the other production targets still import no UI framework, and a test holds both halves.
- **A failed start is final.** A library whose store could not be opened (locked by another process, or unreadable
  before the first unlock) stays `.failed` for its lifetime, because the core client never opens a store twice.
  The facade does not rebuild its client; whether it should is a question for the owner (ADR-058).
- **The published state is not a file-arrival signal** (see the notes under the snippet): `generation` follows the
  catalog, not single assets.
- `conditions` is not a reachability monitor. The client observes the device only while it has work, so the value
  is the state during the last transfer or sync and can be old when nothing is in flight.
- `syncActivity` follows the client's events, so it settles a moment after `sync(_:)` returns its outcome.
- Every published change re-renders every view that observes the library. During a sync that is the progress, at
  most ten times a second, plus each catalog change.
- `purge(_:)` returns only when the bytes are reclaimed, which waits out the deletion grace (10 s by default).
- `client` reaches the core, including its configuration value, which the facade's own calls never take or return.

### Not verified

- **No test has run on a physical device.** 47 device tests are written down and none was run: background
  `URLSession` re-attachment after a relaunch, Apple-hosted packs through TestFlight, low storage, memory warnings,
  real network transitions, Low Power Mode and thermal states, performance, and the unified log.
- **iOS 15 at run time.** The floor is checked by the compiler; the simulator suite runs on a current iOS with test
  bundles built for iOS 17.
- **No app has adopted the package.** The adoption inside ZTronCarouselCore was never built, so the compatibility
  shims and the migration of the prior art's cache have run only against fixtures and fakes (RES-85).
- **The Apple-hosting setup.** None of the Info.plist keys or the App Group was verified, so the repository names
  none of them; take them from Apple's BackgroundAssets documentation.
- **A library on the live environment.** Every test of the facade runs it over fakes; no test builds one over the
  real file system and network.

### Decisions waiting for the owner

Every decision tagged NEEDS-HUMAN-REVIEW is listed at the top of [docs/DECISIONS.md](docs/DECISIONS.md). Among them,
the ones that change what an adopter gets: the storage location (ADR-001), the on-disk format (ADR-002), the platform
floors (ADR-005), the consumer's toolchain floor (ADR-056), the storage, network and power defaults (ADR-035,
ADR-036), background transfers and key exposure (ADR-026), Apple-tier pack retention (ADR-027), the compatibility
shims (ADR-033, ADR-055), and the SwiftUI facade (ADR-058): its exception to R-CAR-9, its place in the product, its
names, and whether a failed start should rebuild the client. Open without a ruling: RES-08, RES-09 and RES-15 above.

## Building and verifying

```sh
bash Scripts/verify.sh --quick        # toolchain + debug build + tests
bash Scripts/verify.sh --full         # the Definition of Done (see the first defect above)
bash Scripts/verify.sh --gates-only   # gate self-test, harness integrity, traceability, unsafe audit, documentation
```

`verify.sh` ends with exactly `VERIFY: PASS` or `VERIFY: FAIL (…)`. The iOS Simulator commands, which `verify.sh`
does not run, are in [HANDBOOK.md](HANDBOOK.md) under "Building and verifying".

## Where to read more

| Document | Read it for |
|---|---|
| [HANDBOOK.md](HANDBOOK.md) | The integrator's guide: concepts, the core quick start, every feature with its caveats, the documentation map |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Adopting the package in ZTronCarouselCore through the compatibility shims |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/DECISIONS.md](docs/DECISIONS.md) | The design as built, and why |
| [docs/VERIFICATION.md](docs/VERIFICATION.md), [docs/RESIDUAL-RISKS.md](docs/RESIDUAL-RISKS.md), [docs/DEVICE-TEST-PLAN.md](docs/DEVICE-TEST-PLAN.md) | What was proven, what was accepted, what is left for a device |
| [SPEC.md](SPEC.md) | The requirements (`R-…`), budgets (`P-n`) and quality gates |
