import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync

extension EngineUnitTests {
    /// The heap a move's interests and a batch of owed re-routes wait in (`MinHeap`): seeded elements come out in
    /// ascending order, and a removal by predicate takes out exactly the matching elements and leaves the rest a heap
    /// that still yields them in ascending order; a predicate that matches nothing leaves the heap as it was.
    @Test("R-SYN-6: the heap of owed moves and re-routes yields its elements in order, and a removal by predicate keeps the rest in order", arguments: [UInt64(0x61), 0x62, 0x63])
    func minHeapYieldsInOrderAndRemovesByPredicate(seed: UInt64) {
        var generator = SeededShuffle(state: seed)
        let values = (0..<300).map { _ in Int(generator.next() % 120) }
        var drained: [Int] = []
        var heap = MinHeap(values)
        #expect(heap.count == values.count && heap.first == values.min())
        while let value = heap.popFirst() {
            drained.append(value)
        }
        #expect(drained == values.sorted(), "the heap drains sorted")
        #expect(heap.isEmpty && heap.first == nil)

        var kept = MinHeap(values)
        let untouched = kept.elements
        let none = kept.removeAll { $0 < 0 }
        #expect(none.isEmpty && kept.elements == untouched, "a predicate that matches nothing leaves the heap as it was")
        let removed = kept.removeAll { $0 % 3 == 0 }
        #expect(removed.sorted() == values.filter { $0 % 3 == 0 }.sorted(), "exactly the matching elements are taken out")
        #expect(kept.count == values.count - removed.count)
        var rest: [Int] = []
        while let value = kept.popFirst() {
            rest.append(value)
        }
        #expect(rest == values.filter { $0 % 3 != 0 }.sorted(), "the rest still drains sorted")
        var emptied = MinHeap(values)
        emptied.removeAll()
        #expect(emptied.isEmpty && emptied.popFirst() == nil)
    }
}
