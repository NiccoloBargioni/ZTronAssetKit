import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-3 (H-6): the background coordinator over `FakeBackgroundSessionDriver`, whose "OS" reports through the
/// real `.background` `SessionDelegate` and survives coordinator instances (relaunches).
@Suite("Background coordinator")
struct BackgroundCoordinatorTests {
    static let identifier = BackgroundSessionIdentifier(namespace: "media")!
    static let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com"])
    static let url = URL(string: "https://cdn.example.com/media/video.bin")!

    /// A staging sink, a driver whose "OS" outlives coordinators, and the first launch's coordinator.
    @available(macOS 15.0, *)
    struct Rig {
        let staging = FakeStagingSink()
        let driver: FakeBackgroundSessionDriver
        let fixtures: URL
        let options: BackgroundTransferOptions

        init(_ name: String, maxTasks: Int = 4) throws {
            self.fixtures = try TransportFixtures.directory(name)
            self.options = BackgroundTransferOptions(namespace: "media", discretionary: true, maxTasks: maxTasks)
            let delegate = SessionDelegate(mode: .background, staging: self.staging, policy: BackgroundCoordinatorTests.policy)
            self.driver = FakeBackgroundSessionDriver(identifier: BackgroundCoordinatorTests.identifier, delegate: delegate, fixtures: self.fixtures)
        }

        /// A coordinator for the current launch.
        func coordinator(appKey: AppKey? = nil) -> BackgroundTransferCoordinator {
            BackgroundTransferCoordinator(
                driver: self.driver,
                staging: self.staging,
                options: self.options,
                policy: BackgroundCoordinatorTests.policy,
                appKey: appKey,
                requestTimeout: 30,
                log: .tapOnly(nil)
            )
        }

        /// The process dies and the OS relaunches it: a new delegate (and session stream) over the same staging.
        func relaunch() async {
            await self.driver.relaunch(delegate: SessionDelegate(mode: .background, staging: self.staging, policy: BackgroundCoordinatorTests.policy))
        }

        func job(_ sequence: UInt32 = 1, epoch: UInt64 = 1, expected: Int64? = 4_000, seed: UInt8 = 1) -> TransferJob {
            TransportFixtures.job(
                id: TransportFixtures.contentID(seed),
                attempt: TransportFixtures.attempt(sequence, epoch: epoch),
                url: BackgroundCoordinatorTests.url,
                expected: expected,
                priority: .bulk
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: self.fixtures)
        }

        /// Waits for the driver's next `signal` (event-driven, never polled).
        func awaitSignal(_ signal: String) async {
            for await received in self.driver.signals where received == signal {
                return
            }
        }
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: the coordinator reports a download finished while the app was dead as a reattached staged transfer", .timeLimit(.minutes(1)))
    func finishedWhileDead() async throws {
        let rig = try Rig("finished-while-dead")
        defer { rig.cleanUp() }
        let body = TransportFixtures.payload(4_000)
        let job = rig.job()
        // The first process's handle stays alive: dropping it would cancel the OS task (`TransferHandle`), while a
        // killed process cancels nothing.
        let firstLaunch = await rig.coordinator().start(job)
        #expect(await rig.driver.starts.map(\.name) == [job.partialName])

        // The app dies; the OS finishes the download and relaunches the app in the background for its events.
        await rig.relaunch()
        await rig.driver.complete(job.partialName, body: body)
        await rig.driver.finishEvents()

        let relaunched = rig.coordinator()
        await relaunched.awaitBackgroundEvents()
        #expect(rig.staging.contents[job.partialName] == body)
        #expect(await relaunched.reattached() == [ReattachedTransfer(name: job.partialName, isRunning: false, bytesReceived: 4_000)])
        // Not re-downloaded by the transport: launch reconciliation adopts the reported file from staging.
        #expect(await rig.driver.starts.count == 1)
        withExtendedLifetime(firstLaunch) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a start for content an OS task is still fetching attaches to that task instead of creating another", .timeLimit(.minutes(1)))
    func attachesToLiveTask() async throws {
        let rig = try Rig("attach-live")
        defer { rig.cleanUp() }
        let job = rig.job()
        let firstLaunch = await rig.coordinator().start(job)
        await rig.relaunch()

        let relaunched = rig.coordinator()
        #expect(await relaunched.reattached() == [ReattachedTransfer(name: job.partialName, isRunning: true, bytesReceived: 0)])
        let handle = await relaunched.start(job)
        #expect(await rig.driver.starts.count == 1)
        #expect(await relaunched.liveTransfers().map(\.name) == [job.partialName])
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        guard case .staged(let file)? = await run(handle).terminal else {
            Issue.record("not staged")
            return
        }
        #expect(file.name == job.partialName && file.byteCount == 4_000)
        withExtendedLifetime(firstLaunch) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-7: a start that joins a live OS task is never handed a staged file of another byteSize", .timeLimit(.minutes(1)), arguments: [
        Int64(4_000), Int64(6_000),
    ])
    func joinChecksTheJoiningJobsSize(_ taggedBytes: Int64) async throws {
        // Review round 3 (PROBE-R3-2): the dead process tagged an OS task for a checksum-less identity with its
        // byteSize then; the new manifest says 5,000 for the same identity. No hash catches a checksum-less file, so
        // the joining job's own size is the check.
        let rig = try Rig("join-size-\(taggedBytes)")
        defer { rig.cleanUp() }
        let old = TransportFixtures.job(id: TransportFixtures.legacyID, attempt: TransportFixtures.attempt(1), url: Self.url, expected: taggedBytes, priority: .bulk)
        await rig.driver.addTask(description: BackgroundTaskTag(name: old.partialName, expectedBytes: taggedBytes).encoded, url: Self.url)
        let coordinator = rig.coordinator()
        #expect(await coordinator.reattached().map(\.name) == [old.partialName])
        let new = TransportFixtures.job(id: TransportFixtures.legacyID, attempt: TransportFixtures.attempt(1, epoch: 2), url: Self.url, expected: 5_000, priority: .bulk)
        let handle = await coordinator.start(new)
        // Joined, not duplicated (R-NET-3).
        #expect(await rig.driver.starts.isEmpty)
        let body = TransportFixtures.payload(Int(taggedBytes))
        await rig.driver.complete(old.partialName, body: body)
        let failure: TransferIntegrityFailure = taggedBytes < 5_000
            ? .truncated(expected: 5_000, received: taggedBytes)
            : .sizeMismatch(expected: 5_000, actual: taggedBytes)
        #expect(await run(handle).terminal == .failed(.integrity(failure)))
        // The OS's file stays in staging for the engine's discard or staging GC (R-CLN-3).
        #expect(rig.staging.contents[old.partialName] == body)
        await coordinator.invalidate()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: foreign or undecodable background tasks are cancelled at launch and never reported", .timeLimit(.minutes(1)))
    func foreignTasksAreCancelled() async throws {
        let rig = try Rig("foreign-tasks")
        defer { rig.cleanUp() }
        let foreign = await rig.driver.addTask(description: "some other app's tag", url: Self.url)
        let untagged = await rig.driver.addTask(description: nil, url: Self.url)
        let ours = BackgroundTaskTag(name: rig.job().partialName, expectedBytes: nil).encoded
        await rig.driver.addTask(description: ours, url: Self.url, bytesReceived: 512)

        let coordinator = rig.coordinator()
        #expect(await coordinator.reattached() == [ReattachedTransfer(name: rig.job().partialName, isRunning: true, bytesReceived: 512)])
        #expect(Set(await rig.driver.cancellations.map(\.taskIdentifier)) == [foreign, untagged])
        #expect(await rig.driver.liveNames == [rig.job().partialName])
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a background pause is reported paused and keeps its resume data", .timeLimit(.minutes(1)), arguments: [false, true])
    func pauseKeepsResumeData(_ dataFirst: Bool) async throws {
        let rig = try Rig("pause-\(dataFirst)")
        defer { rig.cleanUp() }
        let data = ResumeData(bytes: Data("archived".utf8))
        await rig.driver.setResumeData(data, holdingCancellationEvents: dataFirst)
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        await coordinator.cancel(job.partialName, keepingPartial: true)
        if dataFirst {
            await rig.driver.deliverHeldCancellations()
        }
        #expect(await run(handle).terminal == .paused(resumable: true))
        #expect(await coordinator.keptResumeData(for: job.partialName) == data)
        #expect(await rig.driver.cancellations.map(\.producingResumeData) == [true])
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: cancelling a background transfer ends it as cancelled by the client and keeps no resume data", .timeLimit(.minutes(1)))
    func cancelEndsTheTransfer() async throws {
        let rig = try Rig("cancel")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        handle.cancel()
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
        #expect(await coordinator.keptResumeData(for: job.partialName) == nil)
        #expect(await rig.driver.liveNames.isEmpty)
        // Cancelling a name no task writes changes nothing.
        await coordinator.cancel(rig.job(9).partialName, keepingPartial: true)
        #expect(await rig.driver.cancellations.count == 1)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: the coordinator owns a pump task only while a background transfer is outstanding", .timeLimit(.minutes(1)))
    func pumpOnlyWhileOutstanding() async throws {
        let rig = try Rig("pump")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        #expect(await !coordinator.isPumping)
        let job = rig.job()
        let handle = await coordinator.start(job)
        #expect(await coordinator.isPumping)
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        guard case .staged? = await run(handle).terminal else {
            Issue.record("not staged")
            return
        }
        #expect(await !coordinator.isPumping)
        // A second transfer starts a new pump over the same session stream.
        let second = await coordinator.start(rig.job(2, seed: 2))
        #expect(await coordinator.isPumping)
        await rig.driver.fail(rig.job(2, seed: 2).partialName, code: NSURLErrorTimedOut)
        #expect(await run(second).terminal == .failed(.transient(.timedOut, retryAfter: nil)))
        #expect(await !coordinator.isPumping)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: handling background events returns after every event that preceded didFinishEvents was staged", .timeLimit(.minutes(1)))
    func eventsBeforeFinishAreStaged() async throws {
        let rig = try Rig("events")
        defer { rig.cleanUp() }
        let first = rig.job(1, seed: 1)
        let second = rig.job(2, seed: 2)
        let launch = rig.coordinator()
        let handles = [await launch.start(first), await launch.start(second)]
        await rig.relaunch()
        await rig.driver.complete(first.partialName, body: TransportFixtures.payload(4_000, seed: 1))
        await rig.driver.complete(second.partialName, body: TransportFixtures.payload(4_000, seed: 2))
        await rig.driver.finishEvents()

        let staging = rig.staging
        let source = HTTPRemoteSource(
            configuration: HTTPSourceConfiguration(baseURL: URL(string: "https://cdn.example.com/")!, background: .enabled(rig.options)),
            staging: staging,
            policy: Self.policy,
            foreground: FakeTransferBackend(),
            background: rig.coordinator(),
            log: .tapOnly(nil)
        )
        // An identifier that is not this source's returns at once, without activating the session.
        await source.handleBackgroundEvents(identifier: "com.ztron.assetkit.bg.other.v1")
        #expect(await rig.driver.activations == 1)
        await source.handleBackgroundEvents(identifier: Self.identifier.rawValue)
        #expect(staging.contents[first.partialName] == TransportFixtures.payload(4_000, seed: 1))
        #expect(staging.contents[second.partialName] == TransportFixtures.payload(4_000, seed: 2))
        #expect(await source.reattachedTransfers().map(\.name) == [first.partialName, second.partialName].sorted())
        withExtendedLifetime(handles) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a didFinishEvents that arrives before anybody waits releases the next wait at once", .timeLimit(.minutes(1)))
    func earlyFinishIsKept() async throws {
        let rig = try Rig("early-finish")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.finishEvents()
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        guard case .staged? = await run(handle).terminal else {
            Issue.record("not staged")
            return
        }
        await coordinator.awaitBackgroundEvents()
        #expect(await coordinator.reattached().isEmpty)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: an unusable background session fails the transfer for a foreground retry and disables background for the process", .timeLimit(.minutes(1)))
    func unusableSessionDisablesBackground() async throws {
        let rig = try Rig("unusable")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        #expect(await coordinator.admits())
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.fail(job.partialName, code: -996)
        #expect(await run(handle).terminal == .failed(.transient(.backgroundSessionUnavailable(urlErrorCode: -996), retryAfter: nil)))
        #expect(await !coordinator.admits())
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: the background task cap counts re-attached tasks", .timeLimit(.minutes(1)))
    func taskCap() async throws {
        let rig = try Rig("cap", maxTasks: 2)
        defer { rig.cleanUp() }
        let launch = rig.coordinator()
        let first = await launch.start(rig.job(1, seed: 1))
        await rig.relaunch()
        let relaunched = rig.coordinator()
        _ = await relaunched.reattached()
        #expect(await relaunched.admits())
        let second = await relaunched.start(rig.job(2, seed: 2))
        #expect(await !relaunched.admits())
        withExtendedLifetime([first, second]) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: a background-mode delegate refuses bytes that arrived through a cross-origin redirect", .timeLimit(.minutes(1)))
    func crossOriginBackgroundBytesRefused() async throws {
        let rig = try Rig("cross-origin")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000), finalURL: URL(string: "https://elsewhere.example.net/v.bin"))
        #expect(await run(handle).terminal == .failed(.rejected(.redirectRefused(.unenforceableInBackground))))
        #expect(rig.staging.contents[job.partialName] == nil)
    }

    /// One background completion and the verdict it must produce.
    struct Completion: Sendable, CustomTestStringConvertible {
        var status: Int
        var bodyBytes: Int
        var expected: Int64
        var verdict: TransferUpdate?

        var testDescription: String {
            "\(self.status) \(self.bodyBytes) bytes, expected \(self.expected)"
        }
    }

    static let completions: [Completion] = [
        Completion(status: 200, bodyBytes: 3_000, expected: 4_000, verdict: .failed(.integrity(.truncated(expected: 4_000, received: 3_000)))),
        Completion(status: 200, bodyBytes: 5_000, expected: 4_000, verdict: .failed(.integrity(.sizeMismatch(expected: 4_000, actual: 5_000)))),
        Completion(status: 404, bodyBytes: 10, expected: 4_000, verdict: .failed(.permanentMissing(httpStatus: 404))),
        Completion(status: 503, bodyBytes: 10, expected: 4_000, verdict: .failed(.transient(.serverError(httpStatus: 503), retryAfter: nil))),
        Completion(status: 206, bodyBytes: 10, expected: 4_000, verdict: .failed(.rejected(.unexpectedStatus(206)))),
        Completion(status: 200, bodyBytes: 4_000, expected: 4_000, verdict: nil),
    ]

    @available(macOS 15.0, *)
    @Test("R-NET-7: a background download is staged only when its status and size are right", .timeLimit(.minutes(1)), arguments: BackgroundCoordinatorTests.completions)
    func backgroundCompletionChecks(_ completion: Completion) async throws {
        let rig = try Rig("completion-\(completion.status)-\(completion.bodyBytes)")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(expected: completion.expected)
        let handle = await coordinator.start(job)
        await rig.driver.complete(job.partialName, status: completion.status, body: TransportFixtures.payload(completion.bodyBytes))
        let terminal = await run(handle).terminal
        let staged = TransferUpdate.staged(StagedFile(name: job.partialName, byteCount: Int64(completion.bodyBytes), resumed: false, httpStatus: 200, etag: nil))
        #expect(terminal == (completion.verdict ?? staged))
    }

    @available(macOS 15.0, *)
    @Test("R-NET-6: a staging failure while adopting a background download maps to insufficientSpace", .timeLimit(.minutes(1)))
    func adoptionFailure() async throws {
        let rig = try Rig("adopt-enospc")
        defer { rig.cleanUp() }
        rig.staging.failNext(.adoptDownload, with: .insufficientSpace)
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(handle).terminal == .failed(.insufficientSpace(requiredBytes: 4_000)))
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: invalidation releases the session, ends waiting transfers and refuses later starts", .timeLimit(.minutes(1)))
    func invalidation() async throws {
        let rig = try Rig("invalidate")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = await coordinator.start(rig.job())
        await coordinator.invalidate()
        await coordinator.invalidate()
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
        #expect(await rig.driver.invalidations == 1)
        // The OS keeps its task (finishTasksAndInvalidate): nothing was cancelled.
        #expect(await rig.driver.cancellations.isEmpty)
        #expect(await run(await coordinator.start(rig.job(2))).terminal == .failed(.cancelled(.byClient)))
        #expect(await !coordinator.admits())
        await coordinator.awaitBackgroundEvents()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-10: a background transfer's priority change reaches its OS task", .timeLimit(.minutes(1)))
    func priorityChange() async throws {
        let rig = try Rig("priority")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        await coordinator.setPriority(.userInitiated, of: job.partialName)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
        #expect(await rig.driver.priorityChanges.map(\.priority) == [0.75])
        #expect(await rig.driver.starts.map(\.priority) == [0.25])
        withExtendedLifetime(handle) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: a background request carries the key only when the coordinator was given one, and only to allowed origins", .timeLimit(.minutes(1)))
    func backgroundRequestKey() async throws {
        let rig = try Rig("key")
        defer { rig.cleanUp() }
        let keyed = rig.coordinator(appKey: TransportFixtures.canaryKey)
        let first = await keyed.start(rig.job(1, seed: 1))
        // One coordinator per session stream: the keyless one runs in the next launch.
        await rig.relaunch()
        let keyless = rig.coordinator()
        let second = await keyless.start(rig.job(2, seed: 2))
        #expect(await rig.driver.starts.map(\.keyHeader) == [TransportFixtures.canaryValue, nil])
        let foreign = TransportFixtures.job(
            id: TransportFixtures.contentID(3), attempt: TransportFixtures.attempt(3), url: URL(string: "https://evil.example.net/x")!,
            expected: 1, priority: .bulk)
        #expect(await run(await keyed.start(foreign)).terminal == .failed(.rejected(.hostNotAllowed)))
        #expect(await rig.driver.starts.count == 2)
        withExtendedLifetime([first, second]) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a start that overlaps invalidation re-checks it after listing the tasks and starts nothing", .timeLimit(.minutes(1)))
    func startRacingInvalidation() async throws {
        let rig = try Rig("start-race")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        await rig.driver.holdNextSnapshot()
        let job = rig.job()
        let starting = Task { await coordinator.start(job) }
        await rig.awaitSignal("snapshot")
        await coordinator.invalidate()
        await rig.driver.releaseSnapshot()
        #expect(await run(await starting.value).terminal == .failed(.cancelled(.byClient)))
        #expect(await rig.driver.starts.isEmpty)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a pause whose cancellation is reported before the resume data returns still ends paused with that data", .timeLimit(.minutes(1)))
    func pauseWithCancellationFirst() async throws {
        let rig = try Rig("pause-event-first")
        defer { rig.cleanUp() }
        let data = ResumeData(bytes: Data("archived".utf8))
        await rig.driver.setResumeData(data, holdingCancellationEvents: false)
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.holdNextCancel(.afterReporting)
        handle.pause()
        await rig.awaitSignal("cancel")
        // The events barrier: once it returns, the pump has processed the reported cancellation.
        await rig.driver.finishEvents()
        await coordinator.awaitBackgroundEvents()
        await rig.driver.releaseCancel()
        #expect(await run(handle).terminal == .paused(resumable: true))
        #expect(await coordinator.keptResumeData(for: job.partialName) == data)
        // Nothing is outstanding any more, so no pump is left parked on the session stream (T2-10).
        #expect(await !coordinator.isPumping)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: the pump ends once it absorbed a pause's cancellation, also when the paused handle's consumer then goes away", .timeLimit(.minutes(1)))
    func pumpEndsAfterAbsorbedPause() async throws {
        let rig = try Rig("pause-absorbed")
        defer { rig.cleanUp() }
        await rig.driver.setResumeData(ResumeData(bytes: Data("archived".utf8)), holdingCancellationEvents: false)
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job()) as? BackgroundTransferHandle)
        await rig.driver.holdNextCancel(.afterReporting)
        handle.pause()
        await rig.awaitSignal("cancel")
        // The events barrier: once it returns, the pump has processed the reported cancellation.
        await rig.driver.finishEvents()
        await coordinator.awaitBackgroundEvents()
        // Only the pause's own call still waits (for the resume data); the session stream has nothing left for us.
        #expect(await !coordinator.isPumping)
        await coordinator.consumerGone(handle.name, token: handle.token)
        #expect(await !coordinator.isPumping)
        #expect(await rig.driver.cancellations.count == 1)
        await rig.driver.releaseCancel()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a background download that finishes while its pause is being requested ends staged", .timeLimit(.minutes(1)))
    func finishDuringPause() async throws {
        let rig = try Rig("finish-during-pause")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.holdNextCancel(.beforeCancelling)
        let pausing = Task { await coordinator.cancel(job.partialName, keepingPartial: true) }
        await rig.awaitSignal("cancel")
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(handle).terminal == .staged(StagedFile(name: job.partialName, byteCount: 4_000, resumed: false, httpStatus: 200, etag: nil)))
        await rig.driver.releaseCancel()
        await pausing.value
        #expect(await coordinator.keptResumeData(for: job.partialName) == nil)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: an invalidated session ends every waiting background transfer", .timeLimit(.minutes(1)))
    func sessionInvalidated() async throws {
        let rig = try Rig("session-invalid")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = await coordinator.start(rig.job())
        await rig.driver.reportInvalidation()
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a second start for content already attached replaces the first handle, which ends cancelled", .timeLimit(.minutes(1)))
    func secondAttachReplacesTheFirst() async throws {
        let rig = try Rig("double-attach")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        let first = await coordinator.start(job)
        let second = await coordinator.start(rig.job(2))
        #expect(second.attempt == job.attempt)
        #expect(await run(first).terminal == .failed(.cancelled(.byClient)))
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        guard case .staged? = await run(second).terminal else {
            Issue.record("not staged")
            return
        }
        #expect(await rig.driver.starts.count == 1)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: unclaimed outcomes beyond the task cap drop the oldest, whose file stays in staging", .timeLimit(.minutes(1)))
    func outcomeBufferIsBounded() async throws {
        let rig = try Rig("outcome-cap", maxTasks: 1)
        defer { rig.cleanUp() }
        let older = rig.job(1, seed: 1)
        let newer = rig.job(2, seed: 2)
        let launch = rig.coordinator()
        let handles = [await launch.start(older), await launch.start(newer)]
        await rig.relaunch()
        await rig.driver.complete(older.partialName, body: TransportFixtures.payload(4_000, seed: 1))
        await rig.driver.complete(newer.partialName, body: TransportFixtures.payload(4_000, seed: 2))
        await rig.driver.finishEvents()
        let relaunched = rig.coordinator()
        await relaunched.awaitBackgroundEvents()
        #expect(await relaunched.reattached().map(\.name) == [newer.partialName])
        #expect(rig.staging.contents[older.partialName] == TransportFixtures.payload(4_000, seed: 1))
        withExtendedLifetime(handles) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-10: a priority change through the background handle reaches its OS task, an unknown name changes nothing", .timeLimit(.minutes(1)))
    func priorityThroughHandle() async throws {
        let rig = try Rig("priority-handle")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        await coordinator.setPriority(.userInitiated, of: rig.job(7).partialName)
        #expect(await rig.driver.priorityChanges.isEmpty)
        await rig.driver.addTask(description: "foreign", url: Self.url)
        let handle = await coordinator.start(rig.job())
        handle.setPriority(.userInitiated)
        await rig.awaitSignal("priority")
        #expect(await rig.driver.priorityChanges.map(\.priority) == [0.75])
        // Only named tasks are live transfers.
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: dropping a background handle before its outcome cancels the OS task", .timeLimit(.minutes(1)))
    func droppedHandleCancels() async throws {
        let rig = try Rig("dropped")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job()
        do {
            let handle = await coordinator.start(job)
            #expect(handle.id == job.id)
        }
        await rig.awaitSignal("cancelled")
        #expect(await rig.driver.cancellations.map(\.producingResumeData) == [false])
        #expect(await rig.driver.liveNames.isEmpty)
    }

    @MainActor
    @Test("R-NET-3: the events relay keeps a handler only for our identifiers and completes it once")
    func relay() {
        let relay = BackgroundEventsRelay()
        var calls = 0
        #expect(!relay.accept(identifier: "com.other.app.bg.default.v1") { calls += 1 })
        #expect(!relay.hasHandler(for: "com.other.app.bg.default.v1"))
        let ours = Self.identifier.rawValue
        #expect(String(describing: Self.identifier) == ours)
        #expect(relay.accept(identifier: ours) { calls += 1 })
        #expect(relay.hasHandler(for: ours))
        relay.complete(identifier: ours)
        relay.complete(identifier: ours)
        #expect(calls == 1)
        #expect(!relay.hasHandler(for: ours))
    }

    @Test("R-NET-3: the background task tag round-trips through taskDescription with its continuation flag, rejects foreign or over-long tags, and labels a download")
    func tagCodec() throws {
        let seed: UInt64 = 0x5eed_7a6
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for _ in 0..<500 {
            let hash = ContentHash(w0: next(), w1: next(), w2: next(), w3: next())
            let name = StagingFileName(transfer: .content(hash), attempt: TransferAttempt(epoch: next() % 1_000, sequence: UInt32(truncatingIfNeeded: next())), kind: .partial)
            let expected: Int64? = next() % 4 == 0 ? nil : Int64(next() % (1 << 40))
            let tag = BackgroundTaskTag(name: name, expectedBytes: expected, createdFromResumeData: next() % 2 == 0)
            #expect(BackgroundTaskTag(decoding: tag.encoded) == tag, "seed \(seed)")
            // Any mutation either fails to decode or decodes to a tag that re-encodes to itself: never a trap.
            var bytes = Array(tag.encoded.utf8)
            bytes[Int(next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: next())
            if let mutated = BackgroundTaskTag(decoding: String(decoding: bytes, as: UTF8.self)) {
                #expect(BackgroundTaskTag(decoding: mutated.encoded) == mutated, "seed \(seed)")
            }
        }
        let name = rigName()
        for foreign in [
            nil, "", "ztak1", "ztak1 \(name.rawValue)", "ztak2 \(name.rawValue) 10", "ztak1 \(name.rawValue) 10 pause",
            "ztak1 \(name.with(kind: .sidecar).rawValue) 10", "ztak1 \(name.rawValue) -5", "ztak1 \(name.rawValue) +5",
            "ztak1 \(name.rawValue) 12345678901234567890", "ztak1 \(name.rawValue)  10", "ztak1 not-a-name 10",
            "ztak1 \(name.rawValue) " + String(repeating: "1", count: 300),
            "ztak1 \(name.rawValue) 10 Resume", "ztak1 \(name.rawValue) 10 resume extra", "ztak1 \(name.rawValue) 10 resume ",
            "ztak1 \(name.rawValue) 10  resume", "ztak1 \(name.rawValue) resume 10",
        ] as [String?] {
            #expect(BackgroundTaskTag(decoding: foreign) == nil, "\(String(describing: foreign))")
        }
        #expect(BackgroundTaskTag(decoding: "ztak1 \(name.rawValue) -")?.expectedBytes == nil)
        // A fresh download is written exactly as before the flag existed, so a tag an earlier build left with the OS
        // decodes, as a fresh download; only a task created from resume data carries the fourth field.
        #expect(BackgroundTaskTag(name: name, expectedBytes: 10).encoded == "ztak1 \(name.rawValue) 10")
        #expect(BackgroundTaskTag(decoding: "ztak1 \(name.rawValue) 10") == BackgroundTaskTag(name: name, expectedBytes: 10, createdFromResumeData: false))
        #expect(BackgroundTaskTag(name: name, expectedBytes: nil, createdFromResumeData: true).encoded == "ztak1 \(name.rawValue) - resume")
        #expect(BackgroundTaskTag(decoding: "ztak1 \(name.rawValue) 10 resume") == BackgroundTaskTag(name: name, expectedBytes: 10, createdFromResumeData: true))
        // A labelled download carries the tag, the lane's priority and, when known, the size as the OS's hint.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let sized = session.downloadTask(with: Self.url)
        BackgroundTaskTag(name: name, expectedBytes: 4_000).label(sized, priority: 0.25)
        #expect(BackgroundTaskTag(decoding: sized.taskDescription) == BackgroundTaskTag(name: name, expectedBytes: 4_000))
        #expect(sized.priority == 0.25 && sized.countOfBytesClientExpectsToReceive == 4_000)
        let unsized = session.downloadTask(with: Self.url)
        BackgroundTaskTag(name: name, expectedBytes: nil).label(unsized, priority: 0.75)
        #expect(unsized.priority == 0.75 && unsized.countOfBytesClientExpectsToReceive == NSURLSessionTransferSizeUnknown)
    }

    private func rigName() -> StagingFileName {
        StagingFileName(transfer: TransportFixtures.contentID(9), attempt: TransportFixtures.attempt(3), kind: .partial)
    }
}
