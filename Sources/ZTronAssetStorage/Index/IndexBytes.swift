import Foundation
import ZTronAssetModel

/// Appends the index's primitive encodings to a byte buffer (store.md §2.3): little-endian integers, unsigned
/// LEB128 varints, zigzag varints, IEEE doubles by bit pattern and 32-byte digests in digest order.
struct IndexByteWriter {
    /// The bytes written so far.
    private(set) var bytes: [UInt8] = []

    /// Creates an empty writer, reserving `capacity` bytes.
    init(capacity: Int = 0) {
        self.bytes.reserveCapacity(capacity)
    }

    /// One byte.
    mutating func u8(_ value: UInt8) {
        self.bytes.append(value)
    }

    /// Two little-endian bytes.
    mutating func u16(_ value: UInt16) {
        self.littleEndian(UInt64(value), count: 2)
    }

    /// Four little-endian bytes.
    mutating func u32(_ value: UInt32) {
        self.littleEndian(UInt64(value), count: 4)
    }

    /// Eight little-endian bytes.
    mutating func u64(_ value: UInt64) {
        self.littleEndian(value, count: 8)
    }

    /// Unsigned LEB128.
    mutating func varint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            self.bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        self.bytes.append(UInt8(remaining))
    }

    /// A count or index as a varint.
    mutating func count(_ value: Int) {
        self.varint(UInt64(max(0, value)))
    }

    /// Zigzag-encoded signed varint.
    mutating func zigzag(_ value: Int64) {
        self.varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    /// A date as the bit pattern of its reference-date interval: exact round trips, 8 bytes.
    mutating func date(_ value: Date) {
        self.u64(value.timeIntervalSinceReferenceDate.bitPattern)
    }

    /// The 32 digest bytes.
    mutating func hash(_ value: ContentHash) {
        for word in [value.w0, value.w1, value.w2, value.w3] {
            for shift in stride(from: 56, through: 0, by: -8) {
                self.bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
    }

    /// Raw bytes.
    mutating func append(_ other: [UInt8]) {
        self.bytes.append(contentsOf: other)
    }

    private mutating func littleEndian(_ value: UInt64, count: Int) {
        for index in 0..<count {
            self.bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(8 * index)))
        }
    }
}

/// A bounds-checked cursor over index bytes: every read either succeeds or throws `IndexDecodeError`; nothing traps
/// on hostile input (store-1 S1-04).
struct IndexByteReader {
    private let bytes: [UInt8]
    /// The next byte to read.
    private(set) var offset: Int
    /// One past the last readable byte.
    let end: Int

    /// A cursor over `bytes[start..<end]` (clamped to the buffer).
    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        let limit = min(end ?? bytes.count, bytes.count)
        self.end = max(0, limit)
        self.offset = min(max(0, start), self.end)
    }

    /// Bytes left.
    var remaining: Int {
        self.end - self.offset
    }

    /// Whether every byte was consumed.
    var isAtEnd: Bool {
        self.offset == self.end
    }

    /// One byte.
    mutating func u8() throws(IndexDecodeError) -> UInt8 {
        guard self.offset < self.end else {
            throw .malformed
        }
        defer {
            self.offset += 1
        }
        return self.bytes[self.offset]
    }

    /// Two little-endian bytes.
    mutating func u16() throws(IndexDecodeError) -> UInt16 {
        UInt16(truncatingIfNeeded: try self.littleEndian(count: 2))
    }

    /// Four little-endian bytes.
    mutating func u32() throws(IndexDecodeError) -> UInt32 {
        UInt32(truncatingIfNeeded: try self.littleEndian(count: 4))
    }

    /// Eight little-endian bytes.
    mutating func u64() throws(IndexDecodeError) -> UInt64 {
        try self.littleEndian(count: 8)
    }

    /// Unsigned LEB128 of at most ten bytes whose value fits 64 bits.
    mutating func varint() throws(IndexDecodeError) -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try self.u8()
            if shift == 63 && byte > 1 {
                throw .malformed
            }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
            guard shift <= 63 else {
                throw .malformed
            }
        }
    }

    /// A count that must not exceed what `minimumBytesEach`-byte items could fill in the remaining bytes.
    mutating func count(minimumBytesEach: Int) throws(IndexDecodeError) -> Int {
        let value = try self.varint()
        guard value <= UInt64(self.remaining / max(1, minimumBytesEach)) else {
            throw .limitExceeded
        }
        return Int(value)
    }

    /// A zigzag-encoded signed varint.
    mutating func zigzag() throws(IndexDecodeError) -> Int64 {
        let raw = try self.varint()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    /// A date stored as the bit pattern of its reference-date interval; non-finite values are malformed.
    mutating func date() throws(IndexDecodeError) -> Date {
        let interval = Double(bitPattern: try self.u64())
        guard interval.isFinite else {
            throw .malformed
        }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    /// 32 digest bytes.
    mutating func hash() throws(IndexDecodeError) -> ContentHash {
        guard self.remaining >= 32 else {
            throw .malformed
        }
        var words: [UInt64] = [0, 0, 0, 0]
        for index in 0..<32 {
            words[index / 8] = (words[index / 8] << 8) | UInt64(self.bytes[self.offset + index])
        }
        self.offset += 32
        return ContentHash(w0: words[0], w1: words[1], w2: words[2], w3: words[3])
    }

    /// `count` raw bytes.
    mutating func take(_ count: Int) throws(IndexDecodeError) -> ArraySlice<UInt8> {
        guard count >= 0, count <= self.remaining else {
            throw .malformed
        }
        defer {
            self.offset += count
        }
        return self.bytes[self.offset..<(self.offset + count)]
    }

    private mutating func littleEndian(count: Int) throws(IndexDecodeError) -> UInt64 {
        guard self.remaining >= count else {
            throw .malformed
        }
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(self.bytes[self.offset + index]) << UInt64(8 * index)
        }
        self.offset += count
        return value
    }
}
