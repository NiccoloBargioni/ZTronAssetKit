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
/// writes reported after the bytes that landed, non-following `itemInfo` and listings, lock idempotence, including a
/// stale token's release) that both conformers must satisfy, so `FakeFileSystem` cannot drift from the live behaviour
/// the store relies on. Of the `FileSystemError` mapping, the clauses check only the errors a test can induce on both
/// conformers inside its own root: `.notFound`, `.alreadyExists`, `.notEmpty` and `.wouldBlock`, plus `.noSpace` in
/// the short-write clause, which runs on the fake only. The live mapping of every other errno (`.permissionDenied`,
/// `.noSpace`, `.crossDevice`, `.io`, `.notSupported`, `.other`) is covered by WP-B's pure errno-mapping table tests,
/// not here.
///
/// It ships here, as an API, so that each package runs it from its own test files: WP-H against `FakeFileSystem`
/// (`Tests/ZTronAssetStorageTests/TestSupport/`), WP-B against `LiveFileSystem` (`Tests/ZTronAssetStorageTests/Core/`),
/// and neither edits the other's tests (ARCHITECTURE §1.2, §11).
public enum FileSystemConformance {
    /// Runs every clause against `fileSystem` inside `root`, an empty directory the caller created and owns (for
    /// `LiveFileSystem`, under the test's scratch path inside this repository, never the system temporary
    /// directory, ARCHITECTURE §14), and returns the violations: empty when the conformer satisfies the contract.
    /// Synchronous like the seam itself; call it from a test, never from the main actor (C2).
    ///
    /// Each clause works in its own subdirectory of `root` and leaves it behind (the caller removes `root`). Two
    /// fixtures cannot be made through the seam: a symbolic link is created with the fake's seeding hook or, for a
    /// real directory, with `FileManager` inside `root`; a short write can only be induced in the fake, so that
    /// clause is checked only there. The suite never calls `standardDirectory` (the live one may create a
    /// directory outside the repository). Listing order is not part of the contract (the live order is arbitrary;
    /// the fake lists in descending name order so that code relying on an order fails in tests): callers sort.
    public static func violations(of fileSystem: any FileSystem, in root: URL) -> [FileSystemConformanceViolation] {
        let probe = ConformanceProbe(fileSystem: fileSystem, root: root)
        probe.checkDirectories()
        probe.checkWrites()
        probe.checkReads()
        probe.checkRenames()
        probe.checkIdentity()
        probe.checkRemoval()
        probe.checkMetadata()
        probe.checkSymbolicLinks()
        probe.checkShortWrite()
        probe.checkSyncs()
        probe.checkLocks()
        probe.checkAttributesAndCapacity()
        return probe.violations
    }
}

/// Runs the clauses and collects what failed; every call's outcome is captured as a `Result`, never thrown. A class,
/// so the clause helpers can take closures over the probe without overlapping a mutating access.
private final class ConformanceProbe {
    let fileSystem: any FileSystem
    let root: URL
    var violations: [FileSystemConformanceViolation] = []

    init(fileSystem: any FileSystem, root: URL) {
        self.fileSystem = fileSystem
        self.root = root
    }

    // MARK: Clauses

    func checkDirectories() {
        let clause = "createDirectory creates one level and succeeds when the directory exists"
        let directory = self.directory("c01-create")
        self.expectSuccess(clause, "first create") { () throws(FileSystemError) in try self.fileSystem.createDirectory(at: directory) }
        self.expectKind(clause, directory, .directory)
        self.expectSuccess(clause, "second create") { () throws(FileSystemError) in try self.fileSystem.createDirectory(at: directory) }

        let nested = self.root.appendingPathComponent("c02-missing", isDirectory: true).appendingPathComponent("child", isDirectory: true)
        self.expectFailure("createDirectory below a missing parent fails with notFound", .notFound) { () throws(FileSystemError) in
            try self.fileSystem.createDirectory(at: nested)
        }
    }

    func checkWrites() {
        let directory = self.made("c03-truncate")
        let file = directory.appendingPathComponent("file.bin")
        let clause = "write(.truncate) creates the file and replaces its content"
        self.expectSuccess(clause, "create") { () throws(FileSystemError) in try self.fileSystem.write(Data([1, 2, 3]), to: file, mode: .truncate) }
        self.expectContent(clause, file, [1, 2, 3])
        self.expectSuccess(clause, "replace") { () throws(FileSystemError) in try self.fileSystem.write(Data([9]), to: file, mode: .truncate) }
        self.expectContent(clause, file, [9])

        let appended = self.made("c04-append").appendingPathComponent("file.part")
        let append = "write(.append) creates an absent file and appends to an existing one"
        self.expectSuccess(append, "create") { () throws(FileSystemError) in try self.fileSystem.write(Data([1]), to: appended, mode: .append) }
        self.expectSuccess(append, "append") { () throws(FileSystemError) in try self.fileSystem.write(Data([2, 3]), to: appended, mode: .append) }
        self.expectContent(append, appended, [1, 2, 3])

        let orphan = self.root.appendingPathComponent("c05-missing", isDirectory: true).appendingPathComponent("file.bin")
        self.expectFailure("write into a missing directory fails with notFound", .notFound) { () throws(FileSystemError) in
            try self.fileSystem.write(Data([1]), to: orphan, mode: .truncate)
        }
    }

    func checkReads() {
        let file = self.made("c06-read").appendingPathComponent("file.bin")
        let clause = "read returns at most maxLength bytes from offset and empty Data at or past the end"
        self.expectSuccess(clause, "setup") { () throws(FileSystemError) in try self.fileSystem.write(Data(0..<10), to: file, mode: .truncate) }
        self.expectRead(clause, file, offset: 2, maxLength: 3, [2, 3, 4])
        self.expectRead(clause, file, offset: 8, maxLength: 5, [8, 9])
        self.expectRead(clause, file, offset: 10, maxLength: 4, [])
        self.expectRead(clause, file, offset: 25, maxLength: 4, [])

        let missing = self.made("c07-read-missing").appendingPathComponent("absent.bin")
        self.expectFailure("read of a missing file fails with notFound", .notFound) { () throws(FileSystemError) -> Data in
            try self.fileSystem.read(from: missing, offset: 0, maxLength: 4)
        }
    }

    func checkRenames() {
        let exclusive = self.made("c08-exclusive")
        let first = exclusive.appendingPathComponent("a.part")
        let second = exclusive.appendingPathComponent("b.part")
        let clause = "rename(.exclusive) onto an existing name fails with alreadyExists and touches neither name"
        self.write([1], to: first, clause)
        self.write([2], to: second, clause)
        self.expectFailure(clause, .alreadyExists) { () throws(FileSystemError) in
            try self.fileSystem.rename(from: first, to: second, mode: .exclusive)
        }
        self.expectContent(clause, first, [1])
        self.expectContent(clause, second, [2])

        let free = exclusive.appendingPathComponent("c.part")
        let move = "rename(.exclusive) onto a free name moves the file"
        self.expectSuccess(move, "rename") { () throws(FileSystemError) in try self.fileSystem.rename(from: first, to: free, mode: .exclusive) }
        self.expectAbsent(move, first)
        self.expectContent(move, free, [1])

        let replacing = self.made("c10-replacing")
        let source = replacing.appendingPathComponent("index.tmp")
        let target = replacing.appendingPathComponent("index.bin")
        let replace = "rename(.replacing) replaces an existing destination and removes the source name"
        self.write([7, 7], to: source, replace)
        self.write([1], to: target, replace)
        self.expectSuccess(replace, "rename") { () throws(FileSystemError) in try self.fileSystem.rename(from: source, to: target, mode: .replacing) }
        self.expectContent(replace, target, [7, 7])
        self.expectAbsent(replace, source)

        let ghost = replacing.appendingPathComponent("absent.tmp")
        self.expectFailure("rename of a missing source fails with notFound", .notFound) { () throws(FileSystemError) in
            try self.fileSystem.rename(from: ghost, to: replacing.appendingPathComponent("other.tmp"), mode: .replacing)
        }
    }

    func checkIdentity() {
        let directory = self.made("c12-identity")
        let file = directory.appendingPathComponent("file.bin")
        let moved = directory.appendingPathComponent("moved.bin")
        self.write([1, 2], to: file, "identity setup")
        let before = self.info(file)?.identity
        self.expectSuccess("write(.truncate) onto an existing file keeps its identity", "rewrite") { () throws(FileSystemError) in
            try self.fileSystem.write(Data([3]), to: file, mode: .truncate)
        }
        let rewritten = self.info(file)?.identity
        if let before, let rewritten, before != rewritten {
            self.fail("write(.truncate) onto an existing file keeps its identity", "identity changed from \(before) to \(rewritten)")
        }
        self.expectSuccess("rename keeps the moved file's identity", "rename") { () throws(FileSystemError) in
            try self.fileSystem.rename(from: file, to: moved, mode: .exclusive)
        }
        let after = self.info(moved)?.identity
        if let rewritten, let after, rewritten != after {
            self.fail("rename keeps the moved file's identity", "identity changed from \(rewritten) to \(after)")
        }
    }

    func checkRemoval() {
        let directory = self.made("c14-remove")
        let clause = "removeItem of an absent item succeeds, even below a missing directory"
        self.expectSuccess(clause, "absent file") { () throws(FileSystemError) in
            try self.fileSystem.removeItem(at: directory.appendingPathComponent("absent.bin"))
        }
        self.expectSuccess(clause, "missing parent") { () throws(FileSystemError) in
            try self.fileSystem.removeItem(at: directory.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("x"))
        }

        let removes = "removeItem removes a file and an empty directory"
        let file = directory.appendingPathComponent("file.bin")
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        self.write([1], to: file, removes)
        self.expectSuccess(removes, "create empty directory") { () throws(FileSystemError) in try self.fileSystem.createDirectory(at: empty) }
        self.expectSuccess(removes, "remove file") { () throws(FileSystemError) in try self.fileSystem.removeItem(at: file) }
        self.expectSuccess(removes, "remove directory") { () throws(FileSystemError) in try self.fileSystem.removeItem(at: empty) }
        self.expectAbsent(removes, file)
        self.expectAbsent(removes, empty)

        let notEmpty = "removeItem of a non-empty directory fails with notEmpty and keeps it"
        let full = directory.appendingPathComponent("full", isDirectory: true)
        self.expectSuccess(notEmpty, "create directory") { () throws(FileSystemError) in try self.fileSystem.createDirectory(at: full) }
        self.write([1], to: full.appendingPathComponent("child.bin"), notEmpty)
        self.expectFailure(notEmpty, .notEmpty) { () throws(FileSystemError) in try self.fileSystem.removeItem(at: full) }
        self.expectKind(notEmpty, full, .directory)
    }

    func checkMetadata() {
        let directory = self.made("c17-metadata")
        let file = directory.appendingPathComponent("file.bin")
        let clause = "itemInfo of an absent item is nil and of a file reports name, kind, size and modification time"
        if self.info(directory.appendingPathComponent("absent.bin")) != nil {
            self.fail(clause, "an absent item reported metadata")
        }
        self.write([1, 2, 3], to: file, clause)
        if let info = self.info(file) {
            if info.name != "file.bin" || info.kind != .file || info.byteSize != 3 || info.modifiedAt == nil {
                self.fail(clause, "reported \(info)")
            }
        } else {
            self.fail(clause, "no metadata for an existing file")
        }

        let listing = "contentsOfDirectory lists exactly one level with names, kinds and sizes"
        let sub = directory.appendingPathComponent("sub", isDirectory: true)
        self.expectSuccess(listing, "create subdirectory") { () throws(FileSystemError) in try self.fileSystem.createDirectory(at: sub) }
        self.write([1], to: sub.appendingPathComponent("deep.bin"), listing)
        switch self.result({ () throws(FileSystemError) -> [FileItemInfo] in try self.fileSystem.contentsOfDirectory(at: directory) }) {
        case .success(let items):
            let byName = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            if Set(byName.keys) != ["file.bin", "sub"] || byName["file.bin"]?.kind != .file || byName["file.bin"]?.byteSize != 3
                || byName["sub"]?.kind != .directory
            {
                self.fail(listing, "listed \(items.map { "\($0.name):\($0.kind):\($0.byteSize)" })")
            }
        case .failure(let error):
            self.fail(listing, "threw \(error)")
        }
        self.expectFailure("contentsOfDirectory of a missing directory fails with notFound", .notFound) { () throws(FileSystemError) -> [FileItemInfo] in
            try self.fileSystem.contentsOfDirectory(at: directory.appendingPathComponent("absent", isDirectory: true))
        }
    }

    func checkSymbolicLinks() {
        let directory = self.made("c19-links")
        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("link.bin")
        let clause = "itemInfo and listings report a symbolic link as a link and never follow it"
        self.write([1, 2, 3, 4, 5], to: target, clause)
        guard self.makeLink(at: link, destination: "target.bin") else {
            self.fail(clause, "fixture: could not create a symbolic link in \(directory.path)")
            return
        }
        self.expectKind(clause, link, .symbolicLink)
        switch self.result({ () throws(FileSystemError) -> [FileItemInfo] in try self.fileSystem.contentsOfDirectory(at: directory) }) {
        case .success(let items):
            if items.first(where: { $0.name == "link.bin" })?.kind != .symbolicLink {
                self.fail(clause, "listed \(items.map { "\($0.name):\($0.kind)" })")
            }
        case .failure(let error):
            self.fail(clause, "listing threw \(error)")
        }

        let removal = "removeItem of a symbolic link removes the link, not its target"
        self.expectSuccess(removal, "remove link") { () throws(FileSystemError) in try self.fileSystem.removeItem(at: link) }
        self.expectAbsent(removal, link)
        self.expectContent(removal, target, [1, 2, 3, 4, 5])
    }

    func checkShortWrite() {
        guard let seeding = self.fileSystem as? any FileSystemFixtureSeeding else {
            return  // only the fake can be made to write short on demand
        }
        let clause = "a short write reports its error after the bytes that landed"
        let file = self.made("c21-short").appendingPathComponent("file.part")
        seeding.seedShortWrite(at: file, landing: 2, error: .noSpace)
        self.expectFailure(clause, .noSpace) { () throws(FileSystemError) in try self.fileSystem.write(Data([1, 2, 3, 4]), to: file, mode: .append) }
        self.expectContent(clause, file, [1, 2])
    }

    func checkSyncs() {
        let directory = self.made("c22-sync")
        let file = directory.appendingPathComponent("file.bin")
        let clause = "synchronizeFile and synchronizeDirectory succeed at both levels on existing items"
        self.write([1], to: file, clause)
        for level in [SyncLevel.barrier, .full] {
            self.expectSuccess(clause, "file \(level)") { () throws(FileSystemError) in try self.fileSystem.synchronizeFile(at: file, level: level) }
            self.expectSuccess(clause, "directory \(level)") { () throws(FileSystemError) in
                try self.fileSystem.synchronizeDirectory(at: directory, level: level)
            }
        }
        self.expectFailure("synchronizeFile of a missing file fails with notFound", .notFound) { () throws(FileSystemError) in
            try self.fileSystem.synchronizeFile(at: directory.appendingPathComponent("absent.bin"), level: .barrier)
        }
    }

    func checkLocks() {
        let lock = self.made("c23-lock").appendingPathComponent("store.lock")
        let clause = "acquireExclusiveLock creates the lock file and fails with wouldBlock while any holder exists"
        guard case .success(let token) = self.result({ () throws(FileSystemError) -> FileLockToken in try self.fileSystem.acquireExclusiveLock(at: lock) })
        else {
            self.fail(clause, "the first acquisition failed")
            return
        }
        self.expectKind(clause, lock, .file)
        if let identity = self.info(lock)?.identity, identity != token.identity {
            self.fail(clause, "the token's identity \(token.identity) is not the lock file's \(identity)")
        }
        self.expectFailure(clause, .wouldBlock) { () throws(FileSystemError) -> FileLockToken in try self.fileSystem.acquireExclusiveLock(at: lock) }

        let release = "releaseLock is idempotent and the lock can be taken again"
        self.fileSystem.releaseLock(token)
        self.fileSystem.releaseLock(token)
        guard case .success(let again) = self.result({ () throws(FileSystemError) -> FileLockToken in try self.fileSystem.acquireExclusiveLock(at: lock) })
        else {
            self.fail(release, "re-acquiring failed")
            return
        }

        // A live descriptor number is reused after `close`, so a stale token must not name the new lock (R-STO-9).
        let stale = "releasing a stale token leaves a lock taken since then held"
        self.fileSystem.releaseLock(token)
        switch self.result({ () throws(FileSystemError) -> FileLockToken in try self.fileSystem.acquireExclusiveLock(at: lock) }) {
        case .success(let intruder):
            self.fail(stale, "a third holder took the lock after the first token was released again")
            self.fileSystem.releaseLock(intruder)
        case .failure(let error) where error != .wouldBlock:
            self.fail(stale, "acquiring the held lock failed with \(error) instead of wouldBlock")
        case .failure:
            break
        }
        self.fileSystem.releaseLock(again)
    }

    func checkAttributesAndCapacity() {
        let directory = self.made("c25-attributes")
        let clause = "applyStoreAttributes round-trips backup exclusion"
        self.expectSuccess(clause, "apply") { () throws(FileSystemError) in try self.fileSystem.applyStoreAttributes(.storeDefault, at: directory) }
        switch self.result({ () throws(FileSystemError) -> StoreAttributes in try self.fileSystem.storeAttributes(at: directory) }) {
        case .success(let attributes) where !attributes.excludedFromBackup:
            self.fail(clause, "read back \(attributes)")
        case .success:
            break
        case .failure(let error):
            self.fail(clause, "reading threw \(error)")
        }

        let capacity = "availableCapacity reports a non-negative figure for both purposes"
        for purpose in [CapacityPurpose.important, .opportunistic] {
            switch self.result({ () throws(FileSystemError) -> Int64 in try self.fileSystem.availableCapacity(at: directory, for: purpose) }) {
            case .success(let bytes) where bytes < 0:
                self.fail(capacity, "\(purpose) reported \(bytes)")
            case .success:
                break
            case .failure(let error):
                self.fail(capacity, "\(purpose) threw \(error)")
            }
        }
    }

    // MARK: Helpers

    func directory(_ name: String) -> URL {
        self.root.appendingPathComponent(name, isDirectory: true)
    }

    /// A clause's directory, created (a failure to create it is itself reported).
    func made(_ name: String) -> URL {
        let url = self.directory(name)
        self.expectSuccess("createDirectory creates one level and succeeds when the directory exists", "fixture \(name)") { () throws(FileSystemError) in
            try self.fileSystem.createDirectory(at: url)
        }
        return url
    }

    func result<T>(_ body: () throws(FileSystemError) -> T) -> Result<T, FileSystemError> {
        do throws(FileSystemError) {
            return .success(try body())
        } catch {
            return .failure(error)
        }
    }

    func info(_ url: URL) -> FileItemInfo? {
        if case .success(let info) = self.result({ () throws(FileSystemError) -> FileItemInfo? in try self.fileSystem.itemInfo(at: url) }) {
            return info
        }
        return nil
    }

    func fail(_ clause: String, _ detail: String) {
        self.violations.append(FileSystemConformanceViolation(clause: clause, detail: detail))
    }

    func write(_ bytes: [UInt8], to url: URL, _ clause: String) {
        self.expectSuccess(clause, "write \(url.lastPathComponent)") { () throws(FileSystemError) in
            try self.fileSystem.write(Data(bytes), to: url, mode: .truncate)
        }
    }

    func expectSuccess(_ clause: String, _ step: String, _ body: () throws(FileSystemError) -> Void) {
        if case .failure(let error) = self.result(body) {
            self.fail(clause, "\(step) threw \(error)")
        }
    }

    func expectFailure<T>(_ clause: String, _ expected: FileSystemError, _ body: () throws(FileSystemError) -> T) {
        switch self.result(body) {
        case .success:
            self.fail(clause, "succeeded instead of failing with \(expected)")
        case .failure(let error) where error != expected:
            self.fail(clause, "failed with \(error) instead of \(expected)")
        case .failure:
            break
        }
    }

    func expectContent(_ clause: String, _ url: URL, _ expected: [UInt8]) {
        switch self.result({ () throws(FileSystemError) -> Data in try self.fileSystem.read(from: url, offset: 0, maxLength: 1 << 20) }) {
        case .success(let data) where [UInt8](data) != expected:
            self.fail(clause, "\(url.lastPathComponent) holds \([UInt8](data)) instead of \(expected)")
        case .success:
            break
        case .failure(let error):
            self.fail(clause, "reading \(url.lastPathComponent) threw \(error)")
        }
    }

    func expectRead(_ clause: String, _ url: URL, offset: Int64, maxLength: Int, _ expected: [UInt8]) {
        switch self.result({ () throws(FileSystemError) -> Data in try self.fileSystem.read(from: url, offset: offset, maxLength: maxLength) }) {
        case .success(let data) where [UInt8](data) != expected:
            self.fail(clause, "read(offset: \(offset), maxLength: \(maxLength)) returned \([UInt8](data)) instead of \(expected)")
        case .success:
            break
        case .failure(let error):
            self.fail(clause, "read(offset: \(offset), maxLength: \(maxLength)) threw \(error)")
        }
    }

    func expectKind(_ clause: String, _ url: URL, _ kind: FileItemKind) {
        switch self.result({ () throws(FileSystemError) -> FileItemInfo? in try self.fileSystem.itemInfo(at: url) }) {
        case .success(let info) where info?.kind != kind:
            self.fail(clause, "\(url.lastPathComponent) is \(info.map { "\($0.kind)" } ?? "absent") instead of \(kind)")
        case .success:
            break
        case .failure(let error):
            self.fail(clause, "itemInfo(\(url.lastPathComponent)) threw \(error)")
        }
    }

    func expectAbsent(_ clause: String, _ url: URL) {
        switch self.result({ () throws(FileSystemError) -> FileItemInfo? in try self.fileSystem.itemInfo(at: url) }) {
        case .success(let info?):
            self.fail(clause, "\(url.lastPathComponent) still exists as \(info.kind)")
        case .success(nil):
            break
        case .failure(let error):
            self.fail(clause, "itemInfo(\(url.lastPathComponent)) threw \(error)")
        }
    }

    /// Creates the link fixture: through the fake's seeding hook, or with `FileManager` inside the caller's root
    /// (a real directory) for any other conformer.
    func makeLink(at url: URL, destination: String) -> Bool {
        if let seeding = self.fileSystem as? any FileSystemFixtureSeeding {
            return (try? seeding.seedSymbolicLink(at: url, destination: destination)) != nil
        }
        return (try? FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)) != nil
    }
}
