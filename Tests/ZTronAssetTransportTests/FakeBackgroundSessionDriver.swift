import Foundation
import ZTronAssetModel
import ZTronAssetTransport

/// The test double of the device-only background driver (ADR-040): it lives here because its protocol lives in
/// `ZTronAssetTransport`, which `ZTronAssetTestSupport` cannot see. It keeps "OS" tasks across coordinator instances
/// and delivers queued completions only when `activate()` is called, which is the order the real OS imposes
/// (transport-2 T2-03). WP-D implements it with the background coordinator.
actor FakeBackgroundSessionDriver: BackgroundSessionDriver {
    nonisolated let identifier: BackgroundSessionIdentifier

    init(identifier: BackgroundSessionIdentifier) {
        self.identifier = identifier
    }

    func activate() async -> AsyncStream<SessionEvent> {
        fatalError("WP-D: FakeBackgroundSessionDriver.activate not implemented")
    }

    func snapshot() async -> [BackgroundTaskSnapshot] {
        fatalError("WP-D: FakeBackgroundSessionDriver.snapshot not implemented")
    }

    func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?) async {
        fatalError("WP-D: FakeBackgroundSessionDriver.startDownload not implemented")
    }

    func cancel(taskIdentifier: Int, producingResumeData: Bool) async -> ResumeData? {
        fatalError("WP-D: FakeBackgroundSessionDriver.cancel not implemented")
    }

    func setPriority(taskIdentifier: Int, _ priority: Float) async {
        fatalError("WP-D: FakeBackgroundSessionDriver.setPriority not implemented")
    }

    func invalidate() async {
        fatalError("WP-D: FakeBackgroundSessionDriver.invalidate not implemented")
    }
}
