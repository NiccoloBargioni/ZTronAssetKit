import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 4 found in WP-F (cycle 5 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-25).
@Suite("Engine regressions, close-out cycle 5")
struct EngineRegressionCycle5Tests {
    /// What the ensure's `apply` applies after the run's.
    enum SecondManifest: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The same `v2` the run applied.
        case same
        /// A later `v3`, which also lists the on-demand `b` (and still not `z`).
        case later

        var testDescription: String {
            self.rawValue
        }
    }

    // MARK: Two committed applies followed in the store's order (R-SYN-12, L4-R7, L4-R10; PROBE-C4-4)

    /// PROBE-C4-4: a run applies `v2` (drops `z`) and an `ensureAvailable` then applies `v2` again or `v3` (adds `b`).
    /// The store commits the run's `apply` first; the engine ran its side of the ensure's `apply` first (a
    /// higher-priority continuation overtaking a lower-priority one while the actor was busy; here the run's follow-up is
    /// held by a test seam until no other `apply` is at the store or waiting to be followed). Following the run's older
    /// report last took the engine's copy back to `v2` while the store held `v3`, announced `z` pruned a second time and
    /// announced `b` pruned although the store lists and serves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-12: two committed applies are followed in the store's order, so a prune is announced once and a later apply's additions never",
        .timeLimit(.minutes(1)),
        arguments: SecondManifest.allCases
    )
    func appliesFollowedInStoreOrder(_ second: SecondManifest) async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let engine = harness.engine
        let aBytes = EngineFixture.bytes(9_801)
        let zBytes = EngineFixture.bytes(9_802)
        let a = EngineFixture.entry("a", aBytes)
        let z = EngineFixture.entry("z", zBytes)
        await harness.serve([(a, aBytes), (z, zBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let bBytes = EngineFixture.bytes(9_803)
        let b = EngineHarness.onDemand("b", bBytes)
        await harness.source.script(b.transferID, [.stage(bBytes)])
        let v2 = EngineFixture.manifestData([a])
        let next = second == .same ? v2 : EngineFixture.manifestData([a, b])
        await harness.source.scriptManifest([
            .fetched(v2, etag: EngineFixture.etag("v2")),
            .fetched(next, etag: EngineFixture.etag(second == .same ? "v2" : "v3"))
        ])
        // The run's `apply` holds in the store's planning unit (after the run's manifest decode).
        await bulk.holdNext(skipping: 1)
        let run = Task { await engine.sync(.force) }
        await bulk.waitForHold()
        // The ensure fetches the next manifest and begins its own `apply`.
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(["a"])) }
        await engine.awaitCondition { $0.state.manifestCatchUps == 2 }
        // The run's `apply` commits first; the engine's side of it waits until no other `apply` is at the store or
        // waiting to be followed.
        await engine.holdNextApplyFollow()
        await bulk.release()
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        await engine.releaseApplyFollow()
        let outcome = await harness.withClock { await EngineHarness.value(of: run) }
        let ensured = await ensure.value
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.catchUpAfterFailedApply && $0.state.appliesInFlight == 0 }
        #expect(outcome.completeReport != nil, "setup: the run completes: \(outcome)")
        #expect((try? ensured.get())?.present == 1, "setup: the ensure's apply commits: \(ensured)")
        let storeManifest = try await harness.view().appliedManifest
        let copy = await engine.readForTests { $0.state.applied }
        #expect(copy.digest == storeManifest.digest, "\(second): the engine's copy \(copy.entries.map(\.identifier)) is the store's \(storeManifest.entries.map(\.identifier))")
        if second == .later {
            #expect(copy.entry(for: "b") != nil, "the engine's copy lists b, as the store does")
        }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        await probe.stop()
        let zPrunes = received.filter { $0 == .assetRemoved("z", .pruned) }.count
        let bRemovals = received.filter {
            if case .assetRemoved("b", _) = $0 {
                return true
            }
            return false
        }.count
        #expect(zPrunes == 1, "\(second): z's prune is announced exactly once: \(received)")
        #expect(bRemovals == 0, "\(second): b, which the store lists, is never announced removed: \(received)")
    }

    // MARK: An ensure whose member lacks room (R-SYN-11, R-SYN-10; review of close-out cycle 4)

    /// Review of close-out cycle 4 (non-blocking, by reading): the ensure's plan fits the volume, but its member's job
    /// lacks room once the bytes of another job in flight are counted (the headroom ledger, S2-09). The member was failed
    /// with `insufficientSpace` and dropped, and the ensure answered `.success` with the member missing, so the caller
    /// never learned why; R-SYN-11 asks for a typed `insufficientSpace(required:available:)` on a shortage.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: ensureAvailable whose member lacks room beside a transfer in flight fails with insufficientSpace",
        .timeLimit(.minutes(1))
    )
    func ensureMemberShortOfRoomFailsTyped() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(time: time, fileSystem: fileSystem)
        let engine = harness.engine
        let hBytes = EngineFixture.bytes(9_911, count: 300)
        let yBytes = EngineFixture.bytes(9_912, count: 300)
        let h = EngineFixture.entry("h", hBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([h, y])
        await harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await harness.source.script(y.transferID, [.stage(yBytes)])
        try await harness.start()
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        await engine.waitForHandle(h.transferID)
        try await harness.store.flush(.ordered)
        // 450 bytes of room above the reserve: y (300) fits the volume, but not beside h's 300 bytes in flight.
        let room = try await harness.store.freeSpace().volumeImportant - reserve
        try fileSystem.write(Data(repeating: 1, count: Int(room - 450)), to: EngineHarness.base.appendingPathComponent("ballast"), mode: .truncate)
        let ensured = await engine.ensureAvailable(scope: .identifiers(["y"]))
        if case .failure(.insufficientSpace(let required, let available)) = ensured {
            #expect(required == Int64(yBytes.count), "the bytes y needs: \(required)")
            #expect(available <= 150, "the room above the reserve beside h's bytes in flight: \(available)")
        } else {
            Issue.record("the ensure fails with a typed insufficientSpace: \(ensured)")
        }
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.isEmpty, "no transfer of y began")
        #expect(await engine.invariantViolations().isEmpty)
        await harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        _ = await run.value
        await engine.shutdown()
    }

    // MARK: Bytes the store has not scheduled to reclaim (R-SYN-11, L4-R8; review of close-out cycle 4)

    /// Review of close-out cycle 4 (blocking; the in-suite failure and the hang of
    /// `R-SYN-10: ensureAvailable downloads a member that an apply evicted before it threw`): an ensure's member short of
    /// space while the store counts doomed bytes as pending reclaim parked `awaitingSpace`, which only the alarm's
    /// `runDueWork()` wakes. When the store schedules nothing that would reclaim them (no `nextDeadline()`: their blocker
    /// is an acknowledgement or a commit only the store's later work brings), no alarm fires and the caller waited until it
    /// gave up. The verifier reached that state through the store's timing after an `apply` that threw; here the snapshot
    /// sink keeps its snapshot (a main actor that did not take the install), which leaves the pruned blob waiting for an
    /// acknowledgement with no deadline, deterministically.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: ensureAvailable short of bytes the store has not scheduled to reclaim fails with insufficientSpace instead of waiting for ever",
        .timeLimit(.minutes(1))
    )
    func unscheduledReclaimFailsTyped() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 0), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(9_901, count: 300)
        let yBytes = EngineFixture.bytes(9_902, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes), (y, yBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        // The store's due work after x's publication (its trailing install, which readers acknowledge) is done.
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // 200 bytes of room above the reserve: y (300) needs x's bytes reclaimed.
        let room = try await harness.store.freeSpace().volumeImportant - reserve
        try fileSystem.write(Data(repeating: 1, count: Int(room - 200)), to: EngineHarness.base.appendingPathComponent("ballast"), mode: .truncate)
        // v2 prunes x and lists the on-demand y; no install is acknowledged from now on.
        await harness.sink.setBehaviour(.ignore)
        await harness.serveManifest([y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's pruned bytes wait for reclaim")
        #expect(await harness.store.nextDeadline() == nil, "setup: the store schedules no work that would reclaim them")
        // The ensure reads the free space (x's bytes pending reclaim), so its plan fits; its member's job then lacks room
        // on the volume until those bytes are reclaimed.
        let ensured = await harness.withClock { await engine.ensureAvailable(scope: .identifiers(["y"])) }
        if case .failure(.insufficientSpace(let required, let available)) = ensured {
            #expect(required == Int64(yBytes.count), "the bytes y needs: \(required)")
            #expect(available < required, "the room above the reserve y's job had: \(available)")
        } else {
            Issue.record("y's fetch fails with a typed insufficientSpace instead of waiting: \(ensured)")
        }
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.isEmpty, "no transfer of y began")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
