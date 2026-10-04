import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// The small value fakes every package's tests use.
@Suite("Test support: basic fakes")
struct BasicFakesTests {
    @available(macOS 15.0, *)
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
}
