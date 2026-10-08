import Foundation
import ZTronAssetModel

/// The store's implementation of the transport's `StagingSink` over the `FileSystem` seam (R-STO-6, ADR-019).
///
/// Immutable, so `Sendable` without escapes. Synchronous members run on URLSession's delegate queue (one bounded
/// unit each); async members run inside the store's executors. Every write targets `staging/` through
/// `StoreLayout`; exclusive renames never replace (transport-2 T2-02). Being immutable, it cannot see that the store
/// closed and promises nothing after close; shutdown order protects the store instead (`StagingSink` doc, T2-04).
package struct StoreStagingSink: StagingSink {
    /// The file system.
    package let fileSystem: any FileSystem
    /// The layout of the open store.
    package let layout: StoreLayout
    /// Hash and copy reads.
    package let bulkExecutor: any BlockingExecutor
    /// Small metadata units.
    package let metadataExecutor: any BlockingExecutor

    /// Creates a sink (`AssetStore.makeStagingSink()` only).
    package init(
        fileSystem: any FileSystem,
        layout: StoreLayout,
        bulkExecutor: any BlockingExecutor,
        metadataExecutor: any BlockingExecutor
    ) {
        self.fileSystem = fileSystem
        self.layout = layout
        self.bulkExecutor = bulkExecutor
        self.metadataExecutor = metadataExecutor
    }

    /// Creates or truncates the partial file.
    package func createPartial(_ name: StagingFileName) throws(StagingError) {
        try self.perform { () throws(FileSystemError) in
            try self.fileSystem.write(Data(), to: self.layout.stagingURL(name), mode: .truncate)
        }
    }

    /// Appends a chunk and returns the new size.
    package func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64 {
        let url = self.layout.stagingURL(name)
        return try self.perform { () throws(FileSystemError) -> Int64 in
            try self.fileSystem.write(data, to: url, mode: .append)
            return try self.size(of: url)
        }
    }

    /// Exclusive rename of an earlier attempt's partial to this attempt's name (transport-2 T2-02).
    package func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64 {
        let destination = self.layout.stagingURL(next)
        return try self.perform { () throws(FileSystemError) -> Int64 in
            try self.fileSystem.rename(from: self.layout.stagingURL(previous), to: destination, mode: .exclusive)
            return try self.size(of: destination)
        }
    }

    /// Moves a background download's OS temp file into staging (exclusive) before the delegate returns (R-STO-1).
    package func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64 {
        let destination = self.layout.stagingURL(name)
        return try self.perform { () throws(FileSystemError) -> Int64 in
            try self.fileSystem.rename(from: location, to: destination, mode: .exclusive)
            return try self.size(of: destination)
        }
    }

    /// Writes the sidecar through `.resumetmp` and a rename; best effort (a missing sidecar only costs a resume).
    package func writeSidecar(_ sidecar: ResumeSidecar) {
        let temporary = self.layout.stagingURL(sidecar.name.with(kind: .sidecarTemporary))
        let final = self.layout.stagingURL(sidecar.name.with(kind: .sidecar))
        guard let data = try? StoreStagingSink.encoder.encode(sidecar) else {
            return
        }
        do throws(FileSystemError) {
            try self.fileSystem.write(data, to: temporary, mode: .truncate)
            try self.fileSystem.rename(from: temporary, to: final, mode: .replacing)
        } catch {
            try? self.fileSystem.removeItem(at: temporary)
        }
    }

    /// Reads and decodes the sidecar of a partial off the pool; `nil` when absent, undecodable or describing another
    /// file (garbage for staging GC, R-CLN-3).
    package func readSidecar(for name: StagingFileName) async -> ResumeSidecar? {
        let url = self.layout.stagingURL(name.with(kind: .sidecar))
        let fileSystem = self.fileSystem
        let data = await self.metadataExecutor.run { () -> Data? in
            try? fileSystem.read(from: url, offset: 0, maxLength: StoreStagingSink.maxSidecarBytes)
        }
        guard let data, let sidecar = try? JSONDecoder().decode(ResumeSidecar.self, from: data),
            sidecar.name.with(kind: .partial) == name.with(kind: .partial)
        else {
            return nil
        }
        return sidecar
    }

    /// Reads a staged file (a manifest) of at most `maxBytes` bytes, in ≤ 1 MiB units on the bulk executor.
    package func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data {
        let url = self.layout.stagingURL(name)
        let fileSystem = self.fileSystem
        let size = try await self.bulkExecutor.run(throwing: { () throws(StagingError) -> Int64 in
            do throws(FileSystemError) {
                guard let info = try fileSystem.itemInfo(at: url), info.kind == .file else {
                    throw FileSystemError.notFound
                }
                return info.byteSize
            } catch {
                throw FileSystemErrorMapping.stagingError(error)
            }
        })
        guard size <= maxBytes else {
            throw .tooLarge(limit: maxBytes)
        }
        var data = Data()
        data.reserveCapacity(Int(size))
        while Int64(data.count) < size {
            let offset = Int64(data.count)
            let chunk = try await self.bulkExecutor.run(throwing: { () throws(StagingError) -> Data in
                do throws(FileSystemError) {
                    return try fileSystem.read(from: url, offset: offset, maxLength: 1 << 20)
                } catch {
                    throw FileSystemErrorMapping.stagingError(error)
                }
            })
            guard !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            guard Int64(data.count) <= maxBytes else {
                throw .tooLarge(limit: maxBytes)
            }
        }
        return data
    }

    /// Removes a staging file, its sidecar and the sidecar's temporary; idempotent.
    package func discard(_ name: StagingFileName) async {
        let urls = [name, name.with(kind: .sidecar), name.with(kind: .sidecarTemporary)].map(self.layout.stagingURL)
        let fileSystem = self.fileSystem
        await self.metadataExecutor.run {
            for url in urls {
                try? fileSystem.removeItem(at: url)
            }
        }
    }

    /// Streams a chunk source into `.parttmp` in ≤ 1 MiB units on the bulk executor, then renames it exclusively to
    /// `name` (ARCHITECTURE §3); more than `maxBytes` bytes removes the temporary and throws `.tooLarge`.
    package func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError)
        -> Int64
    {
        let temporary = self.layout.stagingURL(name.with(kind: .partialTemporary))
        let destination = self.layout.stagingURL(name)
        let fileSystem = self.fileSystem
        var total: Int64 = 0
        var first = true
        while true {
            let truncate = first
            let written = total
            let step = await self.bulkExecutor.run { () -> Result<Int?, StagingError> in
                do throws(StagingError) {
                    let chunk = try source.nextChunk(maxBytes: 1 << 20)
                    guard chunk != nil || truncate else {
                        return .success(nil)
                    }
                    let data = chunk ?? Data()
                    guard written + Int64(data.count) <= maxBytes else {
                        throw StagingError.tooLarge(limit: maxBytes)
                    }
                    do throws(FileSystemError) {
                        try fileSystem.write(data, to: temporary, mode: truncate ? .truncate : .append)
                    } catch {
                        throw FileSystemErrorMapping.stagingError(error)
                    }
                    return .success(chunk == nil ? nil : data.count)
                } catch {
                    return .failure(error)
                }
            }
            first = false
            switch step {
            case .success(let count?):
                total += Int64(count)
            case .success(nil):
                let result = await self.metadataExecutor.run { () -> Result<Void, StagingError> in
                    do throws(FileSystemError) {
                        try fileSystem.rename(from: temporary, to: destination, mode: .exclusive)
                        return .success(())
                    } catch {
                        try? fileSystem.removeItem(at: temporary)
                        return .failure(FileSystemErrorMapping.stagingError(error))
                    }
                }
                try result.get()
                return total
            case .failure(let error):
                await self.metadataExecutor.run {
                    try? fileSystem.removeItem(at: temporary)
                }
                throw error
            }
        }
    }

    // MARK: Helpers

    /// The largest sidecar read (a sidecar is a few hundred bytes of JSON).
    static let maxSidecarBytes = 64 * 1_024

    /// Deterministic sidecar JSON.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Runs one file-system step and maps its error (ENOSPC → `insufficientSpace`, EEXIST → `nameInUse`).
    private func perform<T>(_ work: () throws(FileSystemError) -> T) throws(StagingError) -> T {
        do throws(FileSystemError) {
            return try work()
        } catch {
            throw FileSystemErrorMapping.stagingError(error)
        }
    }

    /// The size of a staging file that must exist.
    private func size(of url: URL) throws(FileSystemError) -> Int64 {
        guard let info = try self.fileSystem.itemInfo(at: url) else {
            throw .notFound
        }
        return info.byteSize
    }
}
