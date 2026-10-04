import Foundation
import Testing

/// Source and manifest scans for the requirements that bind the whole package rather than one work package
/// (ARCHITECTURE §11, contract-fix round 4): R-CAR-9, R-SEC-3, R-ENV-2, R-ENV-3, R-ENV-4 and R-ENV-5.
///
/// Orchestrator-owned (every `*ContractTests.swift` is, ARCHITECTURE §1.2), so no work package has to edit another
/// package's tests to keep them. Each scan reads the repository through `#filePath` (no SwiftPM resource, no
/// working-directory assumption) and only reads: nothing is written anywhere. The gates of `Scripts/verify.sh`
/// (Q-1 builds, the unsafe gate Q-3) stay the primary proof; these tests make each requirement fail inside
/// `swift test` as well, with the offending file and line in the message.
@Suite("Package scans (orchestrator)")
struct PackageScanContractTests {
    /// The production targets; every one of them must be seen by the source scans, so a moved directory cannot
    /// make a scan pass vacuously.
    private static let productionTargets = [
        "ZTronAssetModel",
        "ZTronAssetStorage",
        "ZTronAssetTransport",
        "ZTronAssetAppleHosted",
        "ZTronAssetSync",
        "ZTronAssetKit",
        "ZTronAssetTestSupport",
    ]

    @Test("R-CAR-9: no production source imports UIKit, SwiftUI or Combine")
    func noUIFrameworkImports() throws {
        let files = try RepositoryScan.sourceFiles(suffix: ".swift")
        try RepositoryScan.requireEveryTarget(Self.productionTargets, in: files)

        var seen: Set<String> = []
        for file in files {
            for (index, line) in file.lines.enumerated() {
                guard let module = RepositoryScan.importedModule(in: line) else {
                    continue
                }
                seen.insert(module)
                #expect(
                    !["UIKit", "SwiftUI", "Combine"].contains(module),
                    "\(file.path):\(index + 1) imports \(module)"
                )
            }
        }
        // The scan really parsed the imports (a parser that saw none would pass vacuously).
        #expect(seen.isSuperset(of: ["Foundation", "ZTronAssetModel", "ZTronAssetStorage", "CryptoKit"]))
    }

    @Test("R-SEC-3: no file under Sources/ declares NSAllowsArbitraryLoads, an ATS exception or a private API")
    func noTransportSecurityExceptionsOrPrivateAPI() throws {
        let files = try RepositoryScan.sourceFiles(suffix: nil)
        try RepositoryScan.requireEveryTarget(Self.productionTargets, in: files)
        // App Transport Security exception keys (any Info.plist or code that builds one), then private-API and
        // runtime-hack entry points. `@_exported import` is a compile-time re-export, not a private API (§8).
        let forbidden = [
            "NSAllowsArbitraryLoads",
            "NSAllowsLocalNetworking",
            "NSExceptionDomains",
            "NSExceptionAllowsInsecureHTTPLoads",
            "NSTemporaryExceptionAllowsInsecureHTTPLoads",
            "NSExceptionMinimumTLSVersion",
            "dlopen(",
            "dlsym(",
            "NSClassFromString(",
            "NSSelectorFromString(",
            "objc_msgSend",
            "method_exchangeImplementations",
            "method_setImplementation",
            "class_replaceMethod",
            "class_addMethod",
            "@_silgen_name",
            "forKey: \"_",
            "forKeyPath: \"_",
        ]

        var scannedLines = 0
        for file in files {
            for (index, line) in file.lines.enumerated() {
                // Swift comments may name the keys (as this requirement's docs do); every other file is scanned whole.
                let code = file.path.hasSuffix(".swift") ? RepositoryScan.codePart(of: line) : line
                scannedLines += 1
                for token in forbidden {
                    #expect(!code.contains(token), "\(file.path):\(index + 1) contains \(token)")
                }
            }
        }
        #expect(scannedLines > 1_000)
    }

    @Test("R-ENV-2: the package's deployment floors are iOS 15 and macOS 12 (manifest scan; the Q-1 iOS build is the primary proof)")
    func deploymentFloors() throws {
        let manifest = try RepositoryScan.packageManifestCode()
        let platforms = try RepositoryScan.matches(
            of: #"\.(iOS|macOS|macCatalyst|tvOS|watchOS|visionOS|driverKit)\(\s*([^)]*)\)"#,
            in: manifest
        )
        let declared = Set(platforms.map { "\($0[1]) \($0[2])" })
        #expect(declared == ["iOS .v15", "macOS .v12"])
    }

    @Test("R-ENV-3: Package.swift declares no package dependencies")
    func noPackageDependencies() throws {
        let manifest = try RepositoryScan.packageManifestCode()
        // A third-party dependency needs `.package(…)` in the package's dependencies and `.product(…)` in a target's.
        #expect(!manifest.contains(".package("))
        #expect(!manifest.contains(".product("))
        // Every target dependency names a target this manifest declares.
        let declaredTargets = Set(
            try RepositoryScan.matches(of: #"\.(?:target|testTarget)\(\s*name:\s*"([^"]+)""#, in: manifest).map { $0[1] }
        )
        #expect(declaredTargets.isSuperset(of: Self.productionTargets))
        let dependencyLists = try RepositoryScan.matches(of: #"dependencies:\s*\[([^\]]*)\]"#, in: manifest).map { $0[1] }
        #expect(!dependencyLists.isEmpty)
        for list in dependencyLists {
            for name in try RepositoryScan.matches(of: #""([^"]+)""#, in: list).map({ $0[1] }) {
                #expect(declaredTargets.contains(name), "dependency \(name) is not a target of this package")
            }
        }
    }

    @Test("R-ENV-4: the unsafe-pattern scan of Sources/ finds at most three escapes, each audited (the unsafe gate Q-3 is the primary proof; today 0)")
    func unsafeEscapesAreCappedAndAudited() throws {
        // The patterns and the cap come from the frozen gate configuration, so this test cannot drift from Q-3.
        let configuration = try RepositoryScan.gateConfiguration()
        let unsafe = try #require(configuration["unsafe"] as? [String: Any])
        let patterns = try #require(unsafe["patterns"] as? [String])
        let maxEscapes = try #require(unsafe["max_escapes"] as? Int)
        #expect(patterns.count >= 9)
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        let marker = try NSRegularExpression(pattern: #"UNSAFE-AUDIT:\s*(U-\d+)"#)
        let audit = try String(contentsOf: RepositoryScan.root.appendingPathComponent("docs/UNSAFE-AUDIT.md"), encoding: .utf8)

        let files = try RepositoryScan.sourceFiles(suffix: ".swift")
        try RepositoryScan.requireEveryTarget(Self.productionTargets, in: files)
        var escapes: [(location: String, marker: String?)] = []
        for file in files {
            for (index, line) in file.lines.enumerated() {
                let code = RepositoryScan.codePart(of: line)
                guard expressions.contains(where: { RepositoryScan.firstMatch(of: $0, in: code) != nil }) else {
                    continue
                }
                // As the gate: the marker is on the line itself or on the line before it.
                let context = (index > 0 ? file.lines[index - 1] : "") + " " + line
                let found = RepositoryScan.firstMatch(of: marker, in: context).map { $0[1] }
                escapes.append((location: "\(file.path):\(index + 1)", marker: found))
            }
        }

        #expect(escapes.count <= min(maxEscapes, 3), "escapes: \(escapes.map(\.location))")
        for escape in escapes {
            let id = try #require(escape.marker, "\(escape.location) has no // UNSAFE-AUDIT: U-nnn marker")
            #expect(audit.contains(id), "\(id) at \(escape.location) has no entry in docs/UNSAFE-AUDIT.md")
        }
    }

    @Test("R-ENV-5: Package.swift sets Swift 6 language mode and strict concurrency and no warnings-as-errors flag (Q-1 builds are the primary proof)")
    func languageModeAndStrictConcurrency() throws {
        let raw = try String(contentsOf: RepositoryScan.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let toolsVersion = try #require(
            try RepositoryScan.matches(of: #"^// swift-tools-version:\s*(\d+)\.(\d+)"#, in: raw).first
        )
        #expect((Int(toolsVersion[1]) ?? 0) >= 6)

        let manifest = try RepositoryScan.packageManifestCode()
        #expect(manifest.contains("swiftLanguageModes: [.v6]"))
        #expect(manifest.contains(#".enableExperimentalFeature("StrictConcurrency=complete")"#))
        // Every target, production and test, gets the strict-concurrency settings.
        let targets = try RepositoryScan.matches(of: #"\.(?:target|testTarget)\("#, in: manifest).count
        let strict = try RepositoryScan.matches(of: #"swiftSettings:\s*strictConcurrency"#, in: manifest).count
        #expect(targets > Self.productionTargets.count)
        #expect(strict == targets)
        // Warnings-as-errors is passed on the command line by Scripts/verify.sh, never baked in (C6).
        for flag in ["warnings-as-errors", "treatAllWarnings", "treatWarning", "unsafeFlags"] {
            #expect(!manifest.contains(flag), "Package.swift sets \(flag)")
        }
    }
}

/// Read-only helpers over the repository's files for `PackageScanContractTests`.
private enum RepositoryScan {
    /// One scanned file: its path relative to the repository and its lines.
    struct File {
        /// For example `Sources/ZTronAssetModel/Identity/AssetID.swift`.
        var path: String
        /// The file's lines, without terminators.
        var lines: [String]
    }

    /// The repository root, three levels above this file (`Tests/ZTronAssetModelTests/<file>`).
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every regular file under `Sources/` (with `suffix`, when given), sorted by path.
    static func sourceFiles(suffix: String?) throws -> [File] {
        let sources = self.root.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var files: [File] = []
        let prefix = self.root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) {
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let path = url.standardizedFileURL.path
            files.append(
                File(
                    path: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path,
                    lines: text.components(separatedBy: "\n")
                )
            )
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Fails unless the scan saw at least one file of every target.
    static func requireEveryTarget(_ targets: [String], in files: [File]) throws {
        for target in targets {
            try #require(files.contains { $0.path.hasPrefix("Sources/\(target)/") }, "no file of \(target) was scanned")
        }
    }

    /// The part of a Swift line before its first `//` (the unsafe gate's own rule; a `//` inside a string literal
    /// shortens the scanned part, never lengthens it).
    static func codePart(of line: String) -> String {
        guard let range = line.range(of: "//") else {
            return line
        }
        return String(line[..<range.lowerBound])
    }

    /// The top-level module an `import` line names (`import Foundation`, `@_exported import X`,
    /// `import struct SwiftUI.Color`, `@preconcurrency import Combine`), or `nil` for any other line.
    static func importedModule(in line: String) -> String? {
        var tokens = self.codePart(of: line).split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first, first.hasPrefix("@") {
            tokens.removeFirst()
        }
        guard tokens.first == "import", tokens.count >= 2 else {
            return nil
        }
        let kinds: Set<String> = ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]
        let path = kinds.contains(tokens[1]) && tokens.count >= 3 ? tokens[2] : tokens[1]
        return path.split(separator: ".").first.map(String.init)
    }

    /// `Package.swift` without its comments.
    static func packageManifestCode() throws -> String {
        let text = try String(contentsOf: self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        return text.components(separatedBy: "\n").map(self.codePart(of:)).joined(separator: "\n")
    }

    /// `Scripts/quality-gates.json` (read only; the harness is frozen).
    static func gateConfiguration() throws -> [String: Any] {
        let data = try Data(contentsOf: self.root.appendingPathComponent("Scripts/quality-gates.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every match of `pattern` in `text`, each as its capture groups (index 0 is the whole match; an unmatched
    /// group is "").
    static func matches(of pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { self.groups(of: $0, in: text) }
    }

    /// The first match of `expression` in `text`, as its capture groups.
    static func firstMatch(of expression: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range).map { self.groups(of: $0, in: text) }
    }

    private static func groups(of match: NSTextCheckingResult, in text: String) -> [String] {
        (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
