import Foundation
import Testing
import ZTronAssetModel

/// R-OBS-1 as a property of every call site in `Sources/` (the package's own code, `ZTronAssetTestSupport`
/// included): one subsystem, the four categories, identifiers hashed, and the six signpost intervals wrapped by
/// their owners. Each checker is first shown to flag a known-bad snippet, so a scan that finds nothing to report
/// is not passing vacuously.
@Suite("Log call sites")
struct LogScanTests {
    /// The only file that may construct a logger or signposter (ADR-043, ADR-047).
    private static let logFile = "Sources/ZTronAssetModel/Environment/AssetLog.swift"

    @Test("R-OBS-1: every log line uses subsystem com.ztron.assetkit and one of the four categories with identifiers hashed")
    func logCallSitesFollowTheRules() throws {
        // The checker flags each kind of violation, and nothing in a compliant snippet.
        let bad = SourceScan.lex(path: "Sources/X/Bad.swift", text: """
            let logger = Logger(subsystem: "com.example", category: "misc")
            print("starting")
            NSLog("x")
            os_log("y")
            let line = LogLine(subsystem: "other", category: .store, level: .info, message: "m")
            let category = LogCategory(rawValue: text)
            route.log(.store, .info, "evicted \\(id.rawValue)")
            route.log(.sync, .error,
                "failed \\(entry.identifier) at \\(remotePath)")
            let span = route.interval(.transfer, category: .transport, "from \\(url)")
            """)
        #expect(Self.violations(in: bad).count == 10, "\(Self.violations(in: bad))")
        let good = SourceScan.lex(path: "Sources/X/Good.swift", text: """
            route.log(.store, .info, "evicted \\(AssetLog.hashed(id)) bytes=\\(byteCount)")
            route.log(.sync, .error,
                "failed \\(AssetLog.hashed(entry.identifier)) class=\\(failure)")
            let span = route.interval(.commit, category: .store, "generation \\(generation)")
            // print("in a comment") and Logger(subsystem: "x") in comments are not code
            let text = "print(\\"in a string\\") is not a call"
            """)
        #expect(Self.violations(in: good).isEmpty, "\(Self.violations(in: good))")

        // The repository.
        let lines = try SourceScan.lines()
        #expect(Set(lines.map { $0.path.split(separator: "/")[1] }).count == 7, "every production target was scanned")
        let constructions = lines.filter { $0.code.contains("Logger(") || $0.code.contains("OSSignposter(") }
        #expect(constructions.count == 3, "\(constructions.map { "\($0.path):\($0.number)" })")
        #expect(constructions.allSatisfy { $0.path == Self.logFile })
        let violations = Self.violations(in: lines)
        #expect(violations.isEmpty, "\(violations)")
        #expect(LogCategory.allCases.map(\.rawValue) == ["store", "sync", "transport", "apple"])
        #expect(AssetLog.subsystem == "com.ztron.assetkit")
    }

    @Test("R-OBS-1: every signpost interval has a call site once the work package that owns it has no stub left")
    func intervalsHaveCallSites() throws {
        // The detector recognises a call site, so the rule below can bite.
        let sample = SourceScan.lex(path: "Sources/X/Y.swift", text: """
            let commit = self.environment.log.interval(.commit, category: .store, "generation \\(generation)")
            // log.interval(.gc, category: .store) in a comment is not a call site
            """)
        #expect(Self.callSites(of: .commit, in: sample).count == 1)
        #expect(Self.callSites(of: .gc, in: sample).isEmpty)

        let lines = try SourceScan.lines()
        var pending: [String] = []
        for name in LogIntervalName.allCases {
            let owner = try #require(Self.owners[name])
            let ownerHasStubs = lines.contains { line in
                line.path.hasPrefix("Sources/\(owner.target)/") && line.text.contains("fatalError(\"WP-\(owner.workPackage)")
            }
            let sites = Self.callSites(of: name, in: lines)
            if sites.isEmpty {
                #expect(ownerHasStubs, "interval \(name.rawValue) has no call site, and WP-\(owner.workPackage) has no stub left in \(owner.target)")
                pending.append("\(name.rawValue) (WP-\(owner.workPackage))")
            }
        }
        print("R-OBS-1 intervals still waiting for their owner: \(pending.isEmpty ? "none" : pending.joined(separator: ", "))")
        #expect(Set(Self.owners.keys) == Set(LogIntervalName.allCases))
    }

    // MARK: - Rules

    /// Who wraps each interval (ARCHITECTURE §1.2, §13.5 item 2): plan is the engine's run, transfer the
    /// transport's, verify and commit the store core's, gc and eviction the store cleanup's.
    private static let owners: [LogIntervalName: (workPackage: String, target: String)] = [
        .plan: ("F", "ZTronAssetSync"),
        .transfer: ("D", "ZTronAssetTransport"),
        .verify: ("B", "ZTronAssetStorage"),
        .commit: ("B", "ZTronAssetStorage"),
        .gc: ("C", "ZTronAssetStorage"),
        .eviction: ("C", "ZTronAssetStorage"),
    ]

    private static func callSites(of name: LogIntervalName, in lines: [SourceScan.Line]) -> [SourceScan.Line] {
        lines.filter { $0.code.contains(".interval(.\(name.rawValue)") || $0.code.contains(".interval(LogIntervalName.\(name.rawValue)") }
    }

    /// Every rule violation in `lines`, as `path:line: rule`.
    private static func violations(in lines: [SourceScan.Line]) -> [String] {
        var found: [String] = []
        let forbiddenCalls = ["print(", "debugPrint(", "NSLog(", "os_log(", "dump("]
        for (index, line) in lines.enumerated() {
            let location = "\(line.path):\(line.number)"
            let code = line.code
            if (code.contains("Logger(") || code.contains("OSSignposter(") || code.contains("OSLog(")), line.path != Self.logFile {
                found.append("\(location): logger or signposter outside AssetLog.swift")
            }
            for call in forbiddenCalls where Self.containsCall(call, in: code) {
                found.append("\(location): \(call) bypasses the log sink")
            }
            if code.contains("LogLine(subsystem:"), !line.path.hasPrefix("Sources/ZTronAssetModel/Environment/") {
                found.append("\(location): a log line with its own subsystem")
            }
            if code.contains("LogCategory(rawValue:") {
                found.append("\(location): a category made from text")
            }
            if [".log(", "LogLine(", ".interval(", ".emit("].contains(where: code.contains), !code.contains("func ") {
                for interpolation in Self.statementText(from: index, in: lines).flatMap(SourceScan.interpolations(in:))
                where Self.namesIdentifier(interpolation) && !interpolation.contains("hashed(") {
                    found.append("\(location): \\(\(interpolation)) is not hashed")
                }
            }
        }
        return found
    }

    /// Whether `call` (`print(`) appears in `code` as a call, not as the tail of a longer name.
    private static func containsCall(_ call: String, in code: String) -> Bool {
        var searchStart = code.startIndex
        while let range = code.range(of: call, range: searchStart..<code.endIndex) {
            let preceding = range.lowerBound == code.startIndex ? nil : code[code.index(before: range.lowerBound)]
            if preceding.map({ !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) ?? true {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// The original text of the statement starting at `index`: lines are joined until its parentheses balance.
    private static func statementText(from index: Int, in lines: [SourceScan.Line]) -> [String] {
        var balance = 0
        var texts: [String] = []
        var current = index
        repeat {
            let line = lines[current]
            texts.append(line.text)
            balance += line.code.filter { $0 == "(" }.count - line.code.filter { $0 == ")" }.count
            current += 1
        } while balance > 0 && current < lines.count && lines[current].path == lines[index].path
        return texts
    }

    /// Whether an interpolated expression names something that identifies an asset or a location: those must be
    /// rendered through `AssetLog.hashed(_:)` (R-OBS-1) or not at all.
    private static func namesIdentifier(_ expression: String) -> Bool {
        let words = expression.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        let identifying: Set<String> = ["id", "ids", "identifier", "identifiers", "assetID", "rawValue", "remotePath", "url", "URL", "appKey", "key"]
        return words.contains(where: identifying.contains)
    }
}
