import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3 probe (lens crash, R-CLN-7): a crash at every boundary of the first sync, then an OS purge between launches
/// (blobs/, the root, every other blob, staging/), then a launch: no crash, I-1, I-2 after reconciliation (needsHeal
/// allowed), no "synced" claim over a lost blob, and convergence without re-downloading what survived.
@Suite("S3 probe: OS purge after a crash", .serialized)
struct S3PurgeAfterCrashProbe {
    enum Purge: String, CaseIterable, Sendable {
        case blobs, root, half, staging
    }

    @Test("R-CLN-7: a crash at every boundary, then an OS purge between launches, heals without a stale synced claim", .timeLimit(.minutes(1)), arguments: [CrashMode.processKill, .powerLossDropUnsynced], Purge.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeAfterCrash(mode: CrashMode, purge: Purge) async throws {
        let clean = CoreHarness.make()
        _ = await FirstSync.run(clean)
        let total = clean.fileSystem.mutationCount
        for point in 0..<total {
            await Task.yield()
            let label = "\(mode) at \(point), purge \(purge)"
            let harness = CoreHarness.make(crashBefore: point, mode: mode)
            _ = await FirstSync.run(harness)
            var disk = harness.fileSystem.survivingDisk()
            let layout = CoreFixture.layout
            switch purge {
            case .blobs:
                disk.purge(layout.blobsDirectory.path)
            case .root:
                disk.purge(layout.root.path)
            case .half:
                let blobs = disk.files.keys.filter { $0.hasPrefix(layout.blobsDirectory.path + "/") }.sorted()
                for (index, path) in blobs.enumerated() where index % 2 == 0 {
                    disk.purge(path)
                }
            case .staging:
                disk.purge(layout.stagingDirectory.path)
            }
            let survivors = Set(disk.files.keys.filter { $0.hasPrefix(layout.blobsDirectory.path + "/") })
            let reopened = CoreHarness.make(disk: disk)
            let report: OpenReport
            do {
                report = try await reopened.store.open()
            } catch {
                Issue.record("\(label): open failed with \(error)")
                continue
            }
            let violations = await CoreInvariants.violations(of: reopened, allowNeedsHeal: true)
            #expect(violations.isEmpty, "\(label): \(violations)")
            let state = await reopened.state
            let healing = state.core.records.values.contains { if case .needsHeal = $0.residency { return true } else { return false } }
            if healing {
                #expect(report.stamp == nil && report.syncDue, "\(label): a lost blob, yet the store claims synced")
            }
            // Converge: whatever survived is bound without a download.
            _ = try await reopened.store.apply(FirstSync.manifest, etag: nil, eviction: nil)
            for (index, asset) in FirstSync.assets.enumerated() {
                let key = CoreFixture.key(asset.bytes, ext: asset.entries[0].fileExtension)
                let missing = await asset.entries.asyncFilter { entry in
                    await reopened.record(entry.identifier)?.referencedBlob != CoreFixture.key(asset.bytes, ext: entry.fileExtension)
                }
                if survivors.contains(layout.blobURL(key).path), asset.entries.count == 1, asset.entries[0].checksum != nil {
                    #expect(missing.isEmpty, "\(label): \(asset.entries[0].identifier.rawValue)'s surviving blob was not bound")
                }
                guard !missing.isEmpty else {
                    continue
                }
                let staged = try await reopened.stage(asset.bytes, for: missing[0], sequence: UInt32(200 + index))
                _ = try await reopened.store.publish(staged, binding: missing.map(\.identifier), expecting: missing[0].contentIdentity, urgency: .bulk)
            }
            try await reopened.store.flush(.durable)
            for asset in FirstSync.assets {
                for entry in asset.entries {
                    let location = await reopened.store.location(for: entry.identifier, extensions: [], recordingAccess: false)
                    #expect(location.flatMap { reopened.content($0.url) } == asset.bytes, "\(label): \(entry.identifier.rawValue) did not converge")
                }
            }
            let after = await CoreInvariants.violations(of: reopened)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            await reopened.store.close()
        }
    }
}

extension Array {
    func asyncFilter(_ isIncluded: (Element) async -> Bool) async -> [Element] {
        var kept: [Element] = []
        for element in self where await isIncluded(element) {
            kept.append(element)
        }
        return kept
    }
}
