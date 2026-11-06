import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// S1, the long-purge log line (Stage 3 close-out cycle 23, the owner's close ruling S3-R28 point 5): a purge's first
/// turn that holds the engine's actor longer than C2's 10 ms writes one `.info` line on `.sync`, so an app that adopts
/// the kit can count, through its own `LogSink` or `OSLogStore`, how often the purge's known misses of the limit happen
/// in the field. The turn is the interval the purge benchmarks record (`EngineState.commitTurnMarksForTests`); the
/// tests lengthen it on the injected clock (`ManualTimeSource`) through that seam, so nothing waits on the wall clock.
@Suite("Engine long purge turn log (S3-R28 point 5)")
struct EngineLongPurgeTurnLogTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-1: a purge's first turn longer than C2's 10 ms writes one info line on sync with its milliseconds and its job and group counts", .timeLimit(.minutes(1)))
    func purgeTurnPastTheLimitIsLogged() async throws {
        let lines = try await Self.purgeLines(turnSeconds: 0.011)
        #expect(lines == [LogLine(category: .sync, level: .info, message: "long purge turn: 11.00 ms, 3 jobs, 2 groups")], "\(lines)")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-1: a purge's first turn of exactly C2's 10 ms writes no long-turn line", .timeLimit(.minutes(1)))
    func purgeTurnAtTheLimitIsNotLogged() async throws {
        let lines = try await Self.purgeLines(turnSeconds: 0.010)
        #expect(lines.isEmpty, "\(lines)")
    }

    /// Purges three held prefetch jobs under two groups while the purge's first turn moves the engine's clock by
    /// `turnSeconds` at its end mark, and returns the lines the purge wrote whose text is S1's.
    @available(macOS 15.0, iOS 18.0, *)
    private static func purgeLines(turnSeconds: TimeInterval) async throws -> [LogLine] {
        let harness = EngineHarness.make()
        let entries = (0..<3).map { EngineHarness.onDemand("lp\($0)", EngineFixture.bytes(UInt64(2_100 + $0))) }
        await harness.serveManifest(entries)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        for entry in entries {
            await harness.source.script(entry.transferID, [.hold])
        }
        let ids = entries.map(\.identifier)
        _ = try await engine.registerGroup(ids, lane: .prefetch).get()
        _ = try await engine.registerGroup([ids[0]], lane: .prefetch).get()
        await engine.waitUntil { $0.running == entries.count }
        for entry in entries {
            await engine.waitForHandle(entry.transferID)
        }
        let before = await engine.readForTests { ($0.state.jobs.count, $0.state.groups.count) }
        try #require(before == (3, 2), "setup: three jobs under two groups: \(before)")
        // The seam is told `true` at the turn's end mark, the point the line's second clock read follows: the clock moves
        // there once, so the turn lasts exactly `turnSeconds` on the engine's clock.
        let mark = TurnEndAdvance(time: harness.time, seconds: turnSeconds)
        await engine.readForTests { $0.state.commitTurnMarksForTests = { ended in mark.marked(ended) } }
        let purged = await engine.purge(.scope(.identifiers(Set(ids))))
        await engine.readForTests { $0.state.commitTurnMarksForTests = nil }
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        #expect(mark.endMarks == 1, "the purge's end mark was the only one while the seam was set: \(mark.endMarks)")
        await engine.shutdown()
        return harness.tap.lines.filter { $0.message.hasPrefix("long purge turn") }
    }
}

/// Moves a manual clock by a fixed amount at the first end mark it is told of (`EngineState.commitTurnMarksForTests`):
/// a purge's first turn then lasts that long on the engine's clock, with no wall-clock wait.
@available(macOS 15.0, iOS 18.0, *)
private final class TurnEndAdvance: Sendable {
    private let time: ManualTimeSource
    private let seconds: TimeInterval
    private let count = Mutex(0)

    /// A mark that moves `time` by `seconds` once.
    init(time: ManualTimeSource, seconds: TimeInterval) {
        self.time = time
        self.seconds = seconds
    }

    /// Moves the clock at the first end mark (`ended == true`); a later mark of another turn moves nothing.
    func marked(_ ended: Bool) {
        guard ended else {
            return
        }
        let first = self.count.withLock { count in
            count += 1
            return count == 1
        }
        if first {
            self.time.advance(by: self.seconds)
        }
    }

    /// How many end marks it was told of; only the first moved the clock.
    var endMarks: Int {
        self.count.withLock { $0 }
    }
}
