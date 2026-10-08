import Foundation
import ZTronAssetModel

/// What a background download task carries in `taskDescription` (H-6, transport.md §4.3): the staging name it
/// writes and the manifest's decoded size, as `ztak1 <staging name> <expected bytes | ->`.
///
/// A background task has no mailbox (S-2), and the OS persists `taskDescription` across relaunch, so this is the
/// only way a relaunched process learns which content an OS task is fetching. It carries no secret and no manifest
/// text (the staging name is hashes and numbers, ADR-013). Parsing is strict: exactly three fields, at most 256
/// bytes, the `ztak1` version, a `.part` staging name and a non-negative decimal size; anything else is foreign and
/// decodes to `nil` (the coordinator cancels such tasks at launch).
package struct BackgroundTaskTag: Sendable, Hashable {
    /// The staging file the download is moved to (kind `.partial`).
    package let name: StagingFileName
    /// The manifest's `byteSize`, when it has one (R-NET-7).
    package let expectedBytes: Int64?

    /// The tag format's version prefix.
    static let version = "ztak1"
    /// The longest description that decodes.
    static let maxBytes = 256

    /// Creates a tag.
    package init(name: StagingFileName, expectedBytes: Int64?) {
        self.name = name
        self.expectedBytes = expectedBytes
    }

    /// Decodes a task description; `nil` for anything that is not exactly one of our tags.
    package init?(decoding description: String?) {
        guard let description, description.utf8.count <= Self.maxBytes else {
            return nil
        }
        let fields = description.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == Self.version[...],
            let name = StagingFileName(parsing: String(fields[1])), name.kind == .partial
        else {
            return nil
        }
        if fields[2] == "-" {
            self.init(name: name, expectedBytes: nil)
            return
        }
        guard (1...19).contains(fields[2].utf8.count), fields[2].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let expected = Int64(fields[2])
        else {
            return nil
        }
        self.init(name: name, expectedBytes: expected)
    }

    /// The task description.
    package var encoded: String {
        "\(Self.version) \(self.name.rawValue) \(self.expectedBytes.map(String.init) ?? "-")"
    }
}
