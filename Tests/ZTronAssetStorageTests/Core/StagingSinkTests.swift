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

    /// The executors a staging sink may run on: inline, the stepped one holding the unit until the test releases it
    /// (the caller is cancelled while its unit waits), and the live dispatch executor.
    enum CleanupExecutor: String, CaseIterable, Sendable {
        case inline
        case steppedHeld
        case dispatch
    }

    /// A sink on `kind` over an open store's fake volume, and the stepped executor when `kind` holds units.
    @available(macOS 15.0, *)
    static func sink(on kind: CleanupExecutor) async throws -> (CoreHarness, StoreStagingSink, SteppedBlockingExecutor?) {
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        let stepped: SteppedBlockingExecutor? = kind == .steppedHeld ? SteppedBlockingExecutor(holding: true) : nil
        let executor: any BlockingExecutor
        switch kind {
        case .inline:
            executor = InlineBlockingExecutor()
        case .steppedHeld:
            executor = stepped ?? InlineBlockingExecutor()
        case .dispatch:
            executor = DispatchBlockingExecutor(label: "staging-sink-tests.cleanup")
        }
        let sink = StoreStagingSink(fileSystem: harness.fileSystem, layout: harness.layout, bulkExecutor: executor, metadataExecutor: executor)
        return (harness, sink, stepped)
    }

    /// Runs `work` in a task that is already cancelled when `work` starts, releasing a held unit of `stepped` meanwhile;
    /// returns whether the task was still cancelled when `work` returned.
    @available(macOS 15.0, *)
    static func inCancelledTask(_ stepped: SteppedBlockingExecutor?, _ work: @escaping @Sendable () async -> Void) async throws -> Bool {
        let returned = Mutex(false)
        let task = Task {
            // Waits for its own cancellation (it ends with the test, CorePoll), so `work` starts cancelled.
            try await CorePoll.until("the cleanup task's cancellation") {
                Task.isCancelled
            }
            await work()
            returned.withLock { $0 = true }
            return Task.isCancelled
        }
        task.cancel()
        if let stepped {
            // The cleanup's unit is held until it is released here; a cleanup that submitted none has returned already
            // (polled, never an uncancellable wait: a regression fails at once instead of hanging the run).
            try await CorePoll.until("the cleanup's unit held, or the cleanup returned") {
                if returned.withLock({ $0 }) {
                    return true
                }
                return await !stepped.heldUnits.isEmpty
            }
            await stepped.releaseAll()
        }
        return try await task.value
    }

    /// WP-E discards staged copies from driver tasks that were cancelled (`StagingSink.discard`, close-out cycle 5): the
    /// files must go all the same. `discard` checks no cancellation, and every executor runs a submitted unit to
    /// completion (`BlockingExecutor`), so the removal happens even when the caller is cancelled before it starts, or
    /// while its unit waits for the executor.
    @Test(
        "R-STO-1: discard from a cancelled task removes the staging file, its sidecar and the sidecar's temporary",
        .timeLimit(.minutes(1)),
        arguments: CleanupExecutor.allCases
    )
    @available(macOS 15.0, *)
    func discardFromACancelledTask(executor: CleanupExecutor) async throws {
        let (harness, sink, stepped) = try await StagingSinkTests.sink(on: executor)
        let name = StagingSinkTests.name(1)
        let urls = [name, name.with(kind: .sidecar), name.with(kind: .sidecarTemporary)].map(harness.layout.stagingURL)
        for url in urls {
            try harness.fileSystem.write(Data([1, 2, 3]), to: url, mode: .truncate)
        }
        let cancelled = try await StagingSinkTests.inCancelledTask(stepped) {
            await sink.discard(name)
        }
        #expect(cancelled, "\(executor): the discard ran in a cancelled task")
        for url in urls {
            #expect(!harness.exists(url), "\(executor): \(url.lastPathComponent) is gone")
        }
    }

    /// The other staging cleanup a cancelled task can reach: a copy whose source fails while the caller is cancelled
    /// (WP-E stops reading a pack when its driver task is cancelled) still removes its `.parttmp`.
    @Test(
        "R-STO-1: a staged copy that fails in a cancelled task still removes its temporary",
        .timeLimit(.minutes(1)),
        arguments: [CleanupExecutor.inline, .dispatch]
    )
    @available(macOS 15.0, *)
    func failedCopyInACancelledTaskCleansUp(executor: CleanupExecutor) async throws {
        let (harness, sink, _) = try await StagingSinkTests.sink(on: executor)
        let name = StagingSinkTests.name(2)
        let outcome = Mutex<StagingError?>(nil)
        let cancelled = try await StagingSinkTests.inCancelledTask(nil) {
            do throws(StagingError) {
                _ = try await sink.writeStaged(name, from: ScriptedChunks(chunks: [Data([1]), Data([2])], failAt: 1), maxBytes: 100)
            } catch {
                outcome.withLock { $0 = error }
            }
        }
        #expect(cancelled)
        #expect(outcome.withLock { $0 } == .source(.readFailed))
        #expect(!harness.exists(harness.layout.stagingURL(name.with(kind: .partialTemporary))), "\(executor): the temporary is removed")
        #expect(!harness.exists(harness.layout.stagingURL(name)))
    }
}
