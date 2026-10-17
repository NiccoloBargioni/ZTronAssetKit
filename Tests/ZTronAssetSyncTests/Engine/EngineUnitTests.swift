import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync

/// The engine's bounded internal structures (R-SYN-12 and H-9's bounds, sync.md §7.2, §8.4, §10.3).
@Suite("Engine units")
struct EngineUnitTests {
    static func transfer(_ n: Int) -> TransferID {
        TransferID.content(ContentHash.sha256(of: Data("unit-\(n)".utf8)))
    }

    @Test("R-SYN-12: a subscriber queue keeps one slot per key and subject and delivers in publication order")
    func subscriberQueueOrder() {
        var queue = SubscriberQueue()
        _ = queue.publish(.syncProgress(SyncRunID(rawValue: 1), SyncProgress(fraction: 0.1, completedCount: 1, totalCount: 10, bytesReceived: 1, bytesExpected: 10)), sequence: 1)
        _ = queue.publish(.assetAvailable("a", generation: 1), sequence: 2)
        let progress = queue.publish(.syncProgress(SyncRunID(rawValue: 1), SyncProgress(fraction: 0.5, completedCount: 5, totalCount: 10, bytesReceived: 5, bytesExpected: 10)), sequence: 3)
        #expect(progress.coalesced, "progress is replaced in place")
        let moved = queue.publish(.assetFailed("a", .offline, .whenOnline), sequence: 4)
        #expect(moved.coalesced, "a subject moves to its latest position")
        #expect(queue.liveCount == 2)
        guard case .syncProgress(_, let latest)? = queue.take() else {
            Issue.record("progress first: it kept its position")
            return
        }
        #expect(latest.completedCount == 5, "newest wins")
        #expect(queue.take() == .assetFailed("a", .offline, .whenOnline))
        #expect(queue.take() == nil)
    }

    @Test("R-SYN-12: clientShutDown finishes a queue and nothing is accepted after it")
    func subscriberQueueFinishes() {
        var queue = SubscriberQueue()
        _ = queue.publish(.snapshotChanged(generation: 3), sequence: 1)
        _ = queue.publish(.clientShutDown, sequence: 2)
        _ = queue.publish(.snapshotChanged(generation: 4), sequence: 3)
        #expect(queue.finished)
        #expect(queue.take() == .snapshotChanged(generation: 3))
        #expect(queue.take() == .clientShutDown)
        #expect(queue.take() == nil)
    }

    @Test("R-SYN-12: a subscriber queue's order stays within twice its live slots however many subjects move", arguments: [UInt64(1), 2, 3])
    func subscriberQueueBound(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        var queue = SubscriberQueue()
        var sequence: UInt64 = 0
        for _ in 0..<20_000 {
            sequence += 1
            let asset = AssetID("s\(random.next() % 64)")
            if random.next() % 5 == 0 {
                queue.retire(.transfer(asset))
                _ = queue.publish(.transferProgress(asset, TransferProgress(received: Int64(sequence), expected: nil)), sequence: sequence)
            } else {
                _ = queue.publish(.assetAvailable(asset, generation: sequence), sequence: sequence)
            }
            if random.next() % 7 == 0 {
                _ = queue.take()
            }
            #expect(queue.storedOrderCount <= 2 * queue.liveCount + 16, "seed \(seed)")
        }
        #expect(queue.liveCount <= 128, "seed \(seed): one slot per key and subject")
    }

    @Test("R-SYN-3: lane queues are FIFO with lazy deletion, put a resumed job first and stay within twice the live entries")
    func laneQueues() {
        var queues = LaneQueues()
        let now = MonotonicInstant(nanoseconds: 1)
        var live = Set<UInt64>()
        for ticket in UInt64(1)...6 {
            queues.push(LaneQueues.Entry(ticket: ticket, transfer: EngineUnitTests.transfer(Int(ticket)), queuedAt: now), to: .bulk)
            live.insert(ticket)
        }
        queues.push(LaneQueues.Entry(ticket: 7, transfer: EngineUnitTests.transfer(7), queuedAt: now), to: .bulk, front: true)
        live.insert(7)
        live.remove(2)
        let isValid: (LaneQueues.Entry) -> Bool = { live.contains($0.ticket) }
        #expect(queues.pop(.bulk, isValid: isValid)?.ticket == 7, "a front push is served first")
        #expect(queues.first(.bulk, isValid: isValid)?.ticket == 1)
        #expect(queues.pop(.bulk, isValid: isValid, accept: { $0.ticket != 1 })?.ticket == 3, "an entry the caller skips keeps its place")
        #expect(queues.pop(.bulk, isValid: isValid)?.ticket == 1)
        #expect(queues.pop(.prefetch, isValid: isValid) == nil)
        live = [5]
        queues.compact { live.contains($0.ticket) }
        #expect(queues.storedCount == 1)
        #expect(queues.pop(.bulk, isValid: { live.contains($0.ticket) })?.ticket == 5)
        // A long run of pops releases the consumed prefix.
        for ticket in UInt64(10)..<110 {
            queues.push(LaneQueues.Entry(ticket: ticket, transfer: EngineUnitTests.transfer(Int(ticket)), queuedAt: now), to: .prefetch)
        }
        for _ in 0..<90 {
            _ = queues.pop(.prefetch, isValid: { _ in true })
        }
        #expect(queues.storedCount <= 2 * 10 + 16)
    }

    @Test("R-SYN-14: the deadline heap fires in deadline then scheduling order and replaces an entry per reason")
    func deadlineHeap() {
        var heap = DeadlineHeap()
        let base = MonotonicInstant(nanoseconds: 1_000)
        heap.schedule(.store, at: base.adding(seconds: 5))
        heap.schedule(.pendingRun, at: base.adding(seconds: 1))
        heap.schedule(.heal("a"), at: base.adding(seconds: 1))
        heap.schedule(.store, at: base.adding(seconds: 2))
        #expect(heap.count == 3)
        #expect(heap.deadline(for: .store) == base.adding(seconds: 2))
        let due = heap.popDue(at: base.adding(seconds: 2))
        #expect(due.map(\.reason) == [.pendingRun, .heal("a"), .store])
        heap.schedule(.manifest(1), at: base)
        heap.schedule(.manifest(2), at: base)
        heap.removeAll { if case .manifest = $0 { return true } else { return false } }
        #expect(heap.first == nil)
    }

    @Test("R-CAR-2: the unknown-identifier cache expires and forgets the oldest beyond its capacity")
    func negativeCache() {
        var cache = NegativeCache()
        let now = MonotonicInstant(nanoseconds: 1_000)
        cache.insert("a", until: now.adding(seconds: 60), capacity: 2)
        cache.insert("b", until: now.adding(seconds: 60), capacity: 2)
        cache.insert("a", until: now.adding(seconds: 60), capacity: 2)
        cache.insert("c", until: now.adding(seconds: 60), capacity: 2)
        #expect(!cache.contains("b", at: now), "the oldest went")
        #expect(cache.contains("a", at: now) && cache.contains("c", at: now))
        #expect(!cache.contains("a", at: now.adding(seconds: 61)), "entries expire")
        cache.remove("a")
        #expect(!cache.contains("a", at: now))
    }

    @Test("R-SYN-16: the verification byte budget follows the time budget")
    func maintenanceBudget() {
        #expect(MaintenanceBudget.bytes(for: 1) == Int64(MaintenanceBudget.verificationBytesPerSecond))
        #expect(MaintenanceBudget.bytes(for: 0) == 1)
        #expect(MaintenanceBudget.bytes(for: -5) == 1)
        #expect(MaintenanceBudget.bytes(for: .nan) == 1)
        #expect(MaintenanceBudget.bytes(for: .infinity) == Int64.max)
        #expect(MaintenanceBudget.bytes(for: 1e30) == Int64.max)
    }

    @Test("R-SYN-12: every event maps to the slot it coalesces under")
    func eventSlots() {
        let run = SyncRunID(rawValue: 1)
        let report = MaintenanceReport(gcBytes: 0, evictedBytes: 0, verifiedBytes: 0, corruptFound: 0, budgetExhausted: false)
        let cases: [(AssetEvent, EventSlot)] = [
            (.snapshotChanged(generation: 1), .snapshot),
            (.conditionsChanged(.unrestricted), .conditions),
            (.syncProgress(run, SyncProgress(fraction: 0, completedCount: 0, totalCount: 0, bytesReceived: 0, bytesExpected: 0)), .run),
            (.transferProgress("a", TransferProgress(received: 0, expected: nil)), .transfer("a")),
            (.clientStarted(generation: 1), .client),
            (.syncStarted(run, .launch), .runStarted),
            (.syncFinished(run, .failed(.offline)), .runFinished),
            (.assetAvailable("a", generation: 1), .asset("a")),
            (.assetFailed("a", .offline, .nextRun), .asset("a")),
            (.assetRemoved("a", .pruned), .asset("a")),
            (.circuitChanged(originID: "o", .closed), .breaker("o")),
            (.maintenanceFinished(report), .maintenance),
            (.clientShutDown, .client),
        ]
        for (event, slot) in cases {
            #expect(EventSlot(event) == slot)
        }
        #expect(cases.filter { $0.1.isProgress }.count == 4)
    }
}
