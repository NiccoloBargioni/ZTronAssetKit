import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// Records the pauses of a survey, in order.
private actor PauseLog {
    private(set) var surveyed: [Int] = []

    func record(_ count: Int) {
        self.surveyed.append(count)
    }
}

/// C2 and H-7: the release decision over a whole adoption report, computed in bounded slices off the state actor.
@Suite("Apple tier: release survey")
struct ReleaseSurveyTests {
    @Test("C2: a 100,000-entry adoption report is surveyed in slices of at most 1,000 entries with a pause between them", .timeLimit(.minutes(1)))
    func surveyPausesBetweenBoundedSlices() async throws {
        let paths = (0..<100_000).map { "ZTronMedia\($0 % 7)/images/\($0).heic" }
        let adopted = Set(paths.filter { !$0.hasPrefix("ZTronMedia3/") })
        let report = AdoptionReport(manifestRemotePaths: paths, adoptedRemotePaths: adopted)
        let log = PauseLog()
        let survey = await ReleaseSurvey.survey(report, catalogPack: Packs.catalog, retention: .releaseAfterAdoption) {
            await log.record($0)
        }
        #expect(await log.surveyed == Array(stride(from: 1_000, to: 100_000, by: 1_000)))
        let settled = Set([0, 1, 2, 4, 5, 6].compactMap { PackID(rawValue: "ZTronMedia\($0)") })
        #expect(survey.settled == settled)
        #expect(survey.adopted == settled)
    }

    @Test("H-7: the sliced survey decides exactly what PackReleasePlanner decides over the whole report", .timeLimit(.minutes(1)))
    func surveyMatchesThePlanner() async throws {
        let seed: UInt64 = 0x5EED_E7
        var random = SplitMix64(seed: seed)
        let packs = ["ZTronCatalog", "ZTronMedia", "ZTronExtras", "ZTronVideo", "not a pack"]
        for round in 0..<300 {
            var paths: [String] = []
            for _ in 0..<Int.random(in: 0...60, using: &random) {
                let pack = packs[Int.random(in: 0..<packs.count, using: &random)]
                let file = Int.random(in: 0..<10, using: &random) == 0 ? "../escape" : "f\(Int.random(in: 0...30, using: &random)).bin"
                paths.append("\(pack)/\(file)")
            }
            let adopted = Set(paths.filter { _ in Bool.random(using: &random) })
            let excluded = Set(paths.filter { _ in Int.random(in: 0..<4, using: &random) == 0 })
            let retention: PackRetention = Int.random(in: 0..<5, using: &random) == 0 ? .keepPacks : .releaseAfterAdoption
            let sliceSize = Int.random(in: 1...8, using: &random)
            let report = AdoptionReport(manifestRemotePaths: paths, adoptedRemotePaths: adopted, excludedRemotePaths: excluded)

            let survey = await ReleaseSurvey.survey(
                report,
                catalogPack: Packs.catalog,
                retention: retention,
                sliceSize: sliceSize,
                pause: { _ in }
            )
            let expected = PackReleasePlanner.packsToRelease(
                catalogEntries: paths.compactMap(PackLocation.init(remotePath:)),
                adopted: Set(adopted.compactMap(PackLocation.init(remotePath:))),
                excluded: Set(excluded.compactMap(PackLocation.init(remotePath:))),
                catalogPack: Packs.catalog,
                retention: retention,
                alreadyReleased: []
            )
            let expectedAdopted = Set(adopted.compactMap(PackLocation.init(remotePath:)).map(\.pack)).subtracting([Packs.catalog])
            #expect(survey.settled.sorted() == expected, "seed \(seed) round \(round)")
            #expect(survey.adopted == expectedAdopted, "seed \(seed) round \(round)")
        }
    }
}
