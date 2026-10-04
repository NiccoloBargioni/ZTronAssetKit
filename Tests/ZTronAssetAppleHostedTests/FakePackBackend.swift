import ZTronAssetAppleHosted
import ZTronAssetModel

/// The test double of `PackBackend` (R-APL-1, ADR-040): it lives here because `PackBackend` is declared in
/// `ZTronAssetAppleHosted`, which `ZTronAssetTestSupport` (Model + Storage only) cannot see. WP-E gives it scripted
/// packs, progress, update checks and removals; the contract round only needs a value that is never called.
struct FakePackBackend: PackBackend {
    func reader(for path: String, in pack: PackID) -> any PackFileReader {
        fatalError("WP-E: FakePackBackend.reader not implemented")
    }

    func ensureAvailable(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async throws(PackError) {
        fatalError("WP-E: FakePackBackend.ensureAvailable not implemented")
    }

    func checkForUpdates() async throws(PackError) -> PackUpdateCheck {
        fatalError("WP-E: FakePackBackend.checkForUpdates not implemented")
    }

    func remove(_ pack: PackID) async throws(PackError) {
        fatalError("WP-E: FakePackBackend.remove not implemented")
    }

    func installedBytes(of pack: PackID) async -> Int64? {
        fatalError("WP-E: FakePackBackend.installedBytes not implemented")
    }
}
