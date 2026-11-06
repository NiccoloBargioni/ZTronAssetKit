import Foundation
import Testing
import ZTronAssetModel

@testable import ZTronAssetTransport

/// Verifier probe (s3ah cycle 1, correctness lens): S3AH-1 against the REAL `RemoteURL.make`.
@Suite("C1 correct probe: S3AH-1 decoder vs RemoteURL.make")
struct C1RemotePathProbe {
    static let base = URL(string: "https://cdn.example.invalid/root")!

    static func violations(_ path: String) -> [ManifestEntryViolation] {
        ManifestDecoder.violations(
            of: ManifestEntry(identifier: "x", fileExtension: "png", remotePath: path), limits: ManifestLimits())
    }

    static func enumerate(_ alphabet: [String], maxLength: Int) -> [String] {
        var all: [String] = []
        var layer = [""]
        for _ in 1...maxLength {
            layer = layer.flatMap { prefix in alphabet.map { prefix + $0 } }
            all += layer
        }
        return all
    }

    /// Every path the decoder accepts is one the transport can join (the bug class of S3-SECU-02).
    @Test("C1: byte-level and token-level enumerations: decoder-accepted implies RemoteURL.make non-nil")
    func acceptedImpliesFetchable() {
        let bytes = Self.enumerate(["a", ".", "/", "\\", "%", "2", "E", "e", "F", "5", "C"], maxLength: 5)
        let tokens = Self.enumerate(["a", ".", "/", "\\", "%2E", "%2e", "%2F", "%5c", "?", "#", ":", "%", "\u{e9}", "\u{301}"], maxLength: 4)
        var acceptedButRefused: [String] = []
        var stricter: [String] = []
        var accepted = 0
        for path in bytes + tokens {
            let decoderAccepts = Self.violations(path).isEmpty
            let transportAccepts = RemoteURL.make(base: Self.base, path: path) != nil
            if decoderAccepts {
                accepted += 1
            }
            if decoderAccepts, !transportAccepts {
                acceptedButRefused.append(path)
            }
            let plain = !path.contains("?") && !path.contains("#") && !path.contains(":") && !path.lowercased().contains("%2f")
                && !path.lowercased().contains("%5c") && !path.hasPrefix("/")
            if !decoderAccepts, transportAccepts, plain {
                stricter.append(path)
            }
        }
        print("C1 S3AH-1: enumerated \(bytes.count + tokens.count), accepted \(accepted), accepted-but-refused \(acceptedButRefused.count): \(acceptedButRefused.prefix(20).map(\.debugDescription))")
        print("C1 S3AH-1: decoder stricter than transport on plain paths: \(stricter.count): \(stricter.prefix(30).map(\.debugDescription))")
        #expect(acceptedButRefused.isEmpty, "\(acceptedButRefused.prefix(20).map(\.debugDescription))")
        #expect(accepted > 1_000)
    }

    /// The streaming parser (raw and escaped strings) and `violations(of:)` agree on every enumerated path, and the
    /// quarantined violation is the first one `violations(of:)` lists.
    @Test("C1: streaming parser (raw and fully escaped) agrees with violations(of:) on every enumerated path")
    func parserAgreesWithRules() throws {
        let paths = Self.enumerate(["a", ".", "/", "\\", "%2E", "%2F", "?", ":", "\u{e9}"], maxLength: 4)
        var mismatches: [String] = []
        var missingDiagnostics = 0
        for escaped in [false, true] {
            for start in stride(from: 0, to: paths.count, by: 10) {
                let batch = Array(paths[start..<min(start + 10, paths.count)])
                let entries = batch.enumerated().map { index, path in
                    "{\"identifier\":\"p\(index)\",\"fileExtension\":\"png\",\"remotePath\":\(Self.quoted(path, escapeAll: escaped)),\"localPathComponents\":[\"A\"]}"
                }
                let manifest = try ManifestDecoder.decode(Data(("[" + entries.joined(separator: ",") + "]").utf8))
                let acceptedIDs = Set(manifest.entries.map(\.identifier.rawValue))
                var quarantined: [Int: ManifestEntryViolation] = [:]
                for item in manifest.quarantined {
                    quarantined[item.index] = item.violation
                }
                for (index, path) in batch.enumerated() {
                    let rules = Self.violations(path)
                    let accepted = acceptedIDs.contains("p\(index)")
                    if rules.isEmpty != accepted {
                        mismatches.append("\(escaped ? "esc" : "raw") \(path.debugDescription): rules \(rules) accepted \(accepted)")
                    } else if !accepted, quarantined[index] == nil {
                        missingDiagnostics += 1
                    } else if !accepted, quarantined[index] != rules.first {
                        mismatches.append("\(escaped ? "esc" : "raw") \(path.debugDescription): rules \(rules) quarantined \(String(describing: quarantined[index]))")
                    }
                }
            }
        }
        print("C1 S3AH-1 parser agreement: \(paths.count * 2) decodes, missing diagnostics \(missingDiagnostics), mismatches \(mismatches.count): \(mismatches.prefix(10))")
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
    }

    @Test("C1: the finding's spellings are quarantined; ordinary and escaped legitimate paths are still accepted")
    func findingSpellings() throws {
        for path in ["media//a.png", "media/./a.png", "./a.png", "media/%2E/a.png", "media/%2e/a.png", "media\\a.png", "media/", "a/%2E", "a/."] {
            #expect(Self.violations(path) == [.remotePathInvalid(.parentSegment)], "\(path.debugDescription) -> \(Self.violations(path))")
            #expect(RemoteURL.make(base: Self.base, path: path) == nil, "\(path.debugDescription)")
        }
        let legit = "{\"identifier\":\"e\",\"fileExtension\":\"png\",\"remotePath\":\"media\\/caf\\u00e9.png\",\"localPathComponents\":[\"A\"]}"
        let manifest = try ManifestDecoder.decode(Data(("[" + legit + "]").utf8))
        #expect(manifest.entries.map(\.remotePath) == ["media/caf\u{e9}.png"])
    }

    private static func quoted(_ text: String, escapeAll: Bool) -> String {
        if !escapeAll {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(text)) ?? Data(), as: UTF8.self)
        }
        var out = "\""
        for unit in text.utf16 {
            out += String(format: "\\u%04x", unit)
        }
        return out + "\""
    }
}
