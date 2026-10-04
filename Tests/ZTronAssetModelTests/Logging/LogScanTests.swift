import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
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
                let detail = "evicted \\(id) after \\(count)"
                route.log(.store, .info, detail)
                var text = "start"
                text += " at \\(remotePath)"
                route.log(.store, .info, "done: \\(text)")
                func f(_ id: AssetID) { route.log(.store, .info, "x \\(id)") }
                func g(_ id: AssetID) -> LogInterval { route.interval(.gc, category: .store, "x \\(id)") }
                route.log(.sync, .error, "manifest rejected: \\(error)")
                route.log(.sync, .error, "first quarantine \\(manifest.quarantined.first!)")
                for asset in kept { route.log(.store, .info, "kept \\(asset)") }
                route.log(.sync, .info, "subject \\(subject) of \\(entries)")
                route.log(.sync, .info, "diagnostic \\(diagnostic) in \\(entry.remotePath.count)")
                """)
            #expect(Self.violations(in: bad).count == 20, "\(Self.violations(in: bad))")
            let good = SourceScan.lex(path: "Sources/X/Good.swift", text: """
                route.log(.store, .info, "evicted \\(AssetLog.hashed(id)) bytes=\\(byteCount)")
                route.log(.sync, .error,
                    "failed \\(AssetLog.hashed(entry.identifier)) class=\\(failure)")
                let span = route.interval(.commit, category: .store, "generation \\(generation)")
                let detail = "evicted \\(AssetLog.hashed(id)) after \\(count)"
                route.log(.store, .info, detail)
                let url = makeURL("\\(id)")
                route.log(.store, .info, "fetched \\(byteCount) bytes")
                // print("in a comment") and Logger(subsystem: "x") in comments are not code
                let text = "print(\\"in a string\\") is not a call"
                route.log(.sync, .info, "kept \\(manifest.count) of \\(entries.count), \\(manifest.quarantinedCount) quarantined")
                route.log(.sync, .error, "failed: \\(String(describing: type(of: error))) after \\(entries.isEmpty)")
                route.log(.sync, .error, "failed \\(AssetLog.hashed(entry.identifier)): \\(reasonClass)")
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

            // A stub is a `fatalError("WP-<owner>` call in code: a comment that quotes one does not keep the rule from
            // biting once the owner's real stubs are gone.
            let stubs = SourceScan.lex(path: "Sources/ZTronAssetStorage/X.swift", text: """
                /// Replaces the old `fatalError("WP-B: not implemented")` stub.
                func f() {} // fatalError("WP-B: not implemented")
                func g() { fatalError("WP-C: not implemented") }
                """)
            #expect(!Self.hasStub(workPackage: "B", target: "ZTronAssetStorage", in: stubs))
            #expect(Self.hasStub(workPackage: "C", target: "ZTronAssetStorage", in: stubs))
            #expect(!Self.hasStub(workPackage: "C", target: "ZTronAssetSync", in: stubs))

            let lines = try SourceScan.lines()
            var pending: [String] = []
            for name in LogIntervalName.allCases {
                let owner = try #require(Self.owners[name])
                let ownerHasStubs = Self.hasStub(workPackage: owner.workPackage, target: owner.target, in: lines)
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

        /// Whether `target` still contains a `fatalError("WP-<workPackage>` stub: the call must be code (`line.code`
        /// keeps it, a comment does not), and the line as written must name the work package.
        private static func hasStub(workPackage: String, target: String, in lines: [SourceScan.Line]) -> Bool {
            lines.contains { line in
                line.path.hasPrefix("Sources/\(target)/") && line.code.contains("fatalError(")
                    && line.text.contains("fatalError(\"WP-\(workPackage)")
            }
        }

        private static func callSites(of name: LogIntervalName, in lines: [SourceScan.Line]) -> [SourceScan.Line] {
            lines.filter { $0.code.contains(".interval(.\(name.rawValue)") || $0.code.contains(".interval(LogIntervalName.\(name.rawValue)") }
        }

        /// Every rule violation in `lines`, as `path:line: rule`.
        private static func violations(in lines: [SourceScan.Line]) -> [String] {
            var found: [String] = []
            let forbiddenCalls = ["print(", "debugPrint(", "NSLog(", "os_log(", "dump("]
            /// Names bound, in the current function, to text that interpolates an identifier without hashing it.
            var tainted: Set<String> = []
            var scope = ""
            for (index, line) in lines.enumerated() {
                let location = "\(line.path):\(line.number)"
                let code = line.code
                if line.path != scope || code.contains("func ") {
                    tainted = []
                    scope = line.path
                }
                if (code.contains("Logger(") || code.contains("OSSignposter(") || code.contains("OSLog(")), line.path != Self.logFile {
                    found.append("\(location): logger or signposter outside AssetLog.swift")
                }
                for call in forbiddenCalls where SourceScan.contains(call, in: code, standalone: true) {
                    found.append("\(location): \(call) bypasses the log sink")
                }
                if code.contains("LogLine(subsystem:"), !line.path.hasPrefix("Sources/ZTronAssetModel/Environment/") {
                    found.append("\(location): a log line with its own subsystem")
                }
                if code.contains("LogCategory(rawValue:") {
                    found.append("\(location): a category made from text")
                }
                let statement = Self.statement(from: index, in: lines)
                let unhashed = statement.map(\.text).flatMap(SourceScan.interpolations(in:)).filter {
                    Self.namesIdentifier($0) && !$0.contains("hashed(")
                }
                // Every line with a call is checked, a one-line `func` whose body logs included (fix round 2: lines with
                // `func ` used to be exempt, so `func f(_ id: AssetID) { route.log(…"\(id)") }` passed). The logging
                // API's own declarations need no exemption: `func log(` and the like contain none of these calls.
                if [".log(", "LogLine(", ".interval(", ".emit("].contains(where: code.contains) {
                    for interpolation in unhashed {
                        found.append("\(location): \\(\(interpolation)) is not hashed")
                    }
                    let words = Set(statement.flatMap { Self.words(in: $0.code) })
                    for name in tainted.sorted() where words.contains(name) {
                        found.append("\(location): \(name) carries an unhashed identifier into the line")
                    }
                }
                // A message assembled before the call: `let m = "…\\(id)…"`, `m += "…"`.
                if let name = Self.boundName(in: code) {
                    if !unhashed.isEmpty {
                        tainted.insert(name)
                    } else if !code.contains("+=") {
                        tainted.remove(name)
                    }
                }
            }
            return found
        }

        /// The name a `let`/`var` binding, an assignment or a `+=` on this line gives a value to.
        private static func boundName(in code: String) -> String? {
            let patterns = [#"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?=(?!=)"#, #"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\+?=(?!=)"#]
            let range = NSRange(code.startIndex..., in: code)
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                    let match = expression.firstMatch(in: code, range: range), let name = Range(match.range(at: 1), in: code)
                else {
                    continue
                }
                return String(code[name])
            }
            return nil
        }

        /// The identifiers (names) in a line of code.
        private static func words(in code: String) -> [String] {
            code.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        }

        /// The lines of the statement starting at `index`: lines are joined until its parentheses balance.
        private static func statement(from index: Int, in lines: [SourceScan.Line]) -> [SourceScan.Line] {
            var balance = 0
            var result: [SourceScan.Line] = []
            var current = index
            repeat {
                let line = lines[current]
                result.append(line)
                balance += line.code.filter { $0 == "(" }.count - line.code.filter { $0 == ")" }.count
                current += 1
            } while balance > 0 && current < lines.count && lines[current].path == lines[index].path
            return result
        }

        /// Whether an interpolated expression names something that identifies an asset or a location, or a value whose
        /// description can carry one: those must be rendered through `AssetLog.hashed(_:)` (R-OBS-1) or not at all.
        /// Since fix round 3 the names include errors (`ManifestError.duplicateIdentifier` renders the identifier),
        /// manifests, entries, assets, quarantine diagnostics and event subjects: `\(error)` or
        /// `\(manifest.quarantined.first!)` would put a raw identifier into a `.public` line. A count, an emptiness
        /// test or a type name derived from them carries none (`isSafeProjection`).
        private static func namesIdentifier(_ expression: String) -> Bool {
            let words = expression.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
            return words.contains(where: Self.identifyingNames.contains) && !Self.isSafeProjection(expression)
        }

        private static let identifyingNames: Set<String> = [
            "id", "ids", "identifier", "identifiers", "assetID", "rawValue", "remotePath", "url", "URL", "appKey", "key",
            "error", "errors", "entry", "entries", "asset", "assets", "quarantine", "quarantined", "diagnostic", "diagnostics",
            "manifest", "manifests", "subject", "subjects",
        ]

        /// Whether the expression is a number, a truth value or a type name: it ends in `.count`, `.isEmpty` or
        /// `.quarantinedCount`, or is `type(of:)` of something (possibly through `String(describing:)`).
        private static func isSafeProjection(_ expression: String) -> Bool {
            let trimmed = expression.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("type(of:") || trimmed.hasPrefix("String(describing: type(of:") {
                return true
            }
            return [".count", ".isEmpty", ".quarantinedCount"].contains { trimmed.hasSuffix($0) }
        }
    }
}
