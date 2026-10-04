/// The per-entry rules of R-MAN-2, one function per field, shared by `ManifestDecoder.violations(of:limits:)` and
/// the streaming parser so the two can never disagree. The text rules work on UTF-8 bytes: the parser passes the
/// payload's bytes (no copy), `violations(of:)` a string's contiguous UTF-8. Each returns the field's violations in
/// a fixed order (an empty array, which does not allocate, when the field is valid); the parser quarantines an entry
/// with the first violation in field order (identifier, fileExtension, remotePath, localPathComponents,
/// localFileName, byteSize, checksum, tags, policy).
enum ManifestRules {
    /// Path components per entry the decoder materialises: the index stores at most 32 per record (store design
    /// §2.3), and the cap bounds the allocation an array of tiny strings could cause (R-MAN-3). An entry with more
    /// is quarantined as `malformedField("localPathComponents")` (ADR draft A-4).
    static let maxPathComponents = 32

    /// The field names `ManifestEntryViolation.malformedField` carries.
    enum Field {
        static let entry = "entry"
        static let identifier = "identifier"
        static let fileExtension = "fileExtension"
        static let remotePath = "remotePath"
        static let localPathComponents = "localPathComponents"
        static let localFileName = "localFileName"
        static let byteSize = "byteSize"
        static let checksum = "checksum"
        static let tags = "tags"
        static let policy = "policy"
    }

    /// Every violation of `entry`, in field order.
    static func violations(of entry: ManifestEntry, limits: ManifestLimits) -> [ManifestEntryViolation] {
        var result = ManifestRules.withUTF8(of: entry.identifier.rawValue) {
            ManifestRules.identifierViolations(utf8: $0, limits: limits)
        }
        if !ManifestRules.withUTF8(of: entry.fileExtension, ManifestRules.isValidFileExtension(utf8:)) {
            result.append(.fileExtensionInvalid)
        }
        result += ManifestRules.withUTF8(of: entry.remotePath) {
            ManifestRules.remotePathViolations(utf8: $0, limits: limits)
        }.map { .remotePathInvalid($0) }
        if entry.localPathComponents.count > ManifestRules.maxPathComponents {
            result.append(.malformedField(Field.localPathComponents))
        }
        if let byteSize = entry.byteSize, let violation = ManifestRules.byteSizeViolation(byteSize, limits: limits) {
            result.append(violation)
        }
        if !ManifestRules.areValidTags(entry.tags, limits: limits) {
            result.append(.tagInvalid)
        }
        return result
    }

    /// Runs `body` over the UTF-8 bytes of `text`: its contiguous storage when it has one (native strings), else a
    /// copy, so both paths feed the rules identical bytes.
    static func withUTF8<Result>(of text: String, _ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        if let result = text.utf8.withContiguousStorageIfAvailable({ body(UnsafeRawBufferPointer($0)) }) {
            return result
        }
        return Array(text.utf8).withUnsafeBytes(body)
    }

    // MARK: - identifier

    /// Non-empty, at most `maxIdentifierBytes` UTF-8 bytes, no control character.
    static func identifierViolations(utf8: UnsafeRawBufferPointer, limits: ManifestLimits) -> [ManifestEntryViolation] {
        guard !utf8.isEmpty else {
            return [.identifierEmpty]
        }
        var result: [ManifestEntryViolation] = []
        if utf8.count > limits.maxIdentifierBytes {
            result.append(.identifierTooLong(bytes: utf8.count))
        }
        if ManifestRules.containsControlCharacter(utf8: utf8) {
            result.append(.identifierControlCharacter)
        }
        return result
    }

    /// Whether valid UTF-8 contains a Unicode control character (general category Cc): C0 (U+0000–U+001F), DEL
    /// (U+007F) or C1 (U+0080–U+009F, encoded `C2 80`…`C2 9F`).
    static func containsControlCharacter(utf8: UnsafeRawBufferPointer) -> Bool {
        let count = utf8.count
        var index = 0
        while index < count {
            let byte = utf8[index]
            if byte < 0x20 || byte == 0x7F {
                return true
            }
            if byte == 0xC2, index + 1 < count, utf8[index + 1] <= 0x9F {
                return true
            }
            index += 1
        }
        return false
    }

    // MARK: - fileExtension

    /// `[A-Za-z0-9]{1,8}`, the rule `AssetFileExtension` re-checks before any URL is built.
    static func isValidFileExtension(utf8: UnsafeRawBufferPointer) -> Bool {
        guard (1...8).contains(utf8.count) else {
            return false
        }
        for byte in utf8 {
            let lower = byte | 0x20
            let isLetter = lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            guard isLetter || isDigit else {
                return false
            }
        }
        return true
    }

    // MARK: - remotePath

    /// The remote path rules: relative, at most `maxRemotePathBytes` bytes, no control character, no scheme, no
    /// authority, not absolute and no `..` segment. The `..` check reads the path as the origin or a transport might:
    /// it ends at a query or fragment (`?`, `#`, RFC 3986 §4.2), segments are also separated by `\` and by
    /// percent-encoded slashes and backslashes (`%2F`, `%5C`), and a dot may be percent-encoded (`%2E`), since any of
    /// these may be decoded or normalised on the way (ADR draft A-4.7).
    static func remotePathViolations(utf8: UnsafeRawBufferPointer, limits: ManifestLimits) -> [RemotePathViolation] {
        let count = utf8.count
        guard count > 0 else {
            return [.empty]
        }
        var result: [RemotePathViolation] = []
        if count > limits.maxRemotePathBytes {
            result.append(.tooLong(bytes: count))
        }
        if ManifestRules.containsControlCharacter(utf8: utf8) {
            result.append(.controlCharacter)
        }
        let slash = UInt8(ascii: "/")
        // RFC 3986 §4.2: the first segment of a relative reference cannot contain a colon, so one there is a scheme.
        var schemeEnd: Int?
        var index = 0
        while index < count, utf8[index] != slash {
            if utf8[index] == UInt8(ascii: ":") {
                schemeEnd = index
                break
            }
            index += 1
        }
        if schemeEnd != nil {
            result.append(.scheme)
        }
        let hierarchyStart = schemeEnd.map { $0 + 1 } ?? 0
        if hierarchyStart + 1 < count, utf8[hierarchyStart] == slash, utf8[hierarchyStart + 1] == slash {
            result.append(.authority)
        }
        if utf8[0] == slash {
            result.append(.absolute)
        }
        // One pass: the path ends at the first `?` or `#`, or at the payload's end; each segment is checked when its
        // separator is reached. An ordinary byte costs one table load.
        let classes = ManifestRules.pathByteClasses
        var segmentStart = 0
        var pathEnd = count
        index = 0
        while index < pathEnd {
            let byteClass = classes[Int(utf8[index])]
            if byteClass == ManifestRules.ordinary {
                index += 1
                continue
            }
            if byteClass == ManifestRules.pathEnd {
                pathEnd = index
                break
            }
            let separator = byteClass == ManifestRules.separator ? 1 : ManifestRules.encodedSeparatorLength(utf8, at: index)
            guard separator > 0 else {
                index += 1
                continue
            }
            if ManifestRules.isParentSegment(utf8, from: segmentStart, to: index) {
                result.append(.parentSegment)
                return result
            }
            index += separator
            segmentStart = index
        }
        if ManifestRules.isParentSegment(utf8, from: segmentStart, to: pathEnd) {
            result.append(.parentSegment)
        }
        return result
    }

    /// The `..` check's byte classes, indexed by byte: `ordinary`, `separator` (`/`, `\`), `percent` (maybe an encoded
    /// separator) or `pathEnd` (`?`, `#`).
    private static let pathByteClasses: [UInt8] = (0...255).map { (byte: Int) -> UInt8 in
        switch UInt8(byte) {
        case UInt8(ascii: "/"), UInt8(ascii: "\\"):
            return ManifestRules.separator
        case UInt8(ascii: "%"):
            return ManifestRules.percent
        case UInt8(ascii: "?"), UInt8(ascii: "#"):
            return ManifestRules.pathEnd
        default:
            return ManifestRules.ordinary
        }
    }

    private static let ordinary: UInt8 = 0
    private static let separator: UInt8 = 1
    private static let percent: UInt8 = 2
    private static let pathEnd: UInt8 = 3

    /// 3 when `%` at `index` starts an encoded slash or backslash (`%2F`, `%5C`, either case), else 0. The two
    /// following bytes are inside the path when they are a separator: neither is `?` or `#`.
    private static func encodedSeparatorLength(_ utf8: UnsafeRawBufferPointer, at index: Int) -> Int {
        guard index + 2 < utf8.count else {
            return 0
        }
        let high = utf8[index + 1]
        let low = utf8[index + 2] | 0x20
        let isSlash = high == UInt8(ascii: "2") && low == UInt8(ascii: "f")
        let isBackslash = high == UInt8(ascii: "5") && low == UInt8(ascii: "c")
        return isSlash || isBackslash ? 3 : 0
    }

    /// Whether `utf8[start..<end]` is `..`, also spelled with percent-encoded dots (`%2e`, `%2E`).
    private static func isParentSegment(_ utf8: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Bool {
        // `..` is 2 bytes; with both dots encoded it is 6.
        guard end - start >= 2, end - start <= 6 else {
            return false
        }
        var dots = 0
        var index = start
        while index < end, dots < 3 {
            if utf8[index] == UInt8(ascii: ".") {
                index += 1
            } else if utf8[index] == UInt8(ascii: "%"), index + 2 < end, utf8[index + 1] == UInt8(ascii: "2"),
                utf8[index + 2] == UInt8(ascii: "e") || utf8[index + 2] == UInt8(ascii: "E")
            {
                index += 3
            } else {
                return false
            }
            dots += 1
        }
        return dots == 2 && index == end
    }

    // MARK: - byteSize, tags

    /// `byteSize` within `0...maxAssetBytes`.
    static func byteSizeViolation(_ byteSize: Int64, limits: ManifestLimits) -> ManifestEntryViolation? {
        byteSize >= 0 && byteSize <= limits.maxAssetBytes ? nil : .byteSizeOutOfRange(byteSize)
    }

    /// At most `maxTagsPerEntry` tags, each 1…`maxTagBytes` UTF-8 bytes.
    static func areValidTags(_ tags: [String], limits: ManifestLimits) -> Bool {
        tags.count <= limits.maxTagsPerEntry && tags.allSatisfy { ManifestRules.isValidTagLength($0.utf8.count, limits: limits) }
    }

    /// Whether a tag of `count` UTF-8 bytes is allowed.
    static func isValidTagLength(_ count: Int, limits: ManifestLimits) -> Bool {
        count > 0 && count <= limits.maxTagBytes
    }
}
