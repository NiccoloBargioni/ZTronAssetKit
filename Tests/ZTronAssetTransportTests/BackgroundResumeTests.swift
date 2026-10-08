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
