import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTestSupport

private func ids(_ names: [String]) -> [AssetID] {
    names.map { AssetID($0) }
}

/// A `PrefetchRegistry` whose user-initiated registrations wait behind a gate until the test opens it, so the
/// order of a re-lane's registration and release is observable (sync-1 S1-05). Unknown tokens are ignored, like the
/// engine; only effective releases are logged, so the log is deterministic.
private actor GatedRegistry: PrefetchRegistry {
    struct Counts: Sendable {
        var registrations = 0
        var gated = 0
        var releases = 0
    }

    private let refuses: Bool
    private var nextToken: UInt64 = 0
    private var live: [InterestToken: [AssetID]] = [:]
    private var gateOpen = false
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(predicate: @Sendable (Counts) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var counts = Counts()
    private(set) var log: [String] = []
    /// The fewest holders each asset had right after any release (0 would mean its transfer was cancelled).
    private(set) var minimumHolders: [AssetID: Int] = [:]

    init(refuses: Bool = false) {
        self.refuses = refuses
    }

    var holderCounts: [AssetID: Int] {
        var result: [AssetID: Int] = [:]
        for ids in self.live.values {
            for id in ids {
                result[id, default: 0] += 1
            }
        }
        return result
    }

    func registerGroup(_ ids: [AssetID], lane: AssetPriority) async -> Result<InterestToken, AssetError> {
        if self.refuses {
            return .failure(.shutDown)
        }
        if lane == .userInitiated && !self.gateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gate.append(continuation)
                self.counts.gated += 1
                self.notify()
            }
        }
        self.nextToken += 1
        let token = InterestToken(rawValue: self.nextToken)
        self.live[token] = ids
        self.log.append("register \(ids.map(\.rawValue).joined(separator: ",")) at \(lane) -> \(self.nextToken)")
        self.counts.registrations += 1
        self.notify()
        return .success(token)
    }

    func releaseGroup(_ token: InterestToken) {
        guard let ids = self.live.removeValue(forKey: token) else {
            return
        }
        self.log.append("release \(token.rawValue)")
        let holders = self.holderCounts
        for id in ids {
            self.minimumHolders[id] = min(self.minimumHolders[id] ?? Int.max, holders[id] ?? 0)
        }
        self.counts.releases += 1
        self.notify()
    }

    func openGate() {
        self.gateOpen = true
        let released = self.gate
        self.gate = []
        for continuation in released {
            continuation.resume()
        }
    }

    func waitUntil(_ predicate: @escaping @Sendable (Counts) -> Bool) async {
        if predicate(self.counts) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.waiters.append((predicate, continuation))
        }
    }

    private func notify() {
        let counts = self.counts
        var ready: [CheckedContinuation<Void, Never>] = []
        self.waiters.removeAll { waiter in
            if waiter.predicate(counts) {
                ready.append(waiter.continuation)
                return true
            }
            return false
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}

/// Records every purge it receives.
@MainActor
private final class CountingCache: PurgeableCache {
    var levels: [MemoryPressureLevel] = []

    func purge(level: MemoryPressureLevel) {
        self.levels.append(level)
    }
}

@Suite("Facade contracts")
struct KitContractTests {
    @Test("R-CAR-3: window targets are current, then ±1, then ±2, clamped at both ends")
    func windowOrder() {
        let pages = ids(["p0", "p1", "p2", "p3", "p4", "p5"])
        let middle = PrefetchWindow.targets(ids: pages, current: 2, radius: 2)
        #expect(middle.map(\.id) == ids(["p2", "p3", "p1", "p4", "p0"]))
        #expect(middle.map(\.priority) == [.userInitiated, .prefetch, .prefetch, .prefetch, .prefetch])
        #expect(middle.map(\.distance) == [0, 1, 1, 2, 2])
        #expect(PrefetchWindow.targets(ids: pages, current: 0, radius: 2).map(\.id) == ids(["p0", "p1", "p2"]))
        #expect(PrefetchWindow.targets(ids: pages, current: 5, radius: 2).map(\.id) == ids(["p5", "p4", "p3"]))
        #expect(PrefetchWindow.targets(ids: pages, current: 3, radius: -1).map(\.id) == ids(["p3"]))
    }

    @Test("R-CAR-3: a repeated identifier keeps its closest occurrence and an out-of-range index yields nothing")
    func windowDeduplicates() {
        let pages = ids(["a", "b", "a", "c", "b"])
        let targets = PrefetchWindow.targets(ids: pages, current: 2, radius: 2)
        #expect(targets.map(\.id) == ids(["a", "c", "b"]))
        #expect(targets.map(\.distance) == [0, 1, 1])
        #expect(PrefetchWindow.targets(ids: pages, current: 5, radius: 2).isEmpty)
        #expect(PrefetchWindow.targets(ids: [], current: 0, radius: 2).isEmpty)
    }

    @Test("R-CAR-2: image, svg, video and audio kinds use the prior-art candidate extensions in order")
    func candidateExtensions() {
        #expect(AssetKind.image.candidateExtensions == ["heic", "png", "jpg", "jpeg"])
        #expect(AssetKind.svg.candidateExtensions == ["svg"])
        #expect(AssetKind.video(fileExtension: "mp4").candidateExtensions == ["mp4"])
        #expect(AssetKind.audio.candidateExtensions == ["wav", "mp3"])
        #expect(BundleResourceKey(name: "x", fileExtension: "PNG") == BundleResourceKey(name: "x", fileExtension: "png"))
    }

    @Test("R-CAR-3: a re-laned prefetch handle releases its old interest only after the successor registered", .timeLimit(.minutes(1)))
    func reLaneNeverDropsInterest() async throws {
        let registry = GatedRegistry()
        var old: PrefetchHandle? = PrefetchHandle(registry: registry, ids: ids(["a"]), priority: .prefetch)
        await registry.waitUntil { $0.registrations == 1 }
        let replacement = PrefetchHandle(registry: registry, ids: ids(["a"]), priority: .userInitiated)
        await registry.waitUntil { $0.gated == 1 }
        weak let released = old
        old?.cancel(after: replacement)
        old = nil
        // The ordered release holds the old handle, so its deinit cannot start an unordered release (sync-1 S1-05).
        #expect(released != nil)
        #expect(await registry.holderCounts == ["a": 1])
        await registry.openGate()
        await registry.waitUntil { $0.releases == 1 }
        #expect(await registry.log == ["register a at prefetch -> 1", "register a at userInitiated -> 2", "release 1"])
        #expect(await registry.minimumHolders == ["a": 1])
        #expect(await registry.holderCounts == ["a": 1])
        #expect(old == nil)
        try await replacement.awaitRegistration()
    }

    @Test("R-CAR-4: a handle released without cancel() releases its interest on deinit", .timeLimit(.minutes(1)))
    func deinitReleasesInterest() async {
        let registry = GatedRegistry()
        var handle: PrefetchHandle? = PrefetchHandle(registry: registry, ids: ids(["a", "b"]), priority: .prefetch)
        await registry.waitUntil { $0.registrations == 1 }
        #expect(await registry.holderCounts == ["a": 1, "b": 1])
        handle = nil
        await registry.waitUntil { $0.releases == 1 }
        #expect(await registry.holderCounts.isEmpty)
        #expect(handle == nil)
    }

    @Test("R-CAR-4: cancel() before the registration landed releases the interest right after it", .timeLimit(.minutes(1)))
    func cancelBeforeRegistration() async {
        let registry = GatedRegistry()
        let handle = PrefetchHandle(registry: registry, ids: ids(["a"]), priority: .userInitiated)
        await registry.waitUntil { $0.gated == 1 }
        handle.cancel()
        handle.cancel()
        await registry.openGate()
        await registry.waitUntil { $0.releases == 1 }
        #expect(await registry.holderCounts.isEmpty)
        #expect(await registry.log == ["register a at userInitiated -> 1", "release 1"])
    }

    @Test("R-SYN-15: a prefetch handle made after shutdown reports shutDown and holds nothing", .timeLimit(.minutes(1)))
    func handleAfterShutdown() async {
        let registry = GatedRegistry(refuses: true)
        let handle = PrefetchHandle(registry: registry, ids: ids(["a"]), priority: .prefetch)
        await #expect(throws: AssetError.shutDown) {
            try await handle.awaitRegistration()
        }
        handle.cancel()
        #expect(await registry.holderCounts.isEmpty)
        #expect(await registry.log.isEmpty)
    }

    @MainActor
    @Test("R-CLN-11: the cache relay purges every live cache, stops observing when none is left and refuses registration after shutdown")
    func cacheRelay() throws {
        let relay = PurgeableCacheRelay()
        let first = CountingCache()
        var second: CountingCache? = CountingCache()
        #expect(relay.add(first) == .start(epoch: 1))
        #expect(relay.add(try #require(second)) == .unchanged)
        #expect(relay.add(first) == .unchanged)
        #expect(relay.purge(level: .warning) == .unchanged)
        #expect(first.levels == [.warning])
        #expect(second?.levels == [.warning])
        second = nil
        #expect(relay.liveCount == 1)
        #expect(relay.purge(level: .critical) == .unchanged)
        #expect(first.levels == [.warning, .critical])
        #expect(relay.remove(first) == .stop(epoch: 2))
        #expect(relay.remove(first) == .unchanged)
        var transient: CountingCache? = CountingCache()
        #expect(relay.add(try #require(transient)) == .start(epoch: 3))
        transient = nil
        #expect(transient == nil)
        #expect(relay.purge(level: .warning) == .stop(epoch: 4))
        relay.close()
        #expect(relay.isClosed)
        #expect(relay.add(first) == nil)
        #expect(relay.liveCount == 0)
    }

    @available(macOS 15.0, *)
    @MainActor
    @Test("R-STO-13: the mirror ignores an out-of-order snapshot and acknowledges what readers see")
    func mirrorAcknowledgesInstalledKey() throws {
        let time = ManualTimeSource()
        let mirror = SnapshotMirror(time: time)
        let blob = BlobKey(hash: ContentHash.sha256(of: Data([7])), ext: try #require(AssetFileExtension("png")))
        let layout = StoreLayout(base: URL(fileURLWithPath: "/virtual", isDirectory: true))
        let location = AssetLocation(id: "a", url: layout.blobURL(blob), fileExtension: blob.ext, byteSize: 1, integrity: .verified, isStale: false)
        let newer = AssetSnapshot(key: SnapshotKey(epoch: 2, version: 5), indexGeneration: 9, entries: ["a": SnapshotEntry(location: location, essential: false)])
        let older = AssetSnapshot(key: SnapshotKey(epoch: 2, version: 4), indexGeneration: 8, entries: [:])

        let first = mirror.install(newer)
        #expect(first.installed == newer.key)
        #expect(first.retired?.key == .zero)
        #expect(mirror.lookup("a", extensions: ["PNG"]) == location)
        #expect(mirror.lookup("b", extensions: []) == nil)
        let ack = mirror.install(older)
        #expect(ack.installed == newer.key)
        #expect(ack.retired == nil)
        #expect(ack.accesses == ["a": time.now()])
        #expect(mirror.install(older).accesses.isEmpty)
        #expect(mirror.hits == 1 && mirror.misses == 1)
        mirror.reset()
        #expect(mirror.installedKey == .zero)
        #expect(mirror.lookup("a", extensions: []) == nil)
    }
}
