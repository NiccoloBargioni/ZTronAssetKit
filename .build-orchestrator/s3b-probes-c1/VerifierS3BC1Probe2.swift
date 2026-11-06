import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Verifier probe (not for commit): two reapers in time-bounded units (one unlink each) racing a rescuing apply.
@Suite("VerifierS3BC1Probe2")
struct VerifierS3BC1Probe2 {
    @Test("probe S3-PERF-04: concurrent reapers and a rescuing apply keep I-1 and unlink each key at most once", .timeLimit(.minutes(3)))
    @available(macOS 15.0, iOS 18.0, *)
    func concurrentReapers() async throws {
        for iteration in 0..<16 {
            let clock = SteppingClock()
            let fake = FakeFileSystem(time: clock.base)
            let metadata = DispatchBlockingExecutor(label: "probe.metadata.\(iteration)")
            let store = AssetStore(
                configuration: CoreFixture.configuration(deletionBatchSize: 2 + iteration % 4),
                environment: CoreHarness.environment(fileSystem: fake, time: clock, metadata: metadata)
            )
            _ = try await store.open()
            let payloads = (0..<48).map { CoreFixture.bytes(30_000 + UInt64($0) + UInt64(iteration * 100), count: 16) }
            let entries = payloads.enumerated().map { CoreFixture.entry("r\($0.offset)", $0.element) }
            _ = try await store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
            let sink = try await store.makeStagingSink()
            for (index, (bytes, entry)) in zip(payloads, entries).enumerated() {
                let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: UInt32(index + 1)), kind: .partial)
                try sink.createPartial(name)
                _ = try sink.appendPartial(bytes, to: name)
                _ = try await store.publish(StagedFile(name: name, byteCount: 16, resumed: false, httpStatus: nil, etag: nil), binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
            }
            _ = try await store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
            clock.base.advance(by: 10)
            await store.runDueWorkInstallOnly()
            clock.setStepping(true)
            let readded = entries.enumerated().filter { $0.offset % 3 == iteration % 3 }.map(\.element)
            async let first = store.reapDeletable(maxKeys: .max)
            async let second = store.reapDeletable(maxKeys: .max)
            async let rescue: ApplyReport = store.apply(CoreFixture.manifest(readded, etagSeed: "re\(iteration)"), etag: nil, eviction: nil)
            let (a, b, report) = try await (first, second, rescue)
            clock.setStepping(false)
            // I-1: every record bound to a blob has its file.
            for entry in readded {
                let record = await store.state.core.records[entry.identifier]
                if let blob = record?.referencedBlob {
                    let info = try? fake.itemInfo(at: CoreFixture.layout.blobURL(blob))
                    #expect(info != nil, "iteration \(iteration): \(entry.identifier.rawValue) bound to an unlinked blob")
                    #expect(await store.state.core.blobTable[blob].map { if case .live = $0 { return true } else { return false } } == true)
                }
            }
            // Each blob unlinked at most once.
            let removed = fake.operations.filter { $0.kind == .removeItem && $0.url.path.contains("/blobs/") }.map(\.url.path)
            #expect(Set(removed).count == removed.count, "iteration \(iteration): a blob unlinked twice")
            // Everything not rescued is eventually reaped.
            _ = await store.runDueWork()
            clock.base.advance(by: 10)
            _ = await store.runDueWork()
            let table = await store.state.core.blobTable
            let rescued = report.reused.count
            print("PROBE2 iteration \(iteration): reaped \(a.filesRemoved)+\(b.filesRemoved), rescued \(rescued), left \(table.count)")
            #expect(table.count == rescued, "iteration \(iteration): \(table.count) keys left, \(rescued) rescued")
            #expect(a.filesRemoved + b.filesRemoved + rescued <= 48)
            await store.close()
        }
    }
}
