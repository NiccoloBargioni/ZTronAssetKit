import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-8 on the background path (orchestrator ruling D-14.2): the resume data a background pause kept is handed
/// to the driver when the engine restarts the same content, used once, and a refused continuation falls back to a
/// fresh download through `resumeRejected`.
@Suite("Background resume")
struct BackgroundResumeTests {
    @available(macOS 15.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    /// Pauses a fresh background transfer of `job` whose cancellation returns `data`.
    @available(macOS 15.0, *)
    static func pause(_ job: TransferJob, returning data: ResumeData?, rig: Rig, coordinator: BackgroundTransferCoordinator) async -> TransferUpdate? {
        await rig.driver.setResumeData(data, holdingCancellationEvents: false)
        let handle = await coordinator.start(job)
        handle.pause()
        return await run(handle).terminal
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a paused background transfer restarted by the engine continues from the kept resume data, once", .timeLimit(.minutes(1)))
    func restartContinuesFromKeptData() async throws {
        let rig = try Rig("bg-resume-continue")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let data = ResumeData(bytes: Data("archive".utf8))
        let paused = rig.job(1)
        #expect(await Self.pause(paused, returning: data, rig: rig, coordinator: coordinator) == .paused(resumable: true))
        let restart = rig.job(2)
        let resumed = await coordinator.start(restart)
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, data])
        #expect(await rig.driver.starts.last?.name == restart.partialName)
        // Used once: nothing is kept for another restart.
        #expect(await coordinator.keptResumeData(for: paused.partialName) == nil)
        // The OS continued with a ranged request and moves the whole body into staging.
        let body = TransportFixtures.payload(4_000)
        await rig.driver.complete(restart.partialName, status: 206, body: body, contentRangeStart: 1_000)
        #expect(await run(resumed).terminal == .staged(StagedFile(name: restart.partialName, byteCount: 4_000, resumed: true, httpStatus: 206, etag: nil)))
        #expect(rig.staging.contents[restart.partialName] == body)
    }

    /// How the OS reports resume data that can no longer be used.
    enum StaleSignal: Sendable, CaseIterable {
        /// −1002: the resume state is unusable (transport-1 TR1-4).
        case unusableResumeState
        /// 416: the range the OS asked for is not satisfiable any more.
        case unsatisfiableRange
        /// A 206 without a `Content-Range`: nothing says where its bytes belong.
        case partialWithoutRange
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: stale background resume data falls back to a fresh download through resumeRejected", .timeLimit(.minutes(1)), arguments: StaleSignal.allCases)
    func staleDataFallsBackToFresh(_ signal: StaleSignal) async throws {
        let rig = try Rig("bg-resume-stale-\(signal)")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let data = ResumeData(bytes: Data("stale".utf8))
        #expect(await Self.pause(rig.job(1), returning: data, rig: rig, coordinator: coordinator) == .paused(resumable: true))
        let continued = rig.job(2)
        let handle = await coordinator.start(continued)
        switch signal {
        case .unusableResumeState:
            await rig.driver.fail(continued.partialName, code: NSURLErrorUnsupportedURL)
        case .unsatisfiableRange:
            await rig.driver.complete(continued.partialName, status: 416, body: Data())
        case .partialWithoutRange:
            await rig.driver.complete(continued.partialName, status: 206, body: TransportFixtures.payload(3_000))
        }
        #expect(await run(handle).terminal == .failed(.transient(.resumeRejected, retryAfter: nil)))
        // The engine's next attempt (immediate, ARCHITECTURE §7.6) downloads afresh: the data was used up.
        let fresh = rig.job(3)
        let restarted = await coordinator.start(fresh)
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, data, nil])
        await rig.driver.complete(fresh.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(restarted).terminal == .staged(StagedFile(name: fresh.partialName, byteCount: 4_000, resumed: false, httpStatus: 200, etag: nil)))
        // On a download that did not continue anything the same signals keep their meaning (no retry loop, D-4).
        let other = rig.job(4, seed: 2)
        let plain = await coordinator.start(other)
        switch signal {
        case .unusableResumeState:
            await rig.driver.fail(other.partialName, code: NSURLErrorUnsupportedURL)
            #expect(await run(plain).terminal == .failed(.rejected(.invalidURL)))
        case .unsatisfiableRange:
            await rig.driver.complete(other.partialName, status: 416, body: Data())
            #expect(await run(plain).terminal == .failed(.rejected(.unexpectedStatus(416))))
        case .partialWithoutRange:
            await rig.driver.complete(other.partialName, status: 206, body: TransportFixtures.payload(3_000))
            #expect(await run(plain).terminal == .failed(.rejected(.unexpectedStatus(206))))
        }
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: any other failure of a continued background download keeps its meaning, and the data is not used again", .timeLimit(.minutes(1)))
    func otherFailuresOfAContinuation() async throws {
        let rig = try Rig("bg-resume-timeout")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let data = ResumeData(bytes: Data("archive".utf8))
        #expect(await Self.pause(rig.job(1), returning: data, rig: rig, coordinator: coordinator) == .paused(resumable: true))
        let continued = rig.job(2)
        let handle = await coordinator.start(continued)
        await rig.driver.fail(continued.partialName, code: NSURLErrorTimedOut)
        // A timeout is a timeout (backoff, ARCHITECTURE §7.6), not a refused resume.
        #expect(await run(handle).terminal == .failed(.transient(.timedOut, retryAfter: nil)))
        let next = await coordinator.start(rig.job(3))
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, data, nil])
        withExtendedLifetime(next) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a checksum-less background transfer is never resumed: its pause keeps no resume data", .timeLimit(.minutes(1)))
    func checksumLessPauseKeepsNothing() async throws {
        let rig = try Rig("bg-resume-legacy")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = { (sequence: UInt32) in
            TransportFixtures.job(id: TransportFixtures.legacyID, attempt: TransportFixtures.attempt(sequence), url: BackgroundCoordinatorTests.url, expected: 4_000, priority: .bulk)
        }
        let paused = job(1)
        #expect(await Self.pause(paused, returning: ResumeData(bytes: Data("legacy".utf8)), rig: rig, coordinator: coordinator) == .paused(resumable: false))
        #expect(await coordinator.keptResumeData(for: paused.partialName) == nil)
        let restarted = await coordinator.start(job(2))
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, nil])
        withExtendedLifetime(restarted) {}
    }

    /// The identity of a background download that was not created from resume data.
    enum Identity: Sendable, CaseIterable {
        /// Checksummed content: it may keep resume data, but this download was created without any.
        case content
        /// A checksum-less identity, which never keeps resume data (transport-1 TR1-3).
        case checksumLess
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a background download not created from resume data refuses a 206, even one with a Content-Range", .timeLimit(.minutes(1)), arguments: Identity.allCases)
    func freshDownloadRefusesPartialContent(_ identity: Identity) async throws {
        let rig = try Rig("bg-resume-fresh-206-\(identity)")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let id = identity == .content ? TransportFixtures.contentID(1) : TransportFixtures.legacyID
        let job = TransportFixtures.job(id: id, attempt: TransportFixtures.attempt(1), url: BackgroundCoordinatorTests.url, expected: 4_000, priority: .bulk)
        let handle = await coordinator.start(job)
        #expect(await rig.driver.starts.map(\.resumeData) == [nil])
        // Nobody asked for a range, so a ranged answer is not ours to adopt (D-4, ARCHITECTURE §6.3, TR1-3), even when
        // its size matches.
        await rig.driver.complete(job.partialName, status: 206, body: TransportFixtures.payload(4_000), contentRangeStart: 1_000)
        #expect(await run(handle).terminal == .failed(.rejected(.unexpectedStatus(206))))
        #expect(rig.staging.contents[job.partialName] == nil)
    }

    /// What the OS answers a continuation that a relaunched process re-attached.
    enum ReattachedAnswer: Sendable, CaseIterable {
        /// −1002: the resume state is unusable.
        case unusableResumeState
        /// 416: the range is not satisfiable any more.
        case unsatisfiableRange
        /// A 206 without a `Content-Range`.
        case partialWithoutRange
        /// A 206 with a `Content-Range`: the OS continued the data and moves the whole body.
        case rangedContinuation
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a continuation re-attached after a relaunch keeps its meaning: a refusal reads resumeRejected, a ranged answer is staged as resumed", .timeLimit(.minutes(1)), arguments: ReattachedAnswer.allCases)
    func continuationSurvivesRelaunch(_ answer: ReattachedAnswer) async throws {
        let rig = try Rig("bg-resume-relaunch-\(answer)")
        defer { rig.cleanUp() }
        let first = rig.coordinator()
        let data = ResumeData(bytes: Data("archive".utf8))
        #expect(await Self.pause(rig.job(1), returning: data, rig: rig, coordinator: first) == .paused(resumable: true))
        let continued = rig.job(2)
        // The first process's handle stays alive: dropping it would cancel the OS task, a killed process cancels nothing.
        let firstLaunch = await first.start(continued)
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, data])
        // The process dies while the OS still holds the (discretionary) continuation; the next process joins it.
        await rig.relaunch()
        let second = rig.coordinator()
        #expect(await second.reattached().map(\.name) == [continued.partialName])
        let joined = await second.start(rig.job(3))
        #expect(await rig.driver.starts.count == 2)
        switch answer {
        case .unusableResumeState:
            await rig.driver.fail(continued.partialName, code: NSURLErrorUnsupportedURL)
        case .unsatisfiableRange:
            await rig.driver.complete(continued.partialName, status: 416, body: Data())
        case .partialWithoutRange:
            await rig.driver.complete(continued.partialName, status: 206, body: TransportFixtures.payload(3_000))
        case .rangedContinuation:
            await rig.driver.complete(continued.partialName, status: 206, body: TransportFixtures.payload(4_000), contentRangeStart: 1_000)
        }
        // ARCHITECTURE §7.6: resumeRejected makes the engine's next attempt immediate and fresh.
        let expected: TransferUpdate = answer == .rangedContinuation
            ? .staged(StagedFile(name: continued.partialName, byteCount: 4_000, resumed: true, httpStatus: 206, etag: nil))
            : .failed(.transient(.resumeRejected, retryAfter: nil))
        #expect(await run(joined).terminal == expected)
        withExtendedLifetime(firstLaunch) {}
    }

    /// What the OS answers a task an earlier build tagged without the continuation flag.
    enum UnflaggedAnswer: Sendable, CaseIterable {
        /// 416.
        case unsatisfiableRange
        /// A 206 with a `Content-Range`.
        case rangedPartial
        /// A 200 with the whole body.
        case whole
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a task tagged without the continuation flag is re-attached as a fresh download", .timeLimit(.minutes(1)), arguments: UnflaggedAnswer.allCases)
    func unflaggedTagIsFresh(_ answer: UnflaggedAnswer) async throws {
        let rig = try Rig("bg-resume-unflagged-\(answer)")
        defer { rig.cleanUp() }
        let old = rig.job(1)
        // The description an earlier build wrote: three fields, no flag. It must still decode (and mean "fresh").
        await rig.driver.addTask(description: "ztak1 \(old.partialName.rawValue) 4000", url: BackgroundCoordinatorTests.url)
        let coordinator = rig.coordinator()
        #expect(await coordinator.reattached().map(\.name) == [old.partialName])
        let joined = await coordinator.start(rig.job(2))
        #expect(await rig.driver.starts.isEmpty)
        let expected: TransferUpdate
        switch answer {
        case .unsatisfiableRange:
            await rig.driver.complete(old.partialName, status: 416, body: Data())
            // A fresh download never asked for a range: restarting it on a 416 would loop (D-4).
            expected = .failed(.rejected(.unexpectedStatus(416)))
        case .rangedPartial:
            await rig.driver.complete(old.partialName, status: 206, body: TransportFixtures.payload(4_000), contentRangeStart: 1_000)
            expected = .failed(.rejected(.unexpectedStatus(206)))
        case .whole:
            await rig.driver.complete(old.partialName, status: 200, body: TransportFixtures.payload(4_000))
            expected = .staged(StagedFile(name: old.partialName, byteCount: 4_000, resumed: false, httpStatus: 200, etag: nil))
        }
        #expect(await run(joined).terminal == expected)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a continued background download answered 200 (validator changed) stages the whole body as a fresh, non-resumed file", .timeLimit(.minutes(1)), arguments: [false, true])
    func continuationAnsweredWhole(_ relaunched: Bool) async throws {
        let rig = try Rig("bg-resume-whole-\(relaunched)")
        defer { rig.cleanUp() }
        let first = rig.coordinator()
        let data = ResumeData(bytes: Data("archive".utf8))
        let paused = rig.job(1)
        #expect(await Self.pause(paused, returning: data, rig: rig, coordinator: first) == .paused(resumable: true))
        let continued = rig.job(2)
        let firstLaunch = await first.start(continued)
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, data])
        #expect(await first.keptResumeData(for: paused.partialName) == nil)
        var waiting = firstLaunch
        if relaunched {
            // The process dies while the OS still holds the continuation; the next process joins it.
            await rig.relaunch()
            let second = rig.coordinator()
            #expect(await second.reattached().map(\.name) == [continued.partialName])
            waiting = await second.start(rig.job(3))
            #expect(await rig.driver.starts.count == 2)
        }
        // The validator changed: the origin ignores If-Range and sends the whole new body with a 200. It is a
        // complete download (hashed at publication), not a refusal: refusing it would cost a second full download.
        let body = TransportFixtures.payload(4_000, seed: 3)
        await rig.driver.complete(continued.partialName, status: 200, body: body)
        #expect(await run(waiting).terminal == .staged(StagedFile(name: continued.partialName, byteCount: 4_000, resumed: false, httpStatus: 200, etag: nil)))
        #expect(rig.staging.contents[continued.partialName] == body)
        withExtendedLifetime(firstLaunch) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: resume data the task cap evicted is not used: that restart downloads afresh", .timeLimit(.minutes(1)))
    func evictedDataIsNotUsed() async throws {
        let rig = try Rig("bg-resume-evicted", maxTasks: 1)
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let older = ResumeData(bytes: Data("older".utf8))
        let newer = ResumeData(bytes: Data("newer".utf8))
        #expect(await Self.pause(rig.job(1, seed: 1), returning: older, rig: rig, coordinator: coordinator) == .paused(resumable: true))
        #expect(await Self.pause(rig.job(2, seed: 2), returning: newer, rig: rig, coordinator: coordinator) == .paused(resumable: true))
        let first = await coordinator.start(rig.job(3, seed: 1))
        let second = await coordinator.start(rig.job(4, seed: 2))
        #expect(await rig.driver.starts.map(\.resumeData) == [nil, nil, nil, newer])
        withExtendedLifetime([first, second]) {}
    }
}
