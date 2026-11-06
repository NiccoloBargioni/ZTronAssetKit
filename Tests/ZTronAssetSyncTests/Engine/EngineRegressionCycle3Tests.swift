import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 2 found in WP-F (cycle 3 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-23).
@Suite("Engine regressions, close-out cycle 3")
struct EngineRegressionCycle3Tests {
    /// What made the engine drop its whole binding ledger while a run still had `x` to materialise.
    enum LedgerDrop: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// An unrelated `ensureAvailable` whose `apply` wrote a manifest in memory and then failed its index commit.
        case failedApply
        /// A successful maintenance pass (it drops the ledger at its start and after its eviction step).
        case maintenance

        var testDescription: String {
            self.rawValue
        }
    }

    /// A run whose plan is `[h1, h2, x]`, with a materialisation limit of 2 (one pipeline of two slots, no lookahead)
    /// and one bulk slot: `h1` holds, `h2` waits, `x` is not materialised yet. A user `ensureAvailable([x])` then
    /// downloads and commits `x`, so the engine's ledger binds it (kept whole while the run exists). `xSteps` scripts
    /// `x`'s transfers (the ensure's first).
    @available(macOS 15.0, iOS 18.0, *)
    static func runWithUnmaterialisedX(
        _ seed: UInt64,
        storage: StoragePolicy = StoragePolicy(),
        xSteps: [FakeTransferStep]? = nil
    ) async throws -> (harness: EngineHarness, run: Task<SyncOutcome, Never>, h1: ManifestEntry, x: ManifestEntry) {
        let time = ManualTimeSource()
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 1, pipelineDepth: 1, runLookahead: 0)
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: storage)
        let h1Bytes = EngineFixture.bytes(seed, count: 10)
        let h2Bytes = EngineFixture.bytes(seed + 1, count: 10)
        let xBytes = EngineFixture.bytes(seed + 2, count: 300)
        let h1 = EngineFixture.entry("h1", h1Bytes)
        let h2 = EngineFixture.entry("h2", h2Bytes)
        let x = EngineFixture.entry("x", xBytes)
        await harness.serveManifest([h1, h2, x])
        await harness.source.script(h1.transferID, [.hold, .stage(h1Bytes)])
        await harness.source.script(h2.transferID, [.stage(h2Bytes)])
        await harness.source.script(x.transferID, xSteps ?? [.stage(xBytes), .stage(xBytes)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.run?.transferring == true && ($0.state.run?.cursor ?? 0) >= 2 }
        await engine.waitForHandle(h1.transferID)
        let cursor = await engine.readForTests { $0.state.run?.cursor ?? -1 }
        let xJob = await engine.readForTests { $0.state.jobs[x.transferID] != nil }
        #expect(cursor == 2 && !xJob, "x is not materialised yet: cursor \(cursor), job \(xJob)")
        let ensured = await engine.ensureAvailable(scope: .identifiers(["x"]))
        #expect((try? ensured.get())?.present == 1, "the user ensure downloads x: \(ensured)")
        #expect(await engine.readForTests { $0.state.boundContent["x"] == x.transferID }, "the ledger binds x while the run exists")
        return (harness, run, h1, x)
    }

    /// An `ensureAvailable([w])` whose `apply` adds the on-demand `w` in memory and then fails its index commit
    /// (ADR-050): the engine drops its whole binding ledger. `x` is listed unchanged, so the store keeps it present.
    @available(macOS 15.0, iOS 18.0, *)
    static func failApply(_ harness: EngineHarness, keeping entries: [ManifestEntry], seed: UInt64) async throws {
        let wBytes = EngineFixture.bytes(seed, count: 20)
        let w = EngineHarness.onDemand("w", wBytes)
        await harness.serveManifest(entries + [w], etag: "v2")
        await harness.source.script(w.transferID, [.stage(wBytes)])
        try await harness.store.flush(.ordered)
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let failed = await harness.engine.ensureAvailable(scope: .identifiers(["w"]))
        guard case .failure(.storageUnavailable) = failed else {
            Issue.record("setup: the apply's failed index commit fails the ensure: \(failed)")
            return
        }
    }

    // MARK: A dropped ledger is unknown, not absent (L4-R5; review of close-out cycle 2, PROBE-C2-2, -4, -6)

    /// PROBE-C2-2 and PROBE-C2-4: after the engine dropped its ledger, the run reached `x`, created a job and downloaded
    /// it a second time although the store held it present at its entry's content throughout.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run does not download an asset the store holds present after the engine dropped its binding ledger", .timeLimit(.minutes(1)), arguments: LedgerDrop.allCases)
    func runAfterLedgerDrop(_ drop: LedgerDrop) async throws {
        let (harness, run, h1, x) = try await EngineRegressionCycle3Tests.runWithUnmaterialisedX(9_211)
        let engine = harness.engine
        switch drop {
        case .failedApply:
            let h1b = EngineFixture.entry("h1", EngineFixture.bytes(9_211, count: 10))
            let h2b = EngineFixture.entry("h2", EngineFixture.bytes(9_212, count: 10))
            try await EngineRegressionCycle3Tests.failApply(harness, keeping: [h1b, h2b, x], seed: 9_299)
        case .maintenance:
            let maintenance = await harness.withClock { await engine.performMaintenance(timeBudget: 5) }
            #expect((try? maintenance.get()) != nil, "setup: maintenance succeeds: \(maintenance)")
        }
        #expect(await engine.readForTests { $0.state.boundContent["x"] } == nil, "setup: the ledger was dropped")
        let before = try #require(try await harness.view().records["x"])
        #expect(SyncEngine.isPresent(before, at: x.transferID), "setup: the store holds x present: \(before.residency)")
        await harness.source.release(h1.transferID, with: .progress(received: 0, expected: nil))
        let outcome = await harness.withClock { await EngineHarness.value(of: run) }
        let starts = await harness.source.starts.filter { $0.id == x.transferID }.count
        #expect(starts == 1, "\(drop): only the user ensure downloaded x; the run found it present (\(outcome))")
        if case .completeWithFailures(let report) = outcome {
            #expect(!report.failures.contains { $0.id == "x" }, "x is not a failure of the run: \(report.failures)")
        }
        let after = try #require(try await harness.view().records["x"])
        #expect(SyncEngine.isPresent(after, at: x.transferID), "x stays present: \(after.residency)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// PROBE-C2-6: the same with the default tuning and policy, and a 40-asset catalog whose first three transfers hold.
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 20.7 s alone and 30.5 to 30.9 s beside a second
    /// TSan process at a load of 16 to 26 (Stage 3 close-out cycle 4), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: with the default tuning, a run does not download an asset the store holds present after a failed apply dropped the ledger", .timeLimit(.minutes(3)))
    func runAfterLedgerDropDefaultTuning() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        var entries: [ManifestEntry] = []
        var held: [ManifestEntry] = []
        for index in 0..<3 {
            let bytes = EngineFixture.bytes(9_600 + UInt64(index), count: 10)
            let entry = EngineFixture.entry("h\(index)", bytes)
            held.append(entry)
            entries.append(entry)
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        for index in 0..<36 {
            let bytes = EngineFixture.bytes(9_700 + UInt64(index), count: 10)
            let entry = EngineFixture.entry("f\(index < 10 ? "0" : "")\(index)", bytes)
            entries.append(entry)
            await harness.source.script(entry.transferID, [.stage(bytes)])
        }
        let xBytes = EngineFixture.bytes(9_799, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        entries.append(x)
        await harness.source.script(x.transferID, [.stage(xBytes), .stage(xBytes)])
        await harness.serveManifest(entries)
        try await harness.start()
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.run?.transferring == true && ($0.state.run?.cursor ?? 0) > 0 }
        for entry in held {
            await engine.waitForHandle(entry.transferID)
        }
        let cursor = await engine.readForTests { $0.state.run?.cursor ?? -1 }
        let xJob = await engine.readForTests { $0.state.jobs[x.transferID] != nil }
        #expect(cursor < entries.count && !xJob, "setup: x is not materialised yet (cursor \(cursor))")
        let ensured = await engine.ensureAvailable(scope: .identifiers(["x"]))
        #expect((try? ensured.get())?.present == 1, "setup: the user ensure downloads x: \(ensured)")
        try await EngineRegressionCycle3Tests.failApply(harness, keeping: entries, seed: 9_899)
        for entry in held {
            await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        }
        let outcome = await harness.withClock { await EngineHarness.value(of: run) }
        let starts = await harness.source.starts.filter { $0.id == x.transferID }.count
        #expect(starts == 1, "only the user ensure downloaded x; the run found it present (\(String(describing: outcome).prefix(120)))")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: A failed transfer never fails a present record (L4-R5 second bullet, R-INT-3; PROBE-C2-3)

    /// PROBE-C2-3: the redundant job of the previous tests, whose download of `x` stages corrupt bytes of the same
    /// length, recorded an integrity failure against present `x`: with `maxIntegrityAttempts` 1 the store dropped `x`'s
    /// blob and answered `integrityFailure` until the entry changes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a present asset is never counted, quarantined or failed by a redundant transfer of its content", .timeLimit(.minutes(1)), arguments: [1, 3])
    func redundantIntegrityFailure(cap: Int) async throws {
        let xBytes = EngineFixture.bytes(9_311 + 2, count: 300)
        var corrupt = xBytes
        corrupt[corrupt.startIndex] ^= 0xFF
        let (harness, run, h1, x) = try await EngineRegressionCycle3Tests.runWithUnmaterialisedX(
            9_311,
            storage: StoragePolicy(maxIntegrityAttempts: cap),
            xSteps: [.stage(xBytes), .stage(corrupt)]
        )
        let engine = harness.engine
        let h1b = EngineFixture.entry("h1", EngineFixture.bytes(9_311, count: 10))
        let h2b = EngineFixture.entry("h2", EngineFixture.bytes(9_312, count: 10))
        try await EngineRegressionCycle3Tests.failApply(harness, keeping: [h1b, h2b, x], seed: 9_399)
        await harness.source.release(h1.transferID, with: .progress(received: 0, expected: nil))
        let outcome = await harness.withClock { await EngineHarness.value(of: run) }
        let record = try #require(try await harness.view().records["x"])
        #expect(record.integrity.attempts == 0, "cap \(cap): no integrity failure is counted against present x: \(record.integrity)")
        #expect(SyncEngine.isPresent(record, at: x.transferID), "cap \(cap): x stays present: \(record.residency)")
        if case .completeWithFailures(let report) = outcome {
            #expect(!report.failures.contains { $0.id == "x" }, "x is not a failure of the run: \(report.failures)")
        }
        let resolved = await harness.withClock { await engine.awaitAsset("x", lane: .userInitiated) }
        #expect(resolved.map(\.byteSize) == .success(Int64(xBytes.count)), "cap \(cap): x is still served: \(resolved)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// Where an integrity failure comes from: the transport (`.integrity`) or the store's hash check of the staged file.
    enum IntegritySource: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case transport
        case publication

        var testDescription: String {
            self.rawValue
        }
    }

    /// The integrity twin of `R-NET-6: a 404 never marks failed an asset the store bound to that content while the
    /// transfer ran`: the store binds `x` to its content behind the engine's back while `x`'s transfer runs (as a legacy
    /// adoption would), then the attempt fails integrity. Only the 404 path re-checked presence before recording.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-INT-3: an integrity failure never counts against an asset the store bound to that content while the transfer ran",
        .timeLimit(.minutes(1)),
        arguments: IntegritySource.allCases, [1, 3]
    )
    func integrityFailureSparesAssetBoundMeanwhile(_ source: IntegritySource, cap: Int) async throws {
        let harness = EngineHarness.make(storage: StoragePolicy(maxIntegrityAttempts: cap))
        let bytes = EngineFixture.bytes(9_411 + UInt64(cap))
        let x = EngineHarness.onDemand("x", bytes)
        await harness.serveManifest([x])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x.transferID)
        let sink = try #require(await harness.source.attachedStaging)
        let name = StagingFileName(transfer: x.transferID, attempt: TransferAttempt(epoch: 99, sequence: 1), kind: .partial)
        try sink.createPartial(name)
        _ = try sink.appendPartial(bytes, to: name)
        let staged = StagedFile(name: name, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)
        _ = try await harness.store.publish(staged, binding: ["x"], expecting: x.contentIdentity, urgency: .userInitiated)
        switch source {
        case .transport:
            await harness.source.release(x.transferID, with: .failed(.integrity(.truncated(expected: Int64(bytes.count), received: 3))))
        case .publication:
            var corrupt = bytes
            corrupt[corrupt.startIndex] ^= 0xFF
            let corruptName = StagingFileName(transfer: x.transferID, attempt: TransferAttempt(epoch: 98, sequence: 1), kind: .partial)
            try sink.createPartial(corruptName)
            _ = try sink.appendPartial(corrupt, to: corruptName)
            let file = StagedFile(name: corruptName, byteCount: Int64(corrupt.count), resumed: false, httpStatus: 200, etag: nil)
            await harness.source.release(x.transferID, with: .staged(file))
        }
        let result = await harness.withClock { await EngineHarness.value(of: waiter) }
        #expect(result.map(\.byteSize) == .success(Int64(bytes.count)), "\(source), cap \(cap): x is present: never integrityFailure, got \(result)")
        let record = try #require(try await harness.view().records["x"])
        #expect(record.integrity.attempts == 0, "\(source), cap \(cap): nothing counted against present x: \(record.integrity)")
        #expect(SyncEngine.isPresent(record, at: x.transferID), "\(source), cap \(cap): the valid local copy is kept: \(record.residency)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: A quarantine reaches every holder of the blob (R-CLN-8; PROBE-C2-7)

    /// PROBE-C2-7: `x` and `y` share one blob. `reportUnreadable("x")` made the store quarantine both, but the engine
    /// forgot, announced and healed only `x`: the run, reaching `y`, counted it fetched from the stale binding and ended
    /// `.complete` (stamp written) while `y` stayed quarantined and unserved.
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 33.8 to 35.2 s beside a second TSan process at a
    /// load of 20 to 35 (59 % of 60 s) and 15.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-8: reportUnreadable announces, forgets and heals every asset the store quarantined with the blob, and a run downloads them again", .timeLimit(.minutes(3)))
    func siblingQuarantine() async throws {
        let time = ManualTimeSource()
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 1, pipelineDepth: 1, runLookahead: 0)
        let harness = EngineHarness.make(time: time, tuning: tuning)
        let engine = harness.engine
        let h1Bytes = EngineFixture.bytes(9_901, count: 10)
        let h2Bytes = EngineFixture.bytes(9_902, count: 10)
        let shared = EngineFixture.bytes(9_903, count: 300)
        let h1 = EngineFixture.entry("h1", h1Bytes)
        let h2 = EngineFixture.entry("h2", h2Bytes)
        let x = EngineFixture.entry("x", shared)
        let y = EngineFixture.entry("y", shared)
        #expect(x.transferID == y.transferID, "setup: x and y share content")
        await harness.serveManifest([h1, h2, x, y])
        await harness.source.script(h1.transferID, [.hold, .stage(h1Bytes)])
        await harness.source.script(h2.transferID, [.stage(h2Bytes)])
        await harness.source.script(x.transferID, [.stage(shared), .stage(shared), .stage(shared), .stage(shared)])
        try await harness.start()
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.run?.transferring == true && ($0.state.run?.cursor ?? 0) >= 2 }
        await engine.waitForHandle(h1.transferID)
        #expect(await engine.readForTests { $0.state.run?.cursor ?? -1 } == 2, "setup: x and y are not materialised")
        let ensured = await engine.ensureAvailable(scope: .identifiers(["x", "y"]))
        #expect((try? ensured.get())?.present == 2, "setup: the ensure commits x and y: \(ensured)")
        #expect(await engine.readForTests { $0.state.boundContent["y"] } == y.transferID, "setup: the ledger binds y")
        let probe = EventProbe(stream: try await engine.subscribe().get())
        // Nothing reportUnreadable does needs the clock (no commit window here): a clock driven meanwhile could reach the
        // quarantine's end and heal before the announcements below are received (L4-R17).
        let reported = await engine.reportUnreadable("x")
        #expect((try? reported.get()) != nil, "reportUnreadable succeeds: \(reported)")
        // Both quarantines are received before the clock moves: each heal's `assetAvailable` has the same subject and
        // would replace its quarantine in the probe's slot if the probe had not pulled it yet (§7.9; L4-R17).
        let xQuarantined = await probe.next { $0 == .assetRemoved("x", .quarantined) }
        let yQuarantined = await probe.next { $0 == .assetRemoved("y", .quarantined) }
        #expect(xQuarantined != nil && yQuarantined != nil, "both quarantines are announced")
        let view = try await harness.view()
        guard case .quarantined? = view.records["y"]?.residency else {
            Issue.record("setup: the store quarantined y with x's blob: \(String(describing: view.records["y"]?.residency))")
            await engine.shutdown()
            return
        }
        #expect(await engine.readForTests { $0.state.boundContent["y"] } == nil, "the engine no longer binds y")
        #expect(await engine.readForTests { $0.state.heals["y"] != nil }, "y's re-download is scheduled at the end of its quarantine")
        await harness.source.release(h1.transferID, with: .progress(received: 0, expected: nil))
        let outcome = await harness.withClock { await EngineHarness.value(of: run) }
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        #expect(finished != nil)
        await probe.stop()
        let yLocation = await harness.store.location(for: "y", extensions: [], recordingAccess: false)
        let yAfter = try await harness.view().records["y"]?.residency
        #expect(outcome.completeReport != nil, "the run completes: \(String(describing: outcome).prefix(200))")
        #expect(yLocation != nil, "a run that completes serves y: \(String(describing: yAfter))")
        if let yLocation {
            #expect(try harness.fileSystem.read(from: yLocation.url, offset: 0, maxLength: shared.count + 1) == shared)
        }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: One insufficientSpace convention at the ledger's parking site (F-22; review of close-out cycle 2, M-JOBS)

    /// The third site of F-22's convention, which no test pinned: a job the headroom ledger parks for lack of space,
    /// with no ENOSPC before it and nothing to reclaim, answers its waiter with the bytes it needs against the room
    /// above the reserve. Under mutant M-JOBS (the raw volume, reserve included) `available` exceeds both.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a waiter of a job the ledger parks for lack of space gets the bytes it needs and the room above the reserve", .timeLimit(.minutes(1)))
    func parkedFiguresExcludeTheReserve() async throws {
        let room: Int64 = 100
        let harness = EngineHarness.make(capacity: StoragePolicy().reserveFreeBytes + room)
        let bytes = EngineFixture.bytes(9_961, count: 300)
        let entry = EngineHarness.onDemand("big", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.stage(bytes)])
        try await harness.start()
        let engine = harness.engine
        // The run reads the free space; the on-demand entry is not fetched by it.
        _ = await engine.sync(.force)
        #expect(await engine.readForTests { $0.state.freeSpace != nil }, "setup: the engine holds a free-space reading")
        let result = await engine.awaitAsset("big", lane: .userInitiated)
        guard case .failure(.insufficientSpace(let required, let available)) = result else {
            Issue.record("expected insufficientSpace, got \(result)")
            await engine.shutdown()
            return
        }
        #expect(required == Int64(bytes.count), "the entry's size: \(required)")
        #expect(available <= room, "the room above the reserve, never the raw volume: \(available)")
        #expect(available < required)
        #expect(await harness.source.starts.filter { $0.id == entry.transferID }.isEmpty, "parked by the ledger, never started")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: A store view older than the copy is never followed (review of close-out cycle 2, by reading)

    /// A catch-up (or a resolve, a prefetch join, a point admission) reads the store's view, and an `apply` the engine
    /// makes lands before the read's continuation runs: following that view would take the engine's copy back to the
    /// older manifest, announce the ids the apply added as pruned and move their jobs to stale entries. No seam orders
    /// the two continuations, so the landing is reproduced by handing `followStoreView` a view read before the apply.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a store view read before an apply the engine followed never takes the engine's copy back", .timeLimit(.minutes(1)))
    func olderViewIsNotFollowed() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let aBytes = EngineFixture.bytes(9_971)
        let a = EngineFixture.entry("a", aBytes)
        await harness.serve([(a, aBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        // A read that began before the next apply.
        let mark = await engine.readForTests { $0.state.copySerial }
        let older = try await harness.view()
        let generation = await engine.readForTests { $0.state.generation }
        // The next manifest adds the on-demand b; ensureAvailable applies it and the engine follows it.
        let bBytes = EngineFixture.bytes(9_972)
        let b = EngineHarness.onDemand("b", bBytes)
        await harness.serveManifest([a, b], etag: "v2")
        await harness.source.script(b.transferID, [.stage(bBytes)])
        let ensured = try await engine.ensureAvailable(scope: .identifiers(["b"])).get()
        #expect(ensured.present == 1, "setup: b is applied and fetched: \(ensured)")
        #expect(await engine.readForTests { $0.state.applied.entry(for: "b") } == b, "setup: the copy lists b")
        let applied = await engine.readForTests { $0.state.generation }
        // What subscribers see: following the older view would announce b, which the apply added, as pruned.
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let followed = await engine.readForTests { $0.followStoreView(older, readAt: mark) }
        #expect(!followed, "a view read before an apply the engine followed is not followed")
        #expect(await engine.readForTests { $0.state.applied.entry(for: "b") } == b, "the copy keeps b")
        #expect(await engine.readForTests { $0.state.generation } > generation, "the generation never goes back")
        // A view read now is current: following it changes nothing.
        let mark2 = await engine.readForTests { $0.state.copySerial }
        let current = try await harness.view()
        #expect(await engine.readForTests { $0.followStoreView(current, readAt: mark2) })
        #expect(await engine.readForTests { $0.state.applied.entry(for: "b") } == b)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        await probe.stop()
        #expect(!received.contains(.assetRemoved("b", .pruned)), "b, which the copy keeps, is never announced removed: \(received)")
        let olderSnapshots = received.filter { event in
            if case .snapshotChanged(let announced) = event {
                return announced < applied
            }
            return false
        }
        #expect(olderSnapshots.isEmpty, "no snapshot generation older than the apply's is announced: \(olderSnapshots)")
    }

    /// The other half of the guard: a refused view must not leave the copy behind the store. Here the store holds a
    /// manifest the engine never applied (what an `apply` that throws after its in-memory writes leaves), and the view
    /// showing it is refused as if the copy had changed during its read: the engine owes a re-read of the store, which
    /// then follows it with its announcements. Without the owed re-read the copy stays behind until some later event.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a store view refused as possibly older than the copy is read again, so the engine still follows the store", .timeLimit(.minutes(1)))
    func refusedViewIsReadAgain() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let aBytes = EngineFixture.bytes(9_981)
        let zBytes = EngineFixture.bytes(9_982)
        let a = EngineFixture.entry("a", aBytes)
        let z = EngineFixture.entry("z", zBytes)
        await harness.serve([(a, aBytes), (z, zBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        // The store applies v2 (z removed) without the engine's bookkeeping.
        let v2 = try ValidatedManifest(entries: [a], digest: ContentHash.sha256(of: Data("v2".utf8)))
        let report = try await harness.store.apply(v2, etag: nil, eviction: nil)
        #expect(report.pruned == ["z"], "setup: the store pruned z")
        let view = try await harness.view()
        // The view is refused: its read began before a change of the copy (a mark older than the copy's).
        let followed = await engine.readForTests { engine in
            engine.followStoreView(view, readAt: engine.state.copySerial &- 1)
        }
        #expect(!followed, "a view whose read may predate the copy is not followed")
        // The owed re-read is a catch-up: once none is in flight, the engine follows the store.
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.catchUpAfterFailedApply }
        #expect(await engine.readForTests { $0.state.applied.digest } == v2.digest, "the engine follows the store's manifest")
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        #expect(received.contains(.assetRemoved("z", .pruned)), "z's removal is announced: \(received)")
        #expect(received.contains(.snapshotChanged(generation: report.generation)), "the store's generation is announced")
        await probe.stop()
    }
}

extension SyncEngine {
    /// Test seam: reads a value from the engine's isolated state.
    func readForTests<T: Sendable>(_ read: @Sendable (isolated SyncEngine) -> T) -> T {
        read(self)
    }
}
