import Foundation
import Testing
import ZTronAssetModel

@testable import ZTronAssetStorage
@testable import ZTronAssetTransport

/// Independent verifier probes (s3ah, cycle 1, reqs lens): the fixed decoder against the REAL transport join
/// (`RemoteURL.make`) and the REAL staging GC, which the Model's own test target cannot import.
@Suite("S3AH verifier probes")
struct S3AHVerifierProbes {
    static let base = URL(string: "https://cdn.example.invalid/root")!

    static func decoderAccepts(_ path: String) -> Bool {
        ManifestDecoder.violations(of: ManifestEntry(identifier: "a.b", fileExtension: "png", remotePath: path), limits: ManifestLimits()).isEmpty
    }

    @Test("S3-SECU-02: every listed form is refused by both, the controls accepted by both", arguments: [
        "media//a.png", "media/./a.png", "./a.png", "media/%2E/a.png", "media/%2e/a.png", "media\\a.png", "media/",
        "media/a.png/", ".", "%2E", "a/.", "\\a", "a\\", "a/.?v=1", "a/%2E%2E/b", "a/.%2e/b",
    ])
    func refusedByBoth(_ path: String) {
        #expect(!Self.decoderAccepts(path), "\(path.debugDescription) accepted by decoder")
        #expect(RemoteURL.make(base: Self.base, path: path) == nil, "\(path.debugDescription) accepted by transport")
    }

    @Test("S3-SECU-02: controls accepted by both", arguments: [
        "media/ok.png", "a/.b/c.", "a/%2E.png", "a/%2E%2Fb", "a/%5Cb", "a..b/c", "x/.../y", "dir/%41.png", "a/%3F.png",
    ])
    func acceptedByBoth(_ path: String) {
        #expect(Self.decoderAccepts(path), "\(path.debugDescription) refused by decoder")
        #expect(RemoteURL.make(base: Self.base, path: path) != nil, "\(path.debugDescription) refused by transport")
    }

    @Test("S3-SECU-02: over 60,000 seeded paths (Unicode prepend and combining marks included) every decoder-accepted path yields a URL from the real RemoteURL.make")
    func seededAgreement() {
        let pieces = ["a", "b.png", ".", "..", "%2E", "%2e", "\\", "/", "//", "%2F", "%5C", "%", "%2", ":", "?", "#", "%3F",
                      "\u{0301}", "\u{0600}", "e\u{0301}", "\u{1F600}", " ", "~", "%00", "%E2%80%8B", ".%2E", "%2E."]
        var random = SplitMix64(seed: 0x5EED_0005_3AC1)
        var accepted = 0
        var mismatches: [String] = []
        for _ in 0..<60_000 {
            let path = (0..<Int.random(in: 1...6, using: &random)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &random)] }.joined()
            guard Self.decoderAccepts(path) else { continue }
            accepted += 1
            if RemoteURL.make(base: Self.base, path: path) == nil, mismatches.count < 20 {
                mismatches.append(path.debugDescription)
            }
        }
        #expect(mismatches.isEmpty, "decoder-accepted but transport-refused: \(mismatches)")
        #expect(accepted > 1_000, "accepted \(accepted)")
        print("S3AH probe: decoder accepted \(accepted) of 60000 seeded paths; transport refused \(mismatches.count) of them")
    }

    @Test("S3-SECU-03: a fresh, non-canonical staging name is collected as foreign (real StagingCollection.garbage)", arguments: ["01-2", "1-02", "00-0", "007-1"])
    func nonCanonicalIsForeign(_ token: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let name = "c-\(String(repeating: "a", count: 64)).\(token).part"
        let item = FileItemInfo(name: name, kind: .file, byteSize: 10, modifiedAt: now, identity: nil)
        let garbage = StagingCollection.garbage([item], claimed: [], now: now, policy: StoragePolicy())
        #expect(garbage.map(\.name) == [name])
        let canonical = "c-\(String(repeating: "a", count: 64)).1-2.part"
        let fresh = FileItemInfo(name: canonical, kind: .file, byteSize: 10, modifiedAt: now, identity: nil)
        // Control: the canonical fresh name is not foreign, so the comparison above is not vacuous.
        #expect(StagingCollection.garbage([fresh], claimed: [], now: now, policy: StoragePolicy()).isEmpty)
    }
}
