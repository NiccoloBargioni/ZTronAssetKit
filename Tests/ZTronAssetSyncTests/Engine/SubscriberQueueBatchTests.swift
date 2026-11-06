import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync

/// A subscriber queue's one-hash terminal publish and its batch path (Stage 3 close-out cycle 22, ruling S3-R27 item 1,
/// a1 and a3; d1 §3's T-A-1 and T-A-2).
extension EngineUnitTests {
    /// T-A-1: a fresh terminal subject is not reported as coalesced, a live one moves to the tail and is, and the live
    /// count and its peak count subjects, not publications.
    @Test("R-SYN-12: a terminal publish reports whether it moved a live slot, and the moved slot goes to the tail (S3-R27 item 1, a1)")
    func terminalPublishReportsAMoveAndMovesToTheTail() {
        var queue = SubscriberQueue()
        let first = queue.publish(.assetAvailable("a", generation: 1), sequence: 1)
        let second = queue.publish(.assetAvailable("b", generation: 1), sequence: 2)
        let third = queue.publish(.assetFailed("a", .notFound, .nextRun), sequence: 3)
        #expect(!first.coalesced && !second.coalesced, "a fresh subject replaces nothing: \(first.coalesced), \(second.coalesced)")
        #expect(third.coalesced, "a live subject's publish moves it")
        #expect(queue.liveCount == 2 && queue.peakLiveCount == 2, "two subjects: live \(queue.liveCount), peak \(queue.peakLiveCount)")
        #expect(queue.take() == .assetAvailable("b", generation: 1), "b first: a moved behind it")
        #expect(queue.take() == .assetFailed("a", .notFound, .nextRun), "then a's latest event")
        #expect(queue.take() == nil)
    }

    /// One event of a seeded mix: terminal events of 24 subjects, their transfers' progress, two runs' progress and the
    /// snapshot, so that batches replace progress in place, move terminal slots and insert new ones.
    static func mixedEvent(_ random: inout SplitMix64, sequence: UInt64) -> AssetEvent {
        let asset = AssetID("s\(random.next() % 24)")
        switch random.next() % 6 {
        case 0:
            return .assetAvailable(asset, generation: sequence)
        case 1:
            return .assetFailed(asset, .notFound, .nextRun)
        case 2:
            return .assetRemoved(asset, .pruned)
        case 3:
            return .transferProgress(asset, TransferProgress(received: Int64(sequence), expected: nil))
        case 4:
            let run = SyncRunID(rawValue: 1 + random.next() % 2)
            return .syncProgress(run, SyncProgress(fraction: 0.5, completedCount: Int(sequence % 7), totalCount: 7, bytesReceived: 1, bytesExpected: 2))
        default:
            return .snapshotChanged(generation: sequence)
        }
    }

    /// What one way of publishing a batch into an empty queue with a pull waiting left: the event the pull received,
    /// whether the publication handed one off, the moves it reported, and the queue.
    struct WaitingPull {
        var received: AssetEvent?
        var handedOff = false
        var coalesced = 0
        var queue = SubscriberQueue()
    }

    /// Publishes `events` into an empty queue whose pull waits, inside that pull's `withCheckedContinuation`, through
    /// `publishAll` or through one `publish` per event, and resumes the pull with what the publication handed off. A
    /// publication that hands nothing off leaves the pull to be resumed with `nil` here, so nothing leaks or hangs.
    static func publishToAWaitingPull(_ events: [AssetEvent], batched: Bool) async -> WaitingPull {
        var outcome = WaitingPull()
        let received = await withCheckedContinuation { (pull: CheckedContinuation<AssetEvent?, Never>) in
            outcome.queue.pending = pull
            if batched {
                let published = outcome.queue.publishAll(events, from: 1)
                outcome.coalesced = published.coalesced
                if let handOff = published.handOff {
                    outcome.handedOff = true
                    handOff.continuation.resume(returning: handOff.event)
                }
            } else {
                var handOff: (continuation: CheckedContinuation<AssetEvent?, Never>, event: AssetEvent)?
                for (offset, event) in events.enumerated() {
                    let published = outcome.queue.publish(event, sequence: UInt64(offset + 1))
                    outcome.coalesced += published.coalesced ? 1 : 0
                    if let continuation = published.handOff {
                        handOff = (continuation, event)
                    }
                }
                if let handOff {
                    outcome.handedOff = true
                    handOff.continuation.resume(returning: handOff.event)
                }
            }
            if !outcome.handedOff {
                pull.resume(returning: nil)
            }
        }
        outcome.received = received
        return outcome
    }

    /// T-A-2: seeded batches of the mix, with retires and takes between them, leave a queue fed through `publishAll` as
    /// one `publish` per event leaves another: the same takes, live and peak counts, stored order and moves, and no
    /// hand-off with no pull waiting. Into an empty queue whose pull waits, both hand off the batch's first event only
    /// and keep the rest, asserted on the pull itself.
    @Test("R-SYN-12: publishAll leaves a subscriber queue as one publish per event does, and hands a waiting pull the first event only (S3-R27 item 1, a3)", arguments: [UInt64(1), 2, 3])
    func publishAllMatchesOnePublishPerEvent(seed: UInt64) async {
        var random = SplitMix64(seed: seed)
        var batched = SubscriberQueue()
        var single = SubscriberQueue()
        var sequence: UInt64 = 0
        var mismatches: [String] = []
        for step in 0..<3_000 {
            let events = (0..<(1 + random.next() % 12)).map { offset in Self.mixedEvent(&random, sequence: sequence + offset + 1) }
            let published = batched.publishAll(events, from: sequence + 1)
            var coalesced = 0
            var handedOff = false
            for event in events {
                sequence += 1
                let one = single.publish(event, sequence: sequence)
                coalesced += one.coalesced ? 1 : 0
                handedOff = handedOff || one.handOff != nil
            }
            if published.handOff != nil || handedOff || published.coalesced != coalesced {
                mismatches.append("step \(step): batch moves \(published.coalesced), one by one \(coalesced); hand-offs \(published.handOff != nil), \(handedOff)")
            }
            if random.next() % 5 == 0 {
                let slot = EventSlot.transfer(AssetID("s\(random.next() % 24)"))
                batched.retire(slot)
                single.retire(slot)
            }
            for _ in 0..<(random.next() % 9) {
                let taken = (batched.take(), single.take())
                if taken.0 != taken.1 {
                    mismatches.append("step \(step): took \(String(describing: taken.0)) against \(String(describing: taken.1))")
                }
            }
            if (batched.liveCount, batched.peakLiveCount, batched.storedOrderCount) != (single.liveCount, single.peakLiveCount, single.storedOrderCount) {
                mismatches.append("step \(step): live \(batched.liveCount)/\(single.liveCount), peak \(batched.peakLiveCount)/\(single.peakLiveCount), stored \(batched.storedOrderCount)/\(single.storedOrderCount)")
            }
        }
        while let event = single.take() {
            let taken = batched.take()
            if taken != event {
                mismatches.append("drain: took \(String(describing: taken)) against \(event)")
            }
        }
        #expect(batched.take() == nil && batched.isEmpty, "seed \(seed): the batched queue drains with the other")
        #expect(mismatches.isEmpty, "seed \(seed): \(mismatches.count) mismatches, first \(mismatches.prefix(3))")
        let events = (0..<12).map { offset in Self.mixedEvent(&random, sequence: sequence + UInt64(offset) + 1) }
        let viaBatch = await Self.publishToAWaitingPull(events, batched: true)
        let viaSingle = await Self.publishToAWaitingPull(events, batched: false)
        #expect(viaBatch.handedOff && viaBatch.received == events.first, "seed \(seed): publishAll hands the waiting pull the first event: \(String(describing: viaBatch.received))")
        #expect(viaSingle.handedOff && viaSingle.received == events.first, "seed \(seed): so does one publish per event: \(String(describing: viaSingle.received))")
        #expect(viaBatch.coalesced == viaSingle.coalesced, "seed \(seed): moves \(viaBatch.coalesced) and \(viaSingle.coalesced)")
        var afterBatch = viaBatch.queue
        var afterSingle = viaSingle.queue
        #expect(afterBatch.pending == nil && afterSingle.pending == nil, "seed \(seed): the hand-off ends the wait")
        #expect((afterBatch.liveCount, afterBatch.peakLiveCount, afterBatch.storedOrderCount) == (afterSingle.liveCount, afterSingle.peakLiveCount, afterSingle.storedOrderCount), "seed \(seed): the rest is kept alike")
        var rest: [AssetEvent] = []
        while let event = afterSingle.take() {
            rest.append(event)
            #expect(afterBatch.take() == event, "seed \(seed): the rest is taken alike")
        }
        #expect(afterBatch.take() == nil && !rest.isEmpty, "seed \(seed): the queue keeps the batch's other events: \(rest.count)")
    }
}
