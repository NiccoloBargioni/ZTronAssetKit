import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import os

/// The R-OBS-1 interval seam (ARCHITECTURE §13.5 item 2): `LogRoute.interval(_:category:_:)` begins and ends a
/// signpost on the sink's signposter and reports both edges to the `LogTap`. No test here writes to the unified
/// log: the recording sink hands out `OSSignposter.disabled`.
@Suite("Log intervals")
struct LogIntervalTests {
    @available(macOS 15.0, *)
    @Test("R-OBS-1: an interval begins and ends on the sink's signposter and reaches the tap as began and ended events")
    func intervalReachesSignposterAndTap() {
        let sink = SignpostRecordingSink()
        let tap = RecordingLogTap()
        let route = LogRoute(sink: sink, tap: tap)
        for name in LogIntervalName.allCases {
            let interval = route.interval(name, category: .store, "generation 7")
            #expect(interval.isSignposted)
            #expect(interval.name == name && interval.category == .store && interval.message == "generation 7")
            interval.end()
        }
        #expect(sink.signposterRequests == Array(repeating: .store, count: LogIntervalName.allCases.count))
        #expect(sink.lines.isEmpty, "intervals are signposts, not lines, on the sink")
        let events = tap.lines.compactMap(LogIntervalEvent.init(line:))
        #expect(events.count == tap.lines.count)
        #expect(events == LogIntervalName.allCases.flatMap { name in
            [LogIntervalEvent.Phase.began, .ended].map {
                LogIntervalEvent(category: .store, name: name, phase: $0, message: "generation 7")
            }
        })
        #expect(events.allSatisfy { $0.subsystem == "com.ztron.assetkit" })
    }

    @available(macOS 15.0, *)
    @Test("R-OBS-1: an environment of fakes emits no signpost and its tap still sees both edges of an interval")
    func testSinkReportsIntervalsOnlyToTheTap() {
        let tap = RecordingLogTap()
        let route = LogRoute.tapOnly(tap)
        let interval = route.interval(.transfer, category: .transport, AssetLog.hashed("bo7.a"))
        #expect(!interval.isSignposted)
        interval.end()
        #expect(tap.lines.map(\.level) == [.debug, .debug])
        #expect(tap.lines.compactMap(LogIntervalEvent.init(line:)).map(\.phase) == [.began, .ended])
        #expect(tap.lines.first?.message == "interval transfer began: \(AssetLog.hashed("bo7.a"))")

        // No tap at all: the interval still begins and ends, silently.
        let silent = LogRoute.tapOnly(nil).interval(.gc, category: .store)
        #expect(!silent.isSignposted)
        silent.end()
    }

    @available(macOS 15.0, *)
    @Test("R-OBS-1: a tap that implements recordInterval receives structured events and no rendered lines")
    func structuredTapReceivesEvents() {
        let tap = StructuredTap()
        let interval = LogRoute.tapOnly(tap).interval(.eviction, category: .store)
        interval.end()
        #expect(tap.events == [
            LogIntervalEvent(category: .store, name: .eviction, phase: .began),
            LogIntervalEvent(category: .store, name: .eviction, phase: .ended),
        ])
        #expect(tap.lines.isEmpty)
    }

    @Test("R-OBS-1: interval events round-trip through their rendered line and no other line parses as one")
    func intervalLinesParse() {
        for name in LogIntervalName.allCases {
            for phase in LogIntervalEvent.Phase.allCases {
                for message in ["", "id#00ff00ff00ff00ff", "a: b: c"] {
                    let event = LogIntervalEvent(category: .apple, name: name, phase: phase, message: message)
                    #expect(LogIntervalEvent(line: event.line) == event)
                    #expect(event.line.level == .debug && event.line.category == .apple)
                }
            }
        }
        let notIntervals = [
            LogLine(category: .store, level: .debug, message: "reaped 3"),
            LogLine(category: .store, level: .info, message: "interval commit began"),
            LogLine(category: .store, level: .debug, message: "interval commit"),
            LogLine(category: .store, level: .debug, message: "interval commit paused"),
            LogLine(category: .store, level: .debug, message: "interval upload began"),
            LogLine(category: .store, level: .debug, message: "interval commit began; x"),
            LogLine(category: .store, level: .debug, message: "interval commit began extra"),
            LogLine(category: .store, level: .debug, message: "interval commit began:no space"),
        ]
        for line in notIntervals {
            #expect(LogIntervalEvent(line: line) == nil, "\(line.message)")
        }
    }
}

/// A sink that records the lines written to it and every signposter request, handing out the disabled signposter
/// so nothing reaches the unified log. Gated for `Mutex` (ADR-014).
@available(macOS 15.0, *)
private final class SignpostRecordingSink: LogSink {
    private let recorded = Mutex<(lines: [LogLine], requests: [LogCategory])>(([], []))

    func write(_ line: LogLine) {
        self.recorded.withLock { $0.lines.append(line) }
    }

    func signposter(_ category: LogCategory) -> OSSignposter? {
        self.recorded.withLock { $0.requests.append(category) }
        return OSSignposter.disabled
    }

    var lines: [LogLine] {
        self.recorded.withLock { $0.lines }
    }

    var signposterRequests: [LogCategory] {
        self.recorded.withLock { $0.requests }
    }
}

/// A tap that takes interval events as values. Gated for `Mutex` (ADR-014).
@available(macOS 15.0, *)
private final class StructuredTap: LogTap {
    private let recorded = Mutex<(lines: [LogLine], events: [LogIntervalEvent])>(([], []))

    func record(_ line: LogLine) {
        self.recorded.withLock { $0.lines.append(line) }
    }

    func recordInterval(_ event: LogIntervalEvent) {
        self.recorded.withLock { $0.events.append(event) }
    }

    var lines: [LogLine] {
        self.recorded.withLock { $0.lines }
    }

    var events: [LogIntervalEvent] {
        self.recorded.withLock { $0.events }
    }
}
