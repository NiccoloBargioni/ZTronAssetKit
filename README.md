# ZTronAssetKit

ZTronAssetKit gets ZTronCarousel's remote media (images, SVG, video, audio) onto the device and owns the lifetime of
every byte it stores there. It covers the whole path from "a manifest exists at an origin" to "a verified file URL
reaches a page": manifest fetch and validation, downloads, integrity checks, content-addressed storage, sync
scheduling, cleanup and quota, the Apple-hosted tier, and migration from the prior art's cache. It replaces the `CDN/`
code of ZTronCarouselCore. It is not a UI library (no UIKit, SwiftUI or Combine in its production targets), holds no
paywall or filter logic (apps map theirs to the `AssetScope` value), does not include the infrastructure that publishes
the catalog, and does not set an app up for Apple-hosted packs: the download extension, the Info.plist keys and the
App Group stay with the app ([SPEC](SPEC.md) §1.3).

## At a glance

- **Platforms.** iOS 15.0 and macOS 12.0 are the package floors ([ADR-005](docs/DECISIONS.md)). The Apple-hosted
  tier runs on iOS 26 or macOS 26 and later.
- **Toolchain.** Building and testing this package needs Swift 6.3 or newer. The manifest declares
  `swift-tools-version: 6.0`, the lowest that gives Swift 6 language mode, so a manifest on tools 6.0 can declare the
  dependency ([SPEC](SPEC.md) §3). An app or package that depends on ZTronAssetKit compiles the package's sources too,
  which use `@concurrent` (SE-0461, Swift 6.2), so no toolchain older than Swift 6.2 builds them; 6.3 or newer is the
  one this package is built and tested with.
- **Language mode.** Swift 6 with complete strict concurrency, also spelled out in [`Package.swift`](Package.swift).
  At most three audited escape hatches are allowed, each justified in
  [docs/UNSAFE-AUDIT.md](docs/UNSAFE-AUDIT.md).
- **Dependencies.** No third-party dependency: only modules that ship with Apple's SDKs and the Swift toolchain.
- **Product.** One library, `ZTronAssetKit`. `import ZTronAssetKit` also exports `ZTronAssetModel` (values, errors,
  events, environment protocols), so an app imports one module. The other targets (`ZTronAssetStorage`,
  `ZTronAssetTransport`, `ZTronAssetAppleHosted`, `ZTronAssetSync`) are internal to the package, and the fakes in
  `ZTronAssetTestSupport` are not a product ([SPEC](SPEC.md) §4.1).

Decisions that need the owner's confirmation, such as the storage location, the on-disk format, the platform floors,
the policy defaults, background transfers and the compatibility shims, are tagged NEEDS-HUMAN-REVIEW in
[docs/DECISIONS.md](docs/DECISIONS.md); the owner review list at the top of that file names each one.

## Installation

Depend on the package with SwiftPM: a path dependency on a checkout, as below; from a published repository, its URL and
a version.

```swift
// Package.swift of the package or app that uses ZTronAssetKit
dependencies: [
    .package(path: "../ZTronAssetKit"),
],
targets: [
    .target(name: "MyFeature", dependencies: [.product(name: "ZTronAssetKit", package: "ZTronAssetKit")]),
]
```

The `package:` argument is the dependency's identity, which for a path dependency is the name of its directory. In
an Xcode app project, add the checkout as a local package and link the `ZTronAssetKit` product.

## Quick start

```swift
import Foundation
import ZTronAssetKit
// A placeholder: the real key comes from the app's secure configuration and is never logged (R-SEC-1).
let key = AppKey("PLACEHOLDER-APP-KEY")
let http = HTTPSourceConfiguration(baseURL: URL(string: "https://assets.example.com/")!, appKey: key)
let client = AssetClient(configuration: AssetClientConfiguration(remote: RemoteConfiguration(http: http)))
try await client.start()                    // opens the store, installs the first snapshot, launches a due sync
let events = try await client.subscribe()   // registered before it returns; replays the current state
Task {
    for await case .assetAvailable(let id, _) in events { print("available:", id) }
}
let pages: [AssetID] = ["page-1", "page-2", "page-3"]
let window = PrefetchWindowController(client: client)   // keep it alive while the carousel is on screen
window.update(ids: pages, current: 0)                   // page-1 at .userInitiated, its neighbours at .prefetch
if let location = client.lookup(pages[0], extensions: ["heic", "png"]) {   // main actor, O(1), no I/O
    print("local:", location.url)
} else {
    let url = try await client.resolve(pages[0])        // the network step: single-flight, user-initiated
    print("fetched:", url)
}
```

This is top-level code, which runs on the main actor. In an app, create the client once at launch on the main actor
and call `start()` from the launch task before the first carousel page is created, the placement that step 3 of
[docs/MIGRATION.md](docs/MIGRATION.md) describes for the shims; keep the client alive for the app's lifetime. A store
root admits one client at a time: a second client, process or extension on the same location fails `start()` with
`.storageUnavailable(.locked)` (R-STO-9). Creating a client performs no I/O and starts nothing. `start()` returns when
the client is ready, not when a sync has finished. The key is wrapped in `AppKey`, which prints as `AppKey(<redacted>)`,
is not `Codable` and cannot be read back by the app, and the client sends it only to allow-listed HTTPS origins.

## How it works, briefly

State lives in actors: `AssetStore` owns the files, `SyncEngine` owns scheduling. The store keeps immutable blobs named
by the SHA-256 of their bytes (`blobs/<aa>/<sha256>.<ext>`) and one atomically replaced index (`index.bin`) under
`<base>/ZTronAssetKit/v1/`, so a moved or renamed catalog entry is an index edit, and a process kill or power loss at
any point leaves a state the next launch reconciles (H-1). Lookups read an immutable snapshot mirrored onto the main
actor. The engine schedules work in three lanes, `userInitiated` above `prefetch` above `bulk`, so the page the user
opens overtakes a bulk sync already in flight. Time, randomness, the file system, the network, reachability and power
state are injected through one `AssetEnvironment` value, whose `.live()` assembles the real conformers; the fallback
chain's bundle step (`MainBundleLookup`, over `Bundle.main`) is a seam of its own (`AssetFallbackChain(client:bundle:)`).
Details:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §2 (concurrency), §3 (every file on disk), §5 (snapshot), §7 (engine)
and §9 (the ten hard problems, each with its decision and its tests).

## Core concepts

### Configuration

`AssetClientConfiguration` is a value: `remote` (required) plus `location`, `storage`, `legacy`, `network`, `power`,
`refresh`, `tuning`, `limits`, `prefetchRadius` and `retentionScope`, each with a documented default. Every knob reaches
the code that uses it ([ADR-048](docs/DECISIONS.md)): `legacy.defaultsSuiteName` picks the `UserDefaults` suite the
default live environment reads the prior art's sync stamp from, `prefetchRadius` is the default radius of
`PrefetchWindowController`, `storage.evictionPermitted` lets a sync evict to make room (maintenance eviction runs
regardless), `limits.maxAssetBytes` is also the store's per-asset cap, and `tuning.snapshotInstallInterval` bounds how
often prefetch and bulk work install a new snapshot. Out-of-range tuning values are clamped, and `diagnosticReport()`
shows the clamped values. The defaults are recorded in [ADR-001](docs/DECISIONS.md) (the location:
`Application Support`, excluded from backup, so the system never purges essential assets; `.caches` suits a fully
regenerable catalog), [ADR-035](docs/DECISIONS.md) (storage) and [ADR-036](docs/DECISIONS.md) (network, power and
tuning). A `.custom(URL)` base in an App Group container is unsupported unless the app shuts its client down
(`shutdown()`) whenever it is backgrounded and creates a new one when it returns: a lock held in a shared container
while the app is suspended risks its termination (0xdead10cc; the documentation of `StorageLocation.custom`, risk R6
of [docs/design/store.md](docs/design/store.md)).

```swift
var configuration = AssetClientConfiguration(remote: remote)
configuration.storage.budget = .bytes(2_000_000_000)     // default: half of (store usage + free space)
configuration.refresh = .atMostEvery(24 * 60 * 60)       // default: once per app version
configuration.retentionScope = .tags(["free"])           // default: .all
let client = AssetClient(configuration: configuration)   // no environment: AssetEnvironment.live(...)
```

### Lookup on the main actor, resolve asynchronously

`lookup(_:extensions:)` is `@MainActor`, O(1) and does no I/O: it reads the snapshot mirror and returns an
`AssetLocation` (URL, extension, size, whether the bytes were verified against a checksum, and whether newer content is
pending while the old bytes are served) or `nil`. It returns `nil` before `start()` installed the first snapshot, after
`shutdown()`, and while a reopen replaces the store. It can also miss an asset for up to about two
`tuning.snapshotInstallInterval`s (0.2 s by default) after `resolve` returned it or an `assetAvailable` event announced
it, because prefetch and bulk work install snapshots at a bounded rate ([ADR-016](docs/DECISIONS.md),
[docs/MIGRATION.md](docs/MIGRATION.md) §4), and during legacy migration it misses a prior-art file until that file's
adoption is installed. After `resolve`, use the URL it returns; on `assetAvailable`, call `resolve`, which answers a
stored asset without a transfer, rather than `lookup`.

`resolve(_:priority:)` is the asynchronous step: one transfer per content however many callers wait, a caller's
cancellation affects only that caller, `.userInitiated` (the default) overtakes prefetch and bulk work, and an unknown
identifier makes the client fetch the manifest first. The public async APIs throw the closed `AssetError` (offline,
authRejected, notFound, insufficientSpace, integrityFailure, serverUnavailable, cancelled, storageUnavailable,
shutDown), so a UI can switch over it exhaustively; `withAsset` throws untyped errors because its body is the caller's,
and `sync` reports failures in its outcome ([ADR-004](docs/DECISIONS.md), [ADR-042](docs/DECISIONS.md)).

A URL the client hands out stays readable for at least `StoragePolicy.deletionGrace` of awake time after a snapshot
without it was installed ([ADR-017](docs/DECISIONS.md)). Code that reads the file again later loads it through `Data`
(an image decoder such as `UIImage(contentsOfFile:)`) or holds a lease with `withAsset(_:_:)`, which keeps eviction,
prune and purge away while its body runs; a video player holds a lease or looks the asset up again when a read fails
(ADR-017 as amended). When the UI cannot decode a file, `reportUnreadable(_:)` quarantines it and downloads it again with backoff.
Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §5 and §8, [ADR-016](docs/DECISIONS.md).

### Prefetch windows

`PrefetchWindowController(client:radius:)` keeps the carousel's neighbourhood warm (R-CAR-3). On every page change,
`update(ids:current:)` takes the ordered identifiers and the current index: the current page goes in at
`.userInitiated`, its neighbours up to the radius at `.prefetch`, in the order current, +1, −1, +2, −2
(`PrefetchWindow.targets`, a pure function). It starts what entered the window, cancels what left it, and re-lanes what
changed priority by registering the new interest before it releases the old one, so a transfer in flight is promoted,
never restarted. `cancelAll()` ends the window. The radius defaults to `configuration.prefetchRadius` (2). Underneath,
`client.prefetch(_:priority:)` returns a `PrefetchHandle` that releases its interest on `cancel()` or deinit, so no
transfer runs for nobody. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §7.2 and §8.

### The fallback chain: bundle, then local, then network

`AssetFallbackChain` is the three-step chain R-CAR-2 asks for: bundle, then local, then network, trying each candidate
extension of the asset's kind. In the prior art only ZTronCarousel's `ZTronSVGView` has all three steps;
ZTronCarouselCore's `BasicImagePage` looks only in the bundle and `BasicVideoPage` goes bundle then local
([docs/RECON.md](docs/RECON.md) §1). `prepare(kinds:)` indexes the app bundle off the main thread; await it once, with
every kind the app will locate, before the first `locate`: until it returns the bundle step finds nothing, and a later
call replaces the index rather than adding to it;
`locate(_:kind:)` (main actor, synchronous, no file-system work) tries the bundle for each candidate extension and then
the local snapshot; `fetch(_:kind:)` is the network step. `AssetKind` fixes the candidates: `.image` (heic, png, jpg,
jpeg), `.svg`, `.video(fileExtension:)` and `.audio` (wav, mp3). It deviates from the prior art in three ways
([ADR-037](docs/DECISIONS.md)): local hits appear only once `start()` installed the first snapshot, the extension
filter also applies to local hits, and asset catalogs (`UIImage(named:)`) stay in the carousel's UIKit adapter.

```swift
let chain = AssetFallbackChain(client: client)          // bundle step: MainBundleLookup()
await chain.prepare(kinds: [.image, .svg])              // once, off the main thread
let url: URL
switch chain.locate("page-1", kind: .image) {           // main actor: bundle, then local; no I/O
case .bundle(let bundled)?: url = bundled
case .local(let location)?: url = location.url
case nil: url = try await chain.fetch("page-1", kind: .image)   // the network step
}
```

### Events and subscribe

`events` returns a new `AsyncStream<AssetEvent>` that registers on its first pull. `subscribe()` starts the client and
returns a stream that is already registered, with the current state replayed (the snapshot generation, the device
conditions, a running sync and its progress). Any number of streams may exist, and each is bounded (R-SYN-12,
[ADR-023](docs/DECISIONS.md)): progress events (`snapshotChanged`, `conditionsChanged`, `syncProgress`,
`transferProgress`) are coalesced newest-wins per key and rate-limited (10 Hz by default); terminal events are never
dropped, the latest one of every subject being delivered; per-asset outcomes of bulk work are folded into
`syncProgress` and `syncFinished`; `clientShutDown` is always the last event. A slow consumer never makes a queue grow,
and cancelling the task that iterates, or releasing the stream, releases the subscription. Details:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §7.9 and §8.

### Retention scope, pins and purgeable caches

The retention scope says what the app wants kept, as an `AssetScope` value (`.all`, `.identifiers`, `.tags`,
`.prefix`): the app passes it in the configuration and calls `setRetentionScope(_:)` whenever the paywall changes
(R-CAR-5, [ADR-027](docs/DECISIONS.md)). Tags and the per-asset policy (`essential`, `standard`, `onDemand`) are
optional fields of each manifest entry, `tags` and `policy` (R-MAN-6), set by whoever publishes the catalog; without them
an entry has no tags and is `standard`. The HTTP tier reads the manifest at `baseURL` + `manifestPath` (`manifest.json` by
default), as a bare JSON array of assets or a `{ "schemaVersion", "assets" }` envelope (R-MAN-1). It is the scope of
every bulk sync, eviction removes entries outside it first,
and Apple-hosted packs whose remaining entries it excludes may be released. Changing it deletes and fetches nothing:
`ensureAvailable(scope:)` or `sync(.force)` fetch what it newly includes, and `purge(.scope(_:))` deletes every entry of
the scope it is given, pinned and essential ones included, whether or not the retention scope still names it, so give it
a scope that holds only what was dropped (an entry tagged both `season-0` and `free` would be deleted by the example
below and fetched again later). `pin(_:)` keeps assets away from eviction, though `purge(.all)` and `purge(.scope(_:))` still remove them, and
`unpin(_:)` undoes it ([ADR-044](docs/DECISIONS.md)).

```swift
try await client.setRetentionScope(.tags(["free", "season-1"]))   // the paywall changed: nothing deleted or fetched
let unlocked = try await client.ensureAvailable(scope: .tags(["season-1"]))   // fetch what it unlocked, now
print("still missing:", unlocked.missing)
try await client.pin(["intro-video"])                             // never evicted; purge(.all) still removes it
let purged = try await client.purge(.scope(.tags(["season-0"])))   // delete what is no longer wanted
print("freed:", purged.bytesFreed)
```

A derived in-memory cache, such as decoded images, conforms to `PurgeableCache` and is registered with `register(_:)`
on the main actor (R-CLN-11, ADR-044). The client holds it weakly and purges it on memory pressure, whose events come
from `AssetEnvironment.memoryPressure`. `AssetEnvironment.live()` sets none, because the UIKit memory warning belongs
outside the module (R-CAR-9), so an app that registers caches passes an environment with its own source:

```swift
var environment = AssetEnvironment.live(legacyDefaultsSuiteName: configuration.legacy.defaultsSuiteName)
environment.memoryPressure = appMemoryWarnings     // the app's MemoryPressureSource, built on UIKit's warning
let client = AssetClient(configuration: configuration, environment: environment)
try client.register(imageCache)                    // main actor; held weakly
```

Storage is budgeted (`StoragePolicy.budget`, a reserve of free space, least-recently-used eviction down to a hysteresis
target, never evicting essential, pinned, leased or recently used assets). `storageReport()` breaks the bytes down,
`purge(_:)` (`.all`, `.evictable`, `.scope`) deletes and makes a sync due, and `performMaintenance(timeBudget:)`, meant
for a `BGProcessingTask` handler, runs garbage collection, eviction and deep verification in bounded steps. Details:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §4.6, §4.6a and §7.10.

### Availability, ensureAvailable and sync modes

`availability(scope:)` counts present, missing, stale, failed and unverified assets of a scope against the applied
manifest, without network or I/O. `ensureAvailable(scope:)` fetches the manifest first and then everything missing in
the scope at `.userInitiated`; an `.identifiers` scope also makes `onDemand` entries eligible. `sync(_:)` runs one sync
of the retention scope at a time: `.ifDue` (the default) asks the refresh policy, `.force` runs now (the prior art's
"verify and repair"). It returns a `SyncOutcome` (`notDue`, `complete`, `completeWithFailures`, `blocked`, `failed`)
instead of throwing. `start()` launches the launch sync by itself when the policy says it is due (R-SYN-9): the policies
are `.oncePerAppVersion` (the default), `.everyLaunch` and `.atMostEvery(_:)`, and an app-version change always makes a
sync due. The sync stamp lives in the index, not in `UserDefaults`; `isSyncDue()` and `lastSyncedAt()` read it. A run
whose manifest fetch misses `tuning.manifestFetchDeadline` falls back to the applied manifest, reports
`manifestFresh == false` and writes no stamp, so the sync stays due ([ADR-053](docs/DECISIONS.md)). Details:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §7.10.

### Diagnostics and logging

`diagnosticReport()` returns JSON for support: the module and index schema versions, the index generation, the app
version, the configuration summarised field by field (the app key as `<redacted>` or `none`, URLs cut to scheme, host,
port and path), named engine counts, the sync stamp, the last 32 errors, the metrics and the storage figures. It is
built from one engine's figures and still answers when the store cannot (R-OBS-3, [ADR-044](docs/DECISIONS.md),
[ADR-054](docs/DECISIONS.md)). `metrics()` returns the in-memory counters (R-OBS-2). Log lines use the subsystem
`com.ztron.assetkit` with the categories `store`, `sync`, `transport` and `apple`, render identifiers as stable hashes
(`id#` and 16 hex digits) and never carry a secret (R-OBS-1, R-SEC-1). `.live()` writes them to the unified log through
`OSLogSink`; an environment assembled by hand defaults to `TapOnlyLogSink`, which writes nothing, unless it passes
`OSLogSink()` ([ADR-047](docs/DECISIONS.md)).

### Shutdown

`shutdown()` cancels and joins every task the engine owns (each store-touching call, transfer, timer and observer),
finishes every event stream with `clientShutDown` and flushes the index durably; calling it again does nothing. Afterwards every API fails with `.shutDown`: the async APIs
throw it, `sync` returns `.failed(.shutDown)`, a new `PrefetchHandle` reports it from `awaitRegistration()`,
`register(_:)` throws it, a new `events` stream yields only `clientShutDown`, and `lookup` returns `nil`; releases stay
harmless, and `handleBackgroundEvents` completes the system's handler at once (R-SYN-15, [ADR-039](docs/DECISIONS.md),
[ADR-042](docs/DECISIONS.md)). Releasing the last reference to a client shuts it down too (its `deinit` starts the
shutdown), so an app keeps one client for its whole lifetime.

### Background transfers: an owner opt-in

Background `URLSession` transfers are off by default: with `HTTPSourceConfiguration.background` at `.disabled`, every
transfer runs in the foreground session ([ADR-026](docs/DECISIONS.md)). Setting it to
`.enabled(BackgroundTransferOptions(...))` is the app's attestation that its AppDelegate forwards
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the client (a SwiftUI app adds one with
`@UIApplicationDelegateAdaptor`). Nothing detects at run time an app that attests the hook without wiring it, so enable
the policy only together with the hook:

```swift
// AppDelegate, in application(_:handleEventsForBackgroundURLSession:completionHandler:):
if !client.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler) {
    completionHandler()   // not the client's session; an app with sessions of its own passes it to their owner
}
```

`handleBackgroundEvents` returns `false`, and keeps nothing, for a session that is not the client's; the app then
passes that handler to the session's owner, or calls it. For the client's own session it calls the handler once the
session's events are staged. Only bulk transfers of known size within the cap, without a range resume, go to the
background session, and only those that carry no app key unless `keyRedirectExposure` is `.acceptedByOwner`: in the
background the system follows redirects without asking the app, so the key could reach a redirect target, and the hop
limit and size cap are checked only after the fact. The CloudFront origin requires the key ([SPEC](SPEC.md) §2.3),
so its bulk transfers stay in the foreground unless the owner accepts that exposure. An explicit `shutdown()` cancels
background downloads in flight, as a best effort; a killed or suspended app cancels nothing, and the next launch
re-attaches the system's tasks or adopts the files they finished ([ADR-028](docs/DECISIONS.md),
[ADR-039](docs/DECISIONS.md)). Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §6.2 and §6.4.

### The Apple-hosted tier

`RemoteConfiguration(http:appleHosted:awsOnly:)` names the tiers. With an `AppleTierConfiguration`, iOS 26 or macOS 26
and later select the Apple-hosted tier (BackgroundAssets packs) unless `awsOnly`, the kill switch, is set; otherwise the
client uses the CloudFront tier, so configure `http` as well for the devices below iOS 26 (R-APL-5: the decision is the
pure `TierSelection.select`, fed by the package's single `#available` check). The catalog is read from the essential
pack (`ZTronCatalog/catalog.json` by default), and each asset is streamed into staging, hashed and adopted into the
store. With `PackRetention.releaseAfterAdoption`, the default, a media pack is released once every entry it holds is
adopted in a durably committed index generation or excluded by the retention scope; `.keepPacks` keeps the packs, and
with them a second copy of their bytes ([ADR-027](docs/DECISIONS.md)). `StorageReport.sourceCopyBytes` reports what
the system still holds. A configured `appleHosted` has no fallback: on iOS 26 and macOS 26 and later the client selects
the Apple-hosted tier whether or not the app ships the extension and the packs, and `http` then serves only with
`awsOnly` set. Pass `appleHosted` only in a build that ships that setup; the `appleHosted: AppleTierConfiguration()` of
step 3 of [docs/MIGRATION.md](docs/MIGRATION.md) presumes it.

The app sets itself up for Apple hosting; the package does not ([SPEC](SPEC.md) §1.3). That means the downloader
extension (an app extension target built on StoreKit's `StoreDownloaderExtension`, iOS 26), the Info.plist keys and
the App Group, and the packs themselves, whose download policy (essential, prefetch or on demand) is build-time data;
the catalog belongs in the essential pack that `catalogPackID` names.
[docs/APPLE-API-VERIFICATION.md](docs/APPLE-API-VERIFICATION.md) holds the downloader extension and the pack policies in
§1.7 (the pack manifest cross-checked against Apple's page "Creating managed asset packs"), the BackgroundAssets
surface the tier uses in §1, and what only a device can confirm in §5. None of the Info.plist keys or the App Group
was verified, so this repository names none of them: take them, with the extension target's setup, from Apple's
BackgroundAssets documentation. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §6.6.

### Reopen after a replaced root

If the store's root directory vanishes or is replaced while the app runs (something outside the client deletes or
replaces it; a `.caches` root the system purges between launches is healed at the next launch instead, R-CLN-7),
commits fail with `.storageUnavailable(.rootVanished)` while reads keep working. The client then reopens: it shuts the
old engine down, resets the main-actor mirror (`lookup` returns `nil` until the replacement installs its first
snapshot), builds a replacement from the same configuration and environment, and repeats the failed call on it, at most
three reopens per call. After any other failure that can stem from the file system (`storageUnavailable`,
`serverUnavailable`, `insufficientSpace`, `integrityFailure`), the client checks the root (one stat, off the main
actor) and reopens only if it was replaced. `withAsset` reads the store's recorded reason (no I/O) before it takes a
lease and reopens first when that reason names a vanished root. Until a commit or a check detects a replacement, a call
that succeeds still uses the old store, a `withAsset` lease included. Prefetch registrations, the memory-pressure
observer and the retention scope set at run time survive a reopen; pins do not, since they lived in the vanished root.
Event streams continue with the replacement's `clientStarted(generation:)`, whose value may repeat an earlier one, and
never show the retired engine's `clientShutDown` (B-15, [ADR-050](docs/DECISIONS.md), [ADR-054](docs/DECISIONS.md);
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §5 and §8).

## Compatibility with ZTronCarouselCore

Every public CDN symbol of the prior art (`CDNAsset`, `CDNProviding`, `StaticManifestCDNProvider` and
`BackgroundAssetsCDNProvider` with their error types, `CDNLocalStore` with `CDNReconciliationSummary`,
`CDNAssetResolver.installed`, `CDNSyncCoordinator`, `CDNSyncProgress`, `NetworkAvailabilityMonitor`) keeps compiling
through shims (`CDNLocalStore`, `CDNAssetResolver` and `CDNSyncCoordinator` adapt `AssetClient`;
`NetworkAvailabilityMonitor` adapts the environment's conditions source), deprecated where the module's own API replaces
them, in
[`Tests/ZTronAssetCompatibilityTests/Shims/`](Tests/ZTronAssetCompatibilityTests/Shims/) (R-CAR-6). `CDNRefreshPolicy`,
`CDNProviderFactory` and `CDNConfiguration`, which SPEC R-CAR-6 names but the prior art on disk lacks, are provided new;
[docs/MIGRATION.md](docs/MIGRATION.md) §2 maps every symbol. The shims live in a test target, so they never ship in the
product and Combine stays out of the production targets ([ADR-033](docs/DECISIONS.md)). They use only the public API
and run there against a real client, and the carousel's call sites are copied into
[`PriorArtCallSiteTests.swift`](Tests/ZTronAssetCompatibilityTests/PriorArtCallSiteTests.swift), so a shim change that
would break them fails this package's build. This package changes nothing in ZTronCarouselCore or ZTronCarousel
([ADR-006](docs/DECISIONS.md)): adopting it there is the owner's step, and [docs/MIGRATION.md](docs/MIGRATION.md) is the
guide (the steps, the symbol-by-symbol map, the pre-existing tests and the behaviour that differs). The shims' open
decisions are tagged in [ADR-055](docs/DECISIONS.md).

A client also migrates the prior art's cache (`Library/Caches/CDNAssets` with its `manifest.json`,
`local-checksums.json` and `UserDefaults` stamp): files whose checksum verifies are moved into the store, not
downloaded again, and the legacy tree is removed afterwards (R-STO-11, [ADR-029](docs/DECISIONS.md); the deviations are
tagged in [ADR-052](docs/DECISIONS.md)). Migration runs in batches after `start()`; until a file's adoption is installed
in the snapshot, `lookup` misses it while `resolve` adopts it on demand without a download. `LegacyMigrationPolicy`
configures it, and `enabled: false` turns it off.

## Building and verifying

These are the repository's commands ([CLAUDE.md](CLAUDE.md)); run them with `bash` and `python3`, never through the
executable bit:

```sh
bash Scripts/verify.sh --quick        # toolchain + debug build + tests (inner loop)
bash Scripts/verify.sh --full         # the Definition of Done
bash Scripts/verify.sh --gates-only   # selftest + trace + unsafe + docs + harness integrity
python3 Scripts/gates.py selftest
SWIFTPM_SCRATCH=.build-<yourname> bash Scripts/verify.sh --quick    # parallel agents: never share .build
```

`verify.sh` ends with exactly `VERIFY: PASS` or `VERIFY: FAIL (…)`. `--full` adds the gate self-test, the release and
iOS builds, repeated test runs, the coverage gate, Thread Sanitizer, the benchmarks and the trace, unsafe and docs
gates; `--perf` runs the benchmarks alone. Warnings are errors, passed on the command line by `verify.sh` and never
set in `Package.swift`. The thresholds and budgets live in [`Scripts/quality-gates.json`](Scripts/quality-gates.json),
which is hash-pinned, and nothing under `Scripts/` changes after the `harness-frozen` tag. The trace gate rewrites
[docs/TRACEABILITY.md](docs/TRACEABILITY.md).

Every test target must also build and pass on the iOS Simulator, which `verify.sh` does not run, so `VERIFY: PASS`
alone does not show it ([ADR-051](docs/DECISIONS.md)). Its commands, run with `TMPDIR` inside your scratch path, on a
simulator of your own that is shut down afterwards:

```sh
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath <scratch>/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet
xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath <scratch>/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'
xcrun xcresulttool get test-results summary --path <bundle>
xcrun simctl shutdown <UDID>
```

Keep build output inside the repository: a scratch path such as `.build-<yourname>` for SwiftPM, and a
`-derivedDataPath` under it for every `xcodebuild`.

## Documentation map

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/DECISIONS.md](docs/DECISIONS.md) describe the package as built:
where another document under docs/ (a design, a review, a decision record, RECON or BASELINE) disagrees with them, they
win; [SPEC.md](SPEC.md), [PROMPT.md](PROMPT.md) and [CLAUDE.md](CLAUDE.md) keep the precedence of PROMPT.md's conflict
rule. The owner review list of NEEDS-HUMAN-REVIEW decisions is at the top of
DECISIONS.md.

| File | What it holds |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | **Authoritative design**: targets and ownership, concurrency, every file on disk, each layer, the hard problems with their tests, the REENTRANCY ledger, requirement-to-test map, review resolutions. |
| [docs/DECISIONS.md](docs/DECISIONS.md) | **Authoritative decisions** (ADRs: context, options, decision, consequences), with the owner review list at the top. |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Adopting the package in ZTronCarouselCore through the compatibility shims. |
| [docs/APPLE-API-VERIFICATION.md](docs/APPLE-API-VERIFICATION.md) | Apple API facts (BackgroundAssets, availability at the floors) checked against the installed SDKs, and what stays unverified. |
| [docs/UNSAFE-AUDIT.md](docs/UNSAFE-AUDIT.md) | The audit of unsafe escape hatches, read by the unsafe gate. |
| [docs/TRACEABILITY.md](docs/TRACEABILITY.md) | Generated by `Scripts/gates.py trace`: each requirement and budget with its test count; never edited by hand. |
| [docs/ORCHESTRATION.md](docs/ORCHESTRATION.md) | The orchestrator's working state for resuming the multi-agent build; not product documentation. |
| [docs/RECON.md](docs/RECON.md) | Historical: the Stage 0 inspection of the prior art (its defects, the behaviour to preserve). |
| [docs/BASELINE.md](docs/BASELINE.md) | Historical: the Stage 0 test baseline of the prior art and of this package's skeleton. |
| [docs/design/store.md](docs/design/store.md) | Historical: Stage 1 storage design draft (rationale, probes), superseded where it differs. |
| [docs/design/sync.md](docs/design/sync.md) | Historical: Stage 1 sync engine and facade design draft, superseded where it differs. |
| [docs/design/transport.md](docs/design/transport.md) | Historical: Stage 1 transport and Apple-tier design draft, superseded where it differs. |
| [docs/design/reviews/store-1.md](docs/design/reviews/store-1.md) | Historical: adversarial review of the storage design (crash consistency). |
| [docs/design/reviews/store-2.md](docs/design/reviews/store-2.md) | Historical: adversarial review of the storage design (snapshot, deletion, lifecycle). |
| [docs/design/reviews/sync-1.md](docs/design/reviews/sync-1.md) | Historical: adversarial review of the sync design (reentrancy, single-flight, cancellation). |
| [docs/design/reviews/sync-2.md](docs/design/reviews/sync-2.md) | Historical: adversarial review of the sync design (liveness and resources). |
| [docs/design/reviews/transport-1.md](docs/design/reviews/transport-1.md) | Historical: adversarial review of the transport design (security and HTTP semantics). |
| [docs/design/reviews/transport-2.md](docs/design/reviews/transport-2.md) | Historical: adversarial review of the transport design (lifecycle and platform). |
| [docs/adr-drafts/a.md](docs/adr-drafts/a.md) | Decision record of WP-A (model: manifest decoding and validation). |
| [docs/adr-drafts/b.md](docs/adr-drafts/b.md) | Decision record of WP-B (storage core). |
| [docs/adr-drafts/c.md](docs/adr-drafts/c.md) | Decision record of WP-C (integrity, cleanup, eviction, legacy migration). |
| [docs/adr-drafts/d.md](docs/adr-drafts/d.md) | Decision record of WP-D (transport). |
| [docs/adr-drafts/e.md](docs/adr-drafts/e.md) | Decision record of WP-E (Apple-hosted tier). |
| [docs/adr-drafts/f.md](docs/adr-drafts/f.md) | Decision record of WP-F (sync planner and engine). |
| [docs/adr-drafts/g.md](docs/adr-drafts/g.md) | Decision record of WP-G (the facade). |
| [docs/adr-drafts/h.md](docs/adr-drafts/h.md) | Decision record of WP-H (test support). |
| [docs/adr-drafts/i.md](docs/adr-drafts/i.md) | Decision record of WP-I (this README and the documentation pass). |
| [docs/adr-drafts/k.md](docs/adr-drafts/k.md) | Decision record of WP-K (the compatibility shims). |
| [docs/adr-drafts/ios.md](docs/adr-drafts/ios.md) | Decision record of the iOS Simulator test build (the gating convention and commands of ADR-051). |
| [docs/adr-drafts/l2close.md](docs/adr-drafts/l2close.md) | Decision record of the Level 2 close pass (code). |
| [docs/adr-drafts/l2fu.md](docs/adr-drafts/l2fu.md) | Decision record of the Level 2 follow-up. |

The decision records under `docs/adr-drafts/` are numbered into DECISIONS.md, whose ADRs cite them as normative
detail; where a record and its ADR disagree, the ADR wins. At the repository root, [SPEC.md](SPEC.md) holds the
requirements (`R-…`), budgets (`P-n`) and quality gates, [PROMPT.md](PROMPT.md) the mission and stage plan,
[CLAUDE.md](CLAUDE.md) the standing rules, and [KICKOFF-README.md](KICKOFF-README.md) how the kit that started this
repository is run.
