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
    /// Reused container stack for `skipValue(depth:)` (`true` = object), so skipping allocates at most once.
    private var stack: [Bool]

    init(bytes: UnsafeRawBufferPointer, maxDepth: Int) {
        self.bytes = bytes
        self.offset = 0
        self.maxDepth = maxDepth
        self.stack = []
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

    /// Skips JSON whitespace (space, tab, line feed, carriage return).
    mutating func skipWhitespace() {
        while self.offset < self.bytes.count {
            switch self.bytes[self.offset] {
            case JSONByte.space, JSONByte.tab, JSONByte.lineFeed, JSONByte.carriageReturn:
                self.offset += 1
            default:
                return
            }
        }
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
        switch byte {
        case JSONByte.quote:
            return .string
        case JSONByte.openBracket:
            return .array
        case JSONByte.openBrace:
            return .object
        case JSONByte.minus, JSONByte.zero...JSONByte.nine:
            return .number
        case UInt8(ascii: "n"):
            return .null
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            return .boolean
        default:
            throw .undecodable(.notJSON)
        }
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
        self.stack.removeAll(keepingCapacity: true)
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
                    self.stack.append(false)
                    continue
                }
            case .object:
                level += 1
                try self.checkDepth(level)
                self.offset += 1
                if self.consume(JSONByte.closeBrace) {
                    level -= 1
                } else {
                    self.stack.append(true)
                    _ = try self.readKey()
                    continue
                }
            }
            // A value ended: close every container it completes, or move to the next member or element.
            while let isObject = self.stack.last {
                if try self.continueContainer(closing: isObject ? JSONByte.closeBrace : JSONByte.closeBracket) {
                    if isObject {
                        _ = try self.readKey()
                    }
                    break
                }
                self.stack.removeLast()
                level -= 1
            }
            if self.stack.isEmpty {
                return
            }
        }
    }

    // MARK: - Strings

    /// Scans a string starting at its opening quote, validating escapes and UTF-8, and returns its extent and
    /// decoded length. Nothing is allocated.
    mutating func scanString() throws(ManifestError) -> JSONString {
        guard self.peek() == JSONByte.quote else {
            throw .undecodable(.notJSON)
        }
        self.offset += 1
        let start = self.offset
        var decodedCount = 0
        var hasEscapes = false
        let end = self.bytes.count
        while true {
            // The common case: a run of printable ASCII.
            while self.offset < end {
                let byte = self.bytes[self.offset]
                guard byte >= 0x20, byte < 0x80, byte != JSONByte.quote, byte != JSONByte.backslash else {
                    break
                }
                self.offset += 1
                decodedCount += 1
            }
            guard self.offset < end else {
                throw .undecodable(.notJSON)
            }
            let byte = self.bytes[self.offset]
            if byte == JSONByte.quote {
                let token = JSONString(start: start, end: self.offset, decodedCount: decodedCount, hasEscapes: hasEscapes)
                self.offset += 1
                return token
            }
            if byte == JSONByte.backslash {
                hasEscapes = true
                decodedCount += try self.scanEscape()
            } else if byte < 0x20 {
                throw .undecodable(.notJSON)
            } else {
                decodedCount += try self.scanMultiByteScalar()
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
            let byte = self.bytes[index]
            guard byte == JSONByte.backslash else {
                result.append(byte)
                index += 1
                continue
            }
            let escaped = self.bytes[index + 1]
            index += 2
            switch escaped {
            case UInt8(ascii: "b"):
                result.append(0x08)
            case UInt8(ascii: "f"):
                result.append(0x0C)
            case UInt8(ascii: "n"):
                result.append(0x0A)
            case UInt8(ascii: "r"):
                result.append(0x0D)
            case UInt8(ascii: "t"):
                result.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = UInt32(self.hexValue(at: index))
                index += 4
                if (0xD800...0xDBFF).contains(scalar) {
                    let low = UInt32(self.hexValue(at: index + 2))
                    index += 6
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                }
                JSONCursor.appendUTF8(scalar, to: &result)
            default:
                // `"`, `\` and `/` stand for themselves.
                result.append(escaped)
            }
        }
        return result
    }

    /// The string's value. Validated UTF-8, so decoding never repairs anything.
    func decodedString(of string: JSONString) -> String {
        if string.hasEscapes {
            return String(decoding: self.decodedBytes(of: string), as: UTF8.self)
        }
        return String(decoding: UnsafeRawBufferPointer(rebasing: self.bytes[string.start..<string.end]), as: UTF8.self)
    }

    /// Whether the decoded string equals `literal` (ASCII keys and enumeration values), without allocating for
    /// the common unescaped case.
    func string(_ string: JSONString, equals literal: [UInt8]) -> Bool {
        guard string.decodedCount == literal.count else {
            return false
        }
        if string.hasEscapes {
            return self.decodedBytes(of: string) == literal
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

    /// Scans one escape sequence at the backslash; returns its decoded UTF-8 length.
    private mutating func scanEscape() throws(ManifestError) -> Int {
        guard self.offset + 1 < self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        let escaped = self.bytes[self.offset + 1]
        self.offset += 2
        switch escaped {
        case JSONByte.quote, JSONByte.backslash, UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
            UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
            return 1
        case UInt8(ascii: "u"):
            let unit = try self.scanHexQuad()
            switch unit {
            case 0xD800...0xDBFF:
                // A high surrogate must be followed by an escaped low surrogate: together one 4-byte scalar.
                guard self.offset + 1 < self.bytes.count, self.bytes[self.offset] == JSONByte.backslash,
                    self.bytes[self.offset + 1] == UInt8(ascii: "u")
                else {
                    throw .undecodable(.notJSON)
                }
                self.offset += 2
                guard (0xDC00...0xDFFF).contains(try self.scanHexQuad()) else {
                    throw .undecodable(.notJSON)
                }
                return 4
            case 0xDC00...0xDFFF:
                throw .undecodable(.notJSON)
            case 0..<0x80:
                return 1
            case 0x80..<0x800:
                return 2
            default:
                return 3
            }
        default:
            throw .undecodable(.notJSON)
        }
    }

    /// Scans four hexadecimal digits and returns their value.
    private mutating func scanHexQuad() throws(ManifestError) -> UInt16 {
        guard self.offset + 4 <= self.bytes.count else {
            throw .undecodable(.notJSON)
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let nibble = JSONByte.hexNibble(self.bytes[self.offset]) else {
                throw .undecodable(.notJSON)
            }
            value = value << 4 | UInt16(nibble)
            self.offset += 1
        }
        return value
    }

    /// The value of four hexadecimal digits that `scanHexQuad` already validated.
    private func hexValue(at index: Int) -> UInt16 {
        var value: UInt16 = 0
        for position in index..<(index + 4) {
            value = value << 4 | UInt16(JSONByte.hexNibble(self.bytes[position]) ?? 0)
        }
        return value
    }

    /// Validates one multi-byte UTF-8 scalar at `offset` (Unicode Table 3-7: no overlongs, no surrogates, nothing
    /// above U+10FFFF) and returns its length.
    private mutating func scanMultiByteScalar() throws(ManifestError) -> Int {
        let lead = self.bytes[self.offset]
        let length: Int
        var secondRange: ClosedRange<UInt8> = 0x80...0xBF
        switch lead {
        case 0xC2...0xDF:
            length = 2
        case 0xE0:
            length = 3
            secondRange = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF:
            length = 3
        case 0xED:
            length = 3
            secondRange = 0x80...0x9F
        case 0xF0:
            length = 4
            secondRange = 0x90...0xBF
        case 0xF1...0xF3:
            length = 4
        case 0xF4:
            length = 4
            secondRange = 0x80...0x8F
        default:
            throw .undecodable(.notJSON)
        }
        guard self.offset + length <= self.bytes.count, secondRange.contains(self.bytes[self.offset + 1]) else {
            throw .undecodable(.notJSON)
        }
        var index = self.offset + 2
        while index < self.offset + length {
            guard (0x80...0xBF).contains(self.bytes[index]) else {
                throw .undecodable(.notJSON)
            }
            index += 1
        }
        self.offset += length
        return length
    }

    /// Appends the UTF-8 encoding of a scalar value that is known to be valid.
    private static func appendUTF8(_ scalar: UInt32, to bytes: inout [UInt8]) {
        switch scalar {
        case 0..<0x80:
            bytes.append(UInt8(truncatingIfNeeded: scalar))
        case 0x80..<0x800:
            bytes.append(UInt8(truncatingIfNeeded: 0xC0 | scalar >> 6))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar & 0x3F))
        case 0x800..<0x10000:
            bytes.append(UInt8(truncatingIfNeeded: 0xE0 | scalar >> 12))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar >> 6 & 0x3F))
            bytes.append(UInt8(truncatingIfNeeded: 0x80 | scalar & 0x3F))
        default:
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

/// A scanned number.
struct JSONNumber {
    /// The first byte (a digit or `-`).
    var start: Int
    /// One past the last byte.
    var end: Int
    /// Whether it has neither a fraction nor an exponent.
    var isInteger: Bool
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

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= JSONByte.zero && byte <= JSONByte.nine
    }

    static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
