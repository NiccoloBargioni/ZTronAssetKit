import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

/// The small value fakes every package's tests use.
@Suite("Test support: basic fakes")
struct TestSupportBasicFakesTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("Test support: FakeLegacyDefaults serves its seeded values and records every removal in order")
    func legacyDefaults() {
        let defaults = FakeLegacyDefaults(values: ["CDNLastSync": "2024-01-01", "other": "x"])
        #expect(defaults.string(forKey: "CDNLastSync") == "2024-01-01")
        defaults.removeValue(forKey: "CDNLastSync")
        defaults.removeValue(forKey: "absent")
        #expect(defaults.string(forKey: "CDNLastSync") == nil)
        #expect(defaults.string(forKey: "other") == "x")
        #expect(defaults.removedKeys == ["CDNLastSync", "absent"])
    }

    /// A value only the calling task carries: a unit that ran on another thread or queue would not see it.
    enum CallerMarker {
        @TaskLocal static var value = 0
    }

    /// The identity of the task running the caller (`nil` outside any task). Task-locals alone cannot prove "inline":
    /// an unstructured `Task { }` or a task-group child inherits them, but each is a different task.
    static func currentTaskIdentity() -> Int? {
        withUnsafeCurrentTask { $0?.hashValue }
    }

    @Test("Test support: InlineBlockingExecutor runs each unit inside the calling task and rethrows a typed failure", .timeLimit(.minutes(1)))
    func inlineExecutor() async {
        let executor = InlineBlockingExecutor()
        let caller = Self.currentTaskIdentity()
        let seen = await CallerMarker.$value.withValue(42) {
            await executor.run { (CallerMarker.value, Self.currentTaskIdentity()) }
        }
        #expect(caller != nil)
        #expect(seen.0 == 42)
        #expect(seen.1 == caller, "the unit ran in another task (a child, unstructured or detached task) or on a queue")
        await #expect(throws: FileSystemError.noSpace) {
            try await executor.run(throwing: { () throws(FileSystemError) -> Int in throw .noSpace })
        }
    }

    @Test("Test support: FakeDeviceConditionsSource delivers each sent state to every live observation", .timeLimit(.minutes(1)))
    func conditionsReachEveryObserver() async throws {
        let source = FakeDeviceConditionsSource()
        let offline = DeviceConditions(
            network: NetworkConditions(satisfied: false, expensive: false, constrained: false),
            power: PowerConditions(lowPowerMode: true, thermal: .serious)
        )
        let observers = (0..<2).map { _ in
            Task { () -> [DeviceConditions] in
                var seen: [DeviceConditions] = []
                for await state in await source.conditions() {
                    seen.append(state)
                    if seen.count == 2 {
                        break
                    }
                }
                return seen
            }
        }
        // The throwing form: observers that never registered would never end, so a cancelled wait ends the test here.
        try await source.requireObservers(equalTo: 2)
        await source.send(offline)
        for observer in observers {
            #expect(await observer.value == [.unrestricted, offline])
        }
        try await source.requireObservers(equalTo: 0)
    }

    @Test("Test support: ScriptedSnapshotSink.waitForInstalls resumes once enough installs were offered", .timeLimit(.minutes(1)))
    func snapshotSinkInstallCensus() async {
        let sink = ScriptedSnapshotSink()
        // A child task, not an unstructured one: the test's cancellation (its time limit) reaches the wait.
        async let waiting: Void = sink.waitForInstalls(atLeast: 2)
        let first = AssetSnapshot(key: SnapshotKey(epoch: 1, version: 1), indexGeneration: 1, entries: [:])
        let second = AssetSnapshot(key: SnapshotKey(epoch: 1, version: 2), indexGeneration: 2, entries: [:])
        _ = await sink.install(first)
        _ = await sink.install(second)
        await waiting
        #expect(await sink.offeredKeys == [first.key, second.key])
        await sink.waitForInstalls(atLeast: 1)
        #expect(await sink.installed.key == second.key)
    }
}
