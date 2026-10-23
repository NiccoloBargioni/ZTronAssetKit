# WP-K decision drafts (R-CAR-6: compatibility shims)

Stage 2, level L5 after WP-G, branch `wp/k` (based on `l5g-merged`). One entry per non-trivial decision, in the
`DECISIONS.md` shape (context · options · decision · consequences); the orchestrator numbers them at merge. Files: every
new file under `Tests/ZTronAssetCompatibilityTests/` (not `CompatibilityShimTests.swift`), bodies and doc comments in
the two Stage 1 shim files (`Shims/CDNAsset.swift` unchanged, `Shims/CDNSyncProgress.swift`: the `CDNProviding` doc
comment only), `docs/MIGRATION.md`, this draft. No contract signature changed. `docs/MIGRATION.md` lies in WP-I's
`docs/**`; the WP-K launch notes allow it ("You may also write docs/MIGRATION.md"), ADR-006 and ADR-037 expect the
shims to document their differences there, and orchestrator ruling L5K-R10 makes it WP-K's file. **For the orchestrator
at merge:** record it as WP-K's file in ARCHITECTURE §1.2 (a "Files WP-K added" paragraph like WP-F's and WP-G's), so
WP-I does not treat it as unowned (fix round 1, reqs issue 2; L5K-R10). The close-out's authorised edits in WP-F's
engine (orchestrator ruling L5K-R1) are listed under "Authorised edits outside WP-K (close-out)" below.

**Proposed REENTRANCY rows** (the code cites them as "k-n (proposed)"; all are main-actor awaits of
`CDNSyncCoordinator`, a test-target type, so ARCHITECTURE §10 may list them under a new "compatibility shims"
heading or by reference to this draft):

| Row | Where | What is re-validated after the await |
|---|---|---|
| k-1 | `CDNSyncCoordinator.run(_:)`: `client.subscribe()`, `client.sync(mode)`, then `follower.value`; and the `await self.run(_:)` of `syncIfNeeded()` and `verifyAndRepair()`, after which nothing is read (fix round 1) | Nothing of the coordinator is read across them. `progress` is written only by this call's follower while the run is in flight and by the outcome once the follower was cancelled **and awaited**, so no progress event lands after the outcome. A concurrent call joins the same single-flight run and publishes the same outcome (its follower may republish a `.syncing` value until its own outcome lands). |
| k-2 | the follower's `for await event in events` (a main-actor task) | Each event is applied in the turn it arrives, after `self` is re-read (weak: a released coordinator publishes nothing). Progress never moves backwards within a run by construction (sync.md §10.6: the engine's completed count is monotone and one subscription delivers a run's progress in order, newest-wins), so no guard is needed. |
| k-3 | `CDNSyncCoordinator.verifyFullyAvailable()`: `cdn.fetchManifest()` | Nothing of the coordinator; the client's snapshot is read after the fetch, so the comparison uses what is stored when the manifest arrived. |
| k-4 | `SyncEngine.storedLocation(of:)` (`EnginePresence.swift`, WP-F's file, close-out ruling L5K-R1): `store.adoptLegacyNow(id)` while legacy migration is pending, called once per id of a job from `answeredFromStore` (row f-11) before any bytes | Nothing in the callee: `answeredFromStore` re-validates after its reads exactly as f-11 says (the lifecycle, the job epoch and the attempt still without a handle; the interests the job holds then; bindings recorded only when nothing was forgotten meanwhile, the adoption being such a binding). A thrown `StoreError` (the caller's cancellation at shutdown, a store that refuses) reads as "nothing stored", so the attempt goes on to the transfer, as the resolve path's own adoption does (ADR-029). The store orders this adoption against the migration loop's adoption of the same file (store rows R17, R18): `performAdoptLegacyNow` moves a queued file to `claimed` before its hash, so no batch takes it; a file a batch already claimed may be hashed by both calls, and `processLegacyFile` and `adoptVerifiedFile` re-validate the records after each await, so the first placement binds the records and the other call finds the file adopted (`alreadyAdopted`) and reads the location from the record. |

**Proposed amendment of row f-11** (ARCHITECTURE §10.2, the orchestrator's file): in its "Await" column, "`store.location(for:extensions:recordingAccess:)` per id of the job" becomes "`store.location(for:extensions:recordingAccess:)` per id of the job, or, while legacy migration is pending, `store.adoptLegacyNow(id)` (row k-4, L5K-R1)"; its re-validation column is unchanged.

**Contract change requests:** no signature change. One behaviour change in another WP's code (fix round 2), **ruled
by the orchestrator (L5K-R1) and made in the close-out** (see "Orchestrator rulings (close-out)" and "L5K-R1: every
transfer path during legacy migration" below); the request as it was filed:

- **CCR-K1 (WP-F engine, behaviour only; blocking R-STO-11 for a sync requested during legacy migration).**
  `SyncEngine.performSync` starts an explicit run while legacy migration is running: `EngineRuns.swift:10-39`
  reaches `startRun(trigger: .explicit, mode:)` at :39 and never reads `state.migration.running`, while `start()`
  (`EngineLifecycle.swift:317-331`) settles at :317, spawns the migration at :320 and parks only the launch run
  (`launchRunWaiting`, :331). Bulk jobs never try `store.adoptLegacyNow` (`EngineCommands.swift:56` is on the resolve
  path only). So `CDNSyncCoordinator.syncIfNeeded()` (`sync(.ifDue)`) or `verifyAndRepair()` right after `start()` on
  the first launch after adoption downloads every prior-art file phase 2 has not adopted yet, where R-STO-11 wants it
  moved (K-15: 6 to 41 of 150 files in 15 of 15 runs on a quiet host; on a loaded one migration can win). Minimal
  change, WP-F's choice: (a) while
  `state.migration.running` (or pending and not deferred), `performSync` sets `launchRunWaiting` and joins the run the
  migration loop's `defer` starts (`EngineRuns.swift:1055-1058`) instead of starting one; or (b) before a bulk job
  starts a transfer for a record whose legacy file is still pending, it tries `store.adoptLegacyNow`, as `awaitAsset`
  does. Tripwire: `R-CAR-6: a coordinator's syncIfNeeded right after start on the first launch after adoption completes
  and downloads none of the prior art's files (CCR-K1)`, whose download count sits in `withKnownIssue(…,
  isIntermittent: true)`; remove the wrapper with the fix. WP-F's F-8 pins only the launch run, so WP-F's own tests
  need the direct case too. Until then MIGRATION.md step 4 keeps the coordinator out of the launch task.

(K-13 notes optional future APIs; the shims do not need them.)

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
  `CDNProviderFactory.install(_:into:environment:)` installs into it. Every shim also takes an explicit client. The
  setter's body is `setInstalled(_:on:)`, an internal seam that takes the point, called with `.process` (fix round 2),
  so the prior art's assignment is tested on local points: `R-CAR-6: setting CDNAssetResolver.installed installs the
  value's client, a later value keeps the first client and nil changes nothing` (a seam that drops its value fails it
  with 3 issues).
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
  own SHA-256 and re-downloaded such an asset on every sync (D-16); `hasAsset` trusts such a checksum on presence, but
  the client's own manifest validator quarantines an entry whose checksum is present and not a SHA-256 (R-MAN-2), so
  the client never stores it under that entry (K-11). Both lookups answer `nil`/`false` until the installed client has
  started (ADR-037, K-11); the doc comments say so.

## K-5 — The two prior-art providers describe a client tier and serve a manifest; they no longer download · **NEEDS-HUMAN-REVIEW** (shim behaviour)
- **Context.** In the prior art the providers were the transport (D-1, D-3, D-4, D-7, D-9, D-11). The client has its own
  transport and Apple tier; the shims cannot reach `ZTronAssetTransport` or `ZTronAssetAppleHosted` (K-1).
- **Decision.** Both keep their initialisers and `CDNProviding` conformance. `StaticManifestCDNProvider` maps to the HTTP
  tier at its base URL and manifest path (no app key of its own: the prior art sent none; a point configured with that
  origin and its key keeps the key, K-6); `fetchManifest()` is one GET with `.reloadIgnoringLocalCacheData` on the
  injected session, a 2xx check (`badResponse` otherwise) and the module's validating `ManifestDecoder` on a
  `DispatchBlockingExecutor` (C2, D-9). It answers the validated manifest (`CDNAsset(entry:)` per entry), not the raw
  decoded array the prior art returned: checksums come back in lowercase hex, and entries the validator quarantines are
  left out (an invalid identifier, extension or remote path, and a checksum that is present but not 64 hex characters,
  R-MAN-2). `verifyFullyAvailable` is unaffected (it compares through `hasAsset`); a direct caller sees the normalised
  values. Pinned by `R-CAR-6: StaticManifestCDNProvider answers the validated manifest: checksums in lowercase hex,
  quarantined entries left out` (fix round 1: the reqs verifier expected a non-SHA-256 checksum to come back `nil`; the
  validator quarantines the entry instead, which the test shows). `BackgroundAssetsCDNProvider` keeps
  `@available(iOS 26.0, *)`, maps to the Apple-hosted tier with SPEC §2.3's layout (the client reads its catalog from the
  essential pack; the app-supplied catalog is what `fetchManifest()` answers, as before). `downloadAsset` is deprecated on
  both and throws `CDNShimError.downloadsGoThroughTheClient` (the Apple provider still reports a malformed `remotePath`
  first). Both error enums gained `Equatable`/`Hashable` (additive).
- **Options considered.** Keeping a working download path in the providers (a per-download session or a temp-file
  staging sink) would keep the defects the module removes alive and write outside the store (D-7); nothing in the shims
  calls it.
- **The provider's own fetch has no app key (fix round 2) · NEEDS-HUMAN-REVIEW (shim API).** `fetchManifest()` sends no
  `x-zombietron-app-key`, so SPEC §2.3's origin answers it 403 and `CDNSyncCoordinator.verifyFullyAvailable()` through
  `StaticManifestCDNProvider` throws `badResponse` on every call there (MIGRATION.md step 4 handed it that provider
  before this round). Options: (a) keep the provider keyless, say so, and recommend a manifest source that reaches the
  origin: an app-defined `CDNProviding` that sends the key to the configured origin and to no other, or the module's
  `client.availability(scope:)` (counts against the manifest the client fetched with its key, no network); (b) an
  additive initialiser that takes the key for the provider's own request and refuses a redirect to another origin
  (R-NET-4). (b) needs the key as a plain `String`, because the shims cannot read `AppKey.secret` (K-1): a second copy
  outside `AppKey`'s redaction (R-SEC-1), plus a task delegate for redirects, which is new secret-handling code in a
  compatibility layer for a call nothing in ZTronCarouselCore or ZTronCarousel makes. Chosen: (a), the owner's call;
  (b) stays available as an additive change. Documented in MIGRATION.md step 4, §2 and §4 and the doc comments of
  `fetchManifest()`, `verifyFullyAvailable()` and the coordinator's `cdn`; pinned by `R-CAR-6: StaticManifestCDNProvider
  sends no app key, so verifyFullyAvailable through it fails with the 403 of an origin that requires one, while a
  manifest source that sends the key reaches it` (a loopback origin that answers 403 without the header and 200 with
  it).
- **Consequences.** A direct caller of `provider.downloadAsset` gets a deprecation warning and a typed error at run time.

## K-6 — The prior-art initialisers share one client per install point · **NEEDS-HUMAN-REVIEW** (shim behaviour; storage location)
- **Context.** The prior art's object graph is a provider plus `CDNLocalStore.shared`, wired separately into
  `CDNAssetResolver(cdn:)` and `CDNSyncCoordinator(cdn:)`. One root admits one client (R-STO-9), and the client's
  transport is fixed when it is built.
- **Decision.** Every `CDNLocalStore` is bound to an install point. The deprecated `CDNAssetResolver(cdn:localStore:)` and
  `CDNSyncCoordinator(cdn:localStore:defaults:appVersionProvider:)` use the client of their store's point, built there on
  first use from the provider (`CDNInstallPoint.installClient(for:)`: K-5's tier for the two prior-art providers, the
  point's configured tiers for a custom provider, which is never used as a transport). `CDNLocalStore()` binds the process
  point (a second default store must not build a second client). `computeChecksum`, `defaults` and `appVersionProvider`
  are ignored (the client verifies SHA-256, keeps its stamp in its index and migrates the `UserDefaults` stamp once,
  R-STO-11). The coordinator's new initialiser is `init(client:cdn:)`.
- **`CDNLocalStore(baseDirectory: X)` (storage location; fix round 1).** The prior art's `X` is the legacy root
  (`LegacyMigrationPolicy(root: X)`), and the store's base is `X`'s parent: `StorageLocation.custom(X.deletingLastPathComponent())`,
  root `<parent>/ZTronAssetKit/v1`, beside `X`. Options: (a) `.custom(X)`, the first implementation, which nests the store
  inside the legacy root: WP-C refuses to migrate a legacy root that is, contains or lies inside the store's directory
  (`LegacyPlacement.swift`, pinned by WP-C's R-STO-11 test), so nothing was adopted, the prior art's files and stamp stayed
  for good, every asset was downloaded again and an error was logged on every launch; and `open()` creates only
  `<base>/ZTronAssetKit`, so on a fresh install (no `X` yet; the prior art created it) `start()` threw
  `storageUnavailable`. Both verifier lenses proved it with probes. (b) The default `.applicationSupport`: it moves the
  store out of the durability class the app chose (`Caches` or `Documents`), may lie on another volume than a custom `X`
  (migration then drops the root, C-14), and overlaps an `X` that is an ancestor of Application Support. (c) The parent, chosen: the same volume as `X` (migration renames,
  C-14), the app's durability class, an existing directory on a fresh install (`Caches`, `Documents`), never overlapping
  `X`. Residuals, documented on the initialiser and in MIGRATION.md: a missing parent still fails `start()`; one client
  per resolved base directory (R-STO-9: the second `start()` throws `storageUnavailable(.locked)`), counting every
  client of the process: two directories with one parent share one root (sharing one point per directory would need a
  main-actor registry, global mutable state under SPEC §4.2: the owner's call, not taken), and `.custom(<Caches>)` or
  `.custom(<Application Support>)` is the root of a client at `StorageLocation.caches` or `.applicationSupport`, the
  process install point's for example (`OpenUnits.base` returns a custom URL as it is; fix round 2); one legacy root per
  process: a store over the prior art's default `<Caches>/CDNAssets` and an installed process client with the default
  `LegacyMigrationPolicy()` would both migrate that tree, so they must not run together; an `X` named `ZTronAssetKit` is
  the store's own directory, which WP-C refuses to migrate. ZTronCarousel uses only `CDNLocalStore.shared`, so these
  bite only an app that adds a `baseDirectory` store. Pinned by `R-CAR-6: the prior-art local store
  initialiser's client adopts the prior art's files found in its directory and downloads nothing` (seeded prior-art tree:
  the resolve answers the adopted blob under `<parent>/ZTronAssetKit/v1/`, no transfer starts, the legacy file is renamed
  away, no "overlaps the store" line is logged), `…starts on a fresh install, before its directory exists` and `two
  prior-art stores in one parent directory share one root, which admits one client (R-STO-9)`; all three failed on the
  first implementation (`82490e7`). Fix round 2 added `a prior-art store whose directory lies in Caches shares its root
  with a client at StorageLocation.caches, which admits one client (R-STO-9)`, which passed on arrival (it pins the
  module's resolution).
- **The app key (fix round 1).** For a prior-art provider the provider's tier replaces the base remote, which dropped a
  configured key: a point built with `CDNConfiguration(baseURL: origin, appKey: key)` gave `StaticManifestCDNProvider`
  at `origin` a client without it, and SPEC §2.3's origin answers 403 without `x-zombietron-app-key`. Now
  `CDNProviderFactory.configuration(for:base:)` keeps `base`'s HTTP settings (key, key header, allowed hosts, connection
  cap, timeout, background policy) with the provider's base URL and manifest path when both name the same origin
  (scheme, host and port, normalised as the transport's `Origin`), and never carries the key to another origin (R-NET-4).
  The process install point's configuration names no origin, so the prior-art idiom there still builds a client without
  a key: MIGRATION.md step 3 says to install a configured client first. Pinned by `R-CAR-6: a prior-art provider at the
  configured origin keeps the configuration's app key and HTTP settings, and one at another origin gets neither`.
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
  provider as the manifest source. That fetch is the provider's own request: `StaticManifestCDNProvider` sends no app
  key, so at SPEC §2.3's origin `verifyFullyAvailable()` through it throws `badResponse` (403) on every call, and the
  manifest source must send the key (fix round 2, K-5; MIGRATION.md step 4).
- **Consequences (differences from the prior art, all recorded in MIGRATION.md).** `.syncing` counts the run's planned
  fetches, not every manifest entry (stored assets are not counted as completed). `.upToDate` means "no sync was due when
  this call asked": the client's own launch run (R-SYN-9) may have synced moments earlier in the same launch, and a call
  that finds that run active joins it and reports its outcome. A complete `verifyAndRepair` also writes the stamp
  (sync.md §12.3). A partial run (`completeWithFailures`) is `.failed(reason:)` and leaves the sync due, as before. A
  blocked run (`SyncOutcome.blocked`: every remaining job waits on a gate: offline, an open breaker, a throttle, space,
  and under ADR-036's defaults Low Power Mode, Low Data Mode or serious thermal pressure for bulk work, where the prior
  art downloaded regardless) is `.failed(reason: "blocked(…)")`, fills `lastReconciliation` from its report (the run
  reconciled before its downloads waited) and leaves the sync due. The engine keeps a pending run and starts it by itself
  once the gate opens (sync-2 S2-03, after `pendingRunDebounce`); the coordinator does not observe it, so `progress`
  keeps the call's outcome while those assets arrive in the same launch. Pinned by `R-CAR-6: a run blocked by Low Power
  Mode reports failed with blocked and stays due, and the client finishes it unobserved once the gate opens` (fix
  round 1). Once per app version: `R-CAR-6: once per app version: a later launch of the same version reports upToDate
  without a manifest request, and a new version syncs at launch` runs three launches on one volume. On a new version the
  client's own launch run performs the sync, so the coordinator's answer is `.complete` only if its call joins that run;
  no public API tells a test when a call has joined, so the test settles the launch run first and pins `.upToDate`
  afterwards, plus one manifest request and only the new catalog's asset fetched (the reqs verifier asked for
  `.complete`; MIGRATION.md §3's row now says what is pinned).
  On a launch during legacy migration (the first launch after adoption, and any later launch that resumes an
  unfinished migration, L5K-R4) a call made while migration is still adopting starts a run at once. Until the
  close-out that run downloaded every prior-art file not adopted yet (CCR-K1); since the engine's fix (L5K-R1) its
  jobs adopt those files instead, and the run takes the place of the launch run that waited for migration, so the
  launch syncs once. MIGRATION.md step 4 therefore calls the launch-task sync safe on every launch again, and the doc
  comments of `syncIfNeeded()` and `verifyAndRepair()` say what such a run does. Pinned by `R-CAR-6: a coordinator's
  syncIfNeeded right after start on the first launch after adoption completes and downloads none of the prior art's
  files (CCR-K1)` and its resumed-launch twin (L5K-V3-06).
  A `.complete` run whose manifest fetch passed its deadline maps to `.complete` (the Stage 1 mapping in
  `CDNSyncProgress.swift`) while the stamp is not written; the next launch retries, which keeps the prior art's retry
  semantics. **Orchestrator ruling (close-out), L5K-R9:** accepted as decided; the mapping stays.

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
- **Consequences.** Prior-art parity, including its limit: a retry registered while online waits for the next satisfied
  report. Releasing a monitor ends its observation (tested). Deviation from the task text, for the orchestrator: the
  monitor is an adapter over the module's environment seam rather than over a client instance.
- **The retry trigger (close-out, L5K-V3-08).** A "report" is a conditions report, not only a path update: the live
  source (`LiveDeviceConditionsSource`) emits one on every path change and also on every Low Power Mode and
  thermal-state notification, so pending retries also run on those reports while the path is satisfied, where the prior
  art's `NWPathMonitor` retried on path updates only; `ZTronSVGView` registers again after each failure, so a view that
  keeps failing also retries then (`NetworkMonitorShimTests` re-sends an identical `.unrestricted` and retry 2 runs).
  Filtering on a changed `network` value would lose path updates the prior art retried on (Wi-Fi to another Wi-Fi).
  **Orchestrator ruling (close-out), L5K-R6:** document it, no behaviour change; done in this entry, MIGRATION.md §2's
  row and §4, and the monitor's doc comments.
- **Orchestrator ruling (close-out), L5K-R7:** K-8 approved as decided: an idle client observes nothing (R-SYN-14), and
  the failing test `c623b34` proved the event-driven version misses the prior art's retry moment. `shared` builds its
  own live conditions source (ADR-038: fresh conformers per call), so it is a second path monitor in the process,
  acceptable for a shim (stated in the monitor's doc comment and MIGRATION.md §2). The public API is unchanged, so this
  is not NEEDS-HUMAN-REVIEW.

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
  is final within its run; a retry would wait for an unscripted step). `make(tuning:)` lets a test bring one more delay
  inside the horizon (the blocked-run test's `pendingRunDebounce`, 0.5 s instead of 5 s, so no explicit clock move races
  the engine's scheduling of it); `relaunch(appVersion:)` builds a later launch's client over the same fakes (fix round 1).
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
- **Orchestrator ruling (close-out), L5K-R3: accepted, with conditions.** `AutoAdvancingClock` wraps `ManualTimeSource`,
  never reads the wall clock and never sleeps for real (C4), and moves the clock only to the deadline of the sleep being
  registered, when that deadline lies within its 1 s bound. The fenced driver of `KitHarness` needs `@testable` engine
  state, which this public-API-only target must not import (K-1: the shims stay copyable into ZTronCarouselCore).
  Conditions, and how they are met: (1) every assertion waits on an explicit, publicly observable condition, never on
  an advance having happened: the L5K-R2 table below checks every test against it, the auto-moves included; (2)
  `manifestFetchDeadline = 1e6` is a harness setting, and no test of this target tests a deadline (none asserts on a
  manifest fetch's deadline, a breaker cooldown, a retry backoff or a pending run's debounce passing by itself; the one
  debounce a test relies on, the blocked-run test's `pendingRunDebounce`, is brought inside the 1 s bound so the
  harness passes it as any short store window); (3) any flake under load or TSan blocks and goes through L5K-R2's class
  rule.
- **Close-out additions (L5K-R1, L5K-R2).** `CompatHarness.make(bulk:)` and `environment(…, bulk:)` take the store's bulk
  executor (inline by default), so a test can hold legacy migration at a unit with `SteppedBlockingExecutor`, public in
  `ZTronAssetTestSupport`. `startHoldingMigration(_:bulk:)` starts a client while releasing every unit until `start()`
  has returned (a second, cancellable caller of the single-flight `start()` is the start's wake-up, so nothing polls)
  and returns the migration's held units; `releaser(_:keeping:)` releases every other unit as it arrives until it is
  cancelled. Every wait ends on cancellation.

## K-11 — Deviations inherited from the module, pinned through the shims
- **Decision.** Five behaviours differ from the prior art because the module decided them, and a shim test pins each so a
  later module change shows up here: a 404 for an asset's new content fails the record until its entry changes, so its old
  bytes are no longer served (ADR-032; ADR-053, L4-R16; the prior art kept the old file and re-requested it on every sync,
  D-16), while a transient failure keeps the old bytes until a later sync fetches the new ones; the extension filter at the
  local step (ADR-037); an on-demand resolve that downloads before its candidate check (as `AssetFallbackChain.fetch`;
  the prior art checked the manifest entry first); the synchronous lookups answer only after `start()` installed the
  first snapshot (ADR-037; the prior art read the disk from launch on, RECON §5), and on a launch during legacy migration
  (the first launch after adoption, and any later launch that resumes an unfinished migration) a prior-art file only
  once the snapshot holding its adoption, by migration or by a resolve after `start()` returned, is installed (fix round
  2, K-15; L5K-R4: starting the client before carousel content exists is not enough on such a launch); and an entry whose checksum is present
  but not a SHA-256 is quarantined (R-MAN-2), never downloaded, where the prior art downloaded it on every sync (D-16).
  Fix round 1 completed the 404 pin (a changed entry is then requested once and stored) and added the lookup pin
  (`R-CAR-6: the lookups answer nil for an asset stored in an earlier launch until the installed client has started, and
  its file right after`) and the quarantine pin (K-5's provider test). MIGRATION.md step 3 now starts the client before
  carousel content is created; the doc comments of `CDNLocalStore`, `existingLocalURL`, `hasAsset` and
  `CDNProviderFactory.install` say the lookups wait for `start()`.
- **The lifetime of the URL `existingLocalURL` hands out (close-out, L5K-V3-07; orchestrator ruling L5K-R5: document it).**
  The prior art kept an asset at one pretty path and replaced its bytes in place when the content changed, so a URL a
  page held stayed valid. The shims hand out the module's content-addressed blob URLs (ADR-017's consumer contract,
  `AssetLocation`'s doc): the URL names stored content; after a content change, a prune or an eviction, the old file is
  removed `StoragePolicy.deletionGrace` (ADR-035: 10 s of awake time by default) after the new snapshot, unless a lease
  holds it. `BasicVideoPage` builds its `TinyVideoPlayer` from the URL at init, so a page created before a republish may
  later re-read a path that is gone: a consumer that re-reads the path later looks it up again when the read fails, or
  holds a lease (`AssetClient.withAsset`). Stated in MIGRATION.md §2 (the `existingLocalURL` row) and §4, and in
  `existingLocalURL`'s doc comment. Not probed: it follows from the module's documented contract.
- **Orchestrator ruling (close-out), L5K-R9:** the behaviour differences inherited from the module (ADR-032/L4-R16,
  ADR-037) are accepted, documented and pinned as they are.

## K-12 — Test-first with compiling skeletons
- **Decision.** Each component landed as a commit of failing tests with a compiling skeleton (the final signatures and
  doc comments, neutral bodies marked `WP-K skeleton`), then a commit of the implementation: install point and factory
  (`cd93f23` → `ac54a46`), local store and resolver (`f95c64f` → `65029f2`), coordinator (`32dfc96` → `436bd70`), monitor
  (`0dc2869` → `2dfbb0c`), providers and deprecated API (`4576216` → `6930f1e`), and the monitor's redesign (failing test
  `c623b34` → `cd2da19`). On the skeletons two tests passed because their expected answers are the neutral ones (a
  cancelled wait answering `nil`, since removed with the install point's wait, and the empty process install point).
  Implementation commits also sharpened tests the skeleton run had exposed as too weak or wrong about the module (the
  stale asset observed while its new content is in flight; the transient and 404 cases of K-11; a wait cancelled after
  it registered). Two later commits change no behaviour under test: `066b0a5` drops a progress guard the engine makes
  unreachable and covers the default legacy root, `35c9f8f` pins the carousel's call sites (K-3), tests of shims that
  already existed. Fix round 1, test first again: `82490e7` (12 issues on the round-0 shims: the store's placement, the
  fresh install, one root per parent, the app key, `localURL` confinement) → `e81449c` (all pass), then `9150501`
  (pins of module behaviour that passed on arrival: lookups before `start()`, the blocked run, once per app version, the
  validated manifest, the changed entry after a 404, the app-version seam). Fix round 2: `d512f03` (the first launch
  after adoption: the lookups pin passed on arrival; the CCR-K1 test failed in 15 of 15 runs before its download count
  was wrapped in `withKnownIssue`, K-15), `8e0854a` (the `installed` seam with its test, refactor-only: the setter's
  behaviour is unchanged, and a mutant seam fails the test), `1a3e94b` (pins that passed on arrival: the keyless
  provider's 403, the Caches root shared with `.caches`).

## K-13 — Optional future APIs (not contract change requests)
- A public read of the client's applied manifest (for example `AssetClient.manifestEntries(scope:)`, no network) would
  let `cachedAsset(forIdentifier:)` reflect the client's manifest and `verifyFullyAvailable()` work without a provider
  (and without the provider's keyless fetch, K-5). The shims work without it (K-6, K-7); recorded for the owner, not
  requested.
- A way to await legacy migration (fix round 2), for example a start option that returns once the prior art's tree is
  adopted, or an awaitable migration report: MIGRATION.md step 3 could then hold carousel content until the prior art's
  files answer the lookups on a launch during legacy migration (K-15). Recorded for the owner, not requested.
- **Orchestrator ruling (close-out), L5K-R9:** a public read of the applied manifest is not added in Level 5: it would be
  a public API addition to `ZTronAssetKit` (NEEDS-HUMAN-REVIEW) that no requirement needs. Both items stay owner options
  (DECISIONS.md's owner review list).

## K-14 — The deprecated `localURL(for:)` stays inside the legacy root (fix round 1)
- **Context.** For an asset the client does not hold, `localURL(for:)` builds the prior art's pretty path from
  manifest-supplied `localPathComponents` and `resolvedFileName`. A crafted entry (`..`, or a component containing `/`)
  named a path outside the legacy root, which app code might read or write (R-SEC-2's spirit; the prior art joined them as
  given).
- **Decision.** Directory components that are empty, `.` or `..`, or that contain `/`, are dropped; in the file name
  every `/` becomes `_`, and a name that would be `.` or `..` is `_`. The identifier's segments (`split(".")`) never
  yield `.`, `..` or empty components, so only a `/` in them is affected.
- **Consequences.** Valid entries keep the prior art's path (the layout test is unchanged); crafted ones stay under the
  root. Pinned by `R-CAR-6: localURL keeps a crafted entry's path inside the legacy root` (failing at `82490e7`, before the fix).

## K-15 — Launches during legacy migration: lookups and syncs (fix round 2; close-out L5K-R1, L5K-R4) · **NEEDS-HUMAN-REVIEW** (shim behaviour)
- **Context.** On a launch on which legacy migration is still adopting the prior art's files (the first launch after
  adoption, and any later launch that resumes a migration an earlier launch did not finish: `open()` finds the persisted
  phase `inProgress`, rebuilds the plan and reports `legacyMigrationPending` again, `StoreMigration.swift`, L5K-V3-06)
  the client adopts the prior art's files (R-STO-11, phase 2) in engine-owned batches (`migrateLegacy(maxFiles: 64)` per
  call of the migration loop) that start only after `start()` has settled: `EngineLifecycle.swift` settles the start,
  spawns the migration and parks the due launch run behind it. A batch installs its snapshot at its end (bulk urgency);
  an on-demand adoption (`adoptLegacyNow`, a resolve's or, since L5K-R1, any job's) installs its own at once. The
  `UserDefaults` stamp migrates in phase 3, after every entry. On a device a terminated first launch is plausible,
  because phase 2 hashes every prior-art byte, so "the first launch after adoption" was never the whole window
  (L5K-V3-01, L5K-V3-06; orchestrator ruling L5K-R4 rescoped every passage).
- **The lookups (the window that remains).** Until the snapshot holding a prior-art file's adoption is installed,
  `existingLocalURL` answers `nil`, `hasAsset` `false`, and `missingOrStaleAssets` lists the file; a resolve adopts a
  pending file on demand (store-2 S2-09) without a transfer and installs its snapshot before it returns. The shims cannot
  close the window: their lookups read the main-actor snapshot with no I/O (K-3, C2), and reading the prior art's tree
  from the main thread would be file-system I/O there and would hand out paths that migration is about to rename.
  Decision: say it (MIGRATION.md step 3 and §4; the doc comments of `CDNLocalStore`, `existingLocalURL`, `hasAsset`,
  `missingOrStaleAssets` and `CDNProviderFactory.install`) and pin it: `R-CAR-6: on a launch during legacy migration the
  lookups miss a prior-art file until it is adopted after start() returned: a resolve adopts it without a download, and
  every file answers once migration has ended`. Since the close-out (L5K-R2) that test holds the migration at a unit of
  its first file (`SteppedBlockingExecutor`), so the window is a held state, not a race: 40 prior-art files; after
  `start()` none answers and the three lookups agree; a `resolveViaNetwork` per file, made while the migration stays
  held, adopts every file with no transfer and empties the prior art's tree; the migration then goes on, and once the
  launch run it held back starts (no other run started in that launch, so that run starts exactly when the migration
  loop ends, after every batch's snapshot is installed) all 40 answer. The round-2 version asserted "all answer" right
  after the resolves over a running migration, which a file a still-running batch had adopted could break (its batch's
  snapshot comes only at the batch's end), so the assertion now waits for the end of migration (the L5K-R2 table).
  `ZTronSVGView` adopts through its `resolveViaNetwork` fallback; `BasicVideoPage` has no network step, so a prior-art
  video appears in a page created after its adoption is installed. An API that awaits migration is K-13's.
- **The syncs (CCR-K1, ruled by L5K-R1 and fixed in the close-out).** Until the close-out a sync requested during
  migration started an explicit run at once, and its bulk jobs downloaded every prior-art file phase 2 had not adopted
  yet (6 to 41 of 150 files in 15 of 15 quiet runs; 30, 38 and 42 of 150 in this close-out's runs of the strict test
  on the pre-fix engine). Since L5K-R1 the engine's pre-transfer read adopts such a file instead, whatever created the
  job, and a run that starts while the launch run waits for migration takes its place (the next section). Through the
  shims: `R-CAR-6: a coordinator's syncIfNeeded right after start on the first launch after adoption completes and
  downloads none of the prior art's files (CCR-K1)` (150 prior-art files of 64 KiB, MIGRATION.md steps 3 and 4 in one
  launch task) is strict now: no transfer, every prior-art file out of the prior art's tree when the sync returns,
  `.complete`, and every asset stored (`availability(scope:)`; the lookups' snapshot follows a running batch's
  adoptions only at the batch's end, and no public event marks the end of migration when a run took the launch run's
  place). Its resumed-launch twin, `R-CAR-6: a coordinator's syncIfNeeded right after start on a later launch that
  resumes an unfinished legacy migration completes and downloads none of the prior art's files (L5K-V3-06)`: launch 1
  runs steps 3 and 4 with every bulk unit held, and is shut down once its sync's run has started (the sync's joiner is
  answered in the shutdown turn that cancels the migration, so at most the files of the units then held are adopted:
  one for the migration and one per running job; 148 of 150 files were left in the runs on the pre-fix engine); launch
  2 starts on the same volume and syncs right away:
  `.complete`, no transfer, the tree empty, every asset stored. On the pre-fix engine it failed 3 of 3 runs (6, 6 and
  18 of the 148 files left were downloaded). MIGRATION.md step 4 calls the launch-task sync safe on every launch again.
- **Consequences.** What remains is the lookups' window above, as long as migration runs; on a device it grows with the
  prior art's bytes (phase 2 hashes them); not measured here. The window's syncs download nothing a migration can still
  adopt (R-STO-11).

## Fix round 1 — the verifiers' issues and what became of them
- reqs 1 / correct 1 (blocking, `CDNLocalStore(baseDirectory:)` nests the store in the legacy root; fresh install):
  fixed (K-6), test first.
- correct 2 (blocking, cold-launch lookups answer nil until `start()`): fixed in MIGRATION.md step 3 and §4, the doc
  comments, K-11; pinned by a new test (K-11).
- reqs 2 (ownership of `docs/MIGRATION.md`): authorised by the launch notes; recorded in this draft's header for the
  orchestrator, who owns ARCHITECTURE §1.2.
- reqs 3 (blocked outcome): test added, documented in K-7, MIGRATION.md §4 and `syncIfNeeded()`'s doc comment.
- reqs 4 (once per app version): test added in the deterministic form K-7 describes; the MIGRATION.md §3 row says what it
  pins. A coordinator `.complete` on a version change is not pinned: it depends on the call joining the client's own
  launch run, which no public API lets a test order.
- reqs 5 (the 404 pin's second half): done (K-11).
- reqs 6 (`defaultAppVersion`): an `appVersion(from:)` seam is tested with synthetic Info dictionaries (order, missing
  keys) and `defaultAppVersion()` against the main bundle directly.
- reqs 7 / correct 6 (`hasAsset` doc said "not stale"): fixed; K-4 already said staleness is not consulted.
- reqs 8 (`fetchManifest()` normalisation undocumented): documented in K-5 and MIGRATION.md §2 and pinned; a checksum
  that is not a SHA-256 quarantines its entry rather than coming back `nil`.
- reqs 9 (MIGRATION.md floors sentence): fixed.
- correct 3 (app key dropped for a prior-art provider): fixed at the same origin, documented for the process point (K-6).
- correct 4 (two stores over one directory): the new placement makes it "one store per parent directory"; documented
  (K-6, the initialiser, MIGRATION.md) and pinned. **Declined:** sharing one install point per directory, which needs a
  main-actor registry (global mutable state, SPEC §4.2); the owner's call.
- correct 5 (REENTRANCY comments on `run(.ifDue)` and `run(.force)`): added (k-1).
- correct 7 (`localURL(for:)` sanitising): fixed (K-14).
- correct 8 (stale line citation in a test message): now cites k-2 and `CDNSyncCoordinator.run(_:)`.
- correct 9 (P-13 benchmark overrun): not WP-K's (no source or benchmark file changed); see the evidence below.

## Fix round 2 — the verifiers' issues and what became of them
- correct 1 (blocking, an explicit sync races legacy migration): an engine defect in WP-F's files, so CCR-K1 for the
  orchestrator; the failing test first (15 of 15 failing runs), kept as a known issue; MIGRATION.md step 4, §4, K-7,
  K-15 and the doc comments of `syncIfNeeded()` and `verifyAndRepair()` state the residual.
- correct 2 (blocking, lookups on the migration launch): documented in MIGRATION.md step 3 and §4, K-11, K-15 and the
  doc comments of `CDNLocalStore`, `existingLocalURL`, `hasAsset`, `missingOrStaleAssets`, `CDNProviderFactory.install`;
  pinned by a new test. A migration-awaiting API is recorded in K-13 (not requested).
- reqs 2 / correct 3 (the provider's fetch has no app key): documented in K-5, MIGRATION.md step 4, §2 and §4, and the
  doc comments of `fetchManifest()`, `verifyFullyAvailable()` and the coordinator's `cdn`; pinned by a loopback test
  (403 without the header, 200 with it). Option (a) chosen, NEEDS-HUMAN-REVIEW; (b), a key-taking initialiser, is
  **declined for now** for the reasons in K-5 (a plain-`String` key outside `AppKey`'s redaction and redirect handling
  in the shims, for a call nothing in the carousel makes); it stays available as an additive change.
- reqs 3 (storage-location residuals): the initialiser's doc comment, K-6 and MIGRATION.md §2 and §4 now say one client
  per resolved base directory, counting the process point's client, and one legacy root per process; pinned (the
  `.caches` collision).
- reqs 4 (the `installed` setter untested): `setInstalled(_:on:)` seam, tested on a local point (K-2).
- reqs 5 (MIGRATION.md cited K-1…K-13): now K-1…K-15.
- reqs 1 (ownership of `docs/MIGRATION.md`): unchanged, for the orchestrator at merge (this draft's header).
- reqs 6 / correct 4 (P-13): not WP-K's (no source or benchmark file changed); one run recorded in the evidence.

## Orchestrator rulings (close-out)
The rulings of `.build-orchestrator/l5k-rulings.md` (L5K-R1…R12), recorded as made; where a ruling and an earlier
entry of this draft disagree, the ruling wins.

- **Orchestrator ruling (close-out), L5K-R1 (CCR-K1 as a class; R-STO-11).** While legacy migration is pending or
  running, no transfer starts for an asset whose prior-art file can still be adopted, whatever created the job. Done
  with option (b) in the one funnel: the pre-transfer read `answeredFromStore` asks `store.adoptLegacyNow(id)` instead
  of `store.location(for:)` while `state.migration.pending`, so the file is adopted and the job answered from the store
  as for a present asset (L4-R5); with no migration pending the read is the old O(1) location read. The parked launch
  run is settled (a run that starts while it waits takes its place). Failing tests first (`e4cd072`, 6 tests, 14 issues
  in 3 of 3 runs), then the fix (`9fe92fc`); the transfer paths, the parked run, the store's serialisation and the C2
  measurements are in "L5K-R1: every transfer path during legacy migration". WP-K's part: the tripwire is strict, the
  resumed-migration shim test exists, and MIGRATION.md step 4 and §4, K-7 and K-15 say the launch-task sync is safe
  (`3cd3768` and the docs commit). Runs: below ("Evidence (close-out cycle 1)").
- **Orchestrator ruling (close-out), L5K-R2 (timing dependence as a class).** The CCR-K1 test's post-condition is
  deterministic (strict on the assets not downloaded, which after L5K-R1 is all of them; no `.syncStarted(_, .launch)`
  wait), and L5-R14's enumeration, patterns (a)–(g) plus the auto-advancing clock, covers every test of
  `Tests/ZTronAssetCompatibilityTests` and every harness helper: "L5K-R2: the compatibility tests' timing dependence".
  Stress evidence in "Evidence (close-out cycle 1)".
- **Orchestrator ruling (close-out), L5K-R3 (K-10, the auto-advancing clock).** Accepted with conditions; recorded in
  K-10 with how each condition is met.
- **Orchestrator ruling (close-out), L5K-R4 (the migration window's scope).** Every passage now says "a launch on which
  legacy migration is still adopting the prior art's files: the first one after adoption, and any later launch that
  resumes an interrupted migration": MIGRATION.md step 3, step 4 and §2's and §4's rows, K-7, K-11, K-15, the CCR-K1
  header's status, and the doc comments of `CDNLocalStore` (type, `existingLocalURL`, `hasAsset`,
  `missingOrStaleAssets`), `CDNProviderFactory.install` and `CDNSyncCoordinator` (`syncIfNeeded()`,
  `verifyAndRepair()`). "Harmless on later launches" is gone. What remains is K-15's lookup window, which the shims
  cannot close without main-thread I/O (C2).
- **Orchestrator ruling (close-out), L5K-R5 (`existingLocalURL`'s lifetime).** Documented: K-11, MIGRATION.md §2's row
  and §4, and `existingLocalURL`'s doc comment carry ADR-017's consumer contract.
- **Orchestrator ruling (close-out), L5K-R6 (the monitor's retry trigger).** Documented, no behaviour change: K-8,
  MIGRATION.md §2's row and §4, the monitor's doc comments.
- **Orchestrator ruling (close-out), L5K-R7 (K-8).** Approved as decided; recorded in K-8 (a second path monitor in the
  process is acceptable for a shim; not NEEDS-HUMAN-REVIEW).
- **Orchestrator ruling (close-out), L5K-R8 (the NEEDS-HUMAN-REVIEW shim decisions).** Approved as the safest defaults:
  K-2 (write-once install point; `installed = nil` and re-installation ignored), K-3 (`@MainActor` lookups, pinned by
  `PriorArtCallSiteTests`), K-5 (the providers describe a tier and no longer download; the app key by option (a),
  documentation and a manifest source that sends the key; option (b) declined), K-6 (one client per install point;
  `CDNLocalStore(baseDirectory: X)` roots the store at X's parent `/ZTronAssetKit/v1`; one store per parent directory;
  the shared registry declined as global mutable state), K-15 (the lookups' window during migration, as rescoped by
  L5K-R4). Each keeps its tag here for ADR-055 and DECISIONS.md's owner review list.
- **Orchestrator ruling (close-out), L5K-R9.** K-7's `.complete` mapping of a run whose manifest was not fresh: accepted
  (K-7). K-11's inherited behaviour differences: accepted, documented and pinned as they are (K-11). K-13: no public read
  of the applied manifest in Level 5, an owner option (K-13). The partial pin of the coordinator's `.complete` on an
  app-version change: accepted as recorded (K-7, MIGRATION.md §3).
- **Orchestrator ruling (close-out), L5K-R10 (ownership).** `docs/MIGRATION.md` is WP-K's file; the docs level adds a
  "Files WP-K added" paragraph to ARCHITECTURE §1.2. This close-out wrote only WP-K's §1.2 files, `docs/MIGRATION.md`
  and the files L5K-R1 authorises (next section).
- **Orchestrator ruling (close-out), L5K-R11 (benchmarks).** WP-K owns no benchmark: no benchmark was run. The C2
  figures L5K-R1 asks for come from a release-mode probe written for the purpose and removed afterwards (never
  committed), filtered to itself, not from the benchmark suite (next section).
- **Orchestrator ruling (close-out), L5K-R12 (coverage).** The gate's per-target figures must not drop (Sync ≥ 90 %,
  Storage ≥ 90 %, Kit ≥ 70 %); WP-K's own measure is llvm-cov over `Shims/*.swift` in the compatibility bundle, ≥ 70 %;
  the uncovered lines listed in the round-2 evidence are accepted as listed. Figures in "Evidence (close-out cycle 1)".

## Authorised edits outside WP-K (close-out)
Under L5K-R1 only, internal state and bodies, no public or package signature changed; ownership unchanged (WP-F's):

- `Sources/ZTronAssetSync/Engine/EnginePresence.swift`: `answeredFromStore` reads each id through the new internal
  `storedLocation(of:)` (`store.location(for:)`, or `store.adoptLegacyNow(id)` while `state.migration.pending`; a thrown
  `StoreError` reads as "nothing stored"); its doc comment says so; the await cites f-11 and k-4 (proposed).
- `Sources/ZTronAssetSync/Engine/EngineRuns.swift`: `startRun` clears `state.migration.launchRunWaiting` once its run
  is in place (the run takes the parked launch run's place); the migration loop's `defer` always clears the flag and
  starts the launch run only when the flag was still set and the engine runs; both doc comments say so.
- `Sources/ZTronAssetSync/Engine/EngineState.swift`: `MigrationProgress.launchRunWaiting`'s doc comment.
- `Sources/ZTronAssetSync/Engine/EngineLifecycle.swift`: authorised, not changed (`start()` still parks the due launch
  run while migration runs).
- New: `Tests/ZTronAssetSyncTests/Engine/EngineLegacyMigrationTransferTests.swift` (6 tests, failing first at `e4cd072`).

No store file changed (`ZTronAssetStorageTests` once: 445/445), and no Kit file (`ZTronAssetKitTests` ×3: 85/85 each).

## L5K-R1: every transfer path during legacy migration
- **The funnel.** Every transfer the engine starts goes through one place: `EngineDispatch.start(_:probe:)` spawns the
  attempt's driver, and the driver either publishes a file an earlier attempt already staged (`publishDrained`: no
  request, no bytes) or runs `drive`, whose first step is `answeredFromStore` and whose second is `remote.transfer`. So
  every attempt, whatever interest created its job, asks the store before any bytes, and while
  `state.migration.pending` that question is `adoptLegacyNow`. `pending` is set in the turn the lifecycle becomes
  `running` (`EngineLifecycle.swift`, before any `pump()` can dispatch: `pump()` requires `isRunning`) and cleared only
  when `migrateLegacy` reports `finished` (every legacy file adopted, dropped or kept, tree and key removed); a
  deferred migration keeps it. The paths that create a job, each through `addInterest`, so each through the funnel:

  | Path | How it creates the job | Pinned by |
  |---|---|---|
  | A run of any trigger: the launch run, an explicit `sync(.ifDue)`/`sync(.force)` (the coordinator's `syncIfNeeded()`/`verifyAndRepair()`), a pending run (`conditionsChanged`, `breakerClosed`, `afterPurge`) | `materializeRun` → `.run` interests | `R-STO-11: an explicit sync during legacy migration adopts every prior-art file still pending and downloads none (CCR-K1)`; the two shim sync tests (K-15) |
  | `ensureAvailable` | `ensureTask` → its group's fetches → `materializeEnsures` → `.ensure` interests | `R-STO-11: ensureAvailable during legacy migration adopts the prior-art files instead of downloading them (CCR-K1)` |
  | A prefetch join (`registerGroup`, a `PrefetchHandle`) | `joinGroup` → `joinMember` → `.prefetch` interests | `R-STO-11: a prefetch group joined during legacy migration adopts the prior-art files instead of downloading them (CCR-K1)` |
  | A resolve (`awaitAsset`, `AssetClient.resolve`, the shims' `resolveViaNetwork`), and a lease of an asset not present (it goes through the resolve) | adopts on demand itself first (ADR-029); only a `nil` answer registers a `.waiter` interest, whose job then asks the funnel again (a cheap repeat: the file is no longer queued) | `R-STO-11: a resolve during migration adopts that legacy file first and never waits for the whole catalog` (WP-F); the shim lookups test (K-15) |
  | A reroute (`followApplied`: interests follow their asset's entry to new content when a new manifest is applied) | moves the interest to the new content's job | by construction (the same `start` → `drive`); a prior-art file holds the old content, so it is adopted only if the new entry names the same digest |
  | A `.system` interest: launch reconciliation's `.attach` of a background transfer an earlier launch started, a heal after a quarantine | `addSystemInterest` | by construction (its attempt passes the funnel like any other); an attach for a prior-art file needs a background transfer an earlier launch started for it, which only the pre-fix engine or a file that could not be adopted could cause |
  | The parked launch run | starts in the migration loop's `defer`, after `pending` is cleared, or with `pending` still set when the loop backed off | `R-STO-11: the launch run waits for legacy migration and downloads nothing it adopted` (F-8); the two parked-run tests below |
  | A later launch that resumes an interrupted migration | `open()` reports `legacyMigrationPending` again, so every path above meets the same funnel | `R-STO-11: a later launch that resumes an interrupted legacy migration adopts, never downloads, the prior-art files an explicit sync asks for (L5K-V3-06)`; the shim twin |

  Two exits stay as they were, neither a transfer of a file migration can still adopt: an attempt the funnel finds no
  longer current after its reads goes on to `remote.transfer` and cancels the request at once (RE-S12, f-11; the drain
  protocol needs the handle), by which time that very read has adopted the file; and a prior-art file that cannot be
  adopted (its bytes do not verify, it vanished, it was kept after `legacyAttempts` deferrals, or the store refused) is
  downloaded, as R-STO-11 and C-12…C-14 intend.
- **The parked launch run (decided).** `start()` parks the due launch run while migration runs (`launchRunWaiting`). The
  migration loop's `defer` used to start it when migration ended, and `startRun` is a no-op while a run is active, so
  whether it ran depended on timing: dropped when an explicit run was still active at the end of migration, run a second
  time when that explicit run had finished first. Options: (a) the run that started meanwhile satisfies the launch's
  sync; (b) the launch run starts after it. **Decision: (a)**, made deterministic: any run that starts while the launch
  run waits takes its place (`startRun` clears the flag in the turn its run is in place), and the `defer` starts the
  launch run only if the flag is still set, clearing it in every case (shutdown included: the `defer` runs when shutdown
  joins the loop's task). Reasons: since L5K-R1 that run does the launch run's work (it applies the same manifest and
  its jobs adopt the files migration has not reached), so one launch syncs once, with no second manifest request and no
  second `syncStarted`/`syncFinished` pair after a sync the app asked for; and the outcome no longer depends on which of
  the two ends first. A run that fails or is blocked leaves the sync due exactly as a failed launch run would (a blocked
  run keeps its pending run; a purge's cancellation makes the next sync due). Pinned: `R-STO-11: a run that starts while
  the launch run waits for legacy migration takes its place, so no launch run follows once migration ends` (the explicit
  run finishes first: one run, one manifest request, no flag or joiner left) and `R-STO-11: when legacy migration ends
  while the run that took the launch run's place is active, no launch run follows it and no flag is left` (a held
  transfer keeps the run active across the end of migration). With no run started during migration, the launch run
  still starts when the loop ends (`R-STO-11: the launch run waits for legacy migration and downloads nothing it
  adopted`, F-8; the shim lookups test waits for exactly that run).
- **Store serialisation (row k-4).** The store already orders an on-demand adoption against the migration loop's:
  `performAdoptLegacyNow` moves a queued file to `claimed` before hashing it, so no batch takes it; a file a batch has
  claimed may be hashed by both calls, and `processLegacyFile` and `adoptVerifiedFile` re-validate the records after
  every await (rows R17, R18), so the first placement binds and the other call finds the file adopted (`alreadyAdopted`)
  and reads the location from the record. The resolve path has relied on this since L3; the funnel uses the same call.
- **C2.** One `adoptLegacyNow` per id of a job, only while migration is pending, after a job was dispatched; the hash
  runs on the store's bulk executor and the placement on its metadata executor, never on the main actor; the engine's
  actor only awaits. Correction of the ruling's premise: `adoptLegacyNow` publishes its snapshot at `.userInitiated`,
  which the store's install-rate limiter does not coalesce (`AssetStore+Snapshot.swift`: only other urgencies wait for
  the install window), so each adoption by a job installs one snapshot at once, as each resolve's adoption already did:
  1,000 installs for 1,000 files adopted by a sync while migration is held (below), each an O(1) swap on the main
  actor (`SnapshotMirror.install`). Measured by a release-mode probe (`swift test -c release --scratch-path
  .build-k-perf -Xswiftc -enable-testing --filter ProbeL5KR1`, a temporary file in the benchmarks target, removed and
  never committed; macOS 27, load average 3.1–4.7): an engine over a real store on `FakeFileSystem` with `N` prior-art
  files of 4 KiB, then `sync(.force)` while two high-priority heartbeats call into the engine's actor and the store's
  actor back to back (`SyncBench.longestWait`'s method: a heartbeat's longest wait bounds the longest turn it queued
  behind). Migration either held at a unit of its first file (so the sync's jobs adopt every file) or running
  concurrently on inline executors. Three runs per case (one at 10,000):

  | Files | Migration | Engine's longest turn (ms) | Store's longest turn (ms) | Sync (s) | Adopted by the sync's jobs | Transfers | Snapshot installs |
  |---|---|---|---|---|---|---|---|
  | 150 | held | 0.084, 0.084, 0.088 | 0.113, 0.114, 0.115 | 0.13–0.15 | 149 of 149 pending | 0 | 150 |
  | 150 | concurrent | 0.091, 0.096, 0.123 | 0.151, 0.176, 0.179 | 0.12–0.13 | 142–143 answered from the store | 0 | 23–34 |
  | 1,000 | held | 0.170, 0.171, 0.172 | 0.350, 0.352, 0.371 | 0.67–0.96 | 999 of 999 pending | 0 | 1,000 |
  | 1,000 | concurrent | 0.180, 0.186, 0.288 | 0.451, 0.465, 0.475 | 1.11–1.46 | 973–981 answered from the store | 0 | 147–153 |
  | 10,000 | held | 1.589 | 1.084 | 9.21 | 9,999 of 9,999 pending | 0 | 10,000 |
  | 10,000 | concurrent | 1.949 | 2.295 | 15.12 | 9,756 answered from the store | 0 | 687 |

  Every turn stays far inside C2's 10 ms at SPEC §6's scale; the store's per-call queue search (one linear search per
  on-demand adoption, `performAdoptLegacyNow`) and the snapshot copy grow with the catalog, which the 10,000-file row
  bounds. Not a device measurement (Not verified here).

## L5K-R2: the compatibility tests' timing dependence
Every test of `Tests/ZTronAssetCompatibilityTests` (70 in 10 suites, the orchestrator's `CompatibilityShimTests.swift`
included, read only) and every harness helper was read against L5-R14's patterns: (a) a wait on a weaker condition than
the assertion needs; (b) a shared fake log counted without a baseline taken at a defined point, or counting what another
engine generation may have added; (c) a fake scripted after an operation that may already consult it; (d) a bounded
number of yields or rounds; (e) a lower bound on, or an exact count of, events a consumer happened to pull; (f) a clock
move racing a driver that has not applied the previous step; (g) a fake-volume mutation in several steps that races the
store's own writes; and L5K-R2's addition, an outcome that depends on whether the engine processed a step before
`AutoAdvancingClock` moved (K-10).

| Test (file: function) | Pattern | Fix |
|---|---|---|
| `MigrationLaunchShimTests: launchSyncDuringLegacyMigration` (L5K-V3-04) | (a): `legacyLeft == 0` waited only for the resolves, while the CCR-K1 downloads left legacy copies for the migration loop or phase 4 to remove later (5 of 6 TSan runs failed); `stored` read the lookups' snapshot, which shows a running batch's adoptions only at the batch's end | After L5K-R1 the post-condition is strict at the sync's return: no transfer at all; every prior-art file out of the tree (each planned file was adopted before its job ended, each unplanned one was present when the run planned); stored read through `availability(scope:)`, the store's state, which the sync's completion orders. The resolves and the known-issue wrapper are gone, and nothing waits for `.syncStarted(_, .launch)` (a run took the launch run's place, so none follows) |
| `MigrationLaunchShimTests: lookupsDuringLegacyMigration` | (a): "all 40 (formerly 320) answer" right after the resolves over a running migration: a resolve that finds a file a still-running batch adopted answers from the store, and that file reaches the lookups only at the batch's end | The migration is held at a unit of its first file (`startHoldingMigration`) while the resolves run (`releaser`), so every adoption in the window is a resolve's, installed before it returns; "none answers after `start()`" replaces "fewer than all" (a held state, not a count race); "all answer" waits for `.syncStarted(_, .launch)`, the launch run the migration loop's end starts when no run took its place (L5K-R1's decision; no other run starts in this test, and the subscription is registered while the migration is held, so the event cannot be missed) |
| `MigrationLaunchShimTests: launchSyncDuringResumedMigration` (new) | written against the patterns | Launch 1's interruption is ordered by events, not timing: the sync's run has started (`EventProbe`), and its joiner is answered in the shutdown turn that cancels the migration; launch 2's post-conditions are the strict ones of the first row |

Checked, no pattern:
- `CompatibilityShimTests` (3, the orchestrator's file): pure.
- `ConfigurationShimTests` (9): synchronous, no client started.
- `LegacyAPIShimTests` (12): `legacyStoreKeepsThePriorArtLayout`, `localURLStaysInsideTheLegacyRoot`,
  `pathAndChecksumHelpers`, `cacheManifestKeepsTheFirstEntry`, `reconcileRecordsOnly`, `storeRefusesExternalFiles`
  (synchronous; the two real directories are per-test under `.build-tests/compatibility/`, touched by no store);
  `legacyStoreStartsOnAFreshInstall`, `legacyStoresInOneParentShareOneRoot`, `legacyStoreInCachesSharesTheCachesRoot`
  (awaited `start()` calls); `localURLIsTheStoredBlob`, `legacyInitialisersShareOneClient` (a settled launch, then
  awaited calls); `legacyStoreAdoptsThePriorArtFiles` (one prior-art file: if its batch adopts it, the batch binds the
  record and installs its snapshot with no await in between, so a resolve that finds the file present runs only after
  the install was handed to the main actor, ahead of the test's continuation; if the resolve adopts it, it installs
  before returning; its `starts.isEmpty` counts a fresh source, and since L5K-R1 no job downloads the file either).
- `LocalStoreShimTests` (10): settled launches (`settleLaunch()`); baselines for `manifestRequests`, `mainThreadCalls`
  and `starts` taken right before the call; `staleAssetServesItsOldBytes` waits for the probe's `syncProgress` with a
  completed asset (the subscription precedes the sync) and holds the republished icon's transfer; the two replacement
  tests read after `sync` returned; `lookupsWaitForTheStartedClient` counts one transfer over a defined history (launch
  1's only one; launch 2 is not due); `sharedStoreFollowsTheProcessInstallPoint`, `storeFollowsItsInstallPoint`
  synchronous after a settled launch.
- `NetworkMonitorShimTests` (5): each run is awaited through `RetryLog.ran` (an `AsyncStream`, its `next()` ends on
  cancellation), registrations through `flush()`, observation through the census `requireObservers(equalTo:)`; no
  client clock (`retryRunsWhileTheClientIsIdle` waits for the idle engine's census of 0 first).
- `PriorArtCallSiteTests` (1): synchronous.
- `ProviderShimTests` (7): each loopback server and session is the test's own; every request is awaited before
  `server.requests` is read; no clock.
- `ResolverShimTests` (6): settled launches; baselines right before the resolve; `failuresAnswerNil` scripts its three
  manifest answers before the first call; the two install-point tests are synchronous.
- `SyncCoordinatorShimTests` (14): settled launches under `.atMostEvery(3600)`; every script is written while the client
  is idle, before the call; baselines right before the call; `progressReportsSyncing` waits for its own collector's
  signal of a `.syncing` value before releasing the held poster, so its `!counts.isEmpty` is what the wait established,
  and its other assertions (monotone, `total == 2`) hold for any subset of the values; `dueAndNotDue`'s `changes >= 1`
  counts synchronous `objectWillChange` emissions of a call that publishes before it returns (a Combine sink, not an
  asynchronous pull); `blockedRunReportsFailed` subscribes before it opens the gate and waits for the pending run's
  `syncProgress`; `oncePerAppVersionAcrossLaunches` counts one manifest request per due launch over a defined history.
- **The auto-advancing clock (K-10).** A move happens only inside `sleep(until:)`, to the deadline of the sleep being
  registered (within 1 s), so it can never run ahead of the step that registered it: the store's short windows (commit
  window, commit retry), the engine's trailing progress emission and the blocked-run test's 0.5 s debounce pass when
  their sleeper registers. No assertion waits for a move: each waits for a public condition (`sync`'s, `resolve`'s or
  `start()`'s return, the coordinator's published progress, an `EventProbe` event, a census). The explicit
  `time.advance(by: 3601)` of five coordinator tests runs while the client is idle (launch settled; no run, job or
  engine timer, R-SYN-14), so no engine step is in flight for it to race (f); the only sleepers it can pass then are
  store windows, which no assertion depends on.
- **Harness helpers.** `AutoAdvancingClock` (above); `CompatFixture`, `ScriptedCDNProvider`, `KeyedManifestSource`,
  `CompatHarness.make`/`environment`/`serve`/`serveManifest`/`starts(after:)`/`relaunch` (no waits); `settleLaunch()`
  (waits for `sync(.ifDue)`'s return, which joins the launch run or answers `.notDue` after its stamp, and records an
  issue otherwise); `startHoldingMigration` and `releaser` (new: census waits and a cancellable joiner of the
  single-flight `start()`, every wait ending on cancellation); `PriorArtTree` (seeds the fake volume before any client
  starts, so no (g)); `AdoptionLaunch` (reads); `RetryLog` (above); `EventProbe` (WP-H's, ends on cancellation).
  Pattern (d) occurs nowhere in the target, and pattern (g) nowhere: the fake volume is mutated only before a client
  starts.

## Close-out cycle 1 — the round-3 issues and what became of them
- L5K-V3-05 (blocking, CCR-K1 needs a ruling) and L5K-V3-00: ruled (L5K-R1) and fixed in WP-F's engine under
  authorisation, failing tests first; WP-K's wrapper removed. See "L5K-R1: every transfer path during legacy migration".
- L5K-V3-04 (blocking, the CCR-K1 test races the end of migration under TSan): fixed (L5K-R2's first table row); the
  compatibility target under TSan: evidence below.
- L5K-V3-01 and L5K-V3-06 (the window is not only the first launch after adoption): rescoped everywhere (L5K-R4); the
  resumed launch pinned in the engine and through the shims.
- L5K-V3-07 (`existingLocalURL`'s lifetime): documented (L5K-R5; K-11).
- L5K-V3-08 (the monitor also retries on power and thermal reports): documented (L5K-R6; K-8).
- L5K-V3-02 and L5K-V3-09 (ownership of `docs/MIGRATION.md`): WP-K's file (L5K-R10); the "Files WP-K added" paragraph
  of ARCHITECTURE §1.2 is the docs level's.
- L5K-V3-03 and L5K-V3-10 (P-13 and the C2 benchmarks under load): not WP-K's; no benchmark run (L5K-R11).

## Not verified here
- The shims at the iOS 15 floor at run time: the test target builds at iOS 17 / macOS 14 (ADR-051), the shims run on the
  iOS 27 simulator and macOS 27 only; their iOS 15 compile is the typecheck recorded in the evidence below.
- `NetworkAvailabilityMonitor.shared` over the live reachability conformer, `StaticManifestCDNProvider` against a real
  origin, `defaultAppVersion()` inside an app bundle, `BackgroundAssetsCDNProvider` on a device.
- `CDNLocalStore(baseDirectory:)`'s placement and migration over the live file system in an app container (the tests run
  them on `FakeFileSystem`), and the 403 a keyless client gets from the real origin (SPEC §2.3, not exercised here).
- Adoption inside ZTronCarouselCore (Q-10, ADR-006): MIGRATION.md describes it; nothing outside this repository was
  built or written.
- A launch during legacy migration on a device (K-15): how long migration takes over a real prior-art tree, hence how
  long the lookups miss its files; the tests run it on `FakeFileSystem` with inline or stepped executors. The C2 figures
  of an adoption by a sync (L5K-R1) come from a release-mode probe on macOS 27, not a device, and the main actor's cost
  of one snapshot install per adopted file was not measured on a device (each is an O(1) swap there).
- That the main actor runs its jobs in the order they were enqueued, which `legacyStoreAdoptsThePriorArtFiles`'s
  determinism argument uses (L5K-R2): taken from the main executor's serial queue, not tested here.

## Evidence (close-out cycle 1; macOS 27, Xcode 27.0, Swift 6.4; scratch `.build-k`, `.build-k-tsan`, `.build-k-perf`)
- **Failing first (L5K-R1).** The six engine tests on the pre-fix engine (`e4cd072`), `swift test --skip-build
  --scratch-path .build-k --filter EngineLegacyMigrationTransferTests`, 3 consecutive runs: `✘ Test run with 6 tests in 1
  suite failed after 0.018 seconds with 14 issues.` each; every issue is the defect's own assertion (`starts.isEmpty` in
  the four download tests; the parked flag, `left.runs == 1` and `manifestRequests.count == 1` in the parked-run tests),
  none a hang. With the fix (`9fe92fc`): `✔ Test run with 6 tests in 1 suite passed` in 3 of 3 runs. The strict shim
  tests on the pre-fix engine (the three engine files checked out from `e4cd072`, built, run 3 times, restored): every
  run failed, `downloaded.isEmpty` (30, 38 and 42 of 150 for the CCR-K1 test; 6, 6 and 18 of the 148 files left on the
  resumed launch) and `legacyLeft == 0` (5 of the 6 runs of those two tests); the lookups test passed.
- `SWIFTPM_SCRATCH=.build-k bash Scripts/verify.sh --quick` on `3657f80`: `VERIFY: PASS` (Model 151, Sync 329, Storage
  445, Transport 84, Kit 85, Compatibility 70, AppleHosted 104 tests).
- **The engine's runs (L5K-R1).** `ZTronAssetSyncTests` ×3: `✔ Test run with 329 tests in 52 suites passed` each (load
  4.1–4.5); under TSan: `✔ Test run with 329 tests in 52 suites passed after 23.991 seconds.`, no ThreadSanitizer report
  (load 4.3–5.2); `ZTronAssetStorageTests` once: 445/445; `ZTronAssetKitTests` ×3: 85/85 each (load 11.1–12.3, a release
  build ran meanwhile).
- **The compatibility target.** ×3: `✔ Test run with 70 tests in 10 suites passed` each (load 3.5); under TSan: 70/70,
  no ThreadSanitizer report (load 7.0).
- **Stress (L5K-R2).** ×20 with the 1-minute load average at 41.3 to 172.5 before each run (the simulator test run beside
  it): 20 of 20 `✔ Test run with 70 tests in 10 suites passed`; ×5 under TSan (load falling from 156.5 to 10.8): 5 of 5
  passed, no ThreadSanitizer report; the simulator run below includes the target.
- **Release build** (`swift build -c release --scratch-path .build-k -Xswiftc -warnings-as-errors`): `Build complete!`.
- **Gates.** `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`; the shims through `gates.py`'s
  `docs_check` and `unsafe_check` in memory: `DOCS public declarations=90 documented=90`, `UNSAFE escapes found=0`;
  `gates.py trace` written to `.build-k/trace-check.md` (never to `docs/TRACEABILITY.md`): `TRACE requirements=90
  (MUST=78) budgets=14 tests-with-ids=1144`, `TRACE: PASS`; `gates.py selftest`: `SELFTEST: PASS`.
- **Coverage** (`swift test --scratch-path .build-k --enable-code-coverage --skip Benchmarks`, the merged export over the
  seven test bundles, `gates.py coverage`): AppleHosted 99.76 %, Kit 97.90 % (1445/1476), Model 99.31 %, Storage 97.37 %
  (7973/8188), Sync 93.63 % (8434/9008), Transport 99.08 %, `COVERAGE overall lines=96.62% (24800/25668)`,
  device-only share 0.68 %, `COVERAGE: PASS` (L5K-R12: no per-target figure dropped). The shims in the compatibility
  bundle (`llvm-cov report` over `Shims/*.swift`): 98.18 % (538/548), the uncovered lines of round 2 unchanged.
- **iOS.** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-k/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, no diagnostic (xcodebuild's one informational line
  `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.`).
- **iOS Simulator** (iPhone 18 Pro `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0, the task's command under
  `caffeinate -i`, on `3657f80`): `** TEST SUCCEEDED **`; `xcresulttool … summary`: `result: Passed`, 1,268 tests, 1,268
  passed, 0 failed, 0 skipped, 0 expected failures (CCR-K1's known issue is gone)
  (`Test-ZTronAssetKit-2026.10.23_17-51-45-+0200.xcresult`); the simulator is shut down.
- **C2 (L5K-R1).** The table in "L5K-R1: every transfer path during legacy migration": a release-mode probe filtered to
  itself, removed afterwards; no benchmark was run (L5K-R11).
- **Writes.** Nothing outside the repository except the simulator's device container (ADR-051). `TMPDIR`, the module
  caches and `LLVM_PROFILE_FILE` under `.build-k/tmp`, derived data under `.build-k/xcode*`; the tests write real files
  only under `.build-tests/compatibility/` and remove them; the probe file was deleted before any commit; `python3 -B`,
  so no `Scripts/__pycache__`.

## Evidence of fix round 2 (history; macOS 27, Xcode 27.0, Swift 6.4; scratch `.build-k`; code at `409db9a`)
- Test first. Round 1: the round-1 tests on the round-0 shims (`82490e7`) failed with 12 issues, all passed after
  `e81449c` (K-12). Round 2: the CCR-K1 test without its `withKnownIssue` wrapper, `swift test --skip-build --filter
  MigrationLaunchShimTests`, 15 consecutive runs at a load average of about 5: 15 of 15 failed `downloaded == 0` (6 to
  41 of 150 prior-art files downloaded, K-15), with no other expectation failing; the lookups pin passed 15 of 15. With
  the wrapper, `swift test --skip-build --filter ZTronAssetCompatibilityTests` 10 consecutive times while the simulator
  run loaded the host (load average up to 139): 69/69 each, no known issue recorded (migration won the race), the
  lookups pin passed 10 of 10. The `installed` seam's test against a mutant seam that drops its value (built, run,
  reverted): `failed … with 3 issues`.
- `SWIFTPM_SCRATCH=.build-k bash Scripts/verify.sh --quick` on `409db9a`: `VERIFY: PASS` (Model 151, Sync 323, Storage
  445, Transport 84, Kit 85 tests; Compatibility 69 tests `passed … with 1 known issue`, CCR-K1; AppleHosted 104). The
  same on `9cf19be`: `VERIFY: PASS`, the same counts.
- `swift build -c release --scratch-path .build-k -Xswiftc -warnings-as-errors`: `Build complete!`.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`. Both scan `Sources/`, which WP-K does not touch
  (`git diff --stat l5g-merged...HEAD -- Sources Tests/ZTronAssetKitBenchmarks Package.swift Scripts` is empty). The
  shims, through `gates.py`'s own `docs_check` and `unsafe_check` over their contents in memory: `DOCS public
  declarations=90 documented=90`, `UNSAFE escapes found=0`. `gates.py selftest`: `SELFTEST: PASS`; `gates.py trace`
  written to `.build-k/trace-check.md` (never to `docs/TRACEABILITY.md`): `TRACE requirements=90 (MUST=78) budgets=14
  tests-with-ids=1137`, `TRACE: PASS`.
- Coverage (`--quick`'s `swift test --enable-code-coverage --skip Benchmarks` on `409db9a`, the merged export over
  every bundle, `gates.py coverage`): every target OK (AppleHosted 99.76 %, Kit 97.90 %, Model 99.31 %, Storage
  97.37 %, Sync 93.56 %, Transport 99.08 %), `COVERAGE overall lines=96.60% (24774/25647)`, `COVERAGE: PASS`. The shims
  sit in a test target, outside the gate; `llvm-cov export` of the compatibility bundle over `Shims/*.swift`: 98.18 %
  (538/548, round 1: 533/545). Not covered: the `installed` setter's one call (the process point, which no test fills;
  its body is the tested seam, K-2), the deprecated coordinator initialiser's body (it constructs `UserDefaults`, K-9),
  the default argument of `CDNLocalStore.init(baseDirectory:computeChecksum:)` (reached only through a protocol), the
  fallback of `defaultLegacyRoot()`, one line of the Stage 1 `CDNAsset.swift`.
- iOS: `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-k/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, no diagnostic (`** BUILD SUCCEEDED **` without `-quiet`;
  incremental, `Sources/` unchanged since round 1).
- The floors, with the compiler: the shims alone typecheck through the public API only: `xcrun --sdk iphoneos swiftc
  -typecheck -swift-version 6 -target arm64-apple-ios15.0 -warnings-as-errors -I
  .build-k/xcode/Build/Products/Debug-iphoneos Tests/ZTronAssetCompatibilityTests/Shims/*.swift` exit 0; the same with
  `--sdk macosx -target arm64-apple-macos12.0 -I .build-k/out/Products/Debug` exit 0 (module caches under `.build-k/tmp`).
- iOS Simulator (iPhone 18 Pro `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0, the task's command under
  `caffeinate -i`, on `9cf19be`): `** TEST SUCCEEDED **`; `xcresulttool … summary`: `result: Passed`, 1,261 tests,
  1,260 passed, 0 failed, 0 skipped, 1 expected failure (CCR-K1's known issue, recorded there)
  (`Test-ZTronAssetKit-2026.10.23_15-53-36-+0200.xcresult`); the simulator is shut down.
- Benchmarks: WP-K owns none and changed none. `swift test -c release --scratch-path .build-k-perf -Xswiftc
  -enable-testing --filter Benchmarks` (load average 24 falling to 3.7, right after the simulator run): 35 tests, 1
  issue, again P-13 `longest <= batchBudget`: unit max 9.65 ms wall against 5.0 ms (1.02 ms on CPU; p50 0.96 ms, p95
  0.99 ms), six units over budget, each under 0.79 ms on CPU, blob unlinks inside the reclaim max 9.00 ms (7 over
  4.0 ms) against a volume unlink profile with p99 0.065 ms and max 18.7 ms: the wall-time stalls in single unlinks of
  rounds 0 and 1, WP-B's budget, not WP-K's.
- Writes: nothing outside the repository except the simulator's device container (ADR-051). `TMPDIR` and the module
  caches were under `.build-k/tmp`, derived data under `.build-k/xcode*`; the tests write real files only under
  `.build-tests/compatibility/` and remove them. Two strays of this round inside the worktree were removed before
  committing: a `default.profraw` (an instrumented test binary run without `--enable-code-coverage`) and
  `Scripts/__pycache__/` (the in-memory gate check; `python3 -B` since).
