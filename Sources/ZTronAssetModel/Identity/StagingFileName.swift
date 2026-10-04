/// The only names that may exist under `staging/` (ADR-013): `<TransferID>.<epoch>-<sequence>.<kind>`.
///
/// Names are a pure function of the transfer and its attempt: no randomness (C4), unique per start (transport-1
/// TR1-1), self-describing at launch (H-6). Anything under `staging/` that does not parse is foreign and is
/// collected by staging GC (R-CLN-3). No manifest text ever appears in a name (R-SEC-2).
public struct StagingFileName: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The role of a staging file; the raw value is the file-name suffix.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Bytes received so far (data tasks append here; ADR-019).
        case partial = "part"
        /// A `.part` being written by a writer that renames it into place when complete (Apple-tier copies).
        case partialTemporary = "parttmp"
        /// Our own resume sidecar (`ResumeSidecar`, JSON). Never URLSession resume data.
        case sidecar = "resume"
        /// The sidecar's atomic-write temporary.
        case sidecarTemporary = "resumetmp"
        /// A `.part` claimed by the store for publication: no producer writes this name (store-1 S1-12).
        case verifying = "verifying"
    }

    /// The transfer this file belongs to.
    public let transfer: TransferID
    /// The start that produced it.
    public let attempt: TransferAttempt
    /// Its role.
    public let kind: Kind

    /// Creates a name.
    public init(transfer: TransferID, attempt: TransferAttempt, kind: Kind) {
        self.transfer = transfer
        self.attempt = attempt
        self.kind = kind
    }

    /// Parses a directory entry name; `nil` for anything that is not exactly one of our names.
    public init?(parsing fileName: String) {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let transfer = TransferID(rawValue: String(parts[0])),
            let attempt = TransferAttempt(token: String(parts[1])),
            let kind = Kind(rawValue: String(parts[2]))
        else {
            return nil
        }
        self.init(transfer: transfer, attempt: attempt, kind: kind)
    }

    /// The file name.
    public var rawValue: String {
        "\(self.transfer.rawValue).\(self.attempt.token).\(self.kind.rawValue)"
    }

    /// The same transfer and attempt with another role.
    public func with(kind: Kind) -> StagingFileName {
        StagingFileName(transfer: self.transfer, attempt: self.attempt, kind: kind)
    }

    /// The file name.
    public var description: String {
        self.rawValue
    }

    /// Decodes and validates the file-name form.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let name = StagingFileName(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a staging file name")
        }
        self = name
    }

    /// Encodes the file-name form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Orders by transfer, attempt, then kind (deterministic GC and reconciliation order, store-2 S2-08).
    public static func < (lhs: StagingFileName, rhs: StagingFileName) -> Bool {
        (lhs.transfer, lhs.attempt, lhs.kind.rawValue) < (rhs.transfer, rhs.attempt, rhs.kind.rawValue)
    }
}
