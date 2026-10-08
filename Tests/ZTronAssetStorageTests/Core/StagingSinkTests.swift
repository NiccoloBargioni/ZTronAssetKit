import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// A chunk source over fixed chunks, failing where told (Apple-tier copies).
@available(macOS 15.0, *)
struct ScriptedChunks: ChunkSource {
    let chunks: [Data]
    let failAt: Int?
    private let pulled = PullCounter()

    init(chunks: [Data], failAt: Int?) {
        self.chunks = chunks
        self.failAt = failAt
    }

    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        // The sink pulls one chunk per unit, in order: the index is the number of chunks already pulled.
        let index = self.pulled.next()
        if let failAt, index == failAt {
            throw .source(.readFailed)
        }
        return index < self.chunks.count ? self.chunks[index] : nil
    }
}

/// A counter for a synchronous chunk source.
@available(macOS 15.0, *)
final class PullCounter: Sendable {
    private let state = Mutex(0)

    func next() -> Int {
        self.state.withLock { value in
            defer {
                value += 1
            }
            return value
        }
    }
}

@Suite("Core: staging sink")
struct StagingSinkTests {
    @available(macOS 15.0, *)
    static func sink() async throws -> (CoreHarness, StoreStagingSink) {
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        return (harness, try await harness.store.makeStagingSink())
    }

    static func name(_ sequence: UInt32, _ kind: StagingFileName.Kind = .partial) -> StagingFileName {
        StagingFileName(transfer: .manifest, attempt: TransferAttempt(epoch: 1, sequence: sequence), kind: kind)
    }

    @Test("R-STO-1: partial files, continuations and adopted downloads land in staging under their exclusive names", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func partialsAndContinuations() async throws {
        let (harness, sink) = try await StagingSinkTests.sink()
        let first = StagingSinkTests.name(1)
        try sink.createPartial(first)
        #expect(try sink.appendPartial(Data([1, 2, 3]), to: first) == 3)
        let second = StagingSinkTests.name(2)
        #expect(try sink.continuePartial(from: first, as: second) == 3)
        #expect(try sink.appendPartial(Data([4]), to: second) == 4)
        try sink.createPartial(first)
        #expect(throws: StagingError.nameInUse) {
            try sink.continuePartial(from: first, as: second)
        }
        #expect(throws: StagingError.io(posixCode: ENOENT)) {
            try sink.continuePartial(from: StagingSinkTests.name(9), as: StagingSinkTests.name(10))
        }
        let download = URL(fileURLWithPath: "/fake-volume/tmp-download.bin")
        try harness.fileSystem.write(Data([7, 7]), to: download, mode: .truncate)
        let adopted = StagingSinkTests.name(3)
        #expect(try sink.adoptDownload(at: download, as: adopted) == 2)
        #expect(harness.content(harness.layout.stagingURL(adopted)) == Data([7, 7]))
        #expect(!harness.exists(download))
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: ".part"), occurrence: .nth(1), error: .noSpace))
        #expect(throws: StagingError.insufficientSpace) {
            try sink.appendPartial(Data([5]), to: second)
        }
    }

    @Test("R-STO-1: a sidecar is written atomically, read back, and ignored when absent, undecodable or describing another file", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func sidecars() async throws {
        let (harness, sink) = try await StagingSinkTests.sink()
        let name = StagingSinkTests.name(1)
        let sidecar = ResumeSidecar(name: name, validator: .lastModified("Wed, 21 Oct 2015 07:28:00 GMT"), receivedBytes: 10, expectedBytes: 20)
        sink.writeSidecar(sidecar)
        #expect(await sink.readSidecar(for: name) == sidecar)
        #expect(!harness.exists(harness.layout.stagingURL(name.with(kind: .sidecarTemporary))))
        #expect(await sink.readSidecar(for: StagingSinkTests.name(2)) == nil)
        try harness.fileSystem.write(Data("{".utf8), to: harness.layout.stagingURL(StagingSinkTests.name(3, .sidecar)), mode: .truncate)
        #expect(await sink.readSidecar(for: StagingSinkTests.name(3)) == nil)
        sink.writeSidecar(ResumeSidecar(name: StagingSinkTests.name(4), validator: .lastModified("x"), receivedBytes: 1, expectedBytes: nil))
        try harness.fileSystem.rename(
            from: harness.layout.stagingURL(StagingSinkTests.name(4, .sidecar)),
            to: harness.layout.stagingURL(StagingSinkTests.name(5, .sidecar)),
            mode: .exclusive
        )
        #expect(await sink.readSidecar(for: StagingSinkTests.name(5)) == nil, "a sidecar that describes another partial is garbage")
        // A failed sidecar write leaves no temporary behind.
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".resumetmp"), occurrence: .nth(1), error: .io))
        sink.writeSidecar(ResumeSidecar(name: StagingSinkTests.name(6), validator: .lastModified("y"), receivedBytes: 1, expectedBytes: nil))
        #expect(!harness.exists(harness.layout.stagingURL(StagingSinkTests.name(6, .sidecarTemporary))))
        await sink.discard(name)
        #expect(!harness.exists(harness.layout.stagingURL(name.with(kind: .sidecar))))
    }

    @Test("R-STO-1: a staged manifest is read within its cap and a larger one is refused", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func readStaged() async throws {
        let (_, sink) = try await StagingSinkTests.sink()
        let name = StagingSinkTests.name(1)
        let payload = GeneratedPayload.bytes(seed: 3, offset: 0, length: (1 << 20) + 5)
        try sink.createPartial(name)
        _ = try sink.appendPartial(payload, to: name)
        #expect(try await sink.readStaged(name, maxBytes: Int64(payload.count)) == payload)
        await #expect(throws: StagingError.tooLarge(limit: 100)) {
            try await sink.readStaged(name, maxBytes: 100)
        }
        await #expect(throws: StagingError.io(posixCode: ENOENT)) {
            try await sink.readStaged(StagingSinkTests.name(2), maxBytes: 100)
        }
        await sink.discard(name)
        await sink.discard(name)
        await #expect(throws: StagingError.io(posixCode: ENOENT)) {
            try await sink.readStaged(name, maxBytes: 100)
        }
    }

    @Test("R-STO-1: a chunk source is staged through a temporary and renamed into place, within its cap", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func writeStaged() async throws {
        let (harness, sink) = try await StagingSinkTests.sink()
        let chunks = [Data([1, 2]), Data([3]), Data([4, 5, 6])]
        let name = StagingSinkTests.name(1)
        #expect(try await sink.writeStaged(name, from: ScriptedChunks(chunks: chunks, failAt: nil), maxBytes: 6) == 6)
        #expect(harness.content(harness.layout.stagingURL(name)) == Data([1, 2, 3, 4, 5, 6]))
        #expect(!harness.exists(harness.layout.stagingURL(name.with(kind: .partialTemporary))))
        let empty = StagingSinkTests.name(2)
        #expect(try await sink.writeStaged(empty, from: ScriptedChunks(chunks: [], failAt: nil), maxBytes: 6) == 0)
        #expect(harness.content(harness.layout.stagingURL(empty)) == Data())
        let large = StagingSinkTests.name(3)
        await #expect(throws: StagingError.tooLarge(limit: 5)) {
            try await sink.writeStaged(large, from: ScriptedChunks(chunks: chunks, failAt: nil), maxBytes: 5)
        }
        #expect(!harness.exists(harness.layout.stagingURL(large.with(kind: .partialTemporary))))
        await #expect(throws: StagingError.source(.readFailed)) {
            try await sink.writeStaged(StagingSinkTests.name(4), from: ScriptedChunks(chunks: chunks, failAt: 1), maxBytes: 100)
        }
        await #expect(throws: StagingError.nameInUse) {
            try await sink.writeStaged(name, from: ScriptedChunks(chunks: chunks, failAt: nil), maxBytes: 100)
        }
    }
}
