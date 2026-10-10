import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The legacy plan (R-STO-11, R-SEC-2; store.md §7): the prior art's path rule, hardened, and the choice of each file's
/// expected digest. Pure.
@Suite("Cleanup: legacy plan (R-STO-11, R-SEC-2)")
struct LegacyPlanTests {
    static func entry(_ id: String, directories: [String] = [], name: String? = nil, ext: String = "png", checksum: ContentHash? = nil) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: ext,
            remotePath: "media/\(id).\(ext)",
            localPathComponents: directories,
            localFileName: name,
            byteSize: 10,
            checksum: checksum
        )
    }

    @Test("R-SEC-2: legacy paths follow the prior art's rule and reject empty, dot, traversal, slash, NUL and over-long components")
    func pathRule() {
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("x", directories: ["A", "B"], name: "n")) == ["A", "B", "n.png"])
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("bo7.ri.icon")) == ["bo7", "ri", "icon.png"])
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("single", ext: "SVG")) == ["single.SVG"])
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("x", name: "..")) == ["...png"], "a name that only starts with dots is a name")
        for bad in [[".."], ["."], [""], ["a/b"], ["a\u{0}b"], [String(repeating: "x", count: 256)]] {
            #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("x", directories: bad)) == nil, "\(bad)")
        }
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("x", name: "a/b")) == nil)
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("x", directories: [String(repeating: "é", count: 127)])) != nil, "254 UTF-8 bytes")
        #expect(LegacyPlanner.relativePath(of: LegacyPlanTests.entry("x", directories: [String(repeating: "é", count: 128)])) == nil, "256 UTF-8 bytes")
    }

    @Test("R-STO-11: the legacy plan adopts listed files by manifest checksum or local checksum and drops the rest")
    func planChoices() {
        let c1 = ContentHash.sha256(of: Data("1".utf8))
        let c2 = ContentHash.sha256(of: Data("2".utf8))
        let c3 = ContentHash.sha256(of: Data("3".utf8))
        let entries = [
            LegacyPlanTests.entry("withChecksum", directories: ["d"], name: "a", checksum: c1),
            LegacyPlanTests.entry("localOnly", directories: ["d"], name: "b"),
            LegacyPlanTests.entry("noChecksum", directories: ["d"], name: "c"),
            LegacyPlanTests.entry("missingFile", directories: ["d"], name: "missing", checksum: c1),
            LegacyPlanTests.entry("staleLocal", directories: ["d"], name: "e", checksum: c2),
            LegacyPlanTests.entry("badLocal", directories: ["d"], name: "f"),
            LegacyPlanTests.entry("sharedFirst", directories: ["s"], name: "g", checksum: c3),
            LegacyPlanTests.entry("sharedSame", directories: ["s"], name: "g", checksum: c3),
            LegacyPlanTests.entry("sharedOther", directories: ["s"], name: "g", checksum: c2),
            LegacyPlanTests.entry("traversal", directories: [".."], name: "a", checksum: c1),
        ]
        let checksums = [
            "localOnly": c2.hex,
            "staleLocal": c1.hex,
            "badLocal": "not-hex",
            "withChecksum": c1.hex,
        ]
        let files: Set<[String]> = [["d", "a.png"], ["d", "b.png"], ["d", "c.png"], ["d", "e.png"], ["d", "f.png"], ["s", "g.png"]]
        let plan = LegacyPlanner.plan(entries: entries, checksums: checksums, files: files)
        #expect(plan.files == [
            LegacyFile(components: ["d", "a.png"], ids: ["withChecksum"], digest: c1, byteSize: 10),
            LegacyFile(components: ["d", "b.png"], ids: ["localOnly"], digest: c2, byteSize: 10),
            LegacyFile(components: ["s", "g.png"], ids: ["sharedFirst", "sharedSame"], digest: c3, byteSize: 10),
        ])
        // noChecksum, staleLocal (the prior art recorded other bytes than the manifest names), badLocal, sharedOther
        // (another digest for a path already planned) and traversal.
        #expect(plan.dropped == 5)
        // missingFile is not in the tree: dropped unless an earlier lifetime adopted it, which phase 1 decides.
        #expect(plan.unlisted == [LegacyUnlisted(id: "missingFile", digest: c1)])
        #expect(plan.legacyIDs == entries.map(\.identifier))
        // Phase 4 may remove these and nothing else but the two metadata files (never a traversal).
        #expect(plan.paths == files.union([["d", "missing.png"]]))
    }
}
