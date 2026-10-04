/// The per-entry rules of R-MAN-2, one function per field, shared by `ManifestDecoder.violations(of:limits:)` and
/// the streaming parser so the two can never disagree. Each returns the field's violations in a fixed order; the
/// parser quarantines an entry with the first violation in field order (identifier, fileExtension, remotePath,
/// localPathComponents, localFileName, byteSize, checksum, tags, policy).
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
        var result = ManifestRules.identifierViolations(entry.identifier.rawValue, limits: limits)
        if !ManifestRules.isValidFileExtension(entry.fileExtension) {
            result.append(.fileExtensionInvalid)
        }
        result += ManifestRules.remotePathViolations(entry.remotePath, limits: limits).map { .remotePathInvalid($0) }
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

    // MARK: - identifier

    /// Non-empty, at most `maxIdentifierBytes` UTF-8 bytes, no control character.
    static func identifierViolations(_ identifier: String, limits: ManifestLimits) -> [ManifestEntryViolation] {
        let count = identifier.utf8.count
        guard count > 0 else {
            return [.identifierEmpty]
        }
        var result: [ManifestEntryViolation] = []
        if count > limits.maxIdentifierBytes {
            result.append(.identifierTooLong(bytes: count))
        }
        if ManifestRules.containsControlCharacter(identifier) {
            result.append(.identifierControlCharacter)
        }
        return result
    }

    /// Whether `text` contains a Unicode control character (general category Cc: U+0000–U+001F, U+007F–U+009F).
    static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }

    // MARK: - fileExtension

    /// `[A-Za-z0-9]{1,8}`, the rule `AssetFileExtension` re-checks before any URL is built.
    static func isValidFileExtension(_ fileExtension: String) -> Bool {
        AssetFileExtension(fileExtension) != nil
    }

    // MARK: - remotePath

    /// The remote path rules: relative, at most `maxRemotePathBytes` bytes, no control character, no scheme, no
    /// authority, not absolute and no `..` segment (also when percent-encoded, since the origin may decode it).
    static func remotePathViolations(_ path: String, limits: ManifestLimits) -> [RemotePathViolation] {
        let utf8 = Array(path.utf8)
        guard !utf8.isEmpty else {
            return [.empty]
        }
        var result: [RemotePathViolation] = []
        if utf8.count > limits.maxRemotePathBytes {
            result.append(.tooLong(bytes: utf8.count))
        }
        if ManifestRules.containsControlCharacter(path) {
            result.append(.controlCharacter)
        }
        let slash = UInt8(ascii: "/")
        let firstSegmentEnd = utf8.firstIndex(of: slash) ?? utf8.count
        // RFC 3986 §4.2: the first segment of a relative reference cannot contain a colon, so one there is a scheme.
        let schemeEnd = utf8[..<firstSegmentEnd].firstIndex(of: UInt8(ascii: ":"))
        if schemeEnd != nil {
            result.append(.scheme)
        }
        let hierarchyStart = schemeEnd.map { $0 + 1 } ?? 0
        if hierarchyStart + 1 < utf8.count, utf8[hierarchyStart] == slash, utf8[hierarchyStart + 1] == slash {
            result.append(.authority)
        }
        if utf8[0] == slash {
            result.append(.absolute)
        }
        var segmentStart = 0
        for index in 0...utf8.count where index == utf8.count || utf8[index] == slash {
            if ManifestRules.isParentSegment(utf8[segmentStart..<index]) {
                result.append(.parentSegment)
                break
            }
            segmentStart = index + 1
        }
        return result
    }

    /// `..`, also spelled with percent-encoded dots (`%2e`, `%2E`).
    private static func isParentSegment(_ segment: ArraySlice<UInt8>) -> Bool {
        var dots = 0
        var index = segment.startIndex
        while index < segment.endIndex, dots < 3 {
            if segment[index] == UInt8(ascii: ".") {
                index += 1
            } else if segment[index] == UInt8(ascii: "%"), index + 2 < segment.endIndex,
                segment[index + 1] == UInt8(ascii: "2"),
                segment[index + 2] == UInt8(ascii: "e") || segment[index + 2] == UInt8(ascii: "E")
            {
                index += 3
            } else {
                return false
            }
            dots += 1
        }
        return dots == 2 && index == segment.endIndex
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
