import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-ENV-1 and R-MAN-7 as source scans of `Sources/` (every production target, `ZTronAssetTestSupport` included).
    @Suite("Environment scans")
    struct EnvironmentScanTests {
        /// Calls that read a real clock, schedule on one, sleep, or draw unseeded randomness (R-ENV-1, C4). A pattern
        /// that starts with a name matches only where that name starts (`Date()` is not `lastUpdateDate()`).
        private static let realWorldCalls = [
            "Date()", "Date.now", "Date.init()", "Date(timeIntervalSinceNow", "Date.init(timeIntervalSinceNow", ": Date = .now",
            "NSDate()", "NSDate.now", "NSDate.date(", "DispatchTime.now(", "DispatchWallTime.now(", ": DispatchTime = .now(",
            "deadline: .now(", "wallDeadline: .now(", "asyncAfter(", "Timer.", "Timer(", "DispatchSource.makeTimerSource", "Task.sleep",
            "Thread.sleep", "usleep(", "nanosleep(", "SystemRandomNumberGenerator", "arc4random", "SecRandomCopyBytes", "UUID()",
            "NSUUID()", "uuid_generate", "CFAbsoluteTimeGetCurrent", "CACurrentMediaTime", "mach_absolute_time", "mach_continuous_time",
            "mach_approximate_time", "clock_gettime", "ContinuousClock", "SuspendingClock", "systemUptime",
        ]

        /// C library calls that read the wall clock or the C library's global generator, matched only as free calls
        /// (fix round 3): `time(nil)` is a call, `stopwatch.time(nil)` a method of another type.
        private static let freeCalls = [
            "gettimeofday(", "time(nil)", "time(NULL)", "drand48(", "erand48(", "lrand48(", "nrand48(", "mrand48(", "jrand48(",
            "random()", "srandom(", "rand()", "srand(",
        ]

        /// Methods that draw from `SystemRandomNumberGenerator` unless a generator is passed with `using:`.
        private static let systemRandomMethods = [".random(", ".randomElement(", ".shuffled(", ".shuffle("]

        @Test("R-ENV-1: no production source outside the live conformers calls Date(), DispatchTime.now(), Task.sleep or SystemRandomNumberGenerator")
        func realClocksOnlyInLiveConformers() throws {
            // The checker separates a live conformer from anything else, and sees code inside string interpolations.
            let sample = SourceScan.lex(path: "Sources/X/Y.swift", text: ##"""
                public struct LiveClock {
                    func now() -> Date { Date() }
                }
                struct Planner {
                    func stamp() -> Date { Date() }
                    func pick() -> Int { Int.random(in: 0..<3) }
                    func seeded(_ g: inout SplitMix64) -> Int { Int.random(in: 0..<3, using: &g) }
                    func note() { route.log(.sync, .info, "planned at \(Date())") }
                    func later() { queue.asyncAfter(deadline: .now() + 1) {} }
                    func tick() { _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in } }
                    func made() -> Date { Date.init() }
                    func inferred() -> Date { let d: Date = .now; return d }
                    func raw() { route.log(.sync, .info, #"at \#(Date())"#) }
                    func names() -> Int { lastUpdateDate() + makeUUID() + EngineTimer.count }
                    func nested() { route.log(.sync, .info, "a \("b \(Date())") c") }
                    func after() -> String { "\(count) then " + String(describing: Date.self) }
                }
                // Date() in a comment, and "Task.sleep" in a string, are not calls
                let text = "Task.sleep \\(Date()) escaped"
                let raw = #"\(Date()) is text in a raw string"#
                struct Clocks {
                    func wall() -> NSDate { NSDate() }
                    func continuous() -> UInt64 { mach_continuous_time() }
                    func approximate() -> UInt64 { mach_approximate_time() }
                    func day() { var tv = timeval(); gettimeofday(&tv, nil) }
                    func epoch() -> Int { time(nil) }
                    func media() -> Double { CACurrentMediaTime() }
                    func stopwatch(_ s: Stopwatch) -> Int { s.time(nil) + s.drand48(seed) }
                }
                struct Draws {
                    func one(_ ids: [Int]) -> Int? { ids.randomElement() }
                    func mixed(_ ids: [Int]) -> [Int] { ids.shuffled() }
                    func inPlace(_ ids: inout [Int]) { ids.shuffle() }
                    func seeded(_ ids: [Int], _ g: inout SplitMix64) -> Int? { ids.randomElement(using: &g) }
                    func seededMix(_ ids: [Int], _ g: inout SplitMix64) -> [Int] { ids.shuffled(using: &g) }
                    func secure(_ b: inout [UInt8]) { _ = SecRandomCopyBytes(kSecRandomDefault, 8, &b) }
                    func c() -> Double { drand48() + Double(random()) + Double(rand()) + Double(lrand48()) }
                    func id() -> NSUUID { NSUUID() }
                }
                """##)
            let sampleFindings = Self.findings(in: sample)
            #expect(sampleFindings.allowed.map(\.number) == [2])
            #expect(sampleFindings.forbidden.map(\.number) == [5, 6, 8, 9, 10, 11, 12, 13, 15, 22, 23, 24, 25, 26, 27, 31, 32, 33, 36, 37, 38])

            let lines = try SourceScan.lines()
            let findings = Self.findings(in: lines)
            #expect(findings.forbidden.isEmpty, "\(findings.forbidden.map { "\($0.path):\($0.number): \($0.text)" })")
            // The live conformers themselves were seen, so the scan is not passing vacuously.
            let liveTypes = Set(findings.allowed.compactMap { $0.enclosingTypes.last { Self.isLiveConformer($0) } })
            #expect(liveTypes.isSuperset(of: ["LiveTimeSource", "SystemRandomSource"]), "\(liveTypes)")
        }

        @Test("R-MAN-7: no Model source performs I/O through files, the network, user defaults or the bundle")
        func modelPerformsNoIO() throws {
            // The checker flags I/O in a function body even on the declaring line, and lets a bodiless requirement name
            // a type.
            let sample = SourceScan.lex(path: "Sources/X/Y.swift", text: """
                protocol Loader {
                    func session() -> URLSession
                    func load() -> Data? { try? Data(contentsOf: u) }
                }
                public func save() { try? data.write(to: url) }
                let defaults = UserDefaults.standard
                // FileManager.default in a comment is not a call
                """)
            #expect(Self.ioFindings(in: sample).map(\.line.number) == [3, 5, 6])

            let lines = try SourceScan.lines(under: "ZTronAssetModel")
            #expect(lines.count > 2_000)
            for finding in Self.ioFindings(in: lines) {
                Issue.record("\(finding.line.path):\(finding.line.number) uses \(finding.token)")
            }
        }

        /// File, network, defaults and bundle access (R-MAN-7). A protocol requirement (a `func` declaration with no body
        /// on its line) may name such a type; any line with code that runs may not.
        private static func ioFindings(in lines: [SourceScan.Line]) -> [(line: SourceScan.Line, token: String)] {
            let io = ["FileManager", "FileHandle", "URLSession", "UserDefaults", "Bundle.", "Data(contentsOf", "String(contentsOf",
                ".write(to", "fopen(", "NWPathMonitor", "NotificationCenter"]
            var found: [(line: SourceScan.Line, token: String)] = []
            for line in lines where !Self.isBodilessDeclaration(line.code) {
                for token in io where line.code.contains(token) {
                    found.append((line, token))
                }
            }
            return found
        }

        /// Whether `code` declares a function without a body on this line (a protocol requirement).
        private static func isBodilessDeclaration(_ code: String) -> Bool {
            let modifiers: Set<String> = ["public", "package", "internal", "private", "fileprivate", "static", "mutating", "nonisolated", "final", "override"]
            let words = code.split(whereSeparator: \.isWhitespace)
            guard let first = words.firstIndex(where: { !modifiers.contains(String($0)) && !$0.hasPrefix("@") }) else {
                return false
            }
            return words[first] == "func" && !code.contains("{")
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
                let unseededRandom = Self.systemRandomMethods.contains(where: line.code.contains) && !line.code.contains("using:")
                let realWorld = Self.realWorldCalls.contains { SourceScan.contains($0, in: line.code) }
                    || Self.freeCalls.contains { SourceScan.contains($0, in: line.code, standalone: true) }
                guard unseededRandom || realWorld else {
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
}
