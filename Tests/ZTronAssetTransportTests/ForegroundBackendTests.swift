import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-2, R-NET-10: the one foreground session against the loopback server: connection reuse, per-task routing,
/// cancellation, invalidation and in-place priority changes.
@Suite("Foreground backend")
struct ForegroundBackendTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-2: 500 downloads through one backend use at most maxConnectionsPerHost TCP connections", .timeLimit(.minutes(1)))
    func connectionReuse() async throws {
        // 3 is below URLSession's own default per-host limit (6 on macOS), so only the configured cap explains it. The
        // 500 tasks queue behind 3 connections and a queued task's request timeout runs while it waits, so the timeout is
        // 50 s, within the test's minute, rather than the rig's 10 s, which a loaded host outlasted (ADR draft C OI-10).
        let rig = try await LoopbackRig.make(maxConnections: 3, requestTimeout: 50) { request in
            LoopbackResponse(body: Data(request.target.utf8) + TransportFixtures.payload(1_000))
        }
        let outcomes = await withTaskGroup(of: (Int, TransferUpdate?).self) { group in
            for index in 0..<500 {
                group.addTask {
                    let path = "asset/\(index).bin"
                    let expected = Int64(("/" + path).utf8.count + 1_000)
                    let request = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(UInt32(index)), path: path, expected: expected)
                    return (index, await run(await rig.source.transfer(request)).terminal)
                }
            }
            var outcomes: [Int: TransferUpdate?] = [:]
            for await (index, terminal) in group {
                outcomes[index] = terminal
            }
            return outcomes
        }
        #expect(outcomes.count == 500)
        for (index, terminal) in outcomes {
            guard case .staged(let file)? = terminal else {
                Issue.record("transfer \(index): \(String(describing: terminal))")
                continue
            }
            // Every task's bytes reached its own staging file through its own mailbox.
            #expect(rig.staging.contents[file.name]?.prefix(("/asset/\(index).bin").utf8.count) == Data("/asset/\(index).bin".utf8))
        }
        let connections = await rig.server.acceptedConnections
        #expect(connections >= 1 && connections <= 3, "\(connections) connections")
        #expect(await rig.server.requests.count == 500)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-2: every task's bytes reach its own staging file and the transfer interval ends once per transfer", .timeLimit(.minutes(1)))
    func mailboxRoutingAndIntervals() async throws {
        let rig = try await LoopbackRig.make { request in
            LoopbackResponse(body: TransportFixtures.payload(300_000, seed: UInt8(request.target.utf8.count % 200)))
        }
        var names: [StagingFileName: Data] = [:]
        for (index, path) in ["a.bin", "bb.bin", "ccc.bin"].enumerated() {
            let request = rig.request(TransportFixtures.contentID(UInt8(index)), path: path, expected: 300_000)
            let result = await run(await rig.source.transfer(request))
            guard case .staged(let file)? = result.terminal else {
                Issue.record("\(path): \(String(describing: result.terminal))")
                continue
            }
            #expect(file.byteCount == 300_000 && !file.resumed && file.httpStatus == 200)
            // Progress is rate-limited: the first chunk and one per 256 KiB boundary at most.
            #expect(!result.progress.isEmpty && result.progress.count <= 2)
            names[file.name] = TransportFixtures.payload(300_000, seed: UInt8(("/" + path).utf8.count % 200))
        }
        for (name, body) in names {
            #expect(rig.staging.contents[name] == body)
        }
        let edges = transferIntervalEdges(rig.tap)
        #expect(edges.began == 3 && edges.ended == 3)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-2: cancelling the consumer cancels the URLSession task and reports cancelled by the client", .timeLimit(.minutes(1)))
    func consumerCancellation() async throws {
        let arrivals = Arrivals()
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout) { request in
            arrivals.signal(request.target)
            return LoopbackResponse(body: TransportFixtures.payload(200_000), ending: .stallAfter(bodyBytes: 1_000))
        }
        let source = rig.source
        let fetch = Task {
            try await source.fetchManifest(ManifestRequest(ifNoneMatch: nil, maxBytes: 1 << 20, attempt: TransportFixtures.attempt(1)))
        }
        #expect(await arrivals.next() == "/manifest.json")
        fetch.cancel()
        let result = await fetch.result
        #expect(throws: TransferError.cancelled(.byClient)) { try result.get() }
        // The data task was cancelled with the stream: nothing is left running.
        #expect(await rig.foreground.liveTransfers().isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-2: invalidation fails every live transfer and later starts without touching the network", .timeLimit(.minutes(1)))
    func invalidation() async throws {
        let arrivals = Arrivals()
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout) { request in
            arrivals.signal(request.target)
            return LoopbackResponse(body: TransportFixtures.payload(100_000), ending: .stallAfter(bodyBytes: 10))
        }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "stall.bin", expected: 100_000))
        #expect(await arrivals.next() == "/stall.bin")
        await rig.source.invalidate()
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
        // A second invalidation returns at once; a start after it is terminal at once and sends nothing.
        await rig.source.invalidate()
        let late = await rig.source.transfer(rig.request(TransportFixtures.contentID(2), path: "late.bin", expected: 10))
        #expect(await run(late).terminal == .failed(.cancelled(.byClient)))
        #expect(await rig.requests(to: "/late.bin").isEmpty)
        let edges = transferIntervalEdges(rig.tap)
        #expect(edges.began == 1 && edges.ended == 1)
        await rig.server.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: setPriority on a running transfer changes URLSessionTask.priority synchronously", .timeLimit(.minutes(1)))
    func priorityChangesInPlace() async throws {
        let arrivals = Arrivals()
        // The handle's discard is held, so its task is provably not cancelled yet when the live transfers are listed.
        let staging = FakeStagingSink()
        let sink = HeldDiscardSink(base: staging)
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout, staging: staging, sink: sink) { request in
            arrivals.signal(request.target)
            return LoopbackResponse(body: TransportFixtures.payload(100_000), ending: .stallAfter(bodyBytes: 10))
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "bulk.bin", expected: 100_000, priority: .bulk)
        let handle = await rig.source.transfer(request)
        #expect(await arrivals.next() == "/bulk.bin")
        #expect(await rig.foreground.liveTransfers().map(\.priority) == [0.25])
        handle.setPriority(.userInitiated)
        let live = await rig.foreground.liveTransfers()
        #expect(live.map(\.priority) == [0.75])
        #expect(live.map(\.name) == [request.partialName])
        #expect(live.allSatisfy { $0.backend == .foreground && $0.isRunning })
        handle.cancel()
        // A cancelling task is no longer a live transfer, whether or not it has completed yet: here its partial is
        // still being discarded, so the task itself has not even been cancelled.
        #expect(await rig.foreground.liveTransfers().isEmpty)
        await sink.release()
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
        // A control after the terminal element changes nothing.
        handle.setPriority(.prefetch)
        handle.pause()
        #expect(await rig.foreground.liveTransfers().isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-2: cancelling by staging name discards the partial unless it keeps it for a pause", .timeLimit(.minutes(1)))
    func cancelByName() async throws {
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout) { _ in
            LoopbackResponse(body: TransportFixtures.payload(1 << 20), ending: .stallAfter(bodyBytes: 512 * 1_024), rangeETag: "\"v1\"")
        }
        let discarded = rig.request(TransportFixtures.contentID(1), path: "drop.bin", expected: 1 << 20)
        let first = await rig.source.transfer(discarded)
        var iterator = first.updates.makeAsyncIterator()
        #expect(await awaitProgress(&iterator, reaching: 512 * 1_024))
        await rig.foreground.cancel(discarded.partialName, keepingPartial: false)
        #expect(await iterator.next() == .failed(.cancelled(.byClient)))
        #expect(rig.staging.contents[discarded.partialName] == nil)

        let kept = rig.request(TransportFixtures.contentID(2), path: "keep.bin", expected: 1 << 20)
        let second = await rig.source.transfer(kept)
        var keptIterator = second.updates.makeAsyncIterator()
        #expect(await awaitProgress(&keptIterator, reaching: 512 * 1_024))
        await rig.foreground.cancel(kept.partialName, keepingPartial: true)
        #expect(await keptIterator.next() == .paused(resumable: true))
        #expect(rig.staging.contents[kept.partialName]?.isEmpty == false)
        #expect(rig.staging.sidecars[kept.partialName]?.validator == .strongETag(try #require(ETag(rawValue: "\"v1\""))))
        // A name that no task writes is ignored: staging and the session are left as they were.
        let contents = rig.staging.contents
        let sidecars = rig.staging.sidecars
        await rig.foreground.cancel(rig.request(TransportFixtures.contentID(3), path: "none", expected: 1).partialName, keepingPartial: false)
        #expect(rig.staging.contents == contents)
        #expect(rig.staging.sidecars == sidecars)
        #expect(await rig.foreground.liveTransfers().isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: cancelling a foreground handle discards its partial, unlike a pause, and a cancel after the outcome changes nothing", .timeLimit(.minutes(1)))
    func handleCancelDiscards() async throws {
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout) { request in
            request.target == "/small.bin"
                ? LoopbackResponse(body: TransportFixtures.payload(1_000))
                : LoopbackResponse(
                    headers: ["Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"],
                    body: TransportFixtures.payload(1 << 20),
                    ending: .stallAfter(bodyBytes: 512 * 1_024)
                )
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 1 << 20)
        let handle = await rig.source.transfer(request)
        var iterator = handle.updates.makeAsyncIterator()
        #expect(await awaitProgress(&iterator, reaching: 512 * 1_024))
        handle.cancel()
        #expect(await iterator.next() == .failed(.cancelled(.byClient)))
        #expect(rig.staging.contents[request.partialName] == nil)
        #expect(rig.staging.sidecars[request.partialName] == nil)
        // After its terminal element the staged file is the engine's: a late cancel must not discard it.
        let small = rig.request(TransportFixtures.contentID(2), path: "small.bin", expected: 1_000)
        let finished = await rig.source.transfer(small)
        #expect(await run(finished).terminal == .staged(StagedFile(name: small.partialName, byteCount: 1_000, resumed: false, httpStatus: 200, etag: nil)))
        finished.cancel()
        #expect(rig.staging.contents[small.partialName] == TransportFixtures.payload(1_000))
        await rig.stop()
    }

    /// A reference that does not keep its object alive.
    struct WeakReference {
        weak var object: AnyObject?
    }

    /// The elements of `updates` other than progress, read to the stream's end the way the engine's per-transfer
    /// reader reads them: the call returns only once the stream finished.
    static func outcomes(of updates: AsyncStream<TransferUpdate>) async -> [TransferUpdate] {
        var outcomes: [TransferUpdate] = []
        for await update in updates {
            if case .progress = update {
                continue
            }
            outcomes.append(update)
        }
        return outcomes
    }

    /// sync-2 S2-19 (ARCHITECTURE §12.4): a per-transfer control reader over a stream nobody finishes leaks one task
    /// per transfer, and the engine's own reader leaks if the update stream outlives its terminal element. ADR-021
    /// gives the foreground handle synchronous controls and no control stream; this pins the consequence against the
    /// real URLSession backend for every way a transfer ends (staged, failed, paused, cancelled): each reader ends at
    /// its one terminal element, every `transfer` interval ended (the stream's termination ran), the session holds no
    /// unfinished task, and once dropped no handle is kept alive by a task (S2-19's reader captured its transfer).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: no task outlives a transfer in the live foreground backend", .timeLimit(.minutes(1)))
    func noTaskOutlivesATransfer() async throws {
        let arrivals = Arrivals()
        let rig = try await LoopbackRig.make(requestTimeout: LoopbackRig.heldStallTimeout) { request in
            arrivals.signal(request.target)
            switch request.target {
            case "/staged.bin":
                return LoopbackResponse(body: TransportFixtures.payload(1_000))
            case "/missing.bin":
                return LoopbackResponse(status: 404)
            default:
                return LoopbackResponse(body: TransportFixtures.payload(100_000), ending: .stallAfter(bodyBytes: 10))
            }
        }
        let staged = rig.request(TransportFixtures.contentID(1), path: "staged.bin", expected: 1_000)
        let expected: [(path: String, terminal: TransferUpdate)] = [
            ("staged.bin", .staged(StagedFile(name: staged.partialName, byteCount: 1_000, resumed: false, httpStatus: 200, etag: nil))),
            ("missing.bin", .failed(.permanentMissing(httpStatus: 404))),
            ("paused.bin", .paused(resumable: false)),
            ("cancelled.bin", .failed(.cancelled(.byClient))),
        ]
        var handles: [any TransferHandle] = []
        var readers: [Task<[TransferUpdate], Never>] = []
        for (index, item) in expected.enumerated() {
            let request = rig.request(TransportFixtures.contentID(UInt8(index + 1)), path: item.path, expected: index == 0 ? 1_000 : 100_000)
            let handle = await rig.source.transfer(request)
            #expect(await arrivals.next() == "/" + item.path)
            // The reader holds the stream only, never the handle.
            let updates = handle.updates
            readers.append(Task { await Self.outcomes(of: updates) })
            handles.append(handle)
        }
        handles[2].pause()
        handles[3].cancel()
        for (reader, item) in zip(readers, expected) {
            #expect(await reader.value == [item.terminal], "\(item.path): exactly one terminal element, then the stream ended")
        }
        let edges = transferIntervalEdges(rig.tap)
        #expect(edges.began == expected.count && edges.ended == expected.count)
        #expect(await rig.foreground.liveTransfers().isEmpty)
        let unfinished = await rig.foreground.session.allTasks.filter { $0.state != .completed }
        #expect(unfinished.isEmpty, "\(unfinished.count) URLSession tasks outlived their transfers")
        let references = handles.map { WeakReference(object: $0 as AnyObject) }
        handles.removeAll()
        #expect(references.allSatisfy { $0.object == nil }, "a task kept a handle alive after its transfer ended")
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-4: a request to an origin outside the policy is refused before any byte is sent", .timeLimit(.minutes(1)))
    func refusedOrigin() async throws {
        let rig = try await LoopbackRig.make(allowedHosts: ["cdn.example.com"]) { _ in LoopbackResponse(body: Data("x".utf8)) }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 1))
        #expect(await run(handle).terminal == .failed(.rejected(.hostNotAllowed)))
        // The refused handle's controls do nothing and its stream stays finished.
        handle.setPriority(.userInitiated)
        handle.pause()
        handle.cancel()
        #expect(await run(handle).terminal == nil)
        #expect(await rig.server.requests.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-4: a remote path that could leave the base path is refused as an invalid URL", .timeLimit(.minutes(1)), arguments: [
        "../secret", "a/../../b", "a/%2e%2e/b", "a/%2E/b", "a//b", "a?b=1", "a#frag", "a\\b", "", "/abs",
    ])
    func invalidPaths(_ path: String) async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: Data("x".utf8)) }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: path, expected: 1))
        #expect(await run(handle).terminal == .failed(.rejected(.invalidURL)))
        #expect(await rig.server.requests.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-4: a remote path is joined by percent-encoded components under the base path", .timeLimit(.minutes(1)))
    func encodedPath() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: Data("ok".utf8)) }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "media/Sky Line/a b%.png", expected: 2))
        guard case .staged = await run(handle).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(await rig.server.requests.map(\.target) == ["/media/Sky%20Line/a%20b%25.png"])
        await rig.stop()
    }
}
