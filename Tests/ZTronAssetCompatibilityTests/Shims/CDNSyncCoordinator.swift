import Combine
import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's bulk-sync coordinator (`CDNSyncCoordinator.swift`, read-only): a main-actor
/// `ObservableObject` publishing `CDNSyncProgress`, as an adapter over `AssetClient.sync` and the client's events.
///
/// Combine stays in this test target (R-CAR-9: bridges live in ZTronCarouselCore). The client does what the prior art's
/// loop did, without its defects (D-2, D-8, D-15): it fetches the manifest, reconciles before downloading (a directory
/// change moves nothing and downloads nothing, a removed entry is deleted, R-SYN-8), downloads what is missing as
/// independent jobs, and writes the once-per-version stamp only after a complete run, inside its own index, never in
/// `UserDefaults` (D-6, R-SYN-9). The coordinator maps the run's events and outcome onto the prior art's progress cases
/// (sync.md §10.6): `syncProgress` is `.syncing`, `notDue` is `.upToDate`, `complete` is `.complete`, every other
/// outcome is `.failed(reason:)` with the outcome's description.
@MainActor
public final class CDNSyncCoordinator: ObservableObject {
    /// The prior art's published progress.
    @Published public private(set) var progress: CDNSyncProgress = .idle
    /// What the last run reconciled (relocations and prunes), `nil` before a run reported one (new in the shims: the
    /// prior art returned it from `CDNLocalStore.reconcile(newManifest:)` and discarded it).
    public private(set) var lastReconciliation: CDNReconciliationSummary?

    /// The client this coordinator drives.
    nonisolated public let client: AssetClient
    /// The manifest source of `verifyFullyAvailable()`: the client applies manifests internally and hands no entries
    /// out. Its fetch must reach the origin on its own (an app key included, SPEC §2.3).
    private let cdn: any CDNProviding
    /// The client's lookups, for `verifyFullyAvailable()`.
    private let localStore: CDNLocalStore

    /// A coordinator over `client`; `cdn` answers `verifyFullyAvailable()`'s manifest fetch.
    public convenience init(client: AssetClient, cdn: any CDNProviding) {
        self.init(client: client, cdn: cdn, localStore: CDNLocalStore(client: client))
    }

    /// The prior art's initialiser. The coordinator drives the client of `localStore`'s install point, built from `cdn`
    /// there when the point is empty (as `CDNAssetResolver(cdn:localStore:)` does), so it shares the installed client;
    /// `cdn` stays the manifest source of `verifyFullyAvailable()`. `defaults` and `appVersionProvider` are ignored: the
    /// stamp lives in the client's index and the app version comes from its environment, in the same format (D-6,
    /// R-SYN-9); the client migrates the prior art's `UserDefaults` stamp once (R-STO-11).
    @available(*, deprecated, message: "Build one AssetClient (CDNProviderFactory.install(_:)) and use CDNSyncCoordinator(client:cdn:)")
    public convenience init(
        cdn: any CDNProviding,
        localStore: CDNLocalStore = .shared,
        defaults: UserDefaults = .standard,
        appVersionProvider: @escaping @Sendable () -> String = CDNSyncCoordinator.defaultAppVersion
    ) {
        self.init(sharingClientOf: localStore, cdn: cdn)
    }

    /// What the prior-art initialiser does, without its ignored parameters (tests call it: constructing `UserDefaults`
    /// is off limits for them).
    convenience init(sharingClientOf localStore: CDNLocalStore, cdn: any CDNProviding) {
        self.init(client: localStore.installPoint.installClient(for: cdn), cdn: cdn, localStore: localStore)
    }

    private init(client: AssetClient, cdn: any CDNProviding, localStore: CDNLocalStore) {
        self.client = client
        self.cdn = cdn
        self.localStore = localStore
    }

    /// The prior art's version string, `"<CFBundleShortVersionString>+<CFBundleVersion>"` (`"0"` for a missing key).
    /// `nonisolated` because it is the default value of a `@Sendable` parameter (SPEC Appendix A, 1). The client reads
    /// the app version through its environment (`LiveAppVersionSource`, the same format), so the shims use this only
    /// for the prior-art initialiser's default.
    nonisolated public static func defaultAppVersion() -> String {
        CDNSyncCoordinator.appVersion(from: Bundle.main.infoDictionary)
    }

    /// `"<CFBundleShortVersionString>+<CFBundleVersion>"` of an Info.plist dictionary, `"0"` for a missing key (the
    /// seam `defaultAppVersion()` reads the main bundle through).
    nonisolated static func appVersion(from info: [String: Any]?) -> String {
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "0"
        return "\(shortVersion)+\(buildNumber)"
    }

    /// The launch sync: `AssetClient.sync(.ifDue)`, safe on every launch. `.upToDate` without network when the refresh
    /// policy says no; otherwise `.syncing` while the run (the client's launch run, if one is active, or a new one)
    /// transfers, then `.complete` or `.failed(reason:)`. A failed or partial run leaves the sync due, so the next launch
    /// retries and downloads only what is still missing. A run whose remaining jobs are blocked (offline, an open
    /// breaker, a throttle, space, and under the default policies Low Power Mode, Low Data Mode or serious thermal
    /// pressure) is `.failed(reason: "blocked(…)")` and leaves the sync due; the client then finishes it by itself once
    /// the gate opens, which this coordinator does not observe, so `progress` keeps the call's outcome while those
    /// assets arrive.
    ///
    /// On a launch during legacy migration (the first launch after adoption, and any later launch that resumes an
    /// unfinished migration), a call made while migration is still adopting the prior art's files starts a run at once,
    /// and that run adopts the files migration has not reached yet instead of downloading them (R-STO-11: before any
    /// transfer the client adopts a file migration can still adopt, even one a migration batch is adopting at that moment,
    /// orchestrator rulings L5K-R1 and L5K-R13); it takes the place of the launch run that waited for migration, so the
    /// launch still syncs once (MIGRATION.md step 4, K-15).
    public func syncIfNeeded() async {
        // REENTRANCY: k-1 (proposed) — nothing is read after it.
        await self.run(.ifDue)
    }

    /// Fetches a fresh manifest from `cdn` and returns every asset in it that is not stored at its content
    /// (`CDNLocalStore.missingOrStaleAssets`), downloading nothing. Throws only when the manifest fetch throws.
    ///
    /// The fetch is `cdn`'s own request. `StaticManifestCDNProvider` sends no app key, so at SPEC §2.3's origin, which
    /// answers 403 without one, this throws `StaticManifestCDNProviderError.badResponse` on every call: pass a manifest
    /// source that sends the key to that origin and no other (MIGRATION.md step 4, K-5).
    public func verifyFullyAvailable() async throws -> [CDNAsset] {
        // REENTRANCY: k-3 (proposed) — nothing of the coordinator is read across the fetch; the client's snapshot is
        // read after it, so the comparison uses what is stored when the manifest arrived.
        let manifest = try await self.cdn.fetchManifest()
        return self.localStore.missingOrStaleAssets(against: manifest)
    }

    /// A repair pass regardless of the refresh policy: `AssetClient.sync(.force)`, publishing progress as
    /// `syncIfNeeded()` does. Unlike the prior art, a complete repair also writes the sync stamp, which is true and
    /// harmless (sync.md §12.3: the prior art skipped it only because its flag meant "once per version"). A repair
    /// while legacy migration is still adopting adopts the files it has not reached yet, as `syncIfNeeded()` does
    /// (L5K-R1, L5K-R13).
    public func verifyAndRepair() async {
        // REENTRANCY: k-1 (proposed) — nothing is read after it.
        await self.run(.force)
    }

    /// One sync through the client, with its progress published as it arrives.
    ///
    /// The stream is subscribed before the run is requested, so the run this call starts, or the active run it joins
    /// (whose latest progress the subscription replays), reports into `progress`. Once the outcome is in, the follower
    /// is cancelled and awaited, so no progress event can overwrite the final state. Concurrent calls join the same
    /// single-flight run and publish the same outcome.
    private func run(_ mode: SyncMode) async {
        let events: AsyncStream<AssetEvent>
        do {
            // REENTRANCY: k-1 (proposed) — nothing of the coordinator is read across the subscription; `progress` is
            // written afterwards only by this call's follower and its final outcome.
            events = try await self.client.subscribe()
        } catch {
            self.finish(.failed(error))
            return
        }
        // Progress never moves backwards within a run by construction (sync.md §10.6): the engine's completed count is
        // monotone and one subscription delivers a run's progress in order, newest-wins.
        let follower = Task { @MainActor [weak self] in
            // REENTRANCY: k-2 (proposed) — each event is applied in the turn it arrives, after re-reading `self` (weak).
            for await event in events {
                if case .syncProgress(_, let progress) = event {
                    self?.progress = CDNSyncProgress(progress: progress)
                }
            }
        }
        // REENTRANCY: k-1 (proposed) — the follower publishes progress meanwhile; the outcome is applied only after the
        // follower ended (below).
        let outcome = await self.client.sync(mode)
        follower.cancel()
        // REENTRANCY: k-1 (proposed) — the follower has ended, so the outcome is the last value this call publishes.
        await follower.value
        self.finish(outcome)
    }

    /// Publishes a run's outcome (sync.md §10.6) and what it reconciled.
    private func finish(_ outcome: SyncOutcome) {
        self.progress = CDNSyncProgress(outcome: outcome)
        switch outcome {
        case .complete(let report), .completeWithFailures(let report), .blocked(_, let report):
            self.lastReconciliation = CDNReconciliationSummary(report: report)
        case .notDue, .failed:
            break
        }
    }
}
