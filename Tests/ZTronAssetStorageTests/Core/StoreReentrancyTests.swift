import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// H-5: store units held at a known point with `SteppedBlockingExecutor` while the actor serves other calls
/// (ADR-045, ARCHITECTURE §13.5 item 3).
@Suite("Core: reentrancy (H-5)")
struct StoreReentrancyTests {
    @Test("R-INT-2: a manifest change during the publish rename yields superseded and never returns the URL", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func manifestChangeDuringRename() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let bytes = CoreFixture.bytes(110)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        await metadata.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        await metadata.releaseNext()  // the claim
        try await metadata.requireHeldUnits(atLeast: 1)  // the placement (sidecar, barrier, rename) is now held
        let changed = CoreFixture.entry("a", CoreFixture.bytes(111))
        let applying = Task {
            try await harness.store.apply(CoreFixture.manifest([changed]), etag: nil, eviction: nil)
        }
        try await metadata.requireHeldUnits(atLeast: 2)  // apply's commit unit queued behind the placement
        await metadata.releaseNext()  // the rename runs; the record changed meanwhile
        await #expect(throws: StoreError.superseded(entry.identifier)) {
            try await publishing.value
        }
        await metadata.setHolding(false)
        _ = try await applying.value
        #expect(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil)
        #expect(await harness.sink.installed.location(for: entry.identifier, extensions: []) == nil)
        let key = CoreFixture.key(bytes)
        guard case .doomed(let info)? = await harness.state.core.blobTable[key] else {
            Issue.record("the superseded blob is not doomed")
            return
        }
        #expect(info.droppedInGeneration == 0 && info.reason == .unreferenced)
        // It never reached a committed generation, so acknowledgement and grace are all it waits for.
        _ = await harness.store.runDueWork()
        harness.time.advance(by: 10)
        #expect(await harness.store.runDueWork().reapedKeys == 1)
        #expect(!harness.exists(harness.layout.blobURL(key)))
    }

    @Test("R-CLN-5: two identifiers with identical bytes published concurrently keep the blob until both are removed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func concurrentIdenticalPublications() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let bytes = CoreFixture.bytes(120)
        let x = CoreFixture.entry("x", bytes)
        let y = CoreFixture.entry("y", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([x, y]), etag: nil, eviction: nil)
        let stagedX = try await harness.stage(bytes, for: x, sequence: 1)
        let stagedY = try await harness.stage(bytes, for: y, sequence: 2)
        await metadata.setHolding(true)
        let publishX = Task {
            try await harness.store.publish(stagedX, binding: [x.identifier], expecting: x.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 1)
        await metadata.releaseNext()  // X's claim; X then holds the key while its placement is held
        try await metadata.requireHeldUnits(atLeast: 1)
        let publishY = Task {
            try await harness.store.publish(stagedY, binding: [y.identifier], expecting: y.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        let held = await metadata.heldUnits
        let key = CoreFixture.key(bytes)
        await metadata.release(held[1])  // Y's claim: Y reaches the key while X's publication is in flight
        // Y hashes, then parks on the key X holds in `publishing` (REENTRANCY R3), before X's placement is released.
        try await CorePoll.until("Y parked on the key X publishes") {
            await harness.state.core.keyWaiters[key]?.count == 1
        }
        #expect(await harness.state.core.publishing.contains(key))
        await metadata.setHolding(false)
        let locationX = try #require(try await publishX.value[x.identifier])
        let locationY = try #require(try await publishY.value[y.identifier])
        #expect(locationX.url == locationY.url && locationX.url == harness.layout.blobURL(key))
        #expect(await harness.state.core.blobTable[key] == .live(references: 2))
        #expect(harness.fileSystem.operations.filter { $0.kind == .rename && $0.destination == harness.layout.blobURL(key) }.count == 1)

        _ = try await harness.store.apply(CoreFixture.manifest([y]), etag: nil, eviction: nil)
        harness.time.advance(by: 3_600)
        #expect(await harness.store.runDueWork().reapedKeys == 0)
        #expect(harness.content(harness.layout.blobURL(key)) == bytes, "y still references the blob")
        _ = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        harness.time.advance(by: 10)
        #expect(await harness.store.runDueWork().reapedKeys == 1)
        #expect(!harness.exists(harness.layout.blobURL(key)))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-CLN-10: a publish that lands during the adoption report's durable commit is not reported adopted", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func publishDuringAdoptionReport() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let a = CoreFixture.bytes(130)
        let b = CoreFixture.bytes(131)
        let entryA = CoreFixture.entry("a", a)
        let entryB = CoreFixture.entry("b", b)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entryA, entryB]), etag: nil, eviction: nil)
        try await harness.publish(a, [entryA], sequence: 1)
        let stagedB = try await harness.stage(b, for: entryB, sequence: 2)
        await metadata.setHolding(true)
        let reporting = Task {
            try await harness.store.adoptionReport()
        }
        try await metadata.requireHeldUnits(atLeast: 1)  // the durable commit holding the captured state
        let publishing = Task {
            try await harness.store.publish(stagedB, binding: [entryB.identifier], expecting: entryB.contentIdentity, urgency: .bulk)
        }
        try await metadata.requireHeldUnits(atLeast: 2)
        let commit = await metadata.heldUnits[0]
        await metadata.release(await metadata.heldUnits[1])  // B's claim
        try await metadata.requireHeldUnits(atLeast: 2)  // B's placement
        await metadata.release(await metadata.heldUnits[1])
        #expect(try await publishing.value[entryB.identifier] != nil)
        await metadata.release(commit)
        let report = try await reporting.value
        #expect(report.manifestRemotePaths == [entryA.remotePath, entryB.remotePath])
        #expect(report.adoptedRemotePaths == [entryA.remotePath], "B landed after the capture: not reported")
        await metadata.setHolding(false)
        // A later report, after B's generation is durable, includes it.
        #expect(try await harness.store.adoptionReport().adoptedRemotePaths == [entryA.remotePath, entryB.remotePath])
    }

    @Test("R-CLN-10: a pack is released only after the adopting generation is durably committed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func adoptionReportIsDurable() async throws {
        let time = ManualTimeSource()
        let fake = FakeFileSystem(time: time)
        let spy = SyncLevelSpy(fake)
        var policy = StoragePolicy()
        policy.allowUnverifiedAssets = true
        let store = AssetStore(configuration: CoreFixture.configuration(policy: policy), environment: CoreHarness.environment(fileSystem: spy, time: time))
        let bytes = CoreFixture.bytes(140)
        let entry = CoreFixture.entry("pack/a", bytes)
        let outside = CoreFixture.entry("other/b", CoreFixture.bytes(141))
        _ = try await store.open()
        _ = try await store.apply(CoreFixture.manifest([entry, outside]), etag: nil, eviction: nil)
        let sink = try await store.makeStagingSink()
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 1), kind: .partial)
        try sink.createPartial(name)
        _ = try sink.appendPartial(bytes, to: name)
        _ = try await store.publish(StagedFile(name: name, byteCount: 300, resumed: false, httpStatus: nil, etag: nil), binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .bulk)
        await store.testSetRetentionScope(.prefix("pack/"))
        let syncsBefore = spy.syncs.count
        let report = try await store.adoptionReport()
        #expect(report.adoptedRemotePaths == [entry.remotePath] && report.excludedRemotePaths == [outside.remotePath])
        let durable = spy.syncs[syncsBefore...].filter { $0.level == .full }.map(\.path)
        let layout = CoreFixture.layout
        #expect(durable == [layout.indexURL(.temporary).path, layout.root.path, layout.container.path, CoreFixture.base.path])
        // What the report claims is in the durable generation on disk.
        let onDisk = try IndexCodec.decode([UInt8](try fake.read(from: layout.indexURL(.current), offset: 0, maxLength: 1 << 20))).get()
        #expect(onDisk.records[entry.identifier]?.referencedBlob == CoreFixture.key(bytes))
        // Nothing to commit: the second report needs no further sync.
        let again = spy.syncs.count
        _ = try await store.adoptionReport()
        #expect(spy.syncs.count == again)
        // A durable commit that fails reports nothing.
        await store.markDirty(.soon)
        let tmp = URLMatcher(lastComponentSuffix: "index.tmp")
        fake.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(1), error: .noSpace))
        fake.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(2), error: .noSpace))
        await #expect(throws: StoreError.fileSystem(.noSpace)) {
            try await store.adoptionReport()
        }
    }

    @Test("R-SYN-8: point admission adds or updates one entry, commits it and keeps the fetched manifest's ETag out", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func pointAdmission() async throws {
        let harness = CoreHarness.make()
        let a = CoreFixture.bytes(150)
        let entryA = CoreFixture.entry("a", a)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entryA]), etag: ETag(rawValue: "\"m1\""), eviction: nil)
        try await harness.publish(a, [entryA])
        let twin = CoreFixture.entry("twin", a)
        try await harness.store.admit(twin)
        let view = try await harness.store.planningView()
        #expect(view.appliedManifest.entries.map(\.identifier) == ["a", "twin"])
        #expect(view.records["twin"]?.referencedBlob == CoreFixture.key(a), "admission adopts a blob already on disk")
        #expect(await harness.state.core.etag == ETag(rawValue: "\"m1\""))
        let committed = await harness.state.core.commits
        #expect(committed.committedSerial == committed.mutationSerial)
        let installs = await harness.sink.offeredKeys.count
        try await harness.store.admit(twin)
        #expect(await harness.sink.offeredKeys.count == installs, "an unchanged admission is a no-op")
        var renamed = twin
        renamed.tags = ["new"]
        try await harness.store.admit(renamed)
        #expect(try await harness.store.planningView().records["twin"]?.revision == 1)
        let changed = CoreFixture.entry("twin", CoreFixture.bytes(151))
        try await harness.store.admit(changed)
        #expect(try await harness.store.planningView().records["twin"]?.isStale == true)
    }

    /// Review round 3: `ValidatedManifest.digest` means "equal digests: nothing to reconcile". An admission changes the
    /// applied entries without a server payload, so the applied digest must stop matching the fetched one; otherwise
    /// a planner that skips `apply` on equal digests would never prune an admitted entry the server dropped again.
    @Test("R-SYN-8: after a point admission the applied digest matches no fetched manifest, so the server's manifest is applied again and prunes it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func admissionInvalidatesTheAppliedDigest() async throws {
        let harness = CoreHarness.make()
        let server = CoreFixture.manifest([CoreFixture.entry("a", CoreFixture.bytes(152))])
        _ = try await harness.store.open()
        _ = try await harness.store.apply(server, etag: ETag(rawValue: "\"m1\""), eviction: nil)
        #expect(try await harness.store.planningView().appliedManifest.digest == server.digest)
        try await harness.store.admit(CoreFixture.entry("extra", CoreFixture.bytes(153)))
        let first = try await harness.store.planningView().appliedManifest.digest
        #expect(first != server.digest, "the admitted state is no server payload")
        try await harness.store.admit(CoreFixture.entry("more", CoreFixture.bytes(154)))
        let second = try await harness.store.planningView().appliedManifest.digest
        #expect(second != first && second != server.digest, "every admission moves the digest")
        let unchanged = try await harness.store.planningView().appliedManifest.digest
        try await harness.store.admit(CoreFixture.entry("more", CoreFixture.bytes(154)))
        #expect(try await harness.store.planningView().appliedManifest.digest == unchanged, "a no-op admission changes nothing")
        // The digest is persisted with the admitted entries.
        await harness.store.close()
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        _ = try await reopened.store.open()
        let view = try await reopened.store.planningView()
        #expect(view.appliedManifest.digest == second)
        #expect(view.appliedManifest.entries.map(\.identifier) == ["a", "extra", "more"])
        // The server still serves the manifest it served before: its digest differs from the applied one, so it is
        // applied, and the admitted entries it does not list are pruned.
        _ = try await reopened.store.apply(server, etag: ETag(rawValue: "\"m1\""), eviction: nil)
        let applied = try await reopened.store.planningView()
        #expect(applied.appliedManifest.digest == server.digest)
        #expect(applied.records.keys.sorted() == ["a"])
    }
}

extension AssetStore {
    /// Sets the retention scope the way WP-C's `setRetentionScope(_:)` will (test seam; a stub at L2).
    func testSetRetentionScope(_ scope: AssetScope) {
        self.state.eviction.retentionScope = scope
    }
}
