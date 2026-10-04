/// The manifest schema on top of `JSONCursor` (R-MAN-1, R-MAN-2): both wire shapes, unknown fields skipped,
/// structural violations rejected, per-entry violations quarantined.
///
/// No recursion, two passes over the same code (ADR draft A-8). The *survey* pass (`survey(_:options:)`) validates
/// the whole payload, applies every per-entry rule on the payload's own bytes, finds repeated identifiers
/// (`SurveyedIdentifiers`) and counts what the result will hold, materialising nothing; `ManifestDecoder` then
/// refuses a payload whose decoded form could exceed its allocation bound (R-MAN-3). The *build* pass reserves
/// exactly the surveyed capacities and materialises an entry only once it is known to be accepted (its members are
/// read again from the payload), so a quarantined entry costs nothing but the diagnostic the bound has room for. The
/// identifier index the result needs is built once, here, and handed to `ValidatedManifest`.
///
/// Which error a rejected payload reports never depends on member order (ADR draft A-4.3, A-4.9, fix round 3): an
/// error inside the assets array (one entry too many, a repeated identifier) is recorded at its place and the rest of
/// the document is still read, so a document that is not JSON or nests too deep reports that, an envelope reports a
/// version or shape error next, and only then the first assets error in payload order.
struct ManifestParser {
    /// What one parse produced: the manifest (build pass) or only the tally (survey pass).
    struct Output {
        var entries: [ManifestEntry]
        var positions: [AssetID: Int]
        var quarantined: [QuarantinedEntry]
        var quarantinedCount: Int
        var shape: ManifestWireShape
        var survey: ManifestSurvey
    }

    private var cursor: JSONCursor
    private let options: ManifestDecodingOptions
    /// Whether this is the build pass (values are materialised) rather than the survey.
    private let building: Bool
    /// The survey pass's counts.
    private var tally = ManifestSurvey()
    /// The first error inside the assets array in payload order, thrown once the whole document has been read.
    private var pendingError: ManifestError?
    /// The survey's record of identifiers seen (duplicate rules).
    private var identifiers = SurveyedIdentifiers()
    private var entries: [ManifestEntry] = []
    /// Accepted identifiers and their positions: the result's index, and under `.keepFirst` the repeat check. Empty
    /// up to `ValidatedManifest.linearLookupLimit` entries, which are found by a linear scan.
    private var positions: [AssetID: Int] = [:]
    private let indexesPositions: Bool
    private var quarantined: [QuarantinedEntry] = []
    private var quarantinedCount = 0
    /// The most diagnostics the build keeps, and the bytes their identifier strings may still take.
    private let diagnosticCapacity: Int
    private var diagnosticStringBytes: Int
    /// Whether diagnostics are still kept: the kept ones are a prefix of the quarantine, in payload order.
    private var keepsDiagnostics = true

    /// A survey pass when `plan` is `nil`, else a build pass that reserves what the survey counted.
    init(bytes: UnsafeRawBufferPointer, options: ManifestDecodingOptions, plan: ManifestBuildPlan?) {
        self.cursor = JSONCursor(bytes: bytes, maxDepth: options.limits.maxNestingDepth)
        self.options = options
        self.building = plan != nil
        self.indexesPositions = (plan?.survey.acceptedCount ?? 0) > ValidatedManifest.linearLookupLimit
        self.diagnosticCapacity = plan?.diagnosticCapacity ?? 0
        self.diagnosticStringBytes = plan?.diagnosticStringBytes ?? 0
        if let plan {
            self.entries.reserveCapacity(plan.survey.acceptedCount)
            if self.indexesPositions {
                self.positions.reserveCapacity(plan.survey.acceptedCount)
            }
            self.quarantined.reserveCapacity(plan.diagnosticCapacity)
        }
    }

    /// Runs the survey pass over the whole payload and returns its counts. The pass's own buffers (the identifier
    /// table) are released when it returns, before the build pass allocates anything.
    static func survey(_ bytes: UnsafeRawBufferPointer, options: ManifestDecodingOptions) throws(ManifestError) -> ManifestSurvey {
        var parser = ManifestParser(bytes: bytes, options: options, plan: nil)
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
        if let error = self.pendingError {
            throw error
        }
        return Output(
            entries: self.entries, positions: self.positions, quarantined: self.quarantined, quarantinedCount: self.quarantinedCount,
            shape: shape, survey: self.tally
        )
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
    /// `assets` looks like, since a later schema may restructure or drop it); then the v1 shape applies (`assets`
    /// present, an array, not repeated); only then an error inside `assets` (one entry too many, a repeated
    /// identifier), which `parseAssets` records rather than throws. So `assets` is interpreted in place only when a
    /// supported version precedes it; otherwise it is skipped (validated only) with its facts recorded, and parsed
    /// once the document has been read. An unsupported version is therefore never interpreted.
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
    /// element, quarantined ones included. The first error in payload order, an element past the limit or (in the
    /// survey) a repeated identifier, is recorded; the elements after it are only validated as JSON.
    private mutating func parseAssets(depth: Int) throws(ManifestError) {
        try self.cursor.checkDepth(depth)
        try self.cursor.expect(JSONByte.openBracket)
        if self.cursor.consume(JSONByte.closeBracket) {
            return
        }
        var index = 0
        repeat {
            if self.pendingError == nil, index >= self.options.limits.maxEntries {
                self.pendingError = .tooManyEntries(count: index + 1, limit: self.options.limits.maxEntries)
            }
            if self.pendingError == nil {
                try self.parseEntry(index: index, depth: depth)
            } else {
                try self.cursor.skipValue(depth: depth)
            }
            index += 1
        } while try self.cursor.continueContainer(closing: JSONByte.closeBracket)
    }

    /// One element of the assets array; `depth` is the array's.
    private mutating func parseEntry(index: Int, depth: Int) throws(ManifestError) {
        guard try self.cursor.peekValueKind() == .object else {
            try self.cursor.skipValue(depth: depth)
            // Two payload bytes (`1,`) cost a whole diagnostic, or none once the bound has no room (ADR draft A-8).
            self.quarantine(index: index, identifier: nil, violation: .malformedField(ManifestRules.Field.entry))
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
    private mutating func finish(_ draft: EntryDraft, index: Int) throws(ManifestError) {
        var draft = draft
        for field in EntryField.required where !draft.isPresent(field) {
            draft.reject(field, .malformedField(field.name))
        }
        guard self.building else {
            self.countInSurvey(draft, index: index)
            return
        }
        // Duplicates (ADR draft A-4.3): under `.reject` the survey proved every identifier unique. Under `.keepFirst`
        // only an accepted identifier makes a later occurrence a duplicate, so the first occurrence that can be kept is
        // kept, and a repeat, valid or not otherwise, is quarantined as `malformedField("identifier")` (the identifier
        // is the first field, so this is its first violation).
        var lookedUp: AssetID?
        if self.options.duplicates == .keepFirst, draft.identifierIsValid, let identifier = draft.identifier {
            let id = AssetID(self.cursor.decodedString(of: identifier))
            if self.isAccepted(id) {
                self.quarantine(index: index, id: id, violation: .malformedField(ManifestRules.Field.identifier))
                return
            }
            lookedUp = id
        }
        guard draft.firstViolation == nil, let identifier = draft.identifier, let fileExtension = draft.fileExtension,
            let remotePath = draft.remotePath, let components = draft.localPathComponents
        else {
            let violation = draft.firstViolation ?? .malformedField(ManifestRules.Field.entry)
            if let lookedUp {
                self.quarantine(index: index, id: lookedUp, violation: violation)
            } else {
                self.quarantine(index: index, identifier: draft.identifier, violation: violation)
            }
            return
        }
        let id = lookedUp ?? AssetID(self.cursor.decodedString(of: identifier))
        let localPathComponents = try self.materialize(components)
        var tags: [String] = []
        if let tagArray = draft.tags {
            tags = try self.materialize(tagArray)
        }
        if self.indexesPositions {
            self.positions[id] = self.entries.count
        }
        self.entries.append(
            ManifestEntry(
                identifier: id,
                fileExtension: self.cursor.decodedString(of: fileExtension),
                remotePath: self.cursor.decodedString(of: remotePath),
                localPathComponents: localPathComponents,
                localFileName: draft.localFileName.map { self.cursor.decodedString(of: $0) },
                byteSize: draft.byteSize,
                checksum: draft.checksum,
                tags: tags,
                policy: draft.policy ?? .standard
            )
        )
    }

    /// Whether `id` is an accepted identifier already.
    private func isAccepted(_ id: AssetID) -> Bool {
        if self.indexesPositions {
            return self.positions[id] != nil
        }
        return self.entries.contains { $0.identifier == id }
    }

    /// The survey pass's count of one entry, matching what `finish` does with it in the build pass, and the duplicate
    /// rules (ADR draft A-4.3): under `.reject` a valid identifier repeating any valid one seen before (a quarantined
    /// occurrence included) is the manifest's error, recorded at this second occurrence; under `.keepFirst` an entry
    /// that passes every rule but repeats an accepted identifier is a quarantine. Identifiers are compared by their
    /// decoded bytes, read from the payload.
    private mutating func countInSurvey(_ draft: EntryDraft, index: Int) {
        guard let identifier = draft.identifier, draft.identifierIsValid else {
            self.tally.quarantinedCount += 1
            self.noteDiagnosticIdentifier(draft.identifier)
            return
        }
        let accepted = draft.firstViolation == nil
        // Under `.keepFirst` the build materialises every valid identifier to look it up among the accepted ones; the
        // string of an entry it then quarantines is a transient (or a diagnostic's, charged to its own budget).
        let lookupBytes = ManifestFootprint.string(utf8Count: identifier.decodedCount) + self.decodedCopyBytes(identifier)
        if self.options.duplicates == .reject || accepted, !self.identifiers.insert(identifier, in: self.cursor) {
            switch self.options.duplicates {
            case .reject:
                self.pendingError = .duplicateIdentifier(AssetID(self.cursor.decodedString(of: identifier)))
            case .keepFirst:
                self.tally.quarantinedCount += 1
                self.tally.noteTransient(lookupBytes)
            }
            return
        }
        guard accepted else {
            self.tally.quarantinedCount += 1
            self.tally.noteTransient(self.options.duplicates == .keepFirst ? lookupBytes : self.decodedCopyBytes(identifier))
            return
        }
        self.tally.acceptedCount += 1
        self.tally.acceptedBytes += draft.heapBytes
        self.tally.noteTransient(ManifestFootprint.array(count: draft.largestEscapedCount, stride: 1))
    }

    /// A kept diagnostic materialises its identifier: an escaped one is decoded through a transient copy.
    private mutating func noteDiagnosticIdentifier(_ identifier: JSONString?) {
        if let identifier {
            self.tally.noteTransient(self.decodedCopyBytes(identifier))
        }
    }

    /// The heap of the decoded copy an escaped string is read through (none for a string without escapes).
    private func decodedCopyBytes(_ string: JSONString) -> Int {
        string.hasEscapes ? ManifestFootprint.array(count: string.decodedCount, stride: 1) : 0
    }

    /// Counts a quarantined element and keeps its diagnostic while the plan has room: at most `diagnosticCapacity`,
    /// and only while their identifier strings fit `diagnosticStringBytes`; the first that does not fit ends the
    /// kept prefix. The identifier is materialised only for a kept diagnostic.
    private mutating func quarantine(index: Int, identifier: JSONString?, violation: ManifestEntryViolation) {
        guard self.building else {
            self.tally.quarantinedCount += 1
            return
        }
        guard self.keepsDiagnostic(identifierBytes: identifier.map { ManifestFootprint.string(utf8Count: $0.decodedCount) } ?? 0) else {
            self.quarantinedCount += 1
            return
        }
        self.quarantinedCount += 1
        let id = identifier.map { AssetID(self.cursor.decodedString(of: $0)) }
        self.quarantined.append(QuarantinedEntry(index: index, identifier: id, violation: violation))
    }

    /// `quarantine(index:identifier:violation:)` for an identifier already materialised (under `.keepFirst`, to look
    /// it up).
    private mutating func quarantine(index: Int, id: AssetID, violation: ManifestEntryViolation) {
        self.quarantinedCount += 1
        if self.keepsDiagnostic(identifierBytes: ManifestFootprint.string(utf8Count: id.rawValue.utf8.count)) {
            self.quarantined.append(QuarantinedEntry(index: index, identifier: id, violation: violation))
        }
    }

    /// Whether the next diagnostic, whose identifier string takes `identifierBytes`, is kept; charges its bytes.
    private mutating func keepsDiagnostic(identifierBytes: Int) -> Bool {
        guard self.keepsDiagnostics, self.quarantined.count < self.diagnosticCapacity, identifierBytes <= self.diagnosticStringBytes else {
            self.keepsDiagnostics = false
            return false
        }
        self.diagnosticStringBytes -= identifierBytes
        return true
    }

    /// The strings of an accepted array member, read again from the payload into an array of exactly their count.
    private mutating func materialize(_ array: DraftStringArray) throws(ManifestError) -> [String] {
        guard array.count > 0 else {
            return []
        }
        var result: [String] = []
        result.reserveCapacity(array.count)
        let resume = self.cursor.offset
        self.cursor.seek(to: array.start)
        try self.cursor.expect(JSONByte.openBracket)
        repeat {
            self.cursor.skipWhitespace()
            let string = try self.cursor.scanString()
            result.append(self.cursor.decodedString(of: string))
        } while try self.cursor.continueContainer(closing: JSONByte.closeBracket)
        self.cursor.seek(to: resume)
        return result
    }

    // MARK: - Fields

    /// Reads one known member's value into the draft: the payload extent of a text value, checked against the field's
    /// rules on the payload's bytes (or, for an escaped string, a decoded copy) and materialised only by `finish`
    /// once the whole entry is accepted. The heap the entry would take is counted as it goes (`EntryDraft.heapBytes`).
    private mutating func parseField(_ field: EntryField, into draft: inout EntryDraft, depth: Int) throws(ManifestError) {
        let limits = self.options.limits
        switch field {
        case .identifier:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard !ManifestRules.isIdentifierTooLong(string.decodedCount, limits: limits) else {
                return draft.reject(field, .identifierTooLong(bytes: string.decodedCount))
            }
            draft.identifier = string
            draft.count(string)
            if let violation = self.firstViolation(of: string, ManifestRules.firstIdentifierViolation(utf8:limits:)) {
                draft.reject(field, violation)
            } else {
                draft.identifierIsValid = true
            }
        case .fileExtension:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard string.decodedCount <= 8, self.isValidFileExtension(string) else {
                return draft.reject(field, .fileExtensionInvalid)
            }
            draft.fileExtension = string
            draft.count(string)
        case .remotePath:
            guard let string = try self.stringValue(field, &draft, depth: depth) else {
                return
            }
            guard !ManifestRules.isRemotePathTooLong(string.decodedCount, limits: limits) else {
                return draft.reject(field, .remotePathInvalid(.tooLong(bytes: string.decodedCount)))
            }
            if let violation = self.firstViolation(of: string, ManifestRules.firstRemotePathViolation(utf8:limits:)) {
                return draft.reject(field, .remotePathInvalid(violation))
            }
            draft.remotePath = string
            draft.count(string)
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
            draft.localFileName = string
            draft.count(string)
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
                field, &draft, depth: depth, maxCount: ManifestRules.maxTagCount(limits), countViolation: .tagInvalid,
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

    /// An array of at most `maxCount` strings, each checked by `elementViolation` (on its decoded UTF-8 length): its
    /// place in the payload and its count, or `nil` after rejecting the field. The rest of a rejected array is still
    /// validated as JSON. `finish` reads an accepted one again into an array of exactly its count.
    private mutating func stringArray(
        _ field: EntryField,
        _ draft: inout EntryDraft,
        depth: Int,
        maxCount: Int,
        countViolation: ManifestEntryViolation,
        elementViolation: (Int) -> ManifestEntryViolation?
    ) throws(ManifestError) -> DraftStringArray? {
        guard try self.cursor.peekValueKind() == .array else {
            try self.rejectValue(field, &draft, depth: depth)
            return nil
        }
        try self.cursor.checkDepth(depth + 1)
        let start = self.cursor.offset
        try self.cursor.expect(JSONByte.openBracket)
        var count = 0
        var heapBytes = 0
        var largestEscaped = 0
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
                // At most `maxCount` elements (`>=`: a limit below one allows none, as `violations(of:)` reads it).
                if count >= maxCount {
                    violation = countViolation
                } else if let rejected = elementViolation(string.decodedCount) {
                    violation = rejected
                } else {
                    heapBytes += ManifestFootprint.string(utf8Count: string.decodedCount)
                    if string.hasEscapes {
                        largestEscaped = max(largestEscaped, string.decodedCount)
                    }
                    count += 1
                }
            } while try self.cursor.continueContainer(closing: JSONByte.closeBracket)
        }
        if let violation {
            draft.reject(field, violation)
            return nil
        }
        draft.heapBytes += heapBytes + ManifestFootprint.array(count: count, stride: MemoryLayout<String>.stride)
        draft.largestEscapedCount = max(draft.largestEscapedCount, largestEscaped)
        return DraftStringArray(start: start, count: count)
    }

    /// The first violation a byte rule reports for a scanned string, on the payload's bytes when it has no escape,
    /// else on a decoded copy (a transient the survey counts).
    private mutating func firstViolation<Violation>(
        of string: JSONString,
        _ rule: (UnsafeRawBufferPointer, ManifestLimits) -> Violation?
    ) -> Violation? {
        if let view = self.cursor.rawBytes(of: string) {
            return rule(view, self.options.limits)
        }
        self.noteDecodedCopy(string)
        return self.cursor.decodedBytes(of: string).withUnsafeBytes { rule($0, self.options.limits) }
    }

    private mutating func isValidFileExtension(_ string: JSONString) -> Bool {
        if let view = self.cursor.rawBytes(of: string) {
            return ManifestRules.isValidFileExtension(utf8: view)
        }
        self.noteDecodedCopy(string)
        return self.cursor.decodedBytes(of: string).withUnsafeBytes(ManifestRules.isValidFileExtension(utf8:))
    }

    private mutating func contentHash(of string: JSONString) -> ContentHash? {
        if let view = self.cursor.rawBytes(of: string) {
            return ManifestParser.contentHash(hex: view)
        }
        self.noteDecodedCopy(string)
        return self.cursor.decodedBytes(of: string).withUnsafeBytes(ManifestParser.contentHash(hex:))
    }

    /// Counts the decoded copy an escaped string is checked through (both passes make it; the survey counts it).
    private mutating func noteDecodedCopy(_ string: JSONString) {
        if !self.building {
            self.tally.noteTransient(self.decodedCopyBytes(string))
        }
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

/// One asset while its members are read: where its accepted values sit in the payload, and the first violation in
/// field order.
struct EntryDraft {
    /// Members seen so far, one bit per `EntryField` (a repeated member is a violation).
    private var presentMask: UInt16 = 0
    /// The identifier when it is within its length limit (for the entry, or the diagnostic of a quarantined one).
    var identifier: JSONString?
    /// Whether `identifier` passed the identifier rules (only valid identifiers take part in the duplicate check).
    var identifierIsValid = false
    var fileExtension: JSONString?
    var remotePath: JSONString?
    var localPathComponents: DraftStringArray?
    var localFileName: JSONString?
    var byteSize: Int64?
    var checksum: ContentHash?
    var tags: DraftStringArray?
    var policy: AssetPolicy?
    /// The heap the entry's strings and string arrays take once materialised (`ManifestFootprint`).
    var heapBytes = 0
    /// The decoded length of the longest escaped string materialising the entry decodes (its copy is a transient).
    var largestEscapedCount = 0
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

    /// Counts the heap a string member takes once materialised.
    mutating func count(_ string: JSONString) {
        self.heapBytes += ManifestFootprint.string(utf8Count: string.decodedCount)
        if string.hasEscapes {
            self.largestEscapedCount = max(self.largestEscapedCount, string.decodedCount)
        }
    }
}

/// An array member of strings that passed its rules: where it starts in the payload (its `[`) and its count.
struct DraftStringArray {
    var start: Int
    var count: Int
}
