import Foundation
import Testing

/// Holds the README's quick adoption snippet to the copy this target compiles (`QuickAdoption.swift`), so the
/// snippet an adopter pastes is one the compiler accepted under Swift 6 and warnings as errors.
@Suite("README quick adoption")
struct QuickAdoptionTests {
    /// The repository root, three levels above this file (`Tests/ZTronAssetSwiftUITests/<file>`).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The lines of `text` strictly between the first line equal to `begin` and the next line equal to `end`.
    private static func lines(of text: String, after begin: String, before end: String) throws -> [String] {
        let all = text.components(separatedBy: "\n")
        let start = try #require(all.firstIndex(of: begin), "no line \(begin)")
        let rest = all[(start + 1)...]
        let stop = try #require(rest.firstIndex(of: end), "no line \(end) after \(begin)")
        return Array(all[(start + 1)..<stop])
    }

    @Test("the README's quick adoption snippet is the compiled one, plus its @main line")
    func readmeMatchesCompiledSnippet() throws {
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Tests/ZTronAssetSwiftUITests/QuickAdoption.swift"),
            encoding: .utf8
        )
        let compiled = try Self.lines(of: source, after: "// README:BEGIN", before: "// README:END")
        let marker = try Self.lines(of: readme, after: "<!-- quick-adoption:begin -->", before: "<!-- quick-adoption:end -->")
        let printed = try Self.lines(of: marker.joined(separator: "\n"), after: "```swift", before: "```")

        #expect(compiled.count > 30, "the compiled snippet was found")
        #expect(printed.filter { $0 == "@main" }.count == 1, "the README shows the app's entry point")
        #expect(printed.filter { $0 != "@main" } == compiled)
    }
}
