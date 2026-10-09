import Foundation
import ZTronAssetModel

/// What the load rule read of one index file: its size and either all of its bytes or only the first 64 (when the
/// size already proves it torn or too large to read).
struct IndexFileRead: Sendable, Hashable {
    /// The file's size on disk.
    var size: Int64
    /// The bytes read: the whole file, or a prefix.
    var bytes: [UInt8]
}

/// The outcome of the load rule (ARCHITECTURE §4.2).
struct IndexLoadOutcome: Sendable, Equatable {
    /// The newest valid generation, if any.
    var content: IndexContent?
    /// Which file it came from.
    var chosen: IndexFile?
    /// `1 + max(generation, launch epoch)` over every header that parsed (1 when none did).
    var nextGeneration: UInt64
    /// The newest valid generation, agreeing with the chosen one's store ID, outside `index.tmp` (0 when none): the
    /// committed generation while a chosen `index.tmp` is not yet promoted to `index.bin` (the launch commit's first
    /// step, ADR draft B-28, which can fail). Keys the chosen generation dooms wait for that promotion or a later
    /// commit (review: load rule vs commit protocol).
    var survivingGeneration: UInt64
    /// The file the surviving generation was read from, validated in full (`nil` when there is none): the index name
    /// the store counts as holding its committed generation until the promotion (ADR draft B-28, close-out cycle 5).
    var survivingFile: IndexFile?
    /// No valid generation although an index file existed, an invalid `index.bin`, a newer schema, or a chosen
    /// generation that was itself degraded.
    var degraded: Bool
    /// Some candidate was written by a newer schema (downgrade): nothing may be deleted.
    var newerSchema: Bool
    /// Whether any index file existed.
    var anyFileExisted: Bool
    /// The index files whose stat or read failed with an error (`IndexLoader`; the pure rule never sets it): the rule saw
    /// such a file as absent or torn without knowing either, so the launch must not write over it (ADR draft B-34).
    var unreadable: Set<IndexFile> = []
}

/// The load rule, as a pure function over what was read (store.md §2.5 as amended by ARCHITECTURE §4.2).
enum IndexLoadRule {
    /// Chooses the newest valid generation among `index.bin`, `index.tmp` and `index.prev`; never traps.
    ///
    /// A candidate is valid when its size is exactly `64 + bodyLength + 32` (after checking `bodyLength ≤ 64 MiB`),
    /// its magic, schema and trailer check and its body decodes. Candidates whose `storeID` differs from the newest
    /// valid one are ignored. `nextGeneration` counts every header that parsed, valid or not, so a failed attempt
    /// never shares a number with a later success (I-5).
    static func choose(_ files: [IndexFile: IndexFileRead]) -> IndexLoadOutcome {
        var valid: [(file: IndexFile, content: IndexContent)] = []
        var maxGeneration: UInt64?
        var newerSchema = false
        var binInvalid = false
        for file in IndexFile.allCases {
            guard let read = files[file] else {
                continue
            }
            if let header = IndexHeader.parse(read.bytes) {
                let top = max(header.generation, header.launchEpoch)
                maxGeneration = max(maxGeneration ?? 0, top)
            }
            let result: Result<IndexContent, IndexDecodeError>
            if read.size != Int64(read.bytes.count) {
                result = .failure(IndexLoadRule.prefixVerdict(read.bytes, size: read.size))
            } else {
                result = IndexCodec.decode(read.bytes)
            }
            switch result {
            case .success(let content):
                valid.append((file, content))
            case .failure(let error):
                if case .newerSchema = error {
                    newerSchema = true
                }
                if file == .current {
                    binInvalid = true
                }
            }
        }
        let next: UInt64
        if let maxGeneration {
            let (sum, overflow) = maxGeneration.addingReportingOverflow(1)
            next = overflow ? IndexHeader.generationCeiling : sum
        } else {
            next = 1
        }
        let newest = valid.max { $0.content.generation < $1.content.generation }
        let agreeing = valid.filter { $0.content.storeID == newest?.content.storeID }
        let chosen = agreeing.max { $0.content.generation < $1.content.generation }
        let surviving = agreeing.filter { $0.file != .temporary }.max { $0.content.generation < $1.content.generation }
        let anyFile = !files.isEmpty
        let degraded = (anyFile && chosen == nil) || binInvalid || newerSchema || (chosen?.content.degraded ?? false)
        return IndexLoadOutcome(
            content: chosen?.content,
            chosen: chosen?.file,
            nextGeneration: next,
            survivingGeneration: surviving?.content.generation ?? 0,
            survivingFile: surviving?.file,
            degraded: degraded,
            newerSchema: newerSchema,
            anyFileExisted: anyFile
        )
    }

    /// The verdict on a file that was not read in full: a newer schema is still recognised from its header, so a
    /// downgrade never deletes (R-STO-4); otherwise the file is torn, or too large to be any valid generation.
    private static func prefixVerdict(_ bytes: [UInt8], size: Int64) -> IndexDecodeError {
        guard let header = IndexHeader.parse(bytes) else {
            return bytes.count >= 8 && Array(bytes[0..<8]) != IndexHeader.magic ? .badMagic : .torn
        }
        if header.schemaVersion > StoreLayout.indexSchemaVersion {
            return .newerSchema(header.schemaVersion)
        }
        return size > IndexHeader.maxFileLength ? .limitExceeded : .torn
    }
}
