import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-3: fuzzed input never traps, and at the 32 MiB payload limit the decoder stays within 4x the payload and
    /// within 1 s.
    ///
    /// Every case derives from one base seed, printed at the start (override it with `ZTRON_MANIFEST_FUZZ_SEED` to
    /// replay a run); each expectation names its case and seed. A trap would end the test process, so reaching the
    /// expectations at all is the "never traps" half; the outcome of every case is also checked against what it must
    /// be (a typed error, a quarantine, or a manifest whose invariants hold).
    ///
    /// How the bounds are measured (ADR draft A-5): time is the decoding thread's CPU time; the heap peak is sampled
    /// (`DecodeMeasurement`). The 1 s bound is about the shipped, optimised decoder, so it is asserted when this target
    /// is built optimised, and in every harness run by the release benchmark `P-3: … R-MAN-3 …` (BenchModel.swift);
    /// an unoptimised build instead asserts that time grows linearly from 1 MiB to 32 MiB, the property that keeps the
    /// optimised bound (no quadratic path). Under Thread Sanitizer, whose allocator and instrumentation change both
    /// figures, the limit-scale cases shrink to 1 MiB and only the outcomes are checked.
    @Suite("Manifest fuzz", .serialized)
    struct ManifestFuzzTests {
        /// What a case must decode to.
        enum Expected {
            /// Any typed outcome; a manifest must satisfy the invariants.
            case anyOutcome
            /// Exactly this error.
            case error(ManifestError)
            /// One entry, quarantined with this violation.
            case quarantined(ManifestEntryViolation)
            /// This many entries, nothing quarantined.
            case accepted(Int)
            /// This many entries accepted and this many quarantined.
            case acceptedAndQuarantined(accepted: Int, quarantined: Int)
            /// Rejected before anything is built because the decoded form could exceed four times the payload.
            case overAllocationBudget
            /// Nothing accepted, every element quarantined, and as many diagnostics as the default limit keeps.
            case allQuarantined(Int)
        }

        /// One fuzz input.
        struct Case {
            var name: String
            var seed: UInt64
            var payload: Data
            var expected: Expected
            /// The options the case decodes with (remote-manifest defaults unless the case says otherwise).
            var options = ManifestDecodingOptions()
            /// The decoder's largest requests for this case, which the allocator is made to serve from cached blocks
            /// nearly twice their size before the case is measured (`DecodeMeasurement.serveFromBlocksTwiceAsLarge`).
            var largeRequests: [Int] = []
        }

        private static let baseSeed: UInt64 = {
            if let text = ProcessInfo.processInfo.environment["ZTRON_MANIFEST_FUZZ_SEED"], let seed = UInt64(text) {
                return seed
            }
            return 0x5EED_0000_0003
        }()

        @available(macOS 15.0, iOS 18.0, *)
        @Test("R-MAN-3: seeded fuzz of random, truncated, mutated and deeply nested manifests never traps, and outside Thread Sanitizer stays within 4x the payload in linear time")
        func seededFuzzStaysWithinBounds() throws {
            let seed = Self.baseSeed
            print("R-MAN-3 fuzz: base seed \(seed) (replay with ZTRON_MANIFEST_FUZZ_SEED=\(seed))")
            let small = try Self.smallCorpus(seed: seed)
            #expect(small.count > 1_000)
            for fuzzCase in small {
                Self.check(fuzzCase, outcome: Self.decode(fuzzCase.payload, options: fuzzCase.options))
            }

            let tsan = DecodeMeasurement.underThreadSanitizer
            let limit = tsan ? 1 << 20 : ManifestCorpus.payloadLimit
            var denseCPU: (small: Double, limit: Double)?
            var limitCases = 0
            Self.forEachLimitCase(seed: seed, payloadBytes: limit) { fuzzCase in
                limitCases += 1
                #expect(fuzzCase.payload.count <= ManifestCorpus.payloadLimit, "\(fuzzCase.name) seed \(fuzzCase.seed)")
                let held = tsan ? [] : DecodeMeasurement.serveFromBlocksTwiceAsLarge(fuzzCase.largeRequests)
                let (outcome, cost) = DecodeMeasurement.measure { Self.decode(fuzzCase.payload, options: fuzzCase.options) }
                withExtendedLifetime(held) {}
                Self.check(fuzzCase, outcome: outcome)
                guard !tsan else {
                    return
                }
                let label = "\(fuzzCase.name) seed \(fuzzCase.seed): \(fuzzCase.payload.count) bytes, cpu \(cost.cpuSeconds) s, peak \(cost.peakHeapGrowth) B"
                #expect(cost.peakHeapGrowth <= 4 * fuzzCase.payload.count, "\(label)")
                if case .overAllocationBudget = fuzzCase.expected {
                    // Rejected by the survey: the result was never built.
                    #expect(cost.peakHeapGrowth < fuzzCase.payload.count, "\(label)")
                }
                #expect(cost.retainedHeapGrowth <= 4 * fuzzCase.payload.count, "\(label), retained \(cost.retainedHeapGrowth) B")
                print("R-MAN-3 limit case \(label), retained \(cost.retainedHeapGrowth) B")
                if DecodeMeasurement.isOptimized {
                    #expect(cost.cpuSeconds <= 1.0, "\(label)")
                }
                if fuzzCase.name == Self.denseCaseName {
                    let reference = ManifestCorpus.manifest(maxBytes: 1 << 20, seed: fuzzCase.seed).data
                    let referenceCost = DecodeMeasurement.measure { Self.decode(reference) }.cost
                    denseCPU = (referenceCost.cpuSeconds, cost.cpuSeconds)
                }
            }
            #expect(limitCases == 38)
            if !tsan {
                // Linear time: 32x the bytes may cost at most 64x the CPU of the 1 MiB manifest (a quadratic path would
                // cost about 1,000x).
                let dense = try #require(denseCPU)
                #expect(dense.limit <= 64 * dense.small, "dense 1 MiB \(dense.small) s vs limit \(dense.limit) s")
            }
        }

        @available(macOS 15.0, iOS 18.0, *)
        @Test("R-MAN-3: a manifest whose decoded form could exceed four times its payload is rejected before anything is built")
        func overBudgetManifestIsRejectedEarly() throws {
            let payload = ManifestCorpus.shortComponentEntries(length: 16, maxBytes: 2 << 20)
            // Three identical decodes: the lowest peak is the decoder's own, since whatever another thread allocates
            // meanwhile only adds to a sample (the orchestrator's contract suites run beside `ModelSuites`).
            var lowestPeak = Int.max
            for _ in 0..<3 {
                let (outcome, cost) = DecodeMeasurement.measure { Self.decode(payload) }
                guard case .failure(.decodedSizeExceeded(let estimated, let limit)) = outcome else {
                    Issue.record("expected decodedSizeExceeded, got \(outcome)")
                    return
                }
                #expect(estimated > limit)
                #expect(limit <= 4 * Int64(payload.count))
                lowestPeak = min(lowestPeak, cost.peakHeapGrowth)
            }
            if !DecodeMeasurement.underThreadSanitizer {
                // The over-budget result was never built (it would take more than 4x the payload); about 10 KB of
                // the survey's own state is, hence the generous bound.
                #expect(lowestPeak < payload.count, "peak \(lowestPeak) B for \(payload.count) B")
            }
            // 18-byte components are over the limit too (a 64-byte string and a 16-byte slot for 21 payload bytes); 20-byte
            // ones fit (about 3.6x), and are decoded whole.
            let denser = ManifestCorpus.shortComponentEntries(length: 18, maxBytes: 2 << 20)
            guard case .failure(.decodedSizeExceeded(let denserEstimate, let denserLimit)) = Self.decode(denser) else {
                Issue.record("expected decodedSizeExceeded for 18-byte components")
                return
            }
            #expect(denserEstimate > denserLimit && denserLimit == Int64(denser.count) * 15 / 4)
            let fitting = ManifestCorpus.shortComponentEntries(length: 20, maxBytes: 2 << 20)
            let decoded = try ManifestDecoder.decode(fitting)
            #expect(decoded.count > 0 && decoded.quarantined.isEmpty)
            #expect(decoded.entries.allSatisfy { $0.localPathComponents.count == 32 })
        }

        @Test("R-MAN-2: a manifest dense with invalid entries is quarantined entry by entry, with an exact count and at most maxQuarantineDiagnostics diagnostics")
        func quarantineDenseManifests() throws {
            // A realistic quarantine: 2,000 entries whose checksum has 32 hex digits are each quarantined; the first 256
            // keep a diagnostic.
            let entries = (0..<2_000).map { index in
                "{\"identifier\":\"bo7.ri.asset.\(index)\",\"fileExtension\":\"png\",\"remotePath\":\"media/a/\(index).png\","
                    + "\"localPathComponents\":[\"Black Ops 7\",\"Maps\"],\"checksum\":\"\(String(repeating: "0f", count: 16))\"}"
            }
            let realistic = try ManifestDecoder.decode(Data(("[" + entries.joined(separator: ",") + "]").utf8))
            #expect(realistic.count == 0 && realistic.quarantinedCount == 2_000)
            #expect(realistic.quarantined.map(\.index) == Array(0..<256))
            #expect(realistic.quarantined.allSatisfy { $0.violation == .checksumInvalid && $0.identifier != nil })
            #expect(realistic.quarantined.first?.identifier == "bo7.ri.asset.0")

            // Empty objects, three bytes of payload for a 48-byte diagnostic: every one is quarantined and counted (past
            // about 1,300 of them they used to be rejected whole, ADR draft A-8), and the diagnostics kept are a prefix
            // that fits the allocation bound: none of 1 (4 bytes), some of 100 and of 1,000, 256 of 20,000 and more.
            for count in [1, 100, 1_000, 20_000, 100_000] {
                let payload = ManifestCorpus.repeatedElements("{}", count: count)
                let manifest = try ManifestDecoder.decode(payload)
                let kept = manifest.quarantined.count
                print("R-MAN-2 quarantine of \(count) empty objects (\(payload.count) bytes): \(kept) diagnostics kept")
                #expect(manifest.count == 0 && manifest.quarantinedCount == count, "\(count)")
                #expect(manifest.quarantined.map(\.index) == Array(0..<kept), "\(count)")
                #expect(manifest.quarantined.allSatisfy { $0.violation == .malformedField("identifier") && $0.identifier == nil }, "\(count)")
                #expect(kept <= min(count, 256), "\(count): \(kept) kept")
                #expect(count < 100 || kept > 0, "\(count): \(kept) kept")
                #expect(count < 20_000 || kept == 256, "\(count): \(kept) kept")
                #expect(kept == 0 || 32 + MemoryLayout<QuarantinedEntry>.stride * kept <= 4 * payload.count, "\(count): \(kept) kept")
            }
            // The limit is a parameter: none at all, or every one.
            let none = try ManifestDecoder.decode(Data("[{},1,null]".utf8), options: ManifestDecodingOptions(limits: ManifestLimits(maxQuarantineDiagnostics: 0)))
            #expect(none.quarantinedCount == 3 && none.quarantined.isEmpty)
            let realisticPayload = Data(("[" + entries.joined(separator: ",") + "]").utf8)
            let every = try ManifestDecoder.decode(realisticPayload, options: ManifestDecodingOptions(limits: ManifestLimits(maxQuarantineDiagnostics: 5_000)))
            #expect(every.quarantinedCount == 2_000 && every.quarantined.count == 2_000)
        }

        @Test("R-MAN-3: every prefix of a shipped manifest is rejected as not JSON without trapping")
        func everyPrefixIsRejected() throws {
            let payload = try ManifestFixtures.data("manifests/apple/v1.envelope.json")
            let close = try #require(payload.lastIndex(of: UInt8(ascii: "}")))
            let stride = DecodeMeasurement.underThreadSanitizer ? 13 : 1
            for length in Swift.stride(from: 0, to: close + 1, by: stride) {
                #expect(throws: ManifestError.undecodable(.notJSON), "prefix \(length)") {
                    try ManifestDecoder.decode(payload.prefix(length))
                }
            }
            #expect(try ManifestDecoder.decode(payload.prefix(close + 1)).count == 13)
        }

        // MARK: - Corpora

        /// Thousands of small inputs: random bytes, prefixes and mutations of every fixture and of generated
        /// manifests, nesting around the depth limit, and long strings in every field.
        private static func smallCorpus(seed: UInt64) throws -> [Case] {
            var cases: [Case] = []
            var random = SplitMix64(seed: seed)
            let starts: [UInt8?] = [nil, UInt8(ascii: "["), UInt8(ascii: "{"), UInt8(ascii: "\"")]
            for size in [0, 1, 2, 3, 7, 16, 64, 256, 4_096, 65_536] {
                for first in starts {
                    for _ in 0..<6 {
                        let caseSeed = random.next()
                        let payload = ManifestCorpus.randomBytes(count: size, seed: caseSeed, firstByte: first)
                        cases.append(Case(name: "random \(size) bytes", seed: caseSeed, payload: payload, expected: .anyOutcome))
                    }
                }
            }

            var sources: [(String, Data)] = []
            let fixtures = try FileManager.default.contentsOfDirectory(
                at: ManifestFixtures.root.appendingPathComponent("manifests/invalid"), includingPropertiesForKeys: nil
            ).map { "manifests/invalid/" + $0.lastPathComponent }
            for file in ["manifests/aws/v1.json", "manifests/aws/v1.envelope.json", "manifests/apple/v3-directory-change.json",
                "manifests/apple/v1.envelope.json"] + fixtures.sorted()
            {
                sources.append((file, try ManifestFixtures.data(file)))
            }
            for count in [1, 7, 50] {
                let generatedSeed = random.next()
                sources.append(("generated \(count) entries", ManifestCorpus.manifest(entryCount: count, seed: generatedSeed)))
            }
            for (name, source) in sources {
                for _ in 0..<12 {
                    let caseSeed = random.next()
                    let cut = Int(caseSeed % UInt64(source.count + 1))
                    cases.append(Case(name: "\(name) truncated to \(cut)", seed: caseSeed, payload: source.prefix(cut), expected: .anyOutcome))
                }
                for edits in [1, 2, 4, 16] {
                    for _ in 0..<10 {
                        let caseSeed = random.next()
                        let payload = ManifestCorpus.mutated(source, count: edits, seed: caseSeed)
                        cases.append(Case(name: "\(name) with \(edits) edits", seed: caseSeed, payload: payload, expected: .anyOutcome))
                    }
                }
            }

            let maxDepth = ManifestLimits().maxNestingDepth
            cases.append(Case(name: "\(maxDepth) nested arrays", seed: 0, payload: ManifestCorpus.nestedArrays(depth: maxDepth, closed: true),
                expected: .anyOutcome))
            for depth in [maxDepth + 1, 1_000, 10_000, 100_000] {
                for closed in [true, false] {
                    cases.append(Case(name: "\(depth) nested arrays, closed \(closed)", seed: 0,
                        payload: ManifestCorpus.nestedArrays(depth: depth, closed: closed), expected: .error(.undecodable(.nestingTooDeep))))
                }
            }
            let objects = String(repeating: "{\"a\":", count: 10_000) + "1" + String(repeating: "}", count: 10_000)
            cases.append(Case(name: "10,000 nested objects", seed: 0, payload: Data(objects.utf8), expected: .error(.undecodable(.nestingTooDeep))))
            let inEnvelope = "{\"schemaVersion\":1,\"x\":" + String(repeating: "[", count: 10_000) + "],\"assets\":[]}"
            cases.append(Case(name: "deep unknown envelope member", seed: 0, payload: Data(inEnvelope.utf8), expected: .error(.undecodable(.nestingTooDeep))))
            cases.append(contentsOf: Self.hugeStringCases(count: 65_536).map { $0() })
            return cases
        }

        private static let denseCaseName = "dense manifest at the limit"

        /// The limit-scale cases, one of each class at (just under) `payloadBytes`, each generated just before `body`
        /// sees it so that no two large payloads are alive at once.
        private static func forEachLimitCase(seed: UInt64, payloadBytes: Int, _ body: (Case) -> Void) {
            var random = SplitMix64(seed: seed ^ 0x3200_0000)
            for first in [nil, UInt8(ascii: "["), UInt8(ascii: "{")] as [UInt8?] {
                let caseSeed = random.next()
                body(Case(name: "random bytes at the limit", seed: caseSeed,
                    payload: ManifestCorpus.randomBytes(count: payloadBytes, seed: caseSeed, firstByte: first), expected: .anyOutcome))
            }
            body(Case(name: "nesting at the limit", seed: 0, payload: ManifestCorpus.nestedArrays(depth: payloadBytes / 2, closed: true),
                expected: .error(.undecodable(.nestingTooDeep))))

            // Room for the mutations' insertions.
            let denseSeed = random.next()
            let dense = ManifestCorpus.manifest(maxBytes: payloadBytes - 4_096, seed: denseSeed)
            body(Case(name: Self.denseCaseName, seed: denseSeed, payload: dense.data, expected: .accepted(dense.entryCount),
                largeRequests: Self.largeRequests(acceptedEntries: dense.entryCount)))
            let cutSeed = random.next()
            let cut = dense.data.count / 2 + Int(cutSeed % UInt64(dense.data.count / 2))
            body(Case(name: "dense manifest truncated", seed: cutSeed, payload: dense.data.prefix(cut), expected: .error(.undecodable(.notJSON))))
            for edits in [1, 8, 64] {
                let caseSeed = random.next()
                body(Case(name: "dense manifest with \(edits) edits", seed: caseSeed,
                    payload: ManifestCorpus.mutated(dense.data, count: edits, seed: caseSeed), expected: .anyOutcome))
            }
            for make in Self.hugeStringCases(count: payloadBytes - 256) {
                body(make())
            }

            // The allocation worst cases: heap strings and entries as dense as a valid manifest allows, padded until the
            // allocation estimate reaches its limit, and measured after freeing blocks just under twice the size of the
            // decoder's entry array and identifier index, which the allocator then serves them from (verifier round 3:
            // such reuse read 4.18x before the estimate counted it, ADR draft A-8).
            let entryCount = min(100_000, payloadBytes / 150)
            let keepFirst = ManifestDecodingOptions(duplicates: .keepFirst)
            body(Case(name: "minimal entries of 16-byte strings, at the estimate's limit", seed: 0,
                payload: ManifestCorpus.paddedToEstimateLimit(ManifestCorpus.shortStringEntries(length: 16, count: entryCount)),
                expected: .accepted(entryCount), largeRequests: Self.largeRequests(acceptedEntries: entryCount)))
            // The same under keepFirst: the survey also keeps every distinct accepted identifier.
            body(Case(name: "minimal entries of 16-byte strings, keepFirst, at the estimate's limit", seed: 0,
                payload: ManifestCorpus.paddedToEstimateLimit(ManifestCorpus.shortStringEntries(length: 16, count: entryCount), options: keepFirst),
                expected: .accepted(entryCount), options: keepFirst, largeRequests: Self.largeRequests(acceptedEntries: entryCount)))
            // Verifier round 3's reproductions: inline identifiers with 16-byte strings in per-entry arrays.
            let arrayShapes: [(name: String, count: Int, components: Int, tags: Int, longStrings: Bool)] = [
                ("one 16-byte path component and one 16-byte tag", entryCount, 1, 1, false),
                ("three 16-byte path components", entryCount, 3, 0, false),
                ("three 16-byte strings and three 16-byte path components", entryCount * 3 / 5, 3, 0, true),
                ("minimal entries", entryCount, 0, 0, false),
            ]
            for shape in arrayShapes {
                let payload = ManifestCorpus.arrayStringEntries(count: shape.count, components: shape.components, tags: shape.tags, longStrings: shape.longStrings)
                body(Case(name: "\(shape.count) entries with \(shape.name), at the estimate's limit", seed: 0,
                    payload: ManifestCorpus.paddedToEstimateLimit(payload), expected: .accepted(shape.count),
                    largeRequests: Self.largeRequests(acceptedEntries: shape.count)))
            }
            body(Case(name: "16-byte path components", seed: 0, payload: ManifestCorpus.shortComponentEntries(length: 16, maxBytes: payloadBytes),
                expected: .overAllocationBudget))
            // The densest component shape the estimate accepts: 25-byte strings (64-byte blocks) in 32-element arrays
            // (640-byte blocks) estimate 2.94x; 24-byte ones estimate 3.03x and are rejected (fix round 2).
            body(Case(name: "25-byte path components", seed: 0, payload: ManifestCorpus.shortComponentEntries(length: 25, maxBytes: payloadBytes),
                expected: .anyOutcome))
            // Tag arrays just within the allocator's 16-byte-quantum class (61 tags: 1,008 bytes) and just past it (64
            // tags: 1,056 bytes, served in 512-byte quanta), with little payload around them.
            for tagCount in [61, 64] {
                body(Case(name: "\(tagCount) one-byte tags per entry", seed: 0,
                    payload: ManifestCorpus.taggedEntries(tagCount: tagCount, padding: 64, maxBytes: payloadBytes), expected: .anyOutcome))
            }
            // String arrays just past a size class of the segregated allocator (31 and 32 elements: 528- and 544-byte
            // requests served from 640-byte blocks), padded until the allocation estimate reaches its limit: the most
            // decoded heap per payload byte that the decoder accepts (fix round 2).
            let sizeClassCount = payloadBytes / 640
            body(Case(name: "32 empty path components and 31 one-byte tags per entry, at the estimate's limit", seed: 0,
                payload: ManifestCorpus.paddedToEstimateLimit(ManifestCorpus.sizeClassEntries(components: 32, tags: 31, count: sizeClassCount)),
                expected: .accepted(sizeClassCount), largeRequests: Self.largeRequests(acceptedEntries: sizeClassCount)))
            let tagClassCount = payloadBytes / 340
            body(Case(name: "31 one-byte tags per entry, at the estimate's limit", seed: 0,
                payload: ManifestCorpus.paddedToEstimateLimit(ManifestCorpus.sizeClassEntries(components: 0, tags: 31, count: tagClassCount)),
                expected: .accepted(tagClassCount), largeRequests: Self.largeRequests(acceptedEntries: tagClassCount)))

            // Elements that are not objects: each is a quarantine for two or three payload bytes, counted exactly, with a
            // bounded number of diagnostics (orchestrator decision 2, fix round 3).
            let maxEntries = ManifestLimits().maxEntries
            for element in ["1", "null", "[]", "\"\"", "{}"] {
                body(Case(name: "\(maxEntries) elements \(element)", seed: 0, payload: ManifestCorpus.repeatedElements(element, count: maxEntries),
                    expected: .allQuarantined(maxEntries)))
            }
            // Elements that are identifiers alone: each is quarantined, and its identifier still takes part in the duplicate
            // rule (ADR draft A-4.3), so the survey's identifier table holds every one of them: 4-byte slots, at most half
            // full (fix round 3).
            let identifiersOnly = (0..<maxEntries).map { "{\"identifier\":\"\(String($0, radix: 36))\"}" }.joined(separator: ",")
            body(Case(name: "\(maxEntries) elements that are an identifier alone", seed: 0, payload: Data(("[" + identifiersOnly + "]").utf8),
                expected: .allQuarantined(maxEntries)))
            // The legacy manifest's policy (keepFirst) with every entry repeating one identifier: the survey cannot
            // build identifiers, yet must not count the repeats as accepted entries.
            let duplicateCount = min(maxEntries, payloadBytes / 100)
            body(Case(name: "\(duplicateCount) minimal entries sharing one identifier, keepFirst", seed: 0,
                payload: ManifestCorpus.duplicateEntries(count: duplicateCount),
                expected: .acceptedAndQuarantined(accepted: 1, quarantined: duplicateCount - 1),
                options: ManifestDecodingOptions(duplicates: .keepFirst)))
        }

        /// One entry with a string of about `count` bytes in each place a manifest can hold one, each made on demand.
        private static func hugeStringCases(count: Int) -> [() -> Case] {
            let units = count / 8
            let make = { (name: String, payload: @escaping () -> Data, expected: Expected) -> () -> Case in
                { Case(name: name, seed: 0, payload: payload(), expected: expected) }
            }
            return [
                make("huge unknown member", { ManifestCorpus.hugeString(in: "blurHash", unit: "abcdefgh", count: units) }, .accepted(1)),
                make("huge identifier", { ManifestCorpus.hugeString(in: "identifier", unit: "abcdefgh", count: units) },
                    .quarantined(.identifierTooLong(bytes: units * 8))),
                make("huge remotePath", { ManifestCorpus.hugeString(in: "remotePath", unit: "abcdefgh", count: units) },
                    .quarantined(.remotePathInvalid(.tooLong(bytes: units * 8)))),
                make("huge localFileName", { ManifestCorpus.hugeString(in: "localFileName", unit: "abcdefgh", count: units) }, .accepted(1)),
                make("huge path component", { ManifestCorpus.hugeString(in: "localPathComponents", unit: "abcdefgh", count: units, inArray: true) },
                    .accepted(1)),
                make("huge tag", { ManifestCorpus.hugeString(in: "tags", unit: "abcdefgh", count: units, inArray: true) }, .quarantined(.tagInvalid)),
                make("huge checksum", { ManifestCorpus.hugeString(in: "checksum", unit: "abcdef01", count: units) }, .quarantined(.checksumInvalid)),
                make("huge escaped localFileName", { ManifestCorpus.hugeString(in: "localFileName", unit: "\\u00e9\\n", count: count / 8) },
                    .accepted(1)),
                make("huge multi-byte unknown member", { ManifestCorpus.hugeString(in: "note", unit: "é日😀", count: count / 9) }, .accepted(1)),
                make("huge unterminated string", { ManifestCorpus.hugeString(in: "blurHash", unit: "abcdefgh", count: units, terminated: false) },
                    .error(.undecodable(.notJSON))),
            ]
        }

        /// The two largest requests of a decode that accepts `count` entries: the entry array and the identifier index
        /// (ADR draft A-8), as malloc sizes.
        private static func largeRequests(acceptedEntries count: Int) -> [Int] {
            let entries = 32 + count * MemoryLayout<ManifestEntry>.stride
            var buckets = 2
            while buckets * 3 / 4 < count {
                buckets *= 2
            }
            let index = 64 + (buckets + 63) / 64 * 8 + buckets * (MemoryLayout<AssetID>.stride + MemoryLayout<Int>.stride)
            return [entries, index]
        }

        // MARK: - Checks

        private static func decode(_ payload: Data, options: ManifestDecodingOptions = ManifestDecodingOptions()) -> Result<ValidatedManifest, ManifestError> {
            do throws(ManifestError) {
                return .success(try ManifestDecoder.decode(payload, options: options))
            } catch {
                return .failure(error)
            }
        }

        /// The case's expectation, and on success the invariants every decoded manifest keeps.
        private static func check(_ fuzzCase: Case, outcome: Result<ValidatedManifest, ManifestError>) {
            let label = "\(fuzzCase.name) seed \(fuzzCase.seed)"
            switch (fuzzCase.expected, outcome) {
            case (.anyOutcome, .failure):
                break
            case (.error(let expected), .failure(let error)):
                #expect(error == expected, "\(label)")
            case (.error(let expected), .success(let manifest)):
                Issue.record("\(label): expected \(expected), decoded \(manifest.count) entries")
            case (.quarantined(let violation), .success(let manifest)):
                #expect(manifest.count == 0, "\(label)")
                #expect(manifest.quarantined.map(\.violation) == [violation], "\(label)")
            case (.accepted(let count), .success(let manifest)):
                #expect(manifest.count == count, "\(label)")
                #expect(manifest.quarantined.isEmpty, "\(label): \(manifest.quarantined.prefix(3))")
            case (.acceptedAndQuarantined(let accepted, let quarantined), .success(let manifest)):
                #expect(manifest.count == accepted, "\(label)")
                #expect(manifest.quarantinedCount == quarantined, "\(label)")
                #expect(manifest.quarantined.count == min(quarantined, ManifestLimits().maxQuarantineDiagnostics), "\(label)")
            case (.allQuarantined(let quarantined), .success(let manifest)):
                #expect(manifest.count == 0 && manifest.quarantinedCount == quarantined, "\(label)")
                #expect(manifest.quarantined.count == min(quarantined, ManifestLimits().maxQuarantineDiagnostics), "\(label)")
            case (.overAllocationBudget, .failure(let error)):
                guard case .decodedSizeExceeded(let estimated, let limit) = error else {
                    Issue.record("\(label): expected the allocation bound, got \(error)")
                    break
                }
                #expect(estimated > limit && limit <= 4 * Int64(fuzzCase.payload.count), "\(label): \(error)")
            case (.overAllocationBudget, .success(let manifest)):
                Issue.record("\(label): expected the allocation bound, decoded \(manifest.count) entries")
            case (.allQuarantined, .failure(let error)):
                Issue.record("\(label): expected a quarantine, got \(error)")
            case (_, .failure(let error)):
                Issue.record("\(label): expected a manifest, got \(error)")
            case (.anyOutcome, .success):
                break
            }
            if case .success(let manifest) = outcome {
                Self.checkInvariants(manifest, payload: fuzzCase.payload, label: label)
            }
        }

        /// Accepted entries are unique, indexed, and break no rule; quarantine indices ascend; the digest is the
        /// payload's.
        private static func checkInvariants(_ manifest: ValidatedManifest, payload: Data, label: String) {
            let limits = ManifestLimits()
            #expect(manifest.digest == ContentHash.sha256(of: payload), "\(label)")
            #expect(manifest.count + manifest.quarantinedCount <= limits.maxEntries, "\(label)")
            #expect(manifest.quarantined.count <= min(manifest.quarantinedCount, limits.maxQuarantineDiagnostics), "\(label)")
            let indices = manifest.quarantined.map(\.index)
            #expect(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 }, "\(label)")
            var broken = 0
            for (position, entry) in manifest.entries.enumerated()
            where manifest.position(of: entry.identifier) != position || !ManifestDecoder.violations(of: entry, limits: limits).isEmpty {
                broken += 1
            }
            #expect(broken == 0, "\(label): \(broken) accepted entries are not indexed or break a rule")
        }
    }
}
