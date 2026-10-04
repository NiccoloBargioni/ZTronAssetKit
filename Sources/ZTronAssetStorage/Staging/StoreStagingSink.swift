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
        fatalError("WP-B: StoreStagingSink.createPartial not implemented")
    }

    /// Appends a chunk and returns the new size.
    package func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64 {
        fatalError("WP-B: StoreStagingSink.appendPartial not implemented")
    }

    /// Exclusive rename of an earlier attempt's partial to this attempt's name.
    package func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64 {
        fatalError("WP-B: StoreStagingSink.continuePartial not implemented")
    }

    /// Moves a background download's OS temp file into staging (exclusive).
    package func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64 {
        fatalError("WP-B: StoreStagingSink.adoptDownload not implemented")
    }

    /// Writes the sidecar through `.resumetmp` and a rename.
    package func writeSidecar(_ sidecar: ResumeSidecar) {
        fatalError("WP-B: StoreStagingSink.writeSidecar not implemented")
    }

    /// Reads and decodes a sidecar.
    package func readSidecar(for name: StagingFileName) async -> ResumeSidecar? {
        fatalError("WP-B: StoreStagingSink.readSidecar not implemented")
    }

    /// Reads a staged manifest.
    package func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data {
        fatalError("WP-B: StoreStagingSink.readStaged not implemented")
    }

    /// Removes a staging file and its sidecar.
    package func discard(_ name: StagingFileName) async {
        fatalError("WP-B: StoreStagingSink.discard not implemented")
    }

    /// Streams a chunk source into staging.
    package func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError)
        -> Int64
    {
        fatalError("WP-B: StoreStagingSink.writeStaged not implemented")
    }
}
