import Foundation
import Testing

/// R-APL-5 / ADR-014: the package's only runtime OS check is the tier resolution's.
@Suite("Apple tier: availability scan")
struct SingleAvailabilityScanTests {
    @Test("R-APL-5: the package contains exactly one #available")
    func exactlyOneAvailabilityCheck() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.path.hasSuffix("ZTronAssetTestSupport/ManualTimeSource.swift") }, "the scan covers ZTronAssetTestSupport")

        var checks: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                if code.contains("#available") || code.contains("#unavailable") {
                    checks.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(checks.count == 1, "\(checks)")
        #expect(checks.first?.hasPrefix("AppleHostedTier.swift:") == true, "\(checks)")
    }
}
