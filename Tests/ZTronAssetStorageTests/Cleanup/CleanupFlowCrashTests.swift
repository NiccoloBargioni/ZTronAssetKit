import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// One crash-enumerated cleanup flow: a set-up that never crashes, the enumerated run, and what a reopened survivor
/// must show (after the relaunch's reap), converging it (Stage 3 ruling S3C-7, S3-CRAS-03; adapted from the crash
/// hunters' `S3CleanupCrashProbe`). Every lifetime installs into a `CleanupAuditSink`, so each unlink of the crashed
/// lifetime, of the reopened one and of the clean reference run is audited for I-3; every clock move goes through
/// `CleanupFlowRun.advance(by:)` so the audit places each unlink in time.
@available(macOS 15.0, iOS 18.0, *)
struct CleanupFlow: Sendable {
    let name: String
    let policy: StoragePolicy
    /// Runs before the enumerated part; never crashes.
    let setUp: @Sendable (CleanupFlowRun) async throws -> Void
    /// The enumerated part; returns the newest generation a commit that returned reached.
    let run: @Sendable (CleanupFlowRun) async -> UInt64
    /// What must hold of a reopened survivor after the relaunch's reap; converges it.
    let check: @Sendable (CleanupFlowRun, String) async throws -> Void

    init(
        name: String,
        policy: StoragePolicy = CleanupFixture.policy(),
        setUp: @escaping @Sendable (CleanupFlowRun) async throws -> Void,
        run: @escaping @Sendable (CleanupFlowRun) async -> UInt64,
        check: @escaping @Sendable (CleanupFlowRun, String) async throws -> Void
    ) {
        self.name = name
        self.policy = policy
        self.setUp = setUp
        self.run = run
        self.check = check
    }
}

/// One lifetime of a crash enumeration: the harness and the audit of its unlinks.
@available(macOS 15.0, iOS 18.0, *)
struct CleanupFlowRun: Sendable {
    let harness: CoreHarness
    let audit: CleanupAuditSink

    /// A lifetime over `disk`, crashing before mutation `crashBefore` in `mode` when given.
    init(disk: DiskImage, policy: StoragePolicy, crashBefore: Int? = nil, mode: CrashMode = .processKill, time: ManualTimeSource = ManualTimeSource()) {
        (self.harness, self.audit) = CoreHarness.audited(disk: disk, policy: policy, crashBefore: crashBefore, mode: mode, time: time)
    }

    /// Moves the clock and tells the audit.
    func advance(by seconds: TimeInterval) async {
        self.harness.time.advance(by: seconds)
        await self.audit.clockMoved()
    }

    /// The deletion protocol driven to its end, audited.
    func settle() async {
        await self.harness.settleDeletions(audited: self.audit)
    }

    /// I-3 over this lifetime's unlinks so far.
    func expectI3(_ label: String) async {
        let violations = await self.audit.violations(self.harness.fileSystem.operations, layout: self.harness.layout, grace: self.harness.configuration.policy.deletionGrace)
        #expect(violations.isEmpty, "\(label): \(violations)")
    }

    /// Runs `operation`, which may sleep on the manual clock (a purge's grace wait) and may die in a crash, moving the
    /// clock to each deadline it sleeps until.
    func drive<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task {
            try await operation()
        }
        let done = CleanupSteps.Finished()
        let watcher = Task {
            _ = try? await task.value
            await done.set()
        }
        while !(await done.value) {
            if self.harness.time.pendingSleepers > 0, let next = self.harness.time.nextDeadline {
                self.harness.time.advance(to: next)
                await self.audit.clockMoved()
            }
            await Task.yield()
        }
        _ = await watcher.value
        return try await task.value
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum CleanupFlows {
    static let a = CleanupFixture.asset("a", seed: 8_001, count: 300)
    static let b = CleanupFixture.asset("b", seed: 8_002, count: 250)
    static let c = CleanupFixture.asset("c", seed: 8_003, count: 200, policy: .essential)
    static let all = [CleanupFlows.a, CleanupFlows.b, CleanupFlows.c]
    static let orphan = CleanupFixture.asset("o", seed: 8_009, count: 180)
    static let x = CleanupFixture.asset("x", seed: 8_020, count: 260, ext: "png")
    /// `x`'s bytes under a second extension: placing it copies the blob (`copyBlob`, then a placement from `.parttmp`).
    static var y: CleanupFixture.Asset {
        CleanupFixture.Asset(entry: CoreFixture.entry("y", CleanupFlows.x.bytes, ext: "jpg"), bytes: CleanupFlows.x.bytes)
    }

    /// A crash before every mutation of `flow`'s run in `mode`, each followed by a reopen with I-1…I-5, the relaunch's
    /// reap and convergence; every lifetime's unlinks audited for I-3.
    static func enumerate(_ flow: CleanupFlow, mode: CrashMode) async throws {
        let clean = CleanupFlowRun(disk: DiskImage(), policy: flow.policy)
        try await flow.setUp(clean)
        let start = clean.harness.fileSystem.mutationCount
        _ = await flow.run(clean)
        let total = clean.harness.fileSystem.mutationCount
        await clean.expectI3("\(flow.name): the run without a crash")
        #expect(total > start, "\(flow.name): the run mutates")
        for point in start..<total {
            // Return the pool thread between cases (ADR-051 item 2, point 8); a timed-out test ends at once.
            await Task.yield()
            try Task.checkCancellation()
            let label = "\(flow.name): \(mode) before mutation \(point)"
            let crashing = CleanupFlowRun(disk: DiskImage(), policy: flow.policy, crashBefore: point, mode: mode)
            try await flow.setUp(crashing)
            let committed = await flow.run(crashing)
            #expect(crashing.harness.fileSystem.crashed, "\(label): the crash happened")
            await crashing.expectI3(label)
            try await CleanupFlows.reopenAndCheck(
                flow,
                disk: crashing.harness.fileSystem.survivingDisk(),
                committed: committed,
                time: crashing.harness.time,
                label: label
            )
        }
        print("R-STO-5 \(flow.name) \(mode): \(total - start) crash points")
    }

    /// Reopens a survivor: I-5 against the disk it loaded, I-1…I-5, the relaunch's reap, the flow's own check and
    /// convergence, I-1…I-5 again, and I-3 over the lifetime's unlinks.
    static func reopenAndCheck(_ flow: CleanupFlow, disk: DiskImage, committed: UInt64, time: ManualTimeSource, label: String) async throws {
        let reopened = CleanupFlowRun(disk: disk, policy: flow.policy, time: time)
        let report = try await reopened.harness.store.open()
        await CleanupCrashTests.checkGenerations(reopened.harness, disk: disk, committed: committed, report: report, label: label)
        let violations = await CoreInvariants.violations(of: reopened.harness)
        #expect(violations.isEmpty, "\(label): \(violations)")
        await reopened.settle()
        let afterReap = await CoreInvariants.violations(of: reopened.harness)
        #expect(afterReap.isEmpty, "\(label), after the relaunch's reap: \(afterReap)")
        try await flow.check(reopened, label)
        let after = await CoreInvariants.violations(of: reopened.harness)
        #expect(after.isEmpty, "\(label), after convergence: \(after)")
        await reopened.harness.store.close()
        await reopened.expectI3(label + ", relaunch")
    }

    /// Re-applies `assets`, publishes whatever is not present at its key, reaps, and requires every byte back.
    static func converge(_ run: CleanupFlowRun, _ assets: [CleanupFixture.Asset], label: String) async throws {
        let harness = run.harness
        _ = try await harness.store.apply(CoreFixture.manifest(assets.map(\.entry)), etag: nil, eviction: nil)
        for (index, asset) in assets.enumerated() where !(await harness.isPresent(asset.id, at: asset.key)) {
            try await harness.publish(asset.bytes, [asset.entry], urgency: .userInitiated, sequence: UInt32(60 + index))
        }
        await run.settle()
        try await harness.store.flush(.durable)
        for asset in assets {
            let location = await harness.store.location(for: asset.id, extensions: [], recordingAccess: false)
            let residency = await harness.record(asset.id)?.residency
            #expect(location.flatMap { harness.content($0.url) } == asset.bytes, "\(label): \(asset.id.rawValue) did not converge: \(String(describing: residency))")
        }
    }

    /// Seeds `assets`, commits durably and lets an hour pass (every asset older than any residency window).
    static func seedDurable(_ run: CleanupFlowRun, _ assets: [CleanupFixture.Asset] = CleanupFlows.all) async throws {
        try await run.harness.seed(assets)
        try await run.harness.store.flush(.durable)
        await run.advance(by: 3_600)
    }

    /// The committed generation after a durable flush, then a clean close; whatever ran before stops at a crash.
    static func finish(_ run: CleanupFlowRun, _ committed: inout UInt64) async throws {
        try await run.harness.store.flush(.durable)
        committed = await run.harness.state.core.committedGeneration
        await run.harness.store.close()
    }

    /// `purge(request)` of every seeded asset, through its grace wait.
    static func purge(_ request: PurgeRequest) -> CleanupFlow {
        CleanupFlow(
            name: request == .all ? "purge(.all)" : "purge(.evictable)",
            setUp: { try await CleanupFlows.seedDurable($0) },
            run: { run in
                var committed: UInt64 = 0
                do {
                    let store = run.harness.store
                    _ = try await run.drive {
                        try await store.purge(request)
                    }
                    committed = await run.harness.state.core.committedGeneration
                    try await CleanupFlows.finish(run, &committed)
                } catch {}
                return committed
            },
            check: { run, label in
                for asset in CleanupFlows.all {
                    let residency = await run.harness.record(asset.id)?.residency
                    let present = await run.harness.isPresent(asset.id, at: asset.key)
                    let kept = request == .evictable && asset.entry.policy == .essential
                    #expect(present || (!kept && residency == .absent(.purged)), "\(label): \(asset.id.rawValue) is \(String(describing: residency))")
                    if present {
                        #expect(run.harness.content(run.harness.layout.blobURL(asset.key)) == asset.bytes, "\(label): \(asset.id.rawValue)'s bytes")
                    }
                }
                try await CleanupFlows.converge(run, CleanupFlows.all, label: label)
            }
        )
    }

    /// `reportUnreadable` (a quarantine dooming the blob `corrupt`), its reap, and the re-download that places the name
    /// again.
    static var quarantine: CleanupFlow {
        CleanupFlow(
            name: "reportUnreadable and its re-download",
            setUp: { try await CleanupFlows.seedDurable($0) },
            run: { run in
                var committed: UInt64 = 0
                do {
                    try await run.harness.store.reportUnreadable(CleanupFlows.a.id)
                    committed = await run.harness.state.core.committedGeneration
                    await run.settle()
                    await run.advance(by: 3_600)
                    try await run.harness.publish(CleanupFlows.a.bytes, [CleanupFlows.a.entry], urgency: .userInitiated, sequence: 30)
                    try await CleanupFlows.finish(run, &committed)
                } catch {}
                return committed
            },
            check: { run, label in
                await run.advance(by: 3_600)
                try await CleanupFlows.converge(run, CleanupFlows.all, label: label)
            }
        )
    }

    /// Orphan GC of a well-named blob nobody knows (placed by a lifetime whose commit was lost): the doom, then its reap.
    static var orphanGC: CleanupFlow {
        CleanupFlow(
            name: "orphan GC",
            setUp: { run in
                try await CleanupFlows.seedDurable(run, [CleanupFlows.a, CleanupFlows.b])
                let fileSystem = run.harness.fileSystem
                let layout = run.harness.layout
                try fileSystem.createDirectory(at: layout.fanOutDirectory(for: CleanupFlows.orphan.key.hash))
                try fileSystem.write(CleanupFlows.orphan.bytes, to: layout.blobURL(CleanupFlows.orphan.key), mode: .truncate)
                try fileSystem.synchronizeFile(at: layout.blobURL(CleanupFlows.orphan.key), level: .full)
                try fileSystem.synchronizeDirectory(at: layout.fanOutDirectory(for: CleanupFlows.orphan.key.hash), level: .full)
                try fileSystem.synchronizeDirectory(at: layout.blobsDirectory, level: .full)
                await run.advance(by: 3_601)
            },
            run: { run in
                var committed: UInt64 = 0
                do {
                    _ = try await run.harness.store.collectGarbage(until: run.harness.time.monotonicNow().adding(seconds: 60))
                    committed = await run.harness.state.core.committedGeneration
                    await run.settle()
                    try await CleanupFlows.finish(run, &committed)
                } catch {}
                return committed
            },
            check: { run, label in
                try await CleanupFlows.converge(run, [CleanupFlows.a, CleanupFlows.b], label: label)
                let readded = CleanupFixture.Asset(entry: CoreFixture.entry("o", CleanupFlows.orphan.bytes), bytes: CleanupFlows.orphan.bytes)
                try await CleanupFlows.converge(run, [CleanupFlows.a, CleanupFlows.b, readded], label: label + " (the orphan's content re-added)")
            }
        )
    }

    /// Deep verification of every blob, then a durable flush.
    static var verify: CleanupFlow {
        CleanupFlow(
            name: "verifyIntegrity",
            setUp: { try await CleanupFlows.seedDurable($0) },
            run: { run in
                var committed: UInt64 = 0
                do {
                    _ = try await run.harness.store.verifyIntegrity(byteBudget: 1 << 30, until: run.harness.time.monotonicNow().adding(seconds: 60))
                    committed = await run.harness.state.core.committedGeneration
                    try await CleanupFlows.finish(run, &committed)
                } catch {}
                return committed
            },
            check: { run, label in
                for asset in CleanupFlows.all {
                    #expect(await run.harness.isPresent(asset.id, at: asset.key), "\(label): \(asset.id.rawValue) stays present")
                }
                try await CleanupFlows.converge(run, CleanupFlows.all, label: label)
            }
        )
    }

    /// One content under two extensions (the second placement copies the blob, `copyBlob`), then the first removed and
    /// reaped.
    static var secondExtension: CleanupFlow {
        CleanupFlow(
            name: "a second extension, then a removal",
            setUp: { run in
                _ = try await run.harness.store.open()
                _ = try await run.harness.store.apply(CoreFixture.manifest([CleanupFlows.x.entry, CleanupFlows.y.entry]), etag: nil, eviction: nil)
                try await run.harness.store.flush(.durable)
            },
            run: { run in
                var committed: UInt64 = 0
                do {
                    try await run.harness.publish(CleanupFlows.x.bytes, [CleanupFlows.x.entry, CleanupFlows.y.entry], urgency: .bulk, sequence: 3)
                    try await run.harness.store.flush(.ordered)
                    committed = await run.harness.state.core.committedGeneration
                    await run.advance(by: 60)
                    _ = try await run.harness.store.apply(CoreFixture.manifest([CleanupFlows.y.entry]), etag: nil, eviction: nil)
                    committed = await run.harness.state.core.committedGeneration
                    await run.settle()
                    try await CleanupFlows.finish(run, &committed)
                } catch {}
                return committed
            },
            check: { run, label in
                try await CleanupFlows.converge(run, [CleanupFlows.y], label: label)
                try await CleanupFlows.converge(run, [CleanupFlows.x, CleanupFlows.y], label: label + " (x re-added)")
            }
        )
    }

    /// Quota eviction while a lease holds the least recently used asset, its reap held by the lease, then released.
    static var leasedEviction: CleanupFlow {
        CleanupFlow(
            name: "eviction held by a lease",
            policy: CleanupFixture.policy(budget: .bytes(400), hysteresisTarget: 1),
            setUp: { try await CleanupFlows.seedDurable($0) },
            run: { run in
                var committed: UInt64 = 0
                do {
                    let lease = try await run.harness.store.acquireLease(CleanupFlows.a.id)
                    _ = try await run.harness.store.evictIfNeeded()
                    committed = await run.harness.state.core.committedGeneration
                    await run.settle()
                    _ = await run.harness.store.releaseLease(lease)
                    await run.settle()
                    try await CleanupFlows.finish(run, &committed)
                } catch {}
                return committed
            },
            check: { run, label in
                #expect(await run.harness.isPresent(CleanupFlows.c.id, at: CleanupFlows.c.key), "\(label): the essential asset stays")
                for asset in [CleanupFlows.a, CleanupFlows.b] {
                    let residency = await run.harness.record(asset.id)?.residency
                    let present = await run.harness.isPresent(asset.id, at: asset.key)
                    #expect(present || residency == .absent(.evicted), "\(label): \(asset.id.rawValue) is \(String(describing: residency))")
                }
                try await CleanupFlows.converge(run, CleanupFlows.all, label: label)
            }
        )
    }
}

/// Crash at every boundary of the cleanup flows the eviction and legacy enumerations of `CleanupCrashTests` do not reach
/// (SPEC 7.3; Stage 3 ruling S3C-7, S3-CRAS-03).
@Suite("Cleanup: crash at every boundary of purge, quarantine, orphan GC, verification, a second extension and a leased eviction (R-STO-5)")
struct CleanupFlowCrashTests {
    @Test("R-STO-5: crash at every boundary during purge(.all) preserves I-1…I-5", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeAll(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.purge(.all), mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during purge(.evictable) preserves I-1…I-5 and keeps the essential asset", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeEvictable(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.purge(.evictable), mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during a quarantine, its reap and the re-download preserves I-1…I-5", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func quarantine(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.quarantine, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during orphan GC's doom and reap preserves I-1…I-5", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func orphanGC(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.orphanGC, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during deep verification preserves I-1…I-5", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func verify(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.verify, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary while identical bytes are copied under a second extension, then one is removed, preserves I-1…I-5", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func secondExtension(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.secondExtension, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during an eviction whose reap waits for a lease preserves I-1…I-5", .serialized, .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func leasedEviction(mode: CrashMode) async throws {
        try await CleanupFlows.enumerate(CleanupFlows.leasedEviction, mode: mode)
    }
}
