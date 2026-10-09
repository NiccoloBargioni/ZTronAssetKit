import Foundation
import ZTronAssetModel

/// The index load path of `open()` (ARCHITECTURE §4.2), shared with the P-2 benchmark so that the benchmark times the
/// production read loop and not a copy of it: one metadata unit stats the three files, metadata units of at most
/// 1 MiB read each candidate (only the header of a file too large to be valid), and the load rule decodes and chooses
/// on the bulk executor. A stat or read that fails with an error leaves what was read (nothing, for a stat), which the
/// load rule then sees as absent or torn, and names the file in `IndexLoadOutcome.unreadable`: `open()` then writes no
/// index file in that lifetime (ADR draft B-34). A read that returns fewer bytes than the file's size is torn, not an
/// error.
///
/// It runs outside the store's actor and counts no unit: it is called only while the store is `opening`, when
/// `close()` waits for `open()` to finish instead of draining units (REENTRANCY R1).
enum IndexLoader {
    /// Reads `index.bin`, `index.tmp` and `index.prev` under `layout` and applies the load rule.
    static func load(
        layout: StoreLayout,
        fileSystem: any FileSystem,
        metadata: any BlockingExecutor,
        bulk: any BlockingExecutor
    ) async -> IndexLoadOutcome {
        let listed = await metadata.run { () -> (sizes: [IndexFile: Int64], unreadable: Set<IndexFile>) in
            var sizes: [IndexFile: Int64] = [:]
            var unreadable: Set<IndexFile> = []
            for file in IndexFile.allCases {
                do throws(FileSystemError) {
                    if let info = try fileSystem.itemInfo(at: layout.indexURL(file)), info.kind == .file {
                        sizes[file] = info.byteSize
                    }
                } catch {
                    unreadable.insert(file)
                }
            }
            return (sizes, unreadable)
        }
        var unreadable = listed.unreadable
        var reads: [IndexFile: IndexFileRead] = [:]
        for file in IndexFile.allCases {
            guard let size = listed.sizes[file] else {
                continue
            }
            let url = layout.indexURL(file)
            let wanted = size <= IndexHeader.maxFileLength ? size : Int64(IndexHeader.length)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(wanted))
            reading: while Int64(bytes.count) < wanted {
                let offset = Int64(bytes.count)
                let length = Int(min(Int64(1 << 20), wanted - offset))
                let chunk = await metadata.run {
                    try? fileSystem.read(from: url, offset: offset, maxLength: length)
                }
                guard let chunk else {
                    unreadable.insert(file)
                    break reading
                }
                guard !chunk.isEmpty else {
                    break reading
                }
                bytes.append(contentsOf: chunk)
            }
            reads[file] = IndexFileRead(size: size, bytes: bytes)
        }
        let candidates = reads
        var outcome = await bulk.run {
            IndexLoadRule.choose(candidates)
        }
        outcome.unreadable = unreadable
        return outcome
    }
}
