/// The identifiers the survey pass has seen, for the duplicate rules of R-MAN-2 (ADR draft A-4.3): under `.reject`
/// every valid identifier, so a repeat is reported at its second occurrence before anything later in the payload;
/// under `.keepFirst` the accepted ones, so the repeats are counted as the quarantines the build will make.
///
/// An open-addressing table of payload offsets: a slot holds one past the offset where an identifier's string body
/// starts, and the identifier is compared and hashed by its decoded bytes, read again from the payload
/// (`JSONCursor.string(_:equalsString:)`, `JSONCursor.hash(_:into:)`), so nothing is materialised and no hash stands
/// in for equality. Four bytes per slot, at most half full: 100,000 identifiers take 1 MiB, and while the table
/// doubles, its old and new slots together take 24 bytes per identifier, for at least 19 payload bytes each
/// (`{"identifier":"x"},`), so the survey stays well within R-MAN-3's bound (ADR draft A-8). It lives only inside
/// the survey, which `ManifestDecoder.decode` runs within its `withUnsafeBytes` scope; the decoder reads at most
/// 4 GiB − 2 bytes, so every offset fits.
struct SurveyedIdentifiers {
    /// One past the body offset of each identifier, or 0 for an empty slot; the count is a power of two.
    private var slots: [UInt32] = []
    /// The identifiers held.
    private var count = 0

    /// Adds the identifier `string`, a token of `cursor`'s payload; returns `false`, adding nothing, when one with the
    /// same decoded bytes is already held.
    mutating func insert(_ string: JSONString, in cursor: JSONCursor) -> Bool {
        if (self.count + 1) * 2 > self.slots.count {
            self.grow(in: cursor)
        }
        let mask = self.slots.count - 1
        var slot = SurveyedIdentifiers.hashValue(of: string, in: cursor) & mask
        while self.slots[slot] != 0 {
            if let held = cursor.string(startingAt: Int(self.slots[slot]) - 1), cursor.string(held, equalsString: string) {
                return false
            }
            slot = (slot + 1) & mask
        }
        self.slots[slot] = UInt32(truncatingIfNeeded: string.start + 1)
        self.count += 1
        return true
    }

    /// Doubles the table (four slots at first) and places every held identifier again.
    private mutating func grow(in cursor: JSONCursor) {
        let old = self.slots
        self.slots = [UInt32](repeating: 0, count: max(4, old.count * 2))
        let mask = self.slots.count - 1
        for value in old where value != 0 {
            guard let string = cursor.string(startingAt: Int(value) - 1) else {
                continue
            }
            var slot = SurveyedIdentifiers.hashValue(of: string, in: cursor) & mask
            while self.slots[slot] != 0 {
                slot = (slot + 1) & mask
            }
            self.slots[slot] = value
        }
    }

    /// The identifier's hash: its decoded bytes through a per-process seeded `Hasher`, so no payload can force
    /// collisions.
    private static func hashValue(of string: JSONString, in cursor: JSONCursor) -> Int {
        var hasher = Hasher()
        cursor.hash(string, into: &hasher)
        return hasher.finalize()
    }
}
