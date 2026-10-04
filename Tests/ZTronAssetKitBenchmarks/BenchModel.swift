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
                ("minimal entries of 16-byte strings, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.shortStringEntries(count: 100_000))
                }),
                // Verifier round 3's R-MAN-3 reproductions, accepted at the estimate's limit (fix round 3, ADR draft A-8).
                ("100,000 entries with one 16-byte path component and one 16-byte tag, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.arrayStringEntries(count: 100_000, components: 1, tags: 1))
                }),
                ("100,000 entries with three 16-byte path components, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.arrayStringEntries(count: 100_000, components: 3, tags: 0))
                }),
                ("60,000 entries with three 16-byte strings and three 16-byte path components, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.arrayStringEntries(count: 60_000, components: 3, tags: 0, longStrings: true))
                }),
                ("100,000 minimal entries, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.arrayStringEntries(count: 100_000, components: 0, tags: 0))
                }),
                ("100,000 empty objects, quarantined", ManifestDecodingOptions(), {
                    Data(("[" + Array(repeating: "{}", count: 100_000).joined(separator: ",") + "]").utf8)
                }),
                ("25-byte path components", ManifestDecodingOptions(), { ReferenceManifest.componentEntries(length: 25, maxBytes: limit) }),
                ("61 one-byte tags per entry", ManifestDecodingOptions(), { ReferenceManifest.taggedEntries(tagCount: 61, maxBytes: limit) }),
                ("huge identifier", ManifestDecodingOptions(), { ReferenceManifest.hugeField("identifier", bytes: limit - 256) }),
                ("huge tag", ManifestDecodingOptions(), { ReferenceManifest.hugeField("tags", bytes: limit - 256, inArray: true) }),
                ("huge checksum", ManifestDecodingOptions(), { ReferenceManifest.hugeField("checksum", bytes: limit - 256) }),
                ("entries sharing one identifier, keepFirst", keepFirst, { ReferenceManifest.duplicateEntries(count: 100_000) }),
                // Per-entry arrays just past an allocator size class, padded to the allocation estimate's limit
                // (fix round 2): the most heap a payload the estimate accepts can hold.
                ("32 empty path components and 31 one-byte tags per entry, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.sizeClassEntries(components: 32, tags: 31, count: limit / 640))
                }),
                ("31 one-byte tags per entry, at the estimate's limit", ManifestDecodingOptions(), {
                    ReferenceManifest.atEstimateLimit(ReferenceManifest.sizeClassEntries(components: 0, tags: 31, count: 100_000))
                }),
                // Keys with an escape are compared while their escapes are decoded (fix round 2): the shortest escaped
                // key whose decoded length matches two field names, with the assets skipped once and parsed again
                // after schemaVersion, or in one entry; and envelope keys of schemaVersion's length.
                ("shortest escaped 8-byte unknown keys, assets before schemaVersion", ManifestDecodingOptions(), {
                    ReferenceManifest.repeatedKeys(#""\/bcdefgh":0"#, bytes: limit, assetsFirst: true)
                }),
                ("shortest escaped 8-byte unknown keys in one entry", ManifestDecodingOptions(), {
                    ReferenceManifest.repeatedKeys(#""\/bcdefgh":0"#, bytes: limit)
                }),
                ("escaped 13-byte unknown keys in the envelope", ManifestDecodingOptions(), {
                    ReferenceManifest.repeatedKeys(#""\/bcdefghijklm":0"#, bytes: limit, inEnvelope: true)
                }),
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

    /// `count` entries with an inline identifier and `components` path components and `tags` tags of 16 bytes each;
    /// with `longStrings`, a 16-byte identifier, remote path and file name too. Built by `String` concatenation.
    static func arrayStringEntries(count: Int, components: Int, tags: Int, longStrings: Bool = false) -> Data {
        func string(_ prefix: String) -> String {
            "\"" + prefix + String(repeating: "x", count: max(0, 16 - prefix.utf8.count)) + "\""
        }
        var text = "["
        for index in 0..<count {
            let identifier = longStrings ? string("\(index)-i") : "\"" + String(index, radix: 36) + "\""
            let componentList = (0..<components).map { string("\(index)-c\($0)-") }.joined(separator: ",")
            let tagList = (0..<tags).map { string("\(index)-t\($0)-") }.joined(separator: ",")
            text += (index == 0 ? "" : ",") + "{\"identifier\":" + identifier + ",\"fileExtension\":\"p\",\"remotePath\":"
                + (longStrings ? string("\(index)-r") : "\"r\"") + ",\"localPathComponents\":[" + componentList + "]"
                + (tags > 0 ? ",\"tags\":[" + tagList + "]" : "") + (longStrings ? ",\"localFileName\":" + string("\(index)-n") : "") + "}"
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

    /// `count` minimal entries, each with `components` empty path components and `tags` one-byte tags: arrays of
    /// 32 + 16 × n bytes, which for 31 and 32 elements (528 and 544 bytes) lie just past a size class of the
    /// segregated allocator and are served from 640-byte blocks.
    static func sizeClassEntries(components: Int, tags: Int, count: Int) -> Data {
        let componentList = "[" + Array(repeating: "\"\"", count: components).joined(separator: ",") + "]"
        let tagList = "[" + Array(repeating: "\"t\"", count: tags).joined(separator: ",") + "]"
        var text = "["
        for index in 0..<count {
            text += (index == 0 ? "" : ",") + "{\"identifier\":\"\(String(index, radix: 36))\",\"fileExtension\":\"p\",\"remotePath\":\"r\","
                + "\"localPathComponents\":\(componentList),\"tags\":\(tagList)}"
        }
        return Data((text + "]").utf8)
    }

    /// `payload` followed by just enough whitespace for the decoder's allocation estimate to reach its limit.
    /// Whitespace changes no estimate, and a rejection reports the estimate and the limit for the payload's size, so
    /// a decode or two find the padding; a payload the decoder already accepts is returned as it is.
    static func atEstimateLimit(_ payload: Data) -> Data {
        var padded = payload
        for _ in 0..<4 {
            do throws(ManifestError) {
                _ = try ManifestDecoder.decode(padded)
                return padded
            } catch {
                guard case .decodedSizeExceeded(let estimated, let limit) = error, limit > 0 else {
                    return padded
                }
                // The limit is proportional to the payload's size.
                let target = (Int(estimated) * padded.count + Int(limit) - 1) / Int(limit)
                padded += Data(repeating: UInt8(ascii: " "), count: max(1, target - padded.count))
            }
        }
        return padded
    }

    /// One minimal entry followed by copies of the unknown member `member` up to `bytes`: inside the entry (after
    /// the envelope's `assets` and before its `schemaVersion` when `assetsFirst`), or in the envelope itself.
    static func repeatedKeys(_ member: String, bytes: Int, assetsFirst: Bool = false, inEnvelope: Bool = false) -> Data {
        let entry = #"{"identifier":"a","fileExtension":"p","remotePath":"r","localPathComponents":[]"#
        let head: String
        let tail: String
        if inEnvelope {
            head = #"{"schemaVersion":1,"assets":["# + entry + "}]"
            tail = "}"
        } else if assetsFirst {
            head = #"{"assets":["# + entry
            tail = #"}],"schemaVersion":1}"#
        } else {
            head = "[" + entry
            tail = "}]"
        }
        let unit = Data(("," + member).utf8)
        let tailBytes = Data(tail.utf8)
        var data = Data(head.utf8)
        data.reserveCapacity(bytes)
        while data.count + unit.count + tailBytes.count <= bytes {
            data.append(unit)
        }
        data.append(tailBytes)
        return data
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

    /// Milliseconds of CPU time the calling thread spends in one call (`CLOCK_THREAD_CPUTIME_ID`). The decoder is
    /// single-threaded and does no I/O, so on a quiet device this is its wall time; unlike wall time it does not grow
    /// when other processes compete for the cores (fix round 2: on a busy host a 200 ms decode read 685 ms of wall
    /// time). Benchmarks run serialized (ADR-010).
    static func time<Result>(_ body: () throws -> Result) rethrows -> (Double, Result) {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = try body()
        let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        return (Double(elapsed) / 1_000_000, result)
    }
}
