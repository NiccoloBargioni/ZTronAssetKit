import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// The small pure functions of the Model that other layers rely on: budgets, backoff, clamping, orderings,
    /// textual forms and the live clock's contract.
    @Suite("Model behaviour")
    struct ModelBehaviourTests {
        @Test("R-SYN-11: a storage budget resolves to bytes, a capped fraction of used plus free space, or unlimited without overflow")
        func storageBudgetResolves() {
            #expect(StorageBudget.unlimited.resolve(usedBytes: 10, availableBytes: 10) == Int64.max)
            #expect(StorageBudget.bytes(500).resolve(usedBytes: 10, availableBytes: 10) == 500)
            #expect(StorageBudget.bytes(-5).resolve(usedBytes: 10, availableBytes: 10) == 0)
            #expect(StorageBudget.fractionOfFreeSpace(0.25).resolve(usedBytes: 100, availableBytes: 300) == 100)
            #expect(StorageBudget.fractionOfFreeSpace(4).resolve(usedBytes: 100, availableBytes: 300) == 400)
            #expect(StorageBudget.fractionOfFreeSpace(0.5).resolve(usedBytes: -100, availableBytes: 300) == 150)
            for degenerate in [0, -0.5, Double.nan, Double.infinity] {
                #expect(StorageBudget.fractionOfFreeSpace(degenerate).resolve(usedBytes: 100, availableBytes: 300) == 0, "\(degenerate)")
            }
            #expect(StorageBudget.fractionOfFreeSpace(1).resolve(usedBytes: Int64.max, availableBytes: Int64.max) == Int64.max)
        }

        @Test("R-INT-3: integrity backoff grows by the multiplier per attempt and ends at maxIntegrityAttempts")
        func integrityBackoffGrowsThenStops() {
            let policy = StoragePolicy(maxIntegrityAttempts: 3, integrityBackoffBase: 60, integrityBackoffMultiplier: 10)
            #expect(policy.integrityBackoff(afterAttempt: 0) == nil)
            #expect(policy.integrityBackoff(afterAttempt: 1) == 60)
            #expect(policy.integrityBackoff(afterAttempt: 2) == 600)
            #expect(policy.integrityBackoff(afterAttempt: 3) == nil)
            #expect(policy.integrityBackoff(afterAttempt: 4) == nil)
        }

        @Test("R-SYN-3: SyncTuning clamps every out-of-range knob and names each field it clamped")
        func tuningClampsEveryKnob() {
            let wild = SyncTuning(
                maxConcurrentTransfers: 99, reservedInteractiveSlots: 50, pipelineDepth: 0, progressInterval: -1,
                unknownIDCacheCapacity: 0, runLookahead: -3, snapshotInstallInterval: .nan
            ).clamped()
            #expect(wild.tuning.maxConcurrentTransfers == 16)
            #expect(wild.tuning.reservedInteractiveSlots == 15)
            #expect(wild.tuning.pipelineDepth == 1)
            #expect(wild.tuning.progressInterval == 0.1)
            #expect(wild.tuning.unknownIDCacheCapacity == 1)
            #expect(wild.tuning.runLookahead == 0)
            #expect(wild.tuning.snapshotInstallInterval == 0.1)
            #expect(wild.clampedFields == [
                "maxConcurrentTransfers", "reservedInteractiveSlots", "pipelineDepth", "progressInterval", "unknownIDCacheCapacity",
                "runLookahead", "snapshotInstallInterval",
            ])
            let single = SyncTuning(maxConcurrentTransfers: 0, reservedInteractiveSlots: 1).clamped()
            #expect(single.tuning.maxConcurrentTransfers == 1 && single.tuning.reservedInteractiveSlots == 0)
            #expect(SyncTuning().clamped().clampedFields.isEmpty)
            #expect(SyncTuning().clamped().tuning == SyncTuning())
        }

        @Test("R-SYN-2: progress is the only transfer update that does not end a transfer stream")
        func onlyProgressIsNonTerminal() throws {
            let name = StagingFileName(transfer: .manifest, attempt: TransferAttempt(epoch: 1, sequence: 1), kind: .partial)
            #expect(!TransferUpdate.progress(received: 1, expected: 2).isTerminal)
            #expect(TransferUpdate.staged(StagedFile(name: name, byteCount: 2, resumed: false, httpStatus: 200, etag: nil)).isTerminal)
            #expect(TransferUpdate.paused(resumable: true).isTerminal)
            #expect(TransferUpdate.failed(.cancelled(.byClient)).isTerminal)
        }

        @Test("R-SYN-1: identifiers, transfers, attempts, staging names, extensions and levels order deterministically")
        func orderingsAreTotalAndStable() throws {
            #expect([AssetID("b"), AssetID("B"), AssetID("a"), AssetID("é")].sorted() == ["B", "a", "b", "é"])
            let hash = ContentHash.sha256(of: Data([1]))
            let ids = [TransferID.manifest, .content(hash), .legacy(identifier: "a", remotePath: "p")]
            #expect(ids.sorted().map(\.kind) == [.content, .legacy, .manifest])
            let early = TransferAttempt(epoch: 1, sequence: 9)
            let late = TransferAttempt(epoch: 2, sequence: 0)
            #expect(early < late && TransferAttempt(epoch: 1, sequence: 1) < early)
            let partial = StagingFileName(transfer: .content(hash), attempt: early, kind: .partial)
            #expect([partial.with(kind: .verifying), partial].sorted() == [partial, partial.with(kind: .verifying)])
            #expect(partial.with(kind: .sidecar).kind == .sidecar && partial.with(kind: .sidecar).attempt == early)
            #expect([AssetFileExtension("PNG"), AssetFileExtension("heic")].compactMap { $0 }.sorted().map(\.description) == ["heic", "png"])
            #expect(LogLevel.allCases.sorted() == [.debug, .info, .error, .fault] && LogLevel.debug < .fault)
            #expect(MemoryPressureLevel.allCases.sorted() == [.warning, .critical] && MemoryPressureLevel.warning < .critical)
            #expect(ThermalLevel.allCases.sorted() == [.nominal, .fair, .serious, .critical] && ThermalLevel.fair < .serious)
            #expect([SyncRunID(rawValue: 3), SyncRunID(rawValue: 1)].sorted() == [SyncRunID(rawValue: 1), SyncRunID(rawValue: 3)])
        }

        @Test("R-NET-1: identity values render as their wire text and invalid wire text fails to decode")
        func textualFormsAndDecodingFailures() throws {
            let hash = ContentHash.sha256(of: Data([7]))
            let attempt = TransferAttempt(epoch: 7, sequence: 3)
            let name = StagingFileName(transfer: .content(hash), attempt: attempt, kind: .partial)
            #expect(TransferID.content(hash).description == "c-" + hash.hex)
            #expect(attempt.description == attempt.token && TransferAttempt(token: attempt.token) == attempt)
            #expect(name.description == name.rawValue && name.rawValue.hasSuffix(".part"))
            #expect(SyncRunID(rawValue: 4).description == "run-4")
            #expect(MonotonicInstant(nanoseconds: 42).description == "42ns")
            #expect(try #require(ETag(rawValue: "\"v1\"")).description == "\"v1\"")
            #expect(AssetID(rawValue: "a.b").rawValue == "a.b" && AssetID(rawValue: "a.b").description == "a.b")
            for (type, text) in [("TransferID", "\"x-1\""), ("StagingFileName", "\"foreign.tmp\""), ("ETag", "\"\""), ("ContentHash", "\"abc\"")] {
                let data = Data(text.utf8)
                let decoded: Bool
                switch type {
                case "TransferID":
                    decoded = (try? JSONDecoder().decode(TransferID.self, from: data)) != nil
                case "StagingFileName":
                    decoded = (try? JSONDecoder().decode(StagingFileName.self, from: data)) != nil
                case "ETag":
                    decoded = (try? JSONDecoder().decode(ETag.self, from: data)) != nil
                default:
                    decoded = (try? JSONDecoder().decode(ContentHash.self, from: data)) != nil
                }
                #expect(!decoded, "\(type) decoded \(text)")
            }
        }

        /// Stage 3 (S3AH-2, S3-SECU-03): a name the module never writes (an attempt token with a leading zero) is
        /// foreign. Parsed leniently, `c-<h>.01-2.part` became `c-<h>.1-2.part`, another file: staging GC kept it under
        /// the age rules instead of removing it as foreign, and two directory entries collapsed onto one inventory key.
        @Test(
            "R-SEC-2: staging names and attempt tokens parse only in the canonical spelling the module writes",
            arguments: ["01-2", "1-02", "00-0", "0-00", "007-1", "1-0010", "00000000000000000001-1"]
        )
        func nonCanonicalTokensAreForeign(_ token: String) {
            let hash = String(repeating: "a", count: 64)
            #expect(TransferAttempt(token: token) == nil, "\(token)")
            for kind in StagingFileName.Kind.allCases {
                let fileName = "c-\(hash).\(token).\(kind.rawValue)"
                #expect(StagingFileName(parsing: fileName) == nil, "\(fileName) parsed as \(StagingFileName(parsing: fileName)?.rawValue ?? "nil")")
            }
        }

        /// The converse: every token and staging name that parses names exactly the text it was parsed from, over a
        /// seeded set of digit-and-dash strings and every canonical edge (zero, the largest epoch and sequence).
        @Test("R-SEC-2: every staging name that parses round-trips to the same file name, and every attempt token to the same text")
        func parsedNamesRoundTrip() throws {
            let transfer = TransferID.content(ContentHash.sha256(of: Data([3])))
            for attempt in [TransferAttempt(epoch: 0, sequence: 0), TransferAttempt(epoch: 10, sequence: 20), TransferAttempt(epoch: .max, sequence: .max)] {
                #expect(TransferAttempt(token: attempt.token) == attempt)
                let name = StagingFileName(transfer: transfer, attempt: attempt, kind: .partial)
                #expect(StagingFileName(parsing: name.rawValue) == name)
            }
            #expect(try #require(StagingFileName(parsing: "c-zz.1-2.part")).rawValue == "c-zz.1-2.part")
            var random = SplitMix64(seed: 0x5EED_5EC0_0003)
            let alphabet = Array("0123456789-")
            var parsed = 0
            for _ in 0..<20_000 {
                let token = String((0..<Int.random(in: 1...6, using: &random)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] })
                guard let attempt = TransferAttempt(token: token) else {
                    continue
                }
                parsed += 1
                #expect(attempt.token == token, "\(token) parsed as \(attempt.token)")
                let fileName = "\(transfer.rawValue).\(token).resume"
                #expect(StagingFileName(parsing: fileName)?.rawValue == fileName, "\(fileName)")
            }
            #expect(parsed > 1_000)
        }

        @Test("R-ENV-1: monotonic instants measure elapsed seconds and never report negative time")
        func monotonicSeconds() {
            let start = MonotonicInstant(nanoseconds: 1_000)
            #expect(MonotonicInstant(nanoseconds: 2_500_001_000).seconds(since: start) == 2.5)
            #expect(start.seconds(since: MonotonicInstant(nanoseconds: 9_000)) == 0)
            #expect(start.seconds(since: start) == 0)
        }

        /// Stage 3 (S3AH-3, L4-R24(2)): `adding(seconds:)` rounds to the nearest nanosecond, so moving by the seconds
        /// between two instants lands on the later one. Truncation landed 1 ns short for about 3 % of gaps, and a
        /// deadline computed that way missed the instant it was derived from. A gap below 2^50 ns (13 days) survives
        /// the two roundings of `seconds(since:)` and the product (relative error at most 2^-52 each, so under 0.5 ns).
        @Test("R-ENV-1: adding the seconds between two instants lands exactly on the later one for every seeded gap below 2^50 ns")
        func secondsRoundTripExactly() {
            var random = SplitMix64(seed: 0x5EED_0000_0104)
            var gaps: [UInt64] = [0, 1, 999_999_999, 1_000_000_001, 1 << 50 - 1]
            for _ in 0..<20_000 {
                gaps.append(UInt64.random(in: 0..<(1 << UInt64.random(in: 1...50, using: &random)), using: &random))
            }
            var shortfalls = 0
            for gap in gaps {
                let start = MonotonicInstant(nanoseconds: UInt64.random(in: 0..<(1 << 62), using: &random))
                let target = MonotonicInstant(nanoseconds: start.nanoseconds + gap)
                if start.adding(seconds: target.seconds(since: start)) != target {
                    shortfalls += 1
                }
            }
            #expect(shortfalls == 0, "\(shortfalls) of \(gaps.count) gaps missed their target")
        }

        @Test("R-ENV-1: the live clock's readings never go backwards and a deadline already passed returns without sleeping", .timeLimit(.minutes(1)))
        func liveClockContract() async throws {
            // The wall clock (`now()`) is not read: tests never depend on it (fix round 2; ADR draft A-12 lists it as a
            // deliberately untested line). The monotonic and awake clocks are, for their order only.
            let clock = LiveTimeSource()
            let first = clock.monotonicNow()
            let awake = clock.uptimeNow()
            #expect(clock.monotonicNow() >= first)
            #expect(clock.uptimeNow() >= awake)
            // A deadline in the past: no sleep at all.
            try await clock.sleep(until: .zero)
            try await clock.sleep(until: first)
            // A far deadline in a cancelled task: Task.sleep throws as soon as the cancellation lands (before or during
            // the sleep), rethrown as CancellationError; nothing waits for the deadline.
            let sleeper = Task {
                do throws(CancellationError) {
                    try await clock.sleep(until: clock.monotonicNow().adding(seconds: 3_600))
                    return false
                } catch {
                    return true
                }
            }
            sleeper.cancel()
            #expect(await sleeper.value)
        }

        @Test("R-SYN-10: an availability report is complete only when nothing in scope is missing, stale or failed")
        func availabilityCompleteness() {
            let complete = AvailabilityReport(
                scope: .all, total: 3, present: 3, missing: 0, stale: 0, failed: 0, unverified: 1, bytesMissing: 0, manifestFresh: true,
                generation: 1
            )
            #expect(complete.isComplete)
            for (missing, stale, failed) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
                var report = complete
                report.missing = missing
                report.stale = stale
                report.failed = failed
                #expect(!report.isComplete)
            }
        }

        @Test("R-OBS-2: failure counts are read and written per class through one subscript")
        func failureCountsSubscript() {
            var counts = FailureCounts()
            for (index, failureClass) in FailureClass.allCases.enumerated() {
                counts[failureClass] = index + 1
            }
            #expect(FailureClass.allCases.map { counts[$0] } == Array(1...FailureClass.allCases.count))
            #expect(counts.offline == 1 && counts.storage == FailureClass.allCases.count)
        }

        @Test("R-NET-6: a 403's hint reads the body first: XML is a missing object, empty is a rejected key, else the manifest leans to the key")
        func forbiddenHintReadsTheBodyFirst() {
            let hint = { (purpose: TransferPurpose, bytes: Int64, xml: Bool) in
                ForbiddenEvidence(purpose: purpose, bodyBytes: bytes, contentTypeIsXML: xml, keyPresented: true, resumed: false).hint
            }
            #expect(hint(.manifest, 243, true) == .objectMissingLikely)
            #expect(hint(.asset, 243, true) == .objectMissingLikely)
            #expect(hint(.asset, 0, false) == .keyRejectedLikely)
            #expect(hint(.manifest, 12, false) == .keyRejectedLikely)
            #expect(hint(.asset, 12, false) == .undetermined)
        }

        @Test("R-MAN-5: content hashes parse hex in either case, order by their bytes and reject any other length")
        func contentHashParsing() throws {
            let lower = try #require(ContentHash(hex: String(repeating: "ab", count: 32)))
            #expect(ContentHash(hex: String(repeating: "AB", count: 32)) == lower)
            #expect(lower.description == String(repeating: "ab", count: 32))
            #expect(ContentHash(hex: String(repeating: "g", count: 64)) == nil)
            #expect(ContentHash(hex: String(repeating: "a", count: 63)) == nil)
            #expect(ContentHash(bytes: [UInt8](repeating: 1, count: 31)) == nil)
            let small = ContentHash(w0: 0, w1: 0, w2: 0, w3: 1)
            let large = ContentHash(w0: 1, w1: 0, w2: 0, w3: 0)
            #expect(small < large && [large, small].sorted() == [small, large])
            #expect(ContentHash(bytes: large.bytes) == large)
        }

        @Test("R-CAR-6: an entry's file name is its localFileName, else the last dot-segment of its identifier")
        func resolvedFileName() {
            #expect(ManifestEntry(identifier: "bo7.ri.map", fileExtension: "png", remotePath: "m", localFileName: "Temple Map").resolvedFileName == "Temple Map")
            #expect(ManifestEntry(identifier: "bo7.ri.map", fileExtension: "png", remotePath: "m").resolvedFileName == "map")
            #expect(ManifestEntry(identifier: "plain", fileExtension: "png", remotePath: "m").resolvedFileName == "plain")
            // The prior art's rule (`split(separator: ".")` drops empty segments, `CDNAsset.resolvedFileName`), which legacy
            // migration needs to find the files the prior art wrote.
            let priorArt = { (identifier: String) in identifier.split(separator: ".").last.map(String.init) ?? identifier }
            for (identifier, expected) in [("trailing.", "trailing"), (".", "."), ("a..b", "b"), ("", ""), ("..", ".."), (".hidden", "hidden")] {
                #expect(ManifestEntry(identifier: AssetID(identifier), fileExtension: "png", remotePath: "m").resolvedFileName == expected, "\(identifier)")
                #expect(priorArt(identifier) == expected, "\(identifier)")
            }
            let hash = ContentHash.sha256(of: Data([3]))
            #expect(ManifestEntry(identifier: "a", fileExtension: "png", remotePath: "m", checksum: hash).transferID == .content(hash))
        }
    }
}
