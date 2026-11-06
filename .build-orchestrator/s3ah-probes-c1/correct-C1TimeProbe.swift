import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// Verifier probe (s3ah cycle 1, correctness lens): S3AH-3.
@Suite("C1 correct probe: S3AH-3 exact clock moves")
struct C1TimeProbe {
    @Test("C1: adding(seconds: b.seconds(since: a)) == b for 1,000,000 random gaps below 2^51 and random starts")
    func roundTrip() {
        var random = SplitMix64(seed: 0xC1C1_0003)
        var misses: [(UInt64, UInt64)] = []
        for _ in 0..<1_000_000 {
            let gap = UInt64.random(in: 0..<(1 << UInt64.random(in: 1...51, using: &random)), using: &random)
            let start = UInt64.random(in: 0..<(1 << 63), using: &random)
            let a = MonotonicInstant(nanoseconds: start)
            let b = MonotonicInstant(nanoseconds: start + gap)
            if a.adding(seconds: b.seconds(since: a)) != b {
                misses.append((start, gap))
            }
        }
        print("C1 S3AH-3: round-trip misses below 2^51: \(misses.count) \(misses.prefix(5))")
        #expect(misses.isEmpty)
    }

    @Test("C1: adding(seconds:) is monotone in its argument, saturates, and ignores NaN/negative/zero")
    func addingInvariants() {
        let near = MonotonicInstant(nanoseconds: UInt64.max - 5)
        #expect(near.adding(seconds: 1e-8) == MonotonicInstant(nanoseconds: UInt64.max))
        #expect(near.adding(seconds: 4e-9) == MonotonicInstant(nanoseconds: UInt64.max - 1))
        #expect(near.adding(seconds: .infinity) == MonotonicInstant(nanoseconds: UInt64.max))
        #expect(MonotonicInstant.zero.adding(seconds: 1.8e10) == MonotonicInstant(nanoseconds: UInt64.max))
        #expect(MonotonicInstant.zero.adding(seconds: 1.7e10) == MonotonicInstant(nanoseconds: 17_000_000_000_000_000_000))
        #expect(MonotonicInstant.zero.adding(seconds: .nan) == .zero)
        #expect(MonotonicInstant.zero.adding(seconds: -1) == .zero)
        #expect(MonotonicInstant.zero.adding(seconds: .leastNonzeroMagnitude) == .zero)
        #expect(MonotonicInstant.zero.adding(seconds: 0.5e-9) == MonotonicInstant(nanoseconds: 1))
        var random = SplitMix64(seed: 0xC1C1_0004)
        var violations = 0
        for _ in 0..<200_000 {
            let x = Double.random(in: 0..<1e6, using: &random)
            let y = x.nextUp
            if MonotonicInstant.zero.adding(seconds: x) > MonotonicInstant.zero.adding(seconds: y) {
                violations += 1
            }
        }
        #expect(violations == 0)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("C1: advance(to:) lands exactly from large starts, wakes the sleeper at the target, not the one 1 ns later", .timeLimit(.minutes(1)))
    func advanceToExact() async throws {
        var random = SplitMix64(seed: 0xC1C1_0005)
        for round in 0..<300 {
            try Task.checkCancellation()
            let startNs = UInt64.random(in: 1..<(1 << 63), using: &random)
            let time = ManualTimeSource(monotonic: MonotonicInstant(nanoseconds: startNs))
            let gap = UInt64.random(in: 1..<(UInt64.max - startNs), using: &random) >> UInt64.random(in: 0...60, using: &random)
            let target = MonotonicInstant(nanoseconds: startNs + max(gap, 1))
            let atTarget = Task { () -> Bool in
                do {
                    try await time.sleep(until: target)
                    return true
                } catch {
                    return false
                }
            }
            let later = Task { () -> Bool in
                do {
                    try await time.sleep(until: MonotonicInstant(nanoseconds: target.nanoseconds &+ 1))
                    return true
                } catch {
                    return false
                }
            }
            try await time.requireSleepers(atLeast: 2)
            time.advance(to: target)
            #expect(time.monotonicNow() == target, "round \(round)")
            #expect(time.uptimeNow() == target, "round \(round)")
            #expect(await atTarget.value, "round \(round)")
            #expect(time.pendingSleepers == 1, "round \(round)")
            later.cancel()
            #expect(await later.value == false, "round \(round)")
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("C1: racing advance(to:) and advance(by:) from many tasks against sleepers: each sleeper resumes once, all wake", .timeLimit(.minutes(1)))
    func racingAdvances() async throws {
        for round in 0..<40 {
            try Task.checkCancellation()
            let time = ManualTimeSource()
            let start = time.monotonicNow()
            var random = SplitMix64(seed: 0xC1C1_0100 &+ UInt64(round))
            let deadlines = (0..<64).map { _ in MonotonicInstant(nanoseconds: start.nanoseconds + UInt64.random(in: 1...1_000_000, using: &random)) }
            let sleepers = deadlines.map { deadline in
                Task { () -> Bool in
                    do {
                        try await time.sleep(until: deadline)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            let targets = (0..<8).map { _ in MonotonicInstant(nanoseconds: start.nanoseconds + UInt64.random(in: 1...1_000_000, using: &random)) }
            await withTaskGroup(of: Void.self) { group in
                for (index, target) in targets.enumerated() {
                    group.addTask {
                        if index.isMultiple(of: 3) {
                            time.advance(by: 1e-4)
                        } else {
                            time.advance(to: target)
                        }
                    }
                }
            }
            try await time.requireSleepers(atLeast: 0)
            // Every sleeper either woke already or wakes now; registration may still be in flight.
            let last = MonotonicInstant(nanoseconds: start.nanoseconds + 2_000_000)
            var woken = 0
            for sleeper in sleepers {
                time.advance(to: last)
                if await sleeper.value {
                    woken += 1
                }
                time.advance(to: last)
            }
            #expect(woken == 64, "round \(round)")
            #expect(time.pendingSleepers == 0)
            #expect(time.monotonicNow() >= last)
            #expect(Set(time.wakeLog).count == time.wakeLog.count)
        }
    }
}
