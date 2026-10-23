# WP-K decision drafts (R-CAR-6: compatibility shims)

Stage 2, level L5 after WP-G, branch `wp/k` (based on `l5g-merged`). One entry per non-trivial decision, in the
`DECISIONS.md` shape (context · options · decision · consequences); the orchestrator numbers them at merge. Files: every
new file under `Tests/ZTronAssetCompatibilityTests/` (not `CompatibilityShimTests.swift`), bodies and doc comments in
the two Stage 1 shim files (`Shims/CDNAsset.swift` unchanged, `Shims/CDNSyncProgress.swift`: the `CDNProviding` doc
comment only), `docs/MIGRATION.md`, this draft. No production source, no contract signature and no other WP's file
changed.

**Proposed REENTRANCY rows** (the code cites them as "k-n (proposed)"; all are main-actor awaits of
`CDNSyncCoordinator`, a test-target type, so ARCHITECTURE §10 may list them under a new "compatibility shims"
heading or by reference to this draft):

| Row | Where | What is re-validated after the await |
|---|---|---|
| k-1 | `CDNSyncCoordinator.run(_:)`: `client.subscribe()`, `client.sync(mode)`, then `follower.value` | Nothing of the coordinator is read across them. `progress` is written only by this call's follower while the run is in flight and by the outcome once the follower was cancelled **and awaited**, so no progress event lands after the outcome. A concurrent call joins the same single-flight run and publishes the same outcome (its follower may republish a `.syncing` value until its own outcome lands). |
| k-2 | the follower's `for await event in events` (a main-actor task) | Each event is applied in the turn it arrives, after `self` is re-read (weak: a released coordinator publishes nothing). Progress never moves backwards within a run by construction (sync.md §10.6: the engine's completed count is monotone and one subscription delivers a run's progress in order, newest-wins), so no guard is needed. |
| k-3 | `CDNSyncCoordinator.verifyFullyAvailable()`: `cdn.fetchManifest()` | Nothing of the coordinator; the client's snapshot is read after the fetch, so the comparison uses what is stored when the manifest arrived. |

**Contract change requests:** none. (K-13 notes an optional future API; the shims do not need it.)

---

## K-1 — The shims use only the public API of `ZTronAssetKit`
- **Context.** ADR-033: the owner copies `Shims/` into ZTronCarouselCore, another package, so anything `package` or
  `@testable` would not compile there. `KitHarness` is not importable from this target either (ADR-054).
- **Decision.** Every shim imports `Foundation`, `ZTronAssetKit` (which re-exports the Model) and, for
  `CDNSyncCoordinator`, `Combine`; nothing else, no `package` member (`AppKey.secret` included), no `@testable`. Internal
  members exist only as test seams that stay internal in the adopting module (`NetworkAvailabilityMonitor.flush()`,
  `StaticManifestCDNProvider.init(…executor:)`, `CDNSyncCoordinator.init(sharingClientOf:cdn:)`).
- **Consequences.** The shims see what an app sees: no applied manifest, no engine state (K-7, K-13). Zero unsafe
  escapes, no `@unchecked`, no lock: the main actor, one task-owned registry and `AsyncStream` continuations carry all
  shared state (K-2, K-8).

## K-2 — `CDNAssetResolver.installed` is an install point, not mutable global state · **NEEDS-HUMAN-REVIEW** (shim API)
- **Context.** The prior art kept `installed` in a `nonisolated(unsafe) static var` (RECON D-19). SPEC §4.2 forbids
  global mutable state and `static var`; R-CAR-6 requires `CDNAssetResolver.installed` (read by `ZTronSVGView`, written
  by the app's launch code) to keep compiling. `CDNLocalStore.shared` must find the same client.
- **Options.** (a) A main-actor `static var`. (b) A task-local (`installed = x` would no longer compile, and UIKit
  callbacks run outside the app's task scope). (c) A write-once install point.
- **Decision.** (c): `CDNInstallPoint`, a `@MainActor final class` reached through `nonisolated static let process`.
  Its one slot is isolated to the main actor (every access compiler-checked, no lock) and written at most once: the first
  installation wins and every later one returns the installed client. `CDNAssetResolver.installed` is a `@MainActor`
  computed property over it (`get`: a resolver over the installed client; `set`: installs the new value's client;
  `installed = nil` changes nothing); `CDNLocalStore.shared` is `CDNLocalStore(installPoint: .process)`.
  `CDNProviderFactory.install(_:into:environment:)` installs into it. Every shim also takes an explicit client.
- **Consequences.** After launch the slot is as immutable as a lazily initialised `static let`, only with a value the
  app supplies; there is no `static var` with storage. Deviation from the prior art: no re-installation or
  uninstallation (the prior art documented one installation at launch). Tests never fill the process point (they use
  local points), which keeps them parallel-safe; `R-CAR-6: CDNLocalStore.shared and CDNAssetResolver.installed follow the
  process install point, which no test fills` pins the empty state.

## K-3 — The lookups are `@MainActor` · **NEEDS-HUMAN-REVIEW** (shim API)
- **Context.** The prior art's lookups were nonisolated and did `fileExists` and hashing on the caller's thread (D-15,
  D-17). The client's synchronous lookup is `@MainActor AssetClient.lookup`, a read of the mirror with no I/O (R-STO-7).
- **Decision.** `CDNLocalStore.client`, `existingLocalURL`, `hasAsset`, `missingOrStaleAssets`, `isFullyAvailable`,
  `localURL(for:)`, `cacheManifest`, `cachedAsset(forIdentifier:)` and `reconcile(newManifest:)` are `@MainActor`.
- **Consequences.** Every prior-art call site compiles unchanged: `BasicVideoPage.init?` (a `UIViewController`) and
  `ZTronSVGView.resolveSVGURL` (a static member of a `UIView`) are main-actor isolated. Both call sites, `ZTronSVGView`'s
  nonisolated `deinit` calling `cancelRetry` included, are copied with their isolation into `PriorArtCallSiteTests.swift`
  (`R-CAR-6: the carousel's call sites compile unchanged and find nothing and start nothing while no client is
  installed`), so a shim change that breaks one fails the build. A nonisolated caller would need
  `await MainActor.run`. `missingOrStaleAssets` reads the snapshot once per asset on the main actor (O(n), no I/O).

## K-4 — `hasAsset` and `existingLocalURL` semantics
- **Decision.** `hasAsset(asset)`: the client's snapshot holds `asset.identifier` with `asset.fileExtension`, and, when
  `asset.checksum` is a SHA-256 (64 hex characters, either case), the stored blob's name equals it (a blob's name is the
  SHA-256 of its bytes, I-1; the URL shape is public on `AssetLocation`): no I/O. A checksum that is not a SHA-256 cannot
  be compared, so presence decides (R-MAN-5). The answer is relative to the asset given, as the prior art's comparison was;
  the client's own view of staleness (`AssetLocation.isStale`, relative to its applied manifest) is not consulted.
  `existingLocalURL(identifier:candidateExtensions:)` is `lookup(_:extensions:)`: candidates match case-insensitively,
  none means any, and the filter applies to manifest-known assets too (ADR-037's deviation, as `AssetFallbackChain.locate`).
- **Consequences.** Prior-art parity where it was sound (a republished checksum is missing, a stale asset keeps serving
  its old bytes while its new content downloads). Where it was not: the prior art compared an ETag-style checksum with its
  own SHA-256 and re-downloaded such an asset on every sync (D-16); the shims trust it on presence.

## K-5 — The two prior-art providers describe a client tier and serve a manifest; they no longer download · **NEEDS-HUMAN-REVIEW** (shim behaviour)
- **Context.** In the prior art the providers were the transport (D-1, D-3, D-4, D-7, D-9, D-11). The client has its own
  transport and Apple tier; the shims cannot reach `ZTronAssetTransport` or `ZTronAssetAppleHosted` (K-1).
- **Decision.** Both keep their initialisers and `CDNProviding` conformance. `StaticManifestCDNProvider` maps to the HTTP
  tier at its base URL and manifest path (no app key: the prior art sent none); `fetchManifest()` is one GET with
  `.reloadIgnoringLocalCacheData` on the injected session, a 2xx check (`badResponse` otherwise) and the module's
  validating `ManifestDecoder` on a `DispatchBlockingExecutor` (C2, D-9). `BackgroundAssetsCDNProvider` keeps
  `@available(iOS 26.0, *)`, maps to the Apple-hosted tier with SPEC §2.3's layout (the client reads its catalog from the
  essential pack; the app-supplied catalog is what `fetchManifest()` answers, as before). `downloadAsset` is deprecated on
  both and throws `CDNShimError.downloadsGoThroughTheClient` (the Apple provider still reports a malformed `remotePath`
  first). Both error enums gained `Equatable`/`Hashable` (additive).
- **Options considered.** Keeping a working download path in the providers (a per-download session or a temp-file
  staging sink) would keep the defects the module removes alive and write outside the store (D-7); nothing in the shims
  calls it.
- **Consequences.** A direct caller of `provider.downloadAsset` gets a deprecation warning and a typed error at run time.

## K-6 — The prior-art initialisers share one client per install point · **NEEDS-HUMAN-REVIEW** (shim behaviour)
- **Context.** The prior art's object graph is a provider plus `CDNLocalStore.shared`, wired separately into
  `CDNAssetResolver(cdn:)` and `CDNSyncCoordinator(cdn:)`. One root admits one client (R-STO-9), and the client's
  transport is fixed when it is built.
- **Decision.** Every `CDNLocalStore` is bound to an install point. The deprecated `CDNAssetResolver(cdn:localStore:)` and
  `CDNSyncCoordinator(cdn:localStore:defaults:appVersionProvider:)` use the client of their store's point, built there on
  first use from the provider (`CDNInstallPoint.installClient(for:)`: K-5's tier for the two prior-art providers, the
  point's configured tiers for a custom provider, which is never used as a transport). `CDNLocalStore()` binds the process
  point (a second default store must not build a second client); `CDNLocalStore(baseDirectory:)` gets a point of its own
  whose client keeps its root in that directory (`StorageLocation.custom`) and migrates the prior art's files found there
  (legacy removal only unlinks listed files and empty directories, so the nested store root is safe). `computeChecksum`,
  `defaults` and `appVersionProvider` are ignored (the client verifies SHA-256, keeps its stamp in its index and migrates
  the `UserDefaults` stamp once, R-STO-11). The coordinator's new initialiser is `init(client:cdn:)`.
- **Consequences.** The prior-art launch idiom (`CDNAssetResolver.installed = CDNAssetResolver(cdn: provider)`, then
  `CDNSyncCoordinator(cdn: provider)`) runs one client in either order (the losing side's unstarted client is dropped
  without I/O, P-12). Pinned by `R-CAR-6: prior-art resolvers and coordinators on one store share the one client its
  install point builds from the first provider`. A custom `CDNProviding` is no longer a transport: the owner configures
  the remote with `CDNConfiguration` (MIGRATION.md).

## K-7 — `CDNSyncCoordinator` over `sync` and the event stream
- **Decision.** `syncIfNeeded()` is `sync(.ifDue)` and `verifyAndRepair()` is `sync(.force)`. Each subscribes to the
  client's events first (`subscribe()`, which also starts the client), publishes every `syncProgress` as `.syncing` while
  the run is in flight (never backwards within a run, by construction, k-2), then cancels and awaits the follower and publishes the
  outcome with the contract's mapping (sync.md §10.6). `lastReconciliation` (new) maps the run's relocations and prunes
  (`CDNReconciliationSummary(report:)`). `verifyFullyAvailable()` fetches `cdn`'s manifest and returns
  `missingOrStaleAssets`, downloading nothing; the client hands no manifest entries out, so `init(client:cdn:)` takes the
  provider as the manifest source.
- **Consequences (differences from the prior art, all recorded in MIGRATION.md).** `.syncing` counts the run's planned
  fetches, not every manifest entry (stored assets are not counted as completed). `.upToDate` means "no sync was due when
  this call asked": the client's own launch run (R-SYN-9) may have synced moments earlier in the same launch, and a call
  that finds that run active joins it and reports its outcome. A complete `verifyAndRepair` also writes the stamp
  (sync.md §12.3). A partial run (`completeWithFailures`) is `.failed(reason:)` and leaves the sync due, as before.
  Observation for the orchestrator: a `.complete` run whose manifest fetch passed its deadline maps to `.complete` (the
  Stage 1 mapping in `CDNSyncProgress.swift`) while the stamp is not written; the next launch retries, which keeps the
  prior art's retry semantics, so the mapping was left as it is.

## K-8 — `NetworkAvailabilityMonitor` watches the reachability seam, not a client's events
- **Context.** The task names the monitor among the adapters over `AssetClient`, and the first implementation followed
  the client's `conditionsChanged` events. Its tests then failed under load, and a test of the prior art's own moment
  (`R-CAR-6: a retry registered while the client is idle still runs when connectivity returns`, commit `c623b34`) failed
  every time: a client with nothing to do observes nothing (R-SYN-14, `EngineConditions.swift`: the watcher stops when no
  work is left), and a view registers its retry exactly when the client has given up on the asset.
- **Decision.** The monitor observes a `DeviceConditionsSource`, the module's reachability seam
  (`AssetEnvironment.conditions`); `shared` uses `AssetEnvironment.live().conditions`, the live conformer every client is
  built with (the prior art used `NWPathMonitor` directly). `init(conditions:)` is the only public initialiser. Observation
  starts with the first registration and lasts as long as the monitor (the prior art's monitor, once created, watched for
  good); every report of a satisfied path runs the pending retries in registration order, the first report included (the
  prior art's initial path update). One task owns the registry and applies one ordered mailbox (registrations,
  cancellations, reports); `retryWhenAvailable` and `cancelRetry` stay synchronous and nonisolated (`ZTronSVGView` cancels
  from its `deinit`). Tokens come from an injectable `makeToken` whose default is `UUID.init`, the live conformer (C4).
- **Consequences.** Prior-art parity, including its limit: a retry registered while online waits for the next path
  change. Releasing a monitor ends its observation (tested). Deviation from the task text, for the orchestrator: the
  monitor is an adapter over the module's environment seam rather than over a client instance.

## K-9 — What is deprecated, and how the tests call deprecated API
- **Decision.** Deprecated where redundant (R-CAR-6): the prior-art initialisers of `CDNLocalStore`, `CDNAssetResolver`
  and `CDNSyncCoordinator`; `CDNLocalStore.sha256Hex`, `mechanicalPathComponents`, `cacheManifest`, `cachedAsset`,
  `localURL(for:)`, `store(temporaryURL:for:)`, `reconcile(newManifest:)`; the providers' `downloadAsset`. Not deprecated:
  what the carousel calls (`CDNLocalStore.shared.existingLocalURL`, `hasAsset`, `missingOrStaleAssets`,
  `isFullyAvailable`, `CDNAssetResolver.installed`, `resolveViaNetwork`, `NetworkAvailabilityMonitor`), the coordinator
  (the `ObservableObject` bridge R-CAR-9 puts in ZTronCarouselCore), the value types, the providers' initialisers and
  `fetchManifest`, and the new `CDNConfiguration`, `CDNProviderFactory`, `CDNInstallPoint`, `CDNShimError`.
- **Test technique.** Swift Testing rejects a deprecated `@Test` (probe: "Attribute 'Test' cannot be applied to this
  function because it has been marked '@available(*, deprecated…)'"), a deprecated extension of a suite likewise, and
  `verify.sh` builds with warnings as errors. A call through a protocol requirement that the deprecated member satisfies
  produces no warning (probed), so `LegacyAPIShimTests.swift` declares `PriorArtLocalStore`, `PriorArtResolver` and
  `PriorArtCoordinator` and conforms the shims to them; each conformance is also a compile-time proof of the prior-art
  signature. The coordinator's deprecated initialiser is proven that way only: calling it constructs `UserDefaults`,
  which tests must not touch; its behaviour is `init(sharingClientOf:cdn:)`'s, which is tested.

## K-10 — The shim test harness
- **Decision.** `CompatHarness`: a real `AssetClient` over `FakeFileSystem`, `FakeRemoteSource` (through
  `FakeRemoteSourceFactory`), `FakeDeviceConditionsSource`, `InlineBlockingExecutor`, `SeededRandom` and a
  `ManualTimeSource` wrapped in `AutoAdvancingClock`, which moves the manual clock to a sleep's deadline when it lies
  within 1 s of now and leaves later deadlines to the test. `KitHarness` drives the clock outside the engine and stops at
  the engine's clock fence, which it reads through `@testable` state; this target cannot. Moving at registration needs no
  fence: the harness's tuning sets `manifestFetchDeadline` to 10^6 s, beyond anything the auto-moves add up to, so only
  short store windows (the commit window, a commit retry, a trailing progress emission) pass by themselves. Also:
  `snapshotInstallInterval` 0 (a run's snapshots are installed when `sync` returns) and `maxAttemptsPerRun` 1 (a failure
  is final within its run; a retry would wait for an unscripted step).
- **L5-R14 patterns.** No run races the call under test: launches settle first (`settleLaunch()`: `sync(.ifDue)` joins
  the launch run or answers `notDue` after its stamp); coordinator tests use `.atMostEvery(3600)` and move the clock past
  the interval explicitly while the client is idle, so the run a call reports is the one it starts. Mid-flight states
  are held (`.hold` steps, released after an `EventProbe` or the coordinator's published progress shows the run in
  flight). Shared fake logs are counted from a baseline taken right before the call (`starts(after:)`). Census waits
  (`requireObservers`) use the throwing forms. No test sleeps or reads a wall clock; every awaiting test has
  `.timeLimit(.minutes(1))`; Mutex-backed fakes gate each `@Test` with `@available(macOS 15.0, iOS 18.0, *)` and the Apple
  provider's tests with `@available(macOS 26.0, iOS 26.0, *)` (ADR-051); real files only under
  `.build-tests/compatibility/` (git-ignored); HTTP only to the loopback server through an ephemeral session.
- **Consequences.** A sleep may return late under the `TimeSource` contract, which is all an overlapping auto-move can
  cause. Wall times in reports advance with the auto-moves; no test asserts them.

## K-11 — Deviations inherited from the module, pinned through the shims
- **Decision.** Three behaviours differ from the prior art because the module decided them, and a shim test pins each so a
  later module change shows up here: a 404 for an asset's new content fails the record until its entry changes, so its old
  bytes are no longer served (ADR-032; ADR-053, L4-R16; the prior art kept the old file and re-requested it on every sync,
  D-16), while a transient failure keeps the old bytes until a later sync fetches the new ones; the extension filter at the
  local step (ADR-037); and an on-demand resolve that downloads before its candidate check (as `AssetFallbackChain.fetch`;
  the prior art checked the manifest entry first).

## K-12 — Test-first with compiling skeletons
- **Decision.** Each component landed as a commit of failing tests with a compiling skeleton (the final signatures and
  doc comments, neutral bodies marked `WP-K skeleton`), then a commit of the implementation: install point and factory
  (`cd93f23` → `ac54a46`), local store and resolver (`f95c64f` → `65029f2`), coordinator (`32dfc96` → `436bd70`), monitor
  (`0dc2869` → `2dfbb0c`), providers and deprecated API (`4576216` → `6930f1e`), and the monitor's redesign (failing test
  `c623b34` → `cd2da19`). On the skeletons two tests passed because their expected answers are the neutral ones (a
  cancelled wait answering `nil`, since removed with the install point's wait, and the empty process install point).

## K-13 — An optional future API (not a contract change request)
- A public read of the client's applied manifest (for example `AssetClient.manifestEntries(scope:)`, no network) would
  let `cachedAsset(forIdentifier:)` reflect the client's manifest and `verifyFullyAvailable()` work without a provider.
  The shims work without it (K-6, K-7); recorded for the owner, not requested.

## Not verified here
- The shims at the iOS 15 floor at run time: the test target builds at iOS 17 / macOS 14 (ADR-051), the shims run on the
  iOS 27 simulator and macOS 27 only; their iOS 15 compile is the typecheck recorded in the evidence below.
- `NetworkAvailabilityMonitor.shared` over the live reachability conformer, `StaticManifestCDNProvider` against a real
  origin, `defaultAppVersion()` inside an app bundle, `BackgroundAssetsCDNProvider` on a device.
- Adoption inside ZTronCarouselCore (Q-10, ADR-006): MIGRATION.md describes it; nothing outside this repository was
  built or written.
