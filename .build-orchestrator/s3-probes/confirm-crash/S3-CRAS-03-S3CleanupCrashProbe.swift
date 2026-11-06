import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3 probes (lens crash): crash at every boundary during cleanup flows the shipped enumerations do not cover
/// (purge, quarantine, orphan GC, deep verification, a lease held across eviction), each followed by a reopen with
/// I-1…I-5, the relaunch's reap and convergence.
@available(macOS 15.0, iOS 18.0, *)
struct S3Scenario {
    let name: String
    let policy: StoragePolicy
    let initialDisk: DiskImage
    /// Runs before the enumerated part; never crashes.
    let setUp: (CoreHarness) async throws -> Void
    /// The enumerated part; returns the newest generation a commit that returned reached.
    let run: (CoreHarness) async -> UInt64
    /// What must hold of a reopened survivor (after the relaunch's reap); converges it.
    let check: (CoreHarness, String) async throws -> Void

    init(
        name: String,
        policy: StoragePolicy? = nil,
        setUp: @escaping (CoreHarness) async throws -> Void,
        run: @escaping (CoreHarness) async -> UInt64,
        check: @escaping (CoreHarness, String) async throws -> Void
    ) {
        self.name = name
        self.policy = policy ?? CleanupFixture.policy()
        self.initialDisk = DiskImage()
        self.setUp = setUp
        self.run = run
        self.check = check
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum S3Crash {
    static let a = CleanupFixture.asset("a", seed: 8_001, count: 300)
    static let b = CleanupFixture.asset("b", seed: 8_002, count: 250)
    static let c = CleanupFixture.asset("c", seed: 8_003, count: 200, policy: .essential)
    static let all = [S3Crash.a, S3Crash.b, S3Crash.c]

    /// Drives a call that may sleep on the manual clock (purge's grace wait) and may die in a crash.
    static func drive<T: Sendable>(_ harness: CoreHarness, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let done = S3Flag()
        let watcher = Task {
            _ = try? await task.value
            await done.set()
        }
        while !(await done.value) {
            if harness.time.pendingSleepers > 0, let next = harness.time.nextDeadline {
                harness.time.advance(to: next)
            }
            await Task.yield()
        }
        _ = await watcher.value
        return try await task.value
    }

    static func enumerate(_ scenario: S3Scenario, mode: CrashMode) async throws {
        let clean = CoreHarness.cleanup(disk: scenario.initialDisk, policy: scenario.policy)
        try await scenario.setUp(clean)
        let start = clean.fileSystem.mutationCount
        _ = await scenario.run(clean)
        let total = clean.fileSystem.mutationCount
        #expect(total > start, "\(scenario.name): the run mutates")
        for point in start..<total {
            await Task.yield()
            let label = "\(scenario.name): \(mode) before mutation \(point)"
            let (harness, audit) = CoreHarness.audited(disk: scenario.initialDisk, policy: scenario.policy, crashBefore: point, mode: mode)
            try await scenario.setUp(harness)
            let committed = await scenario.run(harness)
            #expect(harness.fileSystem.crashed, "\(label): the crash happened")
            let i3 = await audit.violations(harness.fileSystem.operations, layout: harness.layout)
            #expect(i3.isEmpty, "\(label): \(i3)")
            let disk = harness.fileSystem.survivingDisk()
            try await S3Crash.reopenAndCheck(scenario, disk: disk, committed: committed, time: harness.time, label: label)
        }
        print("S3 probe \(scenario.name) \(mode): \(total - start) crash points")
    }

    /// A kill at every point of the run, then a second lifetime (open, reap, durable flush, close) that loses power at
    /// every one of its boundaries.
    static func enumeratePairs(_ scenario: S3Scenario, mode: CrashMode) async throws {
        let clean = CoreHarness.cleanup(disk: scenario.initialDisk, policy: scenario.policy)
        try await scenario.setUp(clean)
        let start = clean.fileSystem.mutationCount
        _ = await scenario.run(clean)
        let total = clean.fileSystem.mutationCount
        var pairs = 0
        for point in start..<total {
            await Task.yield()
            let first = CoreHarness.cleanup(disk: scenario.initialDisk, policy: scenario.policy, crashBefore: point, mode: .processKill)
            try await scenario.setUp(first)
            let committed = await scenario.run(first)
            let killed = first.fileSystem.survivingDisk()
            let probe = CoreHarness.cleanup(disk: killed, policy: scenario.policy, time: first.time)
            await S3Crash.secondLifetime(probe)
            let secondTotal = probe.fileSystem.mutationCount
            for secondPoint in 0...secondTotal {
                await Task.yield()
                let label = "\(scenario.name): kill before \(point), \(mode) before \(secondPoint)"
                let second = CoreHarness.cleanup(disk: killed, policy: scenario.policy, crashBefore: secondPoint < secondTotal ? secondPoint : nil, mode: mode, time: first.time)
                await S3Crash.secondLifetime(second)
                try await S3Crash.reopenAndCheck(scenario, disk: second.fileSystem.survivingDisk(), committed: 0, time: first.time, label: label)
                _ = committed
                pairs += 1
            }
        }
        print("S3 probe \(scenario.name) kill→\(mode): \(pairs) pairs")
    }

    static func secondLifetime(_ harness: CoreHarness) async {
        do {
            _ = try await harness.store.open()
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            await harness.store.close()
        } catch {
            // The power loss.
        }
    }

    static func reopenAndCheck(_ scenario: S3Scenario, disk: DiskImage, committed: UInt64, time: ManualTimeSource, label: String) async throws {
        let (reopened, audit) = CoreHarness.audited(disk: disk, policy: scenario.policy, time: time)
        let report = try await reopened.store.open()
        defer {
            _ = audit
        }
        await CleanupCrashTests.checkGenerations(reopened, disk: disk, committed: committed, report: report, label: label)
        let violations = await CoreInvariants.violations(of: reopened)
        #expect(violations.isEmpty, "\(label): \(violations)")
        await reopened.settleDeletions()
        let afterReap = await CoreInvariants.violations(of: reopened)
        #expect(afterReap.isEmpty, "\(label) after the relaunch's reap: \(afterReap)")
        try await scenario.check(reopened, label)
        let after = await CoreInvariants.violations(of: reopened)
        #expect(after.isEmpty, "\(label) after convergence: \(after)")
        await reopened.store.close()
        let i3 = await audit.violations(reopened.fileSystem.operations, layout: reopened.layout)
        #expect(i3.isEmpty, "\(label) relaunch: \(i3)")
    }

    /// Re-applies `assets`, publishes whatever is not present at its key, reaps, and requires every byte back.
    static func converge(_ harness: CoreHarness, _ assets: [CleanupFixture.Asset], label: String) async throws {
        _ = try await harness.store.apply(CoreFixture.manifest(assets.map(\.entry)), etag: nil, eviction: nil)
        for (index, asset) in assets.enumerated() where !(await harness.isPresent(asset.id, at: asset.key)) {
            try await harness.publish(asset.bytes, [asset.entry], urgency: .userInitiated, sequence: UInt32(60 + index))
        }
        await harness.settleDeletions()
        try await harness.store.flush(.durable)
        for asset in assets {
            let location = await harness.store.location(for: asset.id, extensions: [], recordingAccess: false)
            let residency = await harness.record(asset.id)?.residency
            #expect(location.flatMap { harness.content($0.url) } == asset.bytes, "\(label): \(asset.id.rawValue) did not converge: \(String(describing: residency))")
        }
    }

    static func seedDurable(_ harness: CoreHarness, _ assets: [CleanupFixture.Asset] = S3Crash.all) async throws {
        try await harness.seed(assets)
        try await harness.store.flush(.durable)
        harness.time.advance(by: 3_600)
    }

    static var purgeAll: S3Scenario {
        S3Scenario(
        name: "purge(.all)",
        setUp: { try await S3Crash.seedDurable($0) },
        run: { harness in
            var committed: UInt64 = 0
            do {
                let store = harness.store
                _ = try await S3Crash.drive(harness) { try await store.purge(.all) }
                committed = await harness.state.core.committedGeneration
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            for asset in S3Crash.all {
                let residency = await harness.record(asset.id)?.residency
                let present = await harness.isPresent(asset.id, at: asset.key)
                #expect(present || residency == .absent(.purged), "\(label): \(asset.id.rawValue) is \(String(describing: residency))")
                if present {
                    #expect(harness.content(harness.layout.blobURL(asset.key)) == asset.bytes, "\(label): \(asset.id.rawValue)'s bytes")
                }
            }
            try await S3Crash.converge(harness, S3Crash.all, label: label)
        }
    )
    }

    static var purgeEvictable: S3Scenario {
        S3Scenario(
        name: "purge(.evictable)",
        setUp: { try await S3Crash.seedDurable($0) },
        run: { harness in
            var committed: UInt64 = 0
            do {
                let store = harness.store
                _ = try await S3Crash.drive(harness) { try await store.purge(.evictable) }
                committed = await harness.state.core.committedGeneration
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            #expect(await harness.isPresent(S3Crash.c.id, at: S3Crash.c.key), "\(label): the essential asset stays")
            try await S3Crash.converge(harness, S3Crash.all, label: label)
        }
    )
    }

    static var quarantine: S3Scenario {
        S3Scenario(
        name: "reportUnreadable + re-download",
        setUp: { try await S3Crash.seedDurable($0) },
        run: { harness in
            var committed: UInt64 = 0
            do {
                try await harness.store.reportUnreadable(S3Crash.a.id)
                committed = await harness.state.core.committedGeneration
                await harness.settleDeletions()
                harness.time.advance(by: 3_600)
                try await harness.publish(S3Crash.a.bytes, [S3Crash.a.entry], urgency: .userInitiated, sequence: 30)
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            harness.time.advance(by: 3_600)
            try await S3Crash.converge(harness, S3Crash.all, label: label)
        }
    )
    }

    static let orphan = CleanupFixture.asset("o", seed: 8_009, count: 180)
    static var orphanGC: S3Scenario {
        S3Scenario(
        name: "orphan GC",
        setUp: { harness in
            try await S3Crash.seedDurable(harness, [S3Crash.a, S3Crash.b])
            // A well-named blob nobody knows (placed by a lifetime whose commit was lost), written behind the store.
            let fileSystem = harness.fileSystem
            try fileSystem.createDirectory(at: harness.layout.fanOutDirectory(for: S3Crash.orphan.key.hash))
            try fileSystem.write(S3Crash.orphan.bytes, to: harness.layout.blobURL(S3Crash.orphan.key), mode: .truncate)
            try fileSystem.synchronizeFile(at: harness.layout.blobURL(S3Crash.orphan.key), level: .full)
            try fileSystem.synchronizeDirectory(at: harness.layout.fanOutDirectory(for: S3Crash.orphan.key.hash), level: .full)
            try fileSystem.synchronizeDirectory(at: harness.layout.blobsDirectory, level: .full)
            harness.time.advance(by: 3_601)
        },
        run: { harness in
            var committed: UInt64 = 0
            do {
                _ = try await harness.store.collectGarbage(until: harness.time.monotonicNow().adding(seconds: 60))
                committed = await harness.state.core.committedGeneration
                await harness.settleDeletions()
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            try await S3Crash.converge(harness, [S3Crash.a, S3Crash.b], label: label)
            let o = CleanupFixture.Asset(entry: CoreFixture.entry("o", S3Crash.orphan.bytes), bytes: S3Crash.orphan.bytes)
            try await S3Crash.converge(harness, [S3Crash.a, S3Crash.b, o], label: label + " (orphan re-added)")
        }
    )
    }

    static let x = CleanupFixture.asset("x", seed: 8_020, count: 260, ext: "png")
    static var y: CleanupFixture.Asset {
        var entry = CoreFixture.entry("y", S3Crash.x.bytes, ext: "jpg")
        entry.policy = .standard
        return CleanupFixture.Asset(entry: entry, bytes: S3Crash.x.bytes)
    }

    static var secondExtension: S3Scenario {
        S3Scenario(
        name: "second extension then removal",
        setUp: { harness in
            _ = try await harness.store.open()
            _ = try await harness.store.apply(CoreFixture.manifest([S3Crash.x.entry, S3Crash.y.entry]), etag: nil, eviction: nil)
            try await harness.store.flush(.durable)
        },
        run: { harness in
            var committed: UInt64 = 0
            do {
                try await harness.publish(S3Crash.x.bytes, [S3Crash.x.entry, S3Crash.y.entry], urgency: .bulk, sequence: 3)
                try await harness.store.flush(.ordered)
                committed = await harness.state.core.committedGeneration
                harness.time.advance(by: 60)
                _ = try await harness.store.apply(CoreFixture.manifest([S3Crash.y.entry]), etag: nil, eviction: nil)
                committed = await harness.state.core.committedGeneration
                await harness.settleDeletions()
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            try await S3Crash.converge(harness, [S3Crash.y], label: label)
            try await S3Crash.converge(harness, [S3Crash.x, S3Crash.y], label: label + " (x re-added)")
        }
    )
    }

    static var update: S3Scenario {
        S3Scenario(
        name: "checksum change, directory change, removal",
        setUp: { try await S3UpdateRun.setUp($0) },
        run: { await S3UpdateRun.update($0).committed },
        check: { harness, label in
            try await S3Crash.converge(harness, [S3UpdateRun.a2, S3UpdateRun.b2], label: label)
            #expect(await harness.store.location(for: S3UpdateRun.c1.id, extensions: [], recordingAccess: false) == nil, "\(label): c is gone")
        }
    )
    }

    static var verify: S3Scenario {
        S3Scenario(
        name: "verifyIntegrity",
        setUp: { try await S3Crash.seedDurable($0) },
        run: { harness in
            var committed: UInt64 = 0
            do {
                _ = try await harness.store.verifyIntegrity(byteBudget: 1 << 30, until: harness.time.monotonicNow().adding(seconds: 60))
                committed = await harness.state.core.committedGeneration
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            for asset in S3Crash.all {
                #expect(await harness.isPresent(asset.id, at: asset.key), "\(label): \(asset.id.rawValue) stays present")
            }
            try await S3Crash.converge(harness, S3Crash.all, label: label)
        }
    )
    }

    static var leasedEviction: S3Scenario {
        S3Scenario(
        name: "eviction with a lease",
        policy: CleanupFixture.policy(budget: .bytes(400), hysteresisTarget: 1),
        setUp: { try await S3Crash.seedDurable($0) },
        run: { harness in
            var committed: UInt64 = 0
            do {
                let lease = try await harness.store.acquireLease(S3Crash.a.id)
                _ = try await harness.store.evictIfNeeded()
                committed = await harness.state.core.committedGeneration
                await harness.settleDeletions()
                _ = await harness.store.releaseLease(lease)
                await harness.settleDeletions()
                try await harness.store.flush(.durable)
                committed = await harness.state.core.committedGeneration
                await harness.store.close()
            } catch {}
            return committed
        },
        check: { harness, label in
            #expect(await harness.isPresent(S3Crash.c.id, at: S3Crash.c.key), "\(label): the essential asset stays")
            for asset in [S3Crash.a, S3Crash.b] {
                let residency = await harness.record(asset.id)?.residency
                let present = await harness.isPresent(asset.id, at: asset.key)
                #expect(present || residency == .absent(.evicted), "\(label): \(asset.id.rawValue) is \(String(describing: residency))")
            }
        }
    )
    }
}

actor S3Flag {
    private(set) var value = false
    func set() {
        self.value = true
    }
}

@Suite("S3 probe: crash at every boundary during cleanup flows", .serialized)
struct S3CleanupCrashProbe {
    @Test("R-STO-5: crash at every boundary during purge(.all) preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeAll(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.purgeAll, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during purge(.evictable) preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeEvictable(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.purgeEvictable, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during a quarantine and its re-download preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func quarantine(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.quarantine, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during orphan GC preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func orphanGC(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.orphanGC, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary while identical bytes are placed under a second extension, then one is removed, preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func secondExtension(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.secondExtension, mode: mode)
    }

    @Test("R-STO-5: a kill while bytes are placed under a second extension, then a power loss at every boundary of the next lifetime, preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata])
    @available(macOS 15.0, iOS 18.0, *)
    func secondExtensionPairs(mode: CrashMode) async throws {
        try await S3Crash.enumeratePairs(S3Crash.secondExtension, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during an update (audited I-3) preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func update(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.update, mode: mode)
    }

    @Test("R-STO-5: a kill during an update, then a power loss at every boundary of the next lifetime, preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata])
    @available(macOS 15.0, iOS 18.0, *)
    func updatePairs(mode: CrashMode) async throws {
        try await S3Crash.enumeratePairs(S3Crash.update, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during deep verification preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func verify(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.verify, mode: mode)
    }

    @Test("R-STO-5: crash at every boundary during an eviction that waits for a lease preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: CrashMode.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func leasedEviction(mode: CrashMode) async throws {
        try await S3Crash.enumerate(S3Crash.leasedEviction, mode: mode)
    }

    @Test("R-STO-5: a kill during purge(.all), then a power loss at every boundary of the next lifetime, preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata])
    @available(macOS 15.0, iOS 18.0, *)
    func purgePairs(mode: CrashMode) async throws {
        try await S3Crash.enumeratePairs(S3Crash.purgeAll, mode: mode)
    }

    @Test("R-STO-5: a kill during a quarantine, then a power loss at every boundary of the next lifetime, preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata])
    @available(macOS 15.0, iOS 18.0, *)
    func quarantinePairs(mode: CrashMode) async throws {
        try await S3Crash.enumeratePairs(S3Crash.quarantine, mode: mode)
    }

    @Test("R-STO-5: a kill during an eviction with a lease, then a power loss at every boundary of the next lifetime, preserves I-1…I-5", .timeLimit(.minutes(1)), arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata])
    @available(macOS 15.0, iOS 18.0, *)
    func evictionPairs(mode: CrashMode) async throws {
        try await S3Crash.enumeratePairs(S3Crash.leasedEviction, mode: mode)
    }
}
