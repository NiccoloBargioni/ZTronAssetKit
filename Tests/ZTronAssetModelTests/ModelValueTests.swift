import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-7: Model types are `Sendable` value types, `Hashable`/`Codable` where meaningful, and perform no I/O
    /// (the I/O half is the source scan in `EnvironmentScanTests`).
    @Suite("Model values")
    struct ModelValueTests {
        /// One value of a Codable Model type and a check that it survives a JSON round trip.
        struct Sample: Sendable {
            var name: String
            var roundTrips: @Sendable () throws -> Bool
        }

        private static func sample<Value: Codable & Hashable & Sendable>(_ value: Value) -> Sample {
            Sample(name: "\(Value.self)") {
                let data = try JSONEncoder().encode(value)
                let decoded = try JSONDecoder().decode(Value.self, from: data)
                // Equal, and hashing agrees with equality.
                return decoded == value && Set([decoded, value]).count == 1
            }
        }

        @Test("R-MAN-7: every Model value round-trips through Codable where declared and is usable across tasks without isolation", .timeLimit(.minutes(1)))
        func valuesRoundTripAcrossTasks() async throws {
            let samples = try Self.codableSamples()
            #expect(samples.count >= 70)
            for sample in samples {
                #expect(try sample.roundTrips(), "\(sample.name)")
            }
            // The same values, sent to child tasks that run on the cooperative pool with no isolation.
            let results = await withTaskGroup(of: (String, Bool).self) { group in
                for sample in samples {
                    group.addTask { (sample.name, (try? sample.roundTrips()) ?? false) }
                }
                var collected: [(String, Bool)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            #expect(results.count == samples.count)
            #expect(results.filter { !$0.1 }.map(\.0).isEmpty)

            // Model values that are not Codable are still Sendable (a compile-time check) and comparable.
            let manifest = try ManifestDecoder.decode(Data(#"[{"identifier":"a","fileExtension":"png","remotePath":"m/a","localPathComponents":[]}]"#.utf8))
            let sent = await Task.detached { manifest }.value
            #expect(sent == manifest)
            // The real check is at compile time: `requireSendable` accepts only `Sendable` types.
            _ = [
                Self.requireSendable(ValidatedManifest.self), Self.requireSendable(ManifestDiff.self),
                Self.requireSendable(QuarantinedEntry.self), Self.requireSendable(ManifestError.self),
                Self.requireSendable(ManifestLimits.self), Self.requireSendable(ManifestDecodingOptions.self),
                Self.requireSendable(ManifestWireShape.self), Self.requireSendable(ContentIdentity.self),
                Self.requireSendable(AssetFileExtension.self), Self.requireSendable(LogLine.self),
                Self.requireSendable(LogIntervalEvent.self), Self.requireSendable(LogInterval.self),
                Self.requireSendable(LogRoute.self), Self.requireSendable(AssetEnvironment.self),
                Self.requireSendable(TransferRequest.self), Self.requireSendable(AssetEvent.self),
            ] as [Any.Type]
        }

        private static func requireSendable<Value: Sendable>(_ type: Value.Type) -> Any.Type {
            type
        }

        /// One or more values of every Codable type the Model declares.
        private static func codableSamples() throws -> [Sample] {
            let hash = ContentHash.sha256(of: Data("bytes".utf8))
            let date = Date(timeIntervalSince1970: 1_700_000_000.5)
            let etag = try #require(ETag(rawValue: "\"v1-abc\""))
            let attempt = TransferAttempt(epoch: 7, sequence: 3)
            let staging = StagingFileName(transfer: .content(hash), attempt: attempt, kind: .partial)
            let entry = ManifestEntry(
                identifier: "bo7.ri.map", fileExtension: "PNG", remotePath: "m/x.png", localPathComponents: ["A", "B"],
                localFileName: "Map", byteSize: 12, checksum: hash, tags: ["t"], policy: .onDemand
            )
            var counts = FailureCounts()
            counts[.offline] = 2
            counts[.integrity] = 1
            var metrics = MetricsSnapshot()
            metrics.bytesDownloaded = 99
            let conditions = DeviceConditions(
                network: NetworkConditions(satisfied: true, expensive: false, constrained: true),
                power: PowerConditions(lowPowerMode: true, thermal: .serious)
            )
            let report = SyncReport(
                runID: SyncRunID(rawValue: 4), trigger: .explicit, startedAt: date, finishedAt: date.addingTimeInterval(3),
                manifestFresh: true, planned: PlanTotals(fetchCount: 2, fetchBytes: 10), fetched: 2, reused: 1, relocated: 0,
                pruned: 1, evicted: 0, failedCount: 1, bytesDownloaded: 10,
                failures: [AssetFailure(id: "a", error: .notFound, failureClass: .notFound)]
            )
            var samples: [Sample] = [
                Self.sample(AssetID("bo7.ri.é")), Self.sample(hash), Self.sample(TransferID.content(hash)),
                Self.sample(TransferID.legacy(identifier: "a", remotePath: "m/a")), Self.sample(TransferID.manifest), Self.sample(attempt),
                Self.sample(staging), Self.sample(entry), Self.sample(ManifestEntry(identifier: "x", fileExtension: "a", remotePath: "p")),
                Self.sample(ResumePoint(previous: staging, offset: 9, validator: .strongETag(etag))),
                Self.sample(ResumeValidator.lastModified("Wed, 21 Oct 2015 07:28:00 GMT")),
                Self.sample(ResumeSidecar(name: staging, validator: .strongETag(etag), receivedBytes: 4, expectedBytes: nil)),
                Self.sample(etag), Self.sample(AssetScope.all), Self.sample(AssetScope.identifiers(["a", "b"])),
                Self.sample(AssetScope.tags(["t"])), Self.sample(AssetScope.prefix("bo7.")), Self.sample(MonotonicInstant(nanoseconds: 42)),
                Self.sample(conditions), Self.sample(DeviceConditions.unrestricted), Self.sample(NetworkPolicy()), Self.sample(PowerPolicy()),
                Self.sample(RetryPolicy.background), Self.sample(RetryPolicy.interactive), Self.sample(CircuitBreakerPolicy()),
                Self.sample(SyncTuning()), Self.sample(StorageBudget.unlimited), Self.sample(StorageBudget.bytes(5)),
                Self.sample(StorageBudget.fractionOfFreeSpace(0.25)), Self.sample(RefreshPolicy.oncePerAppVersion),
                Self.sample(RefreshPolicy.everyLaunch), Self.sample(RefreshPolicy.atMostEvery(3_600)), Self.sample(SyncMode.ifDue),
                Self.sample(SyncMode.force), Self.sample(report), Self.sample(PlanTotals()), Self.sample(SyncTrigger.breakerClosed),
                Self.sample(SyncProgress(fraction: 0.5, completedCount: 1, totalCount: 2, bytesReceived: 3, bytesExpected: 6)),
                Self.sample(TransferProgress(received: 3, expected: nil)), Self.sample(RemovalReason.vanished),
                Self.sample(MaintenanceReport(gcBytes: 1, evictedBytes: 2, verifiedBytes: 3, corruptFound: 0, budgetExhausted: true)),
                Self.sample(SyncStamp(appVersion: "1.0+1", completedAt: date, manifestETag: etag, manifestDigest: hash)),
                Self.sample(AvailabilityReport(
                    scope: .prefix("bo7"), total: 3, present: 1, missing: 1, stale: 1, failed: 0, unverified: 0, bytesMissing: 5,
                    manifestFresh: false, generation: 9
                )),
                Self.sample(StorageReport(
                    bytesByKind: ["png": 3], bytesByState: ResidencyBytes(present: 3, stale: 0, pendingDeletion: 1), pinnedBytes: 0,
                    essentialBytes: 3, evictableBytes: 0, stagingBytes: 2, orphanBytes: 0, sourceCopyBytes: 0, budgetBytes: 100,
                    freeBytesImportant: 1_000, freeBytesOpportunistic: 500, unverifiedCount: 0, lastCleanupAt: nil
                )),
                Self.sample(PurgeRequest.all), Self.sample(PurgeRequest.evictable), Self.sample(PurgeRequest.scope(.tags(["t"]))),
                Self.sample(PurgeResult(bytesFreed: 1, bytesDeferred: 2, assetsRemoved: 3)), Self.sample(counts), Self.sample(metrics),
                Self.sample(DiagnosticError(at: date, id: nil, failureClass: .rejected, detail: "host not allowed")),
                Self.sample(AssetError.insufficientSpace(required: 5, available: 1)), Self.sample(AssetError.serverUnavailable(retryAfter: 7)),
                Self.sample(AssetError.authRejected(.ambiguous)), Self.sample(AssetError.storageUnavailable(.degradedReadOnly)),
                Self.sample(AssetError.shutDown),
            ]
            samples += AssetPolicy.allCases.map(Self.sample) + AssetPriority.allCases.map(Self.sample)
                + ThermalLevel.allCases.map(Self.sample) + LogCategory.allCases.map(Self.sample) + LogLevel.allCases.map(Self.sample)
                + LogIntervalName.allCases.map(Self.sample) + FailureClass.allCases.map(Self.sample) + AssetTier.allCases.map(Self.sample)
                + [AssetIntegrity.verified, .unverified].map(Self.sample) + [BreakerCause.authentication, .serverErrors].map(Self.sample)
                + [AuthRejection.confirmed, .ambiguous].map(Self.sample) + [StorageUnavailableReason.locked, .ioFailure].map(Self.sample)
            return samples
        }
    }
}
