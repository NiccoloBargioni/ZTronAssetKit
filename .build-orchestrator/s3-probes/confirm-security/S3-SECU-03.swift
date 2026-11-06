import Foundation
import Testing
import ZTronAssetModel

@testable import ZTronAssetStorage

/// S3-SECU-03 confirmation (independent): a non-canonical spelling of one of our staging names is not treated as
/// foreign ("foreign names always", `StagingCollection.garbage`'s doc), and the inventory collapses two directory
/// entries onto one key.
@Suite("S3 confirm security: staging names")
struct S3ConfirmSecurityStagingProbe {
    static let hash = String(repeating: "a", count: 64)

    @Test("S3-SECU-03: a fresh, non-canonical staging name is collected as foreign")
    func nonCanonicalIsForeign() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let name = "c-\(Self.hash).01-2.part"
        let item = FileItemInfo(name: name, kind: .file, byteSize: 10, modifiedAt: now, identity: nil)
        let garbage = StagingCollection.garbage([item], claimed: [], now: now, policy: StoragePolicy())
        #expect(garbage.map(\.name) == [name], "non-canonical \(name) kept by age rules instead of removed as foreign")
    }

    @Test("S3-SECU-03: two directory entries never parse to the same staging name")
    func distinctEntriesDistinctNames() {
        let canonical = StagingFileName(parsing: "c-\(Self.hash).1-2.part")
        let padded = StagingFileName(parsing: "c-\(Self.hash).1-02.part")
        #expect(canonical == nil || padded == nil || canonical != padded, "both entries parse to \(canonical?.rawValue ?? "nil")")
    }
}
