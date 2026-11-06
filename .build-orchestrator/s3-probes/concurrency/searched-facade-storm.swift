import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Stage 3 concurrency probes at the facade (H-3, R-SYN-4, R-SYN-15, R-CAR-4): a seeded cancellation storm over
/// resolve callers, prefetch handles and event streams, then a shutdown mid-flight.
@Suite("S3 concurrency probes: facade storm")
struct S3FacadeStormProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-15: a seeded cancellation storm over resolve callers, prefetch handles and event streams, then a shutdown mid-flight, answers every caller once and leaves nothing owned",
        .timeLimit(.minutes(1)),
        arguments: [UInt64(0x51), 0x52, 0x53, 0x54, 0x55, 0x56]
    )
    func stormThenShutdown(seed: UInt64) async throws {
        let harness = KitHarness.make()
        let entries = (0..<6).map { index -> (ManifestEntry, Data) in
            let bytes = KitFixture.bytes(900 + UInt64(index))
            return (KitFixture.entry("s\(index)", bytes, policy: .onDemand), bytes)
        }
        await harness.serveManifest(entries.map(\.0))
        try await harness.startAndSettle()
        for (entry, bytes) in entries {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        let client = harness.client
        let engine = await harness.engine()
        var random = SplitMix64(seed: seed)
        var callers: [Task<Result<URL, AssetError>, Never>] = []
        for index in 0..<60 {
            let id = entries[Int(random.next() % 6)].0.identifier
            let priority: AssetPriority = index % 3 == 0 ? .prefetch : .userInitiated
            callers.append(Task {
                do throws(AssetError) {
                    return .success(try await client.resolve(id, priority: priority))
                } catch {
                    return .failure(error)
                }
            })
        }
        var handles: [PrefetchHandle] = []
        for _ in 0..<12 {
            let ids = [entries[Int(random.next() % 6)].0.identifier, entries[Int(random.next() % 6)].0.identifier]
            handles.append(client.prefetch(ids, priority: .prefetch))
        }
        var streams: [Task<Int, Never>] = []
        for _ in 0..<6 {
            streams.append(Task {
                var count = 0
                for await _ in client.events {
                    count += 1
                }
                return count
            })
        }
        // Wave 1: cancellations at once, racing the callers' registration.
        var cancelled = Set<Int>()
        for index in callers.indices where random.next() % 4 == 0 {
            callers[index].cancel()
            cancelled.insert(index)
        }
        for handle in handles where random.next() % 2 == 0 {
            handle.cancel()
        }
        for stream in streams where random.next() % 2 == 0 {
            stream.cancel()
        }
        let survivors = callers.count - cancelled.count
        await engine.waitUntil { $0.waiters == survivors }
        // Wave 2: cancellations after registration.
        for index in callers.indices where !cancelled.contains(index) && random.next() % 3 == 0 {
            callers[index].cancel()
            cancelled.insert(index)
        }
        let left = callers.count - cancelled.count
        await engine.waitUntil { $0.waiters == left }
        let before = await engine.introspect()
        #expect(before.running >= 1, "seed \(seed): transfers in flight before the shutdown: \(before)")
        await client.shutdown()
        for (index, caller) in callers.enumerated() {
            let result = await caller.value
            if cancelled.contains(index) {
                #expect(result == .failure(.cancelled) || result == .failure(.shutDown), "seed \(seed): cancelled caller \(index) got \(result)")
            } else {
                #expect(result == .failure(.shutDown), "seed \(seed): caller \(index) got \(result)")
            }
        }
        for stream in streams {
            _ = await stream.value
        }
        handles.removeAll()
        let state = await engine.introspect()
        #expect(state.lifecycle == .shutDown, "seed \(seed)")
        #expect(state.ownedTasks == 0 && state.waiters == 0 && state.interests == 0 && state.groups == 0, "seed \(seed): \(state)")
        #expect(state.subscribers == 0, "seed \(seed): every stream ended released its subscription: \(state.subscribers)")
        #expect(await harness.source.activeTransfers == 0, "seed \(seed): no transfer runs for nobody")
        #expect(await client.lifecycle.liveFollowers.isEmpty, "seed \(seed): no follower outlives its stream")
    }
}
