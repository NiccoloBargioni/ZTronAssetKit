#if canImport(BackgroundAssets)
import ZTronAssetModel

/// The Apple-hosted tier as a `RemoteSource` (R-APL-1…4, R-CLN-10; WP-E).
///
/// Compiled only where BackgroundAssets exists and available from iOS 26 / macOS 26 (R-APL-1; the macOS clause is
/// required for the host build, APPLE-API-VERIFICATION §1.2). All logic runs against a `PackBackend`, so it is
/// tested with `FakePackBackend`. Catalog in the essential pack, read before any update check is awaited
/// (transport-2 T2-14); pack/catalog skew is `transient(.sourceVersionSkew)`, never integrity (T2-12); a pack is
/// released only after the adopting generation is durably committed (store-1 S1-10).
@available(iOS 26.0, macOS 26.0, *)
public final class AppleHostedRemoteSource: RemoteSource {
    /// The configuration.
    public let configuration: AppleTierConfiguration
    /// The pack seam.
    public let backend: any PackBackend
    /// Where bytes go.
    public let staging: any StagingSink
    /// Where `apple` lines go (ADR-047): the environment's route, tap-only in tests.
    public let log: LogRoute
    /// Staging admission, update checks, releases (the source's only mutable state).
    let state: AppleSourceState
    /// Single-flight pack availability (transport-2 T2-14).
    let packs: PackAvailabilityCoordinator
    /// Staging access shared by the catalog reader and every transfer.
    let copier: PackCopier

    /// Creates the source; touches no pack API (R-APL-1).
    public init(configuration: AppleTierConfiguration, backend: any PackBackend, staging: any StagingSink, log: LogRoute) {
        self.configuration = configuration
        self.backend = backend
        self.staging = staging
        self.log = log
        let state = AppleSourceState()
        self.state = state
        self.packs = PackAvailabilityCoordinator(backend: backend)
        self.copier = PackCopier(backend: backend, staging: staging, state: state)
    }

    /// `"apple-hosted"`.
    public var originID: String {
        "apple-hosted"
    }

    /// No priority, no resume, no background session; keeps source copies (R-CLN-10).
    public var capabilities: RemoteSourceCapabilities {
        RemoteSourceCapabilities(
            tier: .appleHosted,
            supportsPriority: false,
            supportsResume: false,
            supportsBackground: false,
            keepsSourceCopies: true
        )
    }

    /// Reads the catalog from the essential pack; the digest is the pseudo-ETag (R-APL-4).
    ///
    /// The installed catalog is read first; the update check runs afterwards in a task the source owns and is
    /// never awaited (transport-2 T2-14), so its findings (`removedSources`, `updateChecked`) are those of checks
    /// that finished before this fetch began, each reported once, on `notModified` too (T2-20). The pseudo-ETag is
    /// `"sha256:<hex>"` (quotes included, like a strong HTTP tag) of the bytes the store staged.
    public func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        guard let catalog = PackLocation(remotePath: "\(self.configuration.catalogPackID)/\(self.configuration.catalogPath)") else {
            self.log.log(.apple, .fault, "the configured catalog pack id or path is not a valid pack location")
            throw .rejected(.invalidURL)
        }
        let report = await self.state.checkReport()
        let reader = AppleCatalogReader(copier: self.copier, packs: self.packs, log: self.log)
        let read = await reader.read(catalog, request: request)
        if request.allowsUpdateCheck && self.configuration.updateCheckOnManifestFetch {
            await self.state.scheduleUpdateCheck(self.backend, log: self.log)
        }
        let installed: AppleCatalogReader.Catalog
        switch read {
        case .success(let value):
            installed = value
        case .failure(let error):
            throw error
        }
        let etag = ETag(rawValue: "\"sha256:\(installed.digest.hex)\"")
        await self.state.noteCatalog(etag)
        await self.state.acknowledge(report)
        if let etag, etag == request.ifNoneMatch {
            return .notModified(removedSources: report.removed)
        }
        self.log.log(.apple, .info, "catalog read from pack \(catalog.pack): \(installed.bytes.count) bytes")
        let payload = ManifestPayload(
            bytes: installed.bytes,
            etag: etag,
            origin: .installedPack(updateChecked: report.updateChecked),
            removedSources: report.removed
        )
        return .fetched(payload)
    }

    /// Streams the pack file into staging (adopt-and-release, ADR-027): the attempt runs in a task of its own and
    /// ends its stream with `.staged` (no HTTP status, never resumed) for the engine to publish through the hash path.
    public func transfer(_ request: TransferRequest) async -> any TransferHandle {
        let parts = PackTransferDriver.Parts(copier: self.copier, packs: self.packs, state: self.state, log: self.log)
        return PackTransferHandle.start(request, parts: parts)
    }

    /// Packs have no re-attachable transfers.
    public func reattachedTransfers() async -> [ReattachedTransfer] {
        []
    }

    /// Nothing to cancel.
    public func cancelTransfer(_ name: StagingFileName) async {}

    /// Runs `PackReleasePlanner` and removes the packs it selects.
    ///
    /// The report is the store's durably committed adoption (ADR-027, store-1 S1-10); the source also remembers
    /// which media packs hold adopted content, for `sourceCopyBytes()`. The report is surveyed in this task in
    /// bounded slices (C2) before the state actor is entered. A pack the system no longer has counts as released; a
    /// failed removal is reported and planned again by the next call. Each pack is released at most once per catalog
    /// generation (the catalog's pseudo-ETag), so a pack that comes back is never released in a loop, unless a
    /// transfer of this source downloaded it again on demand.
    public func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        guard let catalogPack = PackID(rawValue: self.configuration.catalogPackID) else {
            return ReclaimReport()
        }
        let survey = await ReleaseSurvey.survey(report, catalogPack: catalogPack, retention: self.configuration.retention)
        let plan = await self.state.planRelease(survey)
        var reclaim = ReclaimReport()
        for pack in plan.packs {
            let succeeded: Bool
            do {
                try await self.backend.remove(pack)
                succeeded = true
            } catch {
                succeeded = error == .packNotFound
                if !succeeded {
                    reclaim.failed[pack.rawValue] = PackErrorMapping.transferError(error)
                    let reason = String(describing: error)
                    self.log.log(.apple, .error, "releasing pack \(pack) failed: \(reason)")
                }
            }
            if succeeded {
                reclaim.released.append(pack.rawValue)
                self.log.log(.apple, .info, "released pack \(pack): every catalog entry in it is adopted or excluded")
            }
            await self.state.finishRelease(pack, succeeded: succeeded, generation: plan.generation)
        }
        return reclaim
    }

    /// Bytes the OS still holds in media packs whose entries were adopted, summed from `PackBackend.installedBytes`
    /// (R-CLN-9, H-7, transport-2 T2-13): a released pack reports nothing, and one a transfer downloaded again counts.
    public func sourceCopyBytes() async -> Int64 {
        var total: Int64 = 0
        for pack in await self.state.sourceCopyPacks() {
            total += max(0, await self.backend.installedBytes(of: pack) ?? 0)
        }
        return total
    }

    /// Packs have no background URLSession.
    public func handleBackgroundEvents(identifier: String) async {}

    /// Cancels pack waiters and returns after every in-flight `writeStaged` of this source returned.
    ///
    /// Staging admission closes first, so no staging call starts afterwards, and a copy in flight stops at its next
    /// chunk and removes its file, so the drain waits for at most one more ≤ 1 MiB unit per copy. A copy that had
    /// already written its last chunk finishes; if its transfer was stopped, its file is left for the next launch's
    /// staging GC (ADR-028). The update check is cancelled, not awaited.
    public func invalidate() async {
        await self.state.close()
        await self.packs.close()
        await self.state.drain()
    }
}
#endif
