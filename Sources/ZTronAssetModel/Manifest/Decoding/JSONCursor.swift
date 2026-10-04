/// A forward-only JSON reader over untrusted manifest bytes (R-MAN-1, R-MAN-2, R-MAN-3).
///
/// Why not `JSONSerialization` or `JSONDecoder`: both materialise every value of the document (an `NSString` or a
/// `String` per key and value, a dictionary per object) before the schema is applied, so a 32 MiB payload of short
/// strings or a single huge unknown field costs several times the payload, and their nesting limits are not ours.
/// This reader validates the whole text as RFC 8259 JSON in UTF-8 but materialises nothing on its own: callers ask
/// for exactly the values the manifest schema needs, after checking their decoded length, and skip everything else
/// (unknown fields, over-long strings) without allocating. Nesting is tracked iteratively, so no input can exhaust
/// the stack, and the depth limit is checked before a container is entered.
///
/// It never traps: every read is preceded by an explicit bounds check against `bytes.count`, integer parsing
/// reports overflow instead of wrapping or trapping, and malformed input throws `ManifestError.undecodable`. The
/// buffer is a read-only view (no mutable pointer, ADR draft A-2) that never escapes the decoder's
/// `withUnsafeBytes` scope.
struct JSONCursor {
    /// The payload, read only.
    let bytes: UnsafeRawBufferPointer
    /// The next byte to read.
    private(set) var offset: Int
    /// The nesting limit (`ManifestLimits.maxNestingDepth`).
    let maxDepth: Int
    /// The containers `skipValue(depth:)` has open, one bit per level (set: an object). The first 64 levels live in
    /// `stackWord`, so within the default nesting limit (64) skipping never allocates (R-MAN-3: a payload of a few
    /// bytes must not cost a heap block); deeper levels, possible only under a larger configured limit, use
    /// `stackOverflow`, reserved once for the deepest nesting the payload can hold.
    private var stackCount = 0
    private var stackWord: UInt64 = 0
    private var stackOverflow: [UInt64] = []

    init(bytes: UnsafeRawBufferPointer, maxDepth: Int) {
        self.bytes = bytes
        self.offset = 0
        self.maxDepth = maxDepth
    }

    // MARK: - Bytes and structure

    /// Moves to `offset`, a position this cursor reached before (the envelope replays a skipped `assets` value).
    mutating func seek(to offset: Int) {
        self.offset = min(max(0, offset), self.bytes.count)
    }

    /// Whether every byte was consumed.
    var isAtEnd: Bool {
        self.offset >= self.bytes.count
    }

    /// The next byte, if any, without consuming it.
    func peek() -> UInt8? {
        self.offset < self.bytes.count ? self.bytes[self.offset] : nil
    }

    /// Skips a UTF-8 byte order mark at the very start (RFC 8259 §8.1 lets parsers ignore it).
    mutating func skipByteOrderMark() {
        if self.bytes.count >= 3, self.offset == 0, self.bytes[0] == 0xEF, self.bytes[1] == 0xBB, self.bytes[2] == 0xBF {
            self.offset = 3
        }
    }

    /// Skips JSON whitespace (space, tab, line feed, carriage return). Runs of eight spaces (pretty-printed
    /// indentation) are skipped a word at a time.
    mutating func skipWhitespace() {
        let bytes = self.bytes
        let end = bytes.count
        var offset = self.offset
        while offset < end {
            let byte = bytes[offset]
            if byte == JSONByte.space {
                offset += 1
                while offset + 8 <= end, bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self) == JSONWord.spaces {
                    offset += 8
                }
            } else if byte == JSONByte.lineFeed || byte == JSONByte.carriageReturn || byte == JSONByte.tab {
                offset += 1
            } else {
                break
            }
        }
        self.offset = offset
    }

    /// Skips whitespace, then consumes `byte` if it is next.
    mutating func consume(_ byte: UInt8) -> Bool {
        self.skipWhitespace()
        guard self.offset < self.bytes.count, self.bytes[self.offset] == byte else {
            return false
        }
        self.offset += 1
        return true
    }

    /// Skips whitespace, then consumes `byte` or throws `notJSON`.
    mutating func expect(_ byte: UInt8) throws(ManifestError) {
        guard self.consume(byte) else {
            throw .undecodable(.notJSON)
        }
    }

    /// Throws `nestingTooDeep` unless a container may be opened at `depth` (1 for the top level).
    func checkDepth(_ depth: Int) throws(ManifestError) {
        guard depth <= self.maxDepth else {
            throw .undecodable(.nestingTooDeep)
        }
    }

    /// After a member or element: consumes `,` (returns `true`, another one follows) or `close` (returns `false`).
    mutating func continueContainer(closing close: UInt8) throws(ManifestError) -> Bool {
        self.skipWhitespace()
        guard self.offset < self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        let byte = self.bytes[self.offset]
        self.offset += 1
        if byte == JSONByte.comma {
            // One trailing comma before the closer is accepted, exactly where the prior art's `JSONDecoder` accepted
            // one (R-MAN-1, ADR draft A-4.5): after a member or element, never alone, never twice.
            self.skipWhitespace()
            if self.offset < self.bytes.count, self.bytes[self.offset] == close {
                self.offset += 1
                return false
            }
            return true
        }
        guard byte == close else {
            throw .undecodable(.notJSON)
        }
        return false
    }

    /// Reads an object key and the `:` after it.
    mutating func readKey() throws(ManifestError) -> JSONString {
        self.skipWhitespace()
        guard self.peek() == JSONByte.quote else {
            throw .undecodable(.notJSON)
        }
        let key = try self.scanString()
        try self.expect(JSONByte.colon)
        return key
    }

    // MARK: - Values

    /// Skips whitespace and classifies the next value by its first byte, without consuming it.
    mutating func peekValueKind() throws(ManifestError) -> JSONValueKind {
        self.skipWhitespace()
        guard let byte = self.peek() else {
            throw .undecodable(.notJSON)
        }
        // Plain comparisons, not range patterns: those go through generic `~=` in unoptimised builds.
        if byte == JSONByte.quote {
            return .string
        }
        if byte == JSONByte.openBracket {
            return .array
        }
        if byte == JSONByte.openBrace {
            return .object
        }
        if byte == JSONByte.minus || JSONByte.isDigit(byte) {
            return .number
        }
        if byte == UInt8(ascii: "n") {
            return .null
        }
        if byte == UInt8(ascii: "t") || byte == UInt8(ascii: "f") {
            return .boolean
        }
        throw .undecodable(.notJSON)
    }

    /// Consumes `null` if it is the next value; returns whether it was.
    mutating func consumeNull() throws(ManifestError) -> Bool {
        guard try self.peekValueKind() == .null else {
            return false
        }
        try self.consumeLiteral(JSONByte.nullLiteral)
        return true
    }

    /// Skips one complete value of any kind at `depth` (the number of containers already open around it),
    /// validating it, iteratively so that no nesting can exhaust the stack.
    mutating func skipValue(depth: Int) throws(ManifestError) {
        self.stackCount = 0
        var level = depth
        while true {
            // A value starts here.
            switch try self.peekValueKind() {
            case .string:
                _ = try self.scanString()
            case .number:
                _ = try self.scanNumber()
            case .boolean:
                try self.consumeLiteral(self.peek() == UInt8(ascii: "t") ? JSONByte.trueLiteral : JSONByte.falseLiteral)
            case .null:
                try self.consumeLiteral(JSONByte.nullLiteral)
            case .array:
                level += 1
                try self.checkDepth(level)
                self.offset += 1
                if self.consume(JSONByte.closeBracket) {
                    level -= 1
                } else {
                    self.pushContainer(isObject: false)
                    continue
                }
            case .object:
                level += 1
                try self.checkDepth(level)
                self.offset += 1
                if self.consume(JSONByte.closeBrace) {
                    level -= 1
                } else {
                    self.pushContainer(isObject: true)
                    _ = try self.readKey()
                    continue
                }
            }
            // A value ended: close every container it completes, or move to the next member or element.
            while self.stackCount > 0 {
                let isObject = self.innermostContainerIsObject
                if try self.continueContainer(closing: isObject ? JSONByte.closeBrace : JSONByte.closeBracket) {
                    if isObject {
                        _ = try self.readKey()
                    }
                    break
                }
                self.stackCount -= 1
                level -= 1
            }
            if self.stackCount == 0 {
                return
            }
        }
    }

    /// The heap of the container stack's overflow: none within 64 levels, else the one reservation
    /// `pushContainer(isObject:)` makes for the deepest nesting this payload can hold (counted by R-MAN-3's estimate).
    var stackOverflowBytes: Int {
        self.stackOverflow.isEmpty ? 0 : ManifestFootprint.array(count: JSONCursor.overflowWords(maxDepth: self.maxDepth, payloadBytes: self.bytes.count), stride: 8)
    }

    /// The words the overflow is reserved for: one bit per level past the first 64, and never more levels than the limit
    /// or the payload's bytes (each level opens with one).
    private static func overflowWords(maxDepth: Int, payloadBytes: Int) -> Int {
        max(1, min(maxDepth, payloadBytes) / 64)
    }

    /// Records a container `skipValue(depth:)` opened.
    private mutating func pushContainer(isObject: Bool) {
        let level = self.stackCount
        let bit: UInt64 = 1 << UInt64(level % 64)
        if level < 64 {
            self.stackWord = isObject ? self.stackWord | bit : self.stackWord & ~bit
        } else {
            let word = level / 64 - 1
            if word == self.stackOverflow.count {
                if self.stackOverflow.isEmpty {
                    self.stackOverflow.reserveCapacity(JSONCursor.overflowWords(maxDepth: self.maxDepth, payloadBytes: self.bytes.count))
                }
                self.stackOverflow.append(0)
            }
            let current = self.stackOverflow[word]
            self.stackOverflow[word] = isObject ? current | bit : current & ~bit
        }
        self.stackCount += 1
    }

    /// Whether the innermost open container of `skipValue(depth:)` is an object.
    private var innermostContainerIsObject: Bool {
        let level = self.stackCount - 1
        let word = level < 64 ? self.stackWord : self.stackOverflow[level / 64 - 1]
        return word & (1 << UInt64(level % 64)) != 0
    }

    // MARK: - Strings

    /// Scans a string starting at its opening quote, validating escapes and UTF-8, and returns its extent and
    /// decoded length. Nothing is allocated. Printable ASCII, which is almost every byte of a manifest, is checked
    /// eight bytes at a time (`JSONWord.isPlainASCII`); anything else goes through the byte-wise path.
    mutating func scanString() throws(ManifestError) -> JSONString {
        guard self.peek() == JSONByte.quote else {
            throw .undecodable(.notJSON)
        }
        let bytes = self.bytes
        let end = bytes.count
        let start = self.offset + 1
        var offset = start
        var decodedCount = 0
        var hasEscapes = false
        while true {
            while offset + 8 <= end {
                let word = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                guard JSONWord.isPlainASCII(word) else {
                    break
                }
                offset += 8
                decodedCount += 8
            }
            guard offset < end else {
                throw .undecodable(.notJSON)
            }
            let byte = bytes[offset]
            if byte == JSONByte.quote {
                self.offset = offset + 1
                return JSONString(start: start, end: offset, decodedCount: decodedCount, hasEscapes: hasEscapes)
            } else if byte == JSONByte.backslash {
                hasEscapes = true
                self.offset = offset
                decodedCount += try self.scanEscape()
                offset = self.offset
            } else if byte < 0x20 {
                throw .undecodable(.notJSON)
            } else if byte < 0x80 {
                offset += 1
                decodedCount += 1
            } else {
                self.offset = offset
                decodedCount += try self.scanMultiByteScalar()
                offset = self.offset
            }
        }
    }

    /// The decoded UTF-8 bytes of a scanned string (escapes resolved). Only called for strings the schema wants
    /// and whose `decodedCount` passed its limit.
    func decodedBytes(of string: JSONString) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(string.decodedCount)
        var index = string.start
        while index < string.end {
            // Copy the run up to the next escape in one call.
            var runEnd = index
            while runEnd < string.end, self.bytes[runEnd] != JSONByte.backslash {
                runEnd += 1
            }
            if runEnd > index {
                result.append(contentsOf: UnsafeRawBufferPointer(rebasing: self.bytes[index..<runEnd]))
                index = runEnd
                continue
            }
            let escaped = self.bytes[index + 1]
            index += 2
            if escaped == UInt8(ascii: "u") {
                var scalar = JSONCursor.hexValue(self.bytes, at: index)
                index += 4
                if scalar >= 0xD800 && scalar <= 0xDBFF {
                    let low = JSONCursor.hexValue(self.bytes, at: index + 2)
                    index += 6
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                }
                JSONCursor.appendUTF8(scalar, to: &result)
            } else {
                result.append(JSONByte.unescaped(escaped))
            }
        }
        return result
    }

    /// The string's bytes as a view of the payload when it has no escape (the common case: no copy), else `nil`
    /// and the caller works on `decodedBytes(of:)`. Non-generic, so unoptimised builds pay no metadata lookups.
    func rawBytes(of string: JSONString) -> UnsafeRawBufferPointer? {
        string.hasEscapes ? nil : UnsafeRawBufferPointer(rebasing: self.bytes[string.start..<string.end])
    }

    /// The string's value. Validated UTF-8, so decoding never repairs anything.
    func decodedString(of string: JSONString) -> String {
        if string.hasEscapes {
            return String(decoding: self.decodedBytes(of: string), as: UTF8.self)
        }
        return String(decoding: UnsafeRawBufferPointer(rebasing: self.bytes[string.start..<string.end]), as: UTF8.self)
    }

    /// Whether the decoded string equals `literal`, an ASCII key or enumeration value, without allocating.
    ///
    /// An escaped string is decoded while it is compared and the comparison stops at the first difference: every
    /// unknown member of a manifest goes through here, and a key whose decoded length matches two field names
    /// would otherwise cost two heap copies per occurrence (R-MAN-3's time bound, fix round 2).
    func string(_ string: JSONString, equals literal: [UInt8]) -> Bool {
        guard string.decodedCount == literal.count else {
            return false
        }
        if string.hasEscapes {
            return self.escapedString(string, equals: literal)
        }
        var index = 0
        while index < literal.count {
            guard self.bytes[string.start + index] == literal[index] else {
                return false
            }
            index += 1
        }
        return true
    }

    /// `string(_:equals:)` for a string with escapes, already validated by `scanString`: each escape is decoded in
    /// place and compared byte by byte. The literal is ASCII, so a `\u` escape of a scalar beyond U+007F (a
    /// surrogate pair included) can never match and ends the comparison at once.
    private func escapedString(_ string: JSONString, equals literal: [UInt8]) -> Bool {
        var index = string.start
        var position = 0
        while index < string.end {
            var byte = self.bytes[index]
            index += 1
            if byte == JSONByte.backslash {
                let escaped = self.bytes[index]
                index += 1
                if escaped == UInt8(ascii: "u") {
                    let scalar = JSONCursor.hexValue(self.bytes, at: index)
                    index += 4
                    guard scalar < 0x80 else {
                        return false
                    }
                    byte = UInt8(scalar)
                } else {
                    byte = JSONByte.unescaped(escaped)
                }
            }
            guard position < literal.count, literal[position] == byte else {
                return false
            }
            position += 1
        }
        return position == literal.count
    }

    /// Whether two scanned strings decode to the same bytes, compared without allocating (the survey's identifier
    /// table, ADR draft A-8): raw bytes when neither has an escape, else both decoded in step.
    func string(_ lhs: JSONString, equalsString rhs: JSONString) -> Bool {
        guard lhs.decodedCount == rhs.decodedCount else {
            return false
        }
        if !lhs.hasEscapes, !rhs.hasEscapes {
            let count = lhs.end - lhs.start
            var index = 0
            while index + 8 <= count {
                let left = self.bytes.loadUnaligned(fromByteOffset: lhs.start + index, as: UInt64.self)
                guard left == self.bytes.loadUnaligned(fromByteOffset: rhs.start + index, as: UInt64.self) else {
                    return false
                }
                index += 8
            }
            while index < count {
                guard self.bytes[lhs.start + index] == self.bytes[rhs.start + index] else {
                    return false
                }
                index += 1
            }
            return true
        }
        var left = self.decodedBytes(iterating: lhs)
        var right = self.decodedBytes(iterating: rhs)
        while let byte = left.next() {
            guard byte == right.next() else {
                return false
            }
        }
        return right.next() == nil
    }

    /// Feeds a string's decoded bytes to `hasher`: its decoded length, then little-endian eight-byte words, the last
    /// one zero-padded. A string with escapes and one without hash alike when their decoded bytes are equal.
    func hash(_ string: JSONString, into hasher: inout Hasher) {
        hasher.combine(string.decodedCount)
        var word: UInt64 = 0
        var shift: UInt64 = 0
        if string.hasEscapes {
            var decoded = self.decodedBytes(iterating: string)
            while let byte = decoded.next() {
                word |= UInt64(byte) << shift
                shift += 8
                if shift == 64 {
                    hasher.combine(word)
                    word = 0
                    shift = 0
                }
            }
        } else {
            var offset = string.start
            while offset + 8 <= string.end {
                hasher.combine(UInt64(littleEndian: self.bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                offset += 8
            }
            while offset < string.end {
                word |= UInt64(self.bytes[offset]) << shift
                shift += 8
                offset += 1
            }
        }
        if shift > 0 {
            hasher.combine(word)
        }
    }

    /// The string whose body starts at `start` (one past its opening quote), scanned again: a token this cursor
    /// read before, so it is valid; `nil` otherwise.
    func string(startingAt start: Int) -> JSONString? {
        var copy = self
        copy.seek(to: start - 1)
        return try? copy.scanString()
    }

    /// The decoded UTF-8 bytes of a scanned string, one at a time, with escapes resolved as they are reached.
    func decodedBytes(iterating string: JSONString) -> JSONDecodedBytes {
        JSONDecodedBytes(bytes: self.bytes, index: string.start, end: string.end)
    }

    /// Scans one escape sequence at the backslash; returns its decoded UTF-8 length. (Plain comparisons throughout
    /// this section: range patterns go through generic `~=` in unoptimised builds.)
    private mutating func scanEscape() throws(ManifestError) -> Int {
        guard self.offset + 1 < self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        let escaped = self.bytes[self.offset + 1]
        self.offset += 2
        guard escaped == UInt8(ascii: "u") else {
            guard JSONByte.isSimpleEscape(escaped) else {
                throw .undecodable(.notJSON)
            }
            return 1
        }
        let unit = try self.scanHexQuad()
        if unit >= 0xD800 && unit <= 0xDBFF {
            // A high surrogate must be followed by an escaped low surrogate: together one 4-byte scalar.
            guard self.offset + 1 < self.bytes.count, self.bytes[self.offset] == JSONByte.backslash,
                self.bytes[self.offset + 1] == UInt8(ascii: "u")
            else {
                throw .undecodable(.notJSON)
            }
            self.offset += 2
            let low = try self.scanHexQuad()
            guard low >= 0xDC00 && low <= 0xDFFF else {
                throw .undecodable(.notJSON)
            }
            return 4
        }
        if unit >= 0xDC00 && unit <= 0xDFFF {
            throw .undecodable(.notJSON)
        }
        return unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3
    }

    /// Scans four hexadecimal digits and returns their value.
    private mutating func scanHexQuad() throws(ManifestError) -> UInt16 {
        guard self.offset + 4 <= self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        var value: UInt16 = 0
        var remaining = 4
        while remaining > 0 {
            guard let nibble = JSONByte.hexNibble(self.bytes[self.offset]) else {
                throw .undecodable(.notJSON)
            }
            value = value << 4 | UInt16(nibble)
            self.offset += 1
            remaining -= 1
        }
        return value
    }

    /// The value of four hexadecimal digits that `scanHexQuad` already validated.
    fileprivate static func hexValue(_ bytes: UnsafeRawBufferPointer, at index: Int) -> UInt32 {
        var value: UInt32 = 0
        var position = index
        while position < index + 4 {
            value = value << 4 | UInt32(JSONByte.hexNibble(bytes[position]) ?? 0)
            position += 1
        }
        return value
    }

    /// Validates one multi-byte UTF-8 scalar at `offset` (Unicode Table 3-7: no overlongs, no surrogates, nothing
    /// above U+10FFFF) and returns its length.
    private mutating func scanMultiByteScalar() throws(ManifestError) -> Int {
        let lead = self.bytes[self.offset]
        var secondLow: UInt8 = 0x80
        var secondHigh: UInt8 = 0xBF
        let length: Int
        if lead >= 0xC2 && lead <= 0xDF {
            length = 2
        } else if lead >= 0xE0 && lead <= 0xEF {
            length = 3
            if lead == 0xE0 {
                secondLow = 0xA0
            } else if lead == 0xED {
                secondHigh = 0x9F
            }
        } else if lead >= 0xF0 && lead <= 0xF4 {
            length = 4
            if lead == 0xF0 {
                secondLow = 0x90
            } else if lead == 0xF4 {
                secondHigh = 0x8F
            }
        } else {
            throw .undecodable(.notJSON)
        }
        guard self.offset + length <= self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        let second = self.bytes[self.offset + 1]
        guard second >= secondLow && second <= secondHigh else {
            throw .undecodable(.notJSON)
        }
        var index = self.offset + 2
        while index < self.offset + length {
            let byte = self.bytes[index]
            guard byte >= 0x80 && byte <= 0xBF else {
                throw .undecodable(.notJSON)
            }
            index += 1
        }
        self.offset += length
        return length
    }

    /// Appends the UTF-8 encoding of a scalar value that is known to be valid.
    private static func appendUTF8(_ scalar: UInt32, to bytes: inout [UInt8]) {
        if scalar < 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: scalar))
        } else if scalar < 0x800 {
            bytes.append(UInt8(truncatingIfNeeded: 0xC0 | scalar >> 6))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar & 0x3F))
        } else if scalar < 0x10000 {
            bytes.append(UInt8(truncatingIfNeeded: 0xE0 | scalar >> 12))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar >> 6 & 0x3F))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar & 0x3F))
        } else {
            bytes.append(UInt8(truncatingIfNeeded: 0xF0 | scalar >> 18))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar >> 12 & 0x3F))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar >> 6 & 0x3F))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar & 0x3F))
        }
    }

    // MARK: - Numbers and literals

    /// Scans a number per the RFC 8259 grammar and reports whether it used integer syntax only.
    mutating func scanNumber() throws(ManifestError) -> JSONNumber {
        let start = self.offset
        if self.peek() == JSONByte.minus {
            self.offset += 1
        }
        guard let first = self.peek(), JSONByte.isDigit(first) else {
            throw .undecodable(.notJSON)
        }
        self.offset += 1
        if first != JSONByte.zero {
            self.skipDigits()
        }
        var isInteger = true
        if self.peek() == UInt8(ascii: ".") {
            self.offset += 1
            try self.requireDigits()
            isInteger = false
        }
        if let exponent = self.peek(), exponent == UInt8(ascii: "e") || exponent == UInt8(ascii: "E") {
            self.offset += 1
            if let sign = self.peek(), sign == UInt8(ascii: "+") || sign == JSONByte.minus {
                self.offset += 1
            }
            try self.requireDigits()
            isInteger = false
        }
        return JSONNumber(start: start, end: self.offset, isInteger: isInteger)
    }

    /// The value of an integer-syntax number, saturated to `Int64` when out of range.
    func integerValue(of number: JSONNumber) -> (value: Int64, overflowed: Bool) {
        var index = number.start
        let negative = self.bytes[index] == JSONByte.minus
        if negative {
            index += 1
        }
        var value: Int64 = 0
        while index < number.end {
            let digit = Int64(self.bytes[index] - JSONByte.zero)
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let (next, overflowB) = negative ? shifted.subtractingReportingOverflow(digit) : shifted.addingReportingOverflow(digit)
            if overflowA || overflowB {
                return (negative ? Int64.min : Int64.max, true)
            }
            value = next
            index += 1
        }
        return (value, false)
    }

    /// The value of a number whose exact decimal value is an integer, whatever its spelling (`1234`, `1234.0`,
    /// `1.234e3`, `12340e-1`), saturated to `Int64` when out of range; `nil` when it has a non-zero fractional part
    /// (`1.5`, `1e-1`). Works on the digits, never on a floating-point value, so no spelling loses precision, and in
    /// time linear in the number's length whatever its exponent.
    func integralValue(of number: JSONNumber) -> Int64? {
        var index = number.start
        let negative = self.bytes[index] == JSONByte.minus
        if negative {
            index += 1
        }
        let integerStart = index
        while index < number.end, JSONByte.isDigit(self.bytes[index]) {
            index += 1
        }
        let integerCount = index - integerStart
        var fractionStart = index
        var fractionCount = 0
        if index < number.end, self.bytes[index] == UInt8(ascii: ".") {
            index += 1
            fractionStart = index
            while index < number.end, JSONByte.isDigit(self.bytes[index]) {
                index += 1
            }
            fractionCount = index - fractionStart
        }
        // The exponent, clamped: past 10^8 it only decides between zero, saturation and "fractional".
        var exponent = 0
        if index < number.end {
            index += 1
            let negativeExponent = self.bytes[index] == JSONByte.minus
            if negativeExponent || self.bytes[index] == UInt8(ascii: "+") {
                index += 1
            }
            while index < number.end {
                exponent = min(exponent * 10 + Int(self.bytes[index] - JSONByte.zero), 100_000_000)
                index += 1
            }
            if negativeExponent {
                exponent = -exponent
            }
        }
        // The value is the digit string D (integer then fraction digits) times 10^shift.
        let digitCount = integerCount + fractionCount
        let digits = (integerStart: integerStart, integerCount: integerCount, fractionStart: fractionStart)
        let shift = exponent - fractionCount
        // Digits that shift moves behind the decimal point must all be zero.
        let kept = shift < 0 ? digitCount + shift : digitCount
        var position = max(kept, 0)
        while position < digitCount {
            guard self.digit(position, of: digits) == 0 else {
                return nil
            }
            position += 1
        }
        let saturated = negative ? Int64.min : Int64.max
        var value: Int64 = 0
        position = 0
        while position < kept {
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let digit = self.digit(position, of: digits)
            let (next, overflowB) = negative ? shifted.subtractingReportingOverflow(digit) : shifted.addingReportingOverflow(digit)
            if overflowA || overflowB {
                return saturated
            }
            value = next
            position += 1
        }
        var zeros = shift
        while zeros > 0, value != 0 {
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 10)
            if overflow {
                return saturated
            }
            value = shifted
            zeros -= 1
        }
        return value
    }

    /// The digit at `position` of a number's digit string: its integer digits, then its fraction digits.
    private func digit(_ position: Int, of digits: (integerStart: Int, integerCount: Int, fractionStart: Int)) -> Int64 {
        let offset = position < digits.integerCount ? digits.integerStart + position : digits.fractionStart + position - digits.integerCount
        return Int64(self.bytes[offset] - JSONByte.zero)
    }

    /// Consumes `literal` exactly (`true`, `false`, `null`).
    private mutating func consumeLiteral(_ literal: [UInt8]) throws(ManifestError) {
        guard self.offset + literal.count <= self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        for (position, byte) in literal.enumerated() where self.bytes[self.offset + position] != byte {
            throw .undecodable(.notJSON)
        }
        self.offset += literal.count
    }

    private mutating func skipDigits() {
        while let byte = self.peek(), JSONByte.isDigit(byte) {
            self.offset += 1
        }
    }

    private mutating func requireDigits() throws(ManifestError) {
        guard let byte = self.peek(), JSONByte.isDigit(byte) else {
            throw .undecodable(.notJSON)
        }
        self.skipDigits()
    }
}

/// The first byte of a JSON value, which decides its kind.
enum JSONValueKind: Equatable {
    case string, number, boolean, null, array, object
}

/// A scanned string: its bytes between the quotes and its decoded UTF-8 length.
struct JSONString {
    /// The first byte after the opening quote.
    var start: Int
    /// The closing quote.
    var end: Int
    /// The UTF-8 length after resolving escapes.
    var decodedCount: Int
    /// Whether any escape occurs (otherwise the raw bytes are the value).
    var hasEscapes: Bool
}

/// The decoded UTF-8 bytes of a string `JSONCursor.scanString` validated, produced one at a time without allocating:
/// each escape is decoded when it is reached, and the further bytes of a multi-byte scalar wait in `pending`.
struct JSONDecodedBytes: IteratorProtocol {
    /// The payload.
    let bytes: UnsafeRawBufferPointer
    /// The next payload byte to read.
    var index: Int
    /// The closing quote.
    let end: Int
    /// Bytes of the current scalar still to return, lowest first.
    private var pending: UInt32 = 0
    private var pendingCount = 0

    init(bytes: UnsafeRawBufferPointer, index: Int, end: Int) {
        self.bytes = bytes
        self.index = index
        self.end = end
    }

    mutating func next() -> UInt8? {
        if self.pendingCount > 0 {
            let byte = UInt8(truncatingIfNeeded: self.pending)
            self.pending >>= 8
            self.pendingCount -= 1
            return byte
        }
        guard self.index < self.end else {
            return nil
        }
        let byte = self.bytes[self.index]
        guard byte == JSONByte.backslash else {
            self.index += 1
            return byte
        }
        let escaped = self.bytes[self.index + 1]
        self.index += 2
        guard escaped == UInt8(ascii: "u") else {
            return JSONByte.unescaped(escaped)
        }
        var scalar = JSONCursor.hexValue(self.bytes, at: self.index)
        self.index += 4
        if scalar >= 0xD800 && scalar <= 0xDBFF {
            let low = JSONCursor.hexValue(self.bytes, at: self.index + 2)
            self.index += 6
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
        }
        if scalar < 0x80 {
            return UInt8(truncatingIfNeeded: scalar)
        }
        if scalar < 0x800 {
            self.pending = 0x80 | scalar & 0x3F
            self.pendingCount = 1
            return UInt8(truncatingIfNeeded: 0xC0 | scalar >> 6)
        }
        if scalar < 0x10000 {
            self.pending = (0x80 | scalar >> 6 & 0x3F) | (0x80 | scalar & 0x3F) << 8
            self.pendingCount = 2
            return UInt8(truncatingIfNeeded: 0xE0 | scalar >> 12)
        }
        self.pending = (0x80 | scalar >> 12 & 0x3F) | (0x80 | scalar >> 6 & 0x3F) << 8 | (0x80 | scalar & 0x3F) << 16
        self.pendingCount = 3
        return UInt8(truncatingIfNeeded: 0xF0 | scalar >> 18)
    }
}

/// A scanned number.
struct JSONNumber {
    /// The first byte (a digit or `-`).
    var start: Int
    /// One past the last byte.
    var end: Int
    /// Whether it has neither a fraction nor an exponent.
    var isInteger: Bool
}

/// Eight-byte (SWAR) tests over little-endian words of the payload: each bit trick flags at least every byte it
/// is meant to find (false positives only send a word to the byte-wise path).
enum JSONWord {
    static let spaces: UInt64 = 0x2020_2020_2020_2020
    private static let ones: UInt64 = 0x0101_0101_0101_0101
    private static let highBits: UInt64 = 0x8080_8080_8080_8080

    /// Whether all eight bytes are printable ASCII other than `"` and `\`: no high bit, none below 0x20, none
    /// equal to a quote or a backslash.
    static func isPlainASCII(_ word: UInt64) -> Bool {
        let nonASCII = word & JSONWord.highBits
        let belowSpace = (word &- JSONWord.ones &* 0x20) & ~word & JSONWord.highBits
        let quote = JSONWord.zeroBytes(word ^ (JSONWord.ones &* UInt64(JSONByte.quote)))
        let backslash = JSONWord.zeroBytes(word ^ (JSONWord.ones &* UInt64(JSONByte.backslash)))
        return nonASCII | belowSpace | quote | backslash == 0
    }

    /// A non-zero value iff some byte of `word` is zero.
    private static func zeroBytes(_ word: UInt64) -> UInt64 {
        (word &- JSONWord.ones) & ~word & JSONWord.highBits
    }
}

/// The bytes the reader looks for.
enum JSONByte {
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let minus = UInt8(ascii: "-")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let trueLiteral = Array("true".utf8)
    static let falseLiteral = Array("false".utf8)
    static let nullLiteral = Array("null".utf8)

    /// Whether `\` followed by `byte` is one of the two-character escapes.
    static func isSimpleEscape(_ byte: UInt8) -> Bool {
        byte == JSONByte.quote || byte == JSONByte.backslash || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "b")
            || byte == UInt8(ascii: "f") || byte == UInt8(ascii: "n") || byte == UInt8(ascii: "r") || byte == UInt8(ascii: "t")
    }

    /// The byte a validated two-character escape stands for.
    static func unescaped(_ byte: UInt8) -> UInt8 {
        if byte == UInt8(ascii: "b") {
            return 0x08
        }
        if byte == UInt8(ascii: "f") {
            return 0x0C
        }
        if byte == UInt8(ascii: "n") {
            return 0x0A
        }
        if byte == UInt8(ascii: "r") {
            return 0x0D
        }
        if byte == UInt8(ascii: "t") {
            return 0x09
        }
        // `"`, `\` and `/` stand for themselves.
        return byte
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= JSONByte.zero && byte <= JSONByte.nine
    }

    static func hexNibble(_ byte: UInt8) -> UInt8? {
        if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
            return byte - UInt8(ascii: "0")
        }
        let lower = byte | 0x20
        if lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "f") {
            return lower - UInt8(ascii: "a") + 10
        }
        return nil
    }
}
