# Migrating ZTronCarouselCore to ZTronAssetKit through the R-CAR-6 shims

The shims keep every public symbol of the prior art's `ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/` compiling, as
adapters over one `AssetClient` (SPEC R-CAR-6). Under the owner's standalone directive (ADR-006) they live in this
repository, in the test target `ZTronAssetCompatibilityTests` (`Tests/ZTronAssetCompatibilityTests/Shims/`, ADR-033),
where they are compiled and exercised against a real client over fakes; nothing in ZTronCarouselCore or ZTronCarousel
was changed. Adoption is the owner's follow-up, described here. Decisions and their reasons: `docs/adr-drafts/k.md`
(K-1…K-15).

## 1. Adoption, step by step

1. **Depend on the package.** In ZTronCarouselCore's `Package.swift`, add `.package(path: "../ZTronAssetKit")` (switch it
   to the repository URL and a version on release) and the product `ZTronAssetKit` to the `ZTronCarouselCore` target. iOS
   15 is the floor both packages share; macOS 12 is this package's own (ZTronCarouselCore declares only iOS). Build
   ZTronCarouselCore with a Swift 6.2 or newer toolchain: it compiles this package's sources, which use `@concurrent`
   ([ADR-056](DECISIONS.md), awaiting the owner's confirmation).
2. **Replace `CDN/`.** Delete the nine prior-art files of `Sources/ZTronCarouselCore/CDN/` and copy the eleven files of
   `Tests/ZTronAssetCompatibilityTests/Shims/` in their place. They import `Foundation`, `ZTronAssetKit` and, for
   `CDNSyncCoordinator`, `Combine`; they use only the package's public API (K-1). Keep their `public` access: the app and
   ZTronCarousel reach them through ZTronCarouselCore.
3. **Build one client at launch and start it** before any carousel content is created:

   ```swift
   // On the main actor (for example in the App's init): no I/O, no task (P-12).
   let client = CDNProviderFactory.install(CDNConfiguration(
       baseURL: URL(string: "https://<distribution>.cloudfront.net/")!,
       appKey: AppKey(<the app key, never logged>),
       appleHosted: AppleTierConfiguration(),          // the client picks this tier on iOS 26+
       refreshPolicy: .oncePerAppVersion
   ))
   // In the launch task (for example the root view's .task), before the first carousel page is created:
   try await client.start()
   ```

   Pass `appleHosted` only in a build that ships the Apple-hosting setup (the downloader extension, its Info.plist keys
   and App Group, and the packs): a configured `appleHosted` has no fallback, so on iOS 26 and later the client selects
   that tier whether or not the setup exists ([README](../README.md) "The Apple-hosted tier";
   [APPLE-API-VERIFICATION](APPLE-API-VERIFICATION.md) §1.7 (c); orchestrator ruling WPI-R7). Without it, leave
   `appleHosted` out and every device uses the CloudFront tier.

   `install` fills the process install point that `CDNAssetResolver.installed`, `CDNLocalStore.shared` and the prior-art
   initialisers follow (K-2). `start()` opens the store and installs the first snapshot, which the synchronous lookups
   read: until it has returned, `CDNLocalStore.shared.existingLocalURL` answers `nil` and `hasAsset` answers `false` even
   for assets stored in an earlier launch (ADR-037), so `BasicVideoPage.init?` would return `nil` for a stored video.
   Show carousel content once `start()` has returned (it returns when the client is ready, not when a sync finished).
   **A launch on which legacy migration is still adopting the prior art's files is the exception** (K-15): the first
   launch after adoption, and any later launch that resumes a migration an earlier launch did not finish (an app
   terminated while phase 2 hashed the prior art's bytes). The client adopts the prior art's files (legacy migration,
   R-STO-11) in batches that start only after `start()` has returned, and a prior-art file answers the lookups once the
   snapshot holding its adoption is installed: at once when a resolve adopted it on demand, or found migration adopting
   it and waited for that adoption (the client runs one adoption per prior-art file, orchestrator ruling L5K-R13); at
   the end of its batch when migration adopted it alone. Right after `start()` the files not adopted yet miss (`missingOrStaleAssets` lists them), so
   `BasicVideoPage.init?`, which has no network step, returns `nil` for such a video until then; `ZTronSVGView` falls back
   to `resolveViaNetwork`, which adopts a pending file on demand without a download. An app that must show the prior
   art's videos at once on such a launch resolves them first (`client.resolve(_:priority:)` adopts on demand too); the
   module has no call that waits for migration (K-13). This window of the lookups is the only one left: the shims cannot
   close it without file-system I/O on the main thread (C2).
   The prior art's idiom, `CDNAssetResolver.installed = CDNAssetResolver(cdn: provider)`, still compiles (deprecated) and
   builds the client from the provider (K-6), but without the app key: the process install point names no origin, and
   the origin answers 403 without the key (SPEC §2.3). Install a configured client first, as above; the idiom then
   resolves through it. A point configured with an origin and its key keeps the key for a prior-art provider at that
   origin, never at another one (K-6).
4. **Keep the coordinator** where the app ran the prior art's one (the client syncs at launch by itself, R-SYN-9):

   ```swift
   @StateObject private var coordinator = CDNSyncCoordinator(client: client, cdn: manifestSource)
   // From a user action, such as pull to refresh: await coordinator.syncIfNeeded(), or verifyAndRepair()
   ```

   The client fetches and downloads by itself; `cdn` is the manifest source of `verifyFullyAvailable()` only, and that
   fetch is `cdn`'s own request. `StaticManifestCDNProvider(baseURL:)` sends no app key (the prior art sent none), so at
   SPEC §2.3's origin, which answers 403 without one, `verifyFullyAvailable()` throws
   `StaticManifestCDNProviderError.badResponse` on every call (K-5). Pass an app-defined `CDNProviding` whose
   `fetchManifest()` sends `x-zombietron-app-key` to that origin and to no other (refusing a redirect elsewhere,
   R-NET-4), or ask the client: `client.availability(scope:)` counts what is missing against the manifest the client
   fetched with its key, with no network. `syncIfNeeded()` also starts the client, but the lookups need it started
   earlier (step 3).
   The prior art's launch call, `.task { await coordinator.syncIfNeeded() }`, is safe on every launch: it joins the
   client's launch run, answers `.upToDate`, or retries a run that failed. On a launch during legacy migration (step 3)
   it starts a run at once, and that run adopts the prior-art files migration has not reached yet instead of
   downloading them: before any transfer the client adopts a file migration can still adopt, whatever asked for it,
   even while a migration batch is adopting that same file, since the client runs one adoption per prior-art file and
   every asker gets its outcome (R-STO-11; the engine's fix of CCR-K1 and the store's single flight, orchestrator rulings
   L5K-R1 and L5K-R13, K-15). That run takes the place of the launch run
   that waited for migration, so the launch still syncs once. `verifyAndRepair()` and a call from a user action behave
   the same.
5. **Background transfers** (only if `HTTPSourceConfiguration.background` is enabled): forward
   `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `client.handleBackgroundEvents(identifier:
   completionHandler:)`.
6. **Call sites stay as they are.** `BasicVideoPage` (`CDNLocalStore.shared.existingLocalURL(identifier:candidateExtensions:)`)
   and `ZTronSVGView` (`CDNLocalStore.shared.existingLocalURL`, `CDNAssetResolver.installed`, `resolveViaNetwork`,
   `NetworkAvailabilityMonitor.shared.retryWhenAvailable` and `.cancelRetry` from `deinit`) compile unchanged: the
   lookups are `@MainActor` (K-3), and both call sites are main-actor isolated; `cancelRetry` stays nonisolated. Both
   call sites are copied, with their isolation, into `Tests/ZTronAssetCompatibilityTests/PriorArtCallSiteTests.swift`, so
   a shim change that would break them fails this repository's build.
7. **Tests.** ZTronCarouselCore has no pre-existing CDN test to keep passing or to port (`docs/BASELINE.md`: 0, the only
   test is the template `example()`), so §3's table is empty. The shim suites of this repository can be copied along as a
   characterization suite; they need `ZTronAssetTestSupport` (an internal target of this package, not a product), so they
   stay here unless the owner exports it.
8. **Later.** Move call sites to the module's own API (`AssetFallbackChain.locate`/`fetch`, `AssetClient.resolve`,
   `prefetch`, `events`, `availability`/`ensureAvailable`) and delete the deprecated members, then the shims.

## 2. Symbol by symbol

| Prior-art symbol | Shim | Status | Behaviour in the shims |
|---|---|---|---|
| `CDNAsset` | `Shims/CDNAsset.swift` | kept | Same fields, initialiser, `Codable` wire format and `resolvedFileName`; converts to and from `ManifestEntry` (a checksum that is not a SHA-256 becomes checksum-less, R-MAN-5). |
| `CDNProviding` | `Shims/CDNSyncProgress.swift` | kept | Same requirements; a provider is a manifest source and, for the two prior-art providers, a tier description. The client never downloads through a provider. |
| `StaticManifestCDNProvider` | `Shims/StaticManifestCDNProvider.swift` | kept; `downloadAsset` deprecated | Describes the HTTP tier (base URL, manifest path). `fetchManifest()`: one GET past the URL cache, a 2xx check (`badResponse`), the module's validating decoder off the main thread (D-9). It answers the validated manifest, not the raw decoded array: checksums come back in lowercase hex, and entries the validator quarantines are left out (an invalid identifier, extension or remote path, and a checksum that is present but not a SHA-256, R-MAN-2). `downloadAsset` throws `CDNShimError.downloadsGoThroughTheClient` (K-5). The GET carries no app key, so SPEC §2.3's origin answers it 403 and `fetchManifest()` throws `badResponse` there (step 4). |
| `StaticManifestCDNProviderError` | same file | kept (+`Equatable`) | `badResponse(URLResponse)`. |
| `BackgroundAssetsCDNProvider` (iOS 26) | `Shims/BackgroundAssetsCDNProvider.swift` | kept; `downloadAsset` deprecated | Describes the Apple-hosted tier (the client reads its catalog from the essential pack, SPEC §2.3); `fetchManifest()` serves the app-supplied catalog; `downloadAsset` reports a malformed `remotePath`, otherwise throws `downloadsGoThroughTheClient`. |
| `BackgroundAssetsCDNProviderError` | same file | kept (+`Hashable`) | `malformedRemotePath(String)`. |
| `CDNLocalStore.shared` | `Shims/CDNLocalStore.swift` | kept | Follows the process install point; answers like an empty cache until a client is installed. |
| `CDNLocalStore.init(baseDirectory:computeChecksum:)` | same | deprecated | No directory: the process point. A directory: a point of its own whose client migrates the prior art's files found in that directory and keeps its own root beside it, in the same parent (`<parent>/ZTronAssetKit/v1`), never inside it (the module refuses to migrate a legacy root that contains the store, R-STO-11). One client per resolved base directory (R-STO-9), counting every client: two directories with one parent share one root, and a directory in Caches or Application Support shares the root of a client at `.caches` or `.applicationSupport`, such as the process point's; one legacy root per process (a store over `<Caches>/CDNAssets` and an installed process client with the default legacy policy would both migrate it); the parent must exist; `computeChecksum` ignored (K-6). New: `init(client:)`, `init(installPoint:)`. |
| `existingLocalURL(identifier:candidateExtensions:)` | same | kept, `@MainActor` | The client's snapshot: no file-system call, no network. Candidates match case-insensitively and also filter manifest-known assets (ADR-037). A stale asset answers with its old bytes. `nil` until the installed client has started (step 3), and on a launch during legacy migration for a prior-art file until its adoption is installed (K-15). The URL names stored content, not a pretty path: after a content change, a prune or an eviction the old file is removed `StoragePolicy.deletionGrace` after the new snapshot (ADR-017), so a consumer that reads the path later, such as `BasicVideoPage`'s player, looks it up again when the read fails, or holds a lease (`AssetClient.withAsset`) (K-11, §4). |
| `hasAsset(_:)` | same | kept, `@MainActor` | Stored with its extension and, for a SHA-256 checksum, under that digest (the blob's name), no I/O; relative to the asset given, the client's staleness is not consulted (K-4). `false` until the installed client has started, and on a launch during legacy migration for a prior-art file until its adoption is installed (K-15). |
| `missingOrStaleAssets(against:)`, `isFullyAvailable(against:)` | same | kept, `@MainActor` | `hasAsset` per entry, manifest order, no network; on a launch during legacy migration the prior-art files whose adoption is not installed yet count as missing (K-15). |
| `localURL(for:)` | same | deprecated, `@MainActor` | The stored blob, else the prior art's pretty path under the legacy root (where nothing is written any more), kept inside that root: empty, `.`, `..` and `/`-containing directory components are dropped and a `/` in the file name becomes `_` (K-14). |
| `cacheManifest(_:)`, `cachedAsset(forIdentifier:)` | same | deprecated, `@MainActor` | The manifest last handed to this store in this process (first entry wins on a duplicate, D-13); the client's applied manifest is not readable (K-13). |
| `store(temporaryURL:for:)` | same | deprecated | Throws `CDNShimError.storeIsOwnedByTheClient`, leaves the file. |
| `reconcile(newManifest:)` | same | deprecated, `@MainActor` | Records the manifest, reports nothing moved: the client reconciles inside its sync (see `CDNSyncCoordinator.lastReconciliation`). |
| `mechanicalPathComponents(for:)`, `sha256Hex(of:)` | same | deprecated | The prior art's results. |
| `CDNReconciliationSummary` (+`Failure`) | same file | kept (+a public initialiser, `Hashable`) | `init(report:)` maps a run's relocations and prunes. |
| `CDNAssetResolver.installed` | `Shims/CDNAssetResolver.swift` | kept, `@MainActor` | A view of the process install point; setting installs the client unless one is installed; `nil` changes nothing (K-2). |
| `CDNAssetResolver.init(cdn:localStore:)` | same | deprecated | Resolves through the client of the store's point, built there from `cdn` on first use (K-6). New: `init(client:)`. |
| `resolveViaNetwork(identifier:candidateExtensions:)` | same | kept | `AssetClient.resolve`: a stored asset without a transfer, fetch-first for an unknown identifier (point admission, never a prune), single-flight, verified; any failure is `nil`. |
| `CDNSyncCoordinator` | `Shims/CDNSyncCoordinator.swift` | kept (`@MainActor`, `ObservableObject`) | See step 4 and §4 (a sync during legacy migration adopts the prior art's files, never downloads them, L5K-R1). New: `init(client:cdn:)`, `lastReconciliation`. |
| `CDNSyncCoordinator.init(cdn:localStore:defaults:appVersionProvider:)` | same | deprecated | The client of the store's point, built from `cdn` on first use; `defaults` and `appVersionProvider` ignored (the stamp lives in the client's index; the client migrates the `UserDefaults` stamp once, R-STO-11). |
| `CDNSyncCoordinator.defaultAppVersion()` | same | kept | `"<CFBundleShortVersionString>+<CFBundleVersion>"`. |
| `CDNSyncProgress` | `Shims/CDNSyncProgress.swift` | kept | Same cases; `init(progress:)`, `init(outcome:)` map the client's events (sync.md §10.6). |
| `NetworkAvailabilityMonitor` | `Shims/NetworkAvailabilityMonitor.swift` | kept | `shared` watches the live reachability conformer, a second path monitor beside the client's (ADR-038); every satisfied conditions report runs the pending retries in registration order, the first report included: a path change, and also a Low Power Mode or thermal-state report, where the prior art retried on path updates only (K-8). New: `init(conditions:)`. |
| `CDNRefreshPolicy` (SPEC-named, absent on disk) | `Shims/CDNSyncProgress.swift` | new | `oncePerAppVersion`, `everyLaunch`, `atMostEvery(_:)` → `RefreshPolicy`. |
| `CDNConfiguration` (SPEC-named, absent on disk) | `Shims/CDNConfiguration.swift` | new | A thin adapter onto `AssetClientConfiguration`. |
| `CDNProviderFactory` (SPEC-named, absent on disk) | same file | new | `makeClient`, `install(_:into:environment:)`, `remoteConfiguration(for:)`; tier selection is the client's (R-APL-5). A prior-art provider at the configured HTTP origin keeps that configuration's HTTP settings, the app key among them (K-6). `install` starts nothing: call `start()` (step 3). |
| — | `Shims/CDNInstallPoint.swift`, `Shims/CDNShimError.swift` | new | The write-once install point (K-2); the typed refusals (K-5). |

## 3. Pre-existing CDN tests, one to one

| Prior-art test | Fate |
|---|---|
| (none: ZTronCarouselCore has 0 CDN tests, `docs/BASELINE.md`) | — |

No test was deleted, weakened or ported, because none existed. The prior art's behaviours as read (`docs/RECON.md` §5)
are re-expressed as tests of the shims instead:

| Behaviour (RECON §5) | Shim tests (`R-CAR-6: …`) |
|---|---|
| Manifest wire format; `resolvedFileName` | `CDNAsset keeps the prior-art initialiser, wire format and resolvedFileName`; `a CDNAsset converts to a ManifestEntry and back without loss`; `StaticManifestCDNProvider fetches its manifest anew on every call and decodes the prior-art wire format`; `StaticManifestCDNProvider answers the validated manifest: checksums in lowercase hex, quarantined entries left out` |
| Legacy path layout (`Caches/CDNAssets/…`, `manifest.json`, `local-checksums.json`) and its migration | `the prior-art local store initialiser keeps the prior art's layout for an asset the client does not hold`; `the prior-art local store initialiser's client adopts the prior art's files found in its directory and downloads nothing`; `the prior-art local store initialiser's client starts on a fresh install, before its directory exists`; `two prior-art stores in one parent directory share one root, which admits one client (R-STO-9)`; `a prior-art store whose directory lies in Caches shares its root with a client at StorageLocation.caches, which admits one client (R-STO-9)`; `on a launch during legacy migration the lookups miss a prior-art file until it is adopted after start() returned: a resolve adopts it without a download, and every file answers once migration has ended`; `a coordinator's syncIfNeeded right after start on the first launch after adoption completes and downloads none of the prior art's files (CCR-K1)`; `a coordinator's syncIfNeeded right after start on a later launch that resumes an unfinished legacy migration completes and downloads none of the prior art's files (L5K-V3-06)`; `localURL keeps a crafted entry's path inside the legacy root`; `mechanicalPathComponents and sha256Hex keep the prior art's results` |
| Once-per-version sync (the stamp holds for its app version across launches; a new version syncs at launch, through the client's own launch run, K-7), success marked only after a complete run | `once per app version: a later launch of the same version reports upToDate without a manifest request, and a new version syncs at launch`; `a coordinator starts idle, reports upToDate without a manifest request when no sync is due, and complete after a due sync`; `a sync with a failed asset reports failed and the next sync downloads only what is still missing`; `a sync whose manifest cannot be fetched reports failed with the outcome's description and stays due`; `a run blocked by Low Power Mode reports failed with blocked and stays due, and the client finishes it unobserved once the gate opens` |
| Reconcile before download; changed directory ⇒ no download; removed entry ⇒ deletion; changed checksum ⇒ that asset only | `a directory change moves the stored asset without a download and a removed entry is deleted, before any download`; `a changed checksum re-downloads that asset only` |
| On-demand resolve: fetch-first for an unknown id, never reconciles | `resolveViaNetwork fetches the manifest first for an identifier it does not know and downloads only that asset`; `an on-demand resolve never prunes what the fresh manifest no longer lists`; `resolveViaNetwork answers a stored asset with its local file and starts no transfer`; `resolveViaNetwork answers nil for an identifier the catalog lacks, a failed download, a non-candidate extension and a shut-down client` |
| `existingLocalURL` offline, candidate extensions in order | `existingLocalURL answers from the client's snapshot with no file-system call on the main thread and no network request`; `existingLocalURL matches the candidate extensions case-insensitively and answers nil for an asset in none of them`; `the lookups answer nil for an asset stored in an earlier launch until the installed client has started, and its file right after` (the deviation of §4) |
| Checksum-aware `hasAsset`; the availability guarantee | `hasAsset is true for stored content and false for an absent asset, another extension or another checksum`; `missingOrStaleAssets lists absent and republished assets in manifest order, and isFullyAvailable is true only without any`; `verifyFullyAvailable lists what the provider's fresh manifest names that is missing or stale, downloading nothing`; `StaticManifestCDNProvider sends no app key, so verifyFullyAvailable through it fails with the 403 of an origin that requires one, while a manifest source that sends the key reaches it`; `an asset whose new content is downloading keeps serving its old bytes while hasAsset reports the new content missing` |
| Connectivity retry for failed on-demand fetches | `a retry registered while offline runs once connectivity returns, and only once`; `a cancelled retry never runs, and cancelling a token that already ran or was cancelled changes nothing`; `a retry registered while the client is idle still runs when connectivity returns`; `a monitor observes nothing until a retry is registered, and its first report counts as the prior art's initial path update` |
| The process-wide resolver, set once at launch (`CDNAssetResolver.installed = …`) | `an install point's resolver is the first installed resolver's client, and nil before`; `setting CDNAssetResolver.installed installs the value's client, a later value keeps the first client and nil changes nothing`; `CDNLocalStore.shared and CDNAssetResolver.installed follow the process install point, which no test fills` |
| The carousel's call sites (`BasicVideoPage`, `ZTronSVGView`) unchanged; no cost without an installed resolver | `the carousel's call sites compile unchanged and find nothing and start nothing while no client is installed` |
| Progress `idle / upToDate / syncing / complete / failed(reason)` | `progress reports syncing with a monotone completed count while assets transfer, then complete`; `sync outcomes and refresh policies map to the prior-art cases`; `a coordinator over a shut-down client reports failed with shutDown`; `a run blocked by Low Power Mode reports failed with blocked and stays due, and the client finishes it unobserved once the gate opens` |

## 4. What behaves differently (owner review)

Recorded in `docs/adr-drafts/k.md`; the ones tagged **NEEDS-HUMAN-REVIEW** there change the shims' public behaviour.

- **One client, installed once** (K-2): `CDNAssetResolver.installed` cannot be replaced or cleared after the first
  installation.
- **Lookups wait for `start()`** (ADR-037, K-3): the synchronous lookups read the client's snapshot, which `start()`
  installs; until then `existingLocalURL` answers `nil` and `hasAsset` `false`, even for assets stored in an earlier
  launch, where the prior art read the disk from launch on. Step 3 starts the client before carousel content exists.
  On a launch during legacy migration (the first one after adoption, and any later launch that resumes an unfinished
  migration) a prior-art file also waits for its adoption, after `start()` has returned: `BasicVideoPage.init?` returns
  `nil` for such a video until then, and `ZTronSVGView`'s `resolveViaNetwork` adopts on demand (K-15). The shims cannot
  close this window without file-system I/O on the main thread (C2).
- **The URL is the stored content's** (ADR-017, K-11): `existingLocalURL` names a content-addressed blob, where the
  prior art kept one pretty path per asset and replaced its bytes in place. After a content change, a prune or an
  eviction the old file is removed `StoragePolicy.deletionGrace` (10 s of awake time by default) after the new snapshot.
  A consumer that reads the path later, such as `BasicVideoPage`'s player, which builds `TinyVideoPlayer` from the URL
  at init, looks it up again when the read fails, or holds a lease (`AssetClient.withAsset`) while it reads.
- **Main-actor lookups** (K-3): `CDNLocalStore`'s lookups need the main actor; nonisolated callers use `await MainActor.run`.
- **`CDNLocalStore(baseDirectory:)`** (K-6): the client migrates the prior art's files found in that directory and keeps
  its own root beside it (`<parent>/ZTronAssetKit/v1`), so the store follows the parent's durability class (`Caches`
  may be purged by the OS, R-CLN-7). One client per resolved base directory, counting the process point's client
  (`.caches` and `.applicationSupport` resolve to Caches and Application Support), and one legacy root per process; a
  missing parent makes `start()` throw
  `storageUnavailable`; a directory named `ZTronAssetKit` is the store's own, whose migration the module refuses.
- **The app key** (K-5, K-6): the prior-art idiom on the process install point builds a client without the key, which
  the origin rejects (SPEC §2.3); a configured point keeps its key for a prior-art provider at its origin only.
  `StaticManifestCDNProvider`'s own manifest fetch carries no key, so `verifyFullyAvailable()` through it throws
  `badResponse` (403) at that origin: give the coordinator a manifest source that sends the key (step 4).
- **Providers no longer download** (K-5): `downloadAsset` throws `CDNShimError.downloadsGoThroughTheClient`; a custom
  `CDNProviding` is no transport (K-6): configure the remote with `CDNConfiguration`. The Apple tier's catalog comes from
  the essential pack, not from `BackgroundAssetsCDNProvider(catalog:)`.
- **The coordinator** (K-7): `.syncing` counts the run's planned fetches; `.upToDate` means nothing was due when the call
  asked (the client's own launch run may have synced moments earlier, a new app version's sync included); a complete
  `verifyAndRepair()` also writes the stamp; `verifyFullyAvailable()` needs the provider given to `init(client:cdn:)`. A
  run whose remaining jobs are blocked is `.failed(reason: "blocked(…)")` and leaves the sync due: offline, an open
  breaker, a throttle or space, and, under the default policies (ADR-036), Low Power Mode, Low Data Mode or serious
  thermal pressure for bulk work, where the prior art downloaded regardless. The client then starts a pending run by itself once
  the gate opens, which the coordinator does not observe: `progress` keeps the call's outcome while those assets arrive
  in the same launch. A sync requested during legacy migration adopts the prior-art files migration has not reached
  yet instead of downloading them, a file a migration batch is adopting at that moment included, and takes the place of
  the launch run that waited for migration (L5K-R1, L5K-R13, K-15). Like the files a sync downloads, the files it adopts,
  and those a prefetch adopts or a migration batch adopts after it, reach the lookups within about two
  `SyncTuning.snapshotInstallInterval`s (0.2 s by default) of their adoption: the client coalesces bulk and prefetch
  snapshot installs (ARCHITECTURE §5, L5K-R14) and its alarm runs the trailing install, which the client schedules after
  every such adoption (L5K-R16), skipping the re-read while its alarm already wakes within about two intervals (RE-S40's
  shortcut, F-12); a migration batch returns to the client right after such a publication instead of waiting behind it,
  and the last batch installs at once (L5K-R20, L5K-R23). A resolve's adoption is installed before the call returns, and
  so is every prior-art file a job answers a user-initiated request with (`resolve`, `ensureAvailable`, a user-initiated
  prefetch), whenever that request joined it (L5K-R18, L5K-R21); a job also adopts, rather than downloads, the prior-art
  file of every other id of the same content that joins it before its transfer would start (L5K-R23). Elsewhere a
  user-initiated answer can precede the lookups by up to about two intervals (0.2 s by default), the lag ADR-016
  documents for the module, which the shims inherit (orchestrator ruling L5K-R24): a request that joins a prefetch or
  bulk download while the client verifies it, `ensureAvailable`'s report of assets already stored (during legacy
  migration too, for a file a migration batch or a prefetch adopted moments earlier), and a `resolve` that finds its
  asset already stored. The location such an answer returns is valid at once; `lookup`, `existingLocalURL` and
  `hasAsset` see the asset at the next install, which the client has scheduled. A later version may install a pending
  trailing install before such answers if a device test shows the lag matters (k.md, "L5K-R24").
- **Inherited from the module** (K-11): an asset whose new content the origin reports missing (404) is no longer served
  until its manifest entry changes, where the prior art kept the old file and asked again on every sync; the candidate
  extensions also filter manifest-known assets (ADR-037); an on-demand resolve downloads before its extension check; a
  manifest entry whose checksum is present but not a SHA-256 is quarantined (R-MAN-2), so the client never downloads it
  and `StaticManifestCDNProvider.fetchManifest()` leaves it out, where the prior art downloaded it and re-downloaded it
  on every sync (D-16).
- **`localURL(for:)`** (K-14, deprecated): stays inside the legacy root whatever a manifest entry says.
- **`NetworkAvailabilityMonitor`** (K-8): pending retries run on every satisfied conditions report, which the live
  source sends on a path change and also on a Low Power Mode or thermal-state change, where the prior art's
  `NWPathMonitor` retried on path updates only. A view that keeps failing (`ZTronSVGView` registers again after each
  failure) therefore also retries on those reports. `shared` builds its own live conditions source, a second path
  monitor in the process beside the client's.
- **Not verified here** (k.md): the adoption itself (Q-10), the live monitor and provider against real networks, the
  length of the migration window on a device (phase 2 hashes every prior-art byte), and the shims below the iOS 17
  test-bundle deployment target at run time.
