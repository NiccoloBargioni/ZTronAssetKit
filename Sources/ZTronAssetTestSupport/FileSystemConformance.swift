import Foundation
import ZTronAssetModel

/// One clause of the shared `FileSystem` conformance contract that a conformer broke (R-STO-6).
public struct FileSystemConformanceViolation: Sendable, Hashable, CustomStringConvertible {
    /// The clause, for example `rename(.exclusive) onto an existing name fails with alreadyExists`.
    public var clause: String
    /// What the conformer did instead.
    public var detail: String

    /// Creates a violation.
    public init(clause: String, detail: String) {
        self.clause = clause
        self.detail = detail
    }

    /// `clause: detail`, for test failure messages.
    public var description: String {
        "\(self.clause): \(self.detail)"
    }
}

/// The shared conformance contract of the `FileSystem` seam (R-STO-6; WP-H, contract-fix round 4).
///
/// One set of clauses (absent-is-success removal, exclusive and replacing renames, append and truncate writes, short
/// writes reported after the bytes that landed, non-following `itemInfo` and listings, the closed
/// `FileSystemError` mapping, lock idempotence) that both conformers must satisfy, so `FakeFileSystem` cannot drift
/// from the live behaviour the store relies on. It ships here, as an API, so that each package runs it from its
/// own test files: WP-H against `FakeFileSystem` (`Tests/ZTronAssetStorageTests/TestSupport/`), WP-B against
/// `LiveFileSystem` (`Tests/ZTronAssetStorageTests/Core/`), and neither edits the other's tests (ARCHITECTURE §1.2,
/// §11).
public enum FileSystemConformance {
    /// Runs every clause against `fileSystem` inside `root`, an empty directory the caller created and owns (for
    /// `LiveFileSystem`, under the test's scratch path inside this repository, never the system temporary
    /// directory, ARCHITECTURE §14), and returns the violations: empty when the conformer satisfies the contract.
    /// Synchronous like the seam itself; call it from a test, never from the main actor (C2).
    public static func violations(of fileSystem: any FileSystem, in root: URL) -> [FileSystemConformanceViolation] {
        fatalError("WP-H: FileSystemConformance.violations not implemented")
    }
}
