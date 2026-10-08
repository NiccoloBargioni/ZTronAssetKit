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
    @Test("R-APL-1: overlapping first reads continue on the handle stored first and never read from two handles")
    func overlappingFirstReadsShareOneHandle() throws {
        let first = Pipe()
        let second = Pipe()
        try first.fileHandleForWriting.write(contentsOf: Data("first".utf8))
        try first.fileHandleForWriting.close()
        try second.fileHandleForWriting.write(contentsOf: Data("second".utf8))
        try second.fileHandleForWriting.close()
        let shared = Mutex<FileHandleChunkReader?>(nil)
        let opens = Mutex(0)
        let nestedChunk = Mutex<Data?>(nil)
        let reader = FileHandleChunkReader {
            let call = opens.withLock { count -> Int in
                count += 1
                return count
            }
            guard call == 1 else {
                return .success(second.fileHandleForReading)
            }
            // A second pull arrives while the first is still opening (the open runs outside the reader's lock).
            let nested = shared.withLock { $0 }
            let chunk = try? nested?.nextChunk(maxBytes: 3)
            nestedChunk.withLock { $0 = chunk }
            return .success(first.fileHandleForReading)
        }
        shared.withLock { $0 = reader }
        let outer = try reader.nextChunk(maxBytes: 3)
        #expect(nestedChunk.withLock { $0 } == Data("sec".utf8), "the nested pull opened and stored its handle first")
        #expect(outer == Data("ond".utf8), "the outer pull reads on from the stored handle, not the one it opened")
        #expect(opens.withLock { $0 } == 2)
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
