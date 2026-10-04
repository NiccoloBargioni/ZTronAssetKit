import Foundation
import Testing
import ZTronAssetModel

/// R-ENV-1 and R-MAN-7 as source scans of `Sources/` (every production target, `ZTronAssetTestSupport` included).
@Suite("Environment scans")
struct EnvironmentScanTests {
    /// Calls that read a real clock, sleep, or draw unseeded randomness (R-ENV-1, C4). `.random(` counts only
    /// without `using:`, which draws from the system generator.
    private static let realWorldCalls = [
        "Date()", "Date.now", "Date(timeIntervalSinceNow", "DispatchTime.now(", "DispatchWallTime.now(", "Task.sleep",
        "Thread.sleep", "usleep(", "nanosleep(", "SystemRandomNumberGenerator", "arc4random", "UUID()",
        "CFAbsoluteTimeGetCurrent", "mach_absolute_time", "clock_gettime", "ContinuousClock", "SuspendingClock",
        "systemUptime",
    ]

    @Test("R-ENV-1: no production source outside the live conformers calls Date(), DispatchTime.now(), Task.sleep or SystemRandomNumberGenerator")
    func realClocksOnlyInLiveConformers() throws {
        // The checker separates a live conformer from anything else.
        let sample = SourceScan.lex(path: "Sources/X/Y.swift", text: """
            public struct LiveClock {
                func now() -> Date { Date() }
            }
            struct Planner {
                func stamp() -> Date { Date() }
                func pick() -> Int { Int.random(in: 0..<3) }
                func seeded(_ g: inout SplitMix64) -> Int { Int.random(in: 0..<3, using: &g) }
            }
            // Date() in a comment, and "Task.sleep" in a string, are not calls
            let text = "Task.sleep"
            """)
        let sampleFindings = Self.findings(in: sample)
        #expect(sampleFindings.allowed.map(\.number) == [2])
        #expect(sampleFindings.forbidden.map(\.number) == [5, 6])

        let lines = try SourceScan.lines()
        let findings = Self.findings(in: lines)
        #expect(findings.forbidden.isEmpty, "\(findings.forbidden.map { "\($0.path):\($0.number): \($0.text)" })")
        // The live conformers themselves were seen, so the scan is not passing vacuously.
        let liveTypes = Set(findings.allowed.compactMap { $0.enclosingTypes.last { Self.isLiveConformer($0) } })
        #expect(liveTypes.isSuperset(of: ["LiveTimeSource", "SystemRandomSource"]), "\(liveTypes)")
    }

    @Test("R-MAN-7: no Model source performs I/O through files, the network, user defaults or the bundle")
    func modelPerformsNoIO() throws {
        let io = ["FileManager", "FileHandle", "URLSession", "UserDefaults", "Bundle.", "Data(contentsOf", "String(contentsOf",
            ".write(to", "fopen(", "NWPathMonitor", "NotificationCenter"]
        let lines = try SourceScan.lines(under: "ZTronAssetModel")
        #expect(lines.count > 2_000)
        for line in lines {
            for token in io where line.code.contains(token) && !line.code.contains("func ") {
                Issue.record("\(line.path):\(line.number) uses \(token)")
            }
        }
    }

    /// A live conformer is a type whose name starts with `Live` or `System` (`LiveTimeSource`,
    /// `SystemRandomSource`, `LiveLoopbackDelay`, …): the only code that may touch the real world (ADR-038).
    private static func isLiveConformer(_ type: String) -> Bool {
        type.hasPrefix("Live") || type.hasPrefix("System")
    }

    private static func findings(in lines: [SourceScan.Line]) -> (allowed: [SourceScan.Line], forbidden: [SourceScan.Line]) {
        var allowed: [SourceScan.Line] = []
        var forbidden: [SourceScan.Line] = []
        for line in lines {
            let unseededRandom = line.code.contains(".random(") && !line.code.contains("using:")
            guard unseededRandom || Self.realWorldCalls.contains(where: line.code.contains) else {
                continue
            }
            if line.enclosingTypes.contains(where: Self.isLiveConformer) {
                allowed.append(line)
            } else {
                forbidden.append(line)
            }
        }
        return (allowed, forbidden)
    }
}
