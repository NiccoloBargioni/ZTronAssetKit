import Foundation
import Synchronization
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The facade's reopen limit (`AssetClient.reopenAttempts`; Stage 3 ruling S3G-3, S3-B-096): one call reopens at most
/// that many times, so a root that vanishes again and again is reported instead of looping. The seam is the store's
/// file system (`AssetEnvironment.fileSystem`, ADR-038): `VanishingRootVolume` replaces the root at every root check
/// while armed, which is what an OS purge of Caches between each replacement's open and its next commit looks like.
@Suite("Facade reopen limit")
struct FacadeReopenLimitTests {
    /// A client over a vanishing volume, started and settled while the volume is disarmed.
    @available(macOS 15.0, iOS 18.0, *)
    static func started() async throws -> (harness: KitHarness, volume: VanishingRootVolume) {
        let time = ManualTimeSource()
        let fake = FakeFileSystem(time: time)
        let volume = VanishingRootVolume(fake)
        let harness = KitHarness.make(fileSystem: fake, time: time, volume: { _ in volume })
        try await harness.startAndSettle()
        return (harness, volume)
    }

    /// `purge(.all)` through the client while the clock is driven.
    @available(macOS 15.0, iOS 18.0, *)
    static func purge(_ harness: KitHarness) async -> Result<PurgeResult, AssetError> {
        let client = harness.client
        do throws(AssetError) {
            return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                try await client.purge(.all)
            })
        } catch {
            return .failure(error)
        }
    }

    /// A call whose every attempt meets a replaced root (the commit's root check finds the lock gone) is repeated on a
    /// replacement after each of the first `reopenAttempts` failures, and the last attempt's failure is then reported as
    /// given, with no further reopen. The limit is per call: once the root stays, the next call reopens and succeeds.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-9: a call whose root vanishes at every root check reopens reopenAttempts times, then reports the replaced root", .timeLimit(.minutes(1)))
    func reopenLimitReportsTheFailure() async throws {
        let (harness, volume) = try await FacadeReopenLimitTests.started()
        let client = harness.client
        volume.arm()
        let result = await FacadeReopenLimitTests.purge(harness)
        let vanished = volume.disarm()
        #expect(result.failedWith == .storageUnavailable(.rootVanished), "the last attempt's failure, as given: \(result)")
        let limited = await client.lifecycle.current()
        #expect(limited.generation == 3, "one reopen per repeated attempt, three (`AssetClient.reopenAttempts`) and no more: generation \(limited.generation)")
        #expect(vanished >= 4, "every attempt, the first and the three repeated ones, met a replaced root: \(vanished) roots replaced")
        #expect(await limited.store.unavailableReason == .rootVanished, "the last pair's store knows its root was replaced")
        let next = await FacadeReopenLimitTests.purge(harness)
        #expect((try? next.get()) != nil, "the next call reopens once more and succeeds on a root that stays: \(next)")
        #expect(await client.lifecycle.current().generation == limited.generation + 1)
        await client.shutdown()
    }

    /// `withAsset` asks the store before each attempt, because a lease is a read, which a replaced root still grants: a
    /// pair whose store already knows its root was replaced is reopened before the lease. Here every pair knows it before
    /// the next attempt: the first through its own root check, and each replacement because the lifecycle's seam (G-10)
    /// starts it and checks its root before the reopen goes on, as when its root is purged right after it opened and a
    /// commit noticed. The call then stops after `reopenAttempts` (3) reopens and reports the replaced root rather than
    /// lease under it: no lease is taken and the body never runs.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-9: withAsset whose every pair knows its root was replaced reopens three times, then throws without leasing", .timeLimit(.minutes(1)))
    func withAssetReopenLimitThrows() async throws {
        let (harness, volume) = try await FacadeReopenLimitTests.started()
        let client = harness.client
        let built = Mutex<ClientCore?>(nil)
        await client.lifecycle.setSeam { point in
            switch point {
            case .replacementBuilt(let core):
                built.withLock { $0 = core }
            case .replacementObservesPressure:
                guard let core = built.withLock({ $0 }) else {
                    return
                }
                _ = await core.engine.start()
                _ = await core.store.verifyRootNow()
            default:
                return
            }
        }
        volume.arm()
        let first = await client.lifecycle.current()
        #expect(await first.store.verifyRootNow() == .rootVanished, "setup: the first pair's store knows its root was replaced")
        let ran = Mutex(false)
        let result: Result<Bool, any Error>
        do {
            result = .success(try await harness.withClock { () async throws -> Bool in
                try await client.withAsset("a") { _ in
                    ran.withLock { $0 = true }
                    return true
                }
            })
        } catch {
            result = .failure(error)
        }
        let vanished = volume.disarm()
        #expect((result.failedWith as? AssetError) == .storageUnavailable(.rootVanished), "the replaced root, reported: \(result)")
        #expect(!ran.withLock { $0 }, "the body never ran under a replaced root")
        let limited = await client.lifecycle.current()
        #expect(limited.generation == 3, "three reopens and no more: generation \(limited.generation)")
        #expect(vanished == 4, "the first root and each replacement's, replaced once: \(vanished)")
        for core in built.withLock({ $0 }).map({ [first, $0] }) ?? [first] {
            #expect(await core.store.kitLeaseCount() == 0, "no lease was taken under a replaced root (generation \(core.generation))")
        }
        await client.shutdown()
    }
}

extension Result {
    /// The failure, or `nil`.
    var failedWith: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}

/// A volume over `FakeFileSystem` whose store root vanishes at every root check while armed (Stage 3 ruling S3G-3): an
/// `itemInfo` of a `store.lock` first moves the directory holding it aside, in one operation of the fake volume (as
/// `KitHarness.vanishRoot()` does), so the check finds no lock. Only the root checks (`StoreLock.verifyRoot`, from a
/// commit or from `AssetStore.verifyRootNow()`) stat the lock file. Every other call goes to the fake volume unchanged.
@available(macOS 15.0, iOS 18.0, *)
final class VanishingRootVolume: FileSystem {
    private struct State {
        var armed = false
        var vanished = 0
    }

    let volume: FakeFileSystem
    private let state = Mutex(State())

    init(_ volume: FakeFileSystem) {
        self.volume = volume
    }

    /// From now on every root check finds its root replaced.
    func arm() {
        self.state.withLock { $0.armed = true }
    }

    /// Roots stay from now on; returns how many were replaced while armed.
    @discardableResult
    func disarm() -> Int {
        self.state.withLock { state in
            state.armed = false
            return state.vanished
        }
    }

    /// Moves the root holding `lock` aside when it exists (a root already gone is left as it is).
    private func vanishRoot(of lock: URL) throws(FileSystemError) {
        let root = lock.deletingLastPathComponent()
        guard try self.volume.itemInfo(at: root) != nil else {
            return
        }
        var index = 0
        var aside: URL
        repeat {
            index += 1
            aside = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-vanished-\(index)", isDirectory: true)
        } while try self.volume.itemInfo(at: aside) != nil
        try self.volume.rename(from: root, to: aside, mode: .exclusive)
        self.state.withLock { $0.vanished += 1 }
    }

    func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL {
        try self.volume.standardDirectory(directory)
    }

    func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo? {
        if url.lastPathComponent == "store.lock", self.state.withLock({ $0.armed }) {
            try self.vanishRoot(of: url)
        }
        return try self.volume.itemInfo(at: url)
    }

    func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo] {
        try self.volume.contentsOfDirectory(at: url)
    }

    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data {
        try self.volume.read(from: url, offset: offset, maxLength: maxLength)
    }

    func availableCapacity(at url: URL, for purpose: CapacityPurpose) throws(FileSystemError) -> Int64 {
        try self.volume.availableCapacity(at: url, for: purpose)
    }

    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes {
        try self.volume.storeAttributes(at: url)
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        try self.volume.createDirectory(at: url)
    }

    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError) {
        try self.volume.write(data, to: url, mode: mode)
    }

    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.volume.synchronizeFile(at: url, level: level)
    }

    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError) {
        try self.volume.synchronizeDirectory(at: url, level: level)
    }

    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError) {
        try self.volume.rename(from: source, to: destination, mode: mode)
    }

    func removeItem(at url: URL) throws(FileSystemError) {
        try self.volume.removeItem(at: url)
    }

    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError) {
        try self.volume.applyStoreAttributes(attributes, at: url)
    }

    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> FileLockToken {
        try self.volume.acquireExclusiveLock(at: url)
    }

    func releaseLock(_ token: FileLockToken) {
        self.volume.releaseLock(token)
    }
}
