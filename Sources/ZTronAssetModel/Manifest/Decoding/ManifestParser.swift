/// The manifest schema on top of `JSONCursor` (R-MAN-1, R-MAN-2): both wire shapes, unknown fields skipped,
/// structural violations thrown, per-entry violations quarantined.
///
/// One pass, no recursion. Only the values an accepted entry needs are materialised, and only after their decoded
/// length passed the field's limit, so peak memory is the result plus a bounded scratch (R-MAN-3, ADR draft A-3).
struct ManifestParser {
    /// What one parse produced, before `ValidatedManifest` indexes it.
    struct Output {
        var entries: [ManifestEntry]
        var quarantined: [QuarantinedEntry]
        var shape: ManifestWireShape
    }

    private var cursor: JSONCursor
    private let options: ManifestDecodingOptions
    private var entries: [ManifestEntry] = []
    private var quarantined: [QuarantinedEntry] = []
    /// Identifiers that passed the identifier rules so far (R-MAN-2 duplicates, D-13).
    private var seen: Set<AssetID> = []

    init(bytes: UnsafeRawBufferPointer, options: ManifestDecodingOptions) {
        self.cursor = JSONCursor(bytes: bytes, maxDepth: options.limits.maxNestingDepth)
        self.options = options
    }

    /// Parses the whole payload.
    mutating func parse() throws(ManifestError) -> Output {
        self.cursor.skipByteOrderMark()
        let shape: ManifestWireShape
        switch try self.cursor.peekValueKind() {
        case .array:
            try self.parseAssets(depth: 1)
            shape = .bareArray
        case .object:
            shape = try self.parseEnvelope()
        default:
            // Valid JSON of another kind is the wrong shape; anything else is not JSON.
            try self.cursor.skipValue(depth: 0)
            try self.requireEnd()
            throw .undecodable(.unexpectedShape)
        }
        try self.requireEnd()
        return Output(entries: self.entries, quarantined: self.quarantined, shape: shape)
    }

    /// Only whitespace may follow the top-level value.
    private mutating func requireEnd() throws(ManifestError) {
        self.cursor.skipWhitespace()
        guard self.cursor.isAtEnd else {
            throw .undecodable(.notJSON)
        }
    }

    // MARK: - Envelope

    /// `{ "schemaVersion": Int, "assets": [...] }` in any member order, other members ignored. When `assets`
    /// precedes `schemaVersion`, it is skipped (validated only) and parsed afterwards, so a manifest of an
    /// unsupported version is never interpreted.
    private mutating func parseEnvelope() throws(ManifestError) -> ManifestWireShape {
        try self.cursor.checkDepth(1)
        try self.cursor.expect(JSONByte.openBrace)
        var schemaVersion: Int?
        var assetsOffset: Int?
        var assetsParsed = false
        if !self.cursor.consume(JSONByte.closeBrace) {
            repeat {
                let key = try self.cursor.readKey()
                if self.cursor.string(key, equals: ManifestParser.schemaVersionKey) {
                    guard schemaVersion == nil else {
                        throw .undecodable(.unexpectedShape)
                    }
                    schemaVersion = try self.parseSchemaVersion()
                } else if self.cursor.string(key, equals: ManifestParser.assetsKey) {
                    guard assetsOffset == nil, try self.cursor.peekValueKind() == .array else {
                        throw .undecodable(.unexpectedShape)
                    }
                    assetsOffset = self.cursor.offset
                    if let version = schemaVersion {
                        try self.requireSupported(version)
                        try self.parseAssets(depth: 2)
                        assetsParsed = true
                    } else {
                        try self.cursor.skipValue(depth: 1)
                    }
                } else {
                    try self.cursor.skipValue(depth: 1)
                }
            } while try self.cursor.continueContainer(closing: JSONByte.closeBrace)
        }
        try self.requireEnd()
        guard let version = schemaVersion, let offset = assetsOffset else {
            throw .undecodable(.unexpectedShape)
        }
        try self.requireSupported(version)
        if !assetsParsed {
            // The document is valid JSON (checked above); now interpret the assets it skipped.
            let end = self.cursor.offset
            self.cursor.seek(to: offset)
            try self.parseAssets(depth: 2)
            self.cursor.seek(to: end)
        }
        return .envelope(schemaVersion: version)
    }

    /// An integer-syntax number; anything else makes the envelope the wrong shape.
    private mutating func parseSchemaVersion() throws(ManifestError) -> Int {
        guard try self.cursor.peekValueKind() == .number else {
            try self.cursor.skipValue(depth: 1)
            throw .undecodable(.unexpectedShape)
        }
        let number = try self.cursor.scanNumber()
        guard number.isInteger else {
            throw .undecodable(.unexpectedShape)
        }
        let value = self.cursor.integerValue(of: number).value
        return Int(clamping: value)
    }

    private func requireSupported(_ version: Int) throws(ManifestError) {
        guard version >= 1, version <= self.options.maxSchemaVersion else {
            throw .unsupportedSchemaVersion(version)
        }
    }

    // MARK: - Assets

    /// The assets array at `depth` (1 for a bare array, 2 inside the envelope).
    private mutating func parseAssets(depth: Int) throws(ManifestError) {
        try self.cursor.checkDepth(depth)
        try self.cursor.expect(JSONByte.openBracket)
        if self.cursor.consume(JSONByte.closeBracket) {
            return
        }
        var index = 0
        repeat {
            guard index < self.options.limits.maxEntries else {
                throw .tooManyEntries(count: index + 1, limit: self.options.limits.maxEntries)
            }
            try self.parseEntry(index: index, depth: depth)
            index += 1
        } while try self.cursor.continueContainer(closing: JSONByte.closeBracket)
    }

    /// One element of the assets array; `depth` is the array's.
    private mutating func parseEntry(index: Int, depth: Int) throws(ManifestError) {
        guard try self.cursor.peekValueKind() == .object else {
            try self.cursor.skipValue(depth: depth)
            self.quarantined.append(QuarantinedEntry(index: index, identifier: nil, violation: .malformedField(ManifestRules.Field.entry)))
            return
        }
        let objectDepth = depth + 1
        try self.cursor.checkDepth(objectDepth)
        try self.cursor.expect(JSONByte.openBrace)
        var draft = EntryDraft()
        if !self.cursor.consume(JSONByte.closeBrace) {
            repeat {
                let key = try self.cursor.readKey()
                guard let field = self.field(for: key) else {
                    try self.cursor.skipValue(depth: objectDepth)
                    continue
                }
                if draft.isPresent(field) {
                    // A repeated member is ambiguous (parsers disagree on which one wins): never guess.
                    draft.reject(field, .malformedField(field.name))
                    try self.cursor.skipValue(depth: objectDepth)
                    continue
                }
                draft.markPresent(field)
                try self.parseField(field, into: &draft, depth: objectDepth)
            } while try self.cursor.continueContainer(closing: JSONByte.closeBrace)
        }
        try self.finish(draft, index: index)
    }

    /// Validates a finished draft and appends it to the entries or the quarantine.
    private mutating func finish(_ draft: EntryDraft, index: Int) throws(ManifestError) {
        let limits = self.options.limits
        var draft = draft
        for field in EntryField.required where !draft.isPresent(field) {
            draft.reject(field, .malformedField(field.name))
        }
        // Field-level rules on the materialised values, in field order (the same rules as `violations(of:)`).
        if let identifier = draft.identifier {
            if let violation = ManifestRules.identifierViolations(identifier, limits: limits).first {
                draft.reject(.identifier, violation)
            } else {
                let id = AssetID(identifier)
                if self.seen.contains(id) {
                    switch self.options.duplicates {
                    case .reject:
                        throw .duplicateIdentifier(id)
                    case .keepFirst:
                        draft.reject(.identifier, .malformedField(ManifestRules.Field.identifier))
                    }
                } else {
                    self.seen.insert(id)
                }
            }
        }
        if let fileExtension = draft.fileExtension, !ManifestRules.isValidFileExtension(fileExtension) {
            draft.reject(.fileExtension, .fileExtensionInvalid)
        }
        if let remotePath = draft.remotePath, let violation = ManifestRules.remotePathViolations(remotePath, limits: limits).first {
            draft.reject(.remotePath, .remotePathInvalid(violation))
        }
        if let byteSize = draft.byteSize, let violation = ManifestRules.byteSizeViolation(byteSize, limits: limits) {
            draft.reject(.byteSize, violation)
        }

        if let violation = draft.firstViolation {
            self.quarantined.append(QuarantinedEntry(index: index, identifier: draft.identifier.map { AssetID($0) }, violation: violation))
            return
        }
        guard let identifier = draft.identifier, let fileExtension = draft.fileExtension, let remotePath = draft.remotePath,
            let components = draft.localPathComponents
        else {
            // Unreachable: a missing required field was rejected above. Quarantine rather than trap.
            self.quarantined.append(QuarantinedEntry(index: index, identifier: nil, violation: .malformedField(ManifestRules.Field.entry)))
            return
        }
        self.entries.append(
            ManifestEntry(
                identifier: AssetID(identifier),
                fileExtension: fileExtension,
                remotePath: remotePath,
                localPathComponents: components,
                localFileName: draft.localFileName,
                byteSize: draft.byteSize,
                checksum: draft.checksum,
                tags: draft.tags ?? [],
                policy: draft.policy ?? .standard
            )
        )
    }

    // MARK: - Fields

    /// Reads one known member's value into the draft. Values over their field's limit are skipped, not
    /// materialised.
    private mutating func parseField(_ field: EntryField, into draft: inout EntryDraft, depth: Int) throws(ManifestError) {
        let limits = self.options.limits
        switch field {
        case .identifier:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            if string.decodedCount > limits.maxIdentifierBytes {
                draft.reject(field, .identifierTooLong(bytes: string.decodedCount))
            } else {
                draft.identifier = self.cursor.decodedString(of: string)
            }
        case .fileExtension:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            if string.decodedCount > 8 {
                draft.reject(field, .fileExtensionInvalid)
            } else {
                draft.fileExtension = self.cursor.decodedString(of: string)
            }
        case .remotePath:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            if string.decodedCount > limits.maxRemotePathBytes {
                draft.reject(field, .remotePathInvalid(.tooLong(bytes: string.decodedCount)))
            } else {
                draft.remotePath = self.cursor.decodedString(of: string)
            }
        case .localPathComponents:
            draft.localPathComponents = try self.stringArray(
                field, &draft, depth: depth, maxCount: ManifestRules.maxPathComponents,
                countViolation: .malformedField(field.name), elementViolation: { _ in nil }
            )
        case .localFileName:
            if try self.cursor.consumeNull() {
                return
            }
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            draft.localFileName = self.cursor.decodedString(of: string)
        case .byteSize:
            if try self.cursor.consumeNull() {
                return
            }
            guard try self.cursor.peekValueKind() == .number else {
                return try self.rejectValue(field, &draft, depth: depth)
            }
            let number = try self.cursor.scanNumber()
            guard number.isInteger else {
                return draft.reject(field, .malformedField(field.name))
            }
            draft.byteSize = self.cursor.integerValue(of: number).value
        case .checksum:
            if try self.cursor.consumeNull() {
                return
            }
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard string.decodedCount == 64, let hash = self.contentHash(of: string) else {
                return draft.reject(field, .checksumInvalid)
            }
            draft.checksum = hash
        case .tags:
            if try self.cursor.consumeNull() {
                return
            }
            draft.tags = try self.stringArray(
                field, &draft, depth: depth, maxCount: limits.maxTagsPerEntry, countViolation: .tagInvalid,
                elementViolation: { ManifestRules.isValidTagLength($0, limits: limits) ? nil : .tagInvalid }
            )
        case .policy:
            if try self.cursor.consumeNull() {
                return
            }
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard let policy = ManifestParser.policies.first(where: { self.cursor.string(string, equals: $0.key) })?.policy else {
                return draft.reject(field, .malformedField(field.name))
            }
            draft.policy = policy
        }
    }

    /// The next value as a string token, or `nil` after rejecting the field (and skipping the value) when it is not
    /// a string.
    private mutating func stringValue(_ field: EntryField, _ draft: inout EntryDraft, depth: Int) throws(ManifestError) -> JSONString? {
        guard try self.cursor.peekValueKind() == .string else {
            try self.rejectValue(field, &draft, depth: depth)
            return nil
        }
        return try self.cursor.scanString()
    }

    /// Skips the next value and rejects `field` as malformed.
    private mutating func rejectValue(_ field: EntryField, _ draft: inout EntryDraft, depth: Int) throws(ManifestError) {
        try self.cursor.skipValue(depth: depth)
        draft.reject(field, .malformedField(field.name))
    }

    /// An array of strings with at most `maxCount` elements, each checked by `elementViolation` (on its decoded
    /// UTF-8 length) before it is materialised. Returns `nil` after rejecting the field; the rest of the array is
    /// still validated as JSON but nothing more is materialised.
    private mutating func stringArray(
        _ field: EntryField,
        _ draft: inout EntryDraft,
        depth: Int,
        maxCount: Int,
        countViolation: ManifestEntryViolation,
        elementViolation: (Int) -> ManifestEntryViolation?
    ) throws(ManifestError) -> [String]? {
        guard try self.cursor.peekValueKind() == .array else {
            try self.rejectValue(field, &draft, depth: depth)
            return nil
        }
        try self.cursor.checkDepth(depth + 1)
        try self.cursor.expect(JSONByte.openBracket)
        var result: [String] = []
        var violation: ManifestEntryViolation?
        if !self.cursor.consume(JSONByte.closeBracket) {
            repeat {
                guard violation == nil else {
                    try self.cursor.skipValue(depth: depth + 1)
                    continue
                }
                guard try self.cursor.peekValueKind() == .string else {
                    try self.cursor.skipValue(depth: depth + 1)
                    violation = .malformedField(field.name)
                    continue
                }
                let string = try self.cursor.scanString()
                if result.count == maxCount {
                    violation = countViolation
                } else if let rejected = elementViolation(string.decodedCount) {
                    violation = rejected
                } else {
                    result.append(self.cursor.decodedString(of: string))
                }
            } while try self.cursor.continueContainer(closing: JSONByte.closeBracket)
        }
        if let violation {
            draft.reject(field, violation)
            return nil
        }
        return result
    }

    /// The digest a 64-character hexadecimal string spells (either case), or `nil` if any character is not hex.
    private func contentHash(of string: JSONString) -> ContentHash? {
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        let escaped = string.hasEscapes ? self.cursor.decodedBytes(of: string) : []
        for position in 0..<64 {
            let byte = string.hasEscapes ? escaped[position] : self.cursor.bytes[string.start + position]
            guard let nibble = JSONByte.hexNibble(byte) else {
                return nil
            }
            let value = UInt64(nibble)
            switch position / 16 {
            case 0:
                words.0 = words.0 << 4 | value
            case 1:
                words.1 = words.1 << 4 | value
            case 2:
                words.2 = words.2 << 4 | value
            default:
                words.3 = words.3 << 4 | value
            }
        }
        return ContentHash(w0: words.0, w1: words.1, w2: words.2, w3: words.3)
    }

    /// The known member a key names, or `nil` for an unknown member (ignored, R-MAN-1).
    private func field(for key: JSONString) -> EntryField? {
        EntryField.allCases.first { self.cursor.string(key, equals: $0.key) }
    }

    private static let schemaVersionKey = Array("schemaVersion".utf8)
    private static let assetsKey = Array("assets".utf8)
    private static let policies: [(policy: AssetPolicy, key: [UInt8])] = AssetPolicy.allCases.map { ($0, Array($0.rawValue.utf8)) }
}

/// The known members of an asset, in field order (the order violations are reported in).
enum EntryField: Int, CaseIterable {
    case identifier, fileExtension, remotePath, localPathComponents, localFileName, byteSize, checksum, tags, policy

    /// The members a legacy entry must carry (R-MAN-1: the prior art required them).
    static let required: [EntryField] = [.identifier, .fileExtension, .remotePath, .localPathComponents]

    /// The wire name.
    var name: String {
        switch self {
        case .identifier:
            return ManifestRules.Field.identifier
        case .fileExtension:
            return ManifestRules.Field.fileExtension
        case .remotePath:
            return ManifestRules.Field.remotePath
        case .localPathComponents:
            return ManifestRules.Field.localPathComponents
        case .localFileName:
            return ManifestRules.Field.localFileName
        case .byteSize:
            return ManifestRules.Field.byteSize
        case .checksum:
            return ManifestRules.Field.checksum
        case .tags:
            return ManifestRules.Field.tags
        case .policy:
            return ManifestRules.Field.policy
        }
    }

    /// The wire name as bytes, for allocation-free key matching.
    var key: [UInt8] {
        EntryField.keys[self.rawValue]
    }

    private static let keys: [[UInt8]] = EntryField.allCases.map { Array($0.name.utf8) }
}

/// One asset while its members are read: the materialised values and the first violation in field order.
struct EntryDraft {
    /// Members seen so far, one bit per `EntryField` (a repeated member is a violation).
    private var presentMask: UInt16 = 0
    var identifier: String?
    var fileExtension: String?
    var remotePath: String?
    var localPathComponents: [String]?
    var localFileName: String?
    var byteSize: Int64?
    var checksum: ContentHash?
    var tags: [String]?
    var policy: AssetPolicy?
    /// The violation of the earliest field (in field order) that has one; within a field, the first recorded.
    private(set) var firstViolation: ManifestEntryViolation?
    private var firstViolationField = Int.max

    /// Whether `field` was already seen.
    func isPresent(_ field: EntryField) -> Bool {
        self.presentMask & (1 << field.rawValue) != 0
    }

    /// Marks `field` as seen.
    mutating func markPresent(_ field: EntryField) {
        self.presentMask |= 1 << field.rawValue
    }

    /// Records `violation` for `field` unless an earlier field, or this field, already has one.
    mutating func reject(_ field: EntryField, _ violation: ManifestEntryViolation) {
        if field.rawValue < self.firstViolationField {
            self.firstViolationField = field.rawValue
            self.firstViolation = violation
        }
    }
}
