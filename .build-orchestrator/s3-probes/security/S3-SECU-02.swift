import Foundation
import Testing

@testable import ZTronAssetModel

/// S3-SECU-02: the decoder accepts remote paths that `RemoteURL.make` (ADR draft D-6, TR1-10) refuses on every fetch
/// with `rejected(.invalidURL)`: an empty segment, a `.` segment (also `%2E`), a backslash, a trailing slash. Fix round
/// 3 (orchestrator decision 3) quarantined `?` and `#` for exactly this reason ("the transport would reject the path on
/// every fetch"); these spellings were left out, so such an entry is planned, fails every run (`failed(.nextRun)`) and
/// answers its waiters `.serverUnavailable` instead of being quarantined with a diagnostic.
///
/// S3-SECU-03: staging names parse in spellings the module never writes (`TransferAttempt.token` is canonical decimal),
/// so `StagingFileName(parsing:)` is not "nil for anything that is not exactly one of our names": a foreign
/// `c-….01-2.part` parses as ours and its `rawValue` names another file.
@Suite("S3 security probes: model")
struct S3SecurityModelProbeTests {
    @Test("R-MAN-2: a remote path the transport refuses on every fetch is quarantined by the decoder", arguments: [
        "media//a.png", "media/./a.png", "./a.png", "media/%2E/a.png", "media\\a.png", "media/",
    ])
    func unfetchablePathsAreQuarantined(_ path: String) throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
        let json = """
            [{"identifier":"ok","fileExtension":"png","remotePath":"media/ok.png","localPathComponents":[]},
             {"identifier":"x","fileExtension":"png","remotePath":"\(escaped)","localPathComponents":[]}]
            """
        let manifest = try ManifestDecoder.decode(Data(json.utf8))
        #expect(manifest.entries.map(\.identifier) == ["ok"], "\(path) was accepted although no fetch of it can ever be made")
        #expect(manifest.quarantinedCount == 1)
    }

    @Test("R-SEC-2: staging names parse only in the canonical spelling the module writes", arguments: [
        "c-\(String(repeating: "a", count: 64)).01-2.part",
        "c-\(String(repeating: "a", count: 64)).1-02.part",
        "c-zz.1-2.part",
    ])
    func stagingNamesRoundTrip(_ fileName: String) {
        let parsed = StagingFileName(parsing: fileName)
        #expect(parsed == nil || parsed?.rawValue == fileName, "\(fileName) parsed as \(parsed?.rawValue ?? "nil")")
    }
}
