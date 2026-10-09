import ZTronAssetModel

/// What one adoption report says about the source's media packs, computed outside `AppleSourceState` in bounded
/// slices (C2, H-7, ADR-027).
///
/// A report names every entry of the applied manifest, up to R-MAN-2's 100,000. Parsing them all in one actor turn
/// held a pool thread, and the actor every transfer needs for staging admission, for about half a second at that size
/// (review of WP-E, round 1). So only the manifest entries are parsed, `sliceSize` at a time with a pause between
/// slices, in the caller's task; adopted and excluded paths are matched against the report's own string sets, which
/// is the same membership because a remote path and its `PackLocation` correspond one to one (`description`
/// rebuilds the path). Each slice is decided by `PackReleasePlanner`, the single release rule: a pack is settled when
/// it appears in some slice and no slice found an entry of it that is neither adopted nor excluded.
struct ReleaseSurvey: Sendable, Hashable {
    /// Media packs every catalog entry of which is adopted or excluded, before the already-released filter.
    var settled: Set<PackID>
    /// Media packs holding at least one adopted entry (never the catalog pack). Adopted paths are entries of the
    /// applied manifest (`AdoptionReport`), so they are found among the manifest entries.
    var adopted: Set<PackID>

    /// Entries surveyed between two pauses. Measured in a release build on the M-series host (`-enable-testing`
    /// probe, 100,000 entries): about 0.6 µs per `PackLocation` parse, 1.0 ms per slice of 1,000 entries on average
    /// and 4.7 ms for the slowest slice, so a slice stays under C2's ~10 ms stretch on slower devices too.
    static let sliceSize = 1_000

    /// Surveys `report`; `pause` runs between slices with the number of entries surveyed so far (`Task.yield()` in
    /// production, a recorder in tests).
    static func survey(
        _ report: AdoptionReport,
        catalogPack: PackID,
        retention: PackRetention,
        sliceSize: Int = ReleaseSurvey.sliceSize,
        pause: @Sendable (_ surveyed: Int) async -> Void = { _ in await Task.yield() }
    ) async -> ReleaseSurvey {
        let paths = report.manifestRemotePaths
        let adoptedPaths = report.adoptedRemotePaths
        let excludedPaths = report.excludedRemotePaths
        let size = max(1, sliceSize)
        var appearing: Set<PackID> = []
        var unsettled: Set<PackID> = []
        var adopted: Set<PackID> = []
        var start = paths.startIndex
        while start < paths.endIndex {
            let end = min(start + size, paths.endIndex)
            var entries: [PackLocation] = []
            var adoptedEntries: Set<PackLocation> = []
            var excludedEntries: Set<PackLocation> = []
            var slicePacks: Set<PackID> = []
            entries.reserveCapacity(end - start)
            for path in paths[start..<end] {
                guard let location = PackLocation(remotePath: path) else {
                    continue
                }
                entries.append(location)
                let media = location.pack != catalogPack
                if media {
                    slicePacks.insert(location.pack)
                }
                if adoptedPaths.contains(path) {
                    adoptedEntries.insert(location)
                    if media {
                        adopted.insert(location.pack)
                    }
                }
                if excludedPaths.contains(path) {
                    excludedEntries.insert(location)
                }
            }
            let settledHere = PackReleasePlanner.packsToRelease(
                catalogEntries: entries,
                adopted: adoptedEntries,
                excluded: excludedEntries,
                catalogPack: catalogPack,
                retention: retention,
                alreadyReleased: []
            )
            appearing.formUnion(slicePacks)
            unsettled.formUnion(slicePacks.subtracting(settledHere))
            start = end
            if start < paths.endIndex {
                await pause(start)
            }
        }
        return ReleaseSurvey(settled: appearing.subtracting(unsettled), adopted: adopted)
    }
}
