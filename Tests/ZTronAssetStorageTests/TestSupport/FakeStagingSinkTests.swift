import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// The in-memory staging sink transport and Apple-tier tests use without a store (WP-D, WP-E).
@Suite("Test support: FakeStagingSink")
struct TestSupportFakeStagingSinkTests {
    static func name(_ sequence: UInt32, _ kind: StagingFileName.Kind = .partial) -> StagingFileName {
        StagingFileName(transfer: .content(ContentHash.sha256(of: Data([5]))), attempt: TransferAttempt(epoch: 1, sequence: sequence), kind: kind)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: continuePartial moves an earlier partial exclusively and refuses a taken or missing name")
    func continuePartialIsExclusive() throws {
        let sink = FakeStagingSink()
        try sink.createPartial(Self.name(1))
        _ = try sink.appendPartial(Data([1, 2, 3]), to: Self.name(1))
        try sink.createPartial(Self.name(3))
        #expect(try sink.continuePartial(from: Self.name(1), as: Self.name(2)) == 3)
        #expect(sink.contents == [Self.name(2): Data([1, 2, 3]), Self.name(3): Data()])
        #expect(throws: StagingError.nameInUse) { try sink.continuePartial(from: Self.name(2), as: Self.name(3)) }
        #expect(throws: StagingError.io(posixCode: ENOENT)) { try sink.continuePartial(from: Self.name(1), as: Self.name(4)) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: readStaged returns the staged bytes and refuses a missing file or more than maxBytes", .timeLimit(.minutes(1)))
    func readStagedHonoursTheCap() async throws {
        let sink = FakeStagingSink()
        try sink.createPartial(Self.name(1))
        _ = try sink.appendPartial(Data([1, 2, 3]), to: Self.name(1))
        #expect(try await sink.readStaged(Self.name(1), maxBytes: 3) == Data([1, 2, 3]))
        await #expect(throws: StagingError.tooLarge(limit: 2)) { try await sink.readStaged(Self.name(1), maxBytes: 2) }
        await #expect(throws: StagingError.io(posixCode: ENOENT)) { try await sink.readStaged(Self.name(9), maxBytes: 2) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: sidecars are recorded, read back by partial name and discarded with their partial", .timeLimit(.minutes(1)))
    func sidecarsFollowTheirPartial() async throws {
        let sink = FakeStagingSink()
        let validator = ResumeValidator.lastModified("Wed, 21 Oct 2015 07:28:00 GMT")
        let sidecar = ResumeSidecar(name: Self.name(1), validator: validator, receivedBytes: 3, expectedBytes: 10)
        try sink.createPartial(Self.name(1))
        sink.writeSidecar(sidecar)
        #expect(sink.sidecars == [Self.name(1): sidecar])
        #expect(await sink.readSidecar(for: Self.name(1)) == sidecar)
        #expect(await sink.readSidecar(for: Self.name(2)) == nil)
        await sink.discard(Self.name(1))
        await sink.discard(Self.name(1))
        #expect(sink.contents.isEmpty)
        #expect(sink.sidecars.isEmpty)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: writeStaged drains a chunk source and refuses a taken name, more than maxBytes and a failing source", .timeLimit(.minutes(1)))
    func writeStagedDrainsTheSource() async throws {
        let sink = FakeStagingSink()
        #expect(try await sink.writeStaged(Self.name(1), from: FakeSinkChunkList([Data([1, 2]), Data([3])]), maxBytes: 3) == 3)
        #expect(sink.contents[Self.name(1)] == Data([1, 2, 3]))
        await #expect(throws: StagingError.nameInUse) { try await sink.writeStaged(Self.name(1), from: FakeSinkChunkList([Data([1])]), maxBytes: 3) }
        await #expect(throws: StagingError.tooLarge(limit: 2)) { try await sink.writeStaged(Self.name(2), from: FakeSinkChunkList([Data([1, 2, 3])]), maxBytes: 2) }
        #expect(sink.contents[Self.name(2)] == nil)
        await #expect(throws: StagingError.source(.readFailed)) {
            try await sink.writeStaged(Self.name(3), from: FakeSinkChunkList([Data([1])], failing: .source(.readFailed)), maxBytes: 9)
        }
        #expect(sink.contents[Self.name(3)] == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: adoptDownload copies a file the test made inside the repository and refuses a taken name")
    func adoptDownloadReadsTheFile() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-testsupport-fixtures", isDirectory: true)
            .appendingPathComponent("adopt-download-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("download.tmp")
        try Data([4, 5, 6]).write(to: location)

        let sink = FakeStagingSink()
        #expect(try sink.adoptDownload(at: location, as: Self.name(1)) == 3)
        #expect(sink.contents[Self.name(1)] == Data([4, 5, 6]))
        #expect(throws: StagingError.nameInUse) { try sink.adoptDownload(at: location, as: Self.name(1)) }
        #expect(throws: StagingError.io(posixCode: ENOENT)) { try sink.adoptDownload(at: directory.appendingPathComponent("absent"), as: Self.name(2)) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: failNext fails exactly the next call of one operation")
    func failNextFiresOnce() throws {
        let sink = FakeStagingSink()
        sink.failNext(.createPartial, with: .insufficientSpace)
        sink.failNext(.continuePartial, with: .io(posixCode: EIO))
        #expect(throws: StagingError.insufficientSpace) { try sink.createPartial(Self.name(1)) }
        try sink.createPartial(Self.name(1))
        #expect(throws: StagingError.io(posixCode: EIO)) { try sink.continuePartial(from: Self.name(1), as: Self.name(2)) }
        #expect(try sink.continuePartial(from: Self.name(1), as: Self.name(2)) == 0)
    }
}

/// A chunk source over fixed chunks, optionally failing after them.
@available(macOS 15.0, iOS 18.0, *)
final class FakeSinkChunkList: ChunkSource {
    private let remaining: Mutex<[Data]>
    private let failure: StagingError?

    init(_ chunks: [Data], failing failure: StagingError? = nil) {
        self.remaining = Mutex(chunks)
        self.failure = failure
    }

    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        let next = self.remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if next == nil, let failure = self.failure {
            throw failure
        }
        return next
    }
}
