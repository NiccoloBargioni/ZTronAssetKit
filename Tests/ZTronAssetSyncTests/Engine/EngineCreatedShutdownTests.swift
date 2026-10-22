import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Orchestrator ruling L5-R2 (level 5 close-out; L5-V3-05, R-SYN-15): `shutdown()` returns only once every
/// engine-owned task is cancelled and joined and every continuation resumed with `.shutDown`, whatever lifecycle state
/// it began in, `created` included; from `created` it still never opens the store and never logs. `spawn` allows owned
/// tasks in `created`, and three spawn sites are reachable there (`docs/adr-drafts/g.md`, the L5-R2 table): the
/// memory-pressure observer (`performObserveMemoryPressure`), a group's join (`performRegisterGroup`) and, since the
/// claims of L5-R1, a release follow-up (`continueReleases`). Each test spawns one of them in `created`, shuts the engine
/// down, and checks right after `shutdown()` returns that no owned task is left and that the site's resource is
/// released, with no further event.
@Suite("Engine shutdown from created")
struct EngineCreatedShutdownTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown in created cancels and joins the memory-pressure observer, so its observation ends with no further event", .timeLimit(.minutes(1)))
    func pressureObserverSpawnedInCreated() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let started = await engine.observeMemoryPressure(epoch: 1) { _ in }
        #expect((try? started.get()) != nil, "setup: the request is accepted before start")
        try await harness.pressure.requireObservers(equalTo: 1)
        let before = await engine.introspect()
        #expect(before.lifecycle == .created && before.ownedTasks == 1 && before.memoryPressureObserverActive, "setup: the observer runs while the engine is created: \(before)")
        await engine.shutdown()
        let after = await engine.introspect()
        #expect(after.lifecycle == .shutDown)
        #expect(after.ownedTasks == 0, "no owned task outlives shutdown: \(after.ownedTasks)")
        #expect(!after.memoryPressureObserverActive, "the observer was stopped")
        guard after.ownedTasks == 0 else {
            // The leftover observer ends only at the next event; end it so nothing outlives the test.
            await harness.pressure.send(.warning)
            return
        }
        try await harness.pressure.requireObservers(equalTo: 0)
        #expect(harness.fileSystem.operations.isEmpty, "a shutdown in created never touches the volume")
        #expect(harness.tap.lines.isEmpty, "a shutdown in created never logs: \(harness.tap.lines)")
    }

    /// The join is spawned and the shutdown begun in one engine turn, so the join can run only inside the shutdown: it
    /// is cancelled and joined there, and its `ensureStarted()` refuses during `shuttingDown`, so it never opens the store.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown in created cancels and joins a group's join, which never opens the store", .timeLimit(.minutes(1)))
    func groupJoinSpawnedInCreated() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let outcome = await engine.registerAndShutDown(["x", "y"])
        #expect(outcome.spawned, "setup: the join was spawned while the engine was created")
        // Read in the turn `shutdown()` returned in, before any task left behind could run.
        #expect(outcome.ownedTasks == 0, "no owned task outlives shutdown: \(outcome.ownedTasks)")
        #expect(outcome.groups == 0, "the group was released with the engine")
        let after = await engine.introspect()
        #expect(after.lifecycle == .shutDown && after.ownedTasks == 0)
        let claims = await engine.inOneTurn { engine in engine.state.claims.count + engine.state.unlistedClaims }
        #expect(claims == 0, "no claim outlives shutdown")
        #expect(harness.fileSystem.operations.isEmpty, "neither the shutdown nor the join opened the store")
        #expect(harness.tap.lines.isEmpty, "a shutdown in created never logs: \(harness.tap.lines)")
        let late = await engine.registerGroup(["z"], lane: .prefetch)
        #expect(late == .failure(.shutDown), "nothing registers after shutdown")
    }
}

extension EngineCreatedShutdownTests {
    /// Since L5-R1 a group of more than `releasesPerTurn` members released before start chunks its claims and spawns a
    /// release follow-up while the engine is `created`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown in created cancels and joins a release follow-up", .timeLimit(.minutes(1)))
    func releaseFollowUpSpawnedInCreated() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let ids = (0..<(SyncEngine.releasesPerTurn + 1)).map { AssetID(String(format: "r%04d", $0)) }
        let outcome = await engine.releaseAndShutDown(ids)
        #expect(outcome.spawned, "setup: the release follow-up was spawned while the engine was created")
        #expect(outcome.ownedTasks == 0, "no owned task outlives shutdown: \(outcome.ownedTasks)")
        #expect(outcome.releasing == 0 && outcome.claims == 0, "no release and no claim outlives shutdown")
        #expect(harness.fileSystem.operations.isEmpty, "a shutdown in created never touches the volume")
        #expect(harness.tap.lines.isEmpty, "a shutdown in created never logs: \(harness.tap.lines)")
    }
}

extension SyncEngine {
    /// Test seam: registers a group of more than `releasesPerTurn` members and releases it, which spawns its join and a
    /// release follow-up, then begins `shutdown()`, all in one turn; reports what was left in the turn the shutdown
    /// returned in.
    func releaseAndShutDown(_ ids: [AssetID]) async -> (spawned: Bool, ownedTasks: Int, releasing: Int, claims: Int) {
        let created = self.state.lifecycle == .created
        if let token = try? self.performRegisterGroup(ids, lane: .prefetch).get() {
            self.performReleaseGroup(token)
        }
        let spawned = created && !self.state.releasing.isEmpty && self.state.releaseFollowUpScheduled
        // REENTRANCY: the owned tasks, releases and claims are read right after the shutdown returns (a test seam).
        await self.performShutdown()
        return (spawned, self.state.tasks.count, self.state.releasing.count, self.state.claims.count + self.state.unlistedClaims)
    }

    /// Test seam: registers a group, which spawns its join, and begins `shutdown()` in the same turn; reports whether
    /// the engine was `created` with the join spawned, and the owned tasks and groups left in the turn the shutdown
    /// returned in.
    func registerAndShutDown(_ ids: [AssetID]) async -> (spawned: Bool, ownedTasks: Int, groups: Int) {
        let created = self.state.lifecycle == .created
        let registered = (try? self.performRegisterGroup(ids, lane: .prefetch).get()) != nil
        let spawned = created && registered && self.state.tasks.count == 1
        // REENTRANCY: the owned tasks and the groups are read right after the shutdown returns (a test seam).
        await self.performShutdown()
        return (spawned, self.state.tasks.count, self.state.groups.count)
    }
}
