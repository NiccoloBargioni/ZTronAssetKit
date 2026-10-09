import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Persisted failure bookkeeping, quarantine and deep verification (R-INT-3, R-INT-4, R-CLN-7, R-CLN-8, R-NET-6;
/// ADR-032, store.md §5.4–§5.6, §6.6).
@Suite("Cleanup: integrity bookkeeping and deep verification (R-INT-3, R-INT-4, R-CLN-8)")
struct IntegrityTests {
    @Test("R-INT-3: repeated mismatches back off and finally mark the asset failed until its manifest entry changes", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func backoffThenFailed() async throws {
        let first = CoreHarness.cleanup(policy: CleanupFixture.policy(maxIntegrityAttempts: 3))
        let a = CleanupFixture.asset("a", seed: 300)
        _ = try await first.store.open()
        let manifest = CoreFixture.manifest([a.entry])
        _ = try await first.store.apply(manifest, etag: nil, eviction: nil)
        let identity = a.entry.contentIdentity
        let start = first.time.now()
        try await first.store.recordIntegrityFailure([a.id], identity: identity)
        var record = try #require(await first.record(a.id))
        #expect(record.residency == .quarantined(until: start.addingTimeInterval(60)))
        #expect(record.integrity == IntegrityHistory(attempts: 1, failedIdentity: identity, nextEligibleAt: start.addingTimeInterval(60)))
        first.time.advance(by: 60)
        try await first.store.recordIntegrityFailure([a.id], identity: identity)
        record = try #require(await first.record(a.id))
        #expect(record.residency == .quarantined(until: start.addingTimeInterval(660)))
        #expect(record.integrity.attempts == 2)
        first.time.advance(by: 600)
        try await first.store.recordIntegrityFailure([a.id], identity: identity)
        #expect(await first.record(a.id)?.residency == .failed(.integrity))
        // A further report for the failed asset changes nothing.
        let failed = await first.record(a.id)
        try await first.store.recordIntegrityFailure([a.id], identity: identity)
        #expect(await first.record(a.id) == failed)
        await first.store.close()
        // Persisted: a relaunch keeps it failed, and the same manifest does not clear it.
        let second = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time)
        _ = try await second.store.open()
        _ = try await second.store.apply(manifest, etag: nil, eviction: nil)
        #expect(await second.record(a.id)?.residency == .failed(.integrity))
        // A changed entry clears it.
        let changed = CleanupFixture.asset("a", seed: 301)
        _ = try await second.store.apply(CoreFixture.manifest([changed.entry]), etag: nil, eviction: nil)
        let cleared = try #require(await second.record(a.id))
        #expect(cleared.residency == .absent(.neverFetched) && cleared.integrity == .clean)
    }

    @Test("R-INT-3: a failure reported for content an entry no longer has changes nothing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func staleIdentityIgnored() async throws {
        let harness = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 305)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
        let before = await harness.record(a.id)
        try await harness.store.recordIntegrityFailure([a.id, "unknown"], identity: .checksum(ContentHash.sha256(of: Data("other".utf8))))
        try await harness.store.recordFailure([a.id], identity: .unverified(remotePath: "media/old.png"), reason: .notFound)
        #expect(await harness.record(a.id) == before)
    }

    @Test("R-INT-3: a stale asset keeps serving its old bytes while its new content backs off, and fails over to nothing at the cap", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func staleAssetKeepsServing() async throws {
        let harness = CoreHarness.cleanup(policy: CleanupFixture.policy(maxIntegrityAttempts: 2))
        let old = CleanupFixture.asset("a", seed: 310)
        try await harness.seed([old])
        let new = CleanupFixture.asset("a", seed: 311)
        _ = try await harness.store.apply(CoreFixture.manifest([new.entry]), etag: nil, eviction: nil)
        try await harness.store.recordIntegrityFailure([new.id], identity: new.entry.contentIdentity)
        let record = try #require(await harness.record(new.id))
        #expect(record.referencedBlob == old.key && record.isStale, "the old bytes are still served")
        #expect(record.integrity.attempts == 1 && record.integrity.nextEligibleAt != nil)
        try await harness.store.recordIntegrityFailure([new.id], identity: new.entry.contentIdentity)
        #expect(await harness.record(new.id)?.residency == .failed(.integrity))
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[old.key], .unreferenced), "the stale bytes are healthy, just unwanted")
        #expect(await harness.store.location(for: new.id, extensions: [], recordingAccess: false) == nil)
    }

    @Test("R-NET-6: recordFailure persists notFound across a reopen and a changed entry clears it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func notFoundPersists() async throws {
        let first = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 320)
        let b = CleanupFixture.asset("b", seed: 321)
        _ = try await first.store.open()
        let manifest = CoreFixture.manifest([a.entry, b.entry])
        _ = try await first.store.apply(manifest, etag: nil, eviction: nil)
        try await first.store.recordFailure([a.id, b.id], identity: a.entry.contentIdentity, reason: .notFound)
        #expect(await first.record(a.id)?.residency == .failed(.notFound))
        #expect(await first.record(b.id)?.residency == .absent(.neverFetched), "b has another identity")
        await first.store.close()
        let second = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time)
        _ = try await second.store.open()
        #expect(await second.record(a.id)?.residency == .failed(.notFound))
        _ = try await second.store.apply(manifest, etag: nil, eviction: nil)
        #expect(await second.record(a.id)?.residency == .failed(.notFound), "the same entry is not requested again")
        #expect(await second.store.availability(of: .all).failed == 1)
        var moved = a.entry
        moved.remotePath = "media/moved/a.png"
        moved.checksum = ContentHash.sha256(of: Data("moved".utf8))
        _ = try await second.store.apply(CoreFixture.manifest([moved, b.entry]), etag: nil, eviction: nil)
        #expect(await second.record(a.id)?.residency == .absent(.neverFetched))
    }

    @Test("R-CLN-8: reportUnreadable quarantines the entry, removes the blob after grace and schedules a re-download", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func reportUnreadable() async throws {
        let harness = CoreHarness.cleanup()
        let bytes = CoreFixture.bytes(330)
        let a = CleanupFixture.Asset(entry: CoreFixture.entry("a", bytes), bytes: bytes)
        let twin = CleanupFixture.Asset(entry: CoreFixture.entry("twin", bytes), bytes: bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a.entry, twin.entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a.entry, twin.entry])
        let now = harness.time.now()
        try await harness.store.reportUnreadable(a.id)
        for id in [a.id, twin.id] {
            let record = try #require(await harness.record(id))
            #expect(record.residency == .quarantined(until: now.addingTimeInterval(60)), "every record of the unreadable blob")
            #expect(record.integrity.nextEligibleAt == now.addingTimeInterval(60), "the re-download is scheduled after the backoff")
            #expect(await harness.store.location(for: id, extensions: [], recordingAccess: false) == nil)
        }
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[a.key], .corrupt))
        #expect(await harness.sink.installed.entries[a.id] == nil, "the quarantine is installed at once")
        let mutations = harness.fileSystem.mutationCount
        try await harness.store.reportUnreadable(a.id)
        let attempts = await harness.record(a.id)?.integrity.attempts
        #expect(harness.fileSystem.mutationCount == mutations && attempts == 1, "a second report is a no-op")
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key))
        // The re-download replaces it.
        try await harness.publish(bytes, [a.entry, twin.entry], sequence: 2)
        #expect(await harness.isPresent(a.id, at: a.key) && harness.hasBlob(a.key))
        await #expect(throws: StoreError.unknownAsset("zzz")) {
            try await harness.store.reportUnreadable("zzz")
        }
    }

    @Test("R-CLN-8: a quarantined blob resurrected by power loss is never re-adopted", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func quarantinedNeverReadopted() async throws {
        let harness = CoreHarness.cleanup(mode: .powerLossDropUnsynced)
        let a = CleanupFixture.asset("a", seed: 335)
        try await harness.seed([a])
        try await harness.store.reportUnreadable(a.id)
        await harness.settleDeletions()
        #expect(!harness.hasBlob(a.key))
        let reopened = CoreHarness.cleanup(disk: harness.fileSystem.survivingDisk(), time: harness.time)
        _ = try await reopened.store.open()
        _ = try await reopened.store.apply(CoreFixture.manifest([a.entry]), etag: nil, eviction: nil)
        #expect(await reopened.store.location(for: a.id, extensions: [], recordingAccess: false) == nil)
        if case .quarantined = await reopened.record(a.id)?.residency {
        } else {
            Issue.record("the quarantine must survive the power loss")
        }
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
    }

    @Test("R-INT-4: deep verification repairs a corrupted resident blob within its byte budget", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func deepVerification() async throws {
        let harness = CoreHarness.cleanup()
        let assets = (0..<4).map { CleanupFixture.asset("v\($0)", seed: 340 + UInt64($0), count: 300) }
        try await harness.seed(assets)
        let victim = assets[2]
        // Bit rot: the same size, other bytes.
        try harness.fileSystem.write(CoreFixture.bytes(999, count: 300), to: harness.layout.blobURL(victim.key), mode: .truncate)
        let deadline = harness.time.monotonicNow().adding(seconds: 60)
        var corrupt: [AssetID] = []
        var slices = 0
        var report: VerificationReport
        repeat {
            report = try await harness.store.verifyIntegrity(byteBudget: 600, until: deadline)
            #expect(report.bytesVerified <= 600, "a slice stays within its byte budget")
            corrupt += report.corrupt
            slices += 1
        } while !report.completedPass && slices < 10
        #expect(slices == 2 && corrupt == [victim.id])
        #expect(await harness.store.location(for: victim.id, extensions: [], recordingAccess: false) == nil)
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[victim.key], .corrupt))
        for asset in assets where asset.id != victim.id {
            #expect(await harness.record(asset.id)?.verifiedAt == harness.time.now())
        }
        // The repair: the next verified download replaces the corrupt name.
        try await harness.publish(victim.bytes, [victim.entry], sequence: 9)
        #expect(harness.content(harness.layout.blobURL(victim.key)) == victim.bytes)
        // A new pass starts from the oldest verification.
        let next = try await harness.store.verifyIntegrity(byteBudget: 300, until: deadline)
        #expect(next.bytesVerified == 300 && next.corrupt.isEmpty && !next.completedPass)
    }

    @Test(
        "R-INT-4: deep verification discards a hash whose blob was quarantined or replaced meanwhile and never quarantines the new bytes",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    @available(macOS 15.0, iOS 18.0, *)
    func verificationDiscardsReplacedIncarnation(replaced: Bool) async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(bulk: bulk)
        // Three hash units of 1 MiB, so the name can change between the first and the last.
        let a = CleanupFixture.asset("a", seed: 380, count: (5 << 20) / 2)
        try await harness.seed([a])
        let seeded = await harness.record(a.id)?.verifiedAt
        var rotten = a.bytes
        rotten[rotten.startIndex] ^= 0xFF
        try harness.fileSystem.write(rotten, to: harness.layout.blobURL(a.key), mode: .truncate)
        await bulk.setHolding(true)
        let deadline = harness.time.monotonicNow().adding(seconds: 600)
        let verification = Task {
            try await harness.store.verifyIntegrity(byteBudget: .max, until: deadline)
        }
        // The first unit hashes the rotten file; the second is held.
        try await bulk.requireHeldUnits(atLeast: 1)
        await bulk.releaseNext()
        try await bulk.requireHeldUnits(atLeast: 1)
        let held = try #require(await bulk.heldUnits.first)
        // Meanwhile a reader quarantines the blob (one integrity attempt) …
        try await harness.store.reportUnreadable(a.id)
        guard replaced else {
            // … and verification, finding the blob doomed after its hash, adds no second attempt (R16).
            await bulk.setHolding(false)
            let report = try await verification.value
            #expect(report.corrupt.isEmpty && report.bytesVerified == 0)
            let record = try #require(await harness.record(a.id))
            #expect(record.integrity.attempts == 1 && record.referencedBlob == nil)
            #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[a.key], .corrupt))
            return
        }
        // … and the next verified download replaces the name (ADR draft B-24).
        _ = try await CleanupSteps.run(bulk, keeping: [held]) {
            try await harness.publish(a.bytes, [a.entry], urgency: .userInitiated, sequence: 9)
        }
        #expect(await harness.isPresent(a.id, at: a.key))
        #expect(harness.content(harness.layout.blobURL(a.key)) == a.bytes.prefix(1 << 20))
        // The rest of the hash reads the new file: a digest of two incarnations proves nothing about either.
        await bulk.setHolding(false)
        let report = try await verification.value
        #expect(report.corrupt.isEmpty)
        #expect(await harness.isPresent(a.id, at: a.key), "the verified replacement is not quarantined")
        #expect(await harness.record(a.id)?.verifiedAt == seeded, "and not counted verified either")
        #expect(!StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[a.key], .corrupt))
        // It is checked again in this pass, now as one incarnation.
        let again = try await harness.store.verifyIntegrity(byteBudget: .max, until: deadline)
        #expect(again.bytesVerified == Int64(a.bytes.count) && again.corrupt.isEmpty)
        #expect(await harness.record(a.id)?.verifiedAt == harness.time.now())
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Review round 3 (C2, orchestrator ruling R4): the due list is built off the actor from a snapshot, so a blob
    /// quarantined while it is built is skipped (proposed REENTRANCY row c-6) and the pass verifies the others.
    @Test("R-INT-4: deep verification builds its due list off the actor and skips a blob quarantined while it is built", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func dueListRevalidated() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.cleanup(bulk: bulk)
        let assets = (0..<3).map { CleanupFixture.asset("d\($0)", seed: 370 + UInt64($0), count: 200) }
        try await harness.seed(assets)
        let blobStats = {
            harness.fileSystem.operations.filter { $0.kind == .itemInfo && $0.url.path.hasPrefix(harness.layout.blobsDirectory.path) }.count
        }
        let seeded = blobStats()
        await bulk.setHolding(true)
        let verify = Task {
            try await harness.store.verifyIntegrity(byteBudget: 10_000, until: harness.time.monotonicNow().adding(seconds: 60))
        }
        // The first unit is the due list; no blob has been stat-ed or hashed yet.
        try await bulk.requireHeldUnits(atLeast: 1)
        #expect(blobStats() == seeded)
        try await harness.store.reportUnreadable(assets[0].id)
        await bulk.setHolding(false)
        await bulk.releaseAll()
        let report = try await verify.value
        #expect(report.completedPass && report.corrupt.isEmpty, "the quarantined blob is skipped, not quarantined again")
        #expect(report.bytesVerified == 400)
        #expect(await harness.record(assets[0].id)?.integrity.attempts == 1)
        for asset in assets.dropFirst() {
            #expect(await harness.record(asset.id)?.verifiedAt == harness.time.now())
        }
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-INT-4: deep verification stops at its deadline and does nothing while the store is degraded", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func verificationLimits() async throws {
        let harness = CoreHarness.cleanup()
        try await harness.seed([CleanupFixture.asset("a", seed: 350)])
        let past = harness.time.monotonicNow()
        let report = try await harness.store.verifyIntegrity(byteBudget: 1 << 20, until: past)
        #expect(report == VerificationReport(bytesVerified: 0, corrupt: [], completedPass: false))
        let none = try await harness.store.verifyIntegrity(byteBudget: 0, until: past.adding(seconds: 60))
        #expect(none.bytesVerified == 0)
        // A degraded launch (index.bin rotten, the previous generation, which lists `a` present, loaded) verifies
        // nothing: its records are not trusted until the next apply.
        try await harness.store.setPinned(["a"], pinned: true)
        await harness.store.close()
        var disk = harness.fileSystem.survivingDisk()
        let bin = harness.layout.indexURL(.current).path
        disk.files[bin]?[IndexHeader.length] ^= 0xFF
        let degraded = CoreHarness.cleanup(disk: disk, time: harness.time)
        #expect(try await degraded.store.open().degraded)
        #expect(await degraded.record("a")?.referencedBlob != nil)
        let nothing = try await degraded.store.verifyIntegrity(byteBudget: 1 << 20, until: past.adding(seconds: 60))
        #expect(nothing == VerificationReport(bytesVerified: 0, corrupt: [], completedPass: false))
    }

    @Test(
        "R-CLN-7: a truncated blob is replaced by the next verified download",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    @available(macOS 15.0, iOS 18.0, *)
    func truncatedBlobReplaced(foundAtLaunch: Bool) async throws {
        let first = CoreHarness.cleanup()
        let a = CleanupFixture.asset("a", seed: 360, count: 800)
        try await first.seed([a])
        try first.fileSystem.write(a.bytes.prefix(400), to: first.layout.blobURL(a.key), mode: .truncate)
        let harness: CoreHarness
        if foundAtLaunch {
            await first.store.close()
            harness = CoreHarness.cleanup(disk: first.fileSystem.survivingDisk(), time: first.time)
            _ = try await harness.store.open()
            #expect(await harness.record(a.id)?.residency == .needsHeal(lastBlob: a.key))
        } else {
            harness = first
            let report = try await harness.store.verifyIntegrity(byteBudget: 1 << 20, until: harness.time.monotonicNow().adding(seconds: 60))
            #expect(report.corrupt == [a.id])
        }
        #expect(StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[a.key], .corrupt))
        try await harness.publish(a.bytes, [a.entry], urgency: .userInitiated, sequence: 7)
        #expect(await harness.isPresent(a.id, at: a.key))
        #expect(harness.content(harness.layout.blobURL(a.key)) == a.bytes, "the verified bytes replaced the truncated file")
        await harness.settleDeletions()
        #expect(harness.content(harness.layout.blobURL(a.key)) == a.bytes, "and the reaper never deletes them")
    }
}
