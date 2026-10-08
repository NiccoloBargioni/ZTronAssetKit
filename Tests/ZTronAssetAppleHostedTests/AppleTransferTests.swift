import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

private let assetA = PackAsset("ZTronMedia/images/a.heic", "pixels of a")
private let assetB = PackAsset("ZTronMedia/images/b.heic", "pixels of b, longer")
private let extra = PackAsset("ZTronExtras/sounds/c.wav", "a sound")

private let mediaFiles = [assetA.path: assetA.bytes, assetB.path: assetB.bytes]

/// R-APL-1, R-APL-3: assets are copied out of packs into staging (transport.md §11.3, ADR-027).
@Suite("Apple tier: transfers")
struct AppleTransferTests {
    @available(macOS 26.0, *)
    @Test("R-APL-1: the Apple source satisfies RemoteSource end to end against a fake PackBackend", .timeLimit(.minutes(1)))
    func endToEnd() async throws {
        let fixture = AppleTierFixture(installed: [
            Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: mediaFiles, Packs.extras: [extra.path: extra.bytes],
        ])
        let source: any RemoteSource = fixture.source
        #expect(source.originID == "apple-hosted")
        #expect(
            source.capabilities
                == RemoteSourceCapabilities(
                    tier: .appleHosted, supportsPriority: false, supportsResume: false, supportsBackground: false,
                    keepsSourceCopies: true
                )
        )

        let manifest = try await source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        guard case .fetched(let payload) = manifest else {
            Issue.record("expected the catalog, got \(manifest)")
            return
        }
        #expect(payload.bytes == AppleTierFixture.catalogBytes)

        let request = assetA.request()
        let handle = await source.transfer(request)
        #expect(handle.id == request.id)
        #expect(handle.attempt == request.attempt)
        let updates = await collect(handle)
        let staged = StagedFile(name: request.partialName, byteCount: Int64(assetA.bytes.count), resumed: false, httpStatus: nil, etag: nil)
        #expect(updates == [.staged(staged)])
        #expect(fixture.staging.contents[request.partialName] == assetA.bytes)

        #expect(await source.reattachedTransfers().isEmpty)
        await source.cancelTransfer(request.partialName)
        await source.handleBackgroundEvents(identifier: "com.example.background")
        #expect(fixture.staging.contents[request.partialName] == assetA.bytes, "neither call touches staging")

        let reclaim = await source.reclaimSourceCopies(
            AdoptionReport(
                manifestRemotePaths: [assetA.remotePath, assetB.remotePath, extra.remotePath],
                adoptedRemotePaths: [assetA.remotePath, assetB.remotePath, extra.remotePath]
            )
        )
        #expect(reclaim == ReclaimReport(released: ["ZTronExtras", "ZTronMedia"]))
        #expect(fixture.backend.installedPacks == [Packs.catalog])
        #expect(await source.sourceCopyBytes() == 0)
        await source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: constructing the Apple source and selecting the tier call no pack API", .timeLimit(.minutes(1)))
    func constructionTouchesNoPack() async throws {
        let backend = FakePackBackend(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        let resolved = AppleHostedTier.resolve(
            configuration: RemoteConfiguration(http: nil, appleHosted: AppleTierConfiguration(), awsOnly: false),
            staging: FakeStagingSink(),
            packBackend: backend,
            log: .tapOnly(nil),
            makeAWS: { _ in FakeRemoteSource(originID: "https://unused.example.com:443") }
        )
        let source = try resolved.get()
        #expect(source.originID == "apple-hosted")
        #expect(source.capabilities.tier == .appleHosted)
        #expect(source is AppleHostedRemoteSource)
        #expect(backend.calls.isEmpty)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: concurrent fetches of assets in one pack trigger one ensureAvailable", .timeLimit(.minutes(1)))
    func concurrentFetchesShareOnePackDownload() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let first = await fixture.source.transfer(assetA.request())
        let second = await fixture.source.transfer(assetB.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 2)
        fixture.backend.releaseEnsure(Packs.media, with: .install(progress: []))

        let firstUpdates = await collect(first)
        let secondUpdates = await collect(second)
        #expect(firstUpdates.last.map(Self.isStaged) == true, "\(firstUpdates)")
        #expect(secondUpdates.last.map(Self.isStaged) == true, "\(secondUpdates)")
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.media) }.count == 1)
        #expect(fixture.staging.contents[assetB.request().partialName] == assetB.bytes)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a cancelled waiter leaves the shared pack download running for the others", .timeLimit(.minutes(1)))
    func cancelledWaiterLeavesOthersRunning() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let first = await fixture.source.transfer(assetA.request())
        let second = await fixture.source.transfer(assetB.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 2)

        first.cancel()
        #expect(await collect(first) == [.failed(.cancelled(.byClient))])
        #expect(await fixture.source.packs.waiterCount(on: Packs.media) == 1)
        #expect(!fixture.backend.calls.contains(.ensureCancelled(Packs.media)))

        fixture.backend.releaseEnsure(Packs.media, with: .install(progress: []))
        #expect(await collect(second).last.map(Self.isStaged) == true)
        #expect(fixture.staging.contents[assetA.request().partialName] == nil)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: the pack download is cancelled when its last waiter leaves", .timeLimit(.minutes(1)))
    func lastWaiterLeavingCancelsTheDownload() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let handle = await fixture.source.transfer(assetA.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        handle.cancel()
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
        await fixture.backend.waitFor(.ensureCancelled(Packs.media))
        #expect(await fixture.source.packs.waiterCount(on: Packs.media) == 0)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: pause ends a pack transfer as not resumable and keeps nothing in staging", .timeLimit(.minutes(1)))
    func pauseEndsNotResumable() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let handle = await fixture.source.transfer(assetA.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        handle.setPriority(.bulk)
        handle.pause()
        handle.cancel()
        #expect(await collect(handle) == [.paused(resumable: false)])
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a control after the copy finished discards the staged file and ends the stream once", .timeLimit(.minutes(1)))
    func controlAfterCopyDiscardsTheFile() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles], staging: gated)
        gated.arm(.afterWrite)
        let handle = await fixture.source.transfer(assetA.request())
        await gated.waitForHeldWrites(1)
        handle.cancel()
        gated.open()
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
        #expect(gated.base.contents.isEmpty)
        #expect(gated.events == ["write returned", "discard"])
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a transfer cancelled before it waits for its pack starts no pack download", .timeLimit(.minutes(1)))
    func cancelBeforePackWaitStartsNothing() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles], staging: gated)
        gated.arm(.afterWrite)
        let handle = await fixture.source.transfer(assetA.request())
        await gated.waitForHeldWrites(1)
        handle.cancel()
        gated.open()
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
        #expect(!fixture.backend.calls.contains(.ensure(Packs.media)))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a stopped transfer whose copy outlives invalidate leaves the copy for staging GC", .timeLimit(.minutes(1)))
    func stoppedCopyOutlivingInvalidate() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles], staging: gated)
        gated.arm(.afterWrite)
        let request = assetA.request()
        let handle = await fixture.source.transfer(request)
        await gated.waitForHeldWrites(1)
        handle.cancel()
        let invalidation = Task {
            await fixture.source.invalidate()
        }
        await fixture.source.state.waitForDrain()
        gated.open()
        await invalidation.value
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
        #expect(gated.base.contents[request.partialName] == assetA.bytes)
        #expect(!gated.events.contains("discard"))
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a transfer stopped before its copy reads a chunk opens no pack file", .timeLimit(.minutes(1)))
    func stopBeforeTheFirstChunkReadsNothing() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles], staging: gated)
        gated.arm(.beforeWrite)
        let handle = await fixture.source.transfer(assetA.request())
        await gated.waitForHeldWrites(1)
        handle.pause()
        gated.open()
        #expect(await collect(handle) == [.paused(resumable: false)])
        #expect(!fixture.backend.calls.contains(.open(Packs.media, assetA.path)))
        #expect(gated.base.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: invalidate stops a copy in flight at its next chunk and leaves nothing in staging", .timeLimit(.minutes(1)))
    func invalidateStopsACopyInFlight() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles], staging: gated)
        gated.arm(.beforeWrite)
        let handle = await fixture.source.transfer(assetA.request())
        await gated.waitForHeldWrites(1)
        let invalidation = Task {
            await fixture.source.invalidate()
        }
        await fixture.source.state.waitForDrain()
        gated.open()
        await invalidation.value
        #expect(await collect(handle) == [.failed(.cancelled(.byClient))])
        #expect(!fixture.backend.calls.contains(.open(Packs.media, assetA.path)))
        #expect(gated.base.contents.isEmpty)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a staged copy whose update stream already ended is discarded instead of delivered", .timeLimit(.minutes(1)))
    func stagedCopyForAnEndedStreamIsDiscarded() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles])
        let request = assetA.request()
        let location = try #require(PackLocation(remotePath: assetA.remotePath))
        let copied = await fixture.source.copier.copy(location, as: request.partialName, maxBytes: request.maxBytes)
        #expect(copied == .copied(bytes: Int64(assetA.bytes.count), digest: ContentHash.sha256(of: assetA.bytes)))
        // The consumer dropped the stream after the driver's stop check: the stream has ended before the yield.
        let (_, updates) = AsyncStream.makeStream(of: TransferUpdate.self)
        updates.finish()
        let file = StagedFile(name: request.partialName, byteCount: Int64(assetA.bytes.count), resumed: false, httpStatus: nil, etag: nil)
        await PackTransferDriver.deliver(.staged(file), to: updates, copier: fixture.source.copier)
        #expect(fixture.staging.contents[request.partialName] == nil)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: dropping the update stream cancels the transfer", .timeLimit(.minutes(1)))
    func droppingTheStreamCancels() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let handle = await fixture.source.transfer(assetA.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        let consumer = Task {
            await collect(handle)
        }
        consumer.cancel()
        _ = await consumer.value
        await fixture.backend.waitFor(.ensureCancelled(Packs.media))
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: invalidate cancels pack waiters and returns only after in-flight staging writes", .timeLimit(.minutes(1)))
    func invalidateDrainsStagingWrites() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles], remote: [Packs.extras: [extra.path: extra.bytes]], staging: gated)
        fixture.backend.scriptEnsure(Packs.extras, [.hold])
        let waiting = await fixture.source.transfer(extra.request())
        await fixture.source.packs.waitForWaiters(on: Packs.extras, count: 1)
        gated.note("armed")
        gated.arm(.afterWrite)
        let copying = await fixture.source.transfer(assetA.request())
        await gated.waitForHeldWrites(1)

        let invalidation = Task {
            await fixture.source.invalidate()
            gated.note("invalidate returned")
        }
        #expect(await collect(waiting) == [.failed(.cancelled(.byClient))])
        await fixture.source.state.waitForDrain()
        #expect(!gated.events.contains("invalidate returned"))
        gated.open()
        await invalidation.value
        let sinceArmed = gated.events.drop(while: { $0 != "armed" }).dropFirst()
        #expect(Array(sinceArmed.prefix(2)) == ["write returned", "invalidate returned"])
        #expect(await collect(copying).last.map(Self.isStaged) == true)

        let late = await fixture.source.transfer(assetB.request())
        #expect(await collect(late) == [.failed(.cancelled(.byClient))])
        #expect(gated.base.contents[assetB.request().partialName] == nil)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: an invalid remote path is rejected without touching any pack", .timeLimit(.minutes(1)))
    func invalidRemotePathIsRejected() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles])
        var request = assetA.request()
        request.remotePath = "ZTronMedia/../secrets.json"
        #expect(await collect(await fixture.source.transfer(request)) == [.failed(.rejected(.invalidURL))])
        #expect(fixture.backend.calls.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a pack the system does not know is permanently missing", .timeLimit(.minutes(1)))
    func unknownPackIsMissing() async throws {
        let fixture = AppleTierFixture()
        let updates = await collect(await fixture.source.transfer(assetA.request()))
        #expect(updates == [.failed(.permanentMissing(httpStatus: 404))])
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.media) }.count == 1)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a staging failure maps into the transfer taxonomy and leaves no partial", .timeLimit(.minutes(1)))
    func stagingFailureIsMapped() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles])
        fixture.staging.failNext(.writeStaged, with: .insufficientSpace)
        let request = assetA.request()
        #expect(await collect(await fixture.source.transfer(request)) == [.failed(.insufficientSpace(requiredBytes: Int64(assetA.bytes.count)))])
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a staging name already in use is reported and never discarded", .timeLimit(.minutes(1)))
    func nameInUseIsNeverDiscarded() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles])
        let request = assetA.request()
        let foreign = Data("someone else's bytes".utf8)
        try fixture.staging.createPartial(request.partialName)
        _ = try fixture.staging.appendPartial(foreign, to: request.partialName)
        let updates = await collect(await fixture.source.transfer(request))
        #expect(updates == [.failed(.transient(.localIO(posixCode: EEXIST), retryAfter: nil))])
        #expect(fixture.staging.contents[request.partialName] == foreign)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: a checksum-less entry of unknown size is staged without progress or checksum comparison", .timeLimit(.minutes(1)))
    func legacyEntryIsStagedBySizeOnly() async throws {
        let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
        fixture.backend.scriptEnsure(Packs.media, [.install(progress: [PackProgress(completed: 1, total: 2)])])
        let request = TransferRequest(
            id: .legacy(identifier: AssetID(rawValue: "bo7.menu.background"), remotePath: assetA.remotePath),
            attempt: TransferAttempt(epoch: 1, sequence: 1),
            remotePath: assetA.remotePath,
            expectedBytes: nil,
            maxBytes: 1 << 20,
            priority: .bulk
        )
        let updates = await collect(await fixture.source.transfer(request))
        #expect(updates == [.staged(StagedFile(name: request.partialName, byteCount: Int64(assetA.bytes.count), resumed: false, httpStatus: nil, etag: nil))])
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-OBS-1: an Apple transfer runs inside the transfer signpost interval", .timeLimit(.minutes(1)))
    func transferIsWrappedInTheInterval() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: mediaFiles])
        let request = assetA.request()
        let drained = await collectNotingIntervals(await fixture.source.transfer(request), tap: fixture.tap)
        #expect(drained.updates.last.map(Self.isStaged) == true, "\(drained.updates)")
        // Seen by the consumer when the terminal update arrived, not after the stream ended: whoever sees a
        // transfer's terminal update also sees its interval closed.
        #expect(drained.atTerminal == Self.closedInterval(of: request), "\(drained.atTerminal)")
        #expect(fixture.tap.lines.allSatisfy { $0.subsystem == AssetLog.subsystem })
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-OBS-1: a failed, cancelled or paused Apple transfer closes its interval before its terminal update", .timeLimit(.minutes(1)))
    func stoppedTransferClosesTheInterval() async throws {
        // Failed: the file is missing from its pack after the pack was made available (skew).
        let missing = PackAsset("ZTronMedia/images/new.heic", "added in catalog v2")
        let skewed = AppleTierFixture(installed: [Packs.media: mediaFiles], remote: [Packs.media: mediaFiles])
        let skewRequest = missing.request()
        let skew = await collectNotingIntervals(await skewed.source.transfer(skewRequest), tap: skewed.tap)
        #expect(skew.updates == [.failed(.transient(.sourceVersionSkew, retryAfter: nil))])
        #expect(skew.atTerminal == Self.closedInterval(of: skewRequest), "\(skew.atTerminal)")
        await skewed.source.invalidate()

        // Cancelled and paused while waiting for the pack.
        for control in [TransferControl.cancel, .pause] {
            let fixture = AppleTierFixture(remote: [Packs.media: mediaFiles])
            fixture.backend.scriptEnsure(Packs.media, [.hold])
            let request = assetA.request()
            let handle = await fixture.source.transfer(request)
            await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
            if control == .pause {
                handle.pause()
            } else {
                handle.cancel()
            }
            let drained = await collectNotingIntervals(handle, tap: fixture.tap)
            #expect(drained.updates == [control == .pause ? .paused(resumable: false) : .failed(.cancelled(.byClient))])
            #expect(drained.atTerminal == Self.closedInterval(of: request), "\(control): \(drained.atTerminal)")
            await fixture.source.invalidate()
        }
    }

    /// The two edges of `request`'s `transfer` interval.
    static func closedInterval(of request: TransferRequest) -> [LogIntervalEvent] {
        [
            LogIntervalEvent(category: .apple, name: .transfer, phase: .began, message: "attempt \(request.attempt.token)"),
            LogIntervalEvent(category: .apple, name: .transfer, phase: .ended, message: "attempt \(request.attempt.token)"),
        ]
    }

    @available(macOS 26.0, *)
    @Test("R-APL-3: an adopted asset is served from blobs and never from a pack location", .timeLimit(.minutes(1)))
    func adoptedAssetIsServedFromBlobs() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: mediaFiles])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        let request = assetA.request()
        let updates = await collect(await fixture.source.transfer(request))

        // What the engine receives names a staging file of this transfer, never a pack: the bytes are a copy in
        // the store's own staging area, which the store hashes and publishes into blobs/.
        guard case .staged(let file) = updates.last else {
            Issue.record("expected a staged copy, got \(updates)")
            return
        }
        #expect(file.name == request.partialName && file.name.transfer == request.id)
        #expect(file.httpStatus == nil && file.etag == nil && !file.resumed)
        #expect(fixture.staging.contents[file.name] == assetA.bytes)

        // Once every entry of the pack is adopted the pack is released; the store's copy is unaffected, and neither
        // the release nor anything after it opens a pack file.
        let opensBefore = fixture.backend.calls.filter { if case .open = $0 { true } else { false } }.count
        #expect(fixture.backend.calls.filter { $0 == .open(Packs.media, assetA.path) }.count == 1, "the transfer's own copy")
        let reclaim = await fixture.source.reclaimSourceCopies(
            AdoptionReport(
                manifestRemotePaths: [assetA.remotePath, assetB.remotePath],
                adoptedRemotePaths: [assetA.remotePath, assetB.remotePath]
            )
        )
        #expect(reclaim.released == ["ZTronMedia"])
        #expect(!fixture.backend.installedPacks.contains(Packs.media))
        #expect(fixture.staging.contents[file.name] == assetA.bytes)
        #expect(fixture.backend.calls.filter { if case .open = $0 { true } else { false } }.count == opensBefore)
        await fixture.source.invalidate()
    }

    static func isStaged(_ update: TransferUpdate) -> Bool {
        if case .staged = update {
            return true
        }
        return false
    }
}
