import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-3, R-NET-7: the background coordinator's awaits interleaved with controls, starts, the pump and launch
/// re-attachment (REENTRANCY rows D-2, D-5, D-7), each ordering forced through `FakeBackgroundSessionDriver`'s holds
/// and the events barrier, never by timing.
@Suite("Background coordinator interleavings")
struct BackgroundInterleavingTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    static func staged(_ job: TransferJob, bytes: Int64 = 4_000) -> TransferUpdate {
        .staged(StagedFile(name: job.partialName, byteCount: bytes, resumed: false, httpStatus: 200, etag: nil))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a start during a cancel or pause of the same content creates its own download and each handle ends as its own control asked", .timeLimit(.minutes(1)), arguments: [false, true])
    func startDuringControl(_ pause: Bool) async throws {
        let rig = try Rig("control-vs-start-\(pause)")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = rig.job(1)
        let second = rig.job(2)
        let earlier = await coordinator.start(first)
        await rig.driver.holdNextCancel(.beforeCancelling)
        if pause {
            earlier.pause()
        } else {
            earlier.cancel()
        }
        await rig.awaitSignal("cancel")
        let later = await coordinator.start(second)
        #expect(later.attempt == second.attempt)
        #expect(await rig.driver.starts.map(\.name) == [first.partialName, second.partialName])
        await rig.driver.releaseCancel()
        #expect(await run(earlier).terminal == (pause ? .paused(resumable: false) : .failed(.cancelled(.byClient))))
        await rig.driver.complete(second.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(later).terminal == Self.staged(second))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a replaced handle's controls and its terminated stream never reach the transfer that replaced it", .timeLimit(.minutes(1)))
    func replacedHandleControlsNothing() async throws {
        let rig = try Rig("replaced-handle")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(1)
        let replaced = try #require(await coordinator.start(job) as? BackgroundTransferHandle)
        let replacing = await coordinator.start(rig.job(2))
        #expect(replacing.attempt == job.attempt)
        #expect(await run(replaced).terminal == .failed(.cancelled(.byClient)))
        // What the replaced handle's control hops and its stream's termination deliver, in a known order.
        await coordinator.control(replaced.name, token: replaced.token, keepingPartial: false)
        await coordinator.control(replaced.name, token: replaced.token, keepingPartial: true)
        await coordinator.setPriority(.userInitiated, of: replaced.name, token: replaced.token)
        await coordinator.consumerGone(replaced.name, token: replaced.token)
        #expect(await rig.driver.cancellations.isEmpty)
        #expect(await rig.driver.priorityChanges.isEmpty)
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(replacing).terminal == Self.staged(job))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: a priority change from a handle replaced while it listed the tasks never reaches the transfer that replaced it", .timeLimit(.minutes(1)))
    func replacedDuringPriorityChange() async throws {
        let rig = try Rig("replaced-during-priority")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(1)
        let first = try #require(await coordinator.start(job) as? BackgroundTransferHandle)
        await rig.driver.holdNextSnapshot(.afterListing)
        let changing = Task { await coordinator.setPriority(.userInitiated, of: first.name, token: first.token) }
        await rig.awaitSignal("snapshot")
        // A later start for the same content joins the live task while the first handle's listing is in flight.
        let second = await coordinator.start(rig.job(2))
        #expect(second.attempt == job.attempt)
        await rig.driver.releaseSnapshot()
        await changing.value
        #expect(await rig.driver.priorityChanges.isEmpty)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        #expect(await run(first).terminal == .failed(.cancelled(.byClient)))
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(second).terminal == Self.staged(job))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: dropping a handle while a later start lists the tasks never ends the later transfer", .timeLimit(.minutes(1)))
    func dropDuringStart() async throws {
        let rig = try Rig("drop-during-start")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = rig.job(1)
        let second = rig.job(2)
        let starting: Task<any TransferHandle, Never>
        do {
            let dropped = await coordinator.start(first)
            await rig.driver.holdNextSnapshot(.afterListing)
            starting = Task { await coordinator.start(second) }
            await rig.awaitSignal("snapshot")
            withExtendedLifetime(dropped) {}
        }
        // The dropped stream cancels its OS task while the later start holds a listing that still names it.
        await rig.awaitSignal("cancelled")
        await rig.driver.releaseSnapshot()
        let later = await starting.value
        guard later.attempt == second.attempt else {
            Issue.record("the later start joined the task being cancelled")
            await coordinator.invalidate()
            return
        }
        await rig.driver.complete(second.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(later).terminal == Self.staged(second))
        #expect(await rig.driver.cancellations.count == 1)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a second cancel that finds the task already gone keeps a stale listing from joining it while the first is still ending it", .timeLimit(.minutes(1)))
    func secondCancelKeepsTheTaskEnding() async throws {
        let rig = try Rig("second-cancel")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = rig.job(1)
        let second = rig.job(2)
        let earlier = await coordinator.start(first)
        // The cancellation's session event waits, so the pump cannot process the first task's end meanwhile.
        await rig.driver.setResumeData(nil, holdingCancellationEvents: true)
        await rig.driver.holdNextSnapshot(.afterListing)
        let starting = Task { await coordinator.start(second) }
        await rig.awaitSignal("snapshot")
        await coordinator.cancel(first.partialName, keepingPartial: false)
        // The OS task is gone now: this cancel finds nothing, while the first one's end is still unprocessed.
        await coordinator.cancel(first.partialName, keepingPartial: false)
        #expect(await rig.driver.cancellations.count == 1)
        await rig.driver.releaseSnapshot()
        let later = await starting.value
        #expect(later.attempt == second.attempt)
        await rig.driver.deliverHeldCancellations()
        #expect(await run(earlier).terminal == .failed(.cancelled(.byClient)))
        await rig.driver.complete(second.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(later).terminal == Self.staged(second))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a start whose listing names a task the pump already ended creates a new download instead of waiting forever", .timeLimit(.minutes(1)))
    func staleListingAfterFailure() async throws {
        let rig = try Rig("stale-listing")
        defer { rig.cleanUp() }
        let first = rig.job(1)
        let second = rig.job(2)
        let firstLaunch = await rig.coordinator().start(first)
        await rig.relaunch()
        let coordinator = rig.coordinator()
        #expect(await coordinator.reattached() == [ReattachedTransfer(name: first.partialName, isRunning: true, bytesReceived: 0)])
        await rig.driver.holdNextSnapshot(.afterListing)
        let starting = Task { await coordinator.start(second) }
        await rig.awaitSignal("snapshot")
        // The OS fails the listed task; nobody waits for it, so the pump drops the failure. The events barrier
        // returns only after the pump processed it.
        await rig.driver.fail(first.partialName, code: NSURLErrorTimedOut)
        await rig.driver.finishEvents()
        await coordinator.awaitBackgroundEvents()
        await rig.driver.releaseSnapshot()
        let later = await starting.value
        guard later.attempt == second.attempt else {
            Issue.record("the start attached to a task whose terminal was already processed")
            await coordinator.invalidate()
            return
        }
        await rig.driver.complete(second.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(later).terminal == Self.staged(second))
        #expect(await coordinator.admits())
        #expect(await !coordinator.isPumping)
        withExtendedLifetime(firstLaunch) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: re-attachment that overlaps a finished download reports it once, as staged, and keeps no phantom live task", .timeLimit(.minutes(1)))
    func reattachOverlappingFinish() async throws {
        let rig = try Rig("reattach-overlap", maxTasks: 1)
        defer { rig.cleanUp() }
        // A foreign task listed before ours: its cancellation is the await re-attachment is held in.
        await rig.driver.addTask(description: "some other app's tag", url: BackgroundCoordinatorTests.url)
        let job = rig.job(1)
        let firstLaunch = await rig.coordinator().start(job)
        await rig.relaunch()
        let coordinator = rig.coordinator()
        let waiting = Task { await coordinator.awaitBackgroundEvents() }
        await rig.driver.holdNextCancel(.beforeCancelling)
        let reattaching = Task { await coordinator.reattached() }
        await rig.awaitSignal("cancel")
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        await rig.driver.finishEvents()
        await waiting.value
        await rig.driver.releaseCancel()
        #expect(await reattaching.value == [ReattachedTransfer(name: job.partialName, isRunning: false, bytesReceived: 4_000)])
        #expect(await coordinator.admits())
        #expect(await !coordinator.isPumping)
        withExtendedLifetime(firstLaunch) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: an outcome reported at re-attachment is not handed out again, since launch reconciliation owns its file", .timeLimit(.minutes(1)))
    func reportedOutcomeIsHandedOver() async throws {
        let rig = try Rig("reported-once")
        defer { rig.cleanUp() }
        let job = rig.job(1)
        let firstLaunch = await rig.coordinator().start(job)
        await rig.relaunch()
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        await rig.driver.finishEvents()
        let coordinator = rig.coordinator()
        await coordinator.awaitBackgroundEvents()
        #expect(await coordinator.reattached() == [ReattachedTransfer(name: job.partialName, isRunning: false, bytesReceived: 4_000)])
        #expect(await coordinator.reattached().isEmpty)
        // Launch reconciliation adopted or collected the file meanwhile: a later start must not be handed it.
        await rig.staging.discard(job.partialName)
        let next = rig.job(2)
        let handle = await coordinator.start(next)
        #expect(handle.attempt == next.attempt)
        #expect(await rig.driver.starts.map(\.name) == [job.partialName, next.partialName])
        withExtendedLifetime([firstLaunch, handle]) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a download that finishes while nobody waits is handed to the next start for its content, not downloaded again", .timeLimit(.minutes(1)))
    func unreportedOutcomeIsHandedOut() async throws {
        let rig = try Rig("handed-out")
        defer { rig.cleanUp() }
        let job = rig.job(1)
        let firstLaunch = await rig.coordinator().start(job)
        await rig.relaunch()
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        await rig.driver.finishEvents()
        let coordinator = rig.coordinator()
        await coordinator.awaitBackgroundEvents()
        let next = await coordinator.start(rig.job(2))
        #expect(next.attempt == job.attempt)
        #expect(await run(next).terminal == Self.staged(job))
        #expect(await rig.driver.starts.count == 1)
        withExtendedLifetime(firstLaunch) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a buffered download is handed only to a start that expects its size, else a new download is created", .timeLimit(.minutes(1)))
    func bufferedOutcomeOfAnotherSize() async throws {
        let rig = try Rig("buffered-other-size")
        defer { rig.cleanUp() }
        // Checksum-less identities are keyed by identifier and path only: the manifest may change their size.
        let legacy = { (sequence: UInt32, expected: Int64) in
            TransportFixtures.job(
                id: TransportFixtures.legacyID, attempt: TransportFixtures.attempt(sequence), url: BackgroundCoordinatorTests.url, expected: expected, priority: .bulk)
        }
        let job = legacy(1, 4_000)
        let firstLaunch = await rig.coordinator().start(job)
        await rig.relaunch()
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        await rig.driver.finishEvents()
        let coordinator = rig.coordinator()
        await coordinator.awaitBackgroundEvents()
        let changed = legacy(2, 5_000)
        let next = await coordinator.start(changed)
        #expect(next.attempt == changed.attempt)
        #expect(await rig.driver.starts.map(\.name) == [job.partialName, changed.partialName])
        await rig.driver.complete(changed.partialName, body: TransportFixtures.payload(5_000))
        #expect(await run(next).terminal == Self.staged(changed, bytes: 5_000))
        withExtendedLifetime(firstLaunch) {}
    }

    /// One job the background path cannot bound, and why.
    struct Unbounded: Sendable, CustomTestStringConvertible {
        var expected: Int64?
        var maxBytes: Int64

        var testDescription: String {
            "byteSize \(String(describing: self.expected)), cap \(self.maxBytes)"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: the background path takes only transfers whose byteSize is known and within the cap", .timeLimit(.minutes(1)), arguments: [
        Unbounded(expected: nil, maxBytes: 1_000), Unbounded(expected: 4_000, maxBytes: 1_000),
    ])
    func unboundedJobsAreSentBack(_ job: Unbounded) async throws {
        let rig = try Rig("unbounded-\(job.expected ?? -1)")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let refused = TransportFixtures.job(
            id: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), url: BackgroundCoordinatorTests.url,
            expected: job.expected, maxBytes: job.maxBytes, priority: .bulk)
        // The OS downloads a background task whole before we see a byte, so the cap could only be checked after
        // the fact: such a transfer goes back to the foreground, whose size guard aborts while streaming.
        #expect(await run(await coordinator.start(refused)).terminal == .failed(.transient(.backgroundSessionUnavailable(urlErrorCode: NSURLErrorUnknown), retryAfter: nil)))
        // The source's path declines such a job without a failure that would disable background for the process.
        #expect(await coordinator.startIfAdmitted(refused) == nil)
        #expect(await rig.driver.starts.isEmpty)
        #expect(await coordinator.admits())
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a start for the very attempt whose task is being cancelled is refused as a name clash", .timeLimit(.minutes(1)))
    func sameAttemptDuringCancel() async throws {
        let rig = try Rig("same-attempt")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(1)
        let handle = await coordinator.start(job)
        await rig.driver.holdNextCancel(.beforeCancelling)
        handle.cancel()
        await rig.awaitSignal("cancel")
        let again = await coordinator.start(job)
        await rig.driver.releaseCancel()
        #expect(await run(again).terminal == .failed(.transient(.localIO(posixCode: EEXIST), retryAfter: nil)))
        #expect(await run(handle).terminal == .failed(.cancelled(.byClient)))
        #expect(await rig.driver.starts.count == 1)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: resume data kept by background pauses is bounded by the task cap", .timeLimit(.minutes(1)))
    func keptResumeDataIsBounded() async throws {
        let rig = try Rig("resume-bound", maxTasks: 1)
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let older = rig.job(1, seed: 1)
        let newer = rig.job(2, seed: 2)
        for (index, job) in [older, newer].enumerated() {
            let data = ResumeData(bytes: Data("archive-\(index)".utf8))
            await rig.driver.setResumeData(data, holdingCancellationEvents: false)
            let handle = await coordinator.start(job)
            await coordinator.cancel(job.partialName, keepingPartial: true)
            #expect(await run(handle).terminal == .paused(resumable: true))
            #expect(await coordinator.keptResumeData(for: job.partialName) == data)
        }
        #expect(await coordinator.keptResumeData(for: older.partialName) == nil)
    }

    // MARK: - Priority order (Stage 3, S3-CONC-01; REENTRANCY row D-9)

    /// The engine promotes a bulk background transfer (a user waiter joined) and, while that change lists the tasks,
    /// demotes it again (the waiter withdrew). The demotion is the newest request, so the OS task ends at the bulk
    /// priority 0.25 and the coordinator reports that value: the promotion, whose listing returns last, changes nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: the newest of two overlapping priority changes is the one a background transfer's OS task keeps", .timeLimit(.minutes(1)))
    func newestPriorityChangeWins() async throws {
        let rig = try Rig("newest-priority-demotion")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job()) as? BackgroundTransferHandle)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        // The promotion's listing is held after it was taken...
        await rig.driver.holdNextSnapshot(.afterListing)
        let promotion = Task { await coordinator.setPriority(.userInitiated, of: handle.name, token: handle.token) }
        await rig.awaitSignal("snapshot")
        // ...while the later demotion runs to its end.
        await coordinator.setPriority(.bulk, of: handle.name, token: handle.token)
        await rig.driver.releaseSnapshot()
        await promotion.value
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes.last == 0.25, "the newest request was bulk (0.25), the OS task ends at \(String(describing: changes.last)); changes \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        withExtendedLifetime(handle) {}
    }

    /// The direction H-4 depends on: an older demotion whose listing returns after a newer promotion must not leave
    /// the OS task a user now waits for at the bulk priority.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: a newer promotion is kept over an older demotion whose listing returns later", .timeLimit(.minutes(1)))
    func newestPromotionWins() async throws {
        let rig = try Rig("newest-priority-promotion")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job()) as? BackgroundTransferHandle)
        await coordinator.setPriority(.userInitiated, of: handle.name, token: handle.token)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
        await rig.driver.holdNextSnapshot(.afterListing)
        let demotion = Task { await coordinator.setPriority(.bulk, of: handle.name, token: handle.token) }
        await rig.awaitSignal("snapshot")
        await coordinator.setPriority(.userInitiated, of: handle.name, token: handle.token)
        await rig.driver.releaseSnapshot()
        await demotion.value
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes.last == 0.75, "the newest request was userInitiated (0.75), the OS task ends at \(String(describing: changes.last)); changes \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
        withExtendedLifetime(handle) {}
    }

    /// The engine calls a handle's controls synchronously on every lane change (ADR-021 keeps controls ordered), so
    /// the handle must deliver them in that order: the second change starts only after the first one, held at its
    /// listing, reached the OS task, and the task ends at the second change's value.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: a background handle's priority changes reach its OS task in the order the engine made them", .timeLimit(.minutes(1)))
    func handleControlsInOrder() async throws {
        let rig = try Rig("handle-controls-in-order")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job()) as? BackgroundTransferHandle)
        await rig.driver.holdNextSnapshot(.afterListing)
        handle.setPriority(.userInitiated)
        await rig.awaitSignal("snapshot")
        handle.setPriority(.bulk)
        // A whole listing runs through the coordinator and the driver while the first change is held: the second
        // change, made after it, is not delivered meanwhile.
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        let early = await rig.driver.priorityChanges.map(\.priority)
        #expect(early.isEmpty, "a later change overtook the held one: \(early)")
        await rig.driver.releaseSnapshot()
        await rig.awaitSignal("priority")
        await rig.awaitSignal("priority")
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes == [0.75, 0.25], "each change reaches the OS task in the order it was made: \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        withExtendedLifetime(handle) {}
    }
}
