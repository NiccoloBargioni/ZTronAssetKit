import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: commit protocol and scheduling")
struct StoreCommitTests {
    @Test("R-STO-4: a commit writes tmp, syncs it, renames bin to prev, renames tmp to bin, then syncs the root, in that order", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitOrderAndLevels() async throws {
        let time = ManualTimeSource()
        let fake = FakeFileSystem(time: time)
        let spy = SyncLevelSpy(fake)
        let store = AssetStore(configuration: CoreFixture.configuration(), environment: CoreHarness.environment(fileSystem: spy, time: time))
        let layout = CoreFixture.layout
        let bytes = CoreFixture.bytes(80)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await store.open()
        _ = try await store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let sink = try await store.makeStagingSink()
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 1), kind: .partial)
        try sink.createPartial(name)
        _ = try sink.appendPartial(bytes, to: name)
        _ = try await store.publish(StagedFile(name: name, byteCount: 300, resumed: false, httpStatus: nil, etag: nil), binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        let opsStart = fake.operations.count
        let syncsStart = spy.syncs.count
        try await store.flush(.ordered)
        let fanOut = layout.fanOutDirectory(for: ContentHash.sha256(of: bytes))
        let ops = fake.operations[opsStart...].filter(\.kind.isMutation).map { "\($0.kind.rawValue) \($0.url.lastPathComponent)\($0.destination.map { " → \($0.lastPathComponent)" } ?? "")" }
        #expect(ops == [
            "synchronizeDirectory \(fanOut.lastPathComponent)",
            "synchronizeDirectory blobs",
            "write index.tmp",
            "synchronizeFile index.tmp",
            "rename index.bin → index.prev",
            "rename index.tmp → index.bin",
            "synchronizeDirectory v1",
        ])
        #expect(spy.syncs[syncsStart...].allSatisfy { $0.level == .barrier }, "an ordered commit uses barriers only")

        try await store.markSyncDue()
        let durableStart = spy.syncs.count
        try await store.flush(.durable)
        let durable = Array(spy.syncs[durableStart...])
        #expect(durable.map(\.path) == [
            layout.indexURL(.temporary).path, layout.root.path, layout.container.path, CoreFixture.base.path,
        ])
        #expect(durable.allSatisfy { $0.level == .full })
        await store.close()
    }

    @Test("R-STO-4: a torn index.tmp is ignored and the newest valid generation wins", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func tornTemporaryIsIgnored() async throws {
        let harness = CoreHarness.make()
        let entry = CoreFixture.entry("a", CoreFixture.bytes(81))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        await harness.store.close()
        var disk = harness.fileSystem.survivingDisk()
        let binPath = harness.layout.indexURL(.current).path
        let tmpPath = harness.layout.indexURL(.temporary).path
        var newer = try IndexCodec.decode(try #require(disk.files[binPath])).get()
        let committed = newer.generation
        newer.generation += 5
        newer.records = [:]
        newer.appliedManifest = CoreFixture.manifest([])
        let newerBytes = [UInt8](try #require(IndexCodec.encode(newer)))
        var torn = disk
        torn.files[tmpPath] = Array(newerBytes.prefix(newerBytes.count / 2))
        torn.durableFiles[tmpPath] = torn.files[tmpPath]
        let tornStore = CoreHarness.make(disk: torn)
        let tornReport = try await tornStore.store.open()
        #expect(!tornReport.degraded)
        #expect(try await tornStore.store.planningView().records.keys.contains(entry.identifier), "the older, valid index.bin won")
        #expect(tornReport.launchEpoch == committed + 6, "the torn header still counts for nextGeneration (I-5)")
        await tornStore.store.close()

        disk.files[tmpPath] = newerBytes
        disk.durableFiles[tmpPath] = newerBytes
        let validStore = CoreHarness.make(disk: disk)
        let validReport = try await validStore.store.open()
        #expect(!validReport.degraded)
        #expect(try await validStore.store.planningView().records.isEmpty, "a valid index.tmp of a newer generation wins")
    }

    @Test("R-STO-6: ENOSPC during an index commit keeps the previous generation and retries", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func noSpaceDuringCommit() async throws {
        let harness = CoreHarness.make()
        let tmp = URLMatcher(lastComponentSuffix: "index.tmp")
        _ = try await harness.store.open()
        let manifest = CoreFixture.manifest([CoreFixture.entry("a", CoreFixture.bytes(82))])
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        let stamp = SyncStamp(appVersion: "1", completedAt: harness.time.now(), manifestETag: nil, manifestDigest: manifest.digest)
        try await harness.store.markSynced(stamp, ifPurgeEpoch: 0)
        let binURL = harness.layout.indexURL(.current)
        let before = try IndexCodec.decode([UInt8](try #require(harness.content(binURL)))).get()

        // One ENOSPC: the unit drops index.tmp and index.prev and its retry succeeds.
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(1), error: .noSpace))
        try await harness.store.markSyncDue()
        let retried = try IndexCodec.decode([UInt8](try #require(harness.content(binURL)))).get()
        #expect(retried.generation > before.generation && retried.syncDue)
        #expect(harness.mutations.contains { $0.kind == .removeItem && $0.url == harness.layout.indexURL(.previous) })

        // ENOSPC twice: the commit fails, index.bin keeps the previous generation, the state stays dirty, and the next
        // window retries.
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(1), error: .noSpace))
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(2), error: .noSpace))
        await #expect(throws: StoreError.fileSystem(.noSpace)) {
            try await harness.store.markSynced(stamp, ifPurgeEpoch: 0)
        }
        let kept = try IndexCodec.decode([UInt8](try #require(harness.content(binURL)))).get()
        #expect(kept.generation == retried.generation && kept.stamp == nil)
        #expect(!harness.exists(harness.layout.indexURL(.temporary)))
        #expect(await harness.store.metrics().commitFailures == 1)
        #expect(await harness.store.nextDeadline() != nil)
        let work = await harness.store.runDueWork()
        #expect(work.committed)
        let healed = try IndexCodec.decode([UInt8](try #require(harness.content(binURL)))).get()
        #expect(healed.stamp == stamp && healed.generation > kept.generation + 1, "the failed attempt consumed a generation (I-5)")
    }

    @Test("R-STO-9: a replaced root is detected before the next commit", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func replacedRootDetected() async throws {
        let harness = CoreHarness.make()
        let entry = CoreFixture.entry("a", CoreFixture.bytes(83))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        // Something replaces the root's lock file (a restore, another tool): a new inode at the same path.
        try harness.fileSystem.removeItem(at: harness.layout.lockURL)
        try harness.fileSystem.write(Data(), to: harness.layout.lockURL, mode: .truncate)
        let start = harness.fileSystem.operations.count
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.store.markSyncDue()
        }
        #expect(!harness.fileSystem.operations[start...].contains { $0.kind == .write && $0.url == harness.layout.indexURL(.temporary) })
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.store.flush(.ordered)
        }
        #expect(StoreError.storageUnavailable(.rootVanished).assetError == .storageUnavailable(.rootVanished))
        #expect(await harness.store.nextDeadline() == nil, "no commit is retried into a replaced root")
        #expect(try await harness.store.planningView().records[entry.identifier] != nil, "reads keep working")
    }

    @Test("P-5: bulk publications coalesce into one commit per commitMinimumInterval, and a required commit waits for the window", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitsAreCoalesced() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(commitInterval: 0.25))
        let payloads = (0..<10).map { CoreFixture.bytes(200 + UInt64($0), count: 16) }
        let entries = payloads.enumerated().map { CoreFixture.entry("p\($0.offset)", $0.element) }
        _ = try await harness.store.open()
        // Inside the window of the launch commit, apply's commit waits for the window to open.
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        }
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(await harness.store.metrics().commits == 1)
        harness.time.advance(by: 0.25)
        _ = try await applying.value
        let commitsBefore = await harness.store.metrics().commits
        let windowOpens = try #require(await harness.state.core.commits.lastAttemptAt).adding(seconds: 0.25)
        for (index, (bytes, entry)) in zip(payloads, entries).enumerated() {
            try await harness.publish(bytes, [entry], sequence: UInt32(index + 1))
            harness.time.advance(by: 0.01)
        }
        #expect(await harness.store.metrics().commits == commitsBefore)
        #expect(await harness.store.nextDeadline() == windowOpens)
        #expect(await harness.store.runDueWork().committed == false)
        harness.time.advance(to: windowOpens)
        #expect(await harness.store.runDueWork().committed)
        #expect(await harness.store.metrics().commits == commitsBefore + 1)
        // A caller that needs a commit inside the window sleeps until it opens, and nothing commits earlier.
        let flushing = Task {
            try await harness.store.markSyncDue()
        }
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(await harness.store.metrics().commits == commitsBefore + 1)
        harness.time.advance(by: 0.25)
        try await flushing.value
        #expect(await harness.store.metrics().commits == commitsBefore + 2)
    }

    /// Review round 3, probe 6: a commit that keeps failing (a full volume, EIO) re-encoded the index and logged an
    /// error every 250 ms forever, so the engine's alarm never went quiet. The scheduled retry now backs off.
    @Test("P-5: failed commits back off exponentially, explicit flushes still try at once, success resets, one error per streak", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func failedCommitsBackOff() async throws {
        let interval: TimeInterval = 0.25
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(commitInterval: interval))
        _ = try await harness.store.open()
        harness.time.advance(by: 1)
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("a", CoreFixture.bytes(87))]), etag: nil, eviction: nil)
        // The next six commit attempts fail with EIO on the write of index.tmp (no fallback retry for EIO).
        for occurrence in 1...6 {
            harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(occurrence), error: .io))
        }
        let errorsBefore = harness.tap.lines.filter { $0.level == .error }.count
        await harness.store.markDirty(.soon)
        var attempts: [MonotonicInstant] = []
        for streak in 0..<5 {
            let deadline = try #require(await harness.store.nextDeadline())
            if let last = attempts.last {
                // Not before the deadline: the alarm firing early does nothing.
                harness.time.advance(to: last.adding(seconds: deadline.seconds(since: last) - 0.01))
                #expect(await harness.store.runDueWork().committed == false)
                #expect(await harness.store.metrics().commitFailures == UInt64(streak), "no attempt before the backed-off deadline")
            }
            harness.time.advance(to: deadline)
            let work = await harness.store.runDueWork()
            #expect(!work.committed)
            #expect(await harness.store.metrics().commitFailures == UInt64(streak + 1))
            attempts.append(harness.time.monotonicNow())
        }
        let gaps = zip(attempts.dropFirst(), attempts).map { $0.seconds(since: $1) }
        #expect(gaps == [0.5, 1, 2, 4], "interval × 2^failures: \(gaps)")
        let next = try #require(await harness.store.nextDeadline())
        #expect(next.seconds(since: attempts[4]) == 8)
        let errors = harness.tap.lines.filter { $0.level == .error }.count - errorsBefore
        #expect(errors == 1, "one error per failure streak, not one per attempt: \(errors)")
        // An explicit flush does not wait for the backoff, only for the coalescing window (≤ 4/s).
        harness.time.advance(by: interval)
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.flush(.ordered)
        }
        harness.time.advance(by: interval)
        try await harness.store.flush(.ordered)
        #expect(await harness.store.metrics().commitFailures == 6)
        // Success resets the backoff: the next mutation is due one window after the successful attempt.
        let succeeded = harness.time.monotonicNow()
        await harness.store.markDirty(.soon)
        #expect(await harness.store.nextDeadline() == succeeded.adding(seconds: interval))
        #expect(await harness.state.core.commits.consecutiveFailures == 0)
        // A new streak logs again, once (a rule counts the matching calls made after it was added).
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        harness.time.advance(by: interval)
        #expect(await harness.store.runDueWork().committed == false)
        #expect(harness.tap.lines.filter { $0.level == .error }.count - errorsBefore == 2)
    }

    @Test("R-STO-6: a launch commit that fails leaves the store open on the loaded state and retries later", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func launchCommitFailureServesReadOnly() async throws {
        let harness = CoreHarness.make()
        let tmp = URLMatcher(lastComponentSuffix: "index.tmp")
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(1), error: .noSpace))
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(2), error: .noSpace))
        let report = try await harness.store.open()
        #expect(report.generation == 0)
        #expect(await harness.store.nextDeadline() == harness.time.monotonicNow())
        let applied = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("a", CoreFixture.bytes(84))]), etag: nil, eviction: nil)
        #expect(applied.generation > report.launchEpoch)
        #expect(harness.exists(harness.layout.indexURL(.current)))
    }
}
