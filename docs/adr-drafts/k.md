# WP-K decision drafts (R-CAR-6: compatibility shims)

Stage 2, level L5 after WP-G, branch `wp/k` (based on `l5g-merged`). One entry per non-trivial decision, in the
`DECISIONS.md` shape (context · options · decision · consequences); the orchestrator numbers them at merge. Files: every
new file under `Tests/ZTronAssetCompatibilityTests/` (not `CompatibilityShimTests.swift`), bodies and doc comments in
the two Stage 1 shim files (`Shims/CDNAsset.swift` unchanged, `Shims/CDNSyncProgress.swift`: the `CDNProviding` doc
comment only), `docs/MIGRATION.md`, this draft. No contract signature changed by WP-K's own files; under L5K-R14 one
package signature in WP-C's contract file `Migration/StoreMigration.swift` changed (`adoptLegacyNow(_:urgency:)`,
`urgency` defaulted to `.userInitiated`; L5K-C2-06). `docs/MIGRATION.md` lies in WP-I's
`docs/**`; the WP-K launch notes allow it ("You may also write docs/MIGRATION.md"), ADR-006 and ADR-037 expect the
shims to document their differences there, and orchestrator ruling L5K-R10 makes it WP-K's file. **For the orchestrator
at merge:** record it as WP-K's file in ARCHITECTURE §1.2 (a "Files WP-K added" paragraph like WP-F's and WP-G's), so
WP-I does not treat it as unowned (fix round 1, reqs issue 2; L5K-R10). The close-out's authorised edits in WP-F's
engine (orchestrator rulings L5K-R1, L5K-R14, L5K-R16, L5K-R17, L5K-R18) and in WP-C's legacy migration (L5K-R13,
L5K-R14, L5K-R17, L5K-R18) are listed under "Authorised edits outside WP-K (close-out)" below.

**Proposed REENTRANCY rows** (the code cites them as "k-n (proposed)"; all are main-actor awaits of
`CDNSyncCoordinator`, a test-target type, so ARCHITECTURE §10 may list them under a new "compatibility shims"
heading or by reference to this draft):

| Row | Where | What is re-validated after the await |
|---|---|---|
| k-1 | `CDNSyncCoordinator.run(_:)`: `client.subscribe()`, `client.sync(mode)`, then `follower.value`; and the `await self.run(_:)` of `syncIfNeeded()` and `verifyAndRepair()`, after which nothing is read (fix round 1) | Nothing of the coordinator is read across them. `progress` is written only by this call's follower while the run is in flight and by the outcome once the follower was cancelled **and awaited**, so no progress event lands after the outcome. A concurrent call joins the same single-flight run and publishes the same outcome (its follower may republish a `.syncing` value until its own outcome lands). |
| k-2 | the follower's `for await event in events` (a main-actor task) | Each event is applied in the turn it arrives, after `self` is re-read (weak: a released coordinator publishes nothing). Progress never moves backwards within a run by construction (sync.md §10.6: the engine's completed count is monotone and one subscription delivers a run's progress in order, newest-wins), so no guard is needed. |
| k-3 | `CDNSyncCoordinator.verifyFullyAvailable()`: `cdn.fetchManifest()` | Nothing of the coordinator; the client's snapshot is read after the fetch, so the comparison uses what is stored when the manifest arrived. |
| k-4 | `SyncEngine.storedLocation(of:in:lane:)` (`EnginePresence.swift`, WP-F's file, close-out rulings L5K-R1, L5K-R14, L5K-R16, L5K-R18; `storedLocation(of:lane:)` until cycle 3): `store.adoptLegacyNow(id, urgency:)` while legacy migration is pending, called once per id of a job from `answeredFromStore` (row f-11) before any bytes, at `.userInitiated` for a job of the user-initiated lane and `.bulk` otherwise | Nothing in the callee: `answeredFromStore` re-validates after its reads exactly as f-11 says (the lifecycle, the job epoch and the attempt still without a handle; the interests the job holds then; bindings recorded only when nothing was forgotten meanwhile, the adoption being such a binding). A thrown `StoreError` (the caller's cancellation at shutdown, a store that refuses) reads as "nothing stored", so the attempt goes on to the transfer, as the resolve path's own adoption does (ADR-029). After a `.bulk` adoption the caller's own awaits follow, each re-validated as f-11 says: the lane is re-read, and a job promoted to the user-initiated lane meanwhile asks the store once more at `.userInitiated`, which installs the snapshot at once (L5K-R18); then the store's deadline is re-read into the heap (RE-S40, O(1) while the alarm already wakes within about two install intervals), so the adoption's trailing install runs on the alarm (L5K-R16). The answer is the outcome of the store's one adoption of the prior-art file (L5K-R13, rows k-5 and k-6): a queued file is claimed before its hash, so no batch takes it; a call that finds the file being processed by another adopt-on-demand, or adopted by a batch, waits for that processing and reads the location it bound; when a batch has not finished hashing the file, both may hash it and the one whose bytes verify second waits out the other's adoption. So `nil` means no prior-art file to adopt, or one dropped or kept, never a failure the other adopter caused (the round-1 text of this row claimed the first placement always bound before the other call decided; L5K-C1-00 showed it did not). |
| k-5 | `AssetStore.performAdoptLegacyNow(_:urgency:)` (`Migration/LegacyPhases.swift`, WP-C's file, close-out ruling L5K-R13): the wait for the processing of the same prior-art file in flight, another adopt-on-demand's (`MigrationState.onDemand`, from its claim to its installed snapshot) or another call's adoption (`MigrationState.adopting`), `awaitLegacyFlight(of:)`; and the loop's `awaitOpen()` after it | Nothing is carried across the wait: the call starts again and reads the location, the phase, the plan commit, the queue, the claims and the flights anew. The processing it waited for has ended: adopted (the location is present: the call installs a snapshot at its urgency and answers the location read after that install), dropped or kept (the file is neither queued nor claimed: `nil`), or ended without an outcome for the file (its caller was cancelled, or a transient failure deferred it back to the queue: this call takes the file and processes it itself, as a call arriving then would). `close()` resumes it: it drains the units and resumes the key and commit waiters, so the processing it waits for returns from its await, throws `.closed` at its next phase check, and ends its mark (every exit path of `processLegacyFile` and `processLegacyFileOnDemand` does), which resumes this call; its `awaitOpen()` then throws `.closed`. |
| k-6 | `AssetStore.processLegacyFile(_:)` (`Migration/LegacyPhases.swift`, L5K-R13): after its hash, whether it succeeded or failed, the wait until no other call's adoption of the file is in flight, `awaitLegacyAdoption(of:)` | The loop re-reads `adopting[file]` and the phase (`checkLive`, so a closing store answers `.closed`); it returns in the turn in which no adoption is in flight, and the caller then reads the records as that adoption left them: bound (`.alreadyAdopted`; for a failed hash, `legacyFailureOutcome` sees the binding), no longer wanted (`.dropped`), or still wanted (the other adoption failed: this call adopts with its own verified hash, marking `adopting` in that same turn, so at most one adoption runs at a time). A `notFound` read caused by the other call's rename, or a key in `publishing`, is therefore never classified before that call's binding. `close()` resumes it as for k-5. |
| k-7 | `AssetStore.performMigrateLegacy(maxFiles:)` (`Migration/LegacyPhases.swift`, close-out ruling L5K-R17): with the queue empty and every claimed file an adopt-on-demand's (`MigrationState.onDemand`), the wait for one such processing, `awaitLegacyFlight(of:)`, then `checkLive()` | The queue, the claims and the phase, re-read by the loop in the turn the wait returns: the processing it waited for has ended, adopted, dropped or kept (the file is no longer claimed), or deferred or cancelled (the file is back in the queue, which ends the wait); while every claimed file still is an adopt-on-demand's the call waits for the next one, so it never returns with nothing it could do, and once the claims are empty it goes on to phases 3 and 4 itself (the finish check that follows the loop). A closing store answers `.closed` (`checkLive`); `close()` resumes the wait through the processing it waits for, as for k-5. Each wait is bounded by one adoption. |

**Proposed amendment of row f-11** (ARCHITECTURE §10.2, the orchestrator's file): in its "Await" column, "`store.location(for:extensions:recordingAccess:)` per id of the job" becomes "`store.location(for:extensions:recordingAccess:)` per id of the job, or, while legacy migration is pending, `store.adoptLegacyNow(id, urgency:)` at `.userInitiated` for a job of the user-initiated lane and `.bulk` otherwise, after a `.bulk` adoption a second `store.adoptLegacyNow(id, urgency: .userInitiated)` when the job was promoted meanwhile and the RE-S40 re-read of `store.nextDeadline()` (row k-4, L5K-R1, L5K-R14, L5K-R16, L5K-R18)"; its re-validation column is unchanged.

**Proposed amendments of rows RE-S40 and RE-S27** (ARCHITECTURE §10.2; close-out ruling L5K-R16): RE-S40's "Await" column becomes "re-arming outside the alarm: `store.nextDeadline()` after a lease release, publish, apply or purge, and after every other store call that can leave an install due: a bulk-urgency adoption (k-4), each `migrateLegacy` call (RE-S29), point admission's `admit`, launch reconciliation's publication, a failed maintenance step, a failed `reportUnreadable`, and `recordFailure`/`recordIntegrityFailure` or `publish` when the job ended meanwhile"; its re-validation column gains "an answer applied after another update of the store's deadline landed while it was in flight keeps the earlier of the two deadlines (`applyStoreDeadline`): the store answers in its order and the engine resumes in priority order, so the two may have crossed". RE-S27 gains the same sentence for the alarm's `runDueWork()` report.

**Contract change requests:** none by WP-K; the one package signature change, `adoptLegacyNow(_:urgency:)` in WP-C's
contract file `Migration/StoreMigration.swift` (defaulted to `.userInitiated`), is orchestrator ruling L5K-R14's (L5K-C2-06).
One behaviour change in another WP's code (fix round 2), **ruled
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
  **Status (close-out):** ruled L5K-R1 and fixed in the close-out (`9fe92fc`), then closed as a class by L5K-R13 (one
  adoption per prior-art file, `4811c50`: L5K-C1-00 showed a user-initiated job's adoption racing a migration batch's);
  the wrapper is gone and the test is strict (`3cd3768`), and it holds migration across the call since L5K-R15
  (`de99d9a`); the window includes every later launch that resumes an interrupted migration (L5K-R4); MIGRATION.md
  step 4 calls the launch-task sync safe. The text above is the request as filed.

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
  an on-demand adoption (`adoptLegacyNow`, a resolve's or, since L5K-R1, any job's) installs its own at once when it is
  a resolve's or a user-initiated job's, and within the install interval when it is a bulk or prefetch job's
  (L5K-R14); one adoption per prior-art file runs at a time, whoever asks (L5K-R13). The
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
  job, even one a migration batch is adopting at that moment (L5K-R13: the read waits for that adoption and answers
  its location), and a run that starts while the launch run waits for migration takes its place (the next section).
  Through the
  shims: `R-CAR-6: a coordinator's syncIfNeeded right after start on the first launch after adoption completes and
  downloads none of the prior art's files (CCR-K1)` (150 prior-art files of 64 KiB, MIGRATION.md steps 3 and 4 in one
  launch task, the migration held at a unit of its first file across the call since L5K-R15, so the sync provably
  overlaps it) is strict now: no transfer, every prior-art file out of the prior art's tree when the sync returns,
  `.complete`, and every asset stored (`availability(scope:)`; the lookups' snapshot follows a running batch's
  adoptions only at the batch's end, and no public event marks the end of migration when a run took the launch run's
  place). Its resumed-launch twin, `R-CAR-6: a coordinator's syncIfNeeded right after start on a later launch that
  resumes an unfinished legacy migration completes and downloads none of the prior art's files (L5K-V3-06)`: launch 1
  runs steps 3 and 4 with every bulk unit held, and is shut down once its sync's run has started (the sync's joiner is
  answered in the shutdown turn that cancels the migration, so at most the files of the units then held are adopted:
  one for the migration and one per running job; 148 of 150 files were left in the runs on the pre-fix engine); launch
  2 starts on the same volume, its resumed migration held at a unit of its first file (L5K-R15), and syncs right away:
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
The rulings of `.build-orchestrator/l5k-rulings.md` (L5K-R1…R19, and cycle 2's correction to L5K-R1), recorded as
made; where a ruling and an earlier entry of this draft disagree, the ruling wins.

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
- **Orchestrator ruling (close-out), correction to L5K-R1 (cycle 2).** L5K-R1's line "the store's install-rate limiter
  coalesces snapshot installs" was wrong: `adoptLegacyNow` published at `.userInitiated`, which the limiter never
  coalesces (recorded in cycle 1 under "C2" below). L5K-R14 fixes the consequence.
- **Orchestrator ruling (close-out), L5K-R13 (one adoption per prior-art file, whoever asks; L5K-C1-00, blocking).** At
  most one adoption runs per prior-art file at a time, among a batch, an on-demand call or two on-demand calls; every
  concurrent asker gets that adoption's outcome, the location or `nil` only for a file dropped or kept; a failure caused
  only by the other adopter is never reported as dropped, deferred or `nil`. Done as the ruling's acceptable alternative,
  widened: the adoption step is single per file (`MigrationState.adopting`), whole processings are single among
  adopt-on-demand calls (`MigrationState.onDemand`), and a call decides only once no other adoption of its file is in
  flight; a file a batch has not finished hashing stays adoptable at once. Why, and the outcome of every state and pair:
  "L5K-R13: one adoption per prior-art file". Failing tests first (`5c9612a`), then the fix (`4811c50`). Rows k-5 and
  k-6 proposed and k-4 corrected; the L5K-R1 section's store paragraph, MIGRATION.md step 3, step 4 and §4, K-15 and the
  shim doc comments (`CDNSyncCoordinator`, `CDNLocalStore`) state the real ordering. Runs: "Evidence (close-out cycle
  2)".
- **Orchestrator ruling (close-out), L5K-R14 (bulk-lane adoptions keep the install rate; L5K-C1-02).**
  `AssetStore.adoptLegacyNow(_:urgency:)` with `urgency: AssetPriority = .userInitiated` (package API, defaulted, not
  NEEDS-HUMAN-REVIEW); the funnel passes `.userInitiated` for a job of the user-initiated lane and `.bulk` otherwise.
  Failing test first (`3e51cf8`), fix (`dcd2437`), store pin (`c857cde`): "L5K-R14: the install rate of bulk-lane
  adoptions".
- **Orchestrator ruling (close-out), L5K-R15 (the clearly right cycle-1 items).** L5K-C1-01 and L5K-C1-03: both strict
  shim tests hold migration across the coordinator's call and prove the overlap, every strict assertion kept, the two
  L5K-R2 rows updated; L5K-C1-04: the CCR-K1 header ends with a status line; L5K-C1-05: the migration loop's flag clear
  at shutdown is pinned (`de99d9a`; mutant M3 fails it).
- **Orchestrator ruling (close-out), L5K-R16 (every coalesced publication gets its trailing install scheduled, as a
  class; L5K-C2-00, -02, -03, blocking).** At the end of every engine turn in which the store may have marked an install
  due, the heap holds a store deadline no later than the store's `nextDeadline()`, so no adopted, committed or published
  asset stays out of the readers' snapshot longer than one install interval unless a commit is still pending. Done: every
  engine call of a store method is enumerated with how its deadline is re-read; the RE-S40 re-arm (O(1) shortcut kept,
  F-12) is added after the funnel's bulk adoptions, after every `migrateLegacy` call, and at the seven other call sites
  (eight exits) the enumeration found without one; a crossed answer of the store's deadline keeps the earlier deadline
  (`applyStoreDeadline`); the tripwire is in `invariantViolations(storeDeadlineDue:)` and asserted at idle in the new
  tests, the engine model and the L5K-R1 migration tests. Failing tests first (`30be1bf`: PR14a, PR14b, probes I/J, the
  compatibility test at `snapshotInstallInterval` 0.1, and the L5K-R14 test through the tripwire; `296e5a0`: crossed
  answers), fixes `623378b` and `d931f9e`, a regression test of launch reconciliation (`c229bb3`): "L5K-R16: every
  coalesced publication's trailing install". MIGRATION.md §4, the L5K-R14 section, the f-11 amendment and row k-4 name
  the re-arm.
- **Orchestrator ruling (close-out), L5K-R17 (no hot loop around a store call; L5K-C2-01, blocking).** `performMigrateLegacy`
  waits for an adopt-on-demand of the last claimed files instead of returning with nothing it could do (row k-7), and
  finishes the migration in the same call. Failing tests first (`390523a`: PS3's shape in the store, a call-count seam in
  the engine), fix `4ce04d9`; every engine loop around a store call is enumerated: "L5K-R17: no hot loop around a store
  call".
- **Orchestrator ruling (close-out), L5K-R18 (a job promoted during its adoption; L5K-C2-05).** After the funnel's
  bulk-urgency adoption the lane is re-read; a job promoted to the user-initiated lane meanwhile asks the store once more
  at `.userInitiated`, and the store's present path installs at that urgency too. A seam reaches it: failing test first
  (`94b55a3`), fix `09afc28` with a store pin: "L5K-R18: a job promoted during its adoption".
- **Orchestrator ruling (close-out), L5K-R19 (the cycle-2 non-blocking items).** L5K-C2-04: two held variants reach the
  race in every run (`cb9faef`), and the stochastic tests' premise is recorded in the L5K-R2 table as pattern (a) with
  its measured margin; L5K-C2-06: the header and the contract-change line name L5K-R14's package signature; L5K-C2-07: the
  four defensive branches are recorded as unreachable by construction and deliberately untested ("L5K-R19").

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

In cycle 1 no store file changed (`ZTronAssetStorageTests` once: 445/445), and no Kit file (`ZTronAssetKitTests` ×3:
85/85 each).

Cycle 2, bodies and internal state; the one signature change is L5K-R14's package parameter:
- Under L5K-R13: `Sources/ZTronAssetStorage/Migration/LegacyPhases.swift` (WP-C): `processLegacyFile` marks its
  adoption in `adopting` and, after its hash, waits out another call's adoption of the file (`awaitLegacyAdoption`,
  `endLegacyAdoption`); `performAdoptLegacyNow` waits for a processing in flight and starts again (`awaitLegacyFlight`,
  the `onDemand` mark, `processLegacyFileOnDemand`, `endLegacyOnDemand`); the doc comments of `legacyFailureOutcome`
  and `LegacyOutcome.alreadyAdopted`. `Sources/ZTronAssetStorage/Migration/MigrationState.swift` (WP-C): the fields
  `adopting` and `onDemand`. New: `Tests/ZTronAssetStorageTests/Cleanup/LegacyOnDemandRaceTests.swift` (8 tests: 7 for
  L5K-R13, failing first at `5c9612a`; 1 for L5K-R14). `EnginePresence.swift`: the k-4 comment and `storedLocation`'s
  doc comment. The engine test file: the two race tests over a migration that is not held, `catalog(_:seed:size:)`.
- Under L5K-R14: `Sources/ZTronAssetStorage/Migration/StoreMigration.swift` (`adoptLegacyNow(_:urgency:)`, defaulted),
  `LegacyPhases.swift` (`performAdoptLegacyNow(_:urgency:)` and `processLegacyFileOnDemand` publish at that urgency),
  `EnginePresence.swift` (`storedLocation(of:lane:)` passes the job's lane), `EngineRuns.swift` (one comment naming the
  funnel's new signature, under L5K-R1's authorisation); the engine test `adoptionsKeepTheInstallRate`.
- Under L5K-R15: WP-K's own `MigrationLaunchShimTests.swift`, and the engine test file (`resumedMigrationSync`'s flag
  pin).

No Kit source changed, and no WP-B file: `close()` resumes the new waiters through the call they wait for (row k-5).

Cycle 3, bodies and internal state; no public or package signature changed:
- Under L5K-R16 (`EnginePresence.swift`, `EngineRuns.swift`, `EngineTimers.swift` for the re-arm helper, and re-arm call
  additions in the files the enumeration found):
  - `EnginePresence.swift`: `storedLocation` re-reads the store's deadline after a `.bulk` adoption (RE-S40, the O(1)
    shortcut kept); its doc comment.
  - `EngineRuns.swift`: the migration loop re-reads it after every `migrateLegacy` call, returned or thrown; its doc
    comment.
  - `EngineTimers.swift`, the re-arm helper: `applyStoreDeadline` (an answer that crossed a newer update keeps the
    earlier deadline), applied by `refreshStoreDeadline`, by the alarm's `runDueWork()` report in `fireDue` (the
    update count read before the await and one call line) and by the lease release; `setStoreDeadline` counts updates;
    the test seam `holdNextStoreDeadlineRead()`, `releaseStoreDeadlineRead()`, `storeDeadlineReadHeld`.
  - `EngineState.swift`: `storeDeadlineUpdates`; the seam's `storeDeadlineReadHold` and `StoreDeadlineReadHold`.
  - Re-arm call additions: `EngineDispatch.swift` (`publish` when the store's call threw and when the job ended
    meanwhile), `EngineFailures.swift` (`permanentMissing` and `integrityFailed` when the job ended),
    `EngineLifecycle.swift` (`runStart`, once running, after launch reconciliation published; `reconcileLaunch` returns
    whether it did; shutdown releases the seam's hold), `EngineManifest.swift` (point admission after `admit`),
    `EngineCommands.swift` (maintenance's failed step, a failed `reportUnreadable`; the lease release now applies its
    answer through `applyStoreDeadline` in a private `releaseLease(_:)`, where it called `setStoreDeadline`).
  - The tripwire: `EngineCommands.swift`'s `invariantViolations(storeDeadlineDue:)` (defaulted, so its 116 callers are
    unchanged) and `storeDeadlineSettled`.
- Under L5K-R17: `Migration/LegacyPhases.swift` (`performMigrateLegacy`'s wait, row k-7; a debug line), and the
  engine's call-count seam `MigrationProgress.batchCalls` (`EngineState.swift`, counted in `EngineRuns.swift`).
- Under L5K-R18: `EnginePresence.swift` (`storedLocation(of:in:lane:)` re-reads the job's lane and asks again);
  `Migration/LegacyPhases.swift` (`performAdoptLegacyNow`'s present path publishes for a `.userInitiated` call too, and
  its doc comment). The ruling names no store file: without this change its second ask would answer a present asset
  without an install (a mutant whose present path installs only after a join fails both L5K-R18 tests), and
  `LegacyPhases.swift`'s bodies are authorised under L5K-R13.
- Tests: `EngineLegacyMigrationTransferTests.swift` (the L5K-R16, L5K-R17, L5K-R18 and L5K-R19 tests and helpers,
  `expectSettled` in its earlier tests), `EngineModelTests.swift` (the tripwire after every operation and at idle; L5K-R16
  names "the existing engine model"), `Tests/ZTronAssetStorageTests/Cleanup/LegacyOnDemandRaceTests.swift` (PS3's shape,
  the L5K-R18 store pin).

Not changed in cycle 3: `StoreMigration.swift`, `MigrationState.swift`, any Kit source, any WP-B file, WP-F's other test
files (`EngineHarness.swift` included: the tripwire's helper is an extension in the L5K-R1 test file).

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
- **Store serialisation (row k-4), corrected in cycle 2.** Cycle 1 wrote here that the store already ordered an
  on-demand adoption against the migration loop's: a file a batch had claimed hashed by both, the first placement
  binding before the other call decided. It did not: the other call could decide between the placement's rename and its
  binding, and answer `nil` (L5K-C1-00). Since L5K-R13 the store runs one adoption per prior-art file and the funnel's
  answer is that adoption's outcome ("L5K-R13: one adoption per prior-art file"; rows k-4, k-5, k-6).
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
  bounds. Not a device measurement (Not verified here). Since L5K-R14 (cycle 2) a bulk or prefetch job's adoption
  publishes at `.bulk`, which the limiter coalesces: the table's last column describes cycle 1's code (one install per
  adoption); the 100-file sync of `adoptionsKeepTheInstallRate` installs one snapshot (the apply's) where it installed
  101. The turns above do not grow with that change (each install was an O(1) swap); they were not re-measured (no
  benchmark, L5K-R11).

## L5K-R13: one adoption per prior-art file
- **The defect (L5K-C1-00).** `performAdoptLegacyNow` processed a file a batch had already claimed concurrently with
  that batch. When the batch's placement had renamed the file into `blobs/` but not bound the record yet, the on-demand
  hash failed `.notFound`, `legacyFailureOutcome` answered `.dropped` (the record was not bound yet), `adoptLegacyNow`
  returned `nil`, and the job downloaded a file the batch adopted moments later (the verifier's probes PS1, PS1b, PK2b
  and PK8u). The reverse order made the batch count as dropped a file the on-demand call adopted. Row k-4 and
  MIGRATION.md step 4 claimed an ordering that did not hold.
- **Design.** Two marks in `MigrationState`, keyed by the file's path below the root, each holding its waiters:
  - `adopting`: a batch or an adopt-on-demand is placing and binding the file's verified bytes (`adoptVerifiedFile`,
    the extension copies included). Set in the turn the call decides to adopt, which is the turn in which it found no
    other adoption of the file in flight; cleared on every exit of that call. So at most one adoption runs at a time.
  - `onDemand`: an adopt-on-demand is processing the file, from its claim to its installed snapshot.
  - An adopt-on-demand that finds either mark, the file queued or claimed, waits (`awaitLegacyFlight`, row k-5) and
    starts again: it shares that processing's hash and reads its outcome from the records.
  - A call whose own hash of the file ended, successfully or not, waits until no other call's adoption of the file is in
    flight (`awaitLegacyAdoption`, row k-6) before it decides, so a `notFound` read caused by the other call's rename,
    or the other call's key in `publishing`, reads as `.alreadyAdopted` once that call bound the records.
  - A file a batch has claimed but not finished hashing carries no mark: an adopt-on-demand processes it at once, as
    before, so a user's lookup never waits behind a batch's hash. The two hashes may overlap; the adoption step stays
    single.
- **Why not one flight from a batch's claim (the ruling's recommended form).** The ruling keeps "claimed and not
  started" adoptable on demand at once, and the store cannot tell a batch whose first hash unit is queued from one whose
  hash runs without instrumenting WP-B's `hashFileInternal`, which is not authorised. Treating a batch's hash as in
  flight would also change the premise of WP-C's pre-existing `R-STO-11: an adopt-on-demand racing a batch on the same
  file adopts it once and returns its location` (`LegacyEdgeTests.adoptNowRacesBatch`: the batch's hash unit held while
  the on-demand hash runs first), a file L5K-R13 does not authorise, and every test that holds a migration at its first
  file's hash unit while a job or a resolve adopts that file would wait forever (the L5K-R1 engine tests,
  `lookupsDuringLegacyMigration`). So the ruling's acceptable alternative applies, widened: the prototype waited out a
  placement only while its key was in `publishing`, which misses a reused or rescued key (it never enters `publishing`)
  and the extension copies `bindCopy` places after the first binding; `adopting` covers the whole adoption step. Whole
  processings are single among adopt-on-demand calls, as the recommended form has them. The enumeration below shows the
  invariant for every state and pair. The cost: an adopt-on-demand that arrives while a batch hashes the file reads it a
  second time; every other asker shares the one hash (`secondOnDemandSharesTheFirstsHash` counts one read for two
  calls).
- **The enumeration.** B is a batch (`migrateLegacy`); D, D1 and D2 are adopt-on-demand calls (`adoptLegacyNow`: the
  engine's pre-transfer read or a resolve). A row is the state of the file in the first call's hands when the second
  call meets it; "counted" is the progress counter. In every cell exactly one adoption counts, and no side reports
  `.dropped` for an adopted file.

  | State when the second call meets the file | B first, then D | D first, then B | D1 first, then D2 |
  |---|---|---|---|
  | Queued (nobody processes it) | — (B is not processing it) | D claims it before its hash, so B never takes it: B pops only queued files | D1 claims it and marks `onDemand` in one turn, so D2 always meets D1's mark (the rows below) |
  | Claimed, not started | Not observable: B takes a file and calls `processLegacyFile` in one turn. A batch that claimed ahead would leave the file unmarked: D processes it at once and B later waits out D's adoption, `.alreadyAdopted` | B cannot take it (above) | D2 waits for D1 (`onDemand`), no hash |
  | Hashing | D marks `onDemand` and hashes too. Whoever's bytes verify first marks `adopting`, places, binds and reports `.adopted`, counted (by B, or by D, which did not take the file from the queue); the other waits out that adoption after its own hash, which may have failed with `notFound` once the file was renamed, and reports `.alreadyAdopted`, uncounted. D answers the location either way. Pinned: `batchWaitsForTheOnDemandAdoption` (D places first, B's read fails), WP-C's `adoptNowRacesBatch` (D first, B's hash held) | B cannot take it. One edge: D processes a file batch B1 holds, B1's own read fails transiently and defers it back to the queue, and a later batch B2 pops it while D still processes it; then as in the left cell (one adoption binds, the other reports `.alreadyAdopted`) | D2 waits for D1, no hash: `secondOnDemandSharesTheFirstsHash` (one read of the file for both) |
  | Placing (`adopting` set, the key in `publishing`, or a reused or rescued key) | D joins `adopting` (no hash) and starts again once B's adoption ended: the location is present, D publishes at its own urgency and answers it; B `.adopted`, counted. Pinned: `onDemandJoinsTheBatchsAdoption` (PS1b: D reads no byte of the file) | As in the left cell, for the edge above | D2 waits for D1 (`onDemand`): `secondOnDemandJoinsTheFirstsAdoption` |
  | Binding (the first extension bound, the copies under other extensions being placed; `adopting` still set) | As placing: D answers the location once the copies are bound | As in the left cell | As placing |
  | Adopted | B unclaims the file in the turn its adoption ends; D finds the location at its first read and answers it | D unclaims it, or a batch's claim stays and that batch reports `.alreadyAdopted`, uncounted | D2 waits until D1's snapshot is published, then finds the location and publishes at its own urgency |
  | Deferred (a transient read or move failure of that call) | B put the file back at the head of the queue in the turn it decided (or kept it, at the third deferral); D, waiting or arriving, finds it queued and processes it itself (or answers `nil` when it was kept) | D answered `nil` (an adopt-on-demand that defers answers `nil`, since L3) and requeued it; B takes it on its next call | D1 answers `nil`; D2 starts again, finds the file queued and processes it itself: `waiterRetriesADeferredFile` |
  | Cancelled (the first call's caller) | B requeues the file it held; D takes it | D requeues it when it took it from the queue (WP-C's `cancelledAdoptNowRequeues`) | D1 throws `.cancelled` and requeues it; D2 takes it over: `waiterTakesOverACancelledProcessing` |
  | Dropped or kept | B unclaimed it; D finds it neither queued nor claimed and answers `nil`: really dropped or kept | D, when it took the file, counted it dropped or kept; B never sees it | D2 answers `nil` |

- **The invariant in the deferred and cancelled rows.** A processing that ended without an outcome for the file (its
  caller was cancelled, or a transient failure deferred it) has no adoption to share, so the waiting call re-runs as a
  call arriving then would, and answers `nil` only when the file is dropped or kept, or when its own attempt deferred it.
  Each asker makes at most one attempt per processing it waited for, counted by `deferLegacyFile`; the third deferral
  in a lifetime keeps the file, as before. The call whose own read failed answers `nil`, as in L3: a real failure of
  that read, not one the other adopter caused.
- **Close and shutdown.** `close()`, and so the engine's shutdown, resumes every waiter through the call it waits for.
  It sets `closing`, resumes the key waiters, drains the units and resumes the commit waiters, so every await inside a
  processing returns (the hash and placement units, `acquireReference`'s key wait, the snapshot install). The
  processing's next phase check throws `.closed`, and every exit path of `processLegacyFile` and
  `processLegacyFileOnDemand` ends its marks, which resumes its waiters; they re-run and get `.closed` from `awaitOpen`
  or `checkLive`. WP-B's `closeOpenStore` is not an authorised file, so it does not walk the new lists itself. Rows k-5
  and k-6. Pinned: `closeResumesAWaitingAsker` (the waiting call throws `.closed`; no mark or waiter is left).
- **Tests, failing first** (`5c9612a`, against the cycle-1 code). The store's `LegacyOnDemandRaceTests`: 7 tests, 17
  issues, every one on the defect's own assertions. The engine's `ensureAvailableBesideARunningMigration` and
  `userInitiatedPrefetchBesideARunningMigration`: 20 launches each over 120 prior-art files of 16 KiB, inline executors
  so the migration is not held; 22 of 40 launches downloaded 1 to 5 files (PK2b, PK8u). The engine tests assert zero
  transfers in every launch, and that the race was reached: they count the store's debug lines of a call that waited
  for another call's processing of the same file. With the fix, 19 or 20 of 20 launches had such waits, about 10 to 16
  per launch (three runs, measured with a temporary print that was not committed). The fix (`4811c50`): all pass;
  `adoptNowRacesBatch` and every other store, engine, Kit and compatibility test pass unchanged.
- **C2.** No new I/O and no new unit: the waits are continuations on the store's actor, the bookkeeping is O(1)
  dictionary work per call, and a call that joins reads no byte.

## L5K-R14: the install rate of bulk-lane adoptions
- **The defect (L5K-C1-02).** Since L5K-R1 every bulk job's pre-transfer read called `adoptLegacyNow`, which published
  at `.userInitiated`, an urgency the install-rate limiter never coalesces. A sync adopting N prior-art files installed
  N snapshots (101 for 100 files in the new test), so ARCHITECTURE §5's bound ("at most 10 snapshot builds … per
  second") did not hold during migration.
- **Change.** `AssetStore.adoptLegacyNow(_:urgency:)`, `urgency: AssetPriority = .userInitiated`: package API,
  defaulted, so the resolve path, leases and every existing caller keep their behaviour. The adoption publishes at that
  urgency; a call that joined another's processing publishes at its own, so a user-initiated joiner installs at once
  whoever adopted. The engine's funnel (`storedLocation(of:lane:)`) passes `.userInitiated` for a job of the
  user-initiated lane, read before each id (a promotion during an earlier read counts), and `.bulk` otherwise, the
  prefetch lane included, as the ruling says.
- **Tests.** Failing first (`3e51cf8`): `adoptionsKeepTheInstallRate`, a bulk sync whose jobs adopt 100 prior-art files
  under `ManualTimeSource` with ARCHITECTURE §5's 0.1 s interval installs at most 2 snapshots (1 measured, the apply's;
  101 before the fix); then a user-initiated prefetch join of 4 prior-art pages installs one snapshot at once per
  adoption (4), and readers see every page. The fix: `dcd2437`. Store pin (`c857cde`): `adoptionPublishesAtItsUrgency`,
  three bulk adoptions install at most one snapshot, and a user-initiated one installs at once and carries them.
- **Consequence for the shims (corrected in cycle 3).** Cycle 2 wrote here that the files a sync adopts reach the lookups
  within `SyncTuning.snapshotInstallInterval` of their adoption, the trailing install running on the engine's alarm. It
  did not: nothing re-read the store's deadline after the funnel's `.bulk` adoption or after a migration batch, so the
  alarm never ran that install and the adopted assets stayed out of the readers' snapshot until an unrelated install
  (L5K-C2-00, -02, -03; the compatibility harness's interval of 0 hid it). Since L5K-R16 the engine re-reads the store's
  deadline after every such call, so the statement holds: like the files a sync downloads, the files a sync, a prefetch or
  a migration batch adopts reach the lookups within one install interval (0.1 s by default). A resolve's adoption, a
  user-initiated job's, and since L5K-R18 that of a job promoted to the user-initiated lane during its adoption, is
  installed before the call returns. MIGRATION.md §4 says so; `prefetchedNeighboursDuringLegacyMigration` pins it through
  the shims at the production interval.
- **For the docs level.** ARCHITECTURE §5's bound holds during migration again, so L5K-C1-02's alternative (qualifying
  §5 and ADR-016) is moot. Its sentence "`apply`, `purge`, `reportUnreadable` and `adoptLegacyNow` install at once"
  becomes "`apply`, `purge`, `reportUnreadable` and `adoptLegacyNow` at its default `.userInitiated` install at once
  (the engine's pre-transfer read of a bulk or prefetch job passes `.bulk`, L5K-R14)".

## L5K-R16: every coalesced publication's trailing install
- **The defect (L5K-C2-00, -02, -03).** A publication at `.bulk` or `.prefetch` urgency inside the install window only
  marks the trailing install due (`installDue`); the store owns no timer, so only the engine's alarm runs it, and only
  once the heap holds the store's deadline (ADR-022). The commit path re-read that deadline after every publication
  (RE-S40); the funnel's bulk-lane adoptions (L5K-R14) and the migration loop's batches did not, and since L5K-R1's
  parked-run decision no launch run's apply follows migration to install them. The adopted assets were stored but missed
  by `lookup`, `existingLocalURL` and `hasAsset` until an unrelated install (PR14a, PR14b, probes I and J, PK-R14b).
- **Invariant.** At the end of every engine turn in which the store may have marked an install due, the heap holds a
  store deadline no later than the store's `nextDeadline()`, so nothing published stays out of the readers' snapshot for
  longer than one install interval unless a commit is still pending. Two ways to break it exist: a store call after which
  nothing re-reads the deadline (the enumeration below), and an older answer of the deadline applied after a newer one
  (crossed answers, below).
- **The enumeration: every engine call of a store method**, with what it can leave due and how the deadline is re-read.
  "Install due" means a coalesced publication or a doomed key (`scheduleDoomedKey` marks an install due without
  publishing); "added" marks a re-arm this close-out added (RE-S40 through `refreshStoreDeadline`, or
  `refreshStoreDeadlineAfterPublish`, which skips the read in O(1) while the alarm already wakes for the store within about
  two install intervals, so a bulk sync never reads `nextDeadline()` once per asset, F-12).

  | Engine call site | Store method | Can it leave an install due? | How the deadline is re-read afterwards |
  |---|---|---|---|
  | `runStart` | `open()` | No: open ends with `installSnapshot()`. A failed launch commit leaves its backed-off window, not an install | The first RE-S40 re-read or alarm turn (outside the class) |
  | `runStart` (twice), `pushRetentionScope` | `setRetentionScope` | No: an in-memory field | Nothing to re-read |
  | `runStart` | `makeStagingSink()` | No | Nothing |
  | `reconcileLaunch` | `stagingInventory()`, `planningView()` | No: reads | Nothing |
  | `reconcileLaunch` (`.adoptStaged`) | `publish(…, urgency: .bulk)` | Yes, while the engine starts (no re-read applies before `running`) | **Added:** `runStart` re-reads once running when it published (`refreshStoreDeadlineAfterPublish`); pinned by `reconciledAdoptionReachesTheReaders` (a mutant without it fails) |
  | `reconcileLaunch`; maintenance | `collectStaging(keeping:)` | No: staging files only | Maintenance: `finishMaintenance` (RE-S40); launch: nothing |
  | `releaseSourceCopies` | `adoptionReport()` | No: a read | Nothing |
  | `performShutdown` | `close()` | Terminal | Nothing |
  | `performSync`, `runSteps`, `catchUpWithStore`, `performAwaitAsset`, `joinGroup`, `ensureTask`, `isSyncDue`, `lastSyncedAt`, `diagnostics`, `blobHolders`, `scheduleHeals`, point admission | `planningView()` | No: a read | Nothing |
  | `runSteps`, `ensureTask` | `evictionPlan(toFree:protecting:)` | No: a dry run | Nothing |
  | `applyAndFollow` (a run's, `ensureAvailable`'s) | `apply` | Its dooms mark an install due; it installs at once (`.userInitiated`) when it changed anything | RE-S40 after it in `runSteps` (current run or not) and `ensureTask`; after a failed `apply` the catch-up's RE-S40 (`catchUpWithStore(afterFailedApply:)`) |
  | `runSteps` | `markSynced` | No: an ordered commit inside the call | Nothing left due |
  | `migrateLoop` | `migrateLegacy(maxFiles:)` | Yes: a batch publishes at `.bulk`; phase 3's commit can throw after the publication | **Added:** after every call, returned or thrown (`refreshStoreDeadlineAfterPublish`); pinned by `migrationAdoptionsReachTheReaders` (probes I and J) |
  | `publish` (the commit path) | `publish(…, urgency: lane)` | Yes for the bulk and prefetch lanes | RE-S40 after `committed` (existing); **added** when the job ended during the call and when the call threw (it publishes before its last re-validation, `stillBound`; a failed placement dooms its provisional reference). Both added exits are defensive: neither is known to be reached with an install left due |
  | `permanentMissing` | `recordFailure` | Yes: a failed stale record's blob is doomed and `persistBookkeeping` publishes at `.bulk` | RE-S40 when the job is still current (existing); **added** when the job ended (defensive, as above) |
  | `integrityFailed` | `recordIntegrityFailure` | Yes, at the cap (as above) | As for `recordFailure` |
  | `sparePresent`, `storedLocation` (no migration) | `location(…, recordingAccess: false)` | No | Nothing |
  | `readPresentLocation`, `performAwaitAsset` | `location(…, recordingAccess: true)` | No: a lazy access stamp | Nothing |
  | `storedLocation` (migration pending) | `adoptLegacyNow(id, urgency: .bulk)` | Yes | **Added:** after every such adoption (`refreshStoreDeadlineAfterPublish`); pinned by `syncAdoptionsReachTheReaders` (PR14a), `prefetchedNeighboursReachTheReaders` (PR14b), the shim test (PK-R14b) and the L5K-R14 test's tripwire |
  | `storedLocation` (user-initiated lane, or the L5K-R18 second ask) | `adoptLegacyNow(id, urgency: .userInitiated)` | No: it installs before it returns, a present asset included since L5K-R18 | Nothing left due by it |
  | `performAwaitAsset` (the resolve path) | `adoptLegacyNow(id)` (`.userInitiated`) | No (as above) | Nothing left due by it |
  | `readFreeSpace` (`refreshFreeSpace`, `spaceFailed`, the settling and reclaim reads) | `freeSpace()` | No: a read | Nothing |
  | `fireDue` | `runDueWork()` | Its report carries the store's next deadline | RE-S27: the report re-arms, through `applyStoreDeadline` (crossed answers) |
  | `refreshStoreDeadline` | `nextDeadline()` | — | The re-read itself, through `applyStoreDeadline` |
  | point admission (`answerUnknownWaiters`) | `admit(entry)` | Yes: a content change of a known record dooms its blob, and `admit` publishes only when it adopted a known blob; it may throw after in-memory writes | **Added:** one RE-S40 re-read after the answering pass when it admitted |
  | `performSetPinned` | `setPinned` | No: an ordered commit | RE-S40 (existing) |
  | `performAcquireLease` | `acquireLease` | No: a lease only postpones deletions | Nothing; a lease acquired after shutdown began is released at once (terminal) |
  | `releaseLease(_:)` (`performReleaseLease`) | `releaseLease` | Its answer is the store's new deadline | Applied through `applyStoreDeadline` (RE-S40; it called `setStoreDeadline`) |
  | `purgeTask` | `purge` | Its dooms; it installs at once (`.userInitiated`) | RE-S40 on both paths (existing) |
  | maintenance | `collectGarbage` (orphans doomed with a grace, no install), `evictIfNeeded`, `verifyIntegrity` (install at once) | Their dooms | `finishMaintenance`'s RE-S40 on every exit (existing); **added** on the failed-step exit (a step that threw may have doomed blobs in memory first, ADR-050) |
  | `performReportUnreadable` | `reportUnreadable` | Its doom; it installs at once | RE-S40 in `quarantined` (existing); **added** when it threw |
  | `performStorageReport`, `performMetrics` | `storageReport()`, `metrics()` | No: reads | Nothing |
  | the facade (`AssetClient.perform`) | `verifyRootNow()` | No: a read | Nothing |
  | `publish`'s early exits, `publicationFailed`, `failed`'s resume reads, launch reconciliation | the store's staging sink (`StoreStagingSink.discard`, `readSidecar`) | No: staging files, not the records or the snapshot | Nothing |

  The two calls the ruling named (the funnel's adoption, `migrateLegacy`) and the commit path's re-read keep the O(1)
  shortcut; the other added re-arms are on rare paths (a failure, a job that ended during its publication, a launch with a
  staged download, an admission): those after a publication use the same shortcut, the rest read the deadline in full.
- **Crossed answers (found while enumerating).** The store answers the engine's deadline reads in its own order, and the
  engine resumes their awaits in priority order (the alarm runs at `.utility`, a prefetch driver or the migration loop at
  `.medium`). So an older answer can be applied after a newer one: for example the alarm's `runDueWork()` report ("nothing
  due"), computed before a prefetch adoption marked a trailing install due, applied after that adoption's re-read had put
  the install on the heap, took it off again. Every answer is now applied through `applyStoreDeadline(_:readSince:)`: with
  no update of the store's deadline while it was in flight it replaces the heap's entry as before; otherwise the two may
  have crossed, and the earlier deadline is kept (at worst one early wake, whose report re-arms from the newest deadline).
  Pinned by `crossedDeadlineReadsKeepTheTrailingInstall`: the test seam `holdNextStoreDeadlineRead()` holds one re-read's
  answer ("nothing due") while a bulk adoption leaves the install due and a second re-read schedules it, and the alarm's
  turns are held until both answers are applied; a plain-replace mutant fails it 4 of 4 times. The failing-first commit
  (`296e5a0`) set its premise from the start's own state, which a run could find with the migration's first file already
  adopted; the fix commit sets it through the store and holds the alarm, so the test is deterministic.
- **The tripwire.** `invariantViolations(storeDeadlineDue:)`: when the caller read the store's `nextDeadline()` while the
  engine was settled (`storeDeadlineSettled`: running; no job, run or migration loop; no alarm store work, deadline
  re-read, settling read, presence read, `apply` or catch-up in flight; no owned task but the alarm, the watcher and the
  memory-pressure observer) and the store reported a deadline, the heap must hold a store entry. The store reports a
  deadline whenever `installDue` (its `nextDeadline()` considers the install window then), so this is the ruling's
  "`installDue` implies a store entry" read through the package API, and it also covers every other time-only store
  deadline (a commit window, a reap). The test helper `EngineHarness.idleViolations()` reads the engine, then the store,
  then the engine again, and checks only when the engine was settled both times with the same alarm and store entry (no
  alarm turn ran the store's work in between). Asserted at idle (`expectSettled`: drive the clock until idle-silent, then
  the tripwire) in every new test, in the nine earlier tests of the L5K-R1 file, and in the engine model after every
  operation and at the end of its walk (every caller withdrawn, every group released, every transfer failing at once,
  then idle-silent). On the cycle-2 code it fails the L5K-R14 test, which only counted installs.
- **Tests, failing first** (`30be1bf`, on `1901e91`'s code): `syncAdoptionsReachTheReaders` (PR14a: 20 files, a bulk
  sync during held migration, installs within the limiter), `prefetchedNeighboursReachTheReaders` (PR14b: the store's
  production windows, a user-initiated page visible at once, 11 prefetched neighbours), `migrationAdoptionsReachTheReaders`
  (PR14c, probes I and J: 12 standard files adopted by the sync, 8 on-demand pages only migration adopts, the sync's
  trailing install run first), each also bounding its installs by the limiter (PR14b's and PR14c's bounds added after the
  failing-first commit, `b0fcb68`), and the shim test `prefetchedNeighboursDuringLegacyMigration` (PK-R14b: `SyncTuning`'s default
  interval, `client.prefetch` beside a user-initiated `resolveViaNetwork`). Each failed on its own assertions (the
  readers saw none of the adopted assets; 0 of 11 for `existingLocalURL` and `lookup` through the shims), and
  `adoptionsKeepTheInstallRate` failed on the tripwire. With the fix (`623378b`, `d931f9e`) all pass. The tests that hold
  migration wait for the store's work through `runStoreWork` (drive the clock until the heap is empty and no alarm store
  work is in flight): an empty heap alone is reached when the alarm takes the store's entry before its `runDueWork()`
  installs (L5K-R2 pattern (a)).

## L5K-R17: no hot loop around a store call
- **The defect (L5K-C2-01).** `performMigrateLegacy` returned at once with `remaining > 0` and `finished == false` when the
  queue was empty and the only claimed file was held by an adopt-on-demand, and the engine's loop called it again at once:
  about 280,000 calls a second while a job's adoption hashed the last file (PS3, PSPIN).
- **The fix (as the correctness verifier proposed).** With the queue empty and every claimed file an adopt-on-demand's
  (`MigrationState.onDemand`, set from the claim to the snapshot), the call waits for one such processing
  (`awaitLegacyFlight`), re-reads the queue, the claims and the phase (row k-7), and goes on to the finish check, so the
  same call finishes the migration. A deferred or cancelled adoption puts the file back in the queue, which ends the
  wait, and the next call processes it. Each wait is bounded by one adoption; at shutdown the engine cancels the driver
  whose adoption it waits for (its hash checks cancellation), a resolve's adoption ends on its own, and `close()` resumes
  it through that adoption (row k-5). A claimed file without a mark cannot occur (a batch unclaims every file it took
  before this point, and an adopt-on-demand marks the file in the turn it claims it), so the wait never spins inside the
  store either.
- **The enumeration: every engine loop that repeats a store call**, with why each iteration makes progress or suspends
  on a real event:

  | Loop | Store call | Each iteration |
  |---|---|---|
  | `migrateLoop` (RE-S29) | `migrateLegacy(maxFiles: 64)` | Processes at least one file (adopted, dropped, deferred with its attempt counted: the third deferral keeps the file, so a file is retried at most three times in a row), or waits for an adopt-on-demand (k-7), or finishes, or returns `remaining == 0 && !finished` and backs off to the next maintenance window; never returns at once with nothing done (pinned by `migrationLoopWaitsForTheLastAdoption`: no call while the job's adoption holds the last file, and by the store's `batchWaitsForTheLastOnDemandAdoption`) |
  | `runStart`'s retention loop | `setRetentionScope` | Repeats only when the app set a newer scope during the previous push (the sequence moved): bounded by the app's own calls |
  | the catch-up chain (`manifestCaughtUp` → `catchUpWithStore`) | `planningView()`, then RE-S40 | A view that may predate the copy is not followed and owes one more re-read, made only when the last `apply` or catch-up in flight ends: each repeat follows a real change of the copy or the end of an `apply` |
  | `joinGroup`'s batches (f-14) | `planningView()` only when the copy changed | Each batch registers up to a pipeline's worth of members (progress), with one yield between batches |
  | `performAcquireLease` | `acquireLease` | At most two attempts (`for attempt in 0..<2`), the second after a resolve |
  | point admission (`answerUnknownWaiters`) | `admit`, `planningView()` | One admission per waiter of the pass: finite |
  | the alarm | `runDueWork()` | One turn per deadline the clock reaches; a deadline already due runs at once, and the store's deadlines back off after a failed commit or reap (ADR draft B-23), so the alarm never spins on work it cannot do |
  | store side, called by the engine: `performAdoptLegacyNow`'s loop (k-5) | — | Returns, or waits for a processing in flight (an event), or commits the phase-1 plan once, or takes the file and processes it |

  The engine's other loops (dispatch rounds, the release follow-ups' budgeted removal, the shutdown joins, the apply
  turn's wait) make no store call.
- **Tests, failing first** (`390523a`): the store's `batchWaitsForTheLastOnDemandAdoption` (PS3's shape: `migrateLegacy`
  returned while the adopt-on-demand of the last claimed file ran, with `finished == false`) and the engine's
  `migrationLoopWaitsForTheLastAdoption` with the call-count seam `MigrationProgress.batchCalls` (10 calls in 64 round
  trips through the engine while the job's hash unit was held, 13 to finish). With the fix (`4ce04d9`): the store call
  returns only after that adoption, with `finished == true`; the engine makes no call while the unit is held. The
  engine test's round trips only give a regression the chance to show: the fixed loop makes no call whatever their
  number, so the bound never depends on them.

## L5K-R18: a job promoted during its adoption
- **The defect (L5K-C2-05).** The funnel reads the job's lane before its `adoptLegacyNow` await. A bulk job promoted to the
  user-initiated lane meanwhile (an `ensureAvailable` or a waiter joined it) published its adoption at `.bulk`, so its
  user-initiated asker could return before the readers' snapshot held the asset.
- **The fix.** After a `.bulk` adoption that answered a location, `storedLocation(of:in:lane:)` re-reads the job's lane;
  when it became `.userInitiated` it asks the store once more at `.userInitiated`. The store's present path published only
  for a call that had joined another processing, so a second ask would have answered without an install; it now publishes
  for any `.userInitiated` call too (the adoption that made the asset present may be in a coalesced snapshot only), which
  also gives a user-initiated job whose asset a batch adopted earlier an install before its answer. Cost: one install per
  user-initiated read of an asset already present during migration, an O(1) swap.
- **Tests.** A seam reaches it: `promotedAdoptionInstallsAtOnce` holds a prefetch job's adoption at its hash unit, lets
  `ensureAvailable` join and promote the job, then releases the adoption: on the cycle-2 code `ensureAvailable` returned
  with the asset out of the readers' snapshot (3 of 3 runs, `94b55a3`). The store pin `userInitiatedAskOfACoalescedAdoptionInstalls`
  (a user-initiated ask of an asset a bulk adoption made present installs before it answers). With the fix (`09afc28`)
  both pass; with the engine change alone the engine test still fails, and a mutant whose present path installs only after
  a join fails both.

## L5K-R19: the cycle-2 non-blocking items
- **L5K-C2-04.** Two held variants reach the race in every run (`cb9faef`): `userInitiatedPrefetchReachesTheJoin` and
  `ensureAvailableReachesTheJoin`. The batch is held at the file's hash unit while the job's adoption hashes the same file
  and holds its placement unit (both store executors stepped, the origin answering "not modified" so no manifest decode
  takes a bulk unit); only then is the batch's hash released, so it finds that adoption in flight and waits for it. The
  placement stays held until the store's line of that wait exists, a condition the held placement guarantees, so
  `joins > 0` holds by construction; both keep the zero-transfer assertion. The two stochastic tests stay (they reach the
  race over a migration that runs at its own pace); their premise is in the L5K-R2 table as pattern (a), with the margin
  measured this cycle.
- **L5K-C2-06.** The header and the contract-change line name L5K-R14's package signature change.
- **L5K-C2-07, for ARCHITECTURE §14.** Four defensive branches of L5K-R13 in `Migration/LegacyPhases.swift` are
  unreachable by construction and deliberately untested: the `else { continuation.resume() }` branches of
  `awaitLegacyAdoption` and `awaitLegacyFlight` (each closure runs in the actor's isolation right after the caller's check
  of the same mark, with no suspension between, so the mark is still there) and the no-mark guards of `endLegacyAdoption`
  and `endLegacyOnDemand` (every caller sets the mark before it can end it). `awaitLegacyFlight`'s `else` branch now has
  one more caller, L5K-R17's wait, which also checks the mark first.

## L5K-R2: the compatibility tests' timing dependence
Every test of `Tests/ZTronAssetCompatibilityTests` (71 in 10 suites since cycle 3, the orchestrator's
`CompatibilityShimTests.swift` included, read only) and every harness helper was read against L5-R14's patterns: (a) a wait on a weaker condition than
the assertion needs; (b) a shared fake log counted without a baseline taken at a defined point, or counting what another
engine generation may have added; (c) a fake scripted after an operation that may already consult it; (d) a bounded
number of yields or rounds; (e) a lower bound on, or an exact count of, events a consumer happened to pull; (f) a clock
move racing a driver that has not applied the previous step; (g) a fake-volume mutation in several steps that races the
store's own writes; and L5K-R2's addition, an outcome that depends on whether the engine processed a step before
`AutoAdvancingClock` moved (K-10).

| Test (file: function) | Pattern | Fix |
|---|---|---|
| `MigrationLaunchShimTests: launchSyncDuringLegacyMigration` (L5K-V3-04) | (a): `legacyLeft == 0` waited only for the resolves, while the CCR-K1 downloads left legacy copies for the migration loop or phase 4 to remove later (5 of 6 TSan runs failed); `stored` read the lookups' snapshot, which shows a running batch's adoptions only at the batch's end | After L5K-R1 the post-condition is strict at the sync's return: no transfer at all; every prior-art file out of the tree (each planned file was adopted before its job ended, each unplanned one was present when the run planned); stored read through `availability(scope:)`, the store's state, which the sync's completion orders. The resolves and the known-issue wrapper are gone, and nothing waits for `.syncStarted(_, .launch)` (a run took the launch run's place, so none follows). Cycle 2 (L5K-R15, L5K-C1-03), pattern (a) again: nothing held migration, so `.complete` and the overlap the assertions need depended on the sync reaching the client before migration and the launch run it held back had ended (the verifier's probe: `.upToDate` in 10 of 10 runs with a 50 ms stall after `start()`). Now migration is held at a unit of its first file across the call (`startHoldingMigration`, a `releaser` for the jobs' units) and `heldUnits ⊇ migration` afterwards proves the overlap; the strict assertions hold deterministically, the claimed file being adopted by its job too |
| `MigrationLaunchShimTests: lookupsDuringLegacyMigration` | (a): "all 40 (formerly 320) answer" right after the resolves over a running migration: a resolve that finds a file a still-running batch adopted answers from the store, and that file reaches the lookups only at the batch's end | The migration is held at a unit of its first file (`startHoldingMigration`) while the resolves run (`releaser`), so every adoption in the window is a resolve's, installed before it returns; "none answers after `start()`" replaces "fewer than all" (a held state, not a count race); "all answer" waits for `.syncStarted(_, .launch)`, the launch run the migration loop's end starts when no run took its place (L5K-R1's decision; no other run starts in this test, and the subscription is registered while the migration is held, so the event cannot be missed) |
| `MigrationLaunchShimTests: launchSyncDuringResumedMigration` (new) | written against the patterns | Launch 1's interruption is ordered by events, not timing: the sync's run has started (`EventProbe`), and its joiner is answered in the shutdown turn that cancels the migration; launch 2's post-conditions are the strict ones of the first row. Cycle 2 (L5K-R15, L5K-C1-01): launch 2 ran on inline executors, so its overlap with the resumed migration was a race (the verifier's probe: `.upToDate` in 5 of 10 runs with a 100 ms stall); it now holds the resumed migration across the call as the first row does, with `heldUnits ⊇ migration` afterwards |
| `MigrationLaunchShimTests: prefetchedNeighboursDuringLegacyMigration` (cycle 3, L5K-R16) | written against the patterns, with the production install interval | Migration is held at a unit of its first file across the resolve and the prefetch (`startHoldingMigration`, a `releaser`), so every neighbour is adopted by a prefetch job's pre-transfer read at bulk urgency. The page's visibility is read after `resolveViaNetwork` returned (a user-initiated install precedes the return). The neighbours' visibility is read only once a public condition holds (`waitUntil`, a re-read of the client's answers, never a clock move, L5K-R3): every neighbour stored (`availability`), no job interest, no engine timer or deadline, and no owned task but the held migration loop (the diagnostic report's `engineCounts`). That last clause is what (a) would miss: the alarm takes its entry off the heap before its `runDueWork()` installs, but its task stays owned until that turn ends. The auto-advancing clock passes the alarm's sleep as it registers (K-10), so whether the clock moved before the read is not what the assertion depends on; what it depends on is that a trailing install the engine scheduled has run, which the condition establishes |
| `EngineLegacyMigrationTransferTests: ensureAvailableBesideARunningMigration`, `userInitiatedPrefetchBesideARunningMigration` (engine, recorded here by L5K-R19) | (a), on their premise only: `joins > 0` needs at least one launch out of 20 in which a job's adoption met a batch's processing of the same file, which scheduling decides | Kept as stochastic tests beside the two held variants, which reach the race by construction (L5K-R19). Measured margin this cycle (three runs of both tests, 1-minute load 4.8, a temporary print not committed): 436 to 507 joins per run over the 40 launches, 0 to 3 of 40 launches without a join, 0 to 23 per launch; the premise fails only if all 20 launches of a test meet no join. The per-launch zero-transfer assertions do not depend on scheduling |

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
  the install was handed to the main actor, ahead of the test's continuation; if the resolve adopts it, or since
  L5K-R13 meets the batch's adoption and waits for it, it installs before returning; its `starts.isEmpty` counts a
  fresh source, and since L5K-R1 no job downloads the file either).
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
  Cycle 3: `MigrationLaunchShimTests.configuration(tuning:)` and `rateLimitedTuning` (values), `engineCounts` (one
  diagnostic report, decoded), `waitUntil` (re-reads a public condition until it holds, each read a round trip through the
  client; no bound on the rounds, so not (d); it ends on cancellation, recording the condition that never held).
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

## Close-out cycle 2 — the cycle-1 issues and what became of them
- L5K-C1-00 (blocking: an on-demand adoption racing a batch's adoption of the same file answered `nil`, and the job
  downloaded the file): ruled (L5K-R13) and fixed in WP-C's legacy-migration files under authorisation, failing tests
  first (`5c9612a` → `4811c50`); see "L5K-R13: one adoption per prior-art file". Row k-4, the L5K-R1 section's store
  paragraph, MIGRATION.md step 3, step 4 and §4, K-15 and the shim doc comments now state the real ordering.
- L5K-C1-02 (bulk-lane adoptions bypass the install rate): ruled (L5K-R14) and fixed (`3e51cf8` → `dcd2437`; store
  pin `c857cde`); see "L5K-R14: the install rate of bulk-lane adoptions".
- L5K-C1-01 and L5K-C1-03 (the two strict shim tests' timing dependence): fixed (L5K-R15, `de99d9a`); the two L5K-R2
  rows say how.
- L5K-C1-04 (the CCR-K1 header's stale text): the bullet ends with a status line.
- L5K-C1-05 (no test pinned the migration loop's flag clear at shutdown): pinned in `resumedMigrationSync`'s launch 1
  (true before the stop, false after it, `de99d9a`); mutant M3, which clears the flag only while the engine runs, fails
  it.

## Close-out cycle 3 — the cycle-2 issues and what became of them
- L5K-C2-00, L5K-C2-02 (blocking: the funnel's bulk-lane adoptions never reached the readers' snapshot) and L5K-C2-03
  (blocking: neither did migration's own batch adoptions once a run had taken the parked launch run's place): ruled as a
  class (L5K-R16) and fixed, failing tests first (`30be1bf` → `623378b`), with every engine store call enumerated, the
  missing re-arms added at seven more call sites, crossed deadline answers fixed (`296e5a0` → `d931f9e`) and the tripwire asserted at idle; see
  "L5K-R16: every coalesced publication's trailing install". MIGRATION.md §4 and the L5K-R14 section are corrected.
- L5K-C2-01 (blocking: the migration loop's hot loop while an adopt-on-demand held the last claimed file): ruled
  (L5K-R17) and fixed in `performMigrateLegacy`, failing tests first (`390523a` → `4ce04d9`); every engine loop around a
  store call is enumerated; see "L5K-R17: no hot loop around a store call".
- L5K-C2-05 (a job promoted during its adoption): ruled (L5K-R18) and fixed with a test (`94b55a3` → `09afc28`).
- L5K-C2-04, L5K-C2-06, L5K-C2-07: L5K-R19 (`cb9faef` and this draft).

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
- The one adoption per prior-art file (L5K-R13) with the live executors and on a device: the store tests step its units
  (`SteppedBlockingExecutor`) on `FakeFileSystem`, and the engine tests run them inline there, reaching the race in
  almost every launch on macOS 27 and passing under TSan; nothing measured how often a device reaches it.
- The crossed deadline answers of L5K-R16 under production priorities: the test reproduces the interleaving with a seam
  that holds one answer, not with task priorities (the harness raises every owned task to one priority floor); how often
  a device produces it was not measured.
- The cost of L5K-R16's re-reads and of L5K-R18's extra installs on a device: `nextDeadline()` scans the blob table on a
  full read, which the O(1) shortcut keeps to about one per install interval on the funnel's and the migration loop's
  paths; L5K-R18 adds one O(1) install per user-initiated read of an already present asset during migration. Neither was
  measured (no benchmark, L5K-R11).

## Evidence (close-out cycle 3; macOS 27, Xcode 27.0, Swift 6.4; scratch `.build-k`, `.build-k-tsan`)
- **Failing first (L5K-R16).** On `30be1bf` (`1901e91`'s code plus the tripwire and the tests): `--filter
  "EngineLegacyMigrationTransferTests|EngineModelTests"`: `✘ Test run with 13 tests in 2 suites failed after 2.246
  seconds with 7 issues.`: PR14a (`unseen.isEmpty`, the tripwire), PR14b (`unseen.isEmpty`), probes I/J
  (`unseenPages.isEmpty`, `unseen.isEmpty`, the tripwire), `adoptionsKeepTheInstallRate` (the tripwire); the engine model
  passed. The shim test: `✘ Test run with 1 test in 1 suite failed after 0.013 seconds with 2 issues.`, "existingLocalURL
  answers 0 of 11", "lookup answers 0 of 11". With `623378b` all pass. Mutants afterwards: with only the funnel's re-arm
  (the migration loop's removed), `migrationAdoptionsReachTheReaders` (PR14c, probes I/J) fails with 3 issues while PR14a
  passes; without the start path's re-arm, `reconciledAdoptionReachesTheReaders` fails (`unseen.isEmpty`, the tripwire).
- **Failing first (crossed answers).** On `296e5a0`: the crossing test failed on the older answer having taken the store's
  entry off the heap and on the asset never reaching the readers. With `d931f9e` (the deterministic form of the test): 6
  of 6 runs of the L5K-R1 file pass; a plain-replace mutant of `applyStoreDeadline` fails the test 4 of 4 times
  (`afterOlder == due`, `unseen.isEmpty`), the fix passes 4 of 4.
- **Failing first (L5K-R17).** On `390523a`: the store test `✘ … with 2 issues` (`!returnedEarly`,
  `progress.finished && progress.remaining == 0`); the engine test `✘ … with 2 issues` ("10 migrateLegacy calls while the
  job's adoption held the last file", 13 to finish). With `4ce04d9` both pass.
- **Failing first (L5K-R18).** On `94b55a3`: 3 of 3 runs `✘` on `unseen.isEmpty`. The engine change alone still fails it;
  with `09afc28` it passes 3 of 3, and a mutant whose store present path installs only after a join fails it and the store
  pin.
- **L5K-R19.** The two held variants: 6 of 6 runs pass. The stochastic tests' margin: in the L5K-R2 table.
- `SWIFTPM_SCRATCH=.build-k bash Scripts/verify.sh --quick` on `92aa5a1` and again on `b0fcb68`: `VERIFY: PASS` (Model
  151, Sync 341, Storage 455, Transport 84, Kit 85, Compatibility 71, AppleHosted 104 tests).
- **Runs ×3** (debug, on `8e67d8a`; the simulator build and run beside them, so the 1-minute load went from 5.1 to 297.3
  and back to 54.8): `ZTronAssetCompatibilityTests` `✔ Test run with 71 tests in 10 suites passed` ×3,
  `ZTronAssetSyncTests` 341/341 ×3, `ZTronAssetKitTests` 85/85 ×3, `ZTronAssetStorageTests` 455/455 ×3 (and once more each
  in `--quick` and in the coverage run).
- **TSan** (`--sanitize=thread`): Compatibility `✔ Test run with 71 tests in 10 suites passed after 5.595 seconds.`, Sync
  `✔ Test run with 341 tests in 52 suites passed after 38.205 seconds.` (both on `92aa5a1`, load 3.4 to 11.8), Storage
  `✔ Test run with 455 tests in 60 suites passed after 491.419 seconds.` (on `8e67d8a`, load up to 297); no
  ThreadSanitizer report in any log.
- **Release build** (`swift build -c release --scratch-path .build-k -Xswiftc -warnings-as-errors`): `Build complete!`.
- **Gates.** `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`; `gates.py trace` written to
  `.build-k/trace-check.md`: `TRACE requirements=90 (MUST=78) budgets=14 tests-with-ids=1167`, `TRACE: PASS`;
  `gates.py selftest`: `SELFTEST: PASS`. Every `await` the close-out added in `Sources/` carries a `// REENTRANCY:` line
  (a script over the diff from `1901e91`, 0 missing).
- **Coverage** (`swift test --scratch-path .build-k --enable-code-coverage --skip Benchmarks`, the merged export over the
  seven test bundles, `gates.py coverage`): AppleHosted 99.76 %, Kit 97.83 % (1444/1476), Model 99.31 %, Storage 97.39 %
  (8096/8313), Sync 93.57 % (8567/9156), Transport 99.08 %, `COVERAGE overall lines=96.58% (25055/25941)`, device-only
  share 0.68 %, `COVERAGE: PASS` (L5K-R12: every per-target figure above its floor). The shims in the compatibility bundle:
  98.18 % (538/548), unchanged. Lines this close-out added that no test runs, for ARCHITECTURE §14: the defensive re-arms
  of `publish` when the job ended during its publication (`EngineDispatch.swift`), of `permanentMissing` and
  `integrityFailed` when the job ended (`EngineFailures.swift`), of maintenance's failed-step exit (`EngineCommands.swift`)
  and of a `migrateLegacy` call that throws while the engine runs (`EngineRuns.swift`); the tripwire's violation message
  (reached only when the invariant breaks, as in the failing-first runs); and text-only changes of lines that were
  uncovered before (`storedLocation`'s catch, `reconcileLaunch`'s early `return false` exits).
- **iOS.** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-k/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, only the informational `IDERunDestination` line.
- **iOS Simulator** (iPhone 18 Pro `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0, the task's command under
  `caffeinate -i`, on `8e67d8a`): `** TEST SUCCEEDED **`; `xcresulttool … summary`: `result: Passed`, 1,291 tests, 1,291
  passed, 0 failed, 0 skipped, 0 expected failures (`Test-ZTronAssetKit-2026.10.23_23-25-07-+0200.xcresult`). On
  `b0fcb68`, which adds two limiter bounds to two engine tests, the Sync bundle again (`-only-testing:ZTronAssetSyncTests`):
  `result: Passed`, 341 of 341 (`Test-ZTronAssetKit-2026.10.23_23-45-26-+0200.xcresult`), with the Sync target once more in
  debug (341/341) and under TSan (`✔ Test run with 341 tests in 52 suites passed after 28.131 seconds.`, no report). The
  simulator is shut down.
- **No benchmark** was run (L5K-R11).
- **Writes.** Nothing outside the repository except the simulator's device container (ADR-051). `TMPDIR`, the module
  caches and `LLVM_PROFILE_FILE` under `.build-k/tmp` (unset for the coverage run, whose profiles SwiftPM writes under
  `.build-k`), derived data under `.build-k/xcode*`; the mutants and the temporary join-count print were reverted before
  any commit; `python3 -B`, so no `Scripts/__pycache__`; `docs/TRACEABILITY.md` untouched (the trace gate wrote to
  `.build-k`).

## Evidence (close-out cycle 2; macOS 27, Xcode 27.0, Swift 6.4; scratch `.build-k`, `.build-k-tsan`)
- **Failing first (L5K-R13).** On `5c9612a` (the cycle-1 code plus the tests and the two unused `MigrationState`
  fields): `swift test --scratch-path .build-k --skip Benchmarks --filter LegacyOnDemandRaceTests`: `✘ Test run with 7
  tests in 1 suite failed after 0.031 seconds with 17 issues.`, every issue on the defect's assertions (an answer before
  the other call's adoption ended, a read of the file by the joining call, a `nil` answer, `progress.dropped == 0`, a
  second hash, no wait, the file queued twice, no `.closed`); `--filter BesideARunningMigration` (20 launches each): `✘
  Test run with 2 tests in 1 suite failed after 1.634 seconds with 24 issues.`, 22 of 40 launches with 1 to 5 prior-art
  files downloaded, and both race premises unmet (no wait line yet). With the fix (`4811c50`): `✔ Test run with 7 tests
  in 1 suite passed`, `✔ Test run with 2 tests in 1 suite passed`, and with WP-C's `LegacyEdgeTests` and
  `LegacyMigrationTests` `✔ Test run with 35 tests in 3 suites passed`.
- **Failing first (L5K-R14).** On `3e51cf8`: `✘ Test run with 1 test in 1 suite failed after 0.050 seconds with 1
  issue.`, `syncInstalls <= 2` ("101 snapshot installs for a sync that adopted 100 files"). With the fix (`dcd2437`):
  passes; 1 install for the sync and 4 for the pages in 3 of 3 runs (a temporary print, not committed).
- **L5K-C1-05.** Mutant M3 (the migration loop clears `launchRunWaiting` only while the engine runs), applied and
  reverted: `--filter resumedMigrationSync` fails with `Expectation failed: !waitingAfterStop`.
- `SWIFTPM_SCRATCH=.build-k bash Scripts/verify.sh --quick`: `VERIFY: PASS` on `ddaacb3` and again on `708ef84` (Model
  151, Sync 332, Storage 453, Transport 84, Kit 85, Compatibility 70, AppleHosted 104 tests).
- **Runs ×3** (debug, on `ddaacb3`, 1-minute load 4.4 rising to 11.9): `ZTronAssetCompatibilityTests` `✔ Test run with
  70 tests in 10 suites passed` ×3; `ZTronAssetKitTests` 85/85 ×3; `ZTronAssetSyncTests` 332/332 ×3;
  `ZTronAssetStorageTests` 453/453 ×3.
- **TSan** (`--sanitize=thread`, on `ddaacb3`, load 9.1 to 7.1): Compatibility 70/70, Sync `✔ Test run with 332 tests in
  52 suites passed after 27.510 seconds.`, Storage `✔ Test run with 453 tests in 60 suites passed after 206.281
  seconds.`; no ThreadSanitizer report in any log.
- **Stress of the new and changed tests** (the compatibility target, `EngineLegacyMigrationTransferTests`,
  `LegacyOnDemandRaceTests`; on `708ef84`): ×10 with the 1-minute load at 109.7 to 169.9 (the simulator build beside
  them), 10 of 10 passed; ×5 under TSan with the load falling from 68.7 to 5.7, 5 of 5 passed, no ThreadSanitizer report.
- **Release build** (`swift build -c release --scratch-path .build-k -Xswiftc -warnings-as-errors`): `Build complete!`.
- **Gates.** `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`; `gates.py trace` written to
  `.build-k/trace-check.md`: `TRACE requirements=90 (MUST=78) budgets=14 tests-with-ids=1155`, `TRACE: PASS`;
  `gates.py selftest`: `SELFTEST: PASS`.
- **Coverage** (`swift test --scratch-path .build-k --enable-code-coverage --skip Benchmarks`, the merged export over the
  seven test bundles, `gates.py coverage`): AppleHosted 99.76 %, Kit 97.83 % (1444/1476; cycle 1 measured 1445/1476 and
  no Kit source changed since), Model 99.31 %, Storage 97.38 % (8076/8293), Sync 93.63 % (8440/9014), Transport 99.08 %,
  `COVERAGE overall lines=96.62% (24908/25779)`, device-only share 0.68 %, `COVERAGE: PASS` (L5K-R12: every per-target
  figure above its floor). The shims in the compatibility bundle (`llvm-cov report` over `Shims/*.swift`): 98.18 %
  (538/548), unchanged.
- **iOS.** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-k/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, only the informational `IDERunDestination` line.
- **iOS Simulator** (iPhone 18 Pro `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0, the task's command under
  `caffeinate -i`): on `ddaacb3`, `** TEST SUCCEEDED **`, `xcresulttool … summary`: `result: Passed`, 1,279 tests, 1,279
  passed, 0 failed, 0 skipped, 0 expected failures (`Test-ZTronAssetKit-2026.10.23_20-25-22-+0200.xcresult`); on
  `708ef84`, which renames one engine test, the Sync bundle again (`-only-testing:ZTronAssetSyncTests`): `result:
  Passed`, 332 of 332 (`Test-ZTronAssetKit-2026.10.23_20-36-50-+0200.xcresult`). The simulator is shut down.
- **No benchmark** was run (L5K-R11).
- **Writes.** Nothing outside the repository except the simulator's device container (ADR-051). `TMPDIR`, the module
  caches and `LLVM_PROFILE_FILE` under `.build-k/tmp` (unset for the coverage run, whose profiles SwiftPM writes under
  `.build-k`), derived data under `.build-k/xcode*`; the temporary probe prints were reverted before any commit;
  `python3 -B` or plain script runs, so no `Scripts/__pycache__`.

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
