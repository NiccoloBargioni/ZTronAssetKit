import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// Verifier probe (WP-K close-out cycle 2, requirements lens; scratch copy only, never committed): the public-API shapes of
/// the cycle-1 probes PK2b (ensureAvailable right after start) and PK8u (a user-initiated prefetch right after start), each
/// over 150 prior-art files of 64 KiB on inline executors, so legacy migration runs at its own pace beside the request.
@Suite("Verifier K-C2 public-API probe", .serialized)
struct VerifierKC2PublicProbe {
    static let launches = Int(ProcessInfo.processInfo.environment["PROBE_LAUNCHES"] ?? "") ?? 20

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("PK2b: ensureAvailable(scope: .all) right after start() downloads no prior-art file", .timeLimit(.minutes(10)))
    func ensureAvailableRightAfterStart() async throws {
        var withDownloads = 0
        var total = 0
        for launch in 0..<VerifierKC2PublicProbe.launches {
            await Task.yield()
            let adoption = try await MigrationLaunchShimTests.adoptionLaunch(count: 150, size: 65_536)
            try await adoption.client.start()
            let report = try await adoption.client.ensureAvailable(scope: .all)
            let starts = await adoption.fakes.starts(after: 0)
            if !starts.isEmpty {
                withDownloads += 1
                total += starts.count
            }
            #expect(report.present == 150 && report.missing == 0, "launch \(launch): \(report)")
            await adoption.client.shutdown()
        }
        print("KC2-PROBE PK2b launches=\(VerifierKC2PublicProbe.launches) launchesWithDownloads=\(withDownloads) downloads=\(total)")
        #expect(withDownloads == 0, "PK2b: \(withDownloads) launches downloaded \(total) prior-art files")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("PK8u: prefetch(ids, priority: .userInitiated) right after start() downloads no prior-art file", .timeLimit(.minutes(10)))
    func userInitiatedPrefetchRightAfterStart() async throws {
        var withDownloads = 0
        var total = 0
        for launch in 0..<VerifierKC2PublicProbe.launches {
            await Task.yield()
            let adoption = try await MigrationLaunchShimTests.adoptionLaunch(count: 150, size: 65_536)
            try await adoption.client.start()
            let handle = adoption.client.prefetch(adoption.assets.map { AssetID($0.0.identifier) }, priority: .userInitiated)
            // Joins the prefetch's jobs (single flight) and returns once every asset is stored.
            let report = try await adoption.client.ensureAvailable(scope: .all)
            let starts = await adoption.fakes.starts(after: 0)
            if !starts.isEmpty {
                withDownloads += 1
                total += starts.count
            }
            #expect(report.present == 150 && report.missing == 0, "launch \(launch): \(report)")
            withExtendedLifetime(handle) {}
            await adoption.client.shutdown()
        }
        print("KC2-PROBE PK8u launches=\(VerifierKC2PublicProbe.launches) launchesWithDownloads=\(withDownloads) downloads=\(total)")
        #expect(withDownloads == 0, "PK8u: \(withDownloads) launches downloaded \(total) prior-art files")
    }
}
