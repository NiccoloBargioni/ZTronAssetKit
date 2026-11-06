import Foundation
import Testing
import ZTronAssetModel

@testable import ZTronAssetStorage
@testable import ZTronAssetTransport

/// Verifier probe (s3ah cycle 1, correctness lens): S3AH-2, reproducing the confirmer's S3-SECU-03 probe and more.
@Suite("C1 correct probe: S3AH-2 canonical staging names")
struct C1StagingNameProbe {
    static let hash = String(repeating: "a", count: 64)

    @Test("C1: the confirmer's reproduction: a fresh non-canonical staging name is collected as foreign")
    func nonCanonicalIsForeign() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for token in ["01-2", "1-02", "00-0", "0-00"] {
            let name = "c-\(Self.hash).\(token).part"
            let item = FileItemInfo(name: name, kind: .file, byteSize: 10, modifiedAt: now, identity: nil)
            let garbage = StagingCollection.garbage([item], claimed: [], now: now, policy: StoragePolicy())
            #expect(garbage.map(\.name) == [name], "non-canonical \(name) kept")
        }
        let canonical = StagingFileName(parsing: "c-\(Self.hash).1-2.part")
        let padded = StagingFileName(parsing: "c-\(Self.hash).1-02.part")
        #expect(canonical != nil)
        #expect(padded == nil)
    }

    @Test("C1: exhaustive tokens over [0-9-] up to 5 characters and unicode digits: parse implies identical text")
    func exhaustiveTokens() {
        let alphabet = Array("0123456789-").map(String.init)
        var layer = [""]
        var parsed = 0
        var aliases: [String] = []
        for _ in 1...5 {
            layer = layer.flatMap { prefix in alphabet.map { prefix + $0 } }
            for token in layer {
                if let attempt = TransferAttempt(token: token) {
                    parsed += 1
                    if attempt.token != token {
                        aliases.append(token)
                    }
                    let fileName = "c-\(Self.hash).\(token).resume"
                    if StagingFileName(parsing: fileName)?.rawValue != fileName {
                        aliases.append(fileName)
                    }
                }
            }
        }
        for odd in ["\u{661}-\u{662}", "\u{FF11}-\u{FF12}", "1-\u{FF12}", "1-2\u{301}", "1\u{301}-2", "+1-2", "1-+2", " 1-2", "1-2 ", "1--2", "-1-2",
            "18446744073709551616-0", "0-4294967296", "18446744073709551615-4294967295"]
        {
            if let attempt = TransferAttempt(token: odd), attempt.token != odd {
                aliases.append(odd)
            }
        }
        #expect(TransferAttempt(token: "18446744073709551615-4294967295") == TransferAttempt(epoch: .max, sequence: .max))
        #expect(TransferAttempt(token: "1-2\u{301}") == nil)
        print("C1 S3AH-2: parsed \(parsed) tokens, aliases \(aliases.count): \(aliases.prefix(10))")
        #expect(parsed > 1_000)
        #expect(aliases.isEmpty, "\(aliases.prefix(10))")
    }

    @Test("C1: a background task tag with a non-canonical staging name is not ours")
    func backgroundTagInherits() throws {
        let name = try #require(StagingFileName(parsing: "c-\(Self.hash).1-2.part"))
        let encoded = BackgroundTaskTag.forStart(name: name, expectedBytes: 10, resumeData: nil).encoded
        #expect(BackgroundTaskTag(decoding: encoded) != nil)
        let padded = encoded.replacingOccurrences(of: ".1-2.", with: ".01-2.")
        #expect(padded != encoded)
        #expect(BackgroundTaskTag(decoding: padded) == nil, "\(padded)")
    }
}
