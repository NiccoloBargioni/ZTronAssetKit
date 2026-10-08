import Foundation
import Synchronization
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel

/// The reader behind `LiveAssetPackBackend` (R-APL-1, C1, C2), exercised with pipes: no file is created.
@Suite("Apple tier: file-handle reader")
struct FileHandleChunkReaderTests {
    @available(macOS 26.0, *)
    @Test("R-APL-1: the live reader opens on its first read and streams bounded chunks to the end")
    func opensLazilyAndStreams() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("0123456789".utf8))
        try pipe.fileHandleForWriting.close()
        let opens = Mutex(0)
        let reader = FileHandleChunkReader {
            opens.withLock { $0 += 1 }
            return .success(pipe.fileHandleForReading)
        }
        #expect(opens.withLock { $0 } == 0, "creating the reader opens nothing")
        var chunks: [Data] = []
        while let chunk = try reader.nextChunk(maxBytes: 4) {
            chunks.append(chunk)
        }
        #expect(chunks == [Data("0123".utf8), Data("4567".utf8), Data("89".utf8)])
        #expect(try reader.nextChunk(maxBytes: 4) == nil)
        #expect(opens.withLock { $0 } == 1)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-1: an absent pack or file asks for the pack and a failed read is readFailed")
    func failuresMapToSourceFailures() {
        for (error, expected) in [
            (PackError.packNotFound, StagingError.source(.notInstalled)),
            (PackError.fileNotFound, StagingError.source(.notFound)),
            (PackError.system(domain: NSPOSIXErrorDomain, code: Int(EACCES)), StagingError.source(.system(domain: NSPOSIXErrorDomain, code: Int(EACCES)))),
        ] {
            let reader = FileHandleChunkReader { .failure(error) }
            #expect(throws: expected) {
                try reader.nextChunk(maxBytes: 4)
            }
        }
        let closed = FileHandleChunkReader { .success(FileHandle(fileDescriptor: -1, closeOnDealloc: false)) }
        #expect(throws: StagingError.source(.readFailed)) {
            try closed.nextChunk(maxBytes: 4)
        }
    }
}
