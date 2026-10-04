import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-3's allocation bound for payloads of a few bytes to a few KiB (verifier round 3: a 64 KiB floor let
    /// 100 empty objects, 301 bytes, keep 6,240 bytes of diagnostics, 20.7x).
    ///
    /// A decode this small takes microseconds, so no sampler sees its peak; the retained growth is exact instead
    /// (`DecodeMeasurement.retainedGrowth`, no other thread involved). Each payload is decoded once before it is
    /// measured: the first decode of a process instantiates the Swift runtime's metadata for the decoder's generic
    /// types and CryptoKit's state, a few KiB once per process that no input can grow (ADR draft A-8).
    @Suite("Manifest allocation")
    struct ManifestAllocationTests {
        /// One small payload, and whether it must decode (a manifest a test or a publisher could plausibly write).
        struct SmallCase {
            var name: String
            var payload: Data
            var options = ManifestDecodingOptions()
            var mustDecode = false
        }

        @Test("R-MAN-3: a small payload's decoded form stays within 4x the payload, with no floor")
        func smallPayloadsStayWithinTheBound() {
            let cases = Self.smallCases()
            for small in cases {
                _ = Self.decode(small.payload, options: small.options)
            }
            for small in cases {
                let outcome = Self.decode(small.payload, options: small.options)
                if small.mustDecode, case .failure(let error) = outcome {
                    Issue.record("\(small.name): expected a manifest, got \(error)")
                }
                let retained = DecodeMeasurement.retainedGrowth { Self.decode(small.payload, options: small.options) }
                print("R-MAN-3 small case \(small.name): \(small.payload.count) bytes, retained \(retained) B")
                #expect(retained <= 4 * small.payload.count, "\(small.name): \(retained) B retained for \(small.payload.count) B")
            }
        }

        // MARK: - Corpus

        private static func smallCases() -> [SmallCase] {
            let minimal = #"{"identifier":"a","fileExtension":"p","remotePath":"r","localPathComponents":[]}"#
            let component16 = #"{"identifier":"a","fileExtension":"p","remotePath":"r","localPathComponents":["0123456789abcdef"]}"#
            let strings16 = #"{"identifier":"0123456789abcdef","fileExtension":"png","remotePath":"media/0123456789","localPathComponents":[],"localFileName":"Asset 0123456789"}"#
            let realistic = #"{"identifier":"bo7.ri.asset.0001","fileExtension":"png","remotePath":"media/0123456789abcdef/0001.png","localPathComponents":["Black Ops 7","Rex Infernus","Vehytherion Temple"]}"#
            let list = { (entries: [String]) in Data(("[" + entries.joined(separator: ",") + "]").utf8) }
            let numbered = { (count: Int) in
                list((0..<count).map { #"{"identifier":"a\#($0)","fileExtension":"p","remotePath":"r","localPathComponents":[]}"# })
            }
            return [
                SmallCase(name: "[1]", payload: Data("[1]".utf8)),
                SmallCase(name: "[{}]", payload: Data("[{}]".utf8)),
                SmallCase(name: "[1,1,1]", payload: Data("[1,1,1]".utf8)),
                SmallCase(name: "100 empty objects", payload: ManifestCorpus.repeatedElements("{}", count: 100)),
                SmallCase(name: "1,000 empty objects", payload: ManifestCorpus.repeatedElements("{}", count: 1_000)),
                SmallCase(name: "1,300 empty objects", payload: ManifestCorpus.repeatedElements("{}", count: 1_300)),
                SmallCase(name: "100 ones", payload: ManifestCorpus.repeatedElements("1", count: 100)),
                SmallCase(name: "an identifier alone", payload: Data(#"[{"identifier":"a"}]"#.utf8)),
                SmallCase(name: "an escaped identifier alone", payload: Data(#"[{"identifier":"\/"}]"#.utf8)),
                SmallCase(name: "two escaped identifiers", payload: Data(#"[{"identifier":"\/"},{"identifier":"a"}]"#.utf8)),
                SmallCase(name: "100 identifiers alone", payload: list((0..<100).map { #"{"identifier":"\#($0)"}"# })),
                SmallCase(name: "one minimal entry", payload: list([minimal]), mustDecode: true),
                SmallCase(name: "one entry with a 16-byte path component", payload: list([component16]), mustDecode: true),
                SmallCase(name: "one entry of 16-byte strings", payload: list([strings16]), mustDecode: true),
                SmallCase(name: "one realistic entry", payload: list([realistic]), mustDecode: true),
                SmallCase(name: "two minimal entries", payload: numbered(2), mustDecode: true),
                SmallCase(name: "nine minimal entries", payload: numbered(9), mustDecode: true),
                SmallCase(name: "100 minimal entries", payload: numbered(100), mustDecode: true),
                SmallCase(name: "100 minimal entries of 16-byte strings", payload: ManifestCorpus.shortStringEntries(length: 16, count: 100)),
                SmallCase(name: "50 entries sharing one identifier, keepFirst", payload: ManifestCorpus.duplicateEntries(count: 50),
                    options: ManifestDecodingOptions(duplicates: .keepFirst), mustDecode: true),
                SmallCase(name: "a realistic entry and a quarantined one", payload: list([realistic, #"{"identifier":"b","fileExtension":"p.g","remotePath":"r","localPathComponents":[]}"#]),
                    mustDecode: true),
                SmallCase(name: "an escaped entry", payload: list([#"{"identifier":"ab","fileExtension":"p","remotePath":"m\/é","localPathComponents":["A"],"localFileName":"\n"}"#]),
                    mustDecode: true),
            ]
        }

        private static func decode(_ payload: Data, options: ManifestDecodingOptions) -> Result<ValidatedManifest, ManifestError> {
            do throws(ManifestError) {
                return .success(try ManifestDecoder.decode(payload, options: options))
            } catch {
                return .failure(error)
            }
        }
    }
}
