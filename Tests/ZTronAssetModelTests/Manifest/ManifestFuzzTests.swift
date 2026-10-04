import Foundation
import Testing
import ZTronAssetModel

/// R-MAN-3: fuzzed input never traps, and at the 32 MiB payload limit the decoder stays within 1 s and 4x the
/// payload.
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
@Suite("Manifest fuzz")
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
    }

    /// One fuzz input.
    struct Case {
        var name: String
        var seed: UInt64
        var payload: Data
        var expected: Expected
    }

    private static let baseSeed: UInt64 = {
        if let text = ProcessInfo.processInfo.environment["ZTRON_MANIFEST_FUZZ_SEED"], let seed = UInt64(text) {
            return seed
        }
        return 0x5EED_0000_0003
    }()

    @available(macOS 15.0, *)
    @Test("R-MAN-3: seeded fuzz of random, truncated, mutated and deeply nested manifests never traps and stays within 1 s and 4x the payload")
    func seededFuzzStaysWithinBounds() throws {
        let seed = Self.baseSeed
        print("R-MAN-3 fuzz: base seed \(seed) (replay with ZTRON_MANIFEST_FUZZ_SEED=\(seed))")
        let small = try Self.smallCorpus(seed: seed)
        #expect(small.count > 1_000)
        for fuzzCase in small {
            Self.check(fuzzCase, outcome: Self.decode(fuzzCase.payload))
        }

        let tsan = DecodeMeasurement.underThreadSanitizer
        let limit = tsan ? 1 << 20 : ManifestCorpus.payloadLimit
        var denseCPU: (small: Double, limit: Double)?
        var limitCases = 0
        Self.forEachLimitCase(seed: seed, payloadBytes: limit) { fuzzCase in
            limitCases += 1
            #expect(fuzzCase.payload.count <= ManifestCorpus.payloadLimit, "\(fuzzCase.name) seed \(fuzzCase.seed)")
            let (outcome, cost) = DecodeMeasurement.measure { Self.decode(fuzzCase.payload) }
            Self.check(fuzzCase, outcome: outcome)
            guard !tsan else {
                return
            }
            let label = "\(fuzzCase.name) seed \(fuzzCase.seed): \(fuzzCase.payload.count) bytes, cpu \(cost.cpuSeconds) s, peak \(cost.peakHeapGrowth) B"
            #expect(cost.peakHeapGrowth <= 4 * fuzzCase.payload.count, "\(label)")
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
        #expect(limitCases == 19)
        if !tsan {
            // Linear time: 32x the bytes may cost at most 64x the CPU of the 1 MiB manifest (a quadratic path would
            // cost about 1,000x).
            let dense = try #require(denseCPU)
            #expect(dense.limit <= 64 * dense.small, "dense 1 MiB \(dense.small) s vs limit \(dense.limit) s")
        }
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
        body(Case(name: Self.denseCaseName, seed: denseSeed, payload: dense.data, expected: .accepted(dense.entryCount)))
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

    // MARK: - Checks

    private static func decode(_ payload: Data) -> Result<ValidatedManifest, ManifestError> {
        do throws(ManifestError) {
            return .success(try ManifestDecoder.decode(payload))
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
        #expect(manifest.count + manifest.quarantined.count <= limits.maxEntries, "\(label)")
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
