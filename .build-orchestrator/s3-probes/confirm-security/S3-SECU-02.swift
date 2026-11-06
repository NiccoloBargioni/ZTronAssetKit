import Foundation
import Testing
import ZTronAssetModel

@testable import ZTronAssetTransport

/// S3-SECU-02 confirmation (independent): the Model's decoder accepts these remote paths while `RemoteURL.make`
/// (the only join the HTTP source uses, `HTTPRemoteSource.transfer`) refuses every one of them. The property a fix
/// must establish: every path the decoder accepts yields a URL.
@Suite("S3 confirm security: decoder vs RemoteURL")
struct S3ConfirmSecurityRemoteURLProbe {
    @Test("S3-SECU-02: a decoder-accepted remote path always yields a URL from RemoteURL.make", arguments: [
        "media/ok.png", "media//a.png", "media/./a.png", "./a.png", "media/%2E/a.png", "media\\a.png", "media/",
    ])
    func acceptedPathsAreFetchable(_ path: String) throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
        let json = """
            [{"identifier":"x","fileExtension":"png","remotePath":"\(escaped)","localPathComponents":[]}]
            """
        let manifest = try ManifestDecoder.decode(Data(json.utf8))
        let accepted = manifest.entries.count == 1
        let url = RemoteURL.make(base: URL(string: "https://cdn.example.invalid/root")!, path: path)
        #expect(!accepted || url != nil, "\(path): decoder accepted=\(accepted), RemoteURL.make=\(url?.absoluteString ?? "nil")")
    }
}
