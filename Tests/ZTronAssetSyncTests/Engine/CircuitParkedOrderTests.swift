import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync

extension EngineUnitTests {
    /// The breaker's parked order (`CircuitParkedOrder`, S3-B-063) is a min-heap by (rank, ticket, transfer): seeded
    /// inserts and removals of the smallest entry always remove the smallest one left, and a rebuild from an arbitrary
    /// array yields the same order as inserting it entry by entry.
    @Test("R-SYN-5: the breaker's parked order always yields its smallest entry by rank, then ticket", arguments: [UInt64(0x51), 0x52, 0x53])
    func circuitParkedOrderIsAMinHeap(seed: UInt64) {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        var order = CircuitParkedOrder()
        var model: [CircuitParkedOrder.Entry] = []
        for index in 0..<400 {
            if next() % 3 == 0, !model.isEmpty {
                let smallest = model.min()
                #expect(order.removeFirst() == smallest, "operation \(index)")
                model.removeAll { $0 == smallest }
            } else {
                let entry = CircuitParkedOrder.Entry(
                    rank: Int(next() % 4),
                    ticket: next() % 50,
                    transfer: EngineFixture.entry("order-\(index)", EngineFixture.bytes(UInt64(index), count: 8), policy: .onDemand).transferID
                )
                order.insert(entry)
                model.append(entry)
            }
            #expect(order.count == model.count)
            #expect(order.first == model.min())
        }
        var rebuilt = CircuitParkedOrder()
        var generator = SeededShuffle(state: seed)
        rebuilt.rebuild(model.shuffled(using: &generator))
        var drained: [CircuitParkedOrder.Entry] = []
        while let entry = rebuilt.removeFirst() {
            drained.append(entry)
        }
        #expect(drained == model.sorted(), "a rebuilt order drains sorted")
        order.removeAll()
        #expect(order.first == nil && order.count == 0)
    }
}

/// A deterministic generator for `shuffled(using:)`.
struct SeededShuffle: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        self.state = self.state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return self.state
    }
}
