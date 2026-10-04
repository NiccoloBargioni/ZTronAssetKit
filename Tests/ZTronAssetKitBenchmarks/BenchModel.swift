import Foundation
import Testing
import ZTronAssetKit

extension ZTronAssetKitBenchmarks {
    /// P-3 (WP-A): manifest decode and validation, release configuration (ADR-010). The only threshold is
    /// `budgets.P-3.manifest_decode_validate_ms`, read through `QualityBudgets`.
    @Suite("ModelBenchmarks")
    struct ModelBenchmarks {
        @Test("P-3: decoding and validating the 3.3 MB reference manifest stays under manifest_decode_validate_ms")
        func referenceManifestDecodesWithinBudget() throws {
            let budgetMS = try #require(try QualityBudgets().value("P-3", "manifest_decode_validate_ms"))
            let reference = ReferenceManifest.make()
            // The workload P-3 defines (SPEC §6): 10,000 entries, about 3.3 MB of JSON.
            #expect(reference.entryCount == 10_000)
            #expect(abs(reference.data.count - 3_300_000) < 330_000, "reference manifest is \(reference.data.count) bytes")

            for _ in 0..<3 {
                _ = try ManifestDecoder.decode(reference.data)
            }
            var timings: [Double] = []
            for _ in 0..<15 {
                let (milliseconds, manifest) = try ReferenceManifest.time { try ManifestDecoder.decode(reference.data) }
                #expect(manifest.count == 10_000 && manifest.quarantined.isEmpty)
                timings.append(milliseconds)
            }
            timings.sort()
            print("P-3 reference \(reference.data.count) bytes: p50 \(timings[timings.count / 2]) ms, max \(timings.last ?? 0) ms, budget \(budgetMS) ms")
            #expect((timings.last ?? .infinity) <= budgetMS)
        }

        @Test("P-3: the reference decode rate holds for fuzzed manifests at the 32 MiB payload limit, keeping R-MAN-3 within 1 s")
        func referenceRateHoldsAtThePayloadLimit() throws {
            let budgetMS = try #require(try QualityBudgets().value("P-3", "manifest_decode_validate_ms"))
            let reference = ReferenceManifest.make()
            let limit = Int(ManifestLimits().maxPayloadBytes)
            // P-3's rate scaled to the payload limit: about 0.81 s for 32 MiB, stricter than R-MAN-3's bound.
            let thresholdMS = budgetMS * Double(limit) / Double(reference.data.count)

            let dense = ReferenceManifest.make(maxBytes: limit - 4_096, seed: 32)
            let keepFirst = ManifestDecodingOptions(duplicates: .keepFirst)
            // Each case is made on demand, so no two large payloads are alive at once.
            let cases: [(String, ManifestDecodingOptions, () -> Data)] = [
                ("dense manifest", ManifestDecodingOptions(), { dense.data }),
                ("dense manifest truncated", ManifestDecodingOptions(), { dense.data.prefix(dense.data.count * 3 / 4) }),
                ("dense manifest with edits", ManifestDecodingOptions(), { ReferenceManifest.edited(dense.data, seed: 7) }),
                ("huge unknown string", ManifestDecodingOptions(), { ReferenceManifest.hugeString(in: "note", unit: "abcdefgh", bytes: limit - 256) }),
                ("huge multi-byte string", ManifestDecodingOptions(), { ReferenceManifest.hugeString(in: "note", unit: "é日😀", bytes: limit - 256) }),
                ("huge escaped file name", ManifestDecodingOptions(), {
                    ReferenceManifest.hugeString(in: "localFileName", unit: "\\u00e9\\n", bytes: limit - 256)
                }),
                ("deep nesting", ManifestDecodingOptions(), { Data(repeating: UInt8(ascii: "["), count: limit) }),
                // The allocation worst cases of R-MAN-3 (ADR draft A-5, A-8): the densest heap a valid manifest allows,
                // and the over-long values that are checked but never materialised.
                ("minimal entries of 16-byte strings", ManifestDecodingOptions(), { ReferenceManifest.shortStringEntries(count: 100_000) }),
                ("minimal entries of 16-byte strings, keepFirst", keepFirst, { ReferenceManifest.shortStringEntries(count: 100_000) }),
                ("24-byte path components", ManifestDecodingOptions(), { ReferenceManifest.componentEntries(length: 24, maxBytes: limit) }),
                ("61 one-byte tags per entry", ManifestDecodingOptions(), { ReferenceManifest.taggedEntries(tagCount: 61, maxBytes: limit) }),
                ("huge identifier", ManifestDecodingOptions(), { ReferenceManifest.hugeField("identifier", bytes: limit - 256) }),
                ("huge tag", ManifestDecodingOptions(), { ReferenceManifest.hugeField("tags", bytes: limit - 256, inArray: true) }),
                ("huge checksum", ManifestDecodingOptions(), { ReferenceManifest.hugeField("checksum", bytes: limit - 256) }),
                ("entries sharing one identifier, keepFirst", keepFirst, { ReferenceManifest.duplicateEntries(count: 100_000) }),
            ]
            for (name, options, make) in cases {
                let payload = make()
                #expect(payload.count <= limit, "\(name)")
                _ = try? ManifestDecoder.decode(payload, options: options)
                var worst = 0.0
                for _ in 0..<3 {
                    let (milliseconds, _) = ReferenceManifest.time { try? ManifestDecoder.decode(payload, options: options) }
                    worst = max(worst, milliseconds)
                }
                print("P-3 at the limit, \(name): \(payload.count) bytes, worst \(worst) ms, threshold \(thresholdMS) ms")
                #expect(worst <= thresholdMS, "\(name): \(worst) ms")
            }
        }
    }
}

/// The deterministic synthetic catalog P-3 measures: realistic entries (dotted identifier, AWS-tier remote path,
/// three directories, a file name, a size and a checksum) from a fixed seed, about 330 bytes each.
private enum ReferenceManifest {
    static func make() -> (data: Data, entryCount: Int) {
        let manifest = ReferenceManifest.make(maxBytes: Int.max, seed: 3, entryLimit: 10_000)
        return manifest
    }

    static func make(maxBytes: Int, seed: UInt64, entryLimit: Int = 100_000) -> (data: Data, entryCount: Int) {
        var random = SplitMix64(seed: seed)
        var text = "["
        var count = 0
        let extensions = ["heic", "png", "jpg", "svg", "mp4"]
        let areas = ["Vehytherion Temple", "Control Room", "Nacht der Untoten", "Cinematics"]
        while count < entryLimit {
            let word = random.next()
            let checksum = (0..<4).map { _ in ReferenceManifest.hex16(random.next()) }.joined()
            let ext = extensions[Int(word % UInt64(extensions.count))]
            let identifier = "bo7.ri.easter.egg.\(count).asset\(word >> 52)"
            let entry = "{\"identifier\":\"\(identifier)\",\"fileExtension\":\"\(ext)\",\"remotePath\":\"media/\(checksum.prefix(16))/\(identifier).\(ext)\","
                + "\"localPathComponents\":[\"Black Ops 7\",\"Rex Infernus\",\"\(areas[Int((word >> 8) % 4)])\"],"
                + (word % 2 == 0 ? "\"localFileName\":\"Asset \(count)\"," : "")
                + "\"byteSize\":\(word % 9_000_000),\"checksum\":\"\(checksum)\"}"
            guard text.utf8.count + entry.utf8.count + 2 <= maxBytes else {
                break
            }
            text += (count == 0 ? "" : ",") + entry
            count += 1
        }
        text += "]"
        return (Data(text.utf8), count)
    }

    /// `payload` with a few seeded byte edits (the decoder may reject or quarantine; only time is measured).
    static func edited(_ payload: Data, seed: UInt64) -> Data {
        var random = SplitMix64(seed: seed)
        var bytes = [UInt8](payload)
        for _ in 0..<8 {
            bytes[Int(random.next() % UInt64(bytes.count))] = UInt8(ascii: "x")
        }
        return Data(bytes)
    }

    /// One entry whose member `field` holds about `bytes` bytes of `unit`.
    static func hugeString(in field: String, unit: String, bytes: Int) -> Data {
        let head = Data((#"[{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],""# + field + "\":\"").utf8)
        let tail = Data("\"}]".utf8)
        let unitBytes = Data(unit.utf8)
        var data = head
        data.reserveCapacity(bytes)
        while data.count + unitBytes.count + tail.count <= bytes {
            data.append(unitBytes)
        }
        data.append(tail)
        return data
    }

    /// `count` minimal entries whose identifier, remote path and file name are 16-byte (heap) strings.
    static func shortStringEntries(count: Int) -> Data {
        var text = "["
        let filler = String(repeating: "f", count: 16)
        for index in 0..<count {
            let prefix = "\(index)-"
            let identifier = prefix + String(repeating: "i", count: max(0, 16 - prefix.utf8.count))
            text += (index == 0 ? "" : ",") + "{\"identifier\":\"\(identifier)\",\"fileExtension\":\"p\",\"remotePath\":\"\(filler)\","
                + "\"localPathComponents\":[],\"localFileName\":\"\(filler)\"}"
        }
        return Data((text + "]").utf8)
    }

    /// Entries with 32 path components of `length` bytes each, up to `maxBytes`.
    static func componentEntries(length: Int, maxBytes: Int) -> Data {
        var text = "["
        var index = 0
        while index < 100_000 {
            let components = (0..<32).map { component -> String in
                let prefix = "\(index)-\(component)-"
                return "\"" + prefix + String(repeating: "x", count: max(0, length - prefix.utf8.count)) + "\""
            }
            let entry = "{\"identifier\":\"i\(index)\",\"fileExtension\":\"p\",\"remotePath\":\"r\",\"localPathComponents\":["
                + components.joined(separator: ",") + "]}"
            guard text.utf8.count + entry.utf8.count + 2 <= maxBytes else {
                break
            }
            text += (index == 0 ? "" : ",") + entry
            index += 1
        }
        return Data((text + "]").utf8)
    }

    /// Minimal entries with `tagCount` one-byte tags and a 64-byte unknown member, up to `maxBytes`.
    static func taggedEntries(tagCount: Int, maxBytes: Int) -> Data {
        var text = "["
        let tags = Array(repeating: "\"t\"", count: tagCount).joined(separator: ",")
        let pad = String(repeating: "p", count: 64)
        var index = 0
        while index < 100_000 {
            let entry = "{\"identifier\":\"i\(index)\",\"fileExtension\":\"p\",\"remotePath\":\"r\",\"localPathComponents\":[],"
                + "\"tags\":[\(tags)],\"x\":\"\(pad)\"}"
            guard text.utf8.count + entry.utf8.count + 2 <= maxBytes else {
                break
            }
            text += (index == 0 ? "" : ",") + entry
            index += 1
        }
        return Data((text + "]").utf8)
    }

    /// `count` minimal entries that all share the identifier `a`.
    static func duplicateEntries(count: Int) -> Data {
        let entry = #"{"identifier":"a","fileExtension":"p","remotePath":"r","localPathComponents":[]}"#
        return Data(("[" + Array(repeating: entry, count: count).joined(separator: ",") + "]").utf8)
    }

    /// One entry whose known member `field` holds about `bytes` bytes of hex digits (in a one-element array when
    /// `inArray`): over its limit, so it is checked on the payload and never materialised.
    static func hugeField(_ field: String, bytes: Int, inArray: Bool = false) -> Data {
        var members = [("identifier", "\"a\""), ("fileExtension", "\"png\""), ("remotePath", "\"m/a.png\""), ("localPathComponents", "[]")]
        members.removeAll { $0.0 == field }
        let head = Data(("[{" + members.map { "\"\($0.0)\":\($0.1)," }.joined() + "\"\(field)\":" + (inArray ? "[\"" : "\"")).utf8)
        let tail = Data((inArray ? "\"]}]" : "\"}]").utf8)
        let unit = Data("abcdef01".utf8)
        var data = head
        data.reserveCapacity(bytes)
        while data.count + unit.count + tail.count <= bytes {
            data.append(unit)
        }
        data.append(tail)
        return data
    }

    static func hex16(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// Wall-clock milliseconds of one call (benchmarks run serialized, ADR-010).
    static func time<Result>(_ body: () throws -> Result) rethrows -> (Double, Result) {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try body()
        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return (milliseconds, result)
    }
}
