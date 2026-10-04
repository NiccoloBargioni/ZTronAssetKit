/// The manifest schema on top of `JSONCursor` (R-MAN-1, R-MAN-2): both wire shapes, unknown fields skipped,
/// structural violations thrown, per-entry violations quarantined.
///
/// No recursion, two passes over the same code (ADR draft A-8). The *survey* pass (`survey(_:options:)`) validates
/// the whole payload, applies every per-entry rule on the payload's own bytes and counts what the result will hold
/// (every element of the assets array, and under `.keepFirst` the repeats of an accepted identifier), materialising
/// nothing; `ManifestDecoder` then refuses a payload whose decoded form would exceed its allocation budget
/// (R-MAN-3). The *build* pass reserves exactly the surveyed capacities and materialises only the values an entry
/// may use, so peak memory is the result plus one decoded string at most (ADR draft A-3). The identifier index
/// the result needs is built once, here, and handed to `ValidatedManifest`.
struct ManifestParser {
    /// What one parse produced: the manifest (build pass) or only the tally (survey pass).
    struct Output {
        var entries: [ManifestEntry]
        var positions: [AssetID: Int]
        var quarantined: [QuarantinedEntry]
        var shape: ManifestWireShape
        var survey: ManifestSurvey
    }

    private var cursor: JSONCursor
    private let options: ManifestDecodingOptions
    /// Whether this is the build pass (values are materialised) rather than the survey.
    private let building: Bool
    /// The survey pass's counts.
    private var tally = ManifestSurvey()
    private var entries: [ManifestEntry] = []
    private var quarantined: [QuarantinedEntry] = []
    /// Accepted identifiers and their positions: the result's index and the duplicate check (R-MAN-2, D-13).
    private var positions: [AssetID: Int] = [:]
    /// Valid identifiers of quarantined entries (`.reject` only): a later entry repeating one is a duplicate too.
    private var quarantinedIdentifiers: Set<AssetID> = []
    /// The survey's stand-in for `positions` under `.keepFirst`: the accepted identifiers as views of the payload,
    /// so a repeat is counted as quarantined (as the build will) without materialising a string.
    private var surveyedIdentifiers: Set<SurveyedIdentifier> = []
    /// Reused element buffer for string arrays, so each array is built at its exact size.
    private var scratch: [String] = []

    /// A survey pass when `survey` is `nil`, else a build pass that reserves what the survey counted.
    init(bytes: UnsafeRawBufferPointer, options: ManifestDecodingOptions, reserving survey: ManifestSurvey?) {
        self.cursor = JSONCursor(bytes: bytes, maxDepth: options.limits.maxNestingDepth)
        self.options = options
        self.building = survey != nil
        if let survey {
            self.entries.reserveCapacity(survey.acceptedCount)
            self.positions.reserveCapacity(survey.acceptedCount)
            self.quarantined.reserveCapacity(survey.quarantinedCount)
            self.quarantinedIdentifiers.reserveCapacity(survey.quarantinedIdentifierCount)
        }
    }

    /// Runs the survey pass over the whole payload and returns its counts. The pass's own buffers (the container
    /// stack, and under `.keepFirst` the set of accepted identifiers) are released when it returns, before the build
    /// pass allocates anything.
    static func survey(_ bytes: UnsafeRawBufferPointer, options: ManifestDecodingOptions) throws(ManifestError) -> ManifestSurvey {
        var parser = ManifestParser(bytes: bytes, options: options, reserving: nil)
        return try parser.parse().survey
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
        return Output(entries: self.entries, positions: self.positions, quarantined: self.quarantined, shape: shape, survey: self.tally)
    }

    /// Only whitespace may follow the top-level value.
    private mutating func requireEnd() throws(ManifestError) {
        self.cursor.skipWhitespace()
        guard self.cursor.isAtEnd else {
            throw .undecodable(.notJSON)
        }
    }

    // MARK: - Envelope

    /// `{ "schemaVersion": Int, "assets": [...] }` in any member order, other members ignored.
    ///
    /// The verdict on an envelope never depends on the order of its members (ADR draft A-4.9). It is reached in a
    /// fixed order: the whole document must be JSON within the nesting limit (`notJSON`, `nestingTooDeep`); then
    /// exactly one `schemaVersion` must declare an integer (else `unexpectedShape`: a missing, repeated or
    /// non-integer version cannot be read), and one this build interprets (else `unsupportedSchemaVersion`, whatever
    /// `assets` looks like, since a later schema may restructure or drop it); only then does the v1 shape apply
    /// (`assets` present, an array, not repeated). So `assets` is interpreted in place only when a supported version
    /// precedes it; otherwise it is skipped (validated only) with its facts recorded, and parsed once the document
    /// has been read. An unsupported version is therefore never interpreted.
    ///
    /// With a supported version read first, an error inside `assets` (a duplicate identifier, too many entries) is
    /// reported before a shape violation that follows it; both reject the manifest.
    private mutating func parseEnvelope() throws(ManifestError) -> ManifestWireShape {
        try self.cursor.checkDepth(1)
        try self.cursor.expect(JSONByte.openBrace)
        var versionCount = 0
        var schemaVersion: Int?
        var assetsOffset: Int?
        var assetsIsArray = false
        var assetsRepeated = false
        var assetsParsed = false
        if !self.cursor.consume(JSONByte.closeBrace) {
            repeat {
                let key = try self.cursor.readKey()
                if self.cursor.string(key, equals: ManifestParser.schemaVersionKey) {
                    versionCount += 1
                    let version = try self.parseSchemaVersion()
                    if versionCount == 1 {
                        schemaVersion = version
                    }
                } else if self.cursor.string(key, equals: ManifestParser.assetsKey) {
                    let isArray = try self.cursor.peekValueKind() == .array
                    if assetsOffset == nil {
                        assetsOffset = self.cursor.offset
                        assetsIsArray = isArray
                    } else {
                        assetsRepeated = true
                    }
                    if versionCount == 1, let version = schemaVersion, self.isSupported(version), isArray, !assetsRepeated {
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
        guard versionCount == 1, let version = schemaVersion else {
            throw .undecodable(.unexpectedShape)
        }
        try self.requireSupported(version)
        guard let offset = assetsOffset, assetsIsArray, !assetsRepeated else {
            throw .undecodable(.unexpectedShape)
        }
        if !assetsParsed {
            // The document is valid JSON (checked above); now interpret the assets it skipped.
            let end = self.cursor.offset
            self.cursor.seek(to: offset)
            try self.parseAssets(depth: 2)
            self.cursor.seek(to: end)
        }
        return .envelope(schemaVersion: version)
    }

    /// The version an integer-syntax number declares, or `nil` for any other value, which is skipped (validated
    /// only): the envelope is then the wrong shape, judged once the document has been read. Out-of-range values
    /// saturate (and are then unsupported).
    private mutating func parseSchemaVersion() throws(ManifestError) -> Int? {
        guard try self.cursor.peekValueKind() == .number else {
            try self.cursor.skipValue(depth: 1)
            return nil
        }
        let number = try self.cursor.scanNumber()
        guard number.isInteger else {
            return nil
        }
        return Int(clamping: self.cursor.integerValue(of: number).value)
    }

    /// Whether this build interprets `version` (1 through `maxSchemaVersion`).
    private func isSupported(_ version: Int) -> Bool {
        version >= 1 && version <= self.options.maxSchemaVersion
    }

    private func requireSupported(_ version: Int) throws(ManifestError) {
        guard self.isSupported(version) else {
            throw .unsupportedSchemaVersion(version)
        }
    }

    // MARK: - Assets

    /// The assets array at `depth` (1 for a bare array, 2 inside the envelope). The entry limit counts every
    /// element, quarantined ones included, and stops the parse at the first element past it.
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
            guard self.building else {
                // Two payload bytes (`1,`) can cost a whole diagnostic: the survey counts it like any quarantine.
                self.tally.quarantinedCount += 1
                return
            }
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

    /// Applies the cross-field rules (required members, duplicate identifiers) and appends the entry to the
    /// result or the quarantine (build pass), or counts it (survey pass).
    ///
    /// Duplicates (ADR draft A-4.3): under `.reject` a valid identifier repeating an accepted or a quarantined one
    /// rejects the manifest. Under `.keepFirst` only an accepted identifier makes a later occurrence a duplicate, so
    /// the first occurrence that can be kept is kept, and the repeat is quarantined as `malformedField("identifier")`.
    private mutating func finish(_ draft: EntryDraft, index: Int) throws(ManifestError) {
        var draft = draft
        for field in EntryField.required where !draft.isPresent(field) {
            draft.reject(field, .malformedField(field.name))
        }
        guard self.building else {
            self.countInSurvey(draft)
            return
        }
        let id = draft.identifier.map { AssetID($0) }
        if let id, draft.identifierIsValid {
            switch self.options.duplicates {
            case .reject:
                if self.positions[id] != nil || self.quarantinedIdentifiers.contains(id) {
                    throw .duplicateIdentifier(id)
                }
            case .keepFirst:
                if self.positions[id] != nil {
                    draft.reject(.identifier, .malformedField(ManifestRules.Field.identifier))
                    draft.identifierIsValid = false
                }
            }
        }
        guard draft.firstViolation == nil, let id, let fileExtension = draft.fileExtension,
            let remotePath = draft.remotePath, let components = draft.localPathComponents
        else {
            if let id, draft.identifierIsValid, self.options.duplicates == .reject {
                self.quarantinedIdentifiers.insert(id)
            }
            let violation = draft.firstViolation ?? .malformedField(ManifestRules.Field.entry)
            self.quarantined.append(QuarantinedEntry(index: index, identifier: id, violation: violation))
            return
        }
        self.positions[id] = self.entries.count
        self.entries.append(
            ManifestEntry(
                identifier: id,
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

    /// The survey pass's count of one entry, matching what `finish` does with it in the build pass. Under
    /// `.keepFirst` an entry that passes every rule but repeats an accepted identifier is a quarantine, found by
    /// comparing the identifiers' decoded bytes exactly (no hash stands in for them), so the build reserves exactly.
    private mutating func countInSurvey(_ draft: EntryDraft) {
        guard draft.firstViolation == nil else {
            self.tally.quarantinedCount += 1
            if draft.identifierIsValid, self.options.duplicates == .reject {
                self.tally.quarantinedIdentifierCount += 1
            }
            return
        }
        if let identifier = draft.surveyedIdentifier, !self.surveyedIdentifiers.insert(identifier).inserted {
            self.tally.quarantinedCount += 1
            return
        }
        self.tally.acceptedCount += 1
    }

    /// The string's value in the build pass; in the survey pass, its heap cost is counted and `nil` returned.
    private mutating func materialize(_ string: JSONString) -> String? {
        guard self.building else {
            self.tally.materializedBytes += ManifestFootprint.string(utf8Count: string.decodedCount)
            if string.hasEscapes {
                self.tally.largestEscapedString = max(self.tally.largestEscapedString, string.decodedCount)
            }
            return nil
        }
        return self.cursor.decodedString(of: string)
    }

    // MARK: - Fields

    /// Reads one known member's value into the draft. Text is checked against the field's rules on the payload's
    /// bytes first; a value over its field's length limit is never materialised.
    private mutating func parseField(_ field: EntryField, into draft: inout EntryDraft, depth: Int) throws(ManifestError) {
        let limits = self.options.limits
        switch field {
        case .identifier:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard string.decodedCount <= limits.maxIdentifierBytes else {
                return draft.reject(field, .identifierTooLong(bytes: string.decodedCount))
            }
            draft.identifier = self.materialize(string)
            if let violation = self.firstViolation(of: string, ManifestRules.identifierViolations(utf8:limits:)) {
                draft.reject(field, violation)
            } else {
                draft.identifierIsValid = true
                if !self.building, self.options.duplicates == .keepFirst {
                    draft.surveyedIdentifier = SurveyedIdentifier(body: self.cursor.body(of: string), hasEscapes: string.hasEscapes)
                }
            }
        case .fileExtension:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard string.decodedCount <= 8, self.isValidFileExtension(string) else {
                return draft.reject(field, .fileExtensionInvalid)
            }
            draft.fileExtension = self.materialize(string)
        case .remotePath:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard string.decodedCount <= limits.maxRemotePathBytes else {
                return draft.reject(field, .remotePathInvalid(.tooLong(bytes: string.decodedCount)))
            }
            if let violation = self.firstViolation(of: string, ManifestRules.remotePathViolations(utf8:limits:)) {
                return draft.reject(field, .remotePathInvalid(violation))
            }
            draft.remotePath = self.materialize(string)
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
            draft.localFileName = self.materialize(string)
        case .byteSize:
            if try self.cursor.consumeNull() {
                return
            }
            guard try self.cursor.peekValueKind() == .number else {
                return try self.rejectValue(field, &draft, depth: depth)
            }
            // Any spelling of an integer, as the prior art's `JSONDecoder` read it into `Int` (R-MAN-1): `1234.0`,
            // `1.234e3`; a fraction (`1.5`, `1e-1`) is malformed.
            let number = try self.cursor.scanNumber()
            guard let byteSize = self.cursor.integralValue(of: number) else {
                return draft.reject(field, .malformedField(field.name))
            }
            if let violation = ManifestRules.byteSizeViolation(byteSize, limits: limits) {
                return draft.reject(field, violation)
            }
            draft.byteSize = byteSize
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
    /// still validated as JSON but nothing more is materialised. The build pass collects the elements in `scratch`
    /// and returns them in an array reserved at their exact count; the survey pass counts them and returns `[]`.
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
        self.scratch.removeAll(keepingCapacity: true)
        var count = 0
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
                if count == maxCount {
                    violation = countViolation
                } else if let rejected = elementViolation(string.decodedCount) {
                    violation = rejected
                } else {
                    if let element = self.materialize(string) {
                        self.scratch.append(element)
                    }
                    count += 1
                }
            } while try self.cursor.continueContainer(closing: JSONByte.closeBracket)
        }
        self.tally.materializedBytes += self.building ? 0 : ManifestFootprint.array(count: count, stride: MemoryLayout<String>.stride)
        if let violation {
            draft.reject(field, violation)
            return nil
        }
        var result: [String] = []
        result.reserveCapacity(self.scratch.count)
        result.append(contentsOf: self.scratch)
        return result
    }

    /// The first violation a byte rule reports for a scanned string (on the payload's bytes when unescaped).
    private func firstViolation<Violation>(
        of string: JSONString,
        _ rule: (UnsafeRawBufferPointer, ManifestLimits) -> [Violation]
    ) -> Violation? {
        if let view = self.cursor.rawBytes(of: string) {
            return rule(view, self.options.limits).first
        }
        return self.cursor.decodedBytes(of: string).withUnsafeBytes { rule($0, self.options.limits).first }
    }

    private func isValidFileExtension(_ string: JSONString) -> Bool {
        if let view = self.cursor.rawBytes(of: string) {
            return ManifestRules.isValidFileExtension(utf8: view)
        }
        return self.cursor.decodedBytes(of: string).withUnsafeBytes(ManifestRules.isValidFileExtension(utf8:))
    }

    private func contentHash(of string: JSONString) -> ContentHash? {
        if let view = self.cursor.rawBytes(of: string) {
            return ManifestParser.contentHash(hex: view)
        }
        return self.cursor.decodedBytes(of: string).withUnsafeBytes(ManifestParser.contentHash(hex:))
    }

    /// The digest 64 hexadecimal characters (either case) spell, or `nil` if any is not hex.
    private static func contentHash(hex utf8: UnsafeRawBufferPointer) -> ContentHash? {
        guard utf8.count == 64, let w0 = ManifestParser.hexWord(utf8, at: 0), let w1 = ManifestParser.hexWord(utf8, at: 16),
            let w2 = ManifestParser.hexWord(utf8, at: 32), let w3 = ManifestParser.hexWord(utf8, at: 48)
        else {
            return nil
        }
        return ContentHash(w0: w0, w1: w1, w2: w2, w3: w3)
    }

    /// Sixteen hexadecimal characters at `offset` as one big-endian word.
    private static func hexWord(_ utf8: UnsafeRawBufferPointer, at offset: Int) -> UInt64? {
        var word: UInt64 = 0
        for index in offset..<(offset + 16) {
            guard let nibble = JSONByte.hexNibble(utf8[index]) else {
                return nil
            }
            word = word << 4 | UInt64(nibble)
        }
        return word
    }

    /// The known member a key names, or `nil` for an unknown member (ignored, R-MAN-1). Keys are told apart by
    /// length and first byte, then compared once.
    private func field(for key: JSONString) -> EntryField? {
        guard !key.hasEscapes else {
            return EntryField.allCases.first { self.cursor.string(key, equals: $0.key) }
        }
        let first = key.decodedCount > 0 ? self.cursor.bytes[key.start] : 0
        let candidate: EntryField
        switch key.decodedCount {
        case 4:
            candidate = .tags
        case 6:
            candidate = .policy
        case 8:
            candidate = first == UInt8(ascii: "b") ? .byteSize : .checksum
        case 10:
            candidate = first == UInt8(ascii: "i") ? .identifier : .remotePath
        case 13:
            candidate = first == UInt8(ascii: "f") ? .fileExtension : .localFileName
        case 19:
            candidate = .localPathComponents
        default:
            return nil
        }
        return self.cursor.string(key, equals: candidate.key) ? candidate : nil
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
    /// Whether `identifier` passed the identifier rules (only valid identifiers take part in the duplicate check).
    var identifierIsValid = false
    var fileExtension: String?
    var remotePath: String?
    var localPathComponents: [String]?
    var localFileName: String?
    var byteSize: Int64?
    var checksum: ContentHash?
    var tags: [String]?
    var policy: AssetPolicy?
    /// The valid identifier as the survey pass saw it, under `.keepFirst` only (duplicate counting).
    var surveyedIdentifier: SurveyedIdentifier?
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

/// An identifier as the survey pass sees it: a view of its JSON string body in the payload, equal and hashed by its
/// decoded bytes (an escaped body is decoded on demand, so the set of them holds no copy). The view lives only
/// inside the survey, within `ManifestDecoder.decode`'s `withUnsafeBytes` scope (ADR draft A-2).
struct SurveyedIdentifier: Hashable {
    /// The bytes between the quotes.
    let body: UnsafeRawBufferPointer
    /// Whether `body` contains escapes (its decoded bytes then differ from it).
    let hasEscapes: Bool

    static func == (lhs: SurveyedIdentifier, rhs: SurveyedIdentifier) -> Bool {
        if !lhs.hasEscapes, !rhs.hasEscapes {
            return SurveyedIdentifier.equal(lhs.body, rhs.body)
        }
        return lhs.decoded().withUnsafeBytes { left in rhs.decoded().withUnsafeBytes { right in SurveyedIdentifier.equal(left, right) } }
    }

    func hash(into hasher: inout Hasher) {
        if self.hasEscapes {
            self.decoded().withUnsafeBytes { hasher.combine(bytes: $0) }
        } else {
            hasher.combine(bytes: self.body)
        }
    }

    /// The identifier's UTF-8 bytes, escapes resolved.
    private func decoded() -> [UInt8] {
        guard self.hasEscapes else {
            return Array(self.body)
        }
        let whole = JSONString(start: 0, end: self.body.count, decodedCount: self.body.count, hasEscapes: true)
        return JSONCursor(bytes: self.body, maxDepth: 0).decodedBytes(of: whole)
    }

    private static func equal(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var index = 0
        while index < lhs.count {
            guard lhs[index] == rhs[index] else {
                return false
            }
            index += 1
        }
        return true
    }
}
